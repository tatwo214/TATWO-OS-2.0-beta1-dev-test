import SwiftUI
/// Coder alone folds turn metadata; canonical messages and shared transcripts stay intact.
struct CoderTurnProjection {
    var items: [ChatTranscriptDisplayItem] = []
    var details: [String: [ChatTranscriptDisplayItem]] = [:]
    var owners: [String: String] = [:]
    init(_ source: [ChatTranscriptDisplayItem], messages: [ChatMessage], isRunning: Bool = false) {
        var turns: [String: String] = [:], current = "legacy"
        for message in messages {
            if message.role == .user { current = message.turnID ?? message.id }
            turns[message.id] = message.turnID ?? current
        }
        func turn(_ item: ChatTranscriptDisplayItem) -> String {
            switch item {
            case .message(let message): return turns[message.id] ?? message.id
            case .workTimeline(let timeline): return timeline.messages.first.flatMap { turns[$0.id] } ?? timeline.turnID
            case .planSummary: return "plan"
            }
        }
        for case .message(let message) in source where message.role == .assistant { owners[turn(.message(message))] = message.id }
        for item in source {
            let folded: Bool
            switch item {
            case .workTimeline(let timeline): folded = !timeline.presentation.isActive && !(isRunning && turn(item) == current)
            case .message(let message): folded = ChatSystemNotePresentation.resolve(message)?.tag == TatwoMemoryUsageNote.tag || (ChatSystemNotePresentation.resolve(message)?.tag == "權限" && message.status?.hasPrefix("done|") == true)
            case .planSummary: folded = false
            }
            guard folded else { items.append(item); continue }
            let key = turn(item)
            if owners[key] == nil {
                owners[key] = item.id
                items.append(.message(ChatMessage(id: item.id, role: .assistant, text: "", modelID: { if case .workTimeline(let timeline) = item { return timeline.modelID }; return nil }(), turnID: key)))
            }
            details[owners[key]!, default: []].append(item)
        }
    }
}
