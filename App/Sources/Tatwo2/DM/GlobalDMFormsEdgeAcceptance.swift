#if DEBUG
import AppKit
import IOSurface
import QuartzCore
import SwiftUI

// W184 AB（使用者 09-30 在 MacBook 實測 .031：「動畫切換展開時 邊線會多幾條」）：w184forms 的「邊線」段——
// 真的面板上的圖層台（時鐘由自測推）在動畫中途取樣幾格、畫出來逐點看：
// E1 外框只有一條：四邊（避開圓角）從外框往裡 2–10pt 找不到第二條跟外框平行的線（輸入框在 12pt、頁面圓鈕在 14pt 以外，不算）；
//    反例：台上故意加一圈往內 5pt 的細線，同一個偵測一定抓得到。
// E2 對話欄容器比新的對話欄寬時（進內橫：容器從舊寬縮到左欄寬），多出來那一條是台自己的紙：沒有舊輸入框的右端、舊的字、舊的漸層
//    （墊底的舊對話欄裁成新的欄寬）；反例：把墊底的圖放回原本的寬度，同一個偵測一定抓得到。
// E3 內橫的右欄跟著分欄的進度出現（0→0.35 淡入）：剛分欄時貼右緣那一小條（右欄輸入框的右端＝跟外框同心的第二條弧線）不是實心的；
//    停下時右欄全出、出內橫停下時全收。
extension GlobalDMFormsAcceptance {
    @MainActor static func edgeLineChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        let store = GlobalDMStore(defaults: freshDefaults("edges"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("edgesDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        panels.install()
        defer {
            store.close()
            panels.uninstall()
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.boxPanelForTesting?.isVisible == true }
        guard let panel = panels.boxPanelForTesting, panel.isVisible, let canvas = panel.contentView as? GlobalDMPanelCanvas else {
            return check.skip("E1–E3 邊線：這個環境開不出浮動框（沒有畫面環境）")
        }
        panel.alphaValue = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        panel.makeFirstResponder(nil)
        let clock = TestClock()
        panels.formMotion.clock = { clock.now }
        panels.formMotion.manualTime = true
        defer {
            panels.formMotion.manualTime = false
            panels.formMotion.clock = { CACurrentMediaTime() }
        }
        var frameProblems: [String] = [], stripProblems: [String] = [], rightProblems: [String] = [], notes: [String] = []
        var framesSeen = 0, stripsSeen = 0, ringCaught = 0, ringTried = 0, untrimCaught = 0, untrimTried = 0
        let transitions: [(GlobalDMForm, GlobalDMForm)] = [(.outerPortrait, .innerLandscape), (.innerLandscape, .innerPortrait),
                                                            (.innerPortrait, .innerLandscape), (.innerLandscape, .outerPortrait),
                                                            (.outerPortrait, .innerPortrait), (.innerPortrait, .tent), (.tent, .outerPortrait)]
        for (from, to) in transitions {
            if settings.form != from {
                let current = settings.form
                settings.form = from
                panels.applyForm(.between(current, from, animated: false))
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            panels.prepareForm()
            settings.form = to
            panels.applyForm(.between(from, to))
            // 新的樣子在動畫開始之後才拍（run loop 的下一輪）；時鐘停著＝在 t＝0 交進來。
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            guard let stage = canvas.stage, let plan = panels.formMotion.plan else {
                frameProblems.append("\(from.rawValue)→\(to.rawValue): no stage")
                continue
            }
            let target = plan.target
            let newColumn = to == .tent ? 0 : GlobalDMPhoneLook(form: to, slide: nil, size: target.size).chatWidth(in: target.width)
            let entering = to.isDuo && !from.isDuo, leaving = from.isDuo && !to.isDuo
            let label = "\(from.rawValue)→\(to.rawValue)"
            for t in [0.03, 0.08, 0.14, 0.24, 0.35] {
                stage.show(at: t)
                let box = stage.presentedBox
                guard let rep = renderStage(stage, box: box, panel: panel, canvas: canvas) else { continue }
                framesSeen += 1
                // E1：外框只有一條。
                let lines = parallelLines(rep, size: box.size)
                if !lines.isEmpty { frameProblems.append("\(label)@\(t): \(lines.prefix(3).joined(separator: ", "))") }
                if t == 0.14 {
                    // 反例：往內 5pt 加一圈細線（外框的顏色），同一個偵測一定抓得到。
                    ringTried += 1
                    let ring = stage.addTestRing(inset: 5)
                    if let ringed = renderStage(stage, box: box, panel: panel, canvas: canvas), !parallelLines(ringed, size: box.size).isEmpty { ringCaught += 1 }
                    ring.removeFromSuperlayer()
                }
                // E2：容器比新的對話欄寬（≥12pt）時多出來那一條＝紙（舊的已經淡完：0.14 秒起）。
                let column = stage.presentedColumn
                if t >= 0.14, to != .tent, column - newColumn >= 12 {
                    stripsSeen += 1
                    let strip = CGRect(x: newColumn + 4, y: DMPhone.headerHeight + 8, width: column - newColumn - 8,
                                       height: box.height - DMPhone.headerHeight - 14)
                    // 只看框裡（圓角 52 往內 4pt）：容器就是整個框時（不是內橫），那一條貼著框的右緣，圓角的外框線不算。
                    let inside = CGPath(roundedRect: CGRect(origin: .zero, size: box.size).insetBy(dx: 4, dy: 4),
                                        cornerWidth: DMPhone.screenRadius - 4, cornerHeight: DMPhone.screenRadius - 4, transform: nil)
                    let ink = inkCount(rep, size: box.size, rect: strip, inside: inside)
                    if ink.dark > max(2, ink.total / 500) {
                        stripProblems.append("\(label)@\(t): \(ink.dark)/\(ink.total) ink pixels between the new column (\(Int(newColumn))) and the container (\(Int(column)))")
                    }
                    // 反例：墊底的圖放回原本的寬度（不裁），同一條一定看得到舊的字或輸入框。
                    let unders = stage.pieces.filter { $0.layer.zPosition < 0 }.map(\.layer)
                    if !unders.isEmpty {
                        untrimTried += 1
                        let saved = unders.map { ($0, $0.bounds, $0.contentsRect) }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        for layer in unders {
                            if let image = layer.contents { layer.bounds.size.width = CGFloat((image as! CGImage).width) / layer.contentsScale }
                            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                        }
                        CATransaction.commit()
                        CATransaction.flush()   // 台照 presentation 畫：改過的大小要先送出去
                        if let untrimmed = renderStage(stage, box: box, panel: panel, canvas: canvas) {
                            let bad = inkCount(untrimmed, size: box.size, rect: strip, inside: inside)
                            if bad.dark > max(2, bad.total / 500) { untrimCaught += 1 }
                            notes.append("\(label)@\(t) strip \(Int(strip.width))pt: trimmed \(ink.dark), untrimmed \(bad.dark)")
                        }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        for (layer, bounds, rect) in saved {
                            layer.bounds = bounds
                            layer.contentsRect = rect
                        }
                        CATransaction.commit()
                        CATransaction.flush()
                    }
                }
                // E3：右欄的透明度跟著分欄進度（0→0.35 淡入）。
                if let frame = panels.formMotion.plan?.frame(at: t), entering || leaving {
                    let want = GlobalDMFormStage.rightShown(frame.duo), got = Double(stage.presentedRightOpacity)
                    if abs(want - got) > 0.05 { rightProblems.append("\(label)@\(t): right opacity \(String(format: "%.2f", got)) want \(String(format: "%.2f", want))") }
                    if entering, t == 0.03, got > 0.6 { rightProblems.append("\(label)@0.03: the right column is already \(String(format: "%.2f", got)) opaque") }
                }
            }
            stage.show(at: plan.end)
            if entering, stage.presentedRightOpacity < 0.999 { rightProblems.append("\(label) end: right opacity \(stage.presentedRightOpacity)") }
            if leaving, stage.presentedRightOpacity > 0.01 { rightProblems.append("\(label) end: right opacity \(stage.presentedRightOpacity)") }
            clock.now += 1
            panels.formMotion.tick()   // 停下
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // E4（GPT-6 第三輪 #5）：連續轉向——外直→內直，還沒停就轉內橫：上一段留下的墊底（舊的外直對話欄，466 寬）也要裁成內橫的左欄寬；
        // 等舊的圖淡完，新欄右邊那一條是紙。反例：只有這一段新建的墊底裁過（上一段那一張照原本的寬＝修之前的做法），同一條看得到舊的字。
        var turnNotes: [String] = [], turnProblems: [String] = [], turnStrips = 0, turnCaught = 0
        if settings.form != .outerPortrait {
            let current = settings.form
            settings.form = .outerPortrait
            panels.applyForm(.between(current, .outerPortrait, animated: false))
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        panels.prepareForm()
        settings.form = .innerPortrait
        panels.applyForm(.between(.outerPortrait, .innerPortrait))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))   // 第一段新的樣子（t＝0）
        clock.now += 0.15
        panels.formMotion.tick()
        settings.form = .innerLandscape
        panels.applyForm(.between(.innerPortrait, .innerLandscape))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))   // 轉向那一段新的樣子（轉向那一刻）
        if let stage = canvas.stage, let plan = panels.formMotion.plan, let turnStart = plan.segments.last?.start, plan.segments.count >= 2 {
            let target = plan.target
            let newColumn = GlobalDMPhoneLook(form: .innerLandscape, slide: nil, size: target.size).chatWidth(in: target.width)
            let unders = stage.pieces.filter { $0.layer.zPosition < 0 }.map(\.layer)
            let widths = unders.map { Int($0.bounds.width) }
            for dt in [0.12, 0.2] {
                stage.show(at: turnStart + dt)
                let box = stage.presentedBox, column = stage.presentedColumn
                guard column - newColumn >= 12, let rep = renderStage(stage, box: box, panel: panel, canvas: canvas) else { continue }
                turnStrips += 1
                let strip = CGRect(x: newColumn + 4, y: DMPhone.headerHeight + 8, width: column - newColumn - 8, height: box.height - DMPhone.headerHeight - 14)
                let inside = CGPath(roundedRect: CGRect(origin: .zero, size: box.size).insetBy(dx: 4, dy: 4),
                                    cornerWidth: DMPhone.screenRadius - 4, cornerHeight: DMPhone.screenRadius - 4, transform: nil)
                let ink = inkCount(rep, size: box.size, rect: strip, inside: inside)
                if ink.dark > max(2, ink.total / 500) { turnProblems.append("@\(dt): \(ink.dark)/\(ink.total) ink pixels beside the new column (\(Int(newColumn))) under a container of \(Int(column))") }
                // 反例：上一段留下的墊底（最早那一張）放回它原本的寬（修之前的做法：轉向只裁新建的）。
                if let older = unders.first, let image = older.contents {
                    let saved = (older.bounds, older.contentsRect)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    older.bounds.size.width = CGFloat((image as! CGImage).width) / older.contentsScale
                    older.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    CATransaction.commit()
                    CATransaction.flush()
                    if let bad = renderStage(stage, box: box, panel: panel, canvas: canvas) {
                        let seen = inkCount(bad, size: box.size, rect: strip, inside: inside)
                        if seen.dark > max(2, seen.total / 500) { turnCaught += 1 }
                        turnNotes.append("@\(dt) strip \(Int(strip.width))pt: all re-trimmed \(ink.dark), older underlay untrimmed \(seen.dark)")
                    }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    older.bounds = saved.0
                    older.contentsRect = saved.1
                    CATransaction.commit()
                    CATransaction.flush()
                }
            }
            turnNotes.insert("underlays \(widths) (new column \(Int(newColumn)))", at: 0)
            if widths.count < 2 || widths.contains(where: { CGFloat($0) > newColumn + 0.5 }) { turnProblems.append("underlays \(widths) not all trimmed to \(Int(newColumn))") }
        } else {
            turnProblems.append("no turn on the stage")
        }
        clock.now += 1
        panels.formMotion.tick()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        print("W184FORMS NOTE E4 consecutive turn: \(turnNotes.joined(separator: "; "))")
        check(turnStrips >= 1 && turnProblems.isEmpty && turnCaught == turnStrips,
              "E4 (W184 AB, GPT-6 third review #5) turning again before the slide stops (outer portrait → inner portrait → inner landscape): every underlay still on the stage — the previous segment's too — is trimmed to the new chat column, so the strip beside it is plain paper once the old pictures have faded; counterexample: the previous segment's underlay left at its width (only the new one trimmed, as before) shows the old ink in the same strip",
              "strips=\(turnStrips) caught=\(turnCaught) \(turnProblems.prefix(3).joined(separator: "; "))")
        print("W184FORMS NOTE E edges: frames \(framesSeen), strips \(stripsSeen); \(notes.joined(separator: "; "))")
        check(framesSeen >= 30 && frameProblems.isEmpty && ringTried > 0 && ringCaught == ringTried,
              "E1 (W184 AB, user 09-30 on .031: extra edge lines while the switch expands) mid-slide at 0.03 / 0.08 / 0.14 / 0.24 / 0.35 s in seven directions the box has one outer frame: along all four sides no second line parallel to it 2–10pt inside (the composer at 12pt and the page circle at 14pt aside); counterexample: a hairline ring added 5pt inside is caught by the same detector",
              "frames=\(framesSeen) ring \(ringCaught)/\(ringTried) \(frameProblems.prefix(4).joined(separator: "; "))")
        check(stripsSeen >= 3 && stripProblems.isEmpty && untrimTried > 0 && untrimCaught == untrimTried,
              "E2 (W184 AB) while the chat container is wider than the new chat column (into inner landscape) the strip beside it is plain paper — no old composer end, old text or old fade (the old column kept underneath is trimmed to the new column's width); counterexample: the same strip with the underlay untrimmed shows the old ink",
              "strips=\(stripsSeen) untrimmed caught \(untrimCaught)/\(untrimTried) \(stripProblems.prefix(4).joined(separator: "; "))")
        check(rightProblems.isEmpty,
              "E3 (W184 AB) the inner-landscape right column follows the split (fades in over the first 35% of it, out over the last 35% when leaving): the sliver at the right edge right after the split starts is not solid (its composer end would be a second arc beside the outer frame); fully shown when it stops in inner landscape, gone when it stops outside",
              rightProblems.prefix(4).joined(separator: "; "))
        settings.form = .outerPortrait
        panels.applyForm(.between(.outerPortrait, .outerPortrait, animated: false))
    }

    /// 四邊（避開圓角 56pt）從外框往裡 2–10pt 找第二條跟外框平行的線：沿著邊每 6pt 取一條剖面，某個深度比兩側（±1.5pt）與整條的中位數
    /// 都暗 16 以上（0–255）＝一個線點；同一邊同一個深度有 ≥ 60% 的剖面都有＝一條線。回傳找到的線（邊、深度）。
    @MainActor static func parallelLines(_ rep: NSBitmapImageRep, size: CGSize) -> [String] {
        let scale = CGFloat(rep.pixelsWide) / size.width
        func lum(_ x: CGFloat, _ y: CGFloat) -> Double {
            let px = min(max(Int(x * scale), 0), rep.pixelsWide - 1), py = min(max(Int(y * scale), 0), rep.pixelsHigh - 1)
            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return 0 }
            return 255 * (0.3 * c.redComponent + 0.59 * c.greenComponent + 0.11 * c.blueComponent)
        }
        let corner: CGFloat = 56
        let depths = stride(from: 2.0, through: 10.0, by: 0.5).map { CGFloat($0) }
        var found: [String] = []
        // (邊, 沿邊的位置, 深度 d → 點)
        let sides: [(String, [CGFloat], (CGFloat, CGFloat) -> CGPoint)] = [
            ("left", Array(stride(from: corner, through: size.height - corner, by: 6)), { along, d in CGPoint(x: d, y: along) }),
            ("right", Array(stride(from: corner, through: size.height - corner, by: 6)), { along, d in CGPoint(x: size.width - d, y: along) }),
            ("top", Array(stride(from: corner, through: size.width - corner, by: 6)), { along, d in CGPoint(x: along, y: d) }),
            ("bottom", Array(stride(from: corner, through: size.width - corner, by: 6)), { along, d in CGPoint(x: along, y: size.height - d) }),
        ]
        for (name, positions, point) in sides where positions.count >= 3 {
            var hits = [Int](repeating: 0, count: depths.count)
            for along in positions {
                let profile = stride(from: 0.5, through: 12.0, by: 0.5).map { d -> Double in let p = point(along, CGFloat(d)); return lum(p.x, p.y) }
                let median = profile.sorted()[profile.count / 2]
                for (index, d) in depths.enumerated() {
                    let i = Int(d / 0.5) - 1
                    guard i - 3 >= 0, i + 3 < profile.count else { continue }
                    let here = profile[i]
                    if here < median - 16, here < profile[i - 3] - 16, here < profile[i + 3] - 16 { hits[index] += 1 }
                }
            }
            for (index, count) in hits.enumerated() where Double(count) >= Double(positions.count) * 0.6 {
                found.append("\(name) \(depths[index])pt (\(count)/\(positions.count))")
            }
        }
        return found
    }

    /// W184 AB（量拍一張為什麼貴）：哪幾層畫起來最貴——每一層整棵畫一次，自己的成本＝整棵 − 子層整棵；只往下找整棵 ≥ 0.5ms 的子層。
    /// 回傳：整棵的時間、自己最貴的前 limit 層（誰的圖層、大小、混合模式／濾鏡／遮罩／圓角裁切／內容的種類）。
    @MainActor static func renderHogs(_ root: CALayer, scale: CGFloat, size: CGSize, limit: Int = 6) -> [String] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: max(1, Int(size.width * scale)), height: max(1, Int(size.height * scale)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        func cost(_ layer: CALayer) -> Double {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            let t0 = CACurrentMediaTime()
            layer.render(in: ctx)
            let ms = (CACurrentMediaTime() - t0) * 1000
            ctx.restoreGState()
            return ms
        }
        func describe(_ layer: CALayer) -> String {
            let owner = layer.delegate.map { String(describing: type(of: $0 as AnyObject)) } ?? String(describing: type(of: layer))
            var flags: [String] = []
            if layer.compositingFilter != nil { flags.append("blend") }
            if !(layer.filters ?? []).isEmpty { flags.append("filters") }
            if !(layer.backgroundFilters ?? []).isEmpty { flags.append("bgfilters") }
            if layer.mask != nil { flags.append("mask") }
            if layer.masksToBounds, layer.cornerRadius > 0 { flags.append("roundclip") }
            if let contents = layer.contents {
                let id = CFGetTypeID(contents as CFTypeRef)
                if id == CGImage.typeID {
                    let image = contents as! CGImage
                    flags.append("image \(image.width)×\(image.height)")
                } else if id == IOSurfaceGetTypeID() {
                    flags.append("iosurface")
                } else {
                    flags.append("contents#\(id)")
                }
            }
            if layer.drawsAsynchronously { flags.append("async") }
            return "\(owner)\(layer.name.map { "(\($0))" } ?? "") \(Int(layer.bounds.width))×\(Int(layer.bounds.height)) [\(flags.joined(separator: ","))]"
        }
        _ = cost(root)
        let total = cost(root)
        var selves: [(Double, String, Double)] = []
        var stack: [CALayer] = [root]
        var visited = 0
        while let layer = stack.popLast(), visited < 2000 {
            visited += 1
            let whole = layer === root ? total : cost(layer)
            var children = 0.0
            for child in layer.sublayers ?? [] {
                let c = cost(child)
                children += c
                if c >= 0.5 { stack.append(child) }
            }
            selves.append((whole - children, describe(layer), whole))
        }
        let top = selves.sorted { $0.0 > $1.0 }.prefix(limit)
        return ["total \(String(format: "%.1f", total))ms over \(visited) layers"]
            + top.map { "self \(String(format: "%.1f", $0.0))ms (tree \(String(format: "%.1f", $0.2))) \($0.1)" }
    }

    /// W184 AB：「冷」的那一下花在哪：每一層照「子層先、自己後」各畫一次（第一次＝冷；畫到自己時子層已經畫過）、再照同樣順序畫一次（熱），
    /// 每一層多花的＝第一次 − 第二次。回傳：第一輪、第二輪的總和、多花最多的前 limit 層。
    @MainActor static func coldHogs(_ root: CALayer, size: CGSize, limit: Int = 8) -> [String] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        var order: [CALayer] = []
        func visit(_ layer: CALayer, depth: Int) {
            guard order.count < 1500 else { return }
            if depth < 40 { for child in layer.sublayers ?? [] { visit(child, depth: depth + 1) } }
            order.append(layer)
        }
        visit(root, depth: 0)
        func pass() -> [Double] {
            order.map { layer -> Double in
                ctx.saveGState()
                let t0 = CACurrentMediaTime()
                layer.render(in: ctx)
                let ms = (CACurrentMediaTime() - t0) * 1000
                ctx.restoreGState()
                return ms
            }
        }
        let first = pass(), second = pass()
        func describe(_ layer: CALayer) -> String {
            let owner = layer.delegate.map { String(describing: type(of: $0 as AnyObject)) } ?? String(describing: type(of: layer))
            var flags: [String] = []
            if layer.compositingFilter != nil { flags.append("blend") }
            if layer.mask != nil { flags.append("mask") }
            if layer.contents != nil { flags.append("contents#\(CFGetTypeID(layer.contents! as CFTypeRef))") }
            return "\(owner) \(Int(layer.bounds.width))×\(Int(layer.bounds.height))[\(flags.joined(separator: ","))]"
        }
        let ranked = zip(order, zip(first, second)).map { ($0.0, $0.1.0 - $0.1.1) }.sorted { $0.1 > $1.1 }.prefix(limit)
        return ["\(order.count) layers, first pass \(String(format: "%.1f", first.reduce(0, +)))ms, second \(String(format: "%.1f", second.reduce(0, +)))ms"]
            + ranked.map { "+\(String(format: "%.1f", $0.1))ms \(describe($0.0))" }
    }

    /// rect（框的座標，左上原點、點）裡比那一塊的中位數暗 18 以上（0–255）的像素有幾個（字、輸入框的線、漸層都算；紙紋不算）。
    @MainActor static func inkCount(_ rep: NSBitmapImageRep, size: CGSize, rect: CGRect, inside: CGPath? = nil) -> (dark: Int, total: Int) {
        let scale = CGFloat(rep.pixelsWide) / size.width
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(rep.pixelsHigh, Int(rect.maxY * scale))
        guard x1 > x0, y1 > y0 else { return (0, 0) }
        var values: [Double] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                if let inside, !inside.contains(CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)) { continue }
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                values.append(255 * (0.3 * c.redComponent + 0.59 * c.greenComponent + 0.11 * c.blueComponent))
            }
        }
        guard !values.isEmpty else { return (0, 0) }
        let median = values.sorted()[values.count / 2]
        return (values.filter { $0 < median - 18 }.count, values.count)
    }
}
#endif
