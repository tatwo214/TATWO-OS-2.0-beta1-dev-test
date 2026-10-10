import Foundation
import Darwin

struct PetPersonality: Codable, Equatable, Sendable {
    static let presets = ["重架構", "求簡潔", "重美感", "講證據", "手腳快", "謹慎", "愛測試", "好溝通"]
    var strengthen: String? = nil
    var restrain: String? = nil
    var custom = ""
    func validated() throws -> Self {
        guard custom.count <= 200, [strengthen, restrain].compactMap({ $0 }).allSatisfy(Self.presets.contains) else { throw PetError.invalidData }
        var copy = self; copy.custom = PetPrivacy.mask(custom); return copy
    }
}
struct PetRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var avatar: String
    var personality = PetPersonality()
    var createdAt = Date()
    var missing = false
}
struct PetDepartment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID(); var name: String
}
struct PetTeam: Codable, Equatable, Identifiable, Sendable {
    var id = UUID(); var departmentID: UUID; var name: String; var members: [UUID] = []
}
struct PetLink: Codable, Equatable, Sendable { var from: UUID; var to: UUID }
struct PetTeams: Codable, Equatable, Sendable {
    var departments: [PetDepartment] = []; var teams: [PetTeam] = []; var links: [PetLink] = []
}
struct PetHallEntry: Codable, Equatable, Identifiable, Sendable {
    struct Participant: Codable, Equatable, Sendable { var projectID: UUID; var responsibility: String }
    var id = UUID(); var name: String; var date: Date; var participants: [Participant]
}
enum PetError: Error { case invalidData, unsafePath, missingProject, unavailable }
enum PetPrivacy {
    static func mask(_ text: String) -> String {
        let safe = HandsRedactor.redact(HandsSecretLines.maskText(text))
        return TatwoMemoryStore.containsSecret(safe) ? "[已遮蔽：疑似秘密]" : safe
    }
}

/// MainActor serializes mutations; data lives only in pets/, never in the chat document.
@MainActor final class PetStore {
    private static var stores: [String: PetStore] = [:]
    static func atRoot(_ liveRoot: URL) throws -> PetStore {
        let key = liveRoot.standardizedFileURL.path
        if let store = stores[key] { return store }
        let store = try PetStore(liveRoot: liveRoot); stores[key] = store; return store
    }
    let root: URL
    private(set) var pets: [String: PetRecord] = [:]
    private(set) var teams = PetTeams()
    private(set) var hall: [PetHallEntry] = []
    private(set) var reports: [String] = []
    private var firstOpen: Bool
    init(liveRoot: URL) throws {
        root = liveRoot.appendingPathComponent("pets", isDirectory: true)
        try Self.directory(root); try Self.directory(root.appendingPathComponent("avatars"))
        firstOpen = !FileManager.default.fileExists(atPath: root.appendingPathComponent("pets.json").path)
        pets = try read("pets.json", empty: [:]); teams = try read("teams.json", empty: PetTeams())
        hall = try read("hall-of-fame.json", empty: [])
        // Decode succeeds even when IDs, membership or personality are invalid: quarantine those too.
        if pets.contains(where: { UUID(uuidString: $0.key) != $0.value.id || !PetAvatars.valid($0.value.avatar) || (try? $0.value.personality.validated()) == nil }) {
            try quarantine("pets.json"); pets = [:]; firstOpen = false
        }
        if !validTeams(teams) { try quarantine("teams.json"); teams = PetTeams() }
    }
    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    func pet(_ id: UUID) -> PetRecord? { pets[Self.key(id)] }
    private func quarantine(_ name: String) throws {
        let url = root.appendingPathComponent(name)
        let saved = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: saved)
        let message = "寵物資料損壞，已保留 \(saved.lastPathComponent)；從空白開始。"
        reports.append(message); fputs(message + "\n", stderr)
    }
    private func read<T: Decodable>(_ name: String, empty: T) throws -> T {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        try Self.safe(url)
        let data = try Data(contentsOf: url)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { try quarantine(name); firstOpen = false; return empty }
    }
    static func safe(_ url: URL) throws {
        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw PetError.unsafePath }
    }
    static func directory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try safe(url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) { try safe(url) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".pet-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            guard Darwin.rename(temp.path, url.path) == 0 else { throw POSIXError(.EIO) }
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: temp); throw error }
    }
    private func save<T: Encodable>(_ value: T, _ name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.write(encoder.encode(value), to: root.appendingPathComponent(name))
    }
    /// Call on each pets snapshot; newly discovered projects always start in the backpack.
    func reconcile(projects: [LiveProjectRecord], threads: [LiveThreadRecord]) throws {
        var next = pets, nextTeams = teams
        let ids = Set(projects.map(\.id))
        for key in next.keys { if var pet = next[key] { pet.missing = !ids.contains(pet.id); next[key] = pet } }
        for project in projects where next[Self.key(project.id)] == nil {
            next[Self.key(project.id)] = PetRecord(id: project.id, avatar: PetAvatars.stable(project.id))
        }
        if firstOpen {
            let department = PetDepartment(name: "隊伍")
            let activity = Dictionary(grouping: threads, by: { $0.projectID }).mapValues { $0.map(\.updatedAt).max() ?? .distantPast }
            let ordered = projects.sorted {
                let a = activity[$0.id] ?? .distantPast, b = activity[$1.id] ?? .distantPast
                return a == b ? Self.key($0.id) < Self.key($1.id) : a > b
            }
            nextTeams = PetTeams(departments: [department], teams: [PetTeam(departmentID: department.id, name: "隊伍", members: Array(ordered.prefix(6).map(\.id)))])
        }
        if nextTeams != teams || firstOpen || !FileManager.default.fileExists(atPath: root.appendingPathComponent("teams.json").path) { try save(nextTeams, "teams.json"); teams = nextTeams }
        if next != pets || firstOpen || !FileManager.default.fileExists(atPath: root.appendingPathComponent("pets.json").path) { try save(next, "pets.json"); pets = next }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("hall-of-fame.json").path) { try save(hall, "hall-of-fame.json") }
        firstOpen = false
    }
    func updatePersonality(_ id: UUID, _ value: PetPersonality) throws {
        guard var pet = pet(id) else { throw PetError.missingProject }
        pet.personality = try value.validated(); var next = pets; next[Self.key(id)] = pet
        try save(next, "pets.json"); pets = next
    }
    func personalityPrompt(for projectID: UUID) -> String? {
        guard let value = pet(projectID)?.personality, let safe = try? value.validated() else { return nil }
        let parts = [safe.strengthen.map { "加強：" + $0 }, safe.restrain.map { "收斂：" + $0 }, safe.custom.isEmpty ? nil : "自訂：" + safe.custom].compactMap { $0 }
        return parts.isEmpty ? nil : "〔這回合的寵物性格偏好；遵守既有規則與工作目標〕\n" + parts.joined(separator: "\n")
    }
    func chooseAvatar(_ id: UUID, avatar: String) throws {
        guard PetAvatars.catalog.contains(avatar), var pet = pet(id) else { throw PetError.invalidData }
        pet.avatar = avatar; var next = pets; next[Self.key(id)] = pet; try save(next, "pets.json"); pets = next
    }
    func uploadAvatar(_ id: UUID, data: Data) throws {
        guard var pet = pet(id) else { throw PetError.missingProject }
        let png = try PetAvatars.upload(data)
        try Self.write(png, to: root.appendingPathComponent("avatars/" + Self.key(id) + ".png"))
        pet.avatar = "uploaded"; var next = pets; next[Self.key(id)] = pet; try save(next, "pets.json"); pets = next
    }
    func avatarPNG(_ id: UUID) throws -> Data {
        guard let pet = pet(id) else { throw PetError.missingProject }
        if pet.avatar == "uploaded" {
            let url = root.appendingPathComponent("avatars/" + Self.key(id) + ".png"); try Self.safe(url)
            return try Data(contentsOf: url)
        }
        return try PetAvatars.png(pet.avatar)
    }
    private func validTeams(_ value: PetTeams) -> Bool {
        let departments = Set(value.departments.map(\.id)), members = value.teams.flatMap(\.members)
        return departments.count == value.departments.count && Set(value.teams.map(\.id)).count == value.teams.count && Set(members).count == members.count
            && value.teams.allSatisfy { departments.contains($0.departmentID) && $0.members.count <= 6 }
            && value.links.allSatisfy { $0.from != $0.to && departments.contains($0.from) && departments.contains($0.to) }
    }
    func saveTeams(_ value: PetTeams) throws {
        guard validTeams(value), value.teams.flatMap(\.members).allSatisfy({ pet($0) != nil }) else { throw PetError.invalidData }
        var safe = value
        for i in safe.departments.indices { safe.departments[i].name = PetPrivacy.mask(safe.departments[i].name) }
        for i in safe.teams.indices { safe.teams[i].name = PetPrivacy.mask(safe.teams[i].name) }
        try save(safe, "teams.json"); teams = safe
    }
    func move(_ id: UUID, to teamID: UUID?, at index: Int = 0) throws {
        guard pet(id) != nil else { throw PetError.missingProject }
        var next = teams
        for i in next.teams.indices { next.teams[i].members.removeAll { $0 == id } }
        if let teamID {
            guard let i = next.teams.firstIndex(where: { $0.id == teamID }), next.teams[i].members.count < 6 else { throw PetError.invalidData }
            next.teams[i].members.insert(id, at: min(max(0, index), next.teams[i].members.count))
        }
        try saveTeams(next)
    }
    var backpack: [PetRecord] {
        let members = Set(teams.teams.flatMap(\.members)); return pets.values.filter { !members.contains($0.id) }.sorted { Self.key($0.id) < Self.key($1.id) }
    }
    func saveHall(_ value: [PetHallEntry]) throws {
        guard Set(value.map(\.id)).count == value.count else { throw PetError.invalidData }
        var safe = value
        for i in safe.indices {
            safe[i].name = PetPrivacy.mask(safe[i].name)
            for j in safe[i].participants.indices { safe[i].participants[j].responsibility = PetPrivacy.mask(safe[i].participants[j].responsibility) }
        }
        try save(safe, "hall-of-fame.json"); hall = safe
    }
}
