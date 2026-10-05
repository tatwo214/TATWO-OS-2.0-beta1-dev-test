import AppKit
import ApplicationServices
import Combine

extension Notification.Name {
    static let tatwoToggleGlobalDM = Notification.Name("tatwoToggleGlobalDM")
}

/// 只觀察、不吃掉事件；面板與焦點交給全域私訊框處理。
@MainActor
final class GlobalHotkeyMonitor: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = GlobalHotkeyMonitor()
    @Published private(set) var isSystemWide = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var permissionSurfaces: Set<String> = []
    private var detector = ModifierChordDetector()
    private static let chordEvents: NSEvent.EventTypeMask = [
        .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]

    func install() {
        guard localMonitor == nil else { return }
        detector.reset()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.chordEvents) { [weak self] event in
            self?.consume(event)
            return event
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibilityPermission() }
        }
        refreshAccessibilityPermission()
        updatePermissionPolling()
    }

    func setPermissionSurfaceVisible(_ visible: Bool, owner: String) {
        if visible {
            permissionSurfaces.insert(owner)
            refreshAccessibilityPermission()
        } else {
            permissionSurfaces.remove(owner)
        }
        updatePermissionPolling()
    }

    func menuWillOpen(_ menu: NSMenu) {
        setPermissionSurfaceVisible(true, owner: "menu-\(ObjectIdentifier(menu))")
    }

    func menuDidClose(_ menu: NSMenu) {
        setPermissionSurfaceVisible(false, owner: "menu-\(ObjectIdentifier(menu))")
    }

    private func updatePermissionPolling() {
        // Only visible permission UI needs immediate grant/revocation feedback.
        guard localMonitor != nil, !permissionSurfaces.isEmpty else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibilityPermission() }
        }
        timer.tolerance = 0.1
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func uninstall() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        localMonitor = nil
        globalMonitor = nil
        activationObserver = nil
        isSystemWide = false
        detector.reset()
    }

    func refreshAccessibilityPermission() {
        guard localMonitor != nil else { return }
        if AXIsProcessTrusted() {
            if globalMonitor == nil {
                detector.reset()
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.chordEvents) { [weak self] event in
                    // global monitor 本來就不會收到本 App 的事件；local 仍處理非啟用面板。
                    self?.consume(event)
                }
            }
        } else if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
            detector.reset()
        }
        let available = globalMonitor != nil
        if isSystemWide != available { isSystemWide = available }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func consume(_ event: NSEvent) {
        if event.type != .flagsChanged {
            detector.keyDown(at: event.timestamp)
            return
        }
        var flags: ModifierChordDetector.Flags = []
        let native = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if native.contains(.option) { flags.insert(.option) }
        if native.contains(.command) { flags.insert(.command) }
        if native.contains(.shift) { flags.insert(.shift) }
        if native.contains(.control) { flags.insert(.control) }
        if native.contains(.capsLock) { flags.insert(.capsLock) }
        if native.contains(.function) { flags.insert(.function) }
        if !native.subtracting([.option, .command, .shift, .control, .capsLock, .function]).isEmpty {
            flags.insert(.other)
        }
        // W179 E：設定裡「單按 ⌥⌘ 開關私訊框」關掉時照樣追蹤手勢，只是不開關。
        if detector.flagsChanged(flags, at: event.timestamp), GlobalDMDeskSettings.chordToggleEnabled() {
            NotificationCenter.default.post(name: .tatwoToggleGlobalDM, object: nil)
        }
    }

    /// 直達鍵的 Carbon 熱鍵會吃掉 keyDown；App 內箭頭與錄鍵也在消化按鍵前呼叫這裡。
    /// 把這次手勢作廢，放開 ⌥⌘ 才不會又開關私訊框。
    func cancelPendingChord() {
        detector.keyDown(at: ProcessInfo.processInfo.systemUptime)
    }
}
