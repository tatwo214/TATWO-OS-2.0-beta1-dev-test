#if DEBUG
import AppKit
import TatwoCEFBridge

/// Existing W294E disposable loopback Pod; only synthetic input, no production pairing page.
@MainActor enum W328PairfillAcceptance {
    static func run(pod: TapWebPod) async throws {
        guard NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment), let view = pod.browser,
              view.currentURLString?.hasPrefix("http://127.0.0.1:") == true else {
            throw TapError.remote("W328 requires isolated loopback Pod")
        }
        var passes = 0
        func check(_ ok: Bool, _ label: String) throws {
            print("W328 \(ok ? "PASS" : "FAIL") \(label)")
            guard ok else { throw TapError.remote("W328 " + label) }
            passes += 1
        }
        let previousEvent = pod.onEvent
        var ready = false, complete = false, submitted = false, submits = 0, events = 0, length = 0, keyEvents = 0, focused = false
        var statusLength = -1, documentFocused = false
        pod.onEvent = { raw in
            guard let data = raw.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if event["type"] as? String == "w328_ready" { ready = true }
            if event["type"] as? String == "w328" {
                events += 1; length = event["length"] as? Int ?? -1
                complete = event["complete"] as? Bool == true && event["trusted"] as? Bool == false
            }
            if event["type"] as? String == "w328_key" { keyEvents += 1; focused = event["focused"] as? Bool == true }
            if event["type"] as? String == "w328_submit" { submits += 1; submitted = event["length"] as? Int == 8 && event["trusted"] as? Bool == true }
            if event["type"] as? String == "w328_status" {
                statusLength = event["length"] as? Int ?? -1; documentFocused = event["documentFocused"] as? Bool == true
                print("W328 status length=\(event["length"] as? Int ?? -1) focused=\(event["focused"] as? Bool ?? false) document_focused=\(event["documentFocused"] as? Bool ?? false)")
            }
        }
        pod.beginConnectorViewport()
        defer { view.releaseAgentKey(); pod.endConnectorViewport(); pod.onEvent = previousEvent }
        pod.run("window.__tatwoPod.command({cmd:'w328KeyFixture'})")
        try check(await BrowserRuntimeAcceptance.waitUntil { ready }, "synthetic field observer ready")
        let previousKey = NSApp.keyWindow, parking = view.superview!, savedFrame = view.frame
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.sharingType = .none
        defer {
            view.removeFromSuperview(); parking.addSubview(view); view.frame = savedFrame
            previousKey?.makeKey(); window.close()
            pod.run("window.__tatwoPod.command({cmd:'w328EndFixture'})")
        }
        try check(await ChatGPTConnectorPod.focusPairingView(view) == "parked", "key:no_focus:parked before any native input; card falls back to showing code")
        pod.run("window.__tatwoPod.command({cmd:'w328Status'})")
        try check(await BrowserRuntimeAcceptance.waitUntil { statusLength == 0 }, "parking field length zero")
        try check(events == 0 && keyEvents == 0 && !documentFocused, "parking has zero input and keeps document unfocused")
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(policy) }
        view.removeFromSuperview(); window.contentView!.addSubview(view); view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let focusWhy = await ChatGPTConnectorPod.focusPairingView(view)
        print("W328 native focus reason=\(focusWhy ?? "none") policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) key=\(window.isKeyWindow) responder=\(String(describing: window.firstResponder))")
        let active = NSApp.isActive, keyWindow = window.isKeyWindow
        guard active && keyWindow else {
            print("W328 SKIP focus_unavailable active=\(active ? 1 : 0) key=\(keyWindow ? 1 : 0)")
            print("W328 SUMMARY passes=\(passes) failures=0")
            return
        }
        try check(focusWhy == nil && window.isKeyWindow, "onscreen pairing window becomes key and CEF first responder")
        let generation = view.navigationGeneration
        func key(_ phase: Int32, generation: UInt64? = nil, text: String = "2") -> Bool {
            view.sendAgentKey(19, windowsCode: 50, characters: text, unmodified: text,
                              modifiers: 0, phase: phase, navigationGeneration: generation ?? view.navigationGeneration)
        }
        try check(!key(0, generation: generation + 1) && view.lastAgentKeyRefusal == "stale_generation", "stale generation refusal")
        for phase: Int32 in [-1, 3] {
            try check(!key(phase) && view.lastAgentKeyRefusal == "bad_args", "bad phase refusal")
        }
        try check(!key(0, text: "") && view.lastAgentKeyRefusal == "bad_args", "bad character refusal")
        view.releaseAgentKey()
        try check(!key(1) && view.lastAgentKeyRefusal == "key_host_busy", "orphan character refusal")
        try check(key(0), "seed residual key host")
        try check(!key(0) && view.lastAgentKeyRefusal == "key_host_busy", "busy key host refusal")
        view.releaseAgentKey()
        try check(key(0) && view.lastAgentKeyRefusal.isEmpty, "release clears host and successful send clears reason")
        view.releaseAgentKey()
        view.isHidden = true
        try check(!key(0) && view.lastAgentKeyRefusal == "input_not_current", "hidden view still refused")
        view.isHidden = false
        let snapshot = try await BrowserRuntimeAcceptance.snapshot(view)
        let fields = (snapshot["forms"] as? [[String: Any]] ?? []).flatMap { $0["fields"] as? [[String: Any]] ?? [] }
        guard let rect = fields.first?["rect"] as? [String: Double],
              let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
              let elementID = fields.first?["elementID"] as? String else {
            throw TapError.remote("W328 synthetic field missing")
        }
        try check(view.sendClick(at: NSPoint(x: (x + width / 2).rounded(.down), y: (y + height / 2).rounded(.down)),
                                 navigationGeneration: generation), "native field click on onscreen Pod")
        try? await Task.sleep(for: .milliseconds(150))
        func checkFocus(_ expectedRect: NSRect, pairing: Bool = true) async -> (Bool, String?) {
            await withCheckedContinuation { continuation in
                view.checkAgentFocus(withNavigationGeneration: generation, expectedRect: expectedRect, pairing: pairing,
                    dispatchGate: { dispatch in dispatch(); return true }) { ok, why in continuation.resume(returning: (ok, why)) }
            }
        }
        let fieldRect = NSRect(x: x, y: y, width: width, height: height)
        let wrong = await checkFocus(fieldRect.offsetBy(dx: 100, dy: 0))
        print("W328 checkAgentFocus wrong_field ok=\(wrong.0) reason=\(wrong.1 ?? "none")")
        try check(!wrong.0, "wrong pairing field focus refuses typing")
        let generic = await checkFocus(fieldRect, pairing: false)
        try check(!generic.0, "generic focus still refuses pairing one-time-code")
        let focus = await checkFocus(fieldRect)
        print("W328 checkAgentFocus pairing_field ok=\(focus.0) reason=\(focus.1 ?? "none")")
        try check(focus.0, "document and bound pairing input have focus before typing")
        view.releaseAgentKey()
        func type(pairing: Bool) async -> Bool {
            await withCheckedContinuation { continuation in
                view.typeText("23456789", elementID: elementID, navigationGeneration: generation, submit: true, pairing: pairing,
                    dispatchGate: { dispatch in dispatch(); return true }) { ok, _ in continuation.resume(returning: ok) }
            }
        }
        try check(await type(pairing: false) == false && events == 0 && submits == 0, "generic typeText refuses one-time-code before input or submit")
        try check(await type(pairing: true), "pairing node-bound typeText succeeds with length eight")
        let arrived = await BrowserRuntimeAcceptance.waitUntil { complete }
        pod.run("window.__tatwoPod.command({cmd:'w328Status'})")
        try? await Task.sleep(for: .milliseconds(100))
        print("W328 input events=\(events) length=\(length) key_events=\(keyEvents) focused=\(focused)")
        try check(arrived, "all eight synthetic characters arrive through the native setter")
        try check(length == 8 && documentFocused && statusLength == 8, "value length eight and document focused without reading content")
        try check(await BrowserRuntimeAcceptance.waitUntil { submitted }, "requestSubmit receives length eight")
        try check(submits == 1 && events == 1, "one input event and exactly one requestSubmit")
        try check(view.navigationGeneration == generation, "typing keeps original generation")
        previousKey?.makeKey()
        try check(previousKey == nil || NSApp.keyWindow === previousKey, "previous key window restored without ordering windows")
        print("W328 SUMMARY passes=\(passes) failures=0")
    }
}
#endif
