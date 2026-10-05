import SwiftUI

/// W184 G2d（使用者 09-30：「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：私訊框的 Browser 用同樣的
/// 書籤列，只讀——點一條＝私訊框開它自己的分頁（open，不在主視窗開）；哪一條開著、在看、在載入照私訊框的分頁（state）；
/// 減號＝關掉私訊框裡那一頁（close）。不改名、不刪、不拖不放、沒有右鍵選單（書籤在主視窗整理）。主視窗那一條照舊（external＝nil）。
struct BrowserBookmarkExternal {
    let open: @MainActor (BrowserWorkSpaceStore.Bookmark) -> Void
    let state: @MainActor (BrowserWorkSpaceStore.Bookmark) -> (open: Bool, selected: Bool, loading: Bool)
    let close: @MainActor (BrowserWorkSpaceStore.Bookmark) -> Void
}

/// W184 G2d：私訊框的 Browser 用同樣的資料夾列：展開與否是私訊框自己的（不動主視窗的資料夾），沒有「關掉這個資料夾的所有分頁」。
struct BrowserFolderExternal {
    let expanded: Bool
    let toggle: @MainActor () -> Void
}

/// Selection and close are siblings: closing must never reopen the bookmark.
struct BrowserBookmarkRow: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    let bookmark: BrowserWorkSpaceStore.Bookmark
    let folderID: UUID
    /// 刪除後怎麼通知使用者由外面決定（這個檔不認識 Island，輕量測試才編得過）。
    var onDeleted: (String) -> Void = { _ in }
    /// nil＝主視窗（照舊）；私訊框給自己的開法、狀態與關法（見 BrowserBookmarkExternal）。
    var external: BrowserBookmarkExternal? = nil
    @State private var hovering = false
    @State private var renaming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let external { externalRow(external) } else if renaming { renameField } else { row }
    }

    /// W184 G2d：私訊框那一條——同一個 BrowserTabRow、同一顆 hover 減號、同樣的選中底色與縮排；點、狀態、減號照私訊框的分頁
    /// （音符是主視窗分頁的，這裡用書籤自己的 id，不借主視窗分頁的播放狀態）。
    private func externalRow(_ external: BrowserBookmarkExternal) -> some View {
        let state = external.state(bookmark)
        return HStack(spacing: BrowserSidebarMetrics.childGap) {
            BrowserTabRow(variant: .workspace, title: bookmark.title, tabID: bookmark.id.uuidString,
                favicon: store.tab(forBookmark: bookmark.id)?.faviconPNG, selected: state.selected,
                loading: state.loading, workspaceIconFill: LiquidGlassTokens.browserFolderFill,
                workspaceIconForeground: LiquidGlassTokens.browserFieldFill,
                onSelect: { external.open(bookmark) })
                .accessibilityIdentifier("browser.bookmark.\(bookmark.id)")
                .accessibilityValue(state.loading ? "載入中" : state.open ? "已開啟" : "未開啟")
            if state.open {
                BrowserBookmarkCloseButton(hovering: hovering,
                    label: "關閉這個書籤的分頁", identifier: "browser.bookmark.close.\(bookmark.id)") {
                    external.close(bookmark)
                }
            }
        }
        .background(state.selected ? LiquidGlassTokens.browserFieldFill : .clear,
            in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
        .padding(.leading, BrowserSidebarMetrics.workspaceFaviconSize)
        .help(bookmark.url)
        .onHover { hovering = $0 }
    }

    /// W112（使用者 2026-09-20：「書籤右鍵要可以改名」）：就地改名，Enter 確定、Esc 取消。
    private var renameField: some View {
        TextField("書籤名稱", text: $name)
            .textFieldStyle(.roundedBorder).font(.system(size: BrowserSidebarMetrics.workspaceRowFontSize))
            .focused($nameFocused)
            .onSubmit { store.registry.renameBookmark(bookmark.id, to: name); finishRename() }
            .onExitCommand(perform: finishRename)
            .onChange(of: nameFocused) { _, focused in if !focused { finishRename() } }
            .padding(.leading, BrowserSidebarMetrics.workspaceFaviconSize)
            .accessibilityLabel("書籤名稱")
            .onAppear { store.bookmarkEditorActive = true; DispatchQueue.main.async { nameFocused = true } }
    }

    private func finishRename() { renaming = false; store.bookmarkEditorActive = false }

    private var row: some View {
        let tab = store.tab(forBookmark: bookmark.id)
        let selected = tab.map { store.selectedID == $0.id } ?? false
        let status = tab.map { $0.loading ? "載入中" : $0.sleeping ? "睡眠中" : "已開啟" } ?? "未開啟"
        return HStack(spacing: BrowserSidebarMetrics.childGap) {
            BrowserTabRow(variant: .workspace, title: bookmark.title,
                tabID: tab?.registryID?.uuidString ?? bookmark.id.uuidString,
                favicon: tab?.faviconPNG, selected: selected, sleeping: tab?.sleeping ?? false,
                loading: tab?.loading ?? false, workspaceIconFill: LiquidGlassTokens.browserFolderFill,
                workspaceIconForeground: LiquidGlassTokens.browserFieldFill,
                onSelect: { store.openBookmark(bookmark, folderID: folderID) })
                .accessibilityIdentifier("browser.bookmark.\(bookmark.id)")
                .accessibilityValue(status)
            if tab != nil {
                BrowserBookmarkCloseButton(hovering: hovering,
                    label: "關閉這個書籤的分頁", identifier: "browser.bookmark.close.\(bookmark.id)") {
                    store.closeBookmark(bookmark.id)
                }
            }
        }
        .background(selected ? LiquidGlassTokens.browserFieldFill : .clear,
            in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
        .padding(.leading, BrowserSidebarMetrics.workspaceFaviconSize)
        .help(bookmark.url)
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: "tatwo-browser-bookmark:\(bookmark.id)" as NSString) }
        // W114：分頁拖到資料夾裡任何一列，都算存進這個資料夾（不只資料夾標題那一列）。
        .dropDestination(for: String.self) { payloads, _ in store.saveDraggedTabs(payloads, into: folderID) }
        .contextMenu {
            Button("改名…") { name = bookmark.title; renaming = true }
            BrowserFavoriteMenu(registry: store.registry, url: URL(string: bookmark.url)) {
                store.registry.addFavorite(bookmarkID: bookmark.id)
            }
            Button("新增書籤（目前分頁）") { store.saveBookmark(tabID: store.selectedID, into: folderID) }
            Button("刪除書籤") {
                store.deleteBookmark(bookmark.id)
                onDeleted(bookmark.title)
            }
        }
    }
}

struct BrowserBookmarkFolderRow: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    let folder: BrowserWorkSpaceStore.Folder
    /// nil＝主視窗（照舊）；私訊框給自己的展開狀態（見 BrowserFolderExternal）。
    var external: BrowserFolderExternal? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: BrowserSidebarMetrics.childGap) {
            Button { if let external { external.toggle() } else { store.toggleFolder(folder.id) } } label: {
                HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                    Image(systemName: "folder.fill").foregroundStyle(LiquidGlassTokens.browserFolderFill)
                        .frame(width: BrowserSidebarMetrics.rowIconWidth)
                    HStack(spacing: BrowserSidebarMetrics.childGap) {
                        Text(folder.name).fontWeight(.bold).lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: BrowserSidebarMetrics.faviconFontSize, weight: .bold))
                            .rotationEffect(.degrees((external?.expanded ?? folder.chevronExpanded) ? BrowserSidebarMetrics.chevronExpandedAngle : BrowserSidebarMetrics.chevronCollapsedAngle))
                    }
                    Spacer(minLength: BrowserSidebarMetrics.zero)
                }
                .padding(BrowserSidebarMetrics.rowHorizontalPadding).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(folder.name)
            .accessibilityIdentifier("browser.folder.\(folder.id)")
            if external == nil, store.folderHasOpenTabs(folder.id) {
                BrowserBookmarkCloseButton(hovering: hovering,
                    label: "關閉這個資料夾的所有分頁", identifier: "browser.folder.close.\(folder.id)") {
                    store.closeFolderTabs(folder.id)
                }
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct BrowserBookmarkCloseButton: View {
    let hovering: Bool
    let label: String
    let identifier: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: BrowserSidebarMetrics.closeGlyphSize, weight: .semibold))
                .frame(width: BrowserSidebarMetrics.closeButtonSize, height: BrowserSidebarMetrics.closeButtonSize)
                .background(LiquidGlassTokens.browserFolderFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(LiquidGlassTokens.browserInk)
        .focused($focused)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
        .help(label)
        .opacity(hovering || focused ? BrowserSidebarMetrics.visibleOpacity : BrowserSidebarMetrics.hiddenOpacity)
        .allowsHitTesting(hovering || focused)
    }
}
