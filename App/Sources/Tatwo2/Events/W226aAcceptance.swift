#if DEBUG
import Foundation
import AppKit

@MainActor enum W226aAcceptance {
    static func run() async throws -> Bool {
        guard NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment), NativeStagingIsolation.validationError(ProcessInfo.processInfo.environment) == nil else { throw CocoaError(.fileReadNoPermission) }
        var failures = 0
        func check(_ ok: Bool, _ label: String) { if !ok { failures += 1 }; print("W226a \(ok ? "PASS" : "FAIL") \(label)") }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!).appendingPathComponent("fix-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try DeviceIdentityStore.forLocalDevice().read()
        var now = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let clock = OSClock(now: { now }, arm: { _, _ in })
        let done = DispatchSemaphore(value: 0)
        clock.when(source: "outside-lock", condition: "go") {
            DispatchQueue.global().async { clock.cancel("none"); done.signal() }
            check(done.wait(timeout: .now() + 0.2) == .success, "10 action executes outside clock lock")
        }
        clock.signal("go")
        let project = UUID(), log = OSEventLog(root: root, clock: clock)
        log.append(project: project, actor: "系統", kind: "fixture", at: now)
        try log.flush()
        let file = log.file(project: project, at: now)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken".utf8)); try handle.close()
        now = OSClock.nextMonth(after: now)
        _ = try log.query(project: project, from: .distantPast, through: .distantFuture)
        now = OSClock.nextMonth(after: now)
        _ = try log.query(project: project, from: .distantPast, through: .distantFuture)
        try log.flush()
        check(try log.query(project: project, from: .distantPast, through: .distantFuture).filter { $0.kind == "log_recovery" }.count == 1, "11 recovery across three months recorded once")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try log.query(project: project, from: .distantPast, through: .distantFuture)[0])) as! [String: Any]
        check(obj["device"] as? String == identity.deviceID.lowercased(), "8 device identity present on events")
        let brokenRoot = root.appendingPathComponent("readonly"), readonly = OSEventLog(root: brokenRoot, clock: clock)
        let brokenFile = readonly.file(project: project, at: now)
        try FileManager.default.createDirectory(at: brokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken\n".utf8).write(to: brokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: brokenFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: brokenFile.path) }
        do { _ = try readonly.query(project: project, from: .distantPast, through: .distantFuture); check(true, "11 recovery write failure leaves query usable") }
        catch { check(false, "11 recovery write failure leaves query usable") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try await W226aSourcesAcceptance.run(root: root.appendingPathComponent("sources"), check: check)
        print("W226a SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
