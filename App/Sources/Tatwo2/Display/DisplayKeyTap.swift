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
    }
    struct Snapshot: Sendable {
        var displays: [ControlledDisplay] = []
        var enabled = false, trusted = false, refreshing = false
        var audioDisplay: CGDirectDisplayID?
    }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "ai.tatwo.display-key-tap", qos: .userInteractive)
    private weak var service: DisplayControlService?
    private var snapshot = Snapshot()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
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
    private static func record(_ key: Key, handled: Bool, reason: String?, display: CGDirectDisplayID?) {
        let time = Date()
        logQueue.async {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tatwo2/logs/display-keys.log")
            let line = "\(ISO8601DateFormatter().string(from: time)) key=\(key) result=\(handled ? "handled" : "pass") reason=\(reason ?? "-") display=\(display ?? 0)\n"
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
        tap = created
        worker.async { [self] in
            lock.lock()
            guard tap === created, CFMachPortIsValid(created) else { lock.unlock(); return }
            let loop = CFRunLoopGetCurrent()!
            runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            lock.unlock()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        return true
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil; runLoop = nil; heldKeys.removeAll()
    }
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); defer { lock.unlock() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) else { return pass }
        return process(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1,
                       mouseDisplay: Self.mouseDisplay(for: event)) ? nil : pass
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
