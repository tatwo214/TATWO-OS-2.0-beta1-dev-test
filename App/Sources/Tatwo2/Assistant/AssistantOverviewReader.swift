import Foundation
import Combine

/// W180 E2：「全域狀態」「專案地圖」的資料讀取器（只在頁面看得到時跑，onDisappear 就停）。
/// - 本機：直接讀本機引擎（文件、在跑、待核准）、Island 請求、終端機分頁、背景工作；W170 目標逐檔讀，放在背景。
/// - 遠端：討論串與在跑沿用遠端引擎本來 5 秒一次的 get_document 快取（這裡不另外拉文件）；
///   待核准、目標、背景工作、終端機、Island 請求用 overview_snapshot，15 秒一次、在背景佇列呼叫。
///   讀不到就保留上次的結果；對方是舊版就寫「還沒更新」。
@MainActor
final class AssistantOverviewReader: ObservableObject {
    static let shared = AssistantOverviewReader()

    nonisolated static let localInterval: Duration = .seconds(3)
    nonisolated static let remoteInterval: Duration = .seconds(15)
    /// 目標檔平常只在 ThreadGoalStore 變動或討論串增減時重讀；這是保底的重讀間隔。
    nonisolated static let goalRereadInterval: TimeInterval = 60

    struct LocalIdentity: Equatable, Sendable {
        var deviceID: String?
        var name: String
        var isPrimary: Bool
    }

    /// 記住每台上一輪看到的是哪一條連線（遠端引擎物件）。斷線後重連一定是新的引擎；
    /// 用 weak 記，舊的放掉就不會跟新的認錯。
    struct ConnectionTracker {
        private struct Mark { weak var connection: AnyObject? }
        private var marks: [String: Mark] = [:]

        func isCurrent(_ id: String, connection: AnyObject) -> Bool { marks[id]?.connection === connection }

        /// 記下這一輪的連線；跟上一輪不是同一條（剛連上、斷過又連上）就回 true。
        mutating func observe(_ id: String, connection: AnyObject) -> Bool {
            guard !isCurrent(id, connection: connection) else { return false }
            marks[id] = Mark(connection: connection)
            return true
        }

        mutating func forget(_ id: String) { marks[id] = nil }
    }

    @Published private(set) var status = OverviewStatusSnapshot()
    @Published private(set) var map = OverviewProjectMap()
    @Published private(set) var refreshedAt: Date?
    /// W180 E3b：每台遠端（通常是主設備）的分類建議，跟著 overview_snapshot 一起來；對方是舊版＝沒有這一台。
    @Published private(set) var remoteProposals: [String: [ProjectProposalCard]] = [:]
    private(set) var remoteDetails: [String: OverviewRemoteDetailState] = [:]
    private var connections = ConnectionTracker()
    /// 這次開啟後在線過的遠端（拿到過它的文件）。
    private var remoteSeenOnline = Set<String>()

    private weak var model: ChatPageModel?
    private var viewers = 0
    private var localLoop: Task<Void, Never>?
    private var remoteLoop: Task<Void, Never>?
    private var goalObservation: AnyCancellable?
    private var localRefreshing = false
    private var remoteRefreshing = false
    private var identity: LocalIdentity?
    private var localGoals: [UUID: OverviewGoalSummary]?
    private var goalThreads: Set<UUID>?
    private var goalsReadAt: Date?
    private var goalsDirty = true
    private var localJobs: [BackgroundJobManager.Snapshot] = []

    /// 頁面出現時叫（兩頁、兩個視窗共用一份；最後一個看的人走了才停）。
    func start(model: ChatPageModel) {
        self.model = model
        viewers += 1
        guard viewers == 1 else { return }
        // 頁面重新打開：看不見的這段時間沒問過，「還沒更新」作廢、馬上重問；上次的結果重問到之前只算舊資料。
        for id in Array(remoteDetails.keys) { remoteDetails[id]?.reconnected() }
        // ThreadGoalStore 唯一的 @Published 是 revision：目標一改就重讀（不用等下一輪）。
        goalObservation = ThreadGoalStore.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.goalsDirty = true
            Task { await self.refreshLocal() }
        }
        localLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLocal()
                try? await Task.sleep(for: Self.localInterval)
            }
        }
        remoteLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshRemote()
                try? await Task.sleep(for: Self.remoteInterval)
            }
        }
    }

    /// 頁面消失時叫：不再輪詢本機，也不再問遠端。
    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        localLoop?.cancel(); localLoop = nil
        remoteLoop?.cancel(); remoteLoop = nil
        goalObservation = nil
    }

    var isPolling: Bool { localLoop != nil || remoteLoop != nil }

    // MARK: - 本機

    func refreshLocal() async {
        guard let model, !localRefreshing else { return }
        localRefreshing = true
        defer { localRefreshing = false }
        if identity == nil {
            let environment = ProcessInfo.processInfo.environment
            identity = await Task.detached(priority: .utility) { Self.readLocalIdentity(environment: environment) }.value
        }
        if let live = model.localLiveForBridge {
            let threads = Set(live.doc.threads.filter { !$0.isArchived }.map(\.id))
            let now = Date()
            let expired = goalsReadAt.map { now.timeIntervalSince($0) >= Self.goalRereadInterval } ?? true
            if goalsDirty || expired || goalThreads != threads {
                goalsDirty = false
                let ids = Array(threads)
                localGoals = await Task.detached(priority: .utility) { Self.readGoalSummaries(threads: ids) }.value
                goalThreads = threads
                goalsReadAt = now
            }
        }
        localJobs = await OSAgentBridge.shared.backgroundJobSnapshot(includeLastLine: false)
        rebuild()
    }

    /// W170 目標逐檔讀（可能上千條）：一定在背景跑，不在主執行緒。
    nonisolated static func readGoalSummaries(threads: [UUID]) -> [UUID: OverviewGoalSummary] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var result: [UUID: OverviewGoalSummary] = [:]
        for id in threads {
            if let summary = OverviewGoalSummary.from(ThreadGoalStore.shared.list(id)) { result[id] = summary }
        }
        return result
    }

    /// 這台的名稱與是不是主設備：讀身分檔（背景）；讀不到就叫「這台 Mac」。
    nonisolated static func readLocalIdentity(environment: [String: String]) -> LocalIdentity {
        let identity = try? DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: environment))
        return LocalIdentity(deviceID: identity?.deviceID, name: identity?.name ?? "這台 Mac",
                             isPrimary: identity?.role == .primary)
    }

    /// 本機這一份（主執行緒上讀引擎的現況，不做檔案或網路）。
    func localInput(model: ChatPageModel) -> OverviewDeviceInput? {
        guard let live = model.localLiveForBridge else { return nil }
        let doc = live.doc
        let titles = Dictionary(doc.threads.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return OverviewDeviceInput(
            id: identity?.deviceID ?? "local", name: identity?.name ?? "這台 Mac", isThisDevice: true,
            isPrimary: identity?.isPrimary ?? false, connection: .online, lastSeenAt: nil,
            document: doc, offlineDocument: nil,
            running: Set(doc.threads.filter { live.isRunning($0.id) }.map(\.id)),
            pending: live.pendingPermissionThreadIDs,
            goals: localGoals,
            jobs: localJobs.map { OverviewJob.from($0, threadTitles: titles) },
            cli: (model.cliSessionStore?.sessions ?? []).map(OverviewCLI.from),
            requestTitles: IslandNotice.shared.pendingRequestTitles,
            detail: localGoals == nil ? .waiting : .live)
    }

    // MARK: - 遠端

    func refreshRemote() async {
        guard let model, !remoteRefreshing else { return }
        remoteRefreshing = true
        defer { remoteRefreshing = false }
        for session in model.remoteSessions {
            let id = session.device.id
            guard case .online = session.state, let engine = session.engine else {
                connections.forget(id)   // 斷線：下次連上就算重新連上
                continue
            }
            if connections.observe(id, connection: engine) {
                // 剛連上或斷過又連上（例如對方更新後重開）：「還沒更新」作廢、這輪就重問。
                remoteDetails[id]?.reconnected()
            }
            guard remoteDetails[id]?.shouldFetch(now: Date()) ?? true else { continue }
            let link = session.link
            let (outcome, proposals) = await Task.detached(priority: .utility) { Self.fetchRemoteDetail(link: link) }.value
            remoteDetails[id, default: OverviewRemoteDetailState()].apply(outcome, now: Date())
            // W180 E3b：分類建議讀不到就保留上次的；對方是舊版就拿掉。
            switch outcome {
            case .success: if remoteProposals[id] != proposals { remoteProposals[id] = proposals }
            case .needsUpdate: if remoteProposals[id] != nil { remoteProposals[id] = nil }
            case .failed: break
            }
        }
        rebuild()
    }

    /// W180 E3b：副設備決定之後馬上重問一次（正在問的那一輪先等它結束，最多等 5 秒）。
    func refreshRemoteNow() async {
        for _ in 0..<20 where remoteRefreshing { try? await Task.sleep(for: .milliseconds(250)) }
        await refreshRemote()
    }

    /// 背景佇列：RemoteHostLink.call 會等 SSH，主執行緒一律不准走。
    nonisolated static func fetchRemoteDetail(link: RemoteHostLink) -> (OverviewFetchOutcome, [ProjectProposalCard]?) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            let snapshot = try link.call(method: "overview_snapshot", params: [:])
            // W180 E3b：同一份回應裡的分類建議（白名單解析；舊版沒有這一組＝nil）。
            return (.success(try OverviewRemoteDetail(snapshot: snapshot)), ProjectClassificationWire.cards(snapshot))
        } catch RemoteHostLinkError.remoteError(let code) where code == "unsupported_method" || code == "caller_not_trusted" {
            return (.needsUpdate, nil)
        } catch {
            return (.failed, nil)
        }
    }

    /// 一台遠端的輸入：在線時用遠端引擎的文件快取＋上次拿到的摘要；離線時只剩名稱與數量。
    func remoteInput(_ session: RemoteDeviceSession, primaryID: String?) -> OverviewDeviceInput {
        let device = session.device
        let connection: OverviewConnection
        switch session.state {
        case .online: connection = .online
        case .connecting: connection = .connecting
        case .offline: connection = .offline
        }
        var input = OverviewDeviceInput(
            id: device.id, name: device.name, isThisDevice: false,
            isPrimary: device.role == .primary || device.id.lowercased() == primaryID?.lowercased(),
            connection: connection, lastSeenAt: session.lastSeenAt, detail: .offline)
        guard connection == .online, let engine = session.engine else {
            // 這次開啟後從沒拿到過它的文件：session 手上是空白預設，不是離線前的快照——寫看不到，不寫「沒有專案」。
            let snapshot = session.document
            let neverLoaded = snapshot == TatwoNativeChatStoreDocument() && !remoteSeenOnline.contains(device.id)
            input.offlineDocument = neverLoaded ? nil : snapshot
            return input
        }
        let doc = engine.doc
        input.document = doc
        input.running = Set(doc.threads.filter { engine.isRunning($0.id) }.map(\.id))
        var state = remoteDetails[device.id] ?? OverviewRemoteDetailState()
        // 連線換了、這輪還沒重問：上次的結果只算舊資料，之前的「還沒更新」也不算數。
        if !connections.isCurrent(device.id, connection: engine) { state.reconnected() }
        input.detail = state.source
        if let detail = state.visible {
            input.pending = detail.pending
            input.goals = detail.goals
            input.jobs = detail.jobs
            input.cli = detail.cli
            input.requestTitles = detail.requestTitles
        }
        return input
    }

    // MARK: - 投影

    private func rebuild() {
        guard let model else { return }
        let now = Date()
        var inputs: [OverviewDeviceInput] = []
        if let local = localInput(model: model) { inputs.append(local) }
        let primaryID = model.assistantPrimaryDevice?.id
        for session in model.remoteSessions where session.engine != nil { remoteSeenOnline.insert(session.device.id) }
        inputs += model.remoteSessions.map { remoteInput($0, primaryID: primaryID) }
        let nextStatus = AssistantOverview.status(inputs, now: now)
        let nextMap = AssistantOverview.projectMap(inputs)
        if nextStatus != status { status = nextStatus }
        if nextMap != map { map = nextMap }
        refreshedAt = now
    }
}
