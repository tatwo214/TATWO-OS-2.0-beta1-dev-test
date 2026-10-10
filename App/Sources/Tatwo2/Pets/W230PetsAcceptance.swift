#if DEBUG
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor enum W230PetsAcceptance {
    static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let path = environment["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let root = URL(fileURLWithPath: path).appendingPathComponent("pets-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var failures = 0, passed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("W230PETS PASS " + label) }
            else { failures += 1; print("W230PETS FAIL " + label) }
        }
        func rejects(_ work: () throws -> Void) -> Bool { do { try work(); return false } catch { return true } }
        func until(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw NSError(domain: "W230PETS", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
        let script = root.appendingPathComponent("usage.mjs")
        try #"""
        import readline from 'node:readline';
        const emit = msg => console.log(JSON.stringify({ev:'sdk',msg}));
        readline.createInterface({input:process.stdin}).on('line', line => {
          const c = JSON.parse(line);
          if (c.op === 'close') process.exit(0);
          if (c.op !== 'send') return;
          emit({type:'system',subtype:'init',session_id:'fixture',model:'fixture-model'});
          emit({type:'stream_event',client_turn_id:c.uuid,event:{type:'content_block_delta',delta:{type:'text_delta',text:c.text}}});
          const usage = c.text.startsWith('no-usage') ? {} : {usage:{input_tokens:999999,output_tokens:321,output_tokens_details:{thinking_tokens:123}}};
          emit({type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false,...usage});
        });
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior; overrides["tatwo2.sidecarPath.codex"] = script.path; overrides["tatwo2.sidecarPath.claude"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        var env = environment; env["TATWO2_LIVE_ROOT"] = root.path
        let fixtureStore = ChatLiveStore(root: root)
        var fixtureDoc = LiveDocumentRecord()
        let projects = (0..<8).map { _ in UUID() }
        for (i, id) in projects.enumerated() {
            fixtureDoc.projects.append(LiveProjectRecord(id: id, name: "pet \(i)", workdir: root.path))
            var thread = LiveThreadRecord(projectID: id)
            thread.updatedAt = Date(timeIntervalSince1970: Double(100 + i))
            thread.createdAt = Date(timeIntervalSince1970: Double(10 + i))
            fixtureDoc.threads.append(thread)
        }
        fixtureDoc.selectedThreadID = fixtureDoc.threads.last?.id
        try fixtureStore.saveChecked(fixtureDoc)
        let engine = ChatLiveEngine(store: fixtureStore, environment: env)
        defer { engine.shutdownAll() }
        let selected = engine.doc.selectedThreadID
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.engineLoginTestDouble = [.codex, .claude]
        let chat = PetChat(model: model), store = try chat.store()
        let documentBefore = try Data(contentsOf: engine.store.url)
        check(store.teams.departments.first?.name == "隊伍" && store.teams.teams.first?.members == Array(projects.reversed().prefix(6)) && store.backpack.count >= 2, "2 first open uses activity order, maximum six and backpack")
        let later = engine.newProject(name: "fixture", workdir: root.path); _ = try chat.store()
        check(store.backpack.contains { $0.id == later }, "2 new project automatically enters backpack on next snapshot")
        try store.move(projects[7], to: nil)
        try store.move(projects[0], to: store.teams.teams[0].id, at: 1)
        let full = store.teams
        check(rejects { try store.move(projects[7], to: full.teams[0].id) } && store.teams == full, "2 full team rejects seventh member without losing data")
        try store.updatePersonality(projects[0], PetPersonality(strengthen: "講證據", restrain: "手腳快", custom: "先列證據"))
        check(store.personalityPrompt(for: projects[0])?.contains("先列證據") == true && rejects { try store.updatePersonality(projects[0], PetPersonality(custom: String(repeating: "字", count: 201))) }, "5 personality presets, custom prompt and 200 character bound")
        try store.updatePersonality(projects[1], PetPersonality(custom: "password=fixture-secret-value"))
        check(store.pet(projects[1])?.personality.custom.contains("fixture-secret-value") == false, "5 personality masks secrets before persistence")
        let target = chat.latestThread(projectID: projects[0])!
        engine.setModelPreferences(threadID: target, model: "gpt-6.1-sol", effort: "medium", speedTier: "fast")
        check(chat.send(projectID: projects[0], text: "with-usage"), "6 pets send accepts shared DM path")
        try await until("pet result") { !engine.isRunning(target) }
        check(engine.messages[target]?.last { $0.role == .assistant }?.text.contains("加強：講證據") == true && engine.doc.selectedThreadID == selected && model.selectedThreadID == selected, "5/6 pets prompt arrives and both Coder selections remain unchanged")
        let log = OSEventLog.atRoot(root)
        func events(_ project: UUID) throws -> [OSEvent] { try log.flush(); return try log.query(project: project, from: .distantPast, through: .distantFuture) }
        check(try events(projects[0]).last { $0.kind == "turn_end" }?.tokens == 321, "1 SDK result counts output including thinking once")
        check(try events(projects[0]).contains { $0.kind == "user_send" && $0.origin == "composer" && $0.surface == "pets" }, "6 user event carries composer/pets source")
        try store.updatePersonality(projects[0], PetPersonality(strengthen: "求簡潔", restrain: "謹慎"))
        check(chat.send(projectID: projects[0], text: "no-usage"), "1 second turn without usage accepts")
        try await until("missing usage") { !engine.isRunning(target) }
        check(engine.messages[target]?.last { $0.role == .assistant }?.text.contains("加強：求簡潔") == true
            && engine.messages[target]?.last { $0.role == .assistant }?.text.contains("加強：講證據") == false, "5 changed personality replaces prior preference on a reused sidecar")
        let noUsage = try events(projects[0]).last { $0.kind == "turn_end" }!
        let noUsageJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(noUsage)) as! [String: Any]
        check(noUsage.tokens == nil && noUsageJSON["tokens"] == nil && noUsageJSON["estimated"] == nil, "1 no usage omits token and estimated fields, never reuses preceding turn")
        check(engine.send(threadID: target, text: "coder-only", model: "gpt-6.1-sol", engine: .codex), "5 normal Coder send accepts")
        try await until("coder result") { !engine.isRunning(target) }
        check(engine.messages[target]?.last { $0.role == .assistant }?.text == "coder-only", "5 Coder send never includes pet personality")
        engine.setModelPreferences(threadID: target, model: "fable5", effort: "medium", speedTier: "standard")
        check(engine.send(threadID: target, text: "claude-usage", model: "fable5", engine: .claude), "1 Claude sidecar fixture accepts")
        try await until("Claude result") { !engine.isRunning(target) }
        check(try events(projects[0]).last { $0.kind == "turn_end" }?.tokens == 321, "1 Claude SDK result reads usage")
        check(PetTokenUsage.output(["usage": ["output_tokens": true]]) == nil && PetTokenUsage.output(["usage": ["output_tokens": -1]]) == nil && PetTokenUsage.output(["usage": ["output_tokens": 1.5]]) == nil, "1 invalid usage is never guessed")
        let fresh = engine.newProject(name: "no session", workdir: root.path)
        check(chat.send(projectID: fresh, text: "new-session"), "6 project without session builds a new thread")
        let freshThread = chat.latestThread(projectID: fresh)!
        try await until("new session") { !engine.isRunning(freshThread) }
        check(engine.doc.selectedThreadID == selected && model.selectedThreadID == selected && engine.threadRecord(freshThread)?.projectID == fresh, "6 new thread never selects Coder")
        check(!chat.send(projectID: fresh, threadID: target, text: "wrong-project") && !chat.send(projectID: UUID(), text: "missing"), "6 invalid project/thread target rejects")
        _ = engine.archive(freshThread)
        check(chat.latestThread(projectID: fresh) == nil && chat.send(projectID: fresh, text: "after-archive"), "6 archived-only project gets a new session")
        try await until("after archive") { !engine.isRunning(chat.latestThread(projectID: fresh)!) }
        for (experience, level, badges) in [(0,1,0),(1,1,0),(999,9,0),(970299,99,0),(1000000,1,1),(2000000,1,2)] {
            let progress = PetProgress(creditedTokens: Int64(experience * 100))
            check(progress.level == level && progress.badges == badges, "3 boundary E=\(experience), level=\(level), badges=\(badges)")
        }
        check(PetProgress(creditedTokens: 99999999).level == 99, "3 immediately below badge threshold has level 99")
        var cap = OSEvent(at: OSEventLog.stamp(Date()), project: "fixture", actor: "fixture", kind: "turn_end", tokens: 100000)
        var small = cap; small.id = "small"; small.tokens = 9; small.estimated = true
        check(PetProgress.calculate([cap, cap, small]).creditedTokens == 50009, "3 cap, duplicate protection and integer accumulation with TAP estimates")
        cap.kind = "tool_step"; check(PetProgress.calculate([cap]).experience == 0, "3 only turn_end earns experience")
        check(PetAvatars.catalog.count >= 12 && PetAvatars.stable(projects[0]) == PetAvatars.stable(projects[0]), "4 original catalog and stable ID assignment")
        let variants = try PetAvatars.catalog.map(PetAvatars.png)
        check(Set(variants).count == 12, "4 twelve distinct original pixel PNGs")
        try store.chooseAvatar(projects[0], avatar: "pixel-11")
        let pixels = try store.avatarPNG(projects[0])
        try store.uploadAvatar(projects[0], data: pixels)
        let upload = try store.avatarPNG(projects[0]), image = CGImageSourceCreateWithData(upload as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
        check(properties[kCGImagePropertyPixelWidth] as? Int == 256 && properties[kCGImagePropertyPixelHeight] as? Int == 256 && store.pet(projects[0])?.avatar == "uploaded", "4 uploaded image persists as 256 square PNG")
        let jpegData = NSMutableData(), jpeg = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(jpeg, CGImageSourceCreateImageAtIndex(image, 0, nil)!, nil)
        check(CGImageDestinationFinalize(jpeg) && (try? PetAvatars.upload(jpegData as Data)) != nil, "4 JPEG upload converts to PNG")
        check(rejects { try store.uploadAvatar(projects[0], data: Data(repeating: 0, count: PetAvatars.uploadLimit + 1)) }
            && rejects { try store.uploadAvatar(projects[0], data: Data("not an image".utf8)) }, "4 oversize and non-image uploads reject")
        let hall = PetHallEntry(name: "fixture", date: Date(), participants: [.init(projectID: projects[0], responsibility: "backend")])
        try store.saveHall([hall])
        let reopened = try PetStore(liveRoot: root)
        check(reopened.pet(projects[0]) == store.pet(projects[0]) && reopened.teams == store.teams && reopened.hall == [hall], "2/4/5 team, avatar, personality and hall persist after reopening")
        for name in ["pets.json", "teams.json", "hall-of-fame.json", "avatars/" + PetStore.key(projects[0]) + ".png"] {
            let mode = try FileManager.default.attributesOfItem(atPath: store.root.appendingPathComponent(name).path)[.posixPermissions] as! NSNumber
            check(mode.intValue == 0o600, "2 secure permissions " + name)
        }
        let damagedRoot = root.appendingPathComponent("damaged"), damaged = damagedRoot.appendingPathComponent("pets")
        try PetStore.directory(damaged)
        for name in ["pets.json", "teams.json", "hall-of-fame.json"] { try Data("broken-private-bytes".utf8).write(to: damaged.appendingPathComponent(name)) }
        let recovered = try PetStore(liveRoot: damagedRoot)
        let saved = try FileManager.default.contentsOfDirectory(at: damaged, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".corrupt-") }
        check(saved.count == 3 && recovered.reports.count == 3 && recovered.pets.isEmpty && recovered.teams.teams.isEmpty && recovered.hall.isEmpty
            && saved.allSatisfy { (try? Data(contentsOf: $0)) == Data("broken-private-bytes".utf8) }, "2 corrupt files preserve exact bytes and report all recoveries")
        try recovered.reconcile(projects: [], threads: [])
        check(saved.allSatisfy { (try? Data(contentsOf: $0)) == Data("broken-private-bytes".utf8) }, "2 blank recovery never overwrites quarantined originals")
        let symlinkRoot = root.appendingPathComponent("symlink-live"), untouched = root.appendingPathComponent("untouched.json")
        try Data("keep".utf8).write(to: untouched)
        try PetStore.directory(symlinkRoot.appendingPathComponent("pets"))
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("pets/pets.json"), withDestinationURL: untouched)
        check(rejects { _ = try PetStore(liveRoot: symlinkRoot) } && (try? Data(contentsOf: untouched)) == Data("keep".utf8), "2 symlink storage rejects and preserves external file")
        let removed = projects[3]
        try store.reconcile(projects: engine.doc.projects.filter { $0.id != removed }, threads: engine.doc.threads)
        check(store.pet(removed)?.missing == true, "2 disappeared project is marked missing and retained")
        for (i, name) in ["$skill", "@mcp", "ignored", "@third", "$fourth", "@fifth", "$sixth"].enumerated() {
            for _ in 0..<(8-i) { log.append(project: projects[0], actor: "fixture", kind: i % 2 == 0 ? "tool_step" : "hands_tool", used: [name]) }
        }
        engine.appendSystemMessage(threadID: target, text: "existing summary", status: CoderImport.summaryStatus)
        let profile = try chat.profile(projectID: projects[0])
        check(profile.skills.count == 5 && profile.skills.first == PetSkill(name: "$skill", count: 8) && profile.skills.allSatisfy { $0.name != "ignored" }, "7 tool and hands skills count dollar/at prefixes, top five")
        check(profile.encounteredAt == Date(timeIntervalSince1970: 10) && profile.sessions.first?.summaries.contains("existing summary") == true, "7 earliest encounter and existing summaries are available")
        let ordered = chat.sessions(projectID: fresh)
        check(ordered.count == 2 && ordered[0].updatedAt >= ordered[1].updatedAt, "7 sessions sort by updatedAt and retain archived sessions")
        let exported = try chat.export(projectID: projects[0], to: root.appendingPathComponent("exports"))
        let exportedJSON = try String(contentsOf: exported.appendingPathComponent("pet.json"), encoding: .utf8)
        let fields = try JSONSerialization.jsonObject(with: Data(exportedJSON.utf8)) as! [String: Any]
        let exportedAvatar = try Data(contentsOf: exported.appendingPathComponent("avatar.png"))
        check(fields["projectID"] as? String == projects[0].uuidString && fields["sessionTitles"] != nil && fields["experience"] != nil
            && !exportedJSON.contains("existing summary") && !exportedJSON.contains("coder-only") && !exportedJSON.contains("workdir")
            && exportedAvatar == upload, "8 export contains metadata and avatar, no transcripts or folder paths")
        let anotherExport = try chat.export(projectID: projects[0], to: exported.deletingLastPathComponent())
        check(anotherExport != exported && FileManager.default.fileExists(atPath: exported.appendingPathComponent("pet.json").path), "8 repeated export preserves previous export")
        let isolated = UserDefaults(suiteName: "w230pets-" + UUID().uuidString)!
        check(PetSettings.enabled(defaults: isolated), "9 pets switch defaults true")
        isolated.set(false, forKey: "tatwo.pets.enabled"); check(!PetSettings.enabled(defaults: isolated), "9 pets switch reads false")
        let tap = W185FakeConversationTap(), catalog = try await tap.models(), previous = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(catalog.items); defer { ChatGPTTapModelCatalog.replace(previous) }
        let tapRoot = root.appendingPathComponent("tap"), tapEngine = ChatLiveEngine(store: ChatLiveStore(root: tapRoot), environment: env, tap: tap)
        defer { tapEngine.shutdownAll() }
        let tapProject = tapEngine.newProject(name: "TAP pet", workdir: tapRoot.path), tapThread = tapEngine.newThread(in: tapProject)
        tapEngine.setModelPreferences(threadID: tapThread, model: ChatGPTTapModelCatalog.routeID("fixture-model"), effort: "", speedTier: "standard")
        let tapModel = ChatPageModel(environment: env, botCoreFixture: (tapEngine, BotStore(root: tapRoot))), tapChat = PetChat(model: tapModel)
        try tapChat.store().updatePersonality(tapProject, PetPersonality(strengthen: "好溝通"))
        check(tapChat.send(projectID: tapProject, text: "tap question"), "1/6 pet TAP routes through shared DM without CLI login")
        try await until("TAP sent") { !tap.sent.isEmpty }
        check(tap.sent.last?.text.contains("加強：好溝通") == true, "5 TAP receives personality per pets turn")
        tap.emit(.conversation(id: "fixture-conversation")); tap.emit(.text(messageID: "reply", full: "你好🙂abc")); tap.finish()
        try await until("TAP result") { !tapEngine.isRunning(tapThread) }
        let tapLog = OSEventLog.atRoot(tapRoot); try tapLog.flush()
        let tapRows = try tapLog.query(project: tapProject, from: .distantPast, through: .distantFuture)
        check(tapRows.last { $0.kind == "turn_end" }?.tokens == 6 && tapRows.last { $0.kind == "turn_end" }?.estimated == true
            && PetProgress.calculate(tapRows).creditedTokens == 6, "1/3 TAP Unicode character estimate is flagged and earns experience")
        let beforePetOnlyWrite = try Data(contentsOf: engine.store.url)
        try store.chooseAvatar(projects[0], avatar: "pixel-0"); try store.saveHall([hall]); try store.move(projects[0], to: nil)
        check(try Data(contentsOf: engine.store.url) == beforePetOnlyWrite && !documentBefore.isEmpty, "2 pet mutations leave chat document bytes unchanged")
        print("W230PETS SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
}
#endif
