#if DEBUG
import Foundation
import SwiftUI
import AppKit

/// 正式 View、store 與送出前檢查；所有資料只在隔離 staging 的暫存目錄。
@MainActor enum W192UXAcceptance {
    final class ProjectSelection: ObservableObject {
        @Published var id = UUID()
    }
    struct SwitchingRoom: View {
        @ObservedObject var selection: ProjectSelection
        let journal: HandsRoomJournal
        let workdir: String
        let visible: (Bool) -> Void
        var body: some View {
            var row = ChatGPTRoomRow(projectID: selection.id, workdir: workdir, openThread: { _ in }, roomJournal: journal)
            row.testVisible = visible
            return row
        }
    }
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let live = env["TATWO2_LIVE_ROOT"], let artifacts = env["TATWO2_SELFTEST_ARTIFACTS"] else {
            throw BotLibraryError.invalid("w192ux requires isolated staging and artifacts")
        }
        let root = URL(fileURLWithPath: live).appendingPathComponent("w192ux")
        let folder = URL(fileURLWithPath: artifacts)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var passed = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures += 1 }
            print("W192UX \(value ? "PASS" : "FAIL") \(name)")
        }
        func shot(_ rig: TatwoComposerModeAcceptance.ClickRig, _ name: String) throws {
            guard let png = rig.capture()?.bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                throw BotLibraryError.invalid("render failed: " + name)
            }
            let url = folder.appendingPathComponent(name + ".png")
            try png.write(to: url)
            print("W192UX PNG \(url.path)")
        }
        let journal = HandsRoomJournal(url: root.appendingPathComponent("room.json"))
        let project = UUID(), emptyProject = UUID()
        try journal.append(HandsRoomCall(id: UUID(), at: Date(), projectID: project, grantTag: "fixture",
                                        tool: "list_projects", summary: "專案紀錄", workspaceID: nil, approval: nil))
        var visible = false
        var row = ChatGPTRoomRow(projectID: project, workdir: root.path, openThread: { _ in }, roomJournal: journal)
        row.testVisible = { visible = $0 }
        let room = TatwoComposerModeAcceptance.ClickRig(row, size: CGSize(width: 440, height: 160))
        await room.settle(30)
        check(visible, "01 existing journal renders the actual room button from empty initial state")
        try shot(room, "room-with-records")
        room.close()
        visible = false
        var empty = ChatGPTRoomRow(projectID: emptyProject, workdir: root.path, openThread: { _ in }, roomJournal: journal)
        empty.testVisible = { visible = $0 }
        let emptyRoom = TatwoComposerModeAcceptance.ClickRig(empty, size: CGSize(width: 440, height: 160))
        await emptyRoom.settle(30)
        check(!visible, "01 project without journal renders no room button")
        try shot(emptyRoom, "room-without-records")
        emptyRoom.close()

        let selection = ProjectSelection()
        visible = false
        let switching = TatwoComposerModeAcceptance.ClickRig(
            SwitchingRoom(selection: selection, journal: journal, workdir: root.path, visible: { visible = $0 }),
            size: CGSize(width: 440, height: 160))
        await switching.settle(30)
        selection.id = project
        await switching.settle(30)
        check(visible, "01 switching to a project with records in the same folder renders the room")
        selection.id = emptyProject
        await switching.settle(30)
        check(!visible, "01 switching back to an empty project removes the room")
        switching.close()

        let store = ChatLiveStore(root: root.appendingPathComponent("recovery"))
        var doc = LiveDocumentRecord()
        doc.threads = [LiveThreadRecord(title: "目前文件")]
        store.save(doc); _ = store.load()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var copy = doc; copy.threads[0].title = "較新副本"
        let candidate = ChatLiveStore.preserveUnreadable(try encoder.encode(copy), beside: store.url)!
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: candidate.path)
        check(store.restorableBackup() == nil, "02 healthy document hides older copies")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: candidate.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: store.url.path)
        check(store.restorableBackup() == candidate, "02 newer valid copy is offered")
        let recovered = try store.restoreBackup(candidate)
        check(recovered.threads[0].title == "較新副本", "02 restore uses the selected copy")
        check(store.restorableBackup() == nil, "02 used recovery is hidden despite preserved pre-restore file")
        let reopened = ChatLiveStore(root: store.url.deletingLastPathComponent()); _ = reopened.load()
        check(reopened.restorableBackup() == nil, "02 reopening does not revive pre-restore file or used copy")
        let uiStore = ChatLiveStore(root: root.appendingPathComponent("recovery-confirmation"))
        uiStore.save(doc)
        let uiOriginal = try Data(contentsOf: uiStore.url)
        let uiCandidate = ChatLiveStore.preserveUnreadable(try encoder.encode(copy), beside: uiStore.url)!
        let confirmationProbe = ConversationRecoveryRow.Probe()
        var restores = 0
        var recoveryRow = ConversationRecoveryRow(candidate: uiCandidate, isDisabled: false) {
            if (try? uiStore.restoreBackup(uiCandidate)) != nil { restores += 1 }
        }
        recoveryRow.testProbe = confirmationProbe
        let confirmation = TatwoComposerModeAcceptance.ClickRig(recoveryRow, size: CGSize(width: 700, height: 160))
        await confirmation.settle()
        try shot(confirmation, "recovery-copy-date")
        func pressRecovery() async {
            if let frame = confirmationProbe.button {
                await confirmation.click(confirmation.host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
            }
            await confirmation.settle(10)
        }
        func alertButton(_ title: String) -> NSButton? {
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == title { return button }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            guard let content = (confirmation.window.attachedSheet ?? NSApp.modalWindow)?.contentView else { return nil }
            return find(content)
        }
        await pressRecovery()
        let bytesBeforeConfirmation = try Data(contentsOf: uiStore.url)
        check(confirmationProbe.confirming && restores == 0 && bytesBeforeConfirmation == uiOriginal,
              "02 clicking recovery asks first and leaves bytes unchanged")
        let cancel = alertButton("取消")
        check(cancel != nil, "02 recovery confirmation offers cancellation")
        cancel?.performClick(nil)
        await confirmation.settle(10)
        let bytesAfterCancel = try Data(contentsOf: uiStore.url)
        check(restores == 0 && bytesAfterCancel == uiOriginal, "02 cancel never restores")
        await pressRecovery()
        let confirm = alertButton("先另存目前文件，再還原")
        check(confirm != nil, "02 recovery confirmation offers explicit preservation and restore")
        confirm?.performClick(nil)
        await confirmation.settle(10)
        check(restores == 1 && uiStore.restorableBackup() == nil, "02 confirming restores once and consumes the copy")
        confirmation.close()

        let broken = ChatLiveStore(root: root.appendingPathComponent("decode-failure"))
        try Data("invalid".utf8).write(to: broken.url); _ = broken.load()
        let valid = ChatLiveStore.preserveUnreadable(try encoder.encode(doc), beside: broken.url)!
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: valid.path)
        check(broken.restorableBackup() == valid, "02 decode failure offers even an older fully readable copy")

        let recoveryEngine = ChatLiveEngine(store: broken, environment: env)
        defer { recoveryEngine.shutdownAll() }
        check(recoveryEngine.recoveryCandidate == valid, "02 failed-load engine offers a preserved readable copy")
        recoveryEngine.restoreUnreadableConversation()
        check(recoveryEngine.recoveryCandidate == nil, "02 engine hides the recovery button after use")
        let reopenedRecovery = ChatLiveEngine(store: ChatLiveStore(root: broken.url.deletingLastPathComponent()), environment: env)
        defer { reopenedRecovery.shutdownAll() }
        check(reopenedRecovery.recoveryCandidate == nil, "02 engine reopening keeps pre-restore snapshots hidden")

        let freshStore = ChatLiveStore(root: root.appendingPathComponent("recovery-freshness"))
        freshStore.save(doc)
        let freshCandidate = ChatLiveStore.preserveUnreadable(try encoder.encode(copy), beside: freshStore.url)!
        let fixtureNow = Date()
        try FileManager.default.setAttributes([.modificationDate: fixtureNow.addingTimeInterval(300)], ofItemAtPath: freshCandidate.path)
        let freshEngine = ChatLiveEngine(store: freshStore, environment: env)
        defer { freshEngine.shutdownAll() }
        check(freshEngine.recoveryCandidate == freshCandidate, "W194-A1 newer healthy copy is offered at startup")
        freshStore.save(doc)
        try FileManager.default.setAttributes([.modificationDate: fixtureNow.addingTimeInterval(600)], ofItemAtPath: freshStore.url.path)
        check(freshStore.restorableBackup() == nil && freshEngine.recoveryCandidate == nil,
              "W194-A1 saving a newer healthy document also hides the stale engine recovery button")

        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("model")), environment: env)
        defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.setAssistantModel("fable-5.1")
        model.engineLogins = [.init(kind: .codex, isLoggedIn: true, account: nil, detail: "fixture"),
                              .init(kind: .claude, isLoggedIn: false, account: nil, detail: "fixture")]
        let checklist = SetupChecklist()
        checklist.refresh(logins: model.engineLogins, assistantModel: model.assistantSetupModel)
        check(checklist.items.first?.state == .todo, "03 Codex login does not complete selected Claude assistant setup")
        let menu = AssistantModelMenu.menu(for: model)
        check(menu.items.contains { $0.title.contains("未登入") }, "03 assistant menu marks unsigned provider")
        for reason in ["Please login", "not authenticated", "401 Unauthorized", "authentication_error", "invalid_api_key", "token expired"] {
            check(EngineFailurePresentation.make(reason, alternative: "其他模型").category == .login
                  && EngineFailurePresentation.make(reason, alternative: "其他模型").summary.contains("設定 › 登入"),
                  "03 authentication error has model-login exit: " + reason)
        }
        model.seedSendLoginStatusForSelfTest(.init(kind: .claude, isLoggedIn: true, account: nil, detail: "fixture"),
                                            checkedAt: Date().addingTimeInterval(-120))
        model.catalogRefreshTestDouble = {}
        model.loginRefreshTestDouble = { [.init(kind: .claude, isLoggedIn: false, account: nil, detail: "fixture")] }
        let before = model.loginRefreshStartsForSelfTest
        check(!model.sendToAssistant(text: "第一句"), "03 selected logged-out provider blocks assistant send")
        check(!model.sendToAssistant(text: "第二句"), "03 next send stays blocked without discarding draft")
        check(model.loginRefreshStartsForSelfTest - before == 1, "07 two assistant sends only query login once")
        check(model.catalogRefreshStartsForSelfTest == 0, "07 send preflight never starts model-list engines")
        check(engine.sidecarProcessOwners().isEmpty, "03 rejected assistant sends launch no model engine")
        model.seedSendLoginStatusForSelfTest(.init(kind: .grok, isLoggedIn: false, account: nil, detail: "fixture"), checkedAt: Date())
        check(!model.sendLoginStatusForSelfTest(.grok).isLoggedIn, "03 fresh logged-out status remains blocked")

        model.seedSendLoginStatusForSelfTest(.init(kind: .claude, isLoggedIn: false, account: nil, detail: "fixture"),
                                            checkedAt: Date().addingTimeInterval(-120))
        model.loginRefreshTestDouble = { [.init(kind: .claude, isLoggedIn: true, account: nil, detail: "fixture")] }
        var sent: [String] = []
        model.assistantEngineSendTestDouble = { text, route in
            sent.append(text + "|" + route)
            return true
        }
        let queries = model.loginRefreshStartsForSelfTest
        check(model.sendToAssistant(text: "已登入第一句") && model.sendToAssistant(text: "已登入第二句"),
              "07 two assistant messages reach the engine boundary")
        check(sent == ["已登入第一句|fable5.1", "已登入第二句|fable5.1"], "07 sends retain the selected provider and text")
        check(model.loginRefreshStartsForSelfTest - queries == 1, "07 two accepted assistant sends query login once")

        model.refreshEngineModelCatalogOnce()
        model.refreshEngineModelCatalogOnce()
        check(model.catalogRefreshStartsForSelfTest == 1, "07 model catalog triggers once per app launch")

        let readonlyStore = ChatLiveStore(root: root.appendingPathComponent("readonly"))
        try FileManager.default.createDirectory(at: readonlyStore.url, withIntermediateDirectories: true)
        let readonly = ChatLiveEngine(store: readonlyStore, environment: env)
        defer { readonly.shutdownAll() }
        let thread = readonly.doc.selectedThreadID!
        check(readonlyStore.isReadOnly, "02 unreadable original enters read-only mode")
        let originalTranscript = readonly.transcript(for: thread)
        check(!readonly.send(threadID: thread, text: "不應送出", model: "fable-5.1"), "02 read-only engine rejects send before launching")
        check(readonly.transcript(for: thread) == originalTranscript, "02 read-only rejected send leaves transcript unchanged")
        check(readonly.sidecarProcessOwners().isEmpty, "02 read-only send leaves no sidecar")

        let readonlyModel = ChatPageModel(environment: env, botCoreFixture: (readonly, BotStore(root: root)))
        readonlyModel.prompt = "唯讀模式的草稿"
        check(!readonlyModel.canSend && !readonlyModel.assistantCanSend
              && readonlyModel.localConversationReadOnlyNotice?.contains("唯讀中，不能送出") == true,
              "02 composer clearly warns and disables send")
        readonlyModel.send()
        check(readonlyModel.prompt == "唯讀模式的草稿", "02 read-only composer preserves the draft")
        let composer = TatwoComposerModeAcceptance.ClickRig(ChatPage(model: readonlyModel).composer(contentMaxWidth: 720),
                                                           size: CGSize(width: 840, height: 680))
        await composer.settle()
        try shot(composer, "readonly-composer")
        composer.close()

        var status = EngineLoginStatus(kind: .codex, isLoggedIn: true, account: nil, detail: "fixture")
        status.executableChoice = .init(executable: URL(fileURLWithPath: "/example/runtime/codex"), version: "2.0.0",
                                        source: "本機", reason: "Developer ID Team ID CLI fixture")
        model.engineLogins = [status]
        let loginProbe = EngineLoginCard.Probe()
        var card = EngineLoginCard(model: model)
        card.testProbe = loginProbe
        let login = TatwoComposerModeAcceptance.ClickRig(card, size: CGSize(width: 840, height: 680))
        await login.settle()
        check(loginProbe.expanded.isEmpty && EngineLoginCard.runtimeSummary(status.executableChoice!) == "用的是本機較新的版本",
              "04 runtime diagnostics start collapsed with a plain summary")
        try shot(login, "model-login-collapsed")
        if let frame = loginProbe.details[.codex] {
            await login.click(login.host.convert(NSPoint(x: frame.minX + 3, y: frame.midY), to: nil))
        }
        await login.settle()
        check(loginProbe.expanded.contains(.codex), "04 details can be expanded through the rendered disclosure")
        try shot(login, "model-login-expanded")
        login.close()
        for state in [TatwoPlanArtifactV1.State.discussing, .ready] {
            var plan = TatwoPlanArtifactV1(threadID: UUID(), objective: "驗收用計畫", kind: "pr")
            plan.state = state
            plan.sections = [.init(title: "改動", body: "修正畫布按鈕")]
            plan.prReview = PRPlanReview(directory: root, repository: "example/repository", account: "示範帳號",
                                         snapshot: .init(head: "fixture", status: "", diff: "", stat: "", origin: "https://example.invalid/repository"))
            var actions = PRPlanActions(artifact: plan, isDisabled: false, onConfirm: {}, onSubmit: {}, onReturnToDiscussion: {})
            actions.testLoggedIn = true
            let pr = TatwoComposerModeAcceptance.ClickRig(actions, size: CGSize(width: 840, height: 360))
            await pr.settle()
            try shot(pr, "pr-" + state.rawValue)
            pr.close()
        }
        print("W192UX SUMMARY passed=\(passed) failures=\(failures)")
        return failures == 0
    }
}
#endif
