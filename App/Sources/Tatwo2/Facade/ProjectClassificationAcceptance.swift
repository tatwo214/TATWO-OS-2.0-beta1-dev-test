#if DEBUG
import Foundation

/// W180 E3b 自測（TATWO2_SELFTEST=w180classify）：助理提議專案分類。
/// 提案沒核准前文件不變；核准後討論串（含子討論串）到新專案、資料夾沒被建立或改動；復原後逐欄回到原狀；
/// 新專案復原後變空就封存；副設備只能用 id 決定；工具不在信任清單；project_overview 沒有訊息內容。
/// 只在 staging 隔離環境跑；不開 SSH、不建視窗、不送引擎、不碰真的入口或使用者資料。
enum ProjectClassificationAcceptance {
    private static let secret = "W180_CLASSIFY_PRIVATE_MESSAGE"
    private static let forbiddenKeys: Set<String> = [
        "text", "content", "messages", "cwd", "path", "workdir", "command", "roomBrief", "brief", "host", "user",
        "fingerprint", "logPath", "userWords", "evidence",
    ]

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
              !fm.fileExists(atPath: root.appendingPathComponent(ProjectClassificationStore.proposalsFile).path) else {
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
            print("W180CLASSIFY \(condition ? "PASS" : "FAIL") \(label)")
        }

        planChecks(check)
        try corruptFileCheck(check, root: container.appendingPathComponent("classify-corrupt-\(socketID)"))

        // 兩個工作資料夾：專案地圖搬移前後，裡面的東西與時間都不能變，也不能多出新資料夾。
        let workA = root.appendingPathComponent("work-a"), workB = root.appendingPathComponent("work-b")
        for folder in [workA, workB] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("keep\n".utf8).write(to: folder.appendingPathComponent("README.txt"))
        }

        let store = ChatLiveStore(root: root)
        let engine = ChatLiveEngine(store: store, environment: environment)
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        OSAgentBridge.shared.configureCallerTest(model: model, manager: BackgroundJobManager(root: root))
        guard let assistantID = engine.doc.assistantThreadID, let generalID = engine.doc.generalProjectID,
              let general = engine.projectRecord(generalID) else {
            throw BotLibraryError.invalid("assistant or general project missing")
        }
        let alpha = engine.newProject(name: "Classify alpha", workdir: workA.path)
        let twin = engine.newProject(name: "Classify twin", workdir: workA.path)
        let beta = engine.newProject(name: "Classify beta", workdir: workB.path)
        let t1 = engine.newThread(in: alpha, title: "Alpha main")
        guard let c1 = engine.createDiscussion(parentThreadID: t1), let g1 = engine.createDiscussion(parentThreadID: c1) else {
            throw BotLibraryError.invalid("sub-threads not created")
        }
        let t2 = engine.newThread(in: alpha, title: "Alpha second")
        let t3 = engine.newThread(in: beta, title: "Beta main")
        let t4 = engine.newThread(in: generalID, title: "General chat")
        let t5 = engine.newThread(in: alpha, title: "Alpha busy")
        engine.appendSystemMessage(threadID: t1, text: secret, status: "info|test")
        engine.rename(t1, "Alpha main")   // 存檔：逐字稿與文件一致
        model.document = engine.document
        let files = ProjectClassification.store(for: engine)

        // (1) project_overview：唯讀、只有標題、最後活動、訊息數。
        let overviewReply = await bridge("project_overview", ["callerThreadID": assistantID.uuidString])
        let overview = object(overviewReply.data)
        let projectRows = overview["projects"] as? [[String: Any]] ?? []
        let threadRows = overview["threads"] as? [[String: Any]] ?? []
        let listed = Set(threadRows.compactMap { ($0["threadID"] as? String).flatMap(UUID.init(uuidString:)) })
        let t1Row = threadRows.first { $0["threadID"] as? String == t1.uuidString }
        check(overviewReply.error == nil && [t1, t2, t3, t4, t5].allSatisfy(listed.contains)
              && t1Row?["title"] as? String == "Alpha main" && (t1Row?["messageCount"] as? Int ?? 0) >= 1
              && t1Row?["subThreadCount"] as? Int == 1 && t1Row?["lastActivity"] is String,
              "(1) project_overview lists projects and main threads with titles, activity and counts")
        let overviewText = String(decoding: overviewReply.data ?? Data(), as: UTF8.self)
        check(!overviewText.contains(secret) && !overviewText.contains(workA.path) && !overviewText.contains(workB.path)
              && keys(overview).isDisjoint(with: forbiddenKeys),
              "(1) project_overview returns no message content, paths or commands")
        check(!listed.contains(assistantID) && !listed.contains(c1) && !listed.contains(g1)
              && !projectRows.contains { $0["projectID"] as? String == engine.doc.assistantProjectID?.uuidString },
              "(1) project_overview leaves out the assistant and sub-threads")
        func group(_ id: UUID) -> Int? { projectRows.first { $0["projectID"] as? String == id.uuidString }?["folderGroup"] as? Int }
        check(group(alpha) != nil && group(alpha) == group(twin) && group(alpha) != group(beta),
              "(1) project_overview groups same-folder projects (folderGroup)")
        let overviewArgs = await bridge("project_overview", ["path": "/"])
        check(overviewArgs.error?.hasPrefix("invalid_params") == true, "(1) project_overview rejects arguments")

        // (2) project_suggest：只有助理能提；只建立提案，文件不變。
        func item(_ ids: [UUID], target: UUID? = nil, new: String? = nil, reason: String = "Same topic") -> [String: Any] {
            var row: [String: Any] = ["threadIDs": ids.map(\.uuidString), "reason": reason]
            if let target { row["targetProjectID"] = target.uuidString }
            if let new { row["newProjectName"] = new }
            return row
        }
        func suggest(_ items: [[String: Any]], caller: UUID? = nil) async -> (data: Data?, error: String?) {
            let params: [String: Any] = ["items": items, "callerThreadID": (caller ?? assistantID).uuidString]
            return await bridge("project_suggest", params)
        }
        let diskBeforeSuggest = store.load()
        let docBeforeSuggest = engine.doc
        let proposalsFileBefore = fm.fileExists(atPath: root.appendingPathComponent(ProjectClassificationStore.proposalsFile).path)
        let fromCoder = await suggest([item([t1], target: twin)], caller: t1)
        check(fromCoder.error?.hasPrefix("project_suggest_assistant_only") == true,
              "(2) only the assistant conversation may propose")
        let subOnly = await suggest([item([c1], target: twin)])
        check(subOnly.error?.contains("子討論串") == true, "(2) a sub-thread proposal is refused (sub-threads follow their main thread)")
        let otherFolder = await suggest([item([t3], target: alpha)])
        check(otherFolder.error?.hasPrefix("project_suggest_rejected") == true && otherFolder.error?.contains("另一個資料夾") == true,
              "(2) a different-folder target is refused with the reason")
        let noReason = await suggest([item([t2], target: twin, reason: " ")])
        check(noReason.error?.contains("理由") == true, "(2) each item needs a reason")
        let tooMany = await suggest([item((0..<31).map { _ in UUID() }, target: twin)])
        check(tooMany.error?.hasPrefix("invalid_params") == true, "(2) more than 30 threads are refused")
        var extra = item([t2], target: twin); extra["cwd"] = "/"
        let extraKeys = await suggest([extra])
        let both = await suggest([item([t2], target: twin, new: "Both")])
        check(extraKeys.error?.hasPrefix("invalid_params") == true && both.error?.hasPrefix("invalid_params") == true,
              "(2) unknown keys and two targets are refused")
        let first = await suggest([item([t1], target: twin, reason: "Twin work"), item([t4], new: "Classify new", reason: "New topic")])
        let p1 = (object(first.data)["proposalID"] as? String).flatMap(UUID.init(uuidString:))
        check(first.error == nil && p1 != nil && object(first.data)["status"] as? String == "pending",
              "(2) the assistant's proposal is queued as pending")
        let queued = files.proposals().first { $0.id == p1 }
        check(queued?.sourceThreadID == assistantID && queued?.items.count == 2 && queued?.items.first?.reason == "Twin work"
              && queued?.items.last?.newProjectName == "Classify new" && queued?.status == .pending,
              "(2) the queue records source, items, reasons and pending status")
        let diskAfterSuggest = store.load()
        check(!proposalsFileBefore && diskAfterSuggest.threads == diskBeforeSuggest.threads
              && diskAfterSuggest.projects == diskBeforeSuggest.projects
              && engine.doc.threads == docBeforeSuggest.threads && engine.doc.projects == docBeforeSuggest.projects,
              "(2) a pending proposal changes nothing (saved document and engine document)")
        guard let p1 else { return summary(passed, failed) }

        // (3) 卡片與 overview_snapshot：主設備多回白名單欄位，副設備解析出同一份。
        let cards = ProjectClassification.cards(store: files, doc: engine.doc, running: ProjectClassification.running(engine))
        let card = cards.first { $0.id == p1 }
        check(card?.isPending == true && card?.blocked.isEmpty == true && card?.items.map(\.targetName) == ["Classify twin", "Classify new"]
              && card?.items.last?.isNewProject == true && card?.items.first?.threads.map(\.title) == ["Alpha main"],
              "(3) the card shows reasons, threads and targets")
        let snapshotReply = await bridge("overview_snapshot", [:])
        let snapshot = object(snapshotReply.data)
        let snapshotText = String(decoding: snapshotReply.data ?? Data(), as: UTF8.self)
        check(ProjectClassificationWire.allowedKeys.isSubset(of: AssistantOverviewWire.allowedKeys)
              && keys(snapshot).isSubset(of: AssistantOverviewWire.allowedKeys) && keys(snapshot).isDisjoint(with: forbiddenKeys)
              && !snapshotText.contains(secret) && !snapshotText.contains(workA.path),
              "(3) overview_snapshot carries proposals with allowlisted keys only")
        let parsed = ProjectClassificationWire.cards(snapshot)?.first { $0.id == p1 }
        check(parsed?.items == card?.items && parsed?.status == .pending && parsed?.blocked == card?.blocked,
              "(3) the other device parses the same proposal (id, titles, target, reason)")
        check(ProjectClassificationWire.cards(["version": 1]) == nil, "(3) an older primary without proposals reads as nil")

        // (4) 核准：主串＋子討論串到目標專案；新專案只是一筆紀錄（同一個資料夾）；資料夾不建立、不改。
        let before = engine.doc
        let diskBefore = store.load()
        let foldersBefore = [fingerprint(workA), fingerprint(workB)]
        let record = try? ProjectClassification.approve(p1, engine: engine)
        let newProject = engine.doc.projects.first { $0.name == "Classify new" }
        func projectOf(_ id: UUID) -> UUID? { engine.threadRecord(id)?.projectID }
        check(record != nil && [t1, c1, g1].allSatisfy { projectOf($0) == twin },
              "(4) approve moves the thread with its sub-threads to the target project")
        check(newProject != nil && projectOf(t4) == newProject?.id && newProject?.workdir == general.workdir,
              "(4) a new project is only a project record in the same folder")
        check(projectOf(t2) == alpha && projectOf(t3) == beta && projectOf(t5) == alpha && projectOf(assistantID) == before.assistantProjectID,
              "(4) other threads stay where they were")
        check([fingerprint(workA), fingerprint(workB)] == foldersBefore && !directoryExists(named: "Classify new", under: container),
              "(4) no folder is created or changed")
        let moves = files.moves()
        check(moves.count == 1 && moves.first?.proposalID == p1 && Set(moves.first?.entries.map(\.threadID) ?? []) == [t1, c1, g1, t4]
              && moves.first?.entries.first { $0.threadID == t1 }?.from == alpha
              && moves.first?.entries.first { $0.threadID == t4 }.map { $0.from == generalID && $0.to == newProject?.id } == true
              && moves.first?.createdProjects.map(\.id) == newProject.map { [$0.id] },
              "(4) the move record has time, threads, original and new projects, proposal id")
        check(files.proposals().first { $0.id == p1 }?.status == .approved, "(4) the proposal is marked approved")
        check(error(of: { try ProjectClassification.approve(p1, engine: engine) }) == "proposal_not_pending",
              "(4) approving twice is refused")

        // (5) 復原：逐欄回到原狀；變空的新專案封存（紀錄留著），不刪；資料夾還是沒動。
        let undone = try? ProjectClassification.undo(p1, engine: engine)
        check(engine.doc.threads == before.threads, "(5) undo restores every thread field by field")
        check(engine.doc.projects == before.projects && undone?.archivedProjects.map(\.id) == newProject.map { [$0.id] }
              && undone?.archivedProjects.first?.workdir == general.workdir,
              "(5) the emptied new project is archived in the move record, not deleted")
        let diskAfter = store.load()
        check(diskAfter.threads == diskBefore.threads && diskAfter.projects == diskBefore.projects,
              "(5) the saved document is back to its earlier state")
        check(files.moves().first?.undoneAt != nil && files.moves().first?.archivedProjects.first?.name == "Classify new",
              "(5) the move record keeps the archived project for restore")
        check(error(of: { try ProjectClassification.undo(p1, engine: engine) }) == "nothing_to_undo", "(5) undo twice is refused")
        check([fingerprint(workA), fingerprint(workB)] == foldersBefore && !directoryExists(named: "Classify new", under: container),
              "(5) folders are still untouched after undo")

        // (6) 新專案裡有你後來加的對話：復原後不空，就留著。
        let second = await suggest([item([t2], new: "Classify keep", reason: "Keep topic")])
        guard let p2 = (object(second.data)["proposalID"] as? String).flatMap(UUID.init(uuidString:)) else {
            check(false, "(6) second proposal queued"); return summary(passed, failed)
        }
        let board = ProjectClassificationBoard.shared
        board.start(model: model)
        check(board.isWatching && board.localCards(model: model).contains { $0.id == p2 && $0.isPending },
              "(6) the page board lists the local pending proposal")
        board.decideLocal(model: model, id: p2, action: .approve)
        let keep = engine.doc.projects.first { $0.name == "Classify keep" }
        check(keep != nil && projectOf(t2) == keep?.id && board.message?.contains("已搬好") == true,
              "(6) approving from the page moves the thread")
        let added = engine.newThread(in: keep?.id, title: "Added later")
        board.decideLocal(model: model, id: p2, action: .undo)
        check(projectOf(t2) == alpha && projectOf(added) == keep?.id && engine.doc.projects.contains { $0.id == keep?.id }
              && files.moves().last?.archivedProjects.isEmpty == true,
              "(6) a new project that is not empty after undo is kept")
        board.stop()
        check(!board.isWatching, "(6) the board stops watching when the page goes away")

        // (6b) 核准後才在主串底下開的子討論串：復原時跟著主串回原專案；新專案變空照樣封存。有在跑的先擋。
        func proposalID(_ reply: (data: Data?, error: String?)) -> UUID? {
            (object(reply.data)["proposalID"] as? String).flatMap(UUID.init(uuidString:))
        }
        func approved(_ reply: (data: Data?, error: String?)) -> UUID? {
            guard let id = proposalID(reply), (try? ProjectClassification.approve(id, engine: engine)) != nil else { return nil }
            return id
        }
        func movedCard(_ id: UUID) -> ProjectProposalCard? {
            ProjectClassification.cards(store: files, doc: engine.doc, running: ProjectClassification.running(engine))
                .first { $0.id == id && $0.movedAt != nil }
        }
        guard let pLater = approved(await suggest([item([t2], new: "Classify later", reason: "Later topic")])),
              let laterProject = engine.doc.projects.first(where: { $0.name == "Classify later" })?.id,
              let branch = engine.createDiscussion(parentThreadID: t2), let twig = engine.createDiscussion(parentThreadID: branch) else {
            check(false, "(6b) later sub-threads set up"); return summary(passed, failed)
        }
        check(projectOf(branch) == laterProject && projectOf(twig) == laterProject,
              "(6b) a sub-thread opened after approval starts in the new project")
        engine.markSubStatus(twig, "running")
        let busyUndo = error(of: { try ProjectClassification.undo(pLater, engine: engine) })
        check(busyUndo == "undo_blocked" && movedCard(pLater)?.canUndo == false
              && movedCard(pLater)?.blocked.contains { $0.contains("正在跑") } == true
              && [t2, branch, twig].allSatisfy { projectOf($0) == laterProject },
              "(6b) undo waits while a sub-thread is running; nothing moves")
        engine.markSubStatus(twig, "done")
        let laterUndo = try? ProjectClassification.undo(pLater, engine: engine)
        check([t2, branch, twig].allSatisfy { projectOf($0) == alpha }
              && laterUndo?.laterEntries.map { Set($0.map(\.threadID)) } == Set([branch, twig])
              && laterUndo?.laterEntries?.allSatisfy { $0.from == alpha && $0.to == laterProject } == true,
              "(6b) undo brings sub-threads opened after approval back with their main thread")
        check(!engine.doc.projects.contains { $0.id == laterProject } && laterUndo?.archivedProjects.map(\.id) == [laterProject]
              && files.moves().first { $0.proposalID == pLater }?.laterEntries?.count == 2,
              "(6b) the emptied new project is archived and the record lists the later sub-threads")

        // (6c) 兩次核准動到同一條（或動到上一次新建的專案）：要先復原較晚那次；照順序復原就回到原專案、新專案封存。
        guard let pA = approved(await suggest([item([t2], new: "Classify first", reason: "First topic")])),
              let projectX = engine.doc.projects.first(where: { $0.name == "Classify first" })?.id,
              let pB = approved(await suggest([item([t2], target: twin, reason: "Second topic")])) else {
            check(false, "(6c) two approvals on one thread set up"); return summary(passed, failed)
        }
        let docBeforeOutOfOrder = engine.doc
        let outOfOrder = error(of: { try ProjectClassification.undo(pA, engine: engine) })
        check(projectOf(t2) == twin && outOfOrder == "undo_blocked"
              && engine.doc.threads == docBeforeOutOfOrder.threads && engine.doc.projects == docBeforeOutOfOrder.projects
              && files.moves().first { $0.proposalID == pA }?.undoneAt == nil
              && movedCard(pA)?.canUndo == false && movedCard(pA)?.blocked.contains { $0.contains("先復原較晚那次") } == true
              && movedCard(pB)?.canUndo == true,
              "(6c) undoing the earlier move first is refused (undo the later one first); nothing changes")
        _ = try? ProjectClassification.undo(pB, engine: engine)
        let backInX = projectOf(t2) == projectX
        _ = try? ProjectClassification.undo(pA, engine: engine)
        check(backInX && projectOf(t2) == alpha && !engine.doc.projects.contains { $0.id == projectX }
              && files.moves().first { $0.proposalID == pA }?.archivedProjects.map(\.id) == [projectX],
              "(6c) undoing in reverse order returns the thread to its original project and archives the new project")
        let joiner = engine.newThread(in: alpha, title: "Alpha joiner")
        guard let pC = approved(await suggest([item([t2], new: "Classify shared", reason: "Shared topic")])),
              let shared = engine.doc.projects.first(where: { $0.name == "Classify shared" })?.id,
              let pD = approved(await suggest([item([joiner], target: shared, reason: "Joins shared")])) else {
            check(false, "(6c) a later move into the new project set up"); return summary(passed, failed)
        }
        check(error(of: { try ProjectClassification.undo(pC, engine: engine) }) == "undo_blocked"
              && projectOf(t2) == shared && projectOf(joiner) == shared
              && movedCard(pC)?.blocked.contains { $0.contains("這次新建的專案") } == true,
              "(6c) a later move into the new project also has to be undone first")
        _ = try? ProjectClassification.undo(pD, engine: engine)
        _ = try? ProjectClassification.undo(pC, engine: engine)
        check(projectOf(t2) == alpha && projectOf(joiner) == alpha && !engine.doc.projects.contains { $0.id == shared },
              "(6c) in order, both go home and the shared new project is archived")

        // (7) 正在跑的不搬：核准被擋、原因寫在卡片上、什麼都沒動。
        let third = await suggest([item([t5], target: twin, reason: "Busy topic")])
        let p3 = (object(third.data)["proposalID"] as? String).flatMap(UUID.init(uuidString:))
        engine.markSubStatus(t5, "running")
        let busyCard = ProjectClassification.cards(store: files, doc: engine.doc, running: ProjectClassification.running(engine))
            .first { $0.id == p3 }
        let busyError = p3.flatMap { id in error(of: { try ProjectClassification.approve(id, engine: engine) }) }
        check(third.error == nil && busyCard?.blocked.contains { $0.contains("正在跑") } == true
              && busyError == "proposal_blocked" && projectOf(t5) == alpha
              && files.proposals().first { $0.id == p3 }?.status == .pending,
              "(7) a running thread blocks approval; the card says why and nothing moves")
        engine.markSubStatus(t5, "done")

        // (8) 不要：只改提案狀態。
        let fourth = await suggest([item([t3], new: "Classify beta new", reason: "Beta topic")])
        let p4 = (object(fourth.data)["proposalID"] as? String).flatMap(UUID.init(uuidString:))
        let docBeforeReject = engine.doc
        if let p4 { try? ProjectClassification.reject(p4, engine: engine) }
        check(p4 != nil && files.proposals().first { $0.id == p4 }?.status == .rejected
              && engine.doc.threads == docBeforeReject.threads && engine.doc.projects == docBeforeReject.projects
              && p4.flatMap { id in error(of: { try ProjectClassification.approve(id, engine: engine) }) } == "proposal_not_pending",
              "(8) rejecting only changes the proposal status")

        // (9) 副設備只能用 id 決定；兩個工具不在任何信任清單；引擎不能決定。
        for staging in [false, true] {
            check(OSAgentBridge.allows(caller: .ssh, method: "project_proposal_decide", params: [:], staging: staging)
                  && !OSAgentBridge.allows(caller: .other(pid: nil), method: "project_proposal_decide", params: [:], staging: staging),
                  "(9) paired devices may decide by id; other programs may not (staging=\(staging))")
            check(["project_overview", "project_suggest"].allSatisfy { method in
                !OSAgentBridge.allows(caller: .ssh, method: method, params: [:], staging: staging)
                    && !OSAgentBridge.allows(caller: .other(pid: nil), method: method, params: [:], staging: staging)
            }, "(9) the assistant tools are not on any trust list (staging=\(staging))")
        }
        check(OSAgentBridge.allows(caller: .engine(assistantID), method: "project_suggest", params: [:], staging: false)
              && OSAgentBridge.allows(caller: .app, method: "project_overview", params: [:], staging: false),
              "(9) the App and engines may use the assistant tools")
        guard let p3 else { return summary(passed, failed) }
        let docBeforeRemote = engine.doc
        let smuggled = await bridge("project_proposal_decide",
                                    ["id": p3.uuidString, "action": "approve", "threadIDs": [t2.uuidString], "targetProjectID": beta.uuidString])
        let badAction = await bridge("project_proposal_decide", ["id": p3.uuidString, "action": "move"])
        check(smuggled.error?.hasPrefix("invalid_params") == true && badAction.error?.hasPrefix("invalid_params") == true
              && engine.doc.threads == docBeforeRemote.threads, "(9) the decision RPC accepts only an id and approve/reject/undo")
        check(error(of: { _ = try ProjectClassification.decide(params: ["id": p3.uuidString, "action": "approve"],
                                                              boundThread: assistantID, engine: engine) }) == "project_decide_not_for_engines"
              && engine.doc.threads == docBeforeRemote.threads, "(9) an engine cannot approve its own proposal")
        let remoteApprove = await bridge("project_proposal_decide", ["id": p3.uuidString, "action": "approve"])
        check(object(remoteApprove.data)["status"] as? String == "approved" && projectOf(t5) == twin,
              "(9) approve by id: this device moves the thread itself")
        let remoteUndo = await bridge("project_proposal_decide", ["id": p3.uuidString, "action": "undo"])
        check(object(remoteUndo.data)["status"] as? String == "undone" && projectOf(t5) == alpha,
              "(9) undo by id moves it back")
        check(ProjectClassificationBoard.parseRemoteError("proposal_blocked: A；B") == .failed(code: "proposal_blocked", reasons: ["A", "B"])
              && ProjectClassificationBoard.parseRemoteError("unsupported_method") == .failed(code: "unsupported_method", reasons: []),
              "(9) the other device reads the primary's error code and reasons")
        check(ProjectClassification.userMessage(code: "unsupported_method", remoteName: "Primary One") == "Primary One 還沒更新，更新後才能在這台決定。",
              "(9) an older primary reads 還沒更新")

        // (10) 「請助理整理分類」：切回對話分頁、送固定的一句給助理那條；送不出去就放進空的草稿。
        var captured: [(UUID, String)] = []
        model.dmLocalSendTestDouble = { id, text, _ in captured.append((id, text)); return true }
        model.mode = .tatwo
        AssistantSpaceTabStore.shared.select(.projectMap)
        model.assistantPrompt = ""
        let sent = AssistantClassificationActions.askAssistant(model: model)
        check(sent && captured.count == 1 && captured.first?.0 == assistantID
              && captured.first?.1 == ProjectClassification.assistantRequest
              && AssistantSpaceTabStore.shared.selected == .conversation && model.mode == .tatwo && model.assistantPrompt.isEmpty,
              "(10) the chip returns to the conversation and sends the fixed request to the assistant")
        model.dmLocalSendTestDouble = { _, _, _ in false }
        model.assistantPrompt = "My draft"
        let keptDraft = !AssistantClassificationActions.askAssistant(model: model) && model.assistantPrompt == "My draft"
        model.assistantPrompt = ""
        let filledDraft = !AssistantClassificationActions.askAssistant(model: model)
            && model.assistantPrompt == ProjectClassification.assistantRequest
        check(keptDraft && filledDraft, "(10) when it cannot send, an empty draft gets the request and a typed draft is kept")
        model.dmLocalSendTestDouble = nil

        return summary(passed, failed)
    }

    private static func summary(_ passed: Int, _ failed: Int) -> Bool {
        print("W180CLASSIFY SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }

    // MARK: - 純邏輯（合成文件）

    private static func planChecks(_ check: (Bool, String) -> Void) {
        let a = LiveProjectRecord(name: "Plan alpha", workdir: "/tmp/w180-plan-a")
        let aTwin = LiveProjectRecord(name: "Plan alpha twin", workdir: "/tmp/w180-plan-a/")
        let b = LiveProjectRecord(name: "Plan beta", workdir: "/tmp/w180-plan-b")
        let assistant = LiveProjectRecord(name: "TATWO 助理", workdir: "/tmp/w180-plan-a")
        let main = LiveThreadRecord(projectID: a.id, title: "Main")
        var sub = LiveThreadRecord(projectID: a.id, title: "Sub"); sub.parentThreadID = main.id
        var grand = LiveThreadRecord(projectID: a.id, title: "Grand"); grand.parentThreadID = sub.id
        var bot = LiveThreadRecord(projectID: a.id, title: "Bot"); bot.botPermissionPreset = .askFirst
        var archived = LiveThreadRecord(projectID: a.id, title: "Archived"); archived.isArchived = true
        let other = LiveThreadRecord(projectID: b.id, title: "Other")
        let helper = LiveThreadRecord(projectID: assistant.id, title: "TATWO 助理")
        let doc = LiveDocumentRecord(projects: [a, aTwin, b, assistant], threads: [main, sub, grand, bot, archived, other, helper],
                                     assistantProjectID: assistant.id)
        func codes(_ items: [ProjectProposalItem], running: Set<UUID> = []) -> [String] {
            ProjectClassification.plan(items, doc: doc, running: running).problems.map(\.code)
        }
        func to(_ ids: [UUID], _ project: LiveProjectRecord) -> ProjectProposalItem {
            ProjectProposalItem(threadIDs: ids, targetProjectID: project.id, newProjectName: nil, reason: "r")
        }
        func new(_ ids: [UUID], _ name: String) -> ProjectProposalItem {
            ProjectProposalItem(threadIDs: ids, targetProjectID: nil, newProjectName: name, reason: "r")
        }
        check(ProjectClassification.subtree(of: main.id, in: doc.threads) == [main.id, sub.id, grand.id],
              "(0) sub-threads of sub-threads come along")
        let ok = ProjectClassification.plan([to([main.id], aTwin)], doc: doc, running: [])
        check(ok.problems.isEmpty && ok.plan?.moves.map({ $0.thread }) == [main.id],
              "(0) same folder (trailing slash ignored) can move")
        check(codes([to([main.id], b)]) == ["other_folder"], "(0) a different folder is refused")
        check(codes([to([sub.id], aTwin)]) == ["sub_thread"], "(0) a sub-thread alone is refused")
        check(codes([to([bot.id], aTwin)]) == ["bot"], "(0) bot conversations are not moved")
        check(codes([to([archived.id], aTwin)]) == ["archived"], "(0) archived conversations are not moved")
        check(codes([to([helper.id], aTwin)]) == ["assistant"], "(0) the assistant's own conversation is not moved")
        check(codes([to([main.id], assistant)]) == ["target_missing"], "(0) nothing moves into the assistant project")
        check(codes([new([main.id, other.id], "Mixed")]) == ["mixed_folders"], "(0) one new project cannot mix folders")
        check(codes([new([main.id], "plan BETA")]) == ["name_taken"], "(0) a new project name already in use is refused")
        check(codes([to([main.id], a)]) == ["already_there"], "(0) a thread already in the target is refused")
        check(codes([to([main.id], aTwin)], running: [grand.id]) == ["running"], "(0) a running sub-thread blocks its main thread")
        let created = ProjectClassification.plan([new([main.id], "Fresh")], doc: doc, running: []).plan?.newProjects.first
        check(created?.workdir == a.workdir && created?.name == "Fresh", "(0) a new project keeps the original folder")
    }

    /// 壞掉的提案檔：改之前就丟錯，檔案一個位元組都不改（留給人看）。
    private static func corruptFileCheck(_ check: (Bool, String) -> Void, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(ProjectClassificationStore.proposalsFile)
        let broken = Data("not json".utf8)
        try broken.write(to: url)
        let store = ProjectClassificationStore(root: root)
        var refused = false
        do { try store.updateProposals { $0.removeAll() } } catch let error as ProjectClassificationError {
            refused = error.code == "classification_file_unreadable"
        }
        check(refused && (try? Data(contentsOf: url)) == broken && store.proposals().isEmpty,
              "(0) an unreadable proposal file is never overwritten")
    }

    // MARK: - 工具

    /// os.sock 方法在主執行緒外呼叫（bridge 會回主執行緒讀資料）；參數與回傳都走 JSON，跟遠端一樣。
    private static func bridge(_ method: String, _ params: [String: Any]) async -> (data: Data?, error: String?) {
        let payload = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        return await Task.detached { () -> (data: Data?, error: String?) in
            let decoded = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            do {
                let reply = try OSAgentBridge.shared.callForSelfTest(method: method, params: decoded)
                return (try JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]), nil)
            } catch {
                return (nil, String(describing: error))
            }
        }.value
    }

    private static func object(_ data: Data?) -> [String: Any] {
        data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    }

    private static func keys(_ value: Any) -> Set<String> { AssistantOverviewWire.allKeys(value) }

    @MainActor private static func error(of body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let error as ProjectClassificationError { return error.code } catch { return "\(error)" }
    }

    /// 資料夾裡每個項目的相對路徑、大小、修改時間（含資料夾本身）。
    private static func fingerprint(_ folder: URL) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var rows = [". " + String(describing: (try? fm.attributesOfItem(atPath: folder.path))?[.modificationDate] ?? "none")]
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            rows.append("\(url.lastPathComponent) \(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        return rows.sorted()
    }

    private static func directoryExists(named name: String, under folder: URL) -> Bool {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return true }
        }
        return false
    }
}
#endif
