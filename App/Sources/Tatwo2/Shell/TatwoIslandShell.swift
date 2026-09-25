// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoIslandShell.swift；改動 56 行（原因：保留既有接線；使用者 2026-09-06「全做」Island 三秒 policy、點擊鎖定與外點／Esc；不改排版）
import AppKit
import SwiftUI

extension Notification.Name {
    /// W105：Island 設定（總開關／尺寸／風格）變動，供 controller 立即套用，不必重開 App。
    static let tatwoIslandSettingsChanged = Notification.Name("tatwo.island.settingsChanged")
}

/// Settings › Tatwo Island（W105，使用者 2026-09-19「island開關、尺寸調節(黑劉海跟玻璃尺寸分開調)、風格」）。
/// 刻意放在本檔：Island 幾何要能跟著設定走，而 tests/island-hover.test.mjs 是單檔編譯這支 Shell，
/// 模型拆出去會讓那個契約測試失去自足性。全部出廠值＝今天的外觀，滑桿沒動過就一模一樣。
@MainActor
final class TatwoIslandSettings: ObservableObject {
    static let shared = TatwoIslandSettings()

    private enum Key {
        static let enabled = "tatwo.island.enabled"
        static let notchScale = "tatwo.island.notchScale"
        static let glassScale = "tatwo.island.glassScale"
        static let glassOpacity = "tatwo.island.glassOpacity"
    }

    /// 兩支滑桿共用的倍率區間；1.0＝出廠尺寸。
    nonisolated static let scaleRange: ClosedRange<Double> = 0.6...1.6
    nonisolated static let defaultScale: Double = 1

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled); settingsChanged() }
    }
    /// 黑瀏海（收合態）尺寸倍率，與玻璃分開調。
    @Published var notchScale: Double {
        didSet {
            UserDefaults.standard.set(notchScale, forKey: Key.notchScale)
            settingsChanged()
        }
    }
    /// 玻璃（展開態）尺寸倍率，與黑瀏海分開調。
    /// 設定頁正在拖「玻璃尺寸」：真的 Island 暫時保持展開，邊拖邊看；放手就收回。不存檔。
    @Published var previewExpanded = false { didSet { if previewExpanded != oldValue { settingsChanged() } } }

    /// 展開後那片玻璃的不透明度（1＝原版）。只影響玻璃，不影響黑瀏海。
    nonisolated static let glassOpacityRange: ClosedRange<Double> = 0.3...1
    @Published var glassOpacity: Double {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: Key.glassOpacity); settingsChanged() }
    }
    nonisolated static var glassOpacityValue: Double {
        let value = UserDefaults.standard.object(forKey: Key.glassOpacity) as? Double ?? 1
        return min(max(value, glassOpacityRange.lowerBound), glassOpacityRange.upperBound)
    }

    @Published var glassScale: Double {
        didSet {
            UserDefaults.standard.set(glassScale, forKey: Key.glassScale)
            settingsChanged()
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        notchScale = Self.clamped(defaults.object(forKey: Key.notchScale) as? Double)
        glassScale = Self.clamped(defaults.object(forKey: Key.glassScale) as? Double)
        glassOpacity = Self.glassOpacityValue
    }

    func resetSizes() {
        notchScale = Self.defaultScale
        glassScale = Self.defaultScale
        glassOpacity = 1
    }

    private func settingsChanged() {
        NotificationCenter.default.post(name: .tatwoIslandSettingsChanged, object: nil)
    }

    nonisolated private static func clamped(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return defaultScale }
        return min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    // 幾何在非 main actor 的 enum 裡讀，UserDefaults 本身是 thread-safe（同 ComputerUseSettings.isEnabled）。
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
    }
    nonisolated static var notchScaleValue: CGFloat {
        CGFloat(clamped(UserDefaults.standard.object(forKey: Key.notchScale) as? Double))
    }
    nonisolated static var glassScaleValue: CGFloat {
        CGFloat(clamped(UserDefaults.standard.object(forKey: Key.glassScale) as? Double))
    }
}

enum TatwoIslandShellMetrics {
    struct ShellGeometry {
        let bodySize: NSSize
        let shellSize: NSSize
        let topReverseCornerRadius: CGFloat
        let bottomCornerRadius: CGFloat
    }

    // Measured from the supplied Vibe Island references at 2x scale.
    // W105：這一組是出廠基準，設定頁的兩支倍率滑桿乘在上面（倍率 1.0 時數值與過去完全相同）。
    static let baseCollapsedSize = NSSize(width: 240, height: 33)
    static let baseExpandedSize = NSSize(width: 648, height: 172)
    static let baseCollapsedTopReverseCornerRadius: CGFloat = 10
    static let baseExpandedTopReverseCornerRadius: CGFloat = 22
    static let baseCollapsedBottomCornerRadius: CGFloat = 17
    static let baseExpandedBottomCornerRadius: CGFloat = 28

    /// 黑瀏海＝收合態，玻璃＝展開態；兩組尺寸各自獨立，對應設定頁兩支滑桿。
    static var notchScale: CGFloat { TatwoIslandSettings.notchScaleValue }
    static var glassScale: CGFloat { TatwoIslandSettings.glassScaleValue }


    /// 使用者 2026-09-19：MacBook 本身就有實體瀏海，Island 只是做出「瀏海會延伸」的效果。等比縮放會讓軟體黑瀏海
    /// 比實體的矮或窄，實體那塊就露餡。所以黑瀏海只調左右寬度：高度永遠等於這台螢幕的實體瀏海（各型號自己量），
    /// 寬度縮到最小也比實體瀏海每側多 `hardwareNotchMargin`。沒有實體瀏海的螢幕（外接、mini）沿用出廠高度。
    /// 由 controller 在定位視窗時更新成 Island 所在那面螢幕的量測值。
    static var hardwareNotch: NSSize?
    static let hardwareNotchMargin: CGFloat = 8
    static func hardwareNotch(of screen: NSScreen) -> NSSize? {
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        return width > 40 ? NSSize(width: width, height: screen.safeAreaInsets.top) : nil
    }
    static var minimumCollapsedWidth: CGFloat {
        hardwareNotch.map { $0.width + hardwareNotchMargin * 2 } ?? baseCollapsedSize.width * CGFloat(TatwoIslandSettings.scaleRange.lowerBound)
    }
    static var collapsedSize: NSSize {
        NSSize(
            width: max(baseCollapsedSize.width * notchScale, minimumCollapsedWidth),
            height: hardwareNotch?.height ?? baseCollapsedSize.height
        )
    }
    static var expandedSize: NSSize {
        NSSize(
            width: baseExpandedSize.width * glassScale,
            height: baseExpandedSize.height * glassScale
        )
    }
    static var collapsedTopReverseCornerRadius: CGFloat {
        baseCollapsedTopReverseCornerRadius   // 高度不縮放，圓角也不縮放
    }
    static var expandedTopReverseCornerRadius: CGFloat {
        baseExpandedTopReverseCornerRadius * glassScale
    }
    static var collapsedBottomCornerRadius: CGFloat {
        min(baseCollapsedBottomCornerRadius, collapsedSize.height / 2)
    }
    static var expandedBottomCornerRadius: CGFloat {
        baseExpandedBottomCornerRadius * glassScale
    }
    /// 承載視窗要同時裝得下放大的玻璃與放大的黑瀏海，否則其中一邊會被裁掉。
    static var expandedOverlaySize: NSSize {
        let glassWidth = expandedSize.width + (expandedTopReverseCornerRadius * 2)
        let notchWidth = collapsedSize.width + (collapsedTopReverseCornerRadius * 2)
        return NSSize(
            width: max(glassWidth, notchWidth),
            height: max(expandedSize.height, collapsedSize.height)
        )
    }
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    static let collapseDelay: TimeInterval = IslandCollapsePolicy.delay
    static let expandAnimation = Animation.spring(
        response: 0.42,
        dampingFraction: 0.8,
        blendDuration: 0
    )
    static let collapseAnimation = Animation.smooth(duration: 0.22)

    static func transitionAnimation(expanding: Bool) -> Animation {
        expanding ? expandAnimation : collapseAnimation
    }

    static func geometry(progress: CGFloat, within overlaySize: NSSize) -> ShellGeometry {
        let clampedProgress = min(max(progress, 0), 1)
        let bodySize = NSSize(
            width: min(
                interpolated(collapsedSize.width, expandedSize.width, progress: clampedProgress),
                max(0, overlaySize.width)
            ),
            height: min(
                interpolated(collapsedSize.height, expandedSize.height, progress: clampedProgress),
                max(0, overlaySize.height)
            )
        )
        let preferredTopRadius = interpolated(
            collapsedTopReverseCornerRadius,
            expandedTopReverseCornerRadius,
            progress: clampedProgress
        )
        let topReverseCornerRadius = min(
            preferredTopRadius,
            max(0, (overlaySize.width - bodySize.width) / 2),
            bodySize.width / 2,
            bodySize.height
        )
        let bottomCornerRadius = min(
            interpolated(
                collapsedBottomCornerRadius,
                expandedBottomCornerRadius,
                progress: clampedProgress
            ),
            bodySize.width / 2,
            bodySize.height
        )

        return ShellGeometry(
            bodySize: bodySize,
            shellSize: NSSize(
                width: bodySize.width + (topReverseCornerRadius * 2),
                height: bodySize.height
            ),
            topReverseCornerRadius: topReverseCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    static func overlayFrame(in screenFrame: NSRect) -> NSRect {
        let availableWidth = max(0, screenFrame.width)
        let availableHeight = max(0, screenFrame.height)
        let overlaySize = NSSize(
            width: min(expandedOverlaySize.width, availableWidth),
            height: min(expandedOverlaySize.height, availableHeight)
        )
        return NSRect(
            x: screenFrame.midX - (overlaySize.width / 2),
            y: screenFrame.maxY - overlaySize.height,
            width: overlaySize.width,
            height: overlaySize.height
        )
    }

    private static func interpolated(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
        start + ((end - start) * progress)
    }
}

@MainActor
final class TatwoIslandShellState: ObservableObject {
    private(set) var isExpanded: Bool
    @Published private(set) var expansionProgress: CGFloat
    private let collapseDelay: TimeInterval
    private var pointerIsInside = false
    private var pendingCollapse: DispatchWorkItem?
    private var collapsePolicy = IslandCollapsePolicy()
    /// 同意卡優先於游標；解除 hold 時若游標在外，立即收回。
    private var isHeldOpen = false

    // 驗證用：TATWO_ISLAND_PIN_EXPANDED=1 讓島常駐展開（截圖對照迴圈）
    static let pinExpandedForVerification =
        ProcessInfo.processInfo.environment["TATWO_ISLAND_PIN_EXPANDED"] == "1"

    init(
        isExpanded: Bool = false,
        collapseDelay: TimeInterval = TatwoIslandShellMetrics.collapseDelay
    ) {
        let pinned = Self.pinExpandedForVerification
        self.isExpanded = isExpanded || pinned
        self.expansionProgress = (isExpanded || pinned) ? 1 : 0
        self.collapseDelay = collapseDelay
    }

    func setPointerInside(_ pointerInside: Bool) {
        guard pointerIsInside != pointerInside else { return }
        pointerIsInside = pointerInside
        guard !isHeldOpen else { return }
        pendingCollapse?.cancel()
        pendingCollapse = nil

        if pointerInside {
            collapsePolicy.handle(.hoverEntered)
            setExpanded(true)
            return
        }

        collapsePolicy.handle(.hoverExited(at: ProcessInfo.processInfo.systemUptime))
        scheduleCollapse()
    }

    func holdOpen(_ held: Bool) {
        isHeldOpen = held
        pendingCollapse?.cancel()
        pendingCollapse = nil
        collapsePolicy = IslandCollapsePolicy()
        if held || pointerIsInside || Self.pinExpandedForVerification {
            setExpanded(true)
        } else {
            collapsePolicy.handle(.hoverExited(at: ProcessInfo.processInfo.systemUptime))
            scheduleCollapse()
        }
    }

    func handleCollapseEvent(_ event: IslandCollapsePolicy.Event) {
        guard !isHeldOpen else { return }
        if collapsePolicy.handle(event), !Self.pinExpandedForVerification {
            pendingCollapse?.cancel()
            pendingCollapse = nil
            setExpanded(false)
        } else if case .tick = event,
                  let remaining = collapsePolicy.remainingDelay(at: ProcessInfo.processInfo.systemUptime) {
            scheduleCollapse(after: max(0.01, remaining))
        }
    }

    func expandForNavigation() {
        setExpanded(true)
        guard !isHeldOpen, !pointerIsInside else { return }
        pendingCollapse?.cancel()
        collapsePolicy = IslandCollapsePolicy()
        collapsePolicy.handle(.hoverExited(at: ProcessInfo.processInfo.systemUptime))
        // Navigation previews remain readable; a real hover exit still closes immediately.
        scheduleCollapse(after: 3)
    }

    private func scheduleCollapse(after delay: TimeInterval? = nil) {
        guard isExpanded, !Self.pinExpandedForVerification else { return }
        let delay = delay ?? collapseDelay
        if delay <= 0 {
            handleCollapseEvent(.tick(now: ProcessInfo.processInfo.systemUptime))
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsInside else { return }
            self.pendingCollapse = nil
            self.handleCollapseEvent(.tick(now: ProcessInfo.processInfo.systemUptime))
        }
        pendingCollapse = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func setExpanded(_ isExpanded: Bool) {
        guard self.isExpanded != isExpanded else { return }
        self.isExpanded = isExpanded
        withAnimation(TatwoIslandShellMetrics.transitionAnimation(expanding: isExpanded)) {
            self.expansionProgress = isExpanded ? 1 : 0
        }
    }
}

@MainActor
final class TatwoIslandShellController {
    private let state: TatwoIslandShellState
    private let panel: TatwoIslandShellPanel
    private var localEvents: Any?
    private var outsideEvents: Any?
    private var pointerTimer: Timer?
    private var settingsObserver: NSObjectProtocol?

    init() {
        let state = TatwoIslandShellState()
        let hostingController = NSHostingController(rootView: TatwoIslandShellView(state: state))
        self.state = state
        IslandExceptionsNavigation.shell = state
        self.panel = TatwoIslandShellPanel(
            contentRect: .zero,
            viewController: hostingController
        )
        // 非 key panel 的 Esc 先取消目前卡片；空白 Island 才交回既有關窗路徑。
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.state.isExpanded else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    if let request = IslandNotice.shared.current {
                        IslandNotice.shared.resolve(.cancel, id: request.id)
                        return nil
                    }
                    self.state.handleCollapseEvent(.escape)
                    return event
                }
            } else {
                let geometry = TatwoIslandShellMetrics.geometry(progress: self.state.expansionProgress, within: self.panel.frame.size)
                let bounds = CGRect(x: (self.panel.frame.width - geometry.shellSize.width) / 2, y: 0,
                                    width: geometry.shellSize.width, height: geometry.shellSize.height)
                let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                let point = CGPoint(x: location.x - self.panel.frame.minX, y: self.panel.frame.maxY - location.y)
                let inside = event.window === self.panel && TatwoIslandShellShape(
                    topReverseCornerRadius: geometry.topReverseCornerRadius,
                    bottomCornerRadius: geometry.bottomCornerRadius).path(in: bounds).contains(point)
                self.state.handleCollapseEvent(inside ? .itemTapped : .outsideTapped)
            }
            return event
        }
        outsideEvents = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak state] _ in
            guard let state, state.isExpanded else { return }
            state.handleCollapseEvent(.outsideTapped)
        }
        // W105：總開關與尺寸改動當場生效，不必重開 App。
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .tatwoIslandSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    deinit {
        pointerTimer?.invalidate()
        if let localEvents { NSEvent.removeMonitor(localEvents) }
        if let outsideEvents { NSEvent.removeMonitor(outsideEvents) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func show() {
        // 總開關關閉＝Island 視窗根本不出現，計時器與 notice host 也一併停掉。
        guard TatwoIslandSettings.isEnabled else { hide(); return }
        IslandNotice.shared.hostAvailable = true
        updateOverlayFrame()
        panel.orderFrontRegardless()
        guard pointerTimer == nil else { return }
        // Non-key panels may miss mouseExited during SwiftUI rebuilds or drags.
        // Reconcile only an open, visible Island; no input monitoring permission.
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcilePointer() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    /// 關閉：收走視窗、停掉輪詢計時器，並交回 notice 的備援呈現路徑。
    func hide() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        IslandNotice.shared.hostAvailable = false
        panel.orderOut(nil)
    }

    /// 開關打開就原地復原（含新的尺寸），關閉就收掉。
    private var previewHeld = false

    private func applySettings() {
        guard TatwoIslandSettings.isEnabled else { hide(); return }
        show()
        let wantsPreview = TatwoIslandSettings.shared.previewExpanded
        if wantsPreview != previewHeld {
            previewHeld = wantsPreview
            // 同意卡自己也會 holdOpen；預覽放手時不可以把它的 hold 一起放掉。
            if wantsPreview || IslandNotice.shared.current == nil { state.holdOpen(wantsPreview) }
        }
    }

    private func reconcilePointer() {
        guard panel.isVisible, state.isExpanded else { return }
        let geometry = TatwoIslandShellMetrics.geometry(progress: state.expansionProgress, within: panel.frame.size)
        let bounds = CGRect(x: (panel.frame.width - geometry.shellSize.width) / 2, y: 0,
                            width: geometry.shellSize.width, height: geometry.shellSize.height)
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y)
        state.setPointerInside(TatwoIslandShellShape(
            topReverseCornerRadius: geometry.topReverseCornerRadius,
            bottomCornerRadius: geometry.bottomCornerRadius).path(in: bounds).contains(point))
    }

    private func updateOverlayFrame() {
        guard let screen = screenContainingPointer() ?? NSScreen.main else { return }
        TatwoIslandShellMetrics.hardwareNotch = TatwoIslandShellMetrics.hardwareNotch(of: screen)
        panel.setFrame(
            TatwoIslandShellMetrics.overlayFrame(in: screen.frame),
            display: true,
            animate: false
        )
    }

    private func screenContainingPointer() -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointerLocation) }
    }
}

@MainActor
final class TatwoIslandShellPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, viewController: NSViewController) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = TatwoIslandShellMetrics.windowLevel
        // 2026-09-02 使用者：island 在 Mission Control／App 展開時必須固定在瀏海位，不當成可移動視窗。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        contentViewController = viewController
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
struct TatwoIslandShellView: View {
    @ObservedObject var state: TatwoIslandShellState
    @ObservedObject private var notice = IslandNotice.shared
    @ObservedObject private var settings = TatwoIslandSettings.shared

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .overlay(alignment: .top) {
                    TatwoIslandShellSurface(
                        progress: state.expansionProgress,
                        overlaySize: proxy.size,
                        glassIsInteractive: state.isExpanded,
                        sizeScales: [settings.notchScale, settings.glassScale, settings.glassOpacity],
                        onHover: state.setPointerInside
                    )
                    .opacity(state.isExpanded && notice.current != nil ? 0 : 1)
                    .overlay(alignment: .top) {
                        // W43: ask / confirm / info share the same FIFO surface.
                        IslandNoticeContent(isExpanded: state.isExpanded)
                    }
                }
        }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tatwo Island")
            .accessibilityHint("將游標停留在容器上可展開")
    }
}

struct TatwoIslandShellSurface: View, @MainActor Animatable {
    var progress: CGFloat
    let overlaySize: NSSize
    let glassIsInteractive: Bool
    /// 兩組尺寸倍率不參與計算（幾何從 TatwoIslandShellMetrics 讀），但一定要是輸入：否則拖滑桿時 SwiftUI 看不到輸入改變就不重畫。
    let sizeScales: [Double]
    let onHover: (Bool) -> Void

    init(
        progress: CGFloat,
        overlaySize: NSSize,
        glassIsInteractive: Bool = true,
        sizeScales: [Double] = [],
        onHover: @escaping (Bool) -> Void
    ) {
        self.progress = progress
        self.overlaySize = overlaySize
        self.glassIsInteractive = glassIsInteractive
        self.sizeScales = sizeScales
        self.onHover = onHover
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let collapsedRecoveryOpacity = 1 - min(max(progress, 0), 1)
        let geometry = TatwoIslandShellMetrics.geometry(progress: progress, within: overlaySize)
        let shellShape = TatwoIslandShellShape(
            topReverseCornerRadius: geometry.topReverseCornerRadius,
            bottomCornerRadius: geometry.bottomCornerRadius
        )

        ZStack {
            // 黑 notch 是玻璃後方的內容，不是最後蓋在玻璃上的實色貼片。
            // 先畫黑塊，讓下方唯一的系統玻璃直接對它做模糊與折射。
            TatwoIslandNotchBlackPaint(
                progress: progress,
                shellSize: geometry.shellSize
            )
                .clipShape(shellShape)
                .allowsHitTesting(false)
            // 底板只有一個。不裁切：系統玻璃的外投影本來就落在造型之外，
            // 一裁就會被切成一條沿底邊的白帶。
            TatwoIslandBaseplate(
                shellShape: shellShape,
                cornerRadius: geometry.bottomCornerRadius,
                glassIsInteractive: glassIsInteractive
            )
            .opacity(TatwoIslandSettings.glassOpacityValue)   // 自定義滑軌：玻璃透明度（1＝原版）
            // 系統玻璃的 hover 能量有自己的退場時間。收合時用同一個黑 notch
            // 在玻璃上方同步補回實黑，讓「恢復正常」跟 0.22 秒幾何動畫一起完成；
            // 展開穩態 opacity 為 0，直接不掛進渲染樹，省一層 compositing。
            if collapsedRecoveryOpacity > 0 {
                TatwoIslandNotchBlackPaint(
                    progress: progress,
                    shellSize: geometry.shellSize
                )
                    .clipShape(shellShape)
                    .opacity(collapsedRecoveryOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TatwoIslandHoverTrackingView(
                topReverseCornerRadius: geometry.topReverseCornerRadius,
                bottomCornerRadius: geometry.bottomCornerRadius,
                onHover: onHover
            )
        }
        .frame(width: geometry.shellSize.width, height: geometry.shellSize.height)
    }
}

struct TatwoIslandShellShape: Shape {
    var topReverseCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let topRadius = min(topReverseCornerRadius, rect.width / 2, rect.height)
        let bodyRect = CGRect(
            x: rect.minX + topRadius,
            y: rect.minY,
            width: max(0, rect.width - (topRadius * 2)),
            height: rect.height
        )
        let bottomRadius = min(bottomCornerRadius, bodyRect.width / 2, bodyRect.height)
        let circleControlPointRatio: CGFloat = 0.552_284_75
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: bodyRect.maxX, y: rect.minY + topRadius),
            control1: CGPoint(
                x: rect.maxX - (topRadius * circleControlPointRatio),
                y: rect.minY
            ),
            control2: CGPoint(
                x: bodyRect.maxX,
                y: rect.minY + topRadius - (topRadius * circleControlPointRatio)
            )
        )
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - bottomRadius))
        addContinuousCorner(
            to: &path,
            center: CGPoint(x: bodyRect.maxX - bottomRadius, y: bodyRect.maxY - bottomRadius),
            from: 0,
            to: .pi / 2,
            radius: bottomRadius
        )
        path.addLine(to: CGPoint(x: bodyRect.minX + bottomRadius, y: bodyRect.maxY))
        addContinuousCorner(
            to: &path,
            center: CGPoint(x: bodyRect.minX + bottomRadius, y: bodyRect.maxY - bottomRadius),
            from: .pi / 2,
            to: .pi,
            radius: bottomRadius
        )
        path.addLine(to: CGPoint(x: bodyRect.minX, y: rect.minY + topRadius))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(
                x: bodyRect.minX,
                y: rect.minY + topRadius - (topRadius * circleControlPointRatio)
            ),
            control2: CGPoint(
                x: rect.minX + (topRadius * circleControlPointRatio),
                y: rect.minY
            )
        )
        path.closeSubpath()

        return path
    }

    private func addContinuousCorner(
        to path: inout Path,
        center: CGPoint,
        from startAngle: CGFloat,
        to endAngle: CGFloat,
        radius: CGFloat
    ) {
        guard radius > 0 else { return }
        let segmentCount = 24
        for index in 1...segmentCount {
            let progress = CGFloat(index) / CGFloat(segmentCount)
            let angle = startAngle + ((endAngle - startAngle) * progress)
            let x = superellipseComponent(cos(angle))
            let y = superellipseComponent(sin(angle))
            path.addLine(to: CGPoint(x: center.x + (x * radius), y: center.y + (y * radius)))
        }
    }

    private func superellipseComponent(_ value: CGFloat) -> CGFloat {
        let magnitude = sqrt(abs(value))
        return value < 0 ? -magnitude : magnitude
    }
}

struct TatwoIslandHoverTrackingView: NSViewRepresentable {
    let topReverseCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.topReverseCornerRadius = topReverseCornerRadius
        view.bottomCornerRadius = bottomCornerRadius
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.topReverseCornerRadius = topReverseCornerRadius
        nsView.bottomCornerRadius = bottomCornerRadius
        nsView.onHover = onHover
        nsView.updateHoverStateFromCurrentPointerLocation()
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        var topReverseCornerRadius: CGFloat = 0
        var bottomCornerRadius: CGFloat = 0
        private var trackingAreaReference: NSTrackingArea?
        private var isHovering = false

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaReference {
                removeTrackingArea(trackingAreaReference)
            }
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            trackingAreaReference = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            updateHoverState(for: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHoverState(for: event)
        }

        override func mouseExited(with event: NSEvent) {
            setHovering(false)
        }

        func updateHoverStateFromCurrentPointerLocation() {
            guard let window else { return }
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setHovering(containsShell(pointer))
        }

        private func updateHoverState(for event: NSEvent) {
            setHovering(containsShell(convert(event.locationInWindow, from: nil)))
        }

        private func containsShell(_ point: NSPoint) -> Bool {
            TatwoIslandShellShape(
                topReverseCornerRadius: topReverseCornerRadius,
                bottomCornerRadius: bottomCornerRadius
            )
                .path(in: bounds)
                .contains(point)
        }

        private func setHovering(_ hovering: Bool) {
            guard isHovering != hovering else { return }
            isHovering = hovering
            onHover?(hovering)
        }
    }
}

// MARK: - macOS 26+ 系統原生 Liquid Glass 主路徑

/// 本機是 macOS 27，所以底板只有「一個」系統玻璃表面，造型直接餵
/// TatwoIslandShellShape。折射、邊緣高光、內外陰影、隨桌布與外觀的明暗自適應
/// 全部由系統負責——手工仿製鏈永遠追不上，而且每多一層就多一塊假底板。
/// 舊系統手工玻璃鏈已於 2026-08-19 減碼移除（使用者全部設備都在 macOS 26+，
/// 該路徑永遠不會執行）；低於 macOS 26 僅顯示黑 notch、無玻璃。
private struct TatwoIslandBaseplate: View {
    let shellShape: TatwoIslandShellShape
    let cornerRadius: CGFloat
    let glassIsInteractive: Bool

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            // 保留透明 carrier，避免極低白色填色仍被系統材質放大成偏白底板。
            // 收合目標一成立就關掉 interactive hover 能量；材質本身仍保留，
            // 黑 notch 也仍在玻璃下方，只是不再等待系統高光慢慢退場。
            Color.clear
                .glassEffect(.regular.interactive(glassIsInteractive), in: shellShape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 頂部黑 notch

/// Collapsed = solid black over the current shell. Expanded = 240×33 square
/// (collapsed capsule slot, square corners) with an inward fade into glass.
/// Size, fade, and glass reveal are all driven by `progress`.
private struct TatwoIslandNotchBlackPaint: View {
    var progress: CGFloat
    var shellSize: NSSize

    var body: some View {
        let progress = min(max(progress, 0), 1)
        // 目標＝收合時的島本體（含左右外翻耳）：頂部外 R 角＋底部圓角原樣。
        let notchWidth = TatwoIslandShellMetrics.collapsedSize.width
            + (TatwoIslandShellMetrics.collapsedTopReverseCornerRadius * 2)
        let notchHeight = TatwoIslandShellMetrics.collapsedSize.height
        let coreWidth = max(0, shellSize.width
            + ((notchWidth - shellSize.width) * progress))
        let coreHeight = max(0, shellSize.height
            + ((notchHeight - shellSize.height) * progress))
        let notchShape = TatwoIslandShellShape(
            topReverseCornerRadius: TatwoIslandShellMetrics.collapsedTopReverseCornerRadius,
            bottomCornerRadius: TatwoIslandShellMetrics.collapsedBottomCornerRadius
        )

        notchShape
            .fill(.black)
            .frame(width: coreWidth, height: coreHeight)
            .blur(radius: 4.5 * progress)
            .compositingGroup()
            // 羽化只准往內。沒有這道遮罩，4.5pt 模糊會溢出造型之外，在島下方
            // 糊成灰色光暈／第二塊板——那正是實機截圖看到的東西。
            .mask {
                notchShape
                    .fill(.black)
                    .frame(width: coreWidth, height: coreHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
