import Foundation

/// Real thread-store and ChatPageModel hydration without launching an engine.
enum ModelPreferencesAcceptance {
    @MainActor static func run() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TATWO2_ISSUE_TEST_ROOT"] else { return false }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-only").path),
              environment["TATWO2_LIVE_ROOT"] == root.appendingPathComponent("live").path,
              environment["TATWO2_ENGINES_ROOT"] == root.appendingPathComponent("engines").path else { return false }
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1 }
            print("MODELPREFERENCESTEST \(condition ? "PASS" : "FAIL") \(name)")
        }
        let currentGPTModels = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
        check("picker begins with all four GPT-6 routes",
              Array(TatwoChatRouteProfile.defaults.prefix(4).map(\.id)) == currentGPTModels)
        check("GPT-6.1 Sol catalog keeps low default and 272k context",
              TatwoChatRouteProfile.resolve("gpt-6.1-sol").defaultEffort == .low &&
              TatwoChatRouteProfile.resolve("gpt-6.1-sol").contextWindowLabel == "272k")
        for id in currentGPTModels {
            let route = ChatRouteChoice.resolve(id)
            check("\(id) resolves without changing its model",
                  route.id == id && route.canonicalModelSlug == id &&
                  TatwoChatRouteProfile.resolve(id).modelArgument == id)
            check("\(id) supports native Fast and standard",
                  route.allowedSpeedTiers == [.fast, .standard] && route.defaultSpeedTier == .fast)
            let command = ClaudeSidecar.sendCommand(
                kind: .codex, text: "fixture", uuid: id, attachments: [],
                model: id, reasoningEffort: "medium", serviceTier: "priority")
            check("\(id) forwards model, medium and priority",
                  command["model"] as? String == id && command["effort"] as? String == "medium" &&
                  command["serviceTier"] as? String == "priority")
        }
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: environment)
        let project = engine.newProject(name: "model-fixture", workdir: root.path)
        let first = engine.newThread(in: project)
        let model = ChatPageModel(environment: environment,
                                  botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("live"))))
        check("new chat uses GPT-6.1 Sol", model.selectedModel == "gpt-6.1-sol")
        check("new chat uses medium reasoning", model.selectedEffort == .medium)
        check("new chat uses Fast", model.selectedSpeedTier == .fast)
        check("new thread stores defaults at creation", engine.threadRecord(first)?.requestedModel == "gpt-6.1-sol" && engine.threadRecord(first)?.requestedEffort == "medium" && engine.threadRecord(first)?.requestedSpeedTier == "fast")
        model.setSingleModel("gpt-5.6-sol")
        model.selectedEffort = .high
        model.selectedSpeedTier = .standard
        check("explicit model is stored before sending", engine.threadRecord(first)?.requestedModel == "gpt-5.6-sol")
        check("explicit effort is stored", engine.threadRecord(first)?.requestedEffort == "high")
        check("explicit speed is stored", engine.threadRecord(first)?.requestedSpeedTier == "standard")
        let second = engine.newThread(in: project)
        model.selectedThreadID = second
        check("new chat does not inherit another chat's model", model.selectedModel == "gpt-6.1-sol")
        check("new chat resets to medium Fast", model.selectedEffort == .medium && model.selectedSpeedTier == .fast)
        model.selectedThreadID = first
        check("switching back restores explicit selection", model.selectedModel == "gpt-5.6-sol" && model.selectedEffort == .high && model.selectedSpeedTier == .standard)
        model.selectedThreadID = second
        model.setSingleModel("gpt-6-astra")
        model.selectedEffort = .xhigh
        model.selectedSpeedTier = .standard
        let third = engine.newThread(in: project)
        model.selectedThreadID = third
        check("legacy GPT-6 selection stays stored", engine.threadRecord(second)?.requestedModel == "gpt-6-astra")
        check("new chat after legacy selection uses Sol medium Fast",
              model.selectedModel == "gpt-6.1-sol" && model.selectedEffort == .medium && model.selectedSpeedTier == .fast)
        model.selectedThreadID = first
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment)
        let restarted = ChatPageModel(environment: environment,
                                      botCoreFixture: (reopened, BotStore(root: root.appendingPathComponent("live"))))
        check("restart restores explicit selection", restarted.selectedModel == "gpt-5.6-sol" && restarted.selectedEffort == .high && restarted.selectedSpeedTier == .standard)
        restarted.selectedThreadID = third
        check("restart keeps untouched new-chat defaults", restarted.selectedModel == "gpt-6.1-sol" && restarted.selectedEffort == .medium && restarted.selectedSpeedTier == .fast)
        restarted.selectedThreadID = second
        check("restart retains legacy GPT-6 model and controls",
              restarted.selectedModel == "gpt-6-astra" && restarted.selectedEffort == .xhigh &&
              restarted.selectedSpeedTier == .standard)
        check("Fast uses native catalog ID", TatwoModelSpeedTier.fast.appServerValue == "priority")
        check("standard explicitly resets native Fast", TatwoModelSpeedTier.standard.appServerValue == "default")
        check("CLI speed mapping remains unchanged", TatwoModelSpeedTier.fast.codexArguments == ["-c", "service_tier=\"fast\""] && TatwoModelSpeedTier.standard.codexArguments.isEmpty)
        let old = Data("{\"title\":\"legacy\",\"requestedModel\":\"gpt-5.6-sol\"}".utf8)
        let decoded = try? JSONDecoder().decode(LiveThreadRecord.self, from: old)
        check("legacy documents retain explicit model", decoded?.requestedModel == "gpt-5.6-sol")
        check("legacy documents tolerate missing effort and speed", decoded != nil && decoded?.requestedEffort == nil && decoded?.requestedSpeedTier == nil)
        let command = ClaudeSidecar.sendCommand(kind: .codex, text: "fixture", uuid: "one", attachments: [],
                                               model: "gpt-6-astra", reasoningEffort: "medium",
                                               serviceTier: TatwoModelSpeedTier.fast.appServerValue)
        check("Swift command carries requested model and effort", command["model"] as? String == "gpt-6-astra" && command["effort"] as? String == "medium")
        check("Swift command carries native speed ID", command["serviceTier"] as? String == "priority")
        for kind in [ClaudeSidecar.Kind.claude, .grok] {
            let command = ClaudeSidecar.sendCommand(kind: kind, text: "fixture", uuid: "one", attachments: [],
                                                   model: "fixture", reasoningEffort: "medium", serviceTier: "priority")
            check("OpenAI controls are not forwarded to \(kind.rawValue)", command["effort"] == nil && command["serviceTier"] == nil && command["model"] == nil)
        }
        check("unknown thread cannot accept a send", !engine.send(threadID: UUID(), text: "fixture", model: "gpt-6-astra", engine: .codex))
        let extended: [TatwoCodexReasoningEffort] = [.low, .medium, .high, .xhigh, .max, .ultra]
        for id in ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-astra"] {
            let route = ChatRouteChoice.resolve(id)
            check("\(id) has Codex 0.160 six reasoning levels", route.allowedEfforts == extended)
        }
        let luna = ChatRouteChoice.resolve("gpt-6-luna")
        check("Luna supports max, not ultra", luna.allowedEfforts == Array(extended.dropLast()))
        for route in ChatRouteChoice.all where route.runtimeAdapter == .claudeCLI || route.runtimeAdapter == .grokCLI {
            check("\(route.id) has no new reasoning levels", !route.allowedEfforts.contains(.max) && !route.allowedEfforts.contains(.ultra))
        }
        let sol = ChatRouteChoice.resolve("gpt-6.1-sol")
        let legacy = ChatRouteChoice.resolve("grok-build")
        for (level, effort) in [(ChatCollaborationLevel.s, TatwoCodexReasoningEffort.low),
                                (.m, .medium), (.l, .high), (.xl, .xhigh), (.xxl, .max)] {
            check("Sol slider \(level.title) maps to \(effort.rawValue)",
                  TatwoComposerMode.collaborationEffort(level, route: sol) == effort)
        }
        check("legacy XXL stays xhigh", TatwoComposerMode.collaborationEffort(.xxl, route: legacy) == .xhigh)
        check("off leaves effort alone", TatwoComposerMode.collaborationEffort(.off, route: sol) == nil)
        model.setSingleModel(sol.id)
        for (level, effort) in [(ChatCollaborationLevel.s, TatwoCodexReasoningEffort.low),
                                (.m, .medium), (.l, .high), (.xl, .xhigh), (.xxl, .max)] {
            let card = TatwoComposerMode.coder(model: model,
                                              roleModelID: { model.ultraworkRoleModelID($0, for: first) },
                                              chooseRole: { _, _ in }, chooseModel: { _ in })
            card.collaboration?.setLevel(level)
            check("real card \(level.title) persists \(effort.rawValue)",
                  model.selectedEffort == effort && engine.threadRecord(first)?.requestedEffort == effort.rawValue)
        }
        let steps = TatwoComposerMode.effortSteps(route: sol, selected: .ultra) { _ in }
        check("Ultra is last in the list, never on the slider",
              steps?.options.last?.id == "ultra" && steps?.sliderOptions.map(\.id) == extended.dropLast().map(\.rawValue)
              && steps?.sliderSelectedIndex == nil && steps?.selectedTitle == "Ultra（自動分派）")
        check("unsupported card has no Ultra", TatwoComposerMode.effortSteps(route: legacy, selected: .xhigh) { _ in }?.hasUltra == false)
        check("Ultra quota warning is explicit", TatwoComposerMode.ultraWarning == "會自動分派子代理，較耗額度")
        for effort in extended {
            let encoded = try? JSONEncoder().encode(effort)
            check("\(effort.rawValue) Codable round trip", encoded.flatMap { try? JSONDecoder().decode(TatwoCodexReasoningEffort.self, from: $0) } == effort)
            model.setSingleModel(sol.id)
            model.selectedEffort = effort
            let reread = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment)
            let hydrated = ChatPageModel(environment: environment,
                                        botCoreFixture: (reread, BotStore(root: root.appendingPathComponent("live"))))
            check("\(effort.rawValue) survives store reload and model hydration",
                  reread.threadRecord(first)?.requestedEffort == effort.rawValue && hydrated.selectedEffort == effort)
        }
        for effort in [TatwoCodexReasoningEffort.max, .ultra] {
            check("\(effort.rawValue) exact Codex CLI argument",
                  effort.codexArguments == ["-c", "model_reasoning_effort=\"\(effort.rawValue)\""])
            check("\(effort.rawValue) gateway unchanged, Claude capped",
                  effort.gatewayReasoningValue == effort.rawValue && effort.claudeRawValue == "xhigh")
            let command = ClaudeSidecar.sendCommand(kind: .codex, text: "fixture", uuid: "extended", attachments: [],
                                                   model: sol.id, reasoningEffort: sol.profile.compatibleReasoningValue(effort.rawValue), serviceTier: nil)
            check("\(effort.rawValue) reaches Codex turn", command["effort"] as? String == effort.rawValue)
            model.setSingleModel(sol.id)
            model.selectedEffort = effort
            TatwoComposerMode.applyCoderRoute(legacy, to: model)
            check("\(effort.rawValue) downgrades on model switch with visible explanation",
                  model.selectedEffort == .xhigh && engine.threadRecord(first)?.requestedEffort == "xhigh"
                  && model.composerHint?.contains("不支援") == true && model.composerHint?.contains("超高") == true)
            check("\(effort.rawValue) never sent to legacy engine", legacy.profile.compatibleReasoningValue(effort.rawValue) == "xhigh")
        }
        model.setSingleModel(sol.id)
        model.selectedEffort = .ultra
        model.setSingleModel(luna.id)
        check("Ultra → Luna becomes max, not default medium", model.selectedEffort == .max && engine.threadRecord(first)?.requestedEffort == "max")
        model.setSingleModel(sol.id)
        model.selectedEffort = .ultra
        model.isRunning = true
        TatwoComposerMode.applyCoderRoute(legacy, to: model)
        check("queued route change also caps Ultra at highest supported",
              model.pendingModelID == legacy.id && model.selectedEffort == .xhigh && model.composerHint?.contains("不支援") == true)
        model.isRunning = false
        model.applyPendingModelSelectionIfPossible()
        check("queued route becomes legacy xhigh, not default", model.selectedModel == legacy.id && model.selectedEffort == .xhigh)
        engine.setModelPreferences(threadID: first, model: legacy.id, effort: "ultra", speedTier: "standard")
        check("engine preference writes also cap unsupported Ultra", engine.threadRecord(first)?.requestedEffort == "xhigh")
        let unsupported = TatwoChatRouteProfile(id: "fixture-no-effort", displayName: "Fixture", family: "Fixture",
                                               engine: .codex, modelArgument: nil, contextWindowLabel: "",
                                               supportsImageInput: false, pluginFit: "", sessionRisk: "",
                                               defaultEffort: .medium, allowedEfforts: [], notes: [])
        check("routes without effort controls discard extended values",
              unsupported.compatibleReasoningValue("max") == nil && unsupported.compatibleReasoningValue("ultra") == nil)
        check("old transport values remain unchanged", ["low", "medium", "high", "xhigh"].allSatisfy { legacy.profile.compatibleReasoningValue($0) == $0 })
        var stale = store.load()
        if let index = stale.threads.firstIndex(where: { $0.id == first }) {
            stale.threads[index].requestedModel = legacy.id
            stale.threads[index].requestedEffort = "ultra"
            store.save(stale)
        }
        let staleEngine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment)
        let staleModel = ChatPageModel(environment: environment,
                                      botCoreFixture: (staleEngine, BotStore(root: root.appendingPathComponent("live"))))
        check("unsupported stored Ultra hydrates to xhigh with an explanation",
              staleModel.selectedModel == legacy.id && staleModel.selectedEffort == .xhigh && staleModel.composerHint?.contains("不支援") == true)
        check("acceptance never starts a model", engine.sidecarProcessID(threadID: first) == nil && reopened.sidecarProcessID(threadID: first) == nil)
        print("MODELPREFERENCESTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
