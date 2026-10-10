#if DEBUG
import Foundation

@MainActor enum GroupFixAcceptance {
    static func run() async throws -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print("W225B4 \(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), let live = env["TATWO_STAGING_ROOT"] else { return false }
        let root = URL(fileURLWithPath: live).appendingPathComponent("fix-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("coder.mjs"), log = work.appendingPathComponent("sends.jsonl")
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
            emit({type:'system',subtype:'init',session_id:'fix-fixture',model:'gpt-6.1-sol'});
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
        let project = owner.newProject(name: "Fixture", workdir: work.path), thread = owner.newThread(in: project)
        func commands() -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func until(_ name: String, _ condition: () -> Bool) async throws {
            for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw TapError.remote("W225B4 timeout: " + name)
        }
        let model = ChatPageModel(environment: env, botCoreFixture: (owner, BotStore(root: root)))
        let paths = HandsPaths(root: root.appendingPathComponent("hands"))
        var runtime = HandsRuntime.current(paths: paths, environment: env)
        runtime.appSupport = root.appendingPathComponent("support").path
        let service = HandsService(paths: paths, runtime: runtime)
        service.attach(model: model)
        let grant = HandsGrantAccess(grantID: "fixture", clientID: "fixture", grantLevel: 2, projectIDs: [], allProjects: true)
        let settings: HandsSettings = { var value = HandsSettings(); value.allProjects = true; return value }()
        func read(_ pointer: String) async -> String {
            await Task.detached {
                var next: String? = pointer, text = ""
                do {
                    for _ in 0..<10 {
                        let page = try service.readSession(thread.uuidString, cursor: next, grant: grant, settings: settings)
                        text += page
                        next = (try JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any])?["next_cursor"] as? String
                        if next == nil { return text }
                    }
                    return "READ_INCOMPLETE"
                } catch { return "READ_FAILED: \(error)" }
            }.value
        }
        func pointer(_ payload: String, after marker: String = "cursor=") -> String {
            guard let range = payload.range(of: marker) else { return "MISSING" }
            return String(payload[range.upperBound...].prefix { $0 != ")" })
        }
        _ = owner.appendOfflineRows(threadID: thread, rows: [
            ChatMessage(id: "seed-message", role: .user, text: "seed detail"),
            ChatMessage(id: "seed-tool", role: .assistant, text: "fixture tool", eventKind: .toolUse),
            ChatMessage(id: "seed-hidden", role: .system, text: "private memory", status: TatwoMemoryUsageNote.status),
            ChatMessage(id: "seed-system", role: .system, text: "ordinary notice")
        ])
        _ = owner.composerSend(threadID: thread, text: "@@ChatGPT join-human", model: "gpt-6.1-sol", engine: .codex)
        try await until("join sent") { tap.sent.count == 1 }
        let joinCursor = pointer(tap.sent[0].text)
        let joinRead = await read(joinCursor)
        print("W225B4 EVIDENCE join cursor=\(joinCursor) read_chars=\(joinRead.count)")
        check(joinCursor == thread.uuidString + ":0" && joinRead.contains("seed detail"), "2 joining pointer reads full thread through actual read_session")
        let group = owner.groupBridge.sessions[thread]!
        group.exchangeLimit = 0
        tap.emit(.conversation(id: "fix-conversation")); tap.emit(.text(messageID: "summary", full: "TAP summary")); tap.finish()
        try await until("join idle") { !owner.isRunning(thread) }
        group.leave("ChatGPT")
        for i in 0..<24 {
            let body = "detail-\(i) " + String(repeating: "long ", count: 100)
            _ = owner.appendOfflineRows(threadID: thread, rows: [ChatMessage(id: "detail-\(i)", role: .assistant, text: body, eventKind: .toolUse)])
            group.record(speaker: "Codex", text: body, kind: "step")
        }
        _ = owner.composerSend(threadID: thread, text: "@@ChatGPT catchup-human", model: "gpt-6.1-sol", engine: .codex)
        try await until("catchup sent") { tap.sent.count == 2 }
        let detailCursor = pointer(tap.sent.last!.text, after: "詳情 read_session(thread_id=\(thread), cursor=")
        let detailRead = await read(detailCursor)
        print("W225B4 EVIDENCE detail cursor=\(detailCursor) read_chars=\(detailRead.count)")
        check(detailCursor.hasPrefix(thread.uuidString + ":") && detailRead.contains("detail-0") && detailRead.contains("catchup-human"), "2 detail pointer reads corresponding missed content despite non-event transcript rows")
        tap.emit(.text(messageID: "catchup", full: "caught up")); tap.finish()
        try await until("catchup idle") { !owner.isRunning(thread) }
        model.mode = .chat; model.selectLocalThread(thread); model.selectedModel = "gpt-6.1-sol"
        model.engineLoginTestDouble = [.codex]
        _ = owner.composerSend(threadID: thread, text: "hold-native", model: "gpt-6.1-sol", engine: .codex)
        try await until("busy native and TAP") { tap.sent.count == 3 && commands().count == 3 }
        model.isRunning = owner.isRunning(thread)
        model.prompt = "page-queued-one"
        check(model.canSend, "3 composer send stays enabled while group is busy")
        model.send()
        model.prompt = "page-queued-two"; model.send()
        check(group.queuedHumanCount == 2 && group.events.filter { $0.kind == "queued" }.map(\.text) == ["page-queued-one", "page-queued-two"] && model.prompt.isEmpty, "3 actual page enqueues both drafts and records them")
        // Stop native directly only to finish the fixture step; the group queue must survive.
        owner.groupStopPrimary(thread)
        tap.emit(.text(messageID: "busy", full: "finished busy step")); tap.finish()
        try await until("queue drained") { !group.busy || tap.sent.count == 4 }
        if tap.sent.count == 4 {
            tap.emit(.text(messageID: "queued", full: "finished merged step")); tap.finish()
            try await until("merged idle") { !owner.isRunning(thread) }
        }
        check(group.events.last { $0.speaker == "使用者" && $0.kind == "message" }?.text == "page-queued-one\npage-queued-two" && commands().last?["text"] as? String != nil && (commands().last?["text"] as? String ?? "").contains("page-queued-two"), "3 page messages reach the next native round merged")
        // Native-only busy route cannot steer: direct send must keep draft and show a reason.
        let plainThread = owner.newThread(in: project)
        _ = owner.composerSend(threadID: plainThread, text: "hold-native", model: "gpt-6.1-sol", engine: .codex)
        model.selectLocalThread(plainThread); model.selectedModel = "claude-sonnet-4-6"
        model.isRunning = true; model.prompt = "cannot queue here"; model.send()
        check(model.prompt == "cannot queue here" && (owner.transcript(for: plainThread).contains { $0.text.contains("不能排隊") } || model.composerHint != nil), "3 busy non-queueable send gives an in-place reason")
        owner.groupStopPrimary(plainThread)
        try await until("plain fixture stopped") { !owner.isRunning(plainThread) }
        let unknownThread = owner.newThread(in: project), beforeUnknownTap = tap.sent.count
        let original = "paste @@ROWCOUNT and @@Outside original"
        _ = owner.composerSend(threadID: unknownThread, text: original, model: "gpt-6.1-sol", engine: .codex)
        try await until("unknown native done") { !owner.isRunning(unknownThread) }
        check(owner.groupBridge.sessions[unknownThread] == nil && tap.sent.count == beforeUnknownTap && commands().last?["text"] as? String == original, "4.1 unknown roster names never create a group or alter native original")
        let attachment = work.appendingPathComponent("only.txt")
        try Data("synthetic attachment".utf8).write(to: attachment)
        var attachmentOutcomes: [LiveSendDelivery] = []
        let beforeAttachment = commands().count, beforeAttachmentTap = tap.sent.count
        check(owner.composerSend(threadID: thread, text: "", model: "gpt-6.1-sol", engine: .codex, systemPrompt: nil, attachments: [attachment.path], reasoningEffort: nil, serviceTier: nil, ultrawork: nil, delivery: { attachmentOutcomes.append($0) }), "4.3 attachment-only group send accepted")
        try await Task.sleep(for: .milliseconds(300))
        check(commands().count == beforeAttachment + 1 && attachmentOutcomes == [.delivered] && (commands().last?["attachments"] as? [String]) == [attachment.path], "4.3 attachment-only reaches native wire and delivery callback")
        if tap.sent.count > beforeAttachmentTap { tap.emit(.text(messageID: "attachment", full: "attachment reply")); tap.finish() }
        try await until("attachment idle") { !owner.isRunning(thread) }
        let beforeHeld = commands().count, beforeHeldTap = tap.sent.count
        _ = owner.composerSend(threadID: thread, text: "hold-native reject-next", model: "gpt-6.1-sol", engine: .codex)
        try await until("rejection fixture held") { commands().count == beforeHeld + 1 && tap.sent.count == beforeHeldTap + 1 }
        var rejected: [String: [LiveSendDelivery]] = [:]
        for text in ["reject-queued-one", "reject-queued-two"] {
            _ = owner.composerSend(threadID: thread, text: text, model: "gpt-6.1-sol", engine: .codex, systemPrompt: nil, attachments: [], reasoningEffort: nil, serviceTier: nil, ultrawork: nil, delivery: { rejected[text, default: []].append($0) })
        }
        let planURL = owner.store.url.deletingLastPathComponent().appendingPathComponent("plans/\(thread).json")
        try FileManager.default.createDirectory(at: planURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken fixture plan".utf8).write(to: planURL)
        try Data().write(to: work.appendingPathComponent("release"))
        tap.emit(.text(messageID: "held", full: "held reply")); tap.finish()
        try await until("rejected next TAP") { tap.sent.count == beforeHeldTap + 2 }
        tap.emit(.text(messageID: "rejected", full: "rejected native reply")); tap.finish()
        try await until("rejected idle") { !owner.isRunning(thread) }
        check(rejected.count == 2 && rejected.values.allSatisfy { outcomes in guard outcomes.count == 1 else { return false }; if case .notDelivered = outcomes[0] { return true }; return false } && commands().count == beforeHeld + 1, "4.3 every queued caller gets exactly one notDelivered when native rejects synchronously")
        try FileManager.default.moveItem(at: planURL, to: planURL.appendingPathExtension("fixture-broken"))
        tap.removeConversation("fix-conversation")
        let beforeMissing = tap.sent.count
        _ = owner.composerSend(threadID: thread, text: "@@ChatGPT current-human-after-deletion", model: "gpt-6.1-sol", engine: .codex)
        try await until("missing conversation rejoin") { tap.sent.count == beforeMissing + 1 }
        check(tap.sent.last!.conversationID == nil && tap.sent.last!.text.contains("請先用") && tap.sent.last!.text.contains("current-human-after-deletion"), "4.5 actual TAP existence check preserves current human in replacement opening")
        tap.emit(.conversation(id: "replacement-fix")); tap.emit(.text(messageID: "replacement", full: "manual relay candidate")); tap.finish()
        try await until("replacement idle") { !owner.isRunning(thread) }
        let candidate = group.events.last { $0.speaker == "ChatGPT" && $0.text == "manual relay candidate" }!
        let beforeForward = commands().count
        check(commands().count == beforeForward && !owner.groupBridge.forwardToCoder(thread, eventSequence: candidate.sequence - 1, model: "gpt-6.1-sol", engine: .codex), "4.7 only a completed ChatGPT row exposes manual relay")
        var plan = TatwoPlanArtifactV1(threadID: thread, objective: "manual relay PR"); plan.kind = "pr"
        try owner.savePlanArtifact(plan)
        let forwardTap = tap.sent.count
        check(owner.groupBridge.forwardToCoder(thread, eventSequence: candidate.sequence, model: "gpt-6.1-sol", engine: .codex), "4.7 human explicitly forwards the selected ChatGPT row")
        try await until("manual forward native") { commands().count == beforeForward + 1 && !owner.isRunning(thread) }
        check(tap.sent.count == forwardTap && group.events.filter { $0.kind == "human-forward" }.count == 1, "4.7 selected reply only reaches Coder and records human forwarding")
        let forwardWire = commands().last?["text"] as? String ?? ""
        check(forwardWire.contains("manual relay candidate") && GroupPreflightAcceptance.hasFence(forwardWire) && forwardWire.contains("必須等人按畫布「確認」") && owner.transcript(for: thread).filter { $0.id == "group-\(thread)-\(candidate.sequence)" }.count == 1, "4.7 selected reply remains attached to its row and follows normal human PR guard")
        try await until("forward idle") { !owner.isRunning(thread) }
        let badThread = owner.newThread(in: project), folder = owner.store.url.deletingLastPathComponent()
        let badURL = folder.appendingPathComponent("group-\(badThread).json"), broken = Data("broken group ledger".utf8)
        try broken.write(to: badURL)
        let beforeRecovery = tap.sent.count
        check(owner.composerSend(threadID: badThread, text: "@@ChatGPT recovered-human", model: "gpt-6.1-sol", engine: .codex), "4.2 corrupt ledger rebuild accepts current human")
        if owner.groupBridge.sessions[badThread] != nil {
            owner.groupBridge.sessions[badThread]?.exchangeLimit = 0
            try await until("recovery sent") { tap.sent.count == beforeRecovery + 1 }
            tap.emit(.conversation(id: "recovered-fixture")); tap.emit(.text(messageID: "recovery", full: "recovery summary")); tap.finish()
            try await until("recovery idle") { !owner.isRunning(badThread) }
        }
        let archived = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        check(archived.contains { $0.lastPathComponent.hasPrefix(badURL.lastPathComponent + ".broken-") && (try? Data(contentsOf: $0)) == broken } && owner.transcript(for: badThread).contains { $0.text.contains("封存並重建") }, "4.2 corrupt bytes archived with timestamp and one in-place reason")
        let activeData = try? Data(contentsOf: badURL)
        check(owner.groupBridge.end(badThread) && owner.groupBridge.sessions[badThread] == nil && !FileManager.default.fileExists(atPath: badURL.path), "4.2 end group removes active routing and archives ledger")
        let ended = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        check(ended.contains { $0.lastPathComponent.hasPrefix(badURL.lastPathComponent + ".ended-") && (try? Data(contentsOf: $0)) == activeData }, "4.2 ended ledger remains recoverable byte for byte")
        let afterEnd = tap.sent.count
        _ = owner.composerSend(threadID: badThread, text: "plain after end", model: "gpt-6.1-sol", engine: .codex)
        try await until("normal after end") { !owner.isRunning(badThread) }
        check(owner.groupBridge.sessions[badThread] == nil && tap.sent.count == afterEnd && commands().last?["text"] as? String == "plain after end", "4.2 next plain human uses original native route after end")
        print("W225B4 SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
