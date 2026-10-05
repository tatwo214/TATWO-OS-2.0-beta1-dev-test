import Foundation

// W183 R8c：每台的背景同步、套用自己那一份、執行別台交代的事（GPT-6 必改 2、3）。
//
// - 背景同步不靠設定頁開著（App 啟動就開始；自測、staging 不跑）：副設備定時問主設備，主設備在行程內自己做。
//   每一輪：回報這台的公共狀態（沒有秘密）→ 收主設備簽的信封（驗章、防回滾）→ 套用自己那一份（HandsBuildReconciler）→
//   做給這台的意圖（HandsBuildExecutor）→ 取回這台是擁有者的結果（登入網址、配對碼、回執；ack 之後主設備才拿掉）→ 更新畫面看的全貌。
// - W183 R8c 審查（Claude 高／中「背景輪詢一直在跑」）：多久問一次看需要——有事在跑（這台送出、剛收到意圖、畫面開著）1.5 秒；
//   這台被勾、許可有效 15 秒；沒被勾 60 秒；還沒有設定 120 秒；連不到主設備＝10 秒起一路加倍到 5 分鐘。主設備自己：有副設備在熱問、
//   這台有事＝2 秒，否則 30 秒。信封跟已接受的一樣＝不重驗章；畫面看的全貌沒變＝不重發。
// - 套用（reconcile）的界線：
//   * 撤銷世代變大（明確關掉這台）＝先作廢進行中的設定工作（換世代、收掉 cloudflared），再撤銷這台全部 grant、關開關；存不進去＝不算套用（下一輪再做）。
//   * 這台的版本變大＝子網域照 build 的、等級與專案**只收窄**（W183 R10 改：等級照中央設定寫進本機〔本機欄位只剩相容與畫面，
//     有效範圍直接看中央：HandsSettings.centralized〕、專案不再照中央清單收窄〔全部可見〕）；這台「從沒勾變成勾了」而且已經有網址＝打開；只恢復已經建好的
//     （HandsSetup.resumeIfEnabled：不登入、不新建、不改 DNS、不換網址、不 offer）。同一版＝不動（不會把使用者在這台剛改的等級改回去）。
//   * 許可沒了（信封過期、不再勾這台）＝安全暫停的收尾：收掉跑著的工作、關配對窗口；grant 留著（明確關掉才撤銷）。
//   * 換了主設備（配對到另一台主設備）＝明確的交接：撤銷全部 grant、從頭記版本（不混用舊的計數）。
//   * **輪詢套用不冒充人工重試**：只叫 settingsDidChange／resumeIfEnabled，從不叫 retry——安全停機鎖只有使用者對那台明確解除（unlock_safety）。
// - 執行（B 是最終決策者）：驗目標是這台、沒過期、B 的 setupEpoch 對得上（登入、套用、解除安全鎖、撤銷一定要帶）、套用時設定版本要等於
//   B 已接受的；先把 operationID 記進 app/build-ops.json（0600）才做：同一件再送一次不重做、不重開窗口；取消先到＝墓碑（綁擁有者），晚到的那件不做。

/// 套用這台自己那一份。
struct HandsBuildReconciler {
    var service: HandsService
    var applied: HandsBuildAppliedStore
    /// 只恢復已經建好的（不登入、不新建、不 offer）。
    var resume: () -> Void
    /// 叫關口照設定判斷（不是 retry：安全停機鎖不解除）。
    var serviceChanged: () -> Void
    /// 關掉這台、許可沒了時，進行中的［連線］作廢。
    var cancelConnect: (String) -> Void
    /// W183 R8c 審查（GPT-6 高）：關掉這台時**先**作廢進行中的設定工作（HandsSetup.cancel：換世代、收掉 cloudflared）。
    var cancelSetup: () -> Void = {}
    /// W183 R8c 審查（GPT-6 高）：許可沒了（安全暫停）＝收掉跑著的工作、關配對窗口（grant 留著）。
    var suspend: () -> Void = {}
    /// 上一輪許可是不是 active（只在記憶體；轉成不 active 的那一下才收尾）。
    let lastActive = HandsLocked<Bool?>(nil)

    enum Outcome: Equatable, Sendable { case none, revoked, enabled, narrowed, recorded, suspended, refused, transitioned }

    /// primary：這台現在信的主設備（正本這台＝自己）；nil＝不核交接（自測的單一世界）。
    @discardableResult
    func apply(_ state: HandsBuildPermit.State, configRevision: Int?, local: String, primary: String? = nil) -> Outcome {
        var outcome: Outcome = .none
        // 0. 許可沒了（active → 暫停／沒勾／沒有）：安全暫停的收尾（工作、配對窗口、進行中的連線）；grant 不撤銷。
        let wasActive = lastActive.get()
        lastActive.set(state.isActive)
        if wasActive == true, !state.isActive {
            suspend()
            cancelConnect("build_paused")
            serviceChanged()
            outcome = .suspended
        }
        guard let slice = state.slice, HandsHostAuthority.same(slice.deviceID, local) else { return outcome }
        var record = applied.load() ?? HandsBuildApplied()
        let before = record
        // 換了主設備：明確的交接（不混用舊的計數）。
        if let primary, let old = record.primaryID, !HandsHostAuthority.same(old, primary) {
            cancelSetup()
            cancelConnect("authority_changed")
            _ = service.auth.revokeAll(reason: "authority_changed")
            _ = try? service.updateSettings { $0.enabled = false }
            serviceChanged()
            record = HandsBuildApplied()
            outcome = .transitioned
        }
        if let primary { record.primaryID = primary.lowercased() }
        var failed = false
        // 1. 明確關掉這台（撤銷世代變大）：先作廢進行中的設定工作，再撤銷全部連線、關開關。存不進去＝不算套用（下一輪再做）。
        if slice.revocationGeneration > record.revocationGeneration {
            cancelSetup()
            cancelConnect("build_disabled")
            if service.settings.load().enabled {
                _ = try? service.updateSettings { $0.enabled = false }
            }
            if !service.auth.activeGrantIDs.isEmpty { _ = service.auth.revokeAll(reason: "build_disabled") }
            serviceChanged()
            let durable = !service.settings.load().enabled && !service.settings.forcedOff && service.auth.activeGrantIDs.isEmpty
                && service.auth.revocationProblem == nil
            if durable { record.revocationGeneration = slice.revocationGeneration } else { failed = true }
            outcome = .revoked
        }
        // 2. 這台的內容變了（新的想要的樣子）：子網域照 build 的；等級與專案只收窄；「從沒勾變成勾了」而且已經有網址＝打開。
        let hash = slice.contentKey.contentHash
        if slice.deviceRevision == record.deviceRevision, let known = record.contentHash, known != hash, slice.deviceRevision > 0 {
            // 同一版、不同內容（主設備還原、實作錯誤）：不套用（撤銷那一段照做、照記）。
            if record != before { try? applied.save(record) }
            return .refused
        }
        if slice.deviceRevision > record.deviceRevision, !failed {
            let becameActive = slice.active && record.active != true
            do {
                _ = try service.updateSettings { settings in
                    if slice.active {
                        // W183 R8c 審查（Claude 中）：只有「從沒勾變成勾了」才打開——使用者在這台自己關掉之後，別的內容改了不會被偷偷打開。
                        if becameActive, HandsGatewayLaunch.validHost(settings.publicHost) != nil { settings.enabled = true }
                        settings.hostDeviceID = local
                        settings.subdomainLabel = slice.subdomain
                    }
                    // W183 R10：本機的等級跟中央設定一樣（收窄照舊收工作、鎖工作區；放大也立刻生效，不用到主機再核准）。
                    // 專案不再照中央清單收窄：有效範圍＝這台全部專案（本機的 allowed_project_ids 不是閘門，留著不動）。
                    settings.level = slice.level
                }
                record.deviceRevision = slice.deviceRevision
                record.active = slice.active
                record.contentHash = hash
            } catch {
                failed = true
                // W183 R8 整合審查（GPT-6 高「中央權限收窄存不進去，舊 grant 仍可用原本較大的權限」）：收窄沒存成＝跑著的工作先收掉
                // （新的工具呼叫、工作啟動、發布本來就照有效設定核：W183 R10 起直接看中央設定，HandsService.effectiveSettings）；
                // 不 resume，下一輪再存。
                let local = service.settings.load()
                if local.level > slice.level { suspend() }
            }
            serviceChanged()
            if slice.active, !failed { resume() }
            if outcome == .none { outcome = slice.active ? .enabled : .narrowed }
        }
        // 3. 舊的（升級前的）grant：這台現在有許可＝明確遷移一次（蓋上這台的綁定），之後沒綁定的一律撤銷。
        if state.isActive, !failed, let binding = service.auth.binding?() { service.auth.upgradeLegacyBindings(binding) }
        if !failed, let configRevision { record.configRevision = max(configRevision, record.configRevision) }
        if record != before {
            try? applied.save(record)
            if outcome == .none { outcome = .recorded }
        }
        return outcome
    }
}

/// B 這端：做別台交代的事（B 是最終決策者）。
final class HandsBuildExecutor: @unchecked Sendable {
    struct Dependencies {
        var localID: () -> String?
        var setup: () -> HandsSetup
        var service: () -> HandsService
        var remoteHost: () -> HandsRemote.Host
        /// 使用者明確解除安全停機鎖：事故編號對上才解除（ChatGPTHandsService.unlockSafety(incident:)）。回 true＝解除了。
        var unlockSafety: (_ incident: String) -> Bool
        /// 這台現在的那一份與它的設定版本（副設備：已接受的信封；正本：自己的設定）。
        var current: () -> (slice: HandsBuildDeviceSlice, configRevision: Int)?
        var accounts: () -> CloudflareAccountsStore
        var now: () -> Date = Date.init
    }

    struct Ledger: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var action: String
            var owner: String
            var at: Date
            var outcome: String
        }
        struct Tombstone: Codable, Equatable {
            var owner: String
            var at: Date
        }
        var processed: [String: Entry] = [:]
        var tombstones: [String: Tombstone] = [:]
    }

    /// 只記在記憶體的（讀而已、可以重做的：連線狀態、卡片內容）；其他一律先落地才做。
    static let readOnlyConnectOps: Set<String> = ["connect_offer", "connect_status"]
    /// W183 R8c 審查（GPT-6 高）：一定要帶 B 的 setupEpoch 的（沒帶＝不做）。
    static let epochActions: Set<String> = ["login", "apply_urls", "unlock_safety", "revoke_all"]
    static let maxLedger = 512

    let dependencies: Dependencies
    let ledgerURL: URL
    /// 交結果（本機直接交主設備、或經 RPC）。由 HandsBuildSync 接上。
    var post: (HandsBuildResult) -> Void = { _ in }
    private let queue = DispatchQueue(label: "tatwo.hands-build.executor", qos: .userInitiated)
    private let lock = NSLock()
    private var memoryOnly: Set<String> = []
    /// 正在跑的登入（operationID、擁有者）：login_cancel 要取消的是它（W183 R8c 審查：原子地佔用，忙碌的第二件不會蓋掉）。
    private var runningLogin: (id: String, owner: String)?

    init(dependencies: Dependencies, ledgerURL: URL) {
        self.dependencies = dependencies
        self.ledgerURL = ledgerURL
    }

    func execute(_ intents: [HandsBuildIntent]) {
        for intent in intents { queue.async { [weak self] in self?.run(intent) } }
    }

    typealias ApplyCurrent = () throws -> (slice: HandsBuildDeviceSlice, configRevision: Int)

    /// 原生 UI 的本機套用；每件事自帶回覆，不改共享 post、不進遠端信箱。
    func applyHere(_ intent: HandsBuildIntent, current: @escaping ApplyCurrent,
                   timeout: TimeInterval = 930, completion: @escaping (HandsBuildResult) -> Void) {
        let delivery = HandsBuildLocalReply(completion)
        let reply: (HandsBuildResult) -> Void = { delivery.send($0) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            reply(HandsBuildResult(operationID: intent.operationID, seq: 64, final: true,
                                  object: ["state": "unknown", "reason": "result_unknown"]))
        }
        queue.async { [weak self] in
            guard let self, delivery.pending else { return }
            guard intent.action == "apply_urls", HandsHostAuthority.same(intent.owner, self.dependencies.localID()) else {
                return self.refuse(intent, "not_target", completion: reply)
            }
            self.run(intent, localCurrent: current, completion: reply)
        }
    }

    /// 自測：同步做完（不經佇列）。
    func executeNow(_ intent: HandsBuildIntent) { queue.sync { run(intent) } }

    /// 等佇列上的事做完（自測）。
    func drain() { queue.sync {} }

    private func loadLedger() -> Ledger {
        guard let data = HandsFiles.readSecure(ledgerURL, limit: 1024 * 1024) else { return Ledger() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Ledger.self, from: data)) ?? Ledger()
    }

    private func saveLedger(_ ledger: Ledger) -> Bool {
        var trimmed = ledger
        let cutoff = dependencies.now().addingTimeInterval(-86_400)
        trimmed.processed = trimmed.processed.filter { $0.value.at > cutoff }
        trimmed.tombstones = trimmed.tombstones.filter { $0.value.at > cutoff }
        if trimmed.processed.count > Self.maxLedger {
            let keep = trimmed.processed.sorted { $0.value.at > $1.value.at }.prefix(Self.maxLedger)
            trimmed.processed = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return (try? HandsFiles.writeAtomically(try encoder.encode(trimmed), to: ledgerURL)) != nil
    }

    private func finish(_ intent: HandsBuildIntent, _ object: [String: Any], seq: Int = 0,
                        completion: ((HandsBuildResult) -> Void)? = nil) {
        (completion ?? post)(HandsBuildResult(operationID: intent.operationID, seq: seq, final: true, object: object))
    }

    private func refuse(_ intent: HandsBuildIntent, _ reason: String, completion: ((HandsBuildResult) -> Void)? = nil) {
        finish(intent, ["state": "refused", "reason": reason], completion: completion)
    }

    private func run(_ intent: HandsBuildIntent, localCurrent: ApplyCurrent? = nil,
                     completion: ((HandsBuildResult) -> Void)? = nil) {
        let now = dependencies.now()
        guard let local = dependencies.localID(), HandsHostAuthority.same(intent.target, local) else { return refuse(intent, "not_target", completion: completion) }
        guard intent.expiresAt > now else { return refuse(intent, "expired", completion: completion) }
        // 排隊之後再驗主權、版本、信封期限；套用取快照時還會再驗一次。
        do { _ = try localCurrent?() }
        catch { return refuse(intent, Self.localApplyReason(error), completion: completion) }
        let readOnly = intent.action == "connect" && Self.readOnlyConnectOps.contains(intent.payloadObject["remote_op"] as? String ?? "")
        // 冪等＋墓碑：先記下來才做（當掉、P 重播、A 重送都不重做）。
        lock.lock()
        var ledger = loadLedger()
        if readOnly {
            if memoryOnly.contains(intent.operationID) { lock.unlock(); return refuse(intent, "duplicate", completion: completion) }
            memoryOnly.insert(intent.operationID)
            if memoryOnly.count > 256 { memoryOnly.removeFirst() }
        } else {
            if let seen = ledger.processed[intent.operationID] {
                lock.unlock()
                return finish(intent, ["state": "duplicate", "outcome": seen.outcome], completion: completion)
            }
            if let tomb = ledger.tombstones[intent.operationID], HandsHostAuthority.same(tomb.owner, intent.owner) {
                ledger.processed[intent.operationID] = .init(action: intent.action, owner: intent.owner, at: now, outcome: "cancelled_before_start")
                _ = saveLedger(ledger)
                lock.unlock()
                return finish(intent, ["state": "cancelled", "reason": "cancelled_before_start"], completion: completion)
            }
            ledger.processed[intent.operationID] = .init(action: intent.action, owner: intent.owner, at: now, outcome: "started")
            guard saveLedger(ledger) else { lock.unlock(); return refuse(intent, "ledger_not_saved", completion: completion) }
        }
        lock.unlock()
        if Self.epochActions.contains(intent.action), let problem = epochProblem(intent) {
            record(intent, problem)
            return refuse(intent, problem, completion: completion)
        }
        switch intent.action {
        case "login": login(intent)
        case "login_cancel": loginCancel(intent)
        case "apply_urls": apply(intent, localCurrent: localCurrent, completion: completion)
        case "connect": connect(intent)
        case "revoke_all": revokeAll(intent)
        case "unlock_safety": unlock(intent)
        default:
            refuse(intent, "action")
        }
    }

    private func record(_ intent: HandsBuildIntent, _ outcome: String) {
        lock.lock(); defer { lock.unlock() }
        var ledger = loadLedger()
        ledger.processed[intent.operationID]?.outcome = outcome
        _ = saveLedger(ledger)
    }

    /// B 的 setupEpoch（B 重開、取消、關過就換）。W183 R8c 審查（GPT-6 高）：一定要帶（沒帶＝不做）。
    private func epochProblem(_ intent: HandsBuildIntent) -> String? {
        guard let epoch = intent.setupEpoch else { return "epoch_missing" }
        return epoch == dependencies.setup().setupEpoch ? nil : "epoch_stale"
    }

    private func login(_ intent: HandsBuildIntent) {
        // W183 R8c 審查（GPT-6 中）：原子地佔用「登入」這個位子；已經有一件在跑＝這件回忙碌（不蓋掉那一件的取消控制）。
        lock.lock()
        if runningLogin != nil { lock.unlock(); record(intent, "busy"); return refuse(intent, "busy") }
        runningLogin = (intent.operationID, intent.owner)
        lock.unlock()
        let seq = HandsLocked(0)
        // 授權網址只交給擁有者（經 P；不進公共狀態、不寫檔、不給 AI）。最後一則結果再交帳號與網域名稱（畫面用，不是秘密）。
        let started = dependencies.setup().loginForRemote(requester: intent.owner, operationID: intent.operationID, onURL: { [weak self] url in
            guard let self else { return }
            seq.update { $0 += 1 }
            self.post(HandsBuildResult(operationID: intent.operationID, seq: seq.get(), final: false,
                                       object: ["state": "login_url", "url": url.absoluteString]))
        }, onEnd: { [weak self] outcome in
            guard let self else { return }
            self.lock.lock(); if self.runningLogin?.id == intent.operationID { self.runningLogin = nil }; self.lock.unlock()
            seq.update { $0 += 1 }
            switch outcome {
            case .authorized(let account, let zones):
                self.record(intent, "authorized")
                self.finish(intent, ["state": "authorized", "account": account, "zones": zones], seq: seq.get())
            case .failed(let message):
                self.record(intent, "failed")
                self.finish(intent, ["state": "failed", "reason": String(message.prefix(300))], seq: seq.get())
            case .cancelled:
                self.record(intent, "cancelled")
                self.finish(intent, ["state": "cancelled"], seq: seq.get())
            case .busy:
                self.record(intent, "busy")
                self.finish(intent, ["state": "refused", "reason": "busy"], seq: seq.get())
            }
        })
        if !started { lock.lock(); if runningLogin?.id == intent.operationID { runningLogin = nil }; lock.unlock() }
    }

    /// W183 R8c 審查（GPT-6 中）：取消要找得到**那一件**、而且是同一個擁有者；真的取消了才回成功。
    /// 還沒開始＝墓碑（綁擁有者；存不進去＝回失敗，不假裝取消了）；已經結束＝照實回。
    private func loginCancel(_ intent: HandsBuildIntent) {
        guard let target = (intent.payloadObject["operation_id"] as? String).flatMap({ UUID(uuidString: $0) != nil ? $0.lowercased() : nil }) else {
            return refuse(intent, "operation_id")
        }
        lock.lock()
        let running = runningLogin
        var ledger = loadLedger()
        if let running, running.id == target {
            lock.unlock()
            guard HandsHostAuthority.same(running.owner, intent.owner) else { record(intent, "not_owner"); return refuse(intent, "not_owner") }
            let cancelled = dependencies.setup().cancelRemoteLogin(target)
            record(intent, cancelled ? "cancelled_running" : "not_running")
            return cancelled ? finish(intent, ["state": "done", "was_running": true]) : refuse(intent, "not_running")
        }
        if let seen = ledger.processed[target] {
            lock.unlock()
            let finished = seen.outcome != "started"
            record(intent, finished ? "already_finished" : "not_running")
            return refuse(intent, finished ? "already_finished" : "not_running")
        }
        ledger.tombstones[target] = .init(owner: intent.owner, at: dependencies.now())   // 取消比登入先到：墓碑（晚到的那件不做、不開窗口）
        let saved = saveLedger(ledger)
        lock.unlock()
        guard saved else { record(intent, "ledger_not_saved"); return refuse(intent, "ledger_not_saved") }
        record(intent, "tombstone")
        finish(intent, ["state": "done", "was_running": false])
    }

    /// 「套用」：B 用自己已接受的那一份（設定版本要跟 A 按的時候看到的一樣），拍成不變的 HandsApplyPlan 交給設定流程。
    static func localApplyReason(_ error: Error) -> String {
        switch error {
        case HandsBuildSyncError.configChanged: return "config_changed"
        case HandsBuildSyncError.unavailable(let reason): return reason
        default: return "no_config"
        }
    }

    private func apply(_ intent: HandsBuildIntent, localCurrent: ApplyCurrent? = nil,
                       completion: ((HandsBuildResult) -> Void)? = nil) {
        func reject(_ reason: String) { record(intent, reason); refuse(intent, reason, completion: completion) }
        // 套用的是 B 已接受的那一份（設定版本要一樣：A 看到的跟 B 手上的不同＝先同步，這次不做）。
        let snapshot: (slice: HandsBuildDeviceSlice, configRevision: Int)?
        do { snapshot = try localCurrent.map { try $0() } ?? dependencies.current() }
        catch { return reject(Self.localApplyReason(error)) }
        guard let current = snapshot else { return reject("no_config") }
        guard current.configRevision == intent.configRevision else { return reject("config_changed") }
        guard current.slice.active else { return reject("not_selected") }
        guard let account = current.slice.accountID, let zone = current.slice.zoneID, let hostname = current.slice.hostname else {
            return reject("no_domain")
        }
        let accounts = dependencies.accounts()
        guard accounts.account(account)?.domains.contains(where: { $0.zoneID == zone }) == true, accounts.hasCert(zoneID: zone) else {
            return reject("not_authorized_here")
        }
        let plan = HandsApplyPlan(accountID: account, zoneID: zone, subdomain: current.slice.subdomain, hostname: hostname,
                                  revocationGeneration: current.slice.revocationGeneration)
        let setup = dependencies.setup()
        let started = setup.applyURLs(plan: plan, trigger: .remote, requester: intent.owner, finished: { [weak self] in
            guard let self else { return }
            let state = setup.snapshot
            let tunnel = state.step(.tunnel)
            if tunnel.status == .done, let host = state.publicHost, host.caseInsensitiveCompare(plan.hostname) == .orderedSame {
                self.record(intent, "applied")
                self.finish(intent, ["state": "applied", "public_host": host, "running": state.step(.start).status == .done], completion: completion)
            } else {
                let failed = HandsSetupStep.runOrder.first { state.step($0).status == .failed || state.step($0).status == .waitingUser }
                let message = failed.map { setup.redactedForAI(state.step($0).message) } ?? ""
                self.record(intent, "failed")
                self.finish(intent, ["state": "failed", "step": failed?.rawValue ?? "", "reason": String(message.prefix(300))], completion: completion)
            }
        })
        if !started { reject("busy") }
    }

    /// W183 R8c 審查（GPT-6 高）：「撤銷全部」只作用在按的時候看到的那一組 grant（摘要對上）；之後才建的連線不會被晚到的舊撤銷清掉。
    private func revokeAll(_ intent: HandsBuildIntent) {
        guard let seen = intent.payloadObject["grants_digest"] as? String, seen.utf8.count <= 80 else {
            record(intent, "grants_digest"); return refuse(intent, "grants_digest")
        }
        let service = dependencies.service()
        guard HandsAuth.constantTimeEqual(HandsBuildDeviceReport.digest(grants: service.auth.activeGrantIDs), seen) else {
            record(intent, "grants_changed"); return refuse(intent, "grants_changed")
        }
        let problem = service.revokeEverything()
        record(intent, problem == nil ? "revoked" : "revoke_not_saved")
        finish(intent, problem == nil ? ["state": "done"] : ["state": "failed", "reason": "revoke_not_saved"])
    }

    /// GPT-6 必改 4：只有這一個（使用者對這台明確按的「解除安全鎖」）會解除；輪詢、重新勾選、重開、設定同步都不會。
    /// W183 R8c 審查（GPT-6 高）：綁事故編號（晚到的舊解除清不掉新事故的鎖）、setupEpoch（上面已核）、這台的撤銷世代。
    private func unlock(_ intent: HandsBuildIntent) {
        let payload = intent.payloadObject
        guard let incident = payload["incident"] as? String, (1...64).contains(incident.utf8.count) else {
            record(intent, "incident"); return refuse(intent, "incident")
        }
        if let current = dependencies.current() {
            guard let generation = (payload["revocation_generation"] as? NSNumber)?.intValue, generation == current.slice.revocationGeneration else {
                record(intent, "generation_changed"); return refuse(intent, "generation_changed")
            }
        }
        guard dependencies.unlockSafety(incident) else { record(intent, "incident_changed"); return refuse(intent, "incident_changed") }
        record(intent, "unlocked")
        finish(intent, ["state": "done"])
    }

    /// W183 R8 整合審查（GPT-6 中「本機解除安全鎖繞過事故編號與世代核對」）：使用者在**這台**對這台按「解除安全鎖」——跟信箱那條
    /// 同一套核對（按的時候看到的 setupEpoch、撤銷世代、事故編號；最後經 unlockSafety(incident:) 原子核對才清），只是不經主設備
    /// （這台連不到主設備也解得了）。不叫不帶事故編號的 retry()。回 nil＝解除了；否則是拒絕的原因（refusalText 的代碼）。
    func unlockHere(incident: String, setupEpoch: String?, revocationGeneration: Int) -> String? {
        queue.sync {
            guard (1...64).contains(incident.utf8.count) else { return "incident" }
            guard let setupEpoch else { return "epoch_missing" }
            guard setupEpoch == dependencies.setup().setupEpoch else { return "epoch_stale" }
            if let current = dependencies.current(), current.slice.revocationGeneration != revocationGeneration { return "generation_changed" }
            return dependencies.unlockSafety(incident) ? nil : "incident_changed"
        }
    }

    private func connect(_ intent: HandsBuildIntent) {
        var payload = intent.payloadObject
        guard let op = payload.removeValue(forKey: "remote_op") as? String, HandsConnectRemote.ops.contains(op) else {
            return refuse(intent, "remote_op")
        }
        payload["op"] = op
        // 跟設備簽章 RPC 同一套主機規則（擁有者＝P 驗章得到的 A；B 核對擁有者、世代、範圍、證據）。
        do {
            let result = try HandsConnectRemote.handle(op, payload: payload, sender: intent.owner, host: dependencies.remoteHost(),
                                                       now: dependencies.now())
            if !Self.readOnlyConnectOps.contains(op) { record(intent, "done") }
            finish(intent, ["state": "done", "response": result])
        } catch {
            let text = String(describing: error)
            let code = HandsConnectRefusal.allCases.first { text.contains($0.rawValue) }?.rawValue
                ?? (text.contains(HandsRemote.expiredReason) ? HandsRemote.expiredReason : "connect_invalid")
            if !Self.readOnlyConnectOps.contains(op) { record(intent, code) }
            finish(intent, ["state": "refused", "reason": code])
        }
    }
}

enum HandsBuildSyncError: Error, Equatable, CustomStringConvertible {
    /// 送出去了、等不到結果（B 沒開、太久）：結果未知（先查，不重送）。
    case timeout
    case unavailable(String)
    /// W183 R8 整合審查（GPT-6 高）：送出那一刻的設定（版本、主設備）已經不是使用者按的時候看到的那一份：不送（不自己換版本）。
    case configChanged
    var description: String {
        switch self {
        case .timeout: "hands_build_timeout"
        case .unavailable(let why): "hands_build_unavailable:\(why)"
        case .configChanged: "hands_build_config_changed"
        }
    }
}

/// W183 R8 整合審查（GPT-6 高）：使用者按「套用」那一刻看到的那一份——主權（主設備＋主權 epoch）與設定版本。
/// 從畫面一路帶到送出（HandsBuildSync.submit）：送出前這台知道的設定要還是這一份，意圖裡的版本就是這一個（那台再核一次）。
struct HandsBuildExpected: Equatable, Sendable {
    let authority: String
    let revision: Int

    static func authority(of config: HandsBuildConfig) -> String { config.primaryID.lowercased() + "#\(config.authorityEpoch)" }
    static func of(_ config: HandsBuildConfig) -> HandsBuildExpected { HandsBuildExpected(authority: authority(of: config), revision: config.configRevision) }
}

/// 畫面看的全貌（主設備給的；沒有秘密）。
struct HandsBuildView: Equatable, Sendable {
    var config: HandsBuildConfig?
    var reports: [HandsBuildDeviceReport] = []
    var ownership = HandsBuildOwnership()
    var devices: [HandsSetupDevice] = []
    var serverTime: Date?
    /// W183 R11 第二輪：這一份是這台在什麼時候（這台的鐘）拿到的——跟 serverTime 是同一次拿到的一對（內容沒變不重發時兩個一起留著），
    /// 換算「那台的回報是這台的什麼時候收到的」要用這一對，不能拿別次同步的時間配這一份的 serverTime。
    var localTime: Date?
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：同一次拿到時這台的單調時鐘（跟 localTime 比＝這台的牆上時鐘之後有沒有跳過）。
    var localUptime: TimeInterval?
    /// W183 R11 最後一輪：主設備的時鐘在上一份和這一份之間跳過（主設備時間走的跟這台的單調時鐘差太多）：這一份的新舊算不準。
    var serverClockJumped = false

    /// 兩個時鐘走的差太多＝有一邊跳過（倒退或大跳）。容忍網路來回的差。
    static let clockTolerance: TimeInterval = 10
    static func clockJumped(wall: TimeInterval, monotonic: TimeInterval) -> Bool { abs(wall - monotonic) > clockTolerance }

    init() {}

    init(_ object: [String: Any], local: String?) {
        config = HandsBuildConfig(wire: object["config"])
        reports = (object["reports"] as? [Any] ?? []).prefix(16).compactMap(HandsBuildDeviceReport.init(wire:))
        ownership = HandsBuildOwnership(wire: object["ownership"])
        ownership.unknown = object["ownership_unknown"] as? Bool ?? false
        devices = (object["devices"] as? [[String: Any]] ?? []).prefix(16).compactMap { raw in
            guard let id = (raw["id"] as? String).flatMap({ UUID(uuidString: $0) != nil ? $0.lowercased() : nil }) else { return nil }
            return HandsSetupDevice(id: id, name: String((raw["name"] as? String ?? "").filter { !$0.isNewline }.prefix(60)),
                                    isPrimary: raw["is_primary"] as? Bool ?? false, isThisDevice: HandsHostAuthority.same(id, local))
        }
        serverTime = (object["server_time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    func report(_ id: String) -> HandsBuildDeviceReport? { reports.first { HandsHostAuthority.same($0.deviceID, id) } }

    /// 內容一樣嗎（不看時間戳：伺服器時間、每台回報收到的時間）。W183 R8c 審查（Claude 中）：沒變就不重發給畫面。
    func sameContent(as other: HandsBuildView) -> Bool {
        func strip(_ view: HandsBuildView) -> HandsBuildView {
            var copy = view
            copy.serverTime = nil
            copy.localTime = nil
            copy.localUptime = nil
            // W183 R11 最後一輪：serverClockJumped 不拿掉——主設備的鐘跳過／跳完了，畫面（入口的判定）要換成新的這一份。
            copy.reports = copy.reports.map { var report = $0; report.receivedAt = nil; return report }
            return copy
        }
        return strip(self) == strip(other)
    }
}

/// 一次性（跨執行緒的「只做一次」）。
final class HandsBuildOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// 本機 completion 結束或逾時就釋放；晚到的 callback 不會掉進遠端 post。
private final class HandsBuildLocalReply: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((HandsBuildResult) -> Void)?
    init(_ completion: @escaping (HandsBuildResult) -> Void) { self.completion = completion }
    var pending: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    func send(_ result: HandsBuildResult) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(result)
    }
}

/// 每台的背景同步（正本這台在行程內、副設備經設備簽章 RPC `hands_build`）。
final class HandsBuildSync: ObservableObject, @unchecked Sendable {
    struct Dependencies {
        var role: () -> HandsBuildRole
        /// 這台是正本時的主設備端（行程內）。
        var authority: HandsBuildAuthority?
        /// 副設備：簽章 RPC 到主設備（hands_build）。
        var callPrimary: ([String: Any]) throws -> [String: Any]
        var trust: () -> HandsBuildTrust?
        var accepted: HandsBuildAcceptedStore
        var permit: HandsBuildPermit
        var reconciler: HandsBuildReconciler
        var executor: HandsBuildExecutor
        var report: (_ local: String) -> HandsBuildDeviceReport
        var now: () -> Date = Date.init
        /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：這台的單調時鐘（開機後的秒數；牆上的鐘被調、跳都不影響）。
        var uptime: () -> TimeInterval = { HandsMonotonic.now() }
        var intervals = Intervals()
        /// 副設備：還沒 pin 主設備簽章那把時，呼叫前記下主設備紀錄的主機金鑰（HandsBuildTrust.hostPin）；
        /// 呼叫後先驗再補記、綁那把主機金鑰（HandsBuildTrust.learnPrimaryKey）。契約 §11.10。
        var primaryHostPin: ((_ primary: String) -> String?)? = nil
        var learnPrimaryKey: ((_ envelope: HandsBuildEnvelope, _ trust: HandsBuildTrust, _ expectedHost: String) -> Void)? = nil
    }

    /// W183 R8c 審查（Claude 高／中）：多久問一次。
    struct Intervals: Equatable, Sendable {
        /// 有事在跑（這台送出、剛收到意圖、畫面開著）。
        var hot: TimeInterval = 1.5
        /// 副設備：這台被勾、許可有效（明確關掉最慢這麼久生效；連線的每一步最慢這麼久被取件）。
        var active: TimeInterval = 15
        /// 副設備：沒被勾（別台替它登入時，最慢這麼久被取件；取件期限 180 秒內）。
        var inactive: TimeInterval = 60
        /// 副設備：還沒有設定（沒收到過信封、沒 pin 住主設備）。
        var unconfigured: TimeInterval = 120
        /// 連不到主設備：從這個開始一路加倍到 maxBackoff。
        var backoff: TimeInterval = 10
        var maxBackoff: TimeInterval = 300
        /// 主設備自己：有副設備在熱問、或這台有事。
        var authorityHot: TimeInterval = 2
        var authorityIdle: TimeInterval = 30
        /// 送出的事、收到的意圖多久內算「有事在跑」。
        var hotWindow: TimeInterval = 180
        /// 畫面看的全貌沒變，最久多久也重發一次（時間戳：新不新鮮）。
        var republish: TimeInterval = 20
    }

    static let shared = HandsBuildSync(dependencies: .live())

    @Published private(set) var view = HandsBuildView()
    /// 最近一次同步的問題（連不到主設備、信封不收…；白話給畫面）。
    @Published private(set) var problem: String?
    /// UI-only copy of this device's verified permit; never used to authorize anything.
    @Published private(set) var memberPermit: HandsBuildPermit.State?
    /// 最近一次拿到全貌的時間（這台自己的鐘；畫面判斷新不新鮮）。
    var lastSync: Date? { lock.lock(); defer { lock.unlock() }; return lastSyncValue }
    private var lastSyncValue: Date?
    /// 這台送出去、還沒結束的事（畫面顯示「進行中」）：operationID → (動作, 目標)。
    @Published private(set) var inFlight: [String: (action: String, target: String)] = [:]

    let dependencies: Dependencies
    let queue = DispatchQueue(label: "tatwo.hands-build.sync", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var hotUntil = Date.distantPast
    private var lastRound = Date.distantPast
    private var failures = 0
    private var permitActive = false
    private var permitKnown = false

    private struct Waiter {
        let onResult: (HandsBuildResult) -> Void
        let submittedAt: Date
        let deadline: Date
    }
    private var waiters: [String: Waiter] = [:]
    private var buffered: [String: [HandsBuildResult]] = [:]
    /// 收到過的（去重、ack）：operationID → (最大序號, 是不是最後一則, 送過幾次 ack, 什麼時候)。
    private var received: [String: (seq: Int, final: Bool, acked: Int, at: Date)] = [:]
    /// 副設備交結果沒送到的（只在記憶體；下一輪先送；主設備照 B 的序號去重）。
    private var outbox: [HandsBuildResult] = []
    private var syncing = false
    private var lastPublishedAt = Date.distantPast
    private var publishedView: HandsBuildView?
    /// 鎖保護的副本（任何執行緒讀；view 是給畫面的、只在主執行緒）。
    private var ownershipCopy: HandsBuildOwnership?
    private var configCopy: HandsBuildConfig?

    static let maxOutbox = 64

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        dependencies.executor.post = { [weak self] result in self?.postResult(result) }
        dependencies.authority?.executeLocal = { [weak self] intent in self?.dependencies.executor.execute([intent]) }
        dependencies.authority?.deliverLocal = { [weak self] result in self?.deliver([result]) }
    }

    // MARK: 背景

    /// App 啟動後開始（自測、staging 不跑：跟關口同一條判斷）。
    func start() {
        guard ChatGPTHandsService.allowedToRun(environment: ProcessInfo.processInfo.environment) else { return }
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in self?.tickOnQueue() }
        timer = source
        lock.unlock()
        source.resume()
        // W183 R8c 審查（Claude 中）：舊的 TAP 畫面在這台改等級與專案＝寫穿到中央設定（上限跟著這台的選擇走）。
        HandsState.onLocalScopeChanged = { [weak self] level, projects in self?.localScopeChanged(level: level, projects: projects) }
    }

    /// 有事在跑（這台送出、收到意圖、畫面開著）：一陣子內快一點問。
    func heatUp() { lock.lock(); hotUntil = dependencies.now().addingTimeInterval(dependencies.intervals.hotWindow); lock.unlock() }

    /// 現在該多久問一次（W183 R8c 審查；自測也叫）。
    static func interval(role: HandsBuildRole, hot: Bool, permitActive: Bool, permitKnown: Bool, failures: Int, membersHot: Bool,
                         intervals: Intervals) -> TimeInterval {
        switch role {
        case .authority:
            return hot || membersHot ? intervals.authorityHot : intervals.authorityIdle
        case .member:
            if failures > 0 { return min(intervals.backoff * pow(2, Double(min(failures - 1, 10))), intervals.maxBackoff) }
            if hot { return intervals.hot }
            if permitActive { return intervals.active }
            return permitKnown ? intervals.inactive : intervals.unconfigured
        case .unknown:
            return intervals.unconfigured
        }
    }

    private func isHotLocked(_ now: Date) -> Bool {
        now < hotUntil || waiters.values.contains { now.timeIntervalSince($0.submittedAt) < dependencies.intervals.hotWindow }
    }

    private func tickOnQueue() {
        let now = dependencies.now()
        let role = dependencies.role()
        lock.lock()
        let hot = isHotLocked(now)
        let membersHot = dependencies.authority?.membersPollingHot(now: now) ?? false
        let interval = Self.interval(role: role, hot: hot, permitActive: permitActive, permitKnown: permitKnown, failures: failures,
                                     membersHot: membersHot, intervals: dependencies.intervals)
        let due = now.timeIntervalSince(lastRound) >= interval
        lock.unlock()
        guard due else { return }
        round()
    }

    #if DEBUG
    /// 自測：現在算不算「有事在跑」（快速輪詢）。
    func debugHot() -> Bool { lock.lock(); defer { lock.unlock() }; return isHotLocked(dependencies.now()) }
    #endif

    /// 馬上同步一輪（在同步的佇列上；畫面按了之後、自測）。
    func syncSoon(refreshView: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if refreshView {
                // W199：連線重新核對必須發布這輪的時間戳；內容相同也可能從過舊變成新鮮。
                self.lock.lock(); self.lastPublishedAt = .distantPast; self.lock.unlock()
            }
            self.round()
        }
    }

    /// 自測：同步一輪、等它做完。
    func syncNow() { queue.sync { round() } }

    private func round() {
        lock.lock()
        if syncing { lock.unlock(); return }
        syncing = true
        lastRound = dependencies.now()
        lock.unlock()
        defer { lock.lock(); syncing = false; lock.unlock() }
        switch dependencies.role() {
        case .authority(let local, _):
            guard let authority = dependencies.authority else { return }
            let report = dependencies.report(local)
            authority.record(report, from: local)
            let config = authority.dependencies.store.load()
            let state = dependencies.permit.state(local)
            notePermit(state)
            let outcome = dependencies.reconciler.apply(state, configRevision: config?.configRevision, local: local, primary: local)
            let now = dependencies.now()
            let intents = authority.mailbox.take(target: local, now: now)
            if !intents.isEmpty { heatUp(); dependencies.executor.execute(intents) }
            authority.deliverLocalResults(owner: local)
            expireWaiters(now: now) { id in !authority.mailbox.exists(id, now: now) }
            publish(HandsBuildView(authority.view(), local: local), problem: outcome == .refused ? Self.refusedText : authority.dependencies.store.ownershipProblem)
        case .member(let local, let primary, _):
            flushOutbox()
            let report = dependencies.report(local)
            var payload: [String: Any] = ["op": "sync", "report": report.wire]
            let (acks, waiting) = ackState()
            if !acks.isEmpty { payload["acks"] = acks }
            if !waiting.isEmpty { payload["waiting"] = waiting }
            // W183 R8 實機：還沒 pin 主設備簽章那把＝呼叫前先記下這次通道 pin 的主機金鑰（補記要綁它）。
            let hostPin = dependencies.trust()?.pinnedPrimaryKey == nil ? dependencies.primaryHostPin?(primary) : nil
            let response: [String: Any]
            do {
                response = try dependencies.callPrimary(payload)
                lock.lock(); failures = 0; lock.unlock()
            } catch {
                // 連不到主設備：設定不動（許可到期由許可自己暫停），畫面照實說；下一次慢一點（退避）。
                lock.lock(); failures += 1; lock.unlock()
                let state = dependencies.permit.state(local)
                notePermit(state)
                dependencies.reconciler.apply(state, configRevision: nil, local: local, primary: primary)
                expireWaiters(now: dependencies.now()) { _ in false }
                publish(nil, problem: "連不到主設備（\(HandsRemoteClient.plain(error))）")
                return
            }
            noteAcksSent(acks)
            var problem: String?
            let envelope = HandsBuildEnvelope(wire: response["envelope"])
            if let envelope, let hostPin, let trust = dependencies.trust(), trust.pinnedPrimaryKey == nil,
               HandsHostAuthority.same(trust.primaryID, primary) {
                dependencies.learnPrimaryKey?(envelope, trust, hostPin)   // W183 R8 實機：加入端補記主設備簽章那把（先驗再補、只補空的）
            }
            if let envelope, let trust = dependencies.trust() {
                do { try dependencies.accepted.accept(envelope, trust: trust, now: dependencies.now()) }
                catch { problem = Self.plain(error) }
            } else if response["envelope"] != nil {
                problem = "主設備給的設定看不懂（或這台沒有 pin 住主設備的簽章識別）；這台不套用"
            }
            let accepted = dependencies.accepted.current(trust: dependencies.trust())
            let state = dependencies.permit.state(local)
            notePermit(state)
            if dependencies.reconciler.apply(state, configRevision: accepted?.configRevision, local: local, primary: primary) == .refused {
                problem = problem ?? Self.refusedText
            }
            let intents = (response["intents"] as? [Any] ?? []).prefix(32).compactMap(HandsBuildIntent.init(delivery:))
                .filter { HandsHostAuthority.same($0.target, local) }
            if !intents.isEmpty { heatUp(); dependencies.executor.execute(intents) }
            deliver((response["results"] as? [Any] ?? []).prefix(64).compactMap(HandsBuildResult.init(wire:)))
            let gone = Set((response["gone"] as? [String] ?? []).prefix(64).map { $0.lowercased() })
            expireWaiters(now: dependencies.now()) { gone.contains($0) }
            publish(HandsBuildView(response, local: local), problem: problem)
        case .unknown:
            publish(nil, problem: "這台還沒有設備身分")
        }
    }

    static let refusedText = "主設備給這台的設定跟這台已經套用的同一版卻不一樣（或版本倒退）：這台不套用"

    private func notePermit(_ state: HandsBuildPermit.State) {
        lock.lock()
        permitActive = state.isActive
        permitKnown = state.slice != nil
        lock.unlock()
        let member: HandsBuildPermit.State?
        if case .member = dependencies.role() { member = state } else { member = nil }
        DispatchQueue.main.async { [weak self] in
            if self?.memberPermit != member { self?.memberPermit = member }
        }
    }

    private func publish(_ fetched: HandsBuildView?, problem: String?) {
        let now = dependencies.now()
        let uptime = dependencies.uptime()
        var send = false
        // W183 R11 第二輪：跟 serverTime 同一次拿到的這台時間（沒重發就連這一對一起留著）。W183 R11 最後一輪：加上這台的單調時鐘；
        // 跟上一份比，主設備的時間走的跟這台的單調時鐘差太多＝主設備的時鐘跳過（這一份的新舊算不準）。
        lock.lock()
        let previous = publishedView
        lock.unlock()
        let view = fetched.map { fetched -> HandsBuildView in
            var stamped = fetched
            stamped.localTime = now
            stamped.localUptime = uptime
            if let previous, let before = previous.serverTime, let beforeUptime = previous.localUptime, let after = fetched.serverTime {
                stamped.serverClockJumped = HandsBuildView.clockJumped(wall: after.timeIntervalSince(before), monotonic: uptime - beforeUptime)
            }
            return stamped
        }
        lock.lock()
        if let view {
            ownershipCopy = view.ownership
            if let config = view.config { configCopy = config }
            // W183 R11 最後一輪（GPT-6 R11c 審查 4）：上一份發出去之後這台的牆上時鐘跳過（跟單調時鐘差太多：倒退時「隔多久重發」也算不準）＝
            // 馬上重發（換成新的一對時間），不讓入口一直拿跳之前的那一對算。
            let localJumped = publishedView.map { published -> Bool in
                guard let at = published.localTime, let up = published.localUptime else { return false }
                return HandsBuildView.clockJumped(wall: now.timeIntervalSince(at), monotonic: uptime - up)
            } ?? false
            // 沒變（不看時間戳）＝不重發；最久 republish 秒也發一次（新不新鮮）。
            if publishedView.map({ !$0.sameContent(as: view) }) ?? true || now.timeIntervalSince(lastPublishedAt) >= dependencies.intervals.republish
                || localJumped {
                publishedView = view
                lastPublishedAt = now
                send = true
            }
            lastSyncValue = now
        }
        lock.unlock()
        let sendView = send ? view : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let sendView { self.view = sendView }
            if self.problem != problem { self.problem = problem }
        }
    }

    static func plain(_ error: Error) -> String {
        switch error as? HandsBuildEnvelopeError {
        case .rollback?: return "主設備給的設定比這台已經套用的舊（回滾）：不收"
        case .conflict?: return "主設備給的設定跟這台已經套用的同一版卻不一樣：不收"
        case .unpinned?: return "這台還沒記下主設備的簽章識別：不收（連上主設備時會自動補上）"
        case .untrustedSigner?, .badSignature?: return "主設備給的設定簽章對不上這台記下的主設備：不收"
        case .expired?, .notYetValid?, .lifetime?: return "主設備給的設定時間不對（兩台的時間差太多？）：不收"
        case .wrongPrimary?, .wrongEpoch?, .wrongTarget?: return "主設備給的設定不是給這台的（或主設備換過）：不收"
        default: return "主設備給的設定不收（\(String(describing: error))）"
        }
    }

    // MARK: 結果交給等待者

    /// 這一輪要帶的 ack（收過的最大序號）與還在等的（P 不認得＝gone）。
    private func ackState() -> (acks: [String: Int], waiting: [String]) {
        lock.lock(); defer { lock.unlock() }
        let now = dependencies.now()
        received = received.filter { !($0.value.final && $0.value.acked >= 3) && now.timeIntervalSince($0.value.at) < 900 }
        var acks: [String: Int] = [:]
        for (id, entry) in received.sorted(by: { $0.value.at > $1.value.at }).prefix(64) { acks[id] = entry.seq }
        let waiting = waiters.sorted { $0.value.submittedAt < $1.value.submittedAt }.prefix(64).map(\.key)
        return (acks, waiting)
    }

    private func noteAcksSent(_ acks: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        for id in acks.keys { received[id]?.acked += 1 }
    }

    private func deliver(_ results: [HandsBuildResult]) {
        guard !results.isEmpty else { return }
        let now = dependencies.now()
        for result in results {
            lock.lock()
            let id = result.operationID
            // 去重：同一件收過的序號以前的（回應掉了、P 再給一次）不再交。
            if let seen = received[id], result.seq <= seen.seq { lock.unlock(); continue }
            received[id] = (result.seq, result.final, 0, now)
            if received.count > 256, let oldest = received.min(by: { $0.value.at < $1.value.at })?.key { received[oldest] = nil }
            let waiter = waiters[id]
            if waiter == nil {
                var list = buffered[id] ?? []
                if list.count < 16 { list.append(result) }
                buffered[id] = list
                if buffered.count > 64, let first = buffered.keys.first { buffered[first] = nil }
            }
            if result.final { waiters[id] = nil }
            lock.unlock()
            waiter?.onResult(result)
            if result.final {
                DispatchQueue.main.async { [weak self] in self?.inFlight[id] = nil }
            }
        }
    }

    /// W183 R8c 審查（GPT-6 中／Claude 高）：等不到最後結果的等待者一定會收尾——過了期限、或主設備說不認得（gone）＝
    /// 交一則「結果未知」的最後結果（畫面：那台沒開？再按一次；登入頁收起來），並清掉進行中與快速輪詢。
    private func expireWaiters(now: Date, gone: (String) -> Bool) {
        lock.lock()
        let candidates = waiters.filter { now > $0.value.deadline || gone($0.key) }
        var fired: [(String, Waiter, Bool)] = []
        for (id, waiter) in candidates where waiters[id] != nil && buffered[id] == nil {
            waiters[id] = nil
            fired.append((id, waiter, now > waiter.deadline))
        }
        lock.unlock()
        for (id, waiter, expired) in fired {
            waiter.onResult(HandsBuildResult(operationID: id, seq: 64, final: true,
                                             object: ["state": "unknown", "reason": expired ? "expired" : "result_unknown"]))
            DispatchQueue.main.async { [weak self] in self?.inFlight[id] = nil }
        }
    }

    private func postResult(_ result: HandsBuildResult) {
        queue.async { [weak self] in
            guard let self else { return }
            switch self.dependencies.role() {
            case .authority(let local, _):
                try? self.dependencies.authority?.post(result, from: local)
            case .member:
                // 送不到＝記在 outbox（只在記憶體；登入網址也不落盤），下一輪先送。
                self.lock.lock(); let pending = !self.outbox.isEmpty; self.lock.unlock()
                if pending || (try? self.dependencies.callPrimary(["op": "result", "result": result.wire])) == nil {
                    self.lock.lock()
                    self.outbox.append(result)
                    if self.outbox.count > Self.maxOutbox { self.outbox.removeFirst(self.outbox.count - Self.maxOutbox) }
                    self.lock.unlock()
                    if pending { self.flushOutbox() }
                }
            case .unknown:
                break
            }
        }
    }

    /// 副設備：outbox 照順序送（送不到就停，下一輪再來）；主設備不認得這件（過期、重開）＝丟掉。
    private func flushOutbox() {
        while true {
            lock.lock()
            guard let next = outbox.first else { lock.unlock(); return }
            lock.unlock()
            do {
                _ = try dependencies.callPrimary(["op": "result", "result": next.wire])
            } catch {
                let text = String(describing: error)
                let permanent = text.contains("hands_build_mailbox_unknown_operation") || text.contains("hands_build_mailbox_not_target")
                    || text.contains("hands_build_mailbox_invalid")
                if !permanent { return }
            }
            lock.lock()
            if outbox.first == next { outbox.removeFirst() }
            lock.unlock()
        }
    }

    // MARK: 擁有者這端（這台按的）

    /// 只供原生 UI 使用；不改設定、不送 RPC，也不把結果回送主設備。
    @discardableResult
    func applyHere(expected: HandsBuildExpected, setupEpoch: String?,
                   onResult: @escaping (HandsBuildResult) -> Void) throws -> String {
        guard let local = dependencies.role().localID else { throw HandsBuildSyncError.unavailable("identity") }
        _ = try localApplyCurrent(local: local, expected: expected)
        let now = dependencies.now()
        let id = UUID().uuidString.lowercased()
        let wire = HandsBuildIntent.submissionWire(operationID: id, action: "apply_urls", target: local, attempt: nil,
                                                   configRevision: expected.revision, setupEpoch: setupEpoch,
                                                   expiresAt: now.addingTimeInterval(HandsBuildIntent.maxPickup), payload: [:])
        let intent = try HandsBuildIntent.submission(wire, owner: local, now: now)
        dependencies.executor.applyHere(intent, current: { [weak self] in
            guard let self else { throw HandsBuildSyncError.unavailable("identity") }
            return try self.localApplyCurrent(local: local, expected: expected)
        }, completion: onResult)
        return id
    }

    /// 只用已接受的信封（正本才讀本機設定）；UI 全貌不能代替已簽的本機許可。
    private func localApplyCurrent(local: String, expected: HandsBuildExpected) throws
        -> (slice: HandsBuildDeviceSlice, configRevision: Int) {
        guard let config = knownConfig(), HandsBuildExpected.of(config) == expected else { throw HandsBuildSyncError.configChanged }
        let slice: HandsBuildDeviceSlice
        switch dependencies.role() {
        case .authority(let me, let epoch):
            guard HandsHostAuthority.same(me, local), me.lowercased() + "#\(epoch)" == expected.authority else {
                throw HandsBuildSyncError.configChanged
            }
            slice = config.slice(for: local)
        case .member(let me, let primary, let epoch):
            guard HandsHostAuthority.same(me, local), primary.lowercased() + "#\(epoch)" == expected.authority else {
                throw HandsBuildSyncError.configChanged
            }
            guard let body = dependencies.accepted.current(trust: dependencies.trust()) else {
                throw HandsBuildSyncError.unavailable("no_config")
            }
            guard body.primaryID.lowercased() + "#\(body.authorityEpoch)" == expected.authority,
                  body.configRevision == expected.revision,
                  HandsHostAuthority.same(body.targetDeviceID, local) else { throw HandsBuildSyncError.configChanged }
            guard dependencies.now() < body.expiresDate else { throw HandsBuildSyncError.unavailable("expired") }
            slice = body.content
        case .unknown:
            throw HandsBuildSyncError.unavailable("identity")
        }
        guard HandsHostAuthority.same(slice.deviceID, local) else { throw HandsBuildSyncError.unavailable("not_target") }
        guard slice.active else { throw HandsBuildSyncError.unavailable("not_selected") }
        guard dependencies.permit.permits(local) else { throw HandsBuildSyncError.unavailable("no_config") }
        return (slice, expected.revision)
    }

    /// 送一件事給 target（這台是正本＝直接進信箱；副設備＝經簽章 RPC）。結果（可能幾則）交給 onResult（在同步的佇列上叫）。
    /// 一定會有最後一則：那台做完的、或期限到了／主設備不認得的「結果未知」（W183 R8c 審查）。
    /// W183 R8 整合審查（GPT-6 高「apply 在非同步送出時重讀版本」）：expected＝使用者按的時候看到的那一份（主權＋設定版本）。
    /// 帶了就原樣放進意圖（不自己換成送出那一刻的版本）；送出那一刻這台知道的設定已經不是那一份＝不送（configChanged：請使用者再看一次）。
    /// 「套用」一定要帶（那台核：它已接受的版本要等於這一個）。
    @discardableResult
    func submit(action: String, target: String, attempt: String? = nil, setupEpoch: String? = nil, payload: [String: Any] = [:],
                expected: HandsBuildExpected? = nil, lifetime: TimeInterval = 120, onResult: @escaping (HandsBuildResult) -> Void) throws -> String {
        let id = UUID().uuidString.lowercased()
        let now = dependencies.now()
        let current = knownConfig()
        let revision: Int
        if let expected {
            guard let current, current.configRevision == expected.revision, HandsBuildExpected.authority(of: current) == expected.authority else {
                throw HandsBuildSyncError.configChanged
            }
            revision = expected.revision
        } else {
            guard action != "apply_urls" else { throw HandsBuildSyncError.unavailable("expected_revision") }
            revision = current?.configRevision ?? 0
        }
        let pickup = min(lifetime, HandsBuildIntent.maxPickup)
        let wire = HandsBuildIntent.submissionWire(operationID: id, action: action, target: target, attempt: attempt, configRevision: revision,
                                                   setupEpoch: setupEpoch, expiresAt: now.addingTimeInterval(pickup), payload: payload)
        let deadline = now.addingTimeInterval(pickup + (dependencies.authority?.mailbox.limits.operationLifetime ?? 900) + 30)
        lock.lock()
        waiters[id] = Waiter(onResult: onResult, submittedAt: now, deadline: deadline)
        let early = buffered.removeValue(forKey: id) ?? []
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.inFlight[id] = (action, target.lowercased()) }
        do {
            switch dependencies.role() {
            case .authority(let local, _):
                guard let authority = dependencies.authority else { throw HandsBuildSyncError.unavailable("authority") }
                try authority.submit(try HandsBuildIntent.submission(wire, owner: local, now: now))
            case .member:
                _ = try dependencies.callPrimary(["op": "submit", "intent": wire])
            case .unknown:
                throw HandsBuildSyncError.unavailable("identity")
            }
            heatUp()
        } catch {
            lock.lock(); waiters[id] = nil; lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.inFlight[id] = nil }
            throw error
        }
        for result in early { onResult(result) }
        return id
    }

    /// 送一件、等最後一則結果（連線的每一步用；等不到＝timeout：結果未知）。
    func request(target: String, action: String, attempt: String? = nil, setupEpoch: String? = nil, payload: [String: Any],
                 timeout: TimeInterval = 45) async throws -> [String: Any] {
        let once = HandsBuildOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            do {
                let id = try submit(action: action, target: target, attempt: attempt, setupEpoch: setupEpoch, payload: payload) { result in
                    guard result.final, once.claim() else { return }
                    if result.state == "unknown" { continuation.resume(throwing: HandsBuildSyncError.timeout); return }
                    continuation.resume(returning: result.object)
                }
                syncSoon()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard once.claim() else { return }
                    self?.dropWaiter(id)
                    continuation.resume(throwing: HandsBuildSyncError.timeout)
                }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
    }

    func dropWaiter(_ id: String) {
        lock.lock(); waiters[id] = nil; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.inFlight[id] = nil }
    }

    /// 改設定（預期版本比對；副設備經簽章 RPC）。回新的設定並更新畫面。
    /// W183 R8c 審查（GPT-6 中）：預期版本一定要帶（畫面還沒拿到設定＝不能改）。
    @discardableResult
    func updateConfig(expected: Int, ops: [HandsBuildConfigOp]) throws -> HandsBuildConfig {
        let config: HandsBuildConfig
        switch dependencies.role() {
        case .authority(let local, _):
            guard let authority = dependencies.authority else { throw HandsBuildConfigError.notAuthority }
            config = try authority.updateConfig(from: local, expectedRevision: expected, ops: ops)
        case .member:
            let payload: [String: Any] = ["op": "config", "changes": ops.map(\.wire), "expected_revision": expected,
                                          "expires_at": Int(dependencies.now().timeIntervalSince1970 + HandsRemote.requestLifetime)]
            let response: [String: Any]
            do { response = try dependencies.callPrimary(payload) } catch {
                throw HandsBuildConfigError.from(error) ?? HandsBuildSyncError.unavailable(HandsRemoteClient.plain(error))
            }
            guard let decoded = HandsBuildConfig(wire: response["config"]) else { throw HandsBuildConfigError.invalid("response") }
            config = decoded
        case .unknown:
            throw HandsBuildSyncError.unavailable("identity")
        }
        let snapshot = config
        lock.lock(); configCopy = config; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.view.config = snapshot }
        heatUp()
        syncSoon()
        return config
    }

    /// 現在知道的設定（主設備＝正本；副設備＝上一次從主設備拿到的全貌）。
    func knownConfig() -> HandsBuildConfig? {
        if case .authority = dependencies.role(), let authority = dependencies.authority { return authority.dependencies.store.load() }
        lock.lock(); defer { lock.unlock() }
        return configCopy
    }

    /// 別台有建立證據的通道（這台的「沒用到的通道」不列、不刪）。還沒從主設備拿到過、所有權表讀不到＝nil（不知道＝不列）。
    func foreignTunnelIDs() -> Set<String>? {
        let role = dependencies.role()
        guard let local = role.localID else { return nil }
        if case .authority = role, let authority = dependencies.authority {
            let table = authority.dependencies.store.ownership()
            return table.unknown ? nil : table.foreignTunnels(excluding: local)
        }
        lock.lock(); defer { lock.unlock() }
        guard let copy = ownershipCopy, !copy.unknown else { return nil }   // 還沒從主設備拿到過、或主設備讀不到＝不知道＝不列
        return copy.foreignTunnels(excluding: local)
    }

    // MARK: 這台的開關、等級與專案寫穿到中央設定（W183 R8c 審查，Claude 中）

    /// 使用者在這台打開（沒選設備＝預設這台）：回 true＝這台現在有許可。
    /// - 一台都沒勾＝勾這台、打開總開關（使用者 09-28「沒有副設備的人一率主設備」）；
    /// - 只勾了這台、總開關關著＝打開總開關；
    /// - 總開關開著、沒勾這台＝勾這台；
    /// - 總開關關著、而且勾了別台＝不改（打開會連別台一起開：請在 ChatGPT build 打開）。
    func selectHere(local: String) -> Bool {
        guard let config = knownConfig() else { return false }
        if config.isActive(local) { return dependencies.permit.permits(local) }
        let others = config.devices.filter { $0.selected && !HandsHostAuthority.same($0.deviceID, local) }
        var ops: [HandsBuildConfigOp] = []
        if !(config.entry(local)?.selected ?? false) {
            guard config.enabled || others.isEmpty else { return false }
            ops.append(.select(device: local, selected: true))
        }
        if !config.enabled {
            guard others.isEmpty else { return false }
            ops.append(.setEnabled(true))
        }
        guard !ops.isEmpty, (try? updateConfig(expected: config.configRevision, ops: ops)) != nil else { return false }
        if case .member = dependencies.role() { syncNow() }   // 馬上拿新的信封
        return dependencies.permit.permits(local)
    }

    /// 使用者 09-28「沒有副設備的人一率主設備」：使用者在這台打開、設定裡一台都沒勾＝勾這台。回 true＝這台現在有許可。
    static func selectDefaultIfNone(local: String) -> Bool { shared.selectHere(local: local) }

    /// 使用者在這台關掉開關＝中央設定也取消勾這台（背景做；連不到主設備＝只關這台，reconcile 不會因為別的內容改了就偷偷打開）。
    func localSwitchedOff(local: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for _ in 0..<2 {
                guard let config = self.knownConfig(), config.entry(local)?.selected == true else { return }
                do { try self.updateConfig(expected: config.configRevision, ops: [.select(device: local, selected: false)]); return }
                catch HandsBuildConfigError.revisionConflict { self.syncNow(); continue }
                catch { return }
            }
        }
    }

    /// 舊的 TAP 畫面在這台改了等級或專案＝中央設定裡這台的上限跟著改（背景做）。
    func localScopeChanged(level: Int, projects: [String]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let local = self.dependencies.role().localID else { return }
            for _ in 0..<2 {
                guard let config = self.knownConfig(), let entry = config.entry(local) else { return }
                var ops: [HandsBuildConfigOp] = []
                if entry.level != level { ops.append(.level(device: local, level: min(max(level, 0), HandsSettings.maxLevel))) }
                let wanted = Set(projects.compactMap { UUID(uuidString: $0)?.uuidString })
                let current = Set(entry.projectIDs)
                for id in wanted.subtracting(current).sorted() { ops.append(.project(device: local, projectID: id, selected: true)) }
                for id in current.subtracting(wanted).sorted() { ops.append(.project(device: local, projectID: id, selected: false)) }
                guard !ops.isEmpty, ops.count <= 32 else { return }
                do { try self.updateConfig(expected: config.configRevision, ops: ops); return }
                catch HandsBuildConfigError.revisionConflict { self.syncNow(); continue }
                catch { return }
            }
        }
    }
}

extension HandsBuildSync.Dependencies {
    static func live() -> HandsBuildSync.Dependencies {
        let service = HandsService.shared
        let role = { HandsBuildRole.current() }
        let reconciler = HandsBuildReconciler(
            service: service, applied: .shared,
            resume: { _ = HandsSetup.shared.resumeIfEnabled() },
            serviceChanged: { ChatGPTHandsService.shared.settingsDidChange() },
            cancelConnect: { reason in DispatchQueue.main.async { MainActor.assumeIsolated { HandsConnectFlow.shared.cancel(reason: reason) } } },
            cancelSetup: { HandsSetup.shared.cancel() },
            suspend: { service.suspendForPermit() })
        let executor = HandsBuildExecutor(dependencies: .init(
            localID: { role().localID },
            setup: { HandsSetup.shared },
            service: { service },
            remoteHost: { HandsRemote.Host.live() },
            unlockSafety: { incident in ChatGPTHandsService.shared.unlockSafety(incident: incident) },
            current: {
                switch role() {
                case .authority(let local, _):
                    guard let config = HandsBuildConfigStore.shared.load() else { return nil }
                    return (config.slice(for: local), config.configRevision)
                case .member:
                    guard let body = HandsBuildAcceptedStore.shared.current(trust: HandsBuildTrust.live()),
                          Date() < body.expiresDate else { return nil }
                    return (body.content, body.configRevision)
                case .unknown:
                    return nil
                }
            },
            accounts: { .shared }), ledgerURL: HandsPaths.default.appDir.appendingPathComponent("build-ops.json"))
        return HandsBuildSync.Dependencies(
            role: role,
            authority: .shared,
            callPrimary: { payload in try DeviceDispatch.shared.callPrimary(method: HandsBuildRemote.method, payload: payload) },
            trust: { HandsBuildTrust.live() },
            accepted: .shared, permit: .shared, reconciler: reconciler, executor: executor,
            report: { local in HandsBuildReports.live(local: local) },
            primaryHostPin: { primary in HandsBuildTrust.hostPin(primary: primary) },
            learnPrimaryKey: { envelope, trust, host in
                HandsBuildTrust.learnPrimaryKey(envelope: envelope, trust: trust, expectedHost: host, now: Date())
            })
    }
}

/// 這台的公共狀態（給主設備、再給所有設備的畫面）。沒有秘密：只有進度、名稱、建立證據、事故編號與 grant 摘要（都不是秘密）。
enum HandsBuildReports {
    static func live(local: String) -> HandsBuildDeviceReport {
        build(local: local, service: .shared, setup: .shared, accounts: .shared, permit: .shared, applied: .shared,
              phase: { HandsSetup.onMainSync { ChatGPTHandsService.shared.phase } },
              safetyLocked: { ChatGPTHandsService.safetyStopped(ChatGPTHandsService.shared.paths) },
              safetyIncident: { ChatGPTHandsService.safetyIncident(ChatGPTHandsService.shared.paths) })
    }

    static func build(local: String, service: HandsService, setup: HandsSetup, accounts: CloudflareAccountsStore, permit: HandsBuildPermit,
                      applied: HandsBuildAppliedStore, phase: () -> ChatGPTHandsService.Phase, safetyLocked: () -> Bool,
                      safetyIncident: () -> String? = { nil }) -> HandsBuildDeviceReport {
        var report = HandsBuildDeviceReport(deviceID: local)
        let settings = service.settings.load()
        let appliedRecord = applied.load()
        report.appliedConfigRevision = appliedRecord?.configRevision ?? 0
        // W183 R8 整合審查（GPT-6 中「沒有回報時宣稱已關閉」）：這台已經套用到哪一次「明確關掉」（撤銷世代）＝關掉的回執。
        report.appliedGeneration = appliedRecord?.revocationGeneration ?? 0
        switch permit.state(local) {
        case .active: report.permit = "active"
        case .inactive: report.permit = "inactive"
        case .paused: report.permit = "paused"
        case .none: report.permit = "none"
        }
        report.enabled = settings.enabled
        let current = phase()
        switch current {
        case .stopped: report.phase = "stopped"
        case .starting: report.phase = "starting"
        case .running: report.phase = "running"
        case .failed: report.phase = "failed"
        }
        report.phaseText = String(ChatGPTHandsService.statusText(current).prefix(200))
        report.publicHost = HandsGatewayLaunch.validHost(settings.publicHost)
        report.setupEpoch = setup.setupEpoch
        report.setupBusy = setup.isBusy
        var state = setup.snapshot
        state.steps[HandsSetupStep.start.rawValue] = HandsSetup.liveStartStep(state.step(.start), phase: current)
        report.nextStep = HandsSetupStep.runOrder.first { state.step($0).status != .done }?.rawValue
        if let failed = HandsSetupStep.runOrder.first(where: { state.step($0).status == .failed }) {
            report.stepProblem = setup.redactedForAI(state.step(failed).message)
        }
        // W183 R8 整合審查（Claude 中「面板顯示的是上限不是實際」）：回報實際生效的（W183 R10：中央設定的等級＋這台全部專案；
        // HandsService.effectiveSettings）。W183 R11（GPT-6 R11 審查 1）：先拿有效設定（中央等級變了＝先封頂），下面讀到的 grant 等級是封頂之後的。
        let effective = service.effectiveSettings()
        report.levelGuard = true   // W183 R11：這台的主機會先封頂再讓新的等級生效（主設備的預設升級看這個）
        // W183 R11 最後一輪（GPT-6 R11c 審查 4）：同一把鎖裡讀一份（版本、有效的、每一筆）：回報帶取樣那一刻的授權狀態版本。
        let snapshot = service.auth.reportSnapshot()
        report.grantsVersion = snapshot.version
        let grants = snapshot.active
        report.grants = grants.count
        // W183 R8 整合（R8a 審查）：確認過的（不含連線意圖換到、還沒確認的暫時 grant）才算「已連線」。
        let provisional = Set(snapshot.summaries.filter(\.provisional).map(\.id))
        report.confirmedGrants = grants.filter { !provisional.contains($0) }.count
        // W183 R11：確認過的連線裡最高的等級（私訊框的「已連線・Codex、記憶」照 ChatGPT 實際拿到的，不照中央設定）。
        let confirmed = Set(grants.filter { !provisional.contains($0) })
        let confirmedSummaries = snapshot.summaries.filter { confirmed.contains($0.id) }
        report.grantLevel = confirmedSummaries.map(\.level).max()
        // W183 R11（GPT-6 R11 審查 4、5）：逐筆的代號與等級（按［連線］的那台用它核對「目前這個帳號的那一條」還在不在、拿到哪一級）。
        report.grantLevels = Dictionary(confirmedSummaries.prefix(64).map { (HandsBuildDeviceReport.grantTag($0.id), $0.level) },
                                        uniquingKeysWith: { max($0, $1) })
        report.grantsDigest = HandsBuildDeviceReport.digest(grants: grants)
        report.safetyLocked = safetyLocked()
        if report.safetyLocked { report.safetyIncident = safetyIncident() }
        report.level = effective.level
        report.projectChoices = service.buildProjectChoices()
        report.allowedProjects = effective.allProjects ? report.projectChoices.map(\.id) : effective.allowedProjectIDs
        report.accounts = accounts.snapshot.prefix(16).map { account in
            HandsBuildDeviceReport.Account(id: account.id, name: String(account.displayName.prefix(80)),
                                           zones: account.domains.prefix(64).map { .init(zoneID: $0.zoneID, name: $0.name, authorized: accounts.hasCert(zoneID: $0.zoneID)) })
        }
        var resources: [HandsBuildOwnership.Record] = []
        if let host = HandsGatewayLaunch.validHost(state.publicHost) {
            resources.append(.init(hostname: host, deviceID: local, tunnelID: state.tunnelID, zoneID: state.zoneID, evidence: "created", recordedAt: Date()))
        }
        if let retired = state.retiredHost, let host = HandsGatewayLaunch.validHost(retired.host) {
            resources.append(.init(hostname: host, deviceID: local, tunnelID: retired.tunnelID, zoneID: retired.zoneID, evidence: "created", recordedAt: Date()))
        }
        report.resources = resources
        report.released = (state.releasedHosts ?? []).compactMap { HandsGatewayLaunch.validHost($0) }
        return report
    }
}

extension HandsService {
    /// W183 R8c：正式的這一份接上 ChatGPT build（啟用許可、grant 綁定、範圍上限）。
    func attachBuild(permit: HandsBuildPermit = .shared) {
        permitCheck = { [weak self] in
            guard let self, let local = self.deviceIDOverride ?? HandsBuildRole.current().localID else { return false }
            return permit.permits(local)
        }
        scopeCap = { [weak self] in
            guard let self, let local = self.deviceIDOverride ?? HandsBuildRole.current().localID,
                  let slice = permit.state(local).slice else { return nil }
            return (slice.level, Set(slice.projectIDs))
        }
        auth.binding = { [weak self] in
            guard let self, let local = self.deviceIDOverride ?? HandsBuildRole.current().localID else { return nil }
            let host = HandsGatewayLaunch.validHost(self.settings.load().publicHost)
            return HandsGrantBinding(hostDeviceID: local, issuer: host.map { "https://" + $0 }, resource: host.map { "https://\($0)/mcp" },
                                     generation: permit.state(local).slice?.revocationGeneration ?? 0)
        }
    }
}
