#if DEBUG
import Foundation

@MainActor enum W232Acceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.validationError(env) == nil, let staging = env["TATWO_STAGING_ROOT"] else { throw TapError.notReady }
        let fleetRoot = try DeviceFleetAcceptance.isolatedRoot()
        try await Task.detached { try DeviceFleetAcceptance.run(root: fleetRoot) }.value
        var checks = 0
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw TapError.remote("W232_FAIL_" + name) }; checks += 1; print("W232 PASS " + name)
        }
        let root = URL(fileURLWithPath: staging).appendingPathComponent("w232-group")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("coder.mjs")
        try #"""
        import readline from 'node:readline';
        const emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line);
          if(c.op==='close')process.exit(0);
          if(c.op!=='send')return;
          emit({type:'system',subtype:'init',session_id:'w232-fixture',model:'gpt-6.1-sol'});
          emit({type:'system',subtype:'turn_accepted',client_turn_id:c.uuid});
          emit({type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false,result:'W232 private Coder response'});
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous; overrides["tatwo2.sidecarPath.codex"] = script.path; overrides[GroupCoderBridge.flag] = true
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let fake = W185FakeConversationTap(), tap = W232WaitingTap(tap: fake), catalog = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(try await tap.models().items)
        defer { ChatGPTTapModelCatalog.replace(catalog) }
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let owner = ChatLiveEngine(store: store, environment: env, tap: tap)
        defer { owner.shutdownAll() }
        let project = owner.newProject(name: "Fixture", workdir: root.path), id = owner.newThread(in: project)
        func until(_ name: String, _ condition: () -> Bool) async throws {
            for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw TapError.remote("W232_TIMEOUT_" + name)
        }
        try check("fake-group-started", owner.composerSend(threadID: id, text: "@@ChatGPT W232 private human input", model: "gpt-6.1-sol", engine: .codex))
        try await until("tap-send") { fake.sent.count == 1 }
        let reply = "W232 external first segment\nW232 external second segment"
        fake.emit(.conversation(id: "w232-conversation")); fake.emit(.text(messageID: "w232-message", full: reply)); fake.finish()
        try await until("group-idle") { owner.groupBridge.sessions[id]?.busy == false }
        let group = owner.groupBridge.sessions[id]!, file = store.url.deletingLastPathComponent().appendingPathComponent("group-\(id).json")
        let disk = try String(contentsOf: file, encoding: .utf8)
        for part in ["W232 external first segment", "W232 external second segment", "W232 private Coder response", "W232 private human input"] { try check("ledger-excludes-" + part, !disk.contains(part)) }
        try check("reply-visible-only-in-coder", owner.transcript(for: id).contains { $0.text.contains(reply) })
        let metadata = try JSONSerialization.jsonObject(with: Data(disk.utf8)) as! [String: Any]
        let events = metadata["events"] as! [[String: Any]]
        try check("metadata-retains-size-cursor-time-speaker", events.contains { $0["characters"] as? Int == reply.count && $0["rowOffset"] != nil && $0["time"] != nil && $0["speaker"] as? String == "ChatGPT" } && events.allSatisfy { $0["text"] == nil })
        var legacy = metadata
        legacy["events"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(group.events))
        legacy["membership"] = ["ChatGPT": ["state": "away", "handoff": reply, "errors": 0]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: file, options: .atomic)
        owner.shutdownAll()
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: store.url.deletingLastPathComponent()), environment: env, tap: tap)
        defer { reopened.shutdownAll() }
        try check("legacy-ledger-reopened", reopened.composerSend(threadID: id, text: "W232 after reopen", model: "gpt-6.1-sol", engine: .codex))
        let migrated = try String(contentsOf: file, encoding: .utf8)
        try check("legacy-fulltext-scrubbed-immediately", !migrated.contains("W232 external first segment") && !migrated.contains("W232 external second segment") && !migrated.contains("handoff"))
        reopened.groupBridge.stop(id)
        let waitingID = owner.newThread(in: project)
        ChatGPTTapModelCatalog.replace([])
        tap.pause = true
        try check("queued-group-started", owner.composerSend(threadID: waitingID, text: "@@ChatGPT wait for models", model: "gpt-6.1-sol", engine: .codex))
        try await until("waiting-models") { tap.waiting }
        let sentBefore = fake.sent.count
        owner.markControllerThread(waitingID, fingerprint: "fixture-controller")
        tap.pause = false; tap.resume?.resume(); tap.resume = nil
        try await until("managed-cancelled") { owner.groupBridge.sessions[waitingID]?.busy == false }
        try check("managed-during-await-never-sent", fake.sent.count == sentBefore && owner.groupBridge.sessions[waitingID]?.events.contains { $0.speaker == "ChatGPT" && $0.kind == "failure" } == true)
        print("W232 GROUP SUMMARY checks=\(checks) failures=0")
        return true
    }
}
@MainActor final class W232WaitingTap: GroupGuardedTap {
    var waiting = false; var pause = false; var resume: CheckedContinuation<Void, Never>?
    init(tap: any ConversationTap) { super.init(tap: tap) }
    override func models() async throws -> (items: [TapModel], defaultID: String?, currentEffortID: String?) {
        if pause { waiting = true; await withCheckedContinuation { resume = $0 } }
        return try await super.models()
    }
}

#endif
