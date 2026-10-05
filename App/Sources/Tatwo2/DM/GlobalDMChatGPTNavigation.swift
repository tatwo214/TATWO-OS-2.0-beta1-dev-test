import AppKit
import SwiftUI
import UniformTypeIdentifiers

// W184 G3b（使用者 09-29 17:35 真機驗收 .030：「chatgpt沒有新對話、專案、過去對話、/指令」「＋號也跟chatgpt原版的快捷小視窗不一樣」
// 「字的滑動天地改漸出」；17:50 改方向：「ChatGPT私訊鈕版面改這樣」「左列專案改用滑鼠指到左側滑出 跟瀏覽器右側一樣」＋三張 ChatGPT iPhone App 截圖）：
// 私訊框對象是 ChatGPT 時照 ChatGPT iPhone App——
// - 頂列：私訊框左上的頁面圓鈕照舊（切換對象）；它右邊是 ≡（開抽屜）；ChatGPT 那一欄的中間是模型名（純文字，按了開思考強度與模型面板，
//   浮在頂列下面）；右上是新對話（圓框對話泡泡）。截圖中間的「對話｜工作」不放：TAP 一律把網頁切在「對話」、「工作」送不出去（W177），接不上。
//   頁面圓鈕滑鼠指到時向右展開、蓋在 ≡ 上面（≡ 不跟著被推走）；收起來 ≡ 就露出來。
// - 左側抽屜：滑鼠指到私訊框左緣（頂列以下、22 寬的把手帶，同 Browser 右緣的直把手）就從左邊滑出，滑鼠離開抽屜就收；按 ≡ 打開的
//   要點外面、Esc 或再按 ≡ 才收。打開時主畫面往右推（不是蓋在上面）。內容照截圖：頂端「ChatGPT」＋搜尋；圖庫、專案、外掛程式、已排程
//   （到 ChatGPT Space 打開那一頁；截圖的「遠端」「探索」Space 沒有對應的頁，不列）；已釘選；最近的對話；底部「✎ 聊天」＋設定齒輪。
//   資料讀 ChatGPT Space 那一份（ChatGPTConversationDirectory）；點一則＝私訊框自己的對話切到那一則（Space 正在看的那則不動）。
// - 新對話：清空目前這一則（只在記憶體），草稿（字、附件、工具小卡）留在原本那則，回去時還在。回答中、語音開著時不換對話（說一句原因）。
// - 空白時：輸入框上方列「建議」（ChatGPT 給的建議；沒有就是最近 3 則對話）。
// - 「/」指令：輸入框最前面打「/」跳出指令小視窗（ChatGPT 的工具在前、再來是 App），上下鍵選、Enter 選定＝工具小卡；Esc 只收小視窗。

/// 抽屜與建議要的清單（ChatGPT Space 的那一份；自測換成假的）。對話的動作是私訊框自己的（換到那一則、新對話）。
@MainActor
protocol ChatGPTConversationDirectory: ObservableObject {
    /// 已經載入的對話（新到舊）。
    var directoryConversations: [TapConversation] { get }
    /// 專案（資料夾）、釘選（專案或單一對話）、ChatGPT 給的新對話建議。
    var directoryProjects: [TapFolder] { get }
    var directoryProjectsLoadState: ChatGPTListLoadState { get }
    func directoryRetryProjects()
    var directoryPinned: [TapFolder] { get }
    var directorySuggestions: [TapSuggestion] { get }
    var directoryExpandedProjects: Set<String> { get }
    /// 專案裡的對話（還沒讀＝nil）。
    func directoryConversations(inProject id: String) -> [TapConversation]?
    func directoryProjectLoadState(_ id: String) -> ChatGPTListLoadState
    func directoryRetryProject(_ id: String)
    var directoryListLoadState: ChatGPTListLoadState { get }
    func directoryRetryList()
    func directoryToggleProject(_ id: String)
    /// 抽屜、建議出現時：還沒讀過清單就讀一次。
    func directoryPrepare()
    /// 圖庫、外掛程式、已排程：到 ChatGPT Space 打開那一頁（私訊框自己沒有這些頁）。
    func directoryOpen(_ page: ChatGPTPage)
    /// 齒輪：OS 這座 TAP 的設定（連線、登入、休眠）。
    func directoryOpenSettings()
    /// W184 G3b 第二輪（審查 #5）：清單還有沒載入的舊對話（抽屜最後一列「載入更多」）。
    var directoryHasMore: Bool { get }
    func directoryLoadMore() async
    /// 搜尋全部對話（ChatGPT 伺服器搜尋，查得到還沒載入的舊對話）；查不了＝nil（抽屜改成只查已載入的，並說一句）。
    func directorySearch(_ query: String) async -> [TapConversation]?
}


/// W184 G3b 第二輪（審查 #1）：附件開始收的時候是哪一則對話（對話代號，新對話＝""；換過幾次對話）。
struct GlobalDMChatGPTOrigin: Equatable, Sendable {
    let key: String
    let generation: Int
}

// MARK: - 環境值（頂列的 ChatGPT 控制、ChatGPT 的訊息樣子）

private struct GlobalDMChatGPTTopWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct GlobalDMChatGPTLookKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// ChatGPT 那一欄在這支手機上時它的寬（單欄＝整個框、內橫＝左欄；nil＝不是 ChatGPT）：頂列照它排 ≡、模型名、新對話。
    var globalDMChatGPTTopWidth: CGFloat? {
        get { self[GlobalDMChatGPTTopWidthKey.self] }
        set { self[GlobalDMChatGPTTopWidthKey.self] = newValue }
    }

    /// 這個訊息列表是 ChatGPT 的（照 ChatGPT App：自己的泡泡反白、回答中是灰字「思考」）。
    var globalDMChatGPTLook: Bool {
        get { self[GlobalDMChatGPTLookKey.self] }
        set { self[GlobalDMChatGPTLookKey.self] = newValue }
    }
}

/// 一則對話自己的草稿（換到別則時收起來，回來時放回去）。
struct GlobalDMChatGPTDraft: Equatable {
    var text: String
    var files: [GlobalDMAttachment]
    var tool: TapTool?
}

// MARK: - 動作

extension GlobalDMStore {
    /// 網路搜尋（輸入框右下的圓框放大鏡）＝這一張工具小卡（ChatGPT Space 的「網路搜尋」工具，代號 search）。
    static let chatGPTWebSearchToolID = "search"

    var chatGPTWebSearchOn: Bool { chatGPTTool?.id == Self.chatGPTWebSearchToolID }

    /// ChatGPT 那邊有列出「網路搜尋」這個工具（沒有＝放大鏡變淡、按了說一句；不自己編這個工具）。
    var chatGPTWebSearchTool: TapTool? { chatGPTCatalog.tools.first { $0.id == Self.chatGPTWebSearchToolID } }

    /// 放大鏡：開＝選「網路搜尋」這張工具小卡；再按＝拿掉。W184 G3b 第二輪：只用 ChatGPT 讀到的那一個，清單裡沒有就不選、說一句。
    func toggleChatGPTWebSearch() {
        if chatGPTWebSearchOn {
            chooseChatGPTTool(nil)
            return
        }
        guard let tool = chatGPTWebSearchTool else {
            showNotice("還沒讀到 ChatGPT 的「網路搜尋」（連上 ChatGPT 之後就能用）")
            return
        }
        chooseChatGPTTool(tool)
    }

    /// ＋ 的小卡、思考強度面板一次只開一個。
    func setChatGPTPlusOpen(_ open: Bool) {
        let opening = open && !isChatGPTPlusOpen
        isChatGPTPlusOpen = open
        if !open { chatGPTPlusShowingMore = false }
        if open { isChatGPTModelCardOpen = false }
        if opening { refreshChatGPTToolCatalog() }
    }

    /// 換對象、收框：小卡、抽屜都收。
    func closeChatGPTPopovers() {
        isChatGPTPlusOpen = false
        chatGPTPlusShowingMore = false
        isChatGPTDrawerOpen = false
        chatGPTDrawerPinned = false
        chatGPTDrawerKeyboard = false
    }

    /// ＋ 小卡裡點了哪一列（照片、檔案、貼上、外掛程式 ›、‹ 返回、認真思考、某個工具或 App）。
    func pickChatGPTPlus(_ id: String) {
        switch id {
        case "plugins": chatGPTPlusShowingMore = true
        case "back": chatGPTPlusShowingMore = false
        case HandsConnectEntry.menuRowID:   // W183 R11：外掛程式那一頁的「連線」（跟頂列下面那一顆同一個動作）
            setChatGPTPlusOpen(false)
            HandsConnectEntry.shared.tap()
        case "photos":
            setChatGPTPlusOpen(false)
            pickAttachments(imagesOnly: true)
        case "files":
            setChatGPTPlusOpen(false)
            pickAttachments()
        case "thinking":
            toggleThinkingHard()
        default:
            guard id.hasPrefix("tool:"), let tool = chatGPTCatalog.tools.first(where: { "tool:" + $0.id == id }) else { return }
            setChatGPTPlusOpen(false)
            chooseChatGPTTool(tool)
        }
    }

    // MARK: 「/」指令

    /// 「/」指令小視窗要比對的字：對象是 ChatGPT、草稿最前面是「/」、後面還沒有空白或換行；Esc 收起後草稿改了才再出來
    /// （規則在 ChatGPTSlash，ChatGPT Space 的輸入框同一條）。
    var chatGPTSlashQuery: String? {
        guard target == .chatGPT else { return nil }
        return ChatGPTSlash.query(draft(for: .chatGPT), dismissed: chatGPTSlashDismissed)
    }

    /// 清單＝ChatGPT 那邊的工具與 App（TAP 讀到的那一份；跟 ChatGPT Space 同一份）。
    var chatGPTSlashTools: [TapTool] {
        guard let query = chatGPTSlashQuery else { return [] }
        return ChatGPTQuickMenu.slashTools(chatGPTCatalog.tools, query: query)
    }

    /// 開著：有符合的；或 ChatGPT 的清單還沒讀到過（只列一行說明）。
    var chatGPTSlashOpen: Bool {
        ChatGPTSlash.isOpen(query: chatGPTSlashQuery, catalog: chatGPTCatalog.tools, matches: chatGPTSlashTools)
    }

    /// 鍵盤指著的那一列（清單變短時不超出）。
    var chatGPTSlashHighlight: Int {
        let count = chatGPTSlashTools.count
        return count == 0 ? 0 : min(max(chatGPTSlashIndex, 0), count - 1)
    }

    /// 輸入框交來的鍵（只有沒修飾鍵的 ↑↓ 與 Enter；組字中不會交來，見 ChatComposerTextView.suggestionKeysVerticalOnly）：
    /// 清單開著時 ↑↓ 選、Enter 選定（變工具小卡、草稿的「/…」拿掉）；第一列再往上、沒開著就不吃（照常打字、送出）。
    func handleChatGPTSlashKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let tools = chatGPTSlashTools
        guard chatGPTSlashQuery != nil else { return false }
        // 清單只有一行說明（ChatGPT 的清單還沒讀到過）：Enter 不把「/…」當訊息送出。
        if tools.isEmpty { return key == .commit && chatGPTSlashOpen }
        guard let index = ChatGPTSlash.moved(key, index: chatGPTSlashHighlight, count: tools.count) else { return false }
        if key == .commit { chooseChatGPTSlash(tools[index]) } else { chatGPTSlashIndex = index }
        return true
    }

    func chooseChatGPTSlash(_ tool: TapTool) {
        chooseChatGPTTool(tool)
        setDraft("", for: .chatGPT)
        chatGPTSlashIndex = 0
        chatGPTSlashDismissed = nil
    }

    // MARK: 抽屜、換對話、新對話

    /// 回答中、語音開著時不換對話（換了回答會被切掉、語音那一頁會被換走）。
    var chatGPTSwitchBlocker: String? {
        guard let session = chatGPTSessionIfCreated else { return nil }
        if session.voice.voiceActive { return "語音模式開著；結束語音再換對話" }
        if session.isSending { return "ChatGPT 正在回答；等它結束再換對話" }
        return nil
    }

    /// 打開抽屜：pinned＝VoiceOver 按左緣那一格打開（點外面、Esc 才收）；否則是滑鼠指到左緣（離開抽屜就收）。
    /// W184 G3c：頂列的 ≡ 拿掉了（使用者：「我們只要滑鼠指到左側展開即可」）。
    func openChatGPTDrawer(pinned: Bool) {
        guard target == .chatGPT, !isBrowsing else { return }
        setChatGPTPlusOpen(false)
        isChatGPTModelCardOpen = false
        chatGPTDrawerPinned = pinned || (isChatGPTDrawerOpen && chatGPTDrawerPinned)
        guard !isChatGPTDrawerOpen else { return }
        withAnimation(GlobalDMChatGPTDrawerLayout.motion) { isChatGPTDrawerOpen = true }
    }

    func closeChatGPTDrawer() {
        guard isChatGPTDrawerOpen else { return }
        chatGPTDrawerPinned = false
        chatGPTDrawerKeyboard = false
        withAnimation(GlobalDMChatGPTDrawerLayout.motion) { isChatGPTDrawerOpen = false }
    }

    /// 開著就收，收著就打開（釘住；W184 G3c 起沒有 ≡，留給自測與鍵盤輔助用）。
    func toggleChatGPTDrawer() {
        if isChatGPTDrawerOpen { closeChatGPTDrawer() } else { openChatGPTDrawer(pinned: true) }
    }

    /// W184 G3c（GPT-6 審查 #2）：鍵盤開關抽屜（⌘⇧S，同 ChatGPT 的「切換側邊欄」）：打開＝釘住、鍵盤焦點進抽屜的搜尋欄
    /// （↑↓ 選、Return 打開那一則）；收起＝焦點回輸入框（輸入框那一層記得開之前有沒有焦點）。
    func toggleChatGPTDrawerFromKeyboard() {
        if isChatGPTDrawerOpen {
            closeChatGPTDrawer()
            return
        }
        guard target == .chatGPT, !isBrowsing else { return }
        chatGPTDrawerKeyboard = true
        openChatGPTDrawer(pinned: true)
    }

    /// 滑鼠離開抽屜：滑鼠指到左緣打開的就收；釘住的（VoiceOver 打開的）留著。
    func chatGPTDrawerHoverEnded() {
        guard isChatGPTDrawerOpen, !chatGPTDrawerPinned else { return }
        closeChatGPTDrawer()
    }

    /// W184 G3c：右上「臨時對話」（照 ChatGPT）：新對話時開關；在一則對話裡按＝開一則新的臨時對話；在臨時對話裡按＝關掉、
    /// 回到一般的新對話。回答中、語音開著不換（說一句）。開著送出＝ChatGPT 的臨時對話（不存進紀錄；TAP 同 ChatGPT Space 的做法）。
    func toggleChatGPTTemporary() {
        let session = chatGPT
        if let blocker = chatGPTSwitchBlocker {
            showNotice(blocker)
            return
        }
        let turnOn = !session.isTemporary
        // 已經有內容的那一則（一般的、臨時的）不改它的性質：換一則新的，再照要的開或關。
        if session.conversationID != nil || !session.messages.isEmpty {
            guard newChatGPTConversation() else { return }
        }
        session.temporary = turnOn
        if !turnOn { session.temporaryPersonalized = false }
    }

    /// 抽屜點了一則：私訊框自己的對話切到那一則（讀那則的內容，只在記憶體）；原本那則的草稿收起來、那則的草稿放回來。
    /// W184 G3b 第二輪（審查 #3）：同一則讀不到時再點一次＝重讀。
    @discardableResult
    func openChatGPTConversation(_ id: String) -> Bool {
        let session = chatGPT
        if let blocker = chatGPTSwitchBlocker {
            showNotice(blocker)
            return false
        }
        closeChatGPTDrawer()
        guard id != session.conversationID else {
            session.retryLoad()
            return true
        }
        shelveChatGPTDraft(for: session.conversationID)
        chatGPTDraftGeneration += 1
        session.open(conversationID: id)
        unshelveChatGPTDraft(for: id)
        return true
    }

    /// 新對話：清空目前這一則（只在記憶體），草稿留在原本那則。
    @discardableResult
    func newChatGPTConversation() -> Bool {
        let session = chatGPT
        if let blocker = chatGPTSwitchBlocker {
            showNotice(blocker)
            return false
        }
        closeChatGPTDrawer()
        guard session.conversationID != nil || !session.messages.isEmpty else { return true }
        shelveChatGPTDraft(for: session.conversationID)
        chatGPTDraftGeneration += 1
        session.newConversation()
        unshelveChatGPTDraft(for: nil)
        return true
    }

    /// 抽屜的圖庫、外掛程式、已排程：到 ChatGPT Space 打開那一頁（私訊框自己沒有這些頁）。
    func openChatGPTSpacePage<Directory: ChatGPTConversationDirectory>(_ page: ChatGPTPage, in directory: Directory) {
        closeChatGPTDrawer()
        openChatGPTSpace()
        directory.directoryOpen(page)
    }

    private func shelveChatGPTDraft(for conversationID: String?) {
        let current = GlobalDMChatGPTDraft(text: draft(for: .chatGPT), files: attachments(for: .chatGPT), tool: chatGPTTool)
        let key = conversationID ?? ""
        if current.text.isEmpty, current.files.isEmpty, current.tool == nil {
            chatGPTShelf[key] = nil
        } else {
            chatGPTShelf[key] = current
        }
    }

    private func unshelveChatGPTDraft(for conversationID: String?) {
        let saved = chatGPTShelf.removeValue(forKey: conversationID ?? "")
        setDraft(saved?.text ?? "", for: .chatGPT)
        replaceChatGPTAttachments(saved?.files ?? [])
        chatGPTTool = saved?.tool
        chatGPTSlashDismissed = nil
    }
}

// MARK: - 鍵盤入口（W184 G3c，GPT-6 審查 #2）

/// ChatGPT 那一欄的鍵盤入口（照 ChatGPT 自己的快捷鍵）：⌘⇧S＝開關對話清單（抽屜；「切換側邊欄」）、⌘⇧O＝開新聊天。
/// 不撞私訊框既有的：直達鍵是 ⌥⌘＋鍵、換形態 ⌥⌘Tab、Browser 新分頁 ⌥⌘T（都帶 ⌥）；Coder 的 ⌘⇧O 只收主視窗事件。認實體鍵位（跟輸入法無關，同直達鍵）。
/// 私訊框拿著鍵盤、ChatGPT 那一欄在畫面上才收（GlobalDMPanelController.routeChatGPTKeys）。
enum GlobalDMChatGPTKeys {
    static let drawerKeyCode: UInt16 = 1     // S
    static let newChatKeyCode: UInt16 = 31   // O
    static let drawerDisplay = "⌘⇧S"
    static let newChatDisplay = "⌘⇧O"

    static func matches(_ event: NSEvent, keyCode: UInt16) -> Bool {
        event.type == .keyDown && event.keyCode == keyCode
            && event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .shift]
    }
}

// MARK: - 頂列：臨時對話（W184 G3c；≡、模型名、新對話拿掉）

/// 頂列裡 ChatGPT 那一欄的控制（只在對象是 ChatGPT、單欄不是 Browser 時）：右上一顆「臨時對話」。
/// W184 G3c（使用者 09-30 實測 .031）：「chatgpt的展開鈕是多餘的 我們只要滑鼠指到左側展開即可」＝拿掉 ≡（抽屜只靠左緣）；
/// 「右上隱私對話鈕無效 ui也跟原版不同」＝右上那顆照 ChatGPT 原版是「臨時對話」（虛線對話泡泡，ChatGPT Space 同一個圖示），
/// 按了真的開關臨時對話；新對話照舊用抽屜底部的「聊天」。模型與思考強度搬回輸入框（照 ChatGPT Space 的輸入框）。
/// 抽屜沒有按鈕了：VoiceOver 用左緣那一格（tatwo.dm.chatgpt.drawer）。width＝ChatGPT 那一欄的寬（內橫時只在左欄，不跨到右欄）。
struct GlobalDMChatGPTTopControls: View {
    @ObservedObject var store: GlobalDMStore
    /// 看著對話本身（臨時對話開著沒、回答中與語音開著時變淡；回答完馬上恢復）。
    @ObservedObject var session: ChatGPTConversationSession
    let width: CGFloat
    @State private var temporaryChoicePresented = false
    @State private var temporaryAnchor = AssistantModelMenuAnchor()

    var body: some View {
        let blocker = store.chatGPTSwitchBlocker
        let temporary = session.isTemporary
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                store.toggleChatGPTTemporary()
                temporaryChoicePresented = blocker == nil && session.temporary && session.conversationID == nil && session.messages.isEmpty
            } label: {
                ChatGPTTemporaryChatIcon(active: temporary)
                    .frame(width: 22, height: 22)
                    .frame(width: DMPhone.touch, height: DMPhone.touch)
                    .background { GlobalDMGlassCircle(isSelected: temporary) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(blocker == nil ? 1 : 0.45)
            .help(blocker ?? ChatGPTTemporaryChatText.help(active: temporary))
            .accessibilityLabel(ChatGPTTemporaryChatText.label(active: temporary))
            .accessibilityAddTraits(temporary ? .isSelected : [])
            .accessibilityIdentifier("tatwo.dm.chatgpt.temporary")
            .background(AssistantModelMenuAnchorView(anchor: temporaryAnchor))
        }
        .frame(width: width, height: DMPhone.touch)
        // 原生 transient popover 會把再按原鈕的事件當作「收起 popover」吃掉。
        // 同私訊框的模式卡：在框內呈現，點外面只收卡、不攔事件；原鈕仍負責開關。
        .overlay(alignment: .topTrailing) {
            if temporaryChoicePresented {
                ChatGPTTemporaryPersonalizationChoice(width: min(290, width)) {
                    guard store.chatGPTSwitchBlocker == nil, session.conversationID == nil,
                          session.isTemporary, session.messages.isEmpty else { return }
                    session.temporary = true
                    session.temporaryPersonalized = true
                    temporaryChoicePresented = false
                } dismiss: {
                    temporaryChoicePresented = false
                }
                .fixedSize(horizontal: false, vertical: true)
                .liquidGlassPanelSurface(cornerRadius: DMPhone.cardRadius)
                .background(TatwoComposerModeClickAway(anchor: temporaryAnchor) { temporaryChoicePresented = false })
                .frame(width: width, height: 0, alignment: .topTrailing)
                .offset(y: DMPhone.touch + 8)
            }
        }
        .onChange(of: session.isTemporary) { _, active in
            if !active { temporaryChoicePresented = false }
        }
        .onChange(of: session.conversationID) { _, _ in temporaryChoicePresented = false }
        .onChange(of: session.isSending) { _, sending in
            if sending { temporaryChoicePresented = false }
        }
    }
}

/// 44 的玻璃圓鈕（同頂列左上那顆的大小與玻璃）。
struct GlobalDMChatGPTRoundButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DMPhone.TextSize.body, weight: .medium))
                .foregroundStyle(selected ? LiquidGlassTokens.brandAccent : Color.primary)
                .frame(width: DMPhone.touch, height: DMPhone.touch)
                .background { GlobalDMGlassCircle(isSelected: selected) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - 抽屜

enum GlobalDMChatGPTDrawerLayout {
    /// 抽屜寬＝框寬的 78%（最多 340），手機式；W184 G3c：蓋在主畫面上（主畫面不動）。
    static func width(for boxWidth: CGFloat) -> CGFloat { min(340, (boxWidth * 0.78).rounded()) }
    /// 左緣的判斷區（22 寬，頂列以下整個高度；W184 G3c 起不畫把手）。
    static let handleStrip: CGFloat = 22
    static var motion: Animation {
        let c = DMPhone.motionCurve
        return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: DMPhone.Strip.duration)
    }
}

/// 裝著整支手機（頂列＋欄）的那一層：對象是 ChatGPT 時，左緣 22 寬的判斷區指到就從左邊滑出抽屜，蓋在主畫面上
/// （W184 G3c：主畫面不動；點抽屜外面＝收）；滑鼠離開抽屜：指到才開的就收，釘住的留著。
struct GlobalDMChatGPTDrawerLayer<Directory: ChatGPTConversationDirectory>: ViewModifier {
    @ObservedObject var store: GlobalDMStore
    let enabled: Bool
    let directory: Directory

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let drawerWidth = GlobalDMChatGPTDrawerLayout.width(for: proxy.size.width)
            let open = enabled && store.isChatGPTDrawerOpen
            ZStack(alignment: .topLeading) {
                // W184 G3c（使用者：「左側展開時會把對話筐推去右邊修正對話筐為不動」）：抽屜蓋在上面，主畫面（對話與輸入框）不動。
                // GPT-6 審查 #3：抽屜開著時底下被蓋住的不給 VoiceOver（輸入框的鍵盤另外撤、送出入口另外擋）。
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityHidden(open)
                    .overlay {
                        if open {
                            // 抽屜外面的主畫面：點一下＝收抽屜（不點到底下的東西）；滑鼠移到這裡＝離開抽屜（指到才開的就收；
                            // 抽屜滑出來時剛好蓋在指標下、還沒收到「進入」就移走，也照樣收）。
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { store.closeChatGPTDrawer() }
                                .onHover { inside in if inside { store.chatGPTDrawerHoverEnded() } }
                                .accessibilityHidden(true)
                        }
                    }
                ZStack(alignment: .topLeading) {
                    if open {
                        GlobalDMChatGPTDrawer(store: store, session: store.chatGPT, directory: directory)
                            .frame(width: drawerWidth, height: proxy.size.height)
                            .shadow(color: .black.opacity(0.16), radius: 14, x: 4)
                            .onHover { inside in if !inside { store.chatGPTDrawerHoverEnded() } }
                            .transition(.move(edge: .leading))
                    }
                    if enabled, !open {
                        // 左緣的判斷區（頂列以下、22 寬）：指到就滑出。W184 G3c（使用者：「左側展開槓也是多餘的」）：照舊判斷、不畫出來。
                        // 22 寬剛好到 ＋ 的左緣（12＋16−6）為止，輸入框的字、＋ 都不在判斷區裡。VoiceOver 按這一格＝打開（釘住）。
                        Color.clear
                            .frame(width: GlobalDMChatGPTDrawerLayout.handleStrip, height: max(0, proxy.size.height - DMPhone.headerHeight))
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { store.openChatGPTDrawer(pinned: false) } }
                            .accessibilityElement()
                            .accessibilityLabel("對話清單")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { store.openChatGPTDrawer(pinned: true) }
                            .accessibilityIdentifier("tatwo.dm.chatgpt.drawer")
                            .offset(y: DMPhone.headerHeight)
                    }
                }
                // 只裁抽屜這一層（滑進滑出不露到框外、內橫右欄不蓋到左欄）；主畫面不在這裡裁：
                // W184 G3c 訊息列表往上延伸到框的上緣（頂列底下），框本身的圓角照舊裁。
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }
}

/// W184 G3b 第二輪（審查 #2）：內橫右欄的 ChatGPT（頂列的控制是左欄的）：對話抽屜掛在右欄這一格裡，綁右欄自己的 store。
/// （W184 G3c：思考強度與模型面板改成每一欄自己的輸入框上面那一層——GlobalDMChatGPTPaneLayers，膠囊位置不往上傳。）
struct GlobalDMChatGPTTrailingLayers<Directory: ChatGPTConversationDirectory>: ViewModifier {
    @ObservedObject var store: GlobalDMStore
    let enabled: Bool
    let directory: Directory

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(GlobalDMChatGPTDrawerLayer(store: store, enabled: true, directory: directory))
        } else {
            content
        }
    }
}

/// 同上，包成一個畫面（自測直接畫：抽屜打開時主畫面不動、抽屜蓋在上面）。
struct GlobalDMChatGPTDrawerHost<Directory: ChatGPTConversationDirectory, Content: View>: View {
    @ObservedObject var store: GlobalDMStore
    let enabled: Bool
    let directory: Directory
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().modifier(GlobalDMChatGPTDrawerLayer(store: store, enabled: enabled, directory: directory))
    }
}

/// 抽屜本身（照 ChatGPT iPhone App）：頂端「ChatGPT」＋搜尋；圖庫、專案、外掛程式、已排程；已釘選；最近的對話；底部「✎ 聊天」＋設定齒輪。
struct GlobalDMChatGPTDrawer<Directory: ChatGPTConversationDirectory>: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var session: ChatGPTConversationSession
    @ObservedObject var directory: Directory
    @State private var searching = false
    @State private var search = ""
    @State private var showsProjects = false
    /// W184 G3b 第二輪（審查 #5）：搜尋問 ChatGPT 伺服器（查得到還沒載入的舊對話）：結果、那次查的字、查不了（只查已載入的）。
    @State private var serverResults: [TapConversation]?
    @State private var serverQuery = ""
    @State private var serverFailed = false
    @State private var serverLoading = false
    @State private var searchRetry = 0
    @State private var loadingMore = false
    /// W184 G3c（GPT-6 審查 #2）：用鍵盤打開（⌘⇧S）時焦點在搜尋欄；↑↓ 選最近／搜尋結果裡的一則（keyboardIndex），Return 打開（沒選＝第一則）。
    @FocusState private var searchFocused: Bool
    @State private var keyboardIndex: Int?

    /// 抽屜列出來的 Space 頁（截圖的「遠端」「探索」Space 沒有對應的頁，不列）。
    struct Page: Identifiable {
        let page: ChatGPTPage
        let title: String
        let symbol: String
        var id: String { page.rawValue }
    }
    /// （泛型型別不能有 static 存值屬性，所以是算出來的。）
    static var pages: [Page] {
        [Page(page: .library, title: "圖庫", symbol: "books.vertical"), Page(page: .plugins, title: "外掛程式", symbol: "at"),
         Page(page: .scheduled, title: "已排程", symbol: "clock")]
    }

    /// 搜尋結果：伺服器查到的（查全部）；還沒回來或查不了＝先用已載入的標題過濾。
    static func results(query: String, loaded: [TapConversation], server: [TapConversation]?, serverQuery: String) -> [TapConversation] {
        guard !query.isEmpty else { return loaded }
        if let server, serverQuery == query { return server }
        return loaded.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// 最近的對話（有打字＝搜尋結果）：畫面與鍵盤選的是同一份。
    private var recentItems: [TapConversation] {
        Self.results(query: search.trimmingCharacters(in: .whitespacesAndNewlines), loaded: directory.directoryConversations,
                     server: serverResults, serverQuery: serverQuery)
    }

    /// 鍵盤選著的那一則往上／往下一則（不繞圈）。
    static func moved(_ index: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let start = index ?? (step > 0 ? -1 : count)
        return min(count - 1, max(0, start + step))
    }

    private func openKeyboardSelection() {
        let items = recentItems
        guard !items.isEmpty else { return }
        _ = store.openChatGPTConversation(items[min(items.count - 1, max(0, keyboardIndex ?? 0))].id)
    }

    /// 鍵盤打開：搜尋欄出來、拿到焦點（下一輪再給：搜尋欄這一輪才出現）。
    private func focusSearch() {
        searching = true
        DispatchQueue.main.async { searchFocused = true }
    }

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = recentItems
        ZStack(alignment: .bottom) {
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    if query.isEmpty {
                        row(symbol: Self.pages[0].symbol, title: Self.pages[0].title, identifier: "tatwo.dm.chatgpt.drawer.library") {
                            store.openChatGPTSpacePage(.library, in: directory)
                        }
                        row(symbol: showsProjects ? "folder.fill" : "folder", title: "專案", identifier: "tatwo.dm.chatgpt.drawer.projects") {
                            showsProjects.toggle()
                        }
                        if showsProjects {
                            ChatGPTListStatusRow(state: directory.directoryProjectsLoadState, empty: directory.directoryProjects.isEmpty,
                                                 emptyText: "還沒有專案", identifier: "tatwo.dm.chatgpt.drawer.projects") { directory.directoryRetryProjects() }
                            ForEach(directory.directoryProjects) { folder in folderRows(folder).padding(.leading, 16) }
                        }
                        ForEach(Array(Self.pages.dropFirst())) { item in
                            row(symbol: item.symbol, title: item.title, identifier: "tatwo.dm.chatgpt.drawer.\(item.page.rawValue)") {
                                store.openChatGPTSpacePage(item.page, in: directory)
                            }
                        }
                        if !directory.directoryPinned.isEmpty {
                            sectionTitle("已釘選")
                            ForEach(directory.directoryPinned) { folder in folderRows(folder) }
                        }
                    }
                    sectionTitle(query.isEmpty ? "最近" : "搜尋結果")
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        conversationRow(item, highlighted: index == keyboardIndex).id("tatwo.dm.chatgpt.drawer." + item.id)
                    }
                    if query.isEmpty {
                        ChatGPTListStatusRow(state: directory.directoryListLoadState, empty: recent.isEmpty,
                                             emptyText: "還沒有對話", identifier: "tatwo.dm.chatgpt.drawer.list") { directory.directoryRetryList() }
                    }
                    if !query.isEmpty, serverLoading { Text("讀取中").font(.footnote).foregroundStyle(.secondary) }
                    if recent.isEmpty, !query.isEmpty, !serverLoading, !serverFailed {
                        Text("找不到符合的對話")
                            .font(.system(size: DMPhone.TextSize.footnote))
                            .foregroundStyle(ChatGPTPalette.tertiary)
                            .padding(.vertical, 8)
                    }
                    if !query.isEmpty, serverFailed, serverQuery == query {
                        // 伺服器查不了：只查了已載入的（說清楚範圍）。
                        Button("重試") { searchRetry += 1 }.buttonStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 4).chatGlassChip()
                        Text(serverResults == nil ? "只查了已載入的 \(directory.directoryConversations.count) 則對話（ChatGPT 的搜尋現在查不了）" : "讀不到搜尋結果，先保留上次的清單")
                            .font(.system(size: DMPhone.TextSize.footnote))
                            .foregroundStyle(ChatGPTPalette.tertiary)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("tatwo.dm.chatgpt.drawer.searchScope")
                    }
                    if query.isEmpty, directory.directoryHasMore {
                        // 還有沒載入的舊對話：載入下一頁。
                        GlobalDMChatGPTDrawerRow(symbol: loadingMore ? "hourglass" : "ellipsis", title: loadingMore ? "載入中…" : "載入更多",
                                                 selected: false, identifier: "tatwo.dm.chatgpt.drawer.loadMore") {
                            guard !loadingMore else { return }
                            loadingMore = true
                            Task { @MainActor in
                                await directory.directoryLoadMore()
                                loadingMore = false
                            }
                        }
                    }
                    Color.clear.frame(height: DMPhone.touch + DMPhone.margin * 2)   // 底部「聊天」那一排不蓋到最後一則
                }
                .padding(.horizontal, DMPhone.margin)
            }
            .scrollIndicators(.hidden)
            // 鍵盤選到看不見的那一則：捲過去。
            .onChange(of: keyboardIndex) { _, index in
                guard let index, recent.indices.contains(index) else { return }
                reader.scrollTo("tatwo.dm.chatgpt.drawer." + recent[index].id)
            }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChatGPTPalette.drawerFill)
        .onAppear {
            directory.directoryPrepare()
            if store.chatGPTDrawerKeyboard { focusSearch() }
        }
        .onChange(of: store.chatGPTDrawerKeyboard) { _, keyboard in if keyboard { focusSearch() } }
        .onChange(of: search) { _, _ in keyboardIndex = nil }
        // 打字 0.35 秒後問 ChatGPT 伺服器（同 ChatGPT Space 側欄的搜尋）；換字、清空就作廢上一次。
        .task(id: search.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + String(searchRetry)) {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            serverFailed = false
            serverLoading = !query.isEmpty
            guard !query.isEmpty else { serverResults = nil; serverQuery = ""; return }
            if serverQuery != query { serverResults = nil }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await directory.directorySearch(query)
            guard !Task.isCancelled else { return }
            serverQuery = query
            if let found { serverResults = found }
            serverFailed = found == nil
            serverLoading = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ChatGPT 對話")
        .accessibilityIdentifier("tatwo.dm.chatgpt.drawer.panel")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ChatGPT")
                    .font(.system(size: DMPhone.TextSize.body, weight: .bold))
                    .foregroundStyle(ChatGPTPalette.primary)
                Spacer(minLength: 0)
                Button { searching.toggle(); if !searching { search = "" } } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DMPhone.TextSize.body))
                        .foregroundStyle(ChatGPTPalette.primary)
                        .frame(width: DMPhone.touch, height: DMPhone.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("搜尋對話")
                .accessibilityLabel("搜尋對話")
                .accessibilityIdentifier("tatwo.dm.chatgpt.drawer.searchButton")
            }
            .frame(height: DMPhone.touch)
            if searching {
                TextField("搜尋對話", text: $search)
                    .font(.system(size: DMPhone.TextSize.secondary))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    // W184 G3c（GPT-6 審查 #2）：鍵盤：↑↓ 選一則、Return 打開（沒選＝第一則）；Esc 收抽屜（私訊框的 Esc 路由），焦點回輸入框。
                    .onKeyPress(.downArrow) {
                        keyboardIndex = Self.moved(keyboardIndex, by: 1, count: recentItems.count)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        keyboardIndex = Self.moved(keyboardIndex, by: -1, count: recentItems.count)
                        return .handled
                    }
                    .onSubmit { openKeyboardSelection() }
                    .padding(.horizontal, 12)
                    .frame(height: DMPhone.chipHeight + 4)
                    .background(Capsule().fill(ChatGPTPalette.pressed))
                    .help("↑↓ 選一則、Return 打開；\(GlobalDMChatGPTKeys.drawerDisplay) 或 Esc 收起")
                    .accessibilityIdentifier("tatwo.dm.chatgpt.drawer.search")
            }
        }
        .padding(.top, DMPhone.headerTop)
        .padding(.bottom, 6)
    }

    /// 底部：「✎ 聊天」膠囊（新對話）＋設定齒輪。
    private var footer: some View {
        HStack(spacing: 0) {
            Button { _ = store.newChatGPTConversation() } label: {
                Label("聊天", systemImage: "square.and.pencil")
                    .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                    .foregroundStyle(ChatGPTPalette.inverseText)
                    .padding(.horizontal, 18)
                    .frame(height: DMPhone.touch)
                    .background(Capsule().fill(ChatGPTPalette.inverseFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tatwo.dm.chatgpt.drawer.newChat")
            Spacer(minLength: 0)
            Button { directory.directoryOpenSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: DMPhone.TextSize.body))
                    .foregroundStyle(ChatGPTPalette.primary)
                    .frame(width: DMPhone.touch, height: DMPhone.touch)
                    .background(Circle().fill(ChatGPTPalette.pressed))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("連線與登入")
            .accessibilityLabel("連線與登入")
            .accessibilityIdentifier("tatwo.dm.chatgpt.drawer.settings")
        }
        .padding(.horizontal, DMPhone.margin)
        .padding(.bottom, DMPhone.margin)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: DMPhone.TextSize.footnote, weight: .semibold))
            .foregroundStyle(ChatGPTPalette.primary)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func folderRows(_ folder: TapFolder) -> some View {
        switch folder.kind {
        case .conversation:
            conversationRow(TapConversation(id: folder.id, title: folder.title, updatedAt: .distantPast))
        case .project:
            let expanded = directory.directoryExpandedProjects.contains(folder.id)
            row(symbol: expanded ? "folder.fill" : "folder", title: folder.title, identifier: "tatwo.dm.chatgpt.drawer.project") {
                directory.directoryToggleProject(folder.id)
            }
            if expanded {
                ChatGPTListStatusRow(state: directory.directoryProjectLoadState(folder.id),
                                     empty: (directory.directoryConversations(inProject: folder.id) ?? []).isEmpty,
                                     emptyText: "還沒有對話", identifier: "tatwo.dm.chatgpt.drawer.project." + folder.id) {
                    directory.directoryRetryProject(folder.id)
                }.padding(.leading, 16)
                ForEach(directory.directoryConversations(inProject: folder.id) ?? []) { item in
                    conversationRow(item).padding(.leading, 16)
                }
            }
        case .other:
            EmptyView()
        }
    }

    private func conversationRow(_ item: TapConversation, highlighted: Bool = false) -> some View {
        GlobalDMChatGPTDrawerRow(symbol: nil, title: item.title.isEmpty ? "新對話" : item.title,
                                 selected: item.id == session.conversationID, highlighted: highlighted,
                                 identifier: "tatwo.dm.chatgpt.drawer.conversation") { _ = store.openChatGPTConversation(item.id) }
    }

    private func row(symbol: String, title: String, identifier: String, action: @escaping () -> Void) -> some View {
        GlobalDMChatGPTDrawerRow(symbol: symbol, title: title, selected: false, identifier: identifier, action: action)
    }
}

/// 抽屜的一列（44 高；目前那則用 App 的強調色淡底，不要藍色系統反白）。
struct GlobalDMChatGPTDrawerRow: View {
    let symbol: String?
    let title: String
    let selected: Bool
    /// W184 G3c：鍵盤（抽屜搜尋欄的 ↑↓）選著這一則：同滑鼠滑過的淡底。
    var highlighted = false
    let identifier: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: DMPhone.TextSize.body))
                        .foregroundStyle(ChatGPTPalette.primary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: DMPhone.TextSize.body))
                    .foregroundStyle(ChatGPTPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: DMPhone.touch)
            .background {
                RoundedRectangle(cornerRadius: DMPhone.chipHeight / 2 - 4, style: .continuous)
                    .fill(selected ? LiquidGlassTokens.brandAccent.opacity(0.14) : (hover || highlighted ? ChatGPTPalette.hover : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - 空白時的建議

/// 新對話、還沒有訊息時：輸入框上方列「建議」（ChatGPT 給的建議，點了放進輸入框；沒有就是最近 3 則對話，點了換到那一則）。
/// W184 G3c：臨時聊天開著的新對話（照 ChatGPT Space 與網頁，建議不列）：標題＋說明（跟 Space 同一段字）；
/// 語音模式開的是一般對話（會存進紀錄），臨時聊天裡不開，說明最後一句寫出來。
struct GlobalDMChatGPTTemporaryNote: View {
    var personalized = false
    static let voiceNote = "臨時聊天裡不開語音模式（語音會存進紀錄）。"
    @Environment(\.globalDMSideMargin) private var sideMargin
    @Environment(\.globalDMBoxRole) private var role

    var body: some View {
        VStack(spacing: 8) {
            Text(ChatGPTTemporaryChatText.title)
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
            Text((personalized ? ChatGPTTemporaryChatText.personalizedNote : ChatGPTTemporaryChatText.note) + Self.voiceNote)
                .font(.system(size: DMPhone.TextSize.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, (sideMargin ?? GlobalDMChatLayout.sideMargin(for: role)) + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tatwo.dm.chatgpt.temporaryNote")
    }
}

struct GlobalDMChatGPTSuggestions<Directory: ChatGPTConversationDirectory>: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var directory: Directory
    @Environment(\.globalDMSideMargin) private var sideMargin
    @Environment(\.globalDMBoxRole) private var role

    struct Item: Identifiable, Equatable {
        let id: String
        let symbol: String
        let title: String
        let prompt: String?
    }

    /// 列什麼（純計算，好測）：建議優先（最多 3 則）；沒有建議就是最近 3 則對話。
    static func items(suggestions: [TapSuggestion], recent: [TapConversation]) -> [Item] {
        if !suggestions.isEmpty {
            return suggestions.prefix(3).map { Item(id: "suggestion:" + $0.id, symbol: "sparkles", title: $0.title, prompt: $0.prompt) }
        }
        return recent.prefix(3).map { Item(id: "conversation:" + $0.id, symbol: "bubble.left", title: $0.title.isEmpty ? "新對話" : $0.title,
                                           prompt: nil) }
    }

    var body: some View {
        let items = Self.items(suggestions: directory.directorySuggestions, recent: directory.directoryConversations)
        let margin = sideMargin ?? GlobalDMChatLayout.sideMargin(for: role)
        Group {
            if items.isEmpty {
                // 還沒有建議、也還沒有對話（剛連上、清單還沒讀到）：照舊一行說明（同訊息列表空白時）。
                Text("問 ChatGPT 任何事；用你自己的 ChatGPT 帳號。")
                    .font(.system(size: GlobalDMChatLayout.noticeSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(items) { item in row(item) }
                }
                .padding(.horizontal, margin)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("建議")
                .accessibilityIdentifier("tatwo.dm.chatgpt.suggestions")
            }
        }
        .onAppear { directory.directoryPrepare() }
    }

    private func row(_ item: Item) -> some View {
        Button {
            if let prompt = item.prompt {
                store.setDraft(prompt, for: .chatGPT)
            } else if item.id.hasPrefix("conversation:") {
                _ = store.openChatGPTConversation(String(item.id.dropFirst("conversation:".count)))
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .font(.system(size: DMPhone.TextSize.body))
                    .foregroundStyle(ChatGPTPalette.tertiary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.system(size: DMPhone.TextSize.body))
                    .foregroundStyle(ChatGPTPalette.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(height: DMPhone.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tatwo.dm.chatgpt.suggestion")
    }
}
