import CryptoKit
import Darwin
import Foundation

// W183 R8c：可信設定套用（GPT-6 必改 2）。
//
// - 主設備把「給那一台的那一份」（HandsBuildDeviceSlice）包成信封，用主設備**既有的設備身分金鑰**簽（跟設備 RPC 同一把 SSH 客戶端金鑰；
//   另一個命名空間 tatwo2-hands-build：信封不能拿去當 RPC 的證明，反過來也不行）。信封帶 primaryID／authorityEpoch／targetDeviceID／
//   configRevision／deviceRevision／revocationGeneration／內容雜湊／簽發時間／有效期限。
// - 副設備只信**已配對的那一台主設備的公鑰**（devices.json 的 clientKeyFingerprint）：已 pin 的不從回覆換；加入端只有主機金鑰時，
//   經 pin 住主機金鑰的通道、先驗再補記一次（HandsBuildTrust.learnPrimaryKey，契約 §11.10）；沒 pin 住＝不收（fail closed）。主權換過（epoch 不對）、不是給這台的、雜湊對不上、過期、簽發時間在未來＝不收。
// - 副設備存已接受的最高版本（app/build-accepted.json，0600）：版本變小（回滾）、同版不同內容一律拒；同版同內容＝冪等（只把期限延長）。
// - 每台啟用許可（取代單主機的 HandsHostLease）：正本這台看自己的設定；副設備看已接受、還沒過期、給這台的信封。
//   信封過期（連不到主設備太久）＝安全暫停（關口停、工具不收），**不撤銷** grant；明確關掉（撤銷世代變大）才撤銷。
//   最長撤銷延遲＝信封有效期（lifetime）：副設備連不到主設備時，最多這麼久之後一定停。

struct HandsBuildEnvelopeBody: Codable, Equatable, Sendable {
    static let schemaName = "tatwo.hands-build-envelope.v1"
    var schema: String = HandsBuildEnvelopeBody.schemaName
    var primaryID: String
    var authorityEpoch: Int
    var targetDeviceID: String
    var configRevision: Int
    var deviceRevision: Int
    var revocationGeneration: Int
    var contentHash: String
    var issuedAt: Int
    var expiresAt: Int
    var content: HandsBuildDeviceSlice

    enum CodingKeys: String, CodingKey {
        case schema, primaryID = "primary_id", authorityEpoch = "authority_epoch", targetDeviceID = "target_device_id"
        case configRevision = "config_revision", deviceRevision = "device_revision", revocationGeneration = "revocation_generation"
        case contentHash = "content_hash", issuedAt = "issued_at", expiresAt = "expires_at", content
    }

    var expiresDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }
}

/// 簽過的信封：body 是簽章涵蓋的原始位元組（驗章、解碼都用同一份）。
struct HandsBuildEnvelope: Equatable, Sendable {
    let body: Data
    let signature: Data
    let publicKey: String

    var wire: [String: Any] {
        ["body": body.base64EncodedString(), "signature": signature.base64EncodedString(), "public_key": publicKey]
    }

    init(body: Data, signature: Data, publicKey: String) {
        self.body = body
        self.signature = signature
        self.publicKey = publicKey
    }

    init?(wire raw: Any?) {
        guard let object = raw as? [String: Any], Set(object.keys) == ["body", "signature", "public_key"],
              let body = (object["body"] as? String).flatMap({ Data(base64Encoded: $0) }), body.count <= 64 * 1024,
              let signature = (object["signature"] as? String).flatMap({ Data(base64Encoded: $0) }), signature.count < 8192,
              let key = object["public_key"] as? String, key.utf8.count <= 2048 else { return nil }
        self.init(body: body, signature: signature, publicKey: key)
    }
}

enum HandsBuildEnvelopeError: String, Error, CaseIterable, CustomStringConvertible {
    case malformed = "build_envelope_malformed"
    /// 這台沒有 pin 住主設備的公鑰（配對紀錄缺簽章識別）：不收任何信封。
    case unpinned = "build_envelope_unpinned"
    /// 簽的人不是已配對的那一台主設備。
    case untrustedSigner = "build_envelope_untrusted_signer"
    case badSignature = "build_envelope_bad_signature"
    case wrongPrimary = "build_envelope_wrong_primary"
    case wrongEpoch = "build_envelope_wrong_epoch"
    case wrongTarget = "build_envelope_wrong_target"
    case contentMismatch = "build_envelope_content_mismatch"
    case expired = "build_envelope_expired"
    case notYetValid = "build_envelope_not_yet_valid"
    case lifetime = "build_envelope_lifetime"
    /// 版本比已接受的小（回滾）。
    case rollback = "build_envelope_rollback"
    /// 同一個版本、不同內容。
    case conflict = "build_envelope_conflict"
    case notSaved = "build_envelope_not_saved"
    case signingUnavailable = "build_envelope_signing_unavailable"

    var description: String { rawValue }
}

/// 主設備簽信封（正式＝設備身分的 SSH 客戶端金鑰；ssh-agent 先、不行才用無密碼的金鑰檔；有密碼、拿不到＝不簽）。自測換成測試金鑰。
struct HandsBuildSigner: @unchecked Sendable {
    static let namespace = "tatwo2-hands-build"
    let sign: (Data) throws -> (signature: Data, publicKey: String)

    init(sign: @escaping (Data) throws -> (signature: Data, publicKey: String)) { self.sign = sign }

    /// 跟 DeviceDispatch.signed 同一把金鑰、同樣的做法（不讀私鑰內容、不跳鑰匙圈）；只有命名空間不一樣。
    static func ssh(environment: [String: String] = ProcessInfo.processInfo.environment) -> HandsBuildSigner {
        HandsBuildSigner { data in
            let key = environment["TATWO2_SSH_KEY_PATH"]
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
            let publicKey = try String(contentsOfFile: key + ".pub", encoding: .utf8)
            var result: (Int32, Data) = (1, Data())
            if environment["SSH_AUTH_SOCK"]?.isEmpty == false {
                result = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", key + ".pub", "-n", namespace], input: data)
            }
            if result.0 != 0 {
                result = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", key, "-P", "", "-n", namespace], input: data)
            }
            guard result.0 == 0, !result.1.isEmpty else { throw HandsBuildEnvelopeError.signingUnavailable }
            return (result.1, publicKey)
        }
    }
}

/// 副設備信誰：這台的設備 id、已配對的主設備 id、主權 epoch、主設備公鑰的指紋（配對時 pin 住的簽章識別）。
struct HandsBuildTrust: Equatable, Sendable {
    let localID: String
    let primaryID: String
    let epoch: Int
    let pinnedPrimaryKey: String?

    static func live(entry: TatwoEntry = TatwoEntry(), registry: DeviceRegistry = DeviceRegistry()) -> HandsBuildTrust? {
        guard case .member(let local, let primary, let epoch) = HandsBuildRole.current(entry: entry) else { return nil }
        let record = registry.list().first { HandsHostAuthority.same($0.id, primary) }
        return HandsBuildTrust(localID: local, primaryID: primary, epoch: epoch, pinnedPrimaryKey: record?.pinnedClientKeyFingerprint)
    }

    /// W183 R8 實機（v2.0.21.026，副設備）：加入端（副設備）配對時只 pin 主設備的主機金鑰（隧道用）；主設備的客戶端金鑰（簽信封那把）
    /// 原本只能在「主設備簽章 RPC 驗過之後」補（rpc_proof），可是驗之前就要那把——加入端永遠補不進來，信封一律 unpinned、整台不收。
    /// 補法：信封是經 callPinned（嚴格核對已 pin 的主機金鑰、不 TOFU）向主設備拿的；這條通道已經證明對面是主設備，信封上帶的公鑰
    /// 就是主設備自己拿來簽的那把。契約 §11.10。
    /// 呼叫前：記下主設備紀錄現在 pin 的主機金鑰（還沒有客戶端那把才有；主機金鑰也沒 pin＝nil，不補）。
    static func hostPin(primary: String, registry: DeviceRegistry = DeviceRegistry()) -> String? {
        guard let record = registry.list().first(where: { HandsHostAuthority.same($0.id, primary) }),
              record.pinnedClientKeyFingerprint == nil, !record.needsFingerprintRepair else { return nil }
        return record.hostKeyFingerprint
    }

    /// 呼叫後（GPT-6 審查：先驗再落地、綁這次呼叫）：用候選指紋把信封完整驗一次（簽章、主權、epoch、目標、雜湊、期限）；
    /// 過了才在同一把鎖裡核對「主機金鑰還是呼叫前那一把、客戶端那把還空著」再補記。驗不過、中途換過配對＝什麼都不留。
    @discardableResult
    static func learnPrimaryKey(envelope: HandsBuildEnvelope, trust: HandsBuildTrust, expectedHost: String, now: Date,
                                registry: DeviceRegistry = DeviceRegistry()) -> Bool {
        guard trust.pinnedPrimaryKey == nil,
              let fingerprint = try? DeviceRegistry.fingerprint(publicKey: envelope.publicKey) else { return false }
        let candidate = HandsBuildTrust(localID: trust.localID, primaryID: trust.primaryID, epoch: trust.epoch, pinnedPrimaryKey: fingerprint)
        guard (try? HandsBuildEnvelopes.verify(envelope, trust: candidate, now: now)) != nil else { return false }
        return (try? registry.recordClientFingerprint(id: trust.primaryID, expectedHost: expectedHost, fingerprint: fingerprint,
                                                      source: "hands_build_pinned_channel")) == true
    }
}

enum HandsBuildEnvelopes {
    /// 信封有效期＝副設備連不到主設備時的最長撤銷延遲（到期安全暫停；明確關掉在連得上時下一次同步就生效）。
    static let lifetime: TimeInterval = 2 * 3600
    /// 兩台時鐘最多差多少（簽發時間在這之後＝不收）。
    static let maxSkew: TimeInterval = 300

    static func issue(config: HandsBuildConfig, target: String, signer: HandsBuildSigner, now: Date,
                      lifetime: TimeInterval = HandsBuildEnvelopes.lifetime) throws -> HandsBuildEnvelope {
        let slice = config.slice(for: target)
        let body = HandsBuildEnvelopeBody(primaryID: config.primaryID.lowercased(), authorityEpoch: config.authorityEpoch,
                                          targetDeviceID: target.lowercased(), configRevision: config.configRevision,
                                          deviceRevision: slice.deviceRevision, revocationGeneration: slice.revocationGeneration,
                                          contentHash: slice.contentHash, issuedAt: Int(now.timeIntervalSince1970),
                                          expiresAt: Int(now.timeIntervalSince1970 + max(lifetime, 1)), content: slice)
        return try sign(body, signer: signer)
    }

    static func sign(_ body: HandsBuildEnvelopeBody, signer: HandsBuildSigner) throws -> HandsBuildEnvelope {
        let data = HandsBuildCanonical.encode(body)
        guard !data.isEmpty else { throw HandsBuildEnvelopeError.malformed }
        let signed = try signer.sign(data)
        return HandsBuildEnvelope(body: data, signature: signed.signature, publicKey: signed.publicKey)
    }

    /// 驗：公鑰是 pin 住的那一把、簽章對、是這一任主設備、給這台、雜湊對、在有效期內。回解好的內容。
    /// now＝nil：不看期限（讀回已接受的那一份時：過期的也要記著最高版本，防回滾；暫停由許可判斷）。
    static func verify(_ envelope: HandsBuildEnvelope, trust: HandsBuildTrust, now: Date?,
                       maxLifetime: TimeInterval = HandsBuildEnvelopes.lifetime) throws -> HandsBuildEnvelopeBody {
        guard let pinned = trust.pinnedPrimaryKey, pinned.hasPrefix("SHA256:") else { throw HandsBuildEnvelopeError.unpinned }
        guard let fingerprint = try? DeviceRegistry.fingerprint(publicKey: envelope.publicKey), fingerprint == pinned else {
            throw HandsBuildEnvelopeError.untrustedSigner
        }
        guard verifySignature(body: envelope.body, signature: envelope.signature, publicKey: envelope.publicKey) else {
            throw HandsBuildEnvelopeError.badSignature
        }
        guard let body = try? JSONDecoder().decode(HandsBuildEnvelopeBody.self, from: envelope.body),
              body.schema == HandsBuildEnvelopeBody.schemaName else { throw HandsBuildEnvelopeError.malformed }
        guard HandsHostAuthority.same(body.primaryID, trust.primaryID) else { throw HandsBuildEnvelopeError.wrongPrimary }
        guard body.authorityEpoch == trust.epoch else { throw HandsBuildEnvelopeError.wrongEpoch }
        guard HandsHostAuthority.same(body.targetDeviceID, trust.localID), HandsHostAuthority.same(body.content.deviceID, trust.localID) else {
            throw HandsBuildEnvelopeError.wrongTarget
        }
        guard body.content.contentHash == body.contentHash, body.content.deviceRevision == body.deviceRevision,
              body.content.revocationGeneration == body.revocationGeneration else { throw HandsBuildEnvelopeError.contentMismatch }
        let issued = TimeInterval(body.issuedAt), expires = TimeInterval(body.expiresAt)
        guard expires > issued, expires - issued <= maxLifetime + maxSkew else { throw HandsBuildEnvelopeError.lifetime }
        guard let now else { return body }
        let current = now.timeIntervalSince1970
        guard issued <= current + maxSkew else { throw HandsBuildEnvelopeError.notYetValid }
        guard expires > current else { throw HandsBuildEnvelopeError.expired }
        return body
    }

    #if DEBUG
    /// 自測：叫了幾次 ssh-keygen -Y verify（同一份信封不重驗）。
    nonisolated(unsafe) static var debugVerifyCount = 0
    #endif

    /// ssh-keygen -Y verify（允許的簽章者只有這一把、命名空間 tatwo2-hands-build）；暫存資料夾 0700、用完刪。
    static func verifySignature(body: Data, signature: Data, publicKey: String) -> Bool {
        #if DEBUG
        debugVerifyCount += 1
        #endif
        let fields = publicKey.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, !publicKey.contains("\r"), publicKey.split(separator: "\n").count <= 1,
              fields[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "@" || $0 == ".") }),
              fields[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }) else { return false }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("w183-build-" + UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                          attributes: [.posixPermissions: 0o700])) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let allowed = scratch.appendingPathComponent("allowed"), signatureFile = scratch.appendingPathComponent("signature")
        guard (try? Data("primary \(fields[0]) \(fields[1])\n".utf8).write(to: allowed)) != nil,
              (try? signature.write(to: signatureFile)) != nil,
              let result = try? DeviceDispatch.run("/usr/bin/ssh-keygen", ["-Y", "verify", "-f", allowed.path, "-I", "primary",
                                                                           "-n", HandsBuildSigner.namespace, "-s", signatureFile.path], input: body)
        else { return false }
        return result.0 == 0
    }
}

/// 主設備簽好的信封暫存（同一台、同一版、還有一半以上的期限＝不重簽；自測可以關）。
final class HandsBuildEnvelopeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (revision: Int, epoch: Int, envelope: HandsBuildEnvelope, expires: Date)] = [:]

    func envelope(config: HandsBuildConfig, target: String, signer: HandsBuildSigner, now: Date,
                  lifetime: TimeInterval = HandsBuildEnvelopes.lifetime) throws -> HandsBuildEnvelope {
        let key = target.lowercased()
        lock.lock()
        if let cached = entries[key], cached.revision == config.configRevision, cached.epoch == config.authorityEpoch,
           cached.expires.timeIntervalSince(now) > lifetime / 2 {
            lock.unlock()
            return cached.envelope
        }
        lock.unlock()
        let fresh = try HandsBuildEnvelopes.issue(config: config, target: target, signer: signer, now: now, lifetime: lifetime)
        lock.lock()
        entries[key] = (config.configRevision, config.authorityEpoch, fresh, now.addingTimeInterval(lifetime))
        lock.unlock()
        return fresh
    }
}

/// 副設備：已接受的最高版本（app/build-accepted.json，0600；只有信封原文，沒有秘密）。讀回來也要重驗一次章（同一個使用者的程式改得到檔案）。
final class HandsBuildAcceptedStore: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case accepted(HandsBuildEnvelopeBody)
        /// 同版同內容（冪等）：期限延長了。
        case refreshed(HandsBuildEnvelopeBody)
        /// 同版同內容、期限也沒比較長：什麼都不改。
        case unchanged(HandsBuildEnvelopeBody)

        var body: HandsBuildEnvelopeBody {
            switch self { case .accepted(let body), .refreshed(let body), .unchanged(let body): body }
        }
    }

    private struct Stored: Codable {
        var body: String
        var signature: String
        var publicKey: String
        enum CodingKeys: String, CodingKey { case body, signature, publicKey = "public_key" }
    }

    static let shared = HandsBuildAcceptedStore(url: HandsPaths.default.appDir.appendingPathComponent("build-accepted.json"))

    let url: URL
    private let lock = NSRecursiveLock()
    /// 驗過的（跟當時用的信任資訊綁在一起：主設備換了、公鑰換了就重驗）＋它的原文（W183 R8c 審查：一樣的信封不再叫 ssh-keygen）。
    private var verified: (trust: HandsBuildTrust, body: HandsBuildEnvelopeBody, raw: HandsBuildEnvelope)?
    #if DEBUG
    var failSavesForTesting = false
    #endif

    init(url: URL) { self.url = url }

    private func storedEnvelope() -> HandsBuildEnvelope? {
        guard let data = HandsFiles.readSecure(url, limit: 128 * 1024), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let body = Data(base64Encoded: stored.body), let signature = Data(base64Encoded: stored.signature) else { return nil }
        return HandsBuildEnvelope(body: body, signature: signature, publicKey: stored.publicKey)
    }

    /// 已接受的那一份（驗過章、是這一任主設備給這台的；過期的也回，由許可判斷暫停）。沒有、驗不過＝nil。
    func current(trust: HandsBuildTrust?) -> HandsBuildEnvelopeBody? {
        guard let trust else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let verified, verified.trust == trust { return verified.body }
        // 讀回來重驗章（期限不在這裡判斷：過期的一樣要記著最高版本，防回滾）。
        guard let stored = storedEnvelope(), let body = try? HandsBuildEnvelopes.verify(stored, trust: trust, now: nil) else { return nil }
        verified = (trust, body, stored)
        return body
    }

    /// 收一份新的：驗章與期限（現在必須還有效）、回滾與同版異內容一律拒；同版同內容只延長期限。
    /// W183 R8c 審查（GPT-6 中「防回滾只比全域版本」）：同一任主設備裡，除了整份的設定版本，**每台的** deviceRevision 與撤銷世代也不能倒退；
    /// 同一個 deviceRevision 的內容（與撤銷世代）一定要一樣——就算整份的版本變大也一樣（主設備還原、實作錯誤都擋在這裡）。
    /// W183 R8c 審查（Claude 高「每 10 秒叫一次 ssh-keygen」）：跟已接受的那一份逐位元一樣＝不重驗章（只核期限）。
    @discardableResult
    func accept(_ envelope: HandsBuildEnvelope, trust: HandsBuildTrust, now: Date) throws -> Outcome {
        lock.lock()
        if let verified, verified.trust == trust, verified.raw == envelope {
            lock.unlock()
            let current = now.timeIntervalSince1970
            guard TimeInterval(verified.body.issuedAt) <= current + HandsBuildEnvelopes.maxSkew else { throw HandsBuildEnvelopeError.notYetValid }
            guard verified.body.expiresDate > now else { throw HandsBuildEnvelopeError.expired }
            return .unchanged(verified.body)
        }
        lock.unlock()
        let body = try HandsBuildEnvelopes.verify(envelope, trust: trust, now: now)
        lock.lock(); defer { lock.unlock() }
        if let current = current(trust: trust), HandsHostAuthority.same(current.primaryID, body.primaryID) {
            if body.authorityEpoch < current.authorityEpoch { throw HandsBuildEnvelopeError.rollback }
            if body.authorityEpoch == current.authorityEpoch {
                if body.configRevision < current.configRevision { throw HandsBuildEnvelopeError.rollback }
                if body.configRevision == current.configRevision {
                    guard body.contentHash == current.contentHash else { throw HandsBuildEnvelopeError.conflict }
                    guard body.expiresAt > current.expiresAt else { return .unchanged(current) }
                    try store(envelope)
                    verified = (trust, body, envelope)
                    return .refreshed(body)
                }
                // 整份的版本變大：這台自己的版本與撤銷世代不能倒退；同一個 deviceRevision＝同一份內容。
                guard body.deviceRevision >= current.deviceRevision, body.revocationGeneration >= current.revocationGeneration else {
                    throw HandsBuildEnvelopeError.rollback
                }
                if body.deviceRevision == current.deviceRevision {
                    guard body.content.contentKey == current.content.contentKey, body.revocationGeneration == current.revocationGeneration else {
                        throw HandsBuildEnvelopeError.conflict
                    }
                }
            }
        }
        try store(envelope)
        verified = (trust, body, envelope)
        return .accepted(body)
    }

    private func store(_ envelope: HandsBuildEnvelope) throws {
        #if DEBUG
        if failSavesForTesting { throw HandsBuildEnvelopeError.notSaved }
        #endif
        let stored = Stored(body: envelope.body.base64EncodedString(), signature: envelope.signature.base64EncodedString(),
                            publicKey: envelope.publicKey)
        do { try HandsFiles.writeAtomically(try JSONEncoder().encode(stored), to: url) } catch { throw HandsBuildEnvelopeError.notSaved }
    }
}

/// 這台已經套用到哪一版（app/build-applied.json）：只記版本號，不是秘密。每台（正本這台也是）都有。
/// W183 R8c 審查：記是哪一台主設備的（換了主設備＝明確的交接，不混用舊的計數）、套用時這台有沒有被勾、那一份的內容雜湊。
struct HandsBuildApplied: Codable, Equatable, Sendable {
    var configRevision: Int = 0
    var deviceRevision: Int = 0
    var revocationGeneration: Int = 0
    var primaryID: String? = nil
    var active: Bool? = nil
    var contentHash: String? = nil
    enum CodingKeys: String, CodingKey {
        case configRevision = "config_revision", deviceRevision = "device_revision", revocationGeneration = "revocation_generation"
        case primaryID = "primary_id", active, contentHash = "content_hash"
    }
}

final class HandsBuildAppliedStore: @unchecked Sendable {
    static let shared = HandsBuildAppliedStore(url: HandsPaths.default.appDir.appendingPathComponent("build-applied.json"))
    let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    func load() -> HandsBuildApplied? {
        lock.lock(); defer { lock.unlock() }
        guard let data = HandsFiles.readSecure(url, limit: 16 * 1024) else { return nil }
        return try? JSONDecoder().decode(HandsBuildApplied.self, from: data)
    }

    func save(_ value: HandsBuildApplied) throws {
        lock.lock(); defer { lock.unlock() }
        try HandsFiles.writeAtomically(try JSONEncoder().encode(value), to: url)
    }
}

/// 每台啟用許可（GPT-6 必改 1：取代單主機的 claim／release／HandsHostLease）。
final class HandsBuildPermit: @unchecked Sendable {
    enum State: Equatable, Sendable {
        /// 可以跑（副設備：信封到期時間；正本這台：nil）。
        case active(HandsBuildDeviceSlice, expiresAt: Date?)
        /// 設定裡沒勾這台、或總開關關著。
        case inactive(HandsBuildDeviceSlice?)
        /// 安全暫停（信封過期＝太久連不到主設備）：關口停、工具不收，grant 留著。
        case paused(String)
        /// 沒有設定（沒有設備身分、副設備還沒收到過信封、驗不過）。
        case none

        var isActive: Bool { if case .active = self { return true }; return false }
        var slice: HandsBuildDeviceSlice? {
            switch self {
            case .active(let slice, _): slice
            case .inactive(let slice): slice
            case .paused, .none: nil
            }
        }
    }

    struct Dependencies {
        var role: () -> HandsBuildRole
        var config: () -> HandsBuildConfig?
        var accepted: () -> HandsBuildEnvelopeBody?
        var now: () -> Date = Date.init
    }

    static let shared = HandsBuildPermit(dependencies: .init(
        role: { HandsBuildRole.current() },
        config: { HandsBuildConfigStore.shared.load() },
        accepted: { HandsBuildAcceptedStore.shared.current(trust: HandsBuildTrust.live()) }))

    let dependencies: Dependencies
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func state(_ local: String) -> State {
        switch dependencies.role() {
        case .authority(let me, _):
            guard HandsHostAuthority.same(me, local), let config = dependencies.config() else { return .none }
            let slice = config.slice(for: local)
            return config.isActive(local) ? .active(slice, expiresAt: nil) : .inactive(config.entry(local) == nil ? nil : slice)
        case .member(let me, _, _):
            guard HandsHostAuthority.same(me, local), let body = dependencies.accepted(),
                  HandsHostAuthority.same(body.targetDeviceID, local) else { return .none }
            guard dependencies.now() < body.expiresDate else { return .paused("expired") }
            return body.content.active ? .active(body.content, expiresAt: body.expiresDate) : .inactive(body.content)
        case .unknown:
            return .none
        }
    }

    func permits(_ local: String) -> Bool { state(local).isActive }

    static func permits(_ local: String) -> Bool { shared.permits(local) }
}
