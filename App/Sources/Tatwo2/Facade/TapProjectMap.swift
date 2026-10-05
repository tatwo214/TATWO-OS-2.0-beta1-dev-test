import CryptoKit
import Darwin
import Foundation

/// 只有落點 metadata；不保存文字、前言或摘要。
struct TapProjectMap: Codable, Equatable, Sendable {
    var chatgpt_project_id: String
    var name: String
    var threads: [String: String] = [:]
    var updated_at: String = ISO8601DateFormatter().string(from: Date())
}

/// 檔案 I/O 不在主執行緒；同一個 App 的讀改寫序列化，避免不同討論串互相覆蓋。
actor TapProjectMapStore {
    static let shared = TapProjectMapStore()
    static let didChange = Notification.Name("TapProjectMapChanged")

    /// 畫面只讀；不建立資料夾、不遷移舊表，也不把名稱寫入診斷。
    nonisolated static func displayMap(at folder: URL) -> TapProjectMap? {
        guard let current = try? safeFile(folder) else { return nil }
        let mapsRoot = current.deletingLastPathComponent().deletingLastPathComponent()
        for (file, root) in [(current, mapsRoot), (folder.appendingPathComponent(".tatwo/tap-map.json"), folder)] {
            guard let text = try? HandsSkillet.readOwned(file, root: root),
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["archived"] as? Bool != true,
                  let id = object["chatgpt_project_id"] as? String, id.hasPrefix("g-p-"),
                  let name = object["name"] as? String, name.hasPrefix("TATWO · "), name.count <= 160,
                  !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  HandsRedactor.redact(name, context: .init(paths: [], hostName: nil, userName: nil)) == name else { continue }
            return TapProjectMap(chatgpt_project_id: id, name: name,
                threads: object["threads"] as? [String: String] ?? [:], updated_at: object["updated_at"] as? String ?? "")
        }
        return nil
    }

    func prepareInbox(at folder: URL) throws {
        var info = stat()
        if lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw TapError.remote("TAP 收件匣不能使用符號連結")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    func load(at folder: URL) throws -> TapProjectMap? {
        let file = try Self.safeFile(folder)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return try migrateLegacy(at: folder)
        }
        let map = try JSONDecoder().decode(TapProjectMap.self, from: Data(contentsOf: file))
        guard map.chatgpt_project_id.hasPrefix("g-p-"), !map.name.isEmpty else {
            throw TapError.remote("TAP 專案對應表的 ID 無效")
        }
        return map
    }

    /// 保留舊對話 ID；舊表安全讀取、原子存到 App 資料夾之後才移除 repo 裡的副本。
    private func migrateLegacy(at folder: URL) throws -> TapProjectMap? {
        let legacy = folder.appendingPathComponent(".tatwo/tap-map.json")
        var original = stat()
        guard lstat(legacy.path, &original) == 0 else {
            if errno == ENOENT { return nil }
            throw TapError.remote("舊 TAP 對應表讀不到，這句未送出；請確認專案資料夾權限")
        }
        let directoryFD = open(legacy.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw TapError.remote("舊 TAP 對應表不能安全遷移，這句未送出") }
        defer { close(directoryFD) }
        let text = try HandsSkillet.readOwned(legacy, root: folder)
        let data = Data(text.utf8)
        let map = try JSONDecoder().decode(TapProjectMap.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard Set(object?.keys.map { $0 } ?? []) == Set(["chatgpt_project_id", "name", "threads", "updated_at"]),
              map.chatgpt_project_id.hasPrefix("g-p-"), !map.name.isEmpty else {
            throw TapError.remote("舊 TAP 對應表格式無法確認，這句未送出；原檔已保留")
        }
        try save(map, at: folder, mergeThreads: false)
        var current = stat()
        guard fstatat(directoryFD, "tap-map.json", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG, current.st_uid == getuid(), current.st_nlink == 1,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              current.st_size == original.st_size, current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else {
            throw TapError.remote("舊 TAP 對應表在遷移時變動，原檔已保留；請確認後再送")
        }
        guard unlinkat(directoryFD, "tap-map.json", 0) == 0 else {
            throw TapError.remote("TAP 對應表已安全儲存，但舊副本未能移除；請確認專案資料夾權限")
        }
        return map
    }

    func save(_ map: TapProjectMap, at folder: URL, threadID: UUID? = nil, conversationID: String? = nil, mergeThreads: Bool = true) throws {
        let file = try Self.safeFile(folder)
        let directory = file.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var merged = map
        if mergeThreads, let current = try load(at: folder), current.chatgpt_project_id == map.chatgpt_project_id {
            merged.threads.merge(current.threads) { _, current in current }
        }
        if let threadID, let conversationID { merged.threads[threadID.uuidString] = conversationID }
        merged.updated_at = ISO8601DateFormatter().string(from: Date())
        // 暫存檔建立時已 0600，rename 原子替換；沒有世界可讀的短暫空窗。
        let temporary = directory.appendingPathComponent(".tap-map-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TapError.remote("不能建立 TAP 專案對應表") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try handle.write(contentsOf: encoder.encode(merged))
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, file.path) == 0 else {
                throw TapError.remote("不能原子寫入 TAP 專案對應表")
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temporary) // 自己尚未提交的暫存檔，沒有使用者內容。
            throw error
        }
    }

    /// App 自己的資料夾，以完整專案路徑的 digest 分隔；不寫進使用者的 repo。
    nonisolated static func mapFile(at folder: URL) -> URL {
        let root = ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tatwo2")
        let key = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("tap-maps/" + key, isDirectory: true).appendingPathComponent("tap-map.json")
    }

    nonisolated private static func safeFile(_ folder: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TapError.remote("OS 專案資料夾不在，不能儲存 TAP 對應表")
        }
        let file = Self.mapFile(at: folder)
        let directory = file.deletingLastPathComponent()
        for path in [folder, directory.deletingLastPathComponent(), directory, file] {
            var info = stat()
            if lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw TapError.remote("TAP 對應表不能使用符號連結")
            }
        }
        return file
    }
}

struct TapProjectContext: Sendable {
    let id: UUID
    let name: String
    let folder: URL
    var shortID: String { String(id.uuidString.prefix(8)) }
    var tapName: String { "TATWO · \(name)" }
    var description: String { "由 TATWO OS 建立，對應專案 \(name)（\(shortID)）。請把這個專案的工作都放這裡。" }
}

struct TapProjectDestination: Sendable {
    let folder: URL
    let map: TapProjectMap
    let conversationID: String?
    let notice: String?
}

@MainActor
final class TapProjectMapper {
    let tap: any ConversationTap
    let storage: TapProjectMapStore
    let inboxFolder: URL
    private var resolving: [UUID: Task<TapProjectMap, Error>] = [:]
    private static let inboxID = UUID(uuidString: "00000000-0000-0000-0000-000000000185")!
    init(tap: any ConversationTap, storage: TapProjectMapStore = .shared, inboxFolder: URL) {
        self.tap = tap
        self.storage = storage
        self.inboxFolder = inboxFolder
    }

    private enum ResolutionError: Error { case missingProject, missingConversation }

    func destination(project: TapProjectContext?, threadID: UUID) async throws -> TapProjectDestination {
        var notice: String?
        if let project {
            do { return try await resolve(project, threadID: threadID, notice: nil) }
            catch ResolutionError.missingProject {
                try Task.checkCancellation()
                notice = "對應的 ChatGPT 專案已不存在，這句改送「TATWO · 收件匣」"
            }
            catch ResolutionError.missingConversation {
                // 專案還在，只清掉這一串的失效對話 ID，不改送其他專案。
                guard var map = try await storage.load(at: project.folder) else { throw ResolutionError.missingConversation }
                map.threads.removeValue(forKey: threadID.uuidString)
                try await storage.save(map, at: project.folder, mergeThreads: false)
                return try await resolve(project, threadID: threadID, notice: "對應的 ChatGPT 對話已不存在，將在原專案開新對話")
            }
        }
        // 收件匣也失敗就明確未送出。沒有 gizmoID=nil 的一般聊天退路。
        let inbox = TapProjectContext(id: Self.inboxID, name: "收件匣", folder: inboxFolder)
        do {
            try await storage.prepareInbox(at: inboxFolder)
            let destination = try await resolve(inbox, threadID: threadID, notice: notice)
            if let project {
                // 原專案的對應表跟著修正；下一輪沿用這次的收件匣對話。
                var map = destination.map
                map.threads = [:]
                try await storage.save(map, at: project.folder, mergeThreads: false)
                return TapProjectDestination(folder: project.folder, map: map, conversationID: nil, notice: notice)
            }
            return destination
        }
        catch {
            throw TapError.remote((notice.map { $0 + "；" } ?? "") + "收件匣也無法使用，這句未送出：\(error.localizedDescription)")
        }
    }

    private func resolve(_ project: TapProjectContext, threadID: UUID, notice: String?) async throws -> TapProjectDestination {
        let task: Task<TapProjectMap, Error>
        if let existing = resolving[project.id] { task = existing }
        else {
            task = Task { @MainActor [tap, storage] in
                let saved = try await storage.load(at: project.folder)
                let projects = try await tap.projects()
                try Task.checkCancellation()
                if let saved {
                    guard var folder = projects.first(where: { $0.id == saved.chatgpt_project_id && $0.kind == .project }) else {
                        throw ResolutionError.missingProject
                    }
                    if folder.description.isEmpty { folder = try await tap.projectDetails(projectID: folder.id) }
                    let expectedID = project.shortID
                    let inboxDescription = saved.name == "TATWO · 收件匣"
                        && folder.description.contains(String(Self.inboxID.uuidString.prefix(8)))
                    guard folder.description.contains(expectedID) || inboxDescription else {
                        throw TapError.remote("ChatGPT 專案的識別說明不屬於這個 OS 專案")
                    }
                    return saved
                }
                var found: TapFolder?
                for var candidate in projects where candidate.kind == .project && candidate.id.hasPrefix("g-p-")
                    && candidate.title == project.tapName {
                    if candidate.description.isEmpty { candidate = try await tap.projectDetails(projectID: candidate.id) }
                    if candidate.description.contains(project.shortID) { found = candidate; break }
                }
                let folder: TapFolder
                if let found { folder = found }
                else { folder = try await tap.createProject(name: project.tapName, description: project.description) }
                guard folder.id.hasPrefix("g-p-"), folder.kind == .project else {
                    throw TapError.remote("ChatGPT 沒有提供有效的專案 ID")
                }
                let map = TapProjectMap(chatgpt_project_id: folder.id, name: project.tapName)
                try await storage.save(map, at: project.folder)
                return map
            }
            resolving[project.id] = task
        }
        defer { resolving[project.id] = nil }
        let map = try await task.value
        try Task.checkCancellation()
        // 另一條正在回答時可能剛把 conversationID 記進表，重新讀最新值。
        let latest = try await storage.load(at: project.folder) ?? map
        if let conversation = latest.threads[threadID.uuidString] {
            let conversations = try await tap.conversations(inProject: latest.chatgpt_project_id)
            guard conversations.contains(where: { $0.id == conversation }) else {
                throw ResolutionError.missingConversation
            }
        }
        return TapProjectDestination(folder: project.folder, map: latest,
                                     conversationID: latest.threads[threadID.uuidString], notice: notice)
    }

    func record(_ conversationID: String, threadID: UUID, destination: TapProjectDestination) async throws {
        guard !conversationID.isEmpty else { throw TapError.remote("ChatGPT 沒有提供對話 ID") }
        try await storage.save(destination.map, at: destination.folder, threadID: threadID, conversationID: conversationID)
    }
}
