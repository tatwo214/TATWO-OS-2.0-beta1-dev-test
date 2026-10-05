import AppKit
import SwiftUI

// W184 AB（使用者 09-29：「私訊鈕的ui完全垃圾 應該要參照手機app的規格去設計」「目前滿意的只有上面圓鈕跟私訊筐比例、倒角」
// 「照現在這樣放左上並只呈現當前頁面的logo 滑鼠指到時向右滑展開出現其他logo」「duo的形式已經ok就照你的設計去做」；
// 對照稿 https://claude.ai/artifact/RoVoQkiMN13LDhD9Hj2s2g 的 A-Proto、Forms、Main、Outer-*、Open-*）：
// 私訊框＝一支 iPhone Duo。一個面板裡整支手機的樣子都在這裡：
// - 倒放：整塊是 GlobalDMTentContent（房 E），沒有頂列；離開靠 ⌘⌥Tab 或房 E 的鈕，⌥⌘ 開關照舊。
// - 其他形態：一條頂列（左上目前頁面的圓鈕；對話與 Browser 同一條、高度不跳）＋一欄（外直、內直）或兩欄（內橫：
//   左欄目前對象的對話、右欄 Browser 或另一個對象的對話，中間 0.5 分隔線）。
// - W184 F（使用者 09-29 看了 v2.0.21.029：右上「⋯」「⌄」「這兩個鈕也是不用的」）：右上兩顆拿掉；原本「⋯ 更多」的項目改成左上頁面圓鈕的
//   右鍵選單（control＋點也開）；收起靠 ⌥⌘ 與 Esc。左上圓鈕的位置不動，頂列高度照舊 68（內容區不跳）。
// - 左欄永遠是這一個 GlobalDMBox（同一個位置）：外直↔內橫↔內直換形態時對話不重建（捲動位置、草稿、輸入焦點都在）。
// 數值一律從 DMPhone 取；顏色照 GlobalDMPalette 的規則用 App 的玻璃 token 與系統語意色；不用藍色系統鈕。

// MARK: - 環境值

private struct GlobalDMFormEnvironmentKey: EnvironmentKey {
    static let defaultValue: GlobalDMForm = .outerPortrait
}

private struct GlobalDMScreenRadiusKey: EnvironmentKey {
    static let defaultValue: CGFloat = DMPhone.screenRadius
}

private struct GlobalDMStripPinnedOpenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct GlobalDMSideMarginKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct GlobalDMSurfaceKey: EnvironmentKey {
    static let defaultValue: GlobalDMSurface = .floating
}

/// W184 F／G1（GPT-6 審查 #5）：私訊框裡的 Browser 用哪一份（Browser、連線流程、連線卡片的呈現層）。正式＝都是 nil（這台的 .shared）；
/// 自測把假的 Browser（假授權頁、假配對頁與配對碼）接進真的面板控制器，驗換形態、拖、縮放、換手時的截圖保護。
struct GlobalDMBrowserServices: Sendable {
    var browser: DMBrowser?
    var flow: HandsConnectFlow?
    var connect: HandsConnectPresenter?
    /// W183 R12：任務版面（左頁掛任務卡；正式＝.shared）。
    var taskLayout: GlobalDMTaskLayout? = nil
}

private struct GlobalDMBrowserServicesKey: EnvironmentKey {
    static let defaultValue = GlobalDMBrowserServices()
}

extension EnvironmentValues {
    /// 框現在是哪個形態（訊息區、輸入框照 DMPhone.sideMargin(for:) 挑左右留白）。
    var globalDMForm: GlobalDMForm {
        get { self[GlobalDMFormEnvironmentKey.self] }
        set { self[GlobalDMFormEnvironmentKey.self] = newValue }
    }

    /// 框現在的圓角（縮小時等比）；貼著框邊的輸入框、操作列用它減 DMPhone.edgeInset 算同心圓角。
    var globalDMScreenRadius: CGFloat {
        get { self[GlobalDMScreenRadiusKey.self] }
        set { self[GlobalDMScreenRadiusKey.self] = newValue }
    }

    /// 自測畫面證據用：左上的圓鈕列固定展開（平常照滑鼠指到才展開）。
    var globalDMStripPinnedOpen: Bool {
        get { self[GlobalDMStripPinnedOpenKey.self] }
        set { self[GlobalDMStripPinnedOpenKey.self] = newValue }
    }

    /// W184 F2：頂列、訊息區、提示列的左右留白（換形態途中從 16 連續變到 20、或反過來；nil＝照形態、角色）。
    var globalDMSideMargin: CGFloat? {
        get { self[GlobalDMSideMarginKey.self] }
        set { self[GlobalDMSideMarginKey.self] = newValue }
    }

    /// 這支手機是停靠框還是浮動框（頁面圓鈕右鍵的「收起私訊框」收的就是它）。
    var globalDMSurface: GlobalDMSurface {
        get { self[GlobalDMSurfaceKey.self] }
        set { self[GlobalDMSurfaceKey.self] = newValue }
    }

    /// 框裡的 Browser 用哪一份（面板控制器從根畫面給；正式＝.shared）。
    var globalDMBrowserServices: GlobalDMBrowserServices {
        get { self[GlobalDMBrowserServicesKey.self] }
        set { self[GlobalDMBrowserServicesKey.self] = newValue }
    }
}

// MARK: - 整支手機

struct GlobalDMPhoneBox: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var model: ChatPageModel
    let surface: GlobalDMSurface
    let form: GlobalDMForm
    /// 內橫右欄的另一個對象（第二個 store）；拿不到時右欄放 Browser。
    var secondary: GlobalDMStore? = nil
    @Environment(\.globalDMBrowserServices) private var browserServices

    var body: some View {
        GeometryReader { geometry in
            // W184 F3：SwiftUI 的框一律照形態停著的樣子排（換形態的動畫是 GlobalDMFormStage 的圖層，不再逐格改這裡）。
            let look = GlobalDMPhoneLook(form: form, slide: nil, size: geometry.size)
            phone(look, width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .environment(\.globalDMForm, form)
                .environment(\.globalDMScreenRadius, look.radius)
                .environment(\.globalDMSideMargin, look.sideMargin)
                .environment(\.globalDMSurface, surface)
                .modifier(GlobalDMWebSheetOverlay(store: store))   // W183 R5b／R6b：［連線］卡蓋在整支手機上（內橫也只有一層）
                .modifier(GlobalDMBoxChrome(cornerRadius: look.radius))
                // W184 G1b：右上角、左下角 40×40（貼著框的角）拖＝整個框等比縮放，拖哪個角那個角跟著滑鼠、對角不動；四種形態都有。
                .overlay(alignment: .topTrailing) {
                    GlobalDMBoxGrip(kind: .resize(.topRight), surface: surface)
                        .frame(width: GlobalDMBoxGrip.cornerSize, height: GlobalDMBoxGrip.cornerSize)
                }
                .overlay(alignment: .bottomLeading) {
                    GlobalDMBoxGrip(kind: .resize(.bottomLeft), surface: surface)
                        .frame(width: GlobalDMBoxGrip.cornerSize, height: GlobalDMBoxGrip.cornerSize)
                }
                .opacity(look.opacity)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(surface == .floating ? "tatwo.dm.floatingBox" : "tatwo.dm.box")
    }

    /// 兩層：對話（頂列＋欄；外直、內橫、內直都是同一層、同一個 GlobalDMBox，換形態不重建）與倒放（房 E；沒有頂列）。
    /// 換內容（任何形態↔倒放）兩層先出後進；停著時只有其中一層。
    @ViewBuilder
    private func phone(_ look: GlobalDMPhoneLook, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if look.showsChat {
                VStack(spacing: 0) {
                    GlobalDMTopBar(store: store, form: form)
                    columns(look, width: width)
                        // W184 G3c（使用者：「文字頂部漸淡應頂天 不是空一節」）：欄畫在頂列底下一層；訊息列表往上延伸頂列的高度
                        // （GlobalDMMessageList 讀 globalDMListBleed），在頂列底下捲到框的上緣、漸淡在框的上緣。頂列本身不動、照舊可按。
                        .zIndex(-1)
                        .environment(\.globalDMListBleed, DMPhone.headerHeight)
                }
                // W184 G3b：對象是 ChatGPT 時，頂列放 ChatGPT 那一欄的控制（只在 ChatGPT 那一欄的寬度裡；W184 G3c：只剩右上的臨時聊天，
                // 模型與思考強度回到輸入框）；左緣指到從左邊滑出對話抽屜（W184 G3c：蓋在主畫面上、主畫面不動；GlobalDMChatGPTNavigation.swift）。
                .environment(\.globalDMChatGPTTopWidth, chatGPTColumnShown ? look.chatWidth(in: width) : nil)
                .modifier(GlobalDMChatGPTDrawerLayer(store: store, enabled: chatGPTColumnShown, directory: ChatGPTSpaceModel.shared))
                .opacity(look.chat)
                .allowsHitTesting(look.chat > 0.5)
            }
            if look.showsTent {
                GlobalDMTentContent(store: store)   // W184 AB → 房 E：倒放整塊都是它（沒有頂列）
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(look.tent)
                    .allowsHitTesting(look.tent > 0.5)
            }
        }
    }

    /// ChatGPT 那一欄在這支手機上（對象是 ChatGPT、單欄沒換成 Browser、ChatGPT 分頁開著）：抽屜、頂列的 ChatGPT 控制才有。
    private var chatGPTColumnShown: Bool {
        store.target == .chatGPT && !(store.isBrowsing && !form.isDuo) && store.chatGPTAvailable
    }

    /// 欄：對話欄貼左緣（寬＝框寬 ×（1 → 左欄比例））；內橫的右欄貼右緣、寬度用它最後的寬度、只露出對話欄右邊那一段
    /// （對話欄蓋著它的樣子）；分隔線跟著對話欄的右緣。左欄永遠是這一個 GlobalDMBox（位置不變：換形態不重建）。
    @ViewBuilder
    private func columns(_ look: GlobalDMPhoneLook, width: CGFloat) -> some View {
        let chatWidth = look.chatWidth(in: width)
        ZStack(alignment: .topLeading) {
            if look.duo > 0 {
                GlobalDMDuoBox(primary: store, secondary: secondary, model: model, surface: surface, services: browserServices)
                    .frame(width: look.rightWidth)
                    .frame(width: max(0, width - chatWidth), alignment: .trailing)
                    // W184 G3c：裁切往上多留頂列那一段（右欄的訊息列表一樣延伸到框的上緣）；左右照舊只露出對話欄右邊那一段。
                    .padding(.top, DMPhone.headerHeight)
                    .clipped()
                    .padding(.top, -DMPhone.headerHeight)
                    .padding(.leading, chatWidth)
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: DMPhone.hairline)
                    .padding(.top, DMPhone.dividerTop)
                    .padding(.bottom, DMPhone.dividerBottom)
                    .padding(.leading, chatWidth)
                    .opacity(look.divider)
                    .accessibilityHidden(true)
            }
            // W183 R12：任務（例：連線）的左頁蓋在私訊上（形態是兩頁時）；私訊這一欄不拆（草稿、捲動、焦點都在）。
            GlobalDMTaskCover(store: store) {
                GlobalDMBox(store: store, model: model, surface: surface, role: form.isDuo ? .duoLeading : .single)
            }
                .frame(width: chatWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(form.isDuo ? "tatwo.dm.duo" : "tatwo.dm.columns")
        // W184 G2d（使用者 09-30：「duo的browser左列欄修到頂天」）：欄畫在頂列底下一層（W184 G3c），私訊框 Browser 的側欄同樣往上伸到框頂
        // （頁面圓鈕照舊在最上面、可按）；網頁、頂列、卡片照舊從 Browser 區開始。
        .environment(\.dmBrowserTopExtension, DMPhone.headerHeight)
    }
}

/// 手機這一格的樣子（純計算，好測）：停著照形態；換形態中照 GlobalDMSlideFrame（W184 F3：圖層台照它算對話欄寬、右欄、分隔線）。
struct GlobalDMPhoneLook: Equatable {
    let form: GlobalDMForm
    let radius: CGFloat
    let duo: Double
    let chat: Double
    let tent: Double
    let divider: Double
    let opacity: Double
    let landWidth: CGFloat

    init(form: GlobalDMForm, slide: GlobalDMSlideFrame?, size: CGSize) {
        self.form = form
        radius = DMPhone.screenRadius   // W184 F3：固定 52（任何形態、大小、轉場中）
        duo = slide?.duo ?? (form.isDuo ? 1 : 0)
        chat = slide?.chat ?? (form == .tent ? 0 : 1)
        tent = slide?.tent ?? (form == .tent ? 1 : 0)
        divider = slide?.divider ?? (form.isDuo ? 1 : 0)
        opacity = slide?.opacity ?? 1
        landWidth = slide?.landWidth ?? size.width
    }

    /// 對話那一層在不在（要去的不是倒放，或還在淡出）；倒放那一層同理。
    var showsChat: Bool { form != .tent || chat > 0.001 }
    var showsTent: Bool { form == .tent || tent > 0.001 }

    /// 左右留白：單欄 16、內橫 20，途中連續變。
    var sideMargin: CGFloat { DMPhone.margin + (DMPhone.wideMargin - DMPhone.margin) * CGFloat(duo) }

    /// 內橫的左欄寬（照內橫的框寬）：(框寬 × 400/890) 四捨五入（跟改之前一樣）。
    var landLeft: CGFloat { (landWidth * DMPhone.duoLeadingFraction).rounded() }

    /// 對話欄寬＝框寬 − 右欄露出來的那一段（露出＝進度 ×（內橫框寬 − 左欄））：單欄＝整個框寬；停在內橫＝左欄寬。
    /// 對話欄的右緣（右欄露出多少）跟著進度單向移動，換形態途中轉向也連續。
    func chatWidth(in width: CGFloat) -> CGFloat {
        guard duo > 0 else { return width }
        return min(width, max(0, width - CGFloat(duo) * (landWidth - landLeft)))
    }

    /// 右欄寬：用內橫最後的寬度（停在內橫＝框寬 − 左欄 − 分隔線，跟改之前一樣）。
    var rightWidth: CGFloat {
        max(0, landWidth - landLeft - DMPhone.hairline)
    }
}

// MARK: - 頂列

/// 頂列（對照稿 A-Proto／Main／Open-*）：上 14、左右 16（內橫 20）、下 10；只有左上目前頁面的圓鈕（指到向右展開；右鍵／control＋點＝
/// 形態、直達鍵那一份選單）。W184 F：右上「⋯ 更多」「⌄ 收起」拿掉（收起靠 ⌥⌘ 與 Esc）。對話與 Browser 同一條、高度固定；內橫只有這一條（跨兩欄）。
struct GlobalDMTopBar: View {
    @ObservedObject var store: GlobalDMStore
    let form: GlobalDMForm
    /// W184 F2：換形態途中左右留白連續變（nil＝照形態）。
    @Environment(\.globalDMSideMargin) private var sideMargin
    @Environment(\.globalDMSurface) private var surface
    /// W184 G3b：ChatGPT 那一欄在這支手機上時它的寬（手機框照「對象是 ChatGPT、那一欄看得到」給；nil＝不是）。
    @Environment(\.globalDMChatGPTTopWidth) private var chatGPTWidth

    var body: some View {
        let margin = sideMargin ?? DMPhone.sideMargin(for: form)
        ZStack(alignment: .leading) {
            // W184 G3b：對象是 ChatGPT 時（照 ChatGPT iPhone App）放 ChatGPT 那一欄的控制；W184 G3c：只剩右上的臨時聊天（≡ 拿掉，
            // 抽屜只靠左緣；模型名回到輸入框）。頁面圓鈕畫在上面一層（指到向右展開時蓋在上面）。
            if let chatGPTWidth {
                GlobalDMChatGPTTopControls(store: store, session: store.chatGPT, width: max(0, chatGPTWidth - margin * 2))
            }
            HStack(alignment: .center, spacing: 0) {
                GlobalDMIconStrip(store: store, besideBrowser: form.isDuo)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, DMPhone.headerTop)
        .padding(.bottom, DMPhone.headerBottom)
        .padding(.horizontal, sideMargin ?? DMPhone.sideMargin(for: form))
        .frame(height: DMPhone.headerHeight)
        // W184 G1：頂列的空白處按住拖＝整個框移動（頁面圓鈕、右鍵選單那一格在上面，照舊）。W184 AB（使用者 09-30：「上方不要拖拽槓
        // 不好看」）：正中間那條小把手拿掉；看得出能抓＝滑到頂列空白處游標變張開的手。
        .background {
            GlobalDMBoxGrip(kind: .move, surface: surface)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.header")
    }
}

/// 頂列的位置（框的座標，左上原點；純計算，好測）。
enum GlobalDMTopBarLayout {
    /// 左上的圓鈕列（含 4 的裁切邊，所以比左右留白往外 4）：收起 52×52、展開照顆數。
    static func stripFrame(open: Bool, count: Int, form: GlobalDMForm) -> CGRect {
        CGRect(x: DMPhone.sideMargin(for: form) - DMPhone.Strip.inset, y: DMPhone.headerTop - DMPhone.Strip.inset,
               width: DMPhone.Strip.width(count: count, open: open), height: DMPhone.Strip.collapsed)
    }

    /// 展開後的順序：目前那顆在最左，其他照固定順序（TATWO、ChatGPT、Browser 去掉目前那顆）。
    static func order(_ items: [GlobalDMIconItem], current: String) -> [GlobalDMIconItem] {
        items.filter { $0.id == current } + items.filter { $0.id != current }
    }

    /// 圓鈕列展開、收回：260ms、cubic-bezier(0.2,0.8,0.2,1)。
    static var stripAnimation: Animation {
        let c = DMPhone.motionCurve
        return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: DMPhone.Strip.duration)
    }
}

/// 圓鈕列展開與否（純狀態，好測）：滑鼠指到展開、移開收回；點了別顆＝收回，滑鼠離開以前不再自己展開。
struct GlobalDMStripHover: Equatable {
    private(set) var isOpen = false
    private var held = false

    mutating func hovering(_ inside: Bool) {
        if inside {
            if !held { isOpen = true }
        } else {
            isOpen = false
            held = false
        }
    }

    mutating func picked() {
        isOpen = false
        held = true
    }
}

/// 目前那顆圓鈕外面包一層「目前對象」（沿用舊名字行的識別碼 tatwo.dm.target，唸得出目前對象）。
struct GlobalDMCurrentTargetMark: ViewModifier {
    let active: Bool
    let name: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel("目前對象：\(name)")
                .accessibilityIdentifier("tatwo.dm.target")
        } else {
            content
        }
    }
}

extension GlobalDMStore {
    /// W184 AB：目前頁面那顆圓鈕的 id：單欄 Browser 開著＝browser；內橫的 Browser 在右欄，目前頁面是左欄的對象。
    func currentPageID(besideBrowser: Bool) -> String {
        if isBrowsing && !besideBrowser { return "browser" }
        return target.storageValue
    }

    /// 頂列的圓鈕：TATWO、ChatGPT、Browser（固定順序）；目前對象不在裡面（直達鍵開的 session）時多放它那一顆。
    func pageItems(besideBrowser: Bool) -> [GlobalDMIconItem] {
        var items = iconItems()
        let current = currentPageID(besideBrowser: besideBrowser)
        if !items.contains(where: { $0.id == current }),
           let extra = iconItems(showingOthers: true).first(where: { $0.id == current }) {
            items.insert(extra, at: 0)
        }
        return items
    }
}

// MARK: - 拖、縮放的抓取區（W184 G1、G1b）

/// W184 G1（使用者 09-29：「私訊鈕上方欄新增抓取拖拽能力 又上r腳新增等比拖拽縮放」）＋W184 G1b（「左下也可以調尺寸好了」「拖拽範圍跟體驗有很多問題」：
/// 拖的時候卡、跟不上滑鼠／範圍太小／不知道哪裡能抓）：
/// - move＝頂列空白處（倒放沒有頂列：上緣那一條）：按下去交給系統原生的視窗拖曳（視窗伺服器帶著面板走：拖的途中 App 不排版、
///   不逐事件改面板大小），放開才算位置、存下來；游標張開的手、按下握拳（W184 AB：不畫把手，能抓的提示就是游標；面板不是主視窗時
///   也照樣換：滑鼠移動時看那一點是不是真的落在這塊空白上）。
/// - resize＝右上角、左下角：滑到角附近（約 14pt）出現跟框同心的短弧角標、游標變對角縮放；拖哪個角那個角跟著滑鼠、對角不動。
/// - 雙擊不做任何事。
struct GlobalDMBoxGrip: NSViewRepresentable {
    enum Kind: Equatable {
        case move
        case resize(GlobalDMResizeCorner)
    }
    enum Phase: Equatable {
        case began
        case changed(CGSize)
        case ended
    }

    /// 角的抓取區：40×40 貼著框的角（角標畫在裡面）；真的接點擊的是離框的圓角約 14pt 以內、在輸入框同心圓角外面的那一圈。
    static let cornerSize: CGFloat = 40
    static let cornerReach: CGFloat = 14
    /// 角標：跟框同心（半徑 52 − 6）的短弧，45° 兩邊各 18°、3pt 粗、圓頭。
    static let markInset: CGFloat = 6
    static let markHalfSpan: CGFloat = 18
    static let markWidth: CGFloat = 3

    let kind: Kind
    let surface: GlobalDMSurface

    func makeNSView(context: Context) -> GlobalDMBoxGripView {
        let view = GlobalDMBoxGripView()
        view.kind = kind
        view.surface = surface
        return view
    }

    func updateNSView(_ view: GlobalDMBoxGripView, context: Context) {
        view.kind = kind
        view.surface = surface
    }
}

/// W184 G1b：倒放沒有頂列：上緣那一條（頂列同高的 44）＝拖曳區（在影片上面、在倒放的控制列底下）。W184 AB：不畫把手（跟頂列一樣靠游標）。
struct GlobalDMTentGrabBand: View {
    @Environment(\.globalDMSurface) private var surface

    var body: some View {
        GlobalDMBoxGrip(kind: .move, surface: surface)
            .frame(maxWidth: .infinity)
            .frame(height: DMPhone.touch)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

final class GlobalDMBoxGripView: NSView {
    var kind: GlobalDMBoxGrip.Kind = .move {
        didSet {
            guard kind != oldValue else { return }
            applyFill()
            applyAccessibility()
            layoutMark()
        }
    }
    var surface: GlobalDMSurface = .floating
    /// 自測換：角的拖動通知誰（正式＝面板控制器）、滑鼠在螢幕上的位置（正式＝NSEvent.mouseLocation：框跟著動時照樣準）、
    /// 頂列按下去交給誰做原生的視窗拖曳（正式＝面板控制器的 beginWindowDrag）。
    static var handler: @MainActor (GlobalDMBoxGrip.Kind, GlobalDMSurface, GlobalDMBoxGrip.Phase) -> Void = { kind, surface, phase in
        GlobalDMPanelController.shared.handleGrip(kind, surface: surface, phase: phase)
    }
    static var location: @MainActor (NSEvent) -> NSPoint = { _ in NSEvent.mouseLocation }
    static var windowDrag: @MainActor (GlobalDMSurface, NSEvent) -> Void = { surface, event in
        GlobalDMPanelController.shared.beginWindowDrag(surface, event: event)
    }
    private var start: NSPoint?
    private var tracking: NSTrackingArea?
    /// 頂列：這塊空白上正顯示張開的手（離開、滑到上面的圓鈕時換回箭頭）。
    private(set) var showsHand = false
    /// 角標（只有角的抓取區有；滑到那一圈才出現）。
    let mark = CAShapeLayer()
    private(set) var isNearCorner = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        mark.fillColor = nil
        mark.lineWidth = GlobalDMBoxGrip.markWidth
        mark.lineCap = .round
        mark.opacity = 0
        layer?.addSublayer(mark)
        applyFill()
        applyAccessibility()
    }

    required init?(coder: NSCoder) { nil }

    /// 角那一格有一半在圓角外面（全透明的地方視窗伺服器會讓點擊穿過去）：給它看不見的底才接得到；頂列那一格底下就是框，不用。
    private func applyFill() {
        layer?.backgroundColor = kind == .move ? nil : NSColor.black.withAlphaComponent(0.01).cgColor
    }

    /// W184 F／G1（GPT-6 審查 #7）：抓取區是自動化找得到的元件：頂列拖動＝tatwo.dm.grip.move（AXHandle）、右上角縮放＝tatwo.dm.grip.resize、
    /// 左下角縮放＝tatwo.dm.grip.resize.bottomLeft（AXGrowArea）。
    private func applyAccessibility() {
        setAccessibilityElement(true)
        switch kind {
        case .move:
            setAccessibilityRole(.handle)
            setAccessibilityLabel("拖動私訊框")
        case .resize(let corner):
            setAccessibilityRole(.growArea)
            setAccessibilityLabel(corner == .topRight ? "等比縮放私訊框（左下角不動）" : "等比縮放私訊框（右上角不動）")
        }
        setAccessibilityIdentifier(Self.identifier(kind))
    }

    static func identifier(_ kind: GlobalDMBoxGrip.Kind) -> String {
        switch kind {
        case .move: "tatwo.dm.grip.move"
        case .resize(.topRight): "tatwo.dm.grip.resize"
        case .resize(.bottomLeft): "tatwo.dm.grip.resize.bottomLeft"
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    var corner: GlobalDMResizeCorner? {
        if case .resize(let corner) = kind { return corner }
        return nil
    }

    var cursor: NSCursor {
        guard let corner else { return start == nil ? .openHand : .closedHand }
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: corner == .topRight ? .topRight : .bottomLeft, directions: .all)
        }
        return .crosshair
    }

    /// 框圓角的圓心（這個 view 的座標，左下原點）：右上角的抓取區貼著框的右上角＝(寬 − 52, 高 − 52)；左下角＝(52, 52)。
    static func cornerCenter(_ corner: GlobalDMResizeCorner, size: CGSize) -> CGPoint {
        corner == .topRight ? CGPoint(x: size.width - DMPhone.screenRadius, y: size.height - DMPhone.screenRadius)
            : CGPoint(x: DMPhone.screenRadius, y: DMPhone.screenRadius)
    }

    /// 角的那一圈：離框圓角的圓心 ≥ 52 − 12（輸入框的同心圓角外面：不擋輸入框、＋鈕）且 ≤ 52 + 14（圓角外面約 14pt 以內）。
    static func inCornerBand(_ point: CGPoint, corner: GlobalDMResizeCorner, size: CGSize) -> Bool {
        let center = cornerCenter(corner, size: size)
        let distance = hypot(point.x - center.x, point.y - center.y)
        return distance >= DMPhone.screenRadius - DMPhone.edgeInset && distance <= DMPhone.screenRadius + GlobalDMBoxGrip.cornerReach
    }

    /// 角標的路徑：跟框同心的短弧（半徑 52 − 6，45° 那一點兩邊各 18°）。
    static func markPath(_ corner: GlobalDMResizeCorner, size: CGSize) -> CGPath {
        let center = cornerCenter(corner, size: size)
        let middle: CGFloat = corner == .topRight ? .pi / 4 : .pi * 5 / 4
        let half = GlobalDMBoxGrip.markHalfSpan * .pi / 180
        let path = CGMutablePath()
        path.addArc(center: center, radius: DMPhone.screenRadius - GlobalDMBoxGrip.markInset, startAngle: middle - half,
                    endAngle: middle + half, clockwise: false)
        return path
    }

    override func layout() {
        super.layout()
        layoutMark()
    }

    private func layoutMark() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.frame = bounds
        if let corner {
            mark.path = Self.markPath(corner, size: bounds.size)
            var color = NSColor.labelColor.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.withAlphaComponent(0.45).cgColor }
            mark.strokeColor = color
        } else {
            mark.path = nil
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutMark()
    }

    /// 角：只有那一圈接點擊（輸入框、＋鈕照常點得到）；頂列：整格。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard let corner else { return hit }
        return Self.inCornerBand(convert(point, from: superview), corner: corner, size: bounds.size) ? hit : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // 頂列也收進出與移動：面板不是主視窗（cursorUpdate 不一定送到）時照樣換成張開的手。
        let options: NSTrackingArea.Options = [.cursorUpdate, .activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// 滑到角的那一圈：角標出現、游標變對角縮放；離開：角標收起（拖著的時候不收）。
    func hover(_ point: CGPoint?) {
        guard let corner else { return }
        let near = point.map { Self.inCornerBand($0, corner: corner, size: bounds.size) } ?? false
        guard near != isNearCorner || start != nil else { return }
        isNearCorner = near || start != nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        mark.opacity = isNearCorner ? 1 : 0
        CATransaction.commit()
        if isNearCorner { cursor.set() } else { NSCursor.arrow.set() }
    }

    override func mouseEntered(with event: NSEvent) { pointer(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { pointer(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { pointer(at: nil) }

    /// 滑鼠在視窗的哪一點（nil＝離開）：角＝角標與對角縮放；頂列＝那一點真的落在這塊空白上（上面沒有圓鈕、選單那一格）才是張開的手。
    func pointer(at location: NSPoint?) {
        guard corner == nil else { return hover(location.map { convert($0, from: nil) }) }
        guard start == nil else { return }
        let blank = location.map(isBlank(at:)) ?? false
        if blank {
            NSCursor.openHand.set()
        } else if showsHand {
            NSCursor.arrow.set()
        }
        showsHand = blank
    }

    /// 視窗座標的這一點是不是落在這塊抓取區本身（不是蓋在上面的圓鈕、選單，也不是轉換中的圖層台）：跟視窗派滑鼠事件一樣從最外層往下找。
    func isBlank(at location: NSPoint) -> Bool {
        guard let root = window?.contentView?.superview ?? window?.contentView else { return false }
        return root.hitTest(location) === self
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let corner else {
            if isBlank(at: event.locationInWindow) {
                showsHand = true
                cursor.set()
            }
            return
        }
        if Self.inCornerBand(convert(event.locationInWindow, from: nil), corner: corner, size: bounds.size) { cursor.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }   // 雙擊頂列不做任何事（不觸發系統縮放）
        guard corner != nil else {
            // 頂列：系統原生的視窗拖曳（面板控制器做；放開才算位置、存下來）。
            NSCursor.closedHand.set()
            Self.windowDrag(surface, event)
            return
        }
        start = Self.location(event)
        hover(convert(event.locationInWindow, from: nil))
        cursor.set()
        Self.handler(kind, surface, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard corner != nil, let start else { return }
        let now = Self.location(event)
        Self.handler(kind, surface, .changed(CGSize(width: now.x - start.x, height: now.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        guard corner != nil, start != nil else { return }
        start = nil
        hover(convert(event.locationInWindow, from: nil))
        Self.handler(kind, surface, .ended)
    }
}

// MARK: - 左上頁面圓鈕的右鍵選單（W184 F：取代右上的 ⋯ 更多、⌄ 收起）

/// 目前那顆圓鈕的右鍵選單：右鍵、control＋點跳出原本「⋯ 更多」那一份（形態、直達鍵、⌥⌘ 與輔助使用權限、縮成桌面圓鈕／恢復主視窗）；
/// VoiceOver 的「顯示選單」也是同一份（從圓鈕下方跳出）。左鍵照常給圓鈕（切頁、指到展開）。
struct GlobalDMPageMenu: ViewModifier {
    let active: Bool
    let store: GlobalDMStore
    let anchor: GlobalDMPageMenuAnchor
    /// 這支手機是停靠框還是浮動框（「收起私訊框」收它）。
    var surface: GlobalDMSurface = .floating

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
                .overlay { GlobalDMPageMenuCatcher(store: store, anchor: anchor, surface: surface) }
                .accessibilityAction(.showMenu) { anchor.view?.showMenu(nil) }
        } else {
            content
        }
    }
}

/// 右鍵選單的定位點（VoiceOver「顯示選單」時從圓鈕下方跳出；同 AssistantModelMenuAnchor）。
final class GlobalDMPageMenuAnchor {
    weak var view: GlobalDMPageMenuCatcherView?
}

/// 只接右鍵與 control＋點（同 Browser 空間圓點的 BrowserRightClickCatcher）；左鍵、滑鼠移動照常穿過去給底下的圓鈕。
struct GlobalDMPageMenuCatcher: NSViewRepresentable {
    let store: GlobalDMStore
    let anchor: GlobalDMPageMenuAnchor
    var surface: GlobalDMSurface = .floating

    func makeNSView(context: Context) -> GlobalDMPageMenuCatcherView {
        let view = GlobalDMPageMenuCatcherView()
        view.store = store
        view.surface = surface
        anchor.view = view
        return view
    }

    func updateNSView(_ view: GlobalDMPageMenuCatcherView, context: Context) {
        view.store = store
        view.surface = surface
        anchor.view = view
    }
}

final class GlobalDMPageMenuCatcherView: NSView {
    weak var store: GlobalDMStore?
    /// 選單所在的是停靠框還是浮動框（「收起私訊框」收它）。
    var surface: GlobalDMSurface = .floating
    /// 自測換：現在處理的事件（正式＝NSApp.currentEvent）、選單怎麼組（正式＝照現況組的那一份）、怎麼跳出
    /// （正式＝系統右鍵選單；自測只記下來：選單一跳出就停在選單追蹤裡）。
    static var currentEvent: @MainActor () -> NSEvent? = { NSApp.currentEvent }
    static var makeMenu: @MainActor (GlobalDMStore, GlobalDMSurface) -> NSMenu = { GlobalDMMoreMenu.make(for: $0, surface: $1) }
    static var present: @MainActor (NSMenu, NSEvent?, NSView) -> Void = { menu, event, view in
        if let event { NSMenu.popUpContextMenu(menu, with: event, for: view) } else { GlobalDMMoreMenu.popUp(menu, below: view) }
    }

    /// 右鍵、control＋點才開選單（左鍵照常點圓鈕）。
    static func opensMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Self.opensMenu(Self.currentEvent()), bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    /// 面板不是 key 視窗時第一下也要開得到（同 GlobalDMHostingView）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
        showMenu(event)
    }

    /// 照現況組一份跳出來（event＝nil：VoiceOver 的「顯示選單」，從圓鈕下方跳出）。
    func showMenu(_ event: NSEvent?) {
        guard let store else { return }
        Self.present(Self.makeMenu(store, surface), event, self)
    }
}

/// 頁面圓鈕右鍵選單（原本的「⋯ 更多」）現在該有什麼（純資料，好測）。
struct GlobalDMMoreMenuState: Equatable {
    var form: GlobalDMForm
    var isCollapsed = false
    /// 換形態的鍵（預設 ⌥⌘Tab）註冊失敗（被別的 App 佔用）。
    var tabKeyFailed = false
    /// W184 F45：換形態的鍵（使用者在直達鍵頁設的；預設 Tab）：選單照它寫。
    var formKey: GlobalDMDirectKey = GlobalDMFormKeyBook.standard
    /// 設定裡「單按 ⌥⌘ 開關私訊框」開著。
    var chordEnabled = true
    /// 有輔助使用權限（⌥⌘ 在其他 App 也有效）。
    var systemWide = true
    var hasDirectKeys = true
    /// W184 G1：這個框拖過或縮放過（才出現「回到預設位置與大小」）。
    var movedOrScaled = false
}

@MainActor
enum GlobalDMMoreMenu {
    struct Actions {
        var setForm: @MainActor @Sendable (GlobalDMForm) -> Void
        var openDirectKeys: @MainActor @Sendable () -> Void
        var openAccessibility: @MainActor @Sendable () -> Void
        var collapse: @MainActor @Sendable () -> Void
        var restore: @MainActor @Sendable () -> Void
        /// W184 F2：收起這份選單所在的那個框（浮動框收浮動、停靠框收停靠；同以前的 ⌄）。
        var close: @MainActor @Sendable () -> Void
        /// W184 G1：這個框回到預設的位置與大小。
        var resetPlacement: @MainActor @Sendable () -> Void = {}
    }

    static func make(_ state: GlobalDMMoreMenuState, actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "更多")
        menu.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.more")   // W184 F：右上的 ⋯ 拿掉，識別碼改掛在這份選單上
        menu.delegate = GlobalHotkeyMonitor.shared
        menu.autoenablesItems = false
        let heading = NSMenuItem.sectionHeader(title: "形態（\(state.formKey.display) 依序換）")   // W184 F45：目前設的鍵
        heading.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.size")   // 沿用舊尺寸鈕的識別碼：形態就是以前的尺寸
        menu.addItem(heading)
        for form in GlobalDMForm.allCases {
            let setForm = actions.setForm
            let item = AssistantModelMenuItem(title: form.menuTitle) { setForm(form) }
            item.state = state.form == form ? .on : .off
            item.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.form." + form.rawValue)
            menu.addItem(item)
        }
        if state.tabKeyFailed {
            menu.addItem(info("\(state.formKey.display) 被別的 App 佔用了，用這裡換形態", identifier: "tatwo.dm.form.keyBusy"))
        }
        menu.addItem(.separator())
        if state.hasDirectKeys {
            let keys = AssistantModelMenuItem(title: "直達鍵…", run: actions.openDirectKeys)
            keys.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.more.keys")
            menu.addItem(keys)
            menu.addItem(.separator())
        }
        if !state.chordEnabled {
            menu.addItem(info("單按 ⌥⌘ 開關私訊框：已在設定關掉", identifier: "tatwo.dm.more.chord"))
        } else if state.systemWide {
            menu.addItem(info("⌥⌘ 開關私訊框：在任何 App 都有效", identifier: "tatwo.dm.more.chord"))
        } else {
            menu.addItem(info("要在其他 App 用 ⌥⌘，要開裝置控制和資料取用（舊稱輔助使用）權限", identifier: "tatwo.dm.more.chord"))
            let open = AssistantModelMenuItem(title: "打開裝置控制和資料取用（舊稱輔助使用）設定…", run: actions.openAccessibility)
            open.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.accessibility")
            menu.addItem(open)
        }
        menu.addItem(.separator())
        if state.movedOrScaled {
            let reset = AssistantModelMenuItem(title: "回到預設位置與大小", run: actions.resetPlacement)
            reset.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.more.resetPlacement")
            menu.addItem(reset)
        }
        if state.isCollapsed {
            let restore = AssistantModelMenuItem(title: "恢復主視窗　⌥⌘↑", run: actions.restore)
            restore.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.more.restore")
            menu.addItem(restore)
        } else {
            let collapse = AssistantModelMenuItem(title: "縮成桌面圓鈕　⌥⌘↓", run: actions.collapse)
            collapse.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.more.collapse")
            menu.addItem(collapse)
        }
        // W184 F2：最下面「收起私訊框」（沿用舊 ⌄／✕ 的識別碼）：單按 ⌥⌘ 關掉、單欄又在看 Browser（Esc 給網頁）時也一下就收。
        menu.addItem(.separator())
        let close = AssistantModelMenuItem(title: "收起私訊框", run: actions.close)
        close.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.close")
        menu.addItem(close)
        return menu
    }

    /// 照現況組一份（右鍵那一刻）：形態、縮起、熱鍵、⌥⌘ 設定與權限都讀當下的；surface＝選單所在的框（收起收它）。
    static func make(for store: GlobalDMStore, surface: GlobalDMSurface) -> NSMenu {
        let desk = GlobalDMDeskController.shared
        let monitor = GlobalHotkeyMonitor.shared
        monitor.refreshAccessibilityPermission()
        let state = GlobalDMMoreMenuState(form: desk.settings.form, isCollapsed: desk.isCollapsed,
                                          tabKeyFailed: desk.hotkeys.failed.contains(desk.hotkeys.formKey), formKey: desk.hotkeys.formKey,
                                          chordEnabled: GlobalDMDeskSettings.chordToggleEnabled(),
                                          systemWide: monitor.isSystemWide, hasDirectKeys: store.hasDirectKeys,
                                          movedOrScaled: surface == .floating && desk.isCollapsed ? !desk.settings.bubblePlacement.isStandard
                                              : !desk.settings.placement(surface).isStandard)
        let actions = Actions(
            setForm: { form in _ = GlobalDMDeskController.shared.setForm(form) },
            openDirectKeys: { [store] in
                store.isPickerOpen = false
                store.isBrowsing = false
                store.isEditingDirectKeys = true
            },
            openAccessibility: { GlobalHotkeyMonitor.shared.openAccessibilitySettings() },
            collapse: { GlobalDMDeskController.shared.collapse() },
            restore: { GlobalDMDeskController.shared.restore() },
            close: { [store] in close(store, surface: surface) },
            resetPlacement: { GlobalDMPanelController.shared.resetPlacement(surface) })
        return make(state, actions: actions)
    }

    /// 「收起私訊框」：收這份選單所在的那個框（浮動框收浮動、停靠框收停靠；同以前的 ⌄）。
    static func close(_ store: GlobalDMStore, surface: GlobalDMSurface) {
        if surface == .floating { store.isFloatingOpen = false } else { store.isOpen = false }
    }

    /// 從圓鈕下方跳出（VoiceOver 的「顯示選單」；頂列在框的最上面，選單往下開）。
    static func popUp(_ menu: NSMenu, below view: NSView) {
        let point = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private static func info(_ title: String, identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }
}
