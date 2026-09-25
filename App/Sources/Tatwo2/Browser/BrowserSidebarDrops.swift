import SwiftUI

/// W114（使用者 2026-09-20：「書籤跟新分頁、釘選分頁最好的新增跟移除方式是拖拽 現在缺少直接拖進去的能力」）：
/// 側欄三個落點。只認這個視窗自己發出的 ID（`tatwo-browser-*`），不把拖進來的文字當網址。
struct BrowserSidebarDrop: ViewModifier {
    enum Target { case pinned, tabs }
    @ObservedObject var store: BrowserWorkSpaceStore
    let target: Target
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(targeted ? LiquidGlassTokens.browserFieldFill.opacity(0.7) : .clear,
                        in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
            .dropDestination(for: String.self) { payloads, _ in accept(payloads) } isTargeted: { targeted = $0 }
    }

    private func accept(_ payloads: [String]) -> Bool {
        var accepted = false
        for payload in payloads {
            let parts = payload.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch (String(parts[0]), target) {
            case ("tatwo-browser-tab", .pinned):
                // 一般分頁拖進釘選區＝釘選。書籤／珍藏自己的分頁不在這裡處理。
                guard let tab = store.tabs.first(where: { String($0.id) == value }), !tab.pinned,
                      tab.bookmarkID == nil, tab.favoriteID == nil, let id = tab.registryID else { continue }
                store.registry.setPinned(id, true); accepted = true
            case ("tatwo-browser-tab", .tabs):
                // 釘選的分頁拖回分頁區＝取消釘選。
                guard let tab = store.tabs.first(where: { String($0.id) == value }), tab.pinned, let id = tab.registryID else { continue }
                store.registry.setPinned(id, false); accepted = true
            case ("tatwo-browser-bookmark", .tabs):
                // 書籤拖到分頁區＝移出書籤，分頁留著（沒開過就先開起來）。可用「復原刪除的書籤」救回。
                guard let id = UUID(uuidString: value),
                      let folder = store.folders.first(where: { $0.bookmarks.contains { $0.id == id } }),
                      let bookmark = folder.bookmarks.first(where: { $0.id == id }) else { continue }
                if store.tab(forBookmark: id) == nil { store.openBookmark(bookmark, folderID: folder.id) }
                store.deleteBookmark(id); accepted = true
            case ("tatwo-browser-favorite", .tabs):
                // 珍藏拖到分頁區＝移出珍藏；它開著的分頁回到下面的清單。
                guard let id = UUID(uuidString: value), store.registry.favorites.contains(where: { $0.id == id }) else { continue }
                store.registry.removeFavorite(id); accepted = true
            default: continue
            }
        }
        return accepted
    }
}
