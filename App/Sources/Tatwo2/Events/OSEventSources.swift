import Foundation

@MainActor enum OSEventSources {
    final class Context {
        weak var engine: ChatLiveEngine?
        var activeTurns: [UUID: String] = [:]
        var completed: Set<String> = []
        init(_ engine: ChatLiveEngine) { self.engine = engine }
    }
    struct Send { var origin: String; var actor: String; var surface: String? }
    static var send = Send(origin: "system", actor: "系統", surface: nil)
    private static var engines: [String: Context] = [:]
    static func register(_ engine: ChatLiveEngine) { engines[engine.store.url.deletingLastPathComponent().path] = Context(engine) }
    static func context(_ engine: ChatLiveEngine) -> Context {
        let key = engine.store.url.deletingLastPathComponent().path
        if engines[key]?.engine !== engine { register(engine) }; return engines[key]!
    }
    static func scope<T>(origin: String, actor: String = "你", surface: String? = nil, _ body: () -> T) -> T {
        let previous = send; send = Send(origin: origin, actor: actor, surface: surface); defer { send = previous }; return body()
    }
    static func begin(origin: String, actor: String, surface: String? = nil) -> Send {
        let previous = send; send = Send(origin: origin, actor: actor, surface: surface); return previous
    }
    static func resolve(_ root: URL, thread: UUID, _ body: (ChatLiveEngine, UUID?, String?) -> Void) {
        guard let engine = engines[root.path]?.engine else { return }
        body(engine, engine.threadRecord(thread)?.projectID ?? engine.doc.generalProjectID, engine.messages[thread]?.last { $0.role == .user }?.id)
    }
}

extension ChatLiveEngine {
    private var events: OSEventLog { OSEventLog.atRoot(store.url.deletingLastPathComponent()) }
    private func eventProject(_ thread: UUID) -> UUID? { threadRecord(thread)?.projectID ?? doc.generalProjectID }
    func eventsSelected(_ thread: UUID) {
        events.append(project: eventProject(thread), thread: thread, actor: "你", kind: "thread_select")
        OSPresence.shared.select(thread, project: eventProject(thread), log: events)
    }
    func eventsTurnStarted(_ thread: UUID, turn: String) {
        let context = OSEventSources.context(self)
        if !context.completed.contains(turn) { context.activeTurns[thread] = turn }
    }
    func eventsRow(_ thread: UUID, _ row: ChatMessage) {
        guard row.eventKind == .toolUse || row.role == .user else { return }
        let record = threadRecord(thread), purpose = row.role == .user ? row.id : messages[thread]?.last { $0.role == .user }?.id
        if row.eventKind == .toolUse {
            let name = row.status?.split(separator: "|").last.map(String.init) ?? "工具"
            events.append(project: eventProject(thread), thread: thread, actor: (record?.engine ?? "引擎") + "/" + (row.modelID ?? record?.model ?? "未知"),
                          kind: "tool_step", purpose: purpose, used: ["@" + name], note: "工具步驟")
        } else {
            let source = OSEventSources.send
            if let turn = row.turnID { eventsTurnStarted(thread, turn: turn) }
            events.append(project: eventProject(thread), thread: thread, actor: source.actor, kind: "user_send", purpose: row.id, sizeText: row.text, note: "送出訊息", origin: source.origin)
            if source.origin == "composer" { OSPresence.shared.record(thread: thread, project: eventProject(thread), log: events, surface: source.surface) }
        }
    }
    func eventsFinished(_ thread: UUID, succeeded: Bool, turn: String? = nil) {
        let context = OSEventSources.context(self)
        guard let active = context.activeTurns[thread], turn == nil || turn == active else { return }
        context.activeTurns.removeValue(forKey: thread); guard context.completed.insert(active).inserted else { return }
        let record = threadRecord(thread)
        events.append(project: eventProject(thread), thread: thread, actor: record?.engine == TatwoChatRuntimeAdapter.chatgptTap.rawValue ? "TAP/ChatGPT" : (record?.engine ?? "引擎") + "/" + (messages[thread]?.last { $0.turnID == active && $0.modelID != nil }?.modelID ?? record?.model ?? "未知"),
                      kind: "turn_end", purpose: messages[thread]?.last { $0.role == .user }?.id, result: succeeded ? "通過" : "失敗", sizeText: messages[thread]?.last { $0.turnID == active && $0.role == .assistant && $0.eventKind == .message }?.text, id: "turn:" + thread.uuidString + ":" + active, turn: active)
    }
    func eventsPermission(_ thread: UUID, allowed: Bool, human: Bool) {
        let project = eventProject(thread)
        events.append(project: project, thread: thread, actor: human ? "你" : "系統", kind: "permission_decision", result: allowed ? "核准" : "退回")
        if human { OSPresence.shared.record(thread: thread, project: project, log: events) }
    }
    func eventsNativeGoal(_ thread: UUID, previous: ChatNativeGoal?) {
        if let goal = threadRecord(thread)?.nativeGoal, goal.status == "complete", previous?.status != "complete" {
            events.append(project: eventProject(thread), thread: thread, actor: "codex/" + (threadRecord(thread)?.model ?? "未知"), kind: "goal_complete", purpose: messages[thread]?.last { $0.role == .user }?.id, result: "通過")
        }
    }
}

@MainActor func eventsDecision(_ context: DispatchGitContext, result: String, messenger: any DispatchRoomMessaging) {
    guard let engine = messenger as? ChatLiveEngine else { return }
    let log = OSEventLog.atRoot(engine.store.url.deletingLastPathComponent()), project = engine.threadRecord(context.id)?.projectID ?? engine.doc.generalProjectID
    log.append(project: project, thread: context.id, actor: "你", kind: "change_decision", result: result)
    OSPresence.shared.record(thread: context.id, project: project, log: log)
}
@MainActor func eventsHandsThread(_ engine: ChatLiveEngine?, project: UUID?, workspace: UUID?) -> UUID? {
    if let row = engine?.threadRecord(workspace) { return row.id }
    return engine?.doc.threads.first { $0.engine == ChatLiveEngine.handsEngine && $0.parentThreadID == nil && !$0.isArchived && $0.projectID == (project ?? engine?.doc.generalProjectID) }?.id
}
func eventsHands(id: UUID, project: UUID?, thread: UUID?, workspace: UUID?, tool: String, at: Date, root: URL) {
    OSEventLog.atRoot(root).append(project: project, thread: thread, actor: "TAP/ChatGPT", kind: "hands_tool", at: at, used: ["@" + tool], id: id.uuidString.lowercased(), workspace: workspace)
}
func eventsJob(_ record: BackgroundJobManager.Record, root: URL, ended: Bool) {
    DispatchQueue.main.async {
        OSEventSources.resolve(root, thread: record.threadID) { _, project, purpose in
            OSEventLog.atRoot(root).append(project: project, thread: record.threadID, actor: "系統", kind: ended ? "job_end" : "job_start", at: ended ? Date() : record.startedAt,
                                         purpose: purpose, result: ended && record.exitCode != nil ? (record.exitCode == 0 ? "通過" : "失敗") : nil)
        }
    }
}
func eventsGoals(_ thread: UUID, before: ThreadGoalList, after: ThreadGoalList, root: URL) {
    let append: @MainActor () -> Void = {
        OSEventSources.resolve(root, thread: thread) { _, project, purpose in
            for goal in after.goals where goal.status == .done && before.goals.first(where: { $0.id == goal.id })?.status != .done {
                OSEventLog.atRoot(root).append(project: project, thread: thread, actor: "系統", kind: "goal_complete", purpose: purpose, result: "通過")
            }
        }
    }
    if Thread.isMainThread { MainActor.assumeIsolated(append) } else { DispatchQueue.main.async { append() } }
}
