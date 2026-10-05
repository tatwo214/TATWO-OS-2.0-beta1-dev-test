#if DEBUG
import AppKit
import SwiftUI

/// W184 G2d（GPT-6 審查 G2d #6：「目前沒有任何一條能證明真滑鼠叫得出側欄／頂列」）：`TATWO2_SELFTEST=w184browser` 的 V 段——
/// 不開忽略開關（DMBrowserBarReveal.ignoresRealMouse＝false）、不用 listening:false：Browser 區正式掛上的那一份（DMBrowserBarRevealHost →
/// start(view) 裝本機與全域的滑鼠監聽）；滑鼠移動照使用者的路走——排進 App 的事件佇列（NSApp.postEvent），App 的事件迴圈送出時本機監聽收到，
/// 跟真的游標移動同一條（DMBrowserBarReveal.evaluate(event)）。量：
/// - V1 移入、移出：左緣叫出側欄、上緣叫出頂列；離開＝頂列馬上收、側欄 0.4 秒後才收。
/// - V2 收起延遲期間按側欄的一列：照樣按得到、做它的事；延遲到了才收，收了之後同一點給網頁。
/// - V3 收框：框收起來（視窗不在畫面上）＝側欄、頂列馬上收，經過同一個位置也不叫出來；打開之後照樣叫得出來；Browser 拿下來＝不再聽。
/// - V4 換形態（單欄→內橫）：舊的那一份不再聽；新的右欄照新的位置叫出（指標在左欄＝不叫）。
/// 別的房的自測可能在同一台 mini 動真的游標（全域監聽會照真的游標重算）：每一步送完馬上量；沒看到就再送一次（最多三次，最後一次送的才算）。
/// 真的 CEF 網頁不在這個建置裡（假頁面）；真的游標在 CEF 上的那一段由主導在 .032 實機照報告的步驟驗。
extension DMBrowserPhoneAcceptance {
    /// 送一個滑鼠移動（視窗座標）：排進 App 的事件佇列，等 App 的事件迴圈送出（本機監聽在那時收到）；看到想要的樣子就停，最多三次。
    @MainActor static func pointer(_ screen: Clickable, at point: NSPoint, until expected: () -> Bool) async -> Bool {
        for _ in 0..<3 {
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
            await screen.settle(2)
            if expected() { return true }
        }
        return false
    }

    /// 某一層側欄的命中區登記著（滑出、固定著才登記；網頁讓位）：貼著 x、高高的那一層（頂列那一條只有 48 高，不算）。
    @MainActor static func sidebarClaims(_ screen: Clickable, at x: CGFloat) -> Bool {
        views(BrowserChromeHitLayer.LayerView.self, in: screen.host).contains { layer in
            guard layer.isActive else { return false }
            let frame = layer.convert(layer.bounds, to: nil)
            return abs(frame.minX - x) < 1 && frame.width > 100 && frame.height > 150
        }
    }

    @MainActor static func realMouseChecks(_ check: Checker) async {
        let previous = DMBrowserBarReveal.ignoresRealMouse
        DMBrowserBarReveal.ignoresRealMouse = false
        defer { DMBrowserBarReveal.ignoresRealMouse = previous }
        let size = CGSize(width: 466, height: 610)
        /// 視窗座標：x、離 Browser 區頂端多遠。
        func at(_ x: CGFloat, _ fromTop: CGFloat) -> NSPoint { NSPoint(x: x, y: size.height - fromTop) }
        let phone = Phone("mouse")
        _ = phone.browser.openPod(purpose: .chatgptDeveloper)
        let typed = openedID(phone.browser.openBrowse(url: URL(string: "https://example.com/mouse")!, title: "打的網址", origin: .typed))
        if let pod = phone.browser.tabs.first(where: { $0.kind == .pod }) { phone.browser.select(pod.id) }
        let screen = Clickable(phone.pane(probes: true), size: size)
        await screen.settle()
        _ = await DMBrowserAcceptance.waitUntil(2) { screen.reveal?.isListening == true }
        guard let reveal = screen.reveal, reveal.isListening, let typed else {
            screen.close()
            phone.browser.closeAll()
            return check(false, "V0 the Browser area installs the real mouse monitors when it is put on screen (no ignore switch, no listening:false)")
        }

        // V1 移入、移出。
        let pageQuiet = await pointer(screen, at: at(300, 300)) { !reveal.isRevealed && !reveal.toolbarRevealed && !sidebarClaims(screen, at: 0) }
        let sideIn = await pointer(screen, at: at(6, 300)) { reveal.isRevealed && sidebarClaims(screen, at: 0) }
        let barIn = await pointer(screen, at: at(100, 6)) { reveal.toolbarRevealed && screen.toolbarDrawn && reveal.isRevealed }
        let barOut = await pointer(screen, at: at(400, 300)) { !reveal.toolbarRevealed }
        let sideHeld = reveal.isRevealed   // 還在收起延遲裡
        let sideGone = await DMBrowserAcceptance.waitUntil(1.5) { !reveal.isRevealed }
        await screen.settle(3)
        check(pageQuiet && sideIn && barIn && barOut && sideHeld && sideGone && !sidebarClaims(screen, at: 0),
              "V1 (W184 G2d; GPT-6 G2d #6) real mouse-move events through the app's event queue and the Browser's own monitors (no ignore switch, no listening:false): over the page nothing comes out; the left edge brings the sidebar out; the top edge brings the toolbar out; leaving hides the toolbar at once and the sidebar only after its 0.4 s delay",
              "page=\(pageQuiet) side=\(sideIn) bar=\(barIn) barOut=\(barOut) held=\(sideHeld) gone=\(sideGone)")

        // V2 收起延遲期間按側欄的一列。
        var duringDelay = false, hidAfter = false, pageAfter = false
        if await pointer(screen, at: at(6, 300), until: { reveal.isRevealed }),
           await pointer(screen, at: at(400, 300), until: { !reveal.toolbarRevealed && reveal.isRevealed }),
           let row = screen.center("side.tab.\(typed.uuidString)") {
            await screen.click(row)
            duringDelay = phone.browser.activeID == typed
            hidAfter = await DMBrowserAcceptance.waitUntil(1.5) { !reveal.isRevealed }
            await screen.settle(3)
            pageAfter = !sidebarClaims(screen, at: 0) && screen.pageTakes(row)
        }
        check(duringDelay && hidAfter && pageAfter,
              "V2 (W184 G2d; GPT-6 G2d #6) the pointer leaves the sidebar and, inside the 0.4 s delay, a sidebar row is pressed: the press still belongs to the sidebar and does its job (switches to that tab); when the delay runs out the sidebar goes and the same spot belongs to the page again",
              "during=\(duringDelay) hid=\(hidAfter) page=\(pageAfter)")

        // V3 收框：框收起來（orderOut）＝收起、經過左緣也不叫出來；打開之後叫得出來；Browser 拿下來＝不再聽。
        let outBefore = await pointer(screen, at: at(6, 300)) { reveal.isRevealed }
        screen.window.orderOut(nil)
        let closedQuiet = await pointer(screen, at: at(6, 300)) { !reveal.isRevealed && !reveal.toolbarRevealed }
        screen.window.orderFrontRegardless()
        let reopened = await pointer(screen, at: at(6, 300)) { reveal.isRevealed }
        (screen.host as? NSHostingView<AnyView>)?.rootView = AnyView(Color.clear.frame(width: size.width, height: size.height))
        let stopped = await DMBrowserAcceptance.waitUntil(2) { !reveal.isListening && !reveal.isRevealed && !reveal.toolbarRevealed }
        let reacted = await pointer(screen, at: at(6, 6)) { reveal.isRevealed || reveal.toolbarRevealed }
        let deaf = !reacted
        check(outBefore && closedQuiet && reopened && stopped && deaf,
              "V3 (W184 G2d; GPT-6 G2d #6) closing the box (its window leaves the screen) hides the sidebar and toolbar at once and a pointer at the old edge does not bring them out; reopened, the edge works again; taking the Browser off stops listening (nothing comes out any more)",
              "before=\(outBefore) closed=\(closedQuiet) reopened=\(reopened) stopped=\(stopped) deaf=\(deaf)")
        screen.close()
        phone.browser.closeAll()

        // V4 換形態：單欄 → 內橫（同一個視窗換成內橫的擺法，Browser 在右欄）。
        let duo = Phone("mouse-form")
        duo.store.showBrowser()
        _ = duo.browser.openPod(purpose: .chatgptDeveloper)
        let land = GlobalDMForm.innerLandscape.size
        let portrait = GlobalDMForm.outerPortrait.size
        let leading = (land.width * DMPhone.duoLeadingFraction).rounded()
        let window = Clickable(PhoneColumns(store: duo.store, form: .outerPortrait) { duo.pane(probes: true) }
                                .frame(width: portrait.width, height: portrait.height)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                               size: CGSize(width: land.width, height: max(land.height, portrait.height)))
        await window.settle()
        let height = max(land.height, portrait.height)
        /// 視窗座標：x、離框頂多遠。
        func box(_ x: CGFloat, _ fromTop: CGFloat) -> NSPoint { NSPoint(x: x, y: height - fromTop) }
        _ = await DMBrowserAcceptance.waitUntil(2) { window.reveal?.isListening == true }
        let single = window.reveal
        let singleOut = await pointer(window, at: box(6, DMPhone.headerHeight + 200)) { single?.isRevealed == true && sidebarClaims(window, at: 0) }
        (window.host as? NSHostingView<AnyView>)?.rootView = AnyView(
            PhoneColumns(store: duo.store, form: .innerLandscape) {
                duo.pane(probes: true)
                    .frame(width: land.width - leading - DMPhone.hairline)
                    .frame(width: land.width - leading, alignment: .trailing)
                    .padding(.top, DMPhone.headerHeight)
                    .clipped()
                    .padding(.top, -DMPhone.headerHeight)
                    .padding(.leading, leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: land.width, height: land.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(width: land.width, height: height)
            .environment(\.colorScheme, .light))
        _ = await DMBrowserAcceptance.waitUntil(2) { window.reveal.map { $0 !== single && $0.isListening } == true && single?.isListening == false }
        let right = window.reveal
        let oldDeaf: Bool = single?.isListening == false && single?.isRevealed == false
        let columnEdge = leading + DMPhone.hairline
        let leftStill = await pointer(window, at: box(6, DMPhone.headerHeight + 200)) { right?.isRevealed == false }
        let leftQuiet = leftStill && !sidebarClaims(window, at: columnEdge)
        let rightOut = await pointer(window, at: box(columnEdge + 6, DMPhone.headerHeight + 200)) { right?.isRevealed == true && sidebarClaims(window, at: columnEdge) }
        check(singleOut && right != nil && right !== single && oldDeaf && leftQuiet && rightOut,
              "V4 (W184 G2d; GPT-6 G2d #6) changing form (single column → inner landscape, the Browser moving to the right column): the old Browser area stops listening and hides; the new one listens — the pointer over the left (chat) column brings nothing out, the right column's left edge brings its sidebar out there",
              "singleOut=\(singleOut) new=\(right.map { $0 !== single } ?? false) oldDeaf=\(oldDeaf) leftQuiet=\(leftQuiet) rightOut=\(rightOut)")
        window.close()
        duo.browser.closeAll()
    }
}
#endif
