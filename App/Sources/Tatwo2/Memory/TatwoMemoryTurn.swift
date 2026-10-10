import Foundation

// W180 E1：每一輪帶記憶、回答下面「用了 N 條記憶」。ChatLiveEngine 的兩個插點（send、result）叫這裡。

extension LiveThreadRecord {
    /// Bot 串：Bot 準備時一定會設權限預設（prepareBotThread）。不看 MCP 的「全關」記號——一般對話把 MCP 全部取消也是那個記號。
    var isMemoryBotThread: Bool { botPermissionPreset != nil }
    /// 派工房間（施工或唯讀副審）。
    var isMemoryRoomThread: Bool { roomBrief != nil || roomReadOnly == true }
}

extension LiveMessageRecord {
    /// 「用了 N 條記憶」那一列：不算對話的最後一句（側欄副標、遠端狀態行、串列搜尋都跳過它）。
    var isMemoryUsageRow: Bool { role == "system" && status == TatwoMemoryUsageNote.status }
}

extension LiveDocumentRecord {
    /// 這條對話的記憶強度（照 TatwoMemoryStrength.resolve 的規則；子討論串一路往上跟母串，最多 6 層）。
    func memoryStrength(for threadID: UUID?, depth: Int = 0) -> TatwoMemoryStrength {
        guard let threadID, let thread = threads.first(where: { $0.id == threadID }) else { return .light }
        // Remote work never passively receives the user's private memory. Explicit tools check current creator grants.
        if thread.controllerCreatorFingerprint != nil { return .off }
        let parent = depth < 6 ? thread.parentThreadID.flatMap { id in
            threads.contains(where: { $0.id == id }) ? memoryStrength(for: id, depth: depth + 1) : nil
        } : nil
        return TatwoMemoryStrength.resolve(stored: thread.memoryStrength, isBot: thread.isMemoryBotThread,
                                           isRoom: thread.isMemoryRoomThread,
                                           isAssistant: assistantProjectID != nil && thread.projectID == assistantProjectID,
                                           parent: parent)
    }
}

/// 這一輪 OS 帶了哪幾條、AI 又用 memory_get／memory_search 讀了哪幾條（去重）。os.sock 的工具在背景執行緒記、
/// 引擎在主執行緒收，所以有鎖。
final class TatwoMemoryTurnLedger: @unchecked Sendable {
    static let shared = TatwoMemoryTurnLedger()

    private struct Turn {
        var turn: String?
        var offered: [TatwoMemoryUsageNote.Item] = []
        var read: [TatwoMemoryUsageNote.Item] = []
        var query = ""
    }

    private let lock = NSLock()
    private var turns: [UUID: Turn] = [:]

    func begin(thread: UUID, turn: String, offered: [TatwoMemoryUsageNote.Item], query: String) {
        lock.lock(); defer { lock.unlock() }
        turns[thread] = Turn(turn: turn, offered: offered, query: query)
    }

    func read(thread: UUID, items: [TatwoMemoryUsageNote.Item]) {
        guard !items.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        turns[thread, default: Turn()].read += items
    }

    /// 回合結束時收：同一輪才算 OS 帶的；讀過的都算。收過就清掉。
    func finish(thread: UUID, turn: String?) -> TatwoMemoryUsageNote? {
        lock.lock()
        let entry = turns.removeValue(forKey: thread)
        lock.unlock()
        guard let entry else { return nil }
        let offered = entry.turn != nil && entry.turn == turn ? entry.offered : []
        let note = TatwoMemoryUsageNote(items: offered + entry.read, query: entry.query)
        return note.items.isEmpty ? nil : note
    }
}

extension ChatLiveEngine {
    var memoryUsageStats: TatwoMemoryUsageStats { TatwoMemoryUsageStats.at(store.url.deletingLastPathComponent()) }

    /// 引擎建立時先把記憶快取與「最近常用」讀好（都在背景），第一句就用得到。
    func warmMemory() {
        TatwoMemoryIndex.shared.warm()
        memoryUsageStats.warm()
    }

    /// 主執行緒上挑候選最多花多久；超過就這句不附（送出照常）。比對資料在背景掃檔時就算好，平常只要幾毫秒。
    static let memoryBriefingBudget: TimeInterval = 0.12

    /// 這一句要附的記憶候選（附在目標摘要後面、不顯示在對話裡）。「關」、資料夾不在（例：外接卷沒掛上）、
    /// 快取還沒讀好都回 nil，送出照常。只讀快取，不在主執行緒讀檔；很長的一句只看頭尾，算太久就不附。
    func memoryBriefing(threadID: UUID, turn: String, text: String) -> String? {
        let strength = doc.memoryStrength(for: threadID)
        var block: TatwoMemoryRecall.Block?
        if strength != .off, let snapshot = TatwoMemoryIndex.shared.cached(), snapshot.folderExists {
            let context = TatwoMemoryRecallContext(usage: memoryUsageStats.snapshot(), feedback: snapshot.feedback, now: Date())
            block = TatwoMemoryRecall.promptBlock(query: text, strength: strength, items: snapshot.candidates, context: context,
                                                  budget: Self.memoryBriefingBudget)
        }
        let offered = zip(block?.ids ?? [], block?.titles ?? []).map { TatwoMemoryUsageNote.Item(id: $0, title: $1) }
        TatwoMemoryTurnLedger.shared.begin(thread: threadID, turn: turn, offered: offered, query: text)
        return block?.text
    }

    /// 回合成功結束（產出索引之後）：這輪帶了或讀了記憶才在回答下面加一列「用了 N 條記憶」。
    func appendMemoryUsage(threadID: UUID, turn: String?) {
        guard let note = TatwoMemoryTurnLedger.shared.finish(thread: threadID, turn: turn) else { return }
        memoryUsageStats.record(note.items.map(\.id))
        appendSystemMessage(threadID: threadID, text: note.encoded(), status: TatwoMemoryUsageNote.status)
    }
}
