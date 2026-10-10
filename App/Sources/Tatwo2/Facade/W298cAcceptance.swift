#if DEBUG
import AppKit
import SwiftUI
import Foundation

private final class W298cHTTP: URLProtocol {
    static var body = "", status = 200, offline = false
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor enum W298cAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let artifact = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) { if value { passed += 1 } else { failed += 1 }; print("W298C \(value ? "PASS" : "FAIL") \(label)") }
        defer { print("W298C SUMMARY failures=\(failed) passed=\(passed)") }
        let artifacts = URL(fileURLWithPath: artifact), fm = FileManager.default
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let cli = artifacts.appendingPathComponent("ollama")
        try Data("fixture only; never executed".utf8).write(to: cli)
        check(!LocalModelSource.installed(paths: [cli.path]), "nonexecutable does not count as installed")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        check(LocalModelSource.installed(paths: [cli.path]), "executable installation detected without running it")
        check(!LocalModelSource.installed(paths: [cli.path + "-missing"]), "absent installation hidden")
        let app = artifacts.appendingPathComponent("Ollama.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        check(LocalModelSource.installed(paths: [app.path]), "application installation detected")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [W298cHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "w298c." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let update = EngineAIUpdate(defaults: defaults)
        check(!update.localInstalled, "isolated environment never probes real Ollama")
        let isolatedRead = await LocalModelSource.read()
        check(isolatedRead.1 == nil, "isolated production source never requests real loopback")
        let prior = EngineModelCatalog.catalogs()
        defer { EngineModelCatalog.replace(prior) }
        EngineModelCatalog.replace([])
        update.localSource = { await LocalModelSource.read(session: session) }
        var installs = 0, visits: [String] = []
        update.install = { _, _ in installs += 1; return "unexpected install" }
        let cloud: EngineAIUpdate.Source = { kind in visits.append(kind.rawValue); return ("1.0.0", "1.0.0", nil) }
        func sync(_ body: String, status: Int = 200, offline: Bool = false) async {
            W298cHTTP.body = body; W298cHTTP.status = status; W298cHTTP.offline = offline
            update.cancel()
            await update.check(source: cloud)
        }
        await sync(#"{"models":[{"name":"qwen3:8b"},{"name":"qwen3:8b"},{"name":"llama3:latest"}]}"#)
        check(visits == ["codex", "claude", "grok"], "fourth source shares cloud comparison pass")
        check(EngineModelCatalog.catalogs().first?.models.map(\.model) == ["qwen3:8b", "llama3:latest"], "HTTP names preserved and duplicate removed")
        check(update.message.contains("新增 2 個、下架 0 個"), "addition counts use shared comparison")
        let sections = ChatRouteChoice.brandSections(selectedID: nil)
        let local = sections.first { $0.brand == .local }
        check(local?.choices.map(\.title) == ["qwen3:8b", "llama3:latest"], "Coder local group preserves name tag")
        check(local?.choices.allSatisfy { $0.providerIconID == "local-api" && EngineModelCatalog.engineID($0.profile) == "ollama" && $0.runtimeAdapter == .unavailable } == true, "local routes never execute through Codex")
        check(sections.first { $0.brand == .openAI }?.choices.contains { $0.id == "qwen3:8b" } == false, "local names do not enter OpenAI group")
        let options = TatwoComposerMode.routeOptions(selectedID: nil)
        check(options.filter { $0.brand == .local }.map(\.title) == ["qwen3:8b", "llama3:latest"], "actual Coder menu keeps exact Ollama spelling")
        check(TatwoComposerModeCard.brandGroups(options).first { $0.brand == .local }?.options.count == 2, "actual Coder card has one local group")
        await sync(#"{"models":[{"name":"qwen3:14b"}]}"#)
        check(update.message.contains("新增 1 個、下架 2 個") && !ChatRouteChoice.choices().contains { $0.id == "qwen3:8b" }, "new download added and deleted models retired")
        let saved = EngineModelCatalog.catalogs()
        await sync("", offline: true)
        check(update.rows["ollama"] == "本機模型服務沒開" && EngineModelCatalog.catalogs() == saved && !update.running, "offline is a row status and preserves catalog")
        await sync("not JSON")
        check(update.rows["ollama"] == "本機模型清單查不到" && EngineModelCatalog.catalogs() == saved, "bad JSON preserves catalog without error")
        for body in [#"{}"#, #"{"models":[{"name":""}]}"#, #"{"models":[{"name":3}]}"#] {
            await sync(body)
            check(EngineModelCatalog.catalogs() == saved, "invalid schema never retires models \(body)")
        }
        await sync(#"{"models":[]}"#, status: 503)
        check(EngineModelCatalog.catalogs() == saved, "HTTP failure never treats empty body as retirement")
        await sync(#"{"models":[]}"#)
        check(update.message.contains("新增 0 個、下架 1 個") && !ChatRouteChoice.brandSections(selectedID: nil).contains { $0.brand == .local }, "valid empty list retires all local models")
        let collisions = ["qwen3:8b", "QWEN3:8B", "gpt-6.1-sol", "grok-build"].map { ["name": $0] }
        await sync(String(decoding: try JSONSerialization.data(withJSONObject: ["models": collisions]), as: UTF8.self))
        check(EngineModelCatalog.profiles().filter { EngineModelCatalog.engineID($0) == "ollama" }.count == 3, "W297 same provider lookup key deduplicates local aliases")
        check(EngineModelCatalog.profiles().contains { EngineModelCatalog.engineID($0) == "codex" && $0.modelArgument == "gpt-6.1-sol" } &&
              EngineModelCatalog.profiles().contains { EngineModelCatalog.engineID($0) == "grok" }, "same ID across providers preserves cloud and W298a Grok identity")
        update.cancel()
        var selectedInstalls: [String] = []
        update.install = { kind, _ in selectedInstalls.append(kind.rawValue); return "已更新" }
        await update.check(source: { _ in ("1.0.0", "2.0.0", nil) })
        update.toggle("ollama"); update.toggle("claude"); update.toggle("grok")
        check(update.selecting && update.selected == ["codex"], "local cannot select while vendor selection remains intact")
        let untouchedRows = update.rows.filter { ["claude", "grok"].contains($0.key) }
        await update.installSelected()
        check(selectedInstalls == ["codex"] && update.rows.filter { ["claude", "grok"].contains($0.key) } == untouchedRows, "local refresh preserves selected install and skipped vendors")
        update.cancel()
        await update.check(source: cloud)
        let row = update.rows["ollama"]
        update.cancel()
        check(update.rows["ollama"] == row && !update.selecting, "cancel preserves local row and never installs Ollama")
        check(installs == 0, "local sync never installs or advertises update")
        let requests = W298cHTTP.requests.count
        let mlx = await LocalModelSource.read(.mlx, session: session)
        check(mlx.0 == "MLX 尚未接入" && mlx.1 == nil && W298cHTTP.requests.count == requests, "MLX same interface stub does no HTTP")
        check(W298cHTTP.requests.allSatisfy { $0.url?.absoluteString == "http://127.0.0.1:11434/api/tags" && $0.httpMethod == "GET" && $0.timeoutInterval == 3 }, "only fixed loopback GET with bounded timeout")
        check(!update.hasNewVersion, "local refresh does not light version dot")
        let store = ChatLiveStore(root: artifacts.appendingPathComponent("chat"))
        let live = ChatLiveEngine(store: store, environment: env)
        defer { live.shutdownAll() }
        let page = ChatPageModel(environment: env, botCoreFixture: (live, BotStore(root: artifacts.appendingPathComponent("bots"))))
        page.engineLoginTestDouble = []
        let tap = ChatGPTTap(transport: FakeTapPod(running: true) { _, _ in ["models": []] })
        defer { tap.sleep() }
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }
        for themeID in [TatwoThemeID.fable5, .aurora] {
            theme.use(themeID)
            for dark in [false, true] {
                for installed in [false, true] {
                    update.localSource = installed ? { await LocalModelSource.read(session: session) } : nil
                    update.rows["ollama"] = "本機模型服務沒開"
                    update.selecting = true
                    let shot = GlobalDMChatAcceptance.renderSync(EngineLoginCard(model: page, chatGPT: tap, aiUpdate: update), size: CGSize(width: 900, height: 760), scheme: dark ? .dark : .light)!
                    await W214Acceptance.settle(shot)
                    check((W214Acceptance.node("login.localModels", shot) != nil) == installed, "native row only when installed dark=\(dark) installed=\(installed)")
                    if installed {
                        check(W214Acceptance.text(shot).contains("本機模型服務沒開"), "native offline status dark=\(dark)")
                        let row = W214Acceptance.node("login.localModels", shot)!
                        let children = W214Acceptance.attr(row, "accessibilityChildren", "AXChildren") as? [NSObject] ?? []
                        check(!children.contains { ["AXButton", "AXCheckBox"].contains(W214Acceptance.attr($0, "accessibilityRole", "AXRole") as? String ?? "") }, "native local row has no update control dark=\(dark)")
                    }
                    try W214Acceptance.save(shot, "\(themeID.rawValue)-\(dark ? "dark" : "light")-\(installed ? "installed" : "absent")", artifacts)
                    if installed {
                        update.selecting = false
                        update.rows["ollama"] = "只同步清單。新增 qwen3:8b、llama3:latest"
                        await W214Acceptance.settle(shot)
                        check(W214Acceptance.text(shot).contains("qwen3:8b") && W214Acceptance.text(shot).contains("照本機"), "native refreshed model names visible theme=\(themeID.rawValue) dark=\(dark)")
                        try W214Acceptance.save(shot, "\(themeID.rawValue)-\(dark ? "dark" : "light")-refreshed", artifacts)
                    }
                    shot.close()
                }
            }
        }
        return failed == 0
    }
}
#endif
