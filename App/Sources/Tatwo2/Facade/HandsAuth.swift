import CryptoKit
import Foundation
import Security

// W183 R1／R1b：ChatGPT 手腳的配對、grant 與 token（威脅模型 T2、T3、T15；接口約定 v2 §3–§5、v3 V9、V13、V15、V17）。
//
// - 配對窗口：只有使用者在 App 按「開始配對」才開 10 分鐘（openWindow）；窗口外 authorize_begin 一律 pairing_window_closed。
//   一個窗口同時只有一筆交易（pairing_busy）；配對成功或錯滿 5 次＝窗口一起關（要再配對就再按一次）。
// - 交易：交易編號（4 碼，網頁上顯示同一組）＋8 碼配對碼（V17 字元集），只交給畫面與 Island（onPairingCard），
//   回給關口的內容永遠不含配對碼。確認卡另帶 callback 網域、這筆 grant 會拿到的等級、專案與記憶範圍。
// - 授權碼 60 秒、一次性、原子消耗，綁 client、redirect、PKCE S256 challenge、核准的等級與專案；被重用＝撤銷用它換到的 grant。
// - grant＝一次配對成功：client、核准時的等級上限、核准的專案清單。token 綁 grant：access 1 小時、refresh 30 天每次換新，
//   舊的 refresh 再被用＝撤銷**該 grant**（V15）。撤銷只能從 App 畫面做（不開給關口）。
// - App 端獨立限流（V13）：全域與每 client、每交易；不只靠關口。
// - 狀態檔 app/auth.json（0600）只有 client、grant 與 token 雜湊。窗口、交易、授權碼只在記憶體（App 重開＝全部作廢）。
// W183 R6b（一個開關；one-switch.md「配對」）：配對窗口可以綁一個連線意圖（attempt）：使用者在私訊框按［連線］才開（HandsConnectHost）。
// - 窗口、交易、授權碼、換到的 grant 都記著 attempt；authorize_begin 的範圍用窗口拍下的快照（不讀按下之後才改的設定）。
// - 取消 attempt＝窗口、待確認交易、還沒兌換的授權碼一起作廢，這個 attempt 已經換到的 grant 撤銷；取消過的 attempt 不能再開、授權碼換不到 grant。
// - 關窗口（closeWindow）也清掉還沒兌換的授權碼（用過的留著，重用偵測要用）。
// - 綁 attempt 的確認卡不上設定頁、不上 Island（配對碼只在按［連線］那台的私訊框卡片；HandsState 過濾）。
// W183 R6b 審查（GPT-6）：
// - attempt 換到的 grant 先是「暫時的」（狀態檔記 pendingAttempt）：擁有者核對過 Pod 帳號、主機收到確認（completeAttemptGrant）才轉正。
//   暫時的 grant 只能拿工具清單（第一次 /mcp＝成功證據），不能呼叫工具；App 重開時還是暫時的＝一律撤銷（init），不會自動恢復。
// - 取消、撤銷有「延後通知」版本（cancelAttemptDeferred、revokeGrantDeferred）：HandsConnectHost 在自己的鎖裡改狀態（取消與撤銷同一刻），
//   通知（HandsService 收工作、畫面）等它放鎖之後才送，不會跟設定存檔的鎖互等。
// - closeManualWindow：只收「詳細」手動配對的窗口；綁 attempt 的窗口只能由擁有者 cancel_connect 取消（舊的遠端 stop_pairing 不能關別人的）。
// W183 R8c（多設備；GPT-6 必改 5：每台 OAuth／工作區邊界）：
// - grant 持久化 hostDeviceID、issuer／resource、撤銷世代；每次認 token 都核對（binding：這台的設備 id、這台的網址、這台現在的撤銷世代）。
//   別台的 token／refresh／grant（例如整個 auth.json 被搬過來）、網址換了、撤銷世代變了＝一律不認。沒有這些欄位的舊 grant＝不認（有 binding 時）。
// - App 端也精確核 resource（以前只驗 https:// 開頭，精確比對只在關口）：authorize_begin 帶的 resource 一定要是這台的 `https://<網址>/mcp`。
// - 配對頁證據（evidence）的第二版：原本的四個 OAuth 參數再綁上 target（主機設備）、issuer、resource、attempt、setupEpoch（boundEvidence）；
//   擁有者與主機各自算、對上才給碼——A 那一筆的證據拿到 B 用對不上。

/// 三種錯誤之一：OAuth／os.sock 協定錯誤（fixtures/wire.json 的 `{code, message}`，另可帶 attempts_left）。
struct HandsWireError: Error, CustomStringConvertible, Equatable {
    let code: String
    let message: String
    var attemptsLeft: Int? = nil

    var description: String { code }
    var wire: [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let attemptsLeft { error["attempts_left"] = attemptsLeft }
        return error
    }

    static let unauthorized = HandsWireError(code: "unauthorized", message: "unauthorized")
    static let sandboxToolNotAllowed = HandsWireError(code: "sandbox_tool_not_allowed", message: "沙盒只能領工、交件、回報心跳。")
    static let rateLimited = HandsWireError(code: "rate_limited", message: "try later")
    static let windowClosed = HandsWireError(code: "pairing_window_closed", message: "open pairing in TATWO first")
    static let pairingBusy = HandsWireError(code: "pairing_busy", message: "another pairing is pending")
    static let pairingExpired = HandsWireError(code: "pairing_expired", message: "start pairing again")
    static let invalidRedirect = HandsWireError(code: "invalid_redirect_uri", message: "redirect_uri not allowed")
    static let invalidClient = HandsWireError(code: "invalid_client", message: "invalid client")
    static let invalidGrant = HandsWireError(code: "invalid_grant", message: "invalid grant")
    static let grantRevoked = HandsWireError(code: "invalid_grant", message: "grant revoked")
    static let toolNotAllowed = HandsWireError(code: "tool_not_allowed", message: "tool not allowed")
    static let requestConflict = HandsWireError(code: "request_id_conflict", message: "request_id reused with different arguments")
    static let disabled = HandsWireError(code: "hands_disabled", message: "ChatGPT hands is turned off in TATWO")
    static let wrongDevice = HandsWireError(code: "hands_not_on_this_device", message: "this device is not the hands host")
    static func invalidRequest(_ message: String) -> HandsWireError { HandsWireError(code: "invalid_request", message: message) }
    static func invalidCode(_ left: Int) -> HandsWireError { HandsWireError(code: "invalid_pairing_code", message: "wrong code", attemptsLeft: left) }
}

struct HandsAuthState: Codable, Equatable {
    struct Client: Codable, Equatable {
        var id: String
        var name: String
        var redirectURIs: [String]
        var createdAt: Date
        var lastUsedAt: Date?
    }
    /// 一次配對成功＝一個 grant（接口 v2 §4）。撤銷的保留紀錄（工作區、job 的擁有者），不再能用。
    struct Grant: Codable, Equatable {
        var id: String
        var clientID: String
        var level: Int
        var projectIDs: [String]
        var createdAt: Date
        var lastUsedAt: Date?
        var revokedAt: Date?
        var revokeReason: String?
        /// W183 R6b 審查：這個 grant 是某個連線意圖換到的、擁有者還沒確認（暫時的）。重開 App 時還在＝撤銷。
        var pendingAttempt: String? = nil
        /// W183 R8c：這個 grant 屬於哪台主機、哪個 issuer／resource、建立時的撤銷世代（每次認 token 都核對）。
        var hostDeviceID: String? = nil
        var issuer: String? = nil
        var resource: String? = nil
        var generation: Int? = nil
        /// W183 R10：這個 grant 核准的是「這台全部專案」（新專案自動包含；projectIDs 只是核准當下的清單）。nil／false＝舊 grant：照舊只有 projectIDs。
        var allProjects: Bool? = nil
        var sandboxDeviceID: String? = nil
        var isActive: Bool { revokedAt == nil }
    }
    struct Token: Codable, Equatable {
        var id: String
        var grantID: String
        var accessHash: String
        var accessExpires: Date
        var refreshHash: String
        var refreshExpires: Date
        var createdAt: Date
    }
    struct UsedRefresh: Codable, Equatable {
        var hash: String
        var grantID: String
        var usedAt: Date
    }
    var clients: [Client] = []
    var grants: [Grant] = []
    var tokens: [Token] = []
    var usedRefresh: [UsedRefresh] = []
    /// W183 R8c 審查：舊的 grant 遷移成有綁定的（只做一次；之後再出現沒綁定的一律撤銷）。
    var bindingUpgradedAt: Date? = nil
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：授權狀態的版本（每存一次 +1，只會往上）。連線確認那一刻的版本、回報取樣那一刻的版本
    /// 可以比先後：回報的版本比連線確認的新、卻沒有那一條＝真的不在了；舊的（連上之前取樣的）不能拿來說撤銷了。舊檔沒有＝0。
    var version: Int? = nil
}

struct HandsProjectRef: Equatable, Sendable, Hashable {
    let id: String
    let name: String
}

/// W183 R8c：這台現在的綁定（grant 建立時蓋上、每次認 token 都核對）。
struct HandsGrantBinding: Equatable, Sendable {
    var hostDeviceID: String
    /// `https://<這台的網址>`（沒有網址＝nil）。
    var issuer: String?
    /// `https://<這台的網址>/mcp`。
    var resource: String?
    /// 這台現在的撤銷世代（ChatGPT build 給這台的；明確關掉一次 +1）。
    var generation: Int
}

/// 這筆配對核准後 grant 會拿到的範圍（開交易當下照設定拍下來，確認卡顯示的就是這份）。
struct HandsGrantScope: Equatable, Sendable {
    var level: Int
    var projects: [HandsProjectRef]
    var memory: String
    /// W183 R10：全部可見（這台所有能當專案的；新專案自動包含）。projects 是當下的清單（顯示用）；範圍快照的 digest 只記「全部」。
    var allProjects: Bool = false
    /// W183 R10 底線 B：清單裡交易實盤類的（只能看；顯示用，擋在主機的工具入口）。
    var readOnlyProjectIDs: [String] = []
    var sandboxDeviceID: String? = nil

    static func memoryText(level: Int) -> String {
        level >= 1 ? "讀正式記憶（標「不給 ChatGPT」的除外、遮蔽敏感內容）；只寫 ChatGPT 專屬收件匣" : "不碰記憶"
    }
}

/// 確認卡（設定頁與 Island；副設備之後經設備簽章 RPC 看同一份）。配對碼只在這裡。
struct HandsPairingCard: Equatable, Sendable, Identifiable {
    let id: String
    let displayCode: String
    let pairingCode: String
    let callbackHost: String
    let callbackURL: String
    /// client 自己填的名字（可以亂填，只當參考；文案不宣稱驗證了帳號）。
    let clientName: String
    let scope: HandsGrantScope
    let expiresAt: Date
    var attemptsLeft: Int
    /// 畫面好讀的樣子：「ABCD EFGH」。
    var spacedPairingCode: String { String(pairingCode.prefix(4)) + " " + String(pairingCode.dropFirst(4)) }
    /// W183 R6b：這筆交易屬於哪個連線意圖（nil＝舊的手動「開始配對」）。綁 attempt 的卡不上設定頁與 Island。
    var attemptID: String? = nil
}

/// W183 R6b：綁在連線意圖上的那一筆交易（只給 App 內部：HandsConnectHost 比對 Pod 看到的授權參數、只把碼交給擁有者）。
struct HandsAttemptTransaction: Equatable, Sendable {
    let id: String
    let displayCode: String
    let pairingCode: String
    let clientID: String
    let redirectURI: String
    let state: String
    let challenge: String
    let scope: HandsGrantScope
    let expiresAt: Date
    let attemptsLeft: Int
    /// W183 R8c：關口傳進來、App 核對過的 resource（這台的 `https://<網址>/mcp`）。
    var resource: String? = nil
    var callbackHost: String { URLComponents(string: redirectURI)?.host?.lowercased() ?? "?" }
    /// Pod 看到的授權網址要對得上的那一組（client、redirect、state、challenge）的雜湊。
    var evidenceHash: String { HandsAuth.evidenceHash(clientID: clientID, redirectURI: redirectURI, state: state, challenge: challenge) }
}

/// 驗過的 access token 對應的 grant。
struct HandsGrantAccess: Equatable, Sendable {
    let grantID: String
    let clientID: String
    /// grant 核准的等級（實際等級＝跟設定的上限取小）。
    let grantLevel: Int
    let projectIDs: [String]
    /// W183 R6b 審查：擁有者還沒確認的暫時 grant（只能拿工具清單，不能呼叫工具）。
    var provisional: Bool = false
    /// W183 R10：核准的是這台全部專案（新專案自動包含）。
    var allProjects: Bool = false
    var sandboxDeviceID: String? = nil
}

struct HandsGrantSummary: Equatable, Sendable, Identifiable {
    let id: String
    let clientName: String
    let level: Int
    let projectIDs: [String]
    let createdAt: Date
    let lastUsedAt: Date?
    let revokedAt: Date?
    let revokeReason: String?
    /// W183 R8a 審查（GPT-6）：暫時的 grant（連線意圖換到、擁有者還沒核對、主機還沒確認；只能拿工具清單）。畫面不算「已連線」。
    var provisional: Bool = false
}

/// W183 R11 第二輪（GPT-6 R11b 審查 2，高）：封頂的結果（HandsService.levelGuard 看這個決定能不能記下新的等級）。
enum HandsCapOutcome: Equatable, Sendable {
    /// 沒有要封頂的，或封頂存好了。
    case durable
    /// 存不進去，但授權檔刪掉了（全部撤銷；重開也讀不回舊的 grant）。
    case revokedFileRemoved(String)
    /// 存不進去、授權檔也刪不掉：磁碟上還是封頂前的樣子（重開會讀回舊的 grant）。
    case notDurable(String)

    /// 重開 App 也不會讀回比上限高的 grant。
    var safeAcrossRestart: Bool { if case .notDurable = self { return false }; return true }
}

final class HandsAuth: @unchecked Sendable {
    static let accessLifetime: TimeInterval = 3600
    static let refreshLifetime: TimeInterval = 30 * 86_400
    /// V15：配對窗口 10 分鐘＝配對碼有效期（窗口關就失效）。
    static let windowLifetime: TimeInterval = 600
    static let pairingAttempts = 5
    static let codeLifetime: TimeInterval = 60
    static let maxPendingClients = 16
    /// 用過的 refresh 紀錄上限（偵測期內滿了＝暫停換新，不淘汰證據）：全部、每個 grant。
    static let maxUsedRefresh = 20_000
    static let maxUsedRefreshPerGrant = 2_000
    static let scope = "tatwo.hands"
    /// V17：32 個字元（去掉 0、1、I、O）。8 碼 ≈ 40 位元；每筆最多猜 5 次，錯滿整個窗口關掉。
    static let codeAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    private struct Window {
        let openedAt: Date
        let expiresAt: Date
        /// W183 R6b：綁的連線意圖與它拍下的範圍（nil＝手動「開始配對」）。
        var attemptID: String? = nil
        var scope: HandsGrantScope? = nil
    }
    private struct Transaction {
        let id: String
        let displayCode: String
        let pairingCode: String
        let clientID: String
        let clientName: String
        let redirectURI: String
        let challenge: String
        let state: String
        let scope: HandsGrantScope
        let expiresAt: Date
        var attemptsLeft: Int
        var bindingHash: String?
        var submits: [Date] = []
        /// W183 R6b：這筆交易屬於哪個連線意圖。
        var attemptID: String? = nil
        /// W183 R8c：核對過的 resource。
        var resource: String? = nil
    }
    private struct AuthCode {
        let clientID: String
        let redirectURI: String
        let challenge: String
        let level: Int
        let projectIDs: [String]
        /// W183 R10：這個授權碼換到的 grant 核准這台全部專案。
        var allProjects = false
        let expiresAt: Date
        var used = false
        var grantID: String?
        /// W183 R6b：這個授權碼屬於哪個連線意圖（取消＝還沒兌換的作廢）。
        var attemptID: String? = nil
        /// W183 R8c：這個授權碼是給哪個 resource 的（grant 蓋上）。
        var resource: String? = nil
        var sandboxDeviceID: String? = nil
    }

    let url: URL
    /// 測試可換時鐘。
    var now: () -> Date = Date.init
    /// 每個 grant 用過的 refresh 紀錄上限（自測調小，證明滿了是停止換新、不是丟掉證據）。
    var usedRefreshCapPerGrant = HandsAuth.maxUsedRefreshPerGrant
    /// 確認卡出現、更新（剩幾次）或收掉（nil）：只交給畫面與 Island。
    var onPairingCard: ((HandsPairingCard?) -> Void)?
    /// 窗口開、關（nil＝關）。
    var onWindowChange: ((Date?) -> Void)?
    /// grant 被撤銷（refresh 重用、授權碼重用、畫面撤銷、關開關）：HandsService 收工作、鎖工作區。
    var onGrantsRevoked: (([String], String) -> Void)?
    /// client／grant 有變（畫面重新整理）。
    var onChange: (() -> Void)?
    /// W183 R6b：綁 attempt 的授權碼換到 grant（attemptID, grantID）。HandsConnectHost 記下「這個 attempt 的 grant」。
    var onAttemptGrant: ((String, String) -> Void)?
    /// W183 R8c：這台現在的綁定（nil＝不核對：自測的單機世界）。正式的 HandsService.shared 接上。不准在這裡面叫回 HandsAuth。
    var binding: (() -> HandsGrantBinding?)?

    private let lock = NSRecursiveLock()
    private var state: HandsAuthState
    /// W183 R1b：撤銷沒能存檔（磁碟滿等）：全部 grant 在記憶體裡撤銷、授權檔刪掉，直到下一次存檔成功前一律不認 token。
    private var persistenceFailure: String?
    /// W183 R11 第二輪（GPT-6 R11b 審查 2，高）：上一次存不進去、授權檔也刪不掉＝磁碟上可能還是存檔失敗之前的樣子（重開 App 會讀回舊的 grant）。
    /// 下一次存檔成功才清掉；在那之前封頂（capGrants）一律回「沒存進去」。
    private var diskMayHoldOldGrants = false
    #if DEBUG
    /// 自測：模擬存檔失敗（磁碟滿）。
    var failSavesForTesting = false
    /// 自測（W183 R11 第二輪）：模擬授權檔刪不掉（例如被鎖住）：不真的去設不可變旗標。
    var failRemovesForTesting = false
    #endif
    private var window: Window?
    private var transaction: Transaction?
    private var codes: [String: AuthCode] = [:]
    private var events: [String: [Date]] = [:]
    /// W183 R6b：每個 attempt 換到的 grant（取消時撤銷）；取消過的 attempt（不能再開窗口、授權碼換不到 grant）。只在記憶體。
    private var attemptGrants: [String: [String]] = [:]
    private var cancelledAttempts: [String] = []
    /// W183 R8c：/token 這一次用的綁定（鎖外讀好、鎖裡用）。
    private var bindingForIssue: HandsGrantBinding?

    init(url: URL) {
        self.url = url
        if let data = HandsFiles.readSecure(url, limit: 8 * 1024 * 1024) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            state = (try? decoder.decode(HandsAuthState.self, from: data)) ?? HandsAuthState()
        } else {
            state = HandsAuthState()
        }
        // W183 R6b 審查（GPT-6）：上次 App 結束時還沒確認的連線 grant（/token 完成、擁有者還沒核對帳號）一律撤銷，
        // 在任何人能用它之前（關口起來之前）；存不了檔＝全部撤銷、刪授權檔（persistRevocationLocked）。
        let unfinished = state.grants.filter { $0.isActive && $0.pendingAttempt != nil }.map(\.id)
        if !unfinished.isEmpty {
            _ = revokeLocked(unfinished, reason: "connect_unfinished")
            _ = persistRevocationLocked()
        }
    }

    // MARK: - 畫面：配對窗口

    /// 使用者按「開始配對」：開 10 分鐘窗口（已經開著就重開一個新的、舊的交易作廢）。
    func openWindow() {
        lock.lock()
        let current = now()
        window = Window(openedAt: current, expiresAt: current.addingTimeInterval(Self.windowLifetime))
        let hadTransaction = transaction != nil
        transaction = nil
        let expires = window?.expiresAt
        let (cardChanged, windowChanged) = (onPairingCard, onWindowChange)
        lock.unlock()
        if hadTransaction { cardChanged?(nil) }
        windowChanged?(expires)
    }

    func openSandboxWindow(deviceID: String) {
        lock.lock()
        window = Window(openedAt: now(), expiresAt: now().addingTimeInterval(Self.windowLifetime),
                        scope: HandsGrantScope(level: 0, projects: [], memory: "沙盒（只能領工、交件）；不碰記憶", sandboxDeviceID: deviceID))
        transaction = nil
        let expires = window?.expiresAt
        lock.unlock()
        onPairingCard?(nil); onWindowChange?(expires)
    }

    /// W183 R6b：使用者在私訊框按［連線］（HandsConnectHost.begin）：開一個綁這個 attempt 的 10 分鐘窗口，範圍用按下時的快照。
    /// 已經開著的窗口與交易作廢（跟 openWindow 一樣）。取消過的 attempt 不能再開（回 nil）。
    func openAttemptWindow(attemptID: String, scope: HandsGrantScope) -> Date? {
        lock.lock()
        guard !cancelledAttempts.contains(attemptID) else { lock.unlock(); return nil }
        let current = now()
        window = Window(openedAt: current, expiresAt: current.addingTimeInterval(Self.windowLifetime), attemptID: attemptID, scope: scope)
        let hadTransaction = transaction != nil
        transaction = nil
        let expires = window?.expiresAt
        let (cardChanged, windowChanged) = (onPairingCard, onWindowChange)
        lock.unlock()
        if hadTransaction { cardChanged?(nil) }
        windowChanged?(expires)
        return expires
    }

    /// W183 R6b：取消一個連線意圖——它的窗口、待確認交易、還沒兌換的授權碼作廢；它已經換到的 grant 撤銷。之後這個 attempt 不能再開、
    /// 晚到的授權碼也換不到 grant（取消與 /token 同時：誰先拿到鎖誰先；token 先＝grant 在這裡被撤銷，取消先＝授權碼已經不在）。
    /// 回（撤銷的 grant、撤銷存檔的問題）。
    @discardableResult
    func cancelAttempt(_ attemptID: String, reason: String) -> (revoked: [String], problem: String?) {
        let result = cancelAttemptDeferred(attemptID, reason: reason)
        result.notify()
        return (result.revoked, result.problem)
    }

    /// W183 R6b 審查：同上，但通知（畫面、HandsService 收工作）交給呼叫端在放掉自己的鎖之後再送。狀態在這裡就已經改好（撤銷已生效）。
    func cancelAttemptDeferred(_ attemptID: String, reason: String) -> (revoked: [String], problem: String?, notify: () -> Void) {
        lock.lock()
        if !cancelledAttempts.contains(attemptID) {
            cancelledAttempts.append(attemptID)
            if cancelledAttempts.count > 256 { cancelledAttempts.removeFirst(cancelledAttempts.count - 256) }
        }
        let hadWindow = window?.attemptID == attemptID
        if hadWindow { window = nil }
        let hadTransaction = transaction?.attemptID == attemptID
        if hadTransaction { transaction = nil }
        codes = codes.filter { $0.value.attemptID != attemptID || $0.value.used }
        let active = (attemptGrants[attemptID] ?? []).filter { id in state.grants.contains { $0.id == id && $0.isActive } }
        var ids: [String] = []
        var problem: String?
        if !active.isEmpty {
            _ = revokeLocked(active, reason: "connect_cancelled:" + String(reason.prefix(40)))
            let persisted = persistRevocationLocked()
            ids = active + persisted.revoked
            problem = persisted.problem
        }
        let callback = onGrantsRevoked, changed = onChange, cardChanged = onPairingCard, windowChanged = onWindowChange
        lock.unlock()
        let revoked = ids
        return (ids, problem, {
            if hadTransaction { cardChanged?(nil) }
            if hadWindow { windowChanged?(nil) }
            if !revoked.isEmpty { callback?(revoked, "connect_cancelled"); changed?() }
        })
    }

    /// W183 R6b 審查：擁有者核對過帳號、主機收到確認：這個 attempt 的暫時 grant 轉正（存檔）。存不了檔＝回 false（呼叫端取消、撤銷）。
    func completeAttemptGrant(_ grantID: String) -> Bool {
        lock.lock()
        guard let index = state.grants.firstIndex(where: { $0.id == grantID }), state.grants[index].isActive,
              persistenceFailure == nil else { lock.unlock(); return false }
        let pending = state.grants[index].pendingAttempt
        state.grants[index].pendingAttempt = nil
        do {
            try saveLocked()
        } catch {
            state.grants[index].pendingAttempt = pending   // 沒存成：還是暫時的（呼叫端取消、撤銷）
            lock.unlock()
            return false
        }
        let changed = onChange
        lock.unlock()
        changed?()
        return true
    }

    /// W183 R6b 審查（GPT-6）：只收「詳細」裡手動「開始配對」的窗口（沒綁連線意圖的）。綁 attempt 的窗口不動、回 false
    /// （舊的遠端 stop_pairing 不能關掉別台按［連線］開的窗口、清掉它的授權碼；那要擁有者自己 cancel_connect）。
    @discardableResult
    func closeManualWindow() -> Bool {
        lock.lock()
        if window?.attemptID != nil || transaction?.attemptID != nil { lock.unlock(); return false }
        let had = window != nil || transaction != nil
        window = nil
        transaction = nil
        codes = codes.filter { $0.value.used || $0.value.attemptID != nil }
        let (cardChanged, windowChanged) = (onPairingCard, onWindowChange)
        lock.unlock()
        if had { cardChanged?(nil); windowChanged?(nil) }
        return true
    }

    /// W183 R6b：這個 attempt 的窗口還開著嗎（到期時間；沒開、不是它的、過期＝nil）。
    func attemptWindowExpiry(_ attemptID: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let window, window.attemptID == attemptID, window.expiresAt > now() else { return nil }
        return window.expiresAt
    }

    /// W183 R6b：綁這個 attempt、還在等配對碼的那一筆交易（只給 App 內部）。
    func attemptTransaction(_ attemptID: String) -> HandsAttemptTransaction? {
        lock.lock(); defer { lock.unlock() }
        guard let t = transaction, t.attemptID == attemptID, t.expiresAt > now() else { return nil }
        return HandsAttemptTransaction(id: t.id, displayCode: t.displayCode, pairingCode: t.pairingCode, clientID: t.clientID,
                                       redirectURI: t.redirectURI, state: t.state, challenge: t.challenge, scope: t.scope,
                                       expiresAt: t.expiresAt, attemptsLeft: t.attemptsLeft, resource: t.resource)
    }

    /// W183 R6b：這個 attempt 有沒有配對碼對了、授權碼還沒兌換（等 ChatGPT 來換 token）。
    func attemptHasPendingCode(_ attemptID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let current = now()
        return codes.values.contains { $0.attemptID == attemptID && !$0.used && $0.expiresAt > current }
    }

    /// W183 R6b：這個 attempt 換到的 grant（還有效的）。
    func attemptGrantIDs(_ attemptID: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (attemptGrants[attemptID] ?? []).filter { id in state.grants.contains { $0.id == id && $0.isActive } }
    }

    /// 關窗口（使用者取消、配對完成、錯滿、關開關、撤銷全部）：交易一起作廢。
    /// W183 R6b：還沒兌換的授權碼也一起作廢（用過的留著做重用偵測）。
    func closeWindow() {
        lock.lock()
        let had = window != nil || transaction != nil
        window = nil
        transaction = nil
        codes = codes.filter { $0.value.used }
        let (cardChanged, windowChanged) = (onPairingCard, onWindowChange)
        lock.unlock()
        if had { cardChanged?(nil); windowChanged?(nil) }
    }

    /// 只取消這一筆交易（使用者對不上交易編號時）；窗口留著，網頁重新整理會開新的一筆。
    func cancelTransaction() {
        lock.lock()
        let had = transaction != nil
        transaction = nil
        let cardChanged = onPairingCard
        lock.unlock()
        if had { cardChanged?(nil) }
    }

    var windowExpiresAt: Date? {
        lock.lock(); defer { lock.unlock() }
        guard let window, window.expiresAt > now() else { return nil }
        return window.expiresAt
    }

    // MARK: - 關口呼叫的 op（hands_auth）

    struct Context {
        /// 設定裡的 ChatGPT callback 清單（精確比對）。
        var callbacks: [String]
        /// 設定的等級上限（check 回的等級＝跟 grant 取小）。
        var levelCap: Int
        /// authorize_begin 拍下的範圍（等級、專案、記憶）。
        var scope: HandsGrantScope
        /// W183 R8c：這台的 `https://<網址>/mcp`（App 端精確核 resource；nil＝不核：沒有網址的自測世界）。
        var resource: String? = nil
    }

    func handle(op: String, params: [String: Any], context: Context) throws -> [String: Any] {
        switch op {
        case "register_client": return try registerClient(params, context: context)
        case "authorize_begin": return try authorizeBegin(params, context: context)
        case "authorize_submit": return try authorizeSubmit(params)
        case "token": return try token(params)
        case "check": return try checkOp(params, levelCap: context.levelCap)
        default: throw HandsWireError.invalidRequest("unknown op")
        }
    }

    private func requireKeys(_ params: [String: Any], _ allowed: Set<String>) throws {
        guard Set(params.keys).isSubset(of: allowed.union(["op"])) else { throw HandsWireError.invalidRequest("unexpected field") }
    }

    private func registerClient(_ params: [String: Any], context: Context) throws -> [String: Any] {
        try requireKeys(params, ["redirect_uris", "client_name", "scope"])
        guard params["scope"] == nil || params["scope"] as? String == "sandbox" else { throw HandsWireError.invalidRequest("scope") }
        guard let uris = params["redirect_uris"] as? [String], (1...5).contains(uris.count) else {
            throw HandsWireError.invalidRequest("redirect_uris")
        }
        // 接口 v2 §2：精確在 App 設定的 ChatGPT callback 清單內（無萬用字元、無 fragment）。
        guard uris.allSatisfy({ Self.isAcceptableRedirect($0) && context.callbacks.contains($0) }) else { throw HandsWireError.invalidRedirect }
        let rawName = (params["client_name"] as? String) ?? "ChatGPT"
        let name = String(rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        lock.lock(); defer { lock.unlock() }
        let lane = params["scope"] as? String == "sandbox" ? "sandbox:" : ""
        if !lane.isEmpty { guard let window, window.expiresAt > now(), window.scope?.sandboxDeviceID != nil else { throw HandsWireError.windowClosed } }
        guard allow(lane + "all", max: 300, per: 60), allow(lane + "register", max: 10, per: 3600) else { throw HandsWireError.rateLimited }
        pruneLocked()
        // 待處理（沒有有效 grant）的 client 數上限：先清掉超過一小時的，還是滿就拒。
        let active = Set(state.grants.filter(\.isActive).map(\.clientID))
        var pending = state.clients.filter { !active.contains($0.id) }
        if pending.count >= Self.maxPendingClients {
            let cutoff = now().addingTimeInterval(-3600)
            let stale = Set(pending.filter { $0.createdAt < cutoff && $0.id != transaction?.clientID }.map(\.id))
            state.clients.removeAll { stale.contains($0.id) }
            pending.removeAll { stale.contains($0.id) }
            guard pending.count < Self.maxPendingClients else { throw HandsWireError.rateLimited }
        }
        let client = HandsAuthState.Client(id: "hc_" + Self.hex(bytes: 12), name: name.isEmpty ? "ChatGPT" : String(name),
                                           redirectURIs: uris, createdAt: now(), lastUsedAt: nil)
        state.clients.append(client)
        try saveLocked()
        return ["client_id": client.id]
    }

    private func authorizeBegin(_ params: [String: Any], context: Context) throws -> [String: Any] {
        try requireKeys(params, ["client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "resource", "scope"])
        guard let clientID = params["client_id"] as? String, clientID.utf8.count <= 256 else { throw HandsWireError.invalidRequest("client_id") }
        guard let redirect = params["redirect_uri"] as? String else { throw HandsWireError.invalidRequest("redirect_uri") }
        guard params["code_challenge_method"] as? String == "S256" else { throw HandsWireError.invalidRequest("S256 required") }
        guard let challenge = params["code_challenge"] as? String, Self.isBase64URL(challenge, length: 43) else {
            throw HandsWireError.invalidRequest("code_challenge")
        }
        let stateValue = params["state"] as? String ?? ""
        guard stateValue.utf8.count <= 1024, !stateValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HandsWireError.invalidRequest("state")
        }
        var resource: String?
        if let raw = params["resource"] {
            guard let text = raw as? String, text.utf8.count <= 512, text.hasPrefix("https://") else { throw HandsWireError.invalidRequest("resource") }
            resource = text
        }
        // W183 R8c（GPT-6 必改 5）：App 端也精確核 resource（是這台的網址），不只靠關口。沒帶＝就是這台的。
        if let expected = context.resource {
            if let resource, resource != expected { throw HandsWireError.invalidRequest("resource") }
            resource = expected
        }
        if let scope = params["scope"] {
            guard let text = scope as? String, [Self.scope, "sandbox"].contains(text) else {
                throw HandsWireError.invalidRequest("scope")
            }
        }
        lock.lock()
        guard allow("all", max: 300, per: 60), allow("begin", max: 20, per: 600) else { lock.unlock(); throw HandsWireError.rateLimited }
        let current = now()
        guard let window, window.expiresAt > current else { self.window = nil; lock.unlock(); throw HandsWireError.windowClosed }
        guard (params["scope"] as? String ?? Self.scope) == ((window.scope?.sandboxDeviceID == nil) ? Self.scope : "sandbox") else {
            lock.unlock(); throw HandsWireError.invalidRequest("scope")
        }
        if let transaction, transaction.expiresAt > current { lock.unlock(); throw HandsWireError.pairingBusy }
        guard let client = state.clients.first(where: { $0.id == clientID }) else { lock.unlock(); throw HandsWireError.invalidClient }
        guard client.redirectURIs.contains(redirect), context.callbacks.contains(redirect) else {
            lock.unlock(); throw HandsWireError.invalidRedirect
        }
        // W183 R6b：綁 attempt 的窗口用按［連線］時拍下的範圍（不讀按下之後才改的設定）。
        let created = Transaction(id: "tx_" + Self.random(bytes: 12), displayCode: Self.code(length: 4), pairingCode: Self.code(length: 8),
                                  clientID: clientID, clientName: client.name, redirectURI: redirect, challenge: challenge,
                                  state: stateValue, scope: window.scope ?? context.scope, expiresAt: window.expiresAt,
                                  attemptsLeft: Self.pairingAttempts, attemptID: window.attemptID, resource: resource)
        transaction = created
        let card = Self.card(created)
        let cardChanged = onPairingCard
        lock.unlock()
        cardChanged?(card)
        let formatter = ISO8601DateFormatter()
        return ["transaction_id": created.id, "display_code": created.displayCode, "expires_at": formatter.string(from: created.expiresAt)]
    }

    private func authorizeSubmit(_ params: [String: Any]) throws -> [String: Any] {
        try requireKeys(params, ["transaction_id", "pairing_code", "browser_binding_hash"])
        guard let id = params["transaction_id"] as? String, id.utf8.count <= 128 else { throw HandsWireError.invalidRequest("transaction_id") }
        guard let raw = params["pairing_code"] as? String, raw.utf8.count <= 64 else { throw HandsWireError.invalidRequest("pairing_code") }
        guard let binding = params["browser_binding_hash"] as? String, Self.isBindingHash(binding) else {
            throw HandsWireError.invalidRequest("browser_binding_hash")
        }
        let typed = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        lock.lock()
        guard allow("all", max: 300, per: 60), allow("submit", max: 30, per: 600) else { lock.unlock(); throw HandsWireError.rateLimited }
        let current = now()
        guard var pending = transaction, pending.id == id, let window, window.expiresAt > current, pending.expiresAt > current else {
            let expired = transaction != nil && transaction?.id == id
            if expired { transaction = nil }
            lock.unlock()
            throw window == nil ? HandsWireError.windowClosed : HandsWireError.pairingExpired
        }
        // 每交易限流（V13）：一分鐘最多 10 次送出（錯的、對的都算）。
        pending.submits = pending.submits.filter { current.timeIntervalSince($0) < 60 }
        guard pending.submits.count < 10 else { transaction = pending; lock.unlock(); throw HandsWireError.rateLimited }
        pending.submits.append(current)
        // 瀏覽器防偽 token 的雜湊：第一次送出就綁住這筆交易；之後換了（別的瀏覽器分頁）一律算錯一次。
        let bindingOK = pending.bindingHash.map { Self.constantTimeEqual($0, binding) } ?? true
        if pending.bindingHash == nil { pending.bindingHash = binding }
        let valid = bindingOK && typed.count == 8 && typed.allSatisfy({ Self.codeAlphabet.contains($0) })
            && Self.constantTimeEqual(typed, pending.pairingCode)
        let cardChanged = onPairingCard, windowChanged = onWindowChange
        if !valid {
            pending.attemptsLeft -= 1
            record("submit_fail")
            if pending.attemptsLeft <= 0 {
                // 錯滿 5 次：整筆作廢、窗口一起關（要再配對得回 App 按一次）。
                transaction = nil
                self.window = nil
                lock.unlock()
                cardChanged?(nil); windowChanged?(nil)
                throw HandsWireError.pairingExpired
            }
            transaction = pending
            let card = Self.card(pending)
            lock.unlock()
            cardChanged?(card)
            throw HandsWireError.invalidCode(pending.attemptsLeft)
        }
        // 對了：交易與窗口一起關（一個窗口配一筆），發 60 秒一次性授權碼。
        transaction = nil
        self.window = nil
        let code = "tatwoh_ac_" + Self.random(bytes: 32)
        codes[Self.hash(code)] = AuthCode(clientID: pending.clientID, redirectURI: pending.redirectURI, challenge: pending.challenge,
                                          level: pending.scope.level, projectIDs: pending.scope.projects.map(\.id),
                                          allProjects: pending.scope.allProjects,   // W183 R10
                                          expiresAt: current.addingTimeInterval(Self.codeLifetime), attemptID: pending.attemptID,
                                          resource: pending.resource)
        codes[Self.hash(code)]?.sandboxDeviceID = pending.scope.sandboxDeviceID
        lock.unlock()
        cardChanged?(nil); windowChanged?(nil)
        return ["authorization_code": code, "redirect_uri": pending.redirectURI, "state": pending.state]
    }

    private func token(_ params: [String: Any]) throws -> [String: Any] {
        try requireKeys(params, ["grant_type", "code", "code_verifier", "client_id", "redirect_uri", "refresh_token", "scope"])
        guard let clientID = params["client_id"] as? String else { throw HandsWireError.invalidRequest("client_id") }
        let currentBinding = binding?()   // W183 R8c：鎖外讀（binding 不准叫回 HandsAuth）
        lock.lock()
        bindingForIssue = currentBinding
        var revoked: [String] = []
        var attemptGrant: (String, String)?
        let result: Result<[String: Any], Error>
        do { result = .success(try tokenLocked(params, clientID: clientID, revoked: &revoked, attemptGrant: &attemptGrant)) } catch { result = .failure(error) }
        bindingForIssue = nil
        let callback = onGrantsRevoked, changed = onChange, granted = onAttemptGrant
        lock.unlock()
        if !revoked.isEmpty { callback?(revoked, "token_reuse"); changed?() }
        if case .success = result, let attemptGrant { granted?(attemptGrant.0, attemptGrant.1) }   // W183 R6b
        return try result.get()
    }

    private func tokenLocked(_ params: [String: Any], clientID: String, revoked: inout [String],
                             attemptGrant: inout (String, String)?) throws -> [String: Any] {
        let record = state.tokens.first { Self.constantTimeEqual($0.refreshHash, Self.hash(params["refresh_token"] as? String ?? "")) }
        let sandbox = params["scope"] as? String == "sandbox" || codes[Self.hash(params["code"] as? String ?? "")]?.sandboxDeviceID != nil || state.grants.first(where: { $0.id == record?.grantID })?.sandboxDeviceID != nil
        let lane = sandbox ? "sandbox:" : ""
        guard allow(lane + "all", max: 300, per: 60), allow(lane + "token", max: 60, per: 60), allow(lane + "token:" + clientID, max: 20, per: 60) else {
            throw HandsWireError.rateLimited
        }
        guard state.clients.contains(where: { $0.id == clientID }) else { throw HandsWireError.invalidClient }
        switch params["grant_type"] as? String {
        case "authorization_code":
            guard let code = params["code"] as? String, let verifier = params["code_verifier"] as? String,
                  let redirect = params["redirect_uri"] as? String else { throw HandsWireError.invalidRequest("code") }
            let key = Self.hash(code)
            guard var entry = codes[key], entry.clientID == clientID else { throw HandsWireError.invalidGrant }
            guard params["scope"] == nil || params["scope"] as? String == (entry.sandboxDeviceID == nil ? Self.scope : "sandbox") else { throw HandsWireError.invalidRequest("scope") }
            if entry.used {
                // 授權碼被用第二次：用它換到的 grant 一起撤銷（存不了檔＝全部撤銷、刪授權檔）。
                if let grant = entry.grantID, revokeLocked([grant], reason: "code_reused") { revoked.append(grant) }
                revoked += persistRevocationLocked().revoked
                throw HandsWireError.grantRevoked
            }
            guard entry.expiresAt > now() else { codes[key] = nil; throw HandsWireError.invalidGrant }
            guard entry.redirectURI == redirect else { codes[key] = nil; throw HandsWireError.invalidGrant }
            guard Self.isVerifier(verifier), Self.constantTimeEqual(Self.challenge(for: verifier), entry.challenge) else {
                codes[key] = nil   // PKCE 不符：這個碼作廢
                throw HandsWireError.invalidGrant
            }
            // W183 R6b：取消過的 attempt 的授權碼換不到 grant（取消時已經拿掉；這裡再保險一次）。
            if let attempt = entry.attemptID, cancelledAttempts.contains(attempt) { codes[key] = nil; throw HandsWireError.invalidGrant }
            // W183 R6b 審查：連線意圖換到的 grant 先是暫時的（擁有者確認才轉正；App 重開時還是暫時的＝撤銷）。
            // W183 R8c：蓋上這台的綁定（主機設備、issuer／resource、撤銷世代）；resource 要跟授權碼的一樣（跨台的碼換不到）。
            if let bound = bindingForIssue, let resource = entry.resource, let expected = bound.resource, resource != expected {
                codes[key] = nil
                throw HandsWireError.invalidGrant
            }
            let grant = HandsAuthState.Grant(id: "g_" + Self.hex(bytes: 10), clientID: clientID, level: entry.level,
                                             projectIDs: entry.projectIDs, createdAt: now(), lastUsedAt: nil,
                                             pendingAttempt: entry.attemptID, hostDeviceID: bindingForIssue?.hostDeviceID.lowercased(),
                                             issuer: bindingForIssue?.issuer, resource: entry.resource ?? bindingForIssue?.resource,
                                             generation: bindingForIssue?.generation, allProjects: entry.allProjects ? true : nil, sandboxDeviceID: entry.sandboxDeviceID)   // W183 R10
            state.grants.append(grant)
            entry.used = true
            entry.grantID = grant.id
            codes[key] = entry
            let issued = try issueLocked(grant: grant.id)
            if let attempt = entry.attemptID {
                attemptGrants[attempt, default: []].append(grant.id)
                attemptGrant = (attempt, grant.id)
            }
            return issued
        case "refresh_token":
            guard let refresh = params["refresh_token"] as? String else { throw HandsWireError.invalidRequest("refresh_token") }
            let hashed = Self.hash(refresh)
            if let used = state.usedRefresh.first(where: { Self.constantTimeEqual($0.hash, hashed) }) {
                // 舊的 refresh 又被用（外流的跡象）：撤銷該 grant（V15；存不了檔＝全部撤銷、刪授權檔）。
                if revokeLocked([used.grantID], reason: "refresh_reused") { revoked.append(used.grantID) }
                revoked += persistRevocationLocked().revoked
                throw HandsWireError.grantRevoked
            }
            guard let index = state.tokens.firstIndex(where: { Self.constantTimeEqual($0.refreshHash, hashed) }),
                  state.tokens[index].refreshExpires > now(),
                  let grant = state.grants.first(where: { $0.id == state.tokens[index].grantID }),
                  grant.isActive, grant.clientID == clientID, Self.bound(grant, to: bindingForIssue) else { throw HandsWireError.invalidGrant }
            // W183 R1b：用過的 refresh 在偵測期內一筆都不丟；存滿了就先不換新（停止核發），不能拿掉舊的證據。
            guard params["scope"] == nil || params["scope"] as? String == (grant.sandboxDeviceID == nil ? Self.scope : "sandbox") else { throw HandsWireError.invalidRequest("scope") }
            let grantID = state.tokens[index].grantID
            guard state.usedRefresh.count < Self.maxUsedRefresh,
                  state.usedRefresh.lazy.filter({ $0.grantID == grantID }).count < usedRefreshCapPerGrant else {
                throw HandsWireError.rateLimited
            }
            let old = state.tokens.remove(at: index)
            state.usedRefresh.append(.init(hash: old.refreshHash, grantID: old.grantID, usedAt: now()))
            return try issueLocked(grant: old.grantID)
        default:
            throw HandsWireError.invalidRequest("grant_type")
        }
    }

    private func issueLocked(grant: String) throws -> [String: Any] {
        let access = "tatwoh_at_" + Self.random(bytes: 32)
        let refresh = "tatwoh_rt_" + Self.random(bytes: 32)
        let issued = now()
        state.tokens.append(.init(id: "tok_" + Self.hex(bytes: 8), grantID: grant, accessHash: Self.hash(access),
                                  accessExpires: issued.addingTimeInterval(Self.accessLifetime),
                                  refreshHash: Self.hash(refresh), refreshExpires: issued.addingTimeInterval(Self.refreshLifetime),
                                  createdAt: issued))
        if let index = state.grants.firstIndex(where: { $0.id == grant }) {
            state.grants[index].lastUsedAt = issued
            let client = state.grants[index].clientID
            if let c = state.clients.firstIndex(where: { $0.id == client }) { state.clients[c].lastUsedAt = issued }
        }
        pruneLocked()
        try saveLocked()
        let changed = onChange
        DispatchQueue.global(qos: .utility).async { changed?() }
        return ["access_token": access, "token_type": "Bearer", "expires_in": Int(Self.accessLifetime),
                "refresh_token": refresh, "scope": state.grants.first { $0.id == grant }?.sandboxDeviceID == nil ? Self.scope : "sandbox"]
    }

    private func checkOp(_ params: [String: Any], levelCap: Int) throws -> [String: Any] {
        try requireKeys(params, ["access_token"])
        guard let access = params["access_token"] as? String else { throw HandsWireError.invalidRequest("access_token") }
        let found = grant(forAccess: access)
        lock.lock()
        let allowed = allow(found?.sandboxDeviceID == nil && found != nil ? "check" : "sandbox:check", max: 1200, per: 60)
        lock.unlock()
        guard allowed else { throw HandsWireError.rateLimited }
        guard let found else { return ["ok": false] }
        return ["ok": true, "grant_id": found.grantID, "client_id": found.clientID, "level": min(found.grantLevel, levelCap), "scope": found.sandboxDeviceID == nil ? Self.scope : "sandbox"]
    }

    // MARK: - App 內用

    /// 每次工具呼叫都重查（撤銷、過期立刻拒絕）。
    /// W183 R8c：也核這台的綁定（別台的 grant、網址換了、撤銷世代變了＝不認）。
    func grant(forAccess accessToken: String) -> HandsGrantAccess? {
        guard accessToken.hasPrefix("tatwoh_at_"), accessToken.utf8.count < 200 else { return nil }
        let hashed = Self.hash(accessToken)
        let currentBinding = binding?()   // 鎖外讀
        lock.lock(); defer { lock.unlock() }
        guard persistenceFailure == nil else { return nil }   // 撤銷沒存成：一律不認（W183 R1b）
        guard let token = state.tokens.first(where: { Self.constantTimeEqual($0.accessHash, hashed) }), token.accessExpires > now(),
              let grant = state.grants.first(where: { $0.id == token.grantID }), grant.isActive,
              state.clients.contains(where: { $0.id == grant.clientID }), Self.bound(grant, to: currentBinding) else { return nil }
        return HandsGrantAccess(grantID: grant.id, clientID: grant.clientID, grantLevel: grant.level, projectIDs: grant.projectIDs,
                                provisional: grant.pendingAttempt != nil, allProjects: grant.allProjects == true, sandboxDeviceID: grant.sandboxDeviceID)   // W183 R10
    }

    /// 沙盒發布與 revokeLocked 同鎖；body 只存工作／提案資料，不回呼授權。
    func withSandboxAccess<T>(_ access: String, _ body: () throws -> T) throws -> T {
        let hashed = Self.hash(access), currentBinding = binding?()
        lock.lock(); defer { lock.unlock() }
        guard persistenceFailure == nil, let token = state.tokens.first(where: { Self.constantTimeEqual($0.accessHash, hashed) }), token.accessExpires > now(),
              let grant = state.grants.first(where: { $0.id == token.grantID }), grant.isActive, grant.sandboxDeviceID != nil,
              Self.bound(grant, to: currentBinding) else { throw HandsWireError.unauthorized }
        return try body()
    }

    func grantRecord(_ id: String) -> HandsAuthState.Grant? {
        lock.lock(); defer { lock.unlock() }
        return state.grants.first { $0.id == id }
    }

    func grants() -> [HandsGrantSummary] {
        lock.lock(); defer { lock.unlock() }
        return state.grants.map { grant in
            HandsGrantSummary(id: grant.id, clientName: state.clients.first { $0.id == grant.clientID }?.name ?? "ChatGPT",
                              level: grant.level, projectIDs: grant.projectIDs, createdAt: grant.createdAt,
                              lastUsedAt: grant.lastUsedAt, revokedAt: grant.revokedAt, revokeReason: grant.revokeReason,
                              provisional: grant.pendingAttempt != nil)
        }
    }

    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：授權狀態現在的版本（連線確認的結果、回報都帶這個）。
    var stateVersion: Int {
        lock.lock(); defer { lock.unlock() }
        return state.version ?? 0
    }

    /// W183 R11 最後一輪：回報用的一份（同一把鎖裡讀：版本、有效的 grant、每一筆的摘要對得上同一個時刻）。
    func reportSnapshot() -> (version: Int, active: [String], summaries: [HandsGrantSummary]) {
        lock.lock(); defer { lock.unlock() }
        let summaries = state.grants.map { grant in
            HandsGrantSummary(id: grant.id, clientName: state.clients.first { $0.id == grant.clientID }?.name ?? "ChatGPT",
                              level: grant.level, projectIDs: grant.projectIDs, createdAt: grant.createdAt,
                              lastUsedAt: grant.lastUsedAt, revokedAt: grant.revokedAt, revokeReason: grant.revokeReason,
                              provisional: grant.pendingAttempt != nil)
        }
        return (state.version ?? 0, state.grants.filter(\.isActive).map(\.id), summaries)
    }

    var activeGrantIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return state.grants.filter(\.isActive).map(\.id)
    }

    /// 撤銷一個 grant（畫面）。回 nil＝撤銷已存檔；否則是錯誤說明（W183 R1b：存不了檔＝全部撤銷、授權檔刪掉，畫面要顯示）。
    @discardableResult
    func revokeGrant(_ id: String, reason: String = "user_revoked") -> String? {
        let result = revokeGrantDeferred(id, reason: reason)
        result.notify()
        return result.problem
    }

    /// W183 R6b 審查：同上，但通知交給呼叫端放鎖之後再送（撤銷在這裡就已生效）。
    func revokeGrantDeferred(_ id: String, reason: String) -> (problem: String?, notify: () -> Void) {
        lock.lock()
        var ids = revokeLocked([id], reason: reason) ? [id] : []
        let persisted = persistRevocationLocked()
        ids += persisted.revoked
        let callback = onGrantsRevoked, changed = onChange
        lock.unlock()
        let revoked = ids
        return (persisted.problem, {
            if !revoked.isEmpty { callback?(revoked, reason) }
            changed?()
        })
    }

    func revokeSandboxDevice(_ device: String) {
        lock.lock()
        let pending = window?.scope?.sandboxDeviceID == device || transaction?.scope.sandboxDeviceID == device
        guard pending || codes.values.contains(where: { $0.sandboxDeviceID == device }) || state.grants.contains(where: { $0.sandboxDeviceID == device && $0.isActive }) else { lock.unlock(); return }
        if pending { window = nil; transaction = nil }
        codes = codes.filter { $0.value.sandboxDeviceID != device }
        var ids = state.grants.filter { $0.sandboxDeviceID == device && $0.isActive }.map(\.id)
        _ = revokeLocked(ids, reason: "sandbox_removed")
        ids += persistRevocationLocked().revoked
        lock.unlock()
        if pending { onPairingCard?(nil); onWindowChange?(nil) }
        if !ids.isEmpty { onGrantsRevoked?(ids, "sandbox_removed"); onChange?() }
    }

    /// W183 R11（GPT-6 R11 審查 1，高：「自動遷移會讓曾經被降級的舊 L2 grant 恢復」）：把現有的 grant 封頂在 maxLevel（寫進授權檔）——
    /// 中央等級收窄時 grant 跟著降、調高時現有的 grant 封頂在調高前的等級（HandsService.levelGuard）：之後再調高（面板、R11 的預設遷移）
    /// 只給之後按［連線］、看過確認卡核准的新 grant。存不進去＝跟撤銷一樣 fail closed（全部撤銷、刪授權檔）。
    /// 會在 HandsSandbox 的鎖裡被叫（admission → effectiveSettings）：撤銷的收尾（grantsRevoked 會碰 HandsSandbox）一律丟到背景做，這裡不等。
    /// W183 R11 第二輪（GPT-6 R11b 審查 2，高）：回結果——存好了（或沒有要封頂的）；存不進去但授權檔刪掉了（全部撤銷，重開也讀不回）；
    /// 存不進去、授權檔也刪不掉（磁碟上還是封頂前的樣子：levelGuard 不記下新的等級、留下待完成的上限）。上一次就是後者、這次沒有新的要封頂
    /// ＝再存一次現在的樣子（全部撤銷過的），存好了才算數。
    @discardableResult
    func capGrants(maxLevel: Int) -> HandsCapOutcome {
        let ceiling = min(max(maxLevel, 0), HandsSettings.maxLevel)
        lock.lock()
        var capped = false
        for index in state.grants.indices where state.grants[index].isActive && state.grants[index].level > ceiling {
            state.grants[index].level = ceiling
            capped = true
        }
        guard capped || diskMayHoldOldGrants else { lock.unlock(); return .durable }
        let persisted = persistRevocationLocked()
        let callback = onGrantsRevoked, changed = onChange
        lock.unlock()
        if !persisted.revoked.isEmpty {
            let revoked = persisted.revoked
            DispatchQueue.global(qos: .userInitiated).async { callback?(revoked, "revocation_not_saved") }
        }
        changed?()
        guard let problem = persisted.problem else { return .durable }
        return persisted.removed ? .revokedFileRemoved(problem) : .notDurable(problem)
    }

    /// 撤銷全部 grant（一鍵撤銷、關開關）：token、授權碼、窗口、交易一起作廢；client 留著（重新打開要重新配對）。回 nil＝已存檔。
    @discardableResult
    func revokeAll(reason: String) -> String? {
        lock.lock()
        let ids = state.grants.filter(\.isActive).map(\.id)
        _ = revokeLocked(ids, reason: reason)
        state.tokens.removeAll()
        codes.removeAll()
        attemptGrants.removeAll()   // W183 R6b：全部撤銷了，attempt 的 grant 也都不在了
        let hadWindow = window != nil || transaction != nil
        window = nil
        transaction = nil
        let persisted = persistRevocationLocked()
        let callback = onGrantsRevoked, changed = onChange, cardChanged = onPairingCard, windowChanged = onWindowChange
        lock.unlock()
        if hadWindow { cardChanged?(nil); windowChanged?(nil) }
        if !ids.isEmpty { callback?(ids, reason) }
        changed?()
        return persisted.problem
    }

    /// 移除一個 ChatGPT 連線（client）：它的 grant 一起撤銷。回 nil＝已存檔。
    @discardableResult
    func removeClient(_ id: String) -> String? {
        lock.lock()
        var ids = state.grants.filter { $0.clientID == id && $0.isActive }.map(\.id)
        _ = revokeLocked(ids, reason: "client_removed")
        state.clients.removeAll { $0.id == id }
        codes = codes.filter { $0.value.clientID != id }
        let voided = transaction?.clientID == id
        if voided { transaction = nil }
        let persisted = persistRevocationLocked()
        ids += persisted.revoked
        let callback = onGrantsRevoked, changed = onChange, cardChanged = onPairingCard
        lock.unlock()
        if voided { cardChanged?(nil) }
        if !ids.isEmpty { callback?(ids, "client_removed") }
        changed?()
        return persisted.problem
    }

    /// 撤銷存不了檔時的說明（nil＝沒問題）。畫面顯示用。
    var revocationProblem: String? {
        lock.lock(); defer { lock.unlock() }
        return persistenceFailure
    }

    /// 測試與畫面：現在的確認卡。
    var pendingCard: HandsPairingCard? {
        lock.lock(); defer { lock.unlock() }
        guard let transaction, transaction.expiresAt > now() else { return nil }
        return Self.card(transaction)
    }

    // MARK: - 內部

    private static func card(_ t: Transaction) -> HandsPairingCard {
        HandsPairingCard(id: t.id, displayCode: t.displayCode, pairingCode: t.pairingCode,
                         callbackHost: URLComponents(string: t.redirectURI)?.host?.lowercased() ?? "?", callbackURL: t.redirectURI,
                         clientName: t.clientName, scope: t.scope, expiresAt: t.expiresAt, attemptsLeft: t.attemptsLeft,
                         attemptID: t.attemptID)
    }

    /// W183 R6b：Pod 看到的授權網址（client_id、redirect_uri、state、code_challenge）與交易比對用的雜湊（兩邊用同一個算法）。
    static func evidenceHash(clientID: String, redirectURI: String, state: String, challenge: String) -> String {
        "sha256:" + sha256Hex(Data([clientID, redirectURI, state, challenge].joined(separator: "\n").utf8))
    }

    /// W183 R8c（GPT-6 必改 5）：配對頁證據第二版——上面那四個參數的雜湊再綁上 target（主機設備）、issuer、resource、attempt、setupEpoch。
    /// 擁有者用它按［連線］時的意圖算、主機用自己的設備 id／網址／交易的 resource／attempt 的世代算；A 那一筆拿到 B 用一定對不上。
    static func boundEvidence(_ evidence: String, target: String, issuer: String, resource: String, attempt: String, setupEpoch: String) -> String {
        "sha256:" + sha256Hex(Data(["tatwo-evidence-v2", target.lowercased(), issuer.lowercased(), resource.lowercased(), attempt.lowercased(),
                                       setupEpoch, evidence].joined(separator: "\n").utf8))
    }

    /// W183 R8c：grant 跟這台現在的綁定對得上嗎（binding nil＝不核：自測的單機世界）。
    /// W183 R8c 審查（GPT-6 中「驗證漏掉 issuer，缺 resource 也可能通過」）：主機設備、issuer、resource、撤銷世代**全部**要有、而且精確相符；
    /// 缺任何一欄（舊資料）一律不認——舊資料只經 upgradeLegacyBindings 明確遷移（蓋上這台的綁定）或撤銷。這台現在沒有網址＝都不認。
    static func bound(_ grant: HandsAuthState.Grant, to binding: HandsGrantBinding?) -> Bool {
        guard let binding else { return true }
        guard let host = grant.hostDeviceID, host.caseInsensitiveCompare(binding.hostDeviceID) == .orderedSame,
              let issuer = grant.issuer, let expectedIssuer = binding.issuer, issuer.lowercased() == expectedIssuer.lowercased(),
              let resource = grant.resource, let expectedResource = binding.resource, resource.lowercased() == expectedResource.lowercased(),
              let generation = grant.generation, generation == binding.generation else { return false }
        return true
    }

    /// W183 R8c 審查（Claude 中「升級前就有的 grant 在新版一律不認，但還是被算成有效」）：舊的（沒有綁定欄位的）有效 grant 明確處理一次——
    /// 這台現在有網址、而且還沒遷移過（auth.json 記一次）：蓋上這台現在的綁定（auth.json 本來就只在這台、不同步）；沒有網址、或已經遷移過
    /// 還出現沒綁定的（例如別台的 auth.json 被搬過來）：用明確的原因撤銷。計數、畫面、實際能不能用就一致。回傳（蓋上幾筆、撤銷幾筆）。
    @discardableResult
    func upgradeLegacyBindings(_ binding: HandsGrantBinding) -> (stamped: Int, revoked: Int) {
        lock.lock()
        let legacy = state.grants.filter { $0.isActive && ($0.hostDeviceID == nil || $0.issuer == nil || $0.resource == nil || $0.generation == nil) }.map(\.id)
        guard !legacy.isEmpty || state.bindingUpgradedAt == nil else { lock.unlock(); return (0, 0) }
        let firstTime = state.bindingUpgradedAt == nil
        var stamped = 0
        var revoke: [String] = []
        for id in legacy {
            guard let index = state.grants.firstIndex(where: { $0.id == id }) else { continue }
            let grant = state.grants[index]
            let untouched = grant.hostDeviceID == nil && grant.issuer == nil && grant.resource == nil && grant.generation == nil
            if firstTime, untouched, let issuer = binding.issuer, let resource = binding.resource {
                state.grants[index].hostDeviceID = binding.hostDeviceID.lowercased()
                state.grants[index].issuer = issuer
                state.grants[index].resource = resource
                state.grants[index].generation = binding.generation
                stamped += 1
            } else {
                revoke.append(id)
            }
        }
        _ = revokeLocked(revoke, reason: "binding_upgrade")
        state.bindingUpgradedAt = now()
        let persisted = persistRevocationLocked()
        let callback = onGrantsRevoked, changed = onChange
        lock.unlock()
        if !revoke.isEmpty { callback?(revoke + persisted.revoked, "binding_upgrade") }
        changed?()
        return (stamped, revoke.count)
    }

    /// 回傳有沒有真的撤銷到（原本有效的）。
    private func revokeLocked(_ ids: [String], reason: String) -> Bool {
        var any = false
        for id in ids {
            guard let index = state.grants.firstIndex(where: { $0.id == id }), state.grants[index].isActive else { continue }
            state.grants[index].revokedAt = now()
            state.grants[index].revokeReason = reason
            any = true
        }
        let set = Set(ids)
        state.tokens.removeAll { set.contains($0.grantID) }
        return any
    }

    private func record(_ key: String) {
        var list = events[key, default: []]
        list.append(now())
        if list.count > 500 { list.removeFirst(list.count - 500) }
        events[key] = list
    }

    private func allow(_ key: String, max: Int, per window: TimeInterval) -> Bool {
        let cutoff = now().addingTimeInterval(-window)
        var list = (events[key] ?? []).filter { $0 > cutoff }
        guard list.count < max else { events[key] = list; return false }
        list.append(now())
        events[key] = list
        return true
    }

    private func pruneLocked() {
        let current = now()
        state.tokens.removeAll { $0.refreshExpires <= current }
        // 用過的 refresh 只在它本來就過期之後才清（usedAt＋30 天 ≥ 它的到期時間）；偵測期內不因為筆數多就丟（W183 R1b）。
        state.usedRefresh.removeAll { $0.usedAt < current.addingTimeInterval(-Self.refreshLifetime) }
        codes = codes.filter { $0.value.expiresAt > current.addingTimeInterval(-Self.refreshLifetime) }
        // 撤銷超過 90 天、手上已經沒有任何東西的 grant 紀錄才清（工作區紀錄還要認得擁有者）。
        if state.grants.count > 500 {
            let cutoff = current.addingTimeInterval(-90 * 86_400)
            state.grants.removeAll { ($0.revokedAt ?? .distantFuture) < cutoff }
        }
    }

    private func saveLocked() throws {
        state.version = (state.version ?? 0) + 1   // W183 R11 最後一輪：存不進去也往上（這個行程裡只會往上）
        #if DEBUG
        if failSavesForTesting { throw HandsFileError.unsafe("save_failed_for_testing") }
        #endif
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try HandsFiles.writeAtomically(try encoder.encode(state), to: url)
        persistenceFailure = nil   // 磁碟上現在就是記憶體裡的樣子（撤銷過的也寫進去了）
        diskMayHoldOldGrants = false
    }

    /// W183 R1b：撤銷類的存檔。存不了（磁碟滿等）＝不能讓重開 App 讀回舊的有效 grant／token：
    /// 記憶體裡全部 grant 撤銷、token 清空，授權檔刪掉（刪檔不用空間），在下一次存檔成功前一律不認 token。
    /// 回（錯誤說明、額外撤銷的 grant）；存好了＝(nil, [])。
    /// W183 R11 第二輪：多回一個 removed（存不進去時授權檔有沒有刪掉；存好了＝true）。
    private func persistRevocationLocked() -> (problem: String?, revoked: [String], removed: Bool) {
        do {
            try saveLocked()
            return (nil, [], true)
        } catch {
            let others = state.grants.filter(\.isActive).map(\.id)
            _ = revokeLocked(others, reason: "revocation_not_saved")
            state.tokens.removeAll()
            codes.removeAll()
            #if DEBUG
            // 自測：模擬刪不掉（不真的刪、不設不可變旗標）：磁碟上留著存檔失敗之前的樣子。
            let removed = failRemovesForTesting ? false : (unlink(url.path) == 0 || errno == ENOENT)
            #else
            let removed = unlink(url.path) == 0 || errno == ENOENT
            #endif
            var problem = "撤銷沒能存檔（\(error)）：已停用全部 ChatGPT 連線、刪掉授權檔，要重新配對"
            if !removed { problem += "；授權檔也刪不掉，重開 App 前請先在設定關掉 ChatGPT 手腳" }
            persistenceFailure = problem
            if !removed { diskMayHoldOldGrants = true }
            return (problem, others, removed)
        }
    }

    // MARK: - 小工具

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        return bytes
    }

    static func random(bytes count: Int) -> String { base64URL(Data(randomBytes(count))) }
    static func hex(bytes count: Int) -> String { randomBytes(count).map { String(format: "%02x", $0) }.joined() }

    /// V17 字元集；取樣到 256 可被 32 整除，取餘數沒有偏差。
    static func code(length: Int) -> String {
        String(randomBytes(length).map { codeAlphabet[Int($0) % codeAlphabet.count] })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ value: String) -> String { sha256Hex(Data(value.utf8)) }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// PKCE S256：BASE64URL(SHA256(code_verifier))。
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func isVerifier(_ value: String) -> Bool {
        (43...128).contains(value.count) && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-._~".unicodeScalars.contains($0)
        }
    }

    static func isBase64URL(_ value: String, length: Int) -> Bool {
        value.count == length && value.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }

    /// 關口算的瀏覽器防偽 token 雜湊：`sha256:` 加 16–64 個十六進位字。
    static func isBindingHash(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = value.dropFirst(7)
        return (16...64).contains(hex.count) && hex.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }

    /// ChatGPT 連接器的 OAuth 回呼網址（OpenAI 公布的固定網址，不是使用者的網域）：
    /// `https://chatgpt.com/connector_platform_oauth_redirect`、`https://chatgpt.com/connector/oauth/<callback id>`。
    /// 設定清單只收這兩種樣子；真正比對是精確比對設定清單（接口 v2 §2）。
    static let redirectHosts: Set<String> = ["chatgpt.com"]
    static let stableRedirectPath = "/connector_platform_oauth_redirect"
    static let callbackRedirectPrefix = "/connector/oauth/"

    /// 只收 https、主機在白名單、預設埠、沒有帳密／query／#fragment、路徑是上面兩種之一。
    static func isAcceptableRedirect(_ value: String) -> Bool {
        guard value.utf8.count <= 512, !value.contains("#"),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, components.query == nil, components.port == nil,
              redirectHosts.contains(host) else { return false }
        let path = components.percentEncodedPath
        if path == stableRedirectPath { return true }
        guard path.hasPrefix(callbackRedirectPrefix) else { return false }
        let callback = path.dropFirst(callbackRedirectPrefix.count)
        return (1...128).contains(callback.count)
            && callback.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }
    }
}
