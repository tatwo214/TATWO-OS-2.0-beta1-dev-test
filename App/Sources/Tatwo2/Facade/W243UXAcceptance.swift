#if DEBUG
import Foundation
import AppKit
import SwiftUI

@MainActor enum W243UXAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let root = URL(fileURLWithPath: path).appendingPathComponent("w243-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var failures = 0, passed = 0
        func check(_ ok: Bool, _ label: String) { if ok { passed += 1 } else { failures += 1 }; print("W243UX \(ok ? "PASS" : "FAIL") \(label)") }
        check(try await W236SigilsAcceptance.run(), "U5 Codex and Claude receive hidden context while preserving user rows")
        try await mapping(root: root, check: check)
        try await sigils(root: root.appendingPathComponent("sigils"), env: env, check: check)
        try await reads(root: root.appendingPathComponent("reads"), artifacts: URL(fileURLWithPath: path), env: env, check: check)
        try await pets(root: root.appendingPathComponent("pets"), artifacts: URL(fileURLWithPath: path), env: env, check: check)
        print("W243UX SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
    private static func reads(root: URL, artifacts: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "已讀驗收", workdir: root.path), thread = engine.newThread(in: project)
        let group = GroupTurnEngine(threadID: thread, primary: "Codex", participants: [
            .init(id: "Codex", invoke: { _, done in done(.success("主導回覆")) }, stop: {}),
            .init(id: "ChatGPT", join: true, invoke: { _, done in done(.success("TAP 回覆")) }, stop: {})], exchangeLimit: 0)
        group.onEvent = { event in
            guard event.speaker == "ChatGPT", !["join", "reconnect", "transfer"].contains(event.kind) else { return }
            engine.groupWrite(thread, event, status: event.kind == "pending" ? "writing|ChatGPT" : "done", source: .system)
        }
        _ = group.human("@@ChatGPT 第一輪")
        let first = engine.transcript(for: thread).first!, event = group.events.first { $0.speaker == "ChatGPT" && $0.kind == "summary" }!
        let old = ChatGroupSpeaker.readCount(first, event: event)
        _ = group.human("第二輪")
        let rows = engine.transcript(for: thread)
        let events = group.events.filter { $0.speaker == "ChatGPT" && ["summary", "message"].contains($0.kind) }
        guard rows.count == 2, events.count == 2 else { throw TapError.notReady }
        let counts = zip(rows, events).map { ChatGroupSpeaker.readCount($0.0, event: $0.1) }
        check(counts[0] == old && counts[1] > old && group.cursors["ChatGPT"] == counts[1], "U4 old TAP row retains its own read count after next turn")
        let restored = try ChatLiveStore(root: root).load().threads.first { $0.id == thread }!.messages.map(\.chatMessage)
        check(zip(restored, events).map { ChatGroupSpeaker.readCount($0.0, event: $0.1) } == counts, "U4 per-row read counts survive persistence")
        let restoredGroup = GroupTurnEngine(threadID: thread, primary: group.primary, participants: group.participants)
        try restoredGroup.restore(group.snapshot())
        let restoredEvents = restoredGroup.events.filter { $0.speaker == "ChatGPT" && ["summary", "message"].contains($0.kind) }
        check(restoredEvents.map(\.readCount) == counts.map(Optional.some), "A8 event read counts survive ledger persistence")
        check(rows.allSatisfy { $0.turnID?.hasPrefix("group-read:") != true }, "A8 read counts never occupy turnID")
        var legacy = try JSONSerialization.jsonObject(with: group.snapshot()) as! [String: Any]
        legacy["events"] = (legacy["events"] as! [[String: Any]]).map { row in var row = row; row["readCount"] = nil; return row }
        try restoredGroup.restore(JSONSerialization.data(withJSONObject: legacy))
        check(restoredGroup.events.allSatisfy { $0.readCount == nil }, "A8 old event ledgers decode without readCount")
        let scope = TatwoThemeSelfTestScope(); defer { scope.restore() }; scope.use(.aurora)
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(zip(rows, events)), id: \.0.id) { row, event in
                    ChatGroupSpeaker(name: event.speaker, readCount: ChatGroupSpeaker.readCount(row, event: event))
                    Text(row.text)
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(scheme == .dark ? Color.black : Color.white)
            guard let shot = GlobalDMChatAcceptance.renderSync(view, size: CGSize(width: 820, height: 300), scheme: scheme) else { throw TapError.notReady }
            let text = W214Acceptance.text(shot)
            check(counts.allSatisfy { text.contains("已讀這串 \($0) 則") }, "U4 \(scheme) two rows show distinct counts")
            check(scheme != .dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap), "U4 \(scheme) readable")
            GlobalDMChatAcceptance.save(shot, scheme == .dark ? "w243-tap-reads-dark.png" : "w243-tap-reads-light.png", to: artifacts); shot.close()
        }
    }
    private static func pets(root: URL, artifacts: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "寵物載入驗收", workdir: root.path), thread = engine.newThread(in: project)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        let log = OSEventLog.atRoot(root)
        for _ in 0..<1940 { log.append(project: project, thread: thread, actor: "fixture", kind: "turn_end", tokens: 50_000) }
        log.append(project: project, thread: thread, actor: "fixture", kind: "turn_end", tokens: 29_900)
        try log.flush()
        let state = PetsViewModel(model: model, scheduleEvents: false)
        state.selected = project; state.page = .profile
        let scope = TatwoThemeSelfTestScope(); defer { scope.restore() }; scope.use(.aurora)
        func render(_ phase: String) throws {
            for scheme in [ColorScheme.light, .dark] {
                guard let shot = GlobalDMChatAcceptance.renderSync(PetsRootView(model: model, state: state), size: CGSize(width: 1280, height: 900), scheme: scheme) else { throw TapError.notReady }
                let text = W214Acceptance.text(shot)
                check(text.contains("Lv —") && text.contains("經驗 —") && !text.contains("Lv 1") && !text.contains("0 / 8"), "U3 \(phase) \(scheme) level and experience stay unknown")
                check(phase != "failed" || text.contains("經驗暫時讀不到"), "U3 \(phase) \(scheme) failure explanation")
                check(scheme != .dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap), "U3 \(phase) \(scheme) readable")
                GlobalDMChatAcceptance.save(shot, "w243-pets-" + phase + (scheme == .dark ? "-dark.png" : "-light.png"), to: artifacts); shot.close()
            }
        }
        check(!state.hasProgress(project), "U3 initial metadata has no computed experience")
        try render("loading")
        state.refreshEvents(); try await W241PetsAcceptance.until { state.refreshTask == nil }
        check(state.hasProgress(project) && state.profiles[project]?.progress.level == 99, "U3 background result shows calculated level")
        state.refresh(scheduleEvents: false)
        check(state.hasProgress(project) && state.profiles[project]?.progress.level == 99, "U3 metadata refresh retains calculated experience")
        let folder = log.file(project: project, at: Date()).deletingLastPathComponent(), archive = root.appendingPathComponent("saved-events")
        try FileManager.default.moveItem(at: folder, to: archive)
        try Data("unreadable directory fixture".utf8).write(to: folder)
        state.refreshEvents(); try await W241PetsAcceptance.until { state.refreshTask == nil }
        check(state.experienceUnavailable && !state.hasProgress(project), "U3 failed background calculation invalidates displayed experience")
        try render("failed")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: archive, to: folder)
        state.refreshEvents(); try await W241PetsAcceptance.until { state.refreshTask == nil }
        check(!state.experienceUnavailable && state.hasProgress(project) && state.profiles[project]?.progress.level == 99, "U3 retry recovers the calculated level without resetting experience")
    }
    private static func sigils(root: URL, env: [String: String], check: (Bool, String) -> Void) async throws {
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env, tap: W185FakeConversationTap())
        defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        engine.groupBridge.taps.append(.init(id: "Future", unavailable: { "fixture unavailable" }, invoke: { _, _, _ in }, stop: { _ in }))
        model.prompt = "@@"
        check(model.composerSigilItems.first { $0.name == "Future" }.map { !$0.enabled && $0.detail == "現在不能用" } == true, "U7 unavailable TAP explains current inability")
        let entries: [PluginRegistryEntry] = [.init(id: "tatwo-ultrawork", name: "fixture", kind: .skill, purpose: "fixture", path: root.appendingPathComponent("2026/3/SKILL.md").path, trigger: "", safetyLevel: .medium, installState: .unknown, smokeCommand: nil, publicInstallHint: "")]
        check(ChatComposerSkillCatalog.suggestions(in: .init(entries: entries), query: "2026").isEmpty, "U2 skills do not match file paths")
        let skill = OSMCPRegistry(environment: env).paths.codexHome.appendingPathComponent("skills/tatwo-ultrawork/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: tatwo-ultrawork\ndescription: fixture\n---\nFixture skill.\n".write(to: skill, atomically: true, encoding: .utf8)
        await model.reloadPluginRegistry()?.value
        model.issueListEntries = [.init(id: "fixture", title: "#212", body: "", sourceReference: "212")]
        for text in ["花了 $2", "花了 $5.5", "@2026", "!3", "@@2026"] {
            model.prompt = text
            check(!model.handleComposerSuggestionKey(.commit) && model.prompt == text, "U2 ordinary Enter preserves \(text)")
            if text.contains("$") { check(model.composerSigil == nil, "U2 currency has no skill menu") }
        }
        for text in ["$", "@", "!", "@@"] {
            model.prompt = text
            check(!model.composerSigilItems.isEmpty, "A10 empty query has suggestions \(text)")
            check(!model.handleComposerSuggestionKey(.commit) && model.prompt == text, "A10 empty query Enter sends original \(text)")
            _ = model.handleComposerSuggestionKey(.prev)
            _ = model.handleComposerSuggestionKey(.next)
            check(model.handleComposerSuggestionKey(.commit) && model.prompt != text, "A10 arrow selection allows empty query insertion \(text)")
        }
        model.prompt = "$ult"
        check(model.handleComposerSuggestionKey(.commit) && model.prompt == "$ultrawork ", "U2 prefix Enter picks ultrawork")
        model.prompt = "$work"
        check(!model.handleComposerSuggestionKey(.commit) && model.prompt == "$work", "U2 substring alone cannot replace draft")
        _ = model.handleComposerSuggestionKey(.prev)
        _ = model.handleComposerSuggestionKey(.next)
        check(model.handleComposerSuggestionKey(.commit) && model.prompt == "$ultrawork ", "U2 explicit arrow selection permits substring result")
    }
    private final class HeldTap: GroupGuardedTap {
        var waiting = false
        var resume: CheckedContinuation<Void, Never>?
        override func projects() async throws -> [TapFolder] {
            let folders = try await super.projects()
            waiting = true; await withCheckedContinuation { resume = $0 }
            if let reason = rejection() { throw TapError.remote(reason) }
            return folders
        }
    }
    private static func mapping(root: URL, check: (Bool, String) -> Void) async throws {
        let fake = W185FakeConversationTap(), held = HeldTap(tap: fake)
        let storage = TapProjectMapStore()
        let project = TapProjectContext(id: UUID(), name: "同時首次送出", folder: root)
        let first = TapProjectMapper(tap: held, storage: storage, inboxFolder: root.appendingPathComponent("inbox"))
        let second = TapProjectMapper(tap: fake, storage: storage, inboxFolder: first.inboxFolder)
        let a = Task { try await first.destination(project: project, threadID: UUID()) }
        try await W241PetsAcceptance.until { held.waiting }
        let b = Task { try await second.destination(project: project, threadID: UUID()) }
        for _ in 0..<20 { await Task.yield() }
        held.resume?.resume(); held.resume = nil
        let destinations = try await [a.value, b.value]
        check(fake.createdNames == [project.tapName] && destinations[0].map == destinations[1].map, "U1 two independent turn mappers create one project")
        let saved = try await storage.load(at: root)
        check(saved?.chatgpt_project_id == destinations[0].map.chatgpt_project_id, "U1 shared project mapping saved once")
        let refused = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: refused, withIntermediateDirectories: true)
        var managed = false
        let guardTap = HeldTap(tap: fake, rejection: { managed ? "受管 fixture" : nil })
        let mapper = TapProjectMapper(tap: guardTap, storage: storage, inboxFolder: first.inboxFolder)
        let job = Task { try await mapper.destination(project: .init(id: UUID(), name: "受管", folder: refused), threadID: UUID()) }
        try await W241PetsAcceptance.until { guardTap.waiting }
        managed = true; guardTap.resume?.resume(); guardTap.resume = nil
        do { _ = try await job.value; check(false, "U1 managed while resolving refused") }
        catch { let map = try await storage.load(at: refused); check(fake.createdNames.count == 1 && map == nil, "U1 managed while resolving creates and saves nothing") }
    }
}
#endif
