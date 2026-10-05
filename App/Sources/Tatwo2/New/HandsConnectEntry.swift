import AppKit
import Combine
import SwiftUI

// W183 R11（使用者 09-30：「全程使用者應該只按一兩個按鍵 不勾選、不研究，就是一個很簡單的串接，關鍵是 ui要簡單好懂而不是砸文字做解釋」；
// 主導 09-30 用 Computer Use 實測 .031 之後 A、D：私訊框 ChatGPT 對象、＋ › 外掛程式都找不到「連線」，入口只在主視窗 ChatGPT 分頁右上一顆
// 小圖示，「一般人看不出是入口」）：
// - 使用者會去的三個地方各一個一眼看懂的入口（圖示＋「連線」兩個字、一顆鈕）：私訊框 ChatGPT 對象的頂列下面（HandsConnectDMLayer）、
//   「＋ › 外掛程式」那一頁的第一列（ChatGPTQuickMenu.plusSections，私訊框與 ChatGPT Space 同一份）與 ChatGPT Space 的「外掛」頁、
//   ChatGPT Space 的對話上方（還沒登入 ChatGPT 的那一頁也有）。主視窗右上那顆小圖示照舊（不是唯一入口了）。
// - W199（10-03）：常駐入口只在需要動手時出一行。健康、短暫自動核對安靜；外掛選單、設定與 hands_setup_status 仍可查連線。
// - 按「連線」＝ChatGPT build 的［連線］（HandsBuildController.connect：勾的每台逐台排；同一張確認卡，按連線＝同意）。還沒登入 ChatGPT：
//   同一顆鈕——按了［連線］之後框裡是 ChatGPT 的登入頁，登入好自動接著連（HandsConnectFlow.waitForLogin）。
//   ChatGPT build 開了、網址還沒好＝到 設定 › Plugin › TAP › ChatGPT build（Cloudflare 那幾步在那裡）；沒開＝不出入口（照舊在 TAP 打開）。
// - 副設備（例如 MacBook，引擎停用）一樣：按「連線」＝在這台自己的 ChatGPT 空間（Pod）建連接器、ChatGPT 的 MCP 連到勾的那台（通常是主設備）；
//   主設備不用登入 ChatGPT（連接器是 ChatGPT 帳號層級的，建在按的那台登入的帳號裡）。

/// 入口的狀態（純資料，好測）。
enum HandsConnectEntryState: Equatable, Sendable {
    /// ChatGPT build 沒開、沒勾設備：入口不出來（照舊在 設定 › Plugin › TAP › ChatGPT build 打開）。
    case hidden
    /// 開了、但勾的設備網址還沒好（Cloudflare 那幾步）：按了到 設定 › Plugin › TAP › ChatGPT build。
    case setup
    /// 可以連：按了＝［連線］卡。W183 R11 第二輪（GPT-6 R11 審查 4）：主機上有別的帳號的連線、或核對不了目前帳號，也是這個。
    case connect
    /// 連線中（卡片在跑）。
    case connecting
    /// 目前這個 ChatGPT 帳號在勾的每一台都連上了（核對過：那台回報裡有這個帳號的那一條；或剛連上、回報還沒跟上）。
    /// 等級＝ChatGPT 實際拿到的（多台取最小；nil＝能力未確認：舊版主機沒有逐筆證據）。
    case connected(hosts: [String], level: Int?)
    /// Only these hosts are proven for the current account; other hosts remain unconfirmed.
    case partial(hosts: [String], level: Int?, text: String)

    /// 手動開啟的外掛選單與 AI 狀態文字；W199 不拿健康狀態當常駐提示。
    var word: String {
        switch self {
        case .hidden: ""
        case .setup, .connect: "連線"
        case .connecting: "連線中"
        case .connected(_, let level): "已連線・" + (level.map { HandsConnectAbility.words(level: $0) } ?? Self.unconfirmedWord)
        case .partial(_, _, let text): text
        }
    }

    static let unconfirmedWord = "能力未確認"

    var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .partial: "checkmark.circle"
        default: "link"
        }
    }

    /// 滑過的提示（整句只在這裡）。
    var help: String {
        switch self {
        case .hidden: ""
        case .setup: "ChatGPT build 的網址還沒好：到 設定 › Plugin › TAP › ChatGPT build 做完 Cloudflare 那幾步"
        case .connect: "讓 ChatGPT 用這台的 Codex 和記憶（按一下＝連線卡；沒登入 ChatGPT 會先在框裡登入一次）"
        case .connecting: "正在連：看私訊框"
        case .connected: "按一下看連線；要停就按「斷線」"
        case .partial: "部分設備已連線；按一下查看能用的連線，其他設備的原因見設定"
        }
    }

    /// 給 hands_setup_status（OS 內的 AI）的代碼。
    var code: String {
        switch self {
        case .hidden: "off"
        case .setup: "setup_needed"
        case .connect: "not_connected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .partial: "partially_connected"
        }
    }

    /// 照 ChatGPT build 的中央設定、這台連線流程的當下、與每台的判定（HandsConnectVerdict：目前這個帳號的那一條在不在）算。
    /// W183 R11 第二輪（GPT-6 R11 審查 3、4）：「已連線」只算目前這個帳號核對過的（主機有別的帳號的連線不算）；剛連上的樂觀只到期限或新的回報。
    static func resolve(enabled: Bool, devices: [HandsBuildDevice], cloudflare: HandsBuildNodeState, phase: HandsConnectionPhase,
                        reason: (String) -> String = { _ in "連線未確認" },
                        verdict: (String) -> HandsConnectVerdict) -> HandsConnectEntryState {
        let selected = devices.filter(\.selected)
        guard enabled, !selected.isEmpty else { return .hidden }
        switch phase {
        case .waitingUser, .creatingConnector, .waitingPairing, .verifying: return .connecting
        default: break
        }
        var levels: [Int?] = []
        var connected: [HandsBuildDevice] = []
        for device in selected {
            guard case .connected(let level) = verdict(device.id) else { continue }
            connected.append(device)
            levels.append(level)
        }
        guard !connected.isEmpty else { return cloudflare == .done ? .connect : .setup }
        let known = levels.compactMap { $0 }
        if connected.count != selected.count {
            let ids = Set(connected.map(\.id))
            let text = "已連線：" + connected.map(\.name).joined(separator: "、") + "｜"
                + selected.filter { !ids.contains($0.id) }.map { "\($0.name)：\(reason($0.id))" }.joined(separator: "｜")
            return .partial(hosts: connected.map { $0.id.lowercased() }, level: known.count == levels.count ? known.min() : nil, text: text)
        }
        return .connected(hosts: selected.map { $0.id.lowercased() }, level: known.count == levels.count ? known.min() : nil)
    }
}

/// W199：顯示與授權判定分開；背景核對只走既有同步，不建立連接器或擴權。
struct HandsConnectionNotice {
    private(set) var text: String?
    private var missing: [String] = []
    private var attempts = 0
    private var nextCheck: TimeInterval = 0
    var checkAt: TimeInterval? { missing.isEmpty ? nil : nextCheck }
    var userInitiated = false
    private(set) var dismissed: [String: String] = [:]
    private var currentReasons: [String: String] = [:]
    init(dismissed: [String: String] = [:]) { self.dismissed = dismissed }

    static func fingerprint(identityTag: String, grantTag: String?) -> String {
        HandsAuth.sha256Hex(Data((identityTag + ":" + (grantTag ?? "") + ":revoked").utf8))
    }

    mutating func dismiss() {
        guard text != nil else { return }
        for (host, reason) in currentReasons { dismissed[host] = reason }
        text = nil
    }

    /// Missing reports and legacy reports cannot prove an account needs reconnecting.
    static func actionable(evidence: HandsConnectHostEvidence?, verdict: HandsConnectVerdict, hasAccountRecord: Bool) -> Bool {
        guard let evidence, evidence.fresh, evidence.serving, !evidence.clockSuspect, evidence.grantLevels != nil else { return false }
        switch verdict {
        case .ended(.revoked): return hasAccountRecord
        case .open: return false
        default: return false
        }
    }

    mutating func update(_ state: HandsConnectEntryState, devices: [HandsBuildDevice], uptime: TimeInterval,
                         actionableHosts: Set<String> = [], reasonKeys: [String: String] = [:],
                         recheck: ([String]) -> Void) {
        // A confirmed recovery resets dismissal; absence/staleness of evidence does not.
        let connected: [String]
        switch state {
        case .connected(let hosts, _), .partial(let hosts, _, _): connected = hosts
        default: connected = []
        }
        for host in connected { dismissed[host] = nil }
        currentReasons = Dictionary(uniqueKeysWithValues: actionableHosts.map { ($0, reasonKeys[$0] ?? "revoked") })
        let visibleHosts = actionableHosts.filter { dismissed[$0] != currentReasons[$0] }
        func prompt(_ hosts: [HandsBuildDevice]) -> String? {
            let names = hosts.filter { visibleHosts.contains($0.id.lowercased()) }.map(\.name)
            return names.isEmpty ? nil : names.joined(separator: "、") + " 的連線被撤銷了：按一下重新連線"
        }
        if state == .connecting {
            text = nil
            return
        }
        if state != .connect && state != .setup { userInitiated = false }
        switch state {
        case .setup, .connect: text = prompt(devices.filter(\.selected))
        case .partial(let hosts, _, _):
            let unresolved = devices.filter { $0.selected && !hosts.contains($0.id.lowercased()) }
            let ids = unresolved.map { $0.id.lowercased() }.sorted()
            if missing != ids { missing = ids; attempts = 0; nextCheck = uptime; text = nil }
            let actionable = unresolved.filter { visibleHosts.contains($0.id.lowercased()) }
            text = attempts >= 3 && !actionable.isEmpty ? prompt(actionable) : nil
            if uptime >= nextCheck {
                // 前三輪安靜等待新回報；其後仍核對，恢復時提示自動消失。
                attempts += 1
                nextCheck = uptime + (attempts <= 3 ? 5 : 60)
                recheck(ids)
            }
            return
        default: text = nil
        }
        missing = []; attempts = 0; nextCheck = 0
    }
}

/// 給 hands_setup_status 的那一份（不在主執行緒也能讀）。沒有帳號、沒有 token。
struct HandsConnectEntryStatus: Equatable, Sendable {
    var state = "unknown"
    var text = ""
    var abilities: [String] = []
    var level: Int?
    /// W183 R11 第二輪（GPT-6 R11 審查 5）：已連線時 ChatGPT 拿到的能力有沒有證據（confirmed；舊版主機＝unconfirmed）。
    var capability: String?
    /// W183 R11 第二輪（GPT-6 R11 審查 4）：勾的主機上有沒有確認過的連線（任何帳號）——跟「目前這個帳號已連線」（state）分開。
    var hostAuthorized = false
}

/// W183 R11 最後一輪（GPT-6 R11c 審查 3，中：「Flow 的晚到身分仍可跨登入世代覆蓋 B」）：Pod 這一次登入的世代——入口與連線流程共用
/// 一份。登出、停用、起不來＝換一代；睡著、醒來、起來中不換（帳號不會變）。所有讀到的帳號身分都帶著「讀之前」的世代：跟現在的不一樣＝
/// 晚到的舊結果（不當成目前帳號，只當成「請重新查一次」）。
@MainActor
final class HandsPodLogin {
    static let shared = HandsPodLogin(state: ChatGPTConnectorPod.shared.tap.$connection.eraseToAnyPublisher())

    private(set) var generation = 0
    /// Pod 最後的狀態（還沒收到＝nil）。
    private(set) var connection: TapConnection?
    /// 世代、狀態更新好之後才送（收到的人讀 generation 一定是新的）。
    let changes = PassthroughSubject<TapConnection, Never>()
    private var watch: AnyCancellable?

    init(state: AnyPublisher<TapConnection, Never>) {
        watch = state.sink { [weak self] connection in
            guard let self else { return }
            if !HandsConnectEntry.signedIn(connection) { self.generation += 1 }
            self.connection = connection
            self.changes.send(connection)
        }
    }
}

/// 入口（三個地方共用一份狀態）。
@MainActor
final class HandsConnectEntry: ObservableObject {
    static let shared = HandsConnectEntry()

    /// 「＋ › 外掛程式」那一列的代號（兩邊的 pick 認這個）。
    nonisolated static let menuRowID = "tatwo.connect"
    /// 按下入口時等 Pod 回帳號身分最多多久（等不到＝核對不了＝給［連線］）。
    static let probeTimeout: TimeInterval = 3

    @Published private(set) var state: HandsConnectEntryState = .hidden
    @Published private(set) var availabilityText: String?
    @Published private(set) var noticeText: String?
    private static let dismissalKey = "tatwo.handsConnection.dismissedReasons"
    private var notice = HandsConnectionNotice(dismissed: UserDefaults.standard.dictionary(forKey: HandsConnectEntry.dismissalKey) as? [String: String] ?? [:])
    private var persistedDismissal: [String: String]? = nil
    private var recoveringConnection = false
    private var awaitingIdentity = false

    private let build: @MainActor () -> HandsBuildController
    private let flow: HandsConnectFlow
    private let now: () -> Date
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：這台的單調時鐘（「剛連上」的期限照它算）。
    private let uptime: () -> TimeInterval
    private let accounts: HandsConnectAccounts
    /// Pod 目前帳號的身分（正式＝ChatGPTConnectorPod.identity：登入編號、工作區、信箱；讀不到＝nil）。只拿來算雜湊。
    private let probeIdentity: @MainActor () async -> String?
    /// Pod 的狀態與登入世代（正式＝HandsPodLogin.shared，看 ChatGPTTap.connection）。登出、關掉＝目前帳號不知道。
    /// W183 R11 最後一輪：連線流程也用同一份（流程發布的帳號帶它讀之前的世代）。
    let login: HandsPodLogin
    /// 設定頁（TAP › ChatGPT）：正式＝ChatGPT Space 的「到 TAP 設定」（同主視窗右上那顆小圖示）。
    var openSetup: @MainActor () -> Void
    private var watches: Set<AnyCancellable> = []
    private var started = false
    private var refreshQueued = false
    /// 目前 Pod 帳號身分的雜湊（只在這台；登出、關掉＝nil＝核對不了）。
    private(set) var identityTag: String?
    private var probing = false
    /// W183 R11 第二輪（GPT-6 R11b 審查 3，中：「登出清掉身分後，晚到的 probe 會把 A 寫回來」）：Pod 這一次登入的世代——登出、停用、
    /// 起不來＝換一代：還在路上的身分查詢一律作廢（晚到的結果不採用），新的一代照常查。睡著、醒來不換代（帳號不會變）。
    /// W183 R11 最後一輪：世代改由 HandsPodLogin 管（連線流程與入口同一份）。
    var podGeneration: Int { login.generation }
    /// 每台的判定（最後一次算的）。
    private(set) var verdicts: [String: HandsConnectVerdict] = [:]
    /// 剛連上的樂觀到期時要重算一次（排了哪個時間；單調時鐘）。
    private var noticeRefresh: Task<Void, Never>?
    private var expiryDue: TimeInterval?

    /// 給 hands_setup_status（OS 內的 AI）：最後一次算的狀態。
    nonisolated static let published = HandsLocked(HandsConnectEntryStatus())

    init(build: @escaping @MainActor () -> HandsBuildController = { .shared }, flow: HandsConnectFlow? = nil, now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { HandsMonotonic.now() },
         openSetup: (@MainActor () -> Void)? = nil, accounts: HandsConnectAccounts = .shared,
         probeIdentity: (@MainActor () async -> String?)? = nil,
         login: HandsPodLogin? = nil) {
        self.build = build
        self.flow = flow ?? .shared
        self.now = now
        self.uptime = uptime
        self.openSetup = openSetup ?? { ChatGPTSpaceModel.shared.openTapSettings() }
        self.accounts = accounts
        self.probeIdentity = probeIdentity ?? { await ChatGPTConnectorPod.shared.identity() }
        self.login = login ?? .shared
        start()
    }

    /// 開始看（ChatGPT build 的回報、這台的連線流程、Pod 登入了沒）；只做一次。
    func start() {
        guard !started else { return }
        started = true
        let controller = build()
        controller.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }.store(in: &watches)
        flow.$phase.sink { [weak self] _ in self?.queueRefresh() }.store(in: &watches)
        flow.$card.sink { [weak self] _ in self?.queueRefresh() }.store(in: &watches)
        // 連線流程讀到的 Pod 帳號（確認卡、連上的那一刻、中途登出）＝目前帳號。W183 R11 第二輪：Pod 已經登出＝晚到的帳號不收。
        // W183 R11 最後一輪（GPT-6 R11c 審查 3）：流程發布的帳號帶著它讀之前的登入世代——只收現在這一代的；別一代的（晚到的舊結果）
        // 不當成目前帳號，只當成「請重新查一次」（查到的才是現在的）。
        flow.$podIdentity.dropFirst().sink { [weak self] stamp in
            guard let self, let stamp else { return }
            guard stamp.generation == self.login.generation else {
                if self.login.connection.map(Self.signedIn) ?? false { self.probeSoon() }   // 登出中＝下一次登入好自己會查
                return
            }
            if let tag = stamp.tag {
                guard self.login.connection.map(Self.signedIn) ?? false else { return }
                self.identityTag = tag
            } else {
                self.identityTag = nil
            }
            self.queueRefresh()
        }.store(in: &watches)
        // Pod 登出、關掉＝目前帳號不知道（核對不了＝給［連線］），這一次登入的查詢全部作廢（世代由 HandsPodLogin 換）；登入好了＝讀一次帳號身分。
        if let connection = login.connection { podChanged(connection) }
        login.changes.sink { [weak self] connection in self?.podChanged(connection) }.store(in: &watches)
        refresh()
    }

    private func podChanged(_ connection: TapConnection) {
        switch connection {
        case .ready: probeSoon()
        case .needsLogin, .off, .failed:
            probing = false
            identityTag = nil
            queueRefresh()
        case .starting, .sleeping: queueRefresh()
        }
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    /// 讀一次 Pod 的帳號身分（背景；讀到＝核對用的雜湊）。讀不到（網頁一時沒回）＝不動：登出、關掉時上面已經清掉了
    ///（還在的那一個是同一個 Pod 這一次登入的帳號；Pod 睡著、醒來帳號不會變）。
    private func probeSoon() {
        guard !probing else { return }
        probing = true
        let probe = probeIdentity, generation = podGeneration
        Task { @MainActor [weak self] in
            let identity = await probe()
            // 查的時候登出、換過一次登入＝這個結果作廢（新的一代自己會再查）。
            guard let self, generation == self.podGeneration else { return }
            self.probing = false
            if let identity { self.identityTag = HandsConnectAccounts.identityTag(identity) }
            self.queueRefresh()
        }
    }

    /// Pod 這時候算登入著（睡著、醒來中也算：帳號不會變）。
    nonisolated static func signedIn(_ connection: TapConnection) -> Bool {
        switch connection {
        case .ready, .sleeping, .starting: true
        case .needsLogin, .off, .failed: false
        }
    }

    /// 按下入口的那一下：先核對目前帳號（最多等 probeTimeout）。讀到＝照讀到的（換了帳號＝不再算連著）；讀不到（Pod 睡著、網頁沒回）＝
    /// 照這個 Pod 這一次登入記下的那一個（登出、關掉時已經清掉：那時就是核對不了＝給［連線］）。
    private func probeNow() async {
        let probe = probeIdentity, generation = podGeneration
        let once = HandsBuildOnce()
        let timeout = Self.probeTimeout
        let result: String?? = await withCheckedContinuation { (continuation: CheckedContinuation<String??, Never>) in
            Task { @MainActor in
                let value = await probe()
                if once.claim() { continuation.resume(returning: .some(value)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: .none) }
            }
        }
        guard generation == podGeneration else { return }   // 等的時候登出、換過一次登入＝不採用
        if let identity = result ?? nil { identityTag = HandsConnectAccounts.identityTag(identity) }
    }

    /// 重算（畫面、hands_setup_status 都看這一份）。
    func refresh() {
        let controller = build()
        let records = accounts.records()
        let at = now(), up = uptime()
        let tag = identityTag
        var next: [String: HandsConnectVerdict] = [:]
        var hostAuthorized = false
        for device in controller.selectedDevices {
            let evidence = controller.connectEvidence(device.id)
            next[device.id.lowercased()] = HandsConnectVerdict.of(host: device.id, evidence: evidence, identityTag: tag, records: records,
                                                                 now: at, uptime: up)
            if let tag, next[device.id.lowercased()] == .ended(.revoked) || HandsConnectFlow.hostAuthorization(host: device.id, identityTag: tag, evidence: evidence, records: records) == false {
                flow.requireConnectorAuthorization(host: device.id, identityTags: [tag])
            }
            if let evidence, evidence.serving, evidence.confirmedGrants > 0 { hostAuthorized = true }
        }
        verdicts = next
        let resolved = HandsConnectEntryState.resolve(enabled: controller.enabled, devices: controller.devices, cloudflare: controller.cloudflareState,
                                                      phase: flow.phase, reason: { controller.connectionReason($0) },
                                                      verdict: { next[$0.lowercased()] ?? .open })
        if availabilityText != controller.localAvailabilityText { availabilityText = controller.localAvailabilityText }
        if resolved != state { state = resolved }
        // 網頁暫時失敗也先等重新就緒核對；登入／停用才直接交回使用者。授權 state 不因此變成已連線。
        awaitingIdentity = tag == nil && !records.isEmpty && (login.connection.map {
            switch $0 { case .ready, .sleeping, .starting, .failed: true; case .needsLogin, .off: false }
        } ?? false)
        let selectedIDs = Set(controller.selectedDevices.map { $0.id.lowercased() })
        recoveringConnection = (resolved == .connect || resolved == .setup) && tag != nil
            && records.contains { $0.identityTag == tag && selectedIDs.contains($0.host.lowercased()) }
            && !next.values.contains { if case .ended(.revoked) = $0 { return true }; return false }
        refreshNotice()
        Self.published.set(Self.status(resolved, hostAuthorized: hostAuthorized))
        updateConnectedCard(controller: controller, records: records, tag: tag, at: at, uptime: up)
        scheduleExpiry(records: records, tag: tag, uptime: up)
    }

    private func refreshNotice() {
        let controller = build()
        var displayState = state
        // 曾在目前帳號連上、主機重啟或回報過舊：先沿用自救核對，不閃回「連線」。撤銷仍直接交回使用者。
        if recoveringConnection {
            displayState = .partial(hosts: [], level: nil, text: "")
        } else if (state == .connect || state == .setup), awaitingIdentity {
            displayState = .connecting
        }
        let records = accounts.records()
        let tag = identityTag
        var reasonKeys: [String: String] = [:]
        let actionableHosts = Set(controller.selectedDevices.compactMap { device -> String? in
            guard let tag, HandsConnectionNotice.actionable(evidence: controller.connectEvidence(device.id),
                verdict: verdicts[device.id.lowercased()] ?? .open,
                hasAccountRecord: records.contains { $0.host.lowercased() == device.id.lowercased() && $0.identityTag == tag }) else { return nil }
            let host = device.id.lowercased()
            let record = records.last { $0.host.lowercased() == host && $0.identityTag == tag }
            reasonKeys[host] = HandsConnectionNotice.fingerprint(identityTag: tag, grantTag: record?.grantTag)
            return host
        })
        notice.update(displayState, devices: controller.devices, uptime: uptime(), actionableHosts: actionableHosts, reasonKeys: reasonKeys) { _ in
            controller.dependencies.sync.syncSoon(refreshView: true)
            self.probeSoon()
        }
        if noticeText != notice.text { noticeText = notice.text }
        persistDismissal()
        noticeRefresh?.cancel()
        noticeRefresh = nil
        var delay: TimeInterval?
        if case .partial = displayState, let next = notice.checkAt { delay = max(0.001, next - uptime()) }
        if !actionableHosts.isEmpty, let synced = controller.dependencies.sync.lastSync {
            let expiry = max(0.001, HandsBuildController.freshWindow - controller.dependencies.now().timeIntervalSince(synced) + 0.01)
            delay = min(delay ?? expiry, expiry)
        }
        if let delay {
            noticeRefresh = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.refreshNotice()
            }
        }
    }

    func dismissNotice() {
        notice.dismiss()
        noticeText = notice.text
        persistDismissal()
    }

    private func persistDismissal() {
        if persistedDismissal != notice.dismissed {
            UserDefaults.standard.set(notice.dismissed, forKey: Self.dismissalKey)
            persistedDismissal = notice.dismissed
        }
    }

    /// W183 R11（GPT-6 R11 審查 3）：已連線卡上的那幾台，新的回報說不在了（在別處撤銷、那台停了）或等級變了＝卡片跟著改。
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：推斷斷了的「已斷線」卡也照看——新的回報證明卡上那幾台都還連著（回報裡有這一條）＝卡片恢復。
    private func updateConnectedCard(controller: HandsBuildController, records: [HandsConnectAccountRecord], tag: String?, at: Date,
                                     uptime up: TimeInterval) {
        let shown = flow.watchedHostIDs
        guard !shown.isEmpty else { return }
        var ended: [String] = []
        var ending: HandsConnectVerdict.Ending?
        var levels: [Int?] = []
        var unconfirmed: [String] = []
        var proven: [String] = []
        for host in shown {
            let evidence = controller.connectEvidence(host)
            let verdict = verdicts[host] ?? HandsConnectVerdict.of(host: host, evidence: evidence, identityTag: tag, records: records,
                                                                  now: at, uptime: up)
            switch verdict {
            case .ended(let why):
                ended.append(host)
                if ending != .revoked { ending = why }
            case .connected(let level):
                levels.append(level)
                if HandsConnectVerdict.proves(host: host, evidence: evidence, identityTag: tag, records: records) { proven.append(host) }
            case .open:
                // W183 R11 第二輪（GPT-6 R11b 審查 4）：核對不了（期限過了、回報太舊、登出了）＝卡片改成「連線狀態未確認」、不寫能力。
                unconfirmed.append(host)
            }
        }
        var level = flow.connectedLevelValue
        if !levels.isEmpty {
            let known = levels.compactMap { $0 }
            level = known.count == levels.count ? known.min() : nil
        }
        flow.connectionChanged(ended: ended, ending: ending, level: level, unconfirmed: unconfirmed, connected: proven)
    }

    /// 剛連上的樂觀到期那一刻重算一次（沒有別的事也會重算：過了期限、回報還沒有這一條＝不再算連著）。
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：期限照單調時鐘（連上那一刻記的 uptime）。
    private func scheduleExpiry(records: [HandsConnectAccountRecord], tag: String?, uptime up: TimeInterval) {
        guard let tag else { return }
        let remaining = records.filter { $0.identityTag == tag }
            .compactMap { record in record.uptime.map { $0 + HandsConnectVerdict.optimism - up } }
            .filter { $0 > 0 && $0 <= HandsConnectVerdict.optimism }
        guard let soonest = remaining.min() else { return }
        let due = up + soonest
        guard expiryDue.map({ due < $0 || $0 <= up }) ?? true else { return }
        expiryDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + soonest + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.expiryDue = nil
                self?.refresh()
            }
        }
    }

    static func status(_ state: HandsConnectEntryState, hostAuthorized: Bool = false) -> HandsConnectEntryStatus {
        var status = HandsConnectEntryStatus(state: state.code, text: state.word)
        status.hostAuthorized = hostAuthorized
        switch state {
        case .connected(_, let level), .partial(_, let level, _):
            status.level = level
            status.abilities = level.map { HandsConnectAbility.of(level: $0).map(\.rawValue) } ?? []
            status.capability = level == nil ? "unconfirmed" : "confirmed"
        default: break
        }
        return status
    }

    /// 按了（三個地方同一個動作）。先核對目前帳號（登出、換帳號之後不照舊的算），再照狀態做。
    func tap() {
        HandsConnectLog.shared.write("entry.tap", "state=\(state.code) branch=probe")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.probeNow()
            self.refresh()
            self.notice.userInitiated = true
            self.act()
        }
    }

    private func act() {
        let branch: String
        if case .partial = state { branch = noticeText == nil ? "show_connected" : "connect_remaining" } else { branch = state.code }
        HandsConnectLog.shared.write("entry.act", "state=\(state.code) branch=\(branch)")
        switch state {
        case .hidden:
            return
        case .setup:
            openSetup()
        case .connect:
            // W183 R11 第二輪（GPT-6 R11 審查 4）：目前這個帳號還沒連上（或核對不了）的那幾台逐台排——那台有別的帳號的連線也照連。
            let controller = build()
            let selected = controller.selectedDevices.map { $0.id.lowercased() }
            let open = selected.filter { host in
                if case .connected? = verdicts[host] { return false }
                return true
            }
            controller.connect(deviceIDs: open.isEmpty ? selected : open)
        case .connecting:
            flow.offer()   // 正在連＝只把私訊框叫出來
        case .partial(let hosts, let level, _):
            if noticeText != nil {
                let open = build().selectedDevices.map { $0.id.lowercased() }.filter { !hosts.contains($0) }
                build().connect(deviceIDs: open)
            } else { flow.showConnected(hosts: hosts, level: level) }
        case .connected(let hosts, let level):
            flow.showConnected(hosts: hosts, level: level)
        }
    }

    /// 「＋ › 外掛程式」那一頁的第一列（沒開 ChatGPT build＝不列）。
    var menuRow: ChatGPTQuickMenuRow? {
        guard state != .hidden else { return nil }
        let detail: String
        switch state {
        case .connected, .partial: detail = "按了可以斷線"
        case .connecting: detail = "看私訊框"
        case .setup: detail = "先到設定把網址做好"
        default: detail = "讓 ChatGPT 用這台的 Codex 和記憶"
        }
        return ChatGPTQuickMenuRow(id: Self.menuRowID, symbol: state.symbol, title: state == .setup ? "連線 TATWO" : state.word,
                                  detail: availabilityText ?? detail)
    }

    /// W183 R11（主導 D）：給 hands_setup_status 的 connection（沒開始看＝unknown，並在主執行緒開始看）。
    /// W183 R11 第二輪（GPT-6 R11 審查 4、5）：state＝目前這個 ChatGPT 帳號（核對過的）；host_authorized＝主機上有沒有確認過的連線（任何帳號）；
    /// capability＝能力有沒有證據。沒有帳號、沒有代號、沒有 token。
    nonisolated static func aiStatus() -> [String: Any] {
        let status = published.get()
        if status.state == "unknown" {
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = HandsConnectEntry.shared } }
        }
        var out: [String: Any] = ["state": status.state, "text": status.text, "abilities": status.abilities,
                                  "host_authorized": status.hostAuthorized,
                                  "entry": "私訊框 ChatGPT 對象上方、＋ › 外掛程式、ChatGPT Space 的「連線」"]
        if let level = status.level { out["level"] = level }
        if let capability = status.capability { out["capability"] = capability }
        return out
    }
}

// MARK: - 膠囊（私訊框 ChatGPT 對象上方；ChatGPT Space 的對話上方、外掛頁、還沒登入的那一頁）

/// W199：需要動手時的一行提示；健康時連空白位置也不佔。
struct HandsConnectEntryPill: View {
    let text: String
    let help: String
    var identifier = "tatwo.dm.handsConnect.entry"
    var dismiss: (() -> Void)? = nil
    let action: () -> Void

    /// 離頂列下緣多遠。
    static let gap: CGFloat = 6
    static let height: CGFloat = 32

    /// 私訊框：對象是 ChatGPT、對話那一欄看得到、沒有別的東西浮在上面（連線的卡片、抽屜、模型面板、＋ 小卡、對象清單、直達鍵頁）。
    @MainActor
    static func shows(store: GlobalDMStore, cardShown: Bool) -> Bool {
        guard store.isEnabled, store.target == .chatGPT, store.chatGPTAvailable else { return false }
        if store.isBrowsing && !store.browsesBeside { return false }
        return !cardShown && !store.isPickerOpen && !store.isEditingDirectKeys && !store.isChatGPTDrawerOpen
            && !store.isChatGPTModelCardOpen && !store.isChatGPTPlusOpen
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text(text).lineLimit(1)
                }
                .font(.system(size: DMPhone.TextSize.footnote, weight: .medium))
                .frame(minHeight: Self.height)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .chatGlassChip()
            .help(help)
            .accessibilityLabel(text)
            .accessibilityHint(help)
            .accessibilityIdentifier(identifier)
            if let dismiss {
                Button("先不用", action: dismiss)
                    .font(.system(size: DMPhone.TextSize.footnote))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).frame(minHeight: Self.height)
                    .chatGlassChip()
                    .accessibilityIdentifier(identifier + ".dismiss")
            }
        }
    }
}

/// ChatGPT Space（主視窗）用的那一顆：看同一份狀態；沒開 ChatGPT build＝不出來、也不佔位置（留白只在出來的時候加）。
struct HandsConnectEntryButton: View {
    @ObservedObject var entry = HandsConnectEntry.shared
    var identifier = "chatgpt.handsConnect.entry"
    var alignment: Alignment = .center
    var insets = EdgeInsets()

    var body: some View {
        if let text = entry.noticeText {
            HandsConnectEntryPill(text: text, help: entry.state.help, identifier: identifier, dismiss: { entry.dismissNotice() }) { entry.tap() }
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(insets)
        }
    }
}
