#if DEBUG
import AppKit
import Foundation
import SwiftUI

@MainActor enum W269GPTChromeAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let artifacts = env["TATWO2_SELFTEST_ARTIFACTS"], let scratch = env["TMPDIR"] else {
            throw TapError.remote("isolated fixture environment required")
        }
        guard TatwoCEFRuntime.compiled else { throw TapError.remote("real CEF build required; stub is not acceptance") }
        if Bundle.main.bundleIdentifier == nil {
            guard let receipt = env["TATWO2_W248_CEF_RECEIPT"],
                  let data = try? Data(contentsOf: URL(fileURLWithPath: receipt)),
                  let item = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let binary = item["binary"], let root = item["scratch"],
                  root.hasPrefix(URL(fileURLWithPath: scratch).standardizedFileURL.path + "/"),
                  binary.hasPrefix(root + "/W248.app/") else { throw TapError.remote("missing scratch CEF App receipt") }
            let folder = URL(fileURLWithPath: artifacts)
            let fixture = folder.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            try Data(server.utf8).write(to: fixture.appendingPathComponent("server.py"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [fixture.appendingPathComponent("server.py").path, fixture.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let portFile = fixture.appendingPathComponent("port")
            guard await BrowserRuntimeAcceptance.waitUntil({ FileManager.default.fileExists(atPath: portFile.path) }),
                  let port = Int(try String(contentsOf: portFile).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw TapError.remote("local fixture server failed")
            }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: binary)
            // Chromium test storage avoids the real macOS keychain in this disposable profile.
            child.arguments = ["--use-mock-keychain"]
            var isolated = env
            isolated.removeValue(forKey: "DYLD_FRAMEWORK_PATH")
            isolated["TATWO_STAGING_ALLOW_BROWSER_LOOPBACK"] = "1"
            isolated["TATWO_STAGING_BROWSER_LOOPBACK_PORT"] = String(port)
            child.environment = isolated
            child.standardOutput = FileHandle.standardOutput
            child.standardError = FileHandle.standardError
            return try await withCheckedThrowingContinuation { continuation in
                child.terminationHandler = { process in continuation.resume(returning: process.terminationStatus == 0) }
                do { try child.run() } catch { continuation.resume(throwing: error) }
            }
        }
        guard Bundle.main.bundleIdentifier == "ai.tatwo.tatwo2.staging.w248", NSApp is TatwoCEFApplication else {
            throw TapError.remote("fixture CEF application required")
        }
        let folder = URL(fileURLWithPath: artifacts)
        guard let portText = env["TATWO_STAGING_BROWSER_LOOPBACK_PORT"], let port = Int(portText),
              env["TATWO_STAGING_ALLOW_BROWSER_LOOPBACK"] == "1",
              CommandLine.arguments.contains("--use-mock-keychain") else {
            throw TapError.remote("staging loopback fixture required before CEF startup")
        }
        let origin = "http://127.0.0.1:\(port)"
        var passed = 0
        func check(_ value: Bool, _ label: String) throws {
            print("W269 \(value ? "PASS" : "FAIL") \(label)")
            guard value else { throw TapError.remote(label) }
            passed += 1
        }
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var flags = arguments
        flags[ChatGPTWebSpace.enabledKey] = true
        flags[ChatGPTTap.enabledKey] = false
        flags["tatwo.sidebar.pinned"] = true
        defaults.setVolatileDomain(flags, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let pod = TapWebPod(podID: "w269-fixture", profileID: UUID(), homeURL: URL(string: origin)!, script: #"(report)=>{document.addEventListener('DOMContentLoaded',()=>report(JSON.stringify({type:'hello',loggedIn:true})));return true;}"#)
        guard let stagingRoot = Bundle.main.object(forInfoDictionaryKey: "TatwoStagingRoot") as? String,
              let rootCache = TatwoCEFProfileLocationResolver.rootCacheURL(stagingRootURL: URL(fileURLWithPath: stagingRoot), bundleURL: Bundle.main.bundleURL),
              let helper = EmbeddedBrowserEnginePolicy.helperExecutableURL(in: .main) else { throw TapError.remote("scratch CEF profile required") }
        pod.selfTestLocation = try TatwoCEFProfileLocationResolver.resolve(profile: pod.profile,
            rootCacheURL: rootCache, authorityStagingRootURL: URL(fileURLWithPath: stagingRoot), helperExecutablePath: helper.path,
            logFilePath: rootCache.deletingLastPathComponent().appendingPathComponent("cef-logs/cef.log").path)
        let tap = ChatGPTTap(transport: pod, connection: .sleeping)
        ChatGPTWebSpace.tapForSelfTest = tap
        defer { ChatGPTWebSpace.tapForSelfTest = nil; tap.sleep() }
        let root = URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        var fixtureEnv = env
        fixtureEnv["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "1"
        let model = ChatPageModel(environment: fixtureEnv, botCoreFixture: (engine, BotStore(root: root)))
        model.mode = .chatgpt
        let themes = TatwoThemeSelfTestScope()
        themes.use(.fable5)
        defer { themes.restore() }
        ChatRenderProbe.enabled = true
        defer { ChatRenderProbe.enabled = false }
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let rig = TatwoComposerModeAcceptance.ClickRig(ChatPage(model: model).environment(\.tatwoSurfaceKind, .window), size: CGSize(width: 1000, height: 700))
        (rig.host as! NSHostingView<AnyView>).rootView = AnyView(ChatPage(model: model).environment(\.tatwoSurfaceKind, .window).environment(\.colorScheme, .light))
        defer { rig.close() }
        try check(rig.moveOnScreen(), "1000x700 full production ChatPage window is on screen")
        await rig.settle()
        try check(await BrowserRuntimeAcceptance.waitUntil { pod.spacePage?.window === rig.window && pod.spacePage?.currentURLString == origin + "/" }, "full GPT window mounts real CEF local page")
        guard let page = pod.spacePage, let store = ChatRenderProbe.browserStore else { throw TapError.remote("mounted page and observed sidebar store required") }
        var measurements: [[String: Any]] = []
        func move(_ top: Bool, x: CGFloat = 500) async {
            let point = NSPoint(x: x, y: top ? 698 : 350)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { NSApp.postEvent(event, atStart: false) }
            await rig.settle(12)
        }
        func shot() throws -> GlobalDMChatAcceptance.Rendered {
            guard let cached = rig.capture(), let captured = GlobalDMChatAcceptance.captureOwnWindow(cached) else { throw TapError.remote("own-window screenshot required") }
            return captured
        }
        func save(_ shot: GlobalDMChatAcceptance.Rendered, _ name: String) throws {
            guard let data = shot.bitmap.representation(using: .png, properties: [:]) else { throw TapError.remote("PNG required") }
            try data.write(to: folder.appendingPathComponent(name + ".png"))
            try GlobalDMChatAcceptance.identifiers(in: shot).sorted().joined(separator: "\n").write(to: folder.appendingPathComponent(name + ".ax.txt"), atomically: true, encoding: .utf8)
        }
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            (rig.host as! NSHostingView<AnyView>).rootView = AnyView(ChatPage(model: model).environment(\.tatwoSurfaceKind, .window).environment(\.colorScheme, scheme))
            rig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await rig.settle()
            try check(ChatRenderProbe.browserStore === store, "appearance change preserves the production sidebar store")
            page.loadURLString(origin + "/?dark=" + (dark ? "1" : "0"))
            try check(await BrowserRuntimeAcceptance.waitUntil { page.currentURLString == origin + "/?dark=" + (dark ? "1" : "0") }, "local page selects \(scheme) appearance")
            for collapsed in [false, true] {
                store.sidebarPinned = !collapsed; store.focusMode = collapsed
                await rig.settle()
                for top in [false, true] {
                    await move(top)
                    let snapshot = try await BrowserRuntimeAcceptance.snapshot(page)
                    try check(snapshot["title"] as? String == "W269 local GPT", "real local fixture document is loaded")
                    let captured = try shot()
                    let scale = CGFloat(captured.bitmap.pixelsWide) / 1000
                    guard let color = captured.bitmap.colorAt(x: Int(950 * scale), y: Int(350 * scale))?.usingColorSpace(.deviceRGB) else { throw TapError.remote("page background pixel required") }
                    try check(dark ? color.redComponent > 0.10 && color.redComponent < 0.18 : color.redComponent > 0.98,
                              "CEF pixels show the requested local page appearance")
                    let name = "gpt-fable5-\(dark ? "dark" : "light")-\(collapsed ? "collapsed" : "expanded")-\(top ? "top" : "away")"
                    try save(captured, name)
                    let tree = GlobalDMChatAcceptance.tree(captured)
                    let ids = Set(tree.keys)
                    try check(ids.contains("browser.sidebarToggle") == top && !ids.contains("chat.sidebarToggle"), "\(name): one shared toggle only when top chrome reveals")
                    try check(ids.contains("chat-sidebar-design-philosophy-info") == !collapsed, "\(name): expanded sidebar retains bottom OS settings row")
                    let frame = page.convert(page.bounds, to: rig.host)
                    let railRight = collapsed ? CGFloat(0) : WorkspaceSidebarMetrics.width
                    let gap = frame.minX - railRight
                    try check(abs(gap - WorkspaceSidebarMetrics.browserContentGap) < 0.5, "\(name): CEF left edge gap equals Browser \(gap) pt")
                    measurements.append(["screenshot": name + ".png", "webLeft": frame.minX, "sidebarRight": railRight, "gap": gap, "webWidth": frame.width])
                    if top {
                        let buttons = tree.values.filter { object in
                            let role = GlobalDMChatAcceptance.attribute(object, "accessibilityRole", "AXRole") as? String
                            guard role == "AXButton", let frame = (object as AnyObject).accessibilityFrame?() else { return false }
                            let bounds = rig.window.convertFromScreen(frame)
                            return bounds.midY > 652 && bounds.midX > railRight
                        }
                        try check(buttons.count == 1, "\(name): top chrome has exactly one AXButton")
                        let button = tree["browser.sidebarToggle"]!
                        guard let frame = (button as AnyObject).accessibilityFrame?() else { throw TapError.remote("button frame required") }
                        let bounds = rig.window.convertFromScreen(frame)
                        let expectedX = railRight + BrowserOmniboxMetrics.horizontalInset + (collapsed ? WindowChromeMetrics.trafficLightSafeWidth + BrowserOmniboxMetrics.controlGap : 0)
                        try check(abs(bounds.minX - expectedX) < 0.5 && bounds.width == 32 && bounds.height == 32, "\(name): Browser toggle origin and 32x32 size")
                    }
                }
            }
        }
        // Exercise the actual button twice through native mouse events.
        store.sidebarPinned = true; store.focusMode = false
        await move(true)
        await rig.click(NSPoint(x: WorkspaceSidebarMetrics.width + 24, y: 676))
        try check(await rig.wait { store.focusMode && !store.sidebarPinned }, "real toggle click collapses and releases sidebar")
        await move(false, x: 18)
        try check(await rig.wait { store.hoverRailShown }, "collapsed GPT sidebar slides out at left edge")
        try check(GlobalDMChatAcceptance.tree(try shot())["browser.sidebarToggle"] != nil, "slid-out GPT rail shows the expand button before the top chrome is revealed")
        await move(true, x: 18)
        let hover = try shot()
        try save(hover, "gpt-hover-top")
        let hoverTree = GlobalDMChatAcceptance.tree(hover)
        guard let toggle = hoverTree["browser.sidebarToggle"], let frame = (toggle as AnyObject).accessibilityFrame?() else { throw TapError.remote("hover sidebar toggle required") }
        let target = rig.window.convertFromScreen(frame)
        try check(abs(target.minX - (WorkspaceSidebarMetrics.width - BrowserOmniboxMetrics.collapsedHeight - BrowserOmniboxMetrics.horizontalInset)) < 0.5,
                  "hover sidebar toggle uses Browser rail position")
        await rig.click(NSPoint(x: target.midX, y: target.midY))
        try check(await rig.wait { !store.focusMode && store.sidebarPinned }, "second real toggle click expands and pins sidebar")
        // Browser comparison uses the same full-window route, never a hand-built GPT rail.
        model.mode = .browser
        await rig.settle()
        store.navigateFromStartPage(to: URL(string: origin + "/?surface=browser")!)
        let browserMounted = await BrowserRuntimeAcceptance.waitUntil {
            TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: rig.host).contains { $0.currentURLString?.contains("surface=browser") == true }
        }
        if browserMounted {
            for dark in [false, true] {
                (rig.host as! NSHostingView<AnyView>).rootView = AnyView(ChatPage(model: model).environment(\.tatwoSurfaceKind, .window).environment(\.colorScheme, dark ? .dark : .light))
                rig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for collapsed in [false, true] {
                    store.sidebarPinned = !collapsed; store.focusMode = collapsed
                    for top in [false, true] {
                        await move(top)
                        let captured = try shot()
                        let name = "browser-fable5-\(dark ? "dark" : "light")-\(collapsed ? "collapsed" : "expanded")-\(top ? "top" : "away")"
                        try save(captured, name)
                        let native = TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: rig.host).first { $0.currentURLString?.contains("surface=browser") == true }!
                        let frame = native.convert(native.bounds, to: rig.host)
                        let railRight = collapsed ? CGFloat(0) : WorkspaceSidebarMetrics.width
                        try check(abs(frame.minX - railRight) < 0.5, "\(name): Browser CEF gap is 0 pt")
                        measurements.append(["screenshot": name + ".png", "webLeft": frame.minX, "sidebarRight": railRight, "gap": frame.minX - railRight])
                    }
                }
            }
        } else {
            print("W269 BROWSER COMPARISON BLOCKED full Browser rig did not mount CEF; use existing Browser evidence")
        }
        flags[ChatGPTWebSpace.enabledKey] = false
        defaults.setVolatileDomain(flags, forName: UserDefaults.argumentDomain)
        model.mode = .chatgpt
        (rig.host as! NSHostingView<AnyView>).rootView = AnyView(ChatPage(model: model).environment(\.tatwoSurfaceKind, .window).environment(\.colorScheme, .light))
        await rig.settle()
        let native = try shot()
        try save(native, "native-opt-out")
        let nativeIDs = GlobalDMChatAcceptance.identifiers(in: native)
        try check(nativeIDs.contains("chatgpt.temporary") && nativeIDs.contains("chatgpt.newChat") && !nativeIDs.contains("chatgpt.webSpace"), "native opt-out retains top-right controls and sidebar list")
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("measurements.json"))
        print("W269 SUMMARY failures=0 passed=\(passed) browserMounted=\(browserMounted)")
        return true
    }

    private static let server = #"""
    import http.server, pathlib, sys
    root = pathlib.Path(sys.argv[1])
    class Page(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
        with (root/'requests.log').open('a') as log: log.write(self.path + '\n')
        dark = 'dark=1' in self.path
        html = '<!doctype html><meta charset="utf-8"><title>W269 local GPT</title><style>html,body{margin:0;min-height:100%%;background:%s;color:%s;font:18px system-ui}main{padding:72px 48px}h1{font-size:28px}input{font:inherit;padding:12px}</style><main><h1>ChatGPT · local fixture</h1><p>Independent human page</p><input placeholder="Message ChatGPT"></main>' % ('#202123' if dark else '#ffffff', '#f4f4f4' if dark else '#202123')
        payload = html.encode()
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Content-Length',str(len(payload))); self.end_headers(); self.wfile.write(payload)
      def log_message(self, *_): pass
    with http.server.ThreadingHTTPServer(('127.0.0.1',0), Page) as server:
      (root/'port').write_text(str(server.server_port))
      server.serve_forever()
    """#
}
#endif
