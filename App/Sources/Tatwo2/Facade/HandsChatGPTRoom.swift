import Foundation

/// Deliberately has no arguments, prompt, conversation, screenshot, or tool-result body fields.
struct HandsRoomCall: Codable, Identifiable, Sendable {
    let id: UUID
    let at: Date
    let projectID: UUID?
    let grantTag: String
    let tool: String
    let summary: String
    let workspaceID: UUID?
    let approval: String?
    var app: String? = nil
    var leaseMinutes: Int? = nil
    var requestID: UUID? = nil
}

extension HandsRoomCall {
    var summaryTitle: String {
        if ["computer_status", "computer_stop"].contains(tool), summary.hasPrefix("CU ") {
            let titles = ["pending": "等待核准", "allowed": "已核准", "denied": "已拒絕", "expired": "已失效"]
            return "操作畫面：" + (titles[String(summary.dropFirst(3))] ?? "狀態未知")
        }
        let workPrefix = tool == "job_status" ? "工作 " : tool == "job_cancel" ? "停工作：" : nil
        if let workPrefix, summary.hasPrefix(workPrefix) {
            let titles = ["running": "執行中", "exited": "已結束", "cancelled": "已取消", "timed_out": "已逾時", "failed": "啟動失敗"]
            return "工作：" + (titles[String(summary.dropFirst(workPrefix.count))] ?? "狀態未知")
        }
        if tool == "run_command" {
            let lines = summary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let status = String(lines.first ?? "")
            let title: String
            if status.hasPrefix("exit ") { title = "結束碼：" + status.dropFirst(5) }
            else if status.hasPrefix("killed by signal ") { title = "被訊號終止：" + status.dropFirst(17) }
            else if status.hasPrefix("timed out after ") { title = "執行逾時，已停止" }
            else if status == "cancelled" { title = "已取消" }
            else if status == "failed to start" { title = "啟動失敗" }
            else if status.hasPrefix("still running ") { title = "執行中" }
            else if status == "refused: resource limits could not be set" { title = "無法設定資源限制，已拒絕執行" }
            else { return summary }
            return title + (lines.count > 1 ? "\n" + lines[1] : "")
        }
        return summary
    }
    var toolTitle: String {
        switch tool {
        case "chatgpt_dispatch": "派給 ChatGPT"
        case "computer_request": "請求操作畫面"
        case "computer_status": "查看操作狀態"
        case "computer_stop": "停止操作畫面"
        case "computer_observe": "查看畫面"
        case "computer_action": "操作畫面"
        case "tatwo_status": "查看 TATWO 狀態"
        case "list_projects": "查看專案"
        case "list_workspaces": "查看工作區"
        case "read_file": "讀取檔案"
        case "list_dir": "查看資料夾"
        case "search": "搜尋檔案"
        case "git_status": "查看版本狀態"
        case "git_diff": "查看修改"
        case "memory_search": "搜尋記憶"
        case "memory_get": "讀取記憶"
        case "memory_inbox_save": "保存記憶提案"
        case "memory_inbox_list": "查看記憶提案"
        case "propose_goal": "提出目標"
        case "write_report": "撰寫報告"
        case "open_workspace": "開啟工作區"
        case "write_file", "edit_file", "apply_patch": "修改檔案"
        case "run_command", "job_start": "執行工作"
        case "job_status": "查看工作狀態"
        case "job_output": "讀取工作結果"
        case "job_cancel": "停止工作"
        case "submit_workspace": "提交工作區"
        case "skillet_list": "查看技能"
        case "skillet_read": "讀取技能"
        default: "工具操作"
        }
    }
    var approvalTitle: String? {
        switch approval {
        case "pending": "等待核准"
        case "allowed": "已核准"
        case "denied": "已拒絕"
        case "expired": "已失效"
        case nil: nil
        default: "狀態未知"
        }
    }
}

final class HandsRoomJournal: @unchecked Sendable {
    static let didChange = Notification.Name("HandsChatGPTRoomJournalChanged")
    private let lock = NSLock()
    static let retainedCount = 200
    let url: URL
    init(url: URL) { self.url = url }

    func rows(projectID: UUID?) -> [HandsRoomCall] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadRows(projectID: projectID).suffix(Self.retainedCount))
    }
    private func loadRows(projectID: UUID?) -> [HandsRoomCall] {
        let folder = directory(projectID)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { file -> HandsRoomCall? in
                guard let data = HandsFiles.readSecure(file, limit: 16 * 1024),
                      let row = try? JSONDecoder().decode(HandsRoomCall.self, from: data), row.projectID == projectID else { return nil }
                return row
            }.sorted { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
    }
    private func directory(_ projectID: UUID?) -> URL {
        url.deletingPathExtension().appendingPathComponent(projectID?.uuidString ?? "unclassified", isDirectory: true)
    }
    func append(_ row: HandsRoomCall) throws {
        lock.lock(); defer { lock.unlock() }
        let folder = directory(row.projectID)
        let archive = folder.appendingPathComponent("archive", isDirectory: true)
        try HandsFiles.ensureDirectory(url.deletingPathExtension())
        try HandsFiles.ensureDirectory(folder)
        try HandsFiles.ensureDirectory(archive)
        let name = row.id.uuidString + ".json"
        // A late completion updates its archived receipt without reviving old history.
        let archived = archive.appendingPathComponent(name)
        let destination = FileManager.default.fileExists(atPath: archived.path) ? archived : folder.appendingPathComponent(name)
        try HandsFiles.writeAtomically(try JSONEncoder().encode(row), to: destination)
        let rows = loadRows(projectID: row.projectID)
        for old in rows.prefix(max(0, rows.count - Self.retainedCount)) {
            let name = old.id.uuidString + ".json"
            // Move the original bytes; an archive failure leaves the source intact and fails the journal write.
            try FileManager.default.moveItem(at: folder.appendingPathComponent(name), to: archive.appendingPathComponent(name))
        }
        NotificationCenter.default.post(name: Self.didChange, object: url.path)
    }
}

struct HandsProjectLanding {
    let projectID: UUID?
    let workspaceID: UUID?
    let reminder: String?
}

extension HandsService {
    /// Add only App-resolved project metadata to an intentionally saved inbox note; not conversation data.
    func tagInbox(_ reply: [String: Any], projectID: UUID?) -> [String: Any] {
        guard let projectID, let id = reply["id"] as? String, !id.contains("/"), id.hasSuffix(".json") else { return reply }
        var result = reply
        result["project_id"] = projectID.uuidString
        do {
            try memoryStore.withLock {
                let file = inboxDirectory.appendingPathComponent(id)
                guard let data = HandsFiles.readSecure(file, limit: 64 * 1024),
                      var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw HandsToolError.invalid("inbox_metadata_unavailable")
                }
                object["project_id"] = projectID.uuidString
                try HandsFiles.writeAtomically(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: file)
            }
        } catch {
            result["warning"] = "Note saved; the project reference is in the ChatGPT room, but inbox metadata could not be updated."
        }
        return result
    }

    func inboxProjectTags(_ reply: [String: Any]) -> [String: Any] {
        var reply = reply
        reply["items"] = (reply["items"] as? [[String: Any]] ?? []).map { raw in
            var row = raw
            if let id = row["id"] as? String, !id.contains("/"), id.hasSuffix(".json"),
               let data = HandsFiles.readSecure(inboxDirectory.appendingPathComponent(id), limit: 64 * 1024),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawID = object["project_id"] as? String, let projectID = UUID(uuidString: rawID) {
                row["project_id"] = projectID.uuidString
            }
            return row
        }
        return reply
    }

    func landing(arguments: [String: Any], grant: HandsGrantAccess, settings: HandsSettings) throws -> HandsProjectLanding {
        var workspace = try (arguments["workspace_id"] as? String).map { try self.workspace($0, grant: grant, settings: settings) }
        if workspace == nil, let jobID = arguments["job_id"] as? String,
           let job = jobs.job(jobID, grant: grant.grantID) {
            workspace = try self.workspace(job.workspaceID.uuidString, grant: grant, settings: settings)
        }
        if let raw = arguments["project_id"] as? String {
            let projects = allowedProjects(grant, settings)
            guard let id = UUID(uuidString: raw), projects.contains(where: { $0.id == id }) else {
                throw HandsToolError.invalid("project_not_found: " + HandsTools.json(["choices": projects.map(\.name)]))
            }
            if let workspace, workspace.record.projectID != id { throw HandsToolError.invalid("project_workspace_mismatch") }
            return HandsProjectLanding(projectID: id, workspaceID: workspace?.id, reminder: nil)
        }
        if let workspace { return HandsProjectLanding(projectID: workspace.record.projectID, workspaceID: workspace.id, reminder: nil) }
        return HandsProjectLanding(projectID: nil, workspaceID: workspace?.id,
                                   reminder: "這次沒指定專案，已放到「ChatGPT · 未分類」；下次請帶 project_id（TATWO 專案的 ID）。")
    }

    @discardableResult
    func journal(tool: String, summary: String, landing: HandsProjectLanding, grant: String, approval: String? = nil,
                 app: String? = nil, minutes: Int? = nil, requestID: UUID? = nil, id: UUID = UUID(), at: Date = Date()) -> Bool {
        let safe = HandsRedactor.clip(HandsRedactor.redact(summary, context: redactionContext(workspace: nil)), limit: 900)
        do {
            try roomJournal.append(HandsRoomCall(id: id, at: at, projectID: landing.projectID,
                                                grantTag: String(grant.prefix(8)), tool: tool, summary: safe,
                                                workspaceID: landing.workspaceID, approval: approval,
                                                app: app, leaseMinutes: minutes, requestID: requestID))
            onMain { eventsHands(id: id, project: landing.projectID ?? self.engine?.doc.generalProjectID, thread: eventsHandsThread(self.engine, project: landing.projectID, workspace: landing.workspaceID), workspace: landing.workspaceID, tool: tool, at: at, root: self.runtime.environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) } ?? OSEventLog.liveRoot) }
            return true
        } catch {
            notify(title: "ChatGPT 房紀錄未存成", detail: "請檢查磁碟；尚未開始的工具不執行。")
            return false
        }
    }
}

/// Mapping is read-only and contains only the expected display name. Never traverse a symlink.
enum HandsTapMap {
    static func name(workdir: String) -> String? {
        TapProjectMapStore.displayMap(at: URL(fileURLWithPath: workdir).standardizedFileURL)?.name
    }
}
