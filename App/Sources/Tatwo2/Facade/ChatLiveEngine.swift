// 2.0 真水電：把 Claude 常駐 sidecar 的事件，收斂成 1.0 畫面看得懂的 ChatMessage 列。
// 一條討論串一個 sidecar；sidecar 活著就不重開；關 App 再開用 sessionID 續接。
import AppKit
import Foundation

/// W184 H4 修正第二輪（GPT-6 H4b 審查 #1、#2、#7）：一句送出去之後的結果（呼叫端照它決定草稿）。
enum LiveSendDelivery: Equatable, Sendable {
    /// 引擎（或那台）確認收到這一輪：本機＝這一輪的第一個原生事件（Codex 的 turn_accepted、回覆、工具、成功的結果）；遠端＝那台回覆收下。
    case delivered
    /// 確定沒送到、沒執行：寫不進引擎、引擎在讀到這一句之前就結束（重開或接回原本的對話失敗）、還沒開始就失敗或被停、那台拒收。
    /// 草稿留著，可以再送一次。
    case notDelivered(String)
    /// 不確定（連線在途中斷，那台可能收了也可能沒收）：草稿留著，不自動重送（避免重複執行）；先看對話再決定。
    case unknown(String)
}

/// Shared TAP routing boundary: managed conversations must never use a private ChatGPT account.
enum ManagedConversationTAPPolicy {
    static func rejectionReason(model: String?, creator: String?) -> String? {
        guard creator != nil, let model, ChatGPTTapModelCatalog.isRouteID(model) else { return nil }
        return "受管對話不能使用 ChatGPT TAP，因為它會使用這台的私人 ChatGPT 帳號與記憶。"
    }
}

@MainActor
protocol LiveEngineAPI: AnyObject {
    var store: ChatLiveStore { get }
    var doc: LiveDocumentRecord { get }
    var document: TatwoNativeChatStoreDocument { get }
    var onChange: (() -> Void)? { get set }
    var permissionDecider: ((_ tool: String, _ inputPretty: String) -> Bool)? { get set }
    var pendingPermissionThreadIDs: Set<UUID> { get }
    var autoApprove: Bool { get set }
    var onHint: ((String) -> Void)? { get set }
    var onRoomArchived: ((UUID) -> Void)? { get set }
    var dispatchPaused: Bool { get set }

    func transcript(for threadID: UUID?) -> [ChatMessage]
    func isRunning(_ threadID: UUID?) -> Bool
    func activityDate(_ threadID: UUID) -> Date
    func threadRecord(_ threadID: UUID?) -> LiveThreadRecord?
    func projectRecord(_ projectID: UUID?) -> LiveProjectRecord?
    var archivedThreadCount: Int { get }
    func appendSystemMessage(threadID: UUID, text: String, status: String)
    func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine)
    func newThread(in projectID: UUID?, title: String) -> UUID
    func newProject(name: String, workdir: String) -> UUID
    func select(_ threadID: UUID)
    func setExpanded(_ projectID: UUID, _ expanded: Bool)
    func togglePinned(_ threadID: UUID)
    func rename(_ threadID: UUID, _ title: String)
    func archive(_ threadID: UUID) -> UUID?
    func restoreMostRecentArchivedThread() -> UUID?
    func duplicate(_ threadID: UUID, asBranch: Bool) -> UUID?
    func createDiscussion(parentThreadID: UUID) -> UUID?
    func compressDiscussion(_ discussionID: UUID) -> UUID?
    func mergeDiscussionIntoParent(_ discussionID: UUID) -> UUID?
    func setGitHubRepos(_ repos: [String], for projectID: UUID)
    func issues(threadID: UUID?, global: Bool) -> [TatwoIssueListEntryV1]
    func captureIssue(threadID: UUID)
    func addIssue(threadID: UUID, title: String, body: String)
    func updateIssue(_ id: String, _ body: (inout TatwoIssueListEntryV1) -> Void)
    func removeIssue(_ id: String)
    func gitSummary(for threadID: UUID?, completion: @escaping (ChatLiveEngine.GitSummary) -> Void)
    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind,
        systemPrompt: String?,
        attachments: [String],
        reasoningEffort: String?,
        serviceTier: String?
    ) -> Bool
    /// W184 H4 修正（審查 #2）：同上，另外明確帶這一輪的 ultrawork（檔位＋主導＋每一個副手；卡上的值）。
    /// 本機：接在送進 sidecar 的那一句後面、記成那條的偏好；遠端：序列化給主設備。nil＝呼叫端不管（照那條記住的）。
    /// W184 H4 修正第二輪（GPT-6 H4b 審查 #1、#7）：delivery＝這一輪真的送到沒有（本機：引擎回的第一個屬於這一輪的事件；
    /// 遠端：那台回覆收下）。回 true 只代表「交出去了」；草稿等 delivery 說送到了才清，沒送到／不確定就留著（不自動重送）。
    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind,
        systemPrompt: String?,
        attachments: [String],
        reasoningEffort: String?,
        serviceTier: String?,
        ultrawork: UltraworkTurnSettings?,
        delivery: (@MainActor (LiveSendDelivery) -> Void)?
    ) -> Bool
    func stop(threadID: UUID)
    func shutdownAll()
    func configureRoom(
        threadID: UUID,
        parentThreadID: UUID,
        roomBrief: String,
        engine: String,
        cwdOverride: String,
        deviceID: String?
    )
    func sidecarProcessID(threadID: UUID) -> Int32?
    func sidecarProcessOwners() -> [pid_t: (thread: UUID, startTime: UInt64)]
}

extension LiveEngineAPI {
    /// 遙控資料源沒有本機 sidecar。
    func sidecarProcessOwners() -> [pid_t: (thread: UUID, startTime: UInt64)] { [:] }
    /// 不看送到沒有的呼叫端（Bot、房間、PR、主設備收副設備的那一句）：同上，不帶 delivery。
    @discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind, systemPrompt: String?,
                                 attachments: [String], reasoningEffort: String?, serviceTier: String?,
                                 ultrawork: UltraworkTurnSettings?) -> Bool {
        send(threadID: threadID, text: text, model: model, engine: engine, systemPrompt: systemPrompt, attachments: attachments,
             reasoningEffort: reasoningEffort, serviceTier: serviceTier, ultrawork: ultrawork, delivery: nil)
    }
    @discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind,
              systemPrompt: String?, attachments: [String]) -> Bool {
        return send(threadID: threadID, text: text, model: model, engine: engine,
             systemPrompt: systemPrompt, attachments: attachments, reasoningEffort: nil, serviceTier: nil)
    }
    var pendingPermissionThreadIDs: Set<UUID> { [] }
    func appendSystemMessage(threadID: UUID, text: String) {
        appendSystemMessage(threadID: threadID, text: text, status: "info|監工")
    }

    func newThread(in projectID: UUID?) -> UUID {
        newThread(in: projectID, title: "新聊天")
    }

    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind
    ) -> Bool {
        return send(
            threadID: threadID,
            text: text,
            model: model,
            engine: engine,
            systemPrompt: nil,
            attachments: [])
    }

    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind,
        systemPrompt: String?
    ) -> Bool {
        return send(
            threadID: threadID,
            text: text,
            model: model,
            engine: engine,
            systemPrompt: systemPrompt,
            attachments: [])
    }
}

/// Failure can retain the duration of a partial answer; keep that metadata in the same turn record.
@dynamicMemberLookup
struct ChatGPTCoderTurnState {
    var progress = ChatGPTTurnProgress()
    var failure: ChatGPTTurnFailure?
    subscript<T>(dynamicMember path: WritableKeyPath<ChatGPTTurnProgress, T>) -> T {
        get { progress[keyPath: path] }
        set { progress[keyPath: path] = newValue }
    }
}

@MainActor
final class ChatLiveEngine: LiveEngineAPI {
    let store: ChatLiveStore
    private let environment: [String: String]
    var composerSkills: () -> [PluginRegistryEntry] = { [] }
    private(set) var doc: LiveDocumentRecord
    private(set) var messages: [UUID: [ChatMessage]] = [:]
    private(set) var tapTurn: [UUID: ChatGPTCoderTurnState] = [:]
    private var sidecars: [UUID: ClaudeSidecar] = [:]
    private let conversationTap: any ConversationTap
    private var tapRunners: [UUID: ChatGPTTapTurnRunner] = [:]
    lazy var groupBridge = GroupCoderBridge(owner: self, tap: conversationTap)
    private var tapModelObservation: ChatGPTTapModelObservation?
    var tapInboxFolder: URL { store.url.deletingLastPathComponent().appendingPathComponent("tap-inbox", isDirectory: true) }
    lazy var tapMapper = TapProjectMapper(tap: conversationTap, inboxFolder: tapInboxFolder)
    private var sidecarPermissionModes: [UUID: String] = [:]
    /// W184 H4 修正（審查 #1）：常駐的 sidecar 是用哪個模型開的（Claude、Grok 的模型只在啟動時給；Codex 每一輪自己帶）。
    private var sidecarModels: [UUID: String] = [:]
    /// 遠端 handle 登記（session-only、本 engine 專屬；隨 engine 釋放）
    let remoteHandles = RemoteSessionHandles()
    private var streamingRowID: [UUID: String] = [:]
    /// 引擎自己回報的模型（sdk init 的 model／assistant message 的 model）；回覆列的 modelID 只從這裡來，不拿使用者選的冒充。
    private var attestedModel: [UUID: String] = [:]
    /// 上一輪用哪家引擎；換了家就不能沿用上一家回報的模型。
    private var attestedEngine: [UUID: ClaudeSidecar.Kind] = [:]
    private var turnID: [UUID: String] = [:]
    private var artifactClaims: [UUID: [String]] = [:]
    private var artifactClaimsTruncated: Set<UUID> = []
    private var indexedArtifactTurn: [UUID: String] = [:]
    lazy var turnArtifacts = TurnArtifacts(root: store.url.deletingLastPathComponent())
    /// One-shot terminal observers, installed before send; no polling or selected-thread dependency.
    var onTurnComplete: [UUID: (Bool, String) -> Void] = [:]
    private func notifyTurnComplete(_ threadID: UUID, succeeded: Bool) {
        eventsFinished(threadID, succeeded: succeeded, turn: turnID[threadID])
        defer {
            if pendingArchives.contains(threadID), !isRunning(threadID) {
                pendingArchives.remove(threadID)
                let next = archive(threadID)
                onThreadArchived?(threadID, next)
            }
        }
        let callback = onTurnComplete.removeValue(forKey: threadID)
        guard callback != nil || groupBridge.hasCompletion(threadID) else { return }
        let reply = (messages[threadID] ?? []).last {
            $0.turnID == turnID[threadID] && $0.role == .assistant && $0.eventKind == .message
                && (!groupBridge.hasCompletion(threadID) || $0.runtimeAdapterID != TatwoChatRuntimeAdapter.chatgptTap.rawValue)
        }?.text ?? ""
        groupBridge.completePrimary(threadID, succeeded: succeeded, reply: reply)
        callback?(succeeded, reply)
    }
    private var runningThreads: Set<UUID> = []
    private var stoppingThreads: Set<UUID> = []
    private var pendingArchives: Set<UUID> = []
    private struct PendingSteer {
        let requestID: String
        let targetTurnID: String
        let completion: (Bool, String?) -> Void
    }
    private var pendingSteers: [UUID: PendingSteer] = [:]
    private var currentNativeGoals: Set<UUID> = []
    private var nativeGoalErrors: [UUID: String] = [:]
    private var pendingGoalControls: [UUID: (id: String, completion: (Bool, String?) -> Void)] = [:]
    private(set) var pendingPermissionThreadIDs: Set<UUID> = []
    private var pendingPermissionDepth: [UUID: Int] = [:]

    /// Scope covers both the modal decision and sending its response, including reentrant prompts.
    func withPendingPermission<T>(_ threadID: UUID, _ body: () throws -> T) rethrows -> T {
        pendingPermissionDepth[threadID, default: 0] += 1
        pendingPermissionThreadIDs.insert(threadID)
        onChange?()
        defer {
            let remaining = (pendingPermissionDepth[threadID] ?? 1) - 1
            if remaining == 0 {
                pendingPermissionDepth[threadID] = nil
                pendingPermissionThreadIDs.remove(threadID)
            } else { pendingPermissionDepth[threadID] = remaining }
            onChange?()
        }
        return try body()
    }

    /// 每次資料變動都叫一次，讓 ChatPageModel 重新發佈 document / transcript。
    var onChange: (() -> Void)?
    weak var chatGPTDispatcher: ChatGPTDispatch?
    var onPlanChange: ((TatwoPlanArtifactV1) -> Void)?
    /// 權限詢問：回 true 允許。預設「代我核准」→ 直接允許；其他 → 跳 AppKit 確認框。
    var permissionDecider: ((_ tool: String, _ inputPretty: String) -> Bool)?
    /// 代我核准：Codex 以 acceptEdits 起 sidecar（MCP 工具直接放行，其餘詢問由 permissionDecider 自動允許）
    var autoApprove = false
    var userPermissionPreset: TatwoPermissionPreset?
    var onHint: ((String) -> Void)?
    var onRoomArchived: ((UUID) -> Void)?
    var onThreadArchived: ((UUID, UUID?) -> Void)?
    /// E2 監工：機器壓力過高時設 true，`DispatchEngine.dispatch` 應拒絕新派工（回 `dispatch_paused_pressure`）。
    var dispatchPaused = false
    private var watchdog: DispatchWatchdog?

    init(
        store: ChatLiveStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tap: (any ConversationTap)? = nil
    ) {
        self.store = store
        self.environment = environment
        self.conversationTap = tap ?? ChatGPTTap.shared
        var d = store.load()
        let original = d
        let initialRecoveryCandidate = store.restorableBackup()
        d.prepareChatHierarchy()
        if d.threads.isEmpty {
            var t = LiveThreadRecord(projectID: d.projects.first?.id, title: "新聊天")
            let defaults = ChatModelPreferences.selection(nil)
            t.requestedModel = defaults.route.id; t.requestedEffort = defaults.effort
            t.requestedSpeedTier = defaults.speed.rawValue
            d.threads = [t]; d.selectedThreadID = t.id
        }
        if d.selectedThreadID == nil { d.selectedThreadID = d.threads.first?.id }
        // This identity is local and durable; creating it never selects it.
        d.ensureAssistantThread()
        for i in d.threads.indices {
            d.threads[i].recoverInterruptedWork(reason: "App 重開，這一輪已中斷；請確認對話後再決定是否重送。")
            for j in d.threads[i].messages.indices where d.threads[i].messages[j].status?.hasPrefix("steering|") == true {
                d.threads[i].messages[j].status = "steer_unknown|插話送達狀態待確認"
            }
        }
        self.doc = d
        if d != original { store.save(d) }
        for t in d.threads { messages[t.id] = t.messages.map(\.chatMessage) }; OSEventSources.register(self)
        if tap == nil {
            tapModelObservation = ChatGPTTapModelObservation(onNotice: { [weak self] note in
                self?.onHint?(note)
            }) { [weak self] in self?.onChange?() }
        }
        watchdog = DispatchWatchdog.attach(to: self)
        warmMemory()   // W180 E1：記憶快取在背景先讀好
        availableRecoveryCandidate = initialRecoveryCandidate
        if let notice = store.loadNotice, let tid = doc.selectedThreadID {
            appendSystemMessage(threadID: tid, text: notice, status: "error|對話紀錄")
        }
    }

    private var availableRecoveryCandidate: URL?
    var recoveryCandidate: URL? {
        guard let candidate = availableRecoveryCandidate, store.shouldOfferBackup(candidate) else { return nil }
        return candidate
    }
    var documentSafetyNotice: String? { store.loadNotice }

    func restoreUnreadableConversation() {
        guard let candidate = recoveryCandidate else { return }
        guard runningThreads.isEmpty else { onHint?("請先停止正在回覆的聊天，再還原對話紀錄。"); return }
        do {
            var restored = try store.restoreBackup(candidate)
            restored.prepareChatHierarchy()
            restored.ensureAssistantThread()
            if restored.selectedThreadID == nil { restored.selectedThreadID = restored.threads.first?.id }
            for index in restored.threads.indices {
                restored.threads[index].recoverInterruptedWork(reason: "對話紀錄已還原，先前回合已中斷；請確認後再決定是否重送。")
            }
            doc = restored
            messages = Dictionary(uniqueKeysWithValues: restored.threads.map { ($0.id, $0.messages.map(\.chatMessage)) })
            availableRecoveryCandidate = nil
            persist()
            onHint?("已還原對話紀錄；還原前的文件已另存於 live/unreadable/。")
        } catch { onHint?("對話紀錄尚未還原。請確認儲存空間與檔案權限後再試；目前的對話與副本已保留。") }
    }

    // MARK: - 讀

    var document: TatwoNativeChatStoreDocument {
        TatwoNativeChatStoreDocument(projects: doc.projects.map { p in
            TatwoNativeChatProject(
                id: p.id, name: p.name, workdir: p.workdir, isExpanded: p.isExpanded,
                threads: doc.threads.filter { $0.projectID == p.id && !$0.isArchived }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map { t in
                        TatwoNativeChatThread(id: t.id, title: t.title, isPinned: t.isPinned,
                                              lastPreview: t.messages.last(where: { $0.eventKind == "message" && !$0.isMemoryUsageRow })?.text ?? "",   // W180 E1：跳過「用了 N 條記憶」
                                              parentThreadID: t.parentThreadID,
                                              liveness: ThreadLiveness.forThread(engine: t.engine, status: t.subStatus, lastOutputAt: t.lastOutputAt, dispatchActive: chatGPTDispatcher?.isActive(caller: t.id) == true),   // W183 R1：手腳房間不看時間
                                              lastOutputAt: t.lastOutputAt, engineLabel: t.engine)
                    },
                githubRepos: p.githubRepos.map { TatwoGitHubRepoBinding(url: $0) })
        }, generalProjectID: doc.generalProjectID, assistantProjectID: doc.assistantProjectID)
    }

    func transcript(for threadID: UUID?) -> [ChatMessage] {
        guard let threadID else { return [] }
        // .054 曾把暫時啟動提示寫成永久系統列；只在畫面隱藏，原始紀錄仍保留。
        return (messages[threadID] ?? []).filter {
            !($0.role == .system && $0.status == "info|ChatGPT" && $0.text == "ChatGPT 啟動中，這句已排隊")
        }
    }

    func isRunning(_ threadID: UUID?) -> Bool { threadID.map { runningThreads.contains($0) || groupBridge.sessions[$0]?.busy == true } ?? false }
    func isExecutingPlan(_ plan: TatwoPlanArtifactV1) -> Bool {
        isRunning(plan.threadID) && plan.executionTurnID != nil && turnID[plan.threadID] == plan.executionTurnID
    }

    #if DEBUG
    func commandSelfTestSetRunning(_ id: UUID, _ running: Bool) {
        if running { runningThreads.insert(id) } else { runningThreads.remove(id) }
        onChange?()
    }
    func tapSelfTestHasRunner(_ id: UUID) -> Bool { tapRunners[id] != nil }
    func tapSelfTestSendDirect(_ id: UUID, route: String) -> Bool {
        sendTap(threadID: id, text: "synthetic", routeID: route, attachments: [], effort: nil, delivery: nil, source: .system)
    }
    func tapSelfTestSidecarClosed(_ id: UUID) { handle(id, .closed) }
    #endif
    /// Any thread still running (window-close confirmation gate).
    var hasRunningWork: Bool { !runningThreads.isEmpty || groupBridge.sessions.values.contains { $0.busy } }
    func acceptsBrowserAgentRequests(_ threadID: UUID) -> Bool {
        runningThreads.contains(threadID) && !stoppingThreads.contains(threadID)
    }
    func activityDate(_ threadID: UUID) -> Date { doc.threads.first { $0.id == threadID }?.updatedAt ?? .distantPast }
    func threadRecord(_ threadID: UUID?) -> LiveThreadRecord? {
        guard let threadID else { return nil }
        return doc.threads.first { $0.id == threadID }
    }

    func projectRecord(_ projectID: UUID?) -> LiveProjectRecord? {
        guard let projectID else { return nil }
        return doc.projects.first { $0.id == projectID }
    }

    func handsSessionSnapshot(_ id: UUID) -> (LiveThreadRecord, LiveProjectRecord?, [ChatMessage], URL)? {
        guard let thread = threadRecord(id) else { return nil }
        let project = thread.projectID == doc.generalProjectID ? nil : projectRecord(thread.projectID)
        return (thread, project, messages[id] ?? thread.messages.map(\.chatMessage), store.url.deletingLastPathComponent())
    }

    var archivedThreadCount: Int {
        doc.threads.filter(\.isArchived).count
    }

    /// E2 監工：在指定討論串貼一則 system 訊息（活性/機器壓力警報用）。
    func appendSystemMessage(threadID: UUID, text: String, status: String = "info|監工") {
        appendSystem(threadID, text, status: status)
    }

    /// Completion belongs to its original local thread, not the selected turn.
    /// Reuse the transcript as the durable receipt; no notification database.
    func appendBackgroundCompletion(_ job: BackgroundJobManager.Record) {
        guard job.state != "running", threadRecord(job.threadID) != nil else { return }
        let id = "background:\(job.jobID.uuidString)"
        let legacyText = "背景工作「\(job.title)」結束，exit=\(job.exitCode.map(String.init) ?? "unknown")，log：\(job.logPath)"
        guard !(messages[job.threadID] ?? []).contains(where: {
            $0.id == id || ($0.role == .system && $0.status == "info|背景工作" && $0.text == legacyText)
        }) else { return }
        let text = job.state == "unknown"
            ? "背景工作「\(job.title)」已無法確認執行狀態，log：\(job.logPath)"
            : legacyText
        append(job.threadID, ChatMessage(id: id, role: .system, text: text, status: job.completionStatus))
        persist()
    }

    /// E2 監工：直接改子討論串的 subStatus（例如卡死自動停止時標成 "stalled"）。
    func markSubStatus(_ threadID: UUID, _ status: String) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[i].subStatus = status
        persist()
    }

    func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine) {
        guard let threadID = doc.selectedThreadID else { return }
        setEnabledMCP(pluginID, enabled: enabled, engine: engine, threadID: threadID)
    }

    /// W180 D3：指定討論串（權限放行要寫進那則訊息所屬的那條，不一定是選中的）。
    func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine, threadID: UUID) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }),
              PluginsSource.mcpEngine(from: pluginID) == engine,
              let name = PluginsSource.mcpName(from: pluginID)
        else { return }
        var names = PluginsSource.effectiveEnabledNames(
            stored: doc.threads[index].enabledMCP,
            engine: engine,
            environment: environment)
        if enabled {
            if !names.contains(name) { names.append(name) }
        } else {
            names.removeAll { $0 == name }
        }
        doc.threads[index].enabledMCP = PluginsSource.storedSelection(
            names: names,
            engine: engine,
            environment: environment)
        if !runningThreads.contains(threadID), let sidecar = sidecars.removeValue(forKey: threadID) {
            sidecar.onEvent = nil
            sidecar.close()
        }
        persist()
    }

    // MARK: - 討論串／專案

    @discardableResult
    func newThread(in projectID: UUID?, title: String = "新聊天") -> UUID {
        newThread(in: projectID, title: title, select: true)
    }

    @discardableResult
    func newThread(in projectID: UUID?, title: String = "新聊天", select: Bool) -> UUID {
        let destination = projectID ?? doc.ensureGeneralProject()
        var t = LiveThreadRecord(projectID: destination, title: title)
        let defaults = ChatModelPreferences.selection(nil)
        t.requestedModel = defaults.route.id
        t.requestedEffort = defaults.effort
        t.requestedSpeedTier = defaults.speed.rawValue
        doc.threads.insert(t, at: 0); messages[t.id] = []; if select { doc.selectedThreadID = t.id }
        persist(); return t.id
    }

    func newProject(name: String, workdir: String) -> UUID {
        let p = LiveProjectRecord(name: name, workdir: workdir)
        doc.projects.append(p); persist(); return p.id
    }

    func handsCreateProject(name: String, workdir: String) throws -> LiveProjectRecord {
        let project = LiveProjectRecord(name: name, workdir: workdir)
        var next = doc
        for i in next.threads.indices { next.threads[i].messages = (messages[next.threads[i].id] ?? []).map(LiveMessageRecord.init) }
        next.projects.append(project)
        try store.saveChecked(next)
        doc = next; onChange?(); return project
    }

    @discardableResult
    func importTransferredThread(
        projectName: String?,
        title: String,
        messages transferredMessages: [RemoteThreadTransferMessage],
        files: [RemoteThreadTransferFile]
    ) throws -> UUID {
        if let id = importTransferredImportedThread(projectName: projectName, title: title, messages: transferredMessages, files: files) {
            return id   // W180 E3：匯入串專案名沒對到時不落「一般」＝「聊天」
        }
        // File transfers require a unique explicit project. Never route files to home
        // or the first duplicate name. Baseline preflight uses the same resolver.
        let project = try transferProject(named: projectName, requiresFiles: !files.isEmpty)
        let projectID = project.id

        try RemoteThreadTransfer.write(files, to: project.workdir)
        let rows = transferredMessages.map(\.chatMessage)
        let thread = LiveThreadRecord(
            projectID: projectID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "新聊天"
                : String(title.prefix(120)),
            messages: rows.map(LiveMessageRecord.init))
        doc.threads.insert(thread, at: 0)
        messages[thread.id] = rows
        doc.selectedThreadID = thread.id
        persist()
        return thread.id
    }

    func transferProject(named name: String?, requiresFiles: Bool) throws -> LiveProjectRecord {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matches = doc.projects.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if !name.isEmpty, matches.count == 1 { return matches[0] }
        if requiresFiles { throw RemoteThreadTransfer.TransferError.conflicts(["project mapping missing or ambiguous"]) }
        if let general = doc.projects.first(where: { $0.name == "一般" }) { return general }
        let id = newProject(name: "一般", workdir: NSHomeDirectory())
        guard let project = projectRecord(id) else { throw RemoteHostLinkError.invalidResponse }
        return project
    }

    func select(_ threadID: UUID) { doc.selectedThreadID = threadID; persist(); eventsSelected(threadID) }
    func setModelPreferences(threadID: UUID, model: String, effort: String, speedTier: String) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        let profile = ChatRouteChoice.resolve(model).profile
        if profile.runtimeAdapter != .chatgptTap, let notice = profile.reasoningDowngradeNotice(for: effort) { onHint?(notice) }
        let effort = profile.runtimeAdapter == .chatgptTap ? effort
            : profile.compatibleReasoningValue(effort) ?? profile.defaultEffort.codexRawValue
        guard doc.threads[index].requestedModel != model
                || doc.threads[index].requestedEffort != effort
                || doc.threads[index].requestedSpeedTier != speedTier else { return }
        doc.threads[index].requestedModel = model
        doc.threads[index].requestedEffort = effort.isEmpty ? nil : effort
        doc.threads[index].requestedSpeedTier = speedTier.isEmpty ? nil : speedTier
        persist()
    }
    /// W180 E1：記憶強度只改這一條（照 setModelPreferences 存在那條）。
    func markControllerThread(_ threadID: UUID, fingerprint: String) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[index].controllerCreatorFingerprint = fingerprint
        (groupBridge.tap as? ChatGPTTap)?.cancelRejectedQueuedSends()
        doc.threads[index].memoryStrength = "off"
        persist()
    }
    func setMemoryStrength(threadID: UUID, _ strength: TatwoMemoryStrength) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }),
              doc.threads[index].memoryStrength != strength.rawValue else { return }
        doc.threads[index].memoryStrength = strength.rawValue
        persist()
    }
    /// W184 H4 修正（審查 #3）：ultrawork（檔位＋主導＋每一個副手）只改這一條（照 setModelPreferences 存在那條，重開 App 還在）。
    func setUltrawork(threadID: UUID, _ settings: UltraworkTurnSettings?) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }),
              doc.threads[index].ultrawork != settings else { return }
        doc.threads[index].ultrawork = settings
        persist()
    }
    func setExpanded(_ projectID: UUID, _ expanded: Bool) {
        if let i = doc.projects.firstIndex(where: { $0.id == projectID }) { doc.projects[i].isExpanded = expanded; persist() }
    }
    func togglePinned(_ threadID: UUID) {
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) { doc.threads[i].isPinned.toggle(); persist() }
    }
    func rename(_ threadID: UUID, _ title: String) {
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) { doc.threads[i].title = title; persist() }
    }

    @discardableResult
    func archive(_ threadID: UUID) -> UUID? {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }) else { return doc.selectedThreadID }
        if isRunning(threadID) {
            pendingArchives.insert(threadID)
            stop(threadID: threadID)
            if isRunning(threadID) {
                onHint?("已要求停止這條聊天；確認停止後會自動封存。停止完成前聊天會保持可見。")
                return doc.selectedThreadID
            }
            pendingArchives.remove(threadID)
            if doc.threads[index].isArchived { return doc.selectedThreadID }
        }
        do { try groupBridge.proposals.remove(threadID) }
        catch { onHint?("提案資料未能刪除，這串尚未封存。"); return doc.selectedThreadID }
        chatGPTDispatcher?.endRoom(caller: threadID)
        let projectID = doc.threads[index].projectID
        doc.threads[index].isArchived = true
        BrowserChatLifecycle.didClose(threadID.uuidString.lowercased(), registry: .shared,
            retention: BrowserGeneralSettings.load().sessionRetention)
        doc.threads[index].isPinned = false
        doc.threads[index].updatedAt = Date()
        let archivedRoomID = doc.threads[index].cwdOverride == nil ? nil : threadID
        if doc.selectedThreadID == threadID {
            doc.selectedThreadID = doc.threads
                .filter { $0.projectID == projectID && !$0.isArchived }
                .max(by: { $0.updatedAt < $1.updatedAt })?
                .id
        }
        persist()
        if let archivedRoomID { onRoomArchived?(archivedRoomID) }
        return doc.selectedThreadID
    }

    @discardableResult
    func restoreMostRecentArchivedThread() -> UUID? {
        guard let index = doc.threads.indices
            .filter({ doc.threads[$0].isArchived })
            .max(by: { doc.threads[$0].updatedAt < doc.threads[$1].updatedAt })
        else { return nil }
        doc.threads[index].isArchived = false
        doc.threads[index].updatedAt = Date()
        doc.selectedThreadID = doc.threads[index].id
        persist()
        return doc.threads[index].id
    }

    @discardableResult
    func duplicate(_ threadID: UUID, asBranch: Bool) -> UUID? {
        guard let sourceIndex = doc.threads.firstIndex(where: { $0.id == threadID }) else { return nil }
        let source = doc.threads[sourceIndex]
        let sourceRows = messages[threadID] ?? source.messages.map(\.chatMessage)
        let copiedRows = sourceRows.map { row in
            ChatMessage(
                role: row.role,
                text: row.text,
                status: row.status,
                modelID: row.modelID,
                eventKind: row.eventKind,
                runtimeAdapterID: row.runtimeAdapterID,
                runtimeFallbackReason: row.runtimeFallbackReason,
                turnID: row.turnID,
                planQuestions: row.planQuestions,
                createdAt: row.createdAt)
        }
        let now = Date()
        var copy = LiveThreadRecord(
            projectID: source.projectID,
            title: "\(source.title) 副本",
            isPinned: false,
            isArchived: false,
            sessionID: nil,
            sessionIDs: [:],
            engine: source.engine,
            model: source.model,
            enabledMCP: source.enabledMCP,
            messages: copiedRows.map(LiveMessageRecord.init),
            createdAt: now,
            updatedAt: now)
        copy.parentThreadID = asBranch ? source.id : source.parentThreadID
        if source.roomReadOnly == true {
            copy.roomReadOnly = true
            copy.cwdOverride = source.cwdOverride
        }
        doc.threads.insert(copy, at: min(sourceIndex + 1, doc.threads.endIndex))
        messages[copy.id] = copiedRows
        doc.selectedThreadID = copy.id
        persist()
        return copy.id
    }

    @discardableResult
    func createDiscussion(parentThreadID: UUID) -> UUID? {
        guard let parent = doc.threads.first(where: { $0.id == parentThreadID && !$0.isArchived }) else { return nil }
        let number = doc.threads.filter { $0.parentThreadID == parentThreadID }.count + 1
        var discussion = LiveThreadRecord(
            projectID: parent.projectID,
            title: "支線 \(number)",
            engine: parent.engine,
            model: parent.model,
            enabledMCP: parent.enabledMCP)
        discussion.parentThreadID = parentThreadID
        discussion.subStatus = "idle"
        if parent.roomReadOnly == true {
            discussion.roomReadOnly = true
            discussion.cwdOverride = parent.cwdOverride
        }
        discussion.requestedModel = parent.requestedModel
        discussion.requestedEffort = parent.requestedEffort
        discussion.requestedSpeedTier = parent.requestedSpeedTier
        discussion.controllerCreatorFingerprint = parent.controllerCreatorFingerprint
        discussion.memoryStrength = parent.memoryStrength   // W180 E1：子討論串跟母串
        doc.threads.insert(discussion, at: 0)
        messages[discussion.id] = []
        doc.selectedThreadID = discussion.id
        persist()
        return discussion.id
    }

    @discardableResult
    func compressDiscussion(_ discussionID: UUID) -> UUID? {
        guard
            let childIndex = doc.threads.firstIndex(where: { $0.id == discussionID }),
            let parentID = doc.threads[childIndex].parentThreadID,
            doc.threads.contains(where: { $0.id == parentID })
        else { return nil }
        do { try groupBridge.proposals.remove(discussionID) }
        catch { onHint?("提案資料未能刪除，這串尚未封存。"); return nil }
        let child = doc.threads[childIndex]
        if child.cwdOverride != nil, isRunning(discussionID) { stop(threadID: discussionID) }
        if let summary = (messages[discussionID] ?? [])
            .last(where: { $0.role == .assistant && $0.eventKind == .message })?
            .text
        {
            appendSystem(
                parentID,
                "〔支線 \(child.title) 摘要〕\n\(summary)",
                status: "info|支線摘要")
        }
        doc.threads[childIndex].isArchived = true
        doc.threads[childIndex].updatedAt = Date()
        doc.selectedThreadID = parentID
        persist()
        if child.cwdOverride != nil { onRoomArchived?(discussionID) }
        return parentID
    }

    @discardableResult
    func mergeDiscussionIntoParent(_ discussionID: UUID) -> UUID? {
        guard
            let childIndex = doc.threads.firstIndex(where: { $0.id == discussionID }),
            let parentID = doc.threads[childIndex].parentThreadID,
            doc.threads.contains(where: { $0.id == parentID })
        else { return nil }
        do { try groupBridge.proposals.remove(discussionID) }
        catch { onHint?("提案資料未能刪除，這串尚未封存。"); return nil }
        let child = doc.threads[childIndex]
        if child.cwdOverride != nil, isRunning(discussionID) { stop(threadID: discussionID) }
        let prefix = "〔支線 \(child.title)〕"
        let mergedRows = (messages[discussionID] ?? []).map { row in
            ChatMessage(
                role: row.role,
                text: "\(prefix)\n\(row.text)",
                status: row.status,
                modelID: row.modelID,
                eventKind: row.eventKind,
                runtimeAdapterID: row.runtimeAdapterID,
                runtimeFallbackReason: row.runtimeFallbackReason,
                turnID: row.turnID,
                planQuestions: row.planQuestions,
                createdAt: row.createdAt)
        }
        messages[parentID, default: []].append(contentsOf: mergedRows)
        touch(parentID)
        doc.threads[childIndex].isArchived = true
        doc.threads[childIndex].updatedAt = Date()
        doc.selectedThreadID = parentID
        persist()
        if child.cwdOverride != nil { onRoomArchived?(discussionID) }
        return parentID
    }

    func setGitHubRepos(_ repos: [String], for projectID: UUID) {
        guard let index = doc.projects.firstIndex(where: { $0.id == projectID }) else { return }
        doc.projects[index].githubRepos = repos
        persist()
    }

    // MARK: - issue 清單（右側資訊卡）

    func issues(threadID: UUID?, global: Bool) -> [TatwoIssueListEntryV1] {
        if global { return doc.threads.flatMap(\.issues).sorted { $0.createdAt > $1.createdAt } }
        guard let threadID, let t = doc.threads.first(where: { $0.id == threadID }) else { return [] }
        return t.issues.sorted { $0.createdAt > $1.createdAt }
    }
    /// /issue 直接記進右側資訊卡的 issue 清單（1.0 語意：快速記問題，不叫模型）
    func addIssue(threadID: UUID, title: String, body: String) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        let entry = TatwoIssueListEntryV1(title: String(title.prefix(60)), body: body, sourceReference: threadID.uuidString,
                                          threadReference: threadID.uuidString, projectReference: doc.threads[i].projectID?.uuidString)
        doc.threads[i].issues.append(entry); persist()
    }
    /// Publish only after checked persistence. The caller retains the id on failure.
    func addIssueChecked(threadID: UUID, entry: TatwoIssueListEntryV1) throws {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID && !$0.isArchived }) else {
            throw BotLibraryError.invalid("討論串不存在或已封存")
        }
        if doc.threads[index].issues.contains(where: { $0.id == entry.id }) { return }
        var candidate = doc
        for i in candidate.threads.indices {
            candidate.threads[i].messages = (messages[candidate.threads[i].id] ?? []).map(LiveMessageRecord.init)
        }
        candidate.threads[index].issues.append(entry)
        try store.saveChecked(candidate)
        doc = candidate
        onChange?()
    }
    func updateIssueImagesChecked(id: String, body: String, images: [String]) throws {
        var candidate = doc
        guard let ti = candidate.threads.firstIndex(where: { $0.issues.contains(where: { $0.id == id }) }),
              let ii = candidate.threads[ti].issues.firstIndex(where: { $0.id == id }) else {
            throw BotLibraryError.invalid("issue 不存在")
        }
        candidate.threads[ti].issues[ii].body = body
        candidate.threads[ti].issues[ii].imageAssetPaths = images
        for i in candidate.threads.indices {
            candidate.threads[i].messages = (messages[candidate.threads[i].id] ?? []).map(LiveMessageRecord.init)
        }
        try store.saveChecked(candidate)
        doc = candidate
        onChange?()
    }
    func captureIssue(threadID: UUID) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        let rows = messages[threadID] ?? []
        let lastAssistant = rows.last { $0.role == .assistant && $0.eventKind == .message }?.text ?? ""
        let lastUser = rows.last { $0.role == .user }?.text ?? doc.threads[i].title
        let entry = TatwoIssueListEntryV1(title: String(lastUser.prefix(60)), body: lastAssistant, sourceReference: threadID.uuidString,
                                          threadReference: threadID.uuidString, projectReference: doc.threads[i].projectID?.uuidString)
        doc.threads[i].issues.append(entry); persist()
    }
    func updateIssue(_ id: String, _ body: (inout TatwoIssueListEntryV1) -> Void) {
        for ti in doc.threads.indices {
            if let ii = doc.threads[ti].issues.firstIndex(where: { $0.id == id }) { body(&doc.threads[ti].issues[ii]); persist(); return }
        }
    }
    func removeIssue(_ id: String) {
        for ti in doc.threads.indices { doc.threads[ti].issues.removeAll { $0.id == id } }
        persist()
    }

    // MARK: - git 狀態（專案 workdir）

    struct GitSummary { var branch = "—"; var files: [String] = []; var additions = 0; var deletions = 0; var perFile: [String: (Int, Int)] = [:]; var truncated = false }
    func gitSummary(for threadID: UUID?, completion: @escaping (GitSummary) -> Void) {
        guard let threadID, let t = doc.threads.first(where: { $0.id == threadID }),
              let cwd = t.cwdOverride ?? doc.projects.first(where: { $0.id == t.projectID })?.workdir else { completion(GitSummary()); return }
        let hardened = t.controllerCreatorFingerprint != nil || t.engine == Self.handsEngine
        DispatchQueue.global(qos: .utility).async {
            var readFailed = false
            func run(_ args: [String]) -> String {
                guard let output = HandsGit.hostRead(args, cwd: cwd, hardened: hardened) else { readFailed = true; return "" }
                return output
            }
            var g = GitSummary()
            let branch = run(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { g.truncated = readFailed; DispatchQueue.main.async { completion(g) }; return }
            g.branch = branch
            let paths = TurnArtifactsGit.paths(run(["status", "--porcelain=v1", "-z", "--untracked-files=all"]))
            g.files = Array(paths.prefix(TurnArtifacts.maxPaths))
            for line in run(["diff", "--numstat"]).split(separator: "\n") {
                let parts = line.split(separator: "\t"); if parts.count >= 2 { g.additions += Int(parts[0]) ?? 0; g.deletions += Int(parts[1]) ?? 0 }
                if parts.count >= 3 { g.perFile[parts[2...].joined(separator: "\t")] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0) }   // 結語卡每個檔的 +/-（未追蹤檔沒有 numstat，顯示 0/0）
            }
            g.truncated = readFailed || paths.count > TurnArtifacts.maxPaths
            DispatchQueue.main.async { completion(g) }
        }
    }

    // Bot-only preparation; the caller supplies an already-loaded library snapshot.
    // No filesystem work and no engine process is started in this method.
    func prepareBotThread(existing: UUID?, bot: BotLibraryRecord, registeredMCP: [String],
                          reservedID: UUID? = nil, selectThread: Bool = true) throws -> UUID {
        if let existing, isRunning(existing) { throw BotLibraryError.invalid("bot_turn_in_progress") }
        let resolved = bot.permissions.resolve(registeredMCP: registeredMCP)
        let id: UUID
        if let existing, doc.threads.contains(where: { $0.id == existing }) { id = existing }
        else {
            let projectID: UUID
            if let project = doc.projects.first(where: { $0.workdir == bot.workdir }) { projectID = project.id }
            else {
                let project = LiveProjectRecord(name: bot.name, workdir: bot.workdir)
                doc.projects.append(project); projectID = project.id
            }
            var thread = LiveThreadRecord(id: reservedID ?? UUID(), projectID: projectID, title: bot.name)
            thread.engine = bot.engine
            doc.threads.insert(thread, at: 0); messages[thread.id] = []; id = thread.id
        }
        guard let i = doc.threads.firstIndex(where: { $0.id == id }) else { throw BotLibraryError.invalid("bot_thread_missing") }
        // Empty means default-all in the legacy engine; keep the established deny-all sentinel.
        let selection = resolved.enabledMCP.isEmpty ? ["__tatwo_none__"] : resolved.enabledMCP
        if doc.threads[i].enabledMCP != selection || doc.threads[i].botPermissionPreset != resolved.approval || doc.threads[i].cwdOverride != bot.workdir {
            if let sidecar = sidecars.removeValue(forKey: id) { sidecar.onEvent = nil; sidecar.close() }
        }
        doc.threads[i].enabledMCP = selection
        doc.threads[i].botPermissionPreset = resolved.approval
        doc.threads[i].cwdOverride = bot.workdir
        if selectThread { doc.selectedThreadID = id }
        return id
    }

    // MARK: - 講話

    @discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind = .claude, systemPrompt: String? = nil, attachments: [String] = [], reasoningEffort: String? = nil, serviceTier: String? = nil) -> Bool {
        send(threadID: threadID, text: text, model: model, engine: engine, systemPrompt: systemPrompt, attachments: attachments,
             reasoningEffort: reasoningEffort, serviceTier: serviceTier, ultrawork: nil, delivery: nil)
    }

    /// W184 H4 修正（審查 #2）：ultrawork＝這一輪明確帶的（卡上的值）；nil＝呼叫端不管，照那條記住的（Bot、房間、舊版副設備送來的）。
    /// W184 H4 修正第二輪（審查 #1）：delivery＝引擎真的收到這一輪沒有（見 LiveSendDelivery）；ultrawork 的「上一輪帶出去的」等收到才記。
    @discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind, systemPrompt: String?,
                                 attachments: [String], reasoningEffort: String?, serviceTier: String?,
                                 ultrawork: UltraworkTurnSettings?, delivery: (@MainActor (LiveSendDelivery) -> Void)?) -> Bool {
        let source = OSEventSources.take()
        guard !store.isReadOnly else { return false }
        let requested = model ?? threadRecord(threadID)?.requestedModel ?? threadRecord(threadID)?.model
        let model = requested.flatMap { EngineAIUpdate.retired($0, deviceID: threadRecord(threadID)?.deviceID ?? "local") == nil ? model : ChatRouteChoice.resolve($0, deviceID: threadRecord(threadID)?.deviceID ?? "local").modelArgument }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if GroupTurnEngine.departure(t) != nil, threadRecord(threadID)?.engine != Self.handsEngine,
           let routed = groupBridge.route(threadID: threadID, text: t, model: model, engine: engine, systemPrompt: systemPrompt,
                                          attachments: attachments, effort: reasoningEffort, tier: serviceTier, ultrawork: ultrawork, delivery: delivery, source: source) { return routed }
        if groupBridge.sessions[threadID]?.busy == true, (!t.isEmpty || !attachments.isEmpty),
           let routed = groupBridge.route(threadID: threadID, text: t, model: model, engine: engine, systemPrompt: systemPrompt,
                                          attachments: attachments, effort: reasoningEffort, tier: serviceTier, ultrawork: ultrawork, delivery: delivery, source: source) { return routed }
        guard (!t.isEmpty || !attachments.isEmpty), !runningThreads.contains(threadID), tapRunners[threadID] == nil else { return false }
        if let reason = importedSendBlockReason(threadID) {   // W180 E3：匯入的串原本的資料夾不在了，不送並說明
            appendSystemMessage(threadID: threadID, text: reason, status: "error|匯入"); return false
        }
        if threadRecord(threadID)?.engine == Self.handsEngine {   // W183 R1：ChatGPT 手腳的房間只由 ChatGPT 透過 OS 工具操作
            appendSystemMessage(threadID: threadID, text: Self.handsSendBlockReason, status: "error|ChatGPT 手腳"); return false
        }
        let selectedModel = model ?? threadRecord(threadID)?.requestedModel
        if let selectedModel, ChatGPTTapModelCatalog.isRouteID(selectedModel) {
            if let reason = ManagedConversationTAPPolicy.rejectionReason(model: selectedModel, creator: threadRecord(threadID)?.controllerCreatorFingerprint) {
                appendSystemMessage(threadID: threadID, text: reason, status: "error|ChatGPT TAP"); return false
            }
            guard CanvasCommandPolicy.command(in: t) == nil else {
                appendSystemMessage(threadID: threadID, text: CanvasCommandPolicy.tapUnsupported, status: "info|ChatGPT TAP")
                return false
            }
            return sendTap(threadID: threadID, text: t, routeID: selectedModel, attachments: attachments,
                           effort: reasoningEffort, delivery: delivery, source: source)
        }
        if let routed = groupBridge.route(threadID: threadID, text: t, model: model, engine: engine, systemPrompt: systemPrompt,
                                          attachments: attachments, effort: reasoningEffort, tier: serviceTier, ultrawork: ultrawork, delivery: delivery, source: source) { return routed }
        var plan: TatwoPlanArtifactV1?
        do { plan = try loadPlanArtifact(threadID) }
        catch {
            appendSystemMessage(threadID: threadID, text: "計畫讀取失敗，這句未送出；請先修復畫布資料。", status: "error|Plan")
            return false
        }
        // W181 R3：勾了「不用 API 金鑰」只擋這台只有 API 金鑰（或判斷不出來）的那家；訂閱登入照常送。沒勾跟舊版一樣。
        // 派到別台的串（sidecar 在那台跑）：不拿這台的登入判斷那台，勾了就照舊擋（說明寫出是哪一台）。
        let gateRecord = threadRecord(threadID)
        let gateCwd = gateRecord.flatMap { t -> String? in
            t.deviceID != nil ? nil : t.cwdOverride ?? doc.projects.first { $0.id == t.projectID }?.workdir ?? NSHomeDirectory() }
        let gateDevice = EngineDisableStore.allowsAPIKey(engine) ? nil : gateRecord?.deviceID.map { id in
            (try? RemoteDeviceLookup(root: store.url.deletingLastPathComponent()).device(id: id))?.name ?? "" }
        if let reason = EngineDisableStore.sendBlockReason(engine, cwd: gateCwd, otherDevice: gateDevice) {
            appendSystemMessage(threadID: threadID, text: reason, status: "error|不用 API 金鑰")
            return false
        }
        let thread = threadRecord(threadID)
        let route = ChatRouteChoice.resolve(model ?? thread?.requestedModel ?? thread?.model ?? "gpt-6.1-sol", deviceID: thread?.deviceID ?? "local")
        if thread?.deviceID == nil, route.runtimeAdapter == .unavailable {
            appendEngineFailure(threadID, raw: "unsupported model \(route.id)", status: "error|模型不支援")
            return false
        }
        let usesGPT6Defaults = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"].contains(route.id)
        let requestedEffort = engine == .codex || engine == .claude
            ? reasoningEffort ?? thread?.requestedEffort ?? (usesGPT6Defaults ? "medium" : nil) : nil
        let effort = route.profile.compatibleReasoningValue(requestedEffort)
        if let notice = route.profile.reasoningDowngradeNotice(for: requestedEffort) { onHint?(notice) }
        let requestedTier = engine == .codex || engine == .claude
            ? serviceTier ?? thread?.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:))?.appServerValue
                ?? (usesGPT6Defaults ? TatwoModelSpeedTier.fast.appServerValue : nil) : nil
        let tier: String?
        if route.profile.hasEngineCapabilityReport {
            tier = route.profile.nativeSpeedTier(for: requestedTier.map { $0 == "priority" ? .fast : .standard })?.appServerValue
        } else { tier = requestedTier }
        if let index = doc.threads.firstIndex(where: { $0.id == threadID }) {
            if let model {
                doc.threads[index].requestedModel = ChatModelPreferences.requestedRouteID(
                    providerModel: model, previous: doc.threads[index].requestedModel)
            }
            if let effort { doc.threads[index].requestedEffort = effort }
            if let tier {
                doc.threads[index].requestedSpeedTier = tier == "default" ? "standard" : "fast"
            }
        }
        guard let sidecar = ensureSidecar(threadID, model: model, engine: engine, systemPrompt: systemPrompt) else { return false }
        let turn = UUID().uuidString
        let planBriefing = planContext(plan, userText: t)
        if var confirmed = plan, confirmed.acceptsStart(t)
            || (confirmed.kind == "pr" && confirmed.state == .confirmed && onTurnComplete[threadID] != nil) {
            if confirmed.kind == "pr" { confirmed.prModeExited = true }
            confirmed.executionTurnID = turn
            do { try savePlanArtifact(confirmed) }
            catch {
                appendSystemMessage(threadID: threadID, text: "計畫執行狀態未能儲存，這句未送出。", status: "error|Plan")
                return false
            }
        }
        turnID[threadID] = turn
        if attestedEngine[threadID] != engine { attestedModel[threadID] = nil; attestedEngine[threadID] = engine }
        artifactClaims[threadID] = []
        artifactClaimsTruncated.remove(threadID)
        let shown = ChatAttachmentTranscript.displayTurn(text: t, attachmentPaths: attachments)
        if !groupBridge.relay.contains(threadID) { append(threadID, ChatMessage(role: .user, text: shown, turnID: turn), source: source) }
        let userRowID = groupBridge.relay.contains(threadID) ? "" : messages[threadID]?.last?.id ?? ""   // W184 H4 修正第二輪：沒送到時標這一列
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }), doc.threads[i].title == "新聊天" {
            doc.threads[i].title = String(ChatAttachmentTranscript.previewText(userText: t, attachmentPaths: attachments).prefix(24))
        }
        runningThreads.insert(threadID)
        streamingRowID[threadID] = nil
        // D3：討論串中途換引擎、且新引擎在這條串還沒有 session → 把最近對話摘要當第一句餵給它
        // W170 實測：訊息以 /plg 開頭時 Claude CLI 當成它自己的斜線指令，回「Unknown command: /plg」，引擎根本沒看到。
        // /plg 是 OS 的約定（憲法快捷），送給引擎前翻成一句白話；對話裡照樣顯示使用者打的字。
        let engineText = Self.engineText(t)
        var outgoing = engineText
        if let seeded = importedSeed(threadID: threadID, engine: engine, userText: engineText, currentTurn: turn) {   // W180 E3：匯入的串帶前情
            outgoing = seeded
        } else if let th = thread, let prev = th.engine, prev != engine.rawValue, th.sessionIDs[engine.rawValue] == nil {
            let recent = (messages[threadID] ?? []).filter { $0.eventKind == .message && $0.role != .system }.suffix(13).dropLast()
            if !recent.isEmpty {
                let summary = recent.map { "\($0.role == .user ? "使用者" : "助理")：\($0.text.prefix(600))" }.joined(separator: "\n")
                outgoing = "（這條討論串先前是用 \(prev) 引擎談的，以下是最近對話，請接續，不要重複回答舊問題）\n\(summary)\n\n（現在的訊息）\n\(engineText)"
            }
        }
        if outgoing == engineText,   // W182 R4：別台離線時複製過來的串，第一句帶前情（沒被上面兩種帶過才帶）
           let seeded = offlineCopySeed(threadID: threadID, engine: engine, userText: engineText, currentTurn: turn) {
            outgoing = seeded
        }
        if let seeded = AssistantOfflineSeed.take(threadID, userText: outgoing) { outgoing = seeded }   // W182 R5：斷線接手第一句帶主設備那條的前情（不顯示在對話裡）
        if outgoing == engineText, let caughtUp = offlineCatchUpSeed(threadID: threadID, currentTurn: turn, userText: engineText) {
            outgoing = caughtUp   // W182 R5（主設備這一側）：副設備離線那段剛補回這條、引擎沒看過：這句帶上（資料不是指令，只帶一次）
        }
        if let personality = PetPersonality.turnPrompt(engine: self, projectID: thread?.projectID, source: source) { outgoing += "\n\n" + personality }
        if let planBriefing { outgoing += "\n\n" + planBriefing }
        if source.origin == "composer" { outgoing = composerTurnText(outgoing, engine: engine, markers: engineText) }
        // W170：每一輪都把這串還沒完成的目標交給引擎（不顯示在對話裡），主線才不會飄。
        if let goals = ThreadGoalRules.promptSummary(ThreadGoalStore.shared.list(threadID)) { outgoing += "\n\n" + goals }
        // W180 E1：依這條的記憶強度附上記憶候選（不顯示在對話裡）；「關」、資料夾不在、快取還沒好都不附，送出照常。
        if let memory = memoryBriefing(threadID: threadID, turn: turn, text: t) { outgoing += "\n\n" + memory }
        // W184 H4 修正（審查 #2、#3、#5）：這一輪的 ultrawork（檔位、主導、這一檔上場的每一個副手）每一輪都接在這一句後面（不顯示在對話裡），
        // 不再只在 sidecar 啟動時讀一次 systemPrompt——重用的 sidecar 下一輪照樣換檔、關掉、換角色；剛從開著變成關的那一輪說一聲「關了」。
        let ultraworkTurn = ultraworkTurnBlock(threadID: threadID, explicit: ultrawork)
        if let block = ultraworkTurn.block { outgoing += "\n\n" + block }
        // W184 H4 修正第二輪（GPT-6 H4b 審查 #1）：寫不進引擎（程序已經不在、管線斷了）＝這一句沒送出：不算回覆中、那一列標沒送到、
        // ultrawork 的「上一輪帶出去的」不動（下一輪照樣補說一聲「關了」）；回 false，呼叫端留著草稿。
        if let groupText = groupBridge.outgoing[threadID] { outgoing += "\n\n" + groupText }
        if let review = groupBridge.reviewContext[threadID] { outgoing += "\n\n" + review }
        guard sidecar.send(text: outgoing, uuid: turn, attachments: attachments, model: model,
                           reasoningEffort: effort, serviceTier: tier) else {
            runningThreads.remove(threadID)
            update(threadID, userRowID) { $0.status = Self.undeliveredRowStatus }
            appendSystem(threadID, Self.undeliveredWriteText, status: Self.undeliveredRowStatus)
            persist()
            return false
        }
        if let groupText = groupBridge.outgoing[threadID] { groupBridge.sessions[threadID]?.adjustPrimarySent(outgoing.count - groupText.count) }
        pendingTurnDeliveries[threadID] = PendingTurnDelivery(turn: turn, userRowID: userRowID,
                                                              ultraworkSent: ultraworkTurn.sent, callback: delivery)
        persist()
        return true
    }

    /// W184 H4 修正第二輪（GPT-6 H4b 審查 #1）：送出去、引擎還沒確認收到的那一輪（每條最多一輪：回覆中就不收下一句）。
    /// 確認之前不動 ultraworkSent（沒送到的話下一輪照樣補說一聲「關了」），也不叫呼叫端清草稿；確認＝這一輪的第一個原生事件
    /// （Codex 的 turn_accepted、回覆的串流、工具、成功的結果）；沒送到＝引擎在那之前就結束、回報失敗或被停。送達不明不自動重送。
    private struct PendingTurnDelivery {
        let turn: String
        let userRowID: String
        /// 這一輪確認收到之後才記成「上一輪帶出去的」ultrawork（開著的才記；關著＝nil）。
        let ultraworkSent: UltraworkTurnSettings?
        let callback: (@MainActor (LiveSendDelivery) -> Void)?
    }
    private var pendingTurnDeliveries: [UUID: PendingTurnDelivery] = [:]
    static let undeliveredRowStatus = "error|沒送到"
    static let undeliveredWriteText = "這句沒有送到引擎（寫不進引擎程序：它已經結束或連線斷了），沒有執行；草稿留著，可以再送一次。"
    static let undeliveredClosedText = "這句沒有送到引擎：引擎在讀到這一句之前就結束了（例如換模型重開、接回原本的對話失敗），沒有執行；草稿留著，修好之後再送一次。"

    /// W184 H4 修正（審查 #2、#3）：呼叫端帶的＝卡上的值，記成這條的偏好（遠端送來的也記：那台的卡、這台的卡看同一份）；
    /// 沒帶＝照這條記住的。回這一輪要接的那一段，與這一輪確認收到之後要記成「上一輪帶出去的」那一份（W184 H4 修正第二輪：
    /// 不在這裡記——還沒送到就記，重開失敗時「關了」那一聲就被吃掉）。
    private func ultraworkTurnBlock(threadID: UUID, explicit: UltraworkTurnSettings?) -> (block: String?, sent: UltraworkTurnSettings?) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }) else { return (nil, nil) }
        if let explicit { doc.threads[index].ultrawork = explicit }
        let current = doc.threads[index].ultrawork
        let block = UltraworkTurnSettings.turnBlock(current: current, lastSent: doc.threads[index].ultraworkSent)
        return (block, current?.isOn == true ? current : nil)
    }

    /// 這一輪引擎確認收到了：ultrawork 的「上一輪帶出去的」這時才記；呼叫端可以清草稿。
    private func confirmTurnDelivery(_ threadID: UUID) {
        guard let pending = pendingTurnDeliveries.removeValue(forKey: threadID) else { return }
        if let index = doc.threads.firstIndex(where: { $0.id == threadID }) {
            doc.threads[index].ultraworkSent = pending.ultraworkSent
        }
        persist()
        pending.callback?(.delivered)
    }

    /// 這一輪確定沒送到（引擎在讀它之前就結束、還沒開始就回報失敗或被停）：ultrawork 的「上一輪」不動；那一列標沒送到；
    /// 不自動重送——草稿由呼叫端留著，使用者自己決定要不要再送。
    private func failTurnDelivery(_ threadID: UUID, reason: String, markRow: Bool) {
        guard let pending = pendingTurnDeliveries.removeValue(forKey: threadID) else { return }
        if markRow { update(threadID, pending.userRowID) { $0.status = Self.undeliveredRowStatus } }
        pending.callback?(.notDelivered(reason))
    }

    func savePastedAttachment(data: Data, suggestedName: String) throws -> URL {
        try store.saveAttachment(data: data, suggestedName: suggestedName)
    }

    func nativeGoalIsCurrent(_ threadID: UUID) -> Bool {
        currentNativeGoals.contains(threadID) && sidecars[threadID]?.kind == .codex &&
        sidecars[threadID]?.isRunning == true
    }
    func nativeGoalError(_ threadID: UUID) -> String? { nativeGoalErrors[threadID] }
    func nativeGoalControlPending(_ threadID: UUID) -> Bool { pendingGoalControls[threadID] != nil }

    @discardableResult
    func setNativeGoal(threadID: UUID, status: String?, objective: String? = nil, model: String? = nil,
                       completion: @escaping (Bool, String?) -> Void) -> Bool {
        guard let thread = threadRecord(threadID), thread.deviceID == nil,
              pendingGoalControls[threadID] == nil, !EngineDisableStore.blocksSend(.codex),   // W181 R3
              !isRunning(threadID) || sidecars[threadID]?.kind == .codex,
              let sidecar = ensureSidecar(threadID, model: model, engine: .codex) else { return false }
        let id = UUID().uuidString
        let targetTurn = turnID[threadID]
        pendingGoalControls[threadID] = (id, { [weak self] accepted, error in
            if accepted, status == nil || status == "paused", let self,
               self.turnID[threadID] == targetTurn || self.turnID[threadID]?.hasPrefix("native:") == true {
                self.requestStop(threadID, pauseGoal: false)
            }
            completion(accepted, error)
        })
        nativeGoalErrors[threadID] = nil
        let choice = ChatRouteChoice.resolve(model ?? thread.requestedModel ?? thread.model ?? "gpt-6.1-sol")
        let configure = status == "active" && choice.brandGroup == .openAI
        sidecar.goal(status: status, objective: objective, requestID: id,
                     model: configure ? choice.modelArgument ?? choice.canonicalModelSlug : nil,
                     effort: configure ? choice.profile.compatibleReasoningValue(thread.requestedEffort ?? choice.defaultEffort.codexRawValue) : nil,
                     serviceTier: configure ? thread.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:))?.appServerValue
                        ?? choice.defaultSpeedTier?.appServerValue : nil)
        onChange?()
        return true
    }

    func refreshNativeGoal(_ threadID: UUID) {
        // Navigation never creates a provider process or wakes a model.
        sidecars[threadID]?.refreshGoal()
    }

    private func finishGoalControl(_ threadID: UUID, accepted: Bool, message: String?) {
        guard let pending = pendingGoalControls.removeValue(forKey: threadID) else { return }
        if !accepted { nativeGoalErrors[threadID] = message ?? "目標操作未確認" }
        onChange?()
        pending.completion(accepted, message)
    }

    func canSteer(_ threadID: UUID) -> Bool {
        runningThreads.contains(threadID) && !stoppingThreads.contains(threadID) &&
        pendingSteers[threadID] == nil && (sidecars[threadID]?.kind == .codex || sidecars[threadID]?.kind == .claude) &&
        threadRecord(threadID)?.deviceID == nil
    }

    @discardableResult
    func steer(threadID: UUID, text: String, attachments: [String],
               completion: @escaping (Bool, String?) -> Void) -> Bool {
        let source = OSEventSources.take()
        guard canSteer(threadID), let target = turnID[threadID],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        else { return false }
        let requestID = UUID().uuidString
        pendingSteers[threadID] = .init(requestID: requestID, targetTurnID: target, completion: completion)
        append(threadID, ChatMessage(id: requestID, role: .user,
            text: ChatAttachmentTranscript.displayTurn(text: text, attachmentPaths: attachments),
            status: "steering|等待插話確認", turnID: target), source: source)
        // Keep subsequent assistant text below the inserted user message.
        endStreaming(threadID)
        sidecars[threadID]?.steer(text: source.origin == "composer" ? composerTurnText(text, engine: sidecars[threadID]?.kind ?? .codex) : text, attachments: attachments,
                                 requestID: requestID, targetTurnUUID: target)
        persist()
        return true
    }

    private func finishSteer(_ threadID: UUID, accepted: Bool, message: String?, unknown: Bool = false) {
        guard let pending = pendingSteers.removeValue(forKey: threadID) else { return }
        update(threadID, pending.requestID) {
            $0.status = accepted ? nil : unknown
                ? "steer_unknown|插話送達狀態待確認"
                : "steer_failed|插話未送出"
        }
        persist()
        pending.completion(accepted, message)
    }

    func stop(threadID: UUID) {
        if groupBridge.stop(threadID) { return }
        _ = chatGPTDispatcher?.stop(caller: threadID)
        if let runner = tapRunners[threadID] {
            stoppingThreads.insert(threadID)
            if let rowID = streamingRowID[threadID] { update(threadID, rowID) { $0.status = "cancelled|已停止" } }
            runner.stop()
            persist()
            return
        }
        requestStop(threadID, pauseGoal: threadRecord(threadID)?.nativeGoal?.status == "active" ? true : nil)
    }

    private func requestStop(_ threadID: UUID, pauseGoal: Bool?) {
        ComputerUseController.shared.stop(owner: threadID)
        BrowserAgentBridge.shared.revokeRequests(owner: threadID)
        if sidecars[threadID] == nil, let index = doc.threads.firstIndex(where: { $0.id == threadID }) {
            doc.threads[index].messages = (messages[threadID] ?? []).map(LiveMessageRecord.init)
            if doc.threads[index].recoverInterruptedWork(reason: "這一輪的引擎已不存在，已結束工作狀態；請確認對話後再決定是否重送。") {
                messages[threadID] = doc.threads[index].messages.map(\.chatMessage)
                persist()
            }
            return
        }
        guard sidecars[threadID] != nil,
              runningThreads.contains(threadID) || (pauseGoal != false &&
                (pendingGoalControls[threadID] != nil || threadRecord(threadID)?.nativeGoal?.status == "active")) else { return }
        // 使用者 09-19：「目前遇到終止不了」。中斷只是請求；引擎卡在工具呼叫或根本沒在聽時永遠等不到結束事件。
        // 再按一次＝立刻強制結束；否則給引擎 5 秒自己收尾，逾時一樣強制結束。
        if stoppingThreads.contains(threadID) { forceStop(threadID); return }
        if runningThreads.contains(threadID) {
            stoppingThreads.insert(threadID)
            let stoppedTurn = turnID[threadID]
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                // 只收當初按終止的那一輪；這 5 秒內若已正常結束又開了新一輪，不能誤殺新的。
                guard let self, self.turnID[threadID] == stoppedTurn else { return }
                self.forceStop(threadID)
            }
        }
        sidecars[threadID]?.interrupt(pauseGoal: pauseGoal)
        // Sending interrupt is not confirmation. Reuse the existing running
        // state until the engine emits its terminal event; no timer or poller.
        if let rid = streamingRowID[threadID] {
            update(threadID, rid) { $0.status = "writing|正在停止" }
        }
        persist()
    }

    /// 引擎沒有回報結束時的保底：本地把這一輪收掉、結束那個 sidecar；下一句會重新啟動引擎並接回同一段對話。
    private func forceStop(_ threadID: UUID) {
        guard stoppingThreads.contains(threadID), runningThreads.contains(threadID) else { return }
        cancelUnfinishedRows(threadID, status: "cancelled|已強制停止")
        settleUnconfirmedDelivery(threadID, reason: "已強制停止，這一句是否送達仍待確認；請先確認對話再決定是否重送")
        touchLiveness(threadID, done: true)
        appendSystem(threadID, "已強制停止", status: "cancelled|已強制停止")
        currentNativeGoals.remove(threadID)
        finishGoalControl(threadID, accepted: false, message: "這一輪已強制終止，目標操作結果待確認")
        finishSteer(threadID, accepted: false, message: "這一輪已強制終止，請先確認插話是否送達", unknown: true)
        indexTurnArtifacts(threadID)
        runningThreads.remove(threadID); stoppingThreads.remove(threadID); remoteHandles.remove(threadID)
        if let sidecar = sidecars[threadID] {
            sidecar.onEvent = nil   // 之後的 closed 事件不能再動到這條討論串（可能已經換了新的 sidecar）
            sidecar.terminate()
        }
        sidecars[threadID] = nil
        persist()
        notifyTurnComplete(threadID, succeeded: false)
    }

    private func cancelUnfinishedRows(_ threadID: UUID, status: String) {
        let turn = turnID[threadID]
        for row in messages[threadID] ?? [] where row.turnID == turn &&
            (row.status?.hasPrefix("writing") == true || row.status?.hasPrefix("running-command") == true) {
            update(threadID, row.id) { $0.status = status }
        }
        streamingRowID[threadID] = nil
    }

    private func settleUnconfirmedDelivery(_ threadID: UUID, reason: String) {
        guard let pending = pendingTurnDeliveries.removeValue(forKey: threadID) else { return }
        update(threadID, pending.userRowID) { $0.status = "error|送達待確認" }
        pending.callback?(.unknown(reason))
    }

    func shutdownAll() {
        groupBridge.shutdown()
        chatGPTDispatcher?.stopAll()
        for id in runningThreads {
            if onTurnComplete[id] == nil { eventsFinished(id, succeeded: false, turn: turnID[id]) }
            cancelUnfinishedRows(id, status: "cancelled|引擎已關閉")
            touchLiveness(id, done: true)
            appendSystem(id, "引擎已關閉，這一輪已停止", status: "cancelled|引擎已關閉")
        }
        for id in Array(pendingTurnDeliveries.keys) {
            settleUnconfirmedDelivery(id, reason: "引擎已關閉，這一句是否送達仍待確認")
        }
        for runner in tapRunners.values { runner.shutdown() }
        tapRunners.removeAll()
        for id in Array(onTurnComplete.keys) { notifyTurnComplete(id, succeeded: false) }
        for id in Array(pendingGoalControls.keys) {
            finishGoalControl(id, accepted: false, message: "引擎已離線，目標操作結果待確認")
        }
        currentNativeGoals.removeAll()
        for id in Array(pendingSteers.keys) {
            finishSteer(id, accepted: false, message: "引擎已離線，請先確認插話是否送達", unknown: true)
        }
        for (_, s) in sidecars { s.close() }
        sidecars.removeAll(); remoteHandles.removeAll()
        runningThreads.removeAll(); stoppingThreads.removeAll()
        persist()
    }

    // MARK: - 派工引擎（E1）

    /// A new local reviewer retains the source cwd but never owns a worktree.
    /// Persist the capability with the thread so reopening cannot widen it.
    func configureReadOnlyRoom(threadID: UUID, parentThreadID: UUID, roomBrief: String, cwd: String) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[i].roomReadOnly = true
        configureRoom(threadID: threadID, parentThreadID: parentThreadID, roomBrief: roomBrief,
                      engine: "claude", cwdOverride: cwd, deviceID: nil)
    }

    /// 把新開的子討論串設成一個房間：父串、施工單、初始引擎、專屬 worktree。
    func configureRoom(threadID: UUID, parentThreadID: UUID, roomBrief: String, engine: String, cwdOverride: String, deviceID: String? = nil) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[i].parentThreadID = parentThreadID
        if let creator = threadRecord(parentThreadID)?.controllerCreatorFingerprint {
            doc.threads[i].controllerCreatorFingerprint = creator; doc.threads[i].memoryStrength = "off"
        }
        doc.threads[i].roomBrief = roomBrief
        doc.threads[i].subStatus = "running"
        doc.threads[i].engine = engine
        doc.threads[i].lastOutputAt = Date()
        doc.threads[i].cwdOverride = cwdOverride
        doc.threads[i].deviceID = deviceID
        persist()
    }

    func setRequestedModel(_ model: String?, threadID: UUID) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[i].requestedModel = model
        persist()
    }

    // MARK: - sidecar

    #if DEBUG
    func composedSystemPrompt(threadID: UUID, systemPrompt: String? = nil) -> String? {
        let includeUserPreferences: Bool
        do {
            includeUserPreferences = try ManagedEnginePolicy.forThread(threadID,
                creator: threadRecord(threadID)?.controllerCreatorFingerprint,
                fleet: DeviceFleetStore(registry: DeviceRegistry(environment: environment), environment: environment)) == nil
        } catch { includeUserPreferences = false }
        return composedSystemPrompt(threadID: threadID, systemPrompt: systemPrompt, includeUserPreferences: includeUserPreferences)
    }

    #endif

    private func composedSystemPrompt(threadID: UUID, systemPrompt: String? = nil, includeUserPreferences: Bool) -> String? {
        let isAssistant = doc.assistantProjectID != nil
            && threadRecord(threadID)?.projectID == doc.assistantProjectID
        let persona = isAssistant
            ? [OSUpstream.assistantPersona(), systemPrompt].compactMap { $0 }.joined(separator: "\n\n")
            : systemPrompt
        return OSUpstream.compose(threadSystemPrompt: persona, includeUserPreferences: includeUserPreferences, environment: environment)
    }

    private func ensureSidecar(_ threadID: UUID, model: String?, engine: ClaudeSidecar.Kind, systemPrompt: String? = nil) -> ClaudeSidecar? {
        // Enforce before reusing a resident runner as well as after a restart.
        if let record = threadRecord(threadID), record.roomReadOnly == true,
           engine != .claude || record.deviceID != nil {
            appendSystem(threadID, "此引擎／設備尚不支援唯讀副審，未啟動可寫入模式", status: "error|唯讀副審")
            markSubStatus(threadID, "failed")
            runningThreads.remove(threadID)
            return nil
        }
        guard let record = threadRecord(threadID) else { return nil }
        let controlled = record.controllerCreatorFingerprint != nil
        let memoryPolicy: ManagedEnginePolicy?
        do { memoryPolicy = try ManagedEnginePolicy.forThread(threadID, creator: record.controllerCreatorFingerprint,
            fleet: DeviceFleetStore(registry: DeviceRegistry(environment: environment), environment: environment)) }
        catch {
            sidecars[threadID]?.terminate(); sidecars[threadID] = nil
            runningThreads.remove(threadID)
            appendSystem(threadID, ManagedEnginePolicy.refusal(error, fleet: DeviceFleetStore(registry: DeviceRegistry(environment: environment), environment: environment)), status: "error|權限不足")
            return nil
        }
        let permissionMode = TatwoPermissionPreset.resolvedSidecarMode(
            user: controlled ? .askFirst : userPermissionPreset, bot: controlled ? .askFirst : record.botPermissionPreset,
            readOnly: record.roomReadOnly == true,
            legacyCodexAutoApprove: !controlled && autoApprove && engine == .codex)
        // Process exit can precede its queued main-thread close callback.
        if let s = sidecars[threadID], s.isRunning,
           s.isStarting || s.processIdentifier.flatMap({ OSSocketCaller.processStartTime($0) }).map({ $0 == s.processStartTime }) == true {
            // W181 R3：「不用 API 金鑰」在它啟動後切換過（啟動時才拿掉金鑰變數）：這條沒在回覆就重開，照新設定帶或拿掉金鑰。
            let apiKeyOptOutMatches = s.startedWithAPIKeyOptOut == !EngineDisableStore.allowsAPIKey(engine)
                || runningThreads.contains(threadID)
            let modelMatches = engine == .codex || sidecarModels[threadID] == (model ?? "") || runningThreads.contains(threadID)
            if s.kind == engine && sidecarPermissionModes[threadID] == (permissionMode ?? "configured-default")
                && modelMatches && apiKeyOptOutMatches && s.startedWithoutMemory == (memoryPolicy != nil) { return s }
            finishGoalControl(threadID, accepted: false, message: "引擎或權限已切換，目標操作結果待確認")
            currentNativeGoals.remove(threadID)
            s.onEvent = nil; s.close(); sidecars[threadID] = nil   // 換引擎：舊的先解除事件再關，免得它的「結束」事件蓋掉新引擎的狀態
        }
        guard let idx = doc.threads.firstIndex(where: { $0.id == threadID }) else { return nil }
        let thread = doc.threads[idx]
        let requestedDirectory = thread.cwdOverride ?? doc.projects.first { $0.id == thread.projectID }?.workdir
        let cwd: String
        do { cwd = try memoryPolicy?.workDirectory(for: thread, project: projectRecord(thread.projectID)) ?? requestedDirectory ?? NSHomeDirectory() }
        catch { runningThreads.remove(threadID); appendSystem(threadID, ManagedEnginePolicy.refusal(error, fleet: DeviceFleetStore(registry: DeviceRegistry(environment: environment), environment: environment)), status: "error|工作資料夾"); return nil }
        if thread.deviceID == nil, let problem = ExternalWorkspacePolicy.engineProblem(cwd: cwd) {   // W183 R6c 審查：不在入口 chatgpt/ 啟動引擎
            appendSystem(threadID, problem, status: "error|外部工作區")
            runningThreads.remove(threadID)
            return nil
        }
        let resume = thread.sessionID(for: engine.rawValue, isolated: memoryPolicy != nil)
        doc.threads[idx].engine = engine.rawValue
        let script = ClaudeSidecar.scriptPath(for: engine, allowsOverride: thread.roomReadOnly != true)
        let remote: RemoteDeviceRef?
        do {
            remote = try thread.deviceID.map {
                try RemoteDeviceLookup(root: store.url.deletingLastPathComponent()).device(id: $0)
            }
        } catch {
            appendSystem(threadID, String(describing: error), status: "error|遠端設備")
            runningThreads.remove(threadID)
            return nil
        }
        var remoteHandle: RemoteEngineHandle? = nil
        if let remote {
            do {
                // session handle 必須與本次 device／engine 一致；不一致：fixture fail-closed、production 依 registered device 重新 resolve 固定 handle（正常恢復語意不變）
                var testRequested = false
                #if DEBUG
                testRequested = RemoteSyncFixture.isRequested(environment: ProcessInfo.processInfo.environment)
                #endif
                remoteHandle = try RemoteEngineHandle.resolve(session: remoteHandles.get(threadID), device: remote, engine: engine, testRequested: testRequested)
            } catch {
                appendSystem(threadID, "capture-only／fixture fail-closed：\(error)", status: "error|遠端 handle")
                markSubStatus(threadID, "failed")
                runningThreads.remove(threadID)
                return nil
            }
        }
        guard remote != nil || FileManager.default.fileExists(atPath: script) else {
            appendSystem(threadID, "\(engine.rawValue) 引擎的 sidecar 還沒接（缺 \(script)）", status: "error|引擎未接")
            runningThreads.remove(threadID)
            return nil
        }
        let s = ClaudeSidecar(kind: engine)
        s.onRuntimeSelection = { [weak self, weak s] in
            guard let self, let s, self.sidecars[threadID] === s else { return }
            self.onChange?()
        }
        s.onEvent = { [weak self, weak s] e in
            guard let self, let s, self.sidecars[threadID] === s else { return }   // 只認目前這條串「現任」的 sidecar
            self.handle(threadID, e)
        }
        do {
            let mcpEngine = PluginsSource.MCPEngine(rawValue: engine.rawValue) ?? .grok
            let mcpConfig = thread.roomReadOnly == true ? nil : memoryPolicy != nil ? String(decoding: try JSONSerialization.data(withJSONObject: ["engine": engine.rawValue, "threadID": threadID.uuidString, "servers": [:], "configured": [], "enabled": []]), as: UTF8.self) : PluginsSource.sidecarMCPConfig(
                engine: mcpEngine,
                stored: thread.enabledMCP,
                threadID: threadID,
                environment: environment)
            try s.start(cwd: cwd, resume: resume, model: model, systemPrompt: composedSystemPrompt(threadID: threadID, systemPrompt: systemPrompt, includeUserPreferences: memoryPolicy == nil), mcpConfig: mcpConfig, permissionMode: permissionMode, remote: remoteHandle, memoryPolicy: memoryPolicy)
            sidecars[threadID] = s
            sidecarPermissionModes[threadID] = permissionMode ?? "configured-default"
            sidecarModels[threadID] = model ?? ""   // W184 H4 修正（審查 #1）
            return s
        } catch let error as RemoteCaptureOnlyError {
            appendSystem(threadID, String(describing: error), status: "error|capture-only")   // 明確 capture／BLOCKED，不冒充真房間完成
            markSubStatus(threadID, "failed")
            runningThreads.remove(threadID)
            return nil
        } catch {
            appendSystem(threadID, "sidecar 啟動失敗：\(error.localizedDescription)", status: "error|sidecar")
            if thread.roomReadOnly == true { markSubStatus(threadID, "failed") }
            runningThreads.remove(threadID)
            return nil
        }
    }

    #if DEBUG
    /// Exercise the production launch checkpoint with isolated fixture devices.
    func fixtureStartSidecar(_ thread: UUID, engine: ClaudeSidecar.Kind, systemPrompt: String? = nil) -> Bool {
        ensureSidecar(thread, model: nil, engine: engine, systemPrompt: systemPrompt) != nil
    }
    #endif

    /// R3 無頭驗收只讀：回目前討論串 sidecar（本機 node 或遠端 ssh）的 PID。
    func sidecarProcessID(threadID: UUID) -> Int32? {
        sidecars[threadID]?.processIdentifier
    }

    /// W178：目前每個 sidecar 的 pid 對到哪條討論串。本機 socket 用它認定呼叫的引擎屬於哪條對話，
    /// 引擎（與它開的 MCP、工具程式）不能自稱是別條（例如完整存取權的）對話。
    func sidecarProcessOwners() -> [pid_t: (thread: UUID, startTime: UInt64)] {
        var owners: [pid_t: (thread: UUID, startTime: UInt64)] = [:]
        for (thread, sidecar) in sidecars {
            if let pid = sidecar.processIdentifier, let startTime = sidecar.processStartTime { owners[pid] = (thread, startTime) }
        }
        return owners
    }

    static func engineStderrHint(_ s: String) -> String? {
        // 引擎的雜訊：去掉 ANSI 色碼；codex 的日誌行（時間戳＋INFO/WARN/ERROR）不當提示，只留人看得懂的
        var line = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 只認 timestamp 日誌的記憶 worker；使用者工具錯誤即使提到 memories 路徑也保留。
        if line.range(of: #"^\d{4}-\d{2}-\d{2}T[0-9:.]+Z?\s+ERROR\s+codex_core::memories(?:::|:)"#, options: .regularExpression) != nil {
            return nil
        }
        if line.range(of: #"^\d{4}-\d{2}-\d{2}T[0-9:.]+Z?\s+(TRACE|DEBUG|INFO|WARN|ERROR)\b"#, options: .regularExpression) != nil {
            if line.contains("ERROR") { line = "引擎回報錯誤：" + (line.split(separator: " ", maxSplits: 3).last.map(String.init) ?? line) }
            else { return nil }
        }
        // Node 自己的執行期警告（`(node:1234) [CODE] Warning: …`、`(Use \`node --trace-warnings\` …)`）不是給使用者看的。
        if line.range(of: #"^\(node:\d+\)|^\(Use `node --trace"#, options: .regularExpression) != nil { return nil }
        return line.isEmpty ? nil : String(line.prefix(120))
    }

    private func handle(_ threadID: UUID, _ e: ClaudeSidecar.Event) {
        // 常駐 CLI 的晚到關閉只收掉它自己，不能結束正在喚醒／回覆的 TAP。
        if tapRunners[threadID] != nil {
            switch e {
            case .sdk(let metadata): handleSDK(threadID, metadata)
            case .closed: sidecars[threadID] = nil
            case .permission(let id, _, _, _, _): sidecars[threadID]?.respondPermission(id: id, allow: false)
            default: break
            }
            return
        }
        switch e {
        case .sdk(let m): handleSDK(threadID, m)
        case .permission(let id, let tool, let input, _, let description):
            if threadRecord(threadID)?.roomReadOnly == true {
                sidecars[threadID]?.respondPermission(id: id, allow: false)
                appendSystem(threadID, "唯讀副審不允許擴張工具權限", status: "done|權限")
                return
            }
            withPendingPermission(threadID) {
            let pretty = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(input)"
            let controlled = threadRecord(threadID)?.controllerCreatorFingerprint != nil
            if let creator = threadRecord(threadID)?.controllerCreatorFingerprint,
               (try? DeviceFleetStore(registry: DeviceRegistry(environment: environment), environment: environment).allowsNativeExecution(fingerprint: creator)) != true {
                sidecars[threadID]?.respondPermission(id: id, allow: false)
                return
            }
            let botPreset: TatwoPermissionPreset? = controlled ? .askFirst : doc.threads.first(where: { $0.id == threadID })?.botPermissionPreset
            let botDecision: Bool?
            if botPreset == .askFirst, permissionDecider == nil {
                let alert = NSAlert(); alert.messageText = "Bot 想要執行 " + tool
                alert.informativeText = String(pretty.prefix(1200))
                alert.addButton(withTitle: "允許"); alert.addButton(withTitle: "拒絕")
                botDecision = alert.runModal() == .alertFirstButtonReturn
            } else if botPreset == .approveForMe || botPreset == .fullAccess { botDecision = true }
            else { botDecision = nil }
            let automatic = !controlled && ((botPreset ?? userPermissionPreset)?.automaticallyApprovesTools ?? autoApprove)
            // 沒有人可以問（無 UI 的呼叫路徑）就拒絕，不預設放行。
            let allow = botDecision ?? (automatic ? true :
                permissionDecider?(tool + (description.map { "：\($0)" } ?? ""), pretty) ?? false)
            eventsPermission(threadID, allowed: allow, human: botPreset == .askFirst || (!automatic && botDecision == nil && permissionDecider != nil))
            sidecars[threadID]?.respondPermission(id: id, allow: allow)
            appendSystem(threadID, (allow ? "允許 " : "拒絕 ") + tool, status: "done|權限")
            }
        case .stderr(let s):
            if let hint = Self.engineStderrHint(s) { onHint?(hint) }
        case .error(let s):
            appendEngineFailure(threadID, raw: s, status: "error|sidecar")
        case .closed:
            let stopped = stoppingThreads.contains(threadID)
            _ = chatGPTDispatcher?.stop(caller: threadID)
            if runningThreads.contains(threadID) {
                cancelUnfinishedRows(threadID, status: stopped ? "cancelled|已終止" : "cancelled|sidecar 結束")
                touchLiveness(threadID, done: true)
            }
            currentNativeGoals.remove(threadID)
            finishGoalControl(threadID, accepted: false, message: "引擎已離線，目標操作結果待確認")
            finishSteer(threadID, accepted: false, message: "引擎已離線，請先確認插話是否送達", unknown: true)
            if let rid = streamingRowID[threadID] { update(threadID, rid) { if $0.status?.hasPrefix("writing") == true { $0.status = "cancelled|sidecar 結束" } } }
            streamingRowID[threadID] = nil
            // W184 H4 修正第二輪（審查 #1）：引擎在讀到這一句之前就結束（換模型重開、接回原本的對話失敗）＝這一句沒送到、沒執行：
            // 說清楚、那一列標沒送到、草稿留著（不自動重送）；ultrawork 的「上一輪」不動，重送時照樣補說一聲「關了」。
            if stopped {
                settleUnconfirmedDelivery(threadID, reason: "已停止，這一句是否送達仍待確認")
                indexTurnArtifacts(threadID)
            } else if let pending = pendingTurnDeliveries[threadID] {
                if pending.turn == turnID[threadID], runningThreads.contains(threadID) {
                    failTurnDelivery(threadID, reason: "引擎在讀到這一句之前就結束了", markRow: true)
                    appendSystem(threadID, Self.undeliveredClosedText, status: Self.undeliveredRowStatus)
                } else {
                    pendingTurnDeliveries[threadID] = nil
                    pending.callback?(.unknown("引擎已經結束，不確定那一句有沒有送到"))
                }
            } else if runningThreads.contains(threadID) {
                appendSystem(threadID, "引擎在這一輪中途結束。常見原因：剛啟動時 macOS 跳出「取用可卸除式卷宗」權限詢問還沒按允許（Codex 的設定在外接卷上）。按允許後把這句再送一次即可。", status: "error|引擎結束")
                indexTurnArtifacts(threadID)
            }
            runningThreads.remove(threadID); stoppingThreads.remove(threadID); remoteHandles.remove(threadID)
            sidecars[threadID] = nil; persist()
            notifyTurnComplete(threadID, succeeded: false)
        }
    }

    func handleSDK(_ threadID: UUID, _ m: [String: Any]) {
        if EngineModelCatalog.receive(m, deviceID: threadRecord(threadID)?.deviceID ?? "local") { onChange?(); return }
        // 閒置的 CLI 可能晚到 init/result；不能把正在回答的 TAP 回合結束掉。
        guard tapRunners[threadID] == nil else { return }
        // A preboot cancellation has no native session yet. Only a matching
        // pending request from this Codex sidecar may settle that rejection.
        if m["type"] as? String == "system", m["subtype"] as? String == "goal_result",
           m["session_id"] == nil || m["session_id"] is NSNull {
            guard sidecars[threadID]?.kind == .codex, m["accepted"] as? Bool == false,
                  let id = m["request_id"] as? String, id == pendingGoalControls[threadID]?.id else { return }
            finishGoalControl(threadID, accepted: false, message: m["message"] as? String)
            return
        }
        if m["type"] as? String == "system", let subtype = m["subtype"] as? String,
           ["goal", "goal_unavailable", "goal_result", "native_turn_started"].contains(subtype) {
            guard let index = doc.threads.firstIndex(where: { $0.id == threadID }),
                  let session = m["session_id"] as? String,
                  session == doc.threads[index].sessionID(for: "codex", isolated: sidecars[threadID]?.startedWithoutMemory == true),
                  sidecars[threadID]?.kind == .codex else { return }
            switch subtype {
            case "goal":
                let previousEventGoal = doc.threads[index].nativeGoal
                if m["goal"] is NSNull {
                    doc.threads[index].nativeGoal = nil
                } else if let value = m["goal"], let goal = ChatNativeGoal.decode(value), goal.threadId == session {
                    doc.threads[index].nativeGoal = goal
                } else { return }
                eventsNativeGoal(threadID, previous: previousEventGoal)
                currentNativeGoals.insert(threadID)
                nativeGoalErrors[threadID] = nil
                persist()
            case "goal_unavailable":
                currentNativeGoals.remove(threadID)
                nativeGoalErrors[threadID] = m["message"] as? String ?? "無法確認原生目標"
                onChange?()
            case "goal_result":
                guard let id = m["request_id"] as? String, id == pendingGoalControls[threadID]?.id else { return }
                finishGoalControl(threadID, accepted: m["accepted"] as? Bool == true,
                                  message: m["message"] as? String)
            default:
                guard let id = m["client_turn_id"] as? String, id.hasPrefix("native:"),
                      !id.dropFirst("native:".count).isEmpty,
                      !isRunning(threadID) || turnID[threadID] == id else { return }
                if turnID[threadID] == id { return }
                turnID[threadID] = id; eventsTurnStarted(threadID, turn: id)
                artifactClaims[threadID] = []
                artifactClaimsTruncated.remove(threadID)
                streamingRowID[threadID] = nil
                runningThreads.insert(threadID)
                if m["stopping"] as? Bool == true { stoppingThreads.insert(threadID) }
                touchLiveness(threadID)
                persist()
            }
            return
        }
        // An acknowledgement can arrive after this turn's terminal event.
        // Bind it to its own pending request, not whichever turn runs now.
        if m["type"] as? String == "system", m["subtype"] as? String == "steer_result" {
            guard let requestID = m["request_id"] as? String, let target = m["target_turn_id"] as? String else { return }
            guard let pending = pendingSteers[threadID],
                  requestID == pending.requestID, target == pending.targetTurnID else {
                // A late native reply may resolve a previously unknown row,
                // but must not clear a newer composer draft or another turn.
                if messages[threadID]?.contains(where: {
                    $0.id == requestID && $0.turnID == target && $0.status?.hasPrefix("steer_unknown|") == true
                }) == true, m["unknown"] as? Bool != true {
                    update(threadID, requestID) { $0.status = m["accepted"] as? Bool == true ? nil : "steer_failed|插話未送出" }
                    persist()
                }
                return
            }
            finishSteer(threadID, accepted: m["accepted"] as? Bool == true,
                        message: m["message"] as? String, unknown: m["unknown"] as? Bool == true)
            return
        }
        // Codex uses the UUID already sent by this App, not a second state store.
        // A cancelled turn may still emit while its native interrupt settles.
        // Never let that old result clear a subsequent send's running state.
        if let clientTurn = m["client_turn_id"] as? String {
            guard clientTurn == turnID[threadID], runningThreads.contains(threadID) else { return }
        }
        touchLiveness(threadID)
        let type = m["type"] as? String ?? ""
        // W184 H4 修正第二輪（GPT-6 H4b 審查 #1）：這一輪有沒有真的送到引擎，看它回的第一個屬於這一輪的事件：Codex 的 turn_accepted
        // （turn/start 收下）、回覆的串流、工具、成功的結果＝收到；還沒收到就回報失敗或停止的結果＝沒送到（沒執行）。system 的 init／model
        // 不算（重開時一啟動就有，不代表讀到這一句）。
        if let pendingTurn = pendingTurnDeliveries[threadID]?.turn, pendingTurn == turnID[threadID] {
            switch type {
            case "stream_event", "assistant", "user":
                confirmTurnDelivery(threadID)
            case "system" where m["subtype"] as? String == "turn_accepted":
                confirmTurnDelivery(threadID)
            case "result":
                if m["is_error"] as? Bool == true || m["subtype"] as? String == "cancelled" {
                    failTurnDelivery(threadID, reason: (m["result"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
                                        ?? "引擎還沒開始這一輪就停了", markRow: true)
                } else {
                    confirmTurnDelivery(threadID)
                }
            default:
                break
            }
        }
        switch type {
        case "system":
            if m["subtype"] as? String == "turn_continued" { endStreaming(threadID) }
            if m["subtype"] as? String == "engine_error", let message = m["message"] as? String {
                appendEngineFailure(threadID, raw: message, details: m["details"] as? String, status: "error|sidecar")
            }
            if m["subtype"] as? String == "turn_error", let message = m["message"] as? String {
                if m["retrying"] as? Bool == true {
                    appendEngineFailure(threadID, raw: message, details: m["details"] as? String, status: "info|引擎重試", retrying: true)
                } else { appendSystem(threadID, message, status: "error|停止失敗") }
            }
            if m["subtype"] as? String == "model" {
                let reported = (m["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                attestedModel[threadID] = reported   // native settings event, not the UI's requested model
                if let reported, let index = doc.threads.firstIndex(where: { $0.id == threadID }) {
                    doc.threads[index].model = reported
                    persist()
                }
            }
            if m["subtype"] as? String == "init", let sid = m["session_id"] as? String,
               let i = doc.threads.firstIndex(where: { $0.id == threadID }) {
                let kind = sidecars[threadID]?.kind ?? .claude
                doc.threads[i].sessionIDs[kind.rawValue] = sid
                doc.threads[i].sessionIsolated[kind.rawValue] = sidecars[threadID]?.startedWithoutMemory == true
                if kind == .claude { doc.threads[i].sessionID = sid }
                if let model = m["model"] as? String {
                    doc.threads[i].model = model
                    attestedModel[threadID] = (model.isEmpty || model == "default") ? nil : model
                }
                persist()
            }
        case "stream_event":
            guard let ev = m["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_delta",
               let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta",
               let t = d["text"] as? String { appendStreaming(threadID, t) }
        case "assistant":
            guard let msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            if let reported = msg["model"] as? String, !reported.isEmpty { attestedModel[threadID] = reported }   // Claude SDK 每則 assistant message 都帶實際模型
            for b in content where b["type"] as? String == "tool_use" {
                endStreaming(threadID)
                let name = b["name"] as? String ?? "工具"
                let input = b["input"] as? [String: Any] ?? [:]
                for path in TurnArtifacts.claimedPaths(tool: name, input: input) {
                    if artifactClaims[threadID, default: []].contains(path) { continue }
                    if artifactClaims[threadID, default: []].count < TurnArtifacts.maxPaths {
                        artifactClaims[threadID, default: []].append(path)
                    } else { artifactClaimsTruncated.insert(threadID) }
                }
                let summary = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["pattern"] as? String)
                    ?? (input["description"] as? String) ?? (input["prompt"] as? String).map { String($0.prefix(80)) } ?? ""
                let row = ChatMessage(id: b["id"] as? String ?? UUID().uuidString, role: .assistant,
                                      text: summary.isEmpty ? name : "\(name)：\(summary)",
                                      status: "running-command|\(name)", eventKind: .toolUse, turnID: turnID[threadID])
                append(threadID, row)
            }
        case "user":
            guard let msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for b in content where b["type"] as? String == "tool_result" {
                guard let useID = b["tool_use_id"] as? String else { continue }
                let isError = b["is_error"] as? Bool == true
                update(threadID, useID) { row in
                    let name = row.status?.split(separator: "|").last.map(String.init) ?? "工具"
                    row.status = isError ? "error|\(name)" : "done|\(name)"
                }
            }
        case "result":
            eventsUsage(threadID, tokens: PetTokenUsage.output(m))
            let cancelled = m["subtype"] as? String == "cancelled"
            let failed = m["is_error"] as? Bool == true
            endStreaming(threadID, status: cancelled ? "cancelled|已停止" : "done")
            if let turn = turnID[threadID] {
                let unfinishedStatus = cancelled ? (sidecars[threadID]?.kind == .claude ? "cancelled|已終止" : "cancelled|已停止")
                    : failed ? "error|回合失敗" : "info|回合已結束，工具結果未回報"
                for row in messages[threadID] ?? []
                where row.turnID == turn && row.status?.hasPrefix("running-command") == true {
                    update(threadID, row.id) { $0.status = unfinishedStatus }
                }
            }
            touchLiveness(threadID, done: true)
            if failed, let index = doc.threads.firstIndex(where: { $0.id == threadID }),
               doc.threads[index].parentThreadID != nil {
                doc.threads[index].subStatus = "failed"
            }
            if failed, let r = m["result"] as? String, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendEngineFailure(threadID, raw: r, details: m["error_details"] as? String, status: "error|回合失敗")
            }
            indexTurnArtifacts(threadID)
            finishSteer(threadID, accepted: false, message: "回合已結束，請先確認插話是否送達", unknown: true)
            let succeeded = !cancelled && !failed && !stoppingThreads.contains(threadID)
            if succeeded, runningThreads.contains(threadID),
               let reply = messages[threadID]?.last(where: {
                   $0.turnID == turnID[threadID] && $0.role == .assistant && $0.eventKind == .message
                       && $0.runtimeAdapterID != TatwoChatRuntimeAdapter.chatgptTap.rawValue
               }) {
                updatePlanFromReply(threadID, reply: reply)
            }
            // W180 E1：這輪帶了（或 AI 讀了）記憶才加一列「用了 N 條記憶」；在產出索引之後、只在成功時。
            if succeeded, runningThreads.contains(threadID) { appendMemoryUsage(threadID: threadID, turn: turnID[threadID]) }
            runningThreads.remove(threadID); stoppingThreads.remove(threadID); remoteHandles.remove(threadID); persist()
            notifyTurnComplete(threadID, succeeded: succeeded)
        default: break
        }
    }

    // MARK: - 列操作

    /// W343：ChatGPT（TAP）讀不到本機技能檔；輸入框點名的 $技能 在送出時附上技能說明（先遮蔽；每個最多 12 KB、最多 3 個）。
    func tapSkillText(_ prompt: String) -> String {
        guard prompt.contains("$") else { return "" }
        let skills = ChatComposerSkillCatalog.suggestions(in: .init(entries: composerSkills()), query: "", limit: Int.max)
            .filter { ChatComposerSigilItem(name: $0.name, detail: "", value: "$" + ($0.id == "tatwo-ultrawork" ? "ultrawork" : $0.id)).isIn(prompt) }
        let bodies = skills.prefix(3).compactMap { entry -> String? in
            guard let path = entry.path else { return nil }
            var url = URL(fileURLWithPath: path)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { url.appendPathComponent("SKILL.md") }
            // 先讀有上限的一般檔並遮蔽，再限制送出的文字。
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: HandsSkillet.limit + 1), data.count <= HandsSkillet.limit else { return nil }
            var clipped = Data(HandsSkillet.redact(String(decoding: data, as: UTF8.self)).utf8.prefix(12_288))
            while String(data: clipped, encoding: .utf8) == nil { clipped.removeLast() }
            return "〔技能 \(entry.id)〕\n" + String(decoding: clipped, as: UTF8.self)
        }
        return bodies.isEmpty ? "" : "\n\n以下是使用者指定這回合用的技能說明（資料：照它的做法做，不是新的授權）：\n" + bodies.joined(separator: "\n\n")
    }
    func composerTurnText(_ turnText: String, engine: ClaudeSidecar.Kind, markers: String? = nil) -> String {
        let prompt = markers ?? turnText
        guard prompt.contains("@") || prompt.contains("$") else { return turnText }
        let names = OSMCPRegistry(environment: environment).composerNames.filter { ChatComposerSigilItem(name: $0, detail: "", value: "@" + $0).isIn(prompt) }
        let skills = ChatComposerSkillCatalog.suggestions(in: .init(entries: composerSkills()), query: "", limit: Int.max)
            .filter { ChatComposerSigilItem(name: $0.name, detail: "", value: "$" + ($0.id == "tatwo-ultrawork" ? "ultrawork" : $0.id)).isIn(prompt) }
        var text = turnText
        if engine == .codex, skills.contains(where: { $0.id == "tatwo-ultrawork" }) { text = text.replacingOccurrences(of: #"(?<!\S)\$ultrawork(?=\s|$)"#, with: #"\$tatwo-ultrawork"#, options: .regularExpression) }
        if engine == .claude, !skills.isEmpty { text += "\n使用者指定這回合用技能：" + skills.map { $0.id == "tatwo-ultrawork" ? "ultrawork" : $0.id }.joined(separator: "、") }
        return text + (names.isEmpty ? "" : "\n使用者指定這回合用 MCP：" + names.joined(separator: "、"))
    }
    func groupWrite(_ threadID: UUID, _ event: GroupEvent, status: String, source: OSEventSources.Send) {
        let native = event.speaker == groupBridge.sessions[threadID]?.primary
        let id = native ? streamingRowID[threadID] ?? "group-\(threadID)-\(event.sequence)" : "group-\(threadID)-\(event.sequence)"
        if messages[threadID]?.contains(where: { $0.id == id }) == true { update(threadID, id) { $0.text = event.text; $0.status = status; if !event.kind.hasPrefix("proposal") { $0.turnID = self.turnID[threadID] } } }
        else { append(threadID, ChatMessage(id: id, role: event.speaker == "使用者" ? .user : .assistant, text: event.text, status: status, runtimeAdapterID: native || event.speaker == "使用者" || event.speaker.hasPrefix("沙盒（外部資料）") ? nil : TatwoChatRuntimeAdapter.chatgptTap.rawValue,
            turnID: turnID[threadID]), source: source) }
        persist()
    }
    func groupStopPrimary(_ threadID: UUID) {
        let stoppedTurn = turnID[threadID]
        requestStop(threadID, pauseGoal: threadRecord(threadID)?.nativeGoal?.status == "active" ? true : nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2_500))
            guard let self, self.turnID[threadID] == stoppedTurn else { return }
            self.forceStop(threadID)
        }
    }

    private func sendTap(threadID: UUID, text: String, routeID: String, attachments: [String], effort: String?,
                         delivery: (@MainActor (LiveSendDelivery) -> Void)?, source: OSEventSources.Send) -> Bool {
        if let reason = ManagedConversationTAPPolicy.rejectionReason(model: routeID, creator: threadRecord(threadID)?.controllerCreatorFingerprint) {
            appendSystemMessage(threadID: threadID, text: reason, status: "error|ChatGPT TAP"); return false
        }
        guard let thread = threadRecord(threadID), thread.deviceID == nil else {
            appendSystemMessage(threadID: threadID, text: "ChatGPT TAP 只使用這台的 ChatGPT Pod；請在本機討論串送出。", status: "error|ChatGPT TAP")
            return false
        }
        let history = messages[threadID] ?? []
        let tapModel = ChatRouteChoice.resolve(routeID).tapModel
        let requestedEffort = effort ?? thread.requestedEffort
        let forwardedEffort = tapModel.flatMap { model in
            model.efforts.first { $0.id == requestedEffort }?.id ?? ChatGPTTapModelCatalog.defaultEffort(for: model)
        }
        let project = (thread.projectID == doc.generalProjectID ? nil : projectRecord(thread.projectID)).map {
            TapProjectContext(id: $0.id, name: $0.name, folder: URL(fileURLWithPath: $0.workdir, isDirectory: true))
        }
        let turn = UUID().uuidString
        turnID[threadID] = turn
        tapTurn[threadID] = ChatGPTCoderTurnState()
        let user = ChatMessage(role: .user, text: ChatAttachmentTranscript.displayTurn(text: text, attachmentPaths: attachments),
                               modelID: routeID, runtimeAdapterID: TatwoChatRuntimeAdapter.chatgptTap.rawValue, turnID: turn)
        append(threadID, user, source: source)
        let reply = ChatMessage(role: .assistant, text: "", status: "writing|ChatGPT TAP 準備中",
                                modelID: routeID, runtimeAdapterID: TatwoChatRuntimeAdapter.chatgptTap.rawValue, turnID: turn)
        streamingRowID[threadID] = reply.id
        runningThreads.insert(threadID)
        touchLiveness(threadID)
        append(threadID, reply)
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) {
            doc.threads[i].requestedModel = routeID
            doc.threads[i].engine = TatwoChatRuntimeAdapter.chatgptTap.rawValue
            doc.threads[i].model = routeID
            doc.threads[i].requestedEffort = forwardedEffort
            if doc.threads[i].title == "新聊天" { doc.threads[i].title = String(text.prefix(24)) }
        }
        let guarded = GroupGuardedTap(tap: conversationTap) { [weak self] in
            guard let thread = self?.threadRecord(threadID) else { return "對話已不存在，這句尚未送出" }
            return ManagedConversationTAPPolicy.rejectionReason(model: routeID, creator: thread.controllerCreatorFingerprint)
        }
        let runner = ChatGPTTapTurnRunner(tap: conversationTap, mapper: TapProjectMapper(tap: guarded, storage: tapMapper.storage, inboxFolder: tapMapper.inboxFolder, lifecycleSource: tapMapper))
        tapRunners[threadID] = runner
        var terminalReceived = false
        let event: (TapStreamEvent) -> Void = { [weak self, weak runner] event in
            guard let self, !terminalReceived else { return }
            let terminal: Bool
            switch event { case .finished, .failed, .notSubmitted: terminal = true; default: terminal = false }
            let ownsRunner = runner != nil && self.tapRunners[threadID] === runner
            // 結束回執屬於原本的列與草稿，即使 shutdown 移除了 runner 也必須交付一次。
            guard terminal || (ownsRunner && self.turnID[threadID] == turn) else { return }
            if ownsRunner { self.touchLiveness(threadID) }
            let previousProgress = self.tapTurn[threadID]?.progress
            self.tapTurn[threadID]?.progress.apply(event)
            switch event {
            case .queued:
                self.update(threadID, reply.id) { $0.status = "writing|ChatGPT 準備中" }
            case .progress:
                guard previousProgress != self.tapTurn[threadID]?.progress else { break }
                self.onChange?()
            case .accepted:
                self.tapTurn[threadID]?.failure = nil
                let thinkingStarted = self.tapTurn[threadID]?.thinking?.started
                self.update(threadID, reply.id) {
                    $0.status = "writing|ChatGPT 思考中"
                    if let thinkingStarted { $0.createdAt = thinkingStarted }
                }
                self.onChange?()
            case .text(_, let full):
                self.update(threadID, reply.id) { $0.text = full; $0.status = "writing|回覆中" }
            case .finished, .failed, .notSubmitted:
                terminalReceived = true
                var succeeded = false
                var outcome: LiveSendDelivery = .delivered
                switch event {
                case .finished:
                    succeeded = runner?.stopping != true
                    let note = ChatGPTThinking.doneText(self.tapTurn[threadID]?.thoughtSeconds)
                    self.update(threadID, reply.id) {
                        $0.status = succeeded ? (note.map { "done|" + $0 } ?? "done") : "cancelled|已停止"
                    }
                case .failed(let reason, let code):
                    let failure = ChatGPTTurnFailure(message: reason, reason: code, draft: text, paths: attachments)
                    self.tapTurn[threadID, default: .init()].failure = failure
                    self.update(threadID, reply.id) { $0.status = failure.storedStatus }
                    self.onChange?()
                    // 未證明沒送出，不能用 unknown 的草稿復原路徑。
                case .notSubmitted(let reason):
                    let failure = ChatGPTTurnFailure(message: reason, reason: "not_submitted", draft: text, paths: attachments)
                    outcome = .notDelivered(failure.message)
                    self.update(threadID, user.id) { $0.status = Self.undeliveredRowStatus }
                    self.tapTurn[threadID, default: .init()].failure = runner?.stopping == true ? nil : failure
                    self.update(threadID, reply.id) {
                        $0.status = runner?.stopping == true ? "cancelled|已停止" : failure.storedStatus
                    }
                default: break
                }
                if ownsRunner {
                    self.touchLiveness(threadID, done: true)
                    if !succeeded, let index = self.doc.threads.firstIndex(where: { $0.id == threadID }),
                       self.doc.threads[index].parentThreadID != nil, !self.stoppingThreads.contains(threadID) {
                        self.doc.threads[index].subStatus = "failed"
                    }
                    self.runningThreads.remove(threadID)
                    self.stoppingThreads.remove(threadID)
                    self.streamingRowID[threadID] = nil
                    self.tapRunners[threadID] = nil
                }
                self.persist()
                delivery?(outcome)
                if ownsRunner { self.notifyTurnComplete(threadID, succeeded: succeeded) }
            default: break
            }
        }
        let start = {
            runner.start(threadID: threadID, project: project, title: self.threadRecord(threadID)?.title ?? thread.title, text: PetPersonality.turnText(source.origin == "composer" ? self.composerTurnText(text, engine: .codex) + self.tapSkillText(text) : text, engine: self, projectID: thread.projectID, source: source),
                 routeID: routeID, effort: forwardedEffort, attachmentPaths: attachments, history: history,
                 resolved: { [weak self] route, effort in
                     guard let self, let i = self.doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
                     self.doc.threads[i].model = route; self.doc.threads[i].requestedModel = route; self.doc.threads[i].requestedEffort = effort
                     for id in [user.id, reply.id] { self.update(threadID, id) { $0.modelID = route; $0.modelDisplayName = ChatRouteChoice.resolve(route).title } }
                     self.persist()
                 },
                 notice: { [weak self] reason in self?.appendSystemMessage(threadID: threadID, text: reason, status: "info|ChatGPT") }, event: event)
        }
        if let tap = conversationTap as? ChatGPTTap { tap.withQueuedSendRejection(guarded.rejection, start) }
        else { start() }
        persist()
        return true
    }

    func rememberTapFailureNames(_ threadID: UUID, draft: String, names: [String: String]) {
        guard let failure = tapTurn[threadID]?.failure, failure.draft == draft else { return }
        tapTurn[threadID]?.failure?.names = names.filter { failure.paths.contains($0.key) }
    }

    private func indexTurnArtifacts(_ threadID: UUID) {
        guard let turn = turnID[threadID], let thread = threadRecord(threadID),
              indexedArtifactTurn[threadID] != turn,
              thread.deviceID == nil else { return }
        // 跟 ensureSidecar 用同一套 cwd 規則：沒有專案的對話（例如「新聊天」）也在家目錄跑，索引也要用同一個根，
        // 不然回合結尾永遠沒有產出卡（lab 實測 2026-09-06 抓到）。
        let cwd = thread.cwdOverride ?? projectRecord(thread.projectID)?.workdir ?? NSHomeDirectory()
        indexedArtifactTurn[threadID] = turn
        let claimed = artifactClaims.removeValue(forKey: threadID) ?? []
        let truncated = artifactClaimsTruncated.remove(threadID) != nil
        let messageID = messages[threadID]?.last(where: { $0.turnID == turn })?.id
        let endedAt = Date()
        let artifacts = turnArtifacts
        gitSummary(for: threadID) { [weak self] summary in
            Task {
                do {
                    _ = try await artifacts.collect(threadID: threadID, turnID: turn, messageID: messageID,
                                                    endedAt: endedAt, cwd: cwd, claimed: claimed,
                                                    gitFiles: summary.files, truncated: truncated || summary.truncated)
                    self?.onChange?()
                } catch {
                    self?.appendSystemMessage(threadID: threadID, text: "本回合產出索引未能儲存。",
                                              status: "error|產出索引")
                }
            }
        }
    }

    private func appendStreaming(_ threadID: UUID, _ delta: String) {
        if let rid = streamingRowID[threadID] {
            update(threadID, rid) { $0.appendTranscriptText(delta) }
        } else {
            var row = ChatMessage(role: .assistant, text: delta, status: "writing|回覆中", turnID: turnID[threadID])
            row.modelID = attestedModel[threadID]   // 回覆中就用引擎回報的模型畫頭像，不等到結束
            streamingRowID[threadID] = row.id
            append(threadID, row)
        }
    }

    /// 子討論串活性：每收到一個事件就記時間；回合結束記 done
    private func touchLiveness(_ threadID: UUID, done: Bool = false) {
        // Late init/model metadata is still useful, but cannot restart work.
        guard done || runningThreads.contains(threadID) else { return }
        guard var t = doc.threads.first(where: { $0.id == threadID }) else { return }
        if t.parentThreadID == nil && t.subStatus == nil { return }
        t.lastOutputAt = Date(); t.subStatus = done ? "done" : "running"
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) { doc.threads[i] = t }
    }

    private func endStreaming(_ threadID: UUID, status: String = "done") {
        // Ending a text segment to show a tool is not ending the native turn.
        if let rid = streamingRowID[threadID] {
            let attested = attestedModel[threadID]
            update(threadID, rid) { $0.status = status; $0.modelID = attested }
        }
        streamingRowID[threadID] = nil
    }

    /// 只有這些系統列代表這條房間這一輪已經死了：sidecar 起不來／退出、回合失敗、引擎沒接、遠端設備連不上。
    static let fatalRoomStatuses: Set<String> = ["error|sidecar", "error|回合失敗", "error|引擎結束", "error|引擎未接", "error|遠端設備"]

    private func appendEngineFailure(_ threadID: UUID, raw: String, details: String? = nil, status: String, retrying: Bool = false) {
        let record = threadRecord(threadID)
        let failedRoute = ChatRouteChoice.resolve(record?.requestedModel ?? record?.model ?? "gpt-6.1-sol")
        let kind = sidecars[threadID]?.kind ?? AssistantModelRouting.engineKind(for: failedRoute) ?? .codex
        let alternative = ChatRouteChoice.all.first { $0.id != failedRoute.id && AssistantModelRouting.engineKind(for: $0) == kind }?.title
            ?? (kind == .claude ? "GPT-6.1 Sol" : "Claude Sonnet 5")
        let presentation = EngineFailurePresentation.make(raw, details: details, alternative: alternative, retrying: retrying)
        if !retrying, messages[threadID]?.last?.engineErrorDetails == presentation.details { return }
        if Self.fatalRoomStatuses.contains(status), let index = doc.threads.firstIndex(where: { $0.id == threadID }),
           doc.threads[index].parentThreadID != nil, doc.threads[index].subStatus == "running" {
            doc.threads[index].subStatus = "failed"
        }
        var row = ChatMessage(role: .system, text: presentation.summary, status: presentation.category == .login ? "error|登入" : status, turnID: turnID[threadID])
        row.engineErrorDetails = presentation.details
        append(threadID, row)
        persist()
    }

    private func appendSystem(_ threadID: UUID, _ text: String, status: String) {
        // 房間（子對話）遇到「致命」的引擎事件才立刻標 failed（白名單；review：通用 error 如產出索引存檔失敗可能晚到下一回合，不能拿來改工作狀態）
        if Self.fatalRoomStatuses.contains(status), let i = doc.threads.firstIndex(where: { $0.id == threadID }),
           doc.threads[i].parentThreadID != nil, doc.threads[i].subStatus == "running" {
            doc.threads[i].subStatus = "failed"
            persist()
        }
        append(threadID, ChatMessage(role: .system, text: text, status: status, turnID: turnID[threadID]))
    }

    private func append(_ threadID: UUID, _ row: ChatMessage, source: OSEventSources.Send? = nil) {
        eventsRow(threadID, row, source: source)
        messages[threadID, default: []].append(row); groupBridge.recordStep(threadID, row); touch(threadID); onChange?()
    }

    private func update(_ threadID: UUID, _ rowID: String, _ body: (inout ChatMessage) -> Void) {
        guard var rows = messages[threadID], let i = rows.firstIndex(where: { $0.id == rowID }) else { return }
        body(&rows[i]); messages[threadID] = rows; touch(threadID); onChange?()
    }

    private func touch(_ threadID: UUID) {
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) { doc.threads[i].updatedAt = Date() }
    }

    private func persist() {
        for i in doc.threads.indices { doc.threads[i].messages = (messages[doc.threads[i].id] ?? []).map(LiveMessageRecord.init) }
        store.save(doc); onChange?()
    }

    /// W182 R5：把幾列文字接在這條最後並存檔（只加文字列、不觸發引擎；回覆中不加）。同 id 的列已經在就略過（重送不重複）。
    /// 回傳真的加了幾列。
    @discardableResult
    func appendOfflineRows(threadID: UUID, rows: [ChatMessage]) -> Int {
        guard threadRecord(threadID) != nil, !runningThreads.contains(threadID) else { return 0 }
        let existing = Set((messages[threadID] ?? []).map(\.id))
        let fresh = rows.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        messages[threadID, default: []].append(contentsOf: fresh); touch(threadID); persist()
        return fresh.count
    }

    func persistSpaceConversation() throws {
        for i in doc.threads.indices {
            doc.threads[i].messages = (messages[doc.threads[i].id] ?? []).map(LiveMessageRecord.init)
        }
        try store.saveChecked(doc)
    }
}

extension ChatLiveEngine {
    /// OS 自己的斜線約定（引擎 CLI 不認得）開頭的訊息，換成引擎看得懂的說明。其他文字原樣送出。
    static func engineText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // W180 E4：/蒸餾 跟 /plg 一樣是 OS 的約定，原文送給 Claude 會被當成它自己不認得的斜線指令。
        if let topic = DistillCanvas.argument(in: trimmed) {
            return "（使用者下了 OS 指令 /蒸餾：把這條 session 做完的事整理成可重用的東西，預設寫成技能 SKILL.md。"
                + "照附上的畫布規則起草，放進 tatwo-distill 圍欄；寫不寫、寫到哪由使用者在畫布按鈕決定。）"
                + (topic.isEmpty ? "" : "\n\n主題：" + topic)
        }
        if let token = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).first,
           ["/plan", "/pr", "/feedback"].contains(String(token)) {
            let rest = String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let instruction: String
            switch token {
            case "/plan": instruction = "討論計畫，照附上的畫布規則整理 tatwo-plan；尚未確認與開始前只討論。"
            case "/pr": instruction = "討論對 TATWO OS 公開倉的貢獻計畫，照附上的畫布規則整理 tatwo-plan；只有 App 的確認按鈕能啟動實作。"
            default: instruction = "整理問題回報，照附上的畫布規則釐清並整理 tatwo-issue；提交由 App 的確認按鈕處理。"
            }
            return "（使用者要求：" + instruction + "）" + (rest.isEmpty ? "" : "\n\n" + rest)
        }
        guard trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == "/plg" else { return text }
        let rest = String(trimmed.dropFirst("/plg".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "（使用者下了 OS 指令 /plg：依已確認的計畫開工。主導自己能做的直接做；需要協作時用 tatwo2_os 的 dispatch_rooms 派房間，"
            + "每一步對回這串的目標清單。）" + (rest.isEmpty ? "" : "\n\n" + rest)
    }
}

// MARK: - W182 R4：別台離線時「在這台接著聊」（本機新建一條：第一則是串頂說明，後面是複製來的訊息；不碰引擎、不帶檔案）
// 規則與文字在 ChatPageModel+OfflineContinue.swift；這裡只放要碰私有存放（messages／persist）的那一段。

extension ChatLiveEngine {
    /// 在指定專案建一條新串（nil、找不到或是助理專案＝聊天），放進給的訊息列並存檔。不改選取（Coder 要選由呼叫端選；私訊框不動 Coder）。
    @discardableResult
    func insertOfflineCopy(projectID: UUID?, title: String, rows: [ChatMessage]) -> UUID {
        let known = projectID.map { id in id != doc.assistantProjectID && doc.projects.contains(where: { $0.id == id }) } ?? false
        let destination = known ? projectID! : doc.ensureGeneralProject()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = LiveThreadRecord(projectID: destination, title: trimmed.isEmpty ? "新聊天" : String(trimmed.prefix(120)),
                                      messages: rows.map(LiveMessageRecord.init))
        doc.threads.insert(thread, at: 0)
        messages[thread.id] = rows
        persist()
        return thread.id
    }
}

// MARK: - W183 R1：ChatGPT 手腳的房間（不啟動引擎、不改選取；每次工具呼叫一列，只存遮蔽過的摘要）
// 邏輯在 HandsRooms.swift／HandsService.swift；這裡只放要碰私有存放（messages／persist）的那一段。

extension ChatLiveEngine {
    /// 房間的 engine 欄位固定是這個值（存檔：重開 App 也還是鎖住的）。送出、退回重做都會被擋。
    static let handsEngine = "chatgpt-hands"
    static let handsSendBlockReason = "這條是「ChatGPT 手腳」的紀錄：只由 ChatGPT 透過 OS 工具操作，輸入框已鎖住（不在這裡叫 Claude／Codex 開跑）。"
        + "要審查請用施工卡的「查看 diff」，要動手請另開一條。"

    func isHandsThread(_ threadID: UUID?) -> Bool { threadRecord(threadID)?.engine == Self.handsEngine }

    /// 找或建「ChatGPT 手腳」根對話（W183 R1b：每個專案一條，工作區是它的子房；projectID＝nil 放「一般」專案）。不改選取、不啟動引擎。
    @discardableResult
    func handsRootThread(title: String, intro: String, projectID: UUID? = nil) -> UUID {
        let project = projectID.flatMap { id in doc.projects.contains(where: { $0.id == id }) ? id : nil } ?? doc.ensureGeneralProject()
        if let existing = doc.threads.first(where: {
            $0.engine == Self.handsEngine && $0.parentThreadID == nil && !$0.isArchived && $0.deviceID == nil && $0.projectID == project
        }) { return existing.id }
        var thread = LiveThreadRecord(projectID: project, title: title)
        thread.engine = Self.handsEngine
        let introRow = ChatMessage(id: "hands:intro", role: .system, text: intro, status: "info|ChatGPT 手腳")
        thread.messages = [LiveMessageRecord(introRow)]
        doc.threads.insert(thread, at: 0)
        messages[thread.id] = [introRow]
        persist()
        return thread.id
    }

    /// 在專案底下建一條工作區子房（id 由呼叫端給：worktree 路徑要用同一個）。
    func handsInsertWorkspace(id: UUID, projectID: UUID, parent: UUID, title: String, brief: String, worktree: String) {
        guard !doc.threads.contains(where: { $0.id == id }), doc.projects.contains(where: { $0.id == projectID }) else { return }
        var thread = LiveThreadRecord(id: id, projectID: projectID, title: String(title.prefix(120)))
        thread.engine = Self.handsEngine
        thread.parentThreadID = parent
        if let creator = threadRecord(parent)?.controllerCreatorFingerprint { thread.controllerCreatorFingerprint = creator; thread.memoryStrength = "off" }
        thread.roomBrief = brief
        thread.subStatus = "idle"
        thread.lastOutputAt = Date()
        thread.cwdOverride = worktree
        doc.threads.insert(thread, at: 0)
        messages[id] = []
        persist()
    }

    /// 只改房間狀態（工具真的開始改工作區時：running）。只改子房，不改根對話。
    func handsSetStatus(threadID: UUID, subStatus: String) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }), doc.threads[index].engine == Self.handsEngine,
              doc.threads[index].parentThreadID != nil, doc.threads[index].subStatus != subStatus else { return }
        doc.threads[index].subStatus = subStatus
        doc.threads[index].lastOutputAt = Date()
        touch(threadID)
        persist()
    }

    /// 記一列（同 id 就更新那列）。房間狀態：呼叫中 running、之間 idle、交件 done（只改子房，不改根對話）。
    func handsRecord(threadID: UUID, row: ChatMessage, subStatus: String?) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }), doc.threads[index].engine == Self.handsEngine else { return }
        if var rows = messages[threadID], let existing = rows.firstIndex(where: { $0.id == row.id }) {
            rows[existing] = row
            messages[threadID] = rows
        } else {
            messages[threadID, default: []].append(row)
        }
        if doc.threads[index].parentThreadID != nil {
            if let subStatus { doc.threads[index].subStatus = subStatus }
            doc.threads[index].lastOutputAt = Date()
        }
        touch(threadID)
        persist()
    }
}

// MARK: - W180 E3：從 Codex／Claude Code 匯入（只放有上限的最近內容；原檔只讀，不碰引擎家目錄，不走「一般」專案）

extension ChatLiveEngine {
    /// 同一段（同一家＋同一個 session id）已經匯入過的那條，含封存的。
    func importedThreadID(engine: String, sessionID: String, path: String) -> UUID? {
        let key = CoderImport.dedupeKey(engine: engine, sessionID: sessionID, path: path)
        return doc.threads.first { $0.importedFrom?.dedupeKey == key }?.id
    }

    /// 再匯入同一段＝打開已匯入那條；封存了就還原（不動它的內容）。
    func reopenImportedThread(_ id: UUID) {
        if unarchiveImported(id) { persist() }
    }

    private func unarchiveImported(_ id: UUID) -> Bool {
        guard let index = doc.threads.firstIndex(where: { $0.id == id }), doc.threads[index].isArchived else { return false }
        doc.threads[index].isArchived = false
        return true
    }

    /// 匯入一段（見 importCLISessions）。
    @discardableResult
    func importCLISession(_ digest: CoderImport.Digest, source: CoderImportSource, viewOnlyHint: String? = nil,
                          home: String = NSHomeDirectory()) -> UUID {
        importCLISessions([(digest: digest, source: source)], viewOnlyHint: viewOnlyHint, home: home)[0]
    }

    /// 匯入一批：全部串加進文件後只存一次檔（§8.11：一批 30 段不在主執行緒把整份文件重寫 30 次）。
    /// 已匯入過的就打開舊的那條（施工單 Q7）。回傳的 id 跟 items 一一對應。
    @discardableResult
    func importCLISessions(_ items: [(digest: CoderImport.Digest, source: CoderImportSource)], viewOnlyHint: String? = nil,
                           home: String = NSHomeDirectory()) -> [UUID] {
        var ids: [UUID] = [], changed = false
        for item in items {
            if let id = importedThreadID(engine: item.source.engine, sessionID: item.source.sessionID, path: item.source.path) {
                changed = unarchiveImported(id) || changed
                ids.append(id)
            } else {
                ids.append(insertImportedThread(item.digest, source: item.source, viewOnlyHint: viewOnlyHint, home: home))
                changed = true
            }
        }
        if changed { persist() }
        return ids
    }

    /// 建一條匯入的串（不存檔）。updatedAt 用原檔修改時間，私訊框與側欄的「最近」不會被洗掉。
    private func insertImportedThread(_ digest: CoderImport.Digest, source: CoderImportSource, viewOnlyHint: String?, home: String) -> UUID {
        let excluded = Set([doc.generalProjectID, doc.assistantProjectID].compactMap { $0 })
        let projects = doc.projects.map { CoderImport.ProjectInfo(id: $0.id, name: $0.name, workdir: $0.workdir) }
        let projectID: UUID
        switch CoderImport.projectMapping(cwd: source.cwd, projects: projects, home: home, excluding: excluded) {
        case .existing(let id): projectID = id
        case .create(let name, let workdir):
            let project = LiveProjectRecord(name: name, workdir: workdir)
            doc.projects.append(project)
            projectID = project.id
        }
        let start = digest.rows.first?.timestamp ?? source.sourceModifiedAt
        var rows = [ChatMessage(role: .system, text: CoderImport.bannerText(source, viewOnlyHint: viewOnlyHint),
                                status: CoderImport.bannerStatus, createdAt: start)]
        for row in digest.rows {
            let time = row.timestamp ?? source.sourceModifiedAt
            switch row.kind {
            case .user: rows.append(ChatMessage(role: .user, text: row.text, createdAt: time))
            case .assistant: rows.append(ChatMessage(role: .assistant, text: row.text, createdAt: time))
            case .summary: rows.append(ChatMessage(role: .system, text: row.text, status: CoderImport.summaryStatus, createdAt: time))
            }
        }
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var thread = LiveThreadRecord(projectID: projectID, title: title.isEmpty ? "匯入的對話" : String(title.prefix(120)),
                                      messages: rows.map(LiveMessageRecord.init), createdAt: start,
                                      updatedAt: source.sourceModifiedAt)
        thread.engine = source.engine
        thread.importedFrom = source
        doc.threads.insert(thread, at: 0)
        messages[thread.id] = rows
        return thread.id
    }

    /// 併回／拉到這台的是匯入串（第一則是匯入串頂）：專案名沒有對到時不落「一般」＝「聊天」（Q4、09-26 裁決）。
    /// 「家目錄」或沒名字 → 這台的「家目錄」專案；其他名字有同名專案就放那裡，沒有就新建同名專案、先放這台的家目錄並在串頂說明。
    /// 串頂只跟原本那台有關的行（只能看、那台的資料夾不在）拿掉。不是匯入串、或帶檔案時回 nil，照原本的 transferProject。
    func importTransferredImportedThread(projectName: String?, title: String, messages transferred: [RemoteThreadTransferMessage],
                                         files: [RemoteThreadTransferFile], home: String = NSHomeDirectory()) -> UUID? {
        guard files.isEmpty, let first = transferred.first, first.role == "system",
              CoderImport.bannerEngineLabel(first.text) != nil else { return nil }
        let name = projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let excluded = Set([doc.generalProjectID, doc.assistantProjectID].compactMap { $0 })
        let candidates = doc.projects.filter { !excluded.contains($0.id) && $0.name != "一般" }
        var created: String?
        let projectID: UUID
        if name.isEmpty || name == CoderImport.homeProjectName {
            let infos = candidates.map { CoderImport.ProjectInfo(id: $0.id, name: $0.name, workdir: $0.workdir) }
            switch CoderImport.projectMapping(cwd: home, projects: infos, home: home, excluding: []) {
            case .existing(let id): projectID = id
            case .create(let homeName, let workdir):
                let project = LiveProjectRecord(name: homeName, workdir: workdir)
                doc.projects.append(project)
                projectID = project.id
            }
        } else if let match = candidates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            projectID = match.id
        } else {
            let project = LiveProjectRecord(name: name, workdir: CoderImport.normalized(home))
            doc.projects.append(project)
            projectID = project.id
            created = name
        }
        var rows = transferred.map(\.chatMessage)
        rows[0] = ChatMessage(role: .system, text: CoderImport.transferredBanner(first.text, createdProject: created),
                              status: CoderImport.bannerStatus, createdAt: first.createdAt)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = LiveThreadRecord(projectID: projectID, title: trimmed.isEmpty ? "新聊天" : String(title.prefix(120)),
                                      messages: rows.map(LiveMessageRecord.init))
        doc.threads.insert(thread, at: 0)
        messages[thread.id] = rows
        doc.selectedThreadID = thread.id
        persist()
        return thread.id
    }

    /// 這台已經用引擎送出這條（停用的引擎在 send 前面就擋了）：串頂「這台的引擎已停用」那行過時了，拿掉。
    func dropViewOnlyHint(_ threadID: UUID) {
        guard var rows = messages[threadID], let first = rows.first, first.role == .system,
              first.status == CoderImport.bannerStatus, let text = CoderImport.withoutViewOnlyHint(first.text) else { return }
        rows[0].text = text
        messages[threadID] = rows
    }

    /// 匯入的串原本的資料夾不在了：sidecar 起不來，送出停用並說明（施工單 Q4）。
    func importedSendBlockReason(_ threadID: UUID) -> String? {
        guard let thread = threadRecord(threadID), thread.importedFrom != nil, thread.deviceID == nil else { return nil }
        let workdir = thread.cwdOverride ?? projectRecord(thread.projectID)?.workdir ?? NSHomeDirectory()
        var isDirectory: ObjCBool = false
        guard !FileManager.default.fileExists(atPath: workdir, isDirectory: &isDirectory) || !isDirectory.boolValue else { return nil }
        return "這條匯入的串原本的資料夾已不在（\((workdir as NSString).abbreviatingWithTildeInPath)），送出已停用。"
            + "要接著做：把資料夾放回原處，或在別的專案開新聊天、貼上需要的內容。"
    }

    /// 匯入的串第一次用某家引擎接著做：開新的引擎對話、第一句帶最近內容（包成資料不是指令，施工單 Q3、Q6）。
    /// 只限匯入的串；併回／拉到之後 importedFrom 不在，靠串頂那一行認。
    func importedSeed(threadID: UUID, engine: ClaudeSidecar.Kind, userText: String, currentTurn: String) -> String? {
        dropViewOnlyHint(threadID)
        guard let thread = threadRecord(threadID), thread.parentThreadID == nil,
              thread.sessionIDs[engine.rawValue] == nil, !(engine == .claude && thread.sessionID != nil) else { return nil }
        let rows = messages[threadID] ?? []
        let bannerLabel = rows.first.flatMap { $0.role == .system ? CoderImport.bannerEngineLabel($0.text) : nil }
        guard thread.importedFrom != nil || bannerLabel != nil else { return nil }
        let seedRows = rows.compactMap { row -> CoderImport.SeedRow? in
            guard row.turnID != currentTurn || row.role != .user else { return nil }
            if row.role == .system { return row.status == CoderImport.summaryStatus ? .init(kind: .summary, text: row.text) : nil }
            guard row.eventKind == .message else { return nil }
            return .init(kind: row.role == .user ? .user : .assistant, text: row.text)
        }
        guard !seedRows.isEmpty else { return nil }
        let label = thread.importedFrom.map { CoderImport.engineLabel($0.engine) } ?? bannerLabel
        return CoderImport.seedPrompt(rows: seedRows, sourceLabel: label, userText: userText)
    }
}

// MARK: - W180 E3b：搬移討論串到別的專案（只改歸屬，不建立、不搬、不改任何資料夾；子討論串一起搬）

extension ChatLiveEngine {
    /// 把一條主討論串連同底下所有子討論串改屬 `projectID`。只改 projectID：不動資料夾、不改更新時間、不停引擎。
    /// 回傳實際改到的每一條與它原本的專案；沒改到任何一條＝空陣列、文件不變。
    @discardableResult
    func moveThread(_ threadID: UUID, toProject projectID: UUID) throws -> [ProjectMoveEntry] {
        try moveThreads([(threadID, projectID)], creating: [])
    }

    /// 一次搬好幾條（一次存檔）。`newProjects` 是這次要新增的專案紀錄（沒有建資料夾）；沒搬到任何一條就都不加。
    /// 助理的對話、搬進助理專案一律不做。
    func moveThreads(_ moves: [(thread: UUID, project: UUID)], creating newProjects: [LiveProjectRecord]) throws -> [ProjectMoveEntry] {
        var candidate = doc
        for project in newProjects where !candidate.projects.contains(where: { $0.id == project.id }) {
            candidate.projects.append(project)
        }
        var moved: [ProjectMoveEntry] = []
        for (threadID, projectID) in moves {
            guard projectID != candidate.assistantProjectID, candidate.projects.contains(where: { $0.id == projectID }),
                  candidate.threads.contains(where: { $0.id == threadID }), !candidate.isAssistantThread(threadID) else { continue }
            let family = ProjectClassification.subtree(of: threadID, in: candidate.threads)
            for index in candidate.threads.indices
            where family.contains(candidate.threads[index].id) && candidate.threads[index].projectID != projectID {
                moved.append(ProjectMoveEntry(threadID: candidate.threads[index].id,
                                              from: candidate.threads[index].projectID, to: projectID))
                candidate.threads[index].projectID = projectID
            }
        }
        guard !moved.isEmpty else { return [] }
        try commitMoved(candidate)
        return moved
    }

    /// 復原：還在新專案的那幾條改回原專案（之後又被搬走、或原專案已不在的不動）。
    /// 核准後才在它們底下開的子討論串、房間（還在同一個新專案的）跟著最近的那條一起回去，回傳在 `later`（呼叫端補進紀錄）。
    /// `projectIDs` 裡變空的專案（連封存的對話都沒有）從清單拿掉並回傳（呼叫端留在搬移紀錄裡＝封存，不刪）。
    func restoreThreadProjects(_ entries: [ProjectMoveEntry], archivingEmpty projectIDs: [UUID]) throws
        -> (restored: Int, later: [ProjectMoveEntry], archived: [LiveProjectRecord]) {
        var candidate = doc
        var restored = 0
        var restoredIDs = Set<UUID>()
        for entry in entries {
            guard let index = candidate.threads.firstIndex(where: { $0.id == entry.threadID }),
                  candidate.threads[index].projectID == entry.to,
                  let from = entry.from, candidate.projects.contains(where: { $0.id == from }) else { continue }
            candidate.threads[index].projectID = from
            restored += 1
            restoredIDs.insert(entry.threadID)
        }
        // 紀錄裡沒有的子孫：往上找最近一條在紀錄裡的祖先；那條搬回了、自己也還在它的新專案，就跟著回同一個專案。
        let recorded = Dictionary(entries.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = Dictionary(candidate.threads.map { ($0.id, $0.parentThreadID) }, uniquingKeysWith: { first, _ in first })
        var later: [ProjectMoveEntry] = []
        for index in candidate.threads.indices where recorded[candidate.threads[index].id] == nil {
            var cursor = candidate.threads[index].parentThreadID
            var visited = Set<UUID>()
            while let current = cursor, recorded[current] == nil, visited.insert(current).inserted { cursor = parents[current] ?? nil }
            guard let ancestor = cursor, restoredIDs.contains(ancestor), let entry = recorded[ancestor], let from = entry.from,
                  candidate.threads[index].projectID == entry.to else { continue }
            candidate.threads[index].projectID = from
            later.append(ProjectMoveEntry(threadID: candidate.threads[index].id, from: from, to: entry.to))
        }
        var archived: [LiveProjectRecord] = []
        for id in projectIDs where id != candidate.assistantProjectID && id != candidate.generalProjectID
            && !candidate.threads.contains(where: { $0.projectID == id }) {
            if let index = candidate.projects.firstIndex(where: { $0.id == id }) { archived.append(candidate.projects.remove(at: index)) }
        }
        guard restored > 0 || !archived.isEmpty else { return (0, [], []) }
        try commitMoved(candidate)
        let inactiveFolders = archived.map { URL(fileURLWithPath: $0.workdir) }.filter { folder in
            !candidate.projects.contains { URL(fileURLWithPath: $0.workdir).standardizedFileURL.path == folder.standardizedFileURL.path }
        }
        tapMapper.setArchived(inactiveFolders, archived: true)
        return (restored + later.count, later, archived)
    }

    /// 存檔成功才換上新文件（同 addIssueChecked）；存不進去就什麼都沒變。
    private func commitMoved(_ next: LiveDocumentRecord) throws {
        var candidate = next
        for index in candidate.threads.indices {
            candidate.threads[index].messages = (messages[candidate.threads[index].id] ?? []).map(LiveMessageRecord.init)
        }
        try store.saveChecked(candidate)
        doc = candidate
        onChange?()
    }
}
