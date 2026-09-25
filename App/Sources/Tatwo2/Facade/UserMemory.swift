import Foundation

/// W163 使用者記憶管道（憲法 v4.1 §0 ③：AI 只能提案，使用者核准才寫入 user.md）。
/// - 提案排隊在主設備（入口 memory-proposals.json，不進 git、不派發）。
/// - 任一台都能提、能看、能核准：副設備經已簽章的設備通道轉給主設備；連不上就先放本機待送，下次再送。
/// - 核准＝主設備把那一句加進 user.md 的「最近記住」，走 OSDocuments 的存檔（備份、記版本、派發到各台）。
struct UserMemoryProposal: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var isPublic: Bool
    var source: String
    var createdAt: Date
    var status: String          // pending / accepted / rejected
    var decidedAt: Date?
}

final class UserMemoryStore: @unchecked Sendable {
    static let shared = UserMemoryStore(dispatch: .shared)
    enum Outcome: String { case pending, queued, duplicate }

    private let dispatch: DeviceDispatch
    private let lock = NSRecursiveLock()
    init(dispatch: DeviceDispatch) { self.dispatch = dispatch }

    var isPrimary: Bool { (try? dispatch.identity().role) == .primary }
    private var queueURL: URL { dispatch.entry.root.appendingPathComponent("memory-proposals.json") }
    private var outboxURL: URL { dispatch.root.appendingPathComponent("memory-outbox.json") }

    // MARK: 提案

    @discardableResult
    func propose(text: String, isPublic: Bool = false, source: String) throws -> Outcome {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= 400 else { throw DeviceDispatch.Failure(reason: "invalid_memory_text") }
        let device = (try? dispatch.identity().name) ?? "本機"
        let proposal = UserMemoryProposal(id: UUID().uuidString, text: body, isPublic: isPublic,
                                          source: "\(source)・\(device)", createdAt: Date(), status: "pending")
        if isPrimary { return try receive(proposal) }
        flushOutbox()
        do { return try send(proposal) }
        catch {
            lock.lock(); defer { lock.unlock() }
            var rows = read(outboxURL); rows.append(proposal); try write(rows, to: outboxURL)
            return .queued
        }
    }

    /// 主設備收一條提案：user.md 已有、或已在排隊的同一句，都不重複收。
    func receive(_ proposal: UserMemoryProposal) throws -> Outcome {
        lock.lock(); defer { lock.unlock() }
        guard isPrimary else { throw DeviceDispatch.Failure(reason: "not_primary") }
        let user = (try? OSDocuments.read(id: "user")) ?? ""
        var rows = read(queueURL)
        let key = UserMemoryText.normalized(proposal.text)
        if UserMemoryText.contains(proposal.text, in: user)
            || rows.contains(where: { $0.status == "pending" && UserMemoryText.normalized($0.text) == key }) { return .duplicate }
        rows.append(proposal)
        try write(rows, to: queueURL)
        return .pending
    }

    private func send(_ proposal: UserMemoryProposal) throws -> Outcome {
        let response = try dispatch.callPrimary(method: "memory_propose", payload: DeviceDispatch.object(proposal))
        return Outcome(rawValue: response["status"] as? String ?? "") ?? .pending
    }

    /// 副設備把連不上時先存的提案送出去；送成功一條刪一條。
    func flushOutbox() {
        guard !isPrimary else { return }
        lock.lock(); defer { lock.unlock() }
        var rows = read(outboxURL)
        guard !rows.isEmpty else { return }
        rows.removeAll { (try? send($0)) != nil }
        try? write(rows, to: outboxURL)
    }

    // MARK: 看與核准

    /// 主設備讀自己的排隊；副設備問主設備，連不上就只給本機待送的。
    func list() -> (items: [UserMemoryProposal], offline: Bool) {
        if isPrimary {
            lock.lock(); defer { lock.unlock() }
            return (read(queueURL).sorted { $0.createdAt > $1.createdAt }, false)
        }
        flushOutbox()
        if let response = try? dispatch.callPrimary(method: "memory_list", payload: [:]),
           let raw = response["items"] as? [[String: Any]] {
            return (raw.compactMap { try? DeviceDispatch.decode(UserMemoryProposal.self, $0) }, false)
        }
        lock.lock(); defer { lock.unlock() }
        return (read(outboxURL), true)
    }

    func decide(id: String, accept: Bool, isPublic: Bool) throws {
        guard isPrimary else {
            _ = try dispatch.callPrimary(method: "memory_decide", payload: ["id": id, "accept": accept, "isPublic": isPublic])
            return
        }
        lock.lock(); defer { lock.unlock() }
        var rows = read(queueURL)
        guard let index = rows.firstIndex(where: { $0.id == id && $0.status == "pending" }) else {
            throw DeviceDispatch.Failure(reason: "memory_not_pending")
        }
        if accept {
            let user = try OSDocuments.read(id: "user")
            if !UserMemoryText.contains(rows[index].text, in: user) {
                let outcome = try OSDocuments.write(id: "user", text: UserMemoryText.append(rows[index].text, isPublic: isPublic, to: user))
                if case .commitFailed(let reason) = outcome { throw DeviceDispatch.Failure(reason: reason) }
            }
        }
        rows[index].status = accept ? "accepted" : "rejected"
        rows[index].isPublic = isPublic
        rows[index].decidedAt = Date()
        // 已決定的只留最近 50 筆，排隊檔不長大。
        let decided = rows.filter { $0.status != "pending" }.sorted { ($0.decidedAt ?? .distantPast) > ($1.decidedAt ?? .distantPast) }
        rows = rows.filter { $0.status == "pending" } + decided.prefix(50)
        try write(rows, to: queueURL)
    }

    // MARK: Claude 自動記憶匯入

    /// 讀這台 Claude 的自動記憶（只取 user／feedback 類），逐條變成提案；已有的會被當成重複略過。
    func importClaudeMemories(home: String = NSHomeDirectory()) -> (added: Int, skipped: Int) {
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        var added = 0, skipped = 0
        for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let memory = project.appendingPathComponent("memory")
            for file in (try? fm.contentsOfDirectory(at: memory, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "md" && file.lastPathComponent != "MEMORY.md" {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let candidate = UserMemoryText.claudeMemoryCandidate(text) else { continue }
                if (try? propose(text: candidate, source: "Claude 記憶")) == .duplicate { skipped += 1 } else { added += 1 }
            }
        }
        return (added, skipped)
    }

    // MARK: 檔案

    private func read(_ url: URL) -> [UserMemoryProposal] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UserMemoryProposal].self, from: data)) ?? []
    }

    private func write(_ rows: [UserMemoryProposal], to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(rows).write(to: url, options: .atomic)
    }
}
