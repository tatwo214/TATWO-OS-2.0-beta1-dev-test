import Foundation

// W180 E3b：助理提議專案分類（藍圖 O7）——提案佇列、搬移紀錄、純邏輯。
// 搬移＝改討論串屬於哪個專案（projectID），不建立、不搬、不改、不刪任何資料夾。
// 只能搬到「同一個資料夾」的專案，或新專案（沿用原本的資料夾）：引擎的對話紀錄跟著工作資料夾走
// （Claude 依資料夾存 session，換資料夾就 resume 不到），查證見 docs/specs/180-w179-followups/tasks.md 的 E3b 段。
// 未核准的提案不影響任何東西；核准後可復原；復原後變空的新專案封存（紀錄留在搬移紀錄裡），不刪。

// MARK: - 資料

/// 搬移紀錄裡的一條：哪條討論串、原本在哪個專案、搬到哪個專案。
struct ProjectMoveEntry: Codable, Equatable, Sendable {
    var threadID: UUID
    var from: UUID?
    var to: UUID
}

/// 提案裡的一則：這幾條主討論串（子討論串跟著走）→ 已有的專案，或新專案（名稱），附理由。
struct ProjectProposalItem: Codable, Equatable, Sendable {
    var threadIDs: [UUID]
    var targetProjectID: UUID?
    var newProjectName: String?
    var reason: String
}

struct ProjectProposal: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable { case pending, approved, rejected }
    var id: UUID
    var createdAt: Date
    /// 來源：助理的哪條對話（呼叫 project_suggest 的那條）。
    var sourceThreadID: UUID?
    var items: [ProjectProposalItem]
    var status: Status
    var decidedAt: Date?
}

/// 一次核准的搬移：每條討論串的原專案與新專案、提案 id、時間；復原時照這份搬回。
struct ProjectMoveRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var proposalID: UUID?
    var movedAt: Date
    var entries: [ProjectMoveEntry]
    /// 這次核准新建的專案（只加一筆專案紀錄，沒有建資料夾）。
    var createdProjects: [LiveProjectRecord]
    var undoneAt: Date?
    /// 復原後變空、從專案清單拿掉的新專案：整筆紀錄留在這裡，照原樣加回就還原（封存，不刪）。
    var archivedProjects: [LiveProjectRecord]
    /// 復原時跟著主串一起搬回的、核准後才開的子討論串或房間（from＝搬回的專案，to＝當時所在的新專案）。舊檔沒有＝nil。
    var laterEntries: [ProjectMoveEntry]? = nil
}

struct ProjectClassificationError: Error, CustomStringConvertible, Equatable {
    var code: String
    var reasons: [String] = []

    var description: String { reasons.isEmpty ? code : code + ": " + reasons.joined(separator: "；") }

    static let invalidParams = Self(code: "invalid_params")
    static let unavailable = Self(code: "unsupported_method")
    static let assistantOnly = Self(code: "project_suggest_assistant_only")
    static let tooManyPending = Self(code: "project_suggest_too_many_pending")
    static let notFound = Self(code: "proposal_not_found")
    static let notPending = Self(code: "proposal_not_pending")
    static let nothingToMove = Self(code: "proposal_nothing_to_move")
    static let nothingToUndo = Self(code: "nothing_to_undo")
    static let enginesCannotDecide = Self(code: "project_decide_not_for_engines")
    static let unreadable = Self(code: "classification_file_unreadable")
    static func rejected(_ reasons: [String]) -> Self { Self(code: "project_suggest_rejected", reasons: reasons) }
    static func blocked(_ reasons: [String]) -> Self { Self(code: "proposal_blocked", reasons: reasons) }
    static func undoBlocked(_ reasons: [String]) -> Self { Self(code: "undo_blocked", reasons: reasons) }
    static func invalid(_ reason: String) -> Self { Self(code: "invalid_params", reasons: [reason]) }
}

// MARK: - 檔案（live/project-proposals.json、live/project-moves.json）

/// 讀改寫都在同一把鎖裡（bridge 佇列與畫面各自建實例，鎖是共用的）。檔案讀不懂就丟錯、不覆蓋（壞檔留給人看）。
final class ProjectClassificationStore: @unchecked Sendable {
    static let proposalsFile = "project-proposals.json"
    static let movesFile = "project-moves.json"
    static let didChange = Notification.Name("ai.tatwo.tatwo2.project-classification.changed")
    private static let lock = NSLock()

    let root: URL
    init(root: URL) { self.root = root }

    private struct ProposalFile: Codable { var version = 1; var proposals: [ProjectProposal] = [] }
    private struct MoveFile: Codable { var version = 1; var moves: [ProjectMoveRecord] = [] }

    /// 讀不到（沒有檔、壞檔）都當空的；要改之前用 update，壞檔會丟錯。
    func proposals() -> [ProjectProposal] { (try? readProposals()) ?? [] }
    func moves() -> [ProjectMoveRecord] { (try? readMoves()) ?? [] }

    func readProposals() throws -> [ProjectProposal] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read(ProposalFile.self, Self.proposalsFile)?.proposals ?? []
    }

    func readMoves() throws -> [ProjectMoveRecord] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read(MoveFile.self, Self.movesFile)?.moves ?? []
    }

    @discardableResult
    func updateProposals<T>(_ body: (inout [ProjectProposal]) throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var file = try read(ProposalFile.self, Self.proposalsFile) ?? ProposalFile()
        let result = try body(&file.proposals)
        try write(file, Self.proposalsFile)
        notify()
        return result
    }

    @discardableResult
    func updateMoves<T>(_ body: (inout [ProjectMoveRecord]) throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var file = try read(MoveFile.self, Self.movesFile) ?? MoveFile()
        let result = try body(&file.moves)
        try write(file, Self.movesFile)
        notify()
        return result
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: Data(contentsOf: url)) }
        catch { throw ProjectClassificationError.unreadable }
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

// MARK: - 畫面用的卡片（本機直接算；副設備從 overview_snapshot 解析，同一個形狀）

struct ProjectProposalCard: Identifiable, Equatable, Sendable {
    struct Thread: Identifiable, Equatable, Sendable {
        var id: UUID
        var title: String
    }

    struct Item: Equatable, Sendable {
        var reason: String
        var targetName: String
        var isNewProject: Bool
        var threads: [Thread]
    }

    var id: UUID
    var status: ProjectProposal.Status
    var createdAt: Date
    var items: [Item]
    /// 現在不能核准的原因（空＝可以核准）。
    var blocked: [String]
    var movedAt: Date?
    var undoneAt: Date?
    var canUndo: Bool

    var threadCount: Int { items.reduce(0) { $0 + $1.threads.count } }
    var isPending: Bool { status == .pending }
    var targetSummary: String {
        let names = items.map { $0.isNewProject ? "新專案：\($0.targetName)" : $0.targetName }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique.joined(separator: "、")
    }
}

// MARK: - 純邏輯

enum ProjectClassification {
    static let maxThreads = 30
    static let maxItems = 10
    static let maxPending = 20
    static let reasonLimit = 300
    static let nameLimit = 60
    static let overviewLimit = 500
    static let recentMoves = 10
    /// 卡片上的說明（為什麼只能搬到同一個資料夾的專案或新專案）。
    static let ruleLine = "只改對話屬於哪個專案，不動任何資料夾；只能搬到同一個資料夾的專案或新專案，原本的對話才接得回。"
    /// 「請助理整理分類」送給助理的固定一句。
    static let assistantRequest = "幫我整理專案：看看最近的對話各屬於哪個專案、要不要開新專案，用 project_suggest 提給我核准。"

    struct Problem: Equatable, Sendable {
        var code: String
        var text: String
    }

    struct Plan {
        var newProjects: [LiveProjectRecord]
        var moves: [(thread: UUID, project: UUID)]
    }

    /// 這條與底下所有子討論串（含子的子）。
    static func subtree(of root: UUID, in threads: [LiveThreadRecord]) -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for thread in threads { if let parent = thread.parentThreadID { children[parent, default: []].append(thread.id) } }
        var result: Set<UUID> = [root]
        var queue = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where result.insert(child).inserted { queue.append(child) }
        }
        return result
    }

    /// 同一個資料夾＝標準化後的路徑相同（不解析捷徑：對不上就當不同，寧可擋）。
    static func folderKey(_ workdir: String) -> String {
        let path = URL(fileURLWithPath: (workdir as NSString).expandingTildeInPath).standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// 在跑：引擎回報在跑，或房間狀態是 running（同專案地圖）。
    static func isRunning(_ thread: LiveThreadRecord, running: Set<UUID>) -> Bool {
        running.contains(thread.id) || thread.subStatus == "running"
    }

    private static func quoted(_ title: String) -> String { "「\(String(title.prefix(40)))」" }

    /// 照現在的文件檢查一份提案：能搬就回計畫；不能就回原因（白話）。不改任何東西。
    static func plan(_ items: [ProjectProposalItem], doc: LiveDocumentRecord, running: Set<UUID>) -> (plan: Plan?, problems: [Problem]) {
        let threads = Dictionary(doc.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = Dictionary(doc.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = AssistantOverview.projectNames(doc)
        var problems: [Problem] = []
        func problem(_ code: String, _ text: String) {
            let entry = Problem(code: code, text: text)
            if !problems.contains(entry) { problems.append(entry) }
        }
        var created: [String: (folder: String, project: LiveProjectRecord)] = [:]
        var moves: [(thread: UUID, project: UUID)] = []
        var seen = Set<UUID>()
        for item in items {
            var targetID: UUID?
            var targetFolder: String?
            var targetName = ""
            var newKey: String?
            if let id = item.targetProjectID {
                guard let project = projects[id], id != doc.assistantProjectID else {
                    problem("target_missing", "目標專案已經不在了")
                    continue
                }
                targetID = id; targetFolder = folderKey(project.workdir); targetName = names[id] ?? project.name
            } else if let name = item.newProjectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if doc.projects.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
                    problem("name_taken", "已經有叫「\(name)」的專案，請直接搬進去")
                    continue
                }
                newKey = name.lowercased(); targetName = name
            } else {
                problem("target_missing", "沒有寫要搬到哪個專案")
                continue
            }
            for id in item.threadIDs {
                guard seen.insert(id).inserted else { problem("duplicate", "同一條對話提了兩次"); continue }
                guard let thread = threads[id] else { problem("thread_missing", "有一條對話已經不在了"); continue }
                let title = quoted(thread.title)
                if thread.projectID == doc.assistantProjectID { problem("assistant", "助理自己的對話不搬"); continue }
                if thread.isArchived { problem("archived", "\(title)已經封存"); continue }
                if thread.parentThreadID != nil { problem("sub_thread", "\(title)是子討論串，會跟著主串一起搬；請提主串"); continue }
                if thread.botPermissionPreset != nil { problem("bot", "\(title)是 Bot 的對話，先不搬"); continue }
                let family = subtree(of: id, in: doc.threads)
                if family.contains(where: { threads[$0].map { isRunning($0, running: running) } ?? false }) {
                    problem("running", "\(title)正在跑，跑完再搬")
                }
                // 這條與子討論串現在的專案都要在同一個資料夾（子討論串原本就跟著母串的專案）。
                let folders = Set(family.map { member -> String in
                    guard let projectID = threads[member]?.projectID, let project = projects[projectID] else { return "" }
                    return folderKey(project.workdir)
                })
                guard folders.count == 1, let folder = folders.first, !folder.isEmpty,
                      let current = thread.projectID.flatMap({ projects[$0] }) else {
                    problem("folder_unknown", "\(title)找不到原本的專案資料夾")
                    continue
                }
                if let targetID, let targetFolder {
                    if thread.projectID == targetID { problem("already_there", "\(title)已經在「\(targetName)」"); continue }
                    if folder != targetFolder {
                        problem("other_folder", "\(title)原本在另一個資料夾工作，搬到「\(targetName)」後接不回原本的對話；可以改成新專案")
                        continue
                    }
                    moves.append((id, targetID))
                } else if let newKey {
                    if let existing = created[newKey] {
                        guard existing.folder == folder else {
                            problem("mixed_folders", "要放進新專案「\(targetName)」的對話原本在不同資料夾，接不回原本的對話")
                            continue
                        }
                        moves.append((id, existing.project.id))
                    } else {
                        // 新專案沿用原本的資料夾（只加一筆專案紀錄，不建資料夾）。
                        let project = LiveProjectRecord(name: String(targetName.prefix(nameLimit)), workdir: current.workdir)
                        created[newKey] = (folder, project)
                        moves.append((id, project.id))
                    }
                }
            }
        }
        if moves.isEmpty && problems.isEmpty { problem("empty", "沒有要搬的對話") }
        guard problems.isEmpty else { return (nil, problems) }
        let newProjects = created.values.map { $0.project }.sorted { $0.name < $1.name }
        return (Plan(newProjects: newProjects, moves: moves), [])
    }

    // MARK: 助理工具：project_overview（唯讀，只有標題、最後活動、訊息數）

    static func overview(doc: LiveDocumentRecord, running: Set<UUID>) -> [String: Any] {
        let names = AssistantOverview.projectNames(doc)
        let dates = ISO8601DateFormatter()
        var folders: [String: Int] = [:]
        let projectRows: [[String: Any]] = doc.projects.filter { $0.id != doc.assistantProjectID }.map { project -> [String: Any] in
            let key = folderKey(project.workdir)
            let group: Int
            if let known = folders[key] { group = known } else { group = folders.count + 1; folders[key] = group }
            let count = doc.threads.filter { $0.projectID == project.id && $0.parentThreadID == nil && !$0.isArchived }.count
            return ["projectID": project.id.uuidString, "name": names[project.id] ?? String(project.name.prefix(200)),
                    "folderGroup": group, "isGeneral": project.id == doc.generalProjectID, "threadCount": count]
        }
        var subCounts: [UUID: Int] = [:]
        for thread in doc.threads where thread.parentThreadID != nil && !thread.isArchived {
            if let parent = thread.parentThreadID { subCounts[parent, default: 0] += 1 }
        }
        let roots = doc.threads.filter {
            $0.parentThreadID == nil && !$0.isArchived && $0.projectID != nil && $0.projectID != doc.assistantProjectID
                && $0.botPermissionPreset == nil
        }.sorted { $0.updatedAt > $1.updatedAt }
        let threadRows: [[String: Any]] = roots.prefix(overviewLimit).map { thread -> [String: Any] in
            ["threadID": thread.id.uuidString, "title": String(thread.title.prefix(200)),
             "projectID": thread.projectID?.uuidString ?? "",
             "lastActivity": dates.string(from: thread.updatedAt),
             // 只數有幾則，不讀內容。
             "messageCount": thread.messages.lazy.filter { $0.eventKind == "message" }.count,
             "subThreadCount": subCounts[thread.id] ?? 0,
             "running": isRunning(thread, running: running)]
        }
        return ["projects": projectRows, "threads": threadRows, "truncated": roots.count > overviewLimit,
                "rule": "只能搬到同一個 folderGroup 的專案，或提新專案（沿用原本的資料夾）；只提主串，子討論串會跟著走；你只能提議，使用者核准才搬。"]
    }

    // MARK: 助理工具：project_suggest（只建立提案）

    static func parseItems(_ params: [String: Any]) throws -> [ProjectProposalItem] {
        guard Set(params.keys).isSubset(of: ["callerThreadID", "items"]),
              let rows = params["items"] as? [[String: Any]], !rows.isEmpty else {
            throw ProjectClassificationError.invalid("items 要是至少一則項目的陣列")
        }
        guard rows.count <= maxItems else { throw ProjectClassificationError.invalid("一次最多 \(maxItems) 則項目") }
        var total = 0
        let items = try rows.map { row -> ProjectProposalItem in
            guard Set(row.keys).isSubset(of: ["threadIDs", "targetProjectID", "newProjectName", "reason"]),
                  let raw = row["threadIDs"] as? [String], !raw.isEmpty else {
                throw ProjectClassificationError.invalid("每則項目要有 threadIDs")
            }
            let ids = try raw.map { text -> UUID in
                guard let id = UUID(uuidString: text) else { throw ProjectClassificationError.invalid("threadIDs 要是討論串 id") }
                return id
            }
            total += ids.count
            let reason = (row["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reason.isEmpty, reason.count <= reasonLimit else {
                throw ProjectClassificationError.invalid("每則項目都要寫理由（最多 \(reasonLimit) 字）")
            }
            var target: UUID?
            if let value = row["targetProjectID"] {
                guard let text = value as? String, let id = UUID(uuidString: text) else {
                    throw ProjectClassificationError.invalid("targetProjectID 要是專案 id")
                }
                target = id
            }
            var name: String?
            if let value = row["newProjectName"] {
                guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      text.count <= nameLimit, !text.contains(where: { $0.isNewline }),
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ProjectClassificationError.invalid("newProjectName 要是一行、最多 \(nameLimit) 字")
                }
                name = text
            }
            guard (target == nil) != (name == nil) else {
                throw ProjectClassificationError.invalid("每則項目二選一：targetProjectID 或 newProjectName")
            }
            return ProjectProposalItem(threadIDs: ids, targetProjectID: target, newProjectName: name, reason: reason)
        }
        guard total <= maxThreads else { throw ProjectClassificationError.invalid("一份提案最多 \(maxThreads) 條討論串") }
        return items
    }

    /// 只有助理的對話能提（來源＝那條）；在跑的只擋核准、不擋提議。寫進佇列就結束，什麼都不搬。
    static func suggest(params: [String: Any], caller: UUID?, doc: LiveDocumentRecord, running: Set<UUID>,
                        store: ProjectClassificationStore, now: Date = Date()) throws -> [String: Any] {
        guard let caller, let assistantProjectID = doc.assistantProjectID,
              doc.threads.contains(where: { $0.id == caller && $0.projectID == assistantProjectID }) else {
            throw ProjectClassificationError.assistantOnly
        }
        let items = try parseItems(params)
        let problems = plan(items, doc: doc, running: running).problems.filter { $0.code != "running" }
        guard problems.isEmpty else { throw ProjectClassificationError.rejected(problems.map(\.text)) }
        let proposal = ProjectProposal(id: UUID(), createdAt: now, sourceThreadID: caller, items: items,
                                       status: .pending, decidedAt: nil)
        try store.updateProposals { list in
            guard list.filter({ $0.status == .pending }).count < maxPending else {
                throw ProjectClassificationError.tooManyPending
            }
            list.append(proposal)
        }
        return ["proposalID": proposal.id.uuidString, "status": "pending",
                "hint": "已放進 TATWO › 專案地圖的「分類建議」；使用者按「核准搬移」才會搬，你不能自己搬。"]
    }

    // MARK: 卡片

    static func cards(store: ProjectClassificationStore, doc: LiveDocumentRecord, running: Set<UUID>) -> [ProjectProposalCard] {
        cards(proposals: store.proposals(), moves: store.moves(), doc: doc, running: running)
    }

    /// 待決的提案（新到舊）＋最近核准的搬移（新到舊，最多 10 則）。
    static func cards(proposals: [ProjectProposal], moves: [ProjectMoveRecord], doc: LiveDocumentRecord,
                      running: Set<UUID>) -> [ProjectProposalCard] {
        let titles = Dictionary(doc.threads.map { ($0.id, String($0.title.prefix(200))) }, uniquingKeysWith: { first, _ in first })
        let names = AssistantOverview.projectNames(doc)
        func items(_ proposal: ProjectProposal) -> [ProjectProposalCard.Item] {
            proposal.items.map { item -> ProjectProposalCard.Item in
                let target = item.newProjectName ?? item.targetProjectID.flatMap { names[$0] } ?? "（專案已不在）"
                return ProjectProposalCard.Item(
                    reason: String(item.reason.prefix(reasonLimit)), targetName: String(target.prefix(200)),
                    isNewProject: item.newProjectName != nil,
                    threads: item.threadIDs.map { ProjectProposalCard.Thread(id: $0, title: titles[$0] ?? "（對話已不在）") })
            }
        }
        let pending = proposals.filter { $0.status == .pending }.sorted { $0.createdAt > $1.createdAt }.prefix(maxPending)
            .map { proposal -> ProjectProposalCard in
                ProjectProposalCard(id: proposal.id, status: .pending, createdAt: proposal.createdAt, items: items(proposal),
                                    blocked: plan(proposal.items, doc: doc, running: running).problems.map(\.text),
                                    movedAt: nil, undoneAt: nil, canUndo: false)
            }
        let byID = Dictionary(proposals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let shown = moves.sorted { $0.movedAt > $1.movedAt }.compactMap { record -> (ProjectMoveRecord, ProjectProposal)? in
            guard let id = record.proposalID, let proposal = byID[id], seen.insert(id).inserted else { return nil }
            return (record, proposal)
        }.prefix(recentMoves)
        let recent = shown.map { pair -> ProjectProposalCard in
            let (record, proposal) = pair
            let undoBlocked = undoBlockers(record, moves: moves, doc: doc, running: running)
            return ProjectProposalCard(id: proposal.id, status: proposal.status, createdAt: proposal.createdAt, items: items(proposal),
                                       blocked: undoBlocked, movedAt: record.movedAt, undoneAt: record.undoneAt,
                                       canUndo: record.undoneAt == nil && undoBlocked.isEmpty)
        }
        return Array(pending) + recent
    }

    /// 復原照「後進先出」：這筆之後還沒復原的搬移動到同一家對話（含子討論串），或動到這筆新建的專案，就先擋，
    /// 要先復原較晚那次（反序復原會讓新專案先被封存、對話回不到原本的專案）。這家對話有正在跑的也擋（同核准）；
    /// 原本的專案不在了也擋。回傳白話原因；空＝可以復原（已復原的回空）。`moves` 要照檔案裡的順序（新的在後）。
    static func undoBlockers(_ record: ProjectMoveRecord, moves: [ProjectMoveRecord], doc: LiveDocumentRecord,
                             running: Set<UUID>) -> [String] {
        guard record.undoneAt == nil else { return [] }
        let threads = Dictionary(doc.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectIDs = Set(doc.projects.map(\.id))
        var family = Set<UUID>()
        for entry in record.entries { family.formUnion(subtree(of: entry.threadID, in: doc.threads)) }
        let created = Set(record.createdProjects.map(\.id))
        var reasons: [String] = []
        func add(_ text: String) { if !reasons.contains(text) { reasons.append(text) } }
        func title(_ id: UUID) -> String { quoted(threads[id]?.title ?? "對話") }
        if let position = moves.firstIndex(where: { $0.id == record.id }) {
            for later in moves[moves.index(after: position)...] where later.undoneAt == nil {
                let touched = later.entries + (later.laterEntries ?? [])
                if let hit = touched.first(where: { family.contains($0.threadID) }) {
                    add("\(title(hit.threadID))後來又搬過一次，請先復原較晚那次")
                } else if touched.contains(where: { move in created.contains(move.to) || move.from.map { created.contains($0) } == true }) {
                    add("後來又有對話搬進或搬出這次新建的專案，請先復原較晚那次")
                }
            }
        }
        for entry in record.entries where threads[entry.threadID]?.projectID == entry.to
            && !(entry.from.map { projectIDs.contains($0) } ?? false) {
            add("\(title(entry.threadID))原本的專案已經不在了，沒辦法搬回")
        }
        if let busy = doc.threads.first(where: { family.contains($0.id) && isRunning($0, running: running) }) {
            add("\(title(busy.id))正在跑，跑完再復原")
        }
        return reasons
    }
}

// MARK: - 動作（主執行緒；本機畫面直接呼叫，副設備經 project_proposal_decide）

extension ProjectClassification {
    @MainActor static func store(for engine: ChatLiveEngine) -> ProjectClassificationStore {
        ProjectClassificationStore(root: engine.store.url.deletingLastPathComponent())
    }

    @MainActor static func running(_ engine: ChatLiveEngine) -> Set<UUID> {
        Set(engine.doc.threads.filter { engine.isRunning($0.id) }.map(\.id))
    }

    /// 核准：照現在的文件再檢查一次；能搬才搬（一次存檔），再寫搬移紀錄與提案狀態。紀錄寫不進去就照原樣搬回。
    @MainActor @discardableResult
    static func approve(_ id: UUID, engine: ChatLiveEngine, now: Date = Date()) throws -> ProjectMoveRecord {
        let files = Self.store(for: engine)
        guard let proposal = try files.readProposals().first(where: { $0.id == id }) else { throw ProjectClassificationError.notFound }
        guard proposal.status == .pending else { throw ProjectClassificationError.notPending }
        let result = Self.plan(proposal.items, doc: engine.doc, running: Self.running(engine))
        guard let moving = result.plan, result.problems.isEmpty else {
            throw ProjectClassificationError.blocked(result.problems.map(\.text))
        }
        let entries = try engine.moveThreads(moving.moves, creating: moving.newProjects)
        guard !entries.isEmpty else { throw ProjectClassificationError.nothingToMove }
        let created = moving.newProjects.filter { project in entries.contains { $0.to == project.id } }
        let record = ProjectMoveRecord(id: UUID(), proposalID: id, movedAt: now, entries: entries,
                                       createdProjects: created, undoneAt: nil, archivedProjects: [])
        var recorded = false
        do {
            try files.updateMoves { $0.append(record) }
            recorded = true
            try files.updateProposals { list in
                guard let index = list.firstIndex(where: { $0.id == id }), list[index].status == .pending else {
                    throw ProjectClassificationError.notPending
                }
                list[index].status = .approved
                list[index].decidedAt = now
            }
        } catch {
            let restored = try? engine.restoreThreadProjects(entries, archivingEmpty: created.map(\.id))
            if recorded {
                try? files.updateMoves { moves in
                    guard let index = moves.firstIndex(where: { $0.id == record.id }) else { return }
                    moves[index].undoneAt = now
                    moves[index].archivedProjects = restored?.archived ?? []
                }
            }
            throw error
        }
        return record
    }

    @MainActor static func reject(_ id: UUID, engine: ChatLiveEngine, now: Date = Date()) throws {
        try Self.store(for: engine).updateProposals { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { throw ProjectClassificationError.notFound }
            guard list[index].status == .pending else { throw ProjectClassificationError.notPending }
            list[index].status = .rejected
            list[index].decidedAt = now
        }
    }

    /// 復原：照紀錄把還在新專案的那幾條搬回原專案，核准後才在底下開的子討論串、房間一起回去；
    /// 這次新建的專案變空就封存（紀錄留著），不刪。要照後進先出（`undoBlockers`），擋下時什麼都不動。
    @MainActor @discardableResult
    static func undo(_ proposalID: UUID, engine: ChatLiveEngine, now: Date = Date()) throws -> ProjectMoveRecord {
        let files = Self.store(for: engine)
        let moves = try files.readMoves()
        guard var record = moves.last(where: { $0.proposalID == proposalID && $0.undoneAt == nil }) else {
            throw ProjectClassificationError.nothingToUndo
        }
        let blockers = undoBlockers(record, moves: moves, doc: engine.doc, running: Self.running(engine))
        guard blockers.isEmpty else { throw ProjectClassificationError.undoBlocked(blockers) }
        let restored = try engine.restoreThreadProjects(record.entries, archivingEmpty: record.createdProjects.map(\.id))
        record.undoneAt = now
        record.archivedProjects = restored.archived
        if !restored.later.isEmpty { record.laterEntries = restored.later }
        let final = record
        try files.updateMoves { moves in
            guard let index = moves.firstIndex(where: { $0.id == final.id }) else { return }
            moves[index] = final
        }
        return record
    }

    /// project_proposal_decide（副設備經 SSH）：只收提案 id＋approve／reject／undo，搬移由這台自己照提案做。
    /// 引擎（綁定對話的呼叫者）不能決定：只有使用者能核准。
    @MainActor static func decide(params: [String: Any], boundThread: UUID?, engine: ChatLiveEngine) throws -> [String: Any] {
        guard boundThread == nil else { throw ProjectClassificationError.enginesCannotDecide }
        guard Set(params.keys).isSubset(of: ["id", "action", "callerThreadID"]),
              let raw = params["id"] as? String, let id = UUID(uuidString: raw),
              let action = params["action"] as? String else { throw ProjectClassificationError.invalidParams }
        switch action {
        case "approve":
            let record = try approve(id, engine: engine)
            return ["id": id.uuidString, "status": "approved", "moved": record.entries.count]
        case "reject":
            try reject(id, engine: engine)
            return ["id": id.uuidString, "status": "rejected"]
        case "undo":
            let record = try undo(id, engine: engine)
            return ["id": id.uuidString, "status": "undone", "archivedProjects": record.archivedProjects.count]
        default:
            throw ProjectClassificationError.invalidParams
        }
    }

    /// 畫面上的白話（本機與副設備共用；remoteName＝決定是送到哪一台）。
    static func userMessage(code: String, reasons: [String] = [], remoteName: String? = nil) -> String {
        switch code {
        case "proposal_blocked": return "現在不能搬：" + reasons.joined(separator: "；")
        case "undo_blocked": return "現在不能復原：" + reasons.joined(separator: "；")
        case "proposal_not_pending": return "這則建議已經處理過了。"
        case "proposal_not_found": return "找不到這則建議（可能已經處理過）。"
        case "proposal_nothing_to_move": return "沒有要搬的對話。"
        case "nothing_to_undo": return "沒有可以復原的搬移。"
        case "classification_file_unreadable": return "分類紀錄檔讀不懂，沒有改任何東西；請先檢查 live 資料夾裡的檔案。"
        case "unsupported_method", "caller_not_trusted":
            return remoteName.map { "\($0) 還沒更新，更新後才能在這台決定。" } ?? "這台還不支援。"
        default:
            return remoteName.map { "沒有送到 \($0)，等一下再試。" } ?? "沒有做成（\(code)）。"
        }
    }
}

// MARK: - overview_snapshot 多回的白名單欄位（提案 id、討論串標題、目標名、理由；沒有路徑、訊息）

enum ProjectClassificationWire {
    static let key = "projectProposals"
    static let limit = 40

    static let allowedKeys: Set<String> = [
        "projectProposals", "id", "status", "createdAt", "items", "reason", "targetName", "isNewProject",
        "threads", "threadID", "title", "blocked", "movedAt", "undoneAt", "canUndo",
    ]

    static func rows(_ cards: [ProjectProposalCard]) -> [[String: Any]] {
        let dates = ISO8601DateFormatter()
        return cards.prefix(limit).map { card -> [String: Any] in
            ["id": card.id.uuidString, "status": card.status.rawValue, "createdAt": dates.string(from: card.createdAt),
             "items": card.items.map { item -> [String: Any] in
                 ["reason": item.reason, "targetName": item.targetName, "isNewProject": item.isNewProject,
                  "threads": item.threads.map { thread -> [String: Any] in ["threadID": thread.id.uuidString, "title": thread.title] }]
             },
             "blocked": card.blocked,
             "movedAt": card.movedAt.map { dates.string(from: $0) as Any } ?? NSNull(),
             "undoneAt": card.undoneAt.map { dates.string(from: $0) as Any } ?? NSNull(),
             "canUndo": card.canUndo]
        }
    }

    /// 對方沒有這一組（舊版）＝nil；逐列照白名單解析，缺欄位的列不收。
    static func cards(_ snapshot: [String: Any]) -> [ProjectProposalCard]? {
        guard let rows = snapshot[key] as? [[String: Any]] else { return nil }
        let dates = ISO8601DateFormatter()
        return rows.prefix(limit).compactMap { row -> ProjectProposalCard? in
            guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let status = (row["status"] as? String).flatMap(ProjectProposal.Status.init(rawValue:)),
                  let createdAt = (row["createdAt"] as? String).flatMap(dates.date(from:)),
                  let itemRows = row["items"] as? [[String: Any]] else { return nil }
            let items = itemRows.prefix(ProjectClassification.maxItems).compactMap { item -> ProjectProposalCard.Item? in
                guard let reason = item["reason"] as? String, let target = item["targetName"] as? String,
                      let isNew = item["isNewProject"] as? Bool, let threads = item["threads"] as? [[String: Any]] else { return nil }
                let threadList = threads.prefix(ProjectClassification.maxThreads).compactMap { thread -> ProjectProposalCard.Thread? in
                    guard let threadID = (thread["threadID"] as? String).flatMap(UUID.init(uuidString:)),
                          let title = thread["title"] as? String else { return nil }
                    return ProjectProposalCard.Thread(id: threadID, title: String(title.prefix(200)))
                }
                return ProjectProposalCard.Item(reason: String(reason.prefix(ProjectClassification.reasonLimit)),
                                                targetName: String(target.prefix(200)), isNewProject: isNew, threads: threadList)
            }
            return ProjectProposalCard(
                id: id, status: status, createdAt: createdAt, items: items,
                blocked: (row["blocked"] as? [String] ?? []).prefix(20).map { String($0.prefix(300)) },
                movedAt: (row["movedAt"] as? String).flatMap(dates.date(from:)),
                undoneAt: (row["undoneAt"] as? String).flatMap(dates.date(from:)),
                canUndo: row["canUndo"] as? Bool ?? false)
        }
    }
}
