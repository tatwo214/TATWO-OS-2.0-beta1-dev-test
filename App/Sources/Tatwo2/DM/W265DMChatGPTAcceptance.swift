#if DEBUG
import AppKit
import Combine
import SwiftUI

@MainActor enum W265DMChatGPTAcceptance {
    static func run(tap: ChatGPTTap, pod: TapWebPod, folder: URL, origin: String) async throws -> Bool {
        var passed = 0
        func check(_ value: Bool, _ label: String) throws {
            print("W265 \(value ? "PASS" : "FAIL") \(label)")
            guard value else { throw TapError.remote(label) }
            passed += 1
        }
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        var modelEnv = env
        modelEnv["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "1"
        let model = ChatPageModel(environment: modelEnv, botCoreFixture: (engine, BotStore(root: root)))
        let suite = "w265-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalDMStore(defaults: defaults, chatGPT: { ChatGPTConversationSession(tap: tap) },
            chatGPTAllowed: { true }, chatGPTCatalog: { Just(ChatGPTModelCatalog()).eraseToAnyPublisher() },
            directKeys: false, recentApps: defaults)
        store.attach(model)
        store.select(.chatGPT)
        let themes = TatwoThemeSelfTestScope()
        defer { themes.restore() }
        themes.use(.fable5)
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        var form = GlobalDMForm.outerPortrait
        var theme = TatwoThemeID.fable5
        var scheme = ColorScheme.light
        func phone() -> AnyView {
            AnyView(GlobalDMPhoneBox(store: store, model: model, surface: .floating, form: form)
                .frame(width: form.size.width, height: form.size.height).environment(\.colorScheme, scheme))
        }
        let rig = TatwoComposerModeAcceptance.ClickRig(phone(), size: form.size)
        defer { rig.close() }
        try check(rig.moveOnScreen(), "production Duo window is on screen")
        func mounted(_ page: TatwoCEFBrowserView) -> Bool { page.window === rig.window && page.superview != nil }
        let chat = try pod.openSpacePage()
        try check(await BrowserRuntimeAcceptance.waitUntil { mounted(chat) }, "DM mounts the very same GPT Space page")
        var measurements: [[String: Any]] = []
        func sample(_ name: String, page: TatwoCEFBrowserView) async throws -> [String: Any] {
            let file = folder.appendingPathComponent("fixture/metrics-" + name + ".json")
            var result: [String: Any] = [:]
            let expectedWidth = GlobalDMPhoneLook(form: form, slide: nil, size: form.size).chatWidth(in: form.size.width)
            let expectedHeight = form.size.height - DMPhone.headerHeight
                - GlobalDMWebSheetLayout.segmentHeight - GlobalDMWebSheetLayout.segmentInset * 2
            let matched = await BrowserRuntimeAcceptance.waitUntil {
                guard let data = try? Data(contentsOf: file),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                result = value
                return value["url"] as? String == page.currentURLString
                    && value["innerWidth"] as? Double == Double(expectedWidth)
                    && value["innerHeight"] as? Double == Double(expectedHeight)
            }
            try check(matched && mounted(page) && page.bounds.size == page.superview?.bounds.size
                      && abs(page.bounds.width - expectedWidth) < 1 && abs(page.bounds.height - expectedHeight) < 1,
                      "\(form.rawValue) \(name) CEF viewport equals actual Duo content area")
            try check(result["session"] as? Bool == true && result["tap"] as? String == "undefined"
                      && page.browserActor == .human && !page.isPod && !page.agentControlled,
                      "\(name) shares Pod login with no TAP injection")
            result["form"] = form.rawValue
            result["page"] = name
            measurements.append(result)
            return result
        }
        func switchTo(_ dots: Bool) async throws {
            await rig.settle()
            guard let bounds = ChatGPTWebSpace.tabFramesForSelfTest[dots] else {
                throw TapError.remote("segment layout frame missing")
            }
            try check(bounds.width > 10 && bounds.height > 10, "glass segment has a real drawn layout frame")
            let point = NSPoint(x: bounds.midX, y: form.size.height - bounds.midY)
            await rig.click(point)
            try check(await BrowserRuntimeAcceptance.waitUntil {
                guard let page = dots ? pod.dotsSpacePage : pod.spacePage else { return false }
                return mounted(page)
            }, "real glass chip click mounts \(dots ? "Dots" : "ChatGPT")")
        }
        func draft(_ text: String, page: TatwoCEFBrowserView) async throws {
            let snapshot = try await BrowserRuntimeAcceptance.snapshot(page)
            let fields = (snapshot["forms"] as? [[String: Any]] ?? []).flatMap { $0["fields"] as? [[String: Any]] ?? [] }
            guard let id = fields.first?["elementID"] as? String else { throw TapError.remote("fixture draft missing") }
            let typed = await BrowserRuntimeAcceptance.bounded(fallback: false) { done in
                page.typeText(text, elementID: id, navigationGeneration: page.navigationGeneration, submit: false) { ok, _ in done(ok) }
            }
            try check(typed, "native typing enters \(text)")
        }
        _ = try await sample("chatgpt", page: chat)
        try check(chat.currentURLString == origin + "/pod" && ChatGPTTap.homeURL.absoluteString == "https://chatgpt.com/",
                  "ChatGPT initially opens homepage")
        try await switchTo(false)
        try await switchTo(true)
        let dots = pod.dotsSpacePage!
        _ = try await sample("dots", page: dots)
        try check(dots.currentURLString == origin + "/dots" && ChatGPTDotsState.url.absoluteString == "https://chatgpt.com/dots",
                  "Dots initially opens existing Dots entry URL")
        dots.loadURLString(origin + "/conversation-dots")
        try check(await BrowserRuntimeAcceptance.waitUntil { dots.currentURLString == origin + "/conversation-dots" }, "Dots navigates independently")
        _ = try await sample("dots", page: dots)
        try await draft("dots draft", page: dots)
        let dotsGeneration = dots.navigationGeneration
        try await switchTo(false)
        chat.loadURLString(origin + "/conversation-chatgpt")
        try check(await BrowserRuntimeAcceptance.waitUntil { chat.currentURLString == origin + "/conversation-chatgpt" }, "ChatGPT navigates independently")
        _ = try await sample("chatgpt", page: chat)
        try await draft("chatgpt draft", page: chat)
        let chatGeneration = chat.navigationGeneration
        for next in GlobalDMForm.allCases {
            form = next
            (rig.host as! NSHostingView<AnyView>).rootView = phone()
            rig.window.setContentSize(form.size)
            await rig.settle()
            _ = try await sample("chatgpt", page: chat)
            try await switchTo(true)
            let value = try await sample("dots", page: dots)
            try check(value["draft"] as? String == "dots draft" && dots.currentURLString == origin + "/conversation-dots"
                      && dots.navigationGeneration == dotsGeneration && (try pod.openDotsSpacePage()) === dots,
                      "\(form.rawValue) Dots keeps draft, destination and document")
            try await switchTo(false)
            let home = try await sample("chatgpt", page: chat)
            try check(home["draft"] as? String == "chatgpt draft" && chat.currentURLString == origin + "/conversation-chatgpt"
                      && chat.navigationGeneration == chatGeneration && (try pod.openSpacePage()) === chat,
                      "\(form.rawValue) ChatGPT keeps draft, destination and document")
        }
        form = .outerPortrait
        for nextTheme in [TatwoThemeID.fable5, .aurora] {
            theme = nextTheme
            themes.use(theme)
            for dark in [false, true] {
                scheme = dark ? .dark : .light
                (rig.host as! NSHostingView<AnyView>).rootView = phone()
                rig.window.setContentSize(form.size)
                rig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for isDots in [false, true] {
                    try await switchTo(isDots)
                    let page = isDots ? dots : chat
                    page.loadURLString(origin + (isDots ? "/dots" : "/pod") + "?dark=" + (dark ? "1" : "0"))
                    _ = try await sample(isDots ? "dots" : "chatgpt", page: page)
                    try check(await BrowserRuntimeAcceptance.waitUntil {
                        let file = folder.appendingPathComponent("fixture/metrics-" + (isDots ? "dots" : "chatgpt") + ".json")
                        guard let data = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                        return value["dark"] as? Bool == dark
                    }, "local \(dark ? "dark" : "light") web fixture loaded")
                    await rig.settle(12)
                    guard let cached = rig.capture(), let shot = GlobalDMChatAcceptance.captureOwnWindow(cached),
                          let png = shot.bitmap.representation(using: .png, properties: [:]) else { throw TapError.remote("CEF screenshot missing") }
                    let name = "dm-" + (isDots ? "dots-" : "chatgpt-") + theme.rawValue + (dark ? "-dark.png" : "-light.png")
                    try png.write(to: folder.appendingPathComponent(name))
                    let ids = GlobalDMChatAcceptance.identifiers(in: shot)
                    try check(ids.contains("chatgpt.webSpace.chatgpt") && ids.contains("chatgpt.webSpace.dots")
                              && !ids.contains("tatwo.dm.chatgpt.temporary"), "screenshot has glass segments and no native temporary control")
                    print("W265 PNG \(folder.appendingPathComponent(name).path)")
                }
            }
        }
        try await switchTo(false)
        let main = TatwoComposerModeAcceptance.ClickRig(ChatGPTWebSpacePane(tap: tap, pod: pod), size: CGSize(width: 800, height: 650))
        defer { main.close() }
        try check(main.moveOnScreen(), "concurrent main Space window is on screen")
        await main.settle(15)
        try check(mounted(chat) && TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: main.host).isEmpty,
                  "DM first: main Space never steals or duplicates the browser")
        if let shot = main.capture() {
            let tree = GlobalDMChatAcceptance.tree(shot)
            try check(tree.values.contains { node in
                [("accessibilityValue", "AXValue"), ("accessibilityLabel", "AXDescription"), ("accessibilityTitle", "AXTitle")].contains {
                    (GlobalDMChatAcceptance.attribute(node, $0.0, $0.1) as? String)?.contains("ChatGPT 已在另一個視窗顯示") == true
                }
            }, "main Space displays occupancy placeholder")
        } else { try check(false, "main Space placeholder capture") }
        let cancelled = TatwoComposerModeAcceptance.ClickRig(ChatGPTWebSpacePane(tap: tap, pod: pod), size: CGSize(width: 800, height: 650))
        defer { cancelled.close() }
        try check(cancelled.moveOnScreen(), "W266 transient waiting pane is on screen")
        await cancelled.settle(8)
        (cancelled.host as! NSHostingView<AnyView>).rootView = AnyView(EmptyView())
        await cancelled.settle()
        cancelled.close()
        var screenshotCache: [ObjectIdentifier: GlobalDMChatAcceptance.Rendered] = [:]
        func screenshot(_ name: String, _ rigs: [TatwoComposerModeAcceptance.ClickRig]) throws {
            let shots = try rigs.map { rig in
                let key = ObjectIdentifier(rig.window)
                // Do not lay out the retained, windowless host before the deliberate dismantle.
                guard let cached = rig.window.contentView == nil ? screenshotCache[key] : rig.capture(),
                      let shot = GlobalDMChatAcceptance.captureOwnWindow(cached) else {
                    throw TapError.remote("handoff screenshot missing: " + name)
                }
                screenshotCache[key] = shot
                return shot
            }
            let size = NSSize(width: shots.reduce(0) { $0 + $1.size.width }, height: shots.map { $0.size.height }.max()!)
            let image = NSImage(size: size)
            image.lockFocus()
            var x: CGFloat = 0
            for shot in shots {
                NSImage(cgImage: shot.bitmap.cgImage!, size: shot.size).draw(in: NSRect(origin: NSPoint(x: x, y: 0), size: shot.size))
                x += shot.size.width
            }
            image.unlockFocus()
            guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw TapError.remote("handoff PNG missing") }
            let file = folder.appendingPathComponent(name + ".png")
            try png.write(to: file)
            print("W266b PNG \(file.path)")
        }
        // Detach the window first while ClickRig retains the old hosting tree.
        // Drain the release notification before removing its SwiftUI content.
        try screenshot("reverse-1-before", [rig, main])
        let oldContainer = chat.superview
        var notifications: [Bool] = []
        let observation = NotificationCenter.default.publisher(for: TapWebPod.spaceChanged, object: pod).sink { _ in
            let attached = chat.superview != nil
            notifications.append(attached)
            print("W266b NOTIFY attached=\(attached) oldContainer=\(chat.superview === oldContainer)")
        }
        defer { observation.cancel() }
        rig.window.contentView = nil
        await main.settle(8)
        try check(notifications.contains(true) && chat.superview === oldContainer,
                  "W266b release notification precedes old container dismantle; page is still attached")
        try check(TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: main.host).isEmpty,
                  "W266b waiting main has not stolen the retained page")
        try screenshot("reverse-2-released-retained", [rig, main])
        try check(chat.superview === oldContainer && oldContainer != nil,
                  "W266b second screenshot still precedes old container dismantle")
        let notificationCount = notifications.count
        let detachedAt = ProcessInfo.processInfo.systemUptime
        (rig.host as! NSHostingView<AnyView>).rootView = AnyView(EmptyView())
        rig.host.layoutSubtreeIfNeeded()
        let deadline = detachedAt + 1
        while chat.window !== main.window && ProcessInfo.processInfo.systemUptime < deadline {
            main.host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        let reverseMS = (ProcessInfo.processInfo.systemUptime - detachedAt) * 1000
        print("W266b HANDOFF reverse detach-to-mount ms=\(reverseMS) notifications=\(notifications.count - notificationCount)")
        try check((oldContainer as? TatwoCEFContainerView)?.browserView == nil && chat.superview !== oldContainer,
                  "W266b deliberate old container dismantle has actually completed")
        try check(chat.window === main.window && reverseMS < 1000,
                  "W266b delayed dismantle mounts the same page in waiting main within 1 second")
        try check(notifications.count - notificationCount == 1 && notifications.last == false,
                  "W266b one detached notification completes the handoff")
        try check(TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: main.host).count == 1
                  && TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: main.host).first === chat
                  && TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: rig.host).isEmpty
                  && (try pod.openSpacePage()) === chat,
                  "W266b exactly one original browser, no second TatwoCEFBrowserView")
        await main.settle()
        try screenshot("reverse-3-mounted", [main])
        observation.cancel()
        rig.close()
        try check(TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: cancelled.host).isEmpty,
                  "W266 cancelled waiter stays detached after the ownership notification")
        // Recreate DM ownership so the original two directions remain independent.
        (main.host as! NSHostingView<AnyView>).rootView = AnyView(EmptyView())
        await main.settle()
        rig.window.contentView = rig.host
        (rig.host as! NSHostingView<AnyView>).rootView = phone()
        rig.window.orderFrontRegardless()
        try check(await BrowserRuntimeAcceptance.waitUntil { mounted(chat) }, "W266b DM owns page again before normal handoff")
        (main.host as! NSHostingView<AnyView>).rootView = AnyView(ChatGPTWebSpacePane(tap: tap, pod: pod))
        await main.settle()
        // ClickRig retains its NSHostingView after close. Remove the SwiftUI content as
        // GlobalDMFloatingRoot/GlobalDMDockedBoxRoot do when their presentation flags close.
        func waitForMount(in window: NSWindow) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while chat.window !== window && ProcessInfo.processInfo.systemUptime < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(5))
            }
            window.displayIfNeeded()
            return chat.window === window && chat.superview != nil
        }
        let dmClosedAt = ProcessInfo.processInfo.systemUptime
        (rig.host as! NSHostingView<AnyView>).rootView = AnyView(EmptyView())
        try check(await waitForMount(in: main.window), "closing DM transfers existing page to waiting main Space")
        print("W266b HANDOFF DM-to-main ms=\((ProcessInfo.processInfo.systemUptime - dmClosedAt) * 1000)")
        await main.settle()
        try screenshot("dm-to-main-mounted", [main])
        rig.close()
        try check(TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: cancelled.host).isEmpty,
                  "W266 cancelled waiter stays detached after the ownership notification")
        let second = TatwoComposerModeAcceptance.ClickRig(phone(), size: form.size)
        defer { second.close() }
        try check(second.moveOnScreen(), "second DM window is on screen")
        await second.settle(15)
        try check(chat.window === main.window && TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: second.host).isEmpty,
                  "main first: DM never steals or duplicates the browser")
        let mainClosedAt = ProcessInfo.processInfo.systemUptime
        (main.host as! NSHostingView<AnyView>).rootView = AnyView(EmptyView())
        try check(await waitForMount(in: second.window), "closing main Space transfers existing page to waiting DM")
        print("W266b HANDOFF main-to-DM ms=\((ProcessInfo.processInfo.systemUptime - mainClosedAt) * 1000)")
        await second.settle()
        try screenshot("main-to-dm-mounted", [second])
        main.close()
        (second.host as! NSHostingView<AnyView>).rootView = AnyView(EmptyView())
        await second.settle()
        second.close()
        tap.sleep()
        try check(await BrowserRuntimeAcceptance.waitUntil { !pod.isClosing }, "Pod and both human pages finish close")
        try check(pod.spacePage == nil && pod.dotsSpacePage == nil && pod.browser == nil, "all three browser references are released")
        let location = pod.selfTestLocation!
        let profileLease = try TatwoCEFProfileLeaseRegistry.shared.acquire(identifier: pod.profile.registryKey,
            profileURL: URL(fileURLWithPath: location.persistentProfilePath!)).get()
        TatwoCEFProfileLeaseRegistry.shared.release(profileLease)
        try check(true, "profile lease becomes available after all three native browser close completions")
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("w265-viewport.json"))
        print("W265 SUMMARY failures=0 passed=\(passed)")
        return true
    }

    static let server = #"""
    import http.server, pathlib, sys
    root = pathlib.Path(sys.argv[1])
    class Page(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
        with (root/'requests.log').open('a') as log: log.write(self.path + '\n')
        dark = 'dark=1' in self.path
        dots = 'dots' in self.path
        html = '''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>W265 local fixture</title>
        <style>*{box-sizing:border-box}body{font:15px system-ui;margin:0;background:%s;color:%s}header{padding:22px;font-size:22px;border-bottom:1px solid #8884}main{padding:22px}input{width:100%%;padding:14px;font:inherit;border:1px solid #888;border-radius:20px;background:transparent;color:inherit}p{line-height:1.7}</style>
        <header>%s · Local fixture</header><main><p>完整網頁 · 共用 Pod 登入</p><p>切換分頁後，草稿與目前頁面會保留。</p><form><label>Draft <input id="draft" name="draft"></label></form><p id="session"></p></main>
        <script>document.querySelector('#session').textContent='Session: '+(document.cookie.includes('w248_session=fixture-login')?'fixture-login':'missing');
        document.querySelector('form').onsubmit=e=>e.preventDefault();
        setInterval(()=>{if(typeof window.__tatwoPod!=='undefined')return;fetch('/metrics?surface=%s',{
          method:'POST',body:JSON.stringify({innerWidth,innerHeight,devicePixelRatio,scale:visualViewport.scale,draft:document.querySelector('#draft').value,url:location.href,dark:%s,session:document.cookie.includes('w248_session=fixture-login'),tap:typeof window.__tatwoPod})});},200);</script>''' % ('#202123' if dark else '#ffffff','#f4f4f4' if dark else '#202123','Dots' if dots else 'ChatGPT','dots' if dots else 'chatgpt','true' if dark else 'false')
        payload = html.encode()
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Cache-Control','no-store'); self.send_header('Content-Length',str(len(payload))); self.end_headers(); self.wfile.write(payload)
      def do_POST(self):
        if self.path not in ['/metrics?surface=chatgpt','/metrics?surface=dots']: self.send_error(404); return
        payload=self.rfile.read(min(4096,int(self.headers.get('Content-Length','0'))))
        file=root/('metrics-'+self.path.split('=')[1]+'.json')
        pending=file.with_suffix('.tmp'); pending.write_bytes(payload); pending.replace(file)
        self.send_response(204); self.end_headers()
      def log_message(self, *_): pass
    with http.server.ThreadingHTTPServer(('127.0.0.1',0), Page) as server:
      (root/'port').write_text(str(server.server_port))
      server.serve_forever()
    """#
}
#endif
