#if DEBUG
import AppKit
import Combine
import QuartzCore
import SwiftUI

// W184 F／G1 修正單（GPT-6 審查 #2、#4、#5，查證 #5、#6、#8、#12）：w184forms 的第二部分——真的面板控制器接上真的主視窗
// （TatwoWorkOSWindow）的停靠框（滑、主視窗移動或改大小、拖過輸入框）、假的敏感頁與配對碼的截圖保護整合、轉換中收框時排隊的入口、
// 倒放轉向與帶著影片離開。畫面都在 alpha 0 的視窗裡（排在畫面上、看不見）。
extension GlobalDMFormsAcceptance {
    /// 自測的時鐘（面板控制器的 formMotion.clock 換成它）：停著不動，自測一格一格往前推——「同一時刻」的實際畫面與模型才比得準。
    @MainActor final class TestClock {
        var now: CFTimeInterval = 1_000
    }

    /// 時鐘往前一格（預設 1/60 秒）、叫一格（W184 F3：自測推時鐘＝圖層台停在這一格），再讓 run loop 跑一下（非同步的整理、SwiftUI 的更新
    /// 輪得到——真的框要是在動畫期間排版，自測數得到；時鐘停著，框不會自己往前）。
    @MainActor static func step(_ clock: TestClock, _ motion: GlobalDMFormMotion, _ seconds: Double = 1.0 / 60) {
        clock.now += seconds
        motion.tick()
        RunLoop.main.run(until: Date().addingTimeInterval(0.004))
    }

    /// 兩個框差多少（四個數裡最大的那一個）。
    static func deviation(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    static func same(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.5) -> Bool { deviation(a, b) <= tolerance }

    /// 自測的主視窗（真的 TatwoWorkOSWindow：停靠框掛在它下面）：排在畫面上（isVisible）但看不見（alpha 0）；螢幕放得下就 1200×960。
    @MainActor static func mainWindow() -> TatwoWorkOSWindow? {
        guard let screen = NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1_200, visible.width - 40), height: min(960, visible.height - 40))
        let window = TatwoWorkOSWindow(contentRect: NSRect(x: visible.minX + 20, y: visible.minY + 20, width: size.width, height: size.height),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "W184F 自測主視窗"
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        window.alphaValue = 0
        window.orderFrontRegardless()
        return window
    }

    /// 主視窗底下的子面板（停靠圓鈕、停靠框）一律看不見。
    @MainActor static func hideChildren(of window: NSWindow) {
        for child in window.childWindows ?? [] { child.alphaValue = 0 }
    }

    // MARK: - 停靠框：滑、主視窗移動或改大小、拖過輸入框（查證 #12、GPT-6 審查 #4、#2）

    @MainActor static func dockedRigChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        guard let main = mainWindow() else { return check.skip("H6 停靠框：這個環境沒有螢幕") }
        defer { main.orderOut(nil) }
        let store = GlobalDMStore(defaults: freshDefaults("dockRig"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("dockRigDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        let owner = UUID()
        panels.install()
        defer {
            GlobalDMComposerFrames.shared.report(.coder, nil, owner: owner)
            store.close()
            panels.uninstall()
        }
        store.openDocked()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.dockedPanelForTesting?.isVisible == true }
        guard let panel = panels.dockedPanelForTesting, panel.isVisible, let canvas = panel.contentView as? GlobalDMPanelCanvas else {
            return check.skip("H6 停靠框：這個環境掛不上主視窗的停靠框（沒有畫面環境）")
        }
        hideChildren(of: main)
        let margin = GlobalDMLayout.margin
        let mask = GlobalDMNativePageMask.shared
        let clock = TestClock()
        panels.formMotion.clock = { clock.now }
        panels.formMotion.manualTime = true
        defer {
            panels.formMotion.manualTime = false
            panels.formMotion.clock = { CACurrentMediaTime() }
        }

        // H6（查證 #12）：停靠框的滑。面板只在開始、停下各換一次大小（形態一改就排到下一輪的整理照樣跑，不准改畫布）；每一格畫布包住框、
        // 框的右下角不動、圖層台上的框＝模型那一刻的框（<1pt）；停下＝照平常擺好的停靠框。
        let old = panel.frame.insetBy(dx: margin, dy: margin)
        var frames: [NSRect] = [panel.frame]
        func note() { if frames.last != panel.frame { frames.append(panel.frame) } }
        panels.prepareForm()
        settings.form = .innerLandscape
        panels.applyForm(.between(.outerPortrait, .innerLandscape))
        note()
        let startBox = canvas.stage?.presentedBox ?? .zero
        var worst: CGFloat = 0, contained = true, pinned = true, steps = 0
        while panels.formMotion.isAnimating, steps < 90 {
            step(clock, panels.formMotion)
            steps += 1
            note()
            guard panels.formMotion.isAnimating, let model = panels.formMotion.current, let stage = canvas.stage else { break }
            let now = stage.presentedBox
            worst = max(worst, deviation(now, model.box))
            contained = contained && panel.frame.insetBy(dx: -0.5, dy: -0.5).contains(now.insetBy(dx: -margin, dy: -margin))
            pinned = pinned && abs(now.maxX - old.maxX) <= 0.5 && abs(now.minY - old.minY) <= 0.5
        }
        let placed = panels.placedPanelFrameForTesting()
        check(same(startBox, old) && steps > 10 && worst < 1 && contained && pinned && frames.count == 3 && !panels.formMotion.isAnimating
              && placed.map { same(panel.frame, $0) } == true && canvas.host.frame == canvas.bounds && !mask.isMasking,
              "H6 the docked box slides too (under a real main window): the panel changes size only when the slide starts and when it stops (the deferred reconcile after the form change does not touch the canvas), the canvas holds the box every frame, the bottom-right corner stays, the drawn box is the model's box at the same moment (<1pt), and it ends on the usual docked place",
              "frames=\(frames.count) worst=\(worst) contained=\(contained) pinned=\(pinned) steps=\(steps) panel=\(panel.frame) placed=\(String(describing: placed))")

        // D12（GPT-6 審查 #4）：停靠框換形態途中主視窗移動、改大小＝轉換直接停在終點（遮蔽放掉、畫布還原），照平常的算法替移動後的主視窗重擺。
        // 時鐘停著：轉換不會自己走完，停下只可能是這條規則。
        func midway(to form: GlobalDMForm) -> Bool {
            let from = settings.form
            panels.prepareForm()
            settings.form = form
            panels.applyForm(.between(from, form))
            for _ in 0..<8 { step(clock, panels.formMotion) }
            return panels.formMotion.isAnimating && mask.isMasking && canvas.host.frame != canvas.bounds
        }
        let movingMidway = midway(to: .outerPortrait)
        let origin = main.frame.origin
        main.setFrameOrigin(NSPoint(x: origin.x + 40, y: origin.y + 30))
        _ = await DMBrowserAcceptance.waitUntil(1) { !panels.formMotion.isAnimating }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let movedPlaced = panels.placedPanelFrameForTesting()
        check(movingMidway && !panels.formMotion.isAnimating && !mask.isMasking && canvas.host.frame == canvas.bounds
              && movedPlaced.map { same(panel.frame, $0) } == true
              && abs(panel.frame.width - (GlobalDMForm.outerPortrait.size.width + margin * 2)) <= 1,
              "D12 counterexample (GPT-6 #4): moving the main window while the docked box slides stops the slide at its end (mask released, canvas back to the box) and places the box the usual way for the moved window",
              "midway=\(movingMidway) animating=\(panels.formMotion.isAnimating) panel=\(panel.frame) placed=\(String(describing: movedPlaced))")
        let resizingMidway = midway(to: .innerLandscape)
        var smaller = main.frame
        smaller.size.width -= 120
        smaller.size.height -= 80
        main.setFrame(smaller, display: false)
        _ = await DMBrowserAcceptance.waitUntil(1) { !panels.formMotion.isAnimating }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let resizedPlaced = panels.placedPanelFrameForTesting()
        let content = main.contentView.map { main.convertToScreen($0.convert($0.bounds, to: nil)) } ?? main.frame
        check(resizingMidway && !panels.formMotion.isAnimating && !mask.isMasking && canvas.host.frame == canvas.bounds
              && resizedPlaced.map { same(panel.frame, $0) } == true
              && content.insetBy(dx: -0.5, dy: -0.5).contains(panel.frame.insetBy(dx: margin, dy: margin)),
              "D12 counterexample (GPT-6 #4): making the main window smaller while the docked box slides does the same: it stops at the end and the box is placed inside the smaller window",
              "midway=\(resizingMidway) panel=\(panel.frame) placed=\(String(describing: resizedPlaced)) content=\(content)")
        panels.formMotion.manualTime = false
        panels.formMotion.clock = { CACurrentMediaTime() }
        settings.form = .outerPortrait
        panels.applyForm(.between(.innerLandscape, .outerPortrait, animated: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // D13（W184 G1b：使用者「範圍太小，拖不到想放的地方」）：停靠框＝主視窗整個內容區都能放、可以蓋到輸入框（使用者自己放的就尊重）；
        // 預設的擺法照舊避開輸入框。輸入框在主視窗左邊、預設的停靠框在右邊（不相交）；把框（原生拖曳）拖到輸入框上面放開＝就停在那裡。
        guard let host = main.contentView else { return check(false, "D13 the main window has a content view") }
        let composerGlobal = CGRect(x: 20, y: host.bounds.height - 100, width: min(480, host.bounds.width * 0.4), height: 100)
        GlobalDMComposerFrames.shared.report(.coder, composerGlobal, owner: owner)
        panels.reconcile()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let geometry = panels.dockedGeometryForTesting(), let composer = geometry.composer else {
            return check(false, "D13 the docked box sees the reported composer", "\(String(describing: panels.dockedGeometryForTesting()))")
        }
        let start = panel.frame.insetBy(dx: margin, dy: margin)
        let delta = CGSize(width: composer.minX + 10 - start.minX, height: composer.minY + 10 - start.minY)
        _ = nativeDrag(panels, panel, surface: .docked, by: [CGSize(width: delta.width / 2, height: delta.height / 2), delta], saved: { false })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let after = panel.frame.insetBy(dx: margin, dy: margin)
        let dropped = start.offsetBy(dx: delta.width, dy: delta.height)
        let standard = geometry.standard
        print("W184FORMS NOTE D13 composer=\(composer) start=\(start) dropped=\(dropped) after=\(after) standard=\(standard)")
        check(!GlobalDMDockLayout.overlaps(start, composer) && GlobalDMDockLayout.overlaps(after, composer) && same(after, dropped)
              && !GlobalDMDockLayout.overlaps(standard, GlobalDMDockLayout.composerZone(composer)) && panel.parent === main,
              "D13 (G1b) the docked box can be dropped anywhere in the main window's content, over the composer too (the user put it there — it stays exactly there, still a child of the main window); the default place keeps clear of the composer",
              "start=\(start) dropped=\(dropped) after=\(after) composer=\(composer)")
        panels.resetPlacement(.docked)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // D31（G1b 第二輪，GPT-6 G1b 審查 #1）途中收框：停靠框拖到一半收起來（框關掉、主視窗還在）＝照開始那一份（停靠框、那一刻的
        // 主視窗內容區）存下收起那一刻的位置——不靠框還開著、不重猜；之後的放開什麼都不做；再打開就在那裡。
        var atCollapse = NSRect.zero
        _ = nativeDrag(panels, panel, surface: .docked, by: [CGSize(width: -140, height: 60), CGSize(width: -260, height: 100)], saved: { false }) { index in
            guard index == 0 else { return }
            atCollapse = panel.frame.insetBy(dx: margin, dy: margin)
            store.toggleDocked()   // 收框（圓鈕還在）
            panels.reconcile()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let collapseDrop = panels.lastDrop
        let savedDocked = settings.placement(.docked)
        let hiddenAfter = !panel.isVisible
        store.openDocked()
        _ = await DMBrowserAcceptance.waitUntil(2) { panel.isVisible }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hideChildren(of: main)
        let reopened = panel.frame.insetBy(dx: margin, dy: margin)
        check(collapseDrop.map { $0.key == .docked && $0.reason == "hidden" && $0.dropped == atCollapse } == true && savedDocked.offset != nil
              && hiddenAfter && same(reopened, atCollapse) && !panels.isGrippingForTesting,
              "D31 counterexample (GPT-6 G1b #1) collapsing mid-drag: a docked box closed while it is being dragged is saved where it was at that moment, in the docked record (fixed when the drag began — not guessed again, not depending on the box being open); the later release does nothing; opening it again puts it right there",
              "drop=\(String(describing: collapseDrop)) saved=\(savedDocked) hidden=\(hiddenAfter) atCollapse=\(atCollapse) reopened=\(reopened)")
        panels.resetPlacement(.docked)
    }

    // MARK: - 轉換中收框：排隊的入口下一輪才做（查證 #5）

    @MainActor static func abortIdleChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) async {
        let store = GlobalDMStore(defaults: freshDefaults("abortIdle"), chatGPTAllowed: { true })
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("abortIdleDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        panels.install()
        defer {
            store.close()
            panels.uninstall()
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true }
        guard let panel = panels.floatingPanelForTesting, panel.isVisible else {
            return check.skip("D14 轉換中收框：這個環境開不出浮動框（沒有畫面環境）")
        }
        panel.alphaValue = 0
        let log = HandsLocked<[String]>([])
        panels.formMotion.onIdle = { log.update { $0.append(store.isFloatingOpen ? "idle while open" : "idle after close") } }
        settings.form = .innerLandscape
        panels.applyForm(.between(.outerPortrait, .innerLandscape))
        let sliding = panels.formMotion.isAnimating
        store.isFloatingOpen = false
        panels.reconcile()   // ⌥⌘、Esc 收框的路徑：改旗標再整理一次
        let inside = log.get()
        let stopped = !panels.formMotion.isAnimating && !GlobalDMNativePageMask.shared.isMasking && !panel.isVisible
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let later = log.get()
        check(sliding && inside.isEmpty && stopped && later == ["idle after close"],
              "D14 counterexample (verify #5): closing the box mid-transition stops the slide (mask released) but runs the queued entries only on the next run-loop turn, after the close is done (no nested reconcile reopening the box inside the close path)",
              "sliding=\(sliding) inside=\(inside) stopped=\(stopped) later=\(later)")
        panels.formMotion.onIdle = nil
    }

    // MARK: - 倒放：轉向進倒放、帶著影片離開（查證 #6、#8）

    @MainActor static func tentTurnChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        let rig = DMTentAcceptance.Rig(defaults: freshDefaults("tentTurn"))
        defer { rig.close() }
        let t0 = Date(timeIntervalSince1970: 2_000)
        rig.source.add(BrowserLendableTab(id: "A", host: "video.example", title: "A", lastActiveAt: t0, videoStartedAt: t0.addingTimeInterval(1),
                                          isSelected: true))
        // T1（查證 #6）：⌘⌥Tab 連按：前一段還在滑（isAnimating 一直是 true，不會再有「開始」）時轉向倒放＝馬上放黑底，不先露出空狀態；再轉走就不是。
        rig.settings.form = .innerPortrait
        rig.animating.value = true
        rig.transitions.send(true)
        let before = rig.video.entering
        rig.settings.form = .tent
        let turned = rig.video.entering
        rig.settings.form = .outerPortrait
        let away = rig.video.entering
        rig.animating.value = false
        rig.transitions.send(false)
        await DMTentAcceptance.settle()
        check(!before && turned && !away && !rig.video.entering,
              "T1 counterexample (verify #6): turning into the tent while a slide is still running (⌘⌥Tab pressed quickly) shows the black placeholder at once, not the empty-state card; turning away again drops it",
              "before=\(before) turned=\(turned) away=\(away)")

        // T2（查證 #8）：倒放裡放著影片時離開：影片在動畫開始前已經還回，倒放那一層淡出的那一小段只放黑底（不閃「影片在 Browser 分頁播放」）；
        // 轉換走完才清掉。
        rig.settings.form = .tent
        rig.animating.value = true
        rig.transitions.send(true)
        let container = rig.mount(rig.docked)
        rig.animating.value = false
        rig.transitions.send(false)
        await DMTentAcceptance.settle()
        let lent = rig.video.lentTabID == "A"
        rig.settings.form = .outerPortrait
        rig.animating.value = true
        rig.transitions.send(true)
        let leavingNow = rig.video.leaving && rig.video.shown == nil && rig.source.isHome("A")
        let store = GlobalDMStore(defaults: freshDefaults("tentLeave"), chatGPTAllowed: { true })
        store.attach(model)
        let rendered = GlobalDMChatAcceptance.renderSync(GlobalDMTentPane(store: store, model: model, video: rig.video),
                                                         size: CGSize(width: 678, height: 466))
        let dark = rendered.map(darkShare) ?? -1
        rendered?.close()
        rig.animating.value = false
        rig.transitions.send(false)
        await DMTentAcceptance.settle()
        let cleared = !rig.video.leaving
        rig.unmount(container)
        check(lent && leavingNow && dark > 0.95 && cleared,
              "T2 counterexample (verify #8): leaving the tent with a video playing gives it back before the slide and draws only black while the tent layer fades out (no empty-state card); the flag clears when the transition ends",
              "lent=\(lent) leaving=\(leavingNow) dark=\(dark) cleared=\(cleared)")

        // T3（修正核對 #7）：進倒放途中（黑底，影片還沒收進來）就再按 ⌘⌥Tab 轉走：倒放那一層淡出的那一小段照樣只放黑底，不閃「沒有影片」卡。
        rig.settings.form = .innerPortrait
        await DMTentAcceptance.settle()
        rig.settings.form = .tent
        rig.animating.value = true
        rig.transitions.send(true)
        let enteringFirst = rig.video.entering
        rig.settings.form = .outerPortrait   // 轉向：前一段還在跑
        let blackOnTurn = rig.video.leaving && !rig.video.entering && rig.video.shown == nil && rig.video.lentTabID == nil
        let turnStore = GlobalDMStore(defaults: freshDefaults("tentTurnAway"), chatGPTAllowed: { true })
        turnStore.attach(model)
        let turnShot = GlobalDMChatAcceptance.renderSync(GlobalDMTentPane(store: turnStore, model: model, video: rig.video),
                                                         size: CGSize(width: 678, height: 466))
        let turnDark = turnShot.map(darkShare) ?? -1
        turnShot?.close()
        rig.animating.value = false
        rig.transitions.send(false)
        await DMTentAcceptance.settle()
        check(enteringFirst && blackOnTurn && turnDark > 0.95 && !rig.video.leaving,
              "T3 counterexample (fix-check #7): turning away while still entering the tent (⌘⌥Tab twice) keeps the fading tent layer black (no empty-state card); the flag clears when the transition ends",
              "entering=\(enteringFirst) black=\(blackOnTurn) dark=\(turnDark) leavingAfter=\(rig.video.leaving)")
    }

    /// T4（W184 F 小修正：真機 v2.0.21.030 內直 → 倒放、Browser 沒有在播影片：轉換中淡入黑底、停下才換成米色空狀態卡，最後一刻從黑閃成米色）：
    /// 真的面板上沒有影片進倒放——每一格都不准是黑底：倒放影片容器的佔位不塗黑、倒放那一層不放黑底（entering 一直是 false），
    /// 畫出來的框裡接近黑色的像素不到三成（黑底會是九成以上）；停下之後同一個樣子。
    @MainActor static func tentNoVideoChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        let store = GlobalDMStore(defaults: freshDefaults("tentNoVideo"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("tentNoVideoDesk"))
        settings.form = .innerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        panels.install()
        defer {
            store.close()
            panels.uninstall()
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true }
        guard let panel = panels.floatingPanelForTesting, panel.isVisible, let canvas = panel.contentView as? GlobalDMPanelCanvas else {
            return check.skip("T4 沒有影片進倒放：這個環境開不出浮動框（沒有畫面環境）")
        }
        panel.alphaValue = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let video = DMTentVideo.shared
        func blackFill() -> Bool {
            DMBrowserPhoneAcceptance.views(DMTentVideoContainer.self, in: canvas).contains { container in
                guard let color = container.layer?.backgroundColor, color.alpha > 0.5, let rgb = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return false }
                return rgb.redComponent < 0.15 && rgb.greenComponent < 0.15 && rgb.blueComponent < 0.15
            }
        }
        /// 畫出來的框裡接近黑色的像素佔多少：轉換中看圖層台（W184 F3：動畫是台在動，真的框透明度 0），停著看真的框。
        func darkShare() -> Double {
            let margin = GlobalDMLayout.margin
            let rep: NSBitmapImageRep
            if let stage = canvas.stage {
                let box = stage.presentedBox.insetBy(dx: 6, dy: 6)
                let local = NSRect(x: box.minX - panel.frame.minX, y: box.minY - panel.frame.minY, width: box.width, height: box.height)
                guard local.width > 20, local.height > 20, let shot = canvas.bitmapImageRepForCachingDisplay(in: local) else { return -1 }
                stage.render(into: shot, region: local, underlay: nil)
                rep = shot
            } else {
                let frame = canvas.host.frame.insetBy(dx: margin + 6, dy: margin + 6)
                guard frame.width > 20, frame.height > 20, let shot = canvas.bitmapImageRepForCachingDisplay(in: frame) else { return -1 }
                canvas.cacheDisplay(in: frame, to: shot)
                rep = shot
            }
            guard rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let data = rep.bitmapData else { return -1 }
            let samples = rep.samplesPerPixel, row = rep.bytesPerRow, colors = min(3, samples)
            var dark = 0, total = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                let line = data + y * row
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    let pixel = line + x * samples
                    var black = true
                    for s in 0..<colors where pixel[s] >= 40 { black = false }
                    if black { dark += 1 }
                    total += 1
                }
            }
            return total == 0 ? -1 : Double(dark) / Double(total)
        }
        panels.prepareForm()
        settings.form = .tent
        panels.applyForm(.between(.innerPortrait, .tent))
        var frames = 0, filled = 0, entered = false, worst = 0.0, sampled = 0, staged = 0
        let began = Date()
        while panels.formMotion.isAnimating, Date().timeIntervalSince(began) < 2 {
            frames += 1
            if canvas.stage != nil { staged += 1 }
            if blackFill() || canvas.stage?.tentBackdrop.map(isBlackish) == true { filled += 1 }
            entered = entered || video.entering
            if frames % 3 == 1 {
                let share = darkShare()
                if share >= 0 { sampled += 1; worst = max(worst, share) }
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let rest = darkShare()
        let tentShown = !DMBrowserPhoneAcceptance.views(DMTentVideoContainer.self, in: canvas).isEmpty
        check(frames > 8 && sampled > 3 && staged > 3 && filled == 0 && !entered && worst < 0.3 && rest >= 0 && rest < 0.3 && tentShown && !blackFill(),
              "T4 counterexample (real device v2.0.21.030): entering the tent with no video to borrow never shows a black backdrop — the tent container is not painted black, the stage's tent layer has no black backdrop, under 30% near-black pixels in every sampled frame of the stage, and the same look once it settles (the empty-state card fades straight in)",
              "frames=\(frames) staged=\(staged) blackFills=\(filled) entering=\(entered) worstDark=\(String(format: "%.2f", worst)) rest=\(String(format: "%.2f", rest)) sampled=\(sampled) tent=\(tentShown)")
        settings.form = .outerPortrait
        panels.applyForm(.between(.tent, .outerPortrait, animated: false))
    }

    /// C9（W184 F 小修正：真機內橫縮到約 0.8 倍時，左欄的模型膠囊被截成「Fa...5.1」）：寬度不夠時記憶膠囊先縮成只留強度（ViewThatFits），
    /// 模型膠囊固定用它自己的寬度（fixedSize、排版優先），模型名不截。用真機那個模型名（Fable 5.1）量：0.8 倍內橫的左欄放得下「只留強度的記憶膠囊＋整個模型名」。
    /// W184 H4 修正（查核 #16）：記憶、模型收進一顆「模式選擇」chip（私訊框用 ChatComposerModeChip 的 .dmPhone，GlobalDMModeChip）——
    /// 守的東西不變（0.8 倍內橫的左欄放得下、模型名不截），改量真的在畫的那一顆：完整一行、縮短一行（記憶寫「記中」、模型那段照舊整個名字）各量一次；
    /// 那一排變成 ＋、彈性空白、模式選擇、送出（三個間距）。
    @MainActor static func composerChipChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) {
        func ideal(_ view: some View) -> CGFloat { NSHostingView(rootView: view).fittingSize.width }
        let title = "Fable 5.1"
        let segments = [TatwoComposerMode.modelSegment(title: title, suffix: nil, accessibilityTitle: title, identifier: "tatwo.dm.model"),
                        TatwoComposerMode.memorySegment(TatwoMemoryChipState(strength: .medium, remotePlace: nil, isEnabled: true))]
        // 縮短的那一行＝每一段換成它的簡稱（chip 自己的 ViewThatFits 在放不下完整那一行時畫的就是這個）。
        let shortSegments = segments.map {
            TatwoComposerMode.Segment(id: $0.id, text: $0.short, short: $0.short, icon: $0.icon, accessibilityLabel: $0.accessibilityLabel,
                                      identifier: $0.identifier, emphasized: $0.emphasized, dimmed: $0.dimmed)
        }
        let fullChip = ideal(ChatComposerModeChip(segments: segments, selected: false, style: .dmPhone) {})
        let shortChip = ideal(ChatComposerModeChip(segments: shortSegments, selected: false, style: .dmPhone) {})
        let size = GlobalDMBoxPlacement.sized(GlobalDMForm.innerLandscape.size, factor: 0.8)
        let column = GlobalDMPhoneLook(form: .innerLandscape, slide: nil, size: size).chatWidth(in: size.width)
        let layout = GlobalDMChatLayout.self
        let row = column - layout.composerInset * 2 - layout.composerLeading - layout.composerTrailing
        // ＋、送出（36 的圓；＋往左凸 6）、最小的 Spacer（4）、四樣東西之間三個間距（＋、空白、模式選擇、送出）。
        let fixed = layout.controlSize * 2 + layout.plusOutset + 4 + layout.composerItemSpacing * 3
        let fullNeeds = fixed + fullChip, compactNeeds = fixed + shortChip
        check(compactNeeds <= row && shortChip < fullChip && segments[0].short == title && shortSegments[1].text == "記中" && fullChip > 60,
              "C9 (real device, inner landscape at 0.8): the left column's composer row holds the mode chip shortened (記中) with the whole model name (the chip keeps its own width and never truncates)",
              "row=\(row) chip full=\(fullChip) short=\(shortChip) needs full=\(fullNeeds) compact=\(compactNeeds)")
        print("W184FORMS NOTE C9 row=\(row) chipFull=\(fullChip) chipShort=\(shortChip) fullNeeds=\(fullNeeds) compactNeeds=\(compactNeeds)")
    }

    /// A2（W184 F3，使用者 09-29 17:10：「r角現在會變 導致輸入筐根外ｒ角不齊」）：四種形態、0.7／1.3 倍真的畫出來，四個角都是 52 的圓角——
    /// 52 的圓角外面一點點（縮成 36 的圓角會在裡面）是透明的；52 的圓角裡面一點點（放大成 68 會在外面）是實的（框的底色拍得到才看這一條）。
    @MainActor static func cornerChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) {
        let store = GlobalDMStore(defaults: freshDefaults("corners"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        defer { store.close() }
        func depth(_ radius: CGFloat) -> CGFloat {
            let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: CGRect(x: 0, y: 0, width: 400, height: 400))
            var d: CGFloat = 0
            while d < 120, !path.contains(CGPoint(x: d, y: d)) { d += 0.25 }
            return d
        }
        let small = depth(52 * 0.7), exact = depth(52), large = depth(52 * 1.3)
        let outside = (small + exact) / 2, inside = (exact + large) / 2
        var problems: [String] = [], drawn = 0, solidChecked = 0
        for form in GlobalDMForm.allCases {
            for scale in [CGFloat(0.7), 1.3] {
                let size = CGSize(width: (form.size.width * scale).rounded(), height: (form.size.height * scale).rounded())
                let host = NSHostingView(rootView: GlobalDMPhoneBox(store: store, model: model, surface: .floating, form: form)
                    .frame(width: size.width, height: size.height))
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.isOpaque = false
                window.backgroundColor = .clear
                window.alphaValue = 0
                window.contentView = host
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
                if let rep { host.cacheDisplay(in: host.bounds, to: rep) }
                window.orderOut(nil)
                window.contentView = nil
                guard let rep else { continue }
                drawn += 1
                let s = CGFloat(rep.pixelsWide) / size.width
                func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                    rep.colorAt(x: min(rep.pixelsWide - 1, Int(x * s)), y: min(rep.pixelsHigh - 1, Int(y * s)))?.alphaComponent ?? -1
                }
                let solid = alpha(size.width / 2, size.height / 2) > 0.9
                for (cx, cy, sx, sy) in [(CGFloat(0), CGFloat(0), CGFloat(1), CGFloat(1)), (size.width, 0, -1, 1), (0, size.height, 1, -1),
                                         (size.width, size.height, -1, -1)] {
                    let out = alpha(cx + sx * outside, cy + sy * outside), inn = alpha(cx + sx * inside, cy + sy * inside)
                    if out >= 0.5 { problems.append("\(form.rawValue)@\(scale) (\(Int(cx)),\(Int(cy))) outside α \(String(format: "%.2f", out))") }
                    if solid {
                        solidChecked += 1
                        if inn <= 0.5 { problems.append("\(form.rawValue)@\(scale) (\(Int(cx)),\(Int(cy))) inside α \(String(format: "%.2f", inn))") }
                    }
                }
            }
        }
        print("W184FORMS NOTE A2 corners: depth 36/52/68 = \(small)/\(exact)/\(large) outside \(outside) inside \(inside) solid-checked \(solidChecked)")
        check(drawn == 8 && problems.isEmpty,
              "A2 drawn: every form at 0.7 and 1.3 keeps the 52 corner at all four corners (just outside a 52 corner is clear — a corner scaled to 36 would be solid there; just inside is solid where the surface is drawn — a corner scaled to 68 would be clear)",
              "drawn=\(drawn) \(problems.prefix(6))")
    }

    /// 這個顏色是不是（接近）黑的。
    static func isBlackish(_ color: CGColor) -> Bool {
        guard color.alpha > 0.5, let rgb = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return false }
        return rgb.redComponent < 0.15 && rgb.greenComponent < 0.15 && rgb.blueComponent < 0.15
    }

    /// 畫面裡接近黑色的像素佔多少（0–1；每個色版都比 40 暗才算）。
    @MainActor static func darkShare(_ rendered: GlobalDMChatAcceptance.Rendered) -> Double {
        let rep = rendered.bitmap
        guard rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let data = rep.bitmapData,
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return -1 }
        let samples = rep.samplesPerPixel, row = rep.bytesPerRow, colors = min(3, samples)
        var dark = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            let line = data + y * row
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let pixel = line + x * samples
                var black = true
                for s in 0..<colors where pixel[s] >= 40 { black = false }
                if black { dark += 1 }
                total += 1
            }
        }
        return total == 0 ? -1 : Double(dark) / Double(total)
    }

    // MARK: - 截圖保護整合（GPT-6 審查 #5）

    /// 每一格看：授權頁或配對碼在畫面上 ⇒ 那個視窗不給擷取；碼只在綁定的配對頁在畫面上時顯示；Computer Use 閘門一直開著。
    @MainActor final class SecurityWatch {
        static let pairingKey = 91
        private(set) var frames = 0
        private(set) var problems: [String] = []
        let browser: DMBrowser
        var pages: [NSView] = []
        var pairing: NSView?

        init(browser: DMBrowser) {
            self.browser = browser
        }

        func sample(_ label: String, _ windows: [NSWindow]) {
            frames += 1
            for window in windows where window.isVisible {
                let pageShown = pages.contains { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
                let code = DMBrowserPhoneAcceptance.codeDrawn(in: window)
                if pageShown || code, !WindowCaptureShield.shared.isShielding(window) {
                    problems.append("\(label)#\(frames): \(code ? "the code" : "a sensitive page") on screen in a capturable window")
                }
                if code, !(pairing.map { $0.window === window && !$0.isHiddenOrHasHiddenAncestor } ?? false) || !browser.showsSurface(Self.pairingKey) {
                    problems.append("\(label)#\(frames): the code is drawn without its pairing page on screen")
                }
            }
            if !BrowserSensitivePageGate.isActive { problems.append("\(label)#\(frames): the Computer Use gate was off") }
            // A6（GPT-6 審查 F3 #6）：圖層台上真的畫出來的東西裡不准有配對碼、敏感頁的標記色（每 4 格畫一次台來看）。
            guard frames % 4 == 0 else { return }
            for window in windows where window.isVisible {
                guard let canvas = window.contentView as? GlobalDMPanelCanvas, let stage = canvas.stage,
                      let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
                stage.render(into: rep, region: canvas.bounds, underlay: nil)
                stageRenders += 1
                if let image = rep.cgImage, GlobalDMFormsAcceptance.markerPixels(image) > 0 {
                    problems.append("\(label)#\(frames): the layer stage shows the pairing code or a sensitive page (marker pixels)")
                }
            }
        }
        private(set) var stageRenders = 0
    }

    /// A6：圖裡配對碼、敏感頁的標記色（洋紅）有幾個像素。
    @MainActor static func markerPixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var count = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) where pixels[index] > 200 && pixels[index + 1] < 90 && pixels[index + 2] > 200 {
            count += 1
        }
        return count
    }

    /// 停下之後至少再看多久（比 WindowCaptureShield.linger 久）。
    static let settleWatch: TimeInterval = WindowCaptureShield.linger + 0.15

    /// 一段情境：動作之後每 8ms 看一格（midway 秒時再做一次中途的動作），直到轉換停下再多看 settleWatch（至少 minimum 秒，最多 4 秒）。
    @MainActor static func observe(_ watch: SecurityWatch, _ label: String, windows: () -> [NSWindow], motion: GlobalDMFormMotion,
                                   minimum: Double = 0.2, midway: Double? = nil, then later: () -> Void = {},
                                   _ trigger: () -> Void) async -> (ok: Bool, frames: Int, detail: String) {
        let before = watch.problems.count, framesBefore = watch.frames
        trigger()
        watch.sample(label, windows())
        let began = Date()
        var settledAt: Date?
        var didMidway = midway == nil
        while Date().timeIntervalSince(began) < 4 {
            try? await Task.sleep(nanoseconds: 8_000_000)
            watch.sample(label, windows())
            if !didMidway, let midway, Date().timeIntervalSince(began) >= midway {
                didMidway = true
                later()
                watch.sample(label, windows())
            }
            if motion.isAnimating || !didMidway { settledAt = nil } else if settledAt == nil { settledAt = Date() }
            // 修正核對 #10：停下之後再看 0.6 秒（比截圖保護放手後的 linger 0.45 秒久）：停下那一刻把保護放掉的退步才抓得到。
            if let settledAt, Date().timeIntervalSince(settledAt) > settleWatch, Date().timeIntervalSince(began) > minimum { break }
        }
        let new = Array(watch.problems[before...])
        return (new.isEmpty, watch.frames - framesBefore, new.prefix(4).joined(separator: "; "))
    }

    /// 拖（原生拖曳，假的視窗伺服器十步）或縮放（右上角，十步）浮動框，每一格照樣看；放開之後也看過 linger。
    @MainActor static func observeGrip(_ watch: SecurityWatch, _ label: String, windows: @escaping () -> [NSWindow], panels: GlobalDMPanelController,
                                       resize: Bool) async -> (ok: Bool, frames: Int, detail: String) {
        let before = watch.problems.count, framesBefore = watch.frames
        if resize {
            panels.handleGrip(.resize(.topRight), surface: .floating, phase: .began)
            watch.sample(label, windows())
            for index in 1...10 {
                panels.handleGrip(.resize(.topRight), surface: .floating, phase: .changed(CGSize(width: 0, height: CGFloat(-6 * index))))
                watch.sample(label, windows())
                try? await Task.sleep(nanoseconds: 8_000_000)
                watch.sample(label, windows())
            }
            panels.handleGrip(.resize(.topRight), surface: .floating, phase: .ended)
        } else if let panel = panels.floatingPanelForTesting {
            let steps = (1...10).map { CGSize(width: CGFloat(-12 * $0), height: CGFloat(6 * $0)) }
            _ = nativeDrag(panels, panel, surface: .floating, by: steps, saved: { false }) { _ in watch.sample(label, windows()) }
        }
        let released = Date()
        while Date().timeIntervalSince(released) < settleWatch {   // 放開之後也看過 linger
            try? await Task.sleep(nanoseconds: 8_000_000)
            watch.sample(label, windows())
        }
        let new = Array(watch.problems[before...])
        return (new.isEmpty, watch.frames - framesBefore, new.prefix(4).joined(separator: "; "))
    }

    /// 面板控制器與桌面控制器（瀏覽器、連線卡片要在它們之前建，開框請求照正式的路徑晚一點再接上）。
    @MainActor final class SecurityRefs {
        var panels: GlobalDMPanelController?
        var desk: GlobalDMDeskController?
    }

    /// GPT-6 審查 #5：隔離的 model＋假的敏感分頁（Cloudflare 授權頁）與配對頁＋配對碼（沿用房 D 自測的假頁），接進真的面板控制器
    /// （GlobalDMBrowserServices）與真的桌面控制器（修正核對 #11：setForm、syncDuo 在內橫進出時把 Browser 換到右欄／收回、轉換中的開框請求排隊、
    /// isFormTransitioning 轉給 Browser），真的跑：滑（中途有開框請求排隊）、轉向（離開內橫＝Browser 收回）、減少動態效果、轉換中收框、
    /// 停靠↔浮動換手、拖、縮放、失焦。每一格看 App 所有看得到的視窗：授權頁或配對碼在畫面上 ⇒ 那個視窗不給擷取、碼只在綁定頁在畫面上時顯示、
    /// Computer Use 閘門一直開著；每段停下之後再看 0.6 秒（過了 linger）；最後遮蔽一定解除、收掉之後所有面板（含藏起來的停靠框）都放手。
    @MainActor static func securityChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        guard let main = mainWindow() else { return check.skip("S 截圖保護整合：這個環境沒有螢幕") }
        defer { main.orderOut(nil) }
        // A6：假配對碼、假敏感頁（授權頁、配對頁）畫成洋紅：拍下來的圖、圖層台裡一個洋紅像素都不准有。
        let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        DMSecretCodeView.markerColor = magenta
        DMBrowserAcceptance.FakeWebPage.markerColor = magenta
        DMBrowserPhoneAcceptance.EvidencePage.markerColor = magenta
        // G1b 第二輪（GPT-6 G1b 審查 #5）：每一次拍當下就查像素（標記色幾個），記序號、不淘汰——不再事後查 24 張的環形快取。
        GlobalDMPanelCanvas.captureAudit = { markerPixels($0) }
        defer {
            DMSecretCodeView.markerColor = nil
            DMBrowserAcceptance.FakeWebPage.markerColor = nil
            DMBrowserPhoneAcceptance.EvidencePage.markerColor = nil
            GlobalDMPanelCanvas.captureAudit = nil
        }
        let store = GlobalDMStore(defaults: freshDefaults("secure"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("secureDesk"))
        settings.form = .outerPortrait
        let refs = SecurityRefs()
        let never = Just(false).eraseToAnyPublisher()
        // 正式的 DMBrowser.shared 跟著桌面控制器的 isFormTransitioning；開框請求走面板控制器的 open（桌面控制器的關口：轉換中排隊）。
        let browser = DMBrowser(store: store, openRequest: { request in refs.panels?.open(request) }, pageHost: DMBrowserAcceptance.FakeWebHost(),
                                podPage: { DMBrowserPhoneAcceptance.EvidencePage("ChatGPT（假頁面）") },
                                windowShown: { $0.isVisible }, transitions: { refs.desk?.$isFormTransitioning.eraseToAnyPublisher() ?? never })
        let card = DMBrowserPhoneAcceptance.CardBox()
        let presenter = HandsConnectPresenter(store: store, openRequest: { request in refs.panels?.open(request) }, browser: browser,
                                              hookPod: { _ in }, podURL: { nil }, cancelFlow: {}, card: { card.card })
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true,
                                             browserServices: GlobalDMBrowserServices(browser: browser, flow: DMBrowserPhoneAcceptance.inertFlow(),
                                                                                      connect: presenter))
        let desk = GlobalDMDeskController(store: store, settings: settings, hotkeys: GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend()),
                                          panels: panels, duo: GlobalDMDuo(defaults: nil), browser: browser)
        refs.panels = panels
        refs.desk = desk
        panels.install()
        desk.install()
        let helper = GlobalDMPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 40, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        helper.isReleasedWhenClosed = false
        defer {
            helper.orderOut(nil)
            presenter.hide()
            browser.closeAll()
            store.close()
            desk.uninstall()
            panels.uninstall()
            DMSecretCodeView.suppress(false)
        }
        // 修正核對 #9：看 App 所有看得到的視窗（不只兩個面板）。
        func windows() -> [NSWindow] { NSApp.windows.filter { $0.isVisible } }
        func panelWindows() -> [NSWindow] { [panels.floatingPanelForTesting, panels.dockedPanelForTesting].compactMap { $0 } }
        func hideAll() {
            for window in panelWindows() { window.alphaValue = 0 }
            hideChildren(of: main)
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true }
        guard let floating = panels.floatingPanelForTesting, floating.isVisible else {
            return check.skip("S 截圖保護整合：這個環境開不出浮動框（沒有畫面環境）")
        }
        hideAll()
        // S0：授權頁（假的 Cloudflare 授權頁）開在 Browser：私訊框切到 Browser、頁面放進浮動框。
        let loginURL = DMBrowserAcceptance.loginURL("W184FSEC")
        let opened = browser.open(url: loginURL, purpose: .cloudflareLogin)
        var auth: NSView?
        _ = await DMBrowserAcceptance.waitUntil(5) {
            auth = browser.activeTab.flatMap { browser.page(for: $0.id)?.view }
            return auth?.window === floating && auth?.isHiddenOrHasHiddenAncestor == false
        }
        guard opened, let auth, auth.window === floating else {
            return check(false, "S0 the authorisation page opens in the floating box's Browser (real panel and desk controllers, fake page)",
                         "opened=\(opened) window=\(String(describing: auth?.window?.title))")
        }
        let watch = SecurityWatch(browser: browser)
        watch.pages = [auth]
        watch.sample("S0", windows())
        check(watch.problems.isEmpty && WindowCaptureShield.shared.isShielding(floating) && store.isBrowsing && BrowserSensitivePageGate.isActive,
              "S0 the authorisation page is on screen in the real floating box → that window is shielded; the Computer Use gate is on",
              watch.problems.joined(separator: "; "))

        for tag in ["A", "B"] {
            let what = tag == "A" ? "authorisation page" : "pairing code"
            var reveal: () -> Void = { _ = browser.open(url: loginURL, purpose: .cloudflareLogin) }   // 同一個起點＝把它叫到前面（開框請求）
            if tag == "B" {
                // 配對頁（Pod 另開的 popup，假的）＋配對碼：卡片浮在 Browser 上，碼綁在配對頁。
                let pairing = DMBrowserPhoneAcceptance.EvidencePage("連上 TATWO（假配對頁）")
                browser.adoptPopup(pairing, key: SecurityWatch.pairingKey, purpose: .chatgptPairing, expectedHost: nil)
                card.card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(600), attemptsLeft: 5,
                                                             callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true,
                                                             surface: SecurityWatch.pairingKey))
                presenter.show()
                presenter.setCodeVisible(true)
                _ = await DMBrowserAcceptance.waitUntil(5) { DMBrowserPhoneAcceptance.codeDrawn(in: floating) }
                watch.pages = [auth, pairing.view]
                watch.pairing = pairing.view
                reveal = { browser.focusPopup(key: SecurityWatch.pairingKey) }
                watch.sample("SB0", windows())
                check(DMBrowserPhoneAcceptance.codeDrawn(in: floating) && WindowCaptureShield.shared.isShielding(floating)
                      && presenter.codeOnScreen && watch.problems.isEmpty && floating.sharingType == .none,
                      "SB0 the pairing page and its code are on screen in the real floating box → shielded (the code is drawn on its bound page; the window's sharingType is .none)",
                      "drawn=\(DMBrowserPhoneAcceptance.codeDrawn(in: floating)) onScreen=\(presenter.codeOnScreen) sharing=\(floating.sharingType.rawValue) \(watch.problems.suffix(3))")
                // A1（GPT-6 審查 F3 #1）反例。先證明偵測有效：真的框直接拍（不經安全的拍法）＝看得到洋紅（碼在畫面上）。
                let floatingCanvas = floating.contentView as? GlobalDMPanelCanvas
                var control = -1
                if let host = floatingCanvas?.host, let raw = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: raw)
                    control = raw.cgImage.map(markerPixels) ?? -1
                }
                // (a) 待處理的更新：碼換了一個（SwiftUI 還沒更新），形態要改之前拍舊樣子——拍攝中那一次更新不准把碼翻出來。
                card.card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(600), attemptsLeft: 5,
                                                             callbackHost: "chatgpt.com", pairingCode: "73215947", popup: true,
                                                             surface: SecurityWatch.pairingKey))
                // G1b 第二輪（GPT-6 G1b 審查 #5）：照序號核對「這一次」拍的結果（當下查過像素的那一筆），不切環形快取。
                // 這一次一定要有一筆（prepareForm 真的拍了），而且是「拍成、標記像素 0」或「拒拍」。
                func thisCapture(_ run: () -> Void) -> [GlobalDMPanelCanvas.AuditEntry] {
                    let before = floatingCanvas?.captures ?? 0
                    run()
                    return (floatingCanvas?.auditLog ?? []).filter { $0.seq > before }
                }
                func safe(_ entries: [GlobalDMPanelCanvas.AuditEntry]) -> Bool {
                    entries.count == 1 && entries.allSatisfy { $0.outcome == .captured(markers: 0) || $0.outcome == .refused }
                }
                let pendingEntries = thisCapture { panels.prepareForm() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let backAfterPending = DMBrowserPhoneAcceptance.codeDrawn(in: floating)
                // (b) 拍攝中才出現的碼：先把碼收起來，再要它出來（還沒畫），馬上拍——新掛上的碼照樣藏著。
                presenter.setCodeVisible(false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                presenter.setCodeVisible(true)
                let appearingEntries = thisCapture { panels.prepareForm() }
                _ = await DMBrowserAcceptance.waitUntil(2) { DMBrowserPhoneAcceptance.codeDrawn(in: floating) }
                let backAfterAppearing = DMBrowserPhoneAcceptance.codeDrawn(in: floating)
                // 偵測本身有效：同一套檢查裝在一張故意含標記色的圖上＝記成「拍成、標記像素 > 0」（不會被當成乾淨的）。
                let auditCatches = (GlobalDMPanelCanvas.captureAudit.map { audit -> Int in
                    guard let host = floatingCanvas?.host, let raw = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
                    host.cacheDisplay(in: host.bounds, to: raw)
                    return raw.cgImage.map(audit) ?? -1
                } ?? -1) > 0
                print("W184FORMS NOTE A1 control=\(control) pending=\(pendingEntries) appearing=\(appearingEntries) problems=\(floatingCanvas?.captureProblems.suffix(3) ?? [])")
                check(control > 0 && auditCatches && safe(pendingEntries) && safe(appearingEntries) && backAfterPending && backAfterAppearing,
                      "A1 counterexamples (GPT-6 F3 #1), checked on this capture's own pixels by sequence number (checked the moment it was taken, never evicted): a capture made while a code update is pending, and one made while a new code view is being added, each happened exactly once and contain no code pixel (or were refused); afterwards the code is back on screen (restored to the current state, not forced); a direct capture of the same box does show the marker",
                      "control=\(control) catches=\(auditCatches) pending=\(pendingEntries) appearing=\(appearingEntries) back=\(backAfterPending)/\(backAfterAppearing)")
            }
            func pageBack() -> Bool {
                tag == "A" ? windows().contains { auth.window === $0 } && !auth.isHiddenOrHasHiddenAncestor
                    : windows().contains { DMBrowserPhoneAcceptance.codeDrawn(in: $0) }
            }
            // 1. 滑：外直 → 內橫（桌面控制器：Browser 換到右欄）；滑到一半又要叫頁面出來＝開框請求排隊，停下才做。
            var queuedMidway = false
            let slide = await observe(watch, "\(tag) slide", windows: windows, motion: panels.formMotion, midway: 0.1, then: {
                reveal()
                queuedMidway = desk.pendingContentCount > 0
            }) {
                _ = desk.setForm(.innerLandscape)
            }
            check(slide.ok && slide.frames > 40 && store.isBrowsingBeside && !store.isBrowsing && queuedMidway && desk.pendingContentCount == 0 && pageBack(),
                  "S1\(tag) slide (outer portrait → inner landscape) through the desk controller with the \(what) up: the Browser moves to the right column, a mid-slide request waits in the queue and runs after; every frame shielded / bound / gate on, watched past the linger",
                  "\(slide.detail) beside=\(store.isBrowsingBeside) queued=\(queuedMidway) pending=\(desk.pendingContentCount)")
            // 2. 轉向：內橫 → 外直，滑到一半轉向內直（離開內橫：Browser 收回、換成對話）；再按 Browser 圓鈕叫回來。
            let turn = await observe(watch, "\(tag) turn", windows: windows, motion: panels.formMotion, midway: 0.12, then: {
                _ = desk.setForm(.innerPortrait)
            }) {
                _ = desk.setForm(.outerPortrait)
            }
            let leftDuo = !store.isBrowsingBeside && !store.isBrowsing
            let back = await observe(watch, "\(tag) browser again", windows: windows, motion: panels.formMotion, minimum: 0.4) {
                store.showBrowser()
            }
            check(turn.ok && back.ok && turn.frames > 40 && leftDuo && pageBack(),
                  "S2\(tag) turning mid-slide (inner landscape → outer portrait → inner portrait) with the \(what) up: leaving inner landscape takes the Browser off screen (the release path), the Browser circle brings it back; every frame holds",
                  "turn=\(turn.detail) back=\(back.detail) leftDuo=\(leftDuo)")
            // 3. 減少動態效果：內直 → 外直（淡出、換框、淡入；syncDuo 照形態的訂閱跑）。
            let fade = await observe(watch, "\(tag) fade", windows: windows, motion: panels.formMotion) {
                settings.form = .outerPortrait
                panels.applyForm(.between(.innerPortrait, .outerPortrait, reduceMotion: true))
            }
            check(fade.ok && fade.frames > 30 && pageBack(), "S3\(tag) reduce motion (fade) with the \(what) up: every frame holds, watched past the linger", fade.detail)
            // 4. 轉換中收框（外直 → 內橫途中），再打開（內橫：Browser 在右欄）。
            let close = await observe(watch, "\(tag) close", windows: windows, motion: panels.formMotion, midway: 0.1, then: {
                store.isFloatingOpen = false
                panels.reconcile()
            }) {
                _ = desk.setForm(.innerLandscape)
            }
            let maskReleased = !GlobalDMNativePageMask.shared.isMasking && !panels.formMotion.isAnimating && !floating.isVisible
            let reopen = await observe(watch, "\(tag) reopen", windows: windows, motion: panels.formMotion, minimum: 0.5) {
                store.openFloating()
            }
            hideAll()
            let backAfterReopen = pageBack()
            check(close.ok && reopen.ok && maskReleased && backAfterReopen && WindowCaptureShield.shared.isShielding(floating),
                  "S4\(tag) closing the box mid-transition with the \(what) up: every frame holds, the mask is released at once; reopened, the \(what) is back on screen and shielded",
                  "close=\(close.detail) reopen=\(reopen.detail) released=\(maskReleased) back=\(backAfterReopen)")
            _ = desk.setForm(.outerPortrait, animated: false)
            let single = await observe(watch, "\(tag) single column", windows: windows, motion: panels.formMotion, minimum: 0.4) {
                store.showBrowser()
            }
            // 5. 停靠↔浮動換手（主視窗在畫面上）：浮動 → 停靠 → 浮動。
            let toDocked = await observe(watch, "\(tag) to docked", windows: windows, motion: panels.formMotion, minimum: 0.7) {
                store.openDocked()
            }
            hideAll()
            if tag == "B", let docked = panels.dockedPanelForTesting {
                let page = browser.activeID.flatMap { browser.page(for: $0)?.view }
                let codes = DMSecretCodeView.liveViews.filter { $0.window === docked }
                print("W194 S5B diagnostic: visible=\(docked.isVisible) page-in-dock=\(page?.window === docked) page-hidden=\(page?.isHiddenOrHasHiddenAncestor ?? true) surface=\(browser.shownSurface ?? -999) code-on-screen=\(presenter.codeOnScreen) reveals=\(presenter.revealsCode(card.card ?? .loading("fixture"))) codes=\(codes.count) hidden=\(codes.map { $0.isHiddenOrHasHiddenAncestor }) suppressed=\(DMSecretCodeView.suppressed) shielded=\(WindowCaptureShield.shared.isShielding(docked))")
            }
            let dockedShows = panels.dockedPanelForTesting.map { docked in
                docked.isVisible && (tag == "A" ? auth.window === docked : DMBrowserPhoneAcceptance.codeDrawn(in: docked))
                    && WindowCaptureShield.shared.isShielding(docked)
            } ?? false
            let toFloating = await observe(watch, "\(tag) to floating", windows: windows, motion: panels.formMotion, minimum: 0.7) {
                store.openFloating()
            }
            hideAll()
            check(single.ok && toDocked.ok && toFloating.ok && dockedShows,
                  "S5\(tag) docked ↔ floating hand-off with the \(what) up: every window holds every frame; in the docked box it is on screen and shielded",
                  "single=\(single.detail) docked=\(toDocked.detail) floating=\(toFloating.detail) dockedShows=\(dockedShows)")
            // 6. 拖、7. 縮放（浮動框）。
            let drag = await observeGrip(watch, "\(tag) drag", windows: windows, panels: panels, resize: false)
            let resize = await observeGrip(watch, "\(tag) resize", windows: windows, panels: panels, resize: true)
            panels.resetPlacement(.floating)
            check(drag.ok && resize.ok && drag.frames > 40 && resize.frames > 40,
                  "S6\(tag) dragging and resizing the box with the \(what) up: every frame holds, watched past the linger after release", "drag=\(drag.detail) resize=\(resize.detail)")
            // 8. 失焦（修正核對 #9：GPT-6 第 5 條要的失焦）：別的視窗拿走鍵盤焦點，頁面／碼照樣在畫面上、照樣擋。
            let blur = await observe(watch, "\(tag) focus lost", windows: windows, motion: panels.formMotion, minimum: 0.7) {
                helper.makeKeyAndOrderFront(nil)
            }
            let lostKey = !floating.isKeyWindow
            helper.orderOut(nil)
            check(blur.ok && lostKey && pageBack() && WindowCaptureShield.shared.isShielding(floating),
                  "S8\(tag) the box loses keyboard focus (another window becomes key) with the \(what) up: still on screen and shielded every frame",
                  "\(blur.detail) lostKey=\(lostKey)")
            if tag == "B" {
                // S11（W184 AB 補 F45 查核 #3）：縮成桌面圓鈕時收框＝框的內容先淡出 0.10 秒——這段時間框的內容（配對碼、綁住它的配對頁）
                // 照樣在畫面上：每一格照樣擋擷取、碼只跟它的頁一起出現、Computer Use 閘門開著；淡完才收框、縮回圓鈕。淡出途中按 ⌥⌘＝轉回來，
                // 一樣每一格守住。真的時鐘、真的桌面控制器。
                // 接在 S8B 之後：配對頁與碼正在浮動框裡。縮成桌面圓鈕（框開著：圓鈕不出現、框照舊開著，頁與碼不動）。
                desk.collapse()
                _ = await DMBrowserAcceptance.waitUntil(2) { desk.isCollapsed && floating.isVisible && panels.buttonMorph.phase == .idle }
                hideAll()
                _ = await DMBrowserAcceptance.waitUntil(3) { DMBrowserPhoneAcceptance.codeDrawn(in: floating) }
                let codeBefore = DMBrowserPhoneAcceptance.codeDrawn(in: floating)
                let setupNote = "collapsed=\(desk.isCollapsed) floating=\(floating.isVisible) browsing=\(store.isBrowsing) beside=\(store.isBrowsingBeside) page=\(browser.showsSurface(SecurityWatch.pairingKey)) codeOnScreen=\(presenter.codeOnScreen)"
                /// 動作之後每 8ms 看一格（S 的規則），duration 秒（midway：那一刻再做一次）；數：淡出中的格數、淡出中碼還畫著的格數。
                func watchFade(_ label: String, _ duration: Double, midway: (at: Double, then: () -> Void)? = nil,
                               _ action: () -> Void) async -> (ok: Bool, fading: Int, withCode: Int, detail: String) {
                    let before = watch.problems.count
                    action()
                    var fading = 0, withCode = 0, didMidway = midway == nil
                    let began = Date()
                    while Date().timeIntervalSince(began) < duration {
                        watch.sample(label, windows())
                        if panels.buttonMorph.phase == .clearing {
                            fading += 1
                            if DMBrowserPhoneAcceptance.codeDrawn(in: floating) { withCode += 1 }
                        }
                        if !didMidway, let midway, Date().timeIntervalSince(began) >= midway.at {
                            didMidway = true
                            midway.then()
                            watch.sample(label, windows())
                        }
                        try? await Task.sleep(nanoseconds: 8_000_000)
                    }
                    let new = Array(watch.problems[before...])
                    return (new.isEmpty, fading, withCode, new.prefix(4).joined(separator: "; "))
                }
                let fadeClose = await watchFade("S11 close", 1.2) { store.isFloatingOpen = false }
                let putAway = !floating.isVisible && panels.buttonMorph.phase == .idle
                // 淡出途中按 ⌥⌘：再開一次、再收一次，淡出 0.04 秒時按。
                store.openFloating()
                _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && panels.buttonMorph.phase == .idle }
                hideAll()
                _ = await DMBrowserAcceptance.waitUntil(3) { DMBrowserPhoneAcceptance.codeDrawn(in: floating) }
                let fadeTurn = await watchFade("S11 turn back", 0.8, midway: (0.04, { panels.handleToggle() })) {
                    store.isFloatingOpen = false
                }
                let turnedBack = floating.isVisible && store.isFloatingOpen && panels.buttonMorph.phase == .idle
                    && DMBrowserPhoneAcceptance.codeDrawn(in: floating) && WindowCaptureShield.shared.isShielding(floating)
                check(codeBefore && fadeClose.ok && fadeClose.fading > 3 && fadeClose.withCode > 0 && putAway && fadeTurn.ok && turnedBack,
                      "S11 (W184 AB, F45 #3) bubble mode: closing fades the box's content out first (about 0.10 s) — with the pairing code up, every frame of the fade is shielded, the code shows only with its page, the Computer Use gate is on — then the box is put away; ⌥⌘ mid-fade turns it back, just as guarded",
                      "codeBefore=\(codeBefore) close=\(fadeClose.ok) fading=\(fadeClose.fading) withCode=\(fadeClose.withCode) putAway=\(putAway) turn=\(fadeTurn.ok) turnedBack=\(turnedBack) \(setupNote) \(fadeClose.detail) \(fadeTurn.detail)")
                desk.restore()
                _ = await DMBrowserAcceptance.waitUntil(2) { !desk.isCollapsed }
                if !store.isFloatingOpen { store.openFloating() }
                _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible }
                hideAll()
                _ = await DMBrowserAcceptance.waitUntil(3) { pageBack() }

                // S10（A6：GPT-6 審查 F3 #6）：動畫中碼第一次出現、到期（卡片收掉）、撤銷（卡片收起）、換手（浮動 → 停靠）：每一格照樣守
                //（保護、碼綁頁、Computer Use 閘門、圖層台沒有標記色）。
                presenter.hide()
                presenter.setCodeVisible(false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let appears = await observe(watch, "S10 appears", windows: windows, motion: panels.formMotion, midway: 0.1, then: {
                    presenter.show()
                    presenter.setCodeVisible(true)
                }) { _ = desk.setForm(.innerLandscape) }
                let expires = await observe(watch, "S10 expires", windows: windows, motion: panels.formMotion, midway: 0.1, then: {
                    card.card = nil
                    presenter.setCodeVisible(false)
                }) { _ = desk.setForm(.outerPortrait) }
                card.card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(600), attemptsLeft: 5,
                                                             callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true,
                                                             surface: SecurityWatch.pairingKey))
                presenter.show()
                presenter.setCodeVisible(true)
                _ = await DMBrowserAcceptance.waitUntil(3) { DMBrowserPhoneAcceptance.codeDrawn(in: floating) }
                let revoked = await observe(watch, "S10 revoked", windows: windows, motion: panels.formMotion, midway: 0.1, then: {
                    presenter.hide()
                }) { _ = desk.setForm(.innerLandscape) }
                presenter.show()
                presenter.setCodeVisible(true)
                _ = await DMBrowserAcceptance.waitUntil(3) { DMBrowserPhoneAcceptance.codeDrawn(in: floating) }
                let handOff = await observe(watch, "S10 hand-off", windows: windows, motion: panels.formMotion, minimum: 0.7, midway: 0.1, then: {
                    store.openDocked()
                }) { _ = desk.setForm(.outerPortrait) }
                hideAll()
                check(appears.ok && expires.ok && revoked.ok && handOff.ok && watch.stageRenders > 0,
                      "S10 (A6) mid-slide the code appearing for the first time, expiring, being revoked and the box handing off to the docked panel: every frame holds (shield, code bound to its page, Computer Use gate, no marker pixel on the layer stage)",
                      "appears=\(appears.detail) expires=\(expires.detail) revoked=\(revoked.detail) handOff=\(handOff.detail) stageRenders=\(watch.stageRenders)")
                store.openFloating()
                _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible }
                hideAll()

            }
        }
        // 最後：遮蔽一定解除（不在轉換中、沒有藏著的原生頁）。卡片與分頁都收掉之後：所有面板（浮動框、藏起來的停靠框）都放掉保護（修正核對 #12）。
        let shield = WindowCaptureShield.shared
        let settledEnd = !GlobalDMNativePageMask.shared.isMasking && !panels.formMotion.isAnimating && GlobalDMNativePageMask.shared.hiddenPages.isEmpty
        presenter.hide()
        browser.closeAll()
        let allBack = await DMBrowserAcceptance.waitUntil(2) { panelWindows().allSatisfy { !shield.isShielding($0) } }
        let states = panelWindows().map { "\($0.accessibilityIdentifier()) visible=\($0.isVisible) holders=\(shield.holders(of: $0)) shielding=\(shield.isShielding($0))" }
        let codes = DMSecretCodeView.liveViews.map { "\($0.window?.accessibilityIdentifier() ?? "no window") hidden=\($0.isHiddenOrHasHiddenAncestor)" }
        // S9（W184 F3）：圖層台用的每一張圖，拍的那一刻配對碼與原生網頁都藏著（形態改之前拍的舊樣子、遮蔽持有後拍的新樣子）。
        // G1b 第二輪（GPT-6 G1b 審查 #5）：每一次拍當下就查過、記了序號——每個面板的紀錄從第一筆到最後一次拍（captures）一筆不漏、
        // 序號連續；拍成的每一張標記像素都是 0（被淘汰的早期圖也在紀錄裡）。
        let canvases = panelWindows().compactMap { $0.contentView as? GlobalDMPanelCanvas }
        let captureProblems = canvases.flatMap(\.captureProblems)
        let entries = canvases.flatMap(\.auditLog)
        let taken = entries.filter { if case .captured = $0.outcome { return true } else { return false } }
        let dirty = taken.filter { $0.outcome != .captured(markers: 0) }
        let complete = canvases.allSatisfy { canvas in
            let seqs = canvas.auditLog.map(\.seq)
            guard let first = seqs.first else { return canvas.captures == 0 }
            return seqs == Array(first...canvas.captures)
        }
        check(dirty.isEmpty && taken.count > 4 && complete,
              "S9 (A6) every picture the layer stage used — each checked pixel by pixel for the pairing code's and the sensitive pages' marker colour the moment it was taken, with its sequence number (none evicted, none skipped) — has none of it (the old look before the form changes, the new look under the mask); pictures stay in the panel's own layers",
              "taken=\(taken.count) refused=\(entries.filter { $0.outcome == .refused }.count) failed=\(entries.filter { $0.outcome == .failed }.count) withMarker=\(dirty.prefix(4)) complete=\(complete) problems=\(captureProblems.prefix(4))")
        // sharingType 真的值：只在讀得回來的環境比（ssh 無頭時設了 .none 之後讀回、還原都不準：DMBrowserAcceptance.windowSharingIsObservable）；
        // 讀不回的環境照樣比持有者（上面的 allBack），真的值記下來。
        let observable = DMBrowserAcceptance.windowSharingIsObservable()
        let sharing = panelWindows().map { "\($0.accessibilityIdentifier())=\($0.sharingType.rawValue)" }
        let sharingBack = !observable || panelWindows().allSatisfy { $0.sharingType != .none }
        check(settledEnd && allBack && sharingBack && panelWindows().count == 2 && watch.frames > 1_000,
              "S7 after every scenario the native-page mask is released (nothing left hidden); once the card and pages are gone every panel lets go of the capture shield, including the hidden docked box, and its sharingType is back",
              "settled=\(settledEnd) allBack=\(allBack) sharing=\(sharing) observable=\(observable) \(states) codes=\(codes) frames=\(watch.frames)")
        if !observable {
            check.skip("S7 sharingType 真的值：這個環境讀不回（ssh 無頭），持有者已驗（\(sharing.joined(separator: " "))）；主導實機驗")
        }
    }
}
#endif
