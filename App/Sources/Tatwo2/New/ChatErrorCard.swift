import SwiftUI

/// 把引擎回報的錯誤（原本是一整段 JSON／log 直接灌進氣泡）整理成一張看得懂的卡：
/// 標題講發生什麼、內文講原因、要看原文再展開、可以直接「再送一次」。
struct ChatErrorCardPresentation: Equatable {
    let headline: String
    let detail: String
    let raw: String?

    static func resolve(_ message: ChatMessage) -> ChatErrorCardPresentation? {
        guard message.role == .system,
              let status = message.status?.trimmingCharacters(in: .whitespacesAndNewlines),
              status.lowercased().hasPrefix("error") else { return nil }
        let source = status.split(separator: "|").dropFirst().first.map(String.init) ?? ""
        let text = stripANSI(message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let headline: String
        switch source {
        case "sidecar": headline = text.contains("啟動") ? "引擎啟動失敗" : "引擎回報錯誤"
        case "回合失敗": headline = "這一輪沒有完成"
        case "引擎未接": headline = "引擎還沒接上"
        case "遠端設備": headline = "遠端設備連不上"
        default: headline = text.hasPrefix("引擎在這一輪中途結束") ? "引擎中途結束" : "出了問題"
        }
        let (detail, raw) = summarize(text)
        return ChatErrorCardPresentation(headline: headline, detail: detail, raw: raw)
    }

    /// 內文：JSON 就抓 message／error 欄位；純文字就取前幾句。原文超過內文才提供展開。
    private static func summarize(_ text: String) -> (String, String?) {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let data = String(text[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = firstMessage(in: obj) {
                let prefix = text[..<start].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:")))
                let detail = prefix.isEmpty ? m : "\(prefix)：\(m)"
                return (String(detail.prefix(400)), text)
            }
        }
        let firstBlock = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3).joined(separator: "\n")
        let detail = String(firstBlock.prefix(400))
        return (detail, detail == text ? nil : text)
    }

    private static func firstMessage(in obj: [String: Any]) -> String? {
        for key in ["message", "error", "detail", "reason"] {
            if let s = obj[key] as? String, !s.isEmpty { return s }
            if let nested = obj[key] as? [String: Any], let s = firstMessage(in: nested) { return s }
        }
        return nil
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

struct ChatErrorCard: View {
    let presentation: ChatErrorCardPresentation
    let rowWidth: CGFloat?
    var canRetry: Bool
    var onRetry: () -> Void
    @State private var showsRaw = false

    /// 2026-09-11 使用者回饋：系統訊息用輸入框下方梯形抽屜同一套底色、縮小不佔滿版；
    /// 「再送一次」只留圖示，改用 App 自己的 chip 樣式。
    private static let maxWidth: CGFloat = 520
    static let textColumnInset: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .frame(width: 15, height: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.headline)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                    Text(presentation.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if canRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .chatGlassChip()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("再送一次")
                    .accessibilityLabel("再送一次")
                    .accessibilityIdentifier("chat-error-retry")
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            if let raw = presentation.raw {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showsRaw.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsRaw ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text(showsRaw ? "收起原始訊息" : "看原始訊息")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 34)
                    .padding(.bottom, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsRaw {
                    ScrollView(.horizontal) {
                        Text(raw)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        // 使用者 2026-09-19：灰框退回舊樣子。改用全 App 同一套液態表面（極光走玻璃、fable5 走暖紙浮起），
        // 不再自己畫一塊灰底；左緣對齊助理回覆的文字欄（頭像 24 + 間距 10），不是對齊頭像。
        .chatLiquidSection(cornerRadius: 12)
        .padding(.leading, Self.textColumnInset)
        .frame(width: rowWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.headline)
    }
}
