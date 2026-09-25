import AppKit
import SwiftUI

/// 聊天旁瀏覽器「⌃ 展開工具」的圓鈕列：畫在自己的無邊框子視窗裡。
///
/// 為什麼不是 SwiftUI overlay：CEF 是原生 NSView，任何畫在它上面的 SwiftUI 內容都搶不到點擊
/// （2026-09-18 使用者實機五個候選都點不到）。子視窗永遠在 CEF 之上、命中由 AppKit 保證，
/// 外觀仍是「從 ⌃ 往下一直列、圓鈕浮空、沒有底板」，也不推開網頁、不破壞頂列的漸淡層。
struct BrowserFloatingToolsAnchor<Content: View>: NSViewRepresentable {
    var isOpen: Bool
    var onHoverPanel: (Bool) -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> BrowserFloatingToolsAnchorView { BrowserFloatingToolsAnchorView() }
    func updateNSView(_ view: BrowserFloatingToolsAnchorView, context: Context) {
        view.update(isOpen: isOpen, onHover: onHoverPanel, content: AnyView(content()))
    }
    static func dismantleNSView(_ view: BrowserFloatingToolsAnchorView, coordinator: ()) { view.closePanel() }
}

final class BrowserFloatingToolsAnchorView: NSView {
    /// 子視窗四周留白：圓鈕的陰影與玻璃不會被視窗邊界切成一塊長方形底板（使用者 09-19：「浮空不是真浮空」）。
    static let inset: CGFloat = 12
    private var panel: NSPanel?
    private var host: BrowserFloatingToolsHostingView?
    private var onHover: ((Bool) -> Void)?
    private var wantsOpen = false
    private var lastInside = false
    private var monitors: [Any] = []

    /// 這個錨點只提供位置，不吃任何事件。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isOpen: Bool, onHover: @escaping (Bool) -> Void, content: AnyView) {
        self.onHover = onHover
        wantsOpen = isOpen
        if isOpen { show(content) } else { evaluate() }
    }

    /// 收合不靠計時器（使用者 09-19：「不要延遲」）：滑鼠還在「觸發鈕＋圓鈕列」這塊範圍內就留著，一離開立刻收。
    private func evaluate() {
        guard panel != nil, !wantsOpen, !mouseInside() else { return }
        closePanel()
    }

    private func mouseInside() -> Bool {
        guard let window, let panel else { return false }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let column = panel.frame.insetBy(dx: Self.inset - 2, dy: 0)
        return anchor.union(column).insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
    }

    private func mouseMoved() {
        let inside = mouseInside()
        if inside != lastInside { lastInside = inside; onHover?(inside) }
        if !inside { evaluate() }
    }

    private func show(_ content: AnyView) {
        guard let window else { return }
        let panel = self.panel ?? makePanel(parent: window)
        let padded = AnyView(content.padding(Self.inset))
        if let host { host.rootView = padded } else {
            let created = BrowserFloatingToolsHostingView(rootView: padded)
            panel.contentView = created
            host = created
        }
        guard let host else { return }
        let size = host.fittingSize
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let origin = NSPoint(x: anchor.midX - size.width / 2,
                             y: anchor.minY - BrowserChatChromeMetrics.toolsGap + Self.inset - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        guard monitors.isEmpty else { return }
        window.acceptsMouseMovedEvents = true
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.mouseMoved(); return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            DispatchQueue.main.async { self?.mouseMoved() }
        }) { monitors.append(global) }
    }

    private func makePanel(parent: NSWindow) -> NSPanel {
        let created = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.becomesKeyOnlyIfNeeded = true
        created.hidesOnDeactivate = true
        created.isReleasedWhenClosed = false
        created.setAccessibilityIdentifier("browser.toolbar.toolsPanel")
        created.title = "工具" // 無邊框看不到；給輔助功能與自動化一個可辨識的視窗名
        panel = created
        return created
    }

    func closePanel() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        if lastInside { lastInside = false; onHover?(false) }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        host = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { closePanel() }
    }
}

/// 子視窗的內容；不是 key 視窗時第一下點擊也要生效。
final class BrowserFloatingToolsHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 子視窗裡的圓鈕。子視窗本身是透明的，`withinWindow` 的材質在裡面沒有東西可以模糊，會畫成一塊灰底；
/// 這裡用 `behindWindow`（模糊的是底下的網頁／聊天）再用圓形遮罩，才是真的浮空。
struct BrowserFloatingChip: View {
    let systemImage: String
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: BrowserChatChromeMetrics.expanderFontSize, weight: .semibold))
            .frame(width: BrowserChatChromeMetrics.expanderSize, height: BrowserChatChromeMetrics.expanderSize)
            .background {
                ZStack {
                    Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                        .shadow(color: Color.black.opacity(BrowserChatChromeMetrics.toolShadowOpacity),
                                radius: BrowserChatChromeMetrics.toolShadowRadius, y: BrowserChatChromeMetrics.toolShadowY)
                    BrowserBehindWindowGlass().clipShape(Circle())
                    Circle().fill(Color.primary.opacity(BrowserChatChromeMetrics.expanderFill))
                }
            }
            .contentShape(Circle())
    }
}

struct BrowserBehindWindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        let diameter = BrowserChatChromeMetrics.expanderSize
        view.maskImage = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
        }
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
