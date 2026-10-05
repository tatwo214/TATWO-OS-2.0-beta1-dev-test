import Foundation

/// W181 R1：匯入瀏覽器的一則對話。預覽與匯入沿用 W110／E3（CLITranscriptSession）；標題已換成各家自己的正式標題。
struct CoderImportConversation: Identifiable, Equatable, Sendable {
    let session: CLITranscriptSession
    /// 最後活動：Codex 用它自己的 recency，Claude Code 用原檔修改時間。
    let activity: Date
    /// 原檔還在不在（Codex 紀錄裡有、但檔案被清掉的就不能匯入）。
    let fileExists: Bool

    var id: String { session.engine.rawValue + ":" + (session.sessionID.isEmpty ? session.url.path : session.sessionID) }
    var title: String { session.title }
    /// 跟 E3 的去重一樣（家別＋session id；沒有 id 才比原檔路徑）：「已匯入」不靠路徑字串，捷徑解開與否都認得。
    var importKey: String { CoderImport.dedupeKey(engine: session.engine.rawValue, sessionID: session.sessionID, path: session.url.path) }
}

/// W181 R1 審查修正：「看原檔」要找的那則。用家別＋session id 找（~/.codex、~/.claude 可能是捷徑，
/// E3 存的是解開後的路徑、各家資料庫記的是沒解開的）；沒有 id 才比解開捷徑後的路徑。
struct CoderImportFocus: Equatable, Sendable {
    let engine: CLITranscriptSession.Engine?
    let sessionID: String
    let path: String

    init(engine: CLITranscriptSession.Engine?, sessionID: String, path: String) {
        self.engine = engine; self.sessionID = sessionID; self.path = path
    }
    init(_ source: CoderImportSource) {
        self.init(engine: CLITranscriptSession.Engine(rawValue: source.engine), sessionID: source.sessionID, path: source.path)
    }

    func matches(_ session: CLITranscriptSession) -> Bool {
        if let engine, session.engine != engine { return false }
        if !sessionID.isEmpty, !session.sessionID.isEmpty { return session.sessionID == sessionID }
        return CoderImportCatalog.resolvedPath(session.url.path) == CoderImportCatalog.resolvedPath(path)
    }
}

/// W181 R1 審查修正：整批放進 Coder 的哪個專案（名稱＋資料夾）。
struct CoderImportPlacement: Equatable, Sendable {
    let name: String
    let workdir: String
}

/// W181 R1：左欄的一個專案，照 Codex App／Claude Code 自己左邊欄的樣子。
struct CoderImportProject: Identifiable, Equatable, Sendable {
    let id: String
    let engine: CLITranscriptSession.Engine
    let name: String
    /// 專案根目錄（匯入時 Coder 同名專案的資料夾）；「沒有專案的對話」是空字串，各則照自己的資料夾放。
    let root: String
    var isPinned = false
    var isProjectless = false
    /// 新到舊。
    var conversations: [CoderImportConversation]

    var lastActivity: Date? { conversations.first?.activity }
}

/// W181 R1：讀各家自己的專案清單。全部只讀：不寫、不搬、不連網；資料庫用唯讀開、查完就關。
enum CoderImportCatalog {
    struct Roots: Sendable {
        let codexHome: URL
        let claudeProjects: URL
        let claudeDesktopSessions: URL
        let home: String

        /// 使用者自己在用的 Codex App／Claude Code（不是 OS 內建引擎的隔離家目錄）。
        static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Roots {
            Roots(codexHome: home.appendingPathComponent(".codex"),
                  claudeProjects: home.appendingPathComponent(".claude/projects"),
                  claudeDesktopSessions: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
                  home: home.path)
        }
    }

    static let projectlessName = "沒有專案的對話"
    static let untitled = "（沒有標題）"
    /// 預覽只讀原檔最後這麼多（防護性：這台清單裡有幾百 MB 的對話，整份讀很慢又吃記憶體；
    /// 沒有證實這就是 W181「關不掉」的原因）。要看全部按「讀完整紀錄」，照 W110 整份讀、可以取消。
    static let previewTailBytes = 2 * 1024 * 1024
    static let previewRows = 60
    /// 用量到上限的這個比例才出一行提醒；平常不顯示數字。
    static let nearCapRatio = 0.8

    static func load(_ engine: CLITranscriptSession.Engine, roots: Roots) -> [CoderImportProject] {
        switch engine {
        case .codex: return CodexAppProjects.load(codexHome: roots.codexHome)
        case .claude: return ClaudeCodeProjects.load(projectsRoot: roots.claudeProjects,
                                                     desktopSessions: roots.claudeDesktopSessions, home: roots.home)
        }
    }

    /// 標題只取第一行、去頭尾空白、最多 120 字；空的回 nil（照順序換下一個來源）。
    static func titleLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : String(line.prefix(120))
    }

    /// 原檔在不在、多大、什麼時候改的（只看檔案屬性，不開檔）。
    static func fileInfo(_ path: String) -> (exists: Bool, bytes: Int64, modified: Date?) {
        guard !path.isEmpty, let values = try? FileManager.default.attributesOfItem(atPath: path),
              (values[.type] as? FileAttributeType) == .typeRegular else { return (false, 0, nil) }
        return (true, (values[.size] as? NSNumber)?.int64Value ?? 0, values[.modificationDate] as? Date)
    }

    /// 專案顯示名：家目錄叫「家目錄」（跟匯入後的 Coder 專案同名），其他用資料夾名。
    static func folderName(_ path: String, home: String) -> String {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let normalized = CoderImport.normalized(path)
        if normalized == CoderImport.normalized(home) { return CoderImport.homeProjectName }
        let name = URL(fileURLWithPath: normalized).lastPathComponent
        return name.isEmpty ? normalized : name
    }

    // MARK: 路徑與專案歸屬

    /// 解開捷徑再比（~/.codex、~/.claude 在這台是捷徑）；不存在的路徑照原樣標準化。
    static func resolvedPath(_ path: String) -> String {
        let normalized = CoderImport.normalized(path)
        guard normalized.hasPrefix("/") else { return normalized }
        return CoderImport.normalized(URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path)
    }

    /// 「看原檔」那則在哪個專案（只找清單裡的；子代理、背景執行不在清單）。
    static func locate(_ focus: CoderImportFocus, in projects: [CoderImportProject])
        -> (project: CoderImportProject, conversation: CoderImportConversation)? {
        for project in projects {
            if let hit = project.conversations.first(where: { focus.matches($0.session) }) { return (project, hit) }
        }
        return nil
    }

    /// 整批放進 Coder 的哪個專案。資料夾一律解開捷徑再比：
    /// 1. 來源的根目錄是家目錄 → E3 的「家目錄」專案。
    /// 2. 有 Coder 專案在同一個資料夾 → 用它（名字不同也一樣；E3 照資料夾對到它）。
    /// 3. 來源沒有根目錄 → 只能靠名字：同名專案（家目錄的只認「家目錄」）；都沒有就放家目錄。
    /// 4. 同名但資料夾不同 → 不沿用（否則對話會被放進別的資料夾、接著做時在錯的 repo 裡跑），
    ///    用來源的根目錄新建，名字加上資料夾做區別，例如「tmp（private）」。
    static func placement(name: String, root: String, projects: [CoderImport.ProjectInfo], home: String) -> CoderImportPlacement {
        let homePath = CoderImport.normalized(home)
        let resolvedHome = resolvedPath(home)
        let trimmed = root.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            if let same = projects.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    && (resolvedPath($0.workdir) != resolvedHome || $0.name == CoderImport.homeProjectName)
            }) { return .init(name: same.name, workdir: same.workdir) }
            return .init(name: CoderImport.homeProjectName, workdir: homePath)
        }
        let target = resolvedPath(trimmed)
        if target == resolvedHome { return .init(name: CoderImport.homeProjectName, workdir: homePath) }
        if let same = projects.first(where: { resolvedPath($0.workdir) == target }) { return .init(name: same.name, workdir: same.workdir) }
        let folder = CoderImport.normalized(trimmed)
        return .init(name: distinctName(name, root: folder, taken: projects.map(\.name)), workdir: folder)
    }

    /// 名字被別的資料夾用掉時加上區別：先用資料夾名（跟名字不同時），再用上一層資料夾，最後用整個路徑。
    static func distinctName(_ name: String, root: String, taken: [String]) -> String {
        func free(_ candidate: String) -> Bool { !taken.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame } }
        let url = URL(fileURLWithPath: root)
        let folder = url.lastPathComponent
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? folder : name
        if free(base) { return base }
        var hints: [String] = []
        if !folder.isEmpty, folder != "/", folder.caseInsensitiveCompare(base) != .orderedSame { hints.append(folder) }
        let parent = url.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty, parent != "/" { hints.append(parent) }
        hints.append((root as NSString).abbreviatingWithTildeInPath)
        for hint in hints where free("\(base)（\(hint)）") { return "\(base)（\(hint)）" }
        let last = "\(base)（\(hints[hints.count - 1])）"
        var number = 2
        while !free("\(last) \(number)") { number += 1 }
        return "\(last) \(number)"
    }

    // MARK: 完整紀錄的篩選（照 W110 閱讀器的規則；在背景算，不卡畫面）

    static func filter(_ items: [CLITranscriptItem], query: String, showsTools: Bool) -> [CLITranscriptItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var out: [CLITranscriptItem] = []
        for item in items {
            if Task.isCancelled { break }
            guard showsTools || (item.kind != .toolCall && item.kind != .toolResult) else { continue }
            if needle.isEmpty || item.text.range(of: needle, options: .caseInsensitive) != nil
                || (item.toolName ?? "").range(of: needle, options: .caseInsensitive) != nil {
                out.append(item)
            }
        }
        return out
    }

    // MARK: 預覽（只讀原檔最後一段，解析照 W110 的規則）

    /// 只留你說的、AI 回的、壓縮摘要（跟匯入進 Coder 的一樣）；工具呼叫與輸出不顯示。partial＝前面還有沒讀的。
    static func previewItems(_ session: CLITranscriptSession, maxBytes: Int = previewTailBytes,
                             rows: Int = previewRows) -> (items: [CLITranscriptItem], partial: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: session.url) else { return ([], false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return ([], false) }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // 切在一行中間
        let marker = Data((session.engine == .claude ? "\"type\":\"user\"" : "\"type\":\"response_item\"").utf8)
        let markerAlt = Data("\"type\":\"assistant\"".utf8)
        var items: [CLITranscriptItem] = []
        for line in lines {
            if Task.isCancelled { break }
            guard line.range(of: marker) != nil || (session.engine == .claude && line.range(of: markerAlt) != nil) else { continue }
            autoreleasepool {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return }
                for item in CLITranscriptArchive.items(from: object, engine: session.engine, nextID: items.count) {
                    switch item.kind {
                    case .user:
                        if let text = CoderImport.spokenText(item.text) {
                            items.append(.init(id: items.count, kind: .user, text: text, toolName: nil, timestamp: item.timestamp, clipped: item.clipped))
                        }
                    case .assistant, .summary:
                        items.append(.init(id: items.count, kind: item.kind, text: item.text, toolName: nil, timestamp: item.timestamp, clipped: item.clipped))
                    case .toolCall, .toolResult: break
                    }
                }
            }
        }
        let kept = Array(items.suffix(rows))
        return (kept, start > 0 || items.count > kept.count)
    }

    // MARK: 用量

    /// 平常不顯示；接近上限才說一句白話（不再出現「已用 Zero KB」這種字）。
    static func nearCapNotice(used: Int, cap: Int = CoderImport.maxImportedBytesTotal) -> String? {
        guard cap > 0, Double(used) >= Double(cap) * nearCapRatio else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(cap), countStyle: .file)
        return used >= cap
            ? "Coder 裡的匯入已經滿了（上限 \(size)），不能再匯入；完整紀錄還是可以在這裡看。"
            : "Coder 裡的匯入快滿了（上限 \(size)）；滿了之後就不能再匯入。"
    }
}
