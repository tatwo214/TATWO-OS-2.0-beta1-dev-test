import AppKit
import Combine
import SwiftUI

// W184 G3（使用者 09-29 看了 v2.0.21.029：「chatgpt私訊的輸入筐也不夠像chatgpt 缺少很多實用功能」）：
// ChatGPT 輸入框的元件抽成兩邊都能用——ChatGPT Space（主視窗）與私訊框對象是 ChatGPT 時是同一套：
// 「＋」選單（照網頁版分層）、工具小卡與附件縮圖、思考強度膠囊與面板（面板在 ChatGPTPages.swift）、語音輸入（聽寫）、
// 語音模式／送出／停止那一格、拖進來的提示、即時語音的狀態（ChatGPTVoiceMode）。
// 尺寸與外觀看 ChatGPTComposerMetrics：ChatGPT Space 是 .space（就是原本寫在 Space 輸入框裡的數字，樣子與行為不變）；
// 私訊框是 .dmPhone（手機 token，在 DM/GlobalDMChatGPTComposer.swift 用 DMPhone 組）。

// MARK: - 尺寸與外觀

/// 輸入框元件的尺寸與外觀。ChatGPT Space 照舊（.space）；私訊框用手機 token（.dmPhone：字級 17／15／13／11、36 的圓鈕、32 的 chip、玻璃）。
struct ChatGPTComposerMetrics: Equatable {
    enum Chrome: Equatable {
        /// ChatGPT Space：照 ChatGPT 網頁（圖示鈕沒有底、膠囊滑過淡灰、白色面板、藍色滑桿）。
        case web
        /// App 的玻璃（玻璃圓鈕、玻璃膠囊、玻璃面板、品牌色滑桿；玻璃參數沿用既有 token）。W184 G3b 起私訊框改用 .phone。
        case glass
        /// W184 G3b（使用者 09-29 17:35 真機驗收＋原版 ChatGPT 桌面 App 的截圖）：私訊框的 ChatGPT 對象照原版——中性的白、淺灰、黑
        /// （圖示鈕沒有底、面板白底、模型名是純文字）；滑桿與選中照 App 的強調色（私訊框不要藍色）。
        case phone

        /// 主要的字（膠囊的版本號、附件檔名）：網頁與原版照 ChatGPT 的字色；玻璃用系統語意色。
        var primaryText: Color { self == .glass ? Color.primary : ChatGPTPalette.primary }
        /// 次要的字（一般檔位、⌄、附件類型）。
        var secondaryText: Color { self == .glass ? Color.secondary : ChatGPTPalette.tertiary }
        /// 附件縮圖與檔案卡的底：網頁與原版照 ChatGPT 的白色面板；玻璃上用淡淡的系統語意色。
        var tileSurface: Color { self == .glass ? Color.primary.opacity(0.06) : ChatGPTPalette.surface }
    }

    /// 一顆圓鈕：外框大小、圖示字級。
    struct Round: Equatable {
        var size: CGFloat
        var glyph: CGFloat
    }

    var chrome: Chrome
    var plus: Round
    var dictation: Round
    var voice: Round
    var send: Round
    var stop: Round
    /// 停止鈕有沒有底：ChatGPT Space 只有方塊（照舊）；私訊框跟送出、語音模式一樣是實心圓（照網頁）。
    var stopFilled: Bool
    // 工具小卡
    var chipHeight: CGFloat
    var chipText: CGFloat
    var chipIcon: CGFloat
    var chipClose: CGFloat
    var chipCloseFrame: CGFloat
    // 附件縮圖（圖片方形縮圖、檔案卡）
    var tileImage: CGFloat
    var tileFileWidth: CGFloat
    var tileFileHeight: CGFloat
    var tileFileIcon: CGFloat
    var tileFileGlyph: CGFloat
    var tileRadius: CGFloat
    var tileName: CGFloat
    var tileKind: CGFloat
    var tileClose: CGFloat
    var tileCloseGlyph: CGFloat
    /// 小卡與縮圖之間。
    var chipsSpacing: CGFloat
    // 思考強度膠囊與面板
    var pickerHeight: CGFloat
    var pickerText: CGFloat
    var pickerChevron: CGFloat
    var cardRadius: CGFloat
    /// 面板上的字：標題「High ›」、一列、說明、小字（↺、‹ 思考強度）、›、✓。
    var cardTitle: CGFloat
    var cardRow: CGFloat
    var cardDetail: CGFloat
    var cardSmall: CGFloat
    var cardChevron: CGFloat
    var cardCheck: CGFloat
    // 即時語音的畫面
    var voiceRing: CGFloat
    var voiceDot: CGFloat
    var voiceGlyph: CGFloat
    var voiceTitle: CGFloat
    var voiceStatus: CGFloat
    var voiceButton: CGFloat
    var voiceButtonHeight: CGFloat
    /// 輸入框裡打的字與佔位字（ChatComposerTextView 的 pointSize）。W184 G3b 追加（使用者：「輸入筐字體太大跟chatgpt classic一樣即可」）：
    /// 私訊框照 ChatGPT Space 這一個數字，不另訂。
    var inputText: CGFloat
    // W184 G3b：＋ 小卡與「/」指令（ChatGPTQuickMenu）：字、說明、卡片與每列的圓角、每列的高、左邊圓形圖示底
    var menuText: CGFloat
    var menuCaption: CGFloat
    var menuRadius: CGFloat
    var menuRowRadius: CGFloat
    var menuRowHeight: CGFloat
    var menuDetailRowHeight: CGFloat
    var menuIcon: CGFloat
    // 拖進來的提示
    var dropRadius: CGFloat
    var dropInset: CGFloat
    var dropText: CGFloat

    /// ChatGPT Space（主視窗）：W177 以來輸入框裡的數字，一個都不變（縮圖 144、檔案卡 240×56 同 ChatGPTAttachmentTile 的常數；自測核對）。
    static let space = ChatGPTComposerMetrics(
        chrome: .web,
        plus: Round(size: 28, glyph: 14), dictation: Round(size: 28, glyph: 13), voice: Round(size: 30, glyph: 13),
        send: Round(size: 30, glyph: 14), stop: Round(size: 28, glyph: 11), stopFilled: false,
        chipHeight: 28, chipText: 12, chipIcon: 11, chipClose: 9, chipCloseFrame: 16,
        tileImage: 144, tileFileWidth: 240, tileFileHeight: 56, tileFileIcon: 40, tileFileGlyph: 17, tileRadius: 16,
        tileName: 13, tileKind: 12, tileClose: 22, tileCloseGlyph: 8.5, chipsSpacing: 8,
        pickerHeight: 32, pickerText: 15, pickerChevron: 10, cardRadius: ChatGPTEffortCardMetrics.radius,
        cardTitle: 16, cardRow: 14, cardDetail: 12, cardSmall: 13, cardChevron: 11, cardCheck: 12,
        voiceRing: 150, voiceDot: 96, voiceGlyph: 30, voiceTitle: 17, voiceStatus: 13, voiceButton: 13, voiceButtonHeight: 36,
        inputText: 15,   // W177 起輸入框的字（原本寫在 ChatGPTSpaceMainPane 的 pointSize: 15）
        menuText: 14, menuCaption: 12, menuRadius: 16, menuRowRadius: 10, menuRowHeight: 40, menuDetailRowHeight: 48, menuIcon: 28,   // W184 G3b：＋ 小卡
        dropRadius: 18, dropInset: 16, dropText: 14)
}

extension View {
    /// 有給識別碼才掛（ChatGPT Space 有幾顆鈕原本就沒有識別碼：照舊不掛）。
    @ViewBuilder
    func chatGPTOptionalIdentifier(_ identifier: String?) -> some View {
        if let identifier { accessibilityIdentifier(identifier) } else { self }
    }
}

/// 輸入框裡的圓形圖示鈕：ChatGPT Space 沒有底（照網頁）；私訊框是玻璃圓（同私訊框其他對象的 ＋）。
struct ChatGPTComposerGlyph: View {
    let systemName: String
    let round: ChatGPTComposerMetrics.Round
    var weight: Font.Weight = .regular
    let chrome: ChatGPTComposerMetrics.Chrome

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: round.glyph, weight: weight))
            .frame(width: round.size, height: round.size)
            .background { if chrome == .glass { GlobalDMGlassCircle() } }
            .contentShape(Circle())
    }
}

// MARK: - 「＋」

/// 跟網頁版的「＋」一樣：加入檔案，或選一個 ChatGPT 工具（生圖、搜尋…）。W184 G3b（使用者 09-29 17:35：「＋號也跟chatgpt原版的
/// 快捷小視窗不一樣」）：不再是系統選單——按了開關 ChatGPT 原版那種快捷小視窗（ChatGPTQuickMenu，畫在對話區那一層、
/// 浮在 ＋ 上面）；分層規則照舊在 ChatGPTSpaceModel.plusTools／plusApps／moreTools，列什麼在 ChatGPTQuickMenu.plusSections。
/// 帶不了附件時（私訊框：ChatGPT Space 關著）＋ 變淡、點了只說原因（不用 .disabled：停用的鈕滑過看不到說明）。
struct ChatGPTPlusButton: View {
    @Binding var isOpen: Bool
    let metrics: ChatGPTComposerMetrics
    var identifier = "chatgpt.plus"
    var blocked: String? = nil
    var explain: (String) -> Void = { _ in }

    var body: some View {
        Button {
            if let blocked { explain(blocked) } else { isOpen.toggle() }
        } label: {
            ChatGPTComposerGlyph(systemName: "plus", round: metrics.plus, weight: metrics.chrome == .phone ? .light : .medium,
                                 chrome: metrics.chrome)
                .background {
                    if isOpen { Circle().fill(ChatGPTPalette.pressed) }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(blocked == nil && isOpen ? metrics.chrome.primaryText : Color.secondary)
        .opacity(blocked == nil ? 1 : 0.45)
        .help(blocked ?? "加入檔案或工具")
        .accessibilityLabel("加入檔案或工具")
        .accessibilityHint(blocked ?? "")
        .accessibilityIdentifier(identifier)
        .anchorPreference(key: ChatGPTPopoverAnchorKey.self, value: .bounds) { [.plus: $0] }
    }
}

/// W184 G3b：私訊框的 ChatGPT 對象（照 ChatGPT iPhone App 的輸入框）：圓框放大鏡＝網路搜尋開關（開著＝那張工具小卡）。
/// 開著時用 App 的強調色（不要藍）。
struct ChatGPTToggleGlyph: View {
    let systemName: String
    let selected: Bool
    let metrics: ChatGPTComposerMetrics
    let help: String
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChatGPTComposerGlyph(systemName: systemName, round: metrics.plus, chrome: metrics.chrome)
                .foregroundStyle(selected ? LiquidGlassTokens.brandAccent : Color.secondary)
                .background { if selected { Circle().fill(LiquidGlassTokens.brandAccent.opacity(0.14)) } }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .chatGPTOptionalIdentifier(identifier)
    }
}

// MARK: - 工具小卡與附件縮圖

/// 選了的工具：輸入框裡一張小卡（點 × 拿掉），送出時帶上。
struct ChatGPTToolChip: View {
    let tool: TapTool
    let metrics: ChatGPTComposerMetrics
    var identifier: String? = nil
    let remove: () -> Void

    var body: some View {
        if let identifier {
            // 私訊框：小卡本身是一個容器（裡面的 × 照樣能按），識別碼掛在容器上才找得到。
            chip.accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars").font(.system(size: metrics.chipIcon))
                .foregroundStyle(ChatGlassChipModifier.chipForeground).accessibilityHidden(true)
            Text(tool.title).font(.system(size: metrics.chipText, weight: .medium)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: metrics.chipClose, weight: .bold)).foregroundStyle(ChatGlassChipModifier.chipForeground)
                    .frame(width: metrics.chipCloseFrame, height: metrics.chipCloseFrame).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消 \(tool.title)")
        }
        .padding(.horizontal, 10)
        .frame(height: metrics.chipHeight)
        .chatGlassChip(isSelected: true)
    }
}

/// 輸入框上方的一張附件（ChatGPT Space 的附件、私訊框 ChatGPT 對象的附件都換成它畫；內容只在記憶體）。
struct ChatGPTAttachmentItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let mime: String
    let data: Data

    var isImage: Bool { mime.lowercased().hasPrefix("image/") }
}

extension TapAttachment {
    var composerItem: ChatGPTAttachmentItem { ChatGPTAttachmentItem(id: id, name: name, mime: mime, data: data) }
}

/// 輸入框上方一排：選了的工具小卡＋附件縮圖（附件照 ChatGPT：圖片是方形縮圖、檔案是檔案卡；使用者 09-25「#121 實際應該像 #122」）。
/// 外面包什麼捲動區由各自決定（ChatGPT Space：SwiftUI 橫向捲動；私訊框：滑鼠滾輪也能左右捲的那一種）。
struct ChatGPTComposerChips: View {
    let tool: TapTool?
    let files: [ChatGPTAttachmentItem]
    let metrics: ChatGPTComposerMetrics
    var toolIdentifier: String? = nil
    let removeTool: () -> Void
    let removeFile: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: metrics.chipsSpacing) {
            if let tool {
                ChatGPTToolChip(tool: tool, metrics: metrics, identifier: toolIdentifier, remove: removeTool)
            }
            ForEach(files) { file in
                ChatGPTAttachmentTile(file: file, metrics: metrics) { removeFile(file.id) }
            }
        }
    }

    /// 這一排的高度：有圖片＝縮圖高，只有檔案＝檔案卡高，只有工具小卡＝小卡高（上面多留 8pt 給右上角的 ×）。
    static func rowHeight(files: [ChatGPTAttachmentItem], metrics: ChatGPTComposerMetrics) -> CGFloat {
        if files.contains(where: \.isImage) { return metrics.tileImage + 8 }
        if !files.isEmpty { return metrics.tileFileHeight + 8 }
        return metrics.chipHeight + 2 + 8
    }
}

// MARK: - 語音輸入、語音模式、送出、停止

/// 聽寫（macOS）綁在一個輸入框上（W184 G3；GPT-6 審查 5、查證 #5、#8）：按了先讓那個輸入框所在的視窗成為 key、輸入框成為
/// first responder（停靠的私訊框平常不搶鍵盤焦點，要先 makeKey），0.2 秒後確認還是它（視窗看得到、是 key、焦點還在它身上）
/// 才開始；中途收框、換對象、切走（畫面消失）就取消——不會聽寫進主視窗或別的輸入框。
@MainActor
final class ChatGPTDictation: ObservableObject {
    /// 綁住的輸入框（ChatComposerTextView 的 onTextView 交過來）。
    weak var textView: NSTextView?
    private var pending: Task<Void, Never>?
    var delay: Duration = .milliseconds(200)
    /// 真的開始聽寫（預設送 macOS「開始聽寫」的動作給目前的焦點＝已確認是綁住的輸入框）；自測換成記錄。
    var begin: @MainActor (NSTextView) -> Void = { _ in NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) }

    var isPending: Bool { pending != nil }

    /// 按麥克風：先讓這個輸入框所在的視窗（私訊框的停靠框平常不搶焦點）成為 key、輸入框成為焦點，稍等再開始聽寫；
    /// 開始前再確認一次焦點還在這個輸入框（收框、換對象、切走、焦點被拿走＝不開始，不會聽寫進主視窗的輸入框）。
    func start() {
        cancel()
        guard let textView, let window = textView.window, window.isVisible else { return }
        if !Self.isKey(window) { window.makeKey() }
        window.makeFirstResponder(textView)
        pending = Task { @MainActor [weak self, weak textView, delay] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            guard let textView, let window = textView.window, window.isVisible, Self.isKey(window),
                  window.firstResponder === textView else { return }
            self.begin(textView)
        }
    }

    private static func isKey(_ window: NSWindow) -> Bool { window.isKeyWindow || NSApp.keyWindow === window }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// 語音輸入：用 macOS 內建聽寫把字打進輸入框（跟網頁版的麥克風一樣是「說話變文字」）；綁在 ChatGPTDictation 那一個輸入框上。
struct ChatGPTDictationButton: View {
    let metrics: ChatGPTComposerMetrics
    var identifier: String? = nil
    let dictation: ChatGPTDictation

    var body: some View {
        Button { dictation.start() } label: {
            ChatGPTComposerGlyph(systemName: "mic", round: metrics.dictation, chrome: metrics.chrome)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("語音輸入（macOS 聽寫）")
        .accessibilityLabel("語音輸入")
        .chatGPTOptionalIdentifier(identifier)
    }
}

/// 語音模式（跟網頁版一樣：還沒打字時，送出鍵的位置是黑底圓鈕＋聲波）：開始 ChatGPT 自己的即時語音。
struct ChatGPTVoiceModeButton: View {
    let enabled: Bool
    let metrics: ChatGPTComposerMetrics
    var identifier = "chatgpt.voice.start"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform")
                .font(.system(size: metrics.voice.glyph, weight: .semibold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: metrics.voice.size, height: metrics.voice.size)
                .background(Color.primary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("語音模式")
        .accessibilityLabel("語音模式")
        .accessibilityIdentifier(identifier)
    }
}

/// 停止回答：ChatGPT Space 只有方塊（照舊）；私訊框是實心圓＋方塊（照網頁）。
struct ChatGPTStopButton: View {
    let metrics: ChatGPTComposerMetrics
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill").font(.system(size: metrics.stop.glyph, weight: .bold))
                .modifier(ChatGPTFilledRound(filled: metrics.stopFilled))
                .frame(width: metrics.stop.size, height: metrics.stop.size)
                .background { if metrics.stopFilled { Circle().fill(Color.primary) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("停止")
        .accessibilityLabel("停止回答")
        .chatGPTOptionalIdentifier(identifier)
    }
}

/// 實心圓鈕裡的圖示用底色的反色（同送出、語音模式）；不是實心的照原本的字色。
private struct ChatGPTFilledRound: ViewModifier {
    let filled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled { content.foregroundStyle(Color(nsColor: .windowBackgroundColor)) } else { content }
    }
}

/// 送出鍵那一格，照網頁：回答中＝停止；還沒打字（也沒附件）＝語音模式；有字＝送出（不能送時淡灰）。
struct ChatGPTSendSlot: View {
    enum Kind: Equatable { case stop, voice, send }

    struct Identifiers {
        var stop: String? = nil
        var voice = "chatgpt.voice.start"
        var send = "chatgpt.send"
    }

    /// 這一格現在是哪一顆（ChatGPT Space 與私訊框同一條規則）。
    static func kind(isSending: Bool, isEmpty: Bool) -> Kind {
        isSending ? .stop : (isEmpty ? .voice : .send)
    }

    let isSending: Bool
    let isEmpty: Bool
    let canSend: Bool
    let voiceEnabled: Bool
    let metrics: ChatGPTComposerMetrics
    var identifiers = Identifiers()
    let stop: () -> Void
    let startVoice: () -> Void
    let send: () -> Void

    var body: some View {
        switch Self.kind(isSending: isSending, isEmpty: isEmpty) {
        case .stop:
            ChatGPTStopButton(metrics: metrics, identifier: identifiers.stop, action: stop)
        case .voice:
            ChatGPTVoiceModeButton(enabled: voiceEnabled, metrics: metrics, identifier: identifiers.voice, action: startVoice)
        case .send:
            ChatGPTSendButton(enabled: canSend, metrics: metrics, identifier: identifiers.send, action: send)
        }
    }
}

// MARK: - 思考強度膠囊與面板的位置

/// 思考強度膠囊與面板要的資料與動作。ChatGPT Space：自己的選擇（記住）；私訊框：自己的選擇（只在記憶體，不動 Space 的）。
@MainActor
protocol ChatGPTModelPicking: ObservableObject {
    /// 版本（version:）與其他模型。
    var pickerModels: [TapModel] { get }
    /// 目前會用的模型（面板上的檔位來自它）。
    var pickerModel: TapModel? { get }
    var pickerModelID: String? { get }
    var pickerEffortID: String? { get }
    /// 膠囊與面板標題上的字（「6 Pro」、中文檔位）。
    var pickerLabel: ChatGPTSpaceModel.PickerLabel { get }
    /// 選的跟 ChatGPT 的「上次使用」不一樣：面板右上角出現「↺」、清單最下面有「回到 ChatGPT 的預設」。
    var pickerCanReset: Bool { get }
    func pickerReset()
    func pickerChoose(effort id: String)
    func pickerChoose(model id: String)
}

/// W184 G3b（照 ChatGPT iPhone App 的 ＋ 小卡「認真思考」✓）：兩段式的推理強度——勾起來＝這個模型裡「想比較久」的那一檔
/// （名字是 Thinking／High／思考／高；沒有就是最高檔），取消＝最輕的那一檔（清單第一個）。ChatGPT Space 與私訊框同一條規則。
extension ChatGPTModelPicking {
    /// 「認真思考」要選的那一檔（這個模型沒有檔位可選＝nil，不列這一項）。
    var thinkingEffortID: String? {
        guard let efforts = pickerModel?.efforts, efforts.count > 1 else { return nil }
        let keys = ["think", "high", "思考", "高"]
        let named = efforts.dropFirst().first { effort in
            let text = (effort.id + " " + effort.title + " " + effort.level).lowercased()
            return keys.contains { text.contains($0) }
        }
        return (named ?? efforts.first { $0.isMax } ?? efforts.last)?.id
    }

    /// 勾著：現在這一檔不比「認真思考」那一檔輕（Pro 也算）。
    var thinkingHard: Bool {
        guard let efforts = pickerModel?.efforts, let target = thinkingEffortID,
              let targetIndex = efforts.firstIndex(where: { $0.id == target }) else { return false }
        guard let current = pickerEffortID, let currentIndex = efforts.firstIndex(where: { $0.id == current }) else { return false }
        return currentIndex >= targetIndex
    }

    func toggleThinkingHard() {
        guard let efforts = pickerModel?.efforts, let target = thinkingEffortID, let lightest = efforts.first else { return }
        pickerChoose(effort: thinkingHard ? lightest.id : target)
    }
}

extension ChatGPTSpaceModel: ChatGPTModelPicking {
    var pickerModels: [TapModel] { models }
    var pickerModel: TapModel? { currentModel }
    var pickerModelID: String? { effectiveModelID }
    var pickerEffortID: String? { effectiveEffortID }
    var pickerCanReset: Bool { canResetSelection }
    func pickerReset() { resetSelection() }
    func pickerChoose(effort id: String) { selectedEffortID = id }
    func pickerChoose(model id: String) { selectedModelID = id }
}

extension ChatGPTSpaceModel.PickerLabel {
    /// 照網頁：有檔位＝檔位名（換成中文），帶版本時前面是版本（「6 Pro」）；最高檔紫色；沒有檔位＝模型名（都沒有＝fallback）。
    static func resolve(effort: TapEffort?, model: TapModel?, fallback: String) -> Self {
        if let effort {
            let level = ChatGPTLabels.effort(effort.level.isEmpty ? effort.title : effort.level)
            return Self(version: effort.showsVersion && !effort.version.isEmpty ? effort.version : nil, level: level, isMax: effort.isMax)
        }
        return Self(version: nil, level: model?.title ?? fallback, isMax: false)
    }
}

/// 輸入框裡的膠囊，照 ChatGPT 網頁版（09-25 從網頁 CSS 對過）：平常只有字——一般檔位灰字（High）、帶版本時
/// 版本黑字＋檔位灰字（6 Pro，最高檔紫色）；滑過淡灰底；打開時灰底膠囊、字換成「思考強度」。面板見 ChatGPTEffortCard。
/// 私訊框：玻璃膠囊（同私訊框其他 chip）、13pt。
struct ChatGPTPickerCapsule: View {
    let label: ChatGPTSpaceModel.PickerLabel
    let isOpen: Bool
    let metrics: ChatGPTComposerMetrics
    var identifier = "chatgpt.modelPicker"
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        let chrome = metrics.chrome
        Button(action: toggle) {
            HStack(spacing: 0) {
                // W184 G3c：私訊框的膠囊回到輸入框裡（照 ChatGPT Space 的輸入框）：字跟 Space 的膠囊同一套（頂列那時加的「ChatGPT」拿掉）。
                if isOpen {
                    Text("思考強度").foregroundStyle(chrome.secondaryText)
                } else if let version = label.version {
                    Text(version).foregroundStyle(chrome.primaryText)
                    Text(" " + label.level).foregroundStyle(label.isMax ? ChatGPTPalette.purple : chrome.secondaryText)
                } else {
                    Text(label.level).foregroundStyle(label.isMax ? ChatGPTPalette.purple : chrome.secondaryText)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: metrics.pickerChevron, weight: .semibold))
                    .foregroundStyle(chrome.secondaryText)
                    .padding(.leading, 5)
                    .accessibilityHidden(true)
            }
            .font(.system(size: metrics.pickerText))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: metrics.pickerHeight)
            .background { background }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .anchorPreference(key: ChatGPTPickerAnchorKey.self, value: .bounds) { $0 }
        .help("思考強度與模型")
        .accessibilityLabel("思考強度：\(label.version.map { $0 + " " } ?? "")\(label.level)")
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var background: some View {
        switch metrics.chrome {
        case .web:
            Capsule().fill(isOpen ? ChatGPTPalette.pressed : (hover ? ChatGPTPalette.hover : Color.clear))
        case .glass:
            GlobalDMGlassCapsule()
                .overlay { if isOpen { Capsule().fill(ChatGPTPalette.pressed) } }
        case .phone:
            Capsule().fill(isOpen ? ChatGPTPalette.pressed : (hover ? ChatGPTPalette.hover : Color.clear))
        }
    }
}

/// 面板浮在膠囊正上方、置中對齊（網頁：寬 260，對齊膠囊中心，離膠囊 6pt）；點面板外面就關（Esc 各自接）。
/// 蓋在整個對話區上（ChatGPT Space 的對話區、私訊框的 ChatGPT 那一欄），膠囊的位置從 ChatGPTPickerAnchorKey 來。
struct ChatGPTFloatingCardLayer<Card: View>: View {
    let anchor: Anchor<CGRect>?
    let isOpen: Bool
    let width: CGFloat
    /// W184 G3b：＋ 小卡、「/」小視窗跟著那顆鈕的左邊對齊；思考強度面板照舊置中。
    /// （W184 G3c：私訊框的模型膠囊回到輸入框裡，面板照舊浮在膠囊上面；G3b 那個「浮在頂列下面」拿掉。）
    var leading = false
    let dismiss: () -> Void
    @ViewBuilder let card: () -> Card

    var body: some View {
        GeometryReader { proxy in
            if isOpen, let anchor {
                let rect = proxy[anchor]
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { dismiss() }
                    let x = min(max(8, leading ? rect.minX : rect.midX - width / 2), max(8, proxy.size.width - width - 8))
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        card().layoutPriority(leading ? 1 : 0)   // ＋ 小卡、「/」先拿高度（放不下才縮、可以捲）；思考強度面板照舊
                    }
                    .frame(width: width, height: max(0, rect.minY - 6))
                    .offset(x: x)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
        }
    }
}

// MARK: - 拖進來的提示

/// 照片、檔案拖到對話區上時的虛線框（放開就加入）。
struct ChatGPTDropHighlight: View {
    let metrics: ChatGPTComposerMetrics

    var body: some View {
        RoundedRectangle(cornerRadius: metrics.dropRadius, style: .continuous)
            .strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .background(LiquidGlassTokens.brandAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: metrics.dropRadius, style: .continuous))
            .overlay {
                Label("放開就加入照片或檔案", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: metrics.dropText, weight: .medium))
            }
            .padding(metrics.dropInset)
            .allowsHitTesting(false)
    }
}

// MARK: - 即時語音

/// 語音畫面要的狀態（ChatGPT Space、私訊框）。
@MainActor
protocol ChatGPTVoiceShowing: ObservableObject {
    var voiceLive: Bool { get }
    var voiceStatus: String { get }
    /// 正在結束（還沒確認麥克風停了）：「結束語音」鈕留著，再按一次＝直接關掉語音那一頁。
    var voiceStopping: Bool { get }
    func stopVoice()
}

/// ChatGPT Space 的語音畫面照舊看 Space 自己（Space 把 ChatGPTVoiceMode 的變動轉發出去）。
extension ChatGPTSpaceModel: ChatGPTVoiceShowing {}

/// 即時語音：網頁的語音模式在 Pod 裡跑，這裡管開始、每 2 秒問一次狀態、結束（ChatGPT Space 與私訊框各一份，同一套規則）。
/// W184 G3（GPT-6 審查 2、4；查證 #1、#3、#4）：
/// - 開始之前先在 ChatGPTTap 佔住語音（VoiceClaim）：另一邊佔著、或有回答在跑就開不了；兩邊的聲波鈕都看它。
/// - 結束要確認：送結束、查狀態不是 live 才算；兩輪都沒確認就關掉語音那一頁（Pod）——不會宣告結束卻留著麥克風。
///   結束中「結束語音」鈕一直在，再按一次＝直接關掉那一頁。
/// - 收尾只認這次語音自己的那一則：開始時的對話，或開始時是新對話、live 期間看到的那一則；網頁後來換到別則不算。
/// - 連線中就按了結束：晚回來的「開始」作廢；語音還在自己名下或已經沒人拿著才補送一次結束（09-25 實機、審查 #12）。
@MainActor
final class ChatGPTVoiceMode: ObservableObject, ChatGPTVoiceShowing {
    @Published private(set) var voiceActive = false
    @Published private(set) var voiceLive = false
    @Published private(set) var voiceStatus = ""
    @Published private(set) var voiceStopping = false
    private var voiceWatch: Task<Void, Never>?
    private var voiceLimit: Task<Void, Never>?
    /// 每次開始／結束加一；結束之後才回來的「開始」結果作廢。
    private var voiceSession = 0
    private let tap: ChatGPTTap
    private let owner = UUID()
    private var claim: ChatGPTTap.VoiceClaim?
    /// 「開始」還在網頁那邊跑（還沒回來）的那一次：這段期間不放掉語音，回來了確認結束再放。
    private var pendingStart: ChatGPTTap.VoiceClaim?
    /// 正在結束時使用者按了「直接關掉」（關掉語音那一頁）。
    private var forcedByUser = false
    /// 語音開始時的那一則（nil＝新對話）；新對話時 live 期間看到的那一則。
    private var startedIn: String?
    private var liveConversation: String?
    /// 語音在哪一則對話（ChatGPT Space：正在看的那則；私訊框：它自己那則；nil＝新對話）。
    var conversation: @MainActor () -> String? = { nil }
    /// 語音結束了（確認停了，或關掉了語音那一頁）：帶這次語音自己的那一則。
    var finished: @MainActor (String?) -> Void = { _ in }
    /// 結束的每一步最多等多久（自測縮短）。
    var stopTimeout: Duration = .seconds(6)
    var stateTimeout: Duration = .seconds(4)
    /// 啟動期限與輪詢間隔可供隔離自測縮短。
    var startTimeout: Duration = .seconds(12)
    var statePause: Duration = .seconds(2)
    var stopPause: Duration = .milliseconds(400)
    /// 最後一次怎麼結束的：confirmed＝網頁確認停了；forced＝網頁沒確認，關掉了語音那一頁。
    private(set) var lastEnd: ChatGPTTap.VoiceEnd?

    /// 這一邊拿著語音時，另一邊看到的那一句（W184 G3 第三輪：「ChatGPT Space 的語音模式還開著」）。
    let holderNotice: String

    init(tap: ChatGPTTap, holderNotice: String = "另一邊的語音模式還開著") {
        self.tap = tap
        self.holderNotice = holderNotice
    }

    /// 聲波鈕可不可按：自己沒在語音、TAP 沒人拿著語音、沒有回答在跑或排隊。
    var canStart: Bool { !voiceActive && tap.voiceStartBlocker == nil }

    /// 語音現在在這一邊手上（含「開始」還沒回來、正在確認結束）。
    var holdsVoice: Bool { claim != nil && tap.voiceClaim == claim }

    @discardableResult
    func startVoice() -> Bool {
        // 另一邊按「結束那邊的語音」＝走這一邊自己的確認結束（畫面跟著收）。
        guard !voiceActive, let claim = tap.claimVoice(owner: owner, holderNotice: holderNotice,
                                                          onEndRequest: { [weak self] in self?.endVoice() }) else { return false }
        self.claim = claim
        voiceActive = true
        voiceLive = false
        voiceStopping = false
        lastEnd = nil
        voiceStatus = "連線中…（第一次會詢問麥克風權限）"
        let startedIn = conversation()
        self.startedIn = startedIn
        liveConversation = nil
        pendingStart = claim
        forcedByUser = false
        voiceSession += 1
        let session = voiceSession
        limitAfterPermission(claim, session: session)
        Task {
            do {
                let state = try await tap.voice(start: startedIn, claim: claim)
                if pendingStart == claim { pendingStart = nil }
                guard session == voiceSession, voiceActive, !voiceStopping else {
                    await lateStart(claim)
                    return
                }
                voiceLive = state.live
                if state.live { voiceLimit?.cancel() }
                if state.live, startedIn == nil, let id = state.conversationID { liveConversation = id }
                voiceStatus = state.live ? "正在聆聽，直接說話" : "還沒開始：請確認麥克風權限"
                watchVoice(claim: claim)
            } catch {
                if pendingStart == claim { pendingStart = nil }
                guard session == voiceSession, voiceActive, !voiceStopping else {
                    await lateStart(claim)
                    return
                }
                closeVoice(claim, reason: "語音沒開起來：\(error.localizedDescription.components(separatedBy: .newlines).joined(separator: " "))")
            }
        }
        return true
    }

    /// 晚回來的「開始」（已經按了結束，或畫面已經收尾）：語音還在自己名下，就再確認結束一次（送結束、查狀態，
    /// 沒確認就關掉語音那一頁）；已經沒人拿著＝Pod 關過，網頁早就沒了；別人拿著的語音不動。自己已經收尾了才放掉。
    private func lateStart(_ claim: ChatGPTTap.VoiceClaim) async {
        if tap.voiceClaim == claim {
            let result = await tap.endVoice(claim: claim, stopTimeout: stopTimeout, stateTimeout: stateTimeout, pause: stopPause)
            if result == .forced { lastEnd = .forced }
        }
        if !voiceActive, self.claim == claim { release() }
    }

    private func watchVoice(claim: ChatGPTTap.VoiceClaim) {
        voiceWatch?.cancel()
        voiceWatch = Task { @MainActor [weak self] in
            var wasLive = self?.voiceLive == true
            var misses = 0
            while let self, self.voiceActive, !self.voiceStopping, !Task.isCancelled {
                try? await Task.sleep(for: self.statePause)
                guard !Task.isCancelled, self.voiceActive, !self.voiceStopping else { return }
                // Pod 關過（語音被放掉）：網頁沒了，麥克風早就停了。
                guard self.tap.voiceClaim == claim else { self.finish(.confirmed); return }
                guard let state = try? await self.tap.voiceState(timeout: self.stateTimeout) else {
                    guard self.claim == claim, !self.voiceStopping else { return }
                    if wasLive { misses += 1 }
                    guard wasLive && misses >= 3 else { continue }
                    self.closeVoice(claim, reason: "語音已停止：網頁狀態沒有回應"); return
                }
                guard self.voiceActive, !self.voiceStopping, self.tap.voiceClaim == claim else { return }
                misses = 0
                self.voiceLive = state.live
                if state.live {
                    self.voiceLimit?.cancel()
                    wasLive = true
                    if self.startedIn == nil, self.liveConversation == nil, let id = state.conversationID { self.liveConversation = id }
                    self.voiceStatus = "正在聆聽，直接說話"
                } else if wasLive {
                    // 網頁自己結束了語音（例如在 ChatGPT 那邊按了結束）：查到不是 live 了才收尾。
                    if let id = state.conversationID { self.adoptIfUnseen(id) }
                    self.finish(.confirmed)
                    return
                }
            }
        }
    }

    /// 按「結束語音」、Esc：開始結束；結束中再按一次＝直接關掉語音那一頁（網頁沒回也一定停）。
    func stopVoice() {
        guard voiceActive, let claim else { return }
        if voiceStopping {
            forcedByUser = true
            tap.forceEndVoice(claim)
            return
        }
        endVoice()
    }

    /// 看不到了（收框、換對象、切到 Browser、倒放、換形態）：結束語音；已經在結束就不重複。
    func endVoice() {
        guard voiceActive, !voiceStopping, let claim else { return }
        voiceStopping = true
        voiceStatus = "正在結束語音…"
        voiceSession += 1
        voiceWatch?.cancel()
        limit(claim, after: .seconds(3), reason: "語音已停止：停止逾時，已關閉語音頁面")
        Task {
            let result = await tap.endVoice(claim: claim, stopTimeout: stopTimeout, stateTimeout: stateTimeout, pause: stopPause,
                                            seen: { [weak self] id in self?.adoptIfUnseen(id) })
            guard self.claim == claim else { return }
            finish(forcedByUser ? .forced : result)
        }
    }

    /// 新對話講完馬上結束（live 時還沒看到編號）：用確認停了那一刻網頁所在的那一則（語音一直拿著 Pod，別人換不了頁）。
    /// 開始時就在某一則、或 live 時已經看過編號，就不換（只收自己那一則）。
    private func adoptIfUnseen(_ id: String) {
        if startedIn == nil, liveConversation == nil { liveConversation = id }
    }

    private func finish(_ result: ChatGPTTap.VoiceEnd) {
        guard voiceActive else { return }
        voiceWatch?.cancel()
        if pendingStart == nil { voiceLimit?.cancel() }
        // 這一次已經因為晚回來的「開始」關過語音那一頁，就照實記（不蓋成 confirmed）。
        lastEnd = lastEnd == .forced ? .forced : result
        voiceActive = false
        voiceLive = false
        voiceStopping = false
        // 「開始」還沒回來就先不放（回來時確認結束再放），免得另一邊搶到、又被晚到的開始干擾。
        if pendingStart == nil || pendingStart != claim { release() }
        finished(startedIn ?? liveConversation)
    }

    private func limitAfterPermission(_ claim: ChatGPTTap.VoiceClaim, session: Int) {
        tap.voiceReadyToStart = { [weak self] readyClaim in
            guard let self, readyClaim == claim, session == self.voiceSession, self.voiceActive, !self.voiceStopping else { return }
            self.limit(claim, after: self.startTimeout, reason: "語音沒開起來：連線逾時或網頁沒有回應")
        }
    }

    private func limit(_ claim: ChatGPTTap.VoiceClaim, after timeout: Duration, reason: String) {
        voiceLimit?.cancel()
        voiceLimit = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.claim == claim else { return }
            self.closeVoice(claim, reason: reason)
        }
    }

    private func closeVoice(_ claim: ChatGPTTap.VoiceClaim, reason: String) {
        guard self.claim == claim else { return }
        voiceSession += 1
        voiceStatus = reason
        pendingStart = nil
        tap.forceEndVoice(claim)
        finish(.forced)
        release()
    }

    private func release() {
        if let claim { tap.releaseVoice(claim) }
        claim = nil
    }
}
