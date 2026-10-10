#if DEBUG
import AppKit
import Combine

/// All write coverage uses this fixture transport. No IORegistry or IOAV is opened.
private final class FixtureDDCTransport: DDCTransport, @unchecked Sendable {
    private let lock = NSLock()
    var values: [DDCCommand: DDCValue] = [.brightness: DDCValue(current: 50, maximum: 100), .volume: DDCValue(current: 25, maximum: 100)]
    var readFailures = 0
    var writeFailures = 0
    var reads = 0
    var writes: [(DDCCommand, UInt16)] = []
    func read(_ command: DDCCommand) -> DDCValue? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if readFailures > 0 { readFailures -= 1; return nil }
        return values[command]
    }
    func write(_ command: DDCCommand, value: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes.append((command, value))
        if writeFailures > 0 { writeFailures -= 1; return false }
        guard let old = values[command] else { return false }
        values[command] = DDCValue(current: value, maximum: old.maximum)
        return true
    }
}

private final class FixtureClock: @unchecked Sendable {
    var time = 0.0
    var pauses: [Double] = []
    func pause(_ duration: Double) { pauses.append(duration); time += duration }
}

@MainActor private final class FixtureDimmer: DisplayShading {
    var shades: [CGDirectDisplayID: Double] = [:]
    var animations = 0
    var available = true
    @discardableResult func setShade(_ shade: Double, on display: CGDirectDisplayID, animated: Bool) -> Bool {
        guard available else { return false }
        shades[display] = shade
        if animated { animations += 1 }
        return true
    }
    func retainDisplays(_ ids: Set<CGDirectDisplayID>) { shades = shades.filter { ids.contains($0.key) } }
}

@MainActor enum DisplayAcceptance {
    static func fixture(_ id: CGDirectDisplayID = 1, builtIn: Bool = false, native: Bool = false,
                        virtual: Bool = false, method: DisplayDimmingMethod = .softwareDimmer) -> ControlledDisplay {
        ControlledDisplay(id: id, name: "fixture", identity: DisplayIdentity(vendor: 1, model: id, serial: 42),
                          persistenceKey: "fixture-\(id)", isBuiltIn: builtIn, isVirtual: virtual,
                          isSidecar: virtual, isAppleNative: native, dimmingMethod: method,
                          brightness: 100, volume: nil)
    }

    static func run() async -> Bool {
        var failures = 0
        func check(_ success: Bool, _ name: String) {
            print("W188DISPLAY \(success ? "PASS" : "FAIL") \(name)")
            if !success { failures += 1 }
        }
        let suite = "tatwo.display.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DisplaySettings(defaults: defaults)
        check(!settings.keyboardEnabled, "keyboard defaults off")
        settings.keyboardEnabled = true
        settings.setShade(0.4, for: "fixture")
        let restored = DisplaySettings(defaults: defaults)
        check(restored.keyboardEnabled && restored.shade(for: "fixture") == 0.4, "settings persist keyboard and shade")
        settings.setShade(.nan, for: "fixture")
        check(settings.shade(for: "fixture") == 0.4, "nonfinite shade rejected")

        let transport = FixtureDDCTransport()
        let clock = FixtureClock()
        let ddc = DDCArm64(transport: transport, now: { clock.time }, pause: { clock.pause($0) })
        let display = fixture()
        let endpoint = DisplayEndpoint(identity: display.identity, channel: ddc)
        check(DisplayDiscovery.match(display.identity, displays: [display], endpoints: [endpoint]) != nil, "EDID pairing succeeds")
        check(DisplayDiscovery.match(fixture(2).identity, displays: [fixture(2)], endpoints: [endpoint]) == nil, "EDID mismatch unsupported")
        var duplicate = display
        duplicate = ControlledDisplay(id: 2, name: "example", identity: display.identity, persistenceKey: "example",
                                      isBuiltIn: false, isVirtual: false, isSidecar: false, isAppleNative: false,
                                      dimmingMethod: .softwareDimmer, brightness: 100, volume: nil)
        check(DisplayDiscovery.match(display.identity, displays: [display, duplicate], endpoints: [endpoint]) == nil,
              "identical EDIDs refuse ambiguous pairing")
        check(DisplayDiscovery.match(display.identity, displays: [display], endpoints: [endpoint, endpoint]) == nil,
              "duplicate proxies refuse pairing")
        let read = await ddc.read(.brightness)
        check(read == DDCValue(current: 50, maximum: 100), "brightness read")
        transport.writeFailures = 1
        let written = await ddc.set(75, command: .brightness, smooth: false)
        check(written == .written && transport.values[.brightness]?.current == 75 && transport.writes.count == 2,
              "write retries and reaches value")
        let writtenAgain = await ddc.set(80, command: .brightness, smooth: false)
        check(writtenAgain == .written && clock.pauses.contains(where: { $0 >= 0.049 }), "per-display write throttle")
        transport.readFailures = 2
        check(await ddc.read(.volume) != nil, "read retries")
        let invalid = await ddc.set(.nan, command: .brightness)
        check(invalid == .failed, "invalid write rejected")
        let beforeSmooth = transport.writes.count
        check(await ddc.set(20, command: .brightness) == .written, "smooth hardware transition")
        let smooth = transport.writes.dropFirst(beforeSmooth).map { Int($0.1) }
        check(smooth.count > 1 && smooth.last == 20 && zip(smooth, smooth.dropFirst()).allSatisfy { $0 >= $1 },
              "smooth intermediate values monotonic")
        let concurrent = Task { await ddc.set(100, command: .brightness) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let latestWrite = await ddc.set(35, command: .brightness, smooth: false)
        let oldWrite = await concurrent.value
        check(latestWrite == .written && oldWrite == .superseded,
              "latest request supersedes old transition")
        check(transport.values[.brightness]?.current == 35, "latest request owns final hardware value")

        let discovered = await DisplayDiscovery.resolve(displays: [display], endpoints: [endpoint])
        check(discovered.displays[0].dimmingMethod == .hardwareDDC && discovered.displays[0].volume == 25,
              "validated VCP values expose hardware and volume")
        let noVolume = FixtureDDCTransport()
        noVolume.values.removeValue(forKey: .volume)
        let noVolumeChannel = DDCArm64(transport: noVolume, pause: { _ in })
        let noVolumeResult = await DisplayDiscovery.resolve(displays: [display], endpoints: [DisplayEndpoint(identity: display.identity, channel: noVolumeChannel)])
        check(noVolumeResult.displays[0].volume == nil && noVolumeResult.displays[0].dimmingMethod == .hardwareDDC,
              "volume absent without VCP 0x62 reply")
        let noBrightness = FixtureDDCTransport()
        noBrightness.values.removeValue(forKey: .brightness)
        let volumeOnly = await DisplayDiscovery.resolve(displays: [display], endpoints: [DisplayEndpoint(identity: display.identity, channel: DDCArm64(transport: noBrightness, pause: { _ in }))])
        check(volumeOnly.displays[0].dimmingMethod == .softwareDimmer && volumeOnly.displays[0].volume == 25,
              "volume independent from brightness support")
        let missing = await DisplayDiscovery.resolve(displays: [display], endpoints: [], reason: "Private IOAV symbols unavailable; software dimming fallback")
        check(!IOAVTransport.symbolsAvailable(resolve: { _ in nil }) && missing.displays[0].dimmingMethod == .softwareDimmer && missing.displays[0].volume == nil,
              "missing private symbols degrade to software")

        let dimmer = FixtureDimmer()
        let service = DisplayControlService(settings: settings, dimmer: dimmer, observe: false)
        service.install(discovered)
        var events: [DisplayFeedback] = []
        let subscriber = service.feedback.sink { events.append($0) }
        defer { subscriber.cancel() }
        check(service.listDisplays().count == 1 && service.brightness(of: 1) != nil && service.volume(of: 1) == 25,
              "assistant list and getters")
        check(await service.setBrightness(10, for: 1), "combined brightness write")
        check(transport.values[.brightness]?.current == 0 && dimmer.shades[1] == 0.5,
              "hardware zero before shade below boundary")
        check(await service.setBrightness(60, for: 1) && transport.values[.brightness]?.current == 50 && dimmer.shades[1] == 0,
              "hardware region removes shade")
        check(await service.setVolume(40, for: 1) && transport.values[.volume]?.current == 40, "assistant volume setter")
        check(events.map(\.kind) == [.brightness, .brightness, .volume] && events.last?.percentage == 40 && events.last?.displayName == "fixture",
              "feedback carries display name kind percentage")
        let unknownWrite = await service.setBrightness(50, for: 999)
        let invalidVolume = await service.setVolume(.nan, for: 1)
        check(!unknownWrite && !invalidVolume,
              "unknown display and invalid percentage rejected")
        service.install(noVolumeResult)
        check(!(await service.setVolume(50, for: 1)), "unsupported volume setter rejected")

        for (input, hardware, shade, restoredValue) in [(0.0,0.0,0.85,3.0),(10,0,0.5,10),(20,0,0,20),(60,50,0,60),(100,100,0,100)] {
            let split = CombinedDimming.split(input, hardware: true)
            check(split.hardware == hardware && split.shade == shade && abs(CombinedDimming.combined(hardware: hardware, shade: shade) - restoredValue) < 0.000001,
                  "combined mapping \(Int(input))")
        }
        let software = CombinedDimming.split(25, hardware: false)
        check(software.shade == 0.75, "software-only mapping")
        service.install(missing)
        check(await service.setBrightness(25, for: 1) && dimmer.shades[1] == 0.75, "software service adjusts fixture shade")
        service.install(DisplayDiscoveryResult(displays: [], channels: [:], reason: nil))
        check(dimmer.shades.isEmpty, "unplug removes shade window")
        service.install(missing)
        check(service.brightness(of: 1) == 25 && dimmer.shades[1] == 0.75, "reconnect restores persisted shade")
        let zero = FixtureDDCTransport()
        zero.values[.brightness] = DDCValue(current: 0, maximum: 100)
        let zeroChannel = DDCArm64(transport: zero, pause: { _ in })
        let zeroResult = await DisplayDiscovery.resolve(displays: [display], endpoints: [DisplayEndpoint(identity: display.identity, channel: zeroChannel)])
        service.install(zeroResult)
        check(service.brightness(of: 1) == 5 && zero.writes.isEmpty, "combined reconnect restores shade without hardware writes")
        zero.writeFailures = 3
        check(await service.setBrightness(80, for: 1) && service.displays[0].dimmingMethod == .softwareDimmer && abs((dimmer.shades[1] ?? 0) - 0.2) < 0.000001,
              "DDC write failure degrades to software")
        check(service.failureReason(for: service.displays[0]) == "這台螢幕沒有回應亮度調整，已改用軟體調光。",
              "M10 failed brightness write exposes plain-language reason")

        dimmer.available = false
        service.install(missing)
        check(service.displays[0].dimmingMethod == .unavailable && service.brightness(of: 1) == nil,
              "no desktop surface is unavailable")
        check(service.failureReason(for: service.displays[0]) == "目前無法在這台螢幕加上遮光，請重試。",
              "M10 missing desktop surface exposes reason")
        check(!(await service.setBrightness(50, for: 1)), "unavailable shade setter refuses adjustment")
        dimmer.available = true

        // M8: the left edge and legacy saved shades must leave the desktop visible.
        check(CombinedDimming.split(0, hardware: false).shade <= 0.85 &&
              CombinedDimming.split(0, hardware: true).shade <= 0.85 &&
              CombinedDimming.split(0, hardware: true).hardware == 0,
              "M8 zero brightness caps shade and preserves hardware zero")
        let safetySuite = "tatwo.display.fixture.\(UUID().uuidString)"
        let safetyDefaults = UserDefaults(suiteName: safetySuite)!
        defer { safetyDefaults.removePersistentDomain(forName: safetySuite) }
        safetyDefaults.set([display.persistenceKey: 1.0], forKey: "tatwo.display.shades")
        let safetySettings = DisplaySettings(defaults: safetyDefaults)
        let safetyDimmer = FixtureDimmer()
        let safetyService = DisplayControlService(settings: safetySettings, dimmer: safetyDimmer, observe: false)
        safetyService.install(missing)
        check((safetyDimmer.shades[1] ?? 1) <= 0.85 && (safetyService.brightness(of: 1) ?? 0) > 0,
              "M8 restart clamps legacy full-black software shade")
        check(await safetyService.setBrightness(0, for: 1) && (safetyDimmer.shades[1] ?? 1) <= 0.85,
              "M8 software slider at zero leaves visible desktop")
        let safetyRestart = DisplayControlService(settings: DisplaySettings(defaults: safetyDefaults), dimmer: safetyDimmer, observe: false)
        safetyRestart.install(zeroResult)
        check((safetyDimmer.shades[1] ?? 1) <= 0.85 && (safetyRestart.brightness(of: 1) ?? 0) > 0,
              "M8 hardware-zero reconnect clamps saved shade")
        safetyRestart.install(discovered)
        check(await safetyRestart.setBrightness(0, for: 1) && transport.values[.brightness]?.current == 0 &&
              (safetyDimmer.shades[1] ?? 1) <= 0.85,
              "M8 combined slider writes hardware zero with bounded shade")

        let failingVolumeTransport = FixtureDDCTransport()
        let failingVolumeChannel = DDCArm64(transport: failingVolumeTransport, pause: { _ in })
        let failingVolumeResult = await DisplayDiscovery.resolve(displays: [display], endpoints: [DisplayEndpoint(identity: display.identity, channel: failingVolumeChannel)])
        let failureService = DisplayControlService(settings: safetySettings, dimmer: FixtureDimmer(), observe: false,
                                                  permissionCheck: { true })
        failureService.install(failingVolumeResult)
        failingVolumeTransport.writeFailures = 3
        check(!(await failureService.setVolume(80, for: 1)) && failureService.volume(of: 1) == nil &&
              failureService.failureReason(for: failureService.displays[0]) == "這台螢幕沒有回應音量調整，暫時無法調音量。",
              "M10 failed volume write exposes reason and removes unavailable control")
        failureService.install(missing)
        check(failureService.failureReason(for: failureService.displays[0]) == nil,
              "M10 successful rediscovery clears display error")
        safetySettings.keyboardEnabled = true
        failureService.updateKeyboardTap()
        check(failureService.hasDeviceControlPermission && !failureService.keyTapActive &&
              failureService.keyboardError == "鍵盤控制沒有啟動，請重試或重新確認系統權限。",
              "M10 failed key tap with permission exposes reason")
        safetySettings.keyboardEnabled = false
        failureService.updateKeyboardTap()
        check(failureService.keyboardError == nil, "M10 disabling keyboard clears irrelevant failure")

        // M9: observe real notifications, but replace discovery and permission access.
        let lazySuite = "tatwo.display.fixture.\(UUID().uuidString)"
        let lazyDefaults = UserDefaults(suiteName: lazySuite)!
        defer { lazyDefaults.removePersistentDomain(forName: lazySuite) }
        lazyDefaults.set(false, forKey: "tatwo.display.keyboardEnabled")
        let lazySettings = DisplaySettings(defaults: lazyDefaults)
        var discoveryCalls = 0
        var permissionCalls = 0
        let lazyService = DisplayControlService(settings: lazySettings, dimmer: FixtureDimmer(),
            monitorControl: MonitorControlDetector(observe: false),
            permissionCheck: { permissionCalls += 1; return false },
            discover: { discoveryCalls += 1; return missing })
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(discoveryCalls == 0 && permissionCalls == 0 && !lazyService.isRefreshing,
              "M9 idle launch performs no discovery or permission checks")
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(discoveryCalls == 0, "M9 unused screen and wake events do not discover")
        lazyService.settingsDidOpen()
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(discoveryCalls == 1 && lazyService.displays.count == 1, "M9 settings opening starts discovery")
        lazyService.settingsDidClose()
        lazySettings.keyboardEnabled = true
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(discoveryCalls == 2 && permissionCalls > 0, "M9 keyboard enable starts discovery and checks permission")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(discoveryCalls == 3, "M9 enabled wake notification refreshes without polling")
        lazySettings.keyboardEnabled = false
        try? await Task.sleep(nanoseconds: 30_000_000)
        let checksWhenDisabled = permissionCalls
        let discoversWhenDisabled = discoveryCalls
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        check(permissionCalls == checksWhenDisabled && discoveryCalls == discoversWhenDisabled && !lazyService.keyTapActive,
              "M9 disabled keyboard has no two-second work or unused discovery")
        lazySettings.setShade(0.4, for: display.persistenceKey)
        var restorationCalls = 0
        let restorationService = DisplayControlService(settings: DisplaySettings(defaults: lazyDefaults), dimmer: FixtureDimmer(),
            monitorControl: MonitorControlDetector(observe: false), permissionCheck: { false },
            discover: { restorationCalls += 1; return missing })
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(restorationCalls == 1 && restorationService.brightness(of: 1) == 60,
              "M9 saved shade starts discovery and restores on launch")
        let enabledSuite = "tatwo.display.fixture.\(UUID().uuidString)"
        let enabledDefaults = UserDefaults(suiteName: enabledSuite)!
        defer { enabledDefaults.removePersistentDomain(forName: enabledSuite) }
        enabledDefaults.set(true, forKey: "tatwo.display.keyboardEnabled")
        var enabledCalls = 0
        let enabledService = DisplayControlService(settings: DisplaySettings(defaults: enabledDefaults), dimmer: FixtureDimmer(),
            monitorControl: MonitorControlDetector(observe: false), permissionCheck: { false },
            discover: { enabledCalls += 1; return missing })
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(enabledCalls == 1 && !enabledService.hasDeviceControlPermission,
              "M9 saved enabled keyboard starts discovery on launch")

        var keyDisplay = display
        keyDisplay.volume = 25
        let builtIn = fixture(2, builtIn: true, method: .unavailable)
        let unavailable = fixture(3, method: .unavailable)
        let apple = fixture(4, native: true, method: .unavailable)
        let keyDisplays = [keyDisplay, builtIn, unavailable, apple]
        func target(_ key: DisplayKeyTap.Key, mouse: CGDirectDisplayID? = 1, enabled: Bool = true, trusted: Bool = true,
                    audio: CGDirectDisplayID? = 1) -> CGDirectDisplayID? {
            DisplayKeyTap.target(key: key, mouseDisplay: mouse, displays: keyDisplays, enabled: enabled, trusted: trusted, audioDisplay: audio)
        }
        check(target(.brightnessUp) == 1 && target(.brightnessDown, mouse: nil) == nil, "mouse display target")
        check(target(.brightnessUp, mouse: 2) == nil && target(.brightnessUp, mouse: 4) == nil, "built-in and Apple native keys pass through")
        check(target(.brightnessDown, mouse: 3) == nil, "unavailable display keys pass through")
        check(target(.brightnessUp, enabled: false) == nil && target(.brightnessUp, trusted: false) == nil, "disabled or untrusted keys pass through")
        check(target(.volumeUp, audio: 2) == nil && target(.volumeDown, audio: nil) == nil && target(.volumeUp) == 1,
              "volume requires same output display")
        check(DisplayKeyTap.target(key: .volumeUp, mouseDisplay: 1, displays: [display], enabled: true, trusted: true, audioDisplay: 1) == nil,
              "unsupported volume keys pass through")
        check(target(.mute) == 1 && target(.mute, audio: nil) == nil, "mute follows output target")
        if let cursor = CGEvent(source: nil)?.location, let here = DisplayKeyTap.mouseDisplay(at: cursor),
           let offscreen = CGEvent(source: nil) {
            offscreen.location = CGPoint(x: -100_000, y: -100_000)
            check(DisplayKeyTap.mouseDisplay(at: offscreen.location) == nil && DisplayKeyTap.mouseDisplay(for: offscreen) == here,
                  "media key without cursor location still targets the display under the cursor")
        }
        check(DisplayAudioRoute.target(defaultDevice: 10, digitalDevices: [10], displays: [display]) == 1 &&
              DisplayAudioRoute.target(defaultDevice: 11, digitalDevices: [10], displays: [display]) == nil &&
              DisplayAudioRoute.target(defaultDevice: 10, digitalDevices: [10,11], displays: [display]) == nil &&
              DisplayAudioRoute.target(defaultDevice: 10, digitalDevices: [10], displays: [display, fixture(2)]) == nil,
              "digital audio routing rejects non-display and ambiguous routes")
        let keyDown = DisplayKeyTap.MediaEvent.decode(subtype: 8, data1: (2 << 16) | (0x0a << 8) | 1)
        let keyUp = DisplayKeyTap.MediaEvent.decode(subtype: 8, data1: (2 << 16) | (0x0b << 8))
        check(keyDown?.key == .brightnessUp && keyDown?.pressed == true && keyDown?.isRepeat == true && keyUp?.pressed == false &&
              DisplayKeyTap.MediaEvent.decode(subtype: 9, data1: 0) == nil, "system media key decode down repeat up")
        let codeDown = DisplayKeyTap.MediaEvent.decode(keycode: 145, down: true, isRepeat: true)
        let codeUp = DisplayKeyTap.MediaEvent.decode(keycode: 144, down: false, isRepeat: false)
        check(codeDown == .init(key: .brightnessDown, pressed: true, isRepeat: true) &&
              codeUp == .init(key: .brightnessUp, pressed: false, isRepeat: false) &&
              DisplayKeyTap.MediaEvent.decode(keycode: 122, down: true, isRepeat: false) == nil,
              "Apple keyboard brightness key codes 144/145 decode; F1 key code does not")
        check(MonitorControlDetector.running(in: ["app.monitorcontrol.MonitorControl"]) &&
              !MonitorControlDetector.running(in: ["app.example.fixture"]), "MonitorControl bundle detector")
        let query = IOAVTransport.packet(.brightness)
        let setting = IOAVTransport.packet(.volume, value: 50)
        check(query[1] == 1 && query[2] == 0x10 && setting[1] == 3 && setting[2] == 0x62 && setting[4] == 50,
              "Get VCP and Set VCP packet distinction")
        var reply: [UInt8] = [0x6e,0x88,0x02,0,0x10,0,0,100,0,50]
        reply.append(reply.reduce(UInt8(0x50), ^))
        check(IOAVTransport.decode(reply, command: .brightness)?.current == 50 && IOAVTransport.decode(reply, command: .volume) == nil,
              "reply validates command and checksum")
        reply[10] ^= 1
        check(IOAVTransport.decode(reply, command: .brightness) == nil, "corrupt reply rejected")
        var edid = [UInt8](repeating: 0, count: 128)
        edid.replaceSubrange(0..<8, with: [0,255,255,255,255,255,255,0])
        edid[9] = 1; edid[10] = 2; edid[12] = 42
        edid[127] = 0 &- edid.prefix(127).reduce(UInt8(0), { $0 &+ $1 })
        check(DisplayIdentity.edid(Data(edid)) == DisplayIdentity(vendor: 1, model: 2, serial: 42), "EDID identity parsing")
        edid[127] ^= 1
        check(DisplayIdentity.edid(Data(edid)) == nil, "invalid EDID checksum rejected")
        await ddc.invalidate()
        let invalidatedWrite = await ddc.set(50, command: .brightness)
        let invalidatedRead = await ddc.read(.brightness)
        check(invalidatedWrite == .failed && invalidatedRead == nil,
              "invalidated display refuses further commands")
        print("W188DISPLAY SUMMARY failures=\(failures)")
        return failures == 0
    }

    static func probe() async {
        print("W188DDCPROBE read-only: Get VCP 0x10/0x62 only; Set VCP disabled at transport boundary")
        let result = await DisplayDiscovery.discover(readOnly: true)
        if let reason = result.reason { print("W188DDCPROBE reason=\(reason)") }
        for (index, display) in result.displays.enumerated() {
            // Generic labels deliberately keep actual product names and serials out of logs.
            let label = display.isBuiltIn ? "built-in" : "external"
            let brightness = display.hardwareBrightness.map { "\($0.current)" } ?? "unavailable"
            let maximum = display.hardwareBrightness.map { "\($0.maximum)" } ?? "unavailable"
            let volume = display.hardwareVolume.map { "\($0.current)" } ?? "unavailable"
            let volumeMax = display.hardwareVolume.map { "\($0.maximum)" } ?? "unavailable"
            print("W188DDCPROBE display=\(index + 1) id=\(display.id) kind=\(label) virtual=\(display.isVirtual) method=\(display.dimmingMethod.rawValue) brightness=\(brightness) maximum=\(maximum) volume=\(volume) volumeMaximum=\(volumeMax)")
            if display.hardwareBrightness == nil {
                print("W188DDCPROBE display=\(index + 1) reason=\(display.isAppleNative ? "system-controlled Apple display" : "no unambiguous EDID match or VCP 0x10 query failed; software fallback")")
            }
        }
        print("W188DDCPROBE SUMMARY displays=\(result.displays.count) settingWrites=0")
    }
}
#endif
