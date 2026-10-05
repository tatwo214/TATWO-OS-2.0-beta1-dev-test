#if DEBUG
import AppKit
import Combine
import Foundation

/// `TATWO2_SELFTEST=w183browser`：無頭驗收 W183 R8b 私訊框的 Browser（第三顆圓鈕、手機式瀏覽器、授權頁都開在這裡）。
/// 只在完整隔離的 staging 環境跑；不建真的私訊框視窗、不開網頁（頁面、Pod、popup 都是記憶體替身；真的 CEF 起不來記 SKIP，不當通過）。
enum DMBrowserAcceptance {
    final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: String = "") {
            if condition { passed += 1 } else { failed += 1 }
            print("W183BROWSER \(condition ? "PASS" : "FAIL") \(label)\(condition || evidence.isEmpty ? "" : " — " + String(evidence.prefix(500)))")
        }
        func skip(_ label: String) {
            skipped += 1
            print("W183BROWSER SKIP \(label)")
        }
    }

    /// 假頁面（Pod、popup、網頁共用）：記下放進哪裡、上一頁／下一頁、關了幾次。
    @MainActor final class FakePage: DMBrowserPage {
        final class KeyView: NSView { override var acceptsFirstResponder: Bool { true } }
        let view: NSView = KeyView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        var attaches = 0, detaches = 0, backs = 0, forwards = 0, closes = 0
        var canGoBack = false
        var canGoForward = false
        var isHumanActor: Bool { true }
        func attach(to container: NSView) {
            guard view.superview !== container else { return }
            attaches += 1
            view.removeFromSuperview()
            view.frame = container.bounds
            container.addSubview(view)
        }
        func detach() {
            guard view.superview != nil else { return }
            detaches += 1
            view.removeFromSuperview()
        }
        func goBack() { backs += 1 }
        func goForward() { forwards += 1 }
        func close() { closes += 1; view.removeFromSuperview() }
    }

    @MainActor final class FakeWebPage: GlobalDMWebPage {
        /// W184 F3（A6）：自測把假頁面整頁畫成可辨識的顏色（檢查拍下來的圖、圖層台裡沒有敏感頁）。
        static var markerColor: NSColor?
        final class Marker: NSView {
            let color: NSColor
            init(frame: NSRect, color: NSColor) {
                self.color = color
                super.init(frame: frame)
            }
            required init?(coder: NSCoder) { nil }
            override func draw(_ dirtyRect: NSRect) {
                color.setFill()
                bounds.fill()
            }
        }
        let view: NSView = FakeWebPage.markerColor.map { Marker(frame: NSRect(x: 0, y: 0, width: 300, height: 400), color: $0) as NSView }
            ?? NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        var closes = 0
        var backs = 0
        /// W184 G2d：原生重新載入的次數（重新載入不關頁、不重開）。
        var reloads = 0
        /// 假裝頁面回報狀態（正式＝CEF 的 stateHandler）。
        var report: (@MainActor (GlobalDMWebPageState) -> Void)?
        var isHumanActor: Bool { true }
        func back() {}
        func goBack() { backs += 1 }
        func reload() { reloads += 1 }
        func close() { closes += 1; view.removeFromSuperview() }
    }

    @MainActor final class FakeWebHost: GlobalDMWebPageHosting {
        var pages: [FakeWebPage] = []
        func openPage(url: URL, onState: @escaping @MainActor (GlobalDMWebPageState) -> Void) async throws -> any GlobalDMWebPage {
            let page = FakeWebPage()
            page.report = onState
            pages.append(page)
            onState(GlobalDMWebPageState(loading: false, error: nil, committedURL: url, stacked: 0))
            return page
        }
    }

    /// 等著叫的收尾（DMBrowserPodPage 的 settled）。
    @MainActor final class Pending { var bodies: [@MainActor () -> Void] = [] }

    /// 放在視窗裡的框（看得到的那一頁、不給擷取要有視窗）。W184 D（GPT-6 審查 #2）：「看得到」要視窗排在畫面上（isVisible）——
    /// 這裡排上去（在螢幕外，看不到也不擋人）；要驗「收起來」就 orderOut。
    @MainActor static func windowed(_ name: String) -> (window: NSWindow, holder: NSView) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 466, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = name
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 466, height: 600))
        window.contentView = holder
        window.orderFrontRegardless()
        return (window, holder)
    }

    /// W184 D（GPT-6 審查 #1）：放手之後視窗照 linger 再擋一小段；要讀還原後的 sharingType 先等它過去（計時器在 run loop 上）。
    @MainActor static func settleShield() {
        RunLoop.main.run(until: Date().addingTimeInterval(WindowCaptureShield.linger + 0.15))
    }

    /// 一個私訊框（隔離的 store、無頭的面板控制器）＋它自己的 Browser（假頁面宿主、假 Pod）。
    @MainActor final class Harness {
        let store: GlobalDMStore
        let panels: GlobalDMPanelController
        let host: FakeWebHost
        /// 開過的假 Pod 頁（照正式的做法只在沒有 Pod 分頁時才要一個）。
        let podPages: HandsLocked<[FakePage]>
        let browser: DMBrowser
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 466, height: 600))
        /// W184 D：私訊框的形態轉換（自測自己送）。
        let transitions: CurrentValueSubject<Bool, Never>

        init(_ name: String) {
            let defaults = UserDefaults(suiteName: "w183browser.\(name).\(UUID().uuidString)") ?? .standard
            let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { true }, directKeys: true)
            let panels = GlobalDMPanelController(store: store, hostsWindows: false)
            let host = FakeWebHost()
            let made = HandsLocked<[FakePage]>([])
            self.store = store
            self.panels = panels
            self.host = host
            podPages = made
            let transitions = CurrentValueSubject<Bool, Never>(false)
            self.transitions = transitions
            // W184 D：「看得到」＝視窗排在畫面上（自測的視窗在螢幕外，蓋不蓋住量不準）；形態轉換由自測送。
            browser = DMBrowser(store: store, openBox: { panels.open() }, pageHost: host,
                                podPage: { let page = FakePage(); made.update { $0.append(page) }; return page },
                                windowShown: { $0.isVisible }, transitions: { transitions.eraseToAnyPublisher() })
            browser.claim(surface)
        }
    }

    /// 這個環境的視窗伺服器真的收 sharingType 嗎（ssh 無頭時設了 .none 之後讀回來、還原都不準）。
    @MainActor static func windowSharingIsObservable() -> Bool {
        let probe = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        let original = probe.sharingType
        probe.sharingType = .none
        let hidden = probe.sharingType == .none
        probe.sharingType = original
        return original != .none && hidden && probe.sharingType == original
    }

    static func loginURL(_ key: String) -> URL {
        URL(string: HandsUIAcceptance.loginLine(key))!
    }

    @MainActor static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil else {
            throw BotLibraryError.invalid("w183browser needs a fully isolated staging environment")
        }
        let check = Checker()
        iconChecks(check)
        await tabChecks(check)
        podChecks(check)
        popupChecks(check)
        presenterChecks(check)
        await notificationChecks(check)
        captureChecks(check)
        // W183 R8b 審查（GPT-6、Claude）：交錯的不給擷取、配對碼綁看得到的那一頁、Pod 受保護的呈現、總開關與 popup 的取消。
        await shieldChecks(check)
        surfaceChecks(check)
        await guardedPodChecks(check)
        await cancelChecks(check)
        await pluginNewMenuChecks(check)   // W183 R9：原生外掛頁「新增 ▾」（DMBrowserR9Acceptance.swift）
        if let staging = environment["TATWO_STAGING_ROOT"].flatMap(HandsPath.realpath) {
            let base = URL(fileURLWithPath: staging).appendingPathComponent("w183browser-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try await flowCodeChecks(check, base)
        } else {
            check(false, "配對碼綁看得到的那一頁（流程）：沒有 staging 根目錄")
        }
        check.skip("iPhone 打開的兩欄：Browser 一次只在一欄（GlobalDMDuoBox 的 onChange；無頭自測沒有 SwiftUI 畫面），主導實機截圖驗")
        check.skip("真的 CEF：Pod 的畫面放進分頁、配對頁 popup 收進分頁（原生視窗不出現）、分頁不在畫面時放回它自己的視窗——這個建置沒有 Chromium，主導實機驗")
        print("W183BROWSER SUMMARY passed=\(check.passed) failures=\(check.failed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    // MARK: - 第三顆圓鈕

    @MainActor static func iconChecks(_ check: Checker) {
        let h = Harness("icons")
        let store = h.store
        let items = store.iconItems()
        let browserItem = items.first { $0.kind == .browser }
        check(items.map(\.kind) == [.assistant, .chatGPT, .browser] && browserItem?.title == "Browser" && browserItem?.isEnabled == true
              && browserItem?.id == "browser",
              "第三顆圓鈕：私訊框上方 TATWO、ChatGPT、Browser（地球）", "\(items.map(\.id))")
        store.select(.chatGPT)
        if let browserItem { store.activate(browserItem) }
        let ringed = store.iconItems().filter { store.isSelected($0) }.map(\.kind)
        check(store.isBrowsing && store.target == .chatGPT && ringed == [.browser]
              && !store.isCurrentTarget(items[1]) && store.isCurrentTarget(browserItem ?? items[0]),
              "點 Browser＝框裡換成手機式瀏覽器；只有地球那顆亮（對象照留）", "\(ringed)")
        store.setDraft("W183BROWSERDRAFT", for: store.target)
        let refused = !store.send() && store.draft(for: store.target) == "W183BROWSERDRAFT"
        store.setDraft("", for: store.target)
        store.activate(items[0])
        check(refused && !store.isBrowsing && store.target == .assistant,
              "Browser 開著時不送出（Enter 給網頁）；點 TATWO＝回對話")
        let others = store.iconItems(showingOthers: true)
        store.showBrowser()
        if let coder = others.first(where: { $0.kind == .coder }) { store.activate(coder) }
        let leftForPicker = !store.isBrowsing && store.isPickerOpen
        store.isPickerOpen = false
        store.showBrowser()
        store.isPickerOpen = true
        store.showBrowser()
        check(leftForPicker && !store.isPickerOpen && store.isBrowsing,
              "打開 Coder 清單＝離開 Browser；切到 Browser＝清單、直達鍵頁收起")
        store.select(.assistant)
    }

    // MARK: - 分頁（Cloudflare 授權頁）

    @MainActor static func tabChecks(_ check: Checker) async {
        let h = Harness("tabs")
        let cancels = HandsLocked(0)
        let first = loginURL("W183BROWSERTABA")
        let closedAtStart = !h.store.isPresented && !h.store.isBrowsing
        let opened = h.browser.open(url: first, purpose: .cloudflareLogin, onCancel: { cancels.update { $0 += 1 } })
        _ = await waitUntil(5) { h.host.pages.count == 1 && h.browser.tabs.first.map { h.browser.page(for: $0.id) != nil } == true }
        let tab = h.browser.activeTab
        check(closedAtStart && opened && h.store.isFloatingOpen && h.store.isBrowsing && tab?.purpose == .cloudflareLogin
              && tab?.startURL == first && h.host.pages.first?.view.superview === h.surface && BrowserSensitivePageGate.isActive,
              "DMBrowser.open：私訊框自動打開並切到 Browser、那個分頁在最前面；頁面放進框裡；敏感（Computer Use 不准以 TATWO 為目標）")
        check(!h.browser.open(url: URL(string: "https://evil.example.org/argotunnel?x=1")!, purpose: .cloudflareLogin)
              && !h.browser.open(url: first, purpose: .chatgptDeveloper) && !h.browser.open(url: first, purpose: .chatgptPairing)
              && !h.browser.open(url: first, purpose: .chatgptLogin) && h.browser.tabs.count == 1,
              "起點照用途驗：只收驗過的 Cloudflare 授權網址；Pod、配對頁、登入視窗不能用網址開")
        check(h.browser.open(url: first, purpose: .cloudflareLogin) && h.browser.tabs.count == 1 && h.host.pages.count == 1,
              "同一個網址再開＝叫到前面（不重開、不多一個分頁）")

        // 分頁不會自己消失：框收起來、切到對話＝分頁留著（頁面拿下來）；框回來、再點 Browser＝放回去。
        let page = h.host.pages.first
        h.store.close()
        h.browser.release(h.surface)
        h.store.select(.assistant)
        try? await Task.sleep(nanoseconds: 1_700_000_000)
        let kept = h.browser.tabs.count == 1 && page?.closes == 0 && page?.view.superview == nil
        h.browser.claim(h.surface)
        let back = page?.view.superview === h.surface
        check(kept && back, "分頁不會自己消失：框收起來、切到對話都留著（頁面拿下來、不銷毀）；框回來就放回去")

        // W183 R8b 審查：完成＝標「完成」、頁面關掉（分頁留著、不再算敏感、上一頁／下一頁停用、網址 pill 不再有網域）；使用者關完成的分頁＝不取消。
        h.browser.markDone(purpose: .cloudflareLogin)
        let doneTab = h.browser.activeTab
        let done = doneTab?.done == true && doneTab?.pageClosed == true && h.browser.tabs.count == 1 && page?.closes == 1
            && page?.view.superview == nil && doneTab?.isSensitive == false && !h.browser.isSensitive && doneTab?.displayHost == ""
            && doneTab?.sourceKnown == false && doneTab?.canGoBack == false && doneTab.map { h.browser.page(for: $0.id) == nil } == true
        page?.report?(GlobalDMWebPageState(loading: false, error: nil, committedURL: URL(string: "https://dash.cloudflare.com/after"), stacked: 0))
        h.browser.goBack()
        let inert = h.browser.activeTab?.pageURL == nil && page?.backs == 0
        h.browser.userClose(h.browser.activeTab?.id ?? UUID())
        check(done && inert && h.browser.tabs.isEmpty && page?.closes == 1 && cancels.get() == 0,
              "markDone：分頁標「完成」、頁面關掉（不留可以操作的登入頁、不再算敏感、上一頁停用）；使用者關掉完成的分頁＝只關（不取消流程）",
              "done=\(done) inert=\(inert)")

        // 還沒完成就關＝取消那個流程；close(purpose:)＝流程結束時由呼叫端關（不叫取消）；分頁全沒了＝私訊框回原狀。
        h.store.close()
        h.store.select(.assistant)
        h.browser.open(url: loginURL("W183BROWSERTABB"), purpose: .cloudflareLogin, onCancel: { cancels.update { $0 += 1 } })
        _ = await waitUntil(5) { h.host.pages.count == 2 }
        let cancelHint = h.browser.activeTab.map { h.browser.closingCancels($0.id) } == true
        h.browser.userClose(h.browser.activeTab?.id ?? UUID())
        let cancelledOnce = cancels.get() == 1 && h.browser.tabs.isEmpty && !h.store.isPresented && !h.store.isBrowsing
        h.browser.open(url: loginURL("W183BROWSERTABC"), purpose: .cloudflareLogin, onCancel: { cancels.update { $0 += 1 } })
        _ = await waitUntil(5) { h.host.pages.count == 3 }
        h.browser.close(purpose: .cloudflareLogin)
        check(cancelHint && cancelledOnce && cancels.get() == 1 && h.browser.tabs.isEmpty && h.host.pages.last?.closes == 1 && !h.store.isPresented,
              "還沒完成就關＝取消那個流程；close(purpose:)＝流程結束時關（不叫取消）；分頁全沒了＝私訊框回原狀（原本關著）")

        // W183 R8b 審查（GPT-6）：兩個流程的授權頁（例如這台的環境登入、遠端主機的登入）＝兩個分頁，不互相換掉；結論只命中自己那一張。
        let localURL = loginURL("W183BROWSERLOCALA"), remoteURL = loginURL("W183BROWSERREMOTEB")
        let localCancels = HandsLocked(0)
        h.browser.open(url: localURL, purpose: .cloudflareLogin, onCancel: { localCancels.update { $0 += 1 } })
        h.browser.open(url: remoteURL, purpose: .cloudflareLogin)
        _ = await waitUntil(5) { h.host.pages.count == 5 }
        let both = h.browser.tabs.count == 2 && localCancels.get() == 0 && h.host.pages[3].closes == 0
        HandsSetup.postCloseLoginPages(only: nil)   // 沒有範圍的結束通知：私訊框不收
        HandsSetup.postLoginPagesDone(only: localURL)
        _ = await waitUntil(3) { h.browser.tab(start: localURL)?.done == true }
        let separate = h.browser.tab(start: localURL)?.done == true && h.browser.tab(start: remoteURL)?.done == false
            && h.browser.tab(start: remoteURL)?.pageClosed == false && h.host.pages[4].closes == 0
        check(both && separate,
              "W183 R8b 審查 兩個流程的授權頁各一個分頁（以起點網址認、不以用途合併：不會把還在跑的換掉）；沒有範圍的通知不收、完成只命中自己那一張",
              "tabs=\(h.browser.tabs.count) localDone=\(h.browser.tab(start: localURL)?.done == true) remoteDone=\(h.browser.tab(start: remoteURL)?.done == true)")
        h.browser.closeAll()

        // 私訊鈕總開關關掉＝全部馬上關、還沒完成的流程一起取消（W183 R8b 審查）；程序收尾（closeAll()）只關、不取消。
        let before = cancels.get()
        h.browser.open(url: loginURL("W183BROWSERTABD"), purpose: .cloudflareLogin, onCancel: { cancels.update { $0 += 1 } })
        _ = await waitUntil(5) { h.host.pages.count == 6 }
        h.store.isEnabled = false
        let closedAll = await waitUntil(1) { h.browser.tabs.isEmpty }
        h.store.isEnabled = true
        let switchCancelled = cancels.get() == before + 1
        h.browser.open(url: loginURL("W183BROWSERTABE"), purpose: .cloudflareLogin, onCancel: { cancels.update { $0 += 1 } })
        h.browser.closeAll()
        check(closedAll && h.host.pages.last?.closes == 1 && switchCancelled && cancels.get() == before + 1,
              "私訊鈕總開關關掉＝分頁全部馬上關、還沒完成的流程一起取消；程序收尾只關", "cancels=\(cancels.get() - before)")
    }

    // MARK: - ChatGPT Pod 的分頁

    @MainActor static func podChecks(_ check: Checker) {
        let h = Harness("pod")
        let cancels = HandsLocked(0)
        let opened = h.browser.openPod(purpose: .chatgptDeveloper, currentURL: URL(string: "https://chatgpt.com/"), onCancel: { cancels.update { $0 += 1 } })
        let tab = h.browser.activeTab
        let pod = h.podPages.get().first
        check(opened && tab?.kind == .pod && tab?.title == "ChatGPT Dev" && tab?.expectedHost == "chatgpt.com" && tab?.displayHost == "chatgpt.com"
              && !(tab?.hostMismatch ?? true) && pod?.view.superview === h.surface && h.store.isBrowsing && h.store.isFloatingOpen && tab?.isSensitive == true,
              "openPod：Pod 的畫面當一個分頁（放進框裡）、自動打開私訊框並切到 Browser；頁面開著＝敏感")
        h.podPages.get().first?.canGoBack = true
        h.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/#settings/Connectors"), generation: 2, loading: false, httpStatus: 200))
        let followed = h.browser.activeTab?.displayHost == "chatgpt.com" && h.browser.activeTab?.canGoBack == true
        h.browser.podFrame(HandsPodFrame(url: URL(string: "https://evil.example.org/x"), generation: 3, loading: false, httpStatus: 200))
        let flagged = h.browser.activeTab?.hostMismatch == true
        h.browser.goBack()
        h.browser.goForward()
        check(followed && flagged && pod?.backs == 1 && pod?.forwards == 1,
              "Pod 分頁的網址 pill 跟著原生回報變（導到別的網域＝標出來）；上一頁、下一頁給 Pod")
        // W183 R8b 審查（GPT-6）：沒有實際來源（空白頁、別的協定、沒有網址）＝尚未確認來源，不沿用舊的網域、不給鎖頭。
        h.browser.podFrame(HandsPodFrame(url: URL(string: "about:blank"), generation: 4, loading: false, httpStatus: 0))
        let blank = h.browser.activeTab
        h.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/"), generation: 5, loading: false, httpStatus: 200))
        h.browser.podFrame(HandsPodFrame(url: nil, generation: 6, loading: false, httpStatus: 0))
        let none = h.browser.activeTab
        check(blank?.sourceKnown == false && blank?.displayHost == "" && blank?.sourceText == "尚未確認來源" && blank?.hostMismatch == false
              && blank.map { DMBrowserAddressPill.symbol($0, warn: false) } == "questionmark.circle"
              && none?.sourceKnown == false && none?.pageURL == nil,
              "W183 R8b 審查 網址 pill：空白頁、沒有網址的回報＝「尚未確認來源」（不給鎖頭、不沿用舊網域、不拿該在的網域頂替）")
        let again = h.browser.openPod(purpose: .chatgptDeveloper)
        check(again && h.browser.tabs.count == 1 && h.podPages.get().count == 1, "再開 Pod 分頁＝同一個（不多開）")
        // W183 R8b 審查（Claude）：這一步不用看 Pod＝Pod 從分頁拿下來（分頁留著一句話、不算敏感）；要看再放回來（新的一格）。
        h.browser.suspendPod()
        let suspended = h.browser.activeTab?.pageClosed == true && h.browser.activeTab?.done == false && h.browser.activeTab?.note != nil
            && pod?.closes == 1 && pod?.view.superview == nil && !h.browser.isSensitive
        _ = h.browser.openPod(purpose: .chatgptDeveloper, currentURL: URL(string: "https://chatgpt.com/"))
        let resumed = h.podPages.get().count == 2 && h.podPages.get().last?.view.superview === h.surface && h.browser.activeTab?.pageClosed == false
        check(suspended && resumed, "W183 R8b 審查 Pod 這一步不用看＝從分頁拿下來（分頁留著、不算敏感）；要看再放回來")
        // 完成＝標「完成」、頁面關掉（Pod 交回、不再 claim、上一頁停用、不算敏感）；選它也不會把 Pod 放回來。
        let second = h.podPages.get().last
        h.browser.markDone(purpose: .chatgptDeveloper)
        if let id = h.browser.activeTab?.id { h.browser.select(id) }
        h.browser.goBack()
        let doneTab = h.browser.activeTab
        let doneClosed = doneTab?.done == true && doneTab?.pageClosed == true && doneTab?.isSensitive == false && !h.browser.isSensitive
            && second?.closes == 1 && second?.view.superview == nil && second?.backs == 0 && h.podPages.get().count == 2
        _ = h.browser.openPod(purpose: .chatgptDeveloper)
        let reset = h.browser.activeTab?.done == false && h.podPages.get().count == 3
        h.browser.userClose(h.browser.activeTab?.id ?? UUID())
        check(doneClosed && reset && cancels.get() == 1 && h.browser.tabs.isEmpty && h.podPages.get().last?.view.superview == nil,
              "Pod 分頁完成＝標「完成」、Pod 交回（選它也不放回來、上一頁停用、不再算敏感）；再連一次＝重新放回來；還沒完成就關＝取消這次連線",
              "done=\(doneClosed) reset=\(reset)")
    }

    // MARK: - Pod 開的配對頁 popup

    @MainActor static func popupChecks(_ check: Checker) {
        let h = Harness("popup")
        _ = h.browser.openPod(purpose: .chatgptDeveloper)
        let popup = FakePage()
        h.browser.adoptPopup(popup, key: 7, expectedHost: "os-for-chatgpt.example.com")
        let tab = h.browser.activeTab
        check(tab?.kind == .popup(7) && tab?.purpose == .chatgptPairing && tab?.title == "TATWO 配對" && popup.view.superview === h.surface
              && h.podPages.get().first?.view.superview == nil && h.browser.tabs.count == 2,
              "Pod 開出的配對頁 popup 收進分頁、在最前面（Pod 的分頁頁面先拿下來）")
        // W183 R8b 審查（GPT-6）：popup 還沒載入（about:blank、opener 寫內容）＝尚未確認來源：不顯示該在的網域、不給鎖頭。
        let unconfirmed = tab?.sourceKnown == false && tab?.displayHost == "" && tab?.sourceText == "尚未確認來源"
            && tab.map { DMBrowserAddressPill.symbol($0, warn: false) } == "questionmark.circle"
        h.browser.podFrame(HandsPodFrame(url: URL(string: "about:blank"), generation: 1, loading: false, httpStatus: 0, popup: true, popupKey: 7))
        let stillUnconfirmed = h.browser.activeTab?.sourceKnown == false && h.browser.activeTab?.displayHost == ""
        check(unconfirmed && stillUnconfirmed, "W183 R8b 審查 popup 還沒載入實際網址（空白頁）＝「尚未確認來源」，不拿主機網域冒充、不給鎖頭")
        if let podTab = h.browser.tabs.first(where: { $0.kind == .pod }) { h.browser.select(podTab.id) }
        let switched = h.podPages.get().first?.view.superview === h.surface && popup.view.superview == nil
        h.browser.focusPopup(key: 7)
        let focused = h.browser.activeTab?.kind == .popup(7) && popup.view.superview === h.surface
        h.browser.podFrame(HandsPodFrame(url: URL(string: "https://os-for-chatgpt.example.com/authorize?x=1"), generation: 2, loading: false,
                                         httpStatus: 200, popup: true, popupKey: 7))
        let pill = h.browser.activeTab?.displayHost == "os-for-chatgpt.example.com" && h.browser.activeTab?.hostMismatch == false
            && h.browser.activeTab.map { DMBrowserAddressPill.symbol($0, warn: false) } == "lock.fill"
        h.browser.podFrame(HandsPodFrame(url: nil, generation: 0, loading: false, httpStatus: 0, popup: true, popupKey: 7, closed: true))
        check(switched && focused && pill && h.browser.tabs.count == 1 && popup.closes == 0 && popup.view.superview == nil,
              "換分頁＝頁面跟著換；focusPopup 叫回前面；popup 網址 pill 跟著實際載入的變；popup 自己關了＝分頁拿掉")
        // 完成：配對頁的分頁標「完成」、頁面關掉；之後 popup 關掉的回報不會把完成的分頁拿掉。
        let paired = FakePage()
        h.browser.adoptPopup(paired, key: 8, expectedHost: "os-for-chatgpt.example.com")
        h.browser.markDone(purpose: .chatgptPairing)
        h.browser.podFrame(HandsPodFrame(url: nil, generation: 0, loading: false, httpStatus: 0, popup: true, popupKey: 8, closed: true))
        check(paired.closes == 1 && h.browser.tabs.first(where: { $0.kind == .popup(8) })?.done == true,
              "連線完成：配對頁的分頁標「完成」、頁面關掉；之後 popup 關掉的回報不會把完成的分頁拿掉")
        // W184 G2 第三輪：流程分頁滿了照樣多開（授權頁、配對頁不因分頁數退到 OS 瀏覽器）；網頁一直開新視窗＝多開到 maxTabs＋popupOverflow
        // 為止（硬上限），超過的不開（關掉）、Browser 上一句話。
        let flood = (0..<(DMBrowser.maxTabs + DMBrowser.popupOverflow + 2)).map { _ in FakePage() }
        for (index, page) in flood.enumerated() { h.browser.adoptPopup(page, key: 100 + index, expectedHost: nil) }
        // 已完成的配對頁（不在最前面）先收掉騰位；之後多開到硬上限；超過的那幾個（最後開的）關掉、沒進分頁。
        let adopted = flood.indices.filter { index in h.browser.tabs.contains { $0.kind == .popup(100 + index) } }
        let refused = flood.indices.filter { flood[$0].closes == 1 }
        let lastOnes: Bool = !refused.isEmpty && refused == Array(adopted.count..<flood.count) && adopted == Array(0..<adopted.count)
        check(h.browser.tabs.count == DMBrowser.maxTabs + DMBrowser.popupOverflow && lastOnes && h.browser.notice == DMBrowser.popupRefusedText
              && !h.browser.tabs.contains { $0.kind == .popup(8) },
              "分頁數有上限（網頁開的新視窗最多多開到 \(DMBrowser.maxTabs + DMBrowser.popupOverflow) 個；超過的不開、Browser 說一句）",
              "tabs=\(h.browser.tabs.count) adopted=\(adopted.count) refused=\(refused) notice=\(h.browser.notice ?? "nil")")
        h.browser.clearNotice()
        h.browser.closeAll()
    }

    // MARK: - 「連上 ChatGPT」的卡片與分頁（HandsConnectPresenter）

    @MainActor static func presenterChecks(_ check: Checker) {
        let h = Harness("presenter")
        let cancels = HandsLocked(0)
        var card: HandsConnectCard? = .loading("讀取中")
        let presenter = HandsConnectPresenter(store: h.store, openBox: { h.panels.open() }, browser: h.browser, hookPod: { _ in },
                                              podURL: { nil }, cancelFlow: { cancels.update { $0 += 1 } }, card: { card })
        presenter.show()
        let sheet = presenter.isShown && !presenter.floatsInBrowser && presenter.covers(h.store) && HandsConnectPresenter.anySensitive
        card = .working("在 ChatGPT 裡準備連接器…")
        presenter.setPodVisible(true)
        let podTab = h.browser.activeTab
        let floats = podTab?.kind == .pod && h.store.isBrowsing && presenter.floatsInBrowser && !presenter.covers(h.store)
        h.browser.adoptPopup(FakePage(), key: 9, expectedHost: nil)
        if let id = podTab?.id { h.browser.select(id) }
        presenter.placePopup(key: 9)
        let popupFront = h.browser.activeTab?.kind == .popup(9)
        check(sheet && floats && popupFront,
              "［連線］確認卡蓋在私訊框上（原生卡片）；按了之後切到 Browser 的 ChatGPT Dev 分頁、卡片浮在分頁下方；配對頁 popup 的分頁叫到前面")
        // 流程結束（取消）：還沒完成的連線分頁收掉（不叫取消：這就是流程自己在收）。
        presenter.hide()
        check(h.browser.tabs.isEmpty && cancels.get() == 0 && !presenter.isShown && !h.store.isPresented,
              "流程結束（取消、關開關）：還沒完成的連線分頁收掉；私訊框回原狀")
        // 成功：分頁標「完成」、頁面關掉、不關分頁（收卡片之後也留著）。
        card = .working("…")
        presenter.show()
        presenter.setPodVisible(true)
        presenter.markDone()
        card = .connected("已連線・L1")
        presenter.hide()
        let kept = h.browser.tabs.count == 1 && h.browser.tabs.first?.done == true && h.browser.tabs.first?.pageClosed == true && cancels.get() == 0
        // 使用者關掉還沒完成的 Pod 分頁＝取消這次連線。
        card = .working("…")
        presenter.show()
        presenter.setPodVisible(true)
        let reopened = h.browser.tabs.count == 1 && h.browser.tabs.first?.done == false && h.browser.tabs.first?.pageClosed == false
        h.browser.userClose(h.browser.activeTab?.id ?? UUID())
        check(kept && reopened && cancels.get() == 1,
              "連線完成＝分頁標「完成」（頁面關掉）、收卡片後照樣留著；再連一次重新放回來；使用者關掉還沒完成的 Pod 分頁＝取消這次連線")
        // W183 R8b 審查（Claude）：這一步不用看 Pod（setPodVisible(false)）＝Pod 從分頁拿下來、分頁留著。
        card = .working("…")
        presenter.show()
        presenter.setPodVisible(true)
        presenter.setPodVisible(false)
        let suspended = h.browser.tabs.first(where: { $0.kind == .pod })?.pageClosed == true && h.browser.tabs.count == 1
        check(suspended, "W183 R8b 審查 連線流程收起 Pod 的畫面＝Pod 從分頁拿下來（分頁留著一句話），只有要你操作的那幾步才放進分頁")
        presenter.hide()
        h.browser.closeAll()
    }

    // MARK: - 授權流程結束的通知

    @MainActor static func notificationChecks(_ check: Checker) async {
        let h = Harness("notify")
        let url = loginURL("W183BROWSERNOTE")
        let other = loginURL("W183BROWSEROTHER")
        h.browser.open(url: url, purpose: .cloudflareLogin)
        _ = await waitUntil(5) { h.host.pages.count == 1 }
        NotificationCenter.default.post(name: DMBrowser.loginPagesNotification, object: other, userInfo: ["state": "done"])
        NotificationCenter.default.post(name: DMBrowser.loginPagesNotification, object: nil, userInfo: ["state": "closed"])
        let ignored = h.browser.activeTab?.done == false && h.browser.tabs.count == 1
        // 網址撤回、還在驗：頁面先關、分頁寫「確認中」（不是完成、不算敏感）；驗過存好才標「完成」。
        HandsSetup.postLoginPagesWithdrawn(only: url)
        let withdrawn = await waitUntil(3) { h.browser.activeTab?.pageClosed == true }
        let waiting = withdrawn && h.browser.activeTab?.done == false && h.host.pages.first?.closes == 1 && !h.browser.isSensitive
            && h.browser.activeTab?.note?.contains("確認中") == true
        HandsSetup.postLoginPagesDone(only: url)
        let done = await waitUntil(3) { h.browser.activeTab?.done == true }
        let stays = h.browser.tabs.count == 1 && h.host.pages.first?.closes == 1
        HandsSetup.postCloseLoginPages(only: url)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let doneKept = h.browser.tabs.count == 1
        // 撤下之後驗不過＝收掉。
        h.browser.open(url: other, purpose: .cloudflareLogin)
        _ = await waitUntil(5) { h.host.pages.count == 2 }
        HandsSetup.postLoginPagesWithdrawn(only: other)
        HandsSetup.postCloseLoginPages(only: other)
        let failedGone = await waitUntil(3) { h.browser.tab(start: other) == nil }
        check(ignored && waiting && done && stays && doneKept && failedGone,
              "授權完成的通知＝授權分頁標「完成」（頁面關掉、分頁留著）；網址撤回＝頁面先關、分頁寫「確認中」；驗不過＝收掉；別的網址、沒有網址的通知不動",
              "ignored=\(ignored) waiting=\(waiting) done=\(done) kept=\(doneKept) failed=\(failedGone)")
        h.browser.closeAll()
    }

    // MARK: - 授權與配對時不給擷取

    @MainActor static func captureChecks(_ check: Checker) {
        let h = Harness("capture")
        let (window, holder) = windowed("capture")
        let observable = windowSharingIsObservable()
        let before = window.sharingType
        var seen: [NSWindow.SharingType] = []
        h.browser.claim(holder)
        _ = h.browser.openPod(purpose: .chatgptDeveloper)
        let protected = h.browser.captureProtectedWindow === window
        seen.append(window.sharingType)
        h.browser.markDone(purpose: .chatgptDeveloper)
        let restored = h.browser.captureProtectedWindow == nil
        settleShield()   // W184 D：放手之後視窗再擋 linger 一小段才還原
        seen.append(window.sharingType)
        h.browser.adoptPopup(FakePage(), key: 3, expectedHost: nil)
        let popupProtected = h.browser.captureProtectedWindow === window
        seen.append(window.sharingType)
        h.browser.release(holder)
        let releasedWithBox = h.browser.captureProtectedWindow == nil
        settleShield()
        seen.append(window.sharingType)
        check(protected && restored && popupProtected && releasedWithBox,
              "授權與配對時不給擷取：還開著的敏感頁在畫面上＝框所在的視窗不給擷取；完成（頁面關掉）、框換了就還原",
              "protected=\(protected) restored=\(restored) popup=\(popupProtected) released=\(releasedWithBox)")
        if observable {
            check(seen == [.none, before, .none, before],
                  "視窗真的不給擷取（sharingType .none）、還原成原本的設定", seen.map { String($0.rawValue) }.joined(separator: ","))
        } else {
            check.skip("這個環境沒有能讀回的視窗伺服器狀態（ssh 無頭：sharingType 設了 .none 之後讀回與還原都不準），視窗真的不給擷取由主導實機驗")
        }
        h.browser.closeAll()
        window.contentView = nil
    }

    // MARK: - W183 R8b 審查：交錯的不給擷取（連線卡片與 Browser 保護同一個視窗）
    // W184 D：截圖只擋授權頁與配對碼——卡片本身不再持有視窗；配對碼在畫面上時卡片持有、授權頁（敏感分頁）在畫面上時 Browser 持有，
    // 兩個持有者照舊以視窗計數（最後一個放手才還原）。

    @MainActor static func shieldChecks(_ check: Checker) async {
        let observable = windowSharingIsObservable()
        let shield = WindowCaptureShield.shared
        // Claude 的步驟（W184 D 版）：確認卡出來（不持有）、Pod 分頁掛進同一個視窗（Browser 持有）、配對碼在畫面上（卡片也持有）；
        // 取消（hide）→ 兩個都放手、視窗回到原本的設定。
        let h = Harness("shield")
        let (window, holder) = windowed("shield")
        let before = window.sharingType
        var card: HandsConnectCard? = .loading("讀取中")
        let presenter = HandsConnectPresenter(store: h.store, openBox: { h.panels.open() }, browser: h.browser, hookPod: { _ in },
                                              podURL: { nil }, cancelFlow: {}, card: { card })
        presenter.cardWindow = window
        presenter.show()
        let cardAlone = presenter.captureProtectedWindow == nil && shield.holders(of: window) == 0 && HandsConnectPresenter.anySensitive
        h.browser.claim(holder)
        card = .working("…")
        presenter.setPodVisible(true)
        card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(60), attemptsLeft: 3,
                                                callbackHost: "chatgpt.com", pairingCode: "12345678", popup: false, surface: -1))
        presenter.setCodeVisible(true)
        let both = h.browser.captureProtectedWindow === window && presenter.captureProtectedWindow === window && shield.holders(of: window) == 2
        presenter.hide()   // 取消：卡片放手、連線分頁收掉
        let restoredAfterCancel = shield.holders(of: window) == 0 && h.browser.captureProtectedWindow == nil
            && presenter.captureProtectedWindow == nil
        settleShield()   // W184 D：放手之後視窗再擋 linger 一小段才還原
        let sharingAfterCancel = window.sharingType
        check(cardAlone && both && restoredAfterCancel,
              "W183 R8b 審查 不給擷取以視窗計數（W184 D：卡片本身不擋、Computer Use 閘門照舊；配對碼在畫面上卡片才持有）：Pod 分頁與配對碼保護同一個視窗，取消後兩個都放手＝視窗回到原本的設定（不會卡在不給擷取）",
              "card=\(cardAlone) both=\(both) restored=\(restoredAfterCancel)")

        // GPT-6 的步驟：確認卡＋Pod＋還沒完成的 Cloudflare 分頁（在最前面）；取消連線但 Cloudflare 分頁留著＝視窗照樣不給擷取；Cloudflare 關了才還原。
        card = .loading("讀取中")
        presenter.show()
        card = .working("…")
        presenter.setPodVisible(true)
        h.browser.open(url: loginURL("W183BROWSERSHIELD"), purpose: .cloudflareLogin)
        _ = await waitUntil(5) { h.host.pages.count == 1 }
        let one = shield.holders(of: window) == 1 && h.browser.captureProtectedWindow === window && presenter.captureProtectedWindow == nil
        presenter.hide()
        let stillShielded = h.browser.tab(for: .cloudflareLogin) != nil && h.browser.captureProtectedWindow === window
            && shield.holders(of: window) == 1
        let sharingWhileCloudflare = window.sharingType
        h.browser.close(purpose: .cloudflareLogin)
        let finallyRestored = shield.holders(of: window) == 0
        settleShield()
        check(one && stillShielded && finallyRestored,
              "W183 R8b 審查 取消連線但還沒完成的 Cloudflare 分頁留著＝視窗照樣不給擷取（卡片放手不會把它放開）；最後一個放手才還原",
              "one=\(one) still=\(stillShielded) restored=\(finallyRestored)")
        if observable {
            check(sharingAfterCancel == before && sharingWhileCloudflare == .none && window.sharingType == before,
                  "W183 R8b 審查 視窗真的照計數：取消後回原值、Cloudflare 還開著時 .none、最後回原值",
                  "\(sharingAfterCancel.rawValue)/\(sharingWhileCloudflare.rawValue)/\(window.sharingType.rawValue)/\(before.rawValue)")
        } else {
            check.skip("W183 R8b 審查 sharingType 真的值：這個環境讀不回（ssh 無頭），計數已驗；主導實機驗")
        }
        h.browser.closeAll()
        window.contentView = nil
    }

    // MARK: - W183 R8b 審查：配對碼綁看得到的那一頁

    @MainActor static func surfaceChecks(_ check: Checker) {
        let h = Harness("surface")
        let (window, holder) = windowed("surface")
        h.browser.claim(holder)
        let presenter = HandsConnectPresenter(store: h.store, openBox: { h.panels.open() }, browser: h.browser, hookPod: { _ in },
                                              podURL: { nil }, cancelFlow: {}, card: { .working("…") })
        _ = h.browser.openPod(purpose: .chatgptDeveloper)
        h.browser.adoptPopup(FakePage(), key: 21, expectedHost: nil)
        h.browser.adoptPopup(FakePage(), key: 22, expectedHost: nil)   // 另一個還沒通過配對驗證的 popup
        h.browser.focusPopup(key: 21)
        let bound = presenter.showsSurface(21) && !presenter.showsSurface(22) && !presenter.showsSurface(-1)
        let pairing = HandsConnectCard.pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(60), attemptsLeft: 3,
                                                                        callbackHost: "chatgpt.com", pairingCode: "12345678", popup: true, surface: 21))
        let reveals = presenter.revealsCode(pairing)
        if let pod = h.browser.tabs.first(where: { $0.kind == .pod }) { h.browser.select(pod.id) }
        let hiddenOnPod = !presenter.showsSurface(21) && !presenter.revealsCode(pairing)
        h.browser.focusPopup(key: 22)
        let hiddenOnOther = !presenter.revealsCode(pairing)
        h.browser.focusPopup(key: 21)
        h.browser.isShowingTabList = true
        let hiddenOnList = !presenter.revealsCode(pairing)
        h.browser.isShowingTabList = false
        let back = presenter.revealsCode(pairing)
        h.browser.release(holder)
        let hiddenWhenBoxGone = !presenter.revealsCode(pairing)
        h.browser.claim(holder)
        h.browser.markDone(purpose: .chatgptPairing)
        let hiddenWhenDone = !presenter.revealsCode(pairing)
        check(bound && reveals && hiddenOnPod && hiddenOnOther && hiddenOnList && back && hiddenWhenBoxGone && hiddenWhenDone,
              "W183 R8b 審查 配對碼只在綁住的那一頁正是現在看得到的那一頁時顯示：切到 ChatGPT Dev、另一個 popup、開分頁清單、框收起來、頁面關了＝遮起來；切回來才顯示",
              "bound=\(bound) pod=\(hiddenOnPod) other=\(hiddenOnOther) list=\(hiddenOnList) back=\(back) gone=\(hiddenWhenBoxGone) done=\(hiddenWhenDone)")
        h.browser.closeAll()
        window.contentView = nil
    }

    // MARK: - W183 R8b 審查：Pod 受保護的呈現（別的畫面搶不走、拿下來＝停泊、帶回首頁之後才結束）

    @MainActor static func guardedPodChecks(_ check: Checker) async {
        let pod = TapWebPod(podID: "w183browser", profileID: UUID(), homeURL: URL(string: "https://chatgpt.com/")!, script: "")
        let space = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let settings = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        pod.claim(space)
        let normal = pod.placementTarget === space && !pod.isGuardedPresentation
        let pending = Pending()
        let page = DMBrowserPodPage(pod: pod, settled: { pending.bodies.append($0) })
        page.attach(to: box)
        let inBox = pod.placementTarget === page.view && pod.isGuardedPresentation && pod.isHosted
        pod.claim(settings)   // 別的畫面（TAP 設定的網頁版視窗、ChatGPT Space）又叫了一次
        let notStolen = pod.placementTarget === page.view
        page.attach(to: box)   // 下一次放進框裡（updateNSView）：照樣在這一格
        page.detach()
        let parked = pod.placementTarget == nil && pod.isGuardedPresentation
        page.attach(to: box)
        let back = pod.placementTarget === page.view
        page.close()
        let heldUntilSettled = pod.placementTarget == nil && pod.isGuardedPresentation && pending.bodies.count == 1
        for body in pending.bodies { body() }
        let handedBack = pod.placementTarget === settings && !pod.isGuardedPresentation
        pod.release(settings)
        let previous = pod.placementTarget === space
        check(normal && inBox && notStolen && parked && back && heldUntilSettled && handedBack && previous,
              "W183 R8b 審查 Pod 受保護的呈現：在 Browser 分頁時別的畫面搶不走；拿下來＝停泊（不給別的畫面）；分頁關了等連接器放掉、帶回首頁之後才交回",
              "normal=\(normal) box=\(inBox) stolen=\(!notStolen) parked=\(parked) back=\(back) held=\(heldUntilSettled) handed=\(handedBack) prev=\(previous)")

        // 連接器：拿著獨占時等；放掉並帶回首頁之後才叫（沒拿著＝馬上叫）。
        let transport = HandsConnectAcceptance.LeaseTransport()
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let surface = HandsConnectAcceptance.LeaseSurface()
        let connector = ChatGPTConnectorPod(tap: tap, surface: { surface })
        connector.restoreTimeout = 3
        connector.attach()
        surface.commit("https://chatgpt.com/")
        let calls = HandsLocked(0)
        connector.whenSettled { calls.update { $0 += 1 } }
        let immediate = calls.get() == 1
        let acquired = await connector.acquireExclusive(timeout: 1)
        connector.whenSettled { calls.update { $0 += 1 } }
        let waited = calls.get() == 1
        connector.releaseExclusive()
        let settled = await waitUntil(5) { calls.get() == 2 }
        check(immediate && acquired && waited && settled && tap.connectorHold == nil,
              "W183 R8b 審查 連接器 whenSettled：沒拿著 Pod＝馬上；拿著＝等放掉並帶回首頁之後才叫（私訊框這時才放掉受保護的呈現）",
              "immediate=\(immediate) waited=\(waited) settled=\(settled)")
    }

    // MARK: - W183 R8b 審查：配對頁分頁與總開關的取消

    @MainActor static func cancelChecks(_ check: Checker) async {
        let h = Harness("cancel")
        let flowCancels = HandsLocked(0)
        let presenter = HandsConnectPresenter(store: h.store, openBox: { h.panels.open() }, browser: h.browser, hookPod: { _ in },
                                              podURL: { nil }, cancelFlow: { flowCancels.update { $0 += 1 } }, card: { .working("…") })
        presenter.show()
        presenter.setPodVisible(true)
        // 配對頁 popup（onCancel＝取消這次連線）；登入視窗（沒有取消：只關那個視窗）。
        h.browser.adoptPopup(FakePage(), key: 31, purpose: .chatgptPairing, expectedHost: nil, onCancel: { flowCancels.update { $0 += 1 } })
        h.browser.adoptPopup(FakePage(), key: 32, purpose: .chatgptLogin, expectedHost: nil)
        let login = h.browser.tabs.first(where: { $0.kind == .popup(32) })
        let hints = login.map { !h.browser.closingCancels($0.id) } == true && login?.title == "ChatGPT 登入"
            && h.browser.tabs.first(where: { $0.kind == .popup(31) }).map { h.browser.closingCancels($0.id) } == true
        if let login { h.browser.userClose(login.id) }
        let loginOnly = flowCancels.get() == 0
        if let pairing = h.browser.tabs.first(where: { $0.kind == .popup(31) }) { h.browser.userClose(pairing.id) }
        let pairingCancels = flowCancels.get() == 1
        check(hints && loginOnly && pairingCancels,
              "W183 R8b 審查 使用者關掉配對頁的分頁＝取消這次連線（不是只收頁面）；登入視窗的分頁只關那個視窗；分頁上的提示照實說",
              "hints=\(hints) login=\(loginOnly) pairing=\(pairingCancels)")
        // 總開關關掉：連線流程只取消一次（Pod 分頁、配對頁同一個流程；卡片那一邊也聽總開關，流程的取消本身冪等）。
        h.browser.adoptPopup(FakePage(), key: 33, purpose: .chatgptPairing, expectedHost: nil, onCancel: { flowCancels.update { $0 += 1 } })
        let before = flowCancels.get()
        h.store.isEnabled = false
        let gone = await waitUntil(1) { h.browser.tabs.isEmpty }
        _ = await waitUntil(1) { flowCancels.get() >= before + 2 }
        h.store.isEnabled = true
        check(gone && flowCancels.get() >= before + 1 && flowCancels.get() <= before + 2,
              "W183 R8b 審查 私訊鈕總開關關掉＝連線分頁全關、這次連線走取消（Browser 一次、卡片那一邊一次；不是只把頁面收掉）",
              "cancels=\(flowCancels.get() - before)")
        presenter.hide()
        h.browser.closeAll()
    }

    // MARK: - W183 R8b 審查：流程只在綁住的那一頁看得到時給碼（HandsConnectFlow ＋ 假私訊框）

    @MainActor static func flowCodeChecks(_ check: Checker, _ base: URL) async throws {
        let world = try HandsConnectAcceptance.World(base, "surface")
        let chatgpt = HandsConnectAcceptance.FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt, popup: 77)
        world.presenter.visibleSurface = 77
        world.flow.offer()
        _ = await waitUntil(5) { HandsConnectAcceptance.isConfirm(world.flow.card) }
        world.flow.connect()
        let shown = await waitUntil(8) { world.pairing?.pairingCode != nil && world.presenter.codeVisible }
        let surface = world.pairing?.surface
        world.presenter.visibleSurface = -1   // 使用者切到 ChatGPT Dev 分頁
        let hidden = await waitUntil(3) { world.pairing?.pairingCode == nil && !world.presenter.codeVisible }
        world.presenter.visibleSurface = 77   // 切回配對頁
        let back = await waitUntil(3) { world.pairing?.pairingCode != nil }
        check(shown && surface == 77 && hidden && back,
              "W183 R8b 審查 流程只在綁住的配對頁正在畫面上時給碼：切到別的分頁＝下一次核對就收起來；切回來再核對一次才給",
              "shown=\(shown) surface=\(String(describing: surface)) hidden=\(hidden) back=\(back)")
        world.flow.cancel(reason: "test_done")
    }
}
#endif
