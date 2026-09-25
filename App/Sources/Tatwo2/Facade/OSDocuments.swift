import Foundation

struct OSDocument: Identifiable, Hashable {
    enum Audience: String, CaseIterable, Hashable {
        case user
        case engineering
    }

    let id: String
    let title: String
    let audience: Audience
    let path: String
    let whatItIsFor: String
    let isEditable: Bool
}

enum OSDocuments {
    // Installed by the App's W78 coordinator. Kept injectable so the Foundation
    // document adapter remains independently usable by legacy migration tooling.
    static var secondaryWriter: ((String, String, String) throws -> WriteOutcome)?
    private static let writeLock = NSRecursiveLock()
    private static var readBases: [String: String] = [:]
    enum DocumentError: LocalizedError {
        case unknownDocument(String)
        case readOnly(String)
        case missingEntry(String)
        case missingDocument(String, String)

        var errorDescription: String? {
            switch self {
            case let .unknownDocument(id):
                return "找不到文件：\(id)"
            case let .readOnly(id):
                return "文件不可編輯：\(id)"
            case let .missingEntry(path):
                return "找不到入口 \(path)"
            case let .missingDocument(name, path):
                return "入口缺少 \(name)\n\(path)"
            }
        }
    }

    /// 入口文件與 repo 文件共用 TatwoEntry；執行期上游不搬移。
    static var osRoot: String {
        TatwoEntry().root.path
    }

    /// 憲法 v4.1 §10：todo.md／issue.md 是每個使用者自己的，放入口、隨入口跨設備；
    /// TATWO2_DOCS_ROOT 只留給舊的覆寫與測試。
    static var docsRoot: String {
        ProcessInfo.processInfo.environment["TATWO2_DOCS_ROOT"]
            ?? TatwoEntry().root.path
    }

    static var skilletPath: String {
        ProcessInfo.processInfo.environment["TATWO2_SKILLET_PATH"]
            ?? TatwoEntry().skillet.path
    }

    static func list() -> [OSDocument] {
        return [
            OSDocument(
                id: "os",
                title: "os.md",
                audience: .user,
                path: TatwoEntry().constitution.path,
                whatItIsFor: "放 TATWO OS 長期不變的規矩。",
                isEditable: true),
            OSDocument(
                id: "agents",
                title: "agents.md",
                audience: .user,
                path: TatwoEntry().root.appendingPathComponent("agents.md").path,
                whatItIsFor: "所有 AI 引擎共讀的規則；由 os.md 的「引擎摘要」產生，唯讀。",
                isEditable: false),
            OSDocument(
                id: "user",
                title: "user.md",
                audience: .user,
                path: TatwoEntry().root.appendingPathComponent("user.md").path,
                whatItIsFor: "你的偏好；所有 AI 開工前都會讀。",
                isEditable: true),
            OSDocument(
                id: "skillet",
                title: "skillet.md",
                audience: .user,
                path: skilletPath,
                whatItIsFor: "放主設備上各家 AI 共用的常用技能說明。",
                isEditable: true),
            OSDocument(
                id: "os-upstream",
                title: "os-upstream.md",
                audience: .user,
                path: OSUpstream.overridePath,
                whatItIsFor: "放每條新對話啟動時交給引擎的一頁規則。",
                isEditable: true),
            OSDocument(
                id: "todo",
                title: "todo.md",
                audience: .engineering,
                path: docsURL.appendingPathComponent("todo.md").path,
                whatItIsFor: "放已經決定、可以直接施工的工作。",
                isEditable: true),
            OSDocument(
                id: "issue",
                title: "issue.md",
                audience: .engineering,
                path: docsURL.appendingPathComponent("issue.md").path,
                whatItIsFor: "放還需要使用者拍板的方向。",
                isEditable: true),
        ]
    }

    static func read(id: String) throws -> String {
        writeLock.lock(); defer { writeLock.unlock() }
        let document = try document(id: id)
        try requireExisting(document)
        let text = try String(contentsOfFile: document.path, encoding: .utf8)
        readBases[id] = text
        return text
    }

    enum WriteOutcome: Equatable {
        case saved
        case committed
        case secondary
        case unchanged
        case commitFailed(String)

        var message: String {
            switch self {
            case .saved: return "已儲存，舊版已備份"
            case .committed: return "已儲存並提交，舊版已備份"
            case .secondary: return "已儲存；副設備：未提交"
            case .unchanged: return "已儲存；內容未變，無需提交"
            case let .commitFailed(reason): return "已儲存但未提交：\(reason)"
            }
        }
    }

    @discardableResult
    static func write(id: String, text: String) throws -> WriteOutcome {
        writeLock.lock(); defer { writeLock.unlock() }
        if !isPrimary, id != "os-upstream", let secondaryWriter {
            let base = try readBases[id] ?? String(contentsOfFile: document(id: id).path, encoding: .utf8)
            return try secondaryWriter(id, text, base)
        }
        return try writeLocal(id: id, text: text)
    }

    /// Only an authenticated device RPC may call this. Compare before any backup,
    /// write, or commit. The caller returns the three versions on conflict.
    static func writeFromDevice(id: String, text: String, base: String, source: String) throws -> WriteOutcome {
        writeLock.lock(); defer { writeLock.unlock() }
        guard isPrimary else { throw DocumentError.readOnly(id) }
        let document = try document(id: id)
        guard try String(contentsOfFile: document.path, encoding: .utf8) == base else {
            throw DocumentError.readOnly("conflict")
        }
        return try writeLocal(id: id, text: text, source: source)
    }

    private static func writeLocal(id: String, text: String, source: String? = nil) throws -> WriteOutcome {
        let document = try document(id: id)
        guard document.isEditable else { throw DocumentError.readOnly(id) }
        try requireExisting(document)

        let fileURL = URL(fileURLWithPath: document.path)
        let directory = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: fileURL.path) {
            let backupDirectory = directory.appendingPathComponent(".tatwo2-backups", isDirectory: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let backupURL = nextBackupURL(for: fileURL, in: backupDirectory)
            try fileManager.copyItem(at: fileURL, to: backupURL)
        }

        try Data(text.utf8).write(to: fileURL, options: .atomic)
        return commitIfPrimary(document, source: source)
    }

    static var isPrimary: Bool { deviceIdentity?["role"] as? String == "primary" }

    private static var deviceIdentity: [String: Any]? {
        guard let data = try? Data(contentsOf: TatwoEntry().deviceJSON) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func requireExisting(_ document: OSDocument) throws {
        let entry = TatwoEntry()
        guard entry.exists else { throw DocumentError.missingEntry(entry.root.path) }
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: document.path, isDirectory: &directory),
              !directory.boolValue else {
            throw DocumentError.missingDocument(document.title, document.path)
        }
    }

    /// 入口是 git 倉庫（W160）：主設備存檔就只提交這一個檔，之後照設定推到 GitHub 備份。
    /// 入口還不是 git（尚未開始備份）時只存檔，不算失敗。
    static let committedIDs: Set<String> = ["os", "skillet", "user", "todo", "issue"]
    private static func commitIfPrimary(_ document: OSDocument, source: String? = nil) -> WriteOutcome {
        guard committedIDs.contains(document.id) else { return .saved }
        let tracksWork = document.id == "todo" || document.id == "issue"
        guard let identity = deviceIdentity, identity["role"] as? String == "primary" else {
            return tracksWork ? .secondary : .saved
        }
        let entry = TatwoEntry()
        let root = entry.root.resolvingSymlinksInPath()
        let file = URL(fileURLWithPath: document.path).resolvingSymlinksInPath()
        // Legacy document overrides remain writable, but must never commit another repo/file.
        guard file.path.hasPrefix(root.path + "/"), !file.path.dropFirst(root.path.count + 1).contains("/") else {
            return tracksWork ? .commitFailed("文件不在入口") : .saved
        }
        let relativePath = file.lastPathComponent
        let name = source ?? (identity["name"] as? String)
            ?? (identity["deviceName"] as? String)
            ?? (identity["device_name"] as? String)
            ?? ProcessInfo.processInfo.hostName
        do {
            let top = try git(["rev-parse", "--show-toplevel"], in: entry.root)
            guard top.status == 0, URL(fileURLWithPath: top.output).resolvingSymlinksInPath() == root else {
                return .saved
            }
            if try git(["ls-files", "--error-unmatch", "--", relativePath], in: entry.root).status != 0 {
                let added = try git(["add", "--", relativePath], in: entry.root)
                guard added.status == 0 else { return .commitFailed(added.output) }
            } else {
                let changed = try git(["diff", "--quiet", "HEAD", "--", relativePath], in: entry.root)
                if changed.status == 0 { return .unchanged }
                guard changed.status == 1 else { return .commitFailed(changed.output) }
            }
            // --only/pathspec excludes even unrelated staged changes; never git add -A.
            let result = try git([
                "-c", "commit.gpgsign=false", "commit", "--only", "-m",
                "docs: 使用者經設定頁修改 \(document.title)（\(name)）",
                "--", relativePath,
            ], in: entry.root)
            guard result.status == 0 else { return .commitFailed(result.output) }
            afterCommit?()
            return .committed
        } catch {
            return .commitFailed(error.localizedDescription)
        }
    }

    /// App 啟動時接上 EntryBackup（推到使用者自己的私人 GitHub）；Foundation 測試不接。
    static var afterCommit: (() -> Void)?

    private static func git(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        // A launcher may carry GIT_DIR/GIT_INDEX_FILE; never let those redirect a save.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.arguments = ["--literal-pathspecs"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func modifiedAt(id: String) -> Date? {
        guard let document = try? document(id: id),
              let attributes = try? fileManager.attributesOfItem(atPath: document.path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    static func backupURLs(id: String) -> [URL] {
        guard let document = try? document(id: id) else { return [] }
        let fileURL = URL(fileURLWithPath: document.path)
        let directory = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".tatwo2-backups", isDirectory: true)
        return backupURLs(for: fileURL, in: directory)
    }

    private static let fileManager = FileManager.default

    private static var docsURL: URL {
        URL(fileURLWithPath: docsRoot, isDirectory: true)
    }

    private static func document(id: String) throws -> OSDocument {
        guard let document = list().first(where: { $0.id == id }) else {
            throw DocumentError.unknownDocument(id)
        }
        return document
    }

    private static func nextBackupURL(for fileURL: URL, in directory: URL) -> URL {
        var timestamp = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
        while true {
            let candidate = directory.appendingPathComponent(
                "\(fileURL.lastPathComponent).\(timestamp).md")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            timestamp += 1
        }
    }

    private static func backupURLs(for fileURL: URL, in directory: URL) -> [URL] {
        let prefix = fileURL.lastPathComponent + "."
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "md" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if left == right { return lhs.lastPathComponent < rhs.lastPathComponent }
                return left < right
            }
    }

    // Backups are user work products: retain them; permanent pruning requires a human gate.
}
