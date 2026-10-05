#if DEBUG
import AppKit
import Combine
import SwiftUI

// W183 R12 第一批自測（w184forms；主導 1：連線用雙頁排法＋通用的任務版面機制）：
// - 從外直按［連線］、要開網頁＝自動換成內橫；左頁是授權卡（蓋著私訊）、右頁整頁網頁；兩頁的畫面不重疊；結束回到外直、草稿還在。
// - 從內橫開始＝不換；結束也不改。流程中使用者自己換形態＝結束時不改回。正在打字＝延後再換（進、出都一樣）。
// - 收起私訊框再打開：任務、卡片都還在（不取消）；收著的時候連線的網頁不算在畫面上（流程不倒數）。
// - 畫面證據：外直開始自動換成內橫的雙頁畫面（左頁授權卡、右頁網頁）、說明改了的卡（左頁全文＋同意並繼續）。
// W183 R12 第二批（主導 2）：指路的卡（左頁「點一下右邊亮起來的「連接」」；亮框＋箭頭由 Pod 腳本畫在右頁的真網頁上，
// 這裡的右頁是假頁面：亮框只在真 CEF 看得到，腳本畫的樣子由 node 的動態測試驗）。
// 讀畫面的檢查讀不到＝FAIL（不 skip）。

extension GlobalDMFormsAcceptance {
    @MainActor final class TaskRig {
        let store: GlobalDMStore
        let settings: GlobalDMDeskSettings
        let panels: GlobalDMPanelController
        let desk: GlobalDMDeskController
        let browser: DMBrowser
        let flow: HandsConnectFlow
        let presenter: HandsConnectPresenter
        let layout: GlobalDMTaskLayout
        let box = DMBrowserPhoneAcceptance.CardBox()
        var busy = false

        init(_ name: String, _ freshDefaults: (String) -> UserDefaults, form: GlobalDMForm) {
            let store = GlobalDMStore(defaults: freshDefaults("\(name)Store"), chatGPTAllowed: { true })
            let settings = GlobalDMDeskSettings(defaults: freshDefaults("\(name)Desk"))
            settings.form = form
            let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: false)
            let transitions = CurrentValueSubject<Bool, Never>(false)
            let browser = DMBrowser(store: store, openBox: {}, pageHost: DMBrowserPhoneAcceptance.EvidenceWebHost(),
                                    podPage: { DMBrowserPhoneAcceptance.EvidencePage("ChatGPT・TATWO（Primary One）連接器（假頁面）") },
                                    windowShown: { $0.isVisible }, transitions: { transitions.eraseToAnyPublisher() })
            let desk = GlobalDMDeskController(store: store, settings: settings, hotkeys: GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend()),
                                              panels: panels, duo: GlobalDMDuo(defaults: nil), browser: browser)
            self.store = store
            self.settings = settings
            self.panels = panels
            self.browser = browser
            self.desk = desk
            desk.install()
            flow = DMBrowserPhoneAcceptance.inertFlow()
            var rigBusy: () -> Bool = { false }
            layout = GlobalDMTaskLayout(dependencies: .init(
                form: { settings.form }, formChanges: { settings.$form.eraseToAnyPublisher() },
                setForm: { _ = desk.setForm($0, animated: false) },
                isBrowsing: { store.isBrowsing }, setBrowsing: { if $0 { store.showBrowser() } },
                busyTyping: { rigBusy() }, retryDelay: 0.1))
            let box = self.box
            presenter = HandsConnectPresenter(store: store, openBox: { store.openFloating() }, browser: browser, hookPod: { _ in }, podURL: { nil },
                                              cancelFlow: {}, card: { box.card }, taskLayout: layout)
            rigBusy = { [weak self] in self?.busy ?? false }
        }

        /// 框裡的服務（左頁、右頁都用這一份）。
        var services: GlobalDMBrowserServices { GlobalDMBrowserServices(browser: browser, flow: flow, connect: presenter, taskLayout: layout) }

        /// 流程到了要看網頁的那一步：Pod 的分頁、卡片、呈現層叫出來（跟正式一樣：setPodVisible → show）。
        func startConnect(_ card: HandsConnectCard) {
            box.card = card
            _ = browser.openPod(purpose: .chatgptDeveloper)
            browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
            presenter.setPodVisible(true)
            presenter.show()
        }

        func finish() {
            presenter.hide()
            box.card = nil
        }

        func close() {
            desk.uninstall()
            browser.closeAll()
        }
    }

    @MainActor static func taskChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        // T1 從外直開始：要開網頁＝自動換成內橫；左頁是授權卡；結束回到外直、草稿還在。
        let rig = TaskRig("taskFromPortrait", freshDefaults, form: .outerPortrait)
        defer { rig.close() }
        rig.store.select(.assistant)
        rig.store.setDraft("W183R12 還沒送出的草稿", for: .assistant)
        rig.box.card = .confirm(r12Offer(), account: "Primary One")
        rig.presenter.show()   // 確認卡：還不用網頁＝不換形態（外直的底部 sheet）
        let confirmStays = rig.settings.form == .outerPortrait && rig.presenter.showsSheet && !rig.presenter.onLeftPage
        rig.startConnect(.working("在 ChatGPT 建 TATWO 外掛…"))
        await Task.yield()
        let switched = rig.settings.form == .innerLandscape && rig.layout.leftPageTask(for: rig.store) == .connect
            && rig.presenter.onLeftPage && !rig.presenter.showsSheet && !rig.presenter.cardWithBrowser && rig.store.isBrowsingBeside
        check(confirmStays && switched,
              "R12 T1 from outer portrait the confirm card stays a sheet; once the flow needs the web page the phone switches to inner landscape: card on the left page, the whole right page is the web (no card on it)",
              "confirm=\(confirmStays) form=\(rig.settings.form) left=\(String(describing: rig.layout.leftPageTask(for: rig.store))) sheet=\(rig.presenter.showsSheet) withBrowser=\(rig.presenter.cardWithBrowser) beside=\(rig.store.isBrowsingBeside)")

        // T5 收起私訊框再打開：任務、卡片都還在；收著的時候網頁不算在畫面上（流程不倒數）。
        rig.store.openFloating()
        rig.store.isFloatingOpen = false
        let hiddenOK = !rig.presenter.webOnScreen && rig.presenter.isShown && rig.layout.task == .connect
        rig.store.openFloating()
        let reopened = rig.store.isFloatingOpen && rig.presenter.onLeftPage && rig.box.card != nil
        check(hiddenOK && reopened,
              "R12 T5 collapsing the box keeps the task and the card (nothing cancelled; the web is not on screen so the flow does not count down); reopening shows the same left page",
              "hidden=\(hiddenOK) reopened=\(reopened)")

        // 畫出來：左頁與右頁的網頁不重疊；左頁在左欄裡。PNG：外直開始自動換成內橫的雙頁畫面。
        let size = CGSize(width: GlobalDMForm.innerLandscape.size.width, height: GlobalDMForm.innerLandscape.size.height)
        func phone() -> some View {
            GlobalDMPhoneBox(store: rig.store, model: model, surface: .floating, form: rig.settings.form)
                .environment(\.globalDMBrowserServices, rig.services)
                .environment(\.dmFrameProbes, true)
        }
        if let rendered = GlobalDMChatAcceptance.renderSync(phone(), size: size) {
            let page = DMBrowserPhoneAcceptance.probeFrame("task.page", in: rendered.host)
            let web = DMBrowserPhoneAcceptance.probeFrame("page.frame", in: rendered.host)
            let leftWidth = (size.width * DMPhone.duoLeadingFraction).rounded()
            let apart = page.flatMap { p in web.map { !p.insetBy(dx: 0.5, dy: 0.5).intersects($0.insetBy(dx: 0.5, dy: 0.5)) } } ?? false
            let inLeft = page.map { $0.maxX <= leftWidth + 1 && $0.width > leftWidth * 0.8 } ?? false
            let tall = page.map { $0.height >= size.height - DMPhone.headerHeight - 2 } ?? false
            check(apart && inLeft && tall,
                  "R12 T1 drawn: the left page (task card, full column height) and the right page's web frame do not overlap",
                  "page=\(String(describing: page)) web=\(String(describing: web)) left=\(leftWidth)")
            save(rendered, "r12-duo-from-portrait.png")
            rendered.close()
        } else {
            check(false, "R12 T1 drawn: could not render the phone (screen checks must not be skipped)")
        }
        // 說明改了的卡（左頁全文＋同意並繼續）：PNG。
        rig.box.card = .consent(r12OfferConsent)
        if let rendered = GlobalDMChatAcceptance.renderSync(phone(), size: size) {
            let body = DMBrowserPhoneAcceptance.probeFrame("card.consentBody", in: rendered.host)
            let web = DMBrowserPhoneAcceptance.probeFrame("page.frame", in: rendered.host)
            let apart = body.flatMap { b in web.map { !b.intersects($0) } } ?? false
            check(body != nil && apart, "R12 T1 the 'ChatGPT's text changed' card shows the full text on the left page (not over the web page)",
                  "body=\(String(describing: body)) web=\(String(describing: web))")
            save(rendered, "r12-consent-card.png")
            rendered.close()
        } else {
            check(false, "R12 T1 consent card: could not render (screen checks must not be skipped)")
        }
        // W183 R12 第二批（主導 2）：指路的卡：PNG。
        rig.box.card = .working(HandsConnectFlow.gesturePointText)
        let sided = HandsConnectCardContext.live(rig.flow, revealsCode: false, webOnRight: true).sided(HandsConnectFlow.gesturePointText)
        if let rendered = GlobalDMChatAcceptance.renderSync(phone(), size: size) {
            let page = DMBrowserPhoneAcceptance.probeFrame("task.page", in: rendered.host)
            let web = DMBrowserPhoneAcceptance.probeFrame("page.frame", in: rendered.host)
            let apart = page.flatMap { p in web.map { !p.insetBy(dx: 0.5, dy: 0.5).intersects($0.insetBy(dx: 0.5, dy: 0.5)) } } ?? false
            check(sided == "點一下右邊亮起來的「Connect」" && page != nil && apart,
                  "R12 T6 the pointer card: the left page says 「點一下右邊亮起來的「Connect」」 and nothing covers the web page (the ring and arrow are drawn on the real web page by the Pod script)",
                  "sided=\(sided) page=\(String(describing: page)) web=\(String(describing: web))")
            save(rendered, "r12-gesture-card.png")
            rendered.close()
        } else {
            check(false, "R12 T6 pointer card: could not render (screen checks must not be skipped)")
        }
        // W184 R：舊的 innerRight×0.7 夾具只有 Browser 欄，仍用於單欄退路；
        // 真正的 R12 雙頁必須另外畫整支小框，不能把任務卡又放回右頁來修側欄。
        rig.browser.adoptPopup(DMBrowserPhoneAcceptance.EvidencePage("配對（假頁面）"), key: 184,
                               purpose: .chatgptPairing, expectedHost: nil)
        rig.box.card = DMBrowserPhoneAcceptance.tallCards(surface: 184).first { $0.name == "pairing" }?.card
        rig.presenter.show()
        let compactSize = CGSize(width: 623, height: 438)
        let compact = DMBrowserPhoneAcceptance.Clickable(phone().environment(\.dmBrowserChromeShown, .sidebar), size: compactSize)
        await compact.settle()
        let task = compact.frame("task.page"), web = compact.frame("page.frame"), sidebar = compact.frame("side.panel")
        let viewport = compact.frame("side.scroll")
        let separate = task.flatMap { t in web.map { !t.insetBy(dx: 0.5, dy: 0.5).intersects($0) } } == true
        let fullWeb = web.map { $0.height >= compactSize.height - DMPhone.headerHeight - DMBrowserPhone.pageTop - DMBrowserPhone.pageBottom - 1 } == true
        var newTabPressed = false
        if let row = await compact.scrollIntoView("side.newTab") {
            await compact.click(NSPoint(x: row.midX, y: row.midY))
            newTabPressed = rig.browser.activeTab?.isBlank == true
        }
        check(rig.presenter.onLeftPage && separate && fullWeb && compact.frame("card.frame") == nil
              && sidebar != nil && (viewport?.height ?? 0) > 0 && newTabPressed,
              "W184 R R12 smallest real duo: pairing stays on the left, right web stays full-height, sidebar has a nonzero viewport and 新分頁 takes a real mouse click",
              "task=\(String(describing: task)) web=\(String(describing: web)) viewport=\(String(describing: viewport)) pressed=\(newTabPressed)")
        if let bitmap = compact.host.bitmapImageRepForCachingDisplay(in: compact.host.bounds) {
            compact.host.cacheDisplay(in: compact.host.bounds, to: bitmap)
            save(GlobalDMChatAcceptance.Rendered(host: compact.host, window: compact.window, bitmap: bitmap, size: compactSize),
                 "r12-small-duo-pairing.png")
        }
        compact.close()
        rig.box.card = .working("在 ChatGPT 建 TATWO 外掛…")
        rig.finish()
        await Task.yield()
        check(rig.settings.form == .outerPortrait && rig.layout.task == nil && rig.store.draft(for: .assistant) == "W183R12 還沒送出的草稿"
              && !rig.presenter.onLeftPage,
              "R12 T1 when the flow ends the left page goes back to the chat and the phone slides back to outer portrait; the draft is still there",
              "form=\(rig.settings.form) draft=\(rig.store.draft(for: .assistant))")

        // T2 從內橫開始：不換；結束也不改。
        let duo = TaskRig("taskFromDuo", freshDefaults, form: .innerLandscape)
        defer { duo.close() }
        duo.startConnect(.working("在 ChatGPT 建 TATWO 外掛…"))
        let leftAtOnce = duo.settings.form == .innerLandscape && duo.presenter.onLeftPage && duo.layout.original == nil
        duo.finish()
        check(leftAtOnce && duo.settings.form == .innerLandscape,
              "R12 T2 starting in inner landscape: no switch (the card goes straight to the left page) and nothing to restore at the end")

        // T3 流程中使用者自己換形態：結束時不改回。
        let moved = TaskRig("taskMoved", freshDefaults, form: .outerPortrait)
        defer { moved.close() }
        moved.startConnect(.working("在 ChatGPT 建 TATWO 外掛…"))
        let went = moved.settings.form == .innerLandscape
        _ = moved.desk.setForm(.innerPortrait, animated: false)   // 使用者自己換
        let stillTask = moved.layout.task == .connect && moved.presenter.isShown && moved.presenter.cardWithBrowser
        moved.finish()
        check(went && stillTask && moved.settings.form == .innerPortrait,
              "R12 T3 the user changes the form during the flow: the flow goes on (card follows the web in one column) and the end does not change it back",
              "went=\(went) task=\(stillTask) form=\(moved.settings.form)")

        // T4 正在打字：延後再換（進、出都一樣）。
        let typing = TaskRig("taskTyping", freshDefaults, form: .outerPortrait)
        defer { typing.close() }
        typing.busy = true
        typing.startConnect(.working("在 ChatGPT 建 TATWO 外掛…"))
        let waited = typing.settings.form == .outerPortrait && typing.layout.pendingForm == .innerLandscape
        typing.busy = false
        let entered = await DMBrowserAcceptance.waitUntil(2) { typing.settings.form == .innerLandscape }
        typing.busy = true
        typing.finish()
        let heldBack = typing.settings.form == .innerLandscape && typing.layout.pendingForm == .outerPortrait
        typing.busy = false
        let restored = await DMBrowserAcceptance.waitUntil(2) { typing.settings.form == .outerPortrait }
        check(waited && entered && heldBack && restored,
              "R12 T4 while typing or composing the form switch waits and happens when typing stops (entering and restoring alike)",
              "waited=\(waited) entered=\(entered) heldBack=\(heldBack) restored=\(restored)")
    }

    @MainActor static func r12Offer() -> HandsConnectOffer {
        HandsConnectOffer(hostDeviceID: HandsConnectAcceptance.hostID, hostName: "Primary One", publicHost: HandsConnectAcceptance.publicHost,
                          scope: HandsGrantScope(level: 2, projects: [], memory: HandsGrantScope.memoryText(level: 2), allProjects: true),
                          callbackHosts: ["chatgpt.com"], setupEpoch: "epoch-1")
    }

    static let r12OfferConsent = HandsConsentOffer(
        text: "New Plugin Icon (optional) Name Description (optional) Connection Server URL Authentication OAuth Custom MCP servers introduce risk. "
            + "Learn more I understand and want to continue Only connect to MCP servers you trust. An untrusted server may access or steal information "
            + "shared through app use, or trick ChatGPT into using tools in unintended ways, including changing or deleting data. "
            + "Developer mode apps can run actions that change data in your connected accounts. Read the guide Cancel Create",
        links: [HandsConsentOffer.Link(text: "Learn more", origin: "https://help.openai.com"),
                HandsConsentOffer.Link(text: "Read the guide", origin: "https://developers.openai.com")],
        print: "user\n(fixture)")

    /// 畫面證據寫到 TATWO2_SELFTEST_ARTIFACTS（沒有就不寫；檢查本身照樣做）。
    @MainActor static func save(_ rendered: GlobalDMChatAcceptance.Rendered, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"], !folder.isEmpty else { return }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = DMBrowserPhoneAcceptance.save(rendered, name, to: out)
    }
}
#endif
