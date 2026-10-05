#if DEBUG
import AppKit
import Combine
import SwiftUI

/// W184 G2d（使用者 09-30 02:4x 實測 .031：「duo的browser左列欄修到頂天 上方這些功能跟我們設計的 browser space設計不同」
/// 「應該是滑鼠指到展開玻璃」「還沒有分頁的搜尋狀態也要一樣」「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：
/// `TATWO2_SELFTEST=w184browser` 的 G2d 段——
/// - S1–S3 側欄＝主視窗 Browser space 的側欄那一份（BrowserWorkSpaceSidebarList 借用模式：順序、標頭同主視窗、📌 Pinned、空間名稱在頂列那一排
///   頁面圓鈕右邊、頂天、貼左緣、Browser space 的列高）、停在連線卡片上面；S2d 緊湊側欄捲動之後頂列浮出來也蓋不到列（GPT-6 審查 G2d #3）；
///   S8 來源刪掉的分頁回到分頁清單（GPT-6 審查 G2d #2）。
/// - T1–T5 頂列＝主視窗那一排（純計算、畫出來的順序、真的滑鼠按側欄鈕／上一頁／下一頁／重新載入／網址、翻譯擴充註解按不下去、窄的時候收進 ⋯、
///   滑鼠指到上緣才出）；T3 重新載入＝原生重新載入（同一個瀏覽器、上一頁回得去；GPT-6 審查 G2d #1）。
/// - Q1–Q4 沒分頁、空白分頁＝主視窗那個置中的搜尋框（真的點進去打字、Return 開在那一個空白分頁上）；Q5 右鍵＝同一個搜尋引擎選單。
/// - M1–M4 主視窗 Browser space 的元件行為沒被改到（同一顆側欄鈕、同一排珍藏、同一條書籤、同一顆空間圓點照舊動主視窗的 store），
///   私訊框那一支只走自己的開法、不碰主視窗的分頁；M4 私訊框的圓點走它自己的選擇回呼（GPT-6 審查 G2d #4）。
/// - 畫面證據：私訊框的頂列、側欄（頂天）、沒分頁的搜尋框、內橫右欄、連線卡片＋側欄，每一張跟主視窗的同一元件並排。
/// 隔離：Browser、Browser space 的分頁清單與 store 都是自測自己建的、只在記憶體；頁面是假的（這個建置沒有 Chromium）。
extension DMBrowserPhoneAcceptance {
    // MARK: - S 側欄（主視窗 Browser space 的側欄）

    @MainActor static func sidebarChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        let phone = Phone("sidebar")
        let pinnedID = phone.shelf.addPinned(URL(string: "https://example.org/pinned")!, title: "釘選的頁")
        _ = phone.browser.openPod(purpose: .chatgptDeveloper)
        let typed = openedID(phone.browser.openBrowse(url: URL(string: "https://example.com/typed")!, title: "打的網址", origin: .typed))
        let marked = phone.shelf.projected(phone.shelf.docs.id).flatMap { openedID(DMBrowserShelf.open(bookmark: $0, in: phone.browser)) }
        _ = await DMBrowserAcceptance.waitUntil(3) { phone.webHost.opened.count >= 2 }
        guard let folder = phone.shelf.store.folders.first, let pod = phone.browser.tabs.first(where: { $0.kind == .pod }), let typed,
              phone.shelf.pinnedTab(pinnedID) != nil else {
            return check(false, "S1 fixture: a bookmark folder, a pinned main-window tab, the Pod tab and a typed tab")
        }
        // S1（主導 09-30：「列的內容、順序、標頭、空間名稱擺的位置都要跟主視窗一樣」；GPT-6 審查 G2d #5）：用 GlobalDMPhoneBox 的擺法量
        // （頂列在上、側欄頂天）。順序＝BrowserWorkSpaceSidebarList：珍藏那一排 → 📌 Pinned（標頭＋主視窗釘選的那一列）→ 書籤資料夾 →
        // 新分頁 → 分頁 → 最下面一排（下載、空間圓點、＋）；空間名稱在頂列那一排。書籤開的分頁住在書籤那一列（不列在分頁裡）。
        let portrait = GlobalDMForm.outerPortrait.size
        let lined = Clickable(PhoneColumns(store: phone.store, form: .outerPortrait) { phone.pane(.sidebar, probes: true) }, size: portrait)
        await lined.settle()
        let order = ["side.title", "side.favorites", "side.pinned", "side.pin.\(pinnedID.uuidString)", "side.folder.\(folder.id.uuidString)",
                     "side.newTab", "side.tab.\(pod.id.uuidString)", "side.tab.\(typed.uuidString)", "side.spaces"]
        let tops = order.compactMap { key in lined.frame(key).map { portrait.height - $0.maxY } }
        let ascending: Bool = tops.count == order.count && zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 }
        let bookmarkOnItsRow: Bool = marked.map { lined.frame("side.tab.\($0.uuidString)") == nil } == true
        let bottomRow: Bool = ["side.downloads", "side.space.add"].allSatisfy { lined.frame($0) != nil }
        check(ascending && bookmarkOnItsRow && bottomRow,
              "S1 (W184 G2d; lead 09-30 + GPT-6 G2d #5) the DM sidebar IS the main window's BrowserWorkSpaceSidebarList, same order and headers: favorites strip, 📌 Pinned header with the main window's pinned tab under it, bookmark folders, 新分頁, tabs, then downloads + space dots + ＋ at the bottom; the space name sits in the top row; a tab opened from a bookmark lives on its bookmark row, not in the tab list (same as the main window)",
              "tops=\(tops.map { Int($0) }) bookmarkOnItsRow=\(bookmarkOnItsRow) bottomRow=\(bottomRow)")
        // S1b（主導 09-30：「請查實際的主視窗 Browser space 是怎麼擺的」）：主視窗的空間名稱在視窗頂列、紅綠燈右邊（紅綠燈最右邊再過 10＋8）、
        // 跟紅綠燈同一條中心線（光學修正 1）；私訊框＝頁面圓鈕右邊、跟圓鈕同一條中心線、同樣的間距。列從頂列（Browser 區頂端 48）下面開始。
        let titleFrame = lined.frame("side.title") ?? .zero
        let roundButtons = GlobalDMTopBarLayout.stripFrame(open: false, count: phone.store.pageItems(besideBrowser: false).count, form: .outerPortrait)
        let buttonRight = roundButtons.minX + DMPhone.Strip.inset + DMPhone.touch
        let titleLeft: CGFloat = buttonRight + WindowChromeMetrics.headerHorizontalInset + WindowChromeMetrics.controlSpacing
        let centreGap: CGFloat = abs((portrait.height - titleFrame.midY) - (roundButtons.midY - DMBrowserPhone.sidebarTitleLift))
        let besideButton: Bool = near(titleFrame.minX, titleLeft) && centreGap <= 1 && near(titleFrame.height, WorkspaceSidebarMetrics.spaceSwitcherHeight)
        let rowsBelowBar: Bool = lined.frame("side.favorites").map { portrait.height - $0.maxY >= DMPhone.headerHeight + DMBrowserPhone.toolbarHeight - 0.5 } == true
        check(besideButton && rowsBelowBar,
              "S1b (W184 G2d; lead 09-30: where the main window really puts the space name) the space name is in the top row right of the page round button — the main window puts it right of the traffic lights, 10 + 8 past them, on their centre line (optical lift 1) — same gap and centre line here; the rows start below the 48pt toolbar band",
              "title=\(titleFrame) buttonRight=\(buttonRight) buttonsMidY=\(roundButtons.midY) rowsBelowBar=\(rowsBelowBar)")
        lined.close()
        let screen = Clickable(phone.pane(.sidebar, probes: true), size: size)
        await screen.settle()
        let panel = screen.frame("side.panel") ?? .zero
        let full: Bool = near(panel.minX, 0) && near(panel.width, 250) && near(panel.maxY, size.height) && near(panel.minY, 0)
        let rows = [pod.id, typed].compactMap { screen.frame("side.tab.\($0.uuidString)") }
        let rowHeights: Bool = rows.count == 2 && rows.allSatisfy { $0.height >= BrowserSidebarMetrics.workspaceRowMinHeight - 0.5 }
        let strip = screen.frame("side.favorites")
        let stripHeight: Bool = strip.map { near($0.height, BrowserFavoritesStrip.tileHeight + BrowserSidebarMetrics.rowHorizontalPadding) } == true
        let dots = phone.shelf.store.spaces.compactMap { space in screen.frame("side.space." + (space.registryID?.uuidString ?? String(space.id))) }
        let dotCells: Bool = dots.count == phone.shelf.store.spaces.count
            && dots.allSatisfy { near($0.width, WorkspaceSpaceControlMetrics.cellWidth) && near($0.height, WorkspaceSpaceControlMetrics.cellHeight) }
        let parts: [CGRect] = [strip].compactMap { $0 } + rows + dots
        let inside: Bool = parts.allSatisfy { panel.insetBy(dx: -1, dy: -1).contains($0) }
        check(full && rowHeights && stripHeight && dotCells && inside,
              "S2 (W184 G2d: 「左列欄修到頂天」) the sidebar is the main window's glass sidebar: flush left, 250 wide, from the top of the Browser area to its bottom; rows at the Browser space sizes (tab rows ≥ 34, favorites strip 30 + 8, space cells 14×28), everything inside the glass",
              "panel=\(panel) strip=\(String(describing: strip)) rows=\(rows.map { Int($0.height) }) dots=\(dots.count)")
        screen.close()

        // S2b（W184 G2d 第二輪：自己的並排 PNG 看到頂列蓋在珍藏那一排上）：滑鼠在左上角＝側欄、頂列同時在。頂列只蓋側欄最上面空著的那一段
        // （捲動區外面，side.top）；珍藏、資料夾、新分頁、分頁與 × 都在頂列下面（按得到，不會按到頂列的上一頁／下一頁）。
        // 平常擺法與緊湊擺法（小框＋最高的卡）都量。
        var under: [String] = []
        let both = Clickable(phone.pane(.all, probes: true), size: size)
        await both.settle()
        let barFrame = both.frame("bar.panel.tools") ?? .zero
        let bothKeys = ["side.favorites", "side.folder.\(folder.id.uuidString)", "side.newTab", "side.tab.\(pod.id.uuidString)",
                        "side.close.\(pod.id.uuidString)", "side.tab.\(typed.uuidString)"]
        let bothFrames = bothKeys.compactMap { both.frame($0) }
        if barFrame.isEmpty || bothFrames.count != bothKeys.count { under.append("normal:missing") }
        for (key, frame) in zip(bothKeys, bothFrames) where frame.maxY > barFrame.minY + 0.5 { under.append("normal:" + key) }
        let bandUnderBar: Bool = both.frame("side.top").map { $0.minY <= barFrame.minY + 0.5 } == true
        both.close()
        phone.browser.closeAll()
        let compactPhone = Phone("sidebar-both-compact")
        compactPhone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）"), key: 96, purpose: .chatgptPairing, expectedHost: nil)
        if let tall = tallCards(surface: 96).first(where: { $0.name == "pairing" }) { compactPhone.box.card = tall.card }
        compactPhone.presenter.show()
        let tight = Clickable(compactPhone.pane(.all, probes: true), size: smallBoxes.last?.size ?? size)
        await tight.settle()
        let tightBar = tight.frame("bar.panel.tools") ?? tight.frame("bar.panel.folded") ?? .zero   // 窄＝工具收進 ⋯（T2b）
        let compactMode = tight.frame("side.mode.compact") != nil
        let tightStrip = tight.frame("side.favorites")
        if !compactMode { under.append("compact:notCompact") }
        if tightBar.isEmpty || tightStrip == nil { under.append("compact:missing") }
        if let tightStrip, tightStrip.maxY > tightBar.minY + 0.5 { under.append("compact:side.favorites") }
        tight.close()
        compactPhone.presenter.hide()
        compactPhone.browser.closeAll()
        check(under.isEmpty && bandUnderBar,
              "S2b (W184 G2d second pass) with the sidebar and the toolbar both out (pointer at the top-left), the toolbar covers only the sidebar's empty top band (outside the scroll area) — the favorites strip, folders, 新分頁, tabs and × are all below the toolbar in the normal sidebar and in the compact one (small box + tallest card)",
              "under=\(under) band=\(bandUnderBar) bar=\(barFrame)")

        // S2c（W184 G2d 第三輪，主導 09-30：「duo的browser左列欄修到頂天」——側欄要從框頂開始，不是從頁面圓鈕底下）：用 GlobalDMPhoneBox
        // 同一個擺法（PhoneColumns：欄畫在頂列底下一層）量。外直、內橫右欄的側欄都從框頂到底；頁面圓鈕列在側欄上面、真的按得到
        // （圓鈕列展開，按 TATWO＝離開 Browser）；空間名稱在頂列那一排、圓鈕右邊（主導 09-30：擺法同主視窗「紅綠燈右邊」；內橫右欄的左上沒有圓鈕：
        // 對齊側欄的列、同一條中心線）；珍藏、新分頁、分頁在圓鈕與頂列下面。
        let topPhone = Phone("sidebar-top")
        topPhone.store.showBrowser()
        _ = topPhone.browser.openPod(purpose: .chatgptDeveloper)
        let topTyped = openedID(topPhone.browser.openBrowse(url: URL(string: "https://example.com/top")!, title: "打的網址", origin: .typed))
        let topScreen = Clickable(PhoneColumns(store: topPhone.store, form: .outerPortrait) { topPhone.pane(.sidebar, probes: true) }
                                    .environment(\.globalDMStripPinnedOpen, true),
                                  size: portrait)
        await topScreen.settle()
        let topColumn = topScreen.frame("side.panel") ?? .zero
        let fullHeight: Bool = near(topColumn.maxY, portrait.height) && near(topColumn.minY, 0) && near(topColumn.minX, 0)
        let roundStrip = GlobalDMTopBarLayout.stripFrame(open: true, count: topPhone.store.pageItems(besideBrowser: false).count, form: .outerPortrait)
        /// 框的座標（左上原點）：這一格的上緣離框頂多遠。
        func topOf(_ key: String) -> CGFloat? { topScreen.frame(key).map { portrait.height - $0.maxY } }
        let collapsedButtons = GlobalDMTopBarLayout.stripFrame(open: false, count: topPhone.store.pageItems(besideBrowser: false).count, form: .outerPortrait)
        let besideX: CGFloat = collapsedButtons.minX + DMPhone.Strip.inset + DMPhone.touch + WindowChromeMetrics.headerHorizontalInset
            + WindowChromeMetrics.controlSpacing
        let topTitle: CGRect = topScreen.frame("side.title") ?? .zero
        let topTitleCentre: CGFloat = portrait.height - topTitle.midY
        let titleBeside: Bool = !topTitle.isEmpty && near(topTitle.minX, besideX) && abs(topTitleCentre - DMBrowserPhone.sidebarTitleCenter) <= 1
        let barBottom = DMPhone.headerHeight + DMBrowserPhone.toolbarHeight
        var rowKeys = ["side.favorites", "side.newTab"]
        if let pod = topPhone.browser.tabs.first(where: { $0.kind == .pod }) { rowKeys.append("side.tab.\(pod.id.uuidString)") }
        if let topTyped { rowKeys.append("side.tab.\(topTyped.uuidString)") }
        let rowsUnder: [String] = rowKeys.filter { key in topOf(key).map { $0 < barBottom - 0.5 } ?? true }
        // 圓鈕列第二顆（展開後目前那顆 Browser 在最左，第二顆是 TATWO）的正中間：落在側欄上面那一層＝切到 TATWO、離開 Browser。
        let second = NSPoint(x: roundStrip.minX + DMPhone.Strip.inset + DMPhone.touch * 1.5 + DMPhone.Strip.spacing,
                             y: portrait.height - roundStrip.midY)
        let browsingBefore = topPhone.store.isBrowsing
        await topScreen.click(second)
        let pressed: Bool = browsingBefore && !topPhone.store.isBrowsing
        topScreen.close()
        topPhone.browser.closeAll()
        let duoPhone = Phone("sidebar-top-duo")
        duoPhone.store.showBrowser()
        _ = duoPhone.browser.openPod(purpose: .chatgptDeveloper)
        let land = GlobalDMForm.innerLandscape.size
        let leading = (land.width * DMPhone.duoLeadingFraction).rounded()
        let duoScreen = Clickable(PhoneColumns(store: duoPhone.store, form: .innerLandscape) {
            // 同 GlobalDMPhoneBox.columns 的右欄：寬＝內橫右欄、貼右緣；裁切往上多留頂列那一段（W184 G3c 的做法，側欄才伸得到框頂）。
            duoPhone.pane(.sidebar, probes: true)
                .frame(width: land.width - leading - DMPhone.hairline)
                .frame(width: land.width - leading, alignment: .trailing)
                .padding(.top, DMPhone.headerHeight)
                .clipped()
                .padding(.top, -DMPhone.headerHeight)
                .padding(.leading, leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }, size: land)
        await duoScreen.settle()
        let duoColumn = duoScreen.frame("side.panel") ?? .zero
        let duoFull: Bool = near(duoColumn.maxY, land.height) && near(duoColumn.minY, 0) && near(duoColumn.minX, leading + DMPhone.hairline)
        let duoX: CGFloat = leading + DMPhone.hairline + DMBrowserPhone.sidebarShellInset + BrowserSidebarMetrics.rowHorizontalPadding
        let duoTitleFrame: CGRect = duoScreen.frame("side.title") ?? .zero
        let duoTitleCentre: CGFloat = land.height - duoTitleFrame.midY
        let duoTitle: Bool = !duoTitleFrame.isEmpty && near(duoTitleFrame.minX, duoX) && abs(duoTitleCentre - DMBrowserPhone.sidebarTitleCenter) <= 1
        duoScreen.close()
        duoPhone.browser.closeAll()
        check(fullHeight && titleBeside && rowsUnder.isEmpty && pressed && duoFull && duoTitle,
              "S2c (W184 G2d third pass: 「duo的browser左列欄修到頂天」) laid out like GlobalDMPhoneBox (the top bar one layer above the columns): the sidebar runs from the very top of the box to its bottom — outer portrait, and the inner-landscape right column from that column's top edge — clipped by the box's corner; the page round buttons sit above it and a real click on one (TATWO) still switches away from the Browser; the space name is in the top row right of the round buttons (the right column has no round button: aligned with the rows, same centre line); the favorites, 新分頁 and tabs are below the round buttons and the toolbar",
              "column=\(topColumn) title=\(titleBeside) under=\(rowsUnder) pressed=\(pressed) duo=\(duoColumn) duoTitle=\(duoTitle)")

        // S3：連線卡片浮著（配對碼、輪到你）＝側欄停在卡片上面 8；卡片還是左右 12（寬＝Browser 區 − 24）；卡片的按鈕都不在側欄裡。
        // W184 G2c 第二輪（GPT-6 #4）：也量最小的兩種框（外直 ×0.7、內橫右欄 ×0.7）與最高的卡（手動步驟、手動模式的配對卡）。
        let cardPhone = Phone("sidebar-card")
        cardPhone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）"), key: 97, purpose: .chatgptPairing, expectedHost: nil)
        cardPhone.presenter.show()
        var stops: [String] = []
        let pairing = HandsConnectCard.pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(272), attemptsLeft: 5,
                                                                        callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true, surface: 97))
        var cases: [(String, CGSize, HandsConnectCard, [String])] = [
            ("pairing", size, pairing, ["card.dismiss"]),
            ("turn", size, HandsConnectCard.waitingUser(HandsConnectFlow.riskAckCardText, continuable: true), ["card.turnCancel", "card.continue"])]
        for box in smallBoxes {
            for card in tallCards(surface: 97) { cases.append(("\(box.name)/\(card.name)", box.size, card.card, card.buttons)) }
        }
        for (name, cardSize, card, buttons) in cases {
            cardPhone.box.card = card
            let cardScreen = Clickable(cardPhone.pane(.sidebar, probes: true), size: cardSize)
            await cardScreen.settle()
            let cardFrame = cardScreen.frame("card.frame") ?? .zero
            let area = cardScreen.frame("side.panel") ?? .zero
            let buttonFrames = buttons.compactMap { cardScreen.frame($0) }
            let clear: Bool = !cardFrame.isEmpty && area.minY >= cardFrame.maxY + DMBrowserPhone.sidebarGap - 1 && buttonFrames.count == buttons.count
                && buttonFrames.allSatisfy { !$0.intersects(area) } && near(area.maxY, cardSize.height)
            let cardPlaced: Bool = near(cardFrame.minX, 12) && near(cardFrame.width, cardSize.width - 24) && near(cardFrame.minY, 30)
            stops.append("\(name)=\(clear && cardPlaced)")
            cardScreen.close()
        }
        cardPhone.presenter.hide()
        cardPhone.browser.closeAll()
        check(stops.count == 8 && stops.allSatisfy { $0.hasSuffix("=true") },
              "S3 (W184 G2d; kept from G2c) with the pairing card or the 「輪到你」 card floating (and, in the outer-portrait ×0.7 and inner-landscape right-column ×0.7 boxes, the manual-steps card and the manual-mode pairing card), the full-height sidebar still starts at the top but stops 8 above the card; the card keeps 12 on both sides and none of its buttons (top-right 取消, 取消｜繼續) is under the sidebar",
              stops.joined(separator: " "))
        await scrolledCompactChecks(check)
        await sourceChecks(check)
        await guestRowChecks(check)
    }

    /// S2d（GPT-6 審查 G2d #3）：緊湊側欄（最小的框＋最高的卡片）捲到下面之後，指標到上緣叫出頂列——列表看得到的那一段整個在頂列下面
    /// （避開頂列的那一段在捲動區外面，不跟著捲走），緊貼頂列下緣的那一列真的按得到、真的做它的事（不是頂列的上一頁／下一頁）。
    /// 舊的做法（避開的那一段在捲動區裡）捲過之後列會跑到頂列底下——這裡會失敗。
    @MainActor static func scrolledCompactChecks(_ check: Checker) async {
        let phone = Phone("sidebar-scrolled")
        phone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）"), key: 95, purpose: .chatgptPairing, expectedHost: nil)
        let pairing = phone.browser.activeID
        var rows: [UUID] = []
        for n in 0..<3 {
            if let id = openedID(phone.browser.openBrowse(url: URL(string: "https://example.com/s\(n)")!, title: "分頁 \(n)", origin: .typed)) { rows.append(id) }
        }
        if let pairing { phone.browser.select(pairing) }
        if let tall = tallCards(surface: 95).first(where: { $0.name == "pairing" }) { phone.box.card = tall.card }
        phone.presenter.show()
        let small = smallBoxes.last?.size ?? CGSize(width: 342, height: 370)
        let screen = Clickable(phone.pane(.sidebar, probes: true), size: small)
        await screen.settle()
        let compact = screen.frame("side.mode.compact") != nil
        let last = rows.last.map { "side.tab.\($0.uuidString)" } ?? "side.newTab"
        let scrolledTo = await screen.scrollIntoView(last)
        // 叫出頂列：合成的指標到 Browser 區上緣（同使用者把滑鼠移上去）。
        screen.reveal?.evaluate(windowPoint: NSPoint(x: 120, y: small.height - 6))
        await screen.settle(3)
        let bar = screen.frame("bar.panel.tools") ?? screen.frame("bar.panel.folded") ?? .zero
        let viewport = screen.frame("side.scroll")
        let clipBelow: Bool = !bar.isEmpty && viewport.map { $0.maxY <= bar.minY + 0.5 } == true
        // 看得到的分頁列裡最靠上（緊貼頂列下緣）的那一列：按它看得到那一段的正中間。
        var visible: [(UUID, CGRect)] = []
        for id in rows {
            guard let frame = screen.frame("side.tab.\(id.uuidString)"), let viewport else { continue }
            let part = frame.intersection(viewport)
            if !part.isNull && part.height >= 10 { visible.append((id, part)) }
        }
        let top = visible.max { $0.1.maxY < $1.1.maxY }
        var pressed = false
        var partsBelow = false
        if let top {
            partsBelow = visible.allSatisfy { $0.1.maxY <= bar.minY + 0.5 }
            await screen.click(NSPoint(x: top.1.midX - 20, y: top.1.midY))
            pressed = phone.browser.activeID == top.0 && screen.toolbarDrawn
        }
        check(compact && scrolledTo != nil && clipBelow && partsBelow && pressed,
              "S2d (W184 G2d; GPT-6 G2d #3) the compact sidebar (smallest box + tallest card) scrolled down, then the toolbar called out at the top edge: the list's visible part is entirely below the toolbar (the band that keeps clear of it is outside the scroll area and does not scroll away), and the row right under the toolbar pressed with a real mouse does its own job (switches to that tab), not the toolbar's",
              "compact=\(compact) scrolled=\(String(describing: scrolledTo)) bar=\(bar) viewport=\(String(describing: viewport)) visible=\(visible.map { Int($0.1.maxY) }) pressed=\(pressed)")
        screen.close()
        phone.presenter.hide()
        phone.browser.closeAll()
    }

    /// S8（GPT-6 審查 G2d #2）：書籤、珍藏、Pinned 開的分頁住在各自那一列／那一格（不列在分頁清單）；主視窗刪掉書籤、移出珍藏、取消釘選之後，
    /// 那一頁回到下面的分頁清單——不從側欄消失、不關、不重新載入（舊的做法一律不列＝只能從「所有分頁」找回來，這裡會失敗）。
    @MainActor static func sourceChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        let phone = Phone("sidebar-sources")
        let pinID = phone.shelf.addPinned(URL(string: "https://example.org/pin")!, title: "釘選")
        let fromBookmark = phone.shelf.projected(phone.shelf.docs.id).flatMap { openedID(DMBrowserShelf.open(bookmark: $0, in: phone.browser)) }
        let fromFavorite = openedID(DMBrowserShelf.open(favorite: phone.shelf.favorite, in: phone.browser))
        let fromPinned = phone.shelf.pinnedTab(pinID).flatMap { openedID(DMBrowserShelf.open(pinned: $0, in: phone.browser)) }
        _ = await DMBrowserAcceptance.waitUntil(3) { phone.webHost.pages.count >= 3 }
        let screen = Clickable(phone.pane(.sidebar, probes: true), size: size)
        await screen.settle()
        let ids = [fromBookmark, fromFavorite, fromPinned].compactMap { $0 }
        let hiddenBefore: Bool = ids.count == 3 && ids.allSatisfy { screen.frame("side.tab.\($0.uuidString)") == nil }
        let openedBefore = phone.webHost.opened.count
        phone.shelf.store.deleteBookmark(phone.shelf.docs.id)          // 主視窗：書籤右鍵「刪除書籤」同一條
        phone.shelf.registry.removeFavorite(phone.shelf.favorite.id)   // 主視窗：珍藏右鍵「移出珍藏」同一條
        phone.shelf.registry.setPinned(pinID, false)                   // 主視窗：取消釘選
        await screen.settle()
        let listedAfter: Bool = ids.allSatisfy { screen.frame("side.tab.\($0.uuidString)") != nil }
        let kept: Bool = ids.allSatisfy { id in phone.browser.tabs.contains { $0.id == id } } && phone.webHost.opened.count == openedBefore
            && phone.webHost.pages.allSatisfy { $0.closes == 0 && $0.reloads == 0 }
        // 純計算：還在側欄上的來源＝不列；不在了、打網址開的＝列。
        let bookmark = UUID(), favorite = UUID(), pin = UUID()
        func tab(_ origin: DMBrowserBrowseOrigin) -> DMBrowserTabInfo {
            var info = DMBrowserTabInfo(id: UUID(), purpose: .browse, kind: .web, startURL: URL(string: "https://example.com/x"), expectedHost: nil)
            info.origin = origin
            return info
        }
        let S = DMBrowserSidebar.self
        let none: Set<UUID> = []
        let kept1: Bool = S.hasSidebarEntry(tab(.bookmark(bookmark)), bookmarks: [bookmark], favorites: none, pinned: none)
        let kept2: Bool = S.hasSidebarEntry(tab(.favorite(favorite)), bookmarks: none, favorites: [favorite], pinned: none)
        let kept3: Bool = S.hasSidebarEntry(tab(.pinned(pin)), bookmarks: none, favorites: none, pinned: [pin])
        let gone1: Bool = !S.hasSidebarEntry(tab(.bookmark(bookmark)), bookmarks: none, favorites: [bookmark], pinned: [bookmark])
        let gone2: Bool = !S.hasSidebarEntry(tab(.favorite(favorite)), bookmarks: [favorite], favorites: none, pinned: none)
        let gone3: Bool = !S.hasSidebarEntry(tab(.pinned(pin)), bookmarks: [pin], favorites: [pin], pinned: none)
        let typedListed: Bool = !S.hasSidebarEntry(tab(.typed), bookmarks: [bookmark], favorites: [favorite], pinned: [pin])
        let rule: Bool = kept1 && kept2 && kept3 && gone1 && gone2 && gone3 && typedListed
        check(hiddenBefore && listedAfter && kept && rule,
              "S8 (W184 G2d; GPT-6 G2d #2) tabs opened from a bookmark, a favorite and a pinned tab live on their sidebar entries; once the main window deletes the bookmark, removes the favorite and unpins the tab, those DM tabs come back to the tab list — not closed, not reloaded (only a source still in the sidebar keeps a tab out of the list)",
              "hiddenBefore=\(hiddenBefore) listedAfter=\(listedAfter) kept=\(kept) rule=\(rule) opened=\(phone.webHost.opened.count)/\(openedBefore)")
        screen.close()
        phone.browser.closeAll()
    }

    /// S9（W184 G2d；主導 09-30、GPT-6 審查 G2d #5）：借用主視窗那一份側欄時，只讀＋開啟的限制是能力參數擋的（列是同一份）——
    /// 📌 Pinned 那一列點了＝私訊框開它的網址（新的一般分頁；主視窗的分頁一個都沒多、釘選照舊），再點＝切過去，× 只關私訊框那一頁；
    /// ＋（新增空間）擺著、按不下去；下載鈕開下載清單時側欄留著（同主視窗 sidebarInteractionActive），再按收起＝放手。
    @MainActor static func guestRowChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        let phone = Phone("sidebar-guest")
        let pinID = phone.shelf.addPinned(URL(string: "http://example.org/pinned")!, title: "釘選的頁")
        let mainTabs = phone.shelf.store.tabs.count
        let screen = Clickable(phone.pane(.sidebar, probes: true), size: size)
        await screen.settle()
        var did: [String] = []
        if let point = screen.center("side.pin.\(pinID.uuidString)") {
            await screen.click(point)
            let opened = phone.browser.activeTab
            let fromPin: Bool = opened?.origin == DMBrowserBrowseOrigin.pinned(pinID)
            let https: Bool = opened?.startURL?.absoluteString == "https://example.org/pinned"
            let general: Bool = opened?.purpose == DMBrowserPurpose.browse
            let fresh: Bool = fromPin && https && general && phone.shelf.store.tabs.count == mainTabs
            await screen.click(point)
            let pinTabs: Int = phone.browser.tabs.filter { $0.origin == DMBrowserBrowseOrigin.pinned(pinID) }.count
            let onPin: Bool = phone.browser.activeTab?.origin == DMBrowserBrowseOrigin.pinned(pinID)
            let switched: Bool = pinTabs == 1 && onPin
            did.append("pin=\(fresh && switched)")
            await screen.settle(3)
            if let close = screen.center("side.pinclose.\(pinID.uuidString)") {
                await screen.click(close)
                let closedHere: Bool = !phone.browser.tabs.contains { $0.origin == DMBrowserBrowseOrigin.pinned(pinID) }
                let stillPinned: Bool = phone.shelf.registry.tabs.first { $0.id == pinID }?.isPinned == true
                let mainKept: Bool = stillPinned && phone.shelf.store.tabs.count == mainTabs
                did.append("pinClose=\(closedHere && mainKept)")
            }
        }
        let spacesBefore = phone.shelf.registry.spaces.count
        let selectedBefore = phone.shelf.store.selectedSpace.registryID
        if let plus = screen.center("side.space.add") {
            await screen.click(plus)
            let sameCount: Bool = phone.shelf.registry.spaces.count == spacesBefore
            let sameSpace: Bool = phone.shelf.store.selectedSpace.registryID == selectedBefore
            did.append("plus=\(sameCount && sameSpace)")
        }
        if let downloads = screen.center("side.downloads"), let reveal = screen.reveal {
            await screen.click(downloads)
            let held = reveal.holdsSidebar
            await screen.click(downloads)
            _ = await DMBrowserAcceptance.waitUntil(2) { !reveal.holdsSidebar }
            did.append("downloads=\(held && !reveal.holdsSidebar)")
        }
        check(did == ["pin=true", "pinClose=true", "plus=true", "downloads=true"],
              "S9 (W184 G2d; lead 09-30 + GPT-6 G2d #5) the borrowed sidebar keeps the DM read-and-open rules as capability parameters: the 📌 Pinned row opens the main window's pinned page as a NEW general DM tab (https; no main-window tab added, the pin untouched) and switches to it when pressed again, its × closes only the DM tab; ＋ (new space) sits where the main window has it but does nothing; the downloads button holds the sidebar out while its list is open and lets go when pressed again",
              did.joined(separator: " "))
        screen.close()
        phone.browser.closeAll()
    }

    // MARK: - T 頂列（主視窗 Browser space 那一排）

    @MainActor static func toolbarChecks(_ check: Checker) async {
        // T1 純計算：網址那一格照實際載入的頁；空白分頁、沒分頁不顯示網址；重新載入只給一般分頁；窄的時候收進 ⋯。
        let T = DMBrowserToolbar.self
        var mismatch = DMBrowserTabInfo(id: UUID(), purpose: .cloudflareLogin, kind: .web, startURL: URL(string: "https://a.trycloudflare.com/l"),
                                        expectedHost: "cloudflare.com")
        mismatch.pageURL = URL(string: "https://accounts.example.org/login")
        mismatch.canGoBack = true
        var unknown = DMBrowserTabInfo(id: UUID(), purpose: .chatgptPairing, kind: .popup(1), startURL: nil, expectedHost: nil)
        unknown.pageURL = nil
        var known = DMBrowserTabInfo(id: UUID(), purpose: .browse, kind: .web, startURL: URL(string: "https://example.com/a"), expectedHost: nil)
        known.pageURL = URL(string: "https://example.com/a")
        known.loading = false
        var blank = DMBrowserTabInfo(id: UUID(), purpose: .browse, kind: .web, startURL: nil, expectedHost: nil)
        blank.label = DMBrowser.blankTitle
        var done = DMBrowserTabInfo(id: UUID(), purpose: .cloudflareLogin, kind: .web, startURL: URL(string: "https://a.trycloudflare.com/l"), expectedHost: nil)
        done.pageURL = URL(string: "https://dash.cloudflare.com/")
        done.done = true
        done.pageClosed = true
        done.canGoBack = true
        let labels: Bool = T.label(mismatch) == "accounts.example.org（不是 cloudflare.com）" && T.label(unknown) == "尚未確認來源"
            && T.label(known) == nil && T.label(blank) == nil && T.label(done) == "頁面已關閉"
        let states: Bool = T.state(known).urlString == "https://example.com/a" && T.state(unknown).urlString == nil
            && T.state(mismatch).canGoBack && !T.state(done).canGoBack && T.state(done).urlString == nil && T.state(nil) == .blank
        let address: Bool = !T.showsAddress(nil) && !T.showsAddress(blank) && T.showsAddress(known) && T.showsAddress(unknown)
        let reload: Bool = DMBrowser.reloadable(known) && !DMBrowser.reloadable(blank) && !DMBrowser.reloadable(mismatch) && !DMBrowser.reloadable(done)
        let fold: Bool = T.showsTools(width: 466) && T.showsTools(width: 420) && !T.showsTools(width: 419) && !T.showsTools(width: 342)
        check(labels && states && address && reload && fold,
              "T1 (W184 G2d) the Browser space navigation bar gets the DM tab's facts: the address shows only a really loaded page (host mismatch / not https spelled out, 尚未確認來源, 完成); no address on a blank tab or with no tabs (the centered search takes over, same as the main window's start page); reload only for general tabs (never a flow page); below 420 translate / extensions / notes fold into ⋯",
              "labels=\(labels) states=\(states) address=\(address) reload=\(reload) fold=\(fold)")

        // T2 畫出來的順序（外直 466：工具擺在列上）、小框（內橫右欄 ×0.7：收進 ⋯）。
        let size = CGSize(width: 466, height: 610)
        let phone = Phone("toolbar")
        let page = EvidencePage("ChatGPT 登入（假頁面）")
        phone.browser.adoptPopup(page, key: 93, purpose: .chatgptLogin, expectedHost: nil)
        let loginID = phone.browser.activeID
        let screen = Clickable(phone.pane(.toolbar, probes: true), size: size, keyable: true)
        await screen.settle()
        let keys = ["bar.sidebar", "bar.nav", "bar.menu", "bar.translate", "bar.extensions", "bar.notes"]
        let frames = keys.compactMap { screen.frame($0) }
        let bar = screen.frame("bar.panel.tools") ?? .zero
        let leftToRight: Bool = frames.count == keys.count && zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 1 }
        let centered: Bool = frames.allSatisfy { abs($0.midY - bar.midY) < 2 } && frames.allSatisfy { bar.insetBy(dx: -1, dy: -1).contains($0) }
        let sizes: Bool = [0, 3, 4, 5].allSatisfy { index in frames.count == keys.count && near(frames[index].height, BrowserOmniboxMetrics.collapsedHeight) }
        check(leftToRight && centered && sizes && near(bar.height, 48),
              "T2 (W184 G2d) the toolbar is the main window's Browser space row, left to right: sidebar button, back / forward / reload / address, ⋯, translate, extensions, notes — 48 high, 32pt buttons, all on one line",
              "frames=\(frames.map { Int($0.minX) }) bar=\(bar)")
        let small = Clickable(phone.pane(.toolbar, probes: true), size: CGSize(width: 342, height: 370))
        await small.settle()
        let folded: Bool = small.frame("bar.panel.folded") != nil && small.frame("bar.menu") != nil && small.frame("bar.translate") == nil
            && small.frame("bar.notes") == nil && small.frame("bar.nav") != nil
        small.close()
        check(folded, "T2b in the inner-landscape right column ×0.7 (342 wide) translate, extensions and notes fold into ⋯ (the rest of the row stays)")

        // T3 真的滑鼠：側欄鈕（固定／收合：頁面讓出側欄那一欄）、上一頁（叫到頁面）、下一頁停用、流程頁不重新載入、一般分頁重新載入。
        var did: [String] = []
        if let sidebar = screen.center("bar.sidebar") {
            await screen.click(sidebar)
            let pinned = phone.browser.sidebarPinned
            let pushed = screen.frame("page.frame").map { near($0.minX, 250 + 12) } == true
            await screen.click(sidebar)
            let unpinned = !phone.browser.sidebarPinned && screen.frame("page.frame").map { near($0.minX, 12) } == true
            did.append("sidebar=\(pinned && pushed && unpinned)")
        }
        if let nav = screen.frame("bar.nav") {
            let y = nav.midY
            await screen.click(NSPoint(x: nav.minX + 8 + 16, y: y))
            await screen.click(NSPoint(x: nav.minX + 8 + 36 + 16, y: y))
            did.append("back=\(page.backs) forward=\(page.forwards)")
            let before = phone.webHost.opened.count
            await screen.click(NSPoint(x: nav.minX + 8 + 72 + 16, y: y))   // 登入視窗（流程頁）：重新載入按不下去
            did.append("flowReload=\(phone.webHost.opened.count == before)")
        }
        // 網址：點了打網址（網址欄打開、打字）＋ Return＝開新的一般分頁（登入視窗那一頁不改網址、不關）。
        if let nav = screen.frame("bar.nav") {
            await screen.click(NSPoint(x: nav.minX + 8 + 108 + 40, y: nav.midY))
            let editing = screen.panelState == .address
            let typed = await screen.type("example.com/t")
            await pressKey(36, characters: "\r", flags: [], in: screen.window)
            _ = await DMBrowserAcceptance.waitUntil(2) { phone.browser.activeTab?.purpose == .browse }
            let opened = phone.browser.activeTab?.startURL?.absoluteString == "https://example.com/t" && phone.browser.activeTab?.purpose == .browse
            let loginKept = page.closes == 0 && phone.browser.tabs.contains { $0.id == loginID }
            did.append("address=\(editing && typed && opened && loginKept && screen.panelState == nil)")
        }
        // 一般分頁（GPT-6 審查 G2d #1）：頁內走到 B（/t → /t2），按重新載入＝原生重新載入（同一個瀏覽器、頁面沒關沒重開、紀錄還在），
        // 再按上一頁＝回到 A（/t）。舊的做法（關掉重建）會把紀錄清掉、上一頁回不去——這裡會失敗。
        _ = await DMBrowserAcceptance.waitUntil(2) { phone.browser.activeTab?.pageURL != nil }
        await screen.settle(3)
        if let nav = screen.frame("bar.nav"), let id = phone.browser.activeID, let fake = phone.webHost.pages.last {
            let instance = phone.browser.page(for: id)
            fake.navigate(to: URL(string: "https://example.com/t2")!)
            await screen.settle(3)
            let atB: Bool = phone.browser.activeTab?.pageURL?.absoluteString == "https://example.com/t2" && phone.browser.activeTab?.canGoBack == true
            let before = phone.webHost.opened.count
            await screen.click(NSPoint(x: nav.minX + 8 + 72 + 16, y: nav.midY))   // 重新載入
            _ = await DMBrowserAcceptance.waitUntil(2) { fake.reloads == 1 }
            let samePage: Bool = phone.browser.page(for: id) === instance
            let nothingReopened: Bool = fake.reloads == 1 && fake.closes == 0 && phone.webHost.opened.count == before
            let sameBrowser: Bool = samePage && nothingReopened && phone.browser.activeTab?.pageURL?.absoluteString == "https://example.com/t2"
            await screen.click(NSPoint(x: nav.minX + 8 + 16, y: nav.midY))   // 上一頁
            _ = await DMBrowserAcceptance.waitUntil(2) { phone.browser.activeTab?.pageURL?.absoluteString == "https://example.com/t" }
            let stillSame: Bool = phone.browser.page(for: id) === instance
            let backToA: Bool = phone.browser.activeTab?.pageURL?.absoluteString == "https://example.com/t" && stillSame
            did.append("reload=\(atB && sameBrowser && backToA)")
        }
        check(did == ["sidebar=true", "back=1 forward=0", "flowReload=true", "address=true", "reload=true"],
              "T3 (W184 G2d; GPT-6 G2d #1) pressing the toolbar with a real mouse: the sidebar button pins the sidebar (the page gives up that column, same as the main window) and unpins it; back reaches the page, forward is disabled; reload does nothing on a flow page; the address opens the editor, typing and Return open a NEW general tab (the login page is not navigated or closed); on a general tab A→B, reload is the page's native reload (same browser, nothing closed or reopened) and back then returns to A",
              did.joined(separator: " "))
        // T3b（GPT-6 審查 G2d #1）：只有頁面沒建起來（建立失敗）時，頂列的重新載入才重建（同一個網址再開一次）；頁面在（就算這一頁載入失敗）＝
        // 原生重新載入（在它自己上面重試，不關、不重開）。
        let flaky = FlakyHost()
        let reloadStore = GlobalDMStore(defaults: UserDefaults(suiteName: "w184g2d.reload.\(UUID().uuidString)") ?? .standard,
                                        chatGPTAllowed: { true }, directKeys: true)
        let reloader = DMBrowser(store: reloadStore, openBox: {}, pageHost: flaky, podPage: { FakePage() }, windowShown: { $0.isVisible })
        let target = URL(string: "https://example.com/r")!
        flaky.failNext = true
        let rid = openedID(reloader.openBrowse(url: target, title: "r", origin: .typed))
        _ = await DMBrowserAcceptance.waitUntil(3) { reloader.activeTab?.problem != nil }
        let noPage: Bool = rid.map { reloader.page(for: $0) == nil } == true
        reloader.reloadActive()
        _ = await DMBrowserAcceptance.waitUntil(3) { flaky.pages.count == 1 && reloader.activeTab?.problem == nil }
        let rebuilt: Bool = noPage && flaky.requested == [target, target] && flaky.pages.count == 1 && reloader.activeTab?.problem == nil
        let built = flaky.pages.last
        built?.report?(GlobalDMWebPageState(loading: false, error: "連不上", committedURL: target, stacked: 0))
        let failedLoad: Bool = reloader.activeTab?.problem != nil
        reloader.reloadActive()
        let native: Bool = built?.reloads == 1 && built?.closes == 0 && flaky.requested.count == 2 && flaky.pages.count == 1
        reloader.closeAll()
        check(rebuilt && failedLoad && native,
              "T3b (W184 G2d; GPT-6 G2d #1) reload rebuilds only when the page never got built (same address opened again); a page that exists — even one whose load failed — gets its native reload (retried in place, not closed or reopened)",
              "noPage=\(noPage) requested=\(flaky.requested.map { $0.path }) failedLoad=\(failedLoad) reloads=\(String(describing: built?.reloads)) closes=\(String(describing: built?.closes))")
        // T4 翻譯、擴充、註解：照主視窗的樣子擺著，按不下去（私訊框的網頁是敏感頁，不注入東西；註解綁主視窗的分頁）。
        let auto = UserDefaults.standard.bool(forKey: BrowserPageTranslator.autoKey)
        let tabsBefore = phone.browser.tabs.count
        for key in ["bar.translate", "bar.extensions", "bar.notes"] {
            if let point = screen.center(key) { await screen.click(point) }
        }
        let inert: Bool = UserDefaults.standard.bool(forKey: BrowserPageTranslator.autoKey) == auto && phone.browser.tabs.count == tabsBefore
            && screen.panelState == nil
        UserDefaults.standard.set(auto, forKey: BrowserPageTranslator.autoKey)
        check(inert && !DMBrowserToolbar.translateOff.isEmpty && !DMBrowserToolbar.extensionsOff.isEmpty && !DMBrowserToolbar.notesOff.isEmpty,
              "T4 (W184 G2d) translate, extensions and notes sit where the main window has them but are dimmed and cannot be pressed in the DM Browser (its pages are sensitive pages — nothing is injected — and notes belong to the main window's tabs); their help says why")
        screen.close()
        phone.browser.closeAll()

        // T5 滑鼠指到上緣才出（同主視窗 W112 的頂列）：頂端 20 以內＝畫出來；往下回到網頁＝收掉。
        let hover = Phone("toolbar-hover")
        _ = hover.browser.openPod(purpose: .chatgptDeveloper)
        let hoverScreen = Clickable(hover.pane(probes: true), size: size)
        await hoverScreen.settle()
        if let reveal = hoverScreen.reveal {
            let quiet = hoverScreen.frame("bar.panel.tools") == nil
            reveal.evaluate(windowPoint: NSPoint(x: 300, y: size.height - 6))
            await hoverScreen.settle(3)
            let out = hoverScreen.frame("bar.panel.tools") != nil
            reveal.evaluate(windowPoint: NSPoint(x: 300, y: 300))
            await hoverScreen.settle(10)   // 淡出 0.12 秒之後才從畫面拿掉
            let gone = hoverScreen.frame("bar.panel.tools") == nil
            check(quiet && out && gone, "T5 (W184 G2d: 「應該是滑鼠指到展開玻璃」) the toolbar is not there until the pointer reaches the top of the Browser area, then the glass row appears; back over the page it goes away",
                  "quiet=\(quiet) out=\(out) gone=\(gone)")
        } else {
            check(false, "T5 the Browser's reveal anchor is drawn")
        }
        hoverScreen.close()
        hover.browser.closeAll()
    }

    // MARK: - Q 沒分頁、空白分頁：主視窗那個置中的搜尋框

    /// 置中搜尋框的輸入欄（SwiftUI 的 TextField 在 macOS 是 NSTextField）：在 search.panel 那一塊裡、能打字的那一個。
    @MainActor static func searchField(_ screen: Clickable) -> NSTextField? {
        guard let panel = screen.frame("search.panel") else { return nil }
        return views(NSTextField.self, in: screen.host).first { field in
            let frame = field.convert(field.bounds, to: nil)
            return field.isEditable && panel.contains(NSPoint(x: frame.midX, y: frame.midY))
        }
    }

    @MainActor static func searchChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        let phone = Phone("search")
        let screen = Clickable(phone.pane(probes: true), size: size, keyable: true)
        await screen.settle()
        // Q1 沒有分頁：置中的搜尋框（不是「還沒有分頁」那一段說明），沒有頁面容器。
        let panel = screen.frame("search.panel") ?? .zero
        let page = screen.frame("page.frame") ?? .zero
        let field = searchField(screen)
        let fieldFrame = field.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let centered: Bool = !fieldFrame.isEmpty && abs(fieldFrame.midY - page.midY) < page.height / 4 && page.contains(fieldFrame)
        check(!panel.isEmpty && screen.container == nil && field != nil && centered,
              "Q1 (W184 G2d: 「還沒有分頁的搜尋狀態也要一樣」) with no tabs the Browser shows the main window's centered search box (BrowserStartSearch: Search, ＋, send) inside the page frame — no page container underneath to swallow its clicks",
              "panel=\(panel) field=\(fieldFrame) container=\(screen.container != nil)")
        // Q2 真的點進去、打字、Return＝開新的一般分頁；搜尋框換成那一頁。
        var typedOpened = false
        if let field {
            let frame = field.convert(field.bounds, to: nil)
            await screen.click(NSPoint(x: frame.midX, y: frame.midY))
            let focused = screen.panelState == .search
            let typed = await screen.type("example.com/q")
            await pressKey(36, characters: "\r", flags: [], in: screen.window)
            _ = await DMBrowserAcceptance.waitUntil(2) { !phone.browser.tabs.isEmpty }
            await screen.settle(3)
            typedOpened = focused && typed && phone.browser.tabs.count == 1 && phone.browser.activeTab?.startURL?.absoluteString == "https://example.com/q"
                && phone.browser.activeTab?.purpose == .browse && screen.panelState == nil && screen.frame("search.panel") == nil && screen.container != nil
        }
        check(typedOpened, "Q2 clicking the search box, really typing an address and pressing Return opens it as a general tab (https), and the search box gives way to the page")
        // Q3 新分頁（側欄＋、搜尋框的＋、⌘⌥T 都走 DMBrowser.newTab）：空白分頁＝同一個置中搜尋框，游標已經在裡面。
        _ = phone.browser.newTab()
        _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState == .search }
        await screen.settle(3)
        let blankID = phone.browser.activeID
        let caret: Bool = phone.browser.activeTab?.isBlank == true && screen.panelState == .search && screen.window.firstResponder is NSTextView
            && screen.frame("search.panel") != nil && screen.container == nil
        check(caret, "Q3 a new tab is a blank general tab showing the same centered search box with the caret already in it (typing goes straight in)",
              "blank=\(phone.browser.activeTab?.isBlank == true) panel=\(String(describing: screen.panelState)) responder=\(String(describing: screen.window.firstResponder))")
        // Q4 在空白分頁上打字、Return＝開在這一個分頁上（同一個 id、不多開）。
        let count = phone.browser.tabs.count
        let typed = await screen.type("example.com/fill")
        await pressKey(36, characters: "\r", flags: [], in: screen.window)
        _ = await DMBrowserAcceptance.waitUntil(2) { phone.browser.activeTab?.isBlank == false }
        let filled: Bool = typed && phone.browser.activeID == blankID && phone.browser.tabs.count == count
            && phone.browser.activeTab?.startURL?.absoluteString == "https://example.com/fill"
        check(filled, "Q4 typed in the blank tab's search box and sent = that same tab is filled (same tab, nothing extra opened)",
              "typed=\(typed) tabs=\(phone.browser.tabs.map { $0.startURL?.path ?? "blank" })")
        screen.close()
        phone.browser.closeAll()
    }

    // MARK: - M 主視窗 Browser space 的元件照舊（私訊框那一支不碰主視窗的分頁）

    @MainActor final class Calls { var opened: [String] = [] }

    @MainActor static func mainComponentChecks(_ check: Checker) {
        let shelf = Shelf()
        let store = shelf.store
        // M1 側欄鈕：主視窗那一顆照舊跟著 store（收著＝focusMode）、按下去＝store.toggleSidebar。
        let before = store.focusMode
        let control = BrowserSidebarControls(store: store)
        let mirrors = control.collapsed == before
        control.toggle()
        let toggled = store.focusMode != before
        store.toggleSidebar()
        let restored = store.focusMode == before
        let dm = BrowserSidebarControls(collapsed: true, toggle: {})
        check(mirrors && toggled && restored && dm.collapsed,
              "M1 (W184 G2d) the main window's sidebar button still follows its store (collapsed = focusMode) and toggles store.toggleSidebar; the DM Browser uses the same button with its own pin state")
        guard let favorite = shelf.registry.favorites.first else { return check(false, "M2 fixture favorite") }
        // M2 珍藏那一排：主視窗那一排（沒給 external）點一格＝主視窗 store.openFavorite（綁在那一格的主視窗分頁）；
        //    私訊框那一排（external）＝只走私訊框的開法，主視窗的分頁一個都沒多。
        let width: CGFloat = 214
        let tile = (width - 16 - CGFloat(BrowserFavoritesStrip.visibleCount - 1) * BrowserFavoritesStrip.tileGap) / CGFloat(BrowserFavoritesStrip.visibleCount)
        let point = NSPoint(x: 8 + tile / 2, y: 19)
        func clickOnce<V: View>(_ view: V, size: CGSize, at point: NSPoint) {
            let screen = Clickable(view, size: size)
            screen.host.layoutSubtreeIfNeeded()
            screen.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    screen.window.sendEvent(event)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            screen.close()
        }
        let calls = Calls()
        let mainTabsBefore = store.tabs.count
        clickOnce(BrowserFavoritesStrip(store: store, external: BrowserFavoritesExternal(open: { calls.opened.append("favorite:" + $0.title) },
                                                                                        state: { _ in (false, false) })),
                  size: CGSize(width: width, height: 38), at: point)
        let dmOnly = calls.opened == ["favorite:" + favorite.title] && store.tabs.count == mainTabsBefore
        clickOnce(BrowserFavoritesStrip(store: store), size: CGSize(width: width, height: 38), at: point)
        let mainOpened = store.tabs.contains { $0.favoriteID == favorite.id } && calls.opened.count == 1
        check(dmOnly && mainOpened,
              "M2 (W184 G2d) the favorites strip: the DM's strip (external) only calls the DM's open and adds no main-window tab; the main window's strip still opens the favorite in the main window's store (store.openFavorite, bound to its tile)",
              "dm=\(dmOnly) main=\(mainOpened) calls=\(calls.opened) mainTabs=\(store.tabs.count)")
        // M3 書籤：主視窗那一條（沒給 external）點＝主視窗 store.openBookmark；私訊框那一條只走私訊框的開法。
        if let folder = store.folders.first, let bookmark = folder.bookmarks.first {
            let rowPoint = NSPoint(x: 90, y: 17)
            let tabsBefore = store.tabs.count
            clickOnce(BrowserBookmarkRow(store: store, bookmark: bookmark, folderID: folder.id,
                                         external: BrowserBookmarkExternal(open: { calls.opened.append("bookmark:" + $0.title) },
                                                                           state: { _ in (false, false, false) }, close: { _ in })),
                      size: CGSize(width: 214, height: 34), at: rowPoint)
            let dmRow = calls.opened.last == "bookmark:" + bookmark.title && store.tabs.count == tabsBefore
            clickOnce(BrowserBookmarkRow(store: store, bookmark: bookmark, folderID: folder.id), size: CGSize(width: 214, height: 34), at: rowPoint)
            let mainRow = store.tab(forBookmark: bookmark.id) != nil
            check(dmRow && mainRow,
                  "M3 (W184 G2d) bookmark rows: the DM's row only calls the DM's open; the main window's row still opens the bookmark in the main window's store (store.openBookmark, bound to the row)",
                  "dm=\(dmRow) main=\(mainRow)")
        } else {
            check(false, "M3 fixture bookmark")
        }
        // M4 空間圓點：同一顆 BrowserSpaceDot——主視窗那一顆（可編輯、沒有 choose）點下去＝畫出它的那一份 store 的 selectSpace（行為沒變）。
        // W184 G2d（GPT-6 審查 G2d #4）：私訊框那一顆走它自己的選擇回呼（DMBrowserSpaces.select：記下使用者最後一次選的空間），
        // 真的畫出私訊框的側欄、真的按那一顆：主視窗的 store 交過來之前 A→B→A＝選了 A（交接時照 A 切，不從最後的狀態反推成「沒選過」）；
        // 只切一次（A→B）＝交接時切到 B；沒按過＝不動主視窗。
        if let work = store.spaces.first(where: { $0.registryID == shelf.work }), let primary = store.spaces.first(where: { $0.registryID == shelf.primary }) {
            store.selectSpace(primary.id)
            let dotSize = CGSize(width: WorkspaceSpaceControlMetrics.cellWidth, height: WorkspaceSpaceControlMetrics.cellHeight)
            let center = NSPoint(x: dotSize.width / 2, y: dotSize.height / 2)
            clickOnce(BrowserSpaceDot(store: store, space: work, fallbackFill: .gray, idleFill: .gray), size: dotSize, at: center)
            let mainDot = store.selectedSpace.registryID == shelf.work
            store.selectSpace(primary.id)
            /// 私訊框的側欄（還沒接到主視窗的 store：DMBrowserSpaces 自己留一份），按一串空間圓點（真的滑鼠，按那一顆的正中間），
            /// 再把主視窗的 store（停在 mainAt）交過來：回傳交接之後主視窗在哪個空間、私訊框按完時在哪個空間。
            func dmDots(_ taps: [UUID], mainAt: UUID) -> (main: UUID?, dm: UUID?) {
                let alone = DMBrowserSpaces(registry: shelf.registry)
                let phone = Phone("m4-\(taps.count)")
                let pane = DMBrowserPane(store: phone.store, browser: phone.browser, flow: phone.flow, connect: phone.presenter, spaces: alone)
                    .environment(\.dmBrowserChromeShown, .sidebar)
                    .environment(\.dmFrameProbes, true)
                let screen = Clickable(pane, size: CGSize(width: 466, height: 610))
                for _ in 0..<4 {
                    screen.host.layoutSubtreeIfNeeded()
                    screen.window.displayIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                for tap in taps {
                    guard let point = screen.center("side.space." + tap.uuidString) else { continue }
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                          pressure: type == .leftMouseDown ? 1 : 0) {
                            screen.window.sendEvent(event)
                        }
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
                let dm = alone.store.selectedSpace.registryID
                screen.close()
                let main = BrowserWorkSpaceStore(registry: shelf.registry)
                if let space = main.spaces.first(where: { $0.registryID == mainAt }) { main.selectSpace(space.id) }
                alone.adopt(main)
                return (main.selectedSpace.registryID, dm)
            }
            let roundTrip = dmDots([shelf.work, shelf.primary], mainAt: shelf.work)
            let oneWay = dmDots([shelf.work], mainAt: shelf.primary)
            let untouched = dmDots([], mainAt: shelf.work)
            let tripKept: Bool = roundTrip.dm == shelf.primary && roundTrip.main == shelf.primary
            let oneWayKept: Bool = oneWay.dm == shelf.work && oneWay.main == shelf.work
            let dmPath: Bool = tripKept && oneWayKept && untouched.main == shelf.work
            check(mainDot && dmPath,
                  "M4 (W184 G2d; GPT-6 G2d #4) space dots: the main window's BrowserSpaceDot still switches the store that drew it; the DM sidebar's dot (pressed for real in the DM sidebar) goes through the DM's choice callback — before the main window's store arrives, A→B→A is a choice of A (the hand-over keeps A instead of guessing \"never chosen\" from the end state), A→B hands over B, no press leaves the main window alone",
                  "main=\(mainDot) roundTrip=\(roundTrip) oneWay=\(oneWay) untouched=\(untouched)")
        } else {
            check(false, "M4 fixture spaces")
        }
    }

    // MARK: - 畫面證據：跟主視窗 Browser space 的同一元件並排

    /// 主視窗 Browser space 的頂列：同一組元件、照 BrowserWorkSpaceDesignView.workspaceToolbar 的排法（整個主視窗在自測裡畫不出來：
    /// 沒有 Chromium、頂列平常要滑鼠叫）。只給畫面證據用。
    struct MainToolbarSample: View {
        @ObservedObject var store: BrowserWorkSpaceStore
        @StateObject private var translator = BrowserPageTranslator()
        @State private var query = ""
        @FocusState private var focused: Bool

        var body: some View {
            HStack(spacing: BrowserOmniboxMetrics.controlGap) {
                BrowserSidebarControls(store: store)
                EmbeddedBrowserToolbar(addressText: $query, addressFieldFocused: $focused,
                                       state: EmbeddedBrowserNavigationState(urlString: "https://chatgpt.com/plugins", canGoBack: true,
                                                                             canGoForward: false, visibleError: nil),
                                       enabled: true, onSubmit: {}, onCommand: { _ in })
                BrowserActionsButton { Button("在網頁中尋找…") {} }
                BrowserTranslateButton(translator: translator, host: "chatgpt.com", size: BrowserOmniboxMetrics.collapsedHeight)
                Button {} label: {
                    Image(systemName: "puzzlepiece.extension")
                        .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
                }.buttonStyle(.plain)
                Button {} label: {
                    Image(systemName: "note.text")
                        .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
                }.buttonStyle(.plain).fixedSize()
            }
            .font(.system(size: BrowserOmniboxMetrics.iconSize))
            .foregroundStyle(LiquidGlassTokens.browserOmniboxInk)
            .padding(.horizontal, BrowserOmniboxMetrics.horizontalInset)
            .frame(height: BrowserOmniboxMetrics.toolbarHeight)
            .background { BrowserFloatingToolbarBackdrop() }
        }
    }

    /// 主視窗 Browser space 的側欄，照 ChatPage.browserSidebar 的擺法（主導 09-30：「請查實際的主視窗 Browser space 是怎麼擺的」）：
    /// WorkspaceSidebarShell 裡上面是主視窗的模式頁籤（WorkspaceSidebarModePicker，headerTopInset 22；私訊框對應的是左上的頁面圓鈕）、
    /// 下面是真的 BrowserWorkSpaceSidebarList；空間名稱在視窗頂列、紅綠燈右邊（appControlLeadingX、紅綠燈同一條中心線）。
    /// 紅綠燈是視窗的原生鈕（自測畫不出來）：照 WindowChromeMetrics 的位置畫三個同色的圓點代表；最下面的 OS 列（TATWO OS、更新、帳號）
    /// 是整個主視窗的，不在這裡。
    @MainActor static func mainSidebar(_ store: BrowserWorkSpaceStore) -> some View {
        WorkspaceSidebarShell {
            VStack(alignment: .leading, spacing: WorkspaceSidebarMetrics.sectionSpacing) {
                WorkspaceSidebarModePicker(modes: [.tatwo, .chat, .cli, .browser, .chatgpt], selection: .browser) { _ in }
                    .padding(.top, WorkspaceSidebarMetrics.headerTopInset)
                BrowserWorkSpaceSidebarList(store: store).frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) { MainTopRow(store: store) }
    }

    /// 主視窗頂列那一排：紅綠燈（代表的圓點）＋空間名稱（同 ChatPage.browserSpaceMenu 的字：粗 13、22 高、124 寬、紅綠燈中心線、光學修正 1）。
    struct MainTopRow: View {
        @ObservedObject var store: BrowserWorkSpaceStore

        var body: some View {
            let M = WindowChromeMetrics.self
            let center = M.trafficLightTopInset + M.nativeTrafficLightDiameter / 2
            let lights: [Color] = [Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)]
            ZStack(alignment: .topLeading) {
                ForEach(lights.indices, id: \.self) { index in
                    Circle().fill(lights[index])
                        .frame(width: M.nativeTrafficLightDiameter, height: M.nativeTrafficLightDiameter)
                        .offset(x: M.trafficLightLeadingInset + CGFloat(index) * (M.nativeTrafficLightDiameter + M.nativeTrafficLightSpacing),
                                y: center - M.nativeTrafficLightDiameter / 2)
                }
                Text(store.selectedSpace.name)
                    .font(.system(size: WorkspaceSidebarMetrics.spaceSwitcherFontSize, weight: .bold)).lineLimit(1)
                    .frame(width: WorkspaceSidebarMetrics.spaceSwitcherMenuWidth, height: WorkspaceSidebarMetrics.spaceSwitcherHeight, alignment: .leading)
                    .offset(x: M.appControlLeadingX, y: center - WorkspaceSidebarMetrics.spaceSwitcherHeight / 2 - DMBrowserPhone.sidebarTitleLift)
            }
            .allowsHitTesting(false)
        }
    }

    /// 主視窗 Browser space 沒分頁時的置中搜尋框：同一個 BrowserStartSearch、主視窗給的參數。
    struct MainStartSample: View {
        @ObservedObject var store: BrowserWorkSpaceStore
        @State private var query = ""
        @FocusState private var focus: Int?

        var body: some View {
            BrowserStartSearch(query: $query, focus: $focus, field: 0, canAddTab: store.canAddTab, suggestions: store.suggestions(for: query),
                               notice: store.notice, onSubmit: {}, onAddTab: {}, onSuggestion: { _ in }) { EmptyView() }
                .background(TatwoActivePalette.current.canvasBase)
        }
    }

    /// 兩張並排：左＝私訊框（整支手機），右＝主視窗的同一元件（寫明是哪一個）。
    @MainActor static func pair(_ dm: some View, dmSize: CGSize, _ main: some View, mainSize: CGSize, label: String) -> (AnyView, CGSize) {
        let gap: CGFloat = 28
        let caption: CGFloat = 22
        let view = HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: 6) {
                Text("私訊框 Browser").font(.system(size: DMPhone.TextSize.footnote, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(height: caption - 6, alignment: .leading)
                dm.frame(width: dmSize.width, height: dmSize.height)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: DMPhone.TextSize.footnote, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(height: caption - 6, alignment: .leading)
                main.frame(width: mainSize.width, height: mainSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        let size = CGSize(width: dmSize.width + gap + mainSize.width + 32, height: max(dmSize.height, mainSize.height) + caption + 32)
        return (AnyView(view), size)
    }

    @MainActor static func g2dEvidence(out: URL) async -> [String] {
        var written: [String] = []
        func shoot(_ name: String, _ shot: (AnyView, CGSize)) {
            guard let rendered = GlobalDMChatAcceptance.renderSync(shot.0, size: shot.1) else { return }
            if save(rendered, name, to: out) { written.append(name) }
            rendered.close()
        }
        let phoneSize = CGSize(width: GlobalDMForm.outerPortrait.size.width + GlobalDMLayout.margin * 2,
                               height: GlobalDMForm.outerPortrait.size.height + GlobalDMLayout.margin * 2)
        let browserHeight = GlobalDMForm.outerPortrait.size.height - DMPhone.headerHeight

        let phone = Phone("g2d-evidence")
        phone.shelf.addPinned(URL(string: "https://example.org/pinned")!, title: "釘選的頁")   // 兩邊的 📌 Pinned 底下都有這一列
        phone.store.showBrowser()
        _ = phone.browser.openPod(purpose: .chatgptDeveloper)
        phone.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
        _ = phone.browser.openBrowse(url: URL(string: "https://example.com/news")!, title: "打的網址", origin: .typed)
        if let docs = phone.shelf.projected(phone.shelf.docs.id) { _ = DMBrowserShelf.open(bookmark: docs, in: phone.browser) }
        _ = await DMBrowserAcceptance.waitUntil(3) { phone.webHost.opened.count >= 2 }
        if let pod = phone.browser.tabs.first(where: { $0.kind == .pod }) { phone.browser.select(pod.id) }
        // 1. 頂列（滑鼠指到上緣展開的玻璃）｜主視窗 Browser space 的頂列（同一組元件）。
        shoot("g2d-toolbar.png", pair(phoneShot(phone.store, phone.pane(.toolbar)), dmSize: phoneSize,
                                      MainToolbarSample(store: phone.shelf.store).frame(maxHeight: .infinity, alignment: .top)
                                          .background(Color(nsColor: .textBackgroundColor)),
                                      mainSize: CGSize(width: 720, height: BrowserOmniboxMetrics.toolbarHeight + 96),
                                      label: "主視窗 Browser space 的頂列（同一組元件、同一個排法）"))
        // 2. 側欄展開（頂天）｜主視窗 Browser space 的側欄（BrowserWorkSpaceSidebarList）。
        shoot("g2d-sidebar.png", pair(phoneShot(phone.store, phone.pane(.sidebar)), dmSize: phoneSize,
                                      mainSidebar(phone.shelf.store), mainSize: CGSize(width: WorkspaceSidebarMetrics.width, height: browserHeight),
                                      label: "主視窗 Browser space 的側欄"))
        // 2b（W184 G2d 第三輪：「左列欄修到頂天」；主導 09-30：兩邊要看得出是同一套）：側欄從框頂到底、空間名稱在頂列那一排（頁面圓鈕右邊）、
        // 下面是同一份 BrowserWorkSpaceSidebarList｜主視窗 Browser space 的側欄（從視窗頂到底：紅綠燈右邊是空間名稱、模式頁籤、同一份列表）。
        shoot("g2d-sidebar-top.png", pair(phoneShot(phone.store, phone.pane(.sidebar)), dmSize: phoneSize,
                                          mainSidebar(phone.shelf.store),
                                          mainSize: CGSize(width: WorkspaceSidebarMetrics.width, height: GlobalDMForm.outerPortrait.size.height),
                                          label: "主視窗 Browser space（紅綠燈示意）"))
        // 5. 連線卡片（假碼）＋側欄：側欄停在卡片上面 8｜主視窗的側欄。
        phone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）：輸入私訊框上的 8 碼"), key: 74, purpose: .chatgptPairing,
                                 expectedHost: HandsConnectAcceptance.publicHost)
        phone.box.card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(272), attemptsLeft: 5,
                                                          callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true, surface: 74))
        phone.presenter.show()
        phone.presenter.setCodeVisible(true)
        shoot("g2d-card-sidebar.png", pair(phoneShot(phone.store, phone.pane(.sidebar)), dmSize: phoneSize,
                                           mainSidebar(phone.shelf.store), mainSize: CGSize(width: WorkspaceSidebarMetrics.width, height: browserHeight),
                                           label: "主視窗 Browser space 的側欄"))
        phone.presenter.setCodeVisible(false)
        phone.box.card = nil
        phone.presenter.hide()
        // 3. 沒分頁時的置中搜尋框｜主視窗 Browser space 沒分頁時的同一個搜尋框。
        let empty = Phone("g2d-search")
        empty.store.showBrowser()
        shoot("g2d-search.png", pair(phoneShot(empty.store, empty.pane()), dmSize: phoneSize,
                                     MainStartSample(store: empty.shelf.store), mainSize: CGSize(width: 720, height: browserHeight),
                                     label: "主視窗 Browser space 沒分頁時（同一個 BrowserStartSearch）"))
        // 4. 內橫右欄：左欄對話、右欄 Browser（頂列＋側欄都展開）｜主視窗的側欄。
        let form = GlobalDMForm.innerLandscape
        let leading = (form.size.width * DMPhone.duoLeadingFraction).rounded()
        let bubbles = [GlobalDMBubble(id: "g2d-1", kind: .mine, text: "幫我開書籤裡的 Primary One 文件"),
                       GlobalDMBubble(id: "g2d-2", kind: .theirs, text: "右邊的 Browser 跟主視窗的 Browser space 一樣：滑到左緣是側欄，滑到上緣是頂列。")]
        let duo = PhoneColumns(store: phone.store, form: form) {
            HStack(spacing: 0) {
                GlobalDMMessageList(bubbles: bubbles, emptyText: "")
                    .frame(width: leading)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: DMPhone.hairline)
                    .padding(.top, DMPhone.dividerTop)
                    .padding(.bottom, DMPhone.dividerBottom)
                phone.pane(.all)
            }
        }
        .frame(width: form.size.width, height: form.size.height)
        .modifier(GlobalDMBoxChrome())
        .padding(GlobalDMLayout.margin)
        shoot("g2d-duo.png", pair(duo, dmSize: CGSize(width: form.size.width + GlobalDMLayout.margin * 2, height: form.size.height + GlobalDMLayout.margin * 2),
                                  mainSidebar(phone.shelf.store), mainSize: CGSize(width: WorkspaceSidebarMetrics.width, height: form.size.height),
                                  label: "主視窗 Browser space（紅綠燈示意）"))
        phone.browser.closeAll()
        // 6. 最小的框（外直 ×0.7）＋手動連線卡（步驟縮短讓位）＋側欄展開（停在卡片上面）。
        let small = Phone("g2d-small")
        small.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）"), key: 75, purpose: .chatgptPairing, expectedHost: nil)
        small.box.card = tallCards(surface: 75).first { $0.name == "manual" }?.card
        small.presenter.show()
        let smallSize = CGSize(width: 326 + GlobalDMLayout.margin * 2, height: 475 + GlobalDMLayout.margin * 2)
        if let rendered = GlobalDMChatAcceptance.renderSync(smallShot(small.store, small.pane(.sidebar)), size: smallSize) {
            if save(rendered, "g2d-small-manual.png", to: out) { written.append("g2d-small-manual.png") }
            rendered.close()
        }
        small.presenter.hide()
        small.browser.closeAll()
        // 7. 十一個空間：同主視窗那一排（WorkspaceSpaceControls＋BrowserSpaceDot）｜主視窗的側欄。
        let many = Phone("g2d-spaces")
        for (n, color) in ["graphite", "blue", "yellow", "pink", "red", "orange", "green", "purple"].enumerated() {
            let id = many.shelf.registry.addSpace(name: "空間 \(n + 3)").id
            many.shelf.registry.setSpaceColor(id, color)
        }
        _ = many.browser.openPod(purpose: .chatgptDeveloper)
        shoot("g2d-spaces.png", pair(phoneShot(many.store, many.pane(.sidebar)), dmSize: phoneSize,
                                     mainSidebar(many.shelf.store), mainSize: CGSize(width: WorkspaceSidebarMetrics.width, height: browserHeight),
                                     label: "主視窗 Browser space 的側欄"))
        many.browser.closeAll()
        // 照 run() 期待的順序排（頂列、側欄、搜尋、內橫、卡片＋側欄、小框、空間）。
        let order = ["g2d-toolbar.png", "g2d-sidebar.png", "g2d-sidebar-top.png", "g2d-search.png", "g2d-duo.png", "g2d-card-sidebar.png",
                     "g2d-small-manual.png", "g2d-spaces.png"]
        return order.filter(written.contains)
    }
}
#endif
