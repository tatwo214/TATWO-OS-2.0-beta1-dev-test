import Foundation

// W183 R6b：「一個開關」的主機端——連線意圖（attempt）與配對窗口（one-switch.md「配對（GPT-6 設計審查後的首版）」）。
//
// - 使用者在私訊框按［連線］＝擁有者那台送一個 attempt 來（本機直接呼叫；副設備走設備簽章 RPC begin_connect）。
//   主機一次只接受一個 attempt：同 ID 冪等、不同 ID 回忙碌。窗口、交易、授權範圍、授權碼、grant 都綁這個 attempt（HandsAuth）。
// - 範圍快照：擁有者按下時看到的等級、專案、記憶（offer 的 digest）。開窗口前再算一次，不一樣＝不開（範圍改變，回去重新顯示卡片）；
//   authorize_begin 用快照，不讀按下之後才改的設定；之後範圍一變（狀態查詢、authorize_begin 前都會核對）＝取消。
// - 世代：setupEpoch（主機設定流程取消、關掉、App 重開都會換）不一樣＝不收；attempt 進行中世代換了＝取消。
// - 配對碼只給擁有者，而且只在擁有者的 Pod 看到的授權網址（client、redirect、state、challenge）跟交易完全一樣時（evidence）。
//   第一次對上就綁住那一筆交易；對不上（攻擊者先占交易、別的授權網址）＝終止（refused）、不給碼、交易作廢、窗口關掉。
// - 成功＝這個 attempt 的交易換到 grant（HandsAuth.onAttemptGrant），而且**這個 grant** 的第一次 /mcp 成功（HandsService 回報）。
//   「授權完成」（granted）與「工具連上」（connected）分開。取消與成功只會有一個終態（鎖裡決定）：取消先＝grant 撤銷；成功先＝取消不動它。
// - 只在記憶體：App 重開＝全部作廢（自動續跑不會沿用重開前的［連線］）；還沒確認的 grant 在 HandsAuth 啟動時撤銷。
// W183 R6b 審查（GPT-6、Claude）：
// - 取消與撤銷在同一把鎖裡：先撤銷（HandsAuth 的狀態已改）才公布終態；通知放鎖之後送。
// - 「已連線」只由擁有者的確認（confirm；核對過 Pod 帳號）產生；第一次 /mcp 只到 tools_ready，之前一直可以撤銷（grant 是暫時的、不能呼叫工具）。
// - 世代、範圍、期限在每個提交點都重核：authorize_begin／authorize_submit／token（HandsService）、grant 產生（noteGrant）、
//   /mcp（admit）、確認（confirm）；設定一改也核一次。期限＝窗口 10 分鐘，有碼或 grant 再多 3 分鐘；到期沒人問也會收（計時）。
// - begin 之前就到的取消記成墓碑：晚到的 begin 回「已取消」、不開窗口（HandsAuth 也記著取消過的 attempt）。
// W183 R7a 審查（GPT-6：範圍寫入與取消、同 ID 並發沒有原子性）：begin（核對、驗卡上選的範圍、寫設定、開窗口）與 cancel 排成一條隊
// （commitLock），一次只做一個——取消不會插在「寫設定」與「開窗口」中間先回「已取消」；取消先到＝墓碑，之後的 begin 不寫設定。
// 同 ID 正在跑的 attempt：內容（整個 request，含擁有者與卡上選的範圍）不一樣＝在任何副作用之前就拒絕。
// 驗過之後、寫之前設定被別的地方改了（「詳細」、另一條路）＝不寫、回範圍改變。
// W183 R8c（多設備；GPT-6 必改 5）：擁有者送來的 evidence 是第二版（HandsAuth.boundEvidence：四個 OAuth 參數＋target＋issuer／resource＋
//   attempt＋setupEpoch）；主機用自己的設備 id、交易核對過的 resource、這個 attempt 與它的世代算，對上才綁、才給碼。
//   別台的碼卡、別台的 attempt、別台的網址一律對不上（refused）。每台一次一個窗口（HandsAuth）照舊；擁有者經信箱（HandsBuildMailbox）也一樣。

// W183 R10（使用者 09-29「這邊要勾選也太怪 就要給他用了還要多一個勾選」）：範圍＝中央設定的等級＋這台全部專案（allProjects）。
// - offer 不再給卡上選（supportsChoice＝false：不帶 project_choices、level_memory、unchecked_in_build）；卡片只顯示。
// - begin 帶了卡上選的範圍（level、project_ids）＝一律拒絕（connect_scope_invalid）：主機的範圍只照 ChatGPT build 的中央設定，
//   卡片、設備簽章的 begin_connect 都改不到（取代 W183 R7a 的「驗過就寫進主機設定」）。
// - 範圍快照的 digest：全部可見時專案那一段記「*」（新專案、外接碟暫時不見不會讓進行中的連線作廢）；等級、網址、記憶、callback 照舊綁。

/// 擁有者按［連線］前看到的東西（主機算、擁有者顯示；digest 綁住整份）。不是秘密：沒有碼、沒有 token。
struct HandsConnectOffer: Equatable, Sendable {
    let hostDeviceID: String
    let hostName: String
    let publicHost: String
    let scope: HandsGrantScope
    /// 授權後回到的網域（ChatGPT callback 的主機名）。
    let callbackHosts: [String]
    let setupEpoch: String
    /// W183 R7a：卡上可以選的專案（id、名稱、資料夾最後一段）、每個等級的記憶說明、主機收不收卡上選的範圍（舊版主機＝false：
    /// 卡片照舊只顯示）、主機上已連線幾筆（選得比較小時提醒）。都不進 digest（digest 只綁範圍本身）。
    var projectChoices: [HandsProjectChoice] = []
    var levelMemory: [String] = []
    var supportsChoice = false
    var connectedCount = 0

    /// `https://<公開主機名>/mcp`（主機的可信設定，不從網頁讀）。
    var mcpURL: String { "https://\(publicHost)/mcp" }

    /// 範圍快照的雜湊：主機、網址、等級、專案（id）、記憶文字、callback。擁有者按下時送回來，主機開窗口前核對。
    /// W183 R10：全部可見＝專案那一段是「*」（清單只給卡片顯示；新專案自動包含，不讓進行中的連線因為多一個專案就作廢）。
    var digest: String {
        let projects = scope.allProjects ? "*" : scope.projects.map(\.id).sorted().joined(separator: ",")
        let text = [hostDeviceID.lowercased(), mcpURL, String(scope.level), projects, scope.memory, callbackHosts.sorted().joined(separator: ",")]
            .joined(separator: "\n")
        return "sha256:" + HandsAuth.sha256Hex(Data(text.utf8))
    }

    var wire: [String: Any] {
        var out: [String: Any] = [
            "host_device_id": hostDeviceID, "host_name": String(hostName.prefix(60)), "public_host": publicHost, "mcp_url": mcpURL,
            "level": scope.level, "projects": scope.projects.map { ["id": $0.id, "name": String($0.name.prefix(80))] },
            "memory": scope.memory, "callback_hosts": callbackHosts, "setup_epoch": setupEpoch, "scope_digest": digest]
        if supportsChoice {   // W183 R7a：卡上選範圍要的（舊版擁有者不看這些欄位）。W183 R10 的主機一律不給（supportsChoice＝false）。
            out["project_choices"] = projectChoices.map(\.wire)
            out["level_memory"] = levelMemory
            out["connected_count"] = connectedCount
        }
        if scope.allProjects {   // W183 R10：全部可見（digest 的專案那一段是「*」）；交易實盤類的另外列（卡片標「只能看」）
            out["all_projects"] = true
            out["read_only_projects"] = scope.readOnlyProjectIDs
        }
        return out
    }

    /// 副設備收到的（欄位全部驗過；digest 自己重算，跟主機給的不一樣＝不收）。
    init?(wire object: [String: Any]) {
        guard let host = object["host_device_id"] as? String, UUID(uuidString: host) != nil,
              let publicHost = HandsGatewayLaunch.validHost(object["public_host"] as? String),
              let level = object["level"] as? Int, (0...HandsSettings.maxLevel).contains(level),
              let epoch = object["setup_epoch"] as? String, epoch.utf8.count <= 64,
              let digest = object["scope_digest"] as? String, object["mcp_url"] as? String == "https://\(publicHost)/mcp" else { return nil }
        // W183 R7a 審查：跟卡上的清單同一個上限（不截在 64 個；截了 digest 就對不上）。
        let projects = (object["projects"] as? [[String: Any]] ?? []).prefix(HandsProjectChoice.listLimit).compactMap { raw -> HandsProjectRef? in
            guard let id = raw["id"] as? String, UUID(uuidString: id) != nil else { return nil }
            return HandsProjectRef(id: id, name: String((raw["name"] as? String ?? "").filter { !$0.isNewline }.prefix(80)))
        }
        let callbacks = (object["callback_hosts"] as? [String] ?? []).prefix(8).compactMap { HandsGatewayLaunch.validHost($0) }
        // W183 R10：全部可見（只收 true 這個布林）與交易實盤類的 id（只收 UUID、跟清單同一個上限）。
        let all = (object["all_projects"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        let readOnly = (object["read_only_projects"] as? [String] ?? []).prefix(HandsProjectChoice.listLimit).compactMap { UUID(uuidString: $0)?.uuidString }
        self.init(hostDeviceID: host, hostName: String((object["host_name"] as? String ?? "").filter { !$0.isNewline }.prefix(60)),
                  publicHost: publicHost, scope: HandsGrantScope(level: level, projects: projects,
                                                                 memory: String((object["memory"] as? String ?? "").prefix(200)),
                                                                 allProjects: all, readOnlyProjectIDs: all ? readOnly : []),
                  callbackHosts: Array(callbacks), setupEpoch: epoch,
                  // W183 R7a：主機給了可以選的專案＝收卡上選的範圍（沒給＝舊版主機，卡片照舊只顯示）。
                  // W183 R7a 審查：清單不完整（超過上限、有看不懂的列）＝不收卡上選（不拿不完整的清單重建授權）。
                  projectChoices: HandsProjectChoice.list(object["project_choices"]) ?? [],
                  levelMemory: (object["level_memory"] as? [String] ?? []).prefix(HandsSettings.maxLevel + 1).map { String($0.prefix(200)) },
                  supportsChoice: HandsProjectChoice.list(object["project_choices"]) != nil, connectedCount: max((object["connected_count"] as? Int) ?? 0, 0))
        guard self.digest == digest else { return nil }
    }

    init(hostDeviceID: String, hostName: String, publicHost: String, scope: HandsGrantScope, callbackHosts: [String], setupEpoch: String,
         projectChoices: [HandsProjectChoice] = [], levelMemory: [String] = [], supportsChoice: Bool = false, connectedCount: Int = 0) {
        self.hostDeviceID = hostDeviceID
        self.hostName = hostName
        self.publicHost = publicHost
        self.scope = scope
        self.callbackHosts = callbackHosts
        self.setupEpoch = setupEpoch
        self.projectChoices = projectChoices
        self.levelMemory = levelMemory
        self.supportsChoice = supportsChoice
        self.connectedCount = connectedCount
    }
}

/// 主機這一次連線意圖的狀態（給擁有者；非擁有者一律拒絕）。配對碼只在 pairingCode（擁有者＋Pod 看到的網址對得上才有）。
struct HandsConnectStatus: Equatable, Sendable {
    enum State: String, Sendable {
        /// 窗口開著、還沒有交易。
        case open
        /// 有一筆綁這個 attempt 的交易在等配對碼。
        case pending
        /// 配對碼對了、授權碼還沒被換（等 ChatGPT 來 /token）。
        case authorized
        /// 這個 attempt 換到 grant，等它的第一次 /mcp。
        case granted
        /// W183 R6b 審查：這個 grant 的第一次 /mcp 成功了，等擁有者核對 Pod 帳號後確認（還可以撤銷）。
        case toolsReady = "tools_ready"
        /// 擁有者確認了（這個 attempt 的 grant、第一次 /mcp、同一個帳號）：已連線。
        case connected
        case cancelled, refused, expired
        var isTerminal: Bool { [.connected, .cancelled, .refused, .expired].contains(self) }
    }
    struct Transaction: Equatable, Sendable {
        let displayCode: String
        let expiresAt: Date
        let attemptsLeft: Int
        let callbackHost: String
        /// Pod 看到的授權網址已經對上這一筆（綁住了）。
        let evidenceBound: Bool
        /// 只有擁有者、而且這次查詢帶的 evidence 就是綁住的那一組才有。
        let pairingCode: String?
    }
    let attemptID: String
    let state: State
    /// 終止或取消的原因（機器代碼）。
    let reason: String?
    let windowExpiresAt: Date?
    let transaction: Transaction?
    /// 看過 /register（動態註冊）沒有（診斷「卡在哪段」）。
    let registered: Bool
    /// W183 R11（GPT-6 R11 審查 4）：連上了＝這一筆連線的代號（HandsBuildDeviceReport.grantTag；不是 grant id、不含帳號）。
    /// 按［連線］的那台記下「這個帳號的那一條」（HandsConnectAccounts），之後照主機回報裡的代號核對它還在不在。舊版主機沒有＝nil。
    var grantTag: String? = nil
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：確認這一條那一刻主機授權狀態的版本（HandsAuth.stateVersion）：之後的回報拿它比先後。
    var grantVersion: Int? = nil

    var wire: [String: Any] {
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = ["attempt_id": attemptID, "state": state.rawValue, "registered": registered]
        if let reason { out["reason"] = reason }
        if let grantTag { out["grant_tag"] = grantTag }   // W183 R11
        if let grantVersion { out["grant_version"] = grantVersion }   // W183 R11 最後一輪
        if let windowExpiresAt { out["window_expires_at"] = iso.string(from: windowExpiresAt) }
        if let t = transaction {
            var tx: [String: Any] = ["display_code": t.displayCode, "expires_at": iso.string(from: t.expiresAt), "attempts_left": t.attemptsLeft,
                                     "callback_host": t.callbackHost, "evidence_bound": t.evidenceBound]
            if let code = t.pairingCode { tx["pairing_code"] = code }
            out["transaction"] = tx
        }
        return out
    }

    init(attemptID: String, state: State, reason: String?, windowExpiresAt: Date?, transaction: Transaction?, registered: Bool) {
        self.attemptID = attemptID
        self.state = state
        self.reason = reason
        self.windowExpiresAt = windowExpiresAt
        self.transaction = transaction
        self.registered = registered
    }

    init?(wire object: [String: Any]) {
        guard let id = object["attempt_id"] as? String, UUID(uuidString: id) != nil,
              let raw = object["state"] as? String, let state = State(rawValue: raw) else { return nil }
        let iso = ISO8601DateFormatter()
        attemptID = id
        self.state = state
        reason = (object["reason"] as? String).flatMap { $0.utf8.count <= 80 ? $0 : nil }
        windowExpiresAt = (object["window_expires_at"] as? String).flatMap(iso.date(from:))
        registered = object["registered"] as? Bool ?? false
        grantTag = state == .connected ? HandsBuildDeviceReport.validGrantTag(object["grant_tag"]) : nil   // W183 R11
        grantVersion = state == .connected
            ? (object["grant_version"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : max($0.intValue, 0) } : nil
        if let tx = object["transaction"] as? [String: Any], let display = tx["display_code"] as? String, display.count <= 8,
           let expires = (tx["expires_at"] as? String).flatMap(iso.date(from:)) {
            let code = (tx["pairing_code"] as? String).flatMap { value -> String? in
                value.count == 8 && value.allSatisfy({ HandsAuth.codeAlphabet.contains($0) }) ? value : nil
            }
            transaction = Transaction(displayCode: display, expiresAt: expires, attemptsLeft: tx["attempts_left"] as? Int ?? 0,
                                      callbackHost: String((tx["callback_host"] as? String ?? "?").prefix(120)),
                                      evidenceBound: tx["evidence_bound"] as? Bool ?? false, pairingCode: code)
        } else {
            transaction = nil
        }
    }
}

/// begin_connect 的內容（擁有者送來；owner 必須是驗章得到的那台）。
struct HandsConnectRequest: Equatable, Sendable {
    let attemptID: String
    let setupEpoch: String
    let ownerDeviceID: String
    let scopeDigest: String
    let mcpURL: String
    /// W183 R7a：卡上選的範圍（等級、專案）。nil＝沒帶（舊版擁有者：照主機目前的設定）。
    var choice: HandsScopeChoice? = nil

    init(intent: HandsConnectIntent, scopeDigest: String, choice: HandsScopeChoice? = nil) {
        attemptID = intent.attemptID.uuidString
        setupEpoch = intent.setupEpoch
        ownerDeviceID = intent.ownerDeviceID
        self.scopeDigest = scopeDigest
        mcpURL = intent.mcpURL
        self.choice = choice
    }

    init(attemptID: String, setupEpoch: String, ownerDeviceID: String, scopeDigest: String, mcpURL: String, choice: HandsScopeChoice? = nil) {
        self.attemptID = attemptID
        self.setupEpoch = setupEpoch
        self.ownerDeviceID = ownerDeviceID
        self.scopeDigest = scopeDigest
        self.mcpURL = mcpURL
        self.choice = choice
    }
}

/// 主機拒絕的原因（機器代碼；副設備收到再轉白話）。
enum HandsConnectRefusal: String, Error, CaseIterable, CustomStringConvertible {
    case busy = "connect_busy"
    case staleEpoch = "connect_epoch_stale"
    case scopeChanged = "connect_scope_changed"
    case notHost = "connect_not_host"
    case notReady = "connect_not_ready"
    case notOwner = "connect_not_owner"
    case unknownAttempt = "connect_unknown_attempt"
    case invalid = "connect_invalid"
    case finished = "connect_finished"
    /// W183 R6b 審查：還沒到可以確認的時候（沒有這個 attempt 的 grant、或它還沒有第一次 /mcp）。
    case notConfirmable = "connect_not_confirmable"
    /// W183 R7a：卡上選的範圍主機不收。W183 R10：主機一律不收卡上選的範圍（範圍只照 ChatGPT build 的中央設定）。
    case scopeInvalid = "connect_scope_invalid"
    /// W183 R7a：卡上選的範圍寫不進主機設定（磁碟滿？）：這次不開窗口。
    case scopeNotSaved = "connect_scope_not_saved"

    var description: String { rawValue }

    /// 白話（擁有者的私訊框卡片用）。
    var plain: String {
        switch self {
        case .busy: "主機上另一個連線正在進行（可能是另一台按的）；等它結束，或 10 分鐘後再按"
        case .staleEpoch: "主機的設定剛變了（取消、關掉或重開）；再看一次卡片再按"
        case .scopeChanged: "授權範圍剛改了；再看一次卡片再按"
        case .notHost: "這台主機現在不是 ChatGPT 手腳的主機"
        case .notReady: "主機的 ChatGPT 手腳還沒準備好（關口沒在跑或沒有網址）"
        case .notOwner: "這個連線不是這台按的"
        case .unknownAttempt: "主機不認得這次連線（可能重開過）；再按一次"
        case .invalid: "連線要求的內容不對"
        case .finished: "這次連線已經結束了"
        case .notConfirmable: "ChatGPT 還沒接上 TATWO 的工具，還不能確認"
        case .scopeInvalid: "主機不收卡上選的等級或專案（範圍照 ChatGPT build 的設定）；兩台都更新 TATWO OS 再按"
        case .scopeNotSaved: "主機的設定存不進去（磁碟滿？），這次沒有開始連線"
        }
    }
}

final class HandsConnectHost: @unchecked Sendable {
    /// 正式的主機（HandsService.shared）。第一次用到才接上 HandsAuth 的回呼。
    static let shared: HandsConnectHost = {
        let host = HandsConnectHost(service: .shared, epoch: { HandsSetup.shared.setupEpoch },
                                    localDeviceID: { (try? DeviceIdentityStore.readLocal())?.deviceID },
                                    hostName: { (try? DeviceIdentityStore.readLocal())?.name ?? "" },
                                    serviceRunning: {
                                        HandsSetup.onMainSync { () -> Bool in
                                            if case .running = ChatGPTHandsService.shared.phase { return true }
                                            return false
                                        }
                                    })
        host.attach()
        // W183 R7a：卡上選的範圍寫進主機設定後，主機的畫面（「詳細」的等級、專案）跟著變。
        host.onSettingsChanged = { DispatchQueue.main.async { MainActor.assumeIsolated { HandsState.shared.refresh() } } }
        return host
    }()

    /// W183 R6b 審查：配對窗口到期之後，還給授權碼兌換、第一次 /mcp、擁有者確認的時間（有碼或有 grant 才算）。
    static let completionGrace: TimeInterval = 180

    private final class Weak { weak var value: HandsConnectHost?; init(_ value: HandsConnectHost) { self.value = value } }
    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: Weak] = [:]

    /// 已經接上這個 HandsService 的主機（HandsService 回報 /mcp、/register 用；沒有＝沒有 attempt 在跑，不用回報）。
    static func attached(to service: HandsService) -> HandsConnectHost? {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[ObjectIdentifier(service)]?.value
    }

    /// 遠端 RPC 用：這個 HandsService 的主機（正式的就是 shared）。
    static func forService(_ service: HandsService) -> HandsConnectHost? {
        if let attached = attached(to: service) { return attached }
        return service === HandsService.shared ? shared : nil
    }

    private struct Attempt {
        let request: HandsConnectRequest
        let scope: HandsGrantScope
        let digest: String
        let expiresAt: Date
        var registered = false
        var grantID: String?
        /// 這個 grant 的第一次 /mcp 成功了（tools_ready；還要擁有者確認才算連上）。
        var mcpSeen = false
        /// 第一次對上的 evidence 與那一筆交易。
        var boundEvidence: String?
        var boundTransaction: String?
        var sawTransaction = false
        var terminal: HandsConnectStatus.State?
        var reason: String?
    }

    let service: HandsService
    private let epoch: () -> String?
    private let localDeviceID: () -> String?
    private let hostName: () -> String
    private let serviceRunning: () -> Bool
    /// 測試可換時鐘。
    var now: () -> Date = Date.init
    private let lock = NSRecursiveLock()
    private var current: Attempt?
    /// W183 R7a 審查：begin 與 cancel 排成一條隊（見檔頭）。順序：commitLock → 這個類別的鎖、HandsService 的發布鎖、主執行緒；
    /// 反過來不行（拿著那些的地方不叫 begin／cancel；主執行緒不叫——本機走背景執行緒、遠端在 os.sock 的處理線）。
    private let commitLock = NSLock()
    /// W183 R7a：卡上選的範圍寫進主機設定之後（正式：主機畫面重讀設定）。W183 R10：主機不再收卡上選的範圍，不會再叫（留著相容）。
    var onSettingsChanged: () -> Void = {}
    /// 結束了的 attempt（同 ID 再送 begin／查狀態回同一個終態，不重開）；也收「begin 之前就送到的取消」（墓碑）。只留最近幾個。
    private var finished: [(id: String, owner: String, status: HandsConnectStatus)] = []

    init(service: HandsService, epoch: @escaping () -> String?, localDeviceID: @escaping () -> String?,
         hostName: @escaping () -> String, serviceRunning: @escaping () -> Bool) {
        self.service = service
        self.epoch = epoch
        self.localDeviceID = localDeviceID
        self.hostName = hostName
        self.serviceRunning = serviceRunning
    }

    /// 接上 HandsAuth（這個 attempt 的授權碼換到 grant）並登記（HandsService 回報 /mcp 找得到）。
    func attach() {
        service.auth.onAttemptGrant = { [weak self] attempt, grant in self?.noteGrant(attempt: attempt, grant: grant) }
        Self.registryLock.lock()
        Self.registry[ObjectIdentifier(service)] = Weak(self)
        Self.registryLock.unlock()
    }

    /// W183 R6b 審查：在自己的鎖裡改狀態（取消與撤銷同一刻生效）；HandsAuth 的通知收在 after，放鎖之後才送
    /// （通知會進 HandsService 的發布鎖：不能在這把鎖裡等它，免得跟設定存檔互等）。
    private func locked<T>(_ body: (inout [() -> Void]) throws -> T) rethrows -> T {
        var after: [() -> Void] = []
        lock.lock()
        let result: T
        do {
            result = try body(&after)
        } catch {
            lock.unlock()
            after.forEach { $0() }
            throw error
        }
        lock.unlock()
        after.forEach { $0() }
        return result
    }

    /// 在鎖裡：這個 attempt 作廢（窗口、交易、未兌換的授權碼、它換到的 grant 一起撤銷）；通知放進 after。
    private func voidLocked(_ attemptID: String, reason: String, _ after: inout [() -> Void]) {
        let result = service.auth.cancelAttemptDeferred(attemptID, reason: reason)
        after.append(result.notify)
    }

    // MARK: - 給擁有者看的卡片內容

    /// 現在的 offer（主機、服務網址、範圍、callback、世代）。開關關著、不是主機、沒有網址、關口沒在跑＝拒絕。
    /// 會叫 grantScope（讀專案名稱要主執行緒）：不要在持有這個類別的鎖時叫。
    /// W183 R10：範圍照有效設定（中央設定的等級＋這台全部專案；HandsService.effectiveSettings）。includeChoices 留著相容，不再有作用
    ///（卡上不選範圍）。
    func offer(includeChoices: Bool = false) throws -> HandsConnectOffer {
        try offer(settings: service.effectiveSettings(), includeChoices: includeChoices)
    }

    /// 照這份設定拍的 offer。
    func offer(settings: HandsSettings, includeChoices: Bool = false) throws -> HandsConnectOffer {
        guard settings.enabled, service.deviceAllowed(settings) else { throw HandsConnectRefusal.notHost }
        guard let local = localDeviceID(), HandsHostAuthority.same(settings.hostDeviceID ?? local, local) else {
            throw HandsConnectRefusal.notHost
        }
        guard let publicHost = HandsGatewayLaunch.validHost(settings.publicHost), serviceRunning() else {
            throw HandsConnectRefusal.notReady
        }
        let callbacks = Array(Set(settings.effectiveCallbacks.compactMap { URLComponents(string: $0)?.host?.lowercased() })).sorted()
        // W183 R10：不給卡上選（supportsChoice 預設 false）：卡片只顯示中央設定的等級與「這台全部專案」。
        return HandsConnectOffer(hostDeviceID: local, hostName: hostName(), publicHost: publicHost, scope: service.grantScope(settings),
                                 callbackHosts: callbacks, setupEpoch: epoch() ?? "")
    }

    // MARK: - begin／cancel／status／confirm

    /// 擁有者按了［連線］：核對世代、範圍快照、網址，開一個綁這個 attempt 的 10 分鐘窗口。sender＝驗章得到的那台（本機＝自己）。
    func begin(_ request: HandsConnectRequest, sender: String) throws -> HandsConnectStatus {
        guard UUID(uuidString: request.attemptID) != nil, HandsHostAuthority.same(request.ownerDeviceID, sender),
              request.setupEpoch.utf8.count <= 64, request.scopeDigest.hasPrefix("sha256:"), request.scopeDigest.utf8.count <= 80 else {
            throw HandsConnectRefusal.invalid
        }
        // W183 R10：主機的範圍只照 ChatGPT build 的中央設定：帶了卡上選的範圍（本機或設備簽章的 begin_connect 的 level、project_ids）
        // ＝一律拒絕、什麼都不寫（取代 W183 R7a 的「驗過就寫進主機設定」）。新版擁有者不會帶（offer 不給卡上選）。
        guard request.choice == nil else { throw HandsConnectRefusal.scopeInvalid }
        // W183 R7a 審查：整個 begin 跟 cancel 排隊（核對與開窗口之間不會插進取消）。
        commitLock.lock(); defer { commitLock.unlock() }
        let offer = try self.offer()   // 鎖外算（讀專案名稱要主執行緒）
        let opened: (status: HandsConnectStatus, attemptID: String, deadline: Date) = try locked { after in
            expireLocked(&after)
            if let done = finished.first(where: { $0.id == request.attemptID }) {
                guard HandsHostAuthority.same(done.owner, sender) else { throw HandsConnectRefusal.notOwner }
                return (done.status, request.attemptID, .distantPast)   // 同 ID 的終態（或 begin 之前就收到的取消）：冪等，不重開
            }
            if let attempt = current, attempt.terminal == nil {
                guard attempt.request.attemptID == request.attemptID else { throw HandsConnectRefusal.busy }
                guard attempt.request == request else { throw HandsConnectRefusal.invalid }
                return (statusLocked(attempt, requester: sender, evidence: nil), request.attemptID, .distantPast)   // 同 ID：冪等
            }
            guard request.setupEpoch == offer.setupEpoch else { throw HandsConnectRefusal.staleEpoch }
            guard request.scopeDigest == offer.digest, request.mcpURL == offer.mcpURL else { throw HandsConnectRefusal.scopeChanged }
            guard let expires = service.auth.openAttemptWindow(attemptID: request.attemptID, scope: offer.scope) else {
                throw HandsConnectRefusal.finished
            }
            let attempt = Attempt(request: request, scope: offer.scope, digest: offer.digest, expiresAt: expires)
            current = attempt
            return (statusLocked(attempt, requester: sender, evidence: nil), request.attemptID, expires.addingTimeInterval(Self.completionGrace))
        }
        // 期限到了沒人問也會收（擁有者斷線、App 在背景）：不靠下一次查詢。
        if opened.deadline != .distantPast {
            let delay = max(opened.deadline.timeIntervalSince(now()), 0) + 1
            let id = opened.attemptID
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in self?.expireIfStale(id) }
        }
        return opened.status
    }

    /// 取消（擁有者按取消、意圖作廢、流程出錯）。已經成功＝不動它（只有一個終態）。回取消後（或原本）的狀態。
    /// W183 R6b 審查：取消與撤銷在同一把鎖裡（先撤銷、才公布「已取消」）；begin 還沒到就先收到的取消記成墓碑（晚到的 begin 不開窗口）。
    @discardableResult
    func cancel(attemptID: String, sender: String, reason: String) throws -> HandsConnectStatus {
        guard UUID(uuidString: attemptID) != nil else { throw HandsConnectRefusal.invalid }
        // W183 R7a 審查：跟 begin 排隊——正在寫設定、開窗口的 begin 做完才輪到取消（取消先到＝墓碑，之後的 begin 不寫設定）。
        commitLock.lock(); defer { commitLock.unlock() }
        return try locked { after in
            if let done = finished.first(where: { $0.id == attemptID }) {
                guard HandsHostAuthority.same(done.owner, sender) else { throw HandsConnectRefusal.notOwner }
                return done.status
            }
            guard var attempt = current, attempt.request.attemptID == attemptID else {
                // 墓碑：取消比 begin 先到（或 begin 根本沒到）。之後同 ID 的 begin 回這個終態、不開窗口。
                let status = HandsConnectStatus(attemptID: attemptID, state: .cancelled, reason: Self.cleanReason(reason), windowExpiresAt: nil,
                                                transaction: nil, registered: false)
                remember(attemptID, owner: sender, status: status)
                voidLocked(attemptID, reason: "cancelled_before_begin", &after)
                return status
            }
            guard HandsHostAuthority.same(attempt.request.ownerDeviceID, sender) else { throw HandsConnectRefusal.notOwner }
            if attempt.terminal == nil {
                attempt.terminal = .cancelled
                attempt.reason = Self.cleanReason(reason)
                current = attempt
            }
            if attempt.terminal != .connected { voidLocked(attemptID, reason: attempt.reason ?? "cancelled", &after) }
            return finishLocked(attempt)
        }
    }

    /// 擁有者查狀態。evidence＝擁有者的 Pod 看到的授權網址算出的雜湊（HandsAuth.evidenceHash）；第一次對上就綁住那一筆交易，
    /// 對不上＝終止（refused）。配對碼只在擁有者、而且這次帶的 evidence 就是綁住的那一組時給。
    func status(attemptID: String, sender: String, evidence: String?) throws -> HandsConnectStatus {
        // 範圍、世代有沒有變：鎖外先算好現在的 offer（讀專案名稱要主執行緒）。
        let offer = try? self.offer()
        return try locked { after in
            if let done = finished.first(where: { $0.id == attemptID }) {
                guard HandsHostAuthority.same(done.owner, sender) else { throw HandsConnectRefusal.notOwner }
                return done.status
            }
            guard var attempt = current, attempt.request.attemptID == attemptID else { throw HandsConnectRefusal.unknownAttempt }
            guard HandsHostAuthority.same(attempt.request.ownerDeviceID, sender) else { throw HandsConnectRefusal.notOwner }
            if attempt.terminal == nil {
                if let problem = validityProblem(attempt, offer: offer) {
                    attempt.terminal = problem == "expired" ? .expired : .cancelled
                    attempt.reason = problem
                } else if let evidence, !evidence.isEmpty {
                    // 擁有者的 Pod 看到授權頁：對上這個 attempt 的交易。
                    if let tx = service.auth.attemptTransaction(attemptID) {
                        if let bound = attempt.boundEvidence {
                            if !HandsAuth.constantTimeEqual(bound, evidence) || attempt.boundTransaction != tx.id {
                                attempt.terminal = .refused; attempt.reason = "transaction_mismatch"
                            }
                        } else if HandsAuth.constantTimeEqual(expectedEvidence(tx, attempt), evidence) {   // W183 R8c：第二版證據
                            attempt.boundEvidence = evidence
                            attempt.boundTransaction = tx.id
                        } else {
                            // 占著這個窗口的交易不是擁有者的 Pod 開的那一筆（攻擊者先占、別的授權網址）：終止、不給碼。
                            attempt.terminal = .refused; attempt.reason = "transaction_mismatch"
                        }
                    } else if let bound = attempt.boundEvidence, !HandsAuth.constantTimeEqual(bound, evidence) {
                        attempt.terminal = .refused; attempt.reason = "transaction_mismatch"
                    }
                }
                if attempt.terminal == nil, attempt.grantID == nil, attempt.sawTransaction || attempt.boundTransaction != nil,
                   service.auth.attemptTransaction(attemptID) == nil, !service.auth.attemptHasPendingCode(attemptID),
                   service.auth.attemptWindowExpiry(attemptID) == nil, service.auth.attemptGrantIDs(attemptID).isEmpty {
                    // 交易沒了、碼沒發、窗口也關了（錯滿 5 次、或窗口到期）：這一次失敗了。
                    attempt.terminal = .expired; attempt.reason = "pairing_failed"
                }
                if service.auth.attemptTransaction(attemptID) != nil { attempt.sawTransaction = true }
                current = attempt
            }
            guard attempt.terminal != nil else { return statusLocked(attempt, requester: sender, evidence: evidence) }
            if attempt.terminal != .connected { voidLocked(attemptID, reason: attempt.reason ?? "cancelled", &after) }
            return finishLocked(attempt)
        }
    }

    /// W183 R6b 審查（GPT-6）：擁有者核對過 Pod 帳號（同一個登入、同一個工作區）之後的確認。只有這一下會讓 attempt 變成「已連線」
    /// （這個 attempt 的 grant、它的第一次 /mcp 已經成功、世代範圍期限都還對）；grant 從暫時的轉正。之前一直可以撤銷。
    func confirm(attemptID: String, sender: String) throws -> HandsConnectStatus {
        let offer = try? self.offer()
        return try locked { after in
            if let done = finished.first(where: { $0.id == attemptID }) {
                guard HandsHostAuthority.same(done.owner, sender) else { throw HandsConnectRefusal.notOwner }
                return done.status
            }
            guard var attempt = current, attempt.request.attemptID == attemptID else { throw HandsConnectRefusal.unknownAttempt }
            guard HandsHostAuthority.same(attempt.request.ownerDeviceID, sender) else { throw HandsConnectRefusal.notOwner }
            if attempt.terminal == nil {
                if let problem = validityProblem(attempt, offer: offer) {
                    attempt.terminal = problem == "expired" ? .expired : .cancelled
                    attempt.reason = problem
                } else {
                    guard let grant = attempt.grantID, attempt.mcpSeen else { throw HandsConnectRefusal.notConfirmable }
                    if service.auth.completeAttemptGrant(grant) {
                        attempt.terminal = .connected
                        attempt.reason = nil
                    } else {
                        attempt.terminal = .cancelled
                        attempt.reason = "grant_not_saved"
                    }
                }
                current = attempt
            }
            if attempt.terminal != .connected { voidLocked(attemptID, reason: attempt.reason ?? "cancelled", &after) }
            return finishLocked(attempt)
        }
    }

    /// 授權流程的每個提交點之前（HandsService：authorize_begin、authorize_submit、token；設定一改也叫）：進行中的 attempt 範圍、
    /// 世代、期限還對嗎？不對＝取消（窗口、交易、授權碼、它的 grant 一起作廢），這一步就做不成。
    func validateBeforeAuthorize() {
        let offer = try? self.offer()
        locked { after in
            guard var attempt = current, attempt.terminal == nil, let problem = validityProblem(attempt, offer: offer) else { return }
            attempt.terminal = problem == "expired" ? .expired : .cancelled
            attempt.reason = problem
            current = attempt
            voidLocked(attempt.request.attemptID, reason: problem, &after)
            _ = finishLocked(attempt)
        }
    }

    /// W183 R6b 審查：這個 grant 要用 /mcp（hands_tools）之前：它是進行中 attempt 的 grant，而世代、範圍、期限不對了＝取消並撤銷、回 false。
    /// 不是進行中 attempt 的 grant＝不管（回 true，照一般的 token 檢查）。
    func admit(grantID: String) -> Bool {
        let relevant: Bool = locked { _ in current.map { $0.terminal == nil && $0.grantID == grantID } ?? false }
        guard relevant else { return true }
        let offer = try? self.offer()
        return locked { after in
            guard var attempt = current, attempt.terminal == nil, attempt.grantID == grantID else {
                return service.auth.grantRecord(grantID)?.isActive == true
            }
            guard let problem = validityProblem(attempt, offer: offer) else { return true }
            attempt.terminal = problem == "expired" ? .expired : .cancelled
            attempt.reason = problem
            current = attempt
            voidLocked(attempt.request.attemptID, reason: problem, &after)
            _ = finishLocked(attempt)
            return false
        }
    }

    // MARK: - 回報（HandsAuth、HandsService）

    /// 這個 attempt 的授權碼換到 grant。擁有者的 Pod 沒看過這一筆交易（沒有綁 evidence）、已經取消／終止、或世代範圍期限不對＝馬上撤銷。
    func noteGrant(attempt attemptID: String, grant: String) {
        let offer = try? self.offer()
        locked { after in
            guard var attempt = current, attempt.request.attemptID == attemptID else {
                let revoked = service.auth.revokeGrantDeferred(grant, reason: "connect_not_current")
                after.append(revoked.notify)
                return
            }
            if attempt.terminal != nil {
                let revoked = service.auth.revokeGrantDeferred(grant, reason: "connect_cancelled")
                after.append(revoked.notify)
                return
            }
            if attempt.boundEvidence == nil {
                attempt.terminal = .refused; attempt.reason = "grant_without_evidence"
            } else if let problem = validityProblem(attempt, offer: offer) {
                attempt.terminal = problem == "expired" ? .expired : .cancelled
                attempt.reason = problem
            } else {
                attempt.grantID = grant
            }
            current = attempt
            if attempt.terminal != nil {
                voidLocked(attemptID, reason: attempt.reason ?? "cancelled", &after)   // 這個 attempt 的 grant（就是這一個）一起撤銷
                _ = finishLocked(attempt)
            }
        }
    }

    /// 某個 grant 的工具清單（/mcp）成功：是這個 attempt 的 grant、還沒終止＝工具連上了（tools_ready；還要擁有者確認才是已連線）。
    func noteMCP(grantID: String) {
        locked { _ in
            guard var attempt = current, attempt.terminal == nil, attempt.grantID == grantID else { return }
            attempt.mcpSeen = true
            current = attempt
        }
    }

    /// /register（動態註冊）成功：窗口開著時記下來（只給「卡在哪段」的診斷）。
    func noteRegistered() {
        locked { _ in
            guard var attempt = current, attempt.terminal == nil else { return }
            attempt.registered = true
            current = attempt
        }
    }

    /// W183 R8c：這台算的配對頁證據（第二版）：這台的設備 id、交易核對過的 resource（沒有＝擁有者按下時的 MCP 網址）、它的 issuer、
    /// 這個 attempt 與它的世代。
    private func expectedEvidence(_ tx: HandsAttemptTransaction, _ attempt: Attempt) -> String {
        let resource = tx.resource ?? attempt.request.mcpURL
        let issuer = URL(string: resource)?.host.map { "https://" + $0.lowercased() } ?? ""
        return HandsAuth.boundEvidence(tx.evidenceHash, target: localDeviceID() ?? "", issuer: issuer, resource: resource,
                                       attempt: attempt.request.attemptID, setupEpoch: attempt.request.setupEpoch)
    }

    /// 自測與畫面：現在的 attempt id（沒有＝nil）。
    var currentAttemptID: String? {
        lock.lock(); defer { lock.unlock() }
        guard let current, current.terminal == nil else { return nil }
        return current.request.attemptID
    }

    // MARK: - 內部

    /// 這個 attempt 的最後期限：配對窗口的期限；已經有授權碼或 grant（等兌換、等第一次 /mcp、等擁有者確認）再多給一點。
    private func deadline(_ attempt: Attempt) -> Date {
        let finishing = attempt.grantID != nil || service.auth.attemptHasPendingCode(attempt.request.attemptID)
        return attempt.expiresAt.addingTimeInterval(finishing ? Self.completionGrace : 0)
    }

    private func validityProblem(_ attempt: Attempt, offer: HandsConnectOffer?) -> String? {
        if now() >= deadline(attempt) { return "expired" }
        guard let offer else { return "host_not_ready" }
        if offer.setupEpoch != attempt.request.setupEpoch { return "epoch_changed" }
        if offer.digest != attempt.digest || offer.mcpURL != attempt.request.mcpURL { return "scope_changed" }
        // 窗口被別的東西換掉（手動開始配對、關開關）：這個 attempt 沒了。
        if attempt.grantID == nil, service.auth.attemptWindowExpiry(attempt.request.attemptID) == nil,
           service.auth.attemptTransaction(attempt.request.attemptID) == nil, !service.auth.attemptHasPendingCode(attempt.request.attemptID),
           service.auth.attemptGrantIDs(attempt.request.attemptID).isEmpty, !attempt.sawTransaction, attempt.boundTransaction == nil {
            return "window_closed"
        }
        return nil
    }

    /// 過了最後期限的 attempt（不管有沒有 grant）：到期、作廢、撤銷。
    private func expireLocked(_ after: inout [() -> Void]) {
        guard var attempt = current, attempt.terminal == nil, now() >= deadline(attempt) else { return }
        attempt.terminal = .expired
        attempt.reason = "expired"
        current = attempt
        voidLocked(attempt.request.attemptID, reason: "expired", &after)
        _ = finishLocked(attempt)
    }

    /// begin 時排的計時：期限到了還在＝到期（擁有者斷線、沒人來查也收）。
    func expireIfStale(_ attemptID: String) {
        locked { after in
            guard current?.request.attemptID == attemptID else { return }
            expireLocked(&after)
        }
    }

    private func remember(_ id: String, owner: String, status: HandsConnectStatus) {
        guard !finished.contains(where: { $0.id == id }) else { return }
        finished.append((id, owner, status))
        if finished.count > 64 { finished.removeFirst(finished.count - 64) }
    }

    /// 終止的 attempt 搬進 finished（冪等）。回它的終態狀態。
    @discardableResult
    private func finishLocked(_ attempt: Attempt) -> HandsConnectStatus {
        var status = HandsConnectStatus(attemptID: attempt.request.attemptID, state: attempt.terminal ?? .cancelled, reason: attempt.reason,
                                        windowExpiresAt: nil, transaction: nil, registered: attempt.registered)
        // W183 R11（GPT-6 R11 審查 4）：連上了＝帶這一筆的代號（只回給擁有者：finished 照舊核 owner）。
        if status.state == .connected, let grant = attempt.grantID {
            status.grantTag = HandsBuildDeviceReport.grantTag(grant)
            status.grantVersion = service.auth.stateVersion   // W183 R11 最後一輪：確認（轉正存好）之後的版本
        }
        remember(attempt.request.attemptID, owner: attempt.request.ownerDeviceID, status: status)
        if current?.request.attemptID == attempt.request.attemptID { current = nil }
        return finished.first(where: { $0.id == attempt.request.attemptID })?.status ?? status
    }

    private func statusLocked(_ attempt: Attempt, requester: String, evidence: String?) -> HandsConnectStatus {
        let id = attempt.request.attemptID
        let isOwner = HandsHostAuthority.same(attempt.request.ownerDeviceID, requester)
        var state: HandsConnectStatus.State = .open
        var transaction: HandsConnectStatus.Transaction?
        if attempt.grantID != nil || !service.auth.attemptGrantIDs(id).isEmpty {
            state = attempt.mcpSeen ? .toolsReady : .granted
        } else if let tx = service.auth.attemptTransaction(id) {
            state = .pending
            let bound = attempt.boundTransaction == tx.id && attempt.boundEvidence != nil
            let showCode = isOwner && bound && evidence.map { HandsAuth.constantTimeEqual($0, attempt.boundEvidence ?? "") } == true
            transaction = .init(displayCode: tx.displayCode, expiresAt: tx.expiresAt, attemptsLeft: tx.attemptsLeft, callbackHost: tx.callbackHost,
                                evidenceBound: bound, pairingCode: showCode ? tx.pairingCode : nil)
        } else if service.auth.attemptHasPendingCode(id) {
            state = .authorized
        }
        return HandsConnectStatus(attemptID: id, state: state, reason: nil, windowExpiresAt: service.auth.attemptWindowExpiry(id),
                                  transaction: transaction, registered: attempt.registered)
    }

    static func cleanReason(_ raw: String) -> String {
        let allowed = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return allowed.isEmpty ? "cancelled" : String(allowed.prefix(40))
    }
}

// MARK: - 設備簽章 RPC（remote_hands_action 的 connect_*；HandsRemote 驗完章之後交進來）

enum HandsConnectRemote {
    /// connect_offer（看卡片內容）、begin_connect（按［連線］）、connect_status（擁有者查狀態與碼）、cancel_connect（取消）、
    /// connect_confirm（W183 R6b 審查：擁有者核對過 Pod 帳號後確認；只有這一下會變成已連線）。
    static let ops: Set<String> = ["connect_offer", "begin_connect", "connect_status", "cancel_connect", "connect_confirm"]
    /// 舊的裸 start_pairing（開一個不綁任何人的窗口、碼放在所有設備都輪詢得到的狀態裡）：副設備一律不收。
    static let startPairingRetired = "start_pairing_retired"
    /// W183 R6b 審查：舊的 stop_pairing 碰到綁連線意圖的窗口（不是它能關的）。
    static let stopPairingAttempt = "stop_pairing_attempt"
    static let expiredReason = HandsRemote.expiredReason

    static let allowedKeys: [String: Set<String>] = [
        "connect_offer": ["op", "expires_at"],
        "begin_connect": ["op", "expires_at", "attempt_id", "setup_epoch", "owner_device_id", "scope_digest", "mcp_url",
                          "level", "project_ids"],   // W183 R7a：卡上選的範圍
        "connect_status": ["op", "expires_at", "attempt_id", "evidence"],
        "cancel_connect": ["op", "expires_at", "attempt_id", "reason"],
        "connect_confirm": ["op", "expires_at", "attempt_id"],
    ]

    static func handle(_ op: String, payload: [String: Any], sender: String, host: HandsRemote.Host, now: Date = Date()) throws -> [String: Any] {
        guard let allowed = allowedKeys[op], Set(payload.keys).isSubset(of: allowed) else { throw HandsRemote.Failure.invalid("unexpected field") }
        // 簽章涵蓋的有效期限（延遲送達的舊請求不收；跟設定動作同一條規則）。
        guard let expires = (payload["expires_at"] as? NSNumber)?.doubleValue,
              expires > now.timeIntervalSince1970, expires <= now.timeIntervalSince1970 + HandsRemote.maxAhead else {
            throw HandsRemote.Failure.invalid(expiredReason)
        }
        guard let connect = HandsConnectHost.forService(host.service) else { throw HandsRemote.Failure.invalid(HandsConnectRefusal.notHost.rawValue) }
        do {
            switch op {
            case "connect_offer":
                var out = try connect.offer(includeChoices: true).wire   // W183 R7a：卡片要可以選的專案
                out["done"] = op
                return out
            case "begin_connect":
                guard let attempt = payload["attempt_id"] as? String, let epoch = payload["setup_epoch"] as? String,
                      let owner = payload["owner_device_id"] as? String, let digest = payload["scope_digest"] as? String,
                      let url = payload["mcp_url"] as? String, url.utf8.count <= 300 else { throw HandsConnectRefusal.invalid }
                // 擁有者＝驗章得到的那台（payload 不能替別台申請）。
                guard HandsHostAuthority.same(owner, sender) else { throw HandsConnectRefusal.notOwner }
                let choice = try HandsScopeChoice.fromWire(payload)   // W183 R7a：卡上選的範圍（沒帶＝照主機目前的設定）
                let request = HandsConnectRequest(attemptID: attempt, setupEpoch: epoch, ownerDeviceID: sender, scopeDigest: digest, mcpURL: url,
                                                  choice: choice)
                var out = try connect.begin(request, sender: sender).wire
                out["done"] = op
                return out
            case "connect_status":
                guard let attempt = payload["attempt_id"] as? String, UUID(uuidString: attempt) != nil else { throw HandsConnectRefusal.invalid }
                let evidence = (payload["evidence"] as? String).flatMap { $0.hasPrefix("sha256:") && $0.utf8.count <= 80 ? $0 : nil }
                var out = try connect.status(attemptID: attempt, sender: sender, evidence: evidence).wire
                out["done"] = op
                return out
            case "connect_confirm":
                guard let attempt = payload["attempt_id"] as? String, UUID(uuidString: attempt) != nil else { throw HandsConnectRefusal.invalid }
                var out = try connect.confirm(attemptID: attempt, sender: sender).wire
                out["done"] = op
                return out
            default:   // cancel_connect
                guard let attempt = payload["attempt_id"] as? String, UUID(uuidString: attempt) != nil else { throw HandsConnectRefusal.invalid }
                let reason = HandsConnectHost.cleanReason(payload["reason"] as? String ?? "cancelled")
                var out = try connect.cancel(attemptID: attempt, sender: sender, reason: reason).wire
                out["done"] = op
                return out
            }
        } catch let refusal as HandsConnectRefusal {
            throw HandsRemote.Failure.invalid(refusal.rawValue)
        }
    }
}
