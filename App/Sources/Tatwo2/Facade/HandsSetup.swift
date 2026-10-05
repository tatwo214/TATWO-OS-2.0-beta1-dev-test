import AppKit
import Combine
import Darwin
import Foundation

// W183 R3：ChatGPT 手腳的「標準設定流程」（spec「標準流程：AI 全程處理」；使用者 09-27「這個設定步驟請設成自動化 不用是開始使用
// 但是os內建必須有標準流程 讓使用者要用的時候ai能全程處理到好」「好 主機定mini 這邊也要讓使用者初始設定時勾選」）。
//
// - 照步驟跑，每一步都有結果與白話錯誤；可以重跑單一步、可以中斷、下次接著做（狀態存在 app/setup.json，0600，沒有任何秘密）。
// - 使用者親自按的只有兩步：Cloudflare 授權（OS 瀏覽器按一下）、配對碼（ChatGPT 跳出的 TATWO 頁面輸入一次）。其他 AI 都能做。
// - 觸發：TAP › ChatGPT 打開開關（畫面），或對 TATWO 助理說要開（OS 工具 hands_setup_status／hands_setup_step）。不放「開始使用」。
// - 金鑰界線（憲法 §8 第 2 條）：授權憑證與通道 token 只進鑰匙圈（CloudflareKeychain）；用時才以 0600 暫存檔交給 cloudflared、用完刪；
//   不進 argv、環境、日誌、狀態檔、工具回傳。AI 讀不到。不碰 ~/.cloudflared、不碰既有的任何通道與 DNS 紀錄（只新增、不覆蓋）。
// - 助理叫開、開關原本是關的：先在 Island 問使用者一次（對外開一個網址，有疑問選更嚴的做法）。
// - 「開始配對」只能由使用者在 App 按（T15）：OS 工具不能開配對窗口。
// W183 R3 審查修正：
// - staging／自測：設定的每個副作用（cloudflared、下載、Cloudflare API、鑰匙圈、改設定）都拒絕，不只關口（Dependencies.live）。
// - App 當掉：看門程式收掉 cloudflared 並清檔；App 重開先收掉上次沒結束的那一組、清暫存檔，清不掉就擋住不准做。
//   取消要等舊指令真的結束才清檔、才准重跑（lingering）。
// - 登入完自動接著做的意圖綁在流程世代上：關掉、取消之後再登入不會自己打開；接著做前再看一次開關是不是還開著。
// - 流程進行中不准換網域、換主機、移除帳號；建通道每一步發布前再核對帳號與網域沒變。
// - 一次只有一台主機：換主機要原主機交出（主設備記著現在是哪一台；見 HandsHostAuthority），確認不到就不開。
// - 給 AI 的狀態不帶 Cloudflare 帳號名稱與 id（畫面才有）。
// W183 R3b 審查修正（GPT-6／Claude）：
// - 授權完先「等你確認帳號與網域」（第 3 步停在等你按；確認綁這一輪的授權：確認碼＋畫面上看到的網域）：確認前不建通道、不改 DNS、
//   不啟動；網域名稱查不到就不能確認（先再查一次）。每一次在瀏覽器登入都要確認（unconfirmedZoneIDs）。
// - 授權網址開成瀏覽器的「敏感分頁」（只在記憶體、不進 tabs.json／最近關閉／封存／瀏覽紀錄），流程結束就關掉。
// W183 R5b（使用者 09-28「在這台開啟授權頁面改成自動跳轉與小視窗 不要跳去browser分頁 這樣會中斷使用者思緒 改用私訊鈕跳轉？」
// 「私訊鈕的UI邏輯 一率當成手機做搭建」）：授權頁改在私訊框裡開（手機 App 的內嵌瀏覽器，DM/GlobalDMWebSheet.swift）：
// 自動打開私訊框、頁面滑出；不關設定浮層、不切 Browser、不跳頁；流程結束（closeLoginPages）頁面滑回去、私訊框回原狀。
// 誰按的在誰那台開：副設備經簽章 RPC 按的（trigger .remote）主機不在自己的畫面開（主機螢幕不被劫持、不留敏感頁），副設備自己開。
// 私訊鈕總開關關掉才退回舊的敏感分頁。
// - 取消發生在查帳號名稱時：不收憑證（收了也回滾這一輪新增的）；第 5 步寫「打開」跟取消、交出主機是同一把鎖下的判斷，舊流程不會把關掉的又打開。
// - 「取消並重新授權」的清除記在 discard（冪等，失敗可以重按）；清完之前一般的「繼續」不會重新採用那個授權；這一輪的通道 token 一起刪。
// - 給 AI 的狀態不帶網域與對外主機名（只有關口起來後的 MCP 連線網址 url，給助理代填 ChatGPT 用）。
// W183 R6a（一個開關；docs/specs/183-chatgpt-hands/one-switch.md；使用者 09-28「到目前為止的流程我非常不滿意 太複雜」→「先停，重做成一個開關」）：
// - TAP 的開關＝runAll(allowLogin: true)（跟副設備遠端開始一樣）：沒登入 Cloudflare 就直接在私訊框開授權頁，不再導去環境登入。
// - 走到配對＝叫 HandsConnectFlow.offer()（私訊框的［連線］卡；R6b 實作），不再有「開始配對」、不自己開配對窗口；
//   副設備按的（.remote）由副設備自己 offer；關開關、換主機＝HandsConnectFlow.cancel(reason:)。
// - 主機 App 重開、開關開著＝自動續跑（.resume）：只恢復通道、關口、既有 grant——不開授權頁、不叫「重試」
//   （安全停機的人工重試鎖不解除）、不 offer、不開配對窗口。
// - 固定子網域（09-28 使用者「不要隨機子網域 固定加os-for-chagpt」）：網址固定是 `<標籤>.<網域>`（標籤預設 os-for-chatgpt，設定值）；
//   已經有別的紀錄＝停下說明（不覆蓋、不換名字）；以前的隨機子網域自動遷移，最後只刪狀態裡記的那一筆（而且確認是指向這條通道的 CNAME）。
// - 副設備當了主機、關開關＝交回主設備；交回不成功那一列給「交回主設備」（開關開沒開都可以按）。
// - 「詳細」裡的沒用到的 TATWO 通道（tatwo-hands- 開頭、沒有連線、不是目前在用的）：列出、確認後才刪；走同一套沙盒與看門程式。
// W183 R6a 審查（GPT-6／Claude 十七條）：
// - 換主機要使用者在卡片內按「確定」才做（後端的一次性請求，綁原主機、目標、流程世代、期限）；助理（AI）與遠端只能提出。
// - 交回主設備之前「關」要確定存進磁碟、關口停了；副設備重開後要先問主設備「主機還是這台嗎」才起關口（HandsHostLease）。
// - 自動續跑不換帳號與網域、不遷移網址；遷移時已經連上的 ChatGPT 連線作廢（連接器還指著舊網址），由使用者按［連線］重新連。
// - 刪舊紀錄之前跟 Cloudflare 與鑰匙圈核對（通道是現在這條、Cloudflare 上的名字是 tatwo-hands-、新網址從外面連得到是 TATWO 的關口），刪之前再查一次。
// - 沒用到的通道：被這個網域 DNS 指到的不列；每一條刪之前都再查一次。

enum HandsSetupStep: String, CaseIterable, Codable, Sendable, Identifiable {
    case host, cloudflared, authorize, tunnel, start, url, pairing, remember

    var id: String { rawValue }
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var title: String {
        switch self {
        case .host: "選主機"
        case .cloudflared: "準備 cloudflared"
        case .authorize: "授權 Cloudflare（你按一下）"
        case .tunnel: "建通道與固定網址"
        case .start: "啟動關口"
        case .url: "網址給 ChatGPT"
        case .pairing: "連線（私訊框按［連線］）"
        case .remember: "記住帳號與網域"
        }
    }

    /// 要使用者親自按的兩步（其餘 AI 都能做）。
    var needsUser: Bool { self == .authorize || self == .pairing }

    /// 一次跑完時的順序：「記住」在網址準備好就做，不用等配對；配對最後（等使用者）。
    static let runOrder: [HandsSetupStep] = [.host, .cloudflared, .authorize, .tunnel, .start, .url, .remember, .pairing]
}

enum HandsSetupStatus: String, Codable, Sendable, CaseIterable {
    case pending, running, waitingUser = "waiting_user", done, failed

    /// W183 R3b：畫面上的中文（兩台一樣；給 AI 的工具回傳照舊用英文代碼）。
    var label: String {
        switch self {
        case .pending: "等待中"
        case .running: "進行中"
        case .waitingUser: "等你按"
        case .done: "完成"
        case .failed: "失敗"
        }
    }

    /// 副設備收到的是代碼字串：認得就轉中文，不認得（新版主機多了新狀態）寫「未知」，不把英文代碼放上畫面。
    static func label(forCode code: String) -> String { HandsSetupStatus(rawValue: code)?.label ?? "未知" }
}

struct HandsSetupStepState: Codable, Equatable, Sendable {
    var status: HandsSetupStatus = .pending
    var message: String = ""
    var updatedAt: Date?
    enum CodingKeys: String, CodingKey { case status, message, updatedAt = "updated_at" }
}

/// `app/setup.json`：只有步驟狀態與不是秘密的 id（設備、帳號、網域、通道、網址）。
struct HandsSetupState: Codable, Equatable, Sendable {
    var steps: [String: HandsSetupStepState] = [:]
    var hostDeviceID: String?
    var accountID: String?
    var zoneID: String?
    var domain: String?
    var tunnelID: String?
    var tunnelName: String?
    var publicHost: String?
    /// 鑰匙圈裡的通道 token 是哪一條通道的（只有 id）。換帳號、換網域都不清掉：token 換掉之前它都還是那一條的
    /// （移除帳號時靠它認出「正在用的通道」；W183 R3 審查）。
    var tokenTunnelID: String?
    var cloudflaredSource: String?
    var updatedAt: Date?
    /// W183 R3b：最近一次在瀏覽器登入拿到的授權是哪個網域（只有 zone id）。「取消並重新授權」只清這次登入拿到的，
    /// 不動使用者之前在環境登入加好的帳號。
    var loginZoneID: String?
    /// W183 R3b 審查：在瀏覽器登入拿到、使用者還沒在畫面確認帳號與網域的（只有 zone id）。這些不建通道、不改 DNS、不啟動、不自動採用。
    var unconfirmedZoneIDs: [String]?
    /// 綁這一輪授權的確認碼（不是秘密：只防「按的是舊的那一輪」）；只給畫面與設備簽章通道，不給 AI。
    var confirmToken: String?
    /// 「取消並重新授權」還沒清完的那一筆（冪等：失敗可以重按，清完才拿掉）。
    var discard: HandsSetupDiscard?
    /// W183 R5（實機＋GPT-6 審查）：每個帳號正要建的通道（名字＋記下的時間；建之前先確定寫進磁碟）。Cloudflare 建好了、App 卻沒讀到 id 時，
    /// 重跑先用名字找回來（建立時間要晚於記下的時間才認），不另外再建一條；換帳號不會丟掉別的帳號還沒解決的那一筆。
    var pendingTunnels: [String: HandsPendingTunnel]?
    /// W183 R6a：隨機子網域 → 固定子網域：要刪的那一筆舊紀錄（TATWO 自己建的；名稱、網域 id、它指向的通道）。
    /// 加新紀錄之前先寫進磁碟；新的確認好、關口用新網址起來了才刪；刪完（或確定已經不在、不是我們的）才拿掉。
    var retiredHost: HandsRetiredHost?
    /// W183 R8c（GPT-6 必改 6）：這台自己建的通道（id；建立證據）。「沒用到的通道」只列這裡面的，別台的、沒證據的一律不列、不刪。
    var createdTunnels: [String]?
    /// W183 R8c 審查（GPT-6 中）：這台確定已經釋放的網址（舊紀錄刪掉了、或查過確定已經不在）：主設備的所有權表只憑這個拿掉那一筆。
    var releasedHosts: [String]?

    enum CodingKeys: String, CodingKey {
        case steps
        case hostDeviceID = "host_device_id", accountID = "account_id", zoneID = "zone_id", domain
        case tunnelID = "tunnel_id", tunnelName = "tunnel_name", publicHost = "public_host", tokenTunnelID = "token_tunnel_id"
        case cloudflaredSource = "cloudflared_source", updatedAt = "updated_at", loginZoneID = "login_zone_id"
        case unconfirmedZoneIDs = "unconfirmed_zone_ids", confirmToken = "confirm_token", discard
        case pendingTunnels = "pending_tunnels"
        case retiredHost = "retired_host"
        case createdTunnels = "created_tunnels"
        case releasedHosts = "released_hosts"
    }

    /// W183 R8c：這台有建立證據的通道（建過的、現在用的、鑰匙圈 token 那一條）。
    var tunnelEvidence: Set<String> {
        Set(((createdTunnels ?? []) + [tunnelID, tokenTunnelID].compactMap { $0 }).map { $0.lowercased() })
    }

    func step(_ step: HandsSetupStep) -> HandsSetupStepState { steps[step.rawValue] ?? HandsSetupStepState() }

    /// 這個網域還沒確認。
    func isUnconfirmed(_ zoneID: String?) -> Bool {
        guard let zoneID else { return false }
        return unconfirmedZoneIDs?.contains(zoneID) ?? false
    }

    /// 目前選的網域在等使用者確認。
    var awaitingConfirmation: Bool { discard == nil && isUnconfirmed(zoneID) }
}

/// W183 R5：建之前記下的通道名字與時間（不是秘密）。
struct HandsPendingTunnel: Codable, Equatable, Sendable {
    var name: String
    var since: Date
}

/// W183 R6a：遷移時要刪的舊紀錄（不是秘密）。
struct HandsRetiredHost: Codable, Equatable, Sendable {
    var host: String
    var zoneID: String
    var tunnelID: String
    /// W183 R8c 審查（Claude 高）：按「套用」換子網域時，舊的是這台自己建的固定網址（`<舊標籤>.<網域>`；不是隨機格式）。
    /// 一樣要核對「只有一筆、CNAME、指向這條通道」才刪。
    var fixed: Bool? = nil

    enum CodingKeys: String, CodingKey { case host, zoneID = "zone_id", tunnelID = "tunnel_id", fixed }
}

/// W183 R3b 審查：「取消並重新授權」要清的那一筆（先記下來再清；清到一半失敗，重按會照這筆接著清）。
struct HandsSetupDiscard: Codable, Equatable, Sendable {
    var accountID: String
    var zoneID: String
    /// 是這一輪在瀏覽器登入拿到的（要刪這個網域的授權）；沿用環境登入原本就有的＝不刪，只是不用。
    var fromLogin: Bool
    /// 鑰匙圈裡的通道 token 是這個帳號的通道（要一起刪）。
    var tokenTunnelID: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id", zoneID = "zone_id", fromLogin = "from_login", tokenTunnelID = "token_tunnel_id"
    }
}

/// W183 R3b：畫面（兩台）上「已授權／請確認／沒清完」那一列要的資料。帳號名稱與確認碼只給畫面與設備簽章通道，不給 AI。
struct HandsAuthorizationSummary: Equatable, Sendable {
    let account: String
    let domain: String?
    /// 第 3 步在等使用者確認這個帳號與網域。
    let needsConfirm: Bool
    let confirmToken: String?
    /// 上次「取消並重新授權」沒清完（畫面給「重按一次」）。
    let cleanupPending: Bool
}

struct HandsSetupDevice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let isPrimary: Bool
    let isThisDevice: Bool
}

/// W183 R8c 審查（GPT-6 高／中）：使用者按「套用」當下拍下的那一份（不變）：帳號、網域、子網域、主機名、撤銷世代。
/// 選網域與佔用工作槽是同一個原子操作；建通道、改 DNS、起關口之前都再核一次（設定改過、被關過＝這一輪不做）。
struct HandsApplyPlan: Equatable, Sendable {
    var accountID: String
    var zoneID: String
    var subdomain: String
    var hostname: String
    var revocationGeneration: Int
}

/// W183 R8c：信箱替別台登入的結果（交回擁有者；沒有任何秘密：帳號名稱與網域名稱只給畫面）。
enum HandsLoginOutcome: Equatable, Sendable {
    case authorized(account: String, zones: [String])
    case failed(String)
    case cancelled
    case busy
}

/// W183 R5b：remote＝副設備經設備簽章 RPC 按的（開始、繼續、重新授權）：授權頁只在按的那台開，主機不在自己的畫面開。
/// W183 R6a：resume＝主機 App 重開、開關開著時的自動續跑（只到通道、關口、既有 grant）。
enum HandsSetupTrigger: String, Sendable { case user, assistant, remote, resume }

/// W183 R3b：「取消並重新授權」做不了的原因（副設備經簽章 RPC 收到的是代碼，畫面再轉回白話）。
enum HandsReauthorizeRefusal: String, Error, CaseIterable, CustomStringConvertible {
    case notAuthorized = "reauthorize_not_authorized", paired = "reauthorize_already_paired", busy = "reauthorize_setup_busy"
    var description: String {
        switch self {
        case .notAuthorized: "還沒有授權可以取消（第 3 步還沒拿到授權）"
        case .paired: "已經配對了：要換 Cloudflare 帳號，先在 TAP › ChatGPT「全部撤銷」，再到「設定 › 環境登入 › Cloudflare」移除這個帳號"
        case .busy: "設定進行中；等這一輪做完（或先按「取消」）再按「取消並重新授權」"
        }
    }
}

/// W183 R3b 審查：「是這個，繼續」（確認授權的帳號與網域）做不了的原因。
enum HandsConfirmRefusal: String, Error, CaseIterable, CustomStringConvertible {
    case stale = "confirm_stale", changed = "confirm_domain_changed", busy = "confirm_setup_busy"
    var description: String {
        switch self {
        case .stale: "這個授權已經換過了（或已經確認過）；看一下畫面上的帳號與網域再按"
        case .changed: "網域跟畫面上的不一樣了；看一下畫面上的帳號與網域再按"
        case .busy: "設定進行中；等這一輪做完再按"
        }
    }
}

/// W183 R6a 審查（GPT-6「換主機確認只擋 UI」）：換主機的請求（後端記著；畫面出卡片內確認列，使用者按「確定」才換）。
/// 一次性、綁提出時的主機（from）、目標（to）、流程世代（epoch）、期限；助理（AI）提出的也一樣要使用者按。不是秘密。
struct HandsHostChangeRequest: Equatable, Sendable {
    let token: String
    let from: String?
    let to: String
    let epoch: String
    let expiresAt: Date
    let byAssistant: Bool
}

/// 設定流程的錯（畫面與工具看得到的白話）。
enum HandsSetupError: Error, Equatable, CustomStringConvertible {
    case busy, isolated
    var description: String {
        switch self {
        case .busy: "設定進行中；等這一輪做完（或按「取消」）再改"
        case .isolated: HandsSetup.isolatedMessage
        }
    }
}

/// 隔離環境（staging／自測／source test）裡的 cloudflared：一律不開（W183 R3 審查：設定的副作用都要擋，不只關口）。
final class HandsRefusingRunner: HandsCloudflaredRunning {
    func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL,
               onLine: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand {
        throw HandsSetupError.isolated
    }
}

/// 跨執行緒的小盒子（讀輸出的執行緒寫、流程的執行緒讀）。
final class HandsLocked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&value); lock.unlock() }
}

final class HandsSetup: ObservableObject, @unchecked Sendable {
    static let shared = HandsSetup(dependencies: .live())

    static let isolatedMessage = "隔離測試環境（staging／自測）不跑 ChatGPT 手腳的設定流程：不開 cloudflared、不連 Cloudflare、不碰鑰匙圈"
    static let lingeringMessage = "上一個 cloudflared 設定指令還沒結束（已要求它停）；它結束、暫存檔清掉之前不能重跑，等一下再按「重試」"
    static let leftoverMessage = "清不掉上次留下的授權暫存檔（TATWO OS Hands/cf-setup）；清乾淨之前不能繼續。請檢查那個資料夾的權限後再按「重試」"
    /// W183 R6a：App 重開時跑到一半的步驟（開關開著會自動接著做；畫面顯示「準備中…」）。
    static let interruptedMessage = "上次中斷；開關開著會自動接著做"
    /// W183 R6a：走到配對（私訊框的［連線］卡；HandsConnectFlow）。
    static let pairingWaitingMessage = "等你在私訊框按［連線］（讓 ChatGPT 連上 TATWO；按一下就好，風險勾選與 8 碼由 TATWO 代做）"   // W183 R10
    /// W183 R8c（GPT-6 必改 4）：登入只是登入——登入完（或已經登入過）停在這裡，等使用者在 ChatGPT build 選網域、按「套用」。
    static let chooseDomainMessage = "已登入 Cloudflare：在 ChatGPT build 的 Cloudflare 節點選網域、按「套用」才會建網址（登入不會自己綁網址）"
    static let needsLoginMessage = "還沒登入 Cloudflare：在 ChatGPT build 的 Cloudflare 節點按「登入 Cloudflare」（或到「設定 › 環境登入 › Cloudflare」）；登入完選網域、按「套用」"
    /// W183 R6a：自動續跑遇到沒有可用的 Cloudflare 授權：不自己開授權頁，等使用者按「重新授權」。
    static let resumeNeedsLoginMessage = "Cloudflare 還沒授權：按「重新授權」（授權頁會在私訊框打開）"
    /// W183 R6a：固定的名字已經有別的紀錄：不覆蓋、不換名字，停下說明。
    static func fixedHostTakenMessage(_ host: String) -> String {
        "\(host) 已經有別的 DNS 紀錄；TATWO 不覆蓋、也不換名字（網址固定用這個）。確定那筆沒在用，就到 Cloudflare 後台刪掉它，再按「重試」"
    }
    static let fixedHostUnconfirmedMessage = "新網址的 DNS 紀錄確認不到（Cloudflare 沒回、或不是指向這條通道）；舊網址照用，按「重試」再試"
    /// W183 R6a 審查（Claude）：固定的名字指向這個帳號裡另一條 TATWO 通道（多半是另一台設備當主機時建的）。
    static func fixedHostOtherDeviceMessage(_ host: String) -> String {
        "\(host) 目前指向另一條 TATWO 通道（多半是另一台設備當主機時建的；網址固定，一次只有一台用得到）。TATWO 不覆蓋：要在這台用，先把主機換回原本那台，或到 Cloudflare 後台刪掉這筆紀錄再按「重試」"
    }
    /// W183 R6a 審查（GPT-6／Claude）：網址遷移時，已經連上的 ChatGPT 連線作廢（連接器還指著舊網址）。
    static func migratedMessage(_ host: String) -> String {
        "網址改成固定的 \(host)；舊的 ChatGPT 連線已作廢（連接器還指著舊網址），請在私訊框按［連線］重新連一次"
    }
    /// W183 R6a 審查（GPT-6）：換主機要使用者按（助理、遠端只能提出）。
    static let hostChangeNeedsConfirmMessage = "換主機要你在 TAP › ChatGPT 那一列下面按「換主機」確認（助理只能提出）"
    static let hostChangeLifetime: TimeInterval = 120
    /// W183 R6a 審查（GPT-6）：交回主設備之前「關」要存進磁碟、關口要停。
    static let handbackNotSavedMessage = "這台的設定存不進去（磁碟滿？）：已經在記憶體停下，但還不能交回主設備（重開 App 會以為自己還是主機）；空出空間後再按「交回主設備」"
    static let handbackStillRunningMessage = "這台的關口還沒停下來；等一下再按「交回主設備」"
    /// W183 R6a 審查（GPT-6）：副設備重開後問主設備（租約）。
    static let leaseUnreachableMessage = "太久連不到主設備（ChatGPT build 的設定過期）：這台先暫停（連線沒有撤銷），連得到主設備就會自己接著跑"
    static let leaseNotHostMessage = "ChatGPT build 沒有勾這台；這台不開。要用這台請在 TAP › ChatGPT 的設備節點勾這台"
    /// W183 R8c：沒有被選進 ChatGPT build（或總開關關著）。
    static let notSelectedMessage = "ChatGPT build 沒有勾這台（或總開關關著）：在 TAP › ChatGPT 的設備節點勾這台"
    /// W183 R8c：每台自己跑自己的（不再有「換主機」）。
    static let otherDeviceRunsItselfMessage = "每台設備自己跑自己的：要用那台，在 ChatGPT build 勾那台（那台自己建網址、自己連線）"
    /// W183 R8c：建網址（通道與 DNS）要使用者按「套用」；自動續跑與助理不新建。
    static let applyFirstMessage = "還沒建這台的網址：在 ChatGPT build 按「套用」（按了才建通道與 DNS）"
    /// W183 R8c 審查（GPT-6 高／中）：按「套用」之後設定改過、這台被關過（撤銷世代換了）、或不再勾這台：這一輪不建、不起。
    static let planChangedMessage = "按「套用」之後設定改過了（或這台被關掉）；這一輪不建網址。看一下畫面再按一次「套用」"
    /// W183 R7a：取消後那一步的訊息（按鈕名稱照畫面：授權那一步＝「重新授權」，其他＝「重試」）。
    static func cancelledMessage(_ step: String) -> String {
        step == HandsSetupStep.authorize.rawValue ? "已取消；按「重新授權」再做" : "已取消；按「重試」再做"
    }
    static let cloudflaredMissing = "cloudflared 驗不過（不見了或雜湊不對）；按「重試」重新下載固定版本"
    /// 第 3 步等使用者按（畫面看的；不含網址）。
    /// W183 R5b：授權頁在私訊框裡開（不再是 OS 瀏覽器的分頁）。
    static let authorizeWaitingMessage = "等你按授權：私訊框已打開 Cloudflare 授權頁（沒看到、或人在別台，就在那台的 TAP › ChatGPT 按「在這台打開授權頁」）；選要用的網域（要已付費、放在 Cloudflare），按「Authorize」"
    /// 同一步、副設備按的（主機不在自己的畫面開）。
    static let authorizeWaitingRemoteMessage = "等你在按開始的那台按授權：那台的私訊框會自動打開 Cloudflare 授權頁（在這台按也可以：按「在這台打開授權頁」）；選要用的網域，按「Authorize」"
    /// 同一步給 AI 的版本（W183 R3b：hands_setup_status 只說這一句；授權網址只在畫面與設備簽章通道）。
    static let aiAuthorizeWaiting = "等使用者在瀏覽器按授權"
    /// W183 R3b 審查：授權拿到了、等使用者在畫面確認帳號與網域（畫面看的；帳號與網域在旁邊那一列，不寫進訊息）。
    static let confirmWaitingMessage = "授權拿到了：看下面那一列的 Cloudflare 帳號與網域是不是你要的——是就按「是這個，繼續」；不是就按「取消並重新授權」。確認之前不會建通道、不會開任何網址"
    /// 同一步給 AI 的版本（不帶帳號與網域；AI 不能替使用者確認）。
    static let aiConfirmWaiting = "等使用者在畫面確認授權的 Cloudflare 帳號與網域（你看不到帳號與網域，也不能替他按）"
    /// 「取消並重新授權」清到一半失敗：擋住一般的「繼續」，只能重按。
    static let cleanupPendingMessage = "上次「取消並重新授權」還沒清完；排除原因（例如解鎖鑰匙圈）後再按一次「取消並重新授權」"
    /// 授權拿到了、但 Cloudflare 沒回網域名稱：不能確認（先再查一次）。
    static let namesUnknownMessage = "授權拿到了，但問不到網域名稱（網路？）；網域名稱出現之前不能確認。按「再查一次網域名稱」，或按「取消並重新授權」"
    /// 第 4 步以後遇到還沒確認的授權。
    static let confirmFirstMessage = "先確認授權的 Cloudflare 帳號與網域（按「是這個，繼續」）"

    /// staging／自測／source test：跟關口同一條判斷（ChatGPTHandsService.allowedToRun）。
    static func isolated(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !ChatGPTHandsService.allowedToRun(environment: environment)
    }

    struct Dependencies {
        var paths: HandsPaths
        var accounts: CloudflareAccountsStore
        var runner: HandsCloudflaredRunning
        /// device.json 的 deviceID（原樣，不改大小寫：HandsService.deviceAllowed 是精確比對）。
        var localDeviceID: () -> String?
        var devices: () -> [HandsSetupDevice]
        /// 主設備記著的主機（副設備才問主設備；主設備回 nil＝看自己的設定）。
        var authoritativeHost: () -> String? = { nil }
        /// 換主機（一次只有一台）：成功回 nil、做不到回白話原因。成功時已寫好這台設定的 host_device_id；
        /// 把主機交給別台時先停用這台（撤銷這台的連線）再通知主設備（HandsHostAuthority）。
        var transferHost: (_ target: String) -> String?
        /// 關掉開關之後：副設備是主機就通知主設備「這台不當主機了」。nil＝不用或成功。
        var releaseHost: () -> String? = { nil }
        var locateCloudflared: () -> HandsCloudflared.Location?
        var installCloudflared: (@escaping (Result<HandsCloudflared.Location, HandsCloudflared.Failure>) -> Void) -> Void
        var lookupZone: (_ zoneID: String, _ apiToken: String, _ done: @escaping (String?, String?) -> Void) -> Void
        /// 在這台打開 Cloudflare 授權頁（W183 R5b：私訊框的網頁頁面）。副設備按的（trigger .remote）不叫這個。
        var openURL: (URL) -> Void
        var loadSettings: () -> HandsSettings
        var updateSettings: (((inout HandsSettings) -> Void) throws -> Void)
        var startService: () -> Void
        /// 設定改了（例如移除帳號時關掉開關）：叫關口馬上看。
        var serviceChanged: () -> Void = {}
        var servicePhase: () -> ChatGPTHandsService.Phase
        var hasActiveGrant: () -> Bool
        var askApproval: (_ title: String, _ detail: String, _ done: @escaping (Bool) -> Void) -> Void
        var random: (Int) -> String = HandsSetup.randomLabel
        var loginTimeout: TimeInterval = 600
        var commandTimeout: TimeInterval = 90
        var serviceTimeout: TimeInterval = 90
        var approvalTimeout: TimeInterval = 90
        var downloadTimeout: TimeInterval = 900
        /// 取消後等舊指令真的結束（看門程式 2 秒後 SIGKILL cloudflared；App 5 秒後整組 SIGKILL）。
        var exitWait: TimeInterval = 8
        var pollInterval: TimeInterval = 0.25
        /// 問 Cloudflare 帳號與網域名稱最多等多久。
        var lookupTimeout: TimeInterval = 25
        /// W183 R3b 審查：授權流程結束（失敗、取消、逾時）時關掉瀏覽器裡的敏感分頁（授權頁）。W183 R8b 審查：帶這一輪的網址
        /// （私訊框 Browser 只收那一張；還沒發布過網址＝nil，只關 OS 瀏覽器退路的敏感分頁）。
        var closeLoginPages: (URL?) -> Void = { HandsSetup.postCloseLoginPages(only: $0) }
        /// W183 R8b：授權完成＝私訊框 Browser 的授權頁標「完成」（頁面關掉、分頁留著，使用者自己關）；OS 瀏覽器退路的敏感分頁照舊關。
        /// W183 R8b 審查（GPT-6）：授權檔驗過、存進鑰匙圈之後才叫（不是 cloudflared 一結束、檔案在就算）。
        var loginPagesDone: (URL) -> Void = { HandsSetup.postLoginPagesDone(only: $0) }
        /// W183 R8b 審查：cloudflared 結束（網址撤回）、還在驗授權檔與存鑰匙圈：頁面先關掉，分頁留著寫「確認中」。
        var loginPagesWithdrawn: (URL) -> Void = { HandsSetup.postLoginPagesWithdrawn(only: $0) }
        /// 自測：在固定的點插一手（控制競態的順序）。正式是空的。
        var checkpoint: (String) -> Void = { _ in }
        /// W183 R6a：走到配對（使用者或助理在這台按的）＝私訊框的［連線］卡（HandsConnectFlow.offer；R6b）。正式由 live 設定；預設什麼都不做。
        var offerConnect: () -> Void = {}
        /// W183 R6a：關開關、換主機＝取消這次連線（HandsConnectFlow.cancel(reason:)）。
        var cancelConnect: (String) -> Void = { _ in }
        /// W183 R6a：自動續跑叫關口照設定判斷（ChatGPTHandsService.settingsDidChange）——不叫 retry，安全停機的人工重試鎖不解除。
        var resumeService: () -> Void = {}
        /// W183 R6a：固定子網域的 DNS 紀錄（Cloudflare API；token 只在記憶體）。預設一律「查不到」（自測、staging 不上網）。
        var dnsRecords: (_ zoneID: String, _ name: String, _ apiToken: String, _ done: @escaping (HandsCloudflared.DNSLookup) -> Void) -> Void = { _, _, _, done in
            done(.failure("unavailable"))
        }
        var deleteDNSRecord: (_ zoneID: String, _ recordID: String, _ apiToken: String, _ done: @escaping (String?) -> Void) -> Void = { _, _, _, done in
            done("unavailable")
        }
        // W183 R6a 審查（GPT-6／Claude）：
        /// 這台（副設備）登記是主機＝關掉後要交回主設備。
        var hostNeedsRelease: () -> Bool = { false }
        /// 「關」真的存進磁碟了（不是只在記憶體強制關閉；HandsForcedOff）。
        var offPersisted: () -> Bool = { true }
        /// 這個行程有沒有主設備確認過的主機租約（副設備；主設備一律有）。
        var hostLeaseHeld: (_ local: String) -> Bool = { _ in true }
        /// 自動續跑（副設備）：問主設備「主機還是這台嗎」（只問、不認領）。
        var confirmHostLease: (_ local: String) -> HandsHostLeaseCheck = { _ in .confirmed }
        /// 助理（AI）叫的「重試」：一般的關口失敗救得回來，安全停機的人工重試鎖不解除。
        var retryService: () -> Void = {}
        /// 網址遷移時作廢已經有的 ChatGPT 連線（連接器還指著舊網址）。回傳撤銷沒存成的原因。
        var revokeGrants: (_ reason: String) -> String? = { _ in nil }
        /// 新網址從外面連得到、TLS 對、回的是 TATWO 的關口（nil＝確認了；否則分類）。預設一律「確認不了」。
        var probeHost: (_ host: String, _ done: @escaping (String?) -> Void) -> Void = { _, done in done("unavailable") }
        /// 這個網域裡 CNAME 指到的通道 id（nil＝查不到）。預設一律查不到。
        var dnsTunnelTargets: (_ zoneID: String, _ apiToken: String, _ done: @escaping (Set<String>?) -> Void) -> Void = { _, _, done in done(nil) }
        /// 交回前等關口停下最多多久。
        var stopWait: TimeInterval = 10
        /// W183 R7a：遷移後舊紀錄還沒刪（新網址從外面確認不了、刪不掉）：隔多久自己再試（不用使用者按；一次比一次久，最後停在最後一個）。
        /// 空的＝不自己再試（自測的世界預設空的，免得跟別的檢查搶）。
        var retireRetryDelays: [TimeInterval] = [60, 180, 600, 1800, 3600]
        // W183 R8c（多設備；GPT-6 必改 1、4、6）：
        /// 這台的 ChatGPT build 啟用許可（取代單主機的租約）。自測預設一律可以。
        var buildPermit: (_ local: String) -> HandsBuildPermit.State = { local in
            .active(HandsBuildDeviceSlice(deviceID: local, name: "", active: true, subdomain: HandsSettings.defaultSubdomainLabel, hostname: nil,
                                          accountID: nil, zoneID: nil, domain: nil, level: HandsSettings.maxLevel, projectIDs: [], deviceRevision: 0,
                                          revocationGeneration: 0, connectorName: "TATWO"), expiresAt: nil)
        }
        /// 使用者在這台打開（沒選設備＝預設主設備）：這台是正本、而且一台都沒勾時勾這台。回 true＝這台現在有許可。
        var buildSelectDefault: (_ local: String) -> Bool = { _ in true }
        /// 別台有建立證據的通道 id（主設備的所有權表；nil＝不知道＝不列任何「沒用到的通道」）。自測預設空的。
        var foreignTunnels: () -> Set<String>? = { [] }
        /// W183 R8c（GPT-6 必改 4）：使用者對這台明確解除安全停機鎖（安全停機那一列的「重試」＝HandsOneSwitch.retry）。自測預設不動。
        var unlockSafety: () -> Void = {}
        /// W183 R8c 審查（Claude 中）：使用者在這台關掉開關＝ChatGPT build 的中央設定也取消勾這台（寫穿；在背景做）。自測預設不動。
        var buildSwitchedOff: (_ local: String) -> Void = { _ in }

        static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Dependencies {
            let service = HandsService.shared
            let root = service.paths.root
            let localID: () -> String? = { (try? DeviceIdentityStore.readLocal())?.deviceID }
            if HandsSetup.isolated(environment) {
                // W183 R3 審查：隔離環境沒有明確注入假的 runner／鑰匙圈，就什麼都不做（CloudflareAccountsStore.shared 在這裡也用拒絕的秘密庫）。
                return Dependencies(
                    paths: service.paths, accounts: .shared, runner: HandsRefusingRunner(),
                    localDeviceID: localID, devices: { HandsSetup.pairedDevices() },
                    transferHost: { _ in HandsSetup.isolatedMessage },
                    locateCloudflared: { nil },
                    installCloudflared: { done in done(.failure(.isolated)) },
                    lookupZone: { _, _, done in done(nil, nil) },
                    openURL: { _ in },
                    loadSettings: { service.settings.load() },
                    updateSettings: { _ in throw HandsSetupError.isolated },
                    startService: {},
                    servicePhase: { .stopped },
                    hasActiveGrant: { false },
                    askApproval: { _, _, done in done(false) })
            }
            let authority = HandsHostAuthority.Live(service: service, dispatch: .shared, localID: localID)
            var deps = Dependencies(
                paths: service.paths,
                accounts: .shared,
                runner: HandsCloudflaredRunner(),
                localDeviceID: localID,
                devices: { HandsSetup.pairedDevices() },
                authoritativeHost: { authority.authoritativeHost() },
                transferHost: { target in authority.transfer(to: target) },
                releaseHost: { authority.releaseIfHost() },
                locateCloudflared: { HandsCloudflared.locate(root: root) },
                installCloudflared: { done in
                    guard let pin = HandsCloudflared.pins[HandsCloudflared.currentArch] else { return done(.failure(.unsupportedArch)) }
                    HandsCloudflared.download(pin: pin, root: root) { result in
                        done(result.map { HandsCloudflared.Location(url: $0, source: .downloaded) })
                    }
                },
                lookupZone: { zone, token, done in HandsCloudflared.lookupZone(zoneID: zone, apiToken: token, completion: done) },
                openURL: { url in
                    // W183 R5b 審查：流程在主執行緒上核對「這一輪還有效」之後才叫這裡（同一個主執行緒回合裡開，不再多跳一次）。
                    let open = { MainActor.assumeIsolated { _ = HandsSetup.openLoginPage(url, onCancel: { HandsSetup.shared.cancel() }) } }
                    if Thread.isMainThread { open() } else { DispatchQueue.main.async(execute: open) }
                },
                loadSettings: { service.settings.load() },
                updateSettings: { change in _ = try service.updateSettings(change) },
                // W183 R8c（GPT-6 必改 4）：設定流程叫關口一律「保留安全鎖」（重新勾選、重開、設定同步都不能清安全鎖）；
                // 解除只有使用者對那台明確按的「解除安全鎖」（ChatGPTHandsService.retry：HandsOneSwitch.retry／信箱的 unlock_safety）。
                startService: { ChatGPTHandsService.shared.retryKeepingSafetyLock() },
                serviceChanged: { ChatGPTHandsService.shared.settingsDidChange() },
                servicePhase: { HandsSetup.onMainSync { ChatGPTHandsService.shared.phase } },
                hasActiveGrant: { !service.auth.activeGrantIDs.isEmpty },
                askApproval: { title, detail, done in
                    Task { @MainActor in
                        let decision = await IslandNotice.shared.ask(title: title, detail: detail, allowLabel: "允許", timeout: 80)
                        done(decision == .allow)
                    }
                })
            // W183 R6a：連線那一段（R6b 的 HandsConnectFlow；主執行緒）、自動續跑、固定子網域的 DNS（Cloudflare API）。
            deps.offerConnect = { DispatchQueue.main.async { MainActor.assumeIsolated { HandsConnectFlow.shared.offer() } } }
            deps.cancelConnect = { reason in DispatchQueue.main.async { MainActor.assumeIsolated { HandsConnectFlow.shared.cancel(reason: reason) } } }
            deps.resumeService = { ChatGPTHandsService.shared.settingsDidChange() }
            deps.dnsRecords = { zone, name, token, done in HandsCloudflared.dnsRecords(zoneID: zone, name: name, apiToken: token, completion: done) }
            deps.deleteDNSRecord = { zone, record, token, done in HandsCloudflared.deleteDNSRecord(zoneID: zone, recordID: record, apiToken: token, completion: done) }
            // W183 R6a 審查：交回主機、主機租約、助理的重試、遷移時作廢舊連線、新網址的外部確認、DNS 指到的通道。
            deps.hostNeedsRelease = { authority.needsRelease() }
            deps.offPersisted = { !service.settings.forcedOff }
            deps.hostLeaseHeld = { HandsBuildPermit.permits($0) }   // W183 R8c：每台啟用許可（取代單主機租約）
            deps.confirmHostLease = { _ in authority.confirmLease() }
            deps.buildPermit = { HandsBuildPermit.shared.state($0) }
            deps.buildSelectDefault = { local in HandsBuildSync.selectDefaultIfNone(local: local) }
            deps.foreignTunnels = { HandsBuildSync.shared.foreignTunnelIDs() }
            deps.retryService = { ChatGPTHandsService.shared.retryKeepingSafetyLock() }
            deps.unlockSafety = { ChatGPTHandsService.shared.retry() }
            deps.buildSwitchedOff = { local in HandsBuildSync.shared.localSwitchedOff(local: local) }
            deps.revokeGrants = { reason in
                let problem = service.auth.revokeAll(reason: reason)
                HandsSandbox.terminateAll()
                return problem
            }
            deps.probeHost = { host, done in HandsCloudflared.probeGateway(host: host, completion: done) }
            deps.dnsTunnelTargets = { zone, token, done in HandsCloudflared.dnsTunnelTargets(zoneID: zone, apiToken: token, completion: done) }
            return deps
        }
    }

    enum Outcome: Equatable { case done, waiting, failed, stopped }

    /// 授權頁是在 OS 瀏覽器開的；使用者在「設定」浮層裡按登入時，先關設定讓瀏覽器露出來，授權結束再帶回原本那一頁。
    enum ReturnPage: Equatable, Sendable { case environmentLogin, tap }

    @Published private(set) var state: HandsSetupState
    @Published private(set) var busy = false
    /// 授權網址（OS 瀏覽器沒跳出來時畫面上給一個連結；不是秘密）。
    @Published private(set) var loginURL: URL?
    /// 流程被擋住的原因（上一個 cloudflared 還沒結束、清不掉上次的暫存檔）；nil＝沒事。
    @Published private(set) var problem: String?
    /// W183 R6a：副設備當了主機、交回主設備沒成功的原因（那一列給「交回主設備」）；nil＝沒事。
    @Published private(set) var handbackProblem: String?
    /// W183 R6a：「詳細」裡沒用到的 TATWO 通道（nil＝還沒查過或查不清楚：不顯示那一段）。
    @Published private(set) var unusedTunnels: [HandsCloudflared.UnusedTunnel]?
    /// W183 R6a：正在查或刪沒用到的通道（不算設定流程的「忙碌」：那一行狀態不跳「準備中」）。
    @Published private(set) var checkingTunnels = false
    /// W183 R6a 審查（Claude）：查不到這個網域的 DNS（列出的可能是另一台設備的通道）。
    @Published private(set) var unusedTunnelsUnverified = false
    /// W183 R6a 審查（GPT-6）：等使用者按「確定」的換主機請求（畫面出卡片內確認列）。
    @Published private(set) var hostChangeRequest: HandsHostChangeRequest?

    let dependencies: Dependencies
    private let lock = NSRecursiveLock()
    private var current: HandsSetupState
    /// 授權網址（這一輪 cloudflared 印的；鎖保護，給副設備的簽章 RPC 在背景讀「授權頁開著」這個進度）。
    /// W183 R8 整合審查（GPT-6 高）：替別台登入的那一輪（loginOwnerOnly）只在這裡、只交給擁有者——不發布到這台畫面看的 @Published loginURL。
    private var loginURLValue: URL?
    /// W183 R8 整合審查（GPT-6 高「替別台登入的網址仍暴露在目標設備的本機 UI」）：這一輪是替別台（擁有者）登入：網址只經信箱交給擁有者，
    /// 這台的設定頁、「…」、環境登入都拿不到、開不了（isLocalLoginPage 回 false）。
    private var loginOwnerOnly = false
    /// W183 R5b 審查（GPT-6）：這一輪等授權（第 3 步的 cloudflared login）：識別碼＋發布過網址沒有。結束（完成、失敗、取消、逾時）
    /// 先作廢再停指令；晚到的輸出、主執行緒上真的開頁之前都要核對——作廢之後不會再發布網址、不會再開頁。
    private var loginRound: (id: UUID, published: Bool)?
    /// W183 R8b 審查（GPT-6）：撤下之後還沒有結論的授權頁（這一輪、網址）：授權檔驗過並存好＝標「完成」，其他任何退出＝收掉（冪等）。
    private var pendingLoginPage: (round: UUID, url: URL)?
    /// W183 R5b 審查（GPT-6）：這一個設定工作的編號、誰按的（副設備按的＝主機驗章得到的設備 id，不收 payload 指定）。
    /// 副設備只在「這一輪是它按的」時自動打開授權頁。
    private var currentRun: (id: String, requester: String?)?
    private let work = DispatchQueue(label: "tatwo.chatgpt-hands.setup", qos: .userInitiated)
    private var runningCommand: HandsRunningCommand?
    /// 取消後沒在時限內結束的舊指令：它真的結束（看門程式清完檔）之前不准重跑。
    private var lingering: HandsRunningCommand?
    private var blockedReason: String?
    private var cancelRequested = false
    private var jobActive = false
    /// W183 R6a：正在查或刪沒用到的通道（維護；不是設定流程）。
    private var maintaining = false
    /// W183 R7a：舊紀錄的自動重試：試過幾次、有沒有排著。
    private var retireRetries = 0
    private var retireRetryScheduled = false
    /// 換主機的請求（鎖保護；hostChangeRequest 是給畫面的同一個值）。
    private var hostChangeValue: HandsHostChangeRequest?
    /// 流程世代：每次取消 +1。「登入完自動接著做」綁在當時的世代上。
    private var generation = 0
    /// W183 R3b 審查：這個行程的亂數（重開 App 就換）；跟世代一起組成 setupEpoch（副設備的設定動作要帶，舊的一律不收）。
    private let bootNonce = HandsSetup.randomLabel(12)
    private var terminationObserver: NSObjectProtocol?
    // W183 R8c（GPT-6 必改 4）：拿掉「登入完自動接著做」（resumeIntent）與「重新授權確認後接著做」（continueAfterConfirm）——登入只是登入。
    /// W183 R8c：替別台登入（信箱）時，這一輪的授權網址與結束交給誰（只在記憶體；不寫檔、不給 AI）。
    private var remoteLogin: (onURL: (URL) -> Void, onEnd: (HandsLoginOutcome) -> Void)?
    /// W183 R8c 審查（GPT-6 中）：那一輪替別台登入是哪一件（operationID）、是哪一個設定工作（取消只取消那一個，不動別的工作）。
    private var remoteLoginOperation: String?
    private var remoteLoginRun: String?
    /// W183 R8c 審查（GPT-6 高／中）：這一個設定工作是「套用」拍下的那一份（建通道、改 DNS、起關口前再核）；工作結束就清。
    private var activePlan: HandsApplyPlan?
    /// W183 R8 整合審查（GPT-6 高「舊版設定 RPC 仍能繞過 apply plan 建立或改動 DNS」）：這一個設定工作是使用者按的「套用」
    /// （applyURLs：ChatGPT build 的執行者帶快照、或這台畫面按的）。別台經舊的遠端設定 RPC（start_setup／continue_setup，trigger .remote）
    /// 跑的不是套用：跟自動續跑一樣只照用已經建好的——不新建通道、不改 DNS、不換網址。工作結束就清。
    private var applyRun = false
    /// 使用者在設定頁按登入：授權結束後帶回哪一頁（只在主執行緒讀寫）。
    @MainActor static var returnAfterAuthorize: ReturnPage?

    var stateURL: URL { dependencies.paths.appDir.appendingPathComponent("setup.json") }
    var setupHome: URL { dependencies.paths.root.appendingPathComponent("cf-setup", isDirectory: true) }
    /// 正在跑的設定指令是哪一組（只有行程群組編號；App 當掉後重開用來收掉它）。
    var runnerRecordURL: URL { dependencies.paths.appDir.appendingPathComponent("setup-runner.json") }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        var loaded = Self.load(dependencies.paths.appDir.appendingPathComponent("setup.json"))
        // 上次跑到一半（App 關了、當了）：接著做，不當成完成。
        for (key, value) in loaded.steps where value.status == .running || value.status == .waitingUser {
            loaded.steps[key] = HandsSetupStepState(status: .pending, message: Self.interruptedMessage, updatedAt: value.updatedAt)
        }
        current = loaded
        state = loaded
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cancel()
        }
        // App 上次當掉時可能還有設定指令、明文的暫存憑證：先收掉、清乾淨（在工作佇列上做：之後的任何工作都排在它後面）。
        work.async { [weak self] in self?.recoverAfterCrash() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    private static func load(_ url: URL) -> HandsSetupState {
        guard let data = HandsFiles.readSecure(url, limit: 256 * 1024) else { return HandsSetupState() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(HandsSetupState.self, from: data)) ?? HandsSetupState()
    }

    var snapshot: HandsSetupState { lock.lock(); defer { lock.unlock() }; return current }
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return jobActive }
    /// W183 R3b 審查：流程世代（副設備的開始、繼續、確認、重新授權要帶；取消、關掉、App 重開都會換）。
    var setupEpoch: String { lock.lock(); defer { lock.unlock() }; return "\(bootNonce).\(generation)" }
    /// W183 R5b 審查：正在跑的設定工作（編號、誰按的）；沒在跑＝nil。
    var runInfo: (id: String, requester: String?)? { lock.lock(); defer { lock.unlock() }; return currentRun }

    // MARK: - 狀態寫入（每次都存檔、推給畫面）

    private func mutate(_ change: (inout HandsSetupState) -> Void) {
        // W183 R5 審查（GPT-6 複查）：寫檔也在鎖裡——跟 mutateDurably 同一個順序，舊快照不會在較新的寫入之後才落盤。
        lock.lock()
        change(&current)
        current.updatedAt = Date()
        let value = current
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) { try? HandsFiles.writeAtomically(data, to: stateURL) }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.state = value }
    }

    private func set(_ step: HandsSetupStep, _ status: HandsSetupStatus, _ message: String) {
        mutate { $0.steps[step.rawValue] = HandsSetupStepState(status: status, message: message, updatedAt: Date()) }
    }

    @discardableResult private func done(_ step: HandsSetupStep, _ message: String) -> Outcome { set(step, .done, message); return .done }
    @discardableResult private func fail(_ step: HandsSetupStep, _ message: String) -> Outcome { set(step, .failed, message); return .failed }
    @discardableResult private func waitUser(_ step: HandsSetupStep, _ message: String) -> Outcome { set(step, .waitingUser, message); return .waiting }

    private func publishBusy(_ value: Bool) { DispatchQueue.main.async { [weak self] in self?.busy = value } }
    private func publishLoginURL(_ url: URL?) {
        lock.lock(); let had = loginURLValue; loginURLValue = url; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.loginURL = url }
        // W183 R3b 審查：授權頁（敏感分頁）在流程結束時關掉（W183 R8b 審查：只收原本那一張）。
        if url == nil, let had { dependencies.closeLoginPages(had) }
    }

    /// 關掉這台瀏覽器裡的敏感分頁（授權頁）：BrowserTabRegistry 收到就關（不記進最近關閉）；W183 R8b：私訊框 Browser 的授權分頁關掉。
    /// only（W183 R5b 審查）：只收那一張授權頁（副設備收回它自己開的那一張）；nil＝任何一張。
    /// W183 R8b 審查（GPT-6）：私訊框 Browser 只收帶網址的（沒有網址＝不碰私訊框，只關 OS 瀏覽器退路的敏感分頁）。
    static func postCloseLoginPages(only url: URL? = nil) {
        postLoginPages(url, .closed)
    }

    /// W183 R8b：授權完成——私訊框 Browser 的授權分頁標「完成」（頁面關掉、分頁留著；使用者自己關）；OS 瀏覽器退路的敏感分頁照舊關。
    static func postLoginPagesDone(only url: URL) {
        postLoginPages(url, .done)
    }

    /// W183 R8b 審查：網址撤回、流程還在收尾——私訊框 Browser 的授權頁先關掉（分頁寫「確認中」）；OS 瀏覽器退路的敏感分頁關掉。
    static func postLoginPagesWithdrawn(only url: URL) {
        postLoginPages(url, .withdrawn)
    }

    private static func postLoginPages(_ url: URL?, _ end: DMBrowserLoginPageEnd) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: BrowserTabRegistry.closeSensitiveTabsNotification, object: url)
            guard let url else { return }
            NotificationCenter.default.post(name: DMBrowser.loginPagesNotification, object: url, userInfo: ["state": end.rawValue])   // W183 R8b
        }
    }

    /// W183 R5b 審查（GPT-6）：這一輪還有效、還沒發布過網址：記下網址、第 3 步改成「等你按」。跟 endLoginRound 同一把鎖：
    /// 收尾（作廢）之後晚到的輸出不會再發布網址、不會把步驟改回「等你按」。
    private func publishRoundURL(_ url: URL, round: UUID, message: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = loginRound, current.id == round, !current.published else { return false }
        loginRound = (round, true)
        loginURLValue = url
        // W183 R8 整合審查（GPT-6 高）：替別台登入（信箱那一輪：remoteLogin 在）＝網址只交給擁有者（deliverRemoteLoginURL），
        // 不發布給這台的畫面（設定頁的「在這台打開授權頁」、ChatGPT build 的登入鈕都拿不到）。
        loginOwnerOnly = remoteLogin != nil
        if !loginOwnerOnly { DispatchQueue.main.async { [weak self] in self?.loginURL = url } }
        set(.authorize, .waitingUser, message)
        return true
    }

    /// W183 R8 整合審查（GPT-6 高）：這個網址是不是**這台自己這一輪**的授權頁（還在等、不是替別台登入的那一輪）。
    /// 畫面要在這台打開授權頁之前核這個（不接受裸網址：晚到的、別輪的、替別台登入的一律不開）。
    func isLocalLoginPage(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loginRound != nil && !loginOwnerOnly && loginURLValue == url
    }

    /// 主執行緒上真的開頁之前再核對一次：這一輪還有效、網址還是這一個。
    private func isCurrentLogin(_ url: URL, round: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loginRound?.id == round && loginURLValue == url
    }

    /// 在這台打開授權頁（主執行緒；核對過這一輪還有效才開）。
    private func openIfCurrent(_ url: URL, round: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentLogin(url, round: round) else { return }
            self.dependencies.openURL(url)
        }
    }

    /// W183 R5b 審查（GPT-6）：這一輪結束——先作廢、清掉網址，再收掉這一輪的授權頁（先前還沒有網址也收）。重複呼叫沒事。
    /// W183 R8b 審查（GPT-6）：withdraw＝cloudflared 結束、還要驗授權檔與存鑰匙圈：頁面先撤下（分頁寫「確認中」），結論留給
    /// settleLoginPages（驗過並存好＝標「完成」；其他任何退出＝收掉）。只收這一輪的網址（不會命中別的流程的分頁）。
    private func endLoginRound(_ round: UUID, withdraw: Bool = false) {
        lock.lock()
        let mine = loginRound?.id == round
        var url: URL?
        if mine {
            url = loginURLValue
            loginRound = nil
            loginURLValue = nil
            loginOwnerOnly = false
            if withdraw, let url { pendingLoginPage = (round, url) }
            DispatchQueue.main.async { [weak self] in self?.loginURL = nil }
        }
        lock.unlock()
        guard mine else { return }
        if withdraw, let url { dependencies.loginPagesWithdrawn(url) } else { dependencies.closeLoginPages(url) }
    }

    /// W183 R8b 審查（GPT-6）：撤下的授權頁的結論——done＝授權檔驗過、存進鑰匙圈；否則收掉。只有第一次算（冪等；別輪的不碰）。
    private func settleLoginPages(_ round: UUID, done: Bool) {
        lock.lock()
        guard let pending = pendingLoginPage, pending.round == round else { lock.unlock(); return }
        pendingLoginPage = nil
        lock.unlock()
        if done { dependencies.loginPagesDone(pending.url) } else { dependencies.closeLoginPages(pending.url) }
    }

    /// W183 R3b：正在等使用者按的 Cloudflare 授權網址（任何執行緒都能讀）。只給畫面與副設備的簽章 RPC（remote_hands_status）；
    /// **不進** hands_setup_status 與任何 AI 工具輸出、狀態檔、日誌（授權網址拿到的人可以把他自己的 Cloudflare 帳號塞進來）。
    /// 只在第 3 步真的在等使用者按的時候有值。
    var pendingLoginURL: URL? {
        lock.lock(); defer { lock.unlock() }
        guard let url = loginURLValue, current.step(.authorize).status == .waitingUser else { return nil }
        return url
    }
    private func publishProblem(_ text: String?) { DispatchQueue.main.async { [weak self] in self?.problem = text } }
    private func publishHandback(_ text: String?) { DispatchQueue.main.async { [weak self] in self?.handbackProblem = text } }

    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelRequested }

    // MARK: - App 當掉之後、舊指令沒結束：先收乾淨才准做

    /// 上次（這個行程之前）留下的設定指令：確定是我們的看門程式（argv）才收；收掉後清設定家目錄裡的暫存憑證與授權檔。
    private func recoverAfterCrash() {
        var reason: String?
        if let data = HandsFiles.readSecure(runnerRecordURL, limit: 4096),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = object["pgid"] as? Int, raw > 1, raw < Int(Int32.max) {
            let pgid = pid_t(raw)
            let home = HandsGatewayLaunch.realPath(setupHome.path) ?? setupHome.path
            if HandsCloudflaredRunner.isOurGuard(pid: pgid, setupHome: home) {
                _ = killpg(pgid, SIGTERM)   // 看門程式收掉 cloudflared、等它結束、清檔
                if !Self.waitGone(pgid, seconds: 4) { _ = killpg(pgid, SIGKILL); _ = Self.waitGone(pgid, seconds: 2) }
                if kill(pgid, 0) == 0 { reason = Self.lingeringMessage }
            }
        }
        if reason == nil {
            unlink(runnerRecordURL.path)
            if !Self.removeLeftovers(in: setupHome, dotDir: setupHome.appendingPathComponent(".cloudflared", isDirectory: true)) {
                reason = Self.leftoverMessage
            }
        }
        lock.lock(); blockedReason = reason; lock.unlock()
        publishProblem(reason)
    }

    static func waitGone(_ pid: pid_t, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return kill(pid, 0) != 0
    }

    /// 開工前：上一個指令真的結束了、暫存檔清乾淨了，才准做。回 nil＝可以做。
    private func unblock() -> String? {
        lock.lock(); let old = lingering; lock.unlock()
        if let old {
            guard old.waitForExit(timeout: 3) else { return Self.lingeringMessage }
            lock.lock(); lingering = nil; lock.unlock()
            unlink(runnerRecordURL.path)
            guard Self.removeLeftovers(in: setupHome, dotDir: setupHome.appendingPathComponent(".cloudflared", isDirectory: true)) else {
                lock.lock(); blockedReason = Self.leftoverMessage; lock.unlock()
                return Self.leftoverMessage
            }
        }
        lock.lock(); let blocked = blockedReason != nil; lock.unlock()
        guard blocked else { return nil }
        recoverAfterCrash()   // 再試一次（例如上次的指令後來自己結束了、權限修好了）
        lock.lock(); defer { lock.unlock() }
        return blockedReason
    }

    private func trackRunner(_ command: HandsRunningCommand) {
        guard command.processGroup > 1,
              let data = try? JSONSerialization.data(withJSONObject: ["pgid": Int(command.processGroup)]) else { return }
        try? HandsFiles.writeAtomically(data, to: runnerRecordURL)
    }

    private func untrackRunner() { unlink(runnerRecordURL.path) }

    // MARK: - 給畫面與 OS 工具

    /// 一次跑完（跳過已完成的）；停在要使用者按的那一步或失敗的那一步。回傳有沒有開始（設定進行中＝沒有）。
    /// allowLogin：沒登入 Cloudflare 時直接開授權頁（助理叫的、或使用者在環境登入按的）；TAP 的開關只導去環境登入。
    /// hostOverride（W183 R3b）：副設備經簽章 RPC 叫主設備開始時，主機就是主設備自己（不看流程上次記的別台）。
    /// requester（W183 R5b 審查）：副設備按的（trigger .remote）＝主機驗章得到的那台設備 id。
    @discardableResult
    func runAll(trigger: HandsSetupTrigger, allowLogin: Bool, hostOverride: String? = nil, requester: String? = nil) -> Bool {
        enqueue(HandsSetupStep.runOrder, trigger: trigger, allowLogin: allowLogin, force: false, hostOverride: hostOverride, requester: requester)
    }

    /// W183 R6a（one-switch「自動續跑的界線」）：主機 App 重開、開關開著、這台就是主機＝自動接著做（不用按「繼續」）。
    /// 只恢復已確認設定的通道、關口、既有 grant：不開 Cloudflare 授權頁（allowLogin false）、不叫「重試」（resumeService：
    /// 關口照設定判斷，安全停機的人工重試鎖不解除）、走到配對不 offer、不開配對窗口。回傳有沒有開始。
    @discardableResult
    func resumeIfEnabled() -> Bool {
        let settings = dependencies.loadSettings()
        guard settings.enabled, let local = dependencies.localDeviceID(), HandsHostAuthority.same(settings.hostDeviceID, local) else { return false }
        return enqueue(HandsSetupStep.runOrder, trigger: .resume, allowLogin: false, force: false, hostOverride: nil)
    }

    /// W183 R3b：「取消並重新授權」（兩台畫面都有）：授權完發現不是要的 Cloudflare 帳號或網域——先停下用它的手腳、
    /// 清掉這次登入拿到的憑證（只清這次的；之前在環境登入加好的帳號不動）、回到第 3 步並重開授權頁，授權完照常接著做。
    /// Cloudflare 上已經建的通道與 DNS 紀錄不刪（不碰使用者帳號裡的東西）。已經配對＝不在這裡做；設定進行中＝先按「取消」。
    /// W183 R3b 審查：等確認時（第 3 步等你按）也能按；上次清到一半失敗（discard 還在）＝可以重按（冪等）。回 nil＝開始了。
    func reauthorize(trigger: HandsSetupTrigger, requester: String? = nil) -> HandsReauthorizeRefusal? {
        let state = snapshot
        if state.discard == nil {
            guard let zone = state.zoneID, state.accountID != nil,
                  state.step(.authorize).status == .done || state.isUnconfirmed(zone) else { return .notAuthorized }
        }
        guard !dependencies.hasActiveGrant() else { return .paired }
        // W183 R8c：清掉這一輪的授權後重新登入——登入只是登入（不會自己接著建網址；選網域、按「套用」才建）。
        let started = enqueue([.cloudflared, .authorize], trigger: trigger, allowLogin: true, force: false, hostOverride: nil,
                              forceOnly: [.authorize], requester: requester, prelude: { [weak self] in self?.discardAuthorization() ?? false })
        return started ? nil : .busy
    }

    /// 畫面與副設備用：「已授權：Cloudflare 帳號〈名稱〉、網域〈網域〉」；還沒確認＝同一列加「是這個，繼續」；上次沒清完＝「重按一次」。
    /// 帳號名稱與確認碼只給畫面與設備簽章通道，不給 AI。
    func authorizedSummary() -> HandsAuthorizationSummary? {
        let state = snapshot
        if let discard = state.discard {
            let account = dependencies.accounts.account(discard.accountID)
            let name = account?.domains.first { $0.zoneID == discard.zoneID }?.name
            return HandsAuthorizationSummary(account: String((account?.displayName ?? "（已移除的帳號）").prefix(80)),
                                             domain: (name?.isEmpty ?? true) ? nil : name,
                                             needsConfirm: false, confirmToken: nil, cleanupPending: true)
        }
        guard let id = state.accountID, let zone = state.zoneID, let account = dependencies.accounts.account(id) else { return nil }
        let listed = account.domains.first { $0.zoneID == zone }?.name
        let domain = (listed?.isEmpty ?? true) ? state.domain : listed
        if state.isUnconfirmed(zone) {
            return HandsAuthorizationSummary(account: String(account.displayName.prefix(80)), domain: domain,
                                             needsConfirm: true, confirmToken: state.confirmToken, cleanupPending: false)
        }
        guard state.step(.authorize).status == .done else { return nil }
        return HandsAuthorizationSummary(account: String(account.displayName.prefix(80)), domain: domain,
                                         needsConfirm: false, confirmToken: nil, cleanupPending: false)
    }

    /// W183 R3b 審查：「是這個，繼續」——確認這一輪授權的帳號與網域（token＝畫面拿到的確認碼、domain＝畫面上看到的網域）。
    /// 網域名稱還不知道（Cloudflare 沒回）＝不確認，先再問一次名稱（回 false；畫面顯示名稱後使用者再按）。
    /// 確認了（回 true）：第 3 步完成；開關開著就接著建通道、啟動（開關關著，例如在環境登入加帳號＝只確認，不打開）。
    /// AI 工具不能叫這個（hands_setup_step 沒有這個動作）。
    /// trigger／requester（W183 R6a）：副設備按的「是這個，繼續」＝.remote（接著做到配對時由按的那台 offer，主機不在自己的畫面出［連線］卡）。
    @discardableResult
    func confirmAuthorization(token: String, domain shown: String, trigger: HandsSetupTrigger = .user, requester: String? = nil) throws -> Bool {
        let state = snapshot
        guard let zone = state.zoneID, state.awaitingConfirmation, let expected = state.confirmToken,
              HandsAuth.constantTimeEqual(expected, token) else { throw HandsConfirmRefusal.stale }
        let known = domainName(accountID: state.accountID, zoneID: zone)
        guard let known else {
            let started = enqueue([], trigger: .user, allowLogin: false, force: false, hostOverride: nil,
                                  prelude: { [weak self] in self?.lookupNames(zoneID: zone); return false })
            if !started { throw HandsConfirmRefusal.busy }
            return false
        }
        guard shown == known else { throw HandsConfirmRefusal.changed }
        // W183 R8c（GPT-6 必改 4）：確認只記成確認——不接著跑整條（建網址要使用者按「套用」）。
        let started = enqueue([], trigger: trigger, allowLogin: false, force: false, hostOverride: nil, requester: requester,
                              prelude: { [weak self] in self?.commitConfirmation(token: token, zoneID: zone, domain: shown) ?? false })
        if !started { throw HandsConfirmRefusal.busy }
        return true
    }

    /// 帳號清單裡這個網域的名稱（沒有、空的＝nil）。
    private func domainName(accountID: String?, zoneID: String) -> String? {
        let name = accountID.flatMap(dependencies.accounts.account)?.domains.first { $0.zoneID == zoneID }?.name
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// 在設定工作裡：再核一次（確認碼、網域、授權還在），才記成確認、第 3 步完成。回 true＝開關開著、接著做。
    private func commitConfirmation(token: String, zoneID: String, domain: String) -> Bool {
        let state = snapshot
        guard state.zoneID == zoneID, state.awaitingConfirmation, state.confirmToken == token,
              domainName(accountID: state.accountID, zoneID: zoneID) == domain,
              dependencies.accounts.hasCert(zoneID: zoneID) else {
            _ = waitUser(.authorize, "授權剛換過了；看一下畫面上的帳號與網域再按一次「是這個，繼續」")
            return false
        }
        mutate { value in
            value.unconfirmedZoneIDs = (value.unconfirmedZoneIDs ?? []).filter { $0 != zoneID }
            value.confirmToken = nil
            value.domain = domain
            value.steps[HandsSetupStep.authorize.rawValue] = HandsSetupStepState(status: .done, message: "已確認 Cloudflare 授權（帳號與網域在畫面上）", updatedAt: Date())
        }
        return false   // W183 R8c：不接著做
    }

    /// 網域名稱（與帳號名稱）再問 Cloudflare 一次（用鑰匙圈裡這個網域的授權；token 只在記憶體）。
    private func lookupNames(zoneID: String) {
        guard let pem = try? dependencies.accounts.cert(zoneID: zoneID), let cert = HandsCloudflared.parseOriginCert(pem) else { return }
        let lookup = HandsLocked<(String?, String?)?>(nil)
        let looked = DispatchSemaphore(value: 0)
        dependencies.lookupZone(cert.zoneID, cert.apiToken) { domain, name in lookup.set((domain, name)); looked.signal() }
        _ = looked.wait(timeout: .now() + dependencies.lookupTimeout)
        guard let result = lookup.get(), let host = HandsGatewayLaunch.validHost(result.0),
              (try? dependencies.accounts.setDomainName(zoneID: zoneID, name: host)) != nil else {
            _ = waitUser(.authorize, Self.namesUnknownMessage)
            return
        }
        mutate { if $0.zoneID == zoneID { $0.domain = host } }
        _ = waitUser(.authorize, Self.confirmWaitingMessage)
    }

    static func authorizedText(account: String, domain: String?) -> String {
        let name = domain.flatMap { $0.isEmpty ? nil : $0 } ?? "名稱建通道時補上"
        return "已授權：Cloudflare 帳號〈\(account)〉、網域〈\(name)〉"
    }

    /// W183 R3b 審查：等使用者確認的那一句（兩台、環境登入一樣）。
    static func confirmText(account: String, domain: String?) -> String {
        let name = domain.flatMap { $0.isEmpty ? nil : $0 } ?? "還問不到名稱"
        return "請確認：Cloudflare 帳號〈\(account)〉、網域〈\(name)〉是你要的嗎？確認之前不會建通道、不會開任何網址"
    }

    /// 重跑某一步（已完成的也重做）。配對只能由使用者在私訊框按［連線］（W183 R6a），這裡只檢查狀態。
    @discardableResult
    func run(_ step: HandsSetupStep, trigger: HandsSetupTrigger) -> Bool {
        enqueue([step], trigger: trigger, allowLogin: true, force: true, hostOverride: nil)
    }

    /// 選主機的結果（W183 R6a 審查）。
    enum HostChoice: Equatable, Sendable { case started, needsConfirmation, busy }

    /// 選主機（畫面的設備選單、「改用這台當主機」；OS 工具可帶 hostDeviceID）。設定進行中不會換（回 busy，畫面要說明）。
    /// W183 R6a 審查（GPT-6「換主機確認只擋 UI，助理／MCP 可直接繞過」）：跟現在的主機一樣＝照常確認一次（不換）；
    /// 要換＝後端只記下一張一次性的請求（綁原主機、目標、流程世代、期限），畫面出卡片內確認列——使用者按「確定」（confirmHostChange）才換。
    /// 助理（AI）提出的也一樣；AI 工具沒有「確定」這個動作。
    @discardableResult
    func chooseHost(_ deviceID: String, trigger: HandsSetupTrigger) -> HostChoice {
        if isBusy { return .busy }
        let settings = dependencies.loadSettings()
        let devices = dependencies.devices()
        let local = dependencies.localDeviceID() ?? ""
        guard let target = devices.first(where: { HandsHostAuthority.same($0.id, deviceID) })?.id,
              Self.isHostChange(to: target, configured: settings.hostDeviceID, devices: devices, local: local) else {
            // 跟現在一樣（或不是已知的設備：第 1 步會說明）：照常確認一次，不換。
            return enqueue([.host], trigger: trigger, allowLogin: false, force: true, hostOverride: deviceID) ? .started : .busy
        }
        let request = HandsHostChangeRequest(token: Self.randomLabel(24), from: settings.hostDeviceID, to: target, epoch: setupEpoch,
                                             expiresAt: Date().addingTimeInterval(Self.hostChangeLifetime), byAssistant: trigger == .assistant)
        lock.lock(); hostChangeValue = request; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.hostChangeRequest = request }
        return .needsConfirmation
    }

    /// 要不要算「換主機」：跟設定記的主機（沒記＝預設的主設備）不一樣。
    static func isHostChange(to target: String, configured: String?, devices: [HandsSetupDevice], local: String) -> Bool {
        let current = configured ?? devices.first(where: \.isPrimary)?.id ?? local
        return !HandsHostAuthority.same(current, target)
    }

    /// 卡片內確認列的「確定」（只有畫面叫；AI 工具沒有這個）：這張請求一次性、還沒過期、流程世代沒換（沒有取消、關掉、App 重開）、
    /// 主機還是提出時那一台，才換。換了＝這次連線（私訊框的［連線］、配對）作廢（one-switch：主機改變＝作廢）。
    @discardableResult
    func confirmHostChange(token: String) -> Bool {
        lock.lock()
        let request = hostChangeValue
        let matches = request.map { HandsAuth.constantTimeEqual($0.token, token) } ?? false
        if matches { hostChangeValue = nil }
        let epochNow = "\(bootNonce).\(generation)"
        lock.unlock()
        guard matches, let request else { return false }
        DispatchQueue.main.async { [weak self] in self?.hostChangeRequest = nil }
        let configured = dependencies.loadSettings().hostDeviceID ?? ""
        guard Date() < request.expiresAt, request.epoch == epochNow, configured.lowercased() == (request.from ?? "").lowercased() else { return false }
        let started = enqueue([.host], trigger: .user, allowLogin: false, force: true, hostOverride: request.to, approvedHost: request.to)
        // W183 R8c（GPT-6 必改 1）：換成別台＝不換（每台自己跑自己的；第 1 步說「在 ChatGPT build 勾那台」），這次連線不作廢；換回這台才作廢。
        if started, HandsHostAuthority.same(request.to, dependencies.localDeviceID()) { dependencies.cancelConnect("host_changed") }
        return started
    }

    /// 確認列的「取消」。
    func dismissHostChange() {
        lock.lock(); hostChangeValue = nil; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.hostChangeRequest = nil }
    }

    /// 設定 › 環境登入 › Cloudflare 的「用瀏覽器登入」：先確認有 cloudflared，再授權（已經有帳號也再登入一次，加新帳號或新網域）。
    /// W183 R8c（GPT-6 必改 4）：**登入只是登入**——授權存這台的鑰匙圈、更新帳號清單就停；不採用帳號、不改手腳的網域／通道／網址、
    /// 不建 DNS、不接著跑整條、不解除安全鎖（ChatGPT build 開著時也一樣）。
    @discardableResult
    func login(trigger: HandsSetupTrigger) -> Bool {
        enqueue([.cloudflared, .authorize], trigger: trigger, allowLogin: true, force: true, hostOverride: nil, forceOnly: [.authorize])
    }

    /// W183 R8c（在哪台都能做；GPT-6 必改 3、4）：替別台（擁有者）在**這台**登入 Cloudflare——跑這台的 cloudflared login、授權存這台的鑰匙圈；
    /// 授權網址不在這台開，交給 onURL（信箱只給擁有者，在擁有者的私訊框開）；結束時 onEnd。登入只是登入（同 login）。設定進行中＝busy。
    /// operationID（W183 R8c 審查）：信箱那一件的編號；取消只認這一件（cancelRemoteLogin）。
    @discardableResult
    func loginForRemote(requester: String, operationID: String? = nil, onURL: @escaping (URL) -> Void,
                        onEnd: @escaping (HandsLoginOutcome) -> Void) -> Bool {
        lock.lock()
        guard !jobActive, remoteLogin == nil else { lock.unlock(); onEnd(.busy); return false }
        remoteLogin = (onURL, onEnd)
        // 佔用工作槽與記下「這一輪是哪一件」在同一把鎖裡（遞迴鎖）：取消時找得到確切在跑的那一個。
        let started = enqueue([.cloudflared, .authorize], trigger: .remote, allowLogin: true, force: true, hostOverride: nil,
                              forceOnly: [.authorize], requester: requester, finished: { [weak self] in self?.finishRemoteLogin() })
        if started {
            remoteLoginOperation = operationID
            remoteLoginRun = currentRun?.id
        } else {
            remoteLogin = nil
        }
        lock.unlock()
        if !started { onEnd(.busy) }
        return started
    }

    /// W183 R8c 審查（GPT-6 中「第二次忙碌登入會覆蓋第一次的取消控制」）：只取消「那一件」替別台的登入——
    /// 這一輪的設定工作還在跑、而且就是那一件開的，才取消（跟 cancel() 同樣換世代、收指令）；已經結束、或現在跑的是別的工作＝不動、回 false。
    @discardableResult
    func cancelRemoteLogin(_ operationID: String) -> Bool {
        lock.lock()
        guard jobActive, remoteLogin != nil, remoteLoginOperation == operationID, let run = currentRun, run.id == remoteLoginRun else {
            lock.unlock(); return false
        }
        cancelRequested = true
        generation &+= 1
        let hadRequest = hostChangeValue != nil
        hostChangeValue = nil
        let command = runningCommand
        lock.unlock()
        if hadRequest { DispatchQueue.main.async { [weak self] in self?.hostChangeRequest = nil } }
        command?.cancel()
        return true
    }

    /// 這一輪（信箱替別台登入）拿到授權網址：交給擁有者（不進狀態檔、不進給 AI 的狀態、不進公共狀態）。
    private func deliverRemoteLoginURL(_ url: URL) {
        lock.lock(); let sink = remoteLogin; lock.unlock()
        sink?.onURL(url)
    }

    private func finishRemoteLogin() {
        lock.lock(); let sink = remoteLogin; remoteLogin = nil; remoteLoginOperation = nil; remoteLoginRun = nil; lock.unlock()
        guard let sink else { return }
        let state = snapshot
        let entry = state.step(.authorize)
        let succeeded = entry.status == .done || (entry.status == .waitingUser && entry.message == Self.chooseDomainMessage)
        if succeeded, let zone = state.loginZoneID, let account = dependencies.accounts.snapshot.first(where: { $0.domains.contains { $0.zoneID == zone } }) {
            sink.onEnd(.authorized(account: String(account.displayName.prefix(80)), zones: account.domains.map(\.name).filter { !$0.isEmpty }))
        } else if entry.status == .failed {
            sink.onEnd(.failed(redactedForAI(entry.message)))
        } else {
            sink.onEnd(.cancelled)
        }
    }

    /// W183 R8c（GPT-6 必改 4）：「套用」——用 ChatGPT build 給這台的帳號與網域（使用者選的、這台有授權的）建通道與 DNS、起關口（按了才建）。
    /// 子網域照這台設定的標籤（HandsBuildReconciler 把 build 給這台的子網域寫進設定）。設定進行中、這台沒有那個網域的授權＝false。
    @discardableResult
    func applyURLs(accountID: String, zoneID: String, trigger: HandsSetupTrigger, requester: String? = nil, finished: (() -> Void)? = nil) -> Bool {
        do { try chooseDomain(accountID: accountID, zoneID: zoneID) } catch { return false }
        return enqueue(HandsSetupStep.runOrder, trigger: trigger, allowLogin: false, force: false, hostOverride: nil, requester: requester,
                       apply: true, finished: finished)
    }

    /// W183 R8c 審查（GPT-6 高／中「Apply 沒有原子綁定完整設定快照」）：ChatGPT build 的「套用」（這台與別台都走 HandsBuildExecutor）。
    /// 選網域與佔用工作槽在同一把鎖裡（不會被另一個「套用」插進來改帳號／網域）；工作一開始先核這一份還是 build 給這台的、
    /// 再把子網域寫進設定；建通道、改 DNS、起關口前都再核一次（HandsSetup.planProblem）。設定進行中、選不了網域＝false。
    @discardableResult
    func applyURLs(plan: HandsApplyPlan, trigger: HandsSetupTrigger, requester: String? = nil, finished: (() -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !jobActive, !maintaining else { return false }
        do { try chooseDomain(accountID: plan.accountID, zoneID: plan.zoneID) } catch { return false }
        activePlan = plan
        let started = enqueue(HandsSetupStep.runOrder, trigger: trigger, allowLogin: false, force: false, hostOverride: nil, requester: requester,
                              apply: true, prelude: { [weak self] in self?.adoptPlan(plan) ?? false }, finished: finished)
        if !started { activePlan = nil }
        return started
    }

    /// 工作一開始：這一份還是 build 給這台的（沒改過、沒被關過）才把子網域寫進設定。不對＝寫在第 4 步上、不往下做。
    private func adoptPlan(_ plan: HandsApplyPlan) -> Bool {
        if let problem = planProblem(plan, checkLabel: false) { _ = fail(.tunnel, problem); return false }
        // 網域名稱（帳號清單裡還是空的）＝用 build 設定的（主機名＝子網域＋網域）。
        let domain = String(plan.hostname.dropFirst(plan.subdomain.count + 1))
        if snapshot.domain == nil, plan.hostname.hasPrefix(plan.subdomain + "."), HandsGatewayLaunch.validHost(domain) != nil {
            mutate { if $0.zoneID == plan.zoneID, $0.domain == nil { $0.domain = domain } }
        }
        if dependencies.loadSettings().effectiveSubdomainLabel != plan.subdomain {
            do { try dependencies.updateSettings { $0.subdomainLabel = plan.subdomain } }
            catch { _ = fail(.tunnel, "設定存不進去（磁碟滿？）；空出空間後再按「套用」"); return false }
        }
        return true
    }

    /// 這一輪「套用」拍下的那一份還成立嗎（還勾這台、同一份網域與子網域、撤銷世代沒換、流程記的帳號與網域沒被換）。nil＝成立。
    private func planProblem(_ plan: HandsApplyPlan, checkLabel: Bool = true) -> String? {
        guard let local = dependencies.localDeviceID(), case .active(let slice, _) = dependencies.buildPermit(local),
              slice.subdomain == plan.subdomain, slice.accountID == plan.accountID, slice.zoneID == plan.zoneID, slice.hostname == plan.hostname,
              slice.revocationGeneration == plan.revocationGeneration else { return Self.planChangedMessage }
        let state = snapshot
        guard state.accountID == plan.accountID, state.zoneID == plan.zoneID else { return Self.planChangedMessage }
        if checkLabel, dependencies.loadSettings().effectiveSubdomainLabel != plan.subdomain { return Self.planChangedMessage }
        return nil
    }

    /// 這一個設定工作的那一份（沒有＝不是 ChatGPT build 的「套用」：舊的單主機流程）。
    private var currentPlan: HandsApplyPlan? { lock.lock(); defer { lock.unlock() }; return activePlan }

    /// 取消：收掉正在跑的 cloudflared（例如等授權），步驟回到「還沒做」；也撤銷「登入完自動接著做」。
    func cancel() {
        lock.lock()
        cancelRequested = true
        generation &+= 1
        let hadRequest = hostChangeValue != nil
        hostChangeValue = nil   // W183 R6a 審查：換主機的請求綁在世代上，取消就作廢
        let command = runningCommand
        lock.unlock()
        if hadRequest { DispatchQueue.main.async { [weak self] in self?.hostChangeRequest = nil } }
        command?.cancel()
    }

    /// TAP 關掉開關之後：取消進行中的設定；副設備是主機就通知主設備「這台不當主機了」（一次只有一台主機的交接）。
    func turnedOff() {
        cancel()
        dependencies.cancelConnect("switched_off")   // W183 R6a：關開關＝這次連線作廢（HandsConnectFlow）
        if let local = dependencies.localDeviceID() { dependencies.buildSwitchedOff(local) }   // W183 R8c 審查：中央設定也取消勾這台
        work.async { [weak self] in self?.releaseAfterOff() }
    }

    /// 副設備是主機＝告訴主設備「這台不當主機了」（W183 R6a：關開關＝交回；不成功就記下來，那一列給「交回主設備」）。
    /// W183 R6a 審查（GPT-6）：交回之前「關」要確定存進磁碟、關口停了（stopBeforeRelease）；做不到就不交回。
    private func releaseAfterOff() {
        if dependencies.hostNeedsRelease(), let problem = stopBeforeRelease() ?? dependencies.releaseHost() {
            set(.host, .failed, problem)
            publishHandback(problem)
            return
        }
        publishHandback(nil)
        if dependencies.loadSettings().hostDeviceID == nil, snapshot.step(.host).status != .pending {
            set(.host, .pending, "主機交回主設備；再打開時會用主設備")
        }
    }

    /// W183 R6a 審查（GPT-6「交回主機接受只在記憶體關閉，可能重開後雙主機」）：交回主設備之前——「關」要確定存進磁碟（不是只在記憶體
    /// 強制關閉：重開 App 會讀到舊的「開著」）、關口與通道真的停了。做不到就不交回（主設備收到就可能把主機給別台）。回 nil＝可以交回。
    private func stopBeforeRelease() -> String? {
        var notSaved = false
        do { try dependencies.updateSettings { $0.enabled = false } }
        catch HandsSettingsFailure.offButNotSaved { notSaved = true }
        catch { /* 設定已存、只有撤銷紀錄沒存成；或本來就關著、這次存不進去——下面照磁碟上的樣子判斷 */ }
        dependencies.serviceChanged()
        if notSaved || !dependencies.offPersisted() || dependencies.loadSettings().enabled { return Self.handbackNotSavedMessage }
        let deadline = Date().addingTimeInterval(dependencies.stopWait)
        while case .running = dependencies.servicePhase(), Date() < deadline { Thread.sleep(forTimeInterval: dependencies.pollInterval) }
        if case .running = dependencies.servicePhase() { return Self.handbackStillRunningMessage }
        return nil
    }

    /// W183 R6a：「交回主設備」（副設備當了主機、交回沒成功那一列的鈕；開關開沒開都可以按）。
    /// 先照關掉的順序停下這台（取消；工作裡關開關＝撤銷這台的連線、叫關口停、確定存進磁碟），再告訴主設備；主設備收到才算交回。
    func handBack() {
        cancel()
        dependencies.cancelConnect("host_changed")
        work.async { [weak self] in self?.releaseAfterOff() }
    }

    /// TAP 選帳號與網域：換帳號＝要新通道；只換網域＝同一條通道、新網址。設定進行中不准換（W183 R3 審查）。
    func chooseDomain(accountID: String, zoneID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !jobActive, !maintaining else { throw HandsSetupError.busy }   // W183 R6a 審查：清通道時也不換（它綁著這個帳號）
        try dependencies.accounts.select(accountID: accountID, zoneID: zoneID)
        let domain = dependencies.accounts.account(accountID)?.domains.first { $0.zoneID == zoneID }?.name
        mutate { state in
            if state.accountID != accountID {
                state.tunnelID = nil; state.tunnelName = nil; state.publicHost = nil   // tokenTunnelID 保留：鑰匙圈裡的 token 還是舊通道的
            } else if state.zoneID != zoneID {
                state.publicHost = nil
            }
            if state.zoneID != zoneID { state.confirmToken = HandsSetup.randomLabel(24) }   // W183 R3b：換了就是另一輪的確認
            state.accountID = accountID
            state.zoneID = zoneID
            state.domain = (domain?.isEmpty ?? true) ? nil : domain
            for step in [HandsSetupStep.tunnel, .start, .url, .remember] where state.step(step).status == .done {
                state.steps[step.rawValue] = HandsSetupStepState(status: .pending, message: "換了網域；按「重試」重建網址", updatedAt: Date())
            }
        }
    }

    /// 環境登入 › Cloudflare 的「移除」（W183 R3 審查）：設定進行中不行；是手腳正在用的（鑰匙圈裡的通道 token 是它的通道、
    /// 或設定流程選的就是它）＝先安全停用（關開關＝撤銷全部 ChatGPT 連線、關口停下），再刪通道 token、授權與清單。
    /// 後面哪一步失敗都不會跳過停機。完成後在主執行緒回呼（nil＝成功，否則白話原因）。
    func removeAccount(_ accountID: String, completion: @escaping (String?) -> Void) {
        lock.lock()
        guard !jobActive else {
            lock.unlock()
            DispatchQueue.main.async { completion(HandsSetupError.busy.description) }
            return
        }
        jobActive = true
        lock.unlock()
        publishBusy(true)
        work.async { [weak self] in
            guard let self else { return }
            let problem = self.performRemoval(accountID)
            self.lock.lock(); self.jobActive = false; self.lock.unlock()
            self.publishBusy(false)
            DispatchQueue.main.async { completion(problem) }
        }
    }

    private func performRemoval(_ accountID: String) -> String? {
        guard let account = dependencies.accounts.account(accountID) else { return nil }
        let state = snapshot
        let tokenIsTheirs = account.tunnelID != nil && account.tunnelID == state.tokenTunnelID
        let selected = state.accountID == accountID
        let inUse = tokenIsTheirs || selected || (account.tunnelID != nil && account.tunnelID == state.tunnelID)
        var problems: [String] = []
        if inUse {
            do { try dependencies.updateSettings { $0.enabled = false } } catch { problems.append("關不掉 ChatGPT 手腳的開關") }
            dependencies.serviceChanged()
            let deadline = Date().addingTimeInterval(8)
            while case .running = dependencies.servicePhase(), Date() < deadline { Thread.sleep(forTimeInterval: dependencies.pollInterval) }
            if case .running = dependencies.servicePhase() { problems.append("關口還沒停下來") }
        }
        let removeToken = tokenIsTheirs || (selected && state.tokenTunnelID == nil && dependencies.accounts.hasTunnelToken())
        do { try dependencies.accounts.remove(accountID: accountID, removeTunnelToken: removeToken) } catch {
            problems.append("鑰匙圈裡的授權刪不掉（鑰匙圈鎖著？）")
        }
        if selected || removeToken {
            mutate { value in
                if value.accountID == accountID {
                    value.accountID = nil; value.zoneID = nil; value.domain = nil
                    value.tunnelID = nil; value.tunnelName = nil; value.publicHost = nil
                }
                if removeToken { value.tokenTunnelID = nil }
                if let zone = value.loginZoneID, account.domains.contains(where: { $0.zoneID == zone }) { value.loginZoneID = nil }   // W183 R3b
                // W183 R3b 審查：帳號整個移除了＝它的網域不用再確認；「取消並重新授權」要清的就是它＝已經清完。
                let zones = Set(account.domains.map(\.zoneID))
                value.unconfirmedZoneIDs = value.unconfirmedZoneIDs.map { $0.filter { !zones.contains($0) } }
                if problems.isEmpty, value.discard?.accountID == accountID { value.discard = nil }
                for step in [HandsSetupStep.authorize, .tunnel, .start, .url, .remember] where value.step(step).status == .done {
                    value.steps[step.rawValue] = HandsSetupStepState(status: .pending, message: "Cloudflare 帳號移除了；要再用請重新登入", updatedAt: Date())
                }
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "、") + "；解鎖或稍後再按一次「移除」"
    }

    /// W183 R3b：「取消並重新授權」的清除（在設定工作裡、重開授權頁之前做）。順序跟移除帳號一樣：
    /// 0. 先把要清的那一筆記下來（discard；清到一半失敗，重按會照這筆接著清——冪等；清完才拿掉）；
    /// 1. 手腳已經在用這個授權（關口在跑、建了通道、鑰匙圈的通道 token 是它的）＝先關開關、等關口停下（這時還沒配對，沒有連線要撤銷）；
    /// 2. 這次登入拿到的憑證（loginZoneID 對得上、或還沒確認）＝刪掉這個網域的授權；帳號沒有別的網域就整個移除；
    ///    沿用環境登入原本就有的帳號＝不刪，只是不用它、重新登入；
    /// 3. 鑰匙圈的通道 token 是這個帳號的通道＝刪掉（W183 R3b 審查：不看帳號有沒有整個移除；其他網域的授權留著）；
    /// 4. 流程回到第 3 步（帳號、網域、通道、網址都清掉）。回 false＝停在第 3 步並說明原因（discard 留著，畫面給「重按一次」）。
    private func discardAuthorization() -> Bool {
        var state = snapshot
        if state.discard == nil {
            guard let accountID = state.accountID, let zoneID = state.zoneID else { return true }
            let account = dependencies.accounts.account(accountID)
            let tokenIsTheirs = account?.tunnelID != nil && account?.tunnelID == state.tokenTunnelID
            // W183 R6a 審查：只看「這次登入拿到的」（loginZoneID）——換用環境登入原本就有的帳號時也要確認（還沒確認），但那不是這次登入拿到的，不刪。
            let record = HandsSetupDiscard(accountID: accountID, zoneID: zoneID,
                                           fromLogin: state.loginZoneID == zoneID,
                                           tokenTunnelID: tokenIsTheirs ? state.tokenTunnelID : nil)
            mutate { $0.discard = record }
            state = snapshot
        }
        guard let record = state.discard else { return true }
        let phase = dependencies.servicePhase()
        let running: Bool = { if case .running = phase { return true }; return false }()
        set(.authorize, .running, "取消剛才的授權…")
        if dependencies.loadSettings().enabled, running || state.tunnelID != nil || record.tokenTunnelID != nil || state.publicHost != nil {
            do { try dependencies.updateSettings { $0.enabled = false } } catch {
                _ = fail(.authorize, "關不掉 ChatGPT 手腳的開關；稍後再按一次「取消並重新授權」")
                return false
            }
            dependencies.serviceChanged()
            let deadline = Date().addingTimeInterval(8)
            while case .running = dependencies.servicePhase(), Date() < deadline { Thread.sleep(forTimeInterval: dependencies.pollInterval) }
            if case .running = dependencies.servicePhase() {
                _ = fail(.authorize, "關口還沒停下來；等一下再按一次「取消並重新授權」")
                return false
            }
        }
        if record.fromLogin {
            do { _ = try dependencies.accounts.removeDomain(accountID: record.accountID, zoneID: record.zoneID, removeTunnelToken: false) }
            catch {
                _ = fail(.authorize, "鑰匙圈裡剛才的授權刪不掉（鑰匙圈鎖著？）；解鎖後再按一次「取消並重新授權」")
                return false
            }
        }
        if let tunnel = record.tokenTunnelID, snapshot.tokenTunnelID == tunnel {
            do { try dependencies.accounts.removeTunnelToken() }
            catch {
                _ = fail(.authorize, "鑰匙圈裡這一輪的通道 token 刪不掉（鑰匙圈鎖著？）；解鎖後再按一次「取消並重新授權」")
                return false
            }
            mutate { if $0.tokenTunnelID == tunnel { $0.tokenTunnelID = nil } }
        }
        mutate { value in
            if value.accountID == record.accountID, value.zoneID == record.zoneID {
                value.accountID = nil; value.zoneID = nil; value.domain = nil
                value.tunnelID = nil; value.tunnelName = nil; value.publicHost = nil
            }
            value.loginZoneID = nil
            value.unconfirmedZoneIDs = value.unconfirmedZoneIDs.map { $0.filter { $0 != record.zoneID } }
            value.confirmToken = nil
            value.discard = nil
            for step in [HandsSetupStep.authorize, .tunnel, .start, .url, .remember] {
                value.steps[step.rawValue] = HandsSetupStepState(status: .pending, message: "取消了剛才的授權；重新開 Cloudflare 授權頁", updatedAt: Date())
            }
        }
        return true
    }

    /// prelude（W183 R3b）：在同一個工作裡、步驟之前先做的事（「取消並重新授權」的清除）；回 false＝不往下做。
    @discardableResult
    private func enqueue(_ steps: [HandsSetupStep], trigger: HandsSetupTrigger, allowLogin: Bool, force: Bool,
                         hostOverride: String?, forceOnly: Set<HandsSetupStep>? = nil, requester: String? = nil,
                         approvedHost: String? = nil, apply: Bool = false, prelude: (@Sendable () -> Bool)? = nil,
                         finished: (() -> Void)? = nil) -> Bool {
        lock.lock()
        guard !jobActive else { lock.unlock(); return false }
        jobActive = true
        applyRun = apply   // W183 R8 整合審查：這個工作是不是「套用」（佔用工作槽同一把鎖裡記）
        cancelRequested = false
        currentRun = (Self.randomLabel(16), trigger == .remote ? requester : nil)   // W183 R5b 審查
        lock.unlock()
        publishBusy(true)
        work.async { [weak self] in
            guard let self else { return }
            if let reason = self.unblock() {
                // 擋在第一個要做的步驟上（畫面與工具都看得到原因）。
                self.publishProblem(reason)
                let state = self.snapshot
                if let target = steps.first(where: { state.step($0).status != .done }) ?? steps.first { _ = self.fail(target, reason) }
            } else if let prelude, !prelude() {
                self.publishProblem(nil)   // prelude 自己把原因寫在步驟上
            } else {
                self.publishProblem(nil)
                // W183 R8c（GPT-6 必改 4）：登入完不再「同一個工作裡接著跑」（登入只是登入；建網址要使用者按「套用」）。
                self.runSteps(steps, trigger: trigger, allowLogin: allowLogin, force: force, hostOverride: hostOverride, forceOnly: forceOnly,
                              approvedHost: approvedHost)
            }
            // 取消的收尾（步驟回到「還沒做」）在放掉「忙碌中」之前做完：畫面與工具看到不忙時，狀態已經是最後的。
            if self.cancelled { self.markCancelled() }
            self.lock.lock()
            self.jobActive = false
            self.runningCommand = nil
            self.currentRun = nil
            self.activePlan = nil   // W183 R8c 審查：「套用」拍下的那一份只屬於這一個工作
            self.applyRun = false
            self.lock.unlock()
            self.publishBusy(false)
            DispatchQueue.main.async { MainActor.assumeIsolated { HandsSetup.returnAfterAuthorize = nil } }
            finished?()   // W183 R8c：信箱的登入、套用要知道這一輪結束了（在「忙碌」放掉之後：狀態已經是最後的）
        }
        return true
    }

    /// 照順序做（跳過已完成而且現在還成立的）；停在要使用者按的、失敗的、被取消的那一步。
    private func runSteps(_ steps: [HandsSetupStep], trigger: HandsSetupTrigger, allowLogin: Bool, force: Bool,
                          hostOverride: String?, forceOnly: Set<HandsSetupStep>?, approvedHost: String? = nil) {
        for step in steps {
            if cancelled { break }
            let forced = forceOnly.map { $0.contains(step) } ?? force
            if !forced, snapshot.step(step).status == .done, stillSatisfied(step, trigger: trigger) { continue }
            let outcome = perform(step, trigger: trigger, allowLogin: allowLogin, force: forced, hostOverride: hostOverride, approvedHost: approvedHost)
            if outcome != .done { break }
        }
    }

    private func markCancelled() {
        mutate { state in
            for (key, value) in state.steps where value.status == .running || value.status == .waitingUser {
                // W183 R7a：訊息裡的按鈕名稱跟畫面一致（授權那一步出錯時那一列的鈕是「重新授權」）。
                state.steps[key] = HandsSetupStepState(status: .pending, message: Self.cancelledMessage(key), updatedAt: Date())
            }
        }
        publishLoginURL(nil)
    }

    /// 已完成的步驟現在還成立嗎（例如 token 被刪、關口停了、主機交出去了）。不成立就重做。
    private func stillSatisfied(_ step: HandsSetupStep, trigger: HandsSetupTrigger) -> Bool {
        let state = snapshot
        switch step {
        case .host:
            guard let local = dependencies.localDeviceID(), let host = state.hostDeviceID,
                  let configured = dependencies.loadSettings().hostDeviceID else { return false }
            // W183 R6a 審查（GPT-6）：副設備還要有這個行程裡主設備確認過的租約（重開後要先問主設備）。
            return host.caseInsensitiveCompare(local) == .orderedSame && configured.caseInsensitiveCompare(local) == .orderedSame
                && dependencies.hostLeaseHeld(local)
        case .cloudflared: return dependencies.locateCloudflared() != nil
        case .authorize:
            // W183 R3b 審查：還沒確認、或「取消並重新授權」沒清完＝不算完成（回到第 3 步由使用者按）。
            guard state.discard == nil, !state.isUnconfirmed(state.zoneID) else { return false }
            return state.zoneID.map(dependencies.accounts.hasCert) ?? false
        case .tunnel:
            // W183 R6a：網址要是固定的 `<標籤>.<網域>`（以前的隨機子網域＝不成立，重做這一步＝遷移）。
            // W183 R6a 審查（Claude）：自動續跑不遷移（以前的隨機網址先當成立，等使用者按開關或「重試」才換）。
            // W183 R8c 審查（GPT-6／Claude 高）：自動續跑與助理只恢復「已經套用」的網址——子網域在 build 改了（期望的網址變了）也照用現在的，
            // 不建 DNS、不換網址、不撤銷連線；要換等使用者按「套用」（.user／.remote）。
            return state.tunnelID != nil && state.publicHost != nil && state.tokenTunnelID == state.tunnelID
                && dependencies.accounts.hasTunnelToken() && (isFixedHost(state.publicHost, state: state) || keepsCurrentHost(state, trigger: trigger))
        case .start, .url:
            guard case .running = dependencies.servicePhase() else { return false }
            // W183 R6a：網址換了（隨機→固定）＝關口要照新的網址重開；舊紀錄還沒刪＝第 6 步再試一次。
            guard HandsHostAuthority.same(dependencies.loadSettings().publicHost, state.publicHost) else { return false }
            return step == .start || state.retiredHost == nil
        case .pairing: return dependencies.hasActiveGrant()
        case .remember:
            guard let account = state.accountID.flatMap(dependencies.accounts.account) else { return false }
            return account.selectedDomain == state.zoneID && account.tunnelID == state.tunnelID
        }
    }

    /// 畫面與工具看狀態前：把「已完成但現在不成立」與「使用者已經做完」的步驟對上現況（不跑任何指令）。
    static func liveStartStep(_ stored: HandsSetupStepState, phase: ChatGPTHandsService.Phase) -> HandsSetupStepState {
        switch phase {
        case .running:
            return .init(status: .done, message: "運作中", updatedAt: stored.updatedAt)
        case .starting:
            return .init(status: .running, message: "啟動關口與通道…", updatedAt: stored.updatedAt)
        case .failed:
            return .init(status: .failed, message: "沒在跑：\(ChatGPTHandsService.statusText(phase))", updatedAt: stored.updatedAt)
        case .stopped:
            if stored.status == .failed {
                let message = stored.message.hasPrefix("沒在跑：") ? stored.message : "沒在跑：\(stored.message)"
                return .init(status: .failed, message: message, updatedAt: stored.updatedAt)
            }
            return .init(status: .pending, message: "沒在跑：\(ChatGPTHandsService.statusText(phase))", updatedAt: stored.updatedAt)
        }
    }

    func refreshDerived() {
        guard !isBusy else { return }
        let state = snapshot
        var changes: [(HandsSetupStep, HandsSetupStepState)] = []
        let phase = dependencies.servicePhase()
        let running: String? = { if case .running(let url) = phase { return url }; return nil }()
        if state.step(.pairing).status != .done, dependencies.hasActiveGrant() {
            changes.append((.pairing, .init(status: .done, message: "已配對（有一筆有效的授權）", updatedAt: Date())))
        }
        if let url = running, state.publicHost != nil {
            if state.step(.start).status != .done { changes.append((.start, .init(status: .done, message: "運作中", updatedAt: Date()))) }
            if state.step(.url).status != .done { changes.append((.url, .init(status: .done, message: Self.urlMessage(url), updatedAt: Date()))) }
        } else if state.step(.start).status == .done || state.step(.start).message.hasPrefix("沒在跑：") {
            let live = Self.liveStartStep(state.step(.start), phase: phase)
            if live != state.step(.start) { changes.append((.start, live)) }
            if state.step(.url).status == .done { changes.append((.url, .init(status: .pending, message: "等關口起來", updatedAt: Date()))) }
        }
        if state.step(.tunnel).status == .done, !dependencies.accounts.hasTunnelToken() {
            changes.append((.tunnel, .init(status: .pending, message: "鑰匙圈裡的通道 token 不見了；按「重試」", updatedAt: Date())))
        }
        guard !changes.isEmpty else { return }
        mutate { value in for (step, entry) in changes { value.steps[step.rawValue] = entry } }
    }

    static func urlMessage(_ url: String) -> String {
        "\(url)——ChatGPT 的連接器由 App 在 ChatGPT Space 自動建：使用者在私訊框按［連線］就好"   // W183 R7a：不露內部代號
    }

    /// 接下來該做哪一步（第一個還沒完成的；照執行順序）。
    var nextStep: HandsSetupStep? {
        let state = snapshot
        return HandsSetupStep.runOrder.first { state.step($0).status != .done }
    }

    /// 開關開著、但關口還沒到能用的那一步（第 1–6 步有沒做完的）：畫面顯示「設定中：第 N 步」，不顯示關口的失敗原因（W183 R3 審查）。
    static func settingUpStep(_ state: HandsSetupState) -> HandsSetupStep? {
        HandsSetupStep.runOrder.prefix(while: { $0 != .remember }).first { state.step($0).status != .done }
    }

    // MARK: - 各步驟

    private func perform(_ step: HandsSetupStep, trigger: HandsSetupTrigger, allowLogin: Bool, force: Bool, hostOverride: String?,
                         approvedHost: String? = nil) -> Outcome {
        switch step {
        case .host: return stepHost(requested: hostOverride, trigger: trigger, approved: approvedHost)
        case .cloudflared: return stepCloudflared()
        case .authorize: return stepAuthorize(allowLogin: allowLogin, force: force, trigger: trigger)
        case .tunnel: return stepTunnel(force: force, trigger: trigger)
        case .start: return stepStart(trigger: trigger)
        case .url: return stepURL()
        case .pairing: return stepPairing(trigger: trigger)
        case .remember: return stepRemember()
        }
    }

    private func stepHost(requested: String?, trigger: HandsSetupTrigger, approved: String?) -> Outcome {
        guard let local = dependencies.localDeviceID(), !local.isEmpty else {
            return fail(.host, "這台還沒有設備身分；先到「設定 › 設備」完成設定")
        }
        let devices = dependencies.devices()
        let name = devices.first { $0.id.caseInsensitiveCompare(local) == .orderedSame }?.name ?? "這台"
        // W183 R8c（GPT-6 必改 1）：沒有「一次只有一台主機」了——每台被勾選的設備自己當自己的主機（設定在主設備，ChatGPT build）。
        // 這一步只看這台的啟用許可；不認領、不交出、不叫別台停。要用別台＝在 ChatGPT build 勾那台（那台自己跑自己的）。
        if let requested, !requested.isEmpty, requested.caseInsensitiveCompare(local) != .orderedSame {
            return fail(.host, Self.otherDeviceRunsItselfMessage)
        }
        var permit = dependencies.buildPermit(local)
        // 使用者 09-28「沒有副設備的人一率主設備」：使用者在這台打開、設定裡一台都沒勾＝勾這台（只有正本這台、只有使用者按的；助理與自動續跑不改設定）。
        if !permit.isActive, trigger == .user || trigger == .remote, dependencies.buildSelectDefault(local) {
            permit = dependencies.buildPermit(local)
        }
        switch permit {
        case .active:
            if dependencies.loadSettings().hostDeviceID.map({ $0.caseInsensitiveCompare(local) != .orderedSame }) ?? true {
                do { try dependencies.updateSettings { $0.hostDeviceID = local } } catch { return fail(.host, "設定存不進去") }
            }
            mutate { $0.hostDeviceID = local }
            publishHandback(nil)
            return done(.host, "主機：這台（\(name)）")
        case .paused:
            return fail(.host, Self.leaseUnreachableMessage)
        case .inactive, .none:
            return fail(.host, Self.notSelectedMessage)
        }
    }

    private func stepCloudflared() -> Outcome {
        if let found = dependencies.locateCloudflared() {
            mutate { $0.cloudflaredSource = found.source.rawValue }
            return done(.cloudflared, "用 TATWO 下載、驗過雜湊的 cloudflared \(HandsCloudflared.pinnedVersion)（每次用前再驗）")
        }
        set(.cloudflared, .running, "下載 cloudflared \(HandsCloudflared.pinnedVersion)（固定版本、驗 sha256；不自動更新）…")
        let result = HandsLocked<Result<HandsCloudflared.Location, HandsCloudflared.Failure>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        dependencies.installCloudflared { outcome in result.set(outcome); finished.signal() }
        let deadline = Date().addingTimeInterval(dependencies.downloadTimeout)
        while finished.wait(timeout: .now() + dependencies.pollInterval) == .timedOut {
            if cancelled { return .stopped }
            if Date() > deadline { return fail(.cloudflared, "下載 cloudflared 太久沒完成；稍後按「重試」") }
        }
        switch result.get() {
        case .success(let location)?:
            mutate { $0.cloudflaredSource = location.source.rawValue }
            return done(.cloudflared, "已下載 cloudflared \(HandsCloudflared.pinnedVersion)（雜湊對過）")
        case .failure(let failure)?:
            return fail(.cloudflared, failure.description)
        case nil:
            return fail(.cloudflared, "下載 cloudflared 失敗")
        }
    }

    /// 流程記的那一組（帳號＋網域）現在還能用（授權還在、已確認）。W183 R6a 審查。
    private func recordedAccountDomain() -> (CloudflareAccount, CloudflareDomain)? {
        let state = snapshot
        guard let accountID = state.accountID, let zone = state.zoneID, !state.isUnconfirmed(zone), dependencies.accounts.hasCert(zoneID: zone),
              let account = dependencies.accounts.snapshot.first(where: { $0.id == accountID }),
              let domain = account.domains.first(where: { $0.zoneID == zone }) else { return nil }
        return (account, domain)
    }

    /// W183 R3b 審查：第 4 步以後（建通道、改 DNS、啟動、記住）先過這關：授權還沒確認、或「取消並重新授權」沒清完＝不做。
    private func authorizationGate() -> String? {
        let state = snapshot
        if state.discard != nil { return Self.cleanupPendingMessage }
        if state.isUnconfirmed(state.zoneID) { return Self.confirmFirstMessage }
        return nil
    }

    private enum PrepareFailure: Error { case folder, leftovers }

    private func prepareSetupHome() throws -> (home: URL, config: URL) {
        do {
            try HandsFiles.ensureDirectory(dependencies.paths.root)
            try HandsFiles.ensureDirectory(setupHome)
        } catch { throw PrepareFailure.folder }
        let dotDir = setupHome.appendingPathComponent(".cloudflared", isDirectory: true)
        do { try HandsFiles.ensureDirectory(dotDir) } catch { throw PrepareFailure.folder }
        guard Self.removeLeftovers(in: setupHome, dotDir: dotDir) else {
            lock.lock(); blockedReason = Self.leftoverMessage; lock.unlock()
            publishProblem(Self.leftoverMessage)
            throw PrepareFailure.leftovers
        }
        let config = setupHome.appendingPathComponent("config.yml")
        do { try HandsFiles.writeAtomically(Data("# TATWO OS ChatGPT 手腳：設定流程用，不含任何秘密\nno-autoupdate: true\n".utf8), to: config) }
        catch { throw PrepareFailure.folder }
        return (setupHome, config)
    }

    private static func prepareMessage(_ error: Error) -> String {
        (error as? PrepareFailure) == .leftovers ? leftoverMessage : "準備不了 TATWO 的設定資料夾"
    }

    /// 上次留下的暫存憑證、憑證檔、通道憑證 json：只看這兩個資料夾第一層、只刪名字對得上的。回傳有沒有全部清掉（清不掉＝擋住流程）。
    @discardableResult
    static func removeLeftovers(in home: URL, dotDir: URL) -> Bool {
        var clean = true
        for name in (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        where name.hasPrefix("oc-") || name.hasPrefix("cred-") {
            if unlink(home.appendingPathComponent(name).path) != 0, errno != ENOENT { clean = false }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dotDir.path)) ?? [] {
            if unlink(dotDir.appendingPathComponent(name).path) != 0, errno != ENOENT { clean = false }
        }
        return clean
    }

    /// 讀 cloudflared 寫的小檔：不跟隨捷徑、一般檔、屬於自己、64 KiB 以內。exposed＝群組或其他人讀得到（看門程式設了 umask 077，不該發生）。
    static func readSmallFile(_ url: URL) -> (text: String?, exposed: Bool) {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return (nil, false) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 64 * 1024 else { return (nil, false) }
        guard (info.st_mode & 0o077) == 0 else { return (nil, true) }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, Int(info.st_size)) }
        guard count == Int(info.st_size) else { return (nil, false) }
        return (String(data: data, encoding: .utf8), false)
    }

    private func stepAuthorize(allowLogin: Bool, force: Bool, trigger: HandsSetupTrigger) -> Outcome {
        // W183 R3b 審查：上次「取消並重新授權」沒清完＝一律擋（不重新採用、不另外登入），只能重按那個鈕。
        if snapshot.discard != nil { return fail(.authorize, Self.cleanupPendingMessage) }
        // 在瀏覽器登入拿到、還沒確認的：停在「等你確認帳號與網域」（重按「繼續」不會跳過確認）。
        if !force, snapshot.awaitingConfirmation, let zone = snapshot.zoneID, dependencies.accounts.hasCert(zoneID: zone) {
            if snapshot.confirmToken == nil { mutate { $0.confirmToken = HandsSetup.randomLabel(24) } }
            return waitUser(.authorize, domainName(accountID: snapshot.accountID, zoneID: zone) == nil ? Self.namesUnknownMessage : Self.confirmWaitingMessage)
        }
        if !force {
            // W183 R8c（GPT-6 必改 4：登入只是登入、網址要使用者選）：只用**明確選好**的那一組（ChatGPT build 的 Cloudflare 節點、
            // 「套用」、環境登入的選用）；不再自動挑「帳號裡選好的／第一個有授權的」、不再換用別的帳號（不 adopt）。
            if case let (_, domain)? = recordedAccountDomain() {
                return done(.authorize, "用已登入的 Cloudflare 帳號（\(domain.name.isEmpty ? "網域名稱建通道時補上" : domain.name)），不用再登入")
            }
            // 自動續跑只接受原本確認過的那一組（不換、不開授權頁）。
            if trigger == .resume { return waitUser(.authorize, Self.resumeNeedsLoginMessage) }
            // 已經登入過（有帳號、有授權）但還沒選網域：停在「選網域」（不自己挑）。
            if dependencies.accounts.snapshot.contains(where: { account in account.domains.contains { dependencies.accounts.hasCert(zoneID: $0.zoneID) } }) {
                return waitUser(.authorize, Self.chooseDomainMessage)
            }
        }
        guard allowLogin else {
            // 自動續跑、環境登入以外不開授權頁；也不記「登入完接著做」（W183 R8c：登入完一律停下）。
            if trigger == .resume { return waitUser(.authorize, Self.resumeNeedsLoginMessage) }
            return waitUser(.authorize, Self.needsLoginMessage)
        }
        // W183 R8c（GPT-6 必改 3）：別台按的登入只走信箱（loginForRemote：網址只給按的那台）；舊的遠端開始／繼續／重新授權不開授權頁
        // （網址已經不放進所有設備都輪詢的狀態，開了也沒有人看得到，只會卡著一個 cloudflared）。
        if trigger == .remote {
            lock.lock(); let owner = remoteLogin; lock.unlock()
            if owner == nil { return waitUser(.authorize, Self.needsLoginMessage) }
        }
        guard let cloudflared = dependencies.locateCloudflared() else { return fail(.authorize, "先完成第 2 步（cloudflared）") }
        let prepared: (home: URL, config: URL)
        do { prepared = try prepareSetupHome() } catch { return fail(.authorize, Self.prepareMessage(error)) }
        let home = prepared.home, config = prepared.config
        let dotDir = home.appendingPathComponent(".cloudflared", isDirectory: true)
        let certFile = dotDir.appendingPathComponent("cert.pem")
        set(.authorize, .running, "開 Cloudflare 授權頁…")
        // W183 R5b 審查（GPT-6）：這一輪的識別碼；所有退出路徑的最後一道收尾都作廢它、收掉這一輪的授權頁。
        let round = UUID()
        lock.lock(); loginRound = (round, false); lock.unlock()
        defer { endLoginRound(round); settleLoginPages(round, done: false) }   // W183 R8b 審查：沒標完成的一律收掉
        let opened = HandsLocked(false), foreignURL = HandsLocked(false)
        let exitCode = HandsLocked<Int32??>(nil)
        // 授權頁開過（設定浮層因此關掉了）：這一步結束時帶使用者回原本那一頁；登入完要接著做的，回 TAP › ChatGPT 看進度。
        defer {
            let reopen = opened.get()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let page = HandsSetup.returnAfterAuthorize
                    HandsSetup.returnAfterAuthorize = nil
                    if reopen, let page { HandsSetup.open(page) }
                }
            }
        }
        let command: HandsRunningCommand
        do {
            command = try dependencies.runner.start(
                cloudflared: cloudflared.url, arguments: ["tunnel", "--no-autoupdate", "--config", config.path, "login"],
                home: home, handsRoot: dependencies.paths.root,
                onLine: { [weak self] line in
                    guard let self else { return }
                    if let url = HandsCloudflared.loginURL(in: line) {
                        // W183 R5b 審查：這一輪還有效、還沒發布過才算（逾時、取消收尾之後晚到的輸出不會再開頁）。
                        // W183 R3b：網址不寫進訊息（訊息會給 AI、會存檔）；人在別台就到那台的 TAP › ChatGPT 按「在這台打開授權頁」。
                        guard self.publishRoundURL(url, round: round,
                                                   message: trigger == .remote ? Self.authorizeWaitingRemoteMessage : Self.authorizeWaitingMessage) else { return }
                        opened.set(true)
                        // W183 R5b：誰按的在誰那台開——副設備按的（.remote）主機不開，副設備拿到 login_url 自己在它的私訊框開。
                        // W183 R8c：信箱替別台登入＝網址只交給按的那台（擁有者；經主設備只給它），不進公共狀態。
                        if trigger != .remote { self.openIfCurrent(url, round: round) } else { self.deliverRemoteLoginURL(url) }
                    } else if HandsCloudflared.anyURL(in: line) {
                        foreignURL.set(true)
                    }
                },
                onExit: { code in exitCode.set(.some(code)) })
        } catch { return fail(.authorize, "cloudflared 開不起來") }
        lock.lock(); runningCommand = command; lock.unlock()
        trackRunner(command)
        let deadline = Date().addingTimeInterval(dependencies.loginTimeout)
        // 取消或逾時：收掉（看門程式收掉 cloudflared、等它結束、清檔），**確認真的結束**才清 App 這邊、才准重跑；
        // 沒在時限內結束＝留給看門程式清、記成 lingering（結束前不准重跑；T10：舊指令不會在清完之後才把憑證寫進磁碟）。
        func stopAndClean() -> Bool {
            endLoginRound(round)   // W183 R5b 審查：先作廢這一輪（晚到的輸出不再開頁），再停指令
            command.cancel()
            guard command.waitForExit(timeout: dependencies.exitWait) else {
                lock.lock(); lingering = command; runningCommand = nil; lock.unlock()
                return false
            }
            untrackRunner()
            unlink(certFile.path)
            if !Self.removeLeftovers(in: home, dotDir: dotDir) {
                lock.lock(); blockedReason = Self.leftoverMessage; lock.unlock()
                publishProblem(Self.leftoverMessage)
            }
            return true
        }
        var certText: String?
        while true {
            if cancelled {
                return stopAndClean() ? .stopped : fail(.authorize, Self.lingeringMessage)
            }
            if Date() > deadline {
                return fail(.authorize, stopAndClean() ? "等 Cloudflare 授權太久（10 分鐘）；按「重新授權」再開一次授權頁" : Self.lingeringMessage)
            }
            if let code = exitCode.get() {
                // W183 R5b 審查：cloudflared 結束＝這一輪結束（先作廢）。W183 R8b 審查（GPT-6）：授權頁先撤下（分頁寫「確認中」）；
                // 授權檔驗過、存進鑰匙圈才標「完成」，其他任何退出都收掉（不再由「檔案在」決定）。
                endLoginRound(round, withdraw: code == 0)
                untrackRunner()
                let read = Self.readSmallFile(certFile)
                certText = read.text
                unlink(certFile.path)
                if read.exposed {
                    _ = Self.removeLeftovers(in: home, dotDir: dotDir)
                    return fail(.authorize, "cloudflared 寫的授權檔別人也讀得到，已刪掉沒有使用；按「重新授權」")
                }
                if code != 0 || certText == nil {
                    _ = Self.removeLeftovers(in: home, dotDir: dotDir)
                    if foreignURL.get(), !opened.get() { return fail(.authorize, "cloudflared 給的授權網址不是 Cloudflare 的，沒有打開；請確認 cloudflared 是正版") }
                    return fail(.authorize, "Cloudflare 授權沒有完成（取消、逾時或網路不通）；按「重新授權」再試一次")
                }
                break
            }
            Thread.sleep(forTimeInterval: dependencies.pollInterval)
        }
        lock.lock(); runningCommand = nil; lock.unlock()
        guard Self.removeLeftovers(in: home, dotDir: dotDir) else {
            lock.lock(); blockedReason = Self.leftoverMessage; lock.unlock()
            publishProblem(Self.leftoverMessage)
            return fail(.authorize, Self.leftoverMessage)
        }
        guard let pem = certText, let cert = HandsCloudflared.parseOriginCert(pem) else {
            return fail(.authorize, "看不懂 cloudflared 給的授權檔；請更新 TATWO OS 後再試")
        }
        // 網域名稱與帳號名稱：用授權裡的 token 問 Cloudflare 一次（只在記憶體）。問不到＝先記帳號，但網域名稱出現之前不能確認。
        // W183 R3b 審查：等的時候也看取消；取消了就不收憑證（收進去之後才取消＝回滾這一輪新增的網域與帳號）。
        let lookup = HandsLocked<(String?, String?)?>(nil)
        let looked = DispatchSemaphore(value: 0)
        dependencies.lookupZone(cert.zoneID, cert.apiToken) { domain, name in lookup.set((domain, name)); looked.signal() }
        let lookupDeadline = Date().addingTimeInterval(dependencies.lookupTimeout)
        while looked.wait(timeout: .now() + dependencies.pollInterval) == .timedOut {
            if cancelled || Date() > lookupDeadline { break }
        }
        if cancelled { return .stopped }
        let (domainName, accountName) = lookup.get() ?? (nil, nil)
        let existed = dependencies.accounts.account(cert.accountID)
        let domainExisted = existed?.domains.contains { $0.zoneID == cert.zoneID } ?? false
        do {
            try dependencies.accounts.upsert(accountID: cert.accountID, name: accountName,
                                             domain: CloudflareDomain(name: domainName ?? "", zoneID: cert.zoneID), cert: cert.pem)
        } catch { return fail(.authorize, "授權收不進鑰匙圈（鑰匙圈鎖著？）；解鎖後按「重新授權」") }
        dependencies.checkpoint("authorize.afterUpsert")
        if cancelled {
            // 這一輪新增的網域（與新帳號）拿掉；原本就有的網域是同一個網域的授權（網域只屬於一個帳號），留著。
            if !domainExisted { _ = try? dependencies.accounts.removeDomain(accountID: cert.accountID, zoneID: cert.zoneID, removeTunnelToken: false) }
            return .stopped
        }
        guard dependencies.accounts.account(cert.accountID)?.domains.contains(where: { $0.zoneID == cert.zoneID }) == true else {
            return fail(.authorize, "授權存好了，但帳號清單讀不回來")
        }
        // W183 R8c（GPT-6 必改 4）：登入只是登入——授權存進這台的鑰匙圈、帳號清單更新，**到此為止**：不採用這個帳號與網域（不 adopt）、
        // 不改手腳的帳號／網域／通道／網址、不接著建 DNS、不解除安全鎖。要用哪個網域由使用者在 ChatGPT build 選、按「套用」。
        // 「取消並重新授權」只清這次登入拿到的（loginZoneID）。
        mutate { $0.loginZoneID = cert.zoneID }
        settleLoginPages(round, done: true)   // W183 R8b 審查：驗過、存好＝授權分頁標「完成」（W183 R8 整合：接在 R8c 的「登入只是登入」之後）
        if case let (_, domain)? = recordedAccountDomain() {
            // 原本選好的網域還能用：照舊（登入了另一個帳號或網域也不換）。
            return done(.authorize, domain.zoneID == cert.zoneID ? "已重新登入 Cloudflare（選好的網域授權更新了）"
                                                                   : "已登入另一個 Cloudflare 帳號；ChatGPT build 照舊用選好的網域")
        }
        return waitUser(.authorize, Self.chooseDomainMessage)
    }

    private struct CommandResult {
        var code: Int32?
        var lines: [String]
        /// W183 R5 審查：只有 stdout 的行（`--output json` 只解析這個）。
        var stdout: [String] = []
        var stopped = false
        /// 開不起來、cloudflared 驗不過、舊指令沒結束：直接當這一步的錯誤訊息。
        var problem: String?
    }

    /// 跑一個 cloudflared 指令、等它結束（可以取消、有時限）。輸出只在記憶體、用完就丟。
    /// 每個指令開之前都重驗 cloudflared 的雜湊（縮短「驗完到執行」的空窗；殘餘寫在 HandsCloudflared 開頭）。
    private func runCommand(_ arguments: [String], home: URL) -> CommandResult {
        guard let located = dependencies.locateCloudflared() else { return CommandResult(code: nil, lines: [], problem: Self.cloudflaredMissing) }
        let lines = HandsLocked<[String]>([])
        let stdout = HandsLocked<[String]>([])
        let exitCode = HandsLocked<Int32??>(nil)
        let finished = DispatchSemaphore(value: 0)
        let command: HandsRunningCommand
        do {
            command = try dependencies.runner.start(cloudflared: located.url, arguments: arguments, home: home, handsRoot: dependencies.paths.root,
                                                   onLine: { line in lines.update { if $0.count < 2000 { $0.append(line) } } },
                                                   // W183 R5 審查：超過上限＝整份作廢（補一個 NUL 標記，stdoutJSON 一律不解析），不解析剩下的片段。
                                                   onStdout: { line in stdout.update { if $0.count < 5000 { $0.append(line) } else if $0.last != "\u{0}" { $0.append("\u{0}") } } },
                                                   onExit: { code in exitCode.set(.some(code)); finished.signal() })
        } catch { return CommandResult(code: nil, lines: [], problem: "cloudflared 開不起來") }
        lock.lock(); runningCommand = command; lock.unlock()
        trackRunner(command)
        defer { lock.lock(); runningCommand = nil; lock.unlock() }
        let deadline = Date().addingTimeInterval(dependencies.commandTimeout)
        while finished.wait(timeout: .now() + dependencies.pollInterval) == .timedOut {
            // 取消或逾時：收掉、確認真的結束才回去；沒結束＝記成 lingering（結束、清檔之前不准重跑）。
            if cancelled || Date() > deadline {
                let wasCancelled = cancelled
                command.cancel()
                guard command.waitForExit(timeout: dependencies.exitWait) else {
                    lock.lock(); lingering = command; lock.unlock()
                    return CommandResult(code: nil, lines: [], stopped: wasCancelled, problem: Self.lingeringMessage)
                }
                untrackRunner()
                return wasCancelled ? CommandResult(code: nil, lines: [], stopped: true) : CommandResult(code: nil, lines: lines.get())
            }
        }
        untrackRunner()
        return CommandResult(code: exitCode.get() ?? nil, lines: lines.get(), stdout: stdout.get())
    }

    /// 0600 暫存檔（O_EXCL|O_NOFOLLOW）：只給 `--origincert` 用，這一步做完就刪。
    private func writeTemporaryCert(_ pem: String, in home: URL) throws -> URL {
        let url = home.appendingPathComponent("oc-" + dependencies.random(12) + ".pem")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw HandsFileError.unsafe("temp_cert") }
        defer { close(fd) }
        guard HandsFiles.writeAll(fd, Data(pem.utf8)), fsync(fd) == 0 else { unlink(url.path); throw HandsFileError.unsafe("temp_cert") }
        return url
    }

    /// W183 R5 審查（GPT-6 高）：cloudflared 指令失敗時只記「分類」進手腳資料夾的 logs/setup-errors.log（0600、最多 60 行；沙盒與 AI 都讀不到），
    /// 給主導查原因。不留任何原文（token、路徑、帳號、網域都不會進去）；原始輸出照舊只在記憶體、用完就丟。
    private func recordError(_ command: String, _ result: CommandResult) {
        let url = dependencies.paths.root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("setup-errors.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let code = result.code.map { String($0) } ?? "none"
        let json = HandsCloudflared.stdoutJSON(result.stdout) == nil ? "no" : "yes"
        let entry = "\(stamp) \(command) exit=\(code) lines=\(result.lines.count) stdout=\(result.stdout.count) json=\(json) category=\(HandsCloudflared.errorCategory(result.lines))"
        var kept = (Self.readSmallFile(url).text ?? "").split(separator: "\n").map(String.init)
        kept.append(entry)
        if kept.count > 60 { kept.removeFirst(kept.count - 60) }
        try? HandsFiles.writeAtomically(Data((kept.joined(separator: "\n") + "\n").utf8), to: url)
    }

    /// W183 R5 審查（GPT-6）：要先確定寫進磁碟才准做外部動作的（建通道前記名字）：寫不進去就丟錯，記憶體也不改。
    private func mutateDurably(_ change: (inout HandsSetupState) -> Void) throws {
        lock.lock()
        var value = current
        change(&value)
        value.updatedAt = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        do {
            try HandsFiles.writeAtomically(try encoder.encode(value), to: stateURL)
        } catch {
            lock.unlock()
            throw error
        }
        current = value
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.state = value }
    }

    static let lookupFailedMessage = "找上次建的通道時 Cloudflare 沒有正常回應；按「重試」再試"
    static func foreignMessage(_ name: String) -> String {
        "Cloudflare 上已經有一條叫 \(name) 的通道，但建立時間跟這台記的對不上（不是這一輪建的，或電腦時間差太多）；為了不接管別的通道先停下。確定沒在用的話到 Cloudflare 後台刪掉它，再按「重試」"
    }
    static let lookupUnclearMessage = "Cloudflare 上的通道對不上（同名的不只一條、或回覆看不懂）；為了不接管別的通道先停下。按「重試」再試，還是不行就到 Cloudflare 後台看 tatwo-hands 開頭的通道"

    private func stepTunnel(force: Bool, trigger: HandsSetupTrigger) -> Outcome {
        if let gate = authorizationGate() { return fail(.tunnel, gate) }   // W183 R3b 審查：確認前不建通道、不改 DNS
        // W183 R8c（GPT-6 必改 4）：新建通道與 DNS 只在使用者按的（「套用」、這台或別台經信箱按的）；自動續跑、助理不新建（已經建好的照用）。
        if trigger == .resume || trigger == .assistant, snapshot.tunnelID == nil || snapshot.publicHost == nil {
            return waitUser(.tunnel, Self.applyFirstMessage)
        }
        // W183 R8 整合審查（GPT-6 高）：舊的遠端設定 RPC（start_setup／continue_setup）不是「套用」：沒有建好的就停在這裡（不新建）。
        if legacyRemote(trigger), snapshot.tunnelID == nil || snapshot.publicHost == nil {
            return waitUser(.tunnel, Self.applyFirstMessage)
        }
        let state = snapshot
        guard let accountID = state.accountID, let zoneID = state.zoneID else { return fail(.tunnel, "先完成第 3 步（Cloudflare 授權）") }
        // W183 R8c 審查（GPT-6 高／中）：「套用」拍下的那一份；建通道、改 DNS 之前都再核（設定改過、被關過＝這一輪不做）。
        let plan = currentPlan
        if let plan, let problem = planProblem(plan) { return fail(.tunnel, problem) }
        // 這一輪綁定開始時的帳號與網域（畫面在忙碌時已不准換；這裡每次發布前再核一次，換了就不發布舊的結果）。
        func unchanged() -> Bool {
            let now = snapshot
            return now.accountID == accountID && now.zoneID == zoneID && (plan.map { planProblem($0) == nil } ?? true)
        }
        let changed = "設定途中換了網域；按「重試」用新的網域"
        guard dependencies.locateCloudflared() != nil else { return fail(.tunnel, Self.cloudflaredMissing) }
        let pem: String
        do {
            guard let value = try dependencies.accounts.cert(zoneID: zoneID) else { return fail(.tunnel, "找不到這個網域的 Cloudflare 授權；先完成第 3 步") }
            pem = value
        } catch { return fail(.tunnel, "讀不到 Cloudflare 授權（鑰匙圈鎖著？）；解鎖後按「重試」") }
        let prepared: (home: URL, config: URL)
        do { prepared = try prepareSetupHome() } catch { return fail(.tunnel, Self.prepareMessage(error)) }
        let home = prepared.home, config = prepared.config
        let certFile: URL
        do { certFile = try writeTemporaryCert(pem, in: home) } catch { return fail(.tunnel, "準備不了暫存的授權檔") }
        defer { unlink(certFile.path) }
        let base = ["tunnel", "--no-autoupdate", "--config", config.path, "--origincert", certFile.path]

        // 0. W183 R5（實機＋GPT-6 審查）：這個帳號上一次建到一半（建之前記了名字；Cloudflare 可能建好了、App 沒讀到 id）：先找回來，不另外再建一條。
        //    只有「看得懂、確定沒有」或「同名的是別人早就建的」才准建新的；看不懂、不只一條＝停下（寧可停也不多建、不認錯）。
        if snapshot.tunnelID == nil, let pending = snapshot.pendingTunnels?[accountID] {
            set(.tunnel, .running, "找上次建的通道…")
            let found = runCommand(base + ["list", "--name", pending.name, "--output", "json"], home: home)
            if let problem = found.problem { return fail(.tunnel, problem) }
            if found.stopped { return .stopped }
            guard found.code == 0 else {
                recordError("tunnel.list", found)
                return fail(.tunnel, HandsCloudflared.explain(found.lines, fallback: Self.lookupFailedMessage))
            }
            switch HandsCloudflared.lookupTunnel(stdout: found.stdout, name: pending.name, since: pending.since) {
            case .found(let id):
                guard unchanged() else { return fail(.tunnel, changed) }
                mutate {
                    $0.tunnelID = id; $0.tunnelName = pending.name; $0.publicHost = nil; $0.pendingTunnels?[accountID] = nil
                    $0.createdTunnels = Array(Set(($0.createdTunnels ?? []) + [id.lowercased()])).sorted()   // W183 R8c：建立證據
                }
                try? dependencies.accounts.setTunnel(accountID: accountID, tunnelID: id)
            case .absent:
                mutate { $0.pendingTunnels?[accountID] = nil }   // 看得懂、確定沒有＝上次沒建成：照常用新名字建
            case .foreign:
                // W183 R5 審查（GPT-6 複查）：同名的建立時間對不上（不是這一輪建的，或兩台時鐘差太多）：不認領、也不另外再建，停下讓人看。
                recordError("tunnel.list", found)
                return fail(.tunnel, Self.foreignMessage(pending.name))
            case .ambiguous, .malformed:
                recordError("tunnel.list", found)
                return fail(.tunnel, Self.lookupUnclearMessage)
            }
        }

        // 1. 建新通道（名字隨機、不含使用者資訊；不碰既有的任何通道）。
        if snapshot.tunnelID == nil {
            guard unchanged() else { return fail(.tunnel, plan != nil ? Self.planChangedMessage : changed) }   // W183 R8c 審查：建之前再核
            set(.tunnel, .running, "建新通道…")
            let name = "tatwo-hands-" + dependencies.random(16)   // W183 R5 審查：名字本身就是這一輪的憑據（36^16），撞名機率可以忽略
            let pending = HandsPendingTunnel(name: name, since: Date())
            // 先確定把名字寫進磁碟才建：建好了卻沒記名字，就再也找不回來（只會再多建一條）。
            do { try mutateDurably { $0.pendingTunnels = ($0.pendingTunnels ?? [:]).merging([accountID: pending]) { $1 } } }
            catch { return fail(.tunnel, "設定檔寫不進去（磁碟滿？）；先不建通道，空出空間後按「重試」") }
            let credentials = home.appendingPathComponent("cred-" + dependencies.random(12) + ".json")
            let result = runCommand(base + ["create", "--credentials-file", credentials.path, "--output", "json", name], home: home)
            unlink(credentials.path)   // 我們用 token 模式，不留通道憑證檔
            if let problem = result.problem { return fail(.tunnel, problem) }   // 記下的名字留著：下次先找
            if result.stopped { return .stopped }
            if result.code != 0, HandsCloudflared.errorCategory(result.lines).contains("exists") {
                // 名字撞到既有的通道（不是這一輪建的）：不認領，這個名字作廢，重跑換新名字。
                mutate { $0.pendingTunnels?[accountID] = nil }
                recordError("tunnel.create", result)
                return fail(.tunnel, "通道名字剛好撞到既有的；按「重試」換一個名字")
            }
            var created = result.code == 0 ? HandsCloudflared.createdTunnelID(stdout: result.stdout, name: name) : nil
            if created == nil, result.code == 0 {
                // 結束碼 0（建成了）但 stdout 讀不出這個名字的 id：用名字問一次；問不清楚就停（名字留著，重跑會再找）。
                let found = runCommand(base + ["list", "--name", name, "--output", "json"], home: home)
                if let problem = found.problem { return fail(.tunnel, problem) }
                if found.stopped { return .stopped }
                guard found.code == 0 else {
                    recordError("tunnel.list", found)
                    return fail(.tunnel, HandsCloudflared.explain(found.lines, fallback: Self.lookupFailedMessage))
                }
                guard case .found(let id) = HandsCloudflared.lookupTunnel(stdout: found.stdout, name: name, since: pending.since) else {
                    recordError("tunnel.list", found)
                    return fail(.tunnel, Self.lookupUnclearMessage)
                }
                created = id
            }
            guard let id = created else {
                recordError("tunnel.create", result)
                return fail(.tunnel, HandsCloudflared.explain(result.lines, fallback: "建通道失敗；按「重試」再試"))
            }
            guard unchanged() else { return fail(.tunnel, changed) }
            mutate {
                $0.tunnelID = id; $0.tunnelName = name; $0.publicHost = nil; $0.pendingTunnels?[accountID] = nil
                $0.createdTunnels = Array(Set(($0.createdTunnels ?? []) + [id.lowercased()])).sorted()   // W183 R8c：建立證據
            }
            try? dependencies.accounts.setTunnel(accountID: accountID, tunnelID: id)
        }
        guard unchanged() else { return fail(.tunnel, changed) }
        guard let tunnelID = snapshot.tunnelID else { return fail(.tunnel, "建通道失敗") }

        // 2. W183 R6a（09-28 使用者「不要隨機子網域 固定加os-for-chagpt」）：固定網址 `<標籤>.<網域>`（標籤是設定值，預設 os-for-chatgpt）。
        //    不加 --overwrite-dns：這個名字已經有別的紀錄＝停下說明（不覆蓋、不換名字）。
        //    以前用隨機子網域（TATWO 建的 h…）＝遷移：先把那一筆記下來（寫進磁碟）→ 加新紀錄 → 用 Cloudflare API 確認新的是指向這條通道的 CNAME →
        //    改網址（第 5 步照新網址重開關口）→ 第 6 步看到關口用新網址起來了才刪記下的那一筆（retireOldHost）。
        // W183 R6a 審查（Claude）：自動續跑（以及已經連上時助理叫的）不遷移——網址一換，ChatGPT 的連接器就指向不在的網址；等使用者按開關或「重試」。
        var migrated = false
        if !isFixedHost(snapshot.publicHost, state: snapshot), !keepsCurrentHost(snapshot, trigger: trigger) {
            let label = plan?.subdomain ?? dependencies.loadSettings().effectiveSubdomainLabel
            let old = snapshot.publicHost
            let domain = snapshot.domain
            let requested = domain.map { label + "." + $0 } ?? label
            if let plan, domain == nil || requested != plan.hostname { return fail(.tunnel, Self.planChangedMessage) }
            guard unchanged() else { return fail(.tunnel, plan != nil ? Self.planChangedMessage : changed) }   // W183 R8c 審查：改 DNS 之前再核
            set(.tunnel, .running, "設定固定網址…")
            // 只記 TATWO 自己建的：以前的隨機格式；W183 R8c 審查（Claude 高）：或這台自己的舊固定網址（使用者按「套用」換子網域；
            // 同一個網域、名字不一樣）。刪之前一樣要核對「只有一筆、CNAME、指向這條通道」。
            let retiring: HandsRetiredHost? = old.flatMap { host in
                domain.flatMap { domain -> HandsRetiredHost? in
                    if Self.isTatwoRandomHost(host, domain: domain) { return HandsRetiredHost(host: host, zoneID: zoneID, tunnelID: tunnelID) }
                    if host.lowercased() != requested.lowercased(), host.lowercased().hasSuffix("." + domain.lowercased()) {
                        return HandsRetiredHost(host: host, zoneID: zoneID, tunnelID: tunnelID, fixed: true)
                    }
                    return nil
                }
            }
            if let retiring, snapshot.retiredHost == nil {
                do { try mutateDurably { $0.retiredHost = retiring } }
                catch { return fail(.tunnel, "設定檔寫不進去（磁碟滿？）；網址先不換，空出空間後按「重試」") }
            }
            /// 還沒換過去就停下：記下的舊紀錄拿掉（舊網址照用、不刪）。
            func abandon(_ outcome: Outcome) -> Outcome {
                mutate { if $0.retiredHost?.host == $0.publicHost { $0.retiredHost = nil } }
                return outcome
            }
            let result = runCommand(base + ["route", "dns", tunnelID, requested], home: home)
            if let problem = result.problem { return abandon(fail(.tunnel, problem)) }
            if result.stopped { return abandon(.stopped) }
            guard result.code == 0, let host = HandsCloudflared.routedHost(in: result.lines) else {
                recordError("tunnel.route", result)
                if HandsCloudflared.errorCategory(result.lines).contains("exists") {
                    return abandon(fail(.tunnel, domain == nil ? Self.fixedHostTakenMessage(requested + ".（你的網域）")
                                                               : takenMessage(zoneID: zoneID, host: requested, tunnelID: tunnelID, base: base, home: home)))
                }
                return abandon(fail(.tunnel, HandsCloudflared.explain(result.lines, fallback: "設定網址失敗；按「重試」再試")))
            }
            guard unchanged() else { return abandon(fail(.tunnel, changed)) }
            if let domain {
                guard host == requested else {
                    return abandon(fail(.tunnel, "Cloudflare 設的網址（\(host)）跟選的網域 \(domain) 不一樣；按「重新授權」選對網域"))
                }
            } else {
                guard host.hasPrefix(label + "."), let rest = HandsGatewayLaunch.validHost(String(host.dropFirst(label.count + 1))) else {
                    return abandon(fail(.tunnel, "看不懂 Cloudflare 回的網址"))
                }
                mutate { $0.domain = rest }
                try? dependencies.accounts.setDomainName(zoneID: zoneID, name: rest)
            }
            if old != nil {
                // 遷移：新紀錄要確認是指向這條通道的 CNAME（Cloudflare API）才換過去；確認不到＝舊網址照用、不刪。
                switch checkRecord(zoneID: zoneID, host: host, tunnelID: tunnelID) {
                case .ours: break
                case .stopped: return abandon(.stopped)
                case .unknown("auth"):
                    // 這個授權不能讀 DNS 紀錄（Cloudflare 權限）：以 cloudflared 的回覆為準（上面已核對 Cloudflare 回的就是這個名字、
                    // 指向這條通道）換過去；舊的那一筆刪不了就留著（第 6 步只在 API 確認是指向這條通道的 CNAME 才刪）。
                    recordCategory("dns.confirm", "auth_cloudflared_confirmed")
                case .notOurs, .unknown: return abandon(fail(.tunnel, Self.fixedHostUnconfirmedMessage))
                }
            }
            // W183 R6a 審查（GPT-6／Claude「遷移後舊連接器失效，畫面仍可能顯示已連線」）：ChatGPT 的連接器還指著舊網址——
            // 已經有的連線（grant）作廢：那一列回到「等你在私訊框按一下」，由使用者按［連線］重新連（新網址第一次 /mcp 之前不寫「已連線」、不自動重連）。
            let hadGrants = old != nil && dependencies.hasActiveGrant()
            mutate { $0.publicHost = host }
            if hadGrants {
                if dependencies.revokeGrants("url_migrated") != nil { recordCategory("grants.revoke", "not_saved") }
                migrated = true
            }
        }

        // 3. 通道 token：只進鑰匙圈（R2 從那裡讀；service tatwo2-cloudflare-tunnel、account tunnel）。
        if force || snapshot.tokenTunnelID != tunnelID || !dependencies.accounts.hasTunnelToken() {
            set(.tunnel, .running, "把通道 token 收進鑰匙圈…")
            let result = runCommand(base + ["token", tunnelID], home: home)
            if let problem = result.problem { return fail(.tunnel, problem) }
            if result.stopped { return .stopped }
            guard result.code == 0, let token = HandsCloudflared.token(in: result.lines) else {
                return fail(.tunnel, HandsCloudflared.explain(result.lines.filter { HandsCloudflared.token(in: [$0]) == nil },
                                                               fallback: "拿不到通道 token；按「重試」再試"))
            }
            guard unchanged(), snapshot.tunnelID == tunnelID else { return fail(.tunnel, changed) }
            do { try dependencies.accounts.saveTunnelToken(token) } catch {
                return fail(.tunnel, "通道 token 收不進鑰匙圈（鑰匙圈鎖著？）；解鎖後按「重試」")
            }
            mutate { $0.tokenTunnelID = tunnelID }
        }
        return done(.tunnel, migrated ? Self.migratedMessage(snapshot.publicHost ?? "") : "通道好了：\(snapshot.publicHost ?? "")")
    }

    /// W183 R6a 審查（Claude）：以前 TATWO 的隨機網址這一輪先照用（不遷移）。
    /// W183 R8c 審查（GPT-6／Claude 高「設定同步仍會改 DNS」）：推廣到任何已經套用的網址——自動續跑與助理一律照用現在的網址
    /// （子網域在 build 改了、期望的網址變了也一樣）：不 route dns、不換網址、不撤銷連線；換網址只有使用者按的（「套用」、這台的重試）。
    private func keepsCurrentHost(_ state: HandsSetupState, trigger: HandsSetupTrigger) -> Bool {
        guard state.publicHost != nil, state.tunnelID != nil else { return false }
        return trigger == .resume || trigger == .assistant || legacyRemote(trigger)   // W183 R8 整合審查：舊的遠端設定 RPC 也照用
    }

    /// W183 R8 整合審查（GPT-6 高）：別台經舊的遠端設定 RPC（trigger .remote）跑、而且不是「套用」（沒有執行者拍的快照）的工作。
    /// 這種工作不算套用授權：不新建通道、不 route dns、不換網址（新版的「套用」一律經 HandsBuildExecutor 帶 HandsApplyPlan 與預期版本）。
    private func legacyRemote(_ trigger: HandsSetupTrigger) -> Bool {
        guard trigger == .remote else { return false }
        lock.lock(); defer { lock.unlock() }
        return !applyRun
    }

    /// W183 R6a 審查（Claude「換主機一定卡在第 4 步」）：固定的名字撞到的那一筆，是不是指向這個帳號裡另一條 TATWO 通道（多半是另一台設備
    /// 當主機時建的）——是就照實說（不覆蓋、不換名字）；查不到就是一般的「已經有別的紀錄」。
    private func takenMessage(zoneID: String, host: String, tunnelID: String, base: [String], home: URL) -> String {
        let (lookup, stopped) = lookupRecord(zoneID: zoneID, host: host)
        guard !stopped, case .records(let records)? = lookup, records.count == 1, records[0].type == "CNAME",
              records[0].content.hasSuffix(HandsCloudflared.tunnelSuffix) else { return Self.fixedHostTakenMessage(host) }
        let target = String(records[0].content.dropLast(HandsCloudflared.tunnelSuffix.count))
        guard target != tunnelID.lowercased() else { return Self.fixedHostTakenMessage(host) }
        let listed = runCommand(base + ["list", "--output", "json"], home: home)
        guard listed.problem == nil, !listed.stopped, listed.code == 0, let tunnels = HandsCloudflared.listedTunnels(stdout: listed.stdout),
              let other = tunnels.first(where: { $0.id == target }), other.active, other.name.hasPrefix(HandsCloudflared.tatwoTunnelPrefix) else {
            return Self.fixedHostTakenMessage(host)
        }
        return Self.fixedHostOtherDeviceMessage(host)
    }

    private func stepStart(trigger: HandsSetupTrigger) -> Outcome {
        if let gate = authorizationGate() { return fail(.start, gate) }   // W183 R3b 審查：確認前不啟動
        if let problem = HandsWorkspaceRoot.prepare() { return fail(.start, problem) }   // W183 R6c：起關口前先備好入口的 chatgpt/ 工作區
        let state = snapshot
        guard let host = state.publicHost, let hostDevice = state.hostDeviceID else { return fail(.start, "先完成第 4 步（通道與網址）") }
        if !dependencies.loadSettings().enabled, trigger == .assistant {
            // 助理叫開、開關原本是關的：對外開網址前先問使用者一次（Island）。
            set(.start, .waitingUser, "請在 Island 按「允許」：助理要打開 ChatGPT 手腳（對外開一個網址；沒有配對碼誰都用不了）")
            let answer = HandsLocked<Bool?>(nil)
            let answered = DispatchSemaphore(value: 0)
            dependencies.askApproval("打開 ChatGPT 手腳？",
                                     "TATWO 助理要照標準流程打開「ChatGPT 手腳」：在 \(host) 開一個對外網址。之後還要你在私訊框按一下［連線］（TATWO 會替你勾 ChatGPT 的風險確認、填配對碼），ChatGPT 才用得了。") { allowed in
                answer.set(allowed); answered.signal()
            }
            let deadline = Date().addingTimeInterval(dependencies.approvalTimeout)
            while answered.wait(timeout: .now() + dependencies.pollInterval) == .timedOut {
                if cancelled { return .stopped }
                if Date() > deadline { break }
            }
            guard answer.get() == true else {
                return fail(.start, "你沒有允許打開；要開請到 TAP › ChatGPT 打開「ChatGPT 手腳」開關，或再叫助理一次")
            }
        }
        // W183 R3b 審查：寫「打開」跟關掉、取消、交出主機是同一把鎖下的判斷（HandsService.updateSettings 的 publicationLock）：
        // 關掉的一方先取消（世代換掉）再寫「關」，所以舊流程在鎖裡看到已取消就不寫；主機換成別台了也不寫（一次只有一台主機）。
        dependencies.checkpoint("start.beforeWrite")
        let refusal = HandsLocked<String?>(nil)
        do {
            try dependencies.updateSettings { settings in
                if self.cancelled { refusal.set("cancelled"); return }
                if let current = settings.hostDeviceID, !current.isEmpty, current.caseInsensitiveCompare(hostDevice) != .orderedSame {
                    refusal.set("host"); return
                }
                // W183 R8c 審查（GPT-6 高「disable 未取消 setup；舊 Apply 可以在關閉後寫回 enabled」）：寫「打開」之前（同一把發布鎖裡）
                // 再核這台的啟用許可與「套用」拍下的那一份：這台被關掉、撤銷世代換了、設定改過＝不寫、不起。
                if !self.dependencies.buildPermit(hostDevice).isActive { refusal.set("permit"); return }
                if let plan = self.currentPlan, self.planProblem(plan) != nil { refusal.set("permit"); return }
                settings.publicHost = host
                settings.hostDeviceID = hostDevice
                settings.enabled = true
            }
        } catch { return fail(.start, "設定存不進去") }
        switch refusal.get() {
        case "cancelled"?: return .stopped
        case "host"?: return fail(.start, "主機剛換成別台了（一次只有一台主機）；這台不打開。要用這台請在 TAP › ChatGPT 的「詳細」把主機改回這台再按「重試」")
        case "permit"?: return fail(.start, Self.planChangedMessage)
        default: break
        }
        set(.start, .running, "啟動關口與通道…")
        // W183 R6a：自動續跑與助理（AI）只叫關口照設定判斷（不叫 retry：安全停機的人工重試鎖不解除，關口失敗就照實回報、請使用者按「重試」）；
        // 使用者在這台或副設備按的才是「重試」。
        // W183 R6a 審查（Claude）：助理叫的＝retryKeepingSafetyLock（一般的關口失敗救得回來，安全停機的鎖不解除）。
        switch trigger {
        case .resume: dependencies.resumeService()
        case .assistant: dependencies.retryService()
        case .user, .remote: dependencies.startService()
        }
        let started = Date()
        let deadline = started.addingTimeInterval(dependencies.serviceTimeout)
        while Date() < deadline {
            if cancelled { return .stopped }
            switch dependencies.servicePhase() {
            case .running(let url) where HandsHostAuthority.same(URL(string: url)?.host, host):
                // W183 R6a：要是用「這個」網址起來的（隨機→固定遷移時，舊網址那一輪還在跑的不算）。
                return done(.start, "運作中（App 開著時會自動顧；停了會自己重開）")
            case .failed(let reason) where Date().timeIntervalSince(started) > 3:
                return fail(.start, reason)
            default:
                break
            }
            Thread.sleep(forTimeInterval: dependencies.pollInterval)
        }
        return fail(.start, "關口 \(Int(dependencies.serviceTimeout)) 秒內沒有起來；到 TAP › ChatGPT 看狀態，或按「重試」")
    }

    private func stepURL() -> Outcome {
        guard case .running(let url) = dependencies.servicePhase() else {
            return fail(.url, "關口現在沒在跑（\(ChatGPTHandsService.statusText(dependencies.servicePhase()))）；先完成第 5 步")
        }
        retireOldHost(runningURL: url)   // W183 R6a：隨機→固定遷移的最後一步（關口已經用新網址起來了）
        scheduleRetireRetry()   // W183 R7a：這一次確認不了、刪不掉＝之後自己再試（不用使用者按）
        return done(.url, Self.urlMessage(url))
    }

    private func stepRemember() -> Outcome {
        if let gate = authorizationGate() { return fail(.remember, gate) }   // W183 R3b 審查：沒確認的不記
        let state = snapshot
        guard let accountID = state.accountID, let zoneID = state.zoneID else { return fail(.remember, "先完成第 3 步（Cloudflare 授權）") }
        do {
            try dependencies.accounts.select(accountID: accountID, zoneID: zoneID)
            try dependencies.accounts.setTunnel(accountID: accountID, tunnelID: state.tunnelID)
        } catch { return fail(.remember, "帳號清單存不進去") }
        return done(.remember, "環境登入 › Cloudflare 記住了帳號與網域（\(state.domain ?? "")）；之後不用再登入")
    }

    /// W183 R6a：走到配對＝私訊框的［連線］卡（HandsConnectFlow.offer；卡片、連接器、配對、第一次 /mcp 都是 R6b）。不開配對窗口。
    /// 在這台按的（使用者、助理）＝這台 offer；副設備按的（.remote）由副設備自己 offer（按的那台）；自動續跑（.resume）不 offer。
    private func stepPairing(trigger: HandsSetupTrigger) -> Outcome {
        if dependencies.hasActiveGrant() { return done(.pairing, "已配對（有一筆有效的授權）") }
        let outcome = waitUser(.pairing, Self.pairingWaitingMessage)
        if trigger == .user || trigger == .assistant { dependencies.offerConnect() }
        return outcome
    }

    // MARK: - W183 R6a：固定子網域（確認新紀錄、刪 TATWO 自己建的那一筆舊紀錄）

    /// 網址是固定的 `<標籤>.<網域>`（網域還不知道＝第一段是標籤就算）。
    private func isFixedHost(_ host: String?, state: HandsSetupState) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let label = dependencies.loadSettings().effectiveSubdomainLabel
        if let domain = state.domain?.lowercased(), !domain.isEmpty { return host == label + "." + domain }
        return host.hasPrefix(label + ".")
    }

    /// 以前 TATWO 建的隨機子網域（`h` ＋ 19 個小寫英數 ＋ `.<網域>`；W183 R3 的 randomLabel(19)）。
    static func isTatwoRandomHost(_ host: String, domain: String) -> Bool {
        let host = host.lowercased(), domain = domain.lowercased()
        guard host.hasSuffix("." + domain) else { return false }
        let label = host.dropLast(domain.count + 1)
        return label.range(of: #"^h[a-z0-9]{19}$"#, options: .regularExpression) != nil
    }

    enum RecordCheck: Equatable { case ours, notOurs, unknown(String), stopped }

    /// 授權裡的 API token（只在記憶體；從鑰匙圈讀這個網域的授權、解開、用完就丟）。
    private func apiToken(zoneID: String) -> String? {
        guard let pem = try? dependencies.accounts.cert(zoneID: zoneID), let cert = HandsCloudflared.parseOriginCert(pem),
              cert.zoneID == zoneID else { return nil }
        return cert.apiToken
    }

    /// Cloudflare 上這個名字的紀錄：只有一筆、CNAME、指向這條通道＝ours；有別的＝notOurs；沒有、查不到＝unknown（分類）。
    private func lookupRecord(zoneID: String, host: String) -> (HandsCloudflared.DNSLookup?, Bool) {
        guard let token = apiToken(zoneID: zoneID) else { return (HandsCloudflared.DNSLookup.failure("no_cert"), false) }
        let box = HandsLocked<HandsCloudflared.DNSLookup?>(nil)
        let finished = DispatchSemaphore(value: 0)
        dependencies.dnsRecords(zoneID, host, token) { box.set($0); finished.signal() }
        let deadline = Date().addingTimeInterval(dependencies.lookupTimeout)
        while finished.wait(timeout: .now() + dependencies.pollInterval) == .timedOut {
            if cancelled { return (nil, true) }
            if Date() > deadline { return (HandsCloudflared.DNSLookup.failure("timeout"), false) }
        }
        return (box.get(), false)
    }

    private func checkRecord(zoneID: String, host: String, tunnelID: String) -> RecordCheck {
        let (lookup, stopped) = lookupRecord(zoneID: zoneID, host: host)
        if stopped { return .stopped }
        switch lookup {
        case .records(let records)?:
            guard !records.isEmpty else { recordCategory("dns.confirm", "absent"); return .unknown("absent") }
            // W183 R6a 審查（GPT-6）：還要是經過 Cloudflare 代理的（proxied；不是的話外面連不到通道、也沒有 Cloudflare 的 TLS）。
            let ours = records.count == 1 && records[0].type == "CNAME" && records[0].name == host.lowercased()
                && records[0].content == HandsCloudflared.tunnelTarget(tunnelID) && records[0].proxied
            if !ours { recordCategory("dns.confirm", "not_ours") }
            return ours ? .ours : .notOurs
        case .failure(let category)?:
            recordCategory("dns.confirm", category)
            return .unknown(category)
        case nil:
            recordCategory("dns.confirm", "none")
            return .unknown("none")
        }
    }

    /// 遷移的最後一步：關口已經用新網址起來了，才刪狀態裡記的那一筆舊紀錄。只刪——那個確切名稱、TATWO 的隨機格式、
    /// Cloudflare 上只有這一筆、CNAME、指向記下的那條通道；其他一律不動。刪不掉（權限、網路）不擋流程：留著下次（第 6 步）再試；
    /// 錯誤只記分類（logs/setup-errors.log）。已經不在、或不是指向那條通道＝不刪、也不再試。
    /// W183 R6a 審查（GPT-6）：setup.json 是同一個使用者的程式改得到的——記下的那一筆只當提示；刪之前一律再核對：
    /// ① 記下的通道就是現在用的這一條（狀態、鑰匙圈裡的通道 token 都是它），網域就是現在授權的網域；
    /// ② Cloudflare 上這條通道的名字是 tatwo-hands- 開頭（TATWO 建的；別的服務的通道不會叫這個）；
    /// ③ 新網址從外面連得到、TLS 對、回的是 TATWO 的關口（不只是通道連上 Cloudflare）；
    /// ④ 那一筆只有一筆、CNAME、指向這條通道；⑤ 刪之前再查一次（同一個 id、同一個指向）、流程沒被取消。
    /// Cloudflare 的刪除不能帶條件（沒有「內容還是這樣才刪」）：⑤ 只縮短查驗到刪除的空窗，消除不了（寫在報告）。任何一項確認不了＝不刪。
    private func retireOldHost(runningURL: String) {
        let state = snapshot
        guard let retired = state.retiredHost else { return }
        guard let current = state.publicHost, !HandsHostAuthority.same(current, retired.host),
              HandsHostAuthority.same(URL(string: runningURL)?.host, current) else { return }
        let tunnel = retired.tunnelID.lowercased()
        guard state.tunnelID?.lowercased() == tunnel, state.tokenTunnelID?.lowercased() == tunnel, dependencies.accounts.hasTunnelToken(),
              state.zoneID == retired.zoneID else {
            recordCategory("dns.retire", "not_current")
            mutate { if $0.retiredHost == retired { $0.retiredHost = nil } }
            return
        }
        let domain = state.zoneID == retired.zoneID ? state.domain : nil
        // W183 R8c 審查（Claude 高）：這台自己的舊固定網址（按「套用」換子網域）也收；一樣要下面的全部核對才刪。
        let ownFixed = retired.fixed == true && domain.map { retired.host.lowercased().hasSuffix("." + $0.lowercased())
            && HandsSettings.validLabel(String(retired.host.lowercased().dropLast($0.count + 1))) != nil } == true
        guard let domain, Self.isTatwoRandomHost(retired.host, domain: domain) || ownFixed else {
            recordCategory("dns.retire", "not_tatwo")
            mutate { if $0.retiredHost == retired { $0.retiredHost = nil } }
            return
        }
        lock.lock(); let startedGeneration = generation; lock.unlock()
        switch tunnelOwnership(tunnel) {
        case .tatwo: break
        case .notTatwo:
            recordCategory("dns.retire", "not_tatwo_tunnel")
            mutate { if $0.retiredHost == retired { $0.retiredHost = nil } }
            return
        case .unknown:
            return   // 問不到 Cloudflare：留著下次再試
        }
        if let problem = probe(current) { recordCategory("dns.probe", problem); return }   // 新網址確認不了：舊的留著
        let (lookup, stopped) = lookupRecord(zoneID: retired.zoneID, host: retired.host)
        if stopped { return }
        switch lookup {
        case .records(let records)?:
            if records.isEmpty { released(retired); return }   // 已經不在（W183 R8c 審查：記成已釋放，主設備的所有權表才拿掉）
            guard records.count == 1, let record = records.first, record.type == "CNAME", record.name == retired.host.lowercased(),
                  record.content == HandsCloudflared.tunnelTarget(retired.tunnelID) else {
                recordCategory("dns.retire", "not_ours")   // 被改過、不是指向那條通道：不刪、也不再試
                mutate { if $0.retiredHost == retired { $0.retiredHost = nil } }
                return
            }
            // ⑤ 刪之前再查一次：同一筆（id）、還是同一個指向；流程沒被取消、世代沒換。
            let (again, stoppedAgain) = lookupRecord(zoneID: retired.zoneID, host: retired.host)
            lock.lock(); let sameGeneration = generation == startedGeneration; lock.unlock()
            guard !stoppedAgain, !cancelled, sameGeneration, case .records(let latest)? = again, latest == [record] else {
                recordCategory("dns.retire", "changed")   // 查驗之後變了：這一次不刪，下次從頭核對
                return
            }
            guard let token = apiToken(zoneID: retired.zoneID) else { recordCategory("dns.retire", "no_cert"); return }
            let result = HandsLocked<String??>(nil)
            let finished = DispatchSemaphore(value: 0)
            dependencies.deleteDNSRecord(retired.zoneID, record.id, token) { result.set(.some($0)); finished.signal() }
            _ = finished.wait(timeout: .now() + dependencies.lookupTimeout)
            switch result.get() {
            case .some(nil): released(retired)
            case .some(let category?): recordCategory("dns.delete", category)
            case nil: recordCategory("dns.delete", "timeout")
            }
        case .failure(let category)?:
            recordCategory("dns.list", category)
        case nil:
            recordCategory("dns.list", "none")
        }
    }

    /// W183 R8c 審查（GPT-6 中）：舊紀錄確定刪掉了（或查過確定已經不在）＝記成「已釋放」（最多記 8 筆）；主設備的所有權表只憑這個拿掉那一筆。
    private func released(_ retired: HandsRetiredHost) {
        mutate { state in
            guard state.retiredHost == retired else { return }
            state.retiredHost = nil
            var list = (state.releasedHosts ?? []).filter { $0.caseInsensitiveCompare(retired.host) != .orderedSame }
            list.append(retired.host.lowercased())
            state.releasedHosts = Array(list.suffix(8))
        }
    }

    /// W183 R7a（mini 實測：遷移後「外部確認新網址」記成 dns.probe category=network，舊的隨機紀錄照設計留著）：
    /// 舊紀錄還記著就排一次重試——不用使用者按，隔一段時間在工作佇列上再做一次 retireOldHost（同一套核對，確認不了照樣不刪）。
    /// 設定流程在跑＝晚一點再排（不跟它搶）；開關關了、這台不是主機、關口沒在跑＝這一輪不試（重開 App 或再打開時第 6 步會再試）。
    private func scheduleRetireRetry(sameStep: Bool = false) {
        let delays = dependencies.retireRetryDelays
        lock.lock()
        guard current.retiredHost != nil else { retireRetries = 0; lock.unlock(); return }
        guard !delays.isEmpty, !retireRetryScheduled else { lock.unlock(); return }
        let delay = delays[min(retireRetries, delays.count - 1)]
        if !sameStep { retireRetries += 1 }
        retireRetryScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in self?.retireRetryFired() }
    }

    private func retireRetryFired() {
        lock.lock(); retireRetryScheduled = false; let pending = current.retiredHost != nil; lock.unlock()
        guard pending else { return }
        let settings = dependencies.loadSettings()
        guard settings.enabled, let local = dependencies.localDeviceID(),
              settings.hostDeviceID.map({ HandsHostAuthority.same($0, local) }) ?? true else { return }
        let started = maintenance(publishes: false) { [weak self] in
            guard let self else { return }
            if case .running(let url) = self.dependencies.servicePhase() { self.retireOldHost(runningURL: url) }
            self.scheduleRetireRetry()
        }
        if !started { scheduleRetireRetry(sameStep: true) }   // 設定流程或維護在跑：晚一點再來
    }

    private enum TunnelOwnership { case tatwo, notTatwo, unknown }

    /// W183 R6a 審查（GPT-6）：Cloudflare 上這條通道是不是 TATWO 建的（名字 tatwo-hands- 開頭、還沒刪）。用鑰匙圈的授權跑 `tunnel list`（同一套沙盒）。
    private func tunnelOwnership(_ id: String) -> TunnelOwnership {
        let found: [HandsCloudflared.ListedTunnel]?? = withAccount { (base: [String], home: URL) -> [HandsCloudflared.ListedTunnel]? in
            let result = runCommand(base + ["list", "--output", "json"], home: home)
            guard result.problem == nil, !result.stopped, result.code == 0 else { recordError("tunnel.list", result); return nil }
            return HandsCloudflared.listedTunnels(stdout: result.stdout)
        }
        guard let list = found ?? nil else { return .unknown }
        guard let tunnel = list.first(where: { $0.id == id.lowercased() }) else { return .notTatwo }
        return tunnel.active && tunnel.name.hasPrefix(HandsCloudflared.tatwoTunnelPrefix) ? .tatwo : .notTatwo
    }

    /// W183 R6a 審查（GPT-6「新網址確認通了實際只確認通道連上 Cloudflare」）：從外面連新網址（TLS、回的是 TATWO 的關口）。nil＝確認了。
    private func probe(_ host: String) -> String? {
        let box = HandsLocked<String??>(nil)
        let finished = DispatchSemaphore(value: 0)
        dependencies.probeHost(host) { box.set(.some($0)); finished.signal() }
        let deadline = Date().addingTimeInterval(dependencies.lookupTimeout)
        while finished.wait(timeout: .now() + dependencies.pollInterval) == .timedOut {
            if cancelled { return "cancelled" }
            if Date() > deadline { return "timeout" }
        }
        return box.get() ?? "none"
    }

    /// W183 R6a：錯誤只記分類（跟 recordError 同一個檔、同一個格式；分類是程式裡的白名單字，不是 Cloudflare 的原文）。
    private func recordCategory(_ command: String, _ category: String) {
        let safe = String(category.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "+") }.prefix(40))
        let url = dependencies.paths.root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("setup-errors.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        var kept = (Self.readSmallFile(url).text ?? "").split(separator: "\n").map(String.init)
        kept.append("\(stamp) \(command) category=\(safe.isEmpty ? "unknown" : safe)")
        if kept.count > 60 { kept.removeFirst(kept.count - 60) }
        try? HandsFiles.writeAtomically(Data((kept.joined(separator: "\n") + "\n").utf8), to: url)
    }

    // MARK: - W183 R6a：沒用到的 TATWO 通道（「詳細」：列出、確認後才刪）

    /// 這個帳號裡的通道（`tunnel list --output json`，走同一套沙盒與看門程式）。回 nil＝查不清楚（原因只記分類）。
    private func listUnused(base: [String], home: URL) -> (tunnels: [HandsCloudflared.UnusedTunnel]?, stopped: Bool) {
        let result = runCommand(base + ["list", "--output", "json"], home: home)
        if result.stopped { return (nil, true) }
        guard result.problem == nil, result.code == 0 else { recordError("tunnel.list", result); return (nil, false) }
        let state = snapshot
        let ids = Set([state.tunnelID, state.tokenTunnelID].compactMap { $0 } + dependencies.accounts.snapshot.compactMap(\.tunnelID))
        let names = Set((state.pendingTunnels ?? [:]).values.map(\.name) + [state.tunnelName].compactMap { $0 })
        guard let found = HandsCloudflared.unusedTatwoTunnels(stdout: result.stdout, excludingIDs: ids, excludingNames: names) else {
            recordCategory("tunnel.list", "malformed")
            return (nil, false)
        }
        // W183 R8c（GPT-6 必改 6）：「沒有連線不等於沒有主人」——
        // ① 只列這台有建立證據的（這台建過的；別台建的、沒證據的一律不列、不刪）；
        // ② 主設備的所有權表記的別台的通道一律不列（離線那台的通道照樣是它的）；所有權表拿不到＝整份不列；
        // ③ DNS 查不到＝禁止刪（整份不列；以前是照列加註）；被這個網域的 DNS 紀錄指到的不列。
        guard let foreign = dependencies.foreignTunnels() else { recordCategory("tunnel.list", "ownership_unknown"); return (nil, false) }
        let targets = dnsTunnelTargets()
        DispatchQueue.main.async { [weak self] in self?.unusedTunnelsUnverified = targets == nil }
        guard let targets else { recordCategory("tunnel.list", "dns_unknown"); return (nil, false) }
        let evidence = state.tunnelEvidence
        return (found.filter { evidence.contains($0.id.lowercased()) && !foreign.contains($0.id.lowercased()) && !targets.contains($0.id) }, false)
    }

    /// 這個網域裡 CNAME 指到的通道 id（用鑰匙圈裡這個網域的授權問 Cloudflare API；token 只在記憶體）。nil＝查不到。
    private func dnsTunnelTargets() -> Set<String>? {
        guard let zone = snapshot.zoneID, let token = apiToken(zoneID: zone) else { return nil }
        let box = HandsLocked<Set<String>??>(nil)
        let finished = DispatchSemaphore(value: 0)
        dependencies.dnsTunnelTargets(zone, token) { box.set(.some($0)); finished.signal() }
        guard finished.wait(timeout: .now() + dependencies.lookupTimeout) == .success else { return nil }
        return box.get() ?? nil
    }

    /// 在設定工作裡、用目前這個帳號的授權跑 cloudflared（暫存憑證 0600、用完刪）。沒有授權或準備不了＝nil。
    private func withAccount<T>(_ body: (_ base: [String], _ home: URL) -> T) -> T? {
        guard let zoneID = snapshot.zoneID, !snapshot.isUnconfirmed(zoneID), snapshot.discard == nil,
              dependencies.locateCloudflared() != nil,
              let pem = (try? dependencies.accounts.cert(zoneID: zoneID)) ?? nil,
              let prepared = try? prepareSetupHome(),
              let certFile = try? writeTemporaryCert(pem, in: prepared.home) else { return nil }
        defer { unlink(certFile.path) }
        return body(["tunnel", "--no-autoupdate", "--config", prepared.config.path, "--origincert", certFile.path], prepared.home)
    }

    /// 查一次「沒用到的 TATWO 通道」（詳細打開時）。設定進行中＝不查（回 false）。
    @discardableResult
    func checkUnusedTunnels() -> Bool {
        maintenance { [weak self] in
            guard let self else { return }
            let found = self.withAccount { (base: [String], home: URL) -> [HandsCloudflared.UnusedTunnel]? in
                self.listUnused(base: base, home: home).tunnels
            } ?? nil
            DispatchQueue.main.async { [weak self] in self?.unusedTunnels = found }
        }
    }

    /// 清掉勾選的（卡片內確認之後才叫）：只刪「現在還是沒用到的」而且勾了的；逐一 `tunnel delete <id>`（不加 -f：有連線的 Cloudflare 會拒）。
    /// W183 R6a 審查（GPT-6「後續刪除仍用舊快照」）：**每一條**刪之前都再查一次（名字、沒有連線、不是現在用的、沒被這個網域的 DNS 指到），
    /// 而且本機的設定世代、帳號與網域沒換（取消、關開關、換網域＝停）。查完到刪之間別台剛好改名或接上：Cloudflare 那邊沒有「還是這樣才刪」
    /// 的條件刪除，只能縮短空窗（有連線的會被 Cloudflare 拒；改名無法原子保證，寫在報告）。
    /// 完成後在主執行緒回呼刪了幾條、沒刪成的有幾條（原因只記分類）。
    @discardableResult
    func deleteUnusedTunnels(_ ids: Set<String>, completion: @escaping (_ deleted: Int, _ failed: Int) -> Void) -> Bool {
        let wanted = Set(ids.map { $0.lowercased() })
        return maintenance { [weak self] in
            guard let self else { return }
            var deleted = 0, failed = 0
            self.lock.lock(); let startedGeneration = self.generation; self.lock.unlock()
            let zone = self.snapshot.zoneID, account = self.snapshot.accountID
            let remaining: [HandsCloudflared.UnusedTunnel]? = self.withAccount { (base: [String], home: URL) -> [HandsCloudflared.UnusedTunnel]? in
                for id in wanted.sorted() {
                    self.lock.lock(); let sameGeneration = self.generation == startedGeneration; self.lock.unlock()
                    guard !self.cancelled, sameGeneration, self.snapshot.zoneID == zone, self.snapshot.accountID == account else { failed += 1; continue }
                    guard let fresh = self.listUnused(base: base, home: home).tunnels else { failed += 1; continue }
                    guard let tunnel = fresh.first(where: { $0.id == id }) else { continue }   // 現在不符合（有連線、改名、在用）：不刪
                    let result = self.runCommand(base + ["delete", tunnel.id], home: home)
                    if result.problem == nil, !result.stopped, result.code == 0 { deleted += 1 } else { failed += 1; self.recordError("tunnel.delete", result) }
                }
                return self.listUnused(base: base, home: home).tunnels
            } ?? nil
            DispatchQueue.main.async { [weak self] in
                self?.unusedTunnels = remaining
                completion(deleted, failed)
            }
        }
    }

    /// 設定工作以外的維護（查、刪通道）：設定流程在跑（或排著）就不做；在同一條工作佇列上跑，之後按的開關會排在它後面、
    /// 不會跟它搶 cloudflared。不發布「忙碌」（那一行狀態不跳「準備中」），只發布 checkingTunnels。取消（關開關）一樣收得掉。
    /// publishes（W183 R7a）：舊紀錄的自動重試不發布 checkingTunnels（「詳細」的通道那一段不跟著轉圈）。
    private func maintenance(publishes: Bool = true, _ body: @escaping () -> Void) -> Bool {
        lock.lock()
        guard !jobActive, !maintaining else { lock.unlock(); return false }
        maintaining = true
        cancelRequested = false
        lock.unlock()
        if publishes { DispatchQueue.main.async { [weak self] in self?.checkingTunnels = true } }
        work.async { [weak self] in
            guard let self else { return }
            if self.unblock() == nil { body() }
            self.lock.lock(); self.maintaining = false; self.runningCommand = nil; self.lock.unlock()
            if publishes { DispatchQueue.main.async { [weak self] in self?.checkingTunnels = false } }
        }
        return true
    }

    // MARK: - 小工具

    /// 設備清單（本機＋已配對的）；主設備排第一。
    static func pairedDevices(entry: TatwoEntry = TatwoEntry(), registry: DeviceRegistry = DeviceRegistry()) -> [HandsSetupDevice] {
        let local = try? DeviceIdentityStore.readLocal(entry: entry)
        var list: [HandsSetupDevice] = []
        if let local {
            list.append(HandsSetupDevice(id: local.deviceID, name: local.name, isPrimary: local.role == .primary, isThisDevice: true))
        }
        for record in registry.list() where !list.contains(where: { $0.id.caseInsensitiveCompare(record.id) == .orderedSame }) {
            let primary = record.role == .primary
                || (local?.primaryDeviceID.map { $0.caseInsensitiveCompare(record.id) == .orderedSame } ?? false)
            list.append(HandsSetupDevice(id: record.id, name: record.name, isPrimary: primary, isThisDevice: false))
        }
        return list.sorted { $0.isPrimary && !$1.isPrimary }
    }

    /// 不好猜的名字：小寫英數（系統的安全亂數）。
    static func randomLabel(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<max(count, 1)).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
    }

    static func onMainSync<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    /// W183 R5b：在這台的私訊框打開授權頁（手機 App 的內嵌瀏覽器）。
    /// W183 R8b：開成私訊框第三顆圓鈕 Browser 的分頁（私訊框自動打開、切到 Browser、這個分頁在最前面；分頁不會自己消失，
    /// 授權完成標「完成」）。不關設定浮層、不切 OS 的 Browser 工作區、不跳頁；只收 Cloudflare 授權頁的網址（GlobalDMWebSheet.cloudflareAuthorization 驗）。
    /// 回 true＝開在私訊框。私訊鈕總開關關著才退回舊路（fallback：OS 瀏覽器的敏感分頁；那條會先關設定、授權完帶回 returnTo）。
    /// onCancel＝使用者在還沒完成時關掉這個分頁（取消這一輪的授權）。browser／fallback 只給自測換。
    @MainActor @discardableResult
    static func openLoginPage(_ url: URL, returnTo page: ReturnPage? = nil, onCancel: @escaping @MainActor () -> Void,
                              browser: DMBrowser = .shared,
                              fallback: (@MainActor (URL, ReturnPage?) -> Void)? = nil) -> Bool {
        guard let sheet = GlobalDMWebSheet.cloudflareAuthorization(url) else { return false }
        if let marker = loginMarker(url) { BrowserHistoryStore.excludeVisits(containing: marker) }
        let elsewhere: @MainActor (URL, ReturnPage?) -> Void = fallback ?? { HandsSetup.openInOSBrowser($0, returnTo: $1) }
        let back = page ?? returnAfterAuthorize   // 退回舊路時（會先關設定）授權完帶回的那一頁
        if browser.open(url: sheet.url, purpose: .cloudflareLogin, onCancel: onCancel, fallback: { elsewhere($0, back) }) {
            returnAfterAuthorize = nil   // 設定浮層沒關：授權完不用帶回哪一頁（設定頁照舊停在原處）
            return true
        }
        elsewhere(url, back)
        return false
    }

    /// 在 OS 的瀏覽器打開（跟外部連結同一條路：BrowserExternalURLQueue＋打開 Work OS 視窗）。
    /// W183 R5b：只剩退路（私訊鈕總開關關著、或私訊框的頁面打不開時使用者按「改在 OS 瀏覽器開」）。
    /// 「設定」浮層會蓋住整個工作區：先關掉它，瀏覽器才看得到（W183 R3 審查）；returnTo＝授權結束後帶回哪一頁。
    /// W183 R3b 審查：授權網址是一次性的通行證（拿到的人可以把自己的 Cloudflare 帳號塞進來）：開成「敏感分頁」——
    /// 只在記憶體，不進分頁還原檔（tabs.json）、最近關閉、空間封存；含它的網址不進瀏覽紀錄；流程結束就關掉（closeLoginPages）。
    /// queue／present 只給自測（隔離的佇列、不開視窗）；正式一律 .shared、開視窗。
    @MainActor static func openInOSBrowser(_ url: URL, returnTo page: ReturnPage? = nil,
                                           queue: BrowserExternalURLQueue = .shared, present: Bool = true) {
        guard BrowserExternalURLQueue.accepts(url) else { return }
        if let page { returnAfterAuthorize = page }
        if let marker = loginMarker(url) { BrowserHistoryStore.excludeVisits(containing: marker) }
        if present { NotificationCenter.default.post(name: .tatwoCloseSettingsPage, object: nil) }
        _ = queue.enqueue([url], sensitive: true)
        BrowserSensitivePageGate.pageAppeared()   // W183 R5b 審查：敏感分頁出現＝以 TATWO 自己為目標的 Computer Use 撤銷
        guard present else { return }
        NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: TatwoPage.chat.rawValue)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 授權網址裡一次性的那一段（callback 網址的最後一段；沒有就整段 query）：瀏覽紀錄看到含它的網址就不記。
    static func loginMarker(_ url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let callback = items.first(where: { $0.name == "callback" })?.value, let tail = URL(string: callback)?.lastPathComponent,
           tail.count >= 12 {
            return tail
        }
        let query = url.query ?? ""
        return query.count >= 12 ? query : nil
    }

    /// 帶回設定的某一頁（授權結束後）。
    @MainActor static func open(_ page: ReturnPage) {
        switch page {
        case .environmentLogin:
            EnvironmentLoginTab.open(.cloudflare)
        case .tap:
            UserDefaults.standard.set("tap", forKey: "tatwo.plugins.selectedTab")
            NotificationCenter.default.post(name: .tatwoOpenSettingsSection, object: TatwoSettingsPage.Section.plugin.rawValue)
        }
    }

    // MARK: - OS 工具的回傳（沒有秘密、沒有路徑、沒有 Cloudflare 帳號名稱與 id）

    /// 給 AI 的文字：拿掉 Cloudflare 帳號名稱與 id、網域 id（W183 R3 審查：帳號資料只留在畫面）。訊息本來就不帶，這裡再保險一次。
    /// W183 R3b 審查：網域名稱與對外主機名也只留在畫面（keepHosts＝關口起來後的 MCP 連線網址那一步，給助理代填 ChatGPT 用）。
    func redactedForAI(_ text: String, keepHosts: Bool = false) -> String {
        var out = text
        let state = snapshot
        var pieces: [String] = [state.accountID, state.zoneID].compactMap { $0 }
        var hosts: [String] = keepHosts ? [] : [state.publicHost, state.domain, dependencies.loadSettings().publicHost].compactMap { $0 }
        for account in dependencies.accounts.snapshot {
            pieces += [account.id, String(account.id.prefix(6))] + account.domains.map(\.zoneID)
            if account.name.count >= 2 { pieces.append(account.name) }
            if !keepHosts { hosts += account.domains.map(\.name) }
        }
        let replacements = Set(pieces).map { ($0, "（Cloudflare 帳號）") } + Set(hosts).filter { $0.count >= 4 }.map { ($0, "（你的網域）") }
        for (piece, label) in replacements.sorted(by: { $0.0.count > $1.0.count }) where !piece.isEmpty {
            out = out.replacingOccurrences(of: piece, with: label, options: .caseInsensitive)
        }
        return out
    }

    func statusPayload() -> [String: Any] {
        refreshDerived()
        let state = snapshot
        let phase = dependencies.servicePhase()
        let local = dependencies.localDeviceID()
        let url: String = { if case .running(let value) = phase { return value }; return "" }()
        let steps = HandsSetupStep.allCases.map { step -> [String: Any] in
            let entry = state.step(step)
            return ["step": step.rawValue, "number": step.number, "title": step.title, "status": entry.status.rawValue,
                    "code": "\(step.rawValue).\(entry.status.rawValue)", "message": aiMessage(step, entry), "needs_user": step.needsUser]
        }
        // W183 R3b 審查：不給網域與對外主機名（只在畫面）；url＝關口起來後的 MCP 連線網址（助理代填 ChatGPT 要用；docs/os-mcp-tools.md 寫明）。
        let service: String = { if case .running = phase { return "運作中" }; return redactedForAI(ChatGPTHandsService.statusText(phase)) }()
        var payload: [String: Any] = [
            "steps": steps,
            "running": isBusy,
            "next_step": nextStep?.rawValue ?? "",
            "host_device_id": state.hostDeviceID ?? "",
            "this_device_is_host": state.hostDeviceID.map { host in local.map { host.caseInsensitiveCompare($0) == .orderedSame } ?? false } ?? false,
            "authorization_confirmed": state.step(.authorize).status == .done && !state.awaitingConfirmation,
            "url": url,
            "service": service,
            "enabled": dependencies.loadSettings().enabled,
            "cloudflare_accounts": dependencies.accounts.snapshot.count,
            "rule": HandsSetupTool.rule,
        ]
        lock.lock(); let blocked = blockedReason; lock.unlock()
        if let blocked { payload["problem"] = blocked }
        if let pending = HandsSetupStep.runOrder.first(where: { state.step($0).status == .waitingUser }) {
            payload["user_action"] = aiMessage(pending, state.step(pending))
        }
        return payload
    }

    /// 給 AI 的步驟訊息（W183 R3b）：第 3 步在等使用者按授權時只說「等使用者在瀏覽器按授權」——不帶網址、不帶畫面上的操作細節；
    /// W183 R3b 審查：等確認時只說「等使用者在畫面確認」；其他照舊拿掉帳號資料，也拿掉網域與對外主機名（網址那一步除外）。
    private func aiMessage(_ step: HandsSetupStep, _ entry: HandsSetupStepState) -> String {
        if step == .authorize, entry.status == .waitingUser,
           entry.message == Self.authorizeWaitingMessage || entry.message == Self.authorizeWaitingRemoteMessage || pendingLoginURL != nil {
            return Self.aiAuthorizeWaiting
        }
        if step == .authorize, entry.status == .waitingUser, snapshot.awaitingConfirmation {
            return Self.aiConfirmWaiting
        }
        return redactedForAI(entry.message, keepHosts: step == .url && entry.status == .done)
    }
}

/// OS 內 AI 的兩個工具（`hands_setup_status`、`hands_setup_step`）。只給 App 與這台的引擎：OSAgentBridge.allows 擋掉外部 AI（ChatGPT 手腳的關口）、
/// SSH 轉進來的已配對設備、背景指令與其他程式。
enum HandsSetupTool {
    static let methods: Set<String> = ["hands_setup_status", "hands_setup_step"]

    /// W183 R3：誰能呼叫（只有 App 自己、這台的引擎、自測探針）。
    static func allows(_ caller: OSSocketCaller) -> Bool {
        switch caller {
        case .app, .engine, .helper: return true
        case .job, .ssh, .externalAI, .other: return false
        }
    }

    static let rule = "照步驟跑：hands_setup_step {step:\"all\"} 會從第一個還沒完成的步驟一路做，停在要使用者按的那一步或出錯的那一步；之後用 hands_setup_status 看每一步的 status 與 message。使用者要親自按的只有兩下：Cloudflare 授權（只有第一次；私訊框會打開授權頁，請使用者按 Authorize；他人在副設備就請他在那台的 TAP › ChatGPT 打開開關；授權網址你拿不到也不用拿；授權後要他在畫面確認帳號與網域——是就按「是這個，繼續」、不是就按「取消並重新授權」；帳號與網域你看不到，也不能替他確認，確認之前不會建通道）、連線（私訊框會跳出「讓 ChatGPT 連上 TATWO？」，請使用者按［連線］——按了就好：ChatGPT 表單上的風險勾選由 TATWO 替他勾、8 碼配對碼由 TATWO 在配對頁填好（填不成才會請他照卡片打）；你不能替他按、也看不到配對碼）。出錯時把 message 白話轉告，照 message 的建議重跑那一步（hands_setup_step {step:\"<名稱>\"}）；同一步失敗兩次就停下來問使用者。金鑰、憑證、token 你讀不到，也不要叫使用者貼給你。"

    enum Failure: Error, CustomStringConvertible {
        case invalid(String), needsUser(String)
        var description: String {
            switch self {
            case .invalid(let reason): "hands_setup_invalid_arguments: \(reason)"
            case .needsUser(let reason): "hands_setup_needs_user: \(reason)"
            }
        }
    }

    static func handle(method: String, params: [String: Any], setup: HandsSetup = .shared) throws -> [String: Any] {
        let metadata: Set<String> = ["callerThreadID", "_threadID", "ownerSource"]
        let keys = Set(params.keys).subtracting(metadata)
        switch method {
        case "hands_setup_status":
            guard keys.isEmpty else { throw Failure.invalid("hands_setup_status takes no arguments") }
            // W183 R11（主導 D）：ChatGPT 連上了沒、拿到什麼——跟私訊框 ChatGPT 對象上方那一顆同一份（connected＝「已連線・Codex、記憶」）。
            var payload = setup.statusPayload()
            payload["connection"] = HandsConnectEntry.aiStatus()
            // W183 R12（.033 實機：正式版查不到任何紀錄）：連線紀錄的最後 200 行（只給 App 與這台的引擎；沒有帳號、token、配對碼、查詢字串）。
            payload["connect_log"] = HandsConnectLog.shared.tail(200, maxTotal: 256 * 1024)
            return payload
        case "hands_setup_step":
            guard keys.isSubset(of: ["step", "action", "hostDeviceID"]) else { throw Failure.invalid("unexpected field") }
            guard let raw = params["step"] as? String else { throw Failure.invalid("step") }
            let action = params["action"] as? String ?? "run"
            guard action == "run" || action == "cancel" else { throw Failure.invalid("action") }
            if action == "cancel" {
                setup.cancel()
                var payload = setup.statusPayload(); payload["cancelled"] = true
                return payload
            }
            let started: Bool
            if let host = params["hostDeviceID"] {
                guard let id = host as? String, UUID(uuidString: id) != nil else { throw Failure.invalid("hostDeviceID") }
                // W183 R6a 審查（GPT-6）：換主機只能提出——後端記下請求、TAP 那一列下面出確認列，使用者按「換主機」才換。
                switch setup.chooseHost(id, trigger: .assistant) {
                case .started: started = true
                case .busy: started = false
                case .needsConfirmation:
                    throw Failure.needsUser("換主機要使用者在 TAP › ChatGPT 那一列下面按「換主機」確認（確認列已經出現；你不能替他按）")
                }
            } else if raw == "all" || raw == "next" {
                started = setup.runAll(trigger: .assistant, allowLogin: true)
            } else if let step = HandsSetupStep(rawValue: raw) {
                if step == .pairing {
                    setup.refreshDerived()
                    guard setup.snapshot.step(.pairing).status == .done else {
                        throw Failure.needsUser("配對要使用者在私訊框按［連線］（按一下就好：風險勾選與配對碼由 TATWO 代做，填不成才請他照卡片打）；請提醒他去按（你不能替他按、不能開配對窗口）")
                    }
                    started = false
                } else {
                    started = setup.run(step, trigger: .assistant)
                }
            } else {
                throw Failure.invalid("step must be all, next or one of \(HandsSetupStep.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            var payload = setup.statusPayload(); payload["started"] = started
            if !started, raw != HandsSetupStep.pairing.rawValue { payload["problem"] = payload["problem"] ?? HandsSetupError.busy.description }
            return payload
        default:
            throw Failure.invalid("method")
        }
    }
}
