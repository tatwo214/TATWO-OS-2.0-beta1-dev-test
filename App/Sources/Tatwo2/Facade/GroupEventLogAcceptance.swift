#if DEBUG
import Foundation

@MainActor enum GroupEventLogAcceptance {
    static func run() async throws -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print("W229 \(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let live = env["TATWO2_LIVE_ROOT"] else { return false }
        let root = URL(fileURLWithPath: live).appendingPathComponent("group-events-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("coder.mjs")
        try #"""
        import readline from 'node:readline';
        const emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line);
          if(c.op==='close')process.exit(0);
          if(c.op!=='send')return;
          emit({type:'system',subtype:'init',session_id:'events-fixture',model:'gpt-6.1-sol'});
          emit({type:'system',subtype:'turn_accepted',client_turn_id:c.uuid});
          emit({type:'stream_event',client_turn_id:c.uuid,event:{type:'content_block_delta',delta:{type:'text_delta',text:'private Coder body'}}});
          emit({type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false,result:'private Coder body'});
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous; overrides["tatwo2.sidecarPath.codex"] = script.path; overrides[GroupCoderBridge.flag] = true
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let tap = W185FakeConversationTap(), catalog = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(try await tap.models().items)
        defer { ChatGPTTapModelCatalog.replace(catalog) }
        let owner = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env, tap: tap)
        defer { owner.shutdownAll() }
        let project = owner.newProject(name: "Fixture", workdir: root.path), thread = owner.newThread(in: project)
        let log = OSEventLog.atRoot(owner.store.url.deletingLastPathComponent())
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw TapError.remote("W229 fake group timeout")
        }
        func rows() throws -> [OSEvent] {
            try log.flush(); return try log.query(project: project, from: .distantPast, through: .distantFuture)
        }
        func human(_ text: String) -> Bool { owner.composerSend(threadID: thread, text: text, model: "gpt-6.1-sol", engine: .codex) }
        check(human("@@ChatGPT private human body"), "composer opens fake TAP group")
        try await until { tap.sent.count == 1 }
        let group = owner.groupBridge.sessions[thread]!
        tap.emit(.conversation(id: "events-conversation")); tap.emit(.text(messageID: "summary", full: "private TAP summary")); tap.finish()
        try await until { tap.sent.count == 2 }
        tap.emit(.text(messageID: "exchange", full: "private TAP exchange")); tap.finish()
        try await until { !owner.isRunning(thread) }
        group.exchangeLimit = 0
        let summary = group.events.first { $0.kind == "summary" }!
        check(owner.groupBridge.forwardToCoder(thread, eventSequence: summary.sequence, model: "gpt-6.1-sol", engine: .codex), "human transfer retains normal Coder routing")
        try await until { !owner.isRunning(thread) }
        check(human("@@ChatGPT 離開"), "human leave")
        check(group.state("ChatGPT") == .left, "left state")
        check(human("@@ChatGPT private return"), "human reconnect")
        try await until { tap.sent.count == 3 }
        tap.emit(.text(messageID: "return", full: "private return")); tap.finish()
        try await until { !owner.isRunning(thread) }
        tap.connection = .needsLogin
        check(human("private offline"), "offline TAP preserves Coder")
        try await until { !owner.isRunning(thread) }
        check(group.state("ChatGPT") == .away, "away state")
        tap.connection = .ready
        check(human("private recovered"), "next human reconnects TAP")
        try await until { tap.sent.count == 4 }
        tap.emit(.text(messageID: "recovered", full: "private recovered reply")); tap.finish()
        try await until { !owner.isRunning(thread) }
        let tapCalls = tap.sent.count
        check(OSEventSources.scope(origin: "dispatch", actor: "Codex/gpt-6.1-sol") {
            owner.send(threadID: thread, text: "dispatch @@ChatGPT 離開", model: "gpt-6.1-sol", engine: .codex)
        }, "dispatch native send")
        try await until { !owner.isRunning(thread) }
        let context = DispatchGitContext(id: thread, title: "fixture", workdir: root.path, worktree: root.path, branch: "fixture", deviceID: nil)
        try DispatchRoomActions.returnRoom(context, reason: "redo @@ChatGPT 離開", engine: .codex, messenger: owner)
        try await until { !owner.isRunning(thread) }
        check(tap.sent.count == tapCalls && group.state("ChatGPT") == .collaborating, "dispatch and redo cannot invoke TAP or change membership")
        let all = try rows(), journal = all.filter { $0.kind.hasPrefix("group_") }
        let kinds: Set<String> = ["message", "summary", "human-forward", "join", "leave", "away", "reconnect", "transfer"]
        let expected = group.events.filter { kinds.contains($0.kind) }
        check(journal.count == expected.count + 4, "OS event count equals group speech, transfer and lifecycle count")
        check(Set(journal.map(\.id)).count == journal.count, "each group event appears once")
        for event in expected {
            let saved = journal.first { $0.id == "group:\(thread):\(event.sequence):\(event.kind):\(event.speaker)" }
            check(saved?.actor == (event.speaker == "使用者" ? "你" : event.speaker) && saved?.size == event.text.count, "actor and size for \(event.kind) #\(event.sequence)")
            let initiated = event.speaker == "使用者" || ["join", "leave"].contains(event.kind)
            check(saved?.origin == (initiated ? "composer" : "system"), "origin for \(event.kind) #\(event.sequence)")
        }
        check(journal.filter { $0.kind == "group_join" }.count == 1 && journal.filter { $0.kind == "group_leave" }.count == 1
              && journal.filter { $0.kind == "group_away" }.count == 1 && journal.filter { $0.kind == "group_reconnect" }.count == 2
              && journal.filter { $0.kind == "group_transfer" }.count == 1 && journal.filter { $0.kind == "group_human-forward" }.count == 1, "all six group event families are covered")
        let lifecycle = journal.filter { ["group_join", "group_reconnect", "group_transfer"].contains($0.kind) }
        check(lifecycle.allSatisfy { $0.actor == ($0.kind == "group_transfer" ? "Codex" : "ChatGPT") && $0.origin == ($0.kind == "group_join" ? "composer" : "system") && $0.size == 0 }, "lifecycle actor, origin and metadata-only size")
        let sends = all.filter { $0.kind == "user_send" }
        check(sends.suffix(2).map(\.origin) == ["dispatch", "system"] && sends.suffix(2).allSatisfy { $0.actor != "你" }, "dispatch and redo have nonhuman OS send actors")
        check(all.allSatisfy { $0.project == project.uuidString.lowercased() }, "events keyed by project ID")
        check(try log.query(project: UUID(), from: .distantPast, through: .distantFuture).isEmpty, "other project cannot read group events")
        let disk = String(decoding: try Data(contentsOf: log.file(project: project, at: Date())), as: UTF8.self)
        for text in ["private human body", "private Coder body", "private TAP summary", "private TAP exchange", "private return", "private recovered reply"] {
            check(!disk.contains(text), "OS event file excludes synthetic source body")
        }
        let ledger = try group.snapshot()
        check(!String(decoding: ledger, as: UTF8.self).contains("private TAP summary") && owner.transcript(for: thread).contains { $0.text.contains("private TAP summary") }, "TAP content stays in Coder; group Ledger excludes it")
        for event in group.events { owner.eventsGroup(thread, event, source: .init(origin: "composer", actor: "你", surface: "coder")) }
        check(try rows().filter { $0.kind.hasPrefix("group_") }.count == journal.count, "duplicate callback does not append another event")
        overrides[GroupCoderBridge.flag] = false; defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        let closed = owner.newThread(in: project)
        check(owner.composerSend(threadID: closed, text: "@@ChatGPT closed", model: "gpt-6.1-sol", engine: .codex), "disabled flag still sends native")
        try await until { !owner.isRunning(closed) }
        let closedRows = try rows()
        check(owner.groupBridge.sessions[closed] == nil && tap.sent.count == tapCalls && closedRows.allSatisfy { $0.thread != closed.uuidString.lowercased() || !$0.kind.hasPrefix("group_") }, "disabled flag creates no group, TAP call or group OS event")
        print("W229 EVIDENCE group_events=\(journal.count) ledger_events=\(group.events.count)")
        print("W229 SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
