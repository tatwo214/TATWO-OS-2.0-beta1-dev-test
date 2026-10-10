#if DEBUG
import AppKit
import Foundation
import SwiftUI

@MainActor enum W248WebSpaceAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        let isPodSize = env["TATWO2_SELFTEST"] == "w294e"
        let isDM = env["TATWO2_SELFTEST"] == "w265dmchatgpt" || isPodSize
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
            try Data((isDM ? W265DMChatGPTAcceptance.server : server).utf8).write(to: fixture.appendingPathComponent("server.py"))
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
            print("W248 \(value ? "PASS" : "FAIL") \(label)")
            guard value else { throw TapError.remote(label) }
            passed += 1
        }
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        var flags = arguments
        try check(defaults.object(forKey: ChatGPTWebSpace.enabledKey) == nil && ChatGPTWebSpace.isEnabled,
                  "unset flag defaults to web Space")
        flags[ChatGPTWebSpace.enabledKey] = false
        defaults.setVolatileDomain(flags, forName: UserDefaults.argumentDomain)
        try check(!ChatGPTWebSpace.isEnabled, "flag off selects existing native Space")
        flags[ChatGPTWebSpace.enabledKey] = true
        defaults.setVolatileDomain(flags, forName: UserDefaults.argumentDomain)
        try check(ChatGPTWebSpace.isEnabled, "explicit opt-in selects web Space")

        let pod = TapWebPod(podID: "w248-fixture", profileID: UUID(),
                            homeURL: URL(string: origin + "/pod")!, script: podScript)
        guard let stagingRoot = Bundle.main.object(forInfoDictionaryKey: "TatwoStagingRoot") as? String,
              let rootCache = TatwoCEFProfileLocationResolver.rootCacheURL(
                stagingRootURL: URL(fileURLWithPath: stagingRoot), bundleURL: Bundle.main.bundleURL),
              let helper = EmbeddedBrowserEnginePolicy.helperExecutableURL(in: .main) else {
            throw TapError.remote("scratch CEF profile and helper required")
        }
        let location = try TatwoCEFProfileLocationResolver.resolve(profile: pod.profile,
            rootCacheURL: rootCache, authorityStagingRootURL: URL(fileURLWithPath: stagingRoot),
            helperExecutablePath: helper.path,
            logFilePath: rootCache.deletingLastPathComponent().appendingPathComponent("cef-logs/cef.log").path)
        pod.selfTestLocation = location
        defer {
            for name in ["cef.log", "cef-embedding-telemetry.log"] {
                let source = URL(fileURLWithPath: location.logFilePath).deletingLastPathComponent().appendingPathComponent(name)
                if let data = try? Data(contentsOf: source) { try? data.write(to: folder.appendingPathComponent(name)) }
            }
        }
        let transport = Transport(pod)
        let driver: any ChatGPTPodTransport = isDM ? pod : transport
        let tap = ChatGPTTap(transport: driver, connection: .sleeping)
        let startup = tap.acquireLease(backgroundWork: true)
        tap.start()
        pod.browser?.onPrivateNetworkRequested = { host, reply in
            print("W248 FAIL unexpected private-network consent \(host)")
            reply(false)
        }
        pod.onMainFrame = { url, _, loading, status in print("W248 fixture Pod frame \(url ?? "nil") loading=\(loading) status=\(status)") }
        defer { tap.sleep() }
        try check(await BrowserRuntimeAcceptance.waitUntil { tap.connection == .ready }, "local Pod reports logged-in hello")
        tap.releaseLease(startup)
        let page = try pod.openSpacePage()
        var pageLoading = true
        page.stateHandler = { _, _, _, _, loading, _, _, _, _, _ in pageLoading = loading }
        page.onPrivateNetworkRequested = { host, reply in
            print("W248 FAIL unexpected human private-network consent \(host)"); reply(false)
        }
        try check(page !== pod.browser && page.browserActor == .human && !page.isPod && !page.agentControlled,
                  "separate human browser has no TAP configuration or agent control")
        if case .failure(.profileInUse) = TatwoCEFProfileLeaseRegistry.shared.acquire(
            identifier: pod.profile.registryKey, profileURL: URL(fileURLWithPath: location.persistentProfilePath!)) {
            try check(true, "sibling shares the sole Pod lease")
        } else { try check(false, "sibling shares the sole Pod lease") }

        if isPodSize { try await W294ePodSizeAcceptance.run(pod: pod, folder: folder, origin: origin); return true }
        if isDM { return try await W265DMChatGPTAcceptance.run(tap: tap, pod: pod, folder: folder, origin: origin) }

        let sidebarRoot = URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: sidebarRoot), environment: env)
        var sidebarEnv = env
        sidebarEnv["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "1"
        let model = ChatPageModel(environment: sidebarEnv, botCoreFixture: (engine, BotStore(root: sidebarRoot)))
        model.mode = .chatgpt
        let themes = TatwoThemeSelfTestScope()
        defer { themes.restore() }
        themes.use(.fable5)
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        var rig: TatwoComposerModeAcceptance.ClickRig? = TatwoComposerModeAcceptance.ClickRig(
            FixturePane(model: model, tap: tap, pod: pod, theme: .fable5, scheme: .light), size: CGSize(width: 1000, height: 700))
        defer { rig?.close() }
        try check(rig!.moveOnScreen(), "fixture window is on screen for native CEF and accessibility capture")
        func text() async throws -> String {
            let snapshot = try await BrowserRuntimeAcceptance.snapshot(page)
            return BrowserAgentBridge.readSnapshot(snapshot, url: page.currentURLString ?? "", maxChars: 10000)["text"] as? String ?? ""
        }
        func loaded(_ url: String) async -> Bool {
            await BrowserRuntimeAcceptance.waitUntil { page.currentURLString == url && !pageLoading }
        }
        // Human-page code observes its own globals/cookie; the test never injects TAP there.
        await rig!.settle()
        try check(await loaded(origin + "/pod"), "web Space mounts the live human CEF page")
        // W256: compare the actual Browser tab host with the GPT pane at equal content sizes.
        let browserProfile = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let browserRig = TatwoComposerModeAcceptance.ClickRig(
            BrowserFixture(profile: browserProfile, url: URL(string: origin + "/pod?surface=browser")!),
            size: CGSize(width: 1000, height: 700))
        defer { browserRig.close() }
        try check(browserRig.moveOnScreen(), "comparison Browser window is on screen")
        var measurements: [[String: Any]] = []
        func measure(_ surface: String, _ native: TatwoCEFBrowserView) async throws -> [String: Any] {
            let file = folder.appendingPathComponent("fixture/metrics-" + surface + ".json")
            try? FileManager.default.removeItem(at: file)
            try check(await BrowserRuntimeAcceptance.waitUntil { FileManager.default.fileExists(atPath: file.path) },
                      surface + " fixture reports viewport metrics")
            var result = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            result["surface"] = surface
            result["contentWidth"] = Double(native.superview!.bounds.width)
            result["contentHeight"] = Double(native.superview!.bounds.height)
            result["backingScaleFactor"] = Double(native.window!.backingScaleFactor)
            result["zoomLevel"] = native.zoomLevel
            measurements.append(result)
            print("W256 METRICS " + String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
            return result
        }
        try check(await BrowserRuntimeAcceptance.waitUntil {
            TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: browserRig.host).first?.currentURLString == origin + "/pod?surface=browser"
        }, "actual Browser tab loads local fixture")
        let browserPage = TatwoComposerModeAcceptance.views(TatwoCEFBrowserView.self, in: browserRig.host).first!
        for size in [CGSize(width: 1000, height: 700), CGSize(width: 1160, height: 760)] {
            (rig!.host as! NSHostingView<AnyView>).rootView = AnyView(FixturePane(model: model, tap: tap, pod: pod, theme: .fable5, scheme: .light)
                .frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light))
            (browserRig.host as! NSHostingView<AnyView>).rootView = AnyView(BrowserFixture(profile: browserProfile, url: URL(string: origin + "/pod?surface=browser")!)
                .frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light))
            rig!.window.setContentSize(size); browserRig.window.setContentSize(size)
            await rig!.settle(); await browserRig.settle()
            let gpt = try await measure("gpt", page)
            let browser = try await measure("browser", browserPage)
            for key in ["innerWidth", "innerHeight", "devicePixelRatio", "scale", "zoomLevel", "contentWidth", "contentHeight"] {
                try check((gpt[key] as? Double) == (browser[key] as? Double), "equal Browser and GPT \(key) at \(size)")
            }
            for sample in [gpt, browser] {
                try check(sample["innerWidth"] as? Double == sample["contentWidth"] as? Double &&
                          sample["innerHeight"] as? Double == sample["contentHeight"] as? Double &&
                          sample["devicePixelRatio"] as? Double == sample["backingScaleFactor"] as? Double &&
                          sample["scale"] as? Double == 1 && sample["zoomLevel"] as? Double == 0,
                          "viewport uses points and window backing scale at \(size)")
            }
        }
        TatwoComposerModeAcceptance.views(TatwoCEFTabHostView.self, in: browserRig.host).forEach { $0.close() }
        browserRig.close()
        try check(await BrowserRuntimeAcceptance.waitUntil {
            TatwoComposerModeAcceptance.views(TatwoCEFTabHostView.self, in: browserRig.host).allSatisfy { $0.isIdle }
        }, "comparison Browser tab closes before capture")
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("w256-viewport.json"))
        (rig!.host as! NSHostingView<AnyView>).rootView = AnyView(FixturePane(model: model, tap: tap, pod: pod, theme: .fable5, scheme: .light).frame(width: 1000, height: 700))
        rig!.window.setContentSize(CGSize(width: 1000, height: 700))
        await rig!.settle()
        var body = try await text()
        try check(body.contains("Session: fixture-login"), "Pod cookie is readable by the human page")
        try check(body.contains("TAP: absent"), "human page has no __tatwoPod global")
        page.runPodCommand("document.body.textContent='UNEXPECTED TAP INJECTION'")
        body = try await text()
        try check(!body.contains("UNEXPECTED TAP INJECTION"), "native TAP command refuses the human page")

        let session = ChatGPTConversationSession(tap: tap)
        for dark in [false, true] {
            let url = origin + "/human-next?dark=" + (dark ? "1" : "0")
            page.loadURLString(url)
            session.send("navigation send " + String(dark))
            try check(!pod.browser!.isHidden, "TAP work wakes parked Pod during human navigation")
            try check(await BrowserRuntimeAcceptance.waitUntil { !session.isSending && session.messages.last?.text == "fixture completed" },
                      "DM fake send finishes while human page navigates")
            try check(pageLoading || page.currentURLString != url, "human navigation is still pending at Pod completion")
            try check(await loaded(url), "TAP send preserves human destination URL")
            let snapshot = try await BrowserRuntimeAcceptance.snapshot(page)
            let fields = (snapshot["forms"] as? [[String: Any]] ?? []).flatMap { $0["fields"] as? [[String: Any]] ?? [] }
            guard let field = fields.first, let id = field["elementID"] as? String else { throw TapError.remote("human draft field missing") }
            let draft = "human draft " + String(dark)
            let typing = Task { @MainActor in
                await BrowserRuntimeAcceptance.bounded(fallback: false) { done in
                    page.typeText(draft, elementID: id, navigationGeneration: page.navigationGeneration, submit: false) { ok, _ in done(ok) }
                }
            }
            session.send("typing send " + String(dark))
            try check(await typing.value, "native human typing completes alongside TAP send")
            try check(await BrowserRuntimeAcceptance.waitUntil { !session.isSending && session.messages.last?.text == "fixture completed" },
                      "DM fake send finishes while human types")
            // Dark text can be quarantined by the safe reader; keep that privacy filter intact.
            // The fixture's own input handler acknowledges the real native input over HTTP.
            let proofFile = folder.appendingPathComponent("fixture/draft-proof-" + (dark ? "1" : "0") + ".json")
            func proofMatches() -> Bool {
                guard let data = try? Data(contentsOf: proofFile),
                      let proof = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
                return proof["draft"] == draft && proof["tap"] == "undefined" && proof["url"] == url
            }
            try check(await BrowserRuntimeAcceptance.waitUntil { proofMatches() }
                      && page.currentURLString == url && !page.agentControlled,
                      "human draft, URL and script isolation survive TAP send")
            for theme in [TatwoThemeID.fable5, .aurora] {
                themes.use(theme)
                let scheme: ColorScheme = dark ? .dark : .light
                let chromeScheme: ColorScheme = theme == .fable5 ? .light : scheme
                (rig!.host as! NSHostingView<AnyView>).rootView = AnyView(
                    FixturePane(model: model, tap: tap, pod: pod, theme: theme, scheme: chromeScheme).frame(width: 1000, height: 700))
                rig!.window.appearance = NSAppearance(named: chromeScheme == .dark ? .darkAqua : .aqua)
                func pickerDrawn(_ bitmap: NSBitmapImageRep) -> Bool {
                    let sx = CGFloat(bitmap.pixelsWide) / 1000, sy = CGFloat(bitmap.pixelsHigh) / 700
                    guard let bg = bitmap.colorAt(x: Int((WorkspaceSidebarMetrics.width - 8) * sx), y: Int(110 * sy))?.usingColorSpace(.deviceRGB) else { return false }
                    var ink = 0
                    for y in Int(25 * sy)..<Int(100 * sy) {
                        for x in Int(20 * sx)..<Int((WorkspaceSidebarMetrics.width - 20) * sx) {
                            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            if max(abs(c.redComponent - bg.redComponent), abs(c.greenComponent - bg.greenComponent), abs(c.blueComponent - bg.blueComponent)) > 0.35 { ink += 1 }
                        }
                    }
                    return ink > 30
                }
                var captured: GlobalDMChatAcceptance.Rendered?
                for _ in 0..<8 {
                    rig!.host.needsDisplay = true
                    rig!.window.display()
                    await rig!.settle()
                    if let cached = rig!.capture(), let shot = GlobalDMChatAcceptance.captureOwnWindow(cached), pickerDrawn(shot.bitmap) {
                        captured = shot; break
                    }
                }
                try check(captured != nil, "Space picker is visibly drawn in \(theme.rawValue) \(scheme) screenshot")
                let shot = captured!
                guard let png = shot.bitmap.representation(using: .png, properties: [:]) else {
                    throw TapError.remote("native web Space screenshot missing")
                }
                let name = "webspace-" + theme.rawValue + (dark ? "-dark.png" : "-light.png")
                try png.write(to: folder.appendingPathComponent(name))
                let ids = GlobalDMChatAcceptance.identifiers(in: shot)
                if !ids.contains("workspace.mode.ChatGPT") { print("W248 fixture AX identifiers \(ids.sorted())") }
                try check(!ids.contains { $0.hasPrefix("chatgpt.") && $0 != "chatgpt.webSpace" },
                          "production web sidebar contains no native ChatGPT controls")
                let sidebar = ChatPage(model: model).sidebar
                guard let rail = GlobalDMChatAcceptance.renderSync(sidebar, size: CGSize(width: WorkspaceSidebarMetrics.width, height: 700), scheme: chromeScheme) else {
                    throw TapError.remote("production sidebar capture missing")
                }
                let railIDs = GlobalDMChatAcceptance.identifiers(in: rail)
                try check(railIDs.contains("workspace.mode.ChatGPT") && railIDs.contains("chat-sidebar-design-philosophy-info")
                          && !railIDs.contains { $0.hasPrefix("chatgpt.") }, "production sidebar exposes Space picker and OS footer without native GPT controls")
                rail.close()
                try check(ids.contains("workspace.mode.ChatGPT"), "GPT Space selection remains mounted for \(theme.rawValue) \(scheme)")
                if dark { try check(TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap), "dark fixture is visibly rendered for \(theme.rawValue)") }
                print("W248 PNG \(folder.appendingPathComponent(name).path)")
            }
        }
        session.send("send during Space close")
        rig!.close(); rig = nil
        tap.setSpaceVisible(false)
        try check(!tap.sleepIfIdle() && pod.isRunning && !pod.browser!.isHidden, "closing Space cannot sleep or throttle an active Pod")
        try check(await BrowserRuntimeAcceptance.waitUntil { !session.isSending && session.messages.last?.text == "fixture completed" },
                  "DM fake send completes after Space closes")
        session.send("send after Space close")
        try check(await BrowserRuntimeAcceptance.waitUntil { !session.isSending && session.messages.last?.text == "fixture completed" },
                  "next DM fake send completes with Space closed")
        try check(transport.sends == 6, "all six fake sends executed only in Pod")
        tap.sleep()
        try check(await BrowserRuntimeAcceptance.waitUntil { !pod.isClosing }, "both native browsers finish close")
        let lease = try TatwoCEFProfileLeaseRegistry.shared.acquire(
            identifier: pod.profile.registryKey, profileURL: URL(fileURLWithPath: location.persistentProfilePath!)).get()
        TatwoCEFProfileLeaseRegistry.shared.release(lease)
        try check(true, "Pod profile lease becomes available after both browsers close")
        flags[ChatGPTWebSpace.enabledKey] = false
        defaults.setVolatileDomain(flags, forName: UserDefaults.argumentDomain)
        try check(!ChatGPTWebSpace.isEnabled, "flag restored off for native Space regressions")
        print("W248 SUMMARY failures=0 passed=\(passed)")
        return true
    }

    private struct BrowserFixture: View {
        let profile: EmbeddedBrowserRuntimeProfile
        let url: URL
        var body: some View {
            HStack(spacing: 0) {
                Color.clear.frame(width: WorkspaceSidebarMetrics.width)
                Divider()
                EmbeddedChromiumBrowserView(profile: profile, tabID: "w256-browser", initialURL: url,
                    openTabIDs: ["w256-browser"], command: nil, isGeometryDragInProgress: false,
                    onNavigationStateChange: { _, state in print("W256 Browser fixture state \(state)") })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private struct FixturePane: View {
        let model: ChatPageModel
        let tap: ChatGPTTap
        let pod: TapWebPod
        let theme: TatwoThemeID
        let scheme: ColorScheme
        var body: some View {
            HStack(spacing: 0) {
                ChatPage(model: model).sidebar
                Divider()
                ChatGPTWebSpacePane(tap: tap, pod: pod)
            }
            .background(scheme == .dark ? Color(red: 0.12, green: 0.13, blue: 0.16) : TatwoTheme.theme(for: theme).palette.canvasBase)
            .environment(\.colorScheme, scheme)
        }
    }

    private final class Transport: ChatGPTPodTransport {
        let pod: TapWebPod
        var sends = 0
        init(_ pod: TapWebPod) { self.pod = pod }
        var onEvent: ((String) -> Void)? { get { pod.onEvent } set { pod.onEvent = newValue } }
        var isRunning: Bool { pod.isRunning }
        var isHosted: Bool { pod.isHosted }
        func start() throws { try pod.start() }
        func stop() { pod.stop() }
        func setSpaceVisible(_ value: Bool) { pod.setSpaceVisible(value) }
        func setBackgroundWorkActive(_ value: Bool) { pod.setBackgroundWorkActive(value) }
        func run(_ script: String) {
            // Production commands require chatgpt.com; only this localhost fixture adapter removes that origin guard.
            if script.contains("\"cmd\":\"send\"") { sends += 1 }
            pod.run(script.replacingOccurrences(of: "location.host==='chatgpt.com'&&", with: ""))
        }
    }

    private static let podScript = #"""
    (report) => {
      window.__tatwoPod = {command(c) {
        if (c.cmd === 'w328Status') {
          const field = document.querySelector('#draft,#code');
          report(JSON.stringify({type:'w328_status',length:field.value.length,focused:document.activeElement===field,documentFocused:document.hasFocus()})); return;
        }
        if (c.cmd === 'w328KeyFixture') {
          const field = document.querySelector('#draft'); field.value = '';
          field.id='code'; field.name='code'; field.autocomplete='one-time-code'; field.maxLength=16; field.required=true;
          const button=document.createElement('button'); button.id='w328-submit'; button.type='submit'; button.textContent='Submit fixture'; field.form.appendChild(button);
          field.form.onsubmit=e=>{e.preventDefault();report(JSON.stringify({type:'w328_submit',length:field.value.length,trusted:e.isTrusted}));};
          field.oninput = e => report(JSON.stringify({type:'w328',complete:field.value.length===8,trusted:e.isTrusted,length:field.value.length}));
          document.addEventListener('keydown', e => report(JSON.stringify({type:'w328_key',focused:document.activeElement===field,trusted:e.isTrusted})));
          report(JSON.stringify({type:'w328_ready'})); return;
        }
        if (c.cmd === 'w328EndFixture') { const field=document.querySelector('#code'); field.id='draft'; field.removeAttribute('name'); field.removeAttribute('autocomplete'); document.querySelector('#w328-submit')?.remove(); return; }
        if (c.cmd === 'models') {
          requestAnimationFrame(() => requestAnimationFrame(() => report(JSON.stringify({type:'result',id:c.id,
            ok:innerWidth>=1000,message:'synthetic narrow model menu',viewport:[innerWidth,innerHeight],
            data:{models:[{slug:'desktop-fixture',title:'Desktop fixture model'}]}}))));
          return;
        }
        if (c.cmd.startsWith('connector')) {
          if (c.cmd === 'connectorScan') {
            const viewport = [innerWidth,innerHeight];
            setTimeout(() => report(JSON.stringify({type:'result',id:c.id,
              ok:!c.url.includes('/error'),message:'synthetic scan failure',viewport,
              data:{loggedIn:true,listKnown:true,devMode:true,matches:[]}})), 250);
          } else report(JSON.stringify({type:'result',id:c.id,ok:true,viewport:c.cmd==='connectorViewport'?[innerWidth,innerHeight]:null,
            data:c.cmd==='connectorHome'?{ok:true}:c.cmd==='connectorCreate'?{status:'needs_user',reason:'needs_manual'}:{status:'done',outline:'synthetic fixture'}}));
          return;
        }
        if(c.cmd !== 'send') return;
        document.querySelector('#pod-send').textContent = 'Pod sent: ' + c.text;
        report(JSON.stringify({type:'stream',id:c.id,kind:'accepted'}));
        setTimeout(() => {
          report(JSON.stringify({type:'stream',id:c.id,kind:'text',full:'fixture completed'}));
          report(JSON.stringify({type:'stream',id:c.id,kind:'finished'}));
        }, 350);
      }};
      document.addEventListener('DOMContentLoaded', () => {
        document.cookie='w248_session=fixture-login; Path=/; SameSite=Lax';
        report(JSON.stringify({type:'hello',loggedIn:true}));
      });
      return true;
    }
    """#

    private static let server = #"""
    import http.server, pathlib, sys, time
    root = pathlib.Path(sys.argv[1])
    class Page(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
        with (root/'requests.log').open('a') as log: log.write(self.path + '\n')
        if self.path.startswith('/human-next'): time.sleep(0.6)
        dark = 'dark=1' in self.path
        html = '''<!doctype html><meta charset="utf-8"><title>W248 fake ChatGPT</title>
        <style>body{font:18px system-ui;margin:48px;background:%s;color:%s}input{width:75%%;padding:14px;font:inherit}header{font-size:30px;margin-bottom:24px}p{margin:24px 0}</style>
        <header>ChatGPT · W248 local fixture</header><p>Human Space · independent conversation</p>
        <p id="session"></p><p id="tap"></p><form><label>Human draft <input id="draft" name="draft"></label></form>
        <p id="mirror">Draft: empty</p><p id="pod-send">Pod sent: none</p><a href="/human-next">Another conversation</a>
        <script>document.querySelector('#session').textContent='Session: '+(document.cookie.includes('w248_session=fixture-login')?'fixture-login':'missing');
        document.querySelector('#tap').textContent='TAP: '+(typeof window.__tatwoPod==='undefined'?'absent':'present');
        document.querySelector('#draft').oninput=e=>{
          document.querySelector('#mirror').textContent='Draft: '+e.target.value;
          fetch('/draft-proof'+location.search,{method:'POST',body:JSON.stringify({draft:e.target.value,tap:typeof window.__tatwoPod,url:location.href})});
        };
        document.querySelector('form').onsubmit=e=>e.preventDefault();
        setInterval(()=>{if(typeof window.__tatwoPod!=='undefined')return;fetch('/metrics?surface='+(new URLSearchParams(location.search).get('surface')||'gpt'),{
          method:'POST',body:JSON.stringify({innerWidth,innerHeight,devicePixelRatio,scale:visualViewport.scale})});},200);</script>''' % ('#202123' if dark else '#ffffff','#f4f4f4' if dark else '#202123')
        payload = html.encode()
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Cache-Control','no-store'); self.send_header('Content-Length',str(len(payload))); self.end_headers()
        self.wfile.write(payload)
      def do_POST(self):
        if self.path in ['/metrics?surface=gpt', '/metrics?surface=browser']:
          payload = self.rfile.read(min(2048, int(self.headers.get('Content-Length', '0'))))
          file = root/('metrics-' + self.path.split('=')[1] + '.json')
          pending = file.with_suffix('.tmp'); pending.write_bytes(payload); pending.replace(file)
          self.send_response(204); self.end_headers(); return
        if self.path not in ['/draft-proof?dark=0', '/draft-proof?dark=1']:
          self.send_error(404); return
        payload = self.rfile.read(min(2048, int(self.headers.get('Content-Length', '0'))))
        suffix = '1' if self.path.endswith('=1') else '0'
        (root/('draft-proof-' + suffix + '.json')).write_bytes(payload)
        self.send_response(204); self.end_headers()
      def log_message(self, *_): pass
    with http.server.ThreadingHTTPServer(('127.0.0.1',0), Page) as server:
      (root/'port').write_text(str(server.server_port))
      server.serve_forever()
    """#
}
#endif
