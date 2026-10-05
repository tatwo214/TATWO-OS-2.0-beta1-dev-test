import Foundation

/// W184 H4 修正第四輪：RemoteLiveEngine 每一次呼叫主設備走的那一條。正式版就是 RemoteHostLink 本身；
/// 自測（DEBUG）可以換成主設備真的 OSAgentBridge。接縫放在這裡，不放進 RemoteHostLink（W91c 信任清單上的檔要跟 beta1/integration 零 diff）。
protocol RemoteLiveCalling: AnyObject, Sendable {
    func call(method: String, params: [String: Any]) throws -> [String: Any]
}

extension RemoteHostLink: RemoteLiveCalling {}

/// R2 遙控資料源：畫面仍吃 LiveEngineAPI，底下改走主機 os.sock。
@MainActor
final class RemoteLiveEngine: LiveEngineAPI {
    let store: ChatLiveStore
    private(set) var doc = LiveDocumentRecord()
    var onChange: (() -> Void)?
    var permissionDecider: ((_ tool: String, _ inputPretty: String) -> Bool)?
    var autoApprove = false
    var onHint: ((String) -> Void)?
    var onRoomArchived: ((UUID) -> Void)?
    var onConnectionStateChange: ((Result<Int64, Error>) -> Void)?
    /// W182 R4：讀到一條的逐則內容時交給離線副本（背景存檔；只給畫面用，不開工具）。
    var onTranscriptFetched: ((UUID, [LiveMessageRecord]) -> Void)?
    var dispatchPaused = false

    private let link: RemoteHostLink
    /// 實際打出去的那一條：正式版＝link；只有 DEBUG 自測的建構子會換成別的（見 init(link:callingThrough:store:initial:)）。
    private let caller: any RemoteLiveCalling
    /// W100：這個型別所有 `link.call` 一律丟到這條序列佇列，主執行緒（SwiftUI getter、按鈕）永遠不等 SSH。
    private let callQueue = DispatchQueue(
        label: "ai.tatwo.tatwo2.remote-live", qos: .userInitiated)
    private var revision: Int64 = -1
    private var transcriptCache: [UUID: [ChatMessage]] = [:]
    /// 正在背景刷新的討論串；同一條不重複發。
    private var transcriptLoading: Set<UUID> = []
    /// 失敗後的冷卻，避免 SwiftUI 每次重繪都重試造成請求風暴。
    private var transcriptRetryAfter: [UUID: Date] = [:]
    /// 同一種錯誤 30 秒內只提示一次。
    private var lastHintAt: [String: Date] = [:]
    private var runningThreadIDs: Set<UUID> = []
    private var hasAuthoritativeRunningList = false
    /// W184 H4 修正（審查 #9）：那台（主設備）自己送不出的引擎（get_document 附的）；舊版主設備沒附＝nil（不知道，不擋）。
    private(set) var hostBlockedEngines: Set<String>?
    private(set) var engineModelCatalogs: [EngineModelCatalog.Catalog] = []
    private var pollTask: Task<Void, Never>?
    private(set) var currentRevision: Int64 = -1

    /// initial＝連線時在背景先拉好的第一份文件（不在主執行緒做網路）。沒有就等第一次輪詢。
    convenience init(link: RemoteHostLink, store: ChatLiveStore, initial: [String: Any]? = nil) throws {
        try self.init(link: link, caller: link, store: store, initial: initial)
    }

    #if DEBUG
    /// 自測：連線物件照樣是 link（shutdownAll 照樣斷它），但送出、刷新、輪詢每一次呼叫都改走 caller（例如主設備真的
    /// OSAgentBridge），不開 SSH。只在 DEBUG；正式版只有上面那個建構子。
    convenience init(link: RemoteHostLink, callingThrough caller: any RemoteLiveCalling, store: ChatLiveStore,
                     initial: [String: Any]? = nil) throws {
        try self.init(link: link, caller: caller, store: store, initial: initial)
    }
    #endif

    private init(link: RemoteHostLink, caller: any RemoteLiveCalling, store: ChatLiveStore, initial: [String: Any]?) throws {
        self.link = link
        self.caller = caller
        self.store = store
        if let initial { try apply(result: initial, notify: false) }
        let link = self.caller
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let known = self?.revision, !Task.isCancelled else { return }
                // W100d（使用者 09-18 實機「OS 完全卡死」，sample 抓到主執行緒在 JSONSerialization／JSONDecoder）：
                // 網路「與解碼」都在背景執行緒；revision 沒變就連解碼都不做。主執行緒只做指派。
                let startedAt = Self.clock()   // W184 H4 修正第二輪（審查 #2）：這一次從什麼時候開始拉
                let outcome = await Task.detached(priority: .utility) { () -> Result<Fetched?, Error> in
                    Result {
                        let result = try link.call(method: "get_document", params: [:])
                        let fetchedRevision = (result["revision"] as? NSNumber)?.int64Value ?? 0
                        let running = Set((result["runningThreadIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
                        let authoritative = result["runningThreadIDs"] is [String]
                        let catalogs = EngineModelCatalog.decode(result["engineModelCatalogs"])
                        let blocked = (result["blockedEngines"] as? [String]).map(Set.init)   // W184 H4 修正（審查 #9）
                        if fetchedRevision == known, known >= 0 {
                            return Fetched(document: nil, revision: fetchedRevision, running: running, blocked: blocked,
                                           catalogs: catalogs, startedAt: startedAt, runningIsAuthoritative: authoritative)
                        }
                        let decoded: LiveDocumentRecord = try Self.decode(result["document"])
                        return Fetched(document: decoded, revision: fetchedRevision, running: running, blocked: blocked,
                                       catalogs: catalogs, startedAt: startedAt, runningIsAuthoritative: authoritative)
                    }
                }.value
                guard let self, !Task.isCancelled else { return }
                switch outcome {
                case .success(let fetched):
                    if let fetched { self.applyFetched(fetched) }
                case .failure(let error):
                    // W201：輪詢斷線交給 session 自動重連；使用者動作送不到仍保留各自的失敗說明。
                    self.onConnectionStateChange?(.failure(error))
                    return
                }
            }
        }
    }

    var document: TatwoNativeChatStoreDocument {
        TatwoNativeChatStoreDocument(projects: doc.projects.map { project in
            TatwoNativeChatProject(
                id: project.id,
                name: project.name,
                workdir: project.workdir,
                isExpanded: project.isExpanded,
                threads: doc.threads
                    .filter { $0.projectID == project.id && !$0.isArchived }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map { thread in
                        TatwoNativeChatThread(
                            id: thread.id,
                            title: thread.title,
                            isPinned: thread.isPinned,
                            lastPreview: thread.messages.last(where: { $0.eventKind == "message" && !$0.isMemoryUsageRow })?.text ?? "",   // W180 E1
                            parentThreadID: thread.parentThreadID,
                            liveness: ThreadLiveness.forThread(   // W183 R1：手腳房間不看時間
                                engine: thread.engine,
                                status: thread.subStatus,
                                lastOutputAt: thread.lastOutputAt),
                            lastOutputAt: thread.lastOutputAt,
                            engineLabel: thread.engine)
                    },
                githubRepos: project.githubRepos.map { TatwoGitHubRepoBinding(url: $0) })
        }, assistantProjectID: doc.assistantProjectID)
    }

    /// W100：View 的 getter 只讀快取。沒有快取就回空＋標成載入中，並排一次背景刷新。
    /// `apply(result:notify:)` 換版時會清快取，所以下一次讀取自然會重拉。
    func transcript(for threadID: UUID?) -> [ChatMessage] {
        guard let threadID else { return [] }
        if let cached = transcriptCache[threadID] { return cached }
        refreshTranscript(threadID)
        return []
    }

    /// 首次進遠端模式還沒有快取時，對話區靠這個顯示「連線中…」。
    func isTranscriptLoading(_ threadID: UUID?) -> Bool {
        guard let threadID else { return false }
        return transcriptLoading.contains(threadID)
    }

    func isRunning(_ threadID: UUID?) -> Bool {
        guard let thread = threadRecord(threadID) else { return false }
        if hasAuthoritativeRunningList { return runningThreadIDs.contains(thread.id) }
        if runningThreadIDs.contains(thread.id) { return true }
        if thread.subStatus == "running" { return true }
        return thread.messages.last?.status?.hasPrefix("writing") == true
    }

    func activityDate(_ threadID: UUID) -> Date {
        threadRecord(threadID)?.updatedAt ?? .distantPast
    }

    func threadRecord(_ threadID: UUID?) -> LiveThreadRecord? {
        guard let threadID else { return nil }
        return doc.threads.first { $0.id == threadID }
    }

    func projectRecord(_ projectID: UUID?) -> LiveProjectRecord? {
        guard let projectID else { return nil }
        return doc.projects.first { $0.id == projectID }
    }

    var archivedThreadCount: Int {
        doc.threads.filter(\.isArchived).count
    }

    func appendSystemMessage(threadID: UUID, text: String, status: String) {
        unsupported("新增系統訊息")
    }

    func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine) {
        unsupported("修改 MCP")
    }

    /// 協定要求同步回傳，但遠端建立討論串一定要走背景（不能在主執行緒等 SSH）。
    /// 需要拿到主機給的新 ID 的呼叫端請改用下面的 completion 版本。
    func newThread(in projectID: UUID?, title: String) -> UUID {
        newThread(in: projectID, title: title, completion: { _ in })
        return doc.selectedThreadID ?? UUID()
    }

    /// W100：背景建立遠端討論串，文件刷新完成後才把主機給的 ID 交回主執行緒。
    func newThread(
        in projectID: UUID?,
        title: String,
        completion: @escaping @MainActor (UUID?) -> Void
    ) {
        var params: [String: Any] = ["title": title]
        if let projectID { params["projectID"] = projectID.uuidString }
        perform({ try $0.call(method: "new_thread", params: params) }) { [weak self] outcome in
            guard let self else { return completion(nil) }
            guard
                case .success(let result) = outcome,
                let raw = result["threadID"] as? String,
                let threadID = UUID(uuidString: raw)
            else {
                self.hintOnce("new_thread", "遙控建立討論串失敗：\(Self.describe(outcome))")
                return completion(nil)
            }
            self.refreshDocument(notify: true) { completion(threadID) }
        }
    }

    func newProject(name: String, workdir: String) -> UUID {
        unsupported("新增專案")
        return doc.projects.first?.id ?? UUID()
    }

    func select(_ threadID: UUID) {
        doc.selectedThreadID = threadID
    }

    func setExpanded(_ projectID: UUID, _ expanded: Bool) {
        if let index = doc.projects.firstIndex(where: { $0.id == projectID }) {
            doc.projects[index].isExpanded = expanded
            onChange?()
        }
    }

    func togglePinned(_ threadID: UUID) {
        unsupported("釘選討論串")
    }

    func rename(_ threadID: UUID, _ title: String) {
        unsupported("重新命名")
    }

    func archive(_ threadID: UUID) -> UUID? {
        unsupported("封存討論串")
        return doc.selectedThreadID
    }

    func restoreMostRecentArchivedThread() -> UUID? {
        unsupported("還原封存討論串")
        return nil
    }

    func duplicate(_ threadID: UUID, asBranch: Bool) -> UUID? {
        unsupported(asBranch ? "建立支線副本" : "複製討論串")
        return nil
    }

    func createDiscussion(parentThreadID: UUID) -> UUID? {
        unsupported("建立支線")
        return nil
    }

    func compressDiscussion(_ discussionID: UUID) -> UUID? {
        unsupported("壓縮支線")
        return nil
    }

    func mergeDiscussionIntoParent(_ discussionID: UUID) -> UUID? {
        unsupported("合併支線")
        return nil
    }

    func setGitHubRepos(_ repos: [String], for projectID: UUID) {
        unsupported("修改 GitHub 綁定")
    }

    func issues(threadID: UUID?, global: Bool) -> [TatwoIssueListEntryV1] {
        if global {
            return doc.threads.flatMap(\.issues).sorted { $0.createdAt > $1.createdAt }
        }
        guard let threadID, let thread = doc.threads.first(where: { $0.id == threadID }) else {
            return []
        }
        return thread.issues.sorted { $0.createdAt > $1.createdAt }
    }

    func addIssue(threadID: UUID, title: String, body: String) { unsupported("issue") }
    func captureIssue(threadID: UUID) {
        unsupported("新增 issue")
    }

    func updateIssue(_ id: String, _ body: (inout TatwoIssueListEntryV1) -> Void) {
        unsupported("修改 issue")
    }

    func removeIssue(_ id: String) {
        unsupported("移除 issue")
    }

    func gitSummary(
        for threadID: UUID?,
        completion: @escaping (ChatLiveEngine.GitSummary) -> Void
    ) {
        unsupported("讀取遠端 Git 狀態")
        completion(ChatLiveEngine.GitSummary())
    }

    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind,
        systemPrompt: String?,
        attachments: [String],
        reasoningEffort: String?,
        serviceTier: String?
    ) -> Bool {
        send(threadID: threadID, text: text, model: model, engine: engine, systemPrompt: systemPrompt, attachments: attachments,
             reasoningEffort: reasoningEffort, serviceTier: serviceTier, ultrawork: nil, delivery: nil)
    }

    #if DEBUG
    /// W184 H4 修正（審查 #10）：自測抓「真的要送去主設備的那一包」（方法＋參數；在交給連線之前）。只在 DEBUG。
    var sendPayloadTestTap: ((String, [String: Any]) -> Void)?
    /// 自測：照常刷新一次文件（同送出成功後那一次；完成含失敗才回）。W184 H4 修正第二輪（GPT-6 H4b 審查 #2、#7、#10）：
    /// 自測把呼叫交給主設備真的 OSAgentBridge（init(link:callingThrough:store:initial:)），不開 SSH。
    func refreshForSelfTest() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            refreshDocument(notify: true) { done.resume() }
        }
    }
    #endif

    /// W184 H4 修正第二輪（審查 #7）：正在送到那台、還沒回覆的那幾條——Coder 與私訊框共用這一把（同一台的遠端引擎只有一個），
    /// 同一條不會兩個入口同時送：後到的那句當場退回（草稿留著），不必等那台拒收。
    private(set) var sendingThreadIDs: Set<UUID> = []
    func isSending(_ threadID: UUID) -> Bool { sendingThreadIDs.contains(threadID) }
    nonisolated static let sendingCode = "thread_sending"

    /// W184 H4 修正第二輪（審查 #2）：文件刷新從什麼時候開始拉的（系統開機後秒數；比「那台回覆收下」晚才算數）。
    nonisolated static func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 那台的回覆怎麼交給呼叫端：收下＝送到；那台回了錯（拒收：這條正在忙、參數不對、停用的引擎）＝沒送到；連線在途中斷＝不確定。
    static func delivery(for error: Error) -> LiveSendDelivery {
        guard case RemoteHostLinkError.remoteError(let code) = error else {
            return .unknown("連線在途中斷（\(error.localizedDescription)）")
        }
        return .notDelivered(RemoteSendRejection.reason(for: code) ?? "那台沒收下（\(code)）")
    }

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
    ) -> Bool {
        // W184 H4 修正第二輪（審查 #7）：同一條已經有一句在路上（私訊框或 Coder 送的）：這句當場退回，草稿留著。
        guard !sendingThreadIDs.contains(threadID) else {
            onHint?("這條正在把上一句送到那台；這句先留在輸入框，等一下再送")
            return false
        }
        if !attachments.isEmpty {
            onHint?("遠端討論串不支援附件；已只送出文字")
        }
        var params: [String: Any] = [
            "threadID": threadID.uuidString,
            "engine": engine.rawValue,
            "text": text,
        ]
        params["model"] = Self.remoteProviderModel(model, engine: engine, thread: threadRecord(threadID))
        if let reasoningEffort { params["reasoningEffort"] = reasoningEffort }
        if let serviceTier { params["serviceTier"] = serviceTier }
        // W180 E1：這台選過的記憶強度跟這句一起帶過去（不影響用哪個方法；舊主設備不認得就忽略、照常送出）。
        let memoryStrength = TatwoMemoryStrengthPending.shared.value(for: threadID)
        if let memoryStrength { params["memoryStrength"] = memoryStrength.rawValue }
        // W184 H4 修正（審查 #2）：這一輪的 ultrawork（檔位、主導、每一個副手；卡上的值）序列化帶過去——主設備收下就記在那條、
        // 接在那一句後面（不再是收到 systemPrompt 卻沒送）。舊版主設備不認得這個欄位＝照舊忽略、照常送出；不改用哪個方法。
        // W184 H4 修正第二輪（審查 #2）：這台改了還沒送到的那一份帶著它的世代；那台收下時只確認這一份（送的途中又改過就留著新的）。
        let outgoing = TatwoUltraworkPending.shared.outgoing(for: threadID)
        let sentUltrawork = ultrawork ?? outgoing?.settings
        if let sentUltrawork { params["ultrawork"] = sentUltrawork.wireObject }
        let sentGeneration = outgoing.flatMap { ultrawork == nil || ultrawork == $0.settings ? $0.generation : nil }
        // A pre-upgrade host must reject rather than silently ignore new
        // turn controls. One call, same transport; no extra polling.
        let method = reasoningEffort != nil || serviceTier != nil ? "send_message_with_options" : "send_message"
        // W100：送出是使用者動作，但一樣不能在主執行緒等 SSH。背景送出、完成回呼再刷新。
        let sent = params
        #if DEBUG
        sendPayloadTestTap?(method, sent)
        #endif
        sendingThreadIDs.insert(threadID)
        perform({ try $0.call(method: method, params: sent) }) { [weak self] outcome in
            guard let self else { return }
            self.sendingThreadIDs.remove(threadID)
            switch outcome {
            case .success:
                TatwoMemoryStrengthPending.shared.delivered(threadID, memoryStrength)   // W180 E1
                // W184 H4 修正第二輪（審查 #2）：先記「那台收下了這一份」（畫面照它，不等下一次刷新成功），再刷新。
                if let sentGeneration {
                    TatwoUltraworkPending.shared.delivered(threadID, generation: sentGeneration, at: Self.clock())
                }
                self.transcriptCache[threadID] = nil
                self.transcriptRetryAfter[threadID] = nil
                delivery?(.delivered)
                self.refreshDocument(notify: true)
            case .failure(let error):
                if let delivery { delivery(Self.delivery(for: error)) }
                else { self.hintOnce("send", ChatPageModel.undeliveredMessage(Self.delivery(for: error)) ?? "遙控送出失敗") }
                if case RemoteHostLinkError.remoteError = error {
                    self.transcriptCache[threadID] = nil
                    self.transcriptRetryAfter[threadID] = nil
                    self.refreshDocument(notify: true)
                }
            }
        }
        return true
    }

    /// W179 F：助理與私訊框送到主設備那條。跟 `send` 不同：等主設備回覆收到（並把文件刷新好）才回報成功，
    /// 失敗把原因交回呼叫端（留著草稿、在助理／私訊框顯示一行說明），不走 onHint。只送文字。
    func deliver(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind?, assistantRoute: String?,
                 completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        // W184 H4 修正第二輪（審查 #7）：同一條已經有一句在路上（Coder 或私訊框送的）：當場退回（私訊框留著草稿、顯示一行說明）。
        guard !sendingThreadIDs.contains(threadID) else {
            return completion(.failure(RemoteHostLinkError.remoteError(Self.sendingCode)))
        }
        // W180 E1：這台選過的記憶強度跟這句一起帶過去；主設備收下就記在那條（舊主設備忽略、照常送出）。
        let memoryStrength = TatwoMemoryStrengthPending.shared.value(for: threadID)
        // W184 H4 修正（審查 #2、#3）：私訊框的別台 session 在這台改了、還沒送到的 ultrawork 也跟這句一起帶過去（沒改＝那台照那條記住的）。
        // W184 H4 修正第二輪（審查 #2）：帶著它的世代，那台收下時只確認這一份。
        let outgoing = TatwoUltraworkPending.shared.outgoing(for: threadID)
        let route = ChatModelPreferences.selection(threadRecord(threadID)).route
        let kind = engine ?? AssistantModelRouting.engineKind(for: route) ?? .codex
        let providerModel = Self.remoteProviderModel(model, engine: kind, thread: threadRecord(threadID))
        let sent = Self.deliverParams(threadID: threadID, text: text, model: providerModel, engine: kind,
                                      ultrawork: outgoing?.settings.wireObject,
                                      assistantRoute: assistantRoute, memoryStrength: memoryStrength?.rawValue)
        #if DEBUG
        sendPayloadTestTap?("send_message", sent)
        #endif
        sendingThreadIDs.insert(threadID)
        perform({ try $0.call(method: "send_message", params: sent) }) { [weak self] outcome in
            guard let self else { return completion(.failure(RemoteHostLinkError.invalidResponse)) }
            self.sendingThreadIDs.remove(threadID)
            switch outcome {
            case .success:
                TatwoMemoryStrengthPending.shared.delivered(threadID, memoryStrength)   // W180 E1
                if let outgoing {   // W184 H4 修正第二輪（審查 #2）：先記那台收下了這一份，再刷新（刷新失敗也不退回舊的）
                    TatwoUltraworkPending.shared.delivered(threadID, generation: outgoing.generation, at: Self.clock())
                }
                self.transcriptCache[threadID] = nil
                self.transcriptRetryAfter[threadID] = nil
                self.refreshDocument(notify: true) { completion(.success(())) }
            case .failure(let error):
                // 主設備有回話（拒收）時也刷新一次：拒收原因若寫進了對話（例如還沒登入），馬上看得到。
                guard case RemoteHostLinkError.remoteError = error else { return completion(.failure(error)) }
                self.transcriptCache[threadID] = nil
                self.transcriptRetryAfter[threadID] = nil
                self.refreshDocument(notify: true) { completion(.failure(error)) }
            }
        }
    }

    nonisolated static func remoteProviderModel(_ model: String?, engine: ClaudeSidecar.Kind, thread: LiveThreadRecord?) -> String {
        if let model, !model.isEmpty { return model }
        let route = ChatModelPreferences.selection(thread).route
        if AssistantModelRouting.engineKind(for: route) == engine { return route.modelArgument ?? route.canonicalModelSlug }
        let fallback = TatwoChatRouteProfile.defaults.first { AssistantModelRouting.engineKind(for: ChatRouteChoice(profile: $0)) == engine }
        return fallback?.modelArgument ?? fallback?.canonicalModelSlug ?? "gpt-6.1-sol"
    }

    /// `deliver` 的 send_message 參數。engine：模型參數是 nil 時讓主設備知道是哪一家（例 Claude 路由沒有
    /// claude- 開頭的參數）；assistantRoute：送給主設備助理那條時，這次在選單明確選的路由 id（主設備照自己的
    /// 助理規則送、跳過它停用的引擎）。舊版主設備不認得這兩個欄位，會照舊用模型名或那條上次的引擎。
    /// W180 E1：memoryStrength＝這台在 chip 選過、還沒送到的記憶強度（off/light/medium/deep）；沒選就不帶。
    /// W184 H4 修正：ultrawork＝這台改了、還沒送到的那條 ultrawork（UltraworkTurnSettings.wireObject）；沒改就不帶。
    nonisolated static func deliverParams(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind?,
                                          ultrawork: [String: Any]? = nil,
                                          assistantRoute: String?, memoryStrength: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["threadID": threadID.uuidString, "text": text]
        if let model { params["model"] = model }
        if let engine { params["engine"] = engine.rawValue }
        if let ultrawork { params["ultrawork"] = ultrawork }
        if let assistantRoute { params["assistantRoute"] = assistantRoute }
        if let memoryStrength { params["memoryStrength"] = memoryStrength }
        return params
    }

    func stop(threadID: UUID) {
        let params: [String: Any] = ["threadID": threadID.uuidString]
        perform({ try $0.call(method: "stop_thread", params: params) }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success: self.refreshDocument(notify: true)
            case .failure(let error):
                self.hintOnce("stop", "遙控停止失敗：\(error.localizedDescription)")
            }
        }
    }

    /// W100：搬移也是網路動作，改成背景執行＋完成回呼（編碼在主執行緒做，只有 RPC 進背景）。
    func pushThread(
        projectName: String?,
        title: String,
        messages: [RemoteThreadTransferMessage],
        files: [RemoteThreadTransferFile],
        completion: @escaping @MainActor (Result<UUID, Error>) -> Void
    ) {
        var params: [String: Any] = ["title": title]
        do {
            params["messages"] = try Self.jsonObject(messages)
            params["files"] = try Self.jsonObject(files)
        } catch {
            return completion(.failure(error))
        }
        if let projectName { params["projectName"] = projectName }
        let sent = params
        perform({ try $0.call(method: "push_thread", params: sent) }) { [weak self] outcome in
            guard let self else { return completion(.failure(RemoteHostLinkError.invalidResponse)) }
            switch outcome {
            case .failure(let error): completion(.failure(error))
            case .success(let result):
                guard
                    let rawThreadID = result["threadID"] as? String,
                    let threadID = UUID(uuidString: rawThreadID)
                else { return completion(.failure(RemoteHostLinkError.invalidResponse)) }
                self.refreshDocument(notify: true) { completion(.success(threadID)) }
            }
        }
    }

    typealias PulledThread = (
        projectName: String?,
        title: String,
        messages: [RemoteThreadTransferMessage],
        files: [RemoteThreadTransferFile]
    )

    func pullThread(
        threadID: UUID,
        completion: @escaping @MainActor (Result<PulledThread, Error>) -> Void
    ) {
        let params: [String: Any] = ["threadID": threadID.uuidString]
        perform({ try $0.call(method: "pull_thread", params: params) }) { [weak self] outcome in
            guard let self else { return completion(.failure(RemoteHostLinkError.invalidResponse)) }
            switch outcome {
            case .failure(let error): completion(.failure(error))
            case .success(let result):
                do {
                    guard let title = result["title"] as? String else {
                        throw RemoteHostLinkError.invalidResponse
                    }
                    let messages: [RemoteThreadTransferMessage] = try Self.decode(result["messages"])
                    let files: [RemoteThreadTransferFile] = try Self.decode(result["files"])
                    let pulled: PulledThread = (result["projectName"] as? String, title, messages, files)
                    self.refreshDocument(notify: true) { completion(.success(pulled)) }
                } catch { completion(.failure(error)) }
            }
        }
    }

    func shutdownAll() {
        pollTask?.cancel()
        pollTask = nil
        link.disconnect()
    }

    func configureRoom(
        threadID: UUID,
        parentThreadID: UUID,
        roomBrief: String,
        engine: String,
        cwdOverride: String,
        deviceID: String?
    ) {
        unsupported("設定派工房間")
    }

    func sidecarProcessID(threadID: UUID) -> Int32? {
        nil
    }

    private func unsupported(_ action: String) {
        onHint?("遠端討論串不支援 \(action)")
    }

    // MARK: - W100 背景呼叫

    /// 把一次 link 呼叫丟到背景佇列，完成後回主執行緒。呼叫端不會被 SSH 卡住。
    private func perform<T>(
        _ work: @escaping @Sendable (any RemoteLiveCalling) throws -> T,
        then completion: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        let link = self.caller
        callQueue.async {
            let outcome = Result { try work(link) }
            Task { @MainActor in completion(outcome) }
        }
    }

    /// 同一種錯誤 30 秒內只提示一次，避免重連時的提示風暴。
    private func hintOnce(_ key: String, _ message: String) {
        let now = Date()
        if let last = lastHintAt[key], now.timeIntervalSince(last) < 30 { return }
        lastHintAt[key] = now
        onHint?(message)
    }

    private static func describe<T>(_ outcome: Result<T, Error>) -> String {
        if case .failure(let error) = outcome { return error.localizedDescription }
        return "invalid_json_rpc_response"
    }

    /// 背景重拉一條逐字稿；同一條進行中不重複發，失敗後冷卻 3 秒才准再試。
    private func refreshTranscript(_ threadID: UUID) {
        guard !transcriptLoading.contains(threadID) else { return }
        if let after = transcriptRetryAfter[threadID], Date() < after { return }
        transcriptLoading.insert(threadID)
        let params: [String: Any] = ["threadID": threadID.uuidString]
        perform({ try $0.call(method: "transcript", params: params) }) { [weak self] outcome in
            guard let self else { return }
            self.transcriptLoading.remove(threadID)
            switch outcome {
            case .success(let result):
                do {
                    let records: [LiveMessageRecord] = try Self.decode(result["messages"])
                    self.transcriptRetryAfter[threadID] = nil
                    self.transcriptCache[threadID] = records.map(\.chatMessage)
                    self.onTranscriptFetched?(threadID, records)   // W182 R4
                    self.onChange?()
                } catch {
                    self.transcriptRetryAfter[threadID] = Date().addingTimeInterval(3)
                    self.hintOnce("transcript", "遙控對話讀不懂：\(error.localizedDescription)")
                }
            case .failure(let error):
                self.transcriptRetryAfter[threadID] = Date().addingTimeInterval(3)
                // W201：自動重拉的連線失敗不報備；需要那台的唯讀說明在該對話的輸入位置。
            }
        }
    }

    /// 背景重拉遠端文件；完成（含失敗）後才跑 completion。
    private func refreshDocument(notify: Bool, then completion: @escaping @MainActor () -> Void = {}) {
        let startedAt = Self.clock()   // W184 H4 修正第二輪（審查 #2）
        perform({ try $0.call(method: "get_document", params: [:]) }) { [weak self] outcome in
            guard let self else { return completion() }
            switch outcome {
            case .success(let result):
                do {
                    try self.apply(result: result, notify: notify)
                    self.reconcileUltrawork(fetchStartedAt: startedAt)
                }
                catch { self.hintOnce("document", "遙控資料讀不懂：\(error.localizedDescription)") }
            case .failure:
                // W201：文件自動刷新失敗不另出提示；原動作的送達結果仍交回呼叫端。
                break
            }
            completion()
        }
    }

    /// 輪詢間隔：2 秒會讓 8 GB 機器的主執行緒喘不過氣（每次都重繪整頁）；5 秒對「看到對方新訊息」夠用。
    nonisolated static let pollInterval: Double = 5
    /// 背景已解好的一輪結果；`document == nil` 代表 revision 沒變，只更新執行中清單。
    struct Fetched: @unchecked Sendable {  // 純資料 record，跨背景 Task 回主執行緒
        let document: LiveDocumentRecord?
        let revision: Int64
        let running: Set<UUID>
        let blocked: Set<String>?   // W184 H4 修正（審查 #9）
        var catalogs: [EngineModelCatalog.Catalog] = []
        var startedAt: TimeInterval = 0   // W184 H4 修正第二輪（審查 #2）：這一次從什麼時候開始拉
        var runningIsAuthoritative = true
    }
    private func applyFetched(_ fetched: Fetched) {
        let runningChanged = runningThreadIDs != fetched.running || hasAuthoritativeRunningList != fetched.runningIsAuthoritative
        let catalogsChanged = engineModelCatalogs != fetched.catalogs
        engineModelCatalogs = fetched.catalogs
        runningThreadIDs = fetched.running
        hasAuthoritativeRunningList = fetched.runningIsAuthoritative
        hostBlockedEngines = fetched.blocked   // W184 H4 修正（審查 #9）
        defer { reconcileUltrawork(fetchStartedAt: fetched.startedAt) }   // 文件沒變也算：那台的紀錄就是現在這份
        guard let document = fetched.document else {
            onConnectionStateChange?(.success(fetched.revision))
            if runningChanged { onChange?() } else if catalogsChanged { onChange?() }
            return
        }
        doc = document
        revision = fetched.revision
        currentRevision = fetched.revision
        onConnectionStateChange?(.success(fetched.revision))
        transcriptCache.removeAll(keepingCapacity: true)
        transcriptRetryAfter.removeAll(keepingCapacity: true)
        onChange?()
    }

    /// W184 H4 修正第二輪（審查 #2）：那台收下之後才開始拉的文件＝那台的紀錄已經含那一份（或之後別處改的）：已確認的那一份交還給文件。
    /// 還沒送到的（送的途中又改過的）不動。
    private func reconcileUltrawork(fetchStartedAt: TimeInterval) {
        guard fetchStartedAt > 0 else { return }
        TatwoUltraworkPending.shared.reconcile(threadIDs: Set(doc.threads.map(\.id)), fetchStartedAt: fetchStartedAt)
    }

    private func apply(result: [String: Any], notify: Bool) throws {
        let catalogs = EngineModelCatalog.decode(result["engineModelCatalogs"])
        let catalogsChanged = engineModelCatalogs != catalogs
        engineModelCatalogs = catalogs
        let fetched: LiveDocumentRecord = try Self.decode(result["document"])
        let fetchedRevision = (result["revision"] as? NSNumber)?.int64Value ?? 0
        hasAuthoritativeRunningList = result["runningThreadIDs"] is [String]
        runningThreadIDs = Set(
            (result["runningThreadIDs"] as? [String] ?? [])
                .compactMap(UUID.init(uuidString:)))
        hostBlockedEngines = (result["blockedEngines"] as? [String]).map(Set.init)   // W184 H4 修正（審查 #9）
        let changed = fetchedRevision != revision
        doc = fetched
        revision = fetchedRevision
        currentRevision = fetchedRevision
        onConnectionStateChange?(.success(fetchedRevision))
        guard notify, changed || catalogsChanged else { return }
        transcriptCache.removeAll(keepingCapacity: true)
        transcriptRetryAfter.removeAll(keepingCapacity: true)
        onChange?()
    }

    nonisolated private static func decode<T: Decodable>(_ value: Any?) throws -> T {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw RemoteHostLinkError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
}

// MARK: - W180 E4 遠端 /蒸餾

extension RemoteLiveEngine {
    /// 對這台（遠端 session 所在的設備）的 /蒸餾 畫布呼叫：distill_open／get／edit／write。
    /// 跟其他呼叫同一條背景序列佇列，主執行緒不等 SSH；那台只准碰指定那條的蒸餾畫布。
    func distillCall(_ method: String, params: [String: Any],
                     completion: @escaping @MainActor (Result<[String: Any], Error>) -> Void) {
        guard DistillRemoteRequest.methods.contains(method) else {
            return completion(.failure(RemoteHostLinkError.invalidResponse))
        }
        let sent = params
        perform({ try $0.call(method: method, params: sent) }) { outcome in completion(outcome) }
    }
}
