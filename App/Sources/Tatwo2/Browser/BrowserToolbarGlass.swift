import AppKit
import SwiftUI

/// Blur the webpage behind the floating Chat toolbar, rather than the desktop.
struct BrowserToolbarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = GlassView()
        view.material = .popover
        view.alphaValue = 1.0
        view.isEmphasized = false
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    final class GlassView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Observe without consuming events, including the full-size titlebar band.
struct BrowserToolbarHoverRegion: NSViewRepresentable {
    var onHover: (Bool) -> Void
    func makeNSView(context: Context) -> HoverView { HoverView() }
    func updateNSView(_ view: HoverView, context: Context) { view.onHover = onHover }
    final class HoverView: NSView {
        private static let regions = NSHashTable<HoverView>.weakObjects()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            Self.regions.add(self)
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            Self.regions.add(self)
        }
        /// 「這個點屬於瀏覽器 chrome」：移入偵測帶，或正在接受點擊的 chrome 本體。
        /// 網址列的收合監看用它判斷「點到外面」，才不會按工具列就把編輯面板關掉。
        static func containsInteractionPoint(_ point: NSPoint, in window: NSWindow) -> Bool {
            if BrowserChromeHitLayer.LayerView.ownsChromePoint(point, in: window) { return true }
            return regions.allObjects.contains { region in
                region.window === window && !region.isHiddenOrHasHiddenAncestor
                    && region.bounds.contains(region.convert(point, from: nil))
            }
        }
        var onHover: ((Bool) -> Void)?
        private var monitor: Any?
        private var tracking: NSTrackingArea?
        private var hovered = false
        private var hideWork: DispatchWorkItem?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .leftMouseDown && UserDefaults.standard.bool(forKey: "tatwo.browser.hitTestDiagnostics") {
                    NSLog("BrowserHit event=%@ local=%@ bounds=%@ window=%@", NSStringFromPoint(event.locationInWindow), NSStringFromPoint(self.convert(event.locationInWindow, from: nil)), NSStringFromRect(self.bounds), String(describing: type(of: event.window!)))
                }
                self.publish(self.bounds.contains(self.convert(event.locationInWindow, from: nil)))
                return event
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { publish(true) }
        override func mouseExited(with event: NSEvent) { publish(false) }
        private func publish(_ value: Bool) {
            hideWork?.cancel()
            hideWork = nil
            if !value {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hovered else { return }
                    self.hovered = false
                    self.onHover?(false)
                }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            } else if !hovered {
                // 同步發布：延後一輪 run loop 才顯示工具列的話，使用者「移入就按」的
                // 那一下會落在 allowsHitTesting 還是 false 的工具列上，變成沒反應。
                hovered = true
                onHover?(true)
            }
        }
        deinit { hideWork?.cancel(); if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// 畫在 CEF 之上的 SwiftUI chrome 需要一層真的 NSView，才拿得回自己的點擊：
///
/// 1. 它是 AppKit 命中到的那個 view，`mouseDownCanMoveWindow == false`。視窗是
///    fullSizeContentView，聊天旁工具列整條坐在標題列帶上；沒有這一層時命中的是
///    SwiftUI hosting view，AppKit 會把 mouse-down 當成拖視窗吃掉，按鈕就「點了沒反應」。
/// 2. 它把自己的畫面矩形登記成「chrome 擁有的命中區」，`BrowserChromeAwareContainerView`
///    據此讓位；登記的是工具列真正在接受點擊的矩形，不是移入偵測帶，所以工具列隱藏時
///    CEF 照常收到點擊，不會有「誰都收不到」的空窗。
///
/// 這層自己不處理滑鼠事件：NSResponder 預設把 mouse-down 往 next responder 送，
/// 回到 SwiftUI hosting view 後由 SwiftUI 自己的手勢辨識分派給按鈕。
struct BrowserChromeHitLayer: NSViewRepresentable {
    var isActive = true
    func makeNSView(context: Context) -> LayerView { LayerView(frame: .zero) }
    func updateNSView(_ view: LayerView, context: Context) { view.isActive = isActive }

    final class LayerView: NSView {
        private static let layers = NSHashTable<LayerView>.weakObjects()
        var isActive = true
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            Self.layers.add(self)
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            Self.layers.add(self)
        }
        override var mouseDownCanMoveWindow: Bool { false }
        /// /goal 101（.016 實測，ui_probe 真實滑鼠事件）：命中落在這層時 mouse-down 沿 responder chain 轉交，
        /// SwiftUI 不會把它派給按鈕，點了沒反應；同一顆「＋」落在 hosting view 的那半邊才有效，這就是
        /// 「工具列按鈕反應很差」。這層只需要登記矩形讓 CEF 容器讓位，自己不該被命中。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        static func ownsChromePoint(_ point: NSPoint, in window: NSWindow) -> Bool {
            layers.allObjects.contains { layer in
                layer.isActive && layer.window === window && !layer.isHiddenOrHasHiddenAncestor
                    && layer.bounds.contains(layer.convert(point, from: nil))
            }
        }
    }
}

/// The CEF child must yield mouse hits to SwiftUI chrome drawn above it.
final class BrowserChromeAwareContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window, let superview,
           BrowserChromeHitLayer.LayerView.ownsChromePoint(superview.convert(point, to: nil), in: window) {
            return nil
        }
        return super.hitTest(point)
    }
}

struct BrowserToolbarMaterial: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Rectangle()).allowsHitTesting(false)
        } else {
            BrowserToolbarGlass().allowsHitTesting(false)
        }
    }
}

/// 浮動工具列底下的玻璃，往下淡出到網頁本身；不吃點擊。
struct BrowserFloatingToolbarBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            let fade = BrowserChatChromeMetrics.backdropFade
            let height = geometry.size.height + fade
            ZStack {
                BrowserToolbarMaterial()
                Color.clear
            }
            .frame(height: height)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: geometry.size.height / height),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }.allowsHitTesting(false)
    }
}
