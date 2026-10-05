#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W214MoreAcceptance {
    typealias Check = (Bool, String) -> Void
    private final class LoginPod: FakeTapPod {
        var logouts = 0
        override func restoreDisplayedPage(_ url: URL) {
            guard url.path == "/auth/logout" else { return }
            logouts += 1
            emit(["type": "hello", "loggedIn": false])
        }
    }
    static func compactCard(_ check: Check, _ artifacts: URL) async throws {
        var input = HandsBuildInput()
        input.configKnown = true; input.enabled = true; input.pod = .ready
        input.cloudflare = .done; input.dev = .done
        input.devices = [HandsBuildDevice(id: "fixture", name: "測試設備", isPrimary: true, isThisDevice: true, selected: true, state: .done, subdomain: "fixture", url: "https://fixture.example/mcp", connection: .done)]
        input.projects = [HandsBuildProject(id: "fixture", name: "外部新增測試專案", selected: true)]
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            let shot = GlobalDMChatAcceptance.renderSync(ChatGPTBuildSection(testFrame: HandsBuildModel.frame(input)), size: CGSize(width: 800, height: 480), scheme: dark ? .dark : .light)!
            defer { shot.close() }
            await W214Acceptance.settle(shot)
            let text = W214Acceptance.text(shot)
            check(W214Acceptance.node("tap.chatgpt.build.capabilities", shot) != nil && W214Acceptance.node("tap.chatgpt.build.connect", shot) != nil, "N4.title-capability-and-connect.\(dark)")
            check(!text.contains("外部新增測試專案") && ["project", "projectsAll", "scopeHost", "scopeGrants", "scopeMemory", "levelActual"].allSatisfy { W214Acceptance.node("tap.chatgpt.build." + $0, shot) == nil }, "N4.no-project-chips-or-detail-rows.\(dark)")
            try W214Acceptance.save(shot, "N4-compact-card-" + (dark ? "dark" : "light"), artifacts)
        }
    }
    static func externalProjects(_ check: Check, _ artifacts: URL) async throws {
        let pod = DispatchTapPod(running: true)
        let tap = ChatGPTTap(transport: pod), model = ChatGPTSpaceModel(testTap: tap)
        await model.refresh()
        _ = await HandsConnectAcceptance.waitUntil(2) { model.projectsLoadState == .loaded }
        func add(_ id: String) { pod.projects.append(["id": "g-p-" + id, "title": "手機新增 " + id, "kind": "project", "description": ""]) }
        add("open"); model.directoryPrepare()
        _ = await HandsConnectAcceptance.waitUntil(1) { model.projects.contains { $0.id == "g-p-open" } }
        check(model.projects.contains { $0.id == "g-p-open" }, "N5.external-project-on-directory-open")
        add("appear"); model.appear()
        _ = await HandsConnectAcceptance.waitUntil(1) { model.projects.contains { $0.id == "g-p-appear" } }
        check(model.projects.contains { $0.id == "g-p-appear" }, "N5.external-project-on-space-return")
        add("foreground"); NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        _ = await HandsConnectAcceptance.waitUntil(1) { model.projects.contains { $0.id == "g-p-foreground" } }
        check(model.projects.contains { $0.id == "g-p-foreground" }, "N5.external-project-on-foreground")
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            let shot = GlobalDMChatAcceptance.renderSync(ChatGPTSpaceSidebarList(model: model), size: CGSize(width: 300, height: 650), scheme: dark ? .dark : .light)!
            await W214Acceptance.settle(shot)
            check(W214Acceptance.text(shot).contains("手機新增 foreground"), "N5.new-project-in-native-list.\(dark)")
            try W214Acceptance.save(shot, "N5-external-project-" + (dark ? "dark" : "light"), artifacts)
            shot.close()
        }
        model.disappear()
        // Fresh external project has no OS project_id. Call the actual MCP bridge and verify durable default routing.
        let world = try HandsConnectAcceptance.World(artifacts, "external-mcp")
        _ = try world.service.updateSettings { $0.allProjects = true }
        let service = world.service
        let env = ProcessInfo.processInfo.environment
        let live = ChatLiveEngine(store: ChatLiveStore(root: artifacts.appendingPathComponent("external-live")), environment: env)
        defer { live.shutdownAll() }
        let library = BotLibrary(root: artifacts.appendingPathComponent("external-bots"), skillsRoot: artifacts.appendingPathComponent("external-skills"))
        await library.ready()
        let osModel = ChatPageModel(environment: env, botCoreFixture: (live, BotStore(library: library)))
        service.attach(model: osModel)
        _ = await HandsConnectAcceptance.waitUntil(2) { !service.classificationPending }
        let client = HandsConnectAcceptance.FakeChatGPT(service: service)
        try client.register(); try world.service.startPairing(); _ = client.begin()
        let access = try client.token(try client.submit(world.service.auth.pendingCard?.pairingCode ?? ""))
        let reportToolID = HandsTools.all.first { $0.id == "write_report" }!.id
        let response = await Task.detached {
            let reply = OSAgentBridge.handsResponse(method: "hands_call", params: ["access_token": access, "name": reportToolID, "arguments": ["text": "手機新專案的測試回報"]], service: service)
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }.value
        let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
        let result = object?["result"] as? [String: Any]
        check(result?["isError"] as? Bool == false && world.service.roomJournal.rows(projectID: nil).contains { $0.tool == "write_report" }, "N5.new-project-mcp-call-succeeds-and-journals-inbox")
    }
    static func correctLogo(_ check: Check, _ artifacts: URL) async throws {
        guard let logo = ProviderSVGIconLoader.image(for: "codex-gpt") else { check(false, "N6.logo-asset-loads"); return }
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            let expected = GlobalDMChatAcceptance.renderSync(Image(nsImage: logo).resizable().renderingMode(.template).scaledToFit().frame(width: 24, height: 24).padding(16), size: CGSize(width: 56, height: 56), scheme: dark ? .dark : .light)!
            let actual = GlobalDMChatAcceptance.renderSync(ChatGPTBuildNodeIcon(kind: .gpt).padding(16), size: CGSize(width: 56, height: 56), scheme: dark ? .dark : .light)!
            defer { expected.close(); actual.close() }
            await W214Acceptance.settle(expected); await W214Acceptance.settle(actual)
            let a = TatwoComposerModeAcceptance.recapture(actual)?.bitmap.representation(using: .png, properties: [:])
            let b = TatwoComposerModeAcceptance.recapture(expected)?.bitmap.representation(using: .png, properties: [:])
            check(a != nil && a == b, "N6.pod-icon-matches-login-asset-pixels.\(dark)")
            check(GlobalDMAvatarArt.chatGPTImage?.tiffRepresentation == logo.tiffRepresentation, "N6.dm-avatar-shares-openai-asset.\(dark)")
            try W214Acceptance.save(actual, "N6-correct-logo-" + (dark ? "dark" : "light"), artifacts)
        }
    }
    static func synchronizedLogin(_ check: Check, _ artifacts: URL) async throws {
        for dark in [false, true] {
        TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
        var environment = ProcessInfo.processInfo.environment
        environment["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "settings"
        let model = ChatPageModel(environment: environment)
        let pod = LoginPod(), tap = ChatGPTTap(transport: pod, connection: .needsLogin)
        let first = GlobalDMChatAcceptance.renderSync(EngineLoginCard(model: model, chatGPT: tap), size: CGSize(width: 880, height: 700), scheme: dark ? .dark : .light)!
        let second = GlobalDMChatAcceptance.renderSync(TapSettingsView(chatGPT: tap), size: CGSize(width: 880, height: 700), scheme: dark ? .dark : .light)!
        defer { first.close(); second.close() }
        await W214Acceptance.settle(first); await W214Acceptance.settle(second)
        let codex = model.engineLogins.first { $0.kind == .codex }
        func synchronized(_ status: String) -> Bool {
            W214Acceptance.node("login.chatgpt.status", first).map(DMBrowserAcceptance.axText)?.contains(status) == true
                && W214Acceptance.node("tap.chatgpt.flow.toggle", second).map(DMBrowserAcceptance.axText)?.contains(status) == true
        }
        try W214Acceptance.dump(second, "N7-before-login-\(dark)", artifacts)
        check(TatwoComposerModeAcceptance.press("login.chatgpt.action", in: first) && pod.starts == 1, "N7.login-from-login-page")
        pod.emit(["type": "hello", "loggedIn": true])
        await W214Acceptance.settle(first); await W214Acceptance.settle(second)
        check(synchronized("已登入"), "N7.both-live-views-authenticated")
        tap.sleep()
        await W214Acceptance.settle(first); await W214Acceptance.settle(second)
        check(synchronized("已登入"), "N7.sleep-preserves-one-login-state")
        tap.start()
        pod.emit(["type": "hello", "loggedIn": true])
        check(TatwoComposerModeAcceptance.press("login.chatgpt.action", in: second), "N7.logout-from-environment-tap")
        _ = await HandsConnectAcceptance.waitUntil(1) { pod.logouts == 1 }
        check(pod.logouts == 1, "N7.environment-logout-reaches-pod")
        await W214Acceptance.settle(first); await W214Acceptance.settle(second)
        check(synchronized("未登入"), "N7.both-live-views-logged-out")
        tap.sleep()
        await W214Acceptance.settle(first); await W214Acceptance.settle(second)
        let starts = pod.starts
        check(TatwoComposerModeAcceptance.press("login.chatgpt.action", in: second) && pod.starts > starts, "N7.login-from-environment-tap")
        pod.emit(["type": "hello", "loggedIn": true])
        await W214Acceptance.settle(first); await W214Acceptance.settle(second)
        check(synchronized("已登入"), "N7.reverse-login-live-sync")
        check(TatwoComposerModeAcceptance.press("login.chatgpt.action", in: first), "N7.logout-from-login-page")
        _ = await HandsConnectAcceptance.waitUntil(1) { pod.logouts == 2 }
        check(pod.logouts == 2, "N7.login-page-logout-reaches-pod")
        await W214Acceptance.settle(first); await W214Acceptance.settle(second)
        check(synchronized("未登入"), "N7.reverse-logout-live-sync")
        let after = model.engineLogins.first { $0.kind == .codex }
        check(codex != nil && codex?.isLoggedIn == after?.isLoggedIn && codex?.account == after?.account, "N7.codex-login-independent")
        try W214Acceptance.save(first, "N7-login-state-" + (dark ? "dark" : "light"), artifacts)
        try W214Acceptance.save(second, "N7-environment-state-" + (dark ? "dark" : "light"), artifacts)
        }
    }
    static func singleLogin(_ check: Check, _ artifacts: URL) async throws {
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            for loggedIn in [false, true] {
                let tap = ChatGPTTap(transport: FakeTapPod(running: true), connection: loggedIn ? .ready : .needsLogin)
                var input = HandsBuildInput(); input.pod = loggedIn ? .ready : .needsLogin
                let shot = GlobalDMChatAcceptance.renderSync(TapSettingsView(chatGPT: tap, testBuildFrame: HandsBuildModel.frame(input)), size: CGSize(width: 880, height: 700), scheme: dark ? .dark : .light)!
                defer { shot.close() }
                await W214Acceptance.settle(shot)
                let buttons = W214Acceptance.nodes(shot).filter { object in
                    W214Acceptance.attr(object, "accessibilityRole", "AXRole") as? String == "AXButton"
                        && W214Acceptance.attr(object, "accessibilityIdentifier", "AXIdentifier") as? String != "tap.chatgpt.flow.toggle"
                        && ["登入", "登出"].contains { DMBrowserAcceptance.axText(object).contains($0) }
                }
                check(buttons.count == 1 && W214Acceptance.node("tap.chatgpt.build.loginChatGPT", shot) == nil,
                      "N8.only-one-simple-login-button.\(dark).\(loggedIn)")
                try W214Acceptance.save(shot, "N8-single-login-" + (dark ? "dark" : "light") + (loggedIn ? "-signed-in" : "-signed-out"), artifacts)
            }
        }
    }

    static func spaceLogin(_ check: Check, _ artifacts: URL) async throws {
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            let tap = ChatGPTTap(transport: FakeTapPod(running: true), connection: .needsLogin)
            let model = ChatGPTSpaceModel(testTap: tap)
            let shot = GlobalDMChatAcceptance.renderSync(ChatGPTSpaceMainPane(model: model, showsHeader: false), size: CGSize(width: 760, height: 540), scheme: dark ? .dark : .light)!
            defer { shot.close() }
            await W214Acceptance.settle(shot)
            let buttons = W214Acceptance.nodes(shot).filter { W214Acceptance.attr($0, "accessibilityRole", "AXRole") as? String == "AXButton" }
            check(buttons.count == 1 && buttons.first.map(DMBrowserAcceptance.axText)?.contains("ChatGPT 登入") == true, "N9.only-chatgpt-login-button.\(dark)")
            let text = W214Acceptance.text(shot)
            check(!text.contains("需要登入 ChatGPT") && !text.contains("登入一次就好") && !text.contains("前往登入"), "N9.no-title-or-description.\(dark)")
            UserDefaults.standard.removeObject(forKey: TapSettingsView.loginRequestKey)
            check(TatwoComposerModeAcceptance.press("chatgpt.login", in: shot) && UserDefaults.standard.bool(forKey: TapSettingsView.loginRequestKey), "N9.existing-direct-login-action.\(dark)")
            if let bitmap = TatwoComposerModeAcceptance.recapture(shot)?.bitmap,
               let accent = NSColor(LiquidGlassTokens.brandAccent).usingColorSpace(bitmap.colorSpace) {
                // cacheDisplay captures in the display's ICC profile; compare encoded components in that profile.
                var matchingPixels = 0
                var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = 0, maxY = 0
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                        guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                        if abs(color.redComponent - accent.redComponent) < 0.02,
                           abs(color.greenComponent - accent.greenComponent) < 0.02,
                           abs(color.blueComponent - accent.blueComponent) < 0.02 {
                            matchingPixels += 1
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                }
                check(matchingPixels > 60, "N9.solid-current-theme-accent.\(dark)")
                check(matchingPixels > 60 && abs(minX + maxX - bitmap.pixelsWide) <= 8 && abs(minY + maxY - bitmap.pixelsHigh) <= 8, "N9.button-centered.\(dark)")
                var whitePixels = 0
                if maxX - minX > 16 && maxY - minY > 16 {
                    for x in (minX + 8)..<(maxX - 8) {
                        for y in (minY + 8)..<(maxY - 8) {
                            if let color = bitmap.colorAt(x: x, y: y), color.redComponent > 0.96,
                               color.greenComponent > 0.96, color.blueComponent > 0.96 { whitePixels += 1 }
                        }
                    }
                }
                check(whitePixels > 8, "N9.white-button-text.\(dark)")
            } else { check(false, "N9.current-theme-color-capture.\(dark)") }
            try W214Acceptance.save(shot, "N9-space-login-" + (dark ? "dark" : "light"), artifacts)
        }
    }
}
#endif
