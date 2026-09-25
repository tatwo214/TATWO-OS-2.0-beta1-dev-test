import SwiftUI

/// Uses the existing sidebar's visibility lifecycle; it does not pin or expand the sidebar.
/// W112（使用者 2026-09-20）：「造型我想改細窄 左右滑動尋找 最多展示五個icon 多的要右滑 存進去的方式是從分頁拖拽上去」
/// 「音樂播放時icon要出現音符小動態」。一排細窄的格子，寬度剛好放五格；第六個起往右滑。
struct BrowserFavoritesStrip: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    @ObservedObject private var audible = BrowserAudibleTabs.shared
    @State private var targeted = false
    static let visibleCount = 5
    static let tileHeight: CGFloat = 30
    static let tileGap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let inset = BrowserSidebarMetrics.rowHorizontalPadding
            let tileWidth = max(24, (proxy.size.width - 2 * inset - CGFloat(Self.visibleCount - 1) * Self.tileGap) / CGFloat(Self.visibleCount))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.tileGap) {
                    if store.registry.favorites.isEmpty {
                        // 空的時候也是五個細窄空位，第一格寫明怎麼存。
                        ForEach(0..<Self.visibleCount, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(targeted ? 0.55 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: tileWidth, height: Self.tileHeight)
                                .overlay { if index == 0 { Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) } }
                        }
                        .accessibilityHidden(true)
                    }
                    ForEach(store.registry.favorites) { favorite in tile(favorite, width: tileWidth) }
                }
                .padding(.horizontal, inset)
            }
            .frame(height: Self.tileHeight)
        }
        .frame(height: Self.tileHeight)
        .padding(.vertical, BrowserSidebarMetrics.rowHorizontalPadding / 2)
        .contentShape(Rectangle())
        .help(store.registry.favorites.isEmpty ? "拖分頁到這裡珍藏" : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.registry.favorites.isEmpty ? "常用網頁：拖分頁到這裡珍藏" : "常用網頁")
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
        return Group {   // 不用 Button：Button 會吃掉 mouse-down，這一格就拖不動（W115）
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
            .overlay(alignment: .bottom) { if bound != nil && !selected { Circle().fill(LiquidGlassTokens.browserInk.opacity(0.45)).frame(width: 3, height: 3).padding(.bottom, 2) } }
            .overlay(alignment: .topTrailing) {
                if bound?.registryID.map({ audible.ids.contains($0.uuidString) }) == true || audible.isAudible(host: favorite.url.host, in: store.registry) { BrowserAudioNote(size: 8).padding(3) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
            Button("移到最前") { store.registry.moveFavorite(favorite.id, before: store.registry.favorites.first?.id) }
                .disabled(favorite.order == 0)
            Button("移到最後") { store.registry.moveFavorite(favorite.id, before: nil) }
                .disabled(favorite.order == store.registry.favorites.count - 1)
        }
        .onDrag { NSItemProvider(object: "tatwo-browser-favorite:\(favorite.id)" as NSString) }
        .dropDestination(for: String.self) { payloads, _ in accept(payloads, before: favorite.id) }
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
