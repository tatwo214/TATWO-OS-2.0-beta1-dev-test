import Foundation

// W182 R5：副設備連不上主設備時，「要主設備才能做的事」先排隊，連回後依序自動送出。
// 佇列檔 live/primary-outbox.json：每筆＝種類、參數、建立時間、狀態；原子寫入；只收三種動作（/蒸餾 寫入、
// 記憶提案核准、分類決定），不是任意方法。送出一律走原本的方法與驗章（見 PrimaryOfflineSync）。

/// live 資料夾裡一個小 JSON 檔。讀、寫都在自己的背景佇列（主執行緒不碰磁碟）；寫入是原子的（先寫暫存再換名）。
/// 讀不懂（壞檔）就當空的，壞檔改名留著（不丟資料、不影響啟動）。
final class PrimaryOfflineJSONFile<Value: Codable & Sendable>: @unchecked Sendable {
    let url: URL
    private let queue: DispatchQueue

    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "ai.tatwo.tatwo2.w182." + url.lastPathComponent, qos: .utility)
    }

    func load() async -> Value? {
        let url = self.url
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = try? Data(contentsOf: url) else { return continuation.resume(returning: nil) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let value = try? decoder.decode(Value.self, from: data) { return continuation.resume(returning: value) }
                let kept = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + ".unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: url, to: kept)
                continuation.resume(returning: nil)
            }
        }
    }

    /// 編碼在呼叫的執行緒（只是記憶體），寫檔排進背景佇列；同一個檔的讀寫照順序來。
    func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let url = self.url
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 等排在前面的讀寫都做完（自測、結束前用）。
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in queue.async { continuation.resume() } }
    }
}

/// 佇列裡的一筆。
struct PrimaryOutboxItem: Codable, Equatable, Identifiable, Sendable {
    /// 只收這三種；參數照種類固定。
    enum Kind: String, Codable, CaseIterable, Sendable {
        case distillWrite = "distill_write"
        case memoryDecide = "memory_decide"
        case classifyDecide = "project_proposal_decide"

        var allowedKeys: Set<String> {
            switch self {
            case .distillWrite: ["planID", "threadID", "output", "content", "submissionID", "source"]
            case .memoryDecide: ["id", "accept", "isPublic"]
            case .classifyDecide: ["deviceID", "id", "action"]
            }
        }

        var label: String {
            switch self {
            case .distillWrite: "/蒸餾 寫入"
            case .memoryDecide: "記憶提案"
            case .classifyDecide: "分類建議"
            }
        }
    }

    enum State: String, Codable, Sendable {
        case queued, sending, failed
    }

    var id: UUID
    var kind: Kind
    var params: [String: String]
    var createdAt: Date
    var state: State
    /// 清單上給人看的一行（例：記憶提案「記得喝水」收下）。
    var title: String
    /// 最近一次沒送成的原因（白話）。
    var reason: String?
    /// 主設備回「不能做」：標失敗、不再重試（留著給人看，按「移除」才拿掉）。
    var refused: Bool?
    /// 拒收而且再送也一樣（已處理、不在了、內容讀不懂）：只給「移除」。
    var terminal: Bool?
    var attempts: Int
    /// /蒸餾：寫入已經交給主設備（之後不自動重送；結果在畫布上查）。
    var handedOver: Bool?
    /// 上次沒送到：這個時間以前先不再送（連著失敗就拉長間隔，最長 10 分鐘；連回來那一次不管它）。
    var retryAfter: Date?

    var isWaiting: Bool { refused != true }
    var canRetry: Bool { handedOver != true && terminal != true }

    static let classificationTerminalReasonCodes: Set<String> = ["proposal_not_pending", "proposal_not_found", "proposal_nothing_to_move", "nothing_to_undo"]
    /// Older files retained only display text, not the terminal flag or structured reason code.
    var legacyTerminalRefusal: Bool {
        guard refused == true, let reason else { return false }
        let codes: Set<String> = kind == .memoryDecide ? ["memory_not_pending"]
            : kind == .classifyDecide ? Self.classificationTerminalReasonCodes : []
        if codes.contains(reason) { return true }
        if kind == .classifyDecide, codes.contains(where: { ProjectClassification.userMessage(code: $0) == reason }) { return true }
        let pattern = kind == .memoryDecide ? #"^這條記憶提案(?:在「[^\r\n]*」上)?已經處理過或不在了$"#
            : kind == .classifyDecide ? #"^這則建議不在「[^\r\n]*」上，沒有送$"# : #"(?!)"#
        return reason.range(of: pattern, options: .regularExpression) != nil
    }

    /// 現在該送了（沒被擋、沒交出去、沒在等下一次重試）。
    func isDue(at now: Date = Date()) -> Bool {
        isWaiting && handedOver != true && state != .sending && (retryAfter ?? .distantPast) <= now
    }

    /// 參數對不對：只收這一種的那幾個欄位，每個都要有、格式對。
    static func validate(_ kind: Kind, _ params: [String: String]) -> Bool {
        guard Set(params.keys) == kind.allowedKeys else { return false }
        switch kind {
        case .distillWrite:
            let content = params["content"] ?? ""
            return ["planID", "threadID", "submissionID"].allSatisfy { params[$0].flatMap(UUID.init(uuidString:)) != nil }
                && params["output"].flatMap(DistillOutputKind.init(rawValue:)) != nil
                && !content.isEmpty && content.utf8.count <= DistillCanvas.maxBytes
                && (params["source"]?.count ?? .max) <= 200
        case .memoryDecide:
            let id = params["id"] ?? ""
            return !id.isEmpty && id.count <= 200
                && ["true", "false"].contains(params["accept"] ?? "") && ["true", "false"].contains(params["isPublic"] ?? "")
        case .classifyDecide:
            let device = params["deviceID"] ?? ""
            return params["id"].flatMap(UUID.init(uuidString:)) != nil && !device.isEmpty && device.count <= 200
                && ["approve", "reject", "undo"].contains(params["action"] ?? "")
        }
    }

    var isValid: Bool { Self.validate(kind, params) && title.count <= 400 }
}

/// 檔案裡的一列：讀不懂的那一列（例如不認得的種類）單獨丟掉，其他照讀。
struct PrimaryOutboxEntry: Codable, Sendable {
    var item: PrimaryOutboxItem?

    init(_ item: PrimaryOutboxItem) { self.item = item }

    init(from decoder: Decoder) throws { item = try? PrimaryOutboxItem(from: decoder) }

    func encode(to encoder: Encoder) throws { try item?.encode(to: encoder) }
}

/// 一台（一個 live 資料夾）的佇列。畫面讀 `items`；改動馬上存檔（背景、原子）。
@MainActor
final class PrimaryOutbox: ObservableObject {
    static let fileName = "primary-outbox.json"
    /// 佇列有變（加、取消、送出）：沒有 ChatPageModel 的畫面（記憶提案）用它重畫。
    static let didChange = Notification.Name("ai.tatwo.tatwo2.primaryOutboxDidChange")
    private static var byRoot: [String: PrimaryOutbox] = [:]
    /// 正式 App 那一份（記憶提案畫面沒有 ChatPageModel，從這裡拿）。
    private(set) static weak var main: PrimaryOutbox?

    static func forRoot(_ root: URL, main isMain: Bool = false) -> PrimaryOutbox {
        let key = root.standardizedFileURL.path
        let outbox = byRoot[key] ?? PrimaryOutbox(root: root)
        byRoot[key] = outbox
        if isMain, Self.main == nil { Self.main = outbox }
        return outbox
    }

    @Published private(set) var items: [PrimaryOutboxItem] = []
    /// 主設備的名字（「連回〈名〉後會自動送」用）；同步那邊每次看到主設備就更新。
    @Published var primaryName: String?
    /// 記憶提案：上次連得到主設備時看到的清單（離線時照樣列出來、按了先排隊）。只在記憶體。
    var lastMemoryProposals: [UserMemoryProposal] = []
    let file: PrimaryOfflineJSONFile<[PrimaryOutboxEntry]>
    private var loadTask: Task<Void, Never>?
    private var loaded = false

    /// 直接建一份（自測用來證明重開 App 讀得回來）；平常用 `forRoot`。
    init(root: URL) {
        file = PrimaryOfflineJSONFile(url: root.appendingPathComponent(Self.fileName))
        let file = self.file
        loadTask = Task { @MainActor [weak self] in
            let entries = await file.load()
            self?.finishLoading(entries ?? [])
        }
    }

    func ready() async { await loadTask?.value }

    private func finishLoading(_ entries: [PrimaryOutboxEntry]) {
        let known = Set(items.map(\.id))
        var restored: [PrimaryOutboxItem] = []
        var migrated = false
        for var item in entries.compactMap(\.item) where item.isValid && !known.contains(item.id) {
            // /蒸餾 已經交給主設備的，結果在畫布上查（不自動重送）；其他送到一半的照樣再送（主設備那邊重複的會回「已處理」）。
            if item.handedOver == true { continue }
            if item.state == .sending { item.state = .queued }
            if item.terminal == nil, item.refused == true {
                item.terminal = item.legacyTerminalRefusal
                migrated = true
            }
            restored.append(item)
        }
        let changed = !items.isEmpty
        items = restored + items   // 檔案裡的順序就是排隊順序（新加的一律接在最後）
        loaded = true
        if changed || migrated || restored.count != entries.count { persist() } else { announce() }
    }

    // MARK: 加、取消

    /// 只收三種動作、參數照種類驗過；不合的回 nil（什麼都沒加）。
    @discardableResult
    func enqueue(_ kind: PrimaryOutboxItem.Kind, params: [String: String], title: String,
                 replacing matches: (PrimaryOutboxItem) -> Bool = { _ in false }) -> PrimaryOutboxItem? {
        let item = PrimaryOutboxItem(id: UUID(), kind: kind, params: params, createdAt: Date(), state: .queued,
                                     title: String(title.prefix(400)), reason: nil, refused: nil, attempts: 0)
        guard item.isValid else { return nil }
        var kept: [PrimaryOutboxItem] = []
        for existing in items where !(existing.kind == kind && existing.state != .sending && matches(existing)) {
            kept.append(existing)
        }
        items = kept + [item]
        persist()
        return item
    }

    @discardableResult
    func enqueueDistillWrite(planID: UUID, threadID: UUID, output: DistillOutputKind, content: String,
                             submissionID: UUID, source: String, title: String) -> PrimaryOutboxItem? {
        enqueue(.distillWrite, params: ["planID": planID.uuidString, "threadID": threadID.uuidString, "output": output.rawValue,
                                        "content": content, "submissionID": submissionID.uuidString,
                                        "source": String(source.prefix(200))],
                title: "/蒸餾 寫入「\(title.prefix(60))」")
    }

    /// 同一條提案再按一次（換成另一個決定）＝換掉排著的那筆。
    @discardableResult
    func enqueueMemoryDecide(id: String, accept: Bool, isPublic: Bool, text: String) -> PrimaryOutboxItem? {
        enqueue(.memoryDecide, params: ["id": id, "accept": accept ? "true" : "false", "isPublic": isPublic ? "true" : "false"],
                title: "記憶提案「\(text.prefix(40))」\(accept ? "收下" : "不要")", replacing: { $0.params["id"] == id })
    }

    @discardableResult
    func enqueueClassification(deviceID: String, id: UUID, action: String, summary: String) -> PrimaryOutboxItem? {
        let verb = action == "approve" ? "核准搬移" : action == "reject" ? "不要" : "復原"
        return enqueue(.classifyDecide, params: ["deviceID": deviceID, "id": id.uuidString, "action": action],
                       title: "分類建議「\(summary.prefix(40))」\(verb)",
                       replacing: { $0.params["id"] == id.uuidString })
    }

    /// 取消（或把失敗的那筆移除）。送出中的不取消（已經在路上）。
    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state != .sending else { return }
        items.remove(at: index)
        persist()
    }

    // MARK: 送出那邊用

    func item(_ kind: PrimaryOutboxItem.Kind, key: String, value: String) -> PrimaryOutboxItem? {
        items.last { $0.kind == kind && $0.params[key] == value }
    }

    var waiting: [PrimaryOutboxItem] { items.filter(\.isWaiting) }

    func mark(_ id: UUID, state: PrimaryOutboxItem.State, reason: String? = nil, refused: Bool = false, terminal: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        if state == .sending { items[index].attempts += 1 }
        if let reason { items[index].reason = String(reason.prefix(600)) }
        if refused {
            items[index].refused = true
            items[index].terminal = terminal
            items[index].handedOver = nil   // 留著給人看（畫布上那一行），重開 App 也在
        }
        persist()
    }

    /// 這次沒送到（連線、主設備忙）：留著、寫原因，隔一段再送（10 秒起，每次加倍，最長 10 分鐘）。
    func deferRetry(_ id: UUID, reason: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .queued
        items[index].reason = String(reason.prefix(600))
        let delay = min(600, 10 * pow(2, Double(max(0, min(items[index].attempts - 1, 6)))))
        items[index].retryAfter = Date().addingTimeInterval(delay)
        persist()
    }

    func markHandedOver(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].handedOver = true
        persist()
    }

    func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    // MARK: 記憶提案送到了

    /// 排著的記憶提案核准送到了：記憶提案畫面重讀清單（離線時打開的也一樣），收下的連 user.md 畫面一起重讀。
    static let memoryDecided = Notification.Name("ai.tatwo.tatwo2.primaryOutboxMemoryDecided")

    func noteMemoryDecided(id: String, accept: Bool) {
        if let index = lastMemoryProposals.firstIndex(where: { $0.id == id }) {
            lastMemoryProposals[index].status = accept ? "accepted" : "rejected"
            lastMemoryProposals[index].decidedAt = Date()
        }
        NotificationCenter.default.post(name: Self.memoryDecided, object: self, userInfo: ["id": id, "accept": accept])
    }

    private func persist() {
        if loaded { file.save(items.map(PrimaryOutboxEntry.init)) }
        announce()
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// 等寫檔做完（自測）。
    func flushWrites() async {
        await ready()
        await file.flush()
    }
}
