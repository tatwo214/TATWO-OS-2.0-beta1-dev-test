#if DEBUG
import Foundation
import AppKit

@MainActor enum W226aSourcesAcceptance {
    final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
    static func run(root: URL, check: (Bool, String) -> Void) async throws {
        var env = ProcessInfo.processInfo.environment; env["TATWO2_LIVE_ROOT"] = root.path
        let script = root.appendingPathComponent("turns.mjs")
        try #"""
        import readline from 'node:readline';
        readline.createInterface({input:process.stdin}).on('line', line => {
          const c = JSON.parse(line);
          if(c.op === 'close') process.exit(0);
          if(c.op !== 'send') return;
          console.log(JSON.stringify({ev:'sdk',msg:{type:'system',subtype:'init',session_id:'fixture',model:'fixture-model'}}));
          if(c.text === 'active-close') { setTimeout(()=>process.exit(0),50); return; }
          console.log(JSON.stringify({ev:'sdk',msg:{type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false}}));
          if(c.text === 'idle-close') setTimeout(()=>process.exit(0),100);
        });
        """#.write(to: script, atomically: true, encoding: .utf8)
        let bundledFixture = URL(fileURLWithPath: ClaudeSidecar.scriptPath(for: .claude, allowsOverride: false))
        guard bundledFixture.path.hasPrefix(NSHomeDirectory() + "/"), !FileManager.default.fileExists(atPath: bundledFixture.path) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: bundledFixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: script, to: bundledFixture)
        let defaults = UserDefaults.standard, prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior; overrides["tatwo2.sidecarPath.codex"] = script.path; overrides["tatwo2.sidecarPath.claude"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "fixture", workdir: root.path), thread = engine.newThread(in: project)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.engineLoginTestDouble = [.codex, .claude]; model.selectedModel = "gpt-6.1-sol"; model.selectedThreadID = thread
        CLISessionsTermination.model = model
        let log = OSEventLog.atRoot(root)
        func rows(_ kind: String) throws -> [OSEvent] { try log.flush(); return try log.query(project: project, from: .distantPast, through: .distantFuture, kinds: [kind]) }
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw CocoaError(.coderInvalidValue)
        }
        NSApp?.setActivationPolicy(.regular)
        let window = TatwoWorkOSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); NSApp?.activate(ignoringOtherApps: true)
        defer { window.close() }
        var frontPage = TatwoPage.chat.rawValue, frontKey = true, frontMain = true
        var dmTarget: UUID?
        let foreground: (UUID, String) -> Bool = { thread, surface in
            surface == "dm" ? frontKey && dmTarget == thread : OSPresence.coderVisible(thread, selected: model.selectedThreadID, page: frontPage, mode: model.mode, key: frontKey, main: frontMain)
        }
        let originalPresence = OSPresence.shared
        OSPresence.shared = OSPresence(active: { true }, foreground: foreground)
        defer { OSPresence.shared = originalPresence }
        OSPresence.shared.install()
        NotificationCenter.default.post(name: .tatwoWorkOSPageDidChange, object: TatwoPage.chat.rawValue)
        let dispatched = try await model.dispatchChecked(rooms: [RoomSpec(title: "dispatch fixture", engine: "claude", model: "fable5", brief: "dispatch", readOnly: true)], parent: thread)
        let room = UUID(uuidString: dispatched[0].threadID)!
        try await until { !engine.isRunning(room) }
        let dispatch = try rows("user_send").first { $0.thread == room.uuidString.lowercased() }
        check(dispatch?.actor != "你" && dispatch?.actor != nil && dispatch?.origin == "dispatch", "1 actual dispatch has engine actor and dispatch origin")
        check(try rows("presence").filter { $0.thread == room.uuidString.lowercased() }.isEmpty, "1 dispatch never records human presence")
        CLISessionsTermination.model = model; window.makeKeyAndOrderFront(nil); NSApp?.activate(ignoringOtherApps: true)
        model.mode = .chat; model.prompt = "idle-close"; model.send()
        try await until { !engine.isRunning(thread) }
        // Keep the main-queue exit callback pending while the fixture process exits.
        // A completed turn is not proof that the resident process is still alive.
        if let pid = engine.sidecarProcessID(threadID: thread) {
            for _ in 0..<500 {
                if OSSocketCaller.processStartTime(pid) == nil { break }
                usleep(10_000)
            }
            check(OSSocketCaller.processStartTime(pid) == nil, "4 fixture process exited before queued close callback")
        }
        let human = try rows("user_send").first { $0.thread == thread.uuidString.lowercased() }
        check(human?.actor == "你" && human?.origin == "composer", "1 actual composer records human and composer origin")
        check(try rows("presence").contains { $0.thread == thread.uuidString.lowercased() && $0.surface == "coder" }, "1 composer records foreground coder presence")
        let turn = engine.messages[thread]!.last { $0.role == .user }!.turnID!
        engine.handleSDK(thread, ["type": "result", "client_turn_id": turn, "subtype": "success"])
        let terminal = try rows("turn_end").filter { $0.thread == thread.uuidString.lowercased() }
        check(terminal.count == 1 && terminal[0].turn == turn && terminal[0].result == "通過", "4 idle close and late result preserve single successful turn with ID")
        check(engine.send(threadID: thread, text: "active-close", model: "gpt-6.1-sol", engine: .codex), "4 accepts next programmatic turn")
        let closedTurn = engine.messages[thread]!.last { $0.role == .user }!.turnID!
        try await until { !engine.isRunning(thread) }
        engine.handleSDK(thread, ["type": "result", "client_turn_id": closedTurn, "subtype": "success"])
        check(try rows("turn_end").filter { $0.thread == thread.uuidString.lowercased() && $0.turn == closedTurn && $0.result == "失敗" }.count == 1, "4 active close records failure once; late result does not add another")
        check(try rows("user_send").last?.origin == "system" && rows("user_send").last?.actor == "系統", "1 unmarked programmatic send defaults to system")
        var now = Date().addingTimeInterval(120)
        CLISessionsTermination.model = model; window.makeKeyAndOrderFront(nil)
        let presence = OSPresence(now: { now }, active: { true }, foreground: foreground)
        presence.select(thread, project: project, log: log)
        let before = try rows("presence").count
        for mode in [ChatRunMode.browser, .chatgpt, .bot, .cli] { model.mode = mode; now.addTimeInterval(60); presence.record() }
        model.mode = .chat
        frontPage = TatwoPage.plugins.rawValue
        NotificationCenter.default.post(name: .tatwoWorkOSPageDidChange, object: TatwoPage.plugins.rawValue)
        now.addTimeInterval(60); presence.record()
        check(try rows("presence").count == before, "2 Browser, ChatGPT Space, Bot, CLI and settings have zero presence")
        frontPage = TatwoPage.chat.rawValue
        NotificationCenter.default.post(name: .tatwoWorkOSPageDidChange, object: TatwoPage.chat.rawValue)
        now.addTimeInterval(60); presence.record(); presence.record()
        check(try rows("presence").count == before + 1, "2 foreground Coder records once with sixty-second throttle")
        frontKey = false; now.addTimeInterval(60); presence.record(); frontKey = true
        frontMain = false; now.addTimeInterval(60); presence.record(); frontMain = true
        let selected = model.selectedThreadID; model.selectedThreadID = UUID(); now.addTimeInterval(60); presence.record(); model.selectedThreadID = selected
        check(try rows("presence").count == before + 1, "2 non-key, Island and unselected thread have zero presence")
        let dmThread = engine.newThread(in: project), store = GlobalDMStore(defaults: UserDefaults(suiteName: "ai.tatwo.w226a." + UUID().uuidString)!)
        store.attach(model); store.select(.thread(dmThread))
        dmTarget = dmThread
        let panel = KeyWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let probe = OSPresenceDMProbe.View(frame: NSRect(x: 0, y: 0, width: 300, height: 300)); probe.store = store; panel.contentView = probe; presence.add(probe)
        panel.orderFront(nil); defer { panel.close() }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        now.addTimeInterval(60); presence.record(event: event)
        check(try rows("presence").filter { $0.thread == dmThread.uuidString.lowercased() && $0.surface == "dm" }.count == 1, "2 DM click belongs only to displayed DM thread")
        check(try rows("presence").filter { $0.thread == thread.uuidString.lowercased() }.count == before + 1, "2 DM never increments selected Coder thread")
        store.isBrowsing = true; now.addTimeInterval(60); presence.record(event: event)
        check(try rows("presence").filter { $0.thread == dmThread.uuidString.lowercased() }.count == 1, "2 DM Browser does not record presence")
        store.isBrowsing = false
        let paths = HandsPaths(root: root.appendingPathComponent("hands")), service = HandsService(paths: paths, runtime: HandsRuntime.current(paths: paths, environment: env))
        service.attach(model: model); service.noticeSink = { _, _ in }
        _ = service.rootThread(projectID: project)
        let call = UUID(), workspace = UUID(), landing = HandsProjectLanding(projectID: project, workspaceID: workspace, reminder: nil)
        check(service.journal(tool: "read_file", summary: "呼叫中", landing: landing, grant: "fixture", id: call), "3 hands admission journal succeeds")
        check(service.journal(tool: "read_file", summary: "完成", landing: landing, grant: "fixture", id: call), "3 same call completion journal succeeds")
        let hands = try rows("hands_tool").filter { $0.id == call.uuidString.lowercased() }
        check(hands.count == 1 && hands[0].workspace == workspace.uuidString.lowercased() && hands[0].thread != workspace.uuidString.lowercased(), "3,5 journal twice produces one event; workspace never masquerades as thread")
        let threadCalls = engine.messages.keys.filter { engine.threadRecord($0)?.engine == ChatLiveEngine.handsEngine }
        check(hands.first?.thread.flatMap(UUID.init(uuidString:)).map { threadCalls.contains($0) } == true, "5 hands event thread is an actual TATWO thread")
        let repo = paths.workspaceDir(workspace).appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git"); git.arguments = ["init", "-q", repo.path]
        git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice; try git.run(); git.waitUntilExit()
        let record = HandsWorkspaceRecord(id: workspace, grantID: "fixture", projectID: project, projectName: "fixture", title: "fixture", baseSHA: "", workspaceBase: "", status: "open", dependencies: [], baselineBytes: 0, createdAt: Date(), updatedAt: Date(), secretScan: HandsSecretFiles.scanVersion, gitFingerprint: HandsQuarantine.gitFingerprint(repo: repo.path))
        try service.workspaceStore.insert(record)
        service.projectsOverride = { [(project, "fixture", root.path)] }
        let grant = HandsGrantAccess(grantID: "fixture", clientID: "fixture", grantLevel: 1, projectIDs: [project.uuidString])
        var settings = HandsSettings(); settings.allowedProjectIDs = [project.uuidString]
        let workspaceLanding = try service.landing(arguments: ["workspace_id": workspace.uuidString], grant: grant, settings: settings)
        check(workspaceLanding.projectID == project && workspaceLanding.workspaceID == workspace, "5 workspace-only call resolves workspace's own project")
        let workspaceCall = UUID()
        _ = service.journal(tool: "read_file", summary: "呼叫中", landing: workspaceLanding, grant: "fixture", id: workspaceCall)
        _ = service.journal(tool: "read_file", summary: "完成", landing: workspaceLanding, grant: "fixture", id: workspaceCall)
        check(try rows("hands_tool").filter { $0.id == workspaceCall.uuidString.lowercased() && $0.project == project.uuidString.lowercased() && $0.workspace == workspace.uuidString.lowercased() }.count == 1, "3,5 workspace-only call records once in workspace project")
        let snapshot = root.appendingPathComponent("flush"), pending = OSEventLog.atRoot(snapshot)
        pending.append(project: project, actor: "系統", kind: "shutdown")
        OSEventLog.flushAll()
        check(try Data(contentsOf: pending.file(project: project, at: Date())).split(separator: 10).count == 1, "9 shutdown flush persists queued events")
    }
}
#endif
