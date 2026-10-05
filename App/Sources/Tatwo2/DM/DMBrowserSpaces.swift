import Foundation
import SwiftUI

// W184 G2（使用者 09-29：「browser的下方改右側好了 並且缺乏目前browser space的書籤、珍藏、switch功能，試圖收納進去。」）：
// 私訊框 Browser 的直欄收進 Browser space 的書籤、珍藏、切換空間。
// - 資料一律是主視窗側欄那一份：共用的分頁清單（BrowserTabRegistry）＋主視窗 Browser space 的 store（目前空間、書籤資料夾的投影、
//   BrowserBookmarkRows／BrowserFavoritesStrip／BrowserSpaceDot 讀的同一個）。主視窗打開時由 ChatPage 交過來（adopt）；
//   還沒打開（或這台只開了私訊框）＝私訊框自己留一份（同一份分頁清單），主視窗交過來時照私訊框選的空間切一次，之後以主視窗為準。
// - 私訊框這邊只讀＋開啟：不改名、不刪、不搬、不存書籤與珍藏（在主視窗做）；開＝私訊框 Browser 開新分頁（DMBrowser.openBrowse）。
// - 切換空間＝叫那個 store 的 selectSpace（跟在主視窗側欄點圓點一樣），書籤跟著換；珍藏在資料上是全域一排（主視窗每個空間都是同一排），
//   私訊框跟主視窗一樣顯示同一排。

/// 私訊框 Browser 看的「Browser space」：用哪一個 store（主視窗的那一份，沒有就自己留一份）。
@MainActor
final class DMBrowserSpaces: ObservableObject {
    static let shared = DMBrowserSpaces(registry: .shared)

    let registry: BrowserTabRegistry
    /// 主視窗 Browser space 的 store（ChatPage 交過來；weak：視窗關掉、store 放掉就沒了）。
    private weak var adopted: BrowserWorkSpaceStore?
    /// 主視窗還沒交 store 過來時自己留的一份（同一份分頁清單）。
    private var own: BrowserWorkSpaceStore?
    /// 主視窗還沒交過來時在私訊框最後一次選的空間（交過來時照它切一次）。W184 G2d（GPT-6 審查 G2d #4）：側欄的空間圓點
    /// （主視窗那一顆 BrowserSpaceDot）點下去交給 select(registryID:)，記下使用者的選擇——不從最後的狀態反推有沒有選過
    /// （A→B→A 也是選了 A）。
    private var chosenAlone: UUID?

    /// store 只給自測換（正式＝主視窗交過來的那一份）。
    init(registry: BrowserTabRegistry, store: BrowserWorkSpaceStore? = nil) {
        self.registry = registry
        if let store { adopt(store) }
    }

    /// 主視窗 Browser space 的 store 交過來（ChatPage 出現時）。只收同一份分頁清單的（聊天旁瀏覽器、自測的另一份不收）。
    func adopt(_ store: BrowserWorkSpaceStore) {
        guard store.registry === registry, adopted !== store else { return }
        let chosen = adopted == nil ? chosenAlone : nil   // 最後在私訊框選的那一個
        adopted = store
        own = nil
        chosenAlone = nil
        if let chosen, let space = store.spaces.first(where: { $0.registryID == chosen }) { store.selectSpace(space.id) }
        objectWillChange.send()
    }

    /// 現在用的 store：主視窗那一份；沒有＝自己留一份。
    var store: BrowserWorkSpaceStore {
        if let adopted { return adopted }
        if let own { return own }
        let made = BrowserWorkSpaceStore(registry: registry)
        own = made
        return made
    }

    /// 主視窗的 store 交過來了沒（自測看）。
    var isAdopted: Bool { adopted != nil }

    /// 切換空間：跟在主視窗側欄點圓點一樣（同一個 store 的 selectSpace）；書籤跟著換。W184 G2d：側欄的空間圓點點下去走這裡
    /// （BrowserSpaceDot 的 choose）；主視窗還沒交 store 過來＝記下這一次選的（交接時照它切一次）。
    /// W184 G2 修正（GPT-6 5）：用空間的 registryID（UUID）在「當下」的 store 重新找——store 的整數 ID 是各自視窗的別名，
    /// 接管前後同一個數字可能指到別的空間，所以不跨 store 傳整數；找不到（已刪）＝不切、回 false。
    @discardableResult
    func select(registryID: UUID) -> Bool {
        let target = store
        guard let space = target.spaces.first(where: { $0.registryID == registryID }) else { return false }
        target.selectSpace(space.id)
        if adopted == nil { chosenAlone = registryID }
        return target.selectedSpace.registryID == registryID
    }
}

/// 打的字、書籤、珍藏的網址 → 私訊框 Browser 要開的網址（只開 https）。
enum DMBrowserBrowseInput {
    /// 打的字：網址（沒寫協定＝https）、其他＝用 Browser 設定的搜尋引擎搜尋（同主視窗的網址列 BrowserOmniboxResolver）；
    /// http 一律改 https；javascript:、file:、data:、帶帳密的網址一律不開（nil）。
    static func resolve(_ text: String, engine: BrowserSearchEngine) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = BrowserOmniboxResolver.resolve(trimmed, engine: engine) else { return nil }
        return secured(url)
    }

    /// 書籤、珍藏的網址：https 照開；http 改 https；其他協定、沒有網域、帶帳密＝nil（這一條在私訊框開不了）。
    static func secured(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        if scheme == "http" {
            parts.scheme = "https"
            if parts.port == 80 { parts.port = nil }
        }
        return parts.url.flatMap(DMBrowser.browseStart)
    }

    /// 分頁名字：搜尋＝「搜尋：…」；網址＝網域。
    static func title(for text: String, url: URL, engine: BrowserSearchEngine) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let search = secured(engine.queryURL(trimmed)), search.absoluteString == url.absoluteString { return "搜尋：\(trimmed)" }
        return url.host ?? trimmed
    }
}
