import AppKit
import Combine

/// W179 E：主視窗縮成桌面圓鈕（⌥⌘↓／App 選單）與恢復（⌥⌘↑／App 選單／圓鈕選單最下面一項）。
/// 縮起＝主視窗 `orderOut`：不走關窗確認（`close()`／`performClose`）、不改啟用政策（Dock 圖示照留），Island 照常。
/// 圓鈕是獨立的非啟用面板：所有桌面與全螢幕 App 上都看得到、可以拖、放開記住位置；點它在旁邊展開私訊框（B 房的浮動框）。
/// 也負責接 Carbon 熱鍵的動作：⌥⌘↓、⌥⌘↑、⌥⌘＋直達鍵、⌘⌥Tab（W184 AB：換形態）。
@MainActor
final class GlobalDMDeskController: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = GlobalDMDeskController()

    /// 熱鍵跟著換：縮成圓鈕時只註冊 ⌥⌘↑，平常只註冊 ⌥⌘↓。
    @Published private(set) var isCollapsed = false { didSet { hotkeys.isCollapsed = isCollapsed } }
    /// W184 AB：形態轉換動畫進行中（房 E 等別的畫面可以看；動畫走完才接受下一次換形態）。
    @Published private(set) var isFormTransitioning = false
    let store: GlobalDMStore
    let settings: GlobalDMDeskSettings
    let hotkeys: GlobalDMHotKeys
    private let panels: GlobalDMPanelController
    private let duo: GlobalDMDuo
    /// W184 AB：內橫右欄看它有沒有分頁（自測換成自己的 DMBrowser）。
    private let browserOverride: DMBrowser?
    private var browser: DMBrowser { browserOverride ?? .shared }
    /// 上一次看到時 Browser 有沒有分頁（分頁全關了，內橫的右欄回到另一個對象）。
    private var hadTabs = false
    private var machine = GlobalDMDeskMachine()
    private weak var collapsedWindow: NSWindow?
    private var bubble: GlobalDMPanel?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private(set) var isInstalled = false

    /// 預設值在 init 裡取（主執行緒）；寫在參數預設值會是 Swift 6 的隔離錯誤。
    init(store: GlobalDMStore? = nil, settings: GlobalDMDeskSettings? = nil, hotkeys: GlobalDMHotKeys? = nil,
         panels: GlobalDMPanelController? = nil, duo: GlobalDMDuo? = nil, browser: DMBrowser? = nil) {
        self.store = store ?? .shared
        self.settings = settings ?? .shared
        self.hotkeys = hotkeys ?? .shared
        self.panels = panels ?? .shared
        self.duo = duo ?? .shared
        self.browserOverride = browser
        super.init()
    }

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.install(store: store)
        panels.floatingAnchor = { [weak self] in self?.bubbleAnchor }
        wireButtonMorph()   // W184 F45
        let center = NotificationCenter.default
        // 縮成圓鈕時主視窗被別的路徑叫出來（點 Dock、通知、「到 ChatGPT Space 登入」）：一樣回到原本的位置與大小。
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // 通知本身不帶進主執行緒的閉包（Swift 6 並行檢查）。
                let window = note.object as? TatwoWorkOSWindow
                MainActor.assumeIsolated {
                    guard let window else { return }
                    self?.mainWindowReturned(window)
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panels.buttonMorph.finish()   // W184 F45：換螢幕時長、縮直接到位（再照新螢幕擺圓鈕）
                self?.placeBubble()
            }
        })
        // 私訊鈕總開關關掉時圓鈕沒有意義：主視窗回來。
        store.$isEnabled.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self, !enabled, self.isCollapsed else { return }
                self.restore()
            }
            .store(in: &cancellables)
        // W184 AB：⌘⌥Tab 只在私訊框看得到時註冊（@Published 在改值之前發佈，用送來的新值算）。
        Publishers.CombineLatest3(store.$isOpen, store.$isFloatingOpen, store.$isDockedVisible)
            .map { open, floating, docked in floating || (open && docked) }
            .removeDuplicates()
            .sink { [weak self] showing in self?.hotkeys.isBoxShowing = showing }
            .store(in: &cancellables)
        // W184 AB：內橫的右欄（另一個對象）跟著框、形態、Browser 分頁走（含它自己的 ChatGPT 使用中租約）；下一輪讀現值。
        let duoTriggers: [AnyPublisher<Void, Never>] = [
            store.$isOpen.map { _ in () }.eraseToAnyPublisher(),
            store.$isFloatingOpen.map { _ in () }.eraseToAnyPublisher(),
            store.$isDockedVisible.map { _ in () }.eraseToAnyPublisher(),
            store.$isBrowsing.map { _ in () }.eraseToAnyPublisher(),
            store.$isBrowsingBeside.map { _ in () }.eraseToAnyPublisher(),
            store.$target.map { _ in () }.eraseToAnyPublisher(),
            settings.$form.map { _ in () }.eraseToAnyPublisher(),
            browser.$tabs.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(duoTriggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncDuo() }
            .store(in: &cancellables)
        panels.formMotion.$isAnimating
            .removeDuplicates()
            .sink { [weak self] animating in self?.isFormTransitioning = animating }
            .store(in: &cancellables)
        // W184 AB（GPT-6 審查 #4、複核 新發現 1、2）：「要看到某個畫面」的入口（帶著開框請求的 panels.open）先過這裡：
        // 倒放先立起、轉換中把整個請求排隊；轉換走完接著做排隊的（撤銷了、目標不在了的丟掉）。
        panels.contentGate = { [weak self, weak panels = self.panels] request in
            guard let self else { panels?.perform(request); return }
            self.showContent(request)
        }
        panels.formMotion.onIdle = { [weak self] in self?.runPendingContent() }
        syncDuo()
    }

    /// W184 AB：內橫才有右欄。Browser 在內橫開到右欄（store.isBrowsingBeside），左欄照常是對話（isBrowsing 不動，送出、Esc 照對話）：
    /// 換進內橫時單欄開著的 Browser 搬到右欄；換出內橫時右欄收掉（單欄回到目前對象）；分頁全關了右欄回到另一個對象。
    /// 右欄是 Browser 時第二個 store 不算看得到（不拿 ChatGPT 租約）。
    func syncDuo() {
        let form = settings.form
        let hasTabs = browser.hasTabs
        store.browsesBeside = form.isDuo
        store.hidesColumns = form == .tent   // W184 G3：倒放時對話欄不在畫面上（ChatGPT 的即時語音要停）
        if form.isDuo {
            if store.isBrowsing {
                store.isBrowsing = false
                store.isBrowsingBeside = true
            }
            if hadTabs, !hasTabs, store.isBrowsingBeside { store.isBrowsingBeside = false }
        } else if store.isBrowsingBeside {
            store.isBrowsingBeside = false
        }
        hadTabs = hasTabs
        let showing = store.isEnabled && store.isShowingBox && form.isDuo
        let rightIsBrowser = GlobalDMDuoLayout.rightShowsBrowser(browsing: store.isBrowsingBeside, hasTabs: hasTabs)
        duo.sync(primary: store, showing: showing && !rightIsBrowser)
    }

    /// App 結束時：Carbon 熱鍵全部移除（與 install 成對）、圓鈕收掉。不記圓鈕狀態，下次開啟照常是主視窗。
    func uninstall() {
        guard isInstalled else { return }
        isInstalled = false
        hotkeys.uninstall()
        hotkeys.onAction = nil
        panels.floatingAnchor = nil
        panels.buttonMorph.cancel()   // W184 F45
        panels.buttonMorph.bubble = nil
        panels.buttonMorph.bubbleWanted = nil
        panels.buttonMorph.onClick = nil
        panels.contentGate = nil
        panels.formMotion.onIdle = nil
        let queued = pendingContent
        pendingContent = []
        for request in queued { request.drop() }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        cancellables = []
        bubble?.orderOut(nil)
    }

    // MARK: - 縮起與恢復

    func collapse() {
        let window = visibleMainWindow()
        guard machine.collapse(enabled: store.isEnabled, frame: window?.frame) else { return }
        collapsedWindow = window
        // 框內「設定直達鍵」正在等按鍵的話先離開那一頁：停靠框跟著主視窗收起，不能讓熱鍵一直暫停著。
        store.isEditingDirectKeys = false
        // 不呼叫 close()／performClose(_:)：那兩條會過中斷確認、收掉視窗；orderOut 只是先收起來，工作照跑。
        window?.orderOut(nil)
        isCollapsed = true
        showBubble()
        panels.reconcile()
    }

    func restore() {
        switch machine.restore() {
        case .notCollapsed:
            // 不在圓鈕狀態時什麼都不做（⌥⌘↑ 這時也沒註冊，不會把 TATWO 拉到前面）。
            return
        case .frame(let frame):
            let window = collapsedWindow ?? NSApp.windows.first { $0 is TatwoWorkOSWindow }
            endCollapse()
            if let window {
                window.setFrame(restorable(frame), display: false)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: nil)
            }
        case .reopen:
            endCollapse()
            NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: nil)
        }
        panels.reconcile()
    }

    private func mainWindowReturned(_ window: TatwoWorkOSWindow) {
        guard isCollapsed, window.isVisible else { return }
        if case .frame(let saved) = machine.restore() {
            let frame = restorable(saved)
            if window.frame != frame { window.setFrame(frame, display: true) }
        }
        endCollapse()
        panels.reconcile()
    }

    /// 縮起時記的位置可能已經不在任何螢幕上（外接螢幕拔掉、解析度變小）：拉回看得到的地方，照樣看得到標題列就原樣。
    private func restorable(_ saved: NSRect) -> NSRect {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        return GlobalDMDeskLayout.restorableFrame(saved: saved, visibleFrames: visibleFrames,
                                                  main: visibleFrames.first ?? saved)
    }

    private func endCollapse() {
        isCollapsed = false
        collapsedWindow = nil
        // 開在圓鈕旁的浮動框跟著收起；主視窗裡的停靠框照 B 房規則原樣回來。
        store.isFloatingOpen = false
        bubble?.orderOut(nil)
        panels.buttonMorph.cancel()   // W184 F45：長、縮到一半恢復主視窗＝外殼拆掉，圓鈕不回來
    }

    private func visibleMainWindow() -> NSWindow? {
        NSApp.windows.first { $0 is TatwoWorkOSWindow && $0.isVisible && !$0.isMiniaturized }
    }

    // MARK: - 直達鍵

    private func perform(_ action: GlobalDMHotKeys.Action) {
        switch action {
        case .collapse: collapse()
        case .restore: restore()
        case .direct(let target): openDirect(target)
        case .cycleForm: cycleForm()
        }
    }

    // MARK: - 形態（W184 AB）

    /// 目前的形態（可觀察：`settings.$form`）。
    var form: GlobalDMForm { settings.form }

    /// W184 AB（GPT-6 審查 #4、複核 新發現 1、2）：排隊中的入口操作——整個請求（開框＋選頁／選對象／設定旗標），轉換動畫走完照順序做。
    private var pendingContent: [GlobalDMOpenRequest] = []
    /// 排隊中、還沒撤銷的有幾個（自測看）。
    var pendingContentCount: Int { pendingContent.filter { !$0.isFinished }.count }

    /// 要看到對話、Browser、直達鍵頁、［連線］卡的入口（直達鍵、到私訊框設定、DMBrowser.reveal、［連線］卡都帶著開框請求經 panels.open 到這裡）：
    /// 倒放顯示不了它們——先立起到外直（照轉換表「立起」與減少動態效果）再做；轉換動畫進行中就把整個請求排隊，走完再做（不丟掉）。
    /// 出列前再驗證：流程已經撤銷、目標不在了、私訊鈕關著＝丟掉（不立起、不開框）。
    func showContent(_ request: GlobalDMOpenRequest) {
        guard !request.isFinished else { return }
        if panels.formMotion.isAnimating {
            pendingContent.append(request)
            return
        }
        guard request.stillWanted(in: store) else { return request.drop() }
        if settings.form == .tent { setForm(GlobalDMForm.tent.next) }
        panels.perform(request)
    }

    /// 房 E 倒放卡上的「打開私訊框」：同一條（倒放先立起、轉換中排隊），框本來就開著（點的是框裡的按鈕）＝不重開，立起之後做 action。
    func showContent(_ action: @escaping @MainActor () -> Void) {
        showContent(GlobalDMOpenRequest(opensBox: false, then: action))
    }

    /// 轉換走完：排隊的照順序做（撤銷的跳過；其中一個又讓倒放立起、開始新的轉換時，後面的再排到那一段走完）。
    private func runPendingContent() {
        guard !panels.formMotion.isAnimating, !pendingContent.isEmpty else { return }
        let queued = pendingContent
        pendingContent = []
        for request in queued { showContent(request) }
    }

    /// ⌘⌥Tab：外直 → 內橫 → 內直 → 倒放 → 外直。W184 F2：轉換中再按＝從現在滑到一半的位置直接轉向下一個（不排隊、不等）。
    func cycleForm() {
        setForm(settings.form.next, animated: true)
    }

    /// 用程式換形態（頁面圓鈕右鍵選單、桌面圓鈕右鍵、房 E 倒放卡上的「打開私訊框」「打開配對頁」）：框看得到就滑過去
    /// （系統「減少動態效果」開著＝淡出、換框、淡入；animated＝false＝直接換）。W184 F2：轉換中也接＝直接轉向（速度連續、不跳）。
    @discardableResult
    func setForm(_ form: GlobalDMForm, animated: Bool = true) -> Bool {
        guard store.isEnabled else { return false }
        let from = settings.form
        guard form != from else { return true }
        let transition = GlobalDMFormTransition.between(from, form, animated: animated,
                                                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        panels.buttonMorph.finish()   // W184 F45：圓鈕長成框的途中換形態＝先到位（框的內容照常），再照 F3 滑
        if transition.style != .instant { panels.prepareForm() }   // W184 F3：形態改之前先拍下舊的樣子（交叉淡換、先出後進用）
        settings.form = form
        syncDuo()
        panels.applyForm(transition)
        return true
    }

    /// ⌥⌘＋直達鍵：打開私訊框並切到那個對象（主視窗看得到開停靠框，否則浮動框／圓鈕旁）。
    /// W184 AB（GPT-6 複核 新發現 1）：開框與切對象是同一個請求——框真的開好之後才切（排隊、停靠框換浮動框都不會弄丟）。
    func openDirect(_ target: GlobalDMTarget) {
        guard store.isEnabled else { return }
        let store = store
        panels.open(GlobalDMOpenRequest(then: {
            store.select(target)
            store.validateTarget()
        }))
    }

    /// 設定頁「到私訊框設定」：打開私訊框，直接到「設定直達鍵」那一頁。
    /// W184 AB（GPT-6 複核 新發現 1）：框真的開好之後才翻到那一頁（停靠框換浮動框的中途兩個框都關著、旗標會被清掉）。
    func openDirectKeySettings() {
        guard store.isEnabled else { return }
        let store = store
        panels.open(GlobalDMOpenRequest(then: { store.isEditingDirectKeys = true }))
    }

    // MARK: - 桌面圓鈕

    /// 縮成圓鈕時圓鈕本體（44pt）的螢幕位置；浮動框開在它旁邊。
    /// W184 F45：框開著時圓鈕藏著（圓鈕長成了框），位置照樣算（框照舊開在圓鈕的位置旁、縮回也回到這裡）。
    private var bubbleAnchor: NSRect? {
        guard isCollapsed, let bubble else { return nil }
        return bubble.frame.insetBy(dx: GlobalDMLayout.margin, dy: GlobalDMLayout.margin)
    }

    private func showBubble() {
        let panel = bubble ?? makeBubble()
        bubble = panel
        placeBubble()
        if !store.isFloatingOpen { panel.orderFrontRegardless() }   // W184 F45：浮動框開著＝圓鈕不出現（框收起、縮回到位才出現）
    }

    /// W184 F45（使用者 09-29 晚：「右下小視窗的時候圓鈕展開成視窗 再縮回圓鈕 不要同時存在」）：浮動框開著時桌面圓鈕不出現；
    /// 打開＝圓鈕長成框、收起＝框縮回圓鈕（GlobalDMButtonMorph）。收起接在 store 改值的那一刻（不 receive(on:)）：
    /// SwiftUI 拿掉框內容的同一次畫面更新，外殼已經在框的位置。
    private func wireButtonMorph() {
        let morph = panels.buttonMorph
        morph.bubble = { [weak self] in
            guard let self, self.isCollapsed else { return nil }
            return self.bubble
        }
        morph.bubbleWanted = { [weak self] in
            guard let self else { return false }
            return self.isCollapsed && !self.store.isFloatingOpen
        }
        // W184 F45 查核 #1：長、縮途中按到外殼或圓鈕本來的位置＝點圓鈕（開↔收；走 closing()／presented() 的轉向）。
        morph.onClick = { [weak self] in self?.bubbleClicked() }
        // @Published 在改值之前發佈：送來 false、現在還是 true＝剛要收起。
        store.$isFloatingOpen
            .sink { [weak self, weak morph] open in
                guard let self, !open, self.store.isFloatingOpen else { return }
                morph?.closing()
            }
            .store(in: &cancellables)
    }

    /// 沒拖過就主螢幕（有選單列那個）右下、內縮 24；拖過就放在記住的位置（夾進螢幕範圍）。
    private func placeBubble() {
        guard let bubble else { return }
        let main = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = GlobalDMDeskLayout.placeBubble(saved: settings.bubbleOrigin,
                                                    visibleFrames: NSScreen.screens.map(\.visibleFrame), main: main)
        let frame = NSRect(x: origin.x - GlobalDMLayout.margin, y: origin.y - GlobalDMLayout.margin,
                           width: GlobalDMLayout.dockedClosedSize.width, height: GlobalDMLayout.dockedClosedSize.height)
        if bubble.frame != frame { bubble.setFrame(frame, display: true) }
        if isCollapsed, store.isFloatingOpen { panels.reconcile() }
    }

    private func makeBubble() -> GlobalDMPanel {
        let panel = GlobalDMPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.worksWhenModal = true
        // 點圓鈕不搶鍵盤焦點；打字在旁邊的私訊框。
        panel.becomesKeyOnlyIfNeeded = true
        panel.canHide = false
        panel.isFloatingPanel = true
        // W179 UI：圓鈕比浮動框高一層：框（含陰影邊）永遠蓋不到圓鈕，圓鈕一直點得到、當收合鈕。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "私訊鈕"
        panel.setAccessibilityIdentifier("tatwo.dm.desk.bubblePanel")
        let view = GlobalDMBubbleView(store: store)
        view.onClick = { [weak self] in self?.bubbleClicked() }
        view.onDrag = { [weak self] in self?.bubbleDragged() }
        view.onDrop = { [weak self] in self?.bubbleDropped() }
        view.makeMenu = { [weak self] in self?.makeBubbleMenu() ?? NSMenu() }
        panel.contentView = view
        return panel
    }

    private func bubbleClicked() {
        guard store.isEnabled else { return }
        if store.isFloatingOpen { store.isFloatingOpen = false } else { store.openFloating() }
    }

    private func bubbleDragged() {
        if store.isFloatingOpen { panels.reconcile() }
    }

    private func bubbleDropped() {
        guard let bubble else { return }
        let dropped = CGPoint(x: bubble.frame.minX + GlobalDMLayout.margin, y: bubble.frame.minY + GlobalDMLayout.margin)
        let main = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        settings.saveBubbleOrigin(GlobalDMDeskLayout.placeBubble(saved: dropped,
                                                                 visibleFrames: NSScreen.screens.map(\.visibleFrame),
                                                                 main: main))
        placeBubble()
    }

    // MARK: - 選單

    /// 圓鈕按右鍵（或按住）：「展開成」四種形態（勾目前的）、分隔線、「恢復主視窗 ⌥⌘↑」。
    func makeBubbleMenu() -> NSMenu {
        let menu = NSMenu(title: "展開成")
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "展開成", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for form in GlobalDMForm.allCases {
            let item = NSMenuItem(title: form.menuTitle, action: #selector(expandFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = form.rawValue
            item.state = settings.form == form ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(restoreMenuItem())
        return menu
    }

    /// App 選單的兩項（AppShell 放進 App 選單）。
    func makeAppMenuItems() -> [NSMenuItem] {
        let collapse = NSMenuItem(title: "縮成私訊鈕", action: #selector(collapseFromMenu(_:)),
                                  keyEquivalent: Self.arrowKey(NSDownArrowFunctionKey))
        collapse.keyEquivalentModifierMask = [.option, .command]
        collapse.target = self
        return [collapse, restoreMenuItem()]
    }

    private func restoreMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "恢復主視窗", action: #selector(restoreFromMenu(_:)),
                              keyEquivalent: Self.arrowKey(NSUpArrowFunctionKey))
        item.keyEquivalentModifierMask = [.option, .command]
        item.target = self
        return item
    }

    private static func arrowKey(_ function: Int) -> String {
        String(utf16CodeUnits: [unichar(function)], count: 1)
    }

    @objc private func expandFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let form = GlobalDMForm(rawValue: raw),
              store.isEnabled else { return }
        setForm(form)
        if !store.isFloatingOpen { store.openFloating() }
    }

    @objc private func collapseFromMenu(_ sender: Any?) { collapse() }

    @objc private func restoreFromMenu(_ sender: Any?) { restore() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(collapseFromMenu(_:)): return store.isEnabled && !isCollapsed
        case #selector(restoreFromMenu(_:)): return isCollapsed
        default: return true
        }
    }
}
