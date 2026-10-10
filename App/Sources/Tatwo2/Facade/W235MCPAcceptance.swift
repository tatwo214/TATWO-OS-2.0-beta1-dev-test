#if DEBUG
import Foundation
import SwiftUI
import AppKit

enum W235MCPAcceptance {
    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else { throw CocoaError(.fileReadNoPermission) }
        let registry = OSMCPRegistry(environment: env), home = registry.paths.userHome
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) { print("W235MCP \(value ? "PASS" : "FAIL") \(label)"); if value { passed += 1 } else { failed += 1 } }
        func write(_ text: String, _ file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func writeJSON(_ object: [String: Any], _ file: URL) throws {
            try write(String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self), file)
        }
        func definition(_ command: String, _ args: [String]) -> [String: Any] { ["command": command, "args": args] }
        let codex = registry.paths.codexHome.appendingPathComponent("config.toml")
        let toml = #"""
        [mcp_servers.shared]
        command = 'npx'
        args = ['-y', 'shared-pkg@1.0.0']
        [mcp_servers.shared.env]
        TOKEN = 'W235_FAKE_ENV_OLD'
        [mcp_servers.inline]
        command = 'npx'
        args = ['@scope/pkg@1.0.0']
        env={ OTHER = 'W235_FAKE_INLINE_SECRET', PATH = '/fake/bin' }
        [mcp_servers.computer-use]
        command = 'computer_use_fixture'
        args = []
        [mcp_servers.tatwo2_os]
        command = '/missing/tatwo-fixture'
        args = []
        """#
        try write(toml, codex)
        let claude = home.appendingPathComponent(".claude.json"), project = home.appendingPathComponent("projects/fixture")
        let claudeObject: [String: Any] = ["mcpServers": [
            "shared": definition("npx", ["-y", "shared-pkg@1.0.0"]),
            "uvLatest": definition("uvx", ["uv-fixture==2.0.0"]),
            "remote": ["url": "https://fixture.invalid/mcp", "headers": ["Authorization": "W235_FAKE_HEADER_SECRET"]]
        ], "projects": [project.path: ["mcpServers": ["projectOnly": definition("/missing/project-fixture", [])]]]]
        try writeJSON(claudeObject, claude)
        try writeJSON(["mcpServers": ["settingsOnly": definition("/missing/settings-fixture", [])]], home.appendingPathComponent(".claude/settings.json"))
        let desktop = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        try writeJSON(["mcpServers": ["desktop": definition("npx", ["-y", "@scope/unpinned"])]], desktop)
        let generic = project.appendingPathComponent(".mcp.json")
        try writeJSON(["mcpServers": ["generic": definition("npx", ["not-found-pkg@1.0.0"])]], generic)
        try writeJSON(["mcpServers": ["gbrain_allai": definition("npx", ["brain-fixture@1.0.0"]), "github_fixture": definition("/missing/github-fixture", [])]], home.appendingPathComponent(".cursor/mcp.json"))
        try writeJSON(["servers": ["pipx": definition("pipx", ["run", "--spec", "pip-fixture==1.0.0", "pip-app"])]], home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"))
        let broken = home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        try write("{broken", broken)
        try writeJSON(["projects": [["name": "fixture", "workdir": project.path]]], registry.root.appendingPathComponent("document.json"))
        let sources = [codex, claude, desktop, generic, home.appendingPathComponent(".claude/settings.json"), home.appendingPathComponent(".cursor/mcp.json"), home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"), broken]
        let originals = try sources.map { try Data(contentsOf: $0) }
        check(!fm.fileExists(atPath: registry.url.path), "no OS list before explicit import")
        let scan = registry.scan()
        check(Set(scan.items.filter { $0.group == .codex }.map(\.sourceName)) == ["shared", "inline", "computer-use", "tatwo2_os"], "Codex classification")
        check(Set(scan.items.filter { $0.group == .claude }.map(\.sourceName)) == ["shared", "uvLatest", "remote", "projectOnly", "settingsOnly", "desktop"], "Claude Code global and project, settings and Desktop")
        check(Set(scan.items.filter { $0.group == .general }.map(\.sourceName)) == ["generic", "gbrain_allai", "github_fixture", "pipx"], "known Coder project, Cursor and VS Code classified general")
        check(scan.items.filter { $0.sourceName == "shared" }.count == 2, "same MCP listed for both families")
        check(scan.problems[.general] == ["讀不懂：" + broken.path], "unreadable file reported in its group")
        let danger = scan.items.first { $0.sourceName == "computer-use" }!
        check(danger.dangerous && danger.warning == "可能大量開程式，曾拖垮 8 GB 的 Mac", "danger warning and unchecked default")
        let escaped = URL(fileURLWithPath: env["TATWO_STAGING_ROOT"]!).appendingPathComponent("outside-home")
        try writeJSON(["mcpServers": ["escaped": definition("/missing/escaped", [])]], escaped.appendingPathComponent(".mcp.json"))
        let link = home.appendingPathComponent("linked-project")
        try fm.createSymbolicLink(at: link, withDestinationURL: escaped)
        try writeJSON(["projects": [["workdir": project.path], ["workdir": link.path]]], registry.root.appendingPathComponent("document.json"))
        check(!registry.scan().items.contains { $0.sourceName == "escaped" }, "isolated discovery rejects symlink out of selected home")
        try screenshots(scan: scan, imported: [], updates: [:], phase: "index", env: env)
        try registry.bringIn(scan.items.filter { !$0.dangerous })
        var imported = try registry.load()
        check(imported.count == scan.items.count - 1 && registry.available().items.map(\.id) == [danger.id], "imported omitted from next index")
        check(PluginsSource.osMCPEntries(environment: env).count == imported.count, "imported cards visible")
        check(imported.filter { ["gbrain_allai", "github_fixture", "tatwo2_os"].contains($0.sourceName) }.allSatisfy { $0.name != $0.sourceName }, "built-in names renamed with source suffix")
        check(Set(imported.map(\.name)).count == imported.count, "duplicate names remain distinct")
        let osText = try String(contentsOf: registry.url, encoding: .utf8)
        check(!["W235_FAKE_ENV_OLD", "W235_FAKE_INLINE_SECRET", "W235_FAKE_HEADER_SECRET"].contains { osText.contains($0) } && imported.first { $0.sourceName == "shared" && $0.group == .codex }?.envKeys == ["TOKEN"], "OS JSON stores env keys without env or header secret values")
        func sidecar(_ engine: PluginsSource.MCPEngine, _ items: [OSMCPRegistry.Item]) -> [String: [String: Any]] {
            let text = PluginsSource.sidecarMCPConfig(engine: engine, stored: items.map(\.name), environment: env) ?? "{}"
            return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["servers"] as? [String: [String: Any]] ?? [:]
        }
        for engine in [PluginsSource.MCPEngine.codex, .claude] {
            let servers = sidecar(engine, imported)
            check(imported.allSatisfy { servers[$0.name] != nil }, "\(engine.rawValue) sidecar receives every selected imported MCP")
            let codexItem = imported.first { $0.sourceName == "shared" && $0.group == .codex }!
            check((servers[codexItem.name]?["env"] as? [String: String])?["TOKEN"] == "W235_FAKE_ENV_OLD", "\(engine.rawValue) resolves TOML secret at launch")
            let inline = imported.first { $0.sourceName == "inline" }!
            check((servers[inline.name]?["env"] as? [String: String])?["OTHER"] == "W235_FAKE_INLINE_SECRET", "\(engine.rawValue) resolves inline env")
            let remote = imported.first { $0.sourceName == "remote" }!
            check((servers[remote.name]?["headers"] as? [String: String])?["Authorization"] == "W235_FAKE_HEADER_SECRET", "\(engine.rawValue) resolves remote headers without persisting them")
            let deselected = PluginsSource.sidecarMCPConfig(engine: engine, stored: ["__tatwo_none__"], environment: env) ?? ""
            check(!deselected.contains("W235_FAKE_ENV_OLD"), "\(engine.rawValue) deselection does not forward imported secrets")
        }
        try write(toml.replacingOccurrences(of: "W235_FAKE_ENV_OLD", with: "W235_FAKE_ENV_NEW"), codex)
        let codexItem = imported.first { $0.sourceName == "shared" && $0.group == .codex }!
        let freshOS = try String(contentsOf: registry.url, encoding: .utf8)
        check((registry.resolve(codexItem)?["env"] as? [String: String])?["TOKEN"] == "W235_FAKE_ENV_NEW" && !freshOS.contains("W235_FAKE_ENV_NEW"), "launch reads current secret value without rewriting OS JSON")
        try originals[0].write(to: codex)
        let desktopItem = imported.first { $0.sourceName == "desktop" }!
        let missingCopy = desktop.appendingPathExtension("fixture-moved")
        try fm.moveItem(at: desktop, to: missingCopy)
        check(PluginsSource.osMCPEntries(environment: env).first { $0.name == desktopItem.name }?.liveness.detail == "來源不見了", "missing source marked on card")
        for engine in [PluginsSource.MCPEngine.codex, .claude] { check(sidecar(engine, imported)[desktopItem.name] == nil, "\(engine.rawValue) omits missing source") }
        try fm.moveItem(at: missingCopy, to: desktop)
        var withoutItem = claudeObject; var global = withoutItem["mcpServers"] as! [String: Any]; global.removeValue(forKey: "shared"); withoutItem["mcpServers"] = global
        try writeJSON(withoutItem, claude)
        let claudeItem = imported.first { $0.sourceName == "shared" && $0.group == .claude }!
        check(registry.resolve(claudeItem) == nil && sidecar(.codex, imported)[claudeItem.name] == nil && sidecar(.claude, imported)[claudeItem.name] == nil, "deleted source entry omitted by both engines")
        try originals[1].write(to: claude)
        let fetcher = W235Fetcher()
        let updates = await registry.checkUpdates(fetcher: { try await fetcher.fetch($0) })
        check(Set(updates.values.map { String(describing: $0.state) }) == ["newer", "latest", "unpinned", "local", "missing"], "fake fetcher covers all five update outcomes")
        check(updates[codexItem.id]?.label == "有更新 1.0.0 → 2.0.0", "pinned npm version check")
        let pipx = imported.first { $0.sourceName == "pipx" }!, scoped = imported.first { $0.sourceName == "inline" }!
        check(updates[pipx.id]?.newArgs == ["run", "--spec", "pip-fixture==2.0.0", "pip-app"], "pipx updates spec and retains app argument")
        check(updates[scoped.id]?.newArgs == ["@scope/pkg@2.0.0"], "scoped npm version parsed")
        let calls = await fetcher.urls
        check(calls.contains { $0.path == "/@scope/pkg/latest" } && calls.contains { $0.path == "/pypi/uv-fixture/json" } && !calls.contains { $0.path.contains("unpinned") }, "correct registries queried, unpinned skipped")
        try screenshots(scan: nil, imported: PluginsSource.osMCPEntries(environment: env).filter { entry in
            ["shared", "uvLatest", "desktop", "projectOnly", "generic"].contains { entry.name.hasPrefix($0) } && entry.name != claudeItem.name
        }, updates: updates, phase: "updates", env: env)
        let beforeUpdate = try Data(contentsOf: registry.url), update = updates[codexItem.id]!
        try registry.update(codexItem.id, to: update, confirmed: false)
        check(try Data(contentsOf: registry.url) == beforeUpdate, "update without confirmation leaves OS JSON unchanged")
        try registry.update(codexItem.id, to: update, confirmed: true)
        check(try registry.load().first { $0.id == codexItem.id }?.args == ["-y", "shared-pkg@2.0.0"], "confirmed update changes only OS args")
        for engine in [PluginsSource.MCPEngine.codex, .claude] { check(sidecar(engine, imported)[codexItem.name]?["args"] as? [String] == ["-y", "shared-pkg@2.0.0"], "\(engine.rawValue) launches updated OS args") }
        check(try sources.enumerated().allSatisfy { try Data(contentsOf: $0.element) == originals[$0.offset] }, "all source files remain byte-identical after import and update")
        try registry.remove(codexItem.id)
        let afterRemoval = try registry.load()
        check(!afterRemoval.contains { $0.id == codexItem.id } && registry.available().items.contains { $0.id == codexItem.id }, "remove OS reference restores index entry")
        try registry.bringIn([danger])
        imported = try registry.load()
        check(imported.contains { $0.id == danger.id }, "dangerous item can be explicitly selected")
        let cleanList = try Data(contentsOf: registry.url)
        try write("{broken", registry.url)
        do { try registry.bringIn([codexItem]); check(false, "corrupt OS list protected") } catch { check(try String(contentsOf: registry.url, encoding: .utf8) == "{broken", "corrupt OS list protected from overwrite") }
        try cleanList.write(to: registry.url)
        print("W235MCP SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }

    @MainActor private static func screenshots(scan: OSMCPRegistry.Scan?, imported: [PluginRegistryEntry], updates: [String: OSMCPRegistry.Update], phase: String, env: [String: String]) throws {
        guard let folder = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileWriteNoPermission) }
        let root = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = PluginsPage(entries: [], environment: [], skillsDirectoryCatalog: .init(rootURL: root), skilletRepositoryStore: .init(rootURL: root), onRegister: { _, _, _, _ in }, onRemove: { _ in })
        let scope = TatwoThemeSelfTestScope(); defer { scope.restore() }
        scope.use(.aurora)
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let content = page.mcpAcceptanceView(scan: scan, imported: imported, updates: updates).padding(24).frame(width: 1000, alignment: .leading).background(dark ? Color(red: 0.08, green: 0.09, blue: 0.12) : Color(red: 0.95, green: 0.95, blue: 0.97)).environment(\.colorScheme, scheme)
            guard let shot = GlobalDMChatAcceptance.renderSync(content, size: CGSize(width: 1000, height: phase == "index" ? 1300 : 1200), scheme: scheme) else { throw CocoaError(.fileWriteUnknown) }
            defer { shot.close() }
            guard !dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap),
                  let data = shot.bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: root.appendingPathComponent("w235-\(phase)-\(dark ? "dark" : "light").png"))
            print("W235MCP PASS screenshot \(phase) \(dark ? "dark" : "light") \(shot.bitmap.pixelsWide)x\(shot.bitmap.pixelsHigh)")
        }
    }
}
private actor W235Fetcher {
    var urls: [URL] = []
    func fetch(_ url: URL) throws -> Data {
        urls.append(url)
        if url.path.contains("not-found") { throw URLError(.cannotFindHost) }
        return Data((url.host == "registry.npmjs.org" ? #"{"version":"2.0.0"}"# : #"{"info":{"version":"2.0.0"}}"#).utf8)
    }
}
#endif
