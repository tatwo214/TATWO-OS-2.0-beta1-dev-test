import AppKit
import SwiftUI

/// W116g 實驗（使用者 2026-09-20：「為什麼只在分頁生效 要做就應該全面」）：
/// 瀏覽器核心的完整模式（有擴充功能）不能嵌進我們的 NSView，但它自己的無邊框視窗可以當主視窗的子視窗、
/// 貼在網頁區上。這個檔只負責「網頁區現在在螢幕的哪裡」，用通知交給原生端；不 import 橋接層，輕量測試可以單獨編。
@MainActor
final class BrowserChromeStyleEmbedState: ObservableObject {
    static let shared = BrowserChromeStyleEmbedState()
    static let openRequest = Notification.Name("tatwo.browser.chromeStyleSpike.embed")
    static let frameChanged = Notification.Name("tatwo.browser.chromeStyleSpike.embed.frame")
    static let closed = Notification.Name("tatwo.browser.chromeStyleSpike.embed.close")
    /// 原生端在視窗真的消失時送這個（使用者按紅點也算），Swift 這邊才知道要把狀態清掉。
    static let destroyed = Notification.Name("tatwo.browser.chromeStyleSpike.embed.destroyed")
    /// W144：Browser work space 的分頁選擇變了（store 端用字串名稱送，這樣它的獨立測試不必連這個檔一起編）。
    static let workspaceSelection = Notification.Name("tatwo.browser.workspace.selection")
    @Published var url: String?
    /// W147（使用者 2026-09-21：「整個頁面適配度做得很差」——側欄收起時左邊空一大塊）：網頁區在主視窗裡的真實位置
    /// （視窗座標）。以前用「視窗寬減側欄寬」估，側欄收起、浮層側欄都會算錯；改由網頁區上的定位點回報。
    private(set) var pageRectInWindow: NSRect = .zero
    static let pageRectChanged = Notification.Name("tatwo.browser.chromeStyleSpike.embed.pageRect")
    func reportPageRect(_ rect: NSRect) {
        guard rect != pageRectInWindow, rect.width > 80, rect.height > 80 else { return }
        pageRectInWindow = rect
        if url != nil { NotificationCenter.default.post(name: Self.pageRectChanged, object: nil) }
    }
    private var observer: Any?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: Self.openRequest, object: nil, queue: .main) { [weak self] note in
            let url = note.object as? String ?? "chrome://extensions"
            MainActor.assumeIsolated { self?.url = url }
        }
        NotificationCenter.default.addObserver(forName: Self.destroyed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.url = nil }
        }
        // W144：左列換分頁（或開新分頁、回首頁）時收起擴充管理頁，行為跟一般分頁一樣。
        NotificationCenter.default.addObserver(forName: Self.workspaceSelection, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.url != nil { self?.close() } }
        }
    }
    func close() {
        url = nil
        NotificationCenter.default.post(name: Self.closed, object: nil)
    }
}

/// W145（使用者 2026-09-21 截圖：「哪有改好」——上下疊了兩層商店）：擴充頁上緣讓出工具列高度，
/// 底下分頁的網頁就從那條縫露出來，右邊也看得到原網頁的卡片，一看就是「一個視窗疊在網頁上」。
/// 擴充頁開著時，把底下的網頁整塊蓋掉；讓出來的那條只剩空白，滑鼠移上去照樣叫出工具列。
struct BrowserChromeStyleEmbedLayer: ViewModifier {
    @ObservedObject private var state = BrowserChromeStyleEmbedState.shared
    /// W146（使用者 2026-09-21 截圖：上緣空一大塊）：擴充頁開著時工具列固定顯示，讓出來的那條就是工具列。
    let reveal: BrowserChromeReveal
    /// W147：擴充頁開關時讓網址列重新取值（開著顯示「擴充功能」，不是底下分頁的網址）。
    var surfaceChanged: () -> Void = {}
    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if state.url != nil { Color(nsColor: .textBackgroundColor) }
                BrowserChromeStyleEmbedAnchor()
            }.allowsHitTesting(false)
            // W148（.005 實測：擴充頁頂端比工具列低 28 pt）：overlay 會吃視窗頂的安全區域，定位點量到的網頁區頂端就被往下推。
            .ignoresSafeArea()
        }
        .onChange(of: state.url != nil, initial: true) { _, open in reveal.surfaceHold = open; surfaceChanged() }
    }
}

/// W147：網頁區上的定位點，不吃事件；自己的位置或大小一變就回報（視窗座標，視窗移動時不必重報）。
struct BrowserChromeStyleEmbedAnchor: NSViewRepresentable {
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); report() }
        override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); report() }
        override func layout() { super.layout(); report() }
        func report() {
            guard window != nil else { return }
            let rect = convert(bounds, to: nil)
            DispatchQueue.main.async { MainActor.assumeIsolated { BrowserChromeStyleEmbedState.shared.reportPageRect(rect) } }
        }
    }
    func makeNSView(context: Context) -> AnchorView { AnchorView(frame: .zero) }
    func updateNSView(_ view: AnchorView, context: Context) { view.report() }
}

