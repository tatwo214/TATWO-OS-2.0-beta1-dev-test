import Foundation
import CryptoKit
import Network

final class DevicePairingClient: @unchecked Sendable {
    private struct PairRequest: Codable {
        // W178 v2：配對碼不上網路（code 只留給舊版欄位解碼），改帶 nonce＋HMAC。
        var v: Int?
        var code: String?
        var nonce: String?
        var mac: String?
        let publicKey: String
        let name: String
        var user: String?      // 副機自己的登入名，主機記名單用（2026-09-05 真雙機抓到兩邊都記成自己）
        var deviceID: String?
        // 加入端自報的兩把公鑰指紋：客戶端金鑰讓主機交叉核對送來的公鑰，
        // 主機金鑰讓主機之後能 pin 住反向隧道（舊版主機沒有這兩欄，照樣相容）。
        var clientKeyFingerprint: String?
        var hostKeyFingerprint: String?
    }

    private struct PairResponse: Codable {
        let ok: Bool
        var deviceID: String?
        var hostName: String?
        var hostUser: String?   // 主機的登入名，副機之後 ssh 要用
        var reason: String?
        var hostDeviceID: String?
        // 產生配對碼端自報的兩把公鑰指紋。主機金鑰用來跟 ssh-keyscan 的結果交叉核對，
        // 客戶端金鑰讓加入端之後能驗主機送來的 RPC 簽章。
        var hostKeyFingerprint: String?
        var clientKeyFingerprint: String?
        var mac: String?
    }

    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        var result: Result<PairResponse, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        func resolve(_ value: Result<PairResponse, Error>) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            result = value
            lock.unlock()
            semaphore.signal()
        }
    }

    enum ClientError: Error, LocalizedError {
        case invalidHost
        case invalidPort
        case keyGenerationFailed(String)
        case publicKeyUnreadable
        case connectionTimedOut
        case responseInvalid
        case pairingRejected(String)
        case sshVerificationFailed
        case hostFingerprintUnavailable
        case responseUnauthenticated
        case hostKeyMismatch
        case unsafePeerAccount

        var errorDescription: String? {
            switch self {
            case .invalidHost: "invalid_host"
            case .invalidPort: "invalid_port"
            case let .keyGenerationFailed(reason): "ssh_keygen_failed:\(reason)"
            case .publicKeyUnreadable: "ssh_public_key_unreadable"
            case .connectionTimedOut: "pairing_connection_timed_out"
            case .responseInvalid: "pairing_response_invalid"
            case let .pairingRejected(reason): Self.rejectionText(reason)
            case .sshVerificationFailed: "ssh_batch_mode_verification_failed"
            case .hostFingerprintUnavailable: "ssh_host_fingerprint_unavailable"
            case .responseUnauthenticated:
                "pairing_response_unauthenticated：對方的回覆沒有通過配對碼驗證，可能有人在中間攔截，已停止配對"
            case .hostKeyMismatch:
                "ssh_host_key_mismatch：掃到的主機金鑰跟對方用配對碼證明的不一樣，可能有人在中間攔截，已停止配對"
            case .unsafePeerAccount:
                "pairing_peer_account_invalid：對方回報的登入名稱含有不允許的字元，已停止配對"
            }
        }

        private static func rejectionText(_ reason: String) -> String {
            switch reason {
            case "pairing_protocol_outdated":
                "pairing_rejected:pairing_protocol_outdated：另一台的 TATWO OS 版本不同，兩台都更新到最新版後重開配對窗"
            case "pairing_code_mismatch":
                "pairing_rejected:pairing_code_mismatch：配對碼不對"
            case "bad_request":
                "pairing_rejected:bad_request：另一台可能還是舊版 TATWO OS，兩台都更新到最新版後重開配對窗"
            default:
                "pairing_rejected:\(reason)"
            }
        }
    }

    private let registry: DeviceRegistry
    private let entry: TatwoEntry
    private let environment: [String: String]
    private let privateKeyURL: URL
    private let sshVerifier: (_ user: String, _ host: String, _ hostKey: String) -> Bool
    /// 回主機的 ed25519 公鑰（`ssh-ed25519 <base64>`）；配對時比對對方用配對碼證明的指紋，第一次 SSH 也只信這一把。
    private let hostKeyResolver: (String) -> String?
    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.device-pairing-client")

    init(
        registry: DeviceRegistry? = nil,
        privateKeyURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sshVerifier: ((_ user: String, _ host: String, _ hostKey: String) -> Bool)? = nil,
        hostKeyResolver: ((String) -> String?)? = nil
    ) {
        self.registry = registry ?? DeviceRegistry(environment: environment)
        self.entry = TatwoEntry(environment: environment)
        self.environment = environment
        let resolvedPrivateKeyURL = privateKeyURL
            ?? environment["TATWO2_SSH_KEY_PATH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519")
        self.privateKeyURL = resolvedPrivateKeyURL
        self.sshVerifier = sshVerifier ?? {
            Self.verifySSH(user: $0, host: $1, hostKey: $2, privateKeyURL: resolvedPrivateKeyURL, environment: environment)
        }
        self.hostKeyResolver = hostKeyResolver ?? Self.resolveHostKey
    }

    @discardableResult
    func pair(host: String, port: Int, code: String, name: String) throws -> DeviceRecord {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DevicePairingAuth.isSafeSSHHost(cleanHost) else {
            throw ClientError.invalidHost
        }
        guard (1...65_535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ClientError.invalidPort
        }
        let publicKey = try ensurePublicKey()
        // A first pairing adopts the host-issued UUID; an already identified device keeps it.
        let local = try DeviceIdentityStore.readLocal(entry: entry)
        let nonce = DevicePairingAuth.makeNonce()
        guard let key = DevicePairingAuth.key(code: code, nonce: nonce) else {
            throw ClientError.responseInvalid
        }
        var request = PairRequest(
            v: DevicePairingAuth.protocolVersion, nonce: nonce,
            publicKey: publicKey, name: name, user: NSUserName(),
            deviceID: local?.deviceID,
            clientKeyFingerprint: try? DeviceRegistry.fingerprint(publicKey: publicKey),
            hostKeyFingerprint: DeviceRegistry.localHostKeyFingerprint(environment: environment))
        request.mac = DevicePairingAuth.mac(key: key, label: "request", fields: DevicePairingAuth.requestFields(
            nonce: nonce, publicKey: request.publicKey, name: request.name, user: request.user,
            deviceID: request.deviceID, clientKeyFingerprint: request.clientKeyFingerprint,
            hostKeyFingerprint: request.hostKeyFingerprint))
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)

        let connection = NWConnection(host: NWEndpoint.Host(cleanHost), port: nwPort, using: .tcp)
        let reply = ReplyBox()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        reply.resolve(.failure(error))
                        connection.cancel()
                    } else {
                        self?.receiveLine(from: connection, buffer: Data(), reply: reply)
                    }
                })
            case let .failed(error):
                reply.resolve(.failure(error))
                connection.cancel()
            case let .waiting(error):
                reply.resolve(.failure(error))
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard reply.semaphore.wait(timeout: .now() + 12) == .success else {
            connection.cancel()
            throw ClientError.connectionTimedOut
        }
        connection.cancel()
        let response: PairResponse
        switch reply.result {
        case let .success(value): response = value
        case let .failure(error): throw error
        case .none: throw ClientError.responseInvalid
        }
        let authenticated = DevicePairingAuth.verify(
            mac: response.mac, key: key, label: "response", fields: DevicePairingAuth.responseFields(
                nonce: nonce, ok: response.ok, deviceID: response.deviceID, hostName: response.hostName,
                hostUser: response.hostUser, hostDeviceID: response.hostDeviceID,
                hostKeyFingerprint: response.hostKeyFingerprint,
                clientKeyFingerprint: response.clientKeyFingerprint, reason: response.reason))
        guard response.ok else {
            // 拒絕不一定帶得出驗證（配對碼打錯時雙方金鑰不同）；只拿來顯示原因，不採信任何其他欄位。
            throw ClientError.pairingRejected(response.reason ?? "unknown")
        }
        // 成功回覆必須通過配對碼驗證；否則登入名、主機金鑰指紋都可能是中間人塞的。
        guard authenticated else { throw ClientError.responseUnauthenticated }
        // Older hosts (before W76) do not return hostDeviceID. Accept that during the
        // two-device upgrade window: derive a stable per-host ID instead of failing pairing.
        guard let deviceID = response.deviceID, let hostName = response.hostName else {
            throw ClientError.responseInvalid
        }
        let hostDeviceID = response.hostDeviceID
            ?? UUID(uuidString: Self.legacyHostID(host: cleanHost, name: hostName))?.uuidString
            ?? UUID().uuidString
        guard UUID(uuidString: deviceID) != nil, UUID(uuidString: hostDeviceID) != nil,
              deviceID.lowercased() != hostDeviceID.lowercased(),
              local.map({ $0.deviceID.lowercased() == deviceID.lowercased() }) ?? true
        else {
            throw ClientError.responseInvalid
        }
        let hostUser = response.hostUser ?? NSUserName()
        guard DevicePairingAuth.isSafeSSHUser(hostUser) else {
            throw ClientError.unsafePeerAccount
        }
        // W178：主機用配對碼證明了自己的主機金鑰指紋；實際掃到的必須一模一樣才 pin，不一樣就停。
        guard let declaredHostKey = response.hostKeyFingerprint, declaredHostKey.hasPrefix("SHA256:"),
              let scannedKey = hostKeyResolver(cleanHost),
              let fingerprint = try? DeviceRegistry.fingerprint(publicKey: scannedKey)
        else {
            throw ClientError.hostFingerprintUnavailable
        }
        guard fingerprint == declaredHostKey else { throw ClientError.hostKeyMismatch }
        // 第一次 SSH 也只信這把已證明的金鑰：掃描之後才換端點的中間人，登入會直接失敗。
        guard sshVerifier(hostUser, cleanHost, scannedKey) else {
            throw ClientError.sshVerificationFailed
        }
        let hostKeySource = "pairing"
        // 主機的客戶端金鑰指紋只在格式正確時收下；收不到就留空，之後 RPC 照樣擋。
        let peerClientKey = response.clientKeyFingerprint.flatMap { $0.hasPrefix("SHA256:") ? $0 : nil }
        _ = try DeviceIdentityStore.forLocalDevice(entry: entry, pairedDeviceID: deviceID, name: name)
        let now = Date()
        return try registry.recordPairedHost(DeviceRecord(
            id: hostDeviceID.lowercased(),
            name: hostName,
            host: cleanHost,
            user: hostUser,
            sshPort: 22,
            publicKeyFingerprint: fingerprint,
            addedAt: now, lastSeenAt: now, workdirMap: [:],
            hostKeyFingerprint: fingerprint,
            clientKeyFingerprint: peerClientKey,
            hostKeyFingerprintSource: .init(source: hostKeySource, recordedAt: now),
            clientKeyFingerprintSource: peerClientKey.map { _ in
                .init(source: "pairing", recordedAt: now) }),
            localDeviceID: deviceID)
    }

    /// Deterministic UUID-shaped ID for a pre-W76 host (name-based, lowercase hex).
    static func legacyHostID(host: String, name: String) -> String {
        let digest = Array(SHA256.hash(data: Data("tatwo-legacy-host:\(host.lowercased()):\(name)".utf8)))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-5\(String(c[13..<16]))-a\(String(c[17..<20]))-\(String(c[20..<32]))"
    }

    private func ensurePublicKey() throws -> String {
        let publicURL = URL(fileURLWithPath: privateKeyURL.path + ".pub")
        if !FileManager.default.fileExists(atPath: publicURL.path) {
            try FileManager.default.createDirectory(
                at: privateKeyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let result = Self.run(
                executable: "/usr/bin/ssh-keygen",
                arguments: ["-t", "ed25519", "-N", "", "-f", privateKeyURL.path])
            guard result.status == 0 else {
                throw ClientError.keyGenerationFailed(result.output)
            }
        }
        guard let value = try? String(contentsOf: publicURL, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ClientError.publicKeyUnreadable
        }
        return value
    }

    private func receiveLine(from connection: NWConnection, buffer: Data, reply: ReplyBox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else {
                reply.resolve(.failure(ClientError.responseInvalid))
                return
            }
            var joined = buffer
            if let data { joined.append(data) }
            if joined.count > 65_536 {
                reply.resolve(.failure(ClientError.responseInvalid))
                return
            }
            if let newline = joined.firstIndex(of: 0x0A) {
                self.decodeReply(Data(joined[..<newline]), into: reply)
            } else if complete || error != nil {
                if let error {
                    reply.resolve(.failure(error))
                } else {
                    self.decodeReply(joined, into: reply)
                }
            } else {
                self.receiveLine(from: connection, buffer: joined, reply: reply)
            }
        }
    }

    private func decodeReply(_ data: Data, into reply: ReplyBox) {
        guard let response = try? JSONDecoder().decode(PairResponse.self, from: data) else {
            reply.resolve(.failure(ClientError.responseInvalid))
            return
        }
        reply.resolve(.success(response))
    }

    static let pairingHostKeyAlias = "tatwo-pairing-verify"

    /// 第一次登入的 ssh 參數：只認一次性 known_hosts 裡那把已證明的金鑰（StrictHostKeyChecking=yes），
    /// 登入名用 -l、主機放在 -- 之後。
    static func verifyArguments(user: String, host: String, knownHostsPath: String, identityPath: String?) -> [String] {
        // 路徑照 ssh_config 語法加引號；不共用既有的多工主連線，也不從 KnownHostsCommand／DNS 取其他金鑰。
        let quoted = knownHostsPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"\(quoted)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "KnownHostsCommand=none",
            "-o", "VerifyHostKeyDNS=no",
            "-o", "UpdateHostKeys=no",
            "-o", "HostKeyAlias=\(pairingHostKeyAlias)",
            "-o", "CheckHostIP=no",
            "-o", "HostKeyAlgorithms=ssh-ed25519",
        ]
        if let identityPath { arguments += ["-i", identityPath] }
        return arguments + ["-l", user, "--", host, "echo", "ok"]
    }

    private static func verifySSH(
        user: String,
        host: String,
        hostKey: String,
        privateKeyURL: URL,
        environment: [String: String]
    ) -> Bool {
        guard let key = normalizedHostKey(hostKey) else { return false }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tatwo-pair-known-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temp.path, contents: Data("\(pairingHostKeyAlias) \(key)\n".utf8),
            attributes: [.posixPermissions: 0o600])
        else { return false }
        defer { try? FileManager.default.removeItem(at: temp) }
        let arguments = verifyArguments(
            user: user, host: host, knownHostsPath: temp.path,
            identityPath: environment["TATWO2_SSH_KEY_PATH"] != nil ? privateKeyURL.path : nil)
        let result = run(executable: "/usr/bin/ssh", arguments: arguments)
        guard result.status == 0, result.output.split(whereSeparator: \.isNewline).contains("ok") else { return false }
        // 之後的連線（SSHHostPin）照指紋到 known_hosts 找金鑰；這把已經用配對碼證明過，才替使用者記下來。
        return rememberHostKey(host: host, key: key, environment: environment)
    }

    /// `ssh-ed25519 <base64>`（去掉註解）；格式不對回 nil。
    static func normalizedHostKey(_ value: String) -> String? {
        let fields = value.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "ssh-ed25519", Data(base64Encoded: String(fields[1])) != nil else { return nil }
        return "\(fields[0]) \(fields[1])"
    }

    /// 把已證明的主機金鑰補進 known_hosts（已有同一把就不動；不刪、不改其他行）。
    @discardableResult
    static func rememberHostKey(host: String, key: String, environment: [String: String]) -> Bool {
        guard let key = normalizedHostKey(key), let blob = key.split(separator: " ").last else { return false }
        let path = environment["TATWO2_SSH_KNOWN_HOSTS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["TATWO2_KNOWN_HOSTS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts").path
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if existing.split(whereSeparator: \.isNewline).contains(where: { line in
            line.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init) == "ssh-ed25519"
                && line.split(whereSeparator: \.isWhitespace).dropFirst(2).first.map(String.init) == String(blob)
        }) { return true }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let line = Data((prefix + "\(host) \(key)\n").utf8)
        if !FileManager.default.fileExists(atPath: path) {
            return FileManager.default.createFile(atPath: path, contents: line, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    private static func resolveHostKey(host: String) -> String? {
        let result = run(
            executable: "/usr/bin/ssh-keyscan",
            arguments: ["-T", "5", "-t", "ed25519", "-p", "22", "--", host])
        guard result.status == 0 || !result.output.isEmpty else { return nil }
        let keys = result.output.split(whereSeparator: \.isNewline).map(String.init)
        guard let line = keys.first(where: { $0.contains(" ssh-ed25519 ") }),
              let keyStart = line.range(of: "ssh-ed25519 ")
        else { return nil }
        return normalizedHostKey(String(line[keyStart.lowerBound...]))
    }

    private static func run(executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
