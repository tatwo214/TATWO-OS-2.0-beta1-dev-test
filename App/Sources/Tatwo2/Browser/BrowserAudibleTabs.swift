import Combine
import Foundation

/// W112（使用者 2026-09-20：「音樂播放時icon要出現音符小動態」）：哪些分頁現在真的在出聲。
/// 來源是原生端既有的分頁活動回報（只多一個布林，不帶網址或內容）。
@MainActor
final class BrowserAudibleTabs: ObservableObject {
    static let shared = BrowserAudibleTabs()
    @Published private(set) var ids: Set<String> = []
    /// W176（使用者 2026-09-24：「spotify播放時缺少youtube的icon音符效果」）：聲音不從分頁出來、由 OS 代播的網站
    /// （Spotify 由 TATWO OS 裝置播）。播放中時這個網站的分頁與釘選也畫音符。
    @Published private(set) var playingElsewhere: Set<String> = []

    func setPlayingElsewhere(host: String, _ playing: Bool) {
        if playing { playingElsewhere.insert(host) } else { playingElsewhere.remove(host) }
    }

    func set(_ tabID: String, audible: Bool) {
        if audible { ids.insert(tabID) } else { ids.remove(tabID) }
    }
    /// 分頁關閉時原生 view 直接消失，不會再回報一次 false。
    func forget(_ tabID: String) { ids.remove(tabID) }

    func isAudible(host: String?, in registry: BrowserTabRegistry) -> Bool {
        guard let host, !host.isEmpty else { return false }
        if playingElsewhere.contains(host) { return true }
        guard !ids.isEmpty else { return false }
        return registry.tabs.contains { ids.contains($0.id.uuidString) && $0.url?.host == host }
    }
}
