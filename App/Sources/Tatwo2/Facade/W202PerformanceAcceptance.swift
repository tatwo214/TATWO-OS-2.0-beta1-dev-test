#if DEBUG
import AppKit
import SwiftUI
import Combine

@MainActor enum W202PerformanceAcceptance {
    private final class Visibility: ObservableObject { @Published var visible = true }
    private struct CoderVisibilityHost: View {
        @ObservedObject var visibility: Visibility
        @WorkspaceObservedObject var model: ChatPageModel
        init(visibility: Visibility, model: ChatPageModel) {
            self.visibility = visibility
            _model = WorkspaceObservedObject(wrappedValue: model, forwardWhenHidden: ChatPageModel.presentationChanges, shouldForward: { _ in false })
        }
        var body: some View {
            let _ = ChatRenderProbe.record("visibility.parent.body")
            ChatPage(model: model)
                .environment(\.tatwoSurfaceKind, .window)
                .environment(\.tatwoWorkspaceVisible, visibility.visible)
                .opacity(visibility.visible ? 1 : 0)
        }
    }
    private struct SpaceVisibilityHost: View {
        @ObservedObject var visibility: Visibility
        let model: ChatGPTSpaceModel
        var body: some View {
            HStack {
                ChatGPTSpaceSidebarList(model: model).frame(width: 250)
                VStack {
                    ChatGPTSpaceMainPane(model: model, showsHeader: false)
                    ChatGPTThinkingRow(thinking: .init())
                }
            }
            .environment(\.tatwoWorkspaceVisible, visibility.visible)
            .opacity(visibility.visible ? 1 : 0)
        }
    }
    private typealias QuietPod = FakeTapPod
    static func run() async throws -> Bool {
        setenv("TATWO_BROWSER_WORKSPACE_PREVIEW", "1", 1)
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let rootPath = env["TATWO2_LIVE_ROOT"] else { throw TapError.remote("W202 requires isolated staging") }
        let root = URL(fileURLWithPath: rootPath).appendingPathComponent("w202")
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let thread = engine.newThread(in: nil, title: "Performance fixture")
        var modelEnv = env
        modelEnv["TATWO_BROWSER_WORKSPACE_PREVIEW"] = "1"
        let model = ChatPageModel(environment: modelEnv, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("bots"))))
        model.selectedThreadID = thread
        model.mode = .chat
        engine.onChange = { model.document = engine.document }
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("W202PERF \(value ? "PASS" : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        let firstLayout = ChatBrowserLayoutObservation(model: model)
        let secondLayout = ChatBrowserLayoutObservation(model: model)
        check(firstLayout.store.registry === model.browserTabRegistry
              && firstLayout.inspectorStore.registry === secondLayout.inspectorStore.registry
              && firstLayout.inspectorRuntime === secondLayout.inspectorRuntime,
              "E7 rebuilding layout keeps the same inspector registry and runtime")
        ChatRenderProbe.browserStore = nil
        let page = ChatPage(model: model)
        let rig = TatwoComposerModeAcceptance.ClickRig(page.environment(\.tatwoSurfaceKind, .window), size: CGSize(width: 1100, height: 760))
        defer { rig.window.close() }
        var watches = Set<AnyCancellable>()
        model.objectWillChange.sink { ChatRenderProbe.record("ChatPageModel.publish") }.store(in: &watches)
        await rig.settle(40)
        guard let store = ChatRenderProbe.browserStore else { throw TapError.remote("W202 missing mounted Browser store") }
        store.objectWillChange.sink { ChatRenderProbe.record("BrowserStore.publish") }.store(in: &watches)
        ChatRenderProbe.reset()
        for _ in 0..<200 {
            rig.host.layoutSubtreeIfNeeded()
            rig.window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        report("idle-10s")
        check(quietChat(), "idle 10 seconds has zero ChatPage and toolbar bodies")
        model.mode = .browser
        store.addTab()
        store.addTab()
        await rig.settle(20)
        let ids = store.tabs.map(\.id)
        var selectionsMatch = Set(ids).count >= 2
        ChatRenderProbe.reset()
        for i in 0..<20 {
            store.select(ids[i % ids.count])
            selectionsMatch = selectionsMatch && store.selectedTab.id == ids[i % ids.count]
            await rig.settle(2)
        }
        report("browser-20-tab-switches")
        check(selectionsMatch && model.mode == .browser && quietChat() && ChatRenderProbe.counts["BrowserStore.publish", default: 0] >= 20, "20 Browser switches do not rebuild ChatPage or composer")
        store.focusMode = true
        await rig.settle(10)
        ChatRenderProbe.reset()
        for i in 0..<20 {
            store.select(ids[i % ids.count])
            selectionsMatch = selectionsMatch && store.selectedTab.id == ids[i % ids.count]
            await rig.settle(2)
        }
        report("browser-focus-20-tab-switches")
        check(selectionsMatch && store.focusMode && quietChat() && ChatRenderProbe.counts["BrowserStore.publish", default: 0] >= 20, "20 fullscreen Browser switches do not rebuild ChatPage or composer")
        ChatRenderProbe.reset()
        for i in 0..<20 {
            model.prompt = "background fixture \(i)"
            await rig.settle(2)
        }
        report("browser-background-coder-20-updates")
        check(quietChat() && ChatRenderProbe.counts["ChatPageModel.publish", default: 0] >= 20,
              "Coder continues publishing while Browser presentation stays quiet")
        ChatRenderProbe.reset()
        for i in 0..<20 {
            ChatGPTSpaceModel.shared.draft = "hidden fixture \(i)"
            await rig.settle(2)
        }
        report("browser-background-chatgpt-20-updates")
        check(quietChat() && ChatRenderProbe.counts["ChatGPTSpaceMainPane.body", default: 0] == 0
              && ChatRenderProbe.counts["ChatGPTSpaceSidebarList.body", default: 0] == 0,
              "hidden ChatGPT Space stays out of Browser redraws")
        model.mode = .chat
        await rig.settle(10)
        check(model.selectedThreadID == thread && textViews(rig.host).contains { $0.string == model.prompt },
              "return to Coder displays the retained background draft")
        model.prompt = "visible fixture update"
        await rig.settle(10)
        check(textViews(rig.host).contains { $0.string == model.prompt }, "visible Coder still receives model updates")
        let counter = IslandExceptionsCount { 0 }
        var countPublications = 0
        counter.objectWillChange.sink { countPublications += 1 }.store(in: &watches)
        for tick in 0..<10 { await counter.refresh(now: Double(tick)) }
        print("W202PERF COUNT same-exception-count-10-ticks publications=\(countPublications)")
        check(countPublications == 0, "same exception count does not publish")
        let provider = IslandWorkProvider { IslandWorkSnapshot() }
        var workPublications = 0
        provider.objectWillChange.sink { workPublications += 1 }.store(in: &watches)
        provider.activate()
        try await Task.sleep(for: .milliseconds(50))
        provider.suspend(); provider.unload()
        check(workPublications == 0, "unchanged work snapshot and empty unload do not publish")
        let runtime = BrowserWorkSpaceRuntime.forChat("w202-navigation", registry: model.browserTabRegistry)
        let navigationID = UUID()
        runtime.updateNavigationPresentation(tabID: navigationID, state: .blank)
        var navigationPublications = 0
        runtime.objectWillChange.sink { navigationPublications += 1 }.store(in: &watches)
        for _ in 0..<20 { runtime.updateNavigationPresentation(tabID: navigationID, state: .blank) }
        check(navigationPublications == 0, "20 identical CEF navigation snapshots do not publish")
        let loading = EmbeddedBrowserNavigationState(urlString: "https://example.com", canGoBack: false,
            canGoForward: false, visibleError: nil, isLoading: true, phase: .loading)
        runtime.updateNavigationPresentation(tabID: navigationID, state: loading)
        check(navigationPublications == 1 && runtime.navigationState == loading, "changed CEF navigation state still publishes")
        dispose(rig)
        try await checkBrowserSettings(model: model, check: check)
        await checkFavoriteLeaves(check: check)
        await checkHiddenViews(model: model, store: store, check: check)
        checkPresentationLifecycle(model: model, check: check)
        checkCatalogs(check)
        checkMapping(model: model, engine: engine, thread: thread, check: check)
        print("W202PERF SUMMARY failures=\(failures)")
        return failures == 0
    }
    private static func report(_ scenario: String) {
        for key in ["ChatPage.body", "ChatPage.geometry", "ChatComposerToolbarRow.body", "ChatGPTSpaceMainPane.body", "ChatGPTSpaceSidebarList.body", "ChatGPTThinkingRow.tick", "ChatPageModel.publish", "BrowserStore.publish"] {
            print("W202PERF COUNT \(scenario) \(key)=\(ChatRenderProbe.counts[key, default: 0])")
        }
    }
    private static func quietChat() -> Bool {
        ["ChatPage.body", "ChatPage.geometry", "ChatComposerToolbarRow.body"].allSatisfy { ChatRenderProbe.counts[$0, default: 0] == 0 }
    }
    private static func checkBrowserSettings(model: ChatPageModel, check: (Bool, String) -> Void) async throws {
        let registry = model.browserTabRegistry
        let space = registry.addSpace(name: "W204 original space")
        let original = BrowserGeneralSettings.load()
        var settings = original
        settings.defaultSpaceID = space.id
        try settings.save()
        defer { try? original.save(); registry.removeSpace(space.id, closingTabs: true) }
        let rig = TatwoComposerModeAcceptance.ClickRig(
            TatwoSettingsPage(model: model, initialSection: .browserManagement, onClose: {}),
            size: CGSize(width: 780, height: 560))
        defer { dispose(rig) }
        await rig.settle(20)
        let before = snapshot(rig, "w204-settings-before")
        var modelPublications = 0
        let watch = model.objectWillChange.sink { modelPublications += 1 }
        defer { watch.cancel() }
        ChatRenderProbe.reset()
        registry.renameSpace(space.id, to: "W204 renamed space")
        await rig.settle(10)
        let after = snapshot(rig, "w204-settings-after")
        check(ChatRenderProbe.counts["BrowserSettingsRegistryContent.body", default: 0] > 0
              && before != nil && after != nil && before != after,
              "W204 settings redraw the renamed default space from their own registry subscription")
        ChatRenderProbe.reset()
        let tab = registry.openTab(owner: .chatSession(sessionID: "w204-settings"), url: URL(string: "https://example.org")!)
        await rig.settle(6)
        check(ChatRenderProbe.counts["BrowserSettingsRegistryContent.body", default: 0] > 0,
              "W204 settings refresh tab and open-session counts after an external open")
        ChatRenderProbe.reset()
        registry.close(tab.id)
        await rig.settle(6)
        check(ChatRenderProbe.counts["BrowserSettingsRegistryContent.body", default: 0] > 0,
              "W204 settings refresh counts after an external close")
        check(modelPublications == 0 && quietChat(), "W204 registry updates do not broadcast through Coder")
    }
    private static func checkFavoriteLeaves(check: (Bool, String) -> Void) async {
        let registry = BrowserTabRegistry(storageURL: nil)
        registry.openTab(owner: .workSpace(spaceID: registry.spaces.first { !$0.isSessionSpace }!.id),
                         url: URL(string: "https://example.org/unrelated")!)
        let store = BrowserWorkSpaceStore(registry: registry)
        let dmStore = BrowserWorkSpaceStore(registry: registry)
        let stableTabs = store.tabs
        let main = TatwoComposerModeAcceptance.ClickRig(BrowserFavoritesStrip(store: store), size: CGSize(width: 246, height: 42))
        let dm = TatwoComposerModeAcceptance.ClickRig(
            BrowserFavoritesStrip(store: dmStore, external: .init(open: { _ in }, state: { _ in (false, false) })),
            size: CGSize(width: 246, height: 42))
        defer { dispose(main); dispose(dm) }
        await main.settle(10); await dm.settle(10)
        let mainBefore = snapshot(main, "w204-main-favorites-before")
        let dmBefore = snapshot(dm, "w204-dm-favorites-before")
        let favorite = registry.addFavorite(url: URL(string: "https://example.org/favorite-only")!, title: "W204 unopened favorite")
        await main.settle(10); await dm.settle(10)
        let mainAfter = snapshot(main, "w204-main-favorites-after")
        let dmAfter = snapshot(dm, "w204-dm-favorites-after")
        check(mainBefore != nil && mainAfter != nil && mainBefore != mainAfter && store.tabs == stableTabs,
              "W204 main favorites redraw without any open-tab change")
        check(dmBefore != nil && dmAfter != nil && dmBefore != dmAfter && dmStore.tabs == stableTabs,
              "W204 DM favorites redraw through their own store")
        registry.removeFavorite(favorite.id)
        await main.settle(10); await dm.settle(10)
        check(snapshot(main, "w204-main-favorites-removed") == mainBefore
              && snapshot(dm, "w204-dm-favorites-removed") == dmBefore,
              "W204 removing an unopened favorite restores both empty strips")
    }
    private static func snapshot(_ rig: TatwoComposerModeAcceptance.ClickRig, _ name: String) -> Data? {
        guard let bitmap = rig.host.bitmapImageRepForCachingDisplay(in: rig.host.bounds) else { return nil }
        rig.host.cacheDisplay(in: rig.host.bounds, to: bitmap)
        if let folder = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        guard !bitmap.isPlanar, bitmap.bitsPerSample == 8, let bytes = bitmap.bitmapData else { return nil }
        var pixels = Data()
        for row in 0..<bitmap.pixelsHigh {
            pixels.append(bytes.advanced(by: row * bitmap.bytesPerRow), count: bitmap.pixelsWide * bitmap.samplesPerPixel)
        }
        return pixels
    }
    private static func checkHiddenViews(model: ChatPageModel, store: BrowserWorkSpaceStore, check: (Bool, String) -> Void) async {
        let visibility = Visibility()
        let coder = TatwoComposerModeAcceptance.ClickRig(CoderVisibilityHost(visibility: visibility, model: model),
            size: CGSize(width: 1100, height: 760))
        await coder.settle(20)
        visibility.visible = false
        await coder.settle(10)
        ChatRenderProbe.reset()
        for i in 0..<20 {
            model.prompt = "retained Coder fixture \(i)"
            await coder.settle(2)
        }
        report("hidden-retained-coder-20-updates")
        check(quietChat() && ChatRenderProbe.counts["visibility.parent.body", default: 0] == 0,
              "retained hidden ChatPage and shell stay quiet during draft updates")
        visibility.visible = true
        await coder.settle(10)
        check(textViews(coder.host).contains { $0.string == model.prompt }, "retained Coder shows current draft when made visible")
        dispose(coder)
        let pod = QuietPod(); pod.isRunning = true
        let space = ChatGPTSpaceModel(testTap: ChatGPTTap(transport: pod, connection: .off))
        let spaceVisibility = Visibility()
        let chatGPT = TatwoComposerModeAcceptance.ClickRig(SpaceVisibilityHost(visibility: spaceVisibility, model: space),
            size: CGSize(width: 1100, height: 760))
        defer { dispose(chatGPT) }
        await chatGPT.settle(20)
        spaceVisibility.visible = false
        await chatGPT.settle(10)
        ChatRenderProbe.reset()
        for i in 0..<20 {
            space.draft = "retained Space fixture \(i)"
            await chatGPT.settle(2)
        }
        try? await Task.sleep(for: .seconds(2.2))
        report("hidden-retained-chatgpt-20-updates")
        check(ChatRenderProbe.counts["ChatGPTSpaceMainPane.body", default: 0] == 0
              && ChatRenderProbe.counts["ChatGPTSpaceSidebarList.body", default: 0] == 0
              && ChatRenderProbe.counts["ChatGPTThinkingRow.tick", default: 0] == 0,
              "retained hidden ChatGPT models and thinking timeline stay quiet")
        spaceVisibility.visible = true
        await chatGPT.settle(10)
        check(ChatRenderProbe.counts["ChatGPTSpaceMainPane.body", default: 0] > 0
              && textViews(chatGPT.host).contains { $0.string == space.draft }, "retained Space shows current draft when made visible")
        let base = PeriodicTimelineSchedule(from: Date(), by: 1)
        check(Array(VisibleTimelineSchedule(base: base, isVisible: false).entries(from: Date(), mode: .normal)).isEmpty
              && Array(VisibleTimelineSchedule(base: base, isVisible: true).entries(from: Date(), mode: .normal).prefix(2)).count == 2,
              "hidden timeline has no entries and visible timeline retains its schedule")
    }
    private static func textViews(_ view: NSView) -> [NSTextView] {
        (view as? ChatComposerTextView.ComposerNSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
    private static func checkPresentationLifecycle(model: ChatPageModel, check: (Bool, String) -> Void) {
        let presentation = WorkspaceObservation(object: model, forwardWhenHidden: ChatPageModel.presentationChanges, shouldForward: { $0.mode != .browser })
        var publications = 0
        let watch = presentation.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        presentation.isVisible = false
        model.prompt = "hidden lifecycle fixture"
        check(publications == 0, "hidden presentation ignores ordinary draft publications")
        model.requestOpenBrowserPanel = true
        model.requestOpenBrowserPanel = false
        model.isRunning = true
        model.isRunning = false
        check(publications == 4, "hidden presentation preserves panel requests and work completion handlers")
        presentation.isVisible = true
        model.mode = .browser
        publications = 0
        presentation.forwardOverride = true
        model.prompt = "overlay fixture"
        check(publications == 1, "visible Browser overlays can opt into current Coder model updates")
        model.mode = .chat
    }
    private static func dispose(_ rig: TatwoComposerModeAcceptance.ClickRig) {
        (rig.host as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
        rig.window.contentView = nil
        rig.window.close()
    }
    private static func checkCatalogs(_ check: (Bool, String) -> Void) {
        let aliases = [(" GPT_6.1-Sol ", "gpt-6.1-sol"), ("Claude Sonnet 4.6", "sonnet5"),
                       ("Fable", "fable5.1"), ("GPT-5.5", "gpt-5.6-sol"), ("Opus", "opus5.5")]
        check(aliases.allSatisfy { TatwoChatRouteProfile.resolve($0.0).id == $0.1 }
              && TatwoChatRouteProfile.resolve("Codex/GPT").id == TatwoChatRouteProfile.defaults.first?.id
              && TatwoChatRouteProfile.resolve("unknown-fixture").runtimeAdapter == .unavailable,
              "O1 aliases preserve retired replacements, first-match priority and unknown-route refusal")
        func catalog(_ title: String, effort: String) -> EngineModelCatalog.Catalog {
            .init(engine: "codex", identity: "fixture", source: "fixture", models: [
                .init(model: "fixture-model", displayName: title, efforts: [effort], defaultEffort: effort,
                      speeds: ["standard"], defaultSpeed: "standard", images: true)])
        }
        let deviceA = "w202-device-a", deviceB = "w202-device-b"
        EngineModelCatalog.replace([catalog("Fixture A", effort: "low")], deviceID: deviceA)
        EngineModelCatalog.replace([catalog("Fixture B", effort: "high")], deviceID: deviceB)
        check(ChatRouteChoice.resolveOrNil("fixture-model", deviceID: deviceA)?.title == "Fixture A"
              && ChatRouteChoice.resolveOrNil("fixture-model", deviceID: deviceB)?.title == "Fixture B", "route cache separates devices")
        let revision = EngineModelCatalog.revision(deviceID: deviceA)
        EngineModelCatalog.replace([catalog("Fixture A", effort: "low")], deviceID: deviceA)
        check(EngineModelCatalog.revision(deviceID: deviceA) == revision, "unchanged engine catalog keeps generation")
        EngineModelCatalog.replace([catalog("Fixture A2", effort: "max")], deviceID: deviceA)
        let changed = ChatRouteChoice.resolveOrNil("fixture-model", deviceID: deviceA)
        check(changed?.title == "Fixture A2" && changed?.allowedEfforts == [.max], "catalog changes invalidate cached route capabilities and title")
        check(ChatRouteChoice.resolveOrNil(" \n", deviceID: deviceA) == nil, "empty normalized routes stay unresolved")
        let original = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(original) }
        ChatGPTTapModelCatalog.replace([TapModel(id: "w202-model", title: "Fixture TAP", detail: "")])
        let id = ChatGPTTapModelCatalog.routeID("w202-model")
        check(ChatRouteChoice.resolveOrNil(id)?.title == "Fixture TAP", "TAP route enters the lookup cache")
        ChatGPTTapModelCatalog.replace([])
        ChatGPTTapModelCatalog.rememberDisplayName("Remembered A", routeID: id)
        let remembered = ChatRouteChoice.resolveOrNil(id)
        ChatGPTTapModelCatalog.rememberDisplayName("Remembered B", routeID: id)
        check(remembered?.title == "Remembered A" && ChatRouteChoice.resolveOrNil(id)?.title == "Remembered B"
              && ChatRouteChoice.resolveOrNil(id)?.isAvailable == false, "remembered TAP titles invalidate cache without enabling unavailable routes")
    }
    private static func checkMapping(model: ChatPageModel, engine: ChatLiveEngine, thread: UUID,
                                     check: (Bool, String) -> Void) {
        let space = ChatGPTSpaceModel(testTap: ChatGPTTap(transport: QuietPod(), connection: .off))
        ChatRenderProbe.reset()
        var selectedOnly = true
        for _ in 0..<20 {
            let request = ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .coder, revision: 0)
            selectedOnly = selectedOnly && request.candidates.map(\.threadID) == [thread]
        }
        check(selectedOnly, "Coder mapping lookup contains only selected thread")
        engine.rename(thread, "Renamed fixture")
        let updated = ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .coder, revision: 0)
        check(updated.candidates.first?.thread == "Renamed fixture", "document change invalidates mapping candidates")

    }
}
#endif
