#if DEBUG
import Foundation
import SwiftUI
import AppKit

enum W245MCPAcceptance {
    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else { throw CocoaError(.fileReadNoPermission) }
        let registry = OSMCPRegistry(environment: env), source = registry.paths.userHome.appendingPathComponent(".claude.json")
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) { print("W245MCP \(value ? "PASS" : "FAIL") \(label)"); if value { passed += 1 } else { failed += 1 } }
        func publish(_ servers: [String: Any]) throws {
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys]).write(to: source)
        }
        func candidate(_ name: String) -> OSMCPRegistry.Item { registry.scan().items.first { $0.source == source.path && $0.sourceName == name }! }
        let safe: [String: Any] = ["command": "fixture", "args": []]
        let invisibleCodes = [0x3164, 0x115F, 0x1160, 0xFFA0, 0xFE00, 0xFE0F, 0xE0100, 0xE01EF,
                              0x00AD, 0x034F, 0x061C, 0x17B4, 0x180B, 0x180E, 0x200B, 0x200C, 0x200D,
                              0x200E, 0x2028, 0x2029, 0x202E, 0x2060, 0x2064, 0xFEFF, 0x00A0, 0x2007, 0x202F, 0x2800, 0x3000]
        let mapFolder = registry.root.appendingPathComponent("w259-map")
        try fm.createDirectory(at: mapFolder, withIntermediateDirectories: true)
        let mapFile = TapProjectMapStore.mapFile(at: mapFolder)
        try fm.createDirectory(at: mapFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        func mapName(_ name: String) throws -> String? {
            try JSONEncoder().encode(TapProjectMap(chatgpt_project_id: "g-p-fixture", name: name)).write(to: mapFile)
            return TapProjectMapStore.displayMap(at: mapFolder)?.name
        }
        for code in invisibleCodes {
            let ch = String(UnicodeScalar(code)!), text = "中文" + ch + "說明"
            check(OSAgentBridge.hasInvisibleCharacters(text), "W259 T2 shared rejects U+\(String(code, radix: 16))")
            for singleLine in [true, false] {
                check(OSAgentBridge.approvalTextProblem("echo " + text, singleLine: singleLine) == "command_has_invisible_characters", "W259 T2 approval rejects U+\(String(code, radix: 16)) singleLine=\(singleLine)")
            }
            check(try mapName("TATWO · " + text) == nil, "W259 T2 TAP display rejects U+\(String(code, radix: 16))")
            try publish([text: safe, "command": ["command": "fixture" + ch], "args": ["command": "fixture", "args": [text]], "helper": ["command": "fixture", "headersHelper": text]])
            let indexed = registry.scan().items.filter { $0.source == source.path }
            check(indexed.count == 4 && indexed.allSatisfy { $0.blocked && $0.warning?.contains("看不見的字元") == true }, "W259 T2 MCP name command args helper reject U+\(String(code, radix: 16))")
            for item in indexed {
                do { try registry.bringIn([item]); check(false, "W259 T2 invisible import refused") }
                catch { check(true, "W259 T2 invisible import refused") }
            }
        }
        // FE0F after a visible non-ASCII emoji changes presentation; after text, digits or another selector it has no justified display role.
        for text in ["中文說明", "一般 空格", "한글", "😀", "☀\u{FE0F}", "❤️", "cafe\u{301}"] {
            check(!OSAgentBridge.hasInvisibleCharacters(text) && OSAgentBridge.approvalTextProblem("echo " + text, singleLine: true) == nil, "W259 T2 ordinary text and emoji accepted \(text)")
            check(try mapName("TATWO · " + text) == "TATWO · " + text, "W259 T2 readable TAP name accepted")
            try publish([text: ["command": "fixture", "args": [text], "headersHelper": "helper " + text]])
            let item = candidate(text)
            check(!item.blocked, "W259 T2 readable MCP card accepted")
            try registry.bringIn([item]); check(registry.resolve(try registry.load().first { $0.id == item.id }!) != nil, "W259 T2 readable MCP resolves")
            try registry.remove(item.id)
        }
        for text in ["\u{FE0F}", "a\u{FE0F}", "1\u{FE0F}", "☀\u{FE0F}\u{FE0F}", "☀\u{FE0E}", "☀\u{E0100}", "☀\n\u{FE0F}"] {
            check(OSAgentBridge.hasInvisibleCharacters(text, allowLineBreaks: true), "W259 T2 unjustified variation selector rejected")
        }
        check(OSAgentBridge.approvalTextProblem("echo 中文\n\techo 😀", singleLine: false) == nil, "W259 T2 multiline newline and tab preserved")
        check(OSAgentBridge.approvalTextProblem("echo 中文\n", singleLine: true) == "cli_send_single_line_without_control_characters", "W259 T2 single-line control error preserved")
        check(OSAgentBridge.approvalTextProblem("echo \u{1B}", singleLine: false) == "command_has_control_characters", "W259 T2 multiline control error preserved")
        check(try mapName("TATWO · a\n") == nil, "W259 T2 TAP control rejection preserved")
        check(OSAgentBridge.approvalTextProblem(String(repeating: "中", count: 2001), singleLine: false) == "command_too_long_for_approval", "W259 T2 approval length limit preserved")
        let fakePAT = ["ghp", "W245_FAKE"].joined(separator: "_")
        let urls = ["https://fixture.invalid/mcp#access_token=W245_FAKE", "https://fixture.invalid/mcp#%61pi_key=W245_FAKE", "https://fixture.invalid/mcp#x=\(fakePAT)", "https://fixture.invalid/mcp#password=W245_FAKE"]
        for url in urls { for remote in [true, false] {
            let definition: [String: Any] = remote ? ["url": url] : ["command": "fixture", "args": ["--url=" + url]]
            try publish(["blocked": definition])
            let item = candidate("blocked")
            check(item.blocked && item.commandLine.contains("••••") && !item.commandLine.contains(url), "B1 fragment masked and disabled remote=\(remote)")
            do { try registry.bringIn([item]); check(false, "B1 fragment import refused") } catch { check(true, "B1 fragment import refused") }
        } }
        try publish(["safe": safe]); try registry.bringIn([candidate("safe")])
        let imported = try registry.load()[0]
        try publish(["safe": ["url": urls[0]]])
        check(registry.resolve(imported) == nil && registry.servers().isEmpty, "B1 imported fragment withheld from engine")
        try publish(["safe": safe])
        let full: [String: Any] = ["command": "/usr/bin/env", "args": ["node", "-e", "console.log(JSON.stringify({pathOK:process.env.PATH===process.env.EXPECTED_PATH,tokenOK:process.env.API_TOKEN===process.env.EXPECTED_TOKEN}))"], "env": ["PATH": env["PATH"] ?? "", "API_TOKEN": "W245_TOKEN_ONE"]]
        try publish(["safe": full]); try registry.bringIn([candidate("safe")])
        let consented = try registry.load()[0]
        func engineChild(_ token: String, started: Bool = true) throws -> Bool {
            let payload = PluginsSource.sidecarMCPConfig(engine: .claude, stored: [consented.name], environment: env)!
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env"); child.arguments = ["node", "tests/w245-mcp.test.mjs", "--consent-proof"]
            child.environment = env.merging(["W245_PAYLOAD": payload, "EXPECTED_PATH": env["PATH"] ?? "", "EXPECTED_TOKEN": token]) { _, value in value }
            child.standardOutput = output; child.standardError = output; try child.run()
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); child.waitUntilExit()
            if child.terminationStatus != 0 { print(result) }
            return child.terminationStatus == 0 && result.contains(started ? "W245 CONSENT PASS child started" : "W245 CONSENT PASS child withheld")
        }
        check(try engineChild("W245_TOKEN_ONE"), "B2 full consent reaches fake MCP child")
        var rotated = full; rotated["env"] = ["PATH": env["PATH"] ?? "", "API_TOKEN": "W245_TOKEN_TWO"]
        try publish(["safe": rotated])
        check(try registry.resolve(consented) != nil && engineChild("W245_TOKEN_TWO"), "B2 TOKEN rotation reaches child without renewed consent")
        var changedPath = rotated; changedPath["env"] = ["PATH": "/fake/w245/path", "API_TOKEN": "W245_TOKEN_TWO"]
        try publish(["safe": changedPath])
        check(try registry.resolve(consented) == nil && engineChild("W245_TOKEN_TWO", started: false), "B2 PATH change withholds child until renewed consent")
        for (field, value) in ["headersHelper": "fixture-helper", "oauth": ["clientId": "fixture"], "env": ["PATH": env["PATH"] ?? "", "API_TOKEN": "W245_TOKEN_TWO", "NODE_OPTIONS": "--no-warnings"]] as [String: Any] {
            var changed = full; changed[field] = value
            try publish(["safe": changed])
            check(registry.resolve(consented) == nil, "B2 whole configuration changed \(field) requires consent")
        }
        let headerConfig: [String: Any] = ["command": "fixture", "headers": ["Authorization": "FAKE_ONE", "X-Mode": "one"]]
        try publish(["safe": headerConfig]); try registry.bringIn([candidate("safe")])
        let headerConsent = try registry.load()[0]
        var headers = headerConfig; headers["headers"] = ["Authorization": "FAKE_TWO", "X-Mode": "one"]
        try publish(["safe": headers]); check(registry.resolve(headerConsent) != nil, "B2 AUTH header rotation retains consent")
        headers["headers"] = ["Authorization": "FAKE_TWO", "X-Mode": "two"]
        try publish(["safe": headers]); check(registry.resolve(headerConsent) == nil, "B2 ordinary header change requires consent")
        let stored = try String(contentsOf: registry.url, encoding: .utf8)
        check(!stored.contains("W245_TOKEN") && !stored.contains(env["PATH"] ?? "IMPOSSIBLE") && !stored.contains("headersHelper"), "B2 registry stores only fingerprint")
        try publish(["safe": safe]); try registry.bringIn([candidate("safe")])
        let proof = Process(), pipe = Pipe()
        proof.executableURL = URL(fileURLWithPath: "/usr/bin/env"); proof.arguments = ["node", "tests/w245-mcp.test.mjs", "--engine-proof"]
        proof.environment = env; proof.standardOutput = pipe; proof.standardError = pipe
        try proof.run(); let evidence = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); proof.waitUntilExit()
        check(proof.terminationStatus == 0 && evidence.contains("W245 ENGINE PASS"), "B1/B2 fake MCP subprocess engine proof")
        if proof.terminationStatus != 0 { print(evidence) }
        func waitFor(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<150 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return condition()
        }
        var slowEnv = env; slowEnv["TATWO2_MCP_TEST_READ_DELAY"] = "0.35"
        let slow = OSMCPRegistry(environment: slowEnv), oldNames = slow.composerNames, generation = slow.composerCacheGeneration
        try publish(["safe": ["command": "fixture", "args": ["changed"]]])
        let start = Date(), cached = slow.composerNames
        check(Date().timeIntervalSince(start) < 0.1 && cached == oldNames && cached.contains(imported.name), "B3 slow source refresh immediately returns old names")
        try? await Task.sleep(for: .milliseconds(100))
        let during = Date()
        let duringNames = (0..<100).map { _ in slow.composerNames }
        check(duringNames.allSatisfy { $0 == oldNames }, "B3 old names available during read")
        check(Date().timeIntervalSince(during) < 0.1, "B3 reader never holds composer lock")
        check(await waitFor { !slow.composerNames.contains(imported.name) }, "B3 background read eventually replaces stale names")
        check(slow.composerCacheGeneration == generation + 1, "B3 repeated requests schedule only one refresh")
        let stable = slow.composerCacheGeneration
        try? await Task.sleep(for: .milliseconds(400))
        check(slow.composerCacheGeneration == stable, "B3 unchanged source does not reload")
        try publish(["safe": safe]); try registry.bringIn([candidate("safe")])
        let legacy: [[String: Any]] = [["source": source.path, "sourceName": "safe", "name": imported.name, "group": "claude", "command": "fixture", "args": ["W245_FAKE_LEGACY"]]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        try legacyData.write(to: registry.url); try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: registry.url.path)
        let migrated = try registry.load()
        let backups = try fm.contentsOfDirectory(at: registry.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("os-mcp.json.bak-") }
        check(try backups.count == 1 && Data(contentsOf: backups[0]) == legacyData, "B4 legacy backup retains original bytes")
        check(try (fm.attributesOfItem(atPath: backups[0].path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "B4 backup permission reads back as 0600")
        check(migrated[0].consent == nil && registry.resolve(migrated[0]) == nil, "B4 migration never authorizes legacy registration")
        try publish(["safe": safe, "second": safe]); try registry.bringIn([candidate("second")])
        try publish(["safe": ["command": "fixture", "args": ["--mode", "first"]], "second": ["command": "fixture", "args": ["--mode", "second"]], "fragment 金鑰": ["url": urls[0]]])
        guard let folder = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileWriteNoPermission) }
        let artifacts = URL(fileURLWithPath: folder)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let page = PluginsPage(entries: [], environment: [], skillsDirectoryCatalog: .init(rootURL: artifacts), skilletRepositoryStore: .init(rootURL: artifacts), onRegister: { _, _, _, _ in }, onRemove: { _ in })
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }; theme.use(.aurora)
        let cards = PluginsSource.osMCPEntries(environment: env), index = registry.available()
        let changedCard = cards.first { $0.id == "os-mcp:" + candidate("second").id }!
        let notices = [changedCard.trigger, changedCard.liveness.detail ?? ""].filter { $0.contains("來源設定變了") }
        check(notices.count == 1 && notices[0].contains("來源設定變了：args"), "W259 T1 one changed-source line retains args")
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            guard let shot = GlobalDMChatAcceptance.renderSync(PluginConnectionCard(entry: changedCard).padding(24), size: CGSize(width: 1000, height: 360), scheme: scheme) else { throw TapError.notReady }
            await W214Acceptance.settle(shot)
            let lines = W214Acceptance.nodes(shot).map(DMBrowserAcceptance.axText).filter { $0.contains("來源設定變了") }
            check(lines.count == 1 && lines[0].contains("來源設定變了：args"), "W259 T1 rendered card has one changed-source line dark=\(dark)")
            GlobalDMChatAcceptance.save(shot, "w259-changed-\(dark ? "dark" : "light").png", to: artifacts)
            shot.close()
        }
        check(cards.count == 2 && cards.allSatisfy { $0.liveness.detail?.contains("請重新帶入") == true }, "B5 all stale imports request renewal")
        check(registry.backupPath?.hasPrefix("…/") == true, "B5 backup path shortened")
        for phase in ["cards", "index"] { for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let content = page.mcpAcceptanceView(scan: phase == "index" ? index : nil, imported: phase == "cards" ? cards : [], updates: [:]).padding(24).frame(width: 1200, alignment: .leading)
                .background(dark ? Color(red: 0.08, green: 0.09, blue: 0.12) : Color(red: 0.95, green: 0.95, blue: 0.97)).environment(\.colorScheme, scheme)
            guard let shot = GlobalDMChatAcceptance.renderSync(content, size: CGSize(width: 1200, height: 650), scheme: scheme), let png = shot.bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            defer { shot.close() }
            check(!dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap), "B5 screenshot \(phase) \(scheme) readable")
            try png.write(to: artifacts.appendingPathComponent("w245-\(phase)-\(dark ? "dark" : "light").png"))
        } }
        let notice = IslandNotice.shared, oldHost = notice.hostAvailable
        notice.hostAvailable = true; defer { notice.hostAvailable = oldHost }
        let view = page.mcpAcceptanceView(scan: nil, imported: cards, updates: [:], interactive: true).padding(24).frame(width: 1200)
        guard let shot = GlobalDMChatAcceptance.renderSync(view, size: CGSize(width: 1200, height: 650), scheme: .light) else { throw CocoaError(.fileWriteUnknown) }
        defer { shot.close() }
        await W214Acceptance.settle(shot)
        check(DMBrowserAcceptance.axCollect(shot.host, ["mcp-reimport-" + changedCard.id])["mcp-reimport-" + changedCard.id] != nil, "W259 T1 changed card retains individual renewal action")
        func batchNodes() -> [String: NSObject] { DMBrowserAcceptance.axCollect(shot.host, ["mcp-reimport-all", "mcp-consent-upgrade"]) }
        func pressAll() -> Bool { batchNodes()["mcp-reimport-all"].map(DMBrowserAcceptance.axPress) ?? false }
        let upgradeText = W214Acceptance.text(shot)
        check(batchNodes()["mcp-consent-upgrade"] != nil && upgradeText.contains("這版改了同意方式，已帶入的 MCP 要重新確認一次才會給引擎用") && !upgradeText.contains("舊登記已備份在"), "B5 upgrade line explains consent without technical backup path")
        // 真正變更的項目只允許逐張確認；批次只納入升級前的同意資料。
        check(cards.first { $0.id == "os-mcp:" + candidate("second").id }?.trigger.contains("來源設定變了：args") == true, "B5 changed source names fields")
        let before = try Data(contentsOf: registry.url)
        check(pressAll(), "B5 rendered batch chip can be pressed")
        check(await waitFor { notice.current != nil }, "B5 batch requests one confirmation")
        check(notice.current?.title == "重新帶入 MCP？" && notice.current?.detail.contains("fixture --mode first") == true && notice.current?.detail.contains("fixture --mode second") == false && notice.current?.detail.contains(urls[0]) == false, "B5 batch confirmation lists legacy execution only")
        check(try Data(contentsOf: registry.url) == before && registry.servers().isEmpty, "B5 preview does not renew consent")
        if let request = notice.current { notice.resolve(.cancel, id: request.id) }
        try? await Task.sleep(for: .milliseconds(80))
        check(try Data(contentsOf: registry.url) == before && registry.servers().isEmpty, "B5 cancel leaves all imports withheld")
        check(pressAll(), "B5 batch can be retried after cancel")
        _ = await waitFor { notice.current != nil }
        if let request = notice.current { notice.resolve(.allow, id: request.id) }
        check(await waitFor { registry.servers().count == 1 }, "B5 batch renews only legacy consent")
        check(await waitFor { batchNodes()["mcp-reimport-all"] == nil && batchNodes()["mcp-consent-upgrade"] == nil && !W214Acceptance.text(shot).contains("這版改了同意方式") }, "B5 upgrade line disappears after all renewals")
        check(notice.current == nil && registry.available().items.allSatisfy { $0.sourceName == "fragment 金鑰" }, "B5 renewal has no second notice and imports stay out of index")
        print("W245MCP SUMMARY checks=\(passed + failed) failures=\(failed)")
        return failed == 0
    }
}
#endif
