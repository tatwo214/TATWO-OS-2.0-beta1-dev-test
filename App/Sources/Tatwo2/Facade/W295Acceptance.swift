#if DEBUG
import AppKit
import SwiftUI
import Combine

@MainActor enum W295Acceptance {
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var mainLoads = 0, loads = 0, mainJSON = 0, json = 0
        func load() { lock.withLock { loads += 1; if Thread.isMainThread { mainLoads += 1 } } }
        func encode() { lock.withLock { json += 1; if Thread.isMainThread { mainJSON += 1 } } }
    }
    static func run() async throws -> Bool {
        setenv("TATWO_BROWSER_WORKSPACE_PREVIEW", "1", 1)
        var env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let livePath = env["TATWO2_LIVE_ROOT"] else { throw TapError.remote("W295 requires isolated staging") }
        let root = URL(fileURLWithPath: livePath).appendingPathComponent("w295")
        env["TATWO2_LIVE_ROOT"] = root.path
        env["TATWO_BROWSER_WORKSPACE_PREVIEW"] = "1"
        let store = ChatLiveStore(root: root)
        let engine = ChatLiveEngine(store: store, environment: env, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let thread = engine.newThread(in: nil, title: "W295 fixture")
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("bots"))))
        model.selectedThreadID = thread
        model.mode = .browser
        // Register after model construction: satisfy the real bridge gate without starting a remote session.
        try DeviceRegistry(environment: env).add(id: "fixture-peer", name: "fixture", host: "fixture.invalid",
            user: "fixture", publicKeyFingerprint: "SHA256:fixture")
        let paths = EnginePaths(environment: env)
        paths.createPrivateDirectories()
        try Data("{\"auth_mode\":\"apikey\"}".utf8).write(to: paths.codexAuth)
        let policy = EngineAPIKeyPolicy.shared
        policy.useForTesting(paths: paths, environment: env)
        let oldDisabled = UserDefaults.standard.stringArray(forKey: "tatwo2.disabledEngines")
        UserDefaults.standard.set(["codex"], forKey: "tatwo2.disabledEngines")
        model.disabledEngines = ["codex"]
        defer {
            UserDefaults.standard.set(oldDisabled, forKey: "tatwo2.disabledEngines")
            policy.useForTesting(paths: nil, environment: nil)
            ChatLiveStore.fixtureLoad = nil; OSAgentBridge.fixtureJSON = nil
            DeviceFleetStore.fixtureStateRead = nil; ChatRenderProbe.enabled = false
        }
        let fleet = DeviceFleetStore(registry: DeviceRegistry(environment: env), environment: env)
        var trust = DeviceFleetTrust(localID: "fixture-local", primaryID: "fixture-primary", epoch: 1,
                                    pinnedPrimaryKey: "fixture-pin", kind: .owner)
        try fleet.save(.init(trust: trust))
        let bridge = OSAgentBridge.fleetFixtureBridge()
        bridge.fixtureModel(model)
        ChatRenderProbe.enabled = true
        let cache = RemoteOfflineCache(root: RemoteOfflineCache.defaultRoot(environment: env))
        let peer = DeviceRecord(id: "fixture-peer", name: "fixture", host: "fixture.invalid", user: "fixture", sshPort: 22,
            publicKeyFingerprint: "SHA256:fixture", addedAt: Date(), lastSeenAt: Date(), workdirMap: [:])
        let session = RemoteDeviceSession(device: peer, link: RemoteHostLink(environment: env), environment: env)
        var offlineDoc = engine.doc
        for index in offlineDoc.threads.indices { offlineDoc.threads[index].updatedAt = Date().addingTimeInterval(-86_500) }
        try await Task.detached { try cache.writeSnapshot(.init(deviceID: peer.id, deviceName: peer.name,
            syncedAt: Date(), revision: 1, document: offlineDoc)) }.value
        session.offlineMirror.loadFromDisk()
        model.remoteSessions = [session]
        let snapshot = TatwoAppSnapshotFactory.makeCurrent(environment: env)
        let rig = TatwoComposerModeAcceptance.ClickRig(
            TatwoHydratedPanelView(chatModel: model, surface: .window, initialSelection: .chat,
                initialSnapshot: snapshot, initialModesAuthority: .init(contract: nil, integrityState: .noCurrentSession))
                .environment(\.tatwoSurfaceKind, .window), size: CGSize(width: 1100, height: 760))
        defer { rig.window.close() }
        let tab = model.browserTabRegistry.openTab(owner: .workSpace(spaceID: model.browserTabRegistry.spaces.first!.id))
        await rig.settle(10)
        model.mode = .browser
        await rig.settle(2)
        for _ in 0..<500 where !session.offlineMirror.diskLoaded { await rig.settle(1) }
        guard session.offlineMirror.snapshot != nil else { throw TapError.remote("W300 missing offline snapshot") }
        // Publish real background work state as well as the ordinary heartbeat.
        model.primaryLocalCache = nil
        policy.useForTesting(paths: paths, environment: env)
        _ = policy.method(.codex) // cold start reads auth and optional config once each
        let coldPolicyReads = policy.fixtureFileReads
        policy.resetFixtureFileReads()
        let authorityDirectory = TatwoGoalRunStore.default().directoryURL
        let authorityBefore = await Task.detached {
            TatwoModesIssuedAuthorityResolver.resolve(stateDirectoryURL: authorityDirectory)
        }.value
        ChatRenderProbe.reset()
        let counters = Counts()
        var trustReads = 0, updates = 0, workChanges = 0
        DeviceFleetStore.fixtureStateRead = { trustReads += 1 }
        ChatLiveStore.fixtureLoad = { counters.load() }
        OSAgentBridge.fixtureJSON = { counters.encode() }
        var watches = Set<AnyCancellable>()
        model.browserTabRegistry.changes.sink { updates += 1 }.store(in: &watches)
        model.$isRunning.removeDuplicates().dropFirst().sink { _ in workChanges += 1 }.store(in: &watches)
        for (index, publisher) in ChatPageModel.presentationChanges(model).enumerated() {
            publisher.sink { ChatRenderProbe.record("presentation.\(index)") }.store(in: &watches)
        }
        model.authorityBootstrapModel.objectWillChange.sink { ChatRenderProbe.record("authorityBootstrap.objectWillChange") }.store(in: &watches)
        var revision: Int64?
        var wireUnchanged = true, browserWasVisible = true
        for index in 0..<200 {
            browserWasVisible = browserWasVisible && model.mode == .browser && ChatRunMode.browserPreviewEnabled
            model.browserTabRegistry.update(tab.id, url: URL(string: "about:blank"), title: "fixture \(index)", favicon: nil)
            model.browserTabRegistry.setLoading(tab.id, index % 2 == 0)
            model.isRunning = index % 2 == 0
            model.rebuildRemoteSidebarSections()
            model.objectWillChange.send() // same invalidation as a remote session heartbeat
            _ = model.managedAssistantIsLocal
            let result = try await Task.detached { try bridge.callForSelfTest(method: "get_document", params: [:]) }.value
            let next = (result["revision"] as? NSNumber)?.int64Value ?? -1
            wireUnchanged = wireUnchanged && (revision == nil || revision == next)
                && result["document"] is [String: Any] && result["blockedEngines"] as? [String] == ["codex"]
                && Set(result.keys) == ["document", "revision", "runningThreadIDs", "blockedEngines", "engineModelCatalogs"]
            revision = next
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 8, wheel2: 0, wheel3: 0),
               let event = NSEvent(cgEvent: cg) { rig.window.sendEvent(event) }
            await rig.settle(1)
        }
        let authorityAfter = await Task.detached {
            TatwoModesIssuedAuthorityResolver.resolve(stateDirectoryURL: authorityDirectory)
        }.value
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("W295 \(value ? "PASS" : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        let activity = ChatRenderProbe.counts["RemoteOfflineMirror.activityLines", default: 0]
        let hydrated = ChatRenderProbe.counts["TatwoHydratedPanelView.body", default: 0]
        let coder = ChatRenderProbe.counts["ultraworkCollaborationPanel", default: 0]
        print("W295 COUNTS updates=\(updates) trustReads=\(trustReads) policyReads=\(policy.fixtureFileReads) mainLoads=\(counters.mainLoads) loads=\(counters.loads) mainJSON=\(counters.mainJSON) JSON=\(counters.json) coder=\(coder) chatBodies=\(ChatRenderProbe.counts["ChatPage.body", default: 0]) activityLines=\(activity) hydratedBodies=\(hydrated) workChanges=\(workChanges) authorityUpdates=\(ChatRenderProbe.counts["TatwoModesIssuedAuthorityMonitor.revision", default: 0]) mode=\(model.mode) preview=\(ChatRunMode.browserPreviewEnabled)")
        check(browserWasVisible && model.mode == .browser && ChatRunMode.browserPreviewEnabled, "Browser is visible throughout the measurement")
        check(coldPolicyReads == 2 && policy.fixtureFileReads == 0, "cold policy reads each input once; 200 updates reuse it")
        check(updates >= 200 && trustReads <= 1 && policy.fixtureFileReads <= 1 && counters.mainLoads == 0 && coder == 0,
              "200 Browser updates and scroll events meet hot-path budgets")
        check(activity <= 1 && workChanges >= 200, "200 updates: activityLines <= 1; background work changes >= 200")
        print("W295 OBSERVED hydratedBodies=\(hydrated) authorityUnchanged=\(authorityBefore == authorityAfter) probes=\(ChatRenderProbe.counts.sorted { $0.key < $1.key })")
        check(session.offlineMirror.activityLines()[thread] != nil && model.remoteSidebarSections.first?.projects.flatMap(\.threads).first { $0.id == thread }?.statusLine
              == session.offlineMirror.activityLines()[thread], "offline sidebar keeps activity text")
        check(wireUnchanged && counters.mainJSON == 0 && counters.json == 200, "wire fields and unchanged revision; JSON off main")
        _ = try bridge.callForSelfTest(method: "get_document", params: [:])
        check(counters.mainJSON == 0 && counters.mainLoads == 0, "direct main caller still converts JSON and compares off main")
        var deviceRows = model.deviceRecordsForBridge() // hydrate before measuring unchanged reads
        var deviceNotifications = 0
        let deviceWatch = model.objectWillChange.sink { deviceNotifications += 1 }
        var stableDeviceRows = true
        for _ in 0..<200 {
            let rows = model.deviceRecordsForBridge()
            stableDeviceRows = stableDeviceRows && rows == deviceRows
        }
        let unchangedDeviceNotifications = deviceNotifications
        deviceRows[0].name = "changed fixture"
        try DeviceRegistry(environment: env).add(deviceRows[0])
        let changedDeviceRows = model.deviceRecordsForBridge()
        deviceWatch.cancel()
        print("W295 DEVICE COUNTS reads=200 unchanged=\(unchangedDeviceNotifications) changed=\(deviceNotifications - unchangedDeviceNotifications)")
        check(stableDeviceRows && unchangedDeviceNotifications == 0 && deviceNotifications == 1 && changedDeviceRows == deviceRows,
              "200 unchanged device reads publish zero changes; one edited list publishes once")
        let trustDate = try FileManager.default.attributesOfItem(atPath: fleet.url.path)[.modificationDate] as! Date
        trust.kind = .managed
        try fleet.save(.init(trust: trust))
        try FileManager.default.setAttributes([.modificationDate: trustDate], ofItemAtPath: fleet.url.path)
        check(model.managedAssistantIsLocal, "trust size edit invalidates even with unchanged mtime")
        try Data("not-json".utf8).write(to: fleet.url)
        check(model.managedAssistantIsLocal, "malformed trust retains fail-closed behavior")
        try FileManager.default.removeItem(at: fleet.url)
        check(!model.managedAssistantIsLocal, "missing trust retains standalone behavior")
        try Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"refresh_token\":\"fixture\"}}".utf8).write(to: paths.codexAuth)
        check(policy.method(.codex) == .subscription, "external auth edit invalidates on next read")
        let config = paths.codexHome.appendingPathComponent("config.toml")
        try "forced_login_method = \"api\"".write(to: config, atomically: true, encoding: .utf8)
        check(policy.method(.codex) == .apiKey, "external config creation invalidates on next read")
        try "# subscription again".write(to: config, atomically: true, encoding: .utf8)
        EngineDisableStore.set(.codex, disabled: true)
        check(!EngineDisableStore.blocksSend(.codex), "subscription remains usable with opt-out")
        try "forced_login_method = \"api\"".write(to: config, atomically: true, encoding: .utf8)
        check(EngineDisableStore.blocksSend(.codex), "config edit immediately blocks API login")
        EngineDisableStore.set(.codex, disabled: false)
        check(!EngineDisableStore.blocksSend(.codex), "settings toggle immediately permits engine")
        var changed = engine.doc
        changed.threads[0].title = "changed fixture"
        let document = changed
        try await Task.detached {
            store.saveIfChanged(document)
            guard store.load().threads[0].title == "changed fixture" else { throw TapError.remote("W295 background save failed") }
        }.value
        let staleStamp = PolicyFileStamp(store.url)
        let current = changed
        try await Task.detached {
            let external = ChatLiveStore(root: root)
            var edited = document
            edited.threads[0].title = "newer write"
            edited.threads[0].cliTabsUpdatedAt = Date().addingTimeInterval(30)
            edited.threads[0].cliTabs = [.init(id: UUID(), engine: "codex", cwd: root.path, title: "external CLI")]
            try external.saveChecked(edited)
            store.saveIfChanged(current, expectedStamp: staleStamp)
            guard store.load().threads[0].title == "newer write" else { throw TapError.remote("stale snapshot overwrote newer write") }
            store.saveIfChanged(document)
            guard store.load().threads[0].cliTabs.first?.title == "external CLI" else { throw TapError.remote("CLI tabs lost") }
        }.value
        check(true, "stale snapshot does not overwrite; external CLI tabs preserved")
        let later = try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as! Date
        check(Int64(later.timeIntervalSince1970 * 1000) > revision!, "changed document persists and advances disk revision")
        let activityURL = cache.documentURL(peer.id)
        let oldStamp = PolicyFileStamp(activityURL)
        let beforeEdits = ChatRenderProbe.counts["RemoteOfflineMirror.activityLines", default: 0]
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: activityURL.path)
        _ = session.offlineMirror.activityLines()
        let changedMtime = PolicyFileStamp(activityURL).modified!
        var paddedActivity = try Data(contentsOf: activityURL)
        paddedActivity.append(Data(" ".utf8))
        try paddedActivity.write(to: activityURL)
        try FileManager.default.setAttributes([.modificationDate: changedMtime], ofItemAtPath: activityURL.path)
        _ = session.offlineMirror.activityLines()
        check(ChatRenderProbe.counts["RemoteOfflineMirror.activityLines", default: 0] == beforeEdits + 2
              && PolicyFileStamp(activityURL).size != oldStamp.size, "activity cache invalidates on mtime and size edits")
        var freshDoc = offlineDoc
        for index in freshDoc.threads.indices { freshDoc.threads[index].updatedAt = Date().addingTimeInterval(-3_599.5) }
        session.offlineMirror.record(document: freshDoc, revision: 2, force: true)
        for _ in 0..<500 where session.offlineMirror.snapshot?.revision != 2 { await rig.settle(1) }
        let minuteLines = session.offlineMirror.activityLines()
        try? await Task.sleep(for: .seconds(1))
        let hourLines = session.offlineMirror.activityLines()
        check(minuteLines[thread] == "最後活動 59 分鐘前" && hourLines[thread] == "最後活動 1 小時前",
              "snapshot replacement and relative-time boundary refresh activity text")
        rig.window.close()
        // Use a dedicated authority directory: the facade default is a tmp-directory stub.
        let testAuthorityDirectory = root.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: testAuthorityDirectory, withIntermediateDirectories: true)
        let authorityMonitor = TatwoModesIssuedAuthorityMonitor(stateDirectoryURL: testAuthorityDirectory)
        let authorityRig = TatwoComposerModeAcceptance.ClickRig(
            TatwoHydratedPanelView(chatModel: model, surface: .window, initialSelection: .chat,
                initialSnapshot: snapshot, initialModesAuthority: .init(contract: nil, integrityState: .noPointer),
                authorityMonitor: authorityMonitor)
                .environment(\.tatwoSurfaceKind, .window), size: CGSize(width: 1100, height: 760))
        defer { authorityRig.window.close() }
        await authorityRig.settle(20)
        let bodiesBeforeAuthority = ChatRenderProbe.counts["TatwoHydratedPanelView.body", default: 0]
        let revisionsBeforeAuthority = authorityMonitor.revision
        let pointer = testAuthorityDirectory.appendingPathComponent("current-session.json")
        try Data("changed-authority-fixture".utf8).write(to: pointer, options: .atomic)
        await authorityRig.settle(20)
        let authorityBodies = ChatRenderProbe.counts["TatwoHydratedPanelView.body", default: 0] - bodiesBeforeAuthority
        let authorityRevisions = authorityMonitor.revision - revisionsBeforeAuthority
        print("W295 AUTHORITY revisions=\(authorityRevisions) hydratedBodies=\(authorityBodies)")
        check(authorityRevisions == 1 && authorityBodies == 1,
              "authorization file change recomputes mounted panel body once")
        print("W295 SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
