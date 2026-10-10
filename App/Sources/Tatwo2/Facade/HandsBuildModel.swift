import Combine
import CoreGraphics
import Foundation

// W183 R8a：ChatGPT build 的 adapter（實作 Facade/HandsBuild.swift 的 HandsBuildModeling；規格 docs/specs/183-chatgpt-hands/chatgpt-build.md）。
// 使用者 09-28：「tap/chatgpt跟chatgpt手腳合併 手腳改名chatgpt build」「整個流程不要弄得非常多文字 我還寧願你做得像n8n那種icon流程可視化」
// 「可以 多設備就這樣 照對照稿開工」。
// W183 R8 整合（主導）：接到 R8c 的多設備後端 HandsBuildController（主設備存設定、每台自己當自己的主機、登入與套用分開、信箱）——
// 不再是「一次一台主機」：設備可以多選、每台一個子網域、登入帶目標設備、［連線］逐台排、狀態照每台的回報。
// - 分三層，自測（w183ui）每一層都能單獨驗：
//   1. HandsBuildInput（從 HandsBuildController 與這台的狀態收集的純資料）→ HandsBuildSnapshot.derive（節點標記、狀態字、要你處理的節點、出錯鈕）；
//   2. HandsBuildGraph.make（節點與連線；只有一台＝只畫「主」）、HandsBuildLayout（節點位置）；
//   3. 動作：HandsBuildModel.plan(…) 只算出要做的事（HandsBuildEffect），execute 才真的叫 HandsBuildController。
// - 安全條款照舊（one-switch.md、threat-model.md、contract §11）：改設定一律帶畫面看到的版本（CAS；別處改過＝不送）；登入只是登入；
//   建網址只在按「套用」；解除安全鎖只由使用者對那台按；［連線］＝私訊框的原生卡（一次性連線意圖）；AI 工具不經過這裡。
// - R8a 在接口外加的（出錯鈕、開關能不能按、開發者模式那一句、帶快照的套用、「…」經 adapter、Computer Use 碰不到這張卡）在多設備語意下保留；
//   「一次一台」的換主機確認、交回主設備拿掉（R8c：claim／release 退役）：改成設備面板勾選／取消勾選（取消勾有連線的那台先在卡片內確認）。

/// 節點面板（一次一個）。設備節點不管幾台都開同一個「設備」面板（對照稿）。
enum HandsBuildPanel: String, Sendable, Equatable, CaseIterable {
    case gpt, devices, cloudflare, dev

    var title: String {
        switch self {
        case .gpt: HandsBuildCopy.chatGPTTitle
        case .devices: HandsBuildCopy.devicesTitle
        case .cloudflare: HandsBuildCopy.cloudflare
        case .dev: HandsBuildCopy.dev
        }
    }

    /// 顯示哪個面板：使用者點過的＞要你處理的＞ChatGPT Dev。
    static func resolve(chosen: HandsBuildPanel?, attention: HandsBuildPanel?) -> HandsBuildPanel {
        chosen ?? attention ?? .dev
    }

    /// 步驟屬於哪個節點（那台回報的步驟問題亮在哪一格）。
    static func of(_ step: HandsSetupStep) -> HandsBuildPanel {
        switch step {
        case .host: .devices
        case .cloudflared, .authorize, .tunnel: .cloudflare
        case .start, .url, .pairing, .remember: .dev
        }
    }
}

/// 面板右上「…」裡的工程細節（預設收著；按了才佔版面）。
/// W183 R8 整合：每台都是自己的主機——「…」一律是這台自己的（步驟、帳號與網域、已連線與撤銷、沒用到的通道、診斷）；別台的撤銷在
/// 「已連線與撤銷」的「其他設備」、別台的解除安全鎖在設備面板。R8c 讓「改用這台當主機」退役（claim_host 退役），這一項拿掉。
enum HandsBuildMore: String, Sendable, Equatable, CaseIterable {
    case steps, account, grants, tunnels, diagnostics

    var title: String {
        switch self {
        case .steps: "步驟"
        case .account: "帳號與網域"
        case .grants: "已連線與撤銷"
        case .tunnels: "沒用到的通道"
        case .diagnostics: "診斷"
        }
    }

    /// 選單與畫面都照這一份。
    static let items: [HandsBuildMore] = allCases
}

/// 出錯那一列的一顆鈕（W183 R8 整合：多設備的四種；字都短）。
enum HandsBuildFix: Equatable, Sendable {
    /// 照選好的網域與子網域再套用一次（建網址、起關口）。
    case retryApply
    /// 替那台重新登入 Cloudflare。
    case login(String)
    /// W183 R8 整合審查（Claude 中「失敗那顆鈕的名字要跟步驟訊息一致」，R7a）：那台回報的步驟問題在登入那兩步（cloudflared、授權）＝
    /// 替那台登入；名字跟「…」步驟那一列的鈕同一套（授權那一步＝「重新授權」，其他＝「重試」：ChatGPTHandsStepRow.rerunLabel）。
    case reauthorize(String, HandsSetupStep)
    /// 使用者對那台明確解除安全停機鎖。
    case unlock(String)
    /// 再連一次（nil＝勾選的每一台）。
    case reconnect(String?)

    var title: String {
        switch self {
        case .retryApply: "重試"
        case .login: "重新登入"
        case .reauthorize(_, let step): (step == .authorize ? HandsOneSwitchStatus.Action.reauthorize : .retry).title
        case .unlock: HandsBuildCopy.unlock
        case .reconnect: "再連一次"
        }
    }
}

/// 正式 ChatGPT build 畫面與 adapter 共用的文字；畫面契約以原生 AX 自測驗證。
enum HandsBuildCopy {
    static let title = "ChatGPT build"
    static let infoTitle = "ChatGPT build 是什麼"
    /// ⓘ 的一句（W183 R5 使用者給的那句，沿用；說明只在這裡）。
    static let infoParagraph = "透過 Cloudflare 網域連結主、副設備，提供 ChatGPT 如 Codex 的工程能力，用以節省 Codex 額度。"
    // 狀態 pill
    static let off = "已關閉"
    static let preparing = "準備中…"
    static let waitAuthorize = "等你在私訊框授權"
    /// W183 R12（使用者 09-30 裁決：拿掉等級選擇）：「已連線・」後面寫能力（Codex、記憶），不寫 L?。
    static func connected(_ level: Int) -> String { "已連線・" + HandsConnectAbility.words(level: level) }
    static func failed(_ message: String) -> String { "出錯：" + message }
    // 節點
    static let gpt = "GPT"
    static let pod = "Pod"
    static let primary = "主"
    static let secondary = "副"
    static let cloudflare = "Cloudflare"
    static let notLoggedIn = "未登入"
    static let dev = "ChatGPT Dev"
    static let connectedShort = "已連線"
    // 面板
    static let chatGPTTitle = "ChatGPT"
    static let devicesTitle = "設備"
    static let loginCloudflare = "登入 Cloudflare"
    static let apply = "套用"
    static let connect = "連線"
    static let enableChatGPT = "啟用 ChatGPT"
    static let podAsleep = "Pod 休眠中"
    static let podStarting = "Pod 啟動中"
    static let devModeOn = "開發者模式已開"
    static let devModeLater = "開發者模式：連線時檢查"
    static let primaryRole = "主設備"
    static let secondaryRole = "副設備"
    static let thisDevice = "這台"
    static let domainUnknown = "（網域）"
    static let more = "工程細節"
    static let back = "返回"
    static let activity = "施工房"
    static let envLogin = "環境登入 › Cloudflare"
    static let unlock = "解除安全鎖"
    static func loginFor(_ name: String) -> String { "替" + String(name.prefix(8)) + "登入" }
    static func connectOne(_ name: String) -> String { "連 " + String(name.prefix(10)) }
    // 一句話的提示（按了做不了的原因）
    static let busy = "設定進行中，等一下再按"
    static let turnOnFirst = "先打開 ChatGPT build"
    static let badLabel = "子網域只能小寫英數與「-」"
    /// W183 R8 整合：還沒從主設備拿到 ChatGPT build 的設定（R8c：沒有「不比對版本」的改法）。
    static let notReady = "還沒拿到設定，等一下"
    static let pickDomain = "先選網域"
    static let pickDevice = "先勾設備"
    // W183 R8a 審查（GPT-6／Claude）
    /// 按下去時畫面上的（設定版本、網域、勾選、流程世代）跟現在不一樣：不送。
    static let changed = "畫面剛更新，再看一次"
    static func saveFailed(_ reason: String?) -> String {
        "沒存成" + (reason.map { "：" + String(HandsOneSwitchStatus.short($0).prefix(24)) } ?? "")
    }
    /// W183 R12（使用者 09-30 裁決：拿掉等級選擇——「他連上就是全部都能看 唯讀記憶是有他專屬的區塊」；主導：L0／L1／L2 那一排拿掉，
    /// 換成一行白話）：ChatGPT Dev 面板那一行＝連上之後能做的（跟確認卡同一句）。
    static var capabilities: String { HandsConnectAbility.line(level: HandsBuildConfig.defaultLevel) }

    /// 節點標記的念法（VoiceOver、滑過的提示）。
    static func word(_ state: HandsBuildNodeState) -> String {
        switch state {
        case .done: "完成"
        case .waiting: "等你"
        case .working: "進行中"
        case .off: "未選"
        case .failed: "出錯"
        }
    }

}

// MARK: - 1. 收集的純資料 → 節點標記與狀態字

struct HandsBuildInput: Equatable, Sendable {
    /// ChatGPT 的 Pod（TAP › ChatGPT）。
    enum Pod: Equatable, Sendable { case disabled, starting, needsLogin, ready, sleeping(everReady: Bool), failed(String) }

    /// 已經從主設備拿到 ChatGPT build 的設定（還沒拿到＝畫面不能改：R8c 的 CAS 沒有「不比對版本」）。
    var configKnown = false
    /// 設定版本（按鈕帶著走：改設定、套用都照這個比對）。
    var configRevision: Int?
    /// 主權（主設備＋主權 epoch）：換了主設備＝面板、草稿、待確認的全部收掉。
    var authority = ""
    var localDeviceID: String?
    var enabled = false
    var pod: Pod = .disabled
    var podAccount: String?
    var connect: HandsConnectionPhase = .idle
    /// 每台（HandsBuildController.devices：勾選、那台的回報、網址、連線；沒有設備身分＝空的）。
    var devices: [HandsBuildDevice] = []
    var deviceReasons: [String: String] = [:]
    var localAvailabilityText: String?
    /// 後端算的（HandsBuildController：沒收到回執不寫已套用、已關）。
    var cloudflare: HandsBuildNodeState = .off
    var dev: HandsBuildNodeState = .off
    var statusText = HandsBuildCopy.off
    var statusState: HandsBuildNodeState = .off
    var problem: HandsBuildProblem?
    /// 每台回報的帳號裡的網域（環境登入同一份）。
    var zones: [HandsBuildZone] = []
    var selectedZoneID: String?
    var domain: String?
    /// 等級上限（中央設定，勾選的第一台）。W183 R12：面板上不再選（一律 L2），只拿來比「還沒全開」。
    var level = 1
    /// W183 R8 整合審查（Claude 中）：勾選的設備實際生效的等級（那台回報的：本機核准 ∩ 上限；取最小）。「已連線・…」「記憶」照這個。
    var actualLevel = 1
    /// W183 R12：還沒全開的那台是舊版主機（主設備一律不調高：要先更新那台）。
    var fullNeedsUpdate = false
    var projects: [HandsBuildProject] = []
    /// 勾了、有選好的那個網域的 Cloudflare 授權的設備。
    var authorized: Set<String> = []
    var reported: Set<String> = []
    /// 勾了、網址已經套用到現在這一版的設備。
    var urlReady: Set<String> = []
    /// 已經有網址的設備（換網域要先在卡片內確認）。
    var urlBuilt: Set<String> = []
    var safetyLocked: Set<String> = []
    /// 每台確認過的有效連線（暫時的不算；R8a 審查）。
    var grants: [String: Int] = [:]
    /// 每台的有效連線（含還在確認中的；撤銷看這個）。
    var anyGrants: [String: Int] = [:]
    /// 正在替那台登入、正在套用的設備。
    var loginBusy: Set<String> = []
    var applyBusy: Set<String> = []
    /// ［連線］正在連的那一台。
    var connecting: String?
    /// 這台自己的授權頁開在私訊框、等你按 Authorize。
    var loginOpenHere: URL?
    /// 這台自己的設定流程在跑。
    var busyHere = false
    /// 這台自己的設定流程世代（「…」裡會放寬的動作送出前要一樣）。
    var epochHere: String?

    var hasCloudflareAccount: Bool { !zones.isEmpty }
    var selected: [HandsBuildDevice] { devices.filter(\.selected) }
    /// 主設備（主權）一變＝不適用的面板、草稿、待確認的操作全部收掉（W183 R8a 審查）。
    var roleKey: String { authority + "|" + (localDeviceID ?? "").lowercased() }
    /// 勾選的設備確認過的連線加起來。
    var totalGrants: Int { selected.reduce(0) { $0 + (grants[$1.id] ?? 0) } }
}

/// W183 R8a 審查（GPT-6「套用確認的是點擊當下最新資料」）：畫面畫出來那一刻看到的——主權、設定版本、總開關、網域、勾了哪幾台、這台的流程世代。
/// 按鈕把它帶著走；送出前跟現況比，任何一項變了就不送（「畫面剛更新，再看一次」）；改設定再照這一版做 CAS（主設備那端也比）。
struct HandsBuildSeen: Equatable, Sendable {
    var authority: String
    var configRevision: Int?
    var enabled: Bool
    var zoneID: String?
    var selected: [String]
    var epochHere: String?

    static func of(_ i: HandsBuildInput) -> HandsBuildSeen {
        HandsBuildSeen(authority: i.authority, configRevision: i.configRevision, enabled: i.enabled, zoneID: i.selectedZoneID,
                       selected: i.selected.map { $0.id.lowercased() }.sorted(), epochHere: i.epochHere)
    }

    /// 同一任主設備（「…」裡的收掉、撤銷只看這個）。
    func sameRole(_ other: HandsBuildSeen) -> Bool { authority == other.authority }
}

/// 「套用」時一起存的子網域草稿（先存；存不成就不往下做，草稿留著）。
struct HandsBuildDraft: Equatable, Sendable {
    let label: String
    let device: String
}

struct HandsBuildSnapshot: Equatable, Sendable {
    var gpt: HandsBuildNodeState = .off
    var devices: [HandsBuildDevice] = []
    var deviceReasons: [String: String] = [:]
    var cloudflare: HandsBuildNodeState = .off
    var dev: HandsBuildNodeState = .off
    var statusText = HandsBuildCopy.off
    var statusState: HandsBuildNodeState = .off
    /// 出錯時的一句話、出錯的是哪個節點、那一顆鈕。
    var problem: String?
    var problemPanel: HandsBuildPanel?
    var fix: HandsBuildFix?
    /// 按了做不了的一句話（設定剛被改過…）：面板底下的提示，不算出錯。
    var notice: String?
    /// 第一個要你處理的節點（出錯優先，再來等你）；面板預設跳到這裡。
    var attention: HandsBuildPanel?

    static func derive(_ i: HandsBuildInput) -> HandsBuildSnapshot {
        var s = HandsBuildSnapshot()
        var devices = displayDevices(i)
        if let problem = i.problem {
            if problem.kind == .action {
                s.notice = problem.text
            } else {
                s.problem = problem.text
                s.problemPanel = panel(for: problem)
                s.fix = fix(for: problem)
                // 出錯的是那一台（暫停、安全鎖、連不到）：那一格亮紅。
                if s.problemPanel == .devices, let id = problem.device,
                   let index = devices.firstIndex(where: { HandsHostAuthority.same($0.id, id) }) { devices[index].state = .failed }
            }
        }

        // GPT（Pod）
        let gpt: HandsBuildNodeState
        switch i.pod {
        case .ready, .sleeping(everReady: true): gpt = .done
        case .disabled, .needsLogin, .sleeping(everReady: false): gpt = .waiting
        case .starting: gpt = .working
        case .failed: gpt = .failed
        }

        // Cloudflare（每台的授權與網址；後端算的）。這台自己的授權頁開著＝等你按。
        let cloudflare: HandsBuildNodeState
        if !i.configKnown { cloudflare = .off }
        else if s.problemPanel == .cloudflare { cloudflare = .failed }
        else if i.loginOpenHere != nil { cloudflare = .waiting }
        else if !i.enabled { cloudflare = i.hasCloudflareAccount ? .off : .waiting }   // 關著也能登入（只是登入）
        else { cloudflare = i.cloudflare }

        // ChatGPT Dev（每台的連線；後端算的：確認過的才算）。
        let dev: HandsBuildNodeState = !i.configKnown ? .off : s.problemPanel == .dev ? .failed : i.dev

        s.gpt = gpt
        s.cloudflare = cloudflare
        s.dev = dev
        s.devices = devices
        s.deviceReasons = i.deviceReasons

        // 要你處理的節點：出錯的優先，其次照流程順序第一個等你的（開著、一台都沒勾＝設備）。
        let devicesWaiting = devices.contains { $0.state == .waiting } || (i.configKnown && i.enabled && i.selected.isEmpty)
        let order: [(HandsBuildPanel, Bool)] = [(.gpt, gpt == .waiting), (.devices, devicesWaiting),
                                                (.cloudflare, cloudflare == .waiting), (.dev, dev == .waiting)]
        s.attention = s.problemPanel ?? order.first { $0.1 }?.0

        // 那一行狀態（短）。
        if let availability = i.localAvailabilityText {
            s.statusText = availability
            s.statusState = .waiting
        } else if i.enabled, i.devices.contains(where: { $0.selected && $0.connection == .done }) {
            s.statusText = i.statusText
            s.statusState = i.statusState
        } else if let problem = s.problem {
            s.statusText = HandsBuildCopy.failed(HandsOneSwitchStatus.short(problem))
            s.statusState = .failed
        } else if !i.configKnown {
            s.statusText = HandsBuildCopy.preparing
            s.statusState = .working
        } else if i.enabled, i.loginOpenHere != nil {
            s.statusText = HandsBuildCopy.waitAuthorize
            s.statusState = .waiting
        } else {
            s.statusText = i.statusText
            s.statusState = i.statusState
        }
        return s
    }

    /// 要畫的設備：後端給的（主設備排第一）；讀不到設備身分＝只畫一台「這台」。
    static func displayDevices(_ i: HandsBuildInput) -> [HandsBuildDevice] {
        if !i.devices.isEmpty { return i.devices }
        return [HandsBuildDevice(id: i.localDeviceID ?? "this-device", name: HandsBuildCopy.thisDevice, isPrimary: true, isThisDevice: true,
                                 selected: false, state: .off, subdomain: HandsSettings.defaultSubdomainLabel, url: nil, connection: .off)]
    }

    /// 出錯的是哪個節點（面板顯示那一句話＋那一顆鈕）。按了做不了的（action）不算節點出錯。
    static func panel(for problem: HandsBuildProblem) -> HandsBuildPanel? {
        switch problem.kind {
        case .action: return nil
        case .sync, .paused, .safety, .offline: return .devices
        case .apply, .login: return .cloudflare
        case .step: return problem.step.map { HandsBuildPanel.of($0) } ?? .cloudflare
        case .connect: return .dev
        }
    }

    /// 那一顆鈕：安全鎖＝解除（使用者對那台明確按）；套用、步驟沒成＝再套用；登入沒成＝替那台重新登入；連線沒成＝再連一次。
    static func fix(for problem: HandsBuildProblem) -> HandsBuildFix? {
        switch problem.kind {
        case .safety: return problem.device.map { HandsBuildFix.unlock($0) }
        case .apply:
            // W183 R8 整合審查（Claude 中）：那台還沒登入那個 Cloudflare 帳號＝替它登入（再套用一次只會被 not_authorized_here 拒絕）。
            if problem.step == .authorize, let device = problem.device { return HandsBuildFix.login(device) }
            return HandsBuildFix.retryApply
        case .step:
            // 登入那兩步（cloudflared、授權）出錯＝替那台登入；名字跟步驟訊息、「…」那一列的鈕一致（授權＝「重新授權」）。
            if let step = problem.step, step == .cloudflared || step == .authorize, let device = problem.device {
                return HandsBuildFix.reauthorize(device, step)
            }
            return HandsBuildFix.retryApply
        case .login: return problem.device.map { HandsBuildFix.login($0) }
        case .connect: return HandsBuildFix.reconnect(problem.device)
        case .action, .sync, .paused, .offline: return nil
        }
    }
}

// MARK: - 2. 節點與連線、位置

struct HandsBuildGraph: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case gpt, device, cloudflare, dev }

    struct Node: Equatable, Sendable, Identifiable {
        let id: String
        let kind: Kind
        let label: String
        let sub: String
        let state: HandsBuildNodeState
        let panel: HandsBuildPanel
        /// VoiceOver 念的：名稱（＋設備名）＋狀態。
        var accessibilityLabel: String {
            let name = kind == .device ? "\(label) \(sub)" : label
            return "\(name)：\(HandsBuildCopy.word(state))"
        }
    }

    struct Edge: Equatable, Sendable {
        let from: String
        let to: String
        /// 完成＝品牌色實線；其他＝灰虛線。
        let done: Bool
    }

    let nodes: [Node]
    let edges: [Edge]

    var deviceCount: Int { nodes.filter { $0.kind == .device }.count }

    static let gptID = "gpt", cloudflareID = "cloudflare", devID = "dev"
    static func deviceNodeID(_ id: String) -> String { "device-" + id.lowercased() }

    /// GPT →（每台設備一個節點；只有一台就只畫「主」）→ Cloudflare → ChatGPT Dev。
    static func make(_ s: HandsBuildSnapshot, level: Int, cloudflareSub: String) -> HandsBuildGraph {
        var nodes = [Node(id: gptID, kind: .gpt, label: HandsBuildCopy.gpt, sub: HandsBuildCopy.pod, state: s.gpt, panel: .gpt)]
        for device in s.devices {
            nodes.append(Node(id: deviceNodeID(device.id), kind: .device,
                              label: device.isPrimary ? HandsBuildCopy.primary : HandsBuildCopy.secondary,
                              sub: device.name + (s.deviceReasons[device.id].map { "：\($0)" } ?? ""),
                              state: device.state == .done && s.deviceReasons[device.id] != nil ? device.connection : device.state, panel: .devices))
        }
        let cloudDone = s.cloudflare == .done
        nodes.append(Node(id: cloudflareID, kind: .cloudflare, label: HandsBuildCopy.cloudflare, sub: cloudflareSub, state: s.cloudflare, panel: .cloudflare))
        nodes.append(Node(id: devID, kind: .dev, label: HandsBuildCopy.dev,
                          sub: s.dev == .done ? HandsBuildCopy.connectedShort : s.problemPanel == .dev ? "要重連" : HandsConnectAbility.words(level: level),   // 實際生效的（frame 傳 actualLevel）；W183 R12：寫能力、不寫 L?
                          state: s.dev, panel: .dev))
        var edges: [Edge] = []
        for device in s.devices { edges.append(Edge(from: gptID, to: deviceNodeID(device.id), done: device.selected)) }
        for device in s.devices { edges.append(Edge(from: deviceNodeID(device.id), to: cloudflareID, done: device.selected && cloudDone)) }
        edges.append(Edge(from: cloudflareID, to: devID, done: s.dev == .done))
        return HandsBuildGraph(nodes: nodes, edges: edges)
    }
}

/// 節點的位置（照對照稿 820×250：GPT、設備、Cloudflare、ChatGPT Dev 四欄；設備直向排、間距 110）。
/// 設定頁比對照稿窄：節點寬在 84…120 之間，欄距平均分。
struct HandsBuildLayout: Equatable, Sendable {
    let width: CGFloat
    let height: CGFloat
    let nodeSize: CGSize
    private let columns: [CGFloat]
    private let deviceTops: [CGFloat]
    private let middleTop: CGFloat

    static let nodeHeight: CGFloat = 84
    static let deviceStep: CGFloat = 110

    static func height(devices: Int) -> CGFloat {
        let count = max(devices, 1)
        let span = nodeHeight + CGFloat(count - 1) * deviceStep
        return max(250, span + 56)
    }

    init(width: CGFloat, devices: Int) {
        let count = max(devices, 1)
        let w = max(width, 320)
        self.width = w
        self.height = Self.height(devices: count)
        let margin = max(12, 30 * w / 820)
        let nodeWidth = min(120, max(84, (w - 2 * margin - 3 * 28) / 4))
        nodeSize = CGSize(width: nodeWidth, height: Self.nodeHeight)
        let step = (w - 2 * margin - nodeWidth) / 3
        columns = (0..<4).map { margin + CGFloat($0) * step }
        let span = Self.nodeHeight + CGFloat(count - 1) * Self.deviceStep
        let top = (height - span) / 2
        deviceTops = (0..<count).map { top + CGFloat($0) * Self.deviceStep }
        middleTop = (height - Self.nodeHeight) / 2
    }

    /// 節點左上角（device 帶第幾台）。
    func origin(_ kind: HandsBuildGraph.Kind, index: Int = 0) -> CGPoint {
        switch kind {
        case .gpt: CGPoint(x: columns[0], y: middleTop)
        case .device: CGPoint(x: columns[1], y: deviceTops[min(max(index, 0), deviceTops.count - 1)])
        case .cloudflare: CGPoint(x: columns[2], y: middleTop)
        case .dev: CGPoint(x: columns[3], y: middleTop)
        }
    }

    func frame(_ kind: HandsBuildGraph.Kind, index: Int = 0) -> CGRect { CGRect(origin: origin(kind, index: index), size: nodeSize) }

    /// 每個節點（照 graph 的順序）的框。
    func frames(_ graph: HandsBuildGraph) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        var deviceIndex = 0
        for node in graph.nodes {
            if node.kind == .device { result[node.id] = frame(.device, index: deviceIndex); deviceIndex += 1 }
            else { result[node.id] = frame(node.kind) }
        }
        return result
    }
}

// MARK: - 3. 動作：先算要做的事，再做

/// 畫面按下去之後要做的事（純資料；自測比對每個按鈕叫到後端的哪一個動作）。W183 R8 整合：全部對到 R8c 的 HandsBuildController。
enum HandsBuildEffect: Equatable, Sendable {
    /// 總開關（中央設定；打開時一台都沒勾＝勾主設備；關之前畫面先出確認列）。
    case setEnabled(Bool)
    /// 勾／取消勾那一台（取消勾＝那台關掉、撤銷它的連線；有連線的先在卡片內確認）。
    case select(String, Bool)
    /// 替那台登入 Cloudflare（這台＝這台的環境登入；別台＝經主設備的信箱，登入網址只回到這台的私訊框 Browser）。只是登入。
    case login(String)
    /// 這台自己的授權頁已經在等：在這台（私訊框 Browser）再打開。
    case openLogin(URL)
    case chooseZone(String)
    /// W183 R8a 審查（Claude）：已經有網址之後換網域＝先出卡片內確認列（現有網址與連線會失效），不一鍵換。
    case askZoneChange(String)
    case setSubdomain(String, String)
    /// 「套用」：照畫面看到的那一版（expected）先存子網域草稿（存不成就停）、再請勾選的每台照自己已接受的那一份建網址。
    case apply(expected: Int, drafts: [HandsBuildDraft])
    case setLevel(Int)
    case setProject(String, Bool)
    /// ［連線］＝私訊框的原生［連線］卡（nil＝勾選的每一台逐台排）。
    case connect(String?)
    /// 使用者對那台明確解除安全停機鎖（綁那台回報的事故編號、setupEpoch、撤銷世代）。
    case unlock(String)
    case notice(String)

    var isNotice: Bool { if case .notice = self { return true }; return false }
}

/// W183 R8a 審查：畫面帶著「看到的那一份」按「套用」（接口外；HandsBuildModel 實作）。W183 R8 整合：每台一個子網域草稿。
@MainActor
protocol HandsBuildSeenApplying: AnyObject {
    func applyURLs(seen: HandsBuildSeen, drafts: [HandsBuildDraft])
}

@MainActor
protocol HandsBuildLocalApplying: AnyObject {
    func applyHere(seen: HandsBuildSeen, drafts: [HandsBuildDraft])
}

/// 畫面上的按鈕（每個對到接口的一個動作；自測用記錄的假 model 驗）。
enum HandsBuildUIIntent: Equatable, Sendable {
    case toggle(Bool)
    case pickDevice(String, Bool)
    case loginCloudflare
    /// W183 R8 整合：替那台登入（人在這台，授權存那台）。
    case loginCloudflareFor(String)
    case chooseZone(String)
    case subdomain(String, device: String)
    /// 「套用」：帶著畫面上看到的那一份（seen）與還沒存的子網域草稿；nil＋沒草稿＝接口原本的 applyURLs()。
    case apply(seen: HandsBuildSeen?, drafts: [HandsBuildDraft])
    case applyHere(seen: HandsBuildSeen, drafts: [HandsBuildDraft])
    case level(Int)
    case project(String, Bool)
    case connect(String?)
    /// W183 R8 整合：使用者對那台明確解除安全鎖。
    case unlockSafety(String)

    @MainActor func send(to model: any HandsBuildModeling) {
        switch self {
        case .toggle(let on): model.setEnabled(on)
        case .pickDevice(let id, let selected): model.setDevice(id, selected: selected)
        case .loginCloudflare: model.loginCloudflare()
        case .loginCloudflareFor(let id): model.loginCloudflare(for: id)
        case .chooseZone(let id): model.chooseZone(id)
        case .subdomain(let label, let device): model.setSubdomain(label, for: device)
        case .apply(seen: .none, drafts: let drafts) where drafts.isEmpty: model.applyURLs()
        case .apply(let seen, let drafts):
            // 帶了「看到的那一份」＝只送給會比對的 model（不退回沒比對的 applyURLs）。
            guard let seen, let checking = model as? HandsBuildSeenApplying else { return }
            checking.applyURLs(seen: seen, drafts: drafts)
        case .applyHere(let seen, let drafts):
            (model as? HandsBuildLocalApplying)?.applyHere(seen: seen, drafts: drafts)
        case .level(let level): model.setLevel(level)
        case .project(let id, let selected): model.setProject(id, selected: selected)
        case .connect(let device): model.connect(deviceID: device)
        case .unlockSafety(let id): model.unlockSafety(for: id)
        }
    }
}

extension HandsBuildModel {
    enum Action: Equatable, Sendable {
        case setEnabled(Bool)
        case setDevice(String, Bool)
        /// nil＝這台。
        case loginCloudflare(String?)
        case chooseZone(String)
        /// W183 R8a 審查：換網域的卡片內確認列按了「換網域」（帶確認列畫出來時看到的那一份）。
        case confirmZone(String, seen: HandsBuildSeen)
        case setSubdomain(String, String)
        /// seen＝畫面上看到的（nil＝接口的 applyURLs()，照現況）；drafts＝一起存的子網域。
        case applyURLs(seen: HandsBuildSeen?, drafts: [HandsBuildDraft])
        case setLevel(Int)
        case setProject(String, Bool)
        case connect(String?)
        case unlock(String)
        /// 出錯那一顆鈕（重試／重新登入／解除安全鎖／再連一次）。
        case fix
    }

    /// 算出這個動作要做的事（沒有副作用）。
    static func plan(_ action: Action, _ i: HandsBuildInput) -> [HandsBuildEffect] {
        let snapshot = HandsBuildSnapshot.derive(i)
        func known(_ id: String) -> Bool { i.devices.contains { HandsHostAuthority.same($0.id, id) } }
        // W183 R8c：還沒從主設備拿到設定＝不能改（CAS 沒有「不比對版本」）。登入只是登入（不改設定），這台的可以先登。
        switch action {
        case .loginCloudflare(let target):
            guard let id = target ?? i.localDeviceID else { return [.notice(HandsBuildCopy.notReady)] }
            if HandsHostAuthority.same(id, i.localDeviceID) {
                if let url = i.loginOpenHere { return [.openLogin(url)] }
                if i.busyHere { return [.notice(HandsBuildCopy.busy)] }
                return [.login(id.lowercased())]
            }
            guard i.configKnown, known(id) else { return [.notice(HandsBuildCopy.notReady)] }
            if i.loginBusy.contains(id.lowercased()) { return [] }   // 已經在等那台（授權頁在這台的 Browser）
            return [.login(id.lowercased())]
        default:
            break
        }
        guard i.configKnown, let revision = i.configRevision else { return [.notice(HandsBuildCopy.notReady)] }
        switch action {
        case .loginCloudflare:
            return []

        case .setEnabled(let on):
            return on == i.enabled ? [] : [.setEnabled(on)]

        case .setDevice(let id, let selected):
            guard let device = i.devices.first(where: { HandsHostAuthority.same($0.id, id) }) else { return [] }
            return device.selected == selected ? [] : [.select(device.id.lowercased(), selected)]

        case .chooseZone(let zone):
            guard i.zones.contains(where: { $0.id == zone }), zone != i.selectedZoneID else { return [] }
            // W183 R8a 審查（Claude）：已經有網址（或已連線）之後不一鍵換網域；要換先在卡片內確認（現有網址與連線會失效）。
            guard i.urlBuilt.isEmpty, i.totalGrants == 0 else { return [.askZoneChange(zone)] }
            return [.chooseZone(zone)]

        case .confirmZone(let zone, let seen):
            guard seen == HandsBuildSeen.of(i) else { return [.notice(HandsBuildCopy.changed)] }
            guard i.zones.contains(where: { $0.id == zone }), zone != i.selectedZoneID else { return [] }
            return [.chooseZone(zone)]

        case .setSubdomain(let raw, let device):
            guard let entry = i.devices.first(where: { HandsHostAuthority.same($0.id, device) }) else { return [] }
            guard let label = HandsSettings.validLabel(raw) else { return [.notice(HandsBuildCopy.badLabel)] }
            return label == entry.subdomain ? [] : [.setSubdomain(label, entry.id.lowercased())]

        case .applyURLs(let seen, let drafts):
            // W183 R8a 審查（GPT-6）：確認的一定是畫面上看到的那一份（設定版本、網域、勾選、世代）；變了就不送，請你再看一次。
            if let seen, seen != HandsBuildSeen.of(i) { return [.notice(HandsBuildCopy.changed)] }
            guard i.enabled else { return [.notice(HandsBuildCopy.turnOnFirst)] }
            guard !i.selected.isEmpty else { return [.notice(HandsBuildCopy.pickDevice)] }
            guard i.selectedZoneID != nil else { return [.notice(HandsBuildCopy.pickDomain)] }
            // 子網域草稿跟改子網域同一套把關；不合格＝停在這裡，不往下建網址（存不成的，後端在存的那一步停）。
            var saving: [HandsBuildDraft] = []
            for draft in drafts {
                let saved = plan(.setSubdomain(draft.label, draft.device), i)
                if saved.contains(where: \.isNotice) { return saved }
                if case .setSubdomain(let label, let device)? = saved.first { saving.append(HandsBuildDraft(label: label, device: device)) }
            }
            return [.apply(expected: seen?.configRevision ?? revision, drafts: saving)]

        case .setLevel(let level):
            guard !i.selected.isEmpty else { return [.notice(HandsBuildCopy.pickDevice)] }
            let clamped = min(max(level, 0), HandsSettings.maxLevel)
            return clamped == i.level ? [] : [.setLevel(clamped)]

        case .setProject:
            // W183 R10：專案不再勾（全部可見；面板只顯示）：這個動作什麼都不做（留著相容）。
            return []

        case .connect(let device):
            guard i.enabled else { return [.notice(HandsBuildCopy.turnOnFirst)] }
            guard !i.selected.isEmpty else { return [.notice(HandsBuildCopy.pickDevice)] }
            if let device, !i.selected.contains(where: { HandsHostAuthority.same($0.id, device) }) { return [] }
            // ［連線］＝私訊框的原生［連線］卡（一次性連線意圖只在那張卡上按下才建立；T15 不變）；多台＝逐台排。
            return [.connect(device?.lowercased())]

        case .unlock(let id):
            guard i.safetyLocked.contains(id.lowercased()) else { return [] }
            return [.unlock(id.lowercased())]

        case .fix:
            guard let fix = snapshot.fix else { return [] }
            switch fix {
            case .retryApply: return plan(.applyURLs(seen: nil, drafts: []), i)
            case .login(let id), .reauthorize(let id, _): return plan(.loginCloudflare(id), i)
            case .unlock(let id): return plan(.unlock(id), i)
            case .reconnect(let id): return plan(.connect(id), i)
            }
        }
    }

    /// W183 R8a 審查（GPT-6「子網域存檔失敗仍繼續套用」）：照順序做，任何一步沒成功就停（後面的不做）；回做了幾步、停在哪一步。
    static func runEffects(_ effects: [HandsBuildEffect], perform: (HandsBuildEffect) -> Bool) -> (done: Int, stopped: HandsBuildEffect?) {
        for (index, effect) in effects.enumerated() {
            if !perform(effect) { return (index, effect) }
        }
        return (effects.count, nil)
    }

    /// W183 R8a 審查（GPT-6「…」操作繞過 adapter）：送出那一刻再核一次——主設備（主權）要跟畫面那時一樣；
    /// 會放寬的動作（確認授權、重新授權、重跑、打開授權頁、回呼網址、清通道）這台的流程世代也要一樣。收掉、撤銷、取消不看世代。
    static func detailRefusal(_ action: HandsBuildDetail, shown: HandsBuildSeen, now: HandsBuildSeen) -> String? {
        guard shown.sameRole(now) else { return HandsBuildCopy.changed }
        if action.checksEpoch, shown.epochHere != now.epochHere { return HandsBuildCopy.changed }
        return nil
    }
}

/// 「…」工程細節裡的寫入（W183 R8a 審查）：一律經 HandsBuildModel.detail(_:shown:)，不從畫面直接叫 HandsSetup／HandsState／後端。
/// W183 R8 整合：這台自己的（每台都是自己的主機）＋別台的撤銷全部（經主設備的信箱，只作用在按的時候看到的那一組連線）。
enum HandsBuildDetail: Equatable, Sendable {
    case cancelSetup
    case rerun(HandsSetupStep)
    case openLogin(URL)
    case confirmAuthorization(token: String, domain: String)
    case reauthorize
    case stopPairing
    case revoke(String)
    case revokeAll
    case setCallbacks([String])
    case deleteTunnels(Set<String>)
    /// 別台的撤銷全部（HandsBuildController.revokeAll(for:)）。
    case revokeDevice(String)

    var checksEpoch: Bool {
        switch self {
        case .cancelSetup, .stopPairing, .revoke, .revokeAll, .revokeDevice: false
        default: true
        }
    }
}

// MARK: - adapter（R8c 的多設備後端＋這台自己的狀態）

@MainActor
final class HandsBuildModel: ObservableObject, HandsBuildModeling, HandsBuildSeenApplying, HandsBuildLocalApplying {
    static let shared = HandsBuildModel()

    /// R8c 的多設備後端（設定、每台的回報、信箱、逐台連線）。
    let build: HandsBuildController
    let hands: HandsState
    let service: ChatGPTHandsService
    let setup: HandsSetup
    let accounts: CloudflareAccountsStore
    let connectFlow: HandsConnectFlow
    let tap: ChatGPTTap

    /// 按了做不了的一句話（下一次按別的就清掉）。
    @Published private(set) var notice: String?
    @Published private(set) var podAccountValue: String?
    /// W183 R8a 審查（Claude）：已經有網址之後選了別的網域＝等你在卡片內確認（現有網址與連線會失效）。
    @Published private(set) var pendingZone: String?
    /// W183 R5／R8 整合（使用者「點開啟時卡很久」）：開關按下去先照按的樣子顯示（設定版本還是按的時候那一版、後端沒說做不了才算）；
    /// 這段時間開關停用（上一個動作還沒回來）。
    @Published private(set) var pendingEnabled: (value: Bool, revision: Int)?

    private var watchers: [AnyCancellable] = []
    private var lastAccountRead = Date.distantPast

    init(build: HandsBuildController = .shared, hands: HandsState = .shared, service: ChatGPTHandsService = .shared, setup: HandsSetup = .shared,
         accounts: CloudflareAccountsStore = .shared, connect: HandsConnectFlow = .shared, tap: ChatGPTTap = .shared) {
        self.build = build
        self.hands = hands
        self.service = service
        self.setup = setup
        self.accounts = accounts
        self.connectFlow = connect
        self.tap = tap
        // 任何一個來源一變，畫面就重算（都在主執行緒發佈；接到下一輪再轉發）。
        let sources: [AnyPublisher<Void, Never>] = [
            build.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            hands.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            setup.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            accounts.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            connect.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            tap.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        for source in sources {
            watchers.append(source.receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            })
        }
    }

    /// Coder 的專案（不含助理那個）：「…」的診斷與舊自測用；ChatGPT Dev 面板的專案是每台自己回報的（build.projects）。
    struct ProjectChoice { let id: UUID; let name: String }

    static func availableProjects() -> [ProjectChoice] {
        guard let engine = CLISessionsTermination.model?.localLiveForBridge else { return [] }
        let doc = engine.doc
        return doc.projects.filter { $0.id != doc.assistantProjectID }.map { ProjectChoice(id: $0.id, name: $0.name) }
    }

    // MARK: 收集現況

    var input: HandsBuildInput {
        var i = HandsBuildInput()
        let b = build
        i.localDeviceID = b.localID
        i.pod = Self.pod(tap.connection)
        i.podAccount = podAccountValue
        i.connect = connectFlow.phase
        i.loginOpenHere = setup.loginURL
        i.busyHere = setup.busy
        i.epochHere = setup.setupEpoch
        i.devices = b.devices
        i.localAvailabilityText = b.localAvailabilityText
        for device in i.devices where device.selected && device.connection != .done {
            i.deviceReasons[device.id] = b.connectionReason(device.id)
        }
        i.problem = b.problemInfo
        i.zones = b.zones
        guard let config = b.config else { return i }   // 還沒從主設備拿到設定：畫面只看不改（準備中…）
        i.configKnown = true
        i.configRevision = config.configRevision
        i.authority = config.primaryID.lowercased() + "#\(config.authorityEpoch)"
        i.enabled = config.enabled
        i.cloudflare = b.cloudflareState
        i.dev = b.devState
        i.statusText = b.statusText
        i.statusState = b.statusState
        i.selectedZoneID = b.selectedZoneID
        i.domain = config.domain
        i.level = b.level
        i.actualLevel = b.actualLevel
        i.fullNeedsUpdate = b.fullNeedsUpdate   // W183 R12
        i.projects = b.projects
        i.connecting = b.connecting
        for device in i.devices {
            let id = device.id.lowercased()
            if b.hasFreshReport(id) { i.reported.insert(id) }
            if device.selected, b.authorized(id) { i.authorized.insert(id) }
            if device.selected, b.urlReady(id) { i.urlReady.insert(id) }
            if b.hasURL(id) { i.urlBuilt.insert(id) }
            if b.safetyLocked(id) { i.safetyLocked.insert(id) }
            i.grants[id] = b.confirmedGrants(id)
            i.anyGrants[id] = b.grants(id)
            if case .running? = b.loginWork[id] { i.loginBusy.insert(id) }
            if case .running? = b.applyWork[id] { i.applyBusy.insert(id) }
        }
        return i
    }

    static func pod(_ connection: TapConnection) -> HandsBuildInput.Pod {
        guard ChatGPTTap.isEnabled else { return .disabled }
        switch connection {
        case .off: return .sleeping(everReady: ChatGPTTap.hasBeenReady)
        case .starting: return .starting
        case .needsLogin: return .needsLogin
        case .ready: return .ready
        case .sleeping: return .sleeping(everReady: ChatGPTTap.hasBeenReady)
        case .failed(let message): return .failed(message)
        }
    }

    var snapshot: HandsBuildSnapshot { HandsBuildSnapshot.derive(input) }

    /// 畫面一次要的全部（每次重畫只收集一次）。
    struct Frame: Equatable {
        let input: HandsBuildInput
        let snapshot: HandsBuildSnapshot
        let graph: HandsBuildGraph
    }

    static func frame(_ i: HandsBuildInput) -> Frame {
        let s = HandsBuildSnapshot.derive(i)
        let sub = i.domain ?? (i.hasCloudflareAccount ? HandsBuildCopy.domainUnknown : HandsBuildCopy.notLoggedIn)
        return Frame(input: i, snapshot: s, graph: HandsBuildGraph.make(s, level: i.actualLevel, cloudflareSub: sub))   // W183 R8 整合審查：實際生效的
    }

    var frame: Frame { Self.frame(input) }

    // MARK: HandsBuildModeling

    var enabled: Bool { pendingSwitch ?? input.enabled }

    /// 按下去、後端還沒回來的開關（設定版本換了＝回來了；後端說做不了＝不算）。
    private var pendingSwitch: Bool? {
        guard let pending = pendingEnabled, pending.revision == build.config?.configRevision, build.actionProblem == nil else { return nil }
        return pending.value
    }
    var statusText: String { snapshot.statusText }
    var statusState: HandsBuildNodeState { snapshot.statusState }
    var problem: String? { snapshot.problem }
    var gptState: HandsBuildNodeState { snapshot.gpt }
    var podAccount: String? { podAccountValue }
    var devices: [HandsBuildDevice] { snapshot.devices }
    var cloudflareState: HandsBuildNodeState { snapshot.cloudflare }
    var zones: [HandsBuildZone] { input.zones }
    var selectedZoneID: String? { input.selectedZoneID }
    var devState: HandsBuildNodeState { snapshot.dev }
    var level: Int { input.level }
    var projects: [HandsBuildProject] { input.projects }

    func setEnabled(_ on: Bool) { run(.setEnabled(on)) }
    func setDevice(_ id: String, selected: Bool) { run(.setDevice(id, selected)) }
    func loginCloudflare() { run(.loginCloudflare(nil)) }
    func loginCloudflare(for deviceID: String) { run(.loginCloudflare(deviceID)) }
    func chooseZone(_ id: String) { run(.chooseZone(id)) }
    func setSubdomain(_ label: String, for deviceID: String) { run(.setSubdomain(label, deviceID)) }
    func applyURLs() { run(.applyURLs(seen: nil, drafts: [])) }
    func setLevel(_ level: Int) { run(.setLevel(level)) }
    func setProject(_ id: String, selected: Bool) { run(.setProject(id, selected)) }
    func connect(deviceID: String?) { run(.connect(deviceID)) }
    func unlockSafety(for deviceID: String) { run(.unlock(deviceID)) }
    func viewDidAppear() { build.viewDidAppear() }

    // MARK: 接口以外（畫面的工程細節與確認列用）

    /// 出錯那一顆鈕。
    func fix() { run(.fix) }
    /// 開關能不能按（還沒從主設備拿到設定＝不能：R8c 的 CAS 要帶版本；上一個動作還沒回來＝不能）。
    var canToggle: Bool { input.configKnown && pendingSwitch == nil }
    /// 開發者模式那一句（Pod 平常在聊天頁，讀不到開關；已連上＝一定開著）。
    var devModeText: String { snapshot.dev == .done ? HandsBuildCopy.devModeOn : HandsBuildCopy.devModeLater }
    func clearNotice() { notice = nil }

    /// 畫面畫出來那一刻看到的（按鈕帶著走；送出前比對）。
    var seen: HandsBuildSeen { HandsBuildSeen.of(input) }

    /// 「套用」（帶著看到的那一份與子網域草稿）：看到的變了＝不送；子網域沒存成＝不往下建網址。
    func applyURLs(seen: HandsBuildSeen, drafts: [HandsBuildDraft]) { run(.applyURLs(seen: seen, drafts: drafts)) }
    /// 本機入口不替使用者存草稿（副設備存檔會去主設備）；也不偷偷換一版。
    func applyHere(seen shown: HandsBuildSeen, drafts: [HandsBuildDraft]) {
        let current = input
        if let refusal = Self.localApplyRefusal(shown: shown, current: current, drafts: drafts) {
            notice = refusal
            return
        }
        guard let revision = shown.configRevision else { return }
        notice = nil
        build.applyHere(expected: .init(authority: shown.authority, revision: revision), setupEpoch: shown.epochHere)
    }

    static func localApplyRefusal(shown: HandsBuildSeen, current: HandsBuildInput, drafts: [HandsBuildDraft]) -> String? {
        guard shown == HandsBuildSeen.of(current), current.configKnown, shown.configRevision != nil else { return HandsBuildCopy.changed }
        guard drafts.isEmpty else { return "子網域有未儲存修改；只套用這台不會儲存草稿" }
        guard let local = current.localDeviceID, shown.enabled, shown.zoneID != nil,
              shown.selected.contains(local.lowercased()) else { return "先勾選這台並選好網域" }
        guard !current.busyHere, current.applyBusy.isEmpty else { return "設定正在跑，等一下再按" }
        return nil
    }
    /// 換網域的確認列：「換網域」／「取消」。
    func confirmZoneChange(seen: HandsBuildSeen) {
        guard let zone = pendingZone else { return }
        run(.confirmZone(zone, seen: seen))
    }
    func dismissZoneChange() { pendingZone = nil }

    /// 主設備換了：待確認的操作與一句話提示收掉（畫面那邊收面板與草稿）。
    func resetForRoleChange() {
        pendingZone = nil
        notice = nil
    }

    /// 「…」裡的寫入：送出那一刻再核一次（detailRefusal）；回 nil＝做了，否則是做不了的原因（畫面顯示）。
    @discardableResult
    func detail(_ action: HandsBuildDetail, shown: HandsBuildSeen) -> String? {
        if let refusal = Self.detailRefusal(action, shown: shown, now: seen) {
            notice = refusal
            return refusal
        }
        // W183 R8 整合審查（GPT-6 高）：「…」裡的「在這台打開授權頁」也只開這台自己這一輪的（替別台登入的那一輪不開）。
        if case .openLogin(let url) = action, !setup.isLocalLoginPage(url) {
            notice = HandsBuildCopy.changed
            return HandsBuildCopy.changed
        }
        notice = nil
        switch action {
        case .cancelSetup:
            setup.cancel()
            connectFlow.cancel(reason: "cancelled")   // W183 R6a：取消＝這次連線一起作廢
        case .rerun(let step):
            _ = setup.run(step, trigger: .user)
        case .openLogin(let url):
            HandsSetup.openLoginPage(url, returnTo: .tap, onCancel: { [weak self] in self?.setup.cancel() })
        case .confirmAuthorization(let token, let domain):
            do { try setup.confirmAuthorization(token: token, domain: domain) } catch { return String(describing: error) }
        case .reauthorize:
            HandsSetup.returnAfterAuthorize = .tap   // 私訊鈕關掉時授權頁退回 OS 瀏覽器（設定浮層先關）；授權完帶回這頁
            if let refusal = setup.reauthorize(trigger: .user) {
                HandsSetup.returnAfterAuthorize = nil
                return refusal.description
            }
        case .stopPairing:
            hands.stopPairing()
        case .revoke(let id):
            hands.revokeGrant(id)
        case .revokeAll:
            hands.revokeAll()
        case .setCallbacks(let urls):
            if !hands.setCallbacks(urls) { return HandsBuildCopy.saveFailed(hands.lastError) }
        case .deleteTunnels:
            return nil   // 要回呼：走 deleteUnusedTunnels(_:shown:done:)
        case .revokeDevice(let id):
            build.revokeAll(for: id)
        }
        return nil
    }

    /// 清沒用到的通道（確認列之後）：同一道再核；刪之前 HandsSetup 還會每一條再查一次。
    func deleteUnusedTunnels(_ ids: Set<String>, shown: HandsBuildSeen, done: @escaping (Int, Int) -> Void) -> String? {
        if let refusal = Self.detailRefusal(.deleteTunnels(ids), shown: shown, now: seen) {
            notice = refusal
            return refusal
        }
        return setup.deleteUnusedTunnels(ids, completion: done) ? nil : "設定進行中；等一下再清"
    }

    private func run(_ action: Action) {
        execute(Self.plan(action, input))
    }

    /// 照順序做；任何一步沒成功就停，一句話留在面板上。
    private func execute(_ effects: [HandsBuildEffect]) {
        notice = nil
        _ = Self.runEffects(effects) { perform($0) }
    }

    /// 做一步（都叫 R8c 的 HandsBuildController；改設定在背景照畫面看到的版本送，存不成的原因回到 build.actionProblem）；回 false＝沒成功。
    private func perform(_ effect: HandsBuildEffect) -> Bool {
        switch effect {
        case .setEnabled(let on):
            pendingEnabled = build.config.map { (on, $0.configRevision) }
            build.setEnabled(on)
        case .select(let id, let selected):
            build.setDevice(id, selected: selected)
        case .login(let id):
            // 這台：設定頁不關、不跳頁，授權頁在這台的私訊框 Browser 開；私訊鈕關掉時才退回 OS 瀏覽器（授權完帶回這一頁）。
            if HandsHostAuthority.same(id, build.localID) { HandsSetup.returnAfterAuthorize = .tap }
            build.loginCloudflare(for: id)
        case .openLogin(let url):
            // W183 R8 整合審查（GPT-6 高）：只開這台自己這一輪的授權頁（替別台登入的那一輪、晚到的、別輪的都不開；不收裸網址）。
            guard setup.isLocalLoginPage(url) else { notice = HandsBuildCopy.changed; return false }
            HandsSetup.openLoginPage(url, returnTo: .tap, onCancel: { [weak self] in self?.setup.cancel() })
        case .chooseZone(let zone):
            build.chooseZone(zone)
            pendingZone = nil
        case .askZoneChange(let zone):
            pendingZone = zone
        case .setSubdomain(let label, let device):
            build.setSubdomain(label, for: device)
        case .apply(let expected, let drafts):
            build.applyURLs(saving: drafts.map { HandsBuildConfigOp.subdomain(device: $0.device, label: $0.label) }, expected: expected)
        case .setLevel(let level):
            build.setLevel(level)
        case .setProject(let id, let selected):
            build.setProject(id, selected: selected)
        case .connect(let device):
            build.connect(deviceID: device)
        case .unlock(let id):
            build.unlockSafety(for: id)
        case .notice(let text):
            notice = text
            return false
        }
        return true
    }

    // MARK: 更新（畫面看得到時）

    /// 畫面出現：對一次現況；後端一陣子內同步快一點（W183 R8c 審查：平常不熱問）。
    func appear() {
        hands.refresh()
        accounts.reload()
        setup.refreshDerived()
        build.viewDidAppear()
    }

    /// 狀態會自己變（關口起來、配對完成、別台回報）：畫面開著時每 3 秒對一次這台的現況（不跑任何指令）；每分鐘再請後端快一點同步；
    /// Pod 帳號最多 30 秒讀一次。
    func watch() async {
        appear()
        await readPodAccount()
        var tick = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            tick += 1
            setup.refreshDerived()
            hands.refresh()
            if tick % 20 == 0 { build.viewDidAppear() }
            await readPodAccount()
        }
    }

    /// Pod 目前帳號（觀測值；只在畫面上顯示，不寫檔、不進日誌）。Pod 沒開好＝不讀、沿用上次的。
    private func readPodAccount() async {
        guard tap.connection == .ready, Date().timeIntervalSince(lastAccountRead) >= 30 else { return }
        lastAccountRead = Date()
        guard let account = try? await tap.account() else { return }
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String((email.isEmpty ? name : email).prefix(120))
        podAccountValue = value.isEmpty ? nil : value
    }
}

// MARK: - W183 R8a 審查（GPT-6「Computer Use 仍能代按這張安全設定卡」）

/// ChatGPT build 這張卡（開關、設備、網域、子網域、套用、等級、專案、［連線］、確認列、「…」裡的撤銷與重新授權）在畫面上＝敏感：
/// 跟私訊框的授權頁、［連線］卡同一道閘門（BrowserSensitivePageGate.isActive 經 HandsConnectPresenter.anySensitive 讀這裡）——
/// 卡片一出來就撤銷以 TATWO 自己為目標的 Computer Use（全權也一樣），之後截圖、讀 AX、每一個輸入、回傳結果前都再看一次；卡片收起來才恢復。
/// 內建瀏覽器那條與別的 App 不受影響。人用滑鼠、鍵盤照常。
@MainActor
enum HandsBuildScreenGate {
    private static var shown: Set<UUID> = []

    static var isShown: Bool { !shown.isEmpty }

    /// 卡片出現（每個畫面一個 token；重複出現不重複算）。
    static func appeared(_ token: UUID) {
        shown.insert(token)
        BrowserSensitivePageGate.pageAppeared()   // 以 TATWO 自己為目標的 Computer Use 馬上撤銷
    }

    static func disappeared(_ token: UUID) {
        shown.remove(token)
    }
}
