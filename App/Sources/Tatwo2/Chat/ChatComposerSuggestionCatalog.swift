// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatComposerSuggestionCatalog.swift；改動 4 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import Foundation

enum ChatComposerSigil: String {
    case mcp = "@", skill = "$", issue = "!", tap = "@@"
    var title: String { switch self { case .mcp: "MCP 工具"; case .skill: "Skillet 技能"; case .issue: "Issue List"; case .tap: "TAP（拉進這串一起討論）" } }
    var icon: String { switch self { case .mcp: "wrench.and.screwdriver"; case .skill: "book"; case .issue: "circle"; case .tap: "bubble.left.and.bubble.right" } }
    static func query(_ prompt: String) -> (kind: Self, text: String)? {
        guard prompt.last?.isWhitespace != true, let token = prompt.split(whereSeparator: \.isWhitespace).last else { return nil }
        guard !token.hasPrefix("@-") else { return nil }
        guard let kind = [Self.tap, .mcp, .skill, .issue].first(where: { token.hasPrefix($0.rawValue) }) else { return nil }
        let text = String(token.dropFirst(kind.rawValue.count)).lowercased()
        guard kind != .skill || text.first?.isNumber != true else { return nil }
        return (kind, text)
    }
}

struct ChatComposerSigilItem: Identifiable {
    var id: String { identity ?? value }
    let name, detail, value: String
    var enabled = true
    var identity: String? = nil
    func isIn(_ text: String) -> Bool {
        text.range(of: "(?<!\\S)" + NSRegularExpression.escapedPattern(for: value) + "(?=\\s|$)", options: .regularExpression) != nil
    }
}

enum ChatComposerSuggestionSelection {
    static func next(current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return min(current + 1, count - 1)
    }

    static func previous(current: Int?, count: Int) -> Int? {
        guard count > 0, let current else { return nil }
        return current <= 0 ? nil : min(current - 1, count - 1)
    }
}

enum ChatComposerSkillCatalog {
    static func suggestions(
        in book: TatwoPluginRegistryBookV1,
        query: String,
        limit: Int = 6
    ) -> [PluginRegistryEntry] {
        let lowered = query.lowercased()
        let composerSkills = book.sortedEntries.filter {
            $0.kind == .skill || $0.id == "tatwo-ultrawork"
        }
        let matches = composerSkills.sorted { ($0.id == "tatwo-ultrawork" ? 0 : 1) < ($1.id == "tatwo-ultrawork" ? 0 : 1) }.filter { entry in
            lowered.isEmpty
                || entry.id.lowercased().contains(lowered)
                || entry.name.lowercased().contains(lowered)
        }
        return Array(matches.prefix(limit))
    }
}

struct ChatComposerSlashMatch: Equatable {
    let command: String
}

enum ChatComposerSlashCatalog {
    static let commands = ["/plg", "/plan", "/goal", "/goal list", "/issue", "/feedback", "/pr", "/討論串", "/顯示討論串", "/蒸餾"]

    static func matches(prompt: String) -> [ChatComposerSlashMatch] {
        guard prompt.rangeOfCharacter(from: .newlines) == nil else { return [] }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }
        if trimmed.dropFirst().contains(where: \.isWhitespace) {
            return "/goal list".hasPrefix(trimmed) ? [.init(command: "/goal list")] : []
        }
        return commands
            .filter { $0.hasPrefix(trimmed) || trimmed.hasPrefix($0) }
            .map(ChatComposerSlashMatch.init(command:))
    }

    static func inserting(command: String, into prompt: String) -> String {
        let inserted = TatwoSlashCommandParser.replacingPartialCommand(
            in: prompt,
            with: command)
        return inserted.hasSuffix(" ") ? inserted : inserted + " "
    }
}
