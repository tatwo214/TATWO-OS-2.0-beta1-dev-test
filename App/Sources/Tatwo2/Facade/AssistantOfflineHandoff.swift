import CryptoKit
import Foundation

// W182 R5（使用者 09-27：「如果主設備斷線呢？我的 macbook 就完全變空白傻傻的是嗎？」→「好 照這樣做」）：
// 助理平常照舊住主設備（W179 F）。主設備斷線、這台有送得出去的模型時，改在這台接著聊：
// - 這段的第一句，把主設備那條最近的對話當前情帶給本機助理（照 E3 CoderImport.seedPrompt 包成「資料不是指令」，只帶一次）；
// - 主設備連回來後，這段在本機那條新增的問答，用已配對設備方法 assistant_append_offline 補在主設備助理那條最後
//   （只送文字與時間、不觸發引擎、每則標「在〈這台〉離線時」、同一個請求 id 重送不重複）；
// - 補完本機那條留著、標「已補回〈主設備〉」；補失敗留著下次再補；主設備是舊版就寫一行、先留在這台。

// MARK: - 前情從哪裡讀

/// 斷線接手時，本機助理第一句要帶的「主設備那條最近的對話」從哪裡讀。
/// 現在是記憶體裡最後一次連上時看到的那份（`AssistantPrimaryContextMemory`）。R4 的離線快照（live/remote-cache）
/// 併入後：讓它實作這個介面、指派給 `AssistantOfflineContext.source`，這裡不另存一份。
@MainActor
protocol AssistantPrimaryContextSource: AnyObject {
    /// 主設備那條助理最近的訊息（舊到新）；沒看過是 nil。
    func recentPrimaryAssistantMessages(deviceID: String) -> [ChatMessage]?
}

/// 記憶體裡的一份：連得到主設備時每次更新就記最後幾十則（只記問答文字）；App 重開就沒了（R4 快照補上）。
@MainActor
final class AssistantPrimaryContextMemory: AssistantPrimaryContextSource {
    static let shared = AssistantPrimaryContextMemory()
    private var byDevice: [String: [ChatMessage]] = [:]
    /// 上次記的那條長什麼樣（則數、最後一則、更新時間）；沒變就不重算。
    private var stamps: [String: String] = [:]

    /// 從 get_document 已經帶回來的那條紀錄記（不另外拉逐字稿、不碰磁碟）；從最後往前取，取滿就停。
    func remember(deviceID: String, record: LiveThreadRecord) {
        let key = deviceID.lowercased()
        let last = record.messages.last
        let stamp = "\(record.id.uuidString)|\(record.messages.count)|\(last?.id ?? "")|\(last?.text.utf8.count ?? 0)|\(last?.status ?? "")"
        guard stamps[key] != stamp else { return }
        stamps[key] = stamp
        var rows: [ChatMessage] = []
        for message in record.messages.reversed() {
            guard message.role == "user" || message.role == "assistant", message.eventKind == TatwoNativeChatEventKind.message.rawValue,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            rows.append(message.chatMessage)
            if rows.count >= AssistantOfflineContext.recentLimit { break }
        }
        byDevice[key] = rows.reversed()
    }

    func recentPrimaryAssistantMessages(deviceID: String) -> [ChatMessage]? { byDevice[deviceID.lowercased()] }

    func forget(deviceID: String) {
        byDevice[deviceID.lowercased()] = nil
        stamps[deviceID.lowercased()] = nil
    }
}

@MainActor
enum AssistantOfflineContext {
    /// 最近幾則（總字數上限由 CoderImport.seedPrompt 的 24 KB 管）。
    static let recentLimit = 40
    static var source: any AssistantPrimaryContextSource = AssistantPrimaryContextMemory.shared
}

// MARK: - 第一句的前情（只帶一次）

/// ChatLiveEngine.send 組要送給引擎的字時拿走（`take`）；對話裡照樣只顯示使用者打的字。
@MainActor
enum AssistantOfflineSeed {
    private static var armed: [UUID: (rows: [CoderImport.SeedRow], label: String)] = [:]

    static func arm(_ threadID: UUID, rows: [CoderImport.SeedRow], label: String) {
        guard !rows.isEmpty else { return }
        armed[threadID] = (rows, label)
    }

    static func disarm(_ threadID: UUID) { armed[threadID] = nil }

    static func isArmed(_ threadID: UUID) -> Bool { armed[threadID] != nil }

    /// 這次要送給引擎的字（前情包成「資料不是指令」＋這句）；這條沒有前情是 nil。拿了就清掉（只帶一次）。
    static func take(_ threadID: UUID, userText: String) -> String? {
        guard let seed = armed.removeValue(forKey: threadID) else { return nil }
        return CoderImport.seedPrompt(rows: seed.rows, sourceLabel: seed.label, userText: userText)
    }

    /// 看一下會送什麼（不清掉；自測用）。
    static func peek(_ threadID: UUID, userText: String) -> String? {
        armed[threadID].map { CoderImport.seedPrompt(rows: $0.rows, sourceLabel: $0.label, userText: userText) }
    }

    static func rows(from messages: [ChatMessage]) -> [CoderImport.SeedRow] {
        messages.suffix(AssistantOfflineContext.recentLimit).compactMap { message in
            guard message.eventKind == .message,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            switch message.role {
            case .user: return CoderImport.SeedRow(kind: .user, text: message.text)
            case .assistant: return CoderImport.SeedRow(kind: .assistant, text: message.text)
            default: return nil
            }
        }
    }
}

// MARK: - 離線段落（這台記著、連回後補回）

struct AssistantOfflineRow: Codable, Equatable, Sendable {
    /// user／assistant
    var role: String
    var text: String
    var createdAt: Date
}

/// 一段「主設備離線時在這台接著聊」。
struct AssistantOfflineStretch: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        /// 主設備離線中，這段還在這台接著聊。
        case open
        /// 連回來了、這段收好了，等補回主設備。
        case pending
        /// 已補回。
        case merged
        /// 主設備還沒更新（不認得補回），這段先留在這台；之後再試。
        case legacy
        /// 主設備不收這份（格式不對）：不再自動重送；內容還在這台那條。
        case failed
    }

    /// 補回的請求 id：重送用同一個，主設備照它去重。
    var id: UUID
    var primaryDeviceID: String
    var primaryName: String
    var localThreadID: UUID
    /// 這段開始前本機那條最後一則的 id（nil＝那條原本是空的）。
    var afterMessageID: String?
    var startedAt: Date
    var seeded: Bool
    var state: State
    /// 連回來時收好的問答（之後重送一樣的內容）。
    var rows: [AssistantOfflineRow]?
    var lastError: String?
    var lastAttemptAt: Date?
    var mergedAt: Date?
    /// 補回試過幾次（連回後的新一句只在前幾次等它補完）。
    var attempts: Int?
    /// 一段太長時分成幾次送：已經送到的次數（重送從下一次接著送）。
    var mergedChunks: Int?

    /// 連回後的新一句先等這段補回，最多等這麼多次（再補不成就不擋，這段留在這台、之後再補）。
    static let holdAttempts = 3
}

/// 一台（一個 live 資料夾）的離線段落紀錄：live/assistant-offline.json（背景讀寫、原子寫入）。
@MainActor
final class AssistantOfflineStore {
    static let fileName = "assistant-offline.json"
    private static var byRoot: [String: AssistantOfflineStore] = [:]

    static func forRoot(_ root: URL) -> AssistantOfflineStore {
        let key = root.standardizedFileURL.path
        let store = byRoot[key] ?? AssistantOfflineStore(root: root)
        byRoot[key] = store
        return store
    }

    private(set) var stretches: [AssistantOfflineStretch] = []
    let file: PrimaryOfflineJSONFile<[AssistantOfflineStretch]>
    private var loadTask: Task<Void, Never>?
    private var loaded = false

    init(root: URL) {
        file = PrimaryOfflineJSONFile(url: root.appendingPathComponent(Self.fileName))
        let file = self.file
        loadTask = Task { @MainActor [weak self] in
            let rows = await file.load()
            self?.finishLoading(rows ?? [])
        }
    }

    func ready() async { await loadTask?.value }

    private func finishLoading(_ rows: [AssistantOfflineStretch]) {
        let known = Set(stretches.map(\.id))
        let changed = !stretches.isEmpty
        stretches = rows.filter { !known.contains($0.id) } + stretches
        loaded = true
        if changed { save() }
    }

    func update(_ body: (inout [AssistantOfflineStretch]) -> Void) {
        body(&stretches)
        // 補完的只留最近 20 段、7 天內（給畫面說明用）；沒補完的一律留著。
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let done = stretches.filter { $0.state == .merged }
        let keep = Set(done.filter { ($0.mergedAt ?? .distantPast) > cutoff }
            .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }.prefix(20).map(\.id))
        stretches.removeAll { $0.state == .merged && !keep.contains($0.id) }
        save()
    }

    private func save() { if loaded { file.save(stretches) } }

    func flushWrites() async {
        await ready()
        await file.flush()
    }

    func open(device: String, localThread: UUID) -> AssistantOfflineStretch? {
        stretches.last { $0.state == .open && $0.primaryDeviceID == device && $0.localThreadID == localThread }
    }
}

// MARK: - 補回的方法（主設備那一側收；已配對設備經 SSH 呼叫）

enum AssistantOfflineWire {
    static let method = "assistant_append_offline"
    static let maxRows = 400
    static let maxRowBytes = 64 * 1024
    static let maxTotalBytes = 2 * 1024 * 1024
    static let noteStatus = "info|離線補回"
    /// 補回的列（說明與每則）的 id 開頭；主設備引擎下一句帶前情時照這個認。
    static let rowIDPrefix = "offline:"

    /// 一段太長時切成幾次送：每次的則數與總字數都在主設備收得下的範圍內；照順序，同一段每次切法都一樣。
    static func chunks(_ rows: [AssistantOfflineRow]) -> [[AssistantOfflineRow]] {
        var result: [[AssistantOfflineRow]] = []
        var current: [AssistantOfflineRow] = []
        var bytes = 0
        for row in rows {
            let size = row.text.utf8.count
            if !current.isEmpty, current.count >= maxRows || bytes + size > maxTotalBytes {
                result.append(current)
                current = []
                bytes = 0
            }
            current.append(row)
            bytes += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 第幾次的請求 id：第一次就是這段的 id；之後由這段的 id 加序號算出（固定，重送一樣去重）。
    static func requestID(_ stretch: UUID, chunk index: Int) -> UUID {
        guard index > 0 else { return stretch }
        var bytes = Array(SHA256.hash(data: Data("\(stretch.uuidString.lowercased())#\(index)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return UUID(uuidString: parts.joined(separator: "-")) ?? stretch
    }

    struct Request: Sendable, Equatable {
        let requestID: UUID
        let threadID: UUID
        let device: String
        let rows: [AssistantOfflineRow]
    }

    /// 主設備回的原因代碼（`String(describing:)` 就是代碼本身）。
    struct Failure: Error, CustomStringConvertible, Equatable {
        let code: String
        var description: String { code }
        static let invalidParams = Failure(code: "invalid_params")
        static let unavailable = Failure(code: "assistant_unavailable")
        static let busy = Failure(code: "assistant_busy")
    }

    private static let keys: Set<String> = ["requestID", "threadID", "device", "rows"]

    static func params(requestID: UUID, threadID: UUID, device: String, rows: [AssistantOfflineRow]) -> [String: Any] {
        let dates = ISO8601DateFormatter()
        return ["requestID": requestID.uuidString, "threadID": threadID.uuidString, "device": device,
         "rows": rows.map { ["role": $0.role, "text": $0.text, "createdAt": dates.string(from: $0.createdAt)] }]
    }

    /// 只收這四個欄位；每則只有 user／assistant、文字、時間；則數與大小有上限。
    static func parse(_ params: [String: Any]) throws -> Request {
        guard Set(params.keys) == keys,
              let requestID = (params["requestID"] as? String).flatMap(UUID.init(uuidString:)),
              let threadID = (params["threadID"] as? String).flatMap(UUID.init(uuidString:)),
              let rawDevice = params["device"] as? String,
              let rawRows = params["rows"] as? [[String: Any]],
              !rawRows.isEmpty, rawRows.count <= maxRows else { throw Failure.invalidParams }
        let dates = ISO8601DateFormatter()
        var total = 0
        let rows = try rawRows.map { row -> AssistantOfflineRow in
            guard Set(row.keys) == ["role", "text", "createdAt"],
                  let role = row["role"] as? String, role == "user" || role == "assistant",
                  let text = row["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= maxRowBytes, !text.contains("\0"),
                  let created = (row["createdAt"] as? String).flatMap(dates.date(from:)) else { throw Failure.invalidParams }
            total += text.utf8.count
            return AssistantOfflineRow(role: role, text: text, createdAt: created)
        }
        guard total <= maxTotalBytes else { throw Failure.invalidParams }
        return Request(requestID: requestID, threadID: threadID, device: deviceName(rawDevice), rows: rows)
    }

    /// 設備名只當標記用：去掉換行與控制字元、最多 60 字；空的叫「副設備」。
    static func deviceName(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "副設備" : String(cleaned.prefix(60))
    }

    static func marker(_ device: String) -> String { "〔在「\(device)」離線時〕" }

    /// 補在主設備那條的列：一行說明＋每則（標「在〈這台〉離線時」）。id 由請求 id 決定，重送不會多一份。
    static func messages(_ request: Request) -> [ChatMessage] {
        let prefix = rowIDPrefix + "\(request.requestID.uuidString.lowercased()):"
        let head = ChatMessage(id: prefix + "head", role: .system,
                               text: "以下 \(request.rows.count) 則是在「\(request.device)」離線時的對話，連回後補回。",
                               status: noteStatus, createdAt: request.rows.first?.createdAt ?? Date())
        let rows = request.rows.enumerated().map { index, row in
            ChatMessage(id: prefix + String(index), role: row.role == "user" ? .user : .assistant,
                        text: marker(request.device) + "\n" + row.text,
                        status: row.role == "assistant" ? "done" : nil, createdAt: row.createdAt)
        }
        return [head] + rows
    }
}

// MARK: - ChatPageModel：副設備那一側

/// sendToAssistant 本機分支前後各呼叫一次（開始／結束）。
struct AssistantOfflineTurn {
    let threadID: UUID
    let device: AssistantPrimaryDevice
    let afterMessageID: String?
}

/// 連回後補回的結果。
struct AssistantOfflineMergeReport: Equatable {
    var mergedRows = 0
    var legacy = false
    var waiting = 0
    var failed: [String] = []
}

extension ChatPageModel {
    /// 這台的助理離線接手紀錄；沒有本機引擎是 nil。
    var assistantOfflineStore: AssistantOfflineStore? {
        localLiveForBridge.map { AssistantOfflineStore.forRoot($0.store.url.deletingLastPathComponent()) }
    }

    /// W182 R5：副設備因為主設備離線退回本機那條時（不是「本機那輪還在跑」），記下這段從哪裡開始；這段的第一句帶前情。
    /// 主設備、單機、接著主設備、主設備還沒有助理時都是 nil（行為不變）。
    func assistantOfflineBeginTurn() -> AssistantOfflineTurn? {
        guard let link = primaryLinkState(), link.engine == nil, !link.connecting,
              let threadID = assistantThreadID, let engine = localLiveForBridge,
              let store = assistantOfflineStore else { return nil }
        if store.open(device: link.device.id, localThread: threadID)?.seeded != true {
            let recent = AssistantOfflineContext.source.recentPrimaryAssistantMessages(deviceID: link.device.id)
                ?? assistantPrimaryMessagesFromOfflineMirror(deviceID: link.device.id) ?? []   // W182 R4＋R5 併入
            AssistantOfflineSeed.arm(threadID, rows: AssistantOfflineSeed.rows(from: recent),
                                     label: "主設備「\(link.device.displayName)」的助理")
        }
        return AssistantOfflineTurn(threadID: threadID, device: link.device, afterMessageID: engine.transcript(for: threadID).last?.id)
    }

    /// 送出了：這段開始（或接著）；前情用掉了或沒送出，都不留到下一句。
    func assistantOfflineEndTurn(_ turn: AssistantOfflineTurn?, accepted: Bool) {
        guard let turn else { return }
        AssistantOfflineSeed.disarm(turn.threadID)
        guard accepted, let store = assistantOfflineStore else { return }
        store.update { list in
            if let index = list.lastIndex(where: { $0.state == .open && $0.primaryDeviceID == turn.device.id
                && $0.localThreadID == turn.threadID }) {
                list[index].seeded = true
                list[index].primaryName = turn.device.displayName
            } else {
                list.append(AssistantOfflineStretch(id: UUID(), primaryDeviceID: turn.device.id, primaryName: turn.device.displayName,
                                                    localThreadID: turn.threadID, afterMessageID: turn.afterMessageID,
                                                    startedAt: Date(), seeded: true, state: .open))
            }
        }
        objectWillChange.send()
    }

    /// W201：只有使用者的新一句送不出去，或對話補回被拒收時，才在助理頁說明。
    var assistantOfflineLine: String? {
        guard let link = primaryLinkState() else { return nil }
        let name = link.device.displayName
        if assistantOfflineHandoffActive { return nil }
        guard let store = assistantOfflineStore, let local = assistantThreadID else { return nil }
        let mine = store.stretches.filter { $0.primaryDeviceID == link.device.id && $0.localThreadID == local }
        // 舊版重試仍自動進行，不報備。
        if primaryOfflineSync?.assistantDeliveryBlocked == true, link.engine != nil, let waiting = mine.last(where: { $0.state == .open || $0.state == .pending }) {
            if let error = waiting.lastError {
                if assistantOfflineMergeOutstanding(link.device) {
                    return "剛才離線時那段還沒補回「\(name)」（\(error)）；補回後再送新的一句，草稿留著"
                }
                return "剛才離線時那段還沒補回「\(name)」（\(error)）；會再補，這段留在這台"
            }
            return nil
        }
        if let failed = mine.last(where: { $0.state == .failed }) {
            return "剛才離線時那段沒補回「\(name)」（\(failed.lastError ?? "那台不收")）；這段留在這台"
        }
        return nil
    }

    /// 主設備離線、這台正接著聊：只供接手判斷，不顯示設備連線提示。
    var assistantOfflineHandoffActive: Bool {
        guard let link = primaryLinkState(), link.engine == nil, !link.connecting,
              case .local = assistantPlacement else { return false }
        return true
    }

    /// 一段裡要補回的問答：這段開始之後本機那條的「你說的、AI 回的」文字（系統說明、錯誤、工具步驟都不算）。
    static func assistantOfflineRows(_ transcript: [ChatMessage], after messageID: String?, since start: Date) -> [AssistantOfflineRow] {
        let tail: ArraySlice<ChatMessage>
        if let messageID, let index = transcript.firstIndex(where: { $0.id == messageID }) {
            tail = transcript[(index + 1)...]
        } else if messageID == nil {
            tail = transcript[...]
        } else {
            tail = transcript.filter { $0.createdAt >= start.addingTimeInterval(-1) }[...]
        }
        let rows = tail.compactMap { message -> AssistantOfflineRow? in
            guard message.role == .user || message.role == .assistant, message.eventKind == .message,
                  !(message.status ?? "").hasPrefix("writing"),
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var text = message.text
            if text.utf8.count > AssistantOfflineWire.maxRowBytes - 256 {
                text = String(decoding: Data(text.utf8.prefix(AssistantOfflineWire.maxRowBytes - 256)), as: UTF8.self)
                    + "\n…（太長，完整內容留在這台）"
            }
            return AssistantOfflineRow(role: message.role == .assistant ? "assistant" : "user", text: text, createdAt: message.createdAt)
        }
        return rows   // 一則都不丟：太長的一段補回時分成幾次送（AssistantOfflineWire.chunks）
    }

    /// 連回主設備後：先把還開著的段落收好（本機那輪跑完才收），再依序補回主設備助理那條。
    func mergeAssistantOfflineStretches(device: AssistantPrimaryDevice, primaryThread: UUID,
                                        transport: @escaping PrimaryCallTransport, retryLegacy: Bool = false) async -> AssistantOfflineMergeReport {
        var report = AssistantOfflineMergeReport()
        guard let store = assistantOfflineStore, let local = localLiveForBridge else { return report }
        await store.ready()
        let now = Date()
        store.update { list in
            for index in list.indices where list[index].state == .open && list[index].primaryDeviceID == device.id {
                guard !local.isRunning(list[index].localThreadID) else { continue }
                let rows = Self.assistantOfflineRows(local.transcript(for: list[index].localThreadID),
                                                     after: list[index].afterMessageID, since: list[index].startedAt)
                list[index].rows = rows
                list[index].state = rows.isEmpty ? .merged : .pending
                if rows.isEmpty { list[index].mergedAt = now }
            }
        }
        let thisDevice = primaryOfflineThisDeviceName()
        let due = store.stretches.filter { stretch in
            guard stretch.primaryDeviceID == device.id else { return false }
            if stretch.state == .pending { return true }
            // 舊主設備：10 分鐘後（或連回來那一次）再試一次，主設備更新了就補得回去。
            return stretch.state == .legacy
                && (retryLegacy || (stretch.lastAttemptAt ?? .distantPast) < now.addingTimeInterval(-600))
        }
        for stretch in due {
            guard let rows = stretch.rows, !rows.isEmpty else { continue }
            // 太長的一段分成幾次送（則數、總字數都在主設備收得下的範圍內）；已經送到的那幾次不再送，重送的也會被去重。
            let chunks = AssistantOfflineWire.chunks(rows)
            var update = stretch
            update.lastAttemptAt = Date()
            update.attempts = (stretch.attempts ?? 0) + 1
            var stop = false
            var failure: PrimaryCallFailure?
            for index in min(stretch.mergedChunks ?? 0, chunks.count)..<chunks.count {
                let params = AssistantOfflineWire.params(requestID: AssistantOfflineWire.requestID(stretch.id, chunk: index),
                                                         threadID: primaryThread, device: thisDevice, rows: chunks[index])
                if case .failure(let error) = await awaitPrimaryCall(transport, AssistantOfflineWire.method, params) {
                    failure = PrimaryCallFailure(error)
                    break
                }
                update.mergedChunks = index + 1
                report.mergedRows += chunks[index].count
            }
            if let failure {
                if failure.isOldPeer {
                    // 第一次發現主設備是舊版才說（之後每 10 分鐘再試一次，不再跳通知）。
                    if stretch.state != .legacy { report.legacy = true }
                    update.state = .legacy
                    update.lastError = "「\(device.displayName)」還沒更新"
                    local.appendOfflineRows(threadID: stretch.localThreadID, rows: [ChatMessage(
                        id: "offline:\(stretch.id.uuidString.lowercased()):legacy", role: .system,
                        text: "「\(device.displayName)」還沒更新，這段先留在這台；主設備更新後會再補。",
                        status: AssistantOfflineWire.noteStatus)])
                } else if failure.remote, failure.code == AssistantOfflineWire.Failure.invalidParams.code {
                    update.state = .failed
                    update.lastError = "「\(device.displayName)」不收這份"
                    report.failed.append(update.lastError!)
                } else {
                    // 連線不穩、主設備的助理正在回覆、那條還沒準備好：留著下次再補（依序，後面的也等）。
                    switch failure.code {
                    case AssistantOfflineWire.Failure.busy.code: update.lastError = "主設備的助理正在回覆"
                    case AssistantOfflineWire.Failure.unavailable.code: update.lastError = "主設備的助理那條還沒準備好"
                    default: update.lastError = failure.remote ? "主設備沒收下（\(failure.code)）" : "連線不穩"
                    }
                    report.waiting += 1
                    stop = true
                }
            } else {
                update.state = .merged
                update.mergedAt = Date()
                update.lastError = nil
                local.appendOfflineRows(threadID: stretch.localThreadID, rows: [ChatMessage(
                    id: "offline:\(stretch.id.uuidString.lowercased()):merged", role: .system,
                    text: "已補回「\(device.displayName)」：這段離線時的 \(rows.count) 則對話已接在主設備的助理那條最後。",
                    status: "done|已補回")])
            }
            store.update { list in
                if let index = list.firstIndex(where: { $0.id == update.id }) { list[index] = update }
            }
            if stop { break }
        }
        objectWillChange.send()
        return report
    }

    // MARK: 連回後的新一句：先等剛才離線那段補回

    /// 連回主設備後，這台還有剛才離線那段沒補回主設備那條（還開著；或補過、還沒超過幾次）：新的一句要先等它補完，
    /// 不然這句會排在那段前面、時間倒序。
    func assistantOfflineMergeOutstanding(_ device: AssistantPrimaryDevice) -> Bool {
        guard let store = assistantOfflineStore else { return false }
        return store.stretches.contains { stretch in
            stretch.primaryDeviceID == device.id
                && (stretch.state == .open
                    || (stretch.state == .pending && (stretch.attempts ?? 0) < AssistantOfflineStretch.holdAttempts))
        }
    }

    /// 連回後的新一句正在等補回（畫面標送出中、不能再送）。
    var assistantOfflineHolding: Bool { primaryOfflineSync?.assistantHold != nil }

    /// 先把剛才離線那段補回主設備那條，補完再送這句（`send` 會重新看這一刻接在哪、照常送出）。補不成就不送：
    /// 草稿留著，在該動作的位置寫原因。回 true＝這句交給補回之後再送；false＝已經有一句在等，這句不收。
    func assistantOfflineDeliverAfterMerge(_ device: AssistantPrimaryDevice, send: @escaping @MainActor () -> Void) -> Bool {
        guard let sync = primaryOfflineSync, sync.assistantHold == nil else { return false }
        sync.assistantDeliveryBlocked = false
        sync.assistantHold = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.primaryOfflineSyncSettled()   // 連回時已經在跑的那一輪
            if self.assistantOfflineMergeOutstanding(device) {
                _ = await self.primaryOfflineSyncNow()
                await self.primaryOfflineSyncSettled()
            }
            sync.assistantHold = nil
            sync.assistantDeliveryBlocked = self.assistantOfflineMergeOutstanding(device)
            self.objectWillChange.send()
            guard !self.assistantOfflineMergeOutstanding(device) else { return }
            send()
        }
        objectWillChange.send()
        return true
    }

    // MARK: 主設備那一側

    /// W182 R5（主設備這一側，OSAgentBridge 的 assistant_append_offline）：副設備離線時那段問答補在這台助理那條最後。
    /// 只寫這台自己的助理那條；只加文字列、不觸發引擎；同一個請求 id 已經補過就不再加。
    func receiveAssistantOfflineAppend(_ request: AssistantOfflineWire.Request) throws -> [String: Any] {
        guard let engine = localLiveForBridge, let id = assistantThreadID, id == request.threadID,
              engine.doc.isAssistantThread(id) else { throw AssistantOfflineWire.Failure.unavailable }
        guard !engine.isRunning(id) else { throw AssistantOfflineWire.Failure.busy }
        let added = engine.appendOfflineRows(threadID: id, rows: AssistantOfflineWire.messages(request))
        objectWillChange.send()
        return ["appended": max(0, added - 1), "duplicate": added == 0]
    }
}

// MARK: - 主設備這一側：補回的那段，引擎下一句帶上

extension ChatLiveEngine {
    static let offlineCatchUpLabel = "副設備（主設備離線時在那台接著聊、連回後補回這條的那段）"

    /// W182 R5（主設備這一側）：副設備離線時那段補在助理那條最後，之後這條還沒有新的一問一答（引擎還沒看過）：
    /// 下一句送給引擎時把那段當前情帶上（包成資料不是指令，不顯示在對話裡）。送過一句之後，那段就在引擎看過的那句之前，
    /// 不再帶（只帶一次；從存檔的對話算，App 重開也一樣）。只看助理那條；補回的列照 id 認（AssistantOfflineWire.rowIDPrefix）。
    func offlineCatchUpSeed(threadID: UUID, currentTurn: String, userText: String) -> String? {
        guard doc.isAssistantThread(threadID) else { return nil }
        var unseen: [CoderImport.SeedRow] = []
        for message in transcript(for: threadID).reversed() {
            if message.turnID == currentTurn { continue }
            guard message.eventKind == .message, message.role == .user || message.role == .assistant else { continue }
            guard message.id.hasPrefix(AssistantOfflineWire.rowIDPrefix) else { break }
            guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            unseen.append(CoderImport.SeedRow(kind: message.role == .user ? .user : .assistant, text: message.text))
        }
        guard !unseen.isEmpty else { return nil }
        return CoderImport.seedPrompt(rows: unseen.reversed(), sourceLabel: Self.offlineCatchUpLabel, userText: userText)
    }
}

// MARK: - W182 R4＋R5 併入：記憶體裡沒有（App 重開後主設備還沒連上）時，前情改讀 R4 存在磁碟的離線副本

extension ChatPageModel {
    /// 主設備助理那條最近的問答（舊到新），從 R4 的離線副本讀（只讀記憶體裡那份，不碰磁碟）；沒有是 nil。
    func assistantPrimaryMessagesFromOfflineMirror(deviceID: String) -> [ChatMessage]? {
        guard let session = remoteSessions.first(where: { $0.device.id.caseInsensitiveCompare(deviceID) == .orderedSame }),
              let document = session.offlineMirror.snapshot?.document,
              let id = document.assistantThreadID,
              let thread = document.threads.first(where: { $0.id == id }) else { return nil }
        let rows = thread.messages.map(\.chatMessage).filter { $0.eventKind == .message }
        return rows.isEmpty ? nil : Array(rows.suffix(AssistantOfflineContext.recentLimit))
    }
}
