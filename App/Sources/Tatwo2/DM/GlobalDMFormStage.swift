import AppKit
import QuartzCore
import SwiftUI

// W184 F3（使用者真機驗收 v2.0.21.030：「切換卡頓卡頓的」；主導量到 MacBook Air 上約 20–30 格／秒：每一格都改 SwiftUI 的框、
// 對話欄寬度逐格變＝每一格整支手機重排、文字逐格重新換行，每格還強迫主執行緒同步畫）：換形態的動畫全交給 Core Animation，
// 在畫面伺服器上跑：動畫幾何不逐格觸發排版（A3：GPT-6 審查 F3 #3 的說法修正——框的大小、位置、欄寬、透明度都是圖層動畫，主執行緒不逐格工作；
// 動畫期間真的框只有內容自己變（串流回覆、配對碼到期、撤銷、保護更新照常走）時才排，開始那一刻 SwiftUI 晚一拍套用「轉換中」的狀態最多一次）。
// 動作完全不變（GlobalDMFormPlan 那一套）：右下角固定、框的四邊用阻尼比 1 的彈簧（response 0.42＝.smooth(duration: 0.42)）滑、
// 同一串對話不淡、換倒放才先出後進、轉向（從現在的位置與速度接著滑）、減少動態效果（淡出、換框、淡入）。
// - 開始那一刻（換畫布的同一次畫面更新）：真的 SwiftUI 內容照新形態、剛好是新框的大小只排一次版（停下那一格就是它：不用再排、像素一樣），
//   拍成一張，切成：頂列（貼框的左上）、對話欄（貼框的左下）、內橫右欄（貼框的右下、在對話欄底下）、倒放（整個框、貼右下）。
//   舊的樣子（形態改之前拍好的那一張）照同一種切法放在上面：寬度不同時開頭 0.1 秒交叉淡換；換倒放時先出後進；出內橫時舊的右欄貼右下、
//   被變寬的對話欄蓋過去。舊的對話欄另外留一張在新的底下（不淡）：框變矮時上面空出來的那一段露出舊的訊息（主導的「max(舊高, 新高) 貼底排」
//   換成這個做法：新的排成剛好新框高，停下不用重排；AppKit 的捲動區變矮時是離最上面不變、置中的空狀態會換位置，排高一點再排回來會跳）。
// - 框的底色、邊、陰影、紙紋、分隔線是這裡自己的圖層；對話欄寬、分隔線的位置與透明度、兩層內容的透明度用模型的函式逐格算好（關鍵影格）；
//   框的四邊與貼角用 CASpringAnimation（質量 1、stiffness＝ω²、damping＝2ω，ω＝2π／0.42：跟 GlobalDMSpring 同一條）。
// - 轉向：台上現有的圖從現在的透明度 0.1 秒淡掉（右欄被對話欄蓋回去的例外），新目標重拍，所有容器的彈簧從模型那一刻的位置與速度接著走。
// - 停下：同一次畫面更新裡換回真的內容（排回正常高度、貼底：看得到的部分像素一樣）、拿掉這些圖層、面板換回剛好是新框。
// - 圓角固定 52（W184 F3：任何形態、大小、轉場中都不變）；圖層只有位置、大小、透明度的動畫：沒有 transform、3D、旋轉、縮放。
// - 安全：拍之前原生網頁（CEF）與配對碼都藏好（舊的那一張拍的時候暫時藏、拍完還原；新的那一張拍的時候遮蔽已經持有）；
//   圖只放在這個面板自己的圖層裡（CALayer.contents），不寫檔、不進紀錄；停下就丟掉。

/// 台：蓋在面板畫布上的一層（layer-hosting：圖層樹自己管）。動畫期間真的 SwiftUI 內容在底下（透明度 0，不排版）。
final class GlobalDMStageView: NSView {
    /// 台的座標原點＝螢幕上的一個固定點（畫布轉向時變大，原點不動）。
    let root = CALayer()

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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// 動畫中（0.6 秒）框上的點擊吃掉，不給底下看不見的內容。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}

/// 一段換形態在台上的圖層與動畫（面板畫布一個；停下就拆掉）。
@MainActor
final class GlobalDMFormStage {
    /// 拍好的一個框（整個框：點的大小、像素比例）；tentFill＝倒放影片的佔位色（黑：倒放那一層底下塗滿；nil＝不塗）。
    struct Capture {
        var form: GlobalDMForm
        var image: CGImage
        var size: CGSize
        var scale: CGFloat
        var tentFill: CGColor?
    }

    /// 框的表面（照面板的外觀解析好的顏色）；paper＝底色＋紙紋（fable5 的牛皮紙；玻璃主題沒有）。
    struct Surface {
        var fill: CGColor
        var border: CGColor
        var divider: CGColor
        var paper: CGImage?
    }

    /// 一張圖在框裡的角色：頂列（貼左上）、對話欄（貼左下，在對話欄容器裡）、內橫右欄（貼右下，在對話欄底下）、倒放（貼右下）。
    enum Slot: String {
        case header, left, right, tent
    }

    struct Piece {
        let slot: Slot
        let layer: CALayer
        let old: Bool
    }

    let view: GlobalDMStageView
    /// 台的原點在螢幕上的位置。
    let base: CGPoint
    /// 這一整段轉換的 t＝0 在台上的時間（圖層的本地時間）。
    let origin: CFTimeInterval
    /// 自測推時鐘：台停在指定的時間（show(at:)）。
    let manual: Bool
    let surface: Surface
    private(set) var pieces: [Piece] = []
    private(set) var segments = 0

    private let shadow = CALayer(), clip = CALayer(), paper = CALayer()
    private let chat = CALayer(), body = CALayer(), rights = CALayer(), column = CALayer(), divider = CALayer(), top = CALayer()
    private let tent = CALayer(), tentRight = CALayer()

    var root: CALayer { view.root }

    /// canvas＝畫布的大小；panelOrigin＝面板（畫布）在螢幕上的原點；base＝台的原點（螢幕）；start＝這一整段的 t＝0（CACurrentMediaTime；manual＝自測）。
    init(canvas: NSRect, panelOrigin: CGPoint, base: CGPoint, surface: Surface, start: CFTimeInterval, manual: Bool) {
        view = GlobalDMStageView(frame: canvas)
        view.autoresizingMask = [.width, .height]
        self.base = base
        self.surface = surface
        self.manual = manual
        let root = view.root
        root.bounds = CGRect(origin: .zero, size: canvas.size)
        root.position = CGPoint(x: base.x - panelOrigin.x, y: base.y - panelOrigin.y)
        origin = root.convertTime(start, from: nil)
        if manual {
            root.speed = 0
            root.timeOffset = origin
        }
        for layer in [shadow, clip] {
            layer.anchorPoint = CGPoint(x: 1, y: 0)
            layer.cornerRadius = DMPhone.screenRadius
            layer.cornerCurve = .continuous
            root.addSublayer(layer)
        }
        shadow.backgroundColor = surface.fill
        shadow.shadowColor = NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.22, alpha: 1).cgColor
        shadow.shadowOpacity = 0.12
        shadow.shadowRadius = 9
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        clip.masksToBounds = true
        clip.borderWidth = 1   // 邊畫在所有圖的上面（CALayer 的邊在子圖層之上）；圖裡原本的邊拍的時候已經塗掉
        clip.borderColor = surface.border
        paper.anchorPoint = CGPoint(x: 1, y: 0)
        paper.contents = surface.paper
        paper.contentsGravity = .bottomRight
        paper.contentsScale = 1
        paper.bounds = CGRect(origin: .zero, size: canvas.size)
        clip.addSublayer(paper)
        for layer in [chat, body, column, tent] {
            layer.anchorPoint = .zero
            layer.position = .zero
        }
        body.masksToBounds = true
        column.masksToBounds = true
        tent.masksToBounds = true
        if let paper = surface.paper {
            column.contents = paper
            column.contentsGravity = .bottomLeft
            column.contentsScale = 1
        } else {
            column.backgroundColor = surface.fill
        }
        rights.anchorPoint = .zero
        tentRight.anchorPoint = .zero
        top.anchorPoint = CGPoint(x: 0, y: 1)
        divider.anchorPoint = .zero
        divider.backgroundColor = surface.divider
        divider.opacity = 0
        clip.addSublayer(chat)
        chat.addSublayer(body)
        body.addSublayer(rights)
        body.addSublayer(column)
        body.addSublayer(divider)
        chat.addSublayer(top)
        clip.addSublayer(tent)
        tent.addSublayer(tentRight)
    }

    // MARK: 開始、轉向

    /// 一段（開始或轉向）：框與容器的動畫、第一段舊的樣子（old：蓋在上面）。新的樣子另外交（addFresh）：W184 AB（.031 真機：Retina 上
    /// 按下去到開始動 251ms）——畫面先動（舊的圖跟著框走），新的樣子下一格才拍好交進來；交進來那一刻舊的圖（轉向時台上現有的圖）
    /// 才從當下的透明度 0.1 秒淡掉。減少動態效果：舊的照舊在換框那一刻消失（不等新的）。
    func run(_ segment: GlobalDMSlideSegment, old: Capture?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        segments += 1
        let begin = origin + segment.start
        let fade = segment.style == .fade
        let out = DMPhone.Slide.reduceOut
        let length = segment.length
        var swaps = false
        // W184 AB（使用者 09-30 .031：「動畫切換展開時 邊線會多幾條」）：墊底的舊對話欄只墊「框變矮時新的上面空出來的那一段」，
        // 寬度裁成新的對話欄那麼寬——對話欄容器比新的寬時（例如外直→內橫、內直→內橫：容器從舊寬縮到左欄寬），多出來那一條
        // 露的是台自己的紙，不再露出舊輸入框的右端、舊的字、舊的淡出漸層（那一條就是多出來的幾條邊線）。
        let newColumn = segment.form == .tent ? 0
            : GlobalDMPhoneLook(form: segment.form, slide: nil, size: segment.target.size).chatWidth(in: segment.target.width)
        if !pieces.isEmpty {
            // A2（GPT-6 審查 F3 #2）：連續轉向不累積——已經淡到看不見的圖拿掉，墊底的被更新的蓋滿就拿掉（每種大小最多一張）。
            recycle()
            // 轉向：上一個目標的對話欄另外留一張在新的底下（框變矮時墊著）。現有的圖等新的交進來才淡（減少動態效果＝換框那一刻消失）。
            for piece in pieces where piece.slot == .left && !piece.old && piece.layer.zPosition == 0 {
                if let image = piece.layer.contents {
                    let under = place(.left, image: image as! CGImage, size: piece.layer.bounds.size, scale: piece.layer.contentsScale, tier: .under)
                    pieces.append(Piece(slot: .left, layer: under, old: true))
                }
            }
            if fade {
                for piece in pieces where !(piece.slot == .right && !segment.form.isDuo) && piece.layer.zPosition >= 0 {
                    let now = Double(piece.layer.presentation()?.opacity ?? piece.layer.opacity)
                    piece.layer.removeAnimation(forKey: "o")
                    piece.layer.opacity = 0
                    piece.layer.add(Self.discrete("opacity", [now, 0], switchAt: out, length: length, begin: begin), forKey: "o")
                    piece.layer.zPosition = 1
                }
            }
        }
        if let old {
            // 換倒放（先出後進）：舊的整層由容器淡（chat／tent 的透明度照模型）；同一串對話：頂列與對話欄等新的交進來才淡（交叉淡換），
            // 右欄不淡（被變寬的對話欄蓋回去）；減少動態效果：換框那一刻消失。
            swaps = (old.form == .tent) != (segment.form == .tent)
            for (slot, image, size) in Self.slices(of: old) {
                let layer = place(slot, image: image, size: size, scale: old.scale, tier: .top)
                pieces.append(Piece(slot: slot, layer: layer, old: true))
                if slot == .left, !swaps, !fade {
                    // 同一張舊的對話欄另外留一張在新的底下、不淡：框變矮時上面空出來的那一段露出舊的訊息（寬度裁成新的對話欄寬）。
                    let under = place(slot, image: image, size: size, scale: old.scale, tier: .under)
                    pieces.append(Piece(slot: slot, layer: under, old: true))
                }
                if fade {
                    layer.opacity = 0
                    layer.add(Self.discrete("opacity", [1, 0], switchAt: out, length: length, begin: begin), forKey: "o")
                }
            }
            if old.form == .tent, segment.form != .tent { tent.backgroundColor = old.tentFill }
        }
        // W184 AB（GPT-6 第三輪 #5）：每一段（開始、每一次轉向）都把「所有」還在的墊底裁成這一段新的對話欄寬（照原圖的寬算，
        // 裁過的可以再放寬）：連續轉向時上一段留下、比較寬的墊底不會在新欄右邊露出舊的邊線。
        for piece in pieces where piece.layer.zPosition < 0 { Self.trim(piece.layer, to: newColumn) }
        waiting = (segment, swaps)
        animateFrame(segment, begin: begin)
    }

    /// 這一段的新樣子交進來（start＝交進來的那一刻，這一整段的秒數）：放在墊底的上面、現有的圖底下；現有的圖（第一段的舊樣子、轉向時
    /// 台上的）從當下的透明度 0.1 秒淡掉（右欄不去內橫時留著、被對話欄蓋回去；換倒放由容器淡）。晚交進來、而且原本沒有同一格的圖
    /// （例如進內橫的右欄）＝0.1 秒淡入（不突然跳出來）。減少動態效果：照換框那一刻出現。
    @discardableResult
    func addFresh(_ fresh: Capture, at start: Double) -> Bool {
        guard let (segment, swaps) = waiting else { return false }
        waiting = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let fade = segment.style == .fade
        let begin = origin + segment.start, now = origin + start
        let out = DMPhone.Slide.reduceOut, length = segment.length, fadeOut = DMPhone.Slide.fadeOut
        let late = start > segment.start + 0.001
        var covered = Set<Slot>()
        for piece in pieces where piece.layer.zPosition >= 0 && piece.layer.opacity > 0.001 { covered.insert(piece.slot) }
        if !fade, !swaps {
            for piece in pieces where !(piece.slot == .right && !segment.form.isDuo) && piece.layer.zPosition >= 0 {
                // A2：已經在淡的（目標透明度已經是 0）照原本的淡法淡完，不重新開始。
                if piece.layer.opacity < 0.001 { continue }
                let shown = Double(piece.layer.presentation()?.opacity ?? piece.layer.opacity)
                piece.layer.removeAnimation(forKey: "o")
                piece.layer.opacity = 0
                piece.layer.add(Self.sampled("opacity", length: fadeOut, begin: now, { shown * (1 - GlobalDMEase.step(0, fadeOut, $0)) }),
                                forKey: "o")
                piece.layer.zPosition = 1
            }
        }
        for (slot, image, size) in Self.slices(of: fresh) {
            let layer = place(slot, image: image, size: size, scale: fresh.scale, tier: .fresh)
            pieces.append(Piece(slot: slot, layer: layer, old: false))
            if fade {
                layer.opacity = 1
                layer.add(Self.discrete("opacity", [0, 1], switchAt: out, length: length, begin: begin), forKey: "o")
            } else if late, !covered.contains(slot) {
                layer.opacity = 1
                layer.add(Self.sampled("opacity", length: fadeOut, begin: now, { GlobalDMEase.step(0, fadeOut, $0) }), forKey: "o")
            }
        }
        if fresh.form == .tent { tent.backgroundColor = fresh.tentFill }
        return true
    }

    /// 墊底的圖裁成 width 寬（貼左、只留左邊那一塊；width≤0 或不比原圖窄＝整張）：寬度照「原圖」的寬算（不是現在裁過的寬，
    /// 轉向幾次都不會越裁越歪），contentsRect 取左邊那一段、大小照點 1:1，不縮放。
    static func trim(_ layer: CALayer, to width: CGFloat) {
        guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return }
        let full = CGFloat((contents as! CGImage).width) / max(layer.contentsScale, 1)
        let kept = width > 0 ? min(width, full) : full
        layer.bounds.size.width = kept
        layer.contentsRect = CGRect(x: 0, y: 0, width: kept / full, height: 1)
    }

    /// 這一段還在等新的樣子（run 之後、addFresh 之前）。
    var awaitingFresh: Bool { waiting != nil }
    private var waiting: (segment: GlobalDMSlideSegment, swaps: Bool)?

    /// 拿掉已經淡到看不見的圖（透明度的目標是 0、現在也是 0）；墊底的被比它新的蓋滿（寬、高都不比它小：都貼左下）就拿掉
    ///（同一個形態、同樣大小的只留最新的一張：最多每種大小一張）。
    private func recycle() {
        pieces.removeAll { piece in
            guard piece.layer.zPosition >= 0 else { return false }
            let shown = piece.layer.presentation()?.opacity ?? piece.layer.opacity
            guard piece.layer.opacity < 0.001, shown < 0.001 else { return false }
            piece.layer.removeFromSuperlayer()
            return true
        }
        let unders = pieces.filter { $0.layer.zPosition < 0 }
        var covered = Set<ObjectIdentifier>()
        for (index, older) in unders.enumerated() {
            let size = older.layer.bounds.size
            let newer = unders[(index + 1)...]
            guard newer.contains(where: { $0.layer.bounds.width >= size.width - 0.5 && $0.layer.bounds.height >= size.height - 0.5 }) else { continue }
            covered.insert(ObjectIdentifier(older.layer))
            older.layer.removeFromSuperlayer()
        }
        pieces.removeAll { covered.contains(ObjectIdentifier($0.layer)) }
    }

    /// 一張圖在它的容器裡放哪一層。容器的子圖層陣列順序＝畫的順序（zPosition 也設成同一個順序）：畫面伺服器照 zPosition 排、
    /// CALayer.render（自測拍台上的樣子）照陣列的順序畫——兩個一定要一樣（H5：轉向之後墊底的圖被畫在新的上面）。
    private enum Tier {
        /// 墊底：舊的對話欄墊在新的底下（在所有圖底下；比更舊的墊底新＝在它上面）。
        case under
        /// 新的：在墊底的上面、在台上現有的圖（淡掉中的）底下。
        case fresh
        /// 舊的（第一段）：蓋在最上面。
        case top
    }

    /// 一張圖放進它的容器：頂列貼左上、對話欄貼左下、右欄與倒放貼右下；照 tier 放在陣列的哪裡、zPosition（−1、0、1）。
    private func place(_ slot: Slot, image: CGImage, size: CGSize, scale: CGFloat, tier: Tier) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = .zero
        let container: CALayer
        switch slot {
        case .header:
            layer.anchorPoint = CGPoint(x: 0, y: 1)
            container = top
        case .left:
            layer.anchorPoint = .zero
            container = column
        case .right:
            layer.anchorPoint = CGPoint(x: 1, y: 0)
            container = rights
        case .tent:
            layer.anchorPoint = CGPoint(x: 1, y: 0)
            container = tentRight
        }
        let unders = UInt32(container.sublayers?.filter { $0.zPosition < 0 }.count ?? 0)
        switch tier {
        case .under:
            layer.zPosition = -1
            container.insertSublayer(layer, at: unders)
        case .fresh:
            layer.zPosition = 0
            container.insertSublayer(layer, at: unders)
        case .top:
            layer.zPosition = 1
            container.addSublayer(layer)
        }
        return layer
    }

    /// 框與各個容器照這一段動：框的四邊、貼角＝彈簧（減少動態效果＝換框那一刻直接換）；對話欄寬、分隔線、兩層內容的透明度＝模型逐格算好的關鍵影格。
    private func animateFrame(_ segment: GlobalDMSlideSegment, begin: CFTimeInterval) {
        let head = Double(DMPhone.headerHeight)
        let inset = head + Double(DMPhone.dividerTop + DMPhone.dividerBottom)
        let bx = Double(base.x), by = Double(base.y)
        let x = segment.x, y = segment.y, w = segment.width, h = segment.height
        let maxX = GlobalDMSpring(origin: x.origin + w.origin, velocity: x.velocity + w.velocity, target: x.target + w.target)
        let fade = segment.style == .fade
        let before = segment.before.box, after = segment.target
        let beforeHeight = Double(before.height), afterHeight = Double(after.height)
        let length = segment.length

        /// 一個數（彈簧 s 往上加 shift）：滑＝彈簧；減少動態效果＝換框那一刻從舊值換成新值。
        func drive(_ layer: CALayer, _ keyPath: String, _ key: String, _ s: GlobalDMSpring, shift: Double = 0,
                   from fadeFrom: Double, to fadeTo: Double) {
            layer.removeAnimation(forKey: key)
            if fade {
                guard abs(fadeFrom - fadeTo) > 0.000_1 else { return }
                layer.add(Self.discrete(keyPath, [fadeFrom + shift, fadeTo + shift], switchAt: DMPhone.Slide.reduceOut,
                                        length: length, begin: begin), forKey: key)
            } else if let animation = Self.spring(keyPath, s, shift: shift, begin: begin) {
                layer.add(animation, forKey: key)
            }
        }

        let W = after.width, H = after.height
        for layer in [shadow, clip] {
            layer.bounds = CGRect(x: 0, y: 0, width: W, height: H)
            layer.position = CGPoint(x: after.maxX - base.x, y: after.minY - base.y)
            drive(layer, "bounds.size.width", "w", w, from: Double(before.width), to: Double(after.width))
            drive(layer, "bounds.size.height", "h", h, from: beforeHeight, to: afterHeight)
            drive(layer, "position.x", "x", maxX, shift: -bx, from: Double(before.maxX), to: Double(after.maxX))
            drive(layer, "position.y", "y", y, shift: -by, from: Double(before.minY), to: Double(after.minY))
        }
        paper.position = CGPoint(x: W, y: 0)
        drive(paper, "position.x", "x", w, from: Double(before.width), to: Double(after.width))
        for layer in [chat, tent] {
            layer.bounds = CGRect(x: 0, y: 0, width: W, height: H)
            drive(layer, "bounds.size.width", "w", w, from: Double(before.width), to: Double(after.width))
            drive(layer, "bounds.size.height", "h", h, from: beforeHeight, to: afterHeight)
        }
        let bodyHeight = GlobalDMSpring(origin: h.origin - head, velocity: h.velocity, target: h.target - head)
        body.bounds = CGRect(x: 0, y: 0, width: W, height: max(0, H - CGFloat(head)))
        drive(body, "bounds.size.width", "w", w, from: Double(before.width), to: Double(after.width))
        drive(body, "bounds.size.height", "h", bodyHeight, from: beforeHeight - head, to: afterHeight - head)
        for layer in [rights, tentRight] {
            layer.position = CGPoint(x: W, y: 0)
            drive(layer, "position.x", "x", w, from: Double(before.width), to: Double(after.width))
        }
        top.position = CGPoint(x: 0, y: H)
        drive(top, "position.y", "y", h, from: beforeHeight, to: afterHeight)

        // 對話欄寬（照模型：框寬 −（內橫的框寬 − 左欄）× 進度）、分隔線跟著它的右緣、兩層的透明度：模型逐格算好。
        func chatWidth(_ tau: Double) -> Double {
            let frame = segment.frame(at: tau)
            return Double(GlobalDMPhoneLook(form: frame.form, slide: frame, size: frame.box.size).chatWidth(in: frame.box.width))
        }
        let end = segment.frame(at: length)
        let endColumn = CGFloat(chatWidth(length))
        column.bounds = CGRect(x: 0, y: 0, width: endColumn, height: max(0, H - CGFloat(head)))
        column.removeAnimation(forKey: "w")
        column.add(Self.sampled("bounds.size.width", length: length, begin: begin, chatWidth), forKey: "w")
        drive(column, "bounds.size.height", "h", bodyHeight, from: beforeHeight - head, to: afterHeight - head)
        divider.bounds = CGRect(x: 0, y: 0, width: DMPhone.hairline, height: max(1, H - CGFloat(inset)))
        divider.position = CGPoint(x: endColumn, y: DMPhone.dividerBottom)
        divider.removeAnimation(forKey: "x")
        divider.add(Self.sampled("position.x", length: length, begin: begin, chatWidth), forKey: "x")
        drive(divider, "bounds.size.height", "h", GlobalDMSpring(origin: h.origin - inset, velocity: h.velocity, target: h.target - inset),
              from: beforeHeight - inset, to: afterHeight - inset)
        divider.opacity = Float(end.divider)
        divider.removeAnimation(forKey: "o")
        divider.add(Self.sampled("opacity", length: length, begin: begin, { segment.frame(at: $0).divider }), forKey: "o")
        chat.opacity = Float(end.chat)
        chat.removeAnimation(forKey: "o")
        chat.add(Self.sampled("opacity", length: length, begin: begin, { segment.frame(at: $0).chat }), forKey: "o")
        tent.opacity = Float(end.tent)
        tent.removeAnimation(forKey: "o")
        tent.add(Self.sampled("opacity", length: length, begin: begin, { segment.frame(at: $0).tent }), forKey: "o")
        // W184 AB（「動畫切換展開時 邊線會多幾條」）：內橫的右欄跟著分欄進度出現（0→0.35 淡入；出內橫最後 35% 淡掉）：剛分欄時
        // 貼右緣露出的那一小條（右欄輸入框的右端＝跟外框同心的第二條弧線）不再實心出現。
        rights.opacity = Float(Self.rightShown(end.duo))
        rights.removeAnimation(forKey: "o")
        rights.add(Self.sampled("opacity", length: length, begin: begin, { Self.rightShown(segment.frame(at: $0).duo) }), forKey: "o")
        // 減少動態效果：整個框淡出、換框、淡入（滑的時候一直是 1）。
        root.removeAnimation(forKey: "o")
        root.opacity = 1
        if fade {
            root.add(Self.sampled("opacity", length: length, begin: begin, { segment.frame(at: $0).opacity }), forKey: "o")
        }
    }

    /// 右欄的透明度（分欄進度 duo：0＝單欄、1＝內橫）。
    static func rightShown(_ duo: Double) -> Double { GlobalDMEase.clamp(duo / DMPhone.Slide.rightIn) }

    // MARK: 縮放的快照預覽（W184 G1b）

    /// 拍好的框貼上去（頂列貼左上、對話欄貼左下、右欄與倒放貼右下），框照 box 擺。capture＝nil（拍不了：還有配對碼或原生頁）＝只有框。
    func still(_ capture: Capture?, box: CGRect, form: GlobalDMForm) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let capture {
            for (slot, image, size) in Self.slices(of: capture) {
                let layer = place(slot, image: image, size: size, scale: capture.scale, tier: .fresh)
                pieces.append(Piece(slot: slot, layer: layer, old: false))
            }
            if capture.form == .tent { tent.backgroundColor = capture.tentFill }
        }
        CATransaction.commit()
        set(box: box, form: form)
    }

    /// 框換成 box（螢幕座標；不動畫、不排版）：底色、邊、陰影照新大小，拍下來的內容貼著角（字級不變）。
    func set(box: CGRect, form: GlobalDMForm) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = box.width, height = box.height, head = DMPhone.headerHeight
        for layer in [shadow, clip] {
            layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            layer.position = CGPoint(x: box.maxX - base.x, y: box.minY - base.y)
        }
        paper.position = CGPoint(x: width, y: 0)
        for layer in [chat, tent] { layer.bounds = CGRect(x: 0, y: 0, width: width, height: height) }
        body.bounds = CGRect(x: 0, y: 0, width: width, height: max(0, height - head))
        for layer in [rights, tentRight] { layer.position = CGPoint(x: width, y: 0) }
        rights.opacity = form.isDuo ? 1 : 0
        top.position = CGPoint(x: 0, y: height)
        let columnWidth = GlobalDMPhoneLook(form: form, slide: nil, size: box.size).chatWidth(in: width)
        column.bounds = CGRect(x: 0, y: 0, width: columnWidth, height: max(0, height - head))
        divider.position = CGPoint(x: columnWidth, y: DMPhone.dividerBottom)
        divider.bounds = CGRect(x: 0, y: 0, width: DMPhone.hairline, height: max(1, height - head - DMPhone.dividerTop - DMPhone.dividerBottom))
        divider.opacity = form.isDuo ? 1 : 0
        chat.opacity = form == .tent ? 0 : 1
        tent.opacity = form == .tent ? 1 : 0
        CATransaction.commit()
    }

    /// 畫布變大（轉向時）：台的原點在螢幕上不動。
    func move(panelOrigin: CGPoint, canvas: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = canvas
        root.bounds = CGRect(origin: .zero, size: canvas.size)
        root.position = CGPoint(x: base.x - panelOrigin.x, y: base.y - panelOrigin.y)
        paper.bounds = CGRect(origin: .zero, size: CGSize(width: max(paper.bounds.width, canvas.width),
                                                           height: max(paper.bounds.height, canvas.height)))
        CATransaction.commit()
    }

    // MARK: 切圖

    /// 一個框切成幾張：倒放＝整個框；其他＝頂列（68）、對話欄（左欄寬）、內橫右欄（分隔線右邊）。回傳（角色、圖、點的大小）。
    static func slices(of capture: Capture) -> [(Slot, CGImage, CGSize)] {
        let size = capture.size, head = DMPhone.headerHeight
        var rects: [(Slot, CGRect)]
        if capture.form == .tent {
            rects = [(.tent, CGRect(origin: .zero, size: size))]
        } else {
            let left = GlobalDMPhoneLook(form: capture.form, slide: nil, size: size).chatWidth(in: size.width)
            rects = [(.header, CGRect(x: 0, y: 0, width: size.width, height: head)),
                     (.left, CGRect(x: 0, y: head, width: left, height: size.height - head))]
            if capture.form.isDuo {
                let x = left + DMPhone.hairline
                rects.append((.right, CGRect(x: x, y: head, width: size.width - x, height: size.height - head)))
            }
        }
        return rects.compactMap { entry -> (Slot, CGImage, CGSize)? in
            let (slot, rect) = entry
            let s = capture.scale
            let pixels = CGRect(x: (rect.minX * s).rounded(), y: (rect.minY * s).rounded(),
                                width: (rect.width * s).rounded(), height: (rect.height * s).rounded())
            guard pixels.width >= 1, pixels.height >= 1, let image = capture.image.cropping(to: pixels) else { return nil }
            return (slot, image, CGSize(width: pixels.width / s, height: pixels.height / s))
        }
    }

    // MARK: 自測

    /// 自測推時鐘：整個台停在 elapsed 秒（圖層的 presentation 就是那一刻）。
    func show(at elapsed: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.speed = 0
        root.timeOffset = origin + elapsed
        CATransaction.commit()
        CATransaction.flush()
    }

    /// 框現在在畫面上的樣子（螢幕座標；presentation）。
    var presentedBox: CGRect {
        let layer = clip.presentation() ?? clip
        return CGRect(x: layer.position.x - layer.bounds.width + base.x, y: layer.position.y + base.y,
                      width: layer.bounds.width, height: layer.bounds.height)
    }

    var presentedRadius: CGFloat { (clip.presentation() ?? clip).cornerRadius }

    /// 框的模型值（螢幕座標）：縮放預覽（沒有動畫）的這一格——presentation 要等畫面更新才換，自測在同一格裡讀這個。
    var modelBox: CGRect {
        CGRect(x: clip.position.x - clip.bounds.width + base.x, y: clip.position.y + base.y, width: clip.bounds.width, height: clip.bounds.height)
    }

    /// 對話欄現在的寬（presentation）。
    var presentedColumn: CGFloat { (column.presentation() ?? column).bounds.width }

    /// 內橫右欄現在的透明度（presentation）。
    var presentedRightOpacity: Float { (rights.presentation() ?? rights).opacity }

    #if DEBUG
    /// 自測的反例：在框裡往內 inset 點畫一圈外框顏色的細線（照現在的 presentation 大小；拿掉＝removeFromSuperlayer）。
    func addTestRing(inset: CGFloat) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shown = clip.presentation() ?? clip
        let ring = CAShapeLayer()
        ring.frame = CGRect(origin: .zero, size: shown.bounds.size)
        let rect = ring.bounds.insetBy(dx: inset, dy: inset)
        ring.path = CGPath(roundedRect: rect, cornerWidth: DMPhone.screenRadius - inset, cornerHeight: DMPhone.screenRadius - inset, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = surface.border
        ring.lineWidth = 1
        ring.zPosition = 10
        clip.addSublayer(ring)
        CATransaction.commit()
        return ring
    }
    #endif

    /// 兩層內容與整個框現在的透明度（presentation）。
    var presentedOpacity: (chat: Float, tent: Float, whole: Float) {
        ((chat.presentation() ?? chat).opacity, (tent.presentation() ?? tent).opacity, (root.presentation() ?? root).opacity)
    }

    /// 倒放那一層底下的顏色（黑＝有影片）。
    var tentBackdrop: CGColor? { tent.backgroundColor }

    /// 台上所有圖層（自測看 transform、動畫的 keyPath）。
    var allLayers: [CALayer] {
        var result: [CALayer] = []
        var stack: [CALayer] = [root]
        while let layer = stack.popLast() {
            result.append(layer)
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        return result
    }

    /// 自測：照現在的 presentation 畫進 rep（region＝畫布座標裡要畫的那一塊；underlay＝先鋪的底色）。先把每一層的樣子抄進 model、畫完還原。
    func render(into rep: NSBitmapImageRep, region: CGRect, underlay: CGColor?) {
        guard region.width > 0, region.height > 0, let context = NSGraphicsContext(bitmapImageRep: rep), let backing = view.layer else { return }
        let scale = CGFloat(rep.pixelsWide) / region.width
        let cg = context.cgContext
        cg.saveGState()
        let whole = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        cg.clear(whole)
        if let underlay {
            cg.setFillColor(underlay)
            cg.fill(whole)
        }
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -region.minX, y: -region.minY)
        var saved: [(CALayer, CGRect, CGPoint, Float)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in allLayers {
            let shown = layer.presentation() ?? layer
            saved.append((layer, layer.bounds, layer.position, layer.opacity))
            layer.bounds = shown.bounds
            layer.position = shown.position
            layer.opacity = shown.opacity
        }
        backing.render(in: cg)
        for (layer, bounds, position, opacity) in saved {
            layer.bounds = bounds
            layer.position = position
            layer.opacity = opacity
        }
        CATransaction.commit()
        cg.restoreGState()
        context.flushGraphics()
    }

    /// 停下：拆掉（同一次畫面更新裡換回真的內容）。
    func remove() {
        view.removeFromSuperview()
        pieces = []
    }

    // MARK: 動畫

    /// 阻尼比 1 的彈簧（跟 GlobalDMSpring 同一條：質量 1、stiffness＝ω²、damping＝2ω，ω＝2π／0.42）；起點、速度（點／秒）、終點照模型。
    /// 沒有要走的距離卻有速度（轉向剛好在終點上）＝照模型逐格算好的關鍵影格。
    static func spring(_ keyPath: String, _ s: GlobalDMSpring, shift: Double = 0, begin: CFTimeInterval) -> CAAnimation? {
        let from = s.origin + shift, to = s.target + shift
        if abs(to - from) < 0.25 {
            guard abs(s.velocity) > 0.5 else { return nil }
            return sampled(keyPath, length: DMPhone.Slide.settle, begin: begin, { s.value(at: $0) + shift })
        }
        let omega = GlobalDMSpring.omega
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = CGFloat(omega * omega)
        animation.damping = CGFloat(2 * omega)
        animation.initialVelocity = CGFloat(s.velocity / (to - from))   // 正＝朝終點（以整段距離為單位）
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 1
        animation.beginTime = begin
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// 照函式逐格（1/240 秒）算好的關鍵影格（線性）；f 的參數是這一段開始後的秒數。
    static func sampled(_ keyPath: String, length: Double, begin: CFTimeInterval, _ f: (Double) -> Double) -> CAKeyframeAnimation {
        let step = 1.0 / 240, total = max(length, 0.001)
        let count = max(1, Int((total / step).rounded(.up)))
        let times = (0...count).map { min(total, Double($0) * step) }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = times.map { NSNumber(value: f($0)) }
        animation.keyTimes = times.map { NSNumber(value: $0 / total) }
        animation.calculationMode = .linear
        animation.duration = total
        animation.beginTime = begin
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// 某一刻直接換（減少動態效果的換框）：values[0] 到 switchAt 秒，之後 values[1]。
    static func discrete(_ keyPath: String, _ values: [Double], switchAt: Double, length: Double,
                         begin: CFTimeInterval) -> CAKeyframeAnimation {
        let total = max(length, switchAt + 0.001)
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values.map { NSNumber(value: $0) }
        animation.keyTimes = [0, NSNumber(value: switchAt / total), 1]   // discrete：比 values 多一格
        animation.calculationMode = .discrete
        animation.duration = total
        animation.beginTime = begin
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    // MARK: 表面

    /// 照面板的外觀解析框的顏色；紙紋（fable5）畫成一張底圖（底色＋紙紋 multiply），大小＝畫布。
    static func surface(appearance: NSAppearance, size: CGSize) -> Surface {
        let palette = TatwoActivePalette.current
        var fill = NSColor.windowBackgroundColor.cgColor, border = NSColor.separatorColor.cgColor
        var line = NSColor.separatorColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            if palette.usesGlass {
                // 系統玻璃拍不進圖：動畫那 0.6 秒用接近的霧面底色，停下換回真的玻璃。
                fill = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
                border = NSColor(palette.surfaceBorder).withAlphaComponent(0.5).cgColor
            } else {
                fill = NSColor(palette.surfaceFill).cgColor
                border = NSColor(palette.surfaceBorder).withAlphaComponent(0.85).cgColor
            }
            line = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
        let paper = palette.usesGlass ? nil : paperImage(size: size, fill: fill, grain: palette.grain)
        return Surface(fill: fill, border: border, divider: line, paper: paper)
    }

    private static var paperCache: (key: String, image: CGImage)?
    /// 紙紋的 tile（噪點是 Core Image 產生的：只轉一次成 CGImage）。
    private static var tileImage: CGImage?

    /// 底色＋紙紋（同 tatwoGrainOverlay：180pt 的噪點 tile、multiply、透明度＝grain），一點一像素（同 ImagePaint scale 1）。
    static func paperImage(size: CGSize, fill: CGColor, grain: Double) -> CGImage? {
        // 大小進位到 512 的倍數：換形態、轉向的畫布大小不一樣也多半用同一張（只在第一次畫）。
        let width = Int((size.width / 512).rounded(.up) * 512), height = Int((size.height / 512).rounded(.up) * 512)
        guard width > 0, height > 0 else { return nil }
        let key = "\(width)x\(height)|\(fill.components ?? [])|\(grain)"
        if let paperCache, paperCache.key == key { return paperCache.image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(fill)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if tileImage == nil { tileImage = TatwoPaperGrain.tile.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if grain > 0.0001, let tile = tileImage {
            context.setBlendMode(.multiply)
            context.setAlpha(grain)
            let side = 180
            for y in stride(from: 0, to: height, by: side) {
                for x in stride(from: 0, to: width, by: side) {
                    context.draw(tile, in: CGRect(x: x, y: y, width: side, height: side))
                }
            }
        }
        guard let image = context.makeImage() else { return nil }
        paperCache = (key, image)
        return image
    }
}
