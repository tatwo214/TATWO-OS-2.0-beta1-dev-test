import AppKit
import Combine
import SwiftUI

// W183 R12（使用者 09-30：「瀏覽器可以自動改成橫式 先暫時蓋過左側的私訊 把授權放去左側 就像dou一樣 雙頁協作應該是很靈活彈性的」
// 「duo筐要有針對任務自適應的標準」；主導：做成通用的任務版面機制，連線是第一個用它的任務，之後「AI 在網頁上操作給你看」「讀長文件」
// 「看影片」也掛上來——這一輪只接連線，介面留好）：
// - 掛上任務（begin）：形態是內橫（兩頁攤開）時，左頁暫時蓋掉私訊、放這個任務的卡（整頁高度，自己捲）；私訊那一欄不拆
//   （草稿、捲動位置、輸入焦點都在），只是蓋著、點不到、不唸。
// - 任務要它的形態了（want；例：連線要開網頁）：記下原本的形態，換到任務要的形態（走現有的換形態動畫）；已經是那個形態＝不動。
// - 結束（end）：左頁還給私訊；形態是這個元件換的、使用者中途沒自己換過＝換回原本的（原本是外直就滑回外直）；使用者換過＝不動。
// - 正在打字或組字（輸入法的字還沒選完、剛打過字）：換形態延後，停了再換（進、出都一樣）。
// - 收起私訊框、拉大小、使用者自己換形態：任務照舊（這個元件不取消任何東西）；打開時照現在的形態排。

/// 一種任務：名字（只給程式看）＋要的形態。
struct GlobalDMTask: Hashable, Sendable {
    let id: String
    /// 任務要的形態（連線＝內橫：左頁授權卡、右頁網頁）。
    let form: GlobalDMForm

    /// W183 R12：連線（左頁：進度、確認、說明改了、失敗與重試；右頁：ChatGPT／授權／配對網頁）。
    static let connect = GlobalDMTask(id: "connect", form: .innerLandscape)
    // 之後掛上來的（這一輪不做）：webOperation（AI 在網頁上操作給你看）、document（讀長文件）、video（看影片）——
    // 照這一套：register 左頁、begin、want、end。
}

@MainActor
final class GlobalDMTaskLayout: ObservableObject {
    struct Dependencies {
        /// 現在的形態、它的變化（正式＝GlobalDMDeskSettings.shared.form）。
        var form: @MainActor () -> GlobalDMForm
        var formChanges: @MainActor () -> AnyPublisher<GlobalDMForm, Never>
        /// 用程式換形態（正式＝GlobalDMDeskController.shared.setForm：框看得到就滑、減少動態效果＝淡換）。
        var setForm: @MainActor (GlobalDMForm) -> Void
        /// 單欄的 Browser 開著（換回單欄時還原）。
        var isBrowsing: @MainActor () -> Bool
        var setBrowsing: @MainActor (Bool) -> Void
        /// 正在打字或組字（輸入法的字還沒選完、剛打過字）。
        var busyTyping: @MainActor () -> Bool
        /// 打字中延後多久再看一次。
        var retryDelay: TimeInterval = 0.4

        @MainActor
        static func live() -> Dependencies {
            let settings = GlobalDMDeskSettings.shared
            let store = GlobalDMStore.shared
            return Dependencies(form: { settings.form },
                                formChanges: { settings.$form.eraseToAnyPublisher() },
                                setForm: { _ = GlobalDMDeskController.shared.setForm($0, animated: true) },
                                isBrowsing: { store.isBrowsing },
                                setBrowsing: { if $0 { store.showBrowser() } },
                                busyTyping: { GlobalDMTypingClock.shared.busy() })
        }
    }

    static let shared = GlobalDMTaskLayout(dependencies: .live())

    /// 沒接到桌面控制器的私訊框（自測自己建的框）：形態固定、不換（左頁只在固定的形態是兩頁時掛）。
    static func inert(form: GlobalDMForm = .outerPortrait) -> GlobalDMTaskLayout {
        GlobalDMTaskLayout(dependencies: Dependencies(form: { form }, formChanges: { Empty<GlobalDMForm, Never>().eraseToAnyPublisher() },
                                                      setForm: { _ in }, isBrowsing: { false }, setBrowsing: { _ in }, busyTyping: { false }))
    }

    /// 掛著的任務（nil＝沒有）。
    @Published private(set) var task: GlobalDMTask?
    /// 現在的形態（跟著形態的變化；畫面照它決定左頁要不要掛）。
    @Published private(set) var form: GlobalDMForm
    /// 左頁掛在哪個私訊框（主要那一個 store；別的框不蓋）。
    private weak var owner: GlobalDMStore?
    /// 這個元件換之前的形態（沒換過＝nil）與那時單欄的 Browser 開著沒。
    private(set) var original: (form: GlobalDMForm, browsing: Bool)?
    /// 任務中使用者自己換過形態（結束時不改回）。
    private(set) var userMoved = false
    /// 要換、但正在打字：等停了再換（進任務＝任務的形態；結束＝原本的形態）。
    private(set) var pendingForm: GlobalDMForm?
    private var pendingBrowsing = false
    private var switching = false
    private var retryGeneration = 0
    private var formWatch: AnyCancellable?
    private var pages: [String: @MainActor (GlobalDMBrowserServices) -> AnyView] = [:]
    let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        form = dependencies.form()
        formWatch = dependencies.formChanges().sink { [weak self] next in
            MainActor.assumeIsolated { self?.formChanged(next) }
        }
    }

    // MARK: - 左頁

    /// 任務的左頁（任務自己的卡；services＝框裡用的 Browser、流程、呈現層：正式＝.shared，自測換）。
    func register(_ task: GlobalDMTask, page: @escaping @MainActor (GlobalDMBrowserServices) -> AnyView) {
        pages[task.id] = page
    }

    /// 這個私訊框現在左頁要掛哪個任務（形態是兩頁、任務掛在這個框）。
    func leftPageTask(for store: GlobalDMStore) -> GlobalDMTask? {
        guard let task, form.isDuo, owner === store else { return nil }
        return task
    }

    /// 左頁的畫面（沒有＝nil）。
    func leftPage(for store: GlobalDMStore, services: GlobalDMBrowserServices) -> AnyView? {
        guard let task = leftPageTask(for: store), let page = pages[task.id] else { return nil }
        return page(services)
    }

    // MARK: - 進出

    /// 掛上任務（還不換形態：形態是兩頁時左頁就掛它的卡）。同一個任務再叫＝不動；換了任務＝前一個的還原作廢（新的接手）。
    func begin(_ task: GlobalDMTask, on store: GlobalDMStore) {
        owner = store
        guard self.task != task else { return }
        if self.task == nil {
            pendingForm = nil   // 上一個任務還沒還原完（打字中等著）＝新的接手：不還原
            retryGeneration += 1
            original = nil
            userMoved = false
        }
        self.task = task
    }

    /// 任務要它的形態了：記下原本的、換過去（打字、組字中＝延後）。已經是那個形態＝不動（結束時也不改）。
    func want(_ task: GlobalDMTask) {
        guard self.task == task, original == nil, !userMoved else { return }
        let now = dependencies.form()
        guard now != task.form else { return }
        switchTo(task.form, browsing: nil, remember: (now, dependencies.isBrowsing()))
    }

    /// 任務結束：左頁還給私訊；這個元件換過、使用者沒動過、現在還是任務的形態＝換回原本的（打字中延後）。
    func end(_ task: GlobalDMTask) {
        guard self.task == task else { return }
        self.task = nil
        let back = original
        let moved = userMoved
        original = nil
        userMoved = false
        if pendingForm == task.form { pendingForm = nil; retryGeneration += 1 }   // 還沒換過去就結束了＝不換
        guard let back, !moved, dependencies.form() == task.form else { return }
        switchTo(back.form, browsing: back.browsing, remember: nil)
    }

    /// 換形態（正在打字＝等停了再換；等的時候使用者自己換了、或又掛上別的任務＝不換）。
    private func switchTo(_ target: GlobalDMForm, browsing: Bool?, remember: (GlobalDMForm, Bool)?) {
        if let remember { original = (remember.0, remember.1) }
        if dependencies.busyTyping() {
            pendingForm = target
            pendingBrowsing = browsing ?? false
            retryGeneration += 1
            let generation = retryGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + dependencies.retryDelay) { [weak self] in
                MainActor.assumeIsolated { self?.retry(generation) }
            }
            return
        }
        pendingForm = nil
        apply(target, browsing: browsing ?? false)
    }

    private func retry(_ generation: Int) {
        guard generation == retryGeneration, let target = pendingForm else { return }
        switchTo(target, browsing: pendingBrowsing, remember: nil)
    }

    private func apply(_ target: GlobalDMForm, browsing: Bool) {
        switching = true
        dependencies.setForm(target)
        if browsing, !target.isDuo { dependencies.setBrowsing(true) }
        switching = false
        form = dependencies.form()
    }

    /// 形態變了：不是這個元件換的＝使用者換的（任務中、或等著換的時候）→ 結束時不改回、等著的不換。
    private func formChanged(_ next: GlobalDMForm) {
        if !switching, next != form {
            if task != nil, original != nil { userMoved = true }
            if pendingForm != nil { pendingForm = nil; retryGeneration += 1; if task != nil { userMoved = true } }
        }
        if next != form { form = next }
    }
}

/// W183 R12：「正在打字」：私訊框裡拿著鍵盤的東西正在組字（輸入法的字還沒選完），或剛打過字（草稿 1.2 秒內變過）。
@MainActor
final class GlobalDMTypingClock {
    static let shared = GlobalDMTypingClock(store: .shared)
    static let window: TimeInterval = 1.2
    private var lastEdit: Date?
    private var watch: AnyCancellable?

    init(store: GlobalDMStore) {
        watch = store.$drafts.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.lastEdit = Date() }
        }
    }

    func busy(now: Date = Date()) -> Bool {
        if let lastEdit, now.timeIntervalSince(lastEdit) < Self.window { return true }
        return NSApp.windows.contains { $0 is GlobalDMPanel && $0.isVisible && GlobalDMPanelController.isComposing(in: $0) }
    }
}

/// W183 R12：左欄＝私訊（GlobalDMBox）；有任務的左頁＝蓋在上面（私訊不拆：草稿、捲動、焦點都在）。
struct GlobalDMTaskCover<Content: View>: View {
    let store: GlobalDMStore
    @ViewBuilder let content: () -> Content
    @Environment(\.globalDMBrowserServices) private var services

    var body: some View {
        GlobalDMTaskCoverBody(layout: services.taskLayout ?? .shared, store: store, services: services, content: content)
    }
}

private struct GlobalDMTaskCoverBody<Content: View>: View {
    @ObservedObject var layout: GlobalDMTaskLayout
    @ObservedObject var store: GlobalDMStore
    let services: GlobalDMBrowserServices
    let content: () -> Content

    var body: some View {
        let page = layout.leftPage(for: store, services: services)
        ZStack(alignment: .topLeading) {
            content()
                .opacity(page == nil ? 1 : 0)
                .allowsHitTesting(page == nil)
                .accessibilityHidden(page != nil)
            if let page {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: page != nil)
    }
}
