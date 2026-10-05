import Foundation

// W180 E2：TATWO Space「全域狀態」「專案地圖」的純投影——不碰畫面、檔案、網路，也不改任何東西。
// 每台設備一份輸入；看不到的欄位是 nil，畫面寫「看不到」＋原因，不寫 0。
// 只用標題、狀態、數字、時間：不讀訊息內容、cwd、路徑、主機、使用者、指紋。

// MARK: - 輸入

/// 一條討論串的 W170 目標摘要：完成 n／m 只算主線（不含 AI 提議與子目標）；待驗收算所有非提議的目標。
struct OverviewGoalSummary: Equatable, Sendable {
    var done: Int
    var total: Int
    var review: Int
    var activeTitle: String?

    /// 還沒完成的主線目標數。
    var open: Int { max(0, total - done) }

    static func from(_ list: ThreadGoalList) -> OverviewGoalSummary? {
        let progress = ThreadGoalRules.progress(list)
        let review = list.goals.filter { !$0.proposed && $0.status == .review }.count
        guard progress.total > 0 || review > 0 else { return nil }
        let active = list.goals.first { !$0.proposed && $0.parent == nil && $0.status == .active }
        return OverviewGoalSummary(done: progress.done, total: progress.total, review: review,
                                   activeTitle: active.map { String($0.title.prefix(200)) })
    }
}

/// 背景工作：名稱、狀態、開始時間（不含輸出、指令、位置）。
struct OverviewJob: Equatable, Sendable {
    var name: String
    var state: String
    var startedAt: Date?

    var isRunning: Bool { state == "running" }
    var isFailed: Bool { state == "failed" }

    /// 名稱用所屬討論串的標題：舊的背景工作標題預設就是整條指令（可能含路徑），不拿出來。
    static func from(_ job: BackgroundJobManager.Snapshot, threadTitles: [UUID: String]) -> OverviewJob {
        let failed = job.exitCode.map { $0 != 0 } ?? false
        let name = job.threadID.flatMap { threadTitles[$0] }.map { String($0.prefix(200)) } ?? "背景工作"
        return OverviewJob(name: name, state: failed ? "failed" : String(job.state.prefix(40)), startedAt: job.startedAt)
    }
}

/// 終端機分頁：標題、在跑與否。
struct OverviewCLI: Equatable, Sendable {
    var title: String
    var running: Bool

    static func from(_ record: CLISessionStore.Record) -> OverviewCLI {
        OverviewCLI(title: String(record.title.prefix(200)),
                    running: record.status == .running || record.status == .waitingInput)
    }
}

enum OverviewConnection: Equatable, Sendable { case online, connecting, offline }

/// 待核准、目標、背景工作、終端機、Island 請求這幾欄是從哪裡來的（看不到時畫面寫原因）。
enum OverviewDetailSource: Equatable, Sendable {
    /// 本機，或剛從對方拿到。
    case live
    /// 之後沒讀到，保留上次拿到的（since＝上次拿到的時間）。
    case stale(since: Date)
    /// 對方還是舊版，沒有 overview_snapshot。
    case needsUpdate
    /// 剛連上，還沒拿到第一份。
    case waiting
    /// 一直沒讀到。
    case failed
    /// 對方離線或正在連。
    case offline
}

/// 一台設備的輸入。document＝完整文件（本機，或在線的遠端）；離線時只剩 offlineDocument（名稱與數量）。
struct OverviewDeviceInput {
    var id: String
    var name: String
    var isThisDevice: Bool
    var isPrimary: Bool
    var connection: OverviewConnection
    var lastSeenAt: Date?
    var document: LiveDocumentRecord?
    var offlineDocument: TatwoNativeChatStoreDocument?
    var running: Set<UUID> = []
    /// nil＝看不到（不是 0）。
    var pending: Set<UUID>?
    var goals: [UUID: OverviewGoalSummary]?
    var jobs: [OverviewJob]?
    var cli: [OverviewCLI]?
    var requestTitles: [String]?
    var detail: OverviewDetailSource = .live

    /// 有完整文件、回報得出在跑的東西：本機，或在線的遠端。
    var reportsWork: Bool { document != nil && (isThisDevice || connection == .online) }
}

// MARK: - 全域狀態

struct OverviewThreadRow: Identifiable, Equatable {
    var deviceID: String
    var threadID: UUID
    var title: String
    var projectName: String?
    /// 思考中／工具／超過 15 分鐘沒有輸出／等待批准／房間失敗（照 Island 的字）。
    var stage: String
    /// 最後一次輸出（沒有就是最後更新）的時間。
    var since: Date
    var isAssistant: Bool
    var hasNativeGoal: Bool
    var id: String { deviceID + "|" + threadID.uuidString }
}

struct OverviewGoalRow: Identifiable, Equatable {
    var deviceID: String
    var threadID: UUID
    var title: String
    var projectName: String?
    var goal: OverviewGoalSummary
    var hasNativeGoal: Bool
    var id: String { deviceID + "|" + threadID.uuidString }
}

struct OverviewDeviceStatus: Identifiable, Equatable {
    var id: String
    var name: String
    var isThisDevice: Bool
    var isPrimary: Bool
    var connection: OverviewConnection
    var lastSeenAt: Date?
    var reportsWork: Bool
    var detail: OverviewDetailSource
    var running: [OverviewThreadRow] = []
    var stalled: [OverviewThreadRow] = []
    var failed: [OverviewThreadRow] = []
    /// nil＝看不到。含助理那條：待核准不藏（數字才跟 Island 對得上）。
    var awaiting: [OverviewThreadRow]?
    var requestTitles: [String]?
    var goals: [OverviewGoalRow]?
    var jobs: [OverviewJob]?
    var cli: [OverviewCLI]?

    /// 這台看得到的待核准件數（討論串＋Island 請求）；nil＝看不到。
    var awaitingCount: Int? { awaiting.map { $0.count + (requestTitles?.count ?? 0) } }
}

struct OverviewStatusSnapshot: Equatable {
    var devices: [OverviewDeviceStatus] = []

    var running: Int { devices.reduce(0) { $0 + $1.running.count } }
    var stalled: Int { devices.reduce(0) { $0 + $1.stalled.count } }
    var failed: Int { devices.reduce(0) { $0 + $1.failed.count } }
    /// 看得到的待核准加總；看不到的設備另外列名字（awaitingUnseen），不當 0。
    var awaiting: Int { devices.reduce(0) { $0 + ($1.awaitingCount ?? 0) } }
    var awaitingUnseen: [String] { devices.filter { $0.awaitingCount == nil }.map(\.name) }
    /// 離線或正在連的設備：它們上面的工作看不到。
    var silentDevices: [String] { devices.filter { !$0.reportsWork }.map(\.name) }
}

// MARK: - 專案地圖

struct OverviewMapThread: Identifiable, Equatable {
    var threadID: UUID
    var title: String
    var parentID: UUID?
    /// nil＝不知道（離線前的資料沒有更新時間）。
    var lastActivity: Date?
    var goal: OverviewGoalSummary?
    var isRunning: Bool
    var hasNativeGoal: Bool
    var id: UUID { threadID }
    var isSub: Bool { parentID != nil }
}

struct OverviewMapProject: Identifiable, Equatable {
    var id: UUID
    var name: String
    var mainCount: Int
    var subCount: Int
    var runningCount: Int
    /// 最大的 updatedAt；nil＝沒有討論串，或離線前的資料。
    var lastActivity: Date?
    /// 未完成的主線目標數；nil＝看不到。
    var openGoals: Int?
    /// 點專案標題時打開的那條（最近的主串）。
    var latestThreadID: UUID?
    /// 主串依最後活動新到舊，子討論串排在自己的母串後面。
    var threads: [OverviewMapThread]
}

struct OverviewMapDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var isThisDevice: Bool
    var isPrimary: Bool
    var connection: OverviewConnection
    var lastSeenAt: Date?
    /// 離線（或正在連）時整組變灰、點不動。
    var canOpen: Bool
    /// 離線前的資料：只有名稱與數量，沒有最後活動、在跑、目標。
    var isSnapshot: Bool
    /// 連專案都看不到：這次開啟後還沒從這台拿到過文件（空白預設不是「沒有專案」）。
    var projectsUnseen: Bool = false
    var detail: OverviewDetailSource
    var goalsVisible: Bool
    var projects: [OverviewMapProject]
}

struct OverviewProjectMap: Equatable {
    var devices: [OverviewMapDevice] = []
}

// MARK: - 投影

enum AssistantOverview {
    static let assistantProjectName = "TATWO 助理"
    static let generalProjectName = "聊天"
    /// os_status 另外算的兩種（Island 工作頁不列）用的字。
    static let watchdogStage = "已自動停止"
    static let errorStage = "上一輪出錯"
    /// 背景工作快照的上限（BackgroundJobManager.snapshot 取最早的 200 筆）。
    static let jobSnapshotLimit = 200

    /// 在跑：引擎回報在跑，或房間狀態是 running（同 Island、os_status、遠端引擎的 isRunning）。
    static func isRunning(_ thread: LiveThreadRecord, running: Set<UUID>) -> Bool {
        running.contains(thread.id) || thread.subStatus == "running"
    }

    /// 同 os_status：最近 7 天內、最後一則訊息是錯誤（只看狀態，不讀內容）。
    static func endedWithRecentError(_ thread: LiveThreadRecord, now: Date) -> Bool {
        thread.messages.last?.status?.hasPrefix("error") == true && now.timeIntervalSince(thread.updatedAt) < 7 * 86_400
    }

    /// 專案名：「一般」專案顯示成「聊天」（同私訊框），助理專案顯示成「TATWO 助理」。
    static func projectNames(_ doc: LiveDocumentRecord) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for project in doc.projects where names[project.id] == nil {
            if project.id == doc.assistantProjectID { names[project.id] = assistantProjectName }
            else if project.id == doc.generalProjectID { names[project.id] = generalProjectName }
            else { names[project.id] = String(project.name.prefix(200)) }
        }
        return names
    }

    /// 子討論串算進母串的專案。
    static func resolvedProjectID(_ thread: LiveThreadRecord, threads: [UUID: LiveThreadRecord]) -> UUID? {
        thread.parentThreadID.flatMap { threads[$0]?.projectID } ?? thread.projectID
    }

    static func status(_ inputs: [OverviewDeviceInput], now: Date) -> OverviewStatusSnapshot {
        OverviewStatusSnapshot(devices: inputs.map { deviceStatus($0, now: now) })
    }

    /// 在跑、待核准、卡住、失敗直接用 Island 的分類（IslandWorkProvider.project，不截斷）；封存的不算。
    /// 再照 os_status 補兩種 Island 工作頁不列的：巡檢自動停掉的房間（subStatus stalled）算卡住、
    /// 最近 7 天最後一則是錯誤的討論串算失敗——數字才跟助理用 os_status 回答的一致。
    /// 助理那條不列在在跑／卡住／失敗／目標（照 Coder 的可見範圍），但待核准照列。
    static func deviceStatus(_ input: OverviewDeviceInput, now: Date) -> OverviewDeviceStatus {
        var status = OverviewDeviceStatus(id: input.id, name: input.name, isThisDevice: input.isThisDevice,
                                          isPrimary: input.isPrimary, connection: input.connection,
                                          lastSeenAt: input.lastSeenAt, reportsWork: input.reportsWork,
                                          detail: input.detail)
        guard input.reportsWork, let doc = input.document else { return status }
        let names = projectNames(doc)
        let all = Dictionary(doc.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let threads = doc.threads.filter { !$0.isArchived }
        let work = IslandWorkProvider.project(threads: threads, pending: input.pending ?? [], running: input.running,
                                              bots: .init(), jobs: [], now: now, limit: nil)
        func row(_ thread: LiveThreadRecord, stage: String, since: Date) -> OverviewThreadRow {
            let projectID = resolvedProjectID(thread, threads: all)
            return OverviewThreadRow(deviceID: input.id, threadID: thread.id, title: String(thread.title.prefix(200)),
                                     projectName: projectID.flatMap { names[$0] }, stage: stage, since: since,
                                     isAssistant: projectID != nil && projectID == doc.assistantProjectID,
                                     hasNativeGoal: thread.nativeGoal != nil)
        }
        var awaiting: [OverviewThreadRow] = []
        var classified = Set<UUID>()
        for item in work.exceptions + work.normal {
            guard item.jobID == nil, item.botID == nil, let id = item.threadID, let thread = all[id] else { continue }
            classified.insert(id)
            let entry = row(thread, stage: item.hint, since: item.since)
            switch item.kind {
            case .awaitingApproval: awaiting.append(entry)
            case .stalled: if !entry.isAssistant { status.stalled.append(entry) }
            case .failed: if !entry.isAssistant { status.failed.append(entry) }
            case nil:
                guard !entry.isAssistant else { break }
                // 同 os_status：被巡檢標成 stalled 的算卡住，不算在跑。
                if thread.subStatus == "stalled" { status.stalled.append(row(thread, stage: watchdogStage, since: item.since)) }
                else { status.running.append(entry) }
            case .pendingMemory: break
            }
        }
        for thread in threads where !classified.contains(thread.id) {
            let stalled = thread.subStatus == "stalled"
            guard stalled || endedWithRecentError(thread, now: now) else { continue }
            let entry = row(thread, stage: stalled ? watchdogStage : errorStage, since: thread.lastOutputAt ?? thread.updatedAt)
            guard !entry.isAssistant else { continue }
            if stalled { status.stalled.append(entry) } else { status.failed.append(entry) }
        }
        status.awaiting = input.pending == nil ? nil : awaiting
        status.requestTitles = input.requestTitles
        status.jobs = input.jobs
        status.cli = input.cli
        if let goals = input.goals {
            status.goals = coderThreads(doc, all: all).compactMap { entry -> OverviewGoalRow? in
                let (thread, projectID) = entry
                guard let goal = goals[thread.id], goal.open > 0 || goal.review > 0 else { return nil }
                return OverviewGoalRow(deviceID: input.id, threadID: thread.id, title: String(thread.title.prefix(200)),
                                       projectName: names[projectID], goal: goal, hasNativeGoal: thread.nativeGoal != nil)
            }
        }
        return status
    }

    /// Coder 看得到的討論串（未封存；所屬專案在文件裡、不是助理專案），最近的在前。
    static func coderThreads(_ doc: LiveDocumentRecord,
                             all: [UUID: LiveThreadRecord]) -> [(LiveThreadRecord, UUID)] {
        let projects = Set(doc.projects.map(\.id))
        return doc.threads.compactMap { thread -> (LiveThreadRecord, UUID)? in
            guard !thread.isArchived, let projectID = resolvedProjectID(thread, threads: all),
                  projects.contains(projectID), projectID != doc.assistantProjectID else { return nil }
            return (thread, projectID)
        }
        .sorted { $0.0.updatedAt == $1.0.updatedAt ? $0.0.id.uuidString < $1.0.id.uuidString : $0.0.updatedAt > $1.0.updatedAt }
    }

    static func projectMap(_ inputs: [OverviewDeviceInput]) -> OverviewProjectMap {
        OverviewProjectMap(devices: inputs.map(mapDevice))
    }

    /// 依設備分組，不合併同名專案。離線設備只剩名稱與數量；最後活動不拿 lastSeenAt 冒充。
    static func mapDevice(_ input: OverviewDeviceInput) -> OverviewMapDevice {
        var device = OverviewMapDevice(id: input.id, name: input.name, isThisDevice: input.isThisDevice,
                                       isPrimary: input.isPrimary, connection: input.connection,
                                       lastSeenAt: input.lastSeenAt, canOpen: input.reportsWork, isSnapshot: false,
                                       detail: input.detail, goalsVisible: input.goals != nil, projects: [])
        if input.reportsWork, let doc = input.document {
            device.projects = projects(doc, running: input.running, goals: input.goals)
        } else if let offline = input.offlineDocument {
            device.isSnapshot = true
            device.goalsVisible = false
            device.projects = snapshotProjects(offline)
        } else {
            device.goalsVisible = false
            device.projectsUnseen = true
        }
        return device
    }

    static func projects(_ doc: LiveDocumentRecord, running: Set<UUID>,
                         goals: [UUID: OverviewGoalSummary]?) -> [OverviewMapProject] {
        let all = Dictionary(doc.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = projectNames(doc)
        var grouped: [UUID: [LiveThreadRecord]] = [:]
        for (thread, projectID) in coderThreads(doc, all: all) { grouped[projectID, default: []].append(thread) }
        var seen = Set<UUID>()
        let rows = doc.projects.compactMap { project -> OverviewMapProject? in
            guard project.id != doc.assistantProjectID, seen.insert(project.id).inserted else { return nil }
            let threads = grouped[project.id] ?? []   // 已經是新到舊
            let mains = threads.filter { $0.parentThreadID == nil }
            let subs = threads.filter { $0.parentThreadID != nil }
            let mainIDs = Set(mains.map(\.id))
            func row(_ thread: LiveThreadRecord) -> OverviewMapThread {
                OverviewMapThread(threadID: thread.id, title: String(thread.title.prefix(200)),
                                  parentID: thread.parentThreadID, lastActivity: thread.updatedAt,
                                  goal: goals?[thread.id], isRunning: isRunning(thread, running: running),
                                  hasNativeGoal: thread.nativeGoal != nil)
            }
            var ordered: [OverviewMapThread] = []
            for main in mains {
                ordered.append(row(main))
                ordered += subs.filter { $0.parentThreadID == main.id }.map(row)
            }
            ordered += subs.filter { !mainIDs.contains($0.parentThreadID ?? UUID()) }.map(row)
            return OverviewMapProject(
                id: project.id, name: names[project.id] ?? project.name,
                mainCount: mains.count, subCount: subs.count,
                runningCount: threads.filter { isRunning($0, running: running) }.count,
                lastActivity: threads.map(\.updatedAt).max(),
                openGoals: goals.map { goals in threads.reduce(0) { $0 + (goals[$1.id]?.open ?? 0) } },
                latestThreadID: mains.first?.id, threads: ordered)
        }
        return rows.sorted {
            let lhs = $0.lastActivity ?? .distantPast, rhs = $1.lastActivity ?? .distantPast
            return lhs == rhs ? $0.name < $1.name : lhs > rhs
        }
    }

    /// 離線前的資料：只有名稱與數量（沒有更新時間、在跑、目標）。
    static func snapshotProjects(_ doc: TatwoNativeChatStoreDocument) -> [OverviewMapProject] {
        doc.coderProjects.map { project in
            let mains = project.threads.filter { $0.parentThreadID == nil }
            let subs = project.threads.filter { $0.parentThreadID != nil }
            let mainIDs = Set(mains.map(\.id))
            func row(_ thread: TatwoNativeChatThread) -> OverviewMapThread {
                OverviewMapThread(threadID: thread.id, title: String(thread.title.prefix(200)),
                                  parentID: thread.parentThreadID, lastActivity: nil, goal: nil,
                                  isRunning: false, hasNativeGoal: false)
            }
            var ordered: [OverviewMapThread] = []
            for main in mains {
                ordered.append(row(main))
                ordered += subs.filter { $0.parentThreadID == main.id }.map(row)
            }
            ordered += subs.filter { !mainIDs.contains($0.parentThreadID ?? UUID()) }.map(row)
            return OverviewMapProject(id: project.id, name: String(project.name.prefix(200)),
                                      mainCount: mains.count, subCount: subs.count, runningCount: 0,
                                      lastActivity: nil, openGoals: nil, latestThreadID: mains.first?.id,
                                      threads: ordered)
        }
    }
}

// MARK: - 遠端摘要（overview_snapshot）

/// 對方 overview_snapshot 回來、照白名單解析過的東西。
struct OverviewRemoteDetail: Equatable, Sendable {
    var capturedAt: Date?
    var pending: Set<UUID>
    var pendingTitles: [UUID: String]
    var goals: [UUID: OverviewGoalSummary]
    var jobs: [OverviewJob]
    var cli: [OverviewCLI]
    var requestTitles: [String]

    struct Malformed: Error {}

    init(capturedAt: Date? = nil, pending: Set<UUID> = [], pendingTitles: [UUID: String] = [:],
         goals: [UUID: OverviewGoalSummary] = [:], jobs: [OverviewJob] = [], cli: [OverviewCLI] = [],
         requestTitles: [String] = []) {
        self.capturedAt = capturedAt; self.pending = pending; self.pendingTitles = pendingTitles
        self.goals = goals; self.jobs = jobs; self.cli = cli; self.requestTitles = requestTitles
    }

    /// 只讀白名單裡的鍵；缺了任何一組就當格式不對（不猜）。
    init(snapshot: [String: Any]) throws {
        guard (snapshot["version"] as? NSNumber)?.intValue == AssistantOverviewWire.version,
              let pendingRows = snapshot["pendingThreads"] as? [[String: Any]],
              let goalRows = snapshot["goals"] as? [[String: Any]],
              let jobRows = snapshot["backgroundJobs"] as? [[String: Any]],
              let cliRows = snapshot["cliSessions"] as? [[String: Any]],
              let requests = snapshot["requestTitles"] as? [String] else { throw Malformed() }
        let dates = ISO8601DateFormatter()
        func uuid(_ row: [String: Any]) -> UUID? { (row["threadID"] as? String).flatMap(UUID.init(uuidString:)) }
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        var pending = Set<UUID>(), titles: [UUID: String] = [:]
        for row in pendingRows {
            guard let id = uuid(row) else { continue }
            pending.insert(id)
            titles[id] = (row["title"] as? String).map { String($0.prefix(200)) }
        }
        var goals: [UUID: OverviewGoalSummary] = [:]
        for row in goalRows {
            guard let id = uuid(row), let done = int(row["done"]), let total = int(row["total"]),
                  let review = int(row["review"]) else { continue }
            goals[id] = OverviewGoalSummary(done: done, total: total, review: review,
                                            activeTitle: (row["activeTitle"] as? String).map { String($0.prefix(200)) })
        }
        let jobs = jobRows.compactMap { row -> OverviewJob? in
            guard let name = row["name"] as? String, let state = row["state"] as? String else { return nil }
            return OverviewJob(name: String(name.prefix(200)), state: String(state.prefix(40)),
                               startedAt: (row["startedAt"] as? String).flatMap(dates.date(from:)))
        }
        let cli = cliRows.compactMap { row -> OverviewCLI? in
            guard let title = row["title"] as? String, let running = row["running"] as? Bool else { return nil }
            return OverviewCLI(title: String(title.prefix(200)), running: running)
        }
        self.init(capturedAt: (snapshot["capturedAt"] as? String).flatMap(dates.date(from:)), pending: pending,
                  pendingTitles: titles, goals: goals, jobs: jobs, cli: cli,
                  requestTitles: requests.prefix(50).map { String($0.prefix(200)) })
    }
}

enum OverviewFetchOutcome: Equatable, Sendable {
    case success(OverviewRemoteDetail)
    /// 對方回 unsupported_method 或 caller_not_trusted：還是舊版。
    case needsUpdate
    case failed
}

/// 每台遠端設備的摘要狀態：失敗時保留上次的結果；對方是舊版時隔一段時間才再問。
struct OverviewRemoteDetailState: Equatable, Sendable {
    var last: OverviewRemoteDetail?
    var lastSuccessAt: Date?
    var failing = false
    var needsUpdateAt: Date?

    mutating func apply(_ outcome: OverviewFetchOutcome, now: Date) {
        switch outcome {
        case .success(let detail):
            last = detail; lastSuccessAt = now; failing = false; needsUpdateAt = nil
        case .needsUpdate:
            needsUpdateAt = now; failing = false
        case .failed:
            failing = true
        }
    }

    /// 對方斷線或重新連上、或頁面重新打開：之前的「還沒更新」作廢（馬上重問）；
    /// 上次拿到的結果在重問到之前只算舊資料（標「N 分鐘前」），不當現況。
    mutating func reconnected() {
        needsUpdateAt = nil
        if last != nil { failing = true }
    }

    /// 每問一次舊版都會讓那條連線重建，所以舊版隔 2 分鐘才再問；對方重新連上或頁面重開就不等。
    func shouldFetch(now: Date, retryAfter: TimeInterval = 120) -> Bool {
        guard let needsUpdateAt else { return true }
        return now.timeIntervalSince(needsUpdateAt) >= retryAfter
    }

    var source: OverviewDetailSource {
        if needsUpdateAt != nil { return .needsUpdate }
        guard last != nil, let lastSuccessAt else { return failing ? .failed : .waiting }
        return failing ? .stale(since: lastSuccessAt) : .live
    }

    /// 畫面上用的那份：讀不到時照舊是上次的。
    var visible: OverviewRemoteDetail? { needsUpdateAt == nil ? last : nil }
}

/// overview_snapshot 的回應格式：只有白名單欄位——標題、狀態、數字、時間。
enum AssistantOverviewWire {
    static let version = 1

    /// 回應裡只會出現這些鍵（自測逐鍵比對）。
    static let allowedKeys: Set<String> = [
        "version", "capturedAt", "pendingThreads", "goals", "backgroundJobs", "cliSessions", "requestTitles",
        "threadID", "title", "done", "total", "review", "activeTitle", "name", "state", "startedAt", "running",
        // W180 E3b：分類建議（提案 id、討論串標題、目標名、理由；同 ProjectClassificationWire.allowedKeys）
        "projectProposals", "id", "status", "createdAt", "items", "reason", "targetName", "isNewProject",
        "threads", "blocked", "movedAt", "undoneAt", "canUndo",
    ]

    static func snapshot(doc: LiveDocumentRecord, pending: Set<UUID>, goals: [UUID: OverviewGoalSummary],
                         jobs: [OverviewJob], cli: [OverviewCLI], requestTitles: [String],
                         now: Date) -> [String: Any] {
        let dates = ISO8601DateFormatter()
        // 待核准照 Island：文件裡每一條在等核准的都算（含助理那條）。
        let pendingRows: [[String: Any]] = Array(doc.threads.filter { pending.contains($0.id) }.prefix(200)).map {
            ["threadID": $0.id.uuidString, "title": String($0.title.prefix(200))]
        }
        let goalRows: [[String: Any]] = Array(doc.threads.compactMap { thread -> [String: Any]? in
            guard let goal = goals[thread.id] else { return nil }
            return ["threadID": thread.id.uuidString, "done": goal.done, "total": goal.total, "review": goal.review,
                    "activeTitle": goal.activeTitle.map { String($0.prefix(200)) as Any } ?? NSNull()]
        }.prefix(1000))
        let jobRows: [[String: Any]] = Array(jobs.prefix(200)).map { job in
            ["name": String(job.name.prefix(200)), "state": String(job.state.prefix(40)),
             "startedAt": job.startedAt.map { dates.string(from: $0) as Any } ?? NSNull()]
        }
        let cliRows: [[String: Any]] = Array(cli.prefix(200)).map {
            ["title": String($0.title.prefix(200)), "running": $0.running]
        }
        return [
            "version": version,
            "capturedAt": dates.string(from: now),
            "pendingThreads": pendingRows,
            "goals": goalRows,
            "backgroundJobs": jobRows,
            "cliSessions": cliRows,
            "requestTitles": Array(requestTitles.prefix(50)).map { String($0.prefix(200)) },
        ]
    }

    /// 回應裡所有的鍵（遞迴），給自測比對白名單。
    static func allKeys(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { $0.formUnion(allKeys($1.value)) }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
        }
        return []
    }
}

// MARK: - 畫面用的字（看不到就寫看不到＋原因，不寫 0）

enum OverviewText {
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "剛剛" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分鐘前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小時前" }
        return "\(Int(seconds / 86_400)) 天前"
    }

    static func connection(_ connection: OverviewConnection, isThisDevice: Bool) -> String {
        if isThisDevice { return "這台" }
        switch connection {
        case .online: return "在線"
        case .connecting: return "連線中"
        case .offline: return "離線"
        }
    }

    /// 為什麼這台的待核准／目標／背景工作看不到。
    static func unseenReason(_ detail: OverviewDetailSource, name: String, connection: OverviewConnection) -> String {
        switch detail {
        case .needsUpdate: return "\(name) 還沒更新，更新後就看得到"
        case .waiting: return "正在向 \(name) 讀取"
        case .failed: return "這次沒讀到 \(name) 的資料，等一下會再試"
        case .offline: return connection == .connecting ? "正在連 \(name)" : "\(name) 離線，連上後才看得到"
        case .live, .stale: return "\(name) 沒有回這一項"
        }
    }

    /// 讀不到時保留上次的結果，標「N 分鐘前」。
    static func staleNote(_ detail: OverviewDetailSource, now: Date) -> String? {
        guard case .stale(let since) = detail else { return nil }
        let minutes = Int(now.timeIntervalSince(since) / 60)
        return minutes < 1 ? "不到 1 分鐘前的資料（之後沒讀到）" : "\(minutes) 分鐘前的資料（之後沒讀到）"
    }

    static func unseen(_ reason: String) -> String { "看不到（\(reason)）" }

    /// 有設備看不到時，數字只是看得到的那部分：後面加「＋看不到」，不讓 0 讀起來像「沒有」。
    static func summary(_ snapshot: OverviewStatusSnapshot) -> String {
        let work = snapshot.silentDevices.isEmpty ? "" : "＋看不到"
        let approvals = snapshot.awaitingUnseen.isEmpty ? "" : "＋看不到"
        return "在跑 \(snapshot.running)\(work)・等你核准 \(snapshot.awaiting)\(approvals)"
            + "・卡住 \(snapshot.stalled)\(work)・失敗 \(snapshot.failed)\(work)"
    }

    /// 離線或正在連的設備：它上面的工作看不到（卡片裡每台一行）。
    static func silent(_ device: OverviewDeviceStatus) -> String {
        unseen(unseenReason(device.detail, name: device.name, connection: device.connection))
    }

    /// 背景工作紀錄滿到快照上限：只讀得到最早的那些，較新的（可能正在跑）看不到。
    static func jobsTruncated(_ jobs: [OverviewJob]) -> String? {
        guard jobs.count >= AssistantOverview.jobSnapshotLimit else { return nil }
        return "背景工作紀錄超過 \(AssistantOverview.jobSnapshotLimit) 筆，只讀得到最早的 \(AssistantOverview.jobSnapshotLimit) 筆；較新的看不到。"
    }

    /// 專案地圖裡一台沒有專案可列時的字：看不到就寫看不到＋原因；設備名寫清楚是哪一台。
    static func mapEmpty(_ device: OverviewMapDevice) -> String? {
        if device.projectsUnseen {
            return unseen(device.connection == .connecting ? "正在連 \(device.name)" : "這次開啟後還沒連上 \(device.name)")
        }
        guard device.projects.isEmpty else { return nil }
        if device.isSnapshot { return "\(device.name) 離線前沒有專案。" }
        return device.isThisDevice ? "這台還沒有專案。" : "\(device.name) 還沒有專案。"
    }

    /// 一台的待核准：看得到寫件數；看不到寫「看不到（原因）」。
    static func awaiting(_ device: OverviewDeviceStatus) -> String {
        guard let count = device.awaitingCount else {
            return unseen(unseenReason(device.detail, name: device.name, connection: device.connection))
        }
        if device.isThisDevice { return count == 0 ? "這台沒有等你核准的事。" : "這台 \(count) 件，到 Island 查看" }
        return count == 0 ? "\(device.name) 沒有等你核准的事。" : "\(device.name) 上 \(count) 件，到 \(device.name) 的 Island 核准"
    }

    static func goals(_ device: OverviewDeviceStatus) -> String? {
        guard device.goals == nil else { return nil }
        return unseen(unseenReason(device.detail, name: device.name, connection: device.connection))
    }

    static func goalProgress(_ goal: OverviewGoalSummary) -> String {
        var text = "完成 \(goal.done)／\(goal.total)"
        if goal.review > 0 { text += "・待驗收 \(goal.review)" }
        return text
    }
}
