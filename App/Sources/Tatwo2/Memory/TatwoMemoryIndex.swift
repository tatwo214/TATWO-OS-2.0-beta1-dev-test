import Foundation

/// W180 E1：入口 memory/ 裡的一條記憶（最上層一個 .md；索引檔、說明、imports/ 不算）。
struct TatwoMemoryEntry: Identifiable, Equatable, Sendable {
    /// 檔名（memory/ 最上層）。
    let id: String
    let file: TatwoMemoryFile
    let modifiedAt: Date
    let size: Int
    /// 這條是什麼時候記下的（不是最後修改）：開頭欄位的 created → git 第一次加進來的時間 → 還沒進 git 的新檔看檔案建立時間；
    /// 都查不到是 nil（不算「最近記下」）。只有背景掃檔會填；store.read() 只看開頭欄位。
    var createdAt: Date?
    /// 挑候選用（建立時算好一次）。
    let candidate: TatwoMemoryCandidate
    /// 記憶頁搜尋用：標題、說明、檔名、別名、全文轉小寫接起來（建立時算好一次，畫面重畫不再轉）。
    let searchKey: String

    init(id: String, file: TatwoMemoryFile, modifiedAt: Date, size: Int, createdAt: Date? = nil) {
        self.id = id
        self.file = file
        self.modifiedAt = modifiedAt
        self.size = size
        self.createdAt = createdAt ?? file.created.flatMap(TatwoMemoryFile.parseDate)
        let title = file.displayTitle(fileName: id)
        let summary = Self.summary(file: file, title: title)
        candidate = TatwoMemoryCandidate(id: id, title: title, summary: summary, aliases: file.aliases, body: file.content,
                                         modifiedAt: modifiedAt, isConflictCopy: file.isConflictCopy)
        searchKey = ([title, summary, id, file.content] + file.aliases).joined(separator: "\n").lowercased()
    }

    var title: String { candidate.title }

    /// 一行說明：description；沒有就內文第一行。跟標題一樣時是空的。
    var summary: String { candidate.summary }

    private static func summary(file: TatwoMemoryFile, title: String) -> String {
        let description = file.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text: String
        if description.isEmpty {
            let content = file.content
            let end = content.firstIndex(where: \.isNewline) ?? content.endIndex
            text = String(content[..<end]).trimmingCharacters(in: .whitespaces)
        } else {
            text = description
        }
        return text == title ? "" : String(text.prefix(160))
    }
}

/// 某一刻掃到的記憶資料夾。資料夾不在（例：主設備外接卷沒掛上）時 entries 是空的、folderExists 是 false。
struct TatwoMemorySnapshot: Sendable {
    let folder: URL
    let folderExists: Bool
    /// 最近修改的在前。
    let entries: [TatwoMemoryEntry]
    let feedback: [TatwoMemoryFeedback]
    let scannedAt: Date
    /// 掃檔時就備好（每一句直接拿來比，不再逐條重建）。
    let candidates: [TatwoMemoryCandidate]

    init(folder: URL, folderExists: Bool, entries: [TatwoMemoryEntry], feedback: [TatwoMemoryFeedback], scannedAt: Date) {
        self.folder = folder
        self.folderExists = folderExists
        self.entries = entries
        self.feedback = feedback
        self.scannedAt = scannedAt
        candidates = entries.map(\.candidate)
    }

    func entry(_ id: String) -> TatwoMemoryEntry? { entries.first { $0.id == id } }
}

/// W180 E1：記憶的快取。掃檔一律在背景佇列，主執行緒只讀快取（`cached()` 不等、不讀檔）；
/// 快取舊了（20 秒）、有人寫過（`invalidate()`）或資料夾換了，就排一次背景重掃，下一句才用得到。
/// `warm()` 之後背景每 20 秒自己重掃一次：Claude Code／Codex 直接寫進 memory/ 的、同步拉下來的、手動改的，
/// 閒置很久之後的第一句也拿得到（最多晚 20 秒）。只重新解析有變的檔（照修改時間與大小），
/// git 只在 HEAD 變了才問一次（查每條第一次加進來的時間）。不建 GBrain 索引（主導 W180 裁決 8）。
/// E1b 的同步拉完新版時叫 `invalidate()` 就立刻重掃。
final class TatwoMemoryIndex: @unchecked Sendable {
    static let shared = TatwoMemoryIndex()
    static let staleAfter: TimeInterval = 20
    /// 一條記憶檔最大讀多少（再大的不收）。
    static let maxFileBytes = 1 << 20

    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.memory-index", qos: .utility)
    private let lock = NSLock()
    private var current: TatwoMemorySnapshot?
    private var dirty = true
    private var scanning = false
    private var waiters: [CheckedContinuation<TatwoMemorySnapshot, Never>] = []
    private var override: URL?
    /// 只在背景佇列上讀寫。
    private var parsedCache: [String: (modified: Date, size: Int, entry: TatwoMemoryEntry)] = [:]
    /// 只在背景佇列上讀寫：git 裡每個檔最近一次被加進來的時間（照 HEAD 快取）。
    private var addedCache: (folder: String, head: String, ok: Bool, dates: [String: Date])?
    private var timer: DispatchSourceTimer?

    /// 自測用：固定看這個資料夾（nil＝入口的 memory/，跟著 TATWO_OS_ROOT）。
    var folderOverride: URL? {
        get { lock.lock(); defer { lock.unlock() }; return override }
        set { lock.lock(); override = newValue; dirty = true; lock.unlock() }
    }

    func folder() -> URL { folderOverride ?? EngineMemoryPaths().memory }

    /// 主執行緒用：回快取（還沒掃過是 nil），需要時在背景重掃，不等。
    func cached() -> TatwoMemorySnapshot? {
        let folder = folder()
        lock.lock()
        let snapshot = current
        let stale = dirty || snapshot == nil || snapshot?.folder != folder
            || Date().timeIntervalSince(snapshot?.scannedAt ?? .distantPast) > Self.staleAfter
        lock.unlock()
        if stale { refresh() }
        return snapshot?.folder == folder ? snapshot : nil
    }

    /// App 啟動、引擎建立時先掃一次，第一句就有得用；之後背景每 20 秒重掃一次（只看修改時間，沒變的不重讀）。
    func warm() {
        refresh()
        lock.lock()
        let start = timer == nil
        if start {
            let tick = DispatchSource.makeTimerSource(queue: queue)
            tick.schedule(deadline: .now() + Self.staleAfter, repeating: Self.staleAfter, leeway: .seconds(5))
            tick.setEventHandler { [weak self] in self?.refresh() }
            timer = tick
        }
        let started = timer
        lock.unlock()
        if start { started?.resume() }
    }

    /// 記憶頁、記憶工具寫過檔之後叫：下一次一定重掃。
    func invalidate() {
        lock.lock(); dirty = true; lock.unlock()
        refresh()
    }

    /// 背景重掃完才回（記憶頁、記憶工具、自測用；不要在主執行緒同步等）。
    func reload() async -> TatwoMemorySnapshot {
        await withCheckedContinuation { continuation in
            lock.lock()
            dirty = true
            waiters.append(continuation)
            lock.unlock()
            refresh()
        }
    }

    private func refresh() {
        lock.lock()
        guard !scanning else { lock.unlock(); return }
        scanning = true
        lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                dirty = false
                lock.unlock()
                let snapshot = scan(folder: folder())
                lock.lock()
                current = snapshot
                // 掃的時候又有人寫過：再掃一次，等的人拿最新的。
                if dirty { lock.unlock(); continue }
                scanning = false
                let ready = waiters
                waiters = []
                lock.unlock()
                for waiter in ready { waiter.resume(returning: snapshot) }
                return
            }
        }
    }

    /// 只在背景佇列上跑。
    private func scan(folder: URL) -> TatwoMemorySnapshot {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        var entries: [TatwoMemoryEntry] = []
        var seen = Set<String>()
        if exists {
            for name in EngineMemoryLinks.memoryItems(in: folder) {
                let url = folder.appendingPathComponent(name, isDirectory: false)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                                     .contentModificationDateKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= Self.maxFileBytes else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                let key = folder.path + "/" + name
                seen.insert(key)
                if let cached = parsedCache[key], cached.modified == modified, cached.size == size {
                    entries.append(cached.entry)
                    continue
                }
                guard let data = try? Data(contentsOf: url) else { continue }
                let entry = TatwoMemoryEntry(id: name, file: TatwoMemoryFile.parse(String(decoding: data, as: UTF8.self)),
                                             modifiedAt: modified, size: size)
                parsedCache[key] = (modified, size, entry)
                entries.append(entry)
            }
        }
        parsedCache = parsedCache.filter { seen.contains($0.key) }
        if exists { entries = withCreatedDates(entries, folder: folder) }
        entries.sort { $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.id < $1.id }
        return TatwoMemorySnapshot(folder: folder, folderExists: exists, entries: entries,
                                   feedback: exists ? Self.readFeedback(folder) : [], scannedAt: Date())
    }

    /// 每條補上「記下的時間」：開頭欄位的 created 優先；再來是 git 最近一次把它加進來的時間；
    /// git 查得到、但這個檔還沒進 git（剛寫的新檔）就看檔案建立時間；git 查不到就留 nil（不當成最近記下）。
    /// 只在背景佇列上跑。
    private func withCreatedDates(_ entries: [TatwoMemoryEntry], folder: URL) -> [TatwoMemoryEntry] {
        let added = addedDates(folder: folder)
        return entries.map { entry in
            guard entry.createdAt == nil else { return entry }
            var dated = entry
            if let date = added.dates[entry.id] {
                dated.createdAt = date
            } else if added.ok {
                let url = folder.appendingPathComponent(entry.id, isDirectory: false)
                dated.createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            }
            return dated
        }
    }

    /// git 裡每個檔最近一次被加進來的時間。HEAD 沒變就用上次的（不另開 git）；不是 git 或 git 失敗回 ok=false。
    private func addedDates(folder: URL) -> (ok: Bool, dates: [String: Date]) {
        guard let head = Self.headKey(folder) else { return (false, [:]) }
        if let cached = addedCache, cached.folder == folder.path, cached.head == head { return (cached.ok, cached.dates) }
        let result = EngineMemoryLinks.git(["-c", "core.quotePath=false", "log", "--no-renames", "--diff-filter=A",
                                            "--format=%x01%at", "--name-only"], in: folder)
        var dates: [String: Date] = [:]
        var current: Date?
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("\u{1}") {
                current = TimeInterval(line.dropFirst()).map { Date(timeIntervalSince1970: $0) }
            } else if let current, !line.contains("/") {
                // 由新到舊：第一次看到的就是最近一次加進來的（刪掉又加回來的算新的）。
                let name = String(line)
                if dates[name] == nil { dates[name] = current }
            }
        }
        let ok = result.status == 0
        addedCache = (folder.path, head, ok, ok ? dates : [:])
        return (ok, ok ? dates : [:])
    }

    /// 目前的 HEAD（分支名＋它指到的 commit）；只讀 .git 底下的小檔，不開 git。不是 git 回 nil。
    static func headKey(_ folder: URL) -> String? {
        let git = folder.appendingPathComponent(".git", isDirectory: true)
        guard let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        guard head.hasPrefix("ref: ") else { return head }
        let ref = String(head.dropFirst(5))
        guard !ref.contains(".."), ref.hasPrefix("refs/") else { return head }
        if let value = try? String(contentsOf: git.appendingPathComponent(ref), encoding: .utf8) {
            return head + "@" + value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 已經打包的 ref：看 packed-refs 裡那一行。
        let packed = (try? String(contentsOf: git.appendingPathComponent("packed-refs"), encoding: .utf8)) ?? ""
        let line = packed.split(separator: "\n").first { $0.hasSuffix(" " + ref) }
        return head + "@" + (line.map(String.init) ?? "unborn")
    }

    /// memory/.tatwo/feedback-<設備>.json：每台一檔（跟著記憶同步），全部讀進來。
    static func readFeedback(_ folder: URL) -> [TatwoMemoryFeedback] {
        let directory = folder.appendingPathComponent(".tatwo", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [TatwoMemoryFeedback] = []
        for name in names.sorted() where name.hasPrefix("feedback-") && name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) <= 2 << 20,
                  let data = try? Data(contentsOf: url),
                  let rows = try? decoder.decode([TatwoMemoryFeedback].self, from: data) else { continue }
            result += rows.suffix(TatwoMemoryStore.maxFeedbackPerDevice)
        }
        return result
    }
}

/// W180 E1：每一條最近被帶進對話幾次（「最近常用」加分用）。放在這台 live/ 底下，不進記憶的 git。
/// 讀寫檔都在背景；主執行緒只拿記憶體裡的那份（還沒讀好就是空的）。
final class TatwoMemoryUsageStats: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: TatwoMemoryUsageStats] = [:]

    /// 同一個 live/ 共用一份。
    static func at(_ liveRoot: URL) -> TatwoMemoryUsageStats {
        let url = liveRoot.appendingPathComponent("memory-usage.json", isDirectory: false)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[url.path] { return existing }
        let stats = TatwoMemoryUsageStats(url: url)
        registry[url.path] = stats
        return stats
    }

    private let url: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.memory-usage", qos: .utility)
    private var uses: [String: TatwoMemoryUse] = [:]
    private var loaded = false
    private var loading = false

    private init(url: URL) { self.url = url }

    func warm() {
        lock.lock()
        guard !loaded, !loading else { lock.unlock(); return }
        loading = true
        lock.unlock()
        queue.async { [self] in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: TatwoMemoryUse].self, from: $0) } ?? [:]
            lock.lock()
            // 讀檔期間記下的也留著。
            for (id, use) in stored where uses[id] == nil { uses[id] = use }
            loaded = true
            loading = false
            lock.unlock()
        }
    }

    func snapshot() -> [String: TatwoMemoryUse] {
        lock.lock()
        let result = uses
        let needsLoad = !loaded
        lock.unlock()
        if needsLoad { warm() }
        return result
    }

    func record(_ ids: [String], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        lock.lock()
        for id in Set(ids) {
            var use = uses[id] ?? TatwoMemoryUse(count: 0, last: date)
            use.count += 1
            use.last = date
            uses[id] = use
        }
        // 只留最近用過的 500 條，檔案不長大。
        if uses.count > 500 {
            let keep = uses.sorted { $0.value.last > $1.value.last }.prefix(500)
            uses = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let copy = uses
        lock.unlock()
        queue.async { [url] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? encoder.encode(copy) { try? data.write(to: url, options: .atomic) }
        }
    }
}
