#if DEBUG
import Foundation
import AppKit

@MainActor enum W226Acceptance {
    static func run() async throws -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ label: String) { if !ok { failures += 1 }; print("W226 \(ok ? "PASS" : "FAIL") \(label)") }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!).appendingPathComponent("events-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var now = Date(timeIntervalSince1970: 1_796_083_200) // 2026-12-01 UTC
        var armed: Date?, fire: (() -> Void)?
        let clock = OSClock(now: { now }, arm: { date, callback in armed = date; fire = callback })
        now.addTimeInterval(600)
        check(clock.wakeups == 0 && armed == nil, "idle fake clock ten minutes: zero wakeups")
        var order: [String] = []
        let due = now.addingTimeInterval(30)
        clock.schedule(source: "z", at: due) { order.append("z") }
        clock.schedule(source: "a", at: due) { order.append("a") }
        check(armed == due, "sleeps until nearest deadline")
        now = due; fire?()
        check(order == ["a", "z"] && clock.wakeups == 1, "simultaneous deadlines sorted by source; zero deadline error")
        clock.when(source: "condition", condition: "done") { order.append("condition") }
        clock.signal("done"); clock.signal("done")
        check(order.filter { $0 == "condition" }.count == 1, "condition triggers once without polling")
        var repeats = 0
        clock.schedule(source: "repeat", at: now.addingTimeInterval(1), next: { $0.addingTimeInterval(2) }) { repeats += 1 }
        now.addTimeInterval(1); fire?(); now.addTimeInterval(2); fire?()
        check(repeats == 2, "repeating timed jobs")
        clock.cancel("repeat")
        clock.when(source: "repeated-condition", condition: "again", repeating: true) { repeats += 1 }
        clock.signal("again"); clock.signal("again")
        check(repeats == 4, "repeating conditions require explicit signals")
        let log = OSEventLog(root: root, clock: clock)
        let project = UUID(), thread = UUID()
        let date = now
        log.append(project: project, thread: thread, actor: "你", kind: "user_send", at: date, purpose: "user-1", size: 123)
        try log.flush()
        let url = log.file(project: project, at: date)
        let original = try Data(contentsOf: url)
        let fake = "sk" + "-proj-" + String(repeating: "A1b2", count: 12)
        log.append(project: project, thread: thread, actor: "系統", kind: "tool_step", at: date,
                   used: ["@fixture"], note: String(repeating: "前", count: 115) + fake + "\n尾")
        for _ in 0..<9998 { log.append(project: project, thread: thread, actor: "codex/gpt-6.1-sol", kind: "turn_end", at: date, result: "通過", size: 50) }
        try log.flush()
        let data = try Data(contentsOf: url)
        check(data.prefix(original.count) == original && data.split(separator: 10).count == 10000, "ten thousand appends preserve existing bytes")
        check(data.count <= 5_000_000, "monthly file under five MB")
        let start = ContinuousClock.now
        let rows = try log.query(project: project, from: date.addingTimeInterval(-1), through: date.addingTimeInterval(1))
        let ms = Double(start.duration(to: .now).components.attoseconds) / 1e15
        check(rows.count == 10000 && ms <= 200, "month query under 200 ms")
        check(rows[0].v == 1 && rows[0].purpose == "user-1" && rows[0].thread == thread.uuidString.lowercased() && rows[0].size == 123, "system schema and purpose")
        check(rows[1].note?.contains("已遮蔽") == true && rows[1].note!.count <= 120 && !String(decoding: data, as: UTF8.self).contains(fake), "redact whole secret before truncating at boundary")
        check(try log.query(project: project, from: date, through: date, kinds: ["tool_step"]).count == 1, "inclusive date and kind filters")
        let copy = root.appendingPathComponent("portable")
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("events"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url.deletingLastPathComponent(), to: copy.appendingPathComponent("events/" + project.uuidString.lowercased()))
        let moved = OSEventLog(root: copy)
        check(try moved.query(project: project, from: date.addingTimeInterval(-1), through: date.addingTimeInterval(1)) == rows, "project folder portable into empty LIVE")
        let broken = try FileHandle(forWritingTo: url); try broken.seekToEnd(); try broken.write(contentsOf: Data("{\"broken\":".utf8)); try broken.close()
        check(try log.query(project: project, from: date.addingTimeInterval(-1), through: date.addingTimeInterval(1)).count == 10000, "truncated final line skipped")
        try log.flush()
        let reopened = OSEventLog(root: root)
        let recovered = try reopened.query(project: project, from: .distantPast, through: .distantFuture)
        check(recovered.filter { $0.kind == "log_recovery" }.count == 1, "damaged line recorded once, including after reopening")
        check(recovered.first { $0.kind == "log_recovery" }?.at == OSEventLog.stamp(now) && recovered.first { $0.kind == "log_recovery" }?.purpose == nil, "recovery records actual diagnostic time without invented human purpose")
        let presence = OSPresence(now: { now }, active: { true }, foreground: { _, _ in true })
        presence.select(thread, project: project, log: log)
        presence.record(); now.addTimeInterval(59); presence.record()
        now.addTimeInterval(1); presence.record()
        presence.select(UUID(), project: project, log: log)
        presence.select(thread, project: project, log: log)
        try log.flush()
        check(try log.query(project: project, from: date, through: now, kinds: ["presence"]).count == 3, "same thread sixty-second throttle; switching thread records new presence")
        let inactive = OSPresence(now: { now }, active: { false }, foreground: { _, _ in true })
        inactive.select(thread, project: project, log: log); inactive.record()
        try log.flush()
        check(try log.query(project: project, from: date, through: now, kinds: ["presence"]).count == 3, "background App never records presence")
        log.append(project: nil, actor: "系統", kind: "fixture", at: now)
        try log.flush()
        check(try log.query(project: nil, from: date, through: now).first?.project == "一般", "unassigned thread stored under general project")
        let line = OSTimeLine.describe(rows: Array(rows.prefix(3)), participant: "你")
        check(line.nowIndex == 3 && line.lastIndex == 1 && line.between == 1 && line.elapsed == 0 && line.text.contains("第3筆"), "shared time line indices and elapsed time")
        check(log.openFileCount > 0, "writer caches active monthly file")
        now = OSClock.nextMonth(after: now); fire?(); try log.flush()
        check(log.openFileCount == 0, "scheduler closes monthly files at UTC boundary")
        log.append(project: project, actor: "系統", kind: "next_month", at: now); try log.flush()
        check(log.file(project: project, at: now) != url && FileManager.default.fileExists(atPath: log.file(project: project, at: now).path), "month rollover via scheduler")
        try await W226SourcesAcceptance.run(check)
        print("W226 METRICS bytes=\(data.count) query_ms=\(ms)")
        print("W226 SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
