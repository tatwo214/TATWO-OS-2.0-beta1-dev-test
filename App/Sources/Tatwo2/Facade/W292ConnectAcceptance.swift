#if DEBUG
import AppKit
import Combine
import SwiftUI

@MainActor
enum W292ConnectAcceptance {
    final class CoverState: ObservableObject {
        @Published var settings = false
        @Published var visible = true
    }
    struct RetainedSpace: View {
        @ObservedObject var state: CoverState
        var body: some View {
            Text("假 Space 設定")
                .globalDMCovers(state.settings, id: "chat")
                .opacity(state.visible ? 1 : 0)
                .environment(\.tatwoWorkspaceVisible, state.visible)
        }
    }
    struct SettingsSpace: View {
        @ObservedObject var state: CoverState
        let section: ChatGPTBuildSection
        var body: some View {
            section.opacity(state.visible ? 1 : 0)
                .environment(\.tatwoWorkspaceVisible, state.visible)
        }
    }
    static func run() async throws -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            if !ok { failures += 1 }
            print("W292 \(ok ? "PASS" : "FAIL") \(label)")
        }
        defer { print("W292 SUMMARY failures=\(failures)") }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.validationError(env) == nil, NativeStagingIsolation.isEnabled(env),
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let root = URL(fileURLWithPath: path)
        let defaults = UserDefaults(suiteName: "w292.fixture")!
        let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false }, directKeys: false, recentApps: defaults)
        var openedDM = 0
        let browser = DMBrowser(store: store, openBox: { openedDM += 1 }, podPage: { DMBrowserAcceptance.FakePage() }, windowShown: { _ in true })
        var flow: HandsConnectFlow?
        let presenter = HandsConnectPresenter(store: store, openBox: { openedDM += 1 }, browser: browser,
            hookPod: { _ in }, podURL: { nil }, cancelFlow: { flow?.dismiss() }, card: { flow?.card })
        typealias A = HandsConnectAcceptance
        let registry = HandsConnectorRegistry(url: root.appendingPathComponent("connectors.json"))
        let accounts = HandsConnectAccounts(url: root.appendingPathComponent("accounts.json"))
        accounts.remember(HandsConnectAccountRecord(host: A.hostID, identityTag: HandsConnectAccounts.identityTag(A.identity), grantTag: nil, level: 2, at: Date()))
        let world = try A.World(root, "settings", presenting: presenter,
            disconnect: { _, hosts in Dictionary(uniqueKeysWithValues: hosts.map { ($0, .revoked) }) }, accounts: accounts, connectors: registry)
        flow = world.flow
        let url = "https://" + A.publicHost + "/mcp"
        let keep = HandsConnectorScan.Match(id: "fixture-original", name: "TATWO（Primary One）", auth: "oauth", serverURL: url, detailPath: "/plugins/fixture-original")
        var duplicate = keep; duplicate.id = "fixture-duplicate"; duplicate.name += "2"; duplicate.connected = false   // W294b：只刪明確未連線的
        var active = keep; active.connected = true
        world.pod.scanResult.matches = [active, duplicate]
        world.pod.authorization = .connected
        var input = HandsBuildInput()
        input.configKnown = true; input.enabled = true; input.pod = .ready; input.cloudflare = .done; input.dev = .done
        input.devices = [HandsBuildDevice(id: A.hostID, name: "Primary One", isPrimary: true, isThisDevice: true, selected: true,
            state: .done, subdomain: "fixture", url: url, connection: .done)]
        let theme = TatwoThemeSelfTestScope()
        defer { theme.restore() }
        for dark in [false, true] {
            theme.use(dark ? .aurora : .fable5)
            let section = ChatGPTBuildSection(connectFlow: world.flow, connectPresenter: presenter, connectBrowser: browser,
                openConnection: { world.flow.showConnected(hosts: [A.hostID], level: 2) }, testFrame: HandsBuildModel.frame(input))
            let visibility = CoverState()
            let shot = GlobalDMChatAcceptance.renderSync(SettingsSpace(state: visibility, section: section).padding(20), size: CGSize(width: 780, height: 860), scheme: dark ? .dark : .light)!
            await W214Acceptance.settle(shot)
            check(TatwoComposerModeAcceptance.press("tap.chatgpt.build.connect", in: shot), "settings connected entry AXPress \(dark)")
            await W214Acceptance.settle(shot)
            check(W214Acceptance.node("tap.chatgpt.build.connectionCard", shot) != nil && openedDM == 0,
                "settings card appears in place without opening DM \(dark)")
            try W214Acceptance.save(shot, "settings-card-" + (dark ? "dark" : "light"), root)
            check(TatwoComposerModeAcceptance.press("tatwo.dm.handsConnect.cleanupDuplicates", in: shot), "cleanup entry AXPress \(dark)")
            check(await A.waitUntil(3) { world.flow.cleanupPreview != nil && !world.flow.cleaningConnectors }, "fake Pod reaches preview \(dark)")
            await W214Acceptance.settle(shot)
            check(W214Acceptance.node("tatwo.dm.handsConnect.cleanupConfirm", shot) != nil && W214Acceptance.text(shot).contains(duplicate.name),
                "preview names and delete confirmation stay on settings card \(dark)")
            try W214Acceptance.save(shot, "settings-preview-" + (dark ? "dark" : "light"), root)
            check(TatwoComposerModeAcceptance.press("tatwo.dm.handsConnect.cleanupCancel", in: shot), "cancel cleanup AXPress \(dark)")
            check(world.flow.cleanupPreview == nil && world.pod.deletedConnectors.isEmpty, "cancel leaves fake connectors intact \(dark)")
            if dark {
                check(TatwoComposerModeAcceptance.press("tatwo.dm.handsConnect.disconnect", in: shot), "settings disconnect AXPress")
                check(await A.waitUntil(3) { if case .disconnected? = world.flow.card { return true }; return false }, "settings disconnect reaches result on same card")
                let key = HandsConnectorRegistry.key(device: A.hostID, identity: A.identity, mcpURL: url)
                check(registry.record(key)?.connector.id == keep.id && registry.record(key)?.needsAuthorization == true,
                    "settings disconnect keeps original connector for W208 reconnect")
            }
            visibility.visible = false
            await W214Acceptance.settle(shot)
            check(!presenter.inSettings && !browser.presentsInPlace && world.flow.card == nil,
                "leaving retained settings releases card and in-place routing \(dark)")
            shot.close()
            world.flow.dismiss()
        }
        presenter.inSettings = true
        presenter.setPodVisible(true)
        let podShot = GlobalDMChatAcceptance.renderSync(DMBrowserPageSurface(browser: browser), size: CGSize(width: 480, height: 500), scheme: .light)!
        await W214Acceptance.settle(podShot)
        check(browser.showsSurface(-1) && openedDM == 0, "settings mounts existing Pod surface without any DM open request")
        browser.adoptPopup(DMBrowserAcceptance.FakePage(), key: 3, expectedHost: A.publicHost)
        presenter.placePopup(key: 3)
        await W214Acceptance.settle(podShot)
        check(browser.showsSurface(3) && openedDM == 0, "settings pairing popup stays in existing native surface")
        podShot.close()
        browser.closeAll(cancelling: true)
        presenter.inSettings = false
        check(HandsConnectEntry.webEntryText(state: .connected(hosts: [A.hostID], level: 2), notice: nil, canStart: true, hasRecord: true) == nil, "W199 healthy entry stays quiet")
        check(HandsConnectEntry.webEntryText(state: .connect, notice: nil, canStart: true, hasRecord: false) != nil, "new unconnected account has entry")
        check(HandsConnectEntry.webEntryText(state: .connect, notice: nil, canStart: false, hasRecord: true) == nil, "W199 offline or pending identity remains quiet")
        check(HandsConnectEntry.webEntryText(state: .connect, notice: "需要重新連線", canStart: true, hasRecord: true) != nil, "W199 actionable revocation has entry")
        // Existing W208 performs revoke/reconnect against this same registry mechanism.
        let header = ChatGPTWebSpaceHeader(dots: .constant(false), entryText: "需要重新連線", connect: { openedDM += 1 })
        let top = GlobalDMChatAcceptance.renderSync(VStack { header; Text("ChatGPT・假網頁").frame(maxHeight: .infinity) },
            size: CGSize(width: 480, height: 650), scheme: .light)!
        await W214Acceptance.settle(top)
        check(TatwoComposerModeAcceptance.press("tatwo.dm.handsConnect.webEntry", in: top), "DM web header entry AXPress")
        try W214Acceptance.save(top, "dm-web-entry-light", root)
        top.close()
        let quiet = GlobalDMChatAcceptance.renderSync(ChatGPTWebSpaceHeader(dots: .constant(false), entryText: nil, connect: {}),
            size: CGSize(width: 480, height: 70), scheme: .light)!
        await W214Acceptance.settle(quiet)
        check(W214Acceptance.node("tatwo.dm.handsConnect.webEntry", quiet) == nil, "healthy web header has no resident entry")
        quiet.close()
        guard let main = GlobalDMFormsAcceptance.mainWindow() else { check(false, "native main window"); return false }
        let desk = GlobalDMDeskSettings(defaults: defaults)
        let panels = GlobalDMPanelController(store: store, desk: desk)
        panels.install()
        defer { panels.uninstall(); main.orderOut(nil) }
        let coverState = CoverState()
        let retained = GlobalDMChatAcceptance.renderSync(RetainedSpace(state: coverState), size: CGSize(width: 100, height: 100), scheme: .light)!
        defer { retained.close() }
        for round in 1...3 {
            coverState.visible = true
            coverState.settings = true
            await W214Acceptance.settle(retained)
            check(GlobalDMCoverRegistry.shared.overlays.contains("chat"), "visible settings holds its cover \(round)")
            check(NSApp.windows.contains { $0.accessibilityIdentifier() == "tatwo.dm.panel" }, "settings keeps registered DM panel \(round)")
            coverState.settings = false
            await W214Acceptance.settle(retained)
            check(NSApp.windows.contains { $0.accessibilityIdentifier() == "tatwo.dm.panel" && $0.isVisible }, "closing settings restores DM panel \(round)")
            coverState.settings = true
            await W214Acceptance.settle(retained)
            coverState.visible = false // Same retained view, no onDisappear, settings is still true.
            await W214Acceptance.settle(retained)
            NotificationCenter.default.post(name: .tatwoWorkOSPageDidChange, object: nil)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            try await Task.sleep(for: .milliseconds(60))
            check(!GlobalDMCoverRegistry.shared.overlays.contains("chat") && coverState.settings,
                "leaving retained Space releases cover without closing old settings \(round)")
            check(NSApp.windows.contains { $0.accessibilityIdentifier() == "tatwo.dm.panel" && $0.isVisible }, "Space switch \(round) retains visible registered DM panel")
            GlobalDMFormsAcceptance.hideChildren(of: main)
        }
        return failures == 0
    }
}
#endif
