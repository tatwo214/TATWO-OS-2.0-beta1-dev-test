import AppKit
import SwiftUI

// W184 C（使用者 09-29：「私訊鈕的ui完全垃圾 應該要參照手機app的規格去設計」；對照稿 https://claude.ai/artifact/RoVoQkiMN13LDhD9Hj2s2g
// 的 Main、Outer-ChatGPT、Open-Portrait-Chat、Open-Landscape-*）：私訊框的訊息列、提示列、輸入列照手機 App 排——
// 我說的＝靠右泡泡、回覆＝全寬沒有泡泡、玻璃膠囊輸入框、提示列＝一句白話＋最多一顆鈕。
// 數值一律從 DMPhone 取（字級只用 17／15／13／11、同心圓角）；DMPhone 沒有的值在這裡用 token 組出來（報告列給房 AB 收進 token 檔）。
// 顏色照 GlobalDMPalette 的規則：App 的玻璃 token 與系統語意色，不照抄對照稿的米色。Coder 共用的元件不改，不同的樣子在這裡自己包。

enum GlobalDMChatLayout {
    // MARK: 字級（只用 DMPhone.TextSize）

    /// 訊息（我說的、回覆）、輸入框的字與佔位字。
    static let messageSize = DMPhone.TextSize.body
    /// 提示列那一句、空對話的說明。
    static let noticeSize = DMPhone.TextSize.secondary
    /// chip（記憶、模型、提示列的鈕、附件小卡）、ChatGPT 說明行、「用了 N 條記憶」這種說明字。
    static let footnoteSize = DMPhone.TextSize.footnote
    /// 最小的字：chip 的 ⌄、說明行的鎖頭、小標。
    static let captionSize = DMPhone.TextSize.caption
    /// 圓鈕裡的圖示（＋、送出的上箭頭）與提示列前面的圖示：跟內文一樣大。
    static let glyphSize = DMPhone.TextSize.body
    /// 停止鈕裡的方塊。
    static let stopGlyphSize = DMPhone.TextSize.footnote
    /// 這一區用到的全部字級（自測核對都在 17／15／13／11 裡）。
    static var textSizes: [CGFloat] {
        [messageSize, noticeSize, footnoteSize, captionSize, glyphSize, stopGlyphSize,
         noteTypography.text, noteTypography.label, noteTypography.mark]
    }
    /// 系統說明、「用了 N 條記憶」在私訊框的字級（說明 13、小標與圖示 11）；Coder、TATWO 不設＝照舊。
    static let noteTypography = ChatNoteTypography(text: footnoteSize, label: captionSize, mark: captionSize)

    // MARK: 訊息區

    /// 內距：上 10、下 16；左右 16（內橫兩欄 20）。
    static let listTop: CGFloat = 10
    static let listBottom: CGFloat = 16
    static func sideMargin(for role: GlobalDMBoxRole) -> CGFloat {
        role == .single ? DMPhone.margin : DMPhone.wideMargin
    }
    /// 訊息之間 18；回覆下面緊接的「用了 N 條記憶」只隔 6（對照稿的說明字貼著回覆）。
    static let messageSpacing: CGFloat = 18
    static let metaSpacing: CGFloat = 6

    static func gap(before bubble: GlobalDMBubble, after previous: GlobalDMBubble?) -> CGFloat {
        guard let previous else { return 0 }
        return previous.kind == .theirs && bubble.isMemoryUsage ? metaSpacing : messageSpacing
    }

    static func gaps(_ bubbles: [GlobalDMBubble]) -> [CGFloat] {
        bubbles.indices.map { gap(before: bubbles[$0], after: $0 > 0 ? bubbles[$0 - 1] : nil) }
    }

    /// 我說的：靠右泡泡，最寬約 78%；內距 9／14、圓角 20、行高 23。
    static let userBubbleMaxFraction: CGFloat = 0.78
    static func userBubbleMaxWidth(rowWidth: CGFloat) -> CGFloat { rowWidth * userBubbleMaxFraction }
    static let userBubbleVerticalPadding: CGFloat = 9
    static let userBubbleHorizontalPadding: CGFloat = 14
    static let userBubbleRadius: CGFloat = 20
    static let userLineHeight: CGFloat = 23
    static let userLineSpacing = lineSpacing(size: messageSize, lineHeight: userLineHeight)
    /// 回覆：全寬、沒有泡泡、行高 25；不帶頭像（對象由頂列圓鈕表示）。
    static let replyLineHeight: CGFloat = 25
    static let replyLineSpacing = lineSpacing(size: messageSize, lineHeight: replyLineHeight)
    static let showsReplyAvatar = false

    /// SwiftUI 只有行距：行高減系統字一行的高度。
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return max(0, lineHeight - (font.ascender - font.descender + font.leading))
    }

    // MARK: 輸入框

    /// 外距 左右下 12；圓角＝框 52 − 12＝40（同心）。
    static var composerInset: CGFloat { DMPhone.edgeInset }
    static var composerRadius: CGFloat { DMPhone.barRadius }
    /// 內距 上 12、右 12、下 10、左 16。
    static let composerTop: CGFloat = 12
    static let composerTrailing: CGFloat = 12
    static let composerBottom: CGFloat = 10
    static let composerLeading: CGFloat = 16
    /// 兩層（字、下面一排）之間 10；一排裡的東西之間 8。
    static let composerLayerSpacing: CGFloat = 10
    static let composerItemSpacing: CGFloat = 8
    /// ＋、送出、停止是 36 的圓；記憶、模型 chip 32 高的膠囊。
    static var controlSize: CGFloat { DMPhone.smallControl }
    static var chipHeight: CGFloat { DMPhone.chipHeight }
    /// ＋ 往左凸出 6（圓鈕的邊跟字的左緣錯開，跟對照稿一樣）。
    static let plusOutset: CGFloat = -6
    /// 文字區：一行（17pt 中文約 24 高）到約 5 行。
    static let inputMinimumHeight: CGFloat = 24
    static let inputMaximumHeight: CGFloat = 120
    /// 附件小卡的檔名：照字寬（量出來再留 2，短檔名不會被截成「…」），最寬 140（再長中間省略，滑過看全名）。
    static let attachmentNameMaxWidth: CGFloat = 140
    static func attachmentNameWidth(_ name: String) -> CGFloat {
        let natural = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: footnoteSize)]).width
        return min(attachmentNameMaxWidth, ceil(natural) + 2)
    }

    // MARK: 提示列

    /// 一句話＋最多一顆 chip：內距 8（左 14），最矮 32＋8×2＝48；圓角 16＋8＝24（跟裡面的 chip 同心）。
    static let noticeInset: CGFloat = 8
    static let noticeLeading: CGFloat = 14
    static var noticeMinHeight: CGFloat { chipHeight + noticeInset * 2 }
    static var noticeRadius: CGFloat { chipHeight / 2 + noticeInset }
    static let noticeSpacing: CGFloat = 10
    /// 字最多幾行（窄的框裡一句話也要看得完；再長滑過看全文）。
    static let noticeLineLimit = 4
    /// 等你核准那一列的淡強調底：沿用既有玻璃 token 的 accentOpacity（同 ChatGPT 手腳那張強調卡的 0.12），不自創玻璃參數。
    static let attentionAccentOpacity: Double = 0.12

    // MARK: ChatGPT 說明行

    /// 輸入框上方置中一行（只在對象是 ChatGPT 時）。
    static func showsChatGPTCaption(for target: GlobalDMTarget) -> Bool { target == .chatGPT }
    static let captionBottom: CGFloat = 8
}

extension GlobalDMBubble {
    /// 回覆下面那一列「用了 N 條記憶」（system 訊息，status `info|記憶`）。
    var isMemoryUsage: Bool { kind == .note && note?.tag == TatwoMemoryUsageNote.tag }
}

/// 提示列的規則：一句白話（沒有換行、句號只在最後），最多一顆鈕。自測拿各種提示列的真實文字核對。
enum GlobalDMNoticeRule {
    static let maximumActions = 1

    static func isOneSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return false }
        let enders: Set<Character> = ["。", "！", "？", "!", "?"]
        return !trimmed.dropLast().contains { enders.contains($0) }
    }
}

// MARK: - 私訊框自己的小元件（Coder 的送出／停止鈕、工具列不動）

/// 送出：36 的強調色圓、白色上箭頭；不能送時是淡玻璃圓。Return 由文字框送（多個私訊框同時開著時不搶 ⌘↩）。
struct GlobalDMSendButton: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: GlobalDMChatLayout.glyphSize, weight: .semibold))
                .foregroundStyle(enabled ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .frame(width: GlobalDMChatLayout.controlSize, height: GlobalDMChatLayout.controlSize)
                .background {
                    Circle().fill(enabled
                        ? AnyShapeStyle(LiquidGlassTokens.brandAccent)
                        : AnyShapeStyle(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity)))
                }
                .overlay { Circle().strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 停止：36 的圓、白色方塊；顏色同 Coder 的停止鈕（極光用系統紅，fable5 用品牌色）。
struct GlobalDMStopButton: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let action: () -> Void

    private var tint: Color {
        TatwoActivePalette.current.usesGlass ? Color(nsColor: .systemRed) : LiquidGlassTokens.brandAccent
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: GlobalDMChatLayout.stopGlyphSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: GlobalDMChatLayout.controlSize, height: GlobalDMChatLayout.controlSize)
                .background { Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom)) }
                .overlay { Circle().strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("停止")
    }
}

/// 提示列右邊那一顆：玻璃膠囊 chip（32 高、13pt），不是藍色系統鈕。
struct GlobalDMChipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: GlobalDMChatLayout.footnoteSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: GlobalDMChatLayout.chipHeight)
                .background(GlobalDMGlassCapsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// 對象是 ChatGPT 時，輸入框上方置中一行說明＋小鎖頭（原本在頂列名字行）。
struct GlobalDMChatGPTCaption: View {
    static let text = "OS 不記錄對話內容・用你自己的 ChatGPT 帳號"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: GlobalDMChatLayout.captionSize, weight: .semibold))
            Text(Self.text)
                .font(.system(size: GlobalDMChatLayout.footnoteSize))
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.text)
        .accessibilityIdentifier("tatwo.dm.chatgptCaption")
    }
}

/// 回覆中還沒出字：只有打字點點（回覆不帶頭像）；點點與底照舊（同 TATWO 助理頁那一顆）。
struct GlobalDMTypingRow: View {
    let route: ChatRouteChoice?
    let rowWidth: CGFloat
    /// W184 G3b：ChatGPT 的訊息列表（照 ChatGPT）：回答中還沒出字＝左邊一個灰字「思考」。
    @Environment(\.globalDMChatGPTLook) private var chatGPTLook

    var body: some View {
        if chatGPTLook {
            Text("思考")
                .font(.system(size: DMPhone.TextSize.secondary))
                .foregroundStyle(ChatGPTPalette.tertiary)
                .frame(width: rowWidth, alignment: .leading)
                .accessibilityLabel("ChatGPT 正在思考")
                .accessibilityIdentifier("tatwo.dm.chatgpt.thinking")
        } else {
            dots
        }
    }

    private var dots: some View {
        HStack(spacing: 0) {
            ChatTypingDots()
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Spacer(minLength: 0)
        }
        .frame(width: rowWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.map { "\($0.title) 正在回覆" } ?? "正在回覆")
    }
}
