#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W298aAcceptance {
    private final class NarrowPod: FakeTapPod {
        var width = 225, users = 0
        override func beginConnectorViewport() { users += 1; width = 1100 }
        override func endConnectorViewport() { users -= 1; if users == 0 { width = 225 } }
        override func respond(_ command: [String: Any], id: String, cmd: String) {
            guard cmd == "models" else { super.respond(command, id: id, cmd: cmd); return }
            emit(["type": "result", "id": id, "ok": width >= 1000,
                  "data": ["models": [["slug": "desktop-fixture", "title": "Desktop fixture model"]]]])
        }
    }
    private final class HomePod: FakeTapPod {
        var path = "/settings/plugins-settings", shared = false, homeOK = true
        override var isSpacePageShared: Bool { shared }
        override func respond(_ command: [String: Any], id: String, cmd: String) {
            if cmd == "connectorHome", homeOK { path = "/" }
            emit(["type": "result", "id": id, "ok": true, "data": ["ok": cmd != "connectorHome" || homeOK]])
        }
    }
    private final class HomeSurface: ChatGPTPodSurface {
        var onMainFrame: ((String?, UInt64, Bool, Int) -> Void)?
        var onPopup: ((TatwoCEFBrowserView) -> Void)?
        let pod: HomePod
        private var generation: UInt64 = 1
        private(set) var loads: [URL] = []
        init(_ pod: HomePod) { self.pod = pod }
        func commit() { onMainFrame?("https://chatgpt.com" + pod.path, generation, false, 200) }
        func loadMain(_ url: URL) {
            loads.append(url)
            generation += 1
            onMainFrame?("https://chatgpt.com" + pod.path, generation, true, 0)
            onMainFrame?(url.absoluteString, generation, true, 0)
            pod.path = url.path; commit(); pod.emit(["type": "hello", "loggedIn": true])
        }
    }
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let artifactPath = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        var passed = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failed += 1 }
            print("W298A \(value ? "PASS" : "FAIL") \(name)")
        }
        defer { print("W298A SUMMARY failures=\(failed) passed=\(passed)") }
        let artifacts = URL(fileURLWithPath: artifactPath)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let suite = "w298a." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await W315Acceptance.run(check: check)
        try await W351Acceptance.models(check: check)
        func model(_ id: String) -> EngineModelCatalog.Model {
            .init(model: id, displayName: id, efforts: ["low", "high"], defaultEffort: "low", speeds: [], defaultSpeed: "", images: false)
        }
        func catalog(_ ids: [String], preferred: String? = nil, engine: String = "codex") -> EngineModelCatalog.Catalog {
            .init(engine: engine, identity: "fixture|1.0.0", source: "synthetic native models", models: ids.map(model), defaultModel: preferred)
        }
        let previous = EngineModelCatalog.catalogs(), previousTap = ChatGPTTapModelCatalog.snapshot
        defer { EngineModelCatalog.replace(previous); ChatGPTTapModelCatalog.replace(previousTap) }
        EngineModelCatalog.replace([catalog(["claude-opus-5-5[1m]"], engine: "claude")])
        check(EngineAIUpdate.retired("opus5.5") == nil, "W350 extended-context Claude alias is not retired")
        EngineModelCatalog.replace([catalog(["claude-opus-5-5-20261010"], engine: "claude")])
        check(EngineAIUpdate.retired("opus5.5") == nil, "W350 dated Claude alias is not retired")
        EngineModelCatalog.replace(previous)
        let old = "gpt-5.6-sol", new = "gpt-6.1-sol"
        let before = catalog([old, "gpt-5.6-luna", "gpt-6-luna"], preferred: old)
        let after = catalog(["gpt-6-luna", new, new], preferred: new)
        EngineModelCatalog.replace([catalog(["grok-build", "grok-4.7", "GROK_4.7"], engine: "grok")])
        let grok = TatwoComposerMode.routeOptions(selectedID: nil).filter { $0.brand == .xAI }
        check(grok.count == 1 && grok.first?.id == "grok-build", "W309 Grok provider and route aliases occur once")
        EngineModelCatalog.replace([catalog(["grok-build"], engine: "claude")])
        check(TatwoComposerMode.routeOptions(selectedID: nil).filter { $0.brand == .xAI }.count == 1,
              "W309 Grok duplicate route from another catalog occurs once")
        EngineModelCatalog.replace([catalog(["claude-opus-4-7", "claude-opus-4-8", "claude-opus-5"], engine: "claude")])
        var claude = catalog(["claude-fable-5-1", "fable-5-1", "claude-sonnet-5", "sonnet-5", "claude-opus-5-5", "opus-5-5", "claude-haiku-4-5-20251001", "haiku-4-5"], preferred: "claude-opus-5-5", engine: "claude")
        claude.models[0].displayName = "Fable"; claude.models[2].displayName = "Sonnet"
        claude.models[4].displayName = "Default (recommended)"; claude.models[6].displayName = "Haiku"
        EngineModelCatalog.replace([claude])
        let claudeRows = TatwoComposerMode.routeOptions(selectedID: nil).filter { $0.brand == .anthropic }
        check(claudeRows.map(\.title) == ["Fable 5.1", "Sonnet 5", "Opus 5.5", "Haiku 4.5"] &&
              EngineModelCatalog.profiles().filter { $0.engine == .claude }.map(\.modelArgument) == ["claude-fable-5-1", "claude-sonnet-5", "claude-opus-5-5", "claude-haiku-4-5-20251001"],
              "W309 Claude aliases merge with readable names and retain reported arguments")
        check(!claudeRows.contains { $0.title.contains("4.7") || $0.title.contains("4.8") || $0.title == "Opus 5" }, "W309 Claude retired models and remembered names stay out of menu")
        EngineModelCatalog.replace([catalog(["sonnet"], engine: "claude")])
        check(TatwoComposerMode.routeOptions(selectedID: nil).filter { $0.brand == .anthropic }.map(\.title) == ["Sonnet 5"], "W309 Claude reported aliases exclude unreported builtins")
        EngineModelCatalog.replace([])
        check(EngineModelCatalog.profiles().filter { $0.engine == .claude }.map(\.id) == TatwoChatRouteProfile.defaults.filter { $0.engine == .claude }.map(\.id), "W309 Claude absent report uses builtin fallback")
        let secondIDs = ["fable-5", "haiku-4-5", "sonnet-5", "opus-4-8", "opus-4-7", "opus-5"]
        EngineModelCatalog.replace([catalog(secondIDs, engine: "codex")])
        let originTap = ChatGPTTap(transport: FakeTapPod(running: true) { _, _ in [:] })
        let originSources = await originTap.diagnostics().first { $0.0 == "選單項目 id → 來源" }?.1 ?? ""
        check(secondIDs.allSatisfy { originSources.contains($0 + " → engine:codex") }, "W310 second IDs diagnose app-server catalog origin")
        print("W310 fixture sources: " + originSources)
        originTap.sleep()
        EngineModelCatalog.replace([claude, catalog(secondIDs, engine: "codex")])
        let mixedRows = TatwoComposerMode.routeOptions(selectedID: nil).filter { $0.brand == .anthropic }
        check(mixedRows.count == 4 && mixedRows.map(\.id) == claudeRows.map(\.id), "W310 Claude second catalog excludes six old IDs")
        let mixedTap = ChatGPTTap(transport: FakeTapPod(running: true) { _, _ in [:] })
        let mixedSources = await mixedTap.diagnostics().first { $0.0 == "選單項目 id → 來源" }?.1 ?? ""
        check(!mixedSources.contains("engine:codex") && mixedSources.contains("engine:claude"), "W310 menu sources retain Claude engine only")
        mixedTap.sleep(); EngineModelCatalog.replace([])
        for outcome in ["success", "failure", "cancel"] {
            let homePod = HomePod(running: true), homeTap = ChatGPTTap(transport: homePod, connection: .ready)
            let surface = HomeSurface(homePod), driver = ChatGPTConnectorPod(tap: homeTap, surface: { surface })
            driver.restoreTimeout = 0.3; driver.connectLog = nil
            driver.attach(); surface.commit()
            let acquired = await driver.acquireExclusive(timeout: 1)
            let prepared = acquired && surface.loads.map(\.path) == ["/plugins"] && driver.mainURL?.path == "/plugins" && homeTap.helloCount == 1
            let work = Task { @MainActor in
                defer { driver.releaseExclusive() }
                if outcome == "failure" { throw TapError.remote("synthetic failure") }
                if outcome == "cancel" { try await Task.sleep(for: .seconds(30)) }
            }
            if outcome == "cancel" { work.cancel() }
            _ = await work.result
            for _ in 0..<100 { if homeTap.connectorHold == nil { break }; try? await Task.sleep(for: .milliseconds(10)) }
            check(prepared && homePod.path == "/" && homeTap.connectorHold == nil, "W310 connector " + outcome + " returns home before release")
            homePod.path = "/settings/plugins-settings"; homePod.homeOK = false; surface.commit()
            let fallbackAcquired = await driver.acquireExclusive(timeout: 1); driver.releaseExclusive()
            for _ in 0..<100 { if homeTap.connectorHold == nil { break }; try? await Task.sleep(for: .milliseconds(10)) }
            check(fallbackAcquired && homePod.path == "/" && homeTap.connectorHold == nil && surface.loads.map(\.path) == ["/plugins", "/plugins", "/"], "W310 failed script home uses native restore " + outcome)
            homePod.shared = true; homePod.path = "/settings/plugins-settings"; surface.commit()
            let sharedAcquired = await driver.acquireExclusive(timeout: 1); driver.releaseExclusive()
            for _ in 0..<100 { if homeTap.connectorHold == nil { break }; try? await Task.sleep(for: .milliseconds(10)) }
            check(!sharedAcquired && homePod.path == "/settings/plugins-settings" && homeTap.connectorHold == nil && surface.loads.count == 3, "W310 shared Space URL stays unchanged " + outcome)
            homeTap.sleep()
        }
        var nodeSnapshot = HandsBuildSnapshot()
        nodeSnapshot.devices = [.init(id: "mini", name: "Mac mini", isPrimary: true, isThisDevice: true, selected: true, state: .done, subdomain: "mini", url: nil, connection: .waiting)]
        nodeSnapshot.deviceReasons["mini"] = "等你按連線"; nodeSnapshot.dev = .failed; nodeSnapshot.problemPanel = .dev
        let nodes = HandsBuildGraph.make(nodeSnapshot, level: 2, cloudflareSub: "").nodes
        check(nodes[1].accessibilityLabel == "主 Mac mini：等你按連線：等你" && nodes.last?.sub == "要重連", "W310 graph node words agree with connection state")
        let diagnosticTap = ChatGPTTap(transport: FakeTapPod(running: true) { _, _ in [:] })
        let sourceLine = await diagnosticTap.diagnostics().first { $0.0 == "選單項目 id → 來源" }?.1 ?? ""
        check(sourceLine.contains("fable5.1 → builtin:claude") && !sourceLine.contains("Fable 5.1") && !sourceLine.contains("synthetic native models"), "W309 menu diagnostic includes only IDs and fixed source codes")
        diagnosticTap.sleep()
        let narrowPod = NarrowPod(running: true), narrowTap = ChatGPTTap(transport: narrowPod)
        let narrowModels = try await narrowTap.models()
        check(narrowModels.items.map(\.id) == ["desktop-fixture"] && narrowPod.width == 225 && narrowPod.users == 0,
              "W309 ChatGPT narrow page reads models and restores viewport")
        let modelHold = narrowTap.beginConnectorHold()!
        _ = try await narrowTap.models()
        check(narrowPod.commands.last?["pageBusy"] as? Bool == true && narrowPod.width == 225 && narrowPod.users == 0,
              "W310 model read during connector hold marks navigation busy and restores viewport")
        narrowTap.endConnectorHold(modelHold)
        narrowPod.emit(["type": "hello", "loggedIn": false])
        do { _ = try await narrowTap.models(); check(false, "W309 ChatGPT failed read restores viewport") }
        catch { check(narrowPod.width == 225 && narrowPod.users == 0, "W309 ChatGPT failed read restores viewport") }
        narrowTap.sleep()
        check(EngineAIUpdate.versionLine("1.0.0", "2.0.0").contains("可更新"), "new version")
        check(EngineAIUpdate.versionLine("2.0.0", "2.0.0").contains("已是最新"), "already latest")
        check(EngineAIUpdate.versionLine("2.0.0", nil).contains("查不到最新版本"), "latest lookup fails")
        check(EngineAIUpdate.suggested(old, catalog: catalog(["gpt-6-sol", new, "gpt-6.10-sol"], preferred: new)) == "gpt-6.10-sol", "same suffix newest numeric version")
        check(EngineAIUpdate.suggested("claude-fable-5-1", catalog: catalog(["claude-opus-9", "claude-fable-6-1"], engine: "claude")) == "claude-fable-6-1", "Claude same series")
        check(EngineAIUpdate.suggested(old, catalog: catalog(["gpt-6-luna"], preferred: "gpt-6-luna")) == "gpt-6-luna", "fallback provider default")
        check(EngineAIUpdate.suggested(old, catalog: catalog(["gpt-6-luna"], preferred: "missing")) == nil, "needs user selection")
        check(EngineAIUpdate.table("## 4. 角色\n| loops（整批施工） | gpt-0 |\n## 5. 其他\n| loops | gpt-0 |", section: "4", role: "loops", model: new) == "## 4. 角色\n| loops（整批施工） | \(new) |\n## 5. 其他\n| loops | gpt-0 |", "only target role table changes")
        EngineModelCatalog.replace([before])
        UltraworkRoleConfigurationStore(defaults: defaults).save(.init(primaryModelID: old, auxiliaryModelIDs: []))
        let update = EngineAIUpdate(defaults: defaults)
        var visited: [String] = []
        await update.check(source: { kind in
            visited.append(kind.rawValue)
            if kind == .codex { return ("1.0.0", "2.0.0", after) }
            return ("2.0.0", kind == .claude ? "2.0.0" : nil, nil)
        })
        check(visited == ["codex", "claude", "grok"], "independent sources all checked")
        check(update.message.contains("新增 1 個、下架 2 個") && update.message.contains("1 家查不到最新版本"), "new 1 retired 2 duplicate 1 counted accurately")
        check(EngineModelCatalog.catalogs().first?.models.count == 2, "same provider code deduplicated")
        check(ChatRouteChoice.all.filter { $0.runtimeAdapter == .codexExec }.count == 2 && !ChatRouteChoice.all.contains { $0.modelArgument == old }, "Coder menu replaced")
        check(ChatRouteChoice.resolve(old).modelArgument == new, "retired conversation uses provider default")
        check(update.proposals.count == 1 && update.proposals.first?.suggested == new, "role proposal awaits approval")
        let proposal = update.proposals[0]
        try await update.decide(proposal, accept: false)
        check(UltraworkRoleConfigurationStore(defaults: defaults).load().primaryModelID == old && EngineAIUpdate.retired(old) != nil, "defer preserves config and dispatch remains blocked")
        let snapshot = EngineModelCatalog.catalogs()
        update.cancel()
        await update.check(source: { _ in (nil, nil, nil) })
        check(EngineModelCatalog.catalogs() == snapshot && update.message.contains("3 家查不到最新版本"), "failed sources preserve catalog")
        update.cancel()
        let root = TatwoEntry().root, skill = root.appendingPathComponent("skills/tatwo-ultrawork/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"role\":\"primary\"}".utf8).write(to: TatwoEntry().deviceJSON)
        let osText = "## 4. 角色\n| 主導 | \(old) |\n## 5. 其他\n保持原樣\n"
        let skillText = "## 2. 角色\n| 主導 | \(old) |\n## 3. 流程\n保持原樣\n"
        try Data(osText.utf8).write(to: TatwoEntry().constitution); try Data(skillText.utf8).write(to: skill)
        var modelEnv = env; modelEnv["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "settings"
        let page = ChatPageModel(environment: modelEnv); page.engineQuotaDetails = [:]
        let tap = ChatGPTTap(transport: FakeTapPod(running: true), connection: .needsLogin)
        ChatGPTTapModelCatalog.replace([TapModel(id: "gpt-6", title: "GPT-6", detail: "", efforts: [.init(id: "light", title: "Light"), .init(id: "heavy", title: "Heavy")])])
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }
        for dark in [false, true] {
            theme.use(dark ? .aurora : .fable5)
            for state in ["idle", "running", "complete"] {
                update.running = state == "running"
                update.proposals = state == "complete" ? [proposal] : []
                update.message = state == "idle" ? "" : state == "running"
                    ? "正在更新 Codex（第 1 家，共 3 家）。正在用的對話不會被打斷。"
                    : "更新完成：2 家都是最新。模型清單已換新：新增 1 個、下架 2 個。"
                update.rows = state == "idle" ? ["codex": "0.160.0", "claude": "2.1.288", "grok": "0.2.11"]
                    : ["codex": state == "running" ? "進行中…" : "0.160.0 → 0.161.0 可更新。新增 GPT-6.1 Sol；下架 GPT-5.6 Sol、GPT-5.6 Luna", "claude": "2.1.288。已是最新", "grok": "0.2.11。已是最新"]
                let shot = GlobalDMChatAcceptance.renderSync(TatwoSettingsShell(section: .constant(.modelAccess)) {
                    EngineLoginCard(model: page, chatGPT: tap, aiUpdate: update)
                }, size: CGSize(width: 1040, height: 760), scheme: dark ? .dark : .light)!
                await W214Acceptance.settle(shot)
                let visible = W214Acceptance.text(shot)
                check(W214Acceptance.node("login.aiUpdate", shot) != nil && visible.contains("照網頁：GPT-6，強度 2 段"), "\(state) actual login page and TAP summary \(dark)")
                if state == "running" {
                    let button = W214Acceptance.node("login.aiUpdate", shot)!
                    let selector = NSSelectorFromString("isAccessibilityEnabled")
                    typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
                    let enabled = button.responds(to: selector) ? unsafeBitCast(button.method(for: selector), to: Enabled.self)(button, selector) : true
                    check(!enabled && visible.contains("進行中"), "running button disabled \(dark) enabled=\(enabled) progress=\(visible.contains("進行中"))")
                }
                if state == "complete" {
                    check(TatwoComposerModeAcceptance.press("login.aiUpdate.defer.0", in: shot), "real defer button \(dark)")
                    check(UltraworkRoleConfigurationStore(defaults: defaults).load().primaryModelID == old, "defer leaves role unchanged \(dark)")
                }
                try W214Acceptance.save(shot, (dark ? "dark-" : "light-") + state, artifacts)
                if state == "complete" && dark {
                    check(TatwoComposerModeAcceptance.press("login.aiUpdate.accept.0", in: shot), "real accept button")
                    await W214Acceptance.settle(shot)
                    check(UltraworkRoleConfigurationStore(defaults: defaults).load().primaryModelID == new && update.proposals.isEmpty, "accept saves actual role configuration")
                    let writtenOS = try String(contentsOf: TatwoEntry().constitution, encoding: .utf8)
                    let writtenSkill = try String(contentsOf: skill, encoding: .utf8)
                    check(writtenOS.contains(new) && writtenSkill == skillText, "accept updates os through document writer")
                    let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".tatwo2-backups"), includingPropertiesForKeys: nil)
                    check(try files.contains { try String(contentsOf: $0, encoding: .utf8) == osText }, "accept document writer backs up os before change")
                }
                shot.close()
            }
        }
        try await W351Acceptance.rules(defaults: defaults, check: check)
        // Actual dispatch entrypoint must reject before opening any worktree.
        let store = ChatLiveStore(root: root.appendingPathComponent("dispatch-fixture"))
        var doc = LiveDocumentRecord(); let project = doc.ensureGeneralProject(); store.save(doc)
        let live = ChatLiveEngine(store: store, environment: env)
        defer { live.shutdownAll() }
        let parent = live.newThread(in: project, title: "synthetic parent")
        let coder = ChatPageModel(environment: env, botCoreFixture: (live, BotStore(root: root.appendingPathComponent("bots"))))
        let threadIDs = Set(live.doc.threads.map(\.id))
        do { _ = try await coder.dispatchChecked(rooms: [.init(title: "blocked", engine: "codex", model: old, brief: "synthetic")], parent: parent); check(false, "retired dispatch refused") }
        catch { check(String(describing: error).contains("先不派工"), "retired dispatch refused") }
        check(Set(live.doc.threads.map(\.id)) == threadIDs, "dispatch refusal creates no child or worktree")
        let priorDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = priorDefaults
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../tests/fixtures/w298a-sidecar.mjs").standardizedFileURL
        overrides["tatwo2.sidecarPath.codex"] = script.path
        UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(priorDefaults, forName: UserDefaults.argumentDomain) }
        live.setRequestedModel(old, threadID: parent)
        check(live.send(threadID: parent, text: "synthetic next sentence", model: old, engine: .codex), "next sentence admitted")
        let capture = artifacts.appendingPathComponent("w298a-command.json")
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: capture.path) { break }; try await Task.sleep(for: .milliseconds(30)) }
        let command = (try? JSONSerialization.jsonObject(with: Data(contentsOf: capture))) as? [String: Any]
        check(command?["model"] as? String == new && live.threadRecord(parent)?.requestedModel == new, "next sentence actually sends and stores same provider default")
        update.running = false; update.proposals = []; update.message = ""
        var release: CheckedContinuation<Void, Never>?
        update.source = { kind in
            if kind == .codex { await withCheckedContinuation { release = $0 } }
            return ("2.0.0", "2.0.0", nil)
        }
        let buttonShot = GlobalDMChatAcceptance.renderSync(EngineLoginCard(model: page, chatGPT: tap, aiUpdate: update), size: CGSize(width: 800, height: 600), scheme: .light)!
        defer { buttonShot.close() }
        await W214Acceptance.settle(buttonShot)
        check(TatwoComposerModeAcceptance.press("login.aiUpdate", in: buttonShot), "real update button starts check")
        for _ in 0..<50 { if release != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        check(update.running && update.message.contains("第 1 家，共 3 家"), "button enters provider progress")
        release?.resume()
        for _ in 0..<50 { if !update.running { break }; try await Task.sleep(for: .milliseconds(20)) }
        check(!update.running && update.message.contains("3 家都是最新"), "button completes fake version sources")
        return failed == 0
    }
}
#endif
