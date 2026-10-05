import Combine
import Foundation

/// W180 E3：Coder 的「專案空間」＝具名的專案群組（照 Browser 空間的樣子）。只是這台設備自己的顯示設定：
/// 存 live/coder-spaces.json，不改對話文件、不走 RPC。成員可以是本機專案，也可以是遠端設備上的專案。
struct CoderProjectSpace: Codable, Equatable, Identifiable, Sendable {
    struct RemoteProject: Codable, Hashable, Sendable {
        var deviceID: String
        var projectID: UUID
    }

    var id = UUID()
    var name: String
    var projectIDs: [UUID] = []
    var remoteProjects: [RemoteProject] = []
    /// 封存不直刪；封存的空間可以還原。
    var isArchived = false
}

struct CoderProjectSpacesFile: Codable, Equatable, Sendable {
    var version = 1
    var spaces: [CoderProjectSpace] = []
    /// nil＝「全部專案」，跟沒有這個功能之前完全一樣。
    var selectedSpaceID: UUID?
}

@MainActor
final class CoderProjectSpaces: ObservableObject {
    static let allProjectsName = "全部專案"
    static let shared = CoderProjectSpaces()

    @Published private(set) var file = CoderProjectSpacesFile()
    /// 檔案讀壞了：先照「全部專案」顯示，原檔留著（另存 .bak），使用者改東西之前不覆蓋。
    @Published private(set) var loadProblem: String?
    let url: URL

    init(root: URL? = nil) {
        let base = root ?? ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        url = base.appendingPathComponent("coder-spaces.json")
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: url) else { file = .init(); loadProblem = nil; return }
        do {
            file = try JSONDecoder().decode(CoderProjectSpacesFile.self, from: data)
            loadProblem = nil
        } catch {
            file = .init()
            loadProblem = "專案空間的設定檔讀不出來，先顯示全部專案；原檔留著，另存了一份 .bak。"
            var backup = url.appendingPathExtension("bak")
            if let existing = try? Data(contentsOf: backup), existing != data {
                backup = url.deletingLastPathComponent().appendingPathComponent("coder-spaces-\(Int(Date().timeIntervalSince1970)).json.bak")
            }
            if (try? Data(contentsOf: backup)) != data { try? data.write(to: backup, options: .atomic) }
        }
    }

    private func save() {
        loadProblem = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: 讀

    var activeSpaces: [CoderProjectSpace] { file.spaces.filter { !$0.isArchived } }
    var archivedSpaces: [CoderProjectSpace] { file.spaces.filter(\.isArchived) }
    /// 選著的空間；選的那個被封存或不見了就是「全部專案」。
    var selectedSpace: CoderProjectSpace? {
        guard let id = file.selectedSpaceID else { return nil }
        return activeSpaces.first { $0.id == id }
    }
    var selectedName: String { selectedSpace?.name ?? Self.allProjectsName }

    func space(_ id: UUID) -> CoderProjectSpace? { file.spaces.first { $0.id == id } }

    func contains(localProject projectID: UUID, in spaceID: UUID) -> Bool {
        space(spaceID)?.projectIDs.contains(projectID) ?? false
    }

    func contains(remoteProject projectID: UUID, deviceID: String, in spaceID: UUID) -> Bool {
        space(spaceID)?.remoteProjects.contains(.init(deviceID: deviceID, projectID: projectID)) ?? false
    }

    /// 本機專案區：「全部專案」原樣回傳；選了空間只留成員（已刪的專案 id 自然略過）。
    func visible<Item>(_ items: [Item], id: (Item) -> UUID) -> [Item] {
        guard let space = selectedSpace else { return items }
        let members = Set(space.projectIDs)
        return items.filter { members.contains(id($0)) }
    }

    /// 遠端設備區塊：同一套規則，成員以（設備, 專案）認。
    func showsRemote(_ projectID: UUID, deviceID: String) -> Bool {
        guard let space = selectedSpace else { return true }
        return space.remoteProjects.contains(.init(deviceID: deviceID, projectID: projectID))
    }

    // MARK: 改（每次改完原子寫入）

    func select(_ id: UUID?) {
        guard file.selectedSpaceID != id else { return }
        file.selectedSpaceID = id.flatMap { id in activeSpaces.contains { $0.id == id } ? id : nil }
        save()
    }

    /// 新增並選取；名字重複就補編號。
    @discardableResult
    func addSpace(named name: String = "新的專案空間") -> UUID {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(36))
        let base = trimmed.isEmpty ? "新的專案空間" : trimmed
        let names = Set(file.spaces.map(\.name))
        var candidate = base, index = 2
        while names.contains(candidate) { candidate = "\(base) \(index)"; index += 1 }
        let space = CoderProjectSpace(name: candidate)
        file.spaces.append(space)
        file.selectedSpaceID = space.id
        save()
        return space.id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty, let index = file.spaces.firstIndex(where: { $0.id == id }),
              file.spaces[index].name != trimmed else { return }
        file.spaces[index].name = trimmed
        save()
    }

    /// 封存不直刪：專案本身不動，之後可以還原。選著的被封存就回到「全部專案」。
    func archive(_ id: UUID) {
        guard let index = file.spaces.firstIndex(where: { $0.id == id }) else { return }
        file.spaces[index].isArchived = true
        if file.selectedSpaceID == id { file.selectedSpaceID = nil }
        save()
    }

    func restore(_ id: UUID) {
        guard let index = file.spaces.firstIndex(where: { $0.id == id }) else { return }
        file.spaces[index].isArchived = false
        save()
    }

    func setMember(localProject projectID: UUID, in spaceID: UUID, _ isMember: Bool) {
        guard let index = file.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        file.spaces[index].projectIDs.removeAll { $0 == projectID }
        if isMember { file.spaces[index].projectIDs.append(projectID) }
        save()
    }

    func setMember(remoteProject projectID: UUID, deviceID: String, in spaceID: UUID, _ isMember: Bool) {
        guard let index = file.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let ref = CoderProjectSpace.RemoteProject(deviceID: deviceID, projectID: projectID)
        file.spaces[index].remoteProjects.removeAll { $0 == ref }
        if isMember { file.spaces[index].remoteProjects.append(ref) }
        save()
    }

    /// 專案列右鍵「移到專案空間」：從其他空間拿出來，放進這一個；nil＝移出所有空間。
    func move(localProject projectID: UUID, to spaceID: UUID?) {
        for index in file.spaces.indices { file.spaces[index].projectIDs.removeAll { $0 == projectID } }
        if let spaceID, let index = file.spaces.firstIndex(where: { $0.id == spaceID }) {
            file.spaces[index].projectIDs.append(projectID)
        }
        save()
    }

    /// 在某個空間裡新建或匯入的專案，歸進目前的空間（「全部專案」時不動）。
    func adoptLocalProject(_ projectID: UUID?) {
        adoptLocalProjects(projectID.map { [$0] } ?? [])
    }

    /// 一批匯入的專案一起歸進目前的空間，只寫一次檔。
    func adoptLocalProjects(_ projectIDs: [UUID]) {
        guard let space = selectedSpace, let index = file.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        var added = false
        for projectID in projectIDs where !file.spaces[index].projectIDs.contains(projectID) {
            file.spaces[index].projectIDs.append(projectID)
            added = true
        }
        if added { save() }
    }
}
