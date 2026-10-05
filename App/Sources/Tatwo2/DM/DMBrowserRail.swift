import AppKit
import SwiftUI

// W184 G2（使用者 09-29：「browser的下方改右側好了 並且缺乏目前browser space的書籤、珍藏、switch功能，試圖收納進去。」）：
// 書籤、珍藏點下去怎麼開，與開不了時的那一句話。
// W184 G2d（使用者 09-30：「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：側欄上的珍藏、書籤、空間圓點改用
// 主視窗 Browser space 的元件（BrowserFavoritesStrip、BrowserBookmarkRow、BrowserSpaceDot，見 DMBrowserChrome），這裡只留開法：
// - 只讀＋開啟：書籤、珍藏點一下＝私訊框 Browser 開**新分頁**（DMBrowser.openBrowse；同一個書籤、珍藏已經有自己的分頁＝切過去），
//   絕不在 Pod、配對、授權分頁裡導航；改名、刪除、搬移在主視窗做。

/// 書籤、珍藏點下去怎麼開（畫面與自測走同一條）。
@MainActor
enum DMBrowserShelf {
    /// 書籤：網址照開（http 改 https；其他協定不開）；同一個書籤已經開著＝切過去。
    static func open(bookmark: BrowserWorkSpaceStore.Bookmark, in browser: DMBrowser) -> DMBrowserBrowseResult {
        guard let url = URL(string: bookmark.url).flatMap(DMBrowserBrowseInput.secured) else { return .refused(.notSecure) }
        return browser.openBrowse(url: url, title: bookmark.title, origin: .bookmark(bookmark.id))
    }

    /// 珍藏：同網址已經開著（一般分頁）＝切過去；不然開新分頁。
    static func open(favorite: BrowserFavorite, in browser: DMBrowser) -> DMBrowserBrowseResult {
        guard let url = DMBrowserBrowseInput.secured(favorite.url) else { return .refused(.notSecure) }
        return browser.openBrowse(url: url, title: favorite.title, origin: .favorite(favorite.id))
    }

    /// W184 G2d（主導 09-30：側欄要有主視窗那一段「📌 Pinned」）：Pinned 底下那一列＝主視窗釘選的分頁——私訊框開它的網址
    /// （同書籤：http 改 https、別的協定與空白頁不開；開私訊框自己的一般分頁，不動主視窗那一個）；同一列再按＝切過去。
    static func open(pinned tab: BrowserWorkSpaceStore.Tab, in browser: DMBrowser) -> DMBrowserBrowseResult {
        guard let id = tab.registryID, let url = URL(string: tab.url).flatMap(DMBrowserBrowseInput.secured) else { return .refused(.notSecure) }
        return browser.openBrowse(url: url, title: tab.title, origin: .pinned(id))
    }
}

/// 一句話（打不開、分頁滿了）＋最多一顆鈕（分頁滿了＝「所有分頁」）。W184 G2d：浮在頁面頂上（DMBrowserPane 的小標那一疊）。
struct DMBrowserRailNote: View {
    let refusal: DMBrowserBrowseRefusal
    let showTabs: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(refusal.line)
                .font(.system(size: DMPhone.TextSize.footnote))
                .foregroundStyle(LiquidGlassTokens.loopsCaution)
                .fixedSize(horizontal: false, vertical: true)
            if refusal == .full || refusal == .browseFull {
                GlobalDMChipButton(title: "所有分頁", action: showTabs)
                    .accessibilityIdentifier("tatwo.dm.browser.note.tabs")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.browser.note")
    }
}
