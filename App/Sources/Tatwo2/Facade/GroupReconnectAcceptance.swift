#if DEBUG
import Foundation

@MainActor enum GroupReconnectAcceptance {
    static func run() async throws -> Bool {
        var failed = 0, passed = 0
        func check(_ ok: Bool, _ name: String) { if ok { passed += 1 } else { failed += 1 }; print("W225B2 \(ok ? "PASS" : "FAIL") \(name)") }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let live = env["TATWO2_LIVE_ROOT"] else { return false }
        let root = URL(fileURLWithPath: live).appendingPathComponent("group-reconnect-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("coder-fixture.mjs"), log = root.appendingPathComponent("sends.jsonl")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args=process.argv.slice(2), cwd=args[args.indexOf('--cwd')+1];
        const emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
        let turn, held;
        const finish=()=>{
          if(!held) return;
          const id=held; held=null;
          emit({type:'stream_event',client_turn_id:id,event:{type:'content_block_delta',delta:{type:'text_delta',text:'Coder fixture reply'}}});
          emit({type:'result',client_turn_id:id,subtype:'success',is_error:false,result:'Coder fixture reply'});
        };
        fs.watch(cwd,(_,file)=>{if(file==='release') finish()});
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line);
          fs.appendFileSync(cwd+'/sends.jsonl',JSON.stringify(c)+'\n');
          if(c.op==='send') {
            turn=c.uuid;
            emit({type:'system',subtype:'init',session_id:'reconnect-fixture',model:'gpt-6.1-sol'});
            emit({type:'system',subtype:'turn_accepted',client_turn_id:turn});
            held=turn;
            if(!c.text.includes('hold-native')) finish();
          } else if(c.op==='interrupt') {
            held=null;
            emit({type:'result',client_turn_id:turn,subtype:'cancelled',is_error:false,result:''});
          } else if(c.op==='close') process.exit(0);
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
        var now = Date(timeIntervalSince1970: 1_791_187_200)
        owner.groupBridge.clock = { now }
        var extraSends: [String] = []
        owner.groupBridge.taps.append(GroupTapAdapter(id: "OtherTap", invoke: { _, text, done in extraSends.append(text); done(.success("other TAP reply")) }, stop: { _ in }))
        let project = owner.newProject(name: "Fixture", workdir: root.path), thread = owner.newThread(in: project)
        func commands() -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func nativeCount() -> Int { commands().filter { $0["op"] as? String == "send" }.count }
        func until(_ name: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            print("W225B2 FAIL timeout \(name) native=\(nativeCount()) tap=\(tap.sent.count)")
            throw TapError.remote(name)
        }
        check(owner.composerSend(threadID: thread, text: "@@OtherTap join", model: "gpt-6.1-sol", engine: .codex), "registry fake TAP joins through actual facade")
        try await until("extra TAP joined") { !owner.isRunning(thread) }
        let group = owner.groupBridge.sessions[thread]!
        group.exchangeLimit = 0
        check(extraSends.count == 2 && group.state("OtherTap") == .collaborating && tap.sent.isEmpty, "fake TAP speaks and exchanges; ChatGPT stays uncalled")
        check((commands().first { $0["op"] as? String == "send" }?["text"] as? String)?.contains("OtherTap（未加入，讀到第") == true, "primary context comes from runtime roster and cursors on first join")
        let extraCalls = extraSends.count, natives = nativeCount()
        check(owner.composerSend(threadID: thread, text: "@@OtherTap 離開", model: "gpt-6.1-sol", engine: .codex), "generic leave accepted through route")
        check(extraSends.count == extraCalls && nativeCount() == natives && group.state("OtherTap") == .left, "generic leave has zero AI calls")
        _ = owner.composerSend(threadID: thread, text: "@@Missing", model: "gpt-6.1-sol", engine: .codex)
        check(owner.transcript(for: thread).contains { $0.text == "這台沒有連這個 TAP" }, "unknown TAP reason appears in original transcript")
        try await until("unknown original delivered") { !owner.isRunning(thread) }
        check(nativeCount() == natives + 1 && commands().last { $0["op"] as? String == "send" }?["text"] as? String != nil && (commands().last { $0["op"] as? String == "send" }?["text"] as? String ?? "").contains("@@Missing") && extraSends.count == extraCalls && tap.sent.isEmpty, "unknown original reaches primary intact without TAP calls")
        _ = owner.composerSend(threadID: thread, text: "@@ChatGPT join", model: "gpt-6.1-sol", engine: .codex)
        try await until("ChatGPT join send") { tap.sent.count == 1 }
        check(tap.sent[0].model == "fixture-model" && tap.sent[0].effort == "tap-light", "group chooses Light instead of catalog default Heavy")
        check(tap.sent[0].text.hasPrefix("現在第") && tap.sent[0].text.contains("〔TATWO・Coder Fixture〕"), "actual TAP wire starts with engine clock line")
        tap.emit(.conversation(id: "reconnect-conversation")); tap.emit(.text(messageID: "summary", full: "TAP join summary")); tap.finish()
        try await until("ChatGPT joined") { !owner.isRunning(thread) }
        let joinedCursor = group.cursors["ChatGPT"]!, joinCalls = tap.sent.count
        _ = owner.composerSend(threadID: thread, text: "hold-native", model: "gpt-6.1-sol", engine: .codex)
        try await until("current native held") { nativeCount() == natives + 3 && tap.sent.count == joinCalls + 1 }
        let beforeQueued = nativeCount(), beforeTap = tap.sent.count
        var queuedDeliveries: Set<String> = []
        func enqueue(_ text: String) -> Bool {
            owner.composerSend(threadID: thread, text: text, model: "gpt-6.1-sol", engine: .codex, systemPrompt: nil, attachments: [], reasoningEffort: nil, serviceTier: nil, ultrawork: nil, delivery: { result in
                if result == .delivered { queuedDeliveries.insert(text) }
            })
        }
        check(enqueue("queued-one") && enqueue("queued-two"), "busy native facade accepts both queued messages")
        check(nativeCount() == beforeQueued && tap.sent.count == beforeTap && !commands().contains { $0["op"] as? String == "interrupt" }, "queue leaves active native and TAP uninterrupted")
        try Data("release".utf8).write(to: root.appendingPathComponent("release"))
        tap.emit(.text(messageID: "current", full: "current finishes")); tap.finish()
        try await until("merged next round sent") { nativeCount() == beforeQueued + 1 && tap.sent.count == beforeTap + 1 }
        let mergedNative = commands().last { $0["op"] as? String == "send" }?["text"] as? String ?? ""
        check(mergedNative.contains("queued-one") && mergedNative.contains("queued-two") && tap.sent.last!.text.contains("queued-two") && group.events.last { $0.speaker == "使用者" }?.text == "queued-one\nqueued-two", "next native and TAP receive one merged human turn")
        check(queuedDeliveries == ["queued-one", "queued-two"], "merged native delivery acknowledges every queued caller")
        _ = owner.composerSend(threadID: thread, text: "@@ChatGPT 離開", model: "gpt-6.1-sol", engine: .codex)
        check(group.state("ChatGPT") == .collaborating && tap.sent.count == beforeTap + 1, "leave command while TAP replying waits and sends nothing")
        tap.emit(.text(messageID: "leaving", full: "last TAP words")); tap.finish()
        try await until("TAP left") { !owner.isRunning(thread) }
        check(group.state("ChatGPT") == .left && group.membership["ChatGPT"]!.handoff.contains("last TAP words"), "facade preserves final reply in OS handoff")
        now += 600
        let idleCalls = tap.sent.count
        check(tap.sent.count == idleCalls && group.cursors["ChatGPT"]! >= joinedCursor, "idle clock advance sends nothing")
        _ = owner.composerSend(threadID: thread, text: "@@ChatGPT return", model: "gpt-6.1-sol", engine: .codex)
        try await until("reconnect opening") { tap.sent.count == idleCalls + 1 }
        check(tap.sent.last!.conversationID == "reconnect-conversation" && tap.sent.last!.text.contains("交接：") && !tap.sent.last!.text.contains("請先用") && tap.sent.last!.text.count <= 2400, "actual adapter reconnect uses same conversation and bounded opening")
        tap.emit(.text(messageID: "return", full: "reconnected")); tap.finish()
        try await until("reconnect finished") { !owner.isRunning(thread) }
        _ = owner.composerSend(threadID: thread, text: "first error", model: "gpt-6.1-sol", engine: .codex)
        try await until("first error send") { tap.sent.count == idleCalls + 2 }
        tap.emit(.failed("fixture error")); try await until("first error done") { !owner.isRunning(thread) }
        _ = owner.composerSend(threadID: thread, text: "second error", model: "gpt-6.1-sol", engine: .codex)
        try await until("second error send") { tap.sent.count == idleCalls + 3 }
        tap.emit(.failed("fixture error")); try await until("second error done") { !owner.isRunning(thread) }
        check(group.state("ChatGPT") == .away && owner.transcript(for: thread).contains { $0.text.contains("fixture error") }, "two adapter errors persist away state with visible reason")
        tap.connection = .needsLogin
        _ = owner.composerSend(threadID: thread, text: "offline primary", model: "gpt-6.1-sol", engine: .codex)
        try await until("offline primary done") { !owner.isRunning(thread) }
        check(tap.sent.count == idleCalls + 3, "offline primary runs without invoking away TAP")
        tap.connection = .ready; now += 600
        check(tap.sent.count == idleCalls + 3, "connection restoration and ten idle minutes make no calls")
        _ = owner.composerSend(threadID: thread, text: "recovered", model: "gpt-6.1-sol", engine: .codex)
        try await until("automatic return") { tap.sent.count == idleCalls + 4 }
        check(tap.sent.last!.text.contains("交接：") && tap.sent.last!.conversationID == "reconnect-conversation", "away TAP automatically rejoins next human")
        let stopState = group.state("ChatGPT"), start = Date(), request = tap.sent.last!.requestID
        owner.stop(threadID: thread)
        try await until("both stopped") { !owner.isRunning(thread) && tap.stopped.contains(request) }
        check(Date().timeIntervalSince(start) < 3 && group.state("ChatGPT") == stopState, "stop completes within three seconds without disconnect")
        tap.removeConversation("reconnect-conversation")
        let beforeMissing = tap.sent.count
        _ = owner.composerSend(threadID: thread, text: "@@ChatGPT after deletion", model: "gpt-6.1-sol", engine: .codex)
        try await until("confirmed missing conversation") { tap.sent.count == beforeMissing + 1 }
        check(tap.sent.last!.conversationID == nil && tap.sent.last!.text.contains("請先用") && !tap.sent.last!.text.contains("交接："), "confirmed missing ChatGPT conversation uses first join instead of reconnect")
        check(group.accounting[group.turn]?["ChatGPT"]?.sent == tap.sent.last!.text.count, "replacement first join accounting matches actual wire length")
        tap.emit(.conversation(id: "replacement-conversation")); tap.emit(.text(messageID: "new-summary", full: "new join summary")); tap.finish()
        try await until("replacement summary done") { !owner.isRunning(thread) }
        check(group.events.contains { $0.text == "new join summary" && $0.kind == "summary" }, "deleted conversation rejoin records one new summary")
        try await speedPod(root, check: check)
        print("W225B2 SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }

    private static func speedPod(_ root: URL, check: (Bool, String) -> Void) async throws {
        let slow = TapModel(id: "slow", title: "Pro", detail: ""), fast = TapModel(id: "fast", title: "Instant", detail: "")
        check(GroupFastModel.choose([slow, fast])?.model.id == "fast", "fast model wins regardless of list order")
        let tiers = TapModel(id: "version:latest", title: "Latest", detail: "", efforts: [TapEffort(id: "slow|high", title: "高", level: "High"), TapEffort(id: "fast", title: "即時", level: "Instant")])
        check(GroupFastModel.choose([tiers])?.effort == "fast", "version preset Instant uses exact TAP effort ID")
        check(GroupFastModel.choose([TapModel(id: "research", title: "Deep Research", detail: "")]) == nil && GroupFastModel.choose([]) == nil, "empty or research-only catalogs cannot send group work")
        let fallback = TapModel(id: "thinking", title: "Thinking", detail: "", efforts: [TapEffort(id: "high", title: "High"), TapEffort(id: "light", title: "Light")])
        check(GroupFastModel.choose([fallback])?.effort == "light", "without Instant choose lowest exposed effort tier")
        let highOnly = TapModel(id: "thinking", title: "Thinking", detail: "", efforts: [TapEffort(id: "max", title: "Extra High"), TapEffort(id: "extended", title: "High")])
        check(GroupFastModel.choose([highOnly])?.effort == "extended", "High is faster than Extra High even when Extra High appears first")
        let pod = GroupSpeedPod(), tap = ChatGPTTap(transport: pod)
        let lease = tap.acquireLease(backgroundWork: true)
        defer { tap.releaseLease(lease); tap.sleep() }
        try await tap.readyForSend()
        let mapper = TapProjectMapper(tap: tap, inboxFolder: root.appendingPathComponent("pod-inbox"))
        for available in [true, false] {
            pod.available = available; ChatGPTTapModelCatalog.replace([])
            let runner = ChatGPTTapTurnRunner(tap: tap, mapper: mapper)
            var reason = "", done = false
            runner.start(threadID: UUID(), project: nil, title: "Fixture", text: "group wire", routeID: ChatGPTTapModelCatalog.routeID("unavailable"), effort: nil, attachmentPaths: [], history: [], group: true, notice: { _ in }, event: {
                if case .notSubmitted(let text) = $0 { reason = text; done = true }
                if case .finished = $0 { done = true }
            })
            for _ in 0..<200 where available ? pod.sends.isEmpty : !done { try await Task.sleep(for: .milliseconds(10)) }
            if available {
                check(pod.sends.last?["model"] as? String == "instant", "actual fake Pod wire sends Instant rather than first Pro")
                pod.stream("text", ["messageID": "reply", "full": "fake reply"]); pod.stream("finished")
                for _ in 0..<200 where !done { try await Task.sleep(for: .milliseconds(10)) }
            } else {
                check(done && pod.sends.count == 1 && reason.contains("快速模型") && !reason.contains("\n"), "no usable model yields one reason and zero extra Pod sends")
            }
            runner.shutdown()
        }
    }
}

@MainActor private final class GroupSpeedPod: DispatchTapPod {
    var available = true
    override func respond(_ command: [String: Any], id: String, cmd: String) {
        guard cmd == "models" else { super.respond(command, id: id, cmd: cmd); return }
        let models: [[String: Any]] = available ? [["slug": "pro", "title": "Pro"], ["slug": "instant", "title": "Instant"]] : [["slug": "research", "title": "Deep Research"]]
        emit(["type": "result", "id": id, "ok": true, "data": ["models": models]])
    }
}
#endif
