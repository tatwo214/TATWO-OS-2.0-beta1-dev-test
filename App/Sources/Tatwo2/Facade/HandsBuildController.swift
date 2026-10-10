import Combine
import Foundation

// W183 R8c：ChatGPT build 的多設備後端給畫面（R8a）的實作（HandsBuildModeling；合併時主導把節點流程接到這裡）。
//
// - 讀：主設備給的全貌（HandsBuildSync.view：設定、每台的公共狀態、所有權）。每台的節點狀態看**那台的回報**（套用到哪一版、許可、關口、連線數）：
//   設定改了、那台還沒回報套用＝「進行中」，不寫「已關／已連線」（GPT-6：未收到回執不得顯示全部已關）。
//   W183 R8c 審查（GPT-6 中）：想要的（設定）、看到的（那台的回報）、確定套用的（回報的套用版本）分開——關掉之後那台還沒回報＝「關閉中」，
//   回報太舊（那台或這台連不到主設備）＝「離線、待套用」；新不新鮮也看這台自己的鐘（這台自己失聯時快取的回報不算新）。
// - 動作都是使用者在原生畫面按的（AI 工具走不到這裡）：改設定＝預期版本比對送主設備（還沒拿到設定＝不能改）；
//   「套用」一律經 HandsBuildExecutor（這台也一樣）：那台用自己已接受的那一份拍成不變的快照才建；登入、解除安全鎖、撤銷＝
//   這台本機直接做，別台＝經主設備的信箱交給那台（登入網址、配對碼只回到這台，在這台的私訊框開）；別台的解除安全鎖綁事故編號與 setupEpoch、
//   撤銷綁按的時候看到的那一組連線。
// - 「連全部」＝逐台排隊（同一個 Pod 一次只建一個連接器）：前一台結束（連上、失敗、取消）才開下一台。
// W183 R8 整合（主導把 R8a 的畫面接到這裡；R8a 的 HandsBuildModel 只經這個控制器）：
// - 別台的登入網址開在這台私訊框的 Browser 分頁（HandsSetup.openLoginPage → DMBrowser.open(purpose: .cloudflareLogin)）；
//   授權完成＝那個分頁標「完成」（R8b：頁面關掉、分頁留著）；其他結果（取消、失敗、結果未知）＝收掉。
// - 「套用」可以帶子網域草稿（R8a 的「帶看到的那一份」）：先照畫面看到的版本存（CAS；存不成就停），等勾選的每台拿到新的那一版才送套用。
// - 出錯的是哪一種、哪一台（problemInfo）：畫面決定哪個節點亮紅、給哪一顆鈕；problem 的字與順序照 R8c。
// - 「已連線」只算確認過的連線（R8a 審查：暫時的 grant 不算）：每台回報 confirmed_grants。
// W183 R8 整合審查（GPT-6 跨引擎＋Claude）：
// - 「套用」從按下去那一刻起帶著看到的那一份（主權＋設定版本＋勾了哪幾台：HandsBuildExpected）一路到送出；送出時不自己換版本，
//   有草稿＝用 CAS 回的那個確切版本，而且只送給已經回報拿到那一版的那台（沒回執＝不送）。
// - 解除安全鎖：這台與別台同一套核對（按的時候看到的事故編號、setupEpoch、撤銷世代）；這台的不叫不帶事故編號的 retry()。
// - ［連線］：卡片上按「取消」（HandsConnectFlow 發出「這一輪收掉了」）＝這一輪結束；流程沒真的開始（別的連線還在跑）＝不佔著。
// - 關掉的那台沒有回報＝不知道（待套用），不寫「已關閉」；有回報也要是「套用過這次關掉」（撤銷世代的回執）才算關。
// - 取消勾選、總開關關掉＝那台的套用／登入出錯紀錄收掉；出錯只看勾著的設備。
@MainActor
final class HandsBuildController: ObservableObject, HandsBuildModeling {
    static let shared = HandsBuildController(dependencies: .live())

    struct Dependencies {
        var sync: HandsBuildSync
        var flow: HandsConnectFlow
        var localID: () -> String?
        /// 已配對的設備（全貌還沒拿到時畫面先列這些）。
        var pairedDevices: () -> [HandsSetupDevice] = { HandsSetup.pairedDevices() }
        /// 這台登入 Cloudflare（環境登入同一份；登入只是登入）。
        var loginHere: () -> Void
        /// W183 R8 整合審查（GPT-6 中）：使用者在這台對這台按「解除安全鎖」——帶按的時候看到的事故編號、setupEpoch、撤銷世代，
        /// 跟信箱那條同一套核對（HandsBuildExecutor.unlockHere；最後經 unlockSafety(incident:)）。回 nil＝解除了，否則是拒絕的原因。
        var unlockHere: @Sendable (_ incident: String, _ setupEpoch: String?, _ revocationGeneration: Int) -> String?
        /// W183 R11 第二輪（GPT-6 R11b 審查 5）：撤銷的接線（這台本機、副設備→主設備 RPC）一律由 HandsRevocationWiring.standard 建——
        /// 正式（live）與自測同一個建構器，自測只換底下的 service 與傳輸，不另寫撤銷。沒有預設值（每個 controller 都要明講接哪裡）。
        var revocation: HandsRevocationWiring
        /// W183 R11：這台的角色（副設備要知道主設備是哪一台）。
        var role: () -> HandsBuildRole = { HandsBuildRole.current() }
        /// 在這台的私訊框開 Cloudflare 授權頁（別台的登入網址）；onCancel＝頁面上的取消。
        var openLogin: @MainActor (URL, @escaping @MainActor () -> Void) -> Void
        var closeLogin: @MainActor (URL) -> Void
        /// W183 R8 整合（R8b）：別台的登入完成＝這台私訊框 Browser 的那個授權分頁標「完成」（頁面關掉、分頁留著，使用者自己關）。
        var markLoginDone: @MainActor (URL) -> Void = { url in HandsSetup.postLoginPagesDone(only: url) }
        /// 背景做（簽章 RPC 會等網路；不在主執行緒等）。
        var background: (@escaping @Sendable () -> Void) -> Void = { work in DispatchQueue.global(qos: .userInitiated).async(execute: work) }
        var now: () -> Date = Date.init
        /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：這台的單調時鐘（跟全貌拿到那一刻比＝這台的牆上時鐘有沒有跳過）。
        var uptime: () -> TimeInterval = { HandsMonotonic.now() }

        static func live() -> Dependencies {
            Dependencies(
                sync: .shared, flow: .shared,
                localID: { HandsBuildRole.current().localID },
                loginHere: { HandsSetup.shared.login(trigger: .user) },
                unlockHere: { incident, epoch, generation in
                    HandsBuildSync.shared.dependencies.executor.unlockHere(incident: incident, setupEpoch: epoch, revocationGeneration: generation)
                },
                revocation: .live,
                openLogin: { url, cancel in _ = HandsSetup.openLoginPage(url, onCancel: cancel) },
                closeLogin: { url in HandsSetup.postCloseLoginPages(only: url) })
        }
    }

    /// 一台正在做的事（畫面轉圈、出錯的一句話）。
    enum Work: Equatable, Sendable {
        case idle
        case running(String)
        case failed(String)
        case done(String)
    }

    /// 回報多舊就不算新（兩輪同步）。
    static let freshWindow: TimeInterval = 45
    /// W183 R8 整合：「套用」帶子網域草稿時，存好之後最多等這麼久讓勾選的每台拿到新的那一版（再久＝那台沒開）。
    static let pickupWait: TimeInterval = 90

    let dependencies: Dependencies
    @Published private(set) var actionProblem: String?
    @Published private(set) var loginWork: [String: Work] = [:]
    @Published private(set) var applyWork: [String: Work] = [:]
    /// 「連全部」排隊中的（依序）。
    @Published private(set) var connectQueue: [String] = []
    @Published private(set) var connecting: String?
    private var cancellables: Set<AnyCancellable> = []
    /// 別台的登入：operationID → (那台, 開著的網址)。
    private var logins: [String: (device: String, url: URL?)] = [:]
    /// W183 R8c 審查（Claude 中）：這台的 id 與已配對設備只在全貌換了的時候讀一次（畫面計算裡不讀檔）。
    private var cachedLocalID: String?
    private var cachedPaired: [HandsSetupDevice] = []
    /// W183 R8 整合：存好子網域、等勾選的每台拿到這一版才送「套用」。W183 R8 整合審查（GPT-6 高）：CAS 回的那個確切版本（連主權）、
    /// 按的時候勾的那幾台、還沒送的、最晚等到——每台回報拿到這一版才送那一台；到期還沒拿到的不送（出錯：請它連上再按）。
    private struct PendingApply {
        let expected: HandsBuildExpected
        var remaining: [String]
        let deadline: Date
    }
    private var pendingApply: PendingApply?
    /// W183 R8 整合審查（Claude 中）：「套用」沒成是因為那台還沒登入那個 Cloudflare 帳號（出錯鈕＝替它登入，不是再套用一次）。
    @Published private(set) var applyNeedsLogin: Set<String> = []
    /// W183 R8 整合：上一次連線沒成的那台（出錯鈕「再連一次」連它）。
    @Published private(set) var failedConnect: String?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        refreshCaches(dependencies.sync.view)
        dependencies.sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        dependencies.sync.$view.sink { [weak self] view in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshCaches(view) } }
        }.store(in: &cancellables)
        dependencies.flow.$phase.sink { [weak self] phase in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.flowChanged(phase) } }
        }.store(in: &cancellables)
        // W183 R8 整合審查（GPT-6 中／Claude 高）：卡片上按了「取消」、卡片收起來＝這一輪結束（phase 回到「等你按」，不是 idle）。
        dependencies.flow.$closedByUser.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectRoundClosed() } }
        }.store(in: &cancellables)
        // Freshness and permit expiry also change when no new report arrives.
        // UI-only tick: no RPC, disk reads or changes to permission enforcement.
        Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.view.config != nil else { return }
            self.objectWillChange.send()
        }.store(in: &cancellables)
    }

    private func refreshCaches(_ view: HandsBuildView) {
        cachedLocalID = dependencies.localID()
        if view.devices.isEmpty {
            cachedPaired = dependencies.pairedDevices().map {
                HandsSetupDevice(id: $0.id.lowercased(), name: $0.name, isPrimary: $0.isPrimary, isThisDevice: $0.isThisDevice)
            }
        }
        pruneWork()
        checkPendingApply()
    }

    /// W183 R8 整合審查（Claude 中「套用／登入的失敗紀錄永遠不會清」）：沒勾（或總開關關了）的那台，已經結束的套用紀錄收掉；
    /// 沒勾的那台已經結束的登入紀錄也收掉（跑著的留著：結果回來照樣交）。
    private func pruneWork() {
        guard let config else { return }
        for (id, work) in applyWork where !config.isActive(id) {
            if case .running = work { continue }
            applyWork[id] = nil
            applyNeedsLogin.remove(id)
        }
        for (id, work) in loginWork where !(config.entry(id)?.selected ?? false) {
            if case .running = work { continue }
            loginWork[id] = nil
        }
    }

    /// 畫面打開了：一陣子內快一點同步（W183 R8c 審查：平常不熱問）。
    func viewDidAppear() {
        dependencies.sync.heatUp()
        dependencies.sync.syncSoon()
    }

    // MARK: - 讀

    var view: HandsBuildView { dependencies.sync.view }
    var config: HandsBuildConfig? { view.config }
    var localID: String? { cachedLocalID }

    var enabled: Bool { config?.enabled ?? false }

    func hasFreshReport(_ id: String) -> Bool { fresh(report(id)) }

    private func report(_ id: String) -> HandsBuildDeviceReport? { view.report(id) }

    /// 那台的回報夠新：主設備收到它的時間離主設備現在不到兩輪，而且這台自己最近也拿到過全貌（這台失聯時快取的不算新）。
    private func fresh(_ report: HandsBuildDeviceReport?) -> Bool {
        guard let received = report?.receivedAt, let server = view.serverTime, let synced = dependencies.sync.lastSync else { return false }
        return server.timeIntervalSince(received) <= Self.freshWindow && dependencies.now().timeIntervalSince(synced) <= Self.freshWindow
    }

    /// 那台已經套用到現在這一版了嗎（未收到回執＝沒有）。
    private func appliedCurrent(_ id: String) -> Bool {
        guard let config, let info = self.report(id), fresh(info) else { return false }
        return info.appliedConfigRevision >= config.configRevision
    }

    /// W183 R8 整合（畫面每台一格）：那台的網址已經是設定要的那一個、而且套用到現在這一版了。
    func urlReady(_ id: String) -> Bool { urlApplied(id) && appliedCurrent(id) }

    /// W183 R8 整合：那台有網址了（不管是不是現在設定要的；換網域要先確認）。
    func hasURL(_ id: String) -> Bool { report(id)?.publicHost != nil }

    /// W183 R8 整合：那台回報的有效連線（確認過的；舊版沒回報這個欄位＝0，不當已連線）。
    func confirmedGrants(_ id: String) -> Int { report(id)?.confirmedGrants ?? 0 }

    /// W183 R8 整合：那台回報的有效連線（含還在確認中的；撤銷看這個）。
    func grants(_ id: String) -> Int { report(id)?.grants ?? 0 }

    /// W183 R11：ChatGPT 在那台實際拿到的等級＝確認過的連線的等級 ∩ 那台實際生效的等級。
    /// W183 R11（GPT-6 R11 審查 5，中：「舊版回報缺少 grant 等級時，仍會錯報 Codex 能力」）：舊版沒回報連線等級＝nil（能力未確認）——
    /// 不拿中央設定的上限（實際生效的）當成 ChatGPT 已經拿到的。
    func connectedLevel(_ id: String) -> Int? {
        guard let actual = actualLevel(id), let granted = report(id)?.grantLevel else { return nil }
        return min(granted, actual)
    }

    /// W183 R11（GPT-6 R11 審查 3、4、5）：給入口的那台的證據（回報新不新、在不在服務、確認過的連線數、逐筆代號與等級、收到的時間換成這台的鐘）。
    /// 沒有帳號、沒有 token（帳號跟代號的對應只在這台的 HandsConnectAccounts）。沒回報＝nil。
    func connectEvidence(_ id: String) -> HandsConnectHostEvidence? {
        guard let info = self.report(id) else { return nil }
        let isFresh = fresh(info)
        let serving = isFresh && info.permit == "active" && info.phase == "running" && !info.safetyLocked
        var received: Date?
        // W183 R11 第二輪：用同一份全貌的那一對（主設備的時間、這台拿到的時間）換算；不拿別次同步的時間配這一份（內容沒變不重發時會差很多）。
        if let at = info.receivedAt, let server = view.serverTime, let local = view.localTime {
            received = local.addingTimeInterval(-server.timeIntervalSince(at))
        }
        // W183 R11 最後一輪（GPT-6 R11c 審查 4）：時鐘跳過＝這份回報新不新鮮算不準（一律「未確認」）：這台的牆上時鐘在拿到這一份之後跳過
        //（牆上走的跟單調時鐘差太多），或主設備的時鐘在上一份和這一份之間跳過（拿到時就標好了）。
        var clockSuspect = view.serverClockJumped
        if let local = view.localTime, let localUptime = view.localUptime {
            clockSuspect = clockSuspect || HandsBuildView.clockJumped(wall: dependencies.now().timeIntervalSince(local),
                                                                      monotonic: dependencies.uptime() - localUptime)
        }
        // 主設備的鐘在收到這份回報之後倒退過（出全貌的時間比收件還早，超過容忍）：新不新鮮算不準（fresh 會把負的年齡當成新的）。
        if let at = info.receivedAt, let server = view.serverTime, server.timeIntervalSince(at) < -HandsBuildView.clockTolerance {
            clockSuspect = true
        }
        return HandsConnectHostEvidence(fresh: isFresh, serving: serving, confirmedGrants: info.confirmedGrants ?? 0,
                                        grantLevels: info.grantLevels, receivedAt: received, actualLevel: actualLevel(id),
                                        grantsVersion: info.grantsVersion, clockSuspect: clockSuspect)
    }

    /// W183 R8 整合：那台回報安全停機鎖著。
    func safetyLocked(_ id: String) -> Bool { report(id)?.safetyLocked == true }

    /// W183 R8 整合：那台回報的一行狀態（關口的白話；沒有＝空）。
    func phaseText(_ id: String) -> String { fresh(report(id)) ? report(id)?.phaseText ?? "" : "" }

    /// The reason accompanies the node and its AX label, not just the overall pill.
    func connectionReason(_ id: String) -> String {
        let info = report(id)
        guard fresh(info) else {
            if info == nil { return "沒收到這台的回報" }
            let at = info?.receivedAt.map { received in
                if let server = view.serverTime, let local = view.localTime {
                    return local.addingTimeInterval(-server.timeIntervalSince(received))
                }
                return received
            }
            return "那台的 App 沒開或連不到（最後回報 \(at.map(ChatGPTHandsService.clockText) ?? "尚無")）"
        }
        guard appliedCurrent(id), urlApplied(id) else { return "等你按套用" }
        if let info, info.phase != "running" {
            return "關口沒在跑：\(info.phaseText.isEmpty ? "已停止" : info.phaseText)"
        }
        if info?.safetyLocked == true { return "關口為了安全已暫停" }
        if info?.permit != "active" { return "許可未生效" }
        return "等你按連線"
    }

    static func memberAvailability(permit: HandsBuildPermit.State?, primary: String, lastSync: Date?, now: Date) -> String? {
        guard let permit else { return nil }
        switch permit {
        case .paused("expired"):
            return "已暫停：主設備沒開"
        case .active(_, let expires?):
            if now >= expires { return "已暫停：主設備沒開" }
            guard lastSync.map({ now.timeIntervalSince($0) > freshWindow }) ?? true else { return nil }
            return "主設備（\(primary)）沒開或連不到；你這台的 ChatGPT 手腳會在 \(ChatGPTHandsService.clockText(expires)) 暫停"
        default:
            return nil
        }
    }

    var localAvailabilityText: String? {
        let availability = Self.memberAvailability(permit: dependencies.sync.memberPermit,
                                primary: (view.devices.isEmpty ? cachedPaired : view.devices).first(where: \.isPrimary)?.name ?? "主設備",
                                lastSync: dependencies.sync.lastSync, now: dependencies.now())
        if let availability, dependencies.sync.problem?.contains("主設備的遠端登入沒有回應") == true {
            return (availability.hasPrefix("已暫停") ? "已暫停：" : "") + "主設備的遠端登入沒有回應"
        }
        return availability
    }

    /// 那台現在用的網址就是設定要的那一個（期望＝已套用）。
    private func urlApplied(_ id: String) -> Bool {
        guard let wanted = config?.hostname(id), let host = self.report(id)?.publicHost else { return false }
        return wanted.caseInsensitiveCompare(host) == .orderedSame
    }

    /// 設定要這台關著（沒勾、或總開關關了）：那台確定關了嗎。那台最後一次回報還開著（許可有效、關口在跑、還有連線）＝還沒關：
    /// 回報夠新＝「關閉中」（等它套用、回報），回報太舊＝「離線、待套用」；最後一次回報已經停了＝關。
    /// W183 R8 整合審查（GPT-6 中「沒有設備回報時，UI 反而宣稱已關閉」）：
    /// - 沒有回報（主設備剛重開、那台還沒來同步）＝不知道＝待套用；只有「從來沒在 ChatGPT build 跑過」的證據（設定裡沒有那台、或撤銷世代還是 0
    ///   而且不是舊單主機遷移過來的那台）才算確定關著。
    /// - 有回報、看起來停了：還要是「套用過這一次關掉」（回報的撤銷世代 ≥ 設定裡那台的；舊版沒回報這個欄位＝要套用到現在這一版）才算關——
    ///   關掉之前的舊回報不算回執（那台可能在那之後才起來、還沒回報）。
    private func offState(_ id: String) -> HandsBuildNodeState {
        let entry = config?.entry(id)
        let generation = entry?.revocationGeneration ?? 0
        guard let info = self.report(id) else {
            let neverRan = entry == nil || (generation == 0 && !(config?.migratedFromLegacy == true && entry?.selected == true))
            return neverRan ? .off : .waiting
        }
        let stillOn = info.permit == "active" || info.phase == "running" || info.phase == "starting" || info.grants > 0
        let receipt = info.appliedGeneration.map { $0 >= generation } ?? (info.appliedConfigRevision >= (config?.configRevision ?? 0))
        guard stillOn || !receipt else { return .off }
        return fresh(info) ? .working : .waiting
    }

    var devices: [HandsBuildDevice] {
        let local = localID
        let known = view.devices.isEmpty ? cachedPaired : view.devices
        return known.map { device in
            let entry = config?.entry(device.id)
            let selected = entry?.selected ?? false
            let info = self.report(device.id)
            let running = info?.phase == "running" && fresh(info) && info?.permit == "active" && info?.safetyLocked != true
            var state: HandsBuildNodeState = .off
            if selected, enabled {
                if info?.permit == "paused" || info?.safetyLocked == true { state = .failed }
                else if !appliedCurrent(device.id) { state = fresh(info) ? .working : .waiting }
                else if info?.permit == "active" { state = running ? .done : .waiting }
                else { state = .waiting }
            } else {
                state = offState(device.id)
            }
            // W183 R8 整合（R8a 審查「暫時的 grant 不算已連線」）：確認過的才打勾；只有還在確認中的＝進行中。
            let connection: HandsBuildNodeState = connecting == device.id ? .working
                : (info?.confirmedGrants ?? 0) > 0 && running ? .done
                : (info?.grants ?? 0) > 0 && running ? .working : selected && enabled ? .waiting : .off
            let subdomain = entry?.subdomain ?? HandsBuildConfig.defaultSubdomain(
                name: device.name, deviceID: device.id, isPrimary: device.isPrimary, taken: Set(config?.devices.map(\.subdomain) ?? []))
            return HandsBuildDevice(id: device.id, name: device.name, isPrimary: device.isPrimary,
                                    isThisDevice: HandsHostAuthority.same(device.id, local), selected: selected, state: state,
                                    subdomain: subdomain, url: running ? info?.publicHost.map { "https://\($0)/mcp" } : nil,
                                    connection: connection)
        }
    }

    var selectedDevices: [HandsBuildDevice] { devices.filter(\.selected) }

    /// 設定要關、但還沒確定關掉的設備（沒回執、回報太舊）。
    private var pendingOff: [HandsBuildDevice] { devices.filter { !($0.selected && enabled) && $0.state != .off } }

    var zones: [HandsBuildZone] {
        var seen = Set<String>()
        var out: [HandsBuildZone] = []
        for report in view.reports {
            for account in report.accounts {
                for zone in account.zones where !zone.name.isEmpty && seen.insert(zone.zoneID).inserted {
                    out.append(HandsBuildZone(id: zone.zoneID, name: zone.name, accountName: account.name))
                }
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    var selectedZoneID: String? { config?.zoneID }

    /// 那台有沒有選好的那個網域的 Cloudflare 授權（那台自己回報的：只問有沒有，不讀內容）。
    func authorized(_ id: String) -> Bool {
        guard let zone = config?.zoneID, let info = self.report(id) else { return false }
        return info.accounts.contains { $0.zones.contains { $0.zoneID == zone && $0.authorized } }
    }

    var cloudflareState: HandsBuildNodeState {
        let selected = selectedDevices
        if loginWork.values.contains(where: { if case .running = $0 { return true }; return false })
            || applyWork.values.contains(where: { if case .running = $0 { return true }; return false }) { return .working }
        guard enabled, !selected.isEmpty else { return .off }
        // W183 R8 整合審查（Claude 中）：出錯只看勾著的設備（取消勾選、關掉之後舊的失敗不再亮紅）。
        if selected.contains(where: { if case .failed? = applyWork[$0.id] { return true }; return false }) { return .failed }
        guard config?.zoneID != nil else { return .waiting }
        let ready = selected.allSatisfy { device in authorized(device.id) && urlApplied(device.id) && appliedCurrent(device.id) }
        return ready ? .done : .waiting
    }

    var gptState: HandsBuildNodeState {
        switch dependencies.flow.phase {
        case .waitingUser: .waiting
        case .creatingConnector, .waitingPairing, .verifying: .working
        case .failed, .refused: .failed
        default: podAccount == nil ? .waiting : .done
        }
    }

    var podAccount: String? {
        if case .confirm(_, let account)? = dependencies.flow.card { return account }
        return nil
    }

    var devState: HandsBuildNodeState {
        let selected = selectedDevices
        guard enabled, !selected.isEmpty else { return .off }
        if connecting != nil || !connectQueue.isEmpty { return .working }
        if selected.allSatisfy({ $0.connection == .done }) { return .done }
        return cloudflareState == .done ? .waiting : .off
    }

    var level: Int {
        guard let config else { return HandsBuildConfig.defaultLevel }   // W183 R11：預設 L2（Codex、記憶）
        return config.devices.first(where: \.selected)?.level ?? HandsBuildConfig.defaultLevel
    }

    /// W183 R8 整合審查（Claude 中「面板顯示的是上限、不是實際」）：那台實際生效的等級＝那台回報的（本機核准 ∩ 中央上限），
    /// 再跟現在的上限取小（回報可能晚一輪）。沒回報＝nil（不知道）。
    func actualLevel(_ id: String) -> Int? {
        guard let info = self.report(id) else { return nil }
        return min(info.level, config?.entry(id)?.level ?? info.level)
    }

    /// 勾選的設備裡實際最小的等級（「已連線・L?」「記憶」照這個）；都沒回報＝上限。
    var actualLevel: Int { selectedDevices.compactMap { actualLevel($0.id) }.min() ?? level }

    /// W183 R12（使用者 09-30 裁決：拿掉等級選擇，連上＝全開）：勾選的設備裡還沒全開的（實際生效的比 L2 少）有舊版主機
    ///（回報沒有 level_guard：主設備一律不調高）＝要先更新那台（面板那一行照這個說）。
    var fullNeedsUpdate: Bool {
        selectedDevices.contains { device in
            guard let info = report(device.id), !info.levelGuard else { return false }
            return (actualLevel(device.id) ?? level) < HandsBuildConfig.defaultLevel
        }
    }

    var projects: [HandsBuildProject] {
        guard let config else { return [] }
        return config.devices.filter(\.selected).flatMap { entry -> [HandsBuildProject] in
            let info = self.report(entry.deviceID)
            let choices = info?.projectChoices ?? []
            // W183 R10：專案全部可見——那台回報的每一個能當專案的都在範圍裡（selected 一律 true；面板只顯示、不能勾）；
            // active＝那台回報現在真的允許（新版回報＝全部）；readOnly＝交易實盤類（只能看）。
            let active = info.map { Set($0.allowedProjects.map { $0.uppercased() }) }
            return choices.map { choice in
                HandsBuildProject(id: entry.deviceID + "/" + choice.id, name: choice.name, selected: true,
                                  deviceID: entry.deviceID, active: active.map { $0.contains(choice.id.uppercased()) },
                                  readOnly: choice.readOnlyFloor)
            }
        }
    }

    var problem: String? { problemInfo?.text }

    /// W183 R8 整合：出錯的是哪一種、哪一台（字與順序照 R8c 原本的 problem；多了「那台自己回報的步驟問題」）。
    var problemInfo: HandsBuildProblem? {
        if let actionProblem { return HandsBuildProblem(kind: .action, device: nil, text: actionProblem) }
        if let syncProblem = dependencies.sync.problem { return HandsBuildProblem(kind: .sync, device: nil, text: syncProblem) }
        // W183 R8 整合審查（Claude 中）：套用、登入的失敗只看勾著的設備（取消勾選、關掉之後不再卡在「出錯」）。
        let selectedIDs = Set(selectedDevices.map { $0.id.lowercased() })
        for (id, work) in applyWork.sorted(by: { $0.key < $1.key }) where enabled && selectedIDs.contains(id) {
            // 還沒登入那個帳號＝出錯鈕替它登入（step .authorize：畫面給「重新授權」那一顆）。
            if case .failed(let text) = work {
                return HandsBuildProblem(kind: .apply, device: id, text: name(id) + "：" + text, step: applyNeedsLogin.contains(id) ? .authorize : nil)
            }
        }
        for (id, work) in loginWork.sorted(by: { $0.key < $1.key }) where selectedIDs.contains(id) {
            if case .failed(let text) = work { return HandsBuildProblem(kind: .login, device: id, text: name(id) + "：" + text) }
        }
        if let paused = selectedDevices.first(where: { self.report($0.id)?.permit == "paused" }) {
            return HandsBuildProblem(kind: .paused, device: paused.id, text: paused.name + "：太久連不到主設備，先暫停（連線沒有撤銷）")
        }
        if let locked = selectedDevices.first(where: { self.report($0.id)?.safetyLocked == true }) {
            return HandsBuildProblem(kind: .safety, device: locked.id,
                                     text: locked.name + "：關口為了安全停下（有程式動過連線點）；確認沒有可疑程式後按「解除安全鎖」")
        }
        // W183 R8 整合：勾了、已經套用到這一版、關口沒在跑的那台自己回報的步驟問題（重開畫面也看得到；那台先遮過：redactedForAI）。
        if enabled, let failing = selectedDevices.first(where: { device in
            guard let info = self.report(device.id), fresh(info), info.stepProblem != nil, info.phase != "running" else { return false }
            return appliedCurrent(device.id)
        }), let text = self.report(failing.id)?.stepProblem {
            return HandsBuildProblem(kind: .step, device: failing.id, text: failing.name + "：" + text,
                                     step: self.report(failing.id)?.nextStep.flatMap(HandsSetupStep.init(rawValue:)))
        }
        if let offline = pendingOff.first(where: { $0.state == .waiting }) {
            return HandsBuildProblem(kind: .offline, device: offline.id,
                                     text: offline.name + "：連不到，關閉還沒套用（那台連上主設備、或信封到期時就會停）")
        }
        return dependencies.flow.problem.map { HandsBuildProblem(kind: .connect, device: failedConnect, text: $0) }
    }

    var statusState: HandsBuildNodeState {
        guard enabled else { return pendingOff.isEmpty ? .off : .working }
        if localAvailabilityText != nil { return .waiting }
        if selectedDevices.contains(where: { $0.connection == .done }) {
            return selectedDevices.allSatisfy({ $0.connection == .done }) ? .done : .working
        }
        if problem != nil { return .failed }
        if devState == .done { return .done }
        if cloudflareState == .working || devState == .working || !pendingOff.isEmpty { return .working }
        return .waiting
    }

    var statusText: String {
        // W183 R8c 審查（GPT-6 中）：沒收到回執不寫「已關閉」。
        guard enabled else { return pendingOff.isEmpty ? "已關閉" : "關閉中…（等那台回報）" }
        let selected = selectedDevices
        if selected.isEmpty { return pendingOff.isEmpty ? "等你選設備" : "關閉中…（等那台回報）" }
        if let localAvailabilityText { return localAvailabilityText }
        let connected = selected.filter { $0.connection == .done }
        if connected.count == selected.count { return HandsBuildCopy.connected(actualLevel) }
        if !connected.isEmpty {
            return "已連線：" + connected.map(\.name).joined(separator: "、") + "｜"
                + selected.filter { $0.connection != .done }.map { "\($0.name)：\(connectionReason($0.id))" }.joined(separator: "｜")
        }
        if connecting != nil || !connectQueue.isEmpty { return "連線中…" }
        if cloudflareState == .working { return "準備中…" }
        if selected.contains(where: { !fresh(report($0.id)) }) { return "沒收到這台的回報" }
        if config?.zoneID == nil { return zones.isEmpty ? "等你登入 Cloudflare" : "等你選網址" }
        if let missing = selected.first(where: { !authorized($0.id) }) { return "等你替\(missing.name)登入 Cloudflare" }
        if selected.contains(where: { !urlApplied($0.id) || !appliedCurrent($0.id) }) { return "等你按套用" }
        return "等你按連線"
    }

    private func name(_ id: String) -> String { devices.first { HandsHostAuthority.same($0.id, id) }?.name ?? "那台" }

    // MARK: - 動作（使用者按的）

    /// 改設定：照畫面看到的版本送（別台剛改過＝回「設定剛被改過」、畫面重拿）。還沒拿到設定＝不能改（W183 R8c 審查：沒有「不比對」）。
    private func change(_ ops: [HandsBuildConfigOp]) {
        guard let expected = config?.configRevision else {
            actionProblem = "還沒從主設備拿到設定；等一下再按"
            dependencies.sync.syncSoon()
            return
        }
        let sync = dependencies.sync
        actionProblem = nil
        dependencies.background { [weak self] in
            var failure: String?
            do { try sync.updateConfig(expected: expected, ops: ops) }
            catch { failure = HandsBuildConfigError.from(error)?.plain ?? "改不了設定（\(HandsRemoteClient.plain(error))）" }
            let problem = failure
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.actionProblem = problem } }
        }
    }

    func setEnabled(_ on: Bool) {
        if !on { clearFinishedWork(nil) }   // W183 R8 整合審查（Claude 中）：關掉＝舊的套用出錯收掉
        change([.setEnabled(on)])
    }

    func setDevice(_ id: String, selected: Bool) {
        if !selected { clearFinishedWork(id.lowercased()) }   // W183 R8 整合審查（Claude 中）：取消勾＝那台的套用、登入出錯收掉
        change([.select(device: id.lowercased(), selected: selected)])
    }

    /// 已經結束的套用（與那台的登入）紀錄收掉（nil＝全部的套用）；跑著的留著。
    private func clearFinishedWork(_ id: String?) {
        for (key, work) in applyWork where id == nil || key == id {
            if case .running = work { continue }
            applyWork[key] = nil
            applyNeedsLogin.remove(key)
        }
        if let id, let work = loginWork[id] {
            if case .running = work { return }
            loginWork[id] = nil
        }
    }

    func chooseZone(_ id: String) {
        var found: (account: String, name: String)?
        for report in view.reports {
            for account in report.accounts {
                if let zone = account.zones.first(where: { $0.zoneID == id }) { found = (account.id, zone.name); break }
            }
            if found != nil { break }
        }
        guard let found else { actionProblem = "找不到這個網域"; return }
        guard !found.name.isEmpty else { actionProblem = "這個網域的名稱還不知道；登入的那台再同步一次就有"; return }
        change([.zone(accountID: found.account, zoneID: id, domain: found.name)])
    }

    func setSubdomain(_ label: String, for deviceID: String) {
        guard HandsSettings.validLabel(label) != nil else { actionProblem = "子網域只能用小寫英數與「-」"; return }
        change([.subdomain(device: deviceID.lowercased(), label: label)])
    }

    func setLevel(_ level: Int) {
        let ops = selectedDevices.map { HandsBuildConfigOp.level(device: $0.id, level: min(max(level, 0), HandsSettings.maxLevel)) }
        guard !ops.isEmpty else { return }
        change(ops)
    }

    func setProject(_ id: String, selected: Bool) {
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count == 2, UUID(uuidString: parts[0]) != nil, UUID(uuidString: parts[1]) != nil else { return }
        change([.project(device: parts[0].lowercased(), projectID: parts[1].uppercased(), selected: selected)])
    }

    func loginCloudflare() {
        guard let local = localID else { actionProblem = "這台還沒有設備身分"; return }
        loginCloudflare(for: local)
    }

    /// 替那台登入（人在這台）：那台跑自己的 cloudflared login、授權存那台；登入網址經主設備**只回到這台**，在這台的私訊框開。
    func loginCloudflare(for deviceID: String) {
        let target = deviceID.lowercased()
        if HandsHostAuthority.same(target, localID) { dependencies.loginHere(); return }
        guard let epoch = self.report(target)?.setupEpoch else { loginWork[target] = .failed("那台還沒回報狀態（沒開？）；等一下再按"); return }
        loginWork[target] = .running("等那台開授權頁…")
        let sync = dependencies.sync
        dependencies.background { [weak self] in
            do {
                let id = try sync.submit(action: "login", target: target, attempt: UUID().uuidString.lowercased(), setupEpoch: epoch,
                                         lifetime: HandsBuildIntent.maxPickup) { result in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.loginResult(result, device: target) } }
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { if self?.logins[id] == nil { self?.logins[id] = (target, nil) } } }
            } catch {
                let text = HandsRemoteClient.plain(error)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.loginWork[target] = .failed("送不到主設備（\(text)）") } }
            }
        }
    }

    private func loginResult(_ result: HandsBuildResult, device: String) {
        let object = result.object
        let state = object["state"] as? String ?? ""
        if !result.final, state == "login_url", let raw = object["url"] as? String, let url = HandsCloudflared.loginURL(in: raw) {
            // 只開 Cloudflare 授權頁（固定版本 cloudflared 印的那一種）；頁面上按取消＝請那台取消這一輪。
            logins[result.operationID] = (device, url)
            loginWork[device] = .running("在私訊框按 Authorize（授權存到那台）")
            let operation = result.operationID
            dependencies.openLogin(url) { [weak self] in self?.cancelLogin(operation) }
            return
        }
        guard result.final else { return }
        // 最後一則（含「結果未知」）：授權頁一定收起來（敏感頁面不留著）。W183 R8 整合（R8b）：授權完成＝分頁標「完成」（頁面關掉、分頁留著）；
        // 其他（取消、失敗、結果未知）＝分頁收掉。
        if let opened = logins.removeValue(forKey: result.operationID)?.url {
            if state == "authorized" { dependencies.markLoginDone(opened) } else { dependencies.closeLogin(opened) }
        }
        switch state {
        case "authorized": loginWork[device] = .done("已登入")
        case "cancelled": loginWork[device] = .idle
        case "failed": loginWork[device] = .failed(object["reason"] as? String ?? "登入沒有完成")
        default: loginWork[device] = .failed(Self.refusalText(object["reason"] as? String))
        }
        dependencies.sync.syncSoon()
    }

    private func cancelLogin(_ operation: String) {
        guard let entry = logins[operation] else { return }
        let sync = dependencies.sync
        dependencies.background {
            _ = try? sync.submit(action: "login_cancel", target: entry.device, payload: ["operation_id": operation]) { _ in }
        }
    }

    /// 「套用」：每台勾選的設備照設定建自己的網址——**這台也一樣**經 HandsBuildExecutor（W183 R8c 審查：本機與別台同一套核對，
    /// 那台用自己已接受的那一份拍成不變的快照，設定版本要跟按的時候看到的一樣）。接口的這一個＝照現在畫面上的那一份（沒有草稿）。
    func applyURLs() {
        guard let config else {
            actionProblem = "還沒從主設備拿到設定；等一下再按"
            dependencies.sync.syncSoon()
            return
        }
        applyURLs(saving: [], expected: config.configRevision)
    }

    /// W183 R8 整合（R8a「套用帶著看到的那一份與子網域草稿」）：先照畫面看到的版本存子網域（CAS：別處改過＝不存、不套用，請你再看一次；
    /// 存不成＝停在這裡、不建網址），再等勾選的每台拿到新的那一版（回報的套用版本；那台用自己已接受的那一份拍快照）才送「套用」。
    /// 沒有草稿＝看到的版本要還是現在這一版才送。
    /// W183 R8 整合審查（GPT-6 高「apply 在非同步送出時重讀版本」）：按下去那一刻就拍下主權、版本（有草稿＝CAS 回的那個確切版本）、
    /// 勾了哪幾台，一路帶到送出（HandsBuildSync.submit(expected:)）——送出那一刻的設定不是這一份＝不送；那台再核一次它已接受的版本。
    func applyURLs(saving ops: [HandsBuildConfigOp], expected: Int) {
        guard let config else {
            actionProblem = "還沒從主設備拿到設定；等一下再按"
            dependencies.sync.syncSoon()
            return
        }
        guard config.enabled, config.zoneID != nil else { actionProblem = "先選網域"; return }
        let targets = selectedDevices.map(\.id)   // 按下去那一刻勾的（之後勾的不算：要再按一次）
        guard !targets.isEmpty else { actionProblem = "先勾設備"; return }
        let authority = HandsBuildExpected.authority(of: config)
        guard !ops.isEmpty else {
            guard config.configRevision == expected else {
                actionProblem = HandsBuildConfigError.revisionConflict(config.configRevision).plain
                dependencies.sync.syncSoon()
                return
            }
            actionProblem = nil
            pendingApply = nil
            for target in targets { sendApply(target, HandsBuildExpected(authority: authority, revision: expected)) }
            return
        }
        actionProblem = nil
        pendingApply = nil
        for target in targets { applyWork[target] = .running("存網址…"); applyNeedsLogin.remove(target) }
        let sync = dependencies.sync
        dependencies.background { [weak self] in
            var saved: Int?
            var failure: String?
            do { saved = try sync.updateConfig(expected: expected, ops: ops).configRevision }
            catch { failure = HandsBuildConfigError.from(error)?.plain ?? "改不了設定（\(HandsRemoteClient.plain(error))）" }
            let revision = saved, problem = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let revision else {
                        // 存不成＝停在這裡（不建通道、不改 DNS）；一句話留在面板上。
                        self.actionProblem = problem
                        for target in targets where self.applyWork[target] == .running("存網址…") { self.applyWork[target] = .idle }
                        return
                    }
                    // CAS 回的那個確切版本（主權＝按的時候那一任；送出時再核）：只為這一版送。
                    self.pendingApply = PendingApply(expected: HandsBuildExpected(authority: authority, revision: revision), remaining: targets,
                                                     deadline: self.dependencies.now().addingTimeInterval(Self.pickupWait))
                    for target in targets { self.applyWork[target] = .running("等那台拿到新網址…") }
                    self.checkPendingApply()
                }
            }
        }
    }

    /// 只套用這台：不依賴主設備的本機回報、不寫中央設定。
    func applyHere(expected: HandsBuildExpected, setupEpoch: String?) {
        guard let target = localID, let config, HandsBuildExpected.of(config) == expected else {
            actionProblem = HandsBuildCopy.changed
            return
        }
        if case .running = applyWork[target] {
            actionProblem = "這台正在套用，等一下再按"
            return
        }
        actionProblem = nil
        applyNeedsLogin.remove(target)
        applyWork[target] = .running("建網址中…")
        let sync = dependencies.sync
        dependencies.background { [weak self] in
            let receive: (HandsBuildResult) -> Void = { result in
                guard result.final else { return }
                let object = result.object
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let reason = object["reason"] as? String
                        if result.state == "applied" {
                            self.applyWork[target] = .done("網址好了")
                        } else {
                            self.applyWork[target] = .failed(Self.localApplyText(reason))
                        }
                        // 結果留在本機；不叫 syncSoon、不交遠端 outbox。
                    }
                }
            }
            do { try sync.applyHere(expected: expected, setupEpoch: setupEpoch, onResult: receive) }
            catch {
                let reason = HandsBuildExecutor.localApplyReason(error)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.applyWork[target] = .failed(Self.localApplyText(reason)) }
                }
            }
        }
    }

    static func localApplyText(_ reason: String?) -> String {
        switch reason {
        case "no_config", "expired": return "這台的已接受設定不存在或已過期；未套用"
        case "not_authorized_here": return "這台尚未取得這個 Cloudflare 網域的授權"
        case "result_unknown": return "本機套用結果未知；先查看狀態，不要重送"
        default: return refusalText(reason).replacingOccurrences(of: "那台", with: "這台")
        }
    }

    /// 存好子網域之後：那台回報拿到那一版了＝送那一台；設定又被別處改了（版本變大、主權換了）＝不送（請你再看一次）；
    /// 等太久還沒拿到＝那台出錯、**不送**（W183 R8 整合審查：沒收到那一版的回執就不送）。
    private func checkPendingApply() {
        guard var pending = pendingApply else { return }
        if let config, config.configRevision > pending.expected.revision || HandsBuildExpected.authority(of: config) != pending.expected.authority {
            pendingApply = nil
            for id in pending.remaining where applyWork[id] == .running("等那台拿到新網址…") { applyWork[id] = .idle }
            actionProblem = HandsBuildConfigError.revisionConflict(config.configRevision).plain
            return
        }
        let ready = pending.remaining.filter { id in fresh(self.report(id)) && (self.report(id)?.appliedConfigRevision ?? 0) >= pending.expected.revision }
        pending.remaining.removeAll { ready.contains($0) }
        let late = dependencies.now() > pending.deadline
        if late {
            for id in pending.remaining { applyWork[id] = .failed("那台還沒拿到新的設定（沒開、連不到主設備？）；等它連上再按「套用」") }
            pending.remaining = []
        }
        pendingApply = pending.remaining.isEmpty ? nil : pending
        for id in ready { sendApply(id, pending.expected) }
    }

    /// 送一台的「套用」（帶按的時候看到的那一份；那台的 setupEpoch 照它現在回報的）。
    private func sendApply(_ target: String, _ expected: HandsBuildExpected) {
        applyNeedsLogin.remove(target)
        guard authorized(target) else {
            applyWork[target] = .failed(Self.refusalText("not_authorized_here"))
            applyNeedsLogin.insert(target)
            return
        }
        guard let epoch = self.report(target)?.setupEpoch else { applyWork[target] = .failed("那台還沒回報狀態（沒開？）；等一下再按"); return }
        applyWork[target] = .running(HandsHostAuthority.same(target, localID) ? "建網址中…" : "交給那台建網址…")
        let sync = dependencies.sync
        dependencies.background { [weak self] in
            do {
                _ = try sync.submit(action: "apply_urls", target: target, setupEpoch: epoch, expected: expected,
                                    lifetime: HandsBuildIntent.maxPickup) { result in
                    guard result.final else { return }
                    let object = result.object
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let reason = object["reason"] as? String
                            let step = (object["step"] as? String).flatMap(HandsSetupStep.init(rawValue:))
                            if object["state"] as? String == "applied" {
                                self?.applyWork[target] = .done("網址好了")
                            } else {
                                self?.applyWork[target] = .failed(reason.map { Self.refusalText($0) } ?? "沒有建好")
                                // 那台還沒登入那個帳號（或授權那幾步沒成）＝出錯鈕替它登入。
                                if reason == "not_authorized_here" || step == .cloudflared || step == .authorize { self?.applyNeedsLogin.insert(target) }
                            }
                            sync.syncSoon()
                        }
                    }
                }
            } catch HandsBuildSyncError.configChanged {
                // 送出那一刻的設定已經不是按的時候那一份：不送，請你再看一次（不自己換成新的版本）。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.applyWork[target] = .failed(HandsBuildConfigError.revisionConflict(0).plain) }
                }
            } catch {
                let text = HandsRemoteClient.plain(error)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyWork[target] = .failed("送不到主設備（\(text)）") } }
            }
        }
    }

    /// ［連線］：一台＝那台；nil＝勾選的每一台逐台排（同一個 Pod 一次一個連接器）。
    func connect(deviceID: String?) {
        let targets = deviceID.map { [$0.lowercased()] } ?? selectedDevices.filter { $0.connection != .done }.map(\.id)
        guard !targets.isEmpty else { return }
        connectQueue = targets
        startNextConnect()
    }

    /// W183 R11（GPT-6 R11 審查 4）：入口的「連線」——目前這個 ChatGPT 帳號還沒連上（或核對不了）的那幾台逐台排；那台有別的帳號的連線也照連
    ///（不看那台的「已連線」）。
    func connect(deviceIDs: [String]) {
        var seen = Set<String>()
        let targets = deviceIDs.map { $0.lowercased() }.filter { seen.insert($0).inserted }
        guard !targets.isEmpty else { return }
        connectQueue = targets
        startNextConnect()
    }

    private func startNextConnect() {
        guard connecting == nil, !connectQueue.isEmpty else { return }
        let target = connectQueue.removeFirst()
        connecting = target
        // W183 R10：不再帶面板上選的範圍（卡上不選；主機照 ChatGPT build 的中央設定＋那台全部專案）。
        // W183 R8 整合審查（Claude 高）：流程沒真的開始（別的連線還在跑、正在取消）＝不佔著「正在連」、排隊的也收掉（使用者看一下再按）。
        guard dependencies.flow.offer(target: target, preset: nil) else {
            connecting = nil
            connectQueue = []
            sawActive = false
            actionProblem = "上一次連線還沒結束；在私訊框把它做完或取消，再按「連線」"
            return
        }
    }

    /// W183 R8 整合審查（GPT-6 中／Claude 高）：卡片上按了「取消」、卡片收起來＝這一輪結束（flow 回到「等你按」）：不再佔著、排隊的也收掉。
    private func connectRoundClosed() {
        guard connecting != nil else { return }
        sawActive = false
        connecting = nil
        connectQueue = []
    }

    private var sawActive = false

    /// 連線流程結束（連上、失敗、被拒、取消）才開下一台。
    private func flowChanged(_ phase: HandsConnectionPhase) {
        guard connecting != nil else { return }
        switch phase {
        case .waitingTap, .waitingUser, .creatingConnector, .waitingPairing, .verifying:
            sawActive = true
        case .connected, .failed, .refused, .needsManual:
            sawActive = false
            failedConnect = phase == .connected ? nil : connecting   // W183 R8 整合：出錯鈕「再連一次」連這台
            connecting = nil
            if phase == .connected { startNextConnect() } else { connectQueue = [] }   // 出錯就停下（使用者看一下再按）
            dependencies.sync.syncSoon()
        case .idle:
            if sawActive { sawActive = false; connecting = nil; connectQueue = [] }   // 使用者在卡片上按了取消
        }
    }

    /// 使用者明確解除那台的安全停機鎖（這台＝本機；別台＝經信箱，綁那台回報的事故編號、setupEpoch、撤銷世代）。
    /// W183 R8 整合審查（GPT-6 中）：這台也一樣綁按的時候看到的事故編號、setupEpoch、撤銷世代（HandsBuildExecutor.unlockHere；
    /// 最後經 unlockSafety(incident:) 原子核對）——不叫不帶事故編號的 retry()，晚到的解除清不掉新的事故。
    func unlockSafety(for deviceID: String) {
        let target = deviceID.lowercased()
        guard let info = self.report(target), let epoch = info.setupEpoch, let incident = info.safetyIncident else {
            actionProblem = "那台現在沒有回報安全鎖（或還沒回報）；等一下再看"
            return
        }
        let generation = config?.entry(target)?.revocationGeneration ?? 0
        if HandsHostAuthority.same(target, localID) {
            let unlock = dependencies.unlockHere, sync = dependencies.sync
            dependencies.background { [weak self] in
                let refusal = unlock(incident, epoch, generation)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.actionProblem = refusal.map { Self.refusalText($0) }
                        sync.syncSoon()
                    }
                }
            }
            return
        }
        let sync = dependencies.sync
        dependencies.background { [weak self] in
            do {
                _ = try sync.submit(action: "unlock_safety", target: target, setupEpoch: epoch,
                                    payload: ["incident": incident, "revocation_generation": generation]) { result in
                    guard result.final else { return }
                    let object = result.object
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if object["state"] as? String != "done" { self?.actionProblem = Self.refusalText(object["reason"] as? String) }
                            sync.syncSoon()
                        }
                    }
                }
            } catch {
                let text = HandsRemoteClient.plain(error)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.actionProblem = "送不到主設備（\(text)）" } }
            }
        }
    }

    /// W183 R11（使用者 09-30「測試接上跟取消」；主導：「一顆按鈕就斷乾淨（撤銷授權、ChatGPT 那邊再叫就被拒）」）：［斷線］＝撤銷那幾台全部的
    /// ChatGPT 連線（token、授權碼、窗口作廢，跑著的沙盒工作停下），等每台回覆。這台＝本機直接撤銷；這台是副設備、那台是主設備＝設備簽章 RPC
    ///（remote_hands_action 的 revoke_all）；別台＝經主設備的信箱（跟「撤銷」同一條：綁按的時候看到的那一組連線，最多等 60 秒）。
    /// W183 R11（GPT-6 R11 審查 6，中：「一台失敗，其他全部還算連著、後面不再試」）：每一台都試（前面的失敗不擋後面的），逐台回結果——
    /// 已撤銷、撤銷了但沒存成、沒做成（送不到、那台拒絕）、不知道（送出去了沒回覆）。之後照舊同步一次（回報跟上）。
    func disconnect(deviceIDs: [String]) async -> [String: HandsDisconnectOutcome] {
        var outcomes: [String: HandsDisconnectOutcome] = [:]
        var seen = Set<String>()
        for id in deviceIDs.map({ $0.lowercased() }) where seen.insert(id).inserted {
            outcomes[id] = await disconnectOne(id)
        }
        dependencies.sync.syncSoon()
        return outcomes
    }

    private func disconnectOne(_ target: String) async -> HandsDisconnectOutcome {
        let background = dependencies.background
        let label = name(target)
        if HandsHostAuthority.same(target, localID) {
            let revoke = dependencies.revocation.hereResult
            let problem: String? = await withCheckedContinuation { continuation in
                background { continuation.resume(returning: revoke()) }
            }
            // 撤銷沒存成：記憶體裡已經全部停用、授權檔刪了（一樣斷了），要讓使用者知道之後要重新配對。
            return problem == nil ? .revoked : .revokedUnsaved(label + "：斷了，但授權檔沒存成；之後要重新配對")
        }
        if case .member(_, let primary, _) = dependencies.role(), HandsHostAuthority.same(primary, target) {
            let revoke = dependencies.revocation.primary
            let failure: String? = await withCheckedContinuation { continuation in
                background {
                    do { try revoke(); continuation.resume(returning: nil) }
                    catch { continuation.resume(returning: Self.rpcFailure(error)) }
                }
            }
            guard let failure else { return .revoked }
            if failure.hasPrefix(Self.unsavedMark) { return .revokedUnsaved(label + "：斷了，但主設備的授權檔沒存成；之後要重新配對") }
            if failure.hasPrefix(Self.unknownMark) {
                return .unknown(label + "：不知道斷了沒有（" + String(failure.dropFirst(Self.unknownMark.count)) + "）；再按一次斷線")
            }
            return .failed(label + "：送不到主設備（" + failure + "）")
        }
        guard let info = self.report(target), let epoch = info.setupEpoch else { return .failed(label + "：那台還沒回報狀態；等一下再按") }
        let digest = info.grantsDigest
        let sync = dependencies.sync
        let once = HandsBuildOnce()
        /// 信箱的結果（原始的；白話在主執行緒換）：done＝撤銷了；否則那台給的理由、或這邊的一句話。
        enum Outcome: Sendable { case done, refused(String?), notSent(String), noReply }
        let outcome: Outcome = await withCheckedContinuation { continuation in
            let finish: @Sendable (Outcome) -> Void = { value in if once.claim() { continuation.resume(returning: value) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { finish(.noReply) }
            background {
                do {
                    _ = try sync.submit(action: "revoke_all", target: target, setupEpoch: epoch, payload: ["grants_digest": digest]) { result in
                        guard result.final else { return }
                        let object = result.object
                        finish(object["state"] as? String == "done" ? .done : .refused(object["reason"] as? String))
                    }
                } catch {
                    finish(.notSent(HandsRemoteClient.plain(error)))
                }
            }
        }
        switch outcome {
        case .done: return .revoked
        case .refused(let reason):
            switch reason ?? "" {
            case "revoke_not_saved": return .revokedUnsaved(label + "：斷了，但那台的授權檔沒存成；之後要重新配對")
            case "result_unknown", "expired": return .unknown(label + "：" + Self.refusalText(reason))
            // 剛連上、回報還沒跟上（按的時候看到的那一組連線不是現在的）：沒撤銷，等回報跟上再按。
            case "grants_changed": return .failed(label + "：那台的連線剛變過（回報還沒跟上）；等幾秒再按斷線")
            default: return .failed(label + "：" + Self.refusalText(reason))
            }
        case .notSent(let text): return .failed(label + "：送不到主設備（\(text)）")
        case .noReply: return .unknown(label + "：那台沒回覆（沒開？），不知道斷了沒有；再按一次斷線")
        }
    }

    /// 主設備 RPC 的失敗分三種（開頭的記號）：主設備說撤銷了但沒存成、送出去了不知道結果、根本沒送到或被拒。
    nonisolated static let unsavedMark = "unsaved:"
    nonisolated static let unknownMark = "unknown:"
    nonisolated static func rpcFailure(_ error: Error) -> String {
        let text = HandsRemoteClient.plain(error)
        if let link = error as? RemoteHostLinkError {
            switch link {
            case .remoteError(let detail):
                // 主機收到了、做了撤銷，但存不進去（HandsService.revokeEverything 回的那一句）：記憶體裡已經全部停用。
                if detail.contains("撤銷沒能存檔") { return unsavedMark + text }
                return text
            case .invalidResponse:
                return unknownMark + text   // 送出去了、回覆壞了：不知道那台做了沒有
            default:
                return text                 // 連不上（通道、socket）：沒送到
            }
        }
        return text
    }

    /// 撤銷那台全部的 ChatGPT 連線（這台＝本機；別台＝經信箱，只作用在按的時候看到的那一組）。
    func revokeAll(for deviceID: String) {
        let target = deviceID.lowercased()
        if HandsHostAuthority.same(target, localID) { dependencies.revocation.here(); return }
        guard let info = self.report(target), let epoch = info.setupEpoch else { actionProblem = "那台還沒回報狀態；等一下再按"; return }
        let digest = info.grantsDigest
        let sync = dependencies.sync
        dependencies.background { [weak self] in
            do {
                _ = try sync.submit(action: "revoke_all", target: target, setupEpoch: epoch, payload: ["grants_digest": digest]) { result in
                    guard result.final else { return }
                    let object = result.object
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if object["state"] as? String != "done" { self?.actionProblem = Self.refusalText(object["reason"] as? String) }
                            sync.syncSoon()
                        }
                    }
                }
            } catch {
                let text = HandsRemoteClient.plain(error)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.actionProblem = "送不到主設備（\(text)）" } }
            }
        }
    }

    static func refusalText(_ reason: String?) -> String {
        switch reason ?? "" {
        case "busy": return "那台的設定正在跑，等一下再按"
        case "epoch_stale", "epoch_missing": return "那台剛重開或取消過；再按一次"
        case "config_changed": return "設定剛改過、那台還沒拿到；等幾秒再按"
        case "not_authorized_here": return "那台還沒登入這個 Cloudflare 帳號：先替它登入"
        case "no_domain": return "先選網域"
        case "not_selected": return "那台沒有被勾選"
        case "expired": return "送到那台時已經過期（那台沒開？）；再按一次"
        case "result_unknown": return "不知道那台做了沒有（那台沒開、或主設備重開過）；看一下那台的狀態再按"
        case "duplicate": return "這個動作那台已經做過了"
        case "incident_changed", "incident": return "那台的安全鎖換過了（又發生了一次）；看一下再按「解除安全鎖」"
        case "generation_changed": return "那台剛被關過又打開；看一下再按"
        case "grants_changed": return "那台的連線剛變過；看一下再按「撤銷」"
        default: return "那台沒有照做（\(reason ?? "")）"
        }
    }
}

/// W183 R11 第二輪（GPT-6 R11b 審查 5，中：「正式的本機撤銷接線退步時，驗收還是會過」）：撤銷的接線——［斷線］、ChatGPT build 的「撤銷」都走這一份。
/// 這台＝那台 HandsService 的 revokeEverything（token、授權碼、窗口作廢，沙盒工作停下）；副設備→主設備＝設備簽章 RPC 的
/// remote_hands_action revoke_all。正式（`live`）與自測都用 `standard` 建：自測只換底下的 service 與傳輸，撤銷本身不另寫。
struct HandsRevocationWiring: Sendable {
    /// 這台撤銷全部（不看結果：「撤銷」按鈕）。
    let here: @Sendable () -> Void
    /// 這台撤銷全部，回 nil＝存好了，否則是沒存成的那一句（已經全部停用）。
    let hereResult: @Sendable () -> String?
    /// 副設備→主設備：撤銷主設備上全部的連線（丟錯＝沒做成或不知道，HandsBuildController.rpcFailure 分）。
    let primary: @Sendable () throws -> Void

    static func standard(service: HandsService,
                         callPrimary: @escaping @Sendable (_ method: String, _ payload: [String: Any]) throws -> [String: Any]) -> HandsRevocationWiring {
        HandsRevocationWiring(here: { _ = service.revokeEverything() },
                              hereResult: { service.revokeEverything() },
                              primary: { _ = try callPrimary("remote_hands_action", ["op": "revoke_all"]) })
    }

    /// 正式：這台的 HandsService.shared、DeviceDispatch 的主設備 RPC（舊主設備也認得 revoke_all）。
    static var live: HandsRevocationWiring {
        standard(service: .shared, callPrimary: { method, payload in try DeviceDispatch.shared.callPrimary(method: method, payload: payload) })
    }
}

/// W183 R8 整合：出錯的是哪一種、哪一台（畫面決定哪個節點亮紅、給哪一顆鈕）。字就是 HandsBuildController.problem。
struct HandsBuildProblem: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// 按了做不了（設定剛被改過、還沒拿到設定…）：只是一句話。
        case action
        /// 連不到主設備、信封不收。
        case sync
        /// 那台的「套用」沒成。
        case apply
        /// 替那台登入沒成。
        case login
        /// 那台太久連不到主設備、先暫停。
        case paused
        /// 那台的關口安全停機（要使用者對那台明確解除）。
        case safety
        /// 那台自己回報的步驟問題。
        case step
        /// 關掉了、那台還沒回報。
        case offline
        /// 連線（［連線］卡那一段）出錯。
        case connect
    }
    let kind: Kind
    let device: String?
    let text: String
    /// kind == .step：出錯的是哪一步（那台回報的下一步）。
    var step: HandsSetupStep? = nil
}
