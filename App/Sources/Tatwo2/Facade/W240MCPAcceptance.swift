#if DEBUG
import Foundation
import SwiftUI
import AppKit

enum W240MCPAcceptance {
    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else { throw CocoaError(.fileReadNoPermission) }
        let registry = OSMCPRegistry(environment: env), home = registry.paths.userHome
        let source = home.appendingPathComponent(".claude.json")
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) { print("W240MCP \(value ? "PASS" : "FAIL") \(label)"); if value { passed += 1 } else { failed += 1 } }
        func write(_ object: [String: Any], to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        }
        func definition(_ args: [String] = ["pkg@1.0.0", "--mode", "one"]) -> [String: Any] { ["command": "npx", "args": args, "env": ["OTHER": "W240_FAKE_ENV" ]] }
        var servers: [String: Any] = ["safe": definition()]
        func publish() throws { try write(["mcpServers": servers], to: source) }
        func item(_ name: String) -> OSMCPRegistry.Item { registry.scan().items.first { $0.sourceName == name && $0.source == source.path }! }
        try publish()
        let original = try Data(contentsOf: source)
        try registry.bringIn([item("safe")])
        var imported = try registry.load().first { $0.sourceName == "safe" }!
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: registry.url)) as! [[String: Any]]
        check(stored[0]["args"] == nil && stored[0]["env"] == nil, "M1 OS list contains no copied arguments or values")
        servers["safe"] = definition(["pkg@1.0.0", "--mode", "two"]); try publish()
        check(registry.resolve(imported) == nil && registry.failureReason(imported) == "來源設定變了，請重新帶入", "M1 changed args require renewed consent")
        try registry.bringIn([item("safe")])
        let updates = await registry.checkUpdates(fetcher: { _ in Data(#"{"version":"2.0.0"}"#.utf8) })
        try registry.update(imported.id, to: updates[imported.id]!, confirmed: true)
        let overridden = try JSONSerialization.jsonObject(with: Data(contentsOf: registry.url)) as! [[String: Any]]
        check(overridden[0]["args"] == nil && overridden[0]["packageOverride"] as? [String] == ["pkg@1.0.0", "pkg@2.0.0"], "M1 confirmed update stores only package spec override")
        servers["safe"] = definition(["pkg@1.0.0", "--mode", "three"]); try publish()
        check(registry.resolve(try registry.load()[0]) == nil, "M1 override does not bypass changed source consent")
        try registry.bringIn([item("safe")])
        check(registry.resolve(try registry.load()[0])?["args"] as? [String] == ["pkg@2.0.0", "--mode", "three"], "M1 override replaces one argument and retains fresh source arguments")
        let keys = ["key", "token", "secret", "password", "passwd", "auth", "bearer", "header"]
        let fakeArgument = "W240_FAKE_ARG"
        let secrets = keys.flatMap { [["--\($0)", "W240_FAKE_ARG"], ["\($0)=W240_FAKE_ARG"], ["--\($0)=W240_FAKE_ARG"]] }
            + [["redis://:\(fakeArgument)@fixture.invalid"], ["jdbc:mysql://fixture.invalid/db?user=u&password=\(fakeArgument)"], ["Server=fixture;Uid=u;Pwd=\(fakeArgument)"], ["VALUE=sk-\(fakeArgument)"], ["--other=ghp_\(fakeArgument)"], ["postgres://user:\(fakeArgument)@fixture.invalid/db"], ["sk-\(fakeArgument)"], ["ghp_\(fakeArgument)"], ["github_pat_\(fakeArgument)"], ["xoxb-\(fakeArgument)"], ["AKIA\(fakeArgument)"]]
        for (index, args) in secrets.enumerated() {
            let name = "blocked\(index)"; servers[name] = definition(args); try publish()
            let candidate = item(name), before = try Data(contentsOf: registry.url)
            check(candidate.blocked && candidate.warning == "參數裡像有金鑰，請改放 env 再帶入" && candidate.commandLine.contains("••••") && !candidate.commandLine.contains("W240_FAKE_ARG"), "M1 redacts secret form \(index)")
            do { try registry.bringIn([candidate]); check(false, "M1 rejects secret form \(index)") }
            catch { check(try Data(contentsOf: registry.url) == before, "M1 rejects secret form \(index) without changing list") }
        }
        servers["safe"] = definition(["--token", "W240_FAKE_ARG"]); try publish()
        check(registry.resolve(imported) == nil && registry.servers()[imported.name] == nil && registry.failureReason(imported) == "參數裡像有金鑰，請改放 env 再帶入", "M1 imported source gaining secret is withheld")
        try original.write(to: source)
        try registry.bringIn([item("safe")])
        imported = try registry.load()[0]
        for field in ["command", "env", "url", "headers", "http_headers"] {
            var changed = definition()
            switch field {
            case "command": changed[field] = "uvx"
            case "env": changed[field] = ["OTHER": "W240_FAKE_ENV", "NODE_OPTIONS": "--fixture"]
            case "url": changed[field] = "https://changed.fixture.invalid/mcp"
            default: changed[field] = ["Authorization": "W240_FAKE_HEADER"]
            }
            let beforeChange = item("safe")
            servers = ["safe": changed]; try publish()
            do { try registry.bringIn([beforeChange]); check(false, "M2 rejects stale selection \(field)") }
            catch { check(true, "M2 rejects stale selection \(field)") }
            check(registry.failureReason(imported) == "來源設定變了，請重新帶入" && registry.resolve(imported) == nil && registry.servers()[imported.name] == nil, "M2 changed \(field) requires consent")
            try original.write(to: source)
        }
        servers = ["safe": definition()]; var rotated = definition(); rotated["env"] = ["OTHER": "W240_FAKE_ROTATED"]
        servers["safe"] = rotated; try publish()
        check(registry.resolve(imported) == nil && registry.failureReason(imported) == "來源設定變了，請重新帶入", "M2 ordinary env value change requires renewed consent")
        var credential = definition(); credential["env"] = ["API_TOKEN": "W240_FAKE_ONE"]
        servers["safe"] = credential; try publish(); try registry.bringIn([item("safe")])
        let credentialConsent = try registry.load()[0]
        credential["env"] = ["API_TOKEN": "W240_FAKE_TWO"]
        servers["safe"] = credential; try publish()
        check((registry.resolve(credentialConsent)?["env"] as? [String: String])?["API_TOKEN"] == "W240_FAKE_TWO", "M2 credential env value rotation retains consent for same key")
        servers["safe"] = ["command": "uvx", "args": ["pkg==1.0.0"], "env": ["OTHER": "W240_FAKE_ENV"]]; try publish()
        try registry.bringIn([item("safe")])
        imported = try registry.load()[0]
        let renewedCount = try registry.load().count
        check(registry.resolve(imported)?["command"] as? String == "uvx" && renewedCount == 1, "M2 explicit reimport renews consent without duplicate")
        try original.write(to: source)
        try registry.bringIn([item("safe")])
        let currentSafe = try registry.load().first { $0.sourceName == "safe" }!
        for (args, label) in [(["pkg@1.0.0"], "M2"), (["--token", "W240_FAKE_ARG"], "M1")] {
            let changed: [String: Any] = ["command": label == "M2" ? "uvx" : "npx", "args": args, "env": ["OTHER": "W240_FAKE_ENV"]]
            try write(["mcpServers": ["safe": changed]], to: source)
            try write(["mcpServers": ["safe": changed]], to: registry.paths.claudeAccountFile)
            let text = PluginsSource.sidecarMCPConfig(engine: .claude, stored: [currentSafe.name], environment: env)!
            let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            check((payload["servers"] as? [String: Any])?[currentSafe.name] == nil, "\(label) native Claude definition cannot bypass OS rejection")
        }
        try original.write(to: source)
        try write(["mcpServers": ["safe": definition()]], to: registry.paths.claudeAccountFile)
        let fallbackSource = registry.paths.codexHome.appendingPathComponent("config.toml")
        let fallbackTOML = "[mcp_servers.nativeFallback]\ncommand = 'npx'\nargs = []\nenv = { OTHER = 'W240_FAKE_ENV' }\n"
        try fm.createDirectory(at: fallbackSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fallbackTOML.utf8).write(to: fallbackSource)
        try registry.bringIn(registry.scan().items.filter { $0.source == fallbackSource.path })
        let fallback = try registry.load().first { $0.sourceName == "nativeFallback" }!
        try Data((fallbackTOML + "[mcp_servers.nativeFallback.env]\nNODE_OPTIONS = '--fixture'\n").utf8).write(to: fallbackSource)
        let blockedText = PluginsSource.sidecarMCPConfig(engine: .codex, stored: [fallback.name], environment: env)!
        let blockedPayload = try JSONSerialization.jsonObject(with: Data(blockedText.utf8)) as! [String: Any]
        check(!(blockedPayload["enabled"] as? [String] ?? []).contains(fallback.name) && (blockedPayload["servers"] as? [String: Any])?[fallback.name] == nil, "M2 native Codex definition cannot bypass OS rejection")
        try Data(fallbackTOML.utf8).write(to: fallbackSource)
        let projectA = home.appendingPathComponent("projects/one"), projectB = home.appendingPathComponent("projects/two")
        let same: [String: Any] = ["mcpServers": ["same": definition()]]
        try write(["mcpServers": ["same": definition()], "projects": [projectA.path: same, projectB.path: same]], to: source)
        let twins = registry.scan().items.filter { $0.sourceName == "same" }
        check(twins.count == 3 && Set(twins.map(\.id)).count == 3 && Set(twins.map(\.displayName)).count == 3, "M3 global and two project scopes stay distinct with path labels")
        try registry.bringIn(twins)
        check(try registry.load().filter { $0.sourceName == "same" }.count == 3, "M3 all three same-name scopes can be imported")
        let scopedFile = projectA.appendingPathComponent(".mcp.json")
        try write(same, to: scopedFile)
        try write(["projects": [["workdir": projectA.path]]], to: registry.root.appendingPathComponent("document.json"))
        check(registry.scan().items.first { $0.source == scopedFile.path }?.scope == projectA.path, "M3 project source file also displays its scope")
        let saved = try Data(contentsOf: registry.url)
        try JSONSerialization.data(withJSONObject: [["source": scopedFile.path, "sourceName": "same", "name": "fixture", "command": "npx", "args": ["OLD"], "envKeys": ["OTHER"], "group": "通用", "id": scopedFile.path + "\n" + "same"]]).write(to: registry.url)
        let legacy = try registry.load()
        check(legacy.count == 1 && legacy[0].sourceName == "same" && legacy[0].scope == projectA.path, "M3 old unscoped OS list remains readable")
        try saved.write(to: registry.url)
        try original.write(to: source)
        let unsafeNames = ["雲端 MCP", "same.name", "same name", "quote\"name", "github.fixture"]
        servers = Dictionary(uniqueKeysWithValues: unsafeNames.map { ($0, definition()) }); try publish()
        try registry.bringIn(registry.scan().items.filter { $0.source == source.path })
        let renamed = try registry.load().filter { unsafeNames.contains($0.sourceName) }
        check(renamed.count == unsafeNames.count && Set(renamed.map(\.name)).count == unsafeNames.count && renamed.allSatisfy { $0.name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil && $0.displayName == $0.sourceName }, "M4 safe unique engine names preserve original display names")
        var oldNames = try JSONSerialization.jsonObject(with: Data(contentsOf: registry.url)) as! [[String: Any]]
        let unsafe = oldNames.firstIndex { $0["sourceName"] as? String == unsafeNames[0] }!
        oldNames[unsafe]["name"] = unsafeNames[0]
        try JSONSerialization.data(withJSONObject: oldNames).write(to: registry.url)
        try registry.bringIn([item(unsafeNames[0])])
        check(try registry.load().first { $0.sourceName == unsafeNames[0] }!.name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, "M4 reimport also sanitizes legacy unsafe names")
        try original.write(to: source)
        let proof = Process(), pipe = Pipe()
        proof.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proof.arguments = ["node", "tests/w240-mcp.test.mjs", "--claude-expansion-proof"]
        proof.environment = env; proof.standardOutput = pipe; proof.standardError = pipe
        try proof.run()
        let evidence = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proof.waitUntilExit()
        check(proof.terminationStatus == 0 && evidence.contains("M5 actual Claude alias expansion"), "M5 actual Claude expands aliases into fake MCP env and headers with no raw values in argv")
        if proof.terminationStatus != 0 { print(evidence) }
        let tomlSource = registry.paths.codexHome.appendingPathComponent("config.toml")
        let toml = """
        [mcp_servers.fields]
        command = 'fixture'
        args = ['one']
        cwd = '/fake/cwd'
        startup_timeout_sec = 12.5
        tool_timeout_sec = 90
        env_vars = [
          'INHERITED', 'SECOND'
        ]
        bearer_token_env_var = 'BEARER_FIXTURE'
        env = { OTHER = 'W240_FAKE_ENV' }
        [mcp_servers.remote]
        url = 'https://fixture.invalid/mcp'
        http_headers = { Authorization = 'W240_FAKE_HEADER' }
        bearer_token_env_var = 'REMOTE_BEARER'
        """
        try fm.createDirectory(at: tomlSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(toml.utf8).write(to: tomlSource)
        try registry.bringIn(registry.scan().items.filter { $0.source == tomlSource.path })
        let fields = try registry.load().first { $0.sourceName == "fields" }!
        let resolved = registry.resolve(fields)!
        check(resolved["cwd"] as? String == "/fake/cwd" && resolved["startup_timeout_sec"] as? Double == 12.5 && resolved["tool_timeout_sec"] as? Double == 90 && resolved["env_vars"] as? [String] == ["INHERITED", "SECOND"] && resolved["bearer_token_env_var"] as? String == "BEARER_FIXTURE", "M6 TOML fields retained including multiline env_vars")
        for engine in [PluginsSource.MCPEngine.codex, .claude] {
            let text = PluginsSource.sidecarMCPConfig(engine: engine, stored: [fields.name], environment: env)!
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            let engineFields = (object["servers"] as! [String: [String: Any]])[fields.name]!
            check(engine == .codex ? engineFields["cwd"] as? String == "/fake/cwd" : ["enabled", "cwd", "env_vars", "bearer_token_env_var", "startup_timeout_sec", "tool_timeout_sec"].allSatisfy { engineFields[$0] == nil }, "M6 \(engine.rawValue) receives only supported fields")
        }
        let healthy = PluginsSource.osMCPEntries(environment: env).first { $0.id == "os-mcp:" + fields.id }!
        check(healthy.liveness.detail == nil && !PluginConnectionCard(entry: healthy).showsLivenessStatus, "M7 untouched OS MCP card has no unexplored status")
        let safeItem = try registry.load().first { $0.sourceName == "safe" }!
        servers = ["safe": ["command": "uvx", "args": []]]; try publish()
        let changedCard = PluginsSource.osMCPEntries(environment: env).first { $0.id == "os-mcp:" + safeItem.id }!
        check(changedCard.liveness.detail == "請重新帶入" && changedCard.trigger.contains("來源設定變了：") && !PluginConnectionCard(entry: changedCard).showsLivenessStatus, "M7 source change card says required action and changed fields once")
        servers = ["safe": definition(["--token", "W240_FAKE_ARG"])]; try publish()
        check(PluginsSource.osMCPEntries(environment: env).first { $0.id == "os-mcp:" + safeItem.id }?.liveness.detail == "參數裡像有金鑰，請改放 env 再帶入", "M7 imported secret warning appears on card")
        try fm.moveItem(at: source, to: source.appendingPathExtension("missing"))
        check(PluginsSource.osMCPEntries(environment: env).first { $0.id == "os-mcp:" + safeItem.id }?.liveness.detail == "來源不見了", "M7 missing source card says required action")
        try fm.moveItem(at: source.appendingPathExtension("missing"), to: source)
        try original.write(to: source)
        for duplicate in try registry.load().filter({ $0.sourceName == "same" }) { try registry.remove(duplicate.id) }
        try write(["mcpServers": ["same": definition(), "金鑰參數": definition(["--token", "W240_FAKE_ARG"]), "safe": ["command": "uvx", "args": []]], "projects": [projectA.path: same, projectB.path: same]], to: source)
        let index = registry.scan().items.filter { $0.source == source.path && $0.sourceName != "safe" }
        let cards = PluginsSource.osMCPEntries(environment: env).filter { $0.id == "os-mcp:" + safeItem.id || $0.id == "os-mcp:" + fields.id }
        guard let folder = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileWriteNoPermission) }
        let artifacts = URL(fileURLWithPath: folder)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let page = PluginsPage(entries: [], environment: [], skillsDirectoryCatalog: .init(rootURL: artifacts), skilletRepositoryStore: .init(rootURL: artifacts), onRegister: { _, _, _, _ in }, onRemove: { _ in })
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }; theme.use(.aurora)
        for phase in ["index", "cards"] { for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let content = page.mcpAcceptanceView(scan: phase == "index" ? .init(items: index) : nil, imported: phase == "cards" ? cards : [], updates: [:]).padding(24).frame(width: 1000, alignment: .leading)
                .background(dark ? Color(red: 0.08, green: 0.09, blue: 0.12) : Color(red: 0.95, green: 0.95, blue: 0.97)).environment(\.colorScheme, scheme)
            guard let shot = GlobalDMChatAcceptance.renderSync(content, size: CGSize(width: 1000, height: 760), scheme: scheme), let png = shot.bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            defer { shot.close() }
            check(!dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap), "M7 screenshot \(phase) \(dark ? "dark" : "light") readable")
            try png.write(to: artifacts.appendingPathComponent("w240-\(phase)-\(dark ? "dark" : "light").png"))
            var labels = [String](), seen = Set<ObjectIdentifier>()
            func visit(_ node: NSObject, _ depth: Int) {
                guard depth < 80, seen.insert(ObjectIdentifier(node)).inserted else { return }
                for (selector, attribute) in [("accessibilityLabel", "AXDescription"), ("accessibilityValue", "AXValue"), ("accessibilityTitle", "AXTitle")] {
                    if let label = GlobalDMChatAcceptance.attribute(node, selector, attribute) as? String { labels.append(label) }
                }
                for child in GlobalDMChatAcceptance.attribute(node, "accessibilityChildren", "AXChildren") as? [NSObject] ?? [] { visit(child, depth + 1) }
                if let view = node as? NSView { for child in view.subviews { visit(child, depth + 1) } }
            }
            visit(shot.window, 0); visit(shot.host, 0)
            let text = labels.joined(separator: "\n")
            check(!text.isEmpty && !text.contains("W240_FAKE_ARG") && !text.contains("未探測"), "M1/M7 rendered UI exposes neither argument values nor unexplored status")
            check(!text.contains("同步到 Claude") && !text.contains("移除登記"), "M8 rendered MCP page exposes no legacy actions")
            check(phase == "index" ? text.contains("參數裡像有金鑰，請改放 env 再帶入") && text.contains("projects/one") && text.contains("projects/two") : text.contains("來源設定變了：") && text.contains("請重新帶入"), "M1/M3/M7 required notices and scopes are actually rendered")
        } }
        let sourceBeforeRemoval = try Data(contentsOf: source), tomlBeforeRemoval = try Data(contentsOf: tomlSource)
        try registry.remove(fields.id)
        let remaining = try registry.load()
        check(!remaining.contains { $0.id == fields.id } && registry.servers()[fields.name] == nil, "M8 OS removal removes the reference")
        for engine in [PluginsSource.MCPEngine.codex, .claude] {
            let text = PluginsSource.sidecarMCPConfig(engine: engine, stored: [fields.name], environment: env) ?? "{}"
            let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            check((payload["servers"] as? [String: Any])?[fields.name] == nil, "M8 \(engine.rawValue) payload omits removed OS definition")
        }
        check(try Data(contentsOf: source) == sourceBeforeRemoval && Data(contentsOf: tomlSource) == tomlBeforeRemoval, "M8 OS removal never synchronizes or modifies either source file")
        print("W240MCP SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}
#endif
