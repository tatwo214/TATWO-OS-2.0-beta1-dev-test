import Combine
import Foundation

// W183 R3：副設備看主機的「ChatGPT 手腳」（接口 v2 §9；spec「副設備（MacBook）要看得到主機上的手腳狀態、施工房與待輸入的配對碼」）。
//
// - 兩個**帶設備簽章**的 RPC（照 memory_propose：OSAgentBridge 先 DeviceDispatch.authenticate 驗章，再交給這裡）：
//   `remote_hands_status`（只回畫面要的欄位）、`remote_hands_action`（開始配對、收掉配對、撤銷一筆、全部撤銷；
//   W183 R3 審查：加上主機交接 claim_host／release_host）。
// - 不經 transcript、overview_snapshot 或任何 AI 工具（os-mcp 沒有這兩個）；外部 AI（關口）連呼叫都不准（allows 只給它三個方法）。
// - 回傳沒有任何 token、雜湊、路徑；配對碼只在確認卡上（跟主機畫面、Island 一樣），配對窗口關著就沒有。
// - 簽章 RPC 只有「副設備 → 主設備」這個方向（驗章只在主設備、副設備手上沒有別台的客戶端金鑰）。所以：
//   主設備記著「現在哪一台是主機」（一次只有一台；換主機要原主機交出，確認不到就不開）；主機是主設備時副設備看得到它的狀態、
//   能遠端開始配對與撤銷；主機是某一台副設備時，其他設備的畫面只寫「主機是那台、請在那台看」，不顯示錯的服務（殘餘寫在報告）。
// W183 R3b（主導實機：副設備只有遠端檢視、沒有開關、授權網址只在主機）：
// - 副設備的開關＝`start_setup`（主設備當主機、開關打開、照標準流程跑；授權頁可以在任何一台按）／`continue_setup`（繼續）／
//   `cancel_setup`（取消進行中的那一步）／`turn_off`（關開關＝撤銷全部 grant）／`reauthorize`（取消並重新授權）。
// - 第 3 步等使用者按時，`remote_hands_status` 帶 `login_url`（只在等待中、只經這條設備簽章通道；不進 hands_setup_status、
//   任何 AI 工具輸出、狀態檔、日誌、transcript）。副設備畫面用這台的 OS 瀏覽器開（跟主機同一條 BrowserExternalURLQueue 路）。
// - 第 3 步完成後帶 `authorized`（Cloudflare 帳號名稱與網域；只給畫面，給 AI 的狀態沒有）。
// W183 R3b 審查修正（GPT-6／Claude）：
// - 授權後要使用者確認帳號與網域（`confirm_authorization`，帶這一輪的確認碼與畫面上看到的網域）；確認前主機不建通道、不啟動。
// - 設定動作（開始、繼續、取消、關掉、重新授權、確認）要帶簽章涵蓋的 `expires_at`（過期不收）；開始、繼續、重新授權、確認還要帶
//   主機給的 `setup_epoch`（取消、關掉、App 重開都會換；舊的一律不收）——延遲送達的舊請求不會在主機關掉之後又把它打開。
// - 關掉：先取消進行中的流程（世代換掉），再關開關；設定存不進去＝主機已在記憶體強制關閉，回報照實說。
// - 主機的設定流程在跑時，不交出主機（claim_host 回 host_setup_busy）。
// - 步驟另帶機器代碼 `code`（例如 authorize.needs_login）：副設備顯示自己這台該怎麼做，不照抄主機畫面用的訊息。
// W183 R5b（使用者 09-28「在這台開啟授權頁面改成自動跳轉與小視窗 不要跳去browser分頁」「私訊鈕的UI邏輯 一率當成手機做搭建」）：
// - 副設備按的開始、繼續、重新授權，主機以 trigger .remote 跑：主機不在自己的畫面開授權頁（主機螢幕不被劫持、不留敏感頁）。
// - 按的那台（副設備）記著「這一輪是我按的」，拿到 login_url 就在這台的私訊框自動打開（手機 App 的內嵌瀏覽器）；
//   授權結束（完成、等確認、失敗、取消、逾時）頁面自動滑回去。「在這台打開授權頁」留著當備援（也是開在私訊框）。
// W183 R5b 審查（GPT-6／Claude）：
// - 主機用驗章得到的 sender 記「這一輪是哪台按的」（payload 不能指定），每一個設定工作一個編號（setup_run）；
//   狀態帶 setup_run 與 setup_run_mine（問的那台是不是按的那台）。副設備只在編號與設備都對上時自動開；換輪、取消、失敗、連不上＝不等了。
// - 已開的頁綁著這一輪有效的網址：網址撤回、換了、狀態連不上（確認不到主機還在等）＝馬上收頁；期限有自己的計時器，
//   不靠網路回覆；狀態太久沒更新也收。
// W183 R6b（一個開關；one-switch.md「配對」）：
// - 新增 connect_offer／begin_connect／connect_status／cancel_connect（HandsConnectRemote；帶簽章涵蓋的 expires_at、setup_epoch、
//   attempt_id、擁有設備＝驗章得到的那台）。配對碼只回給擁有那個 attempt 的設備（connect_status），**不再放進所有設備輪詢的狀態**（card 拿掉）。
// - 舊的裸 start_pairing（不綁任何人的窗口）副設備一律不收；主設備本機的手動「開始配對」留在「詳細」。
// - W183 R6b 審查：舊的 stop_pairing 只關手動窗口；綁連線意圖的窗口回 stop_pairing_attempt（要擁有者 cancel_connect）。
// W183 R7a：狀態帶主機可以選的專案（project_choices：id、名稱、資料夾最後一段；不帶完整路徑）與目前的等級上限（level），給［連線］卡與
//   副設備的「詳細」；等級與專案只有擁有者在卡上按［連線］（begin_connect 帶 level、project_ids）才改得到。
// W183 R8c（多設備；GPT-6 必改 1、3、4）：
// - 公共狀態（所有設備都輪詢得到的 remote_hands_status）**不再帶**登入網址（login_url）與確認 token（confirm_token）；配對碼早就不帶。
//   登入網址、配對碼改走信箱（HandsBuildMailbox：只給按的那台）。
// - 拿掉單一主機的 claim_host／release_host（回 host_claim_retired）：每台被勾選的設備自己當自己的主機（ChatGPT build 設定在主設備）。
// - 安全停機鎖只能由使用者對那台明確解除：新的 unlock_safety（要簽章涵蓋的 expires_at）；開始、繼續、重試都不再解除。

enum HandsRemote {
    static let methods: Set<String> = ["remote_hands_status", "remote_hands_action"]
    static let actions: Set<String> = ["start_pairing", "stop_pairing", "revoke_grant", "revoke_all", "claim_host", "release_host",
                                       "start_setup", "continue_setup", "cancel_setup", "turn_off", "reauthorize", "confirm_authorization",
                                       "unlock_safety"]
    /// W183 R3b：設定動作（要帶 expires_at）。W183 R8c：unlock_safety（使用者明確解除主機的安全停機鎖）。
    static let setupOps: Set<String> = ["start_setup", "continue_setup", "cancel_setup", "turn_off", "reauthorize", "confirm_authorization",
                                        "unlock_safety"]
    /// W183 R8c：單一主機的交接拿掉了（每台被勾選的設備自己當自己的主機）。
    static let hostClaimRetired = "host_claim_retired"
    /// W183 R3b 審查：會讓流程往前走的（還要帶主機給的 setup_epoch）。
    /// W183 R8c 審查（GPT-6 高）：解除安全鎖也要帶（晚到的舊解除不收）。
    static let epochOps: Set<String> = ["start_setup", "continue_setup", "reauthorize", "confirm_authorization", "unlock_safety"]
    /// W183 R6a 審查（GPT-6）：主機交接（要帶簽章涵蓋的 expires_at、request_id；認領帶「按的時候看到的主機」expected_host，
    /// 交回帶認領時拿到的主機任期 host_epoch）。主設備在寫設定的同一把鎖裡核對後才改。
    static let hostOps: Set<String> = ["claim_host", "release_host"]
    static let setupFields: Set<String> = ["expires_at", "setup_epoch", "confirm", "domain", "safety_incident"]
    /// W183 R8c 審查：解除安全鎖時事故編號對不上（又發生了一次、或早就解除了）。
    static let incidentChangedReason = "hands_safety_incident_changed"
    static let hostFields: Set<String> = ["expires_at", "expected_host", "host_epoch", "request_id"]
    /// 副設備遠端開始或繼續設定、但主設備現在是關的（continue 不幫忙打開）。
    static let notEnabledReason = "hands_setup_not_enabled"
    /// W183 R3b 審查：請求過期（或兩台時間差太多）、流程世代對不上（主機剛取消或關過）。
    static let expiredReason = "hands_request_expired"
    static let staleEpochReason = "hands_setup_epoch_stale"
    /// 關掉：主機已停下（記憶體強制關閉），但設定檔存不進去。
    static let offNotSavedReason = "hands_off_not_saved"
    /// 副設備的請求有效多久（簽章涵蓋；主機收 now < expires_at ≤ now＋maxAhead，容許兩台時鐘差）。
    static let requestLifetime: TimeInterval = 90
    static let maxAhead: TimeInterval = 300

    /// 主機這端用什麼回（自測換成自己的 HandsService）。
    struct Host {
        var service: HandsService
        var phase: () -> ChatGPTHandsService.Phase
        var setup: () -> HandsSetupState?
        var localDeviceID: () -> String?
        /// 已配對設備（id → 名稱；含這台）。
        var devices: () -> [String: String] = { [:] }
        /// 設定改了：叫關口馬上看（交出主機時要停下）。
        var serviceChanged: () -> Void = {}
        /// W183 R3b：主機的標準設定流程（遠端開始、繼續、取消、重新授權；授權網址與已授權的帳號）。nil＝這個主機不收設定動作。
        var flow: HandsSetup? = nil
        /// W183 R3b：主機畫面的開關跟著變（遠端打開或關掉之後）。
        var refreshUI: () -> Void = {}
        /// W183 R8c：使用者明確解除安全停機鎖。W183 R8c 審查（GPT-6 高）：事故編號對上才解除（ChatGPTHandsService.unlockSafety(incident:)）。自測換掉。
        var unlockSafety: (_ incident: String) -> Bool = { ChatGPTHandsService.shared.unlockSafety(incident: $0) }
        /// 現在這一次安全停機的事故編號（亂數，不是秘密；沒鎖＝nil）。預設 nil（自測不讀真的 App 資料夾）；正式的由 live() 接上。
        var safetyIncident: () -> String? = { nil }

        static func live() -> Host {
            Host(service: .shared,
                 phase: { HandsSetup.onMainSync { ChatGPTHandsService.shared.phase } },
                 setup: { HandsSetup.shared.snapshot },
                 localDeviceID: { (try? DeviceIdentityStore.readLocal())?.deviceID },
                 devices: { HandsHostAuthority.deviceNames() },
                 serviceChanged: { ChatGPTHandsService.shared.settingsDidChange() },
                 flow: HandsSetup.shared,
                 refreshUI: { DispatchQueue.main.async { MainActor.assumeIsolated { HandsState.shared.refresh() } } },
                 safetyIncident: { ChatGPTHandsService.safetyIncident(ChatGPTHandsService.shared.paths) })
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let reason): "hands_remote_invalid: \(reason)" }
        }
    }

    static let iso = ISO8601DateFormatter()

    /// 驗完章之後才進來（sender＝已配對設備的 id）。
    static func handle(method: String, payload: [String: Any], sender: String, host: Host = .live()) throws -> [String: Any] {
        switch method {
        case "remote_hands_status":
            guard payload.isEmpty else { throw Failure.invalid("status takes no fields") }
            return status(host, sender: sender)
        case "remote_hands_action":
            if let op = payload["op"] as? String, HandsConnectRemote.ops.contains(op) {   // W183 R6b：連線意圖（擁有者才拿得到碼）
                return try HandsConnectRemote.handle(op, payload: payload, sender: sender, host: host)
            }
            guard Set(payload.keys).isSubset(of: Set(["op", "grant_id"]).union(setupFields).union(hostFields)),
                  let op = payload["op"] as? String, actions.contains(op) else {
                throw Failure.invalid("op")
            }
            let allowedExtra = setupOps.contains(op) ? setupFields : hostOps.contains(op) ? hostFields : []
            if payload.keys.contains(where: { setupFields.union(hostFields).contains($0) && !allowedExtra.contains($0) }) {
                throw Failure.invalid("unexpected field")
            }
            switch op {
            case "claim_host", "release_host":
                // W183 R8c（GPT-6 必改 1）：沒有單一主機了——不認領、不交回（每台被勾選的設備自己當自己的主機）。
                throw Failure.invalid(hostClaimRetired)
            case "start_pairing":
                // W183 R6b：副設備不能再開不綁任何人的窗口（碼會跑到所有設備都輪詢得到的狀態）；改用 begin_connect（碼只給按的那台）。
                throw Failure.invalid(HandsConnectRemote.startPairingRetired)
            case "stop_pairing":
                // W183 R6b 審查（GPT-6）：只收手動配對的窗口；別台按［連線］開的（綁 attempt）只能由擁有者 cancel_connect 取消。
                guard host.service.auth.closeManualWindow() else { throw Failure.invalid(HandsConnectRemote.stopPairingAttempt) }
            case "revoke_grant":
                guard let id = payload["grant_id"] as? String, id.utf8.count <= 128,
                      host.service.auth.grants().contains(where: { $0.id == id }) else { throw Failure.invalid("grant_id") }
                if let problem = host.service.auth.revokeGrant(id) { throw Failure.invalid(problem) }
            case "revoke_all":
                if let problem = host.service.revokeEverything() { throw Failure.invalid(problem) }
            case "start_setup", "continue_setup", "cancel_setup", "turn_off", "reauthorize", "confirm_authorization", "unlock_safety":
                guard payload["grant_id"] == nil else { throw Failure.invalid("unexpected field") }
                var result = try setupAction(op, payload: payload, host: host, sender: sender)
                result["done"] = op
                return result
            default:
                throw Failure.invalid("op")
            }
            var result = status(host, sender: sender)
            result["done"] = op
            return result
        default:
            throw Failure.invalid("method")
        }
    }

    /// W183 R3b：副設備的開關與設定按鈕（主設備這端，已驗章）。開始、繼續、重新授權、確認只在主機是主設備（或還沒選主機＝預設主設備）時做；
    /// 主機是別台＝host_busy（那台的畫面自己跑）。關掉、取消不看主機（關的是主設備自己的開關、取消的是主設備自己的流程）。
    /// W183 R3b 審查：每個設定動作都要簽章涵蓋的 expires_at（過期不收）；會讓流程往前走的還要主機給的 setup_epoch（舊的不收）。
    /// sender（W183 R5b 審查）：驗章得到的那台設備 id——開始、繼續、重新授權記成「這一輪是它按的」（payload 不能指定）。
    static func setupAction(_ op: String, payload: [String: Any] = [:], host: Host, now: Date = Date(), sender: String? = nil) throws -> [String: Any] {
        guard let flow = host.flow else { throw Failure.invalid("op") }
        guard let expires = (payload["expires_at"] as? NSNumber)?.doubleValue,
              expires > now.timeIntervalSince1970, expires <= now.timeIntervalSince1970 + maxAhead else {
            throw Failure.invalid(expiredReason)
        }
        if epochOps.contains(op) {
            guard let epoch = payload["setup_epoch"] as? String, epoch.utf8.count <= 64, epoch == flow.setupEpoch else {
                throw Failure.invalid(staleEpochReason)
            }
        }
        switch op {
        case "turn_off":
            // 跟主機畫面的「關掉」一樣。順序（W183 R3b 審查）：先取消進行中的設定（世代換掉：舊流程在設定鎖裡看到已取消就不會再寫「打開」）→
            // 關開關（撤銷全部 grant、關配對窗口、鎖工作區；存檔前就在記憶體強制關閉）→ 交出主機的收尾 → 叫關口停。
            flow.cancel()
            var failure: String?
            do { _ = try host.service.updateSettings { $0.enabled = false } }
            catch HandsSettingsFailure.offButNotSaved { failure = offNotSavedReason }
            catch { failure = revokeNotSavedReason }
            flow.turnedOff()
            host.serviceChanged()
            host.refreshUI()
            if let failure { throw Failure.invalid(failure) }
            return status(host, sender: sender)
        case "cancel_setup":
            flow.cancel()
            return status(host, sender: sender)
        case "unlock_safety":
            // W183 R8c（GPT-6 必改 4）：安全停機鎖只由使用者對這台明確解除（簽章＋期限）；開始、繼續、重試、輪詢都不解除。
            // W183 R8c 審查（GPT-6 高）：還要帶這一次的事故編號與 setup_epoch（上面已核）：晚到的舊解除清不掉新事故的鎖。
            guard let incident = payload["safety_incident"] as? String, (1...64).contains(incident.utf8.count), host.unlockSafety(incident) else {
                throw Failure.invalid(incidentChangedReason)
            }
            host.refreshUI()
            return status(host, sender: sender)
        default:
            break
        }
        guard let local = host.localDeviceID(), !local.isEmpty else { throw Failure.invalid("hands_not_on_this_device") }
        let settings = host.service.settings.load()
        if let current = settings.hostDeviceID, !current.isEmpty, !same(current, local) { throw Failure.invalid(HandsHostAuthority.busyReason) }
        var result: [String: Any]
        switch op {
        case "start_setup":
            // 主機上的開關跟著開；照原本的標準流程跑（主機＝主設備自己）。W183 R5b：授權頁不在主機開（trigger .remote），
            // 網址經這條通道給副設備、在按的那台的私訊框自動打開。
            do { _ = try host.service.updateSettings { $0.enabled = true } } catch { throw Failure.invalid("settings_not_saved") }
            host.refreshUI()
            let started = flow.runAll(trigger: .remote, allowLogin: true, hostOverride: local, requester: sender)
            result = status(host, sender: sender)
            result["started"] = started
        case "continue_setup":
            guard settings.enabled else { throw Failure.invalid(notEnabledReason) }
            let started = flow.runAll(trigger: .remote, allowLogin: true, hostOverride: local, requester: sender)
            result = status(host, sender: sender)
            result["started"] = started
        case "confirm_authorization":
            // W183 R3b 審查：使用者在副設備確認了授權的帳號與網域（確認碼綁這一輪、網域要跟畫面上看到的一樣）。
            guard let token = payload["confirm"] as? String, token.utf8.count <= 64,
                  let domain = payload["domain"] as? String, domain.utf8.count <= 253 else { throw Failure.invalid("confirm") }
            let confirmed: Bool
            do { confirmed = try flow.confirmAuthorization(token: token, domain: domain, trigger: .remote, requester: sender) }   // W183 R6a
            catch let refusal as HandsConfirmRefusal { throw Failure.invalid(refusal.rawValue) }
            host.refreshUI()
            result = status(host, sender: sender)
            result["started"] = confirmed
        default:   // reauthorize
            guard same(settings.hostDeviceID, local) else { throw Failure.invalid("hands_not_on_this_device") }
            if let refusal = flow.reauthorize(trigger: .remote, requester: sender) { throw Failure.invalid(refusal.rawValue) }
            host.refreshUI()
            result = status(host, sender: sender)
            result["started"] = true
        }
        return result
    }

    static let revokeNotSavedReason = "hands_revoke_not_saved"

    /// 畫面要的欄位（白名單）。主設備不是主機時不給配對窗口與確認卡（那些只在主機上有意義）。
    /// sender（W183 R5b 審查）：問的那台（驗章得到的）；帶 setup_run_mine＝這一輪是不是它按的。
    static func status(_ host: Host, sender: String? = nil) -> [String: Any] {
        let settings = host.service.settings.load()
        let phase = host.phase()
        let local = host.localDeviceID()
        let isHost = HandsHostAuthority.same(settings.hostDeviceID, local)
        var phaseInfo: [String: Any] = ["text": ChatGPTHandsService.statusText(phase)]
        switch phase {
        case .stopped: phaseInfo["state"] = "stopped"
        case .starting: phaseInfo["state"] = "starting"
        case .running(let url): phaseInfo["state"] = "running"; phaseInfo["url"] = url
        case .failed: phaseInfo["state"] = "failed"
        }
        let names = Dictionary(host.service.projectRecords(Set(settings.allowedProjectIDs)).map { ($0.0.uuidString, $0.1) },
                               uniquingKeysWith: { first, _ in first })
        // W183 R10：有效範圍＝中央設定的等級＋這台全部專案（本機的 allowed_project_ids 不再當閘門）：狀態照有效的報。
        let effective = host.service.effectiveSettings()
        let allowedNames = effective.allProjects ? host.service.buildProjectRecords().map { $0.1 } : settings.allowedProjectIDs.compactMap { names[$0] }
        let devices = host.devices()
        var result: [String: Any] = [
            "host_device_id": settings.hostDeviceID ?? "",
            "host_epoch": settings.hostEpoch ?? 0,   // W183 R6a 審查：主機任期（副設備交回時帶、重開後確認租約用；不是秘密）
            "host_name": settings.hostDeviceID.flatMap { id in devices.first { same($0.key, id) }?.value }.map { String($0.prefix(60)) } ?? "",
            "this_device_is_host": isHost,
            "enabled": settings.enabled,
            "level": effective.level,
            "public_host": settings.publicHost ?? "",
            "phase": phaseInfo,
            "allowed_projects": allowedNames,
            "grants": host.service.auth.grants().filter { $0.revokedAt == nil }.prefix(50).map { grant -> [String: Any] in
                ["id": grant.id, "client_name": String(grant.clientName.prefix(60)), "level": grant.level,
                 "projects": grant.projectIDs.count, "created_at": iso.string(from: grant.createdAt),
                 "last_used_at": grant.lastUsedAt.map { iso.string(from: $0) } ?? "",
                 "provisional": grant.provisional]   // W183 R8a 審查：暫時的 grant 副設備也不算「已連線」
            },
        ]
        if isHost, let expires = host.service.auth.windowExpiresAt, expires > Date() { result["window_expires_at"] = iso.string(from: expires) }
        if isHost, let incident = host.safetyIncident() { result["safety_incident"] = incident }   // W183 R8c 審查：解除安全鎖要帶（不是秘密）
        if isHost {   // W183 R7a：主機的專案清單（主機目前允許、暫時用不了的也列、帶 problem；超過上限不給、不截斷）。W183 R10：不照中央清單收窄
            let choices = host.service.connectProjectChoices(allowed: Set(settings.allowedProjectIDs))
            if choices.count <= HandsProjectChoice.listLimit { result["project_choices"] = choices.map(\.wire) }
        }
        // W183 R6b：配對碼不再放進這份所有設備都輪詢的狀態（card 拿掉）；只有按［連線］那台用 connect_status 拿得到。
        // W183 R8c（GPT-6 必改 3）：登入網址也不放（只說「授權頁開著」這個進度）；網址只經信箱給按的那台。
        let loginOpen = isHost && host.flow?.pendingLoginURL != nil
        if let setup = host.setup() {
            result["setup"] = HandsSetupStep.allCases.map { step -> [String: Any] in
                let entry = setup.step(step)
                var item: [String: Any] = ["step": step.rawValue, "status": entry.status.rawValue, "message": entry.message]
                if let code = stepCode(step, entry, setup: setup, loginOpen: loginOpen) { item["code"] = code }
                return item
            }
        }
        // W183 R3b：設定進行中（副設備顯示「取消」）、授權網址（只在第 3 步等使用者按）、已授權的帳號與網域（只給畫面）。
        if let flow = host.flow {
            result["setup_busy"] = flow.isBusy
            result["setup_epoch"] = flow.setupEpoch   // W183 R3b 審查：副設備的設定動作要帶（舊的不收）
            // W183 R5b 審查：這一個設定工作的編號、是不是問的那台按的（副設備只在兩者都對上時自動開授權頁）。
            // 第一次開始時主機還沒寫進設定（第 1 步在工作裡才做），所以不看 isHost；只有編號與一個是非，沒有別的資料。
            if let run = flow.runInfo {
                result["setup_run"] = run.id
                result["setup_run_mine"] = sender.map { same(run.requester, $0) } ?? false
            }
            if isHost {
                // W183 R8c：不帶 login_url、confirm_token（公共狀態只有進度）。
                if let summary = flow.authorizedSummary() {
                    result["authorized"] = ["account_name": summary.account, "domain": summary.domain ?? "",
                                            "needs_confirm": summary.needsConfirm, "cleanup_pending": summary.cleanupPending] as [String: Any]
                    result["can_reauthorize"] = !flow.isBusy && !flow.dependencies.hasActiveGrant()
                }
            }
        }
        return result
    }

    /// W183 R3b：步驟的機器代碼（副設備依代碼顯示自己這台該怎麼做；主機的訊息是寫給主機畫面的）。
    static func stepCode(_ step: HandsSetupStep, _ entry: HandsSetupStepState, setup: HandsSetupState, loginOpen: Bool) -> String? {
        guard entry.status == .waitingUser else { return nil }
        switch step {
        case .authorize:
            if loginOpen { return "authorize.login_open" }
            if setup.awaitingConfirmation { return "authorize.confirm" }
            if entry.message == HandsSetup.chooseDomainMessage { return "authorize.choose_domain" }   // W183 R8c：登入只是登入，等選網域、按「套用」
            return "authorize.needs_login"
        case .pairing: return "pairing.waiting"
        case .start: return "start.approval"
        default: return nil
        }
    }

    static func same(_ a: String?, _ b: String?) -> Bool { HandsHostAuthority.same(a, b) }
}

/// 一次只有一台主機（T12；W183 R3 審查「一次只有一台主機只是提示」的修正）：主設備的手腳設定 `host_device_id` 就是「現在哪一台是主機」。
/// - 副設備要當主機：先問主設備（簽章 claim_host）。主設備是原主機＝關掉自己的開關（撤銷它的全部連線、關配對窗口）並等關口停下；
///   原主機是另一台副設備、還沒交出＝拒絕。確認不到（連不到主設備）＝不開。
/// - 副設備不當主機了（關開關、改主機）：先停用自己，再告訴主設備（簽章 release_host）；主設備收到才空出主機。沒送到＝這台還是登記的主機（已停用）。
/// - 主設備自己要當主機（或指定別台）：原主機是另一台副設備、還沒交出＝不行。原主機的配對紀錄從主設備移除了＝當作已交出（使用者明確解除配對）。
enum HandsHostAuthority {
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// 已配對設備的名稱（含這台）。
    static func deviceNames() -> [String: String] {
        Dictionary(HandsSetup.pairedDevices().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    static let busyReason = "host_busy"
    /// W183 R3b 審查：主機（主設備）的設定流程在跑，先不交出主機。
    static let setupBusyReason = "host_setup_busy"

    static func busyMessage(_ name: String?) -> String {
        "主機目前是「\(name ?? "另一台設備")」：請先在那台關掉 ChatGPT 手腳（或在那台把主機改成要的那一台，那台會通知主設備）。確認不到原主機停了，就不能換主機"
    }

    /// W183 R6a 審查（GPT-6）：主機交接的請求對不上（延遲送達：主機已經不是按的時候看到的那一台、或不是這一任）。
    static let staleHostReason = "hands_host_changed"

    /// 主機交接的請求：簽章涵蓋的期限（now < expires_at ≤ now＋maxAhead）與冪等 id。
    static func checkHostRequest(_ payload: [String: Any], now: Date) throws -> String {
        guard let expires = (payload["expires_at"] as? NSNumber)?.doubleValue, expires > now.timeIntervalSince1970,
              expires <= now.timeIntervalSince1970 + HandsRemote.maxAhead else { throw HandsRemote.Failure.invalid(HandsRemote.expiredReason) }
        guard let id = payload["request_id"] as? String, !id.isEmpty, id.utf8.count <= 64 else { throw HandsRemote.Failure.invalid("request_id") }
        return id
    }

    /// 主設備這端：sender（已驗章的副設備）要當主機。
    /// W183 R6a 審查（GPT-6）：要帶期限、冪等 id、按的時候看到的主機（expected_host，沒有主機＝空字串）；在寫設定的同一把鎖裡核對「現在的主機
    /// 還是那一台（或已經是 sender）」才改——使用者取消、關掉、換過主機之後才送到的舊請求不會停掉現在的主機。主機換了＝任期 +1（回給 sender）。
    static func claim(sender: String, host: HandsRemote.Host, payload: [String: Any], now: Date = Date()) throws -> [String: Any] {
        let requestID = try checkHostRequest(payload, now: now)
        guard let expected = payload["expected_host"] as? String, expected.utf8.count <= 64 else { throw HandsRemote.Failure.invalid("expected_host") }
        if let cached = HandsHostRequests.shared.result(requestID, sender: sender) { return cached }
        // W183 R3b 審查：主設備的設定流程在跑（例如跑到第 5 步會寫「主機＝主設備、打開」）：先不交出，等它停下（或先按「取消」）。
        if host.flow?.isBusy == true { throw HandsRemote.Failure.invalid(setupBusyReason) }
        let local = host.localDeviceID()
        let devices = host.devices()
        let refusal = HandsLocked<String?>(nil), handedOver = HandsLocked(false), epoch = HandsLocked(0)
        var saveError: Error?
        do {
            _ = try host.service.updateSettings { settings in
                let current = settings.hostDeviceID ?? ""
                guard same(current, sender) || current.lowercased() == expected.lowercased() else { refusal.set(staleHostReason); return }
                if !current.isEmpty, !same(current, sender), !same(current, local), devices.keys.contains(where: { same($0, current) }) {
                    refusal.set(busyReason); return
                }
                // 主設備自己是原主機：交出＝關掉開關（撤銷全部 ChatGPT 連線、關配對窗口、鎖工作區）＋關口停下。
                if same(current, local) { settings.enabled = false; handedOver.set(true) }
                if !same(current, sender) { settings.hostEpoch = (settings.hostEpoch ?? 0) + 1 }
                settings.hostDeviceID = sender
                epoch.set(settings.hostEpoch ?? 0)
            }
        } catch HandsSettingsFailure.offButNotSaved {
            // W183 R3b 審查：設定存不進去（磁碟滿）＝主設備已在記憶體停用，但「主機換成那台」沒記下來：不宣稱交接成功。
            host.serviceChanged()
            throw HandsRemote.Failure.invalid("settings_not_saved")
        } catch { saveError = error }
        if let reason = refusal.get() { throw HandsRemote.Failure.invalid(reason) }
        // 交出時設定已存、只有撤銷紀錄沒存成（撤銷在記憶體已生效）：交接照做；其他存不進去＝丟錯。
        if let saveError, !handedOver.get() { throw saveError }
        var stopped = true
        if handedOver.get() {
            host.serviceChanged()
            let deadline = Date().addingTimeInterval(10)
            while case .running = host.phase(), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            if case .running = host.phase() { stopped = false }
        }
        let result: [String: Any] = ["host_device_id": sender, "previous_stopped": stopped, "host_epoch": epoch.get()]
        HandsHostRequests.shared.remember(requestID, sender: sender, result: result)
        return result
    }

    /// 主設備這端：sender 不當主機了（它自己已經停用、而且存進磁碟、關口停了）。只有它真的是現在的主機、而且是它認領的那一任（host_epoch）才空出來；
    /// 已經不是它＝沒事（冪等）；不是這一任＝延遲送達的舊請求，不收。
    static func release(sender: String, host: HandsRemote.Host, payload: [String: Any], now: Date = Date()) throws -> [String: Any] {
        let requestID = try checkHostRequest(payload, now: now)
        guard let tenure = (payload["host_epoch"] as? NSNumber)?.intValue else { throw HandsRemote.Failure.invalid("host_epoch") }
        if let cached = HandsHostRequests.shared.result(requestID, sender: sender) { return cached }
        let refusal = HandsLocked<String?>(nil)
        _ = try host.service.updateSettings { settings in
            guard same(settings.hostDeviceID, sender) else { return }
            guard tenure == (settings.hostEpoch ?? 0) else { refusal.set(staleHostReason); return }
            settings.hostDeviceID = nil
            settings.hostEpoch = (settings.hostEpoch ?? 0) + 1
        }
        if let reason = refusal.get() { throw HandsRemote.Failure.invalid(reason) }
        let result: [String: Any] = ["released": true]
        HandsHostRequests.shared.remember(requestID, sender: sender, result: result)
        return result
    }

    /// 主設備（或還沒配對任何設備的單機）這端換主機：原主機是另一台、還在配對清單裡、沒交出＝不行。
    /// 從這台交出去＝先關掉這台的開關（撤銷它的連線）。成功回 nil。
    static func localTransfer(to target: String, localID: String, service: HandsService, devices: [String: String],
                              serviceChanged: () -> Void) -> String? {
        let settings = service.settings.load()
        let current = settings.hostDeviceID
        if let current, !same(current, localID), !same(current, target), devices.keys.contains(where: { same($0, current) }) {
            return busyMessage(devices.first { same($0.key, current) }?.value)
        }
        do {
            let changes = !same(current, target)   // W183 R6a 審查：主機換了＝任期 +1
            if same(current, localID), !same(target, localID) {
                _ = try service.updateSettings { $0.enabled = false; $0.hostDeviceID = target; if changes { $0.hostEpoch = ($0.hostEpoch ?? 0) + 1 } }
                serviceChanged()
            } else {
                _ = try service.updateSettings { $0.hostDeviceID = target; if changes { $0.hostEpoch = ($0.hostEpoch ?? 0) + 1 } }
            }
        } catch { return "設定存不進去" }
        return nil
    }

    static func plain(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains(setupBusyReason) { return "主機（主設備）的設定流程正在跑；先按「取消」（或等它停在要你按的那一步）再改用這台當主機" }
        if text.contains(busyReason) { return busyMessage(nil) }
        if text.contains("hands_not_on_this_device") { return "主設備不是 ChatGPT 手腳的主機" }
        // W183 R3b：遠端開始、繼續、關掉、重新授權的原因（主設備回代碼，這裡轉白話）。
        if text.contains(HandsRemote.notEnabledReason) { return "主機的 ChatGPT 手腳是關的；先把開關打開" }
        if text.contains(HandsRemote.revokeNotSavedReason) { return "主機已經關了，但撤銷紀錄沒存成功；到主機的 TAP › ChatGPT 看一下" }
        if text.contains(HandsRemote.offNotSavedReason) { return "主機已經停下（所有 ChatGPT 連線作廢、關口停了），但設定存不進去（磁碟滿？）；主機 App 開著期間會保持關閉，空出空間後在主機再關一次" }
        if text.contains(HandsRemote.expiredReason) { return "這個動作送到主機時已經過期（或兩台的時間差太多）；再按一次" }
        if text.contains(HandsRemote.staleEpochReason) { return "主機的設定狀態剛變了（有人按了取消或關掉、或主機 App 重開）；看一下畫面再按一次" }
        if text.contains(staleHostReason) { return "主機剛換過了（這個請求是換之前送的）；看一下畫面再按一次" }
        if let refusal = HandsConfirmRefusal.allCases.first(where: { text.contains($0.rawValue) }) { return refusal.description }
        if text.contains("settings_not_saved") { return "主機的設定存不進去" }
        if let refusal = HandsReauthorizeRefusal.allCases.first(where: { text.contains($0.rawValue) }) { return refusal.description }
        if text.contains("hands_remote_invalid: op") { return "主設備的 TATWO OS 版本太舊（不認得這個動作）；主設備更新後再試" }
        return HandsRemoteClient.plain(error)
    }

    /// 正式：主設備走本機規則，副設備走簽章 RPC。
    struct Live {
        let service: HandsService
        let dispatch: DeviceDispatch
        let localID: () -> String?

        private var isSecondary: Bool { (try? DeviceIdentityStore.readLocal())?.role == .secondary }

        /// 主設備記著的主機（副設備才問；問不到回 nil）。
        func authoritativeHost() -> String? {
            guard isSecondary, let current = try? primaryHost(), !current.host.isEmpty, UUID(uuidString: current.host) != nil else { return nil }
            return current.host
        }

        /// 主設備現在記的主機與任期（副設備問；問不到丟錯）。
        private func primaryHost() throws -> (host: String, epoch: Int) {
            let response = try dispatch.callPrimary(method: "remote_hands_status", payload: [:])
            return ((response["host_device_id"] as? String) ?? "", (response["host_epoch"] as? NSNumber)?.intValue ?? 0)
        }

        /// W183 R6a 審查（GPT-6）：交接請求（簽章涵蓋的期限、這一次的冪等 id）。
        private func hostRequest(_ op: String, _ extra: [String: Any]) -> [String: Any] {
            var payload = extra
            payload["op"] = op
            payload["expires_at"] = Int(Date().timeIntervalSince1970 + HandsRemote.requestLifetime)
            payload["request_id"] = HandsSetup.randomLabel(24)
            return payload
        }

        func transfer(to target: String) -> String? {
            guard let local = localID(), !local.isEmpty else { return "這台還沒有設備身分；先到「設定 › 設備」完成設定" }
            // W183 R8c（GPT-6 必改 1）：沒有單一主機的交接了——每台被勾選的設備自己當自己的主機；這台要跑＝這台有啟用許可。
            if same(target, local) {
                return HandsBuildPermit.permits(local) ? nil : HandsSetup.notSelectedMessage
            }
            return HandsSetup.otherDeviceRunsItselfMessage
        }

        /// W183 R8c：舊的單主機交接（保留給之前的版本對照；不再被呼叫）。
        func legacyTransfer(to target: String) -> String? {
            guard let local = localID(), !local.isEmpty else { return "這台還沒有設備身分；先到「設定 › 設備」完成設定" }
            guard isSecondary else {
                return HandsHostAuthority.localTransfer(to: target, localID: local, service: service, devices: deviceNames(),
                                                        serviceChanged: { ChatGPTHandsService.shared.settingsDidChange() })
            }
            if same(target, local) {
                // 這台（副設備）要當主機：主設備確認原主機交出了才開。W183 R6a 審查：帶「現在看到的主機」，主設備在同一把鎖裡核對。
                do {
                    let current = try primaryHost()
                    let response = try dispatch.callPrimary(method: "remote_hands_action", payload: hostRequest("claim_host", ["expected_host": current.host]))
                    guard same(response["host_device_id"] as? String, local) else { return "主設備沒有確認這台是主機；按「重試」" }
                    if response["previous_stopped"] as? Bool == false { return "原主機（主設備）的關口還沒停下來；等一下按「重試」" }
                } catch { return "確認不到原主機已停用（\(plain(error))）；這台先不開" }
                do { _ = try service.updateSettings { $0.hostDeviceID = local } } catch { return "設定存不進去" }
                return nil
            }
            // 交給別台：這台原本是主機＝先停用這台（HandsSetup.stopBeforeRelease 已經確定「關」存進磁碟、關口停了），再告訴主設備；
            // 沒送到就留著登記（主設備不會讓別台接手）。
            if same(service.settings.load().hostDeviceID, local) {
                _ = try? service.updateSettings { $0.enabled = false }
                ChatGPTHandsService.shared.settingsDidChange()
                if let problem = release(local) { return problem }
            }
            do { _ = try service.updateSettings { $0.hostDeviceID = target } } catch { return "設定存不進去" }
            return nil
        }

        /// W183 R6a 審查（GPT-6）：這台（副設備）登記是主機＝關掉之後要交回主設備。
        /// W183 R8c：沒有單一主機的交回了（每台自己跑自己的）。
        func needsRelease() -> Bool { false }

        /// 告訴主設備「這台不當主機了」（帶這一任的任期；主設備記的已經不是這台＝沒事）。成功＝租約收回。
        private func release(_ local: String) -> String? {
            do {
                let current = try primaryHost()
                if same(current.host, local) {
                    _ = try dispatch.callPrimary(method: "remote_hands_action", payload: hostRequest("release_host", ["host_epoch": current.epoch]))
                }
            } catch {
                return "這台已經關了；但主設備沒收到「這台不當主機了」（\(plain(error))）：連得到主設備時按「交回主設備」"
            }
            return nil
        }

        /// 關掉開關之後：副設備是主機就告訴主設備（成功才把這台設定裡的主機清掉，下次打開會重新向主設備要）。
        /// W183 R6a 審查（GPT-6）：清不掉（存不進去）也照實說，不宣稱交回完成（下次再按會再清一次）。
        /// W183 R8c：沒有單一主機了，不用交回。
        func releaseIfHost() -> String? { nil }

        func legacyReleaseIfHost() -> String? {
            guard isSecondary, let local = localID(), same(service.settings.load().hostDeviceID, local) else { return nil }
            if let problem = release(local) { return problem }
            do { _ = try service.updateSettings { $0.hostDeviceID = nil } } catch {
                return "主設備已經收回主機，但這台的設定存不進去（磁碟滿？）；空出空間後再按「交回主設備」"
            }
            return nil
        }

        /// W183 R6a 審查（GPT-6）：副設備重開後、起關口之前，先問主設備「現在的主機還是這台嗎」（只問、不認領、不搶）。
        /// W183 R8c：改成看這台的啟用許可（主設備簽的信封：給這台、沒過期、勾了這台）。
        func confirmLease() -> HandsHostLeaseCheck {
            guard let local = localID() else { return .notHost }
            switch HandsBuildPermit.shared.state(local) {
            case .active: return .confirmed
            case .paused: return .unreachable
            case .inactive, .none: return isSecondary && HandsBuildAcceptedStore.shared.current(trust: HandsBuildTrust.live()) == nil ? .unreachable : .notHost
            }
        }
    }
}

/// W183 R6a 審查（GPT-6）：副設備重開後問主設備的結果。
enum HandsHostLeaseCheck: Equatable, Sendable { case confirmed, notHost, unreachable }

/// W183 R8c（GPT-6 必改 1）：單一主機的「租約」（HandsHostLease）拿掉了，改成每台啟用許可（HandsBuildPermit：綁設備 id、設定版本、
/// 撤銷世代、有效期限；副設備看主設備簽的信封）。

/// W183 R6a 審查（GPT-6）：主設備這端記最近處理過的交接請求（冪等：同一台同一個 id 再送一次＝回同一個結果，不重做）。
final class HandsHostRequests: @unchecked Sendable {
    static let shared = HandsHostRequests()
    private let lock = NSLock()
    private var entries: [(key: String, result: [String: Any])] = []

    func result(_ id: String, sender: String) -> [String: Any]? {
        let key = sender.lowercased() + "\u{1}" + id
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key == key }?.result
    }

    func remember(_ id: String, sender: String, result: [String: Any]) {
        let key = sender.lowercased() + "\u{1}" + id
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.append((key, result))
        if entries.count > 32 { entries.removeFirst(entries.count - 32) }
    }
}

/// 副設備畫面用的解碼後狀態。
struct HandsRemoteStatus: Equatable, Sendable {
    struct Card: Equatable, Sendable {
        let transaction: String
        let pairingCode: String
        let callbackHost: String
        let level: Int
        let projects: [String]
        let memory: String
        let expiresAt: Date?
        let attemptsLeft: Int
        var spacedCode: String { String(pairingCode.prefix(4)) + " " + String(pairingCode.dropFirst(4)) }
    }
    struct Grant: Equatable, Sendable, Identifiable {
        let id: String
        let clientName: String
        let level: Int
        let createdAt: Date?
        /// W183 R8a 審查：暫時的 grant（主機還沒確認）；舊版主機沒給＝當確認過的。
        var provisional: Bool = false
    }
    struct Step: Equatable, Sendable {
        let step: String
        let status: String
        let message: String
        /// W183 R3b 審查：主機給的機器代碼（例如 authorize.needs_login）；副設備依代碼顯示這台該怎麼做。
        var code: String? = nil
        /// W183 R3b：畫面上的中文狀態（跟主機那頁一樣）；不認得的代碼寫「未知」。
        var statusLabel: String { HandsSetupStatus.label(forCode: status) }
        /// 副設備畫面上的訊息：主機的訊息是寫給主機畫面的（例如「到設定 › 環境登入按用瀏覽器登入」），人在這台照做會登在錯的設備。
        var displayMessage: String {
            switch code {
            // W183 R8c（GPT-6 必改 3、4）：替那台登入走 ChatGPT build（經主設備的信箱，登入網址只給按的那台）；登入只是登入，選網域按「套用」才建網址。
            case "authorize.needs_login"?: return "那台還沒登入 Cloudflare（或還沒選網域）：在 ChatGPT build 的 Cloudflare 節點替那台按「登入 Cloudflare」（授權頁會在這台的私訊框打開），選網域後按「套用」；不要在這台的環境登入另外登入"
            case "authorize.login_open"?: return "那台在等 Cloudflare 授權：授權頁在按「登入 Cloudflare」的那台的私訊框打開（登入網址只給按的那台）"
            case "authorize.confirm"?: return "授權拿到了：看上面那一列的帳號與網域，是你要的就按「是這個，繼續」；不是就按「取消並重新授權」"
            case "authorize.choose_domain"?: return "那台已登入 Cloudflare：在 ChatGPT build 的 Cloudflare 節點選網域、按「套用」才會建網址（登入不會自己綁網址）"
            case "pairing.waiting"?: return "等你在私訊框按［連線］（讓 ChatGPT 連上 TATWO；按一下就好）"   // W183 R10
            case "start.approval"?: return "主機在等你在主機的 Island 按「允許」（助理要打開 ChatGPT 手腳）；人不在主機旁就先別按，回到主機再說"
            default:
                // W183 R5（實機）：主機寫的是「主機：這台（Mac mini）」——在副設備上「這台」指錯了，只留名字。
                if step == HandsSetupStep.host.rawValue, message.hasPrefix("主機：這台（"), message.hasSuffix("）") {
                    return "主機：" + message.dropFirst("主機：這台（".count).dropLast()
                }
                return message
            }
        }
    }
    let hostDeviceID: String
    let hostName: String
    /// 主設備自己就是主機（副設備能遠端看與按的只有這種）。
    let primaryIsHost: Bool
    let enabled: Bool
    let level: Int
    /// W183 R7a：主機目前允許的專案（名稱）、可以選的專案（id、名稱、資料夾最後一段）。
    let allowedProjects: [String]
    let projectChoices: [HandsProjectChoice]
    let phaseState: String
    let phaseText: String
    let url: String?
    var windowExpiresAt: Date?
    var card: Card?
    let grants: [Grant]
    let setup: [Step]
    /// W183 R3b：主機的設定流程正在跑（顯示「取消」，不顯示「繼續」）。
    let setupBusy: Bool
    /// W183 R3b：主機第 3 步在等使用者按的 Cloudflare 授權網址（只收 Cloudflare 授權頁的網址；太舊、斷線就拿掉）。
    var loginURL: URL?
    /// W183 R3b：第 3 步完成後的帳號名稱與網域（只給畫面）。
    let authorizedAccount: String?
    let authorizedDomain: String?
    let canReauthorize: Bool
    /// W183 R3b 審查：主機在等使用者確認這個帳號與網域（副設備也能按「是這個，繼續」；要帶這一輪的確認碼）。
    let authorizedNeedsConfirm: Bool
    let confirmToken: String?
    /// 上次「取消並重新授權」沒清完（副設備給「重按一次」）。
    let cleanupPending: Bool
    /// W183 R3b 審查：主機的流程世代（開始、繼續、重新授權、確認要帶）。
    let setupEpoch: String?
    /// W183 R5b 審查：主機正在跑的設定工作編號、是不是這台按的。
    let setupRun: String?
    let setupRunMine: Bool
    /// 這份狀態是什麼時候從主設備拿到的（太舊＝不顯示配對碼）。
    var fetchedAt: Date

    init?(_ object: [String: Any], fetchedAt: Date = Date()) {
        guard let enabled = object["enabled"] as? Bool, let phase = object["phase"] as? [String: Any],
              let state = phase["state"] as? String, let text = phase["text"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        hostDeviceID = object["host_device_id"] as? String ?? ""
        hostName = String((object["host_name"] as? String ?? "").prefix(60))
        primaryIsHost = object["this_device_is_host"] as? Bool ?? false
        self.enabled = enabled
        level = min(max(object["level"] as? Int ?? 1, 0), HandsSettings.maxLevel)
        allowedProjects = (object["allowed_projects"] as? [String] ?? []).prefix(HandsProjectChoice.listLimit).map { String($0.filter { !$0.isNewline }.prefix(80)) }   // W183 R7a
        projectChoices = HandsProjectChoice.list(object["project_choices"]) ?? []   // W183 R7a 審查：不完整的清單整份不收
        phaseState = state
        phaseText = String(text.prefix(200))
        url = (phase["url"] as? String).flatMap { $0.hasPrefix("https://") && $0.utf8.count <= 300 ? $0 : nil }
        windowExpiresAt = (object["window_expires_at"] as? String).flatMap(iso.date(from:))
        if let raw = object["card"] as? [String: Any], let tx = raw["transaction"] as? String, let code = raw["pairing_code"] as? String,
           code.count == 8, tx.count <= 8 {
            card = Card(transaction: tx, pairingCode: code, callbackHost: String((raw["callback_host"] as? String ?? "?").prefix(120)),
                        level: raw["level"] as? Int ?? 1, projects: (raw["projects"] as? [String] ?? []).map { String($0.prefix(80)) },
                        memory: String((raw["memory"] as? String ?? "").prefix(200)),
                        expiresAt: (raw["expires_at"] as? String).flatMap(iso.date(from:)), attemptsLeft: raw["attempts_left"] as? Int ?? 0)
        } else {
            card = nil
        }
        grants = (object["grants"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            return Grant(id: id, clientName: String((raw["client_name"] as? String ?? "ChatGPT").prefix(60)), level: raw["level"] as? Int ?? 1,
                         createdAt: (raw["created_at"] as? String).flatMap(iso.date(from:)), provisional: raw["provisional"] as? Bool ?? false)
        }
        // W183 R8 整合：R8a 審查要的「主機勾的專案名稱」＝上面 R7a 的 allowedProjects（同一個欄位，上限照 R7a 審查不截在 50）。
        setup = (object["setup"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let step = raw["step"] as? String, let status = raw["status"] as? String else { return nil }
            let code = (raw["code"] as? String).flatMap { $0.utf8.count <= 40 ? $0 : nil }
            return Step(step: step, status: status, message: String((raw["message"] as? String ?? "").prefix(300)), code: code)
        }
        setupBusy = object["setup_busy"] as? Bool ?? false
        // 主設備給的網址一樣只收 Cloudflare 授權頁（https、cloudflare.com、/argotunnel），其他一律不顯示、不開。
        loginURL = (object["login_url"] as? String).flatMap { $0.utf8.count <= 4096 ? HandsCloudflared.loginURL(in: $0) : nil }
        if let authorized = object["authorized"] as? [String: Any], let name = authorized["account_name"] as? String, !name.isEmpty {
            authorizedAccount = String(name.filter { !$0.isNewline }.prefix(80))
            authorizedDomain = (authorized["domain"] as? String).flatMap { HandsGatewayLaunch.validHost($0) }
            authorizedNeedsConfirm = authorized["needs_confirm"] as? Bool ?? false
            confirmToken = (authorized["confirm_token"] as? String).flatMap { $0.utf8.count <= 64 && !$0.isEmpty ? $0 : nil }
            cleanupPending = authorized["cleanup_pending"] as? Bool ?? false
        } else {
            authorizedAccount = nil
            authorizedDomain = nil
            authorizedNeedsConfirm = false
            confirmToken = nil
            cleanupPending = false
        }
        canReauthorize = authorizedAccount != nil && (object["can_reauthorize"] as? Bool ?? false)
        setupEpoch = (object["setup_epoch"] as? String).flatMap { $0.utf8.count <= 64 ? $0 : nil }
        setupRun = (object["setup_run"] as? String).flatMap { $0.utf8.count <= 64 && !$0.isEmpty ? $0 : nil }
        setupRunMine = setupRun != nil && (object["setup_run_mine"] as? Bool ?? false)
        self.fetchedAt = fetchedAt
    }

    /// 配對資料多久沒更新就不顯示（輪詢每 10 秒一次；連不上會退避）。
    static let freshFor: TimeInterval = 25

    /// 此刻還能顯示的配對窗口與確認卡（W183 R3 審查）：到期的、太久沒從主設備更新的，一律拿掉。
    func live(at now: Date) -> HandsRemoteStatus {
        var copy = self
        let fresh = now.timeIntervalSince(fetchedAt) <= Self.freshFor
        if !fresh || (copy.windowExpiresAt.map { $0 <= now } ?? false) { copy.windowExpiresAt = nil; copy.card = nil }
        if let expires = copy.card?.expiresAt, expires <= now { copy.card = nil }
        if copy.card != nil, copy.card?.expiresAt == nil { copy.card = nil }
        if !fresh { copy.loginURL = nil }   // W183 R3b：確認不到主機還在等授權，就不給按
        return copy
    }

    /// 連不上主設備：狀態留著看，但配對碼、配對窗口、授權網址一律拿掉（不能再宣稱窗口開著、主機還在等授權）。
    func withoutPairing() -> HandsRemoteStatus {
        var copy = self
        copy.windowExpiresAt = nil
        copy.card = nil
        copy.loginURL = nil
        return copy
    }

    /// W183 R3b：主機還沒做到關口能用的那一步（跟 HandsSetup.settingUpStep 同一條規則）；沒有步驟資料＝nil。
    var settingUpStep: HandsSetupStep? {
        guard !setup.isEmpty else { return nil }
        let done = Set(setup.filter { $0.status == HandsSetupStatus.done.rawValue }.map(\.step))
        return HandsSetupStep.runOrder.prefix(while: { $0 != .remember }).first { !done.contains($0.rawValue) }
    }

    /// W183 R3b：還有沒做完的步驟（配對以外；配對等使用者按「開始配對」）＝副設備給「繼續」。
    var needsContinue: Bool {
        setup.contains { $0.step != HandsSetupStep.pairing.rawValue && $0.status != HandsSetupStatus.done.rawValue }
    }
}

/// 副設備：問主設備（帶設備簽章；走已 pin 的 SSH），不在主執行緒做。
/// W183 R3 審查：同一時間只有一個狀態查詢在路上（上一個沒回來就跳過）；連不上就退避（10→30→60 秒）；
/// 按鈕（開始配對、撤銷）走自己的佇列，不排在一串查詢後面。簽章呼叫本身仍由 DeviceDispatch 排成一列（序號規則）。
final class HandsRemoteClient: ObservableObject, @unchecked Sendable {
    static let shared = HandsRemoteClient()

    @Published private(set) var status: HandsRemoteStatus?
    @Published private(set) var problem: String?
    @Published private(set) var busy = false
    /// 最近一次查詢失敗（配對碼已拿掉；畫面停用配對相關的按鈕）。
    @Published private(set) var stale = false
    /// W183 R5（使用者 09-28「點開啟時卡很久」＋GPT-6 審查）：按了開關、主機還沒回覆前，開關先照按下去的樣子顯示。
    /// 由那一次動作自己的成功／失敗收尾清掉（不靠畫面觀察 busy 的變化，切畫面、合併更新都不會漏）。
    @Published private(set) var pendingEnabled: Bool?
    /// 哪一次動作設的 pendingEnabled（只有那一次收尾才清；GPT-6 複查：前一個請求不會清掉後一個的）。
    private var pendingToken: UUID?

    let dispatch: DeviceDispatch
    private let queue = DispatchQueue(label: "tatwo.chatgpt-hands.remote", qos: .utility)
    private let actionQueue = DispatchQueue(label: "tatwo.chatgpt-hands.remote-action", qos: .userInitiated)
    private var watchers = 0
    /// W183 R6a：設定頁看得到的觀看者（TAP › ChatGPT 開著）：連不上的退避上限縮成 10 秒內（主機重開後最多 10 秒就更新）。
    private var visibleWatchers = 0
    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private var failures = 0
    private var nextAllowed = Date.distantPast
    private let lock = NSLock()

    static let interval: TimeInterval = 10
    static let backoff: [TimeInterval] = [10, 30, 60]
    /// W183 R6a：設定頁看得到時，連不上最多隔多久再問（從「上一次開始問」起算）。
    /// W183 R6a 審查（GPT-6「9 秒退避加 10 秒定時器，實際可超過 10 秒」）：到期時自己排一次，不等下一輪定時器。自測可以縮短。
    var visibleMaxGap: TimeInterval = 10
    #if DEBUG
    /// 自測：換掉對主設備的呼叫（模擬查詢延遲與失敗）；nil＝正式的 DeviceDispatch。
    var debugCall: ((String, [String: Any]) throws -> [String: Any])?
    /// 自測：每一次真的開始問主設備的時間（鎖保護；讀 debugStartTimes）。
    private var debugStarts: [Date] = []
    #endif

    init(dispatch: DeviceDispatch = .shared) { self.dispatch = dispatch }

    /// 這台是副設備（有主設備可以問）。
    var isSecondary: Bool { (try? dispatch.identity().role) == .secondary }

    /// 問一次主設備。上一次還沒回來、或還在退避時間內（force 除外）就跳過。
    func fetch(force: Bool = false) {
        lock.lock()
        if inFlight || (!force && Date() < nextAllowed) { lock.unlock(); return }
        inFlight = true
        let started = Date()
        #if DEBUG
        debugStarts.append(started)
        #endif
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            // 在背景解碼：送到主執行緒的只有解好的狀態與白話錯誤。
            var decoded: HandsRemoteStatus?
            var failure: String?
            do {
                let response = try self.callPrimary(method: "remote_hands_status", payload: [:])
                decoded = HandsRemoteStatus(response)
                if decoded == nil { failure = "主設備回的狀態看不懂" }
            } catch {
                failure = "連不到主設備（\(Self.plain(error))）"
            }
            self.lock.lock()
            self.inFlight = false
            var retryIn: TimeInterval?
            if failure == nil {
                self.failures = 0
                self.nextAllowed = Date()
            } else {
                self.failures += 1
                let delay = Self.backoff[min(self.failures - 1, Self.backoff.count - 1)]
                if self.visibleWatchers > 0 {
                    // W183 R6a 審查：看得到時從「這一次開始問」起算最多 visibleMaxGap 就再問（查詢本身花的時間也算在內），到期自己排一次。
                    self.nextAllowed = started.addingTimeInterval(min(delay, self.visibleMaxGap))
                    retryIn = max(0, self.nextAllowed.timeIntervalSinceNow) + 0.05
                } else {
                    self.nextAllowed = Date().addingTimeInterval(delay)
                }
            }
            self.lock.unlock()
            if let retryIn { DispatchQueue.main.asyncAfter(deadline: .now() + retryIn) { [weak self] in self?.retryWhileVisible() } }
            let result = decoded, problem = failure
            DispatchQueue.main.async {
                if let result {
                    self.status = result
                    self.stale = false
                    self.problem = nil
                } else {
                    // 連不上或看不懂：狀態留著看，但配對碼、配對窗口、授權網址一律拿掉（不能再宣稱窗口開著）。
                    self.status = self.status?.withoutPairing()
                    self.stale = true
                    self.problem = problem
                }
                MainActor.assumeIsolated {
                    self.autoOpen(result)        // W183 R5b：這台按的那一輪（編號與設備都對上），主機拿到授權網址就在這台的私訊框自動打開
                    self.settleAwaiting(result)  // W183 R3b／R5b 審查：已開的頁綁這一輪有效的網址
                    self.offerIfReady(result)    // W183 R6a：這台按的開關，主機走到「等你按［連線］」＝這台的私訊框出［連線］卡
                }
            }
        }
    }

    /// W183 R6a 審查：連不上的那一次到期了、設定頁還看得到＝再問一次（上一次還在路上、或剛成功就跳過）。
    private func retryWhileVisible() {
        lock.lock(); let visible = visibleWatchers > 0; lock.unlock()
        if visible { fetch() }
    }

    private func callPrimary(method: String, payload: [String: Any]) throws -> [String: Any] {
        #if DEBUG
        if let debugCall { return try debugCall(method, payload) }
        #endif
        return try dispatch.callPrimary(method: method, payload: payload)
    }

    /// extra（W183 R3b 審查）：確認授權時的確認碼與網域。設定動作自動帶 expires_at（簽章涵蓋）與最近一次拿到的 setup_epoch。
    func act(_ op: String, grantID: String? = nil, extra: [String: String] = [:]) {
        var payload: [String: Any] = ["op": op]
        if let grantID { payload["grant_id"] = grantID }
        if HandsRemote.setupOps.contains(op) {
            payload["expires_at"] = Int(Date().timeIntervalSince1970 + HandsRemote.requestLifetime)
            if HandsRemote.epochOps.contains(op), let epoch = epochForRequest() { payload["setup_epoch"] = epoch }
            for (key, value) in extra where ["confirm", "domain"].contains(key) { payload[key] = value }
        }
        let pending: Bool? = op == "start_setup" ? true : nil
        let token = UUID()
        // W183 R5b 審查：這台按了取消或關掉＝這台不再等自動打開（不等下一輪輪詢）。
        let stopsWaiting = op == "cancel_setup" || op == "turn_off"
        let publish = {
            self.busy = true
            if let pending { self.pendingEnabled = pending; self.pendingToken = token }
            if stopsWaiting { MainActor.assumeIsolated { self.disarmAutoOpen(); self.disarmOffer() } }   // W183 R6a：也不等［連線］了
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }   // 按下去當下就停用開關（不等下一輪）
        actionQueue.async { [weak self] in
            guard let self else { return }
            do {
                let response = try self.dispatch.callPrimary(method: "remote_hands_action", payload: payload)
                let decoded = HandsRemoteStatus(response)
                // W183 R5b：開始、繼續、重新授權是這台按的（主機真的開始了）＝這一輪的授權頁在這台自動打開。
                // W183 R5b 審查（GPT-6）：綁主機給的這一輪編號，而且主機記的按的那台（驗章得到的）就是這台。
                let run = Self.autoOpenOps.contains(op) && response["started"] as? Bool == true && decoded?.setupRunMine == true
                    ? decoded?.setupRun : nil
                let offer = Self.offerOps.contains(op) && response["started"] as? Bool == true   // W183 R6a
                DispatchQueue.main.async {
                    self.status = decoded ?? self.status; self.stale = false; self.problem = nil; self.busy = false
                    if self.pendingToken == token { self.pendingEnabled = nil; self.pendingToken = nil }
                    if let run { MainActor.assumeIsolated { self.armAutoOpen(run: run) } }
                    if offer { MainActor.assumeIsolated { self.armOffer() } }
                }
                // W183 R3b：開始、繼續、重新授權之後，主機幾秒內會拿到授權網址：先多問幾次，不用等 10 秒一輪。
                if Self.followUpOps.contains(op) {
                    for delay in Self.followUps { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in self?.fetch(force: true) } }
                }
            } catch {
                DispatchQueue.main.async {
                    self.problem = "主設備沒有照做（\(HandsHostAuthority.plain(error))）"; self.busy = false
                    if self.pendingToken == token { self.pendingEnabled = nil; self.pendingToken = nil }
                }
                // 主機的流程世代換了（有人取消或關掉）：馬上重拿一次狀態，畫面看到的就是新的。
                if String(describing: error).contains(HandsRemote.staleEpochReason) { self.fetch(force: true) }
            }
        }
    }

    /// 最近一次從主設備拿到的流程世代（任何執行緒都能讀；只在主執行緒寫 status）。
    private func epochForRequest() -> String? {
        if Thread.isMainThread { return status?.setupEpoch }
        return DispatchQueue.main.sync { self.status?.setupEpoch }
    }

    static let followUpOps: Set<String> = ["start_setup", "continue_setup", "reauthorize", "confirm_authorization"]
    static let followUps: [TimeInterval] = [1.5, 4, 8]

    // MARK: W183 R3b：在這台打開主機的授權頁

    /// 按了「在這台打開授權頁」之後在等主機收到授權（等的時候就算設定頁關了也繼續問；最多 10 分鐘）。
    @Published private(set) var awaitingAuthorize = false
    private var awaitingDeadline = Date.distantPast
    /// W183 R5b 審查（GPT-6）：期限自己的計時器（不靠網路回覆才收）。
    private var awaitingTimer: DispatchWorkItem?
    /// W183 R5b 審查（GPT-6）：這台現在開著的授權網址（綁這一輪有效的網址；撤回、換了、連不上、狀態太舊就收）。
    private(set) var openedLoginURL: URL?
    /// 授權完成後帶回 TAP › ChatGPT（看「已授權：帳號、網域」）；nil＝正式的 HandsSetup.open(.tap)，自測換掉。
    /// W183 R5b：只在退回舊路（授權頁開成 OS 瀏覽器分頁、設定浮層被關掉）時才帶回；開在私訊框＝設定頁照舊停在原處。
    var returnToSettings: (@MainActor () -> Void)?
    /// W183 R3b 審查：等授權結束（完成、失敗、取消、逾時）時關掉這台瀏覽器的敏感分頁（授權頁）；nil＝正式的通知，自測換掉。
    /// W183 R5b／R8b：同一條也關掉私訊框 Browser 的授權分頁（DMBrowser 聽 HandsSetup.postCloseLoginPages 發的通知）；帶網址＝只收這台開的那一張。
    var closeLoginPages: (@MainActor (URL?) -> Void)?
    /// W183 R8b：授權完成（或在等你確認帳號與網域）＝這台開的授權頁在私訊框 Browser 標「完成」、不關；nil＝正式的通知，自測換掉。
    var loginPageDone: (@MainActor (URL) -> Void)?
    /// W183 R8b 審查（Claude）：網址撤回、主機還在收尾（查網域、寫鑰匙圈）＝頁面先關掉、分頁留著寫「確認中」；nil＝正式的通知，自測換掉。
    var loginPageWithdrawn: (@MainActor (URL) -> Void)?
    /// W183 R8b 審查（GPT-6）：這台開的授權頁是主機哪一輪的（開頁那一刻的設定工作編號）；標「完成」要同一輪。
    private var openedRun: String?
    /// 這台開的授權頁已經撤下（頁面關了、分頁寫「確認中」），等主機的結果。
    private var openedPageWithdrawn = false
    /// W183 R5b：授權頁在哪開（回 true＝這台的私訊框、false＝退回 OS 瀏覽器分頁）；nil＝正式的 HandsSetup.openLoginPage，自測換掉。
    var openLoginPage: (@MainActor (URL) -> Bool)?
    static let defaultAwaitLimit: TimeInterval = 600
    /// 等授權最多多久（自測可以縮短）。
    var awaitLimit: TimeInterval = HandsRemoteClient.defaultAwaitLimit
    /// W183 R5b：這一次的授權頁是不是退回 OS 瀏覽器分頁開的（那條會關設定浮層，授權完才要帶回設定頁）。
    private var openedInTab = false

    /// 在這台打開主機的授權頁（W183 R5b：這台的私訊框，手機 App 的內嵌瀏覽器；私訊鈕關掉才退回 OS 瀏覽器分頁）。
    /// 只開 Cloudflare 授權頁的網址。頁面上的「取消」＝這台先不等了、再請主機取消這一輪的授權。
    @MainActor func openLoginHere(_ url: URL) {
        guard HandsCloudflared.loginURL(in: url.absoluteString) == url else { return }
        if !awaitingAuthorize { watch() }
        awaitingAuthorize = true
        armDeadline()
        openedLoginURL = url
        openedRun = status?.setupRun   // W183 R8b 審查：綁開頁那一刻主機的這一輪
        openedPageWithdrawn = false
        let inSheet = openLoginPage?(url)
            ?? HandsSetup.openLoginPage(url, onCancel: { [weak self] in self?.cancelFromPage() })
        openedInTab = !inSheet
    }

    /// W183 R5b 審查（Claude）：頁面頂列「取消」——這台馬上不等了（不等下一輪輪詢，按「繼續」的新一輪照樣自動打開），再請主機取消。
    @MainActor func cancelFromPage() {
        disarmAutoOpen()
        openedLoginURL = nil   // 頁面自己已經收回
        endAwaiting(closePage: false)
        act("cancel_setup")
    }

    @MainActor private func armDeadline() {
        awaitingDeadline = Date().addingTimeInterval(awaitLimit)
        awaitingTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.expireAwaiting() } }
        awaitingTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + awaitLimit, execute: item)
    }

    /// 期限到了（不管網路有沒有回）：收頁、不等了。重新開始等會換掉這個計時器，所以叫到就是這一次的期限。
    @MainActor private func expireAwaiting() {
        guard awaitingAuthorize else { return }
        endAwaiting(closePage: true)
    }

    @MainActor private func endAwaiting(closePage: Bool) {
        guard awaitingAuthorize else { return }
        awaitingAuthorize = false
        awaitingTimer?.cancel()
        awaitingTimer = nil
        unwatch()
        if closePage { closeOpenedPage() }
    }

    /// 收回這台開的授權頁（私訊框的頁面、退路的敏感分頁）。
    @MainActor private func closeOpenedPage() {
        guard let url = openedLoginURL else { return }   // 已經收了（或頁面自己按了取消）
        openedLoginURL = nil
        openedPageWithdrawn = false
        if let hook = closeLoginPages { hook(url) } else { HandsSetup.postCloseLoginPages(only: url) }
    }

    /// W183 R5b 審查（GPT-6）：頁開著，但狀態太久沒從主機更新（查詢卡住）＝確認不到主機還在等這個網址：收頁。
    @MainActor private func checkFreshness(now: Date = Date()) {
        guard openedLoginURL != nil else { return }
        if let status, now.timeIntervalSince(status.fetchedAt) <= HandsRemoteStatus.freshFor { return }
        closeOpenedPage()
    }

    // MARK: W183 R5b：這台按的那一輪＝授權頁在這台自動打開（主機不開）

    /// 開始、繼續、重新授權（主機以 trigger .remote 跑）。
    static let autoOpenOps: Set<String> = ["start_setup", "continue_setup", "reauthorize"]
    /// 最多等主機拿到授權網址多久（第 2 步可能要下載 cloudflared）。
    static let autoOpenLimit: TimeInterval = 20 * 60
    /// 這台按了、還在等主機拿到授權網址（nil＝沒在等）。只在主執行緒讀寫。
    private var autoOpenUntil: Date?
    /// W183 R5b 審查（GPT-6）：這台按的那一輪（主機給的設定工作編號）。
    private var autoOpenRun: String?
    /// 自測看：這台現在在等主機的授權網址。
    var autoOpenArmed: Bool { autoOpenUntil != nil }

    @MainActor private func armAutoOpen(run: String) {
        if autoOpenUntil == nil { watch() }   // 設定頁關了也繼續問，網址一出來就打開
        autoOpenUntil = Date().addingTimeInterval(Self.autoOpenLimit)
        autoOpenRun = run
    }

    @MainActor private func disarmAutoOpen() {
        guard autoOpenUntil != nil else { return }
        autoOpenUntil = nil
        autoOpenRun = nil
        unwatch()
    }

    /// 每次拿到主設備的狀態後（主執行緒）：這一輪是這台按的（編號對、主機記的按的那台是這台）、主機拿到授權網址了＝在這台的私訊框自動打開。
    /// 等太久、連不上、換了一輪（例如別台取消後重開）、這一輪不是這台按的、主機這一輪沒有要授權（已經授權過、停在別的步驟、做完了）＝不等了。
    @MainActor private func autoOpen(_ status: HandsRemoteStatus?) {
        guard let until = autoOpenUntil, let run = autoOpenRun else { return }
        guard Date() <= until, let status, status.setupRun == run, status.setupRunMine else {
            disarmAutoOpen()
            return
        }
        if let url = status.loginURL {
            disarmAutoOpen()
            openLoginHere(url)
        } else if !status.setupBusy {
            disarmAutoOpen()
        }
    }

    /// 每次拿到主設備的狀態後（主執行緒）：已開的頁綁這一輪有效的網址；主機不再等授權了就停止等；授權完成（或在等你確認帳號與網域）＝帶回設定頁。
    @MainActor private func settleAwaiting(_ status: HandsRemoteStatus?) {
        guard awaitingAuthorize else { return }
        // W183 R5b 審查（GPT-6）：連不上（確認不到主機還在等）＝馬上收頁、不再等（「在這台打開授權頁」可以再按）。
        guard let status else {
            endAwaiting(closePage: true)
            return
        }
        // W183 R8b 審查（GPT-6）：主機正在跑的是別的一輪（不是開頁那一輪）＝這一頁不是它的（主機跑完一輪會清掉編號：沒有編號＝沒有新的一輪）。
        let otherRun = status.setupRun != nil && status.setupRun != openedRun
        if let url = openedLoginURL, status.loginURL != url {
            if status.loginURL != nil || otherRun {
                closeOpenedPage()   // W183 R5b 審查：網址換了、換了一輪＝馬上收
            } else if !openedPageWithdrawn {
                // W183 R8b 審查（Claude）：網址撤回、同一輪還在收尾（cloudflared 剛結束到寫下結果之間：查網域、寫鑰匙圈）＝
                // 頁面馬上關掉（R5b「網址撤回就收頁面」照舊），分頁先留著寫「確認中」，等結果再決定標完成或收掉。
                openedPageWithdrawn = true
                if let hook = loginPageWithdrawn { hook(url) } else { HandsSetup.postLoginPagesWithdrawn(only: url) }
            }
        }
        let step = status.setup.first(where: { $0.step == HandsSetupStep.authorize.rawValue })?.status
        let confirming = status.authorizedNeedsConfirm && status.loginURL == nil
        let authorized = step == HandsSetupStatus.done.rawValue || confirming
        let timedOut = Date() > awaitingDeadline
        // 網址拿掉了、第 3 步也不在跑或等（完成、失敗、取消）才算結束：cloudflared 剛結束到寫下「完成」之間的那一下不算。
        // W183 R3b 審查：等你確認帳號與網域也算結束（要回設定頁按確認）。
        let settled = status.loginURL == nil
            && (confirming || (step != HandsSetupStatus.waitingUser.rawValue && step != HandsSetupStatus.running.rawValue))
        guard timedOut || settled else { return }
        // W183 R8b：授權完成（完成、或在等你確認）而且是開頁那一輪＝這台開的那一頁標「完成」（分頁不會自己消失，使用者自己關）；
        // 失敗、取消、逾時、別的一輪＝收掉。W183 R8b 審查（GPT-6）：核對開頁那一輪；而且要看得出是這一頁的登入（在等你確認帳號與網域
        // ＝剛在瀏覽器登入過；或網址撤回時同一輪還在收尾）——別的一輪不用登入就做完的「完成」不算這一頁的。
        if authorized, !timedOut, !otherRun, confirming || openedPageWithdrawn, let url = openedLoginURL, Self.authorizationFinished(status) {
            openedLoginURL = nil
            openedPageWithdrawn = false
            if let hook = loginPageDone { hook(url) } else { HandsSetup.postLoginPagesDone(only: url) }
        }
        endAwaiting(closePage: true)   // 還沒標完成的授權頁（私訊框的分頁／敏感分頁）收回
        // W183 R5b：開在私訊框＝設定浮層沒關、設定頁照舊停在原處（看得到「請確認帳號與網域」），不跳頁；退回分頁那條才帶回。
        guard authorized, !timedOut, openedInTab else { return }
        if let hook = returnToSettings { hook() } else { HandsSetup.open(.tap) }
    }

    /// W183 R8b：主機的第 3 步做完了（完成、或授權拿到了在等你確認帳號與網域）。
    static func authorizationFinished(_ status: HandsRemoteStatus) -> Bool {
        let step = status.setup.first(where: { $0.step == HandsSetupStep.authorize.rawValue })?.status
        return step == HandsSetupStatus.done.rawValue || (status.authorizedNeedsConfirm && status.loginURL == nil)
    }

    /// 自測：等授權、等自動打開時不另外起輪詢（自測自己餵狀態）。正式一律 true。
    var pollsWhileWaiting = true

    /// 畫面看得到時每 10 秒問一次（配對碼、狀態）；看不到就停。
    /// visible（W183 R6a）：設定頁本身在看（連不上的退避上限縮成 10 秒內）；等授權、等［連線］的背景觀看不算。
    func watch(visible: Bool = false) {
        lock.lock(); watchers += 1; if visible { visibleWatchers += 1 }; let start = watchers == 1 && pollsWhileWaiting; lock.unlock()
        guard start else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: Self.interval)
        source.setEventHandler { [weak self] in
            self?.fetch()
            MainActor.assumeIsolated { self?.checkFreshness() }   // W183 R5b 審查：查詢卡住時頁不留著
        }
        source.resume()
        lock.lock(); timer = source; lock.unlock()
    }

    func unwatch(visible: Bool = false) {
        lock.lock()
        watchers = max(watchers - 1, 0)
        if visible { visibleWatchers = max(visibleWatchers - 1, 0) }
        let stop = watchers == 0; let source = stop ? timer : nil; if stop { timer = nil }
        lock.unlock()
        source?.cancel()
    }

    /// W183 R6a：設定頁一出現（或主機設定一變）就強制問一次：還沒拿到狀態不會一直卡「讀取中」；連不上的退避也不等（看得到＝最多 10 秒）。
    func refreshNow() { fetch(force: true) }

    // MARK: W183 R6a：這台按的開關＝主機走到「等你按［連線］」時，這台的私訊框出［連線］卡

    /// 按了這些（主機真的開始了）＝等主機走到連線那一步（最多 30 分鐘；中間要等使用者授權 Cloudflare、確認網域）。
    static let offerOps: Set<String> = ["start_setup", "continue_setup", "confirm_authorization", "reauthorize"]
    static let offerLimit: TimeInterval = 30 * 60
    /// 只在主執行緒讀寫。
    private var offerUntil: Date?
    /// 自測看：這台在等主機走到連線那一步。
    var offerArmed: Bool { offerUntil != nil }
    /// 出［連線］卡（nil＝正式的 HandsConnectFlow.shared.offer；自測換掉）。
    var offerConnect: (@MainActor () -> Void)?

    /// 主機的狀態說「關口起來了、還沒有 grant、配對那一步在等使用者」＝可以出［連線］卡。
    static func readyForConnect(_ status: HandsRemoteStatus) -> Bool {
        status.enabled && !status.setupBusy && status.phaseState == "running" && status.grants.isEmpty
            && status.setup.first(where: { $0.step == HandsSetupStep.pairing.rawValue })?.status == HandsSetupStatus.waitingUser.rawValue
    }

    @MainActor private func armOffer() {
        if offerUntil == nil { watch() }   // 設定頁關了也繼續問，走到連線那一步就出卡
        offerUntil = Date().addingTimeInterval(Self.offerLimit)
    }

    @MainActor private func disarmOffer() {
        guard offerUntil != nil else { return }
        offerUntil = nil
        unwatch()
    }

    /// 每次拿到主機的狀態（主執行緒）：走到連線那一步＝出卡（一次）；已經連上、關掉了、等太久＝不等了；連不上＝照等（期限內）。
    @MainActor private func offerIfReady(_ status: HandsRemoteStatus?) {
        guard let until = offerUntil else { return }
        guard Date() <= until else { return disarmOffer() }
        guard let status else { return }
        if !status.enabled || !status.grants.isEmpty { return disarmOffer() }
        guard Self.readyForConnect(status) else { return }
        disarmOffer()
        if let hook = offerConnect { hook() } else { HandsConnectFlow.shared.offer() }
    }

    static func plain(_ error: Error) -> String {
        let text = String(describing: error)
        if ["Connection reset", "Connection closed", "ssh_remote_login_unresponsive"].contains(where: text.contains) { return "主設備的遠端登入沒有回應" }
        if text.contains("untrusted_rpc_sender") || text.contains("revoked_rpc_key") { return "這台還沒跟主設備配對好" }
        if text.contains("caller_not_trusted") || text.contains("unknown") { return "主設備的 TATWO OS 版本太舊" }
        if text.contains("primary_not_paired") || text.contains("authority_unknown") { return "還沒設定主設備" }
        return "網路或主設備沒開"
    }

    #if DEBUG
    /// W183 R5b 審查自測：這台按了（綁那一輪的編號）、收到主機的狀態（nil＝連不上）、查詢卡住多久之後。
    @MainActor func debugArm(run: String) { armAutoOpen(run: run) }
    /// W183 R6a 自測：這台按了開關（等主機走到連線那一步）。
    @MainActor func debugArmOffer() { armOffer() }
    @MainActor func debugReceive(_ received: HandsRemoteStatus?) {
        status = received ?? status?.withoutPairing()
        autoOpen(received)
        settleAwaiting(received)
        offerIfReady(received)
    }
    @MainActor func debugCheckFreshness(now: Date) { checkFreshness(now: now) }

    /// 自測：現在的退避狀態。
    var debugBackoff: (inFlight: Bool, failures: Int, nextAllowed: Date) { lock.lock(); defer { lock.unlock() }; return (inFlight, failures, nextAllowed) }
    var debugStartTimes: [Date] { lock.lock(); defer { lock.unlock() }; return debugStarts }
    #endif
}
