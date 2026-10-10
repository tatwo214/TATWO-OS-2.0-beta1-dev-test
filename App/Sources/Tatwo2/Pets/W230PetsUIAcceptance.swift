#if DEBUG
import Foundation
import AppKit
import SwiftUI

@MainActor enum W230PetsUIAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let artifacts = URL(fileURLWithPath: path), root = artifacts.appendingPathComponent("ui-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var failures = 0, passed = 0
        func check(_ value: Bool, _ label: String) { if value { passed += 1 } else { failures += 1 }; print("W230PETSUI \(value ? "PASS" : "FAIL") \(label)") }
        let script = root.appendingPathComponent("reply.mjs")
        try #"""
        import readline from 'node:readline';
        readline.createInterface({input:process.stdin}).on('line', line => {
          const c=JSON.parse(line); if(c.op==='close') process.exit(0); if(c.op!=='send') return;
          const emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
          emit({type:'system',subtype:'init',session_id:'pet-ui-fixture',model:'fixture'});
          setTimeout(() => { emit({type:'stream_event',client_turn_id:c.uuid,event:{type:'content_block_delta',delta:{type:'text_delta',text:'寵物已收到：'+c.text}}});
          emit({type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false,usage:{output_tokens:1200}}); }, 500);
        });
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior; overrides["tatwo2.sidecarPath.codex"] = script.path; overrides["tatwo2.sidecarPath.claude"] = script.path
        overrides["tatwo.pets.enabled"] = true; defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let liveStore = ChatLiveStore(root: root); var document = LiveDocumentRecord()
        let ids = (0..<8).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            let workdir = URL(fileURLWithPath: env["HOME"]!).appendingPathComponent("projects/pet-\(i+1)")
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            document.projects.append(LiveProjectRecord(id: id, name: i == 0 ? "這是一隻名稱很長需要截斷顯示的寵物" : "寵物 \(i+1)", workdir: workdir.path))
            var thread = LiveThreadRecord(projectID: id); thread.title = "工作 \(i+1)"; thread.updatedAt = Date(timeIntervalSince1970: Double(100+i)); document.threads.append(thread)
        }
        document.selectedThreadID = document.threads.last?.id; try liveStore.saveChecked(document)
        var environment = env; environment["TATWO2_LIVE_ROOT"] = root.path
        let engine = ChatLiveEngine(store: liveStore, environment: environment)
        defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(root: root))); model.engineLoginTestDouble = [.codex, .claude]
        let state = PetsViewModel(model: model), store = try state.chat.store(), selected = model.selectedThreadID
        let coderBytes = try Data(contentsOf: liveStore.url)
        check(PetSettings.enabled() && ChatRunMode.bot.rawValue == "Bot" && ChatRunMode.bot.displayName == "寵物", "1 switch defaults, stable Bot rawValue and pet display name")
        state.editTeams { $0.departments.append(PetDepartment(name: "研發")) }
        let department = store.teams.departments.last!.id
        state.editTeams { $0.departments[$0.departments.count-1].name = "設計"; $0.teams.append(PetTeam(departmentID: department, name: "第二隊")); $0.links.append(PetLink(from: $0.departments[0].id, to: department)) }
        check(store.teams.departments.last?.name == "設計" && store.teams.links.count == 1, "3 add and rename departments, add team and link")
        let team = store.teams.teams[0].id, incoming = store.backpack[0].id, outgoing = store.teams.teams[0].members[0]
        state.move(incoming, to: team)
        check(state.swap?.0 == incoming && store.teams.teams[0].members.count == 6, "7 full team requests replacement without mutation")
        state.replace(outgoing)
        check(store.teams.teams[0].members.contains(incoming) && store.backpack.contains { $0.id == outgoing }, "7 replace atomically, outgoing enters backpack")
        state.move(incoming, to: nil); state.move(incoming, to: team)
        check(store.teams.teams[0].members.count == 6 && store.pets.count == 8, "7 button moves preserve all pets and membership cap")
        state.deleteDepartment(store.teams.departments[0].id)
        check(store.teams.departments.count == 2, "3 occupied department cannot be deleted")
        state.deleteDepartment(department)
        check(store.teams.departments.count == 1 && store.teams.links.isEmpty, "3 delete empty department removes its teams and links")
        state.editTeams { $0.teams[0].name = "主隊" }
        let documentAfter = try Data(contentsOf: liveStore.url)
        check(store.teams.teams[0].name == "主隊" && documentAfter == coderBytes, "3 team rename does not modify Coder document")
        state.open(incoming); state.draft = "請檢查畫面"; state.send()
        for _ in 0..<500 { if let thread = state.thread, !engine.isRunning(thread) { break }; try await Task.sleep(for: .milliseconds(10)) }
        state.refresh()
        check(state.thread.map { model.dmTranscript(for: $0).contains { $0.role == .assistant && $0.text.contains("寵物已收到") } } == true && model.selectedThreadID == selected && engine.doc.selectedThreadID == selected, "4 reply renders through shared DM transcript, both Coder selections unchanged")
        check(await state.refreshTask?.value != nil, "4 background event refresh completes before profile verification")
        check(state.profiles[incoming]?.progress.experience == 12, "4 reply tokens update profile experience")
        let session = state.chat.sessions(projectID: incoming).first!
        check(state.chat.newSession(projectID: UUID()) == nil && engine.doc.assistantProjectID.map { state.chat.newSession(projectID: $0) == nil } != false, "1 newSession rejects missing and assistant projects")
        state.open(incoming, session: session.id)
        check(state.thread == session.id && state.page == .stage, "5 selected session opens on stage")
        try store.chooseAvatar(incoming, avatar: PetAvatars.catalog.last!)
        try store.updatePersonality(incoming, PetPersonality(strengthen: "求簡潔", restrain: "手腳快", custom: "先說結果")); state.refresh()
        check(state.profiles[incoming]?.pet.personality.custom == "先說結果" && store.pet(incoming)?.avatar == PetAvatars.catalog.last, "6 avatar and personality persist via public API")
        let exported = try state.chat.export(projectID: incoming, to: artifacts)
        check(FileManager.default.fileExists(atPath: exported.appendingPathComponent("avatar.png").path), "6 pet export contains avatar")
        var hall = PetHallEntry(name: "完成寵物畫面", date: Date(), participants: [.init(projectID: incoming, responsibility: "施工")])
        try store.saveHall([hall]); hall.name = "寵物畫面驗收"; try store.saveHall([hall]); state.refresh()
        let reloaded = try PetStore(liveRoot: root)
        check(reloaded.hall.first?.name == hall.name && reloaded.teams == store.teams && reloaded.pet(incoming)?.personality == store.pet(incoming)?.personality, "8 hall registration/edit and pet state survive reload")
        let visualDepartment = PetDepartment(name: "設計"), visualTeam = PetTeam(departmentID: UUID(), name: "驗收")
        state.editTeams { value in var team = visualTeam; team.departmentID = visualDepartment.id; value.departments.append(visualDepartment); value.teams.append(team); value.links.append(PetLink(from: value.departments[0].id, to: visualDepartment.id)) }
        state.move(outgoing, to: visualTeam.id)
        let theme = TatwoThemeStore.shared, priorTheme = theme.activeThemeID
        defer { theme.select(priorTheme) }
        if let coder = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).composer(contentMaxWidth: nil), size: CGSize(width: 900, height: 220)),
           let input = textViews(coder.host).first(where: { $0.accessibilityLabel() == "Chat message" }) {
            defer { model.prompt = ""; coder.close() }
            input.setAccessibilityValue("Coder 第一行"); pump()
            coder.window.makeFirstResponder(input)
            input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
            if let event = key(36, "\r", modifiers: .shift, window: coder.window) { NSApp.postEvent(event, atStart: false) }
            try await Task.sleep(for: .milliseconds(120)); pump()
            print("W230PETSUI NOTE Coder postEvent newline=\(model.prompt.contains(where: { $0.isNewline })) focused=\(coder.window.firstResponder === input) keyWindow=\(NSApp.keyWindow?.windowNumber ?? -1) target=\(coder.window.windowNumber)")
            if let event = key(36, "\r", modifiers: .shift, window: coder.window) { coder.window.sendEvent(event) }; pump()
            check(model.prompt.contains(where: { $0.isNewline }), "2 Coder window-dispatched Shift-Enter inserts newline")
        } else { check(false, "2 Coder shared composer keyboard probe") }
        let pages: [(PetsViewModel.Page, String)] = [(.teams,"teams"),(.stage,"stage"),(.profile,"profile"),(.exchange,"exchange"),(.backpack,"backpack"),(.hall,"hall")]
        for themeID in TatwoThemeID.allCases { theme.select(themeID)
            if themeID == .fable5 { check(theme.active.palette.fixedLightAppearance && NSApp.appearance?.name == .aqua, "10 fable5 always uses light App appearance") }
            for dark in theme.active.palette.fixedLightAppearance ? [false] : [false,true] {
                let scheme: ColorScheme = dark ? .dark : .light, suffix = themeID.rawValue + (dark ? "-dark" : "-light")
                for (page, name) in pages {
                    state.page = page
                    if page == .profile {
                        var personality = store.pet(incoming)!.personality; personality.custom = String(repeating: "性格捲動\n", count: 20)
                        try store.updatePersonality(incoming, personality); state.refresh()
                    }
                    guard let shot = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900), scheme: scheme) else { check(false, "\(name) render"); continue }
                    let identifiers = GlobalDMChatAcceptance.identifiers(in: shot)
                    check(identifiers.contains("tatwo.pets.\(name)"), "10 \(suffix) \(name) accessibility")
                    if page == .profile {
                        if let scroll = textViews(shot.host).first?.enclosingScrollView {
                            check(!scroll.hasVerticalScroller || scroll.verticalScroller?.isHidden == true, "6 \(suffix) overflowing personality editor has no permanent scrollbar")
                        } else { check(false, "6 personality native scroll view") }
                    }
                    GlobalDMChatAcceptance.save(shot, name + "-" + suffix + ".png", to: artifacts); shot.close()
                }
                state.page = .stage; state.sessionsFor = incoming
                if let shot = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900), scheme: scheme) {
                    let windows = NSApplication.shared.windows.filter { $0 != shot.window && $0.contentView != nil }
                    var captured = false, newEnabled = false
                    for window in windows {
                        guard let host = window.contentView, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let popup = GlobalDMChatAcceptance.Rendered(host: host, window: window, bitmap: bitmap, size: host.bounds.size)
                        if GlobalDMChatAcceptance.identifiers(in: popup).contains("tatwo.pets.sessions") {
                            GlobalDMChatAcceptance.save(popup, "sessions-" + suffix + ".png", to: artifacts); captured = true
                            newEnabled = enabledElement("tatwo.pets.session.new.\(incoming)", in: host)
                        }
                    }
                    check(captured, "5 \(suffix) native session popover screenshot")
                    check(newEnabled, "5 new conversation enabled")
                    let before = Set(state.chat.sessions(projectID: incoming).map(\.id)), oldTranscript = model.dmTranscript(for: session.id)
                    let pressed = windows.compactMap(\.contentView).contains { press("tatwo.pets.session.new.\(incoming)", in: $0) }
                    pump()
                    check(pressed && state.page == .stage && state.sessionsFor == nil && state.thread.map { !before.contains($0) && engine.threadRecord($0)?.projectID == incoming && model.dmTranscript(for: $0).isEmpty } == true && state.draft.isEmpty, "1 \(suffix) popover action opens a new blank stage")
                    check(model.selectedThreadID == selected && engine.doc.selectedThreadID == selected && model.dmTranscript(for: session.id).map(\.text) == oldTranscript.map(\.text), "1 new conversation preserves Coder selections and previous transcript")
                    state.sessionsFor = nil; shot.close()
                    if let blank = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900), scheme: scheme) {
                        GlobalDMChatAcceptance.save(blank, "new-stage-" + suffix + ".png", to: artifacts)
                        if let input = textViews(blank.host).first(where: { $0.accessibilityLabel() == "對寵物說話" }) {
                            input.setAccessibilityValue("第一行"); pump(); input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
                            blank.window.makeFirstResponder(input)
                            if let event = key(36, "\r", modifiers: .shift, window: blank.window) { blank.window.sendEvent(event) }; pump()
                            print("W230PETSUI NOTE Shift-Enter scalars=\(state.draft.unicodeScalars.map(\.value)) focused=\(blank.window.firstResponder === input)")
                            check(state.draft.contains(where: { $0.isNewline }) && state.thread.map { model.dmTranscript(for: $0).isEmpty } == true, "2 Shift-Enter inserts newline without sending")
                            if let event = key(36, "\r", window: blank.window) { blank.window.sendEvent(event) }
                            check(state.thread.map { model.dmSessionIsRunning($0) } == true, "2 composer reports sending state")
                            pump()
                            check(state.draft.isEmpty && state.thread.map { model.dmTranscript(for: $0).contains { $0.role == .user && $0.text.contains("第一行") } } == true, "2 Enter sends to the new session")
                        } else { check(false, "2 native shared composer text view") }
                        blank.close()
                        for _ in 0..<500 { if let thread = state.thread, !engine.isRunning(thread) { break }; try await Task.sleep(for: .milliseconds(10)) }
                    } else { check(false, "1 new stage screenshot") }
                    state.open(incoming, session: session.id)
                } else { check(false, "5 session popover render") }
                state.page = .profile; state.avatarsOpen = true
                if let profile = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900), scheme: scheme) {
                    var gridCaptured = false
                    for window in NSApplication.shared.windows where window != profile.window {
                        guard let host = window.contentView, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let grid = GlobalDMChatAcceptance.Rendered(host: host, window: window, bitmap: bitmap, size: host.bounds.size)
                        let ids = GlobalDMChatAcceptance.identifiers(in: grid)
                        if ids.contains("tatwo.pets.avatars") {
                            check(PetAvatars.catalog.allSatisfy { ids.contains("tatwo.pets.avatar.choose." + $0) } && ids.contains("tatwo.pets.avatar.upload"), "7 twelve visible avatar choices and upload")
                            GlobalDMChatAcceptance.save(grid, "avatars-" + suffix + ".png", to: artifacts); gridCaptured = true
                            check(press("tatwo.pets.avatar.choose.pixel-0", in: host), "7 avatar grid choice is clickable"); pump()
                            check(store.pet(incoming)?.avatar == "pixel-0" && !state.avatarsOpen, "7 avatar choice saves and closes grid")
                            break
                        }
                    }
                    check(gridCaptured, "7 \(suffix) avatar grid screenshot"); state.avatarsOpen = false; profile.close()
                } else { check(false, "7 avatar grid render") }
                state.page = .teams; state.renameID = store.teams.departments[0].id; state.renameDraft = "隊伍改名中"
                if let rename = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900), scheme: scheme) {
                    check(GlobalDMChatAcceptance.identifiers(in: rename).contains("tatwo.pets.department.name.\(store.teams.departments[0].id)"), "3 department title enters rename field")
                    GlobalDMChatAcceptance.save(rename, "rename-" + suffix + ".png", to: artifacts)
                    let original = store.teams.departments[0].name
                    if let editor = rename.window.firstResponder as? NSTextView, let escape = key(53, "\u{1b}", window: rename.window) {
                        editor.keyDown(with: escape); pump()
                        check(state.renameID == nil && store.teams.departments[0].name == original, "3 Esc cancels rename without persisting")
                    } else { check(false, "3 focused rename editor") }
                    rename.close(); state.renameID = nil
                    for operation in ["enter", "blur"] {
                        state.renameID = store.teams.departments[0].id; state.renameDraft = original + operation
                        if let edit = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900), scheme: scheme) {
                            if let editor = edit.window.firstResponder as? NSTextView {
                                if operation == "enter", let event = key(36, "\r", window: edit.window) { editor.keyDown(with: event) } else { edit.window.makeFirstResponder(nil) }; pump()
                                check(store.teams.departments[0].name == original + operation && state.renameID == nil, "3 \(operation) commits rename")
                            } else { check(false, "3 commit rename editor") }
                            edit.close()
                        } else { check(false, "3 commit rename render") }
                    }
                    state.renameID = nil; state.editTeams { $0.departments[0].name = original }
                } else { check(false, "3 rename screenshot") }
            }
        }
        let emptyRoot = artifacts.appendingPathComponent("empty-live"); var emptyEnv = env; emptyEnv["TATWO2_LIVE_ROOT"] = emptyRoot.path
        let emptyStore = ChatLiveStore(root: emptyRoot); var emptyDocument = LiveDocumentRecord()
        _ = emptyDocument.ensureAssistantProject(); try emptyStore.saveChecked(emptyDocument)
        let emptyEngine = ChatLiveEngine(store: emptyStore, environment: emptyEnv)
        defer { emptyEngine.shutdownAll() }
        let emptyModel = ChatPageModel(environment: emptyEnv, botCoreFixture: (emptyEngine, BotStore(root: emptyRoot)))
        for themeID in TatwoThemeID.allCases { theme.select(themeID); for dark in theme.active.palette.fixedLightAppearance ? [false] : [false,true] {
            if let shot = GlobalDMChatAcceptance.renderSync(PetsRootView(model: emptyModel), size: CGSize(width: 1280, height: 900), scheme: dark ? .dark : .light) {
                check(GlobalDMChatAcceptance.identifiers(in: shot).contains("tatwo.pets.empty.coder"), "9 empty projects expose Coder action")
                GlobalDMChatAcceptance.save(shot, "empty-\(themeID.rawValue)-\(dark ? "dark" : "light").png", to: artifacts); shot.close()
            } else { check(false, "9 empty render") }
        } }
        try store.saveHall([])
        check(store.hall.isEmpty && store.pets.count == 8, "8 delete only hall record")
        overrides["tatwo.pets.enabled"] = false; defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        check(!PetSettings.enabled(), "1 disabled switch selects retained bot branch")
        model.mode = .bot
        if let legacy = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).mainPane(contentMaxWidth: nil), size: CGSize(width: 1280, height: 900)) {
            let identifiers = GlobalDMChatAcceptance.identifiers(in: legacy)
            check(identifiers.contains("bot.space.add") && !identifiers.contains("tatwo.pets.root"), "1 disabled switch renders original BotStudioRootView")
            GlobalDMChatAcceptance.save(legacy, "legacy-bot.png", to: artifacts); legacy.close()
        } else { check(false, "1 disabled switch legacy render") }
        print("W230PETSUI SUMMARY failures=\(failures) passed=\(passed)"); return failures == 0
    }
    private static func pump() { for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) } }
    private static func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
    private static func textViews(_ root: NSView) -> [NSTextView] { (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap { textViews($0) } }
    private static func press(_ id: String, in host: NSView) -> Bool {
        guard let element = DMBrowserAcceptance.axCollect(host, [id])[id] else { return false }; return DMBrowserAcceptance.axPress(element)
    }
    private static func enabledElement(_ id: String, in root: NSView) -> Bool {
        var seen = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> Bool {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return false }
            func attribute(_ selector: String, _ legacy: String) -> Any? {
                let modern = NSSelectorFromString(selector), old = NSSelectorFromString("accessibilityAttributeValue:")
                if object.responds(to: modern), let value = object.perform(modern)?.takeUnretainedValue() { return value }
                return object.responds(to: old) ? object.perform(old, with: legacy)?.takeUnretainedValue() : nil
            }
            if attribute("accessibilityIdentifier", "AXIdentifier") as? String == id {
                if let element = object as? NSAccessibilityProtocol { return element.isAccessibilityEnabled() }
                let selector = NSSelectorFromString("isAccessibilityEnabled")
                if object.responds(to: selector), let implementation = object.method(for: selector) {
                    typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
                    return unsafeBitCast(implementation, to: Enabled.self)(object, selector)
                }
                return attribute("AXEnabled", "AXEnabled") as? Bool == true
            }
            var children = attribute("accessibilityChildren", "AXChildren") as? [NSObject] ?? []
            if let view = object as? NSView { children += view.subviews }
            return children.contains { find($0) }
        }
        return find(root)
    }
}
#endif
