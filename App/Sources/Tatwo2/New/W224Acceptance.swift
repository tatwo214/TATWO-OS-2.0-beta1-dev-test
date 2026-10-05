#if DEBUG
import AppKit
import SwiftUI

/// Synthetic fixtures only. Exercise production views, notifications and actions.
@MainActor enum W224Acceptance {
    typealias Check = (Bool, String) -> Void
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let artifacts = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        var failures = 0, passed = 0
        let check: Check = { ok, name in
            if ok { passed += 1 } else { failures += 1 }
            print("W224 \(ok ? "PASS" : "FAIL") \(name)")
        }
        let scope = TatwoThemeSelfTestScope()
        defer { scope.restore() }
        try await login(check, artifacts, env)
        try await projects(check, artifacts)
        try await memory(check, artifacts)
        compactBuild(check)
        print("W224 SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }

    static func compactBuild(_ check: Check) {
        // Retained production copy, including states absent from the rendered fixture.
        let shortCopy = [
            HandsBuildCopy.title, HandsBuildCopy.infoTitle, HandsBuildCopy.off, HandsBuildCopy.preparing,
            HandsBuildCopy.waitAuthorize, HandsBuildCopy.connected(HandsBuildConfig.defaultLevel),
            HandsBuildCopy.gpt, HandsBuildCopy.pod, HandsBuildCopy.primary, HandsBuildCopy.secondary,
            HandsBuildCopy.cloudflare, HandsBuildCopy.notLoggedIn, HandsBuildCopy.dev, HandsBuildCopy.connectedShort,
            HandsBuildCopy.chatGPTTitle, HandsBuildCopy.devicesTitle, HandsBuildCopy.loginCloudflare,
            HandsBuildCopy.apply, HandsBuildCopy.connect, HandsBuildCopy.enableChatGPT, HandsBuildCopy.podAsleep,
            HandsBuildCopy.podStarting, HandsBuildCopy.devModeOn, HandsBuildCopy.devModeLater,
            HandsBuildCopy.primaryRole, HandsBuildCopy.secondaryRole, HandsBuildCopy.thisDevice,
            HandsBuildCopy.domainUnknown, HandsBuildCopy.more, HandsBuildCopy.back, HandsBuildCopy.activity,
            HandsBuildCopy.envLogin, HandsBuildCopy.unlock, HandsBuildCopy.loginFor(String(repeating: "長", count: 30)),
            HandsBuildCopy.connectOne(String(repeating: "長", count: 30)), HandsBuildCopy.busy,
            HandsBuildCopy.turnOnFirst, HandsBuildCopy.badLabel, HandsBuildCopy.notReady,
            HandsBuildCopy.pickDomain, HandsBuildCopy.pickDevice, HandsBuildCopy.changed,
            HandsBuildFix.retryApply.title, HandsBuildFix.login("fixture").title,
            HandsBuildFix.unlock("fixture").title, HandsBuildFix.reconnect(nil).title
        ] + HandsSetupStep.allCases.map { HandsBuildFix.reauthorize("fixture", $0).title }
          + [HandsBuildNodeState.done, .waiting, .working, .off, .failed].map { HandsBuildCopy.word($0) }
        for (index, label) in shortCopy.enumerated() {
            check(!label.isEmpty && label.count <= 20, "5.retained-short-copy.\(index):\(label)")
        }
        var input = HandsBuildInput()
        input.configKnown = true; input.configRevision = 1; input.enabled = true; input.pod = .ready
        input.devices = [.init(id: "fixture-device", name: "fixture", isPrimary: true, isThisDevice: true, selected: true,
                               state: .done, subdomain: "fixture", url: "https://fixture.invalid/mcp", connection: .done)]
        input.projects = [.init(id: "fixture-project", name: "retired project row", selected: true)]
        for dark in [false, true] {
            let scope = TatwoThemeSelfTestScope()
            scope.use(dark ? .aurora : .fable5)
            defer { scope.restore() }
            let shot = GlobalDMChatAcceptance.renderSync(ChatGPTBuildSection(testFrame: HandsBuildModel.frame(input)),
                                                        size: CGSize(width: 800, height: 500), scheme: dark ? .dark : .light)!
            defer { shot.close() }
            TatwoComposerModeAcceptance.settle(shot)
            let visible = W214Acceptance.text(shot)
            check(W214Acceptance.node("tap.chatgpt.build.capabilities", shot) != nil
                  && visible.contains(HandsBuildCopy.capabilities)
                  && W214Acceptance.node("tap.chatgpt.build.connect", shot) != nil,
                  "5.current-card-shows-capability-and-connect.\(dark)")
            let retired = ["project", "projectsAll", "scopeHost", "scopeGrants", "scopeMemory", "levelActual", "loginChatGPT"]
            check(retired.allSatisfy { W214Acceptance.node("tap.chatgpt.build." + $0, shot) == nil }
                  && !visible.contains("retired project row")
                  && visible.range(of: #"L[0-2]"#, options: .regularExpression) == nil,
                  "5.current-card-has-no-retired-summaries-or-levels.\(dark)")
            let labels = W214Acceptance.nodes(shot).filter {
                W214Acceptance.attr($0, "accessibilityRole", "AXRole") as? String == "AXStaticText"
            }.compactMap { W214Acceptance.attr($0, "accessibilityValue", "AXValue") as? String }
            check(!labels.isEmpty && labels.filter { $0 != HandsBuildCopy.capabilities }.allSatisfy { $0.count <= 20 },
                  "5.current-inline-copy-short-except-capability.\(dark)")
            check(!visible.contains(HandsBuildCopy.infoParagraph) && HandsBuildCopy.infoParagraph.count <= 80
                  && W214Acceptance.node("tap.chatgpt.build.info", shot) != nil,
                  "5.long-description-stays-in-info.\(dark)")
        }
    }

    static func memory(_ check: Check, _ artifacts: URL) async throws {
        // Invalid ID produces a real LocalizedError before any write.
        let invalid = "../invalid", valid = "w224-fixture.md"
        try FileManager.default.createDirectory(at: TatwoMemoryStore.shared.memory, withIntermediateDirectories: true)
        for coder in [false, true] {
            let note = TatwoMemoryUsageNote(items: [.init(id: invalid, title: "失敗 fixture"), .init(id: valid, title: "成功 fixture")],
                                            query: "synthetic fixture")
            let presentation = ChatSystemNotePresentation(symbol: "brain", tag: TatwoMemoryUsageNote.tag, text: note.encoded())
            let shot = GlobalDMChatAcceptance.renderSync(ChatSystemNoteRow(presentation: presentation, rowWidth: 600, revealsMemory: coder),
                                                        size: CGSize(width: 640, height: 350), scheme: .light)!
            defer { shot.close() }
            await W214Acceptance.settle(shot)
            if !coder {
                check(W214Acceptance.node("tatwo-memory-irrelevant-\(invalid)", shot) == nil, "4.shared-starts-collapsed")
                check(TatwoComposerModeAcceptance.press("tatwo-memory-usage", in: shot), "4.shared-disclosure-opens")
                await W214Acceptance.settle(shot)
            } else {
                check(W214Acceptance.node("tatwo-memory-usage", shot) == nil, "4.coder-keeps-turn-expansion-without-inner-disclosure")
            }
            check(TatwoComposerModeAcceptance.press("tatwo-memory-irrelevant-\(invalid)", in: shot), "4.\(coder).irrelevant-action")
            await W214Acceptance.settle(shot)
            check(W214Acceptance.text(shot).contains(TatwoMemoryStore.Failure.invalidID.localizedDescription),
                  "4.\(coder).detailed-localized-error")
            check(TatwoComposerModeAcceptance.press("tatwo-memory-irrelevant-\(invalid)", in: shot), "4.\(coder).failure-can-retry")
            await W214Acceptance.settle(shot)
            check(TatwoComposerModeAcceptance.press("tatwo-memory-irrelevant-\(valid)", in: shot), "4.\(coder).success-action")
            await W214Acceptance.settle(shot)
            check(W214Acceptance.text(shot).contains(TatwoMemoryUsageRow.markedHere)
                  && !W214Acceptance.text(shot).contains(TatwoMemoryStore.Failure.invalidID.localizedDescription),
                  "4.\(coder).success-clears-error-and-marks-row")
            var opened = false
            let observer = NotificationCenter.default.addObserver(forName: .tatwoOpenWorkOSWindow, object: nil, queue: .main) { _ in opened = true }
            check(TatwoComposerModeAcceptance.press("tatwo-memory-open-\(valid)", in: shot), "4.\(coder).open-action")
            await W214Acceptance.settle(shot)
            NotificationCenter.default.removeObserver(observer)
            check(opened, "4.\(coder).open-uses-shared-navigator")
            try W214Acceptance.save(shot, "w224-memory-\(coder)", artifacts)
        }
    }

    final class CatalogPod: DispatchTapPod {
        var hold = false, fail = false, empty = false, revision = 1
        var pending: [String] = []
        override func respond(_ command: [String: Any], id: String, cmd: String) {
            guard cmd == "projects" else { super.respond(command, id: id, cmd: cmd); return }
            if hold { pending.append(id) } else { reply(id) }
        }
        func flush() { let ids = pending; pending = []; ids.forEach(reply) }
        func reply(_ id: String) {
            let rows: [[String: Any]] = empty ? [] : [["id": "g-p-fixture", "title": "Catalog \(revision)", "kind": "project"]]
            emit(fail ? ["type": "result", "id": id, "ok": false, "message": "fixture failure"]
                 : ["type": "result", "id": id, "ok": true, "data": ["items": rows]])
        }
    }

    static func projects(_ check: Check, _ artifacts: URL) async throws {
        let pod = CatalogPod(running: true), tap = ChatGPTTap(transport: pod)
        let model = ChatGPTSpaceModel(testTap: tap)
        defer { model.disappear(); tap.sleep() }
        pod.hold = true
        model.retryProjects()
        check(model.projectsLoadState == .loading, "3.first-load-shows-loading")
        check(await HandsConnectAcceptance.waitUntil(2) { !pod.pending.isEmpty }, "3.first-request-reaches-fixture")
        pod.fail = true; pod.flush()
        check(await HandsConnectAcceptance.waitUntil(2) { model.projectsLoadState == .failed("讀不到專案清單") },
              "3.first-failure-shows-error")
        pod.fail = false; model.retryProjects()
        _ = await HandsConnectAcceptance.waitUntil(2) { !pod.pending.isEmpty }
        pod.flush()
        check(await HandsConnectAcceptance.waitUntil(2) { model.projects.first?.title == "Catalog 1" }, "3.retry-loads-catalog")
        model.appear()
        _ = await HandsConnectAcceptance.waitUntil(2) { !pod.pending.isEmpty }
        pod.flush()
        try await Task.sleep(for: .milliseconds(100))
        for trigger in ["foreground", "reopen", "renewed"] {
            if trigger == "foreground" { NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp) }
            else if trigger == "reopen" { model.disappear(); model.appear() }
            else { pod.emit(["type": "auth"]) }
            _ = await HandsConnectAcceptance.waitUntil(2) { !pod.pending.isEmpty }
            check(model.projectsLoadState == .loaded && model.projects.first?.title == "Catalog 1",
                  "3.\(trigger).keeps-loaded-state")
            pod.fail = true; pod.flush()
            try await Task.sleep(for: .milliseconds(100))
            check(model.projectsLoadState == .loaded && model.projects.first?.title == "Catalog 1",
                  "3.\(trigger).failure-keeps-catalog-without-error")
        }
        pod.fail = false; pod.revision = 2; model.retryProjects()
        _ = await HandsConnectAcceptance.waitUntil(2) { !pod.pending.isEmpty }
        pod.flush()
        check(await HandsConnectAcceptance.waitUntil(2) { model.projects.first?.title == "Catalog 2" }, "3.background-success-replaces-catalog")
        let shot = GlobalDMChatAcceptance.renderSync(ChatGPTSpaceSidebarList(model: model), size: CGSize(width: 300, height: 650), scheme: .light)!
        await W214Acceptance.settle(shot)
        check(!W214Acceptance.text(shot).contains("讀取中") && !W214Acceptance.text(shot).contains("讀不到專案清單"),
              "3.cached-native-list-has-no-status-error")
        try W214Acceptance.save(shot, "w224-projects-cached", artifacts)
        shot.close()
        pod.empty = true; model.retryProjects()
        _ = await HandsConnectAcceptance.waitUntil(2) { !pod.pending.isEmpty }
        pod.flush()
        _ = await HandsConnectAcceptance.waitUntil(2) { model.projects.isEmpty }
        model.retryProjects()
        check(model.projectsLoadState == .loaded, "3.successful-empty-catalog-does-not-flash")
        _ = await HandsConnectAcceptance.waitUntil(2) { !pod.pending.isEmpty }
        pod.fail = true; pod.flush()
        try await Task.sleep(for: .milliseconds(100))
        check(model.projectsLoadState == .loaded, "3.successful-empty-catalog-failure-is-not-first-load-error")
    }

    static func login(_ check: Check, _ artifacts: URL, _ environment: [String: String]) async throws {
        var env = environment; env["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "settings"
        let entry = TatwoEntry()
        guard entry.root.path == environment["TATWO2_OS_ROOT"] else { throw CocoaError(.fileWriteNoPermission) }
        let id = "22400000-0000-4000-8000-000000000001"
        try DeviceIdentity(deviceID: id, name: "fixture", hardwareModel: "Fixture", role: .primary, epoch: 1,
                           primaryDeviceID: id, updatedAt: Date()).encoded().write(to: entry.deviceJSON, options: .atomic)
        check(OSDocuments.isPrimary, "1.real-shaped-primary-fixture-enables-backup-banner")
        let model = ChatPageModel(environment: env)
        let before = UserDefaults.standard.object(forKey: EnvironmentLoginTab.storageKey)
        defer { UserDefaults.standard.set(before, forKey: EnvironmentLoginTab.storageKey); EnvironmentLoginTarget.pending = nil }
        for dark in [false, true] {
            TatwoThemeSelfTestScope().use(dark ? .aurora : .fable5)
            let shot = GlobalDMChatAcceptance.renderSync(TatwoSettingsPage(model: model, initialSection: .modelAccess, onClose: {}),
                                                        size: CGSize(width: 780, height: 560), scheme: dark ? .dark : .light)!
            await W214Acceptance.settle(shot)
            check(W214Acceptance.node("settings.envLogin.github", shot) == nil, "1.ordinary-login-collapsed.\(dark)")
            for target in EnvironmentLoginTarget.allCases {
                if target == .backup { UserDefaults.standard.set("cloudflare", forKey: EnvironmentLoginTab.storageKey) }
                target.open()
                await W214Acceptance.settle(shot)
                check(W214Acceptance.node("settings.envLogin.github", shot) != nil, "1.\(target).expands.\(dark)")
                if target != .update {
                    check(UserDefaults.standard.string(forKey: EnvironmentLoginTab.storageKey) == (target == .backup ? "github" : target.rawValue),
                          "1.\(target).selects-tab.\(dark)")
                }
                let id = target == .github || target == .cloudflare ? "login.environment.accounts" : "login.environment." + target.rawValue
                let frame = W214Acceptance.node(id, shot).flatMap(DMBrowserAcceptance.axFrame) ?? .zero
                let visible = shot.window.convertToScreen(shot.host.convert(shot.host.bounds, to: nil))
                check(frame.height > 0 && frame.intersects(visible), "1.\(target).target-visible.\(dark)")
                try W214Acceptance.save(shot, "w224-login-\(target)-\(dark)", artifacts)
                check(TatwoComposerModeAcceptance.press("login.environment.toggle", in: shot), "1.\(target).can-recollapse.\(dark)")
                await W214Acceptance.settle(shot)
                target.open()
                await W214Acceptance.settle(shot)
                check(W214Acceptance.node("settings.envLogin.github", shot) != nil, "1.\(target).repeated-entry-expands.\(dark)")
            }
            NotificationCenter.default.post(name: .tatwoOpenSettingsSection, object: TatwoSettingsPage.Section.start.rawValue)
            await W214Acceptance.settle(shot)
            check(TatwoComposerModeAcceptance.press("setup-open-backup", in: shot), "1.setup-backup-action.\(dark)")
            await W214Acceptance.settle(shot)
            check(W214Acceptance.node("settings.envLogin.github", shot) != nil, "1.setup-backup-expands.\(dark)")
            shot.close()
            let initial = GlobalDMChatAcceptance.renderSync(TatwoSettingsPage(model: model, initialSection: .github, onClose: {}),
                                                           size: CGSize(width: 780, height: 560), scheme: dark ? .dark : .light)!
            await W214Acceptance.settle(initial)
            check(W214Acceptance.node("login.environment.update", initial) != nil, "1.sidebar-initial-update.\(dark)")
            initial.close()
            EnvironmentLoginTab.open(.cloudflare)
            let cold = GlobalDMChatAcceptance.renderSync(TatwoSettingsPage(model: model, initialSection: .github, onClose: {}),
                                                        size: CGSize(width: 780, height: 560), scheme: dark ? .dark : .light)!
            await W214Acceptance.settle(cold)
            check(W214Acceptance.node("settings.envLogin.cloudflare", cold) != nil
                  && UserDefaults.standard.string(forKey: EnvironmentLoginTab.storageKey) == "cloudflare",
                  "1.closed-settings-cloudflare-entry.\(dark)")
            cold.close()
        }
    }
}
#endif
