import SwiftUI

/// W184 G2d（主導 09-30 轉使用者：「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」；GPT-6 審查 G2d #5：
/// 私訊框的側欄要「就是」這一份，不是照抄排出來的另一份）：別的畫面借用 BrowserWorkSpaceSidebarList——同一個組合、同一個段落順序、
/// 同一組元件（珍藏那一排、📌 Pinned、書籤資料夾與書籤、分隔線、新分頁、分頁、下載＋空間圓點＋＋），只換「點了開在哪裡」與能做的事：
/// 借用的那一邊只讀＋開啟＋切換空間——不改名、不刪、不拖不放、沒有右鍵選單、不新增空間（W184 G2 施工單：書籤「只讀＋開啟；
/// 改名、刪除、搬移不做（在主視窗做）」）；分頁是借用那一邊自己的（它的資料、它的關法）。主視窗不給（nil）＝行為一個都沒變。
struct BrowserSidebarGuest {
    /// 珍藏那一排、書籤：點＝開在借用的那一邊。
    let favorites: BrowserFavoritesExternal
    let bookmarks: BrowserBookmarkExternal
    /// 資料夾展開與否是借用那一邊自己的（不動主視窗的資料夾）。
    let folder: @MainActor (BrowserWorkSpaceStore.Folder) -> BrowserFolderExternal
    /// 📌 Pinned 底下的一列（主視窗釘選的分頁）：借用那一邊畫它自己的那一列（點＝開在它那邊）。
    let pinnedRow: @MainActor (BrowserWorkSpaceStore.Tab) -> AnyView
    /// 新分頁那一列：借用那一邊的新分頁、識別碼、說明。
    let newTab: @MainActor () -> Void
    let newTabIdentifier: String
    let newTabHelp: String
    /// 分頁：借用那一邊自己的分頁列（主視窗的分頁不列）。
    let tabs: AnyView
    /// 空間圓點：點＝交給借用那一邊（它記下使用者選的空間再切；GPT-6 審查 G2d #4）；最下面那一排的識別碼（借用那一邊原本的）。
    let selectSpace: @MainActor (BrowserWorkSpaceStore.Space) -> Void
    let spacesIdentifier: String
    /// ＋（新增空間）照主視窗的位置擺著、按不下去：說明寫在哪裡新增。
    let addSpaceOff: String
    /// 側欄上開著東西（下載清單）＝借用那一邊把它的側欄留著（主視窗是 store.sidebarInteractionActive）。
    let interaction: @MainActor (Bool) -> Void
    /// 尺寸自適應（spec 184 G2d：「小框側欄緊湊擺法」）：側欄很矮（小框＋最高的連線卡）＝最下面那一排（下載、空間圓點、＋）
    /// 跟著列表一起捲、排在列表最後（同一排、同一個順序），列表才留得下捲動的地方。
    var compact = false
    /// 自測的量尺（正式＝nil）。
    var mark: (@MainActor (String) -> AnyView)? = nil
}

extension View {
    /// W184 G2d：只在條件成立時才掛的東西（主視窗才有的右鍵選單、拖放；借用那一邊按不下去的＋）。
    @ViewBuilder
    func browserSidebarWhen<Changed: View>(_ condition: Bool, @ViewBuilder _ change: (Self) -> Changed) -> some View {
        if condition { change(self) } else { self }
    }
}
