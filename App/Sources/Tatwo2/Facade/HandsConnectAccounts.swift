import Foundation

// W183 R11 第二輪（GPT-6 R11 審查 3、4、5、6）：
// - 4（中）「入口把『主機有人連著』當成『目前這個 ChatGPT 帳號已連線』」：按［連線］的那台自己記「哪個 ChatGPT 帳號（Pod 帳號身分的雜湊）
//   連上哪台主機的哪一筆連線（主機回的代號）」——只在這台、0600，不進回報、不進 hands_setup_status、不進任何公開的狀態出口。
//   入口照這一份＋主機回報裡的代號核對「目前這個帳號的那一條還在不在」；核對不了（帳號讀不到、舊版主機沒有代號）＝照樣給［連線］。
// - 3（中）「剛連上」只維持到新的回報、或期限：回報在連上之後收到、卻沒有這一條＝斷了（在別處撤銷）；那台回報停了、暫停、安全鎖＝優先。
// - 5（中）主機的回報沒有逐筆證據（舊版）＝能力未確認，不推定 L2。
// - 6（中）［斷線］逐台回報：已撤銷／撤銷了但沒存成／沒做成／不知道。

/// 一筆：這台的 Pod 用哪個帳號、連上哪台、哪一筆。
struct HandsConnectAccountRecord: Codable, Equatable, Sendable {
    /// 主機的設備 id（小寫）。
    var host: String
    /// Pod 帳號身分（登入編號、工作區、信箱）的雜湊（HandsConnectAccounts.identityTag）。
    var identityTag: String
    /// 主機回的那一筆連線的代號（HandsBuildDeviceReport.grantTag）。舊版主機、晚一步的成功＝nil（核對不了）。
    var grantTag: String?
    /// 這次確認卡上的等級。
    var level: Int
    /// 連上的時間（這台的鐘）。
    var at: Date
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：連上那一刻這台的單調時鐘（「剛連上」的期限照這個算：牆上的鐘被調、跳都不影響）。
    /// 舊紀錄沒有＝nil（不算剛連上）。
    var uptime: TimeInterval? = nil
    /// W183 R11 最後一輪：主機確認這一條那一刻的授權狀態版本（回報的版本比它新、卻沒有這一條＝不在了）。舊版主機、晚一步的成功＝nil。
    var grantVersion: Int? = nil

    enum CodingKeys: String, CodingKey {
        case host, identityTag = "identity_tag", grantTag = "grant_tag", level, at, uptime, grantVersion = "grant_version"
    }
}

/// 這台按［連線］連上的紀錄（只在這台）。
final class HandsConnectAccounts: @unchecked Sendable {
    static let shared = HandsConnectAccounts(url: HandsPaths.default.appDir.appendingPathComponent("connect-accounts.json"))
    static let maxRecords = 32

    let url: URL
    private let lock = NSLock()
    private var cache: [HandsConnectAccountRecord]?

    init(url: URL) { self.url = url }

    /// Pod 帳號身分的雜湊（只在這台比對用；不存原文）。
    static func identityTag(_ identity: String) -> String {
        "i_" + String(HandsAuth.sha256Hex(Data(("tatwo-connect-identity|" + identity).utf8)).prefix(32))
    }

    func records() -> [HandsConnectAccountRecord] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// 這個帳號連上那台的那一筆（最新的）。
    func record(host: String, identityTag: String) -> HandsConnectAccountRecord? {
        records().last { HandsHostAuthority.same($0.host, host) && $0.identityTag == identityTag }
    }

    /// 連上了：記下（同一台、同一個帳號只留最新的一筆）。
    func remember(_ record: HandsConnectAccountRecord) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked().filter { !(HandsHostAuthority.same($0.host, record.host) && $0.identityTag == record.identityTag) }
        var fresh = record
        fresh.host = record.host.lowercased()
        list.append(fresh)
        if list.count > Self.maxRecords { list.removeFirst(list.count - Self.maxRecords) }
        saveLocked(list)
    }

    /// 斷好了（那幾台全部的連線都撤銷了）：那幾台的紀錄拿掉。
    func forget(hosts: [String]) {
        guard !hosts.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let list = loadLocked().filter { record in !hosts.contains { HandsHostAuthority.same($0, record.host) } }
        saveLocked(list)
    }

    private func loadLocked() -> [HandsConnectAccountRecord] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = HandsFiles.readSecure(url, limit: 256 * 1024).flatMap { try? decoder.decode([HandsConnectAccountRecord].self, from: $0) } ?? []
        let kept = Array(list.suffix(Self.maxRecords))
        cache = kept
        return kept
    }

    private func saveLocked(_ list: [HandsConnectAccountRecord]) {
        cache = list   // 存不進去也照記憶體裡的（重開 App＝核對不了＝照樣給［連線］：不會多說）
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(list) { try? HandsFiles.writeAtomically(data, to: url) }
    }
}

/// W183 R11（GPT-6 R11 審查 6）：［斷線］每台的結果。
enum HandsDisconnectOutcome: Equatable, Sendable {
    /// 撤銷了、存好了。
    case revoked
    /// 撤銷了（全部停用、授權檔刪了），但沒存成：一樣算斷了，之後要重新配對（帶那台給的一句話）。
    case revokedUnsaved(String)
    /// 沒做成（送不到、那台拒絕）：還連著，可以再按。
    case failed(String)
    /// 送出去了、不知道那台做了沒有（沒回覆、主設備重開）：不算斷；再按只重試這幾台。
    case unknown(String)

    /// 這台的連線確定斷了（撤銷了；存沒存成另外說）。
    var cut: Bool {
        switch self {
        case .revoked, .revokedUnsaved: true
        case .failed, .unknown: false
        }
    }

    /// 給卡片的一句（撤銷好了＝nil）。
    var text: String? {
        switch self {
        case .revoked: nil
        case .revokedUnsaved(let text), .failed(let text), .unknown(let text): text
        }
    }
}

/// W183 R11（GPT-6 R11 審查 3、4、5）：那台的回報給入口的證據（沒有帳號、沒有 token）。
struct HandsConnectHostEvidence: Equatable, Sendable {
    /// 回報夠新（那台、這台最近都跟主設備同步過）。
    var fresh: Bool
    /// 回報夠新、許可有效、關口在跑、沒有安全鎖。
    var serving: Bool
    /// 確認過的連線數（任何帳號＝「主機有有效授權」）。
    var confirmedGrants: Int
    /// 逐筆的代號 → 等級（nil＝舊版主機：沒有逐筆證據）。
    var grantLevels: [String: Int]?
    /// 這份回報收到的時間（換算成這台的鐘；不知道＝nil）。
    var receivedAt: Date?
    /// 那台實際生效的等級（中央設定）。
    var actualLevel: Int?
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：回報取樣那一刻那台授權狀態的版本（舊版沒有＝nil）。
    var grantsVersion: Int? = nil
    /// W183 R11 最後一輪：時鐘剛跳過（這台或主設備）：這份回報新不新鮮算不準。
    var clockSuspect = false
}

/// W183 R11：目前這個帳號在那台的樣子。
enum HandsConnectVerdict: Equatable, Sendable {
    /// 目前這個帳號的那一條還在（回報有它的代號；或剛連上、回報還沒跟上）。level＝ChatGPT 實際拿到的（nil＝能力未確認）。
    case connected(level: Int?)
    /// 沒有、或核對不了（帳號讀不到、沒有回報、舊版主機過了期限）：給［連線］。
    case open
    /// 這台記得的那一條確定不在了（新的回報沒有它＝在別處撤銷；那台回報停了、暫停、安全鎖）：已連線卡要跟著改。
    case ended(Ending)

    enum Ending: String, Equatable, Sendable { case revoked, stopped }

    /// 剛連上、回報還沒跟上：最多算多久（單調時鐘）。
    static let optimism: TimeInterval = 90

    /// 一台的判定（純資料，好測）。W183 R11 最後一輪（GPT-6 R11c 審查 4，中：「時間因果」）：
    /// - 「剛連上」照單調時鐘算（uptime：連上那一刻到現在）；牆上的鐘被調、跳都不影響。紀錄沒有單調時間（舊的）、單調時鐘倒退（重開機過）、
    ///   或連上之後牆上時鐘跳過（跟單調時鐘差太多）＝不算剛連上（不知道隔了多久）。
    /// - 時鐘剛跳過（這台的牆上時鐘在拿到這份全貌之後、或主設備的時鐘在收件與出全貌之間、上一份與這一份之間跳過）＝一律「未確認」：
    ///   不說已連線、也不說撤銷了、停了。
    /// - 撤銷、停了只看主機那邊的取樣先後（授權狀態版本）：回報取樣的版本不比連線確認那一刻舊、卻沒有這一條＝不在了；比較舊
    ///  （連上之前取樣、送晚了）＝這份回報說不到這條連線（剛連上的那一段算連著，之後「未確認」）；沒有可以比的版本（舊版主機、
    ///   晚一步的成功）＝不推定撤銷。不再用收到的牆上時間比先後。
    static func of(host: String, evidence: HandsConnectHostEvidence?, identityTag: String?, records: [HandsConnectAccountRecord],
                   now: Date, uptime: TimeInterval) -> HandsConnectVerdict {
        guard let identityTag, let record = records.last(where: { HandsHostAuthority.same($0.host, host) && $0.identityTag == identityTag }) else {
            return .open
        }
        guard let evidence, evidence.fresh else { return .open }   // 沒有回報、回報太舊：核對不了（不當成斷了，也不當成連著）
        if evidence.clockSuspect { return .open }                    // 時鐘剛跳過：這份回報新不新鮮算不準（不說連著、也不說斷了）
        let actual = evidence.actualLevel
        func capped(_ level: Int) -> Int { min(level, actual ?? level) }
        // 剛連上（單調時鐘；睡眠也算時間）：回報還沒跟上的那一段算連著。舊版主機（沒有逐筆證據）＝能力未確認（不推定 L2）。
        let optimistic: HandsConnectVerdict = young(record, now: now, uptime: uptime)
            ? .connected(level: evidence.grantLevels == nil ? nil : capped(record.level)) : .open
        // 這份回報是在連線確認之前取樣的（送晚了）：說不到這條連線（不算撤銷、不算停了）。
        let predates: Bool = {
            guard let sampled = evidence.grantsVersion, let confirmed = record.grantVersion else { return false }
            return sampled < confirmed
        }()
        guard evidence.serving else { return predates ? optimistic : .ended(.stopped) }   // 那台說它停了、暫停、安全鎖：優先
        if let levels = evidence.grantLevels {
            if let tag = record.grantTag, let level = levels[tag] { return .connected(level: capped(level)) }
            // 沒有這一條：取樣不比連線確認舊＝不在了（在別處撤銷）；比較舊、或比不了＝不推定撤銷。
            if record.grantTag != nil, evidence.grantsVersion != nil, record.grantVersion != nil, !predates { return .ended(.revoked) }
        }
        // 舊版主機（沒有逐筆證據）、比不了先後：剛連上的那一段算連著；之後核對不了＝給［連線］（卡片「未確認」）。不推定撤銷。
        return optimistic
    }

    /// 「剛連上」：連上那一刻到現在（單調時鐘）還在期限內，而且這一段牆上的鐘沒跳過。
    static func young(_ record: HandsConnectAccountRecord, now: Date, uptime: TimeInterval) -> Bool {
        guard let then = record.uptime else { return false }
        let elapsed = uptime - then
        guard elapsed >= 0, !HandsBuildView.clockJumped(wall: now.timeIntervalSince(record.at), monotonic: elapsed) else { return false }
        return elapsed < optimism
    }

    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：新的回報「證明」目前這個帳號的那一條還連著（回報新、時鐘沒跳過、那台在服務、裡面有這一條）——
    /// 不是剛連上的樂觀。推斷斷了的卡片只照這個恢復。
    static func proves(host: String, evidence: HandsConnectHostEvidence?, identityTag: String?, records: [HandsConnectAccountRecord]) -> Bool {
        guard let identityTag, let record = records.last(where: { HandsHostAuthority.same($0.host, host) && $0.identityTag == identityTag }),
              let tag = record.grantTag, let evidence, evidence.fresh, !evidence.clockSuspect, evidence.serving else { return false }
        return evidence.grantLevels?[tag] != nil
    }
}

/// W183 R11 最後一輪（GPT-6 R11c 審查 4）：這台的單調時鐘（秒；睡眠也算時間、牆上的鐘被調不影響；重開機歸零）。
enum HandsMonotonic {
    static func now() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
}
