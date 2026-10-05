import AppKit
import SwiftUI

// W184 G2d（使用者 09-30 02:4x 實測 .031：「duo的browser左列欄修到頂天 上方這些功能跟我們設計的 browser space設計不同」
// 「應該是滑鼠指到展開玻璃」「還沒有分頁的搜尋狀態也要一樣」「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：
// 私訊框 Browser 的頂列與側欄直接用主視窗 Browser space 的元件，只接私訊框自己的分頁、只做尺寸自適應——
// - 頂列＝BrowserSidebarControls＋EmbeddedBrowserToolbar（上一頁、下一頁、重新載入、網址）＋BrowserActionsButton（⋯）＋
//   BrowserTranslateButton（翻譯）＋擴充＋註解（同主視窗 auxiliaryBrowserControls 的兩顆）；字級、鈕的大小、間距照 BrowserOmniboxMetrics。
//   頂列窄（DMBrowserPhone.toolbarToolsMinWidth）＝翻譯、擴充、註解收進 ⋯。
// - 側欄＝WorkspaceSidebarShell（玻璃、頂天）裡放主視窗那一份 BrowserWorkSpaceSidebarList 本身（借用模式 BrowserSidebarGuest；主導 09-30、
//   GPT-6 審查 G2d #5：不是照抄排出來的另一份）：珍藏那一排、📌 Pinned、書籤資料夾與書籤、分隔線、新分頁、分頁、下載＋空間圓點＋＋，
//   列的內容、順序、標頭同主視窗；空間名稱擺在頂列那一排（主視窗：紅綠燈右邊；私訊框：頁面圓鈕右邊）。
// 私訊框的網頁都是敏感頁（授權頁、配對頁、Pod、私訊框開的一般網頁：只准 https、不注入東西、不進分頁清單與紀錄），所以：
// - 翻譯、擴充、註解照主視窗的樣子擺著但變暗、按不下去，說明寫原因（翻譯、擴充會注入網頁；註解綁主視窗分頁清單的分頁）。
// - 網址欄打的字、書籤、珍藏、Pinned 一律開私訊框的一般分頁（DMBrowser.openBrowse：開在開始打字的那一個空白分頁，或開新分頁），
//   絕不在 Pod、配對、授權分頁裡導航；重新載入只給一般分頁（流程的頁不動；頁面還在＝原生重新載入，紀錄都在）。
// - 書籤、珍藏、Pinned、空間在這裡只讀＋開啟＋切換空間（W184 G2 施工單：書籤「只讀＋開啟；改名、刪除、搬移不做（在主視窗做）」）：
//   不改名、不刪、不拖不放、沒有右鍵選單、不新增空間（＋擺著、按不下去）——都是借用模式的能力參數擋的，列本身是同一份。

/// 私訊框 Browser 的頂列（主視窗 Browser space 那一排）。
struct DMBrowserToolbar: View {
    @ObservedObject var browser: DMBrowser
    @Binding var address: String
    let focused: FocusState<Bool>.Binding
    @Binding var expansionRequest: Bool
    @Binding var editing: Bool
    /// 頂列多寬（畫面照 Browser 區給；決定翻譯、擴充、註解擺在列上還是收進 ⋯）。
    let width: CGFloat
    let probe: Bool
    let onSubmit: () -> Void
    let showTabs: () -> Void
    let newTab: () -> Void
    /// 私訊框的網頁不能翻譯；這一顆照主視窗的樣子擺著（它自己的翻譯器，按不下去）。
    @StateObject private var translator = BrowserPageTranslator()

    static let translateOff = "私訊框的網頁不翻譯：授權頁、配對頁與私訊框開的網頁都是敏感頁，不注入東西（要翻譯到主視窗的 Browser 開）"
    static let extensionsOff = "擴充功能不在私訊框的網頁上執行（敏感頁）；要管理擴充到主視窗的 Browser"
    static let notesOff = "註解綁主視窗 Browser 的分頁；私訊框的網頁不進分頁清單，沒有註解"

    /// 翻譯、擴充、註解擺在列上（寬度夠）還是收進 ⋯。
    static func showsTools(width: CGFloat) -> Bool { width >= DMBrowserPhone.toolbarToolsMinWidth }

    var body: some View {
        let tab = browser.activeTab
        let tools = Self.showsTools(width: width)
        HStack(spacing: BrowserOmniboxMetrics.controlGap) {
            BrowserSidebarControls(collapsed: !browser.sidebarPinned, toggle: browser.toggleSidebar)
                .background { if probe { DMFrameProbe(key: "bar.sidebar") } }
            EmbeddedBrowserToolbar(addressText: $address, addressFieldFocused: focused, state: Self.state(tab), enabled: true,
                                   onSubmit: onSubmit, onCommand: { command($0) },
                                   openTabs: browser.tabs.filter { !$0.isBlank }.map {
                                       BrowserAddressSuggestion(id: $0.id.uuidString, title: $0.title, url: $0.pageURL?.absoluteString ?? "")
                                   },
                                   onSelectTab: { id in if let uuid = UUID(uuidString: id) { browser.select(uuid) } },
                                   expansionRequest: $expansionRequest, showsAddress: Self.showsAddress(tab),
                                   labelOverride: Self.label(tab), isEditing: $editing,
                                   reloadAllowed: tab.map(DMBrowser.reloadable) ?? false)
                .background { if probe { DMFrameProbe(key: "bar.nav") } }
            BrowserActionsButton { menu(foldedTools: !tools) }
                .background { if probe { DMFrameProbe(key: "bar.menu") } }
            if tools {
                BrowserTranslateButton(translator: translator, host: nil, size: BrowserOmniboxMetrics.collapsedHeight,
                                       unavailableReason: Self.translateOff)
                    .accessibilityValue("私訊框不能用")
                    .background { if probe { DMFrameProbe(key: "bar.translate") } }
                toolButton("puzzlepiece.extension", label: "擴充功能", reason: Self.extensionsOff, id: "browser.extensions", probeKey: "bar.extensions")
                toolButton("note.text", label: "註解", reason: Self.notesOff, id: "tatwo.dm.browser.notes", probeKey: "bar.notes")
            }
        }
        .font(.system(size: BrowserOmniboxMetrics.iconSize))
        .foregroundStyle(LiquidGlassTokens.browserOmniboxInk)
        .padding(.horizontal, BrowserOmniboxMetrics.horizontalInset)
        .frame(height: BrowserOmniboxMetrics.toolbarHeight)
        .background(BrowserChromeHitLayer())
        .background { if probe { DMFrameProbe(key: tools ? "bar.panel.tools" : "bar.panel.folded") } }
    }

    /// 主視窗 auxiliaryBrowserControls 的那兩顆（擴充、註解）：同圖示、同 32 的格子；私訊框的網頁用不到＝變暗、按不下去，說明寫原因。
    private func toolButton(_ symbol: String, label: String, reason: String, id: String, probeKey: String) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
                .opacity(0.3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(true)
        .help(reason).accessibilityLabel(label).accessibilityValue("私訊框不能用").accessibilityIdentifier(id)
        .fixedSize()
        .background { if probe { DMFrameProbe(key: probeKey) } }
    }

    /// ⋯（瀏覽器功能）：私訊框用得到的那幾項；頂列窄時翻譯、擴充、註解也在這裡（變暗、寫原因）。
    @ViewBuilder
    private func menu(foldedTools: Bool) -> some View {
        Button("這個 Browser 在這台：\(DMBrowser.deviceName)") {}.disabled(true)
        Divider()
        Button("新分頁（\(DMBrowserNewTabKey.display)）") { newTab() }
        Button("所有分頁（\(browser.tabs.count)）…", action: showTabs).disabled(browser.tabs.isEmpty)
        if let tab = browser.activeTab {
            Button(browser.closingCancels(tab.id) ? "關閉目前分頁（這一次還沒完成，會一起取消）" : "關閉目前分頁") { browser.userClose(tab.id) }
        }
        if browser.canOpenElsewhere {
            Button("改在 OS 瀏覽器開") { browser.openElsewhere() }
        }
        Divider()
        Button(browser.sidebarPinned ? "收合側欄" : "展開並固定側欄", action: browser.toggleSidebar)
        if foldedTools {
            Divider()
            Button("翻譯：" + Self.translateOff) {}.disabled(true)
            Button("擴充功能：" + Self.extensionsOff) {}.disabled(true)
            Button("註解：" + Self.notesOff) {}.disabled(true)
        }
    }

    private func command(_ action: EmbeddedBrowserCommand.Action) {
        switch action {
        case .goBack: browser.goBack()
        case .goForward: browser.goForward()
        case .reload: browser.reloadActive()
        default: break
        }
    }

    /// 網址欄給主視窗那條導覽列看的狀態：只照實際載入的頁（W183 R8b：沒有、空白頁、別的協定、頁面關了＝沒有網址）；
    /// 上一頁／下一頁照私訊框的分頁；私訊框沒有「停止載入」，重新載入那一顆一律是重新載入（只給一般分頁）。
    static func state(_ tab: DMBrowserTabInfo?) -> EmbeddedBrowserNavigationState {
        guard let tab else { return .blank }
        return EmbeddedBrowserNavigationState(urlString: tab.sourceKnown ? tab.pageURL?.absoluteString : nil,
                                              canGoBack: tab.canGoBack && !tab.pageClosed, canGoForward: tab.canGoForward && !tab.pageClosed,
                                              visibleError: nil)
    }

    /// 沒有分頁、空白的新分頁＝不顯示網址（中間是置中的搜尋框；同主視窗的起始頁）。
    static func showsAddress(_ tab: DMBrowserTabInfo?) -> Bool {
        guard let tab else { return false }
        return !tab.isBlank
    }

    /// 網址那一格的字：來源確認了＝網域（網域對不上、不是 https 再寫出來）；沒確認＝白話（尚未確認來源、完成、確認中）。
    static func label(_ tab: DMBrowserTabInfo?) -> String? {
        guard let tab, !tab.isBlank else { return nil }
        guard tab.sourceKnown else { return tab.sourceText }
        if tab.hostMismatch, let expected = tab.expectedHost { return "\(tab.displayHost)（不是 \(expected)）" }
        if tab.isInsecure { return "\(tab.displayHost)（連線不安全）" }
        return nil
    }
}

/// 私訊框 Browser 的側欄＝主視窗 Browser space 的側欄那一份（BrowserWorkSpaceSidebarList，借用模式 BrowserSidebarGuest），放在同一片玻璃殼
/// （WorkspaceSidebarShell）裡。W184 G2d（主導 09-30 轉使用者：「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」；
/// GPT-6 審查 G2d #5）：列的內容、順序、標頭都是那一份自己的（珍藏那一排、📌 Pinned、書籤資料夾與書籤、分隔線、新分頁、分頁、
/// 下載＋空間圓點＋＋）；私訊框只多兩段尺寸自適應——頂列那一排（空間名稱：擺法同主視窗「紅綠燈右邊」＝頁面圓鈕右邊）與頂列浮出來的那一段（空著）。
struct DMBrowserSidebar: View {
    @ObservedObject var browser: DMBrowser
    /// 書籤、珍藏、空間（主視窗的那一份；主視窗的 store 交過來＝跟著換）。
    @ObservedObject var spaces: DMBrowserSpaces
    let width: CGFloat
    /// 側欄在 Browser 區裡多高（到連線卡片上面 8；太矮＝緊湊擺法，見 Inner.compact）。
    let height: CGFloat
    /// W184 G2d：側欄往上伸到框頂的那一段（私訊框頂列的高度）：空間名稱擺在這一段（頁面圓鈕那一排）；列表照舊從 Browser 區、頂列下面開始。
    var topInset: CGFloat = 0
    /// 空間名稱從側欄左緣多遠開始（單欄：頁面圓鈕右邊；nil＝對齊側欄的列：內橫右欄的左上沒有圓鈕）。
    var titleLeading: CGFloat? = nil
    let probe: Bool
    let finish: (DMBrowserBrowseResult) -> Void
    let newTab: () -> Void
    /// 側欄上開著東西（下載清單）＝把側欄留著（DMBrowserBarReveal.holdSidebar；主視窗是 store.sidebarInteractionActive）。
    var interaction: (Bool) -> Void = { _ in }

    /// 新增空間在主視窗做（＋照主視窗的位置擺著、按不下去）。
    static let addSpaceOff = "新增空間請到主視窗的 Browser（私訊框只切換空間）"

    var body: some View {
        Inner(store: spaces.store, spaces: spaces, browser: browser, width: width, compact: height < DMBrowserPhone.sidebarCompactHeight,
              topInset: topInset, titleLeading: titleLeading, probe: probe, finish: finish, newTab: newTab, interaction: interaction)
    }

    /// W184 G2d（GPT-6 審查 G2d #2）：同主視窗——書籤、珍藏、Pinned 開的分頁住在各自那一列／那一格，不列在下面的分頁裡；只有那一列
    /// 還在側欄上才這樣：來源不在了（主視窗刪了書籤、移出珍藏、取消釘選）或換了空間看不到＝回到下面的分頁清單（不關、不重新載入）。
    nonisolated static func hasSidebarEntry(_ tab: DMBrowserTabInfo, bookmarks: Set<UUID>, favorites: Set<UUID>, pinned: Set<UUID>) -> Bool {
        switch tab.origin {
        case .bookmark(let id)?: return bookmarks.contains(id)
        case .favorite(let id)?: return favorites.contains(id)
        case .pinned(let id)?: return pinned.contains(id)
        case .typed?, nil: return false
        }
    }

    private struct Inner: View {
        @ObservedObject var store: BrowserWorkSpaceStore
        let spaces: DMBrowserSpaces
        @ObservedObject var browser: DMBrowser
        let width: CGFloat
        /// W184 G2d 尺寸自適應：小框＋最高的連線卡把側欄壓得很矮時，玻璃內距從 18 縮成 8、最下面那一排跟著列表一起捲（同一份列表、同一個順序、
        /// 每一格都捲得到、按得到）；平常＝主視窗那一套（內距 18、最下面那一排固定）。
        let compact: Bool
        let topInset: CGFloat
        let titleLeading: CGFloat?
        let probe: Bool
        let finish: (DMBrowserBrowseResult) -> Void
        let newTab: () -> Void
        let interaction: (Bool) -> Void
        /// 資料夾展開與否是私訊框自己的（一開始照主視窗那一份；在這裡點＝只改這裡）。
        @State private var expanded: [UUID: Bool] = [:]
        /// 滑鼠停在哪一列（那一列的 × 才出來；同主視窗 tabRow）。
        @State private var hovered: String?
        /// 緊湊擺法直接畫玻璃（不經 LiquidGlassPanelCard）：一樣跟著主題換（同 LiquidGlassPanelCard 看 TatwoThemeStore）。
        @ObservedObject var themeStore = TatwoThemeStore.shared
        private var palette: TatwoThemePalette { TatwoActivePalette.current }
        private var fieldFill: Color { LiquidGlassTokens.browserFieldFill }
        private var folderFill: Color { LiquidGlassTokens.browserFolderFill }
        private var shadowColor: Color { LiquidGlassTokens.browserShadowColor }

        var body: some View {
            Group {
                if compact {
                    // 緊湊：同一片玻璃（liquidGlassPanelSurface，直角），內距 8。
                    content(inset: DMBrowserPhone.sidebarCompactPadding)
                        .padding(DMBrowserPhone.sidebarCompactPadding)
                        .frame(width: width)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .liquidGlassPanelSurface(cornerRadius: 0)
                        .background { if probe { DMFrameProbe(key: "side.mode.compact") } }
                } else {
                    // 平常：主視窗那一套（WorkspaceSidebarShell：玻璃、內距 18）。
                    WorkspaceSidebarShell(width: width) { content(inset: DMBrowserPhone.sidebarShellInset) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Browser 側欄")
        }

        /// 頂列那一排（空間名稱）＋頂列浮出來的那一段（空著）＋主視窗的 BrowserWorkSpaceSidebarList（同一份：列表自己捲、下載＋空間圓點＋＋
        /// 固定在最下面）。上面兩段固定在捲動區外面：捲動之後列也不會跑到頂列底下（GPT-6 審查 G2d #3）。
        private func content(inset: CGFloat) -> some View {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: max(0, DMBrowserPhone.sidebarListTop(topExtension: topInset) - inset))
                    .overlay(alignment: .topLeading) {
                        if topInset > 0 {
                            spaceTitle.offset(x: titleX - inset,
                                              y: DMBrowserPhone.sidebarTitleCenter - WorkspaceSidebarMetrics.spaceSwitcherHeight / 2 - inset)
                        }
                    }
                    .background { if probe { DMFrameProbe(key: "side.top") } }
                BrowserWorkSpaceSidebarList(store: store, guest: guest)
            }
        }

        /// 空間名稱從側欄左緣多遠開始：單欄＝頁面圓鈕右邊（同主視窗紅綠燈右邊）；內橫右欄＝對齊側欄的列。
        private var titleX: CGFloat {
            titleLeading ?? (compact ? DMBrowserPhone.sidebarCompactPadding : DMBrowserPhone.sidebarShellInset) + BrowserSidebarMetrics.rowHorizontalPadding
        }

        /// 空間名稱（同主視窗頂列那一個：粗 13、22 高、最寬 124）。只顯示——私訊框頂列的空白處是整個框的拖曳區（W184 G1），
        /// 切換空間用最下面那一排圓點（同主視窗那一排）。
        private var spaceTitle: some View {
            Text(store.selectedSpace.name)
                .font(.system(size: WorkspaceSidebarMetrics.spaceSwitcherFontSize, weight: .bold)).lineLimit(1)
                .padding(.horizontal, WorkspaceSidebarMetrics.spaceSwitcherHorizontalInset)
                .frame(width: max(0, min(WorkspaceSidebarMetrics.spaceSwitcherMenuWidth, width - titleX - BrowserSidebarMetrics.rowHorizontalPadding)),
                       height: WorkspaceSidebarMetrics.spaceSwitcherHeight, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isHeader)
                .background { if probe { DMFrameProbe(key: "side.title") } }
        }

        /// 借用主視窗那一份側欄：點了開在私訊框（一般分頁；絕不在 Pod／配對／授權分頁裡導航），只讀＋開啟＋切換空間。
        private var guest: BrowserSidebarGuest {
            let folder: @MainActor (BrowserWorkSpaceStore.Folder) -> BrowserFolderExternal = { folder in
                BrowserFolderExternal(expanded: isExpanded(folder), toggle: { expanded[folder.id] = !isExpanded(folder) })
            }
            let pinned: @MainActor (BrowserWorkSpaceStore.Tab) -> AnyView = { pin in AnyView(pinnedRow(pin)) }
            let select: @MainActor (BrowserWorkSpaceStore.Space) -> Void = { space in
                guard let id = space.registryID else { return }
                _ = spaces.select(registryID: id)
            }
            var mark: (@MainActor (String) -> AnyView)?
            if probe { mark = { key in AnyView(DMFrameProbe(key: "side." + key)) } }
            return BrowserSidebarGuest(favorites: favorites, bookmarks: bookmarkActions, folder: folder, pinnedRow: pinned,
                                       newTab: newTab, newTabIdentifier: "tatwo.dm.browser.newTab",
                                       newTabHelp: "新分頁（\(DMBrowserNewTabKey.display)）", tabs: AnyView(tabRows), selectSpace: select,
                                       spacesIdentifier: "tatwo.dm.browser.spaces", addSpaceOff: DMBrowserSidebar.addSpaceOff,
                                       interaction: interaction, compact: compact, mark: mark)
        }

        // MARK: 珍藏、書籤

        /// 珍藏那一排：點＝私訊框開這個珍藏自己的分頁（已經有＝切過去）；開著、在看照私訊框的分頁。
        private var favorites: BrowserFavoritesExternal {
            BrowserFavoritesExternal(open: { favorite in finish(DMBrowserShelf.open(favorite: favorite, in: browser)) },
                                     state: { favorite in
                                         let tab = browser.tabs.first { $0.origin == .favorite(favorite.id) }
                                         return (tab != nil, tab.map { $0.id == browser.activeID } ?? false)
                                     })
        }

        private func isExpanded(_ folder: BrowserWorkSpaceStore.Folder) -> Bool { expanded[folder.id] ?? folder.expanded }

        /// 書籤：點＝私訊框開這個書籤的分頁（http 改 https；別的協定不開）；減號＝關掉私訊框裡那一頁（沒完成的流程不會是書籤開的）。
        private var bookmarkActions: BrowserBookmarkExternal {
            BrowserBookmarkExternal(open: { bookmark in finish(DMBrowserShelf.open(bookmark: bookmark, in: browser)) },
                                    state: { bookmark in
                                        let tab = browser.tabs.first { $0.origin == .bookmark(bookmark.id) }
                                        let loading = tab.map { $0.loading && $0.problem == nil && !$0.pageClosed } ?? false
                                        return (tab != nil, tab.map { $0.id == browser.activeID } ?? false, loading)
                                    },
                                    close: { bookmark in
                                        if let tab = browser.tabs.first(where: { $0.origin == .bookmark(bookmark.id) }) { browser.userClose(tab.id) }
                                    })
        }

        // MARK: 分頁、Pinned 的列

        /// 私訊框自己的分頁：流程的分頁（授權頁、Pod、配對頁）、打網址開的一般分頁，還有來源已經不在側欄上的（見 DMBrowserSidebar.hasSidebarEntry）。
        private var listedTabs: [DMBrowserTabInfo] {
            let bookmarks = Set(store.folders.flatMap(\.bookmarks).map(\.id))
            let favorites = Set(store.registry.favorites.map(\.id))
            let pinned = Set(store.pinnedTabs.compactMap(\.registryID))
            return browser.tabs.filter { !DMBrowserSidebar.hasSidebarEntry($0, bookmarks: bookmarks, favorites: favorites, pinned: pinned) }
        }

        private var tabRows: some View {
            ForEach(Array(listedTabs.enumerated()), id: \.element.id) { index, tab in tabRow(tab, index: index) }
        }

        /// 一個分頁：點＝切過去；×＝關掉（流程分頁還沒完成時 × 會一起取消那個流程）。
        private func tabRow(_ tab: DMBrowserTabInfo, index: Int) -> some View {
            let title = tab.done ? "\(tab.title)・完成" : tab.title
            return row(probeKey: "tab.\(tab.id.uuidString)", closeKey: "close.\(tab.id.uuidString)", title: title, tabID: tab.id.uuidString,
                       host: tab.displayHost, favicon: nil, selected: tab.id == browser.activeID,
                       loading: tab.loading && tab.problem == nil && !tab.pageClosed && !tab.isBlank,
                       iconFill: index.isMultiple(of: 2) ? palette.brandAccent : folderFill,
                       select: { browser.select(tab.id) }, close: { browser.userClose(tab.id) }, closeLabel: "關閉 \(title)",
                       closeHelp: browser.closingCancels(tab.id) ? "關掉這個分頁（這一次還沒完成，會一起取消）" : "關掉這個分頁")
                .accessibilityIdentifier("tatwo.dm.browser.tabRow." + tab.purpose.rawValue)
        }

        /// 📌 Pinned 底下的一列（主視窗釘選的分頁）：點＝私訊框開它的網址（DMBrowserShelf.open(pinned:)；同一列再按＝切過去）；
        /// 開著、在看照私訊框的分頁；×（私訊框開著時才有）只關私訊框那一頁，主視窗釘選的分頁不動。
        private func pinnedRow(_ pin: BrowserWorkSpaceStore.Tab) -> some View {
            let key = pin.registryID?.uuidString ?? String(pin.id)
            let tab = pin.registryID.flatMap { id in browser.tabs.first { $0.origin == .pinned(id) } }
            var close: (() -> Void)?
            if let opened = tab { close = { browser.userClose(opened.id) } }
            let selected: Bool = tab.map { $0.id == browser.activeID } ?? false
            let loading: Bool = tab.map { $0.loading && $0.problem == nil && !$0.pageClosed } ?? false
            return row(probeKey: "pin.\(key)", closeKey: "pinclose.\(key)", title: pin.title, tabID: key, host: URL(string: pin.url)?.host,
                       favicon: pin.faviconPNG, selected: selected, loading: loading,
                       iconFill: pin.id.isMultiple(of: 2) ? palette.brandAccent : folderFill,
                       select: { finish(DMBrowserShelf.open(pinned: pin, in: browser)) }, close: close,
                       closeLabel: "關閉私訊框開的 \(pin.title)", closeHelp: "關掉私訊框開的這一頁（主視窗釘選的分頁不動）")
        }

        /// 一列（同主視窗 tabRow：BrowserTabRow＋hover 才出現的 ×、選中的底色與陰影）——私訊框的分頁與 Pinned 那幾列同一個樣子。
        /// 自測（量尺開著）：合成的滑鼠不觸發 hover，× 固定顯示好讓自測真的按到。
        private func row(probeKey: String, closeKey: String, title: String, tabID: String, host: String?, favicon: Data?, selected: Bool,
                         loading: Bool, iconFill: Color, select: @escaping () -> Void, close: (() -> Void)?, closeLabel: String,
                         closeHelp: String) -> some View {
            let closeVisible = close != nil && (hovered == probeKey || probe)
            return HStack(spacing: BrowserSidebarMetrics.childGap) {
                BrowserTabRow(variant: .workspace, title: title, tabID: tabID, host: host, favicon: favicon, selected: selected,
                              loading: loading, workspaceIconFill: iconFill, workspaceIconForeground: fieldFill, onSelect: select)
                    .background { if probe { DMFrameProbe(key: "side." + probeKey) } }
                Button { close?() } label: {
                    Image(systemName: "xmark").font(.system(size: BrowserSidebarMetrics.faviconFontSize))
                        .frame(width: BrowserSidebarMetrics.laneCardOuterInset, height: BrowserSidebarMetrics.searchButtonSize)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(closeLabel)
                .help(closeHelp)
                .opacity(closeVisible ? BrowserSidebarMetrics.visibleOpacity : BrowserSidebarMetrics.hiddenOpacity)
                .allowsHitTesting(closeVisible)
                .background { if probe { DMFrameProbe(key: "side." + closeKey) } }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .background(selected ? fieldFill : .clear, in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowSpacing))
            .shadow(color: shadowColor.opacity(selected ? BrowserSidebarMetrics.selectedRowShadowOpacity : BrowserSidebarMetrics.hiddenOpacity),
                    radius: BrowserSidebarMetrics.controlGap, x: BrowserSidebarMetrics.zero, y: BrowserSidebarMetrics.childGap)
            .onHover { inside in
                if inside { hovered = probeKey } else if hovered == probeKey { hovered = nil }
            }
        }
    }
}
