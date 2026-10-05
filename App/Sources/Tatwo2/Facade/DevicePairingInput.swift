import Foundation
import Network

/// 只解析畫面的輸入，不改配對請求、配對碼生命週期或信任判斷。
enum DevicePairingInput {
    struct Address: Equatable {
        let host: String
        let port: String
        let code: String?
    }

    static func normalizedCode(_ text: String) -> String {
        let bytes = text.utf8.compactMap { byte -> UInt8? in
            switch byte {
            case 97...122: byte - 32
            case 65...90, 48...57: byte
            default: nil
            }
        }
        return String(decoding: bytes.prefix(6), as: UTF8.self)
    }

    static func portNumber(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(text), (1...65_535).contains(port) else { return nil }
        return port
    }

    static func validHost(_ text: String) -> Bool {
        let host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DevicePairingAuth.isSafeSSHHost(host) else { return false }
        if host.contains(":") {
            // 不把未解析的 host:埠 當主機名，也不猜未加括號的 IPv6 哪段是埠。
            let parts = host.split(separator: "%", omittingEmptySubsequences: false)
            return parts.count <= 2 && parts.allSatisfy { !$0.isEmpty }
                && IPv6Address(String(parts[0])) != nil
        }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            return IPv4Address(host) != nil
        }
        return !host.contains("%") && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-")
        }
    }

    /// 一次改多個字視為整段貼入；逐字輸入在按 Enter 或離開欄位時才拆，避免 :1 被搶先拆走。
    static func isBulkEdit(previous: String, current: String) -> Bool {
        var before = previous[...]
        var after = current[...]
        while !before.isEmpty, !after.isEmpty, before.first == after.first {
            before.removeFirst()
            after.removeFirst()
        }
        while !before.isEmpty, !after.isEmpty, before.last == after.last {
            before.removeLast()
            after.removeLast()
        }
        return max(before.count, after.count) > 1
    }

    /// 只接受完整、無歧義的 host:埠 或 TATWO 配對 host:埠 6碼；失敗回 nil，呼叫端保留原文。
    static func parseAddress(_ text: String) -> Address? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        let endpoint: String
        let code: String?
        if fields.count == 4, fields[0] == "TATWO", fields[1] == "配對" {
            let rawCode = String(fields[3])
            let cleanCode = normalizedCode(rawCode)
            guard rawCode.utf8.count == 6, cleanCode.count == 6 else { return nil }
            endpoint = String(fields[2])
            code = cleanCode
        } else if fields.count == 1 {
            endpoint = String(fields[0])
            code = nil
        } else {
            return nil
        }

        let host: String
        let rawPort: String
        if endpoint.hasPrefix("["), let closing = endpoint.firstIndex(of: "]") {
            let suffix = endpoint[endpoint.index(after: closing)...]
            guard suffix.hasPrefix(":") else { return nil }
            host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closing])
            guard host.contains(":") else { return nil }
            rawPort = String(suffix.dropFirst())
        } else {
            let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            host = String(parts[0])
            rawPort = String(parts[1])
        }
        guard validHost(host), let port = portNumber(rawPort) else { return nil }
        return Address(host: host, port: String(port), code: code)
    }

    static func validationMessage(host: String, port: String, code: String, name: String) -> String? {
        if !validHost(host) { return "請填那台的位址，也可以貼上「位址:埠」或全部配對資訊。" }
        if portNumber(port) == nil { return "配對埠要填那台畫面上冒號後面的數字（1–65535）。" }
        if code.count != 6 || normalizedCode(code) != code { return "請填那台畫面上的 6 碼（A–Z、0–9）。" }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "請填這台的名字。" }
        return nil
    }

    static func copyLine(address: String, code: String) -> String {
        "TATWO 配對 \(address) \(code)"
    }
}

/// model 的訊息維持原樣；畫面另外給白話與小字工程資訊。
enum DevicePairingFeedback {
    struct Failure {
        let message: String
        let detail: String
    }

    static func failure(_ modelMessage: String) -> Failure? {
        let prefix = "配對失敗："
        guard modelMessage.hasPrefix(prefix) else { return nil }
        let raw = String(modelMessage.dropFirst(prefix.count))
        let detail = String(raw.split(separator: "：", maxSplits: 1).first ?? Substring(raw))
        let reason = detail.hasPrefix("pairing_rejected:")
            ? String(detail.dropFirst("pairing_rejected:".count)) : detail
        let message: String
        switch reason {
        case "invalid_host":
            message = "請填那台畫面上的位址，或直接貼上它的全部配對資訊。"
        case "invalid_port":
            message = "配對埠要填那台畫面上冒號後面的數字"
        case "pairing_code_mismatch", "pairing seed does not match the active request":
            message = "配對碼不對；請確認那台畫面上的 6 碼，再試一次。"
        case "pairing code expired", "pairing_code_expired":
            message = "配對碼已過期；請在那台重新產生配對碼。"
        case "pairing code already consumed (replay rejected)", "pairing_code_already_consumed":
            message = "這組配對碼已用過；請在那台重新產生配對碼。"
        case "pairing_window_closed":
            message = "那台沒有開著配對；請在那台按「產生配對碼」。"
        case "pairing_connection_timed_out":
            message = "連不到那台；請確認兩台在同一個網路，且那台正在顯示配對碼。"
        case "pairing_protocol_outdated", "bad_request":
            message = "兩台的配對版本可能不同；請把兩台 TATWO OS 都更新後重新配對。"
        case "ssh_public_key_unreadable":
            message = "讀不到這台用來配對的公鑰；請檢查這台的 SSH 設定。"
        case "ssh_batch_mode_verification_failed":
            message = "配對碼已確認，但 SSH 登入沒有成功；請確認那台已開啟「遠端登入」。"
        case "ssh_host_fingerprint_unavailable":
            message = "無法確認那台的主機金鑰；請確認那台已開啟「遠端登入」。"
        case "pairing_response_unauthenticated", "ssh_host_key_mismatch", "device_fingerprint_conflict":
            message = "那台的身分驗證沒有通過，可能有連線遭攔截；已停止配對。"
        case "pairing_peer_account_invalid":
            message = "那台回報的登入名字無法安全使用；已停止配對。"
        case "pairing_response_invalid":
            message = "那台的配對回覆無法辨識；請確認兩台版本一致，再重新產生配對碼。"
        case "request_too_large":
            message = "配對資料太大；請確認兩台版本一致後重新配對。"
        case "pairing code authority primary/epoch mismatch":
            message = "那台的設備身分已變更；請在那台重新產生配對碼。"
        default:
            if reason.hasPrefix("ssh_keygen_failed:") {
                message = "這台無法建立配對用的金鑰；請檢查這台的 SSH 設定。"
            } else {
                message = "配對沒有完成；請確認兩台在同一個網路、那台開著配對，再試一次。"
            }
        }
        return Failure(message: message, detail: detail)
    }
}
