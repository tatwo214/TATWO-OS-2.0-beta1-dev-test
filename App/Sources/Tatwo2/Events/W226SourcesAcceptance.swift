#if DEBUG
import Foundation
import AppKit

@MainActor enum W226SourcesAcceptance {
    static func run(_ check: (Bool, String) -> Void) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let path = environment["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let root = URL(fileURLWithPath: path).appendingPathComponent("sources-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var env = environment; env["TATWO2_LIVE_ROOT"] = root.path
        let script = root.appendingPathComponent("fixture.mjs")
        try #"""
        import readline from 'node:readline';
        const toolName = 'mcp__fixture';
        const emit = msg => console.log(JSON.stringify({ev:'sdk',msg}));
        const rl = readline.createInterface({input:process.stdin});
        rl.on('line', line => {
          const c = JSON.parse(line);
          if (c.op === 'send') {
            const goal = {threadId:'fixture-session', objective:'fixture goal', status:'active', tokenBudget:null,
              tokensUsed:0, timeUsedSeconds:0, createdAt:1, updatedAt:2};
            emit({type:'system', subtype:'init', session_id:'fixture-session', model:'fixture-model'});
            emit({type:'system', subtype:'goal', session_id:'fixture-session', goal});
            console.log(JSON.stringify({ev:'permission_request',id:c.uuid+'-permission',tool:'write_file',input:{}}));
            emit({type:'assistant',client_turn_id:c.uuid,message:{model:'fixture-model',content:[{type:'tool_use',id:'fixture-tool',name:toolName,input:{command:'private command body'}}]}});
            emit({type:'user',client_turn_id:c.uuid,message:{content:[{type:'tool_result',tool_use_id:'fixture-tool',content:'private result body'}]}});
            emit({type:'stream_event',client_turn_id:c.uuid,event:{type:'content_block_delta',delta:{type:'text_delta',text:'private reply body'}}});
            emit({type:'system',subtype:'goal',session_id:'fixture-session',goal:{...goal,status:'complete'}});
            emit({type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false});
          } else if(c.op === 'close') process.exit(0);
        });
        rl.on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var override = prior; override["tatwo2.sidecarPath.codex"] = script.path
        defaults.setVolatileDomain(override, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        engine.autoApprove = false
        engine.permissionDecider = { _, _ in true }
        let project = engine.newProject(name: "W226 fixture", workdir: root.path)
        let thread = engine.newThread(in: project)
        engine.configureRoom(threadID: thread, parentThreadID: engine.newThread(in: project), roomBrief: "fixture", engine: "codex", cwdOverride: root.path)
        engine.select(thread)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.selectedThreadID = thread
        func until(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw NSError(domain: "W226", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
        check(OSEventSources.scope(origin: "composer", surface: "coder") { engine.send(threadID: thread, text: "private human message body", model: "gpt-6.1-sol", engine: .codex) }, "real user send hook accepts isolated fixture")
        try await until("native fixture turn") { !engine.isRunning(thread) && engine.threadRecord(thread)?.nativeGoal?.status == "complete" }
        let log = OSEventLog.atRoot(root)
        try log.flush()
        func rows() throws -> [OSEvent] { try log.query(project: project, from: .distantPast, through: .distantFuture) }
        let initial = try rows()
        let user = initial.first { $0.kind == "user_send" }
        check(initial.filter { $0.kind == "user_send" }.count == 1 && user?.actor == "你" && user?.size == 26 && user?.purpose != nil, "user source has one event, size and message ID")
        check(initial.filter { $0.kind == "turn_end" }.count == 1 && initial.first { $0.kind == "turn_end" }?.result == "通過", "turn end source has one successful event")
        check(initial.filter { $0.kind == "tool_step" }.count == 1 && initial.first { $0.kind == "tool_step" }?.used == ["@mcp__fixture"]
              && initial.first { $0.kind == "tool_step" }?.purpose == user?.purpose, "tool source has one event and human purpose")
        check(initial.filter { $0.kind == "permission_decision" }.count == 1, "approval source records decision")
        check(initial.filter { $0.kind == "goal_complete" }.count == 1 && initial.first { $0.kind == "goal_complete" }?.actor == "codex/fixture-model", "native goal source completes once")
        check(initial.contains { $0.kind == "thread_select" && $0.thread == thread.uuidString.lowercased() }, "engine and model selection use current thread")
        let goals = ThreadGoalStore(environment: env)
        let goal = try goals.update(thread) { try ThreadGoalRules.add(&$0, title: "fixture", userWords: nil, proposed: false) }
        try goals.update(thread) { try ThreadGoalRules.setStatus(&$0, id: goal.id, to: .done, evidence: nil, actor: .user) }
        try goals.update(thread) { try ThreadGoalRules.setStatus(&$0, id: goal.id, to: .done, evidence: nil, actor: .user) }
        try log.flush()
        check(try rows().filter { $0.kind == "goal_complete" && $0.purpose == user?.purpose && $0.actor == "系統" }.count == 1, "local goal transition adds once; unchanged done does not add")
        let context = DispatchGitContext(id: thread, title: "fixture", workdir: root.path, worktree: root.path, branch: "fixture", deviceID: nil)
        DispatchRoomActions.recordMerge(context, sha: "fixture-sha", messenger: engine)
        try DispatchRoomActions.returnRoom(context, reason: "fixture", engine: .codex, messenger: engine)
        try await until("returned turn") { !engine.isRunning(thread) }
        try log.flush()
        check(try rows().filter { $0.kind == "change_decision" }.map(\.result) == ["套用", "退回"], "apply and return source records exact decisions")
        let paths = HandsPaths(root: root.appendingPathComponent("hands"))
        let service = HandsService(paths: paths, runtime: HandsRuntime.current(paths: paths, environment: env))
        service.noticeSink = { _, _ in }
        check(service.journal(tool: "read_file", summary: "private external message body", landing: HandsProjectLanding(projectID: project, workspaceID: thread, reminder: nil), grant: "fixture"), "hands source accepts synthetic call")
        let jobs = BackgroundJobManager(root: root)
        var finished = false; jobs.onCompletion = { _ in finished = true }
        _ = try jobs.run(command: "/usr/bin/true", cwd: root.path, title: "fixture", threadID: thread)
        try await until("background job") { finished }
        try log.flush()
        let all = try rows()
        check(all.filter { $0.kind == "hands_tool" }.count == 1 && all.first { $0.kind == "hands_tool" }?.used == ["@read_file"], "hands hook records tool metadata without external body")
        check(all.filter { $0.kind == "job_start" || $0.kind == "job_end" }.map(\.kind) == ["job_start", "job_end"]
              && all.first { $0.kind == "job_end" }?.result == "通過" && all.first { $0.kind == "job_start" }?.purpose == engine.transcript(for: thread).last { $0.role == .user }?.id, "background source starts and ends in order under project ID")
        let humanIDs = Set(engine.transcript(for: thread).filter { $0.role == .user }.map(\.id))
        check(all.compactMap(\.purpose).allSatisfy { humanIDs.contains($0) }, "purpose is a triggering human message ID, never a job, goal or thread ID")
        check(all.allSatisfy { $0.project == project.uuidString.lowercased() }, "each source preserves project ID")
        let persisted = String(decoding: try Data(contentsOf: log.file(project: project, at: Date())), as: UTF8.self)
        check(!persisted.contains("private human message body") && !persisted.contains("private reply body") && !persisted.contains("private command body")
              && !persisted.contains("private external message body"), "events never contain source message bodies")
        let hotRow = ChatMessage(role: .user, text: String(repeating: "假", count: 10000))
        var sendMax = 0.0, endMax = 0.0
        for _ in 0..<500 {
            var start = ContinuousClock.now; engine.eventsRow(thread, hotRow)
            sendMax = max(sendMax, milliseconds(start.duration(to: .now)))
            start = .now; engine.eventsFinished(thread, succeeded: true)
            endMax = max(endMax, milliseconds(start.duration(to: .now)))
        }
        check(sendMax <= 5 && endMax <= 5, "additional send and turn end hook cost <= five ms, 500 samples")
        print("W226 METRICS send_max_ms=\(sendMax) turn_end_max_ms=\(endMax)")
        try log.flush()
        let tap = W185FakeConversationTap(), catalog = try await tap.models(), previous = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(catalog.items); defer { ChatGPTTapModelCatalog.replace(previous) }
        let tapEngine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("tap")), environment: env, tap: tap)
        defer { tapEngine.shutdownAll() }
        let general = tapEngine.newThread(in: nil)
        check(tapEngine.send(threadID: general, text: "fixture", model: ChatGPTTapModelCatalog.routeID("fixture-model"), engine: .codex), "TAP user submission also uses source hook")
        try await until("fake TAP submission") { !tap.sent.isEmpty }
        tap.emit(.conversation(id: "fixture-conversation")); tap.finish()
        try await until("fake TAP completion") { !tapEngine.isRunning(general) }
        let generalLog = OSEventLog.atRoot(tapEngine.store.url.deletingLastPathComponent()); try generalLog.flush()
        let generalRows = try generalLog.query(project: tapEngine.doc.generalProjectID, from: .distantPast, through: .distantFuture)
        check(generalRows.filter { $0.kind == "user_send" || $0.kind == "turn_end" }.count == 2 && generalRows.allSatisfy { $0.project == tapEngine.doc.generalProjectID?.uuidString.lowercased() }, "unassigned TAP events retain existing general project ID")
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
#endif
