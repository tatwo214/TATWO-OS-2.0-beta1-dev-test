import AppKit
import Combine
import Darwin
import TatwoCEFBridge

enum TapPodError: LocalizedError {
    case profileUnavailable
    case scriptRejected

    var errorDescription: String? {
        switch self {
        case .profileUnavailable: "瀏覽器安裝或資料目錄無效，Pod 無法啟動"
        case .scriptRejected: "瀏覽器核心沒有接受這個 Pod 的腳本"
        }
    }
}

/// TAP 的網頁艙（Pod）：用 OS 自己的瀏覽器核心跑外部 App 的真網頁版。
/// - 一個 Pod 一個獨立的登入空間（CEF 設定檔），登入資料只留在這裡，OS 核心拿不到。
/// - Tap 的腳本只注入這個瀏覽器（TatwoCEFBridge 的 configurePod），一般分頁完全不受影響。
/// - 原生 Space 的網頁墊在畫面外；Space 不在畫面且沒有回合時，另設原生 hidden 讓 Chromium 節流。
///   需要登入時由設定頁把它移到畫面上。
/// - 同一時間可能有兩個畫面要它（Space、設定頁的網頁版視窗）：最後叫它的那個拿到，放手後回到前一個。
@MainActor
final class TapWebPod {
    private struct Host {
        weak var view: NSView?
        let presentsPage: Bool
    }

    let podID: String
    let profile: EmbeddedBrowserRuntimeProfile
    let homeURL: URL
    /// W183 R9 審查（GPT-6 #3）：每次建立瀏覽器用的腳本（ChatGPT 的 Pod 每次換一把鑰匙：start(script:)）。
    private var script: String
    /// W183 R9 審查（GPT-6 #10）：只給人用的檔案選擇器（Pod 在私訊框 Browser 的分頁、看得到、使用者自己按才開）。
    private(set) lazy var filePicker = TapPodFilePicker(context: { [weak self] in self?.filePickerContext() ?? .closed })
    private(set) var browser: TatwoCEFBrowserView?
    private(set) var spacePage: TatwoCEFBrowserView?
    private(set) var dotsSpacePage: TatwoCEFBrowserView?
    private var spaceHost: UUID?
    // One human surface per Pod: first visible host keeps both pages until it disappears.
    func acquireSpaceHost(_ id: UUID) -> Bool {
        guard spaceHost == nil || spaceHost == id else { return false }
        spaceHost = id
        return true
    }
    static let spaceChanged = Notification.Name("TapWebPod.spaceChanged")
    func spaceDidChange() { NotificationCenter.default.post(name: Self.spaceChanged, object: self) }
    func releaseSpaceHost(_ id: UUID) { if spaceHost == id { spaceHost = nil; spaceDidChange() } }
    private var lease: TatwoCEFProfileLeaseRegistry.Lease?
    private var hosts: [Host] = []
    private var parking: NSWindow?
    private struct ConnectorPlacement {
        weak var parent: NSView?
        let frame: NSRect, mask: NSView.AutoresizingMask
    }
    private var connectorPlacement: ConnectorPlacement?
    private var connectorViewportUsers = 0
    private var connectorTermination: AnyCancellable?
    var connectorViewportBefore: NSSize? { connectorPlacement?.frame.size ?? browser?.bounds.size }
    func beginConnectorViewport() {
        connectorViewportUsers += 1
        guard connectorPlacement == nil, let browser, browser.bounds.width < 1000 || browser.bounds.height < 700 else { return }
        connectorPlacement = ConnectorPlacement(parent: browser.superview, frame: browser.frame, mask: browser.autoresizingMask)
        connectorTermination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            Task { @MainActor in self?.connectorViewportUsers = 1; self?.endConnectorViewport() }
        }
        place()
    }
    func endConnectorViewport() {
        connectorViewportUsers = max(0, connectorViewportUsers - 1)
        guard connectorViewportUsers == 0 else { return }
        guard let saved = connectorPlacement, let browser else { return }
        connectorPlacement = nil; connectorTermination = nil
        guard let parent = saved.parent, parent.window != nil, parent === placementTarget else { place(); return }
        browser.removeFromSuperview()
        parent.addSubview(browser)
        browser.frame = saved.frame; browser.autoresizingMask = saved.mask
        updateVisibility()
    }
    private var managesVisibility = false
    var isSpacePageShared: Bool { spaceVisible && spacePage == nil }
    private var spaceVisible = false
    private var backgroundWorkActive = false
    private var closingBrowsers = 0
    var isClosing: Bool { closingBrowsers > 0 }
    func waitUntilClosed(timeout: Duration) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: timeout)
        while isClosing, clock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        guard !isClosing else { throw TapPodError.profileUnavailable }
    }

    func setSpaceVisible(_ visible: Bool) {
        managesVisibility = true
        spaceVisible = visible
        updateVisibility()
    }

    func setBackgroundWorkActive(_ active: Bool) {
        managesVisibility = true
        backgroundWorkActive = active
        updateVisibility()
    }

    /// macOS windowed CEF 的 WebContentsViewCocoa.viewDidHide／viewDidUnhide
    /// 會讀 isHiddenOrHasHiddenAncestor 並送 OnWindowVisibilityChanged(kHidden／kVisible)。
    /// 依據：chromium/content/app_shim_remote_cocoa/web_contents_view_cocoa.mm:485–547。
    /// WasHidden 僅適用 windowless（cef/include/cef_browser.h），這裡不用它。
    private func updateVisibility() {
        guard managesVisibility, let browser else { return }
        let target = placementTarget
        let pagePresented = connectorPlacement != nil || (target != nil && (!guards.isEmpty || hosts.last(where: { $0.view != nil })?.presentsPage == true))
        browser.isHidden = Self.shouldHide(spaceVisible: spaceVisible, workActive: backgroundWorkActive, pagePresented: pagePresented)
        // 背景送出仍須通過原生輸入的 window.isVisible；不拿焦點、不顯示到螢幕內。
        if browser.superview === parking?.contentView {
            if !browser.isHidden { parking?.orderFrontRegardless() }
            else { parking?.orderOut(nil) }
        }
    }

    static func shouldHide(spaceVisible: Bool, workActive: Bool, pagePresented: Bool) -> Bool {
        !spaceVisible && !workActive && !pagePresented
    }
    /// Pod 主框架所在的渲染程序（腳本注入時由瀏覽器核心回報）；只用來讀記憶體用量。
    private(set) var rendererPID: pid_t?
    /// Tap 腳本回報的 JSON 字串。
    var onEvent: ((String) -> Void)?
    /// W183 R6b：主框架實際載入的網址（原生瀏覽器回報：網址、第幾份文件、載入中、HTTP 狀態；不是網頁腳本說的）。
    var onMainFrame: ((String?, UInt64, Bool, Int) -> Void)?
    /// W183 R6b：這個 Pod 開了一個原生新視窗（CEF popup；沿用 Pod 的登入空間）。收到的人可以看它的網址、把它移到別處。
    var onPopup: ((TatwoCEFBrowserView) -> Void)?

    init(podID: String, profileID: UUID, homeURL: URL, script: String) {
        self.podID = podID
        self.profile = .persistent(profileID)
        self.homeURL = homeURL
        self.script = script
    }

    #if DEBUG
    // The isolated CEF fixture uses the existing ai.tatwo.tatwo2.* loopback identity.
    var selfTestLocation: TatwoCEFProfileLocation?
    #endif

    var isRunning: Bool { browser != nil }

    func openSpacePage() throws -> TatwoCEFBrowserView {
        if let spacePage { return spacePage }
        let page = try makeSpacePage(homeURL)
        spacePage = page
        return page
    }

    func openDotsSpacePage() throws -> TatwoCEFBrowserView {
        if let dotsSpacePage { return dotsSpacePage }
        var url = ChatGPTDotsState.url
        #if DEBUG
        if (ProcessInfo.processInfo.environment["TATWO2_SELFTEST"] == "w265dmchatgpt" || ProcessInfo.processInfo.environment["TATWO_W270_DLFLY"] == "1"), selfTestLocation != nil {
            url = homeURL.deletingLastPathComponent().appending(path: "dots")
        }
        #endif
        let page = try makeSpacePage(url)
        dotsSpacePage = page
        return page
    }

    private func makeSpacePage(_ url: URL) throws -> TatwoCEFBrowserView {
        guard let browser else { throw TapPodError.profileUnavailable }
        // Same Pod lease and human actor; a normal sibling never receives configurePod.
        let page = try TatwoCEFBrowserView(frame: .zero, sharingContextWith: browser,
                                         initialURL: url.absoluteString, actor: .human)
        BrowserHumanInteraction.shared.configure(page, onForegroundTab: { [weak page] url in
            page?.loadURLString(url.absoluteString)
        }) { [weak page] url in page?.loadURLString(url.absoluteString) }
        return page
    }

    /// W183 R9 審查（GPT-6 #3）：用這一份腳本建立瀏覽器（已經在跑＝不動）。
    func start(script: String) throws {
        guard browser == nil else { return }
        self.script = script
        try start()
    }

    /// 照 OS 瀏覽器開分頁的同一套步驟：找設定檔 → 取租約（一個設定檔同時只給一個宿主）→ 初始化核心 → 建頁面。
    func start() throws {
        guard browser == nil else { return }
        var resolved = try TatwoCEFProfileLocationResolver.resolve(profile: profile)
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if ["w248webspace", "w265dmchatgpt", "w269gptchrome", "w294e"].contains(env["TATWO2_SELFTEST"] ?? ""), NativeStagingIsolation.isEnabled(env),
           NativeStagingIsolation.validationError(env) == nil,
           Bundle.main.bundleIdentifier == "ai.tatwo.tatwo2.staging.w248" {
            resolved = selfTestLocation
        }
        #endif
        guard let location = resolved else {
            throw TapPodError.profileUnavailable
        }
        if lease == nil {
            lease = try TatwoCEFProfileLocationResolver.prepareForRuntime(location)
        }
        TatwoCEFRuntime.configureRendererProcessLimit(BrowserMemorySettings.load().limit() ?? 0)
        try TatwoCEFRuntime.initialize(
            withRootCachePath: location.rootCachePath,
            helperExecutablePath: location.helperExecutablePath,
            logFilePath: location.logFilePath,
            bundledDenyListPath: BrowserBundledHostDenyList.verifiedResourceURL().path)
        let view = try TatwoCEFBrowserView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 800),
            persistentProfile: location.persistentProfilePath,
            initialURL: ChatGPTWebSpace.isEnabled ? homeURL.absoluteString : "about:blank", actor: .human)
        guard view.configurePod(script: script) else { throw TapPodError.scriptRejected }
        view.onPodEvent = { [weak self] json in
            guard let self else { return }
            if json.hasPrefix(Self.processPrefix) {
                self.rendererPID = Self.processID(json)
            } else {
                self.onEvent?(json)
            }
        }
        // 登入流程開的新視窗（例如用 Google 登入）留在同一個 Pod 裡，登入資料才會存在這個 Pod。
        BrowserHumanInteraction.shared.configure(view, onForegroundTab: { [weak view] url in
            view?.loadURLString(url.absoluteString)
        }) { [weak view] url in
            view?.loadURLString(url.absoluteString)
        }
        // W183 R9 審查（GPT-6 #10、N8）：網頁要選檔（例如「上傳外掛程式封存檔」）＝只給人用的檔案選擇器；不接＝CEF 一律取消。
        // 瀏覽器核心作廢網頁功能（導頁開始、渲染程序結束、關閉、AI 開始操作）＝選檔視窗一起取消、回覆結清、「新增」那一次結束。
        Self.wireWebFeatures(view, picker: filePicker)
        // W183 R6b：popup 照舊（手勢保護、原本的設定都不動），另外通知一聲；主框架的網址給連線流程核對配對頁。
        let configuredPopup = view.onPopupCreated
        view.onPopupCreated = { [weak self] popup in
            configuredPopup?(popup)
            self?.onPopup?(popup)
        }
        view.stateHandler = { [weak self] committed, generation, _, _, loading, _, status, _, _, _ in
            self?.onMainFrame?(committed, generation, loading, status)
            if self?.browser?.canShareRequestContext == true { self?.spaceDidChange() }
        }
        browser = view
        place()
        if !ChatGPTWebSpace.isEnabled { view.loadURLString(homeURL.absoluteString) }
    }

    /// 某個畫面要顯示（或墊著）Pod：最後叫的那個拿到（W183 R8b 審查：受保護的呈現進行中＝只記下，放掉之後才輪到它）。
    func claim(_ container: NSView, presentsPage: Bool = true) {
        hosts.removeAll { $0.view == nil || $0.view === container }
        hosts.append(Host(view: container, presentsPage: presentsPage))
        place()
    }

    /// 畫面不要了：回到前一個還在的畫面，都沒有就收回停泊視窗（仍在跑，只是看不到）。
    func release(_ container: NSView) {
        hosts.removeAll { $0.view == nil || $0.view === container }
        place()
    }

    /// 有沒有任何畫面正拿著 Pod（拿著就不休眠）。W183 R8b 審查：受保護的呈現進行中也算（連線流程要用它）。
    var isHosted: Bool { !guards.isEmpty || hosts.contains { $0.view?.window != nil } }

    // MARK: W183 R8b 審查（GPT-6、Claude）：受保護的呈現（私訊框 Browser 的「ChatGPT Dev」分頁）
    // 拿著的時候 Pod 只放在受保護的那一格（沒有格子＝停泊視窗）：別的畫面（ChatGPT Space、TAP 設定的網頁版視窗）claim 只記下，
    // 搬不走真的頁面；主框架只准 https（CEF 的 httpsOnly）。全部放掉才回到最後 claim 的畫面、解除只准 https。

    private final class Guard {
        let id: UUID
        weak var view: NSView?
        init(_ id: UUID) { self.id = id }
    }
    private var guards: [Guard] = []

    /// 受保護的呈現進行中（連接器看這個決定 Pod 另開的視窗要不要收進 Browser、當敏感頁）。
    var isGuardedPresentation: Bool { !guards.isEmpty }

    /// 開始一份受保護的呈現（回租約編號）。
    func beginGuardedPresentation() -> UUID {
        let id = UUID()
        guards.append(Guard(id))
        browser?.httpsOnly = true
        place()
        return id
    }

    /// 這份租約的格子（nil＝拿下來：Pod 收進停泊視窗，不給別的畫面）。每次叫都會把 Pod 放回來（被搬走過、Pod 重開過）。
    func showGuarded(_ container: NSView?, lease: UUID) {
        guard let entry = guards.first(where: { $0.id == lease }) else { return }
        entry.view = container
        if container != nil { browser?.httpsOnly = true }
        place()
        if placementTarget == nil { filePicker.invalidate() }   // W183 R9 審查：Pod 從分頁拿下來＝還開著的選檔視窗取消
    }

    /// 結束這份受保護的呈現；全部結束＝回到最後 claim 的畫面、解除只准 https。
    func endGuardedPresentation(_ lease: UUID) {
        guard let index = guards.firstIndex(where: { $0.id == lease }) else { return }
        guards.remove(at: index)
        if guards.isEmpty { browser?.httpsOnly = false }
        if guards.isEmpty { filePicker.invalidate() }   // W183 R9 審查：分頁關了＝還開著的選檔視窗取消（不留給別的畫面）
        place()
    }

    /// W183 R9 審查（GPT-6 #10）：選檔視窗能不能開——Pod 正受保護地放在私訊框 Browser 的分頁裡、那一格在看得到的視窗裡、
    /// 瀏覽器是人在用（不是 AI 在操作）。Pod 墊在畫面外、收在停泊視窗時的選檔要求不會是使用者按的：一律不開。
    private func filePickerContext() -> TapPodFilePicker.Context {
        guard let browser, !guards.isEmpty, let target = placementTarget, browser.superview === target,
              let window = browser.window, window.isVisible, !browser.isHiddenOrHasHiddenAncestor else { return .closed }
        return TapPodFilePicker.Context(guarded: true, visible: true,
                                        human: browser.browserActor == .human && !browser.agentControlled, window: window)
    }

    /// Pod 現在該放在哪一格（nil＝停泊視窗）。受保護的呈現進行中＝最新一份有格子的租約（都沒有＝停泊），不看別的畫面。
    var placementTarget: NSView? {
        if connectorPlacement != nil { return nil }
        if !guards.isEmpty { return guards.last(where: { $0.view?.window != nil })?.view }
        return hosts.last(where: { $0.view?.window != nil })?.view
    }

    /// Pod 渲染程序目前的實體記憶體（位元組）；沒在跑或讀不到回 nil，不假裝是 0。
    var footprintBytes: UInt64? {
        guard browser != nil, let pid = rendererPID else { return nil }
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    private func place() {
        guard let browser else { return }
        defer { updateVisibility() }
        let target = placementTarget ?? parkingView()   // W183 R8b 審查：受保護的呈現優先
        guard browser.superview !== target else { return }
        browser.removeFromSuperview()
        browser.frame = target.bounds
        browser.autoresizingMask = [.width, .height]
        target.addSubview(browser)
    }

    private static let processPrefix = #"{"type":"process","#
    static func processID(_ json: String) -> pid_t? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    /// 執行 Tap 自己的指令（只有 Pod 瀏覽器會接受）。
    func run(_ javascript: String) {
        browser?.runPodCommand(javascript)
    }

    func restoreDisplayedPage(_ url: URL) {
        browser?.loadURLString(url.absoluteString)
    }

    /// 關掉網頁、還回設定檔租約。登入資料留在設定檔裡，下次開不用重登。
    func stop() {
        connectorViewportUsers = 1
        endConnectorViewport()
        guard let browser else { return }
        self.browser = nil
        rendererPID = nil
        browser.onPodEvent = nil
        browser.stateHandler = nil   // W183 R6b
        Self.unwireWebFeatures(browser, picker: filePicker)   // W183 R9 審查（GPT-6 #10、N8）
        let lease = self.lease
        self.lease = nil
        let pages = [browser] + [spacePage, dotsSpacePage].compactMap { $0 }
        spacePage = nil
        dotsSpacePage = nil
        var pending = pages.count
        closingBrowsers += pending
        // A sibling retains the native context after the root closes; keep its lease too.
        for page in pages {
            page.closeBrowser(completion: { [weak self] in
                Task { @MainActor in
                    page.removeFromSuperview()
                    pending -= 1
                    if pending == 0, let lease { TatwoCEFProfileLeaseRegistry.shared.release(lease) }
                    self?.closingBrowsers -= 1
                }
            })
        }
    }

    #if DEBUG
    func parkingSharingTypeForSelfTest() -> NSWindow.SharingType {
        _ = parkingView()
        let sharing = parking!.sharingType
        parking?.close(); parking = nil
        return sharing
    }
    #endif
    private func parkingView() -> NSView {
        if let view = parking?.contentView { return view }
        let frame = NSRect(x: -30_000, y: -30_000, width: 1100, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = content
        parking = window
        return content
    }
}

/// W183 R9 審查（GPT-6 N8）：Pod 瀏覽器的兩條網頁功能接線（選檔、作廢）。抽成協定：自測用假的宿主驗「接線」本身
/// （CEF 叫 onWebFeaturesInvalidated → 選檔視窗取消、回覆結清、「新增」那一次結束），不只手動叫 picker 的 invalidate()。
@MainActor
protocol TapPodWebFeatureHost: AnyObject {
    var onFileDialog: TatwoCEFFileDialogHandler? { get set }
    var onWebFeaturesInvalidated: (() -> Void)? { get set }
}

extension TatwoCEFBrowserView: TapPodWebFeatureHost {}

extension TapWebPod {
    /// 接上（start 用）：換了一個瀏覽器＝上一個還開著的選檔視窗先取消（世代）；選檔只走人用的選擇器；
    /// 核心作廢網頁功能＝選擇器作廢（sheet 收掉、回覆結清），再通知原生（「新增」那一次結束、放掉 Pod 的操作租約）。
    static func wireWebFeatures(_ host: any TapPodWebFeatureHost, picker: TapPodFilePicker) {
        picker.invalidate()
        host.onFileDialog = { [weak picker] mode, title, defaultPath, filters, multiple, completion in
            guard let picker else { completion(nil); return }
            picker.request(mode: mode, title: title, defaultPath: defaultPath, filters: filters, multiple: multiple) { completion($0) }
        }
        host.onWebFeaturesInvalidated = { [weak picker] in picker?.browserInvalidated() }
    }

    /// 拆掉（stop 用）：之後的選檔一律取消（CEF 沒有接手的＝取消）；還開著的選檔視窗取消。
    static func unwireWebFeatures(_ host: any TapPodWebFeatureHost, picker: TapPodFilePicker) {
        host.onFileDialog = nil
        host.onWebFeaturesInvalidated = nil
        picker.invalidate()
    }
}
