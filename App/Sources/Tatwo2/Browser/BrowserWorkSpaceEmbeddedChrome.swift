import SwiftUI

/// 聊天旁瀏覽器（compact chrome）與工具列共用控制項的幾何權威。
/// W54：視圖不寫裸數字；PR #4 帶進來的浮動工具列尺寸集中在這裡。
enum BrowserChatChromeMetrics {
    static let toolbarHeight: CGFloat = 40
    static let hoverBandExtra: CGFloat = 2
    static let backdropFade: CGFloat = 16
    static let stripHeight: CGFloat = 30
    static let stripPadding: CGFloat = 6
    static let stripGap: CGFloat = 2
    static let stripTrailingReserve: CGFloat = 40
    static let stripControlReserve: CGFloat = 44
    static let tabGap: CGFloat = 4
    static let tabInnerGap: CGFloat = 3
    static let tabHeight: CGFloat = 28
    static let tabMaxWidth: CGFloat = 136
    static let tabMinWidth: CGFloat = 56
    static let tabPadding: CGFloat = 5
    static let tabCornerRadius: CGFloat = 5
    static let tabFontSize: CGFloat = 12
    static let tabCloseFontSize: CGFloat = 9
    static let tabCloseWidth: CGFloat = 16
    static let tabCloseHeight: CGFloat = 20
    static let selectedTabFill = 0.10
    static let idleTabFill = 0.025
    static let newTabSize: CGFloat = 24
    static let newTabSlotWidth: CGFloat = 28
    static let standaloneNewTabSize: CGFloat = 32
    static let toolsGap: CGFloat = 8
    static let toolsOffset: CGFloat = 34
    static let toolsButtonCount = 3
    static let expanderSize: CGFloat = 28
    static let expanderFontSize: CGFloat = 11
    static let expanderFill = 0.07
    static let toolShadowRadius: CGFloat = 4
    static let toolShadowOpacity = 0.18
    static let toolShadowY: CGFloat = 1
    /// 移入偵測帶：比圓鈕寬一點好進入，但仍以 ⌃ 為中心，展開後蓋住整列圓鈕。
    static let toolsColumnWidth = expanderSize + toolsGap
    static let toolsColumnHeight = toolsOffset + expanderSize * CGFloat(toolsButtonCount)
        + toolsGap * CGFloat(toolsButtonCount - 1)
    static let sidebarPopoverWidth: CGFloat = 240
    static let sidebarPopoverHeight: CGFloat = 480
    static let sidebarPopoverPadding: CGFloat = 8
}

// 來源：公開 PR #4（作者 saiguigu1068021-cell）。整合時從
// BrowserWorkSpaceDesignView.swift 搬出來，維持該檔 1300 行上限（不放寬）。
extension BrowserWorkSpaceDesignView {
    /// 聊天旁的單排分頁；獨立 Browser work space 仍用側欄分頁列表。
    var embeddedTabStrip: some View {
        GeometryReader { geometry in
            let slot = max(1, store.tabs.count)
            let available = geometry.size.width - BrowserChatChromeMetrics.stripControlReserve
            let tabWidth = min(BrowserChatChromeMetrics.tabMaxWidth,
                max(BrowserChatChromeMetrics.tabMinWidth,
                    available / CGFloat(slot) - BrowserChatChromeMetrics.tabGap))
            HStack(spacing: BrowserChatChromeMetrics.stripGap) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BrowserChatChromeMetrics.tabGap) {
                            ForEach(store.tabs) { tab in
                                embeddedTab(tab, width: tabWidth)
                            }
                        }
                    }
                    .onChange(of: store.selectedID, initial: true) { _, selected in
                        scroll.scrollTo(selected, anchor: .trailing)
                    }
                }
                .frame(width: min(max(0, geometry.size.width - BrowserChatChromeMetrics.stripTrailingReserve),
                    CGFloat(store.tabs.count) * (tabWidth + BrowserChatChromeMetrics.tabGap)))
                newTabButton.frame(width: BrowserChatChromeMetrics.newTabSlotWidth,
                    height: BrowserChatChromeMetrics.stripHeight)
                Spacer(minLength: 0)
            }.padding(.horizontal, BrowserChatChromeMetrics.stripPadding)
        }.frame(height: BrowserChatChromeMetrics.stripHeight)
    }

    private func embeddedTab(_ tab: BrowserWorkSpaceStore.Tab, width: CGFloat) -> some View {
        let identity = tab.registryID?.uuidString ?? String(tab.id)
        return HStack(spacing: BrowserChatChromeMetrics.tabInnerGap) {
            Button { store.select(tab.id) } label: {
                Text(tab.title.isEmpty ? "新分頁" : tab.title)
                    .font(.system(size: BrowserChatChromeMetrics.tabFontSize)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("切換分頁：\(tab.title)")
            .accessibilityIdentifier("browser.chatTab.\(identity)")
            // 關掉最後一個分頁＝收合聊天旁瀏覽器（使用者 09-18：「新分頁無法打叉」）。
            Button {
                let last = store.tabs.count <= 1
                store.close(tab.id)
                if last { onClose?() }
            } label: {
                Image(systemName: "xmark").font(.system(size: BrowserChatChromeMetrics.tabCloseFontSize))
                    .frame(width: BrowserChatChromeMetrics.tabCloseWidth,
                        height: BrowserChatChromeMetrics.tabCloseHeight).contentShape(Rectangle())
            }
            .accessibilityLabel("關閉分頁：\(tab.title)")
            .accessibilityIdentifier("browser.chatCloseTab.\(identity)")
        }
        .buttonStyle(.plain).padding(.horizontal, BrowserChatChromeMetrics.tabPadding)
        .frame(width: width, height: BrowserChatChromeMetrics.tabHeight)
        .background(Color.primary.opacity(tab.id == store.selectedID
            ? BrowserChatChromeMetrics.selectedTabFill : BrowserChatChromeMetrics.idleTabFill),
            in: RoundedRectangle(cornerRadius: BrowserChatChromeMetrics.tabCornerRadius))
        .id(tab.id)
    }

    /// 新增分頁；右鍵是既有「瀏覽器功能」清單，兩種 chrome 共用同一份動作。
    var newTabButton: some View {
        let size = onClose == nil
            ? BrowserChatChromeMetrics.standaloneNewTabSize : BrowserChatChromeMetrics.newTabSize
        return Button {
            if store.canAddTab { store.addTab(); store.searchFocusRequest += 1 }
        } label: {
            Image(systemName: "plus").frame(width: size, height: size)
        }
        .buttonStyle(.plain).disabled(!store.canAddTab)
        .accessibilityLabel("新增分頁")
        .accessibilityIdentifier("browser.toolbar.newTab")
        .help("新增分頁；右鍵開啟分頁、下載與瀏覽器功能")
        .contextMenu { browserActionsMenu }
    }

    @ViewBuilder var browserActionsMenu: some View {
        if onClose != nil {
            Button("分頁、書籤與下載…") { embeddedSidebarPresented = true }
            Divider()
        }
        Button("在網頁中尋找…") { performBrowserAction(.findInPage) }
        Button("列印…") { send(.printPage) }
        Button("存成 PDF 並用系統預覽開啟") { send(.printPDF) }
        if runtime.navigationTabID == store.selectedRegistryID && runtime.navigationState.isPDF {
            Button("下載 PDF 並用系統預覽開啟") { send(.openPDF) }
        }
        Button("登入協助…") { loginHelpPresented = true }
        Button("重設此網站的多檔下載權限") { send(.resetDownloadPermission) }
        Divider()
        Button("搜尋分頁…", action: openTabSearch)
        Button(store.focusMode ? "展開側欄" : "收合側欄", action: store.toggleSidebar)
        Divider()
        Button("關閉目前分頁") { store.close(store.selectedID) }
        Button("重新開啟關閉的分頁", action: store.reopenClosedTab).disabled(!store.canReopenClosedTab)
        Button("復原刪除的書籤", action: store.undoBookmarkDeletion).disabled(store.lastRemovedBookmark == nil)
        Button("診斷…") { diagnosticsPresented = true }
        Button("新增 space", action: store.addSpace)
        Button("從其他瀏覽器導入…", action: store.requestImport)
        Divider()
        Button("擴充功能…") { extensionsPresented = true }
        Menu("工作區") {
            ForEach(ChatRunMode.visibleChatTabs) { mode in
                Button(mode.displayName) {
                    NotificationCenter.default.post(name: .tatwoChatSelectMode, object: mode.rawValue)
                }
            }
        }
    }

    /// 獨立 Browser work space 保留 W66／W67 已核准的可見「瀏覽器功能」選單；
    /// 聊天旁 chrome 放不下，同一份動作改掛在新增分頁的右鍵選單上。
    var browserActionsButton: some View {
        Menu { browserActionsMenu } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("瀏覽器功能")
    }

    /// 聊天旁 chrome 的圓鈕：與 ⌃ 同尺寸、同材質、同陰影，浮在網頁上，沒有底板。
    func embeddedToolChip(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: BrowserChatChromeMetrics.expanderFontSize, weight: .semibold))
            .frame(width: BrowserChatChromeMetrics.expanderSize,
                height: BrowserChatChromeMetrics.expanderSize)
            .background {
                ZStack {
                    BrowserToolbarMaterial()
                    Color.primary.opacity(BrowserChatChromeMetrics.expanderFill)
                }
                .clipShape(Circle())
                .shadow(color: Color.black.opacity(BrowserChatChromeMetrics.toolShadowOpacity),
                    radius: BrowserChatChromeMetrics.toolShadowRadius,
                    y: BrowserChatChromeMetrics.toolShadowY)
            }
            .contentShape(Circle())
    }

    /// 聊天旁展開的工具：獨立圓鈕垂直一列，中心線對齊 ⌃，間距一致，沒有底板。
    @ViewBuilder var embeddedToolsColumn: some View {
        Button { extensionsPresented.toggle() } label: { BrowserFloatingChip(systemImage: "puzzlepiece.extension") }
            .buttonStyle(.plain).accessibilityLabel("擴充功能").accessibilityIdentifier("browser.extensions")
            .popover(isPresented: $extensionsPresented, arrowEdge: .trailing) { extensionsMenu }
        Button { store.showAnnotations(store.selectedID) } label: { BrowserFloatingChip(systemImage: "note.text") }
            .buttonStyle(.plain).disabled(store.selectedRegistryID == nil)
            .help("註解").accessibilityLabel("註解")
        if let onClose {
            Button(action: onClose) { BrowserFloatingChip(systemImage: "sidebar.right") }
                .buttonStyle(.plain).accessibilityLabel("收合聊天旁瀏覽器")
        }
    }

    /// W122：拼圖鈕的選單。商店是一般網頁 → 開新分頁；`chrome://extensions` 與 `chrome-extension://` 嵌入的分頁不准載入
    /// （CEF 的 Alloy 白名單沒有它們），只能用完整模式的介面貼在網頁區上開。
    @ViewBuilder var extensionsMenu: some View {
        BrowserExtensionsMenu(
            openTab: { url in if let target = URL(string: url) { store.addTab(url: target) } },
            openManager: { url in NotificationCenter.default.post(name: BrowserChromeStyleEmbedState.openRequest, object: url) },
            dismiss: { extensionsPresented = false })
    }

    private func openExtensionPage(_ url: String) {
        NotificationCenter.default.post(name: BrowserChromeStyleEmbedState.openRequest, object: url)
    }

    /// 擴充視窗要開在哪：主視窗的網頁區（側欄右邊、頂列下面）。算不出來就交給原生端用預設位置。
    /// W147：擴充頁的位置＝網頁區的真實位置（定位點回報），扣掉上面固定顯示的工具列。還沒回報時才退回舊估法。
    static func extensionSurfaceFrame(for window: NSWindow?) -> NSRect {
        guard let window else { return .zero }
        var page = BrowserChromeStyleEmbedState.shared.pageRectInWindow
        guard page.width > 80, page.height > 80 else { return extensionSurfaceFrame(for: window, sidebarInset: WorkspaceSidebarMetrics.width) }
        page.size.height -= BrowserOmniboxMetrics.toolbarHeight   // 視窗座標原點在左下，扣高度＝頂邊往下讓
        return window.convertToScreen(page)
    }
    static func extensionSurfaceFrame(for window: NSWindow?, sidebarInset: CGFloat) -> NSRect {
        guard let window else { return .zero }
        let frame = window.frame
        // W136：往下讓出整條頂列的高度，否則擴充視窗會蓋住拼圖鈕，開著時就叫不出選單、也關不掉。
        return NSRect(x: frame.minX + sidebarInset, y: frame.minY,
                      width: max(400, frame.width - sidebarInset),
                      height: max(300, frame.height - BrowserOmniboxMetrics.toolbarHeight))
    }

    @ViewBuilder var auxiliaryBrowserControls: some View {
        if onClose == nil {   // W114：翻譯鈕在工具列，可手動按（目前只接獨立 Browser）
            BrowserTranslateButton(translator: translator, host: URL(string: store.selectedTab.url)?.host, size: BrowserOmniboxMetrics.collapsedHeight)
                .disabled(store.showsStartPage)
        }
        BrowserPinnedExtensionButtons(size: BrowserOmniboxMetrics.collapsedHeight, openPage: openExtensionPage)
        Button { extensionsPresented.toggle() } label: {
            Image(systemName: "puzzlepiece.extension")
                .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
        }.buttonStyle(.plain).accessibilityLabel("擴充功能").accessibilityIdentifier("browser.extensions")
        .popover(isPresented: $extensionsPresented, arrowEdge: .bottom) { extensionsMenu }
        Button { store.showAnnotations(store.selectedID) } label: {
            Image(systemName: "note.text")
                .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
        }
        .buttonStyle(.plain).disabled(store.selectedRegistryID == nil)
        .help("註解").accessibilityLabel("註解").fixedSize()
        if let onClose {
            Button(action: onClose) { Image(systemName: "sidebar.right") }
                .buttonStyle(.plain).accessibilityLabel("收合聊天旁瀏覽器")
        }
    }

    /// 聊天旁工具列太窄放不下輔助控制項，改成移入展開／點擊固定的一欄。
    var embeddedToolsExpander: some View {
        Button { embeddedToolsPinned.toggle() } label: {
            embeddedToolChip(embeddedToolsPinned ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(embeddedToolsPinned ? "收合瀏覽器工具" : "向下展開瀏覽器工具")
        .accessibilityIdentifier("browser.toolbar.expandTools")
        .help("移入向下展開工具；點擊固定，再點收合")
        .onHover { embeddedToolsHovered = $0 }
        // PR4e：圓鈕列畫在無邊框子視窗（永遠在 CEF 之上、點得到），從 ⌃ 正下方一直列、無底板、不推開網頁。
        .background {
            BrowserFloatingToolsAnchor(isOpen: embeddedToolsOpen,
                                       onHoverPanel: { embeddedToolsPanelHovered = $0 }) {
                VStack(spacing: BrowserChatChromeMetrics.toolsGap) { embeddedToolsColumn }
                    .frame(width: BrowserChatChromeMetrics.expanderSize)
                    .foregroundStyle(LiquidGlassTokens.browserOmniboxInk)
            }
        }
    }

    var embeddedToolsOpen: Bool { embeddedToolsHovered || embeddedToolsPanelHovered || embeddedToolsPinned }
}
