// System media key semantics informed by MonitorControl/Support/MediaKeyTapManager.swift
// (MIT), Copyright © 2017. https://github.com/MonitorControl/MonitorControl
// See THIRD_PARTY_NOTICES.md.
import AppKit
import ApplicationServices

final class DisplayKeyTap: @unchecked Sendable {
    enum Key: Int, Sendable { case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }
    struct MediaEvent: Equatable, Sendable {
        let key: Key
        let pressed: Bool
        let isRepeat: Bool
        static func decode(subtype: Int16, data1: Int) -> Self? {
            guard subtype == 8, let key = Key(rawValue: (data1 >> 16) & 0xffff) else { return nil }
            let state = (data1 >> 8) & 0xff
            guard state == 0x0a || state == 0x0b else { return nil }
            return Self(key: key, pressed: state == 0x0a, isRepeat: (data1 & 1) != 0)
        }
        /// Apple keyboards on Apple silicon send F1/F2 as plain key events 145/144, not system-defined
        /// events (10-07 Studio Magic Keyboard: zero system-defined brightness rows). MonitorControl's
        /// MediaKeyTap reads the same two key codes.
        static func decode(keycode: Int64, down: Bool, isRepeat: Bool) -> Self? {
            let key: Key? = keycode == 144 ? .brightnessUp : keycode == 145 ? .brightnessDown : nil
            return key.map { Self(key: $0, pressed: down, isRepeat: isRepeat) }
        }
    }
    struct Snapshot: Sendable {
        var displays: [ControlledDisplay] = []
        var enabled = false, trusted = false, refreshing = false
        var audioDisplay: CGDirectDisplayID?
    }
    private let lock = NSLock()
    private weak var service: DisplayControlService?
    private var snapshot = Snapshot()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var keyTap: CFMachPort?
    private var keySource: CFRunLoopSource?
    private var keyLoop: CFRunLoop?
    private var heldKeys: [Key: CGDirectDisplayID] = [:]
    @MainActor private var mutedVolumes: [CGDirectDisplayID: Double] = [:]
    @MainActor init(service: DisplayControlService) { self.service = service }
    func update(_ value: Snapshot) { lock.lock(); defer { lock.unlock() }; snapshot = value }

    static func target(key: Key, mouseDisplay: CGDirectDisplayID?, displays: [ControlledDisplay],
                       enabled: Bool, trusted: Bool, audioDisplay: CGDirectDisplayID?) -> CGDirectDisplayID? {
        reason(key: key, mouse: mouseDisplay, state: Snapshot(displays: displays, enabled: enabled,
               trusted: trusted, audioDisplay: audioDisplay)) == nil ? mouseDisplay : nil
    }
    private static func reason(key: Key, mouse: CGDirectDisplayID?, state: Snapshot) -> String? {
        if !state.enabled { return "keyboard_off" }
        if !state.trusted { return "no_permission" }
        if state.refreshing { return "refreshing" }
        guard let mouse else { return "mouse_display_unknown" }
        guard let display = state.displays.first(where: { $0.id == mouse }) else { return "display_not_controllable" }
        if display.isAppleNative { return "display_apple_native" }
        if display.isBuiltIn || display.dimmingMethod == .unavailable { return "display_not_controllable" }
        if key == .volumeUp || key == .volumeDown || key == .mute {
            if display.volume == nil || state.audioDisplay != mouse { return "volume_not_routed" }
        }
        return nil
    }
    private static let logQueue = DispatchQueue(label: "ai.tatwo.display-key-log")
    private static var logWrites = 0   // Only accessed on logQueue.
    private static var rawSeen = 0   // Only accessed on logQueue.
    /// Unrecognized system-defined key events (subtype, key type, state) — no content, at most 40 per launch.
    private static func recordRaw(subtype: Int16, data1: Int) {
        logQueue.async {
            guard rawSeen < 40 else { return }
            rawSeen += 1
            appendLine("\(ISO8601DateFormatter().string(from: Date())) raw subtype=\(subtype) keytype=\((data1 >> 16) & 0xffff) state=\(String((data1 >> 8) & 0xff, radix: 16))\n")
        }
    }
    /// F1/F2 in standard function-key mode and F14/F15 — fixed codes only, never other keys.
    private static func recordFunctionKey(_ keycode: Int64) {
        logQueue.async {
            guard rawSeen < 40 else { return }
            rawSeen += 1
            appendLine("\(ISO8601DateFormatter().string(from: Date())) raw keycode=\(keycode)\n")
        }
    }
    private static func record(_ key: Key, handled: Bool, reason: String?, display: CGDirectDisplayID?) {
        let time = Date()
        logQueue.async {
            appendLine("\(ISO8601DateFormatter().string(from: time)) key=\(key) result=\(handled ? "handled" : "pass") reason=\(reason ?? "-") display=\(display ?? 0)\n")
        }
    }
    /// Runs on logQueue.
    private static func appendLine(_ line: String) {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tatwo2/logs/display-keys.log")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: Data(line.utf8))
                logWrites += 1
                if logWrites == 1 || logWrites % 50 == 0 {
                    let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                    if rows.count > 200 { try (rows.suffix(200).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
                }
            } catch { NSLog("Display key diagnostic write failed") }
    }
    /// 媒體鍵事件不一定帶游標座標（模擬鍵、部分鍵盤是 0,0）；跟 MonitorControl 一樣看「現在游標在哪個螢幕」。
    static func mouseDisplay(for event: CGEvent) -> CGDirectDisplayID? {
        mouseDisplay(at: CGEvent(source: nil)?.location ?? event.location)
    }
    static func mouseDisplay(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0, count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &id, &count) == .success && count == 1 ? id : nil
    }
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.enabled, snapshot.trusted else { return false }
        if tap != nil { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                             eventsOfInterest: CGEventMask(1 << 14), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<DisplayKeyTap>.fromOpaque(context).takeUnretainedValue().handle(type: type, event: event)
        }, userInfo: context), let source = CFMachPortCreateRunLoopSource(nil, created, 0) else { return false }
        // Key-down/up tap for 144/145: it sees every keystroke, so it runs on its own thread (never waits on main)
        // and reads only CGEvent fields (no NSEvent, so HIToolbox's Caps Lock path stays out).
        // Both taps or neither: without it Apple keyboards' F1/F2 do nothing, so fail and let the next start retry.
        guard let keys = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1 << 10) | CGEventMask(1 << 11), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<DisplayKeyTap>.fromOpaque(context).takeUnretainedValue().handleKey(type: type, event: event)
        }, userInfo: context), let keysSource = CFMachPortCreateRunLoopSource(nil, keys, 0) else {
            CGEvent.tapEnable(tap: created, enable: false); CFMachPortInvalidate(created)
            return false
        }
        tap = created
        // Main run loop: HIToolbox's Caps Lock press-and-hold timer lands on the tap's run loop
        // and asserts the main queue (10-07 Studio crash in TSMAdjustCapsLockPressAndHold).
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tapSource = source
        CGEvent.tapEnable(tap: created, enable: true)
        keyTap = keys; keySource = keysSource
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.keySource === keysSource else { self.lock.unlock(); return }   // stop() already ran
            self.keyLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keysSource, .commonModes)
            self.lock.unlock()
            CFRunLoopRun()   // stop() stops this loop.
        }
        thread.name = "ai.tatwo.display-key-codes"
        thread.start()
        return true
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false); CFMachPortInvalidate(keyTap) }
        if let keySource { CFRunLoopSourceInvalidate(keySource) }
        if let keyLoop { CFRunLoopStop(keyLoop) }
        tap = nil; tapSource = nil; keyTap = nil; keySource = nil; keyLoop = nil; heldKeys.removeAll()
    }
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); defer { lock.unlock() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) else { return pass }
        if MediaEvent.decode(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1) == nil {
            Self.recordRaw(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1)   // F1/F2 diagnosis: codes only
        }
        return process(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1,
                       mouseDisplay: Self.mouseDisplay(for: event)) ? nil : pass
    }
    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); defer { lock.unlock() }
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return pass
        }
        guard type == .keyDown || type == .keyUp else { return pass }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let media = MediaEvent.decode(keycode: keycode, down: type == .keyDown,
                                            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) else {
            if type == .keyDown, [122, 120, 107, 113].contains(keycode) { Self.recordFunctionKey(keycode) }
            return pass
        }
        return process(media: media, mouseDisplay: Self.mouseDisplay(for: event)) ? nil : pass
    }
    func process(subtype: Int16, data1: Int, mouseDisplay: CGDirectDisplayID?) -> Bool {
        guard let media = MediaEvent.decode(subtype: subtype, data1: data1) else { return false }
        return process(media: media, mouseDisplay: mouseDisplay)
    }
    func process(media: MediaEvent, mouseDisplay: CGDirectDisplayID?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let id = media.pressed ? mouseDisplay : heldKeys.removeValue(forKey: media.key)
        let reason = media.pressed ? Self.reason(key: media.key, mouse: mouseDisplay, state: snapshot) : (id == nil ? "key_up_unhandled" : nil)
        Self.record(media.key, handled: reason == nil, reason: reason, display: id ?? mouseDisplay)
        guard reason == nil, let id else { return false }
        if !media.pressed { return true }
        heldKeys[media.key] = id
        if media.key == .mute && media.isRepeat { return true }
        Task { @MainActor [weak self] in
            guard let self, let service = self.service else { return }
            switch media.key {
            case .brightnessUp, .brightnessDown, .volumeUp, .volumeDown:
                let volume = media.key == .volumeUp || media.key == .volumeDown
                let delta = media.key == .volumeUp || media.key == .brightnessUp ? 6.25 : -6.25
                if let current = volume ? service.volume(of: id) : service.brightness(of: id) {
                    if volume { await service.setVolume(current + delta, for: id, smooth: true) }
                    else { await service.setBrightness(current + delta, for: id, smooth: true) }
                }
            case .mute:
                if let current = service.volume(of: id) {
                    if current > 0 { self.mutedVolumes[id] = current }
                    await service.setVolume(current > 0 ? 0 : (self.mutedVolumes[id] ?? 25), for: id, smooth: true)
                }
            }
        }
        return true
    }
}
