import Combine
import Foundation

// W183 R1／R1b：給 R3 畫面（TAP › ChatGPT「ChatGPT 手腳」、環境登入、ChatGPT Space 狀態小鈕）用的可觀察狀態。
// 本房只提供狀態與動作，不做畫面。所有寫入走 HandsService（app/settings.json 0600、原子寫入、改設定的副作用）。
// 配對碼只出現在這裡（確認卡）與 Island，不經關口。確認卡文案：「授權這筆連線」，不宣稱驗證了 ChatGPT 帳號（v2 §3、v3 V15）。

@MainActor
final class HandsState: ObservableObject {
    static let shared = HandsState(service: .shared)

    @Published private(set) var settings: HandsSettings
    /// 配對窗口（使用者按「開始配對」才開；nil＝關著）。
    @Published private(set) var pairingWindowExpiresAt: Date?
    /// 確認卡：callback 網域、等級、交易編號（網頁上顯示同一組）、8 碼配對碼、這筆 grant 會拿到的專案與記憶範圍。
    @Published private(set) var pendingPairing: HandsPairingCard?
    @Published private(set) var grants: [HandsGrantSummary] = []
    @Published private(set) var lastError: String?

    let service: HandsService

    init(service: HandsService) {
        self.service = service
        self.settings = service.settings.load()
        self.grants = service.auth.grants()
        service.auth.onPairingCard = { [weak self] card in
            // W183 R6b：綁連線意圖（私訊框［連線］）的卡不上設定頁、不上 Island：配對碼只在按［連線］那台的私訊框卡片（HandsConnectFlow）。
            if card?.attemptID != nil { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.present(card) } }
        }
        service.auth.onWindowChange = { [weak self] expires in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pairingWindowExpiresAt = expires; if expires == nil { self?.pendingPairing = nil } } }
        }
        service.auth.onChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    /// 例：「L1 提案與記憶」。
    var levelLabel: String { Self.levelLabel(settings.level) }
    static func levelLabel(_ level: Int) -> String {
        switch level {
        case 0: "L0 看"
        case 2: "L2 沙盒動手"
        default: "L1 提案與記憶"
        }
    }

    var activeGrants: [HandsGrantSummary] { grants.filter { $0.revokedAt == nil } }
    /// W183 R8a 審查（GPT-6）：確認過的（不含暫時的 grant）；「已連線」只看這個。撤銷、能不能改網址仍看 activeGrants（暫時的也算）。
    var confirmedGrants: [HandsGrantSummary] { activeGrants.filter { !$0.provisional } }

    func refresh() {
        settings = service.settings.load()
        grants = service.auth.grants()
        pairingWindowExpiresAt = service.auth.windowExpiresAt
        if pairingWindowExpiresAt == nil { pendingPairing = nil }
        if let card = pendingPairing, card.expiresAt <= Date() { pendingPairing = nil }
    }

    func setEnabled(_ enabled: Bool) { apply { _ = try self.service.updateSettings { $0.enabled = enabled } } }
    // W183 R8a 審查（GPT-6）：回 false＝沒存成（lastError 是原因）；ChatGPT build 的面板要停下、把原因顯示在原面板。
    // W183 R8 整合：R8c 審查的 scopeChanged（這台改了等級或專案＝ChatGPT build 裡這台的上限跟著改）只在真的存成時叫。
    @discardableResult
    func setLevel(_ level: Int) -> Bool {
        let saved = apply { _ = try self.service.updateSettings { $0.level = min(max(level, 0), HandsSettings.maxLevel) } }
        if saved { scopeChanged() }
        return saved
    }
    @discardableResult
    func setAllowedProjects(_ ids: [UUID]) -> Bool {
        let saved = apply { _ = try self.service.updateSettings { $0.allowedProjectIDs = ids.map(\.uuidString) } }
        if saved { scopeChanged() }
        return saved
    }

    /// W183 R8c 審查（Claude 中「reconciler 把舊畫面改的等級、專案改回去」）：這台在舊畫面改了等級或專案＝ChatGPT build 裡這台的上限也跟著改
    /// （HandsBuildSync.start 接上；自測與沒接的時候什麼都不做）。
    nonisolated(unsafe) static var onLocalScopeChanged: ((Int, [String]) -> Void)?
    private func scopeChanged() {
        guard service === HandsService.shared, let hook = Self.onLocalScopeChanged else { return }
        let current = service.settings.load()
        hook(current.level, current.allowedProjectIDs)
    }
    @discardableResult
    func setCallbacks(_ urls: [String]) -> Bool { apply { _ = try self.service.updateSettings { $0.chatgptCallbacks = urls } } }
    /// W183 R8a：ChatGPT build 的 Cloudflare 面板改子網域（只在網址還沒建、沒有連線時；畫面與 HandsBuildModel.plan 把關）。
    @discardableResult
    func setSubdomainLabel(_ label: String) -> Bool { apply { _ = try self.service.updateSettings { $0.subdomainLabel = HandsSettings.validLabel(label) } } }
    func setHost(deviceID: String?, publicHost: String?) {
        apply { _ = try self.service.updateSettings { $0.hostDeviceID = deviceID; $0.publicHost = publicHost } }
    }

    /// 「開始配對」：開 10 分鐘窗口（開關要開著、這台要是主機）。
    func startPairing() { apply { try self.service.startPairing() } }
    /// 收掉窗口（交易一起作廢）。
    func stopPairing() { service.auth.closeWindow(); refresh() }
    /// 交易編號對不上：只作廢這一筆（窗口留著，網頁重新整理會開新的）。
    func cancelPendingPairing() { service.auth.cancelTransaction(); pendingPairing = nil }

    /// 撤銷一個 grant（一次配對）：它的工作收掉、工作區鎖住（保留不刪）。
    func revokeGrant(_ id: String) { lastError = service.auth.revokeGrant(id); refresh() }   // W183 R1b：撤銷沒能存檔要顯示

    /// 一鍵撤銷：全部 grant、token、配對作廢、沙盒裡還在跑的全部收掉（關口登記保留，可以馬上重新配對）。
    func revokeAll() {
        lastError = service.revokeEverything()
        pendingPairing = nil
        refresh()
    }

    func present(_ card: HandsPairingCard?) {
        guard card?.attemptID == nil else { return }   // W183 R6b：綁連線意圖的卡只在私訊框
        pendingPairing = card
        guard let card else { return }
        // Island：交易編號、回到哪個網域、等級、配對碼；不放別的。
        IslandNotice.shared.info(title: "ChatGPT 手腳：授權這筆連線？",
                                 detail: "交易 \(card.displayCode)・回到 \(card.callbackHost)・\(Self.levelLabel(card.scope.level))・配對碼 \(card.spacedPairingCode)（窗口到期前有效）",
                                 duration: 60)
    }

    @discardableResult
    private func apply(_ change: () throws -> Void) -> Bool {
        var saved = true
        do { try change(); lastError = nil } catch { lastError = String(describing: error); saved = false }
        refresh()
        return saved
    }
}

extension ChatPageModel {
    /// W183 R1：選中的是「ChatGPT 手腳」的紀錄或施工房（輸入框鎖住）。
    var isSelectedHandsThread: Bool {
        selectedRemote == nil && (localLiveForBridge?.isHandsThread(selectedThreadID) ?? false)
    }

    /// W183 R1：施工卡上不給「退回重做」「複製合併指令」（ChatGPT 的工作區走 Hands 專用後端）。
    func isHandsRoom(_ id: UUID) -> Bool {
        localLiveForBridge?.isHandsThread(id) ?? false
    }
}

extension ThreadLiveness {
    /// W183 R1：「ChatGPT 手腳」的房間照人的速度動（ChatGPT 兩次呼叫之間可能隔很久）：狀態直接對應、不看時間，
    /// 不會因為久沒輸出變成「15 分鐘零輸出」。其他房間照舊（ThreadLiveness.from）。
    static func forThread(engine: String?, status: String?, lastOutputAt: Date?, now: Date = Date(), dispatchActive: Bool = false) -> ThreadLiveness? {
        guard engine == ChatLiveEngine.handsEngine else { return from(status: status, lastOutputAt: lastOutputAt, now: now, dispatchActive: dispatchActive) }
        switch status {
        case nil: return nil
        case "running": return .active
        case "done": return .done
        case "failed": return .failed
        default: return .idle
        }
    }
}
