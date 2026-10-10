#if DEBUG
import AppKit
import TatwoCEFBridge

/// Real CEF, disposable loopback page; never loads ChatGPT or a real profile.
@MainActor enum W294ePodSizeAcceptance {
    final class Transport: ChatGPTPodTransport {
        let pod: TapWebPod
        var onEvent: ((String) -> Void)?
        var measured: [Int] = []
        var scans = 0
        var dropScan = false
        init(_ pod: TapWebPod) {
            self.pod = pod
            pod.onEvent = { [weak self] json in
                if let data = json.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let size = object["viewport"] as? [Int] { self?.measured = size }
                self?.onEvent?(json)
            }
        }
        var isRunning: Bool { pod.isRunning }
        var isHosted: Bool { pod.isHosted }
        func start() throws { try pod.start() }
        func stop() { pod.stop() }
        func setSpaceVisible(_ visible: Bool) { pod.setSpaceVisible(visible) }
        func setBackgroundWorkActive(_ active: Bool) { pod.setBackgroundWorkActive(active) }
        func beginConnectorViewport() { pod.beginConnectorViewport() }
        func endConnectorViewport() { pod.endConnectorViewport() }
        func run(_ script: String) {
            if script.contains("connectorScan") { scans += 1; if dropScan { return } }
            // Same loopback exception as the existing W248 fixture transport.
            pod.run(script.replacingOccurrences(of: "location.host==='chatgpt.com'&&", with: ""))
        }
    }

    static func run(pod: TapWebPod, folder: URL, origin: String) async throws {
        guard let browser = pod.browser else { throw TapError.remote("W294E missing CEF Pod") }
        let previousEvent = pod.onEvent, previousFrame = pod.onMainFrame, previousPopup = pod.onPopup
        let transport = Transport(pod)
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let connector = ChatGPTConnectorPod(tap: tap, surface: { pod })
        connector.preparesPluginsPage = false   // 這裡只量 Pod 尺寸；W334 的整頁載入由 w334／w298a 自測驗
        connector.connectLog = HandsConnectLog(url: folder.appendingPathComponent("w294e-connect-log.txt"))
        connector.restoreTimeout = 0.05
        connector.attach()
        // W334：連接器現在連同頁換網址也記；本機假頁面在 loopback，照 Transport 的 chatgpt.com 例外把它當成 chatgpt.com。
        let attachedFrame = pod.onMainFrame
        pod.onMainFrame = { url, generation, loading, status in
            attachedFrame?(url.map { $0.hasPrefix(origin) ? "https://chatgpt.com" + String($0.dropFirst(origin.count)) : $0 }, generation, loading, status)
        }
        // Seed native frame evidence through the same callback as CEF.
        pod.onMainFrame?("https://chatgpt.com/", browser.navigationGeneration, false, 200)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 225, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 225, height: 540))
        window.contentView = container
        window.orderFrontRegardless()
        let other = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 500))
        let guardLease = pod.beginGuardedPresentation()
        pod.showGuarded(container, lease: guardLease)
        let frame = NSRect(x: 0, y: 0, width: 225, height: 540)
        let mask: NSView.AutoresizingMask = [.width, .minYMargin]
        browser.frame = frame; browser.autoresizingMask = mask
        var passes = 0
        func check(_ value: Bool, _ label: String) throws {
            print("W294E \(value ? "PASS" : "FAIL") \(label)")
            guard value else { throw TapError.remote("W294E " + label) }
            passes += 1
        }
        func restored(_ label: String) throws {
            try check(browser.superview === container && browser.frame == frame && browser.autoresizingMask == mask,
                      label + " restores original container, frame and autoresizing")
        }
        func settle() async -> Bool {
            var done = false
            connector.whenSettled { done = true }
            return await BrowserRuntimeAcceptance.waitUntil { done }
        }
        defer {
            pod.endConnectorViewport()
            pod.endGuardedPresentation(guardLease)
            pod.release(other)
            window.close()
            pod.onEvent = previousEvent; pod.onMainFrame = previousFrame; pod.onPopup = previousPopup
        }
        try await W328PairfillAcceptance.run(pod: pod)
        pod.run("window.__tatwoPod.command({cmd:'connectorViewport',id:'before'})")
        try check(await BrowserRuntimeAcceptance.waitUntil { transport.measured == [225, 540] },
                  "original small container gives the real web viewport 225x540")
        let models = try await tap.models()
        try check(models.items.map(\.title) == ["Desktop fixture model"] && transport.measured == [1100, 800],
                  "W309 models reads desktop catalog from narrow 225x540 page")
        try restored("W309 models success")
        pod.beginConnectorViewport()
        _ = try await tap.models()
        try check(browser.frame.size == NSSize(width: 1100, height: 800), "W309 models preserves concurrent connector viewport")
        pod.endConnectorViewport()
        try restored("W309 final viewport user")
        transport.onEvent?(#"{"type":"hello","loggedIn":false}"#)
        do { _ = try await tap.models(); try check(false, "W309 models rejects unavailable transport") }
        catch { try restored("W309 models failure") }
        transport.onEvent?(#"{"type":"hello","loggedIn":true}"#)
        for mode in ["success", "error", "cancel", "timeout"] {
            transport.measured = []; transport.dropScan = mode == "timeout"
            let scans = transport.scans
            try check(await connector.acquireExclusive(timeout: 1), mode + " acquires exclusive Pod")
            try restored(mode + " idle hold / manual mode")
            let task = Task { await connector.scan(url: "https://fixture.invalid/" + mode) }
            try check(await BrowserRuntimeAcceptance.waitUntil { transport.scans > scans }, mode + " dispatches connectorScan")
            try check(browser.superview !== container && browser.frame.size == NSSize(width: 1100, height: 800)
                      && browser.window?.isVisible == true && !browser.isHidden, mode + " request parks visible CEF off screen at 1100x800")
            if mode == "cancel" {
                task.cancel(); connector.releaseExclusive()
            } else {
                pod.claim(other)
                pod.showGuarded(container, lease: guardLease)
                try check(browser.superview !== container && browser.superview !== other,
                          mode + " host updates cannot shrink the leased viewport")
                if mode == "timeout" {
                    pod.run("window.__tatwoPod.command({cmd:'connectorViewport',id:'viewport'})")
                    try check(await BrowserRuntimeAcceptance.waitUntil { transport.measured.count == 2 }, "timeout measures real web viewport")
                }
            }
            let scan = await task.value
            try restored(mode + " request ended before hold release")
            if mode != "cancel" {
                try check(transport.measured.count == 2 && transport.measured[0] >= 1000 && transport.measured[1] >= 700,
                          mode + " connectorScan web innerWidth >= 1000 and innerHeight >= 700: \(transport.measured)")
                try check(mode == "success" ? scan.listKnown : scan.failure != nil, mode + " returns expected result")
                connector.releaseExclusive()
            }
            try check(await settle(), mode + " cleanup settles")
            try restored(mode)
        }
        try check(connector.connectLog!.tail().filter { $0.contains("pod viewport before=225x540 during=1100x800") }.count == 4,
                  "each scan logs only numeric viewport sizes")

        try check(await connector.acquireExclusive(timeout: 1), "two requests share one hold")
        transport.dropScan = false
        for index in 1...2 {
            let scan = await connector.scan(url: "https://fixture.invalid/success")
            try check(scan.listKnown && transport.measured[0] >= 1000, "request \(index) uses desktop web viewport")
            try restored("between requests \(index)")
        }
        let overlappingScans = transport.scans
        let firstScan = Task { await connector.scan(url: "https://fixture.invalid/success") }
        let secondScan = Task { await connector.scan(url: "https://fixture.invalid/success") }
        try check(await BrowserRuntimeAcceptance.waitUntil { transport.scans == overlappingScans + 2 }, "W309 concurrent connector requests start")
        _ = try await tap.models()
        try check(browser.frame.size == NSSize(width: 1100, height: 800), "W309 model completion preserves both connector requests")
        let firstResult = await firstScan.value, secondResult = await secondScan.value
        try check(firstResult.listKnown && secondResult.listKnown, "W309 both concurrent connector requests complete")
        try restored("W309 concurrent requests")
        let action = await connector.create(url: "https://fixture.invalid/mcp", acknowledged: nil)
        if case .needsUser = action { try check(true, "create returns needs_manual") }
        else { try check(false, "create returns needs_manual") }
        try restored("needs_manual waits on the human surface")
        _ = await connector.pointAtGesture(url: "https://fixture.invalid/mcp", name: "fixture")
        try restored("human gesture requests stay on the human surface")
        transport.onEvent?(#"{"type":"hello","loggedIn":false}"#)
        try check(tap.connection == .needsLogin, "fixture enters login wait")
        try restored("login wait")
        transport.onEvent?(#"{"type":"hello","loggedIn":true}"#)
        connector.releaseExclusive()
        try check(await settle(), "manual and login cleanup settles")

        for mode in ["removed", "replaced", "released"] {
            try check(await connector.acquireExclusive(timeout: 1), mode + " acquires hold")
            let scans = transport.scans
            let task = Task { await connector.scan(url: "https://fixture.invalid/success") }
            try check(await BrowserRuntimeAcceptance.waitUntil { transport.scans > scans }, mode + " starts request")
            if mode == "released" { pod.showGuarded(nil, lease: guardLease) }
            else {
                window.contentView = other
                if mode == "replaced" { pod.showGuarded(other, lease: guardLease) }
            }
            _ = await task.value
            try check(browser.superview !== container, mode + " never restores into stale parent")
            try check(mode == "replaced" ? browser.superview === other && browser.frame == other.bounds :
                      pod.placementTarget == nil && browser.window !== window && browser.frame.size == NSSize(width: 1100, height: 800),
                      mode + " follows current lease or parks")
            window.contentView = container
            pod.showGuarded(container, lease: guardLease)
            browser.frame = frame; browser.autoresizingMask = mask
            connector.releaseExclusive()
            try check(await settle(), mode + " cleanup settles")
        }
        try check(await connector.acquireExclusive(timeout: 1), "termination acquires exclusive Pod")
        let scans = transport.scans
        let task = Task { await connector.scan(url: "https://fixture.invalid/success") }
        try check(await BrowserRuntimeAcceptance.waitUntil { transport.scans > scans }, "termination starts request")
        await Task.detached { NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil) }.value
        try check(await BrowserRuntimeAcceptance.waitUntil { browser.superview === container }, "background termination restores on main actor")
        try restored("App termination")
        _ = await task.value
        connector.releaseExclusive()
        try check(await settle(), "termination cleanup settles")
        print("W294E SUMMARY passes=\(passes) failures=0")
    }
}
#endif
