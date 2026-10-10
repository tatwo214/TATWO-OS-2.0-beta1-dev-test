#if DEBUG
import Foundation
import SwiftUI
import Darwin

/// Actual Coder facade and TAP runner, using only fixture sidecar and synthetic TAP replies.
@MainActor enum GroupCoderAcceptance {
    static func run() async throws -> Bool {
        var failed = 0, passed = 0
        func check(_ ok: Bool, _ name: String) { if ok { passed += 1 } else { failed += 1 }; print("W225GROUP \(ok ? "PASS" : "FAIL") \(name)") }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil, env["TATWO2_LIVE_ROOT"] != nil else { return false }
        let root = URL(fileURLWithPath: env["TATWO_STAGING_ROOT"]!).appendingPathComponent("group-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("coder-fixture.mjs")
        let log = root.appendingPathComponent("sends.jsonl")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const toolName = 'fixture_step';
        const args = process.argv.slice(2), cwd = args[args.indexOf('--cwd') + 1];
        const emit = msg => console.log(JSON.stringify({ev:'sdk', msg}));
        let turn;
        readline.createInterface({input:process.stdin}).on('line', line => {
          const c = JSON.parse(line);
          if(c.op==='send') {
            turn=c.uuid;
            fs.appendFileSync(cwd+'/sends.jsonl', JSON.stringify(c)+'\n');
            emit({type:'system',subtype:'init',session_id:'group-fixture',model:'gpt-6.1-sol'});
            emit({type:'system',subtype:'turn_accepted',client_turn_id:turn});
            if(c.text.includes('hold-coder')) return;
            emit({type:'assistant',client_turn_id:turn,message:{content:[{type:'tool_use',id:turn+'-tool',name:toolName,input:{description:'fixture'}}]}});
            emit({type:'user',client_turn_id:turn,message:{content:[{type:'tool_result',tool_use_id:turn+'-tool',content:'fixture'}]}});
            emit({type:'stream_event',client_turn_id:turn,event:{type:'content_block_delta',delta:{type:'text_delta',text:'Coder fixture reply'}}});
            emit({type:'result',client_turn_id:turn,subtype:'success',is_error:false,result:'Coder fixture reply'});
          } else if(c.op==='interrupt') {
            fs.appendFileSync(cwd+'/sends.jsonl',JSON.stringify(c)+'\n');
            if(fs.existsSync(cwd+'/ignore-stop')) return;
            emit({type:'result',client_turn_id:turn,subtype:'cancelled',is_error:false,result:''});
          } else if(c.op==='close') process.exit(0);
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous
        overrides["tatwo2.sidecarPath.codex"] = script.path
        overrides[GroupCoderBridge.flag] = false
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let tap = W185FakeConversationTap()
        let catalog = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(try await tap.models().items)
        defer { ChatGPTTapModelCatalog.replace(catalog) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "Fixture", workdir: root.path), thread = engine.newThread(in: nil)
        let coder = engine.newThread(in: project)
        var observedRunning = false
        engine.onChange = { observedRunning = engine.isRunning(coder) }
        func until(_ name: String, _ condition: () -> Bool, limit: Int = 400) async throws {
            for _ in 0..<limit { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            print("W225GROUP EVIDENCE \(name) tap=\(tap.sent.count) native=\(commands().filter { $0["op"] as? String == "send" }.count) tail=\(engine.groupBridge.sessions[coder]?.events.suffix(8).map { "\($0.sequence) \($0.speaker) \($0.kind)" } ?? [])")
            throw NSError(domain: "GroupAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
        }
        func commands() -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        check(!UserDefaults(suiteName: "w225-missing-\(UUID())")!.bool(forKey: GroupCoderBridge.flag), "missing flag is false")
        check(!defaults.bool(forKey: GroupCoderBridge.flag), "flag defaults off")
        check(engine.composerSend(threadID: coder, text: "@@ChatGPT closed", model: "gpt-6.1-sol", engine: .codex), "disabled send accepted")
        try await until("disabled native finished") { !engine.isRunning(coder) }
        check(tap.sent.isEmpty && engine.groupBridge.sessions.isEmpty && commands().first?["text"] as? String == "@@ChatGPT closed", "flag off preserves native send exactly")
        overrides[GroupCoderBridge.flag] = true; defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        check(engine.composerSend(threadID: coder, text: "@@ChatGPT join-human", model: "gpt-6.1-sol", engine: .codex), "group join accepted")
        try await until("both got human") { tap.sent.count == 1 && commands().filter { $0["op"] as? String == "send" }.count == 2 && engine.transcript(for: coder).contains { $0.text == "Coder fixture reply" } }
        check(engine.groupBridge.sessions[coder]?.events.contains { $0.speaker == "Codex" && $0.text == "Coder fixture reply" } == true, "Coder completes while ChatGPT pending")
        check(engine.isRunning(coder), "pending TAP keeps stop available")
        check(tap.sent[0].text.hasPrefix("現在第") && tap.sent[0].text.contains("〔TATWO・Coder Fixture〕") && tap.sent[0].text.contains("read_session(thread_id=") && !tap.sent[0].text.contains("@@ChatGPT closed"), "join uses time, speaker prefix and tool pointer without old content")
        tap.emit(.conversation(id: "group-conversation"))
        tap.emit(.text(messageID: "summary", full: "ChatGPT summary password=fixture-only-secret")); tap.finish()
        try await until("one exchange both sides") { tap.sent.count == 2 && commands().filter { $0["op"] as? String == "send" }.count == 2 }
        let lastNative = commands().last { $0["op"] as? String == "send" }?["text"] as? String ?? ""
        check(lastNative.contains("@@ChatGPT") && !lastNative.contains("fixture-only-secret"), "primary context remains; TAP waits for human before Coder sees it")
        check(tap.sent[1].conversationID == "group-conversation", "one Coder thread keeps same ChatGPT conversation")
        tap.emit(.text(messageID: "exchange", full: "ChatGPT proposal")); tap.finish()
        try await until("join idle") { !engine.isRunning(coder) }
        check(engine.groupBridge.sessions[coder]?.collaborating.contains("ChatGPT") == true && engine.transcript(for: coder).contains { $0.text.hasPrefix("ChatGPT summary") }, "summary in original thread and collaborating")
        check(engine.transcript(for: coder).filter { $0.role == .user }.count == 2, "automatic relay does not fabricate human rows")
        check(!observedRunning && !engine.hasRunningWork, "completion updates facade observers after moderator becomes idle")
        check(engine.groupBridge.sessions[coder]?.events.contains { $0.kind == "step" && $0.text.contains("fixture_step") } == true, "native tool steps enter shared event ledger")
        check(engine.groupBridge.sessions[coder]?.exchange() == false, "second automatic exchange blocked")
        var samples: [Int: [String: Int]] = [:]
        for round in 2...30 {
            let startTap = tap.sent.count, startNative = commands().filter { $0["op"] as? String == "send" }.count
            let human = String(format: "human-%02d", round)
            check(engine.composerSend(threadID: coder, text: human, model: "gpt-6.1-sol", engine: .codex), "round \(round) accepted")
            try await until("round \(round) initial") { tap.sent.count == startTap + 1 && commands().filter { $0["op"] as? String == "send" }.count == startNative + 1 }
            tap.emit(.text(messageID: "fixed", full: "Tap fixture reply")); tap.finish()
            try await until("round \(round) exchange") { tap.sent.count == startTap + 2 && commands().filter { $0["op"] as? String == "send" }.count == startNative + 1 }
            tap.emit(.text(messageID: "fixed", full: "Tap fixture reply")); tap.finish()
            try await until("round \(round) idle") { !engine.isRunning(coder) }
            let nativeText = commands().filter { $0["op"] as? String == "send" }.suffix(1).compactMap { $0["text"] as? String }
            let tapText = tap.sent.suffix(2).map(\.text)
            if round == 2 { check(nativeText[0].contains("ChatGPT 說") && GroupPreflightAcceptance.hasFence(nativeText[0]) && !nativeText[0].contains("fixture-only-secret"), "TAP redaction and fences reach Coder on next human turn") }
            check(nativeText.filter { $0.contains(human) }.count == 1 && tapText.filter { $0.contains(human) }.count == 1, "round \(round) human arrives once per AI")
            if [2,10,30].contains(round), let account = engine.groupBridge.sessions[coder]?.accounting[round] {
                samples[round] = account.mapValues(\.sent)
                for id in ["使用者", "Codex", "ChatGPT"] { print("W225GROUP ACCOUNT round=\(round) participant=\(id) sent=\(account[id]?.sent ?? 0) received=\(account[id]?.received ?? 0)") }
                check(account["Codex"]?.sent == nativeText.reduce(0) { $0 + $1.count } && account["ChatGPT"]?.sent == tapText.reduce(0) { $0 + $1.count }, "round \(round) accounting matches actual wire lengths including context and prefix")
            }
        }
        for id in ["Codex", "ChatGPT"] { check(Double(samples[30]?[id] ?? 0) <= Double(samples[2]?[id] ?? 0) * 1.5, "\(id) actual round 30/2 <= 1.5") }
        let groupFile = engine.store.url.deletingLastPathComponent().appendingPathComponent("group-\(coder).json")
        let saved = GroupTurnEngine(threadID: coder, primary: "Codex", participants: [])
        try saved.restore(Data(contentsOf: groupFile))
        check(saved.accounting[30]?["Codex"]?.sent == samples[30]?["Codex"], "accounting stored beside event ledger and readable")
        check(engine.composerSend(threadID: coder, text: "second-human", model: "gpt-6.1-sol", engine: .codex), "second human accepted")
        try await until("second both received") { tap.sent.count == 61 && engine.groupBridge.sessions[coder]?.events.contains { $0.turn == engine.groupBridge.sessions[coder]?.turn && $0.speaker == "Codex" && $0.kind == "message" } == true }
        check(!tap.sent[60].text.contains("加入") && !tap.sent[60].text.contains("join-human") && tap.sent[60].conversationID == "group-conversation", "second turn sends delta without rejoin")
        tap.emit(.failed("fixture error"))
        try await until("failure idle") { !engine.isRunning(coder) }
        check(engine.transcript(for: coder).contains { $0.text == "ChatGPT：fixture error" } && tap.sent.count == 61, "TAP failure in place, native done, no automatic retry")
        engine.groupBridge.timeout = 0.06
        check(engine.composerSend(threadID: thread, text: "@@ChatGPT timeout-human", model: "gpt-6.1-sol", engine: .codex), "timeout join accepted")
        try await until("timeout idle") { !engine.isRunning(thread) }
        check(engine.groupBridge.sessions[thread]?.events.contains { $0.speaker == "ChatGPT" && $0.kind == "failure" && $0.text.contains("逾時") } == true, "TAP timeout isolated")
        try Data().write(to: root.appendingPathComponent("ignore-stop"))
        check(engine.composerSend(threadID: coder, text: "hold-coder", model: "gpt-6.1-sol", engine: .codex), "stop round accepted")
        try await until("stop both running") { tap.sent.count == 63 && engine.groupBridge.sessions[coder]?.busy == true }
        let start = Date(), request = tap.sent.last!.requestID
        engine.stop(threadID: coder)
        try await until("both stopped", { !engine.isRunning(coder) && tap.stopped.contains(request) }, limit: 310)
        check(Date().timeIntervalSince(start) < 3, "unresponsive Coder and TAP stop within 3 seconds")
        engine.shutdownAll()
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env, tap: tap)
        defer { reopened.shutdownAll() }
        let ledgerURL = root.appendingPathComponent("live/group-\(coder).json")
        let beforeDelivery = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as! [String: Any]
        let cache = GroupCoderBridge(owner: reopened, tap: tap)
        for _ in 0..<100 { check(cache.proposalSession(coder) == nil, "W352 cold normal ledger stays outside sandbox proposals") }
        check(cache.proposalLedgerReads == 1, "W352 unchanged normal ledger read once across 100 redraws")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: ledgerURL.path)
        check(cache.proposalSession(coder) == nil && cache.proposalLedgerReads == 2, "W352 ledger mtime invalidates negative cache")
        let cacheThread = reopened.newThread(in: project), cacheURL = root.appendingPathComponent("live/group-\(cacheThread).json")
        try Data(contentsOf: ledgerURL).write(to: cacheURL)
        check(cache.proposalSession(cacheThread) == nil, "W352 cache detects another normal ledger")
        var sandboxMetadata = beforeDelivery; sandboxMetadata["sandboxOnly"] = true
        try JSONSerialization.data(withJSONObject: sandboxMetadata).write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(4)], ofItemAtPath: cacheURL.path)
        check(cache.proposalSession(cacheThread)?.participants.isEmpty == true, "W352 changed normal ledger restores as sandbox")

        // Cold App receives a real Hands sandbox result before the first composer send.
        let bots = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills")); await bots.ready()
        let model = ChatPageModel(environment: env, botCoreFixture: (reopened, BotStore(library: bots)))
        let paths = HandsPaths(root: root.deletingLastPathComponent().appendingPathComponent("sandbox-hands"))
        var runtime = HandsRuntime.current(paths: paths, environment: env)
        runtime.appSupport = root.deletingLastPathComponent().appendingPathComponent("sandbox-support").path
        let service = HandsService(paths: paths, runtime: runtime)
        service.attach(model: model); service.deviceIDOverride = HandsConnectAcceptance.hostID
        _ = try service.updateSettings { $0.enabled = true; $0.level = 2; $0.allProjects = true; $0.hostDeviceID = HandsConnectAcceptance.hostID; $0.publicHost = HandsConnectAcceptance.publicHost }
        let device = "w352-synthetic-sandbox", lane = service.sandboxLane
        lane.deviceCheck = { $0 == device }
        let client = HandsConnectAcceptance.FakeChatGPT(service: service); try client.register(); try lane.pair(device)
        let begin = try service.handle(method: "hands_auth", params: ["op": "authorize_begin", "client_id": client.clientID, "redirect_uri": client.redirect,
            "code_challenge": client.challenge, "code_challenge_method": "S256", "state": client.state, "scope": "sandbox"])
        client.transaction = begin["transaction_id"] as? String
        let code = try client.submit(service.auth.pendingCard!.pairingCode)
        let token = try service.handle(method: "hands_auth", params: ["op": "token", "grant_type": "authorization_code", "code": code, "code_verifier": client.verifier,
            "client_id": client.clientID, "redirect_uri": client.redirect])["access_token"] as! String
        try await until("sandbox classification ready") { !service.classificationPending }
        let job = try await Task.detached { try lane.queue(device, thread: coder, instruction: "Report only", files: [], artifacts: []) }.value
        func sandboxCall(_ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
            try await Task.detached { try service.handle(method: "hands_call", params: ["access_token": token, "name": name,
                "arguments": ["issued_at": Date().timeIntervalSince1970].merging(args) { _, new in new }, "request_id": UUID().uuidString]) }.value
        }
        let fetched = try await sandboxCall("sandbox_fetch_job")
        let payload = try JSONSerialization.jsonObject(with: Data(((fetched["content"] as! [[String: Any]])[0]["text"] as! String).utf8)) as! [String: Any]
        let delivered = try await sandboxCall("sandbox_post_result", ["job_id": job, "lease": payload["lease"]!, "report": "Cold external sandbox report"])
        check(delivered["isError"] as? Bool == false, "W352 real sandbox delivery accepted before first post-restart message")
        let sandboxGroup = reopened.groupBridge.sessions[coder]!, resultSequence = sandboxGroup.events.last!.sequence
        let afterDelivery = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as! [String: Any]
        check(sandboxGroup.participants.contains { $0.id == "ChatGPT" } && sandboxGroup.state("ChatGPT") == .collaborating,
              "W352 cold sandbox delivery restores collaboration participants and membership")
        check(afterDelivery["sandboxOnly"] as? Bool == false && Set(afterDelivery["collaborating"] as? [String] ?? []) == Set(beforeDelivery["collaborating"] as? [String] ?? []),
              "W352 cold sandbox delivery preserves collaborating and sandboxOnly flag")
        check(sandboxGroup.events.last?.sequence == resultSequence, "W352 cold sandbox delivery appends to original ledger")
        let tapBefore = tap.sent.count
        check(reopened.composerSend(threadID: coder, text: "after-reopen", model: "gpt-6.1-sol", engine: .codex), "restored collaboration accepts ordinary human without mention")
        try await until("reopened send") { tap.sent.count == tapBefore + 1 }
        check(!tap.sent.last!.text.contains("加入") && tap.sent.last!.conversationID == "group-conversation", "reopen preserves joined membership and one-to-one mapping")
        tap.emit(.text(messageID: "reopened", full: "Tap fixture reply")); tap.finish()
        try await until("reopened exchange") { tap.sent.count == tapBefore + 2 }
        tap.emit(.text(messageID: "reopened", full: "Tap fixture reply")); tap.finish()
        try await until("reopened idle") { !reopened.isRunning(coder) }
        check(reopened.groupBridge.sessions[coder]?.accounting[30]?["Codex"]?.sent == samples[30]?["Codex"], "reopen preserves previous per-turn accounting")
        try await departureCheck(engine: reopened, tap: tap, project: project, root: root, env: env, check: check)
        try await podCheck(root: root, check: check)
        print("W225GROUP SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }
    private static func departureCheck(engine: ChatLiveEngine, tap: W185FakeConversationTap, project: UUID, root: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        let thread = engine.newThread(in: project)
        func sends() -> Int {
            ((try? String(contentsOf: root.appendingPathComponent("sends.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.filter { $0["op"] as? String == "send" }.count
        }
        func human(_ text: String) -> Bool { engine.composerSend(threadID: thread, text: text, model: "gpt-6.1-sol", engine: .codex) }
        var waitingStep = 0
        func until(_ done: () -> Bool) async throws {
            waitingStep += 1
            for _ in 0..<500 { if done() { return }; try await Task.sleep(for: .milliseconds(10)) }
            print("W341 EVIDENCE step=\(waitingStep) native=\(sends()) tap=\(tap.sent.count) events=\(engine.groupBridge.sessions[thread]?.events.suffix(8).map { "\($0.speaker) \($0.kind) \($0.text.prefix(100))" } ?? []) rows=\(engine.transcript(for: thread).suffix(5).map { $0.text.prefix(100) })")
            throw TapError.remote("W341 fixture timeout")
        }
        let initialNative = sends(), initialTap = tap.sent.count
        check(human(" @- \n"), "W341 inactive departure consumed")
        check(engine.transcript(for: thread).last?.text == "這串沒有在協作" && engine.transcript(for: thread).allSatisfy { $0.role != .user } && engine.groupBridge.sessions[thread] == nil && sends() == initialNative && tap.sent.count == initialTap, "W341 inactive departure only creates system hint")
        for invalid in ["email @-", "@-ChatGPT more", "@- ChatGPT", "@-ChatGPT\nnext"] {
            check(GroupTurnEngine.departure(invalid) == nil, "W341 whole sentence required: " + invalid)
        }
        check(ChatComposerSigil.query("@-") == nil, "W341 departure does not open MCP suggestions")
        check(human("@@ChatGPT"), "W341 starts collaboration")
        try await until { tap.sent.count == initialTap + 1 && sends() == initialNative + 1 }
        tap.emit(.conversation(id: "w341-conversation")); tap.emit(.text(messageID: "join", full: "W341 synthetic summary")); tap.finish()
        try await until { tap.sent.count == initialTap + 2 }
        tap.emit(.text(messageID: "exchange", full: "W341 synthetic reply")); tap.finish()
        try await until { !engine.isRunning(thread) }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.mode = .chat; model.selectedThreadID = thread
        let artifacts = URL(fileURLWithPath: env["TATWO2_SELFTEST_ARTIFACTS"]!)
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }
        func render(_ phase: String) async throws {
            for dark in [false, true] {
                theme.use(dark ? .aurora : .fable5)
                let view = VStack(spacing: 8) {
                    if let group = engine.groupBridge.sessions[thread], !group.participants.isEmpty { ChatGroupParticipants(group: group) }
                    ChatPage(model: model).transcript(contentMaxWidth: 840)
                }
                guard let shot = GlobalDMChatAcceptance.renderSync(view, size: CGSize(width: 1000, height: 720), scheme: dark ? .dark : .light) else { throw TapError.notReady }
                await W214Acceptance.settle(shot)
                let text = W214Acceptance.text(shot)
                check(text.contains(phase == "participants" ? "打 @- 結束協作" : "已結束三方協作"), "W341 " + phase + " visible " + (dark ? "aurora" : "fable5"))
                try W214Acceptance.save(shot, "w341-" + phase + (dark ? "-aurora" : "-fable5"), artifacts); shot.close()
            }
        }
        try await render("participants")
        check(engine.groupBridge.route(threadID: thread, text: "@-", model: nil, engine: .codex, systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil, source: .system) == nil && engine.groupBridge.sessions[thread]?.state("ChatGPT") == .collaborating, "W341 system source cannot close active collaboration")
        let users = engine.transcript(for: thread).filter { $0.role == .user }.count
        let beforeNative = sends(), beforeTap = tap.sent.count
        check(engine.composerSend(threadID: thread, text: " @- ", model: ChatGPTTapModelCatalog.routeID("fixture-model"), engine: .codex), "W341 ends collaboration after selecting TAP model")
        check(engine.groupBridge.sessions[thread]?.participants.isEmpty == true && !engine.isRunning(thread) && engine.transcript(for: thread).last?.text == "已結束三方協作" && engine.transcript(for: thread).filter { $0.role == .user }.count == users && sends() == beforeNative && tap.sent.count == beforeTap, "W341 end stops session without model send or user row")
        try await render("ended")
        check(human("ordinary-after-end"), "W341 ordinary conversation after end")
        try await until { sends() == beforeNative + 1 && !engine.isRunning(thread) }
        check(tap.sent.count == beforeTap, "W341 ordinary conversation uses only primary")
        check(human("@@ChatGPT"), "W341 reopens after end")
        try await until { tap.sent.count == beforeTap + 1 && sends() == beforeNative + 2 }
        let stopped = tap.sent.last!.requestID
        let midNative = sends(), midTap = tap.sent.count, midUsers = engine.transcript(for: thread).filter { $0.role == .user }.count
        check(human("@-ChatGPT"), "W341 named departure while busy")
        try await until { !engine.isRunning(thread) }
        check(engine.groupBridge.sessions[thread]?.participants.isEmpty == true && engine.transcript(for: thread).last?.text == "ChatGPT 已離開協作" && tap.stopped.contains(stopped) && sends() == midNative && tap.sent.count == midTap && engine.transcript(for: thread).filter { $0.role == .user }.count == midUsers, "W341 last named participant leaves without sending")
        check(human("@-"), "W341 repeated departure consumed")
        check(engine.transcript(for: thread).last?.text == "這串沒有在協作", "W341 repeated departure says inactive")
        let restored = GroupCoderBridge(owner: engine, tap: tap)
        check(restored.proposalSession(thread)?.participants.isEmpty == true && restored.route(threadID: thread, text: "ordinary", model: nil, engine: .codex, systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil, source: .init(origin: "composer", actor: "使用者", surface: nil)) == nil, "W341 ended ledger stays native after restart")
        let coldThread = engine.newThread(in: project)
        check(engine.composerSend(threadID: coldThread, text: "@@ChatGPT hold-coder", model: "gpt-6.1-sol", engine: .codex), "W341 cold ledger fixture starts")
        try await until { engine.groupBridge.sessions[coldThread]?.busy == true }
        engine.groupBridge.stop(coldThread)
        let cold = GroupCoderBridge(owner: engine, tap: tap)
        check(cold.route(threadID: coldThread, text: "@-", model: nil, engine: .codex, systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil, source: .init(origin: "composer", actor: "使用者", surface: nil)) == true && cold.sessions[coldThread]?.participants.isEmpty == true, "W341 unloaded active ledger can end")
        let sourceThread = engine.newThread(in: project)
        check(engine.groupBridge.route(threadID: sourceThread, text: "@-", model: nil, engine: .codex, systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil, source: .system) == nil && engine.transcript(for: sourceThread).isEmpty, "W341 system source cannot end or create hint")
        engine.groupBridge.taps.append(GroupTapAdapter(id: "Other", invoke: { _, _, done in done(.success("synthetic other")) }, stop: { _ in }))
        check(human("@@ChatGPT @@Other"), "W341 multiple participants join")
        try await until { engine.groupBridge.sessions[thread]?.state("Other") == .collaborating }
        check(human("@-Other") && engine.groupBridge.sessions[thread]?.participants.contains { $0.id == "ChatGPT" } == true && engine.groupBridge.sessions[thread]?.participants.contains { $0.id == "Other" } == false, "W341 named departure keeps remaining collaborator")
        check(human("@-Unknown") && engine.groupBridge.sessions[thread]?.participants.contains { $0.id == "ChatGPT" } == true, "W341 unknown participant does not end group")
        check(human("@-"), "W341 whole group ends after partial departure")
        let alone = engine.newThread(in: project)
        check(engine.composerSend(threadID: alone, text: "@@Other", model: "gpt-6.1-sol", engine: .codex), "W341 only one of the available TAPs joins")
        try await until { engine.groupBridge.sessions[alone]?.state("Other") == .collaborating }
        check(engine.groupBridge.sessions[alone]?.state("ChatGPT") == .unjoined && engine.composerSend(threadID: alone, text: "@-Other", model: "gpt-6.1-sol", engine: .codex) && engine.groupBridge.sessions[alone]?.participants.isEmpty == true, "W341 unjoined candidates do not keep collaboration active")
        engine.markControllerThread(sourceThread, fingerprint: "fixture-controller")
        check(engine.groupBridge.route(threadID: sourceThread, text: "@-", model: nil, engine: .codex, systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil, source: .init(origin: "composer", actor: "使用者", surface: nil)) == nil && engine.groupBridge.sessions[sourceThread] == nil, "W341 managed conversation gate unchanged")
        let tradeFolder = root.appendingPathComponent("trading-fixture")
        try FileManager.default.createDirectory(at: tradeFolder, withIntermediateDirectories: true)
        let trade = engine.newThread(in: engine.newProject(name: "交易驗收", workdir: tradeFolder.path))
        check(engine.groupBridge.route(threadID: trade, text: "@-", model: nil, engine: .codex, systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil, source: .init(origin: "composer", actor: "使用者", surface: nil)) == nil && engine.groupBridge.sessions[trade] == nil && engine.transcript(for: trade).isEmpty, "W341 trading project gate unchanged")
    }
    private static func podCheck(root: URL, check: (Bool, String) -> Void) async throws {
        let pod = DispatchTapPod()
        let tap = ChatGPTTap(transport: pod)
        let lease = tap.acquireLease(backgroundWork: true)
        defer { tap.releaseLease(lease); tap.sleep() }
        try await tap.readyForSend()
        let mapper = TapProjectMapper(tap: tap, inboxFolder: root.appendingPathComponent("pod-inbox"))
        ChatGPTTapModelCatalog.replace([])
        let runner = ChatGPTTapTurnRunner(tap: tap, mapper: mapper)
        var text = "", done = false
        let payload = "〔TATWO・Coder Pod Fixture〕你：加入；read_session(thread_id=fixture, cursor=0)"
        runner.start(threadID: UUID(), project: nil, title: "Fixture", text: payload, routeID: ChatGPTTapModelCatalog.routeID("unavailable"), effort: nil, attachmentPaths: [], history: [], group: true,
                     notice: { _ in }, event: { event in
            if case .text(_, let full) = event { text = full }
            if case .finished = event { done = true }
        })
        for _ in 0..<200 where pod.sends.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        check(pod.sends.last?["text"] as? String == payload && pod.sends.last?["model"] as? String == "fixture-model", "actual Pod wire preserves group delta without legacy history prefix")
        pod.stream("accepted", ["conversationID": "11111111-1111-4111-8111-111111111111"])
        pod.stream("text", ["messageID": "summary", "full": "fake read_session summary"])
        pod.stream("finished")
        for _ in 0..<200 where !done { try await Task.sleep(for: .milliseconds(10)) }
        check(done && text == "fake read_session summary", "fake Pod read_session summary traverses actual TAP runner")
    }

}
#endif
