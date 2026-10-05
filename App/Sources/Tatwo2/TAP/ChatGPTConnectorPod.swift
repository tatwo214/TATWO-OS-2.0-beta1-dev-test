import AppKit
import Combine
import TatwoCEFBridge

// W183 R6b：ChatGPT 手腳在 ChatGPT Space 的 Pod 裡建連接器（one-switch.md「ChatGPT 連接器（App 自動建）」「自動建連接器的保護」）。
// - 只在使用者在私訊框按了［連線］之後跑（HandsConnectFlow）；在使用者已登入的那個 Pod（ChatGPTTap.shared），不換別的瀏覽器。
// - 獨占 Pod：聊天中不硬換頁（有一則正在送、語音開著就等空檔）；拿著的時候新的送出先排隊、會換頁的指令一律拒絕（ChatGPTTap.beginConnectorHold）。
// - 網頁腳本的指令只在 chatgpt.com 執行（ChatGPTTap.commandScript 的限制照舊）；TATWO 的配對頁不注入任何腳本。
// - 配對頁是 Pod 主框架同頁跳轉、還是另開視窗（CEF popup）：都由原生瀏覽器回報實際載入的網址（不是網頁腳本說的）；
//   popup 的手勢保護不放寬（沒有使用者手勢就被擋：私訊框請使用者在頁面上點一下）。
// W183 R6b 審查（GPT-6、Claude）：
// - 放掉獨占＝先停掉還在跑的連接器指令（connectorAbort）、把 Pod 帶回 chatgpt.com 首頁，回到了才放行排隊的聊天：
//   主框架停在 TATWO 配對頁或外站時（網頁腳本在那裡不執行）用原生方式載回首頁、等新的網頁報到（hello）；等不到就重開 Pod。
// - 拿著獨占時 Pod 開的視窗＝配對頁：設成敏感頁（只准 https、它再開的視窗一律擋）、不給螢幕擷取；流程結束一律關掉（不留在最上層）。
// - 每一頁都帶「從哪裡來」：主框架＝上一個網址；popup＝打開它的那一刻主框架的網址與時間（連線流程拿來分辨是不是對話裡的連結）。
// - 等待（拿獨占、等 Pod 起來）都會在流程取消時馬上停（不在主執行緒空轉）。
// W183 R8b：私訊框 Browser 的分頁跟著顯示 Pod 的原生回報（onDisplayFrame；不取代 onFrame）；拿著獨占時開的配對頁 popup
// 收進 Browser 的分頁（onSensitivePopup；原生視窗先變透明、點不到，頁面搬進分頁後收起來）。沒有接的地方＝照 R6b 留在原生視窗。
// W183 R8b 審查（GPT-6）：Pod 在私訊框 Browser 受保護呈現時（登入、開發者設定、配對、帶回首頁）另開的視窗——例如用 Google 登入——
// 也是敏感頁、也收進 Browser（不再只看「拿著獨占」）；私訊框放掉受保護的呈現要等連接器放掉 Pod、帶回首頁做完（whenSettled）。
// W183 R10（按［連線］＝同意；TATWO 代勾、代填，只限 TATWO 自己開的那一頁）：
// - 代勾（tick）：網頁腳本量出「I understand and want to continue」那一格的位置（.tickable）。W183 R10 第二輪（GPT-6 2）：不走裸座標——
//   先確認還是量的那一份文件（導頁世代）、畫面大小一樣、沒縮放，再用 CEF 的畫面快照找到同一個位置的那一個控制項（剛好一個），
//   走 CEF 的節點驗證點擊（clickElement：送出之前在隔離的 world 裡再核那一點最上面還是它、沒被蓋、位置沒變、同一份文件，才送原生點擊；
//   網頁看到的是 isTrusted，腳本從不改 checked）。任何一步對不上＝不點（交給使用者）。
// - 按 Create／重新連線（W183 R10 第二輪，GPT-6 1）：網頁腳本核對完回 armed（不按）；這裡先把「送出按的這一刻」（主框架的導頁世代、網址、
//   已經開著的 popup）交給流程當來源證據的錨點（onPressDispatch），才送 connectorPress（腳本再核一次才按）。
// - 代填（fillPairingCode）：只在綁住的那一頁——同一個畫面（主框架或那一個 popup）、同一份文件（導頁世代）、網址的授權參數就是綁住的那一組；
//   用 CEF 的畫面快照（DevTools DOMSnapshot，不跑網頁的程式、不讀欄位的值）找「這台主機、POST、剛好一格文字欄＋一顆送出」的表單，
//   原生點欄位、原生按鍵打 8 碼、原生點送出。每一下都綁那一份文件（換頁就送不出去）。碼只在記憶體、不寫任何紀錄。

/// Pod 的原生那一層（正式＝TapWebPod；自測＝假的，看得到「帶回首頁」有沒有照順序做）。
@MainActor
protocol ChatGPTPodSurface: AnyObject {
    var onMainFrame: ((String?, UInt64, Bool, Int) -> Void)? { get set }
    var onPopup: ((TatwoCEFBrowserView) -> Void)? { get set }
    /// 用原生方式讓主框架載入這個網址（不經網頁腳本）。
    func loadMain(_ url: URL)
    /// W183 R8b 審查：私訊框 Browser 正在受保護地呈現 Pod（TapWebPod.beginGuardedPresentation）。
    var isGuardedPresentation: Bool { get }
    /// W183 R10：Pod 主框架的原生瀏覽器畫面（代勾、代填在上面送原生輸入）。自測的假畫面＝nil。
    var nativeView: TatwoCEFBrowserView? { get }
}

extension ChatGPTPodSurface {
    var isGuardedPresentation: Bool { false }
    var nativeView: TatwoCEFBrowserView? { nil }
}

extension TapWebPod: ChatGPTPodSurface {
    func loadMain(_ url: URL) { browser?.loadURLString(url.absoluteString) }
    var nativeView: TatwoCEFBrowserView? { browser }   // W183 R10
}

@MainActor
final class ChatGPTConnectorPod: HandsConnectPodDriving {
    static let shared = ChatGPTConnectorPod(tap: .shared)
    /// 連線流程拿著 Pod 時開的敏感視窗（配對頁）還開著幾個（敏感頁閘門讀：Computer Use 不准以 TATWO 為目標）。
    private(set) static var sensitivePopupCount = 0

    let tap: ChatGPTTap
    private let surface: @MainActor () -> (any ChatGPTPodSurface)?
    var onFrame: ((HandsPodFrame) -> Void)?
    var onLost: ((String) -> Void)?
    /// W183 R10 第二輪：送出「按」之前的錨點（HandsConnectFlow 記下）。
    var onPressDispatch: ((HandsPressAnchor) -> Void)?
    /// W183 R10 第四輪（GPT-6 發現 1）：原生一開窗就通知（key、開的時間、是不是主框架開的）——不等載入完成。
    var onPopupOpened: ((Int, Date, Bool) -> Void)?
    /// W183 R10 第三輪（GPT-6 發現 7）：流程這一次按的操作編號（指令一開始記下、錨點帶著它）。
    var pressOperation: String?
    /// W183 R12（.033 實機：正式版查不到任何紀錄）：每個連接器指令的結果一行；對不上時多一份頁面的結構快照（DOM 文字，不是截圖）。nil＝不寫。
    var connectLog: HandsConnectLog? = .shared
    /// W183 R12：找不到指路那一顆時上一次留快照的時間（一分鐘最多一份）。
    private var lastGestureSnapshot: Date?
    /// W183 R12（.037 實機）：找到的那一顆的字（卡片「點一下右邊亮起來的「…」」用）、上一次 TATWO 自己按 Continue 的時間。
    private var lastGestureLabel = ""
    private var lastContinueClick: Date?
    /// W183 R12（.036 實機）：Create 量不到／點不中＝亮起來請使用者自己按（流程換卡片那一句）。
    var onUserPressNeeded: (() -> Void)?
    /// W183 R8b：每一頁原生回報也給私訊框 Browser 一份（網址 pill、上一頁；popup 關了＝分頁拿掉）。
    var onDisplayFrame: ((HandsPodFrame) -> Void)?
    /// W183 R8b：敏感 popup 交給私訊框 Browser 收進分頁（key＝popup 編號；pairing＝連線流程拿著 Pod 時開的＝配對頁，否則＝登入視窗）。
    var onSensitivePopup: ((TatwoCEFBrowserView, Int, Bool) -> Void)?
    /// W183 R8b 審查：等連接器放掉 Pod、帶回首頁做完的（私訊框 Browser 結束受保護的呈現）。
    private var settleWaiters: [@MainActor () -> Void] = []
    private var hold: UUID?
    private var releasing: Task<Void, Never>?
    private var hookedSurface: ObjectIdentifier?
    private var connectionWatch: AnyCancellable?
    private final class Popup {
        weak var view: TatwoCEFBrowserView?
        let openedAt: Date
        let source: URL?
        let sensitive: Bool
        /// W183 R10 第四輪（GPT-6 發現 1）：開它的是不是 Pod 主框架（CEF 的 frame->IsMain()；子框架、iframe 開的＝false）。
        let openerIsMain: Bool
        /// W183 R8b：CEF 給它開的那個原生視窗（頁面可能已經搬進私訊框的分頁：收視窗只收這一個，不碰私訊框）。
        weak var home: NSWindow?
        init(view: TatwoCEFBrowserView?, openedAt: Date, source: URL?, sensitive: Bool, openerIsMain: Bool) {
            self.view = view; self.openedAt = openedAt; self.source = source; self.sensitive = sensitive; self.openerIsMain = openerIsMain
        }
    }
    private var popups: [Int: Popup] = [:]
    /// 主框架：現在的網址、第幾份（原生的導頁世代）、上一個網址、載入中。
    private(set) var mainURL: URL?
    private var mainGeneration: UInt64 = 0
    private var mainSource: URL?
    private var mainLoading = false
    /// 帶回首頁最多等多久（自測調短）。
    var restoreTimeout: TimeInterval = 20
    /// W183 R9c（GPT-6 C3）：連接器自己的指令正在跑幾個（在跑的時候換頁是指令自己做的，網頁腳本自己看得到；不另外通知）。
    private var commandsInFlight = 0
    /// 上一次原生看到的主框架路徑（percent-encoded，跟網頁的 location.pathname 同一個樣子）。
    private var observedPath: String?

    init(tap: ChatGPTTap, surface: (@MainActor () -> (any ChatGPTPodSurface)?)? = nil) {
        self.tap = tap
        self.surface = surface ?? { tap.pod as (any ChatGPTPodSurface)? }
    }

    /// 接上 Pod 的原生回報（冪等）。
    func attach() {
        guard let surface = surface() else { return }
        let id = ObjectIdentifier(surface)
        guard hookedSurface != id else { return }
        hookedSurface = id
        surface.onMainFrame = { [weak self] url, generation, loading, status in self?.mainFrame(url, generation, loading, status) }
        surface.onPopup = { [weak self] popup in self?.adopt(popup) }
        if connectionWatch == nil {
            connectionWatch = tap.$connection.dropFirst().sink { [weak self] connection in
                switch connection {
                case .off, .sleeping, .failed: self?.onLost?("pod_closed")
                case .needsLogin: self?.onLost?("pod_logged_out")
                default: break
                }
            }
        }
    }

    private func mainFrame(_ raw: String?, _ generation: UInt64, _ loading: Bool, _ status: Int) {
        let url = raw.flatMap { URL(string: $0) }
        if let url, generation != mainGeneration, hold != nil { connectLog?.write("pod", "main page \(Self.logURL(url.absoluteString)) status=\(status)") }   // W183 R12
        if let url, generation != mainGeneration {
            // 新的一份（或同一份裡換了網址）：上一個網址＝從哪裡來。世代變小＝Pod 重開過（新的瀏覽器）：沒有「從哪裡來」。
            mainSource = generation > mainGeneration ? mainURL : nil
            mainURL = url
            mainGeneration = generation
        }
        if let url { noteNavigation(url) }
        mainLoading = loading
        let frame = HandsPodFrame(url: url, generation: generation, loading: loading, httpStatus: status, source: mainSource)
        onFrame?(frame)
        onDisplayFrame?(frame)   // W183 R8b
    }

    /// W183 R9c（GPT-6 C3）：原生看到主框架的路徑換了（含同一份文件裡的 pushState、replaceState）：連接器拿著 Pod、而且沒有自己的指令在跑
    /// （等使用者看警語、勾選的時候）＝告訴網頁腳本那個路徑（跟登記時不一樣的表單紀錄永久作廢；就算之後又回到原來的路徑）。
    private func noteNavigation(_ url: URL) {
        guard let path = Self.observedPath(url), path != observedPath else { return }
        observedPath = path
        guard let hold, commandsInFlight == 0, tap.connection == .ready else { return }
        let tap = self.tap
        Task { @MainActor in _ = try? await tap.connectorRequest("connectorNavigated", ["path": path], hold: hold, timeout: .seconds(3)) }
    }

    /// 主框架網址的路徑（跟網頁 location.pathname 一樣是 percent-encoded；空的＝/）。
    nonisolated static func observedPath(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        let path = components.percentEncodedPath
        return path.isEmpty ? "/" : path
    }

    /// 連接器自己的指令（算進 commandsInFlight）。
    private func request(_ command: String, _ arguments: [String: Any], hold: UUID?, timeout: Duration) async throws -> [String: Any] {
        commandsInFlight += 1
        defer { commandsInFlight -= 1 }
        return try await tap.connectorRequest(command, arguments, hold: hold, timeout: timeout)
    }

    /// Pod 另開的視窗：記下來（弱參照），看它實際載入的網址。原本的 popup 設定（BrowserHumanInteraction）不動，只收得更緊。
    private func adopt(_ popup: TatwoCEFBrowserView) {
        let key = ObjectIdentifier(popup).hashValue
        popups = popups.filter { $0.value.view != nil }
        // 連線流程拿著 Pod 時開的＝配對頁：敏感頁（在 CEF 建立它之前設定：只准 https、它再開的視窗沒有地方接＝一律擋）、不給螢幕擷取。
        // W183 R8b 審查（GPT-6）：Pod 在私訊框 Browser 受保護呈現時開的（登入視窗）一樣。
        let pairing = hold != nil
        let sensitive = pairing || surface()?.isGuardedPresentation == true
        if sensitive {
            popup.sensitivePage = true
            popup.window?.sharingType = .none
            Self.sensitivePopupCount += 1   // 閘門當下就生效；撤銷進行中的 Computer Use 放到 CEF 的回呼之外做
            Task { @MainActor in BrowserSensitivePageGate.pageAppeared() }
        }
        // W183 R10 第四輪（GPT-6 發現 1）：原生一開窗就登記、馬上告訴流程；開它的是不是主框架照 CEF 給的（popup.openedByMainFrame）。
        let entry = registerPopup(key: key, view: popup, sensitive: sensitive, openerIsMain: popup.openedByMainFrame)
        popups[key]?.home = popup.window   // W183 R8b
        connectLog?.write("pod", "popup opened opener_main=\(popup.openedByMainFrame) during_connect=\(pairing)")   // W183 R12（.035 實機）
        let openedAt = entry.openedAt, source = entry.source, openerIsMain = entry.openerIsMain
        popup.stateHandler = { [weak self] committed, generation, _, _, loading, _, status, _, _, _ in
            self?.popupState(key, committed: committed, generation: generation, loading: loading, status: status,
                             source: source, openedAt: openedAt, openerIsMain: openerIsMain)
        }
        popup.addCloseObserver { [weak self] in self?.popupClosed(key) }
        // W183 R8b：收進私訊框 Browser 的分頁。原生視窗先變透明、點不到（CEF 接著會把它叫到前面）；搬進分頁放在 CEF 的回呼之外做。
        if sensitive, onSensitivePopup != nil, let window = popup.window {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            Task { @MainActor [weak self, weak popup] in
                guard let self, let popup, self.popups[key] != nil else { return }
                self.onSensitivePopup?(popup, key, pairing)
            }
        }
    }

    /// W183 R10 第四輪：登記一個剛開的 popup（adopt 與自測共用這一條），並立刻通知流程。
    @discardableResult
    private func registerPopup(key: Int, view: TatwoCEFBrowserView?, sensitive: Bool, openerIsMain: Bool) -> Popup {
        let entry = Popup(view: view, openedAt: Date(), source: mainURL, sensitive: sensitive, openerIsMain: openerIsMain)
        popups[key] = entry
        onPopupOpened?(key, entry.openedAt, openerIsMain)
        return entry
    }

    /// popup 的一次狀態（載入中、載入完成）：帶著開窗那一刻記下的來源、時間與開窗者。
    private func popupState(_ key: Int, committed: String?, generation: UInt64, loading: Bool, status: Int, source: URL?, openedAt: Date?,
                            openerIsMain: Bool) {
        if !loading, let committed { connectLog?.write("pod", "popup page \(Self.logURL(committed)) status=\(status)") }   // W183 R12
        let frame = HandsPodFrame(url: committed.flatMap { URL(string: $0) }, generation: generation, loading: loading, httpStatus: status,
                                  popup: true, popupKey: key, source: source, openedAt: openedAt, openerIsMain: openerIsMain)
        onFrame?(frame)
        onDisplayFrame?(frame)   // W183 R8b
    }

    private func popupClosed(_ key: Int) {
        guard let entry = popups.removeValue(forKey: key) else { return }
        connectLog?.write("pod", "popup closed")   // W183 R12
        if entry.sensitive { Self.sensitivePopupCount = max(Self.sensitivePopupCount - 1, 0) }
        let frame = HandsPodFrame(url: nil, generation: 0, loading: false, httpStatus: 0, popup: true, popupKey: key, closed: true,
                                  openerIsMain: entry.openerIsMain)
        onFrame?(frame)
        onDisplayFrame?(frame)   // W183 R8b：分頁跟著拿掉
    }

    #if DEBUG
    /// 自測（W183 R10 第四輪）：沒有真的 CEF 畫面時，走跟原生開窗同一條登記、狀態、關閉的路（view＝nil）。
    func simulateNativePopup(key: Int, openerIsMain: Bool) {
        registerPopup(key: key, view: nil, sensitive: false, openerIsMain: openerIsMain)
    }

    func simulatePopupState(key: Int, url: String?, generation: UInt64, loading: Bool) {
        guard let entry = popups[key] else { return }
        popupState(key, committed: url, generation: generation, loading: loading, status: loading ? 0 : 200, source: entry.source,
                   openedAt: entry.openedAt, openerIsMain: entry.openerIsMain)
    }

    func simulatePopupClosed(key: Int) { popupClosed(key) }
    #endif

    /// CEF 給這個 popup 開的原生視窗（W183 R8b：頁面可能已經搬進私訊框的分頁，這裡只回它自己那個視窗）。
    func popupWindow(_ key: Int) -> NSWindow? { popups[key]?.home }

    /// 關掉連線流程開的視窗（配對頁）：流程結束、取消、被拒一律關（不留在最上層）。
    func closePopups() {
        for (_, entry) in popups where entry.sensitive {
            entry.view?.isHidden = true
            entry.home?.orderOut(nil)   // W183 R8b：只收它自己的原生視窗（頁面在私訊框的分頁裡時不能收到私訊框）
            entry.view?.closeBrowser()
        }
    }

    func prepare() async -> HandsPodReadiness {
        guard ChatGPTTap.isEnabled else { return .unavailable("設定 › Plugin › TAP 的 ChatGPT 關著") }
        attach()
        tap.start()
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if Task.isCancelled { return .unavailable("已取消") }
            switch tap.connection {
            case .ready: return .ready(account: await account())
            case .needsLogin: return .needsLogin
            case .failed(let reason): return .unavailable(reason)
            case .off: return .unavailable("設定 › Plugin › TAP 的 ChatGPT 關著")
            default: break
            }
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return .unavailable("已取消") }
        }
        return .unavailable("ChatGPT 網頁沒有回應")
    }

    /// Pod 目前登入的帳號（觀測值：信箱，沒有就名字；給卡片看）。
    func account() async -> String? {
        guard tap.connection == .ready, let account = try? await tap.account() else { return nil }
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = email.isEmpty ? name : email
        return value.isEmpty ? nil : String(value.prefix(120))
    }

    /// 比對用的帳號身分：登入編號、工作區、信箱（讀不到＝nil，呼叫端不能當成通過）。
    func identity() async -> String? {
        guard tap.connection == .ready,
              let data = try? await request("connectorAccount", [:], hold: nil, timeout: .seconds(12)) else { return nil }
        let user = (data["user"] as? String) ?? ""
        let workspace = (data["workspace"] as? String) ?? ""
        let email = ((data["email"] as? String) ?? "").lowercased()
        guard !user.isEmpty || !email.isEmpty else { return nil }
        return "u=\(user)|w=\(workspace)|e=\(email)"
    }

    func acquireExclusive(timeout: TimeInterval) async -> Bool {
        if hold != nil { return true }
        if let releasing { await releasing.value }   // 上一次放掉的還在帶回首頁：等它做完
        if hold != nil { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if let id = tap.beginConnectorHold() { hold = id; return true }
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return false }
        }
        return false
    }

    /// 放掉獨占：先停掉還在跑的連接器指令、把 Pod 帶回 chatgpt.com 首頁，回到了才放行排隊的聊天（獨占到那時才真的放）。
    func releaseExclusive() {
        guard let id = hold else { return }
        hold = nil
        let tap = self.tap
        releasing = Task { @MainActor [weak self] in
            if let self { await self.restore(id) }
            tap.endConnectorHold(id)
            self?.releasing = nil
            self?.flushSettled()   // W183 R8b 審查
        }
    }

    /// W183 R8b 審查：連接器沒拿著 Pod、帶回首頁也做完了就叫 body（現在就是＝馬上叫；否則等下一次放掉並帶回首頁之後）。
    /// 私訊框 Browser 放掉 Pod 的受保護呈現前等這個：配對頁、外站不會出現在別的畫面。
    func whenSettled(_ body: @escaping @MainActor () -> Void) {
        if hold == nil, releasing == nil { return body() }
        settleWaiters.append(body)
    }

    private func flushSettled() {
        guard hold == nil, releasing == nil, !settleWaiters.isEmpty else { return }
        let waiters = settleWaiters
        settleWaiters = []
        for body in waiters { body() }
    }

    private func restore(_ id: UUID) async {
        guard tap.connection == .ready || tap.connection == .needsLogin else { return }   // Pod 沒在跑：沒有頁要帶回
        if let url = mainURL, url.host?.lowercased() == "chatgpt.com", !mainLoading, tap.connection == .ready {
            _ = try? await request("connectorAbort", [:], hold: id, timeout: .seconds(3))
            _ = try? await request("connectorHome", [:], hold: id, timeout: .seconds(15))
            return
        }
        // 主框架不在 chatgpt.com（同頁跳到 TATWO 配對頁、外站）或還在載入：網頁腳本在那裡不執行——原生載回首頁，等新的網頁報到。
        guard let surface = surface() else { return }
        let hellos = tap.helloCount
        surface.loadMain(ChatGPTTap.homeURL)
        let deadline = Date().addingTimeInterval(restoreTimeout)
        while Date() < deadline {
            if tap.helloCount != hellos, mainURL?.host?.lowercased() == "chatgpt.com" { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // 等不到：重開 Pod（排隊的送出會明確失敗，不會被派進一個不執行指令的頁面）。
        tap.restart()
    }

    private(set) var resolvedConnector: HandsConnectorScan.Match?
    private var knownDetails: [String: HandsConnectorScan.Match] = [:]

    private static func connector(_ raw: [String: Any]) -> HandsConnectorScan.Match {
        HandsConnectorScan.Match(id: (raw["id"] as? String).flatMap { $0.utf8.count <= 200 ? $0 : nil },
            name: String((raw["name"] as? String ?? "").prefix(80)),
            auth: ["oauth", "none"].contains(raw["auth"] as? String ?? "") ? raw["auth"] as! String : "unknown",
            serverURL: raw["serverURL"] as? String, detailPath: raw["detailPath"] as? String, connected: raw["connected"] as? Bool)
    }

    func inspect(_ connector: HandsConnectorScan.Match, url: String) async -> HandsConnectorAuthorization {
        var result = HandsConnectorAuthorization.unknown
        defer { connectLog?.write("pod", "connectorInspect result=\(result) count=\(result == .unknown ? 0 : 1)") }
        guard let id = connector.id else { return .unknown }
        var arguments: [String: Any] = ["url": url, "connectorID": id]
        if let path = connector.detailPath { arguments["detailPath"] = path }
        guard let data = try? await request("connectorInspect", arguments, hold: hold, timeout: .seconds(20)) else { return .unknown }
        knownDetails[id] = connector
        if let raw = data["connector"] as? [String: Any] { resolvedConnector = Self.connector(raw) }
        switch data["authorization"] as? String {
        case "connected": result = .connected
        case "needs_reconnect": result = .needsReconnect
        default: break
        }
        return result
    }

    func deleteConnector(_ connector: HandsConnectorScan.Match, keeping: String, url: String) async -> Bool {
        var deleted = false
        defer { connectLog?.write("pod", "connectorDelete result=\(deleted) count=\(deleted ? 1 : 0)") }
        guard let id = connector.id, id != keeping, connector.serverURL == url else { return false }
        var arguments: [String: Any] = ["url": url, "connectorID": id, "name": connector.name, "keeping": keeping]
        if let path = connector.detailPath { arguments["detailPath"] = path }
        deleted = (try? await request("connectorDelete", arguments, hold: hold, timeout: .seconds(25)))?["deleted"] as? Bool == true
        return deleted
    }

    func scan(url: String) async -> HandsConnectorScan {
        do {
            let data = try await request("connectorScan", ["url": url], hold: hold, timeout: .seconds(30))
            if data["status"] as? String == "aborted" {
                return HandsConnectorScan(loggedIn: true, listKnown: false, devMode: nil, matches: [], failure: "已中止")
            }
            var scan = HandsConnectorScan()
            scan.loggedIn = data["loggedIn"] as? Bool ?? false
            scan.listKnown = data["listKnown"] as? Bool ?? false
            scan.devMode = data["devMode"] as? Bool
            scan.matches = (data["matches"] as? [[String: Any]] ?? []).prefix(256).map(Self.connector)
            scan.conflictingNames = data["conflictingNames"] as? [String] ?? []
            knownDetails = Dictionary(scan.matches.compactMap { match in match.id.map { ($0, match) } }, uniquingKeysWith: { _, b in b })
            return scan
        } catch {
            return HandsConnectorScan(loggedIn: tap.connection != .needsLogin, listKnown: false, devMode: nil, matches: [],
                                      failure: Self.plain(error))
        }
    }

    func devModeNow() async -> Bool? {
        (try? await request("connectorDevMode", [:], hold: nil, timeout: .seconds(8)))?["devMode"] as? Bool
    }

    func create(url: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
        await create(url: url, name: HandsBuildConfig.connectorName(""), acknowledged: acknowledged)
    }

    /// W183 R8c：連接器名稱「TATWO（<設備名稱>）」（網頁腳本只收這個樣子；不合就用 TATWO）。辨識既有的仍以帳號＋完整網址＋OAuth。
    func create(url: String, name: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
        resolvedConnector = nil
        var arguments: [String: Any] = ["url": url, "name": name]
        if let acknowledged { arguments["ack"] = ["form": acknowledged.form, "warning": acknowledged.warning] }
        if let approved = acknowledged?.approved { arguments["approved"] = approved }   // W183 R12：使用者同意過的那一份同意內容
        return Self.carrying(await action("connectorCreate", arguments), approved: acknowledged?.approved)
    }

    func reconnect(url: String, connectorID: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
        var arguments: [String: Any] = ["url": url, "connectorID": connectorID]
        if let path = knownDetails[connectorID]?.detailPath { arguments["detailPath"] = path }
        if let acknowledged { arguments["ack"] = ["form": acknowledged.form, "warning": acknowledged.warning] }
        if let approved = acknowledged?.approved { arguments["approved"] = approved }   // W183 R12
        return Self.carrying(await action("connectorReconnect", arguments), approved: acknowledged?.approved)
    }

    /// W183 R12（.037 實機）：用本機記下的名字找那個建好、還沒授權的（清單讀不到它）；認的方法照舊（完整網址＋OAuth）。
    func reconnectByName(url: String, name: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
        var arguments: [String: Any] = ["url": url, "name": name]
        if let acknowledged { arguments["ack"] = ["form": acknowledged.form, "warning": acknowledged.warning] }
        if let approved = acknowledged?.approved { arguments["approved"] = approved }
        return Self.carrying(await action("connectorReconnect", arguments), approved: acknowledged?.approved)
    }

    /// W183 R12：同意過的那一份跟著回來的確認往下帶（代勾之後再按 Create 那一次也帶著，網頁腳本整份核對）。
    nonisolated static func carrying(_ action: HandsConnectorAction, approved: String?) -> HandsConnectorAction {
        guard let approved else { return action }
        switch action {
        case .tickable(let ack, let target): return .tickable(ack.approving(approved), target)
        case .needsUser(let reason, let ack?): return .needsUser(reason, ack.approving(approved))
        default: return action
        }
    }

    private func action(_ command: String, _ arguments: [String: Any]) async -> HandsConnectorAction {
        // W183 R10 第三輪（GPT-6 發現 7；主導裁決）：這一次指令綁住同一次獨占（lease）、同一份文件（導頁世代）與流程的操作編號；
        // 每次 await 回來、記錨點前、送「按」之前都核對——取消、重連之後晚到的 armed 不記錨點、不送「按」（也不會用到新的獨占）。
        guard let lease = hold else { return .notFound("no_lease") }
        let operation = pressOperation ?? ""
        let data: [String: Any]
        // W183 R10 第二輪（GPT-6 2）：代勾的位置是在這個指令跑的時候量的；指令前後主框架的導頁世代一樣＝量的就是這一份文件
        //（記在 HandsTickTarget.generation，點之前再核）。中間換過文件＝量的是哪一份說不準：世代記 0（不代勾，交給使用者）。
        let before = surface()?.nativeView?.navigationGeneration ?? 0
        do {
            data = try await request(command, arguments, hold: lease, timeout: .seconds(45))
        } catch TapError.timeout {
            // W183 R10 第二輪：這一步只核對、不按（按是下一步 connectorPress）：逾時＝沒有按。
            return .notFound("arm_timeout")
        } catch {
            return .notFound(Self.plain(error))
        }
        guard hold == lease, !Task.isCancelled else { return .notFound("stale_operation") }
        let after = surface()?.nativeView?.navigationGeneration ?? 0
        let generation = before == after ? after : 0
        if let raw = data["connector"] as? [String: Any] {
            resolvedConnector = Self.connector(raw)
            if let id = resolvedConnector?.id { knownDetails[id] = resolvedConnector }
        }
        trace(command, data, generation: generation)   // W183 R12：正式版的連線紀錄
        guard data["status"] as? String == "armed" else {
            let decoded = Self.decodeAction(data, generation: generation)
            // W183 R10 第三輪（GPT-6 發現 2）：量完的當下就向 CEF 認那一個節點（backendNodeId），派送前只驗它；認不到＝不代勾。
            if case .tickable(let ack, var target) = decoded {
                // W183 R12（.034 實機：CEF 的畫面快照整頁只有 1 個控制項，這一步永遠認不到＝永遠不代勾）：CEF 認得到＝加分（照舊點那一個節點）；
                // 認不到＝不當成「找不到」，改走 DOM 驗證（tick 裡：按之前在同一份文件再驗一次、量位置、點中心、點完用 DOM 確認勾上了）。
                target.node = await captureTickNode(target, lease: lease)
                guard hold == lease else { return .notFound("stale_operation") }
                target.form = ack.form
                return .tickable(ack, target)
            }
            if Self.needsSnapshot(decoded) { await snapshotPage(command, HandsConnectFlow.actionLabel(decoded), lease: lease) }   // W183 R12
            return decoded
        }
        guard let token = Self.armToken(data["form"]) else { return .notFound("unexpected") }
        // 錨點：送出「按」之前的這一刻（主框架的導頁世代與網址＝連接器對話框那一頁；已經開著的 popup；這一次的操作編號）。
        let armedGeneration = surface()?.nativeView?.navigationGeneration ?? mainGeneration
        guard hold == lease, after == 0 || armedGeneration == after else { return .notFound("stale_armed") }
        let anchor = HandsPressAnchor(at: Date(), mainGeneration: armedGeneration, mainURL: mainURL, popups: Set(popups.keys),
                                      operation: operation)
        onPressDispatch?(anchor)
        guard hold == lease, (surface()?.nativeView?.navigationGeneration ?? mainGeneration) == armedGeneration else { return .notFound("stale_armed") }
        // W183 R12（.035 實機：程式按 Create＝沒有真人手勢，ChatGPT 開授權視窗被擋、對話框整張停在等待）：先請腳本照舊全部核完、量那一顆的
        // 位置（不按），用 CEF 真的滑鼠事件點中心（跟代勾同一套：同一次獨占、同一份文件、畫面大小一樣、沒縮放）；腳本核那一下真的落在那一顆上
        // ＝按了。量不到、點不出去＝照舊由腳本按（紀錄寫明沒有真人手勢）。
        if let native = await nativePress(token, lease: lease, generation: armedGeneration) { return native }
        guard hold == lease else { return .unknown }
        do {
            let pressed = try await request("connectorPress", ["form": token], hold: lease, timeout: .seconds(20))
            guard hold == lease else { return .unknown }   // 按了、回來時獨占已經換了：結果算不清（流程照 unknown：不代填）
            let result = Self.decodeAction(pressed, generation: generation)
            trace("connectorPress", pressed, generation: generation)   // W183 R12
            if Self.needsSnapshot(result) { await snapshotPage("connectorPress", HandsConnectFlow.actionLabel(result), lease: lease) }
            return result
        } catch TapError.timeout {
            return .unknown   // 送了「按」、回覆沒回來：可能按了、可能沒按（呼叫端先讀清單，不再按；也不代填）
        } catch {
            return .notFound(Self.plain(error))
        }
    }

    /// W183 R10 第三輪（GPT-6 發現 2）：Pod 量完那一格的當下，向 CEF 的畫面快照認出同一個位置剛好一個的控制項，記下它的節點身分
    ///（cef-<backendNodeId>：瀏覽器那端給的，網頁改不了）與 CEF 量到的位置。還拿著同一次獨占、還是同一份文件才算；認不到＝nil。
    private func captureTickNode(_ target: HandsTickTarget, lease: UUID) async -> HandsTickNode? {
        guard target.generation != 0, let view = surface()?.nativeView, view.navigationGeneration == target.generation else { return nil }
        guard let json = await Self.snapshot(view), let data = json.data(using: .utf8),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              hold == lease, view.navigationGeneration == target.generation,
              let control = Self.tickControl(snapshot, target: target, generation: target.generation, viewport: view.bounds.size) else {
            await noteNodeMiss(target, view: view, lease: lease)   // W183 R12：找不到節點＝那一帶的控制項＋結構快照進紀錄
            return nil
        }
        return HandsTickNode(id: control.elementID, x: control.rect.minX, y: control.rect.minY, width: control.rect.width, height: control.rect.height)
    }

    // MARK: - W183 R12 正式版的連線紀錄（.033 實機：失敗了查不到頁面長什麼樣）

    /// 指令結果的一行（狀態、原因、步驟、同意內容認不認得、有沒有代勾的位置、有沒有全文；不含頁面上的字）。
    private func trace(_ command: String, _ data: [String: Any], generation: UInt64) {
        guard let connectLog else { return }
        var parts = ["pod \(command)", "status=\(data["status"] as? String ?? "?")"]
        for key in ["reason", "step", "consent"] { if let value = data[key] as? String, !value.isEmpty { parts.append("\(key)=\(value.prefix(40))") } }
        if data["tick"] != nil { parts.append("tick=yes") }
        if data["offer"] != nil { parts.append("offer=yes") }
        if let native = data["native"] as? Bool { parts.append("native=\(native)") }   // W183 R12：Create 是不是真的點擊按的
        if data["refound"] as? Bool == true { parts.append("refound=yes") }
        parts.append("gen=\(generation)")
        connectLog.write("pod", parts.joined(separator: " "))
    }

    /// W183 R12（.035／.036 實機）：用 CEF 真的滑鼠點 Create（或重新連線）——程式按沒有真人手勢，ChatGPT 的授權視窗出不來、對話框會一直等。
    /// 量不到、點不中＝不退回程式按：把那一顆亮起來、請使用者自己按（onUserPressNeeded），按了照常接手。nil＝沒有畫面（呼叫端照舊）。
    private func nativePress(_ token: String, lease: UUID, generation: UInt64) async -> HandsConnectorAction? {
        guard let view = surface()?.nativeView, view.navigationGeneration == generation else {
            connectLog?.write("pod", "create path=script reason=no_view")
            return nil
        }
        let aimed = try? await request("connectorPress", ["form": token, "phase": "aim"], hold: lease, timeout: .seconds(10))
        guard hold == lease else { return .unknown }
        guard let aimed, aimed["status"] as? String == "aimed" else {
            if let aimed, aimed["status"] as? String != "aim_failed" {   // 核不過（press_stale、同意內容變了…）＝就是結果，不按
                trace("connectorPress(aim)", aimed, generation: generation)
                let result = Self.decodeAction(aimed, generation: generation)
                if Self.needsSnapshot(result) { await snapshotPage("connectorPress", HandsConnectFlow.actionLabel(result), lease: lease) }
                return result
            }
            connectLog?.write("pod", "create aim_failed why=\(aimed?["why"] as? String ?? "error") rect=\(aimed?["rect"] as? String ?? "") top=\((aimed?["top"] as? String ?? "").prefix(200)) view=\(view.bounds.width)x\(view.bounds.height)")
            await snapshotPage("connectorPress", "aim_failed", lease: lease)
            return await waitForUserPress(token, lease: lease, generation: generation)
        }
        guard let point = Self.domClickPoint(["status": "ok", "tick": aimed["rect"] ?? NSNull()], generation: generation, viewSize: view.bounds.size,
                                             zoomLevel: view.zoomLevel), view.navigationGeneration == generation else {
            connectLog?.write("pod", "create aim_failed why=point view=\(view.bounds.width)x\(view.bounds.height) zoom=\(view.zoomLevel)")
            return await waitForUserPress(token, lease: lease, generation: generation)
        }
        let sent = view.sendClick(at: point, navigationGeneration: generation)
        connectLog?.write("pod", "create path=native click at=\(Int(point.x)),\(Int(point.y)) sent=\(sent)")
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard hold == lease else { return .unknown }
        guard let confirmed = try? await request("connectorPress", ["form": token, "phase": "confirm"], hold: lease, timeout: .seconds(20)),
              hold == lease else { return .unknown }
        trace("connectorPress(confirm)", confirmed, generation: generation)
        if confirmed["status"] as? String == "not_landed" {
            connectLog?.write("pod", "create native click not landed")
            return await waitForUserPress(token, lease: lease, generation: generation)
        }
        let result = Self.decodeAction(confirmed, generation: generation)
        if Self.needsSnapshot(result) { await snapshotPage("connectorPress", HandsConnectFlow.actionLabel(result), lease: lease) }
        return result
    }

    /// W183 R12（.036 實機）：把 Create 亮起來、等使用者自己按（最多到配對窗口的期限）；按了＝pressed（真人手勢），ChatGPT 講了錯（alert）照樣寫進紀錄。
    private func waitForUserPress(_ token: String, lease: UUID, generation: UInt64) async -> HandsConnectorAction {
        guard let started = try? await request("connectorPress", ["form": token, "phase": "wait_user"], hold: lease, timeout: .seconds(10)),
              hold == lease else { return .unknown }
        guard started["status"] as? String == "waiting_user" else {
            trace("connectorPress(wait_user)", started, generation: generation)
            return Self.decodeAction(started, generation: generation)
        }
        connectLog?.write("pod", "create path=user (Create highlighted; waiting for the user's own press)")
        onUserPressNeeded?()
        let deadline = Date().addingTimeInterval(HandsAuth.windowLifetime)
        var lastAlert = ""
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard hold == lease, !Task.isCancelled else { return .unknown }
            guard let polled = try? await request("connectorPress", ["form": token, "phase": "poll"], hold: lease, timeout: .seconds(5)),
                  hold == lease else { continue }
            let status = polled["status"] as? String
            if status == "waiting_user" {
                if let alert = polled["alert"] as? String, alert != lastAlert { lastAlert = alert; connectLog?.write("pod", "create alert: \(alert)") }
                continue
            }
            trace("connectorPress(poll)", polled, generation: generation)
            return Self.decodeAction(polled, generation: generation)
        }
        connectLog?.write("pod", "create user press timed out")
        return .notFound("user_press_timeout")
    }

    /// W183 R12：紀錄裡的網址只記網域＋路徑（不記查詢字串、片段）。
    nonisolated static func logURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host else { return "?" }
        return host + String(url.path.prefix(120))
    }

    /// 對不上（交回使用者、拒絕、找不到、不只一個）＝留一份結構快照。
    nonisolated static func needsSnapshot(_ action: HandsConnectorAction) -> Bool {
        switch action {
        case .needsUser, .refused, .ambiguous: true
        case .notFound(let step): !["no_lease", "aborted", "stale_operation", "arm_timeout"].contains(step)
        default: false
        }
    }

    /// 結構快照：網頁腳本 connectorOutline（只讀；DOM 文字，不是截圖；腳本截在 16 KB）；press_stale 那一刻留的（arm 的時候那一顆 vs. 現在的按鈕清單）一起寫。
    private func snapshotPage(_ command: String, _ code: String, lease: UUID) async {
        guard let connectLog, hold == lease,
              let data = try? await request("connectorOutline", [:], hold: lease, timeout: .seconds(8)) else { return }
        if let stale = data["stale"] as? [String: Any] {
            let why = stale["why"] as? String ?? "?"
            connectLog.write("pod", "press_stale why=\(why.prefix(80)) armed=\((stale["armed"] as? String ?? "").prefix(400)) now=\((stale["armedNow"] as? String ?? "").prefix(400))")
            if let buttons = stale["buttons"] as? String { connectLog.structure("pod", "press_stale buttons", buttons) }
            if let structure = stale["structure"] as? String { connectLog.structure("pod", "press_stale structure", structure) }
        }
        if let outline = data["outline"] as? String { connectLog.structure("pod", "\(command) \(code) outline", outline) }
    }

    /// 代勾那一格 CEF 認不到（找不到節點）：記下快照裡那一帶的控制項（種類、位置、停用；不含字與值）＋頁面的結構快照。
    private func noteNodeMiss(_ target: HandsTickTarget, view: TatwoCEFBrowserView, lease: UUID) async {
        guard let connectLog else { return }
        var summary = "tick node not found target=\(Int(target.x)),\(Int(target.y)) \(Int(target.width))x\(Int(target.height))"
            + " viewport=\(Int(target.viewportWidth))x\(Int(target.viewportHeight)) gen=\(target.generation) now=\(view.navigationGeneration)"
            + " zoom=\(view.zoomLevel) view=\(view.bounds.width)x\(view.bounds.height)"
        if let json = await Self.snapshot(view), let data = json.data(using: .utf8),
           let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let controls = snapshot["controls"] as? [[String: Any]] ?? []
            summary += " controls=\(controls.count)"
            let cx = target.x + target.width / 2, cy = target.y + target.height / 2
            var near: [String] = []
            for control in controls {
                guard let rect = control["rect"] as? [String: Any], let x = (rect["x"] as? NSNumber)?.doubleValue,
                      let y = (rect["y"] as? NSNumber)?.doubleValue, let w = (rect["width"] as? NSNumber)?.doubleValue,
                      let h = (rect["height"] as? NSNumber)?.doubleValue, abs(x + w / 2 - cx) < 80, abs(y + h / 2 - cy) < 80 else { continue }
                let kind = (control["kind"] as? String ?? "?").prefix(20)
                near.append("\(kind)@\(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))" + ((control["disabled"] as? Bool) == true ? " disabled" : ""))
                if near.count >= 12 { break }
            }
            summary += " near=[" + near.joined(separator: "; ") + "]"
        } else {
            summary += " snapshot=none"
        }
        connectLog.write("pod", summary)
        await snapshotPage("tick_node", "node_not_found", lease: lease)
    }

    /// armed 的一次性記號（跟表單記號同一個樣子）。
    nonisolated static func armToken(_ raw: Any?) -> String? {
        guard let form = raw as? String, (2...24).contains(form.utf8.count), form.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return form
    }

    static func decodeAction(_ data: [String: Any], generation: UInt64 = 0) -> HandsConnectorAction {
        let step = String((data["step"] as? String ?? data["reason"] as? String ?? "").prefix(40))
        switch data["status"] as? String {
        case "pressed": return .pressed
        case "needs_user":
            let ack = (data["form"] as? String).flatMap { form -> HandsConnectorAck? in
                guard form.utf8.count <= 24, form.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
                return HandsConnectorAck(form: form, warning: String((data["warning"] as? String ?? "").prefix(40)))
            }
            // W183 R10 第二輪（GPT-6 3）：同意內容對不上核實過的版本＝不代勾，卡片說「跟 TATWO 認得的不一樣」。
            // W183 R12（主導 3）：腳本讀得到那一份（純文字、連結都在 OpenAI 的網域）＝一起帶回來：卡片顯示全文、［同意並繼續］。
            if step == "risk_ack", data["consent"] as? String == "unknown" {
                var offered = ack
                if let offer = HandsConsentOffer(wire: data["offer"]), let seen = ack { offered = HandsConnectorAck(form: seen.form, warning: seen.warning, consent: offer) }
                return .needsUser(HandsConnectFlow.warningChangedReason, offered)
            }
            // W183 R10：只剩「I understand and want to continue」那一格、腳本也量得出它在畫面上的位置＝TATWO 代勾（記下量的那一份文件）。
            if step == "risk_ack", let ack, let target = HandsTickTarget(wire: data["tick"], generation: generation) { return .tickable(ack, target) }
            return .needsUser(userReasonText(step), ack)
        case "ambiguous": return .ambiguous(step)
        case "refused": return .refused(step)
        case "not_found": return .notFound(step)
        case "aborted": return .notFound("aborted")
        default: return .notFound("unexpected")
        }
    }

    static func userReasonText(_ reason: String) -> String {
        switch reason {
        case "risk_ack": HandsConnectFlow.riskAckReason   // W183 R9：「I understand and want to continue」那一格
        case "untrusted_tick": HandsConnectFlow.untrustedTickReason   // W183 R9 審查（GPT-6 #2）：勾著、但沒有使用者真的按過的紀錄
        case "warning_unbounded": HandsConnectFlow.warningUnboundedReason   // W183 R9 審查（GPT-6 N9）：警語太長或看不出範圍（App 改手動）
        case "warning_changed": HandsConnectFlow.warningChangedReason   // W183 R10：警語跟認得的不一樣（不代勾）
        case "checkbox": HandsConnectFlow.checkboxUnknownReason   // W183 R10：多了沒見過的勾選框（不代勾）
        case "warning": "表單上有警語"
        case "create_disabled": "「建立」鈕還不能按"
        default: reason
        }
    }

    // MARK: - W183 R10 代勾、代填

    /// 代勾（W183 R10 第二輪，GPT-6 2：不走裸座標 sendClick；第三輪，GPT-6 發現 2、3：只點量完當下記下的那一個節點）：
    /// 拿著 Pod、還是量的那一份文件、畫面大小一樣、沒縮放 → 請網頁腳本再核一次同意內容（版本、順序文字、連結字與網域跟量的時候一樣；
    /// 變了＝consentChanged）→ CEF 的節點驗證點擊，目標就是記下的那一個節點（cef-<backendNodeId>；送出之前 CEF 再核它還在、還在那一點
    /// 最上面、位置沒變、同一份文件；送出那一刻還拿著同一次獨占）。任何一步對不上＝notClicked（交給使用者）。
    func tick(_ target: HandsTickTarget) async -> HandsTickOutcome {
        // W183 R12（.035 實機：紀錄只有「沒勾到」、看不出停在哪一步）：每一個不點的地方都寫一行原因；點的時候寫走哪條路（cef／dom）。
        guard let lease = hold, tap.connection == .ready, let view = surface()?.nativeView, !target.form.isEmpty else {
            connectLog?.write("pod", "tick refused why=no_pod hold=\(hold != nil) ready=\(tap.connection == .ready) view=\(surface()?.nativeView != nil) form=\(!target.form.isEmpty)")
            return .notClicked
        }
        let generation = view.navigationGeneration
        let viewport = NSSize(width: target.viewportWidth, height: target.viewportHeight)
        // zoomLevel 是 Chromium 的縮放級數（0＝100%，±1 一級）：.034 紀錄的 zoom=0.0＝沒縮放，CEF 的畫面點＝網頁的 CSS px（畫面大小也核了）。
        guard target.generation != 0, generation == target.generation, Self.sameViewport(view.bounds.size, viewport), view.zoomLevel == 0 else {
            connectLog?.write("pod", "tick refused why=page gen=\(target.generation)/\(generation) view=\(view.bounds.width)x\(view.bounds.height) page=\(target.viewportWidth)x\(target.viewportHeight) zoom=\(view.zoomLevel)")
            return .notClicked
        }
        // 派送前核同意內容（網頁腳本照代勾那一刻綁住的版本、文字、連結字與網域比；表單換了、離開這一頁也算變了）。
        let consent: [String: Any]
        do { consent = try await request("connectorConsent", ["form": target.form], hold: lease, timeout: .seconds(5)) } catch {
            connectLog?.write("pod", "tick refused why=consent_error")
            return .notClicked
        }
        guard hold == lease, view.navigationGeneration == generation else { return .notClicked }
        guard consent["status"] as? String == "ok" else {
            connectLog?.write("pod", "tick refused why=consent status=\(consent["status"] as? String ?? "?")")
            return consent["status"] as? String == "changed" ? .consentChanged : .notClicked
        }
        connectLog?.write("pod", "tick path=\(target.node == nil ? "dom" : "cef")")
        let clicked: Bool
        if let node = target.node {
            let rect = NSRect(x: node.x, y: node.y, width: node.width, height: node.height)
            guard let point = BrowserAgentBridge.clickPoint(rect: ["x": node.x, "y": node.y, "width": node.width, "height": node.height],
                                                            viewport: ["width": target.viewportWidth, "height": target.viewportHeight],
                                                            size: view.bounds.size) else { return .notClicked }
            clicked = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                view.clickElement(node.id, at: point, expectedRect: rect, viewportSize: view.bounds.size,
                                  navigationGeneration: generation, dispatchGate: { [weak self] dispatch in
                    // 真的送出之前：還拿著同一次獨占、還是同一份文件（CEF 自己也核節點、世代、網址、畫面大小、縮放）。
                    guard let self, self.hold == lease, view.navigationGeneration == generation else { return false }
                    dispatch()
                    return true
                }) { completed, _ in continuation.resume(returning: completed) }
            }
        } else {
            clicked = await domTick(target, view: view, lease: lease, generation: generation)   // W183 R12：CEF 認不到＝DOM 驗證
        }
        guard clicked else { return .notClicked }
        // W183 R12：點完用 DOM 確認勾上了、Create 變成可按；沒有＝交回使用者（不點第二次）。
        return await tickLanded(target.form, view: view, lease: lease, generation: generation) ? .clicked : .notClicked
    }

    /// 畫面快照裡「Pod 量的那一格」：chatgpt.com、同一份文件（導頁世代）、畫面大小一樣；按鈕或勾選框、沒停用、位置跟量的差不到 1 px 的
    /// 剛好一個（多個、沒有、位置變了＝nil，不點）。回 CEF 節點驗證點擊要的元素編號與快照裡的位置。
    nonisolated static func tickControl(_ snapshot: [String: Any], target: HandsTickTarget, generation: UInt64, viewport: NSSize)
        -> (elementID: String, rect: NSRect, rectWire: [String: Any], viewportWire: [String: Any])? {
        guard (snapshot["origin"] as? String)?.lowercased() == "https://chatgpt.com",
              (snapshot["navigationGeneration"] as? NSNumber)?.uint64Value == generation,
              let size = snapshot["viewport"] as? [String: Any],
              let width = (size["width"] as? NSNumber)?.doubleValue, let height = (size["height"] as? NSNumber)?.doubleValue,
              sameViewport(NSSize(width: width, height: height), viewport),
              let controls = snapshot["controls"] as? [[String: Any]] else { return nil }
        let matches = controls.compactMap { control -> (String, NSRect, [String: Any])? in
            guard ["button", "checkbox"].contains(control["kind"] as? String ?? ""), control["disabled"] as? Bool != true,
                  let id = control["elementID"] as? String, id.hasPrefix("cef-"), let raw = control["rect"] as? [String: Any],
                  let rect = Self.rect(raw, within: viewport),
                  abs(rect.minX - target.x) < 1, abs(rect.minY - target.y) < 1,
                  abs(rect.width - target.width) < 1, abs(rect.height - target.height) < 1 else { return nil }
            return (id, rect, raw)
        }
        guard matches.count == 1 else { return nil }
        return (matches[0].0, matches[0].1, matches[0].2, size)
    }

    /// W183 R12（.034 實機）：代勾的 DOM 驗證那一條——按之前請網頁腳本在同一份文件再驗一次（這張表單、同意內容一字不差、剛好一格、字對得上、
    /// 看得見、沒停用、還沒勾）並量位置；還拿著同一次獨占、同一份文件、畫面大小一樣、沒縮放，才用 CEF 真的滑鼠事件點那一格的中心。
    private func domTick(_ target: HandsTickTarget, view: TatwoCEFBrowserView, lease: UUID, generation: UInt64) async -> Bool {
        let aim = try? await request("connectorTick", ["phase": "aim", "form": target.form], hold: lease, timeout: .seconds(5))
        guard hold == lease, view.navigationGeneration == generation,
              let point = Self.domClickPoint(aim, generation: generation, viewSize: view.bounds.size, zoomLevel: view.zoomLevel) else {
            connectLog?.write("pod", "dom tick not aimed status=\(aim?["status"] as? String ?? "none") why=\(aim?["why"] as? String ?? "")")
            return false
        }
        let sent = view.sendClick(at: point, navigationGeneration: generation)
        connectLog?.write("pod", "dom tick click at=\(Int(point.x)),\(Int(point.y)) sent=\(sent)")
        return sent
    }

    /// W183 R12：腳本量回來的位置 → CEF 的點（整數、在那一格裡）。狀態不是 ok、位置不合格、畫面大小對不上、有縮放＝nil（不點）。
    nonisolated static func domClickPoint(_ aim: [String: Any]?, generation: UInt64, viewSize: NSSize, zoomLevel: Double) -> NSPoint? {
        guard let aim, aim["status"] as? String == "ok", zoomLevel == 0,
              let fresh = HandsTickTarget(wire: aim["tick"], generation: generation),
              sameViewport(viewSize, NSSize(width: fresh.viewportWidth, height: fresh.viewportHeight)) else { return nil }
        return NSPoint(x: fresh.point.x, y: fresh.point.y)
    }

    /// W183 R12：點完看勾上了沒（網頁處理完才會變：最多等約 1 秒）；勾上了而且 Create 能按＝true。
    private func tickLanded(_ form: String, view: TatwoCEFBrowserView, lease: UUID, generation: UInt64) async -> Bool {
        var last: [String: Any]?
        for _ in 0..<7 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard hold == lease, view.navigationGeneration == generation else { break }
            last = try? await request("connectorTick", ["phase": "after", "form": form], hold: lease, timeout: .seconds(3))
            if Self.tickTook(last) { return true }
        }
        connectLog?.write("pod", "tick not landed checked=\(last?["checked"] as? Bool ?? false) create=\(last?["create"] as? Bool ?? false) status=\(last?["status"] as? String ?? "none")")
        return false
    }

    nonisolated static func tickTook(_ after: [String: Any]?) -> Bool {
        after?["status"] as? String == "ok" && after?["checked"] as? Bool == true && after?["create"] as? Bool == true
    }

    /// 代填：只在綁住的那一頁填 8 碼、送出（見檔頭）。任何一步對不上＝.failed（呼叫端退回顯示碼）。碼不寫任何紀錄。
    func fillPairingCode(_ code: String, frame: HandsPodFrame, evidence: String, publicHost: String) async -> HandsCodeFill {
        guard code.count == 8, code.allSatisfy({ HandsAuth.codeAlphabet.contains($0) }) else { return .failed("code") }
        guard let view = boundView(frame) else { return .failed("no_view") }
        // 綁住的是「那一個畫面上、那一組參數的配對頁」：同一頁重新載入（窗口剛好還沒開的那一次 403 重載）導頁世代會變、參數不變——
        // 以現在這一份文件為準（參數要對得上），之後每一步都要還是這一份（換頁、換參數、換畫面＝不填）。
        let generation = view.navigationGeneration
        func stillBound() -> Bool {
            guard view.navigationGeneration == generation, let current = view.currentURLString.flatMap({ URL(string: $0) }) else { return false }
            return HandsConnectFlow.authorizeEvidence(current, publicHost: publicHost).map { HandsAuth.constantTimeEqual($0, evidence) } ?? false
        }
        guard stillBound(), view.zoomLevel == 0 else { return .failed("not_bound_page") }
        guard let json = await Self.snapshot(view), let data = json.data(using: .utf8),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed("snapshot") }
        guard stillBound(), let form = Self.pairingForm(snapshot, publicHost: publicHost, generation: generation, viewport: view.bounds.size) else {
            return .failed("form")
        }
        let field = NSPoint(x: form.field.midX.rounded(.down), y: form.field.midY.rounded(.down))
        let submit = NSPoint(x: form.submit.midX.rounded(.down), y: form.submit.midY.rounded(.down))
        guard view.sendClick(at: field, navigationGeneration: generation) else { return .failed("focus") }
        try? await Task.sleep(nanoseconds: 150_000_000)
        for character in code {
            guard stillBound(), let key = Self.key(for: character) else { view.releaseAgentKey(); return .failed("key") }
            for phase in 0...2 {
                guard view.sendAgentKey(key.code, windowsCode: key.windowsCode, characters: key.characters, unmodified: key.unmodified,
                                        modifiers: key.flags.rawValue, phase: Int32(phase), navigationGeneration: generation) else {
                    view.releaseAgentKey()
                    return .failed("key")
                }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard stillBound(), view.sendClick(at: submit, navigationGeneration: generation) else { return .failed("submit") }
        return .filled
    }

    /// 綁住的那一個畫面：主框架＝Pod 的原生畫面；popup＝那一個（還開著的）視窗。
    private func boundView(_ frame: HandsPodFrame) -> TatwoCEFBrowserView? {
        if frame.popup { return frame.popupKey.flatMap { popups[$0]?.view } }
        return surface()?.nativeView
    }

    /// 畫面大小對得上（CEF 的畫面點＝網頁的 CSS px，只在沒縮放、大小一樣時成立）。
    /// W183 R12（.035 實機：私訊框的 Browser 會縮放，畫面可以是小數點（524.5），網頁的 innerWidth 是整數（524）＝以前差 0.5 就不點）：差不到 1。
    nonisolated static func sameViewport(_ a: NSSize, _ b: NSSize) -> Bool {
        abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// 配對碼的一個字 → 原生按鍵（字母用 Shift 打大寫；字元集沒有 0、1、I、O）。
    nonisolated static func key(for character: Character) -> BrowserNativeInput.Key? {
        guard HandsAuth.codeAlphabet.contains(character) else { return nil }
        let text = String(character).lowercased()
        return try? BrowserNativeInput.parseKey(character.isLetter ? "shift+" + text : text)
    }

    private static func snapshot(_ view: TatwoCEFBrowserView) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            view.captureVisibleSnapshot { json, _ in continuation.resume(returning: json) }
        }
    }

    /// 畫面快照裡的配對表單（W183 R10 代填）：這一頁是這台主機（origin）、同一份文件（導頁世代）、畫面大小對得上；
    /// 送到這台主機的 POST 表單剛好一張，裡面剛好一格能打字的文字欄與一顆送出，兩個都整個在畫面裡、至少 8×8。其他一律 nil（不填）。
    nonisolated static func pairingForm(_ snapshot: [String: Any], publicHost: String, generation: UInt64, viewport: NSSize) -> (field: NSRect, submit: NSRect)? {
        let origin = "https://" + publicHost.lowercased()
        guard (snapshot["origin"] as? String)?.lowercased() == origin,
              (snapshot["navigationGeneration"] as? NSNumber)?.uint64Value == generation,
              let size = snapshot["viewport"] as? [String: Any],
              let width = (size["width"] as? NSNumber)?.doubleValue, let height = (size["height"] as? NSNumber)?.doubleValue,
              sameViewport(NSSize(width: width, height: height), viewport),
              let forms = snapshot["forms"] as? [[String: Any]] else { return nil }
        let mine = forms.filter { ($0["actionOrigin"] as? String)?.lowercased() == origin && ($0["method"] as? String)?.uppercased() == "POST" }
        guard mine.count == 1, let fields = mine[0]["fields"] as? [[String: Any]] else { return nil }
        func usable(_ field: [String: Any]) -> Bool { field["disabled"] as? Bool != true && field["readOnly"] as? Bool != true }
        let texts = fields.filter { $0["type"] as? String == "text" && usable($0) }
        let submits = fields.filter { $0["type"] as? String == "submit" && usable($0) }
        guard texts.count == 1, submits.count == 1, let field = rect(texts[0]["rect"], within: viewport),
              let submit = rect(submits[0]["rect"], within: viewport) else { return nil }
        return (field, submit)
    }

    private nonisolated static func rect(_ raw: Any?, within viewport: NSSize) -> NSRect? {
        guard let object = raw as? [String: Any], let x = (object["x"] as? NSNumber)?.doubleValue, let y = (object["y"] as? NSNumber)?.doubleValue,
              let w = (object["width"] as? NSNumber)?.doubleValue, let h = (object["height"] as? NSNumber)?.doubleValue,
              [x, y, w, h].allSatisfy(\.isFinite), w >= 8, h >= 8, x >= 0, y >= 0, x + w <= viewport.width, y + h <= viewport.height else { return nil }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    func highlight(url: String, name: String?) async -> Bool {
        var arguments: [String: Any] = ["url": url]
        if let name { arguments["name"] = name }
        return ((try? await request("connectorHighlight", arguments, hold: hold, timeout: .seconds(20)))?["highlighted"] as? Bool) ?? false
    }

    /// W183 R12（主導 2：要真人點的那一步指給他看；不按）：網頁腳本找到那一顆、捲到看得見、量位置（一次性記號＋位置）→ 還拿著同一次獨占、
    /// 同一份文件、畫面大小一樣、沒縮放 → CEF 的畫面快照在同一個位置認得出剛好一顆沒停用的按鈕（跟代勾同一套節點驗證）→ 才請腳本畫亮框＋箭頭。
    /// 任何一步對不上＝false（不畫；卡片照舊那一句）。
    func pointAtGesture(url: String, name: String) async -> HandsGesturePoint {
        guard let lease = hold, tap.connection == .ready, let view = surface()?.nativeView else { return .none }
        // 已經指著、那一顆還在＝不重畫（每幾秒看一次，不會一閃一閃）。
        if let alive = try? await request("connectorGesture", ["phase": "alive"], hold: lease, timeout: .seconds(5)),
           hold == lease, alive["shown"] as? Bool == true { return .shown(lastGestureLabel) }
        guard hold == lease else { return .none }
        let generation = view.navigationGeneration
        let found = try? await request("connectorGesture", ["phase": "find", "url": url, "name": name], hold: lease, timeout: .seconds(8))
        // W183 R12（.035 實機）：對話框整張停在等待（按了 Create 之後等 ChatGPT 自己的授權視窗）＝那時候沒有 Connect 是正常的，不判找不到。
        if hold == lease, found?["status"] as? String == "waiting" { return .waiting }
        // W183 R12（.036 實機）：對話框裡 ChatGPT 講了錯（例：同名的 App 已經有了）＝沒建成。
        if hold == lease, found?["status"] as? String == "rejected" {
            let alert = String((found?["alert"] as? String ?? "").prefix(80))
            connectLog?.write("pod", "gesture rejected alert: \(alert)")
            await snapshotPage("connectorGesture", "rejected", lease: lease)
            return .rejected(alert)
        }
        if hold == lease, found?["status"] as? String != "found" {
            // W183 R12（.034 實機：亮框沒出現、這一頁的樣子沒有）：找不到那一顆＝留一份結構快照（一分鐘最多一份）。
            if lastGestureSnapshot.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                lastGestureSnapshot = Date()
                connectLog?.write("pod", "gesture not found status=\(found?["status"] as? String ?? "none") step=\(found?["step"] as? String ?? "")")
                await snapshotPage("connectorGesture", "not_found", lease: lease)
            }
            return .none
        }
        guard let found, hold == lease, found["status"] as? String == "found", let mark = Self.armToken(found["mark"]),
              let target = HandsTickTarget(wire: found["rect"], generation: generation),
              view.navigationGeneration == generation, view.zoomLevel == 0,
              Self.sameViewport(view.bounds.size, NSSize(width: target.viewportWidth, height: target.viewportHeight)) else { return .none }
        // W183 R12（.034 實機：CEF 的畫面快照認不到 ChatGPT 對話框裡的控制項）：CEF 認得到＝加分（記進紀錄）；認不到不當成「找不到」——
        // 只畫、不按，DOM 那邊找（那一區剛好一顆）、畫之前再量一次位置沒變就畫。
        var confirmed = false
        if let json = await Self.snapshot(view), let data = json.data(using: .utf8),
           let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            confirmed = Self.gestureControl(snapshot, target: target, generation: generation, viewport: view.bounds.size) != nil
        }
        guard hold == lease, view.navigationGeneration == generation else { return .none }
        let label = String((found["label"] as? String ?? "").prefix(80))
        lastGestureLabel = label
        connectLog?.write("pod", "gesture found \(found["kind"] as? String ?? "connect") label=\(label) at=\(Int(target.x)),\(Int(target.y)) cef_confirmed=\(confirmed)")
        // W183 R12（.037 實機：建成之後 ChatGPT 開「Connect <名字>」對話框，唯一一顆「Continue to <名字>」）：這一步 TATWO 自己真的點擊
        //（使用者按［連線］＝同意連線；ChatGPT 要的是真人手勢），腳本確認落在那一顆上；20 秒內不點第二次（沒反應＝亮起來請你按）。
        if found["kind"] as? String == "continue", lastContinueClick.map({ Date().timeIntervalSince($0) > 20 }) ?? true {
            let point = NSPoint(x: target.point.x, y: target.point.y)
            let sent = view.sendClick(at: point, navigationGeneration: generation)
            lastContinueClick = Date()
            connectLog?.write("pod", "continue path=native click at=\(Int(point.x)),\(Int(point.y)) sent=\(sent)")
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard hold == lease else { return .none }
            let landed = (try? await request("connectorGesture", ["phase": "landed"], hold: lease, timeout: .seconds(5)))?["landed"] as? Bool == true
            connectLog?.write("pod", "continue landed=\(landed)")
            if landed { return .clicked(label) }
            return .none   // 沒落上：下一輪找到就畫亮框（20 秒內不再點）
        }
        guard let shown = try? await request("connectorGesture", ["phase": "show", "mark": mark], hold: lease, timeout: .seconds(5)),
              hold == lease else { return .none }
        return shown["shown"] as? Bool == true ? .shown(label) : .none
    }

    func clearGesture() {
        guard let lease = hold else { return }
        Task { @MainActor [weak self] in _ = try? await self?.request("connectorGesture", ["phase": "clear"], hold: lease, timeout: .seconds(5)) }
    }

    /// W183 R12：畫面快照裡「腳本量到的那一顆」：chatgpt.com、同一份文件、畫面大小一樣；按鈕、沒停用、位置跟量的差不到 1 px 的剛好一個。
    nonisolated static func gestureControl(_ snapshot: [String: Any], target: HandsTickTarget, generation: UInt64, viewport: NSSize) -> String? {
        guard let control = tickControl(snapshot, target: target, generation: generation, viewport: viewport),
              let controls = snapshot["controls"] as? [[String: Any]],
              controls.contains(where: { $0["elementID"] as? String == control.elementID && $0["kind"] as? String == "button" }) else { return nil }
        return control.elementID
    }

    func showDeveloperSettings() async {
        _ = try? await request("connectorSettings", [:], hold: hold, timeout: .seconds(10))
    }

    func reload(_ url: URL, popupKey: Int?) {
        if let popupKey, let popup = popups[popupKey]?.view {
            popup.loadURLString(url.absoluteString)
        } else {
            surface()?.loadMain(url)
        }
    }

    static func plain(_ error: Error) -> String {
        if let tap = error as? TapError { return tap.errorDescription ?? "ChatGPT 網頁沒有回應" }
        return "ChatGPT 網頁沒有回應"
    }
}
