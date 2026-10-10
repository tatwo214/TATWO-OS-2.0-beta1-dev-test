import AppKit
import SwiftUI

/// 私訊框只剩頭像色（W179 UI）：框、泡泡、按鈕、選單一律用 App 的玻璃 token 與系統語意色，不自訂米色、不用藍色。
enum GlobalDMPalette {
    static let assistantAvatar = Color(red: 0xA2 / 255, green: 0x55 / 255, blue: 0x3B / 255)
    static let sessionAvatar = Color(red: 0x56 / 255, green: 0x6A / 255, blue: 0x82 / 255)
    static let chatGPTAvatar = Color(red: 0x1F / 255, green: 0x7A / 255, blue: 0x5C / 255)
    static let laterAvatar = Color(red: 0x75 / 255, green: 0x6B / 255, blue: 0x60 / 255)

    /// W180 A3：圖示列每一顆的頭像色。
    static func color(for tint: GlobalDMIconItem.Tint) -> Color {
        switch tint {
        case .assistant: assistantAvatar
        case .chatGPT: chatGPTAvatar
        case .session: sessionAvatar
        case .later: laterAvatar
        case .offline: Color(red: 0x9A / 255, green: 0x9C / 255, blue: 0xA0 / 255)   // W182 R4：連不上那台的對話（灰）
        case .browser: Color(red: 0x5A / 255, green: 0x5F / 255, blue: 0x66 / 255)   // W183 R8b：Browser（地球線條圖示用白底，這個色只在退回字母時用）
        }
    }
}

enum GlobalDMLayout {
    static let buttonSize: CGFloat = 44
    static let trailing: CGFloat = 12
    static let bottom: CGFloat = 8
    static let gap: CGFloat = 10
    /// W181（使用者 09-27：「私訊筐再大 r角對照iphone螢幕弧度」「很明顯不是iphone duo的比例…私訊筐寬一點」）：
    /// 停靠框＝iPhone Duo 闔起時的外螢幕（Apple 規格 1398×2034 像素＠3x＝466×678 點）；放不下就照這個比例等比縮小。
    /// 圓角照 iPhone 螢幕（約 55pt）。
    static let box = CGSize(width: 466, height: 678)
    static let cornerRadius: CGFloat = 52
    /// W181（使用者 09-27：「這邊輸入筐比例很醜」）：輸入框貼著框底，左右下同一個距離；
    /// 圓角＝框的圓角減這個距離（同心：DMPhone.barRadius；矮的時候自然變膠囊）。
    static let composerInset: CGFloat = 12
    /// 子面板四周留給陰影的透明邊。
    static let margin: CGFloat = 18
    static let floatingInset: CGFloat = 24
    /// 右側空白放不下圓鈕時，圓鈕離主視窗底部的高度（在輸入框上方）。
    static let composerClearance: CGFloat = 148
    /// W179 UI：框頂一列的高度（W184 AB 起私訊框的頂列照 DMPhone.headerHeight；這個留給［連線］卡的頂列）。
    static let headerHeight: CGFloat = 52   // W181：大圓角下頂列往下讓一點，圖示不被圓角切到
    /// 框裡的小圖示鈕（返回、清除；W184 AB 起框頂的 ✕、尺寸鈕拿掉）一律這個大小。
    static let iconButtonSize: CGFloat = 28
    /// 主視窗太矮時停靠框先縮到這個高度，再考慮蓋到輸入框。
    static let minimumDockedBoxHeight: CGFloat = 280
    /// W181：框等比縮小時最窄到這裡（再窄輸入列的 chip 放不下）。
    static let minimumDockedBoxWidth: CGFloat = 300

    static var dockedClosedSize: CGSize {
        CGSize(width: buttonSize + margin * 2, height: buttonSize + margin * 2)
    }

    /// 這幾個 Space 的輸入框置中、有最大寬度；送出鈕在輸入框右下。
    static func composerWidth(for mode: ChatRunMode?) -> CGFloat? {
        switch mode {
        case .chat?, .tatwo?: return ChatUILayout.chatColumnMaxWidth
        case .chatgpt?: return 760
        default: return nil
        }
    }

    /// 圓鈕離主視窗內容區底部多高：預設 8；輸入框右側的空白放不下圓鈕（含 8pt 間隔）時抬到輸入框上方，
    /// 才不會蓋住 Coder／TATWO 輸入框的送出鈕。寬度估算照聊天版面（側欄 250＋間距、外框 18、左右留白 36）。
    static func bottomInset(contentWidth: CGFloat, mode: ChatRunMode?) -> CGFloat {
        guard let composer = composerWidth(for: mode) else { return bottom }
        let sidebar = contentWidth >= 760 ? WorkspaceSidebarMetrics.width + WorkspaceSidebarMetrics.contentGap : 0
        let main = max(0, contentWidth - sidebar - 36)
        let column = min(composer, max(320, main - 36))
        let rightSpace = (main - column) / 2 + 18
        return rightSpace >= trailing + buttonSize + 8 ? bottom : composerClearance
    }
}

enum GlobalDMSurface { case docked, floating }

/// 主視窗子面板之一：右下那顆圓鈕（W179 UI：圓鈕與框各一個面板，框的位置由控制器依輸入框決定）。
struct GlobalDMDockedButtonRoot: View {
    @ObservedObject var store: GlobalDMStore

    var body: some View {
        GlobalDMRoundButton(isOpen: store.isOpen) {
            withAnimation(.easeOut(duration: 0.16)) { store.toggleDocked() }
        }
        .padding(GlobalDMLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 主視窗子面板之二：私訊框，填滿面板（面板大小由控制器決定：W184 AB 照目前形態，放不下等比縮）。
/// W184 F3：換形態的動畫是面板畫布上的圖層（GlobalDMFormStage），這裡一律照形態停著的樣子畫（轉換開始、停下各排一次版）。
struct GlobalDMDockedBoxRoot: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var desk = GlobalDMDeskSettings.shared
    /// W184 AB（停靠：同 F45 浮動）：收框＝框的內容先淡出 0.10 秒（dockedMorph 的 clearing）：這段時間照樣留著內容，淡完才收框、縮回圓鈕。
    @ObservedObject var morph: GlobalDMButtonMorph

    var body: some View {
        Group {
            if store.isOpen || morph.keepsContent {
                GlobalDMBoxHost(store: store, surface: .docked, form: desk.form)
            }
        }
        .padding(GlobalDMLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 獨立浮動面板：只有框，沒有圓鈕。W179 E：框填滿面板；W184 AB：面板大小照目前形態（內橫＝一條頂列跨兩欄）。
struct GlobalDMFloatingRoot: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var desk = GlobalDMDeskSettings.shared
    /// W184 AB（補 F45 查核 #3）：縮成桌面圓鈕時收框＝框的內容先淡出 0.10 秒（GlobalDMButtonMorph 的 clearing）：這段時間照樣留著內容，
    /// 淡完才收框、縮回圓鈕。
    @ObservedObject var morph: GlobalDMButtonMorph

    var body: some View {
        Group {
            if store.isFloatingOpen || morph.keepsContent {
                GlobalDMBoxHost(store: store, surface: .floating, form: desk.form)
            }
        }
        .padding(GlobalDMLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

struct GlobalDMRoundButton: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOpen ? LiquidGlassTokens.brandAccent : Color.primary.opacity(0.72))
                .frame(width: GlobalDMLayout.buttonSize, height: GlobalDMLayout.buttonSize)
                .liquidGlassPanelSurface(cornerRadius: GlobalDMLayout.buttonSize / 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "收起私訊框（⌥⌘）" : "私訊（⌥⌘）")
        .accessibilityLabel("私訊")
        .accessibilityIdentifier("tatwo.dm.button")
    }
}

struct GlobalDMBoxHost: View {
    @ObservedObject var store: GlobalDMStore
    let surface: GlobalDMSurface
    /// W184 AB：框的形態（面板大小由控制器照它決定；內橫的右欄拿第二個 store）。
    var form: GlobalDMForm = .outerPortrait

    var body: some View {
        Group {
            if let model = store.model {
                // W184 F3：進、出內橫途中露出來的右欄是轉換開始、停下那一刻拍的圖（GlobalDMFormStage），這裡只照形態拿第二個 store。
                GlobalDMPhoneBox(store: store, model: model, surface: surface, form: form,
                                 secondary: form.isDuo ? GlobalDMDuo.shared.secondary : nil)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("私訊框還在準備，稍等一下").font(.system(size: DMPhone.TextSize.footnote)).foregroundStyle(.secondary)
                }
                .modifier(GlobalDMBoxSizing(size: nil))
                .modifier(GlobalDMWebSheetOverlay(store: store))   // W183 R5b
                .modifier(GlobalDMBoxChrome())
            }
        }
    }
}

struct GlobalDMBoxChrome: ViewModifier {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    /// W184 F3：框的圓角固定 52（任何形態、大小、轉場中；輸入框 40 同心）。
    var cornerRadius: CGFloat = GlobalDMLayout.cornerRadius

    /// W179 UI：框的表面、圓角、陰影用 App 的玻璃（極光＝系統玻璃，fable5＝牛皮紙），不自訂底色與黑陰影。
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle))
            .liquidGlassPanelSurface(cornerRadius: cornerRadius)
    }
}

/// 一則訊息：使用者（Coder 的使用者訊息樣式）、對方（頭像＋Coder 的回答排版）、錯誤卡、系統說明一行、
/// 回覆中還沒出字時的打字點點（同 TATWO 助理頁）。
struct GlobalDMBubble: Identifiable, Equatable {
    enum Kind: Equatable { case mine, theirs, note, error, typing }
    let id: String
    let kind: Kind
    let text: String
    /// 引擎回報的模型：頭像照它畫（同 Coder）。
    var modelID: String? = nil
    var error: ChatErrorCardPresentation? = nil
    var turnFailure: ChatGPTTurnFailure? = nil
    var thinking: ChatGPTThinking? = nil
    var note: ChatSystemNotePresentation? = nil

    static let maximumRows = 80
    static let typingID = "tatwo.dm.typing"

    /// `running`：對象正在回覆。最後一則還不是有字的回答時，尾巴加一列打字點點（同 TATWO 助理頁、Coder）。
    static func rows(_ messages: [ChatMessage], running: Bool = false) -> [GlobalDMBubble] {
        var mapped = messages.compactMap { message -> GlobalDMBubble? in
            switch message.role {
            case .user where message.eventKind == .message:
                return GlobalDMBubble(id: message.id, kind: .mine, text: GlobalDMMessageText.displayText(message.text))
            case .assistant where message.eventKind == .message:
                return message.text.isEmpty ? nil
                    : GlobalDMBubble(id: message.id, kind: .theirs, text: GlobalDMMessageText.displayText(message.text),
                                     modelID: message.modelID)
            // 錯誤一律顯示（Coder 的錯誤卡）；系統說明（權限、PR 作業、完成…）同 TATWO 助理頁，全部用 Coder 的說明列。
            case .system:
                if let error = ChatErrorCardPresentation.resolve(message) {
                    return GlobalDMBubble(id: message.id, kind: .error, text: message.text, error: error)
                }
                if let note = ChatSystemNotePresentation.resolve(message) {
                    return GlobalDMBubble(id: message.id, kind: .note, text: message.text, note: note)
                }
                return nil
            default:
                return nil
            }
        }
        if running, !(messages.last.map { $0.role == .assistant && $0.eventKind == .message && !$0.text.isEmpty } ?? false) {
            // 頭像照這條最近回報的模型（同回答那一列）。
            let modelID = messages.last { $0.role == .assistant && $0.modelID != nil }?.modelID
            mapped.append(GlobalDMBubble(id: typingID, kind: .typing, text: "", modelID: modelID))
        }
        return Array(mapped.suffix(maximumRows))
    }

    static func rows(_ messages: [TapMessage], answering: Bool, thinking: ChatGPTThinking? = nil) -> [GlobalDMBubble] {
        Array(messages.flatMap { message -> [GlobalDMBubble] in
            var rows: [GlobalDMBubble] = []
            if message.role == .user {
                rows.append(GlobalDMBubble(id: message.id, kind: .mine,
                    text: GlobalDMMessageText.displayText(message.text, files: message.files)))
            } else if !message.text.isEmpty {
                if let note = ChatGPTThinking.doneText(message.thoughtSeconds) {
                    rows.append(GlobalDMBubble(id: message.id + "-thought", kind: .note, text: note,
                        note: ChatSystemNotePresentation(symbol: "", tag: "", text: note)))
                }
                rows.append(GlobalDMBubble(id: message.id, kind: .theirs, text: GlobalDMMessageText.displayText(message.text)))
            } else if answering && message.stopNotice == nil && message.turnFailure == nil {
                rows.append(GlobalDMBubble(id: message.id, kind: .typing, text: "", thinking: thinking))
            }
            if let failure = message.turnFailure {
                rows.append(GlobalDMBubble(id: message.id + "-failed", kind: .error, text: failure.displayText, turnFailure: failure))
            }
            if let note = message.stopNotice {
                rows.append(GlobalDMBubble(id: message.id + "-stopped", kind: .note, text: note,
                    note: ChatSystemNotePresentation(symbol: "stop.circle", tag: "", text: note)))
            }
            return rows
        }.suffix(maximumRows))
    }
}

/// W184 AB：一欄的內容（頂列在 GlobalDMPhoneBox）：目前對象的對話；單欄時 Browser 開著＝這一欄換成 Browser。
/// 內橫的左欄永遠是對話（Browser 在右欄）；右欄的另一個對象（第二個 store）也是這個。
struct GlobalDMBox: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var model: ChatPageModel
    let surface: GlobalDMSurface
    /// 單欄、內橫的左欄或右欄。
    var role: GlobalDMBoxRole = .single
    /// 框裡的 Browser 用哪一份（正式＝.shared；W184 F／G1 自測接假的）。
    @Environment(\.globalDMBrowserServices) private var browserServices

    var body: some View {
        Group {
            if store.isBrowsing, role.showsBrowser {
                // W183 R8b：第三顆圓鈕＝手機式瀏覽器（授權頁都開在這裡的分頁）
                DMBrowserPane(store: store, browser: browserServices.browser, flow: browserServices.flow, connect: browserServices.connect)
            } else {
            switch store.target {
            case .chatGPT:
                if ChatGPTWebSpace.isEnabled, store.chatGPTAvailable, let pod = store.chatGPT.tap.webPod {
                    ChatGPTWebSpacePane(tap: store.chatGPT.tap, pod: pod, showsTabs: true)
                } else {
                    GlobalDMChatGPTPane(store: store, session: store.chatGPT, isAvailable: store.chatGPTAvailable)
                }
            case .assistant:
                // W179 F：副設備連得到主設備時這裡是主設備那條；接不到時只顯示一行說明、草稿留著。
                GlobalDMThreadPane(store: store, bubbles: GlobalDMBubble.rows(model.assistantMessages,
                                                                             running: model.assistantIsRunning),
                                   emptyText: model.assistantTranscriptLoading ? "載入對話…"
                                       : "有什麼我可以幫你的？生活、工作或 OS 怎麼用都可以問。",
                                   placeholder: "問助理任何事…",
                                   note: model.assistantPlacementNote, hint: model.assistantPrimaryHint,
                                   canSend: model.assistantCanSend, avatarRoute: model.assistantRouteChoice)
            case .thread(let id):
                // W179 F：主設備上的對話在主設備連不上時一行說明、送出鈕關掉、草稿留著。
                GlobalDMThreadPane(store: store,
                                   bubbles: GlobalDMBubble.rows(model.dmTranscript(for: id),
                                                                running: model.dmSessionIsRunning(id)),
                                   emptyText: model.dmSessionLoading(id) ? "載入對話…"
                                       : model.dmOfflineEmptyText(id) ?? "這條對話還沒有訊息。",   // W182 R4
                                   placeholder: "對這條對話下令…",
                                   note: model.dmSessionNote(id), hint: model.dmSessionHint(id),
                                   canSend: model.dmSessionCanSend(id), fallbackAvatar: .thread(id),
                                   noteAction: model.dmOfflineContinueAction(id, store: store))   // W182 R4：「在這台接著聊」
            }
            }
        }
        .environment(\.globalDMBoxRole, role)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(role == .duoTrailing ? "tatwo.dm.column.trailing" : "tatwo.dm.column")
    }
}

/// W181（使用者 09-27：「這是我的logo 做小視窗t的替代」「chatgpt logo也對應過去」）：
/// TATWO 助理用使用者的 logo、ChatGPT 用 OpenAI 圖示；讀不到圖時退回原本的字母頭像。
enum GlobalDMAvatarArt: Equatable {
    case assistant, chatGPT
    /// W183 R8b：Browser 的地球（系統線條圖示，白底黑線，同 ChatGPT 那顆的樣子）。
    case browser

    static let assistantImage: NSImage? = ProviderIconResources.pngURL(for: "TatwoAvatar-assistant")
        .flatMap { NSImage(contentsOf: $0) }
    static let chatGPTImage: NSImage? = {
        guard let image = ProviderSVGIconLoader.image(for: "codex-gpt")?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        return image
    }()

    var image: NSImage? {
        switch self {
        case .assistant: Self.assistantImage
        case .chatGPT: Self.chatGPTImage
        case .browser: nil
        }
    }
}

struct GlobalDMAvatar: View {
    let letter: String
    let color: Color
    var size: CGFloat = 22
    var art: GlobalDMAvatarArt? = nil

    init(target: GlobalDMTarget, size: CGFloat = 22) {
        switch target {
        case .assistant: letter = "T"; color = GlobalDMPalette.assistantAvatar; art = .assistant
        case .thread: letter = "C"; color = GlobalDMPalette.sessionAvatar
        case .chatGPT: letter = "G"; color = GlobalDMPalette.chatGPTAvatar; art = .chatGPT
        }
        self.size = size
    }

    init(letter: String, color: Color, size: CGFloat = 22, art: GlobalDMAvatarArt? = nil) {
        self.letter = letter
        self.color = color
        self.size = size
        self.art = art
    }

    var body: some View {
        if art == .assistant, let image = GlobalDMAvatarArt.assistantImage {
            // 使用者的 logo：白色圓裡放整顆頭（比例照使用者 09-27 給的樣子，圖檔本身已排好）。
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .background(Color.white)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
        } else if art == .chatGPT, let image = GlobalDMAvatarArt.chatGPTImage {
            // OpenAI 圖示：白底黑線（使用者 09-27：「chatgpt要用白色底黑線不要綠色」）。
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(Color.black)
                .padding(size * 0.2)
                .frame(width: size, height: size)
                .background(Color.white, in: Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
        } else if art == .browser {
            // W183 R8b：Browser 的地球（對照稿：白底、深色線條）。
            Image(systemName: "globe")
                .resizable()
                .scaledToFit()
                .font(.system(size: size * 0.5, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(size * 0.24)
                .frame(width: size, height: size)
                .background(Color.white, in: Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
        } else {
            Text(letter)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color, in: Circle())
        }
    }
}

/// 討論串（含助理；本機或主設備上的）的訊息區＋輸入框。
struct GlobalDMThreadPane: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject private var fleet = DeviceFlowSession.shared
    @Environment(\.globalDMBoxRole) private var role
    let bubbles: [GlobalDMBubble]
    let emptyText: String
    let placeholder: String
    /// W179 F：一行白話說明（不是錯誤卡），例如助理在主設備上、現在連不上。
    var note: String? = nil
    /// W179 F：送到主設備那句沒送到（草稿留著）、或主設備連線的提示。
    var hint: String? = nil
    var canSend = true
    /// W179 UI：助理的頭像用它的模型（同 TATWO 助理頁）；session 沒回報模型時用對象頭像。
    var avatarRoute: ChatRouteChoice? = nil
    var fallbackAvatar: GlobalDMTarget = .assistant
    /// W182 R4：說明列右邊的玻璃 chip（例如那台離線時的「在這台接著聊」）；nil＝沒有。
    var noteAction: GlobalDMNoteAction? = nil

    var body: some View {
        VStack(spacing: 0) {
            GlobalDMBodyRegion(store: store) {
                GlobalDMMessageList(bubbles: bubbles, emptyText: emptyText, avatarRoute: avatarRoute,
                                    fallbackAvatar: fallbackAvatar,
                                    fleet: store.target == .assistant ? fleet : nil,
                                    fleetRevision: store.target == .assistant ? fleet.revision : 0)
                    .equatable()
                // 提示列一律在訊息下面、輸入列上面，同一種樣式。
                if let note {
                    GlobalDMNoticeRow(icon: "wifi.slash", text: note, actionTitle: noteAction?.title, identifier: "tatwo.dm.primaryOffline") {
                        noteAction?.run()
                    }
                }
                if let hint {
                    GlobalDMNoticeRow(icon: "info.circle", text: hint, actionTitle: nil, identifier: "tatwo.dm.primaryHint") {}
                }
                if store.isAwaitingApproval {
                    // W184 C：核准仍只在 Island（D54），這一列只帶過去；強調色＝要你動手（對照稿的「等你核准」列）。
                    GlobalDMNoticeRow(tone: .attention, icon: "hand.raised", text: "等你核准", actionTitle: "到 Island 核准",
                                      identifier: "tatwo.dm.approval") { store.revealApprovalInIsland() }
                }
                if let notice = store.notice {
                    GlobalDMNoticeRow(icon: "info.circle", text: notice, actionTitle: nil, identifier: "tatwo.dm.notice") {}
                }
                // W184 H4 修正第三輪：沒送到、而輸入框已經有新的字的那一句（不蓋掉）：一行＋玻璃 chip「放回輸入框」（接在草稿前面，不送出）。
                if let undelivered = store.undeliveredNotice {
                    GlobalDMNoticeRow(icon: "arrow.uturn.backward.circle", text: undelivered, actionTitle: "放回輸入框",
                                      identifier: "tatwo.dm.undelivered") { store.restoreUndelivered() }
                }
                if let returned = store.chatGPTReturnedDraft {
                    GlobalDMNoticeRow(icon: "arrow.uturn.backward.circle", text: "未送草稿已保留，移開目前草稿後可恢復",
                                      actionTitle: "恢復草稿", identifier: "tatwo.dm.chatGPT.returned") {
                        store.restoreReturnedChatGPTDraft(returned.id)
                    }
                }
            }
            // 直達鍵頁開著時收起輸入列：錄鍵時按的字不會跑進草稿（回對話再出現）。
            if !store.isEditingDirectKeys {
                GlobalDMComposer(store: store, placeholder: placeholder, isRunning: store.isRunning,
                                 canSend: canSend, initiallyFocused: role.takesInitialFocus)
            }
        }
        .background(OSPresenceDMProbe(store: store))
    }
}

/// ChatGPT（經 TAP）：私訊框自己的對話；登入與 ChatGPT Space 共用。
/// 目前 Space 把 ChatGPT 分頁關掉時只顯示一行說明，不叫醒 ChatGPT、不送出。
struct GlobalDMChatGPTPane<Directory: ChatGPTConversationDirectory>: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var session: ChatGPTConversationSession
    @Environment(\.globalDMBoxRole) private var role
    @Environment(\.globalDMSideMargin) private var sideMargin
    let isAvailable: Bool
    /// W184 G3b：空白時的建議、最近的對話（ChatGPT Space 那一份；自測換成假的）。
    let directory: Directory

    /// W184 G3b 第二輪（審查 #2）：內橫右欄沒有頂列的 ChatGPT 控制（頂列是左欄的）：右欄自己一排（W184 G3c：只剩臨時聊天），
    /// 綁右欄自己的 store；抽屜也掛在右欄這一格裡。
    private var ownsControls: Bool { role == .duoTrailing && isAvailable }
    /// W184 G3c：右欄自己那一排的高度（上 10＋44）：內容照舊從它下面開始；訊息列表再往上延伸到框的上緣（在它與頂列底下捲）。
    private var controlsInset: CGFloat { ownsControls ? DMPhone.headerBottom + DMPhone.touch : 0 }
    @Environment(\.globalDMListBleed) private var listBleed

    var body: some View {
        VStack(spacing: 0) {
            GlobalDMBodyRegion(store: store) {
                if session.messages.isEmpty, isAvailable, session.conversationID == nil {
                    if session.temporary {
                        // W184 G3c：臨時聊天開著（照 ChatGPT Space）：說明代替建議。
                        GlobalDMChatGPTTemporaryNote(personalized: session.temporaryPersonalized)
                    } else {
                        // W184 G3b（照 ChatGPT iPhone App）：空白時輸入框上方列建議（ChatGPT 給的；沒有就是最近 3 則對話）。
                        GlobalDMChatGPTSuggestions(store: store, directory: directory)
                    }
                } else if session.messages.isEmpty, session.loadState == .loading {
                    // W184 G3b 第二輪（審查 #3）：換到的那一則還在讀（這時不能送）。
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("讀取這則對話…")
                            .font(.system(size: DMPhone.TextSize.footnote))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("tatwo.dm.chatgptLoading")
                } else {
                    GlobalDMMessageList(bubbles: GlobalDMBubble.rows(session.messages,
                                                                     answering: session.isSending && session.thinking != nil, thinking: session.thinking),
                                        emptyText: "問 ChatGPT 任何事；用你自己的 ChatGPT 帳號。", fallbackAvatar: .chatGPT,
                                        chatGPTLook: true, recoverChatGPT: { failure in
                                            guard !session.isSending else { return }
                                            store.restoreChatGPTFailure(failure, session: session)
                                        }, recoveryAvailable: !session.isSending)
                        .equatable()
                }
                if !isAvailable {
                    GlobalDMNoticeRow(icon: "slash.circle", text: "ChatGPT Space 已關閉；到設定打開 ChatGPT 分頁才能用",
                                      actionTitle: nil, identifier: "tatwo.dm.chatgptOff") {}
                } else {
                    // W184 G3b 第二輪（審查 #3、#8）：讀不到（說出來、可以重試，不當成空對話）；Work 模式的對話（看得到、不能接著聊）。
                    if case .failed(let reason) = session.loadState {
                        GlobalDMNoticeRow(icon: "exclamationmark.triangle", text: reason, actionTitle: "重試",
                                          identifier: "tatwo.dm.chatgptLoadFailed") { session.retryLoad() }
                    }
                    if session.isWork {
                        GlobalDMNoticeRow(icon: "briefcase", text: ChatGPTConversationSession.workNotice, actionTitle: nil,
                                          identifier: "tatwo.dm.chatgptWork") {}
                    }
                    // W184 G3 第三輪（修正核對 #1）：語音在另一邊手上（聲波鈕因此是灰的、文字會排在語音後面）：說一句，給「結束那邊的語音」。
                    if let elsewhere = session.voiceElsewhere {
                        GlobalDMNoticeRow(icon: "waveform", text: elsewhere, actionTitle: "結束那邊的語音",
                                          identifier: "tatwo.dm.voiceElsewhere") { session.endVoiceElsewhere() }
                    }
                    if let note = session.tap.recoveryNotice ?? session.stopNotice {
                        GlobalDMNoticeRow(icon: "info.circle", text: note, actionTitle: nil,
                                          identifier: "tatwo.dm.chatgptStopped") {}
                    }
                    switch session.state {
                    case .needsLogin:
                        GlobalDMNoticeRow(icon: "person.crop.circle.badge.exclamationmark", text: "ChatGPT 要先登入",
                                          actionTitle: "到 ChatGPT Space 登入", identifier: "tatwo.dm.chatgptLogin") {
                            store.openChatGPTSpace()
                        }
                    case .failed:
                        if let reason = session.failureNotice {
                            GlobalDMNoticeRow(icon: "exclamationmark.triangle", text: reason, actionTitle: nil,
                                              identifier: "tatwo.dm.chatgptFailed") {}
                        }
                    default:
                        EmptyView()
                    }
                }
            }
            // W184 G3c：右欄自己那一排蓋在上面（見下面的 overlay），內容照舊從它下面開始；訊息列表多延伸這一段。
            .padding(.top, controlsInset)
            .environment(\.globalDMListBleed, listBleed + controlsInset)
            if !store.isEditingDirectKeys {
                GlobalDMComposer(store: store,
                                 placeholder: !isAvailable ? "ChatGPT Space 已關閉"
                                     : session.state == .needsLogin ? "先登入 ChatGPT" : "問問 ChatGPT",
                                 isRunning: session.isSending, canSend: isAvailable,
                                 initiallyFocused: role.takesInitialFocus, chatGPTSession: session)
            }
        }
        // W184 G3c（使用者：「文字頂部漸淡應頂天 不是空一節」）：內橫右欄自己那一排（臨時聊天）蓋在訊息列表上面，列表在它底下捲到框的上緣；
        // 那一排的按鈕在上面一層照舊可按。
        .overlay(alignment: .top) {
            if ownsControls {
                GeometryReader { proxy in
                    GlobalDMChatGPTTopControls(store: store, session: session, width: proxy.size.width)
                }
                .frame(height: DMPhone.touch)
                .padding(.horizontal, sideMargin ?? GlobalDMChatLayout.sideMargin(for: role))
                .padding(.top, DMPhone.headerBottom)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tatwo.dm.chatgpt.trailingBar")
            }
        }
        // W184 G3：思考強度面板、語音模式的畫面、拖進對話區的照片與檔案（同 ChatGPT Space；GlobalDMChatGPTComposer.swift）。
        .modifier(GlobalDMChatGPTPaneLayers(store: store, voice: session.voice))
        .modifier(GlobalDMChatGPTTrailingLayers(store: store, enabled: ownsControls, directory: directory))
    }
}

extension GlobalDMChatGPTPane where Directory == ChatGPTSpaceModel {
    /// 正式：清單是 ChatGPT Space 那一份。
    init(store: GlobalDMStore, session: ChatGPTConversationSession, isAvailable: Bool) {
        self.init(store: store, session: session, isAvailable: isAvailable, directory: ChatGPTSpaceModel.shared)
    }
}

/// 標題列以下、輸入列以上的內容區（W179 UI）：對話與提示列，或直達鍵頁（這時輸入列收起，整塊給直達鍵頁）；
/// 對象選單只蓋在這一塊裡。
struct GlobalDMBodyRegion<Content: View>: View {
    @ObservedObject var store: GlobalDMStore
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if store.isEditingDirectKeys {
                GlobalDMDirectKeyPage(store: store)
            } else {
                VStack(spacing: 0, content: content)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if store.isPickerOpen {
                GeometryReader { geo in
                    let frame = GlobalDMMenuLayout.pickerFrame(bodySize: geo.size)
                    ZStack(alignment: .topLeading) {
                        // 點選單外面收起選單。
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { store.isPickerOpen = false }
                        GlobalDMTargetPicker(store: store, maxHeight: frame.height)
                            .frame(width: frame.width, alignment: .top)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
    }
}

/// 所有提示列（等你核准、主設備連不上、送不到主設備、ChatGPT 關閉／要登入／失敗、一般提示、在這台接著聊）同一種樣式。
/// W184 C（對照稿 Open-Portrait-Chat、Open-Landscape-Ack）：一句白話＋最多一顆玻璃 chip；最矮 48、圓角 24（跟 chip 同心），
/// 字 15pt；等你核准那一列用強調色的圖示與淡強調底（既有玻璃 token 的 accentOpacity）。
struct GlobalDMNoticeRow: View {
    enum Tone { case plain, attention }

    var tone: Tone = .plain
    let icon: String
    let text: String
    let actionTitle: String?
    let identifier: String
    let action: () -> Void
    @Environment(\.globalDMBoxRole) private var role
    /// W184 F2：換形態途中左右留白連續變（16 ↔ 20）；停著＝nil（照角色）。
    @Environment(\.globalDMSideMargin) private var sideMargin

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: GlobalDMChatLayout.glyphSize, weight: .medium))
                .foregroundStyle(tone == .attention ? AnyShapeStyle(LiquidGlassTokens.brandAccent) : AnyShapeStyle(.secondary))
            Text(text)
                .font(.system(size: GlobalDMChatLayout.noticeSize))
                .foregroundStyle(.primary)
                .lineLimit(GlobalDMChatLayout.noticeLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            if let actionTitle {
                GlobalDMChipButton(title: actionTitle, action: action)
                    .accessibilityIdentifier(identifier + ".action")
            }
        }
        .padding(.leading, GlobalDMChatLayout.noticeLeading)
        .padding([.trailing, .vertical], GlobalDMChatLayout.noticeInset)
        .frame(minHeight: GlobalDMChatLayout.noticeMinHeight)
        .chatLiquidSection(cornerRadius: GlobalDMChatLayout.noticeRadius,
                           accentOpacity: tone == .attention ? GlobalDMChatLayout.attentionAccentOpacity : 0)
        .padding(.horizontal, sideMargin ?? GlobalDMChatLayout.sideMargin(for: role))
        .padding(.bottom, GlobalDMChatLayout.noticeSpacing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// 訊息區（W184 C：照手機 App）：我說的＝靠右泡泡（最寬約 78%）；回覆＝全寬、沒有泡泡、不帶頭像（對象由頂列圓鈕表示）；
/// 錯誤卡、系統說明、「用了 N 條記憶」、打字點點照舊（Coder 的元件）。內距 上 10、左右 16（內橫兩欄 20）、下 16，
/// 訊息間距 18；貼底排（訊息少時靠近輸入框，新訊息在下）。
/// Equatable：打字時只有輸入框重畫，訊息區不重算。只在主執行緒比較（isolated conformance，Swift 6 並行檢查）。
struct GlobalDMMessageList: View, @MainActor Equatable {
    let bubbles: [GlobalDMBubble]
    let emptyText: String
    /// 回覆中那一列的說明用（誰在回覆）；畫面上不畫頭像。
    var avatarRoute: ChatRouteChoice? = nil
    var fallbackAvatar: GlobalDMTarget = .assistant
    /// W184 G3b：對象是 ChatGPT（照 ChatGPT iPhone App）：自己的泡泡反白（淺色黑底白字、深色淺底黑字）、回答中左邊一個灰字「思考」。
    var chatGPTLook = false
    var fleet: DeviceFlowSession? = nil
    var fleetRevision = 0
    var recoverChatGPT: ((ChatGPTTurnFailure) -> Void)? = nil
    var recoveryAvailable = true
    @Environment(\.globalDMBoxRole) private var role
    /// W184 F2：換形態途中左右留白連續變（16 ↔ 20）；停著＝nil（照角色）。
    @Environment(\.globalDMSideMargin) private var sideMargin

    /// W184 G3b（使用者 09-29 17:35：「字的滑動天地改漸出 現在是切線」）：上下緣各 24 淡出（文字淡出，不是一刀切）。
    static let edgeFade: CGFloat = 24
    /// W184 G3c（使用者 09-30：「文字頂部漸淡應頂天 不是空一節」）：列表往上延伸多少（手機框給頂列的高度；內橫右欄的 ChatGPT 再加它自己那一排）。
    /// 捲動區延伸到框的上緣（頂列那一段的列都畫得到——捲動區只畫跟它相交的列），上緣的漸淡在框的上緣；第一則上面多留這麼多
    /// （捲到最上面時在頂列下面、捲動時可以捲進頂列底下）。用內容裡的內距，不用 contentMargins／safeArea：那兩個在 AppKit 那一層是
    /// contentInsets，會動到捲動位置的算法（W184 F3T 的 H1、R2 量到）。
    @Environment(\.globalDMListBleed) private var bleed
    /// W184 AB（R2；GPT-6 審 G3c #4）：每一則目前的位置（GlobalDMListRows）：換形態時面板控制器用它守住使用者在讀的那一則
    /// （頂列底下看得到的第一則），排版之後捲回原來的位置。
    @State private var rows = GlobalDMListRows()

    #if DEBUG
    /// 自測用：每一則的遮罩最後量到的上緣位置（捲動區座標；負的＝這一則有一段捲出上緣）——看得出位置有沒有跟著捲動。
    @MainActor static var rowTopsForSelfTest: [String: CGFloat] = [:]
    #endif

    static func == (lhs: GlobalDMMessageList, rhs: GlobalDMMessageList) -> Bool {
        lhs.bubbles == rhs.bubbles && lhs.emptyText == rhs.emptyText
            && lhs.avatarRoute?.id == rhs.avatarRoute?.id && lhs.fallbackAvatar == rhs.fallbackAvatar && lhs.chatGPTLook == rhs.chatGPTLook
            && lhs.fleet === rhs.fleet && lhs.fleetRevision == rhs.fleetRevision
            && lhs.recoveryAvailable == rhs.recoveryAvailable
    }

    /// 一則在捲動區裡的位置 → 它自己由上到下的遮罩（純計算，好測）：捲動區最上面 0→24 從透明到不透明、最下面 24 反過來，
    /// top／bottom 是那一邊淡多少（0＝不淡、1＝整個 24，見 fadeStrength）。W184 G3c：捲動區延伸到框的上緣，這裡的 0 就是框的上緣。
    static func fadeStops(rowMinY: CGFloat, rowHeight: CGFloat, viewport: CGFloat, top: CGFloat, bottom: CGFloat) -> [Gradient.Stop] {
        guard rowHeight > 0 else { return [.init(color: .black, location: 0), .init(color: .black, location: 1)] }
        let maxY = rowMinY + rowHeight
        var ys = [rowMinY, maxY]
        for y in [0, edgeFade, viewport - edgeFade, viewport] where y > rowMinY && y < maxY { ys.append(y) }
        return ys.sorted().map { y in
            Gradient.Stop(color: Color.black.opacity(fadeAlpha(y: y, viewport: viewport, top: top, bottom: bottom)),
                          location: (y - rowMinY) / rowHeight)
        }
    }

    /// 捲動區裡高度 y 那一條線要多不透明（0＝完全淡掉、1＝完整）：離上緣、下緣 24 以內照距離淡出，乘上那一邊的強度。
    static func fadeAlpha(y: CGFloat, viewport: CGFloat, top: CGFloat, bottom: CGFloat) -> Double {
        let fromTop = min(1, max(0, y / edgeFade)), fromBottom = min(1, max(0, (viewport - y) / edgeFade))
        return Double(min(1 - top * (1 - fromTop), 1 - bottom * (1 - fromBottom)))
    }

    /// 這一則的上緣／下緣要淡多少（不靠整個列表的狀態，每一則自己算，捲動時一路連續、不會跳）：
    /// 中間的每一則都是 1；第一則照「從內容最上面捲開多遠」、最後一則照「離內容最下面還有多遠」，0→24 從 0 變 1——
    /// 捲到最上面時第一則不淡、捲到最下面時最後一則（回答、「用了 N 條記憶」）完整清楚。
    /// W184 G3c：topInset＝第一則在內容最上面時的上緣（listTop＋往上延伸的那一段）。
    static func fadeStrength(rowMinY: CGFloat, rowMaxY: CGFloat, viewport: CGFloat, isFirst: Bool, isLast: Bool,
                             topInset: CGFloat = GlobalDMChatLayout.listTop) -> (top: CGFloat, bottom: CGFloat) {
        let top = isFirst ? min(1, max(0, (topInset - rowMinY) / edgeFade)) : 1
        let bottom = isLast ? min(1, max(0, (rowMaxY + GlobalDMChatLayout.listBottom - viewport) / edgeFade)) : 1
        return (top, bottom)
    }

    var body: some View {
        #if DEBUG
        let _ = GlobalDMListRows.noteListed(bubbles)   // W184 AB（H12）：自測看每一則什麼時候進到列表
        #endif
        GeometryReader { geometry in
            let side = sideMargin ?? GlobalDMChatLayout.sideMargin(for: role)
            let headerAvoidanceInset = max(0, bleed)
            let viewportHeight = max(0, geometry.size.height - headerAvoidanceInset)
            let topInset = GlobalDMChatLayout.listTop
            let rowWidth = max(120, geometry.size.width - side * 2)
            if bubbles.isEmpty && fleet?.active == nil {
                Text(emptyText)
                    .font(.system(size: GlobalDMChatLayout.noticeSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, side)
                    .frame(width: geometry.size.width, height: max(0, geometry.size.height - bleed))
                    .offset(y: bleed)   // W184 G3c：空白說明照舊在頂列下面那一塊的正中間
            } else {
                let gaps = GlobalDMChatLayout.gaps(bubbles)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
                                row(bubble, rowWidth: rowWidth)
                                    .modifier(GlobalDMEdgeFade(id: bubble.id, viewport: viewportHeight, isFirst: index == 0,
                                                               isLast: index == bubbles.count - 1, topInset: topInset))
                                    // W184 AB（R2）：第一行字離這一則上緣多遠（我說的泡泡＝上內距）；捲出懶載入範圍就不再記它的位置。
                                    .environment(\.globalDMRowLead, bubble.kind == .mine ? GlobalDMChatLayout.userBubbleVerticalPadding : 0)
                                    .padding(.top, gaps[index])
                                    .id(bubble.id)
                                    .onDisappear { rows.forget(bubble.id) }
                            }
                            if let fleet, fleet.active != nil {
                                DeviceFlowCard(session: fleet)
                                    .padding(.top, bubbles.isEmpty ? 0 : GlobalDMChatLayout.messageSpacing)
                                    .id("tatwo.dm.fleet.card")
                            }
                            // 底部內距放在尾巴裡：捲到最後時最後一則離輸入框 16。
                            Color.clear.frame(height: GlobalDMChatLayout.listBottom).id("tatwo.dm.tail")
                        }
                        .frame(width: rowWidth, alignment: .leading)
                        .padding(.horizontal, side)
                        .padding(.top, topInset)   // W184 G3c：listTop＋往上延伸的那一段（可以捲進頂列底下）
                        .frame(minHeight: viewportHeight, alignment: .bottom)
                        // W184 AB（R2）：跟著內容捲的座標（量每一則時知道那一刻捲到哪：捲過以後沒再量的列，位置是舊的）。
                        .coordinateSpace(name: Self.contentSpace)
                        // W184 AB（R2）：位置記錄掛在捲動區裡（1pt、看不見、點不到），面板控制器從這個捲動區找得到它。
                        .background(alignment: .topLeading) {
                            GlobalDMListRowsProbe(rows: rows).frame(width: 1, height: 1).accessibilityHidden(true)
                        }
                    }
                    .coordinateSpace(name: Self.space)
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.hidden)
                    .padding(.top, headerAvoidanceInset)
                    // 淡出是每一則自己遮（GlobalDMEdgeFade），不遮整個 ScrollView：Coder 對話區遮整個 ScrollView 在 live 大視窗
                    // 會把內文遮成透明（ChatPage+Transcript 已經拿掉過）。
                    .environment(\.globalDMChatGPTLook, chatGPTLook)
                    .environment(\.globalDMListRows, rows)
                    .onAppear { scrollToTail(proxy) }
                    .onChange(of: bubbles.count) { _, _ in scrollToTail(proxy) }
                    .onChange(of: bubbles.last?.text) { _, _ in scrollToTail(proxy) }
                    .onChange(of: fleetRevision) { _, _ in scrollToTail(proxy) }
                }
            }
        }
        .environment(\.chatNoteTypography, GlobalDMChatLayout.noteTypography)   // 說明字 13、小標 11（手機 token）
        // W194：沿用框提供的頂列高度，但捲動 viewport 避開浮動頭像；四種形態都不讓文字進入頭像區。
        .padding(.top, -bleed)
        .frame(maxHeight: .infinity)
    }

    static let space = "tatwo.dm.messageList"
    /// W184 AB（R2）：跟著內容捲的座標（GlobalDMListRows 用它分出捲過以後沒再量的列）。
    static let contentSpace = "tatwo.dm.messageContent"

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("tatwo.dm.tail", anchor: .bottom) }
    }

    @ViewBuilder
    private func row(_ bubble: GlobalDMBubble, rowWidth: CGFloat) -> some View {
        switch bubble.kind {
        case .mine:
            HStack(spacing: 0) {
                Spacer(minLength: rowWidth - GlobalDMChatLayout.userBubbleMaxWidth(rowWidth: rowWidth))
                GlobalDMUserBubble(text: bubble.text)
            }
            .frame(width: rowWidth, alignment: .trailing)
        case .theirs:
            // W179 F：照 Coder 的方式排版 Markdown（表格、清單、程式碼用 Coder 的元件；一般段落用行內樣式）。
            GlobalDMRichText(text: bubble.text)
                .frame(width: rowWidth, alignment: .leading)
        case .error:
            if let failure = bubble.turnFailure {
                ChatGPTTurnFailureRow(failure: failure) { recoverChatGPT?(failure) }.disabled(!recoveryAvailable)
            } else if let error = bubble.error {
                // Coder 的錯誤卡本身內縮頭像欄（34）；回覆不帶頭像，這裡抵掉，左緣對齊回覆的字。
                ChatErrorCard(presentation: error, rowWidth: rowWidth + ChatErrorCard.textColumnInset, canRetry: false, onRetry: {})
                    .padding(.leading, -ChatErrorCard.textColumnInset)
            }
        case .note:
            if let note = bubble.note {
                ChatSystemNoteRow(presentation: note, rowWidth: rowWidth)
            }
        case .typing:
            // 回覆中還沒出字：打字點點（不帶頭像）；說明寫誰在回覆（有回報模型就用它）。W184 G3b：ChatGPT 的是灰字「思考」（環境值）。
            if let thinking = bubble.thinking { ChatGPTThinkingRow(thinking: thinking) }
            else { GlobalDMTypingRow(route: bubble.modelID.map(ChatRouteChoice.resolve) ?? avatarRoute, rowWidth: rowWidth) }
        }
    }
}

/// W184 G3b（使用者 09-29：「字的滑動天地改漸出 現在是切線」）：一則訊息照它在捲動區裡的位置自己淡出（上下緣各 24）。
/// 遮罩裡量這一則在捲動區（GlobalDMMessageList.space）裡的位置，捲動時跟著重算；遮的是這一則自己（純 SwiftUI 的字與泡泡）。
/// 第一則、最後一則在捲到最上面／最下面時不淡（GlobalDMMessageList.fadeStrength）。
struct GlobalDMEdgeFade: ViewModifier {
    let id: String
    let viewport: CGFloat
    let isFirst: Bool
    let isLast: Bool
    /// W184 G3c：第一則在內容最上面時的上緣（listTop＋往上延伸的那一段）。
    var topInset: CGFloat = GlobalDMChatLayout.listTop
    /// W184 AB（R2）：量到的位置順手記進這個列表的位置記錄（換形態時守住在讀的那一則）。
    @Environment(\.globalDMListRows) private var rows
    @Environment(\.globalDMRowLead) private var lead

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(GlobalDMMessageList.space))
                let strength = GlobalDMMessageList.fadeStrength(rowMinY: frame.minY, rowMaxY: frame.maxY, viewport: viewport,
                                                                isFirst: isFirst, isLast: isLast, topInset: topInset)
                let _ = rows?.record(id, frame: frame, content: proxy.frame(in: .named(GlobalDMMessageList.contentSpace)), lead: lead,
                                     covered: topInset - GlobalDMChatLayout.listTop, viewport: viewport)
                #if DEBUG
                let _ = GlobalDMMessageList.recordRowTop(id, frame.minY)
                #endif
                LinearGradient(stops: GlobalDMMessageList.fadeStops(rowMinY: frame.minY, rowHeight: frame.height, viewport: viewport,
                                                                    top: strength.top, bottom: strength.bottom),
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

// MARK: - W184 G3c：訊息列表頂天

private struct GlobalDMListBleedKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// W184 G3c：訊息列表往上延伸多少（0＝不延伸；手機框給頂列的高度，內橫右欄的 ChatGPT 再加它自己那一排）。
    var globalDMListBleed: CGFloat {
        get { self[GlobalDMListBleedKey.self] }
        set { self[GlobalDMListBleedKey.self] = newValue }
    }
}

#if DEBUG
extension GlobalDMMessageList {
    @MainActor static func recordRowTop(_ id: String, _ minY: CGFloat) -> Bool {
        rowTopsForSelfTest[id] = minY
        return true
    }
}
#endif

/// 輸入列＝TATWO 輸入框的精簡版：Coder 的文字元件（中文輸入法組字中不送；Return 送出、Shift+Return 換行，最多約 5 行）、
/// 玻璃卡；W180 A4：文字下面一列：左邊「＋」附件、右邊記憶、模型 chip 與送出／停止；
/// 有附件時文字上方一排附件小卡；⌘V、拖檔案進來也是附件。每個對象各自保留草稿與附件。
/// W181：iPhone 的樣子——輸入框貼著框底、圓角與框同心；「⌥⌘ 開關」那行小字在框頂（GlobalDMBox.header）。
/// W184 C（對照稿 Main、Outer-ChatGPT）：玻璃膠囊——外距 左右下 12、內距 12／12／10／16、圓角 52−12＝40；
/// 兩層：上面 17pt 的字（佔位字照舊），下面一排 ＋（36 圓、往左凸 6）…記憶、模型（32 高膠囊）、送出（36 強調色圓）／停止。
/// 對象是 ChatGPT 時輸入框上方置中一行說明（OS 不記錄對話內容・用你自己的 ChatGPT 帳號）。
/// 送出、停止、工具列是私訊框自己的（GlobalDMChatPhone.swift）；Coder 共用的 ChatComposerChrome 不改。
struct GlobalDMComposer: View {
    @ObservedObject var store: GlobalDMStore
    let placeholder: String
    let isRunning: Bool
    let canSend: Bool
    /// W184 G3：ChatGPT 那一欄的對話（沒給＝store.chatGPT）；ChatGPT 的三層看它回答中沒有、語音。
    let chatGPTSession: ChatGPTConversationSession?
    @State private var textHeight: CGFloat = GlobalDMChatLayout.inputMinimumHeight
    @State private var focused: Bool
    @Environment(\.globalDMBoxRole) private var role
    /// W184 F2：換形態途中左右留白連續變（16 ↔ 20）；停著＝nil（照角色）。
    @Environment(\.globalDMSideMargin) private var sideMargin
    /// W183 R5b 審查（Claude）：網頁頁面蓋著時整個輸入列拿掉——鍵盤不會留在看不見的草稿、Enter 不會送出。
    @Environment(\.globalDMWebSheetActive) private var webSheetActive
    /// W184 H4：模式卡開著沒有（記憶、模型收進「模式選擇」chip；卡浮在輸入框上方）；chip 的位置（點 chip 不算點卡外面）。
    @State private var modeOpen: Bool
    @State private var modeAnchor = AssistantModelMenuAnchor()

    init(store: GlobalDMStore, placeholder: String, isRunning: Bool, canSend: Bool = true, initiallyFocused: Bool = true,
         chatGPTSession: ChatGPTConversationSession? = nil, modeCardOpen: Bool = false) {
        _store = ObservedObject(wrappedValue: store)
        self.placeholder = placeholder
        self.isRunning = isRunning
        self.canSend = canSend
        self.chatGPTSession = chatGPTSession
        _focused = State(initialValue: initiallyFocused)
        _modeOpen = State(initialValue: modeCardOpen)   // W184 H4：自測畫卡片開著的樣子
    }

    var body: some View {
        if !webSheetActive { composer }   // W183 R5b 審查
    }

    @ViewBuilder private var composer: some View {
        let target = store.target
        let draft = Binding(get: { store.draft(for: target) }, set: { store.setDraft($0, for: target) })
        let files = store.attachments(for: target)
        // W180 修正：Coder 清單開著時輸入列先收小（附件小卡收起、文字只留一行），框很矮時清單才有可用的高度；
        // 草稿與附件都還在，清單收起就回來。
        let folded = store.isPickerOpen
        let textFrame = folded ? GlobalDMChatLayout.inputMinimumHeight
            : min(GlobalDMChatLayout.inputMaximumHeight, max(GlobalDMChatLayout.inputMinimumHeight, textHeight))
        VStack(spacing: 0) {
            // W184 C：ChatGPT 的說明行（原本在頂列名字行）；別的對象沒有。
            if GlobalDMChatLayout.showsChatGPTCaption(for: target) {
                GlobalDMChatGPTCaption()
                    .padding(.horizontal, sideMargin ?? GlobalDMChatLayout.sideMargin(for: role))
                    .padding(.bottom, GlobalDMChatLayout.captionBottom)
            }
            VStack(alignment: .leading, spacing: GlobalDMChatLayout.composerLayerSpacing) {
                if target == .chatGPT {
                    // W184 G3：ChatGPT 對象＝ChatGPT Space 的輸入框（共用元件、私訊框的手機 token；GlobalDMChatGPTComposer.swift）：
                    // ＋ 分層選單、工具小卡、附件縮圖、思考強度膠囊、語音輸入、語音模式／送出／停止。外框照這裡（說明行、玻璃膠囊、內外距）。
                    GlobalDMChatGPTComposerLayers(store: store, session: chatGPTSession ?? store.chatGPT, placeholder: placeholder,
                                                  canSend: canSend, folded: folded, textHeight: $textHeight, focused: $focused)
                } else {
                    if !files.isEmpty, !folded {
                        GlobalDMAttachmentRow(store: store, files: files)
                    }
                    // W184 H4 修正第二輪（主導看 0.7 倍 PNG：「輸入框的字被 chip 那一列蓋住」）：文字區只露整行——可見高度＝整數行
                    // （至少一行），比它長的在文字區裡捲；不露半行、不跟下面那排疊在一起。零頭留白在文字區下面（GlobalDMComposerText）。
                    ChatComposerTextView(text: draft, contentHeight: $textHeight, isFocused: focused,
                        placeholder: placeholder, isMonospaced: false,
                        // 文件至少一整行（不是 24）：一行字時文件跟看得到的一樣高，不會被捲動 4pt 露出半行。
                        minimumHeight: GlobalDMComposerText.visibleHeight(GlobalDMChatLayout.inputMinimumHeight),
                        maximumHeight: GlobalDMChatLayout.inputMaximumHeight,
                        onSubmit: { _ = store.send() }, onFocusChange: { focused = $0 },
                        onPasteImage: { store.pasteAttachment(from: $0) },
                        accessibilityTextLabel: "私訊內容", pointSize: GlobalDMChatLayout.messageSize, slashCommands: [])
                        .frame(height: GlobalDMComposerText.visibleHeight(textFrame))
                        .frame(height: textFrame, alignment: .top)
                        .accessibilityIdentifier("tatwo.dm.input")
                        .id(target)
                    HStack(spacing: GlobalDMChatLayout.composerItemSpacing) {
                        GlobalDMAttachButton(store: store)
                            .padding(.leading, GlobalDMChatLayout.plusOutset)
                        if target == .assistant { DeviceFlowChip(session: .shared) }
                        Spacer(minLength: 4)
                        // W184 H4：記憶、模型收進一顆「模式選擇」（按了在輸入框上方開模式卡）；舊識別碼 tatwo.dm.model、tatwo-memory-strength
                        // 在 chip 的兩段上；記憶照舊只在助理與 Coder 對話（ChatGPT、Bot 串不顯示）。
                        GlobalDMModeChip(store: store, isOpen: $modeOpen, anchor: modeAnchor)
                        if isRunning {
                            GlobalDMStopButton { store.stop() }
                                .accessibilityLabel("停止")
                                .accessibilityIdentifier("tatwo.dm.stop")
                        } else {
                            GlobalDMSendButton(enabled: canSend && store.hasContentToSend) {
                                _ = store.send()
                            }
                            .help("送出")
                            .accessibilityLabel("送出")
                            .accessibilityIdentifier("tatwo.dm.send")
                        }
                    }
                    .frame(height: GlobalDMChatLayout.controlSize)
                    .background(GlobalDMComposerControlsMarker())   // W184 H4 修正第二輪：自測量這一排的位置（不畫、不接點擊）
                }
            }
            .padding(.top, GlobalDMChatLayout.composerTop)
            .padding(.trailing, GlobalDMChatLayout.composerTrailing)
            .padding(.bottom, GlobalDMChatLayout.composerBottom)
            .padding(.leading, GlobalDMChatLayout.composerLeading)
            // W184 G3c（使用者：「chatgpt duo輸入筐造型r角很醜」）：對象是 ChatGPT 也是這個玻璃膠囊（跟其他對象一致；圓角跟框同心 52−12＝40）。
            .liquidGlassPanelSurface(cornerRadius: GlobalDMChatLayout.composerRadius)
            // W184 H4：模式卡浮在輸入框上方 8、右緣對齊輸入框（手機尺寸）；點卡以外的地方收起。換對象、開 session 清單時收起。
            .tatwoComposerModeCard(isPresented: $modeOpen, anchor: modeAnchor) { GlobalDMModeCard(store: store) }
            .padding(.horizontal, GlobalDMChatLayout.composerInset)
            .padding(.bottom, GlobalDMChatLayout.composerInset)
        }
        .onChange(of: target) { _, _ in modeOpen = false }
        .onChange(of: store.isPickerOpen) { _, open in if open { modeOpen = false } }
        // W184 AB（H4 查核 #9）：卡開著沒有跟 store 兩邊同步——Esc 的路由（GlobalDMPanelController.routeEscape）看 store 收卡。
        .onChange(of: modeOpen, initial: true) { _, open in if store.isModeCardOpen != open { store.isModeCardOpen = open } }
        .onChange(of: store.isModeCardOpen) { _, open in if modeOpen != open { modeOpen = open } }
    }
}

/// W184 H4 修正第二輪（主導看 0.7 倍 PNG）：私訊框輸入框的文字區只露整行。行高＝輸入框那個字級的預設行高（TextKit 1，
/// 中英文同一個行高）；可見高度取整數行、至少一行（例：最矮的 24 只露 1 行＝20，不再露出第 2 行的上緣）。
@MainActor
enum GlobalDMComposerText {
    static let lineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: GlobalDMChatLayout.messageSize))

    static func visibleHeight(_ frame: CGFloat) -> CGFloat {
        guard lineHeight > 1 else { return frame }
        let lines = max(1, Int((frame + 0.5) / lineHeight))
        return min(frame, CGFloat(lines) * lineHeight)
    }
}

/// 私訊框輸入框底下那一排（＋、模式選擇、送出）的位置點：不畫、不接點擊；自測量文字區有沒有跟它疊在一起。
struct GlobalDMComposerControlsMarker: NSViewRepresentable {
    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}
}

/// 鍵帽樣式的小字（⌥⌘G）：同 Coder 系統說明列的標籤。
struct GlobalDMKey: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - 框級圖示鈕（W179 UI）

/// 玻璃圓底：公式同 App 的玻璃 chip（chatGlassChip），形狀是圓。框級圖示鈕（✕、尺寸、返回、清除）都用它。
struct GlobalDMGlassCircle: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var isSelected = false

    var body: some View {
        if TatwoActivePalette.current.usesGlass {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay { Circle().fill(Color.white.opacity(0.26)) }
                .overlay {
                    Circle().fill(LiquidGlassTokens.tint.opacity(isSelected ? 0.15 : LiquidGlassTokens.chipFillOpacity))
                }
                .overlay {
                    Circle().strokeBorder(LiquidGlassTokens.tint.opacity(isSelected ? 0.22 : LiquidGlassTokens.strokeOpacity * 0.7))
                }
        } else {
            Circle()
                .fill(isSelected
                    ? AnyShapeStyle(LiquidGlassTokens.brandAccent.opacity(0.15))
                    : AnyShapeStyle(TatwoActivePalette.current.surfaceFill))
                .overlay {
                    Circle().strokeBorder(isSelected
                        ? LiquidGlassTokens.brandAccent.opacity(0.55)
                        : TatwoActivePalette.current.surfaceBorder.opacity(0.75), lineWidth: 1)
                }
        }
    }
}

/// W181：玻璃膠囊底（私訊框輸入列的 chip）：公式同 GlobalDMGlassCircle，形狀是膠囊。
struct GlobalDMGlassCapsule: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared

    var body: some View {
        if TatwoActivePalette.current.usesGlass {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay { Capsule().fill(Color.white.opacity(0.26)) }
                .overlay { Capsule().fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity)) }
                .overlay { Capsule().strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity * 0.7)) }
        } else {
            Capsule()
                .fill(TatwoActivePalette.current.surfaceFill)
                .overlay { Capsule().strokeBorder(TatwoActivePalette.current.surfaceBorder.opacity(0.75), lineWidth: 1) }
        }
    }
}

/// W181（使用者 09-27：「這邊輸入筐比例很醜」）：私訊框輸入列的 chip：玻璃膠囊、寬度跟著字（不是固定寬的方塊）。
/// 模型 chip、記憶 chip 都用它。W184 C（對照稿）：32 高、13pt、左 12 右 10，⌄ 用最小字級。
struct GlobalDMChipLabel: View {
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: GlobalDMChatLayout.footnoteSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let value {
                Text(value)
                    .font(.system(size: GlobalDMChatLayout.footnoteSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: GlobalDMChatLayout.captionSize, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(height: GlobalDMChatLayout.chipHeight)
        .background(GlobalDMGlassCapsule())
        .contentShape(Capsule())
    }
}

/// 圓形玻璃圖示鈕的樣子（28pt，同送出鈕）。
struct GlobalDMIconLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: GlobalDMLayout.iconButtonSize, height: GlobalDMLayout.iconButtonSize)
            .background(GlobalDMGlassCircle())
            .contentShape(Circle())
    }
}

/// W180 A3／D2：點 Coder 圖示展開的 session 選擇（就是原本對象清單裡的 Coder 對話那一段）：最近的 session
/// （子討論串掛在父 session 下面、所有配對設備的都列、標設備名）、其他專案的對話搜尋；連不上的配對設備各一行說明。
/// W179 UI：只在內容區裡（標題列以下、輸入列以上），超出就在清單裡捲動；底板同 Coder 的模型選單（玻璃）。選了就切過去、收起。
struct GlobalDMTargetPicker: View {
    @ObservedObject var store: GlobalDMStore
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if store.isBrowsingAllSessions { allSessions } else { groups }
        }
        .padding(6)
        .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        .frame(maxHeight: maxHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.targets")
    }

    private var groups: some View {
        ViewThatFits(in: .vertical) {
            groupRows.fixedSize(horizontal: false, vertical: true)
            ScrollView { groupRows }
        }
        .frame(maxHeight: max(0, maxHeight - 12))
    }

    private var groupRows: some View {
        let rows = store.sessionRows()
        return VStack(alignment: .leading, spacing: 1) {
            heading("Coder 對話 · 最近")
            if rows.isEmpty {
                Text("還沒有 Coder 對話").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(8)
            }
            ForEach(rows) { sessionRow($0) }
            Button { store.isBrowsingAllSessions = true } label: {
                row(avatar: GlobalDMAvatar(letter: "C", color: GlobalDMPalette.sessionAvatar, size: 20),
                    title: "其他專案的對話…", current: false, trailing: nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tatwo.dm.targets.more")
        }
    }

    /// 每列右側顯示它的直達鍵（⌥⌘＋鍵）。
    private func keyHint(_ target: GlobalDMTarget) -> AnyView? {
        if let key = store.directKeys[target] { return AnyView(GlobalDMKey(key.display)) }
        return nil
    }

    private var allSessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { store.isBrowsingAllSessions = false; store.sessionQuery = "" } label: {
                    GlobalDMIconLabel(systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("回對象清單")
                .accessibilityLabel("回對象清單")
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                    ChatChipTextField(title: "搜尋專案或對話", text: $store.sessionQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .accessibilityIdentifier("tatwo.dm.targets.search")
                }
                .padding(.horizontal, 9)
                .frame(height: GlobalDMLayout.iconButtonSize)
                .chatGlassChip()
            }
            let results = store.sessionRows(query: store.sessionQuery, everything: true)
            let rows = VStack(alignment: .leading, spacing: 1) {
                if results.isEmpty {
                    Text("找不到符合的對話").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(8)
                }
                ForEach(results) { sessionRow($0) }
            }
            ViewThatFits(in: .vertical) {
                rows.fixedSize(horizontal: false, vertical: true)
                ScrollView { rows }
            }
        }
        .frame(maxHeight: max(0, maxHeight - 12), alignment: .top)
    }

    /// 一條 session：最上層「設備 · 專案 › 標題」；子討論串縮排、只寫自己的標題（完整名字在說明與無障礙名稱）。
    private func sessionRow(_ item: GlobalDMSessionRow) -> some View {
        let session = item.session
        let target = GlobalDMTarget.thread(session.id)
        return Button { store.select(target) } label: {
            row(avatar: GlobalDMAvatar(letter: GlobalDMSessionCandidate.abbreviation(session.projectName),
                                       color: GlobalDMPalette.color(for: session.isOffline ? .offline : .session),
                                       size: item.depth > 0 ? 16 : 20),
                title: item.depth > 0 ? "↳ " + session.shortLabel : session.displayLabel,
                current: store.target == target, trailing: keyHint(target), indent: CGFloat(item.depth) * 14)
                .opacity(session.isOffline ? 0.6 : 1)   // W182 R4：連不上那台的對話照樣列出（灰、只能看）
        }
        .buttonStyle(.plain)
        .help(session.isOffline ? session.displayLabel + "（離線，只能看）" : session.displayLabel)
        .accessibilityLabel(session.displayLabel)
        .accessibilityIdentifier("tatwo.dm.targets." + target.storageValue)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 3)
    }

    private func row(avatar: GlobalDMAvatar, title: String, current: Bool, trailing: AnyView?,
                     indent: CGFloat = 0) -> some View {
        HStack(spacing: 8) {
            avatar
            Text(title)
                .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let trailing { trailing }
        }
        .foregroundStyle(Color.primary)
        .padding(.leading, 8 + indent).padding(.trailing, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
        .chatMenuRowHover(isSelected: current)
    }
}

/// 清單右側的小標籤（「之後」「Space 已關閉」）。
struct GlobalDMBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}
