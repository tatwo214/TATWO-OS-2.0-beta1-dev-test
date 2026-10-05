import AppKit
import TatwoCEFBridge

// W183 R5b：私訊框裡的「網頁頁面」（Cloudflare 授權；手機 App 的內嵌瀏覽器）正式的頁面宿主＝這台 OS 瀏覽器的 CEF。
// W183 R8b：頁面放在私訊框第三顆圓鈕 Browser 的分頁裡（DM/DMBrowser.swift）；建法與保護不變。
// - 用這台 OS 瀏覽器同一個 human 設定檔（BrowserWorkSpaceRuntime.shared：使用者已經在 OS 瀏覽器登入 Cloudflare）：
//   跟 Browser 後端（TatwoCEFTabHostView.openSensitivePage）要一個共用 context 的頁面；後端還沒啟動就走後端同一套啟動
//   （引擎檢查 → authorize → mount → 這個 host 的租約與 runtime），不另開設定檔、不自己搶設定檔租約、不用 WKWebView。
// - actor 一律 .human；頁面不在分頁清單（BrowserTabRegistry）、不進 BrowserAgentBridge／WebMCP（AI 與 Computer Use 的瀏覽器工具
//   只在 TatwoCEFContainerView 裡找頁面，這張不在任何容器裡）、不記瀏覽紀錄、不進 tabs.json 與最近關閉。
// - 收回就 close()：馬上從畫面拿掉、要求 CEF 關掉（不留在停泊視窗）；CEF 真的關完才還設定檔租約。
// W183 R5b 審查（GPT-6）：
// - 敏感頁（browser.sensitivePage）：只准 https；頁內開的所有新視窗一律不開原生視窗，疊在同一張頁面上（GlobalDMCEFPageStack，
//   保住 opener）；頂列的網域照最上面那一頁實際載入的網址。
// - 敏感頁開著時，Computer Use 不准以 TATWO 自己為目標（BrowserSensitivePageGate；截圖、讀 AX、每個輸入、回傳結果前都再看一次）。

/// 私訊框網頁頁面打不開的原因（畫面上的白話）。
enum BrowserSensitivePageError: Error, Equatable, CustomStringConvertible {
    /// 這個建置沒有 Chromium（或不是正式的 App）。
    case engineUnavailable
    /// 瀏覽器的資料目錄現在不能用。
    case unavailable
    /// 還有分頁在啟動或在關：稍後再試（呼叫端自己重試一陣子）。
    case busy
    /// 設定檔被擋（例如資料目錄正在整理）：Browser 後端給的白話原因。
    case blocked(String)

    var description: String {
        switch self {
        case .engineUnavailable: "這個版本沒有內建的瀏覽器核心"
        case .unavailable: "瀏覽器的資料目錄現在不能用"
        case .busy: "瀏覽器還在啟動或關分頁，等一下再試"
        case .blocked(let message): message
        }
    }
}

/// W183 R5b 審查（GPT-6）：敏感頁開著嗎（私訊框 Browser 的分頁、OS 瀏覽器的敏感分頁）。開著時 Computer Use 不准以 TATWO 自己為目標。
@MainActor
enum BrowserSensitivePageGate {
    // W183 R8b：私訊框的授權頁改成 Browser 的分頁（DMBrowser）；分頁留著的整段時間都算（不是只有在畫面上的時候）。
    private final class WeakBrowser { weak var value: DMBrowser?; init(_ value: DMBrowser) { self.value = value } }
    private static var browsers: [WeakBrowser] = []

    static func register(_ browser: DMBrowser) {
        browsers.removeAll { $0.value == nil }
        if !browsers.contains(where: { $0.value === browser }) { browsers.append(WeakBrowser(browser)) }
    }

    /// 私訊框 Browser 有敏感分頁（授權頁、配對頁、還沒完成的 Pod 分頁）、或 OS 瀏覽器有敏感分頁（退路開的授權頁；BrowserTabRegistry 記著）。
    static var isActive: Bool {
        browsers.contains { $0.value?.isSensitive == true } || !BrowserTabRegistry.withSensitiveTabs.isEmpty
            || HandsConnectPresenter.anySensitive   // W183 R6b（審查）：連線卡片在畫面上的整段時間、配對頁視窗還開著
    }

    /// 敏感頁出現：以 TATWO 自己為目標的 Computer Use 馬上撤銷（進行中的輸入在下一個事件前就被擋）。
    static func pageAppeared() {
        ComputerUseController.shared.revokeSelfTargetForSensitivePage()
    }
}

/// W183 R5b 審查（GPT-6）：私訊框的一張 CEF 頁面＝一疊：最底下是授權頁，頁內開的新視窗（帶尺寸、about:blank 都算）疊在上面，
/// 保住 opener（OAuth 照常），不開原生視窗。新視窗自己 window.close() 就拿掉；最上面那一層可以按「返回」收掉。
@MainActor
final class GlobalDMCEFPageStack: NSView {
    private(set) var pages: [TatwoCEFBrowserView] = []
    private var states: [ObjectIdentifier: GlobalDMWebPageState] = [:]
    var onChange: (@MainActor (GlobalDMWebPageState) -> Void)?

    var root: TatwoCEFBrowserView? { pages.first }

    /// 最底下那一頁（Browser 後端建的授權頁）：頁內新視窗放進這一疊。
    func adoptRoot(_ browser: TatwoCEFBrowserView) {
        pages = [browser]
        contain(browser)
        browser.frame = bounds
        browser.autoresizingMask = [.width, .height]
        addSubview(browser)
    }

    /// 最底下那一頁的狀態（Browser 後端轉過來）。
    func rootState(committed: String?, loading: Bool, error: String?) {
        guard let root else { return }
        record(root, committed: committed, loading: loading, error: error)
    }

    /// 頁內開的新視窗（TatwoCEFBridge 在 CEF 建立它之前同步叫）：人用的回呼、不用 BrowserPopupFeatures（它會換掉視窗的 contentView）。
    func push(_ popup: TatwoCEFBrowserView) {
        guard popup.sensitivePage, popup.browserActor == .human, !popup.agentControlled else { popup.closeBrowser(); return }
        BrowserHumanInteraction.shared.configure(popup, onForegroundTab: { [weak popup] url in
            popup?.loadURLString(url.absoluteString)
        }) { [weak popup] url in
            popup?.loadURLString(url.absoluteString)
        }
        popup.onPopupCreated = nil
        contain(popup)
        popup.stateHandler = { [weak self, weak popup] committed, _, _, _, isLoading, phase, _, _, _, visibleError in
            guard let self, let popup else { return }
            self.record(popup, committed: committed, loading: isLoading || phase == .creating, error: visibleError)
        }
        popup.addCloseObserver { [weak self, weak popup] in
            guard let self, let popup else { return }
            self.remove(popup)
        }
        popup.frame = bounds
        popup.autoresizingMask = [.width, .height]
        addSubview(popup)
        pages.append(popup)
        publish()
    }

    /// 「返回」：收掉最上面那一層（真的關完才從這一疊拿掉）。
    func popTop() {
        guard pages.count > 1, let top = pages.last else { return }
        top.isHidden = true
        top.closeBrowser()
    }

    private func contain(_ browser: TatwoCEFBrowserView) {
        browser.onContainedPopup = { [weak self] popup in self?.push(popup) }
    }

    private func remove(_ browser: TatwoCEFBrowserView) {
        guard let index = pages.firstIndex(where: { $0 === browser }), index > 0 else { return }
        pages.remove(at: index)
        states[ObjectIdentifier(browser)] = nil
        browser.stateHandler = nil
        TatwoCEFContainerTeardownContract.detachFromHostWindow(browser)
        publish()
    }

    private func record(_ browser: TatwoCEFBrowserView, committed: String?, loading: Bool, error: String?) {
        var state = states[ObjectIdentifier(browser)] ?? GlobalDMWebPageState()
        state.loading = loading
        state.error = error
        // W183 R8b 審查（GPT-6）：提交了別的東西（空白頁、錯誤頁、別的協定）＝這一頁的來源不再是舊網址（nil＝尚未確認來源）；還沒提交＝不動。
        if let committed, !committed.isEmpty { state.committedURL = GlobalDMWebPageState.committed(committed) }
        states[ObjectIdentifier(browser)] = state
        publish()
    }

    /// 給網址 pill 的是最上面那一頁：網域、載入中、錯誤都看最上面那一頁。W183 R8b 審查（GPT-6）：它還沒載入 http／https＝尚未確認來源
    /// （不拿底下那一頁的網址頂替）。
    /// W183 R8b：上一頁／下一頁看最上面那一頁的瀏覽紀錄（疊了新視窗＝上一頁也能收掉那一層）。
    private func publish() {
        guard let top = pages.last else { return }
        var state = states[ObjectIdentifier(top)] ?? GlobalDMWebPageState()
        state.stacked = max(pages.count - 1, 0)
        state.canGoBack = top.canGoBack
        state.canGoForward = top.canGoForward
        onChange?(state)
    }

    /// W183 R8b：上一頁＝最上面那一頁退一頁；它沒有上一頁而且是頁內開的新視窗＝收掉那一層。
    func goBack() {
        guard let top = pages.last else { return }
        if top.canGoBack { top.goBack() } else { popTop() }
    }

    func goForward() {
        pages.last?.goForward()
    }

    /// W184 G2d（GPT-6 審查 G2d #1）：重新載入最上面那一頁（原生 reload：同一個瀏覽器、瀏覽紀錄都在）。
    func reload() {
        pages.last?.reload()
    }
}

/// 一張 CEF 頁面：從 Browser 後端拿的 human 頁面（一疊，見 GlobalDMCEFPageStack）；收回＝交回後端關掉。
@MainActor
final class GlobalDMCEFWebPage: GlobalDMWebPage {
    /// 拿著 host：頁面還開著時 host（與它的設定檔租約）不會被放掉。
    let host: TatwoCEFTabHostView
    let stack: GlobalDMCEFPageStack
    let browser: TatwoCEFBrowserView
    private var closed = false
    /// 自測看：CEF 真的關完了（後端的關閉回呼）。
    private(set) var closeCompleted = false

    init(host: TatwoCEFTabHostView, stack: GlobalDMCEFPageStack, browser: TatwoCEFBrowserView) {
        self.host = host
        self.stack = stack
        self.browser = browser
    }

    var view: NSView { stack }
    var isHumanActor: Bool { stack.pages.allSatisfy { $0.browserActor == .human && !$0.agentControlled && $0.sensitivePage } }

    func back() { stack.popTop() }
    func goBack() { stack.goBack() }   // W183 R8b
    func goForward() { stack.goForward() }
    func reload() { stack.reload() }   // W184 G2d（GPT-6 審查 G2d #1）

    func close() {
        guard !closed else { return }
        closed = true
        stack.onChange = nil
        TatwoCEFContainerTeardownContract.detachFromHostWindow(stack)
        host.closeSensitivePage(browser) { [weak self] in self?.closeCompleted = true }
    }
}

/// 正式的頁面宿主：這台 OS 瀏覽器的 human 設定檔（BrowserWorkSpaceRuntime.shared）。
@MainActor
final class GlobalDMCEFWebPageHost: GlobalDMWebPageHosting {
    private let runtime: @MainActor () -> BrowserWorkSpaceRuntime
    /// 分頁還在啟動或在關（.busy）時最多等多久。
    static let busyWait: TimeInterval = 15

    init(runtime: (@MainActor () -> BrowserWorkSpaceRuntime)? = nil) {
        self.runtime = runtime ?? { BrowserWorkSpaceRuntime.shared }
    }

    func openPage(url: URL, onState: @escaping @MainActor (GlobalDMWebPageState) -> Void) async throws -> any GlobalDMWebPage {
        guard EmbeddedBrowserEnginePolicy.current == .chromiumCEF else { throw BrowserSensitivePageError.engineUnavailable }
        let runtime = self.runtime()
        await runtime.authorize()   // 跟 Browser 分頁同一套：先確認這個設定檔可以用
        guard EmbeddedBrowserRuntimeMountPolicy.allowsMount(state: runtime.access, profileKey: runtime.runtimeProfile.registryKey) else {
            if case let .blocked(_, failure) = runtime.access { throw BrowserSensitivePageError.blocked(failure.visibleMessage) }
            throw BrowserSensitivePageError.unavailable
        }
        let host = runtime.mount()
        let stack = GlobalDMCEFPageStack(frame: NSRect(x: 0, y: 0, width: 466, height: 600))
        stack.onChange = onState
        let deadline = Date().addingTimeInterval(Self.busyWait)
        while true {
            try Task.checkCancellation()
            do {
                let browser = try host.openSensitivePage(url: url, configure: { [weak stack] in stack?.adoptRoot($0) }) { [weak stack] committed, loading, error in
                    stack?.rootState(committed: committed, loading: loading, error: error)
                }
                return GlobalDMCEFWebPage(host: host, stack: stack, browser: browser)
            } catch BrowserSensitivePageError.busy where Date() < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
