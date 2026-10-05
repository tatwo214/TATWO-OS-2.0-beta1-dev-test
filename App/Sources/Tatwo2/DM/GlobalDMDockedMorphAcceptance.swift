#if DEBUG
import AppKit
import QuartzCore

// W184 AB（使用者 09-30 在 MacBook 實測 .031：「停靠時主視窗裡的私訊鈕跟框同時存在」）：w184button 的「停靠」段——
// 真的主視窗（TatwoWorkOSWindow，看不見）、真的面板控制器；時鐘由自測推（dockedMorph 的 manualTime）：
// N0 框收著：圓鈕是主視窗的子視窗、看得到；N1 打開＝圓鈕藏起、外殼（跟主視窗同一層）從圓鈕長成框、框的內容後段才淡入、外殼在框後面；
// N2 框開著的每一格圓鈕都不在畫面上（中途整理也不會叫回來）；N3 收起＝內容先淡出（外殼墊在框下面）、收框、縮回圓鈕，到位才放回圓鈕
//（掛回主視窗）；N4 減少動態效果＝淡入淡出；N5 長到一半主視窗移動＝直接到位；N6 縮到一半按外殼＝長回去。
extension GlobalDMButtonMorphAcceptance {
    @MainActor static func dockedMorphChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        guard let main = GlobalDMFormsAcceptance.mainWindow() else { return check.skip("N0 停靠：這個環境沒有螢幕") }
        defer { main.orderOut(nil) }
        let store = GlobalDMStore(defaults: freshDefaults("dockMorph"), chatGPTAllowed: { true })
        store.isEnabled = true
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("dockMorphDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        panels.install()
        let morph = panels.dockedMorph
        let clock = Clock()
        morph.manualTime = true
        morph.clock = { clock.now }
        morph.reduceMotion = { false }
        defer {
            morph.cancel()
            store.close()
            panels.uninstall()
        }
        let margin = GlobalDMLayout.margin
        panels.reconcile()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.dockedButtonForTesting?.isVisible == true }
        guard let button = panels.dockedButtonForTesting, button.isVisible else {
            return check.skip("N0 停靠：這個環境掛不上主視窗的圓鈕（沒有畫面環境）")
        }
        func circle() -> CGRect { button.frame.insetBy(dx: margin, dy: margin) }
        check(button.parent === main && panels.dockedPanelForTesting?.isVisible != true && morph.phase == .idle,
              "N0 (W184 AB, user 09-30 on .031) docked box closed: the DM button shows in the main window (its child window), no box",
              "parent=\(button.parent === main) box=\(panels.dockedPanelForTesting?.isVisible == true) phase=\(morph.phase)")

        // N1、N2：打開＝從圓鈕長成框。
        let startCircle = circle()
        clock.now = 100
        store.openDocked()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.dockedPanelForTesting?.isVisible == true && morph.phase == .growing }
        guard let box = panels.dockedPanelForTesting, box.isVisible, morph.phase == .growing, let shell = morph.shell, let plan = morph.plan else {
            return check(false, "N1 opening the docked box from the button starts the grow", "phase=\(morph.phase) box=\(panels.dockedPanelForTesting?.isVisible == true)")
        }
        let target = box.frame.insetBy(dx: margin, dy: margin)
        var rects: [CGRect] = [], radii: [CGFloat] = [], issues: [String] = [], content: [Double: Float] = [:], order: [String] = []
        var together = false, orderUnknown = false
        for t in [0.0, 0.05, 0.12, 0.25, 0.44, 0.6] {
            clock.now = 100 + t
            morph.show(at: t)
            let rect = shell.presentedRect
            rects.append(rect)
            radii.append(shell.presentedRadius)
            content[t] = morph.presentedContent
            if !near(rect, plan.rect(at: t), 1) { issues.append("t=\(t) presented \(rect) model \(plan.rect(at: t))") }
            if button.isVisible, box.isVisible { together = true }
            switch isBehind(shell.panel, box) {
            case nil: orderUnknown = true
            case false?: order.append("t=\(t) shell in front of the box")
            case true?: break
            }
            if t == 0.12 {
                // 長到一半有別的整理：不重來、圓鈕照樣不出現。
                panels.reconcile()
                if morph.phase != .growing || morph.shell !== shell { issues.append("a reconcile mid-grow restarted or stopped it (phase=\(morph.phase))") }
                if button.isVisible { together = true }
            }
        }
        check(near(rects[0], startCircle, 1) && abs(radii[0] - 22) < 0.5 && shell.panel.level == .normal && issues.isEmpty,
              "N1 open: the docked button hides and the shell starts on it (its circle, radius 22), at the main window's level (.normal, not floating over other apps) — the layers run the model",
              "start=\(rects[0]) circle=\(startCircle) r=\(radii[0]) level=\(shell.panel.level.rawValue) \(issues.prefix(3))")
        check(approaches(rects, target) && near(rects.last ?? .zero, target, 1) && abs((radii.last ?? 0) - 52) < 0.5,
              "N1 open sampled at 0.05 / 0.12 / 0.25 / 0.44 / 0.6 s: the shell moves one way from the button to the docked box (≤1pt at 0.6 s), corner 22 → 52",
              "rects=\(describe(rects)) radii=\(radii.map { Int($0) })")
        let early = [0.05, 0.12, 0.25].map { content[$0] ?? 1 }, half = content[0.44] ?? 0, full = content[0.6] ?? 0
        check(early.allSatisfy { $0 < 0.01 } && half > 0.05 && half < 0.95 && full > 0.99,
              "N1 open: the docked box's content is transparent at 0.05 / 0.12 / 0.25 s, half in at 0.44 s and fully in at 0.6 s (the shell paints only paper, no picture of the box)",
              "early=\(early) 0.44=\(half) 0.6=\(full)")
        if orderUnknown {
            check.skip("N1 order：這個環境查不到視窗的前後順序")
        } else {
            check(order.isEmpty, "N1 order: at every sample the shell is behind the docked box (the content fades in over it)", "\(order)")
        }
        clock.now = 100.61
        morph.tick()
        settleUI()
        check(morph.phase == .idle && morph.shell == nil && !shell.panel.isVisible && morph.presentedContent > 0.99 && box.isVisible && !button.isVisible,
              "N1 once in place the shell is taken down; the docked box is fully visible; the button stays hidden",
              "phase=\(morph.phase) content=\(morph.presentedContent) button=\(button.isVisible)")
        panels.reconcile()
        settleUI()
        check(!together && !button.isVisible && box.isVisible,
              "N2 the docked button and the open docked box are never on screen together (every sample of the grow, a reconcile mid-grow and one after)",
              "together=\(together) button=\(button.isVisible)")

        // N3：收起＝內容先淡出、收框、縮回圓鈕。
        clock.now = 200
        store.isOpen = false   // store 改值的那一刻（willSet）dockedMorph.closing()：內容淡出、外殼墊在框下面
        let clearing = morph.phase == .clearing && morph.shell != nil
        var faded: [Float] = [], fadeTogether = false, shellUnder = true
        for t in [0.03, 0.08] {
            clock.now = 200 + t
            morph.show(at: t)
            faded.append(morph.presentedContent)
            if button.isVisible { fadeTogether = true }
            if let under = morph.shell.flatMap({ isBehind($0.panel, box) }), !under { shellUnder = false }
        }
        panels.reconcile()   // 淡出途中的整理：框照樣留著、圓鈕照樣不出現
        settleUI()
        let kept = box.isVisible && !button.isVisible && morph.phase == .clearing
        clock.now = 200 + GlobalDMMorphTiming.clearOut + 0.001
        morph.tick()   // 淡完：外殼開始縮、請面板控制器收框
        let shrinkStart = clock.now
        _ = await DMBrowserAcceptance.waitUntil(2) { !box.isVisible }
        guard morph.phase == .shrinking, let shrinkShell = morph.shell, let shrinkPlan = morph.plan else {
            return check(false, "N3 after the fade the shell shrinks into the button", "phase=\(morph.phase) box=\(box.isVisible)")
        }
        var shrinkRects: [CGRect] = [], buttonSeen = false
        for t in [0.05, 0.12, 0.25, 0.44] {
            clock.now = shrinkStart + t
            morph.show(at: t)
            shrinkRects.append(shrinkShell.presentedRect)
            if button.isVisible { buttonSeen = true }
        }
        let goal = circle()
        clock.now = shrinkStart + 0.61
        morph.tick()
        settleUI()
        check(clearing && faded.count == 2 && faded[0] > 0.05 && faded[0] < 0.95 && faded[1] < faded[0] && !fadeTogether && shellUnder && kept,
              "N3 close: the content fades out first (0.10 s: part-way at 0.03, less at 0.08) with the shell under the box; the button stays hidden; a reconcile mid-fade keeps the box",
              "clearing=\(clearing) faded=\(faded) together=\(fadeTogether) under=\(shellUnder) kept=\(kept)")
        check(!box.isVisible && near(shrinkPlan.target, goal, 0.5) && approaches(shrinkRects, goal) && !buttonSeen,
              "N3 close: after the fade the box is put away and the shell shrinks into the button's circle; the button stays hidden until it arrives",
              "rects=\(describe(shrinkRects)) goal=\(goal) seen=\(buttonSeen)")
        check(button.isVisible && button.parent === main && morph.phase == .idle && morph.shell == nil && !shrinkShell.panel.isVisible,
              "N3 close: when the shell arrives the button shows again, attached to the main window (it moves with it)",
              "button=\(button.isVisible) parent=\(button.parent === main) phase=\(morph.phase)")

        // N6：縮到一半按外殼＝點圓鈕（長回去）。
        clock.now = 300
        store.openDocked()
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .growing }
        clock.now = 300.61
        morph.tick()
        settleUI()
        clock.now = 310
        store.isOpen = false
        clock.now = 310 + GlobalDMMorphTiming.clearOut + 0.001
        morph.tick()
        let turnStart = clock.now
        _ = await DMBrowserAcceptance.waitUntil(2) { !box.isVisible }
        clock.now = turnStart + 0.12
        morph.show(at: 0.12)
        let pressed = morph.phase == .shrinking
        morph.shell?.view.onPress?()
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .growing && box.isVisible }
        let turned = morph.phase == .growing && store.isOpen && (morph.plan?.segments.count ?? 0) >= 2 && !button.isVisible
        clock.now = turnStart + 1.5
        morph.tick()
        settleUI()
        check(pressed && turned && morph.phase == .idle && box.isVisible && !button.isVisible,
              "N6 pressing the shrinking shell is pressing the button: the box opens again, growing back from where the shell is (same shell, turned), the button stays hidden",
              "pressed=\(pressed) turned=\(turned) phase=\(morph.phase) open=\(store.isOpen)")

        // N5：長到一半主視窗移動＝直接到位（外殼不是子視窗，不會跟著走）。
        store.isOpen = false
        clock.now = 400 + GlobalDMMorphTiming.clearOut + 0.001
        morph.tick()
        _ = await DMBrowserAcceptance.waitUntil(2) { !box.isVisible }
        clock.now = 402
        morph.tick()
        settleUI()
        clock.now = 500
        store.openDocked()
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .growing }
        clock.now = 500.1
        morph.show(at: 0.1)
        let growing = morph.phase == .growing
        main.setFrameOrigin(NSPoint(x: main.frame.minX + 30, y: main.frame.minY))
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .idle }
        settleUI()
        check(growing && morph.phase == .idle && morph.shell == nil && box.isVisible && !button.isVisible && morph.presentedContent > 0.99,
              "N5 the main window moving mid-grow puts it straight at its end (shell down, box fully shown, button hidden)",
              "growing=\(growing) phase=\(morph.phase) content=\(morph.presentedContent)")

        // N4：減少動態效果＝淡入淡出（不長不縮）。
        store.isOpen = false
        clock.now = 600 + GlobalDMMorphTiming.clearOut + 0.001
        morph.tick()
        _ = await DMBrowserAcceptance.waitUntil(2) { !box.isVisible }
        clock.now = 602
        morph.tick()
        settleUI()
        morph.reduceMotion = { true }
        clock.now = 700
        store.openDocked()
        _ = await DMBrowserAcceptance.waitUntil(2) { box.isVisible && morph.phase == .fadingIn }
        let fadeOpen = morph.phase == .fadingIn && morph.shell == nil && !button.isVisible
        clock.now = 700.07
        morph.show(at: 0.07)
        let fadeHalf = morph.presentedContent
        clock.now = 700.2
        morph.tick()
        settleUI()
        let fadeOpened = morph.phase == .idle && morph.presentedContent > 0.99 && !button.isVisible && box.isVisible
        check(fadeOpen && fadeHalf > 0.05 && fadeHalf < 0.95 && fadeOpened,
              "N4 reduce motion, open: no shell; the button hides and the docked box fades in (0.15 s)",
              "open=\(fadeOpen) half=\(fadeHalf) opened=\(fadeOpened)")
        clock.now = 800
        store.isOpen = false
        let fadeClearing = morph.phase == .clearing && morph.shell == nil && !button.isVisible
        clock.now = 800 + GlobalDMMorphTiming.reduceOut + 0.001
        morph.tick()
        _ = await DMBrowserAcceptance.waitUntil(2) { !box.isVisible }
        let buttonBack = button.isVisible && button.parent === main
        clock.now = 800 + GlobalDMMorphTiming.reduceOut + GlobalDMMorphTiming.reduceIn + 0.01
        morph.tick()
        settleUI()
        check(fadeClearing && buttonBack && button.isVisible && morph.phase == .idle && !box.isVisible,
              "N4 reduce motion, close: the box itself fades out (0.12 s) and is put away, then the button fades back in (attached to the main window)",
              "clearing=\(fadeClearing) back=\(buttonBack) phase=\(morph.phase) box=\(box.isVisible)")
        morph.reduceMotion = { false }

        // 第三輪（GPT-6 審查 #1–#4）：途中主視窗移動、只改寬度、切到別的桌面。
        /// 打開到停好（長到位）。
        func openSettled(at time: Double) async {
            clock.now = time
            store.openDocked()
            _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .growing }
            clock.now = time + 0.61
            morph.tick()
            settleUI()
        }
        /// 收到底（淡完、縮到位）。
        func closeSettled(at time: Double) async {
            clock.now = time
            store.isOpen = false
            clock.now = time + GlobalDMMorphTiming.clearOut + 0.001
            morph.tick()
            _ = await DMBrowserAcceptance.waitUntil(2) { !box.isVisible }
            clock.now = time + 2
            morph.tick()
            settleUI()
        }
        func clean() -> Bool {
            box.contentView.map { $0.alphaValue == 1 && $0.layer?.animation(forKey: GlobalDMButtonMorph.clearKey) == nil } ?? false
        }

        // N7（#1）：淡出途中移動主視窗＝這一次收框算完成：框收掉（不再掛在主視窗上）、內容透明度還原、圓鈕照新的位置出現；外殼、點擊區拆掉。
        await openSettled(at: 900)
        clock.now = 910
        store.isOpen = false
        let clearing7 = morph.phase == .clearing && box.isVisible
        clock.now = 910.05
        morph.show(at: 0.05)
        let origin7 = main.frame.origin
        main.setFrameOrigin(NSPoint(x: origin7.x + 40, y: origin7.y + 20))
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .idle && !box.isVisible }
        settleUI()
        let expected7 = panels.dockedButtonPlacementForTesting() ?? .null
        check(clearing7 && morph.phase == .idle && morph.shell == nil && morph.catcherPanel?.isVisible != true && !box.isVisible && box.parent == nil
              && clean() && button.isVisible && button.parent === main && near(button.frame, expected7, 0.5) && !store.isOpen,
              "N7 (GPT-6 third review #1) moving the main window during the close's content fade finishes that close: the box is put away (off the main window), its content opacity is restored, the button shows at the main window's new place; shell and click spot gone",
              "clearing=\(clearing7) phase=\(morph.phase) box=\(box.isVisible) parent=\(box.parent != nil) clean=\(clean()) button=\(button.frame) expected=\(expected7)")
        main.setFrameOrigin(origin7)
        _ = await DMBrowserAcceptance.waitUntil(1) { panels.dockedButtonPlacementForTesting().map { near(button.frame, $0, 0.5) } == true }

        // N8（#2）：縮回途中移動主視窗＝直接到位，圓鈕照「移動後」的主視窗擺（不是縮之前記下的位置）。
        await openSettled(at: 1_000)
        clock.now = 1_010
        store.isOpen = false
        clock.now = 1_010 + GlobalDMMorphTiming.clearOut + 0.001
        morph.tick()
        _ = await DMBrowserAcceptance.waitUntil(2) { !box.isVisible }
        let shrinking8 = morph.phase == .shrinking && !button.isVisible
        clock.now = 1_010.2
        morph.show(at: 0.1)
        let buttonBefore8 = panels.dockedButtonPlacementForTesting() ?? .null
        let origin8 = main.frame.origin
        main.setFrameOrigin(NSPoint(x: origin8.x - 30, y: origin8.y + 25))
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .idle }
        settleUI()
        let expected8 = panels.dockedButtonPlacementForTesting() ?? .null
        check(shrinking8 && morph.phase == .idle && morph.shell == nil && button.isVisible && button.parent === main && near(button.frame, expected8, 0.5)
              && near(button.frame, buttonBefore8.offsetBy(dx: -30, dy: 25), 0.5),
              "N8 (GPT-6 third review #2) moving the main window while the box shrinks into the button: it goes straight to its end and the button shows at the moved main window's place (its screen frame moved with the window), not where it was before",
              "shrinking=\(shrinking8) phase=\(morph.phase) button=\(button.frame) expected=\(expected8) before=\(buttonBefore8)")
        main.setFrameOrigin(origin8)
        _ = await DMBrowserAcceptance.waitUntil(1) { panels.dockedButtonPlacementForTesting().map { near(button.frame, $0, 0.5) } == true }

        // N9（#3）：長到一半只改主視窗寬度（原點不動）＝外殼直接到位，框照新的主視窗擺（外殼不會自己飛到舊的目標）。
        clock.now = 1_100
        store.openDocked()
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .growing }
        clock.now = 1_100.1
        morph.show(at: 0.1)
        let growing9 = morph.phase == .growing
        let frame9 = main.frame
        main.setFrame(NSRect(x: frame9.minX, y: frame9.minY, width: frame9.width - 120, height: frame9.height), display: false)
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .idle }
        settleUI()
        let placed9 = panels.placedPanelFrameForTesting() ?? .null
        check(growing9 && morph.phase == .idle && morph.shell == nil && box.isVisible && !button.isVisible && morph.presentedContent > 0.99
              && near(box.frame, placed9, 0.5),
              "N9 (GPT-6 third review #3) resizing only the main window's width mid-grow (origin unchanged) puts the shell straight at its end and the box where the resized window places it — the shell does not fly on to the old target",
              "growing=\(growing9) phase=\(morph.phase) box=\(box.frame) placed=\(placed9) content=\(morph.presentedContent)")
        main.setFrame(frame9, display: false)
        _ = await DMBrowserAcceptance.waitUntil(1) { panels.placedPanelFrameForTesting().map { near(box.frame, $0, 0.5) } == true }

        // N10（#4）：停靠的外殼與點擊區只在主視窗那個桌面（不跨所有桌面）；切到別的桌面＝直接到位、拆掉。浮動框那一份照舊跨桌面。
        await closeSettled(at: 1_200)
        clock.now = 1_300
        store.openDocked()
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .growing }
        let shellPanel10 = morph.shell?.panel
        let local = shellPanel10.map { !$0.collectionBehavior.contains(.canJoinAllSpaces) } == true
            && morph.catcherPanel.map { !$0.collectionBehavior.contains(.canJoinAllSpaces) } == true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .idle }
        settleUI()
        check(local && morph.phase == .idle && morph.shell == nil && shellPanel10?.isVisible == false && morph.catcherPanel?.isVisible != true
              && box.isVisible && !button.isVisible && panels.buttonMorph.joinsAllSpaces,
              "N10 (GPT-6 third review #4) the docked shell and click spot stay on the main window's Space (no canJoinAllSpaces; the floating one still joins all); switching Spaces mid-grow puts it straight at its end and takes both down",
              "local=\(local) phase=\(morph.phase) shell=\(shellPanel10?.isVisible == true) catcher=\(morph.catcherPanel?.isVisible == true)")
        await closeSettled(at: 1_400)

        // N11（S5B 查到的）：停靠 → 浮動換手（同一下停靠框收起、浮動框打開）：停靠框不淡出——頁面與配對碼搬到浮動框去了，淡出中的那一份
        // 會在沒有頁面的框裡照樣畫著碼。收起的淡出當場算完成（內容不留）、停靠框收掉、圓鈕回到主視窗，浮動框照常打開。
        await openSettled(at: 1_500)
        clock.now = 1_510
        store.openFloating()
        let handedOff = morph.phase == .idle && !morph.keepsContent && morph.shell == nil
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true && !box.isVisible }
        settleUI()
        check(handedOff && !box.isVisible && box.parent == nil && clean() && button.isVisible && button.parent === main
              && panels.floatingPanelForTesting?.isVisible == true && store.isFloatingOpen && !store.isOpen,
              "N11 (S5B) docked → floating hand-off: the docked box does not fade its copy (its pages and pairing code move to the floating box) — the close counts as done at once, the docked box is put away, the button is back, the floating box opens",
              "handedOff=\(handedOff) phase=\(morph.phase) docked=\(box.isVisible) clean=\(clean()) button=\(button.isVisible) floating=\(panels.floatingPanelForTesting?.isVisible == true)")
        store.isFloatingOpen = false
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible != true }
    }
}
#endif
