import Foundation
@main struct GroupEventsCheck {
    @MainActor static func main() throws {
        var notifications: [GroupEvent] = [], available = true
        var callbacks: [(Result<String, Error>) -> Void] = []
        let primary = GroupParticipant(id: "Codex", invoke: { _, done in done(.success("private Coder body")) }, stop: {})
        let tap = GroupParticipant(id: "FixtureTap", join: true, unavailable: { available ? nil : "synthetic offline" }, invoke: { _, done in callbacks.append(done) }, stop: {})
        let group = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [primary, tap])
        group.canExchange = { $0 != "Codex" }
        group.onEvent = { notifications.append($0) }
        func finish(_ body: String) { callbacks.removeFirst()(.success(body)) }
        precondition(group.human("@@FixtureTap private human body"))
        finish("private TAP summary")
        precondition(callbacks.count == 1)
        finish("private TAP exchange")
        precondition(!group.busy)
        precondition(notifications.filter { $0.kind == "join" }.count == 1)
        precondition(notifications.filter { $0.kind == "transfer" }.count == 1)
        group.exchangeLimit = 0
        group.leave("FixtureTap")
        precondition(group.human("@@FixtureTap return"))
        finish("private return")
        available = false
        precondition(group.human("offline turn"))
        precondition(group.state("FixtureTap") == .away)
        available = true
        precondition(group.human("recovered turn"))
        finish("private recovered")
        precondition(notifications.filter { $0.kind == "leave" }.count == 1)
        precondition(notifications.filter { $0.kind == "away" }.count == 1)
        precondition(notifications.filter { $0.kind == "reconnect" }.count == 2)
        precondition(!group.events.contains { ["join", "transfer", "reconnect"].contains($0.kind) })
        let data = try group.snapshot()
        let restored = GroupTurnEngine(threadID: group.threadID, primary: "Codex", participants: [primary, tap])
        try restored.restore(data, content: { group.events[$0.sequence - 1].text })
        precondition(restored.events == group.events)
        print("W229 GROUP EVENTS PASS join=1 transfer=1 leave=1 away=1 reconnect=2 ledger-preserved")
    }
}
