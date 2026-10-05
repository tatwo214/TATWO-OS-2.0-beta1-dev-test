import Combine
import Foundation

// W183 R9（使用者 09-29 看了原生 ChatGPT Space 的「外掛」頁：「那很明顯是我們內建chatgpt space/plugins沒有做到這個功能」）：
// 網頁版外掛頁右上角有「新增 ▾」（建立外掛程式／上傳外掛程式封存檔／建立 MCP 應用程式），原生頁補上同一個選單。
// - 三項都把**真的網頁**開在私訊框 Browser 的「ChatGPT Dev」分頁（DMBrowser.openPod(purpose: .chatgptDeveloper)）：
//   Pod 的網頁腳本 pluginNewMenu 到 /plugins、按「新增」、選那一項，只做到對話框打開為止——不填、不勾、不按 Create。
//   表單由使用者在分頁裡自己填（TATWO 不代填、不代勾風險確認）。
// - 要連 TATWO 用 ChatGPT build 的［連線］（會自動填好、有配對保護）；選單上那一項下面有一行提示。
// - 找不到那一項、Pod 起不來、私訊鈕關著：原生頁顯示一句話（不是代號）。
// W183 R9 審查（GPT-6 #3、#8、#9、#10；Claude #7、#8、#9）：
// - 拿 Pod 的操作租約（ChatGPTTap.beginMenuHold，跟連線流程同級）：正在回答、語音中、連線流程拿著＝不做；拿著的時候聊天送出、重新產生、
//   語音、連線流程都等它（雙向）。對話框交給使用者之後照樣拿著，直到：使用者關掉 ChatGPT Dev 分頁、私訊框收起來、網頁的對話框關了
//   （腳本回報）、網頁換了一份、Pod 關了、或 10 分鐘（原生頁一句話）。
// - 每按一次發一個一次性的操作序號（op）：分頁關掉、私訊鈕關掉、逾時＝作廢（pluginNewMenuAbort：還在找選單、按項目的在下一個動作前停手）。
// - 「上傳外掛程式封存檔」：只打開網頁的「新增」選單、標出那一項，原生頁說「在 Browser 分頁自己點它選檔」（Pod 接了只給人用的檔案選擇器）。
// W183 R9 審查（GPT-6 N7、N8）：
// - 從拿到操作租約那一刻就開始看（不等 Pod 回覆）：私訊框收起來、切離 Browser、分頁關了、Pod 關了、網頁換了一份（原生頁面世代）＝撤銷；
//   還在等回覆（網頁的選單延遲掛載）的時候看得更勤，選單出來之前就能停。
// - 瀏覽器核心作廢網頁功能（導頁開始、渲染程序結束、關閉）＝Pod 的選檔視窗取消、回覆結清，這一次跟著結束；世代變了不因為「選檔視窗開著」而跳過。
// W184 D（主導）：「私訊框收起來（或框裡不是 Browser）」改看 ChatGPT Dev 分頁的頁面真的在畫面上（leftDevTab：單欄的 Browser、
//   內橫的右欄都算）；舊的只看主 store 的 isBrowsing，內橫時 Browser 在右欄會被誤判成不在、提早放掉租約。
// W183 R9c（GPT-6 C7）：收起私訊框、切離 Browser＝事件一來就撤銷（訂閱私訊框的變化，一變就用 boxClosed 判斷），不等下一次輪詢；
//   輪詢照舊當備援。boxClosed 仍是判斷式（房 D 會換掉它的內容，例如看頁面實際在不在畫面上），這裡只加觸發。

/// 「新增 ▾」的三項。
enum ChatGPTPluginNewItem: String, CaseIterable, Identifiable, Sendable {
    case plugin
    case archive
    case mcp

    var id: String { rawValue }

    /// 選單上的字（跟網頁版一樣）。
    var title: String {
        switch self {
        case .plugin: "建立外掛程式"
        case .archive: "上傳外掛程式封存檔"
        case .mcp: "建立 MCP 應用程式"
        }
    }

    var systemImage: String {
        switch self {
        case .plugin: "puzzlepiece.extension"
        case .archive: "doc.badge.plus"
        case .mcp: "link"
        }
    }

    /// 「建立 MCP 應用程式」下面那一行小字。
    static let mcpHint = "要連 TATWO：用 ChatGPT build 的［連線］（會自動填好）"
}

@MainActor
final class ChatGPTPluginNewMenu: ObservableObject {
    static let shared = ChatGPTPluginNewMenu()

    /// 原生頁顯示的一句話（打開了、或為什麼沒打開）。
    @Published private(set) var message: String?
    /// 正在開哪一項（選單先停用，不重複送）。
    @Published private(set) var working: ChatGPTPluginNewItem?
    /// 對話框（或選單）已經交給使用者、還拿著 Pod 的操作租約的那一項。
    @Published private(set) var holding: ChatGPTPluginNewItem?

    struct Dependencies {
        /// Pod 醒著、登入了＝nil；否則一句話。needsLogin＝要登入（分頁照樣打開，讓使用者在那裡登入）。
        var prepare: @MainActor () async -> (problem: String?, needsLogin: Bool)
        /// 拿 Pod 的操作租約（拿不到＝nil 與一句話）。
        var beginHold: @MainActor () -> (hold: UUID?, blocker: String?)
        var endHold: @MainActor (UUID) -> Void
        /// 把 Pod 的畫面開成私訊框 Browser 的「ChatGPT Dev」分頁（私訊鈕關著＝false）。onCancel＝使用者在還沒結束時關掉那個分頁
        /// （或關掉私訊鈕總開關）。
        var openTab: @MainActor (_ onCancel: @escaping @MainActor () -> Void) -> Bool
        /// ChatGPT Dev 分頁還在、頁面還開著。
        var tabOpen: @MainActor () -> Bool
        /// 送 pluginNewMenu 給 Pod 的網頁腳本（item＝plugin／archive／mcp、這一次的操作序號、租約）。
        var send: @MainActor (_ item: String, _ op: String, _ hold: UUID) async throws -> [String: Any]
        /// 這一次打開的對話框（或選單）還開著嗎（nil＝問不到：網頁換了一份、Pod 關了、沒回）。
        var watch: @MainActor (_ op: String, _ hold: UUID) async -> Bool?
        /// 撤銷這一次（不等回覆；放掉租約之前送）。
        var abort: @MainActor (_ op: String) -> Void
        /// 私訊框收起來了（停靠框、浮動框都關了，或框裡已經不是 Browser）。W184 D：正式＝ChatGPT Dev 分頁的頁面不在畫面上（leftDevTab）。
        var boxClosed: @MainActor () -> Bool
        /// Pod 還醒著、登入著。
        var podAlive: @MainActor () -> Bool
        /// 使用者自己叫出來的選檔視窗還開著（「上傳外掛程式封存檔」：選檔時網頁的選單已經關了，照樣拿著 Pod）。
        var pickerOpen: @MainActor () -> Bool = { false }
        /// W183 R9 審查（GPT-6 N7）：原生頁面世代——Pod 的網頁換了一份就變（live＝ChatGPTTap 收到新網頁報到的次數）。
        var pageGeneration: @MainActor () -> Int = { 0 }
        /// W183 R9 審查（GPT-6 N8）：接上「瀏覽器核心作廢了網頁功能」的通知（live＝Pod 的檔案選擇器：選檔視窗已取消、回覆已結清之後叫）。
        var armPicker: @MainActor (_ invalidated: @escaping @MainActor () -> Void) -> Void = { _ in }
        /// W183 R9 審查（GPT-6 N7）：還在等 Pod 回覆時多久看一次（比交給使用者之後勤：網頁的選單延遲掛載，出來之前就要能停）。
        var sendWatchEvery: Double = 0.25
        /// W183 R9c（GPT-6 C7）：私訊框的樣子變了（收起來、切離 Browser、換分頁…）的通知：changed 一叫就馬上用 boxClosed 判斷（不等輪詢）。
        /// 回傳的訂閱拿著＝一直收；cancel＝不再收。
        var visibilityChanges: @MainActor (_ changed: @escaping @MainActor () -> Void) -> AnyCancellable = { _ in AnyCancellable {} }
        var now: @MainActor () -> Date = { Date() }
        var pause: @MainActor (Double) async -> Void = { seconds in _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        /// 對話框交給使用者之後最多拿著多久（10 分鐘）。
        var holdLimit: TimeInterval = 600
        /// 多久問一次「還開著嗎」。
        var watchEvery: Double = 1.5

        static func live() -> Dependencies {
            Dependencies(
                prepare: {
                    switch await ChatGPTConnectorPod.shared.prepare() {
                    case .ready: return (nil, false)
                    case .needsLogin: return ("ChatGPT 還沒登入：在私訊框 Browser 的「ChatGPT Dev」分頁登入後再按一次", true)
                    case .unavailable(let reason): return ("ChatGPT 的 Pod 起不來（\(reason)）", false)
                    }
                },
                beginHold: {
                    let tap = ChatGPTTap.shared
                    if let hold = tap.beginMenuHold() { return (hold, nil) }
                    return (nil, tap.menuHoldBlocker ?? "ChatGPT 正在忙；等一下再按")
                },
                endHold: { ChatGPTTap.shared.endMenuHold($0) },
                openTab: { onCancel in
                    let browser = DMBrowser.shared
                    // Pod 的原生回報給 Browser（網址 pill、上一頁；登入視窗收進分頁）——跟連線流程同一套接法。
                    HandsConnectPresenter.hookLivePod(browser, cancel: { HandsConnectFlow.shared.dismiss() })
                    // W183 R9 審查（GPT-6 #10）：Pod 的選檔視窗沒開成（不是人在看的時候、已經開著一個、要資料夾）＝原生頁一句話。
                    ChatGPTTap.shared.pod.filePicker.onRefused = { ChatGPTPluginNewMenu.shared.showFilePickerRefused() }
                    return browser.openPod(purpose: .chatgptDeveloper, currentURL: ChatGPTConnectorPod.shared.mainURL, onCancel: onCancel)
                },
                tabOpen: { DMBrowser.shared.tab(for: .chatgptDeveloper).map { !$0.pageClosed } ?? false },
                send: { item, op, hold in try await ChatGPTTap.shared.pluginNewMenu(item, op: op, hold: hold) },
                watch: { op, hold in await ChatGPTTap.shared.pluginNewMenuOpen(op: op, hold: hold) },
                abort: { ChatGPTTap.shared.abortPluginNewMenu(op: $0) },
                // W183 R9 審查（GPT-6 N7）＋W184 D：ChatGPT Dev 分頁的頁面不在畫面上（私訊框收起來、換到對話或別的分頁；內橫右欄也算在畫面上）＝撤銷。
                boxClosed: { ChatGPTPluginNewMenu.leftDevTab(store: DMBrowser.shared.store, browser: DMBrowser.shared) },
                podAlive: { ChatGPTTap.shared.connection == .ready },
                pickerOpen: { ChatGPTTap.shared.connection == .ready && ChatGPTTap.shared.pod.filePicker.isOpen },
                pageGeneration: { ChatGPTTap.shared.helloCount },
                armPicker: { hook in ChatGPTTap.shared.pod.filePicker.onBrowserInvalidated = hook },
                visibilityChanges: { changed in
                    // 私訊框（開關、停靠／浮動、框裡是不是 Browser）與 Browser（分頁、最前面的頁）的任何變化；變化生效之後（下一輪主執行緒）才判斷。
                    let browser = DMBrowser.shared
                    return browser.store.objectWillChange.merge(with: browser.objectWillChange)
                        .receive(on: DispatchQueue.main)
                        .sink { _ in MainActor.assumeIsolated { changed() } }
                })
        }
    }

    /// 進行中的那一次（一次只有一個）。
    private struct MenuOperation {
        let op: String
        let hold: UUID
        let item: ChatGPTPluginNewItem
        /// 拿到租約時的原生頁面世代（變了＝網頁換了一份）。
        let generation: Int
        var handedAt: Date?
    }

    private let dependencies: Dependencies
    private var operation: MenuOperation?
    private var clearTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var visibilityWatch: AnyCancellable?

    init(dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? .live()
    }

    /// 選單按下去。W183 R9 審查（Claude #8）：做完之前再按＝不重複送（run 自己也擋）。
    func open(_ item: ChatGPTPluginNewItem) {
        guard working == nil else { return }
        working = item   // 馬上標著：同一輪再按一次不會再開一個 Task
        Task { [weak self] in await self?.run(item, marked: true) }
    }

    /// 自測直接叫（等到對話框交給使用者、或停下）。
    func run(_ item: ChatGPTPluginNewItem) async { await run(item, marked: false) }

    private func run(_ item: ChatGPTPluginNewItem, marked: Bool) async {
        guard marked ? working == item : working == nil else { return }
        working = item
        defer { working = nil }
        show(nil)
        let ready = await dependencies.prepare()
        if let problem = ready.problem {
            // W184 G2 第三輪（查證 #3）：要登入＝打開 ChatGPT Dev 分頁讓使用者在那裡登入；分頁開不出來＝照實說，不叫他去不存在的分頁登入。
            if ready.needsLogin, !dependencies.openTab({}) { return show(Self.noPlaceText) }
            return show(problem)
        }
        let taken = dependencies.beginHold()
        guard let hold = taken.hold else { return show(taken.blocker ?? "ChatGPT 正在忙；等一下再按") }
        let op = UUID().uuidString   // 一次性操作序號（腳本用過就不再收）
        operation = MenuOperation(op: op, hold: hold, item: item, generation: dependencies.pageGeneration())
        // W183 R9 審查（GPT-6 N8）：瀏覽器核心作廢網頁功能（導頁、渲染程序結束、關閉）＝這一次跟著結束。
        dependencies.armPicker { [weak self] in self?.pickerInvalidated() }
        // W183 R9c（GPT-6 C7）：私訊框一變就判斷（收起來、切離 Browser＝馬上撤銷；不等輪詢）。
        visibilityWatch = dependencies.visibilityChanges { [weak self] in self?.visibilityChanged(op) }
        guard dependencies.openTab({ [weak self] in self?.finish(op, abort: true, note: Self.tabClosedText) }) else {
            finish(op, abort: false, note: nil)
            return show(Self.noPlaceText)
        }
        // W183 R9 審查（GPT-6 N7）：從拿到租約起就看（不等 Pod 回覆）：等回覆的時候私訊框收起來、切離 Browser、網頁換了＝馬上撤銷
        // （腳本在下一個按之前停手），不是回覆之後才開始看。
        watch(op)
        let data: [String: Any]
        do {
            data = try await dependencies.send(item.rawValue, op, hold)
        } catch {
            guard operation?.op == op else { return }   // 分頁關掉、私訊鈕關掉：已經撤銷（那邊寫了一句話）
            finish(op, abort: true, note: nil)
            return show("沒打開「\(item.title)」：" + ((error as? TapError)?.errorDescription ?? "ChatGPT 網頁沒有回應"))
        }
        guard operation?.op == op else { return }
        let status = data["status"] as? String
        guard status == "opened" || status == "menu_open" else {
            finish(op, abort: true, note: nil)
            return show(Self.resultText(data, item: item))
        }
        operation?.handedAt = dependencies.now()
        holding = item
        show(Self.resultText(data, item: item), sticky: true)
    }

    /// 拿到租約之後一直看（W183 R9 審查，GPT-6 N7）：分頁關了、私訊框收起來（切離 Browser）、Pod 關了、網頁換了一份＝放掉；
    /// 交給使用者之後再定時問「還開著嗎」、10 分鐘＝放掉。還在等 Pod 回覆的時候看得更勤。
    private func watch(_ op: String) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while let self, let current = self.operation, current.op == op {
                await self.dependencies.pause(current.handedAt == nil ? self.dependencies.sendWatchEvery : self.dependencies.watchEvery)
                guard let now = self.operation, now.op == op else { return }
                if let handed = now.handedAt, self.dependencies.now().timeIntervalSince(handed) > self.dependencies.holdLimit {
                    return self.finish(op, abort: true, note: Self.timeoutText)
                }
                if !self.dependencies.podAlive() { return self.finish(op, abort: false, note: Self.podGoneText) }
                if !self.dependencies.tabOpen() { return self.finish(op, abort: true, note: Self.tabClosedText) }
                if self.dependencies.boxClosed() { return self.finish(op, abort: true, note: Self.boxClosedText) }
                // W183 R9 審查（GPT-6 N7、N8）：網頁換了一份＝結束；在「選檔視窗開著」之前看（世代變了不因為選檔而跳過）。
                if self.dependencies.pageGeneration() != now.generation { return self.finish(op, abort: true, note: Self.pageChangedText) }
                guard now.handedAt != nil else { continue }   // 還在等 Pod 回覆：只看上面這些（還不知道打開了什麼）
                if self.dependencies.pickerOpen() { continue }   // 使用者正在選檔：照樣拿著（選完網頁開的上傳對話框也算這一次的）
                let open = await self.dependencies.watch(op, now.hold)
                guard let still = self.operation, still.op == op else { return }
                if open == true { continue }
                // 關了也送撤銷：只把標出的框拿掉（這一次已經結束，沒有別的東西要停）。
                return self.finish(op, abort: true, note: open == nil ? Self.pageChangedText : Self.closedText)
            }
        }
    }

    /// 結束這一次：先撤銷（還在找選單、按項目的停手、標的框拿掉），再放掉 Pod 的操作租約（排隊的聊天接著送）。
    private func finish(_ op: String, abort: Bool, note: String?) {
        guard let current = operation, current.op == op else { return }
        operation = nil
        holding = nil
        watchTask?.cancel()
        watchTask = nil
        visibilityWatch?.cancel()
        visibilityWatch = nil
        if abort { dependencies.abort(op) }
        dependencies.endHold(current.hold)
        if let note { show(note) }
    }

    #if DEBUG
    /// 自測看：還拿著 Pod 的操作租約的那一次（op）。
    var operationForSelfTest: String? { operation?.op }
    /// 自測：叫一次「還開著嗎」的判斷（不等計時）。
    func finishForSelfTest(abort: Bool, note: String?) { if let op = operation?.op { finish(op, abort: abort, note: note) } }
    #endif

    /// Pod 的選檔視窗沒開成：一句話（W183 R9 審查，GPT-6 #10）。
    func showFilePickerRefused() { show(Self.pickerRefusedText) }

    /// W183 R9c（GPT-6 C7）：私訊框變了：收起來、切離 Browser（boxClosed）＝這一次馬上結束（撤銷、放掉 Pod 的操作租約）。
    private func visibilityChanged(_ op: String) {
        guard let current = operation, current.op == op else { return }
        if dependencies.boxClosed() { finish(op, abort: true, note: Self.boxClosedText) }
    }

    /// W183 R9 審查（GPT-6 N8）：瀏覽器核心作廢了網頁功能（導頁開始、渲染程序結束、關閉、AI 開始操作）：Pod 的選檔視窗已經取消、
    /// 回覆已經結清；這一次跟著結束（撤銷、放掉 Pod 的操作租約），不等下一次輪詢、也不因為選檔視窗「還開著」而跳過。
    func pickerInvalidated() {
        guard let op = operation?.op else { return }
        finish(op, abort: true, note: Self.pageChangedText)
    }

    private func show(_ text: String?, sticky: Bool = false) {
        message = text
        clearTask?.cancel()
        guard let text, !sticky else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.message == text else { return }
            self.message = nil
        }
    }

    /// W184 D（主導：R9 留下的內橫缺口）：「新增」交給使用者之後，什麼時候算離開了——私訊鈕關著，或 ChatGPT Dev 分頁的頁面不在畫面上
    /// （收起來、換到對話、倒放、選了別的分頁、開著分頁總覽）。單欄的 Browser、內橫的右欄都算在畫面上：舊的判斷只看主 store 的
    /// isBrowsing，內橫時 Browser 在右欄（isBrowsingBeside）會被誤判成不在、提早放掉租約（聊天可能打斷正在填的網頁對話框）。
    static func leftDevTab(store: GlobalDMStore, browser: DMBrowser) -> Bool {
        !store.isEnabled || !browser.showsPage(.chatgptDeveloper)
    }

    static let tabClosedText = "ChatGPT Dev 分頁關了：「新增」已停止，ChatGPT 的聊天照常"
    /// ChatGPT Dev 分頁開不出來（私訊鈕關著；W184 G2 第三輪：流程分頁永遠有位子，分頁數不會擋它）。
    static let noPlaceText = "私訊鈕關著：先在設定打開私訊鈕，ChatGPT 的頁面才有地方開"
    static let boxClosedText = "ChatGPT Dev 分頁不在畫面上了（私訊框收起來、換到對話或別的分頁）：「新增」已停止，ChatGPT 的聊天照常"
    static let timeoutText = "「新增」的對話框開了 10 分鐘：TATWO 已經放開 ChatGPT（聊天照常）；還沒填完的話，在 Browser 分頁照樣可以填"
    static let pageChangedText = "ChatGPT 的頁面換了：「新增」已停止"
    static let podGoneText = "ChatGPT 的 Pod 關了或登出了：「新增」已停止"
    static let closedText = "ChatGPT Dev 分頁的對話框關了：ChatGPT 的聊天照常"
    /// W183 R9c（GPT-6 C1）：Pod 的網頁少了 TATWO 安全判斷需要的瀏覽器功能：不自動操作（不退回網頁自己的方法）。
    static let unsafeEnvText = "ChatGPT 的頁面少了 TATWO 需要的瀏覽器功能，TATWO 不在上面自動操作；在 Browser 分頁自己按「新增」"
    static let pickerRefusedText = "選檔視窗沒開：只有你自己在私訊框 Browser 的 ChatGPT Dev 分頁點、而且那一頁在最前面時才開（一次一個、只選檔案）"

    /// Pod 回的結果 → 一句話（不是代號）。W183 R9 審查（Claude #7）：「不只一個」看是哪一步。
    static func resultText(_ data: [String: Any], item: ChatGPTPluginNewItem) -> String {
        let step = data["step"] as? String ?? ""
        switch data["status"] as? String {
        case "opened":
            return "已在私訊框 Browser 的「ChatGPT Dev」分頁打開「\(item.title)」：在那裡自己填、自己確認（對話框開著的時候，ChatGPT 的聊天先排隊）"
        case "menu_open":
            return "已在私訊框 Browser 的「ChatGPT Dev」分頁打開「新增」選單、標出「\(item.title)」：在那裡自己點它選檔（TATWO 不代選）"
        case "not_found" where step == "new_button" || step == "new_menu" || step == "plugins_page":
            return "ChatGPT 外掛頁找不到「新增」選單（ChatGPT 改版，或這個帳號沒開開發者模式）"
        case "not_found" where step == "dialog":
            return "按了「\(item.title)」，ChatGPT 的對話框沒有出來（ChatGPT 改版）；在 Browser 分頁自己看"
        case "not_found":
            return "ChatGPT 的「新增」選單裡找不到「\(item.title)」（ChatGPT 改版，或這個帳號沒開開發者模式）"
        case "ambiguous" where step == "new_button":
            return "ChatGPT 外掛頁上的「新增」鈕不只一顆，TATWO 不猜；在 Browser 分頁自己按"
        case "ambiguous" where step == "new_menu":
            return "ChatGPT 外掛頁上已經開著別的選單（關不掉），TATWO 不猜；在 Browser 分頁自己按「新增」"
        case "ambiguous":
            return "ChatGPT 的「新增」選單裡「\(item.title)」不只一個，TATWO 不猜；在 Browser 分頁自己按"
        case "busy":
            return "ChatGPT Dev 分頁上已經開著一個對話框：先在那裡關掉它，再按「新增」"
        case "refused" where data["reason"] as? String == "unsafe_env":
            return unsafeEnvText
        case "aborted":
            return "「新增」中途停下了（分頁關了或又按了一次）"
        default:
            return "沒打開「\(item.title)」：ChatGPT 的頁面跟預期的不一樣"
        }
    }
}
