import SwiftUI

/// W184 G2d（使用者 09-30：「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：私訊框的 Browser 用同一排，
/// 只讀——點一格＝私訊框開它自己的分頁（open，不在主視窗開）；哪一格開著／顯示中照私訊框的分頁（state）。
/// 私訊框不拖、不放、沒有右鍵選單（珍藏在主視窗整理）、沒有音符（播放狀態是主視窗分頁的）。主視窗那一排照舊（external＝nil）。
struct BrowserFavoritesExternal {
    let open: @MainActor (BrowserFavorite) -> Void
    let state: @MainActor (BrowserFavorite) -> (bound: Bool, selected: Bool)
}

/// Uses the existing sidebar's visibility lifecycle; it does not pin or expand the sidebar.
/// W112（使用者 2026-09-20）：「造型我想改細窄 左右滑動尋找 最多展示五個icon 多的要右滑 存進去的方式是從分頁拖拽上去」
/// 「音樂播放時icon要出現音符小動態」。一排細窄的格子，寬度剛好放五格；第六個起往右滑。
struct BrowserFavoritesStrip: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    /// nil＝主視窗（照舊）；私訊框給自己的開法與狀態（見 BrowserFavoritesExternal）。
    var external: BrowserFavoritesExternal? = nil
    @ObservedObject private var audible = BrowserAudibleTabs.shared
    @State private var targeted = false
    static let visibleCount = 5
    static let tileHeight: CGFloat = 30
    static let tileGap: CGFloat = 6

    var body: some View {
        if let external { externalStrip(external) } else { strip }
    }

    private var strip: some View {
        GeometryReader { proxy in
            let inset = BrowserSidebarMetrics.rowHorizontalPadding
            let tileWidth = max(24, (proxy.size.width - 2 * inset - CGFloat(Self.visibleCount - 1) * Self.tileGap) / CGFloat(Self.visibleCount))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.tileGap) {
                    if store.favorites.isEmpty {
                        // 空的時候也是五個細窄空位，第一格寫明怎麼存。
                        ForEach(0..<Self.visibleCount, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(targeted ? 0.55 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: tileWidth, height: Self.tileHeight)
                                .overlay { if index == 0 { Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) } }
                        }
                        .accessibilityHidden(true)
                    }
                    ForEach(store.favorites) { favorite in tile(favorite, width: tileWidth) }
                }
                .padding(.horizontal, inset)
            }
            .frame(height: Self.tileHeight)
        }
        .frame(height: Self.tileHeight)
        .padding(.vertical, BrowserSidebarMetrics.rowHorizontalPadding / 2)
        .contentShape(Rectangle())
        .help(store.favorites.isEmpty ? "拖分頁到這裡珍藏" : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.favorites.isEmpty ? "常用網頁：拖分頁到這裡珍藏" : "常用網頁")
        .accessibilityIdentifier("browser.favorites.strip")
        .dropDestination(for: String.self) { payloads, _ in accept(payloads, before: nil) }
            isTargeted: { targeted = $0 }
        .contextMenu {
            Button("匯入珍藏 HTML…") { BrowserBookmarkExport.presentFavoriteImport(registry: store.registry) }
        }
    }

    private func tile(_ favorite: BrowserFavorite, width: CGFloat) -> some View {
        // 珍藏點開的分頁住在這一格上，不列在下面的分頁清單；從裡面再開的新視窗才會出現在下面。
        let bound = store.tabs.first { $0.favoriteID == favorite.id }
        let selected = bound.map { $0.id == store.selectedID } ?? false
        let playing = bound?.registryID.map({ audible.ids.contains($0.uuidString) }) == true || audible.isAudible(host: favorite.url.host, in: store.registry)
        return Group {   // 不用 Button：Button 會吃掉 mouse-down，這一格就拖不動（W115）
            face(favorite, width: width, selected: selected, bound: bound != nil, playing: playing)
        }
        .onTapGesture { store.openFavorite(favorite.id) }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.openFavorite(favorite.id) }
        .help(favorite.title)
        .accessibilityLabel(favorite.title)
        .accessibilityValue(selected ? "顯示中" : bound != nil ? "已開啟" : "未開啟")
        .accessibilityIdentifier("browser.favorite.\(favorite.id)")
        .contextMenu {
            if let bound { Button("關閉這個珍藏的分頁") { store.close(bound.id) } }
            Button("移出珍藏") { store.registry.removeFavorite(favorite.id) }
            Button("移到最前") { store.registry.moveFavorite(favorite.id, before: store.favorites.first?.id) }
                .disabled(favorite.order == 0)
            Button("移到最後") { store.registry.moveFavorite(favorite.id, before: nil) }
                .disabled(favorite.order == store.favorites.count - 1)
        }
        .onDrag { NSItemProvider(object: "tatwo-browser-favorite:\(favorite.id)" as NSString) }
        .dropDestination(for: String.self) { payloads, _ in accept(payloads, before: favorite.id) }
    }

    /// 一格的樣子（主視窗、私訊框同一套）：細窄格子、favicon、選中的框、開著的小點、播放中的音符。
    private func face(_ favorite: BrowserFavorite, width: CGFloat, selected: Bool, bound: Bool, playing: Bool) -> some View {
        Group {
            if let data = favorite.faviconPNG, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "globe").foregroundStyle(LiquidGlassTokens.browserInk)
            }
        }
        .frame(width: BrowserSidebarMetrics.workspaceFaviconSize, height: BrowserSidebarMetrics.workspaceFaviconSize)
        .frame(width: width, height: Self.tileHeight)
        .background(LiquidGlassTokens.browserFieldFill.opacity(selected ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { if selected { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(LiquidGlassTokens.browserInk.opacity(0.35), lineWidth: 1) } }
        .overlay(alignment: .bottom) { if bound && !selected { Circle().fill(LiquidGlassTokens.browserInk.opacity(0.45)).frame(width: 3, height: 3).padding(.bottom, 2) } }
        .overlay(alignment: .topTrailing) { if playing { BrowserAudioNote(size: 8).padding(3) } }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// W184 G2d：私訊框那一排——同樣的五格寬、右滑、格子樣子；點＝私訊框開（external.open），選中／開著照私訊框的分頁。
    /// 不拖不放、沒有右鍵選單、沒有音符；空的時候同樣五個虛線空位（說明寫「在主視窗的 Browser 把分頁拖到這一排」）。
    private func externalStrip(_ external: BrowserFavoritesExternal) -> some View {
        GeometryReader { proxy in
            let inset = BrowserSidebarMetrics.rowHorizontalPadding
            let tileWidth = max(24, (proxy.size.width - 2 * inset - CGFloat(Self.visibleCount - 1) * Self.tileGap) / CGFloat(Self.visibleCount))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.tileGap) {
                    if store.favorites.isEmpty {
                        ForEach(0..<Self.visibleCount, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: tileWidth, height: Self.tileHeight)
                        }
                        .accessibilityHidden(true)
                    }
                    ForEach(store.favorites) { favorite in
                        let state = external.state(favorite)
                        Group { face(favorite, width: tileWidth, selected: state.selected, bound: state.bound, playing: false) }
                            .onTapGesture { external.open(favorite) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { external.open(favorite) }
                            .help(favorite.title)
                            .accessibilityLabel(favorite.title)
                            .accessibilityValue(state.selected ? "顯示中" : state.bound ? "已開啟" : "未開啟")
                            .accessibilityIdentifier("browser.favorite.\(favorite.id)")
                    }
                }
                .padding(.horizontal, inset)
            }
            .frame(height: Self.tileHeight)
        }
        .frame(height: Self.tileHeight)
        .padding(.vertical, BrowserSidebarMetrics.rowHorizontalPadding / 2)
        .contentShape(Rectangle())
        .help(store.favorites.isEmpty ? "還沒有珍藏：在主視窗的 Browser 把分頁拖到這一排" : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.favorites.isEmpty ? "常用網頁：在主視窗的 Browser 把分頁拖到這一排" : "常用網頁")
        .accessibilityIdentifier("browser.favorites.strip")
    }

    private func accept(_ payloads: [String], before target: UUID?) -> Bool {
        BrowserFavoriteDrop.accept(payloads, before: target, registry: store.registry) { alias in
            store.tabs.first { $0.id == alias }?.registryID
        }
    }
}

/// The same action is used by bookmark and tab context menus.
struct BrowserFavoriteMenu: View {
    @ObservedObject var registry: BrowserTabRegistry
    let url: URL?
    let add: () -> Void
    var body: some View {
        if let url, let existing = registry.favorite(for: url) {
            Button("移出珍藏") { registry.removeFavorite(existing.id) }
        } else {
            Button("加入珍藏", action: add).disabled(url == nil)
        }
    }
}

@MainActor
enum BrowserFavoriteDrop {
    /// IDs must resolve in this registry/window. Never interpret dropped text as a URL.
    static func accept(_ payloads: [String], before target: UUID?, registry: BrowserTabRegistry,
                       tabID: (Int) -> UUID?) -> Bool {
        var accepted = false
        for payload in payloads {
            let parts = payload.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            if parts[0] == "tatwo-browser-favorite", let id = UUID(uuidString: value) {
                if id == target { accepted = registry.favorites.contains { $0.id == id } || accepted }
                else { accepted = registry.moveFavorite(id, before: target) || accepted }
                continue
            }
            let favorite: BrowserFavorite?
            switch String(parts[0]) {
            case "tatwo-browser-tab":
                favorite = Int(value).flatMap(tabID).flatMap { registry.addFavorite(tabID: $0) }
            case "tatwo-browser-registry-tab":
                favorite = UUID(uuidString: value).flatMap { registry.addFavorite(tabID: $0) }
            case "tatwo-browser-bookmark":
                favorite = UUID(uuidString: value).flatMap { registry.addFavorite(bookmarkID: $0) }
            default: favorite = nil
            }
            if let favorite {
                if let target { registry.moveFavorite(favorite.id, before: target) }
                accepted = true
            }
        }
        return accepted
    }
}
