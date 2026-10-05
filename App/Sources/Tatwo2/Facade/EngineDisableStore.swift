import Foundation

/// 使用者在「模型登入」頁對某家按了「不用 API 金鑰」（W181 R3 前叫「禁用 API」；存的鍵與值不變）。
/// W181 R3：勾了只代表「這家不准走 API 金鑰（按量計費）」，訂閱／帳號登入照常能跑；
/// 擋不擋送出只看 `sendBlockReason`（勾了、而且這家在這台只有 API 金鑰或判斷不出來）。
enum EngineDisableStore {
    private static let key = "tatwo2.disabledEngines"
    /// 勾了「不用 API 金鑰」的家（設定值本身，不等於擋送出）。
    static func disabled() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    /// 勾了「不用 API 金鑰」（設定值本身，不等於擋送出；要不要擋看 `blocksSend`）。
    static func isDisabled(_ kind: ClaudeSidecar.Kind) -> Bool { disabled().contains(kind.rawValue) }
    static func set(_ kind: ClaudeSidecar.Kind, disabled: Bool) {
        var s = self.disabled()
        if disabled { s.insert(kind.rawValue) } else { s.remove(kind.rawValue) }
        UserDefaults.standard.set(Array(s).sorted(), forKey: key)
    }
    static func displayName(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind { case .codex: "OpenAI"; case .claude: "Claude"; case .grok: "Grok" }
    }

    /// W181 R3：唯一的擋送出判斷（Coder、助理、私訊框、派工、遙控、橋接都走這裡）。nil＝可以送，否則是白話說明。
    /// optedOut 不給就讀使用者的設定；cwd＝這句要跑的資料夾（Claude 的專案設定也可能叫它改走 API 金鑰）；
    /// otherDevice＝這條派到別台跑（那台的名字，不知道給空字串）：這台的登入說明不了那台，勾了就照舊擋；
    /// allowStale＝畫面用（Claude 的登入方式先用上次查的，背景重查）。主執行緒一律不起子程序（見 EngineAPIKeyPolicy.method）。
    /// 沒勾：一律 nil，跟舊版一樣什麼都不查。
    static func sendBlockReason(_ kind: ClaudeSidecar.Kind, optedOut: Set<String>? = nil, cwd: String? = nil,
                                otherDevice: String? = nil,
                                allowStale: Bool = false, policy: EngineAPIKeyPolicy = .shared) -> String? {
        guard (optedOut ?? disabled()).contains(kind.rawValue) else { return nil }
        if let otherDevice { return EngineAPIKeyPolicy.otherDeviceMessage(kind, device: otherDevice.isEmpty ? nil : otherDevice) }
        if kind == .claude, let cwd, EngineAPIKeyPolicy.claudeProjectUsesAPIKey(cwd: cwd) {
            return EngineAPIKeyPolicy.claudeProjectMessage
        }
        let method = policy.method(kind, allowStale: allowStale)
        return method == .subscription ? nil : EngineAPIKeyPolicy.blockMessage(kind, method)
    }

    /// W181 R3：這台送不出這家（勾了不用 API 金鑰、而且這家在這台只有 API 金鑰或判斷不出來）。
    static func blocksSend(_ kind: ClaudeSidecar.Kind, optedOut: Set<String>? = nil, cwd: String? = nil,
                           allowStale: Bool = false, policy: EngineAPIKeyPolicy = .shared) -> Bool {
        sendBlockReason(kind, optedOut: optedOut, cwd: cwd, allowStale: allowStale, policy: policy) != nil
    }

    /// W181 R3：設定頁、總覽頁那一小行（沒勾是 nil）；blocked＝這台現在送不出（紅字、紅圈）。畫面用，不起子程序。
    static func optOutLabel(_ kind: ClaudeSidecar.Kind, optedOut: Set<String>? = nil,
                            policy: EngineAPIKeyPolicy = .shared) -> (text: String, blocked: Bool)? {
        guard (optedOut ?? disabled()).contains(kind.rawValue) else { return nil }
        switch policy.method(kind, allowStale: true) {
        case .subscription: return ("不用 API 金鑰（訂閱照用）", false)
        case .checking: return ("不用 API 金鑰（確認登入方式中…）", false)
        case .checkFailed: return ("不用 API 金鑰（暫時查不到登入，先不送）", true)
        case .apiKey, .unknown: return ("不用 API 金鑰（沒訂閱登入，送不出）", true)
        }
    }

    /// W181 R3：只吃 API 金鑰的地方（GBrain 語意搜尋）能不能帶這家的金鑰：勾了就不帶。
    static func allowsAPIKey(_ kind: ClaudeSidecar.Kind, optedOut: Set<String>? = nil) -> Bool {
        !(optedOut ?? disabled()).contains(kind.rawValue)
    }
}
