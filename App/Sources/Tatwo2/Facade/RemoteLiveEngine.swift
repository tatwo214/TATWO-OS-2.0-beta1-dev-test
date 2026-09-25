import Foundation

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
    var dispatchPaused = false

    private let link: RemoteHostLink
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
    private var pollTask: Task<Void, Never>?
    private(set) var currentRevision: Int64 = -1

    /// initial＝連線時在背景先拉好的第一份文件（不在主執行緒做網路）。沒有就等第一次輪詢。
    init(link: RemoteHostLink, store: ChatLiveStore, initial: [String: Any]? = nil) throws {
        self.link = link
        self.store = store
        if let initial { try apply(result: initial, notify: false) }
        let link = self.link
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let known = self?.revision, !Task.isCancelled else { return }
                // W100d（使用者 09-18 實機「OS 完全卡死」，sample 抓到主執行緒在 JSONSerialization／JSONDecoder）：
                // 網路「與解碼」都在背景執行緒；revision 沒變就連解碼都不做。主執行緒只做指派。
                let outcome = await Task.detached(priority: .utility) { () -> Result<Fetched?, Error> in
                    Result {
                        let result = try link.call(method: "get_document", params: [:])
                        let fetchedRevision = (result["revision"] as? NSNumber)?.int64Value ?? 0
                        let running = Set((result["runningThreadIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
                        if fetchedRevision == known, known >= 0 {
                            return Fetched(document: nil, revision: fetchedRevision, running: running)
                        }
                        let decoded: LiveDocumentRecord = try Self.decode(result["document"])
                        return Fetched(document: decoded, revision: fetchedRevision, running: running)
                    }
                }.value
                guard let self, !Task.isCancelled else { return }
                switch outcome {
                case .success(let fetched):
                    if let fetched { self.applyFetched(fetched) }
                case .failure(let error):
                    self.hintOnce("disconnect", "遙控連線中斷，正在重連：\(error.localizedDescription)")
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
                            lastPreview: thread.messages.last(where: { $0.eventKind == "message" })?.text ?? "",
                            parentThreadID: thread.parentThreadID,
                            liveness: ThreadLiveness.from(
                                status: thread.subStatus,
                                lastOutputAt: thread.lastOutputAt),
                            lastOutputAt: thread.lastOutputAt,
                            engineLabel: thread.engine)
                    },
                githubRepos: project.githubRepos.map { TatwoGitHubRepoBinding(url: $0) })
        })
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
        if !attachments.isEmpty {
            onHint?("遠端討論串不支援附件；已只送出文字")
        }
        var params: [String: Any] = [
            "threadID": threadID.uuidString,
            "text": text,
        ]
        if let model { params["model"] = model }
        if let reasoningEffort { params["reasoningEffort"] = reasoningEffort }
        if let serviceTier { params["serviceTier"] = serviceTier }
        // A pre-upgrade host must reject rather than silently ignore new
        // turn controls. One call, same transport; no extra polling.
        let method = reasoningEffort != nil || serviceTier != nil ? "send_message_with_options" : "send_message"
        // W100：送出是使用者動作，但一樣不能在主執行緒等 SSH。背景送出、完成回呼再刷新。
        let sent = params
        perform({ try $0.call(method: method, params: sent) }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.transcriptCache[threadID] = nil
                self.transcriptRetryAfter[threadID] = nil
                self.refreshDocument(notify: true)
            case .failure(let error):
                self.hintOnce("send", "遙控送出失敗：\(error.localizedDescription)")
            }
        }
        return true
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
        _ work: @escaping @Sendable (RemoteHostLink) throws -> T,
        then completion: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        let link = self.link
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
                    self.onChange?()
                } catch {
                    self.transcriptRetryAfter[threadID] = Date().addingTimeInterval(3)
                    self.hintOnce("transcript", "遙控對話讀不懂：\(error.localizedDescription)")
                }
            case .failure(let error):
                self.transcriptRetryAfter[threadID] = Date().addingTimeInterval(3)
                self.hintOnce("transcript", "遙控對話讀取失敗：\(error.localizedDescription)")
            }
        }
    }

    /// 背景重拉遠端文件；完成（含失敗）後才跑 completion。
    private func refreshDocument(notify: Bool, then completion: @escaping @MainActor () -> Void = {}) {
        perform({ try $0.call(method: "get_document", params: [:]) }) { [weak self] outcome in
            guard let self else { return completion() }
            switch outcome {
            case .success(let result):
                do { try self.apply(result: result, notify: notify) }
                catch { self.hintOnce("document", "遙控資料讀不懂：\(error.localizedDescription)") }
            case .failure(let error):
                self.hintOnce("document", "遙控文件更新失敗：\(error.localizedDescription)")
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
    }
    private func applyFetched(_ fetched: Fetched) {
        runningThreadIDs = fetched.running
        guard let document = fetched.document else {
            onConnectionStateChange?(.success(fetched.revision))
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

    private func apply(result: [String: Any], notify: Bool) throws {
        let fetched: LiveDocumentRecord = try Self.decode(result["document"])
        let fetchedRevision = (result["revision"] as? NSNumber)?.int64Value ?? 0
        runningThreadIDs = Set(
            (result["runningThreadIDs"] as? [String] ?? [])
                .compactMap(UUID.init(uuidString:)))
        let changed = fetchedRevision != revision
        doc = fetched
        revision = fetchedRevision
        currentRevision = fetchedRevision
        onConnectionStateChange?(.success(fetchedRevision))
        guard notify, changed else { return }
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
