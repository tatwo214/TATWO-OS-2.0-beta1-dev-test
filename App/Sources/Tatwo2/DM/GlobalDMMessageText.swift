import SwiftUI
import UniformTypeIdentifiers

/// W179 F：私訊框訊息的顯示文字與排版。附件標籤換成短字（不露路徑）；對方的回答照 Coder 的方式排 Markdown。
enum GlobalDMMessageText {
    /// `<image name=… path="…">` 這類附件標籤顯示類型與檔名，完整路徑不顯示。
    static func displayText(_ raw: String) -> String {
        guard raw.contains("<"),
              let regex = try? NSRegularExpression(pattern: #"<(image|video|file)\b[^>]*>"#) else { return raw }
        let source = raw as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let kind = source.substring(with: match.range(at: 1))
            let tag = source.substring(with: match.range)
            result += attachmentLabel(kind: kind, fileName: name(in: tag))
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    /// W180 修正：ChatGPT 那邊附上的檔案也顯示類型與檔名，跟本機助理與對話的泡泡一致。
    static func attachmentTag(fileName: String) -> String {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension)
        let kind = type?.conforms(to: .image) == true ? "image"
            : type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true ? "video" : "file"
        return attachmentLabel(kind: kind, fileName: fileName)
    }

    private static func name(in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\bname=(?:\[([^\]\r\n]*)\]|"([^"\r\n]*)"|'([^'\r\n]*)'|([^\s>]+))"#),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return (tag as NSString).substring(with: match.range(at: index))
        }
        return nil
    }

    private static func attachmentLabel(kind: String, fileName: String?) -> String {
        let label = kind == "image" ? "圖片" : kind == "video" ? "影片" : "檔案"
        let basename = ((fileName ?? "").replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let safe = String(String.UnicodeScalarView(basename.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty, safe != ".", safe != ".." else { return "[\(label)附件]" }
        return "[\(label)：\(String(safe.prefix(160)))]"
    }

    /// 使用者訊息＋附件短字：跟本機那邊一樣，文字後空一行、每個附件一行。
    static func displayText(_ raw: String, files: [String]) -> String {
        let text = displayText(raw)
        guard !files.isEmpty else { return text }
        return text + (text.isEmpty ? "" : "\n\n") + files.map { attachmentTag(fileName: $0) }.joined(separator: "\n")
    }

    /// 有區塊結構（標題、清單、表格、程式碼、引言、分隔線）才用 Coder 的排版元件；一般段落用行內樣式，泡泡照字寬收。
    static func needsBlockLayout(_ text: String) -> Bool {
        text.split(separator: "\n").contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("```") || line.hasPrefix("|") || line.hasPrefix(">")
                || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line == "---" {
                return true
            }
            let digits = line.prefix { $0.isNumber }
            return !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(". ")
        }
    }

    /// 行內樣式（粗體、斜體、行內程式碼、連結），保留換行；讀不懂就照原文。
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// 私訊框的字級：W184 C 照手機內文 17pt（DMPhone token）；使用者訊息、回答、輸入框都用它。
    static let pointSize: CGFloat = GlobalDMChatLayout.messageSize

    /// 字級比照私訊框、行高 25（同一般段落），其餘照 Coder 的回答排版（表格、清單、程式碼）。
    static let typography = ChatTranscriptTypography(
        scale: pointSize / TatwoChatTranscriptVisualMetrics.transcriptPointSize,
        lineSpacing: GlobalDMChatLayout.replyLineSpacing)
}

/// 對方的一則訊息：有表格、清單、程式碼時用 Coder 的回答元件，其餘用行內樣式的文字。
struct GlobalDMRichText: View {
    let text: String

    var body: some View {
        if GlobalDMMessageText.needsBlockLayout(text) {
            ChatAssistantTranscriptBlockView(
                document: TatwoAssistantTranscriptPresentation.document(markdown: text),
                copyAllText: text,
                tracksAvailableWidth: true)
                .environment(\.chatTranscriptTypography, GlobalDMMessageText.typography)
        } else {
            // W184 C：回覆全寬、沒有泡泡，17pt、行高 25。
            Text(GlobalDMMessageText.inline(text))
                .font(.system(size: GlobalDMMessageText.pointSize))
                .lineSpacing(GlobalDMChatLayout.replyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// W179 UI：使用者自己的訊息（淡錨色底、無框；底色讀 Coder 使用者訊息同一組 token，不照抄對照稿的米色）。
/// W184 C：手機的樣子——17pt、行高 23、內距 9／14、圓角 20（GlobalDMChatLayout）；最寬約 78% 由訊息列決定。
struct GlobalDMUserBubble: View {
    let text: String
    /// W184 G3b：對象是 ChatGPT（照 ChatGPT App）：反白的泡泡（淺色黑底白字、深色淺底黑字），沒有框線。其他對象照舊。
    @Environment(\.globalDMChatGPTLook) private var inverse

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GlobalDMChatLayout.userBubbleRadius, style: .continuous)
        Text(text)
            .font(.system(size: GlobalDMMessageText.pointSize))
            .foregroundStyle(inverse ? AnyShapeStyle(ChatGPTPalette.inverseText) : AnyShapeStyle(.primary))
            .lineSpacing(GlobalDMChatLayout.userLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, GlobalDMChatLayout.userBubbleHorizontalPadding)
            .padding(.vertical, GlobalDMChatLayout.userBubbleVerticalPadding)
            .background(shape.fill(inverse ? ChatGPTPalette.inverseFill
                                    : LiquidGlassTokens.brandAccent.opacity(TatwoChatTranscriptVisualMetrics.userBubbleTintOpacity)))
            .overlay(shape.strokeBorder(inverse ? Color.clear
                                        : LiquidGlassTokens.brandAccent.opacity(TatwoChatTranscriptVisualMetrics.userBubbleStrokeOpacity),
                                        lineWidth: 1))
    }
}
