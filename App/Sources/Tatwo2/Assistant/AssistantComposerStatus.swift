import Foundation

/// W179 UI：TATWO 助理輸入框下方狀態抽屜（外觀同 Coder 的梯形抽屜）這一刻顯示什麼。純函式，`w179ui` 自測驗。
/// 照 Coder 09-11 的裁決「沒提醒時梯形裡不要有字」：平常沒字；主設備名不常駐（在模型選單第一行）。
/// 先後：送出失敗等提示 → 接不到主設備的說明（連線中＝進行中，連不上／先用這台＝要注意）→ 送到主設備途中 → 回覆中（同 Coder 的「工作中」）→ 沒字。
struct AssistantComposerStatus: Equatable {
    let text: String?
    let tone: ChatComposerStatusTone
    let identifier: String

    static func resolve(hint: String?, placementNote: String?, isConnecting: Bool,
                        isDelivering: Bool, isRunning: Bool) -> Self {
        if let hint {
            return Self(text: hint, tone: .hint, identifier: "tatwo-assistant-primary-hint")
        }
        if let placementNote {
            return Self(text: placementNote, tone: isConnecting ? .working : .warning, identifier: "tatwo-assistant-offline")
        }
        if isDelivering {
            return Self(text: "送到主設備…", tone: .working, identifier: "tatwo-assistant-status")
        }
        if isRunning {
            return Self(text: "工作中", tone: .working, identifier: "tatwo-assistant-status")
        }
        return Self(text: nil, tone: .quiet, identifier: "tatwo-assistant-status")
    }
}
