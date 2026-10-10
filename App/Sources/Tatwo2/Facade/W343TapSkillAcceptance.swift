#if DEBUG
import Foundation

/// W343：ChatGPT（TAP）的 Coder 回合帶上輸入框點名的 $技能 說明（有上限、先遮蔽、沒點名不附）。
@MainActor enum W343TapSkillAcceptance {
    static func run() async throws -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("w343-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func skill(_ id: String, _ body: String) throws -> PluginRegistryEntry {
            let dir = root.appendingPathComponent("skills/\(id)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
            return PluginRegistryEntry(id: id, name: id, kind: .skill, purpose: "", path: dir.path, trigger: "", safetyLevel: .medium,
                                       installState: .unknown, smokeCommand: nil, publicInstallHint: "")
        }
        let big = try skill("fixture-big", "# 大技能\n照這個做。\n" + String(repeating: "長", count: 9000))
        let secret = try skill("fixture-secret", "# 小技能\n金鑰 " + ["gh", "p_"].joined() + String(repeating: "A", count: 30) + " 不能送出去。\napi_key = fixturelower123\n密碼: fixturepassword123\n")
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")),
                                    environment: ProcessInfo.processInfo.environment, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let fifoDir = root.appendingPathComponent("skills/fixture-fifo")
        try fm.createDirectory(at: fifoDir, withIntermediateDirectories: true)
        _ = mkfifo(fifoDir.appendingPathComponent("SKILL.md").path, 0o600)
        let fifo = PluginRegistryEntry(id: fifoDir.lastPathComponent, name: fifoDir.lastPathComponent, kind: .skill, purpose: "", path: fifoDir.path, trigger: "",
                                       safetyLevel: .medium, installState: .unknown, smokeCommand: nil, publicInstallHint: "")
        engine.composerSkills = { [big, secret, fifo] }
        var failures = 0, passed = 0
        func check(_ ok: Bool, _ name: String) { if ok { passed += 1; print("W343 PASS \(name)") } else { failures += 1; print("W343 FAIL \(name)") } }
        let both = engine.tapSkillText("$fixture-big $fixture-secret 請照做")
        check(both.contains("〔技能 fixture-big〕") && both.contains("照這個做") && both.contains("〔技能 fixture-secret〕"), "named-skills-attached")
        let bigText = engine.tapSkillText("$fixture-big").components(separatedBy: "〔技能 fixture-big〕\n").last ?? ""
        check(bigText.utf8.count <= 12_288 && !bigText.contains("\u{FFFD}"), "each-skill-bounded-12KB")
        check(!both.contains(["gh", "p_AAAA"].joined()) && both.contains("已遮蔽"), "skill-secrets-redacted")
        check(!both.contains("fixturelower123") && !both.contains("fixturepassword123"), "lowercase-api-key-and-chinese-password-lines-redacted")
        let boundary = try skill("fixture-boundary", String(repeating: "x", count: 12_260) + "\napi_key = " + String(repeating: "a", count: 1000) + "\n")
        engine.composerSkills = { [big, secret, fifo, boundary] }
        check(!engine.tapSkillText("$fixture-boundary").contains("api_key ="), "redact-complete-line-before-12KB-clip")
        check(engine.tapSkillText("沒有技能").isEmpty && engine.tapSkillText("$fixture-none").isEmpty, "no-named-skill-no-text")
        let started = Date()
        check(engine.tapSkillText("$fixture-fifo").isEmpty && Date().timeIntervalSince(started) < 2, "special-file-skill-skipped-without-blocking")
        let linked = root.appendingPathComponent("linked-skills")
        try fm.createSymbolicLink(at: linked, withDestinationURL: root.appendingPathComponent("skills"))
        check(PluginsSource.skillFolders(linked)?.contains { $0.lastPathComponent == "fixture-big" } == true, "symlinked-skills-root-listed")
        print("W343 SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
}
#endif
