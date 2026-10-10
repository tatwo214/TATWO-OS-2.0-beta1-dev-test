#if DEBUG
import AppKit
import Combine
import Foundation

/// Only synthetic catalogs, transport, preferences and isolated document storage.
@MainActor
enum W297Acceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let live = env["TATWO2_LIVE_ROOT"] else { throw TapError.notReady }
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1 } else { failed += 1 }
            print("W297 \(value ? "PASS" : "FAIL") \(label)")
        }
        defer { print("W297 SUMMARY failures=\(failed) passed=\(passed)") }
        let root = URL(fileURLWithPath: live).appendingPathComponent("w297")
        let old = "chatgpt-tap:gpt-5-5-mini"
        let first = TapModel(id: "gpt-6-mini", title: "GPT-6 Mini", detail: "")
        let preferred = TapModel(id: "gpt-6", title: "GPT-6", detail: "",
                                 efforts: [TapEffort(id: "six-standard", title: "Standard")])
        let items = [first, preferred]
        let previous = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(previous) }
        try await catalogObservation(check)
        ChatGPTTapModelCatalog.rememberDisplayName("GPT-5.5 Mini", routeID: old)
        for scenario in ["loaded", "cold", "refresh-removes-selected", "refresh-fails", "catalog-changes-during-preparation"] {
            let tap = W185FakeConversationTap()
            tap.modelFixture = (items, preferred.id, "six-standard")
            tap.modelFailure = scenario == "refresh-fails"
            let store = ChatLiveStore(root: root.appendingPathComponent(scenario))
            var doc = LiveDocumentRecord()
            var thread = LiveThreadRecord(projectID: doc.ensureGeneralProject(), title: "Synthetic")
            thread.engine = "chatgpt-tap"; thread.model = old; thread.requestedModel = old
            thread.requestedEffort = "gpt-5-6"
            doc.threads = [thread]; store.save(doc)
            if scenario == "loaded" || scenario == "catalog-changes-during-preparation" {
                ChatGPTTapModelCatalog.replace(items, currentEffortID: "six-standard", defaultModelID: preferred.id)
            } else if scenario == "refresh-removes-selected" {
                ChatGPTTapModelCatalog.replace([TapModel(id: "gpt-5-5-mini", title: "GPT-5.5 Mini", detail: "")],
                                              fetchedAt: Date().addingTimeInterval(-600))
            } else { ChatGPTTapModelCatalog.replace([]) }
            let engine = ChatLiveEngine(store: store, environment: env, tap: tap)
            defer { engine.shutdownAll() }
            let coder = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent(scenario + "-bots"))))
            coder.selectedThreadID = thread.id
            coder.engineLoginTestDouble = []
            coder.chatGPTTapConnectionTestDouble = { tap.connection }
            engine.onChange = { coder.document = engine.document; coder.isRunning = engine.isRunning(thread.id) }
            let segment = ChatPage(model: coder).coderComposerMode().segments.first
            if scenario == "loaded" {
                check(segment?.text == "ChatGPT / GPT-6" && segment?.accessibilityLabel == "模型：ChatGPT / GPT-6",
                      "loaded Coder uses server default instead of retired stored title")
                check(coder.dmSessionModelChipTitle(thread.id) == "ChatGPT / GPT-6", "thread DM uses the same current model")
                check(store.load().threads.first?.requestedModel == old, "display alone leaves old storage until send")
            } else if scenario == "cold" {
                check(segment?.text == "ChatGPT" && segment?.short == "ChatGPT" && segment?.accessibilityLabel == "模型：ChatGPT",
                      "cold Coder shows only ChatGPT, including compact and accessibility labels")
                check(coder.dmSessionModelChipTitle(thread.id) == "ChatGPT", "cold thread DM hides historical model name")
                check(coder.sendAvailabilityDiagnostic.contains("重新整理 ChatGPT 模型目錄"), "cold send keeps existing refresh explanation")
            }
            var release: CheckedContinuation<Void, Never>?
            if scenario == "cold" { tap.modelGate = { await withCheckedContinuation { release = $0 } } }
            if scenario == "catalog-changes-during-preparation" { tap.projectGate = { await withCheckedContinuation { release = $0 } } }
            coder.prompt = "Synthetic catalog check"
            check(coder.canSend, "\(scenario) enters TAP preparation without CLI login")
            coder.send()
            if scenario == "cold" {
                try await until { release != nil }
                check(tap.sent.isEmpty && engine.isRunning(thread.id), "cold send waits for model catalog before dispatch")
                release?.resume()
            }
            let expectedModel = scenario == "catalog-changes-during-preparation" ? first : preferred
            let expectedRoute = ChatGPTTapModelCatalog.routeID(expectedModel.id)
            let expectedEffort: String? = expectedModel.efforts.first?.id
            if scenario == "catalog-changes-during-preparation" {
                try await until { release != nil }
                ChatGPTTapModelCatalog.replace([first], defaultModelID: first.id)
                check(tap.sent.isEmpty, "catalog changes during preparation before any dispatch")
                release?.resume()
            }
            if scenario == "refresh-fails" {
                try await until { !engine.isRunning(thread.id) }
                check(tap.sent.isEmpty && coder.prompt == "Synthetic catalog check", "catalog failure submits nothing and restores draft")
                continue
            }
            try await until { tap.sent.count == 1 }
            check(tap.sent.first?.model == expectedModel.id && tap.sent.first?.effort == expectedEffort,
                  "\(scenario) dispatch contains current model and validated effort")
            check(tap.modelCalls == (scenario == "loaded" || scenario == "catalog-changes-during-preparation" ? 0 : 1), "\(scenario) refreshes only when required")
            let saved = store.load().threads.first
            check(saved?.model == expectedRoute && saved?.requestedModel == expectedRoute && saved?.requestedEffort == expectedEffort,
                  "\(scenario) document rewrites model and requestedModel to actual dispatch")
            check(saved?.messages.filter { $0.role == "user" || $0.role == "assistant" }.allSatisfy { $0.modelID == expectedRoute } == true,
                  "\(scenario) current turn records actual model")
            tap.finish(); try await until { !engine.isRunning(thread.id) }
        }
        ChatGPTTapModelCatalog.replace(items, defaultModelID: "not-in-catalog")
        check(ChatRouteChoice.resolve(old).id == ChatGPTTapModelCatalog.routeID(first.id), "missing server default falls back to first current model")
        ChatGPTTapModelCatalog.replace(items, defaultModelID: preferred.id)
        check(ChatRouteChoice.resolve(ChatGPTTapModelCatalog.routeID(first.id)).id == ChatGPTTapModelCatalog.routeID(first.id),
              "valid saved ChatGPT selection stays selected")
        check(!ChatGPTTapModelCatalog.isRouteID(ChatRouteChoice.resolve("gpt-6.1-sol").id), "Codex route stays separate")
        check(ChatRouteChoice.resolve("fable-5.1").runtimeAdapter != .chatgptTap, "Claude route stays separate")
        let originalEngines = EngineModelCatalog.catalogs()
        defer { EngineModelCatalog.replace(originalEngines) }
        let nativeProfiles = TatwoChatRouteProfile.defaults.filter { $0.id != "codex-auto-review" }
        let merged = ["codex", "claude"].map { family in
            EngineModelCatalog.Catalog(engine: family, identity: "synthetic", source: "two sources",
                models: nativeProfiles.filter { $0.engine.rawValue.lowercased() == family }.flatMap { profile in
                    let model = EngineModelCatalog.Model(model: profile.modelArgument ?? profile.id,
                        displayName: profile.displayName, efforts: ["low"], defaultEffort: "low",
                        speeds: [], defaultSpeed: "", images: false)
                    var alias = model; alias.model = model.model.uppercased().replacingOccurrences(of: "-", with: "_")
                    return [model, alias]
                })
        }
        EngineModelCatalog.replace(merged)
        let nativeChoices = ChatRouteChoice.all.filter { $0.runtimeAdapter != .chatgptTap }
        let routeKeys = nativeChoices.map { $0.brandGroup.rawValue + ":" + ChatProviderModelIdentity.lookupKey($0.modelArgument ?? $0.id) }
        check(Set(routeKeys).count == routeKeys.count && nativeChoices.count == nativeProfiles.count, "merged default and duplicate engine sources list every provider/code once")
        for device in ["local", "w297-remote"] {
            if device != "local" { EngineModelCatalog.replace(merged, deviceID: device) }
            let sections = ChatRouteChoice.brandSections(selectedID: nil, deviceID: device)
            check(sections.allSatisfy { section in
                let codes = section.choices.map { ChatProviderModelIdentity.lookupKey($0.modelArgument ?? $0.id) }
                return codes.count == Set(codes).count
            }, "\(device) composer sections contain no duplicate codes")
            if device != "local" { EngineModelCatalog.replace([], deviceID: device) }
        }
        check(ChatRouteChoice.all.filter { $0.title == "GPT-6" }.map(\.brandGroup).contains(.chatgptTap)
              && ChatRouteChoice.all.filter { $0.title == "GPT-6" }.map(\.brandGroup).contains(.openAI),
              "same display name remains in Codex and ChatGPT groups")
        check(ChatGPTTapModelCatalog.choice(model: .init(id: "o3", title: "o 3-pro", detail: "")).profile.displayName == "o 3-pro", "TAP preserves exact web name without spelling correction")
        check(ChatGPTTapModelCatalog.effortTitle(TapEffort(id: "web-power|1", title: "1")) == "1"
              && ChatGPTTapModelCatalog.effortTitle(TapEffort(id: "six-t|max", title: "Extra High")) == "Extra High",
              "Power step numbers and unrecognised web labels stay distinct")
        ChatGPTTapModelCatalog.replace([preferred], defaultModelID: preferred.id)
        check(ChatGPTTapModelCatalog.choices.count == 1 && ChatGPTTapModelCatalog.effectiveModel("chatgpt-tap:version:5.5")?.id == preferred.id,
              "legacy version cannot remain a selectable or dispatched route")
        let webTransport = FakeTapPod(running: true) { cmd, _ in
            if cmd != "models" { return ["items": []] }
            return ["models": [], "versions": [
                ["id": "latest", "title": "GPT-6", "presets": (1...5).map { ["id": "web-power|\($0)", "title": "\($0)"] }]],
                "current": ["version": "latest", "preset": "web-power|2"]]
        }
        let webTap = ChatGPTTap(transport: webTransport)
        defer { webTap.sleep() }
        let webCatalog = try await webTap.models()
        ChatGPTTapModelCatalog.replace(webCatalog.items, currentEffortID: webCatalog.currentEffortID, defaultModelID: webCatalog.defaultID)
        let webSection = ChatRouteChoice.brandSections(selectedID: nil).first { $0.brand == .chatgptTap }
        check(webSection?.choices.count == 1 && webSection?.choices.first?.title == "GPT-6"
              && webSection?.choices.first?.tapEfforts.count == 5, "decoded locked web catalog gives one composer model and five Power steps")
        check(webCatalog.defaultID == "version:latest" && webCatalog.currentEffortID == "web-power|2", "web current Power step survives native catalog decoding")
        ChatGPTTapModelCatalog.replace(items, defaultModelID: preferred.id)
        let choice = ChatGPTModelChoice(modelID: "gpt-5-5-mini", effortID: "gpt-5-6")
        let catalog = ChatGPTModelCatalog(models: items, defaultModelID: preferred.id, defaultEffortID: "six-standard")
        let args = ChatGPTModelMenu.sendArguments(catalog, choice)
        check(args.model == preferred.id && args.effort == "six-standard", "ChatGPT DM validates retired choice and effort against current catalog")
        check(ChatGPTModelMenu.chipTitle(.init(), choice) == "ChatGPT", "cold ChatGPT DM shows only ChatGPT")

        let defaults = UserDefaults.standard
        let keys = [ChatGPTSpaceModel.pageModelKey, ChatGPTSpaceModel.pageEffortKey, ChatGPTSpaceModel.modelKey, ChatGPTSpaceModel.effortKey]
        let prior = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) } }
        defaults.set("gpt-5-6", forKey: ChatGPTSpaceModel.pageModelKey)
        defaults.set("gpt-5-6", forKey: ChatGPTSpaceModel.pageEffortKey)
        let pod = FakeTapPod(running: true) { cmd, _ in
            if cmd == "send" { return nil }
            if cmd == "models" {
                return ["models": [["slug": first.id, "title": first.title],
                                   ["slug": preferred.id, "title": preferred.title, "efforts": [["id": "six-standard", "title": "Standard"]]]],
                        "default": preferred.id, "current": ["preset": "six-standard"]]
            }
            return ["items": [], "messages": []]
        }
        let native = ChatGPTTap(transport: pod)
        defer { native.sleep() }
        let space = ChatGPTSpaceModel(testTap: native)
        let dm = GlobalDMStore(chatGPT: { ChatGPTConversationSession(tap: native) }, chatGPTAllowed: { true },
                               chatGPTCatalog: { Just(ChatGPTModelCatalog()).eraseToAnyPublisher() })
        check(dm.pickerLabel.level == "ChatGPT", "cold native DM capsule shows only ChatGPT")
        check(space.pageModelID == "gpt-5-6" && space.pickerLabel.level == "ChatGPT", "cold Space hides stored page model")
        await space.refresh()
        try await until { !space.models.isEmpty && space.pageModelID == preferred.id }
        check(space.effectiveModelID == preferred.id && space.pageModelID == preferred.id && space.pageEffortID == "six-standard",
              "Space replaces retired page model and effort with current server defaults")
        check(defaults.string(forKey: ChatGPTSpaceModel.pageModelKey) == preferred.id && defaults.string(forKey: ChatGPTSpaceModel.pageEffortKey) == "six-standard",
              "Space rewrites isolated page UserDefaults")
        defaults.set(first.id, forKey: ChatGPTSpaceModel.pageModelKey)
        let mixed = ChatGPTSpaceModel(testTap: native)
        mixed.selectedModelID = "gpt-5-5-mini"
        await mixed.refresh(); try await until { !mixed.models.isEmpty }
        check(mixed.effectiveModelID == preferred.id, "retired explicit Space selection uses server default even with another valid page model")
        space.selectedModelID = "gpt-5-5-mini"; space.selectedEffortID = "gpt-5-6"
        space.draft = "Synthetic Space check"; space.send()
        try await until { pod.sends.count == 1 }
        check(pod.sends.first?["model"] as? String == preferred.id && pod.sends.first?["effort"] as? String == "six-standard",
              "Space native dispatch uses only current catalog IDs")
        check(space.selectedModelID == preferred.id && defaults.string(forKey: ChatGPTSpaceModel.modelKey) == preferred.id,
              "Space rewrites retired explicit model on send")
        pod.stream("finished")
        return failed == 0
    }
    private static func until(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { throw TapError.remote("W297 fixture timeout") }
    }
    private static func catalogObservation(_ check: (Bool, String) -> Void) async throws {
        ChatGPTTapModelCatalog.replace([])
        let pod = W305CatalogPod(running: true) { cmd, _ in
            cmd == "models" ? ["models": [["slug": "gpt-6", "title": "GPT-6"]]] : [:]
        }
        let tap = ChatGPTTap(transport: pod, connection: .sleeping)
        let previousObserver = ChatGPTTapModelObservation.current
        var changes = 0, notices = 0
        let observer = ChatGPTTapModelObservation(tap: tap, onNotice: { _ in notices += 1 }) { changes += 1 }
        defer { tap.sleep(); ChatGPTTapModelObservation.current = previousObserver }
        pod.emit(["type": "hello", "loggedIn": true])
        try await until { ChatGPTTapModelCatalog.isFresh }
        check(pod.modelCalls == 1 && ChatGPTTapModelCatalog.choices.map(\.title) == ["GPT-6"],
              "W305 cold ready reads real TAP transport before any send")
        observer.refreshIfNeeded()
        check(pod.modelCalls == 1, "W305 fresh menu does not reread")
        let saved = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(saved, fetchedAt: Date().addingTimeInterval(-600))
        pod.hold = true
        observer.refreshIfNeeded(); observer.refreshIfNeeded()
        try await until { pod.pending != nil }
        check(pod.modelCalls == 2, "W305 expired menu starts one background read")
        observer.refreshIfNeeded()
        check(pod.modelCalls == 2, "W305 reopening while reading does not duplicate or cancel read")
        pod.release()
        try await until { ChatGPTTapModelCatalog.isFresh }
        pod.failure = "讀不到網頁目前模型"
        ChatGPTTapModelCatalog.replace(saved, fetchedAt: Date().addingTimeInterval(-600))
        let before = changes
        observer.refreshIfNeeded()
        try await until { changes > before && ChatGPTTapModelCatalog.failureReason != "ChatGPT 模型讀取中" }
        check(ChatGPTTapModelCatalog.snapshot == saved && !ChatGPTTapModelCatalog.isFresh
              && ChatGPTTapModelCatalog.unavailabilityReason(connection: .ready, routeID: "chatgpt-tap:gpt-6") == nil,
              "W305 failed read preserves stale selectable models")
        let env = ProcessInfo.processInfo.environment
        let store = ChatLiveStore(root: URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!).appendingPathComponent("w305-ui"))
        let engine = ChatLiveEngine(store: store, environment: env, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: store.url.deletingLastPathComponent().appendingPathComponent("bots"))))
        model.chatGPTTapConnectionTestDouble = { tap.connection }
        let mode = ChatPage(model: model).coderComposerMode()
        check(mode.models.first?.options.contains { $0.id == "chatgpt-tap:gpt-6" && $0.title.contains("待更新") && !$0.isDisabled } == true,
              "W305 Coder mode lists cached model with pending update label")
        do { try await ChatGPTTapModelCatalog.refreshForSend(tap: tap); check(false, "W305 failed send refresh blocks") }
        catch { check(pod.sends.isEmpty && ChatGPTTapModelCatalog.snapshot == saved, "W305 failed send refresh blocks and preserves list") }
        ChatGPTTapModelCatalog.replace([])
        let coldBefore = changes
        observer.refreshIfNeeded()
        try await until { changes > coldBefore && ChatGPTTapModelCatalog.failureReason != "ChatGPT 模型讀取中" }
        let reason = ChatGPTTapModelCatalog.unavailabilityReason(connection: .ready)
        let coldMode = ChatPage(model: model).coderComposerMode()
        check(reason == "ChatGPT 頁面沒有模型選單"
              && coldMode.models.first?.options.contains { $0.id == "chatgpt-tap:unavailable" && $0.title.contains(reason!) } == true,
              "W305 never loaded failure row displays cause")
        let diagnostics = await tap.diagnostics()
        check(diagnostics.contains { $0.0 == "模型目錄讀取" && $0.1 == "讀取失敗：ChatGPT 頁面沒有模型選單" },
              "W305 existing diagnostics record read step and fixed reason")
        check(ChatGPTTap.modelReadFailureReason(TapError.remote("Synthetic private page text")) == "ChatGPT 模型讀取失敗（回應無法辨識）",
              "W305 unknown errors cannot expose page content in diagnostics")
        pod.failure = nil
        pod.empty = true
        ChatGPTTapModelCatalog.replace(saved, fetchedAt: Date().addingTimeInterval(-600))
        let emptyBefore = changes
        observer.refreshIfNeeded()
        try await until { changes > emptyBefore && ChatGPTTapModelCatalog.failureReason != "ChatGPT 模型讀取中" }
        check(ChatGPTTapModelCatalog.snapshot == saved && ChatGPTTapModelCatalog.failureReason == "ChatGPT 模型目錄是空的",
              "W305 empty response preserves previous successful catalog")
        tap.sleep()
        let sleepingCalls = pod.modelCalls
        observer.refreshIfNeeded()
        check(pod.modelCalls == sleepingCalls && pod.starts == 0 && notices == 0,
              "W305 menu never wakes sleeping Pod or shows notices")
        ChatGPTTapModelCatalog.replace([])
    }
}

@MainActor
private final class W305CatalogPod: FakeTapPod {
    var failure: String?
    var hold = false, empty = false
    var pending: (command: [String: Any], id: String, cmd: String)?
    var modelCalls: Int { commands.filter { $0["cmd"] as? String == "models" }.count }
    override func respond(_ command: [String: Any], id: String, cmd: String) {
        if cmd == "models" {
            if hold { pending = (command, id, cmd); return }
            if let failure { emit(["type": "result", "id": id, "ok": false, "message": failure]); return }
            if empty { emit(["type": "result", "id": id, "ok": true, "data": ["models": []]]); return }
        }
        super.respond(command, id: id, cmd: cmd)
    }
    func release() {
        hold = false
        if let pending { self.pending = nil; respond(pending.command, id: pending.id, cmd: pending.cmd) }
    }
}
#endif
