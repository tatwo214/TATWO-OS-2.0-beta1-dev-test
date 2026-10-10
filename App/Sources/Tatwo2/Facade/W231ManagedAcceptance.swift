#if DEBUG
import Foundation

@MainActor enum W231ManagedAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let staging = env["TATWO_STAGING_ROOT"] else { throw TapError.notReady }
        let root = URL(fileURLWithPath: staging).appendingPathComponent("w231")
        func dir(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        var failures = 0, passed = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failures += 1 }
            print("W231 \(ok ? "PASS" : "FAIL") \(name)")
        }
        let script = root.appendingPathComponent("coder.mjs")
        _ = try dir("work")
        try #"""
        import readline from 'node:readline';
        const emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line);
          if(c.op==='send'){
            emit({type:'system',subtype:'init',session_id:'w231-fixture',model:'gpt-6.1-sol'});
            emit({type:'system',subtype:'turn_accepted',client_turn_id:c.uuid});
            emit({type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false,result:'fixture reply'});
          }else if(c.op==='close')process.exit(0);
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous
        overrides["tatwo2.sidecarPath.codex"] = script.path; overrides[GroupCoderBridge.flag] = true
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let tap = W185FakeConversationTap()
        let owner = ChatLiveEngine(store: ChatLiveStore(root: try dir("live")), environment: env, tap: tap)
        defer { owner.shutdownAll() }
        let project = owner.newProject(name: "Fixture", workdir: try dir("work").path)
        let normal = owner.newThread(in: project, title: "Normal")
        let managed = owner.newThread(in: project, title: "Managed private title")
        owner.markControllerThread(managed, fingerprint: "fixture-controller")
        _ = owner.appendOfflineRows(threadID: normal, rows: [ChatMessage(role: .user, text: "visible fixture")])
        _ = owner.appendOfflineRows(threadID: managed, rows: [ChatMessage(role: .user, text: "managed private body")])
        let bots = BotLibrary(root: root, skillsRoot: try dir("skills")); await bots.ready()
        let model = ChatPageModel(environment: env, botCoreFixture: (owner, BotStore(library: bots)))
        var runtime = HandsRuntime.current(paths: HandsPaths(root: try dir("hands")), environment: env)
        runtime.home = try dir("home").path; runtime.entryRoot = try dir("entry").path; runtime.appSupport = try dir("support").path
        let service = HandsService(paths: HandsPaths(root: try dir("hands")), runtime: runtime)
        service.deviceIDOverride = HandsConnectAcceptance.hostID; service.callsPerMinute = 100_000
        service.noticeSink = { _, _ in }; service.attach(model: model)
        _ = try service.updateSettings {
            $0.enabled = true; $0.level = 2; $0.allProjects = true
            $0.hostDeviceID = HandsConnectAcceptance.hostID; $0.publicHost = HandsConnectAcceptance.publicHost
        }
        let client = HandsConnectAcceptance.FakeChatGPT(service: service)
        try client.register(); try service.startPairing(); _ = client.begin()
        let access = try client.token(try client.submit(service.auth.pendingCard?.pairingCode ?? ""))
        func call(_ name: String, _ args: [String: Any]) async -> (Bool, String) {
            let encoded = await Task.detached {
                let wire = OSAgentBridge.handsResponse(method: "hands_call", params: ["access_token": access, "name": name, "arguments": args], service: service)
                return (try? JSONSerialization.data(withJSONObject: wire)) ?? Data()
            }.value
            let wire = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] ?? [:]
            let result = wire["result"] as? [String: Any] ?? [:]
            return (wire["error"] != nil || result["isError"] as? Bool == true,
                    (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "")
        }
        let missing = await call("read_session", ["thread_id": UUID().uuidString])
        check(missing.0 && missing.1.contains("session_not_found_or_not_allowed"), "missing session fixture error")
        for creator in ["fixture-controller", ""] {
            owner.markControllerThread(managed, fingerprint: creator)
            for cursor: String? in [nil, managed.uuidString + ":0", "invalid"] {
                var args: [String: Any] = ["thread_id": managed.uuidString]
                if let cursor { args["cursor"] = cursor }
                let denied = await call("read_session", args)
                check(denied.0 && denied.1 == missing.1, "managed read equals missing before cursor processing creator=\(creator.isEmpty ? "empty" : "marked")")
            }
        }
        let normalRead = await call("read_session", ["thread_id": normal.uuidString])
        check(!normalRead.0 && normalRead.1.contains("visible fixture"), "normal session readable")
        let trading = owner.newProject(name: "BTC 實盤", workdir: try dir("trading").path)
        let tradingThread = owner.newThread(in: trading)
        _ = owner.appendOfflineRows(threadID: tradingThread, rows: [ChatMessage(role: .user, text: "trading readable fixture")])
        let tradingRead = await call("read_session", ["thread_id": tradingThread.uuidString])
        check(!tradingRead.0 && tradingRead.1.contains("trading readable fixture"), "trading session readable")
        let workspaceCount = service.workspaceStore.all().count
        let tradingWrite = await call("open_workspace", ["project_id": trading.uuidString, "title": "Denied fixture"])
        check(tradingWrite.0 && tradingWrite.1 == "project_read_only" && service.workspaceStore.all().count == workspaceCount,
              "trading writable workspace refused without creating workspace")
        func route(_ id: UUID) -> Bool? {
            owner.groupBridge.route(threadID: id, text: "@@ChatGPT fixture", model: "gpt-6.1-sol", engine: .codex,
                                    systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil,
                                    source: .init(origin: "composer", actor: "你", surface: "coder"))
        }
        check(route(managed) == nil && owner.groupBridge.sessions[managed] == nil && tap.sent.isEmpty, "managed mention creates no group or TAP send")
        _ = owner.composerSend(threadID: managed, text: "@@ChatGPT managed fixture", model: "gpt-6.1-sol", engine: .codex)
        check(owner.groupBridge.sessions[managed] == nil && tap.sent.isEmpty, "managed composer mention creates no group or TAP send")
        check(!FileManager.default.fileExists(atPath: owner.store.url.deletingLastPathComponent().appendingPathComponent("group-\(managed).json").path), "managed mention creates no ledger")
        check(route(normal) == true, "normal mention enters group")
        for _ in 0..<400 { if tap.sent.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        check(owner.groupBridge.sessions[normal] != nil && tap.sent.count == 1, "normal group reaches synthetic TAP")
        let forwardSequence = owner.groupBridge.sessions[normal]?.record(speaker: "ChatGPT", text: "forward fixture", kind: "summary") ?? -1
        check(owner.groupBridge.sessions[normal]?.coderRelay(forwardSequence) != nil, "forwarding fixture has valid ChatGPT event")
        owner.markControllerThread(normal, fingerprint: "fixture-controller")
        let before = tap.sent.count
        check(route(normal) == nil && tap.sent.count == before, "existing group routing stops after becoming managed")
        var refused = false
        owner.groupBridge.taps[0].invoke(normal, "private relay fixture") { result in if case .failure = result { refused = true } }
        check(refused && tap.sent.count == before, "queued TAP transport rechecks managed marker")
        check(!owner.groupBridge.forwardToCoder(normal, eventSequence: forwardSequence, model: "gpt-6.1-sol", engine: .codex), "managed group forwarding refused")
        print("W231 SUMMARY passed=\(passed) failures=\(failures)")
        return failures == 0
    }
}
#endif
