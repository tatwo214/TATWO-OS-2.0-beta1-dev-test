import Foundation

/// W180 E1：TATWO › 記憶 頁的資料。讀記憶一律經 TatwoMemoryIndex（背景掃）；寫一律經 TatwoMemoryStore（背景跑、先擋金鑰、
/// 寫完更新 MEMORY.md 並 commit）。副設備讀的是這台的副本，離線也能用；改了由同步交給主設備。
@MainActor
final class TatwoMemoryPageModel: ObservableObject {
    enum Filter: Hashable {
        case all, recent, pending, conflicts, forgotten
        case type(String)

        var title: String {
            switch self {
            case .all: "全部"
            case .recent: "最近 7 天"
            case .pending: "待核准"
            case .conflicts: "兩版並存"
            case .forgotten: "最近忘記的"
            case .type(let type): TatwoMemoryPageModel.typeName(type)
            }
        }
    }

    static let folderMissingText = "記憶資料夾還沒接上：到 設定 › OS › 記憶 接上。"
    /// 從「用了 N 條記憶」按「打開」、這台卻沒有那一條（候選是主設備挑的，可能還沒同步過來）。
    static let notHereText = "這台找不到這條記憶：可能還沒從主設備同步過來，或已經被忘記、改名了。"
    static let recentWindow: TimeInterval = 7 * 86_400

    @Published private(set) var snapshot: TatwoMemorySnapshot?
    @Published private(set) var forgotten: [TatwoForgottenMemory] = []
    @Published var query = ""
    @Published var filter: Filter = .all
    @Published private(set) var editingID: String?
    @Published var draftTitle = ""
    @Published var draftAliases = ""
    @Published var draftContent = ""
    @Published var confirmForgetID: String?
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var highlightedID: String?

    let store: TatwoMemoryStore
    let index: TatwoMemoryIndex

    init(store: TatwoMemoryStore = .shared, index: TatwoMemoryIndex = .shared) {
        self.store = store
        self.index = index
    }

    // MARK: - 讀

    var folderMissing: Bool { snapshot.map { !$0.folderExists } ?? false }
    var entries: [TatwoMemoryEntry] { snapshot?.entries ?? [] }

    var types: [String] {
        Array(Set(entries.compactMap { $0.file.type?.lowercased() }.filter { !$0.isEmpty })).sorted {
            (Self.typeOrder.firstIndex(of: $0) ?? 99, $0) < (Self.typeOrder.firstIndex(of: $1) ?? 99, $1)
        }
    }

    nonisolated static let typeOrder = ["user", "feedback", "project", "reference"]

    nonisolated static func typeName(_ type: String) -> String {
        switch type.lowercased() {
        case "user": "關於你"
        case "feedback": "做事偏好"
        case "project": "專案"
        case "reference": "參考"
        default: type
        }
    }

    var conflictCount: Int { entries.filter(\.file.isConflictCopy).count }

    /// 最近 7 天「記下」的（看記下的時間，不看最後修改：clone、同步、改一個別名都不會讓舊記憶變成「最近」）。
    /// 「撤銷」只給這些（撤銷＝把剛記下的這條忘記，封存可還原）。
    func isRecent(_ entry: TatwoMemoryEntry, now: Date = Date()) -> Bool {
        guard let created = entry.createdAt else { return false }
        let age = now.timeIntervalSince(created)
        return age >= -300 && age < Self.recentWindow
    }

    /// 這個篩選＋搜尋之後看到的（搜尋照字面、別名打分，高的在前；沒搜尋照最近修改）。
    func visible(now: Date = Date()) -> [TatwoMemoryEntry] {
        var rows: [TatwoMemoryEntry]
        switch filter {
        case .all, .pending, .forgotten: rows = entries
        case .recent: rows = entries.filter { isRecent($0, now: now) }
        case .conflicts: rows = entries.filter(\.file.isConflictCopy)
        case .type(let type): rows = entries.filter { $0.file.type?.lowercased() == type }
        }
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(200))
        guard !text.isEmpty else { return rows }
        let matched = rows.filter { $0.searchKey.contains(text) }
        let ranked = TatwoMemoryRecall.rank(query: text, items: rows.map(\.candidate), context: TatwoMemoryRecallContext(now: now),
                                            minimumScore: 0.1, limit: rows.count)
        let scores = Dictionary(ranked.map { ($0.candidate.id, $0.score) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let union = ranked.compactMap { byID[$0.candidate.id] } + matched
        return union.filter { seen.insert($0.id).inserted }
            .sorted { (scores[$0.id] ?? 0) != (scores[$1.id] ?? 0) ? (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0)
                : $0.modifiedAt > $1.modifiedAt }
    }

    func reload() async {
        let snapshot = await index.reload()
        let store = self.store
        let forgotten = await Task.detached(priority: .userInitiated) { store.forgotten() }.value
        self.snapshot = snapshot
        self.forgotten = forgotten
        if let editingID, snapshot.entry(editingID) == nil { cancelEdit() }
    }

    /// 從「用了 N 條記憶」的「打開」過來：回到全部、清搜尋、標出那一條。
    /// 這台沒有那一條（副設備還沒同步到、或已經忘記）：說一行為什麼，原本的篩選和搜尋不動。
    func focus(_ id: String) {
        guard snapshot?.entry(id) != nil else {
            highlightedID = nil
            message = Self.notHereText
            return
        }
        filter = .all
        query = ""
        message = nil
        highlightedID = id
    }

    // MARK: - 改

    func beginEdit(_ entry: TatwoMemoryEntry) {
        editingID = entry.id
        confirmForgetID = nil
        draftTitle = entry.title
        draftAliases = entry.file.aliases.joined(separator: "、")
        draftContent = entry.file.content
        message = nil
    }

    func cancelEdit() {
        editingID = nil
        confirmForgetID = nil
    }

    static func aliases(from text: String) -> [String] { TatwoMemoryFile.parseList(text) }

    func saveEdit() async {
        guard let id = editingID else { return }
        let title = draftTitle, aliases = Self.aliases(from: draftAliases), content = draftContent
        await run(success: "已存") { store in try store.update(id: id, title: title, aliases: aliases, content: content) }
        if message == "已存" { editingID = nil }
    }

    /// 忘記＝搬到入口 archive/memory-forgotten-<日期>/（附還原說明），索引那行拿掉；可以在「最近忘記的」還原。
    func forget(_ id: String) async {
        await run(success: "已忘記；可以在「最近忘記的」還原") { store in _ = try store.forget(id: id) }
        if editingID == id { editingID = nil }
        confirmForgetID = nil
    }

    func restore(_ record: TatwoForgottenMemory) async {
        await run(success: "已還原「\(record.title)」") { store in try store.restore(record) }
    }

    private func run(success: String, _ body: @escaping @Sendable (TatwoMemoryStore) throws -> Void) async {
        guard !busy else { return }
        busy = true
        let store = self.store
        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do { try body(store); return nil }
            catch { return (error as? LocalizedError)?.errorDescription ?? "沒完成" }
        }.value
        message = failure ?? success
        busy = false
        await reload()
    }
}
