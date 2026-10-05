import Foundation
import SQLite3

/// W181 R1：Codex App 左邊欄的專案與對話。
/// 來源：`~/.codex/state_N.sqlite`（取最大號；projects、project_roots、threads、thread_spawn_edges）
/// ＋ `~/.codex/.codex-global-state.json`（專案順序、釘選、對話歸哪個專案）。
/// 資料庫只用 SQLITE_OPEN_READONLY 開、查完就關：Codex 可能正開著（WAL），不寫、不長時間持有。
/// 旁邊沒有 -wal／-shm（Codex 沒開）時唯讀開不起來，改用 immutable（不上鎖、不建任何檔）。
enum CodexAppProjects {
    /// 「沒有專案的對話」匯入 Coder 時放進的專案名（一個專案，不照每則的暫存資料夾各建一個）。
    static let projectlessCoderName = "Codex 沒有專案的對話"

    /// `state_*.sqlite` 裡號碼最大的那個（版本號會變）。
    static func stateDatabase(in codexHome: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codexHome.path)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let number = Int(name.dropFirst("state_".count).dropLast(".sqlite".count)) else { return nil }
            return (number, name)
        }
        return numbered.max { $0.0 < $1.0 }.map { codexHome.appendingPathComponent($0.1) }
    }

    /// Codex 自己的標題：改過的名字 → 標題 → 第一句 → 預覽；四個都空＝沒說過話的空對話（Codex 左邊欄也不列），回 nil。
    static func officialTitle(name: String?, title: String?, firstMessage: String?, preview: String?) -> String? {
        CoderImportCatalog.titleLine(name) ?? CoderImportCatalog.titleLine(title)
            ?? CoderImportCatalog.titleLine(firstMessage) ?? CoderImportCatalog.titleLine(preview)
    }

    /// 背景執行（exec、SDK、MCP、OS 聊天背後的 sidecar）不列。
    static func isBackground(source: String, originator: String) -> Bool {
        let origin = originator.lowercased()
        return source == "exec" || source == "mcp" || origin.contains("exec") || origin.contains("sdk") || origin.hasSuffix("-sidecar")
    }

    /// 子代理不列：thread_source＝subagent、source 是子代理的 JSON、有代理角色或暱稱、或在 thread_spawn_edges 裡是子。
    static func isSubagent(source: String, threadSource: String, agentRole: String?, agentNickname: String?, spawned: Bool) -> Bool {
        spawned || threadSource == "subagent" || source.hasPrefix("{") || !(agentRole ?? "").isEmpty || !(agentNickname ?? "").isEmpty
    }

    static func load(codexHome: URL) -> [CoderImportProject] {
        guard let database = stateDatabase(in: codexHome) else { return [] }
        let state = globalState(codexHome.appendingPathComponent(".codex-global-state.json"))
        var dbProjects: [[String: String]] = [], roots: [[String: String]] = [], threadRows: [[String: String]] = []
        var spawned = Set<String>()
        withReadOnlyDatabase(database) { db in
            dbProjects = rows(db, "SELECT * FROM projects")
            roots = rows(db, "SELECT * FROM project_roots ORDER BY position")
            threadRows = rows(db, "SELECT * FROM threads")
            spawned = Set(rows(db, "SELECT child_thread_id FROM thread_spawn_edges").compactMap { $0["child_thread_id"] })
        }

        // 舊的本機專案 id（local-…）對到資料庫的專案 id；只看這台自己的 Codex 家目錄。
        let hostKeys = ["local:" + codexHome.path, "local:" + codexHome.resolvingSymlinksInPath().path]
        let legacyMaps = (state["app-server-project-id-by-legacy-project-id-by-host"] as? [String: Any]) ?? [:]
        var legacy: [String: String] = [:]
        for (host, map) in legacyMaps where hostKeys.contains(host) || (host.hasPrefix("local:") && legacyMaps.count == 1) {
            for (old, new) in (map as? [String: Any]) ?? [:] { if let new = new as? String { legacy[old] = new } }
        }
        func unify(_ id: String) -> String { legacy[id] ?? id }

        struct Info { var name: String; var root: String; var position: Int }
        var projects: [String: Info] = [:]
        for row in dbProjects {
            guard let id = row["id"] else { continue }
            let root = roots.first { $0["project_id"] == id }?["path"] ?? ""
            projects[id] = Info(name: row["name"] ?? "", root: root, position: Int(row["position"] ?? "") ?? .max)
        }
        for (id, value) in (state["local-projects"] as? [String: Any]) ?? [:] {
            guard let entry = value as? [String: Any] else { continue }
            let key = unify(id)
            let root = (entry["rootPaths"] as? [String])?.first ?? ""
            if var known = projects[key] {
                if known.name.isEmpty { known.name = entry["name"] as? String ?? "" }
                if known.root.isEmpty { known.root = root }
                projects[key] = known
            } else {
                projects[key] = Info(name: entry["name"] as? String ?? "", root: root, position: .max)
            }
        }

        // 順序：釘選的在前，再照 Codex 的 project-order，其餘照資料庫的 position；別台（遠端）的專案不在這台，不列。
        let pinned = ((state["pinned-project-ids"] as? [String]) ?? []).map(unify)
        var order: [String] = []
        for id in pinned + ((state["project-order"] as? [String]) ?? []).map(unify) where projects[id] != nil && !order.contains(id) {
            order.append(id)
        }
        for id in projects.keys.sorted(by: { (projects[$0]!.position, $0) < (projects[$1]!.position, $1) }) where !order.contains(id) {
            order.append(id)
        }

        // 對話歸哪個專案：資料庫的 project_id → global state 的指派 → 明寫沒有專案 → 資料夾在哪個專案底下。
        let assignments = (state["thread-project-assignments"] as? [String: Any]) ?? [:]
        let projectless = Set((state["projectless-thread-ids"] as? [String]) ?? [])
        let hints = (state["thread-workspace-root-hints"] as? [String: Any]) ?? [:]
        func projectFor(_ row: [String: String], id: String) -> String? {
            if let direct = row["project_id"], !direct.isEmpty { return projects[unify(direct)] != nil ? unify(direct) : nil }
            if let assigned = assignments[id] as? [String: Any], (assigned["projectKind"] as? String ?? "local") == "local",
               let project = assigned["projectId"] as? String {
                return projects[unify(project)] != nil ? unify(project) : nil
            }
            if projectless.contains(id) { return nil }
            let path = CoderImport.normalized((hints[id] as? String) ?? row["cwd"] ?? "")
            guard !path.isEmpty else { return nil }
            return projects.filter { !$0.value.root.isEmpty }
                .map { (id: $0.key, root: CoderImport.normalized($0.value.root)) }
                .filter { path == $0.root || path.hasPrefix($0.root == "/" ? "/" : $0.root + "/") }
                .max { $0.root.count < $1.root.count }?.id
        }

        var buckets: [String?: [CoderImportConversation]] = [:]
        for row in threadRows {
            guard let id = row["id"], !id.isEmpty, (row["archived"] ?? "0") == "0",
                  !isBackground(source: row["source"] ?? "", originator: row["originator"] ?? ""),
                  !isSubagent(source: row["source"] ?? "", threadSource: row["thread_source"] ?? "",
                              agentRole: row["agent_role"], agentNickname: row["agent_nickname"], spawned: spawned.contains(id)) else { continue }
            let milliseconds = [row["recency_at_ms"], row["updated_at_ms"]].compactMap { Int64($0 ?? "") }.first { $0 > 0 }
                ?? (Int64(row["updated_at"] ?? "") ?? 0) * 1000
            let activity = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            guard let title = officialTitle(name: row["name"], title: row["title"], firstMessage: row["first_user_message"],
                                            preview: row["preview"]) else { continue }
            // 解開捷徑（~/.codex 可能是捷徑）：跟 E3 存進 importedFrom 的路徑一樣，「看原檔」與 Finder 都指到同一個檔。
            let path = (row["rollout_path"] ?? "").isEmpty ? "" : CoderImportCatalog.resolvedPath(row["rollout_path"] ?? "")
            let file = CoderImportCatalog.fileInfo(path)
            let session = CLITranscriptSession(url: URL(fileURLWithPath: path.isEmpty ? "/nonexistent-\(id)" : path), engine: .codex,
                                               origin: .native, sessionID: id, title: title, cwd: row["cwd"] ?? "",
                                               modifiedAt: file.modified ?? activity, bytes: file.bytes, isBatch: false)
            buckets[projectFor(row, id: id), default: []].append(.init(session: session, activity: activity, fileExists: file.exists))
        }

        var result = order.map { id -> CoderImportProject in
            let info = projects[id]!
            let folder = CoderImportCatalog.folderName(info.root, home: "")
            let name = !info.name.isEmpty ? info.name : folder.isEmpty ? "（沒有名字的專案）" : folder
            return CoderImportProject(id: "codex:" + id, engine: .codex, name: name, root: info.root, isPinned: pinned.contains(id),
                                      conversations: (buckets[id] ?? []).sorted { $0.activity > $1.activity })
        }
        if let loose = buckets[nil], !loose.isEmpty {
            // 匯入時放進一個 Coder 專案；資料夾用 Codex 自己記的工作根目錄（大多是它放「沒有專案的對話」的那個資料夾）。
            let root = projectlessRoot(hints: loose.compactMap { hints[$0.session.sessionID] as? String },
                                       folders: loose.map(\.session.cwd))
            result.append(CoderImportProject(id: "codex:none", engine: .codex, name: CoderImportCatalog.projectlessName, root: root,
                                             isProjectless: true, conversations: loose.sorted { $0.activity > $1.activity }))
        }
        return result
    }

    // MARK: 只讀

    /// 「沒有專案的對話」的資料夾：Codex 記的工作根目錄裡最多的那個；沒有就取各則資料夾共同的上層；都沒有回空字串。
    static func projectlessRoot(hints: [String], folders: [String]) -> String {
        let counted = Dictionary(grouping: hints.map(CoderImport.normalized).filter { $0.count > 1 }, by: { $0 })
        if let best = counted.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) })?.key { return best }
        let paths = folders.map(CoderImport.normalized).filter { $0.hasPrefix("/") && $0.count > 1 }
        guard var common = paths.first.map({ URL(fileURLWithPath: $0).pathComponents }) else { return "" }
        for path in paths.dropFirst() {
            let parts = URL(fileURLWithPath: path).pathComponents
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        guard common.count > 1 else { return "" }
        return NSString.path(withComponents: common)
    }

    private static func globalState(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// 唯讀開、查完立刻關；忙的時候最多等 0.2 秒，不跟 Codex 搶。
    /// Codex 開著時旁邊有 -wal／-shm，照 SQLite 的規矩當讀者（看得到還沒寫回主檔的新對話）；
    /// Codex 沒開、這兩個檔不在時唯讀開不起來，改用 immutable：不上鎖、不建 -wal／-shm，只讀主檔。
    private static func withReadOnlyDatabase(_ url: URL, _ body: (OpaquePointer) -> Void) {
        for target in [url.path, immutableURI(url)] {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | (target.hasPrefix("file:") ? SQLITE_OPEN_URI : 0)
            guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 200)
            // 開得起來不代表讀得到（唯讀讀者建不了 -shm 時第一次查詢才失敗）：先試一句，失敗就換 immutable。
            var probe: OpaquePointer?
            let readable = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &probe, nil) == SQLITE_OK
                && [SQLITE_ROW, SQLITE_DONE].contains(sqlite3_step(probe))
            sqlite3_finalize(probe)
            guard readable else { continue }
            body(db)
            return
        }
    }

    /// `file:` URI：路徑裡的空白、中文、? # % 都要編碼，否則會被當成參數。
    static func immutableURI(_ url: URL) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))
        return "file:" + (url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path) + "?mode=ro&immutable=1"
    }

    /// 每一列照欄名取成字串（整數轉字串、NULL 不放）；表不在或欄位改名時回空，不報錯。
    private static func rows(_ db: OpaquePointer, _ sql: String) -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, column) else { continue }
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: continue
                case SQLITE_INTEGER: row[String(cString: name)] = String(sqlite3_column_int64(statement, column))
                default:
                    if let text = sqlite3_column_text(statement, column) { row[String(cString: name)] = String(cString: text) }
                }
            }
            out.append(row)
        }
        return out
    }
}
