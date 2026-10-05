import Darwin
import Foundation

/// W74: one logical entrance on every device; do not resolve away the mini's symlink.
struct TatwoEntry {
    enum Status: String {
        case available
        case missing
        case brokenSymbolicLink
        case notDirectory
    }

    let root: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: String? = UserDefaults.standard.string(forKey: "tatwo2.osRoot"),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let path = [environment["TATWO_OS_ROOT"], environment["TATWO2_OS_ROOT"], preference]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let path {
            let expanded: String
            if path == "~" {
                expanded = homeDirectory.path
            } else if path.hasPrefix("~/") {
                expanded = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
            } else {
                expanded = path
            }
            // Keep the caller's spelling: standardizedFileURL strips /private and would
            // disagree with realpath-based callers; symlinks (the mini entrance) stay intact.
            root = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            root = homeDirectory.appendingPathComponent("AI/TATWO OS", isDirectory: true)
        }
    }

    var constitution: URL { root.appendingPathComponent("os.md") }
    var skillet: URL { root.appendingPathComponent("skillet.md") }
    var deviceJSON: URL { root.appendingPathComponent("device.json") }
    var gbrainDir: URL { root.appendingPathComponent("gbrain", isDirectory: true) }
    var noteDir: URL { root.appendingPathComponent("note", isDirectory: true) }
    var repoRoot: URL { root.appendingPathComponent("tatwo2", isDirectory: true) }
    var repoDocs: URL { repoRoot.appendingPathComponent("docs", isDirectory: true) }

    var exists: Bool { status == .available }

    var status: Status {
        let manager = FileManager.default
        var directory: ObjCBool = false
        if manager.fileExists(atPath: root.path, isDirectory: &directory) {
            return directory.boolValue ? .available : .notDirectory
        }
        // Also recognize a broken link in a parent component of the entrance.
        var candidate = root
        while candidate.path != "/" {
            if (try? manager.destinationOfSymbolicLink(atPath: candidate.path)) != nil,
               !manager.fileExists(atPath: candidate.path) {
                return .brokenSymbolicLink
            }
            candidate.deleteLastPathComponent()
        }
        return .missing
    }
}

// W183 R6c 審查（GPT-6）：入口的 `chatgpt/` 是外部 AI（ChatGPT 手腳）的工作區，內容一律當外部資料。
// 這是共用的判定，套在真正讀取、登錄、匯入、啟動的地方（不是只在掃描器上標警告）：
// - 技能：PluginsSource（技能清單）、TatwoSkillsDirectoryCatalog（技能目錄）——連到 chatgpt/ 的不收。
// - 記憶：UserMemory（Claude 記憶提案）、EngineMemoryLinks（Claude／Codex 記憶併入入口）——連到 chatgpt/ 的不讀、不標成引擎記憶。
// - 規則檔掃描：EngineRuleScanner。
// - 專案與引擎：新增既有資料夾、Coder 匯入不建在裡面；對話的引擎（sidecar）與 CLI 分頁的 AI 不在裡面啟動；手腳自己的專案檢查。
// 判定：真實路徑（解開捷徑）＋不分大小寫的字串比對＋檔案系統身分（裝置、inode）。身分那一步擋大小寫變體、
// `/System/Volumes/Data/...` 這類別名、上層被換成捷徑——只要真實位置的任何一層就是 chatgpt 資料夾本身，就算在裡面。
// 放在 TatwoEntry.swift、只靠 Foundation：既有的單獨編譯探針（plugins-liveness 等）只編那份檔案清單，不用改清單也編得過。
enum ExternalWorkspacePolicy {
    /// 跟手腳那邊的資料夾名稱同一個（自測、node 測試都比對）。
    static let folderName = "chatgpt"
    static let projectRefusal = "這個資料夾在入口的 chatgpt 裡（ChatGPT 的工作區，外部資料），不能當專案"
    static let engineRefusal = "這個專案的資料夾在入口的 chatgpt 裡（ChatGPT 的工作區，外部資料），引擎不在那裡啟動"

    #if DEBUG
    /// 自測：多認幾個假入口（staging 的入口不是自測建的那個）。
    final class EntryList: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        func get() -> [String] { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: [String]) { lock.lock(); value = newValue; lock.unlock() }
    }
    static let extraEntriesForTesting = EntryList()
    #endif

    /// 這台的入口（App 既有的入口解析，不寫死路徑）。
    static func entries(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var list = [TatwoEntry(environment: environment).root.path]
        #if DEBUG
        list += extraEntriesForTesting.get()
        #endif
        return list
    }

    struct Identity: Hashable {
        let device: Int32
        let inode: UInt64
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    /// 各入口的 chatgpt 資料夾（入口原樣與 realpath 兩種寫法；可能還不存在）。
    static func folders(_ entries: [String]) -> [String] {
        var result: [String] = []
        for entry in entries where !entry.isEmpty {
            for base in [entry, resolved(entry) ?? entry] {
                let folder = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/" + folderName
                if !result.contains(folder) { result.append(folder) }
            }
        }
        return result
    }

    /// path 在某個入口的 chatgpt/ 裡（含 chatgpt 本身）。resolvingLinks：true＝先解開所有捷徑再判定（讀檔、匯入、啟動用：
    /// 從外面連進 chatgpt/ 的也算）；false＝照寫的路徑判定、不解開捷徑（規則檔掃描用：放在外面、連進 chatgpt/ 的捷徑另外標出）。
    static func contains(_ path: String, entries: [String]? = nil, resolvingLinks: Bool = true) -> Bool {
        guard !path.isEmpty else { return false }
        let folders = Self.folders(entries ?? Self.entries())
        guard !folders.isEmpty else { return false }
        let located = resolvingLinks ? (resolved(path) ?? canonical(path)) : path
        // 1) 字串：不分大小寫（APFS 預設不分大小寫：ChatGPT/ 跟 chatgpt/ 是同一個資料夾）。
        for candidate in Set([path, located]) {
            let lowered = candidate.lowercased()
            if folders.contains(where: { isWithin(lowered, $0.lowercased()) }) { return true }
        }
        // 2) 身分：chatgpt 資料夾的（裝置、inode）是 located 的某一層＝在裡面（大小寫變體、/System/Volumes/Data 別名都抓得到）。
        var identities = Set<Identity>()
        for folder in folders {
            var info = stat()
            if stat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { identities.insert(Identity(info)) }
        }
        guard !identities.isEmpty else { return false }
        var current = located
        while !current.isEmpty {
            var info = stat()
            let found = resolvingLinks ? stat(current, &info) : lstat(current, &info)
            if found == 0, identities.contains(Identity(info)) { return true }
            let next = (current as NSString).deletingLastPathComponent
            if next == current { break }
            current = next
        }
        return false
    }

    static func contains(_ url: URL, entries: [String]? = nil) -> Bool { contains(url.path, entries: entries) }

    /// 對話引擎、CLI 分頁的 AI 要在這裡啟動：在 chatgpt/ 裡＝回一句話（不啟動）。
    static func engineProblem(cwd: String) -> String? { contains(cwd) ? engineRefusal : nil }

    // 路徑小工具（跟手腳的路徑工具同樣的做法；這裡自己帶，免得單獨編譯時拉進手腳的檔）。
    static func resolved(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func canonical(_ path: String) -> String {
        if let real = resolved(path) { return real }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, let real = resolved(parent) else { return path }
        return real + "/" + (path as NSString).lastPathComponent
    }

    static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
