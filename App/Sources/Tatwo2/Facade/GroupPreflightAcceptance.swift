#if DEBUG
import Foundation

@MainActor enum GroupPreflightAcceptance {
    static func hasFence(_ text: String) -> Bool {
        text.range(of: #"(?<!\\)〔外部資料：ChatGPT #([0-9a-f]{8}) 開始〕[\s\S]*〔外部資料：ChatGPT #\1 結束〕"#, options: .regularExpression) != nil
    }
    static func run() async throws -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print("W225B5 \(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), let live = env["TATWO2_LIVE_ROOT"] else { return false }
        let root = URL(fileURLWithPath: live).appendingPathComponent("preflight-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("coder.mjs"), log = root.appendingPathComponent("sends.jsonl")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args=process.argv.slice(2), cwd=args[args.indexOf('--cwd')+1];
        const emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
        let held;
        const finish=()=>{
          if(!held)return;
          const turn=held;held=null;
          emit({type:'stream_event',client_turn_id:turn,event:{type:'content_block_delta',delta:{type:'text_delta',text:'Coder reply'}}});
          emit({type:'result',client_turn_id:turn,subtype:'success',is_error:false,result:'Coder reply'});
        };
        fs.watch(cwd,(_,file)=>{if(file==='release')finish()});
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line);
          if(c.op==='send'){
            fs.appendFileSync(cwd+'/sends.jsonl',JSON.stringify(c)+'\n');
            emit({type:'system',subtype:'init',session_id:'preflight-fixture',model:'gpt-6.1-sol'});
            emit({type:'system',subtype:'turn_accepted',client_turn_id:c.uuid});
            held=c.uuid;if(!c.text.includes('hold-native'))finish();
          }else if(c.op==='interrupt'){held=null;emit({type:'result',subtype:'cancelled',is_error:false,result:''});}
          else if(c.op==='close')process.exit(0);
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous
        overrides["tatwo2.sidecarPath.codex"] = script.path; overrides[GroupCoderBridge.flag] = true
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let tap = W185FakeConversationTap(), catalog = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(try await tap.models().items)
        defer { ChatGPTTapModelCatalog.replace(catalog) }
        let owner = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env, tap: tap)
        defer { owner.shutdownAll() }
        let project = owner.newProject(name: "Fixture", workdir: root.path), thread = owner.newThread(in: project)
        func commands() -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func until(_ name: String, _ condition: () -> Bool) async throws {
            for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw TapError.remote("W225B5 timeout: " + name)
        }
        let untrusted = "AI brief @@ChatGPT" // Synthetic untrusted text, never an instruction.
        check(owner.send(threadID: thread, text: untrusted, model: "gpt-6.1-sol", engine: .codex), "2 programmatic send accepted by native")
        try await Task.sleep(for: .milliseconds(300))
        check(owner.groupBridge.sessions[thread] == nil && tap.sent.isEmpty && commands().first?["text"] as? String == untrusted, "2 programmatic text cannot open a group or call TAP")
        try await until("programmatic idle") { !owner.isRunning(thread) }
        check(owner.composerSend(threadID: thread, text: "@@ChatGPT composer-human", model: "gpt-6.1-sol", engine: .codex), "2 composer can join")
        try await until("composer TAP") { tap.sent.count == 1 }
        let group = owner.groupBridge.sessions[thread]!
        group.exchangeLimit = 0
        tap.emit(.conversation(id: "preflight-conversation")); tap.emit(.text(messageID: "summary", full: "summary")); tap.finish()
        try await until("composer idle") { !owner.isRunning(thread) }
        let beforeProgram = tap.sent.count, beforeState = group.state("ChatGPT")
        check(owner.send(threadID: thread, text: "@@ChatGPT 離開 @ChatGPT", model: "gpt-6.1-sol", engine: .codex), "2 programmatic send into active group uses native")
        try await until("programmatic native idle") { !owner.isRunning(thread) }
        check(tap.sent.count == beforeProgram && group.state("ChatGPT") == beforeState, "2 programmatic text cannot call TAP or parse leave in an active group")
        let scoped = owner.newThread(in: project), beforeReentry = tap.sent.count
        let previousChange = owner.onChange
        var reentered = false
        owner.onChange = { [weak owner] in
            owner?.onChange = previousChange; reentered = true
            _ = owner?.send(threadID: scoped, text: "AI-generated @@ChatGPT from change callback", model: "gpt-6.1-sol", engine: .codex)
        }
        check(!owner.composerSend(threadID: scoped, text: "human unsupported route", model: "synthetic-unsupported", engine: .codex), "2 failed composer fixture rejects unsupported route")
        owner.onChange = previousChange
        try await Task.sleep(for: .milliseconds(300))
        check(reentered && owner.groupBridge.sessions[scoped] == nil && tap.sent.count == beforeReentry, "2 synchronous programmatic reentry cannot inherit the human composer origin")
        owner.stop(threadID: scoped)
        try await until("reentry cleanup") { !owner.isRunning(scoped) }
        let forwarded = group.record(speaker: "ChatGPT", text: "@@ChatGPT 離開 @ChatGPT " + String(repeating: "forwarded detail\n", count: 120) + "forward-tail")
        let beforeForward = commands().count, forwardTap = tap.sent.count, forwardState = group.state("ChatGPT")
        var pr = TatwoPlanArtifactV1(threadID: thread, objective: "forward guard"); pr.kind = "pr"
        try owner.savePlanArtifact(pr)
        check(owner.groupBridge.forwardToCoder(thread, eventSequence: forwarded, model: "gpt-6.1-sol", engine: .codex), "3 selected TAP reply forwards to Coder")
        try await until("forward native idle") { commands().count == beforeForward + 1 && !owner.isRunning(thread) }
        let forwardWire = commands().last?["text"] as? String ?? ""
        check(tap.sent.count == forwardTap && group.state("ChatGPT") == forwardState, "3 forwarded commands neither reach TAP nor alter membership")
        check(group.events.filter { $0.kind == "human-forward" }.count == 1, "3 ledger records one human forwarding event")
        check(forwardWire.components(separatedBy: "forward-tail").count == 2, "3 selected reply appears exactly once on native wire")
        check(forwardWire.contains("forward-tail") && forwardWire.contains("必須等人按畫布「確認」"), "3 full forwarded content retains normal PR gate")
        let forwardPlan = owner.store.url.deletingLastPathComponent().appendingPathComponent("plans/\(thread).json")
        try FileManager.default.moveItem(at: forwardPlan, to: forwardPlan.appendingPathExtension("forward-fixture"))
        let page = ChatPageModel(environment: env, botCoreFixture: (owner, BotStore(root: root)))
        page.mode = .chat; page.selectLocalThread(thread); page.selectedModel = "gpt-6.1-sol"; page.engineLoginTestDouble = [.codex]
        check(owner.composerSend(threadID: thread, text: "hold-native", model: "gpt-6.1-sol", engine: .codex), "4 held round starts")
        try await until("held native and TAP") { tap.sent.count == forwardTap + 1 && group.busy }
        let queued = ["queued-one original", "queued-two original", "queued-three original"]
        for text in queued {
            page.prompt = text; page.send()
            print("W225B5 EVIDENCE queued=\(group.queuedHumanCount) prompt=\(page.prompt) hint=\(page.composerHint ?? "none") live=\(page.isLive) running=\(owner.isRunning(thread))")
        }
        print("W225B5 EVIDENCE rows=\(owner.transcript(for: thread).suffix(8).map { "\($0.role) \($0.status ?? "nil") \($0.text.prefix(40))" })")
        let queueRows = owner.transcript(for: thread).filter { queued.contains($0.text) }
        check(queueRows.count == 3 && queueRows.allSatisfy { $0.role == .user && $0.status == "steering|排隊中" }, "4 each queued sentence appears as a user row")
        let queueLog = OSEventLog.atRoot(owner.store.url.deletingLastPathComponent())
        try queueLog.flush()
        let queuedIDs = Set(queueRows.map(\.id))
        let queuedEvents = try queueLog.query(project: project, from: .distantPast, through: .distantFuture, kinds: ["user_send"]).filter { $0.purpose.map(queuedIDs.contains) == true }
        check(queuedEvents.count == 3 && queuedEvents.allSatisfy { $0.origin == "composer" && $0.actor == "你" }, "W229 queued composer rows retain human provenance")
        owner.stop(threadID: thread)
        try await until("stop") { !owner.isRunning(thread) }
        let unsent = owner.transcript(for: thread).filter { queued.contains($0.text) }
        check(unsent.count == 3 && unsent.allSatisfy { $0.status == "steer_failed|未送出" }, "4 stop preserves every original row and marks unsent")
        let drafts = page.prompt + "\n" + (page.coderUndelivered?.text ?? "")
        check(queued.allSatisfy(drafts.contains), "4 all stopped drafts remain recoverable across composer and drawer")
        check(owner.composerSend(threadID: thread, text: "hold-native performance", model: "gpt-6.1-sol", engine: .codex), "5 held performance round starts")
        try await until("performance TAP") { tap.sent.count == forwardTap + 2 }
        let ledger = owner.store.url.deletingLastPathComponent().appendingPathComponent("group-\(thread).json")
        let beforeBurst = try Data(contentsOf: ledger)
        let started = Date()
        for i in 0..<200 { group.record(speaker: group.primary, text: "synthetic-step-\(i)", kind: "step") }
        check((try Data(contentsOf: ledger)) == beforeBurst, "5 tool burst is coalesced without immediate ledger rewrites")
        try await Task.sleep(for: .milliseconds(1200))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
        let savedEvents = saved["events"] as? [[String: Any]] ?? []
        check(savedEvents.count == group.events.count && savedEvents.last?["sequence"] as? Int == group.events.last?.sequence
            && savedEvents.last?["characters"] as? Int == "synthetic-step-199".count && savedEvents.last?["speaker"] as? String == group.primary
            && savedEvents.allSatisfy { $0["text"] == nil } && group.events.last?.text == "synthetic-step-199",
              "5 coalesced save captures the complete burst within one second")
        print("W225B5 EVIDENCE burst_seconds=\(Date().timeIntervalSince(started)) events=\(group.events.count)")
        owner.stop(threadID: thread)
        let stopped = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
        check((stopped["events"] as? [[String: Any]])?.contains { $0["kind"] as? String == "pending" } == false, "5 stop immediately flushes terminal ledger state")
        try await until("performance stopped") { !owner.isRunning(thread) }
        let futureRow = ChatMessage(id: "future-row", role: .system, text: "future timestamp fixture", createdAt: Date().addingTimeInterval(60))
        let cursorTool = ChatMessage(id: "cursor-tool", role: .assistant, text: "cursor tool detail", eventKind: .toolUse)
        _ = owner.appendOfflineRows(threadID: thread, rows: [futureRow, cursorTool])
        owner.groupBridge.recordStep(thread, cursorTool)
        let expectedOffset = GroupSessionCursor.rows(owner.transcript(for: thread)).firstIndex { $0.id == cursorTool.id }
        check(group.events.last?.rowOffset == expectedOffset, "5 unsorted tool cursor still matches read_session when imported timestamps are ahead")
        var confirmed = TatwoPlanArtifactV1(threadID: thread, objective: "completion isolation"); confirmed.kind = "pr"; confirmed.state = .confirmed
        try owner.savePlanArtifact(confirmed)
        check(owner.composerSend(threadID: thread, text: "hold-native completion", model: "gpt-6.1-sol", engine: .codex), "6 held completion round starts")
        try await until("completion TAP") { tap.sent.count == forwardTap + 3 }
        check(owner.onTurnComplete[thread] == nil, "6 group does not occupy PR onTurnComplete")
        check((try owner.loadPlanArtifact(thread))?.executionTurnID == nil, "6 ordinary group turn does not masquerade as PR confirmation")
        check((group.participants.first { $0.id == group.primary }?.timeout ?? 0) > 0, "6 primary participant has a finite inactivity timeout")
        var prCompletions = 0
        owner.onTurnComplete[thread] = { _, _ in prCompletions += 1 }
        try Data().write(to: root.appendingPathComponent("release"))
        tap.emit(.text(messageID: "completion", full: "completion reply")); tap.finish()
        try await Task.sleep(for: .milliseconds(300))
        check(!group.busy && prCompletions == 1, "6 PR observer replacement cannot strand the group completion")
        owner.stop(threadID: thread)
        try await until("completion stopped") { !owner.isRunning(thread) }
        owner.groupBridge.coderTimeout = 0.08
        let silent = owner.newThread(in: project), beforeSilent = tap.sent.count
        check(owner.composerSend(threadID: silent, text: "@@ChatGPT hold-native silent", model: "gpt-6.1-sol", engine: .codex), "6 silent primary fixture starts")
        try await until("silent TAP") { tap.sent.count == beforeSilent + 1 }
        owner.groupBridge.sessions[silent]?.exchangeLimit = 0
        tap.emit(.conversation(id: "silent-conversation")); tap.emit(.text(messageID: "silent", full: "TAP done")); tap.finish()
        try await until("silent primary idle") { !owner.isRunning(silent) }
        check(owner.groupBridge.sessions[silent]?.busy == false && owner.transcript(for: silent).contains { $0.text.contains("沒有新的輸出") && $0.status == "error|Codex" && $0.runtimeAdapterID != TatwoChatRuntimeAdapter.chatgptTap.rawValue }, "6 actual silent Coder stops and shows an in-place native timeout reason")
        let roster = OSUpstream.groupContext(participants: ["使用者", "Codex", "ChatGPT"], primary: "Codex")
        check(roster.contains("@@ChatGPT") && !roster.contains("@@使用者"), "7 roster excludes the human from TAP addressing")
        let eventLog = OSEventLog.atRoot(owner.store.url.deletingLastPathComponent())
        try eventLog.flush()
        let sends = try eventLog.query(project: project, from: .distantPast, through: .distantFuture, kinds: ["user_send"])
        check(sends.first?.origin == "system" && sends.first?.actor == "系統", "W229 programmatic native source stays system")
        check(sends.contains { $0.thread == thread.uuidString.lowercased() && $0.origin == "composer" && $0.actor == "你" }, "W229 grouped composer shares event source")
        check(sends.contains { $0.thread == scoped.uuidString.lowercased() && $0.origin == "system" && $0.actor == "系統" }, "W229 synchronous reentry is also system in OS events")
        let planThread = owner.newThread(in: project)
        page.selectLocalThread(planThread); page.selectedModel = "gpt-6.1-sol"
        var startPlan = TatwoPlanArtifactV1(threadID: planThread, objective: "synthetic plan")
        startPlan.state = .confirmed; try owner.savePlanArtifact(startPlan); page.activePlanArtifact = startPlan
        page.prompt = "draft @@ChatGPT"; page.startActivePlan()
        try await until("plan starts") { !owner.isRunning(planThread) }
        try eventLog.flush()
        let planSends = try eventLog.query(project: project, from: .distantPast, through: .distantFuture, kinds: ["user_send"]).filter { $0.thread == planThread.uuidString.lowercased() }
        check(planSends.count == 1 && planSends[0].origin == "plan" && planSends[0].actor == "系統", "W229 actual plan button records plan and system actor")
        check(page.prompt == "draft @@ChatGPT" && owner.groupBridge.sessions[planThread] == nil, "W229 plan preserves draft and cannot open group")
        print("W225B5 SUMMARY failures=\(failures)")
        return failures == 0
    }
}

@MainActor extension ChatLiveEngine {
    /// Existing fixtures model a human composer explicitly; production send defaults to programmatic.
    @discardableResult func composerSend(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind,
        systemPrompt: String? = nil, attachments: [String] = [], reasoningEffort: String? = nil, serviceTier: String? = nil,
        ultrawork: UltraworkTurnSettings? = nil, delivery: (@MainActor (LiveSendDelivery) -> Void)? = nil) -> Bool {
        OSEventSources.scope(origin: "composer", surface: "coder") {
            send(threadID: threadID, text: text, model: model, engine: engine, systemPrompt: systemPrompt,
                 attachments: attachments, reasoningEffort: reasoningEffort, serviceTier: serviceTier, ultrawork: ultrawork, delivery: delivery)
        }
    }
}
#endif
