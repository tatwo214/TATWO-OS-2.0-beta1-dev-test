#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W252GoalLoopsAcceptance {
    struct Fixture: View {
        let threadID: UUID
        @State private var expanded = true
        var body: some View {
            VStack {
                ThreadGoalCard(threadID: threadID, expanded: $expanded)
                Spacer()
            }.padding(LiquidGlassTokens.islandNoticeColumnSpacing)
        }
    }

    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let live = env["TATWO2_LIVE_ROOT"], let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let out = URL(fileURLWithPath: path), root = URL(fileURLWithPath: live).appendingPathComponent("goals")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let scope = TatwoThemeSelfTestScope(), appearance = NSApplication.shared.appearance
        defer { scope.restore(); NSApplication.shared.appearance = appearance }
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failed += 1 }
            print("W252GOALLOOPS \(ok ? "PASS" : "FAIL") \(label)")
        }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), thread = UUID(), oldThread = UUID()
        func goal(_ id: Int, _ title: String, _ status: ThreadGoal.Status, _ parent: Int? = nil) -> ThreadGoal {
            ThreadGoal(id: id, title: title, status: status, proposed: false, parent: parent, createdAt: now, updatedAt: now)
        }
        var fixture = ThreadGoalList(goals: [goal(1, "目標卡片與 loops", .active), goal(2, "舊資料相容", .done), goal(3, "下一條主線", .pending),
            goal(4, "資料規則", .done, 1), goal(5, "回歸測試", .pending, 1), goal(6, "卡片驗收", .review, 1),
            goal(7, "卡片重排", .active, 1), goal(8, "等待下輪", .paused, 1), goal(9, "舊檔讀回", .done, 2)], nextID: 10)
        fixture.goals[0].userWords = "先主線，點擊展開 loops，點 loop 看細節"
        fixture.goals[6].progress = 0.65; fixture.goals[6].startedAt = now.addingTimeInterval(-300)
        fixture.goals[6].etaAt = now.addingTimeInterval(600); fixture.goals[6].device = "Studio"; fixture.goals[6].branch = "w252/goal-loops"
        fixture.goals[6].doneSteps = ["資料欄位", "引擎工具"]; fixture.goals[6].queue = ["卡片驗收", "回歸測試"]
        fixture.goals[6].evidence = "W170 規則測試通過"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fixture).write(to: root.appendingPathComponent(thread.uuidString.lowercased() + ".json"))
        let old = #"{"nextID":12,"goals":[{"id":10,"title":"舊主線","status":"active","proposed":false,"createdAt":"2026-10-06T00:00:00Z","updatedAt":"2026-10-06T00:00:00Z"},{"id":11,"title":"舊 loop","status":"pending","proposed":false,"parent":10,"createdAt":"2026-10-06T00:00:00Z","updatedAt":"2026-10-06T00:00:00Z"}]}"#
        try Data(old.utf8).write(to: root.appendingPathComponent(oldThread.uuidString.lowercased() + ".json"))
        check(ThreadGoalStore.shared.list(thread) == fixture, "fixture loads from isolated goal file")
        check(ThreadGoalStore.shared.list(oldThread).goals.count == 2, "legacy file loads without new keys")
        let bridge = OSAgentBridge.fleetFixtureBridge(), toolThread = UUID()
        try ThreadGoalStore.shared.update(toolThread) { $0 = fixture }
        func call(_ params: [String: Any], method: String = "goal_update") throws -> [String: Any] {
            var params = params; params["callerThreadID"] = toolThread.uuidString
            return try bridge.callForSelfTest(method: method, params: params)
        }
        let update = try call(["id": 7, "progress": 0.4, "etaMinutes": 5, "queue": ["新步驟"], "doneSteps": ["已做"], "branch": "fixture/loop", "device": "fixture"])
        let updated = ThreadGoalStore.shared.list(toolThread).goals[6]
        check(update["ok"] as? Bool == true && updated.status == .active && updated.progress == 0.4 && updated.queue == ["新步驟"] &&
              updated.doneSteps == ["已做"] && updated.branch == "fixture/loop" && updated.device == "fixture" &&
              abs((updated.etaAt ?? .distantPast).timeIntervalSinceNow - 300) < 3, "engine updates details without status")
        let rows = try call([:], method: "goal_list")["goals"] as? [[String: Any]] ?? []
        check(rows.first { $0["id"] as? Int == 7 }.map { row in
            ["progress", "startedAt", "etaAt", "queue", "doneSteps", "branch", "device"].allSatisfy { row[$0] != nil } &&
            (row["etaAt"] as? String)?.contains(".") == false
        } == true, "goal_list returns all shared fields and ISO8601 dates")
        for params: [String: Any] in [["id": 7], ["id": 7, "progress": true], ["id": 7, "queue": [1]], ["id": 7, "status": "invalid", "progress": 0.2]] {
            do { _ = try call(params); check(false, "invalid engine update rejected") }
            catch { check(ThreadGoalStore.shared.list(toolThread).goals[6] == updated, "invalid engine update rejected without mutation") }
        }
        let done = try call(["id": 7, "status": "done", "progress": 1, "evidence": "fixture verified"])
        check(done["ok"] as? Bool == true && ThreadGoalStore.shared.list(toolThread).goals[6].status == .done, "engine combines status and progress")
        var clock = fixture.goals[6]
        check(ThreadGoalCard.timeLabel(clock, now: now) == "剩 10 分", "remaining minutes")
        clock.etaAt = now.addingTimeInterval(-120)
        check(ThreadGoalCard.timeLabel(clock, now: now) == "超時 2 分", "overdue minutes")
        clock.etaAt = nil
        check(ThreadGoalCard.timeLabel(clock, now: now) == "已跑 5 分", "elapsed fallback")

        func press(_ id: String, _ shot: GlobalDMChatAcceptance.Rendered) async -> Bool {
            guard let node = GlobalDMChatAcceptance.tree(shot)[id], DMBrowserAcceptance.axPress(node) else { return false }
            try? await Task.sleep(for: .milliseconds(250))
            shot.host.layoutSubtreeIfNeeded()
            return true
        }
        func order(_ prefix: String, _ shot: GlobalDMChatAcceptance.Rendered) -> [String] {
            GlobalDMChatAcceptance.tree(shot).filter { $0.key.hasPrefix(prefix) }
                .compactMap { key, node in DMBrowserAcceptance.axFrame(node).map { (key, $0.midY) } }
                .sorted { $0.1 > $1.1 }.map(\.0)
        }
        for theme in [TatwoThemeID.fable5, .aurora] {
            scope.use(theme)
            for requested in [ColorScheme.light, .dark] {
                let name = theme.rawValue + (requested == .dark ? "-dark" : "-light")
                let scheme: ColorScheme = TatwoActivePalette.current.fixedLightAppearance ? .light : requested
                NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                guard let shot = GlobalDMChatAcceptance.renderSync(Fixture(threadID: thread), size: CGSize(width: 640, height: 420), scheme: scheme) else {
                    check(false, name + " renders"); continue
                }
                defer { shot.close() }
                let initial = GlobalDMChatAcceptance.identifiers(in: shot)
                check(initial.filter { $0.hasPrefix("goal.main.") }.count == 3 && !initial.contains { $0.hasPrefix("goal.loop.") }, name + " default only mainlines")
                check(order("goal.main.", shot) == ["goal.main.1", "goal.main.3", "goal.main.2"], name + " mainline status order")
                check(await press("goal.main.1", shot), name + " mainline press")
                check(order("goal.loop.", shot) == ["goal.loop.7", "goal.loop.6", "goal.loop.5", "goal.loop.8", "goal.loop.4"], name + " active review queue paused done order")
                let nodes = GlobalDMChatAcceptance.tree(shot)
                check(nodes["goal.loop.7"].map { DMBrowserAcceptance.axText($0).contains("65%") && DMBrowserAcceptance.axText($0).contains("剩 10 分") } == true, name + " active progress and remaining time")
                check(nodes["goal.loop.4"].map { DMBrowserAcceptance.axText($0).contains("已完成，變暗") } == true, name + " completed row dimmed semantics")
                check(!nodes.keys.contains { $0.hasPrefix("goal.location.") || $0.hasPrefix("goal.steps.") }, name + " loop details initially hidden")
                if let flat = GlobalDMChatAcceptance.captureOwnWindow(shot), let queued = nodes["goal.loop.5"], let completed = nodes["goal.loop.4"] {
                    let queuedInk = inkContrast(flat, queued), completedInk = inkContrast(flat, completed)
                    let width = nodes["goal.loop.7"].map { progressWidth(flat, $0) } ?? 0
                    check(abs(width - 64 * 0.65) < 2, name + " thin progress bar drawn at 65 percent")
                    let ratio = titleContrastRatio(flat, queued)
                    check(ratio >= 4.5, name + " readable appearance")
                    print("W252GOALLOOPS NOTE \(name) progressWidth=\(width) titleContrast=\(ratio)")
                    if scheme == .dark {
                        let background = flat.bitmap.colorAt(x: flat.bitmap.pixelsWide - 5, y: flat.bitmap.pixelsHigh - 5)?.usingColorSpace(.deviceRGB)
                        check(shot.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua &&
                              background.map { max($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.35 } == true, name + " actual dark appearance and canvas")
                    }
                    print("W252GOALLOOPS NOTE \(name) queuedInk=\(queuedInk) completedInk=\(completedInk)")
                    check(queuedInk > 0.1 && completedInk > 0.05 && completedInk < queuedInk * 0.85, name + " completed row visibly dimmer")
                } else { check(false, name + " completed row pixel capture") }
                check(await press("goal.loop.7", shot), name + " loop press")
                let details = GlobalDMChatAcceptance.tree(shot)
                check(details["goal.location.7"].map { DMBrowserAcceptance.axText($0).contains("Studio · w252/goal-loops") } == true &&
                      details["goal.steps.7"].map { DMBrowserAcceptance.axText($0).contains("✓ 資料欄位") && DMBrowserAcceptance.axText($0).contains("○ 卡片驗收") } == true,
                      name + " device branch and completed queued steps")
                if let screenshot = GlobalDMChatAcceptance.captureOwnWindow(shot) {
                    GlobalDMChatAcceptance.save(screenshot, "w252-" + name + ".png", to: out)
                    check(theme != .fable5 || shot.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, name + " paper retains existing light appearance")
                } else { check(false, name + " expanded screenshot") }
                check(await press("goal.main.1", shot) && !GlobalDMChatAcceptance.identifiers(in: shot).contains("goal.loop.7"), name + " mainline collapses")
                check(await press("goal.main.2", shot) && GlobalDMChatAcceptance.identifiers(in: shot).contains("goal.loop.9"), name + " completed mainline expands")
            }
        }
        if let oldShot = GlobalDMChatAcceptance.renderSync(Fixture(threadID: oldThread), size: CGSize(width: 640, height: 240)) {
            defer { oldShot.close() }
            let oldMain = GlobalDMChatAcceptance.identifiers(in: oldShot).contains("goal.main.10")
            let oldPressed = await press("goal.main.10", oldShot)
            check(oldMain && oldPressed, "legacy mainline renders and expands")
            let nodes = GlobalDMChatAcceptance.tree(oldShot)
            check(nodes["goal.loop.11"].map { DMBrowserAcceptance.axText($0).contains("排隊") } == true && !nodes.keys.contains { $0.hasPrefix("goal.progress.") }, "legacy loop renders without new fields")
        } else { check(false, "legacy card renders") }
        print("W252GOALLOOPS SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }

    private static func progressWidth(_ shot: GlobalDMChatAcceptance.Rendered, _ node: NSObject) -> Double {
        guard let screen = DMBrowserAcceptance.axFrame(node),
              let accent = NSColor(LiquidGlassTokens.brandAccent).usingColorSpace(.deviceRGB) else { return 0 }
        let rect = shot.host.convert(shot.window.convertFromScreen(screen), from: nil)
        let scale = Double(shot.bitmap.pixelsWide) / Double(shot.size.width)
        let top = shot.host.isFlipped ? rect.minY : shot.size.height - rect.maxY
        var longest = 0
        for y in Int(top * scale)..<Int((top + rect.height) * scale) {
            var run = 0
            for x in Int(rect.midX * scale)..<Int(rect.maxX * scale) {
                guard x >= 0, y >= 0, x < shot.bitmap.pixelsWide, y < shot.bitmap.pixelsHigh,
                      let c = shot.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(c.redComponent - accent.redComponent) + abs(c.greenComponent - accent.greenComponent) + abs(c.blueComponent - accent.blueComponent) < 0.3 {
                    run += 1; longest = max(longest, run)
                } else { run = 0 }
            }
        }
        return Double(longest) / scale
    }

    /// A compact glass card can occupy most of its window; verify text contrast, not the fraction of dark canvas.
    private static func titleContrastRatio(_ shot: GlobalDMChatAcceptance.Rendered, _ node: NSObject) -> Double {
        guard let screen = DMBrowserAcceptance.axFrame(node) else { return 0 }
        let rect = shot.host.convert(shot.window.convertFromScreen(screen), from: nil)
        let scale = Double(shot.bitmap.pixelsWide) / Double(shot.size.width)
        let top = shot.host.isFlipped ? rect.minY : shot.size.height - rect.maxY
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        var low = 1.0, high = 0.0
        for y in Int(top * scale)..<Int((top + rect.height) * scale) {
            for x in Int((rect.minX + 24) * scale)..<Int((rect.minX + 140) * scale) {
                guard x >= 0, y >= 0, x < shot.bitmap.pixelsWide, y < shot.bitmap.pixelsHigh,
                      let c = shot.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let l = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
                low = min(low, l); high = max(high, l)
            }
        }
        return (high + 0.05) / (low + 0.05)
    }

    /// Compare title ink only; status symbols and the time label have their own semantic colors.
    private static func inkContrast(_ shot: GlobalDMChatAcceptance.Rendered, _ node: NSObject) -> Double {
        guard let screen = DMBrowserAcceptance.axFrame(node) else { return 0 }
        let rect = shot.host.convert(shot.window.convertFromScreen(screen), from: nil)
        let scale = Double(shot.bitmap.pixelsWide) / Double(shot.size.width)
        let top = shot.host.isFlipped ? rect.minY : shot.size.height - rect.maxY
        var low = 1.0, high = 0.0
        for y in Int(top * scale)..<Int((top + rect.height) * scale) {
            for x in Int((rect.minX + 24) * scale)..<Int((rect.minX + 140) * scale) {
                guard x >= 0, y >= 0, x < shot.bitmap.pixelsWide, y < shot.bitmap.pixelsHigh,
                      let c = shot.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                low = min(low, l); high = max(high, l)
            }
        }
        return max(0, high - low)
    }
}
#endif
