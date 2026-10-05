import AppKit
import Combine
import QuartzCore
import SwiftUI

/// ⌥⌘ 該怎麼做：純判斷，好測。
enum GlobalDMToggleAction: Equatable {
    case ignore
    case closeFloating
    case toggleDocked
    case openFloating

    /// 浮動框開著就先關它；主視窗裡的框開著且有鍵盤焦點（例如別的 App 在前景時點圓鈕打開的）就關它；
    /// App 在前景且主視窗真的看得到就開關主視窗裡的框；其他情況（別的 App 在前景、主視窗隱藏、縮到 Dock、
    /// 在別的桌面或整個被蓋住）開螢幕右下角的獨立浮動框。
    static func resolve(enabled: Bool, floatingOpen: Bool, dockedFocused: Bool = false,
                        appActive: Bool, mainWindowVisible: Bool) -> Self {
        if floatingOpen { return .closeFloating }
        guard enabled else { return .ignore }
        if dockedFocused { return .toggleDocked }
        return appActive && mainWindowVisible ? .toggleDocked : .openFloating
    }
}

/// W179 UI：三種面板：主視窗裡的圓鈕、主視窗裡的框、獨立浮動框。
enum GlobalDMPanelKind { case dockedButton, dockedBox, floating }

/// 無邊框面板預設不能成為 key；私訊框要能直接打字。
final class GlobalDMPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func becomeKey() {
        super.becomeKey()
        GlobalHotkeyMonitor.shared.refreshAccessibilityPermission()
    }
    override var canBecomeMain: Bool { false }
    /// W184 G1b：面板的位置、大小由控制器決定（頂列至少 44pt 在範圍裡）：不讓系統把面板往選單列下面推（陰影邊超過 visibleFrame 時會推）。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// 不是 key 視窗時第一下點擊也要生效（網頁、CEF 上面也點得到）。
final class GlobalDMHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// W184 F3：排過幾次版（自測看：換形態只在開始、停下各排一次，動畫期間不排）。
    private(set) var layoutCount = 0
    #if DEBUG
    /// 自測看：最近幾次排版的時間（動畫期間那一次是什麼時候排的）。
    private(set) var layoutTimes: [CFTimeInterval] = []
    #endif

    #if DEBUG
    /// 自測：開著時每一次排版記下是誰叫的（找「動畫期間多排了一次」的來源）。
    static var traceLayouts = false
    private(set) var layoutStacks: [String] = []
    #endif

    override func layout() {
        super.layout()
        layoutCount += 1
        #if DEBUG
        layoutTimes.append(CACurrentMediaTime())
        if layoutTimes.count > 64 { layoutTimes.removeFirst(layoutTimes.count - 64) }
        if Self.traceLayouts {
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(36).map { line -> String in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                return parts.count > 3 ? parts[3...].prefix(1).joined() : line
            }
            layoutStacks.append("L\(layoutCount): " + frames.joined(separator: " < "))
            if layoutStacks.count > 16 { layoutStacks.removeFirst(layoutStacks.count - 16) }
        }
        #endif
    }

    /// 面板大小由控制器決定；SwiftUI 內容不回頭改視窗大小。W184 AB：一定有圖層。
    static func make(_ root: some View) -> GlobalDMHostingView {
        let host = GlobalDMHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        host.wantsLayer = true
        return host
    }
}

/// W184 F2：私訊框面板的內容畫面：平常裝著 SwiftUI 的框（填滿面板）；換形態時面板一次換成「舊框∪新框」的透明畫布。
/// W184 F3：畫布裡真的框只在開始（新形態、新大小）與停下各排一次版，動畫期間透明度 0；動畫是蓋在上面的圖層台（GlobalDMFormStage），
/// 圖是這裡拍的（拍的時候配對碼、原生網頁一定藏著）。
final class GlobalDMPanelCanvas: NSView {
    let host: GlobalDMHostingView
    /// 換形態進行中的圖層台（停著＝nil）。
    private(set) var stage: GlobalDMFormStage?
    /// 自測看：每一次拍圖時有沒有配對碼或原生網頁還在畫面上（有就是一筆、那一張不拍）。
    private(set) var captureProblems: [String] = []
    /// 拍了幾次（成功、拒拍、沒拍成都算；也是每一次的序號）。
    private(set) var captures = 0
    #if DEBUG
    /// 自測看：最近拍的圖（只給「四角透明」那種看最後一張的檢查用；安全檢查看 auditLog）。
    private(set) var recentCaptures: [CGImage] = []
    /// W184 G1b 第二輪（GPT-6 G1b 審查 #5：A1／S9 查的是 24 張的環形快取——滿了之後切出來是空的、早期的圖被淘汰就查不到）：
    /// 自測裝上像素檢查（標記色的像素數）之後，每一次拍當下就記一筆：序號、標籤、結果（拍成＋標記像素數／拒拍／沒拍成）。
    /// 不淘汰（只在裝了檢查的期間記：自測才有）。
    enum AuditOutcome: Equatable {
        case captured(markers: Int)
        case refused
        case failed
    }
    struct AuditEntry: Equatable {
        let seq: Int
        let label: String
        let outcome: AuditOutcome
    }
    static var captureAudit: ((CGImage) -> Int)?
    private(set) var auditLog: [AuditEntry] = []
    private func audit(_ seq: Int, _ label: String, _ outcome: AuditOutcome) {
        guard Self.captureAudit != nil else { return }
        auditLog.append(AuditEntry(seq: seq, label: label, outcome: outcome))
    }
    #endif

    init(host: GlobalDMHostingView) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(host)
        rest()
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 框（螢幕座標、不含陰影邊）擺進畫布（面板在螢幕上的位置 panelFrame）：四周照舊留陰影邊。
    func place(box: NSRect, panelFrame: NSRect, margin: CGFloat) {
        host.autoresizingMask = []
        let frame = NSRect(x: box.minX - margin - panelFrame.minX, y: box.minY - margin - panelFrame.minY,
                           width: box.width + margin * 2, height: box.height + margin * 2)
        if host.frame != frame { host.frame = frame }
    }

    /// 停著：框填滿面板（跟改之前一樣）、看得到；圖層台拆掉。
    func rest() {
        stage?.remove()
        stage = nil
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        if host.alphaValue != 1 { host.alphaValue = 1 }
    }

    /// 動畫開始：圖層台蓋在真的框上面，真的框透明度 0（不藏：鍵盤焦點、捲動位置、原生頁的持有都不動）。
    func present(_ stage: GlobalDMFormStage) {
        self.stage?.remove()
        self.stage = stage
        addSubview(stage.view, positioned: .above, relativeTo: host)
        host.alphaValue = 0
    }

    /// W184 F3（A1：GPT-6 審查 F3 #1）：拍真的框一張的唯一入口——換形態的舊樣子、新樣子、角的縮放預覽都走這裡（之後圓鈕長成框要拍內容也走這裡）。
    /// box＝host 座標裡的框（host 是 flipped，左上原點）。
    /// - 整個拍攝區間同步持有兩段遮蔽：配對碼（DMSecretCodeView.holdForCapture：現在畫著的藏起來；拍攝中 SwiftUI 更新到的、新掛上的照樣藏）、
    ///   原生網頁（GlobalDMNativePageMask 的 token：現有的藏起來、拍攝中新掛上的也藏、容器塗佔位色）。拍完照「當下的」遮蔽狀態還原
    ///   （轉換還持有＝照樣藏著），不是一律顯示。
    /// - 拍之前、拍之後都檢查：畫面上還有配對碼或原生頁＝不產圖（回 nil：呼叫的地方直接切到真的框、不做圖層轉場）。
    /// - 轉向時真的框是透明度 0：拍的那一刻照樣看得到（呼叫的地方在同一次畫面更新裡、畫面更新關著）。
    /// - 原本的邊（1pt、連續曲率的圓角）塗成底色：台自己畫邊（跟著框走）；圓角外（拍到的是陰影）清成透明；拍的那一下陰影全關（muteShadows）。
    ///   圖只放進這個面板的圖層台，不寫檔、不進紀錄。
    /// W184 AB（.031 真機 Retina）：scale＝拍的像素比例（沒給＝視窗的：Retina 2）；拍法換成 CALayer.render 照這個比例重畫圖層樹
    ///（跟 cacheDisplay 同樣的圖，量過 0 個像素不同；1x 拍在 2x 的視窗上不會走 AppKit 換比例的那條慢路）。
    func capture(_ form: GlobalDMForm, box: NSRect, fill: CGColor, label: String, scale requested: CGFloat? = nil) -> GlobalDMFormStage.Capture? {
        let codes = DMSecretCodeView.holdForCapture()
        let mask = GlobalDMNativePageMask.shared
        let pages = mask.begin()
        mask.cover(in: host)
        let transparent = host.alphaValue < 1
        if transparent { host.alphaValue = 1 }
        defer {
            if transparent { host.alphaValue = 0 }
            mask.end(pages)
            DMSecretCodeView.releaseCapture(codes)
        }
        captures += 1
        let seq = captures
        guard sensitiveOnScreen(label, "before") == nil else { return refuse(seq, label) }
        let scale = requested ?? nativeScale
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard box.width >= 1, box.height >= 1, width > 0, height > 0, let layer = host.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fail(seq, label) }
        cg.scaleBy(x: scale, y: scale)
        // host 的圖層是 geometryFlipped（左上原點；box 是 host 座標）：翻過來、移到框的左上角再畫。
        cg.saveGState()
        cg.translateBy(x: 0, y: box.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -box.minX, y: -box.minY)
        muteShadows { layer.render(in: cg) }
        cg.restoreGState()
        guard sensitiveOnScreen(label, "after") == nil else { return refuse(seq, label) }
        let rect = CGRect(origin: .zero, size: box.size)
        let path = RoundedRectangle(cornerRadius: DMPhone.screenRadius, style: .continuous).path(in: rect).cgPath
        // 圓角外那四小塊拍到的是框的陰影：清成透明（台上的框比這張寬、高時——例如出內橫——角落不會多一圈陰影的弧線，露出的是台自己的紙）。
        cg.saveGState()
        cg.addRect(rect)
        cg.addPath(path)
        cg.setBlendMode(.clear)
        cg.fillPath(using: .evenOdd)
        cg.restoreGState()
        cg.addPath(path)
        cg.clip()
        cg.addPath(path)
        cg.setStrokeColor(fill)
        cg.setLineWidth(3)
        cg.strokePath()
        guard let image = cg.makeImage() else { return fail(seq, label) }
        #if DEBUG
        recentCaptures.append(image)
        if recentCaptures.count > 24 { recentCaptures.removeFirst(recentCaptures.count - 24) }
        if let check = Self.captureAudit { audit(seq, label, .captured(markers: check(image))) }
        #endif
        let tent = form == .tent ? Self.tentFill(in: host) : nil
        return GlobalDMFormStage.Capture(form: form, image: image, size: box.size, scale: scale, tentFill: tent)
    }

    /// W184 AB：新的樣子用多大的像素比例拍。Retina 上框小（照視窗的比例 ≤ 1.3M 像素：外直、倒放）＝照視窗的 2x；框大（內直、內橫在
    /// 預設大小是 2.2M 像素：mini 上 2x 拍一張 60–210ms、MacBook 更久）＝1x——新的樣子早一點換上（舊的圖不會一直切著留到動畫後段）；
    /// 動畫中的字比較軟，停下就換回真的框（清楚）。
    static let freshPixelBudget: CGFloat = 1_300_000

    func freshScale(for size: CGSize) -> CGFloat {
        let native = nativeScale
        guard native > 1 else { return native }
        return size.width * size.height * native * native <= Self.freshPixelBudget ? native : 1
    }

    /// 拍新樣子用的像素比例：視窗的（Retina＝2）。自測可以換（在 1x 的機器上量接近 Retina 的成本：同一棵圖層樹照兩倍像素重畫）。
    var nativeScale: CGFloat {
        #if DEBUG
        if let override = Self.nativeScaleOverride { return override }
        #endif
        return window?.backingScaleFactor ?? 1
    }

    #if DEBUG
    static var nativeScaleOverride: CGFloat?
    #endif

    /// W184 F3（量到：mini 1x 拍一張內橫 140–180ms，取樣裡大半是 CALayer.render 替有陰影的圖層做高斯模糊——框裡有 49 層有陰影：
    /// 框本身、輸入框的「牛皮紙表面」陰影套在整個輸入框上＝SwiftUI 把它分到每一個小元件（＋、記憶、模型膠囊、字、箭頭），CPU 拍的時候
    /// 每一層都要畫進離屏再模糊，加上留白一共約 3.4M pt²；Retina 上像素 4 倍、模糊核 2 倍）：拍的那一下所有陰影先關掉、拍完照原值還原，
    /// 在同一個關掉動作的 CATransaction 裡（畫面伺服器看不到）。量到：1x 內橫 147→50ms；跟照原樣拍比，沒有一個像素差超過 40/255
    ///（最大 29/255：輸入框小元件與頁面圓鈕的淡陰影，只在 0.6 秒的動畫裡少了，停下換回真的框就在）。
    private func muteShadows(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var muted: [(CALayer, Float)] = []
        var stack: [CALayer] = host.layer.map { [$0] } ?? []
        var visited = 0
        while let layer = stack.popLast(), visited < 4000 {
            visited += 1
            if layer.shadowOpacity > 0 {
                muted.append((layer, layer.shadowOpacity))
                layer.shadowOpacity = 0
            }
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        body()
        for (layer, opacity) in muted { layer.shadowOpacity = opacity }
        CATransaction.commit()
        #if DEBUG
        lastMutedShadows = muted.count
        #endif
    }

    #if DEBUG
    /// 自測看：最近一次拍的時候關掉幾層陰影。
    private(set) var lastMutedShadows = 0
    /// 自測：同一套關陰影的做法包住自測自己的拍法（比關與不關的像素、時間）。
    func withShadowsMutedForTesting(_ body: () -> Void) { muteShadows(body) }
    #endif

    /// 拒拍（畫面上還有配對碼或原生頁）、沒拍成：自測記一筆，回 nil。
    private func refuse(_ seq: Int, _ label: String) -> GlobalDMFormStage.Capture? {
        #if DEBUG
        audit(seq, label, .refused)
        #endif
        return nil
    }

    private func fail(_ seq: Int, _ label: String) -> GlobalDMFormStage.Capture? {
        #if DEBUG
        audit(seq, label, .failed)
        #endif
        return nil
    }

    /// 拍的那一刻畫面上還看得到的配對碼、原生網頁（有＝記一筆、不拍）。
    private func sensitiveOnScreen(_ label: String, _ when: String) -> String? {
        let codes = DMSecretCodeView.liveViews.filter { $0.isDescendant(of: host) && !$0.isHiddenOrHasHiddenAncestor }
        let pages = Self.nativeHosts(in: host).flatMap(\.subviews).filter { !$0.isHiddenOrHasHiddenAncestor }
        guard !codes.isEmpty || !pages.isEmpty else { return nil }
        let problem = "\(label) \(when): \(codes.count) code view(s), \(pages.count) native page(s) on screen — not captured"
        captureProblems.append(problem)
        return problem
    }

    // MARK: 捲動（W184 F3）

    /// 真的框裡捲得動的列表（對話、內橫右欄的對話）。
    func scrollLists() -> [NSScrollView] {
        Self.descendants(NSScrollView.self, in: host).filter { scroll in
            guard let document = scroll.documentView, !scroll.isHiddenOrHasHiddenAncestor else { return false }
            return document.frame.height > scroll.contentView.bounds.height + 1
        }
    }

    /// 離最底多遠（點）。
    static func distanceFromBottom(_ scroll: NSScrollView) -> CGFloat {
        let visible = scroll.contentView.bounds, height = scroll.documentView?.frame.height ?? 0
        return scroll.documentView?.isFlipped == true ? height - visible.maxY : visible.minY
    }

    /// 換形態之前捲上去看舊訊息（不在最底）的列表。
    func listsAwayFromBottom() -> Set<ObjectIdentifier> {
        Set(scrollLists().filter { Self.distanceFromBottom($0) > 8 }.map { ObjectIdentifier($0) })
    }

    /// 排版之後：原本在最底的（或新出現的）列表捲回最底——聊天的習慣，最新一則一直在最下面（AppKit 的捲動區變矮時是離最上面不變，
    /// 最底那幾則會被切掉）。捲上去看舊訊息的（away）不動。有捲就回 true（懶載入的列要再排一次才出來）。
    func pinBottoms(except away: Set<ObjectIdentifier>) -> Bool {
        var moved = false
        for scroll in scrollLists() where !away.contains(ObjectIdentifier(scroll)) {
            guard Self.distanceFromBottom(scroll) > 0.5, let document = scroll.documentView else { continue }
            let visible = scroll.contentView.bounds
            let y = document.isFlipped ? document.frame.height - visible.height : 0
            scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            moved = true
        }
        return moved
    }

    /// W184 AB（R2；GPT-6 審 G3c #4）：捲上去看舊訊息（away）的列表，換形態之前記下使用者在讀的那一則——頂列底下看得到的第一則
    /// （GlobalDMListRows.reading；不是藏在頂列、漸淡底下只露一截的那一則）——與那時每一則的位置。
    func readingRows(in away: Set<ObjectIdentifier>) -> [ObjectIdentifier: GlobalDMListRows.Snapshot] {
        guard !away.isEmpty else { return [:] }
        #if DEBUG
        guard Self.keepsReading else { return [:] }
        #endif
        var result: [ObjectIdentifier: GlobalDMListRows.Snapshot] = [:]
        for scroll in scrollLists() where away.contains(ObjectIdentifier(scroll)) {
            guard let rows = GlobalDMListRows.of(scroll), let snapshot = rows.snapshot() else { continue }
            result[ObjectIdentifier(scroll)] = snapshot
            #if DEBUG
            traceReading("reading \(snapshot.id)@\(Self.pt(snapshot.top)) covered \(Self.pt(rows.covered))")
            #endif
        }
        return result
    }

    /// 排版之後：在讀的那一則捲回原來的位置。欄寬變了，上面幾則重新換行、懶載入的列重估高度，AppKit／SwiftUI 留住的是捲動區裡
    /// 最上面那一列（頂列底下只露一截的那一則）或別的位置——在讀的那一則會被推走。有捲就回 true（要再排一次：懶載入的列排出來）。
    func keepReading(_ reading: [ObjectIdentifier: GlobalDMListRows.Snapshot]) -> Bool {
        guard !reading.isEmpty else { return false }
        var moved = false
        for scroll in scrollLists() {
            guard let snapshot = reading[ObjectIdentifier(scroll)], let rows = GlobalDMListRows.of(scroll),
                  let document = scroll.documentView else { continue }
            let drift = rows.drift(from: snapshot)
            let visible = scroll.contentView.bounds
            let limit = max(0, document.frame.height - visible.height)
            let y = min(limit, max(0, document.isFlipped ? visible.minY + (drift ?? 0) : visible.minY - (drift ?? 0)))
            #if DEBUG
            traceReading("drift \(drift.map(Self.pt) ?? "unmeasured") (\(rows.rows.values.filter(\.fresh).count) fresh) "
                         + "offset \(Self.pt(visible.minY))→\(Self.pt(y))")
            #endif
            guard let drift, abs(drift) > 0.5, abs(y - visible.minY) > 0.5 else { continue }
            rows.beginPass()
            scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            moved = true
        }
        return moved
    }

    /// W184 F3＋AB（R2）：換形態排版之後整理捲動位置——原本在最底的捲回最底（pinBottoms）；捲上去看舊訊息的，在讀的那一則捲回原來的位置
    /// （keepReading）。有捲就再排一次（懶載入的列排出來、量出真的高度），在讀的那一則還差就再對一次、再排一次（最多這兩次）。
    func settleLists(away: Set<ObjectIdentifier>, reading: [ObjectIdentifier: GlobalDMListRows.Snapshot]) {
        let pinned = pinBottoms(except: away)
        let kept = keepReading(reading)
        guard pinned || kept else { return }
        host.layoutSubtreeIfNeeded()
        if kept, keepReading(reading) { host.layoutSubtreeIfNeeded() }
    }

    #if DEBUG
    /// 自測的反例（F3T R2）：關掉「守住在讀的那一則」＝退回只靠 AppKit／SwiftUI 自己留的位置。正式版沒有這個開關。
    static var keepsReading = true
    /// 自測看：換形態時在讀的那一則怎麼守的（記下的那一則、每一次對的差距與捲動位置；留最近 60 筆）。
    var readingTrace: [String] = []
    private func traceReading(_ line: String) {
        readingTrace.append(line)
        if readingTrace.count > 60 { readingTrace.removeFirst(readingTrace.count - 60) }
    }
    private static func pt(_ value: CGFloat) -> String { String(format: "%.1f", value) }
    #endif

    /// 倒放影片容器的佔位色（黑＝有影片；空狀態＝nil）。
    static func tentFill(in root: NSView) -> CGColor? {
        for container in descendants(DMTentVideoContainer.self, in: root) {
            let color = container.placeholderFill
            if color.alpha > 0.5 { return color }
        }
        return nil
    }

    static func nativeHosts(in root: NSView) -> [NSView] {
        var result: [NSView] = []
        var stack: [NSView] = [root]
        var visited = 0
        while let view = stack.popLast(), visited < 4000 {
            visited += 1
            if view is GlobalDMNativePageHost {
                result.append(view)
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    static func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var result: [T] = []
        var stack: [NSView] = [root]
        var visited = 0
        while let view = stack.popLast(), visited < 4000 {
            visited += 1
            if let match = view as? T { result.append(match) }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }
}

/// W184 G1：框擺放用的範圍（螢幕座標、不含陰影邊）：預設的框、參考範圍（浮動＝螢幕 visibleFrame、停靠＝主視窗內容區）、
/// 能拖的範圍、要避開的輸入框（停靠框才有：量到的或估計的；浮動框＝nil）。
struct GlobalDMPlacementGeometry: Equatable {
    var standard: NSRect
    var reference: NSRect
    var bounds: NSRect
    var composer: NSRect?
}

/// W184 G1b：一次角的縮放：哪個框、哪個角、按下那一刻的框、比例 1 的大小、範圍、參考（記位置用）、記住的位置與大小、
/// 圓鈕模式的圓鈕；current／scale＝現在預覽的框與比例（放開才存）。
struct GlobalDMGrip {
    let corner: GlobalDMResizeCorner
    let surface: GlobalDMSurface
    let box: NSRect
    let base: CGSize
    let area: NSRect
    let reference: NSRect
    let placement: GlobalDMBoxPlacement
    var bubble: NSRect? = nil
    /// 預設的框（圓鈕模式：開在圓鈕旁＝讓不開時的退路）。
    var standard: NSRect = .zero
    /// 按下那一刻框用的比例（縮到邊上不能再縮＝框原樣、比例原樣）。
    var startScale: CGFloat = 1
    var current: NSRect
    var scale: CGFloat? = nil
}

/// W184 G1b 第二輪（GPT-6 G1b 審查 #1：拖到一半收框位置丟了、換模式寫到另一份）：一次原生拖曳開始那一刻就定好的東西——
/// 存到哪一份（浮動、停靠、圓鈕模式）、按下那一刻記住的位置與大小、幾何參考（停靠＝主視窗內容區與預設的框；圓鈕模式＝那一刻的圓鈕、
/// 它的螢幕、開在它旁邊的預設框；浮動＝放的地方那個螢幕，放開才看）。放開、途中收框、途中換模式都照這一份存，不重猜、不靠框還開著。
struct GlobalDMDragContext {
    enum Key: String, Equatable { case floating, docked, bubble }
    let panel: GlobalDMPanel
    let surface: GlobalDMSurface
    let key: Key
    let placement: GlobalDMBoxPlacement
    let geometry: GlobalDMPlacementGeometry?
    let bubble: NSRect?
}

/// 停靠框照主視窗算出來的擺法（只算不擺）：內容區、AppKit 量到的輸入框、SwiftUI 回報的來源、預設的擺法、要避開的輸入框（量不到用估計值）。
struct GlobalDMDockedPlaced {
    let content: NSRect
    let probed: NSRect?
    let source: GlobalDMComposerSource?
    let placement: GlobalDMDockLayout.Placement
    let composer: NSRect?
}

/// 承載圓鈕與私訊框：
/// - 主視窗看得到時：主視窗的兩個子面板（圓鈕一個、框一個），貼齊內容區右下（右 12、下 8；碰到輸入框就抬高），
///   框在圓鈕上方、下緣在輸入框之上（`GlobalDMDockLayout`），跟著主視窗移動、縮放；主視窗縮到 Dock、隱藏或關掉時一起藏。
///   W179 UI：主視窗有東西整頁蓋上來（設定、sheet、App 層級確認框…）時兩個子面板先收起，拿掉後回來；
///   工具核准的確認框例外（私訊框的「等你核准」列要看得到）。
/// - ⌥⌘ 在其他 App（或主視窗看不到）時：獨立浮動面板，出現在滑鼠所在螢幕的右下角（內縮 24），
///   不把整個 App 叫到前景、可以直接打字、所有桌面與全螢幕 App 上都看得到；再按 ⌥⌘ 或 Esc 關掉。
@MainActor
final class GlobalDMPanelController {
    static let shared = GlobalDMPanelController()

    let store: GlobalDMStore
    /// W179 E：私訊框的形態（W184 AB：停靠框、浮動框都照它）。
    let desk: GlobalDMDeskSettings
    /// W184 AB：換形態的動畫與「轉換進行中」（可觀察）。
    let formMotion: GlobalDMFormMotion
    /// W179 E：縮成桌面圓鈕時回傳圓鈕（44pt 本體）的螢幕位置，浮動框開在它旁邊；平常是 nil。
    var floatingAnchor: (@MainActor () -> NSRect?)?
    /// W184 F45：縮成桌面圓鈕時圓鈕長成浮動框、浮動框縮回圓鈕（桌面控制器接上圓鈕；沒接＝框照舊直接開關）。
    let buttonMorph = GlobalDMButtonMorph()
    /// W184 AB（使用者 09-30 .031：「停靠時主視窗裡的私訊鈕跟框同時存在」）：主視窗裡的圓鈕 ↔ 停靠框，同一套外殼（F45）：
    /// 停靠框開著時圓鈕不出現；打開＝從圓鈕長成框、收起＝縮回圓鈕（外殼只畫紙紋底色、不拍內容）；減少動態效果＝淡入淡出。
    let dockedMorph = GlobalDMButtonMorph()
    /// W184 AB（GPT-6 第三輪 #1–#3）：停靠的長、縮、淡出開始那一刻主視窗內容區在螢幕上的位置與大小；途中變了（移動、改大小、換螢幕、
    /// 全螢幕）＝外殼直接到位，再照新的主視窗擺圓鈕與框。
    private var dockedMorphContent: NSRect?
    /// NSWorkspace 的通知（桌面切換）另外記：要從 NSWorkspace 的通知中心拿掉。
    private var workspaceObservers: [NSObjectProtocol] = []
    private let hostsWindows: Bool
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var modeWatch: AnyCancellable?
    private var keyMonitor: Any?
    /// W179 UI：主視窗裡的圓鈕（子面板）。
    private var dockedButton: GlobalDMPanel?
    /// 主視窗裡的私訊框（子面板）；Esc、鍵盤焦點都看它。
    private var docked: GlobalDMPanel?
    private var floating: GlobalDMPanel?
    /// 上一次整理時停靠面板的狀態：只有「圓鈕在、框剛打開」那一次給框鍵盤焦點。
    private var dockedPresence: GlobalDMDockedPresence = .hidden
    /// sheet 正要掛上（willBegin 時 attachedSheet 還是 nil）。
    private var sheetStarting = false
    /// 上一次看到的 App 層級確認框狀態：key 視窗換來換去時只有它變了才整理。
    private var lastAppModal = false
    /// App 層級確認框開著時每 0.25 秒看一次它關了沒（關掉不一定有通知）。
    private var modalWatch: Timer?
    private weak var closingWindow: NSWindow?
    /// 上一次整理時浮動框是不是開著：只有「剛打開」那一次給它鍵盤焦點。
    private var floatingWasOpen = false
    private(set) var isInstalled = false
    /// W184 F2：轉換中的面板與它的畫布（舊框∪新框＋陰影邊）；轉換中整理（reconcile）不改它的大小。
    private weak var canvasPanel: GlobalDMPanel?
    private var canvasFrame: NSRect?
    /// W184 F／G1（GPT-6 審查 #4）：停靠框開始轉換時主視窗內容區的螢幕位置；轉換中主視窗移動或改大小＝轉換直接停在終點再照平常重擺。
    private var canvasContent: NSRect?
    /// W184 F3：形態改之前（desk.form 的 willSet）拍好的舊樣子：哪個面板、哪個形態、什麼時候拍的。applyForm 的第一段拿它當舊的圖。
    private var pendingOld: (panel: ObjectIdentifier, form: GlobalDMForm, capture: GlobalDMFormStage.Capture, at: CFTimeInterval)?
    /// 自測看：最近一次換形態開始、停下各花了主執行緒多久（秒）、各一步的時間與真的框排版到第幾次；拍舊樣子時排了幾次版。
    private(set) var lastStartCost: Double = 0
    private(set) var lastStopCost: Double = 0
    private(set) var lastStartTrace: [String] = []
    private(set) var lastStopTrace = ""
    /// 停下那一次（面板換回新框、拆掉圖層台）真的框排了幾次版（大小不變＝0）。
    private(set) var lastStopLayouts = 0
    /// A1：拍不了（還有配對碼或原生頁）、直接切到真的框的次數。
    private(set) var skippedTransitions = 0
    private(set) var lastPrepareLayouts = 0
    /// 自測看：最近一次拍舊的樣子花了主執行緒多久（秒）。
    private(set) var lastPrepareCost: Double = 0
    /// W184 F2／G1b：這個面板現在由別的流程管位置與大小（換形態的畫布、原生拖曳、角的縮放）：整理（reconcile）不改它。
    private func isHeld(_ panel: GlobalDMPanel) -> Bool {
        if panel === canvasPanel || panel === dragPanel { return true }
        guard let grip else { return false }
        return (grip.surface == .floating ? floating : docked) === panel
    }

    /// W184 G1b：角的縮放（放開才存進 desk；途中是圖層台的快照預覽）。
    private var grip: GlobalDMGrip?
    /// W184 G1b：原生視窗拖曳中的那一次（視窗伺服器帶著走；放開才算位置）：這段時間整理（reconcile）不改它的大小與位置。
    private var drag: GlobalDMDragContext?
    private var dragPanel: GlobalDMPanel? { drag?.panel }
    private var dragTimer: Timer?
    /// 自測看：最近一次放開（或途中收框、換模式結束）的位置（放的地方、推回之後）、存到哪一份、為什麼結束；
    /// 縮放開始花多久、縮放途中每一次事件花多久。
    private(set) var lastDrop: (dropped: NSRect, landed: NSRect, key: GlobalDMDragContext.Key, reason: String)?
    private(set) var lastResizeStartCost: Double = 0
    private(set) var resizeEvents = 0
    private(set) var resizeEventCost: Double = 0
    /// W184 F／G1（GPT-6 審查 #5）：框裡的 Browser 用哪一份（正式＝nil＝這台的 .shared；自測接假的 Browser、假授權頁、假配對碼）。
    let browserServices: GlobalDMBrowserServices

    /// `hostsWindows: false` 給無頭自測：只改狀態，不建任何視窗。
    /// 預設值在 init 裡取（主執行緒）；寫在參數預設值會是 Swift 6 的隔離錯誤。
    init(store: GlobalDMStore? = nil, desk: GlobalDMDeskSettings? = nil, hostsWindows: Bool = true,
         browserServices: GlobalDMBrowserServices = GlobalDMBrowserServices()) {
        self.store = store ?? .shared
        self.desk = desk ?? .shared
        self.hostsWindows = hostsWindows
        self.browserServices = browserServices
        self.formMotion = GlobalDMFormMotion()
        formMotion.onFrame = { [weak self] frame, finished in self?.slideFrame(frame, finished: finished) }
        formMotion.onTick = { [weak self] elapsed in self?.showStage(at: elapsed) }
    }

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        // W184 AB：圓鈕模式收框的內容淡完＝現在才收掉真的框（整理一次：hideFloating → orderOut）。
        buttonMorph.onCleared = { [weak self] in self?.reconcile() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .tatwoToggleGlobalDM, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleToggle() }
        })
        guard hostsWindows else { return }
        wireDockedMorph()
        let windowEvents: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
            NSWindow.willCloseNotification,
        ]
        for name in windowEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // 通知本身不帶進主執行緒的閉包（Swift 6 並行檢查）：先取出主視窗與是不是要關。
                let window = note.object as? TatwoWorkOSWindow
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    if closing { self.closingWindow = window }
                    self.reconcile()
                }
            })
        }
        // W184 F／G1（GPT-6 審查 #4）：主視窗移動平常不用整理（子面板跟著走）；停靠框換形態途中移動＝轉換直接停在終點再照平常重擺。
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] note in
            let fromMain = note.object is TatwoWorkOSWindow
            MainActor.assumeIsolated {
                guard let self, fromMain else { return }
                // W184 AB（第三輪 #1、#2）：停靠的長、縮、淡出途中主視窗移動＝整理（整理裡看到主視窗換了位置就讓外殼直接到位、收完框、
                // 照新位置放回圓鈕）；外殼不是子視窗，不會跟著走。
                guard self.dockedMorph.isAnimating || (self.canvasPanel != nil && self.canvasPanel === self.docked) else { return }
                self.reconcile()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let fromMain = note.object is TatwoWorkOSWindow
            MainActor.assumeIsolated {
                guard fromMain else { return }
                self?.detachDocked()
            }
        })
        // W179 UI：主視窗掛 sheet 時停靠面板先收起；willBegin 時 attachedSheet 還沒設好，先記一筆、下一輪再看一次。
        observers.append(center.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil,
                                            queue: .main) { [weak self] note in
            // 通知本身不帶進主執行緒的閉包（Swift 6 並行檢查），只帶「是不是主視窗」。
            let fromMain = note.object is TatwoWorkOSWindow
            MainActor.assumeIsolated {
                guard let self, fromMain else { return }
                self.sheetStarting = true
                self.reconcile()
                Task { @MainActor [weak self] in
                    self?.sheetStarting = false
                    self?.reconcile()
                }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didEndSheetNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let fromMain = note.object is TatwoWorkOSWindow
            MainActor.assumeIsolated {
                guard fromMain else { return }
                self?.reconcile()
            }
        })
        // App 層級確認框（runModal）開關時 key 視窗會換；只有確認框的有無變了才整理。
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, (NSApp.modalWindow != nil) != self.lastAppModal else { return }
                    self.reconcile()
                }
            })
        }
        let appEvents: [Notification.Name] = [
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification,
        ]
        for name in appEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            })
        }
        Publishers.Merge3(store.$isOpen.map { _ in () }, store.$isFloatingOpen.map { _ in () },
                          store.$isEnabled.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        desk.$form.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        store.$model
            .receive(on: DispatchQueue.main)
            .sink { [weak self] model in
                self?.modeWatch = model?.$mode.removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.reconcile() }
            }
            .store(in: &cancellables)
        // W179 UI：主視窗的蓋層（設定、搜尋、燈箱…）與輸入框位置（文字長高、側欄開關、右側面板推擠）一變就重擺。
        GlobalDMCoverRegistry.shared.$overlays.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        GlobalDMComposerFrames.shared.$frames.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // W184 G3c（GPT-6 審查 #2）：ChatGPT 那一欄的鍵盤入口（⌘⇧S 對話清單、⌘⇧O 新聊天；跟下面兩條的鍵不重疊）。
            guard let event = self.handleChatGPTKeys(event) else { return nil }
            // W184 G2c：⌘⌥T＝私訊框 Browser 的新分頁（私訊框自己的按鍵，不是全域熱鍵）；其他照舊走 Esc 的路。
            guard let event = self.handleNewTab(event) else { return nil }
            return self.handleEscape(event)
        }
        reconcile()
    }

    func uninstall() {
        buttonMorph.onCleared = nil
        dockedMorph.cancel()
        dockedMorph.onClick = nil
        dockedMorph.onCleared = nil
        dockedMorph.bubble = nil
        dockedMorph.bubbleWanted = nil
        dockedMorph.anchor = nil
        dockedMorph.hideBubble = nil
        dockedMorph.showBubble = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        cancellables = []
        modeWatch = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        detachDocked()
        floating?.orderOut(nil)
        floating = nil
        floatingWasOpen = false
        docked?.orderOut(nil)
        docked = nil
        dockedButton?.orderOut(nil)
        dockedButton = nil
        modalWatch?.invalidate()
        modalWatch = nil
        dockedPresence = .hidden
        isInstalled = false
    }

    // MARK: - ⌥⌘

    func handleToggle() {
        guard !GlobalDMHotKeys.shared.isSuspended, !store.isEditingDirectKeys else { return }
        let action = GlobalDMToggleAction.resolve(enabled: store.isEnabled, floatingOpen: store.isFloatingOpen,
                                                  dockedFocused: store.isOpen && docked?.isKeyWindow == true,
                                                  appActive: hostsWindows && NSApp.isActive,
                                                  mainWindowVisible: mainWindowOnScreenForUser() != nil && !mainWindowCovered)
        switch action {
        case .ignore: return
        case .closeFloating: store.isFloatingOpen = false
        case .toggleDocked: store.toggleDocked()
        case .openFloating: store.openFloating()
        }
        reconcile()
    }

    /// W184 AB（GPT-6 審查 #4、複核 新發現 1–3）：「要看到某個畫面」的入口都帶一個開框請求走 open(_:)
    /// （直達鍵、到私訊框設定、流程開的授權頁與配對頁、［連線］卡）。桌面控制器接上這個關口：倒放不能顯示它們，
    /// 先切回能顯示的形態（照轉換表與減少動態效果），轉換動畫中就把整個請求排隊、走完再做。沒接＝直接做。
    var contentGate: (@MainActor (GlobalDMOpenRequest) -> Void)?

    /// W179 E：直達鍵與設定頁的「到私訊框設定」＝打開私訊框（不是開關）；照 ⌥⌘ 的規則選停靠框或浮動框。
    func open() {
        open(GlobalDMOpenRequest())
    }

    /// 帶著請求打開：框真的開好之後才做請求裡的選頁、選對象、設定旗標；完成回呼帶開框前後的樣子。
    func open(_ request: GlobalDMOpenRequest) {
        guard let contentGate else { return perform(request) }
        contentGate(request)
    }

    /// 關口放行（出列）：再驗證（撤銷了、目標不在了、私訊鈕關著＝不開）→ 照 ⌥⌘ 規則開框 → 開好了才做 then。
    func perform(_ request: GlobalDMOpenRequest) {
        request.run(store: store) { openNow() }
    }

    private func openNow() {
        let action = GlobalDMOpenAction.resolve(enabled: store.isEnabled, floatingOpen: store.isFloatingOpen,
                                                dockedShowing: store.isOpen && store.isDockedVisible,
                                                appActive: hostsWindows && NSApp.isActive,
                                                mainWindowVisible: mainWindowOnScreenForUser() != nil && !mainWindowCovered)
        switch action {
        case .ignore: return
        case .focusFloating: floating?.makeKey()
        case .focusDocked: docked?.makeKey()
        case .openDocked: store.openDocked()
        case .openFloating: store.openFloating()
        }
        reconcile()
    }

    /// Esc 只關私訊框（組字中交給輸入法；對象清單開著先關清單），不讓主視窗的 Esc 關窗接到。
    private func handleEscape(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window === docked || window === floating else { return event }
        return Self.routeEscape(event, window: window, floating: floating, store: store, form: desk.form)
    }

    /// W184 G3c（GPT-6 審查 #2）：ChatGPT 那一欄的鍵盤入口（只看停靠框、浮動框）。
    private func handleChatGPTKeys(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window === docked || window === floating else { return event }
        return Self.routeChatGPTKeys(event, window: window, store: store, form: desk.form, duo: GlobalDMDuo.shared.existing,
                                     browserHasTabs: (browserServices.browser ?? .shared).hasTabs)
    }

    /// W184 G3c（GPT-6 審查 #2：拿掉 ≡ 之後鍵盤要有抽屜入口）：⌘⇧S＝開關 ChatGPT 的對話清單（抽屜；打開＝焦點進抽屜的搜尋欄，
    /// 收起＝焦點回輸入框），⌘⇧O＝開新聊天（GlobalDMChatGPTKeys）。ChatGPT 那一欄看得到才收：左欄優先，左欄不是 ChatGPT 時給內橫右欄的
    /// ChatGPT；組字中、在設直達鍵、倒放照原本的路。
    static func routeChatGPTKeys(_ event: NSEvent, window: NSWindow, store: GlobalDMStore, form: GlobalDMForm, duo: GlobalDMStore?,
                                 browserHasTabs: Bool) -> NSEvent? {
        let drawer = GlobalDMChatGPTKeys.matches(event, keyCode: GlobalDMChatGPTKeys.drawerKeyCode)
        let newChat = GlobalDMChatGPTKeys.matches(event, keyCode: GlobalDMChatGPTKeys.newChatKeyCode)
        guard drawer || newChat, form != .tent, !isComposing(in: window) else { return event }
        let left = store.target == .chatGPT && store.chatGPTAvailable && !store.isEditingDirectKeys && !(store.isBrowsing && !form.isDuo)
        let right = form.isDuo && !left
            && !GlobalDMDuoLayout.rightColumnShowsBrowser(browsing: store.isBrowsing, browsingBeside: store.isBrowsingBeside,
                                                          hasTabs: browserHasTabs, hasSecondary: duo != nil)
        guard let owner = left ? store : (right ? duo : nil), owner.target == .chatGPT, owner.chatGPTAvailable,
              !owner.isEditingDirectKeys else { return event }
        if drawer {
            owner.toggleChatGPTDrawerFromKeyboard()
        } else {
            _ = owner.newChatGPTConversation()
        }
        return nil
    }

    /// W184 G2c：⌘⌥T＝新分頁（只看停靠框、浮動框）。W184 G2c 第二輪：右欄拿不拿得到第二個 store 跟畫面（GlobalDMBoxHost）看同一份。
    private func handleNewTab(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window === docked || window === floating else { return event }
        return Self.routeNewTab(event, window: window, store: store, form: desk.form, browser: browserServices.browser ?? .shared,
                                hasSecondary: GlobalDMDuo.shared.hasSecondary)
    }

    /// W184 G2c（使用者 09-29 驗收 .030：「沒有新增分頁的功能 並且快捷鍵一樣command option t」）：⌘⌥T＝私訊框 Browser 的新分頁。
    /// 只在私訊框是 key 視窗、而且看得到 Browser 時收；別的時候（對話、倒放、在設直達鍵、輸入法組字中）照原本的路走。
    /// 不是全域熱鍵：私訊框拿著鍵盤時才看得到這一下；⌥⌘T 不能設成直達鍵（GlobalDMDirectKeyRules.blocked）。
    /// 主視窗的 ⌘T（沒有 ⌥）不受影響。認實體鍵位（跟輸入法無關，同直達鍵）。
    /// W184 G2c 第二輪（GPT-6 #1）：「看得到 Browser」跟畫面同一個判斷（GlobalDMDuoLayout.showsBrowser）——內橫選了左欄的對話對象
    /// （兩個旗標都清掉），右欄因為還有分頁照樣是 Browser，⌘⌥T 也照樣收。GPT-6 #2：組字看任何文字輸入（isComposing），不只 NSTextView。
    static func routeNewTab(_ event: NSEvent, window: NSWindow, store: GlobalDMStore, form: GlobalDMForm, browser: DMBrowser,
                            hasSecondary: Bool) -> NSEvent? {
        guard DMBrowserNewTabKey.matches(event), window.isKeyWindow else { return event }
        if isComposing(in: window) { return event }
        guard !store.isEditingDirectKeys,
              GlobalDMDuoLayout.showsBrowser(form: form, browsing: store.isBrowsing, browsingBeside: store.isBrowsingBeside,
                                             hasTabs: browser.hasTabs, hasSecondary: hasSecondary) else { return event }
        GlobalHotkeyMonitor.shared.cancelPendingChord()   // 這一下 ⌥⌘ 手勢作廢（放開時不開關私訊框）
        browser.newTab()
        return nil
    }

    /// W184 G2c 第二輪（GPT-6 #2）：拿著鍵盤的東西正在組字（輸入法的字還沒選完）——任何文字輸入（NSTextInputClient：網址欄、對話輸入框、
    /// 網頁裡的輸入框），不只 NSTextView。組字中的 Esc、⌘⌥T 一律交給輸入法。
    static func isComposing(in window: NSWindow) -> Bool {
        guard let text = window.firstResponder as? NSTextInputClient else { return false }
        return text.hasMarkedText()
    }

    /// 停靠框、浮動框的 Esc 怎麼走（W184 G2 修正：抽成靜態的判斷——自測拿真的 Esc 事件走同一條）。
    static func routeEscape(_ event: NSEvent, window: NSWindow, floating: NSWindow?, store: GlobalDMStore, form: GlobalDMForm) -> NSEvent? {
        guard event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
        if isComposing(in: window) { return event }
        // W184 G3（查證 #2、#7）：ChatGPT 的即時語音開著先停（Browser 開著也一樣；再按一次＝直接關掉語音那一頁）。內橫右欄的也算。
        if store.endChatGPTVoiceForEscape() || GlobalDMDuo.shared.existing?.endChatGPTVoiceForEscape() == true { return nil }
        // W184 E：倒放沒有 Browser 那一頁、也沒有對象清單（整塊是影片子畫面）：Esc＝收框（影片還回主視窗的分頁），不給倒放框裡的網頁。
        if form == .tent {
            if window === floating { store.isFloatingOpen = false } else if store.isOpen { store.isOpen = false } else { return event }
            CoderSheetEscapeGuard.armForDM(after: event)
            return nil
        }
        // W184 G2 修正（GPT-6 4；查證 #5、#8）：Browser 自己的操作面板（網址卡與它的輸入框、切換空間選單、書籤／珍藏 sheet）開著＝
        // Esc 只收那一個（單欄、內橫都一樣），不收整個私訊框、也不給網頁。
        if DMBrowserPanelEscape.closePanel(in: window) { return nil }
        if store.isBrowsing { return event }   // W183 R5b／R8b：Browser 開著時 Esc 給網頁（手機式瀏覽器）；收框用 ⌥⌘（W184 F：⌄ 拿掉了）
        // W184 G3：ChatGPT 的思考強度面板開著先關面板。內橫右欄的也算。
        // W184 G3b 第二輪（審查 #7）：看得到的 ChatGPT 抽屜、＋／「/」小卡、思考強度面板排在「內橫右欄的網頁拿著鍵盤＝Esc 給網頁」前面——
        // 網頁拿著鍵盤、滑鼠指到左緣開了抽屜（焦點沒動）時，Esc 先收抽屜；組字、Browser 自己的面板、單欄 Browser 照舊在更前面。
        // 右欄是 Browser 時右欄那個 store 的看不到，不收。
        if store.dismissChatGPTLayers() { return nil }
        if !store.isBrowsingBeside, GlobalDMDuo.shared.existing?.dismissChatGPTLayers() == true { return nil }
        // W184 AB（H4 查核 #9）：輸入框「模式選擇」開的模式卡開著＝Esc 只收卡（框照舊開著）；再按一次才照原本的順序。內橫右欄（對話）的也算。
        // 組字中、語音、Browser 自己的面板、ChatGPT 的小卡照舊在前面。
        if store.isModeCardOpen { store.isModeCardOpen = false; return nil }
        if !store.isBrowsingBeside, let duo = GlobalDMDuo.shared.existing, duo.isModeCardOpen { duo.isModeCardOpen = false; return nil }
        // W184 AB：內橫右欄的網頁拿著鍵盤時 Esc 也給網頁；左欄（對話）照舊收框。
        if store.isBrowsingBeside, let responder = window.firstResponder as? NSView, GlobalDMNativePageMask.isInsideNativePage(responder) {
            return event
        }
        if store.isPickerOpen { store.isPickerOpen = false; return nil }
        if store.isEditingDirectKeys { store.isEditingDirectKeys = false; return nil }
        if window === floating { store.isFloatingOpen = false } else if store.isOpen { store.isOpen = false } else { return event }
        CoderSheetEscapeGuard.armForDM(after: event)
        return nil
    }

    // MARK: - 換形態（W184 AB）

    /// 現在看得到私訊框的那個面板（浮動框優先，其次停靠框）。
    private var boxPanel: GlobalDMPanel? {
        if store.isFloatingOpen, let floating, floating.isVisible { return floating }
        if store.isOpen, store.isDockedVisible, let docked, docked.isVisible { return docked }
        return nil
    }

    /// W184 F3：形態要改之前（GlobalDMDeskController.setForm 在改 desk.form 之前叫）：框看得到、沒在轉換、沒在拖＝先拍下舊的樣子
    /// （拍的那一刻暫時藏起配對碼與原生網頁，拍完還原）。applyForm 的第一段拿它蓋在新的圖上面淡掉。
    /// 不在 desk.form 的 willSet 裡拍：那時 SwiftUI 已經收到 objectWillChange，拍圖會逼它照舊值重畫、吃掉這次更新（新形態畫不出來）。
    func prepareForm() {
        pendingOld = nil
        if dockedMorph.isAnimating { dockedMorph.finish() }   // W184 AB：停靠的長、縮到一半換形態＝先到位（同 F45 浮動）
        guard hostsWindows, isInstalled, canvasPanel == nil, !formMotion.isAnimating, grip == nil, dragPanel == nil,
              let panel = boxPanel, panel.isVisible, let canvas = panel.contentView as? GlobalDMPanelCanvas,
              canvas.stage == nil, canvas.host.frame == canvas.bounds else { return }
        let began = CACurrentMediaTime()
        let margin = GlobalDMLayout.margin
        let box = NSRect(x: margin, y: margin, width: canvas.bounds.width - margin * 2, height: canvas.bounds.height - margin * 2)
        let surface = GlobalDMFormStage.surface(appearance: panel.effectiveAppearance, size: .zero)
        let before = canvas.host.layoutCount
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // W184 AB（.031 真機 Retina）：舊的樣子用 1x 拍——只顯示 0.1–0.4 秒、而且在動；Retina 上少四分之三的像素（按下去到開始動的大宗）。
        let capture = canvas.capture(desk.form, box: box, fill: surface.fill, label: "old \(desk.form.rawValue)", scale: 1)
        CATransaction.commit()
        lastPrepareLayouts = canvas.host.layoutCount - before
        lastPrepareCost = CACurrentMediaTime() - began
        if let capture { pendingOld = (ObjectIdentifier(panel), desk.form, capture, CACurrentMediaTime()) }
    }

    /// W184 F2：形態換了。框看得到＝滑（系統減少動態效果＝淡出、換框、淡入）：面板一次換成「現在的框∪新框」的畫布；
    /// 轉換中再換＝從現在滑到一半的位置直接轉向（畫布＝目前畫布∪新目標）。框看不到、直接換＝照新形態擺好。
    /// W184 F3：開始（換畫布的同一次畫面更新）真的內容照新形態、新大小只排一次版（對話本體 max(舊高, 新高)、貼底）、拍下來，
    /// 圖層台（GlobalDMFormStage）照模型的彈簧在畫面伺服器上動；動畫幾何不逐格觸發排版、主執行緒不逐格工作（只有一個停下的計時器）。
    func applyForm(_ transition: GlobalDMFormTransition) {
        guard hostsWindows, isInstalled else { return }
        // W184 F／G1（GPT-6 審查 #3）：拖、縮放進行中就先結束並存下目前的位置與大小（選「結束並存檔」：框停在使用者放的地方、
        // 從那裡滑到新形態；同一次按住的後續拖動、放開不再接）。不整理（整理會先照新形態擺，滑就沒有起點了）。
        if dockedMorph.isAnimating { dockedMorph.finish() }   // W184 AB：停靠的長、縮到一半換形態＝先到位
        endGrip()
        let margin = GlobalDMLayout.margin
        let old = pendingOld
        pendingOld = nil
        guard transition.style != .instant, dragPanel == nil, let panel = canvasPanel ?? boxPanel, panel.isVisible,
              let canvas = panel.contentView as? GlobalDMPanelCanvas, let target = placedBox(for: panel) else {
            formMotion.finish()
            reconcile()
            return
        }
        let began = CACurrentMediaTime()
        let turning = formMotion.plan != nil && canvas.stage != nil
        let resting = panel.frame.insetBy(dx: margin, dy: margin)
        let now = formMotion.current
        let box = now?.box ?? resting
        let area = (canvasFrame ?? panel.frame).union(box.insetBy(dx: -margin, dy: -margin)).union(target.insetBy(dx: -margin, dy: -margin))
        // 1. 拍之前先藏：遮蔽持有（原生網頁藏起來、佔位色）、「轉換進行中」（配對碼同步藏起來）。
        formMotion.hold(host: canvas)
        let surface = GlobalDMFormStage.surface(appearance: panel.effectiveAppearance, size: area.size)
        // 2. 舊的樣子（第一段）：形態改之前拍好的那一張；沒有（例如自測直接叫）就現在拍（這時 SwiftUI 還沒照新形態重排）。
        // 形態已經改了才叫 applyForm（沒先 prepareForm）＝沒有舊的圖（新的直接出來，不交叉淡換）：這時再拍會逼 SwiftUI 照新形態、舊大小重排。
        var previous: GlobalDMFormStage.Capture?
        if !turning, let old, old.panel == ObjectIdentifier(panel), old.form == transition.from, CACurrentMediaTime() - old.at < 1 {
            previous = old.capture
        }
        var trace: [String] = []
        func mark(_ label: String) {
            trace.append("\(label) \(String(format: "%.1f", (CACurrentMediaTime() - began) * 1000))ms L\(canvas.host.layoutCount)")
        }
        mark("hold")
        // 換畫布：面板換大小、真的框照新形態排一次版、拍、台蓋上去，都在同一次畫面更新（框在螢幕上一個像素都不跳）。
        panel.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasPanel = panel
        canvasFrame = area
        if panel === docked, canvasContent == nil { canvasContent = visibleMainWindow().map(mainContent(of:)) }
        formMotion.surface = panel === floating ? .floating : .docked
        // 3. 真的框：新形態、剛好是新框的大小排一次版（停下時不用再排：大小不變，停下那一格跟台上最後一格一樣）。先擺好真的框再換畫布
        //    （不然面板換大小時真的框會先照畫布的大小排一次）。原本捲到最底的列表排完照樣在最底（最新一則不被切掉）；捲上去看舊訊息的不動。
        //    框變矮時上面空出來的那一段由舊的圖墊著（GlobalDMFormStage：舊對話欄的圖留在新的底下）。
        //    W184 AB（R2；GPT-6 審 G3c #4）：捲上去看舊訊息的，守住使用者在讀的那一則（頂列底下看得到的第一則）的位置。
        let away = canvas.listsAwayFromBottom()
        let reading = canvas.readingRows(in: away)
        canvas.place(box: target, panelFrame: area, margin: margin)
        if panel.frame != area { panel.setFrame(area, display: false) }
        canvas.stage?.move(panelOrigin: area.origin, canvas: canvas.bounds)
        mark("canvas")
        canvas.host.layoutSubtreeIfNeeded()
        canvas.settleLists(away: away, reading: reading)
        mark("layout")
        // W184 AB（.031 真機：Retina 上按下去到開始動 251ms）：有舊的圖（第一段形態改之前拍好的、轉向時台上現有的）＝畫面先動、舊的圖
        // 跟著框走，新的樣子下一格才拍（scheduleFresh：拍的那一刻照樣走同一個安全的入口）。沒有舊的圖（形態改之前拍不了）＝照舊現在就拍
        //（不然第一格什麼都沒有）。
        let freshBox = NSRect(x: margin, y: margin, width: target.width, height: target.height)
        let deferFresh = turning || previous != nil
        if !turning { freshLog = [] }
        let syncStarted = CACurrentMediaTime()
        let captured = deferFresh ? nil : canvas.capture(transition.to, box: freshBox, fill: surface.fill, label: "new \(transition.to.rawValue)",
                                                         scale: canvas.freshScale(for: freshBox.size))
        mark("capture")
        if !deferFresh, captured == nil {
            freshLog.append(FreshRecord(segment: (canvas.stage?.segments ?? 0) + 1, outcome: .degraded, scale: canvas.freshScale(for: freshBox.size),
                                        deferred: false, startedAt: syncStarted, endedAt: CACurrentMediaTime()))
            // A1：拍不了（畫面上還有配對碼或原生頁）＝不做圖層轉場，直接切到真的框（新形態、新框）。
            canvasPanel = nil
            canvasFrame = nil
            canvasContent = nil
            panel.setFrame(target.insetBy(dx: -margin, dy: -margin), display: false)
            canvas.rest()
            canvas.layoutSubtreeIfNeeded()
            CATransaction.commit()
            panel.displayIfNeeded()
            skippedTransitions += 1
            formMotion.finish()
            reconcile()
            return
        }
        // 4. 模型：開始或轉向（t＝0 從這裡算：重的工作做完才開始，第一格就是起點）。
        formMotion.slide(from: GlobalDMSlideFrame.rest(transition.from, box: box), to: transition.to, target: target,
                         style: transition.style, host: canvas)
        // 5. 圖層台：第一段帶舊的圖；轉向＝台上現有的圖淡掉、新的放底下，彈簧從這一刻的位置與速度接著走。
        if let segment = formMotion.plan?.segments.last {
            let stage = canvas.stage ?? GlobalDMFormStage(canvas: canvas.bounds, panelOrigin: area.origin, base: area.origin, surface: surface,
                                                          start: formMotion.manualTime ? CACurrentMediaTime() : formMotion.startedAt,
                                                          manual: formMotion.manualTime)
            if canvas.stage == nil { canvas.present(stage) }
            stage.run(segment, old: previous)
            if let captured {
                let staged = stage.addFresh(captured, at: segment.start)
                freshLog.append(FreshRecord(segment: stage.segments, outcome: staged ? .staged : .stale, scale: captured.scale, deferred: false,
                                            startedAt: syncStarted, endedAt: CACurrentMediaTime()))
            }
            if formMotion.manualTime { stage.show(at: formMotion.elapsed) }
        }
        mark("stage")
        CATransaction.commit()
        panel.displayIfNeeded()
        mark("display")
        lastStartCost = CACurrentMediaTime() - began
        lastStartTrace = trace
        if deferFresh { scheduleFresh(panel, canvas: canvas, form: transition.to, box: freshBox, target: target, fill: surface.fill) }
    }

    /// W184 AB：新的樣子等第一格送出去之後才拍（一格的時間＋4ms；自測推時鐘＝下一輪）：拍的時候真的框是透明度 0（capture 裡暫時看得到、
    /// 同一次畫面更新還原），主執行緒忙這一下的時候畫面伺服器照樣在跑動畫。拍好交給圖層台（舊的圖從那一刻淡掉）；這期間轉向、停下、
    /// 收框＝這一次作廢（cancelFresh）。拍不了（畫面上還有配對碼或原生頁，A1）＝不做圖層轉場，直接切到真的框。
    /// 用 run loop 的計時器（common 模式），不用 DispatchQueue.main：主佇列正在跑一個工作時（例如 MainActor 的 Task 裡）巢狀的 run loop
    /// 不會輪到主佇列，計時器會。
    private struct PendingFresh {
        let token: Int
        weak var panel: GlobalDMPanel?
        weak var canvas: GlobalDMPanelCanvas?
        let form: GlobalDMForm
        let box: NSRect
        let target: NSRect
        let fill: CGColor
        let scheduled: CFTimeInterval
    }
    private var freshToken = 0
    private var pendingFresh: PendingFresh?
    private var freshTimer: Timer?
    private(set) var lastFreshCost: Double = 0
    private(set) var lastFreshDelay: Double = 0
    /// W184 AB（GPT-6 第三輪 #7）：新的樣子每一次怎麼了——嘗試（過了檢查、要拍）、拍成、上台（圖層台收下）、降級（拍不了＝直接換真的框）
    /// 分開記：這一段轉換（開始算起，轉向不重算）每一次一筆，帶第幾段、像素比例、開始拍與上台的時間。自測逐段斷言「拍成而且真的上台」。
    enum FreshOutcome: Equatable, Sendable {
        /// 拍成、圖層台收下了。
        case staged
        /// 拍成，但圖層台已經不等這一段（不該發生：轉向、停下會先作廢）。
        case stale
        /// 拍不了（A1：畫面上還有配對碼或原生頁）＝不做圖層轉場，直接切到真的框。
        case degraded
    }
    struct FreshRecord: Equatable, Sendable {
        let segment: Int
        let outcome: FreshOutcome
        let scale: CGFloat
        let deferred: Bool
        let startedAt: CFTimeInterval
        let endedAt: CFTimeInterval
    }
    private(set) var freshLog: [FreshRecord] = []
    private(set) var freshAttempts = 0
    private(set) var lastFreshScale: CGFloat = 0

    private func scheduleFresh(_ panel: GlobalDMPanel, canvas: GlobalDMPanelCanvas, form: GlobalDMForm, box: NSRect, target: NSRect,
                               fill: CGColor) {
        cancelFresh()
        let token = freshToken
        pendingFresh = PendingFresh(token: token, panel: panel, canvas: canvas, form: form, box: box, target: target, fill: fill,
                                    scheduled: CACurrentMediaTime())
        let fps = Double(max(30, panel.screen?.maximumFramesPerSecond ?? 60))
        let timer = Timer(timeInterval: formMotion.manualTime ? 0 : 1 / fps + 0.004, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runFresh(token) }
        }
        RunLoop.main.add(timer, forMode: .common)
        freshTimer = timer
    }

    /// 還沒拍的新樣子作廢（轉向重排、停下、收框、中止）。
    private func cancelFresh() {
        freshToken &+= 1
        pendingFresh = nil
        freshTimer?.invalidate()
        freshTimer = nil
    }

    private func runFresh(_ token: Int) {
        guard let pending = pendingFresh, pending.token == token, token == freshToken else { return }
        pendingFresh = nil
        freshTimer = nil
        guard let panel = pending.panel, let canvas = pending.canvas, canvasPanel === panel, let stage = canvas.stage, stage.awaitingFresh,
              formMotion.isAnimating else { return }
        lastFreshDelay = CACurrentMediaTime() - pending.scheduled
        freshAttempts += 1
        let scale = canvas.freshScale(for: pending.box.size)
        lastFreshScale = scale
        let started = CACurrentMediaTime()
        let segment = stage.segments
        panel.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let captured = canvas.capture(pending.form, box: pending.box, fill: pending.fill, label: "new \(pending.form.rawValue)",
                                      scale: canvas.freshScale(for: pending.box.size))
        if let captured {
            let staged = stage.addFresh(captured, at: formMotion.elapsed)
            if formMotion.manualTime { stage.show(at: formMotion.elapsed) }
            freshLog.append(FreshRecord(segment: segment, outcome: staged ? .staged : .stale, scale: scale, deferred: true,
                                        startedAt: started, endedAt: CACurrentMediaTime()))
        } else {
            freshLog.append(FreshRecord(segment: segment, outcome: .degraded, scale: scale, deferred: true,
                                        startedAt: started, endedAt: CACurrentMediaTime()))
            // A1：拍不了＝不做圖層轉場，直接切到真的框（新形態、新框）。
            let margin = GlobalDMLayout.margin
            canvasPanel = nil
            canvasFrame = nil
            canvasContent = nil
            panel.setFrame(pending.target.insetBy(dx: -margin, dy: -margin), display: false)
            canvas.rest()
            canvas.layoutSubtreeIfNeeded()
        }
        CATransaction.commit()
        lastFreshCost = CACurrentMediaTime() - started
        if captured == nil {
            skippedTransitions += 1
            formMotion.finish()
            reconcile()
        }
    }

    /// 自測推時鐘：台停在這一格。
    private func showStage(at elapsed: Double) {
        (canvasPanel?.contentView as? GlobalDMPanelCanvas)?.stage?.show(at: elapsed)
    }

    /// 停下那一格（W184 F3：動畫期間不再逐格叫）：面板換回剛好是新框（＋陰影邊）、真的框填滿面板排回新框高（貼底：看得到的部分
    /// 跟台上最後一格一樣）、拿掉圖層台，同一次畫面更新；再照平常的算法整理一次。
    private func slideFrame(_ frame: GlobalDMSlideFrame, finished: Bool) {
        guard finished, let panel = canvasPanel, let canvas = panel.contentView as? GlobalDMPanelCanvas else {
            if finished {
                canvasPanel = nil
                canvasFrame = nil
            }
            return
        }
        let began = CACurrentMediaTime()
        let margin = GlobalDMLayout.margin
        cancelFresh()   // 還沒拍的新樣子作廢（停下＝真的框換回來）
        panel.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasPanel = nil
        canvasFrame = nil
        canvasContent = nil
        let settled = frame.box.insetBy(dx: -margin, dy: -margin)
        if panel.frame != settled { panel.setFrame(settled, display: false) }
        let layoutsBefore = canvas.host.layoutCount
        canvas.rest()
        canvas.layoutSubtreeIfNeeded()
        let laidOut = canvas.host.layoutCount
        CATransaction.commit()
        panel.displayIfNeeded()
        lastStopLayouts = canvas.host.layoutCount - layoutsBefore
        lastStopCost = CACurrentMediaTime() - began
        lastStopTrace = "layout \(String(format: "%.1f", (CACurrentMediaTime() - began) * 1000))ms L\(laidOut)→L\(canvas.host.layoutCount)"
        reconcile()
    }

    /// 轉換中框被收起（或停靠框的主視窗移動、改大小）：畫布還原（框填滿面板、圖層台拆掉；接著照平常擺）、轉換直接停在終點（遮蔽放掉），
    /// 不在這裡再整理一次（呼叫的地方自己接著擺或收）。W184 F／G1（查證 #5）：排隊的入口不在收框的路徑裡同步做（finish(notify: false)：
    /// 下一輪 run loop 才做），收框走完之前不會有巢狀的整理把剛收的框又打開。
    private func abortCanvas() {
        guard let panel = canvasPanel else { return }
        cancelFresh()
        canvasPanel = nil
        canvasFrame = nil
        canvasContent = nil
        (panel.contentView as? GlobalDMPanelCanvas)?.rest()
        formMotion.finish(notify: false)
    }

    /// 這個面板照目前形態該在的框（螢幕座標、不含陰影邊）：跟平常擺的算法一樣，只算不擺。
    private func placedBox(for panel: GlobalDMPanel) -> NSRect? {
        let margin = GlobalDMLayout.margin
        if panel === floating { return floatingFrame(screen: panel.screen).insetBy(dx: margin, dy: margin) }
        if panel === docked, let window = visibleMainWindow() { return dockedBox(dockedPlacement(in: window)) }
        return nil
    }

    /// 自測看：現在看得到私訊框的那個面板、它照目前形態該在的位置（面板大小＝框＋陰影邊）。
    var boxPanelForTesting: GlobalDMPanel? { canvasPanel ?? boxPanel }
    func placedPanelFrameForTesting() -> NSRect? {
        guard let panel = canvasPanel ?? boxPanel else { return nil }
        return placedBox(for: panel)?.insetBy(dx: -GlobalDMLayout.margin, dy: -GlobalDMLayout.margin)
    }
    /// 自測看：停靠框、浮動框的面板（不管開沒開）；拖、縮放還在進行嗎；停靠框的輸入框（量到的或估計的）與能拖的範圍。
    var dockedPanelForTesting: GlobalDMPanel? { docked }
    /// 自測看：停靠的圓鈕面板（主視窗右下那顆）；照現在的主視窗它該在哪（面板大小＝圓鈕＋陰影邊）。
    var dockedButtonForTesting: GlobalDMPanel? { dockedButton }
    func dockedButtonPlacementForTesting() -> NSRect? {
        visibleMainWindow().map { dockedPlacement(in: $0).placement.button.insetBy(dx: -GlobalDMLayout.margin, dy: -GlobalDMLayout.margin) }
    }
    var floatingPanelForTesting: GlobalDMPanel? { floating }
    var isGrippingForTesting: Bool { grip != nil || dragPanel != nil }
    func dockedGeometryForTesting() -> GlobalDMPlacementGeometry? {
        visibleMainWindow().flatMap { dockedGeometry(dockedPlacement(in: $0)) }
    }

    // MARK: - 視窗

    private func visibleMainWindow() -> NSWindow? {
        guard hostsWindows, !NSApp.isHidden else { return nil }
        return NSApp.windows.first { window in
            window is TatwoWorkOSWindow && window !== closingWindow && window.isVisible && !window.isMiniaturized
        }
    }

    /// 只給 ⌥⌘ 判斷用：主視窗真的在使用者眼前——在目前的桌面、沒有被整個蓋住（例如網頁影片全螢幕的舞台視窗）。
    /// isVisible 在別的桌面或被蓋住時仍是 true。停靠框的掛上／拿下照舊看 visibleMainWindow，部分被蓋住時圓鈕才不會閃。
    private func mainWindowOnScreenForUser() -> NSWindow? {
        guard let window = visibleMainWindow(), window.isOnActiveSpace,
              window.occlusionState.contains(.visible) else { return nil }
        return window
    }

    /// W179 UI：主視窗這一刻有沒有東西整頁蓋上來（SwiftUI 回報的蓋層、sheet、App 層級確認框；私訊框自己不算；
    /// 有工具在等核准時的確認框就是核准框，不算）。
    private func mainCover(for window: NSWindow) -> GlobalDMMainCover {
        GlobalDMMainCover(overlays: GlobalDMCoverRegistry.shared.overlays,
                          sheet: sheetStarting || window.attachedSheet != nil,
                          appModal: NSApp.modalWindow.map { !($0 is GlobalDMPanel) } ?? false,
                          approvalPending: !(store.model?.localLiveForBridge?.pendingPermissionThreadIDs.isEmpty ?? true))
    }

    /// 蓋著時 ⌥⌘、直達鍵開的是螢幕右下的浮動框（停靠框這時收著）。
    private var mainWindowCovered: Bool {
        visibleMainWindow().map { mainCover(for: $0).isCovered } ?? false
    }

    func reconcile() {
        guard hostsWindows, isInstalled else { return }
        // W184 G1b 第二輪（GPT-6 G1b 審查 #1）：浮動框拖到一半換了模式（縮成圓鈕／恢復主視窗）＝這次拖曳照開始那一份結束並存下
        //（不改寫另一份），接著照新模式整理。
        if let drag, drag.surface == .floating, (drag.key == .bubble) != (floatingAnchor?() != nil) { finishDrag("mode") }
        // W184 F／G1（GPT-6 審查 #4）：停靠框換形態途中主視窗移動、改大小（內容區換了位置）或不見了＝轉換直接停在終點
        // （遮蔽放掉、畫布還原；停下會叫 onIdle，排隊的請求可能先整理一次），這一輪再照最新的狀態、平常的算法重擺——
        // 不讓畫布拿開始時的螢幕座標繼續擺。
        if let canvasPanel, canvasPanel === docked, let started = canvasContent,
           visibleMainWindow().map(mainContent(of:)) != started {
            abortCanvas()
        }
        // W184 AB（GPT-6 第三輪 #1–#3）：停靠的長、縮、淡出途中主視窗移動、改大小、換螢幕、全螢幕（或不見了）＝外殼直接到位
        //（淡出中＝這一次收框算完成：這一輪接著收掉框），再照新的主視窗擺圓鈕與框。
        if dockedMorph.isAnimating, let started = dockedMorphContent, visibleMainWindow().map(mainContent(of:)) != started {
            dockedMorph.finish(notify: false)
        }
        let window = visibleMainWindow()
        let cover = window.map(mainCover(for:)) ?? GlobalDMMainCover()
        lastAppModal = NSApp.modalWindow != nil
        let presence = GlobalDMDockedPresence.resolve(enabled: store.isEnabled, mainWindowVisible: window != nil,
                                                      covered: cover.isCovered, boxOpen: store.isOpen)
        if let window, case .shown = presence {
            attachDocked(to: window, from: dockedPresence, to: presence)
        } else {
            detachDocked()
        }
        dockedPresence = presence
        watchModalEnd(cover.appModal)
        closingWindow = nil
        let floatingJustOpened = store.isFloatingOpen && !floatingWasOpen
        floatingWasOpen = store.isFloatingOpen
        if store.isEnabled, store.isFloatingOpen { showFloating(focus: floatingJustOpened) } else { hideFloating() }
    }

    /// App 層級確認框開著時掛一個計時器，發現關了就整理一次；確認框不在時停掉。
    private func watchModalEnd(_ modal: Bool) {
        guard modal else {
            modalWatch?.invalidate()
            modalWatch = nil
            return
        }
        guard modalWatch == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.modalWindow == nil else { return }
                self.reconcile()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modalWatch = timer
    }

    private func makePanel(kind: GlobalDMPanelKind) -> GlobalDMPanel {
        let panel = GlobalDMPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        // 工具核准是 App 層級的確認框（runModal），期間 AppKit 只把事件送給 worksWhenModal 的視窗；
        // 私訊框的「等你核准」那一行就在這時出現，所以要能點。
        panel.worksWhenModal = true
        panel.title = "私訊" // 無邊框看不到；給輔助使用與自動化辨識
        switch kind {
        case .floating:
            panel.becomesKeyOnlyIfNeeded = false
            // ⌘H／「隱藏其他」不收它：在隱藏中的 App 按 ⌥⌘ 也要看得到、能打字。
            panel.canHide = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.setAccessibilityIdentifier("tatwo.dm.floatingPanel")
            panel.contentView = GlobalDMPanelCanvas(host: GlobalDMHostingView.make(
                GlobalDMFloatingRoot(store: store, desk: desk, morph: buttonMorph)
                    .environment(\.globalDMBrowserServices, browserServices)))
        case .dockedButton:
            panel.becomesKeyOnlyIfNeeded = true
            panel.setAccessibilityIdentifier("tatwo.dm.panel")
            panel.contentView = GlobalDMHostingView.make(GlobalDMDockedButtonRoot(store: store))
        case .dockedBox:
            panel.becomesKeyOnlyIfNeeded = true
            panel.setAccessibilityIdentifier("tatwo.dm.boxPanel")
            panel.contentView = GlobalDMPanelCanvas(host: GlobalDMHostingView.make(
                GlobalDMDockedBoxRoot(store: store, desk: desk, morph: dockedMorph)
                    .environment(\.globalDMBrowserServices, browserServices)))
        }
        return panel
    }

    /// W179 UI：圓鈕與框各一個子面板。框的下緣在主視窗輸入框上緣之上、右緣對齊圓鈕（`GlobalDMDockLayout`）；
    /// 圓鈕一直在框上面，框的陰影邊蓋不到它。
    /// 停靠框、圓鈕照主視窗的內容區與輸入框該在哪（只算不擺；W184 F2 換形態時也用它算新框）。
    /// composer＝輸入框（量到的；量不到用估計值——拖過、縮放過的框照它避開輸入框，跟預設擺法同一條）。
    private func dockedPlacement(in window: NSWindow) -> GlobalDMDockedPlaced {
        let content = mainContent(of: window)
        // 輸入框位置：先用 AppKit 當下量（不受 SwiftUI 啟動時序影響），量不到才用 SwiftUI 回報的；都沒有時框照估計擺。
        let source = GlobalDMComposerSource.forMode(store.model?.mode)
        let probed = source != nil ? GlobalDMComposerProbe.card(in: window, content: content) : nil
        let composer = probed ?? source.flatMap { composerFrameOnScreen($0, in: window) }
        let placement = GlobalDMDockLayout.place(content: content, composer: composer, mode: store.model?.mode, boxOpen: store.isOpen,
                                                 boxSize: desk.form.size)   // W184 AB：停靠框也照目前形態
        return GlobalDMDockedPlaced(content: content, probed: probed, source: source, placement: placement,
                                    composer: composer ?? GlobalDMDockLayout.estimatedComposer(content: content, mode: store.model?.mode))
    }

    /// 主視窗內容區的螢幕位置。
    private func mainContent(of window: NSWindow) -> NSRect {
        window.contentView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? window.frame
    }

    private func attachDocked(to window: NSWindow, from old: GlobalDMDockedPresence, to new: GlobalDMDockedPresence) {
        let placed = dockedPlacement(in: window)
        let (content, probed, source, placement) = (placed.content, placed.probed, placed.source, placed.placement)
        GlobalDMLayoutLog.note("dock mode=\(String(describing: store.model?.mode)) content=\(content) probed=\(String(describing: probed)) reportedScreen=\(String(describing: source.flatMap { composerFrameOnScreen($0, in: window) })) reported=\(GlobalDMComposerFrames.shared.frames.keys.map { "\($0)" }.sorted()) host=\(String(describing: window.contentView.map { "\(type(of: $0)) flipped=\($0.isFlipped) h=\($0.bounds.height)" })) box=\(String(describing: placement.box))")
        let margin = GlobalDMLayout.margin
        let button = dockedButton ?? makePanel(kind: .dockedButton)
        dockedButton = button
        let buttonFrame = placement.button.insetBy(dx: -margin, dy: -margin)
        if let box = dockedBox(placed) {
            // W184 AB（使用者 09-30：停靠時圓鈕跟框同時存在）：框開著時圓鈕不出現。圓鈕的位置照樣擺好（長、縮的起點與終點照它）；
            // 剛打開＝從圓鈕長成框（dockedMorph 自己在外殼的第一格送出去之後才藏圓鈕：同一個位置換手）。
            if button.frame != buttonFrame { button.setFrame(buttonFrame, display: false) }
            let panel = docked ?? makePanel(kind: .dockedBox)
            docked = panel
            dockedMorph.prepare(panel)   // 要出現＝內容先藏著（第一格透明）；收起的淡出途中又打開＝內容淡回來
            attach(panel, to: window, frame: box.insetBy(dx: -margin, dy: -margin))
            dockedMorph.presented(panel)   // 剛出現＝圓鈕長成框（圓鈕藏起、外殼長過去、內容後段淡入）
            if !dockedMorph.holdsBubble { hideDockedButton(button) }
        } else {
            detachBox(from: window)
            if dockedMorph.holdsBubble {
                // 收起的淡出、縮回途中：圓鈕等外殼到位才由 dockedMorph 放回來（位置照樣更新）。
                if button.frame != buttonFrame { button.setFrame(buttonFrame, display: false) }
            } else {
                attach(button, to: window, frame: buttonFrame)
            }
        }
        if !store.isDockedVisible { store.isDockedVisible = true }
        if GlobalDMDockedPresence.takesFocus(from: old, to: new) { docked?.makeKey() }
    }

    private func attach(_ panel: GlobalDMPanel, to window: NSWindow, frame: NSRect) {
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        // W184 F2：轉換中的面板是畫布，大小照畫布（停下時換回剛好是新框）；W184 G1b：拖著、縮放中的也不動。
        if !isHeld(panel), panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFront(nil) }
        refreshBrowserPlacement()   // 頁面先掛好、視窗再顯示：配對碼依真實可見狀態重算，盾先持有再重畫。
    }

    private func refreshBrowserPlacement() {
        if let browser = browserServices.browser { browser.containerMoved() }
        else if store.isBrowsing || store.isBrowsingBeside { DMBrowser.shared.containerMoved() }
    }

    /// 收起框：它有鍵盤焦點又是本 App 在前景時交還主視窗；別的 App 在前景時（不啟用本 App 的面板）
    /// 收起後焦點自然回到那個 App。
    private func detachBox(from window: NSWindow?, animated: Bool = true) {
        guard let panel = docked, panel.parent != nil || panel.isVisible else { return }
        endGestures(.docked, reason: "hidden")   // W184 F／G1（GPT-6 審查 #3）、G1b 第二輪（G1b 審查 #1）：拖、縮放中收起＝照開始那一份結束並存下（之後的放開不再接）；W184 AB：收的那一刻就結束（內容淡出那 0.1 秒不再接拖動）
        // W184 AB：收框＝內容先淡出（dockedMorph 淡完叫整理才收）；主視窗不見了這種收法（animated＝false）＝外殼直接拆掉、不縮。
        if animated {
            guard !dockedMorph.isClearing(panel) else { return }
            dockedMorph.dismiss(panel)   // 收的那一刻沒接到的在這裡接（縮回圓鈕）
        } else {
            dockedMorph.cancel()
        }
        if panel === canvasPanel { abortCanvas() }   // W184 F2：轉換中收起＝轉換直接停下（不在收起途中再整理一次）
        let hadKey = panel.isKeyWindow
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if hadKey, NSApp.isActive, let window { window.makeKey() }
        dockedMorph.hidden(panel)   // W184 AB：淡出過的內容等框收掉才還原透明度
        settleHidden(panel)
    }

    /// 輸入框回報的 SwiftUI global 位置換成螢幕座標。
    private func composerFrameOnScreen(_ source: GlobalDMComposerSource, in window: NSWindow) -> NSRect? {
        guard let global = GlobalDMComposerFrames.shared.frames[source], let host = window.contentView else { return nil }
        let local = GlobalDMComposerFrames.windowRect(global: global, hostHeight: host.bounds.height,
                                                      hostIsFlipped: host.isFlipped)
        return window.convertToScreen(host.convert(local, to: nil))
    }

    private func detachDocked() {
        if store.isDockedVisible { store.isDockedVisible = false }
        dockedMorph.cancel()   // W184 AB：主視窗不見了（縮到 Dock、隱藏、關掉、蓋層）＝長、縮直接停，外殼拆掉
        detachBox(from: docked?.parent, animated: false)
        if let dockedButton { hideDockedButton(dockedButton) }
    }

    // MARK: 停靠的圓鈕 ↔ 停靠框（W184 AB）

    /// 停靠框的長、縮接上：圓鈕＝主視窗右下那顆（停靠顯示中才有）、要不要放回＝停靠顯示中而且框收著；點外殼＝點圓鈕；
    /// 外殼跟主視窗同一層、擺在停靠框（或主視窗）的正上方；圓鈕照子視窗的方式藏、放回；收起接在 store 改值的那一刻（不 receive(on:)）。
    private func wireDockedMorph() {
        let morph = dockedMorph
        morph.bubble = { [weak self] in
            guard let self, self.dockedShown else { return nil }
            return self.dockedButton
        }
        morph.bubbleWanted = { [weak self] in
            guard let self else { return false }
            return self.dockedShown && !self.store.isOpen
        }
        morph.onClick = { [weak self] in
            guard let self, self.store.isEnabled else { return }
            self.store.toggleDocked()
        }
        morph.onCleared = { [weak self] in self?.reconcile() }
        morph.shellLevel = .normal
        morph.anchor = { [weak self] in
            guard let self else { return nil }
            if let docked = self.docked, docked.isVisible { return docked }
            return self.visibleMainWindow()
        }
        morph.hideBubble = { [weak self] window in self?.hideDockedButton(window) }
        morph.showBubble = { [weak self] window in self?.showDockedButton(window) }
        morph.joinsAllSpaces = false   // 第三輪 #4：外殼、點擊區只在主視窗那個桌面
        // 開始那一刻記下主視窗內容區（途中變了就直接到位）；停下就清掉。
        morph.$phase
            .sink { [weak self] phase in
                guard let self else { return }
                if phase == .idle {
                    self.dockedMorphContent = nil
                } else if self.dockedMorphContent == nil {
                    self.dockedMorphContent = self.visibleMainWindow().map(self.mainContent(of:))
                }
            }
            .store(in: &cancellables)
        // 第三輪 #4：切到別的桌面（主視窗離開目前的桌面）＝長、縮直接到位，外殼與點擊區拆掉。
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dockedMorph.isAnimating else { return }
                self.dockedMorph.finish(notify: false)
                self.reconcile()
            }
        })
        // @Published 在改值之前發佈：送來 false、現在還是 true＝剛要收起。
        store.$isOpen
            .sink { [weak self] open in
                guard let self, !open, self.store.isOpen else { return }
                self.dockedMorph.closing()
            }
            .store(in: &cancellables)
        // 換手（停靠框收起、同一下浮動框打開，或反過來）：收起那一邊不淡出——框裡的頁面與配對碼搬到另一個框去了，淡出中的那一份
        // 會在頁面不在的框裡照樣畫著配對碼（S5B：碼只准跟它的配對頁一起在畫面上）。收起的淡出直接算完成（同一輪就拿掉內容）。
        store.$isFloatingOpen
            .sink { [weak self] open in
                guard let self, open, !self.store.isFloatingOpen, self.dockedMorph.phase == .clearing else { return }
                self.dockedMorph.finish(notify: false)
            }
            .store(in: &cancellables)
        store.$isOpen
            .sink { [weak self] open in
                guard let self, open, !self.store.isOpen, self.buttonMorph.phase == .clearing else { return }
                self.buttonMorph.finish(notify: false)
            }
            .store(in: &cancellables)
    }

    /// 停靠的圓鈕與框現在是不是掛在主視窗上（不管框開沒開）。
    private var dockedShown: Bool {
        if case .shown = dockedPresence { return true }
        return false
    }

    /// 停靠的圓鈕藏起來（子視窗：先從主視窗拆下來再收）。
    private func hideDockedButton(_ window: NSWindow) {
        window.parent?.removeChildWindow(window)
        if window.isVisible { window.orderOut(nil) }
    }

    /// 停靠的圓鈕放回來（照舊掛回主視窗、在最上面）。
    /// W184 AB（GPT-6 第三輪 #2）：位置照「現在」的主視窗重算（縮回途中主視窗可能已經移動；圓鈕那時是拆下來的，不會跟著走）。
    private func showDockedButton(_ window: NSWindow) {
        guard let panel = window as? GlobalDMPanel, let main = visibleMainWindow() else { return }
        let frame = dockedPlacement(in: main).placement.button.insetBy(dx: -GlobalDMLayout.margin, dy: -GlobalDMLayout.margin)
        attach(panel, to: main, frame: frame)
    }

    /// 只有剛叫出來（`focus`）時拿鍵盤焦點；隱藏、取消隱藏、回到前景、換螢幕這些被動整理只確保看得到，不搶焦點。
    /// W179 E：大小照目前形態（W184 AB；放不下就等比縮小），換形態或拖圓鈕時跟著調整。
    private func showFloating(focus: Bool) {
        let panel = floating ?? makePanel(kind: .floating)
        floating = panel
        buttonMorph.prepare(panel)   // W184 F45：要出現、而且是圓鈕模式＝內容先藏著（第一格透明）
        let frame = floatingFrame(screen: panel.isVisible ? panel.screen : nil)
        if !isHeld(panel), panel.frame != frame { panel.setFrame(frame, display: true) }   // W184 F2：轉換中照畫布；G1b：拖著、縮放中不動
        if !panel.isVisible { panel.orderFrontRegardless() }
        refreshBrowserPlacement()
        if focus { panel.makeKey() }
        buttonMorph.presented(panel)   // W184 F45：剛出現＝圓鈕長成框（圓鈕藏起、外殼長過去、內容後段淡入）
    }

    /// 縮成桌面圓鈕時開在圓鈕旁；否則在滑鼠所在螢幕的右下角（內縮 24），已經開著就留在原本那個螢幕。
    /// W184 G1：使用者拖過、縮放過就照記住的位置與大小；W184 G1b：縮成圓鈕時另存一份（相對於圓鈕：拖過就留在放的地方、跟著圓鈕走；
    /// 蓋到圓鈕就讓開一點）；範圍的唯一限制＝頂列至少 44pt 在螢幕裡。
    private func floatingFrame(screen current: NSScreen?) -> NSRect {
        let box: NSRect
        if let bubble = floatingAnchor?() {
            let geometry = bubbleGeometry(bubble)
            let placement = desk.bubblePlacement
            box = placement.isStandard ? geometry.standard
                : GlobalDMBoxPlacement.clearing(userBox(placement, geometry), bubble: bubble, in: geometry.bounds, fallback: geometry.standard)
        } else {
            box = userBox(desk.placement(.floating), floatingPlacementGeometry(screen: current))
        }
        return box.insetBy(dx: -GlobalDMLayout.margin, dy: -GlobalDMLayout.margin)
    }

    /// W184 G1b：圓鈕模式擺放用的範圍：預設的框＝開在圓鈕旁（boxBeside，不蓋圓鈕）、參考＝圓鈕（位置相對於它：跟著圓鈕走）、
    /// 範圍＝圓鈕所在螢幕的 visibleFrame。
    private func bubbleGeometry(_ bubble: NSRect) -> GlobalDMPlacementGeometry {
        let visible = bubbleVisible(for: bubble)
        return GlobalDMPlacementGeometry(standard: GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: desk.form.size, visible: visible),
                                         reference: bubble, bounds: visible, composer: nil)
    }

    /// 圓鈕所在螢幕的可用範圍（W184 G1b：面板不再被系統往選單列下推——GlobalDMPanel.constrainFrameRect——所以不用扣陰影邊）。
    private func bubbleVisible(for bubble: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: bubble.midX, y: bubble.midY)) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// 浮動框預設的框（不含陰影邊）與那個螢幕的 visibleFrame：縮成圓鈕時開在圓鈕旁；否則在滑鼠所在螢幕的右下角（內縮 24），
    /// 已經開著就留在原本那個螢幕。
    private func floatingGeometry(screen current: NSScreen?) -> (standard: NSRect, visible: NSRect) {
        let wanted = desk.form.size
        if let bubble = floatingAnchor?() {
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: bubble.midX, y: bubble.midY)) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            return (GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: wanted, visible: visible), visible)
        }
        let mouse = NSEvent.mouseLocation
        let screen = current ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = GlobalDMDeskLayout.fitted(wanted, in: visible)
        let box = NSRect(x: visible.maxX - GlobalDMLayout.floatingInset - size.width, y: visible.minY + GlobalDMLayout.floatingInset,
                         width: size.width, height: size.height)
        return (box, visible)
    }

    /// 浮動框擺放用的範圍：預設的框、參考範圍都是那個螢幕的 visibleFrame；沒有輸入框要避。W184 G1b：整個 visibleFrame 都能放
    /// （面板不再被系統往選單列下推：GlobalDMPanel.constrainFrameRect），唯一限制＝頂列至少 44pt 在範圍裡。
    private func floatingPlacementGeometry(screen current: NSScreen?) -> GlobalDMPlacementGeometry {
        let (standard, visible) = floatingGeometry(screen: current)
        return GlobalDMPlacementGeometry(standard: standard, reference: visible, bounds: visible, composer: nil)
    }

    /// 停靠框擺放用的範圍：預設的框（GlobalDMDockLayout：照舊避開輸入框）、參考範圍＝主視窗內容區。W184 G1b（使用者：「範圍太小，拖不到想放的地方」）：
    /// 使用者自己放的＝主視窗整個內容區都可以（可以蓋到輸入框：自己放的就尊重），唯一限制＝頂列至少 44pt 在內容區裡。
    private func dockedGeometry(_ placed: GlobalDMDockedPlaced) -> GlobalDMPlacementGeometry? {
        guard let standard = placed.placement.box else { return nil }
        return GlobalDMPlacementGeometry(standard: standard, reference: placed.content, bounds: placed.content, composer: placed.composer)
    }

    /// 停靠框：照預設的擺法（GlobalDMDockLayout）算出預設的框，再照使用者的位置與大小擺（夾回能拖的範圍、避開輸入框）。
    private func dockedBox(_ placed: GlobalDMDockedPlaced) -> NSRect? {
        guard let geometry = dockedGeometry(placed) else { return nil }
        return userBox(desk.placement(.docked), geometry)
    }

    /// 照使用者的位置與大小擺框（放開之後的整理、換形態的終點都走這一條，不會一邊一個樣）：沒拖過、沒縮放過＝跟改之前一模一樣
    /// （預設的擺法本來就避開輸入框）；拖過、縮放過＝照記住的位置與大小，頂列至少 44pt 在範圍裡（W184 G1b：不再避開輸入框、不整個推回範圍裡）。
    private func userBox(_ placement: GlobalDMBoxPlacement, _ geometry: GlobalDMPlacementGeometry) -> NSRect {
        placement.box(standard: geometry.standard, reference: geometry.reference, bounds: geometry.bounds)
    }

    // MARK: - 拖、縮放（W184 G1、G1b）

    /// W184 G1b（使用者：「拖的時候卡、跟不上滑鼠」）：頂列按下去＝系統原生的視窗拖曳。視窗伺服器帶著面板走：拖的途中 App 不排版、
    /// 不逐事件改面板大小；放開才算位置、存下來（頂列不到 44pt 在範圍裡才用短動畫推回）。停靠框照樣是主視窗的子面板
    /// （子面板自己拖、主視窗不跟著動）。縮成桌面圓鈕時也能拖：另存一份相對於圓鈕的位置。
    /// 自測換：原生拖曳那一下（正式＝performDrag，放開滑鼠才回來）、滑鼠左鍵還按著嗎。
    static var windowDrag: @MainActor (NSWindow, NSEvent) -> Void = { window, event in window.performDrag(with: event) }
    static var mouseIsDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    func beginWindowDrag(_ surface: GlobalDMSurface, event: NSEvent) {
        guard hostsWindows, isInstalled, canvasPanel == nil, !formMotion.isAnimating, drag == nil, grip == nil,
              let panel = surface == .floating ? floating : docked, panel.isVisible else { return }
        let box = panel.frame.insetBy(dx: GlobalDMLayout.margin, dy: GlobalDMLayout.margin)
        // 存到哪一份、幾何參考：按下這一刻就定（GPT-6 G1b 審查 #1）。
        if surface == .floating, let bubble = floatingAnchor?() {
            drag = GlobalDMDragContext(panel: panel, surface: surface, key: .bubble, placement: desk.bubblePlacement,
                                       geometry: bubbleGeometry(bubble), bubble: bubble)
        } else if surface == .docked {
            guard let geometry = placementGeometry(for: panel, box: box) else { return }
            drag = GlobalDMDragContext(panel: panel, surface: surface, key: .docked, placement: desk.placement(.docked),
                                       geometry: geometry, bubble: nil)
        } else {
            drag = GlobalDMDragContext(panel: panel, surface: surface, key: .floating, placement: desk.placement(.floating),
                                       geometry: nil, bubble: nil)
        }
        panel.isMovable = true
        Self.windowDrag(panel, event)
        finishDragWhenReleased()
    }

    /// performDrag 放開滑鼠才回來；萬一它先回來（滑鼠還按著），每一格看一次滑鼠，放開才收尾。途中已經收尾（收框、換模式）＝什麼都不做。
    private func finishDragWhenReleased() {
        guard drag != nil else { return }
        guard Self.mouseIsDown() else { return finishDrag() }
        dragTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !Self.mouseIsDown() else { return }
                self.finishDrag()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    /// 放開（reason＝release）：照開始那一刻定好的那一份算位置、存下來；頂列不到 44pt 在範圍裡（或圓鈕模式蓋到圓鈕）才用短動畫推回，
    /// 再整理一次。途中收框、換模式（reason＝hidden／mode）：照同一份存下框那一刻的位置、放掉這次拖曳（之後的放開什麼都不做），
    /// 不推回、不在這裡整理（呼叫的地方正在收框或整理）。
    private func finishDrag(_ reason: String = "release") {
        dragTimer?.invalidate()
        dragTimer = nil
        guard let context = drag else { return }
        drag = nil
        let panel = context.panel
        panel.isMovable = false
        let margin = GlobalDMLayout.margin
        let box = panel.frame.insetBy(dx: margin, dy: margin)
        var landed = box
        var placement = context.placement
        switch context.key {
        case .bubble:
            if let bubble = context.bubble, let geometry = context.geometry {
                landed = GlobalDMBoxPlacement.clearing(box, bubble: bubble, in: geometry.bounds, fallback: geometry.standard)
                placement.offset = GlobalDMBoxPlacement.offset(of: landed, reference: bubble)
                desk.saveBubblePlacement(placement)
            }
        case .docked:
            if let geometry = context.geometry {
                landed = GlobalDMBoxPlacement.keepGrabbable(box, in: geometry.bounds)
                placement.offset = GlobalDMBoxPlacement.offset(of: landed, reference: geometry.reference)
                desk.savePlacement(placement, for: .docked)
            }
        case .floating:
            // 浮動框照放的地方那個螢幕（頂列在哪個螢幕）的 visibleFrame：拖到別的螢幕就用那個螢幕（不看現在是不是圓鈕模式）。
            // 整個拖出螢幕外（頂列不在任何螢幕上、面板也不在）＝照滑鼠所在的螢幕、再不行主螢幕（跟平常擺浮動框同一條）。
            let top = NSPoint(x: box.midX, y: box.maxY - GlobalDMBoxPlacement.grabbable / 2)
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(top) } ?? panel.screen
                ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            landed = GlobalDMBoxPlacement.keepGrabbable(box, in: visible)
            placement.offset = GlobalDMBoxPlacement.offset(of: landed, reference: visible)
            desk.savePlacement(placement, for: .floating)
        }
        lastDrop = (box, landed, context.key, reason)
        guard reason == "release" else { return }
        if panel.isVisible, landed != box {
            let frame = landed.insetBy(dx: -margin, dy: -margin)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        }
        reconcile()
    }

    /// 途中收框（停靠框收起、浮動框收起）：這個框的拖曳結束並存下（照開始那一份），縮放也一樣。
    private func endGestures(_ surface: GlobalDMSurface, reason: String) {
        if drag?.surface == surface { finishDrag(reason) }
        endGrip(surface)
    }

    /// 角的縮放：拖哪個角那個角跟著滑鼠、對角不動（右上角拉＝左下角不動；左下角拉＝右上角不動），比例 0.7–1.3。
    /// W184 G1b（使用者：「縮放中要順」）：縮放途中不排版——開始時真的框拍一張、面板一次換成「對角到最大的框」的畫布，途中只動
    /// 圖層台（快照預覽：框的底色、邊、陰影照新大小，內容照拍下來的樣子貼著角，字級不變）；放開才照新大小排一次、存下來。
    /// 換形態轉換中不開始（停下再縮放）；放開一定收尾；換形態、收框前已經先結束並存下的，同一次按住的後續拖動與放開什麼都不做。
    func handleGrip(_ kind: GlobalDMBoxGrip.Kind, surface: GlobalDMSurface, phase: GlobalDMBoxGrip.Phase) {
        guard hostsWindows, isInstalled, case .resize(let corner) = kind else { return }
        if case .ended = phase {
            guard grip?.surface == surface else { return }
            endGrip(surface)
            reconcile()
            return
        }
        guard canvasPanel == nil, !formMotion.isAnimating, drag == nil,
              let panel = surface == .floating ? floating : docked, panel.isVisible,
              let canvas = panel.contentView as? GlobalDMPanelCanvas else { return }
        let margin = GlobalDMLayout.margin
        switch phase {
        case .began:
            guard grip == nil else { return }
            let box = panel.frame.insetBy(dx: margin, dy: margin)
            let bubble = surface == .floating ? floatingAnchor?() : nil
            guard let geometry = bubble.map(bubbleGeometry) ?? placementGeometry(for: panel, box: box) else { return }
            let base = geometry.standard.size
            let largest = GlobalDMBoxPlacement.largest(box, corner: corner, base: base, area: geometry.bounds)
            let area = box.union(largest).insetBy(dx: -margin, dy: -margin)
            let surfaceColors = GlobalDMFormStage.surface(appearance: panel.effectiveAppearance, size: area.size)
            let started = CACurrentMediaTime()
            // 先拍（配對碼、原生網頁藏著拍），再換畫布、蓋上圖層台：同一次畫面更新。
            let hostBox = NSRect(x: margin, y: margin, width: box.width, height: box.height)
            let capture = canvas.capture(desk.form, box: hostBox, fill: surfaceColors.fill, label: "resize")   // 拍不了（還有碼或原生頁）＝只有框的預覽
            panel.disableScreenUpdatesUntilFlush()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            canvas.place(box: box, panelFrame: area, margin: margin)   // 真的框大小不變（不排版），只換在畫布裡的位置
            panel.setFrame(area, display: false)
            let stage = GlobalDMFormStage(canvas: canvas.bounds, panelOrigin: area.origin, base: area.origin, surface: surfaceColors,
                                          start: CACurrentMediaTime(), manual: true)
            canvas.present(stage)
            stage.still(capture, box: box, form: desk.form)
            CATransaction.commit()
            panel.displayIfNeeded()
            let placement = bubble == nil ? desk.placement(surface) : desk.bubblePlacement
            grip = GlobalDMGrip(corner: corner, surface: surface, box: box, base: base, area: geometry.bounds, reference: geometry.reference,
                                placement: placement, bubble: bubble, standard: geometry.standard,
                                startScale: placement.factor(standard: geometry.standard, bounds: geometry.bounds), current: box)
            lastResizeStartCost = CACurrentMediaTime() - started
        case .changed(let delta):
            guard var active = grip, active.surface == surface, active.corner == corner, let stage = canvas.stage else { return }
            let started = CACurrentMediaTime()
            let resized = GlobalDMBoxPlacement.resized(active.box, corner: corner, base: active.base, by: delta, area: active.area,
                                                       startScale: active.startScale)
            active.current = resized.box
            active.scale = resized.scale
            grip = active
            stage.set(box: resized.box, form: desk.form)
            resizeEvents += 1
            resizeEventCost += CACurrentMediaTime() - started
        case .ended:
            return
        }
    }

    /// 縮放進行中就結束它：面板換回剛好是新框、真的框照新大小排一次、拆掉圖層台（同一次畫面更新），存下位置與大小
    /// （放開、換形態、收框都走這裡；surface＝只收這個框的）。圓鈕模式：蓋到圓鈕就讓開一點，存在圓鈕那一份。
    private func endGrip(_ surface: GlobalDMSurface? = nil) {
        guard let active = grip, surface == nil || active.surface == surface else { return }
        grip = nil
        let margin = GlobalDMLayout.margin
        var box = active.current
        var placement = active.placement
        placement.scale = active.scale ?? placement.scale
        if let bubble = active.bubble {
            box = GlobalDMBoxPlacement.clearing(box, bubble: bubble, in: active.area, fallback: active.standard)
            placement.offset = GlobalDMBoxPlacement.offset(of: box, reference: bubble)
            desk.saveBubblePlacement(placement)
        } else {
            box = GlobalDMBoxPlacement.keepGrabbable(box, in: active.area)   // 縮放途中已經夾在合法的比例裡：這裡不會再動它（保險）
            placement.offset = GlobalDMBoxPlacement.offset(of: box, reference: active.reference)
            desk.savePlacement(placement, for: active.surface)
        }
        guard let panel = active.surface == .floating ? floating : docked, let canvas = panel.contentView as? GlobalDMPanelCanvas,
              canvas.stage != nil else { return }
        panel.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(box.insetBy(dx: -margin, dy: -margin), display: false)
        canvas.rest()
        canvas.layoutSubtreeIfNeeded()
        CATransaction.commit()
        panel.displayIfNeeded()
    }

    /// 頁面圓鈕右鍵選單的「回到預設位置與大小」（縮成圓鈕時＝圓鈕那一份：回到開在圓鈕旁）。
    func resetPlacement(_ surface: GlobalDMSurface) {
        if grip?.surface == surface { endGrip(surface) }
        if surface == .floating, floatingAnchor?() != nil {
            desk.saveBubblePlacement(.standard)
        } else {
            desk.savePlacement(.standard, for: surface)
        }
        reconcile()
    }

    /// 這個面板擺放用的範圍（浮動＝框所在螢幕的 visibleFrame、停靠＝主視窗內容區）。box＝框現在的位置（浮動框照頂列在哪個螢幕：
    /// 拖到別的螢幕就用那個螢幕）。
    private func placementGeometry(for panel: GlobalDMPanel, box: NSRect? = nil) -> GlobalDMPlacementGeometry? {
        if panel === floating {
            let top = box.map { NSPoint(x: $0.midX, y: $0.maxY - GlobalDMBoxPlacement.grabbable / 2) }
            let screen = top.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } } ?? panel.screen
            return floatingPlacementGeometry(screen: screen)
        }
        if panel === docked, let window = visibleMainWindow() { return dockedGeometry(dockedPlacement(in: window)) }
        return nil
    }

    /// W184 F／G1（修正核對 #12）：收起來的面板照樣讓 SwiftUI 把收掉的內容拿掉（藏起來的視窗不一定會自己更新：留在裡面的配對碼會一直擋著截圖）。
    private func settleHidden(_ panel: GlobalDMPanel) {
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func hideFloating() {
        guard let floating, floating.isVisible else { return }
        endGestures(.floating, reason: "hidden")   // W184 F／G1（GPT-6 審查 #3）、G1b 第二輪（G1b 審查 #1）：拖、縮放中收起＝照開始那一份結束並存下
        if floating === canvasPanel { abortCanvas() }   // W184 F2：轉換中收起＝轉換直接停下（不在收起途中再整理一次）
        guard !buttonMorph.isClearing(floating) else { return }   // W184 AB：圓鈕模式收框＝內容先淡出，淡完 buttonMorph 叫整理才收
        buttonMorph.dismiss(floating)   // W184 F45：圓鈕模式＝框縮回圓鈕（收的那一刻已經接手的不重來）
        // 不啟用本 App 的面板收起後，鍵盤焦點自然回到原本在前景的 App。
        floating.orderOut(nil)
        buttonMorph.hidden(floating)   // W184 AB：淡出過的內容等框收掉才還原透明度
        settleHidden(floating)
    }
}
