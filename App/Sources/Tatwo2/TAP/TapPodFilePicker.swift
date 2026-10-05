import AppKit
import UniformTypeIdentifiers

// W183 R9 審查（GPT-6 #10）：ChatGPT Pod 的檔案選擇器——只給人用。
// - 以前 Pod 沒接 CEF 的選檔回呼（CEF 一律取消）：「上傳外掛程式封存檔」就算使用者自己按，也選不了檔。
// - 只在 Pod 正受保護地放在私訊框 Browser 的「ChatGPT Dev」分頁、那一格在看得到的視窗裡、瀏覽器是人在用（不是 AI 在操作）時才開；
//   Pod 墊在畫面外、收在停泊視窗時的選檔要求不會是使用者按的，一律不開。網頁本身也要使用者真的按下才叫得出選檔（瀏覽器的規則）。
// - 只開檔（一個或多個）；不開資料夾、不開「另存新檔」。TATWO 不代選、不預選（網頁給的預設路徑只拿來當起始資料夾）。
// - 一次一個；Pod 關掉、換了一個瀏覽器、Pod 從分頁拿下來、受保護的呈現結束＝還開著的選檔視窗取消（世代），晚到的結果不交給網頁。

@MainActor
final class TapPodFilePicker {
    /// 這一刻 Pod 在哪裡、誰在用（TapWebPod 算）。
    struct Context {
        var guarded: Bool
        var visible: Bool
        var human: Bool
        var window: NSWindow?

        static let closed = Context(guarded: false, visible: false, human: false, window: nil)
    }

    /// 真的開選檔視窗（正式＝NSOpenPanel 掛在私訊框的視窗上；自測＝假的）。回「取消它」的方法；nil＝沒開成。
    typealias Present = @MainActor (_ window: NSWindow, _ request: Request, _ done: @escaping @MainActor ([URL]?) -> Void) -> (@MainActor () -> Void)?

    struct Request {
        let multiple: Bool
        let types: [UTType]
        let title: String
        let directory: URL?
    }

    /// 交給網頁的結果：剛好一次（之後再叫都不理）。
    @MainActor private final class Reply {
        private var completion: (@MainActor ([String]?) -> Void)?
        init(_ completion: @escaping @MainActor ([String]?) -> Void) { self.completion = completion }
        func finish(_ paths: [String]?) {
            guard let completion else { return }
            self.completion = nil
            completion(paths)
        }
    }

    private let context: @MainActor () -> Context
    private let present: Present
    private(set) var generation: UInt64 = 0
    private var cancelOpen: (@MainActor () -> Void)?
    private var finishOpen: Reply?
    /// 沒開成（不是人在看的時候、不支援的種類、已經開著一個）：原生頁可以說一句話。
    var onRefused: (@MainActor () -> Void)?
    /// W183 R9 審查（GPT-6 N8）：瀏覽器核心作廢了網頁功能（導頁開始、渲染程序結束、關閉、AI 開始操作）：選檔視窗已經取消、回覆已結清之後叫
    /// （原生「新增」那一次跟著結束，不等下一次輪詢、也不因為選檔視窗「還開著」而跳過）。
    var onBrowserInvalidated: (@MainActor () -> Void)?

    init(context: @escaping @MainActor () -> Context, present: Present? = nil) {
        self.context = context
        if let present { self.present = present } else { self.present = Self.openPanel }
    }

    /// 有一個選檔視窗開著。
    var isOpen: Bool { finishOpen != nil }

    /// 只開檔（0＝一個、1＝多個）；資料夾（2）、另存新檔（3）不開。其他條件：受保護的呈現、看得到、人在用、有視窗。
    static func allows(mode: Int, _ context: Context) -> Bool {
        (mode == 0 || mode == 1) && context.guarded && context.visible && context.human && context.window != nil
    }

    /// CEF 的選檔要求。completion 一定剛好叫一次（nil＝取消）。
    func request(mode: Int, title: String, defaultPath: String, filters: [String], multiple: Bool,
                 completion: @escaping @MainActor ([String]?) -> Void) {
        let now = context()
        guard finishOpen == nil, Self.allows(mode: mode, now), let window = now.window else {
            completion(nil)
            onRefused?()
            return
        }
        generation &+= 1
        let mine = generation
        let reply = Reply(completion)
        finishOpen = reply
        // 只當起始資料夾，不預選檔。
        let directory: URL? = (defaultPath as NSString).isAbsolutePath ? URL(fileURLWithPath: defaultPath).deletingLastPathComponent() : nil
        let request = Request(multiple: mode == 1 && multiple, types: BrowserWebFeatures.contentTypes(filters),
                              title: BrowserHumanInteraction.oneLine(title), directory: directory)
        cancelOpen = present(window, request) { [weak self] urls in
            guard let self else { reply.finish(nil); return }
            // 世代換過（Pod 關了、換了瀏覽器、從分頁拿下來）或現在不是人在看：不交給網頁。
            let still = self.generation == mine && Self.allows(mode: mode, self.context())
            if self.generation == mine { self.finishOpen = nil; self.cancelOpen = nil }
            reply.finish(still ? (urls ?? []).filter(\.isFileURL).map(\.path) : nil)
        }
        if cancelOpen == nil, generation == mine {   // 沒開成
            finishOpen = nil
            reply.finish(nil)
            onRefused?()
        }
    }

    /// W183 R9 審查（GPT-6 N8）：CEF 的 onWebFeaturesInvalidated（TapWebPod.wireWebFeatures 接上）。先取消、結清，再通知。
    func browserInvalidated() {
        invalidate()
        onBrowserInvalidated?()
    }

    /// 取消還開著的選檔視窗（網頁拿到「取消」）；之後晚到的結果不交給網頁。
    func invalidate() {
        generation &+= 1
        let reply = finishOpen, cancel = cancelOpen
        finishOpen = nil
        cancelOpen = nil
        cancel?()
        reply?.finish(nil)
    }

    /// 選檔視窗的回覆（放在主執行緒的物件裡，sheet 的回呼只抓它）。
    @MainActor private final class PanelReply {
        let done: @MainActor ([URL]?) -> Void
        init(_ done: @escaping @MainActor ([URL]?) -> Void) { self.done = done }
    }

    /// 正式：NSOpenPanel 掛在 Pod 所在的視窗上（sheet）。不預選檔、不允許建資料夾。
    private static func openPanel(_ window: NSWindow, _ request: Request, _ done: @escaping @MainActor ([URL]?) -> Void) -> (@MainActor () -> Void)? {
        guard window.attachedSheet == nil else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = request.multiple
        panel.canCreateDirectories = false
        if !request.title.isEmpty { panel.title = request.title }
        panel.message = "ChatGPT 要你選檔（你自己選；TATWO 不代選）"
        if let directory = request.directory { panel.directoryURL = directory }
        if !request.types.isEmpty { panel.allowedContentTypes = request.types }
        panel.allowsOtherFileTypes = request.types.isEmpty
        let reply = PanelReply(done)
        panel.beginSheetModal(for: window) { [reply, weak panel] response in
            reply.done(response == .OK ? (panel?.urls ?? []) : nil)
        }
        return { [weak panel] in panel?.cancel(nil) }
    }
}
