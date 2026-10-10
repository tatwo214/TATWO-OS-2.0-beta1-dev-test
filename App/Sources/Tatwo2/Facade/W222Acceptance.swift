#if DEBUG
import Foundation

@MainActor enum W222Acceptance {
    static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let live = environment["TATWO2_LIVE_ROOT"] else { print("W222C FAIL requires isolated staging"); return false }
        let root = URL(fileURLWithPath: live).appendingPathComponent("w222c-\(UUID().uuidString)")
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W222C \(condition ? "PASS" : "FAIL") \(label)")
        }
        try await archiveChecks(root: root.appendingPathComponent("archive"), environment: environment, check: check)
        try await restoreChecks(root: root.appendingPathComponent("restore"), environment: environment, check: check)
        try await sharedFolderChecks(root: root.appendingPathComponent("shared"), environment: environment, check: check)
        try await lifecycleChecks(root: root.appendingPathComponent("lifecycle"), environment: environment, check: check)
        print("W222C SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }

    static func archiveChecks(root: URL, environment: [String: String], check: (Bool, String) -> Void) async throws {
        let pod = Pod(running: true), tap = ChatGPTTap(transport: pod)
        var engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment, tap: tap)
        defer { engine.shutdownAll(); tap.sleep() }
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = engine.newProject(name: "fixture", workdir: folder.path)
        let context = TapProjectContext(id: id, name: "fixture", folder: folder), oldThread = UUID()
        let original = try await engine.tapMapper.destination(project: context, threadID: oldThread)
        try await engine.tapMapper.record("archived-conversation", threadID: oldThread, destination: original)
        let file = TapProjectMapStore.mapFile(at: folder)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        object["archived"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let nextThread = UUID()
        let inbox = try await engine.tapMapper.destination(project: context, threadID: nextThread)
        check(inbox.map.name == "TATWO · 收件匣" && inbox.map.chatgpt_project_id != original.map.chatgpt_project_id
            && inbox.conversationID == nil, "W222b-2 archived project dispatches new conversation to inbox")
        try await engine.tapMapper.record("new-inbox-conversation", threadID: nextThread, destination: inbox)
        try await engine.tapMapper.record("late-old-conversation", threadID: UUID(), destination: original)
        let retained = try await TapProjectMapStore.shared.load(at: folder)
        object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        check(retained?.chatgpt_project_id == original.map.chatgpt_project_id && retained?.threads[oldThread.uuidString] == "archived-conversation"
            && retained?.threads[nextThread.uuidString] == nil && object["archived"] as? Bool == true,
              "W222b-2 old mapping and archive flag survive inbox and late records")
        check(TapProjectMapStore.displayMap(at: folder) == nil, "W222b-2 archived map is hidden from active mapping display")
        check(pod.commands.allSatisfy { !["archive", "remove", "renameProject"].contains($0["cmd"] as? String ?? "") },
              "W222b-2 archive never modifies or deletes remote project")

        let legacyFolder = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyFolder.appendingPathComponent(".tatwo"), withIntermediateDirectories: true)
        let legacy: [String: Any] = ["chatgpt_project_id": "g-p-legacy", "name": "TATWO · Legacy", "threads": [oldThread.uuidString: "legacy-conversation"], "updated_at": "old"]
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyFolder.appendingPathComponent(".tatwo/tap-map.json"))
        let migrated = try await TapProjectMapStore.shared.load(at: legacyFolder)
        check(migrated?.threads[oldThread.uuidString] == "legacy-conversation" && migrated?.name == "TATWO · Legacy",
              "W222b-2 legacy four-key map decodes and migrates")

        let hookFolder = root.appendingPathComponent("hook")
        try FileManager.default.createDirectory(at: hookFolder, withIntermediateDirectories: true)
        let hookID = engine.newProject(name: "fixture", workdir: hookFolder.path)
        let hookContext = TapProjectContext(id: hookID, name: "fixture", folder: hookFolder)
        let hookDestination = try await engine.tapMapper.destination(project: hookContext, threadID: UUID())
        let removed = try engine.restoreThreadProjects([], archivingEmpty: [hookID])
        let hookInbox = try await engine.tapMapper.destination(project: hookContext, threadID: UUID())
        let hookObject = try JSONSerialization.jsonObject(with: Data(contentsOf: TapProjectMapStore.mapFile(at: hookFolder))) as! [String: Any]
        check(removed.archived.map(\.id) == [hookID] && !engine.doc.projects.contains { $0.id == hookID }
            && hookObject["archived"] as? Bool == true && hookInbox.map.chatgpt_project_id != hookDestination.map.chatgpt_project_id,
              "W222b-2 existing OS archive waits for map flag before dispatch")
    }

    static func sharedFolderChecks(root: URL, environment: [String: String], check: (Bool, String) -> Void) async throws {
        let pod = Pod(running: true), tap = ChatGPTTap(transport: pod)
        var engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment, tap: tap)
        defer { engine.shutdownAll(); tap.sleep() }
        let folder = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = engine.newProject(name: "fixture", workdir: folder.path)
        let context = TapProjectContext(id: id, name: "fixture", folder: folder)
        let original = try await engine.tapMapper.destination(project: context, threadID: UUID())
        let thread = engine.newThread(in: id)
        let files = ProjectClassification.store(for: engine), proposal = UUID()
        try files.updateProposals { list in
            list.append(ProjectProposal(id: proposal, createdAt: Date(), sourceThreadID: thread,
                items: [ProjectProposalItem(threadIDs: [thread], targetProjectID: nil, newProjectName: "Classified", reason: "fixture")],
                status: .pending, decidedAt: nil))
        }
        let moved = try ProjectClassification.approve(proposal, engine: engine)
        check(moved.createdProjects.first?.workdir == folder.path, "W222c-3 classification shares the original folder")
        let undone = try ProjectClassification.undo(proposal, engine: engine)
        let next = try await engine.tapMapper.destination(project: context, threadID: UUID())
        check(undone.archivedProjects.count == 1 && engine.threadRecord(thread)?.projectID == id
            && next.map.chatgpt_project_id == original.map.chatgpt_project_id && next.map.archived != true,
              "W222c-3 classification then undo keeps new conversation in original ChatGPT project")
    }

    static func lifecycleChecks(root: URL, environment: [String: String], check: (Bool, String) -> Void) async throws {
        let pod = Pod(running: true), tap = ChatGPTTap(transport: pod)
        var engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment, tap: tap)
        defer { engine.shutdownAll(); tap.sleep() }
        let bad = root.appendingPathComponent("bad"), good = root.appendingPathComponent("good")
        for folder in [bad, good] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let badContext = TapProjectContext(id: UUID(), name: "fixture", folder: bad), goodContext = TapProjectContext(id: UUID(), name: "sample", folder: good)
        _ = try await engine.tapMapper.destination(project: badContext, threadID: UUID())
        let original = try await engine.tapMapper.destination(project: goodContext, threadID: UUID())
        let file = TapProjectMapStore.mapFile(at: bad)
        let bytes = try Data(contentsOf: file)
        // 在隔離 fixture 用符號連結觸發 store 的安全拒寫；原始資料留在記憶體。
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("unused"))
        engine.tapMapper.setArchived([bad], archived: true)
        try await engine.tapMapper.waitForLifecycle()
        let unrelated = try await engine.tapMapper.destination(project: goodContext, threadID: UUID())
        check(unrelated.map.chatgpt_project_id == original.map.chatgpt_project_id && engine.tapMapper.lifecycleErrors[bad.path]?.contains("符號連結") == true,
              "W222c-4 failed archive records one reason while another project still dispatches")
        var blocked = false
        do { _ = try await engine.tapMapper.destination(project: badContext, threadID: UUID()) } catch { blocked = true }
        check(blocked, "W222c-4 only failed folder is blocked until explicit lifecycle retry")
        try FileManager.default.removeItem(at: file)
        try bytes.write(to: file)
        let guarded = GroupGuardedTap(tap: tap) { nil }
        let turnMapper = TapProjectMapper(tap: guarded, storage: engine.tapMapper.storage,
            inboxFolder: engine.tapMapper.inboxFolder, lifecycleSource: engine.tapMapper)
        blocked = false
        do { _ = try await turnMapper.destination(project: badContext, threadID: UUID()) } catch { blocked = true }
        check(blocked, "W299 guarded turn retains failed lifecycle gate after file recovery")
        let guardedGood = try await turnMapper.destination(project: goodContext, threadID: UUID())
        check(guardedGood.map.chatgpt_project_id == original.map.chatgpt_project_id,
              "W299 guarded turn still dispatches unrelated project")
        engine.tapMapper.setArchived([bad], archived: true)
        let archived = try await turnMapper.destination(project: badContext, threadID: UUID())
        check(archived.map.name == "TATWO · 收件匣", "W299 guarded turn awaits queued archive before routing")
        engine.tapMapper.setArchived([bad], archived: false)
        let restored = try await engine.tapMapper.destination(project: badContext, threadID: UUID())
        check(archived.map.name == "TATWO · 收件匣" && restored.map.name == "TATWO · fixture" && engine.tapMapper.lifecycleErrors.isEmpty,
              "W222c-4 next archive and restore retry successfully")
    }

    static func restoreChecks(root: URL, environment: [String: String], check: (Bool, String) -> Void) async throws {
        let pod = Pod(running: true), tap = ChatGPTTap(transport: pod)
        var engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment, tap: tap)
        defer { engine.shutdownAll(); tap.sleep() }
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = engine.newProject(name: "fixture", workdir: folder.path)
        let context = TapProjectContext(id: id, name: "fixture", folder: folder), oldThread = UUID()
        let original = try await engine.tapMapper.destination(project: context, threadID: oldThread)
        try await engine.tapMapper.record("old-restored-conversation", threadID: oldThread, destination: original)
        let archived = try engine.restoreThreadProjects([], archivingEmpty: [id]).archived.first!
        _ = try await engine.tapMapper.destination(project: context, threadID: UUID())
        let archiveMap = try await TapProjectMapStore.shared.load(at: folder)
        let staleArchive = TapProjectDestination(folder: folder, map: archiveMap!, conversationID: nil, notice: nil)
        let remoteChanges = pod.commands.filter { ["renameProject", "archive", "remove", "createProject"].contains($0["cmd"] as? String ?? "") }.count
        engine = try await restoreFixture(engine, archived, environment: environment, tap: tap)
        let restored = try await engine.tapMapper.destination(project: context, threadID: UUID())
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: TapProjectMapStore.mapFile(at: folder))) as! [String: Any]
        check(engine.doc.projects.contains { $0 == archived } && object["archived"] == nil,
              "W222b-3 restore reinstates OS record and removes archived marker")
        check(restored.map.chatgpt_project_id == original.map.chatgpt_project_id && restored.conversationID == nil
            && restored.map.threads[oldThread.uuidString] == "old-restored-conversation", "W222b-3 restore resumes original project and retains old conversation")
        try await engine.tapMapper.record("late-after-restore", threadID: UUID(), destination: staleArchive)
        let afterLate = try await engine.tapMapper.destination(project: context, threadID: UUID())
        check(afterLate.map.chatgpt_project_id == original.map.chatgpt_project_id, "W222b-3 late archived record cannot rearchive restored map")
        engine = try await restoreFixture(engine, archived, environment: environment, tap: tap)
        check(engine.doc.projects.filter { $0.id == id }.count == 1, "W222b-3 repeat restore does not duplicate OS project")
        check(pod.commands.filter { ["renameProject", "archive", "remove", "createProject"].contains($0["cmd"] as? String ?? "") }.count == remoteChanges,
              "W222b-3 restore does not create or modify remote projects")
    }

    /// 產品沒有專案改名／還原入口；fixture 只改隔離文件，驗證底層同步與標記。
    static func restoreFixture(_ engine: ChatLiveEngine, _ project: LiveProjectRecord,
                               environment: [String: String], tap: ChatGPTTap) async throws -> ChatLiveEngine {
        var document = engine.doc
        if !document.projects.contains(where: { $0.id == project.id }) { document.projects.append(project) }
        engine.shutdownAll()
        try engine.store.saveChecked(document)
        let reloaded = ChatLiveEngine(store: engine.store, environment: environment, tap: tap)
        reloaded.tapMapper.setArchived([URL(fileURLWithPath: project.workdir)], archived: false)
        try await reloaded.tapMapper.waitForLifecycle()
        return reloaded
    }

    final class Pod: DispatchTapPod {}
}
#endif
