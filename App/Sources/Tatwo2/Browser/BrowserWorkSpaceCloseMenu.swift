import SwiftUI

/// Shared by tab-row and blank-sidebar context menus; guest/inspector surfaces stay scoped out.
struct BrowserWorkSpaceCloseMenu: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    var body: some View {
        if store.allowsCloseAllTabs {
            Button(store.closeAllTabsTitle, action: store.closeAllTabs).disabled(store.closeAllTabsCount == 0)
            if store.closedBatchCount > 0 {
                Button(store.reopenClosedBatchTitle, action: store.reopenClosedBatch)
            }
        }
    }
}

extension BrowserWorkSpaceStore {
    var allowsCloseAllTabs: Bool { !threadScoped && canAddTab }
    var closeAllTabsCount: Int {
        guard allowsCloseAllTabs, let spaceID = currentSpaceUUID else { return 0 }
        return registry.workSpaceCloseCandidates(spaceID: spaceID).count
    }
    var closeAllTabsTitle: String { "關閉全部分頁（\(closeAllTabsCount)）" }
    var reopenClosedBatchTitle: String { "重新開啟剛關閉的 \(closedBatchCount) 個分頁" }
    func reopenClosedBatch() {
        guard allowsCloseAllTabs, let spaceID = currentSpaceUUID else { return }
        if let selected = registry.reopenWorkSpaceBatch(spaceID: spaceID) { select(registryID: selected, touch: false) }
    }
    func closeAllTabs() {
        guard allowsCloseAllTabs, let spaceID = currentSpaceUUID else { return }
        let result = registry.closeWorkSpaceTabs(spaceID: spaceID, selectedID: selectedRegistryID)
        IslandNotice.shared.info(title: result.noticeTitle, detail: result.noticeDetail, duration: 6)
    }
}
