import AppKit
import SwiftUI
import UniformTypeIdentifiers

// W184 G3（使用者 09-29 看了 v2.0.21.029：「chatgpt私訊的輸入筐也不夠像chatgpt 缺少很多實用功能」）：
// 私訊框對象是 ChatGPT 時，輸入框＝ChatGPT Space 的輸入框——同一套共用元件（TAP/ChatGPTComposerKit.swift、ChatGPTPages.swift），
// 私訊框用手機 token（.dmPhone）：
// - ＋：照網頁版分層的選單（前 4 個有名次的工具、最近用過的 App、其他收進「更多」）＋加入照片和檔案（＋私訊框原本的貼上剪貼簿圖片）。
// - 選了工具＝輸入框裡一張小卡（點 × 拿掉），送出時帶到 ChatGPT（同 ChatGPT Space：TAP 的 tool／網頁的 hint）。
// - 貼上、拖進來的照片與檔案（含「照片」App 的檔案承諾）：輸入框上方的附件縮圖，可以拿掉。
// - 思考強度膠囊與面板在輸入框裡（字照網頁「6 Pro」、中文檔位）；資料是 GlobalDMStore 的 chatGPTCatalog／chatGPTChoice（只在記憶體）。
// - 語音模式（ChatGPT 的即時語音）；送出鍵那一格照網頁：回答中＝停止、空白＝語音模式、有字＝送出（不能送時淡灰）。
//   W184 G3b 追加（使用者：「只留ai對話 不用麥克風輸入法」）：私訊框不放聽寫（麥克風）鈕；ChatGPT Space 的聽寫照舊。
//   打的字與佔位字照 ChatGPT Space 的輸入框（ChatGPTComposerMetrics.space.inputText；使用者：「輸入筐字體太大跟chatgpt classic一樣即可」）。
// 外框（說明行、玻璃膠囊、同心圓角、內外距）是 GlobalDMComposer 的，其他對象的輸入框不變。字級只用 DMPhone 的 17／15／13／11。

// MARK: - 私訊框的尺寸（手機 token）

extension ChatGPTComposerMetrics {
    /// 私訊框：字級只用 17／15／13／11；＋、語音模式、送出、停止是 36 的圓（DMPhone.smallControl，同其他對象的 ＋／送出）；
    /// 聽寫那一格私訊框不用（W184 G3b 追加拿掉聽寫鈕；欄位是共用的，數字照 token 留著）；
    /// 工具小卡、思考強度膠囊 32 高（DMPhone.chipHeight）；玻璃。DMPhone 沒有的值用 token 組（寫在旁邊）。
    static let dmPhone: ChatGPTComposerMetrics = {
        let round = DMPhone.smallControl
        return ChatGPTComposerMetrics(
            chrome: .phone,   // W184 G3b：照 ChatGPT iPhone App（中性、圖示鈕沒有底、面板照主題）；滑桿與選中照 App 的強調色
            plus: Round(size: round, glyph: DMPhone.TextSize.body),
            dictation: Round(size: round, glyph: DMPhone.TextSize.body),
            voice: Round(size: round, glyph: DMPhone.TextSize.secondary),
            send: Round(size: round, glyph: DMPhone.TextSize.body),
            stop: Round(size: round, glyph: DMPhone.TextSize.footnote),
            stopFilled: true,
            chipHeight: DMPhone.chipHeight, chipText: DMPhone.TextSize.footnote, chipIcon: DMPhone.TextSize.caption,
            chipClose: DMPhone.TextSize.caption,
            chipCloseFrame: DMPhone.chipHeight - 8,                 // 24：小卡裡上下各留 4
            tileImage: round * 2,                                   // 72：兩顆圓鈕高（Space 144 在 466 寬的框裡太大）
            tileFileWidth: round * 5,                               // 180
            tileFileHeight: round + 16,                             // 52：36 的類型方塊＋上下各 8
            tileFileIcon: round, tileFileGlyph: DMPhone.TextSize.body,
            tileRadius: DMPhone.chipHeight / 2,                     // 16：同 chip 的圓角（Space 也是 16）
            tileName: DMPhone.TextSize.footnote, tileKind: DMPhone.TextSize.caption,
            tileClose: DMPhone.chipHeight - 8, tileCloseGlyph: DMPhone.TextSize.caption,
            chipsSpacing: GlobalDMChatLayout.composerItemSpacing,
            // W184 G3b 第二輪（主導）：模型膠囊的字級跟 ChatGPT Space 的模型膠囊一樣（15；W184 G3c 起膠囊在輸入框裡）。
            pickerHeight: DMPhone.chipHeight, pickerText: DMPhone.TextSize.secondary, pickerChevron: DMPhone.TextSize.caption,
            cardRadius: DMPhone.cardRadius,
            cardTitle: DMPhone.TextSize.body, cardRow: DMPhone.TextSize.secondary, cardDetail: DMPhone.TextSize.footnote,
            cardSmall: DMPhone.TextSize.footnote, cardChevron: DMPhone.TextSize.caption, cardCheck: DMPhone.TextSize.footnote,
            voiceRing: DMPhone.touch * 3,                           // 132
            voiceDot: DMPhone.touch * 2,                            // 88
            voiceGlyph: (DMPhone.touch * 2 / 3).rounded(),          // 29：聲波圖示跟著圓（圖案，不是字）
            voiceTitle: DMPhone.TextSize.body, voiceStatus: DMPhone.TextSize.footnote,
            voiceButton: DMPhone.TextSize.footnote, voiceButtonHeight: DMPhone.touch,
            inputText: ChatGPTComposerMetrics.space.inputText,     // 15：照 ChatGPT Space 的輸入框（W184 G3b 追加），不另訂
            // W184 G3b：＋ 小卡（照 iPhone App：一行 17 的字、36 的圓形圖示底、每列 44＋8）
            menuText: DMPhone.TextSize.body, menuCaption: DMPhone.TextSize.footnote, menuRadius: DMPhone.cardRadius,
            menuRowRadius: DMPhone.chipHeight / 2, menuRowHeight: DMPhone.touch + 8, menuDetailRowHeight: DMPhone.touch + 16,
            menuIcon: round,
            dropRadius: DMPhone.cardRadius, dropInset: DMPhone.margin, dropText: DMPhone.TextSize.secondary)
    }()

    /// 自測核對用：這一套裡所有「字」的字級（圖示鈕裡的圖示也算，同房 C 的 glyphSize）。
    var textSizes: [CGFloat] {
        [plus.glyph, dictation.glyph, voice.glyph, send.glyph, stop.glyph, chipText, chipIcon, chipClose, tileFileGlyph, tileName, tileKind,
         tileCloseGlyph, pickerText, pickerChevron, cardTitle, cardRow, cardDetail, cardSmall, cardChevron, cardCheck, voiceTitle,
         voiceStatus, voiceButton, inputText, menuText, menuCaption, dropText]
    }
}

extension GlobalDMAttachment {
    /// ChatGPT 對象的附件都在記憶體（data）：畫成 ChatGPT 的縮圖／檔案卡。
    var composerItem: ChatGPTAttachmentItem { ChatGPTAttachmentItem(id: id, name: name, mime: mime, data: data ?? Data()) }
}

// MARK: - 輸入框裡的三層

/// 私訊框對象是 ChatGPT 時，GlobalDMComposer 的玻璃膠囊裡放這三層（ChatGPT Space 輸入框的元件，手機 token）：
/// 上面一排工具小卡與附件縮圖（有才出現；Coder 清單開著時收起）；中間 17pt 的字（Return 送出、Shift-Return 換行、組字中不送、
/// 長到約 5 行再捲）；下面一排 ＋…網路搜尋、思考強度膠囊、語音模式／送出／停止（W184 G3c；私訊框不放聽寫）。
struct GlobalDMChatGPTComposerLayers: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var session: ChatGPTConversationSession
    @ObservedObject var tap: ChatGPTTap
    /// W184 G3：語音開著時撤掉輸入框焦點（GPT-6 審查 7）。
    @ObservedObject var voice: ChatGPTVoiceMode
    let placeholder: String
    /// ChatGPT Space 的 ChatGPT 分頁開著（關著＝送不出去、＋ 變淡）。
    let canSend: Bool
    /// Coder 清單開著：小卡收起、字只留一行（草稿與附件都在）。
    let folded: Bool
    @Binding var textHeight: CGFloat
    @Binding var focused: Bool
    /// W184 G3c（GPT-6 審查 #3）：抽屜打開前輸入框有焦點＝抽屜收起時還給它；輸入框本身（看有沒有在組字）。
    @State private var refocusAfterDrawer = false
    @State private var textView = GlobalDMWeakTextView()

    init(store: GlobalDMStore, session: ChatGPTConversationSession, placeholder: String, canSend: Bool, folded: Bool,
         textHeight: Binding<CGFloat>, focused: Binding<Bool>) {
        _store = ObservedObject(wrappedValue: store)
        _session = ObservedObject(wrappedValue: session)
        _tap = ObservedObject(wrappedValue: session.tap)
        _voice = ObservedObject(wrappedValue: session.voice)
        self.placeholder = placeholder
        self.canSend = canSend
        self.folded = folded
        _textHeight = textHeight
        _focused = focused
    }

    var body: some View {
        let metrics = ChatGPTComposerMetrics.dmPhone
        let draft = Binding(get: { store.draft(for: .chatGPT) }, set: { store.setDraft($0, for: .chatGPT) })
        let files = store.attachments(for: .chatGPT).map(\.composerItem)
        let tool = store.chatGPTTool
        let textFrame = folded ? GlobalDMChatLayout.inputMinimumHeight
            : min(GlobalDMChatLayout.inputMaximumHeight, max(GlobalDMChatLayout.inputMinimumHeight, textHeight))
        VStack(alignment: .leading, spacing: GlobalDMChatLayout.composerLayerSpacing) {
            if !folded, tool != nil || !files.isEmpty {
                // 放不下就左右捲（同其他對象的附件列：滑鼠滾輪也能捲、兩端淡出）。
                GlobalDMHorizontalScroller {
                    ChatGPTComposerChips(tool: tool, files: files, metrics: metrics, toolIdentifier: "tatwo.dm.tool",
                                         removeTool: { store.chooseChatGPTTool(nil) }, removeFile: { store.removeAttachment($0) })
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                }
                .frame(height: ChatGPTComposerChips.rowHeight(files: files, metrics: metrics))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("附件")
                .accessibilityIdentifier("tatwo.dm.attachments")
            }
            ChatComposerTextView(text: draft, contentHeight: $textHeight, isFocused: focused,
                placeholder: placeholder, isMonospaced: false,
                minimumHeight: GlobalDMChatLayout.inputMinimumHeight,
                maximumHeight: GlobalDMChatLayout.inputMaximumHeight,
                onSubmit: { _ = store.send() }, onFocusChange: { focused = $0 },
                // W184 G3b：「/」指令小視窗開著時上下鍵選、Enter 選定（沒開著就照常打字、送出）。
                onSuggestionKey: { store.handleChatGPTSlashKey($0) },
                onPasteImage: { store.pasteAttachment(from: $0) },
                accessibilityTextLabel: "私訊內容", allowsProgrammaticBlur: true,
                pointSize: metrics.inputText, slashCommands: [],   // W184 G3b 追加：照 ChatGPT Space 的輸入框（15）
                acceptsPhotoDrags: true,
                accessibilityHidden: store.isChatGPTDrawerOpen,
                onTextView: { textView.view = $0 },   // W184 G3c：抽屜打開時看有沒有在組字
                // W184 G3b 第二輪（審查 #6）：「/」清單只拿沒修飾鍵的 ↑↓ 與 Enter；組字中、←→、Shift 選取照常給輸入框。
                suggestionKeysVerticalOnly: true)
                .frame(height: textFrame)
                .accessibilityIdentifier("tatwo.dm.input")
                .id(GlobalDMTarget.chatGPT)
                .anchorPreference(key: ChatGPTPopoverAnchorKey.self, value: .bounds) { [.slash: $0] }
            // W184 G3b（照 ChatGPT iPhone App 的輸入框）：左＝＋（＋ 小卡）；右＝圓框放大鏡（網路搜尋開關）、語音模式／送出／停止
            // （W184 G3b 追加：拿掉聽寫的麥克風，只留跟 AI 對話的語音模式）。
            // W184 G3c（使用者：「chatgpt duo輸入筐…功能鍵也不全」）：功能鍵照 ChatGPT Space 的輸入框補齊——模型與思考強度膠囊回到這裡
            // （同一個 ChatGPTPickerCapsule；點了開 Space 那種推理強度小卡，浮在膠囊上面）；聽寫麥克風照舊不放。
            HStack(spacing: GlobalDMChatLayout.composerItemSpacing) {
                ChatGPTPlusButton(isOpen: Binding(get: { store.isChatGPTPlusOpen }, set: { store.setChatGPTPlusOpen($0) }),
                                  metrics: metrics, identifier: "tatwo.dm.attach", blocked: store.attachmentBlock(for: .chatGPT),
                                  explain: { store.showNotice($0) })
                    .padding(.leading, GlobalDMChatLayout.plusOutset)
                Spacer(minLength: 4)
                // W184 G3b 第二輪：網路搜尋只用 ChatGPT 那邊列出來的那一個；還沒讀到＝變淡、按了說一句（不自己編）。
                ChatGPTToggleGlyph(systemName: "magnifyingglass.circle", selected: store.chatGPTWebSearchOn, metrics: metrics,
                                   help: store.chatGPTWebSearchTool == nil ? "還沒讀到 ChatGPT 的「網路搜尋」" : "網路搜尋",
                                   identifier: "tatwo.dm.webSearch") { store.toggleChatGPTWebSearch() }
                    .opacity(store.chatGPTWebSearchTool == nil && !store.chatGPTWebSearchOn ? 0.45 : 1)
                ChatGPTPickerCapsule(label: store.pickerLabel, isOpen: store.isChatGPTModelCardOpen, metrics: metrics,
                                     identifier: "tatwo.dm.model") { store.toggleChatGPTModelCard() }
                    .disabled(!store.canChooseModel)
                    .layoutPriority(1)   // 窄的時候先縮空白，模型名不被擠掉
                ChatGPTSendSlot(isSending: session.isSending, isEmpty: !store.hasContentToSend,
                                canSend: canSend && store.hasContentToSend && !voice.voiceActive,
                                voiceEnabled: canSend && session.canStartVoice && store.chatGPTColumnOnScreen, metrics: metrics,
                                identifiers: .init(stop: "tatwo.dm.stop", voice: "tatwo.dm.voice", send: "tatwo.dm.send"),
                                stop: { store.stop() }, startVoice: { store.startChatGPTVoice() }, send: { _ = store.send() })
            }
            .frame(height: GlobalDMChatLayout.controlSize)
        }
        // 「/」後面的字變了：鍵盤指著的那一列回到第一列。
        .onChange(of: store.chatGPTSlashQuery) { _, _ in store.chatGPTSlashIndex = 0 }
        // 以指令輸入判斷，不以匹配結果判斷：舊清單漏掉 App 時仍須刷新；打字與清單更新不連續重讀。
        .onChange(of: store.chatGPTSlashQuery != nil, initial: true) { _, active in
            if active { store.refreshChatGPTToolCatalog() }
        }
        // 語音開著：撤掉輸入框焦點（打字、Return 不會送；store／session／TAP 另外也擋）。
        .onChange(of: voice.voiceActive) { _, active in
            if active { focused = false }
        }
        // W184 G3c（GPT-6 審查 #3）：抽屜蓋住輸入框時，輸入框不收字、不送出：撤掉焦點（送出入口 store.send 另外擋）；組字中（輸入法的
        // 候選字還沒選完）不搶，等字選完再撤，候選字不丟（組字中的 Return 是給輸入法的，不會送出）。收起時焦點還給輸入框，草稿本來就留著。
        .onChange(of: store.isChatGPTDrawerOpen) { _, open in
            if open {
                if focused { refocusAfterDrawer = true }
                blurForDrawer()
            } else if refocusAfterDrawer {
                refocusAfterDrawer = false
                if !voice.voiceActive { focused = true }
            }
        }
    }

    /// 抽屜打開：輸入框在組字就等選完字（每 80ms 看一次），抽屜還開著才撤焦點；鍵盤打開的抽屜自己把焦點拿進搜尋欄（不用撤）。
    private func blurForDrawer() {
        Task { @MainActor in
            while store.isChatGPTDrawerOpen, textView.view?.hasMarkedText() == true {
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard store.isChatGPTDrawerOpen, !store.chatGPTDrawerKeyboard else { return }
            focused = false
        }
    }
}

/// W184 G3c：輸入框的 NSTextView（弱引用；抽屜打開時看有沒有在組字；只在主執行緒用）。
final class GlobalDMWeakTextView {
    weak var view: NSTextView?
}

// MARK: - ChatGPT 那一欄上面的幾層（面板、語音、拖進來）

/// 蓋在私訊框 ChatGPT 那一欄上（對話＋輸入框）：思考強度面板浮在輸入框裡那顆膠囊正上方（點外面關、Esc 關）；語音模式開著時蓋上語音畫面；
/// 照片、檔案拖到對話區上＝附件（同 ChatGPT Space 的對話區）。
struct GlobalDMChatGPTPaneLayers: ViewModifier {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var voice: ChatGPTVoiceMode
    @State private var dropTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let metrics = ChatGPTComposerMetrics.dmPhone
        content
            .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
                store.attachChatGPT(providers: providers)
            }
            .overlay {
                if dropTargeted { ChatGPTDropHighlight(metrics: metrics) }
            }
            // W184 G3c：思考強度與模型面板浮在輸入框裡那顆膠囊上面、置中對齊（同 ChatGPT Space）；點外面收、Esc 收。
            // 膠囊的位置不再往上傳（內橫兩欄各有一顆，各自的面板只在自己那一欄）。
            .overlayPreferenceValue(ChatGPTPickerAnchorKey.self) { anchor in
                ChatGPTFloatingCardLayer(anchor: anchor, isOpen: store.target == .chatGPT && store.isChatGPTModelCardOpen && store.canChooseModel,
                                         width: ChatGPTEffortCardMetrics.width, dismiss: { store.closeChatGPTModelCard() }) {
                    ChatGPTEffortCard(model: store, metrics: metrics) { store.closeChatGPTModelCard() }
                }
            }
            .transformPreference(ChatGPTPickerAnchorKey.self) { $0 = nil }
            // W184 G3b：＋ 小卡（浮在 ＋ 上面、左邊對齊）、「/」指令小視窗（浮在輸入框上面）；點外面收、Esc 收（routeEscape）。
            .overlayPreferenceValue(ChatGPTPopoverAnchorKey.self) { anchors in
                ZStack {
                    ChatGPTFloatingCardLayer(anchor: anchors[.plus], isOpen: store.isChatGPTPlusOpen, width: ChatGPTQuickMenu.width,
                                             leading: true, dismiss: { store.setChatGPTPlusOpen(false) }) {
                        ChatGPTQuickMenu(sections: ChatGPTQuickMenu.plusSections(
                                            tools: store.chatGPTCatalog.tools, recentApps: store.chatGPTRecentApps,
                                            selectedToolID: store.chatGPTTool?.id,
                                            thinking: store.thinkingEffortID == nil ? nil : store.thinkingHard,
                                            showingPlugins: store.chatGPTPlusShowingMore,
                                            tatwo: HandsConnectEntry.shared.menuRow),   // W183 R11：外掛程式那一頁最上面「連線」
                                         metrics: metrics, identifier: "tatwo.dm.plusMenu") { store.pickChatGPTPlus($0) }
                    }
                    ChatGPTFloatingCardLayer(anchor: anchors[.slash], isOpen: store.chatGPTSlashOpen, width: ChatGPTQuickMenu.width,
                                             leading: true, dismiss: { _ = store.dismissChatGPTLayers() }) {
                        let tools = store.chatGPTSlashTools
                        ChatGPTQuickMenu(sections: ChatGPTSlash.sections(tools, catalogEmpty: store.chatGPTCatalog.tools.isEmpty,
                                                                         selectedID: store.chatGPTTool?.id),
                                         highlighted: tools.indices.contains(store.chatGPTSlashHighlight)
                                            ? "tool:" + tools[store.chatGPTSlashHighlight].id : nil,
                                         metrics: metrics, identifier: "tatwo.dm.slash") { id in
                            if let picked = tools.first(where: { "tool:" + $0.id == id }) { store.chooseChatGPTSlash(picked) }
                        }
                    }
                }
            }
            .overlay {
                if voice.voiceActive {
                    ChatGPTVoiceOverlay(model: voice, metrics: metrics, identifier: "tatwo.dm.voiceMode",
                                        stopIdentifier: "tatwo.dm.voiceMode.stop")
                }
            }
    }
}

// MARK: - 資料與動作

/// 思考強度膠囊與面板的資料：私訊框自己的選擇（chatGPTChoice，只在記憶體；ChatGPT Space 的選擇不動），
/// 模型清單與「上次使用」是 chatGPTCatalog（跟 ChatGPT Space 同一份）；規則同 ChatGPTModelMenu（送出帶的就是面板上顯示的那一檔）。
extension GlobalDMStore: ChatGPTModelPicking {
    var pickerModels: [TapModel] { chatGPTCatalog.models }
    var pickerModel: TapModel? { ChatGPTModelMenu.effectiveModel(chatGPTCatalog, chatGPTChoice) }
    var pickerModelID: String? { pickerModel?.id }
    var pickerEffortID: String? { ChatGPTModelMenu.effectiveEffort(chatGPTCatalog, chatGPTChoice)?.id }
    var pickerLabel: ChatGPTSpaceModel.PickerLabel {
        .resolve(effort: ChatGPTModelMenu.effectiveEffort(chatGPTCatalog, chatGPTChoice), model: pickerModel, fallback: "預設")
    }
    /// 選過、而且跟 ChatGPT 的「上次使用」不一樣（同 ChatGPT Space 的規則）。
    var pickerCanReset: Bool {
        !chatGPTChoice.isDefault && (pickerEffortID != chatGPTCatalog.defaultEffortID || pickerModelID != chatGPTCatalog.defaultModelID)
    }
    func pickerReset() { chooseChatGPT(ChatGPTModelChoice()) }
    func pickerChoose(effort id: String) { chooseChatGPT(ChatGPTModelChoice(modelID: chatGPTChoice.modelID, effortID: id)) }
    /// 換模型：新模型沒有的檔位回到預設（同 ChatGPT Space）。
    func pickerChoose(model id: String) { chooseChatGPT(ChatGPTModelChoice(modelID: id)) }
}

extension GlobalDMStore {
    func toggleChatGPTModelCard() {
        guard canChooseModel else { return }
        setChatGPTPlusOpen(false)   // W184 G3b：＋ 小卡與面板一次只開一個
        withAnimation(ChatGPTEffortCardMetrics.motion) { isChatGPTModelCardOpen.toggle() }
    }

    func closeChatGPTModelCard() {
        withAnimation(ChatGPTEffortCardMetrics.motion) { isChatGPTModelCardOpen = false }
    }

    /// 語音模式（ChatGPT 的即時語音，在私訊框自己這則對話裡講）。ChatGPT 那一欄不在畫面上（收框、單欄是 Browser、倒放、
    /// 對象不是 ChatGPT、Space 的 ChatGPT 分頁關著）不開；別的地方拿著語音、有回答在跑也不開（session／TAP 判斷）。有開始才回 true。
    @discardableResult
    func startChatGPTVoice() -> Bool {
        guard chatGPTColumnOnScreen else { return false }
        isChatGPTModelCardOpen = false
        return chatGPT.startVoice()
    }

    /// 「＋ › 貼上剪貼簿圖片」（私訊框原本就有的一項）：剪貼簿沒有圖片或檔案就說一句。
    func pasteClipboardForChatGPT() {
        if !pasteAttachment(from: .general, preferText: false) { showNotice("剪貼簿沒有圖片或檔案") }
    }
}
