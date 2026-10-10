#if DEBUG
import AppKit
import SwiftUI
import Combine
import ScreenCaptureKit

@MainActor enum W270DownloadAcceptance {
    static var passed = 0, failures = 0
    static var measurements: [[String: Any]] = []
    static func check(_ value: Bool, _ label: String) {
        print("W270 \(value ? "PASS" : "FAIL") \(label)")
        if value { passed += 1 } else { failures += 1 }
    }
    static func mouse(_ point: CGPoint, rig: TatwoComposerModeAcceptance.ClickRig) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.sendEvent(event) }
        }
    }
    static func point(_ label: String, browser: TatwoCEFBrowserView) async throws -> CGPoint {
        let snapshot = try await BrowserRuntimeAcceptance.snapshot(browser)
        guard let element = BrowserAgentBridge.uniqueElement(BrowserAgentBridge.clickElements(snapshot), selector: nil, label: label),
              let rect = element["rect"] as? [String: Any], let viewport = snapshot["viewport"] as? [String: Any],
              let p = BrowserAgentBridge.clickPoint(rect: rect, viewport: viewport, size: browser.bounds.size) else { throw TapError.remote("click target missing " + label + "; labels=" + String(describing: BrowserAgentBridge.clickElements(snapshot).map { $0["label"] ?? "nil" }) + "; viewport=" + String(describing: snapshot["viewport"])) }
        return browser.convert(CGPoint(x: p.x, y: browser.isFlipped ? p.y : browser.bounds.height - p.y), to: nil)
    }
    static func count(_ name: String, _ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return (layer.name == name ? 1 : 0) + (layer.sublayers ?? []).reduce(0) { $0 + count(name, $1) }
    }
    static func files(_ layer: CALayer?) -> Int { count("download.file", layer) }
    static func particles(_ rig: TatwoComposerModeAcceptance.ClickRig) -> Int {
        TatwoComposerModeAcceptance.views(BrowserDownloadFlight.Overlay.self, in: rig.host).reduce(0) { $0 + count("download.spark", $1.layer) }
    }
    static func capture(_ rig: TatwoComposerModeAcceptance.ClickRig) async throws -> (SCContentFilter, SCStreamConfiguration) {
        rig.window.alphaValue = 1; rig.window.displayIfNeeded()
        await rig.settle(2)
        guard #available(macOS 14.4, *) else { throw TapError.remote("own-process capture requires macOS 14.4") }
        let content: SCShareableContent = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getCurrentProcessShareableContent { value, error in
                if let value { continuation.resume(returning: value) } else { continuation.resume(throwing: error ?? TapError.remote("own window enumeration failed")) }
            }
        }
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(rig.window.windowNumber) }) else { throw TapError.remote("own window missing") }
        let config = SCStreamConfiguration(); config.width = Int(rig.size.width * rig.window.backingScaleFactor); config.height = Int(rig.size.height * rig.window.backingScaleFactor)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        return (SCContentFilter(desktopIndependentWindow: window), config)
    }
    static func shot(_ name: String, rig: TatwoComposerModeAcceptance.ClickRig, capture: (SCContentFilter, SCStreamConfiguration), folder: URL, start: Double, at milliseconds: Int) async throws {
        try await Task.sleep(for: .seconds(max(0, start + Double(milliseconds)/1000 - ProcessInfo.processInfo.systemUptime)))
        rig.window.displayIfNeeded()
        let at = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let image = try await SCScreenshotManager.captureImage(contentFilter: capture.0, configuration: capture.1)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw TapError.remote("PNG unavailable") }
        try data.write(to: folder.appendingPathComponent(name + ".png"))
        measurements.append(["shot": name, "requestedMs": milliseconds, "captureMs": at])
        print("W270 SHOT \(name) requested=\(milliseconds) actual=\(String(format: "%.1f", at))ms")
    }
    static func sequence(_ prefix: String, browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig, origin: String, folder: URL, full: Bool = false, reduced: Bool = false, floating: Bool = true) async throws {
        let downloads = BrowserDownloadStore.shared, flight = BrowserDownloadFlight.shared
        downloads.clearDownloads(); downloads.markDownloadsSeen()
        var loading = true
        let previousState = browser.stateHandler
        browser.stateHandler = { a, b, c, d, isLoading, f, g, h, i, j in loading = isLoading; previousState?(a, b, c, d, isLoading, f, g, h, i, j) }
        defer { browser.stateHandler = previousState }
        browser.loadURLString(origin + "/page/slow-" + prefix)
        check(await BrowserRuntimeAcceptance.waitUntil { browser.currentURLString == origin + "/page/slow-" + prefix && !loading }, prefix + " local human page")
        await rig.settle()
        check(browser.browserActor == .human && !browser.agentControlled, prefix + " real human CEF")
        rig.window.makeKeyAndOrderFront(nil)
        let capture = try await capture(rig)
        let click = try await point("Download slow", browser: browser)
        let oldIDs = Set(downloads.downloads.map(\.id))
        let start = ProcessInfo.processInfo.systemUptime
        mouse(click, rig: rig)
        try await shot(prefix + "-0", rig: rig, capture: capture, folder: folder, start: start, at: 0)
        check(await W268DownloadAcceptance.wait(0.3) { downloads.downloads.contains { !oldIDs.contains($0.id) } }, prefix + " native mouse starts download")
        guard let item = downloads.downloads.first(where: { !oldIDs.contains($0.id) }) else { return }
        let scope = flight.routes[item.id] ?? "missing"
        _ = await W268DownloadAcceptance.wait(0.25) {
            rig.host.layoutSubtreeIfNeeded()
            return TatwoComposerModeAcceptance.views(BrowserDownloadFlight.Marker.self, in: rig.host).contains { $0.anchor && $0.scope == scope && $0.bounds.width > 0 }
        }
        let markers = TatwoComposerModeAcceptance.views(BrowserDownloadFlight.Marker.self, in: rig.host)
        let host = markers.first { !$0.anchor && $0.scope == scope }
        let anchor = markers.first { $0.anchor && $0.scope == scope }
        check(host != nil && anchor != nil, prefix + " registered page and target")
        if !reduced {
            let ripples = TatwoComposerModeAcceptance.views(BrowserDownloadFlight.Overlay.self, in: rig.host).flatMap { $0.layer?.sublayers ?? [] }.filter { $0.name == "download.ripple" }
            let delay = (ripples.last?.animation(forKey: "opacity")?.beginTime ?? 0) - (ripples.first?.animation(forKey: "opacity")?.beginTime ?? 0)
            check(ripples.count == 2 && particles(rig) == 8 && abs(delay - 0.11) < 0.002, prefix + " two ripples 110ms apart and eight sparks")
        }
        if full { try await shot(prefix + "-150", rig: rig, capture: capture, folder: folder, start: start, at: 150) }
        try await shot(prefix + "-400", rig: rig, capture: capture, folder: folder, start: start, at: 400)
        if reduced {
            check(flight.evidence.allSatisfy { $0.id != item.id } && (flight.overlay?.superview == nil || files(flight.overlay?.layer) == 0) && particles(rig) == 0, prefix + " reduced no file or particles")
        } else {
            let evidence = flight.evidence.last { $0.id == item.id }
            let error = evidence.map { hypot($0.start.x - click.x, $0.start.y - click.y) } ?? 999
            if let evidence { measurements.append(["download": prefix, "originX": evidence.start.x, "originY": evidence.start.y, "targetX": evidence.end.x, "targetY": evidence.end.y, "originErrorPt": error, "fileCount": files(flight.overlay?.layer)]) }
            check(evidence?.recent == true && error < 2, prefix + " recent click origin error=\(error)pt")
            check(files(flight.overlay?.layer) == 1, prefix + " exactly one file in flight")
            if let evidence, let anchor {
                let center = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
                let error = hypot(center.x - evidence.end.x, center.y - evidence.end.y)
                check(error < 2, prefix + " target center error=\(error)pt")
            }
            if let overlay = flight.overlay { check(overlay.hitTest(.zero) == nil, prefix + " animation overlay passes clicks") }
        }
        if floating { check(anchor != nil && flight.feedback(scope) != nil, prefix + " floating target visible") }
        // Click the actual webpage input while the file is flying, then type through NSWindow.
        let input = browser.convert(CGPoint(x: 140, y: browser.isFlipped ? 85 : browser.bounds.height - 85), to: nil)
        mouse(input, rig: rig)
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: rig.window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) { rig.window.sendEvent(event) }
        if full { try await shot(prefix + "-800", rig: rig, capture: capture, folder: folder, start: start, at: 800) }
        try await shot(prefix + "-1200", rig: rig, capture: capture, folder: folder, start: start, at: 1200)
        let snapshot = try await BrowserRuntimeAcceptance.snapshot(browser)
        check(String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)?.contains("Focus:INPUT Typed:x") == true, prefix + " input receives click and typing during animation")
        check(await W268DownloadAcceptance.wait(1) { W268DownloadAcceptance.marker("card", in: rig) != nil }, prefix + " landing card rendered")
        if !scope.hasPrefix("browser") || floating, let card = W268DownloadAcceptance.marker("card", in: rig), let host {
            let cardRect = host.convert(card.bounds, from: card)
            check(host.bounds.insetBy(dx: -1, dy: -1).contains(cardRect), prefix + " card stays within webpage")
        }
        print("W270 awaiting completion " + prefix)
        check(await W268DownloadAcceptance.wait(12) { downloads.downloads.first { $0.id == item.id }?.done == true }, prefix + " real CEF completes")
        try await shot(prefix + "-complete", rig: rig, capture: capture, folder: folder, start: ProcessInfo.processInfo.systemUptime, at: 180)
        check(await W268DownloadAcceptance.wait(0.3) { W268DownloadAcceptance.marker("indicator", in: rig)?.phase == "completed" }, prefix + " rendered checkmark")
        check(particles(rig) == (reduced ? 0 : 6), prefix + " completion particles=\(particles(rig))")
        let deadline = flight.deadlines[item.id] ?? Date()
        check(await W268DownloadAcceptance.wait(5) { flight.dismissed.contains(item.id) }, prefix + " feedback dismisses")
        let error = Date().timeIntervalSince(deadline)
        check(abs(error) < 0.25, prefix + " dismissal at 4s error=\(String(format: "%.3f", error))s")
        if full { try await shot(prefix + "-complete-plus-5s", rig: rig, capture: capture, folder: folder, start: ProcessInfo.processInfo.systemUptime, at: 1000) }
        // 10-07 使用者：下載鈕下載完留著，按「清除紀錄」才消失。
        func targets() -> Bool { TatwoComposerModeAcceptance.views(BrowserDownloadFlight.Marker.self, in: rig.host).contains { $0.anchor && $0.scope == scope } }
        check(targets(), prefix + " download target stays after completion")
        BrowserDownloadStore.shared.clearDownloads()
        check(await W268DownloadAcceptance.wait(0.5) { !targets() }, prefix + " download target gone after clear")
    }
    static func run(store: BrowserWorkSpaceStore, runtime: BrowserWorkSpaceRuntime, browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig, scene: W268DownloadAcceptance.SceneState, origin: String, folder: URL) async throws -> Bool {
        let themes = TatwoThemeSelfTestScope(); themes.use(.fable5); defer { themes.restore() }
        let shots = folder.appendingPathComponent("w270-shots"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        // Read the approved HTML in the real human browser, with no external requests.
        browser.loadURLString(origin + "/prototype")
        check(await BrowserRuntimeAcceptance.waitUntil { browser.currentURLString == origin + "/prototype" }, "A2 prototype open in real CEF browser")
        await rig.settle()
        let prototypeCapture = try await capture(rig)
        let p = try await point("Download Notchy", browser: browser)
        mouse(p, rig: rig)
        try await shot("prototype-A2-400", rig: rig, capture: prototypeCapture, folder: folder, start: ProcessInfo.processInfo.systemUptime, at: 400)
        for dark in [false, true] {
            scene.dark = dark; rig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for collapsed in [false, true] {
                store.focusMode = collapsed
                try await sequence("\(dark ? "dark" : "light")-\(collapsed ? "collapsed" : "expanded")", browser: browser, rig: rig, origin: origin, folder: shots, full: true, floating: collapsed)
            }
        }
        scene.reduced = true; store.focusMode = true
        try await sequence("reduced", browser: browser, rig: rig, origin: origin, folder: shots, reduced: true)
        scene.reduced = false
        try await keyboardAndQueue(browser: browser, rig: rig, origin: origin)
        try await fallback(browser: browser, origin: origin, folder: shots)
        rig.window.orderOut(nil)
        try await otherSurfaces(origin: origin, folder: shots)
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("w270-measurements.json"))
        print("W270 SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
    static func keyboardAndQueue(browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig, origin: String) async throws {
        let store = BrowserDownloadStore.shared, flight = BrowserDownloadFlight.shared
        store.clearDownloads()
        browser.loadURLString(origin + "/page/slow-keyboard")
        check(await BrowserRuntimeAcceptance.waitUntil { browser.currentURLString == origin + "/page/slow-keyboard" }, "keyboard local page")
        await rig.settle()
        check(flight.click.map { ProcessInfo.processInfo.systemUptime - $0.time > 5 } ?? true, "recent click expires after 5s")
        for (text, code) in [("\t", UInt16(48)), ("\r", UInt16(36))] {
            if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) { rig.window.sendEvent(key) }
            try await Task.sleep(for: .milliseconds(30))
        }
        check(await W268DownloadAcceptance.wait(2) { flight.evidence.contains { $0.id == store.downloads.first?.id } }, "keyboard starts real CEF flight")
        if let item = store.downloads.first, let evidence = flight.evidence.last(where: { $0.id == item.id }),
           let host = TatwoComposerModeAcceptance.views(BrowserDownloadFlight.Marker.self, in: rig.host).first(where: { !$0.anchor && $0.scope == evidence.scope }) {
            let rect = host.convert(host.bounds, to: nil)
            let error = hypot(evidence.start.x - rect.midX, evidence.start.y - (rect.minY + rect.height * 0.3))
            check(!evidence.recent && error < 2, "keyboard lower-center fallback error=\(error)pt")
            check(await W268DownloadAcceptance.wait(12) { store.downloads.first { $0.id == item.id }?.done == true }, "keyboard download completes")
            _ = await W268DownloadAcceptance.wait(5) { flight.dismissed.contains(item.id) }
        }
        store.clearDownloads()
        var starts: [String: CGPoint] = [:]
        for suffix in ["one", "two", "three"] {
            let url = origin + "/page/slow-queue-" + suffix
            browser.loadURLString(url)
            check(await BrowserRuntimeAcceptance.waitUntil { browser.currentURLString == url }, "queue " + suffix + " page")
            await rig.settle(2)
            let point = try await point("Download slow", browser: browser)
            mouse(point, rig: rig)
            check(await W268DownloadAcceptance.wait(0.3) { store.downloads.contains { $0.filename == "slow-queue-" + suffix + ".bin" } }, "queue " + suffix + " real CEF start")
            if let item = store.downloads.first(where: { $0.filename == "slow-queue-" + suffix + ".bin" }) { starts[item.id] = point }
        }
        var maximum = 0
        for _ in 0..<90 {
            let count = TatwoComposerModeAcceptance.views(BrowserDownloadFlight.Overlay.self, in: rig.host).reduce(0) { $0 + files($1.layer) }
            maximum = max(maximum, count)
            try await Task.sleep(for: .milliseconds(30))
        }
        check(maximum == 1 && starts.count == 3, "queue maximum simultaneous file count=\(maximum)")
        let evidence = flight.evidence.filter { starts[$0.id] != nil }
        check(evidence.count == 2 && evidence.allSatisfy { sample in starts[sample.id].map { hypot($0.x - sample.start.x, $0.y - sample.start.y) < 2 } == true }, "queue both files fly from their original clicks")
        check(store.downloads.filter { $0.filename == "slow-queue-three.bin" }.allSatisfy { item in flight.landed.contains(item.id) && !flight.evidence.contains { $0.id == item.id } }, "queue excess download lands directly")
        check(await W268DownloadAcceptance.wait(12) { store.active.isEmpty && store.downloads.count == 3 && store.downloads.allSatisfy(\.done) }, "queue all three real downloads complete")
        _ = await W268DownloadAcceptance.wait(5) { starts.keys.allSatisfy { flight.dismissed.contains($0) } }
    }
    struct PlainSurface: NSViewRepresentable {
        let page: TatwoCEFBrowserView
        func makeNSView(context: Context) -> TatwoCEFContainerView { TatwoCEFContainerView(frame: .zero) }
        func updateNSView(_ view: TatwoCEFContainerView, context: Context) { if view.browserView !== page { view.mountBorrowedBrowser(page) } }
        static func dismantleNSView(_ view: TatwoCEFContainerView, coordinator: ()) { view.detachBorrowedBrowser() }
    }
    static func fallback(browser: TatwoCEFBrowserView, origin: String, folder: URL) async throws {
        let page = try TatwoCEFBrowserView(frame: .zero, sharingContextWith: browser, initialURL: origin + "/page/slow-fallback", actor: .human)
        BrowserHumanInteraction.shared.configure(page, onForegroundTab: { [weak page] in page?.loadURLString($0.absoluteString) }) { [weak page] in page?.loadURLString($0.absoluteString) }
        let rig = TatwoComposerModeAcceptance.ClickRig(PlainSurface(page: page), size: CGSize(width: 360, height: 450))
        defer { rig.close(); page.closeBrowser() }
        check(rig.moveOnScreen(), "unregistered human window on screen")
        check(await BrowserRuntimeAcceptance.waitUntil { page.currentURLString == origin + "/page/slow-fallback" && page.navigationGeneration > 0 }, "unregistered local page")
        await rig.settle()
        let capture = try await capture(rig)
        mouse(try await point("Download slow", browser: page), rig: rig)
        let store = BrowserDownloadStore.shared, flight = BrowserDownloadFlight.shared
        check(await W268DownloadAcceptance.wait(0.5) { store.downloads.contains { $0.filename == "slow-fallback.bin" } }, "unregistered real CEF start")
        guard let item = store.downloads.first(where: { $0.filename == "slow-fallback.bin" }) else { return }
        check(flight.routes[item.id]?.hasPrefix("fallback-") == true && !flight.evidence.contains { $0.id == item.id }, "no anchor shows card without flight")
        check(await W268DownloadAcceptance.wait(0.3) { W268DownloadAcceptance.marker("card", in: rig) != nil }, "fallback native card visible")
        await rig.settle()
        if let card = W268DownloadAcceptance.marker("card", in: rig) {
            let frame = rig.host.convert(card.bounds, from: card)
            check(rig.host.bounds.contains(frame) && frame.width >= 250 && frame.height >= 50, "fallback card bounds inside window \(frame)")
        }
        try await shot("fallback-card", rig: rig, capture: capture, folder: folder, start: ProcessInfo.processInfo.systemUptime, at: 0)
        check(await W268DownloadAcceptance.wait(12) { store.downloads.first { $0.id == item.id }?.done == true }, "fallback download completes")
        check(await W268DownloadAcceptance.wait(5) { flight.dismissed.contains(item.id) }, "fallback card dismisses")
    }
    static func otherSurfaces(origin: String, folder: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let pod = TapWebPod(podID: "w270-fixture", profileID: UUID(), homeURL: URL(string: origin + "/page/slow-gpt")!, script: #"(report)=>{document.addEventListener('DOMContentLoaded',()=>report(JSON.stringify({type:'hello',loggedIn:true})));return true;}"#)
        guard let stagingRoot = Bundle.main.object(forInfoDictionaryKey: "TatwoStagingRoot") as? String,
              let rootCache = TatwoCEFProfileLocationResolver.rootCacheURL(stagingRootURL: URL(fileURLWithPath: stagingRoot), bundleURL: Bundle.main.bundleURL),
              let helper = EmbeddedBrowserEnginePolicy.helperExecutableURL(in: .main) else { throw TapError.remote("isolated Pod profile required") }
        pod.selfTestLocation = try TatwoCEFProfileLocationResolver.resolve(profile: pod.profile, rootCacheURL: rootCache, authorityStagingRootURL: URL(fileURLWithPath: stagingRoot), helperExecutablePath: helper.path, logFilePath: rootCache.deletingLastPathComponent().appendingPathComponent("cef-logs/cef.log").path)
        let tap = ChatGPTTap(transport: pod, connection: .sleeping)
        let root = URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        var modelEnv = env; modelEnv["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "1"
        let model = ChatPageModel(environment: modelEnv, botCoreFixture: (engine, BotStore(root: root)))
        model.mode = .chatgpt
        ChatGPTWebSpace.tapForSelfTest = tap
        defer { ChatGPTWebSpace.tapForSelfTest = nil; tap.sleep() }
        let gpt = TatwoComposerModeAcceptance.ClickRig(ChatPage(model: model).environment(\.tatwoSurfaceKind, .window), size: CGSize(width: 1000, height: 700))
        check(gpt.moveOnScreen(), "production GPT window on screen")
        check(await BrowserRuntimeAcceptance.waitUntil { pod.spacePage?.window === gpt.window }, "production GPT mounts CEF")
        guard let page = pod.spacePage else { throw TapError.remote("GPT page missing") }
        try await sequence("gpt", browser: page, rig: gpt, origin: origin, folder: folder)
        gpt.close(); await gpt.settle()
        let suite = "w270-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dmStore = GlobalDMStore(defaults: defaults, chatGPT: { ChatGPTConversationSession(tap: tap) }, chatGPTAllowed: { true }, chatGPTCatalog: { Just(ChatGPTModelCatalog()).eraseToAnyPublisher() }, directKeys: false, recentApps: defaults)
        dmStore.attach(model); dmStore.select(.chatGPT)
        let form = GlobalDMForm.outerPortrait
        let dm = TatwoComposerModeAcceptance.ClickRig(GlobalDMPhoneBox(store: dmStore, model: model, surface: .floating, form: form), size: form.size)
        defer { dm.close() }
        check(dm.moveOnScreen(), "production DM window on screen")
        check(await BrowserRuntimeAcceptance.waitUntil { page.window === dm.window }, "production DM mounts same human page")
        try await sequence("dm", browser: page, rig: dm, origin: origin, folder: folder)
        // Both DM segments are production pages; pin the fixture URL before mounting Dots.
        let dots = try pod.openDotsSpacePage(); dots.loadURLString(origin + "/page/slow-dots")
        await dm.settle()
        guard let frame = ChatGPTWebSpace.tabFramesForSelfTest[true] else { throw TapError.remote("Dots segment missing") }
        mouse(dm.host.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil), rig: dm)
        check(await BrowserRuntimeAcceptance.waitUntil { dots.window === dm.window }, "DM Dots mounted")
        try await sequence("dots", browser: dots, rig: dm, origin: origin, folder: folder)
        dm.window.orderOut(nil)
        let coderModel = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        let session = UUID().uuidString
        let runtime = BrowserWorkSpaceRuntime.forChat(session, registry: coderModel.browserTabRegistry)
        await runtime.authorize()
        let tab = coderModel.browserTabRegistry.openTab(owner: .chatSession(sessionID: session), url: URL(string: origin + "/page/slow-coder")!, title: "W270 local")
        coderModel.browserTabRegistry.select(tab.id)
        let coder = TatwoComposerModeAcceptance.ClickRig(EmbeddedBrowserView(sessionID: session, model: coderModel), size: CGSize(width: 640, height: 700))
        defer { coder.close() }
        check(coder.moveOnScreen(), "production Coder right panel on screen")
        check(await BrowserRuntimeAcceptance.waitUntil { TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: coder.host).first?.currentURLString == origin + "/page/slow-coder" }, "Coder mounts real CEF")
        guard let coderPage = TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: coder.host).first else { throw TapError.remote("Coder page missing isLive=\(model.isLive)") }
        try await sequence("coder", browser: coderPage, rig: coder, origin: origin, folder: folder, floating: false)
    }
}
#endif
