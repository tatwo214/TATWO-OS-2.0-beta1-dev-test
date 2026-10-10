import Foundation
import UniformTypeIdentifiers

/// 只擁有一輪 TAP；沒有 CLI、程序或 sidecar。
@MainActor
final class ChatGPTTapTurnRunner {
    let tap: any ConversationTap
    let mapper: TapProjectMapper
    private(set) var requestID: String?
    private var task: Task<Void, Never>?
    private(set) var stopping = false
    init(tap: any ConversationTap, mapper: TapProjectMapper) {
        self.tap = tap
        self.mapper = mapper
    }

    func start(threadID: UUID, project: TapProjectContext?, title: String, text: String,
               routeID: String, effort: String?, attachmentPaths: [String], history: [ChatMessage],
               group: Bool = false, groupOpening: (() -> String)? = nil, resolved: @escaping (String, String?) -> Void = { _, _ in }, notice: @escaping (String) -> Void, event: @escaping (TapStreamEvent) -> Void) {
        task = Task { @MainActor [self] in
            let chatGPT = tap as? ChatGPTTap
            let lease = chatGPT?.acquireLease(backgroundWork: true)
            defer { if let lease { chatGPT?.releaseLease(lease) }; task = nil }
            do {
                if let chatGPT, chatGPT.connection == .sleeping || chatGPT.connection == .starting {
                    event(.queued)
                    try await chatGPT.readyForSend()
                }
                guard tap.connection == .ready else { throw TapError.notReady }
                try await ChatGPTTapModelCatalog.refreshForSend(tap: tap)
                let fast = group ? GroupFastModel.choose(ChatGPTTapModelCatalog.snapshot) : nil
                if group && fast == nil { throw TapError.remote("這個 TAP 沒有可用的快速模型，這句未送出") }
                var route = (fast?.model ?? ChatGPTTapModelCatalog.effectiveModel(routeID)).map { ChatGPTTapModelCatalog.routeID($0.id) } ?? routeID
                let destination = try await mapper.destination(project: project, threadID: threadID)
                if let reason = destination.notice { notice(ChatGPTLocalText.clean(reason, limit: 160)) }
                let attachments = try await Self.loadAttachments(attachmentPaths)
                try Task.checkCancellation()
                guard !stopping else { throw CancellationError() }
                if !group, let current = ChatGPTTapModelCatalog.effectiveModel(routeID) { route = ChatGPTTapModelCatalog.routeID(current.id) }
                guard ChatGPTTapModelCatalog.isFresh,
                      ChatGPTTapModelCatalog.snapshot.contains(where: { ChatGPTTapModelCatalog.routeID($0.id) == route }) else {
                    throw TapError.remote("ChatGPT 模型清單尚未準備好；請登入 ChatGPT Space 後再送")
                }
                let model = ChatGPTTapModelCatalog.modelID(route)
                guard !model.isEmpty, model != "unavailable", destination.map.chatgpt_project_id.hasPrefix("g-p-") else {
                    throw TapError.remote("ChatGPT 模型或專案尚未就緒")
                }
                let outgoing = group ? (destination.conversationID == nil ? groupOpening?() ?? text : text) : Self.outgoing(text: text, project: project, first: destination.conversationID == nil, history: history)
                if !group {
                    if let summary = Self.collaborationNotice(history) { notice(summary) }
                }
                let selected = ChatGPTTapModelCatalog.effectiveModel(route)
                let actualEffort = group ? fast?.effort : selected.flatMap { model in model.efforts.first { $0.id == effort }?.id ?? ChatGPTTapModelCatalog.defaultEffort(for: model) }
                resolved(route, actualEffort)
                let stream = tap.send(text: outgoing, conversationID: destination.conversationID, model: model, effort: actualEffort,
                                      attachments: attachments, tool: nil, gizmoID: destination.map.chatgpt_project_id,
                                      temporary: false, parentID: nil)
                for await item in stream {
                    switch item {
                    case .request(let id):
                        requestID = id
                        if stopping { tap.stop(requestID: id) }
                    case .conversation(let id):
                        do { try await mapper.record(id, threadID: threadID, destination: destination) }
                        catch {
                            if let requestID { tap.stop(requestID: requestID) }
                            event(.failed("ChatGPT 對話已建立，但對應表未能儲存；請勿直接重送"))
                            return
                        }
                    default: break
                    }
                    event(item)
                    switch item {
                    case .finished:
                        if destination.conversationID == nil, let saved = try? await mapper.storage.load(at: destination.folder),
                           let id = saved.threads[threadID.uuidString] {
                            // 標題同步不阻擋下一輪；失敗不重送使用者文字。
                            Task { @MainActor [tap] in
                                do {
                                    try await tap.rename(conversationID: id, title: title)
                                    NotificationCenter.default.post(name: TapProjectMapStore.didChange, object: nil)
                                }
                                catch { notice("ChatGPT 對話標題未能同步") }
                            }
                        }
                        return
                    case .failed, .notSubmitted: return
                    default: break
                    }
                }
                if stopping { event(.finished) }
                else { event(.failed("ChatGPT 串流中斷，結果未確認；請先看對話，不要直接重送")) }
            } catch {
                // 到這裡尚未呼叫 send；確定沒送出才能還草稿。
                event(.notSubmitted(stopping ? "這句尚未送出，已停止" : ChatGPTLocalText.clean(error.localizedDescription, limit: 160)))
            }
        }
    }

    func stop() {
        stopping = true
        if let requestID { tap.stop(requestID: requestID) }
        else { task?.cancel() }
    }

    func shutdown() {
        stop()
        task?.cancel()
    }

    /// 沿用 Space 的一般檔案、O_NOFOLLOW、O_NONBLOCK 與大小限制；背景讀取有期限。
    static func loadAttachments(_ paths: [String], timeout: TimeInterval = 5,
                                reader: @escaping @Sendable (URL, Int) -> Data? = { url, limit in
                                    ChatGPTSpaceModel.readReceivedFile(url, in: url.deletingLastPathComponent(), limit: limit)
                                }) async throws -> [TapAttachment] {
        var attachments: [TapAttachment] = []
        for path in paths {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: path)
            let limit = ChatGPTSpaceModel.readLimit(for: url.lastPathComponent)
            let raw = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let gate = AttachmentReadGate(continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    if let data = reader(url, limit) { gate.finish(.success(data)) }
                    else { gate.finish(.failure(TapError.remote(ChatGPTSpaceModel.refusedMessage(url.lastPathComponent)))) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    gate.finish(.failure(TapError.remote("附件讀取逾時，這句尚未送出；請改用本機的一般檔案")))
                }
            }
            try Task.checkCancellation()
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            switch ChatGPTSpaceModel.admit(raw, name: url.lastPathComponent, mime: mime,
                                          currentBytes: attachments.reduce(0) { $0 + $1.data.count }) {
            case .success(let file): attachments.append(file)
            case .failure(let refusal): throw TapError.remote(refusal.message)
            }
        }
        return attachments
    }

    private final class AttachmentReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Data, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    static func outgoing(text: String, project: TapProjectContext?, first: Bool, history: [ChatMessage]) -> String {
        var prefixes: [String] = []
        if first {
            if let project {
                let name = project.name
                let id = project.id.uuidString
                prefixes.append("你在 TATWO OS 的 Coder 裡被當作模型使用；這個專案是 \(name)（\(String(id.prefix(8)))）。需要讀寫檔、跑指令、記憶時，用 TATWO 這個 app 的工具，並帶 project_id=\(id)。")
            } else {
                prefixes.append("你在 TATWO OS 的 Coder 裡被當作模型使用；這條獨立討論串沒有 OS 專案，對應 ChatGPT 的「TATWO · 收件匣」。需要工具時用 TATWO 這個 app；未指定 project_id 的工具紀錄放在「ChatGPT · 未分類」，收件匣不是 OS 專案 ID。")
            }
        }
        if let summary = collaborationSummary(history) { prefixes.append(summary) }
        return (prefixes + [text]).joined(separator: "\n\n")
    }

    private static func collaborationRows(_ history: [ChatMessage]) -> [ChatMessage] {
        let start = history.lastIndex {
            $0.runtimeAdapterID == TatwoChatRuntimeAdapter.chatgptTap.rawValue
                && $0.role == .user && $0.status != ChatLiveEngine.undeliveredRowStatus
        }.map { $0 + 1 } ?? 0
        return history.dropFirst(start).filter {
            $0.role == .assistant && $0.eventKind == .message && !$0.text.isEmpty
                && $0.runtimeAdapterID != TatwoChatRuntimeAdapter.chatgptTap.rawValue
                && !($0.status.map { $0.hasPrefix("error") || $0.hasPrefix("cancelled") } ?? false)
        }
    }

    static func collaborationNotice(_ history: [ChatMessage]) -> String? {
        let count = collaborationRows(history).count
        return count == 0 ? nil : "已附上前面 \(count) 則其他模型的摘要（已遮敏）"
    }

    static func collaborationSummary(_ history: [ChatMessage]) -> String? {
        let others = collaborationRows(history)
        guard !others.isEmpty else { return nil }
        var truncated = false
        let fragments = others.map { row -> String in
            let identity = ((row.runtimeAdapterID ?? "") + " " + (row.modelID ?? "")).lowercased()
            let name = identity.contains("claude") || identity.contains("fable") || identity.contains("opus")
                || identity.contains("sonnet") || identity.contains("haiku") ? "Claude"
                : identity.contains("grok") ? "Grok"
                : identity.contains("codex") || identity.contains("gpt") ? "Codex" : "其他引擎"
            // 先遮敏，再截短；避免把金鑰切成無法比對的半段。
            let masked = HandsSecretLines.maskText(row.text).components(separatedBy: "\n")
                .map { TatwoMemoryStore.containsSecret($0) ? HandsSecretLines.masked : $0 }.joined(separator: "\n")
            let safe = HandsRedactor.redact(masked)
            if safe.count > 400 { truncated = true }
            let excerpt = String(safe.prefix(400)).split(whereSeparator: \.isNewline).prefix(2).joined(separator: " ")
            return "\(name) 說：\(excerpt)"
        }
        let body = "〔TATWO：這中間 " + fragments.joined(separator: "；") + (truncated ? "…（已截斷）〕" : "〕")
        let limit = 1_500
        let suffix = "…（已截斷）〕"
        return body.count <= limit ? body : String(body.prefix(limit - suffix.count)) + suffix
    }
}
