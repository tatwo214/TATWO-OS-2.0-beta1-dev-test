#if DEBUG
import Foundation
import SwiftUI
import AppKit

enum W242MCPAcceptance {
    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else { throw CocoaError(.fileReadNoPermission) }
        let registry = OSMCPRegistry(environment: env), source = registry.paths.userHome.appendingPathComponent(".claude.json")
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) { print("W242MCP \(value ? "PASS" : "FAIL") \(label)"); if value { passed += 1 } else { failed += 1 } }
        func publish(_ servers: [String: Any]) throws {
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys]).write(to: source)
        }
        func candidate(_ name: String) -> OSMCPRegistry.Item { registry.scan().items.first { $0.source == source.path && $0.sourceName == name }! }
        let safe: [String: Any] = ["command": "npx", "args": ["fixture@1.0.0"]]
        let fixtureHost = "fixture.invalid", userInfo = "u:p", user = "u"
        let fakeKey = ["sk", "FAKE"].joined(separator: "-"), fakePAT = ["github", "pat", "FAKE"].joined(separator: "_"), fakeGitHub = ["ghp", "FAKE"].joined(separator: "_")
        let urls = ["https://\(userInfo)@\(fixtureHost)/mcp", "https://\(user)@\(fixtureHost)/mcp", "https://\(userInfo)%3Fa@\(fixtureHost)/mcp", "https://fixture.invalid/mcp?api_key=FAKE", "https://fixture.invalid/mcp?access_token=FAKE", "https://fixture.invalid/secret/FAKE", "https://fixture.invalid/mcp?x=\(fakeKey)", "https://fixture.invalid/\(fakePAT)", "https://fixture.invalid/mcp?signature=FAKE", "https://fixture.invalid/mcp?x=\(fakeGitHub)", "https://fixture.invalid/mcp?x=xoxb-FAKE", "https://fixture.invalid/mcp?x=AKIAFAKE", "https://fixture.invalid/mcp?%74oken=FAKE"]
        for (index, url) in urls.enumerated() {
            for remote in [true, false] {
                let definition: [String: Any] = remote ? ["url": url] : ["command": "fixture", "args": ["--url=" + url]]
                try publish(["blocked": definition])
                let item = candidate("blocked")
                check(item.blocked && item.commandLine.contains("••••") && !item.commandLine.contains(url), "K1 redacts and disables URL form \(index) remote=\(remote)")
                do { try registry.bringIn([item]); check(false, "K1 refuses URL import") } catch { check(true, "K1 refuses URL import") }
            }
        }
        try publish(["safe": safe]); try registry.bringIn([candidate("safe")])
        let imported = try registry.load()[0]
        try publish(["safe": ["url": urls[0]]])
        check(registry.resolve(imported) == nil && registry.servers().isEmpty && registry.failureReason(imported)?.contains("headers 或 env") == true, "K1 already imported secret URL withheld with remedy")
        check(PluginsSource.osMCPEntries(environment: env)[0].purpose == "••••", "K1 card masks current remote URL")
        try publish(["safe": safe])
        let fields: [String: Any] = ["command": "uvx", "args": ["other"], "cwd": "/fake", "env": ["NEW": "FAKE"], "env_vars": ["INHERITED"], "url": "https://other.invalid/mcp", "headers": ["X-Test": "FAKE"], "http_headers": ["X-Other": "FAKE"], "env_http_headers": ["X-Env": "HEADER_ENV"], "bearer_token_env_var": "BEARER_ENV", "enabled_tools": ["read"], "disabled_tools": ["write"]]
        for (field, value) in fields {
            var changed = safe; changed[field] = value
            try publish(["safe": changed])
            check(registry.resolve(imported) == nil && registry.failureReason(imported) == "來源設定變了，請重新帶入", "K2 changed \(field) withheld")
            do { try registry.bringIn([imported]); check(false, "K2 stale selection denied") } catch { check(true, "K2 stale selection denied") }
        }
        try publish(["safe": safe])
        let storage = try String(contentsOf: registry.url, encoding: .utf8)
        check(imported.consent?.fingerprint?.count == 64 && !storage.contains("fixture@1.0.0") && !storage.contains("https://"), "K2 SHA256 consent stores no args or URL")
        let headerDefinition: [String: Any] = ["command": "fixture", "args": [], "env": ["ENV": "FAKE_ONE"], "headers": ["X-Test": "FAKE_ONE"]]
        try publish(["safe": headerDefinition]); try registry.bringIn([candidate("safe")])
        let keyConsent = try registry.load()[0]
        var rotated = headerDefinition; rotated["env"] = ["ENV": "FAKE_TWO"]; rotated["headers"] = ["X-Test": "FAKE_TWO"]
        try publish(["safe": rotated])
        check(registry.resolve(keyConsent) == nil, "K2 ordinary env and header value changes require renewed consent")
        let credentials: [String: Any] = ["command": "fixture", "env": ["API_TOKEN": "FAKE_ONE"], "headers": ["Authorization": "FAKE_ONE"]]
        try publish(["safe": credentials]); try registry.bringIn([candidate("safe")])
        let credentialConsent = try registry.load()[0]
        var rotatedCredentials = credentials; rotatedCredentials["env"] = ["API_TOKEN": "FAKE_TWO"]; rotatedCredentials["headers"] = ["Authorization": "FAKE_TWO"]
        try publish(["safe": rotatedCredentials])
        check(registry.resolve(credentialConsent) != nil, "K2 credential env and header value rotation retains key consent")
        try publish(["safe": safe]); try registry.bringIn([candidate("safe")])
        guard let folder = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileWriteNoPermission) }
        let artifacts = URL(fileURLWithPath: folder)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let page = PluginsPage(entries: [], environment: [], skillsDirectoryCatalog: .init(rootURL: artifacts), skilletRepositoryStore: .init(rootURL: artifacts), onRegister: { _, _, _, _ in }, onRemove: { _ in })
        let packageUpdates = await registry.checkUpdates(fetcher: { _ in Data(#"{"version":"2.0.0"}"#.utf8) })
        try registry.update(imported.id, to: packageUpdates[imported.id]!, confirmed: true)
        var changed = safe; changed["args"] = ["fixture@1.0.0", "--mode", "two"]
        try publish(["safe": changed])
        let staleCard = PluginsSource.osMCPEntries(environment: env)[0], beforeRenewal = try Data(contentsOf: registry.url)
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }; theme.use(.aurora)
        let notice = IslandNotice.shared, oldHost = notice.hostAvailable
        notice.hostAvailable = true; defer { notice.hostAvailable = oldHost }
        func waitFor(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<100 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return condition()
        }
        let renewView = page.mcpAcceptanceView(scan: nil, imported: [staleCard], updates: [:]).padding(24).frame(width: 1000)
        guard let renewShot = GlobalDMChatAcceptance.renderSync(renewView, size: CGSize(width: 1000, height: 500), scheme: .light) else { throw CocoaError(.fileWriteUnknown) }
        defer { renewShot.close() }
        func pressRenewal() -> Bool { GlobalDMChatAcceptance.tree(renewShot)["mcp-reimport-" + staleCard.id].map { ($0 as AnyObject).accessibilityPerformPress?() == true } ?? false }
        check(pressRenewal(), "K3 rendered card renewal chip can be pressed")
        check(await waitFor { notice.current?.title == "重新帶入 MCP？" }, "K3 renewal asks for confirmation")
        check(try notice.current?.detail.contains("npx fixture@2.0.0 --mode two") == true && Data(contentsOf: registry.url) == beforeRenewal, "K3 preview includes retained OS version override without renewing consent")
        if let request = notice.current { notice.resolve(.cancel, id: request.id) }
        try? await Task.sleep(for: .milliseconds(60))
        check(try Data(contentsOf: registry.url) == beforeRenewal && registry.resolve(try registry.load()[0]) == nil, "K3 cancel leaves old consent withheld")
        check(pressRenewal(), "K3 renewal chip retries after cancel")
        _ = await waitFor { notice.current != nil }
        if let request = notice.current { notice.resolve(.allow, id: request.id) }
        check(await waitFor { registry.resolve((try? registry.load().first) ?? imported) != nil }, "K3 confirmation renews consent")
        let renewed = try registry.load()
        check(renewed.count == 1 && renewed[0].id == imported.id && renewed[0].name == imported.name && registry.resolve(renewed[0])?["args"] as? [String] == ["fixture@2.0.0", "--mode", "two"] && !registry.available().items.contains { $0.id == imported.id }, "K3 renewal updates same card and stays out of index")
        let tomlSource = registry.paths.codexHome.appendingPathComponent("config.toml")
        let toml = """
        [mcp_servers.tools]
        command = 'fixture'
        args = []
        enabled_tools = [
          'read', 'write'
        ]
        disabled_tools = ['write']
        [mcp_servers.remote]
        url = 'https://fixture.invalid/mcp'
        env_http_headers = { Authorization = 'HEADER_ENV' }
        [mcp_servers.remote.env_http_headers]
        X-Test = 'SECOND_ENV'
        """
        try fm.createDirectory(at: tomlSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(toml.utf8).write(to: tomlSource)
        let tomlItems = registry.scan().items.filter { $0.source == tomlSource.path }
        try registry.bringIn(tomlItems)
        let tools = try registry.load().first { $0.sourceName == "tools" }!, remote = try registry.load().first { $0.sourceName == "remote" }!
        check(registry.resolve(tools)?["enabled_tools"] as? [String] == ["read", "write"] && registry.resolve(tools)?["disabled_tools"] as? [String] == ["write"], "K4 TOML tool allow and deny lists retained")
        check(registry.resolve(remote)?["env_http_headers"] as? [String: String] == ["Authorization": "HEADER_ENV", "X-Test": "SECOND_ENV"], "K4 inline and table env_http_headers retained")
        let payload = PluginsSource.sidecarMCPConfig(engine: .codex, stored: [tools.name, remote.name], environment: env)!
        let objects = (try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any])["servers"] as! [String: [String: Any]]
        check(objects[tools.name]?["disabled_tools"] as? [String] == ["write"] && objects[remote.name]?["env_http_headers"] as? [String: String] == ["Authorization": "HEADER_ENV", "X-Test": "SECOND_ENV"], "K4 OS sidecar receives source tool restrictions and headers")
        let proof = Process(), pipe = Pipe()
        proof.executableURL = URL(fileURLWithPath: "/usr/bin/env"); proof.arguments = ["node", "tests/w242-mcp.test.mjs", "--engine-proof"]
        proof.environment = env; proof.standardOutput = pipe; proof.standardError = pipe
        try proof.run(); let evidence = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); proof.waitUntilExit()
        check(proof.terminationStatus == 0 && evidence.contains("W242 ENGINE PASS"), "K1/K4 actual Codex fake MCP proof passes")
        if proof.terminationStatus != 0 { print(evidence) }
        let legacy: [[String: Any]] = [["source": source.path, "sourceName": "safe", "name": imported.name, "group": "claude", "command": "npx", "envKeys": [], "args": ["LEGACY_FAKE_ARGUMENT"], "url": urls[0], "consent": ["command": "npx", "url": urls[0], "envKeys": [], "headerKeys": []]]]
        let oldData = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        try oldData.write(to: registry.url)
        let migrated = try registry.load()
        let cleaned = try String(contentsOf: registry.url, encoding: .utf8)
        let backups = try fm.contentsOfDirectory(at: registry.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("os-mcp.json.bak-") }
        check(!cleaned.contains("LEGACY_FAKE_ARGUMENT") && !cleaned.contains("https://") && !cleaned.contains("args") && !cleaned.contains("url") && !cleaned.contains("command") && !cleaned.contains("envKeys"), "K5 first read removes all execution plaintext from legacy JSON")
        check(try backups.count == 1 && Data(contentsOf: backups[0]) == oldData, "K5 original legacy file backed up byte-for-byte before rewrite")
        check(migrated.count == 1 && migrated[0].consent == nil && registry.resolve(migrated[0]) == nil, "K5 old consent does not silently authorize current source")
        let legacyCard = PluginsSource.osMCPEntries(environment: env)[0]
        check(legacyCard.liveness.detail == "請重新帶入" && legacyCard.trigger == "這版改了同意方式", "K3/K5 legacy card requests renewal and explains consent upgrade")
        _ = try registry.load()
        check(try fm.contentsOfDirectory(at: registry.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("os-mcp.json.bak-") }.count == 1, "K5 clean reread does not create another backup")
        try registry.bringIn([candidate("safe")])
        check(registry.resolve(try registry.load()[0]) != nil, "K3/K5 explicit legacy renewal enables current source")
        let initialNames = registry.composerNames, generation = registry.composerCacheGeneration
        for _ in 0..<200 { _ = OSMCPRegistry(environment: env).composerNames }
        check(registry.composerCacheGeneration == generation && initialNames.contains(imported.name), "K6 recreated registry redraw queries reuse cached names without rereading")
        try publish(["safe": safe]);
        check(await waitFor { !registry.composerNames.contains(imported.name) }, "K6 source file timestamp refresh withholds changed consent")
        let beforeCacheRenewal = registry.composerCacheGeneration
        try registry.bringIn([candidate("safe")])
        check(registry.composerNames.contains(imported.name) && registry.composerCacheGeneration > beforeCacheRenewal, "K6 renewal immediately invalidates cached names")
        try publish(["safe": safe, "second": safe])
        try registry.bringIn([candidate("second")])
        let second = try registry.load().first { $0.sourceName == "second" }!
        check(registry.composerNames.contains(second.name), "K6 import immediately invalidates cache")
        try registry.remove(second.id)
        check(!registry.composerNames.contains(second.name), "K6 removal immediately invalidates cache")
        let alternateRoot = registry.root.appendingPathComponent("alternate")
        var alternateEnv = env; alternateEnv["TATWO2_LIVE_ROOT"] = alternateRoot.path
        check(!OSMCPRegistry(environment: alternateEnv).composerNames.contains(imported.name), "K6 cache never crosses isolated environments")
        let stableGeneration = registry.composerCacheGeneration
        try? await Task.sleep(for: .milliseconds(350))
        check(registry.composerCacheGeneration == stableGeneration, "K6 unchanged file timestamps do not rebuild cache")
        var screenshotChanged = safe; screenshotChanged["args"] = ["fixture@1.0.0", "--mode", "three"]
        try publish(["safe": screenshotChanged])
        try publish(["safe": screenshotChanged, "網址金鑰": ["url": urls[2]]])
        let cards = PluginsSource.osMCPEntries(environment: env), index = registry.available()
        for phase in ["index", "cards"] { for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let content = page.mcpAcceptanceView(scan: phase == "index" ? index : nil, imported: phase == "cards" ? cards : [], updates: [:]).padding(24).frame(width: 1000, alignment: .leading)
                .background(dark ? Color(red: 0.08, green: 0.09, blue: 0.12) : Color(red: 0.95, green: 0.95, blue: 0.97)).environment(\.colorScheme, scheme)
            guard let shot = GlobalDMChatAcceptance.renderSync(content, size: CGSize(width: 1000, height: 650), scheme: scheme), let png = shot.bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            defer { shot.close() }
            check(!dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap), "K3 screenshot \(phase) \(scheme) readable")
            try png.write(to: artifacts.appendingPathComponent("w242-\(phase)-\(dark ? "dark" : "light").png"))
        } }

        print("W242MCP SUMMARY checks=\(passed + failed) failures=\(failed)")
        return failed == 0
    }
}
#endif
