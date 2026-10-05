import AppKit

@MainActor protocol DisplayShading: AnyObject {
    @discardableResult func setShade(_ shade: Double, on display: CGDirectDisplayID, animated: Bool) -> Bool
    func retainDisplays(_ ids: Set<CGDirectDisplayID>)
}

@MainActor final class SoftwareDimmer: DisplayShading {
    private var windows: [CGDirectDisplayID: NSPanel] = [:]
    private var transitions: [CGDirectDisplayID: Task<Void, Never>] = [:]

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
    @discardableResult func setShade(_ shade: Double, on display: CGDirectDisplayID, animated: Bool = true) -> Bool {
        guard shade.isFinite else { return false }
        transitions[display]?.cancel()
        let shade = CombinedDimming.clampShade(shade)
        guard shade > 0 || windows[display] != nil else { return true }
        guard let screen = Self.screen(for: display) else { return false }
        let window: NSPanel
        if let existing = windows[display] { window = existing }
        else {
            window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.sharingType = .none
            window.alphaValue = 0
            windows[display] = window
        }
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        guard animated else {
            window.alphaValue = shade
            if shade == 0 { window.orderOut(nil) }
            return true
        }
        let start = window.alphaValue
        transitions[display] = Task { @MainActor [weak self, weak window] in
            for step in 1...12 {
                guard !Task.isCancelled, let window else { return }
                window.alphaValue = start + (shade - start) * Double(step) / 12
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            if shade == 0 { window?.orderOut(nil) }
            self?.transitions[display] = nil
        }
        return true
    }
    func retainDisplays(_ ids: Set<CGDirectDisplayID>) {
        for id in Array(windows.keys) where !ids.contains(id) {
            transitions.removeValue(forKey: id)?.cancel()
            windows.removeValue(forKey: id)?.close()
        }
    }
}

