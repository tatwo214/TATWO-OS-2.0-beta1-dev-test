import CoreFoundation
import Darwin
import Foundation

/// W198：只有本機引擎能進；不建立新授權、不變更 Hands 的工具或專案範圍。
@MainActor
final class ChatGPTDispatch {
    nonisolated static let methods: Set<String> = ["chatgpt_dispatch", "chatgpt_dispatch_stop"]
    nonisolated static let instructions = """

    〔TATWO 派工交件說明〕
    這是一份由本機主導送來的施工單或審查單。施工房：{{room}}。
    呼叫來源對話：{{caller}}；TATWO 專案 ID：{{project}}。
    可使用你既有的 TATWO 連線工具讀檔、寫報告；只使用已授權的工具與專案／工作區，不得要求擴大授權。
    read_file 等工具請用上述 TATWO 專案 ID 與專案內相對路徑。若施工房不在已授權的專案內，請回報讀不到，不要繞過限制。
    write_report 請帶 project_id={{project}}（若你已開了授權工作區，另帶 workspace_id）；這個既有工具會寫到該專案的 ChatGPT 房或該工作區房，不接受任意路徑。
    完整交件也請放在最後回覆；OS 會把最後回覆存回施工房 {{reply}}。這個檔案由 OS 寫入，請勿自行覆蓋。
    不得呼叫 chatgpt_dispatch 或再派給自己；遇到缺少工具、檔案或授權就明確說明限制。
    """
    /// W342：施工房的名字會寫進送給 ChatGPT 的說明。「一般」專案＝家目錄，名字就是帳號名，會被當成個人資料整單擋下；這種寫成「~」。
    nonisolated static func roomLabel(_ room: URL) -> String {
        let name = room.lastPathComponent.replacingOccurrences(of: "[\\p{Cc}\\p{Zl}\\p{Zp}]", with: " ", options: .regularExpression)
        return HandsRedactor.redact(name) == name ? name : "~"
    }
    nonisolated private static let credentialPattern = #"(?i)(?:\b(?:password|passwd|pwd|api[_-]?key|access[_-]?token|secret)\b|密碼|密码)\s*[:=]\s*[^\s]+"#
    nonisolated private static func sensitive(_ text: String) -> Bool {
        rejectionCategory(text) != nil
    }
    nonisolated static func rejectionCategory(_ text: String) -> String? {
        for rule in ChatGPTLocalText.privacyRules where ["path", "contact", "key"].contains(rule.category) {
            if text.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return ["path": "local_path_rejected", "contact": "contact_data_rejected", "key": "credentials_rejected"][rule.category]
            }
        }
        if
        HandsSecretLines.maskText(text) != text || HandsRedactor.redact(text) != text
            || text.range(of: credentialPattern, options: .regularExpression) != nil
        { return "credentials_rejected" }
        return nil
    }
    nonisolated static func allows(_ caller: OSSocketCaller) -> Bool {
        if case .engine = caller { return true }
        return false
    }

    struct Request: Sendable {
        let text: String?
        let ticketPath: String?
        let model: String
        let projectID: UUID?
        let title: String
        let timeout: Int

        static func parse(_ params: [String: Any]) throws -> Self {
            guard Set(params.keys).isSubset(of: ["text", "ticketPath", "model", "projectID", "title", "timeoutSeconds", "callerThreadID"]),
                  (params["text"] != nil) != (params["ticketPath"] != nil) else { throw Failure("invalid_arguments") }
            func string(_ key: String, limit: Int, required: Bool = false, multiline: Bool = false) throws -> String? {
                guard let raw = params[key] else { if required { throw Failure("invalid_arguments") }; return nil }
                // text 的上限是位元組（64 KiB）；其他欄位跟 MCP schema 的 maxLength 一樣算 UTF-16 字數（中文標題不會被多擋）。
                guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      (key == "text" ? value.utf8.count : value.utf16.count) <= limit,
                      !value.unicodeScalars.contains(where: { scalar in
                          scalar.value < 32 && !(multiline && (scalar == "\n" || scalar == "\r" || scalar == "\t")) || scalar.value == 127
                      }) else { throw Failure("invalid_arguments") }
                return value
            }
            let text = try string("text", limit: 65536, multiline: true)
            let path = try string("ticketPath", limit: 4096)
            let model = try string("model", limit: 160, required: true)!
            let title = try string("title", limit: 200, required: true)!
            let project = try string("projectID", limit: 36)
            guard project == nil || UUID(uuidString: project!) != nil else { throw Failure("invalid_arguments") }
            var timeout = 600
            if let raw = params["timeoutSeconds"] {
                guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                      (1...1800).contains(value.doubleValue) else { throw Failure("invalid_arguments") }
                timeout = value.intValue
            }
            return Self(text: text, ticketPath: path, model: model, projectID: project.flatMap(UUID.init(uuidString:)), title: title, timeout: timeout)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let code: String
        init(_ code: String) { self.code = code }
        var description: String { "chatgpt_dispatch_" + code }
    }

    struct Receipt: Sendable {
        let dispatchID: UUID
        var conversationID: String?
        var replyPath: String?
        var summary = ""
        var status = "not_submitted"
        var reason = ""
        var stopped = false
        var wire: [String: Any] {
            ["dispatchID": dispatchID.uuidString, "conversationID": conversationID as Any? ?? NSNull(),
             "replyPath": replyPath as Any? ?? NSNull(), "summary": summary, "status": status, "reason": reason, "stopped": stopped]
        }
    }

    private final class Work {
        let id = UUID()
        let caller: UUID
        let projectID: UUID
        let request: Request
        var receipt: Receipt
        var continuation: CheckedContinuation<Receipt, Never>?
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var requestID: String?
        var sendCalled = false
        var resultUnconfirmed = false
        let deadline: TimeInterval
        var dedupKey: String?
        var output: Output?
        var messages: [String: String] = [:]
        var order: [String] = []
        init(caller: UUID, projectID: UUID, request: Request) {
            self.caller = caller; self.projectID = projectID; self.request = request
            deadline = HandsMonotonic.now() + Double(request.timeout)
            receipt = Receipt(dispatchID: id)
        }
        var full: String { order.compactMap { messages[$0] }.joined(separator: "\n\n") }
    }

    let tap: ChatGPTTap
    let mapper: TapProjectMapper
    let journal: HandsRoomJournal
    private var active: [UUID: Work] = [:]
    /// Hashes only. An uncertain submitted ticket cannot be replayed by a tool retry.
    private var uncertain: [UUID: [String: Receipt]] = [:]
    /// 未確認收據不淘汰：滿了就不收新派工，等呼叫者看過對話後明確解除。
    static let uncertainCapacity = 128

    func isActive(caller: UUID, uptime: TimeInterval = HandsMonotonic.now()) -> Bool {
        guard let work = active[caller] else { return false }
        return uptime < work.deadline
    }

    /// Explicit caller action after inspecting the conversation; never an automatic retry.
    @discardableResult
    func releaseUncertain(caller: UUID) -> Int {
        uncertain.removeValue(forKey: caller)?.count ?? 0
    }
    func endRoom(caller: UUID) {
        _ = stop(caller: caller)
        _ = releaseUncertain(caller: caller)
    }
    #if DEBUG
    func fillUncertainForSelfTest(caller: UUID) {
        for index in 0..<Self.uncertainCapacity { uncertain[caller, default: [:]]["synthetic-\(index)"] = Receipt(dispatchID: UUID()) }
    }
    #endif

    func stopAll() {
        for caller in Array(active.keys) { _ = stop(caller: caller) }
    }
    init(tap: ChatGPTTap, mapper: TapProjectMapper, journal: HandsRoomJournal) {
        self.tap = tap; self.mapper = mapper; self.journal = journal
    }

    func dispatch(_ request: Request, caller: UUID, room: URL, projectID: UUID,
                  destination: TapProjectContext?) async -> Receipt {
        let work = Work(caller: caller, projectID: projectID, request: request)
        guard active[caller] == nil, active.count < 4 else {
            work.receipt.reason = "chatgpt_dispatch_busy"
            try? record(work)
            return work.receipt
        }
        do { try record(work, status: "preparing") }
        catch { work.receipt.reason = "chatgpt_dispatch_journal_unavailable"; return work.receipt }
        active[caller] = work
        return await withCheckedContinuation { continuation in
            work.continuation = continuation
            work.timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(request.timeout)) } catch { return }
                self?.finish(work, status: "timed_out", reason: work.sendCalled
                    ? "期限已到，已要求停止；送出後的結果未確認，請先查看對話再決定是否重送"
                    : "期限已到，尚未送出，已取消準備", stop: true)
            }
            work.task = Task { @MainActor [self] in
                let lease = tap.acquireLease(backgroundWork: true)
                defer { tap.releaseLease(lease) }
                do {
                    // 全檔掃描在送出與喚醒前完成；拒送不記錄單子內容。
                    let prepared = try await Task.detached { try Self.prepare(request, room: room, id: work.id) }.value
                    try Task.checkCancellation()
                    guard active[caller] === work else { return }
                    work.output = prepared.output
                    let keyData = try JSONSerialization.data(withJSONObject: [prepared.text, request.model, request.title,
                        projectID.uuidString, request.projectID?.uuidString ?? "inbox", room.path])
                    let key = HandsAuth.sha256Hex(keyData)
                    work.dedupKey = key
                    if let previous = uncertain[caller]?[key] {
                        work.receipt.status = "not_submitted"
                        work.receipt.reason = "相同派工已有未確認結果；沿用原派工代號，沒有再次送出"
                        try record(work)
                        active[caller] = nil
                        work.timer?.cancel()
                        work.continuation?.resume(returning: previous)
                        work.continuation = nil
                        return
                    }
                    guard (uncertain[caller]?.count ?? 0) < Self.uncertainCapacity else { throw Failure("unconfirmed_full") }
                    if tap.connection == .sleeping || tap.connection == .starting { try await tap.readyForSend() }
                    try Task.checkCancellation()
                    guard tap.connection == .ready else { throw Failure("tap_not_ready") }
                    try await ChatGPTTapModelCatalog.refreshForSend(tap: tap)
                    guard ChatGPTTapModelCatalog.isFresh,
                          ChatGPTTapModelCatalog.snapshot.contains(where: { $0.id == request.model }) else { throw Failure("model_not_in_catalog") }
                    let target = try await mapper.destination(project: destination, threadID: work.id)
                    // Explicit targets must not silently deliver a ticket into the inbox fallback.
                    if request.projectID != nil, target.notice != nil { throw Failure("target_project_unavailable") }
                    try Task.checkCancellation()
                    guard active[caller] === work else { return }
                    let note = Self.instructions.replacingOccurrences(of: "{{room}}", with: Self.roomLabel(room))
                        .replacingOccurrences(of: "{{caller}}", with: caller.uuidString)
                        .replacingOccurrences(of: "{{project}}", with: projectID.uuidString)
                        .replacingOccurrences(of: "{{reply}}", with: "chatgpt-dispatch/" + prepared.output.name)
                    let outgoing = prepared.text + note
                    if let category = await Task.detached(operation: { Self.rejectionCategory(outgoing) }).value { throw Failure(category) }
                    try Task.checkCancellation()
                    guard active[caller] === work else { return }
                    work.sendCalled = true
                    work.resultUnconfirmed = true
                    let stream = tap.send(text: outgoing, conversationID: nil, model: request.model,
                                          effort: nil, attachments: [], tool: nil, gizmoID: target.map.chatgpt_project_id,
                                          temporary: false, parentID: nil)
                    for await event in stream {
                        guard active[caller] === work else { return }
                        switch event {
                        case .request(let id): work.requestID = id
                        case .conversation(let id): work.receipt.conversationID = id
                        case .text(let id, let full):
                            let total = work.messages.values.reduce(0, { $0 + $1.utf8.count }) - (work.messages[id]?.utf8.count ?? 0) + full.utf8.count
                            guard total <= 4 * 1024 * 1024 else {
                                finish(work, status: "failed", reason: "回覆超過 4 MiB，未宣告完整交件", stop: true); return
                            }
                            if work.messages[id] == nil { work.order.append(id) }
                            work.messages[id] = full
                        case .finished:
                            work.resultUnconfirmed = false
                            guard let conversation = work.receipt.conversationID, !conversation.isEmpty, !work.full.isEmpty else {
                                finish(work, status: "failed", reason: "TAP 完成但缺少對話代號或回覆，未宣告交件"); return
                            }
                            // 標題也是同一份期限的一部分；失敗不重送單子。
                            var titleWarning = ""
                            do { try await tap.rename(conversationID: conversation, title: request.title) }
                            catch { titleWarning = "回覆完成；ChatGPT 對話標題同步失敗" }
                            guard active[caller] === work else { return }
                            finish(work, status: "completed", reason: titleWarning); return
                        case .notSubmitted(let reason):
                            work.resultUnconfirmed = false
                            finish(work, status: "not_submitted", reason: reason); return
                        case .failed(let reason, let code):
                            if ["provider_failed", "conversation_too_long"].contains(code ?? "") { work.resultUnconfirmed = false }
                            finish(work, status: "failed", reason: reason); return   // W200 起 failed 多帶分類代碼
                        default: break
                        }
                    }
                    if active[caller] === work { finish(work, status: "failed", reason: "串流中斷，結果未確認，請勿直接重送") }
                } catch {
                    if active[caller] === work {
                        let failure = error as? Failure
                        let reason = failure?.description ?? "ChatGPT 準備失敗，尚未送出；請檢查 TAP 登入、檔案與專案"
                        finish(work, status: work.sendCalled ? "failed" : "not_submitted", reason: reason, fixedReason: failure != nil)
                    }
                }
            }
        }
    }

    /// 停止只取消工作：已送出的這一張仍算未確認。releasingEarlier＝chatgpt_dispatch_stop：呼叫者看過對話後，明確解除之前的未確認收據。
    func stop(caller: UUID, releasingEarlier: Bool = false) -> [String: Any] {
        let released = releasingEarlier ? releaseUncertain(caller: caller) : 0
        guard let work = active[caller] else { return ["stopped": false, "reason": "no_active_dispatch", "releasedUncertain": released] }
        work.receipt.stopped = true
        finish(work, status: work.sendCalled ? "failed" : "not_submitted",
               reason: work.sendCalled ? "已要求停止；送出後結果未確認，請先查看對話" : "尚未送出，已停止", stop: true)
        return ["stopped": true, "dispatchID": work.id.uuidString]
    }

    private func record(_ work: Work, status: String? = nil) throws {
        let state = status ?? work.receipt.status
        let label = ["preparing": "準備中", "completed": "完成", "timed_out": "逾時", "failed": "失敗", "not_submitted": "未送出"][state] ?? state
        let safeModel = Self.sensitive(work.request.model) ? "[rejected]" : work.request.model
        let file = work.receipt.replyPath.map { "chatgpt-dispatch/" + URL(fileURLWithPath: $0).lastPathComponent } ?? "未產生"
        let summary = "派工：\(label)\n主導：\(work.caller.uuidString)\n模型：\(safeModel)\n回覆檔：\(file)"
        try journal.append(HandsRoomCall(id: work.id, at: Date(), projectID: work.projectID,
            grantTag: "local", tool: "chatgpt_dispatch", summary: summary,
            workspaceID: nil, approval: nil))
    }

    private func finish(_ work: Work, status: String, reason: String, stop: Bool = false, fixedReason: Bool = false) {
        guard active[work.caller] === work else { return }
        active[work.caller] = nil
        work.timer?.cancel(); work.task?.cancel()
        if stop, let requestID = work.requestID { tap.stop(requestID: requestID) }
        work.receipt.status = status
        work.receipt.reason = fixedReason ? reason : ChatGPTLocalText.clean(HandsRedactor.redact(HandsSecretLines.maskText(reason)), limit: 160)
        if !work.full.isEmpty, let output = work.output {
            do {
                let metadata = "# ChatGPT 派工回覆\n\n- dispatchID: \(work.id.uuidString)\n- conversationID: \(work.receipt.conversationID ?? "unknown")\n- status: \(status)\n- stopped: \(work.receipt.stopped)\n\n"
                try output.write(Data((metadata + work.full).utf8))
                work.receipt.replyPath = output.path
                let safe = HandsRedactor.redact(HandsSecretLines.maskText(work.full)).components(separatedBy: "\n")
                    .map { ChatGPTLocalText.clean($0, limit: 1000) }
                work.receipt.summary = String(safe.prefix(5).joined(separator: "\n").prefix(1000))
            } catch { work.receipt.status = "failed"; work.receipt.reason = "回覆檔未能安全寫入，請查看 ChatGPT 對話；不要直接重送" }
        }
        do { try record(work) }
        catch { work.receipt.status = "failed"; work.receipt.reason = "派工已收尾但 ChatGPT 房紀錄未能更新；請查看對話及回覆檔，不要直接重送" }
        if work.resultUnconfirmed, let key = work.dedupKey { uncertain[work.caller, default: [:]][key] = work.receipt }
        work.continuation?.resume(returning: work.receipt); work.continuation = nil
    }

    private struct Prepared: Sendable { let text: String; let output: Output }
    nonisolated private static func prepare(_ request: Request, room: URL, id: UUID) throws -> Prepared {
        let text: String
        if let inline = request.text { text = inline }
        else {
            let raw = request.ticketPath!
            let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : room.appendingPathComponent(raw)
            text = try HandsSkillet.readOwned(url, root: room)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65536 else { throw Failure("ticket_empty_or_over_64KiB") }
        for field in [text, request.title, request.model] {
            // Scan the whole value before truncation; labelled short passwords also fail closed.
            if let category = rejectionCategory(field) { throw Failure(category) }
        }
        return Prepared(text: text, output: try Output(room: room, id: id))
    }

    /// Pin the calling room and child directory. No symlink traversal, overwrite or pathname rename race.
    private final class Output: @unchecked Sendable {
        let fd: Int32
        let name: String
        let path: String
        init(room: URL, id: UUID) throws {
            let base = open(room.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard base >= 0 else { throw Failure("room_unavailable") }
            defer { close(base) }
            let child = "chatgpt-dispatch"
            guard mkdirat(base, child, 0o700) == 0 || errno == EEXIST else { throw Failure("reply_directory_unavailable") }
            fd = openat(base, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure("reply_directory_unsafe") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                close(fd); throw Failure("reply_directory_not_private")
            }
            do { try Self.ensureGitIgnore(fd) }
            catch { close(fd); throw error }
            name = id.uuidString + ".md"
            path = room.appendingPathComponent(child).appendingPathComponent(name).path
        }
        /// Protect replies in arbitrary projects, without trusting their parent .gitignore.
        private static func ensureGitIgnore(_ fd: Int32) throws {
            let file = openat(fd, ".gitignore", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file >= 0 {
                defer { close(file) }
                guard HandsFiles.writeAll(file, Data("*\n".utf8)), fsync(file) == 0 else { throw Failure("git_ignore_write_failed") }
            } else if errno != EEXIST { throw Failure("git_ignore_unavailable") }
            let existing = openat(fd, ".gitignore", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard existing >= 0 else { throw Failure("git_ignore_unsafe") }
            defer { close(existing) }
            var info = stat()
            guard fstat(existing, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
                  (1...2).contains(info.st_size) else { throw Failure("git_ignore_unsafe") }
            var bytes = [UInt8](repeating: 0, count: 3)
            let count = Darwin.read(existing, &bytes, 3)
            guard count == info.st_size, bytes[0] == 42, count == 1 || bytes[1] == 10 else { throw Failure("git_ignore_unsafe") }
        }
        deinit { close(fd) }
        private func checkLocation() throws {
            let current = open(URL(fileURLWithPath: path).deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard current >= 0 else { throw Failure("reply_directory_changed") }
            defer { close(current) }
            var pinned = stat(), observed = stat()
            guard fstat(fd, &pinned) == 0, fstat(current, &observed) == 0,
                  pinned.st_dev == observed.st_dev, pinned.st_ino == observed.st_ino else { throw Failure("reply_directory_changed") }
        }
        func write(_ data: Data) throws {
            try checkLocation()
            try Self.ensureGitIgnore(fd)
            let temporary = ".reply-" + UUID().uuidString
            let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw Failure("reply_create_failed") }
            defer { close(file); unlinkat(fd, temporary, 0) }
            guard HandsFiles.writeAll(file, data), fsync(file) == 0,
                  linkat(fd, temporary, fd, name, 0) == 0 else { throw Failure("reply_write_failed") }
            try checkLocation()
        }
    }
}
