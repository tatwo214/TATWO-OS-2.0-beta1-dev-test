import Foundation

extension LiveThreadRecord {
    /// No runner can resume these persisted rows; retain text and close only active states.
    @discardableResult mutating func recoverInterruptedWork(reason: String) -> Bool {
        let unfinished = messages.indices.filter {
            messages[$0].status?.hasPrefix("writing") == true || messages[$0].status?.hasPrefix("running-command") == true
        }
        guard !unfinished.isEmpty || subStatus == "running" else { return false }
        let turn = unfinished.last.flatMap { messages[$0].turnID }
        for index in unfinished { messages[index].status = "cancelled|回合已中斷" }
        if subStatus == "running" { subStatus = "done" }
        messages.append(LiveMessageRecord(ChatMessage(role: .system, text: reason,
            status: "cancelled|回合已中斷", turnID: turn)))
        updatedAt = Date()
        return true
    }
}
