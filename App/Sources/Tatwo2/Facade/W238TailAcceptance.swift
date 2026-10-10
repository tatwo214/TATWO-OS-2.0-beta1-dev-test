#if DEBUG
import Foundation

@MainActor enum W238TailAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let root = URL(fileURLWithPath: path).appendingPathComponent("tail-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = 0, failures = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failures += 1 }
            print("W238 \(ok ? "PASS" : "FAIL") \(label)")
        }
        try await queueChecks(root: root, environment: env, check: check)
        try await groupChecks(root: root.appendingPathComponent("groups"), environment: env, check: check)
        try documentChecks(root: root.appendingPathComponent("documents"), check: check)
        print("W238 SUMMARY passed=\(passed) failures=\(failures)")
        return failures == 0
    }
    private static func until(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw TapError.remote("W238 timeout " + label)
    }
    private static func queueChecks(root: URL, environment: [String: String], check: (Bool, String) -> Void) async throws {
        let script = root.appendingPathComponent("reply.mjs")
        try #"""
        import readline from 'node:readline';
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line), emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
          if(c.op==='close')process.exit(0); if(c.op!=='send')return;
          emit({type:'system',subtype:'init',session_id:'tail-fixture',model:'fixture'});
          emit({type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false,result:'fixture reply'});
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior; overrides["tatwo2.sidecarPath.codex"] = script.path; overrides[GroupCoderBridge.flag] = true
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let pod = DispatchTapPod(), tap = ChatGPTTap(transport: pod), catalog = ChatGPTTapModelCatalog.snapshot
        let lease = tap.acquireLease(backgroundWork: true)
        defer { tap.releaseLease(lease); tap.sleep(); ChatGPTTapModelCatalog.replace(catalog) }
        try await tap.readyForSend()
        let owner = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment, tap: tap)
        defer { owner.shutdownAll() }
        let project = owner.newProject(name: "Fixture", workdir: root.path), thread = owner.newThread(in: project)
        let active = tap.send(text: "active fixture", conversationID: nil, model: nil, effort: nil, attachments: [], tool: nil, gizmoID: nil, temporary: false, parentID: nil)
        check(owner.composerSend(threadID: thread, text: "@@ChatGPT queued fixture", model: "gpt-6.1-sol", engine: .codex), "G1 normal group enters real TAP queue")
        try await until("group queued") { tap.queuedSendCount == 1 }
        let sent = pod.sends.count
        owner.markControllerThread(thread, fingerprint: "fixture-controller")
        check(tap.queuedSendCount == 0 && pod.sends.count == sent, "G1 managed marker cancels queued send without dispatch")
        try await until("group settled") { owner.groupBridge.sessions[thread]?.busy == false }
        check(owner.transcript(for: thread).filter { $0.text.contains("受管對話不能使用 ChatGPT TAP") }.count == 1, "G1 UI has one managed cancellation reason")
        pod.stream("finished")
        check(pod.sends.count == sent, "G1 cancelled queue remains empty after active send finishes")

        let activeAgain = tap.send(text: "active again", conversationID: nil, model: nil, effort: nil, attachments: [], tool: nil, gizmoID: nil, temporary: false, parentID: nil)
        var managed = false, reason: String?
        let guarded = GroupGuardedTap(tap: tap) { managed ? "受管 fixture 未送出" : nil }
        let queued = guarded.send(text: "private queued fixture", conversationID: nil, model: nil, effort: nil, attachments: [], tool: nil, gizmoID: nil, temporary: false, parentID: nil)
        let consumer = Task { @MainActor in for await event in queued { if case .notSubmitted(let why) = event { reason = why } } }
        check(tap.queuedSendCount == 1, "G1 transport queues guarded send behind active request")
        managed = true; let beforeDrain = pod.sends.count; pod.stream("finished")
        await consumer.value
        check(tap.queuedSendCount == 0 && pod.sends.count == beforeDrain && reason == "受管 fixture 未送出", "G1 dequeue rechecks policy and reports not submitted")
        managed = false
        let healthy = guarded.send(text: "healthy fixture", conversationID: nil, model: nil, effort: nil, attachments: [], tool: nil, gizmoID: nil, temporary: false, parentID: nil)
        check(pod.sends.count == beforeDrain + 1, "G1 subsequent ordinary send still dispatches")
        pod.stream("finished")
        withExtendedLifetime([active, activeAgain, healthy]) {}
    }
    private static func groupChecks(root: URL, environment: [String: String], check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let peers = [GroupParticipant(id: "Codex", invoke: { _, done in done(.success("fixture")) }, stop: {}),
                     GroupParticipant(id: "ChatGPT", join: true, invoke: { _, done in done(.success("fixture")) }, stop: {})]
        let group = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: peers)
        let first = group.record(speaker: "使用者", text: "private human fixture"), second = group.record(speaker: "ChatGPT", text: "private TAP fixture", kind: "summary")
        group.bindRow(first, offset: 0); group.bindRow(second, offset: 2)
        let data = try group.snapshot(), restored = GroupTurnEngine(threadID: group.threadID, primary: "Codex", participants: peers)
        try restored.restore(data, content: { [0: "reloaded human", 2: "reloaded external reply"][$0.rowOffset ?? -1] ?? "" })
        let relay = restored.coderRelay(second) ?? ""
        check(restored.events.map(\.text) == ["reloaded human", "reloaded external reply"] && relay.components(separatedBy: "reloaded external reply").count == 2 && GroupPreflightAcceptance.hasFence(relay) && !relay.contains("private TAP fixture"), "G2 restored event bodies and Coder relay use transcript row offsets")
        var metadata = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        metadata["events"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(group.events))
        metadata["membership"] = ["ChatGPT": ["state": "away", "handoff": "private handoff fixture", "errors": 0]]
        let legacy = try JSONSerialization.data(withJSONObject: metadata)
        let oldArchive = root.appendingPathComponent("group-\(group.threadID).json.ended-123")
        try legacy.write(to: oldArchive)
        let fake = W185FakeConversationTap(), owner = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment, tap: fake)
        defer { owner.shutdownAll() }
        _ = owner.groupBridge
        func safeArchive(_ url: URL) throws -> Bool {
            let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let events = rows["events"] as! [[String: Any]], members = rows["membership"] as! [String: [String: Any]]
            return events.allSatisfy { $0["text"] == nil } && members.values.allSatisfy { $0["handoff"] == nil }
                && events.last?["characters"] as? Int == "private TAP fixture".count && events.last?["rowOffset"] as? Int == 2
        }
        check(try safeArchive(oldArchive), "G2 old archived group retains event skeleton without bodies or handoff")
        let thread = owner.newThread(in: nil), activeFile = root.appendingPathComponent("group-\(thread).json")
        try legacy.write(to: activeFile)
        check(owner.groupBridge.end(thread), "G2 ending a legacy group succeeds")
        let archive = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(activeFile.lastPathComponent + ".ended-") }!
        let archivedSafe = try safeArchive(archive)
        check(!FileManager.default.fileExists(atPath: activeFile.path) && archivedSafe, "G2 newly archived legacy group contains only event skeleton")

        let prior = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(prior) }
        ChatGPTTapModelCatalog.replace([])
        let waiting = W232WaitingTap(tap: fake); waiting.pause = true
        var managed = false, rejection: String?
        let guarded = GroupGuardedTap(tap: waiting) { managed ? "受管 destination fixture" : nil }
        let mapper = TapProjectMapper(tap: guarded, storage: TapProjectMapStore(), inboxFolder: root.appendingPathComponent("inbox"))
        let runner = ChatGPTTapTurnRunner(tap: guarded, mapper: mapper)
        defer { runner.shutdown() }
        runner.start(threadID: UUID(), project: nil, title: "fixture", text: "private destination fixture", routeID: ChatGPTTapModelCatalog.routeID("fixture-model"), effort: nil, attachmentPaths: [], history: [], group: true, notice: { _ in }, event: { if case .notSubmitted(let reason) = $0 { rejection = reason } })
        try await until("models held") { waiting.waiting }
        let requests = fake.requestCalls
        managed = true; waiting.resume?.resume(); waiting.resume = nil
        try await until("destination refused") { rejection != nil }
        check(rejection == "ChatGPT 模型目錄重新整理失敗，這句未送出：受管 destination fixture" && fake.requestCalls == requests + 1 && fake.sent.isEmpty && fake.createdNames.isEmpty && !FileManager.default.fileExists(atPath: mapper.inboxFolder.path), "G2 managed after models wait refuses destination lookup and project creation")
    }
    private static func documentChecks(root: URL, check: (Bool, String) -> Void) throws {
        let store = ChatLiveStore(root: root)
        let date = Date(timeIntervalSince1970: 1000.123)
        let row = ChatMessage(role: .assistant, text: String(repeating: "fixture body ", count: 2000), createdAt: date)
        var doc = LiveDocumentRecord(threads: [LiveThreadRecord(messages: [LiveMessageRecord(row)], createdAt: date, updatedAt: date)])
        try store.saveChecked(doc)
        let bytes = try Data(contentsOf: store.url), oldStamp = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: oldStamp], ofItemAtPath: store.url.path)
        var updates = 0
        func sync(_ snapshot: LiveDocumentRecord) {
            if !OSAgentBridge.documentsEqual(snapshot, store.load()) { store.save(snapshot); updates += 1 }
        }
        for _ in 0..<100 { sync(doc) }
        let stamp = try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
        let unchangedBytes = try Data(contentsOf: store.url)
        check(updates == 0 && stamp == oldStamp && unchangedBytes == bytes, "F1 identical content leaves persisted document and revision unchanged")
        doc.threads[0].messages[0].createdAt = Date(timeIntervalSince1970: 1000.789)
        sync(doc)
        check(updates == 0, "F1 ISO date fractional differences retain existing equality semantics")
        doc.threads[0].messages[0].text = "changed fixture body"
        sync(doc)
        check(updates == 1 && store.load().threads[0].messages[0].text == "changed fixture body", "F1 changed body with unchanged timestamps triggers update")
        for _ in 0..<100 { sync(doc) }
        check(updates == 1, "F1 repeated changed snapshot is cached without further updates")
        doc.threads[0].requestedModel = "changed-model"
        sync(doc)
        check(updates == 2 && store.load().threads[0].requestedModel == "changed-model", "F1 model metadata change also triggers update")
    }
}
#endif
