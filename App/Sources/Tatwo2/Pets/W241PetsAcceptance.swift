#if DEBUG
import Foundation
import AppKit
import SwiftUI

@MainActor enum W241PetsAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let root = URL(fileURLWithPath: path).appendingPathComponent("pets-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var failures = 0, passed = 0
        func check(_ ok: Bool, _ label: String) { if ok { passed += 1 } else { failures += 1 }; print("W241PETS \(ok ? "PASS" : "FAIL") \(label)") }
        try await queueChecks(root: root, env: env, check: check)
        try await projectChecks(root: root.appendingPathComponent("mapping"), env: env, check: check)
        try await draftChecks(root: root.appendingPathComponent("drafts"), env: env, check: check)
        try await performanceChecks(root: root.appendingPathComponent("performance"), env: env, check: check)
        progressChecks(check: check)
        try await visualChecks(root: root.appendingPathComponent("visual"), artifacts: URL(fileURLWithPath: path), env: env, check: check)
        print("W241PETS SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw TapError.remote("W241 fixture timeout")
    }
    private static func visualChecks(root: URL, artifacts: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "寵物驗收", workdir: root.path), id = engine.newThread(in: project)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        let state = PetsViewModel(model: model); state.open(project, session: id); state.page = .profile
        try await until { state.refreshTask == nil }
        let original = state.profiles[project]!, theme = TatwoThemeStore.shared, prior = theme.activeThemeID
        defer { theme.select(prior) }
        for themeID in TatwoThemeID.allCases {
            theme.select(themeID)
            for dark in theme.active.palette.fixedLightAppearance ? [false] : [false, true] {
                let scheme: ColorScheme = dark ? .dark : .light, suffix = themeID.rawValue + (dark ? "-dark" : "-light")
                for (name, experience) in [("profile-lv99", 970299), ("profile-badge", 1000000)] {
                    let progress = PetProgress(creditedTokens: Int64(experience) * 100)
                    state.profiles[project] = PetProfile(pet: original.pet, name: original.name, workdir: original.workdir, progress: progress, encounteredAt: original.encounteredAt, sessions: original.sessions, skills: original.skills)
                    guard let shot = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900), scheme: scheme) else { throw TapError.notReady }
                    let text = W214Acceptance.text(shot)
                    check(text.contains("Lv \(progress.level)") && text.contains(progress.levelExperience.formatted() + " / " + progress.nextLevelExperience.formatted()), "P5 \(name)-\(suffix) displays level and matching experience text")
                    GlobalDMChatAcceptance.save(shot, name + "-" + suffix + ".png", to: artifacts); shot.close()
                }
                let hall = PetHallEntry(name: "冠軍殿堂驗收", date: Date(), participants: [.init(projectID: project, responsibility: "寵物與群組施工")])
                var saved: PetHallEntry?
                let skin = PetSkin(palette: theme.active.palette, dark: dark)
                guard let shot = GlobalDMChatAcceptance.renderSync(PetHallEditor(entry: hall, profiles: state.profiles, skin: skin, save: { saved = $0 }, cancel: {}), size: CGSize(width: 800, height: 700), scheme: scheme) else { throw TapError.notReady }
                await W214Acceptance.settle(shot)
                let fields = W214Acceptance.nodes(shot).compactMap { $0 as? NSTextField }.filter(\.isEditable)
                check(fields.count == 2 && fields.allSatisfy { !$0.isBezeled && $0.focusRingType == .none }, "P6 \(suffix) hall fields have no border or blue focus ring")
                if let field = fields.first { shot.window.makeFirstResponder(field); field.selectText(nil) }
                GlobalDMChatAcceptance.save(shot, "hall-editor-" + suffix + ".png", to: artifacts)
                if let button = DMBrowserAcceptance.axCollect(shot.host, ["tatwo.pets.hall.save"])["tatwo.pets.hall.save"] {
                    check(DMBrowserAcceptance.axPress(button) && saved == hall, "P6 \(suffix) native save keeps editable hall data")
                } else { check(false, "P6 native hall save button") }
                shot.close()
            }
        }
    }
    private static func progressChecks(check: (Bool, String) -> Void) {
        for (experience, level, badges, current, required) in [(0,1,0,0,8), (970299,99,0,0,29701), (1000000,1,1,0,8), (1125000,50,1,0,7651)] {
            let progress = PetProgress(creditedTokens: Int64(experience) * 100)
            check(progress.level == level && progress.badges == Int64(badges) && progress.levelExperience == Double(current) && progress.nextLevelExperience == Double(required) && progress.levelFraction == 0, "P5 E=\(experience) Lv\(level) badge\(badges) text and bar share level progress")
        }
        let halfway = PetProgress(creditedTokens: 112882550)
        check(halfway.level == 50 && halfway.levelExperience == 3825.5 && halfway.nextLevelExperience == 7651 && halfway.levelFraction == 0.5, "P5 second-cycle partial level uses matching text and bar fraction")
        check(PetProgress(creditedTokens: 99999999).level == 99 && PetProgress(creditedTokens: 200000000).badges == 2, "P5 Lv99 remains visible until each 100 cubed badge")
    }
    private static func performanceChecks(root: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        let tap = W185FakeConversationTap(), engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "效能驗收", workdir: root.path), id = engine.newThread(in: project)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        let state = PetsViewModel(model: model); state.open(project, session: id)
        try await until { state.refreshTask == nil }
        guard let shot = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900)) else { throw TapError.notReady }
        defer { shot.close() }
        check(state.chat.eventProfileReads[project] == 1, "P4 initial event profile computes once")
        for _ in 0..<100 { model.objectWillChange.send(); await Task.yield() }
        try await until { state.refreshTask == nil }
        check(state.chat.eventProfileReads[project] == 1, "P4 100 streaming notifications keep one event computation")
        let log = OSEventLog.atRoot(root)
        log.append(project: project, thread: id, actor: "fixture", kind: "turn_end", tokens: 1200)
        log.append(project: project, thread: id, actor: "fixture", kind: "tool_step", used: ["$fixture"])
        model.objectWillChange.send(); try await until { state.refreshTask == nil && state.profiles[project]?.progress.experience == 12 }
        check(state.chat.eventProfileReads[project] == 2 && state.profiles[project]?.skills == [PetSkill(name: "$fixture", count: 1)], "P4 event change refreshes experience and skills once")
        let store = try state.chat.store(), file = store.root.appendingPathComponent("pets.json")
        try store.updatePersonality(project, PetPersonality(strengthen: "求簡潔", restrain: "手腳快")); state.refresh()
        func inode() throws -> UInt64 { (try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber).uint64Value }
        let before = try inode(); var writes = 0, previous = before
        for n in 1...20 {
            state.editCustom(project, text: String(repeating: "字", count: n))
            try await Task.sleep(for: .milliseconds(10)); let current = try inode(); if current != previous { writes += 1 }; previous = current
        }
        check(writes == 0 && store.pet(project)?.personality.custom == "", "P4 typing 20 characters never writes during typing")
        try await Task.sleep(for: .milliseconds(650)); let after = try inode(); if after != previous { writes += 1 }
        check(writes == 1 && store.pet(project)?.personality.custom == String(repeating: "字", count: 20), "P4 20 characters persist once after 0.5 seconds idle")
        state.editCustom(project, text: "離開立即儲存"); state.commitCustom(project)
        check(store.pet(project)?.personality == PetPersonality(strengthen: "求簡潔", restrain: "手腳快", custom: "離開立即儲存"), "P4 explicit commit preserves presets and saves immediately")
        try await Task.sleep(for: .milliseconds(650)); check(try inode() != after && state.customDrafts.isEmpty, "P4 committed personality has no delayed draft")
    }
    private static func draftChecks(root: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        let tap = W185FakeConversationTap(), catalog = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(catalog) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "草稿驗收", workdir: root.path), id = engine.newThread(in: project)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        engine.setModelPreferences(threadID: id, model: ChatGPTTapModelCatalog.routeID("fixture-model"), effort: "", speedTier: "")
        let state = PetsViewModel(model: model); state.open(project, session: id)
        state.draft = "失敗原文"; state.send(); try await until { tap.sent.count == 1 }
        tap.emit(.notSubmitted("沒有送出 fixture")); try await until { !engine.isRunning(id) }
        check(state.draft == "失敗原文" && state.notice == ChatPageModel.undeliveredMessage(.notDelivered("沒有送出 fixture")), "P3 failed send returns original draft and reason")
        state.draft = "排隊原文"; state.send(); try await until { tap.sent.count == 2 }
        state.draft = "新的字"; tap.emit(.notSubmitted("排隊取消 fixture")); try await until { !engine.isRunning(id) }
        check(state.draft == "新的字" && state.undelivered[id] == "排隊原文", "P3 queue cancellation preserves new text and holds original")
        state.restoreUndelivered()
        check(state.draft == "排隊原文\n新的字" && state.undelivered.isEmpty && tap.sent.count == 2, "P3 explicit restore prepends original without sending")
        tap.modelFailure = true; ChatGPTTapModelCatalog.replace([])
        state.draft = "查詢失敗原文"; state.send(); try await until { !engine.isRunning(id) }
        check(state.draft == "查詢失敗原文" && tap.sent.count == 2, "P3 model query failure returns original without sending")
        tap.modelFailure = false; ChatGPTTapModelCatalog.replace([])
        state.draft = "換對話原文"; state.send(); try await until { tap.sent.count == 3 }
        let other = engine.newThread(in: project); state.open(project, session: other); state.draft = "別條新字"
        tap.emit(.notSubmitted("未送出 fixture")); try await until { !engine.isRunning(id) }
        check(state.draft == "別條新字" && state.undelivered[id] == "換對話原文", "P3 return belongs to original session after navigation")
        state.open(project, session: id); state.restoreUndelivered()
        check(state.draft == "換對話原文", "P3 original session can recover held draft")
    }
    private static func projectChecks(root: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = W185FakeConversationTap(), waiting = MappingTap(tap: fake), catalog = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(catalog) }
        ChatGPTTapModelCatalog.replace(try await waiting.models().items)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: waiting)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "群組驗收", workdir: root.path), id = engine.newThread(in: project)
        var finished = false, reason = ""
        engine.groupBridge.taps[0].invoke(id, "群組假訊息") { result in finished = true; if case .failure(let error) = result { reason = error.localizedDescription } }
        try await until { waiting.waiting }
        check(fake.modelCalls > 0 && fake.createdNames.isEmpty, "P2 models completed before project lookup is held")
        engine.markControllerThread(id, fingerprint: "fixture-controller")
        waiting.resume?.resume(); waiting.resume = nil
        try await until { finished }
        check(fake.createdNames.isEmpty && fake.sent.isEmpty && reason.contains("受管對話不能使用 ChatGPT TAP"), "P2 managed between models and creation never creates or sends")
        check(try await engine.tapMapper.storage.load(at: root) == nil, "P2 refused creation never saves mapping")
        var managed = false
        let guarded = GroupGuardedTap(tap: fake) { managed ? "受管 fixture" : nil }
        let mapper = TapProjectMapper(tap: guarded, storage: TapProjectMapStore(), inboxFolder: root.appendingPathComponent("inbox"))
        let folder = root.appendingPathComponent("record"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = TapProjectDestination(folder: folder, map: TapProjectMap(chatgpt_project_id: "g-p-fixture", name: "fixture"), conversationID: nil, notice: nil)
        managed = true
        do { try await mapper.record("fixture-conversation", threadID: id, destination: destination); check(false, "P2 managed mapping write refused") }
        catch { check(try await mapper.storage.load(at: folder) == nil, "P2 managed mapping write refused") }
    }
    private final class MappingTap: GroupGuardedTap {
        var waiting = false; var resume: CheckedContinuation<Void, Never>?
        override func projects() async throws -> [TapFolder] {
            waiting = true; await withCheckedContinuation { resume = $0 }
            return try await super.projects()
        }
    }
    private static func queueChecks(root: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        let pod = DispatchTapPod(), tap = ChatGPTTap(transport: pod), catalog = ChatGPTTapModelCatalog.snapshot
        defer { tap.sleep(); ChatGPTTapModelCatalog.replace(catalog) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "寵物驗收", workdir: root.path), thread = engine.newThread(in: project)
        engine.setModelPreferences(threadID: thread, model: ChatGPTTapModelCatalog.routeID("fixture-model"), effort: "", speedTier: "")
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        let pet = PetChat(model: model)
        check(pet.send(projectID: project, threadID: thread, text: "喚醒假 Pod"), "P1 sleeping TAP accepts pet send")
        try await until { pod.sends.count == 1 }
        pod.stream("finished"); try await until { !engine.isRunning(thread) }
        let active = tap.send(text: "active fixture", conversationID: nil, model: nil, effort: nil, attachments: [], tool: nil, gizmoID: nil, temporary: false, parentID: nil)
        var reasons: [String] = []
        check(pet.send(projectID: project, threadID: thread, text: "排隊寵物", onUndelivered: { reasons.append($0) }), "P1 pet enters TAP queue")
        try await until { tap.queuedSendCount == 1 }
        let sent = pod.sends.count
        engine.markControllerThread(thread, fingerprint: "fixture-controller")
        try await until { !engine.isRunning(thread) }
        check(tap.queuedSendCount == 0 && pod.sends.count == sent && reasons.count == 1 && reasons[0].contains("受管對話不能使用 ChatGPT TAP"), "P1 managed marker empties queue, sends nothing and reports one reason")
        check(engine.transcript(for: thread).filter { $0.status == "error|沒有送出" }.count == 1, "P1 original reply owns cancellation notice")
        pod.stream("finished"); check(pod.sends.count == sent, "P1 cancelled pet never dispatches after active finishes")
        withExtendedLifetime(active) {}
    }
}
#endif
