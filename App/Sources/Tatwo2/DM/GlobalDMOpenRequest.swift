import Foundation

/// 私訊框開關的樣子（停靠框、浮動框、是不是在 Browser）：開框請求完成時回報「開之前」與「開之後」。
struct GlobalDMBoxPresence: Equatable, Sendable {
    let docked: Bool
    let floating: Bool
    let browsing: Bool

    var isOpen: Bool { docked || floating }

    init(docked: Bool, floating: Bool, browsing: Bool) {
        self.docked = docked
        self.floating = floating
        self.browsing = browsing
    }

    @MainActor init(_ store: GlobalDMStore) {
        self.init(docked: store.isOpen, floating: store.isFloatingOpen, browsing: store.isBrowsing)
    }
}

/// 開框請求的結果（只有一個，只報一次）。
enum GlobalDMOpenOutcome: Equatable, Sendable {
    /// 框真的開好了、選頁／選對象／設定旗標也做完了：這一次開框之前與之後的樣子。
    case opened(before: GlobalDMBoxPresence, after: GlobalDMBoxPresence)
    /// 出列時不做了（目標不在了、私訊鈕總開關關著、框沒打開、關口收掉）：不立起、不開框、不選頁。
    case dropped
    /// 流程結束先撤銷（關分頁、取消連線、restoreBox／hide）。
    case cancelled
}

/// W184 AB（GPT-6 複核 新發現 1–3）：一次「要看到某個畫面」的入口操作——開框＋選頁／選對象／設定旗標，整個是一個請求。
/// - 倒放、轉換動畫中排隊的是整個請求（不是只有開框）；框真的開好之後才做 then（選頁、選對象、設定旗標）——
///   停靠框換成浮動框的中途（兩個框都關著的那一下，私訊框會清掉直達鍵頁之類的旗標）不會把它清掉。
/// - 每個請求有自己的 id 與取消句柄：流程結束＝cancel()，還沒出列的不再開框；重複取消、做完再取消都不動。
/// - 出列前再驗證（valid＝目標還在；私訊鈕總開關開著）：不在了＝丟掉。
/// - 完成回呼帶這一次開框前後的樣子：呼叫端照它記「打開後的樣子」，不用「任一框已開」推定。
@MainActor
final class GlobalDMOpenRequest {
    let id = UUID()
    /// false＝框本來就開著、只要切回能顯示的形態再做 then（房 E 倒放卡上的「打開私訊框」：點的就是框裡的按鈕，不照 ⌥⌘ 規則重開，
    /// 免得非啟用面板點下去 App 沒有變成作用中、停靠框被換成浮動框）。
    let opensBox: Bool
    private let valid: @MainActor () -> Bool
    private let then: @MainActor () -> Void
    private var handlers: [@MainActor (GlobalDMOpenOutcome) -> Void] = []
    private(set) var outcome: GlobalDMOpenOutcome?

    init(opensBox: Bool = true, valid: @escaping @MainActor () -> Bool = { true }, then: @escaping @MainActor () -> Void = {}) {
        self.opensBox = opensBox
        self.valid = valid
        self.then = then
    }

    var isFinished: Bool { outcome != nil }

    /// 有結果時叫（已經有結果＝馬上叫）；每個只叫一次。
    func whenFinished(_ handler: @escaping @MainActor (GlobalDMOpenOutcome) -> Void) {
        if let outcome { handler(outcome) } else { handlers.append(handler) }
    }

    /// 流程結束：還沒出列的不再開框。已經有結果（做完、撤銷過、丟掉過）＝不動。
    func cancel() { finish(.cancelled) }

    /// 關口丟掉它（出列時目標不在了、關口收掉）。已經有結果＝不動。
    func drop() { finish(.dropped) }

    /// 出列前再驗證：還沒有結果、私訊鈕總開關開著、目標還在。
    func stillWanted(in store: GlobalDMStore) -> Bool {
        outcome == nil && store.isEnabled && valid()
    }

    /// 出列：再驗證 → 開框（照 ⌥⌘ 規則）→ 框真的開著才做 then → 回報前後的樣子。
    /// requiresBox＝false 只給自測的同步假開框（叫完就算開好：照舊做 then，框沒開的話呼叫端不記「打開後的樣子」）。
    func run(store: GlobalDMStore, requiresBox: Bool = true, open: @MainActor () -> Void) {
        guard stillWanted(in: store) else { return drop() }
        let before = GlobalDMBoxPresence(store)
        if opensBox { open() }
        guard outcome == nil else { return }   // 開框的途中流程結束了（撤銷）：不選頁
        guard store.isPresented || !requiresBox else { return drop() }
        then()
        finish(.opened(before: before, after: GlobalDMBoxPresence(store)))
    }

    private func finish(_ result: GlobalDMOpenOutcome) {
        guard outcome == nil else { return }
        outcome = result
        let waiting = handlers
        handlers = []
        for handler in waiting { handler(result) }
    }
}
