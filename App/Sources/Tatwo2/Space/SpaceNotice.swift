import Foundation

/// 各 Space 的通知（使用者 2026-09-25「chatgpt的回覆會有通知 但是os內建目前缺少通知 我們其實是需要有各space的通知功能的」）。
///
/// - 用 Island 的提示卡：App 不在前面也看得到，不用系統通知權限，也不寫進系統的通知中心。
/// - 只放標題（例如對話名稱），不放內容。
/// - 每個 Space 各自一個開關（預設開）；Space 用它在 Space 設定裡的代號（例：chatgpt）。
@MainActor
enum SpaceNotice {
    static func key(_ space: String) -> String { "tatwo.space.\(space).notify" }

    static func isEnabled(_ space: String) -> Bool {
        UserDefaults.standard.object(forKey: key(space)) as? Bool ?? true
    }

    static func setEnabled(_ space: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key(space))
    }

    static func post(space: String, title: String, detail: String) {
        guard isEnabled(space) else { return }
        IslandNotice.shared.info(title: title, detail: detail)
    }
}
