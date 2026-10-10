#if DEBUG
import Foundation
import AppKit
import SwiftUI

@MainActor enum W244ProposalAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let staging = env["TATWO_STAGING_ROOT"] else { throw TapError.notReady }
        let work = URL(fileURLWithPath: staging).appendingPathComponent("w244-work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "before\n".write(to: work.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        _ = try await Task.detached { try HandsGit.checked(["init", "-q"], cwd: work.path) }.value
        let patch = "diff --git a/hello.txt b/hello.txt\n--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-before\n+after\n"
        var failures = 0
        func check(_ ok: Bool, _ label: String) { print("W244 \(ok ? "PASS" : "FAIL") \(label)"); if !ok { failures += 1 } }
        check(try await W239ProposalAcceptance.run(), "A1–A4 TAP boundaries, deletion and external data cannot become user markers")
        check(try await W232Acceptance.run(), "A8 TAP rows sharing turnID cannot impersonate primary replies")
        check(try await W243UXAcceptance.run(), "A8 event read snapshots and legacy decoding; A10 empty-query Enter and prefix selection")
        let oldRows = [ChatMessage(id: "u1", role: .user, text: "第一輪", turnID: "t1"), ChatMessage(id: "tap1", role: .assistant, text: "TAP", turnID: "group-read:2"),
            ChatMessage(id: "work1", role: .system, text: "記憶", status: "done|記憶", turnID: "t1"),
            ChatMessage(id: "u2", role: .user, text: "第二輪", turnID: "t2"), ChatMessage(id: "tap2", role: .assistant, text: "TAP", turnID: "group-read:2")]
        let projection = CoderTurnProjection(oldRows.map { .message($0) }, messages: oldRows)
        check(projection.owners["t1"] == "tap1" && projection.owners["t2"] == "tap2" && projection.owners["group-read:2"] == nil, "A8 identical legacy read counts do not merge turns or create standalone turns")
        let engine = ChatLiveEngine(store: ChatLiveStore(root: work.appendingPathComponent("cache-live")), environment: env, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: work)))
        await model.reloadPluginRegistry()?.value
        let registry = OSMCPRegistry(environment: env), names = registry.composerNames, generation = registry.composerCacheGeneration
        let skill = registry.paths.codexHome.appendingPathComponent("skills/tatwo-ultrawork/SKILL.md"), archived = work.appendingPathComponent("cached-skill.md")
        try FileManager.default.moveItem(at: skill, to: archived)
        let cachedTurn = engine.composerTurnText("@TATWO OS $ultrawork", engine: .claude)
        check(cachedTurn.contains("使用者指定這回合用技能：ultrawork") && cachedTurn.contains("使用者指定這回合用 MCP：TATWO OS"), "A9 sends from existing skill and MCP caches when skill file is absent")
        check(names == registry.composerNames && registry.composerCacheGeneration == generation, "A9 send reuses MCP cache generation")
        await model.reloadPluginRegistry()?.value
        check(!engine.composerTurnText("$ultrawork", engine: .claude).contains("使用者指定這回合用技能"), "A9 background refresh updates skill cache")
        try FileManager.default.moveItem(at: archived, to: skill)
        for code in Array(0x202A...0x202E) + Array(0x2066...0x2069) + Array(0x200B...0x200F) + [0x061C, 0x2060, 0x2064, 0x180E, 0xFEFF] {
            let character = String(UnicodeScalar(code)!)
            for diff in [patch.replacingOccurrences(of: "+after", with: "+after" + character), patch.replacingOccurrences(of: "hello.txt", with: "hello" + character + ".txt"), character + patch] {
                let reason = await Task.detached { () -> String in
                    do { _ = try ChangeProposalStore.check(diff, cwd: work.path); return "accepted" }
                    catch { return String(describing: error) }
                }.value
                check(reason == "hidden_characters：補丁含看不見的格式字元（例如雙向標記、零寬字元、BOM），畫面看到的可能跟實際不同，請改用一般文字", "A5 reject U+\(String(code, radix: 16)) in body/path/header")
            }
        }
        for mode in ["error", "fix"] {
            try "before\n".write(to: work.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
            let spaced = patch.replacingOccurrences(of: "+after\n", with: "+after  \n")
            let result = try await Task.detached { () -> (Int32, [ChangeProposalStore.File], String) in
                _ = try HandsGit.checked(["config", "apply.whitespace", mode], cwd: work.path)
                let configured = try HandsGit.run(["apply", "--check", "-"], cwd: work.path, stdin: Data(spaced.utf8))
                let files = try ChangeProposalStore.check(spaced, cwd: work.path)
                let store = ChangeProposalStore(root: work.appendingPathComponent("store-" + mode)), thread = UUID()
                try store.save(.init(title: "空白", summary: "", projectID: UUID(), cwd: work.path, files: files, digest: HandsAuth.sha256Hex(Data(spaced.utf8))), patch: spaced, thread: thread, sequence: 1)
                try store.apply(thread, 1)
                return (configured.status, files, try String(contentsOf: work.appendingPathComponent("hello.txt"), encoding: .utf8))
            }.value
            check(mode != "error" || result.0 != 0, "A7 fixture whitespace error would reject a plain --check")
            check(result.1 == [.init(path: "hello.txt", added: 1, deleted: 1)] && result.2 == "after  \n", "A7 check/numstat/apply use nowarn under \(mode)")
        }
        let proposal = ChangeProposalStore.Proposal(title: "受保護的改動", summary: "檢查拒絕原因", projectID: UUID(), cwd: work.path,
            files: [.init(path: ".env", added: 1, deleted: 1)], digest: "")
        let scope = TatwoThemeSelfTestScope(); defer { scope.restore() }; scope.use(.aurora)
        let artifacts = URL(fileURLWithPath: env["TATWO2_SELFTEST_ARTIFACTS"]!)
        for scheme in [ColorScheme.light, .dark] {
            for (raw, expected, name) in [("protected_path：不准改保護檔或金鑰檔", "不准改保護檔或金鑰檔", "blocked"), ("symlink_refused", "提案處理失敗，請稍後再試。", "generic"), ("unknown: English only", "提案處理失敗，請稍後再試。", "english")] {
                let card = ChangeProposalCard(proposal: proposal, event: .init(sequence: 1, turn: 1, speaker: "ChatGPT", text: "", kind: "proposal"), primary: "Codex",
                    viewPatch: { throw HandsToolError.invalid(raw) }, review: { false }, apply: {}, reject: {})
                guard let shot = GlobalDMChatAcceptance.renderSync(card.padding(24), size: CGSize(width: 820, height: 380), scheme: scheme) else { throw TapError.notReady }
                guard let button = GlobalDMChatAcceptance.tree(shot)["proposal-diff"] else { throw TapError.notReady }
                check((button as AnyObject).accessibilityPerformPress?() == true, "A6 diff failure triggered \(name) \(scheme)")
                try await W241PetsAcceptance.until { GlobalDMChatAcceptance.tree(shot)["proposal-error"] != nil }
                let text = W214Acceptance.text(shot)
                check(text.contains(expected) && !text.contains(raw.split(whereSeparator: { $0 == "：" || $0 == ":" }).first.map(String.init) ?? raw), "A6 card shows short Chinese reason \(name) \(scheme)")
                shot.host.layoutSubtreeIfNeeded(); shot.window.displayIfNeeded()
                shot.host.cacheDisplay(in: shot.host.bounds, to: shot.bitmap)
                if name == "blocked" { GlobalDMChatAcceptance.save(shot, "w244-blocked-\(scheme == .dark ? "dark" : "light").png", to: artifacts) }
                check(scheme != .dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap), "A6 readable \(name) \(scheme)")
                shot.close()
            }
        }
        print("W244 SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
