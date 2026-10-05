import Foundation

/// Stable refusal codes contain no user text or local paths. Detailed context
/// stays in the host transcript, fetched over the existing authenticated link.
enum RemoteSendRejection {
    static func code(for status: String?) -> String {
        switch status {
        case "error|Plan": "plan_unreadable"
        case "error|不用 API 金鑰": "engine_blocked"
        case "error|匯入": "workspace_missing"
        case "error|外部工作區": "workspace_denied"
        case "error|唯讀副審": "read_only_unsupported"
        case "error|ChatGPT 手腳", "error|ChatGPT TAP": "engine_route_unsupported"
        case "error|遠端設備", "error|遠端 handle": "device_unavailable"
        case "error|引擎未接", "error|sidecar", "error|capture-only": "engine_unavailable"
        default: "send_rejected"
        }
    }

    static func reason(for code: String) -> String? {
        switch code {
        case "thread_sending": "這條正在把上一句送到那台"
        case "thread_busy", "assistant_busy": "那台這條正在忙，請等上一輪結束"
        case "thread_missing": "那台的這條聊天已不存在，請刷新後確認"
        case "device_offline", "device_unavailable": "執行設備不在線或無法連線，請確認設備狀態"
        case "remote_access_disabled_no_paired_devices": "那台未允許遠端存取，請確認設備配對與權限"
        case "workspace_denied": "那台未允許存取工作資料夾，請先確認權限"
        case "workspace_missing": "那台的工作資料夾不存在，請先重新選擇"
        case "engine_blocked", "assistant_engine_disabled", "assistant_engines_disabled": "那台的引擎受到模型存取設定限制，請先確認登入與權限"
        case "plan_unreadable": "那台的計畫無法讀取或儲存，請先修復畫布資料"
        case "engine_unavailable": "那台的引擎尚未接上或無法啟動，請確認安裝狀態"
        case "unsupported_method", "engine_options_unsupported", "read_only_unsupported", "engine_route_unsupported": "那台的版本或引擎不支援這次送出設定，請確認版本與模型"
        case "invalid_params": "那台不接受這次送出的參數，請確認版本與送出設定"
        case "send_rejected", "assistant_not_sent": "那台未送出這句，原因已寫在對話裡"
        default: nil
        }
    }
}
