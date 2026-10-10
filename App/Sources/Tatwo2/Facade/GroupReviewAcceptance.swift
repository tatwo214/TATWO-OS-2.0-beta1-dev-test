#if DEBUG
import Foundation

@MainActor enum GroupReviewAcceptance {
    static func run() async throws -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print("W225B3 \(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), let live = env["TATWO2_LIVE_ROOT"] else { return false }
        let root = URL(fileURLWithPath: live).appendingPathComponent("review-fixture")
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
            emit({type:'system',subtype:'init',session_id:'review-fixture',model:'gpt-6.1-sol'});
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
            throw TapError.remote("W225B3 timeout: " + name)
        }
        let memory = EngineMemoryPaths().memory
        try EngineMemoryLinks.createMemoryFolder(memory)
        try "---\nname: 晚餐不吃香菜\nmetadata:\n  type: user\n  aliases: [晚餐, 香菜]\n---\n晚餐不吃香菜。\n".write(to: memory.appendingPathComponent("dinner.md"), atomically: true, encoding: .utf8)
        _ = await TatwoMemoryIndex.shared.reload()
        owner.setMemoryStrength(threadID: thread, .medium)
        var plan = TatwoPlanArtifactV1(threadID: thread, objective: "群組 PR")
        plan.kind = "pr"; try owner.savePlanArtifact(plan)
        let human = "@@ChatGPT 晚餐香菜 " + String(repeating: "人的完整原話\n", count: 260) + "尾端不可省略"
        let ultra = UltraworkTurnSettings(level: 1, primaryModelID: "gpt-6.1-sol", auxiliaryModelIDs: [])
        check(owner.composerSend(threadID: thread, text: human, model: "gpt-6.1-sol", engine: .codex, systemPrompt: nil, attachments: [], reasoningEffort: nil, serviceTier: nil, ultrawork: ultra, delivery: nil), "1 group send accepted")
        try await until("initial native and TAP") { !commands().isEmpty && tap.sent.count == 1 && owner.transcript(for: thread).contains { $0.text == "Coder reply" } }
        let wire = commands().first?["text"] as? String ?? ""
        check(wire.contains(human), "1 native wire contains full multiline human beyond 1200 chars")
        check(wire.contains("必須等人按畫布「確認」") && wire.contains("ultrawork"), "1 PR gate and ultrawork survive group assembly")
        check(owner.threadRecord(thread)?.ultraworkSent == ultra, "1 ultrawork acknowledged normally")
        check(wire.contains("晚餐不吃香菜") && owner.transcript(for: thread).contains { $0.status == TatwoMemoryUsageNote.status && (TatwoMemoryUsageNote.decode($0.text)?.count ?? 0) > 0 }, "1 carried memory and usage row survive")
        tap.emit(.conversation(id: "review-conversation")); tap.emit(.text(messageID: "summary", full: "TAP summary")); tap.finish()
        try await until("exchange TAP") { tap.sent.count == 2 }
        tap.emit(.text(messageID: "exchange", full: "TAP reply")); tap.finish()
        try await until("group idle") { !owner.isRunning(thread) }
        check(commands().count == 1, "3 TAP reply never auto-starts writable Coder turn")
        let nativeLength = commands().compactMap { $0["text"] as? String }.reduce(0) { $0 + $1.count }
        check(owner.groupBridge.sessions[thread]?.accounting[1]?["Codex"]?.sent == nativeLength, "1 accounting matches complete native wire including guards")
        let tradingFolder = root.appendingPathComponent("trading-fixture")
        try FileManager.default.createDirectory(at: tradingFolder, withIntermediateDirectories: true)
        let trading = owner.newProject(name: "實盤交易", workdir: tradingFolder.path)
        let tradingThread = owner.newThread(in: trading), beforeTap = tap.sent.count
        let tradingHuman = "@@ChatGPT 保留交易人的原文"
        check(owner.composerSend(threadID: tradingThread, text: tradingHuman, model: "gpt-6.1-sol", engine: .codex), "2 trading original accepted by native")
        try await until("trading native") { !owner.isRunning(tradingThread) }
        check(tap.sent.count == beforeTap && owner.groupBridge.sessions[tradingThread] == nil, "2 trading has zero TAP calls and no group")
        let tradingCommand = try JSONSerialization.jsonObject(with: Data(String(contentsOf: tradingFolder.appendingPathComponent("sends.jsonl"), encoding: .utf8).split(separator: "\n").last!.utf8)) as! [String: Any]
        check(tradingCommand["text"] as? String == tradingHuman && owner.transcript(for: tradingThread).contains { $0.text == "交易專案不開群組" }, "2 native receives original and reason stays in place")
        let alias = owner.newProject(name: "fixture", workdir: tradingFolder.path)
        let aliasThread = owner.newThread(in: alias)
        check(owner.composerSend(threadID: aliasThread, text: tradingHuman, model: "gpt-6.1-sol", engine: .codex), "2 trading alias original accepted")
        try await until("alias native") { !owner.isRunning(aliasThread) }
        check(tap.sent.count == beforeTap && owner.groupBridge.sessions[aliasThread] == nil, "2 same-folder trading alias stays blocked")
        let missing = UUID()
        let missingRoute = owner.groupBridge.route(threadID: missing, text: "@@ChatGPT", model: "gpt-6.1-sol", engine: .codex, systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil)
        check(missingRoute == nil && owner.groupBridge.sessions[missing] == nil, "2 missing thread never enters bridge")
        print("W225B3 SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
