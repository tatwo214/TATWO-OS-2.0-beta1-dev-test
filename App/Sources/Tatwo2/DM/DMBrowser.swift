import AppKit
import Combine
import TatwoCEFBridge

// W183 R8b（使用者 09-28 晚：「私訊鈕授權在上方tatwoos跟chatgpt圓鈕新增一欄bowser，以手機ui去搭建瀏覽器，然後授權一率從那邊就不會遺失」
// 「我人不在主設備 我根本按不了授權 可是這些都是我的設備」「私訊鈕的UI邏輯 一率當成手機做搭建」；規格 docs/specs/183-chatgpt-hands/chatgpt-build.md
// 「私訊框 › Browser」）：私訊框的第三顆圓鈕 Browser＝手機式瀏覽器，所有授權頁都開在這裡的分頁。
// - 入口只有這裡：open(url:purpose:)（Cloudflare 授權頁；只收 HandsCloudflared.loginURL 驗過的網址）、openPod(purpose:)（ChatGPT Pod 的畫面，
//   受保護的呈現放進分頁）、adoptPopup（Pod 另開的配對頁、登入視窗收進分頁，不留原生視窗）、close(purpose:)、markDone(purpose:)。
//   沒有網址列可以打字：Browser 只開流程給的頁（不是一般瀏覽器）。
// - 開的時候私訊框自動打開並切到 Browser、那個分頁在最前面。
// - **分頁不會自己消失**：框收起來、主視窗收起來、切到別的對象都不關（頁面只是從畫面拿下來，不掛在任何視窗）；流程完成＝分頁標「完成」
//   （使用者自己關）；流程結束（取消、失敗、逾時、網址撤回）＝呼叫端 close。私訊鈕總開關關掉＝全部馬上關（沿用 R5b）。
// - 敏感保護沿用 R5b／R6b，不放寬：網頁分頁＝這台 OS 瀏覽器的 human 設定檔、敏感頁（只准 https、頁內新視窗疊在同一個分頁）、
//   不進分頁清單／tabs.json／瀏覽紀錄、AI 與 Computer Use 的瀏覽器工具找不到；有分頁開著＝Computer Use 不准以 TATWO 為目標
//   （BrowserSensitivePageGate）；授權與配對時（還沒完成的分頁在畫面上）框所在的視窗不給擷取。
// - 取捨（寫進報告）：R5b 的「沒有看得到的框接手＝銷毀」改成「分頁留著、頁面不掛在任何視窗」——使用者要的是授權頁不會遺失；
//   補的保護：有分頁就擋 Computer Use、還沒完成的分頁由流程結束時關、總開關關掉全關、分頁數有上限。
// W183 R8b 審查（GPT-6、Claude）：
// - 「完成」＝頁面關掉（網頁銷毀、Pod 交回、配對頁關掉），分頁留著換成原生的完成卡、上一頁／下一頁停用；網址撤回、流程還在收尾＝
//   頁面先關掉、分頁寫「確認中」。只有還開著的真網頁算敏感（Computer Use 閘門、不給擷取）。
// - 網址 pill 只照實際載入的 http／https；沒有、空白頁、別的協定、頁面關了＝「尚未確認來源」，不拿起點或該在的網域頂替、不給鎖頭。
// - Cloudflare 授權分頁以起點網址認（不以用途合併）；授權頁的結論通知一定帶網址，沒有範圍的不收（不會跨流程命中）。
// - 使用者關掉還沒完成的分頁（含配對頁 popup）、關掉私訊鈕總開關＝走流程的取消（連線流程只取消一次）；程序收尾（closeAll()）只關。
// - Pod 的畫面是「受保護的呈現」（TapWebPod.beginGuardedPresentation）：別的畫面搶不走；分頁拿下來＝Pod 收進停泊視窗；
//   分頁關掉＝等連接器放掉、帶回首頁之後才結束（ChatGPTConnectorPod.whenSettled）。
// - 不給擷取改成以視窗計數（WindowCaptureShield）：連線卡片與 Browser 保護同一個視窗時，最後一個放手才還原。
// - 配對碼只在綁住的那一頁正是現在看得到的那一頁時顯示（showsSurface）；換分頁、分頁清單、框收起來＝遮起來。
// W184 D（使用者截私訊框常常只截到空白；對照稿「截圖：只有授權頁、配對碼在畫面上時不給截圖」，使用者 09-29 定案）：
// - 不給擷取只在「授權頁正在畫面上」：Browser 在框裡看得到（有框接著頁面、框在視窗裡；內橫＝右欄在顯示它）、分頁總覽沒開、
//   選中的就是還開著的敏感分頁（capturesBlocked）。敏感分頁開著但在看對話、框收起來、倒放、選中別的（完成的）分頁、開分頁總覽＝放手。
//   配對碼在畫面上由連線卡片自己持有（HandsConnectPresenter.codeOnScreen）；兩個持有者照舊以視窗計數。
// - 其他保護一條都不動：Computer Use 閘門照舊看 isSensitive（有敏感分頁開著就擋，不管在不在畫面上）、只准 https、不進紀錄、
//   popup 原生視窗不給擷取且收起來、配對碼只在綁住的那一頁在畫面上時顯示、關掉未完成分頁＝取消流程。
// W184 G2（使用者 09-29：「browser的下方改右側好了 並且缺乏目前browser space的書籤、珍藏、switch功能，試圖收納進去。」）：
// - 使用者自己開的一般分頁（直欄的書籤、珍藏、打網址或搜尋；用途 browse）：一律開**新分頁**（openBrowse），絕不在 Pod、配對、授權分頁裡導航；
//   同一個書籤、同網址的珍藏已經開著＝切過去。頁面照舊是這台 OS 瀏覽器的敏感頁建法（只准 https、頁內新視窗疊在同一頁、不進分頁清單與
//   瀏覽紀錄、AI 的瀏覽器工具找不到）。
// - 一般分頁不是授權頁：不算敏感（isSensitive 只看流程開的分頁），不擋截圖、不擋 Computer Use（同主視窗的 Browser space）；
//   流程分頁的保護（Computer Use 閘門、截圖、配對碼、R9 租約、關掉未完成＝取消）一條不動。
// - 分頁數（W184 G2 修正，GPT-6 1、2／查證 #3；第三輪）：一般分頁最多 maxTabs−2 個；滿了只收「已完成、不在最前面」的分頁
//   （完成的頁面早就關了）；絕不收使用者開的一般分頁、還沒完成的流程分頁（不替使用者取消別的流程）、目前在看的分頁；先確認新頁建得起來
//   才動別的分頁。流程分頁（授權頁、Pod、配對頁）永遠有位子：還是滿＝暫時多開（流程很短，用完就收），不因為分頁數退到 OS 瀏覽器
//   （那裡沒有截圖保護）；只有網頁自己開的新視窗有硬上限（maxTabs＋popupOverflow），到了＝不開、Browser 上一句話。
//   使用者自己開的一般分頁放不下＝一句話。

/// Browser 分頁是誰開的（決定起點怎麼驗、網址 pill 該是哪個網域、流程結束時收哪些）。
enum DMBrowserPurpose: String, Sendable, CaseIterable {
    /// Cloudflare 授權頁（ChatGPT build 的登入、環境登入 › Cloudflare、副設備「在這台打開授權頁」）。
    case cloudflareLogin = "cloudflare_login"
    /// ChatGPT Pod 的畫面（建連接器、開發者模式、配對頁在 Pod 同一頁）。
    case chatgptDeveloper = "chatgpt_developer"
    /// Pod 在連線時另開的 TATWO 配對頁（popup）。
    case chatgptPairing = "chatgpt_pairing"
    /// W183 R8b 審查（GPT-6）：Pod 在 Browser 顯示時另開的登入視窗（例如用 Google 登入 ChatGPT）：一樣收進分頁、一樣保護。
    case chatgptLogin = "chatgpt_login"
    /// W184 G2：使用者自己開的一般網頁（書籤、珍藏、打網址或搜尋）；不是流程的頁。
    case browse = "browse"

    /// 分頁上的名字（對照稿：「Cloudflare」「ChatGPT Dev」）。
    var title: String {
        switch self {
        case .cloudflareLogin: "Cloudflare"
        case .chatgptDeveloper: "ChatGPT Dev"
        case .chatgptPairing: "TATWO 配對"
        case .chatgptLogin: "ChatGPT 登入"
        case .browse: "網頁"
        }
    }

    /// 這種分頁該在的網域（網址 pill 對不上就標出來）；配對頁由呼叫端給（這台主機的公開網址）；登入視窗不比（各家登入網域）；一般網頁不比。
    @MainActor var expectedHost: String? {
        switch self {
        case .cloudflareLogin: return HandsCloudflared.loginHost.split(separator: ".").suffix(2).joined(separator: ".")
        case .chatgptDeveloper: return ChatGPTTap.homeURL.host
        case .chatgptPairing, .chatgptLogin, .browse: return nil
        }
    }

    /// 連線流程的分頁（Pod、配對頁、登入視窗：同一個流程）。W184 G2：明列（一般網頁不是連線流程）。
    var isConnect: Bool { self == .chatgptDeveloper || self == .chatgptPairing || self == .chatgptLogin }
    /// W184 G2：流程開的分頁（授權頁、Pod、配對頁、登入視窗）；一般網頁不是。敏感保護只看流程開的分頁。
    var isFlow: Bool { self != .browse }
}

/// W184 G2：一般分頁是從哪裡開的（同一個書籤、同網址的珍藏已經開著＝切過去；打網址或搜尋＝一律新分頁）。
/// W184 G2d：pinned＝側欄「📌 Pinned」底下那一列（主視窗釘選的分頁；值＝它在分頁清單裡的 id）：同一列再按＝切過去。
enum DMBrowserBrowseOrigin: Equatable, Sendable {
    case typed
    case bookmark(UUID)
    case favorite(UUID)
    case pinned(UUID)
}

/// W184 G2：一般分頁開不了的原因（畫面上一句話；分頁滿了多一顆「所有分頁」）。
enum DMBrowserBrowseRefusal: Equatable, Sendable {
    /// 私訊鈕總開關關著。
    case off
    /// 不是 https 網頁（javascript:、file:、帶帳密……）。
    case notSecure
    /// 分頁滿了（最多 DMBrowser.maxTabs 個）。
    case full
    /// W184 G2 修正：一般網頁滿了（最多 DMBrowser.maxBrowseTabs 個，留位子給授權頁、配對頁）。
    case browseFull

    @MainActor var line: String {
        switch self {
        case .off: "私訊鈕關著，Browser 不開網頁。"
        case .notSecure: "這個打不開：私訊框的 Browser 只開 https 網頁。"
        case .full: "分頁滿了（最多 \(DMBrowser.maxTabs) 個），先關掉一個。"
        case .browseFull: "一般網頁最多 \(DMBrowser.maxBrowseTabs) 個（留位子給授權頁、配對頁），先關掉一個。"
        }
    }
}

/// W184 G2：開一般分頁的結果（畫面照它收起卡片或說一句話）。
enum DMBrowserBrowseResult: Equatable, Sendable {
    case opened(UUID)
    case switched(UUID)
    /// W184 G2 修正（查證 #6）：同一個書籤、珍藏的分頁上次沒開成（載入失敗）：重新載入那一頁。
    case reloaded(UUID)
    case refused(DMBrowserBrowseRefusal)
}

/// W184 G2c：要一個新分頁（側欄的新分頁、分頁總覽的＋、搜尋框的＋、⌘⌥T 都走 DMBrowser.newTab）：畫面照它把游標放進空白分頁上置中的搜尋框（W184 G2d）；
/// 開不了（一般網頁滿了）＝頁面頂上那一句話。serial 每要一次加一（同一個結果連按兩次也算一次新的）。
struct DMBrowserNewTabAsk: Equatable, Sendable {
    let serial: Int
    let refusal: DMBrowserBrowseRefusal?
}

enum DMBrowserTabKind: Equatable, Sendable {
    /// 這台 OS 瀏覽器的 human 設定檔開的敏感頁（R5b 的建法）。
    case web
    /// ChatGPT Pod（同一個 Pod，受保護的呈現放進分頁）。
    case pod
    /// Pod 另開的 popup（key＝ChatGPTConnectorPod 的 popup 編號）。
    case popup(Int)
}

/// 一個分頁看得到的樣子（畫面只讀這個）。
struct DMBrowserTabInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    let purpose: DMBrowserPurpose
    let kind: DMBrowserTabKind
    /// 起點（網頁分頁才有；只拿來認分頁、給「改在 OS 瀏覽器開」，不拿來當網址 pill）。
    let startURL: URL?
    /// 該在的網域（nil＝不比）。
    var expectedHost: String?
    /// 看得到的那一頁實際載入的主框架網址（原生回報的 http／https）。W183 R8b 審查（GPT-6）：沒有、空白頁、錯誤頁、別的協定、
    /// 還沒載入＝nil（「尚未確認來源」），不拿起點或該在的網域頂替。
    var pageURL: URL?
    var loading = true
    /// 打不開、載入失敗的白話原因。
    var problem: String?
    /// 頁內開的新視窗疊了幾層（網頁分頁）。
    var stacked = 0
    var canGoBack = false
    var canGoForward = false
    /// 流程完成（分頁標「完成」；不關，使用者自己關）。
    var done = false
    /// W183 R8b 審查：頁面已經關掉（完成、網址撤回在等結果、這一步不用看 Pod）：分頁留著、內容換成原生卡片。
    var pageClosed = false
    /// 頁面關掉時原生卡片上的一句話（完成＝nil）。
    var note: String?
    /// W184 G2：一般分頁的名字（書籤、珍藏的名字；打的網址＝網域；搜尋＝「搜尋：…」）；流程的分頁＝nil（用用途的名字）。
    var label: String? = nil
    /// W184 G2：一般分頁從哪裡開的（同一個書籤、珍藏再按一次＝切過去）。
    var origin: DMBrowserBrowseOrigin? = nil

    var title: String { label ?? purpose.title }
    /// 來源確認了（頁面開著、實際載入了 http／https）。
    var sourceKnown: Bool { !pageClosed && pageURL != nil }
    /// 網址 pill 的網域（只有實際載入的頁面才有；沒有＝空字串）。
    var displayHost: String { sourceKnown ? pageURL.map(GlobalDMWebSheet.displayHost) ?? "" : "" }
    /// 不是 https（網頁分頁本來就只准 https；這裡再保險一次，不是就標出來）。
    var isInsecure: Bool { sourceKnown && pageURL.map { !GlobalDMWebSheet.isSecure($0) } == true }
    /// 網域對不上（例如授權頁導到別的網站）：標出來。
    var hostMismatch: Bool {
        guard sourceKnown, let expected = expectedHost?.lowercased(), !expected.isEmpty, let host = pageURL?.host?.lowercased() else { return false }
        return !(host == expected || host.hasSuffix("." + expected))
    }
    /// 分頁清單、網址 pill 上寫的來源（白話）。
    var sourceText: String {
        if isBlank { return "打網址或搜尋" }
        if pageClosed { return done ? "頁面已關閉" : (note ?? "頁面已收起") }
        return pageURL == nil ? "尚未確認來源" : displayHost
    }
    /// W184 G2c：空白的新分頁（直欄＋、分頁總覽的＋、⌘⌥T 開的一般分頁，還沒打網址）：沒有頁面；打了網址、點了書籤或珍藏就開在它上面。
    var isBlank: Bool { purpose == .browse && startURL == nil }
    /// 敏感：頁面還開著（授權、登入、配對的真網頁、Pod）。完成、撤下（頁面已關）就不算。
    /// W184 G2：只看流程開的分頁；使用者自己開的一般網頁（書籤、珍藏、打網址）不是授權頁，不算。
    var isSensitive: Bool { !pageClosed && purpose.isFlow }
}

/// 分頁裡的一頁（網頁＝R5b 的 CEF 敏感頁；Pod＝ChatGPT 的 Pod；popup＝Pod 開的配對頁或登入視窗；自測＝假的）。
@MainActor
protocol DMBrowserPage: AnyObject {
    var view: NSView { get }
    var isHumanActor: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// 放進框裡（已經在裡面＝不動）。
    func attach(to container: NSView)
    /// 從框裡拿下來（不銷毀）。
    func detach()
    func goBack()
    func goForward()
    /// 關掉並銷毀（Pod 只交回原處，Pod 本身不關）。
    func close()
}

@MainActor
extension DMBrowserPage {
    func attach(to container: NSView) {
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        GlobalDMNativePageMask.shared.present(view, in: container)   // W184 AB（審查 #3）：換形態轉換中新掛上／搬家的照遮蔽狀態藏，平常＝顯示
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    func detach() {
        view.removeFromSuperview()
    }
}

/// 網頁分頁：R5b 的頁面（正式＝GlobalDMCEFWebPage；自測＝假頁面）。
@MainActor
final class DMBrowserWebPage: DMBrowserPage {
    let page: any GlobalDMWebPage
    /// 最近一次的狀態（上一頁、下一頁要看）。
    var state = GlobalDMWebPageState()

    init(_ page: any GlobalDMWebPage) { self.page = page }

    var view: NSView { page.view }
    var isHumanActor: Bool { page.isHumanActor }
    var canGoBack: Bool { state.canGoBack || state.stacked > 0 }
    var canGoForward: Bool { state.canGoForward }
    func goBack() { page.goBack() }
    func goForward() { page.goForward() }
    func close() { page.close() }
}

/// ChatGPT Pod 的分頁：受保護的呈現（W183 R8b 審查）——建的時候跟 Pod 拿一份「受保護的呈現」：拿著的時候 Pod 只放在這一格
/// （別的畫面 claim 只記下，不能把它搬走；被搬走過或 Pod 重開過，下一次放進框裡就放回來）；拿下來＝Pod 收進停泊視窗（不給別的畫面）；
/// 關掉＝等連接器放掉 Pod、帶回首頁之後才結束（配對頁不會出現在別的畫面），之後 Pod 回到 ChatGPT Space 或停泊視窗，照舊在跑。
@MainActor
final class DMBrowserPodPage: DMBrowserPage {
    let pod: TapWebPod
    /// 放 Pod 的那一格。
    let view = NSView(frame: .zero)
    private let lease: UUID
    private let settled: @MainActor (@escaping @MainActor () -> Void) -> Void
    private var closed = false

    /// settled＝連接器放掉 Pod、帶回首頁之後叫（正式＝ChatGPTConnectorPod.whenSettled；自測換）。
    init(pod: TapWebPod, settled: (@MainActor (@escaping @MainActor () -> Void) -> Void)? = nil) {
        self.pod = pod
        self.settled = settled ?? { ChatGPTConnectorPod.shared.whenSettled($0) }
        lease = pod.beginGuardedPresentation()
        view.setAccessibilityElement(false)
    }

    var isHumanActor: Bool { pod.browser.map { $0.browserActor == .human && !$0.agentControlled } ?? true }
    var canGoBack: Bool { pod.browser?.canGoBack ?? false }
    var canGoForward: Bool { pod.browser?.canGoForward ?? false }

    func attach(to container: NSView) {
        guard !closed else { return }
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        pod.showGuarded(view, lease: lease)   // W183 R8b 審查（Claude）：被別的畫面搬走過、Pod 重開過＝放回這一格
        GlobalDMNativePageMask.shared.present(view, in: container)   // W184 AB（審查 #3）：照遮蔽狀態（轉換中藏；平常一定顯示，以前藏過的也回來）
    }

    func detach() {
        pod.showGuarded(nil, lease: lease)   // 拿下來＝Pod 收進停泊視窗（不給別的畫面）
        view.removeFromSuperview()
    }

    func goBack() { pod.browser?.goBack() }
    func goForward() { pod.browser?.goForward() }

    func close() {
        guard !closed else { return }
        closed = true
        detach()
        let pod = self.pod, lease = self.lease
        settled { pod.endGuardedPresentation(lease) }
    }
}

/// Pod 另開的配對頁、登入視窗（CEF popup）：原生視窗不出現（看不見、點不到、不給擷取、收起來），頁面本身搬進私訊框的分頁；
/// 分頁不在畫面上時放回它自己那個看不見的視窗（CEF 一直有地方掛）。它是敏感頁（ChatGPTConnectorPod 在 CEF 建立它之前就設了）。
@MainActor
final class DMBrowserPopupPage: DMBrowserPage {
    let popup: TatwoCEFBrowserView
    private weak var home: NSView?
    private weak var homeWindow: NSWindow?

    init(popup: TatwoCEFBrowserView) {
        self.popup = popup
        home = popup.superview
        homeWindow = popup.window
        if let window = popup.window {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.sharingType = .none
            window.orderOut(nil)
        }
    }

    var view: NSView { popup }
    var isHumanActor: Bool { popup.browserActor == .human && !popup.agentControlled && popup.sensitivePage }
    var canGoBack: Bool { popup.canGoBack }
    var canGoForward: Bool { popup.canGoForward }

    func detach() {
        guard popup.superview != nil, popup.superview !== home else { return }
        popup.removeFromSuperview()
        if let home, home.window != nil {
            popup.frame = home.bounds
            popup.autoresizingMask = [.width, .height]
            home.addSubview(popup)
        }
    }

    func goBack() { popup.goBack() }
    func goForward() { popup.goForward() }

    func close() {
        TatwoCEFContainerTeardownContract.detachFromHostWindow(popup)
        homeWindow?.orderOut(nil)
        popup.closeBrowser()
    }
}

// WindowCaptureShield（以視窗計數的「不給擷取」）搬到 DM/WindowCaptureShield.swift（W184 D：最後一個放手之後再擋到最後一幀）。

/// 授權頁的結論（HandsSetup、HandsRemoteClient 發的通知帶 rawValue）。
enum DMBrowserLoginPageEnd: String, Sendable {
    /// 授權完成（驗過、存好）：分頁標「完成」、頁面關掉。
    case done
    /// 網址撤回了、流程還在收尾（查網域、寫鑰匙圈）：頁面先關掉，分頁留著寫「確認中」。
    case withdrawn
    /// 流程結束（取消、失敗、逾時、換了一輪）：還沒完成的分頁關掉。
    case closed
}

/// 私訊框的 Browser（一台一個）：分頁、哪一頁在最前面、頁面放在哪個框、敏感保護。
@MainActor
final class DMBrowser: ObservableObject {
    /// W184 D（GPT-6 審查 #2）：正式的這一份跟著私訊框的形態轉換（轉換中配對碼一律遮起來；動畫一開始就同步藏）。
    static let shared = DMBrowser(transitions: { GlobalDMDeskController.shared.$isFormTransitioning.eraseToAnyPublisher() })
    /// 授權頁的結論（HandsSetup、HandsRemoteClient 發）：object＝那一張授權頁的網址（必填：沒有網址的不收，不會跨流程命中）；
    /// userInfo["state"]＝LoginPageEnd 的 rawValue。
    static let loginPagesNotification = Notification.Name("tatwo.dm.browser.loginPages")
    /// 分頁最多幾個（都是流程開的；滿了先收已完成的）。
    static let maxTabs = 6
    /// W184 G2 修正（GPT-6 1、2；查證 #3）：使用者自己開的一般分頁最多幾個——留兩格給流程。
    static let maxBrowseTabs = maxTabs - 2
    /// W184 G2 第三輪（查證 #1、#2）：流程分頁滿了照樣多開；網頁自己開的新視窗（Pod 的配對頁、登入視窗）最多多開到 maxTabs＋這個數。
    static let popupOverflow = 4
    static let popupRefusedText = "ChatGPT 的頁面又開了一個視窗，但私訊框的 Browser 分頁太多了，這個視窗沒開：先關掉幾個分頁再試一次"
    /// W184 G2 第三輪：Browser 上的一句話（網頁開的新視窗沒開成）；畫面點一下或過一會兒收起。
    @Published private(set) var notice: String?
    /// W184 G2c：最近一次要新分頁（畫面照它叫出網址卡）。
    @Published private(set) var newTabAsk: DMBrowserNewTabAsk?
    /// W184 G2d：側欄固定著（頂列最左邊那顆，同主視窗 Browser space 的 BrowserSidebarControls）；沒固定＝滑鼠到左緣才滑出。
    /// 停靠框、浮動框、內橫右欄是同一份（只在記憶體）。
    @Published var sidebarPinned = false

    func toggleSidebar() {
        sidebarPinned.toggle()
    }
    static let blankTitle = "新分頁"
    /// W184 G2 修正（查證 #4）：流程把它的分頁叫到前面的次數（授權頁、Pod、配對頁）：畫面照它收起直欄開著的東西（書籤、珍藏、網址卡、選單）。
    @Published private(set) var flowRaised = 0

    typealias LoginPageEnd = DMBrowserLoginPageEnd

    /// 私訊框開關的樣子（停靠框、浮動框、是不是在 Browser）：分頁全部收掉時，還是 Browser 自己打開後那樣才改回原本的樣子。
    struct BoxState: Equatable {
        let docked: Bool
        let floating: Bool
        let browsing: Bool
    }

    let store: GlobalDMStore
    /// W184 AB（GPT-6 複核 新發現 1–3）：開框＝交出一個開框請求（正式＝過桌面控制器的關口：倒放先立起、轉換中整個請求排隊）。
    private let openRequest: @MainActor (GlobalDMOpenRequest) -> Void
    private let pageHost: any GlobalDMWebPageHosting
    private let podPage: @MainActor () -> (any DMBrowserPage)?
    @Published private(set) var tabs: [DMBrowserTabInfo] = []
    @Published private(set) var activeID: UUID?
    /// 分頁清單（手機的分頁總覽：每個分頁一張小卡、可關）。
    @Published var isShowingTabList = false {
        didSet { if isShowingTabList != oldValue { place() } }
    }
    private var pages: [UUID: any DMBrowserPage] = [:]
    private var pageTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelActions: [UUID: @MainActor () -> Void] = [:]
    private var fallbackActions: [UUID: @MainActor (URL) -> Void] = [:]
    private final class WeakView { weak var view: NSView?; init(_ view: NSView) { self.view = view } }
    private var containers: [WeakView] = []
    private var prior: BoxState?
    private var applied: BoxState?
    private var observer: NSObjectProtocol?
    private var enabledWatch: AnyCancellable?
    /// W184 D：頁面放好之後要叫的（連線卡片：配對碼還在不在畫面上）。
    private var placementWatchers: [ObjectIdentifier: @MainActor () -> Void] = [:]
    /// W184 D：現在畫面上是哪一個 Pod 畫面（主框架＝-1、popup＝編號；沒有＝nil）。頁面放好之後的下一輪才更新（不在畫面更新的當下發布），
    /// 畫面照它重算配對碼要不要顯示（浮卡剛出來、換分頁之後不用等流程下一次核對；碼本身照舊只在流程給了而且綁住的那一頁看得到時顯示）。
    @Published private(set) var shownSurface: Int?
    /// 上一次排了發布的（畫面上的 Pod 頁＋放在哪個框）：框換了（停靠框↔浮動框、新建的 Browser 畫面）也要重發，新的畫面才會重算。
    private struct Placement: Equatable {
        let surface: Int?
        let container: ObjectIdentifier?
    }
    private var pendingPlacement: Placement?
    /// W184 D（GPT-6 審查 #2）：視窗算不算「看得到」（正式＝排在畫面上、沒被整個蓋住；自測換）。
    private let windowShown: @MainActor (NSWindow) -> Bool
    /// 私訊框的形態轉換（正式＝桌面控制器的 isFormTransitioning；第一次有框接頁面時才訂，不在建構時碰別的單例）。
    private let transitionSource: (@MainActor () -> AnyPublisher<Bool, Never>)?
    private var transitionWatch: AnyCancellable?
    private var occlusionObserver: NSObjectProtocol?
    /// 私訊框正在換形態（動畫中原生網頁先藏起來、配對碼一律遮起來）。
    private(set) var isTransitioning = false
    /// W184 D（主導轉達房 AB）：原生網頁正被形態轉換的遮蔽狀態藏著（GlobalDMNativePageMask.isMasking；照送來的新值記）。
    private var maskWatch: AnyCancellable?
    private(set) var isMasking = false
    /// W184 AB（GPT-6 複核 新發現 2、3）：還沒出列的開框請求（每個分頁最多一個）：分頁拿掉＝撤銷它的；分頁全收（restoreBox）＝全部撤銷。
    private var pendingOpens: [UUID: GlobalDMOpenRequest] = [:]
    /// W184 G2：直欄「網址」那張卡在打字：頁面開好、換分頁都不把鍵盤搶回頁面（畫面設）。
    var keepsKeyboard = false

    /// store、openBox／openRequest、pageHost、podPage、windowShown、transitions 只給自測換（正式＝私訊框、帶著開框請求照 ⌥⌘ 規則打開停靠框或浮動框、
    /// 這台 OS 瀏覽器的 CEF、ChatGPT 的 Pod、視窗排在畫面上而且沒被整個蓋住、桌面控制器的形態轉換）。
    /// openBox＝舊的同步假開框（叫完就算開好）；openRequest＝照正式那樣收整個請求（可以先排著、之後出列）。
    init(store: GlobalDMStore? = nil, openBox: (@MainActor () -> Void)? = nil,
         openRequest: (@MainActor (GlobalDMOpenRequest) -> Void)? = nil, pageHost: (any GlobalDMWebPageHosting)? = nil,
         podPage: (@MainActor () -> (any DMBrowserPage)?)? = nil, notifications: NotificationCenter = .default,
         windowShown: (@MainActor (NSWindow) -> Bool)? = nil, transitions: (@MainActor () -> AnyPublisher<Bool, Never>)? = nil) {
        let store = store ?? .shared
        self.store = store
        if let openRequest {
            self.openRequest = openRequest
        } else if let openBox {
            self.openRequest = { request in request.run(store: store, requiresBox: false, open: openBox) }
        } else {
            self.openRequest = { GlobalDMPanelController.shared.open($0) }
        }
        self.pageHost = pageHost ?? GlobalDMCEFWebPageHost()
        self.podPage = podPage ?? { DMBrowserPodPage(pod: ChatGPTTap.shared.pod) }
        self.windowShown = windowShown ?? { DMBrowser.windowShowsPages($0) }
        transitionSource = transitions
        observer = notifications.addObserver(forName: Self.loginPagesNotification, object: nil, queue: .main) { [weak self] note in
            // W183 R8b 審查（GPT-6）：沒有範圍（網址）的通知不收——別的流程結束不會把這一張關掉或標完成。
            guard let url = note.object as? URL else { return }
            let end = (note.userInfo?["state"] as? String).flatMap(DMBrowserLoginPageEnd.init(rawValue:)) ?? .closed
            MainActor.assumeIsolated { self?.loginPage(url, end) }
        }
        // 私訊鈕總開關關掉＝全部馬上關（沿用 R5b：不留）；W183 R8b 審查（GPT-6）：還沒完成的流程一起取消。
        enabledWatch = self.store.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in MainActor.assumeIsolated { if !enabled { self?.closeAll(cancelling: true) } } }
        // W184 D（GPT-6 審查 #2）：框所在的視窗被收起來（orderOut）、被整個蓋住、又回到畫面上：重看頁面與配對碼在不在畫面上。
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                                                   queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window === self.shownWindow else { return }
                self.placementChanged()
            }
        }
        BrowserSensitivePageGate.register(self)
    }

    /// 正式的「看得到」：排在畫面上、而且沒被別的視窗整個蓋住。
    static func windowShowsPages(_ window: NSWindow) -> Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    // MARK: - 讀

    var activeTab: DMBrowserTabInfo? { tabs.first { $0.id == activeID } }
    var hasTabs: Bool { !tabs.isEmpty }
    /// 有還開著的敏感頁（Computer Use 不准以 TATWO 為目標）。W184 D：這一條不跟著截圖放寬——不管在不在畫面上都算。
    var isSensitive: Bool { tabs.contains(where: \.isSensitive) }
    /// W184 D：授權頁正在畫面上（框所在的視窗不給擷取）：選中的是還開著的敏感分頁、分頁總覽沒開、Browser 在框裡看得到。
    /// 完成、撤下的分頁頁面已關，不算；敏感分頁開著但沒在畫面上（看對話、收起來、倒放、選中別的分頁）也不算。
    var needsCaptureProtection: Bool {
        Self.capturesBlocked(activeSensitive: activeTab?.isSensitive == true, tabList: isShowingTabList, onScreen: shownWindow != nil)
    }

    /// 不給擷取的規則（純計算；DMBrowser 持有視窗、畫面上的「這一頁不給截圖」小標都用這一條）。
    nonisolated static func capturesBlocked(activeSensitive: Bool, tabList: Bool, onScreen: Bool) -> Bool {
        activeSensitive && !tabList && onScreen
    }

    /// 頁面現在放在哪個視窗（最後叫的框在視窗裡＝Browser 在畫面上；都沒有＝nil）。
    private var shownWindow: NSWindow? { containers.last(where: { $0.view != nil })?.view?.window }
    /// ChatGPT 連線的分頁（Pod、配對頁、登入視窗）還在。
    var hasConnectTab: Bool { tabs.contains { $0.purpose.isConnect } }
    func tab(for purpose: DMBrowserPurpose) -> DMBrowserTabInfo? { tabs.first { $0.purpose == purpose } }
    /// 這個起點的網頁分頁（流程開的；W184 G2：使用者自己開的一般分頁不算，流程不會接手它）。
    func tab(start url: URL) -> DMBrowserTabInfo? { tabs.first { $0.kind == .web && $0.purpose.isFlow && $0.startURL == url } }
    /// 自測看：這個分頁的頁面開好了。
    func page(for id: UUID) -> (any DMBrowserPage)? { pages[id] }
    /// 使用者關掉這個分頁會一起取消它的流程嗎（還沒完成、有取消的路）。
    func closingCancels(_ id: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.done else { return false }
        return cancelActions[id] != nil
    }

    /// W183 R8b 審查（GPT-6）：這個 Pod 畫面（主框架＝-1、popup＝它的編號）是不是現在真的看得到的那一頁。配對碼只在綁住的那一頁
    /// 看得到時顯示（換分頁、開分頁清單、框收起來＝遮起來）。W184 D（GPT-6 審查 #2）：「看得到」照實際呈現（presents）。
    func showsSurface(_ surface: Int) -> Bool {
        guard let id = activeID, let tab = tabs.first(where: { $0.id == id }), presents(id) else { return false }
        switch tab.kind {
        case .pod: return surface == -1
        case .popup(let key): return surface == key
        case .web: return false
        }
    }

    /// W184 D（GPT-6 審查 #2：「掛在視窗」不等於「頁面看得到」）：這個分頁的頁面現在真的呈現在畫面上——選中、頁面開著而且放在最後叫的框裡、
    /// 框所在的視窗看得到（排在畫面上、沒被整個蓋住；停靠框只 orderOut、內容還掛著＝看不到）、頁面與它的上層都沒被藏起來
    /// （形態轉換會先把原生網頁藏起來）、分頁總覽沒開、不在形態轉換中（轉換一開始就不算，原生網頁恢復、轉換結束才又算）。
    func presents(_ id: UUID) -> Bool {
        guard !isShowingTabList, !isTransitioning, !isMasking, id == activeID, let page = pages[id], let tab = tabs.first(where: { $0.id == id }),
              !tab.pageClosed, let container = containers.last(where: { $0.view != nil })?.view, let window = container.window,
              page.view.superview === container, !page.view.isHiddenOrHasHiddenAncestor, windowShown(window) else { return false }
        return true
    }

    /// W184 D（GPT-6 審查 #1：跨視窗換手）：這個框是不是頁面現在放的那一個（最後叫的框）。兩個 Browser 畫面同時在（停靠框↔浮動框換手、
    /// 停靠框只 orderOut 沒拆）時，只有這一個畫配對碼；舊的那一個收起來，它的視窗在碼不見之後還原。
    func holdsPage(_ container: NSView?) -> Bool {
        guard let container else { return false }
        return containers.last(where: { $0.view != nil })?.view === container
    }

    /// W184 D（主導：R9 原生「新增 ▾」的 Pod 操作租約）：這種分頁的頁面還在私訊框裡給使用者用——Browser 在框裡（單欄的 Browser、
    /// 內橫的右欄都算；只看主 store 的 isBrowsing 會把內橫的右欄誤判成不在）、它是選中的分頁、頁面開著而且放在框裡、分頁總覽沒開、
    /// 框所在的視窗排在畫面上。GPT-6 審查 #2：短暫的形態轉換（原生網頁暫時藏起來）、被別的視窗蓋住都不算離開（不放租約）；
    /// 真的收框、停靠框被 orderOut、看對話、倒放才算。
    func showsPage(_ purpose: DMBrowserPurpose) -> Bool {
        guard !isShowingTabList, let id = activeID, let page = pages[id], let tab = tabs.first(where: { $0.id == id }),
              tab.purpose == purpose, !tab.pageClosed,
              let container = containers.last(where: { $0.view != nil })?.view, let window = container.window, window.isVisible,
              page.view.superview === container else { return false }
        return true
    }

    /// W184 D（GPT-6 審查 #2）：形態轉換開始、結束。開始＝配對碼在動畫的第一個畫面之前就同步藏起來（DMSecretCodeView），之後照
    /// 實際呈現重算（不算看得到）；結束＝原生網頁已經恢復，重算之後才又顯示碼。
    private func transitionChanged(_ on: Bool) {
        guard on != isTransitioning else { return }
        isTransitioning = on
        DMSecretCodeView.suppress(isTransitioning || isMasking)
        placementChanged()
    }

    /// W184 D（主導轉達房 AB）：原生網頁的遮蔽狀態（形態轉換把頁面藏著）：遮蔽中＝頁面不在畫面上、碼同步藏起來；租約不放（短暫）。
    private func maskChanged(_ on: Bool) {
        guard on != isMasking else { return }
        isMasking = on
        DMSecretCodeView.suppress(isTransitioning || isMasking)
        placementChanged()
    }

    // MARK: - 入口

    /// 開一個網頁分頁（現在只有 Cloudflare 授權頁；起點照用途驗過才開）。私訊框自動打開、切到 Browser、這個分頁在最前面。
    /// 私訊鈕總開關關著或網址不對＝回 false（呼叫端退回舊路）。同一個起點已經開著＝只把它叫到前面（撤下還沒結論的＝頁面重開）。
    /// W183 R8b 審查（GPT-6）：以起點認分頁（不以用途合併）：別的流程還在跑的授權分頁不會被換掉。
    /// onCancel＝使用者在還沒完成時關掉這個分頁（例如取消這一輪的授權）；fallback＝頁面打不開時「改在 OS 瀏覽器開」。
    @discardableResult
    func open(url: URL, purpose: DMBrowserPurpose, onCancel: (@MainActor () -> Void)? = nil,
              fallback: (@MainActor (URL) -> Void)? = nil) -> Bool {
        guard store.isEnabled, let start = Self.validatedStart(url, purpose) else { return false }
        if let existing = tab(start: start) {
            cancelActions[existing.id] = onCancel
            fallbackActions[existing.id] = fallback
            guard existing.pageClosed, !existing.done else {
                reveal(existing.id)
                return true
            }
            update(existing.id) { $0.pageClosed = false; $0.note = nil; $0.loading = true; $0.problem = nil }
            BrowserSensitivePageGate.pageAppeared()
            reveal(existing.id)
            startWebPage(existing.id, url: start)
            return true
        }
        commitRoom(flowRoom())   // W184 G2 第三輪：流程分頁永遠有位子（滿了暫時多開），不退到 OS 瀏覽器、不關別的分頁
        let tab = DMBrowserTabInfo(id: UUID(), purpose: purpose, kind: .web, startURL: start, expectedHost: purpose.expectedHost)
        tabs.append(tab)
        cancelActions[tab.id] = onCancel
        fallbackActions[tab.id] = fallback
        BrowserSensitivePageGate.pageAppeared()   // 敏感頁出現：以 TATWO 自己為目標的 Computer Use 馬上撤銷
        reveal(tab.id)
        startWebPage(tab.id, url: start)
        return true
    }

    /// ChatGPT Pod 的分頁（一個；已經有＝叫到前面、頁面收起來過就放回來、重新算「完成」）。onCancel＝使用者在還沒完成時關掉它（取消這次連線）。
    @discardableResult
    func openPod(purpose: DMBrowserPurpose = .chatgptDeveloper, currentURL: URL? = nil,
                 onCancel: (@MainActor () -> Void)? = nil) -> Bool {
        guard store.isEnabled else { return false }
        let observed = currentURL.flatMap { GlobalDMWebPageState.committed($0.absoluteString) }
        if let existing = tabs.first(where: { $0.kind == .pod }) {
            if pages[existing.id] == nil {
                guard let page = podPage() else { return false }
                pages[existing.id] = page
                update(existing.id) { $0.pageURL = observed; $0.loading = false }
            }
            if let onCancel { cancelActions[existing.id] = onCancel }
            update(existing.id) { $0.done = false; $0.pageClosed = false; $0.note = nil }
            BrowserSensitivePageGate.pageAppeared()
            reveal(existing.id)
            refreshNavigation(existing.id)
            return true
        }
        // W184 G2 修正（GPT-6 1；第三輪）：先確認 Pod 的頁面建得起來，才動別的分頁；流程分頁永遠有位子（滿了暫時多開）。
        guard let page = podPage() else { return false }
        commitRoom(flowRoom())
        let tab = DMBrowserTabInfo(id: UUID(), purpose: purpose, kind: .pod, startURL: nil, expectedHost: purpose.expectedHost,
                                   pageURL: observed, loading: false)
        tabs.append(tab)
        pages[tab.id] = page
        cancelActions[tab.id] = onCancel
        BrowserSensitivePageGate.pageAppeared()
        reveal(tab.id)
        refreshNavigation(tab.id)
        return true
    }

    /// W183 R8b 審查（Claude）：這一步不用在 Pod 上操作（連線流程收起 Pod 的畫面）：Pod 從分頁拿下來、交回（受保護的呈現等連接器放掉、
    /// 帶回首頁之後才結束），分頁留著、換成原生的一句話。完成的不動。
    func suspendPod() {
        guard let tab = tabs.first(where: { $0.kind == .pod }), !tab.pageClosed else { return }
        retire(tab.id, done: false, note: "ChatGPT 的頁面先收起來了（這一步不用在頁面上操作）")
        place()
    }

    /// Pod 另開的視窗：收進分頁（不留原生視窗）、叫到前面。私訊鈕關著＝不留（關掉）。
    /// purpose＝配對頁（連線流程拿著 Pod 時開的）或登入視窗；onCancel＝使用者在還沒完成時關掉這個分頁（配對頁＝取消這次連線）。
    func adoptPopup(_ page: any DMBrowserPage, key: Int, purpose: DMBrowserPurpose = .chatgptPairing, expectedHost: String?,
                    onCancel: (@MainActor () -> Void)? = nil, onFull: (@MainActor () -> Void)? = nil) {
        guard store.isEnabled else { page.close(); return }
        if let existing = tabs.first(where: { $0.kind == .popup(key) }) {
            reveal(existing.id)
            return
        }
        // W184 G2 修正（GPT-6 2；查證 #3；第三輪 #2）：流程開的新視窗照樣多開；只有到了硬上限（網頁一直開窗）才不開——不替使用者關別的
        // 分頁、不取消別的流程：這一頁關掉、Browser 上一句話（不管有沒有在連線），連線中另外交給呼叫端（onFull：卡片說一句）。
        guard let room = popupRoom() else {
            page.close()
            notice = Self.popupRefusedText
            onFull?()
            return
        }
        commitRoom(room)
        let tab = DMBrowserTabInfo(id: UUID(), purpose: purpose, kind: .popup(key), startURL: nil, expectedHost: expectedHost ?? purpose.expectedHost)
        tabs.append(tab)
        pages[tab.id] = page
        cancelActions[tab.id] = onCancel
        BrowserSensitivePageGate.pageAppeared()
        reveal(tab.id)
        refreshNavigation(tab.id)
    }

    /// 把這個 popup 的分頁叫到前面（連線流程在它上面看到了配對頁）。
    func focusPopup(key: Int) {
        guard let tab = tabs.first(where: { $0.kind == .popup(key) }) else { return }
        reveal(tab.id)
    }

    /// 連線流程又叫私訊框出來（例如從 TAP 再按一次）：把連線的分頁叫到前面（配對頁優先，其次 Pod）。沒有就不動。
    func revealConnectTab() {
        guard let tab = tabs.last(where: { $0.purpose == .chatgptPairing }) ?? tabs.first(where: { $0.purpose == .chatgptDeveloper }) else { return }
        reveal(tab.id)
    }

    /// 流程完成：這種分頁標「完成」、頁面關掉（W183 R8b 審查：不留可以操作的登入頁——網頁銷毀、Pod 交回、配對頁關掉）。分頁留著，使用者自己關。
    func markDone(purpose: DMBrowserPurpose) {
        for tab in tabs where tab.purpose == purpose {
            retire(tab.id, done: true, note: nil)
        }
        place()
    }

    /// 流程結束：關掉這種分頁（keepingDone＝已完成的留著給使用者自己關）。
    func close(purpose: DMBrowserPurpose, keepingDone: Bool = false) {
        for tab in tabs where tab.purpose == purpose && !(keepingDone && tab.done) {
            removeTab(tab.id)
        }
    }

    /// 全部關掉。cancelling＝使用者關掉私訊鈕總開關：還沒完成的流程一起取消（連線流程只取消一次）；自測收尾、程序收尾＝只關。
    func closeAll(cancelling: Bool = false) {
        var cancels: [@MainActor () -> Void] = []
        var connectCancelled = false
        if cancelling {
            for tab in tabs where !tab.done {
                guard let cancel = cancelActions[tab.id] else { continue }
                if tab.purpose.isConnect {
                    if connectCancelled { continue }
                    connectCancelled = true
                }
                cancels.append(cancel)
            }
        }
        for tab in tabs { removeTab(tab.id) }
        for cancel in cancels { cancel() }
    }

    // MARK: - 使用者在 Browser 上按的

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeID = id
        isShowingTabList = false
        place(focus: true)
    }

    /// 使用者關掉一個分頁（分頁上的 ×）：還沒完成的＝也取消它那個流程（例如這一輪的授權、這次連線）；完成的只關。
    func userClose(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let cancel = tab.done ? nil : cancelActions[id]
        removeTab(id)
        cancel?()
    }

    func goBack() {
        guard let id = activeID, let page = pages[id] else { return }
        page.goBack()
        refreshNavigation(id)
    }

    func goForward() {
        guard let id = activeID, let page = pages[id] else { return }
        page.goForward()
        refreshNavigation(id)
    }

    /// W184 G2d：頂列的重新載入（Browser space 的那一顆）：只給使用者自己開的一般分頁；授權頁、配對頁、Pod 不重新載入（流程的頁面不動）。
    /// GPT-6 審查 G2d #1：頁面還在＝原生重新載入（同一個瀏覽器、上一頁／下一頁的紀錄都在；載入失敗的頁也是在它自己上面重試）；
    /// 頁面沒建起來（建立失敗）＝才重建（reload(_:)，失敗重試那一條）；還在建立＝本來就在載入，不動。
    func reloadActive() {
        guard let tab = activeTab, Self.reloadable(tab) else { return }
        if let page = pages[tab.id] as? DMBrowserWebPage {
            page.page.reload()
            return
        }
        guard pageTasks[tab.id] == nil else { return }
        reload(tab.id)
    }

    /// 能不能重新載入：一般分頁、不是空白的新分頁、頁面還在（沒被收起）。
    nonisolated static func reloadable(_ tab: DMBrowserTabInfo) -> Bool {
        tab.purpose == .browse && !tab.isBlank && !tab.pageClosed
    }

    /// 頁面打不開：關掉這個分頁、改在 OS 瀏覽器開（只有使用者在錯誤畫面按了才走）。
    func openElsewhere() {
        guard let tab = activeTab, let url = tab.startURL, let fallback = fallbackActions[tab.id] else { return }
        removeTab(tab.id)
        fallback(url)
    }

    var canOpenElsewhere: Bool { activeID.map { fallbackActions[$0] != nil } ?? false }

    // MARK: - W184 G2：使用者自己開的一般分頁（直欄的書籤、珍藏、打網址或搜尋）

    /// 開一般網頁：一律開**新分頁**，絕不在 Pod、配對、授權分頁裡導航（流程的頁面一個都不碰）；同一個書籤、同網址的珍藏已經開著＝切過去
    /// （只找一般分頁）。只收 https、沒有帳密的網址；私訊鈕關著、分頁滿了＝不開，回一句話。
    /// 按的就是框裡的鈕（框開著、Browser 在畫面上）：不另外走開框請求；使用者自己開了分頁＝Browser 交給使用者（分頁全關時不再自動收框）。
    /// typedInto＝打網址時，開始打字的那一個分頁（畫面在開始打字時記下；沒有分頁＝nil）。
    @discardableResult
    func openBrowse(url: URL, title: String?, origin: DMBrowserBrowseOrigin = .typed, typedInto: UUID? = nil) -> DMBrowserBrowseResult {
        guard store.isEnabled else { return .refused(.off) }
        guard let start = Self.browseStart(url) else { return .refused(.notSecure) }
        if let existing = browseTab(origin, url: start) {
            // W184 G2 修正（查證 #6）：上次沒開成（載入失敗、頁面沒建起來）＝再按一次就重新載入，不是只切過去。
            if existing.problem != nil || (pages[existing.id] == nil && pageTasks[existing.id] == nil) {
                reload(existing.id)
                select(existing.id)
                return .reloaded(existing.id)
            }
            select(existing.id)
            return .switched(existing.id)
        }
        // W184 G2c：目前在看的是空白的新分頁＝就開在它上面（不再多開一個）。
        // W184 G2c 第二輪（GPT-6 #3）：打網址只開在「開始打字的那一個」空白分頁上，而且送出的當下它還在、還是空白的一般頁、還是目前那一頁；
        // 不是（換過頁、關掉了）＝照打網址的規則開新分頁，草稿不填進別的空白頁。書籤、珍藏＝按下去的當下在看的那一個空白分頁。
        if let blank = Self.blankToFill(origin: origin, typedInto: typedInto, active: activeTab) {
            fill(blank, start: start, title: title, origin: origin)
            return .opened(blank)
        }
        if tabs.filter({ $0.purpose == .browse }).count >= Self.maxBrowseTabs { return .refused(.browseFull) }
        guard let room = browseRoom() else { return .refused(.full) }   // 一般分頁不多開
        commitRoom(room)
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var tab = DMBrowserTabInfo(id: UUID(), purpose: .browse, kind: .web, startURL: start, expectedHost: nil)
        tab.label = (name?.isEmpty == false ? name : nil) ?? start.host
        tab.origin = origin
        tabs.append(tab)
        prior = nil
        applied = nil
        store.showBrowser()
        activeID = tab.id
        isShowingTabList = false
        place(focus: true)
        startWebPage(tab.id, url: start)
        return .opened(tab.id)
    }

    /// W184 G2c 第二輪（GPT-6 #3）：要開在哪一個空白分頁上（沒有＝nil，開新分頁）。只看目前那一頁：它要是空白的一般頁（.browse、還沒有起點）；
    /// 打網址（.typed）還要是開始打字的那一頁（typedInto）——換過頁、關掉又被別頁接手＝不是同一頁。
    nonisolated static func blankToFill(origin: DMBrowserBrowseOrigin, typedInto: UUID?, active: DMBrowserTabInfo?) -> UUID? {
        guard let active, active.isBlank else { return nil }
        if origin == .typed { return typedInto == active.id ? active.id : nil }
        return active.id
    }

    /// 已經開著的一般分頁：同一個書籤、同一個珍藏（或網址一樣的一般分頁）；打網址＝一律新開。流程的分頁永遠不算。
    func browseTab(_ origin: DMBrowserBrowseOrigin, url: URL) -> DMBrowserTabInfo? {
        let browse = tabs.filter { $0.purpose == .browse }
        switch origin {
        case .typed:
            return nil
        case .bookmark, .pinned:
            return browse.first { $0.origin == origin }
        case .favorite:
            // W184 G2 第三輪（查證 #5；同主視窗 BrowserTabRegistry.openFavorite）：先找這個珍藏自己開的分頁——就算載入時轉址、加了 query、
            // 換了 SPA 路由，仍然是它的分頁；沒有＝找沒綁定的一般分頁（打網址開的）「現在」停在同一個網址的（GPT-6 6：已經導到別處＝不算）。
            // 書籤、別的珍藏開的分頁屬於它們自己，不拿來比網址。
            if let bound = browse.first(where: { $0.origin == origin }) { return bound }
            let key = BrowserTabRegistry.favoriteURLKey(url)
            return browse.first { tab in
                guard tab.origin == .typed, let current = Self.currentAddress(tab) else { return false }
                return BrowserTabRegistry.favoriteURLKey(current) == key
            }
        }
    }

    /// 一般分頁現在停在哪：已提交的網址；還在載入第一頁（沒提交過、沒出錯）＝起點；其他（空白頁、錯誤頁、別的協定）＝nil。
    nonisolated static func currentAddress(_ tab: DMBrowserTabInfo) -> URL? {
        if let committed = tab.pageURL { return committed }
        return tab.loading && tab.problem == nil ? tab.startURL : nil
    }

    /// W184 G2 修正（查證 #6）：重新載入一般分頁（上次沒開成）：舊頁面（有的話）關掉、清掉錯誤、再開一次。
    /// W184 G2 第三輪（查證 #7）：開的是這個分頁自己失敗的那個網址（最後停在的網址；還沒停過＝它的起點），不是別的網址。
    private func reload(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.purpose == .browse,
              let target = Self.retryAddress(tab) else { return }
        pageTasks.removeValue(forKey: id)?.cancel()
        if let page = pages.removeValue(forKey: id) {
            page.detach()
            page.close()
        }
        update(id) { $0.problem = nil; $0.loading = true; $0.pageURL = nil; $0.canGoBack = false; $0.canGoForward = false; $0.stacked = 0 }
        startWebPage(id, url: target)
    }

    /// 重試開哪個網址：分頁最後停在的網址（只收 https）；還沒停過＝它的起點。
    nonisolated static func retryAddress(_ tab: DMBrowserTabInfo) -> URL? {
        tab.pageURL.flatMap(browseStart) ?? tab.startURL
    }

    /// W184 G2 第三輪：畫面點一下、或過一會兒，收起 Browser 上那一句話。
    func clearNotice() {
        notice = nil
    }

    /// W184 G2c：新分頁（直欄＋、分頁總覽的＋、⌘⌥T）：開一個空白的一般分頁（照一般分頁的上限：最多 maxBrowseTabs 個，滿了＝一句話），
    /// 叫到前面、收起分頁總覽；畫面照 newTabAsk 把網址卡叫出來、游標在網址欄（打網址或搜尋就開在這一頁）。
    /// 已經在一個空白的新分頁上＝不再多開，只叫出網址卡。不是授權頁（一般分頁）；總開關關著不開。
    @discardableResult
    func newTab() -> DMBrowserBrowseResult {
        guard store.isEnabled else { return ask(.refused(.off)) }
        isShowingTabList = false
        if let blank = activeTab, blank.isBlank {
            store.showBrowser()
            return ask(.switched(blank.id))
        }
        if tabs.filter({ $0.purpose == .browse }).count >= Self.maxBrowseTabs { return ask(.refused(.browseFull)) }
        guard let room = browseRoom() else { return ask(.refused(.full)) }
        commitRoom(room)
        var tab = DMBrowserTabInfo(id: UUID(), purpose: .browse, kind: .web, startURL: nil, expectedHost: nil)
        tab.label = Self.blankTitle
        tab.origin = .typed
        tab.loading = false
        tabs.append(tab)
        prior = nil
        applied = nil
        store.showBrowser()
        activeID = tab.id
        place(focus: false)
        return ask(.opened(tab.id))
    }

    private func ask(_ result: DMBrowserBrowseResult) -> DMBrowserBrowseResult {
        let refusal: DMBrowserBrowseRefusal?
        if case .refused(let reason) = result { refusal = reason } else { refusal = nil }
        newTabAsk = DMBrowserNewTabAsk(serial: (newTabAsk?.serial ?? 0) &+ 1, refusal: refusal)
        return result
    }

    /// 把空白的新分頁換成要開的網頁（同一個分頁、同一個 id）。
    private func fill(_ id: UUID, start: URL, title: String?, origin: DMBrowserBrowseOrigin) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var tab = DMBrowserTabInfo(id: id, purpose: .browse, kind: .web, startURL: start, expectedHost: nil)
        tab.label = (name?.isEmpty == false ? name : nil) ?? start.host
        tab.origin = origin
        tabs[index] = tab
        store.showBrowser()
        activeID = id
        isShowingTabList = false
        place(focus: true)
        startWebPage(id, url: start)
    }

    /// 一般網頁的起點：只收 https、有網域、沒有帳密（http、javascript:、file: 之類一律不開；要升級成 https 由呼叫端先做）。
    nonisolated static func browseStart(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    // MARK: - 流程回報

    /// Pod 主框架或 popup 載入了一頁（原生回報；ChatGPTConnectorPod.onDisplayFrame）；popup 自己關了＝分頁拿掉（完成的留著）。
    func podFrame(_ frame: HandsPodFrame) {
        let match: DMBrowserTabKind = frame.popup ? .popup(frame.popupKey ?? -2) : .pod
        guard let tab = tabs.first(where: { $0.kind == match }) else { return }
        if frame.popup, frame.closed {
            if tab.pageClosed { return }   // 頁面是這邊關的（完成）：分頁留著
            return removeTab(tab.id, closing: false)
        }
        guard !tab.pageClosed else { return }   // 頁面已經關了（完成、Pod 收起來）：不再跟
        update(tab.id) {
            // W183 R8b 審查（GPT-6）：只認這一次回報裡實際載入的 http／https；沒有、空白頁、別的協定＝尚未確認來源（不沿用舊的）。
            $0.pageURL = frame.url.flatMap { GlobalDMWebPageState.committed($0.absoluteString) }
            $0.loading = frame.loading
        }
        refreshNavigation(tab.id)
    }

    /// 授權頁的結論（只認那一張的網址）：完成＝標「完成」、頁面關掉；撤回＝頁面先關、分頁寫「確認中」；結束＝還沒完成的關掉。
    func loginPage(_ url: URL, _ end: LoginPageEnd) {
        for tab in tabs where tab.purpose == .cloudflareLogin && tab.kind == .web && tab.startURL == url {
            switch end {
            case .done: retire(tab.id, done: true, note: nil)
            case .withdrawn: if !tab.done { retire(tab.id, done: false, note: "確認中…（授權頁已關閉，等結果）") }
            case .closed: if !tab.done { removeTab(tab.id) }
            }
        }
        place()
    }

    // MARK: - 頁面放在哪個框（停靠框、浮動框、兩欄的一欄；最後叫的拿到，放手就回前一個；都沒有＝頁面拿下來，分頁留著）

    func claim(_ container: NSView) {
        if transitionWatch == nil, let transitionSource {   // 第一次有框接頁面：跟著私訊框的形態轉換（同步送來，動畫開始之前）
            transitionWatch = transitionSource().sink { [weak self] on in MainActor.assumeIsolated { self?.transitionChanged(on) } }
        }
        if maskWatch == nil {   // 原生網頁的遮蔽狀態（房 AB；同步送來、送的是新值）
            maskWatch = GlobalDMNativePageMask.shared.$isMasking.sink { [weak self] on in MainActor.assumeIsolated { self?.maskChanged(on) } }
        }
        containers.removeAll { $0.view == nil }
        if !containers.contains(where: { $0.view === container }) {
            containers.append(WeakView(container))
            place(focus: true)
        } else {
            place()
        }
    }

    func release(_ container: NSView) {
        containers.removeAll { $0.view == nil || $0.view === container }
        place()
    }

    /// 框換了視窗（停靠框↔浮動框）：重看要不要擋擷取。
    func containerMoved() {
        protectCapture()
        placementChanged()
    }

    /// W184 D：頁面放好之後（換分頁、開關分頁總覽、框收起來或換了視窗、頁面關了）叫：連線卡片重看「配對碼還在不在畫面上」。
    /// 一個持有者一個（再登記＝換掉）；持有者自己用 weak 接著，不在了就什麼都不做。
    func watchPlacement(_ owner: AnyObject, _ body: @escaping @MainActor () -> Void) {
        placementWatchers[ObjectIdentifier(owner)] = body
    }

    private func placementChanged() {
        for body in placementWatchers.values { body() }
        var surface: Int?
        if showsSurface(-1) {
            surface = -1
        } else if let tab = activeTab, case .popup(let key) = tab.kind, showsSurface(key) {
            surface = key
        }
        let now = Placement(surface: surface, container: containers.last(where: { $0.view != nil })?.view.map { ObjectIdentifier($0) })
        guard now != pendingPlacement else { return }
        pendingPlacement = now
        // 下一輪 run loop 才發布（不在 SwiftUI 更新畫面的當下）；用 run loop 不用 main queue：巢狀的 run loop（例如在 main queue 的工作裡
        // 跑畫面）也會輪到它。值一樣也發布一次：新建的 Browser 畫面（換形態、框換手）第一次算的時候頁面還沒放進去，要靠這一次重算；
        // 框換了（停靠框↔浮動框）舊的畫面也要重算，才會把碼收起來。
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingPlacement == now else { return }
                self.shownSurface = now.surface
            }
        }
    }

    /// 現在最前面的分頁的頁面放進最後叫的那個框；其他分頁的頁面拿下來（不銷毀）。分頁清單開著＝頁面也先拿下來（原生頁面會蓋住清單）。
    private func place(focus: Bool = false) {
        containers.removeAll { $0.view == nil }
        let target = isShowingTabList ? nil : containers.last?.view
        for tab in tabs {
            guard let page = pages[tab.id] else { continue }
            if tab.id == activeID, let target { page.attach(to: target) } else { page.detach() }
        }
        if focus, target != nil { focusActive() }
        protectCapture()
        placementChanged()   // W184 D：配對碼的持有者跟著重看
    }

    /// 鍵盤給頁面（不是別的輸入列）；頁面還沒有能接鍵盤的東西＝至少讓別的輸入列放掉。W184 G2：直欄的網址卡在打字＝不搶。
    private func focusActive() {
        guard !keepsKeyboard, let id = activeID, let view = pages[id]?.view, let window = view.window else { return }
        if let responder = window.firstResponder as? NSView, responder === view || responder.isDescendant(of: view) { return }
        if let candidate = Self.keyTarget(in: view), window.makeFirstResponder(candidate) { return }
        window.makeFirstResponder(nil)
    }

    /// 頁面裡第一個能接鍵盤的元件（CEF 的原生子元件；外層的 TatwoCEFBrowserView 本身不接）。
    static func keyTarget(in view: NSView) -> NSView? {
        var queue: [NSView] = [view]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let next = queue.removeFirst()
            visited += 1
            if !next.isHidden, next.acceptsFirstResponder { return next }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    /// W184 D：授權頁正在畫面上＝框所在的視窗不給擷取（WindowCaptureShield 以視窗計數）；換到對話、收起來、倒放、選中別的分頁、
    /// 開分頁總覽、完成（頁面關掉）、框換了＝放手或跟著換視窗。
    private func protectCapture() {
        containers.removeAll { $0.view == nil }
        let window = containers.last?.view?.window
        WindowCaptureShield.shared.hold(self, window: needsCaptureProtection ? window : nil)
    }

    /// 自測看：框所在的視窗現在不給擷取（哪一個視窗）。
    var isProtectingCapture: Bool { captureProtectedWindow != nil }
    var captureProtectedWindow: NSWindow? { WindowCaptureShield.shared.window(heldBy: self) }

    // MARK: - 內部

    /// 私訊框自動打開、切到 Browser、這個分頁在最前面（第一次開分頁時記下私訊框原本的樣子）。
    /// W184 AB（GPT-6 複核 新發現 1–3）：整個操作是一個開框請求——倒放、轉換中排隊的是整個請求，框真的開好之後才切到 Browser、
    /// 把分頁叫到前面；出列前分頁被關掉＝撤銷（不再開框、不立起）；完成回呼記這一次開框之後的樣子。
    private func reveal(_ id: UUID) {
        guard store.isEnabled else { return }
        if prior == nil { prior = BoxState(docked: store.isOpen, floating: store.isFloatingOpen, browsing: store.isBrowsing) }
        pendingOpens.removeValue(forKey: id)?.cancel()
        let request = GlobalDMOpenRequest(valid: { [weak self] in self?.tabs.contains { $0.id == id } == true },
                                          then: { [weak self] in self?.bringToFront(id) })
        pendingOpens[id] = request
        request.whenFinished { [weak self] outcome in self?.openFinished(id, request, outcome) }
        // W184 G2 修正（查證 #4）：流程要把它的分頁叫到前面：網址卡拿著的鍵盤放掉（分頁放好時鍵盤給那一頁）、畫面收起直欄開著的東西。
        keepsKeyboard = false
        flowRaised &+= 1
        openRequest(request)
    }

    /// 開框請求出列、框開好了：切到 Browser、這個分頁在最前面。
    private func bringToFront(_ id: UUID) {
        store.showBrowser()
        activeID = id
        isShowingTabList = false
        place(focus: true)
    }

    /// W184 AB（GPT-6 複核 新發現 3）：這一次開框請求的完成回呼——框真的開著才記「打開後的樣子」（不用「任一框已開」推定；
    /// 排隊之後停靠框換成浮動框，記的就是浮動框，收尾照樣改回原本的停靠框）。使用者在上一次打開之後自己動過框
    /// （開這一次之前的樣子已經不是上一次記的）＝不改記：收尾時比對不上，不蓋掉使用者的操作。
    private func openFinished(_ id: UUID, _ request: GlobalDMOpenRequest, _ outcome: GlobalDMOpenOutcome) {
        if pendingOpens[id] === request { pendingOpens[id] = nil }
        guard prior != nil, case .opened(let before, let after) = outcome, after.isOpen else { return }
        guard applied == nil || applied == BoxState(before) else { return }
        applied = BoxState(after)
    }

    /// 分頁全部收掉：還沒出列的開框請求全部撤銷；私訊框還是 Browser 自己打開後那樣（使用者沒動過）才改回原本的樣子。
    private func restoreBox() {
        let pending = Array(pendingOpens.values)
        pendingOpens = [:]
        for request in pending { request.cancel() }
        if let prior, let applied,
           BoxState(docked: store.isOpen, floating: store.isFloatingOpen, browsing: store.isBrowsing) == applied {
            store.isOpen = prior.docked
            store.isFloatingOpen = prior.floating
            store.isBrowsing = prior.browsing
        }
        prior = nil
        applied = nil
    }

    /// 新分頁放不放得下（W184 G2 修正，GPT-6 1、2／查證 #3；第三輪 #1、#2）——先算、不動任何分頁；新頁建得起來之後才 commitRoom：
    /// - 總數沒滿＝放得下。
    /// - 滿了＝先收一個「已完成」而且不在最前面的分頁（完成的頁面早就關了，收掉不丟東西）。
    /// - 還是滿：一般分頁＝放不下（一句話）；流程分頁（授權頁、Pod）＝暫時多開；網頁開的新視窗＝多開到 maxTabs＋popupOverflow 為止。
    /// 絕不收使用者開的一般分頁、絕不收還沒完成的流程分頁（不替使用者取消別的流程）、絕不收目前在看的分頁。
    /// 一般分頁另有上限（maxBrowseTabs，openBrowse 先看）。
    private enum Room: Equatable {
        case free
        case evict(UUID)
    }

    /// 一般分頁：不多開。
    private func browseRoom() -> Room? {
        if tabs.count < Self.maxTabs { return .free }
        guard let done = tabs.first(where: { $0.done && $0.id != activeID }) else { return nil }
        return .evict(done.id)
    }

    /// 流程分頁（授權頁、Pod）：永遠有位子——滿了又沒有可收的＝暫時多開（流程很短，用完就收）。
    private func flowRoom() -> Room {
        browseRoom() ?? .free
    }

    /// 網頁自己開的新視窗（Pod 的配對頁、登入視窗）：同流程分頁，但多開到硬上限為止（網頁一直開窗也不會無限長）。
    private func popupRoom() -> Room? {
        if let room = browseRoom() { return room }
        return tabs.count < Self.maxTabs + Self.popupOverflow ? .free : nil
    }

    private func commitRoom(_ room: Room) {
        if case .evict(let id) = room { removeTab(id, restoring: false) }
    }

    /// 頁面關掉、分頁留著（完成、撤下、Pod 收起來）：網址、上一頁／下一頁、載入中、錯誤都清掉。
    private func retire(_ id: UUID, done: Bool, note: String?) {
        pageTasks.removeValue(forKey: id)?.cancel()
        if let page = pages.removeValue(forKey: id) {
            page.detach()
            page.close()
        }
        update(id) {
            $0.done = done
            $0.pageClosed = true
            $0.note = note
            $0.pageURL = nil
            $0.loading = false
            $0.problem = nil
            $0.stacked = 0
            $0.canGoBack = false
            $0.canGoForward = false
        }
    }

    /// 拿掉一個分頁：頁面拿下來並關掉（closing＝false：它自己已經關了）；最前面的換成最後一個；全部沒了＝私訊框回原狀。
    private func removeTab(_ id: UUID, closing: Bool = true, restoring: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        pendingOpens.removeValue(forKey: id)?.cancel()   // W184 AB（GPT-6 複核 新發現 2）：還沒出列的開框請求撤銷
        pageTasks.removeValue(forKey: id)?.cancel()
        if let page = pages.removeValue(forKey: id) {
            page.detach()
            if closing { page.close() } else { page.view.removeFromSuperview() }
        }
        cancelActions[id] = nil
        fallbackActions[id] = nil
        if activeID == id { activeID = tabs.last?.id }
        if tabs.isEmpty {
            isShowingTabList = false
            if restoring { restoreBox() }
        }
        place(focus: true)
    }

    private func update(_ id: UUID, _ change: (inout DMBrowserTabInfo) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        change(&tab)
        if tab != tabs[index] { tabs[index] = tab }
    }

    /// Pod、popup 的上一頁／下一頁（網頁分頁的在狀態回報裡）。
    private func refreshNavigation(_ id: UUID) {
        guard let page = pages[id], let tab = tabs.first(where: { $0.id == id }), tab.kind != .web else { return }
        let back = page.canGoBack, forward = page.canGoForward
        update(id) { $0.canGoBack = back; $0.canGoForward = forward }
    }

    private func startWebPage(_ id: UUID, url: URL) {
        let host = pageHost
        pageTasks[id]?.cancel()
        pageTasks[id] = Task { @MainActor [weak self] in
            do {
                let page = try await host.openPage(url: url) { [weak self] state in self?.webState(id, state) }
                guard let self, let tab = self.tabs.first(where: { $0.id == id }), !tab.pageClosed, !Task.isCancelled else {
                    page.close()   // 開好之前就關了（或頁面已經撤下）：馬上銷毀
                    return
                }
                let wrapped = DMBrowserWebPage(page)
                wrapped.state = GlobalDMWebPageState(loading: tab.loading, error: nil, committedURL: tab.pageURL, stacked: tab.stacked,
                                                     canGoBack: tab.canGoBack, canGoForward: tab.canGoForward)
                self.pages[id] = wrapped
                self.pageTasks[id] = nil
                self.place(focus: id == self.activeID)
            } catch {
                guard let self, !Task.isCancelled, self.tabs.contains(where: { $0.id == id }) else { return }
                self.pageTasks[id] = nil
                self.update(id) { $0.loading = false; $0.problem = "打不開這一頁（\(error)）" }
            }
        }
    }

    private func webState(_ id: UUID, _ state: GlobalDMWebPageState) {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.pageClosed else { return }
        let wasLoading = tab.loading
        (pages[id] as? DMBrowserWebPage)?.state = state
        update(id) {
            $0.loading = state.loading
            $0.problem = state.error.map { "這一頁載入失敗：\($0)" }
            $0.pageURL = state.committedURL   // W183 R8b 審查（GPT-6）：跟著看得到的那一頁（沒有＝尚未確認來源）
            $0.stacked = state.stacked
            $0.canGoBack = state.canGoBack || state.stacked > 0
            $0.canGoForward = state.canGoForward
        }
        if wasLoading, !state.loading, id == activeID { focusActive() }
    }

    /// 起點照用途驗：Cloudflare 授權頁只收 HandsCloudflared.loginURL 驗過的網址；Pod、配對頁、登入視窗不能用網址開（只從 Pod 來）。
    /// W184 G2：一般網頁不走流程的入口（只從 openBrowse，使用者按的）。
    static func validatedStart(_ url: URL, _ purpose: DMBrowserPurpose) -> URL? {
        switch purpose {
        case .cloudflareLogin: return GlobalDMWebSheet.cloudflareAuthorization(url)?.url
        case .chatgptDeveloper, .chatgptPairing, .chatgptLogin: return nil
        case .browse: return nil
        }
    }

    /// 「這台：<名稱>」：這台的設備名稱（設備身分檔；讀不到用系統的電腦名稱）。
    static let deviceName: String = {
        if let name = (try? DeviceIdentityStore.readLocal())?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return Host.current().localizedName ?? "這台 Mac"
    }()
}

extension DMBrowser.BoxState {
    /// W184 AB（GPT-6 複核 新發現 3）：開框請求完成時回報的樣子。
    init(_ presence: GlobalDMBoxPresence) {
        self.init(docked: presence.docked, floating: presence.floating, browsing: presence.browsing)
    }
}
