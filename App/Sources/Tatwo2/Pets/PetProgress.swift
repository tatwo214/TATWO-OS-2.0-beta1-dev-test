import Foundation
import CoreFoundation

/// Provider output totals include hidden thinking/reasoning; detail fields are subsets.
enum PetTokenUsage {
    static func output(_ result: [String: Any]) -> Int? {
        guard let usage = result["usage"] as? [String: Any], let n = usage["output_tokens"] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0, n.doubleValue < Double(Int.max),
              n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
        return n.intValue
    }
}
struct PetProgress: Codable, Equatable, Sendable {
    static let turnCap = 50_000
    static let tokensPerPoint = 100
    static let badgeExperience = 1_000_000
    static let maximumLevel = 99
    let creditedTokens: Int64
    var experience: Double { Double(creditedTokens) / Double(Self.tokensPerPoint) }
    var badges: Int64 { creditedTokens / (Int64(Self.badgeExperience) * Int64(Self.tokensPerPoint)) }
    var remainderTokens: Int64 { creditedTokens % (Int64(Self.badgeExperience) * Int64(Self.tokensPerPoint)) }
    var level: Int {
        var n = 1
        while n < Self.maximumLevel && Int64((n + 1) * (n + 1) * (n + 1) * Self.tokensPerPoint) <= remainderTokens { n += 1 }
        return n
    }
    private var levelFloor: Int { level == 1 ? 0 : level * level * level }
    var levelExperience: Double { Double(remainderTokens) / Double(Self.tokensPerPoint) - Double(levelFloor) }
    var nextLevelExperience: Double { Double((level + 1) * (level + 1) * (level + 1) - levelFloor) }
    var levelFraction: Double { min(1, max(0, levelExperience / nextLevelExperience)) }
    /// Integer tokens accumulate without rounding each turn (one token = 0.01 experience).
    static func calculate(_ events: [OSEvent]) -> Self {
        var seen: Set<String> = [], total: Int64 = 0
        for event in events where event.kind == "turn_end" && seen.insert(event.id).inserted {
            if let tokens = event.tokens { total += Int64(min(max(0, tokens), turnCap)) }
        }
        return Self(creditedTokens: total)
    }
    static func query(projectID: UUID, log: OSEventLog) throws -> Self {
        calculate(try log.query(project: projectID, from: .distantPast, through: .distantFuture, kinds: ["turn_end"]))
    }
}
@MainActor extension PetPersonality {
    static func turnPrompt(engine: ChatLiveEngine, projectID: UUID?, source: OSEventSources.Send) -> String? {
        guard source.surface == "pets", let projectID else { return nil }
        do { return try PetStore.atRoot(engine.store.url.deletingLastPathComponent()).personalityPrompt(for: projectID) }
        catch { engine.onHint?("寵物性格讀取失敗；這回合未加入性格。"); return nil }
    }
    static func turnText(_ text: String, engine: ChatLiveEngine, projectID: UUID?, source: OSEventSources.Send) -> String {
        turnPrompt(engine: engine, projectID: projectID, source: source).map { text + "\n\n" + $0 } ?? text
    }
}
enum PetSettings {
    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: "tatwo.pets.enabled") as? Bool) ?? true
    }
}
