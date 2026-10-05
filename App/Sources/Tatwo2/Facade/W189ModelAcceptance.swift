#if DEBUG
import Foundation

enum W189ModelAcceptance {
    @MainActor static func run() -> Bool {
        guard NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment) else {
            print("W189MODELS SUMMARY failures=1 (fixture isolation required)")
            return false
        }
        var passed = 0, failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1 }
            print("W189MODELS \(condition ? "PASS" : "FAIL") \(name)")
        }
        check("M2 Sonnet provider argument survives assistant routing",
              AssistantModelRouting.modelArgument(ChatRouteChoice.resolve("sonnet5"), kind: .claude) == "claude-sonnet-5")
        check("M2 explicit remote engine overrides prior Codex engine and model heuristic",
              OSAgentBridge.sendMessageEngine(modelArgument: "sample-model", requested: "claude", threadEngine: "codex") == .claude)
        for id in ["claude-opus-5[1m]", "claude-opus-5-20260901[1m]"] {
            check("M4 \(id) restores retired Opus replacement", ChatRouteChoice.resolve(id).id == "opus5.5")
        }
        check("M4 current Claude suffix retains provider argument",
              ChatRouteChoice.resolve("claude-fable-5-1[1m]").modelArgument == "claude-fable-5-1")
        check("M4 unknown variant stays unavailable", ChatRouteChoice.resolve("sample-model[1m]").runtimeAdapter == .unavailable)
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!).appendingPathComponent("models-fixture")
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        check("M9 first cold Coder thread stores all defaults", engine.threadRecord(engine.doc.selectedThreadID!)?.requestedModel == "gpt-6.1-sol")
        let first = engine.newThread(in: nil)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        let previousCatalog = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(previousCatalog); engine.shutdownAll() }
        ChatGPTTapModelCatalog.replace([TapModel(id: "fixture-model", title: "Fixture", detail: "",
                                                efforts: [TapEffort(id: "max", title: "Fixture effort")])])
        model.chatGPTTapConnectionTestDouble = { .ready }
        let tapRoute = ChatGPTTapModelCatalog.routeID("fixture-model")
        model.setSingleModel(tapRoute)
        model.selectTapEffort("max")
        check("M7 TAP selection and native effort persist before sending",
              engine.threadRecord(first)?.requestedModel == tapRoute && engine.threadRecord(first)?.requestedEffort == "max")
        let second = engine.newThread(in: nil)
        model.selectedThreadID = second
        model.selectedThreadID = first
        check("M7 switching away restores unsent TAP choice", model.selectedModel == tapRoute && model.selectedTapEffortID == "max")
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        let restarted = ChatPageModel(environment: env, botCoreFixture: (reopened, BotStore(root: root)))
        check("M7 restart restores unsent TAP choice", restarted.selectedModel == tapRoute && restarted.selectedTapEffortID == "max")
        let script = root.appendingPathComponent("fixture-sidecar.mjs")
        try! #"""
        import readline from 'node:readline';
        const sdk = msg => console.log(JSON.stringify({ev:'sdk',msg}));
        sdk({type:'system',subtype:'init',session_id:'fixture-session',model:'gpt-5.6-terra'});
        readline.createInterface({input:process.stdin}).on('line',line => {
          const cmd=JSON.parse(line);
          if(cmd.op==='send') sdk({type:'system',subtype:'turn_accepted',client_turn_id:cmd.uuid});
          if(cmd.op==='close') process.exit(0);
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior
        overrides["tatwo2.sidecarPath.codex"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        model.setSingleModel("codex-auto-review")
        check("M8 fixture turn accepted", engine.send(threadID: first, text: "fixture", model: "gpt-5.6-terra", engine: .codex))
        check("M8 provider argument does not overwrite Auto Review route", engine.threadRecord(first)?.requestedModel == "codex-auto-review")
        model.selectedThreadID = second
        model.selectedThreadID = first
        check("M8 route survives switch after a send", model.selectedModel == "codex-auto-review")
        engine.onChange = { [weak model] in
            guard let model else { return }
            model.document = engine.document
            model.isRunning = engine.isRunning(model.selectedThreadID)
            model.applyPendingModelSelectionIfPossible()
        }
        defer { engine.onChange = nil }
        let secondModel = engine.threadRecord(second)?.requestedModel
        model.setSingleModel("opus5.5")
        check("M1 running A queues next model", model.pendingModelID == "opus5.5")
        let restoredQueue = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        check("M1 pending selection survives model reconstruction", restoredQueue.pendingModelID == "opus5.5")
        model.selectedThreadID = second
        check("M1 switching to idle B preserves B model", engine.threadRecord(second)?.requestedModel == secondModel)
        check("M1 B does not display A pending choice", model.pendingModelID == nil)
        engine.handleSDK(first, ["type": "result", "subtype": "success", "is_error": false, "result": "fixture"])
        check("M1 only A receives the next model when A ends", engine.threadRecord(first)?.requestedModel == "opus5.5" && engine.threadRecord(second)?.requestedModel == secondModel)
        model.selectedThreadID = first
        check("M1 switching back restores completed selection", model.selectedModel == "opus5.5")
        let pending = PendingModelSelections(root: root.appendingPathComponent("queue-fixture"))
        try! pending.set(deviceID: "fixture-device", threadID: first, routeID: "opus5.5", pending: true)
        try! pending.set(deviceID: "sample-device", threadID: first, routeID: "sonnet5", pending: true)
        try! pending.set(deviceID: "fixture-device", threadID: first, routeID: "opus5.5", pending: false)
        let reloaded = PendingModelSelections(root: root.appendingPathComponent("queue-fixture"))
        check("M1 same thread UUID on different devices stays isolated and durable",
              reloaded.entry(deviceID: "fixture-device", threadID: first)?.pending == false &&
              reloaded.entry(deviceID: "sample-device", threadID: first)?.routeID == "sonnet5" &&
              reloaded.entry(deviceID: "sample-device", threadID: first)?.pending == true)
        let fresh = engine.newThread(in: nil)
        model.selectedThreadID = fresh
        let freshRecord = engine.threadRecord(fresh)
        check("M9 new thread stores model effort and speed at creation",
              freshRecord?.requestedModel == "gpt-6.1-sol" && freshRecord?.requestedEffort == "medium" && freshRecord?.requestedSpeedTier == "fast")
        check("M9 Coder and DM resolve the same untouched thread",
              model.dmSessionModelChipTitle(fresh) == AssistantModelRouting.chipName(model.routeChoice))
        engine.handleSDK(fresh, ["type": "system", "subtype": "engine_error", "message": "unsupported model fixture",
                                "details": "{\"error\":{\"message\":\"unsupported model fixture\"}}"])
        let errorRow = engine.transcript(for: fresh).last
        check("M5 error has readable cause and named alternative", errorRow?.text.contains("不支援") == true && errorRow?.text.contains("GPT-6") == true)
        check("M5 raw JSON is retained in details rather than the message", errorRow?.engineErrorDetails?.contains("unsupported model fixture") == true && errorRow?.text.hasPrefix("{") == false)
        let saved = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        check("M5 expanded details survive restart", saved.transcript(for: fresh).last?.engineErrorDetails == errorRow?.engineErrorDetails)
        let count = engine.transcript(for: fresh).count
        engine.handleSDK(fresh, ["type": "result", "subtype": "error", "is_error": true, "result": ""])
        check("M5 empty failed completion adds no blank error", engine.transcript(for: fresh).count == count)
        engine.handleSDK(fresh, ["type": "system", "subtype": "turn_error", "message": "fixture retry", "retrying": true, "details": "{}"])
        check("M5 retry is informational", engine.transcript(for: fresh).last?.status == "info|引擎重試")
        let bundled = EngineRuntimeSelection.Candidate(path: URL(fileURLWithPath: "/fixture/bundled"), version: "0.99.0", verified: true, developerID: true, teamID: "fixture-team")
        var local = bundled; local.path = URL(fileURLWithPath: "/fixture/local"); local.version = "0.160.0"
        check("M3 newer verified same-team executable wins semantic comparison", EngineRuntimeSelection.choose(bundled: bundled, local: local).source == "本機")
        local.teamID = "sample-team"
        check("M3 other Team ID is rejected with a visible reason", EngineRuntimeSelection.choose(bundled: bundled, local: local).reason?.contains("Team ID") == true)
        local.teamID = bundled.teamID; local.verified = false
        check("M3 failed signature never executes local binary", EngineRuntimeSelection.choose(bundled: bundled, local: local).executable == bundled.path)
        local.verified = true; local.developerID = false
        check("M3 ad-hoc local signature is rejected", EngineRuntimeSelection.choose(bundled: bundled, local: local).source == "App 內附")
        local.developerID = true; local.version = "0.98.0"
        check("M3 older local engine cannot replace bundle", EngineRuntimeSelection.choose(bundled: bundled, local: local).source == "App 內附")
        let priorCatalogs = EngineModelCatalog.catalogs()
        defer { EngineModelCatalog.replace(priorCatalogs); EngineModelCatalog.replace([], deviceID: "fixture-device") }
        let capability = EngineModelCatalog.Model(model: "gpt-5.6-sol", displayName: "Fixture engine model", efforts: ["low", "medium", "max", "ultra"], defaultEffort: "low", speeds: ["standard"], defaultSpeed: "standard", images: true)
        let unknown = EngineModelCatalog.Model(model: "sample-model", displayName: "Sample engine display", efforts: ["medium"], defaultEffort: "medium", speeds: [], defaultSpeed: "", images: false)
        let catalog = EngineModelCatalog.Catalog(engine: "codex", identity: "fixture-runtime|0.160.0", source: "app-server model/list", models: [capability, unknown])
        EngineModelCatalog.replace([catalog])
        let actual = ChatRouteChoice.resolve("gpt-5.6-sol")
        check("M10 5.6 effort menu and default come from actual engine", actual.allowedEfforts == [.low, .medium, .max, .ultra] && actual.defaultEffort == .low)
        check("M10 restored unsupported effort uses engine default", actual.profile.compatibleReasoningValue("high") == "low")
        check("M10 speed menu shares the same capability source", actual.allowedSpeedTiers == [.standard] && actual.defaultSpeedTier == .standard)
        check("M10 unknown engine model uses engine display name", ChatRouteChoice.resolve("sample-model").title == "Sample engine display")
        check("M10 engine-unavailable model cannot silently route", ChatRouteChoice.resolve("gpt-6.1-sol").runtimeAdapter == .unavailable)
        check("M10 unsupported engine model rejects dispatch with a readable error", !engine.send(threadID: fresh, text: "fixture", model: "gpt-6.1-sol", engine: .codex) && engine.transcript(for: fresh).last?.text.contains("不支援") == true)
        check("M10 fallback table explicitly labels missing engine data", ChatRouteChoice.resolve("sonnet5").profile.menuSubtitle.contains("備援表"))
        EngineModelCatalog.replace([EngineModelCatalog.Catalog(engine: "codex", identity: "sample-runtime", source: "app-server model/list", models: [unknown])], deviceID: "fixture-device")
        check("M10 device-scoped models do not leak from local runtime", ChatRouteChoice.resolve("gpt-5.6-sol", deviceID: "fixture-device").runtimeAdapter == .unavailable && ChatRouteChoice.resolve("gpt-5.6-sol").runtimeAdapter == .codexExec)
        let command = ClaudeSidecar.sendCommand(kind: .claude, text: "fixture", uuid: "fixture", attachments: [], model: "sample-claude", reasoningEffort: "max", serviceTier: "priority")
        check("M10 Claude native effort and speed reach the sidecar", command["effort"] as? String == "max" && command["serviceTier"] as? String == "priority")
        check("M2 missing remote model resolves Claude provider argument", RemoteLiveEngine.remoteProviderModel(nil, engine: .claude, thread: nil) == "claude-fable-5-1")
        print("W189MODELS SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }
}
#endif
