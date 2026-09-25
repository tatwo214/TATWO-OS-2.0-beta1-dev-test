import Foundation

/// W170 目標清單（使用者 2026-09-22：對齊 Claude CLI 的任務清單——主線看得見、只加不蓋、完成有標記、不飄移）。
/// 純規則，不碰檔案，tests/w170-goals.test.mjs 單獨編譯驗證。
struct ThreadGoal: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable { case pending, active, review, done, paused }
    var id: Int                 // 顯示用編號，一條討論串內只增不重用
    var title: String
    var userWords: String?      // 使用者原話（來源）
    var status: Status
    var proposed: Bool          // AI 提議，使用者按「加入主線」前不算主線
    var evidence: String?
    var parent: Int?            // /plg 派工的子目標掛在哪一條底下
    var createdAt: Date
    var updatedAt: Date
    var roomThread: String? = nil   // /plg 派出去的那條子討論串（sub 用它回報）
}

struct ThreadGoalList: Codable, Equatable {
    var goals: [ThreadGoal] = []
    var nextID = 1
}

enum ThreadGoalRules {
    /// 誰在改：使用者（畫面）、主導（這條對話的引擎）、sub（被派出去的工作）。
    enum Actor: String { case user, lead, sub }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound, proposedNeedsApproval, evidenceRequired, subCannotComplete, userOnly, emptyTitle
        case openChildren(Int)
        var description: String {
            switch self {
            case .notFound: "找不到這一條目標"
            case .proposedNeedsApproval: "這條是 AI 提議，使用者按「加入主線」後才能開始"
            case .evidenceRequired: "標完成要附證據（測試結果、截圖或版本號）"
            case .subCannotComplete: "被派出去的工作只能標「待驗收」，要主導驗過才算完成"
            case .userOnly: "暫停、改文字或刪除要使用者自己來"
            case .emptyTitle: "目標不能是空的"
            case .openChildren(let n): "還有 \(n) 條派出去的工作沒回報，等它們到「待驗收」再標完成"
            }
        }
    }

    /// 只加不蓋：新目標永遠接在後面，編號遞增。
    static func add(_ list: inout ThreadGoalList, title: String, userWords: String?, proposed: Bool,
                    parent: Int? = nil, now: Date = Date()) throws -> ThreadGoal {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyTitle }
        let goal = ThreadGoal(id: list.nextID, title: String(text.prefix(200)),
                              userWords: userWords.map { String($0.prefix(400)) }, status: .pending,
                              proposed: proposed, evidence: nil, parent: parent, createdAt: now, updatedAt: now)
        list.goals.append(goal)
        list.nextID += 1
        return goal
    }

    static func setStatus(_ list: inout ThreadGoalList, id: Int, to status: ThreadGoal.Status,
                          evidence: String?, actor: Actor, now: Date = Date()) throws {
        guard let index = list.goals.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        if list.goals[index].proposed && actor != .user { throw Failure.proposedNeedsApproval }
        var target = status
        let proof = evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        if target == .done && actor == .sub { target = .review }
        if target == .done && actor == .lead && (proof ?? "").isEmpty && (list.goals[index].evidence ?? "").isEmpty {
            throw Failure.evidenceRequired
        }
        if target == .paused && actor != .user { throw Failure.userOnly }
        // 2026-09-22 使用者選：父目標完成時，底下「待驗收」的子目標跟著完成（主導的驗收涵蓋它們）；
        // 還在做的子目標擋住主導，使用者自己按完成則一併收掉（例如房間掛了）。
        if target == .done {
            let open = list.goals.indices.filter { list.goals[$0].parent == id && list.goals[$0].status != .done }
            let working = open.filter { [.active, .pending].contains(list.goals[$0].status) }
            if actor != .user && !working.isEmpty { throw Failure.openChildren(working.count) }
            for i in open where actor == .user || list.goals[i].status == .review {
                list.goals[i].status = .done; list.goals[i].updatedAt = now
            }
        }
        list.goals[index].status = target
        if let proof, !proof.isEmpty { list.goals[index].evidence = String(proof.prefix(600)) }
        list.goals[index].updatedAt = now
        // 同一時間只留一條「進行中」：新的開始，舊的退回待做（不是完成）。
        if target == .active {
            for i in list.goals.indices where i != index && list.goals[i].status == .active && list.goals[i].parent == nil
                && list.goals[index].parent == nil {
                list.goals[i].status = .pending; list.goals[i].updatedAt = now
            }
        }
    }

    /// 使用者對 AI 提議：收下＝變成主線；不要＝拿掉（它本來就不是主線）。
    static func decideProposal(_ list: inout ThreadGoalList, id: Int, accept: Bool, now: Date = Date()) throws {
        guard let index = list.goals.firstIndex(where: { $0.id == id && $0.proposed }) else { throw Failure.notFound }
        if accept { list.goals[index].proposed = false; list.goals[index].updatedAt = now }
        else { list.goals.remove(at: index) }
    }

    /// 只有使用者能改文字或刪除主線目標。
    static func edit(_ list: inout ThreadGoalList, id: Int, title: String?, remove: Bool, actor: Actor, now: Date = Date()) throws {
        guard actor == .user else { throw Failure.userOnly }
        guard let index = list.goals.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        if remove { list.goals.remove(at: index); return }
        if let title {
            let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.emptyTitle }
            list.goals[index].title = String(text.prefix(200)); list.goals[index].updatedAt = now
        }
    }

    static func progress(_ list: ThreadGoalList) -> (done: Int, total: Int) {
        let main = list.goals.filter { !$0.proposed && $0.parent == nil }
        return (main.filter { $0.status == .done }.count, main.count)
    }

    static func symbol(_ goal: ThreadGoal) -> String {
        if goal.proposed { return "◇" }
        switch goal.status {
        case .pending: return "○"
        case .active: return "●"
        case .review: return "◌"
        case .done: return "✓"
        case .paused: return "⏸"
        }
    }

    /// 每一輪交給引擎的清單摘要：只列還沒完成的，並提醒規矩。沒有目標回 nil（不打擾）。
    static func promptSummary(_ list: ThreadGoalList) -> String? {
        let open = list.goals.filter { $0.status != .done }
        guard !open.isEmpty else { return nil }
        let lines = open.map { goal -> String in
            let tag = goal.proposed ? "（AI 提議，未核准）" : goal.status == .review ? "（待驗收）" : goal.status == .paused ? "（暫停）" : ""
            return "\(symbol(goal)) \(goal.id). \(goal.title)\(tag)"
        }
        let (done, total) = progress(list)
        return """
        ［這串的目標清單：已完成 \(done)／\(total)］
        \(lines.joined(separator: "\n"))
        規矩：回報時說明這一步屬於第幾條；要做清單外的事先停下來問使用者，或用 goal_propose 提議；完成要附證據（goal_update）。
        """
    }
}
