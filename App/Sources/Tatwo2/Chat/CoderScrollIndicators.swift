import SwiftUI
import AppKit
extension View {
    func coderScrollIndicators(_ enabled: Bool = true) -> some View { scrollIndicators(enabled ? .never : .automatic) }
}

class CoderOverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        keepOverlay()
        NotificationCenter.default.addObserver(self, selector: #selector(keepOverlay), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("Coder scroll views are created programmatically") }
    @objc private func keepOverlay() { scrollerStyle = .overlay; autohidesScrollers = true }
    deinit { NotificationCenter.default.removeObserver(self) }
}
