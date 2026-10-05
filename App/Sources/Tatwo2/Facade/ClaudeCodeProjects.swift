import Foundation

/// W181 R1：Claude Code 的專案＝`~/.claude/projects/<編碼過的資料夾>/`，一個資料夾一個專案、照最近活動排。
/// 每則只讀頭尾各一段（跟 W110 一樣）：標題類的行 Claude Code 會補寫在檔尾。
/// 桌面 App 的 Code 對話（`claude-code-sessions/…/local_*.json`）有同一個 session 就用它的標題；封存的不列。
enum ClaudeCodeProjects {
    struct Meta: Equatable, Sendable {
        var cwd = ""
        var entrypoint: String?
        var sidechain = false
        var agentName: String?
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstPrompt: String?
    }

    struct DesktopSession: Equatable, Sendable {
        let title: String?
        let archived: Bool
    }

    static let sampleBytes = CLITranscriptArchive.sampleBytes

    /// Claude Code 自己的標題順序（它的 session 清單就是這樣排）：桌面 App 的標題 → 代理名稱 → 自訂標題（/rename）
    /// → AI 取的標題 → 摘要 → 第一句真的使用者話。
    static func officialTitle(_ meta: Meta, desktopTitle: String? = nil) -> String? {
        [desktopTitle, meta.agentName, meta.customTitle, meta.aiTitle, meta.summary, meta.firstPrompt]
            .lazy.compactMap(CoderImportCatalog.titleLine).first
    }

    /// 背景執行（`claude -p`＝sdk-cli、SDK、MCP）不列；沒寫 entrypoint 的舊檔當成一般對話。
    static func isBackground(entrypoint: String?) -> Bool {
        guard let entrypoint else { return false }
        return entrypoint.hasPrefix("sdk") || entrypoint == "mcp"
    }

    static func load(projectsRoot: URL, desktopSessions: URL, home: String) -> [CoderImportProject] {
        let desktop = desktopSessionsByID(desktopSessions)
        let fm = FileManager.default
        // ~/.claude 可能是捷徑：先解開，路徑跟 E3（CLITranscriptArchive）存的一樣。
        let projectsRoot = projectsRoot.resolvingSymlinksInPath()
        let folders = ((try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var projects: [CoderImportProject] = []
        for folder in folders {
            if Task.isCancelled { break }
            // 只看資料夾第一層的 <session>.jsonl；<session>/subagents/ 底下是子代理。
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            var conversations: [CoderImportConversation] = []
            for file in files {
                let id = file.deletingPathExtension().lastPathComponent
                let info = CoderImportCatalog.fileInfo(file.path)
                guard info.exists, info.bytes > 0, let meta = scan(file, size: info.bytes) else { continue }
                let app = desktop[id]
                guard !meta.sidechain, app?.archived != true, app != nil || !isBackground(entrypoint: meta.entrypoint),
                      let title = officialTitle(meta, desktopTitle: app?.title) else { continue }
                let modified = info.modified ?? .distantPast
                let session = CLITranscriptSession(url: file, engine: .claude, origin: .native, sessionID: id, title: title,
                                                   cwd: meta.cwd, modifiedAt: modified, bytes: info.bytes, isBatch: false)
                conversations.append(.init(session: session, activity: modified, fileExists: true))
            }
            guard !conversations.isEmpty else { continue }
            conversations.sort { $0.activity > $1.activity }
            let root = conversations.first { !$0.session.cwd.isEmpty }?.session.cwd ?? ""
            let name = CoderImportCatalog.folderName(root, home: home)
            projects.append(CoderImportProject(id: "claude:" + folder.lastPathComponent, engine: .claude,
                                               name: name.isEmpty ? folder.lastPathComponent : name, root: root,
                                               conversations: conversations))
        }
        return projects.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// 讀頭尾各一段（只讀）；檔頭取資料夾、入口、是不是子代理、第一句，頭尾都找標題類的行（後面的蓋前面的）。
    static func scan(_ url: URL, size: Int64) -> Meta? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: sampleBytes)) ?? Data()
        var tail = Data()
        if size > Int64(sampleBytes) {
            let offset = UInt64(max(Int64(sampleBytes), size - Int64(sampleBytes)))
            if (try? handle.seek(toOffset: offset)) != nil { tail = (try? handle.readToEnd()) ?? Data() }
        }
        var meta = Meta(), decided = false
        var headLines = head.split(separator: 0x0A, omittingEmptySubsequences: true)
        if size > Int64(head.count), !headLines.isEmpty { headLines.removeLast() }   // 讀到一半的那行
        var tailLines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        if !tailLines.isEmpty { tailLines.removeFirst() }
        for line in headLines {
            autoreleasepool {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return }
                if meta.cwd.isEmpty, let cwd = object["cwd"] as? String { meta.cwd = cwd }
                if meta.entrypoint == nil, let entry = object["entrypoint"] as? String { meta.entrypoint = entry }
                let type = object["type"] as? String
                if !decided, type == "user" || type == "assistant" {
                    decided = true
                    meta.sidechain = object["isSidechain"] as? Bool == true
                }
                if meta.firstPrompt == nil, type == "user" {
                    for item in CLITranscriptArchive.items(from: object, engine: .claude, nextID: 0) where item.kind == .user {
                        if let text = CoderImport.spokenText(item.text) { meta.firstPrompt = text; break }
                    }
                }
                note(object, into: &meta)
            }
        }
        let markers = ["agent-name", "custom-title", "ai-title", "summary"].map { Data("\"type\":\"\($0)\"".utf8) }
        for line in tailLines where markers.contains(where: { line.range(of: $0) != nil }) {
            autoreleasepool {
                if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { note(object, into: &meta) }
            }
        }
        return meta
    }

    private static func note(_ object: [String: Any], into meta: inout Meta) {
        switch object["type"] as? String {
        case "agent-name": if let value = object["agentName"] as? String { meta.agentName = value }
        case "custom-title": if let value = object["customTitle"] as? String { meta.customTitle = value }
        case "ai-title": if let value = object["aiTitle"] as? String { meta.aiTitle = value }
        case "summary": if let value = object["summary"] as? String { meta.summary = value }
        default: break
        }
    }

    /// 桌面 App 的 Code 對話：session id（去掉 local_ 前綴也認）→ 標題、封存。只讀 json，不動它。
    static func desktopSessionsByID(_ root: URL) -> [String: DesktopSession] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: DesktopSession] = [:]
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            if walker.level > 4 { walker.skipDescendants(); continue }
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = object["sessionId"] as? String, !id.isEmpty else { continue }
            let entry = DesktopSession(title: object["title"] as? String, archived: object["isArchived"] as? Bool == true)
            out[id] = entry
            if id.hasPrefix("local_") { out[String(id.dropFirst("local_".count))] = entry }
            for key in ["cliSessionId", "claudeSessionId"] {
                if let other = object[key] as? String, !other.isEmpty { out[other] = entry }
            }
        }
        return out
    }
}
