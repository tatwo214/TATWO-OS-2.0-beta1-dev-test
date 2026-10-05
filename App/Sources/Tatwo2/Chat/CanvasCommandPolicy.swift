import Foundation

struct CanvasArchiveOption: Equatable {
    let planID: UUID
    let kind: String?
    let objective: String

    init(_ plan: TatwoPlanArtifactV1) {
        planID = plan.planID
        kind = plan.kind
        objective = plan.objective
    }
}

enum CanvasCommandPolicy {
    static let commands: Set<String> = ["/plan", "/pr", "/feedback", "/蒸餾"]
    static let tapUnsupported = "ChatGPT（TAP）目前不支援這個指令，請改用 Codex 或 Claude"
    static func command(in text: String) -> String? {
        guard let token = text.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init),
              commands.contains(token) else { return nil }
        return token
    }
}
