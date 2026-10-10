import AppKit

// The actual fillPairingCode, form validation, pairing typeText and log sanitizer are inserted below.
// Fake browser only: no CEF runtime, network, profile, real account or pairing code.
typealias TatwoCEFBrowserView = FakeView
enum HandsCodeFill: Equatable { case failed(String), filled }
struct HandsPodFrame {}
enum HandsAuth {
    static let codeAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool { a == b }
}
enum HandsConnectFlow {
    static func authorizeEvidence(_ url: URL, publicHost: String) -> String? {
        url.scheme == "https" && url.host == publicHost && url.path == "/bound" ? "synthetic-bound-evidence" : nil
    }
    // INSERT cleanStep
}
final class FakeLog {
    var lines: [String] = []
    func write(_ source: String, _ text: String) { lines.append(source + ":" + text) }
}
@MainActor final class FakeWindow {
    var frame = NSRect(x: 50, y: 50, width: 1100, height: 800)
    var isKeyWindow = false, allowResponder = true
    var fronts = 0, restores = 0
    func makeKeyAndOrderFront(_ sender: Any?) { fronts += 1; isKeyWindow = true }
    func makeFirstResponder(_ view: FakeView?) -> Bool { allowResponder }
    func makeKey() { restores += 1 }
}
@MainActor final class FakeApp {
    var keyWindow: FakeWindow? = FakeWindow(), activations = 0
    func activate(ignoringOtherApps: Bool) { activations += 1 }
}
@MainActor let NSApp = FakeApp()
enum NSScreen {
    struct Screen { let frame = NSRect(x: 0, y: 0, width: 2000, height: 1200) }
    static let screens = [Screen()]
}
@MainActor final class FakeView {
    var subviews: [FakeView] { [self] }
    var window: FakeWindow? = FakeWindow()
    var focusOK = true, focusReason = "browser_field_target_unavailable", focusChecks = 0
    func checkAgentFocus(withNavigationGeneration generation: UInt64, expectedRect: NSRect, pairing: Bool,
                         dispatchGate: (() -> Void) -> Bool, completion: (Bool, String?) -> Void) {
        precondition(pairing, "pairing fill must use its dedicated predicate")
        focusChecks += 1
        let dispatched = dispatchGate({})
        mutate?(self, "focusCheck")
        completion(focusOK && dispatched, focusReason)
    }
    var navigationGeneration: UInt64 = 7
    var currentURLString: String? = "https://fixture.invalid/bound"
    var zoomLevel: Double = 0
    var bounds = NSRect(x: 0, y: 0, width: 1100, height: 800)
    var busy = true
    var releases = 0, clicks = 0, sends = 0, inserted = 0
    var lastAgentKeyRefusal = ""
    var typeOK = true, typeReason = "browser_field_target_unavailable", typeCalls = 0
    var snapshotOK = true
    var mutate: ((FakeView, String) -> Void)?
    func releaseAgentKey() { busy = false; releases += 1 }
    func sendClick(at point: NSPoint, navigationGeneration: UInt64) -> Bool {
        precondition(navigationGeneration == self.navigationGeneration)
        clicks += 1
        mutate?(self, clicks == 1 ? "focus" : "submit")
        return true
    }
    func typeText(_ text: String, elementID: String, navigationGeneration: UInt64, submit: Bool, pairing: Bool,
                  dispatchGate: (() -> Void) -> Bool, completion: (Bool, String?) -> Void) {
        precondition(elementID == "cef-42" && navigationGeneration == self.navigationGeneration && submit && pairing)
        typeCalls += 1
        mutate?(self, "typeGate")
        let sent = dispatchGate({})
        if sent && typeOK { inserted = text.count; sends += 1 }
        completion(sent && typeOK, typeReason)
    }
}
@MainActor final class ChatGPTConnectorPod {
    let view: FakeView
    var connectLog: FakeLog? = FakeLog()
    init(_ view: FakeView) { self.view = view }
    func boundView(_ frame: HandsPodFrame) -> FakeView? { view }
    static func snapshot(_ view: FakeView) async -> String? {
        guard view.snapshotOK else { return nil }
        let form: [String: Any] = ["origin": "https://fixture.invalid", "navigationGeneration": 7,
            "viewport": ["width": 1100, "height": 800], "forms": [["actionOrigin": "https://fixture.invalid", "method": "POST", "fields": [
                ["type": "text", "elementID": "cef-42", "rect": ["x": 20, "y": 20, "width": 200, "height": 40]],
                ["type": "submit", "rect": ["x": 20, "y": 80, "width": 200, "height": 40]]]]]]
        let result = String(data: try! JSONSerialization.data(withJSONObject: form), encoding: .utf8)!
        view.mutate?(view, "snapshot")
        return result
    }
    // INSERT fillPairingCode
    // INSERT helpers
}
@main struct Checks {
    @MainActor static func main() async {
        var passes = 0
        func check(_ ok: Bool, _ label: String) {
            precondition(ok, label); passes += 1
        }
        func run(_ view: FakeView, code: String = "23456789") async -> HandsCodeFill {
            let pod = ChatGPTConnectorPod(view)
            let restores = NSApp.keyWindow!.restores
            let result = await pod.fillPairingCode(code, frame: HandsPodFrame(), evidence: "synthetic-bound-evidence", publicHost: "fixture.invalid")
            if view.clicks > 0 { check(NSApp.keyWindow!.restores == restores + 1, "previous key restored on every input exit") }
            if case .failed(let why) = result {
                let line = "autofill failed " + HandsConnectFlow.cleanStep(why)
                check(line.hasSuffix(why), "connect-log preserves the complete structured reason")
                check(!line.contains(code), "connect-log contains no synthetic code")
            }
            check(pod.connectLog?.lines.joined().contains(code) == false, "Pod log contains no synthetic code")
            return result
        }
        let parked = FakeView(); parked.window!.frame.origin = NSPoint(x: -30000, y: -30000)
        let activations = NSApp.activations
        check(await run(parked) == .failed("key:no_focus:parked") && parked.sends == 0 && parked.clicks == 0
              && parked.window!.fronts == 0 && NSApp.activations == activations, "parking refuses without activation or input")
        let noWindow = FakeView(); noWindow.window = nil
        check(await run(noWindow) == .failed("key:no_focus:no_window"), "detached view refuses")
        let noResponder = FakeView(); noResponder.window!.allowResponder = false
        check(await run(noResponder) == .failed("key:no_focus:responder") && noResponder.sends == 0, "responder failure refuses input")
        let noFocus = FakeView(); noFocus.focusOK = false
        check(await run(noFocus) == .failed("key:no_focus:browser_field_target_unavailable") && noFocus.sends == 0 && noFocus.clicks == 1,
              "document or wrong field focus failure refuses all keys and restores window")
        let checkNavigation = FakeView()
        checkNavigation.mutate = { v, event in if event == "focusCheck" { v.navigationGeneration += 1 } }
        check(await run(checkNavigation) == .failed("type:bound:gen_changed_1:url_changed_0:zoom_0:viewport_0") && checkNavigation.sends == 0,
              "focus callback navigation refuses keys")
        let residual = FakeView()
        check(await run(residual) == .filled, "residual key host is released before typing succeeds")
        check(residual.releases == 2 && !residual.busy && residual.sends == 1 && residual.typeCalls == 1 && residual.inserted == 8 && residual.clicks == 1,
              "all eight fake characters and submit, with cleanup")
        for reason in ["browser_field_target_unavailable", "browser_unavailable", "browser_action_result_unavailable"] {
            let view = FakeView(); view.typeOK = false; view.typeReason = reason
            check(await run(view) == .failed("type:" + reason), "native type failure forwarded")
            check(view.clicks == 1 && view.inserted == 0 && !view.busy && view.releases == 2, "failed typing does not submit and releases")
        }
        let changedFocus = FakeView()
        changedFocus.mutate = { v, event in if event == "focus" { v.navigationGeneration += 1 } }
        check(await run(changedFocus) == .failed("key:bound:gen_changed_1:url_changed_0:zoom_0:viewport_0") && changedFocus.typeCalls == 0,
              "navigation after click refuses focus and typing")
        let changedGate = FakeView()
        changedGate.mutate = { v, event in if event == "typeGate" { v.navigationGeneration += 1 } }
        check(await run(changedGate) == .failed("type:browser_field_target_unavailable") && changedGate.inserted == 0,
              "navigation at native dispatch gate refuses input and submission")
        for (condition, expected) in [("url", "url_changed_1:zoom_0:viewport_0"), ("zoom", "url_changed_0:zoom_1:viewport_0"),
                                      ("viewport", "url_changed_0:zoom_0:viewport_1")] {
            let view = FakeView()
            view.mutate = { v, event in
                guard event == "focusCheck" else { return }
                if condition == "url" { v.currentURLString = "https://fixture.invalid/other" }
                if condition == "zoom" { v.zoomLevel = 1 }
                if condition == "viewport" { v.bounds.size.width = 900 }
            }
            check(await run(view) == .failed("type:bound:gen_changed_0:" + expected), "changed \(condition) refuses typeText")
            check(view.inserted == 0 && view.typeCalls == 0 && view.clicks == 1 && !view.busy, "binding guards unchanged")
        }
        let changedBoth = FakeView()
        changedBoth.mutate = { v, event in if event == "focus" { v.navigationGeneration += 1; v.currentURLString = nil } }
        check(await run(changedBoth) == .failed("key:bound:gen_changed_1:url_changed_1:zoom_0:viewport_0"), "generation and URL evidence evaluated independently")
        let snapshot = FakeView()
        snapshot.mutate = { v, event in if event == "snapshot" { v.navigationGeneration += 1 } }
        check(await run(snapshot) == .failed("form:bound:gen_changed_1:url_changed_0:zoom_0:viewport_0") && snapshot.clicks == 0, "snapshot change refuses field click")
        let invalid = FakeView()
        check(await run(invalid, code: "00000000") == .failed("code") && invalid.clicks == 0 && invalid.releases == 0, "invalid fake code refuses before touching view")
        check(HandsConnectFlow.cleanStep("key:send:0:bad_args /?\n") == "key:send:0:bad_args", "sanitizer still rejects unsafe punctuation")
        print("W328 SWIFT SUMMARY passes=\(passes) failures=0")
    }
}
