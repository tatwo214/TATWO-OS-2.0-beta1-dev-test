import SwiftUI
import AppKit
import Combine

// A2 palette shared by the native layers, progress ring and file tile.
enum BrowserDownloadPalette {
    static let purple = Color(red: 155/255, green: 124/255, blue: 240/255)
    static let deep = Color(red: 91/255, green: 60/255, blue: 196/255)
    static let sparks = [purple, Color(red: 201/255, green: 184/255, blue: 1), Color(red: 242/255, green: 184/255, blue: 75/255)]
    static let gradient = LinearGradient(colors: [purple, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

@MainActor final class BrowserDownloadFlight: ObservableObject {
    static let shared = BrowserDownloadFlight()
    final class Marker: NSView {
        var scope = "browser", anchor = false, reduced = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); BrowserDownloadFlight.shared.register(self) }
    }
    final class Overlay: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private class WeakMarker { weak var value: Marker?; init(_ view: Marker) { value = view } }
    private var markers: [WeakMarker] = []
    private var monitor: Any?
    private var events: AnyCancellable?
    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in self?.record(event); return event }
        events = NotificationCenter.default.publisher(for: BrowserDownloadStore.motionEvent, object: BrowserDownloadStore.shared).sink { [weak self] note in
            MainActor.assumeIsolated { guard let item = note.userInfo?["item"] as? BrowserDownloadStore.Item else { return }
                if note.userInfo?["start"] as? Bool == true { self?.start(item) } else { self?.completed(item) }
            }
        }
    }
    private(set) var click: (point: CGPoint, window: Int, time: TimeInterval)?
    @Published private(set) var routes: [String: String] = [:]
    @Published private(set) var landed: Set<String> = []
    @Published private(set) var completions: Set<String> = []
    @Published private(set) var dismissed: Set<String> = []
    @Published private(set) var pulses: [String: UUID] = [:]
    var deadlines: [String: Date] = [:]
    private var queue: [(BrowserDownloadStore.Item, Marker, CGPoint)] = []
    private var flying = false
    private var latest: [String: String] = [:]
    private var fallbackViews: [Int: NSHostingView<BrowserDownloadCard>] = [:]
#if DEBUG
    private(set) var evidence: [(id: String, scope: String, start: CGPoint, end: CGPoint, recent: Bool)] = []
    private(set) var overlay: Overlay?
#endif
    private func register(_ view: Marker) {
        markers.removeAll { $0.value == nil }
        if !markers.contains(where: { $0.value === view }) { markers.append(WeakMarker(view)) }
    }
    func record(_ event: NSEvent) {
        guard let window = event.window, let root = window.contentView else { return }
        var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        while let view = hit {
            if view is TatwoCEFBrowserView { click = (event.locationInWindow, window.windowNumber, ProcessInfo.processInfo.systemUptime); return }
            hit = view.superview
        }
    }
    private func visible(_ view: Marker) -> Bool { view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor && view.visibleRect.width > 0 && view.visibleRect.height > 0 }
    func items(_ scope: String) -> [BrowserDownloadStore.Item] { BrowserDownloadStore.shared.downloads.filter { routes[$0.id] == scope } }
    func feedback(_ scope: String) -> BrowserDownloadStore.Item? { items(scope).first { !dismissed.contains($0.id) && ($0.id == latest[scope] || !$0.state.isTerminal) } }
    private func assign(_ id: String, _ scope: String) { latest[scope] = id; routes[id] = scope }
    func dismiss(_ id: String) { dismissed.insert(id); BrowserDownloadStore.shared.dismissFeedback(id) }
    func start(_ item: BrowserDownloadStore.Item) {
        let recent = click.flatMap { ProcessInfo.processInfo.systemUptime - $0.time <= 5 ? $0 : nil }
        let window = recent?.window ?? (NSApp.keyWindow ?? NSApp.mainWindow)?.windowNumber ?? markers.compactMap(\.value).last(where: visible)?.window?.windowNumber
        let hosts = markers.compactMap(\.value).filter { !$0.anchor && visible($0) && $0.window?.windowNumber == window }
        let host = hosts.last { view in recent.map { view.convert(view.bounds, to: nil).contains($0.point) } ?? false } ?? hosts.last
        guard let host else {
            if let anchor = markers.compactMap(\.value).last(where: { $0.anchor && visible($0) && $0.window?.windowNumber == window }) {
                assign(item.id, anchor.scope); queue.append((item, anchor, recent?.point ?? anchor.convert(.zero, to: nil))); drain()
            } else { fallbackCard(item, window: window) }
            return
        }
        assign(item.id, host.scope)
        let rect = host.convert(host.bounds, to: nil)
        let from = recent?.point ?? CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.3)
        if !host.reduced, let view = canvas(host), let layer = view.layer {
            let point = view.convert(from, from: nil)
            ring(point, size: 20, scale: 4.5, delay: 0, in: layer); ring(point, size: 20, scale: 4.5, delay: 0.11, in: layer)
            burst(point, count: 8, distance: 44, in: layer)
            Task { try? await Task.sleep(for: .milliseconds(630)); view.removeFromSuperview() }
        }
        if flying && !queue.isEmpty {
            landed.insert(item.id)
            if let anchor = markers.compactMap(\.value).last(where: { $0.anchor && $0.scope == host.scope && $0.window === host.window && visible($0) }) { pulses[host.scope] = UUID(); if !host.reduced { decorate(anchor) } }
            return
        }
        queue.append((item, host, from)); drain()
    }
    private func fallbackCard(_ item: BrowserDownloadStore.Item, window: Int?) {
        guard let window, let root = NSApp.windows.first(where: { $0.windowNumber == window })?.contentView else { return }
        let scope = "fallback-\(window)"; assign(item.id, scope); landed.insert(item.id)
        if fallbackViews[window]?.window === root.window { return }
        let card = NSHostingView(rootView: BrowserDownloadCard(scope: scope, width: min(280, max(0, root.bounds.width - 28))))
        let height = card.fittingSize.height
        card.frame = CGRect(x: 14, y: root.isFlipped ? root.bounds.height - height - 14 : 14, width: min(280, max(0, root.bounds.width - 28)), height: height)
        card.autoresizingMask = [.maxXMargin, root.isFlipped ? .minYMargin : .maxYMargin]
        fallbackViews[window] = card; root.addSubview(card, positioned: .above, relativeTo: nil)
        Task { while card.window != nil && self.feedback(scope) != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }; card.removeFromSuperview(); if self.fallbackViews[window] === card { self.fallbackViews[window] = nil }
        }
    }
    func completed(_ item: BrowserDownloadStore.Item) {
        deadlines[item.id] = Date().addingTimeInterval(4); completions.insert(item.id)
        Task { try? await Task.sleep(for: .milliseconds(1200)); self.completions.remove(item.id) }
        guard let scope = routes[item.id] else { return }
        if items(scope).first(where: { $0.id == latest[scope] }).map({ dismissed.contains($0.id) }) ?? true { latest[scope] = item.id }
        pulses[scope] = UUID()
        if let anchor = markers.compactMap(\.value).last(where: { $0.anchor && $0.scope == scope && visible($0) }), !anchor.reduced {
            decorate(anchor, completion: true)
        }
    }
    private func drain() {
        guard !flying, !queue.isEmpty else { return }
        flying = true
        let (item, host, from) = queue.removeFirst()
        Task { @MainActor in
            // Let a newly inserted floating button finish layout; no frame timer.
            await Task.yield()
            if !self.markers.contains(where: { $0.value?.anchor == true && $0.value?.scope == host.scope && $0.value?.window === host.window }) { try? await Task.sleep(for: .milliseconds(20)) }
            let anchor = self.markers.compactMap(\.value).last { $0.anchor && $0.scope == host.scope && $0.window === host.window && self.visible($0) }
            if let anchor, self.visible(host), !host.reduced { self.fly(item, host: host, anchor: anchor, from: from) }
            else { self.landed.insert(item.id); self.flying = false; self.drain() }
        }
    }
    private func canvas(_ anchor: Marker) -> Overlay? {
        guard let root = anchor.window?.contentView else { return nil }
        let view = Overlay(frame: root.bounds); view.wantsLayer = true; view.autoresizingMask = [.width, .height]
        root.addSubview(view, positioned: .above, relativeTo: nil)
#if DEBUG
        overlay = view
#endif
        return view
    }
    private func animate(_ layer: CALayer, _ key: String, _ values: [Any], _ duration: Double, delay: Double = 0, times: [Double]? = nil, timing: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1), fill: CAMediaTimingFillMode = .both) {
        let animation = CAKeyframeAnimation(keyPath: key); animation.values = values; animation.keyTimes = times?.map { NSNumber(value: $0) }
        animation.duration = duration; animation.beginTime = CACurrentMediaTime() + delay
        animation.timingFunction = timing
        animation.fillMode = fill; animation.isRemovedOnCompletion = false; layer.add(animation, forKey: key)
    }
    private func ring(_ point: CGPoint, size: CGFloat, scale: Double, delay: Double, in layer: CALayer) {
        let ring = CAShapeLayer(); ring.name = size == 20 ? "download.ripple" : "download.halo"; ring.opacity = 0; ring.bounds = CGRect(x: 0, y: 0, width: size, height: size); ring.position = point
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil); ring.fillColor = nil
        ring.strokeColor = NSColor(BrowserDownloadPalette.purple).cgColor; ring.lineWidth = 2; layer.addSublayer(ring)
        animate(ring, "transform.scale", [1, scale], size == 20 ? 0.52 : 0.56, delay: delay, timing: CAMediaTimingFunction(name: .easeOut))
        animate(ring, "opacity", [size == 20 ? 0.9 : 0.7, 0], size == 20 ? 0.52 : 0.56, delay: delay, timing: CAMediaTimingFunction(name: .easeOut), fill: .forwards)
    }
    private func burst(_ point: CGPoint, count: Int, distance: Double, completion: Bool = false, in layer: CALayer) {
        let colors = completion ? [BrowserDownloadPalette.purple, BrowserDownloadPalette.sparks[2], Color(red: 123/255, green: 211/255, blue: 137/255)] : BrowserDownloadPalette.sparks
        for i in 0..<count {
            let dot = CALayer(); dot.name = "download.spark"; dot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6); dot.cornerRadius = 3
            dot.backgroundColor = NSColor(colors[i % 3]).cgColor; dot.position = point; layer.addSublayer(dot)
            let angle = Double(i) * .pi * 2 / Double(count) + (i % 2 == 1 ? 0.25 : 0)
            let radius = distance * (0.75 + 0.5 * Double((i * 7) % 5) / 5)
            animate(dot, "position", [point, CGPoint(x: point.x + cos(angle) * radius, y: point.y + sin(angle) * radius)], 0.56)
            animate(dot, "transform.scale", [1, 0.3], 0.56); animate(dot, "opacity", [1, 0], 0.56)
        }
    }
    private func decorate(_ anchor: Marker, completion: Bool = false) {
        guard let view = canvas(anchor), let layer = view.layer else { return }
        let point = view.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), from: anchor)
        ring(point, size: 34, scale: 2.6, delay: 0, in: layer)
        if completion { burst(point, count: 6, distance: 26, completion: true, in: layer) }
        Task { try? await Task.sleep(for: .milliseconds(560)); view.removeFromSuperview() }
    }
    private func fly(_ item: BrowserDownloadStore.Item, host: Marker, anchor: Marker, from: CGPoint) {
        guard let view = canvas(anchor), let layer = view.layer else { landed.insert(item.id); flying = false; drain(); return }
        let start = view.convert(from, from: nil), lift = CGPoint(x: start.x, y: start.y - 34)
        let end = view.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), from: anchor)
#if DEBUG
        evidence.append((item.id, host.scope, from, anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil), click.map { ProcessInfo.processInfo.systemUptime - $0.time <= 5 } ?? false))
#endif
        let file = CALayer(); file.name = "download.file"; file.bounds = CGRect(x: 0, y: 0, width: 34, height: 40)
        file.backgroundColor = NSColor.white.cgColor; file.cornerRadius = 6; file.borderWidth = 1
        file.borderColor = NSColor(BrowserDownloadPalette.purple).withAlphaComponent(0.35).cgColor
        file.shadowColor = NSColor(BrowserDownloadPalette.deep).cgColor; file.shadowOpacity = 0.28; file.shadowRadius = 7; file.shadowOffset = CGSize(width: 0, height: 4)
        let icon = CATextLayer(); icon.string = item.fileURL.pathExtension.uppercased(); icon.fontSize = 9; icon.alignmentMode = .center
        icon.foregroundColor = NSColor(BrowserDownloadPalette.deep).cgColor; icon.frame = CGRect(x: 0, y: 14, width: 34, height: 14); icon.contentsScale = view.window?.backingScaleFactor ?? 2
        file.addSublayer(icon); layer.addSublayer(file)
        // Name pill hugs its text (prototype A2: 10 pt semibold ink, 7 pt side padding, soft shadow); long names truncate in the middle.
        let tagText = NSAttributedString(string: item.name, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                         .foregroundColor: NSColor(red: 43/255, green: 38/255, blue: 32/255, alpha: 1)])
        let tagWidth = min(ceil(tagText.size().width) + 14, 220), tagHeight: CGFloat = 17
        let tag = CALayer(); tag.backgroundColor = NSColor.white.cgColor; tag.cornerRadius = tagHeight / 2
        tag.shadowColor = NSColor.black.cgColor; tag.shadowOpacity = 0.12; tag.shadowRadius = 4; tag.shadowOffset = CGSize(width: 0, height: 2)
        tag.frame = CGRect(x: (34 - tagWidth) / 2, y: 44, width: tagWidth, height: tagHeight); file.addSublayer(tag)
        let label = CATextLayer(); label.string = tagText; label.alignmentMode = .center; label.truncationMode = .middle
        label.contentsScale = icon.contentsScale; label.frame = CGRect(x: 7, y: 2, width: tagWidth - 14, height: 13); tag.addSublayer(label)
        animate(tag, "opacity", [1, 0], 0.16, delay: 0.42, timing: CAMediaTimingFunction(name: .linear))
        let control = CGPoint(x: (lift.x + end.x) / 2, y: min(lift.y, end.y) - 150)
        let path = CGMutablePath(); path.move(to: lift); path.addQuadCurve(to: end, control: control)
        let travel = CAKeyframeAnimation(keyPath: "position"); travel.path = path; travel.duration = 0.76
        travel.beginTime = CACurrentMediaTime() + 0.42; travel.fillMode = .forwards; travel.isRemovedOnCompletion = false
        travel.timingFunction = CAMediaTimingFunction(controlPoints: 0.35, 0.05, 0.25, 1)
        file.position = lift; animate(file, "position", [start, lift, lift], 0.3, times: [0, 0.6, 1]); file.add(travel, forKey: "travel")
        animate(file, "transform.scale", [0.3, 1.18, 1], 0.3, times: [0, 0.6, 1], timing: CAMediaTimingFunction(controlPoints: 0.2, 1.4, 0.4, 1))
        animate(file, "opacity", [0, 1, 1], 0.3, times: [0, 0.6, 1])
        func travelAnimation(_ key: String, values: [Double], times: [Double]? = nil) {
            let animation = CAKeyframeAnimation(keyPath: key); animation.values = values; animation.keyTimes = times?.map { NSNumber(value: $0) }
            animation.duration = 0.76; animation.beginTime = CACurrentMediaTime() + 0.42; animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            animation.timingFunction = travel.timingFunction; file.add(animation, forKey: "travel." + key)
        }
        travelAnimation("transform.scale", values: [1, 0.38]); travelAnimation("transform.rotation", values: [0, -16 * Double.pi / 180])
        travelAnimation("opacity", values: [1, 1, 0], times: [0, 0.92, 1])
        Task { try? await Task.sleep(for: .milliseconds(1180)); view.removeFromSuperview()
            self.landed.insert(item.id); self.pulses[host.scope] = UUID(); self.decorate(anchor)
            self.flying = false; self.drain()
        }
    }
}

struct BrowserDownloadRegistration: NSViewRepresentable {
    let scope: String
    var anchor = false
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @Environment(\.browserDownloadReducedMotion) private var override
    func makeNSView(context: Context) -> BrowserDownloadFlight.Marker { BrowserDownloadFlight.Marker() }
    func updateNSView(_ view: BrowserDownloadFlight.Marker, context: Context) { view.scope = scope; view.anchor = anchor; view.reduced = systemReduce || override == true }
}

struct BrowserDownloadSurface: ViewModifier {
    let scope: String
    /// Browser work space: the floating button stands in for the sidebar one, so it follows the whole history.
    var persistent = false
    var floating = true
    var showsCard = true
    @ObservedObject private var store = BrowserDownloadStore.shared
    @ObservedObject private var flight = BrowserDownloadFlight.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @Environment(\.browserDownloadReducedMotion) private var override
    @State private var presented = false
    func body(content: Content) -> some View {
        content.background(BrowserDownloadRegistration(scope: scope))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 8) {
                        // 10-07 使用者：有下載才出現，下載完留著，按「清除紀錄」才消失。
                        if floating, persistent ? !store.downloads.isEmpty : !flight.items(scope).isEmpty {
                            Button { store.markDownloadsSeen(); presented.toggle() } label: { BrowserDownloadIndicator(scope: scope).frame(width: 34, height: 34) }
                                .buttonStyle(.plain).background(.white, in: Circle()).foregroundStyle(BrowserDownloadPalette.deep)
                                .shadow(color: .black.opacity(0.18), radius: 9, y: 3)
                                .popover(isPresented: $presented) { ChatBrowserDownloadsView() }
                                .transition(systemReduce || override == true ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                                .accessibilityIdentifier("browser.download.floating")
                        }
                        if showsCard { BrowserDownloadCard(scope: scope, width: min(BrowserSidebarMetrics.downloadsWidth, max(0, geometry.size.width - (floating ? 70 : 28)))) }
                    }.padding(14).frame(maxHeight: .infinity, alignment: .bottom)
                }.allowsHitTesting(true)
            }
            .animation(systemReduce || override == true || flight.feedback(scope) == nil ? .easeOut(duration: 0.26) : .spring(duration: 0.28, bounce: 0.2), value: flight.feedback(scope)?.id)
    }
}
