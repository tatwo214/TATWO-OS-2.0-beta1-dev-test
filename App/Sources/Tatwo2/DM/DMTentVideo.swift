import AppKit
import Combine
import SwiftUI

// W184 E（使用者 09-29：「倒放 預設作為影片子畫面」「duo的形式已經ok就照你的設計去做」；spec E1–E3；
// spike 報告 rooms/w183-handoff/w184-e-spike-report.md；施工單 briefs/w184-e-tent.md 的主導裁決）：
// 倒放＝Browser 影片子畫面（第一階段）。倒放框顯示的是那個分頁的整張網頁：搬 TatwoCEFBrowserView 本身（不重載）；
// 只撐滿影片（腳本）、播放控制（暫停、進度條）是下一步。
// - 挑哪個分頁（DMTentPick）：進倒放那一刻＝Browser 工作區選中且在播影片的分頁，否則最近開始播的；已在倒放時不自動換台；
//   「關掉子畫面」後記住那個分頁，它重新開始播才再收；倒放是空狀態時才自動收新開始播的影片，而且那個分頁正在主視窗看得到就不搶。
// - 一律不借（BrowserTentPolicy）：授權頁、Pod、配對頁與登入 popup、AI 分頁與 AI 控制中、敏感頁、非使用者本人操作的頁、睡著的、聊天 session 的。
// - 什麼時候還回：切形態（進倒放等轉換動畫走完才掛上；離開倒放在動畫開始前先還回——@Published 在改值之前送，setForm 在那之後才播動畫）、
//   沒有「看得到的框」超過換手寬限期（框被拿掉＝收起私訊框；停靠框被 orderOut＝主視窗縮到 Dock、被 sheet 蓋住、隱藏；視窗被整個蓋住；
//   停靠↔浮動換手在寬限期內接手就不彈回；GPT-6 審查發現 5）、分頁被關或要睡、主視窗下指令或按「拿回來」、頁面要全螢幕
//   （主機先還回再通知）、AI 控制（借著的時候定時與每次變動重看）。框再出現＝進倒放那一刻（還在播就收回來）。
// - 抽一個影片來源（DMTentVideoSource）：正式版接 Browser 工作區，自測用假的 NSView（無頭建置沒有 CEF）。

// MARK: - 挑分頁（純計算，好測）

enum DMTentPick {
    /// 「關掉子畫面」記下的分頁：它重新開始播（開始時間變了）以前都不收。
    struct Dismissed: Equatable, Sendable {
        let id: String
        let startedAt: Date?
    }

    /// 能收進倒放的：借得到（BrowserTentPolicy）、正在播影片、不是關掉過還沒重新開始播的那個。
    static func candidates(_ tabs: [BrowserLendableTab], dismissed: Dismissed?) -> [BrowserLendableTab] {
        tabs.filter { tab in
            guard BrowserTentPolicy.lendable(tab), tab.isPlayingVideo else { return false }
            if let dismissed, dismissed.id == tab.id, dismissed.startedAt == tab.videoStartedAt { return false }
            return true
        }
    }

    /// 最近開始播的在前（同時開始＝最後用的在前，再同＝照 id，結果固定）。
    static func newerFirst(_ a: BrowserLendableTab, _ b: BrowserLendableTab) -> Bool {
        let x = a.videoStartedAt ?? .distantPast, y = b.videoStartedAt ?? .distantPast
        if x != y { return x > y }
        if a.lastActiveAt != b.lastActiveAt { return a.lastActiveAt > b.lastActiveAt }
        return a.id < b.id
    }

    /// 進倒放那一刻：Browser 工作區選中且在播影片的分頁（正在主視窗看也收：使用者自己換到倒放的）；否則最近開始播的。
    static func onEnter(_ tabs: [BrowserLendableTab], dismissed: Dismissed?) -> String? {
        let pool = candidates(tabs, dismissed: dismissed)
        if let selected = pool.first(where: \.isSelected) { return selected.id }
        return pool.sorted(by: newerFirst).first?.id
    }

    /// 倒放是空狀態時有分頁新開始播：收它——那個分頁正在主視窗看得到就不搶（使用者在主視窗按播放，不會被吸走）。
    static func collectsStart(_ id: String, in tabs: [BrowserLendableTab], dismissed: Dismissed?) -> Bool {
        guard let tab = candidates(tabs, dismissed: dismissed).first(where: { $0.id == id }) else { return false }
        return !tab.isOnScreen
    }

    /// 空狀態那句話：Browser 有影片在播（只是沒收進來：關掉過、正在主視窗看）＝照實說。
    static func playingElsewhere(_ tabs: [BrowserLendableTab]) -> Bool {
        tabs.contains { BrowserTentPolicy.lendable($0) && $0.isPlayingVideo }
    }
}

// MARK: - 框再出現就收回來的資格（純計算，好測）

/// GPT-6 審查新發現 4：框被收起（還掛著、只是看不到）超過寬限期而還回去的那一支，框再出現時收回來的資格。
/// 綁還回當下的樣子；主視窗接手了（在呈現、選過或離開過、導頁或重新整理、暫停後又播）就作廢——不把使用者已經在主視窗
/// 看、在操作、甚至已經導到非影片頁的分頁再吸回倒放。
enum DMTentRestore {
    struct Ticket: Equatable, Sendable {
        let id: String
        /// 頁面世代（主框架導頁就變）＋網址（同一份文件裡換網址也看得到）。
        let navigationGeneration: UInt64
        let pageURL: String?
        /// 主視窗選它、離開它都會碰這個時間。
        let lastActiveAt: Date
        /// 這一段播放開始的時間（停了又播＝不同的一段）。
        let videoStartedAt: Date

        /// 還回當下記下來；那時已經在主視窗呈現、沒在播影片、原生頁面沒了、借不到＝不給資格。
        init?(_ tab: BrowserLendableTab) {
            guard let native = tab.native, !native.isOnScreen, let started = tab.videoStartedAt,
                  BrowserTentPolicy.lendable(tab) else { return nil }
            id = tab.id
            navigationGeneration = native.navigationGeneration
            pageURL = native.pageURL
            lastActiveAt = tab.lastActiveAt
            videoStartedAt = started
        }
    }

    /// 還收得回來嗎：同一個頁面世代與網址（沒導頁、沒重新整理）、主視窗沒選過或離開過它（最後使用時間沒變）、
    /// 這一段播放沒停過（開始播的時間沒變、仍在播）、現在不在主視窗呈現、還借得到。任何一條不符＝主視窗接手了，資格作廢。
    static func stillValid(_ ticket: Ticket, _ tab: BrowserLendableTab?) -> Bool {
        guard let tab, tab.id == ticket.id, let native = tab.native, BrowserTentPolicy.lendable(tab) else { return false }
        return native.navigationGeneration == ticket.navigationGeneration && native.pageURL == ticket.pageURL
            && tab.lastActiveAt == ticket.lastActiveAt && tab.videoStartedAt == ticket.videoStartedAt && !native.isOnScreen
    }
}

// MARK: - 影片來源

/// 倒放的影片從哪裡來（正式＝Browser 工作區；自測＝假的 NSView）。
@MainActor
protocol DMTentVideoSource: AnyObject {
    /// 分頁現在的樣子（每一種不借的情況都在旗標裡；篩選在 BrowserTentPolicy／DMTentPick）。
    func tabs() -> [BrowserLendableTab]
    /// 把這個分頁的畫面搬進 container（不重建、不重新載入）；已經借著＝換到這個 container。借不到＝false。
    func lend(_ id: String, into container: NSView) -> Bool
    /// 放回原分頁容器；focus＝鍵盤還給頁面（只有「回到 Browser」）。
    func giveBack(_ id: String, focus: Bool)
    /// 主視窗切到 Browser 工作區、選這個分頁（nil＝只打開 Browser）、叫到前面。
    func openBrowser(_ id: String?)
    /// 有分頁「開始播影片」（時間已經記好）。
    var starts: AnyPublisher<String, Never> { get }
    /// 分頁有變動（網址、標題、關掉、睡著、播放狀態）。
    var changes: AnyPublisher<Void, Never> { get }
    /// 主機自己還回（分頁要關、主視窗下指令或拿回來、頁面要全螢幕）。
    var returns: AnyPublisher<(tabID: String, reason: BrowserTabReturnReason), Never> { get }
}

/// 正式的影片來源：這台的 Browser 工作區（BrowserWorkSpaceRuntime.shared；聊天旁、聊天 session 的分頁不在裡面）。
@MainActor
final class DMTentBrowserSource: DMTentVideoSource {
    private var runtime: BrowserWorkSpaceRuntime { .shared }

    func tabs() -> [BrowserLendableTab] { runtime.lendableTabs() }

    func lend(_ id: String, into container: NSView) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return runtime.lendTab(uuid, into: container)
    }

    func giveBack(_ id: String, focus: Bool) {
        guard let uuid = UUID(uuidString: id) else { return }
        runtime.giveBackTab(uuid, focus: focus)
    }

    /// 同「打開 TATWO › 記憶」的走法：主視窗叫到前面、切到對話頁、Space 的 Browser 分頁；分頁選取走 Browser 工作區既有的
    /// foregroundTabRequest（同點連結開新分頁；分頁在別的空間先切過去）。主視窗剛打開或剛換到 Browser 時畫面在下一輪才掛上：過一下再送。
    func openBrowser(_ id: String?) {
        let tab = id.flatMap(UUID.init(uuidString:))
        NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: TatwoPage.chat.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        Self.select(tab)
        Task { @MainActor in
            for delay: UInt64 in [350_000_000, 650_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                Self.select(tab)
            }
        }
    }

    /// 切到 Browser（Space 的 Browser 分頁），有分頁就選它。
    private static func select(_ tab: UUID?) {
        NotificationCenter.default.post(name: .tatwoChatSelectMode, object: ChatRunMode.browser.rawValue)
        if let tab { BrowserWorkSpaceRuntime.shared.requestForeground(tab) }
    }

    var starts: AnyPublisher<String, Never> { BrowserVideoTabs.shared.starts.eraseToAnyPublisher() }

    var changes: AnyPublisher<Void, Never> {
        // startedAt 是 @Published（改值之前送）：到下一輪再讀；登記簿的 changes 是改完才送。
        Publishers.Merge(BrowserVideoTabs.shared.$startedAt.map { _ in () }.receive(on: DispatchQueue.main),
                         BrowserTabRegistry.shared.changes)
            .eraseToAnyPublisher()
    }

    var returns: AnyPublisher<(tabID: String, reason: BrowserTabReturnReason), Never> {
        runtime.lentReturns.map { (tabID: $0.tabID.uuidString, reason: $0.reason) }.eraseToAnyPublisher()
    }
}

// MARK: - 倒放的影片（一台一個；停靠框、浮動框的倒放都用它）

@MainActor
final class DMTentVideo: ObservableObject {
    static let shared = DMTentVideo()

    /// 倒放框現在顯示的分頁（nil＝空狀態）。
    @Published private(set) var shown: BrowserLendableTab?
    /// 空狀態時 Browser 有沒有影片在播（只是沒收進來：關掉過、正在主視窗看）——空狀態那句話照實說。
    @Published private(set) var playingElsewhere = false
    /// 正在轉進倒放、走完就會收一支影片進來：這段時間畫面只放黑底（不閃「沒有在播影片」那句）。
    @Published private(set) var entering = false
    /// W184 F／G1（查證 #8）：帶著影片離開倒放（影片在動畫開始前已經還回）：倒放那一層淡出的這一小段只放黑底，不閃空狀態那句。
    @Published private(set) var leaving = false
    /// 「等你核准」按了「稍後」：這一次的核准不再蓋上來（核准結束就重置）。停靠框、浮動框共用。
    @Published var approvalSnoozed = false
    /// 「關掉子畫面」記下的分頁（自測看）。
    private(set) var dismissed: DMTentPick.Dismissed?
    /// 換手寬限期（GPT-6 審查發現 5）：借出的影片沒有「看得到的框」——框被拿掉、停靠框被 orderOut（主視窗縮到 Dock、被 sheet 蓋住、
    /// 隱藏）、視窗被整個蓋住——等這麼久還是沒有才還回原分頁。停靠框↔浮動框換手、sheet 一閃而過時新的框在這段時間裡接手，影片不彈回主視窗。
    let holderGrace: TimeInterval
    /// 借著的時候多久重看一次（分頁資格、AI 控制、框看不看得到；orderOut 這類隱藏不發任何通知）。
    let recheckInterval: TimeInterval

    private let makeSource: @MainActor () -> any DMTentVideoSource
    private var sourceStorage: (any DMTentVideoSource)?
    private var source: any DMTentVideoSource {
        if let sourceStorage { return sourceStorage }
        let made = makeSource()
        sourceStorage = made
        return made
    }
    private let settings: GlobalDMDeskSettings
    private let isTransitioning: @MainActor () -> Bool
    private final class WeakContainer {
        weak var view: DMTentVideoContainer?
        init(_ view: DMTentVideoContainer) { self.view = view }
    }
    private var containers: [WeakContainer] = []
    private var lentID: String?
    private weak var lentContainer: DMTentVideoContainer?
    /// 新的倒放畫面掛上了（換到倒放、打開私訊框、停靠↔浮動換手）：看得到時照「進倒放那一刻」挑一支。
    /// 框只是被收起又出現（sheet、縮到 Dock、被蓋住）不算——不會把使用者正在主視窗看的影片吸進來。
    private var entryPending = false
    /// 框被收起（還掛著、只是看不到）超過寬限期而還回去的那一支：框再出現、而且主視窗沒接手才收回來（DMTentRestore）。
    private var restoreTicket: DMTentRestore.Ticket?
    private var evaluateScheduled = false
    /// 借出的影片沒有看得到的框：換手寬限期倒數中。
    private var orphanTask: Task<Void, Never>?
    private var recheck: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var sourceWatch: Set<AnyCancellable> = []
    private var watchingSource = false

    /// 預設值在 init 裡取（主執行緒）；寫在參數預設值會是 Swift 6 的隔離錯誤。自測換成自己的來源、形態、轉換旗標、寬限期。
    init(source: (@MainActor () -> any DMTentVideoSource)? = nil, settings: GlobalDMDeskSettings? = nil,
         transitions: AnyPublisher<Bool, Never>? = nil, isTransitioning: (@MainActor () -> Bool)? = nil,
         boxChanges: AnyPublisher<Void, Never>? = nil, holderGrace: TimeInterval = 1, recheckInterval: TimeInterval = 1) {
        self.makeSource = source ?? { DMTentBrowserSource() }
        self.settings = settings ?? .shared
        let motion = transitions == nil || isTransitioning == nil ? GlobalDMPanelController.shared.formMotion : nil
        self.isTransitioning = isTransitioning ?? { motion?.isAnimating ?? false }
        self.holderGrace = holderGrace
        self.recheckInterval = recheckInterval
        // 離開倒放：同步還回（@Published 在改值之前送；GlobalDMDeskController.setForm 在這之後才播轉換動畫、藏原生畫面）。
        self.settings.$form
            .sink { [weak self] form in self?.formWillChange(to: form) }
            .store(in: &cancellables)
        // 進倒放：轉換動畫走完才掛上（原生畫面不吃 3D／縮放／裁切）。
        (transitions ?? motion?.$isAnimating.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher())
            .removeDuplicates()
            .sink { [weak self] animating in if animating { self?.transitionStarted() } else { self?.scheduleEvaluate() } }
            .store(in: &cancellables)
        let store = boxChanges == nil ? GlobalDMStore.shared : nil
        let box: AnyPublisher<Void, Never> = boxChanges ?? Publishers.MergeMany([
            store?.$isOpen.map { _ in () }.eraseToAnyPublisher(),
            store?.$isFloatingOpen.map { _ in () }.eraseToAnyPublisher(),
            store?.$isDockedVisible.map { _ in () }.eraseToAnyPublisher(),
            store?.$isEnabled.map { _ in () }.eraseToAnyPublisher(),
        ].compactMap { $0 }).eraseToAnyPublisher()
        box.sink { [weak self] in self?.scheduleEvaluate() }.store(in: &cancellables)
        // 框所在的視窗被整個蓋住／露出來（occlusion）：重看有沒有看得到的框。
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .sink { [weak self] _ in self?.windowVisibilityChanged() }
            .store(in: &cancellables)
    }

    /// 現在借著的分頁（自測看）。
    var lentTabID: String? { lentID }
    /// 影片現在放在哪個框（自測看）。
    var hostingContainer: NSView? { lentContainer }
    /// 借出的影片正在等換手寬限期（沒有看得到的框；自測看）。
    var isAwaitingHolder: Bool { orphanTask != nil }

    /// 看得到的框：掛在視窗上、視窗排在畫面上（沒被 orderOut）、沒縮到 Dock、沒被整個蓋住（occlusion）、自己跟祖先都沒藏。
    /// 借出的影片只待在看得到的框裡；看不到的超過換手寬限期就還回原分頁（GPT-6 審查發現 5）。
    static func isVisibleHolder(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else { return false }
        return !view.isHiddenOrHasHiddenAncestor
    }

    // MARK: 框（倒放畫面的原生容器；停靠框、浮動框各一個，最後掛上、看得到的拿到）

    func claim(_ container: DMTentVideoContainer) {
        ensureSourceWatch()
        containers.removeAll { $0.view == nil }
        if !containers.contains(where: { $0.view === container }) {
            containers.append(WeakContainer(container))
            entryPending = true   // 新的倒放畫面：看得到時照「進倒放那一刻」挑（借著的時候不算）
        }
        scheduleEvaluate()
    }

    /// 框拿掉了（收起私訊框、換形態、停靠↔浮動）：重算。借著影片而沒有看得到的框＝換手寬限期後還回（evaluate 裡，不在這裡直接還）。
    func release(_ container: DMTentVideoContainer) {
        containers.removeAll { $0.view == nil || $0.view === container }
        if containers.isEmpty { restoreTicket = nil }   // 私訊框整個收起：不留「框再出現就收回來」，下次打開照進倒放那一刻挑
        scheduleEvaluate()
    }

    /// 框掛上或拿下視窗。
    func containerMoved(_ container: DMTentVideoContainer) { scheduleEvaluate() }

    /// 最後掛上、而且看得到的框（影片放這裡）。
    private var visibleContainer: DMTentVideoContainer? {
        containers.removeAll { $0.view == nil }
        return containers.last(where: { $0.view.map { Self.isVisibleHolder($0) } ?? false })?.view
    }

    private var hasContainer: Bool {
        containers.removeAll { $0.view == nil }
        return !containers.isEmpty
    }

    // MARK: 使用者按的

    /// 「回到 Browser」：還回（鍵盤給頁面）、主視窗切到 Browser 工作區選那個分頁、叫到前面。
    func backToBrowser() {
        restoreTicket = nil
        guard let id = lentID else {
            source.openBrowser(nil)
            return
        }
        returnLent(focus: true)
        source.openBrowser(id)
    }

    /// 「關掉子畫面」：還回、記住這個分頁（它重新開始播才再收）。
    func dismiss() {
        restoreTicket = nil
        guard let id = lentID else { return }
        dismissed = DMTentPick.Dismissed(id: id, startedAt: source.tabs().first { $0.id == id }?.videoStartedAt)
        returnLent(focus: false)
    }

    /// 空狀態的「打開 Browser」。
    func openBrowser() { source.openBrowser(nil) }

    // MARK: 內部

    private func formWillChange(to form: GlobalDMForm) {
        if form != .tent {
            // 離開倒放：動畫開始前先還回（動畫期間影片在主視窗的分頁裡，不會跟著 3D 動作歪掉）；不等換手寬限期。
            // 查證 #8：帶著影片離開、修正核對 #7：進倒放途中（黑底還在）就轉走——倒放那一層淡出的那一小段都只放黑底。
            if lentID != nil || shown != nil || entering { leaving = true }
            returnLent(focus: false)
            restoreTicket = nil
            entryPending = false
        } else if leaving {
            leaving = false
        }
        // W184 F／G1（查證 #6）：轉換中再換形態（⌘⌥Tab 連按＝轉向）不會再有「開始」（isAnimating 一直是 true）：照傳進來的新形態重算
        // （@Published 在改值之前送：settings.form 這時還是舊的）。
        if isTransitioning() { updateEntering(form) }
        scheduleEvaluate()
    }

    /// 轉換動畫開始：轉進倒放、而且走完會收一支影片進來＝先放黑底（形態已經換好：setForm 先改形態再播動畫；
    /// 倒放的畫面在下一輪才掛上，所以不等框）。動畫只在框看得到時播。
    private func transitionStarted() {
        updateEntering(settings.form)
    }

    /// 轉進（或轉向到）倒放、走完會收一支影片進來＝先放黑底；轉向到別的形態＝不是。
    private func updateEntering(_ form: GlobalDMForm) {
        let value = form == .tent && lentID == nil && DMTentPick.onEnter(source.tabs(), dismissed: dismissed) != nil
        if entering != value { entering = value }
    }

    /// 某個視窗被蓋住或露出來：有框才重看。
    private func windowVisibilityChanged() {
        guard hasContainer else { return }
        scheduleEvaluate()
    }

    private func scheduleEvaluate() {
        guard !evaluateScheduled else { return }
        evaluateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.evaluateScheduled = false
            self.evaluate()
        }
    }

    /// 倒放現在「看得到」：形態是倒放、沒在轉換、有看得到的框。
    private func isActive(_ container: DMTentVideoContainer?) -> Bool {
        settings.form == .tent && !isTransitioning() && container != nil
    }

    func evaluate() {
        let container = visibleContainer
        defer {
            if entering, !isTransitioning() { entering = false }
            if leaving, !isTransitioning() { leaving = false }
            refreshElsewhere()
        }
        guard settings.form == .tent, !isTransitioning() else { return }
        if let id = lentID {
            entryPending = false
            // 已經借著：每次都重看還能不能借（AI 控制、睡著、關掉…）。
            guard validate() else { return }
            guard let container else {
                // 發現 5：沒有看得到的框（框被拿掉、停靠框被 orderOut、主視窗縮到 Dock 或被 sheet 蓋住、視窗被整個蓋住）：
                // 換手寬限期後還是沒有就還回原分頁——不靠框被拆掉才觸發。
                startOrphanGrace()
                return
            }
            cancelOrphanGrace()
            if lentContainer !== container {
                // 停靠框↔浮動框換手：跟著最後接手、看得到的框。
                if source.lend(id, into: container) {
                    lentContainer = container
                    container.applyCovered()
                } else {
                    returnLent(focus: false)
                }
            }
            return
        }
        expireRestoreIfTakenOver()
        guard let container else { return }
        // 框被收起又出現（sheet、縮到 Dock、被蓋住）：寬限期後還回去的那一支，主視窗沒接手才收回來（收之前再核一次）。
        if let ticket = restoreTicket {
            restoreTicket = nil
            if DMTentRestore.stillValid(ticket, source.tabs().first(where: { $0.id == ticket.id })) {
                lend(ticket.id, into: container)
                return
            }
        }
        // 進倒放那一刻（新的倒放畫面掛上而且看得到）：挑一個收進來；之後只收新開始播的。
        guard entryPending else { return }
        entryPending = false
        if let pick = DMTentPick.onEnter(source.tabs(), dismissed: dismissed) { lend(pick, into: container) }
    }

    private func videoStarted(_ id: String) {
        defer { refreshElsewhere() }
        // 已在倒放時不自動換台；空狀態時才收新開始播的（正在主視窗看的不搶；關掉過的要重新開始播才收）。
        guard lentID == nil, let container = visibleContainer, isActive(container),
              DMTentPick.collectsStart(id, in: source.tabs(), dismissed: dismissed) else { return }
        lend(id, into: container)
    }

    private func lend(_ id: String, into container: DMTentVideoContainer) {
        guard source.lend(id, into: container) else { return }
        cancelOrphanGrace()
        restoreTicket = nil
        entryPending = false
        lentID = id
        lentContainer = container
        if dismissed?.id == id { dismissed = nil }
        shown = source.tabs().first { $0.id == id }
        container.applyCovered()
        startRecheck()
    }

    /// 倒放自己還回（切形態、看不到的框過了寬限期、關掉子畫面、回到 Browser、不能再借）。
    private func returnLent(focus: Bool) {
        cancelOrphanGrace()
        guard let id = lentID else { return }
        lentID = nil
        lentContainer = nil
        shown = nil
        stopRecheck()
        source.giveBack(id, focus: focus)
        refreshElsewhere()
    }

    /// 主機自己還回了（分頁要關、主視窗下指令或拿回來、頁面要全螢幕）：跟著變成空狀態。
    /// 要全螢幕而主視窗沒在顯示這個分頁（全螢幕沒開）＝回到 Browser（在主視窗那邊再按一次全螢幕）。
    private func hostReturned(_ id: String, _ reason: BrowserTabReturnReason) {
        guard id == lentID else { return }
        cancelOrphanGrace()
        restoreTicket = nil
        lentID = nil
        lentContainer = nil
        shown = nil
        stopRecheck()
        if case .fullscreen(let started) = reason, !started { source.openBrowser(id) }
        refreshElsewhere()
    }

    /// 借出的影片沒有看得到的框：換手寬限期倒數；時間到還是沒有（或已經不是倒放）＝還回原分頁，有了就照常跟過去。
    private func startOrphanGrace() {
        guard orphanTask == nil else { return }
        let grace = holderGrace
        orphanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.orphanTask = nil
            guard let id = self.lentID else { return }
            if self.visibleContainer == nil || self.settings.form != .tent {
                // 框還掛著、只是看不到（被收起、被蓋住）＝框再出現就收回來；框整個拿掉（收起私訊框）＝不留，下次打開照進倒放那一刻挑。
                let hidden = self.hasContainer && self.settings.form == .tent
                self.returnLent(focus: false)
                // 還回當下記下資格（頁面世代、網址、最後使用時間、這一段播放）；那時主視窗已經在呈現它＝不給。
                self.restoreTicket = hidden ? self.source.tabs().first(where: { $0.id == id }).flatMap(DMTentRestore.Ticket.init) : nil
            } else {
                self.evaluate()
            }
        }
    }

    private func cancelOrphanGrace() {
        orphanTask?.cancel()
        orphanTask = nil
    }

    /// 借著的分頁還能借嗎（AI 控制、睡著、關掉、變成敏感頁…＝馬上還回）；網址、標題跟著更新。
    @discardableResult
    private func validate() -> Bool {
        guard let id = lentID else { return true }
        guard let tab = source.tabs().first(where: { $0.id == id }), BrowserTentPolicy.lendable(tab) else {
            returnLent(focus: false)
            return false
        }
        if shown?.host != tab.host || shown?.title != tab.title { shown = tab }
        return true
    }

    private func refreshElsewhere() {
        let value = lentID == nil && settings.form == .tent && hasContainer && DMTentPick.playingElsewhere(source.tabs())
        if playingElsewhere != value { playingElsewhere = value }
    }

    private func sourceChanged() {
        if lentID != nil { evaluate() } else {
            expireRestoreIfTakenOver()
            refreshElsewhere()
        }
    }

    /// 主視窗接手了（在呈現、選過或離開過、導頁、暫停後又播、不能借了）：「框再出現就收回來」的資格馬上作廢，之後也不會再恢復。
    private func expireRestoreIfTakenOver() {
        guard let ticket = restoreTicket else { return }
        if !DMTentRestore.stillValid(ticket, source.tabs().first(where: { $0.id == ticket.id })) { restoreTicket = nil }
    }

    /// 自測看：框再出現就收回來的資格還在不在。
    var hasRestoreTicket: Bool { restoreTicket != nil }

    /// 借著的時候定時重看（分頁資格、AI 控制、框看不看得到）：orderOut 這類隱藏不發任何通知。
    private func startRecheck() {
        guard recheck == nil else { return }
        let interval = recheckInterval
        recheck = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
                guard let self, self.lentID != nil, !Task.isCancelled else { return }
                self.evaluate()
            }
        }
    }

    private func stopRecheck() {
        recheck?.cancel()
        recheck = nil
    }

    /// 第一次有框掛上才接來源（沒用過倒放就不碰 Browser 工作區）。
    private func ensureSourceWatch() {
        guard !watchingSource else { return }
        watchingSource = true
        source.starts.sink { [weak self] id in self?.videoStarted(id) }.store(in: &sourceWatch)
        source.changes.sink { [weak self] in self?.sourceChanged() }.store(in: &sourceWatch)
        source.returns.sink { [weak self] event in self?.hostReturned(event.tabID, event.reason) }.store(in: &sourceWatch)
    }
}

// MARK: - 倒放畫面的原生容器

/// 影片（CEF 的 NSView）放在這裡：照框的圓角裁（原生網頁不吃 SwiftUI 的 clipShape）；第一下點擊就生效、點進頁面時讓私訊框拿鍵盤；
/// 浮在上面的控制鈕（掛 BrowserChromeHitLayer）的地方把點擊讓出來（BrowserChromeAwareContainerView 是 final，照抄它的 hitTest）；
/// 有卡蓋著時影片藏在下面（聲音照播）。換形態的動畫期間照 GlobalDMNativePageHost 藏起來（倒放離開前已先還回，通常是空的）。
final class DMTentVideoContainer: NSView, GlobalDMNativePageHost {
    weak var video: DMTentVideo?
    weak var hover: DMTentHover?
    /// 有卡蓋著（或［連線］卡蓋著）：影片藏在下面，聲音照播。
    var covered = false {
        didSet { if covered != oldValue { applyCovered() } }
    }
    var cornerRadius: CGFloat = DMPhone.screenRadius {
        didSet { if cornerRadius != oldValue { layer?.cornerRadius = cornerRadius } }
    }
    private var clickMonitor: Any?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = cornerRadius
        setAccessibilityIdentifier("tatwo.dm.tent.video")
    }

    required init?(coder: NSCoder) { nil }

    func applyCovered() {
        for view in subviews { view.isHidden = covered }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if covered { subview.isHidden = true }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window, let superview,
           BrowserChromeHitLayer.LayerView.ownsChromePoint(superview.convert(point, to: nil), in: window) {
            return nil
        }
        return super.hitTest(point)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            hover?.detach()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        video?.containerMoved(self)
        guard window != nil else { return }
        hover?.attach(self)
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.takeKeyIfInside(event) }
            return event
        }
    }

    /// 打字、空白鍵要進得了網頁：點在影片上時讓這個框成為 key（不把整個 App 叫到前景）。
    private func takeKeyIfInside(_ event: NSEvent) {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor, !window.isKeyWindow, !subviews.isEmpty else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { window.makeKey() }
    }

    // 滑鼠移入：CEF 會吃掉 hover 事件，所以用自己的追蹤區＋滑鼠位置判斷（DMTentHover）。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover?.evaluate() }
    override func mouseExited(with event: NSEvent) { hover?.evaluate() }
    override func mouseMoved(with event: NSEvent) {
        hover?.evaluate()
        super.mouseMoved(with: event)
    }
}

/// 滑鼠在不在倒放框裡（照 BrowserChromeReveal：用滑鼠位置判斷，不靠 SwiftUI 的 hover——CEF 的原生 view 會吃掉 hover 事件）。
@MainActor
final class DMTentHover: ObservableObject {
    @Published private(set) var inside = false
    private weak var view: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func attach(_ view: NSView) {
        guard self.view !== view || localMonitor == nil else { evaluate(); return }
        detach()
        guard let window = view.window else { return }
        self.view = view
        window.acceptsMouseMovedEvents = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.evaluate()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    func detach() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        view = nil
        if inside { inside = false }
    }

    func evaluate() {
        guard let view, let window = view.window, window.isVisible else {
            if inside { inside = false }
            return
        }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let now = view.bounds.contains(point)
        if inside != now { inside = now }
    }
}
