import AppKit
import SwiftUI

/// W184 H4 修正（GPT-6 H4 審查 #6）：模式卡的鍵盤與焦點——所有入口（Coder、TATWO 助理頁、Space 搭建、私訊框、Bot Studio）同一套，
/// 因為卡都由同一個 TatwoComposerModePopover 掛出來：
/// - 卡開著時 Esc 先收卡（私訊框的 routeEscape 也是先收卡；兩邊誰先收到都一樣：只收卡、框照舊開著）；
/// - 卡裡用 ↑↓ 或 Tab（Shift＋Tab 反向）換一區、←→ 換這一區的檔位、Return 選定（模型那一列＝進清單、清單裡＝選那一個、← 回卡的主頁）；
/// - 卡開著時輸入框的 Return 不送出、方向鍵不動游標、不選建議（ChatComposerTextView 看 yieldsToCard，把這幾鍵讓給卡）；
/// - 組字中（輸入法的字還沒選完）的按鍵一律先給輸入法；
/// - 收卡後焦點回輸入框（剛剛點到別的輸入的地方就不搶）。
enum TatwoComposerModeKeyboard {
    enum Key: Equatable { case escape, next, previous, left, right, commit }

    /// 卡要的鍵（沒有 ⌘／⌃／⌥；Shift 只配 Tab）；其他照舊給輸入框（打字、⌘ 快捷鍵）。
    static func key(for event: NSEvent) -> Key? {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 53: return mods.isEmpty ? .escape : nil
        case 48: return mods.isEmpty ? .next : (mods == [.shift] ? .previous : nil)
        case 125: return mods.isEmpty ? .next : nil
        case 126: return mods.isEmpty ? .previous : nil
        case 123: return mods.isEmpty ? .left : nil
        case 124: return mods.isEmpty ? .right : nil
        case 36, 76: return mods.isEmpty ? .commit : nil
        default: return nil
        }
    }

    /// 拿著鍵盤的東西正在組字（同 GlobalDMPanelController.isComposing：任何文字輸入，不只 NSTextView）。
    @MainActor static func isComposing(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    /// 這個視窗有模式卡開著（卡的鍵盤監看登記著）。
    @MainActor static func isOpen(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return TatwoComposerModeKeyMonitorView.live.allObjects.contains { $0.window === window && $0.isActive }
    }

    /// 輸入框要不要把這一鍵讓給卡：這個視窗有卡開著、不在組字、是卡要的鍵。
    @MainActor static func yieldsToCard(_ event: NSEvent, in window: NSWindow?) -> Bool {
        isOpen(in: window) && !isComposing(in: window) && key(for: event) != nil
    }
}

/// 卡的鍵盤監看（本機事件監看，同點卡外收起那一層的做法）：卡開著時收卡要的鍵；組字中、別的視窗、卡不要的鍵照舊往下傳。
final class TatwoComposerModeKeyMonitorView: NSView {
    static let live = NSHashTable<TatwoComposerModeKeyMonitorView>.weakObjects()
    /// 回 true＝卡收下這一鍵（不再往下給輸入框、視窗）。
    var onKey: (@MainActor (TatwoComposerModeKeyboard.Key) -> Bool)?
    /// 卡還開著嗎（收起的那一刻就是 false——卡淡出的那一下不再搶鍵，輸入框的 Return 照常送出）。
    var isLive: (@MainActor () -> Bool)?
    var isActive: Bool { onKey != nil && (isLive?() ?? true) }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
            Self.live.remove(self)
        } else {
            Self.live.add(self)
            start()
        }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    isolated deinit {
        stop()
    }

    private func consumes(_ event: NSEvent) -> Bool {
        guard isActive, let window, event.window === window, let onKey,
              !TatwoComposerModeKeyboard.isComposing(in: window),
              let key = TatwoComposerModeKeyboard.key(for: event) else { return false }
        return onKey(key)
    }
}

struct TatwoComposerModeKeyMonitor: NSViewRepresentable {
    let onKey: @MainActor (TatwoComposerModeKeyboard.Key) -> Bool
    let isLive: @MainActor () -> Bool

    func makeNSView(context: Context) -> TatwoComposerModeKeyMonitorView {
        let view = TatwoComposerModeKeyMonitorView()
        view.onKey = onKey
        view.isLive = isLive
        return view
    }

    func updateNSView(_ view: TatwoComposerModeKeyMonitorView, context: Context) {
        view.onKey = onKey
        view.isLive = isLive
    }

    static func dismantleNSView(_ view: TatwoComposerModeKeyMonitorView, coordinator: ()) {
        view.onKey = nil
        view.isLive = nil
        view.stop()
    }
}

// MARK: - 收卡（Esc）：掛卡的那一層把「收起」交給卡

struct TatwoComposerModeDismiss {
    let action: @MainActor () -> Void
    /// 卡現在還算開著（讀掛卡那一層的開關；卡淡出途中已經是 false）。
    let isPresented: @MainActor () -> Bool
}

private struct TatwoComposerModeDismissKey: EnvironmentKey {
    static var defaultValue: TatwoComposerModeDismiss? { nil }
}

extension EnvironmentValues {
    /// 卡由 TatwoComposerModePopover 掛出來時才有（Plan 畫布那張沒有：不收鍵盤）。
    var tatwoComposerModeDismiss: TatwoComposerModeDismiss? {
        get { self[TatwoComposerModeDismissKey.self] }
        set { self[TatwoComposerModeDismissKey.self] = newValue }
    }
}

// MARK: - 收卡後焦點回輸入框

/// 掛卡的那個輸入框在視窗裡的位置（墊在輸入框底下，不畫、不接點擊）；收卡後找它裡面的文字輸入（ChatComposerTextView）交回焦點。
final class TatwoComposerModeHostRef {
    weak var view: NSView?

    /// 收卡之後：剛剛點到別的輸入的地方（輸入框外的文字框拿著鍵盤）就不搶；其他（沒人拿著、按了送出、按了 Esc）交回輸入框。
    @MainActor func restoreFocusSoon() {
        Task { @MainActor [weak self] in self?.restoreFocus() }
    }

    @MainActor func restoreFocus() {
        guard let view, let window = view.window, let root = window.contentView else { return }
        let frame = view.convert(view.bounds, to: nil)
        guard let input = Self.textViews(in: root).first(where: { candidate in
            candidate.isEditable && frame.intersects(candidate.convert(candidate.bounds, to: nil))
        }) else { return }
        if window.firstResponder === input { return }
        if let current = window.firstResponder as? NSView, current is NSText || current is NSTextField,
           !frame.intersects(current.convert(current.bounds, to: nil)) {
            return
        }
        window.makeFirstResponder(input)
    }

    @MainActor static func textViews(in root: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        func visit(_ view: NSView) {
            if let text = view as? ChatComposerTextView.ComposerNSTextView { found.append(text) }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return found
    }
}

struct TatwoComposerModeHostMarker: NSViewRepresentable {
    let ref: TatwoComposerModeHostRef

    func makeNSView(context: Context) -> TatwoComposerModePassiveView {
        let view = TatwoComposerModePassiveView()
        ref.view = view
        return view
    }

    func updateNSView(_ view: TatwoComposerModePassiveView, context: Context) {
        ref.view = view
    }
}

/// 不畫、不接點擊的定位點（輸入框的範圍、卡的捲動區）。
final class TatwoComposerModePassiveView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 捲動後看不到的拉條不接滑鼠（W184 H4 修正：審查 #4）

/// 卡中間那一段捲動時的可視範圍（墊在 ScrollView 後面的定位點）；拉條的滑鼠監看只接落在這裡面的按下
/// （被捲走、落在固定的標題／S～XXL／底列上的不算）。
final class TatwoComposerModeViewport {
    weak var view: NSView?

    /// 可視範圍（視窗座標）；還沒畫出來、不在同一個視窗＝nil（不限）。
    @MainActor func windowRect(in window: NSWindow?) -> NSRect? {
        guard let view, let window, view.window === window else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

struct TatwoComposerModeViewportMarker: NSViewRepresentable {
    let viewport: TatwoComposerModeViewport

    func makeNSView(context: Context) -> TatwoComposerModeViewportView {
        let view = TatwoComposerModeViewportView()
        viewport.view = view
        return view
    }

    func updateNSView(_ view: TatwoComposerModeViewportView, context: Context) {
        viewport.view = view
    }
}

/// 卡中間那一段捲動時的可視範圍（不畫、不接點擊；自測也照它找捲動區在哪）。
final class TatwoComposerModeViewportView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TatwoComposerModeViewportKey: EnvironmentKey {
    static var defaultValue: TatwoComposerModeViewport? { nil }
}

extension EnvironmentValues {
    /// 卡中間那一段在捲的時候才有；拉條把它交給 ChatSliderPointerOverlay。
    var tatwoComposerModeViewport: TatwoComposerModeViewport? {
        get { self[TatwoComposerModeViewportKey.self] }
        set { self[TatwoComposerModeViewportKey.self] = newValue }
    }
}
