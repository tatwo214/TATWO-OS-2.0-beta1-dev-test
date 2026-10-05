import AppKit
import SwiftUI

// W183 R8b：私訊框第三顆圓鈕 Browser 的畫面＝手機式瀏覽器；停靠框、浮動框、內橫的右欄都用這一個。
// W183 R8b 審查（GPT-6、Claude）：網址只照實際載入的 http／https；沒有、空白頁、別的協定＝「尚未確認來源」（不給鎖頭、不拿該在的網域頂替）；
// 頁面關掉的分頁（完成、確認中、Pod 收起來）＝原生卡片（完成／一句話＋「關掉這個分頁」）；分頁的 × 只在真的會取消流程時才說「會一起取消」。
// W184 D（對照稿 A-Proto、Outer-Tabs；數值在 DMBrowserPhone）：頁面框（外距 上 4、左右下 12，圓角 28、0.5 分隔色邊）；
// 按了［連線］之後的卡片浮在頁上（不把頁面擠短）；分頁總覽＝兩欄卡片；授權頁在畫面上＝頁面頂端「這一頁不給截圖」小標；
// 浮在網頁上的東西登記 chrome 命中區（BrowserChromeHitLayer），頁面容器讓位（同主視窗 Browser）。
// W184 G2（使用者 09-29：書籤、珍藏、switch 收進私訊框的 Browser）：書籤、珍藏、打網址一律開新的一般分頁（不在 Pod／配對／授權分頁導航）；
// 一般分頁不是授權頁。規則見 DMBrowser、DMBrowserSpaces。
// W184 G2c（09-29 17:35：新分頁＋⌘⌥T；17:50：左列改成滑鼠指到才出）：新分頁（側欄＋、分頁總覽＋、⌘⌥T）＝空白的一般分頁；
// 連線卡片左右 12 不動，側欄停在卡片上面 8（卡片的按鈕永遠不被蓋）；流程把授權頁、配對頁叫到前面＝收起輸入、放掉鍵盤；Esc＝只收輸入。
// W184 G2d（使用者 09-30 02:4x 實測 .031：「duo的browser左列欄修到頂天 上方這些功能跟我們設計的 browser space設計不同」
// 「應該是滑鼠指到展開玻璃」「還沒有分頁的搜尋狀態也要一樣」「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：
// - 頂列＝主視窗 Browser space 那一排（DMBrowserToolbar：側欄鈕、上一頁、下一頁、重新載入、網址｜⋯、翻譯、擴充、註解），
//   平常不在，滑鼠到 Browser 區頂端才浮出玻璃（同主視窗 W112 的頂列）；橫跨整個 Browser 區，畫在側欄上面。
// - 側欄＝主視窗 Browser space 的側欄那一份（DMBrowserSidebar：WorkspaceSidebarShell 玻璃、頂天，裡面是 BrowserWorkSpaceSidebarList 本身），
//   滑鼠指到左緣 18 才滑出、移開 0.4 秒收（同主視窗浮出側欄）；左緣不畫把手。頂列最左那顆（BrowserSidebarControls）＝固定／收合：
//   固定著＝頁面讓出側欄那一欄（同主視窗）。
// - 沒有分頁、空白的新分頁＝主視窗那個置中的搜尋框（BrowserStartSearch：Search、＋、送出；右鍵＝同一個搜尋引擎選單）；
//   打字送出＝開在那一個空白分頁上（沒有分頁＝開新分頁）。
// - 上兩輪的規則照舊：新分頁與 ⌘⌥T、填進開始打字的那一個空白分頁、草稿不跟到別頁、⌥⌘T 擋直達鍵、連線卡片不被蓋、小框可操作；
//   安全規則照舊（見 DMBrowser、DMBrowserChrome）。

/// W184 G2d：置中搜尋框的焦點（BrowserStartSearch 用 FocusState<Field?>）。
enum DMBrowserSearchField: Hashable {
    case search
}

/// Browser 的整塊（框頂圓鈕列以下）。
struct DMBrowserPane: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject private var browser: DMBrowser
    @ObservedObject private var flow: HandsConnectFlow
    @ObservedObject private var connect: HandsConnectPresenter
    /// W184 G2：書籤、珍藏、空間（主視窗 Browser space 的那一份）；不在這一層觀察（側欄自己觀察，主視窗的分頁一動不用整塊重畫）。
    private let spaces: DMBrowserSpaces
    @StateObject private var reveal = DMBrowserBarReveal()
    /// 這一個 Browser 畫面自己的頁面容器（碼只畫在頁面真的放在自己框裡的那一個畫面）。
    @State private var slot = DMBrowserPageSlot()
    /// W184 G2d：頂列網址欄的字（主視窗那條導覽列拿著編輯）、焦點、正在編輯、要它打開編輯。
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var addressEditing = false
    @State private var expansionRequest = false
    /// W184 G2d：置中搜尋框的字（草稿）與焦點。
    @State private var draft = ""
    @FocusState private var searchFocus: DMBrowserSearchField?
    /// W184 G2c 第二輪（GPT-6 #3）：這一次打的字從哪一頁開始——送出只開在那一頁（它還是空白的一般頁、還是目前那一頁）；
    /// 換頁、關頁＝收起輸入、草稿清掉（不跟到別頁）。
    @State private var editTarget: UUID?
    /// W184 G2：開不了的那一句話（頁面頂上；分頁滿了多一顆「所有分頁」）。
    @State private var refusal: DMBrowserBrowseRefusal?
    /// 要把游標放進搜尋框、打開網址欄（新分頁、自測一打開就在打字）：框拿到鍵盤的下一輪才做。
    @State private var pendingFocus: DMBrowserPanel?
    /// W184 G2c：連線卡片的頂端（Browser 區座標）；側欄停在它上面 8。
    @State private var cardTop: CGFloat?
    /// W184 G2c 第二輪（GPT-6 #4）：Browser 區多高（框小的時候手動連線卡的步驟縮短，側欄還留 DMBrowserPhone.sidebarMinHeight）。
    @State private var paneHeight: CGFloat = 0
    @Environment(\.dmBrowserChromeShown) private var forced
    @Environment(\.dmFrameProbes) private var probe
    /// W184 G2d：Browser 區上面私訊框頂列的高度（側欄往上伸到框頂；頁面、頂列、卡片照舊從 Browser 區開始）。
    @Environment(\.dmBrowserTopExtension) private var topExtension
    /// W184 G2d：框的形態（側欄的空間名稱擺在哪：單欄＝頁面圓鈕右邊；內橫右欄＝對齊側欄的列）。
    @Environment(\.globalDMForm) private var form
    /// W184 G2d（GPT-6 審查 G2d #5）：置中搜尋框右鍵的搜尋引擎（主視窗那一個 BrowserSearchEngineMenu；存進同一個 Browser 設定）。
    /// 搜尋框出現時才讀一次設定（不在每次畫面重建時讀檔）。
    @State private var engine: BrowserSearchEngine = .google
    @State private var engineError: String?

    /// browser、flow、connect、spaces 只給自測換（正式＝這台的 Browser、連線流程、私訊框的連線卡片、主視窗的 Browser space）；
    /// panel＝自測畫面證據一打開就在打字（address＝頂列網址欄；沒有網頁可編＝置中搜尋框；正式＝沒有）。
    init(store: GlobalDMStore, browser: DMBrowser? = nil, flow: HandsConnectFlow? = nil, connect: HandsConnectPresenter? = nil,
         spaces: DMBrowserSpaces? = nil, panel: DMBrowserPanel? = nil) {
        let shown = browser ?? .shared
        _store = ObservedObject(wrappedValue: store)
        _browser = ObservedObject(wrappedValue: shown)
        _flow = ObservedObject(wrappedValue: flow ?? .shared)
        _connect = ObservedObject(wrappedValue: connect ?? .shared)
        self.spaces = spaces ?? .shared
        _pendingFocus = State(initialValue: panel)
        _editTarget = State(initialValue: panel == nil ? nil : shown.activeID)
    }

    /// 現在開著的輸入：頂列網址欄在打字＝address；置中搜尋框拿著游標、或裡面有還沒送出的字（輸入法、別的地方暫時拿走游標）＝search。
    private var panel: DMBrowserPanel? {
        if addressEditing { return .address }
        if searchFocus != nil || (!draft.isEmpty && showsStartSearch) { return .search }
        return nil
    }

    /// 開著 VoiceOver：側欄、頂列一直在（不用滑鼠也找得到）。
    private var voiceOver: Bool { NSWorkspace.shared.isVoiceOverEnabled }

    /// 側欄在畫面上：固定著、滑鼠在左緣那一帶、自測畫面證據固定展開、VoiceOver。
    private var sidebarShown: Bool { forced.contains(.sidebar) || browser.sidebarPinned || reveal.isRevealed || voiceOver }

    /// 頂列在畫面上：滑鼠在頂端那一帶（網址欄在打字＝留著）、自測畫面證據固定展開、VoiceOver。
    private var toolbarShown: Bool {
        forced.contains(.toolbar) || reveal.toolbarRevealed || voiceOver || addressEditing || pendingFocus == .address
    }

    /// 分頁總覽開著（有分頁才有）：頁面、側欄、頂列、連線卡片都先收起來。
    private var showingTabList: Bool { browser.isShowingTabList && !browser.tabs.isEmpty }

    /// 沒有分頁、目前是空白的新分頁＝置中的搜尋框（同主視窗 Browser space 的起始頁）。
    private var showsStartSearch: Bool { browser.tabs.isEmpty || browser.activeTab?.isBlank == true }

    var body: some View {
        GeometryReader { proxy in
            layout(proxy.size)
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(DMBrowserCardTopKey.self) { top in cardTop = top }
        .background(GeometryReader { proxy in Color.clear.preference(key: DMBrowserPaneHeightKey.self, value: proxy.size.height) })
        .onPreferenceChange(DMBrowserPaneHeightKey.self) { height in paneHeight = height }
        .background(DMBrowserBarRevealHost(reveal: reveal))
        .background(DMBrowserPanelEscapeAnchor(panel: panel, close: closePanel))   // Esc 只收輸入（錨一直在，收起的當下就拿掉）
        .background(DMBrowserKeyTaker(active: panel != nil || pendingFocus != nil))   // 打字要進得了輸入框：框拿鍵盤
        .onChange(of: showingTabList) { _, list in if list { closePanel() } }
        .onChange(of: browser.flowRaised) { _, _ in closePanel() }   // W184 G2 修正（查證 #4）：流程把它的分頁叫到前面＝收起輸入、放掉鍵盤
        // W184 G2c 第二輪（GPT-6 #3）：打字的時候換了頁（點側欄別的分頁、流程叫到前面）或開始打字的那一頁關掉了＝收起輸入、草稿清掉，
        // 不跟到別頁（送出時 DMBrowser.openBrowse 也再驗一次是不是同一個空白頁）。
        .onChange(of: browser.activeID) { _, id in
            if id != editTarget, panel != nil || !draft.isEmpty || editTarget != nil { closePanel() }
        }
        .onChange(of: browser.tabs.map(\.id)) { _, ids in
            if let editTarget, !ids.contains(editTarget) { closePanel() }
        }
        // W184 G2c：要了新分頁（側欄＋、搜尋框的＋、⌘⌥T）＝空白分頁上置中的搜尋框拿到游標；開不了＝頁面頂上那一句話。
        .onChange(of: browser.newTabAsk) { _, ask in
            guard let ask else { return }
            closePanel()
            refusal = ask.refusal
            guard ask.refusal == nil else { return }
            editTarget = browser.activeID   // 這一次打的字只開在這一頁（新的空白分頁）
            pendingFocus = .search
            applyPendingFocus()
        }
        .onChange(of: searchFocus) { _, field in
            if field != nil, editTarget == nil { editTarget = browser.activeID }   // 在搜尋框開始打字＝記下這一頁（沒有分頁＝nil）
            if field != nil, pendingFocus == .search { pendingFocus = nil }
        }
        .onChange(of: addressEditing) { _, editing in
            guard editing else { return }
            if pendingFocus == .address { pendingFocus = nil }
            editTarget = browser.activeID
            refusal = nil
        }
        // 網址欄在打字＝頂列照樣展開（指標移開也不收）；打完的當下照滑鼠位置重算。在打字（任一個）＝頁面開好、換分頁都不搶鍵盤。
        .onChange(of: panel, initial: true) { _, open in
            reveal.hold(open == .address)
            browser.keepsKeyboard = open != nil
        }
        .onChange(of: browser.sidebarPinned, initial: true) { _, pinned in reveal.sidebarPinned = pinned }
        .onAppear { applyPendingFocus() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.browser")
    }

    private static let space = "tatwo.dm.browser.pane"

    /// 疊起來（由下到上）：頁面那一欄（側欄固定著＝讓出側欄那一欄）→ 連線卡片 → 側欄 → 頂列。
    private func layout(_ size: CGSize) -> some View {
        let width = DMBrowserPhone.sidebarWidth(for: size.width)
        let pushed: CGFloat = browser.sidebarPinned && !showingTabList ? width : 0
        let card = connectCard
        let toolbar = toolbarShown && !showingTabList
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: pushed)
                Group {
                    if showingTabList {
                        DMBrowserTabList(browser: browser)
                    } else {
                        // W183 R12（主導 1：「卡片永遠不蓋網頁」）：有連線卡片時網頁的下緣停在卡片上緣（讓出那一段）。
                        pageFrame(toolbar: toolbar, yield: card == nil ? nil : cardTop.map { max(0, size.height - $0 + DMBrowserPhone.pageSide) })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: size.width, height: size.height)
            if let card { cardLayer(card, size: size) }
            if !showingTabList {
                sidebarLayer(size: size, width: width, cardTop: card == nil ? nil : cardTop)
            }
            if toolbar {
                toolbarLayer(width: size.width)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeOut(duration: DMBrowserPhone.toolbarFade), value: toolbar)
        .animation(.easeOut(duration: DMBrowserPhone.fadeDuration), value: card != nil)
        .onAppear { reveal.sidebarWidth = width; reveal.sidebarAbove = topExtension }
        .onChange(of: width) { _, next in reveal.sidebarWidth = next }
        .onChange(of: topExtension) { _, next in reveal.sidebarAbove = next }
    }

    // MARK: 頁面

    /// 按了［連線］之後的卡片浮在 ChatGPT 分頁（Pod、配對頁、登入視窗）的頁上；Cloudflare 授權頁、使用者自己開的一般網頁上不浮。
    private var showsConnectCard: Bool {
        // W183 R12（主導 1）：兩頁的時候卡片在左頁（這裡整頁是網頁，不放卡片）；單欄的時候卡片擺在網頁下面（網頁讓出那一段，見 pageFrame）。
        guard connect.cardWithBrowser, !showingTabList, let tab = browser.activeTab else { return false }
        return tab.purpose.isConnect && connect.card != nil
    }

    private var connectCard: HandsConnectCard? { showsConnectCard ? connect.card : nil }

    private var pageShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DMBrowserPhone.pageRadius, style: .continuous)
    }

    /// yield＝頁面底下讓出多少（有連線卡片：卡片上緣以下；nil＝照舊）。
    private func pageFrame(toolbar: Bool, yield: CGFloat? = nil) -> some View {
        ZStack(alignment: .top) {
            if showsStartSearch {
                // 空白的新分頁沒有頁面：頁面容器不掛（原生容器會吃掉搜尋框的點擊）。
                startSearch
            } else {
                DMBrowserPageSurface(browser: browser, slot: slot)
                if let tab = browser.activeTab, tab.pageClosed { closedView(tab) }
                if let problem = browser.activeTab?.problem { problemView(problem) }
            }
            badges
                .padding(.top, DMBrowserPhone.badgeTop + (toolbar ? DMBrowserPhone.toolbarHeight - DMBrowserPhone.pageTop : 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pageShape.fill(Color.primary.opacity(0.035)))
        .clipShape(pageShape)
        .overlay(pageShape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: DMPhone.hairline))
        .background { if probe { DMFrameProbe(key: "page.frame") } }
        .padding(.top, DMBrowserPhone.pageTop)
        .padding(.horizontal, DMBrowserPhone.pageSide)
        .padding(.bottom, max(DMBrowserPhone.pageBottom, yield ?? 0))
    }

    /// 頁面頂上置中的一疊：「這一頁不給截圖」、網域對不上／不是 https 的警告、網頁開的新視窗沒開成、開不了的那一句話。
    private var badges: some View {
        // W184 D：跟 DMBrowser 不給擷取同一條規則（這裡畫出來＝Browser 在畫面上）。
        let shielded = !browser.tabs.isEmpty
            && DMBrowser.capturesBlocked(activeSensitive: browser.activeTab?.isSensitive == true, tabList: browser.isShowingTabList, onScreen: true)
        return VStack(spacing: DMBrowserPhone.badgeSpacing) {
            if shielded {
                DMBrowserShieldBadge()
            }
            if let tab = browser.activeTab, let caution = DMBrowserCautionBadge.text(tab) {
                DMBrowserCautionBadge(text: caution)   // W184 G2d：頂列平常不在，網域對不上、不是 https 的警告一直看得到
            }
            if let notice = browser.notice {   // W184 G2 第三輪：網頁開的新視窗沒開成＝一句話（點一下收起、過一會兒自己收）
                DMBrowserNoticeBadge(text: notice) { browser.clearNotice() }
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: DMBrowserPhone.noticeNanoseconds)
                        if !Task.isCancelled, browser.notice == notice { browser.clearNotice() }
                    }
            }
            if let refusal {
                DMBrowserRailNote(refusal: refusal) { showAllTabs() }
                    .padding(.horizontal, DMBrowserPhone.badgePadding)
                    .padding(.vertical, DMBrowserPhone.badgeSpacing)
                    .background(Capsule().fill(.regularMaterial))
                    .background(BrowserChromeHitLayer())   // 浮在網頁上：這一塊的點擊給它（「所有分頁」）
                    .background { if probe { DMFrameProbe(key: "note") } }
                    .padding(.horizontal, DMBrowserPhone.cardInset)
            }
        }
    }

    /// W184 G2d：主視窗 Browser space 那個置中的搜尋框（Search、＋、送出）。打字送出＝開在開始打字的那一個空白分頁上（沒有分頁＝開新分頁）；
    /// ＋＝新分頁（同側欄的新分頁、⌘⌥T）；打字時上面浮一排建議（已開的分頁、用搜尋引擎搜尋），同主視窗。
    private var startSearch: some View {
        BrowserStartSearch(query: $draft, focus: $searchFocus, field: .search, canAddTab: true,
                           suggestions: suggestions(for: draft), notice: engineError ?? "", identifier: "tatwo.dm.browser.search",
                           onSubmit: submitSearch, onAddTab: { _ = browser.newTab() }, onSuggestion: pick) {
            BrowserSearchEngineMenu(engine: engine) { chooseEngine($0) }
        }
            .onAppear { engine = BrowserSettings.load().searchEngine }
            .background { if probe { DMFrameProbe(key: "search.panel") } }
    }

    /// 同主視窗：選了＝存進 Browser 設定（打字搜尋照它）；存不進去＝搜尋框下面一句話。
    private func chooseEngine(_ next: BrowserSearchEngine) {
        engineError = BrowserSearchEngineMenu.save(next)
        if engineError == nil { engine = next }
    }

    /// 同主視窗 BrowserWorkSpaceStore.suggestions：第一個對得上的已開分頁＋「搜尋『…』」，最多三列。
    private func suggestions(for text: String) -> [BrowserWorkSpaceStore.Suggestion] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var result: [BrowserWorkSpaceStore.Suggestion] = []
        if let tab = browser.tabs.first(where: { !$0.isBlank && ($0.title.localizedCaseInsensitiveContains(query) || $0.displayHost.localizedCaseInsensitiveContains(query)) }) {
            result.append(BrowserWorkSpaceStore.Suggestion(id: "dmtab-" + tab.id.uuidString, section: "已開分頁", title: tab.title, tabID: nil))
        }
        result.append(BrowserWorkSpaceStore.Suggestion(id: "search", section: "搜尋", title: "搜尋「\(query)」", tabID: nil))
        return Array(result.prefix(3))
    }

    private func pick(_ suggestion: BrowserWorkSpaceStore.Suggestion) {
        if suggestion.id.hasPrefix("dmtab-"), let id = UUID(uuidString: String(suggestion.id.dropFirst(6))) {
            closePanel()
            browser.select(id)
        } else {
            submitSearch()
        }
    }

    /// W183 R8b 審查：頁面已經關掉的分頁（完成、確認中、Pod 這一步不用看）：原生卡片，不是網頁。W184 D：一句話＋一顆鈕。
    private func closedView(_ tab: DMBrowserTabInfo) -> some View {
        VStack(spacing: 10) {
            if tab.done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.loopsPositive)
                Text("\(tab.title)・完成").font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                Text("頁面已經關掉；這個分頁留著讓你看結果，不需要就關掉。")
                    .font(.system(size: DMPhone.TextSize.secondary))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
                Text(tab.note ?? "頁面已收起")
                    .font(.system(size: DMPhone.TextSize.secondary))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GlobalDMChipButton(title: "關掉這個分頁") { browser.userClose(tab.id) }
                .help(browser.closingCancels(tab.id) ? "關掉這個分頁（這一次還沒完成，會一起取消）" : "關掉這個分頁")
                .accessibilityIdentifier("tatwo.dm.browser.closed.close")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .background(BrowserChromeHitLayer())   // W184 G2d：蓋住整個頁面框：點擊給這張卡（頁面容器讓位）
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(tab.done ? "tatwo.dm.browser.done" : "tatwo.dm.browser.waiting")
    }

    private func problemView(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: DMPhone.TextSize.secondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if browser.canOpenElsewhere {
                GlobalDMChipButton(title: "改在 OS 瀏覽器開") { browser.openElsewhere() }
                    .accessibilityIdentifier("tatwo.dm.browser.elsewhere")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .background(BrowserChromeHitLayer())   // W184 G2d：蓋住整個頁面框：點擊給這張卡（頁面容器讓位）
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.browser.problem")
    }

    // MARK: 連線卡片、側欄、頂列

    private func cardLayer(_ card: HandsConnectCard, size: CGSize) -> some View {
        // 碼要不要顯示在這裡算（Browser 的頁面放好、換了分頁，shownSurface 一變這裡就重算；不用等流程下一次核對）。
        // W184 D（GPT-6 審查 #1 跨視窗換手）：兩個 Browser 畫面同時在（停靠框↔浮動框換手、停靠框只 orderOut 沒拆）時，
        // 只有頁面真的放在自己框裡的那一個畫碼；舊的那一個把碼收掉（它的視窗在碼不見、再多一段 linger 之後還原）。
        let reveals = connect.revealsCode(card) && browser.holdsPage(slot.container)
        return HandsConnectFloatingCard(card: card, flow: flow, presenter: connect, revealsCode: reveals)
            .environment(\.dmCardBodyLimit, DMBrowserPhone.cardBodyLimit(paneHeight: paneHeight))   // W184 G2c 第二輪：小框讓側欄留得下
            .background { if probe { DMFrameProbe(key: "card.frame") } }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: DMBrowserCardTopKey.self, value: proxy.frame(in: .named(Self.space)).minY)
            })
            .padding(.horizontal, DMBrowserPhone.cardInset)
            .padding(.bottom, DMBrowserPhone.cardBottom)
            .frame(width: size.width, height: size.height, alignment: .bottom)
            // W184 D（GPT-6 審查 #1）：畫著配對碼的卡片退場不播動畫（分頁總覽、取消、收起來：同一個畫面就拿掉）。
            .transition(dmCardTransition(showingSecret: reveals && card.carriesCode))
    }

    /// 側欄：頂天、貼左緣、寬照框寬（最寬 250）；有連線卡片時停在卡片上面 8（卡片的按鈕不會被蓋住）。從左 8 滑進來、淡入（同主視窗浮出側欄）。
    /// 側欄的點擊給側欄（滑出、固定著才登記 chrome 命中區，網頁讓位）；畫出來、點得到的只在側欄裡。
    /// W184 G2d（使用者 09-30：「duo的browser左列欄修到頂天」）：側欄從框頂開始（Browser 區上面私訊框頂列那一段也是側欄的玻璃，
    /// 照框的圓角裁切；頂列畫在它上面一層，頁面圓鈕照舊按得到）。主導 09-30（「空間名稱擺的位置要跟主視窗一樣」）：空間名稱在頂列那一排、
    /// 頁面圓鈕右邊（主視窗：紅綠燈右邊）；珍藏、Pinned、分頁從 Browser 區的頂列下面開始（不在圓鈕、頂列底下）。
    /// 側欄上開著下載清單＝側欄留著（interaction → reveal.holdSidebar）。
    private func sidebarLayer(size: CGSize, width: CGFloat, cardTop: CGFloat?) -> some View {
        let shown = sidebarShown
        let height = cardTop.map { max(0, $0 - DMBrowserPhone.sidebarGap) } ?? size.height
        return DMBrowserSidebar(browser: browser, spaces: spaces, width: width, height: height, topInset: topExtension,
                                titleLeading: DMBrowserPhone.sidebarTitleLeading(form: form), probe: probe, finish: finish,
                                newTab: { _ = browser.newTab() }, interaction: { reveal.holdSidebar($0) })
            .frame(width: width, height: height + topExtension, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .background(BrowserChromeHitLayer(isActive: shown))
            .background { if probe { DMFrameProbe(key: "side.panel") } }
            .padding(.top, -topExtension)   // 往上伸到框頂（排版上移，量尺、命中區跟著）
            .offset(x: shown ? 0 : -DMBrowserPhone.slide)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(.easeInOut(duration: shown ? DMBrowserPhone.sidebarOpenDuration : DMBrowserPhone.sidebarCloseDuration), value: shown)
            .accessibilityHidden(!shown)
            .accessibilityIdentifier("tatwo.dm.browser.sidebar")
    }

    /// 頂列：橫跨整個 Browser 區、畫在側欄上面；玻璃底往下多畫一段漸淡（同主視窗 BrowserFloatingToolbarBackdrop）。
    private func toolbarLayer(width: CGFloat) -> some View {
        DMBrowserToolbar(browser: browser, address: $address, focused: $addressFocused, expansionRequest: $expansionRequest,
                         editing: $addressEditing, width: width, probe: probe, onSubmit: submitAddress, showTabs: showAllTabs,
                         newTab: { _ = browser.newTab() })
            .frame(width: width, alignment: .leading)
            .background { BrowserFloatingToolbarBackdrop() }
            .zIndex(BrowserOmniboxMetrics.chromeZIndex)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Browser 頂列")
            .accessibilityIdentifier("tatwo.dm.browser.toolbar")
    }

    // MARK: 打字、開不了的那一句話

    /// 新分頁、自測一打開就在打字：下一輪（框拿到鍵盤之後）才把游標放進去。有網頁可編＋要網址欄＝打開頂列的網址欄；其他＝置中的搜尋框。
    private func applyPendingFocus() {
        guard let pending = pendingFocus else { return }
        DispatchQueue.main.async {
            guard pendingFocus == pending else { return }
            if pending == .address, DMBrowserToolbar.showsAddress(browser.activeTab) {
                expansionRequest = true
            } else if showsStartSearch {
                searchFocus = .search
            } else {
                pendingFocus = nil
            }
        }
    }

    private func closePanel() {
        refusal = nil
        draft = ""
        editTarget = nil
        pendingFocus = nil
        searchFocus = nil
        if addressEditing || addressFocused {
            address = DMBrowserToolbar.state(browser.activeTab).urlString ?? ""
            addressFocused = false   // 主視窗那條導覽列：失焦＝收起網址欄、字還原
        }
        browser.keepsKeyboard = false
    }

    /// 打的字：網址（沒寫協定＝https、http 改 https）或搜尋（Browser 設定的搜尋引擎）；開在開始打字的那一個空白分頁上
    /// （W184 G2c 第二輪：送出時它得還是那一個空白的一般頁、還是目前那一頁），不然開新分頁。流程分頁的網址一律不改。
    private func open(_ text: String) {
        let engine = BrowserGeneralSettings.load().searchEngine
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let url = DMBrowserBrowseInput.resolve(text, engine: engine) else {
            refusal = .notSecure
            return
        }
        browser.keepsKeyboard = false
        finish(browser.openBrowse(url: url, title: DMBrowserBrowseInput.title(for: text, url: url, engine: engine), origin: .typed,
                                  typedInto: editTarget))
    }

    private func submitSearch() { open(draft) }

    private func submitAddress() { open(address) }

    /// 開了（或切過去了）＝收起輸入；開不了＝留著、說一句話。
    private func finish(_ result: DMBrowserBrowseResult) {
        switch result {
        case .opened, .switched, .reloaded:
            closePanel()
        case .refused(let reason):
            refusal = reason
        }
    }

    private func showAllTabs() {
        closePanel()
        if !browser.tabs.isEmpty { browser.isShowingTabList = true }
    }
}

/// W184 G2c：連線卡片的頂端（Browser 區座標）：側欄停在它上面。
struct DMBrowserCardTopKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = min(value ?? next, next) }
    }
}

/// W184 G2c 第二輪：Browser 區的高度（手動連線卡的步驟那一段照它縮）。
struct DMBrowserPaneHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// W184 G2d：網域對不上、不是 https 的警告（以前寫在網址 pill 上；頂列平常不在，改成頁面頂上一直看得到的小標）。不接點擊。
struct DMBrowserCautionBadge: View {
    let text: String

    /// 這個分頁要不要警告（來源確認了才比：網域對不上＝「<網域>・不是 <該在的網域>」；不是 https＝「<網域>・連線不安全」）。
    static func text(_ tab: DMBrowserTabInfo) -> String? {
        guard tab.sourceKnown else { return nil }
        if tab.hostMismatch, let expected = tab.expectedHost { return "\(tab.displayHost)・不是 \(expected)" }
        if tab.isInsecure { return "\(tab.displayHost)・連線不安全" }
        return nil
    }

    var body: some View {
        HStack(spacing: DMBrowserPhone.badgeSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
            Text(text)
                .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, DMBrowserPhone.badgePadding)
        .frame(height: DMBrowserPhone.badgeHeight)
        .background(Capsule().fill(LiquidGlassTokens.loopsCaution))
        .padding(.horizontal, DMBrowserPhone.cardInset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("tatwo.dm.browser.caution")
    }
}

/// W184 G2d：打字的時候讓私訊框拿鍵盤（停靠框平常只在需要時才拿，點頂列、側欄的鈕不會自己拿）：網址欄、搜尋框的字才打得進去。
/// 只對能拿鍵盤、看得到的框；不把整個 App 叫到前景（同 DMBrowserPageContainer 點進網頁時的做法）。
struct DMBrowserKeyTaker: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> KeyTaker {
        let view = KeyTaker(frame: .zero)
        view.active = active
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: KeyTaker, context: Context) {
        view.active = active
    }

    final class KeyTaker: NSView {
        var active = false {
            didSet { if active && !oldValue { takeKey() } }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if active { takeKey() }
        }

        /// 不在 SwiftUI 更新畫面的當下動視窗：下一輪再拿鍵盤。
        private func takeKey() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, let window = self.window, window.isVisible, window.canBecomeKey, !window.isKeyWindow else { return }
                window.makeKey()
            }
        }
    }
}

/// 網址 pill：鎖頭＋網域（跟著實際載入的頁面）；不是 https 或網域對不上＝橘色警告＋「不是 <該在的網域>」。
/// W183 R8b 審查（GPT-6）：沒有實際載入的 http／https（還沒載入、空白頁、別的協定）＝「尚未確認來源」、不給鎖頭；頁面關了＝完成／確認中。
/// W184 D：操作列中間那一顆（44 高、圓角 22）：第一行鎖頭＋網域 15 半粗、第二行「這台：<名稱>」11 次要色。
/// W184 G2d：私訊框的 Browser 改用主視窗 Browser space 那條導覽列（DMBrowserToolbar），這一顆不再畫；鎖頭、網域的判斷（symbol、label）
/// 留著給自測與授權流程的核對用（HandsUIAcceptance、DMBrowserAcceptance），網址那一格照同一條規則寫（DMBrowserToolbar.label）。
struct DMBrowserAddressPill: View {
    let tab: DMBrowserTabInfo?

    var body: some View {
        let host = tab?.displayHost ?? ""
        let known = tab?.sourceKnown ?? false
        let mismatch = tab?.hostMismatch ?? false
        let insecure = tab?.isInsecure ?? false
        let warn = mismatch || insecure
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                if let tab {
                    Image(systemName: Self.symbol(tab, warn: warn))
                        .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
                        .foregroundStyle(warn ? LiquidGlassTokens.loopsCaution : known ? Color.primary.opacity(0.8) : Color.secondary)
                }
                Text(known ? host : tab?.sourceText ?? "沒有分頁")
                    .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                    .foregroundStyle(known ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if mismatch, let expected = tab?.expectedHost {
                    Text("不是 \(expected)")
                        .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
                        .foregroundStyle(LiquidGlassTokens.loopsCaution)
                        .lineLimit(1)
                        .fixedSize()
                } else if insecure {
                    Text("連線不安全")
                        .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
                        .foregroundStyle(LiquidGlassTokens.loopsCaution)
                        .lineLimit(1)
                        .fixedSize()
                }
                if tab?.loading == true, tab?.problem == nil {
                    ProgressView().controlSize(.mini).accessibilityLabel("載入中")
                }
            }
            .help(known ? host : tab?.sourceText ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(known ? Self.label(host: host, mismatch: mismatch ? tab?.expectedHost : nil, insecure: insecure) : tab?.sourceText ?? "沒有分頁")
            .accessibilityIdentifier("tatwo.dm.browser.addressHost")   // tatwo.dm.browser.address＝左列上點了打網址的那一顆
            Text("這台：\(DMBrowser.deviceName)")
                .font(.system(size: DMPhone.TextSize.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("這個 Browser 在這台：\(DMBrowser.deviceName)")
                .accessibilityLabel("這台：\(DMBrowser.deviceName)")
                .accessibilityIdentifier("tatwo.dm.browser.device")
        }
        .padding(.horizontal, DMBrowserPhone.pillPadding)
        .frame(maxWidth: .infinity, minHeight: DMBrowserPhone.pillHeight, maxHeight: DMBrowserPhone.pillHeight)
        .background(Capsule().fill(warn ? LiquidGlassTokens.loopsCaution.opacity(0.14) : Color.primary.opacity(0.06)))
        .overlay {
            if warn {
                Capsule().strokeBorder(LiquidGlassTokens.loopsCaution.opacity(0.6))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 鎖頭只給實際載入的 https、網域對得上；其他＝警告、問號（尚未確認來源）、打勾（完成）、暫停（頁面收起來）。
    static func symbol(_ tab: DMBrowserTabInfo, warn: Bool) -> String {
        if tab.isBlank { return "magnifyingglass" }   // W184 G2c：空白的新分頁
        if tab.pageClosed { return tab.done ? "checkmark.circle" : "pause.circle" }
        if !tab.sourceKnown { return "questionmark.circle" }
        return warn ? "exclamationmark.triangle.fill" : "lock.fill"
    }

    static func label(host: String, mismatch: String?, insecure: Bool) -> String {
        guard !host.isEmpty else { return "沒有分頁" }
        if let mismatch { return "網域 \(host)（不是 \(mismatch)）" }
        return insecure ? "網域 \(host)（連線不安全）" : "網域 \(host)"
    }
}

/// 分頁總覽（W184 D：對照稿 Outer-Tabs）：一行「N 個分頁・…」、兩欄卡片（名稱、來源、狀態、右上關掉）、底部玻璃膠囊裡的「完成」。
/// 點卡片＝換到那一頁。縮圖區一律中性色塊（不拍敏感頁的縮圖）。
struct DMBrowserTabList: View {
    @ObservedObject var browser: DMBrowser
    @Environment(\.dmFrameProbes) private var probes

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DMBrowserPhone.listSpacing) {
                    Text("\(browser.tabs.count) 個分頁・授權頁與配對頁都會開在這裡，不會自己消失")
                        .font(.system(size: DMPhone.TextSize.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 4)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: DMBrowserPhone.gridSpacing), GridItem(.flexible(), spacing: DMBrowserPhone.gridSpacing)],
                              spacing: DMBrowserPhone.gridSpacing) {
                        ForEach(browser.tabs) { tab in card(tab) }
                        newTabCard   // W184 G2c：最後一格「＋」＝新分頁
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("分頁")
                    .accessibilityIdentifier("tatwo.dm.browser.tabStrip")
                }
                .padding(.top, DMBrowserPhone.listTop)
                .padding(.horizontal, DMBrowserPhone.listSide)
                .padding(.bottom, DMBrowserPhone.listBottom)
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                DMPhoneCapsuleButton(title: "完成", prominent: true) { browser.isShowingTabList = false }
                    .help("收起分頁總覽")
                    .accessibilityIdentifier("tatwo.dm.browser.tabList.close")
            }
            .padding(.horizontal, DMBrowserPhone.barPadding + 2)
            .frame(height: DMBrowserPhone.barHeight)
            .liquidGlassPanelSurface(cornerRadius: DMBrowserPhone.barRadius)
            .padding(.horizontal, DMBrowserPhone.barInset)
            .padding(.bottom, DMBrowserPhone.barInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tatwo.dm.browser.tabList.bar")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.browser.tabList")
    }

    /// W184 G2c：分頁總覽最後一格：＋ 新分頁（同側欄的新分頁、⌘⌥T：開一個空白的一般分頁、置中的搜尋框拿到游標；滿了＝頁面頂上一句話）。
    private var newTabCard: some View {
        let shape = RoundedRectangle(cornerRadius: DMBrowserPhone.tabCardRadius, style: .continuous)
        return Button { browser.newTab() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                Text(DMBrowser.blankTitle)
                    .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: DMBrowserPhone.thumbnailHeight + DMBrowserPhone.newTabCardExtra)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background(shape.fill(Color.primary.opacity(DMBrowserPhone.thumbnailOpacity)))
        .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
        .help("新分頁（\(DMBrowserNewTabKey.display)）")
        .accessibilityLabel("新分頁")
        .accessibilityIdentifier("tatwo.dm.browser.tabList.newTab")
        .background { if probes { DMFrameProbe(key: "tabList.newTab") } }
    }

    private func card(_ tab: DMBrowserTabInfo) -> some View {
        let active = tab.id == browser.activeID
        let shape = RoundedRectangle(cornerRadius: DMBrowserPhone.tabCardRadius, style: .continuous)
        return ZStack(alignment: .topTrailing) {
            Button { browser.select(tab.id) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(DMBrowserPhone.thumbnailOpacity))
                        .frame(height: DMBrowserPhone.thumbnailHeight)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.title)
                            .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                            .lineLimit(1)
                        Text(tab.sourceText)
                            .font(.system(size: DMPhone.TextSize.footnote))
                            .foregroundStyle(tab.hostMismatch || tab.isInsecure ? LiquidGlassTokens.loopsCaution : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        status(tab)
                    }
                    .padding(.top, DMBrowserPhone.tabTextTop)
                    .padding(.horizontal, DMBrowserPhone.tabTextSide)
                    .padding(.bottom, DMBrowserPhone.tabTextBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help(tab.done ? "\(tab.title)（完成）" : tab.title)
            .accessibilityLabel(tab.done ? "\(tab.title)（完成）" : tab.title)
            .accessibilityValue(active ? "目前分頁" : "")
            .accessibilityIdentifier("tatwo.dm.browser.tab." + tab.purpose.rawValue)
            Button { browser.userClose(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: DMPhone.TextSize.caption, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: DMBrowserPhone.closeSize, height: DMBrowserPhone.closeSize)
                    .background(Circle().fill(Color.black.opacity(DMBrowserPhone.closeOpacity)))
                    .padding(DMBrowserPhone.closeInset)
                    .contentShape(Rectangle())   // 看得到的是 28 的圓，按得到的是 44（四邊各多 8）
            }
            .buttonStyle(.plain)
            .help(browser.closingCancels(tab.id) ? "關掉這個分頁（這一次還沒完成，會一起取消）" : "關掉這個分頁")
            .accessibilityLabel("關掉：\(tab.title)")
            .accessibilityIdentifier("tatwo.dm.browser.tabList.close." + tab.purpose.rawValue)
        }
        .liquidGlassPanelSurface(cornerRadius: DMBrowserPhone.tabCardRadius)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(active ? LiquidGlassTokens.brandAccent : Color(nsColor: .separatorColor),
                               lineWidth: active ? DMBrowserPhone.tabCardRing : DMPhone.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.done ? "\(tab.title)（完成）" : tab.title)
        .accessibilityIdentifier("tatwo.dm.browser.tabList.card." + tab.purpose.rawValue)
    }

    /// 狀態：完成＝綠勾；頁面還開著＝進行中（強調色）或載入中；頁面收起來等結果＝來源那一行已經寫了，不再多一行。
    /// W184 G2：使用者自己開的一般網頁沒有流程在進行：只標載入中。
    @ViewBuilder
    private func status(_ tab: DMBrowserTabInfo) -> some View {
        if tab.done {
            Label("完成", systemImage: "checkmark.circle.fill")
                .font(.system(size: DMPhone.TextSize.footnote, weight: .semibold))
                .foregroundStyle(LiquidGlassTokens.loopsPositive)
        } else if !tab.pageClosed, tab.purpose.isFlow {
            Text(tab.loading ? "載入中…" : "進行中")
                .font(.system(size: DMPhone.TextSize.footnote, weight: .semibold))
                .foregroundStyle(tab.loading ? Color.secondary : LiquidGlassTokens.brandAccent)
        } else if tab.loading {
            Text("載入中…")
                .font(.system(size: DMPhone.TextSize.footnote, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
    }
}

/// 頁面放在這個容器裡（頁面由 DMBrowser 拿著；框換了就搬過去）。
struct DMBrowserPageSurface: NSViewRepresentable {
    let browser: DMBrowser
    /// 這個容器屬於哪一個 Browser 畫面（畫面據此判斷頁面是不是放在自己這裡）。
    var slot: DMBrowserPageSlot?

    func makeNSView(context: Context) -> DMBrowserPageContainer {
        let container = DMBrowserPageContainer(frame: .zero)
        container.owner = browser
        slot?.container = container
        browser.claim(container)
        return container
    }

    func updateNSView(_ container: DMBrowserPageContainer, context: Context) {
        browser.claim(container)   // 頁面剛開好、換了分頁：放進來
    }

    static func dismantleNSView(_ container: DMBrowserPageContainer, coordinator: ()) {
        container.owner?.release(container)
    }
}

/// W184 D（GPT-6 審查 #1 跨視窗換手）：一個 Browser 畫面自己的頁面容器（weak；容器拆掉就是 nil）。
final class DMBrowserPageSlot {
    weak var container: NSView?
}

/// 網頁的容器：照頁面框的圓角裁（原生網頁不吃 SwiftUI 的 clipShape）；點進網頁時讓私訊框拿鍵盤（停靠框平常只在需要時才拿）。
/// W184 D：操作列、連線卡片浮在網頁上——它們登記的命中區（BrowserChromeHitLayer）這個容器讓位，點擊交給 SwiftUI 的按鈕。
final class DMBrowserPageContainer: NSView {
    weak var owner: DMBrowser?
    private var monitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = DMBrowserPhone.pageRadius
        layer?.cornerCurve = .continuous
        setAccessibilityIdentifier("tatwo.dm.browser.page")
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window, let superview,
           BrowserChromeHitLayer.LayerView.ownsChromePoint(superview.convert(point, to: nil), in: window) {
            return nil
        }
        return super.hitTest(point)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let monitor, newWindow == nil {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owner?.containerMoved()
        guard window != nil, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.takeKeyIfInside(event) }
            return event
        }
    }

    /// 打字要進得了網頁：點在網頁上時讓這個框成為 key（不把整個 App 叫到前景）。
    private func takeKeyIfInside(_ event: NSEvent) {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor, !window.isKeyWindow else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { window.makeKey() }
    }
}
