import Foundation

struct PetSession: Identifiable, Equatable, Sendable {
    let id: UUID; let title: String; let createdAt: Date; let updatedAt: Date; let isArchived: Bool; let summaries: [String]
}
struct PetSkill: Equatable, Sendable { let name: String; let count: Int }
struct PetProfile: Sendable {
    let pet: PetRecord; let name: String; let workdir: String?; let progress: PetProgress
    let encounteredAt: Date?; let sessions: [PetSession]; let skills: [PetSkill]
}

/// W230b creates this with the existing ChatPageModel; every send reuses its DM guards and routing.
@MainActor final class PetChat {
    private unowned let model: ChatPageModel
    init(model: ChatPageModel) { self.model = model }
    private var engine: ChatLiveEngine? { model.localLiveForBridge }
    func store() throws -> PetStore {
        guard let engine else { throw PetError.unavailable }
        let store = try PetStore.atRoot(engine.store.url.deletingLastPathComponent())
        try store.reconcile(projects: engine.doc.projects.filter { $0.id != engine.doc.assistantProjectID }, threads: engine.doc.threads); return store
    }
    func sessions(projectID: UUID) -> [PetSession] {
        (engine?.doc.threads ?? []).filter { $0.projectID == projectID }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }.map { thread in
            let summaries = (engine?.messages[thread.id] ?? []).filter {
                $0.role == .system && ($0.status == CoderImport.summaryStatus || $0.status == "info|支線摘要")
            }.map { PetPrivacy.mask($0.text) }
            return PetSession(id: thread.id, title: thread.title, createdAt: thread.createdAt, updatedAt: thread.updatedAt,
                isArchived: thread.isArchived, summaries: summaries)
        }
    }
    func latestThread(projectID: UUID) -> UUID? {
        sessions(projectID: projectID).first { !$0.isArchived && engine?.threadRecord($0.id)?.deviceID == nil
            && engine?.threadRecord($0.id)?.engine != ChatLiveEngine.handsEngine && engine?.doc.isAssistantThread($0.id) != true }?.id
    }
    func newSession(projectID: UUID) -> UUID? {
        guard let engine, projectID != engine.doc.assistantProjectID, engine.projectRecord(projectID) != nil, !engine.store.isReadOnly else { return nil }
        do { _ = try store() } catch { return nil }
        return engine.newThread(in: projectID, select: false)
    }
    @discardableResult func send(projectID: UUID, threadID: UUID? = nil, text: String, attachments: [String] = [],
                                onDelivered: @escaping @MainActor () -> Void = {},
                                onUndelivered: @escaping @MainActor (String) -> Void = { _ in }) -> Bool {
        guard let engine, projectID != engine.doc.assistantProjectID, engine.projectRecord(projectID) != nil, !engine.store.isReadOnly,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        do { _ = try store() } catch { engine.onHint?("寵物資料讀取失敗；訊息未送出。"); return false }
        let destination: UUID
        if let threadID {
            guard let record = engine.threadRecord(threadID), record.projectID == projectID, !record.isArchived else { return false }
            destination = threadID
        } else { destination = latestThread(projectID: projectID) ?? engine.newThread(in: projectID, select: false) }
        return OSEventSources.scope(origin: "composer", surface: "pets") {
            model.sendFromDM(threadID: destination, text: text, attachments: attachments, onDelivered: onDelivered, onUndelivered: onUndelivered)
        }
    }
    var profileRevision: [String] {
        guard let engine else { return [] }
        return engine.doc.projects.map { "\($0.id):\($0.name):\($0.workdir)" } + engine.doc.threads.map { thread in
            "\(thread.id):\(thread.title):\(thread.isArchived):" + (engine.messages[thread.id] ?? []).filter { $0.role == .system }.map(\.text).joined(separator: "\n")
        }
    }
    #if DEBUG
    private(set) var eventProfileReads: [UUID: Int] = [:]
    #endif
    func eventProfiles(since revisions: [UUID: String]) async throws -> [UUID: (String, PetProgress, [PetSkill])] {
        guard let engine else { throw PetError.unavailable }
        let ids = engine.doc.projects.filter { $0.id != engine.doc.assistantProjectID }.map(\.id)
        let log = OSEventLog.atRoot(engine.store.url.deletingLastPathComponent())
        let changed = try await Task.detached(priority: .utility) {
            var changed: [UUID: (String, PetProgress, [PetSkill])] = [:]
            for id in ids {
                let revision = try log.revision(project: id)
                guard revisions[id] != revision else { continue }
                let rows = try log.query(project: id, from: .distantPast, through: .distantFuture, kinds: ["turn_end", "tool_step", "hands_tool"])
                changed[id] = (revision, PetProgress.calculate(rows), Self.skills(rows))
            }
            return changed
        }.value
        #if DEBUG
        for id in changed.keys { eventProfileReads[id, default: 0] += 1 }
        #endif
        return changed
    }
    func commonSkills(projectID: UUID) throws -> [PetSkill] {
        guard let engine else { throw PetError.unavailable }
        let log = OSEventLog.atRoot(engine.store.url.deletingLastPathComponent())
        let rows = try log.query(project: projectID, from: .distantPast, through: .distantFuture, kinds: ["tool_step", "hands_tool"])
        return Self.skills(rows)
    }
    nonisolated private static func skills(_ rows: [OSEvent]) -> [PetSkill] {
        var counts: [String: Int] = [:], seen: Set<String> = []
        for row in rows where ["tool_step", "hands_tool"].contains(row.kind) && seen.insert(row.id).inserted {
            for name in row.used ?? [] where name.hasPrefix("$") || name.hasPrefix("@") { counts[name, default: 0] += 1 }
        }
        return counts.map { PetSkill(name: $0.key, count: $0.value) }.sorted {
            $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
        }.prefix(5).map { $0 }
    }
    func profile(projectID: UUID, eventProfile: (PetProgress, [PetSkill])? = nil) throws -> PetProfile {
        let store = try store()
        guard let pet = store.pet(projectID), let engine else { throw PetError.missingProject }
        let project = engine.projectRecord(projectID), list = sessions(projectID: projectID)
        return PetProfile(pet: pet, name: project?.name ?? "找不到專案", workdir: project?.workdir,
            progress: try eventProfile?.0 ?? PetProgress.query(projectID: projectID, log: .atRoot(engine.store.url.deletingLastPathComponent())),
            encounteredAt: list.map(\.createdAt).min(), sessions: list, skills: try eventProfile?.1 ?? commonSkills(projectID: projectID))
    }
    /// destination is a new subfolder in the folder chosen by the user; existing exports are preserved.
    @discardableResult func export(projectID: UUID, to folder: URL) throws -> URL {
        let profile = try profile(projectID: projectID), store = try store()
        struct Export: Encodable {
            let projectID: UUID; let name: String; let avatar: String; let personality: PetPersonality
            let level: Int; let experience: Double; let badges: Int64; let sessionTitles: [String]
        }
        let data = Export(projectID: projectID, name: PetPrivacy.mask(profile.name), avatar: "avatar.png",
            personality: try profile.pet.personality.validated(), level: profile.progress.level, experience: profile.progress.experience,
            badges: profile.progress.badges, sessionTitles: profile.sessions.map { PetPrivacy.mask($0.title) })
        let avatar = try store.avatarPNG(projectID), encoded = try JSONEncoder().encode(data)
        let destination = folder.appendingPathComponent("pet-" + PetStore.key(projectID) + "-" + UUID().uuidString)
        try PetStore.directory(destination)
        try PetStore.write(encoded, to: destination.appendingPathComponent("pet.json"))
        try PetStore.write(avatar, to: destination.appendingPathComponent("avatar.png"))
        return destination
    }
}
