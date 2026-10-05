import Foundation

#if DEBUG
enum RemoteRejectionAcceptance {
    final class Caller: RemoteLiveCalling, @unchecked Sendable {
        let reply: [String: Any]
        private let lock = NSLock()
        private var reads = 0
        var documentReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
        init(_ reply: [String: Any]) { self.reply = reply }
        func call(method: String, params: [String: Any]) throws -> [String: Any] {
            if method.hasPrefix("send_message") { throw RemoteHostLinkError.remoteError("plan_unreadable") }
            lock.lock(); reads += 1; lock.unlock()
            return reply
        }
    }
    @MainActor static func run(root: URL, env: [String: String], check: (String, Bool) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fixture.mjs")
        try #"""
        import readline from 'node:readline';
        const rl = readline.createInterface({input:process.stdin});
        rl.on('line', line => { if(JSON.parse(line).op === 'close') process.exit(0); });
        rl.on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior
        overrides["tatwo2.sidecarPath.codex"] = script.path
        overrides["tatwo2.disabledEngines"] = [] as [String]
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "fixture", workdir: root.path)
        let thread = engine.newThread(in: project)
        let bots = BotStore(root: root)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, bots))
        let bridge = OSAgentBridge.botCoreTestBridge(library: bots.library)
        bridge.configureCallerTest(model: model, manager: BackgroundJobManager())
        func rejection(_ id: UUID) -> String {
            do {
                _ = try bridge.callForSelfTest(method: "send_message", params: ["threadID": id.uuidString,
                    "text": "sample", "model": "gpt-6.1-sol", "engine": "codex"])
                return "accepted"
            } catch { return String(describing: error) }
        }
        check("send-11 unpaired access remains denied", rejection(thread).contains("remote_access_disabled"))
        let registry = DeviceRegistry(root: URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!),
            authorizedKeysURL: root.appendingPathComponent("unused-authorized-keys"), environment: env)
        try registry.add(id: "fixture-peer", name: "fixture", host: "fixture.invalid", user: "fixture",
                         publicKeyFingerprint: "SHA256:fixture")
        check("send-11 missing thread has distinct reason", rejection(UUID()) == "thread_missing")
        check("send-11 fixture starts real busy turn", engine.send(threadID: thread, text: "sample", model: "gpt-6.1-sol", engine: .codex))
        check("send-11 busy thread has distinct reason", rejection(thread) == "thread_busy")
        engine.stop(threadID: thread); engine.stop(threadID: thread)
        let plan = root.appendingPathComponent("plans/\(thread.uuidString).json")
        try fm.createDirectory(at: plan.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unreadable = Data("{".utf8); try unreadable.write(to: plan)
        check("send-11 unreadable plan has distinct reason", rejection(thread) == "plan_unreadable")
        check("send-11 rejected plan remains unchanged", try Data(contentsOf: plan) == unreadable)
        try fm.removeItem(at: plan)
        overrides["tatwo2.disabledEngines"] = ["codex"]
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        check("send-11 engine permission has distinct reason", rejection(thread) == "engine_blocked")
        overrides["tatwo2.disabledEngines"] = [] as [String]
        overrides["tatwo2.sidecarPath.codex"] = root.appendingPathComponent("missing-fixture.mjs").path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        check("send-11 unavailable engine has distinct reason", rejection(thread) == "engine_unavailable")
        for (code, word) in [("thread_busy", "忙"), ("thread_missing", "不存在"), ("device_offline", "不在線"),
                             ("remote_access_disabled_no_paired_devices", "配對"), ("unsupported_method", "版本"),
                             ("plan_unreadable", "計畫"), ("invalid_params", "參數")] {
            if case .notDelivered(let reason) = RemoteLiveEngine.delivery(for: RemoteHostLinkError.remoteError(code)) {
                check("send-11 displays reason \(code)", reason.contains(word))
            } else { check("send-11 explicit rejection is notDelivered \(code)", false) }
        }
        if case .unknown = RemoteLiveEngine.delivery(for: CocoaError(.fileReadUnknown)) {
            check("send-11 transport ambiguity remains unknown", true)
        } else { check("send-11 transport ambiguity remains unknown", false) }
        var document = LiveDocumentRecord()
        var remoteThread = LiveThreadRecord(title: "fixture")
        document.threads = [remoteThread]; document.selectedThreadID = remoteThread.id
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let initial: [String: Any] = ["document": try JSONSerialization.jsonObject(with: encoder.encode(document)),
            "revision": 1, "runningThreadIDs": [] as [String]]
        remoteThread.messages = [LiveMessageRecord(ChatMessage(role: .system, text: "fixture plan rejection", status: "error|Plan"))]
        document.threads = [remoteThread]
        let updated: [String: Any] = ["document": try JSONSerialization.jsonObject(with: encoder.encode(document)),
            "revision": 2, "runningThreadIDs": [] as [String]]
        let caller = Caller(updated)
        let remote = try RemoteLiveEngine(link: RemoteHostLink(environment: env), callingThrough: caller,
            store: ChatLiveStore(root: root.appendingPathComponent("remote-fixture")), initial: initial)
        defer { remote.shutdownAll() }
        var rejected = false
        _ = remote.send(threadID: remoteThread.id, text: "sample", model: nil, engine: .codex,
            systemPrompt: nil, attachments: [], reasoningEffort: nil, serviceTier: nil, ultrawork: nil) { result in
                if case .notDelivered = result { rejected = true }
            }
        for _ in 0..<100 {
            if rejected && caller.documentReads > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check("send-11 explicit remote rejection refreshes immediately", rejected && caller.documentReads > 0
              && remote.doc.threads.first?.messages.first?.text == "fixture plan rejection")
    }
}
#endif
