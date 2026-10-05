#if DEBUG
import AppKit
import SwiftUI

/// W214 tests native accessibility trees and actions; no real accounts or web connections.
@MainActor enum W214Acceptance {
    static func run() async throws -> Bool {
        var failures = 0, passed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures += 1 }
            print("W214 \(value ? "PASS" : "FAIL") \(name)")
        }
        defer { print("W214 SUMMARY failures=\(failures) passed=\(passed)") }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let artifacts = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let theme = TatwoThemeSelfTestScope()
        theme.use(.fable5)
        defer { theme.restore() }
        let step = env["W214_STEP"]
        if step == nil || step == "1" { try await logos(check, artifacts) }
        if step == nil || step == "2" { try await loginPage(check, artifacts, env) }
        if step == nil || step == "3" { try await flowDisclosure(check, artifacts) }
        if step == nil || step == "4" { try await W214MoreAcceptance.compactCard(check, artifacts) }
        if step == nil || step == "5" { try await W214MoreAcceptance.externalProjects(check, artifacts) }
        if step == nil || step == "6" { try await W214MoreAcceptance.correctLogo(check, artifacts) }
        if step == nil || step == "7" { try await W214MoreAcceptance.synchronizedLogin(check, artifacts) }
        if step == nil || step == "8" { try await W214MoreAcceptance.singleLogin(check, artifacts) }
        if step == nil || step == "9" { try await W214MoreAcceptance.spaceLogin(check, artifacts) }
        return failures == 0
    }

    static func nodes(_ shot: GlobalDMChatAcceptance.Rendered) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.count < 6000, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? NSView, view.isAccessibilityHidden() { return }
            result.append(object)
            for child in attr(object, "accessibilityChildren", "AXChildren") as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(shot.window); visit(shot.host)
        return result
    }
    static func attr(_ object: NSObject, _ selector: String, _ legacy: String) -> Any? {
        let modern = NSSelectorFromString(selector)
        if object.responds(to: modern), let value = object.perform(modern)?.takeUnretainedValue() {
            if let text = value as? String, text.isEmpty {} else if let list = value as? [Any], list.isEmpty {} else { return value }
        }
        let old = NSSelectorFromString("accessibilityAttributeValue:")
        return object.responds(to: old) ? object.perform(old, with: legacy)?.takeUnretainedValue() : nil
    }
    static func text(_ shot: GlobalDMChatAcceptance.Rendered) -> String { nodes(shot).map(DMBrowserAcceptance.axText).joined(separator: "\n") }
    static func node(_ id: String, _ shot: GlobalDMChatAcceptance.Rendered) -> NSObject? {
        nodes(shot).first { attr($0, "accessibilityIdentifier", "AXIdentifier") as? String == id }
    }
    static func settle(_ shot: GlobalDMChatAcceptance.Rendered) async {
        for _ in 0..<8 {
            shot.host.layoutSubtreeIfNeeded(); shot.window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
    static func click(_ point: NSPoint, in shot: GlobalDMChatAcceptance.Rendered) async {
        shot.window.ignoresMouseEvents = false
        shot.window.alphaValue = 1
        shot.window.setFrameOrigin(NSPoint(x: -20_000, y: -19_000))
        let now = ProcessInfo.processInfo.systemUptime
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now + Double(index) * 0.05,
                windowNumber: shot.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        try? await Task.sleep(for: .milliseconds(150))
        await settle(shot)
    }
    static func save(_ shot: GlobalDMChatAcceptance.Rendered, _ name: String, _ folder: URL) throws {
        guard let rendered = TatwoComposerModeAcceptance.recapture(shot),
              let png = rendered.bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }
    static func dump(_ shot: GlobalDMChatAcceptance.Rendered, _ name: String, _ folder: URL) throws {
        let rows = nodes(shot).map { object in
            ([String(describing: type(of: object)), "accessibilityRole", "accessibilityIdentifier", "accessibilityValue", "accessibilityLabel"].map { key in
                key.hasPrefix("accessibility") ? "\(key)=\(String(describing: attr(object, key, "AX" + key.dropFirst(13))))" : key
            } + ["frame=\(DMBrowserAcceptance.axFrame(object) ?? .zero)"]).joined(separator: " | ")
        }
        try rows.joined(separator: "\n").write(to: folder.appendingPathComponent(name + ".ax.txt"), atomically: true, encoding: .utf8)
    }
    private static func logos(_ check: (Bool, String) -> Void, _ artifacts: URL) async throws {
        let before = UserDefaults.standard.object(forKey: EnvironmentLoginTab.storageKey)
        defer { UserDefaults.standard.set(before, forKey: EnvironmentLoginTab.storageKey) }
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            UserDefaults.standard.set("github", forKey: EnvironmentLoginTab.storageKey)
            let shot = GlobalDMChatAcceptance.renderSync(EnvironmentLoginTabPicker().padding(24), size: CGSize(width: 240, height: 100), scheme: dark ? .dark : .light)!
            defer { shot.close() }
            await settle(shot)
            let github = node("settings.envLogin.github", shot), cloud = node("settings.envLogin.cloudflare", shot)
            check(github != nil && cloud != nil && [github, cloud].allSatisfy {
                $0.map { attr($0, "accessibilityRole", "AXRole") as? String == "AXButton" } ?? false
            }, "N1.logo-circle-buttons.\(dark)")
            check(["github", "cloudflare"].allSatisfy { name in
                ProviderIconResources.url(for: "EnvironmentIcon-" + name).flatMap { NSImage(contentsOf: $0) } != nil
            }, "N1.packaged-vectors.\(dark)")
            check(!nodes(shot).contains { attr($0, "accessibilityRole", "AXRole") as? String == "AXTabGroup" }, "N1.no-segmented-picker.\(dark)")
            check(TatwoComposerModeAcceptance.press("settings.envLogin.cloudflare", in: shot), "N1.cloudflare-click.\(dark)")
            await settle(shot)
            check(node("settings.envLogin.cloudflare", shot).flatMap { attr($0, "accessibilityValue", "AXValue") as? String } == "已選取"
                  && node("settings.envLogin.github", shot).flatMap { attr($0, "accessibilityValue", "AXValue") as? String } == "未選取", "N1.selection-outline-state.\(dark)")
            check(UserDefaults.standard.string(forKey: EnvironmentLoginTab.storageKey) == "cloudflare", "N1.selection-persists.\(dark)")
            try save(shot, "N1-environment-" + (dark ? "dark" : "light"), artifacts)
        }
    }
    private static func loginPage(_ check: (Bool, String) -> Void, _ artifacts: URL, _ environment: [String: String]) async throws {
        var env = environment; env["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "settings"
        let model = ChatPageModel(environment: env)
        model.engineQuotaDetails = [:]
        let pod = FakeTapPod(running: true), tap = ChatGPTTap(transport: pod, connection: .needsLogin)
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            let probe = EngineLoginCard.Probe()
            let shot = GlobalDMChatAcceptance.renderSync(
                TatwoSettingsShell(section: .constant(.modelAccess)) { EngineLoginCard(model: model, chatGPT: tap, testProbe: probe) },
                size: CGSize(width: 780, height: 560), scheme: dark ? .dark : .light)!
            defer { shot.close() }
            await settle(shot)
            let visible = text(shot)
            check(TatwoSettingsPage.Section.modelAccess.title == "登入" && !visible.contains("模型登入"), "N2.login-title-and-sidebar.\(dark)")
            check(!visible.contains("初始設定"), "N2.completed-banner-absent.\(dark)")
            check(node("login.chatgpt.tap", shot) != nil && node("login.environment.toggle", shot) != nil,
                  "N2.tap-row-and-environment-disclosure.\(dark)")
            check(node("settings.envLogin.github", shot) == nil && node("settings.envLogin.cloudflare", shot) == nil,
                  "N2.environment-default-collapsed.\(dark)")
            let sidebar = nodes(shot).filter { attr($0, "accessibilityRole", "AXRole") as? String == "AXButton" }
            check(!sidebar.contains { DMBrowserAcceptance.axText($0).contains("環境登入") && attr($0, "accessibilityIdentifier", "AXIdentifier") as? String != "login.environment.toggle" },
                  "N2.no-environment-sidebar-entry.\(dark)")
            try save(shot, "N2-login-" + (dark ? "dark" : "light"), artifacts)
            check(TatwoComposerModeAcceptance.press("login.environment.toggle", in: shot), "N2.environment-expand-action.\(dark)")
            await settle(shot)
            check(node("settings.envLogin.github", shot) != nil && node("settings.envLogin.cloudflare", shot) != nil, "N2.environment-expands-in-place.\(dark)")
            try save(shot, "N2-environment-expanded-" + (dark ? "dark" : "light"), artifacts)
            try dump(shot, "N2-before-recollapse-\(dark)", artifacts)
            check(TatwoComposerModeAcceptance.press("login.environment.toggle", in: shot), "N2.environment-collapse-action.\(dark)")
            await settle(shot)
            check(node("settings.envLogin.github", shot) == nil, "N2.environment-recollapses.\(dark)")
            try save(shot, "N2-after-recollapse-\(dark)", artifacts)
        }
        model.engineLogins = [.init(kind: .codex, isLoggedIn: false, account: nil, detail: "fixture")]
        let probe = W190SetupAcceptance.Probe()
        var opened: TatwoSettingsPage.Section?
        let guide = GlobalDMChatAcceptance.renderSync(SetupGuidePage(model: model, open: { opened = $0 }, testProbe: probe), size: CGSize(width: 780, height: 680), scheme: .light)!
        defer { guide.close() }
        await settle(guide)
        check(node("setup-assistant-login", guide).map(DMBrowserAcceptance.axText)?.contains("登入 ›") == true && !text(guide).contains("模型登入"), "N2.setup-login-renamed-in-tree")
        if let frame = probe.chip?.1 {
            await click(guide.host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil), in: guide)
        }
        check(opened == .modelAccess, "N2.setup-login-routes-to-login")
    }

    private static func flowDisclosure(_ check: (Bool, String) -> Void, _ artifacts: URL) async throws {
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            let shot = GlobalDMChatAcceptance.renderSync(TapSettingsView(chatGPT: ChatGPTTap(transport: FakeTapPod(), connection: .sleeping)), size: CGSize(width: 880, height: 820), scheme: dark ? .dark : .light)!
            defer { shot.close() }
            await settle(shot)
            try dump(shot, "N3-before-expand-\(dark)", artifacts)
            check(node("tap.chatgpt.build.flow", shot) == nil, "N3.flow-default-absent.\(dark)")
            check(node("tap.chatgpt.flow.toggle", shot).flatMap { attr($0, "accessibilityRole", "AXRole") as? String } == "AXButton", "N3.header-is-actionable-button.\(dark)")
            check(TatwoComposerModeAcceptance.press("tap.chatgpt.flow.toggle", in: shot), "N3.header-expand-click.\(dark)")
            await settle(shot)
            check(node("tap.chatgpt.build.flow", shot) != nil, "N3.flow-visible-after-expand.\(dark)")
            try save(shot, "N3-flow-expanded-" + (dark ? "dark" : "light"), artifacts)
            check(TatwoComposerModeAcceptance.press("tap.chatgpt.flow.toggle", in: shot), "N3.header-collapse-click.\(dark)")
            await settle(shot)
            check(node("tap.chatgpt.build.flow", shot) == nil, "N3.flow-absent-after-collapse.\(dark)")
            try save(shot, "N3-flow-collapsed-" + (dark ? "dark" : "light"), artifacts)
        }
    }

}
#endif
