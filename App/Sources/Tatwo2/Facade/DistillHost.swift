import Foundation

/// W180 E4：/蒸餾 畫布在「這台」（主設備或單機）的所有動作：開畫布、讀、改、預覽、確認寫入、還原。
/// 本機畫布按鈕、已配對設備經 SSH 轉進來的 distill_open／distill_get／distill_edit／distill_write 都走這裡，
/// 所以寫入一律在這台執行、這台再檢查一次（名稱、保留名、EngineRuleAudit、原檔 sha）。
/// 只碰指定那條討論串的 /蒸餾 畫布：別種畫布（plan、feedback、pr）讀不到也改不了；不執行指令、不操作電腦。
struct DistillHostContext {
    let roots: DistillWriterRoots
    /// 寫進封存紀錄的名字（只給人看）。
    let device: String
    /// GBrain adapter 定義（JSON）；GBrain 不可用時是 nil。
    let gbrainDefinition: () -> Data?
}

/// 一次請求（先在收到的執行緒解析成 Sendable，才進主執行緒）。
struct DistillRemoteRequest: Sendable, Equatable {
    /// status＝查某次寫入或還原的結果（那台先回「寫入中」、或連線斷掉時用）。
    enum Action: String, Sendable { case preview, apply, restore, status }
    let method: String
    var threadID: UUID?
    var planID: UUID?
    var argument: String?
    var text: String?
    var output: DistillOutputKind?
    var canvasAction: String?
    var action: Action?
    var content: String?
    var submissionID: UUID?
    var expected: DistillWritePlan?
    var archivePath: String?
    var source: String?

    static let methods: Set<String> = ["distill_open", "distill_get", "distill_edit", "distill_write"]
    private static let keys: [String: Set<String>] = [
        "distill_open": ["threadID", "argument"],
        "distill_get": ["threadID"],
        "distill_edit": ["threadID", "planID", "text", "output", "canvasAction"],
        "distill_write": ["threadID", "planID", "action", "output", "content", "submissionID", "expected", "archivePath", "source"],
    ]

    static func parse(method: String, params: [String: Any]) throws -> DistillRemoteRequest {
        guard let allowed = keys[method], Set(params.keys).isSubset(of: allowed) else { throw DistillCanvas.Failure(reason: "invalid_params") }
        func uuid(_ key: String) throws -> UUID? {
            guard let raw = params[key] else { return nil }
            guard let text = raw as? String, let id = UUID(uuidString: text) else { throw DistillCanvas.Failure(reason: "invalid_params") }
            return id
        }
        func string(_ key: String, limit: Int) throws -> String? {
            guard let raw = params[key] else { return nil }
            guard let text = raw as? String, text.utf8.count <= limit, !text.contains("\0") else { throw DistillCanvas.Failure(reason: "invalid_params") }
            return text
        }
        var request = DistillRemoteRequest(method: method)
        request.threadID = try uuid("threadID")
        request.planID = try uuid("planID")
        request.submissionID = try uuid("submissionID")
        request.argument = try string("argument", limit: 4_096)
        request.canvasAction = try string("canvasAction", limit: 16)
        if let action = request.canvasAction, !["archive", "restore"].contains(action) { throw DistillCanvas.Failure(reason: "invalid_params") }
        request.text = try string("text", limit: DistillCanvas.maxBytes)
        request.content = try string("content", limit: DistillCanvas.maxBytes)
        request.archivePath = try string("archivePath", limit: 4_096)
        request.source = try string("source", limit: 200)
        if let raw = try string("output", limit: 32) {
            guard let output = DistillOutputKind(rawValue: raw) else { throw DistillCanvas.Failure(reason: "invalid_params") }
            request.output = output
        }
        if let raw = try string("action", limit: 32) {
            guard let action = Action(rawValue: raw) else { throw DistillCanvas.Failure(reason: "invalid_params") }
            request.action = action
        }
        if let raw = params["expected"] {
            guard JSONSerialization.isValidJSONObject(raw),
                  let plan = try? JSONDecoder().decode(DistillWritePlan.self, from: JSONSerialization.data(withJSONObject: raw)) else {
                throw DistillCanvas.Failure(reason: "invalid_params")
            }
            request.expected = plan
        }
        switch method {
        case "distill_open", "distill_get":
            guard request.threadID != nil else { throw DistillCanvas.Failure(reason: "invalid_params") }
        case "distill_edit":
            guard request.threadID != nil, request.planID != nil, request.text != nil || request.output != nil || request.canvasAction != nil else {
                throw DistillCanvas.Failure(reason: "invalid_params")
            }
        default:
            // 每一種都要帶畫布編號；沒有討論串的（副設備自己那條）還要帶那次寫入的編號，還原才綁得到它自己那次。
            guard let action = request.action, request.planID != nil else { throw DistillCanvas.Failure(reason: "invalid_params") }
            let threadless = request.threadID == nil
            switch action {
            case .preview:
                guard !threadless || (request.content != nil && request.output != nil) else { throw DistillCanvas.Failure(reason: "invalid_params") }
            case .apply:
                guard request.expected != nil, request.submissionID != nil,
                      !threadless || request.content != nil else { throw DistillCanvas.Failure(reason: "invalid_params") }
            case .restore:
                guard !threadless || (request.archivePath != nil && request.submissionID != nil) else { throw DistillCanvas.Failure(reason: "invalid_params") }
            case .status:
                guard request.submissionID != nil else { throw DistillCanvas.Failure(reason: "invalid_params") }
            }
        }
        return request
    }

    /// 送出去的參數（RemoteLiveEngine 與自測共用，形狀一樣）。
    func params() throws -> [String: Any] {
        var result: [String: Any] = [:]
        if let threadID { result["threadID"] = threadID.uuidString }
        if let planID { result["planID"] = planID.uuidString }
        if let submissionID { result["submissionID"] = submissionID.uuidString }
        if let argument { result["argument"] = argument }
        if let text { result["text"] = text }
        if let canvasAction { result["canvasAction"] = canvasAction }
        if let content { result["content"] = content }
        if let archivePath { result["archivePath"] = archivePath }
        if let source { result["source"] = source }
        if let output { result["output"] = output.rawValue }
        if let action { result["action"] = action.rawValue }
        if let expected { result["expected"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) }
        return result
    }
}

/// 寫入或還原的結果（本機與遠端同一個形狀）。
struct DistillWriteResult: Codable, Equatable, Sendable {
    /// done｜failed（沒寫，可改完重來）｜unconfirmed（請先查目的地）｜restored｜
    /// writing（那台還在寫，稍後用 status 查）｜unknown（那台查不到這次寫入）
    let status: String
    let lines: [String]
    let archivePath: String?
    /// 這個結果是寫入（apply）還是還原（restore）的；狀態查詢時用來分辨「失敗」是哪一個。
    var mode: String?
    var message: String { lines.joined(separator: "\n") }
    var failed: Bool { status == "failed" || status == "unconfirmed" || status == "unknown" }
    /// 還沒有定論，要再查。
    var pending: Bool { status == "writing" || status == "unknown" }
}

struct DistillRemoteReply: Sendable {
    var canvas: TatwoPlanArtifactV1?
    var plan: DistillWritePlan?
    var result: DistillWriteResult?
    /// 要在背景跑的寫入；跑完交給 finish。
    var job: DistillWriteJob?
    var archives: [TatwoPlanArtifactV1]?

    func object() throws -> [String: Any] {
        var object: [String: Any] = ["canvas": NSNull()]
        if let archives { object["archives"] = try archives.map { try JSONSerialization.jsonObject(with: $0.canonicalJSONData()) } }
        if let canvas { object["canvas"] = try JSONSerialization.jsonObject(with: canvas.canonicalJSONData()) }
        if let plan { object["plan"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) }
        if let result { object["result"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) }
        return object
    }

    static func decode(_ object: [String: Any]) throws -> DistillRemoteReply {
        func data(_ key: String) throws -> Data? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            guard JSONSerialization.isValidJSONObject(value) else { throw RemoteHostLinkError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: value)
        }
        var reply = DistillRemoteReply()
        if let raw = object["archives"] {
            reply.archives = try JSONDecoder.tatwoPlanArtifact.decode([TatwoPlanArtifactV1].self, from: JSONSerialization.data(withJSONObject: raw))
            guard reply.archives!.allSatisfy({ $0.kind == "distill" }) else { throw RemoteHostLinkError.invalidResponse }
        }
        if let raw = try data("canvas") {
            let canvas = try JSONDecoder.tatwoPlanArtifact.decode(TatwoPlanArtifactV1.self, from: raw)
            guard canvas.kind == "distill" else { throw RemoteHostLinkError.invalidResponse }
            reply.canvas = canvas
        }
        if let raw = try data("plan") { reply.plan = try JSONDecoder().decode(DistillWritePlan.self, from: raw) }
        if let raw = try data("result") { reply.result = try JSONDecoder().decode(DistillWriteResult.self, from: raw) }
        return reply
    }
}

/// 橋接層等背景寫入結果用：寫好就交結果，等不到就先回「寫入中」。
final class DistillReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var value: DistillRemoteReply?

    func finish(_ reply: DistillRemoteReply) {
        lock.lock(); value = reply; lock.unlock()
        done.signal()
    }

    /// 最多等 seconds 秒；0＝不等。
    func wait(_ seconds: TimeInterval) -> DistillRemoteReply? {
        guard seconds > 0, done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// 橋接層（背景執行緒）也要讀的時間設定。
enum DistillWire {
    #if DEBUG
    /// 寫入送出後，這台在回覆前最多等幾秒；等不到就先回「寫入中」，對方用 status 查。0＝不等（自測走查詢那條路）。
    nonisolated(unsafe) static var replyWait: TimeInterval = 5
    /// 對方查結果的間隔（秒）。
    nonisolated(unsafe) static var pollInterval: TimeInterval = 1
    #else
    static let replyWait: TimeInterval = 5
    static let pollInterval: TimeInterval = 1
    #endif
    /// 查結果最多查多久（GBrain 每一步最多等 45 秒）。
    static let pollDeadline: TimeInterval = 240
}

@MainActor
enum DistillHost {
    static func failure(_ reason: String) -> DistillCanvas.Failure { DistillCanvas.Failure(reason: reason) }

    /// 這次開機以來在這台跑過的寫入與還原（用 submissionID 查；對方逾時、斷線也查得回來）。
    struct Recorded {
        let planID: UUID?
        let threadID: UUID?
        var result: DistillWriteResult
    }
    private(set) static var recent: [UUID: Recorded] = [:]
    private static var recentOrder: [UUID] = []
    /// 正在寫（或還原）的那一次；寫入中的畫布不能被新的 /蒸餾 蓋掉。
    private(set) static var inFlight: Set<UUID> = []

    private static func record(_ id: UUID, _ entry: Recorded) {
        if recent[id] == nil { recentOrder.append(id) }
        recent[id] = entry
        while recentOrder.count > 200 { recent[recentOrder.removeFirst()] = nil }
    }

    /// 這台要把某次寫入交給別台（副設備交主設備）時，也標成寫入中。
    static func markInFlight(_ id: UUID) { inFlight.insert(id) }
    static func clearInFlight(_ id: UUID) { inFlight.remove(id) }

    /// 指定那條的 /蒸餾 畫布；別種畫布當作沒有。
    static func canvas(_ engine: ChatLiveEngine, _ threadID: UUID) throws -> TatwoPlanArtifactV1? {
        guard engine.threadRecord(threadID) != nil else { throw failure("找不到這條討論串") }
        guard let plan = try engine.loadPlanArtifact(threadID), plan.kind == "distill" else { return nil }
        return plan
    }

    private static func distillCanvas(_ engine: ChatLiveEngine, _ threadID: UUID, _ planID: UUID?) throws -> TatwoPlanArtifactV1 {
        guard let plan = try canvas(engine, threadID) else { throw failure("這條沒有 /蒸餾 畫布（別種畫布不能從這裡改）") }
        guard planID == nil || plan.planID == planID else { throw failure("畫布已經換了一張；請重新打開") }
        return plan
    }

    /// 還沒寫完或還能還原的寫入（開新畫布時留在歷史，還原鈕不跟著舊畫布消失）。
    private static func keepsHistory(_ submission: DistillSubmission) -> Bool {
        guard let status = submission.status else { return false }   // W81 舊版送出：只有紀錄，沒有還原
        return status != "restored"
    }

    /// 開一張新的 /蒸餾 畫布（預設技能）。
    /// - 上一份還在寫入：不開（寫完才知道結果）。
    /// - 上一份已寫入、還能還原（或還沒確認）：留在新畫布的「之前的寫入」，還原照樣按得到。
    /// - 遠端（已配對設備）看不到別種畫布：這條在這台有進行中的計畫、回報或 PR 畫布就不蓋，請在這台處理。
    static func open(engine: ChatLiveEngine, threadID: UUID, argument: String, remote: Bool) throws -> TatwoPlanArtifactV1 {
        guard engine.threadRecord(threadID) != nil, !engine.doc.isAssistantThread(threadID) else { throw failure("找不到這條討論串") }
        guard !engine.isRunning(threadID) else { throw failure("這條正在回覆，等它回完再 /蒸餾") }
        var plan = DistillCanvas.newPlan(threadID: threadID, argument: argument)
        if let existing = try engine.loadPlanArtifact(threadID) {
            if existing.kind == "distill" {
                let all = (existing.distillEarlier ?? []) + [existing.distillSubmission].compactMap { $0 }
                if all.contains(where: { inFlight.contains($0.id) }) {
                    throw failure("上一份 /蒸餾 還在寫入或還原；等它有結果再開新的")
                }
                let kept = all.filter(keepsHistory)
                plan.distillEarlier = kept.isEmpty ? nil : kept
            } else if remote && !finishedOtherCanvas(existing, engine: engine) {
                throw failure("這條在主設備有進行中的\(existing.kind == "pr" ? " PR" : existing.kind == "feedback" ? "回報" : "計畫")畫布；請先在主設備處理完再 /蒸餾")
            }
        }
        try engine.savePlanArtifact(plan)
        return plan
    }

    /// 別種畫布已經做完（可以換成 /蒸餾 畫布）：計畫確認並開工過、回報已送出；PR 一律當進行中。
    private static func finishedOtherCanvas(_ plan: TatwoPlanArtifactV1, engine: ChatLiveEngine) -> Bool {
        guard plan.kind != "pr", plan.state == .confirmed, !engine.isRunning(plan.threadID) else { return false }
        return plan.kind == "feedback" || plan.executionTurnID != nil
    }

    /// 人手改畫布全文（逐位元保存）或換類型（只存畫布、不自動送出）。送出寫入後就鎖住。
    static func edit(engine: ChatLiveEngine, threadID: UUID, planID: UUID?, text: String?, output: DistillOutputKind?) throws -> TatwoPlanArtifactV1 {
        var plan = try distillCanvas(engine, threadID, planID)
        guard plan.distillSubmission == nil else { throw failure("已經寫入過，畫布鎖住了") }
        guard !engine.isRunning(threadID) else { throw failure("請等回覆完成再改畫布") }
        if let text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("畫布不可空白") }
            plan.applyEditedText(text)
        }
        if let output { plan.distillOutput = output; plan.state = .discussing }
        try engine.savePlanArtifact(plan)
        return plan
    }

    /// 預覽：這台重新算寫到哪、會不會封存同名舊檔。
    static func preview(content: String, output: DistillOutputKind, planID: UUID, context: DistillHostContext) throws -> DistillWritePlan {
        if output == .gbrain, context.gbrainDefinition() == nil { throw failure("GBrain 不可用；可改選技能、清單或 SOP。") }
        return try DistillWriter.preview(output: output, content: content, planID: planID, roots: context.roots)
    }

    /// 處理一次請求。寫入與還原回傳 job：呼叫端在背景跑 `DistillWriter.perform(job)`，再把結果交給 `finish`。
    static func begin(_ request: DistillRemoteRequest, engine: ChatLiveEngine, context: DistillHostContext) throws -> DistillRemoteReply {
        switch request.method {
        case "distill_open":
            return DistillRemoteReply(canvas: try open(engine: engine, threadID: request.threadID!, argument: request.argument ?? "", remote: true))
        case "distill_get":
            return DistillRemoteReply(canvas: try canvas(engine, request.threadID!), archives: try engine.archivedPlanArtifacts(request.threadID!).filter { $0.kind == "distill" })
        case "distill_edit":
            if let action = request.canvasAction {
                let threadID = request.threadID!, planID = request.planID!
                guard engine.threadRecord(threadID) != nil, !engine.isRunning(threadID), !inFlight.contains(planID) else { throw failure("distill_busy") }
                if action == "archive" {
                    let plan = try distillCanvas(engine, threadID, planID)
                    try engine.archivePlanArtifact(plan)
                    return DistillRemoteReply(archives: try engine.archivedPlanArtifacts(threadID).filter { $0.kind == "distill" })
                }
                guard let saved = try engine.archivedPlanArtifacts(threadID).first(where: { $0.planID == planID }), saved.kind == "distill",
                      !(try engine.loadPlanArtifact(threadID).map { inFlight.contains($0.planID) } ?? false) else { throw failure("invalid_params") }
                let plan = try engine.restorePlanArtifact(threadID, planID: planID)
                return DistillRemoteReply(canvas: plan, archives: try engine.archivedPlanArtifacts(threadID).filter { $0.kind == "distill" })
            }
            return DistillRemoteReply(canvas: try edit(engine: engine, threadID: request.threadID!, planID: request.planID,
                                                       text: request.text, output: request.output))
        case "distill_write":
            break
        default:
            throw failure("invalid_params")
        }
        let device = [context.device, request.source.map { "來自 \($0)" }].compactMap { $0 }.joined(separator: "，")
        if request.action == .status {
            return status(submissionID: request.submissionID!, planID: request.planID!, threadID: request.threadID,
                          engine: engine, roots: context.roots)
        }
        // 已配對設備自己那台的 session（少見）：沒有這台的畫布，只帶全文來；檢查與寫入照樣在這台做。
        guard let threadID = request.threadID else {
            let planID = request.planID!
            switch request.action! {
            case .preview:
                return DistillRemoteReply(plan: try preview(content: request.content!, output: request.output!, planID: planID, context: context))
            case .apply:
                let fresh = try preview(content: request.content!, output: request.expected!.output, planID: planID, context: context)
                guard fresh == request.expected else { throw failure("預覽之後內容或同名檔變了；沒有寫入，請重新預覽。") }
                return DistillRemoteReply(job: job(.apply, fresh, request.content!, context: context, device: device,
                                                   threadID: nil, planID: planID, submissionID: request.submissionID!, archivePath: nil))
            case .restore:
                let plan = DistillWritePlan(output: request.output ?? .skill, name: "", title: "", targets: [], contentSHA: "")
                return DistillRemoteReply(job: job(.restore, plan, "", context: context, device: device, threadID: nil,
                                                   planID: planID, submissionID: request.submissionID!, archivePath: request.archivePath))
            case .status:
                throw failure("invalid_params")
            }
        }
        var plan = try distillCanvas(engine, threadID, request.planID)
        let content = plan.editableText()
        let output = DistillCanvas.output(of: plan)
        switch request.action! {
        case .preview:
            if let sent = request.content, !DistillCanvas.byteEqual(sent, content) { throw failure("畫布已經改過；請重新預覽。") }
            return DistillRemoteReply(canvas: plan, plan: try preview(content: content, output: output, planID: plan.planID, context: context))
        case .apply:
            guard plan.distillSubmission == nil else { throw failure("這張畫布已經寫入過；不重複寫。") }
            guard !engine.isRunning(threadID) else { throw failure("請等回覆完成再寫入") }
            if let sent = request.content, !DistillCanvas.byteEqual(sent, content) { throw failure("畫布已經改過；請重新預覽。") }
            let fresh = try preview(content: content, output: output, planID: plan.planID, context: context)
            guard fresh == request.expected else { throw failure("預覽之後內容或同名檔變了；沒有寫入，請重新預覽。") }
            // 人按了「確認寫入」的界線：先把這份快照存進畫布，才碰任何目的地；中斷也不會自動重送。
            var submission = DistillSubmission(id: request.submissionID!, threadID: threadID, content: content, title: fresh.title,
                                               slug: fresh.name, gbrain: output == .gbrain, skillet: false,
                                               message: "寫入中；若中斷，請先查目的地，不會自動重送。")
            submission.output = output
            submission.targets = fresh.targets
            submission.status = "writing"
            submission.planID = plan.planID
            plan.distillSubmission = submission
            plan.confirm()
            try engine.savePlanArtifact(plan)
            return DistillRemoteReply(canvas: plan, job: job(.apply, fresh, content, context: context, device: device, threadID: threadID,
                                                             planID: plan.planID, submissionID: submission.id, archivePath: nil))
        case .restore:
            // 預設還原這張畫布的寫入；帶了 submissionID 就是「之前的寫入」那一份。
            let wanted = request.submissionID ?? plan.distillSubmission?.id
            let candidates = [plan.distillSubmission].compactMap { $0 } + (plan.distillEarlier ?? [])
            guard let submission = candidates.first(where: { $0.id == wanted }), submission.status == "done",
                  submission.restoredAt == nil, let archive = submission.archivePath else { throw failure("這張畫布沒有可以還原的寫入。") }
            guard !inFlight.contains(submission.id) else { throw failure("這次寫入正在處理中；等它有結果再還原。") }
            let recorded = DistillWritePlan(output: submission.output ?? output, name: submission.slug, title: submission.title,
                                            targets: submission.targets ?? [], contentSHA: DistillCanvas.sha256(submission.content))
            return DistillRemoteReply(canvas: plan, job: job(.restore, recorded, submission.content, context: context, device: device,
                                                             threadID: threadID, planID: submission.planID ?? plan.planID,
                                                             submissionID: submission.id, archivePath: archive))
        case .status:
            throw failure("invalid_params")
        }
    }

    /// 建一個要在背景跑的工作，並記成「寫入中」（狀態查詢查得到；寫入中的畫布不能被蓋掉）。
    private static func job(_ mode: DistillWriteJob.Mode, _ plan: DistillWritePlan, _ content: String, context: DistillHostContext,
                            device: String, threadID: UUID?, planID: UUID, submissionID: UUID, archivePath: String?) -> DistillWriteJob {
        inFlight.insert(submissionID)
        record(submissionID, Recorded(planID: planID, threadID: threadID,
                                      result: DistillWriteResult(status: "writing", lines: [mode == .apply ? "寫入中…" : "還原中…"],
                                                                 archivePath: nil, mode: mode.rawValue)))
        // 還原時一律帶 GBrain（封存裡有 GBrain 舊頁才用得到）；寫入只有 GBrain 類型才帶。
        return DistillWriteJob(mode: mode, plan: plan, content: content, roots: context.roots, device: device, threadID: threadID,
                               planID: planID, submissionID: submissionID, archivePath: archivePath,
                               gbrainDefinition: plan.output == .gbrain || mode == .restore ? context.gbrainDefinition() : nil)
    }

    nonisolated static func result(_ mode: DistillWriteJob.Mode, _ outcome: DistillWriteOutcome) -> DistillWriteResult {
        switch outcome {
        case .done(let lines, let archive):
            return DistillWriteResult(status: mode == .apply ? "done" : "restored", lines: lines, archivePath: archive, mode: mode.rawValue)
        case .cleanFailure(let reason): return DistillWriteResult(status: "failed", lines: [reason], archivePath: nil, mode: mode.rawValue)
        case .unconfirmed(let reason): return DistillWriteResult(status: "unconfirmed", lines: [reason], archivePath: nil, mode: mode.rawValue)
        }
    }

    /// 某次寫入或還原現在的結果：先看這次開機以來的紀錄，再看畫布（有討論串）或封存紀錄（沒有討論串）。
    static func status(submissionID: UUID, planID: UUID, threadID: UUID?, engine: ChatLiveEngine, roots: DistillWriterRoots) -> DistillRemoteReply {
        let canvas = threadID.flatMap { try? Self.canvas(engine, $0) }
        if let entry = recent[submissionID], entry.planID == planID, entry.threadID == threadID {
            return DistillRemoteReply(canvas: canvas, result: entry.result)
        }
        if threadID != nil {
            let all = [canvas?.distillSubmission].compactMap { $0 } + (canvas?.distillEarlier ?? [])
            if let submission = all.first(where: { $0.id == submissionID }) {
                return DistillRemoteReply(canvas: canvas, result: statusResult(submission))
            }
        } else if let found = DistillWriter.recorded(submissionID: submissionID, planID: planID, roots: roots) {
            let path = found.archive.path
            let result: DistillWriteResult
            if found.manifest.restoredAt != nil {
                result = DistillWriteResult(status: "restored", lines: ["已還原；封存：\(path)"], archivePath: path, mode: "restore")
            } else if found.manifest.writtenAt != nil {
                result = DistillWriteResult(status: "done", lines: ["已寫入：" + found.manifest.entries.map(\.path).joined(separator: "、"),
                                                                    "封存：\(path)"], archivePath: path, mode: "apply")
            } else if let reason = found.manifest.abandoned {
                result = DistillWriteResult(status: "failed", lines: [reason], archivePath: nil, mode: "apply")
            } else {
                result = DistillWriteResult(status: "unconfirmed", lines: ["寫入沒有確認；請看 \(path)/還原.md"], archivePath: nil, mode: "apply")
            }
            return DistillRemoteReply(result: result)
        }
        return DistillRemoteReply(canvas: canvas, result: DistillWriteResult(status: "unknown", lines: ["這台查不到這次寫入的紀錄"],
                                                                            archivePath: nil))
    }

    private static func statusResult(_ submission: DistillSubmission) -> DistillWriteResult {
        // 寫入或還原正在跑：畫布上的狀態還是舊的，照「寫入中」回。
        if inFlight.contains(submission.id) {
            return DistillWriteResult(status: "writing", lines: [submission.message], archivePath: nil)
        }
        switch submission.status {
        case "done"?:
            return DistillWriteResult(status: "done", lines: submission.receiptLines ?? [submission.message],
                                      archivePath: submission.archivePath, mode: "apply")
        case "restored"?:
            return DistillWriteResult(status: "restored", lines: submission.receiptLines ?? [submission.message],
                                      archivePath: submission.archivePath, mode: "restore")
        default:
            return DistillWriteResult(status: "unconfirmed", lines: [submission.message], archivePath: nil)
        }
    }

    /// 一次寫入或還原的結果套到那一份送出紀錄上；nil＝這份拿掉（寫入前就失敗，畫布解鎖）。
    static func applying(_ mode: DistillWriteJob.Mode, _ outcome: DistillWriteOutcome, to submission: DistillSubmission,
                         now: Date) -> DistillSubmission? {
        var submission = submission
        let written = result(mode, outcome)
        switch (mode, outcome) {
        case (.apply, .done(let lines, let archive)):
            submission.status = "done"
            submission.receiptLines = lines
            submission.archivePath = archive
            submission.message = written.message
        case (.apply, .cleanFailure):
            return nil
        case (.restore, .done(let lines, _)):
            submission.status = "restored"
            submission.restoredAt = TatwoPlanArtifactV1.storagePrecision(now)
            submission.receiptLines = (submission.receiptLines ?? []) + lines
            submission.message = written.message
        case (.restore, .cleanFailure):
            break
        case (_, .unconfirmed):
            submission.status = "unconfirmed"
            submission.message = written.message
        }
        return submission
    }

    /// 背景跑完之後：把結果存回畫布（沒有畫布的就只回結果）。什麼都沒寫的失敗會把畫布解鎖，改完可以重新預覽。
    static func finish(_ job: DistillWriteJob, _ outcome: DistillWriteOutcome, engine: ChatLiveEngine, now: Date = Date()) throws -> DistillRemoteReply {
        let written = Self.result(job.mode, outcome)
        if let id = job.submissionID {
            inFlight.remove(id)
            record(id, Recorded(planID: job.planID, threadID: job.threadID, result: written))
        }
        guard let threadID = job.threadID else { return DistillRemoteReply(result: written) }
        // 畫布可能已經換新（這一份在「之前的寫入」裡）：照 submissionID 找，不照畫布編號。
        guard var plan = try canvas(engine, threadID), let id = job.submissionID else {
            throw failure("畫布上的寫入紀錄對不上；請先查目的地，不會自動重送。")
        }
        if let submission = plan.distillSubmission, submission.id == id {
            plan.distillSubmission = applying(job.mode, outcome, to: submission, now: now)
            if plan.distillSubmission == nil { plan.state = .discussing }
        } else if let index = plan.distillEarlier?.firstIndex(where: { $0.id == id }) {
            if let updated = applying(job.mode, outcome, to: plan.distillEarlier![index], now: now) {
                plan.distillEarlier![index] = updated
            }
        } else {
            throw failure("畫布上的寫入紀錄對不上；請先查目的地，不會自動重送。")
        }
        try engine.savePlanArtifact(plan)
        return DistillRemoteReply(canvas: plan, result: written)
    }
}
