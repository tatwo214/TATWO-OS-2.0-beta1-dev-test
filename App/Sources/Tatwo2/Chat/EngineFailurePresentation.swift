import Foundation

enum EngineFailurePresentation {
    static func openModelLogin() {
        NotificationCenter.default.post(name: .tatwoOpenSettingsSection, object: TatwoSettingsPage.Section.modelAccess.rawValue)
    }
    enum Category { case login, version, model, quota, other }
    struct Value { var summary: String; var details: String; var category: Category }
    static func make(_ raw: String, details: String? = nil, alternative: String, retrying: Bool = false) -> Value {
        let object = raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let error = object?["error"] as? [String: Any]
        let reason = (error?["message"] as? String) ?? object?["message"] as? String ?? raw
        let lower = [reason, error?["type"] as? String, error?["code"] as? String,
                     object?["code"] as? String].compactMap { $0 }.joined(separator: " ").lowercased()
        let summary: String
        let category: Category
        if ["login", "log in", "sign in", "unauthorized", "unauthenticated", "not authenticated", "authentication",
            "invalid_api_key", "invalid api key", "token expired", "expired token", "未登入", "尚未登入", "登入已失效", "重新登入"].contains(where: lower.contains) {
            category = .login
            summary = "登入已失效或尚未完成，請到設定 › 登入重新登入，再送出這句。"
        } else if retrying {
            category = .other
            summary = "連線暫時出錯，引擎正在重試；請稍候。"
        } else if lower.contains("newer version") || lower.contains("minimum version") || lower.contains("too old") {
            category = .version
            summary = "引擎版本太舊，請到設定 › 登入檢查版本，或改選 \(alternative) 再送出。"
        } else if lower.contains("unsupported") || lower.contains("not supported") || lower.contains("unknown model") || lower.contains("model_not_found") {
            category = .model
            summary = "目前引擎或帳號不支援這個模型，請改選 \(alternative) 再送出。"
        } else if lower.contains("quota") || lower.contains("rate limit") || lower.contains("limit exhausted") {
            category = .quota
            summary = "目前模型的額度已用完，請稍後重試，或改選 \(alternative)。"
        } else {
            category = .other
            summary = "引擎未能完成這一輪，請稍後重試，或改選 \(alternative)。"
        }
        let original = details ?? (object != nil ? raw :
            String(data: (try? JSONSerialization.data(withJSONObject: ["message": raw], options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? raw)
        let safe = HandsRedactor.redact(HandsSecretLines.maskText(original))
        return Value(summary: summary, details: String(safe.prefix(32_000)) + (safe.count > 32_000 ? "\n〔細節已截斷〕" : ""), category: category)
    }
}
