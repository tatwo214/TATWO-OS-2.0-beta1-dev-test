import Foundation

/// 從零建立第一個領域 Space 的共用判斷。純函式，不碰 IO，也不 import SwiftUI，
/// 讓 tests/w89-space-from-zero.test.mjs 可以單獨編譯這個檔驗證前置條件。
/// W160（使用者 2026-09-22）：領域不以 bot 為前提。沒有 bot 也能建，bot 之後再掛進來。
enum SpaceCreationOutcome: Equatable {
    /// 可以建立；owner 用選中的 bot，沒有選中就用 library 第一隻，一隻都沒有就先不設。
    case ready(ownerBotID: String?)
}

enum SpaceCreationResult: Equatable {
    case created(id: String, name: String)
    case failed(String)
}

enum SpaceCreation {
    /// 既有 space 的預設密度（BotFixtureDensity.compact）。從零建立不讓使用者先選密度。
    static let defaultDensity = "compact"

    /// W171：全新安裝自動建立的那一個（Space 頁標題顯示這個名字）。
    static let defaultDomainName = "我的 Space"
    static let emptyExplanation = "Space 是 bot 的工作領域；先建立第一個領域"
    static let createTitle = "建立第一個領域"
    static let namePlaceholder = "領域名稱"
    static let loadingText = "正在讀取 work space…"

    /// owner：選中的 bot 優先，其次 library 第一隻；都沒有就不設，領域照樣建立。
    static func outcome(botIDs: [String], selectedBotID: String?) -> SpaceCreationOutcome {
        if let selected = selectedBotID, botIDs.contains(selected) { return .ready(ownerBotID: selected) }
        return .ready(ownerBotID: botIDs.first)
    }

    /// 沒有 bot、也沒有目前專案時，領域用入口底下自己的資料夾當工作目錄。
    static func domainFolder(entryRoot: String, domainID: String) -> String {
        (entryRoot as NSString).appendingPathComponent("spaces/" + domainID)
    }

    /// 領域名稱：去頭尾空白；空字串不建立。
    static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    /// Bot 頁三段流只有路徑與提示詞欄位；領域名稱取路徑最後一段。
    static func nameFromPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return normalizedName(last)
    }

    static func successText(name: String) -> String { "已建立領域 \(name)" }
}
