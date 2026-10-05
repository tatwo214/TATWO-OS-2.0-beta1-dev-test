import AppKit
import SwiftUI

// W184 D（使用者 09-29：「私訊鈕的ui完全垃圾 應該要參照手機app的規格去設計」、Browser 操作列「做成滑鼠指到才出現」、
// 「duo的形式已經ok就照你的設計去做」；對照稿 https://claude.ai/artifact/RoVoQkiMN13LDhD9Hj2s2g 的 A-Proto、Outer-Browser-*、Outer-Tabs、
// Outer-Connect、Open-*）：私訊框 Browser 照手機 App——頁面佔滿、連線卡片浮在頁上、分頁總覽是兩欄卡片格、
// 授權頁或配對碼在畫面上時頁面頂端有「這一頁不給截圖」小標。
// W184 G2d（使用者 09-30 02:4x 實測 .031：「duo的browser左列欄修到頂天 上方這些功能跟我們設計的 browser space設計不同」
// 「應該是滑鼠指到展開玻璃」「還沒有分頁的搜尋狀態也要一樣」「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：
// 頂列、側欄、沒分頁時的搜尋框都直接用主視窗 Browser space 的元件（EmbeddedBrowserToolbar、BrowserSidebarControls、
// BrowserActionsButton、WorkspaceSidebarShell、BrowserFavoritesStrip、書籤列、BrowserTabRow、空間圓點、BrowserStartSearch），
// 這裡只放「尺寸跟著框」的數字；互動與外觀同主視窗（滑鼠指到才展開玻璃、側欄頂天、左緣不畫把手）。
// 顏色照 GlobalDMPalette 的規則：App 的玻璃 token 與系統語意色；不用藍色系統鈕。

/// 私訊框 Browser 的尺寸（對照稿量出來的數字＋W184 G2d 照主視窗 Browser space 的數字）。
enum DMBrowserPhone {
    // MARK: 頁面框（對照稿：外距 上 4、左右 12、下 12；圓角 28；0.5 分隔色邊）

    static let pageTop: CGFloat = 4
    /// 頁面框左右、下邊離 Browser 區 12（W184 G2d：左邊不再留把手帶，側欄是滑鼠指到左緣才展開的玻璃）。
    static var pageSide: CGFloat { DMPhone.edgeInset }
    static var pageBottom: CGFloat { DMPhone.edgeInset }
    static var pageRadius: CGFloat { DMPhone.cardRadius }
    /// 淡直把手（5×44、在 22 寬的帶子中間）：私訊框的 Browser 不畫了（使用者說過多餘）；房 C 的 ChatGPT 抽屜還在用（DMBrowserHandle）。
    static var handleStrip: CGFloat { DMPhone.Drawer.handle }
    static var handleLength: CGFloat { DMPhone.touch }
    static let handleThickness: CGFloat = 5
    static let handleOpacity: Double = 0.2

    // MARK: W184 G2d：Browser space 的側欄（滑鼠指到左緣展開的玻璃、頂天）

    /// 寬＝主視窗 Browser space 的側欄寬（WorkspaceSidebarMetrics.width 250）；框窄的時候跟著縮（至少 180，右邊至少留 120 的網頁）。
    static func sidebarWidth(for paneWidth: CGFloat) -> CGFloat {
        min(WorkspaceSidebarMetrics.width, max(180, paneWidth - 120))
    }
    static var sidebarMaxWidth: CGFloat { WorkspaceSidebarMetrics.width }
    /// 滑鼠到 Browser 區左緣 18 以內＝展開；展開之後側欄右緣再往右 30 以內都留著，往右回到網頁才收
    /// （同主視窗 ChatPage 的 chatProjectRailRevealWidth 18、chatProjectRailExitZoneWidth 30）。
    static let revealZone: CGFloat = 18
    static let exitZone: CGFloat = 30
    /// 離開之後等 0.40 秒才收（同主視窗 ChatPage 的 chatProjectRailCloseDelay；指標只是掠過網頁不會收）。
    static let sidebarCloseDelay: Double = 0.40
    /// 展開：從左 8 滑進來、淡入（同主視窗浮出側欄的轉場 .offset(x: -8)＋opacity，展開 0.24 秒、收起 0.22 秒 easeInOut）。
    static let slide: CGFloat = 8
    static let sidebarOpenDuration: Double = 0.24
    static let sidebarCloseDuration: Double = 0.22
    /// 連線卡片出現、收起的淡入淡出。
    static let fadeDuration: Double = 0.18
    /// 側欄停在連線卡片上面 8（卡片的按鈕不被蓋住）。
    static let sidebarGap: CGFloat = 8
    /// 卡片浮著時側欄至少留這麼高（小框時手動連線卡的步驟那一段縮短讓位）：三列 44＋上下 8。
    static var sidebarMinHeight: CGFloat { DMPhone.touch * 3 + 16 }
    /// 側欄矮過這個（小框＋最高的連線卡）＝緊湊擺法：玻璃內距從 18 縮成 8、最下面那一排（下載、空間圓點、＋）跟著列表一起捲、排在列表最後
    /// （主視窗那一套的內距 18＋固定的圓點列＋間距，剩下的捲動區放不下兩列）；同一個 BrowserWorkSpaceSidebarList、同一個順序。
    static let sidebarCompactHeight: CGFloat = 160
    static let sidebarCompactPadding: CGFloat = 8
    /// WorkspaceSidebarShell（LiquidGlassPanelCard）的內距。
    static let sidebarShellInset: CGFloat = 18
    /// W184 G2d（主導 09-30：「空間名稱擺的位置要跟主視窗一樣」）：主視窗的空間名稱在視窗頂列、紅綠燈右邊、跟紅綠燈同一條中心線
    /// （ChatPage.browserSidebar 的 TrafficLightAlignedTitle：名稱從 appControlLeadingX 開始＝紅綠燈最右邊再過 10＋8）。
    /// 私訊框的頂列是頁面圓鈕那一排：名稱放在圓鈕右邊（圓鈕右緣再過同樣的 10＋8）、跟圓鈕同一條中心線（主視窗那邊的光學修正 1）。
    /// 內橫右欄的左上沒有圓鈕（圓鈕在左欄上面）：名稱對齊側欄的列。
    static let sidebarTitleLift: CGFloat = 1
    static var sidebarTitleCenter: CGFloat { DMPhone.headerTop + DMPhone.touch / 2 - sidebarTitleLift }
    static func sidebarTitleLeading(form: GlobalDMForm) -> CGFloat? {
        form.isDuo ? nil : DMPhone.sideMargin(for: form) + DMPhone.touch + WindowChromeMetrics.headerHorizontalInset + WindowChromeMetrics.controlSpacing
    }
    /// 頂列（48）浮出來會蓋在側欄上面那一段：列表從頂列下緣再往下 2 開始（固定在捲動區外面，捲動之後列也不會跑到頂列底下；
    /// GPT-6 審查 G2d #3）。從側欄頂端（框頂）量：框頂列＋頂列＋2。
    static let sidebarToolbarClearance: CGFloat = 2
    static func sidebarListTop(topExtension: CGFloat) -> CGFloat { topExtension + toolbarHeight + sidebarToolbarClearance }

    // MARK: W184 G2d：Browser space 的頂列（滑鼠指到上緣展開的玻璃）

    /// 高＝主視窗 Browser space 的頂列（BrowserOmniboxMetrics.toolbarHeight 48）。
    static var toolbarHeight: CGFloat { BrowserOmniboxMetrics.toolbarHeight }
    /// 滑鼠到 Browser 區頂端 20 以內＝展開；展開之後離頂 48＋10 以內都留著（同主視窗 BrowserChromeReveal 的 triggerBand＝16＋4、
    /// chromeHeight＋10；自測核對兩邊一樣）。
    static let toolbarTrigger: CGFloat = 20
    static let toolbarStay: CGFloat = 10
    /// 浮出、收起：0.12 秒淡入淡出（同主視窗 BrowserChromeReveal）。
    static let toolbarFade: Double = 0.12
    /// 頂列不到 420 寬＝右邊的翻譯、擴充、註解收進 ⋯（主視窗獨立 Browser 的頂列不收；聊天旁那一條的收合要另開子視窗，
    /// 私訊框照施工單「它沒有的話，把右邊的圖示收進 ⋯」）。420＝側欄鈕＋上一頁／下一頁／重新載入＋⋯＋三顆工具（320）＋網址至少 100。
    static let toolbarToolsMinWidth: CGFloat = 420

    /// 分頁總覽底部「完成」那一條（不動）：左右下 12、高 56、圓角 28（膠囊）、玻璃。
    static var barInset: CGFloat { DMPhone.edgeInset }
    static let barHeight: CGFloat = 56
    static var barRadius: CGFloat { barHeight / 2 }
    static let barPadding: CGFloat = 6
    /// 網址 pill（授權頁的鎖頭／警告那一顆，DMBrowserAddressPill）：44 高、圓角 22。
    static var pillHeight: CGFloat { DMPhone.touch }
    static var pillRadius: CGFloat { pillHeight / 2 }
    static let pillPadding: CGFloat = 12

    // MARK: 浮卡（配對碼、輪到你勾選、進行中）

    /// 左右 12、離底 30、內距 16、圓角 28、材質底＋陰影。側欄展開時停在卡片上面 8（側欄的下緣跟著卡片頂端），
    /// 卡片不動、不變窄（配對碼一行放得下），它的按鈕（右上的取消／完成、「輪到你」的取消｜繼續）永遠不會被側欄蓋住。
    static var cardInset: CGFloat { DMPhone.edgeInset }
    static let cardBottom: CGFloat = 30
    static var cardPadding: CGFloat { DMPhone.margin }
    static var cardRadius: CGFloat { DMPhone.cardRadius }
    static let cardSpacing: CGFloat = 12
    /// 卡片內容太長（手動步驟）時最多多高、其餘捲動。
    static let cardMaxBody: CGFloat = 260
    /// 手動連線卡除了步驟那一段以外的高度（內距 16×2、頂列 32 的 chip、間距 8）；步驟那一段最少 66（約三行）。
    static var cardChrome: CGFloat { cardPadding * 2 + DMPhone.chipHeight + 8 }
    static let cardMinBody: CGFloat = 66

    /// 手動步驟那一段最多多高：放得下＝260；框小的時候縮到側欄還留 sidebarMinHeight（卡片離底 30、側欄離卡片 8），最少 66。
    /// paneHeight＝Browser 區的高度（還沒量到＝0：照 260）。
    static func cardBodyLimit(paneHeight: CGFloat) -> CGFloat {
        guard paneHeight > 0 else { return cardMaxBody }
        let room = paneHeight - cardBottom - cardChrome - sidebarGap - sidebarMinHeight
        return max(cardMinBody, min(cardMaxBody, room))
    }

    /// 配對碼：34 等寬、字距 0.16em、置中（對照稿指定的顯示字級，碼不是內文；其他字一律 17／15／13／11）。
    static let codeSize: CGFloat = 34
    static var codeTracking: CGFloat { codeSize * 0.16 }

    // MARK: 「這一頁不給截圖」小標

    /// 頁面框頂端置中（離頂 10）、26 高、圓角 13、深色 0.78 底、白 11 半粗、眼睛斜線圖示。
    static let badgeTop: CGFloat = 10
    static let badgeHeight: CGFloat = 26
    static var badgeRadius: CGFloat { badgeHeight / 2 }
    static let badgeOpacity: Double = 0.78
    static let badgePadding: CGFloat = 10
    static let badgeSpacing: CGFloat = 5
    /// W184 G2 第三輪：Browser 上那一句話停多久自己收起（8 秒）。
    static let noticeNanoseconds: UInt64 = 8_000_000_000

    // MARK: 分頁總覽（兩欄卡片格）

    /// 內距 上 6、左右 16、下 12，間距 12；卡片圓角 24、選中 2 強調色框、其他 0.5；上半 150 高的縮圖區（中性色塊）、右上 28 的關掉鈕。
    static let listTop: CGFloat = 6
    static var listSide: CGFloat { DMPhone.margin }
    static let listBottom: CGFloat = 12
    static let listSpacing: CGFloat = 12
    static let gridSpacing: CGFloat = 12
    static let tabCardRadius: CGFloat = 24
    static let tabCardRing: CGFloat = 2
    static let thumbnailHeight: CGFloat = 150
    static let closeSize: CGFloat = 28
    static let closeInset: CGFloat = 8
    static let closeOpacity: Double = 0.55
    static let tabTextTop: CGFloat = 10
    static let tabTextSide: CGFloat = 12
    static let tabTextBottom: CGFloat = 12
    /// 縮圖區：不拍敏感頁的縮圖（授權頁、配對頁一律不截），一律中性色塊。
    static let thumbnailOpacity: Double = 0.05
    /// W184 G2c：分頁總覽最後一格「＋ 新分頁」至少跟一張卡片一樣高（縮圖 150＋字的那一段）。
    static let newTabCardExtra: CGFloat = 64

    // MARK: 按鈕

    /// 44 高的膠囊鈕（取消、連線、繼續、完成）左右內距。
    static let capsulePadding: CGFloat = 18

    /// 這一區（卡片、總覽、小標）用到的全部字級（自測核對都在 17／15／13／11 裡；配對碼 34 另外列）。
    /// 頂列、側欄、置中搜尋是主視窗 Browser space 的元件，字級照它自己的（BrowserSidebarMetrics／BrowserOmniboxMetrics）。
    static var textSizes: [CGFloat] {
        [DMPhone.TextSize.body, DMPhone.TextSize.secondary, DMPhone.TextSize.footnote, DMPhone.TextSize.caption]
    }
}

/// W184 G2c：私訊框 Browser 的新分頁快捷鍵 ⌘⌥T——認實體 T 鍵（kVK_ANSI_T＝17，跟輸入法無關，同直達鍵）、只有 ⌘⌥（不帶 ⇧⌃）。
enum DMBrowserNewTabKey {
    static let keyCode: UInt16 = 17
    static let display = "⌘⌥T"

    static func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == keyCode
            && event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option]
    }
}

/// 開著的輸入：address＝頂列的網址欄在打字（頂列不收，指標移開也一樣）；search＝沒分頁、空白分頁時置中的搜尋框在打字。
/// Esc＝只收這個輸入。
enum DMBrowserPanel: String, Sendable {
    case address
    case search
}

/// W184 G2d：自測畫面證據用：側欄、頂列固定展開（平常照滑鼠在不在左緣、上緣）。
struct DMBrowserChromeShown: OptionSet, Sendable {
    let rawValue: Int
    static let sidebar = DMBrowserChromeShown(rawValue: 1)
    static let toolbar = DMBrowserChromeShown(rawValue: 2)
    static let all: DMBrowserChromeShown = [.sidebar, .toolbar]
}

// MARK: - 環境值

private struct DMBrowserChromeShownKey: EnvironmentKey {
    static let defaultValue: DMBrowserChromeShown = []
}

/// W184 G2：自測量每一格、卡片的按鈕實際畫在哪（正式＝false，不掛量尺）。
private struct DMFrameProbesKey: EnvironmentKey {
    static let defaultValue = false
}

/// W184 G2 修正：自測換連線卡片的按鈕做什麼（量「按下去真的觸發」；正式＝nil，照流程）。
private struct DMConnectCardActionsKey: EnvironmentKey {
    static var defaultValue: HandsConnectCardActions? { nil }
}

/// W184 G2c 第二輪：手動連線卡步驟那一段最多多高（Browser 畫面照框的大小算好給；sheet 裡、沒給＝260）。
private struct DMCardBodyLimitKey: EnvironmentKey {
    static let defaultValue: CGFloat = DMBrowserPhone.cardMaxBody
}

/// W184 G2d（使用者 09-30：「duo的browser左列欄修到頂天」）：Browser 區上面還有多高是私訊框的頂列（側欄往上伸到框頂；沒給＝0）。
private struct DMBrowserTopExtensionKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 自測畫面證據用：側欄、頂列固定展開（平常照滑鼠在不在左緣、上緣）。
    var dmBrowserChromeShown: DMBrowserChromeShown {
        get { self[DMBrowserChromeShownKey.self] }
        set { self[DMBrowserChromeShownKey.self] = newValue }
    }

    /// 自測用：每一格、卡片的「取消」「繼續」後面墊一把量尺（DMFrameProbeView），自測照它讀那一格實際畫在視窗的哪裡。
    var dmFrameProbes: Bool {
        get { self[DMFrameProbesKey.self] }
        set { self[DMFrameProbesKey.self] = newValue }
    }

    /// 自測用：連線卡片的按鈕換成自測自己的（正式＝nil）。
    var dmConnectCardActions: HandsConnectCardActions? {
        get { self[DMConnectCardActionsKey.self] }
        set { self[DMConnectCardActionsKey.self] = newValue }
    }

    /// W184 G2c 第二輪：手動連線卡步驟那一段最多多高。
    var dmCardBodyLimit: CGFloat {
        get { self[DMCardBodyLimitKey.self] }
        set { self[DMCardBodyLimitKey.self] = newValue }
    }

    /// W184 G2d：Browser 區上面私訊框頂列的高度——側欄從框頂開始（頂列畫在它上面一層，頁面圓鈕照舊按得到）；網頁、頂列、卡片不動。
    var dmBrowserTopExtension: CGFloat {
        get { self[DMBrowserTopExtensionKey.self] }
        set { self[DMBrowserTopExtensionKey.self] = newValue }
    }
}

/// W184 G2d：側欄（左緣）與頂列（上緣）展開與否——同主視窗 Browser space：用滑鼠位置判斷（CEF 的原生網頁會吃掉 hover，
/// 不能靠 SwiftUI 的 onHover；同主視窗的 BrowserChromeReveal）。側欄固定著（頂列最左那顆）＝不用滑鼠叫；
/// 頂列一律橫跨整個 Browser 區（畫在側欄上面：側欄固定著也不會把頂列擠窄）。
@MainActor
final class DMBrowserBarReveal: ObservableObject {
    /// 側欄（沒固定時）展開了嗎。
    @Published private(set) var isRevealed = false
    /// 頂列展開了嗎。
    @Published private(set) var toolbarRevealed = false
    /// 側欄現在多寬（畫面照框寬算好給）、固定著沒。
    var sidebarWidth: CGFloat = DMBrowserPhone.sidebarMaxWidth
    /// 側欄往上伸出 Browser 區多少（私訊框頂列那一段）：展開之後指標在這一段的側欄上也算在側欄上（叫出來照舊只看 Browser 區的左緣）。
    var sidebarAbove: CGFloat = 0
    var sidebarPinned = false { didSet { if sidebarPinned != oldValue { reevaluate() } } }
    /// W184 G2d：側欄上開著東西（下載清單）＝側欄留著（同主視窗 store.sidebarInteractionActive）；關掉的當下照最後的滑鼠位置重算。
    private(set) var holdsSidebar = false
    /// 指標離開之後等多久才收側欄（同主視窗 0.40 秒；自測可以設 0 直接量）。
    var closeDelay: Double = DMBrowserPhone.sidebarCloseDelay
    #if DEBUG
    /// 自測（w184browser）：只照自測給的合成位置算，不聽真的滑鼠——同一台 mini 上別的房的自測會動真的游標，插進來重算就把頂列、
    /// 側欄收掉（整合分支 R12 的「typing=false」）。正式＝false。
    static var ignoresRealMouse = false
    #endif
    private var closeTask: Task<Void, Never>?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// 這一點要不要讓側欄展開（純計算，好測）：bounds＝整個 Browser 區（y 從上往下），point 同一個座標系。
    /// 收著＝只有滑鼠在左緣 18 以內才展開——網頁左邊的內容叫不出側欄；展開之後＝側欄右緣再往右 30 以內都留著（上到下都算）。
    /// above：側欄往上伸出 Browser 區的那一段（私訊框頂列底下）；展開之後那一段也算。
    nonisolated static func sidebarZone(_ point: CGPoint, bounds: CGRect, revealed: Bool, width: CGFloat, above: CGFloat = 0) -> Bool {
        let area = revealed && above > 0
            ? CGRect(x: bounds.minX, y: bounds.minY - above, width: bounds.width, height: bounds.height + above) : bounds
        guard area.contains(point) else { return false }
        let fromLeading = point.x - bounds.minX
        if fromLeading >= 0 && fromLeading <= DMBrowserPhone.revealZone { return true }
        guard revealed else { return false }
        return fromLeading <= width + DMBrowserPhone.exitZone
    }

    /// 這一點要不要讓頂列展開（純計算）：收著＝滑鼠到 Browser 區頂端 20 以內；展開之後離頂 48＋10 以內都留著（左右整個 Browser 區）。
    nonisolated static func toolbarZone(_ point: CGPoint, bounds: CGRect, revealed: Bool) -> Bool {
        guard bounds.contains(point) else { return false }
        let fromTop = point.y - bounds.minY
        if revealed { return fromTop <= DMBrowserPhone.toolbarHeight + DMBrowserPhone.toolbarStay }
        return fromTop <= DMBrowserPhone.toolbarTrigger
    }

    /// 掛上（Browser 區進了視窗）：本 App 的滑鼠移動（不論在哪個視窗）、別的 App 在前景時的滑鼠移動都拿來重算。
    /// listening＝false 只給自測：只照自測給的合成位置算（不聽真的滑鼠；同一台機器上別的測試可能正在動滑鼠）。
    func start(_ view: NSView, listening: Bool = true) {
        anchor = view
        #if DEBUG
        if Self.ignoresRealMouse { return }
        #endif
        guard listening else { return }
        view.window?.acceptsMouseMovedEvents = true
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                self?.evaluate(event)
                return event
            }
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                Task { @MainActor in self?.evaluate(nil) }
            }
        }
        evaluate(nil)
    }

    /// 拿下來（Browser 區離開畫面）：不再聽滑鼠、馬上收起來（不等收起的延遲）。
    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        anchor = nil
        set(sidebar: false, toolbar: false, immediately: true)
    }

    /// 頂列的網址欄、置中的搜尋框在打字＝頂列照樣展開（指標移開也不收；同主視窗 BrowserChromeReveal.holdOpen）；打完的當下照最後一次的
    /// 滑鼠位置重算。
    private(set) var holds = false
    /// 最後一次算的滑鼠位置（視窗座標）。
    private var lastPoint: NSPoint?

    func hold(_ on: Bool) {
        guard on != holds else { return }
        holds = on
        reevaluate()
    }

    func holdSidebar(_ on: Bool) {
        guard on != holdsSidebar else { return }
        holdsSidebar = on
        reevaluate()
    }

    #if DEBUG
    /// 自測：現在有沒有在聽真的滑鼠（本 App 的滑鼠移動、別的 App 在前景時的滑鼠移動）。
    var isListening: Bool { localMonitor != nil || globalMonitor != nil }
    #endif

    private func reevaluate() {
        if let lastPoint { evaluate(windowPoint: lastPoint) } else { evaluate(nil) }
    }

    /// 重算一次：事件帶的視窗座標（同一個視窗才用），不然問系統現在滑鼠在哪。
    func evaluate(_ event: NSEvent?) {
        #if DEBUG
        if Self.ignoresRealMouse { return }
        #endif
        guard let anchor, let window = anchor.window else { return set(sidebar: false, toolbar: holds) }
        // W184 G2d（GPT-6 審查 G2d #6：收框）：框收起來（視窗不在畫面上）＝側欄、頂列馬上收（不等延遲），收著的時候滑鼠經過同一個位置也不叫出來；
        // 框再打開之後照下一次的滑鼠位置算。
        guard window.isVisible else { return set(sidebar: false, toolbar: holds, immediately: true) }
        let location = event.flatMap { $0.window === window ? $0.locationInWindow : nil } ?? window.mouseLocationOutsideOfEventStream
        apply(windowPoint: location, anchor: anchor)
    }

    /// 自測：照這個視窗座標算一次（合成的滑鼠位置，不動真的游標）。
    func evaluate(windowPoint: NSPoint) {
        guard let anchor else { return set(sidebar: false, toolbar: holds) }
        apply(windowPoint: windowPoint, anchor: anchor)
    }

    private func apply(windowPoint: NSPoint, anchor: NSView) {
        lastPoint = windowPoint
        let point = anchor.convert(windowPoint, from: nil)
        // 側欄固定著＝它自己一直在（畫面照 DMBrowser.sidebarPinned 畫），滑鼠不管它；拿掉固定之後照滑鼠位置重算。
        let sidebar = !sidebarPinned && (holdsSidebar || Self.sidebarZone(point, bounds: anchor.bounds, revealed: isRevealed, width: sidebarWidth,
                                                                         above: sidebarAbove))
        let toolbar = holds || Self.toolbarZone(point, bounds: anchor.bounds, revealed: toolbarRevealed)
        set(sidebar: sidebar, toolbar: toolbar, immediately: sidebarPinned)
    }

    /// 頂列馬上跟著；側欄展開馬上、收起等 closeDelay（期間指標回到側欄那一帶＝不收）。
    private func set(sidebar: Bool, toolbar: Bool, immediately: Bool = false) {
        if toolbar != toolbarRevealed { toolbarRevealed = toolbar }
        if sidebar {
            closeTask?.cancel()
            closeTask = nil
            if !isRevealed { isRevealed = true }
            return
        }
        guard isRevealed else {
            closeTask?.cancel()
            closeTask = nil
            return
        }
        if immediately || closeDelay <= 0 {
            closeTask?.cancel()
            closeTask = nil
            isRevealed = false
            return
        }
        guard closeTask == nil else { return }
        let delay = UInt64(closeDelay * 1_000_000_000)
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.closeTask = nil
            self.isRevealed = false
        }
    }
}

/// W184 G2 第三輪：Browser 上的一句話（網頁開的新視窗沒開成）：頂上置中、在「這一頁不給截圖」下面；點一下收起（畫面過一會兒也會收）。
/// 浮在網頁上：這一塊的點擊給它（BrowserChromeHitLayer），不給網頁。
struct DMBrowserNoticeBadge: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            Text(text)
                .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color.white)
                .padding(.horizontal, DMBrowserPhone.badgePadding)
                .padding(.vertical, DMBrowserPhone.badgeSpacing)
                .background(RoundedRectangle(cornerRadius: DMBrowserPhone.badgeRadius, style: .continuous)
                    .fill(Color.black.opacity(DMBrowserPhone.badgeOpacity)))
                .contentShape(RoundedRectangle(cornerRadius: DMBrowserPhone.badgeRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(BrowserChromeHitLayer())
        .padding(.horizontal, DMBrowserPhone.cardInset)
        .help("收起")
        .accessibilityLabel(text)
        .accessibilityIdentifier("tatwo.dm.browser.notice")
    }
}

/// W184 G2：自測的量尺——墊在側欄、頂列某一格、卡片某一顆按鈕後面（不接點擊、不給無障礙），自測讀它在視窗裡的位置。
/// key：側欄＝"side.<那一格>"；頂列＝"bar.<那一顆>"；卡片＝"card.dismiss"（右上取消／完成）、"card.continue"（輪到你的繼續）。
final class DMFrameProbeView: NSView {
    var key = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct DMFrameProbe: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> DMFrameProbeView {
        let view = DMFrameProbeView(frame: .zero)
        view.key = key
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: DMFrameProbeView, context: Context) {
        view.key = key
    }
}

// MARK: - W184 G2 修正：Esc 認得 Browser 自己的操作面板

/// W184 G2 修正（GPT-6 4；查證 #5、#8；G2c／G2d）：頂列的網址欄、置中的搜尋框在打字時，Esc 只收那個輸入——
/// 單欄、內橫一樣；不收整個私訊框、也不給網頁。私訊框的 Esc 路由（GlobalDMPanelController.routeEscape）先問這裡。
/// 每個 Browser 畫面在它所在的視窗墊一個錨（DMBrowserPanelEscapeAnchor，一直在）：有面板開著才登記、面板收起來的當下就拿掉
/// （不等收起的動畫；收掉之後馬上再按 Esc 照原本的路走）。
@MainActor
enum DMBrowserPanelEscape {
    private final class Entry {
        weak var anchor: NSView?
        let panel: DMBrowserPanel
        let close: @MainActor () -> Void
        init(anchor: NSView, panel: DMBrowserPanel, close: @escaping @MainActor () -> Void) {
            self.anchor = anchor
            self.panel = panel
            self.close = close
        }
    }

    private static var entries: [Entry] = []

    static func register(_ anchor: NSView, panel: DMBrowserPanel, close: @escaping @MainActor () -> Void) {
        entries.removeAll { $0.anchor == nil || $0.anchor === anchor }
        entries.append(Entry(anchor: anchor, panel: panel, close: close))
    }

    static func unregister(_ anchor: NSView) {
        entries.removeAll { $0.anchor == nil || $0.anchor === anchor }
    }

    /// 這個視窗裡開著的輸入（最後開的那一個；沒有＝nil）。
    static func openPanel(in window: NSWindow) -> DMBrowserPanel? {
        entries.last { $0.anchor?.window === window }?.panel
    }

    /// Esc：這個視窗裡有開著的輸入＝收掉最後開的那一個，回 true（事件用掉）；沒有＝false（照原本的路走）。
    /// 收了就先拿掉這一筆（畫面下一次更新也會拿掉）：下一個 Esc 不會再被同一個面板吃掉。
    static func closePanel(in window: NSWindow) -> Bool {
        entries.removeAll { $0.anchor == nil }
        guard let entry = entries.last(where: { $0.anchor?.window === window }) else { return false }
        entries.removeAll { $0 === entry }
        entry.close()
        return true
    }
}

/// 墊在 Browser 區後面的錨（不接點擊、一直在）：在視窗裡而且有面板開著＝登記；面板收起來（panel＝nil）、離開視窗、拆掉＝拿掉。
struct DMBrowserPanelEscapeAnchor: NSViewRepresentable {
    let panel: DMBrowserPanel?
    let close: @MainActor () -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView(frame: .zero)
        view.panel = panel
        view.close = close
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.panel = panel
        view.close = close
        view.registerIfNeeded()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        DMBrowserPanelEscape.unregister(view)
    }

    final class AnchorView: NSView {
        var panel: DMBrowserPanel?
        var close: @MainActor () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerIfNeeded()
        }

        func registerIfNeeded() {
            if let panel, window != nil {
                DMBrowserPanelEscape.register(self, panel: panel, close: { [weak self] in self?.close() })
            } else {
                DMBrowserPanelEscape.unregister(self)
            }
        }
    }
}

/// 墊在 Browser 區後面、量它的位置與大小（不接點擊）；自己也有一塊追蹤區（滑鼠進出、移動；App 不在前景也收得到）。
final class DMBrowserBarAnchorView: NSView {
    weak var reveal: DMBrowserBarReveal?
    private var tracking: NSTrackingArea?

    /// y 從上往下（頂列的感應區照離 Browser 區頂端多遠算）。
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { reveal?.evaluate(event) }
    override func mouseExited(with event: NSEvent) { reveal?.evaluate(event) }
    override func mouseMoved(with event: NSEvent) { reveal?.evaluate(event) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibility {
            NotificationCenter.default.removeObserver(visibility)
            self.visibility = nil
        }
        guard let window else { return }
        // W184 G2d（GPT-6 審查 G2d #6：收框）：框收起來、又打開（視窗離開畫面、回到畫面）＝馬上照現在的樣子重算——收起來＝側欄、頂列收掉，
        // 打開＝照現在的游標位置（不等下一次滑鼠移動）。
        visibility = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reveal?.evaluate(nil) }
        }
        // 不在 SwiftUI 更新畫面的當下改狀態：下一輪再掛上、算一次。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.reveal?.start(self)
        }
    }

    private var visibility: NSObjectProtocol?
}

struct DMBrowserBarRevealHost: NSViewRepresentable {
    let reveal: DMBrowserBarReveal

    func makeNSView(context: Context) -> DMBrowserBarAnchorView {
        let view = DMBrowserBarAnchorView(frame: .zero)
        view.reveal = reveal
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: DMBrowserBarAnchorView, context: Context) {
        view.reveal = reveal
    }

    static func dismantleNSView(_ view: DMBrowserBarAnchorView, coordinator: ()) {
        let reveal = view.reveal
        view.reveal = nil
        DispatchQueue.main.async { reveal?.stop() }
    }
}

// MARK: - 小元件

/// 頁面左邊那一條（W184 G2c：左列的把手帶，DMPhone.Drawer.handle）：22 寬、上下置中 5×44 的淡直把手（左列滑出時空著）。
struct DMBrowserHandle: View {
    let visible: Bool

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(DMBrowserPhone.handleOpacity))
            .frame(width: DMBrowserPhone.handleThickness, height: DMBrowserPhone.handleLength)
            .opacity(visible ? 1 : 0)
            .frame(maxHeight: .infinity)
            .frame(width: DMBrowserPhone.handleStrip)
            .accessibilityHidden(true)
    }
}

/// 「這一頁不給截圖」小標：只在授權頁（還開著的敏感頁）正在畫面上、視窗不給擷取時出現；不接點擊（點到的是網頁）。
struct DMBrowserShieldBadge: View {
    static let text = "授權頁・這一頁不給截圖"

    var body: some View {
        HStack(spacing: DMBrowserPhone.badgeSpacing) {
            Image(systemName: "eye.slash")
                .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
            Text(Self.text)
                .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, DMBrowserPhone.badgePadding)
        .frame(height: DMBrowserPhone.badgeHeight)
        .background(Capsule().fill(Color.black.opacity(DMBrowserPhone.badgeOpacity)))
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.text)
        .accessibilityIdentifier("tatwo.dm.browser.shield")
    }
}

/// 44 高的膠囊鈕：主要動作＝強調色底白字（連線、繼續、完成）；其他＝玻璃膠囊（取消）。不用藍色系統鈕。
struct DMPhoneCapsuleButton: View {
    let title: String
    var prominent = false
    var grow = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: DMPhone.TextSize.body, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                .lineLimit(1)
                .padding(.horizontal, DMBrowserPhone.capsulePadding)
                .frame(maxWidth: grow ? .infinity : nil)
                .frame(height: DMPhone.touch)
                .background {
                    if prominent {
                        Capsule().fill(LiquidGlassTokens.brandAccent)
                    } else {
                        GlobalDMGlassCapsule()
                    }
                }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !grow, vertical: true)
        .accessibilityLabel(title)
    }
}

// MARK: - 秘密文字（配對碼）

/// W184 D（GPT-6 審查 #1、#2）：配對碼畫在自己的 NSView 上，不靠邏輯狀態保護——
/// - 它在哪個視窗，那個視窗就不給擷取（WindowCaptureShield，以視窗計數）：碼還畫著的每一幀都擋；離開視窗之後照 linger 再擋一小段
///   （退場動畫的尾巴、合成器的最後一幀）。分頁總覽、取消、框收起來、停靠框↔浮動框換手、倒放都一樣。
/// - 私訊框換形態時在動畫的第一個畫面之前同步藏起來（suppress，由 DMBrowser 跟著桌面控制器的 isFormTransitioning 叫）；
///   轉換期間畫面怎麼重算都不顯示，轉換結束（原生網頁恢復）才又顯示。
/// - 無障礙只唸「配對碼」，不唸出碼；不接點擊。
struct DMSecretCode: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> DMSecretCodeView {
        let view = DMSecretCodeView(frame: .zero)
        view.text = text
        return view
    }

    func updateNSView(_ view: DMSecretCodeView, context: Context) {
        view.text = text
        view.isHidden = DMSecretCodeView.isSuppressed   // W184 F3 A1：轉換中或拍圖中都藏著（拍圖途中的更新不會把碼翻出來）
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DMSecretCodeView, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? natural.width, height: natural.height)
    }
}

final class DMSecretCodeView: NSView {
    private static let live = NSHashTable<DMSecretCodeView>.weakObjects()
    /// 私訊框正在換形態：所有配對碼先藏起來。
    private(set) static var suppressed = false
    /// W184 F3（A1：GPT-6 審查 F3 #1）：拍私訊框的圖（GlobalDMPanelCanvas.capture）持有的遮蔽，可巢狀：整段拍攝都藏著——
    /// 現在畫著的、拍攝中 SwiftUI 更新到的、拍攝中新掛上的都一樣。
    private static var captureHolds: Set<Int> = []
    private static var nextHold = 0
    /// 現在該藏嗎（轉換中，或正在拍圖）。
    static var isSuppressed: Bool { suppressed || !captureHolds.isEmpty }
    #if DEBUG
    /// 自測：碼畫成可辨識的顏色（檢查拍下來的圖、圖層台裡沒有碼）。
    static var markerColor: NSColor?
    #endif

    /// 形態轉換開始（true）：現在畫著的配對碼馬上同步藏起來（在動畫的第一個畫面之前）；結束（false）：之後畫面重算時才又顯示。
    static func suppress(_ on: Bool) {
        suppressed = on
        guard on else { return }
        for view in live.allObjects { view.isHidden = true }
    }

    /// 拍圖開始：現在畫著的碼同步藏起來；之後的更新、新掛上的照 isSuppressed 藏。回傳這一段的 token。
    static func holdForCapture() -> Int {
        nextHold += 1
        captureHolds.insert(nextHold)
        for view in live.allObjects { view.isHidden = true }
        return nextHold
    }

    /// 拍圖結束：照「當下的」遮蔽狀態還原（還在轉換中＝照樣藏著；都沒有＝顯示回來），不是一律顯示。
    static func releaseCapture(_ token: Int) {
        guard captureHolds.remove(token) != nil, captureHolds.isEmpty else { return }
        let hidden = isSuppressed
        for view in live.allObjects where view.isHidden != hidden { view.isHidden = hidden }
    }

    /// 現在畫著的配對碼（自測看：碼還畫在哪些視窗）。
    static var liveViews: [DMSecretCodeView] { live.allObjects }

    var text = "" {
        didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.live.add(self)
        isHidden = Self.isSuppressed
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("配對碼")
        setAccessibilityIdentifier("tatwo.dm.handsConnect.code")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// 34 等寬半粗、字距 0.16em（放不下時等比縮小，最多到 0.6 倍）。
    private func attributed(scale: CGFloat = 1) -> NSAttributedString {
        let size = DMBrowserPhone.codeSize * scale
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: Self.textColor,
            .kern: DMBrowserPhone.codeTracking * scale,
        ])
    }

    private static var textColor: NSColor {
        #if DEBUG
        if let markerColor { return markerColor }
        #endif
        return .labelColor
    }

    override var intrinsicContentSize: NSSize {
        let size = attributed().size()
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        var text = attributed()
        if text.size().width > bounds.width, bounds.width > 0 {
            text = attributed(scale: max(0.6, bounds.width / text.size().width))
        }
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 進了哪個視窗就保護哪個視窗；離開（nil）＝放手，視窗照 linger 再擋一小段才還原。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        WindowCaptureShield.shared.hold(self, window: window)
    }
}

extension HandsConnectCard {
    /// 這張卡帶著配對碼（流程給了碼）。
    var carriesCode: Bool {
        if case .pairing(let view) = self { return view.pairingCode != nil }
        return false
    }
}

/// 帶著秘密的卡片退場不播動畫（同一個畫面裡就拿掉，不留退場的中間幀）；其他卡片照樣從下滑出、淡出。
func dmCardTransition(showingSecret: Bool) -> AnyTransition {
    showingSecret ? .identity : .move(edge: .bottom).combined(with: .opacity)
}
