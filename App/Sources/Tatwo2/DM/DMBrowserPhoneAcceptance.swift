#if DEBUG
import AppKit
import Combine
import SwiftUI

/// `TATWO2_SELFTEST=w184browser`：W184 D 私訊框 Browser 與［連線］照手機 App——分頁總覽卡片格、配對卡浮在頁上、［連線］確認＝底部 sheet、
/// 截圖只擋授權頁與配對碼（每一條都有會失敗的反例）、主導補的 R9「新增 ▾」租約（內橫右欄）。
/// W184 G2：書籤、珍藏、切換空間（DMBrowserRailAcceptance.swift）。W184 G2d：頂列、側欄、沒分頁時的搜尋框改用主視窗 Browser space 的元件
/// （DMBrowserChromeAcceptance.swift：跟主視窗同一元件並排的畫面證據、主視窗元件的行為沒被改到）。
/// 規則＋真的畫出來量位置、點擊讓位、無障礙識別碼；畫面證據 PNG 寫進 TATWO2_SELFTEST_ARTIFACTS。完整隔離的 staging；
/// 不用任何 shared 單例（Browser、呈現層、流程都是自測自己建的；頁面是假的，這個建置沒有 Chromium）。
enum DMBrowserPhoneAcceptance {
    final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: String = "") {
            if condition { passed += 1 } else { failed += 1 }
            print("W184BROWSER \(condition ? "PASS" : "FAIL") \(label)\(condition || evidence.isEmpty ? "" : " — " + String(evidence.prefix(500)))")
        }
        func skip(_ label: String) {
            skipped += 1
            print("W184BROWSER SKIP \(label)")
        }
    }

    typealias Harness = DMBrowserAcceptance.Harness
    typealias FakePage = DMBrowserAcceptance.FakePage

    /// 畫面證據用的假頁面：白底、一行標題、幾條灰線（正式是 CEF 的網頁）。
    @MainActor final class EvidencePage: DMBrowserPage {
        /// W184 F3（A6）：自測把假配對頁畫成可辨識的顏色（檢查拍下來的圖、圖層台裡沒有它）。
        static var markerColor: NSColor?
        final class Canvas: NSView {
            var title = ""
            var marker: NSColor?
            override var isFlipped: Bool { true }
            override var acceptsFirstResponder: Bool { true }
            override func draw(_ dirtyRect: NSRect) {
                (marker ?? NSColor.white).setFill()
                bounds.fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                                                 .foregroundColor: NSColor.black]
                (title as NSString).draw(at: NSPoint(x: 24, y: 64), withAttributes: attributes)
                NSColor(white: 0.9, alpha: 1).setFill()
                for row in 0..<6 {
                    NSRect(x: 24, y: 108 + CGFloat(row) * 30, width: bounds.width * (row % 2 == 0 ? 0.72 : 0.5), height: 12).fill()
                }
            }
        }

        let canvas = Canvas(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        var canGoBack = true
        var canGoForward = false
        /// W184 G2 修正：左列的上一頁、下一頁真的按到、頁面有沒有被關掉（自測數）。
        var backs = 0, forwards = 0, closes = 0
        init(_ title: String) {
            canvas.title = title
            canvas.marker = Self.markerColor
        }
        var view: NSView { canvas }
        var isHumanActor: Bool { true }
        func goBack() { backs += 1 }
        func goForward() { forwards += 1 }
        func close() { closes += 1; canvas.removeFromSuperview() }
    }

    /// 卡片（呈現層讀它；自測自己換）。
    @MainActor final class CardBox { var card: HandsConnectCard? }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil else {
            throw BotLibraryError.invalid("w184browser needs a fully isolated staging environment")
        }
        let check = Checker()
        // 整個 w184browser 只照合成的滑鼠位置算側欄、頂列（不聽真的游標；別的房的自測會在同一台 mini 上動它）。
        DMBrowserBarReveal.ignoresRealMouse = true
        defer { DMBrowserBarReveal.ignoresRealMouse = false }
        tokenChecks(check)
        await revealChecks(check)
        await realMouseChecks(check)   // W184 G2d（GPT-6 審查 G2d #6）：不開忽略開關、真的事件路徑（排進 App 的事件佇列，local monitor 收）
        await shieldChecks(check)
        faceChecks(check)
        leaseChecks(check)
        presentationChecks(check)   // GPT-6 審查 #2、#6：實際呈現（看得到的視窗、沒被藏、不在轉換中）；租約分短暫轉換與真的收框
        maskChecks(check)           // 主導轉達房 AB：原生網頁的遮蔽狀態（GlobalDMNativePageMask）
        queuedOpenChecks(check)     // 主導轉達房 AB：open() 排隊時，框真的打開之後才記「打開後的樣子」
        layoutChecks(check)
        exitFrameChecks(check)      // GPT-6 審查 #1、#6：碼還畫著的每一幀都不給擷取（分頁總覽、取消、收框、換手、轉換）
        await sidebarChecks(check)  // W184 G2d：側欄＝主視窗 Browser space 的側欄（頂天、貼左緣、順序同主視窗）、卡片不被蓋
        await toolbarChecks(check)  // W184 G2d：頂列＝主視窗 Browser space 那一排（真的滑鼠按每一顆；窄的時候收進 ⋯）
        await searchChecks(check)   // W184 G2d：沒分頁、空白分頁＝主視窗那個置中的搜尋框（真的打字送出）
        mainComponentChecks(check)  // W184 G2d：主視窗 Browser space 的元件行為沒被改到；私訊框那一支不碰主視窗的分頁
        await shelfChecks(check)    // W184 G2：書籤、珍藏開新分頁不動流程分頁、切換空間、打網址、分頁滿了、一般分頁不算敏感
        await capacityChecks(check) // W184 G2 修正 1：不自動關使用者的頁、不替使用者取消別的流程、流程永遠有兩格
        await pointerChecks(check)  // 卡片的按鈕按得到、不被側欄蓋；網頁左邊不叫出側欄；側欄每一格真的做它的事；打網址時頂列不收
        await panelChecks(check)    // 流程叫到前面收起輸入、Esc 只收輸入（真的 Esc；輸入法、倒放的順序）
        await newTabChecks(check)   // W184 G2c：新分頁（側欄＋、分頁總覽的＋、⌘⌥T、滿了一句話）
        // W184 G2c 第二輪（GPT-6 審查 w184g2c；DMBrowserSidebarAcceptance.swift）：草稿綁在開始打字的空白分頁、⌘⌥T 走正式的面板控制器、
        // ⌥⌘T 不能設成直達鍵、小框＋最高的卡片、很多空間。
        await draftChecks(check)
        await newTabControllerChecks(check)
        directKeyChecks(check)
        await smallBoxChecks(check)
        await r12YieldChecks(check)   // W183 R12（主導 1）：單欄時連線卡片擺在網頁下面，網頁的下緣停在卡片上緣（不蓋網頁）
        await manySpacesChecks(check)
        await evidence(check)
        DMSecretCodeView.suppress(false)
        check.skip("真的 CEF 網頁上：側欄、頂列、浮卡蓋在網頁上且點得到、真的游標到左緣／上緣才滑出（這個建置沒有 Chromium；真的事件路徑已用 V1–V4 在假頁面上驗、讓位的規則已驗），主導 .032 實機照報告的步驟驗")
        check.skip("sharingType 真的值：只在讀得回來的環境驗（ssh 無頭讀回不準），持有者計數已驗；主導實機截圖驗")
        print("W184BROWSER SUMMARY passed=\(check.passed) failures=\(check.failed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    // MARK: - A 數字（對照稿）

    @MainActor static func tokenChecks(_ check: Checker) {
        let P = DMBrowserPhone.self
        check(P.pageTop == 4 && P.pageSide == 12 && P.pageBottom == 12 && P.pageRadius == 28 && DMPhone.hairline == 0.5,
              "A1 page frame (W184 G2d): margins top 4, left / right / bottom 12, radius 28, 0.5 separator edge — no handle strip on the left any more (the user said it was redundant)")
        // W184 G2d：側欄、頂列的數字直接取主視窗 Browser space 的（寬 250、左緣 18 叫出、右緣外 30 留著、0.4 秒才收、頂列 48、頂端 20 叫出）。
        let sidebar: Bool = P.sidebarMaxWidth == WorkspaceSidebarMetrics.width && P.sidebarWidth(for: 466) == 250
            && P.sidebarWidth(for: 342) == 222 && P.sidebarWidth(for: 250) == 180
            && P.revealZone == 18 && P.exitZone == 30 && P.sidebarCloseDelay == 0.40 && P.slide == 8
            && P.sidebarOpenDuration == 0.24 && P.sidebarCloseDuration == 0.22 && P.sidebarGap == 8
        let toolbar: Bool = P.toolbarHeight == BrowserOmniboxMetrics.toolbarHeight && P.toolbarHeight == 48
            && P.toolbarTrigger == BrowserChromeReveal.triggerBand && P.toolbarStay == 10 && P.toolbarFade == 0.12
            && P.toolbarToolsMinWidth == 420
        check(sidebar && toolbar,
              "A2 (W184 G2d) the sidebar and toolbar take the main window's Browser space numbers: sidebar 250 wide (narrower boxes: pane − 120, at least 180), out from the left 18pt, kept within 30 past its edge, hides 0.40 s after the pointer leaves, slides 8pt with opacity (0.24 s in / 0.22 s out); toolbar 48 high, out within the top 20pt (BrowserChromeReveal.triggerBand), kept within 48 + 10, 0.12 s fade; translate / extensions / notes fold into ⋯ below 420",
              "sidebar=\(sidebar) toolbar=\(toolbar)")
        let cardPlace: Bool = P.cardInset == 12 && P.cardBottom == 30
        let cardLook: Bool = P.cardPadding == 16 && P.cardRadius == 28 && P.codeSize == 34 && abs(P.codeTracking - 34 * 0.16) < 0.001
        check(cardPlace && cardLook,
              "A3 floating card (W184 G2c): 12 from both sides, 30 above the bottom (the sidebar stops 8 above it instead); padding 16, radius 28; the code is 34pt monospaced with 0.16em tracking")
        check(P.barInset == 12 && P.barHeight == 56 && P.barRadius == 28,
              "A2b the tab overview keeps its bottom glass capsule with 完成 (12 from the edges, 56 high, radius 28)")
        check(P.badgeTop == 10 && P.badgeHeight == 26 && P.badgeRadius == 13 && P.badgeOpacity == 0.78
              && DMBrowserShieldBadge.text.hasSuffix("這一頁不給截圖"),
              "A4 「這一頁不給截圖」badge: top-centred 10pt down, 26 high, radius 13, dark 0.78, white 11pt semibold")
        check(P.listTop == 6 && P.listSide == 16 && P.listBottom == 12 && P.listSpacing == 12 && P.gridSpacing == 12 && P.tabCardRadius == 24
              && P.tabCardRing == 2 && P.thumbnailHeight == 150 && P.closeSize == 28,
              "A5 tab overview: padding 6/16/12, spacing 12, two columns 12 apart, cards radius 24 (selected 2pt ring), 150pt neutral thumbnail, 28pt round close")
        let S = GlobalDMWebSheetLayout.self
        check(S.topInset == 96 && S.topRadius == 40 && S.bottomRadius == 52 && S.dimOpacity == 0.22 && S.grabberSize == CGSize(width: 36, height: 5)
              && S.contentTop == 10 && S.contentSide == 16 && S.contentBottom == 16 && S.contentSpacing == 18 && S.groupRadius == 26
              && S.rowHeight == 48 && S.navRowHeight == 52 && S.segmentHeight == 34,
              "A6 ［連線］ sheet: 0.22 dim, slides up to 96 from the top, radius 40 top / 52 bottom, 36×5 grabber; content 10/16/16 spaced 18; groups radius 26, rows 48 and 52; level segments 34 high")
        check(Set(P.textSizes) == [17, 15, 13, 11], "A7 text sizes are only 17/15/13/11 (the pairing code is the one display size, 34)")
    }

    // MARK: - B 側欄、頂列：滑鼠指到才展開（W184 G2d：同主視窗 Browser space）

    @MainActor static func revealChecks(_ check: Checker) async {
        let bounds = CGRect(x: 0, y: 0, width: 466, height: 600)
        let R = DMBrowserBarReveal.self
        // 側欄：收著＝只有左緣 18 以內（上到下都算）；網頁左邊的內容、Browser 區外面都不會。展開之後＝側欄右緣再往右 30 以內都留著。
        let edge = R.sidebarZone(CGPoint(x: 0, y: 10), bounds: bounds, revealed: false, width: 250)
            && R.sidebarZone(CGPoint(x: 18, y: 300), bounds: bounds, revealed: false, width: 250)
            && R.sidebarZone(CGPoint(x: 5, y: 590), bounds: bounds, revealed: false, width: 250)
        let quiet = !R.sidebarZone(CGPoint(x: 19, y: 300), bounds: bounds, revealed: false, width: 250)
            && !R.sidebarZone(CGPoint(x: 40, y: 300), bounds: bounds, revealed: false, width: 250)
            && !R.sidebarZone(CGPoint(x: -4, y: 300), bounds: bounds, revealed: false, width: 250)
        let stays = R.sidebarZone(CGPoint(x: 150, y: 300), bounds: bounds, revealed: true, width: 250)
            && R.sidebarZone(CGPoint(x: 280, y: 580), bounds: bounds, revealed: true, width: 250)
        let leaves = !R.sidebarZone(CGPoint(x: 281, y: 300), bounds: bounds, revealed: true, width: 250)
            && !R.sidebarZone(CGPoint(x: 470, y: 300), bounds: bounds, revealed: true, width: 250)
        // W184 G2d 第三輪（側欄頂天）：展開之後，側欄伸到框頂的那一段（私訊框頂列底下，Browser 區上面 68）也算；收著時那一段叫不出來。
        let above = R.sidebarZone(CGPoint(x: 120, y: -40), bounds: bounds, revealed: true, width: 250, above: 68)
            && !R.sidebarZone(CGPoint(x: 10, y: -40), bounds: bounds, revealed: false, width: 250, above: 68)
            && !R.sidebarZone(CGPoint(x: 120, y: -70), bounds: bounds, revealed: true, width: 250, above: 68)
            && !R.sidebarZone(CGPoint(x: 290, y: -40), bounds: bounds, revealed: true, width: 250, above: 68)
        // 頂列：收著＝頂端 20 以內（左右整個 Browser 區）；展開之後離頂 48＋10 以內都留著。
        let top = R.toolbarZone(CGPoint(x: 5, y: 0), bounds: bounds, revealed: false) && R.toolbarZone(CGPoint(x: 460, y: 20), bounds: bounds, revealed: false)
        let topQuiet = !R.toolbarZone(CGPoint(x: 200, y: 21), bounds: bounds, revealed: false)
        let topStays = R.toolbarZone(CGPoint(x: 200, y: 58), bounds: bounds, revealed: true)
        let topLeaves = !R.toolbarZone(CGPoint(x: 200, y: 59), bounds: bounds, revealed: true) && !R.toolbarZone(CGPoint(x: 200, y: -2), bounds: bounds, revealed: true)
        check(edge && quiet && stays && leaves && above && top && topQuiet && topStays && topLeaves,
              "B1 (W184 G2d, same as the main window's Browser space) the sidebar comes out only from the left 18pt (top to bottom) — never from the page's left part or outside the Browser — and once out stays within 30 past its right edge (and over its part that reaches up to the top of the box); the toolbar comes out only within the top 20pt (the whole width) and stays within 48 + 10",
              "edge=\(edge) quiet=\(quiet) stays=\(stays) leaves=\(leaves) above=\(above) top=\(top)/\(topQuiet)/\(topStays)/\(topLeaves)")
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 466, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 466, height: 600))
        window.contentView = content
        let anchor = DMBrowserBarAnchorView(frame: content.bounds)
        content.addSubview(anchor)
        let reveal = DMBrowserBarReveal()
        reveal.sidebarWidth = 250
        // 只照下面合成的位置算：不接 anchor 的追蹤區、不聽真的滑鼠（等 0.4 秒那兩段期間，真的游標在哪都不能插進來重算）。
        reveal.start(anchor, listening: false)
        /// 視窗座標（原點在左下）：x、離 Browser 區頂端多遠。
        func at(_ x: CGFloat, _ fromTop: CGFloat) { reveal.evaluate(windowPoint: NSPoint(x: x, y: 600 - fromTop)) }
        at(40, 300)
        let pageQuiet = !reveal.isRevealed && !reveal.toolbarRevealed
        at(10, 300)
        let shown = reveal.isRevealed && !reveal.toolbarRevealed
        at(150, 300)
        let onColumn = reveal.isRevealed
        // 同主視窗：指標離開側欄那一帶＝等 0.40 秒才收；期間回到側欄上＝不收。
        at(330, 300)
        let heldByDelay = reveal.isRevealed
        at(150, 320)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let cameBack = reveal.isRevealed
        at(330, 300)
        try? await Task.sleep(nanoseconds: 550_000_000)
        let closedAfterDelay = !reveal.isRevealed
        reveal.closeDelay = 0   // 以下量位置，不等延遲
        // 頂列：頂端 20 以內＝展開（任何 x）；往下到 58 還在；再往下＝收。
        at(300, 8)
        let toolbarOut = reveal.toolbarRevealed && !reveal.isRevealed
        at(300, 50)
        let toolbarStays = reveal.toolbarRevealed
        at(300, 80)
        let toolbarGone = !reveal.toolbarRevealed
        // 網址在打字（hold）：指標離開也不收；打完的當下照最後的位置重算。
        at(300, 8)
        reveal.hold(true)
        at(300, 300)
        let heldTyping = reveal.toolbarRevealed
        reveal.hold(false)
        let releasedTyping = !reveal.toolbarRevealed
        // 側欄固定著（頂列最左那顆）：滑鼠不管它（左緣不再叫出「浮出」的那一層）；拿掉固定之後照滑鼠位置重算。
        at(10, 300)
        let beforePin = reveal.isRevealed
        reveal.sidebarPinned = true
        let pinnedQuiet = !reveal.isRevealed
        at(10, 300)
        let pinnedStillQuiet = !reveal.isRevealed
        reveal.sidebarPinned = false
        let unpinnedFollows = reveal.isRevealed
        reveal.stop()
        let stopped = !reveal.isRevealed && !reveal.toolbarRevealed
        check(pageQuiet && shown && onColumn && heldByDelay && cameBack && closedAfterDelay,
              "B2 in a real window (synthetic mouse, cursor untouched): the page's left part does not bring the sidebar out; the left 18pt does; on the sidebar it stays; leaving it keeps it for 0.40 s (coming back in time keeps it), then it hides — same as the main window's hover sidebar",
              "page=\(pageQuiet) shown=\(shown) column=\(onColumn) delay=\(heldByDelay) back=\(cameBack) closed=\(closedAfterDelay)")
        check(toolbarOut && toolbarStays && toolbarGone && heldTyping && releasedTyping && beforePin && pinnedQuiet && pinnedStillQuiet && unpinnedFollows && stopped,
              "B3 the toolbar comes out at the top 20pt and stays within 58, hides below; while the address is being typed it stays with the pointer away and follows the pointer again when typing ends; a pinned sidebar ignores the pointer (it is simply there) and unpinning follows the pointer again; the Browser leaving the screen hides both",
              "toolbar=\(toolbarOut)/\(toolbarStays)/\(toolbarGone) typing=\(heldTyping)/\(releasedTyping) pin=\(beforePin)/\(pinnedQuiet)/\(pinnedStillQuiet)/\(unpinnedFollows) stopped=\(stopped)")
        // B4（W184 G2d：側欄是主視窗那一份，最下面有下載鈕）：側欄上開著下載清單＝側欄留著（同主視窗 store.sidebarInteractionActive；
        // 指標跑到清單那一塊、跑出側欄一帶也不收）；關掉的當下照最後的位置重算（指標在網頁上＝收）。
        let held = DMBrowserBarReveal()
        held.sidebarWidth = 250
        held.closeDelay = 0
        held.start(anchor, listening: false)
        held.evaluate(windowPoint: NSPoint(x: 10, y: 300))
        let heldOut = held.isRevealed
        held.holdSidebar(true)
        held.evaluate(windowPoint: NSPoint(x: 400, y: 300))
        let kept = held.isRevealed && held.holdsSidebar
        held.holdSidebar(false)
        let released = !held.isRevealed && !held.holdsSidebar
        held.stop()
        check(heldOut && kept && released,
              "B4 (W184 G2d) while the sidebar's downloads list is open the sidebar stays out even with the pointer far off it (the main window's sidebarInteractionActive); closing the list re-evaluates at once (pointer on the page = the sidebar hides)",
              "out=\(heldOut) kept=\(kept) released=\(released)")
        window.contentView = nil
    }

    @MainActor static func shieldChecks(_ check: Checker) async {
        let observable = DMBrowserAcceptance.windowSharingIsObservable()
        let shield = WindowCaptureShield.shared
        let h = Harness("w184shield")
        let (window, holder) = DMBrowserAcceptance.windowed("w184shield")
        let before = window.sharingType
        var seen: [NSWindow.SharingType] = []
        h.browser.release(h.surface)   // 自測的框一開始接著一個沒有視窗的框：拿掉，當作「私訊框在看對話」
        // 1. 敏感分頁（Cloudflare 授權頁）開著，但框在看對話（頁面沒放在任何框）＝可截；Computer Use 閘門照舊擋。
        let first = DMBrowserAcceptance.loginURL("W184SHIELDA"), second = DMBrowserAcceptance.loginURL("W184SHIELDB")
        h.browser.open(url: first, purpose: .cloudflareLogin)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 1 && h.browser.activeTab.map { h.browser.page(for: $0.id) != nil } == true }
        let chat = h.browser.captureProtectedWindow == nil && shield.holders(of: window) == 0 && h.browser.isSensitive && BrowserSensitivePageGate.isActive
        check(chat, "D5-1 counterexample: a sensitive tab is open but the box shows the conversation → the window CAN be captured; the Computer Use gate still refuses TATWO",
              "held=\(String(describing: h.browser.captureProtectedWindow)) gate=\(BrowserSensitivePageGate.isActive)")
        // 2. 切到那個敏感分頁（Browser 在框裡看得到）＝不可截。
        h.browser.claim(holder)
        let onPage = h.browser.captureProtectedWindow === window && shield.holders(of: window) == 1
        seen.append(window.sharingType)
        check(onPage, "D5-2 switching to the sensitive tab (Browser on screen) → that window cannot be captured")
        // 3. 選中別的（完成的）分頁＝放手（敏感分頁還開著：閘門照舊）；再選回敏感分頁＝不可截。
        h.browser.open(url: second, purpose: .cloudflareLogin)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 2 }
        h.browser.loginPage(second, .done)
        let doneFront = h.browser.activeTab?.done == true && h.browser.captureProtectedWindow == nil && shield.holders(of: window) == 0
            && h.browser.isSensitive && BrowserSensitivePageGate.isActive
        DMBrowserAcceptance.settleShield()   // 放手之後視窗再擋 linger 一小段才還原
        seen.append(window.sharingType)
        if let sensitive = h.browser.tab(start: first) { h.browser.select(sensitive.id) }
        let backOn = h.browser.captureProtectedWindow === window
        check(doneFront && backOn,
              "D5-3 counterexample: a finished (non-sensitive) tab in front → capture allowed while the sensitive tab waits behind (gate still on); selecting it again blocks capture",
              "doneFront=\(doneFront) backOn=\(backOn)")
        // 4. 分頁總覽開著（頁面拿下來，卡片格沒有縮圖）＝可截；收起來＝不可截。
        h.browser.isShowingTabList = true
        let list = h.browser.captureProtectedWindow == nil && shield.holders(of: window) == 0
        h.browser.isShowingTabList = false
        let listClosed = h.browser.captureProtectedWindow === window
        check(list && listClosed, "D5-4 counterexample: the tab overview is open (no page on screen) → capture allowed; closing it blocks capture again")
        // 5. 收起來、倒放（Browser 從畫面拿掉）＝放手。
        h.browser.release(holder)
        let collapsed = h.browser.captureProtectedWindow == nil && shield.holders(of: window) == 0
        h.browser.claim(holder)
        check(collapsed && h.browser.captureProtectedWindow === window,
              "D5-5 counterexample: collapsing the box or turning it into the tent (Browser off screen) → capture allowed; back on screen → blocked")
        // 6. 配對碼：確認卡、進行中的卡片本身不擋（W184 D）；碼顯示＝連線卡片也持有（兩個持有者）；碼收起來＝卡片放手、授權頁還在畫面上照樣擋；
        //    碼顯示中打開分頁總覽（碼遮起來、頁面拿下來）＝兩個都放手、還原。
        let box = CardBox()
        let presenter = HandsConnectPresenter(store: h.store, openBox: { h.panels.open() }, browser: h.browser, hookPod: { _ in },
                                              podURL: { nil }, cancelFlow: {}, card: { box.card })
        presenter.cardWindow = window
        box.card = .loading("讀取中")
        presenter.show()
        h.browser.adoptPopup(FakePage(), key: 41, purpose: .chatgptPairing, expectedHost: nil)
        let cardOnly = presenter.captureProtectedWindow == nil && HandsConnectPresenter.anySensitive
        let view = HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(300), attemptsLeft: 5,
                                           callbackHost: "chatgpt.com", pairingCode: "12345678", popup: true, surface: 41)
        box.card = .pairing(view)
        presenter.setCodeVisible(true)
        let codeShown = presenter.codeOnScreen && presenter.captureProtectedWindow === window && h.browser.captureProtectedWindow === window
            && shield.holders(of: window) == 2
        seen.append(window.sharingType)
        check(cardOnly && codeShown,
              "D5-6 the ［連線］ card by itself no longer blocks capture (Computer Use gate unchanged); the pairing code on screen → the card holds the window too (two holders)",
              "cardOnly=\(cardOnly) codeShown=\(codeShown) holders=\(shield.holders(of: window))")
        box.card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(300), attemptsLeft: 5,
                                                    callbackHost: "chatgpt.com", pairingCode: nil, popup: true, surface: 41))
        presenter.setCodeVisible(false)
        let codeGoneStillPage = presenter.captureProtectedWindow == nil && h.browser.captureProtectedWindow === window && shield.holders(of: window) == 1
        seen.append(window.sharingType)
        check(codeGoneStillPage,
              "D5-7 two holders on one window: the code is taken back → the card lets go, the pairing page is still on screen → the window stays blocked (last holder restores)")
        box.card = .pairing(view)
        presenter.setCodeVisible(true)
        let twoAgain = shield.holders(of: window) == 2
        h.browser.isShowingTabList = true   // 碼綁的那一頁不在畫面上：碼遮起來
        let hiddenByList = !presenter.codeOnScreen && presenter.captureProtectedWindow == nil && h.browser.captureProtectedWindow == nil
            && shield.holders(of: window) == 0
        DMBrowserAcceptance.settleShield()
        seen.append(window.sharingType)
        check(twoAgain && hiddenByList,
              "D5-8 counterexample: the code is covered (tab overview) → both holders let go at once and the window can be captured again",
              "two=\(twoAgain) hidden=\(hiddenByList)")
        h.browser.isShowingTabList = false
        let codeBack = presenter.codeOnScreen && shield.holders(of: window) == 2
        h.browser.release(holder)   // 收起來：碼與頁面都不在畫面上
        let collapsedWithCode = !presenter.codeOnScreen && shield.holders(of: window) == 0
        check(codeBack && collapsedWithCode, "D5-9 code back on screen → both hold; collapsing the box with the code up → both let go")
        presenter.hide()
        let hiddenCard = presenter.captureProtectedWindow == nil && shield.holders(of: window) == 0
        check(hiddenCard, "D5-10 the card goes away → nothing left holding the window")
        DMBrowserAcceptance.settleShield()
        if observable {
            check(seen == [.none, before, .none, .none, before] && window.sharingType == before,
                  "D5-11 the window really switches sharingType (.none only while an authorisation page or the code is on screen) and goes back to its own setting",
                  seen.map { String($0.rawValue) }.joined(separator: ","))
        } else {
            check.skip("D5-11 sharingType 真的值：這個環境讀不回（ssh 無頭），持有者計數已驗")
        }
        // 小標跟持有同一條規則。
        let B = DMBrowser.self
        check(B.capturesBlocked(activeSensitive: true, tabList: false, onScreen: true) && !B.capturesBlocked(activeSensitive: true, tabList: true, onScreen: true)
              && !B.capturesBlocked(activeSensitive: true, tabList: false, onScreen: false) && !B.capturesBlocked(activeSensitive: false, tabList: false, onScreen: true),
              "D5-12 the 「這一頁不給截圖」badge and the window hold use the same rule: sensitive tab in front, no tab overview, Browser on screen")
        h.browser.closeAll()
        window.contentView = nil
    }

    // MARK: - C 卡片在手機上是哪一種

    @MainActor static func faceChecks(_ check: Checker) {
        typealias F = HandsConnectCardFace
        // W183 R10：TATWO 代勾；「輪到你勾」只剩退路（那一格不在畫面上、TATWO 點了沒勾到）——字講清楚是 TATWO 這次沒勾成。
        let ack = F.make(.waitingUser(HandsConnectFlow.riskAckCardText, continuable: true), phase: .waitingUser)
        let missed = F.make(.waitingUser(HandsConnectFlow.tickMissedCardText, continuable: true), phase: .waitingUser)
        let changed = F.make(.waitingUser(HandsConnectFlow.warningChangedCardText, continuable: true), phase: .waitingUser)
        check(ack.kind == .turn && ack.title == "輪到你：勾選「I understand」" && ack.line.hasPrefix("TATWO 這次沒辦法替你勾")
              && ack.actions == [.continueAfterUser] && ack.dismissTitle == "取消"
              && missed.title == ack.title && missed.line.hasPrefix("TATWO 沒勾到") && missed.actions == [.continueAfterUser]
              // W183 R11：卡上只留一句短話（整句照舊在流程裡：detail 給滑過的提示、無障礙）。
              && changed.kind == .turn && changed.line == F.changedLine && changed.detail == HandsConnectFlow.warningChangedCardText
              && changed.actions == [.continueAfterUser],
              "C1 W183 R10 risk tick fallback only: 「輪到你：勾選「I understand」」 says TATWO couldn't tick it this time (or missed), 取消｜繼續; a changed warning says why in one sentence (W183 R11: one short line, the full sentence kept as the hint)")
        let tick = F.make(.waitingUser(HandsConnectFlow.untrustedTickCardText, continuable: true), phase: .waitingUser)
        let login = F.make(.waitingUser("ChatGPT 還沒登入（或要驗證）：在上面的頁面登入 ChatGPT。", continuable: false), phase: .waitingUser)
        // W183 R11：R9 的整句照舊在（detail），卡上換成一句短話；登入那一張＝短句「登入好自動接著連」。
        let loginWait = F.make(.waitingUser(HandsConnectFlow.loginCardText, continuable: false), phase: .waitingUser)
        check(tick.kind == .turn && tick.line == F.untrustedLine && tick.detail == HandsConnectFlow.untrustedTickCardText
              && tick.actions == [.continueAfterUser] && login.kind == .turn && login.actions.isEmpty
              && loginWait.line == F.loginLine && loginWait.actions.isEmpty,
              "C2 other 「輪到你」 cards keep R9's words as the hint and show one short line; not continuable = only 取消 (top right)")
        let pairing = HandsConnectPairingView(displayCode: "AB12", expiresAt: Date(), attemptsLeft: 5, callbackHost: "chatgpt.com",
                                              pairingCode: nil, popup: true)
        let code = F.make(.pairing(pairing), phase: .waitingPairing)
        let manual = F.make(.manual(url: "https://example.com/mcp", steps: ["a"]), phase: .needsManual)
        check(code.kind == .code && code.title == "配對碼・只在這台" && manual.kind == .manual,
              "C3 pairing → the code card 「配對碼・只在這台」; manual → R9's steps")
        let needs = F.make(.needsManual("看不到授權頁"), phase: .needsManual)
        let failed = F.make(.failed("出錯了"), phase: .failed)
        let refused = F.make(.refused("網域不符"), phase: .refused)
        check(needs.actions == [.manual, .retry] && failed.actions == [.retry] && refused.actions == [.retry]
              && failed.mark == .warning && refused.line == "網域不符",
              "C4 errors: one sentence + 再連一次 (needs manual: 手動 or 再連一次)")
        // W183 R11：已連線卡＝「已連線：Codex、記憶」＋［斷線］＋右上「完成」；已斷線＝一句＋［連線］＋「完成」。
        let done = F.make(.connected(HandsConnectFlow.connectedText(level: 2)), phase: .connected)
        let gone = F.make(.disconnected(HandsConnectFlow.disconnectedText), phase: .idle)
        check(done.mark == .done && done.dismissTitle == "完成" && done.actions == [.disconnect] && done.kind == .connected
              && done.line == "已連線：Codex、記憶" && gone.kind == .disconnected && gone.actions == [.reconnect] && gone.dismissTitle == "完成",
              "C5 connected: a check mark, 「已連線：Codex、記憶」, 斷線 and 完成 (W183 R11); disconnected: one line, 連線 and 完成")
        let busy = [F.make(.loading("讀取中"), phase: .waitingTap), F.make(.working("準備中"), phase: .creatingConnector),
                    F.make(.verifying("驗證中"), phase: .verifying)]
        check(busy.allSatisfy { $0.kind == .status && $0.mark == .progress && $0.actions.isEmpty },
              "C6 loading, working, verifying: one sentence with a spinner, no extra button")
    }

    // MARK: - E 主導：R9「新增 ▾」的 Pod 操作租約（內橫右欄）

    @MainActor static func leaseChecks(_ check: Checker) {
        let h = Harness("w184lease")
        let (window, holder) = DMBrowserAcceptance.windowed("w184lease")
        h.browser.release(h.surface)
        h.browser.claim(holder)
        _ = h.browser.openPod(purpose: .chatgptDeveloper)
        let single = h.store.isBrowsing && !ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        // 內橫：Browser 在右欄（isBrowsingBeside），左欄是對話（主 store 的 isBrowsing＝false）；ChatGPT Dev 的頁面照樣在畫面上。
        h.store.isBrowsing = false
        h.store.isBrowsingBeside = true
        let oldRuleDrops = !h.store.isEnabled || (!h.store.isOpen && !h.store.isFloatingOpen) || !h.store.isBrowsing
        let beside = !ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        check(single && beside && oldRuleDrops,
              "E1 (lead, R9 gap) the 「新增 ▾」 lease counts the ChatGPT Dev page as on screen in one column AND in the inner-landscape right column — counterexample: the old store.isBrowsing rule would have dropped the lease here",
              "single=\(single) beside=\(beside) oldRuleDrops=\(oldRuleDrops)")
        h.browser.isShowingTabList = true
        let list = ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        h.browser.isShowingTabList = false
        h.browser.adoptPopup(FakePage(), key: 51, purpose: .chatgptLogin, expectedHost: nil)   // 另一個分頁在最前面
        let other = ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        if let pod = h.browser.tabs.first(where: { $0.kind == .pod }) { h.browser.select(pod.id) }
        let back = !ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        h.browser.release(holder)   // 看對話、收起來、倒放：頁面不在任何框
        let chat = ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        h.browser.claim(holder)
        h.store.isEnabled = false
        let off = ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        h.store.isEnabled = true
        check(list && other && back && chat && off,
              "E2 the lease is let go when the ChatGPT Dev page is not on screen: tab overview, another tab in front, the box off the Browser (conversation, collapsed, tent), the DM switch off",
              "list=\(list) other=\(other) back=\(back) chat=\(chat) off=\(off)")
        h.browser.closeAll()
        window.contentView = nil
    }

    // MARK: - H 實際呈現（GPT-6 審查 #2、#6）：看得到的視窗、沒被藏、不在轉換中；租約分短暫轉換與真的收框

    @MainActor static func presentationChecks(_ check: Checker) {
        let h = Harness("w184present")
        let (window, _) = DMBrowserAcceptance.windowed("w184present")
        let container = DMBrowserPageContainer(frame: NSRect(x: 0, y: 0, width: 466, height: 600))
        window.contentView?.addSubview(container)
        h.browser.release(h.surface)
        h.browser.claim(container)
        _ = h.browser.openPod(purpose: .chatgptDeveloper)
        let pairing = FakePage()
        h.browser.adoptPopup(pairing, key: 81, purpose: .chatgptPairing, expectedHost: nil)
        let onScreen = h.browser.showsSurface(81) && h.browser.activeID.map { h.browser.presents($0) } == true
        // 停靠框只 orderOut（內容照樣掛著、沒拆）＝看不到：不給碼。回到畫面上才又給。
        window.orderOut(nil)
        let orderedOut = !h.browser.showsSurface(81) && pairing.view.window === window
        window.orderFrontRegardless()
        let back = h.browser.showsSurface(81)
        check(onScreen && orderedOut && back,
              "H1 counterexample: the docked panel only ordered out (content still mounted, not unmounted) → the pairing page is not on screen, no code; ordered back in → code allowed again",
              "on=\(onScreen) out=\(orderedOut) back=\(back)")
        // 形態轉換把原生網頁藏起來（isHidden）：掛在框裡也不算看得到。
        pairing.view.isHidden = true
        let hiddenPage = !h.browser.showsSurface(81)
        pairing.view.isHidden = false
        check(hiddenPage && h.browser.showsSurface(81),
              "H2 counterexample: the native page is hidden (as the form transition does) though still attached → no code; shown again → code allowed")
        // 轉換一開始就不算看得到（原生網頁恢復、轉換結束才又算）；畫著的配對碼同步藏起來。
        let codeView = DMSecretCodeView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(codeView)
        h.transitions.send(true)
        let during = !h.browser.showsSurface(81) && h.browser.isTransitioning && DMSecretCodeView.suppressed && codeView.isHidden
        h.transitions.send(false)
        let after = h.browser.showsSurface(81) && !h.browser.isTransitioning && !DMSecretCodeView.suppressed
        codeView.removeFromSuperview()
        check(during && after,
              "H3 counterexample: the form transition starts → the code is hidden at once (synchronously, before the first animated frame) and the page no longer counts as on screen; the transition ends → allowed again",
              "during=\(during) after=\(after)")
        // 租約（R9「新增 ▾」）：短暫的轉換、原生網頁暫時藏起來＝不放；真的收框（orderOut、拆掉）＝放。
        if let pod = h.browser.tabs.first(where: { $0.kind == .pod }) { h.browser.select(pod.id) }
        let podView = h.browser.activeTab.flatMap { h.browser.page(for: $0.id) }?.view
        h.transitions.send(true)
        podView?.isHidden = true
        let keptDuringTransition = !ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        podView?.isHidden = false
        h.transitions.send(false)
        window.orderOut(nil)
        let releasedOnOrderOut = ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        window.orderFrontRegardless()
        let keptBack = !ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        h.browser.release(container)
        let releasedWhenUnmounted = ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        check(keptDuringTransition && releasedOnOrderOut && keptBack && releasedWhenUnmounted,
              "H4 the 「新增 ▾」 lease is kept through a short form transition (page hidden for the animation) but let go when the panel is really ordered out or the Browser is unmounted",
              "transition=\(keptDuringTransition) orderOut=\(releasedOnOrderOut) back=\(keptBack) unmounted=\(releasedWhenUnmounted)")
        window.orderOut(nil)
        check(!DMBrowser.windowShowsPages(window), "H5 counterexample: an ordered-out window never counts as showing pages")
        h.browser.closeAll()
        window.contentView = nil
    }

    /// H6（主導轉達房 AB）：換形態時原生網頁的遮蔽狀態（GlobalDMNativePageMask.isMasking）：遮蔽中＝頁面不在畫面上、碼同步藏起來；
    /// 「新增 ▾」租約不放（短暫的轉換）；遮蔽結束（頁面顯示回來）才又給碼。
    @MainActor static func maskChecks(_ check: Checker) {
        let h = Harness("w184mask")
        let (window, holder) = DMBrowserAcceptance.windowed("w184mask")
        h.browser.release(h.surface)
        h.browser.claim(holder)
        _ = h.browser.openPod(purpose: .chatgptDeveloper)
        h.browser.adoptPopup(FakePage(), key: 82, purpose: .chatgptPairing, expectedHost: nil)
        let codeView = DMSecretCodeView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(codeView)
        let before = h.browser.showsSurface(82) && !codeView.isHidden
        let mask = GlobalDMNativePageMask.shared
        let token = mask.begin()
        let masked = !h.browser.showsSurface(82) && h.browser.isMasking && codeView.isHidden && DMSecretCodeView.suppressed
        if let pod = h.browser.tabs.first(where: { $0.kind == .pod }) { h.browser.select(pod.id) }
        let leaseKept = !ChatGPTPluginNewMenu.leftDevTab(store: h.store, browser: h.browser)
        mask.end(token)
        if let pairing = h.browser.tabs.first(where: { $0.kind == .popup(82) }) { h.browser.select(pairing.id) }
        let after = h.browser.showsSurface(82) && !h.browser.isMasking && !DMSecretCodeView.suppressed
        codeView.removeFromSuperview()
        check(before && masked && leaseKept && after,
              "H6 counterexample (room AB's native-page mask): while masking the pairing page is not on screen and the code is hidden at once; the 「新增 ▾」 lease is kept (a short transition); mask over → code allowed again",
              "before=\(before) masked=\(masked) lease=\(leaseKept) after=\(after)")
        h.browser.closeAll()
        window.contentView = nil
    }

    /// H7（主導轉達房 AB：open() 在倒放先立起、轉換中排隊）：框真的打開之後才記「打開後的樣子」，流程結束照樣收回。
    /// 反例：以前叫完 openBox 當下就記——排隊時記成「還沒打開」，收尾時框不會收回。
    /// W184 AB（GPT-6 複核 新發現 3）：假的關口照正式那樣收整個開框請求，出列時走 run（完成回呼記「打開後的樣子」）。
    @MainActor static func queuedOpenChecks(_ check: Checker) {
        func freshStore(_ name: String) -> GlobalDMStore {
            GlobalDMStore(defaults: UserDefaults(suiteName: "w184browser.\(name).\(UUID().uuidString)") ?? .standard,
                          chatGPTAllowed: { true }, directKeys: true)
        }
        let store = freshStore("queued-browser")
        var queued: [@MainActor () -> Void] = []
        let browser = DMBrowser(store: store, openRequest: { request in queued.append { request.run(store: store) { store.isFloatingOpen = true } } },
                                pageHost: DMBrowserAcceptance.FakeWebHost(), podPage: { FakePage() }, windowShown: { $0.isVisible })
        _ = browser.openPod(purpose: .chatgptDeveloper)
        let waiting = !store.isFloatingOpen && queued.count == 1
        for run in queued { run() }
        queued = []
        let opened = store.isFloatingOpen
        browser.closeAll()
        let restored = !store.isFloatingOpen
        check(waiting && opened && restored,
              "H7 counterexample: the Browser's open() is queued (tent stands up / transition running) — the box state is recorded when it really opens, so closing every tab closes the box again",
              "waiting=\(waiting) opened=\(opened) restored=\(restored)")

        let cardStore = freshStore("queued-card")
        var cardQueue: [@MainActor () -> Void] = []
        let cardBrowser = DMBrowser(store: cardStore, openBox: {}, pageHost: DMBrowserAcceptance.FakeWebHost(), podPage: { FakePage() },
                                    windowShown: { $0.isVisible })
        let presenter = HandsConnectPresenter(store: cardStore,
                                              openRequest: { request in cardQueue.append { request.run(store: cardStore) { cardStore.isFloatingOpen = true } } },
                                              browser: cardBrowser, hookPod: { _ in }, podURL: { nil }, cancelFlow: {}, card: { .loading("讀取中") })
        presenter.show()
        let cardWaiting = !cardStore.isFloatingOpen && cardQueue.count == 1
        for run in cardQueue { run() }
        let cardOpened = cardStore.isFloatingOpen
        presenter.hide()
        let cardRestored = !cardStore.isFloatingOpen
        check(cardWaiting && cardOpened && cardRestored,
              "H7 counterexample: the ［連線］ card's open() is queued — recorded when the box really opens, and the box closes again when the card goes away",
              "waiting=\(cardWaiting) opened=\(cardOpened) restored=\(cardRestored)")
        cardBrowser.closeAll()
    }

    // MARK: - F 真的畫出來量：頁面框、操作列、浮卡的位置；點擊讓位；識別碼

    @MainActor static func inertFlow() -> HandsConnectFlow {
        HandsConnectFlow(dependencies: .init(link: { (nil, "w184browser") }, pod: { HandsConnectAcceptance.FakePod(window: { false }) },
                                             presenter: { HandsConnectAcceptance.FakePresenter() }, localDeviceID: { nil }, copy: { _ in }))
    }

    /// 一支手機的 Browser（假 Pod 頁、假配對頁、假授權頁）＋連線卡片呈現層（卡片由 CardBox 給）。
    /// W184 G2：Browser space 也是自測自己的一份（只在記憶體的分頁清單＋它的 store；不碰正式的）。
    @MainActor final class Phone {
        let store: GlobalDMStore
        let browser: DMBrowser
        let flow: HandsConnectFlow
        let box: CardBox
        let presenter: HandsConnectPresenter
        let shelf = Shelf()
        /// 一般分頁、授權頁的假網頁宿主（記下每一次開的網址：量重新載入、打網址開了哪一頁）。
        let webHost: EvidenceWebHost
        /// 私訊框的形態轉換（自測自己送）。
        let transitions: CurrentValueSubject<Bool, Never>

        init(_ name: String) {
            let defaults = UserDefaults(suiteName: "w184browser.\(name).\(UUID().uuidString)") ?? .standard
            let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { true }, directKeys: true)
            let transitions = CurrentValueSubject<Bool, Never>(false)
            let webHost = EvidenceWebHost()
            self.webHost = webHost
            // 「看得到」＝視窗排在畫面上（自測的視窗透明，蓋不蓋住量不準）；形態轉換由自測送。
            let browser = DMBrowser(store: store, openBox: {}, pageHost: webHost,
                                    podPage: { EvidencePage("ChatGPT Dev・New Plugin（假頁面）") },
                                    windowShown: { $0.isVisible }, transitions: { transitions.eraseToAnyPublisher() })
            let box = CardBox()
            self.transitions = transitions
            self.store = store
            self.browser = browser
            self.box = box
            flow = DMBrowserPhoneAcceptance.inertFlow()
            presenter = HandsConnectPresenter(store: store, openBox: {}, browser: browser, hookPod: { _ in }, podURL: { nil },
                                              cancelFlow: {}, card: { box.card })
        }

        /// shown＝自測畫面證據固定展開的（側欄、頂列；平常照滑鼠）；probes＝每一格墊量尺（自測讀位置、真的按）。
        func pane(_ shown: DMBrowserChromeShown = [], panel: DMBrowserPanel? = nil, probes: Bool = false) -> some View {
            DMBrowserPane(store: store, browser: browser, flow: flow, connect: presenter, spaces: shelf.spaces, panel: panel)
                .transformEnvironment(\.dmBrowserChromeShown) { $0.formUnion(shown) }   // 外面再給的也算（不蓋掉）
                .transformEnvironment(\.dmFrameProbes) { if probes { $0 = true } }
        }

        /// 舊的寫法：pinned＝側欄固定展開（自測畫面證據）。
        func pane(pinned: Bool, panel: DMBrowserPanel? = nil) -> some View {
            pane(pinned ? .sidebar : [], panel: panel)
        }
    }

    @MainActor static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        var stack: [NSView] = [root]
        var visited = 0
        while let view = stack.popLast(), visited < 5000 {
            visited += 1
            if let match = view as? T { found.append(match) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }

    /// 量尺那一格在視窗裡的位置（原點在左下）；沒畫＝nil。
    @MainActor static func probeFrame(_ key: String, in host: NSView) -> CGRect? {
        views(DMFrameProbeView.self, in: host).first { $0.key == key }.map { $0.convert($0.bounds, to: nil) }
    }

    /// 頁面容器在這一點給不給那一頁（true＝點到網頁；false＝讓位給浮在上面的東西，或點到別的）。
    @MainActor static func pageGets(_ point: NSPoint, in host: NSView, page: NSView?) -> Bool {
        guard let container = views(DMBrowserPageContainer.self, in: host).first, let superview = container.superview else { return false }
        let hit = container.hitTest(superview.convert(point, from: nil))
        return page.map { hit === $0 || hit?.isDescendant(of: $0) == true } == true
    }

    @MainActor private static func dumpToolbarAX(_ root: NSObject) {
        var seen = Set<ObjectIdentifier>()
        func value(_ object: NSObject, _ name: String, _ legacy: String) -> Any? {
            let getter = NSSelectorFromString(name)
            if object.responds(to: getter), let result = object.perform(getter)?.takeUnretainedValue() { return result }
            let old = NSSelectorFromString("accessibilityAttributeValue:")
            return object.responds(to: old) ? object.perform(old, with: legacy)?.takeUnretainedValue() : nil
        }
        func visit(_ object: NSObject) {
            guard seen.count < 6000, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let id = value(object, "accessibilityIdentifier", "AXIdentifier") as? String ?? ""
            let label = value(object, "accessibilityLabel", "AXDescription") as? String ?? ""
            if id == "browser-navigation-bar" || id.hasPrefix("browser.omnibox") || label.contains("網址") || label.contains("chatgpt.com") {
                print("W193 AX address node class=\(type(of: object)) id=\(id) label=\(label) role=\(value(object, "accessibilityRole", "AXRole") ?? "nil")")
            }
            for child in value(object, "accessibilityChildren", "AXChildren") as? [NSObject] ?? [] { visit(child) }
        }
        visit(root)
    }

    @MainActor static func layoutChecks(_ check: Checker) {
        let phone = Phone("layout")
        _ = phone.browser.openPod(purpose: .chatgptDeveloper)
        phone.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
        let size = CGSize(width: 466, height: 610)
        guard let hidden = GlobalDMChatAcceptance.renderSync(phone.pane(probes: true), size: size) else {
            return check.skip("F 真的畫出來：這個環境畫不出來（沒有畫面環境）")
        }
        let container = views(DMBrowserPageContainer.self, in: hidden.host).first
        let frame = container.map { $0.convert($0.bounds, to: nil) } ?? .zero
        check(container != nil && near(frame.minX, 12) && near(frame.width, 442) && near(frame.maxY, 606) && near(frame.minY, 12)
              && container?.layer?.cornerRadius == 28,
              "F1 rendered (W184 G2d): the page fills the Browser — 4 below the top, 12 from the left, right and bottom, rounded 28 (no handle strip on the left any more)",
              "\(frame)")
        let page = phone.browser.activeTab.flatMap { phone.browser.page(for: $0.id) }?.view
        let hitLayers = views(BrowserChromeHitLayer.LayerView.self, in: hidden.host)
        let toolbarAbsent = probeFrame("bar.panel.tools", in: hidden.host) == nil && probeFrame("bar.panel.folded", in: hidden.host) == nil
        let leftPart = NSPoint(x: 40, y: 305), topPart = NSPoint(x: 233, y: 598)
        check(hitLayers.allSatisfy { !$0.isActive } && toolbarAbsent && pageGets(leftPart, in: hidden.host, page: page) && pageGets(topPart, in: hidden.host, page: page),
              "F2 sidebar and toolbar hidden (the pointer is on neither edge): the toolbar is not drawn, the sidebar claims nothing — clicks on the page's left part and top go to the page",
              "layers=\(hitLayers.count) active=\(hitLayers.filter(\.isActive).count) toolbarAbsent=\(toolbarAbsent)")
        hidden.close()

        guard let shown = GlobalDMChatAcceptance.renderSync(phone.pane(.all, probes: true), size: size) else { return }
        let side = probeFrame("side.panel", in: shown.host) ?? .zero
        let bar = probeFrame("bar.panel.tools", in: shown.host) ?? .zero
        let sideLayer = views(BrowserChromeHitLayer.LayerView.self, in: shown.host).contains { $0.isActive && abs($0.frame.width - 250) < 1 }
        check(near(side.minX, 0) && near(side.width, 250) && near(side.maxY, 610) && near(side.minY, 0) && sideLayer,
              "F3 (W184 G2d: 「左列欄修到頂天」) the sidebar out is the Browser space glass sidebar, flush left, 250 wide, from the very top of the Browser area to its bottom (not a floating rounded card)",
              "\(side)")
        check(near(bar.minX, 0) && near(bar.width, 466) && near(bar.maxY, 610) && near(bar.height, 48),
              "F3b the toolbar out is the Browser space row, 48 high across the whole Browser area at its top (drawn over the sidebar, so a pinned sidebar never squeezes it)",
              "\(bar)")
        check(!pageGets(NSPoint(x: 125, y: 305), in: shown.host, page: page) && !pageGets(NSPoint(x: 350, y: 590), in: shown.host, page: page)
              && pageGets(NSPoint(x: 380, y: 305), in: shown.host, page: page),
              "F4 over the page the sidebar and the toolbar get their own clicks (the page container yields there) while the rest of the page still gets clicks")
        check(views(DMBrowserPageContainer.self, in: shown.host).first?.accessibilityIdentifier() == "tatwo.dm.browser.page",
              "F5a the page container keeps tatwo.dm.browser.page")
        let ids = GlobalDMChatAcceptance.identifiers(in: shown)
        print("W193 AX DM Browser identifiers: \(ids.sorted())")
        print("W193 AX DM Browser address shown=\(DMBrowserToolbar.showsAddress(phone.browser.activeTab)) label=\(DMBrowserToolbar.label(phone.browser.activeTab) ?? "domain")")
        dumpToolbarAX(shown.window)
        let wanted = ["tatwo.dm.browser", "tatwo.dm.browser.sidebar", "tatwo.dm.browser.toolbar", "tatwo.dm.browser.shield", "tatwo.dm.browser.newTab",
                      "tatwo.dm.browser.spaces", "browser.sidebarToggle", "browser-navigation-bar", "browser.omnibox", "browser.favorites.strip",
                      "browser.translate"]
        if !ids.contains("tatwo.dm.browser") {
            check.skip("F5 identifiers: this environment built no SwiftUI accessibility tree (ssh headless); the node test checks them in the source")
        } else {
            let missing = wanted.filter { !ids.contains($0) }
            check(missing.isEmpty, "F5 identifiers: the DM Browser, its sidebar and toolbar, the Browser space components inside (sidebar toggle, navigation bar, address, favorites, translate), new tab, spaces and the 「這一頁不給截圖」 badge", "missing=\(missing)")
        }
        shown.close()

        // 浮卡：離底 30、左右 12（442 寬）——側欄藏著、滑出都一樣（卡片不動、不變窄）；側欄停在卡片上面 8，卡片的按鈕不會被蓋；
        // 卡片那一塊的點擊給卡片。
        phone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）"), key: 61, purpose: .chatgptPairing, expectedHost: HandsConnectAcceptance.publicHost)
        phone.box.card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(272), attemptsLeft: 5,
                                                          callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true, surface: 61))
        phone.presenter.show()
        // 每一次新的 Browser 畫面放好配對頁，Browser 都要（下一輪）發布一次，卡片才會重算把碼畫出來（值跟上一次一樣也要）。
        var publishes = 0
        let watch = phone.browser.$shownSurface.dropFirst().sink { value in if value == 61 { publishes += 1 } }
        /// 這一張的量法：卡片的位置、側欄停在卡片上面 8、卡片中間的點擊給卡片。
        func cardPlaced(_ rendered: GlobalDMChatAcceptance.Rendered, width: CGFloat) -> (Bool, String) {
            let card = probeFrame("card.frame", in: rendered.host) ?? .zero
            let column = probeFrame("side.panel", in: rendered.host) ?? .zero
            let cardYields = views(DMBrowserPageContainer.self, in: rendered.host).first.map { c in
                c.superview.map { c.hitTest($0.convert(NSPoint(x: card.midX, y: card.midY), from: nil)) == nil } ?? false } == true
            let clear = column.minY >= card.maxY + DMBrowserPhone.sidebarGap - 1 && !column.intersects(card)
            let placed = !card.isEmpty && near(card.minY, 30) && near(card.minX, 12) && near(card.width, width - 24)
            return (placed && cardYields && clear, "card=\(card) column=\(column) yields=\(cardYields)")
        }
        for out in [false, true] {
            let before = publishes
            guard let rendered = GlobalDMChatAcceptance.renderSync(phone.pane(out ? .sidebar : [], probes: true), size: size) else { continue }
            check(publishes > before, "F7a a fresh Browser pane (\(out ? "second" : "first") render) gets its pairing page published once after it is placed, so the card redraws with the code",
                  "publishes=\(publishes) before=\(before)")
            let (ok, evidence) = cardPlaced(rendered, width: size.width)
            check(ok, "F6 (W184 G2d) the pairing card floats on the page (the page is not squeezed): 30 above the bottom, 12 from both sides, 442 wide with the sidebar \(out ? "out — the sidebar stops 8 above the card, so its buttons are never covered" : "hidden"); its clicks go to the card", evidence)
            if out {
                // Browser 把「現在畫面上的 Pod 頁」在下一輪 run loop 發布（不在畫面更新當下）：卡片據此把碼畫出來，不用等流程下一次核對。
                check(phone.browser.shownSurface == 61 && phone.presenter.revealsCode(phone.box.card ?? .loading("")) && phone.presenter.codeOnScreen == false,
                      "F7 once the pairing page is placed the Browser publishes it (next run loop) and the card may show the code; the card only holds the window after the flow hands over the code (codeVisible)",
                      "surface=\(String(describing: phone.browser.shownSurface))")
                let ids = GlobalDMChatAcceptance.identifiers(in: rendered)
                if ids.contains("tatwo.dm.browser") {
                    let missing = ["tatwo.dm.handsConnect.float", "tatwo.dm.handsConnect.cancel", "tatwo.dm.handsConnect.code"].filter { !ids.contains($0) }
                    check(missing.isEmpty, "F8 pairing card identifiers (float, cancel, code) kept", "missing=\(missing)")
                } else {
                    check.skip("F8 pairing card identifiers: no SwiftUI accessibility tree here (ssh headless); the node test checks them in the source")
                }
            }
            rendered.close()
        }
        watch.cancel()
        // F6b（W184 G2c 第二輪，GPT-6 #4）：最小的兩種框（外直 ×0.7、內橫右欄 ×0.7）同一張配對卡：照樣離底 30、左右 12（寬＝Browser 區 − 24）、
        //      卡片那一塊的點擊給卡片；側欄（藏著、滑出）停在卡片上面 8、跟卡片不相交。
        var small: [String] = []
        for box in smallBoxes {
            for out in [false, true] {
                guard let rendered = GlobalDMChatAcceptance.renderSync(phone.pane(out ? .sidebar : [], probes: true), size: box.size) else { continue }
                let (ok, _) = cardPlaced(rendered, width: box.size.width)
                small.append("\(box.name)/\(out ? "out" : "hidden")=\(ok)")
                rendered.close()
            }
        }
        if small.isEmpty {
            check.skip("F6b 最小的框：這個環境畫不出來")
        } else {
            check(small.count == 4 && small.allSatisfy { $0.hasSuffix("=true") },
                  "F6b (W184 G2c second round, GPT-6 #4) in the smallest boxes (outer portrait ×0.7, inner-landscape right column ×0.7) the pairing card still floats 30 above the bottom and 12 from both sides, its clicks go to the card, and the sidebar stops 8 above it without touching it",
                  small.joined(separator: " "))
        }
        phone.presenter.hide()
        phone.browser.closeAll()
    }

    // MARK: - I 碼還畫著的每一幀都不給擷取（GPT-6 審查 #1、#6）

    /// 這個視窗裡還畫著（沒藏起來）的配對碼。
    @MainActor static func codeDrawn(in window: NSWindow) -> Bool {
        DMSecretCodeView.liveViews.contains { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// 動作之後一格一格跑 run loop（約 8ms 一格）：每一格「碼還畫著 ⇒ 視窗不給擷取」；回傳（全部守住、碼有沒有收掉、最後視窗還原了沒）。
    @MainActor static func sample(_ windows: [NSWindow], frames: Int = 110, _ trigger: () -> Void) -> (held: Bool, gone: Bool, restored: Bool) {
        var held = true
        trigger()
        for window in windows where codeDrawn(in: window) && !WindowCaptureShield.shared.isShielding(window) { held = false }
        for _ in 0..<frames {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            for window in windows where codeDrawn(in: window) && !WindowCaptureShield.shared.isShielding(window) { held = false }
        }
        let gone = windows.allSatisfy { !codeDrawn(in: $0) }
        let restored = windows.allSatisfy { !WindowCaptureShield.shared.isShielding($0) }
        return (held, gone, restored)
    }

    @MainActor static func exitFrameChecks(_ check: Checker) {
        let size = CGSize(width: 466, height: 610)
        let card = HandsConnectCard.pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(272), attemptsLeft: 5,
                                                                    callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true, surface: 91))
        /// 一支手機：配對頁在前面、流程給了碼、卡片浮在頁上（畫出來、等碼真的畫上去）。
        func phoneWithCode(_ name: String) -> (Phone, GlobalDMChatAcceptance.Rendered)? {
            let phone = Phone(name)
            phone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）"), key: 91, purpose: .chatgptPairing, expectedHost: nil)
            phone.box.card = card
            phone.presenter.show()
            phone.presenter.setCodeVisible(true)
            guard let rendered = GlobalDMChatAcceptance.renderSync(phone.pane(pinned: false), size: size) else { return nil }
            for _ in 0..<40 where !codeDrawn(in: rendered.window) { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return (phone, rendered)
        }
        guard case let (listPhone, listShot)? = phoneWithCode("exit-list") else { return check.skip("I 碼退場的每一幀：這個環境畫不出來") }
        let drawnAtStart = codeDrawn(in: listShot.window) && WindowCaptureShield.shared.isShielding(listShot.window)
        check(drawnAtStart, "I0 the pairing code is drawn on the page (its own view) and that window is shielded")
        // 1. 分頁總覽：Browser、卡片的邏輯持有馬上放手，碼那一格照樣擋到它真的不見、再多擋 linger。
        let list = sample([listShot.window]) { listPhone.browser.isShowingTabList = true }
        check(list.held && list.gone && list.restored,
              "I1 counterexample (GPT-6 #1): opening the tab overview — every frame that still draws the code keeps the window uncapturable; the code goes away without an exit animation and the window is restored after",
              "held=\(list.held) gone=\(list.gone) restored=\(list.restored)")
        listPhone.presenter.hide()
        listShot.close()
        // 2. 取消（卡片收起來、連線分頁收掉）。
        if case let (cancelPhone, cancelShot)? = phoneWithCode("exit-cancel") {
            let cancel = sample([cancelShot.window]) {
                cancelPhone.box.card = nil
                cancelPhone.presenter.hide()
            }
            check(cancel.held && cancel.gone && cancel.restored,
                  "I2 counterexample: cancelling with the code up — every frame that still draws it is shielded; restored after it is gone",
                  "held=\(cancel.held) gone=\(cancel.gone) restored=\(cancel.restored)")
            cancelShot.close()
        }
        // 3. 收框（真的把畫面拆掉，不是直接叫 release）。
        if case let (closePhone, closeShot)? = phoneWithCode("exit-close") {
            let window = closeShot.window
            let close = sample([window]) { window.contentView = nil }
            check(close.held && close.gone && close.restored,
                  "I3 counterexample: collapsing the box for real (the view torn down) — the window stays uncapturable until the code is gone plus the last frame",
                  "held=\(close.held) gone=\(close.gone) restored=\(close.restored)")
            closePhone.presenter.hide()
            closeShot.close()
        }
        // 4. 停靠框↔浮動框換手：新視窗接過頁面，舊視窗的碼收掉；兩個視窗每一格都守住。
        if case let (handPhone, first)? = phoneWithCode("exit-handoff") {
            var second: GlobalDMChatAcceptance.Rendered?
            let hand = sample([first.window]) {
                second = GlobalDMChatAcceptance.renderSync(handPhone.pane(pinned: false), size: size)
            }
            let moved = second.map { codeDrawn(in: $0.window) && WindowCaptureShield.shared.isShielding($0.window) } ?? false
            check(hand.held && hand.gone && hand.restored && moved,
                  "I4 counterexample: handing the Browser to another window — the old window stays shielded while it still draws the code and is restored after; the new window draws the code and is shielded",
                  "held=\(hand.held) gone=\(hand.gone) restored=\(hand.restored) moved=\(moved)")
            // 5. 形態轉換：一開始就同步藏起來（同一格裡），轉換期間畫面怎麼重算都不顯示；結束、頁面恢復才又畫。
            if let second {
                handPhone.transitions.send(true)
                let hiddenAtOnce = !codeDrawn(in: second.window)
                for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                let stillHidden = !codeDrawn(in: second.window) && !handPhone.presenter.codeOnScreen
                handPhone.transitions.send(false)
                for _ in 0..<60 where !codeDrawn(in: second.window) { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                let backAfter = codeDrawn(in: second.window) && WindowCaptureShield.shared.isShielding(second.window)
                check(hiddenAtOnce && stillHidden && backAfter,
                      "I5 counterexample (GPT-6 #2): a form transition starts → the code is hidden in the same frame and stays hidden through the transition; after it ends (pages restored) it is drawn again, shielded",
                      "atOnce=\(hiddenAtOnce) during=\(stillHidden) back=\(backAfter)")
                second.close()
            }
            handPhone.presenter.hide()
            first.close()
        }
        DMSecretCodeView.suppress(false)
        DMBrowserAcceptance.settleShield()
    }

    // MARK: - G 畫面證據（PNG）

    @MainActor static func save(_ rendered: GlobalDMChatAcceptance.Rendered, _ name: String, to folder: URL) -> Bool {
        guard let png = rendered.bitmap.representation(using: .png, properties: [:]) else { return false }
        let url = folder.appendingPathComponent(name)
        do { try png.write(to: url) } catch { return false }
        print("W184BROWSER NOTE evidence \(url.path)")
        return true
    }

    /// 一支手機（外直 466×678）：頂列＋內容，外面留陰影邊。
    /// 同 GlobalDMPhoneBox.phone 的擺法（W184 G3c／G2d）：頂列在上、欄畫在頂列底下一層（zIndex −1），欄拿到頂列的高度——
    /// 訊息列表（globalDMListBleed）與 Browser 側欄（dmBrowserTopExtension）往上伸到框頂，頁面圓鈕照舊在最上面。
    /// GlobalDMPhoneBox 要一整個 ChatPageModel，自測與畫面證據用這個一欄的版本（node w184-rail 守兩邊同一個擺法）。
    struct PhoneColumns<Content: View>: View {
        let store: GlobalDMStore
        let form: GlobalDMForm
        @ViewBuilder let content: () -> Content

        var body: some View {
            VStack(spacing: 0) {
                GlobalDMTopBar(store: store, form: form)
                content()
                    .zIndex(-1)
                    .environment(\.globalDMListBleed, DMPhone.headerHeight)
                    .environment(\.dmBrowserTopExtension, DMPhone.headerHeight)
            }
            .environment(\.globalDMForm, form)   // 同 GlobalDMPhoneBox（整支手機拿到形態：側欄的空間名稱照它擺）
        }
    }

    /// 一支外直的手機：頂列＋Browser（同 GlobalDMPhoneBox：欄在頂列底下一層、側欄頂天）。
    @MainActor static func phoneShot(_ store: GlobalDMStore, _ content: some View) -> some View {
        PhoneColumns(store: store, form: .outerPortrait) { content }
        .frame(width: GlobalDMForm.outerPortrait.size.width, height: GlobalDMForm.outerPortrait.size.height)
        .modifier(GlobalDMBoxChrome())
        .padding(GlobalDMLayout.margin)
    }

    @MainActor static func evidence(_ check: Checker) async {
        guard let folder = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"], !folder.isEmpty else {
            return check.skip("G 畫面證據：沒有 TATWO2_SELFTEST_ARTIFACTS（不是 lead-verify 跑的）")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let size = CGSize(width: GlobalDMForm.outerPortrait.size.width + GlobalDMLayout.margin * 2,
                          height: GlobalDMForm.outerPortrait.size.height + GlobalDMLayout.margin * 2)
        var written: [String] = []
        func shoot(_ name: String, _ view: some View) {
            guard let rendered = GlobalDMChatAcceptance.renderSync(view, size: size) else { return }
            if save(rendered, name, to: out) { written.append(name) }
            rendered.close()
        }

        let phone = Phone("evidence")
        phone.store.showBrowser()
        _ = phone.browser.openPod(purpose: .chatgptDeveloper)
        phone.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
        // 輪到你勾選（W183 R10：只剩退路——TATWO 沒勾到那一格）：浮在 ChatGPT Dev 分頁的頁上（側欄、頂列藏著：頁面佔滿）。
        phone.box.card = .waitingUser(HandsConnectFlow.tickMissedCardText, continuable: true)
        phone.presenter.show()
        shoot("browser-ack-card.png", phoneShot(phone.store, phone.pane()))

        // 配對碼（假碼）：浮在配對頁上。
        phone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）：輸入私訊框上的 8 碼"), key: 71, purpose: .chatgptPairing,
                                 expectedHost: HandsConnectAcceptance.publicHost)
        phone.browser.podFrame(HandsPodFrame(url: URL(string: "https://\(HandsConnectAcceptance.publicHost)/authorize?client_id=fixture"), generation: 2,
                                             loading: false, httpStatus: 200, popup: true, popupKey: 71))
        phone.box.card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(272), attemptsLeft: 5,
                                                          callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true, surface: 71))
        phone.presenter.setCodeVisible(true)
        shoot("browser-code-card.png", phoneShot(phone.store, phone.pane()))
        phone.presenter.setCodeVisible(false)
        phone.box.card = nil

        // 分頁總覽：三個分頁（進行中兩個、完成一個）。
        let login = DMBrowserAcceptance.loginURL("W184EVIDENCE")
        phone.browser.open(url: login, purpose: .cloudflareLogin)
        phone.browser.loginPage(login, .done)
        if let pod = phone.browser.tabs.first(where: { $0.kind == .pod }) { phone.browser.select(pod.id) }
        phone.browser.isShowingTabList = true
        shoot("browser-tabs.png", phoneShot(phone.store, phone.pane()))
        phone.browser.isShowingTabList = false
        phone.presenter.hide()
        phone.browser.closeAll()

        // ［連線］確認＝底部 sheet（蓋在對話上）。W183 R10：沒有專案那一層；範圍只顯示（中央設定的等級＋這台全部專案）、
        //［連線］旁一行小字（按連線＝同意）；第二張：有交易類專案（只能看）的那一台。
        let projects = [HandsProjectRef(id: UUID().uuidString, name: "Primary One 專案"), HandsProjectRef(id: UUID().uuidString, name: "示範專案")]
        let trading = HandsProjectRef(id: UUID().uuidString, name: "BTC 實盤")
        let offers = [("connect-sheet.png", [HandsProjectRef]()), ("connect-sheet-trading.png", [trading])].map { name, extra -> (String, HandsConnectOffer) in
            (name, HandsConnectOffer(hostDeviceID: HandsConnectAcceptance.hostID, hostName: "Primary One", publicHost: HandsConnectAcceptance.publicHost,
                                     scope: HandsGrantScope(level: 1, projects: projects + extra, memory: HandsGrantScope.memoryText(level: 1),
                                                            allProjects: true, readOnlyProjectIDs: extra.map(\.id)),
                                     callbackHosts: ["chatgpt.com"], setupEpoch: "epoch-1"))
        }
        phone.store.select(.chatGPT)
        for (name, offer) in offers {
            let context = HandsConnectCardContext(phase: .waitingTap, offer: offer)
            // 同 HandsConnectDMLayer：遮罩蓋住整支手機（含頂列），sheet 從下滑出到離頂 96。
            let sheet = ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    GlobalDMTopBar(store: phone.store, form: .outerPortrait)
                    Spacer(minLength: 0)
                }
                Color.black.opacity(GlobalDMWebSheetLayout.dimOpacity)
                HandsConnectSheetView(card: .confirm(offer, account: "Primary One"), context: context, actions: HandsConnectCardActions())
                    .padding(.top, GlobalDMWebSheetLayout.topInset)
            }
            .frame(width: GlobalDMForm.outerPortrait.size.width, height: GlobalDMForm.outerPortrait.size.height)
            .modifier(GlobalDMBoxChrome())
            .padding(GlobalDMLayout.margin)
            shoot(name, sheet)
        }
        // W184 G2d：私訊框的頂列、側欄（頂天）、沒分頁的搜尋框、內橫右欄、連線卡片＋側欄——每一張跟主視窗 Browser space 的同一元件並排
        // （DMBrowserChromeAcceptance.swift）；小框＋手動連線卡、十一個空間。
        written += await g2dEvidence(out: out)
        let expected = ["browser-ack-card.png", "browser-code-card.png", "browser-tabs.png", "connect-sheet.png", "connect-sheet-trading.png",
                        "g2d-toolbar.png", "g2d-sidebar.png", "g2d-sidebar-top.png", "g2d-search.png", "g2d-duo.png", "g2d-card-sidebar.png",
                        "g2d-small-manual.png", "g2d-spaces.png"]
        if written.isEmpty {
            check.skip("G 畫面證據：這個環境畫不出來（沒有畫面環境）")
        } else {
            check(written == expected, "G evidence PNGs (W184 G2d): tick-missed fallback card, pairing card (fake code), tab overview, ［連線］ sheet (read-only scope + consent line) and one with a view-only trading project; G2d side by side with the main window's Browser space component: toolbar, sidebar out (full height; once more with the round buttons open over it), no-tab search box, inner-landscape right column, connect card with the sidebar; the smallest box with the manual-steps card and eleven spaces",
                  "\(written)")
        }
    }
}
#endif
