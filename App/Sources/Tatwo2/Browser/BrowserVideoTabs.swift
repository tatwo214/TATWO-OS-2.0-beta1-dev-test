import Combine
import Foundation

/// W184 E（使用者 09-29：「倒放 預設作為影片子畫面」；spec E；spike 報告 rooms/w183-handoff/w184-e-spike-report.md）：
/// 哪些分頁現在有 <video> 在播、這一次什麼時候開始播的。來源是原生端既有的分頁活動回報多出的一個布林
/// （TatwoCEFBrowserView.onVideoPlayingChange：只給使用者本人的頁面、不帶網址或內容）。
/// 倒放（影片子畫面）靠它挑分頁：最近開始播的優先；倒放是空狀態時，新開始播的才自動收進來。
@MainActor
final class BrowserVideoTabs: ObservableObject {
    static let shared = BrowserVideoTabs()
    /// 分頁 id → 這一次開始播影片的時間（沒在播＝不在表裡）。
    @Published private(set) var startedAt: [String: Date] = [:]
    /// 有分頁從「沒在播」變成「在播」時送出它的 id（時間已經記好）。
    let starts = PassthroughSubject<String, Never>()
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    func set(_ tabID: String, playing: Bool) {
        if playing {
            guard startedAt[tabID] == nil else { return }
            startedAt[tabID] = clock()
            starts.send(tabID)
        } else if startedAt[tabID] != nil {
            startedAt[tabID] = nil
        }
    }

    /// 分頁關閉或睡著時原生 view 直接消失，不會再回報一次 false。
    func forget(_ tabID: String) {
        if startedAt[tabID] != nil { startedAt[tabID] = nil }
    }

    func isPlaying(_ tabID: String) -> Bool { startedAt[tabID] != nil }
}
