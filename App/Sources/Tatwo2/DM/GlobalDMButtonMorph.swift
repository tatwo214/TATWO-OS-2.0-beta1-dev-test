import AppKit
import QuartzCore

// W184 F45（使用者 09-29 晚看了 v2.0.21.030：「右下小視窗的時候圓鈕展開成視窗 再縮回圓鈕 不要同時存在」）：
// 主視窗縮成桌面圓鈕時，私訊框開著就不顯示桌面圓鈕；打開＝圓鈕長成框、收起＝框縮回圓鈕。
// - 長、縮的是一個空的外殼：框的底色（紙紋）、邊框、陰影，沒有框的內容——不拍任何畫面（配對碼、授權頁不可能進圖）。
//   外殼是一個獨立的透明面板（不拿焦點；只有畫出來的外殼接點擊，見下面「點擊」），圖層在畫面伺服器上跑：框的右緣、下緣、寬、高各走一條彈簧
//   （跟換形態同一條：GlobalDMSpring，質量 1、ω＝2π／0.42、阻尼比 1、不回彈；CASpringAnimation），主執行緒只排一個計時器。
//   t＝0 在外殼（面板、紙紋）建好之後才取（W184 F45 查核 #2）：建窗花的時間不算進動畫，第一格就是起點。
// - 圓角＝min(52, 短邊的一半)：圓鈕（44）時是半徑 22 的圓，長到短邊 104 以上就是框的 52（W184 F3：框的圓角能 52 就一直 52）。
// - 打開：圓鈕馬上藏起來（同一次畫面更新換成外殼的圓），外殼從圓鈕的位置與圓形長到框；真的框一開始就在最後的位置、有鍵盤焦點，
//   內容透明，外殼快到位（0.36 秒起）內容淡入 0.16 秒；0.6 秒外殼到位（離終點 ≤1pt）拆掉。
// - 收起（W184 AB 補 F45 查核 #3，主導選 (a)）：store 說收起的那一刻，框的內容先淡出 0.10 秒——這段時間 GlobalDMFloatingRoot
//   照樣留著框的內容（keepsContent），外殼（同色、同邊、同陰影）停在框的位置、墊在框下面，框畫布的透明度 1 → 0；淡完才請面板控制器
//   收掉真的框（hideFloating、orderOut），外殼接著縮回圓鈕；0.6 秒到位：圓鈕出現、外殼拆掉。淡出途中又打開（點圓鈕、⌥⌘）＝內容從當下的
//   透明度淡回來、外殼拆掉，框照舊開著。淡出這 0.1 秒框的內容照常在畫面上：配對碼、授權頁的截圖保護照原本的規則（碼在畫面上＝擋擷取）。
// - 轉向：長到一半收起＝從外殼當下的位置與速度縮回；縮到一半又打開＝從當下的位置與速度長回去（不排隊、不跳）。
// - 點擊（查核 #1）：長、縮途中圓鈕藏著；點畫出來的外殼、或圓鈕本來的位置（一塊看不見、跟圓鈕本體一樣大的點擊區）＝點圓鈕（開↔收）：
//   縮到一半點它＝長回去；長到一半點它（例如連點圓鈕的第二下）＝縮回去。這一下不會穿到後面的 App、把剛開的框的鍵盤焦點搶走。
//   外殼以外透明的地方照樣穿過去（外殼面板不設 ignoresMouseEvents：視窗伺服器照像素透明度決定）。
// - 系統「減少動態效果」、圓鈕與框在不同螢幕：不長不縮，淡入淡出（打開：圓鈕藏起、框 0.15 秒淡入；收起：框本身（內容連同框）0.12 秒
//   淡出、收掉，圓鈕 0.15 秒淡入）。
// - 位置一律在動畫開始那一刻讀圓鈕面板與框面板的實際 frame（不另存：房 AB 的 G1b 讓框與圓鈕分開拖、分開記，合併後照樣從它們在的地方長、縮）。
// - W184 AB（使用者 09-30 .031：「停靠時主視窗裡的私訊鈕跟框同時存在」）：主視窗裡的停靠框用同一套（面板控制器另一個實例）：
//   圓鈕＝主視窗右下那顆（主視窗的子視窗）、框＝停靠框；外殼跟主視窗同一層（.normal）、擺在主視窗那一疊的最上面（不蓋到別的 App），
//   圓鈕藏起、放回照子視窗的方式（先拆再收、照舊掛回主視窗）。

/// 長或縮。
enum GlobalDMMorphDirection: Equatable, Sendable {
    case grow
    case shrink
}

/// 時間與形狀（純計算，好測）。
enum GlobalDMMorphTiming {
    /// 真的框的內容從這一段開始後幾秒開始淡入（外殼約走完 97%）。
    static let contentIn: Double = 0.36
    /// 內容淡入多久（施工單：約 0.12–0.22 秒）。
    static let contentFade: Double = 0.16
    /// W184 AB：收起時框的內容先淡出多久（外殼墊在框下面；淡完才收框、開始縮）。
    static let clearOut: Double = 0.10
    /// 一段走多久算到位（同換形態：0.6 秒、離終點 ≤1pt）。
    static var settle: Double { DMPhone.Slide.settle }
    /// 減少動態效果：淡出、淡入（同換形態）。
    static var reduceOut: Double { DMPhone.Slide.reduceOut }
    static var reduceIn: Double { DMPhone.Slide.reduceIn }
    /// 外殼面板比外殼的活動範圍多留的邊（陰影、邊框）。
    static let pad: CGFloat = 32

    /// 外殼的圓角：能 52 就 52，比 104 小的時候是短邊的一半（圓鈕 44＝半徑 22 的圓）。
    static func radius(for size: CGSize) -> CGFloat {
        min(DMPhone.screenRadius, max(0, min(size.width, size.height) / 2))
    }

    enum Style: Equatable, Sendable {
        /// 長成框、縮回圓鈕。
        case morph
        /// 淡入淡出（減少動態效果、圓鈕與框在不同螢幕）。
        case fade
    }

    /// 怎麼動：減少動態效果＝淡入淡出；圓鈕與框的中心不在同一個螢幕（或找不到螢幕）＝淡入淡出；其他＝長、縮。
    static func style(bubble: CGRect, box: CGRect, screens: [CGRect], reduceMotion: Bool) -> Style {
        guard !reduceMotion else { return .fade }
        func screen(_ rect: CGRect) -> Int? { screens.firstIndex { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) } }
        guard let first = screen(bubble), let second = screen(box), first == second else { return .fade }
        return .morph
    }
}

/// 外殼一格的速度（點／秒；轉向時接著走）。
struct GlobalDMMorphSpeed: Equatable, Sendable {
    var maxX = 0.0, minY = 0.0, width = 0.0, height = 0.0
    static let zero = GlobalDMMorphSpeed()
}

/// 一段（開始、或每一次轉向）：外殼的右緣、下緣、寬、高各走一條彈簧（同換形態的圖層台：圖層的錨點在右下，位置＝右緣、下緣）。
struct GlobalDMMorphSegment: Equatable, Sendable {
    let start: Double
    let direction: GlobalDMMorphDirection
    let target: CGRect
    let maxX: GlobalDMSpring, minY: GlobalDMSpring, width: GlobalDMSpring, height: GlobalDMSpring

    init(start: Double, direction: GlobalDMMorphDirection, from rect: CGRect, speed: GlobalDMMorphSpeed, to target: CGRect) {
        self.start = start
        self.direction = direction
        self.target = target
        maxX = GlobalDMSpring(origin: rect.maxX, velocity: speed.maxX, target: target.maxX)
        minY = GlobalDMSpring(origin: rect.minY, velocity: speed.minY, target: target.minY)
        width = GlobalDMSpring(origin: rect.width, velocity: speed.width, target: target.width)
        height = GlobalDMSpring(origin: rect.height, velocity: speed.height, target: target.height)
    }

    func rect(at tau: Double) -> CGRect {
        let w = max(1, width.value(at: tau)), h = max(1, height.value(at: tau))
        return CGRect(x: maxX.value(at: tau) - w, y: minY.value(at: tau), width: w, height: h)
    }

    func speed(at tau: Double) -> GlobalDMMorphSpeed {
        GlobalDMMorphSpeed(maxX: maxX.speed(at: tau), minY: minY.speed(at: tau), width: width.speed(at: tau),
                           height: height.speed(at: tau))
    }
}

/// 一整段（開始＋每一次轉向）：t＝從開始算的秒數；外殼的矩形、圓角、真的框內容的透明度都是 t 的純函式（自測在指定秒數取樣）。
struct GlobalDMMorphPlan: Equatable, Sendable {
    private(set) var segments: [GlobalDMMorphSegment]

    init(from rect: CGRect, to target: CGRect, direction: GlobalDMMorphDirection) {
        segments = [GlobalDMMorphSegment(start: 0, direction: direction, from: rect, speed: .zero, to: target)]
    }

    private var last: GlobalDMMorphSegment { segments[segments.count - 1] }
    var direction: GlobalDMMorphDirection { last.direction }
    var target: CGRect { last.target }
    /// 最後一段到位的時間。
    var end: Double { last.start + GlobalDMMorphTiming.settle }

    func segment(at t: Double) -> GlobalDMMorphSegment {
        segments.last { $0.start <= t } ?? segments[0]
    }

    func rect(at t: Double) -> CGRect {
        let segment = segment(at: t)
        return segment.rect(at: t - segment.start)
    }

    func speed(at t: Double) -> GlobalDMMorphSpeed {
        let segment = segment(at: t)
        return segment.speed(at: t - segment.start)
    }

    func radius(at t: Double) -> CGFloat { GlobalDMMorphTiming.radius(for: rect(at: t).size) }

    /// 真的框內容的透明度：最後一段是長的＝那一段開始後 0.36 秒起淡入 0.16 秒；縮的時候內容已經被拿掉＝0。
    func content(at t: Double) -> Double {
        guard last.direction == .grow else { return 0 }
        let from = last.start + GlobalDMMorphTiming.contentIn
        return GlobalDMEase.step(from, from + GlobalDMMorphTiming.contentFade, t)
    }

    /// 轉向：從 t 這一刻的位置與速度接著走，換成新目標（不排隊、不跳、不重設速度）。
    mutating func retarget(at t: Double, direction: GlobalDMMorphDirection, to target: CGRect) {
        let current = segment(at: t)
        let tau = t - current.start
        segments.append(GlobalDMMorphSegment(start: t, direction: direction, from: current.rect(at: tau),
                                             speed: current.speed(at: tau), to: target))
    }
}

// MARK: - 外殼（畫面）

/// 外殼的透明面板（圓鈕本來的位置那塊點擊區也用它）：不拿焦點（不會變成 key、不啟用 App），所有桌面與全螢幕 App 上都在（同浮動框）；
/// 位置、大小由控制器決定（不讓系統往選單列下面推）。
final class GlobalDMMorphShellPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// 外殼的畫面：layer-hosting（圖層樹自己管），沒有任何子 view、不畫任何東西，只放外殼的圖層。
/// W184 F45 查核 #1：點到畫出來的外殼（presentation 的圓角矩形）＝點圓鈕；外殼以外不接（面板沒設 ignoresMouseEvents：
/// 那些透明的地方視窗伺服器照像素透明度讓點擊穿到後面；明確設 false 反而整塊都會接）。
final class GlobalDMMorphShellView: NSView {
    /// 圖層的座標原點＝螢幕上一個固定點（面板變大時原點不動）。
    let root = CALayer()
    /// 畫出來的外殼現在在哪（螢幕座標的圓角矩形；GlobalDMMorphShell 接上）。
    var shape: (@MainActor () -> CGPath?)?
    /// 按到外殼（GlobalDMButtonMorph 接上：同點圓鈕）。
    var onPress: (@MainActor () -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let backing = CALayer()
        backing.masksToBounds = false
        layer = backing
        wantsLayer = true
        root.anchorPoint = .zero
        root.masksToBounds = false
        backing.addSublayer(root)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    /// 只有畫出來的外殼接（point 在 superview 的座標；換成螢幕座標比外殼現在的圓角矩形）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, let path = shape?() else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return path.contains(window.convertPoint(toScreen: convert(local, to: nil))) ? self : nil
    }

    /// 面板不會變成 key：第一下就要送到這裡。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 按下就算（外殼在動：放開時它可能已經走開、或到位拆掉了）。
    override func mouseDown(with event: NSEvent) { withExtendedLifetime(window) { () -> Void in onPress?() } }
}

/// W184 F45 查核 #1：圓鈕本來的位置（長、縮途中圓鈕藏著）：跟圓鈕本體一樣大、什麼都不畫的點擊區，只有圓形接（同圓鈕的 hitTest），
/// 按下＝點圓鈕。連點圓鈕的第二下（外殼 0.1 秒就長離這裡了）、縮回途中點圓鈕要回去的地方，都不會穿到後面的 App。
final class GlobalDMMorphCatcherView: NSView {
    var onPress: (@MainActor () -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return NSBezierPath(ovalIn: bounds).contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { withExtendedLifetime(window) { () -> Void in onPress?() } }
}

/// 一段長、縮在畫面上的外殼：陰影一層、底色（紙紋）＋邊框一層。只有位置、大小、圓角、透明度的動畫；停下就拆掉。
@MainActor
final class GlobalDMMorphShell {
    let panel: GlobalDMMorphShellPanel
    let view: GlobalDMMorphShellView
    let surface: GlobalDMFormStage.Surface
    /// 圖層座標的原點在螢幕上的位置。
    let base: CGPoint
    /// 這一整段的 t＝0 在圖層上的時間（圖層的本地時間；begin(at:) 設）。
    private(set) var origin: CFTimeInterval = 0
    let manual: Bool
    /// 外殼（面板、紙紋、圖層）建好的時間（CACurrentMediaTime；自測看：t＝0 要在這之後取，查核 #2）。
    let builtAt: CFTimeInterval
    private let shadow = CALayer(), clip = CALayer()

    var root: CALayer { view.root }

    /// frame＝外殼面板（螢幕座標）；manual＝自測推時鐘。建好之後由 begin(at:) 定這一整段的 t＝0。
    /// 面板不設 ignoresMouseEvents（查核 #1）：畫出來的外殼接點擊（hitTest 只認圓角矩形），其他透明的地方點擊照樣穿過去。
    init(frame: CGRect, surface: GlobalDMFormStage.Surface, manual: Bool) {
        panel = GlobalDMMorphShellPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.canHide = false
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "私訊鈕外殼"
        panel.setAccessibilityIdentifier("tatwo.dm.desk.morph")
        view = GlobalDMMorphShellView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        self.surface = surface
        self.base = frame.origin
        self.manual = manual
        let root = view.root
        root.bounds = CGRect(origin: .zero, size: frame.size)
        root.position = .zero
        for layer in [shadow, clip] {
            layer.anchorPoint = CGPoint(x: 1, y: 0)
            layer.cornerCurve = .continuous
            root.addSublayer(layer)
        }
        shadow.backgroundColor = surface.fill
        shadow.shadowColor = NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.22, alpha: 1).cgColor   // 同換形態的圖層台
        shadow.shadowOpacity = 0.12
        shadow.shadowRadius = 9
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        clip.masksToBounds = true
        clip.backgroundColor = surface.fill
        clip.borderWidth = 1
        clip.borderColor = surface.border
        if let paper = surface.paper {
            clip.contents = paper
            clip.contentsGravity = .bottomRight
            clip.contentsScale = 1
        }
        builtAt = CACurrentMediaTime()
        view.shape = { [weak self] in self?.presentedPath }
    }

    /// 這一整段的 t＝0（外殼建好之後才取，查核 #2：建窗、畫紙紋花的時間不算進動畫）→ 圖層的本地時間原點；自測推時鐘＝停住。
    func begin(at start: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        origin = manual ? 1_000 : root.convertTime(start, from: nil)
        if manual {
            root.speed = 0
            root.timeOffset = origin
        }
        CATransaction.commit()
    }

    /// 面板至少要蓋住 rect（外殼會走到的地方＋陰影邊）：不夠就變大，圖層座標原點在螢幕上不動。
    func cover(_ rect: CGRect) {
        let needed = panel.frame.union(rect.insetBy(dx: -GlobalDMMorphTiming.pad, dy: -GlobalDMMorphTiming.pad))
        guard needed != panel.frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(needed, display: false)
        view.frame = NSRect(origin: .zero, size: needed.size)
        root.bounds = CGRect(origin: .zero, size: needed.size)
        root.position = CGPoint(x: base.x - needed.minX, y: base.y - needed.minY)
        CATransaction.commit()
    }

    /// 停在 rect（淡出用：不長不縮）。
    func place(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [shadow, clip] {
            for key in ["w", "h", "x", "y", "r"] { layer.removeAnimation(forKey: key) }
            layer.bounds = CGRect(origin: .zero, size: rect.size)
            layer.position = CGPoint(x: rect.maxX - base.x, y: rect.minY - base.y)
            layer.cornerRadius = GlobalDMMorphTiming.radius(for: rect.size)
        }
        CATransaction.commit()
    }

    /// 一段（開始或轉向）：四個數＝彈簧（從模型那一刻的位置與速度接著走），圓角＝照模型逐格算好的關鍵影格。
    func run(_ segment: GlobalDMMorphSegment, at start: Double) {
        let begin = origin + start
        let bx = Double(base.x), by = Double(base.y)
        let target = segment.target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [shadow, clip] {
            layer.bounds = CGRect(origin: .zero, size: target.size)
            layer.position = CGPoint(x: target.maxX - base.x, y: target.minY - base.y)
            layer.cornerRadius = GlobalDMMorphTiming.radius(for: target.size)
            replace(layer, "w", GlobalDMFormStage.spring("bounds.size.width", segment.width, begin: begin))
            replace(layer, "h", GlobalDMFormStage.spring("bounds.size.height", segment.height, begin: begin))
            replace(layer, "x", GlobalDMFormStage.spring("position.x", segment.maxX, shift: -bx, begin: begin))
            replace(layer, "y", GlobalDMFormStage.spring("position.y", segment.minY, shift: -by, begin: begin))
            replace(layer, "r", GlobalDMFormStage.sampled("cornerRadius", length: GlobalDMMorphTiming.settle, begin: begin) { tau in
                Double(GlobalDMMorphTiming.radius(for: segment.rect(at: tau).size))
            })
        }
        CATransaction.commit()
    }

    /// 整個外殼淡掉（減少動態效果的收起）：從 start 起 length 秒。
    func fadeOut(at start: Double, length: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = 0
        root.removeAnimation(forKey: "o")
        root.add(GlobalDMFormStage.sampled("opacity", length: length, begin: origin + start) { 1 - GlobalDMEase.step(0, length, $0) },
                 forKey: "o")
        CATransaction.commit()
    }

    private func replace(_ layer: CALayer, _ key: String, _ animation: CAAnimation?) {
        layer.removeAnimation(forKey: key)
        if let animation { layer.add(animation, forKey: key) }
    }

    /// 自測推時鐘：整個外殼停在 elapsed 秒。
    func show(at elapsed: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.speed = 0
        root.timeOffset = origin + elapsed
        CATransaction.commit()
        CATransaction.flush()
    }

    /// 外殼現在在畫面上的樣子（螢幕座標；presentation）。
    var presentedRect: CGRect {
        let layer = clip.presentation() ?? clip
        return CGRect(x: layer.position.x - layer.bounds.width + base.x, y: layer.position.y + base.y,
                      width: layer.bounds.width, height: layer.bounds.height)
    }

    var presentedRadius: CGFloat { (clip.presentation() ?? clip).cornerRadius }
    var presentedOpacity: Float { (root.presentation() ?? root).opacity }

    /// 畫出來的外殼（螢幕座標的圓角矩形；presentation）：點擊只認這裡面（查核 #1）。
    var presentedPath: CGPath {
        let rect = presentedRect
        let radius = max(0, min(presentedRadius, min(rect.width, rect.height) / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// 外殼所有的圖層（自測看：圖層裡只有底色、紙紋、邊框、陰影，沒有任何拍下來的畫面）。
    var allLayers: [CALayer] {
        var result: [CALayer] = []
        var stack: [CALayer] = view.layer.map { [$0] } ?? [root]
        while let layer = stack.popLast() {
            result.append(layer)
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        return result
    }

    /// 自測：照現在的 presentation 畫進 rep（region＝螢幕座標、底下已經鋪好的內容照留）；先把每一層的樣子抄進 model、畫完還原。
    func render(into rep: NSBitmapImageRep, region: CGRect) {
        guard region.width > 0, region.height > 0, let context = NSGraphicsContext(bitmapImageRep: rep),
              let backing = view.layer else { return }
        // NSGraphicsContext(bitmapImageRep:) 已經照 rep.size（點）對到像素：這裡只補 region → rep.size 的比例（rep.size＝region.size 時是 1）。
        let scale = rep.size.width / region.width
        let cg = context.cgContext
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: panel.frame.minX - region.minX, y: panel.frame.minY - region.minY)
        var saved: [(CALayer, CGRect, CGPoint, Float, CGFloat)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [root, shadow, clip] {
            let shown = layer.presentation() ?? layer
            saved.append((layer, layer.bounds, layer.position, layer.opacity, layer.cornerRadius))
            layer.bounds = shown.bounds
            layer.position = shown.position
            layer.opacity = shown.opacity
            layer.cornerRadius = shown.cornerRadius
        }
        backing.render(in: cg)
        for (layer, bounds, position, opacity, radius) in saved {
            layer.bounds = bounds
            layer.position = position
            layer.opacity = opacity
            layer.cornerRadius = radius
        }
        CATransaction.commit()
        cg.restoreGState()
        context.flushGraphics()
    }

    func remove() {
        panel.orderOut(nil)
        panel.close()
    }
}

// MARK: - 控制

/// 桌面圓鈕 ↔ 浮動框（面板控制器一個）：浮動框整理（showFloating／hideFloating）與桌面控制器（store 說收起的那一刻）叫這裡。
/// 沒接桌面圓鈕（bubble 是 nil：不是縮成圓鈕的狀態、或自測只接了 floatingAnchor）＝什麼都不做，框照舊直接開關。
@MainActor
final class GlobalDMButtonMorph: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case growing
        case shrinking
        /// 減少動態效果、不同螢幕：打開（圓鈕藏起、框淡入）。
        case fadingIn
        /// 減少動態效果、不同螢幕：收起（框淡掉之後圓鈕淡入）；長到一半收起的淡出（空外殼淡出、圓鈕淡入）。
        case fadingOut
        /// W184 AB：收起的第一段——框的內容淡出（外殼墊在框下面；減少動態效果＝框本身淡掉），淡完才收框。
        case clearing
    }

    @Published private(set) var phase: Phase = .idle
    /// 桌面圓鈕（桌面控制器接上）：縮成圓鈕時回傳圓鈕的面板（藏著也回傳：位置照它）；不是圓鈕模式＝nil。
    var bubble: (@MainActor () -> NSWindow?)?
    /// 圓鈕現在該不該出現（框收著、還是圓鈕模式）：縮回到位時照它決定要不要放回圓鈕。
    var bubbleWanted: (@MainActor () -> Bool)?
    /// 浮動框的面板（面板控制器整理時交給這裡）。
    weak var box: NSWindow?
    /// 系統「減少動態效果」（自測換）。
    var reduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// 時鐘（自測換）；manualTime＝自測推時鐘（不排計時器；自測叫 tick()、show(at:)）。
    var clock: @MainActor () -> CFTimeInterval = { CACurrentMediaTime() }
    var manualTime = false
    /// 查核 #1：長、縮途中按到外殼或圓鈕本來的位置＝點圓鈕（桌面控制器接上：開↔收，走 closing()／presented() 的轉向）。
    var onClick: (@MainActor () -> Void)?
    /// W184 AB（停靠框）：外殼、點擊區要擺到最前面時，擺在誰的正上方（停靠＝停靠框或主視窗：跟著主視窗那一疊，不蓋到別的 App 的視窗）；
    /// nil＝這一層的最前面（浮動框）。外殼面板的層級（停靠＝跟主視窗一樣 .normal）。
    var anchor: (@MainActor () -> NSWindow?)?
    var shellLevel: NSWindow.Level = .floating
    /// W184 AB（停靠框）：圓鈕怎麼藏、怎麼放回來（停靠的圓鈕是主視窗的子視窗：藏＝先拆再收、放回＝照舊掛回主視窗）；nil＝orderOut／orderFrontRegardless。
    var hideBubble: (@MainActor (NSWindow) -> Void)?
    var showBubble: (@MainActor (NSWindow) -> Void)?
    /// W184 AB（GPT-6 第三輪 #4）：外殼、點擊區要不要跨所有桌面（浮動框＝要：它本來就在每個桌面；停靠＝不要：只在主視窗那個桌面，
    /// 切到別的桌面由面板控制器直接到位、拆掉）。
    var joinsAllSpaces = true
    /// W184 AB（GPT-6 第三輪 #1）：收起的內容淡出途中被叫直接到位的那個框：面板控制器接著收它的時候不要再縮一次（dismiss 跳過一次）。
    private weak var putAway: NSWindow?

    /// 這一整段的外殼（長、縮）；淡入淡出沒有。
    private(set) var plan: GlobalDMMorphPlan?
    private(set) var shell: GlobalDMMorphShell?
    private(set) var startedAt: CFTimeInterval = 0
    /// 淡入淡出這一段多長；收起的淡入淡出：圓鈕放回來了沒。
    private var fadeLength: Double = 0
    private var bubbleBack = false
    /// W184 AB：收起的內容淡出——多長、淡完之後長縮還是淡入淡出、框在哪；淡掉的那一個框內容（收掉之後才還回透明度 1）。
    private var clearLength: Double = 0
    private var clearStyle: GlobalDMMorphTiming.Style = .morph
    private var clearRect: CGRect = .zero
    private weak var cleared: NSView?
    private var clearOrigin: CFTimeInterval = 0
    /// 內容淡完：請面板控制器現在收掉真的框（面板控制器接上：整理一次）。
    var onCleared: (@MainActor () -> Void)?
    /// 這一次整理要出現的框（prepare 記、presented 用）。
    private weak var appearing: NSWindow?
    /// 掛著我們動畫的框內容、圓鈕內容（停下拿掉）；自測推時鐘時它們的本地時間原點。
    private weak var content: NSView?
    private weak var bubbleContent: NSView?
    private var contentOrigin: CFTimeInterval = 0
    private var bubbleOrigin: CFTimeInterval = 0
    private var timer: Timer?
    /// 查核 #1：圓鈕本來的位置那塊看不見的點擊區（長、縮、淡入淡出途中才在畫面上；重複用同一個）。
    private var catcher: GlobalDMMorphShellPanel?
    /// 自測看：那塊點擊區。
    var catcherPanel: NSWindow? { catcher }

    /// 外殼、點擊區的桌面行為：浮動＝每個桌面都在；停靠（W184 AB 第三輪 #4）＝只在出現時那個桌面（全螢幕的主視窗那一個也可以）。
    static let allSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    static let localSpaces: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

    static let holdKey = "tatwo.dm.morph.hold"
    static let clearKey = "tatwo.dm.morph.clear"
    static let contentKey = "tatwo.dm.morph.content"
    static let bubbleKey = "tatwo.dm.morph.bubble"

    init() {}

    var isAnimating: Bool { phase != .idle }
    /// 這一段開始到現在幾秒。
    var elapsed: Double { phase == .idle ? 0 : clock() - startedAt }
    /// 這一段什麼時候停。
    var end: Double { plan?.end ?? fadeLength }
    /// W184 AB：收起的內容淡出中——GlobalDMFloatingRoot 照樣留著框的內容（store 已經說收起）。
    var keepsContent: Bool { phase == .clearing }
    /// W184 AB（停靠框）：圓鈕現在由這裡藏著、之後由這裡放回來（長、淡入、收起的淡出與縮、收起的淡入淡出圓鈕還沒回來）——
    /// 面板控制器這段時間不自己擺出圓鈕。
    var holdsBubble: Bool {
        switch phase {
        case .idle: false
        case .fadingOut: !bubbleBack
        case .growing, .shrinking, .fadingIn, .clearing: true
        }
    }
    /// 這個框正在收起的內容淡出中（面板控制器的 hideFloating 先不收它，淡完這裡會叫 onCleared）。
    func isClearing(_ panel: NSWindow) -> Bool { phase == .clearing && box === panel }

    // MARK: 浮動框整理叫的

    /// 浮動框要出現之前（showFloating，orderFront 之前）：圓鈕模式就先把框的內容藏著（第一格就是透明的，不會先整個框閃一下）。
    /// 縮回途中又打開、框還沒收掉（同一輪就又打開）：一樣當作要出現（從外殼當下長回去）。
    func prepare(_ panel: NSWindow) {
        if putAway === panel { putAway = nil }
        // W184 AB：收起的內容淡出途中又打開（點圓鈕、⌥⌘）＝內容淡回來、框照舊開著（沒有長、沒有縮）。
        if phase == .clearing, box === panel, panel.isVisible { return unclear(panel) }
        // 淡出之後的框（收掉時才還原透明度）又要出現：先還原（萬一沒收掉就又打開）。
        if let view = cleared, view === panel.contentView {
            cleared = nil
            release(view)
        }
        let reopening = panel.isVisible && phase == .shrinking && box === panel
        box = panel
        guard !panel.isVisible || reopening, bubble?() != nil, let view = panel.contentView else { return }
        appearing = panel
        view.wantsLayer = true
        // 透明度先歸零（還沒有圖層也有效）；presented 在同一輪換成真的淡入（模型回到 1、畫面照動畫）。
        view.alphaValue = 0
        if let layer = view.layer {
            // 再蓋一段 3 秒的透明：萬一沒人接手也會自己結束（release 一定把透明度還回 1）。
            let hold = CABasicAnimation(keyPath: "opacity")
            hold.fromValue = 0
            hold.toValue = 0
            hold.duration = 3
            hold.fillMode = .both
            layer.add(hold, forKey: Self.holdKey)
        }
        CATransaction.flush()
    }

    /// 浮動框出現之後（showFloating，orderFront、拿焦點之後）：這一次是 prepare 記下的＝圓鈕長成框（或淡入）。
    func presented(_ panel: NSWindow) {
        guard appearing === panel else { return }
        appearing = nil
        guard let bubbleWindow = bubble?() else { return release(panel.contentView) }
        let margin = GlobalDMLayout.margin
        let target = panel.frame.insetBy(dx: margin, dy: margin)
        let circle = bubbleWindow.frame.insetBy(dx: margin, dy: margin)
        let screens = NSScreen.screens.map(\.frame)
        switch GlobalDMMorphTiming.style(bubble: circle, box: target, screens: screens, reduceMotion: reduceMotion()) {
        case .fade: fadeIn(panel, bubble: bubbleWindow)
        case .morph: grow(panel, bubble: bubbleWindow, from: circle, to: target)
        }
    }

    /// store 說收起的那一刻（桌面控制器接 store.$isFloatingOpen，不等 receive(on:)）：外殼在同一次畫面更新接手。
    /// 這裡只動外殼自己的面板與圖層，不碰框的畫面（不排版、不重畫：SwiftUI 照常在這一輪把內容拿掉）。
    func closing() {
        guard let panel = box, panel.isVisible, phase != .shrinking, phase != .fadingOut, phase != .clearing,
              let bubbleWindow = bubble?() else { return }
        // 長、淡入到一半收起、換形態途中收起（F3 的圖層台在跑）：照舊直接縮（內容還沒完全出來／畫布在動）。
        if phase == .growing || phase == .fadingIn || (panel.contentView as? GlobalDMPanelCanvas)?.stage != nil {
            return shrink(panel, bubble: bubbleWindow)
        }
        clear(panel, bubble: bubbleWindow)
    }

    /// 浮動框收起（hideFloating，orderOut 之前）：收的那一刻沒接到的在這裡接；框內容上的淡入拿掉。
    func dismiss(_ panel: NSWindow) {
        if appearing === panel { appearing = nil }
        if putAway === panel {
            putAway = nil   // 淡出途中已經直接到位：這一次收框不再縮
        } else if panel === box, panel.isVisible, phase != .shrinking, phase != .fadingOut, phase != .clearing, let bubbleWindow = bubble?() {
            shrink(panel, bubble: bubbleWindow)
        }
        // 淡出過的內容等框收掉（hidden）才還原透明度：這裡還原會在 orderOut 之前整個閃回來。
        if panel.contentView !== cleared { release(panel.contentView) }
    }

    /// W184 AB：面板控制器收掉真的框之後（orderOut 之後）：淡出過的內容透明度還回 1（框已經不在畫面上，下次打開照常）。
    func hidden(_ panel: NSWindow) {
        if putAway === panel { putAway = nil }
        guard let view = cleared, view === panel.contentView else { return }
        cleared = nil
        release(view)
    }

    /// 直接到終點（換形態、換螢幕前）：外殼拆掉、框內容照常、縮回的那一段圓鈕放回來。
    /// W184 AB（GPT-6 第三輪 #1）：收起的內容淡出途中直接到位＝這一次收框算完成：圓鈕放回來、請面板控制器現在收掉真的框
    ///（notify；面板控制器自己的整理裡叫的＝false，接著那一輪就會收），收的時候不再縮；淡出過的內容等框收掉（hidden）才還原透明度。
    func finish(notify: Bool = true) {
        let closing = phase == .clearing ? box : nil
        settle(showBubble: true)
        guard let closing else { return }
        putAway = closing
        if notify { onCleared?() }
    }

    /// 取消（恢復主視窗、App 結束）：外殼拆掉、框內容照常，圓鈕不放回來（桌面控制器自己收）。
    func cancel() { settle(showBubble: false) }

    // MARK: 長、縮

    private func grow(_ panel: NSWindow, bubble bubbleWindow: NSWindow, from circle: CGRect, to target: CGRect) {
        if var plan, let shell, phase == .growing || phase == .shrinking {
            // 縮到一半又打開：從外殼這一刻的位置與速度長回去（沒有重的工作：用當下的時間）。
            let t = clock() - startedAt
            plan.retarget(at: t, direction: .grow, to: target)
            self.plan = plan
            shell.cover(target)
            if let segment = plan.segments.last { shell.run(segment, at: t) }
            shell.panel.order(.below, relativeTo: panel.windowNumber)
            fadeContentIn(panel, plan: plan, at: t)
            phase = .growing
            return schedule()
        }
        settle(showBubble: false)
        let plan = GlobalDMMorphPlan(from: circle, to: target, direction: .grow)
        guard let shell = makeShell(covering: circle.union(target), appearance: panel.effectiveAppearance) else {
            return fadeIn(panel, bubble: bubbleWindow)
        }
        // 查核 #2：t＝0 在外殼（面板、紙紋）建好之後才取：建窗花的時間不算進動畫，第一格就是圓鈕的位置與圓形。
        startedAt = clock()
        shell.begin(at: startedAt)
        self.plan = plan
        self.shell = shell
        if let segment = plan.segments.last { shell.run(segment, at: 0) }
        shell.panel.order(.below, relativeTo: panel.windowNumber)
        fadeContentIn(panel, plan: plan, at: 0)
        // 外殼的第一格先送出去，再把圓鈕藏起來（同一個位置換手，中間不會空一格）；圓鈕的位置換成看不見的點擊區（查核 #1）。
        CATransaction.flush()
        hide(bubbleWindow)
        showCatcher(at: circle, level: bubbleWindow.level)
        phase = .growing
        schedule()
    }

    /// 框現在在畫面上的矩形（螢幕座標、不含陰影邊）：換形態途中（F3 的圖層台在跑，面板是「舊框∪新框」的畫布）＝台上的框；平常＝面板扣掉陰影邊。
    static func visibleBox(of panel: NSWindow) -> CGRect {
        if let canvas = panel.contentView as? GlobalDMPanelCanvas, let stage = canvas.stage { return stage.presentedBox }
        let margin = GlobalDMLayout.margin
        return panel.frame.insetBy(dx: margin, dy: margin)
    }

    private func shrink(_ panel: NSWindow, bubble bubbleWindow: NSWindow) {
        let margin = GlobalDMLayout.margin
        let circle = bubbleWindow.frame.insetBy(dx: margin, dy: margin)
        if var plan, let shell, phase == .growing {
            // 長到一半收起：從外殼這一刻的位置與速度縮回去（沒有重的工作：用當下的時間）。
            let t = clock() - startedAt
            plan.retarget(at: t, direction: .shrink, to: circle)
            self.plan = plan
            shell.cover(circle)
            if let segment = plan.segments.last { shell.run(segment, at: t) }
            phase = .shrinking
            return schedule()
        }
        let boxRect = Self.visibleBox(of: panel)   // 換形態途中收起：從台上看得到的框開始縮（不是整塊畫布）
        settle(showBubble: false)
        let screens = NSScreen.screens.map(\.frame)
        guard GlobalDMMorphTiming.style(bubble: circle, box: boxRect, screens: screens, reduceMotion: reduceMotion()) == .morph,
              let shell = makeShell(covering: circle.union(boxRect), appearance: panel.effectiveAppearance) else {
            return fadeOut(panel, box: boxRect, bubble: bubbleWindow)
        }
        // 查核 #2：t＝0 在外殼建好之後才取：第一格就是框的位置。
        startedAt = clock()
        shell.begin(at: startedAt)
        let plan = GlobalDMMorphPlan(from: boxRect, to: circle, direction: .shrink)
        self.plan = plan
        self.shell = shell
        if let segment = plan.segments.last { shell.run(segment, at: 0) }
        // 這裡可能在 store 改值的途中（willSet）：不 flush、不碰框的畫面；外殼跟 SwiftUI 拿掉內容在同一次畫面更新送出去。
        front(shell.panel)
        showCatcher(at: circle, level: bubbleWindow.level)   // 查核 #1：縮回途中點圓鈕要回去的地方＝長回去
        phase = .shrinking
        schedule()
    }

    // MARK: 收起的內容淡出（W184 AB）

    /// 框的內容先淡出（0.10 秒；減少動態效果、不同螢幕＝框本身淡掉 reduceOut），外殼停在框的位置、墊在框下面（淡出時露出的是外殼的紙）；
    /// 淡完（finishClearing）才收框、縮回圓鈕。這裡可能在 store 改值的途中（willSet）：不 flush、不排版、不重畫框。
    private func clear(_ panel: NSWindow, bubble bubbleWindow: NSWindow) {
        settle(showBubble: false)
        let margin = GlobalDMLayout.margin
        let circle = bubbleWindow.frame.insetBy(dx: margin, dy: margin)
        let boxRect = Self.visibleBox(of: panel)
        let screens = NSScreen.screens.map(\.frame)
        clearStyle = GlobalDMMorphTiming.style(bubble: circle, box: boxRect, screens: screens, reduceMotion: reduceMotion())
        clearRect = boxRect
        let built = clearStyle == .morph ? makeShell(covering: circle.union(boxRect), appearance: panel.effectiveAppearance) : nil
        if built == nil { clearStyle = .fade }
        // t＝0 在外殼建好之後才取（同查核 #2）。
        startedAt = clock()
        clearLength = clearStyle == .morph ? GlobalDMMorphTiming.clearOut : GlobalDMMorphTiming.reduceOut
        if let shell = built {
            self.shell = shell
            shell.begin(at: startedAt)
            shell.place(boxRect)
            shell.panel.order(.below, relativeTo: panel.windowNumber)   // 墊在真的框下面
        }
        if let view = panel.contentView { fadeContentOut(view, length: clearLength) }
        showCatcher(at: circle, level: bubbleWindow.level)   // 淡出途中點圓鈕本來的位置＝打開回來（同查核 #1）
        phase = .clearing
        schedule()
    }

    /// 內容淡完：接下來那一段先開始（外殼從框的位置縮回圓鈕；減少動態效果＝圓鈕淡入），再請面板控制器收掉真的框（orderOut）。
    private func finishClearing() {
        guard box != nil, let bubbleWindow = bubble?() else { return settle(showBubble: true) }
        let margin = GlobalDMLayout.margin
        let circle = bubbleWindow.frame.insetBy(dx: margin, dy: margin)
        if clearStyle == .morph, let shell {
            startedAt = clock()
            shell.begin(at: startedAt)
            let plan = GlobalDMMorphPlan(from: clearRect, to: circle, direction: .shrink)
            self.plan = plan
            shell.cover(circle)
            if let segment = plan.segments.last { shell.run(segment, at: 0) }
            front(shell.panel)
            phase = .shrinking
        } else {
            // 框本身已經淡掉：接著圓鈕淡入（收起的淡入淡出的後半段；時間接在 reduceOut 之後）。
            shell?.remove()
            shell = nil
            plan = nil
            startedAt = clock() - GlobalDMMorphTiming.reduceOut
            fadeLength = GlobalDMMorphTiming.reduceOut + GlobalDMMorphTiming.reduceIn
            bubbleBack = false
            phase = .fadingOut
            bringBubbleBack(at: GlobalDMMorphTiming.reduceOut)
        }
        schedule()
        onCleared?()   // 面板控制器：現在才收掉真的框（hideFloating → orderOut → hidden）
        if manualTime { show(at: elapsed) }
    }

    /// 淡出途中又打開（點圓鈕、⌥⌘）：內容從當下的透明度淡回 1（用淡出已經走的時間），外殼、點擊區拆掉，框照舊開著、圓鈕照樣藏著。
    private func unclear(_ panel: NSWindow) {
        let t = min(max(0, elapsed), clearLength)
        let shown = 1 - GlobalDMEase.step(0, clearLength, t)
        shell?.remove()
        shell = nil
        hideCatcher()
        plan = nil
        let back = max(0.02, (1 - shown) * clearLength)
        fadeLength = t + back
        cleared = nil
        if let view = panel.contentView {
            view.layer?.removeAnimation(forKey: Self.clearKey)
            reveal(view, at: t, length: back) { shown + (1 - shown) * GlobalDMEase.step(0, back, $0) }
        }
        phase = .fadingIn
        schedule()
    }

    /// 框的內容 1 → 0（逐格算好的關鍵影格，掛在框面板的內容圖層上）；模型停在 0：淡完到收掉之前不會閃回來。
    private func fadeContentOut(_ view: NSView, length: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        cleared = view
        if manualTime {
            // 自測推時鐘：圖層停在這一段的 t＝0（不 flush：這裡可能在 store 改值的途中）。
            layer.speed = 0
            layer.timeOffset = 1_000
            clearOrigin = 1_000
        } else {
            clearOrigin = layer.convertTime(startedAt, from: nil)
        }
        for key in [Self.holdKey, Self.contentKey, Self.clearKey] { layer.removeAnimation(forKey: key) }
        layer.add(GlobalDMFormStage.sampled("opacity", length: length, begin: clearOrigin) { 1 - GlobalDMEase.step(0, length, $0) },
                  forKey: Self.clearKey)
        view.alphaValue = 0
    }

    // MARK: 淡入淡出（減少動態效果、不同螢幕）

    private func fadeIn(_ panel: NSWindow, bubble bubbleWindow: NSWindow) {
        settle(showBubble: false)
        startedAt = clock()
        fadeLength = GlobalDMMorphTiming.reduceIn
        if let view = panel.contentView {
            let length = GlobalDMMorphTiming.reduceIn
            reveal(view, at: 0, length: length) { GlobalDMEase.step(0, length, $0) }
        }
        CATransaction.flush()
        hide(bubbleWindow)
        showCatcher(at: bubbleWindow.frame.insetBy(dx: GlobalDMLayout.margin, dy: GlobalDMLayout.margin), level: bubbleWindow.level)
        phase = .fadingIn
        schedule()
    }

    private func fadeOut(_ panel: NSWindow, box boxRect: CGRect, bubble bubbleWindow: NSWindow) {
        bubbleBack = false
        plan = nil
        let built = makeShell(covering: boxRect, appearance: panel.effectiveAppearance)
        // 查核 #2：t＝0 在外殼建好之後才取。
        startedAt = clock()
        fadeLength = GlobalDMMorphTiming.reduceOut + GlobalDMMorphTiming.reduceIn
        if let shell = built {
            self.shell = shell
            shell.begin(at: startedAt)
            shell.place(boxRect)
            shell.fadeOut(at: 0, length: GlobalDMMorphTiming.reduceOut)
            front(shell.panel)
        }
        showCatcher(at: bubbleWindow.frame.insetBy(dx: GlobalDMLayout.margin, dy: GlobalDMLayout.margin), level: bubbleWindow.level)
        phase = .fadingOut
        schedule()
    }

    /// 收起的淡入淡出走到一半（空外殼淡完）：圓鈕淡入回來。
    private func bringBubbleBack(at t: Double) {
        bubbleBack = true
        guard let bubbleWindow = bubble?(), bubbleWanted?() ?? true, let view = bubbleWindow.contentView else { return }
        view.wantsLayer = true
        if let layer = view.layer {
            bubbleContent = view
            bubbleOrigin = timeOrigin(layer)
            let length = GlobalDMMorphTiming.reduceIn, start = t
            layer.removeAnimation(forKey: Self.bubbleKey)
            layer.add(GlobalDMFormStage.sampled("opacity", length: length, begin: bubbleOrigin + start) { GlobalDMEase.step(0, length, $0) },
                      forKey: Self.bubbleKey)
            if manualTime { freeze(layer, at: bubbleOrigin + t) }
            CATransaction.flush()
        }
        show(bubbleWindow)
    }

    // MARK: 框的內容

    /// 真的框的內容：照模型（這一段開始後 0.36 秒起淡入 0.16 秒）逐格算好的關鍵影格，掛在框面板的內容圖層上（圖層在畫面伺服器上跑）。
    private func fadeContentIn(_ panel: NSWindow, plan: GlobalDMMorphPlan, at start: Double) {
        guard let view = panel.contentView else { return }
        reveal(view, at: start, length: GlobalDMMorphTiming.contentIn + GlobalDMMorphTiming.contentFade) { plan.content(at: start + $0) }
    }

    /// 框內容的透明度模型回到 1、畫面照關鍵影格（f 的參數是這一段開始後的秒數）；沒有圖層（不該發生）＝直接看得到。
    private func reveal(_ view: NSView, at start: Double, length: Double, _ f: (Double) -> Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let layer = view.layer else {
            view.alphaValue = 1
            return
        }
        if content !== view {
            content = view
            contentOrigin = timeOrigin(layer)
        }
        layer.removeAnimation(forKey: Self.holdKey)
        layer.removeAnimation(forKey: Self.contentKey)
        layer.removeAnimation(forKey: Self.clearKey)
        layer.add(GlobalDMFormStage.sampled("opacity", length: length, begin: contentOrigin + start, f), forKey: Self.contentKey)
        view.alphaValue = 1
        if manualTime { freeze(layer, at: contentOrigin + start) }
    }

    /// 框內容上的動畫都拿掉、透明度還回 1（內容照常看得到）。
    private func release(_ view: NSView?) {
        guard let view else { return }
        if let layer = view.layer {
            layer.removeAnimation(forKey: Self.holdKey)
            layer.removeAnimation(forKey: Self.contentKey)
            layer.removeAnimation(forKey: Self.clearKey)
            if manualTime, view === content || layer.speed == 0 { thaw(layer) }
        }
        if view.alphaValue != 1 { view.alphaValue = 1 }
        if view === content { content = nil }
    }

    // MARK: 停下

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !manualTime, phase != .idle else { return }
        let next = phase == .clearing ? clearLength : phase == .fadingOut && !bubbleBack ? GlobalDMMorphTiming.reduceOut : end
        let interval = max(0, next - elapsed) + 0.002
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 看一下時間：收起的淡入淡出到一半＝圓鈕淡入；走完就停；自測推時鐘時畫面停在這一刻；計時器早到＝再排一次。
    func tick() {
        guard phase != .idle else { return }
        let t = elapsed
        if phase == .clearing {
            // 1ms 的容差：時鐘相減的浮點誤差（計時器本來就晚 2ms 排）。
            guard t >= clearLength - 0.001 else { return manualTime ? show(at: t) : schedule() }
            return finishClearing()
        }
        if phase == .fadingOut, !bubbleBack, t >= GlobalDMMorphTiming.reduceOut { bringBubbleBack(at: t) }
        guard t < end else { return settle(showBubble: true) }
        if manualTime { show(at: t) } else { schedule() }
    }

    /// 自測推時鐘：外殼、框內容、圓鈕都停在 elapsed 秒。
    func show(at elapsed: Double) {
        shell?.show(at: elapsed)
        if let layer = content?.layer { freeze(layer, at: contentOrigin + elapsed) }
        if phase == .clearing, let layer = cleared?.layer { freeze(layer, at: clearOrigin + elapsed) }
        if let layer = bubbleContent?.layer { freeze(layer, at: bubbleOrigin + elapsed) }
    }

    /// 停下：外殼拆掉、框內容照常；縮回（或收起的淡入淡出）走完＝圓鈕放回來（showBubble＝false：取消、長的那一段接著要開始）。
    private func settle(showBubble: Bool) {
        timer?.invalidate()
        timer = nil
        let was = phase
        guard was != .idle || shell != nil || content != nil || bubbleContent != nil else { return }
        if showBubble, was == .shrinking || was == .clearing || (was == .fadingOut && !bubbleBack),
           let bubbleWindow = bubble?(), bubbleWanted?() ?? true {
            show(bubbleWindow)
        }
        if let layer = bubbleContent?.layer {
            layer.removeAnimation(forKey: Self.bubbleKey)
            if manualTime { thaw(layer) }
        }
        bubbleContent = nil
        release(content)
        shell?.remove()
        shell = nil
        hideCatcher()
        plan = nil
        fadeLength = 0
        bubbleBack = false
        clearLength = 0
        if phase != .idle { phase = .idle }
    }

    // MARK: 點擊（查核 #1）

    /// 按到外殼或圓鈕本來的位置：同點圓鈕（開↔收）。
    private func pressed() { onClick?() }

    /// 圓鈕本來的位置放一塊看不見的點擊區（跟圓鈕本體一樣大）；level＝圓鈕的層級（比浮動框高一層：框的陰影邊蓋不到它，同圓鈕）。
    private func showCatcher(at circle: CGRect, level: NSWindow.Level) {
        let panel = catcher ?? makeCatcher()
        catcher = panel
        let spaces: NSWindow.CollectionBehavior = joinsAllSpaces ? Self.allSpaces : Self.localSpaces
        if panel.collectionBehavior != spaces { panel.collectionBehavior = spaces }
        if panel.level != level { panel.level = level }
        if panel.frame != circle { panel.setFrame(circle, display: false) }
        front(panel)
    }

    private func hideCatcher() {
        guard let catcher, catcher.isVisible else { return }
        catcher.orderOut(nil)
    }

    private func makeCatcher() -> GlobalDMMorphShellPanel {
        let size = GlobalDMLayout.buttonSize
        let panel = GlobalDMMorphShellPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        // 什麼都不畫的面板要接點擊得明確設 false（沒設＝視窗伺服器照像素透明度讓點擊穿過去）；圓形以外的四個小角由 hitTest 放掉（點了沒反應）。
        panel.ignoresMouseEvents = false
        panel.canHide = false
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "私訊鈕（長、縮途中）"
        panel.setAccessibilityIdentifier("tatwo.dm.desk.morphCatcher")
        let view = GlobalDMMorphCatcherView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.autoresizingMask = [.width, .height]
        view.onPress = { [weak self] in self?.pressed() }
        panel.contentView = view
        return panel
    }

    // MARK: 小工具

    /// 外殼、點擊區擺到最前面：浮動（anchor＝nil）＝這一層的最前面；停靠＝擺在主視窗那一疊的最上面（anchor 的正上方）。
    private func front(_ panel: NSWindow) {
        if let above = anchor?() {
            panel.order(.above, relativeTo: above.windowNumber)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// 圓鈕藏起來、放回來（停靠的圓鈕由面板控制器照子視窗的方式做）。
    private func hide(_ bubbleWindow: NSWindow) {
        if let hideBubble { hideBubble(bubbleWindow) } else { bubbleWindow.orderOut(nil) }
    }

    private func show(_ bubbleWindow: NSWindow) {
        if let showBubble { showBubble(bubbleWindow) } else { bubbleWindow.orderFrontRegardless() }
    }

    /// 外殼：面板、紙紋、圖層都在這裡建（重的工作）；t＝0 由呼叫的地方在這之後取（查核 #2）。
    private func makeShell(covering rect: CGRect, appearance: NSAppearance) -> GlobalDMMorphShell? {
        let frame = rect.insetBy(dx: -GlobalDMMorphTiming.pad, dy: -GlobalDMMorphTiming.pad)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let surface = GlobalDMFormStage.surface(appearance: appearance, size: frame.size)
        let shell = GlobalDMMorphShell(frame: frame, surface: surface, manual: manualTime)
        if shell.panel.level != shellLevel { shell.panel.level = shellLevel }   // W184 AB：停靠＝跟主視窗同一層
        if !joinsAllSpaces { shell.panel.collectionBehavior = Self.localSpaces }   // W184 AB（第三輪 #4）：停靠＝只在主視窗那個桌面
        shell.view.onPress = { [weak self] in self?.pressed() }   // 查核 #1：按到畫出來的外殼＝點圓鈕
        return shell
    }

    /// 這個圖層上「這一整段 t＝0」的本地時間（自測推時鐘：固定一個數、圖層停住）。
    private func timeOrigin(_ layer: CALayer) -> CFTimeInterval {
        guard manualTime else { return layer.convertTime(startedAt, from: nil) }
        freeze(layer, at: 1_000)
        return 1_000
    }

    private func freeze(_ layer: CALayer, at time: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.speed = 0
        layer.timeOffset = time
        CATransaction.commit()
        CATransaction.flush()
    }

    private func thaw(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.speed = 1
        layer.timeOffset = 0
        CATransaction.commit()
    }

    // MARK: 自測看

    /// 框內容現在的透明度（presentation；沒有動畫＝1）。
    var presentedContent: Float {
        guard let layer = (content ?? cleared ?? box?.contentView)?.layer else { return 1 }
        return (layer.presentation() ?? layer).opacity
    }

    /// 圓鈕內容現在的透明度（presentation）。
    func presentedBubble(_ window: NSWindow?) -> Float {
        guard let layer = window?.contentView?.layer else { return 1 }
        return (layer.presentation() ?? layer).opacity
    }
}
