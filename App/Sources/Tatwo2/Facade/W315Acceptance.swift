#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W315Acceptance {
    static func run(check: (Bool, String) -> Void) async throws {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default
        guard NativeStagingIsolation.validationError(env) == nil, NativeStagingIsolation.isEnabled(env),
              let artifact = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let root = URL(fileURLWithPath: artifact).appendingPathComponent("w315")
        let runtime = root.appendingPathComponent("runtime/bin"), calls = root.appendingPathComponent("calls.txt")
        let claude = root.appendingPathComponent("claude-sidecar/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude")
        func binary(_ url: URL, _ version: String, beforeVersion: String = "") throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = "#!/bin/sh\necho \"$*|$DISABLE_AUTOUPDATER\" >> '\(calls.path)'\n[ \"$1\" = --version ] && [ \"$DISABLE_AUTOUPDATER\" = 1 ] || exit 9\n\(beforeVersion)\necho \(version)\n"
            try Data(script.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let priorRuntime = env["TATWO2_RUNTIME_BIN"], priorResources = env["TATWO2_RESOURCES_ROOT"]
        setenv("TATWO2_RUNTIME_BIN", runtime.path, 1); setenv("TATWO2_RESOURCES_ROOT", root.path, 1)
        defer {
            if let priorRuntime { setenv("TATWO2_RUNTIME_BIN", priorRuntime, 1) } else { unsetenv("TATWO2_RUNTIME_BIN") }
            if let priorResources { setenv("TATWO2_RESOURCES_ROOT", priorResources, 1) } else { unsetenv("TATWO2_RESOURCES_ROOT") }
        }
        try binary(runtime.appendingPathComponent("codex"), "0.161.0")
        try binary(claude, "2.1.294")
        var modelEnv = env; modelEnv["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "settings"
        let page = ChatPageModel(environment: modelEnv), tap = ChatGPTTap(transport: FakeTapPod(running: true), connection: .needsLogin)
        defer { tap.sleep() }
        for scenario in ["newer", "older", "uncached-true", "uncached-false"] {
            let suite = "w315." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let saved = scenario != "uncached-false", cached = !scenario.hasPrefix("uncached")
            defaults.set(saved, forKey: "ai.available"); defaults.set(12345, forKey: "ai.lastCheck")
            if cached { defaults.set("0.161.0", forKey: "ai.newest.codex"); defaults.set("2.1.293", forKey: "ai.newest.claude") }
            try binary(claude, scenario == "older" ? "2.1.292" : "2.1.294")
            let update = EngineAIUpdate(defaults: defaults)
            update.rows["claude"] = "舊列不能沿用"
            func open() async throws -> GlobalDMChatAcceptance.Rendered {
                let shot = GlobalDMChatAcceptance.renderSync(EngineLoginCard(model: page, chatGPT: tap, aiUpdate: update), size: CGSize(width: 1040, height: 760), scheme: .light)!
                for _ in 0..<100 {
                    if update.rows["grok"] != nil && update.rows["claude"] != "舊列不能沿用" { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                await W214Acceptance.settle(shot)
                return shot
            }
            let shot = try await open(), expected = scenario == "older" || (!cached && saved)
            let visible = W214Acceptance.text(shot)
            let dot = W214Acceptance.node("login.aiUpdate.dot", shot) != nil
            check(update.hasNewVersion == expected && defaults.bool(forKey: "ai.available") == expected && dot == expected,
                  "W315 " + scenario + " page dot and persisted availability")
            check(update.rows["claude"] == (cached ? EngineAIUpdate.versionLine(scenario == "older" ? "2.1.292" : "2.1.294", "2.1.293") : "2.1.294") &&
                  (cached ? visible.contains(expected ? "可更新" : "已是最新") : visible.contains("2.1.294") && !visible.contains("查不到最新版本")), "W315 " + scenario + " page versionLine")
            check(defaults.double(forKey: "ai.lastCheck") == 12345, "W315 " + scenario + " local refresh preserves network cadence")
            try W214Acceptance.save(shot, scenario, root); shot.close()
            if scenario == "older" {
                try binary(claude, "2.1.294")
                update.rows["claude"] = "舊列不能沿用"; update.rows["grok"] = nil
                let reopened = try await open()
                check(!update.hasNewVersion && !defaults.bool(forKey: "ai.available") && W214Acceptance.node("login.aiUpdate.dot", reopened) == nil && update.rows["claude"] == "2.1.294。已是最新", "W315 reopen observes external CLI update")
                reopened.close()
            }
            if scenario == "older" { try binary(claude, "2.1.292") }
            update.rows["claude"] = "舊列不能沿用"; update.rows["grok"] = nil
            let cancelShot = try await open(), openingRows = update.rows
            update.source = { _ in ("0.0.1", "9.0.0", nil) }
            check(TatwoComposerModeAcceptance.press("login.aiUpdate", in: cancelShot), "W317 " + scenario + " update button")
            for _ in 0..<100 { if update.selecting { break }; try await Task.sleep(for: .milliseconds(20)) }
            await W214Acceptance.settle(cancelShot)
            check(update.rows != openingRows && TatwoComposerModeAcceptance.press("login.aiUpdate.cancel", in: cancelShot), "W317 " + scenario + " cancel button")
            await W214Acceptance.settle(cancelShot)
            check(!update.selecting && update.rows == openingRows && (!cached || openingRows["claude"]?.contains(scenario == "older" ? "可更新" : "已是最新") == true) && openingRows.values.allSatisfy { W214Acceptance.text(cancelShot).contains($0) }, "W317 " + scenario + " cancel restores opening text")
            try W214Acceptance.save(cancelShot, scenario + "-cancel", root); cancelShot.close()
        }
        let suite = "w315.background." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let update = EngineAIUpdate(defaults: defaults), day = Date(timeIntervalSince1970: 1_000_000)
        var reads = 0
        let source: EngineAIUpdate.Source = { kind in reads += 1; return ("1.0.0", kind == .grok ? nil : "2.0.0", nil) }
        await update.backgroundCheck(source: source, now: day)
        check(defaults.string(forKey: "ai.newest.codex") == "2.0.0" && defaults.string(forKey: "ai.newest.claude") == "2.0.0" && defaults.object(forKey: "ai.newest.grok") == nil, "W315 background stores each known newest")
        await update.backgroundCheck(source: source, now: day.addingTimeInterval(3600))
        check(reads == 3, "W315 daily network gate unchanged")
        await update.backgroundCheck(source: { _ in (nil, nil, nil) }, now: day.addingTimeInterval(86400))
        check(defaults.string(forKey: "ai.newest.claude") == "2.0.0", "W315 failed lookup retains newest cache")
        let started = root.appendingPathComponent("probe-started"), released = root.appendingPathComponent("probe-released")
        try binary(runtime.appendingPathComponent("codex"), "0.161.0", beforeVersion: "touch '\(started.path)'; while [ ! -e '\(released.path)' ]; do sleep 0.05; done")
        let local = Task { await update.refreshLocalVersions() }, readsBefore = reads
        for _ in 0..<100 { if fm.fileExists(atPath: started.path) { break }; try await Task.sleep(for: .milliseconds(10)) }
        await update.backgroundCheck(source: source, now: day.addingTimeInterval(172800))
        check(fm.fileExists(atPath: started.path) && reads == readsBefore && defaults.double(forKey: "ai.lastCheck") == day.addingTimeInterval(86400).timeIntervalSince1970, "W315 local probe and background check cannot race")
        try Data().write(to: released); await local.value
        await update.backgroundCheck(source: source, now: day.addingTimeInterval(172800))
        check(reads == readsBefore + 3, "W315 background check resumes after local probe")
        let cachedCalls = try String(contentsOf: calls, encoding: .utf8)
        await update.refreshLocalVersions()
        check((try? String(contentsOf: calls, encoding: .utf8)) == cachedCalls, "W350 cached settings refresh never reprobes CLI")
        for _ in 0..<2 { await update.refreshLocalVersions(forceVerification: true) }
        check((try? String(contentsOf: calls, encoding: .utf8)) != cachedCalls, "W350 explicit recheck bypasses verification cache")
        let commands = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        check(commands.count >= 10 && commands.allSatisfy { $0 == "--version|1" }, "W315 fake CLI only reads local version with auto updater disabled")
    }
}
#endif
