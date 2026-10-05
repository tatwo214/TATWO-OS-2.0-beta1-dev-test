import Foundation

// W183 R6a：「一個開關」的流程與那一行狀態（docs/specs/183-chatgpt-hands/one-switch.md）。
// 使用者 09-28：「到目前為止的流程我非常不滿意 太複雜」→「先停，重做成一個開關」；「有可能都不離開設定頁面？」。
// TAP › ChatGPT 只剩一列「ChatGPT 手腳 ⓘ｜一行狀態｜開關」＋預設收起的「詳細」。W183 R8a：畫面改成「ChatGPT build」節點流程
// （New/ChatGPTBuildSection.swift、Facade/HandsBuildModel.swift）；這裡的判斷與動作照用（狀態字由 HandsBuildSnapshot 換成節點的短字）。
// 這裡只放判斷與動作（不碰畫面），主機與副設備同一套字、同一個開關：
// - 狀態只有：已關閉｜準備中…｜等你在私訊框按一下｜連線中…｜已連線・L1｜出錯：〈一句話〉＋一顆鈕（重試／重新授權／再連一次；
//   副設備當了主機交回不成功＝交回主設備）。不再顯示「第 N 步」。
//   例外（寫進報告）：Cloudflare 授權後「用〈帳號〉的〈網域〉？」這一下還在 TAP 那一列下面按（私訊框的頁面是 R5b／R6b 的檔），
//   那時的字是「等你在這裡按一下」。
// - 連線那一段（私訊框的［連線］卡、連接器、配對、第一次 /mcp）看 HandsConnectFlow.shared 的 phase／problem（R6b 實作）。

enum HandsOneSwitchStatus: Equatable, Sendable {
    /// 在等使用者按的是哪一下。
    enum Waiting: Equatable, Sendable {
        /// 私訊框的 Cloudflare 授權頁（Authorize）。
        case login
        /// 授權後確認帳號與網域（TAP 那一列下面的「用這個」）。
        case confirm
        /// 私訊框的［連線］卡（HandsConnectFlow）。
        case connect
    }

    /// 出錯時那一顆鈕。
    enum Action: String, Equatable, Sendable, CaseIterable {
        case retry, reauthorize, reconnect, handBack
        var title: String {
            switch self {
            case .retry: "重試"
            case .reauthorize: "重新授權"
            case .reconnect: "再連一次"
            case .handBack: "交回主設備"
            }
        }
    }

    case off
    case preparing
    case waiting(Waiting)
    case connecting
    case connected(level: Int)
    case failed(String, Action)

    /// 那一行狀態的字（規格的六種）。
    var text: String {
        switch self {
        case .off: Self.offText
        case .preparing: Self.preparingText
        case .waiting(.confirm): Self.waitingHereText
        case .waiting: Self.waitingText
        case .connecting: Self.connectingText
        case .connected(let level): "已連線・L\(min(max(level, 0), HandsSettings.maxLevel))"
        case .failed(let message, _): "出錯：" + message
        }
    }

    static let offText = "已關閉"
    static let preparingText = "準備中…"
    static let waitingText = "等你在私訊框按一下"
    static let waitingHereText = "等你在這裡按一下"
    static let connectingText = "連線中…"

    /// 出錯時的那一顆鈕（其他狀態沒有鈕）。
    var action: Action? { if case .failed(_, let action) = self { return action }; return nil }

    enum Tone: Equatable, Sendable { case idle, busy, waiting, good, bad }
    var tone: Tone {
        switch self {
        case .off: .idle
        case .preparing, .connecting: .busy
        case .waiting: .waiting
        case .connected: .good
        case .failed: .bad
        }
    }

    // MARK: 判斷

    /// 本機（這台是主機、或還沒選主機的主設備）判斷要的東西。
    struct LocalInput: Equatable, Sendable {
        var enabled: Bool
        var level: Int
        var busy: Bool
        var setup: HandsSetupState
        /// 私訊框的授權頁開著（HandsSetup.loginURL）。
        var loginOpen: Bool
        /// 設定流程被擋住的原因（上一個 cloudflared 還沒結束、清不掉暫存檔）。
        var blocked: String?
        var phase: ChatGPTHandsService.Phase
        var activeGrants: Int
        var connect: HandsConnectionPhase
        var connectProblem: String?
        /// 副設備當了主機、交回主設備不成功（或開關關著還登記是主機）。
        var handback: String?
        /// W183 R8a 審查（GPT-6）：暫時的 grant（連線意圖換到、還沒確認）；activeGrants 只算確認過的。
        var provisionalGrants: Int = 0
    }

    /// 副設備看主機（主設備）的狀態。
    struct RemoteInput: Equatable, Sendable {
        var status: HandsRemoteStatus?
        /// 按了開關、主機還沒回覆。
        var pendingEnabled: Bool?
        var stale: Bool
        var problem: String?
        var connect: HandsConnectionPhase
        var connectProblem: String?
    }

    static let needsLoginText = "Cloudflare 還沒授權"
    static let cleanupText = "上次取消授權還沒清完"
    static let unreachableText = "連不到主設備"
    static let cancelledText = "已取消"

    static func forLocal(_ s: LocalInput) -> HandsOneSwitchStatus {
        if let handback = s.handback { return .failed(handback, .handBack) }
        if !s.enabled && !s.busy { return .off }
        if let blocked = s.blocked { return .failed(blocked, .retry) }
        // 正在跑：只分「授權頁開著等你按」與「準備中」（跑的途中不顯示上一輪的錯）。
        if s.busy { return s.loginOpen ? .waiting(.login) : .preparing }
        if s.setup.discard != nil { return .failed(cleanupText, .reauthorize) }
        let steps = HandsSetupStep.runOrder.filter { $0 != .remember && $0 != .pairing }
        for step in steps {
            let entry = s.setup.step(step)
            if entry.status == .done { continue }
            let phaseFailure: String? = { if case .failed(let reason) = s.phase { return reason }; return nil }()
            // W183 R8c：已經登入、在等選網域（登入只是登入）不算「還沒登入」。
            // 等選網域、按「套用」＝等你在這裡按一下（ChatGPT build 的 Cloudflare 節點）。
            let choosing = step == .authorize && entry.message == HandsSetup.chooseDomainMessage
            return pending(step: step, status: entry.status, message: entry.message, loginOpen: s.loginOpen,
                           awaitingConfirm: s.setup.awaitingConfirmation || choosing,
                           needsLogin: step == .authorize && !s.setup.awaitingConfirmation && !choosing,
                           phaseFailure: phaseFailure)
        }
        switch s.phase {
        case .failed(let reason): return .failed(reason, .retry)
        case .starting, .stopped: return .preparing
        case .running: break
        }
        return connection(grants: s.activeGrants, provisional: s.provisionalGrants, level: s.level, connect: s.connect, problem: s.connectProblem)
    }

    static func forRemote(_ r: RemoteInput) -> HandsOneSwitchStatus {
        guard let status = r.status else {
            // 還沒拿到主機的狀態：還在問＝準備中；問不到＝出錯＋重試（畫面也會強制再問一次，不再卡「讀取主機狀態…」）。
            if r.problem != nil { return .failed(unreachableText, .retry) }
            return .preparing
        }
        if r.pendingEnabled == true, !status.enabled { return .preparing }
        guard status.enabled || status.setupBusy else { return .off }
        if r.stale { return .failed(unreachableText, .retry) }
        if status.setupBusy { return status.loginURL != nil ? .waiting(.login) : .preparing }
        if status.cleanupPending { return .failed(cleanupText, .reauthorize) }
        let steps = HandsSetupStep.runOrder.filter { $0 != .remember && $0 != .pairing }
        for step in steps {
            // 主機沒給步驟（舊版主機）＝不看步驟，只看關口。
            guard let entry = status.setup.first(where: { $0.step == step.rawValue }) else { continue }
            let code = HandsSetupStatus(rawValue: entry.status)
            if code == .done { continue }
            return pending(step: step, status: code ?? .failed, message: entry.displayMessage, loginOpen: status.loginURL != nil,
                           awaitingConfirm: status.authorizedNeedsConfirm || entry.code == "authorize.choose_domain",
                           needsLogin: entry.code == "authorize.needs_login",
                           phaseFailure: status.phaseState == "failed" ? status.phaseText : nil)
        }
        switch status.phaseState {
        case "failed": return .failed(status.phaseText, .retry)
        case "running": break
        default: return .preparing
        }
        return connection(grants: status.grants.filter { !$0.provisional }.count, provisional: status.grants.filter(\.provisional).count,
                          level: status.level, connect: r.connect, problem: r.connectProblem)
    }

    /// 第 1–6 步有一步還沒做完（沒在跑的時候）。
    private static func pending(step: HandsSetupStep, status: HandsSetupStatus, message: String, loginOpen: Bool,
                                awaitingConfirm: Bool, needsLogin: Bool, phaseFailure: String?) -> HandsOneSwitchStatus {
        switch status {
        case .done, .running: return .preparing
        case .waitingUser:
            if step == .authorize {
                if loginOpen { return .waiting(.login) }
                if awaitingConfirm { return .waiting(.confirm) }
                if needsLogin { return .failed(needsLoginText, .reauthorize) }
            }
            return .failed(short(message), .retry)
        case .failed:
            return .failed(short(message), step == .authorize ? .reauthorize : .retry)
        case .pending:
            // 上次中斷（App 重開）：開關開著會自動接著做。其他（取消了、換了網域、token 不見了…）要按一下。
            if message.isEmpty || message == HandsSetup.interruptedMessage { return .preparing }
            // 關口那兩步（App 剛開、關口還沒起來）：關口失敗就寫關口的原因；不是取消的＝關口會自己起來（每 5 秒看一次設定）。
            if step == .start || step == .url {
                if let phaseFailure { return .failed(phaseFailure, .retry) }
                if !message.hasPrefix("已取消") { return .preparing }
            }
            return .failed(short(message), step == .authorize ? .reauthorize : .retry)
        }
    }

    /// 關口起來之後：連線那一段（R6b 的 HandsConnectFlow）。已經有有效的 grant＝已連線（重開後沿用既有 grant）。
    /// W183 R8a 審查（GPT-6）：只算確認過的 grant；只有暫時的（別台正在連、還沒確認）＝連線中，不打勾、不寫「已連線」。
    private static func connection(grants: Int, provisional: Int = 0, level: Int, connect: HandsConnectionPhase, problem: String?) -> HandsOneSwitchStatus {
        if grants > 0 {
            if connect == .verifying { return .connecting }
            return .connected(level: level)
        }
        switch connect {
        case .idle, .waitingTap, .waitingUser, .waitingPairing, .connected: return provisional > 0 ? .connecting : .waiting(.connect)
        case .creatingConnector, .verifying: return .connecting
        case .needsManual: return .failed(problem.map(short) ?? "自動連不上 ChatGPT", .reconnect)
        case .refused: return .failed(problem.map(short) ?? "這次連線對不上，已經作廢", .reconnect)
        case .failed: return .failed(problem.map(short) ?? "連線沒有成功", .reconnect)
        }
    }

    /// 一句話：取到第一個「；」或「——」之前（詳細裡看得到全文）。
    static func short(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        for mark in ["；", "——"] {
            if let range = text.range(of: mark) { text = String(text[..<range.lowerBound]) }
        }
        // W183 R7a：那一行沒有步驟編號（編號只在「詳細」的步驟清單）：「第 N 步（X）」只留「X」、單獨的「第 N 步」改成「前一步」。
        text = text.replacingOccurrences(of: #"第\s*[0-9]+\s*步（([^）]*)）"#, with: "「$1」", options: .regularExpression)
            .replacingOccurrences(of: #"第\s*[0-9]+\s*步"#, with: "前一步", options: .regularExpression)
        if text.hasPrefix("已取消") { return cancelledText }
        return text.isEmpty ? "設定停下來了" : String(text.prefix(80))
    }

    /// 那一列要不要自動叫出私訊框的［連線］卡（狀態在等連線、這一段還沒開始）。
    static func shouldOffer(_ status: HandsOneSwitchStatus, connect: HandsConnectionPhase) -> Bool {
        status == .waiting(.connect) && connect == .idle
    }
}

/// W183 R6a：開關的動作（畫面叫這裡；自測也叫同一份）。
@MainActor
enum HandsOneSwitch {
    /// 打開（這台是主機、或還沒選主機的主設備；副設備當主機也一樣）：開關打開、照標準流程一路做——
    /// 沒登入 Cloudflare 就直接在私訊框開授權頁（allowLogin true），不再停下來導去環境登入（帳號照樣記在環境登入）。
    static func turnOn(setEnabled: (Bool) -> Void, setup: HandsSetup) {
        setEnabled(true)
        setup.runAll(trigger: .user, allowLogin: true)
    }

    /// 關掉（卡片內確認之後）：先取消（世代換掉，進行中的舊流程不會把關掉的又打開）→ 關開關（撤銷全部 grant）→
    /// turnedOff（取消這次連線 HandsConnectFlow.cancel、副設備是主機＝交回主設備）→ 叫關口馬上看。
    static func turnOff(setEnabled: (Bool) -> Void, setup: HandsSetup, serviceChanged: () -> Void) {
        setup.cancel()
        setEnabled(false)
        setup.turnedOff()
        serviceChanged()
    }

    /// 出錯那一列的「重試」：從第一個還沒完成的步驟接著做（使用者按的＝可以開授權頁；安全停機的重試鎖也由這一下解除）。
    static func retry(setup: HandsSetup) {
        // W183 R8c（GPT-6 必改 4）：設定流程叫關口一律保留安全鎖；安全停機那一列的「重試」是使用者對這台明確按的＝這一下才解除。
        if case .failed(ChatGPTHandsService.tamperedText) = setup.dependencies.servicePhase() { setup.dependencies.unlockSafety() }
        setup.runAll(trigger: .user, allowLogin: true)
    }

    /// 副設備當了主機、交回主設備沒成功＝出錯＋「交回主設備」（開關開沒開都可以按）。
    /// 看「交回真的沒成功」——這個行程記的原因，或存在 setup.json 的第 1 步失敗（重開後也看得到）；剛認領、開關關著＝「已關閉」。
    /// W183 R8 整合：從 HandsBuildModel 搬來（ChatGPT build 的卡片接到多設備後端之後不再用「交回」；舊的單主機狀態字與自測照用）。
    static func handback(problem: String?, isSecondary: Bool, local: String?, settings: HandsSettings, hostStep: HandsSetupStepState, busy: Bool) -> String? {
        if let problem { return HandsOneSwitchStatus.short(problem) }
        guard isSecondary, let local, HandsHostAuthority.same(settings.hostDeviceID, local), !settings.enabled, !busy,
              hostStep.status == .failed else { return nil }
        return HandsOneSwitchStatus.short(hostStep.message)
    }

    /// 「重新授權」：上次取消授權沒清完＝接著清（冪等）；否則照流程接著做，沒有可用的授權就在私訊框開授權頁。
    static func reauthorize(setup: HandsSetup) {
        if setup.snapshot.discard != nil, setup.reauthorize(trigger: .user) == nil { return }
        setup.runAll(trigger: .user, allowLogin: true)
    }
}
