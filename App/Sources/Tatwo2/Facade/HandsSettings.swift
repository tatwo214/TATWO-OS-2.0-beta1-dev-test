import Darwin
import Foundation

// W183 R1／R1b：ChatGPT 手腳的設定與狀態檔（接口約定 v2 §10）。
// 全部在 `<App Support>/TATWO OS Hands/`：App 端 app/（設定、OAuth 狀態、工作區紀錄、request_id 紀錄）——關口讀不到；
// workspaces/<id>/{repo,scratch}（沙盒工作區）；output/<grant>/<job>（指令輸出，App 管理、沙盒不可寫）；marks/（掃描標記）。
// 關口端的 gateway/、cf-home/、logs/、cf.yml 由 R2 寫；沙盒一律讀寫不到。
// 檔案：資料夾 0700、檔案 0600，原子寫入（O_EXCL|O_NOFOLLOW 建暫存再 rename）。讀不到、格式壞、權限或擁有者不對＝當成「關閉」。

/// `<App Support>/TATWO OS Hands` 底下的位置（跟 R2 的 HandsGatewayLaunch.Paths 同一個根）。
struct HandsPaths: Equatable, Sendable {
    static let rootFolderName = "TATWO OS Hands"
    let root: URL

    var appDir: URL { root.appendingPathComponent("app", isDirectory: true) }
    var settingsFile: URL { appDir.appendingPathComponent("settings.json") }
    var authFile: URL { appDir.appendingPathComponent("auth.json") }
    var workspacesFile: URL { appDir.appendingPathComponent("workspaces.json") }
    var requestsDir: URL { appDir.appendingPathComponent("requests", isDirectory: true) }
    /// App 自己的暫存（交件的暫存 index、patch）：沙盒碰不到。
    var tmpDir: URL { appDir.appendingPathComponent("tmp", isDirectory: true) }
    var workspacesDir: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    var outputDir: URL { root.appendingPathComponent("output", isDirectory: true) }
    var marksDir: URL { root.appendingPathComponent("marks", isDirectory: true) }
    /// 不屬於任何工作區的小幫手暫存（讀專案主線）。
    var scratchDir: URL { root.appendingPathComponent("scratch", isDirectory: true) }

    func workspaceDir(_ id: UUID) -> URL { workspacesDir.appendingPathComponent(id.uuidString, isDirectory: true) }
    func repo(_ id: UUID) -> URL { workspaceDir(id).appendingPathComponent("repo", isDirectory: true) }
    func scratch(_ id: UUID) -> URL { workspaceDir(id).appendingPathComponent("scratch", isDirectory: true) }
    func output(grant: String, job: String) -> URL {
        outputDir.appendingPathComponent(grant, isDirectory: true).appendingPathComponent(job, isDirectory: true)
    }

    /// 沙盒一律讀寫不到的（含 R2 的關口設定、cloudflared 家目錄與日誌）。
    var privateAreas: [URL] {
        [appDir, outputDir, root.appendingPathComponent("gateway", isDirectory: true),
         root.appendingPathComponent("cf-home", isDirectory: true), root.appendingPathComponent("logs", isDirectory: true),
         root.appendingPathComponent("cf.yml")]
    }

    /// 預設 `~/Library/Application Support/TATWO OS Hands`（staging 的 CFFIXED_USER_HOME 會把它帶到 staging 的家目錄）。
    static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(rootFolderName, isDirectory: true)
    }

    static let `default` = HandsPaths(root: defaultRoot())
}

/// `app/settings.json`。公開網域不寫死：執行時從使用者的 Cloudflare 網域選（R3），這裡只存選好的值。
struct HandsSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// 0＝L0 看、1＝L1 提案與記憶（預設）、2＝L2 沙盒動手。L3（整台電腦）不存在。等級上限：grant 核准的等級也不能超過這個。
    var level: Int = 1
    /// W183 R10：本機欄位留著相容（舊檔、舊版讀得到），**不再當閘門**——有效範圍看 centralized(by:)：等級＝ChatGPT build 給這台的、
    /// 專案＝那台所有能當專案的（allProjects）。這個欄位現在只剩「畫面上的舊值」，沒有任何地方拿它決定 ChatGPT 能碰什麼。
    var allowedProjectIDs: [String] = []
    /// W183 R10：不存檔（不在 CodingKeys）。centralized(by:) 算出來的有效設定＝true：專案＝這台所有能當專案的（新專案自動包含）。
    var allProjects: Bool = false
    /// 借出的資料夾：接口 v2／v3 的工具表沒有對應工具，首版不開放（欄位保留給 R3，不生效）。
    var lentFolders: [String] = []
    var hostDeviceID: String? = nil
    var publicHost: String? = nil
    /// ChatGPT 的 OAuth callback 清單（接口 v2 §2：redirect_uris 必須精確在這裡；沒設就用 defaultCallbacks）。
    var chatgptCallbacks: [String] = []
    /// W183 R6a（09-28 使用者「不要隨機子網域 固定加os-for-chagpt」→ 確認拼字 os-for-chatgpt）：服務網址的子網域標籤，
    /// 網址固定是 `<標籤>.<選的網域>`；nil 或不合格＝預設 os-for-chatgpt（「詳細」看得到）。
    var subdomainLabel: String? = nil
    /// W183 R6a 審查（GPT-6「主機 claim／release 沒有世代與期限保護」）：主設備記的「主機任期」——主機每換一次（認領、交回、換別台）就 +1。
    /// 副設備交回時要帶它認領時拿到的任期：延遲送達的舊交回不會把這一任的主機空出來。只有主設備的這一份有意義。
    var hostEpoch: Int? = nil

    static let maxLevel = 2
    /// ChatGPT 連接器的固定回呼網址（OpenAI 公布的，不是使用者的網域）。每個連接器自己的 `/connector/oauth/<id>` 要由畫面加進清單。
    static let defaultCallbacks = ["https://chatgpt.com/connector_platform_oauth_redirect"]
    /// W183 R6a：固定子網域的預設標籤。
    static let defaultSubdomainLabel = "os-for-chatgpt"

    /// 實際用的標籤（DNS 標籤：小寫英數與「-」，頭尾不是「-」，最多 63 字）。
    var effectiveSubdomainLabel: String { subdomainLabel.flatMap(Self.validLabel) ?? Self.defaultSubdomainLabel }

    static func validLabel(_ raw: String) -> String? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard label.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil else { return nil }
        return label
    }

    enum CodingKeys: String, CodingKey {
        case enabled, level
        case allowedProjectIDs = "allowed_project_ids"
        case lentFolders = "lent_folders"
        case hostDeviceID = "host_device_id"
        case publicHost = "public_host"
        case chatgptCallbacks = "chatgpt_callbacks"
        case subdomainLabel = "subdomain_label"
        case hostEpoch = "host_epoch"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        level = min(max(try c.decodeIfPresent(Int.self, forKey: .level) ?? 1, 0), Self.maxLevel)
        allowedProjectIDs = try c.decodeIfPresent([String].self, forKey: .allowedProjectIDs) ?? []
        lentFolders = try c.decodeIfPresent([String].self, forKey: .lentFolders) ?? []
        hostDeviceID = try c.decodeIfPresent(String.self, forKey: .hostDeviceID)
        publicHost = try c.decodeIfPresent(String.self, forKey: .publicHost)
        chatgptCallbacks = try c.decodeIfPresent([String].self, forKey: .chatgptCallbacks) ?? []
        subdomainLabel = try c.decodeIfPresent(String.self, forKey: .subdomainLabel)
        hostEpoch = try c.decodeIfPresent(Int.self, forKey: .hostEpoch)
    }

    /// 等級夾在 0...2；專案 id 只收 UUID；回呼網址只收 ChatGPT 的固定網址（HandsAuth.isAcceptableRedirect）。
    var normalized: HandsSettings {
        var copy = self
        copy.level = min(max(level, 0), Self.maxLevel)
        var seen = Set<String>()
        copy.allowedProjectIDs = allowedProjectIDs.compactMap { UUID(uuidString: $0)?.uuidString }
            .filter { seen.insert($0).inserted }
        copy.lentFolders = Array(lentFolders.filter { $0.hasPrefix("/") && !$0.contains("\0") }.prefix(16))
        if let host = publicHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
           host.count <= 253, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) {
            copy.publicHost = host.lowercased()
        } else {
            copy.publicHost = nil
        }
        var seenCallbacks = Set<String>()
        copy.chatgptCallbacks = Array(chatgptCallbacks.filter { HandsAuth.isAcceptableRedirect($0) && seenCallbacks.insert($0).inserted }.prefix(8))
        copy.subdomainLabel = subdomainLabel.flatMap(Self.validLabel)   // W183 R6a
        copy.hostEpoch = hostEpoch.map { max($0, 0) }   // W183 R6a 審查
        return copy
    }

    /// W183 R10（使用者 09-29「就要給他用了還要多一個勾選」；取代 W183 R8 整合審查的「本機核准 ∩ 中央上限」）：這台實際生效的範圍＝
    /// **中央設定**（ChatGPT build 給這台的等級；HandsService.scopeCap）＋ **這台所有能當專案的**（allProjects；新專案自動包含）。
    /// 不再 ∩ 本機的 allowed_project_ids、不再跟本機的 level 取小：在任何一台改面板，主機收到信封就生效，不用到主機再核准。
    /// 工具清單、每次呼叫、工作啟動與發布都照這一份核（再 ∩ grant）；撤銷（總開關、撤銷世代）照舊由 reconcile 立即做。
    /// cap nil＝沒接 ChatGPT build 的單機世界（自測）：等級照本機設定，專案一樣全部可見。兩條底線（金鑰、實盤）另外擋（HandsFloors.swift）。
    func centralized(by cap: (level: Int, projects: Set<String>)?) -> HandsSettings {
        var copy = self
        if let cap { copy.level = min(max(cap.level, 0), Self.maxLevel) }
        copy.allProjects = true
        return copy
    }

    /// 真正比對用的清單（精確比對，沒有萬用字元）。
    var effectiveCallbacks: [String] { chatgptCallbacks.isEmpty ? Self.defaultCallbacks : chatgptCallbacks }
}

enum HandsFileError: Error, CustomStringConvertible {
    case unsafe(String)
    var description: String {
        switch self { case .unsafe(let reason): "hands_file_\(reason)" }
    }
}

/// App 端的檔案讀寫：資料夾 0700、檔案 0600、只收一般檔、不跟隨捷徑、擁有者必須是自己。
enum HandsFiles {
    static func ensureDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw HandsFileError.unsafe("directory") }
            let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw HandsFileError.unsafe("directory_open") }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0 else {
                throw HandsFileError.unsafe("directory_mode")
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ensureDirectory(url)
    }

    static func restrictOwnedFile(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HandsFileError.unsafe("private_open") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, fchmod(fd, 0o600) == 0 else {
            throw HandsFileError.unsafe("private_mode")
        }
    }

    /// 原子寫入：同資料夾建 O_EXCL|O_NOFOLLOW 的 0600 暫存檔，寫完 fsync 再 rename 蓋過去。
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        var existing = stat()
        if lstat(url.path, &existing) == 0, (existing.st_mode & S_IFMT) != S_IFREG {
            throw HandsFileError.unsafe("not_regular")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw HandsFileError.unsafe("open_temp") }
        var ok = writeAll(fd, data)
        if ok { ok = fsync(fd) == 0 }
        _ = fchmod(fd, 0o600)
        close(fd)
        guard ok, Darwin.rename(temporary.path, url.path) == 0 else {
            _ = unlink(temporary.path)
            throw HandsFileError.unsafe("write")
        }
    }

    /// 建一個新檔（O_EXCL：已經有就失敗＝原子占位）。成功回 true。
    static func createExclusive(_ data: Data, at url: URL) throws -> Bool {
        try ensureDirectory(url.deletingLastPathComponent())
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else {
            if errno == EEXIST { return false }
            throw HandsFileError.unsafe("create")
        }
        defer { close(fd) }
        guard writeAll(fd, data), fsync(fd) == 0 else { throw HandsFileError.unsafe("write") }
        return true
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
    }

    /// 讀：不跟隨捷徑、必須是自己的一般檔、權限不能比 0600 寬、大小有上限。不合就回 nil（呼叫端當成空／關閉）。
    static func readSecure(_ url: URL, limit: Int = 4 * 1024 * 1024) -> Data? {
        guard (try? ensureDirectory(url.deletingLastPathComponent())) != nil else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0, info.st_size >= 0, Int(info.st_size) <= limit else { return nil }
        return readFD(fd, count: Int(info.st_size))
    }

    /// 從 offset 讀最多 count 個位元組（不跟隨捷徑、只收自己的一般檔）。
    static func readRange(_ url: URL, offset: Int, count: Int) -> (data: Data, total: Int)? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return nil }
        let total = Int(info.st_size)
        let start = min(max(offset, 0), total)
        let length = min(max(count, 0), total - start)
        guard lseek(fd, off_t(start), SEEK_SET) >= 0 else { return nil }
        guard let data = readFD(fd, count: length) else { return nil }
        return (data, total)
    }

    private static func readFD(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var total = 0
            while total < buffer.count {
                let n = Darwin.read(fd, base.advanced(by: total), buffer.count - total)
                if n < 0 { if errno == EINTR { continue }; return -1 }
                if n == 0 { break }
                total += n
            }
            return total
        }
        guard read >= 0 else { return nil }
        return data.prefix(read)
    }
}

/// W183 R3b 審查：關掉開關時設定檔寫不進去（例如磁碟滿）——不能讓舊的「開著」繼續運作。
/// 記憶體裡記下「這份設定檔強制關閉」（這個 App 行程內一直有效）：HandsSettingsStore.load 與關口的 HandsGatewayLaunch.readSettings
/// 都把它當成關的（撤銷、關口停下照常做）；之後有一次設定真的存進去了才解除（那時檔案就是使用者要的樣子）。
final class HandsForcedOff: @unchecked Sendable {
    static let shared = HandsForcedOff()
    private let lock = NSLock()
    private var paths: Set<String> = []

    /// 同一個檔案不管從哪條路徑來（/var 與 /private/var）都對得上。
    static func key(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    func set(_ url: URL, _ forced: Bool) {
        let key = Self.key(url)
        lock.lock(); if forced { paths.insert(key) } else { paths.remove(key) }; lock.unlock()
    }

    func contains(_ url: URL) -> Bool {
        let key = Self.key(url)
        lock.lock(); defer { lock.unlock() }
        return paths.contains(key)
    }
}

/// W183 R3b 審查：改設定的錯（畫面與副設備看得到的白話）。
enum HandsSettingsFailure: Error, Equatable, CustomStringConvertible {
    /// 要關掉：已經關了（撤銷全部連線、關口停下、這個 App 行程內保持關閉），但設定檔存不進去。
    case offButNotSaved
    /// W183 R11 第二輪（GPT-6 R11b 審查 2）：中央等級調高，但現有的連線還沒封頂成功（存不進去、授權檔也刪不掉）：本機等級先不往上改。
    case levelCapNotSaved
    var description: String {
        switch self {
        case .offButNotSaved: "已經關掉（所有 ChatGPT 連線作廢、關口停下），但設定存不進去（磁碟滿？）；App 開著期間會一直保持關閉，空出空間後再關一次"
        case .levelCapNotSaved: "現有的 ChatGPT 連線還沒能封頂存檔（磁碟滿或授權檔被鎖？）：先不調高這台的等級，這段期間 ChatGPT 的工具一律不收"
        }
    }
}

/// app/settings.json 的存取（每次呼叫都重讀，關掉開關立刻生效）。
final class HandsSettingsStore: @unchecked Sendable {
    let paths: HandsPaths
    private let lock = NSLock()
    var settingsURL: URL { paths.settingsFile }
    #if DEBUG
    /// 自測：模擬設定檔存不進去（磁碟滿）。
    var failSavesForTesting = false
    #endif

    init(paths: HandsPaths) { self.paths = paths }
    convenience init() { self.init(paths: .default) }

    /// 記憶體強制關閉（HandsForcedOff）時一律回「關」。
    func load() -> HandsSettings {
        lock.lock(); defer { lock.unlock() }
        guard let data = HandsFiles.readSecure(settingsURL, limit: 256 * 1024),
              var settings = try? JSONDecoder().decode(HandsSettings.self, from: data).normalized else { return HandsSettings() }
        if HandsForcedOff.shared.contains(settingsURL) { settings.enabled = false }
        return settings
    }

    /// 這份設定檔是不是正被記憶體強制關閉（存檔失敗後）。
    var forcedOff: Bool { HandsForcedOff.shared.contains(settingsURL) }

    func save(_ settings: HandsSettings) throws {
        lock.lock(); defer { lock.unlock() }
        #if DEBUG
        if failSavesForTesting { throw HandsFileError.unsafe("save_failed_for_testing") }
        #endif
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try HandsFiles.writeAtomically(try encoder.encode(settings.normalized), to: settingsURL)
    }

    /// 改設定：回（改之前, 改之後）。副作用（撤銷、收工作、鎖工作區）由 HandsService.updateSettings 處理。
    @discardableResult
    func update(_ change: (inout HandsSettings) -> Void) throws -> (old: HandsSettings, new: HandsSettings) {
        let old = load()
        var settings = old
        change(&settings)
        try save(settings)
        return (old, settings.normalized)
    }
}
