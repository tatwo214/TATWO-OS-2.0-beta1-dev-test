import CryptoKit
import Foundation

// W182 R4（使用者 09-27：「如果主設備斷線呢？我的macbook就完全變空白傻傻的是嗎？」→「好 照這樣做」）：
// 每台配對設備最後一次拿到的文件（專案、討論串標題、狀態、最後活動）與最近讀過的逐則內容，存在這台
// live/remote-cache/<設備id>/。那台連不上時畫面照樣列出、可以讀、可以「在這台接著聊」。
// 只給畫面用（W110：不開工具給 OS 內的 AI 讀別台歷史）；檔案讀寫一律在自己的序列佇列（背景），主執行緒只收結果；
// 檔案壞了就當沒有。

// MARK: - 存檔格式

/// 一台設備最後同步到的文件。每條只留最後一兩則（側欄預覽用），逐則內容另外存。
struct RemoteOfflineSnapshot: Codable, Equatable, @unchecked Sendable {   // 純資料，跨背景佇列傳遞
    static let currentVersion = 1
    var version: Int
    var deviceID: String
    var deviceName: String
    /// 最後一次跟那台同步成功的時間（側欄「離線・最後同步 N 分鐘前」）。
    var syncedAt: Date
    var revision: Int64
    var document: LiveDocumentRecord

    init(deviceID: String, deviceName: String, syncedAt: Date, revision: Int64, document: LiveDocumentRecord) {
        self.version = Self.currentVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.syncedAt = syncedAt
        self.revision = revision
        self.document = document
    }

    /// 側欄預覽只要一小段。
    static let previewChars = 300
    /// 主設備助理那條留幾則、每則幾個字（給斷線接手的前情；總量由 CoderImport.seedPrompt 的上限管）。
    static let assistantContextRows = 40
    static let assistantContextChars = 2_000

    /// 存檔前瘦身：封存的串不存（離線時畫面不列，助理那條除外）；每條只留最後一則「訊息」當預覽、截到幾百字；
    /// 分頁、房間簡報、issue 不存。串一多也不會把每台的額度吃光。
    func slimmed() -> RemoteOfflineSnapshot {
        var copy = self
        let full = copy.document
        copy.document.threads = full.threads.filter { !$0.isArchived || full.isAssistantThread($0.id) }
        for index in copy.document.threads.indices {
            let rows = copy.document.threads[index].messages
            if full.isAssistantThread(copy.document.threads[index].id) {
                // W182 R4＋R5 併入：主設備的助理那條多留最近幾十則問答（每則截短），App 重開後主設備還沒連上時，
                // 這台助理接手的第一句才帶得到前情（AssistantOfflineHandoff 讀這裡）。
                copy.document.threads[index].messages = rows
                    .filter { $0.eventKind == "message" && !$0.isMemoryUsageRow && ($0.role == "user" || $0.role == "assistant") }
                    .suffix(Self.assistantContextRows)
                    .map { row in
                        guard row.text.count > Self.assistantContextChars else { return row }
                        var short = row
                        short.text = String(row.text.prefix(Self.assistantContextChars)) + "…"
                        return short
                    }
                copy.document.threads[index].cliTabs = []
                copy.document.threads[index].roomBrief = nil
                copy.document.threads[index].issues = []
                continue
            }
            let preview = rows.last(where: { $0.eventKind == "message" && !$0.isMemoryUsageRow })
            copy.document.threads[index].messages = preview.map { row in
                guard row.text.count > Self.previewChars else { return [row] }
                var short = row
                short.text = String(row.text.prefix(Self.previewChars)) + "…"
                return [short]
            } ?? []
            copy.document.threads[index].cliTabs = []
            copy.document.threads[index].roomBrief = nil
            copy.document.threads[index].issues = []
        }
        return copy
    }

    /// 畫面用的投影（跟 RemoteLiveEngine.document 同一套規則）；離線時不顯示「執行中」這類活性。
    var projection: TatwoNativeChatStoreDocument {
        TatwoNativeChatStoreDocument(projects: document.projects.map { project in
            TatwoNativeChatProject(
                id: project.id,
                name: project.name,
                workdir: project.workdir,
                isExpanded: project.isExpanded,
                threads: document.threads
                    .filter { $0.projectID == project.id && !$0.isArchived }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map { thread in
                        TatwoNativeChatThread(
                            id: thread.id,
                            title: thread.title,
                            isPinned: thread.isPinned,
                            lastPreview: thread.messages.last(where: { $0.eventKind == "message" && !$0.isMemoryUsageRow })?.text ?? "",
                            parentThreadID: thread.parentThreadID,
                            liveness: nil,
                            lastOutputAt: thread.lastOutputAt,
                            engineLabel: thread.engine)
                    },
                githubRepos: project.githubRepos.map { TatwoGitHubRepoBinding(url: $0) })
        }, generalProjectID: document.generalProjectID, assistantProjectID: document.assistantProjectID)
    }
}

/// 快取裡一條討論串的逐則內容（最後 N 則）。
struct RemoteOfflineTranscript: Codable, @unchecked Sendable {
    static let currentVersion = 1
    var version: Int = RemoteOfflineTranscript.currentVersion
    var threadID: UUID
    var savedAt: Date
    /// 那條當時共幾則（只存最後幾則）。
    var totalMessages: Int
    var messages: [LiveMessageRecord]
}

/// 快取裡有內容的一條：多大、什麼時候存的（照最舊的丟）。
struct RemoteOfflineCacheEntry: Equatable, Sendable {
    let threadID: UUID
    let bytes: Int
    let savedAt: Date
}

// MARK: - 檔案（只在背景佇列）

final class RemoteOfflineCache: @unchecked Sendable {   // 不可變設定＋靜態佇列；檔案操作只在 queue 上
    struct Limits: Equatable, Sendable {
        /// 每台最多存幾條的內容。
        var threads = 30
        /// 每條最多存最後幾則。
        var messagesPerThread = 200
        /// 每台總量（含文件）。
        var bytes = 20 * 1024 * 1024
        /// 一則太長時只存前面一段。
        var charsPerMessage = 20_000
        /// 文件（專案與串清單）自己的上限：寫與讀同一條規則（超過就不寫，讀到也當沒有）。
        var documentBytes = 4 * 1024 * 1024
    }

    enum CacheError: LocalizedError {
        case documentTooLarge(Int)
        var errorDescription: String? {
            switch self {
            case .documentTooLarge(let bytes):
                return "離線副本的專案清單太大（\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))），這次沒存"
            }
        }
    }

    static let folderName = "remote-cache"
    static let standard = Limits()
    static let truncatedSuffix = "…（離線副本只存前面一段）"
    /// 所有離線副本的檔案讀寫都排在這一條（全域一條：同一台的新舊 session 也不會同時寫）。
    static let queue = DispatchQueue(label: "ai.tatwo.tatwo2.remote-offline-cache", qos: .utility)
    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var mainThreadIO = 0
    #if DEBUG
    /// 自測用：清除時搬到自測自己的資料夾，不碰真的垃圾桶。
    nonisolated(unsafe) static var testRetire: ((URL) throws -> Void)?
    #endif

    let root: URL
    let limits: Limits

    init(root: URL, limits: Limits = RemoteOfflineCache.standard) {
        self.root = root
        self.limits = limits
    }

    /// live/remote-cache（live 跟 Coder 的 document.json 同一層；自測時是 TATWO2_LIVE_ROOT）。
    static func defaultRoot(environment: [String: String]) -> URL {
        let live = environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        return live.appendingPathComponent(folderName, isDirectory: true)
    }

    /// 設備 id 當資料夾名：只收安全字元，其他（或太長）改用雜湊，不讓 id 跳出 remote-cache。
    static func folderName(deviceID: String) -> String {
        let safe = deviceID.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ".")
        }
        if safe, !deviceID.isEmpty, deviceID.count <= 80, !deviceID.hasPrefix(".") { return deviceID }
        return "id-" + SHA256.hash(data: Data(deviceID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func folder(_ deviceID: String) -> URL {
        root.appendingPathComponent(Self.folderName(deviceID: deviceID), isDirectory: true)
    }
    func documentURL(_ deviceID: String) -> URL { folder(deviceID).appendingPathComponent("document.json") }
    func threadsFolder(_ deviceID: String) -> URL { folder(deviceID).appendingPathComponent("threads", isDirectory: true) }
    func transcriptURL(_ deviceID: String, _ threadID: UUID) -> URL {
        threadsFolder(deviceID).appendingPathComponent(threadID.uuidString + ".json")
    }

    /// 自測：主執行緒碰過離線副本檔案幾次（應該永遠是 0）。
    static var mainThreadIOCount: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return mainThreadIO
    }

    private func noteIO() {
        guard Thread.isMainThread else { return }
        Self.counterLock.lock(); Self.mainThreadIO += 1; Self.counterLock.unlock()
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: 同步版（只在 queue 上叫）

    /// 讀不到、太大、解不開、版本或設備不對＝沒有（不丟錯、不影響啟動）。
    func readSnapshot(deviceID: String) -> RemoteOfflineSnapshot? {
        noteIO()
        guard let data = try? Data(contentsOf: documentURL(deviceID)), data.count <= limits.documentBytes,
              let snapshot = try? Self.decoder().decode(RemoteOfflineSnapshot.self, from: data),
              snapshot.version == RemoteOfflineSnapshot.currentVersion, snapshot.deviceID == deviceID else { return nil }
        return snapshot
    }

    /// 瘦身後原子寫入；回傳寫了多少位元組。超過文件上限就不寫（留一行記錄；磁碟上那份保持原樣），跟讀的規則一致。
    @discardableResult
    func writeSnapshot(_ snapshot: RemoteOfflineSnapshot) throws -> Int {
        noteIO()
        let data = try Self.encoder().encode(snapshot)
        guard data.count <= limits.documentBytes else {
            NSLog("remote-offline-cache: document too large (%d bytes > %d), not written", data.count, limits.documentBytes)
            throw CacheError.documentTooLarge(data.count)
        }
        try FileManager.default.createDirectory(at: folder(snapshot.deviceID), withIntermediateDirectories: true)
        try data.write(to: documentURL(snapshot.deviceID), options: .atomic)
        return data.count
    }

    func readTranscript(deviceID: String, threadID: UUID) -> RemoteOfflineTranscript? {
        noteIO()
        guard let data = try? Data(contentsOf: transcriptURL(deviceID, threadID)), data.count <= limits.bytes,
              let file = try? Self.decoder().decode(RemoteOfflineTranscript.self, from: data),
              file.version == RemoteOfflineTranscript.currentVersion, file.threadID == threadID else { return nil }
        return file
    }

    /// 只存最後幾則、每則太長的截前面一段；原子寫入，檔案時間＝存的時間（照最舊的丟用）。寫完照上限清一次，回傳剩下的。
    @discardableResult
    func writeTranscript(deviceID: String, threadID: UUID, messages: [LiveMessageRecord],
                         savedAt: Date = Date()) throws -> [RemoteOfflineCacheEntry] {
        noteIO()
        let file = RemoteOfflineTranscript(threadID: threadID, savedAt: savedAt, totalMessages: messages.count,
                                           messages: Self.trim(messages, limits: limits))
        let data = try Self.encoder().encode(file)
        try FileManager.default.createDirectory(at: threadsFolder(deviceID), withIntermediateDirectories: true)
        let url = transcriptURL(deviceID, threadID)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: savedAt], ofItemAtPath: url.path)
        return enforceLimits(deviceID: deviceID)
    }

    /// 又讀了一次、內容沒變：不重寫，只把檔案時間改成這次讀的時間（上限照「最近讀過」丟最舊的）。
    /// 檔案已經不在（被上限丟了或清掉）回 false。
    func touchTranscript(deviceID: String, threadID: UUID, at date: Date = Date()) -> Bool {
        noteIO()
        let url = transcriptURL(deviceID, threadID)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return true
    }

    static func trim(_ messages: [LiveMessageRecord], limits: Limits) -> [LiveMessageRecord] {
        messages.suffix(limits.messagesPerThread).map { row in
            guard row.text.count > limits.charsPerMessage else { return row }
            var short = row
            short.text = String(row.text.prefix(limits.charsPerMessage)) + truncatedSuffix
            return short
        }
    }

    /// 有存內容的每一條（檔名是討論串 id）。
    func entries(deviceID: String) -> [RemoteOfflineCacheEntry] {
        noteIO()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: threadsFolder(deviceID), includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return RemoteOfflineCacheEntry(threadID: id, bytes: values.fileSize ?? 0,
                                           savedAt: values.contentModificationDate ?? .distantPast)
        }
    }

    func documentBytes(deviceID: String) -> Int {
        noteIO()
        return (try? documentURL(deviceID).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// 超過上限（條數、總量含文件）照最舊的丟（檔案時間＝最後寫入或最後又讀到的時間，見 touchTranscript）。
    /// 這是快取：丟掉的只是這台的副本，那台的原串不受影響。
    func enforceLimits(deviceID: String) -> [RemoteOfflineCacheEntry] {
        var rows = entries(deviceID: deviceID).sorted {
            $0.savedAt == $1.savedAt ? $0.threadID.uuidString < $1.threadID.uuidString : $0.savedAt < $1.savedAt
        }
        var total = rows.reduce(documentBytes(deviceID: deviceID)) { $0 + $1.bytes }
        while !rows.isEmpty, rows.count > limits.threads || total > limits.bytes {
            let oldest = rows.removeFirst()
            try? FileManager.default.removeItem(at: transcriptURL(deviceID, oldest.threadID))
            total -= oldest.bytes
        }
        return rows
    }

    /// 移除設備時：整個資料夾移到垃圾桶（可以放回），不直接刪。沒有副本回 false。
    @discardableResult
    func clear(deviceID: String) throws -> Bool {
        noteIO()
        let target = self.folder(deviceID)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        #if DEBUG
        if let testRetire = Self.testRetire { try testRetire(target); return true }
        #endif
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        return true
    }

    // MARK: 非同步

    /// 在背景佇列做，做完照順序回主執行緒。
    func run<T>(_ work: @escaping (RemoteOfflineCache) -> T, then completion: @escaping @MainActor (T) -> Void) {
        let box = RemoteOfflineWork(work: work, completion: completion)
        Self.queue.async { [self] in
            let result = RemoteOfflineResult(box.work(self))
            DispatchQueue.main.async { MainActor.assumeIsolated { box.completion(result.value) } }
        }
    }

    /// 等前面排的讀寫（連同它們回主執行緒的那一步）都做完。
    static func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }
}

/// 跨佇列傳遞的小盒子（閉包與結果只在排好的順序裡用一次）。
private final class RemoteOfflineWork<T>: @unchecked Sendable {
    let work: (RemoteOfflineCache) -> T
    let completion: @MainActor (T) -> Void
    init(work: @escaping (RemoteOfflineCache) -> T, completion: @escaping @MainActor (T) -> Void) {
        self.work = work
        self.completion = completion
    }
}

private final class RemoteOfflineResult<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - 一台設備的離線副本（記憶體＋磁碟）

/// 每個 RemoteDeviceSession 一個。連線時記下每次拿到的文件與讀過的內容（背景存檔）；
/// 離線時提供側欄、Coder 唯讀畫面、私訊框用的快照與內容（沒在記憶體的從磁碟背景讀）。
@MainActor
final class RemoteOfflineMirror {
    let deviceID: String
    let deviceName: String
    let cache: RemoteOfflineCache
    /// 最後同步到的文件（已瘦身）；nil＝從沒同步過、檔案壞了或清掉了。
    private(set) var snapshot: RemoteOfflineSnapshot? { didSet { activityCache = nil } }
    /// 最後一次同步成功的時間（連線時每次輪詢都更新；寫檔最多每分鐘一次，除非換版）。
    private(set) var syncedAt: Date?
    /// 有存內容的那幾條。
    private(set) var entries: [UUID: RemoteOfflineCacheEntry] = [:]
    /// 磁碟那份讀過了（App 剛開時還在讀）。
    private(set) var diskLoaded = false
    private(set) var documentBytes = 0
    private var transcripts: [UUID: [ChatMessage]] = [:]
    private var loading: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<[ChatMessage]?, Never>]] = [:]
    private var lastWrittenRevision: Int64?
    private var lastWrittenAt = Date.distantPast
    /// 那台忙著換版時先記著最後一份，最多每 documentWriteInterval 寫一次；斷線時補寫（flushPendingDocument）。
    private var pendingDocument: (document: LiveDocumentRecord, revision: Int64, at: Date)?
    private var lastTranscriptSignature: [UUID: String] = [:]
    /// 每條最後一次寫檔或改檔案時間（內容沒變時最多每 transcriptTouchInterval 改一次）。
    private var lastTranscriptTouch: [UUID: Date] = [:]
    /// 已經排了、還沒寫完的內容檔（別條寫完清理時不要誤清它）。
    private var pendingTranscriptWrites: [UUID: Int] = [:]
    /// 清掉之後遞增，晚到的背景結果就丟掉。
    private var generation = 0
    /// 設備移除了：之後不再記任何東西（晚到的輪詢結果也不會把資料夾寫回來）。
    private(set) var isRetired = false
    static let documentWriteInterval: TimeInterval = 20
    static let transcriptTouchInterval: TimeInterval = 30
    /// 讀完磁碟、讀好一條內容、清掉時叫（session 用來重畫側欄與畫面）。
    var onChange: (() -> Void)?

    init(deviceID: String, deviceName: String, cache: RemoteOfflineCache) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.cache = cache
    }

    /// App 開著時第一次：背景讀這台上次存的文件與有內容的清單。已經有新的（剛連上）就不蓋掉。
    func loadFromDisk() {
        let id = deviceID, token = self.generation
        cache.run({ cache in (cache.readSnapshot(deviceID: id), cache.entries(deviceID: id), cache.documentBytes(deviceID: id)) }) {
            [weak self] loaded in
            guard let self, token == self.generation else { return }
            self.diskLoaded = true
            if self.snapshot == nil, let snapshot = loaded.0 {
                self.snapshot = snapshot
                self.syncedAt = max(self.syncedAt ?? .distantPast, snapshot.syncedAt)
                self.documentBytes = loaded.2
            }
            for entry in loaded.1 where self.entries[entry.threadID] == nil { self.entries[entry.threadID] = entry }
            self.onChange?()
        }
    }

    /// 連線時每次拿到文件（含 revision 沒變的輪詢）：記下同步時間；換版、或上次寫檔超過一分鐘才背景寫一次。
    /// 那台忙著一直換版時最多每 20 秒寫一次（中間的先記著，斷線時補寫）；force＝剛連上，馬上換成最新的。
    func record(document: LiveDocumentRecord, revision: Int64, now: Date = Date(), force: Bool = false) {
        guard !isRetired else { return }
        syncedAt = now
        let changed = revision != lastWrittenRevision
        guard changed || now.timeIntervalSince(lastWrittenAt) >= 60 else { return }
        if changed, !force, now.timeIntervalSince(lastWrittenAt) < Self.documentWriteInterval {
            pendingDocument = (document, revision, now)
            return
        }
        writeDocument(document, revision: revision, at: now)
    }

    /// 斷線那一刻：還沒寫的最後一份補寫進去（同步時間照它當時的）。
    func flushPendingDocument() {
        guard !isRetired, let pending = pendingDocument else { return }
        writeDocument(pending.document, revision: pending.revision, at: pending.at)
    }

    private func writeDocument(_ document: LiveDocumentRecord, revision: Int64, at now: Date) {
        pendingDocument = nil
        lastWrittenRevision = revision
        lastWrittenAt = now
        let raw = RemoteOfflineSnapshot(deviceID: deviceID, deviceName: deviceName, syncedAt: now, revision: revision,
                                        document: document)
        let token = self.generation
        cache.run({ cache -> (RemoteOfflineSnapshot, Int) in
            let slim = raw.slimmed()
            return (slim, (try? cache.writeSnapshot(slim)) ?? 0)
        }) { [weak self] written in
            guard let self, token == self.generation else { return }
            // 寫不進去（例如磁碟滿）也留在記憶體：這次開著時斷線照樣看得到。
            self.snapshot = written.0
            if written.1 > 0 { self.documentBytes = written.1 }
        }
    }

    /// 連線時讀到某條的逐則內容：記在記憶體（最後幾則）、背景存檔並照上限清舊的。
    /// 內容沒變就不重寫，只把檔案時間改成這次讀的（上限照「最近讀過」丟）；被上限丟掉的那條下次讀到會重寫。
    func record(transcript records: [LiveMessageRecord], threadID: UUID, now: Date = Date()) {
        guard !isRetired else { return }
        transcripts[threadID] = records.suffix(cache.limits.messagesPerThread).map(\.chatMessage)
        let last = records.last
        let signature = "\(records.count)|\(last?.id ?? "")|\(last?.text.utf8.count ?? 0)|\(last?.status ?? "")"
        let id = deviceID, token = self.generation
        guard lastTranscriptSignature[threadID] != signature else {
            guard now.timeIntervalSince(lastTranscriptTouch[threadID] ?? .distantPast) >= Self.transcriptTouchInterval else { return }
            lastTranscriptTouch[threadID] = now
            cache.run({ cache in cache.touchTranscript(deviceID: id, threadID: threadID, at: now) }) { [weak self] exists in
                guard let self, token == self.generation, !exists, self.pendingTranscriptWrites[threadID] == nil else { return }
                // 檔案已經不在（被上限丟了）：剛讀到的這份重寫回去。
                self.lastTranscriptSignature[threadID] = nil
                self.record(transcript: records, threadID: threadID, now: now)
            }
            return
        }
        lastTranscriptSignature[threadID] = signature
        lastTranscriptTouch[threadID] = now
        pendingTranscriptWrites[threadID, default: 0] += 1
        cache.run({ cache in try? cache.writeTranscript(deviceID: id, threadID: threadID, messages: records, savedAt: now) }) {
            [weak self] rows in
            guard let self, token == self.generation else { return }
            let left = (self.pendingTranscriptWrites[threadID] ?? 1) - 1
            self.pendingTranscriptWrites[threadID] = left > 0 ? left : nil
            guard let rows else {
                self.lastTranscriptSignature[threadID] = nil   // 沒寫進去（例如磁碟滿）：下次讀到再試
                return
            }
            self.entries = Dictionary(rows.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first })
            // 被上限丟掉的那幾條：記憶體與簽章都不留（上限對畫面一樣生效；之後再讀到會重寫回磁碟）。
            // 排了還沒寫完的不算（它的檔案等一下才會出現）。
            let known = Set(self.transcripts.keys).union(self.lastTranscriptSignature.keys)
            for key in known where self.entries[key] == nil && self.pendingTranscriptWrites[key] == nil { self.forget(key) }
        }
    }

    private func forget(_ threadID: UUID) {
        transcripts[threadID] = nil
        lastTranscriptSignature[threadID] = nil
        lastTranscriptTouch[threadID] = nil
    }

    // MARK: 離線時讀

    func thread(_ threadID: UUID) -> LiveThreadRecord? {
        snapshot?.document.threads.first { $0.id == threadID }
    }

    /// 快照裡有這條（離線時可以打開唯讀畫面）；助理那條不算。
    func hasThread(_ threadID: UUID) -> Bool {
        guard let doc = snapshot?.document else { return false }
        return doc.threads.contains { $0.id == threadID } && !doc.isAssistantThread(threadID)
    }

    /// 那條有存內容（記憶體或磁碟）。
    func hasTranscript(_ threadID: UUID) -> Bool { transcripts[threadID] != nil || entries[threadID] != nil }

    func isLoading(_ threadID: UUID) -> Bool { loading.contains(threadID) }

    /// 畫面讀：在記憶體就回；磁碟有就排一次背景讀（先回 nil，讀好會叫 onChange）；沒有回 nil。
    func transcript(for threadID: UUID) -> [ChatMessage]? {
        if let cached = transcripts[threadID] { return cached }
        if entries[threadID] != nil { load(threadID) }
        return nil
    }

    /// 等它讀好（「在這台接著聊」與 R5 助理前情用）；沒有存就是 nil。
    func loadTranscript(_ threadID: UUID) async -> [ChatMessage]? {
        if let cached = transcripts[threadID] { return cached }
        guard entries[threadID] != nil else { return nil }
        return await withCheckedContinuation { continuation in
            waiters[threadID, default: []].append(continuation)
            load(threadID)
        }
    }

    private func load(_ threadID: UUID) {
        guard loading.insert(threadID).inserted else { return }
        let id = deviceID, token = self.generation
        cache.run({ cache in cache.readTranscript(deviceID: id, threadID: threadID)?.messages }) { [weak self] records in
            guard let self else { return }
            let waiting = self.waiters.removeValue(forKey: threadID) ?? []
            guard token == self.generation else { waiting.forEach { $0.resume(returning: nil) }; return }
            self.loading.remove(threadID)
            if let records {
                self.transcripts[threadID] = records.map(\.chatMessage)
            } else {
                self.entries[threadID] = nil   // 壞了或不見了：當沒有
            }
            waiting.forEach { $0.resume(returning: self.transcripts[threadID]) }
            self.onChange?()
        }
    }

    private var activityCache: (stamp: PolicyFileStamp, until: Date, lines: [UUID: String])?

    /// 側欄離線時每條的一行：最後活動多久前（快照裡的更新時間）。
    func activityLines() -> [UUID: String] {
        guard let threads = snapshot?.document.threads else { return [:] }
        let stamp = PolicyFileStamp(cache.documentURL(deviceID)), now = Date()
        if let cached = activityCache, cached.stamp == stamp, now < cached.until { return cached.lines }
        #if DEBUG
        ChatRenderProbe.record("RemoteOfflineMirror.activityLines")
        #endif
        let lines = Dictionary(threads.map { ($0.id, "最後活動 " + RemoteDeviceSidebarSection.seen($0.updatedAt)) },
                               uniquingKeysWith: { first, _ in first })
        // 相對時間在原來的分鐘／小時邊界到期，避免快取把側欄時間凍住。
        let until = threads.reduce(Date.distantFuture) { deadline, thread in
            let age = Int(now.timeIntervalSince(thread.updatedAt))
            guard age < 86_400 else { return deadline }
            let next = age < 3_600 ? max(120, (age / 60 + 1) * 60) : (age / 3_600 + 1) * 3_600
            return min(deadline, thread.updatedAt.addingTimeInterval(Double(next)))
        }
        activityCache = (stamp, until, lines)
        return lines
    }

    /// 設定 › 設備 那一行：存了幾條內容、多大。
    var usageLine: String {
        let bytes = documentBytes + entries.values.reduce(0) { $0 + $1.bytes }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        guard snapshot != nil || !entries.isEmpty else { return "還沒有離線副本" }
        return "離線副本：專案與討論串清單＋\(entries.count) 條內容（\(size)）"
    }

    /// 清掉這台的離線副本（移到垃圾桶）。記憶體一起清；連著線時下次同步會再存一份新的。
    func clear(completion: @escaping @MainActor (Result<Bool, Error>) -> Void) {
        generation += 1
        snapshot = nil
        syncedAt = nil
        entries = [:]
        transcripts = [:]
        loading = []
        let waiting = waiters.values.flatMap { $0 }
        waiters = [:]
        waiting.forEach { $0.resume(returning: nil) }
        lastWrittenRevision = nil
        lastWrittenAt = .distantPast
        pendingDocument = nil
        lastTranscriptSignature = [:]
        lastTranscriptTouch = [:]
        pendingTranscriptWrites = [:]
        documentBytes = 0
        let id = deviceID
        cache.run({ cache in Result { try cache.clear(deviceID: id) } }) { [weak self] result in
            self?.onChange?()   // 先讓 session 換回空白文件，再回報
            completion(result)
        }
    }

    /// 設定 › 設備「移除」這台：不再記任何東西，離線副本一起移到垃圾桶（可以放回）。之後重新配對同一個 id 不會冒出舊快照。
    func retire(completion: @escaping @MainActor (Result<Bool, Error>) -> Void) {
        isRetired = true
        onChange = nil   // 移除的那台不再叫畫面
        clear(completion: completion)
    }
}
