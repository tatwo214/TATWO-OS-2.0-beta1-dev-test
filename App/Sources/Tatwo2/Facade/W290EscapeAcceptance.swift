#if DEBUG
import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Real keyDown events on the production window and production DM event monitor.
enum W290EscapeAcceptance {
    @MainActor private final class Input: NSView {
        var keys = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            keys += 1
            interpretKeyEvents([event])
        }
    }

    /// A deterministic input-method stand-in: AppKit's setMarkedText alone does not start an IME session.
    @MainActor private final class MarkedInput: NSTextView {
        var cancelledComposition = false
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53, hasMarkedText() {
                cancelledComposition = true
                unmarkText()
            } else { super.keyDown(with: event) }
        }
    }

    @MainActor private static func escape(_ window: NSWindow, throughApp: Bool = false, repeatKey: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: repeatKey, keyCode: 53)!
        // DM consumes Escape in its app-local monitor, before NSWindow.sendEvent.
        if throughApp { NSApp.sendEvent(event) } else { window.sendEvent(event) }
    }

    @MainActor private static func settle() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else {
            throw BotLibraryError.invalid("w290esc requires an isolated staging environment")
        }
        var passed = 0, failures = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failures += 1 }
            print("W290 \(ok ? "PASS" : "FAIL") \(label)")
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let main = TatwoWorkOSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.animationBehavior = .none
        let input = Input(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let anchor = NSButton(frame: NSRect(x: 60, y: 650, width: 80, height: 30))
        anchor.title = "Popover"
        input.addSubview(anchor)
        main.contentView = input
        main.makeKeyAndOrderFront(nil)
        main.makeMain()
        main.makeFirstResponder(input)
        await settle()
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let screenLocked = session?["CGSSessionScreenIsLocked"]
        print("W290 NOTE appActive=\(NSApp.isActive) screenLocked=\(String(describing: screenLocked))")
        let frame = main.frame
        let alpha = main.alphaValue
        var closes = 0
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: main, queue: .main) { _ in closes += 1 }
        defer {
            NotificationCenter.default.removeObserver(closeObserver)
            main.orderOut(nil)
        }
        func mainIntact(_ key: Bool = true) -> Bool {
            main.isVisible && (!key || main.isKeyWindow) && !main.isMiniaturized
                && main.frame == frame && main.alphaValue == alpha && closes == 0 && !NSApp.isHidden
        }

        check(mainIntact() && main.attachedSheet == nil, "A main starts visible and key with no panels")
        for index in 1...3 {
            escape(main)
            await settle()
            check(mainIntact() && input.keys == index, "A Esc \(index) reaches the responder; main stays visible and key")
        }
        check(mainIntact(false) && input.keys == 3, "A three Esc preserve visibility, frame, alpha and responder delivery")
        escape(main, repeatKey: true)
        check(mainIntact(), "A held Esc also keeps the main window")

        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        let popoverController = NSViewController()
        let popoverInput = Input(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        popoverController.view = popoverInput
        popover.contentViewController = popoverController
        popover.contentSize = popoverInput.frame.size
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        await settle()
        check(popover.isShown, "B native popover opens")
        if let popupWindow = popoverInput.window {
            popupWindow.makeKey()
            popupWindow.makeFirstResponder(popoverInput)
            let keys = input.keys
            escape(popupWindow)
            await settle()
            check(!popover.isShown && mainIntact(false) && input.keys == keys, "B Esc closes only the popover; main stays visible")
        } else { check(false, "B popover has a window") }
        popover.close()
        main.makeKey()
        main.makeFirstResponder(input)

        // Existing DM UI and monitor; isolated defaults, fake web host, no engines or accounts.
        let defaults = UserDefaults(suiteName: "W290-\(UUID().uuidString)")!
        let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false },
            chatGPTCatalog: { Empty().eraseToAnyPublisher() }, recentApps: defaults)
        let settings = GlobalDMDeskSettings(defaults: defaults)
        settings.form = .outerPortrait
        let browser = DMBrowser(store: store, openBox: {}, pageHost: DMBrowserAcceptance.FakeWebHost(), podPage: { nil })
        let panels = GlobalDMPanelController(store: store, desk: settings,
            browserServices: GlobalDMBrowserServices(browser: browser, flow: DMBrowserPhoneAcceptance.inertFlow()))
        defer { store.close(); panels.uninstall(); browser.closeAll() }
        panels.install()
        store.openFloating()
        await settle()
        if let dm = panels.floatingPanelForTesting {
            dm.makeKey()
            check(dm.isVisible && store.isFloatingOpen, "C real DM panel opens")
            escape(dm, throughApp: true)
            await settle()
            check(!store.isFloatingOpen && !dm.isVisible && mainIntact(false), "C Esc folds DM and keeps the main window")
            main.makeKey()
            main.makeFirstResponder(input)
            escape(main)
            await settle()
            check(mainIntact(false), "C another Esc after folding DM keeps main visible")
        } else { check(false, "C real DM panel exists") }
        panels.uninstall()

        var recording = true, records = 0, cancellations = 0
        let recorder = BrowserShortcutRecorder.Capture(frame: input.bounds)
        recorder.record = { _ in records += 1 }
        recorder.cancel = {
            recording = false
            cancellations += 1
            main.contentView = input
            main.makeFirstResponder(input)
        }
        main.contentView = recorder
        main.makeKey()
        main.makeFirstResponder(recorder)
        check(main.firstResponder === recorder && recording, "D production shortcut recorder takes focus")
        escape(main)
        check(!recording && cancellations == 1 && records == 0 && mainIntact(false), "D Esc cancels recording without storing a key or closing main")
        escape(main)
        check(mainIntact(false) && cancellations == 1, "D another Esc after recording keeps main visible")

        let text = MarkedInput(frame: input.bounds)
        main.contentView = text
        main.makeFirstResponder(text)
        text.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        check(text.hasMarkedText(), "IME Chinese marked text is active")
        escape(main)
        check(text.cancelledComposition && !text.hasMarkedText() && mainIntact(false), "IME stand-in receives Esc to cancel marked text before main")
        main.contentView = input
        main.makeFirstResponder(input)

        let sheet = CoderSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = Input(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        main.beginSheet(sheet, completionHandler: nil)
        await settle()
        check(main.attachedSheet === sheet, "sheet opens on main")
        escape(sheet, throughApp: true)
        await settle()
        main.makeKey()
        main.makeFirstResponder(input)
        check(main.attachedSheet == nil && mainIntact(false), "sheet Esc closes only sheet")
        escape(main)
        check(mainIntact(false), "sheet another Esc keeps main visible")
        main.beginSheet(sheet, completionHandler: nil)
        await settle()
        let sheetClosedAt = Date()
        escape(sheet, throughApp: true)
        main.makeKey()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if let cardWindow = popoverInput.window {
            cardWindow.makeKey(); cardWindow.makeFirstResponder(popoverInput)
            escape(cardWindow, throughApp: true)
            let elapsed = Date().timeIntervalSince(sheetClosedAt)
            await settle()
            print("W352 ESC elapsed=\(elapsed) cardShown=\(popover.isShown) appActive=\(NSApp.isActive) mainVisible=\(main.isVisible) attachedSheet=\(main.attachedSheet != nil)")
            check(elapsed < 0.15 && !popover.isShown && mainIntact(false), "W352 immediate Esc after sheet closes native card within 150ms")
        } else { check(false, "W352 immediate card gets a window") }

        print("W290 SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
}
#endif
