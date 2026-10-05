#if DEBUG
import AppKit

@MainActor enum W211Acceptance {
    static func run() async -> Bool {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("W211 \(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let suite = "tatwo.w211.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DisplayControlService(settings: DisplaySettings(defaults: defaults),
            dimmer: W211Dimmer(), observe: false, permissionCheck: { false })
        var display = DisplayAcceptance.fixture(method: .hardwareDDC)
        display.hardwareBrightness = DDCValue(current: 50, maximum: 100)
        display.volume = 25
        display.hardwareVolume = DDCValue(current: 25, maximum: 100)
        let transport = W211Transport()
        let channel = DDCArm64(transport: transport, pause: { _ in })
        service.install(DisplayDiscoveryResult(displays: [display], channels: [display.id: channel], reason: nil))
        let view = DisplaySettingsView(service: service, openSettings: {})
        for value in [35.0, 70, 45] {
            let binding = view.brightnessBinding(for: display)
            binding.wrappedValue = value
            check(binding.wrappedValue == value, "brightness binding immediate readback \(Int(value))")
            let volume = view.volumeBinding(for: display)
            volume.wrappedValue = value
            check(volume.wrappedValue == value, "volume binding immediate readback \(Int(value))")
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(transport.snapshot().filter { $0.0 == .brightness }.map(\.1) == [31]
              && transport.snapshot().filter { $0.0 == .volume }.map(\.1) == [45],
              "synchronous slider burst sends only newest queued brightness and volume")
        check(await W211DDCConcurrencyAcceptance.run(), "DDC suspended transaction acceptance")
        let dragTransport = W211Transport()
        let dragChannel = DDCArm64(transport: dragTransport)
        let dragService = DisplayControlService(settings: DisplaySettings(defaults: defaults),
            dimmer: W211Dimmer(), observe: false, permissionCheck: { false })
        dragService.install(DisplayDiscoveryResult(displays: [display], channels: [display.id: dragChannel], reason: nil))
        let dragView = DisplaySettingsView(service: dragService, openSettings: {})
        let began = ProcessInfo.processInfo.systemUptime
        for value in 0..<20 {
            dragView.brightnessBinding(for: display).wrappedValue = Double(24 + value * 4)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check(ProcessInfo.processInfo.systemUptime - began < 0.16, "drag submits 20 values in about 100ms")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let dragWrites = dragTransport.snapshot()
        print("W211 drag writes=\(dragWrites.count) final=\(dragWrites.last?.1 ?? 0)")
        check(dragWrites.count <= 6, "drag coalesces 20 updates into at most 6 writes")
        check(dragWrites.last?.1 == 100, "drag release always writes final value")
        check(dragWrites.firstIndex(where: { $0.1 == 100 }) == dragWrites.count - 1,
              "drag never writes stale value after final value")
        check(zip(dragWrites, dragWrites.dropFirst()).allSatisfy { $1.2 - $0.2 >= 0.045 },
              "drag writes respect per-panel minimum interval")
        let beforeKeyboard = dragTransport.snapshot().count
        check(await dragService.setBrightness(40, for: display.id, smooth: true), "keyboard-style service adjustment succeeds")
        check(dragTransport.snapshot().count > beforeKeyboard + 1, "keyboard adjustment retains smooth steps")
        let keyboardSuite = "tatwo.w211.keyboard.\(UUID().uuidString)"
        let keyboardDefaults = UserDefaults(suiteName: keyboardSuite)!
        defer { keyboardDefaults.removePersistentDomain(forName: keyboardSuite) }
        let keyboardSettings = DisplaySettings(defaults: keyboardDefaults)
        let notice = IslandNotice.shared
        notice.hostAvailable = false
        defer { notice.hostAvailable = false }
        let keyboardService = DisplayControlService(settings: keyboardSettings, dimmer: W211Dimmer(),
            observe: false, permissionCheck: { false })
        let adjustable = DisplayAcceptance.fixture()
        let keyboardResult = DisplayDiscoveryResult(displays: [adjustable], channels: [:], reason: nil)
        keyboardService.install(keyboardResult)
        keyboardService.updateKeyboardTap()
        check(keyboardDefaults.object(forKey: "tatwo.display.keyboardPermissionNoticeShown") == nil,
              "unavailable Island does not consume the one-time permission notice")
        notice.hostAvailable = true
        keyboardService.updateKeyboardTap()
        check(keyboardSettings.keyboardEnabled, "unconfigured external adjustable display defaults keyboard on")
        check(keyboardDefaults.object(forKey: "tatwo.display.keyboardEnabled") == nil,
              "automatic keyboard default never writes user preference")
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(notice.current?.allowLabel == "打開系統設定",
              "missing default keyboard permission offers Island settings action")
        if let prompt = notice.current { notice.resolve(.cancel, id: prompt.id) }
        keyboardService.updateKeyboardTap()
        keyboardService.install(keyboardResult)
        let restarted = DisplayControlService(settings: DisplaySettings(defaults: keyboardDefaults),
            dimmer: W211Dimmer(), observe: false, permissionCheck: { false })
        restarted.install(keyboardResult)
        restarted.updateKeyboardTap()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(notice.current == nil, "missing keyboard permission is only announced once across restart")
        let actionNotice = IslandNotice(fallback: { _, _, _ in
            check(false, "keyboard permission action never opens fallback windows")
            return nil
        }, holdOpen: { _ in }, log: { _ in })
        actionNotice.hostAvailable = true
        var openedSettings = 0
        DisplayIslandFeedback.requestKeyboardPermission(notice: actionNotice, openSettings: { openedSettings += 1 })
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(actionNotice.current?.detail == "請允許裝置控制權限，才能用鍵盤調整外接螢幕。",
              "keyboard permission notice contains one actionable sentence")
        if let prompt = actionNotice.current { actionNotice.resolve(.allow, id: prompt.id) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(openedSettings == 1, "Island settings action invokes injected opener exactly once")
        keyboardSettings.keyboardEnabled = false
        keyboardService.install(keyboardResult)
        check(!keyboardSettings.keyboardEnabled && keyboardDefaults.object(forKey: "tatwo.display.keyboardEnabled") as? Bool == false,
              "user disabled keyboard remains disabled on rediscovery")
        let disabledRestart = DisplayControlService(settings: DisplaySettings(defaults: keyboardDefaults),
            dimmer: W211Dimmer(), observe: false, permissionCheck: { false })
        disabledRestart.install(keyboardResult)
        check(!disabledRestart.settings.keyboardEnabled, "user disabled keyboard remains disabled after restart")
        for excluded in [
            DisplayAcceptance.fixture(2, builtIn: true),
            DisplayAcceptance.fixture(3, native: true),
            DisplayAcceptance.fixture(4, method: .unavailable)
        ] {
            let excludedSuite = "tatwo.w211.excluded.\(UUID().uuidString)"
            let excludedDefaults = UserDefaults(suiteName: excludedSuite)!
            let excludedService = DisplayControlService(settings: DisplaySettings(defaults: excludedDefaults),
                dimmer: W211Dimmer(), observe: false, permissionCheck: { false })
            excludedService.install(DisplayDiscoveryResult(displays: [excluded], channels: [:], reason: nil))
            check(!excludedService.settings.keyboardEnabled, "non-eligible display \(excluded.id) does not enable keyboard")
            check(excludedDefaults.object(forKey: "tatwo.display.keyboardEnabled") == nil,
                  "non-eligible display \(excluded.id) leaves keyboard preference absent")
            excludedDefaults.removePersistentDomain(forName: excludedSuite)
        }
        check(W211DispatchAcceptance.run(), "entry synchronization negative acceptance")
        print("W211 SUMMARY failures=\(failures)")
        return failures == 0
    }
}

@MainActor private final class W211Dimmer: DisplayShading {
    func setShade(_ shade: Double, on display: CGDirectDisplayID, animated: Bool) -> Bool { true }
    func retainDisplays(_ ids: Set<CGDirectDisplayID>) {}
}

private final class W211Transport: DDCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DDCCommand: DDCValue] = [
        .brightness: DDCValue(current: 50, maximum: 100),
        .volume: DDCValue(current: 25, maximum: 100)
    ]
    private(set) var writes: [(DDCCommand, UInt16, TimeInterval)] = []
    func snapshot() -> [(DDCCommand, UInt16, TimeInterval)] {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
    func read(_ command: DDCCommand) -> DDCValue? {
        lock.lock(); defer { lock.unlock() }
        return values[command]
    }
    func write(_ command: DDCCommand, value: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes.append((command, value, ProcessInfo.processInfo.systemUptime))
        values[command] = DDCValue(current: value, maximum: 100)
        return true
    }
}
#endif
