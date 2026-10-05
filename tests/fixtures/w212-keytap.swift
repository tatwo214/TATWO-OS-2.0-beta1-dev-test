import AppKit
import ApplicationServices

// Only value fixtures and a replacement transport; no real discovery or event posting.
enum DisplayDimmingMethod: Sendable { case softwareDimmer, unavailable }
struct ControlledDisplay: Sendable {
    let id: CGDirectDisplayID
    var isBuiltIn = false
    var isAppleNative = false
    var dimmingMethod = DisplayDimmingMethod.softwareDimmer
    var volume: Double? = 25
}
enum DisplayAudioRoute {
    static func currentTarget(displays: [ControlledDisplay]) -> CGDirectDisplayID? { 1 }
}
@MainActor final class DisplayControlService {
    struct Settings { var keyboardEnabled = true }
    var settings = Settings()
    var displays = [ControlledDisplay(id: 1)]
    var hasDeviceControlPermission = true
    var isRefreshing = false
    var adjustments = 0
    var adjustedOnMain = false
    func brightness(of id: CGDirectDisplayID) -> Double? { 50 }
    func volume(of id: CGDirectDisplayID) -> Double? { 25 }
    func setBrightness(_ value: Double, for id: CGDirectDisplayID, smooth: Bool) async {
        adjustments += 1
        adjustedOnMain = Thread.isMainThread
    }
    func setVolume(_ value: Double, for id: CGDirectDisplayID, smooth: Bool) async {
        adjustments += 1
        adjustedOnMain = Thread.isMainThread
    }
}
final class Receipt: @unchecked Sendable {
    let lock = NSLock()
    private var stored: (Bool, Double)?
    func record(_ handled: Bool, _ elapsed: Double) {
        lock.lock(); defer { lock.unlock() }
        stored = (handled, elapsed)
    }
    var value: (Bool, Double)? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
@main struct Probe {
    @MainActor static func logTest() async -> Bool {
        var failures = 0
        func check(_ success: Bool, _ name: String) {
            print("W212LOG \(success ? "PASS" : "FAIL") \(name)")
            if !success { failures += 1 }
        }
        let service = DisplayControlService()
        let tap = DisplayKeyTap(service: service)
        let initial = DisplayKeyTap.Snapshot(displays: service.displays, enabled: true, trusted: true, audioDisplay: 1)
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tatwo2/logs/display-keys.log")
        func rows() -> [String] {
            ((try? String(contentsOf: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        var cases: [(String, DisplayKeyTap.Snapshot, CGDirectDisplayID?, Int)] = []
        var value = initial
        value.enabled = false; cases.append(("keyboard_off", value, 1, 2))
        value = initial; value.trusted = false; cases.append(("no_permission", value, 1, 2))
        value = initial; value.refreshing = true; cases.append(("refreshing", value, 1, 2))
        cases.append(("mouse_display_unknown", initial, nil, 2))
        value = initial; value.displays[0].dimmingMethod = .unavailable
        cases.append(("display_not_controllable", value, 1, 2))
        value = initial; value.displays[0].isAppleNative = true
        cases.append(("display_apple_native", value, 1, 2))
        value = initial; value.audioDisplay = 2; cases.append(("volume_not_routed", value, 1, 0))
        for (reason, snapshot, mouse, key) in cases {
            tap.update(snapshot)
            check(!tap.process(subtype: 8, data1: key << 16 | 0x0a << 8, mouseDisplay: mouse),
                  "\(reason) passes event")
        }
        for _ in 0..<100 where rows().count < cases.count { try? await Task.sleep(nanoseconds: 10_000_000) }
        let first = rows()
        check(first.count == cases.count, "one row per supported media event")
        for (reason, _, mouse, key) in cases {
            let expected = "key=\(DisplayKeyTap.Key(rawValue: key)!) result=pass reason=\(reason) display=\(mouse ?? 0)"
            check(first.filter { $0.hasSuffix(expected) }.count == 1, "\(reason) writes matching reason and target")
        }
        let formatter = ISO8601DateFormatter()
        check(!first.isEmpty && first.allSatisfy {
            let fields = $0.split(separator: " ")
            return fields.count == 5 && formatter.date(from: String(fields[0])) != nil
        }, "rows contain timestamp and only four diagnostic fields")
        tap.update(initial)
        let countBeforeUnknown = rows().count
        check(!tap.process(subtype: 8, data1: 99 << 16 | 0x0a << 8, mouseDisplay: 1),
              "unrelated media key passes")
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(rows().count == countBeforeUnknown, "unrelated media key writes no row")
        for (subtype, data) in [(Int16(0), 2 << 16 | 0x0a << 8), (Int16(8), 2 << 16 | 0x0c << 8)] {
            check(!tap.process(subtype: subtype, data1: data, mouseDisplay: 1), "undecodable event passes")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(rows().count == countBeforeUnknown, "undecodable events write no row")
        let reader = try! FileHandle(forReadingFrom: path)
        defer { try? reader.close() }
        for key in [DisplayKeyTap.Key.brightnessUp, .brightnessDown, .volumeUp, .volumeDown, .mute] {
            check(tap.process(subtype: 8, data1: key.rawValue << 16 | 0x0a << 8, mouseDisplay: 1),
                  "\(key) handled")
        }
        for _ in 0..<100 where rows().count < cases.count + 5 { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(rows().suffix(5).allSatisfy { $0.contains("result=handled reason=- display=1") } &&
              rows().count == cases.count + 5, "handled events write matching rows")
        check(String(data: try! reader.readToEnd()!, encoding: .utf8)?.split(separator: "\n").count == cases.count + 5,
              "normal append preserves open file identity")
        for id in UInt32(10)...UInt32(246) {
            var rolling = initial
            rolling.displays = [ControlledDisplay(id: id)]
            tap.update(rolling)
            _ = tap.process(subtype: 8, data1: 2 << 16 | 0x0a << 8, mouseDisplay: id)
        }
        for _ in 0..<500 where rows().last?.hasSuffix("display=246") != true {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check(rows().count == 249, "between periodic checks appends without rewriting")
        var final = initial; final.displays = [ControlledDisplay(id: 247)]
        tap.update(final)
        _ = tap.process(subtype: 8, data1: 2 << 16 | 0x0a << 8, mouseDisplay: 247)
        for _ in 0..<500 where rows().count != 200 || rows().last?.hasSuffix("display=247") != true {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let retained = rows()
        check(retained.count == 200, "log retains exactly last 200 rows")
        check(retained.first?.hasSuffix("display=48") == true && retained.last?.hasSuffix("display=247") == true,
              "log discards oldest rows and preserves event order")
        print("W212LOG SUMMARY failures=\(failures)")
        return failures == 0
    }
    @MainActor static func singleLogTest() async -> Bool {
        let id = UInt32(ProcessInfo.processInfo.environment["W227_DISPLAY_ID"]!)!
        let service = DisplayControlService()
        let tap = DisplayKeyTap(service: service)
        _ = tap.process(subtype: 8, data1: 2 << 16 | 0x0a << 8, mouseDisplay: id)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tatwo2/logs/display-keys.log")
        for _ in 0..<500 {
            let rows = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n")
            if rows.last?.hasSuffix("display=\(id)") == true {
                print("W227 PASS first event flushed on background queue")
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
    @MainActor static func run() async -> Bool {
        var failures = 0
        func check(_ success: Bool, _ name: String) {
            print("W212 \(success ? "PASS" : "FAIL") \(name)")
            if !success { failures += 1 }
        }
        for key in [DisplayKeyTap.Key.brightnessUp, .brightnessDown, .volumeUp, .volumeDown, .mute] {
            let service = DisplayControlService()
            let tap = DisplayKeyTap(service: service)
            tap.update(.init(displays: service.displays, enabled: true, trusted: true, audioDisplay: 1))
            let receipt = Receipt()
            let ready = DispatchSemaphore(value: 0)
            let worker = Task.detached {
                ready.signal()
                let began = ProcessInfo.processInfo.systemUptime
                let handled = await tap.process(subtype: 8, data1: (key.rawValue << 16) | (0x0a << 8), mouseDisplay: 1)
                receipt.record(handled, ProcessInfo.processInfo.systemUptime - began)
            }
            ready.wait()
            blockMain()
            check(receipt.value.map { $0.0 && $0.1 < 0.2 } == true,
                  "\(key) intercepts while main blocked for two seconds")
            check(service.adjustments == 0, "\(key) adjustment waits for main")
            await worker.value
            try? await Task.sleep(nanoseconds: 100_000_000)
            check(service.adjustments == 1 && service.adjustedOnMain,
                  "\(key) adjusts once on main after unblock")
            let released = tap.process(subtype: 8, data1: (key.rawValue << 16) | (0x0b << 8), mouseDisplay: nil)
            check(released, "\(key) swallows paired release outside display")
            check(!tap.process(subtype: 8, data1: (key.rawValue << 16) | (0x0b << 8), mouseDisplay: 1),
                  "\(key) passes unmatched release")
        }
        let service = DisplayControlService()
        let tap = DisplayKeyTap(service: service)
        var snapshot = DisplayKeyTap.Snapshot(displays: service.displays, enabled: true, trusted: true, audioDisplay: 1)
        snapshot.refreshing = true
        tap.update(snapshot)
        check(!tap.process(subtype: 8, data1: 2 << 16 | 0x0a << 8, mouseDisplay: 1),
              "published refreshing snapshot passes immediately")
        snapshot.refreshing = false
        snapshot.enabled = false
        tap.update(snapshot)
        check(!tap.process(subtype: 8, data1: 2 << 16 | 0x0a << 8, mouseDisplay: 1),
              "published disabled snapshot passes immediately")
        snapshot.enabled = true
        tap.update(snapshot)
        check(tap.process(subtype: 8, data1: 7 << 16 | 0x0a << 8, mouseDisplay: 1) &&
              tap.process(subtype: 8, data1: 7 << 16 | 0x0a << 8 | 1, mouseDisplay: 1),
              "mute repeat is swallowed")
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(service.adjustments == 1, "mute repeat does not adjust twice")
        print("W212 SUMMARY failures=\(failures)")
        return failures == 0
    }
    static func blockMain() { Thread.sleep(forTimeInterval: 2) }
    static func main() {
        Task { @MainActor in
            let mode = ProcessInfo.processInfo.environment["W212_LOG_TEST"]
            let success = mode == "2" ? await singleLogTest() : mode == "1" ? await logTest() : await run()
            exit(success ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}
