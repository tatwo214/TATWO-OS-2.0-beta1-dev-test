import Foundation

// W183 R8 接口（主導）：ChatGPT build 的畫面（R8a）與後端（R8c）之間唯一的入口；規格 docs/specs/183-chatgpt-hands/chatgpt-build.md。
// - R8a：節點流程與面板只讀這裡的值、只叫這裡的動作；先寫一個實作 `HandsBuildModeling` 的 adapter，把現有單主機的流程
//   （HandsSetup、HandsRemoteClient、HandsConnectFlow、HandsState、CloudflareAccountsStore）接上來。
// - R8c：換成多主機（主設備存設定、每台自己當主機）時只改 adapter 裡面，名字與語意不改。

/// 節點右上角的標記。
enum HandsBuildNodeState: String, Sendable, Equatable {
    /// 完成（綠勾）。
    case done
    /// 等你（橘「!」）：這個節點要使用者選或按。
    case waiting
    /// 進行中（App 自己在做；轉圈）。
    case working
    /// 沒選、或前面還沒好（灰）。
    case off
    /// 出錯（紅）：一句話在 `problem`。
    case failed
}

struct HandsBuildDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let isPrimary: Bool
    let isThisDevice: Bool
    /// 使用者勾了這台（ChatGPT build 要在這台跑）。
    var selected: Bool
    var state: HandsBuildNodeState
    /// 這台的子網域標籤（主設備預設 os-for-chatgpt）。
    var subdomain: String
    /// 這台的服務網址（通道建好才有）。
    var url: String?
    /// 這台的 ChatGPT 連線狀態（連接器「TATWO（<名稱>）」）。
    var connection: HandsBuildNodeState
}

struct HandsBuildZone: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let accountName: String
}

struct HandsBuildProject: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    var selected: Bool
    /// W183 R8c：這個專案在哪一台（專案是那台自己的：(deviceID, projectID)）。nil＝舊的單主機 adapter。
    var deviceID: String? = nil
    /// W183 R8 整合審查（Claude 中）：那台回報現在真的允許（本機核准 ∩ 中央上限）；selected 是中央上限勾了。nil＝還沒回報（不知道）。
    /// W183 R10：專案全部可見（selected 一律 true、面板只顯示）；active 留著相容。
    var active: Bool? = nil
    /// W183 R10 底線 B：交易實盤類（ChatGPT 只能看：面板標「只能看」；擋在主機）。
    var readOnly: Bool = false
}

/// 畫面看的全部東西＋畫面能叫的全部動作。每個動作都是「使用者在原生畫面按的」（AI 工具不經過這裡）。
@MainActor
protocol HandsBuildModeling: AnyObject {
    var enabled: Bool { get }
    /// 那一列的狀態 pill（短，例如「等你選設備」「已連線・L2」）。
    var statusText: String { get }
    var statusState: HandsBuildNodeState { get }
    /// 出錯時的一句話。
    var problem: String? { get }

    var gptState: HandsBuildNodeState { get }
    /// Pod 目前帳號（觀測值）。
    var podAccount: String? { get }
    var devices: [HandsBuildDevice] { get }
    var cloudflareState: HandsBuildNodeState { get }
    /// 已登入（環境登入 › Cloudflare 同一份）的帳號裡的網域。
    var zones: [HandsBuildZone] { get }
    var selectedZoneID: String? { get }
    var devState: HandsBuildNodeState { get }
    /// 0…2。
    var level: Int { get }
    var projects: [HandsBuildProject] { get }

    func setEnabled(_ on: Bool)
    func setDevice(_ id: String, selected: Bool)
    /// 登入 Cloudflare（授權頁開在這台私訊框的 Browser 分頁）；只是登入，不綁網址。
    func loginCloudflare()
    func chooseZone(_ id: String)
    func setSubdomain(_ label: String, for deviceID: String)
    /// 照選好的網域與子網域建通道與 DNS（按了才建）。
    func applyURLs()
    func setLevel(_ level: Int)
    func setProject(_ id: String, selected: Bool)
    /// ［連線］：nil＝所有勾選的設備；否則那一台。
    func connect(deviceID: String?)
    /// W183 R8c：替指定的那台登入 Cloudflare（人在這台，授權存那台；登入網址只回到這台的私訊框）。
    func loginCloudflare(for deviceID: String)
    /// W183 R8c：使用者明確解除那台的安全停機鎖（重新勾選、重開、同步都不會解除）。
    func unlockSafety(for deviceID: String)
    /// W183 R8c 審查（Claude 中）：畫面打開了（後端一陣子內同步快一點；平常不熱問）。
    func viewDidAppear()
}

/// W183 R8c：接口只加不改——舊的單主機 adapter 沒有多設備，這幾個照舊（只做這台）。
extension HandsBuildModeling {
    func loginCloudflare(for deviceID: String) { loginCloudflare() }
    func unlockSafety(for deviceID: String) {}
    func viewDidAppear() {}
}
