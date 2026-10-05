#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

// W184 G1b（使用者 09-29：「左下也可以調尺寸好了」「拖拽範圍跟體驗有很多問題」；選了：拖的時候卡、跟不上滑鼠／範圍太小，拖不到想放的地方／
// 不知道哪裡能抓／「縮小os後的私訊筐無法拖拽」）：w184forms 的拖拽、縮放段——
// 純計算（範圍的唯一限制＝頂列至少 44pt、兩個角的等比縮放、圓鈕讓開）、記住（浮動、停靠、圓鈕模式各一份）、真的面板的原生拖曳路徑
// （注入事件：頂列的抓取區收到按下 → 交給視窗伺服器的拖曳；放開才存）、角的縮放（快照預覽、放開才排一次）、圓鈕模式、
// 角標在四種形態的位置、游標（W184 AB：頂列的小把手拿掉了，能抓的提示是游標）。
extension GlobalDMFormsAcceptance {
    // MARK: - 純計算

    @MainActor static func gripPureChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) {
        typealias P = GlobalDMBoxPlacement
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let base = floatingStandard(.outerPortrait, in: visible)

        // D20 範圍：唯一限制＝頂列至少 44pt 在範圍裡。拖到一大半在螢幕外（頂列還有 60pt 在裡面）＝照放的；整個拖出去＝推回剛好 44pt；
        // 上緣不超過範圍上緣；頂列最上面 44pt 不低於範圍下緣。
        let mostlyOut = base.offsetBy(dx: visible.maxX - 60 - base.minX, dy: 0)
        let allOut = base.offsetBy(dx: 5_000, dy: 0)
        let tooHigh = base.offsetBy(dx: 0, dy: 5_000)
        let tooLow = base.offsetBy(dx: 0, dy: -5_000)
        let leftOut = base.offsetBy(dx: -5_000, dy: 0)
        let keptOut = P.keepGrabbable(mostlyOut, in: visible), pulled = P.keepGrabbable(allOut, in: visible)
        let lowered = P.keepGrabbable(tooHigh, in: visible), raised = P.keepGrabbable(tooLow, in: visible)
        let pulledLeft = P.keepGrabbable(leftOut, in: visible)
        check(keptOut == mostlyOut && abs(pulled.minX - (visible.maxX - 44)) < 0.001 && abs(lowered.maxY - visible.maxY) < 0.001
              && abs(raised.maxY - (visible.minY + 44)) < 0.001 && abs(pulledLeft.maxX - (visible.minX + 44)) < 0.001
              && P.isGrabbable(mostlyOut, in: visible) && !P.isGrabbable(allOut, in: visible),
              "D20 the only limit is 44pt of the top bar inside: a box dragged mostly off-screen (60pt of its top bar left) stays where it was dropped; dragged fully out it comes back to exactly 44pt; the top never goes above the area and the top 44pt never below it",
              "kept=\(keptOut) pulled=\(pulled) lowered=\(lowered) raised=\(raised) left=\(pulledLeft)")
        // 記住的位置照同一條規則擺（換螢幕：同一個位移，再照 44pt 的規則）；比例上限照範圍大小（整個框放得進範圍）。
        var dragged = P.standard
        dragged.offset = P.offset(of: mostlyOut, reference: visible)
        let replayed = dragged.box(standard: base, reference: visible, bounds: visible)
        let other = CGRect(x: 1_440, y: 0, width: 1_280, height: 1_000)
        let elsewhere = dragged.box(standard: floatingStandard(.outerPortrait, in: other), reference: other, bounds: other)
        check(replayed == mostlyOut && P.isGrabbable(elsewhere, in: other)
              && abs((elsewhere.maxX - other.maxX) - (mostlyOut.maxX - visible.maxX)) < 0.001,
              "D20 a remembered place is laid out by the same rule (the same offset on another screen, then 44pt of the top bar inside)",
              "replayed=\(replayed) elsewhere=\(elsewhere)")
        // 停靠框：主視窗整個內容區都能放、可以蓋到輸入框（使用者自己放的就尊重）；預設的擺法照舊避開輸入框。
        let content = CGRect(x: 100, y: 100, width: 1_200, height: 800)
        let composer = CGRect(x: 300, y: 100, width: 700, height: 150)
        let docked = GlobalDMDockLayout.place(content: content, composer: composer, mode: .chat, boxOpen: true,
                                              boxSize: GlobalDMForm.outerPortrait.size)
        if let standard = docked.box {
            let over = CGRect(x: 500, y: 110, width: standard.width, height: standard.height)
            var placed = P.standard
            placed.offset = P.offset(of: over, reference: content)
            let laid = placed.box(standard: standard, reference: content, bounds: content)
            check(laid == over && GlobalDMDockLayout.overlaps(laid, composer) && !GlobalDMDockLayout.overlaps(standard, composer),
                  "D20 the docked box can go anywhere in the main window's content, over the composer too (the user put it there); the default place still keeps clear of the composer",
                  "laid=\(laid) standard=\(standard)")
        } else {
            check(false, "D20 the docked box can go anywhere in the main window's content, over the composer too (the user put it there); the default place still keeps clear of the composer", "no docked box")
        }

        // D21 記住：浮動、停靠、圓鈕模式各一份（{dx, dy, scale}），重開還在；回到預設＝拿掉那一份的記錄。
        let defaults = freshDefaults("gripPlacement")
        let saved = GlobalDMDeskSettings(defaults: defaults)
        var zoomed = P.standard
        zoomed.scale = 1.2
        var besideBubble = P.standard
        besideBubble.offset = CGSize(width: -80, height: 60)
        besideBubble.scale = 0.9
        saved.savePlacement(dragged, for: .floating)
        saved.savePlacement(zoomed, for: .docked)
        saved.saveBubblePlacement(besideBubble)
        let reopened = GlobalDMDeskSettings(defaults: defaults)
        let restored = reopened.placement(.floating) == dragged && reopened.placement(.docked) == zoomed && reopened.bubblePlacement == besideBubble
        reopened.saveBubblePlacement(.standard)
        let again = GlobalDMDeskSettings(defaults: defaults)
        check(restored && again.bubblePlacement.isStandard && again.placement(.floating) == dragged
              && defaults.object(forKey: GlobalDMDeskSettings.bubblePlacementKey) == nil,
              "D21 remembered per box — floating, docked and the desktop-bubble box apart ({dx, dy, scale}) — across relaunches; back to default removes only that record")

        // D22 兩個角等比縮放：拖哪個角那個角跟著滑鼠（投影到對角線上）、對角不動；右上角拉＝左下角不動、左下角拉＝右上角不動；
        // 比例夾在 0.7–1.3、上限受範圍大小（右上角拉時再受上緣）限制；形態的比例不變。
        let roomy = CGRect(x: 0, y: 0, width: 2_560, height: 1_400)
        let start = CGRect(x: 1_200, y: 200, width: base.width, height: base.height)
        let along = CGSize(width: base.width * 0.2, height: base.height * 0.2)
        let up = P.resized(start, corner: .topRight, base: base.size, by: along, area: roomy)
        let down = P.resized(start, corner: .bottomLeft, base: base.size, by: CGSize(width: -along.width, height: -along.height), area: roomy)
        let offAxis = P.resized(start, corner: .topRight, base: base.size, by: CGSize(width: base.width * 0.2 + 30, height: base.height * 0.2 - 30 * base.width / base.height), area: roomy)
        let tiny = P.resized(start, corner: .topRight, base: base.size, by: CGSize(width: -5_000, height: -5_000), area: roomy)
        let huge = P.resized(start, corner: .bottomLeft, base: base.size, by: CGSize(width: -5_000, height: -5_000), area: roomy)
        let underTop = P.resized(CGRect(x: 1_200, y: roomy.maxY - base.height - 40, width: base.width, height: base.height), corner: .topRight,
                                 base: base.size, by: CGSize(width: 400, height: 400), area: roomy)
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        let topRightFollows = near(up.box.minX, start.minX) && near(up.box.minY, start.minY) && abs(up.scale - 1.2) < 0.001
            && near(up.box.maxX, start.maxX + along.width) && near(up.box.maxY, start.maxY + along.height)
        let bottomLeftFollows = near(down.box.maxX, start.maxX) && near(down.box.maxY, start.maxY) && abs(down.scale - 1.2) < 0.001
            && near(down.box.minX, start.minX - along.width) && near(down.box.minY, start.minY - along.height)
        let projected = abs(offAxis.scale - 1.2) < 0.001   // 偏離對角線的移動只算落在對角線上的那一段
        let clamped = abs(tiny.scale - P.minScale) < 0.001 && abs(huge.scale - P.maxScale) < 0.001
        let topLimited = underTop.box.maxY <= roomy.maxY + 0.5 && underTop.scale < 1.3
        let proportional = [up, down, tiny, huge].allSatisfy { abs($0.box.width / $0.box.height - base.width / base.height) < 0.01 }
        check(topRightFollows && bottomLeftFollows && projected && clamped && topLimited && proportional,
              "D22 two corners scale in proportion: the dragged corner follows the mouse (projected on the diagonal) and the opposite one stays — top-right drag keeps the bottom-left, bottom-left drag keeps the top-right; 0.7–1.3, capped by the area (and the top edge for the top-right corner)",
              "up=\(up) down=\(down) offAxis=\(offAxis.scale) tiny=\(tiny.scale) huge=\(huge.scale) underTop=\(underTop)")

        // D23 圓鈕模式：放開時蓋到圓鈕（含 12 的間隔）就往最近的一邊讓開；沒蓋到＝原樣；位置記成相對於圓鈕（圓鈕動了框跟著走）。
        let bubble = CGRect(x: 1_300, y: 60, width: 44, height: 44)
        let covering = CGRect(x: 1_000, y: 80, width: 466, height: 678)
        let bubbleGeometryBase = GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: GlobalDMForm.outerPortrait.size, visible: visible)
        let cleared = P.clearing(covering, bubble: bubble, in: roomy, fallback: bubbleGeometryBase)
        let apart = CGRect(x: 400, y: 200, width: 466, height: 678)
        var bubblePlaced = P.standard
        bubblePlaced.offset = P.offset(of: cleared, reference: bubble)
        let movedBubble = bubble.offsetBy(dx: -300, dy: 100)
        let followed = bubblePlaced.box(standard: bubbleGeometryBase, reference: movedBubble, bounds: roomy)
        check(!cleared.intersects(bubble.insetBy(dx: -12, dy: -12)) && abs(cleared.minY - (bubble.maxY + 12)) < 0.001
              && P.clearing(apart, bubble: bubble, in: roomy, fallback: bubbleGeometryBase) == apart
              && abs(followed.minX - (cleared.minX - 300)) < 0.001 && abs(followed.minY - (cleared.minY + 100)) < 0.001,
              "D23 desktop-bubble mode: a box dropped over the bubble (12pt gap) moves off it the shortest way; a box elsewhere stays; its place is kept relative to the bubble (moving the bubble moves the box)",
              "cleared=\(cleared) followed=\(followed)")

        // D23（G1b 第二輪，GPT-6 G1b 審查 #4）讓開之後照 44pt 的規則夾好照樣不疊：圓鈕在四個角、四邊的中間，框蓋在圓鈕上（一般的放法、
        // 只剩頂列在螢幕裡的放法）——結果一律不疊圓鈕（含 12 的間隔）、頂列至少 44pt 在範圍裡、跟「四個方向各自夾好再挑最短」一樣
        //（夾完還疊著的不算）。GPT-6 的例子：螢幕 1440×900、圓鈕在右下角、框只剩頂列＝往左讓 80（不是往下讓 56 又被推回來）。
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let form = GlobalDMForm.outerPortrait.size
        let spots: [(String, CGRect)] = [
            ("bottom-right", CGRect(x: 1_372, y: 0, width: 44, height: 44)), ("bottom-left", CGRect(x: 24, y: 0, width: 44, height: 44)),
            ("top-right", CGRect(x: 1_372, y: 856, width: 44, height: 44)), ("top-left", CGRect(x: 24, y: 856, width: 44, height: 44)),
            ("bottom", CGRect(x: 700, y: 0, width: 44, height: 44)), ("top", CGRect(x: 700, y: 856, width: 44, height: 44)),
            ("left", CGRect(x: 0, y: 400, width: 44, height: 44)), ("right", CGRect(x: 1_396, y: 400, width: 44, height: 44)),
        ]
        var clearNotes: [String] = [], clearOK = true
        for (name, spot) in spots {
            let zone = spot.insetBy(dx: -12, dy: -12)
            let fallback = GlobalDMDeskLayout.boxBeside(bubble: spot, wanted: form, visible: screen)
            let over = CGRect(x: spot.midX - form.width / 2, y: spot.midY - form.height / 2, width: form.width, height: form.height)
            let topBarOnly = CGRect(x: spot.midX - form.width / 2, y: screen.minY + 44 - form.height, width: form.width, height: form.height)
            for (kind, drop) in [("over", over), ("top-bar-only", topBarOnly)] {
                let result = P.clearing(drop, bubble: spot, in: screen, fallback: fallback)
                func isClear(_ rect: CGRect) -> Bool {
                    let hit = rect.intersection(zone)
                    return hit.isNull || hit.width <= 0.001 || hit.height <= 0.001
                }
                // 參考答案：照 44pt 夾好就不疊＝就是它；否則四個方向各自夾好、拿掉還疊著的、挑最短（位移＝左下角的距離）。
                let keptDrop = P.keepGrabbable(drop, in: screen)
                let moves = [CGSize(width: 0, height: zone.maxY - drop.minY), CGSize(width: 0, height: zone.minY - drop.maxY),
                             CGSize(width: zone.minX - drop.maxX, height: 0), CGSize(width: zone.maxX - drop.minX, height: 0)]
                let legal = moves.map { P.keepGrabbable(drop.offsetBy(dx: $0.width, dy: $0.height), in: screen) }.filter(isClear)
                let shortest = isClear(keptDrop) ? keptDrop
                    : legal.min { abs($0.minX - drop.minX) + abs($0.minY - drop.minY) < abs($1.minX - drop.minX) + abs($1.minY - drop.minY) }
                let ok = isClear(result) && P.isGrabbable(result, in: screen) && (shortest.map { $0 == result } ?? true)
                clearOK = clearOK && ok
                if !ok { clearNotes.append("\(name)/\(kind): result=\(result) shortest=\(String(describing: shortest))") }
            }
        }
        let example = P.clearing(CGRect(x: 974, y: -634, width: 466, height: 678), bubble: CGRect(x: 1_372, y: 0, width: 44, height: 44), in: screen,
                                 fallback: GlobalDMDeskLayout.boxBeside(bubble: CGRect(x: 1_372, y: 0, width: 44, height: 44), wanted: form, visible: screen))
        check(clearOK && example == CGRect(x: 894, y: -634, width: 466, height: 678),
              "D23 counterexample (GPT-6 G1b #4): bubble at each corner and edge, box dropped over it (also with only its top bar on screen) — it ends clear of the bubble (12pt gap), with 44pt of its top bar inside, by the shortest move that is still legal after the 44pt rule (GPT-6's case: 80pt left, not 56pt down and pushed back)",
              "example=\(example) \(clearNotes.prefix(4).joined(separator: "; "))")

        // D32（G1b 第二輪，GPT-6 G1b 審查 #2）框部分在範圍外時縮小：縮放途中就夾在合法的比例裡——每一格頂列都至少 44pt 在範圍裡、固定的角
        // 一個點都不動，放開（keepGrabbable）不用再推。四邊各一次：左（右上角縮）、下（右上角縮）、右（左下角縮）、上（上緣貼著範圍上緣，
        // 左下角縮：上緣是固定的角）；左邊剛好只剩 44pt（GPT-6 的例子）＝縮不下去、框原樣。
        let edges: [(String, CGRect, GlobalDMResizeCorner)] = [
            ("left 120pt", CGRect(x: 120 - form.width, y: 100, width: form.width, height: form.height), .topRight),
            ("left 44pt", CGRect(x: 44 - form.width, y: 100, width: form.width, height: form.height), .topRight),
            ("bottom 120pt", CGRect(x: 400, y: 120 - form.height, width: form.width, height: form.height), .topRight),
            ("right 120pt", CGRect(x: screen.maxX - 120, y: 100, width: form.width, height: form.height), .bottomLeft),
            ("top edge", CGRect(x: 400, y: screen.maxY - form.height, width: form.width, height: form.height), .bottomLeft),
        ]
        var edgeNotes: [String] = [], edgeOK = true
        for (name, start, corner) in edges {
            func fixed(_ r: CGRect) -> CGPoint { corner == .topRight ? CGPoint(x: r.minX, y: r.minY) : CGPoint(x: r.maxX, y: r.maxY) }
            var ok = true, last = start
            for step in 1...40 {
                let shrink = CGFloat(step) * 10
                let delta = corner == .topRight ? CGSize(width: -shrink * form.width / form.height, height: -shrink)
                    : CGSize(width: shrink * form.width / form.height, height: shrink)
                let r = P.resized(start, corner: corner, base: form, by: delta, area: screen, startScale: 1)
                ok = ok && P.isGrabbable(r.box, in: screen) && fixed(r.box) == fixed(start)
                last = r.box
            }
            ok = ok && P.keepGrabbable(last, in: screen) == last
            switch name {
            case "left 44pt": ok = ok && last == start
            case "top edge": ok = ok && abs(last.width - (form.width * P.minScale).rounded()) <= 1
            default: ok = ok && last.width < start.width - 20
            }
            edgeOK = edgeOK && ok
            edgeNotes.append("\(name): \(Int(last.minX)),\(Int(last.minY)) \(Int(last.width))×\(Int(last.height))\(ok ? "" : " ✗")")
        }
        check(edgeOK,
              "D32 counterexample (GPT-6 G1b #2): shrinking a box that is partly outside (left, bottom, right; top edge at the top) stays inside the legal scale range the whole time — every step keeps 44pt of the top bar inside and the fixed corner exactly where it was, so nothing is pushed on release; at exactly 44pt left it does not shrink at all",
              edgeNotes.joined(separator: "; "))
    }

    @MainActor static func gripEventChecks(_ check: Checker) {
        // D10 回到預設位置與大小：拖過或縮放過才出現在右鍵選單；按了照預設。
        let resets = HandsLocked(0)
        var actions = noopActions()
        actions.resetPlacement = { resets.update { $0 += 1 } }
        let movedMenu = GlobalDMMoreMenu.make(GlobalDMMoreMenuState(form: .outerPortrait, movedOrScaled: true), actions: actions)
        let plainMenu = GlobalDMMoreMenu.make(GlobalDMMoreMenuState(form: .outerPortrait), actions: actions)
        let item = movedMenu.items.first { $0.identifier?.rawValue == "tatwo.dm.more.resetPlacement" }
        if let item, let action = item.action, let target = item.target as? NSObject { _ = target.perform(action, with: item) }
        check(item?.title == "回到預設位置與大小" && resets.get() == 1
              && !plainMenu.items.contains { $0.identifier?.rawValue == "tatwo.dm.more.resetPlacement" },
              "D10 回到預設位置與大小 shows in the page circle's menu only after a drag or a resize, and resets it")

        // D8（G1b）抓取區的滑鼠：頂列按下＝交給原生的視窗拖曳（不走逐事件的 began／changed／ended）；角＝按下、拖、放開送給面板控制器
        //（螢幕座標的位移）；雙擊什麼都不做。
        let events = HandsLocked<[String]>([])
        let savedHandler = GlobalDMBoxGripView.handler, savedLocation = GlobalDMBoxGripView.location, savedDrag = GlobalDMBoxGripView.windowDrag
        defer {
            GlobalDMBoxGripView.handler = savedHandler
            GlobalDMBoxGripView.location = savedLocation
            GlobalDMBoxGripView.windowDrag = savedDrag
        }
        GlobalDMBoxGripView.handler = { kind, surface, phase in
            let text: String
            switch phase {
            case .began: text = "began"
            case .changed(let delta): text = "changed \(Int(delta.width)),\(Int(delta.height))"
            case .ended: text = "ended"
            }
            let name: String
            switch kind {
            case .move: name = "move"
            case .resize(let corner): name = corner.rawValue
            }
            events.update { $0.append("\(name) \(surface == .floating ? "floating" : "docked") \(text)") }
        }
        GlobalDMBoxGripView.windowDrag = { surface, event in
            events.update { $0.append("window drag \(surface == .floating ? "floating" : "docked") clicks=\(event.clickCount)") }
        }
        let script = HandsLocked<[NSPoint]>([NSPoint(x: 500, y: 300), NSPoint(x: 420, y: 360)])
        GlobalDMBoxGripView.location = { _ in script.get().first.map { first in script.update { $0.removeFirst() }; return first } ?? .zero }
        func mouse(_ type: NSEvent.EventType, clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: clicks, pressure: 1)
        }
        let move = GlobalDMBoxGripView(frame: NSRect(x: 0, y: 0, width: 200, height: 68))
        move.kind = .move
        let corner = GlobalDMBoxGripView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        corner.kind = .resize(.bottomLeft)
        corner.surface = .docked
        if let down = mouse(.leftMouseDown, clicks: 1), let drag = mouse(.leftMouseDragged, clicks: 1), let up = mouse(.leftMouseUp, clicks: 1),
           let double = mouse(.leftMouseDown, clicks: 2) {
            move.mouseDown(with: down)
            move.mouseDragged(with: drag)
            move.mouseUp(with: up)
            move.mouseDown(with: double)
            corner.mouseDown(with: down)
            corner.mouseDragged(with: drag)
            corner.mouseUp(with: up)
        }
        check(events.get() == ["window drag floating clicks=1", "bottomLeft docked began", "bottomLeft docked changed -80,60", "bottomLeft docked ended"]
              && !move.mouseDownCanMoveWindow && GlobalDMBoxGripView.identifier(.resize(.bottomLeft)) == "tatwo.dm.grip.resize.bottomLeft",
              "D8 (G1b) the top-bar grip hands a press to the system window drag (no per-event began/changed/ended); a corner turns press, drag and release into a screen-space resize for the panel controller; a double-click does nothing",
              "\(events.get())")
    }

    // MARK: - 真的面板

    /// 假的「視窗伺服器拖曳」：頂列的抓取區收到按下（真的 NSEvent）→ 面板控制器叫原生拖曳（正式＝performDrag）→ 這裡照 steps 一格一格
    /// 移動面板（跑 run loop，途中看存了沒、排版了沒），最後放開。
    @MainActor final class FakeWindowDrag {
        var steps: [CGSize] = []
        var called: [(window: NSWindow, event: NSEvent)] = []
        var during: (layouts: Int, saved: Bool, setFrames: Int)?
        var onStep: ((Int) -> Void)?
    }

    @MainActor static func nativeDrag(_ panels: GlobalDMPanelController, _ panel: GlobalDMPanel, surface: GlobalDMSurface, by steps: [CGSize],
                                      saved: @escaping () -> Bool, onStep: ((Int) -> Void)? = nil) -> FakeWindowDrag? {
        guard let canvas = panel.contentView as? GlobalDMPanelCanvas,
              let grip = DMBrowserPhoneAcceptance.views(GlobalDMBoxGripView.self, in: canvas.host)
                .first(where: { $0.kind == .move && !$0.isHiddenOrHasHiddenAncestor && $0.window === panel }) else { return nil }
        let fake = FakeWindowDrag()
        fake.steps = steps
        fake.onStep = onStep
        let savedDrag = GlobalDMPanelController.windowDrag, savedDown = GlobalDMPanelController.mouseIsDown
        let savedRoute = GlobalDMBoxGripView.windowDrag
        defer {
            GlobalDMPanelController.windowDrag = savedDrag
            GlobalDMPanelController.mouseIsDown = savedDown
            GlobalDMBoxGripView.windowDrag = savedRoute
        }
        // 抓取區按下去交給這個（自測的）面板控制器；它再叫「原生拖曳」（這裡換成假的視窗伺服器）。
        GlobalDMBoxGripView.windowDrag = { [weak panels] surface, event in panels?.beginWindowDrag(surface, event: event) }
        GlobalDMPanelController.mouseIsDown = { false }
        GlobalDMPanelController.windowDrag = { window, event in
            fake.called.append((window, event))
            let origin = window.frame.origin
            let layouts = canvas.host.layoutCount
            var savedMidway = false
            for (index, step) in fake.steps.enumerated() {
                window.setFrameOrigin(NSPoint(x: origin.x + step.width, y: origin.y + step.height))
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                fake.onStep?(index)
                savedMidway = savedMidway || saved()
            }
            fake.during = (canvas.host.layoutCount - layouts, savedMidway, 0)
        }
        let point = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return nil }
        grip.mouseDown(with: down)
        return fake
    }

    @MainActor static func gripRigChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        let store = GlobalDMStore(defaults: freshDefaults("gripRig"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("gripRigDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        panels.install()
        defer {
            store.close()
            panels.uninstall()
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true }
        guard let panel = panels.floatingPanelForTesting, panel.isVisible, let canvas = panel.contentView as? GlobalDMPanelCanvas,
              let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return check.skip("D24 真的面板：這個環境開不出浮動框（沒有畫面環境）")
        }
        panel.alphaValue = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let margin = GlobalDMLayout.margin
        func box() -> NSRect { panel.frame.insetBy(dx: margin, dy: margin) }

        // D24 原生拖曳的路徑（注入事件）：頂列的抓取區收到按下 → 面板控制器叫原生拖曳（拿到這個面板與這一下按下）；拖的途中面板就在
        // 視窗伺服器放的地方（控制器不逐事件擺、SwiftUI 不排版）、還沒存；放開才存，框留在放的地方。
        let start = box()
        let steps = (1...10).map { CGSize(width: CGFloat(-30 * $0), height: CGFloat(12 * $0)) }
        var framesMatched = true
        let fake = nativeDrag(panels, panel, surface: .floating, by: steps, saved: { settings.placement(.floating).offset != nil }) { index in
            let expected = start.offsetBy(dx: steps[index].width, dy: steps[index].height)
            panels.reconcile()   // 途中有整理也不動它（拖著的面板由視窗伺服器管）
            framesMatched = framesMatched && box() == expected
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let dropped = start.offsetBy(dx: -300, dy: 120)
        let savedOffset = settings.placement(.floating).offset
        check(fake?.called.count == 1 && fake?.called.first?.window === panel && fake?.called.first?.event.type == .leftMouseDown
              && framesMatched && fake?.during?.layouts == 0 && fake?.during?.saved == false
              && box() == dropped && savedOffset != nil && !panels.isGrippingForTesting,
              "D24 the native drag path (injected press on the top-bar grip): the press goes to the system window drag for this panel; while dragging the panel is exactly where the window server puts it (no per-event placing, no SwiftUI layout, nothing saved), and on release the place is saved and the box stays there",
              "called=\(fake?.called.count ?? -1) matched=\(framesMatched) during=\(String(describing: fake?.during)) box=\(box()) dropped=\(dropped) saved=\(String(describing: savedOffset))")

        // D25 範圍（真的面板）：拖到大半在螢幕外（頂列留 60pt）＝留著；整個拖出去＝放開後短動畫推回剛好 44pt。
        let toEdge = CGSize(width: visible.maxX - 60 - box().minX, height: 0)
        _ = nativeDrag(panels, panel, surface: .floating, by: [CGSize(width: toEdge.width / 2, height: 0), toEdge], saved: { false })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let edge = panels.lastDrop
        let keptOut = edge.map { $0.landed == $0.dropped } ?? false
        let outAt = box()
        _ = nativeDrag(panels, panel, surface: .floating, by: [CGSize(width: 3_000, height: 0)], saved: { false })
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let pulled = panels.lastDrop
        let pulledBack = pulled.map { abs($0.landed.minX - (visible.maxX - 44)) < 0.5 && $0.landed != $0.dropped } ?? false
        check(keptOut && abs(outAt.minX - (visible.maxX - 60)) < 0.5 && pulledBack && abs(box().minX - (visible.maxX - 44)) < 1,
              "D25 on a real floating panel the box can sit mostly off-screen as long as 44pt of its top bar is on it; dragged fully out it slides back to exactly 44pt after release",
              "edge=\(String(describing: edge)) pulled=\(String(describing: pulled)) now=\(box())")
        panels.resetPlacement(.floating)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // D26 角的縮放（真的面板）：右上角拉＝左下角不動、左下角拉＝右上角不動；途中是快照預覽（圖層台在、真的框透明度 0、不排版、面板不逐事件換大小），
        // 放開才照新大小排一次、存比例。量：預覽每一次事件多久、放開排一次版多久（逐格排版要多久）。
        let before = box()
        let beganAt = canvas.host.layoutCount
        panels.handleGrip(.resize(.topRight), surface: .floating, phase: .began)
        // 按下那一刻拍一張（拍的時候藏配對碼、原生頁，可能排一次版）不算「途中」；途中＝之後每一次拖動事件。
        let startLayouts = canvas.host.layoutCount - beganAt
        let layouts = canvas.host.layoutCount
        let canvasFrame = panel.frame
        var previewOK = canvas.stage != nil && canvas.host.alphaValue == 0
        let base = GlobalDMForm.outerPortrait.size
        for index in 1...12 {
            let grow = CGFloat(index) * 6
            panels.handleGrip(.resize(.topRight), surface: .floating, phase: .changed(CGSize(width: grow * base.width / base.height, height: grow)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            if let shown = canvas.stage?.presentedBox {
                previewOK = previewOK && abs(shown.minX - before.minX) < 0.5 && abs(shown.minY - before.minY) < 0.5 && panel.frame == canvasFrame
            } else {
                previewOK = false
            }
        }
        let duringLayouts = canvas.host.layoutCount - layouts
        let releaseStart = CACurrentMediaTime()
        panels.handleGrip(.resize(.topRight), surface: .floating, phase: .ended)
        let releaseMs = (CACurrentMediaTime() - releaseStart) * 1000
        let grown = box()
        let topRightOK = abs(grown.minX - before.minX) < 0.5 && abs(grown.minY - before.minY) < 0.5 && grown.height > before.height + 60
            && canvas.stage == nil && canvas.host.alphaValue == 1 && settings.placement(.floating).scale > 1.1
        let grownLayouts = canvas.host.layoutCount - layouts - duringLayouts
        panels.handleGrip(.resize(.bottomLeft), surface: .floating, phase: .began)
        panels.handleGrip(.resize(.bottomLeft), surface: .floating, phase: .changed(CGSize(width: 40 * base.width / base.height, height: 40)))
        panels.handleGrip(.resize(.bottomLeft), surface: .floating, phase: .ended)
        let shrunk = box()
        let bottomLeftOK = abs(shrunk.maxX - grown.maxX) < 0.5 && abs(shrunk.maxY - grown.maxY) < 0.5 && shrunk.height < grown.height - 30
        let perEvent = panels.resizeEvents > 0 ? panels.resizeEventCost / Double(panels.resizeEvents) * 1000 : -1
        print("W184FORMS NOTE D26 resize preview: start \(String(format: "%.1f", panels.lastResizeStartCost * 1000))ms, per event \(String(format: "%.3f", perEvent))ms over \(panels.resizeEvents) events, release (one layout at the new size) \(String(format: "%.1f", releaseMs))ms")
        check(previewOK && duringLayouts == 0 && grownLayouts >= 1 && topRightOK && bottomLeftOK && perEvent >= 0 && perEvent < 2,
              "D26 corner resize on a real panel: dragging the top-right corner keeps the bottom-left, dragging the bottom-left keeps the top-right; while dragging it is a snapshot preview (layer stage, real box at opacity 0, no SwiftUI layout, the panel not resized per event, under 2ms per event), laid out once at the new size on release and the scale saved",
              "preview=\(previewOK) start=\(startLayouts) during=\(duringLayouts) after=\(grownLayouts) before=\(before) grown=\(grown) shrunk=\(shrunk) perEvent=\(perEvent)")
        panels.resetPlacement(.floating)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // D33（G1b 第二輪，GPT-6 G1b 審查 #2）真的面板：框拖到左邊、下面、右邊只剩 120pt 在螢幕裡，再從角一路縮到底——縮放途中就停在
        // 「頂列還有 44pt」的地方；放開時固定的角一個點都不動（不再被 44pt 的規則推走 140pt）、就是預覽的最後一格。
        var jumpNotes: [String] = [], jumpOK = true
        let size0 = box().size
        let edgeSpots: [(String, CGPoint, GlobalDMResizeCorner)] = [
            ("left", CGPoint(x: visible.minX + 120 - size0.width, y: visible.minY + 100), .topRight),
            ("bottom", CGPoint(x: visible.minX + 300, y: visible.minY + 120 - size0.height), .topRight),
            ("right", CGPoint(x: visible.maxX - 120, y: visible.minY + 100), .bottomLeft),
        ]
        for (name, origin, corner) in edgeSpots {
            let from = box()
            _ = nativeDrag(panels, panel, surface: .floating, by: [CGSize(width: origin.x - from.minX, height: origin.y - from.minY)], saved: { false })
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let placed = box()
            func fixed(_ r: NSRect) -> CGPoint { corner == .topRight ? CGPoint(x: r.minX, y: r.minY) : CGPoint(x: r.maxX, y: r.maxY) }
            panels.handleGrip(.resize(corner), surface: .floating, phase: .began)
            var grabbableAll = true
            for index in 1...20 {
                let shrink = CGFloat(index) * 20
                let delta = corner == .topRight ? CGSize(width: -shrink * size0.width / size0.height, height: -shrink)
                    : CGSize(width: shrink * size0.width / size0.height, height: shrink)
                panels.handleGrip(.resize(corner), surface: .floating, phase: .changed(delta))
                if let shown = canvas.stage?.modelBox { grabbableAll = grabbableAll && GlobalDMBoxPlacement.isGrabbable(shown, in: visible) }
            }
            let previewed = canvas.stage?.modelBox ?? .zero
            panels.handleGrip(.resize(corner), surface: .floating, phase: .ended)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let after = box()
            let ok = grabbableAll && abs(fixed(after).x - fixed(placed).x) < 0.5 && abs(fixed(after).y - fixed(placed).y) < 0.5
                && same(after, previewed, 0.5) && GlobalDMBoxPlacement.isGrabbable(after, in: visible) && after.width < placed.width - 20
            jumpOK = jumpOK && ok
            jumpNotes.append("\(name): placed=\(placed) previewed=\(previewed) after=\(after)\(ok ? "" : " ✗")")
            panels.resetPlacement(.floating)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        check(jumpOK,
              "D33 counterexample (GPT-6 G1b #2) on a real floating panel: a box dragged mostly off the left, bottom or right edge (120pt left) and then shrunk from a corner stops where 44pt of its top bar is still inside, every preview frame included; on release the fixed corner has not moved at all (no push afterwards) and the box is the last preview",
              jumpNotes.joined(separator: "; "))

        // D16（G1b）：拖著的時候換形態＝放開才照新形態擺在放的地方（拖的途中不換畫布、不跟視窗伺服器搶）；拖著的時候收框＝放開照樣存。
        let formStart = box()
        var formChangedMidway = false
        _ = nativeDrag(panels, panel, surface: .floating, by: [CGSize(width: -120, height: 40), CGSize(width: -200, height: 60)], saved: { false }) { index in
            guard index == 0 else { return }
            let from = settings.form
            settings.form = .innerLandscape
            panels.applyForm(.between(from, .innerLandscape))
            formChangedMidway = !panels.formMotion.isAnimating && canvas.stage == nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let afterForm = box()
        let placedAfter = panels.placedPanelFrameForTesting()?.insetBy(dx: margin, dy: margin) ?? .zero
        check(formChangedMidway && abs(afterForm.maxX - (formStart.maxX - 200)) < 1 && abs(afterForm.minY - (formStart.minY + 60)) < 1
              && abs(afterForm.width - placedAfter.width) < 1 && afterForm.width > formStart.width + 100,
              "D16 counterexample (G1b): a form change while the window server drags the box does not start a slide under it; on release the new form is laid out where the box was dropped (bottom-right corner kept)",
              "midway=\(formChangedMidway) start=\(formStart) after=\(afterForm)")
        settings.form = .outerPortrait
        panels.applyForm(.between(.innerLandscape, .outerPortrait, animated: false))
        panels.resetPlacement(.floating)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // D27 桌面圓鈕模式：預設開在圓鈕旁；拖得動（原生拖曳），存在圓鈕那一份（相對於圓鈕）；圓鈕動了框跟著走；放到蓋住圓鈕＝讓開一點；
        // 角的縮放也存在那一份；回到預設位置與大小＝回到開在圓鈕旁。
        var bubble = NSRect(x: visible.maxX - 24 - 44, y: visible.minY + 24, width: 44, height: 44)
        panels.floatingAnchor = { bubble }
        defer { panels.floatingAnchor = nil }
        panels.reconcile()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let beside = box()
        let besideOK = !beside.intersects(bubble) && settings.bubblePlacement.isStandard
        _ = nativeDrag(panels, panel, surface: .floating, by: [CGSize(width: -250, height: 80)], saved: { false })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let movedInBubble = box()
        let bubbleSaved = settings.bubblePlacement.offset != nil && settings.placement(.floating).offset == nil
        bubble = bubble.offsetBy(dx: -40, dy: 30)
        panels.reconcile()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let followed = box()
        let follows = abs(followed.minX - (movedInBubble.minX - 40)) < 1 && abs(followed.minY - (movedInBubble.minY + 30)) < 1
        let onto = CGSize(width: bubble.midX - followed.midX, height: bubble.midY - followed.minY - 20)
        _ = nativeDrag(panels, panel, surface: .floating, by: [onto], saved: { false })
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let clearedBox = box()
        let clearsBubble = !clearedBox.intersects(bubble.insetBy(dx: -11.5, dy: -11.5))
        panels.handleGrip(.resize(.topRight), surface: .floating, phase: .began)
        panels.handleGrip(.resize(.topRight), surface: .floating, phase: .changed(CGSize(width: 30, height: 40)))
        panels.handleGrip(.resize(.topRight), surface: .floating, phase: .ended)
        let bubbleScaled = abs(settings.bubblePlacement.scale - 1) > 0.01 && abs(settings.placement(.floating).scale - 1) < 0.001
        panels.resetPlacement(.floating)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let backBeside = box()
        check(besideOK && bubbleSaved && follows && clearsBubble && bubbleScaled && settings.bubblePlacement.isStandard && !backBeside.intersects(bubble),
              "D27 desktop-bubble mode: the box opens beside the bubble, can be dragged (native drag) and is remembered apart (relative to the bubble), follows the bubble, steps aside when dropped over it, keeps its own scale; 回到預設位置與大小 puts it back beside the bubble",
              "beside=\(besideOK) saved=\(bubbleSaved) follows=\(follows) cleared=\(clearedBox) bubble=\(bubble) scaled=\(bubbleScaled) back=\(backBeside)")

        // D27（G1b 第二輪，GPT-6 G1b 審查 #4）真的面板：圓鈕貼在螢幕右下角，把框拖到只剩頂列在螢幕裡、又疊著圓鈕——放開後不疊圓鈕
        //（含 12 的間隔：圓鈕的層級比框高，疊到的那一塊點不到框）、頂列至少 44pt 在螢幕裡。
        bubble = NSRect(x: visible.maxX - 24 - 44, y: visible.minY, width: 44, height: 44)
        panels.reconcile()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let beforeEdge = box()
        let edgeTarget = CGPoint(x: bubble.midX - beforeEdge.width / 2, y: visible.minY + 44 - beforeEdge.height)
        _ = nativeDrag(panels, panel, surface: .floating, by: [CGSize(width: edgeTarget.x - beforeEdge.minX, height: edgeTarget.y - beforeEdge.minY)], saved: { false })
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let edgeDrop = panels.lastDrop
        let edgeBox = box()
        let edgeClear = !edgeBox.intersects(bubble.insetBy(dx: -11.5, dy: -11.5)) && GlobalDMBoxPlacement.isGrabbable(edgeBox, in: visible)
            && edgeDrop.map { $0.landed == edgeBox && $0.key == .bubble } == true
        check(edgeClear,
              "D27 counterexample (GPT-6 G1b #4) on a real panel: the bubble in the bottom-right corner, the box dropped with only its top bar on screen and over the bubble — after release it is clear of the bubble (12pt gap) with 44pt of its top bar on screen",
              "bubble=\(bubble) drop=\(String(describing: edgeDrop)) box=\(edgeBox)")
        panels.resetPlacement(.floating)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // D31（G1b 第二輪，GPT-6 G1b 審查 #1）途中換模式：圓鈕模式拖到一半恢復主視窗（圓鈕不見）＝這次拖曳照開始那一份（圓鈕那一份、
        // 相對於那一刻的圓鈕）存下換模式那一刻的位置，浮動框那一份不動；反過來（一般模式拖到一半縮成圓鈕）＝存在浮動框那一份、圓鈕那一份不動；
        // 之後的放開什麼都不做。
        var anchor: NSRect? = NSRect(x: visible.maxX - 24 - 44, y: visible.minY + 24, width: 44, height: 44)
        let fixedBubble = anchor!
        panels.floatingAnchor = { anchor }
        settings.saveBubblePlacement(.standard)
        settings.savePlacement(.standard, for: .floating)
        panels.reconcile()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var atSwitch = NSRect.zero
        _ = nativeDrag(panels, panel, surface: .floating, by: [CGSize(width: -220, height: 70), CGSize(width: -300, height: 110)], saved: { false }) { index in
            guard index == 0 else { return }
            atSwitch = box()
            anchor = nil   // 恢復主視窗：圓鈕不見了
            panels.reconcile()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let toBubbleDrop = panels.lastDrop
        let bubbleOffset = settings.bubblePlacement.offset
        let expectedBubble = GlobalDMBoxPlacement.offset(of: atSwitch, reference: fixedBubble)
        let bubbleKept = toBubbleDrop.map { $0.key == .bubble && $0.reason == "mode" } == true
            && bubbleOffset.map { abs($0.width - expectedBubble.width) < 0.5 && abs($0.height - expectedBubble.height) < 0.5 } == true
            && settings.placement(.floating).isStandard
        settings.saveBubblePlacement(.standard)
        settings.savePlacement(.standard, for: .floating)
        panels.reconcile()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var atSwitchBack = NSRect.zero
        _ = nativeDrag(panels, panel, surface: .floating, by: [CGSize(width: -180, height: 50), CGSize(width: -260, height: 80)], saved: { false }) { index in
            guard index == 0 else { return }
            atSwitchBack = box()
            anchor = fixedBubble   // 縮成圓鈕
            panels.reconcile()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let toFloatingDrop = panels.lastDrop
        let floatingOffset = settings.placement(.floating).offset
        let expectedFloating = GlobalDMBoxPlacement.offset(of: atSwitchBack, reference: visible)
        let floatingKept = toFloatingDrop.map { $0.key == .floating && $0.reason == "mode" } == true
            && floatingOffset.map { abs($0.width - expectedFloating.width) < 0.5 && abs($0.height - expectedFloating.height) < 0.5 } == true
            && settings.bubblePlacement.isStandard
        check(bubbleKept && floatingKept,
              "D31 counterexample (GPT-6 G1b #1) mode switch mid-drag: a drag started in desktop-bubble mode that sees the main window come back mid-way is saved in the bubble record (where the box was at the switch, relative to that bubble) and the floating record is untouched; the other way round saves only the floating record; the later release does nothing",
              "toBubble=\(String(describing: toBubbleDrop)) bubbleOffset=\(String(describing: bubbleOffset)) want=\(expectedBubble) floating=\(settings.placement(.floating)); toFloating=\(String(describing: toFloatingDrop)) floatingOffset=\(String(describing: floatingOffset)) want=\(expectedFloating) bubbleRecord=\(settings.bubblePlacement)")
        settings.saveBubblePlacement(.standard)
        settings.savePlacement(.standard, for: .floating)
        panels.floatingAnchor = nil
        panels.reconcile()
    }

    // MARK: - 真的桌面圓鈕（G1b 第二輪，GPT-6 G1b 審查 #6）

    /// D30：真的桌面控制器縮成圓鈕，對它建的那一顆 GlobalDMBubbleView 送按下、移動、放開（滑鼠位置由自測給；選單不真的跳出來）：
    /// 移動沒超過 3pt＝只算點一下（框打開、圓鈕的位置不動）；超過＝只存位置（圓鈕跟著走、記住的位置換了、框不打開）；
    /// 按住 0.55 秒跳出選單之後放開＝不算點、不算放。
    @MainActor static func bubbleEventChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        guard let main = mainWindow() else { return check.skip("D30 桌面圓鈕：這個環境沒有螢幕") }
        defer { main.orderOut(nil) }
        let store = GlobalDMStore(defaults: freshDefaults("bubbleEvents"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("bubbleEventsDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        let browser = DMBrowser(store: store, openBox: {}, pageHost: DMBrowserAcceptance.FakeWebHost(), podPage: { nil })
        let desk = GlobalDMDeskController(store: store, settings: settings, hotkeys: GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend()),
                                          panels: panels, duo: GlobalDMDuo(defaults: nil), browser: browser)
        panels.install()
        desk.install()
        let savedLocation = GlobalDMBubbleView.mouseLocation, savedMenu = GlobalDMBubbleView.presentMenu
        let menus = HandsLocked(0)
        var pointer = NSPoint(x: 400, y: 300)
        GlobalDMBubbleView.mouseLocation = { pointer }
        GlobalDMBubbleView.presentMenu = { _, _, _, _ in menus.update { $0 += 1 } }
        defer {
            GlobalDMBubbleView.mouseLocation = savedLocation
            GlobalDMBubbleView.presentMenu = savedMenu
            if desk.isCollapsed { desk.restore() }
            store.close()
            desk.uninstall()
            panels.uninstall()
        }
        desk.collapse()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard desk.isCollapsed,
              let bubblePanel = NSApp.windows.first(where: { $0.accessibilityIdentifier() == "tatwo.dm.desk.bubblePanel" && $0.isVisible }),
              let view = bubblePanel.contentView as? GlobalDMBubbleView else {
            return check.skip("D30 桌面圓鈕：這個環境縮不成圓鈕（沒有畫面環境）")
        }
        bubblePanel.alphaValue = 0
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: bubblePanel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        /// 按下 → 照 moves 一格一格移動（每一格是相對於按下的位移）→ 放開。
        func press(moves: [CGSize], hold: Double = 0) async {
            let start = pointer
            guard let down = mouse(.leftMouseDown), let drag = mouse(.leftMouseDragged), let up = mouse(.leftMouseUp) else { return }
            view.mouseDown(with: down)
            if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) }
            for move in moves {
                pointer = NSPoint(x: start.x + move.width, y: start.y + move.height)
                view.mouseDragged(with: drag)
            }
            view.mouseUp(with: up)
            pointer = start
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        // 1. 點一下（移動 2pt，沒超過 3pt 的門檻）＝框打開、圓鈕不動、記住的位置不變。
        let frame0 = bubblePanel.frame, origin0 = settings.bubbleOrigin
        await press(moves: [CGSize(width: 1, height: 1), CGSize(width: 2, height: 0)])
        let clicked = store.isFloatingOpen && bubblePanel.frame == frame0 && settings.bubbleOrigin == origin0
        // 2. 拖（移動 60,40）＝只存位置：圓鈕跟著走、記住的位置換成放的地方、框不打開。
        store.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        await press(moves: [CGSize(width: 20, height: 10), CGSize(width: -60, height: 40)])
        let moved = bubblePanel.frame
        let dropped = !store.isFloatingOpen && abs(moved.minX - (frame0.minX - 60)) < 1 && abs(moved.minY - (frame0.minY + 40)) < 1
            && settings.bubbleOrigin.map { abs($0.x - (moved.minX + GlobalDMLayout.margin)) < 1 && abs($0.y - (moved.minY + GlobalDMLayout.margin)) < 1 } == true
        // 3. 按住 0.7 秒（選單在 0.55 秒跳出來）再放開＝不算點（框不打開）、不算放（位置不變）。
        let origin1 = settings.bubbleOrigin, frame1 = bubblePanel.frame
        await press(moves: [], hold: 0.7)
        let held = menus.get() == 1 && !store.isFloatingOpen && settings.bubbleOrigin == origin1 && bubblePanel.frame == frame1
        check(clicked && dropped && held,
              "D30 (GPT-6 G1b #6) the real desktop bubble (made by the desk controller) given press, move and release: under the 3pt threshold it is only a click (the box opens, the bubble stays, nothing saved); past it only the place is saved (the bubble follows, the remembered origin is where it was dropped, the box does not open); a long press opens the menu and the release after it is neither a click nor a drop",
              "clicked=\(clicked) dropped=\(dropped) held=\(held) menus=\(menus.get()) frame0=\(frame0) moved=\(moved) origin=\(String(describing: settings.bubbleOrigin)) open=\(store.isFloatingOpen)")
    }

    // MARK: - 抓取區、角標、游標（四種形態；W184 AB：沒有小把手）

    @MainActor static func gripMarkChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) {
        let store = GlobalDMStore(defaults: freshDefaults("gripMarks"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        defer { store.close() }
        var problems: [String] = [], checked = 0
        for form in GlobalDMForm.allCases {
            let size = form.size
            let host = NSHostingView(rootView: GlobalDMPhoneBox(store: store, model: model, surface: .floating, form: form)
                .frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            let grips = DMBrowserPhoneAcceptance.views(GlobalDMBoxGripView.self, in: host)
            func frame(_ view: NSView) -> CGRect {   // 框的座標，左上原點
                let rect = host.convert(view.bounds, from: view)
                return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            }
            let topRight = grips.first { $0.kind == .resize(.topRight) }, bottomLeft = grips.first { $0.kind == .resize(.bottomLeft) }
            let move = grips.first { $0.kind == .move }
            let side = GlobalDMBoxGrip.cornerSize
            if let topRight {
                let rect = frame(topRight)
                if abs(rect.maxX - size.width) > 0.5 || abs(rect.minY) > 0.5 || abs(rect.width - side) > 0.5 { problems.append("\(form.rawValue) top-right at \(rect)") }
            } else { problems.append("\(form.rawValue) no top-right grip") }
            if let bottomLeft {
                let rect = frame(bottomLeft)
                if abs(rect.minX) > 0.5 || abs(rect.maxY - size.height) > 0.5 || abs(rect.width - side) > 0.5 { problems.append("\(form.rawValue) bottom-left at \(rect)") }
            } else { problems.append("\(form.rawValue) no bottom-left grip") }
            if let move {
                let rect = frame(move)
                if abs(rect.minY) > 0.5 || rect.width < size.width - 1 { problems.append("\(form.rawValue) move grip at \(rect)") }
            } else { problems.append("\(form.rawValue) no move grip") }
            // 角標：跟框同心（圓心離框的角各 52）、滑到那一圈才出現；只接那一圈的點擊（輸入框、＋鈕那一塊不接）。
            for grip in [topRight, bottomLeft].compactMap({ $0 }) {
                guard let corner = grip.corner else { continue }
                let center = GlobalDMBoxGripView.cornerCenter(corner, size: grip.bounds.size)
                let boxCorner = corner == .topRight ? CGPoint(x: grip.bounds.width, y: grip.bounds.height) : .zero
                let concentric = abs(abs(boxCorner.x - center.x) - DMPhone.screenRadius) < 0.01 && abs(abs(boxCorner.y - center.y) - DMPhone.screenRadius) < 0.01
                let band = CGPoint(x: center.x + (corner == .topRight ? 1 : -1) * 48 / 1.414, y: center.y + (corner == .topRight ? 1 : -1) * 48 / 1.414)
                let inner = CGPoint(x: center.x + (corner == .topRight ? 1 : -1) * 20, y: center.y + (corner == .topRight ? 1 : -1) * 20)
                grip.hover(nil)
                let hiddenFirst = grip.mark.opacity == 0
                grip.hover(band)
                let shown = grip.mark.opacity == 1 && grip.isNearCorner
                let hitBand = GlobalDMBoxGripView.inCornerBand(band, corner: corner, size: grip.bounds.size)
                let missInner = !GlobalDMBoxGripView.inCornerBand(inner, corner: corner, size: grip.bounds.size)
                grip.hover(nil)
                if !(concentric && hiddenFirst && shown && hitBand && missInner && grip.mark.path != nil) {
                    problems.append("\(form.rawValue) \(corner.rawValue) mark concentric=\(concentric) hidden=\(hiddenFirst) shown=\(shown) band=\(hitBand) inner=\(missInner)")
                }
                // 游標：對角縮放（右上角＝右上、左下角＝左下）。
                if #available(macOS 15.0, *) {
                    let wanted = NSCursor.frameResize(position: corner == .topRight ? .topRight : .bottomLeft, directions: .all)
                    let same = grip.cursor === wanted || (grip.cursor.hotSpot == wanted.hotSpot
                        && grip.cursor.image.tiffRepresentation == wanted.image.tiffRepresentation)
                    if !same { problems.append("\(form.rawValue) \(corner.rawValue) cursor") }
                }
                checked += 1
            }
            if let move, move.cursor != .openHand { problems.append("\(form.rawValue) move cursor") }
            // W184 AB（使用者 09-30：「上方不要拖拽槓 不好看」）：頂列（倒放：上緣那一條）正中間原本小把手那一點跟旁邊一樣（沒有把手）；
            // 那一點照樣是頂列的抓取區（視窗從最外層往下找到的就是它：按下去照樣拖、游標是張開的手），滑到左上的圓鈕上不是。
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / size.width
                func luminance(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                    guard let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB) else { return -1 }
                    return 0.3 * color.redComponent + 0.59 * color.greenComponent + 0.11 * color.blueComponent
                }
                let middle = luminance(size.width / 2, 8.5), beside = luminance(size.width / 2 + 36, 8.5)
                if abs(middle - beside) >= 0.03 { problems.append("\(form.rawValue) something drawn where the handle was (\(middle) vs \(beside))") }
            }
            if let move {
                let middle = CGPoint(x: size.width / 2, y: size.height - 8.5)   // 視窗座標（左下原點）：頂列正中間、離上緣 8.5
                let circle = CGPoint(x: DMPhone.sideMargin(for: form) + DMPhone.touch / 2, y: size.height - DMPhone.headerTop - DMPhone.touch / 2)
                let blank = move.isBlank(at: middle)
                move.pointer(at: middle)
                let hand = move.showsHand
                let overCircle = form == .tent || !move.isBlank(at: circle)
                move.pointer(at: form == .tent ? nil : circle)
                let released = !move.showsHand
                move.pointer(at: nil)
                if !(blank && hand && overCircle && released) {
                    problems.append("\(form.rawValue) move blank=\(blank) hand=\(hand) circleCovered=\(overCircle) released=\(released)")
                }
            }
        }
        check(problems.isEmpty && checked == 8,
              "D28 in all four forms: the move grip spans the top bar (the tent: its top band) and draws nothing (W184 AB: no grab handle — the middle of the bar is plain, and the window's own hit test lands on the grip there, not on the page circle); 40×40 corner grips sit flush in the top-right and bottom-left corners; their marks are short arcs concentric with the 52 corner, shown only near the corner; only that band takes clicks (the composer and ＋ keep theirs)",
              problems.prefix(6).joined(separator: "; "))
        check(problems.filter { $0.contains("cursor") || $0.contains("hand=") }.isEmpty,
              "D29 cursors: open hand over the blank top bar — also when the panel is not the key window (mouse moved over the blank middle → open hand; onto the page circle or out → arrow) — closed while the window server drags; diagonal resize at the top-right and bottom-left corners",
              problems.filter { $0.contains("cursor") || $0.contains("hand=") }.prefix(4).joined(separator: "; "))
    }
}
#endif
