import AppKit
import SwiftUI

/// W112（使用者 2026-09-20：「網址列平時隱形讓網頁往上靠」「紅綠燈就一起隱藏啊 反正滑鼠指過去就會出現
/// 左列space則是跟隨space不影響」）：獨立 Browser 的頂列平時不在，網頁貼到視窗頂；滑鼠到視窗最上緣才浮出
/// 整條列（浮在網頁上，不推內容），離開就收。用滑鼠位置判斷，不靠 hover 事件（CEF 的原生 view 會吃掉 hover）。
@MainActor
final class BrowserChromeReveal: ObservableObject {
    /// 觸發帶＝從視窗頂到「紅綠燈圓鈕的上緣」那一條水平範圍（使用者 2026-09-21：「喚出位置太低 改到紅綠燈圓鈕的上緣水平範圍」）。
    /// 09-20 晚曾整條頂列高度都算（48），結果滑鼠在網頁上緣移動就會把工具列叫出來，太容易誤觸；改回紅綠燈上緣，
    /// 多給 4 pt 容差讓它好打中。
    static let triggerBand: CGFloat = WindowChromeMetrics.trafficLightTopInset + 4
    @Published private(set) var revealed = false
    /// 網址列在編輯、尋找列開著等：不管滑鼠在哪都留著。
    var holdOpen = false { didSet { if holdOpen != oldValue { evaluate() } } }
    /// W146：擴充管理頁開著時工具列固定顯示，它上面那條就是正常的工具列，不是一塊空白。
    var surfaceHold = false { didSet { if surfaceHold != oldValue { evaluate() } } }
    private weak var window: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var chromeHeight: CGFloat = 44
    private var graceUntil = Date.distantPast

    /// ⌘L／新分頁：頂列平時不在畫面上，要先叫出來網址欄才拿得到焦點；給一小段時間讓焦點接手 holdOpen。
    func revealForFocus() {
        graceUntil = Date().addingTimeInterval(1.2)
        if !revealed { revealed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in self?.evaluate() }
    }

    func start(in window: NSWindow?, chromeHeight: CGFloat) {
        guard let window else { return }
        self.chromeHeight = chromeHeight
        guard self.window !== window || localMonitor == nil else { return }
        stop()
        self.window = window
        window.acceptsMouseMovedEvents = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.evaluate(event.window === self?.window ? event.locationInWindow : nil); return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        revealed = false
        TatwoWindowDragNSView.suppressed = false
        if let window { Self.setTrafficLights(hidden: false, in: window) }
        window = nil
    }

    /// 由畫面把「側欄現在看不看得到」交進來：看得到時紅綠燈跟著側欄，不藏。
    func sync(sidebarVisible: Bool) {
        guard let window else { return }
        Self.setTrafficLights(hidden: !sidebarVisible && !revealed, in: window)
        // 頂列不在的時候，標題列那條拖曳區也要讓開，不然網頁最上面 40 pt 點不到。
        TatwoWindowDragNSView.suppressed = !revealed
    }

    /// location：事件自己帶的視窗座標（自測用的合成滑鼠移動不會動到真的游標）；沒有就問系統。
    private func evaluate(_ location: NSPoint? = nil) {
        guard let window, let content = window.contentView else { return }
        let mouse = location ?? window.mouseLocationOutsideOfEventStream
        let inside = content.bounds.contains(mouse)
        let fromTop = content.bounds.height - mouse.y
        let next: Bool
        if holdOpen || surfaceHold || Date() < graceUntil { next = true }
        else if !inside { next = false }
        else if revealed { next = fromTop <= chromeHeight + 10 }
        else { next = fromTop <= Self.triggerBand }
        if next != revealed { withAnimation(.easeOut(duration: 0.12)) { revealed = next } }
    }

    static func setTrafficLights(hidden: Bool, in window: NSWindow) {
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = hidden }
    }
}

/// 把畫面所在的視窗交給 `BrowserChromeReveal`，並在頂列或側欄狀態變動時同步紅綠燈。
struct BrowserChromeRevealHost: NSViewRepresentable {
    @ObservedObject var reveal: BrowserChromeReveal
    let sidebarVisible: Bool
    let chromeHeight: CGFloat

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let revealed = reveal.revealed   // 讀一次，讓這個 view 跟著 revealed 重算
        _ = revealed
        DispatchQueue.main.async { [weak view] in
            reveal.start(in: view?.window, chromeHeight: chromeHeight)
            reveal.sync(sidebarVisible: sidebarVisible)
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) {}
}
