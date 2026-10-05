#if DEBUG
import Foundation
import Combine

/// W180 E2 自測（TATWO2_SELFTEST=w180overview）：分頁骨架、純投影、讀取器對 goal_index／os_status、
/// 在 Coder 打開、遠端摘要（overview_snapshot 白名單、讀不到保留、舊版提示）、乾淨安裝。
/// 只在 staging 隔離環境跑；不開 SSH、不建視窗、不碰真的入口或使用者資料。
enum AssistantOverviewAcceptance {
    private static let secret = "W180_PRIVATE_CONTENT_MUST_NOT_LEAK"

    @MainActor static func run() async throws -> Bool {
        guard let path = ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"] else {
            throw BotLibraryError.invalid("isolated TATWO2_LIVE_ROOT required")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else {
            throw BotLibraryError.invalid("run inside an isolated staging environment")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path),
              !fm.fileExists(atPath: root.appendingPathComponent("goals").path) else {
            throw BotLibraryError.invalid("self-test requires a fresh directory")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (key, suffix) in [
            "TATWO2_OS_ROOT": "os", "TATWO2_ENGINES_ROOT": "engines",
            "TATWO2_OS_UPSTREAM_PATH": "os/os-upstream.md",
            "TATWO2_DOCS_ROOT": "os", "TATWO2_CODEX_SOURCE_HOME": "engines/codex",
            "CODEX_HOME": "engines/codex", "CLAUDE_CONFIG_DIR": "engines/claude",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "engines/claude",
            "TATWO2_SKILLET_PATH": "os/skillet.md", "TATWO2_RESOURCES_ROOT": "resources",
            "HOME": "home", "CFFIXED_USER_HOME": "home", "TATWO_STAGING_SCRATCH_HOME": "home",
        ] { setenv(key, root.appendingPathComponent(suffix).path, 1) }
        let container = root.deletingLastPathComponent()
        setenv("TATWO_STAGING_ROOT", container.path, 1)
        let socketID = String(UUID().uuidString.prefix(8))
        setenv("TATWO2_OS_SOCKET", container.appendingPathComponent("\(socketID)-os").path, 1)
        setenv("TATWO2_BROWSER_SOCKET", container.appendingPathComponent("\(socketID)-web").path, 1)
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.validationError(environment) == nil else {
            throw BotLibraryError.invalid("invalid isolated self-test environment")
        }
        try fm.createDirectory(at: root.appendingPathComponent("os"), withIntermediateDirectories: true)
        try Data("# Isolated self-test upstream\n".utf8).write(to: root.appendingPathComponent("os/os-upstream.md"))

        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W180OVERVIEW \(condition ? "PASS" : "FAIL") \(label)")
        }

        projectionChecks(check)
        remoteDetailChecks(check)

        // 乾淨安裝：新文件、沒有配對設備、沒有目標。
        let store = ChatLiveStore(root: root)
        let engine = ChatLiveEngine(store: store, environment: environment)
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        guard let assistantID = engine.doc.assistantThreadID, let assistantProjectID = engine.doc.assistantProjectID else {
            throw BotLibraryError.invalid("assistant identity missing")
        }
        let reader = AssistantOverviewReader.shared
        reader.start(model: model)
        check(reader.isPolling, "(3) reader polls while a page is visible")
        reader.stop()
        check(!reader.isPolling, "(3) reader stops polling on disappear")
        await reader.refreshLocal()
        let fresh = reader.status.devices.first
        check(reader.status.devices.count == 1 && fresh?.isThisDevice == true
              && fresh?.running.isEmpty == true && fresh?.awaiting?.isEmpty == true
              && fresh?.goals?.isEmpty == true && fresh?.jobs?.isEmpty == true
              && reader.status.running == 0 && reader.status.awaiting == 0,
              "(7) clean install: one device, empty status sections")
        check(reader.map.devices.count == 1
              && !(reader.map.devices.first?.projects.contains { $0.id == assistantProjectID } ?? true)
              && (reader.map.devices.first?.projects.allSatisfy { $0.runningCount == 0 && $0.openGoals == 0 } ?? false),
              "(7) clean install map: this device only, no assistant project, nothing running")

        let jobThreadTitle = "Job owner"
        let project = engine.newProject(name: "Overview project", workdir: root.path)
        let first = engine.newThread(in: project, title: "Overview first")
        let second = engine.newThread(in: project, title: "Overview second")
        let jobOwner = engine.newThread(in: project, title: jobThreadTitle)
        engine.appendSystemMessage(threadID: first, text: secret, status: "info|test")
        model.document = engine.document
        // 背景工作：標題、指令、位置都是秘密字串，畫面只能看到所屬討論串的標題。
        let job = BackgroundJobManager.Record(jobID: UUID(), pid: 0, title: secret, command: secret, cwd: secret,
            logPath: root.appendingPathComponent("private.log").path, threadID: jobOwner,
            startedAt: Date(), state: "exited", exitCode: 1)
        try Data(secret.utf8).write(to: root.appendingPathComponent("private.log"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([job]).write(to: root.appendingPathComponent("bg-jobs.json"))
        OSAgentBridge.shared.configureCallerTest(model: model, manager: BackgroundJobManager(root: root))

        // 兩條本機討論串加目標檔；讀取器、goal_index、os_status、overview_snapshot 要一致。
        try ThreadGoalStore.shared.update(first) { list in
            let a = try ThreadGoalRules.add(&list, title: "First done", userWords: secret, proposed: false)
            try ThreadGoalRules.setStatus(&list, id: a.id, to: .done, evidence: secret, actor: .lead)
            let b = try ThreadGoalRules.add(&list, title: "First active", userWords: secret, proposed: false)
            try ThreadGoalRules.setStatus(&list, id: b.id, to: .active, evidence: nil, actor: .lead)
            _ = try ThreadGoalRules.add(&list, title: "Proposal", userWords: secret, proposed: true)
        }
        try ThreadGoalStore.shared.update(second) { list in
            let c = try ThreadGoalRules.add(&list, title: "Second review", userWords: secret, proposed: false)
            try ThreadGoalRules.setStatus(&list, id: c.id, to: .review, evidence: secret, actor: .lead)
        }
        // os_status 另外算的兩種：巡檢自動停掉的房間、上一輪出錯的討論串；派出去的房間（subStatus running）算在跑。
        let stalledRoom = engine.newThread(in: project, title: "Overview stalled room")
        engine.configureRoom(threadID: stalledRoom, parentThreadID: first, roomBrief: secret, engine: "claude", cwdOverride: secret)
        let runningRoom = engine.newThread(in: project, title: "Overview running room")
        engine.configureRoom(threadID: runningRoom, parentThreadID: first, roomBrief: secret, engine: "claude", cwdOverride: secret)
        engine.appendSystemMessage(threadID: jobOwner, text: secret, status: "error|test")
        engine.markSubStatus(stalledRoom, "stalled")   // 會存檔：上一則訊息也進了文件
        model.document = engine.document
        await reader.refreshLocal()
        let local = reader.status.devices.first
        let readerGoals = Dictionary((local?.goals ?? []).map { ($0.threadID, $0.goal) }, uniquingKeysWith: { a, _ in a })
        let index = try json(await bridgeCall("goal_index"))
        let indexRows = index["threads"] as? [[String: Any]] ?? []
        let indexProgress = Dictionary(indexRows.compactMap { row -> (UUID, [Int])? in
            guard let id = (row["threadID"] as? String).flatMap(UUID.init(uuidString:)),
                  let progress = row["progress"] as? [String: Any],
                  let done = (progress["done"] as? NSNumber)?.intValue,
                  let total = (progress["total"] as? NSNumber)?.intValue else { return nil }
            return (id, [done, total])
        }, uniquingKeysWith: { a, _ in a })
        check(Set(readerGoals.keys) == Set(indexProgress.keys) && Set(readerGoals.keys) == [first, second]
              && readerGoals.allSatisfy { indexProgress[$0.key] == [$0.value.done, $0.value.total] },
              "(3) reader goals match goal_index (same threads, same n/m)")
        check(readerGoals[first]?.activeTitle == "First active" && readerGoals[first]?.open == 1
              && readerGoals[second]?.review == 1, "(3) active title, open count and review count")
        let status = try json(await bridgeCall("os_status"))
        for key in ["running", "awaitingApproval", "stalled", "failed"] {
            let ids = Set((status[key] as? [[String: Any]] ?? []).compactMap { $0["threadID"] as? String })
            let rows: [OverviewThreadRow]
            switch key {
            case "running": rows = local?.running ?? []
            case "awaitingApproval": rows = local?.awaiting ?? []
            case "stalled": rows = local?.stalled ?? []
            default: rows = local?.failed ?? []
            }
            check(ids == Set(rows.map(\.threadID.uuidString)), "(3) reader \(key) matches os_status")
        }
        check(local?.stalled.contains { $0.threadID == stalledRoom && $0.stage == AssistantOverview.watchdogStage } == true
              && local?.failed.contains { $0.threadID == jobOwner && $0.stage == AssistantOverview.errorStage } == true
              && local?.running.map(\.threadID) == [runningRoom],
              "(3) watchdog-stalled room and a thread that ended with an error show up like os_status")
        let localProject = reader.map.devices.first?.projects.first { $0.id == project }
        check(localProject?.runningCount == 1 && localProject?.threads.first { $0.threadID == runningRoom }?.isRunning == true,
              "(3) subStatus running counts on the map for this device (same as the status page)")
        let jobs = local?.jobs ?? []
        check(jobs.count == 1 && jobs.first?.name == jobThreadTitle && jobs.first?.isFailed == true,
              "(3) background job named by its thread, failed state, no command")
        engine.withPendingPermission(second) {
            let pending = reader.localInput(model: model).map { AssistantOverview.deviceStatus($0, now: Date()) }
            check(pending?.awaiting?.map(\.threadID) == [second] && pending?.awaitingCount == 1,
                  "(3) local pending approval comes from the live engine")
        }

        // B 段：overview_snapshot（白名單、秘密不外流、MacBook 解析後同一批待核准與目標）。
        let snapshotData = try await bridgeCall("overview_snapshot")
        let snapshot = try json(snapshotData)
        let keys = AssistantOverviewWire.allKeys(snapshot)
        check(keys.isSubset(of: AssistantOverviewWire.allowedKeys), "(6) overview_snapshot keys are allowlisted")
        check(keys.isDisjoint(with: forbiddenKeys), "(6) overview_snapshot has no text/content/cwd/path/host keys")
        check(!String(decoding: snapshotData, as: UTF8.self).contains(secret),
              "(6) overview_snapshot leaks no message, goal source/evidence, job command/cwd/log")
        let parsed = try OverviewRemoteDetail(snapshot: snapshot)
        check(parsed.goals == readerGoals, "(6) parsed remote goals equal the local reader's goals")
        check(parsed.jobs.map(\.name) == [jobThreadTitle] && parsed.pending.isEmpty && parsed.cli.isEmpty,
              "(6) parsed jobs and empty pending/CLI")
        for staging in [false, true] {
            check(OSAgentBridge.allows(caller: .ssh, method: "overview_snapshot", params: [:], staging: staging),
                  "(6) paired device over SSH may read overview_snapshot (staging=\(staging))")
            check(!OSAgentBridge.allows(caller: .other(pid: nil), method: "overview_snapshot", params: [:], staging: staging),
                  "(6) untrusted caller is refused (staging=\(staging))")
            for method in ["os_status", "goal_index"] {
                check(!OSAgentBridge.allows(caller: .ssh, method: method, params: [:], staging: staging),
                      "(6) \(method) still refused over SSH (staging=\(staging))")
            }
        }

        // (5) 在 Coder 打開：本機串 → Coder 模式、選到那條、不是遠端、助理草稿不動。
        let map = reader.map.devices.first
        check(!(map?.projects.contains { $0.id == assistantProjectID } ?? true)
              && map?.projects.first { $0.id == project }?.mainCount == 3,
              "(5) map lists the Coder project and never the assistant project")
        model.mode = .tatwo
        model.prompt = "Coder draft"
        model.assistantPrompt = "Assistant draft"
        let localID = map?.id ?? "local"
        check(AssistantOverviewNavigation.open(model: model, deviceID: localID, isThisDevice: true, threadID: second)
              && model.mode == .chat && model.selectedThreadID == second && model.selectedRemote == nil
              && model.assistantPrompt == "Assistant draft",
              "(5) open local thread: Coder mode, selected, not remote, assistant draft kept")
        model.mode = .tatwo
        check(!AssistantOverviewNavigation.open(model: model, deviceID: localID, isThisDevice: true, threadID: UUID())
              && model.mode == .tatwo && model.selectedThreadID == second, "(5) missing thread does nothing")
        check(!AssistantOverviewNavigation.open(model: model, deviceID: "Primary One", isThisDevice: false, threadID: first)
              && model.mode == .tatwo, "(5) unknown or offline remote does nothing")
        model.mode = .chat
        check(AssistantOverviewNavigation.open(model: model, deviceID: localID, isThisDevice: true, threadID: assistantID)
              && model.mode == .tatwo && model.selectedThreadID == second,
              "(5) assistant thread returns to TATWO without changing Coder selection")
        // 已經在 TATWO（這兩頁只在 TATWO 裡）：點助理那條連一次 mode 都不指定——
        // 指定 mode 會停掉電腦操作、收回瀏覽器請求，正在等核准的那件事就被打斷。
        AssistantSpaceTabStore.shared.select(.status)
        var assignments = 0
        let watcher = model.$mode.dropFirst().sink { _ in assignments += 1 }
        let opened = AssistantOverviewNavigation.open(model: model, deviceID: localID, isThisDevice: true, threadID: assistantID)
        watcher.cancel()
        check(opened && assignments == 0 && model.mode == .tatwo && model.selectedThreadID == second
              && AssistantSpaceTabStore.shared.selected == .conversation,
              "(5) assistant thread from the status page: mode is never reassigned, tab back to conversation")

        tabChecks(check, model: model, assistantID: assistantID, coderID: second)

        print("W180OVERVIEW SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }

    private static let forbiddenKeys: Set<String> = [
        "text", "content", "cwd", "path", "host", "user", "fingerprint", "messages", "command", "lastLine",
        "workdir", "brief", "roomBrief", "userWords", "evidence", "logPath", "tmuxName",
    ]

    /// os.sock 方法要在主執行緒外呼叫（bridge 會回主執行緒讀資料）；回傳 JSON，跟遠端收到的一樣。
    private static func bridgeCall(_ method: String) async throws -> Data {
        try await Task.detached {
            try JSONSerialization.data(withJSONObject: OSAgentBridge.shared.callForSelfTest(method: method, params: [:]))
        }.value
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BotLibraryError.invalid("bridge reply is not an object")
        }
        return object
    }

    // MARK: - (1) 分頁骨架

    @MainActor
    private static func tabChecks(_ check: (Bool, String) -> Void, model: ChatPageModel, assistantID: UUID, coderID: UUID) {
        let tabs = AssistantSpaceTabStore.shared
        check(tabs.selected == .conversation, "(1) default tab is conversation")
        check(AssistantSpaceTab.allCases == [.conversation, .memory, .status, .projectMap, .team],
              "(1) tabs keep the sidebar order")
        check(AssistantSpaceTab.status.isSelectable && AssistantSpaceTab.projectMap.isSelectable
              && AssistantSpaceTab.memory.isSelectable && !AssistantSpaceTab.team.isSelectable,
              "(1) status, map and memory (W180 E1) open; team later")
        model.mode = .tatwo
        let before = (model.selectedThreadID, model.prompt, model.assistantPrompt, model.selectedRemote == nil)
        tabs.select(.status)
        check(tabs.selected == .status, "(1) status selectable")
        tabs.select(.projectMap)
        check(tabs.selected == .projectMap, "(1) project map selectable")
        tabs.select(.team)
        check(tabs.selected == .projectMap, "(1) team cannot be selected")
        tabs.select(.conversation)
        check(tabs.selected == .conversation && model.mode == .tatwo && model.selectedThreadID == before.0
              && model.prompt == before.1 && model.assistantPrompt == before.2 && (model.selectedRemote == nil) == before.3,
              "(1) switching tabs keeps mode, Coder selection, Coder draft and assistant draft")
        tabs.select(.status)
        tabs.modeAssigned(.chat)
        check(tabs.selected == .status, "(1) leaving TATWO does not reset the tab")
        tabs.modeAssigned(.tatwo)
        check(tabs.selected == .conversation, "(1) coming back to TATWO returns to conversation")
        // 跟 host 同一條接法：mode 每被指定一次就通知分頁（已經在 TATWO、又被導到助理那條）。
        let wiring = model.$mode.dropFirst().sink { tabs.modeAssigned($0) }
        tabs.select(.projectMap)
        model.selectLocalThread(assistantID)
        check(tabs.selected == .conversation && model.mode == .tatwo && model.selectedThreadID == coderID,
              "(1) opening the assistant thread from elsewhere returns to conversation")
        wiring.cancel()
        tabs.select(.status)
        tabs.selectedThreadChanged(coderID, assistantThreadID: assistantID)
        check(tabs.selected == .status, "(1) selecting a Coder thread keeps the tab")
        tabs.selectedThreadChanged(assistantID, assistantThreadID: assistantID)
        check(tabs.selected == .conversation, "(1) selected thread becoming the assistant returns to conversation")
    }

    // MARK: - (2) 純投影

    private static func projectionChecks(_ check: (Bool, String) -> Void) {
        let now = Date()
        let alpha = LiveProjectRecord(name: "Alpha project", workdir: secret)
        let beta = LiveProjectRecord(name: "Beta project", workdir: secret)
        let general = LiveProjectRecord(name: "一般", workdir: secret)
        let assistant = LiveProjectRecord(name: "TATWO 助理", workdir: secret)
        func thread(_ title: String, _ project: LiveProjectRecord?, age: TimeInterval) -> LiveThreadRecord {
            var row = LiveThreadRecord(projectID: project?.id, title: title,
                                       updatedAt: now.addingTimeInterval(-age))
            row.messages = [LiveMessageRecord(ChatMessage(role: .user, text: secret))]
            row.cwdOverride = secret; row.roomBrief = secret
            return row
        }
        var run = thread("Running", alpha, age: 60); run.lastOutputAt = now.addingTimeInterval(-60)
        var stall = thread("Stalled", alpha, age: 1200); stall.lastOutputAt = now.addingTimeInterval(-1200)
        var sub = thread("Room", nil, age: 30); sub.parentThreadID = run.id; sub.subStatus = "failed"
        let wait = thread("Waiting", alpha, age: 90)
        var archived = thread("Archived", alpha, age: 5); archived.isArchived = true
        let chat = thread("Chat", general, age: 10)
        let assistantThread = thread("TATWO 助理", assistant, age: 20)
        var assistantRoom = thread("Assistant room", assistant, age: 25); assistantRoom.parentThreadID = assistantThread.id
        var native = thread("Native", alpha, age: 300)
        native.nativeGoal = ChatNativeGoal(threadId: "native", objective: "Ship", status: "active", tokenBudget: nil,
                                           tokensUsed: 0, timeUsedSeconds: 0, createdAt: 0, updatedAt: 0)
        let doc = LiveDocumentRecord(projects: [alpha, beta, general, assistant],
                                     threads: [run, stall, sub, wait, archived, chat, assistantThread, assistantRoom, native],
                                     selectedThreadID: run.id, generalProjectID: general.id, assistantProjectID: assistant.id)
        let running: Set<UUID> = [run.id, stall.id, archived.id, assistantRoom.id]
        let goals: [UUID: OverviewGoalSummary] = [
            run.id: .init(done: 1, total: 3, review: 1, activeTitle: "Build map"),
            chat.id: .init(done: 2, total: 2, review: 0, activeTitle: nil),
            archived.id: .init(done: 0, total: 4, review: 0, activeTitle: nil),
            assistantThread.id: .init(done: 0, total: 1, review: 0, activeTitle: nil),
        ]
        let local = OverviewDeviceInput(id: "this", name: "Primary One", isThisDevice: true, isPrimary: true,
                                        connection: .online, lastSeenAt: nil, document: doc, running: running,
                                        pending: [wait.id, assistantThread.id], goals: goals,
                                        jobs: [OverviewJob(name: "Running job", state: "running", startedAt: now)],
                                        cli: [OverviewCLI(title: "Shell", running: true)], requestTitles: ["Approve"])
        let remoteThread = thread("Remote running", alpha, age: 30)
        let remoteDoc = LiveDocumentRecord(projects: [alpha], threads: [remoteThread])
        let unseen = OverviewDeviceInput(id: "second", name: "Second One", isThisDevice: false, isPrimary: false,
                                         connection: .online, lastSeenAt: now, document: remoteDoc,
                                         running: [remoteThread.id], detail: .needsUpdate)
        let lastSeen = now.addingTimeInterval(-7200)
        var offlineDoc = TatwoNativeChatStoreDocument()
        let parentID = UUID()
        offlineDoc.projects = [
            TatwoNativeChatProject(id: UUID(), name: "Gamma project", threads: [
                TatwoNativeChatThread(id: parentID, title: "Gamma main"),
                TatwoNativeChatThread(title: "Gamma other"),
                TatwoNativeChatThread(title: "Gamma room", parentThreadID: parentID),
            ]),
            TatwoNativeChatProject(id: assistant.id, name: "TATWO 助理", threads: [TatwoNativeChatThread(title: "TATWO 助理")]),
        ]
        offlineDoc.assistantProjectID = assistant.id
        let offline = OverviewDeviceInput(id: "third", name: "Third One", isThisDevice: false, isPrimary: false,
                                          connection: .offline, lastSeenAt: lastSeen, offlineDocument: offlineDoc,
                                          detail: .offline)

        let status = AssistantOverview.status([local, unseen, offline], now: now)
        let this = status.devices[0], second = status.devices[1], third = status.devices[2]
        let island = IslandWorkProvider.project(threads: doc.threads.filter { !$0.isArchived },
                                                pending: [wait.id, assistantThread.id], running: running,
                                                bots: .init(), jobs: [], now: now, limit: nil)
        let islandIDs = { (kind: IslandWorkSnapshot.Kind) in
            Set(island.exceptions.filter { $0.kind == kind }.compactMap(\.threadID))
        }
        check(this.running.map(\.threadID) == [run.id], "(2) running: archived and assistant rows excluded")
        check(Set(this.stalled.map(\.threadID)) == islandIDs(.stalled) && this.stalled.map(\.threadID) == [stall.id],
              "(2) stalled equals Island classification")
        check(Set(this.failed.map(\.threadID)) == islandIDs(.failed) && this.failed.map(\.threadID) == [sub.id],
              "(2) failed equals Island classification (room failure)")
        check(Set(this.awaiting?.map(\.threadID) ?? []) == [wait.id, assistantThread.id]
              && this.awaiting?.first { $0.threadID == assistantThread.id }?.projectName == AssistantOverview.assistantProjectName
              && this.awaitingCount == 3, "(2) approvals include the assistant thread and Island requests (Island count)")
        check(this.failed.first?.projectName == "Alpha project", "(2) a room counts in its parent's project")
        check(this.running.first?.stage == "思考中" && this.stalled.first?.stage == "超過 15 分鐘沒有輸出"
              && this.failed.first?.stage == "房間失敗", "(2) stage words follow Island")
        check(this.goals?.map(\.threadID) == [run.id] && this.goals?.first?.goal.activeTitle == "Build map",
              "(2) goal rows: open mainline only; archived, done-only and assistant excluded")
        check(status.running == 2 && status.stalled == 1 && status.failed == 1 && status.awaiting == 3,
              "(2) summary counts are exact")
        // 只有這台（看得到全部）：數字後面不加「＋看不到」。另一條在跑的是 Second One 上的。
        check(OverviewText.summary(AssistantOverview.status([local], now: now)) == "在跑 1・等你核准 3・卡住 1・失敗 1",
              "(2) summary wording")
        check(OverviewText.summary(status) == "在跑 2＋看不到・等你核准 3＋看不到・卡住 1＋看不到・失敗 1＋看不到",
              "(2) summary marks unseen devices instead of reading as 0")
        check(OverviewText.silent(third) == "看不到（Third One 離線，連上後才看得到）",
              "(2) silent device line reads 看不到 with the reason")
        check(second.awaiting == nil && second.awaitingCount == nil && second.goals == nil
              && second.running.map(\.threadID) == [remoteThread.id], "(2) remote without snapshot: approvals and goals are nil")
        let unseenText = OverviewText.awaiting(second)
        check(unseenText.contains("看不到") && unseenText.contains("Second One 還沒更新，更新後就看得到")
              && !unseenText.contains("0"), "(2) nil approvals read 看不到 with the reason, never 0")
        check(OverviewText.goals(second)?.contains("看不到") == true && OverviewText.goals(this) == nil,
              "(2) nil goals read 看不到")
        check(status.awaitingUnseen == ["Second One", "Third One"] && status.silentDevices == ["Third One"],
              "(2) summary names devices whose approvals or work are not visible")
        check(!third.reportsWork && third.name == "Third One" && third.lastSeenAt == lastSeen
              && third.running.isEmpty && third.awaiting == nil, "(2) offline device keeps name and last seen, reports nothing")

        let map = AssistantOverview.projectMap([local, unseen, offline])
        let localMap = map.devices[0], offlineMap = map.devices[2]
        let alphaCard = localMap.projects.first { $0.id == alpha.id }
        check(!localMap.projects.contains { $0.id == assistant.id }, "(2) map excludes the assistant project")
        check(alphaCard?.mainCount == 4 && alphaCard?.subCount == 1 && alphaCard?.runningCount == 2,
              "(2) map counts: mains, rooms, running (archived excluded)")
        check(alphaCard?.lastActivity == sub.updatedAt, "(2) last activity is the newest updatedAt (rooms included)")
        check(alphaCard?.openGoals == 2 && alphaCard?.latestThreadID == run.id, "(2) open goals and latest main thread")
        let order = alphaCard?.threads.map(\.threadID) ?? []
        check(order.first == run.id && order.dropFirst().first == sub.id, "(2) rooms follow their parent")
        check(alphaCard?.threads.first { $0.threadID == native.id }?.hasNativeGoal == true
              && alphaCard?.threads.first { $0.threadID == native.id }?.goal == nil,
              "(2) native /goal is a marker, not counted in n/m")
        check(localMap.projects.first { $0.id == general.id }?.name == "聊天"
              && localMap.projects.first { $0.id == beta.id }?.lastActivity == nil,
              "(2) general project reads 聊天; empty project has no activity")
        check(map.devices[1].goalsVisible == false && map.devices[1].projects.first?.openGoals == nil,
              "(2) remote without snapshot: map goals are nil, not 0")
        check(offlineMap.isSnapshot && !offlineMap.canOpen && offlineMap.lastSeenAt == lastSeen
              && offlineMap.projects.count == 1 && offlineMap.projects[0].mainCount == 2
              && offlineMap.projects[0].subCount == 1 && offlineMap.projects[0].lastActivity == nil
              && offlineMap.projects[0].threads.allSatisfy { $0.lastActivity == nil },
              "(2) offline map: names and counts only, no lastSeenAt as activity, disabled")
        check(OverviewText.mapEmpty(localMap) == nil && OverviewText.mapEmpty(offlineMap) == nil,
              "(2) devices with projects have no empty line")

        // 這次開啟後還沒拿到過文件（離線或正在連）：看不到，不是「沒有專案」。
        var never = OverviewDeviceInput(id: "fourth", name: "Fourth One", isThisDevice: false, isPrimary: true,
                                        connection: .offline, lastSeenAt: lastSeen, detail: .offline)
        let neverMap = AssistantOverview.mapDevice(never)
        never.connection = .connecting
        var emptySnapshot = never
        emptySnapshot.connection = .offline
        emptySnapshot.offlineDocument = TatwoNativeChatStoreDocument()
        var emptyRemote = never
        emptyRemote.connection = .online
        emptyRemote.document = LiveDocumentRecord(projects: [], threads: [])
        var emptyLocal = emptyRemote
        emptyLocal.isThisDevice = true
        check(neverMap.projectsUnseen && !neverMap.canOpen && !neverMap.isSnapshot
              && OverviewText.mapEmpty(neverMap) == "看不到（這次開啟後還沒連上 Fourth One）"
              && OverviewText.mapEmpty(AssistantOverview.mapDevice(never)) == "看不到（正在連 Fourth One）"
              && OverviewText.mapEmpty(AssistantOverview.mapDevice(emptySnapshot)) == "Fourth One 離線前沒有專案。"
              && OverviewText.mapEmpty(AssistantOverview.mapDevice(emptyRemote)) == "Fourth One 還沒有專案。"
              && OverviewText.mapEmpty(AssistantOverview.mapDevice(emptyLocal)) == "這台還沒有專案。",
              "(2) never-loaded remote reads 看不到, not 沒有專案; empty wording names the device")

        let job = OverviewJob(name: "Old job", state: "exited", startedAt: nil)
        check(OverviewText.jobsTruncated(Array(repeating: job, count: AssistantOverview.jobSnapshotLimit)) != nil
              && OverviewText.jobsTruncated([job]) == nil,
              "(2) jobs at the snapshot limit are marked as incomplete")

        osOnlyChecks(check, now: now)
    }

    /// os_status 另外算的兩種（Island 工作頁不列）：巡檢自動停掉的房間算卡住、最近 7 天最後一則是錯誤的算失敗；
    /// 派出去的房間（subStatus running）在全域狀態與專案地圖都算在跑。
    private static func osOnlyChecks(_ check: (Bool, String) -> Void, now: Date) {
        let project = LiveProjectRecord(name: "Ops project", workdir: secret)
        func thread(_ title: String, age: TimeInterval) -> LiveThreadRecord {
            var row = LiveThreadRecord(projectID: project.id, title: title, updatedAt: now.addingTimeInterval(-age))
            row.lastOutputAt = now.addingTimeInterval(-age)
            row.messages = [LiveMessageRecord(ChatMessage(role: .user, text: secret))]
            return row
        }
        let parent = thread("Ops main", age: 100)
        var watchdog = thread("Watchdog room", age: 1300); watchdog.parentThreadID = parent.id; watchdog.subStatus = "stalled"
        var dispatched = thread("Dispatched room", age: 10); dispatched.parentThreadID = parent.id; dispatched.subStatus = "running"
        var marked = thread("Marked stalled", age: 30); marked.subStatus = "stalled"
        let errorMessage = LiveMessageRecord(ChatMessage(role: .system, text: secret, status: "error|test"))
        var errored = thread("Errored", age: 50); errored.messages = [errorMessage]
        var oldError = thread("Old error", age: 8 * 86_400); oldError.messages = [errorMessage]
        let doc = LiveDocumentRecord(projects: [project], threads: [parent, watchdog, dispatched, marked, errored, oldError])
        let input = OverviewDeviceInput(id: "ops", name: "Ops One", isThisDevice: true, isPrimary: false,
                                        connection: .online, lastSeenAt: nil, document: doc, running: [marked.id],
                                        pending: [], goals: [:])
        let status = AssistantOverview.deviceStatus(input, now: now)
        check(Set(status.stalled.map(\.threadID)) == [watchdog.id, marked.id]
              && status.stalled.allSatisfy { $0.stage == AssistantOverview.watchdogStage },
              "(2) watchdog-stalled room counts as stalled (os_status rule), also when the engine still says running")
        check(status.failed.map(\.threadID) == [errored.id] && status.failed.first?.stage == AssistantOverview.errorStage,
              "(2) a thread that ended with an error in the last 7 days counts as failed; older ones do not")
        check(status.running.map(\.threadID) == [dispatched.id], "(2) dispatched room (subStatus running) counts as running")
        let map = AssistantOverview.projectMap([input]).devices.first?.projects.first
        check(map?.threads.first { $0.threadID == dispatched.id }?.isRunning == true
              && map?.threads.first { $0.threadID == parent.id }?.isRunning == false && map?.runningCount == 2,
              "(2) subStatus running counts on the map, same as Island and the remote engine")
    }

    // MARK: - (6) 遠端摘要

    @MainActor
    private static func remoteDetailChecks(_ check: (Bool, String) -> Void) {
        let now = Date()
        let project = LiveProjectRecord(name: "Remote project", workdir: secret)
        var pendingThread = LiveThreadRecord(projectID: project.id, title: "Remote waiting")
        pendingThread.messages = [LiveMessageRecord(ChatMessage(role: .user, text: secret))]
        let goalThread = LiveThreadRecord(projectID: project.id, title: "Remote goal")
        let doc = LiveDocumentRecord(projects: [project], threads: [pendingThread, goalThread])
        let goal = OverviewGoalSummary(done: 1, total: 2, review: 1, activeTitle: "Remote active")
        let snapshot = AssistantOverviewWire.snapshot(
            doc: doc, pending: [pendingThread.id], goals: [goalThread.id: goal],
            jobs: [OverviewJob(name: "Remote job", state: "running", startedAt: now)],
            cli: [OverviewCLI(title: "Remote shell", running: false)], requestTitles: ["Remote request"], now: now)
        let data = (try? JSONSerialization.data(withJSONObject: snapshot)) ?? Data()
        let wire = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        check(AssistantOverviewWire.allKeys(wire).isSubset(of: AssistantOverviewWire.allowedKeys)
              && AssistantOverviewWire.allKeys(wire).isDisjoint(with: forbiddenKeys)
              && !String(decoding: data, as: UTF8.self).contains(secret),
              "(6) wire snapshot is allowlisted and leaks nothing")
        let parsed = try? OverviewRemoteDetail(snapshot: wire)
        check(parsed?.pending == [pendingThread.id] && parsed?.pendingTitles[pendingThread.id] == "Remote waiting"
              && parsed?.goals[goalThread.id] == goal && parsed?.jobs.first?.isRunning == true
              && parsed?.cli == [OverviewCLI(title: "Remote shell", running: false)]
              && parsed?.requestTitles == ["Remote request"], "(6) the other device parses the same approvals and goals")
        var malformed = wire; malformed["goals"] = nil
        check((try? OverviewRemoteDetail(snapshot: malformed)) == nil, "(6) malformed snapshot is rejected, not guessed")

        guard let parsed else { return }
        var state = OverviewRemoteDetailState()
        check(state.source == .waiting && state.visible == nil, "(6) before the first reply: waiting")
        state.apply(.success(parsed), now: now)
        check(state.source == .live && state.visible == parsed, "(6) reply shown live")
        state.apply(.failed, now: now.addingTimeInterval(15))
        check(state.source == .stale(since: now) && state.visible == parsed, "(6) failure keeps the last result")
        check(OverviewText.staleNote(state.source, now: now.addingTimeInterval(180)) == "3 分鐘前的資料（之後沒讀到）",
              "(6) stale result is marked N 分鐘前")
        state.apply(.needsUpdate, now: now.addingTimeInterval(30))
        check(state.source == .needsUpdate && state.visible == nil, "(6) old version: nothing shown")
        check(OverviewText.unseenReason(state.source, name: "Primary One", connection: .online)
              == "Primary One 還沒更新，更新後就看得到", "(6) old version wording uses the device display name")
        check(!state.shouldFetch(now: now.addingTimeInterval(90)) && state.shouldFetch(now: now.addingTimeInterval(151)),
              "(6) old version is asked again after 2 minutes")
        var reconnecting = state
        reconnecting.reconnected()
        check(reconnecting.shouldFetch(now: now.addingTimeInterval(31)) && reconnecting.source == .stale(since: now)
              && reconnecting.visible == parsed,
              "(6) reconnect after an old-version reply asks again at once (no 還沒更新 left over)")
        var live = OverviewRemoteDetailState()
        live.apply(.success(parsed), now: now)
        live.reconnected()
        let staleAfterReconnect = live.source == .stale(since: now) && live.visible == parsed
        live.apply(.success(parsed), now: now.addingTimeInterval(20))
        var untouched = OverviewRemoteDetailState()
        untouched.reconnected()
        check(staleAfterReconnect && live.source == .live && untouched.source == .waiting,
              "(6) reconnect marks the last result stale (N 分鐘前) until it is read again")
        var tracker = AssistantOverviewReader.ConnectionTracker()
        let firstLink = NSObject(), secondLink = NSObject()
        check(tracker.observe("a", connection: firstLink) && !tracker.observe("a", connection: firstLink)
              && tracker.isCurrent("a", connection: firstLink), "(6) connection tracker: first sight is new, then current")
        check(tracker.observe("a", connection: secondLink) && !tracker.isCurrent("a", connection: firstLink),
              "(6) connection tracker: a new remote engine counts as a reconnect")
        tracker.forget("a")
        check(!tracker.isCurrent("a", connection: secondLink) && tracker.observe("a", connection: secondLink),
              "(6) connection tracker: back after offline counts as a reconnect")
        var never = OverviewRemoteDetailState()
        never.apply(.failed, now: now)
        check(never.source == .failed && never.visible == nil, "(6) never read: failed, nothing shown")
    }
}
#endif
