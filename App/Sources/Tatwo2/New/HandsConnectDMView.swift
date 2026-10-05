import AppKit
import Combine
import SwiftUI

// W183 R6b：私訊框裡「讓 ChatGPT 連上 TATWO」的原生卡片（one-switch.md「［連線］卡最少要顯示」；使用者 09-28「私訊鈕的UI邏輯 一率當成手機做搭建」）。
// - 卡片是原生畫面，不是聊天訊息：底下的輸入列拿掉（字不會進草稿、Enter 不會送出）、不發通知、不寫診斷。
// - 配對碼只在這張卡、只在這台（擁有者；主機核對過 Pod 看到的配對頁才給）。碼在畫面上時：Computer Use 不准以 TATWO 為目標
//   （BrowserSensitivePageGate）、這個視窗不給螢幕擷取（WindowCaptureShield，碼收起來就還原）。
// W183 R6b 審查（GPT-6、Claude）：
// - Computer Use 的敏感範圍＝卡片在畫面上的整段時間（［連線］確認卡、登入、開發者模式與警語、配對、確認），加上這次連線開的配對頁視窗還開著：
//   Computer Use 不准以 TATWO 為目標（BrowserSensitivePageGate）；不是只有「碼在畫面上」的時候。
// W183 R7a（09-28 實測：副設備沒有地方改等級與專案）：［連線］卡上直接選——等級分段選（L0／L1／L2，下面一行白話說能做什麼、不能做什麼），
//   專案照主機給的清單勾（名稱＋資料夾最後一段，預設沿用主機目前的設定），記憶照現有規則只顯示。按［連線］時選的就是這次的範圍快照。
//   玻璃 chip、原生卡片，不是聊天；主機是舊版（不收卡上選的範圍）就照舊只顯示。
// W183 R7a 審查：主機允許、但暫時用不了的專案灰著列出、預設勾著（寫「資料夾暫時不見」）；主機允許、但不能當專案的，卡上明講按［連線］會拿掉；
//   專案多（超過 8 個）有「找專案」欄；清單寫「共 N 個、勾了 K 個」（清單是完整的，沒有截斷）。
// W183 R10（使用者 09-29「就要給他用了還要多一個勾選」；裁決：按［連線］＝同意，「I understand」與 8 碼由 TATWO 代做）：
//   卡上選範圍那一層（等級分段、專案、記憶下一層、「先到 ChatGPT build 勾」的提示）整個拿掉：範圍＝ChatGPT build 的中央設定＋這台全部專案，
//   卡片只顯示；［連線］旁一行小字講明按連線＝同意、TATWO 會替你勾。按了之後卡片只剩進度與結果（勾選、配對碼卡只剩退路）。
// W183 R8b（chatgpt-build.md「私訊框 › Browser」；使用者 09-28 晚「私訊鈕授權在上方tatwoos跟chatgpt圓鈕新增一欄bowser…授權一率從那邊就不會遺失」）：
// - 按了［連線］之後自動切到 Browser 的「ChatGPT Dev」分頁（Pod 的畫面用 claim／release 放進分頁），之後的卡片浮在那個分頁的頁上。
// - Pod 開出的配對頁 popup 不再是擺到私訊框位置的原生視窗：頁面收進 Browser 的「TATWO 配對」分頁（DMBrowserPopupPage），原生視窗不出現。
// - 分頁不會自己消失：連線完成＝分頁標「完成」（使用者自己關）；流程結束（取消、關開關）＝還沒完成的連線分頁收掉。
//   配對頁 popup 照 R6b 一律在流程結束時關（ChatGPTConnectorPod.closePopups），它的分頁跟著拿掉。
// W183 R8b 審查（GPT-6、Claude）：
// - 配對碼只在綁住的那一頁（Pod 主框架或那個 popup）正是 Browser 現在看得到的那一頁時顯示（showsSurface）；換分頁、開分頁清單、
//   框收起來＝當下遮起來，流程下一次核對時才再給碼。
// - 不給擷取用 WindowCaptureShield（以視窗計數，跟 Browser 的敏感分頁共用同一個視窗也不會互相放開）。
// - 這一步不用看 Pod（setPodVisible(false)）＝Pod 從分頁拿下來（分頁留著一句話）；只有流程要使用者看 Pod 的時候才放進分頁。
// - 配對頁的分頁被使用者關掉、私訊鈕總開關關掉＝取消這次連線（不是只把頁面收掉）。
// W184 D（使用者 09-29：「私訊鈕的ui完全垃圾 應該要參照手機app的規格去設計」「duo的形式已經ok就照你的設計去做」；對照稿 Outer-Connect、
// Outer-Browser-Ack、Outer-Browser-Code；內容與白話照 R9，只換成手機樣子）：
// - ［連線］確認＝底部 sheet：後面 0.22 黑遮罩、從下滑出到離頂 96、上圓角 40／下圓角 52、頂端 grabber（往下拉＝取消）；
//   頂列「取消｜連上 ChatGPT｜連線」（舊的底部第二顆「取消」拿掉）；帳號、主機、網址、授權後回到一組；「ChatGPT 能做到哪」L0／L1／L2 分段＋一行白話；
//   專案、記憶一組，按進下一層（專案照 R9 的清單與說法勾選、找專案；記憶只看）。
// - 按了［連線］之後的卡片浮在 Browser 的頁上（左右 12；離底 30、操作列出來時 84）：配對碼卡（「配對碼・只在這台」＋右上取消、34 等寬大字、
//   「照著打進上面的頁面・剩 m:ss」、交易編號一行）、「輪到你勾選」卡（取消｜繼續）、其他狀態一句話＋一顆鈕。
// - 取消在哪一邊（規則，寫進報告）：有主要動作時，取消在主要動作的前面（左）——sheet 頂列「取消｜…｜連線」、勾選卡「取消｜繼續」；
//   卡片只有取消（或已連線的完成）一顆時，放在卡片頂列的右上（iOS 關閉鈕的位置）。
// - 截圖（D5，安全變更）：卡片在畫面上的整段時間不再擋截圖；只有配對碼正在畫面上（codeOnScreen）卡片所在的視窗才不給擷取。
//   Computer Use 閘門照舊看卡片在不在（anySensitive，不放寬）；授權頁在畫面上由 DMBrowser 自己持有（兩個持有者照舊以視窗計數）。

/// 私訊框卡片的呈現（正式）。
@MainActor
final class HandsConnectPresenter: ObservableObject, HandsConnectPresenting {
    static let shared = HandsConnectPresenter()

    let store: GlobalDMStore
    /// W183 R8b：Pod 與配對頁的分頁開在這裡。
    let browser: DMBrowser
    /// W184 AB（GPT-6 複核 新發現 1–3）：叫私訊框出來＝交出一個開框請求（正式＝過桌面控制器的關口：倒放先立起、轉換中整個請求排隊）。
    private let openRequest: @MainActor (GlobalDMOpenRequest) -> Void
    private let hookPod: @MainActor (DMBrowser) -> Void
    private let podURL: @MainActor () -> URL?
    private let cancelFlow: @MainActor () -> Void
    private let currentCard: @MainActor () -> HandsConnectCard?
    /// W183 R12（主導 1）：任務版面——連線要開網頁時私訊框換成內橫（兩頁），左頁放授權卡、右頁整頁網頁；結束還原。
    let taskLayout: GlobalDMTaskLayout
    @Published private(set) var isShown = false
    @Published private(set) var podVisible = false
    @Published private(set) var codeVisible = false
    private var prior: (docked: Bool, floating: Bool)?
    private var applied: (docked: Bool, floating: Bool)?
    private var podHooked = false
    private var enabledWatch: AnyCancellable?
    /// W184 AB（GPT-6 複核 新發現 2、3）：還沒出列的開框請求（收卡片＝撤銷）。
    private var pendingOpen: GlobalDMOpenRequest?
    /// W184 D：最後報到的那一張卡片（sheet 或浮卡）：新的先報到、舊的後離開也不會把視窗清掉。
    private var lastProbe: ObjectIdentifier?

    /// 除了 store、openBox／openRequest 以外都只給自測換（正式＝私訊框的 Browser、ChatGPT 的 Pod、HandsConnectFlow.shared）。
    /// openBox＝舊的同步假開框（叫完就算開好）；openRequest＝照正式那樣收整個請求（可以先排著、之後出列）。
    init(store: GlobalDMStore? = nil, openBox: (@MainActor () -> Void)? = nil,
         openRequest: (@MainActor (GlobalDMOpenRequest) -> Void)? = nil, browser: DMBrowser? = nil,
         hookPod: (@MainActor (DMBrowser) -> Void)? = nil, podURL: (@MainActor () -> URL?)? = nil,
         cancelFlow: (@MainActor () -> Void)? = nil, card: (@MainActor () -> HandsConnectCard?)? = nil,
         taskLayout: GlobalDMTaskLayout? = nil) {
        let store = store ?? .shared
        self.store = store
        // W183 R12：正式的私訊框＝正式的任務版面；自測自己建的框（沒給）＝形態固定、不換的那一份（不動到這台的形態設定）。
        self.taskLayout = taskLayout ?? (store === GlobalDMStore.shared ? .shared : .inert())
        if let openRequest {
            self.openRequest = openRequest
        } else if let openBox {
            self.openRequest = { request in request.run(store: store, requiresBox: false, open: openBox) }
        } else {
            self.openRequest = { GlobalDMPanelController.shared.open($0) }
        }
        self.browser = browser ?? .shared
        self.hookPod = hookPod ?? { HandsConnectPresenter.hookLivePod($0, cancel: { HandsConnectFlow.shared.dismiss() }) }
        self.podURL = podURL ?? { ChatGPTConnectorPod.shared.mainURL }
        self.cancelFlow = cancelFlow ?? { HandsConnectFlow.shared.dismiss() }
        self.currentCard = card ?? { HandsConnectFlow.shared.card }
        // W183 R8b 審查（GPT-6）：私訊鈕總開關關掉＝取消這次連線（卡片在畫面上時；不只是把頁面收掉）。
        enabledWatch = self.store.$isEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    guard !enabled, let self, self.isShown else { return }
                    self.cancelFlow()
                }
            }
        // W184 D：Browser 的頁面換了位置（換分頁、分頁總覽、框收起來或換視窗）＝重看配對碼還在不在畫面上。
        self.browser.watchPlacement(self) { [weak self] in self?.refreshCodeShield() }
        // W183 R12：連線的左頁（任務版面掛上時，兩頁的左頁畫這個；畫面用框裡的那一份流程與呈現層）。
        self.taskLayout.register(.connect) { services in
            AnyView(HandsConnectTaskPage(flow: services.flow ?? .shared, presenter: services.connect ?? .shared))
        }
    }

    var isAvailable: Bool { store.isEnabled }

    /// 現在的卡片（正式＝HandsConnectFlow.shared.card；自測換）。
    var card: HandsConnectCard? { currentCard() }

    func show() {
        guard store.isEnabled else { return }
        store.isPickerOpen = false
        store.isEditingDirectKeys = false
        if !isShown {
            prior = (store.isOpen, store.isFloatingOpen)
            isShown = true
            Self.shown.removeAll { $0.value == nil || $0.value === self }
            Self.shown.append(WeakPresenter(self))
            // 連線過程的卡片一出來：以 TATWO 自己為目標的 Computer Use 馬上撤銷（這一條不放寬）。W183 R11：只剩結果的卡片（已連線、已斷線）不算。
            if inProcess { BrowserSensitivePageGate.pageAppeared() }
            refreshCodeShield()   // W184 D：截圖只在配對碼在畫面上時擋（卡片出來本身不擋）
        } else if inProcess {
            BrowserSensitivePageGate.pageAppeared()   // W183 R11：從「已連線／已斷線」換回過程卡、再叫一次：照樣馬上撤銷
        }
        taskLayout.begin(.connect, on: store)   // W183 R12：掛上連線任務（形態是兩頁＝左頁就放卡）
        requestBox()
        if floatsInBrowser {
            if inProcess { taskLayout.want(.connect) }   // W183 R12：連線中要看網頁＝換成內橫（左頁卡、右頁網頁）；只剩結果的卡不換
            browser.revealConnectTab()   // W183 R8b：卡片浮在 Browser 的連線分頁上：切過去
        }
        store.coveredBySheet = covers(store)   // W184 G3 第三輪：sheet 蓋住私訊框＝ChatGPT 那一欄不在畫面上（即時語音停）
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        taskLayout.end(.connect)   // W183 R12：左頁還給私訊、形態回到開始之前（使用者中途自己換過＝不動）
        store.coveredBySheet = false   // W184 G3 第三輪
        Self.shown.removeAll { $0.value == nil || $0.value === self }
        podVisible = false
        setCodeVisible(false)
        unprotectWindow()
        // W183 R8b：流程結束（取消、關開關、成功後收卡片）＝還沒完成的連線分頁收掉；完成的留著（分頁不會自己消失，使用者自己關）。
        browser.close(purpose: .chatgptPairing, keepingDone: true)
        browser.close(purpose: .chatgptDeveloper, keepingDone: true)
        browser.close(purpose: .chatgptLogin)   // W183 R8b 審查：受保護呈現時開的登入視窗跟著收
        pendingOpen?.cancel()   // W184 AB（GPT-6 複核 新發現 2）：還沒出列的開框請求撤銷（收卡片之後不再開框）
        pendingOpen = nil
        if let prior, let applied, store.isOpen == applied.docked, store.isFloatingOpen == applied.floating {
            store.isOpen = prior.docked
            store.isFloatingOpen = prior.floating
        }
        prior = nil
        applied = nil
    }

    /// W184 AB（GPT-6 複核 新發現 1–3）：叫私訊框出來＝一個開框請求：倒放、轉換中整個排隊；收卡片＝撤銷；出列前再看卡片還在不在；
    /// 框真的開好之後才收掉對象清單、直達鍵頁。已經有一個在排＝不再排（出列時就會打開）。
    private func requestBox() {
        if let pendingOpen, !pendingOpen.isFinished { return }
        let request = GlobalDMOpenRequest(valid: { [weak self] in self?.isShown == true },
                                          then: { [weak self] in
                                              self?.store.isPickerOpen = false
                                              self?.store.isEditingDirectKeys = false
                                          })
        pendingOpen = request
        request.whenFinished { [weak self] outcome in self?.openFinished(request, outcome) }
        openRequest(request)
    }

    /// W184 AB（GPT-6 複核 新發現 3）：這一次開框請求的完成回呼——框真的開著才記「打開後的樣子」（不用「任一框已開」推定；
    /// 排隊之後停靠框換成浮動框，記的就是浮動框，收卡片照樣改回原本的停靠框）。使用者在上一次打開之後自己動過框＝不改記。
    private func openFinished(_ request: GlobalDMOpenRequest, _ outcome: GlobalDMOpenOutcome) {
        if pendingOpen === request { pendingOpen = nil }
        guard isShown, case .opened(let before, let after) = outcome, after.isOpen else { return }
        if let applied, applied.docked != before.docked || applied.floating != before.floating { return }
        applied = (after.docked, after.floating)
    }

    /// W183 R8b：Pod 的畫面＝Browser 的「ChatGPT Dev」分頁（私訊框自動打開、切到 Browser、它在最前面）。
    /// 不顯示＝分頁留著（分頁不會自己消失；授權完成之後卡片照樣浮在它上面）；W183 R8b 審查：Pod 本身從分頁拿下來（分頁寫一句話）。
    /// 使用者在還沒完成時關掉它＝取消這次連線。
    func setPodVisible(_ visible: Bool) {
        podVisible = visible
        guard visible else { return browser.suspendPod() }   // W183 R8b 審查（Claude）：這一步不用看 Pod＝從分頁拿下來（分頁留著）
        if isShown { taskLayout.want(.connect) }   // W183 R12：要看 ChatGPT 的網頁了＝換成內橫
        if !podHooked {
            podHooked = true
            hookPod(browser)
        }
        browser.openPod(purpose: .chatgptDeveloper, currentURL: podURL(), onCancel: cancelFlow)   // W184 G2 第三輪：流程分頁永遠有位子
    }

    /// W184 G2 修正：正式的「分頁太多、這次連線的新視窗沒開」＝連線流程作廢這一次、卡片回一句「先關掉幾個分頁，再按一次連線」
    /// （沒有在連線＝流程不動，Browser 自己說那一句）。排到下一輪才做：這一步是 Pod 開 popup 的回呼裡發生的，不在那一步的中間重入流程。
    static func invalidateBrowserFull() {
        Task { @MainActor in HandsConnectFlow.shared.invalidate("browser_full") }
    }

    /// W183 R8b：Pod 另開的配對頁已經收進 Browser 的分頁（ChatGPTConnectorPod.onSensitivePopup）；這裡把它叫到前面。
    func placePopup(key: Int) {
        if isShown { taskLayout.want(.connect) }   // W183 R12：配對頁（網頁）要出來了＝兩頁
        browser.focusPopup(key: key)
    }

    /// W183 R8b：連線完成＝連線的分頁標「完成」（不關）。
    func markDone() {
        browser.markDone(purpose: .chatgptDeveloper)
        browser.markDone(purpose: .chatgptPairing)
        // W183 R12（主導 1：「流程結束（連上、取消、失敗後使用者關掉卡片）：左頁還給私訊，形態回到開始前的樣子」）：連上了＝任務結束。
        // 「已連線」卡照舊留著（私訊框上的「已連線」小膠囊按了就拿出來，有［斷線］）。
        taskLayout.end(.connect)
    }

    /// 正式：Pod 的原生回報也給 Browser 一份（網址 pill、上一頁）；連線中開的配對頁 popup、受保護呈現時開的登入視窗收進 Browser 的分頁。
    /// W183 R8b 審查（GPT-6）：配對頁的分頁被使用者關掉＝取消這次連線（cancel）；登入視窗（例如用 Google 登入）只關那個視窗。
    /// W184 G2 修正（GPT-6 2；第三輪）：網頁開的新視窗到了硬上限＝這一頁不開、Browser 上一句話；在連線中另外作廢這次、卡片說一句（full），
    /// 不替使用者取消別的流程。
    static func hookLivePod(_ browser: DMBrowser, cancel: @escaping @MainActor () -> Void, full: (@MainActor () -> Void)? = nil) {
        let connector = ChatGPTConnectorPod.shared
        let full = full ?? { HandsConnectPresenter.invalidateBrowserFull() }
        connector.onDisplayFrame = { [weak browser] frame in browser?.podFrame(frame) }
        connector.onSensitivePopup = { [weak browser] popup, key, pairing in
            browser?.adoptPopup(DMBrowserPopupPage(popup: popup), key: key, purpose: pairing ? .chatgptPairing : .chatgptLogin,
                                expectedHost: pairing ? HandsConnectFlow.shared.offerShown?.publicHost : nil, onCancel: pairing ? cancel : nil,
                                onFull: full)
        }
    }

    /// W183 R8b 審查（GPT-6）：這個 Pod 畫面（主框架＝-1、popup＝編號）是不是 Browser 現在看得到的那一頁（配對碼只在這時顯示）。
    func showsSurface(_ surface: Int) -> Bool { browser.showsSurface(surface) }

    /// W183 R12（主導 1）：私訊框看得到、連線的網頁（Pod 或它開的頁）正放在畫面上。收起私訊框、換到別的分頁＝不算（流程不倒數、不取消）。
    var webOnScreen: Bool { store.isShowingBox && browser.shownSurface != nil }

    /// 這張卡片可以把配對碼顯示出來嗎（碼綁住的那一頁正在畫面上）。
    func revealsCode(_ card: HandsConnectCard) -> Bool {
        guard case .pairing(let view) = card else { return false }
        return showsSurface(view.surface)
    }

    /// 在畫面上的卡片（敏感頁閘門讀這個，不用為了檢查去建私訊框）。
    private final class WeakPresenter {
        weak var value: HandsConnectPresenter?
        init(_ value: HandsConnectPresenter) { self.value = value }
    }
    private static var shown: [WeakPresenter] = []

    /// 連線過程的卡片在畫面上、或這次連線開的配對頁視窗還開著：敏感（Computer Use 不准以 TATWO 為目標）。
    /// W183 R8a 審查（GPT-6）：ChatGPT build 的安全設定卡在畫面上也算（HandsBuildScreenGate）。W184 D：不跟著截圖放寬。
    /// W183 R11（主導 D：「流程走完、閘門解除後，已連線／已斷線的狀態要一眼看得出來…以便 Computer Use 在閘門外驗證」）：只剩結果的卡片
    ///（已連線、已斷線：沒有碼、沒有同意、沒有授權頁）不算過程——以前「已連線」2.5 秒就收，現在留著給你按［斷線］，不因為它一直擋著。
    /// 確認卡、登入、警語、配對、確認中、出錯可以再連（再連＝重新開始，等於同意那一下）照舊算。
    static var anySensitive: Bool {
        shown.contains { $0.value?.inProcess == true } || ChatGPTConnectorPod.sensitivePopupCount > 0 || HandsBuildScreenGate.isShown
    }

    /// W183 R11：這張卡片在連線的過程裡（不是只剩結果）。
    var inProcess: Bool { isShown && Self.inProcess(currentCard()) }

    /// W183 R11：哪些卡片算過程（還沒出卡片＝讀取中，算）。
    nonisolated static func inProcess(_ card: HandsConnectCard?) -> Bool {
        switch card {
        case .connected?, .disconnected?, .unconfirmed?: return false   // W183 R11 第二輪：狀態未確認也只是結果（沒有碼、沒有同意）
        default: return true
        }
    }

    func setCodeVisible(_ visible: Bool) {
        if visible != codeVisible {
            codeVisible = visible
            if visible { BrowserSensitivePageGate.pageAppeared() }   // 碼出來時再撤銷一次（卡片出來時已撤銷過）
        }
        refreshCodeShield()
    }

    /// 卡片所在的視窗（HandsConnectWindowProbe 回報）：配對碼在畫面上時這個視窗不給擷取。
    weak var cardWindow: NSWindow? {
        didSet { refreshCodeShield() }
    }

    /// W184 D：卡片（sheet 或浮卡）報到自己在哪個視窗；離開時只有最後報到的那一張才把視窗清掉。
    func cardProbe(_ probe: ObjectIdentifier, window: NSWindow?) {
        if let window {
            lastProbe = probe
            if cardWindow !== window { cardWindow = window }
        } else if lastProbe == probe {
            lastProbe = nil
            cardWindow = nil
        }
    }

    /// W184 D：配對碼正在畫面上＝卡片出來了、流程給了碼、碼綁住的那一頁正是 Browser 現在看得到的那一頁（卡片照同一條把碼畫出來）。
    /// 碼遮起來（換分頁、開分頁總覽、框收起來、流程收回碼）＝不算。
    var codeOnScreen: Bool {
        guard isShown, codeVisible, case .pairing(let view)? = currentCard(), view.pairingCode != nil else { return false }
        return showsSurface(view.surface)
    }

    /// W184 D：只有配對碼在畫面上時，卡片所在的視窗不給擷取（WindowCaptureShield 以視窗計數：跟 Browser 的授權頁保護同一個視窗時，
    /// 最後一個放手才還原）；碼遮起來、卡片收起來＝放手。
    private func refreshCodeShield() {
        WindowCaptureShield.shared.hold(self, window: codeOnScreen ? cardWindow : nil)
    }

    private func unprotectWindow() {
        WindowCaptureShield.shared.release(self)
    }

    /// 自測看：卡片保護的視窗。
    var captureProtectedWindow: NSWindow? { WindowCaptureShield.shared.window(heldBy: self) }

    /// W183 R8b：按了［連線］之後的卡片浮在 Browser 的連線分頁上（確認卡、讀取中照舊蓋在私訊框上）。沒有連線分頁＝退回蓋在私訊框上。
    var floatsInBrowser: Bool {
        guard isShown, let card = currentCard() else { return false }
        switch card {
        case .loading, .confirm: return false
        default: return browser.hasConnectTab
        }
    }

    /// W183 R12（主導 1）：卡片在兩頁的左頁（連線任務掛著、形態是內橫）：右頁整頁是網頁，沒有卡片蓋在上面；不出底部 sheet。
    var onLeftPage: Bool { isShown && currentCard() != nil && taskLayout.leftPageTask(for: store) == .connect }

    /// 底部 sheet（確認卡、讀取中；不是兩頁的時候）。
    var showsSheet: Bool { isShown && currentCard() != nil && !floatsInBrowser && !onLeftPage }

    /// 卡片跟著 Browser 的連線分頁（不是兩頁的時候：單欄、內直）——W183 R12：擺在網頁下面，網頁讓出那一段（不蓋網頁）。
    var cardWithBrowser: Bool { floatsInBrowser && !onLeftPage }

    /// 這個私訊框現在被卡片蓋著（底下的輸入列拿掉）。浮在 Browser 上的時候不算（框裡是 Browser，沒有輸入列）。
    /// W183 R12：左頁蓋著私訊也算（ChatGPT 那一欄不在畫面上）。
    func covers(_ box: GlobalDMStore) -> Bool { isShown && box === store && (!floatsInBrowser || onLeftPage) }
}

/// 蓋在私訊框上的那一層（GlobalDMWebSheetOverlay 裡一起掛；框的外觀不動）：確認卡、讀取中（R6b）；卡片浮在 Browser 上的時候不蓋。
/// W184 D：底部 sheet——後面 0.22 黑遮罩（點了不關）、sheet 從下滑出到離頂 96。
struct HandsConnectDMLayer: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject private var presenter = HandsConnectPresenter.shared
    @ObservedObject private var flow = HandsConnectFlow.shared
    @ObservedObject private var browser = DMBrowser.shared   // W183 R8b：連線分頁在不在（決定卡片蓋在框上還是浮在 Browser 上）
    /// W183 R11（主導 A、D）：ChatGPT 對象上方的「連線」入口／「已連線」小膠囊。
    @ObservedObject private var entry = HandsConnectEntry.shared
    /// W183 R12：左頁有沒有掛（形態變了、任務掛上＝重算 sheet 要不要出）。
    @ObservedObject private var tasks = GlobalDMTaskLayout.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            // W183 R11：對象是 ChatGPT、對話那一欄看得到、沒有別的東西浮在上面（卡片、抽屜、模型面板、＋ 小卡、對象清單）＝頂列下面置中一顆小膠囊。
            // 內橫：只在左邊的 ChatGPT 那一欄置中（右欄是 Browser）。
            // 不出來＝整層不在（別的畫面、自測的點擊與版面都不受影響）；出來時只有膠囊本身接點擊（空白處照樣點到底下的對話）。
            if let text = entry.noticeText, HandsConnectEntryPill.shows(store: store, cardShown: presenter.isShown && flow.card != nil) {
                GeometryReader { proxy in
                    let column = store.browsesBeside ? (proxy.size.width * DMPhone.duoLeadingFraction).rounded() : proxy.size.width
                    HandsConnectEntryPill(text: text, help: entry.state.help, dismiss: { entry.dismissNotice() }, action: { entry.tap() })
                        .frame(width: column)
                        .padding(.top, DMPhone.headerHeight + HandsConnectEntryPill.gap)
                }
                .transition(.opacity)
            }
            if presenter.showsSheet, presenter.store === store, let card = flow.card {
                Color.black.opacity(GlobalDMWebSheetLayout.dimOpacity)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                    .transition(.opacity)
                HandsConnectSheet(card: card, flow: flow, presenter: presenter)
                    .padding(.top, GlobalDMWebSheetLayout.topInset)
                    // W184 D（GPT-6 審查 #1）：sheet 上畫著配對碼時退場不播動畫（碼本身的保護見 DMSecretCode）。
                    .transition(presenter.revealsCode(card) && card.carriesCode ? .identity : .move(edge: .bottom))
            }
        }
        .animation(GlobalDMWebSheetLayout.slide, value: presenter.showsSheet)
    }
}

// MARK: - W184 D：卡片畫出來要的資料與按鈕（正式接流程；自測畫面證據用假的）

/// 卡片畫出來要看的（正式＝HandsConnectFlow 與呈現層；自測畫面證據＝假的）。
struct HandsConnectCardContext {
    var phase: HandsConnectionPhase = .idle
    var cancelling = false
    /// 主機、服務網址（按［連線］之後每一步的那一行）。
    var offer: HandsConnectOffer?
    var problem: String?
    /// 碼綁住的那一頁正在 Browser 的畫面上（不是就遮起來，即使流程給了碼）。
    var revealsCode = false
    /// W183 R11：進度點走到第幾格（HandsConnectFlow.progressStep）、下面那一句（只在要你做一件事時才有）、正在斷線。
    var step = 0
    var hint: String?
    var disconnecting = false
    /// W183 R11（GPT-6 R11 審查 2）：這一次連線用的 ChatGPT 帳號（進度點下面一行小字；沒登入按下、登入之後自動接著連的＝登入的那一個）。
    var account: String?
    /// W183 R12（主導 1）：網頁在卡片的哪一邊（兩頁＝右邊；單欄＝上面）：卡上「在上面的頁面…」照這個說。
    var webOnRight = false
    /// 找不到舊外掛時，重試代表使用者已確認不存在；按鈕不能仍只寫「再連一次」。
    var retryWillRebuild = false
    var cleanupPreview: HandsConnectorCleanup.Preview?
    var cleaningConnectors = false
    var retryTitle: String { retryWillRebuild ? "確認不存在，重建" : "再連一次" }

    /// 流程給的一句（寫著「上面」的）照網頁實際的位置說。
    func sided(_ text: String) -> String {
        guard webOnRight else { return text }
        return text.replacingOccurrences(of: "上面的頁面", with: "右邊的頁面")
            .replacingOccurrences(of: "在上面", with: "在右邊")
            .replacingOccurrences(of: "點一下亮起來的", with: "點一下右邊亮起來的")   // W183 R12（主導 2）：指路的那一句
            .replacingOccurrences(of: "上面的頁面上", with: "右邊的頁面上")   // W183 R12：「點一下上面的頁面上的「Connect」」
    }

    @MainActor
    static func live(_ flow: HandsConnectFlow, revealsCode: Bool, webOnRight: Bool = false) -> HandsConnectCardContext {
        HandsConnectCardContext(phase: flow.phase, cancelling: flow.cancelling, offer: flow.offerShown,
                                problem: flow.problem, revealsCode: revealsCode,
                                step: flow.progressStep, hint: flow.progressHint, disconnecting: flow.disconnecting,
                                account: flow.attemptAccount, webOnRight: webOnRight, retryWillRebuild: flow.retryWillRebuild, cleanupPreview: flow.cleanupPreview, cleaningConnectors: flow.cleaningConnectors)
    }

    /// W183 R11：畫進度點（連線的中間步驟）；讀取中、取消中、斷線中照舊一句話＋轉圈。
    var showsDots: Bool {
        !cancelling && !disconnecting && [.creatingConnector, .waitingPairing, .verifying].contains(phase)
    }
}

/// 卡片上的按鈕做什麼（正式＝HandsConnectFlow；自測畫面證據＝什麼都不做）。
struct HandsConnectCardActions {
    var dismiss: @MainActor () -> Void = {}
    var connect: @MainActor () -> Void = {}
    var continueAfterUser: @MainActor () -> Void = {}
    var retry: @MainActor (_ manual: Bool) -> Void = { _ in }
    /// W183 R11：已連線卡的［斷線］、已斷線卡的［連線］。
    var disconnect: @MainActor () -> Void = {}
    var reconnect: @MainActor () -> Void = {}
    /// W183 R12（主導 3）：說明改了的卡上的［同意並繼續］。
    var approveConsent: @MainActor () -> Void = {}
    var prepareCleanup: @MainActor () -> Void = {}
    var confirmCleanup: @MainActor () -> Void = {}
    var cancelCleanup: @MainActor () -> Void = {}
    var copyPairingCode: @MainActor (HandsConnectPairingView) -> Bool = { _ in false }

    /// 正式：只有卡片上的按鈕叫得到這些。W183 R10：卡上不再選等級、專案（範圍照 ChatGPT build 的中央設定）。
    @MainActor
    static func live(_ flow: HandsConnectFlow) -> HandsConnectCardActions {
        HandsConnectCardActions(dismiss: { flow.dismiss() }, connect: { flow.connect() }, continueAfterUser: { flow.continueAfterUser() },
                                retry: { flow.retry(manual: $0) }, disconnect: { flow.disconnect() }, reconnect: { flow.reconnect() },
                                approveConsent: { flow.approveConsent() },
                                prepareCleanup: { flow.prepareConnectorCleanup() }, confirmCleanup: { flow.confirmConnectorCleanup() },
                                cancelCleanup: { flow.cancelConnectorCleanup() },
                                copyPairingCode: { flow.copyPairingCode($0) })
    }
}

/// 卡片在手機上是哪一種（純資料，好測）：確認、配對碼、輪到你（勾選、開發者模式、登入）、手動步驟、其他一句話＋一顆鈕。
/// W183 R11（使用者 09-30「ui要簡單好懂而不是砸文字做解釋」）：連線中＝進度點（不寫過程）；已連線＝「已連線：Codex、記憶」＋［斷線］；
/// 已斷線＝一句＋［連線］；輪到你的退路卡都只留一句短話（原本的整句留在流程裡：紀錄、無障礙、滑過的提示）。
struct HandsConnectCardFace: Equatable {
    enum Kind: Equatable { case confirm, code, turn, manual, status, connected, disconnected, consent }
    enum Mark: Equatable { case none, progress, done, warning }
    enum Action: String, Equatable { case continueAfterUser = "continue", manual, retry, disconnect, reconnect, approveConsent }

    var kind: Kind
    var title: String
    var line = ""
    var mark: Mark = .none
    var actions: [Action] = []
    /// 取消那一顆的字（已連線、已斷線＝完成）。
    var dismissTitle = "取消"
    /// W183 R11：整句（流程給的；短句換掉它的時候留在這裡給滑過的提示、無障礙）。
    var detail = ""

    static let connectTitle = "連上 ChatGPT"
    static let codeTitle = "配對碼・只在這台"
    static let turnTitle = "輪到你"
    /// 對照稿 Outer-Browser-Ack：R9 的風險勾選（「I understand and want to continue」那一格）。W183 R10：TATWO 代勾；這張卡只剩退路
    ///（那一格不在畫面上、TATWO 點了沒勾到），Create 照舊由 TATWO 開好配對窗口後再按。
    static let ackTitle = "輪到你：勾選「I understand」"
    static let ackLine = "TATWO 這次沒辦法替你勾：勾完按繼續（Create 由 TATWO 按）。"
    static let tickMissedLine = "TATWO 沒勾到：自己勾完按繼續（Create 由 TATWO 按）。"
    /// W183 R11：其他退路卡的短句（一句話；整句在 detail）。
    static let changedLine = "ChatGPT 的說明改了，TATWO 不代勾：看完自己勾，再按繼續。"
    static let unknownBoxLine = "表單多了沒見過的勾選框，TATWO 不代勾：看完自己勾，再按繼續。"
    static let untrustedLine = "那一格要你這一次自己勾：取消再勾一次，再按繼續。"
    static let warningLine = "有一段 TATWO 不代按的說明：看完、有勾選框就自己勾，再按繼續。"
    static let loginLine = "在上面登入 ChatGPT，登入好自動接著連。"
    static let developerLine = "在上面打開 ChatGPT 的開發者模式，開好自動接著連。"
    static let manualTitle = "手動連線（網址已複製）"
    /// W183 R11：手動模式只留一句；步驟收在「步驟」裡（按了才展開）。
    static let manualLine = "照亮的地方做：新增 → 建立 MCP 應用程式 → 貼網址 → OAuth → 勾選 → Create"
    static let connectedTitle = "已連線"
    static let disconnectedTitle = "已斷線"
    /// W183 R11 第二輪（GPT-6 R11b 審查 4）。
    static let unconfirmedTitle = "連線狀態未確認"
    /// W183 R12（主導 3）：ChatGPT 的說明改了——卡片上就讀得到全文、按［同意並繼續］（不用去小網頁裡找勾選框）。
    static let consentTitle = "ChatGPT 的說明改了"
    static let consentLine = "讀完下面這段，同意就按「同意並繼續」：TATWO 替你勾，這一版以後不再問。"
    static let consentAction = "同意並繼續"

    /// W183 R11：流程給的整句 → 卡片上的短句（沒列到的照原句）。
    @MainActor
    static func shortLine(_ text: String) -> String {
        switch text {
        case HandsConnectFlow.riskAckCardText: ackLine
        case HandsConnectFlow.tickMissedCardText: tickMissedLine
        case HandsConnectFlow.warningChangedCardText: changedLine
        case HandsConnectFlow.checkboxUnknownCardText: unknownBoxLine
        case HandsConnectFlow.untrustedTickCardText: untrustedLine
        case HandsConnectFlow.loginCardText: loginLine
        case HandsConnectFlow.developerModeCardText: developerLine
        default: text.hasPrefix("ChatGPT 有一段 TATWO 不代按的警語或勾選") ? warningLine : text
        }
    }

    @MainActor
    static func make(_ card: HandsConnectCard, phase: HandsConnectionPhase) -> HandsConnectCardFace {
        let finished: Bool = {
            switch card {
            case .connected, .disconnected, .unconfirmed: return true
            default: return phase == .connected
            }
        }()
        let dismiss = finished ? "完成" : "取消"
        switch card {
        case .loading(let text):
            return HandsConnectCardFace(kind: .status, title: connectTitle, line: text, mark: .progress, dismissTitle: dismiss, detail: text)
        case .confirm:
            return HandsConnectCardFace(kind: .confirm, title: connectTitle, dismissTitle: dismiss)
        case .working(let text), .verifying(let text):
            return HandsConnectCardFace(kind: .status, title: connectTitle, line: text, mark: .progress, dismissTitle: dismiss, detail: text)
        case .waitingUser(let text, let continuable):
            // W183 R10：代勾的退路（那一格不在畫面上／沒勾到）＝輪到你勾那一格；W183 R11：其他退路也只留一句短話。
            let ack = text == HandsConnectFlow.riskAckCardText || text == HandsConnectFlow.tickMissedCardText
            return HandsConnectCardFace(kind: .turn, title: ack ? ackTitle : turnTitle, line: shortLine(text),
                                        actions: continuable ? [.continueAfterUser] : [], dismissTitle: dismiss, detail: text)
        case .manual:
            return HandsConnectCardFace(kind: .manual, title: manualTitle, line: manualLine, dismissTitle: dismiss)
        case .pairing:
            return HandsConnectCardFace(kind: .code, title: codeTitle, dismissTitle: dismiss)
        case .connected(let text):
            // W183 R11：「已連線：Codex、記憶」＋［斷線］（完成＝收起來）。
            return HandsConnectCardFace(kind: .connected, title: connectedTitle, line: text, mark: .done, actions: [.disconnect],
                                        dismissTitle: dismiss, detail: text)
        case .disconnected(let text):
            // W183 R11：斷好了＝一句＋［連線］（重接走同一張確認卡）。
            return HandsConnectCardFace(kind: .disconnected, title: disconnectedTitle, line: text, actions: [.reconnect],
                                        dismissTitle: dismiss, detail: text)
        case .unconfirmed(let text):
            // W183 R11 第二輪（GPT-6 R11b 審查 4）：不說已連線、不寫能力（一句＋警示）；［斷線］留著。
            return HandsConnectCardFace(kind: .status, title: unconfirmedTitle, line: text, mark: .warning, actions: [.disconnect],
                                        dismissTitle: dismiss, detail: text)
        case .needsManual(let text):
            return HandsConnectCardFace(kind: .status, title: connectTitle, line: text, mark: .warning, actions: [.manual, .retry], dismissTitle: dismiss)
        case .consent:
            // W183 R12（主導 3）：全文＋［同意並繼續］（玻璃 chip）；取消在它前面。
            return HandsConnectCardFace(kind: .consent, title: consentTitle, line: consentLine, actions: [.approveConsent], dismissTitle: dismiss,
                                        detail: consentLine)
        case .refused(let text), .failed(let text):
            return HandsConnectCardFace(kind: .status, title: connectTitle, line: text, mark: .warning, actions: [.retry], dismissTitle: dismiss)
        }
    }
}

// MARK: - 確認卡：底部 sheet

/// 確認卡（蓋在私訊框上，手機的底部 sheet）：頂端 grabber（往下拉＝取消）、頂列「取消｜連上 ChatGPT｜連線」＋內容。
struct HandsConnectSheet: View {
    let card: HandsConnectCard
    @ObservedObject var flow: HandsConnectFlow
    @ObservedObject var presenter: HandsConnectPresenter
    @ObservedObject private var build = HandsBuildController.shared
    @ObservedObject private var entry = HandsConnectEntry.shared

    private var availability: String? {
        if let text = build.localAvailabilityText { return text }
        if case .partial = entry.state { return entry.state.word }
        return nil
    }

    var body: some View {
        HandsConnectSheetView(card: card, context: .live(flow, revealsCode: presenter.revealsCode(card)), actions: .live(flow),
                              availabilityText: availability)
            .background(HandsConnectWindowProbe(presenter: presenter))
    }
}

/// sheet 本身（純畫面：卡片、它要看的、按鈕做什麼都由外面給）。W183 R10：只有一層（專案、記憶那兩層拿掉）。
struct HandsConnectSheetView: View {
    let card: HandsConnectCard
    let context: HandsConnectCardContext
    let actions: HandsConnectCardActions
    var availabilityText: String?
    @State private var pull: CGFloat = 0

    init(card: HandsConnectCard, context: HandsConnectCardContext, actions: HandsConnectCardActions, availabilityText: String? = nil) {
        self.card = card
        self.context = context
        self.actions = actions
        self.availabilityText = availabilityText
    }

    var body: some View {
        let face = HandsConnectCardFace.make(card, phase: context.phase)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                grabber
                header(face)
            }
            .contentShape(Rectangle())
            .gesture(pullToDismiss)
            ScrollView {
                if let availabilityText {
                    Text(availabilityText).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, GlobalDMWebSheetLayout.contentSide)
                        .accessibilityLabel(availabilityText)
                }
                content(face)
                    .padding(.top, GlobalDMWebSheetLayout.contentTop)
                    .padding(.horizontal, GlobalDMWebSheetLayout.contentSide)
                    .padding(.bottom, GlobalDMWebSheetLayout.contentBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(GlobalDMWebSheetLayout.shape)
        .liquidGlassPanelSurface(cornerRadius: GlobalDMWebSheetLayout.topRadius)
        .offset(y: pull)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.handsConnect")
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.primary.opacity(0.22))
            .frame(width: GlobalDMWebSheetLayout.grabberSize.width, height: GlobalDMWebSheetLayout.grabberSize.height)
            .padding(.top, GlobalDMWebSheetLayout.grabberTop)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func header(_ face: HandsConnectCardFace) -> some View {
        ZStack {
            Text(face.title)
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                if face.kind != .connected { leading(face) }
                Spacer(minLength: 8)
                trailing
            }
        }
        .padding(.top, GlobalDMWebSheetLayout.headerTop)
        .padding(.horizontal, GlobalDMWebSheetLayout.contentSide)
        .padding(.bottom, GlobalDMWebSheetLayout.headerBottom)
    }

    /// 左上：取消（有主要動作時取消一律在它前面）。
    private func leading(_ face: HandsConnectCardFace) -> some View {
        DMPhoneCapsuleButton(title: face.dismissTitle) { actions.dismiss() }
            .disabled(context.cancelling)
            .help(context.phase == .connected ? "收起來" : "這次先不連")
            .accessibilityIdentifier("tatwo.dm.handsConnect.cancel")
    }

    /// 右上：確認卡＝「連線」（強調色膠囊）；進行中＝轉圈；其他＝空著（兩邊一樣寬，標題置中）。
    @ViewBuilder
    private var trailing: some View {
        switch card {
        case .confirm:
            DMPhoneCapsuleButton(title: "連線", prominent: true) { actions.connect() }
                .help(HandsConnectFlow.consentLine)   // W183 R10：按連線＝同意（卡片頂上也寫一行）
                .accessibilityIdentifier("tatwo.dm.handsConnect.connect")
        case .loading, .working, .verifying:
            ProgressView()
                .controlSize(.small)
                .frame(width: DMPhone.touch, height: DMPhone.touch)
                .accessibilityLabel("進行中")
        default:
            Color.clear
                .frame(width: DMPhone.touch, height: DMPhone.touch)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func content(_ face: HandsConnectCardFace) -> some View {
        switch card {
        case .confirm(let offer, let account):
            HandsConnectConfirmContent(offer: offer, account: account, problem: context.problem)
        default:
            HandsConnectCardBody(card: card, face: face, context: context, actions: actions, inSheet: true)
        }
    }

    /// 往下拉（grabber、頂列那一帶）超過一段＝取消（同 iOS 的 sheet）；不夠就彈回去。
    private var pullToDismiss: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in pull = max(0, value.translation.height) }
            .onEnded { value in
                let dismiss = value.translation.height > GlobalDMWebSheetLayout.pullToDismiss && !context.cancelling
                withAnimation(GlobalDMWebSheetLayout.slide) { pull = 0 }
                if dismiss { actions.dismiss() }
            }
    }
}

/// 確認卡的內容。W183 R11（使用者 09-30「關鍵是 ui要簡單好懂而不是砸文字做解釋」；主導：「用圖示加一行字，不放大段說明」）：
/// - 一條路：ChatGPT（Pod 目前帳號）→ 這台（主機名稱）；兩個圖示＋名字。
/// - 能做什麼＝圖示 chip（L2：Codex、記憶；L1：記憶、提案；L0：只看），一行白話；等級的整段說明只在滑過的提示與無障礙。
/// - ［連線］旁那一行小字（按連線＝同意，W183 R10 裁決）照舊；網址、全部專案、授權後回到哪收成一行小字（T15：帳號、主機、網址、等級、專案、
///   callback 網域照樣都在卡上；文案不宣稱驗證了帳號）；交易類只能看、還沒登入、出錯各一行。
/// W183 R10：範圍＝ChatGPT build 的中央設定＋這台全部專案（卡上不選）；交易實盤類專案另外寫「只能看」。
/// W183 R12（使用者 09-30 裁決：拿掉等級選擇；主導：確認卡也不顯示等級膠囊，直接寫能力）：圖示 chip 拿掉，只剩一行能力
///（HandsConnectAbility.line：L2＝「連上後：看全部專案・可用 Codex・記憶只讀＋收件匣」）；滑過的提示與無障礙也不寫 L0／L1／L2。
struct HandsConnectConfirmContent: View {
    let offer: HandsConnectOffer
    let account: String?
    let problem: String?

    /// 專案那一列的字：全部可見＝「這台全部（N 個）」；舊版主機（照它自己的清單）＝名字。
    static func projectsText(_ offer: HandsConnectOffer) -> String {
        if offer.scope.allProjects { return "這台全部（\(offer.scope.projects.count) 個）" }
        return offer.scope.projects.isEmpty ? "沒有" : offer.scope.projects.map(\.name).joined(separator: "、")
    }

    /// W183 R10 底線 B：交易實盤類的專案（ChatGPT 只能看）。
    static func tradingNote(_ offer: HandsConnectOffer) -> String? {
        let count = offer.scope.readOnlyProjectIDs.count
        return count > 0 ? "其中 \(count) 個交易類專案只能看；金鑰、憑證類檔案一律讀不到" : nil   // W183 R12：不寫等級
    }

    /// W183 R11：卡片上那一行（照等級）。W183 R12：直接寫能力（不寫等級；主機名在上面那一條路）。
    static func line(_ offer: HandsConnectOffer) -> String { HandsConnectAbility.line(level: offer.scope.level) }

    /// W183 R11：網址、專案、授權後回到哪——一行小字（T15 的其餘幾項）。
    static func facts(_ offer: HandsConnectOffer) -> String {
        let back = offer.callbackHosts.isEmpty ? "chatgpt.com" : offer.callbackHosts.joined(separator: "、")
        return "\(offer.publicHost)・\(projectsText(offer))・授權後回到 \(back)"
    }

    var body: some View {
        VStack(spacing: GlobalDMWebSheetLayout.contentSpacing) {
            HandsConnectRoute(account: account, host: offer.hostName.isEmpty ? offer.hostDeviceID : offer.hostName)
            VStack(spacing: 10) {
                // W183 R12（主導：確認卡不顯示等級膠囊，直接寫能力）：能力 chip 拿掉，一行白話。
                Text(Self.line(offer))
                    .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            // 能做什麼的整段說明只在滑過的提示與無障礙（不放大段說明）；能力、專案、記憶照舊一組只顯示（沒有按鈕、沒有勾選框）。
            .help(HandsConnectCardBody.levelText(offer.scope.level))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Self.line(offer))；專案：\(Self.projectsText(offer))；記憶：\(HandsConnectCardBody.memorySummary(level: offer.scope.level))")
            .accessibilityHint(HandsConnectCardBody.levelText(offer.scope.level))
            .accessibilityIdentifier("tatwo.dm.handsConnect.scopeSummary")
            VStack(spacing: 6) {
                // W183 R10：［連線］旁一行小字（使用者 09-29 裁決：按［連線］那一下就算同意）。
                Text(HandsConnectFlow.consentLine)
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tatwo.dm.handsConnect.consent")
                Text(Self.facts(offer))
                    .font(.system(size: DMPhone.TextSize.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .help(Self.facts(offer))
                    .accessibilityLabel("服務網址 \(offer.publicHost)；專案 \(Self.projectsText(offer))；授權後回到 \(offer.callbackHosts.isEmpty ? "chatgpt.com" : offer.callbackHosts.joined(separator: "、"))")
                    .accessibilityIdentifier("tatwo.dm.handsConnect.facts")
                if let note = Self.tradingNote(offer) {
                    Label(note, systemImage: "lock.fill")
                        .font(.system(size: DMPhone.TextSize.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("tatwo.dm.handsConnect.readOnly")
                }
                if account == nil {
                    Label("還沒登入 ChatGPT：按連線後在框裡登入一次，登入好自動接著連", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.system(size: DMPhone.TextSize.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("tatwo.dm.handsConnect.needsLogin")
                }
                if let problem {
                    Text(problem)
                        .font(.system(size: DMPhone.TextSize.footnote))
                        .foregroundStyle(LiquidGlassTokens.loopsCaution)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// W183 R11：一條路（ChatGPT → 這台）：兩個圖示＋名字（帳號是 Pod 目前登入的那個，不宣稱驗證過）。
struct HandsConnectRoute: View {
    let account: String?
    let host: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            end(symbol: "bubble.left.and.bubble.right.fill", name: account ?? "還沒登入", label: "Pod 目前帳號")
            Image(systemName: "arrow.right")
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .accessibilityHidden(true)
            end(symbol: "desktopcomputer", name: host, label: "主機")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.handsConnect.route")
    }

    private func end(symbol: String, name: String, label: String) -> some View {
        VStack(spacing: 6) {
            Group {
                if symbol == "bubble.left.and.bubble.right.fill" { ChatGPTLogo(size: 24) }
                else { Image(systemName: symbol).font(.system(size: DMPhone.TextSize.body, weight: .semibold)) }
            }
                .foregroundStyle(.primary)
                .frame(width: DMPhone.touch, height: DMPhone.touch)
                .background { GlobalDMGlassCircle(isSelected: false) }
            Text(name)
                .font(.system(size: DMPhone.TextSize.footnote))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(name)")
    }
}

// W183 R12（使用者 09-30 裁決：拿掉等級選擇；主導：確認卡不顯示等級膠囊，直接寫能力）：能力的圖示 chip（HandsConnectAbilityChips）拿掉，
// 確認卡只寫一行能力（HandsConnectAbility.line）。

/// W183 R11：進度點（連線的中間步驟：準備 → 建外掛 → 配對 → 確認）；走過的實心、現在這一格強調色、還沒到的空心。
struct HandsConnectProgressDots: View {
    let step: Int
    var total = HandsConnectFlow.progressSteps

    static let size: CGFloat = 8
    static let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < step ? AnyShapeStyle(LiquidGlassTokens.brandAccent.opacity(0.55))
                          : index == step ? AnyShapeStyle(LiquidGlassTokens.brandAccent) : AnyShapeStyle(Color.primary.opacity(0.14)))
                    .frame(width: Self.size, height: Self.size)
                    .scaleEffect(index == step ? 1.25 : 1)
            }
        }
        .animation(GlobalDMWebSheetLayout.slide, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("連線中：第 \(min(step + 1, total)) 步，共 \(total) 步")
        .accessibilityIdentifier("tatwo.dm.handsConnect.progress")
    }
}

// MARK: - 按了［連線］之後：浮在 Browser 頁上的卡片

/// W183 R8b／W184 D：按了［連線］之後的卡片，浮在 Browser 的 ChatGPT 分頁（Pod、配對頁）的頁上（對照稿：配對碼卡、輪到你勾選卡）。
struct HandsConnectFloatingCard: View {
    let card: HandsConnectCard
    @ObservedObject var flow: HandsConnectFlow
    @ObservedObject var presenter: HandsConnectPresenter
    /// 碼綁住的那一頁正在畫面上（Browser 算好給；presenter.revealsCode）。
    let revealsCode: Bool
    /// W184 G2 修正：自測換按鈕做什麼（量「按下去真的觸發」；正式＝nil，照流程）。
    @Environment(\.dmConnectCardActions) private var actionsOverride

    var body: some View {
        HandsConnectFloatCardView(card: card, context: .live(flow, revealsCode: revealsCode), actions: actionsOverride ?? .live(flow))
            .background(HandsConnectWindowProbe(presenter: presenter))
    }
}

/// 浮卡本身（純畫面）：內距 16、圓角 28、材質底＋陰影；浮在網頁上，這一塊的點擊給卡片（BrowserChromeHitLayer），不給網頁。
struct HandsConnectFloatCardView: View {
    let card: HandsConnectCard
    let context: HandsConnectCardContext
    let actions: HandsConnectCardActions

    var body: some View {
        HandsConnectCardBody(card: card, face: HandsConnectCardFace.make(card, phase: context.phase), context: context, actions: actions, inSheet: false)
            .padding(DMBrowserPhone.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassPanelSurface(cornerRadius: DMBrowserPhone.cardRadius)
            .background(BrowserChromeHitLayer())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tatwo.dm.handsConnect.float")
    }
}

/// 卡片內容（浮卡與 sheet 共用；inSheet＝在 sheet 裡：取消在 sheet 的頂列，卡片自己不再放一顆）。
struct HandsConnectCardBody: View {
    let card: HandsConnectCard
    let face: HandsConnectCardFace
    let context: HandsConnectCardContext
    let actions: HandsConnectCardActions
    var inSheet = false
    /// W183 R12：在兩頁的左頁（整頁自己捲）：長的內容（說明全文）不再包一層捲動。
    var fillsPage = false
    /// W183 R12：單欄的浮卡裡說明全文那一段最多多高（自己捲）。
    static let consentFloatBody: CGFloat = 120

    var body: some View {
        switch card {
        case .confirm:
            EmptyView()   // 確認卡只在 sheet（HandsConnectConfirmContent）
        case .pairing(let view):
            pairing(view)
        case .manual(let url, let steps):
            manual(url, steps: steps)
        case .consent(let offer):
            consent(offer)
        default:
            switch face.kind {
            case .turn: turn
            case .connected: connected   // W183 R11
            case .disconnected: disconnected   // W183 R11
            default: if face.mark == .progress && context.showsDots { progress } else { status }
            }
        }
    }

    /// W183 R11：手動模式的步驟收起來（按「步驟」才展開）。
    @State private var cleanupToken = UUID()
    @State private var showsSteps = false
    @State private var copiedCode = false

    /// 等級的白話（W183 R10：專案＝這台全部專案；等級照 ChatGPT build 的設定）。W183 R12：只寫能做什麼（不寫等級的名字）。
    static func levelText(_ level: Int) -> String {
        switch level {
        case 0: "只看：可讀這台的專案與狀態；不碰記憶、不寫任何東西"
        case 2: "Codex：能在沙盒工作區改檔、跑測試；不能上網；改完要你核准才合併。記憶：可讀正式記憶（遮敏感），只寫 ChatGPT 收件匣與提案"
        default: "可讀這台的專案、可讀正式記憶；只寫 ChatGPT 收件匣與提案，不直接改專案檔"
        }
    }

    /// 記憶那一列的短字（記憶照規則只顯示）。
    static func memorySummary(level: Int) -> String { level >= 1 ? "讀・遮敏感" : "不碰" }

    /// W184 G2：自測量「取消」「繼續」畫在哪（正式＝false）。
    @Environment(\.dmFrameProbes) private var probes
    /// W184 G2c／R：手動步驟、配對內容最多多高（Browser 照框大小給；小框讓側欄留得下；sheet 裡＝260）。
    @Environment(\.dmCardBodyLimit) private var bodyLimit

    /// 卡片只有取消（或已連線的完成）一顆時：卡片頂列右上的 chip（32 高）。
    private var dismissChip: some View {
        GlobalDMChipButton(title: face.dismissTitle) { actions.dismiss() }
            .disabled(context.cancelling)
            .help(context.phase == .connected ? "收起來（分頁留著，標「完成」）" : "這次先不連")
            .accessibilityIdentifier("tatwo.dm.handsConnect.cancel")
            .background { if probes { DMFrameProbe(key: "card.dismiss") } }
    }

    /// 主機・網址一行（按［連線］之後每一步都寫：多台的時候看得出是哪一台）。
    @ViewBuilder private var hostLine: some View {
        if let offer = context.offer {
            Text("主機 \(offer.hostName.isEmpty ? "（主機）" : offer.hostName)・\(offer.publicHost)")
                .font(.system(size: DMPhone.TextSize.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder private var mark: some View {
        switch face.mark {
        case .progress:
            ProgressView().controlSize(.small).accessibilityLabel("進行中")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .foregroundStyle(LiquidGlassTokens.loopsPositive)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .foregroundStyle(LiquidGlassTokens.loopsCaution)
        case .none:
            EmptyView()
        }
    }

    /// W183 R11（主導：「中間的步驟用進度點表示，不用文字解釋」）：連線中＝一條路的圖示＋進度點＋取消；整句只在滑過的提示與無障礙。
    /// 要你做一件事的時候（等 ChatGPT 空下來、在頁面上點一下）才在點下面寫一句。
    private var progress: some View {
        VStack(alignment: .leading, spacing: DMBrowserPhone.cardSpacing) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("連線中").font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    HandsConnectProgressDots(step: context.step)
                }
                Spacer(minLength: 8)
                if !inSheet { dismissChip }
            }
            // W183 R11（GPT-6 R11 審查 2）：用哪個 ChatGPT 帳號連（登入之後自動接著連的，看得到登入的是哪一個）。
            if let account = context.account {
                Label(account, systemImage: "person.crop.circle")
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("ChatGPT 帳號：\(account)")
                    .accessibilityIdentifier("tatwo.dm.handsConnect.account")
            }
            if let hint = context.hint {
                Text(context.sided(hint))   // W183 R12：兩頁＝「右邊的頁面」
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tatwo.dm.handsConnect.hint")
            }
        }
        .help(face.detail)
        .accessibilityElement(children: .contain)
        .accessibilityHint(face.detail)
        .accessibilityIdentifier("tatwo.dm.handsConnect.working")
    }

    /// W183 R11（主導：「接上後一張小卡寫『已連線：Codex、記憶』，加一顆『斷線』」）：勾＋那一句、能做什麼的圖示；［完成］是主要動作，與［斷線］並排。
    /// 沒斷成＝下面一行原因（［斷線］照樣可以再按）。
    private var connected: some View {
        VStack(alignment: .leading, spacing: DMBrowserPhone.cardSpacing) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.loopsPositive)
                Text(face.line)
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tatwo.dm.handsConnect.connectedLine")
                Spacer(minLength: 8)
            }
            if let problem = context.problem {
                Text(problem)
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .foregroundStyle(LiquidGlassTokens.loopsCaution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if context.cleanupPreview == nil { hostLine }
            // 私訊框不用系統彈窗：刪除前的確認就在卡片上（看完清單才按）。
            if let preview = context.cleanupPreview {
                Text(preview.text)
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tatwo.dm.handsConnect.cleanupPreview")
                HStack(spacing: 10) {
                    DMPhoneCapsuleButton(title: "取消", grow: true) { actions.cancelCleanup() }
                        .accessibilityIdentifier("tatwo.dm.handsConnect.cleanupCancel")
                    DMPhoneCapsuleButton(title: "刪除重複外掛", grow: true) { actions.confirmCleanup() }
                        .accessibilityIdentifier("tatwo.dm.handsConnect.cleanupConfirm")
                }
            } else {
                GlobalDMChipButton(title: "整理重複的 TATWO 外掛") { actions.prepareCleanup() }
                    .disabled(context.cleaningConnectors || context.disconnecting || context.cancelling)
                    .accessibilityIdentifier("tatwo.dm.handsConnect.cleanupDuplicates")
            }
            HStack(spacing: 10) {
                DMPhoneCapsuleButton(title: "斷線", grow: true) { actions.disconnect() }
                    .disabled(context.cleaningConnectors || context.disconnecting || context.cancelling)
                    .help("撤銷這次的授權：ChatGPT 之後再叫就被拒；要用再按連線")
                    .accessibilityIdentifier("tatwo.dm.handsConnect.disconnect")
                DMPhoneCapsuleButton(title: "完成", prominent: true, grow: true) { actions.dismiss() }
                    .disabled(context.cancelling)
                    .help("收起來（分頁留著）")
                    .accessibilityIdentifier("tatwo.dm.handsConnect.cancel")
                    .background { if probes { DMFrameProbe(key: "card.dismiss") } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.handsConnect.connected")
        .onAppear { HandsBuildScreenGate.appeared(cleanupToken) }
        .onDisappear { HandsBuildScreenGate.disappeared(cleanupToken) }
    }

    /// W183 R11：斷好了：一句＋［連線］（重接走同一張確認卡）；右上「完成」＝收起來。
    private var disconnected: some View {
        VStack(alignment: .leading, spacing: DMBrowserPhone.cardSpacing) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(face.line)
                    .font(.system(size: DMPhone.TextSize.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !inSheet { dismissChip }
            }
            HStack {
                Spacer(minLength: 0)
                DMPhoneCapsuleButton(title: "連線", prominent: true) { actions.reconnect() }
                    .accessibilityIdentifier("tatwo.dm.handsConnect.reconnect")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.handsConnect.disconnected")
    }

    /// 一句話＋一顆鈕（needsManual：手動、再連一次兩條路）。
    private var status: some View {
        VStack(alignment: .leading, spacing: DMBrowserPhone.cardSpacing) {
            HStack(alignment: .top, spacing: 10) {
                mark
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.sided(face.line))
                        .font(.system(size: DMPhone.TextSize.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    hostLine
                }
                Spacer(minLength: 8)
                if !inSheet { dismissChip }
            }
            if !face.actions.isEmpty {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    ForEach(face.actions, id: \.self) { action($0) }
                }
            }
        }
    }

    @ViewBuilder
    private func action(_ action: HandsConnectCardFace.Action) -> some View {
        switch action {
        case .manual:
            DMPhoneCapsuleButton(title: "手動") { actions.retry(true) }
                .accessibilityIdentifier("tatwo.dm.handsConnect.manual")
        case .retry:
            DMPhoneCapsuleButton(title: context.retryTitle, prominent: true) { actions.retry(false) }
                .help(context.retryWillRebuild ? "先在 ChatGPT 外掛頁確認舊外掛不存在；若仍存在，請沿用它，不要重建" : "重新檢查連線")
                .accessibilityIdentifier("tatwo.dm.handsConnect.retry")
        case .continueAfterUser:
            DMPhoneCapsuleButton(title: "繼續", prominent: true) { actions.continueAfterUser() }
                .accessibilityIdentifier("tatwo.dm.handsConnect.continue")
        case .disconnect:
            DMPhoneCapsuleButton(title: "斷線") { actions.disconnect() }
                .accessibilityIdentifier("tatwo.dm.handsConnect.disconnect")
        case .reconnect:
            DMPhoneCapsuleButton(title: "連線", prominent: true) { actions.reconnect() }
                .accessibilityIdentifier("tatwo.dm.handsConnect.reconnect")
        case .approveConsent:
            GlobalDMChipButton(title: HandsConnectCardFace.consentAction) { actions.approveConsent() }
                .accessibilityIdentifier("tatwo.dm.handsConnect.approveConsent")
        }
    }

    /// W183 R12（主導 3）：說明改了——讀到的全文（純文字、可捲、可選取）、連結只寫字與網域（不給點）；底下「取消｜同意並繼續」（玻璃 chip，
    /// 不是藍色系統鈕）。外來的字只顯示（Text(verbatim:)：不當成 Markdown、不執行）。
    private func consent(_ offer: HandsConsentOffer) -> some View {
        VStack(alignment: .leading, spacing: DMBrowserPhone.cardSpacing) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                VStack(alignment: .leading, spacing: 2) {
                    if !fillsPage {   // 左頁的頂列已經寫著標題
                        Text(face.title)
                            .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(face.line)
                        .font(.system(size: DMPhone.TextSize.secondary))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            consentText(offer)
            HStack(spacing: 10) {
                if !inSheet {
                    DMPhoneCapsuleButton(title: face.dismissTitle, grow: true) { actions.dismiss() }
                        .disabled(context.cancelling)
                        .accessibilityIdentifier("tatwo.dm.handsConnect.cancel")
                }
                GlobalDMChipButton(title: HandsConnectCardFace.consentAction) { actions.approveConsent() }
                    .disabled(context.cancelling)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("tatwo.dm.handsConnect.approveConsent")
                    .background { if probes { DMFrameProbe(key: "card.approveConsent") } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.handsConnect.consent")
    }

    /// 說明全文＋連結（字・網域）。浮卡、sheet 裡自己捲（有高度上限）；左頁整頁捲（不再包一層）。
    @ViewBuilder
    private func consentText(_ offer: HandsConsentOffer) -> some View {
        let body = VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: offer.text)
                .font(.system(size: DMPhone.TextSize.footnote))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tatwo.dm.handsConnect.consentText")
            ForEach(Array(offer.links.enumerated()), id: \.offset) { _, link in
                Label {
                    Text(verbatim: "\(link.text)・\(URL(string: link.origin)?.host ?? link.origin)")
                } icon: {
                    Image(systemName: "link")
                }
                .font(.system(size: DMPhone.TextSize.caption))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .background { if probes { DMFrameProbe(key: "card.consentBody") } }
        if fillsPage {
            body
        } else {
            // 單欄（網頁在卡片上面）：全文那一段最多 120（自己捲），小框也留得下網頁與按鈕；兩頁的左頁整段顯示。
            ScrollView { body }
                .frame(maxHeight: min(DMBrowserPhone.cardMaxBody, bodyLimit, Self.consentFloatBody))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 輪到你（R9 的風險勾選、開發者模式、登入）：手勢圖示＋一句標題＋一句話；可以繼續＝底下「取消｜繼續」，不能＝右上取消。
    private var turn: some View {
        VStack(alignment: .leading, spacing: DMBrowserPhone.cardSpacing) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised")
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(face.title)
                        .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(context.sided(face.line))
                        .font(.system(size: DMPhone.TextSize.secondary))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    hostLine
                }
                Spacer(minLength: 8)
                if !inSheet, face.actions.isEmpty { dismissChip }
            }
            if face.actions.contains(.continueAfterUser) {
                HStack(spacing: 10) {
                    if !inSheet {
                        DMPhoneCapsuleButton(title: face.dismissTitle, grow: true) { actions.dismiss() }
                            .disabled(context.cancelling)
                            .accessibilityIdentifier("tatwo.dm.handsConnect.cancel")
                            .background { if probes { DMFrameProbe(key: "card.turnCancel") } }   // W184 G2c：自測量左邊的取消不被左列蓋住
                    }
                    DMPhoneCapsuleButton(title: "繼續", prominent: true, grow: true) { actions.continueAfterUser() }
                        .accessibilityIdentifier("tatwo.dm.handsConnect.continue")
                        .background { if probes { DMFrameProbe(key: "card.continue") } }
                }
            }
        }
        .help(face.detail)   // W183 R11：卡上只留短句；整句在滑過的提示
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.handsConnect.ack")
    }

    /// 手動連線：步驟照 R9（ChatGPT 改版後的「新增 ▾ → 建立 MCP 應用程式」）＋等寬網址；長的時候在卡片裡捲。
    private func manual(_ url: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(face.title).font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                Spacer(minLength: 8)
                if !inSheet { dismissChip }
            }
            // W183 R11（主導：「退路卡（TATWO 沒勾到、手動模式）也要短」）：一句路線＋網址；R9 的整段步驟收在「步驟」裡，按了才展開。
            Text(face.line)
                .font(.system(size: DMPhone.TextSize.footnote))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(url)
                    .font(.system(size: DMPhone.TextSize.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                GlobalDMChipButton(title: showsSteps ? "收起" : "步驟") { showsSteps.toggle() }
                    .accessibilityIdentifier("tatwo.dm.handsConnect.manualSteps")
            }
            if showsSteps {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                            .font(.system(size: DMPhone.TextSize.footnote))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(url)
                        .font(.system(size: DMPhone.TextSize.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    hostLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: min(DMBrowserPhone.cardMaxBody, bodyLimit))
            .fixedSize(horizontal: false, vertical: true)
            .background { if probes { DMFrameProbe(key: "card.manualBody") } }
            }
        }
    }

    /// 配對碼卡（對照稿 Outer-Browser-Code）：鎖頭「配對碼・只在這台」＋右上取消；碼 34 等寬、字距 0.16em、置中；
    /// 「照著打進上面的頁面・剩 m:ss」；交易編號（網頁上同一組）、回到哪、還可以錯幾次收進一行 11 的次要字。
    /// 碼只在綁住的那一頁正在畫面上時顯示（revealsCode）；不是就寫切回哪個分頁。
    private func pairing(_ view: HandsConnectPairingView) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let left = max(Int(view.expiresAt.timeIntervalSince(timeline.date)), 0)
            let remaining = "剩 \(left / 60):\(String(format: "%02d", left % 60))"
            VStack(spacing: 8) {   // 頂列與內容的間距對齊 cardChrome 的高度預算。
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: DMPhone.TextSize.footnote, weight: .semibold))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                    Text(face.title).font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                    Spacer(minLength: 8)
                    if !inSheet { dismissChip }
                }
                if fillsPage || inSheet {
                    pairingDetails(view, left: left, remaining: remaining)
                } else {
                    // 複製鈕與完整警語都保留；單欄小框讓內容自己捲，取消固定在外。
                    // 與手動步驟共用高度預算，不把 Browser 的可捲側欄擠成 0。
                    ScrollView {
                        pairingDetails(view, left: left, remaining: remaining)
                    }
                    .frame(maxHeight: min(DMBrowserPhone.cardMaxBody, bodyLimit))
                    .fixedSize(horizontal: false, vertical: true)
                    .background { if probes { DMFrameProbe(key: "card.pairingBody") } }
                }
            }
        }
        .onChange(of: card) { _, _ in copiedCode = false }
        .onChange(of: context.revealsCode) { _, _ in copiedCode = false }
        .task(id: copiedCode) {
            guard copiedCode else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedCode = false
        }
    }

    private func pairingDetails(_ view: HandsConnectPairingView, left: Int, remaining: String) -> some View {
        VStack(spacing: DMBrowserPhone.cardSpacing) {
            if view.autoFillFailed || view.autoFillUnproven {
                // W183 R10：代填沒成（退路）：一句話說明為什麼要自己打。W183 R10 第二輪：來源證明不了（Create 的回覆沒回來）＝不代填，也說一句。
                Text(view.autoFillUnproven ? HandsConnectFlow.autoFillUnprovenLine : HandsConnectFlow.autoFillFailedLine)
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .foregroundStyle(LiquidGlassTokens.loopsCaution)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("tatwo.dm.handsConnect.autoFillFailed")
            }
            if let code = view.spacedCode, context.revealsCode, left > 0 {
                // W184 D（GPT-6 審查 #1）：碼畫在 DMSecretCode 自己的 NSView 上——畫著的每一幀那個視窗都不給擷取，換形態時同步藏起來；
                // 碼與「遮起來」那一句互換不播動畫（不留碼淡出的中間幀）。
                DMSecretCode(text: code)
                    .frame(maxWidth: .infinity)
                    .transaction { $0.animation = nil }
                GlobalDMChipButton(title: copiedCode ? "已複製" : "複製") {
                    copiedCode = actions.copyPairingCode(view)
                }
                .disabled(context.cancelling || view.attemptsLeft <= 0)
                .accessibilityIdentifier("tatwo.dm.handsConnect.copyCode")
                .background { if probes { DMFrameProbe(key: "card.copyCode") } }
                .help("複製八碼，再自行貼上；剪貼簿最多保留 60 秒")
                Text(context.sided("複製後貼到上面的頁面・\(remaining)"))
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // W183 R8b 審查：碼綁住的那一頁不在畫面上（換了分頁、開著分頁總覽、框收起來）：遮起來。
                Text(left == 0 ? "配對碼已過期，請重新連線。" : view.pairingCode != nil
                     ? "配對碼只在「\(view.popup ? DMBrowserPurpose.chatgptPairing.title : DMBrowserPurpose.chatgptDeveloper.title)」分頁在最前面時顯示；切回那個分頁就會出現。"
                     : "等 TATWO 的配對頁對上這一筆…（離開配對頁時碼會先收起來）")
                    .font(.system(size: DMPhone.TextSize.secondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text(remaining)
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // 交易編號＝網頁上顯示的同一組（不一樣就按取消）；回到哪；還可以錯幾次。
            Text("交易 \(view.displayCode)（網頁上要一樣）・回到 \(view.callbackHost)・還可以錯 \(view.attemptsLeft) 次")
                .font(.system(size: DMPhone.TextSize.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
            if view.manual {
                Text("手動模式：TATWO 無法確認這一頁是你剛剛自己建立的連接器打開的；只有你剛在 ChatGPT 按了「建立」才照打。")
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .foregroundStyle(LiquidGlassTokens.loopsCaution)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { if probes { DMFrameProbe(key: "card.pairingWarning") } }
            }
        }
    }
}

// MARK: - W183 R12：兩頁的左頁（任務版面：連線）

/// W183 R12（使用者 09-30「瀏覽器可以自動改成橫式 先暫時蓋過左側的私訊 把授權放去左側 就像dou一樣」；主導 1）：連線的左頁——
/// 私訊框換成內橫時蓋在私訊上：整頁高度、內容自己捲；確認卡、進度（第幾步／共幾步）、說明改了的全文與［同意並繼續］、要你在右邊做的那一句、
/// 失敗與重試都在這裡。右頁整頁是網頁（沒有任何卡片蓋在上面）。配對碼照舊只在綁住的那一頁在畫面上時顯示、畫在不給擷取的那一層。
struct HandsConnectTaskPage: View {
    @ObservedObject var flow: HandsConnectFlow
    @ObservedObject var presenter: HandsConnectPresenter

    var body: some View {
        if let card = presenter.card {   // 正式＝flow.card（呈現層照它）；自測的呈現層換成假的卡
            HandsConnectTaskPageView(card: card, context: .live(flow, revealsCode: presenter.revealsCode(card), webOnRight: true), actions: .live(flow))
                .background(HandsConnectWindowProbe(presenter: presenter))
        }
    }
}

/// 左頁本身（純畫面：卡片、它要看的、按鈕做什麼都由外面給；自測畫面證據用假的）。
struct HandsConnectTaskPageView: View {
    let card: HandsConnectCard
    let context: HandsConnectCardContext
    let actions: HandsConnectCardActions
    @Environment(\.dmFrameProbes) private var probes

    /// 進度那一行（第幾步／共幾步）。
    static func stepText(_ step: Int, total: Int = HandsConnectFlow.progressSteps) -> String {
        "第 \(min(max(step, 0), total - 1) + 1) 步／共 \(total) 步"
    }

    var body: some View {
        let face = HandsConnectCardFace.make(card, phase: context.phase)
        VStack(alignment: .leading, spacing: 0) {
            header(face)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if context.showsDots {
                        Text(Self.stepText(context.step))
                            .font(.system(size: DMPhone.TextSize.footnote, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("tatwo.dm.handsConnect.page.step")
                    }
                    content(face)
                }
                .padding(.horizontal, GlobalDMWebSheetLayout.contentSide)
                .padding(.top, 6)
                .padding(.bottom, GlobalDMWebSheetLayout.contentBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())   // 蓋著私訊那一欄：底下的點不到（私訊本身也已經不接點擊）
        .background { if probes { DMFrameProbe(key: "task.page") } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.handsConnect.page")
    }

    /// 頂列：左＝取消（已連線、已斷線＝完成）；中＝標題；右＝確認卡的［連線］、進行中的轉圈。
    private func header(_ face: HandsConnectCardFace) -> some View {
        ZStack {
            Text(face.title)
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                if face.kind != .connected {
                    DMPhoneCapsuleButton(title: face.dismissTitle) { actions.dismiss() }
                        .disabled(context.cancelling)
                        .help(context.phase == .connected ? "收起來" : "這次先不連")
                        .accessibilityIdentifier("tatwo.dm.handsConnect.cancel")
                }
                Spacer(minLength: 8)
                switch card {
                case .confirm:
                    DMPhoneCapsuleButton(title: "連線", prominent: true) { actions.connect() }
                        .help(HandsConnectFlow.consentLine)
                        .accessibilityIdentifier("tatwo.dm.handsConnect.connect")
                case .loading, .working, .verifying:
                    ProgressView().controlSize(.small).frame(width: DMPhone.touch, height: DMPhone.touch)
                default:
                    Color.clear.frame(width: DMPhone.touch, height: DMPhone.touch).accessibilityHidden(true)
                }
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, GlobalDMWebSheetLayout.contentSide)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func content(_ face: HandsConnectCardFace) -> some View {
        switch card {
        case .confirm(let offer, let account):
            HandsConnectConfirmContent(offer: offer, account: account, problem: context.problem)
        default:
            HandsConnectCardBody(card: card, face: face, context: context, actions: actions, inSheet: true, fillsPage: true)
        }
    }
}

// MARK: - sheet 裡的清單樣子（對照稿：圓角 26 的群組、列高 48／52、0.5 分隔線）

/// 一組列（圓角 26 的玻璃群組）。
struct HandsConnectGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .chatLiquidSection(cornerRadius: GlobalDMWebSheetLayout.groupRadius)
    }
}

/// 群組裡的分隔線（左邊縮 16）。
struct HandsConnectSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: DMPhone.hairline)
            .padding(.leading, GlobalDMWebSheetLayout.contentSide)
            .accessibilityHidden(true)
    }
}

/// 一列（列高 48）：左邊名稱 17、右邊值 17 次要色（網址 15 等寬）。
struct HandsConnectRow: View {
    let title: String
    let value: String
    var monospaced = false
    /// 唸出來的名稱（例如「帳號」唸「Pod 目前帳號」：它是 Pod 現在登入的帳號，不宣稱驗證過）。
    var label: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: DMPhone.TextSize.body))
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(size: DMPhone.TextSize.secondary, design: .monospaced) : .system(size: DMPhone.TextSize.body))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .padding(.horizontal, GlobalDMWebSheetLayout.contentSide)
        .frame(minHeight: GlobalDMWebSheetLayout.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label ?? title)：\(value)")
    }
}

/// 群組下面的一行說明（13 次要色，左右縮 16）。
struct HandsConnectNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: DMPhone.TextSize.footnote))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, GlobalDMWebSheetLayout.contentSide)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 回報卡片所在的視窗（配對碼在畫面上時這個視窗不給擷取）。W184 D：每張卡片各自報到（sheet、浮卡換手時不會把視窗清掉）。
struct HandsConnectWindowProbe: NSViewRepresentable {
    let presenter: HandsConnectPresenter

    final class Probe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        let id = ObjectIdentifier(probe)
        probe.onWindow = { [weak presenter] window in MainActor.assumeIsolated { presenter?.cardProbe(id, window: window) } }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}
}
