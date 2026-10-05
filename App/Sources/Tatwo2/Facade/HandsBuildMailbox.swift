import Foundation

// W183 R8c：信箱協定——在哪台都能做（GPT-6 必改 3）。
//
// 所有副設備只主動連主設備 P（沒有新的公開管理端點、P 也不反向 SSH 進副設備）：
//   A 原生畫面按 → P：提交指定 B 的短期操作意圖（登入、套用網址、連線、取消、撤銷、解除安全鎖）
//   B → P：定時取件（背景同步，不靠設定頁開著）→ B 驗、B 自己做（B 是最終決策者）
//   B → P：結果（登入網址、配對碼、回執）**只給擁有者 A**；A → P：取件、在 A 自己的私訊框顯示。
//   A、B 都是副設備也一樣；A＝P 或 B＝P 就是本機那一段。
// - 意圖綁 sender（驗章得到的那台＝擁有者，payload 不能指定）／target／operationID／attempt 或 loginRound／設定版本／B 的 setupEpoch／
//   expiresAt／payloadHash（P 自己重算，對不上＝不收）。同一個 operationID 同內容＝冪等、不同內容＝拒。
// - P 只存在記憶體（P 重開＝全部作廢，不會重開任何窗口）、有 TTL、容量與每個擁有者的上限、完成（擁有者取走最後結果）即清。
// - W183 R8c 審查（GPT-6 中「信箱結果是一次性取走，掉包後無法恢復」）：結果有序號；擁有者下一次同步帶「收到哪一則」（ack）P 才拿掉，
//   沒 ack 的下一次再給（有 TTL 上限）。B 交結果失敗＝B 記在記憶體的 outbox 下一輪再送（P 照 B 的序號去重）。擁有者帶「還在等哪幾件」，
//   P 不認得的（沒人取、過期、P 重開）回 gone：擁有者收成「結果未知」，不會永遠轉圈。
// - **首版主設備明文中繼**（主導裁決）：P 看得到經手的登入網址與配對碼（P 是使用者自己的設備）；端對端加密放下一版（殘餘風險）。
// - 公共狀態（每台回報、所有設備看得到的那一份）只有進度，沒有登入網址、確認 token、配對碼。
// - T12（改寫）：多台都能被 ChatGPT 連上，不代表任何一台的 ChatGPT 工具能管理、派工或轉送到別台——這裡只給 App 的原生畫面與
//   設備簽章 RPC（OSAgentBridge 只准 SSH 轉進來的 hands_build；外部 AI、引擎、背景工作一律拒）。

/// A 指定 B 做的一件事。
struct HandsBuildIntent: Equatable, Sendable {
    static let actions: Set<String> = ["login", "login_cancel", "apply_urls", "connect", "revoke_all", "unlock_safety"]
    /// 取件期限上限（送出後多久內 B 要取走；過了＝不做）。
    static let maxPickup: TimeInterval = 180
    static let maxPayload = 16 * 1024

    let operationID: String
    let action: String
    /// 擁有者：P 驗章得到的那台（本機提交＝這台）。
    let owner: String
    let target: String
    /// 連線意圖的 attempt、或登入的 loginRound。
    let attempt: String?
    /// 送出時畫面看到的設定版本。
    let configRevision: Int
    /// 送出時看到的 B 的 setupEpoch（B 重開、取消、關過就換；對不上＝不做）。
    let setupEpoch: String?
    let expiresAt: Date
    /// payload 的正規 JSON（雜湊也是算這份）。
    let payload: Data
    let payloadHash: String
    let submittedAt: Date

    var payloadObject: [String: Any] { (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:] }

    /// 送出的欄位（A → P）。owner 不在裡面（P 用驗章得到的）。
    static func submissionWire(operationID: String, action: String, target: String, attempt: String?, configRevision: Int,
                               setupEpoch: String?, expiresAt: Date, payload: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["operation_id": operationID, "action": action, "target": target.lowercased(), "config_revision": configRevision,
                                  "expires_at": Int(expiresAt.timeIntervalSince1970), "payload": payload,
                                  "payload_hash": HandsBuildCanonical.hash(payload)]
        if let attempt { out["attempt"] = attempt }
        if let setupEpoch { out["setup_epoch"] = setupEpoch }
        return out
    }

    /// P 收到的提交：欄位白名單、期限、payload 雜湊 P 自己重算。owner＝驗章得到的那台。
    static func submission(_ raw: [String: Any], owner: String, now: Date) throws -> HandsBuildIntent {
        let allowed: Set<String> = ["operation_id", "action", "target", "attempt", "config_revision", "setup_epoch", "expires_at", "payload", "payload_hash"]
        guard Set(raw.keys).isSubset(of: allowed) else { throw HandsBuildMailboxError.invalid("unexpected field") }
        guard let id = raw["operation_id"] as? String, UUID(uuidString: id) != nil else { throw HandsBuildMailboxError.invalid("operation_id") }
        guard let action = raw["action"] as? String, actions.contains(action) else { throw HandsBuildMailboxError.invalid("action") }
        guard let target = (raw["target"] as? String).flatMap({ UUID(uuidString: $0) != nil ? $0.lowercased() : nil }) else {
            throw HandsBuildMailboxError.invalid("target")
        }
        let attempt = raw["attempt"] as? String
        if let attempt, attempt.isEmpty || attempt.utf8.count > 64 { throw HandsBuildMailboxError.invalid("attempt") }
        guard let revision = (raw["config_revision"] as? NSNumber)?.intValue, revision >= 0 else { throw HandsBuildMailboxError.invalid("config_revision") }
        let epoch = raw["setup_epoch"] as? String
        if let epoch, epoch.utf8.count > 64 { throw HandsBuildMailboxError.invalid("setup_epoch") }
        guard let expires = (raw["expires_at"] as? NSNumber)?.doubleValue else { throw HandsBuildMailboxError.expired }
        guard expires > now.timeIntervalSince1970, expires <= now.timeIntervalSince1970 + maxPickup + 30 else { throw HandsBuildMailboxError.expired }
        guard let payload = raw["payload"] as? [String: Any] else { throw HandsBuildMailboxError.invalid("payload") }
        let data = HandsBuildCanonical.object(payload)
        guard data.count <= maxPayload else { throw HandsBuildMailboxError.invalid("payload_size") }
        let hash = "sha256:" + HandsAuth.sha256Hex(data)
        guard let claimed = raw["payload_hash"] as? String, HandsAuth.constantTimeEqual(claimed, hash) else { throw HandsBuildMailboxError.invalid("payload_hash") }
        return HandsBuildIntent(operationID: id.lowercased(), action: action, owner: owner.lowercased(), target: target, attempt: attempt,
                                configRevision: revision, setupEpoch: epoch, expiresAt: Date(timeIntervalSince1970: expires), payload: data,
                                payloadHash: hash, submittedAt: now)
    }

    /// 交給 B 的（P → B；帶擁有者：B 只信 P 經驗章告訴它的）。
    var deliveryWire: [String: Any] {
        var out: [String: Any] = ["operation_id": operationID, "action": action, "owner": owner, "target": target, "config_revision": configRevision,
                                  "expires_at": Int(expiresAt.timeIntervalSince1970), "payload": payloadObject, "payload_hash": payloadHash,
                                  "submitted_at": Int(submittedAt.timeIntervalSince1970)]
        if let attempt { out["attempt"] = attempt }
        if let setupEpoch { out["setup_epoch"] = setupEpoch }
        return out
    }

    /// B 收到的（再核一次雜湊與欄位）。
    init?(delivery raw: Any?) {
        guard let object = raw as? [String: Any], let id = object["operation_id"] as? String, UUID(uuidString: id) != nil,
              let action = object["action"] as? String, Self.actions.contains(action),
              let owner = (object["owner"] as? String).flatMap({ UUID(uuidString: $0) != nil ? $0.lowercased() : nil }),
              let target = (object["target"] as? String).flatMap({ UUID(uuidString: $0) != nil ? $0.lowercased() : nil }),
              let revision = (object["config_revision"] as? NSNumber)?.intValue,
              let expires = (object["expires_at"] as? NSNumber)?.doubleValue,
              let payload = object["payload"] as? [String: Any], let claimed = object["payload_hash"] as? String else { return nil }
        let data = HandsBuildCanonical.object(payload)
        let hash = "sha256:" + HandsAuth.sha256Hex(data)
        guard data.count <= Self.maxPayload, HandsAuth.constantTimeEqual(claimed, hash) else { return nil }
        let attempt = (object["attempt"] as? String).flatMap { $0.utf8.count <= 64 && !$0.isEmpty ? $0 : nil }
        let epoch = (object["setup_epoch"] as? String).flatMap { $0.utf8.count <= 64 ? $0 : nil }
        let submitted = (object["submitted_at"] as? NSNumber)?.doubleValue ?? expires - Self.maxPickup
        self.init(operationID: id.lowercased(), action: action, owner: owner, target: target, attempt: attempt, configRevision: revision,
                  setupEpoch: epoch, expiresAt: Date(timeIntervalSince1970: expires), payload: data, payloadHash: hash,
                  submittedAt: Date(timeIntervalSince1970: submitted))
    }

    init(operationID: String, action: String, owner: String, target: String, attempt: String?, configRevision: Int, setupEpoch: String?,
         expiresAt: Date, payload: Data, payloadHash: String, submittedAt: Date) {
        self.operationID = operationID
        self.action = action
        self.owner = owner
        self.target = target
        self.attempt = attempt
        self.configRevision = configRevision
        self.setupEpoch = setupEpoch
        self.expiresAt = expiresAt
        self.payload = payload
        self.payloadHash = payloadHash
        self.submittedAt = submittedAt
    }
}

/// B 做完（或做到一半：例如登入網址）交回的一則結果。只給擁有者。
struct HandsBuildResult: Equatable, Sendable {
    static let maxPayload = 16 * 1024
    let operationID: String
    let seq: Int
    /// 最後一則（這件事結束了）。
    let final: Bool
    let payload: Data

    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:] }
    var state: String { object["state"] as? String ?? "" }

    init(operationID: String, seq: Int, final: Bool, object: [String: Any]) {
        self.operationID = operationID
        self.seq = seq
        self.final = final
        payload = HandsBuildCanonical.object(object)
    }

    var wire: [String: Any] { ["operation_id": operationID, "seq": seq, "final": final, "result": object] }

    init?(wire raw: Any?) {
        guard let object = raw as? [String: Any], Set(object.keys).isSubset(of: ["operation_id", "seq", "final", "result"]),
              let id = object["operation_id"] as? String, UUID(uuidString: id) != nil,
              let seq = (object["seq"] as? NSNumber)?.intValue, (0...64).contains(seq), let final = object["final"] as? Bool,
              let result = object["result"] as? [String: Any] else { return nil }
        let data = HandsBuildCanonical.object(result)
        guard data.count <= Self.maxPayload else { return nil }
        operationID = id.lowercased()
        self.seq = seq
        self.final = final
        payload = data
    }
}

enum HandsBuildMailboxError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case expired
    case full
    /// 同一個 operationID 送了不同的內容。
    case conflict
    case unknownTarget
    case unknownOperation
    /// 不是這件事的目標那台（只有 B 能交 B 的結果）。
    case notTarget

    var description: String {
        switch self {
        case .invalid(let what): "hands_build_mailbox_invalid:\(what)"
        case .expired: "hands_build_mailbox_expired"
        case .full: "hands_build_mailbox_full"
        case .conflict: "hands_build_mailbox_conflict"
        case .unknownTarget: "hands_build_mailbox_unknown_target"
        case .unknownOperation: "hands_build_mailbox_unknown_operation"
        case .notTarget: "hands_build_mailbox_not_target"
        }
    }
}

/// 主設備的信箱（只在記憶體）。
final class HandsBuildMailbox: @unchecked Sendable {
    struct Limits {
        var perOwner = 16
        var total = 64
        /// 一件事從送出到最後一則結果被取走，最長多久（登入要等使用者按，最多 10 分鐘；多給一點）。
        var operationLifetime: TimeInterval = 900
        var resultsPerOperation = 8
    }

    private struct Operation {
        let intent: HandsBuildIntent
        var delivered = false
        /// 還沒被擁有者 ack 的結果（P 重新編的序號）。
        var results: [HandsBuildResult] = []
        var finalPosted = false
        var nextSeq = 0
        /// B 送過的序號（outbox 重送＝同一則不收兩次）。
        var senderSeqs: Set<Int> = []
    }

    let limits: Limits
    private let lock = NSLock()
    private var operations: [String: Operation] = [:]
    private var order: [String] = []

    init(limits: Limits = Limits()) { self.limits = limits }

    /// 收一件（冪等：同 id 同內容回 false；不同內容丟 conflict）。
    @discardableResult
    func submit(_ intent: HandsBuildIntent, now: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        purgeLocked(now)
        if let existing = operations[intent.operationID] {
            guard existing.intent.owner == intent.owner, existing.intent.target == intent.target, existing.intent.action == intent.action,
                  existing.intent.payloadHash == intent.payloadHash, existing.intent.attempt == intent.attempt else { throw HandsBuildMailboxError.conflict }
            return false
        }
        guard operations.count < limits.total, operations.values.filter({ $0.intent.owner == intent.owner }).count < limits.perOwner else {
            throw HandsBuildMailboxError.full
        }
        operations[intent.operationID] = Operation(intent: intent)
        order.append(intent.operationID)
        return true
    }

    /// B 取件：給 B 的、還沒交過、取件期限還沒過的（依送出順序）。**只交一次**（B 當掉就是這件沒做：擁有者等不到＝結果未知，不會重做、不會重開窗口）。
    func take(target: String, now: Date) -> [HandsBuildIntent] {
        lock.lock(); defer { lock.unlock() }
        purgeLocked(now)
        var out: [HandsBuildIntent] = []
        for id in order {
            guard var operation = operations[id], !operation.delivered, HandsHostAuthority.same(operation.intent.target, target) else { continue }
            guard operation.intent.expiresAt > now else { continue }
            operation.delivered = true
            operations[id] = operation
            out.append(operation.intent)
        }
        return out
    }

    /// 給 B 的還有幾件沒取（B 要不要快一點問）。
    func pending(target: String, now: Date) -> Int {
        lock.lock(); defer { lock.unlock() }
        return operations.values.filter { !$0.delivered && HandsHostAuthority.same($0.intent.target, target) && $0.intent.expiresAt > now }.count
    }

    /// B 交結果：只有這件事的目標那台能交；序號由 P 重新編（B 送的只當參考）；每件最多幾則。回擁有者（P 本機交給本機的等待者用）。
    @discardableResult
    func post(_ result: HandsBuildResult, from sender: String, now: Date) throws -> String {
        lock.lock(); defer { lock.unlock() }
        purgeLocked(now)
        guard var operation = operations[result.operationID] else { throw HandsBuildMailboxError.unknownOperation }
        guard HandsHostAuthority.same(operation.intent.target, sender) else { throw HandsBuildMailboxError.notTarget }
        guard !operation.finalPosted, !operation.senderSeqs.contains(result.seq) else { return operation.intent.owner }
        guard operation.results.count < limits.resultsPerOperation || result.final else { throw HandsBuildMailboxError.full }
        operation.senderSeqs.insert(result.seq)
        operation.results.append(HandsBuildResult(operationID: result.operationID, seq: operation.nextSeq, final: result.final, object: result.object))
        operation.nextSeq += 1
        if result.final { operation.finalPosted = true }
        operations[result.operationID] = operation
        return operation.intent.owner
    }

    /// 擁有者取結果（只有它的）。acks＝擁有者說「這一件收到第幾則了」：那幾則才從 P 拿掉；最後一則也 ack 了＝整件清掉（完成即清）。
    /// 沒 ack 的下一次再給（回應在路上掉了也拿得回來）；最長留到 operationLifetime。
    func takeResults(owner: String, now: Date, acks: [String: Int] = [:]) -> [HandsBuildResult] {
        lock.lock(); defer { lock.unlock() }
        purgeLocked(now)
        acknowledgeLocked(owner: owner, acks: acks)
        var out: [HandsBuildResult] = []
        for id in order {
            guard let operation = operations[id], HandsHostAuthority.same(operation.intent.owner, owner) else { continue }
            out += operation.results
        }
        return out
    }

    /// 擁有者收到了（本機的擁有者在交給等待者之後馬上 ack）。
    func acknowledge(owner: String, acks: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        acknowledgeLocked(owner: owner, acks: acks)
    }

    private func acknowledgeLocked(owner: String, acks: [String: Int]) {
        guard !acks.isEmpty else { return }
        for (raw, seq) in acks.prefix(128) {
            let id = raw.lowercased()
            guard var operation = operations[id], HandsHostAuthority.same(operation.intent.owner, owner) else { continue }
            operation.results.removeAll { $0.seq <= seq }
            operations[id] = operation.finalPosted && operation.results.isEmpty && operation.nextSeq <= seq + 1 ? nil : operation
        }
        order.removeAll { operations[$0] == nil }
    }

    /// 擁有者還在等的那幾件裡，P 已經不認得的（沒人取就過期、太久、P 重開過）：擁有者收成「結果未知」。別人的一律當不認得（不洩漏）。
    func gone(owner: String, waiting: [String], now: Date) -> [String] {
        lock.lock(); defer { lock.unlock() }
        purgeLocked(now)
        return waiting.prefix(64).map { $0.lowercased() }.filter { id in
            guard let operation = operations[id] else { return true }
            return !HandsHostAuthority.same(operation.intent.owner, owner)
        }
    }

    /// P 手上還有沒有這件（本機的擁有者判斷「不見了」用）。
    func exists(_ id: String, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        purgeLocked(now)
        return operations[id.lowercased()] != nil
    }

    /// 自測與診斷：P 手上還有沒有這件、還留著幾則結果（不回內容）。
    func debugState(_ id: String) -> (exists: Bool, results: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let operation = operations[id.lowercased()] else { return (false, 0) }
        return (true, operation.results.count)
    }

    /// 自測：P 手上所有結果的原文（證明取走即清、別台拿不到）。
    func debugAllResultPayloads() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return operations.values.flatMap { $0.results.map(\.payload) }
    }

    /// P 重開（或自測模擬）：全部作廢。
    func reset() {
        lock.lock(); operations = [:]; order = []; lock.unlock()
    }

    private func purgeLocked(_ now: Date) {
        for id in order {
            guard let operation = operations[id] else { continue }
            let tooOld = now.timeIntervalSince(operation.intent.submittedAt) > limits.operationLifetime
            let neverPicked = !operation.delivered && operation.intent.expiresAt <= now
            if tooOld || neverPicked { operations[id] = nil }
        }
        order.removeAll { operations[$0] == nil }
    }
}

/// 每台回報給主設備的公共狀態（所有設備的畫面都看得到）：只有進度與名稱，**沒有**登入網址、確認 token、配對碼、任何 token 或路徑。
struct HandsBuildDeviceReport: Equatable, Sendable {
    struct Zone: Equatable, Sendable {
        var zoneID: String
        var name: String
        /// 這台有這個網域的 Cloudflare 授權（鑰匙圈裡有；只問有沒有，不讀內容）。
        var authorized: Bool
    }
    struct Account: Equatable, Sendable {
        var id: String
        var name: String
        var zones: [Zone]
    }

    var deviceID: String
    var appliedConfigRevision: Int = 0
    /// W183 R8 整合審查（GPT-6 中）：這台已經套用的撤銷世代（明確關掉的回執）。nil＝舊版沒回報這個欄位。
    var appliedGeneration: Int?
    /// active／inactive／paused／none。
    var permit: String = "none"
    var enabled = false
    /// stopped／starting／running／failed。
    var phase: String = "stopped"
    var phaseText: String = ""
    var publicHost: String?
    var setupEpoch: String?
    var setupBusy = false
    var nextStep: String?
    var stepProblem: String?
    var grants = 0
    /// W183 R8 整合（R8a 審查「暫時的 grant 不算已連線」）：確認過的連線數（grants 含還在確認中的）。舊版沒回報＝nil（畫面不當已連線）。
    var confirmedGrants: Int?
    /// W183 R11：確認過的連線裡最高的等級（ChatGPT 實際拿到的＝這個跟 level 取小；舊版沒回報＝nil）。私訊框的「已連線・Codex、記憶」照這個，
    /// 不把「中央設定是 L2」當成「ChatGPT 已經拿到 L2」（舊的 L1 grant 要斷線再連才升）。
    var grantLevel: Int?
    /// W183 R11（GPT-6 R11 審查 4、5）：確認過的每一筆連線的代號 → 它的等級（代號＝grant id 的雜湊，不含帳號；帳號跟代號的對應只在按［連線］
    /// 的那台自己：HandsConnectAccounts）。舊版沒回報＝nil（沒有逐筆證據：能力未確認、也核對不了目前帳號）。
    var grantLevels: [String: Int]?
    /// W183 R11（GPT-6 R11 審查 1）：這台的主機在中央等級變了之後、生效之前會先把現有的 grant 封頂（HandsService.levelGuard）。
    /// 舊版沒有＝false（主設備遷移的預設升級對它先不升：它有連線的話）。
    var levelGuard = false
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：取樣那一刻這台授權狀態的版本（HandsAuth.stateVersion，只會往上）。按［連線］的那台拿它跟
    /// 連線確認那一刻的版本比先後：新的回報沒有那一條＝不在了；比連線舊的快照不算。舊版沒有＝nil（比不了＝不推定撤銷）。
    var grantsVersion: Int?
    var safetyLocked = false
    /// W183 R8c 審查（GPT-6 高）：安全停機的事故編號（亂數，不是秘密）：別台「解除安全鎖」要帶這個（晚到的舊解除清不掉新事故）。
    var safetyIncident: String?
    /// W183 R8c 審查（GPT-6 高）：這台現在有效 grant 的摘要（id 排序後的雜湊）：「撤銷全部」只作用在按的時候看到的那一組。
    var grantsDigest: String = ""
    /// W183 R8c 審查（GPT-6 中）：這台確定已經釋放的網址（所有權表只憑這個拿掉）。
    var released: [String] = []
    var level = 1
    var allowedProjects: [String] = []
    var projectChoices: [HandsProjectChoice] = []
    var accounts: [Account] = []
    var resources: [HandsBuildOwnership.Record] = []
    /// P 收到的時間（不是回報的那台說的）。
    var receivedAt: Date?

    var wire: [String: Any] {
        var out: [String: Any] = [
            "device_id": deviceID, "applied_config_revision": appliedConfigRevision, "permit": permit, "enabled": enabled,
            "phase": phase, "phase_text": phaseText, "setup_busy": setupBusy, "grants": grants, "safety_locked": safetyLocked,
            "level": level, "allowed_projects": allowedProjects, "project_choices": projectChoices.map(\.wire),
            "accounts": accounts.map { account in
                ["id": account.id, "name": account.name,
                 "zones": account.zones.map { ["zone_id": $0.zoneID, "name": $0.name, "authorized": $0.authorized] }] as [String: Any]
            },
            "resources": resources.map { record -> [String: Any] in
                var row: [String: Any] = ["hostname": record.hostname]
                if let tunnel = record.tunnelID { row["tunnel_id"] = tunnel }
                if let zone = record.zoneID { row["zone_id"] = zone }
                return row
            }]
        if let publicHost { out["public_host"] = publicHost }
        if let setupEpoch { out["setup_epoch"] = setupEpoch }
        if let nextStep { out["next_step"] = nextStep }
        if let stepProblem { out["step_problem"] = stepProblem }
        if let receivedAt { out["received_at"] = Int(receivedAt.timeIntervalSince1970) }
        if let safetyIncident { out["safety_incident"] = safetyIncident }
        if !grantsDigest.isEmpty { out["grants_digest"] = grantsDigest }
        if !released.isEmpty { out["released"] = released }
        if let confirmedGrants { out["confirmed_grants"] = confirmedGrants }   // W183 R8 整合
        if let grantLevel { out["grant_level"] = grantLevel }   // W183 R11
        if let grantLevels { out["grant_levels"] = grantLevels }   // W183 R11（GPT-6 R11 審查 4、5）
        if levelGuard { out["level_guard"] = true }   // W183 R11（GPT-6 R11 審查 1）
        if let grantsVersion { out["grants_version"] = grantsVersion }   // W183 R11 最後一輪
        if let appliedGeneration { out["applied_generation"] = appliedGeneration }   // W183 R8 整合審查
        return out
    }

    /// W183 R11（GPT-6 R11 審查 4）：一筆連線的代號（grant id 的雜湊；回報、連線結果都只帶這個，不帶 grant id、不帶帳號）。
    static func grantTag(_ grantID: String) -> String {
        "g_" + String(HandsAuth.sha256Hex(Data(("tatwo-grant-tag|" + grantID.lowercased()).utf8)).prefix(24))
    }

    /// 收到的代號只收這個樣子（g_ ＋ 24 個十六進位字）。
    static func validGrantTag(_ raw: Any?) -> String? {
        guard let tag = raw as? String, tag.utf8.count == 26, tag.hasPrefix("g_"), tag.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
        return tag.lowercased()
    }

    /// 有效 grant 的摘要（沒有＝空的）。
    static func digest(grants ids: [String]) -> String {
        ids.isEmpty ? "" : "sha256:" + String(HandsAuth.sha256Hex(Data(ids.map { $0.lowercased() }.sorted().joined(separator: "\n").utf8)).prefix(32))
    }

    init(deviceID: String) { self.deviceID = deviceID.lowercased() }

    /// 收到的（每個欄位都驗、都有上限）。
    init?(wire raw: Any?) {
        guard let object = raw as? [String: Any],
              let id = (object["device_id"] as? String).flatMap({ UUID(uuidString: $0) != nil ? $0.lowercased() : nil }) else { return nil }
        deviceID = id
        appliedConfigRevision = max((object["applied_config_revision"] as? NSNumber)?.intValue ?? 0, 0)
        appliedGeneration = (object["applied_generation"] as? NSNumber).map { max($0.intValue, 0) }   // W183 R8 整合審查
        permit = ["active", "inactive", "paused", "none"].first { $0 == object["permit"] as? String } ?? "none"
        enabled = object["enabled"] as? Bool ?? false
        phase = ["stopped", "starting", "running", "failed"].first { $0 == object["phase"] as? String } ?? "stopped"
        phaseText = String((object["phase_text"] as? String ?? "").filter { !$0.isNewline }.prefix(200))
        publicHost = HandsGatewayLaunch.validHost(object["public_host"] as? String)
        setupEpoch = (object["setup_epoch"] as? String).flatMap { $0.utf8.count <= 64 ? $0 : nil }
        setupBusy = object["setup_busy"] as? Bool ?? false
        nextStep = (object["next_step"] as? String).flatMap { HandsSetupStep(rawValue: $0)?.rawValue }
        stepProblem = (object["step_problem"] as? String).map { String($0.filter { !$0.isNewline }.prefix(300)) }
        grants = min(max((object["grants"] as? NSNumber)?.intValue ?? 0, 0), 999)
        confirmedGrants = (object["confirmed_grants"] as? NSNumber).map { min(max($0.intValue, 0), grants) }   // W183 R8 整合：不超過全部的
        grantLevel = (object["grant_level"] as? NSNumber).map { min(max($0.intValue, 0), HandsSettings.maxLevel) }   // W183 R11
        // W183 R11（GPT-6 R11 審查 4、5）：逐筆的代號與等級（最多 64 筆；樣子不對的整份不收＝當成沒有逐筆證據）。
        if let raw = object["grant_levels"] as? [String: Any], raw.count <= 64 {
            var levels: [String: Int] = [:]
            for (key, value) in raw {
                guard let tag = Self.validGrantTag(key), let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { levels = [:]; break }
                levels[tag] = min(max(number.intValue, 0), HandsSettings.maxLevel)
            }
            grantLevels = levels.count == raw.count ? levels : nil
        }
        levelGuard = object["level_guard"] as? Bool ?? false   // W183 R11（GPT-6 R11 審查 1）
        grantsVersion = (object["grants_version"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : max($0.intValue, 0) }
        safetyLocked = object["safety_locked"] as? Bool ?? false
        level = min(max((object["level"] as? NSNumber)?.intValue ?? 1, 0), HandsSettings.maxLevel)
        allowedProjects = (object["allowed_projects"] as? [String] ?? []).prefix(64).compactMap { UUID(uuidString: $0)?.uuidString }
        projectChoices = HandsProjectChoice.list(object["project_choices"]) ?? []   // W183 R8 整合：R7a 審查——不完整的清單整份不收（list 回 nil）
        accounts = (object["accounts"] as? [[String: Any]] ?? []).prefix(16).compactMap { raw in
            guard let id = raw["id"] as? String, CloudflareAccountsStore.validID(id) else { return nil }
            let zones = (raw["zones"] as? [[String: Any]] ?? []).prefix(64).compactMap { zone -> Zone? in
                guard let zoneID = zone["zone_id"] as? String, CloudflareAccountsStore.validID(zoneID) else { return nil }
                return Zone(zoneID: zoneID, name: HandsGatewayLaunch.validHost(zone["name"] as? String) ?? "", authorized: zone["authorized"] as? Bool ?? false)
            }
            return Account(id: id, name: String((raw["name"] as? String ?? "").filter { !$0.isNewline }.prefix(80)), zones: Array(zones))
        }
        resources = (object["resources"] as? [[String: Any]] ?? []).prefix(8).compactMap { raw in
            guard let host = HandsGatewayLaunch.validHost(raw["hostname"] as? String) else { return nil }
            return HandsBuildOwnership.Record(hostname: host, deviceID: id,
                                              tunnelID: (raw["tunnel_id"] as? String).flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil },
                                              zoneID: (raw["zone_id"] as? String).flatMap { CloudflareAccountsStore.validID($0) ? $0 : nil },
                                              evidence: "created", recordedAt: Date())
        }
        receivedAt = (object["received_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        safetyIncident = (object["safety_incident"] as? String).flatMap {
            (1...64).contains($0.utf8.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? $0 : nil
        }
        grantsDigest = (object["grants_digest"] as? String).flatMap {
            $0.hasPrefix("sha256:") && $0.utf8.count <= 80 && $0.dropFirst(7).allSatisfy(\.isHexDigit) ? $0 : nil
        } ?? ""
        released = (object["released"] as? [String] ?? []).prefix(8).compactMap { HandsGatewayLaunch.validHost($0) }
    }
}

/// 主設備這端：設定正本、信封、信箱、每台回報的公共狀態。副設備經設備簽章 RPC `hands_build` 進來（HandsBuildRemote）；主設備自己在行程內直接叫。
final class HandsBuildAuthority: @unchecked Sendable {
    struct Dependencies {
        var store: HandsBuildConfigStore
        var signer: HandsBuildSigner
        /// 已配對、主設備認得的設備（含這台）。
        var knownDevices: () -> [HandsSetupDevice]
        /// 這台（主設備）自己的 id。
        var localID: () -> String?
        var now: () -> Date = Date.init
        var envelopeLifetime: TimeInterval = HandsBuildEnvelopes.lifetime
    }

    static let shared = HandsBuildAuthority(dependencies: .init(
        store: .shared, signer: .ssh(), knownDevices: { HandsSetup.pairedDevices() },
        localID: { (try? DeviceIdentityStore.readLocal())?.deviceID.lowercased() }))

    let dependencies: Dependencies
    let mailbox = HandsBuildMailbox()
    private let envelopes = HandsBuildEnvelopeCache()
    private let lock = NSLock()
    private var reports: [String: HandsBuildDeviceReport] = [:]
    /// 每台副設備最近兩次來同步的時間（W183 R8c 審查：有副設備在熱問＝主設備自己也快一點更新它自己的狀態）。
    private var syncTimes: [String: (last: Date, previous: Date?)] = [:]
    /// 給主設備自己的意圖（本機直接做）；結果擁有者是主設備自己（本機直接交）。由 HandsBuildSync 接上。
    var executeLocal: ((HandsBuildIntent) -> Void)?
    var deliverLocal: ((HandsBuildResult) -> Void)?

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    private func known(_ id: String) -> Bool {
        dependencies.knownDevices().contains { HandsHostAuthority.same($0.id, id) } || HandsHostAuthority.same(dependencies.localID(), id)
    }

    /// 記一台的公共狀態（收到的時間用 P 自己的鐘）＋它有建立證據的資源（所有權）。
    func record(_ report: HandsBuildDeviceReport, from sender: String) {
        guard HandsHostAuthority.same(report.deviceID, sender) else { return }
        var stamped = report
        stamped.receivedAt = dependencies.now()
        lock.lock(); reports[sender.lowercased()] = stamped; lock.unlock()
        dependencies.store.recordResources(device: sender, report.resources, released: report.released)
        // W183 R11（GPT-6 R11 審查 1）：舊的一份遷移時待升到預設 L2 的那台：它的回報說會先封頂現有連線（或沒有連線）才升。
        // W183 R11 最後一輪：帶收到的時間（raiseCheck 看這一份新不新鮮）。
        dependencies.store.applyPendingDefault(device: sender, report: stamped)
    }

    /// 有副設備在熱問（最近 10 秒內來過、而且前後兩次隔不到 5 秒）。
    func membersPollingHot(now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return syncTimes.values.contains { entry in
            guard let previous = entry.previous else { return false }
            return now.timeIntervalSince(entry.last) < 10 && entry.last.timeIntervalSince(previous) < 5
        }
    }

    func reportsSnapshot() -> [HandsBuildDeviceReport] {
        lock.lock(); defer { lock.unlock() }
        return Array(reports.values).sorted { $0.deviceID < $1.deviceID }
    }

    /// 畫面看的（設定、每台公共狀態、所有權、已配對設備）。沒有秘密。
    func view() -> [String: Any] {
        let ownership = dependencies.store.ownership()
        var out: [String: Any] = ["reports": reportsSnapshot().map(\.wire), "ownership": ownership.wire, "ownership_unknown": ownership.unknown,
                                  "devices": dependencies.knownDevices().map { ["id": $0.id.lowercased(), "name": String($0.name.prefix(60)), "is_primary": $0.isPrimary] }]
        if let config = dependencies.store.load() { out["config"] = config.wire }
        out["server_time"] = Int(dependencies.now().timeIntervalSince1970)
        return out
    }

    /// 一台來同步：記它的狀態 → 簽給它的信封 → 給它的意圖 → 它是擁有者的結果（先照它的 ack 拿掉收過的）→ 它還在等、P 已經不認得的（gone）
    /// → 畫面要的全貌。
    func sync(from sender: String, report: HandsBuildDeviceReport?, acks: [String: Int] = [:], waiting: [String] = []) throws -> [String: Any] {
        guard known(sender) else { throw HandsBuildMailboxError.unknownTarget }
        let arrived = dependencies.now()
        lock.lock()
        let key = sender.lowercased()
        syncTimes[key] = (arrived, syncTimes[key]?.last)
        if syncTimes.count > 32, let oldest = syncTimes.min(by: { $0.value.last < $1.value.last })?.key { syncTimes[oldest] = nil }
        lock.unlock()
        if let report { record(report, from: sender) }
        var out = view()
        if !HandsHostAuthority.same(sender, dependencies.localID()), let config = dependencies.store.load() {
            out["envelope"] = try envelopes.envelope(config: config, target: sender, signer: dependencies.signer, now: dependencies.now(),
                                                     lifetime: dependencies.envelopeLifetime).wire
        }
        let now = dependencies.now()
        out["intents"] = mailbox.take(target: sender, now: now).map(\.deliveryWire)
        out["results"] = mailbox.takeResults(owner: sender, now: now, acks: acks).map(\.wire)
        let gone = mailbox.gone(owner: sender, waiting: waiting, now: now)
        if !gone.isEmpty { out["gone"] = gone }
        return out
    }

    /// 改設定（預期版本比對）。回新的設定。
    func updateConfig(from sender: String, expectedRevision: Int, ops: [HandsBuildConfigOp]) throws -> HandsBuildConfig {
        guard known(sender) else { throw HandsBuildConfigError.unknownDevice }
        // W183 R11 第二輪（GPT-6 R11b 審查 1，高）：調高等級照那台最後的回報核。W183 R11 最後一輪（GPT-6 R11c 審查 1）：舊版主機一律不調高；
        // 會先封頂的主機要回報夠新、已經套用到改之前的這一版。
        let now = dependencies.now()
        return try dependencies.store.update(expectedRevision: expectedRevision, ops: ops,
                                             raise: { id, current in HandsBuildConfig.raiseCheck(self.report(for: id), config: current, now: now) })
    }

    /// 那台最後一次的回報（沒有＝nil）。
    func report(for id: String) -> HandsBuildDeviceReport? {
        lock.lock(); defer { lock.unlock() }
        return reports[id.lowercased()]
    }

    /// A 送一件事給 B。目標是主設備自己＝本機直接做。
    func submit(_ intent: HandsBuildIntent) throws {
        guard known(intent.owner), known(intent.target) else { throw HandsBuildMailboxError.unknownTarget }
        let fresh = try mailbox.submit(intent, now: dependencies.now())
        if fresh, HandsHostAuthority.same(intent.target, dependencies.localID()), let executeLocal {
            for delivered in mailbox.take(target: intent.target, now: dependencies.now()) { executeLocal(delivered) }
        }
    }

    /// B 交結果。擁有者是主設備自己＝本機直接交給等待者（交完馬上 ack）。
    func post(_ result: HandsBuildResult, from sender: String) throws {
        let owner = try mailbox.post(result, from: sender, now: dependencies.now())
        if HandsHostAuthority.same(owner, dependencies.localID()), let deliverLocal {
            deliverLocalResults(owner: owner)
        }
    }

    /// 本機是擁有者的結果：交給等待者、馬上 ack（同一個行程，不會掉）。
    func deliverLocalResults(owner: String) {
        guard let deliverLocal else { return }
        let ready = mailbox.takeResults(owner: owner, now: dependencies.now())
        var acks: [String: Int] = [:]
        for result in ready {
            deliverLocal(result)
            acks[result.operationID] = max(acks[result.operationID] ?? -1, result.seq)
        }
        mailbox.acknowledge(owner: owner, acks: acks)
    }
}

/// 設備簽章 RPC `hands_build`（OSAgentBridge 先 DeviceDispatch.authenticate 驗章，再交進來；只准 SSH 轉進來的呼叫者）。
enum HandsBuildRemote {
    static let method = "hands_build"
    static let ops: Set<String> = ["sync", "config", "submit", "result"]

    static func handle(payload: [String: Any], sender: String, authority: HandsBuildAuthority = .shared) throws -> [String: Any] {
        guard let op = payload["op"] as? String, ops.contains(op) else { throw HandsBuildMailboxError.invalid("op") }
        switch op {
        case "sync":
            guard Set(payload.keys).isSubset(of: ["op", "report", "acks", "waiting"]) else { throw HandsBuildMailboxError.invalid("unexpected field") }
            let report = payload["report"].flatMap { HandsBuildDeviceReport(wire: $0) }
            var acks: [String: Int] = [:]
            if let raw = payload["acks"] {
                guard let object = raw as? [String: Any], object.count <= 128 else { throw HandsBuildMailboxError.invalid("acks") }
                for (id, value) in object {
                    guard UUID(uuidString: id) != nil, let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          (0...64).contains(number.intValue) else { throw HandsBuildMailboxError.invalid("acks") }
                    acks[id.lowercased()] = number.intValue
                }
            }
            var waiting: [String] = []
            if let raw = payload["waiting"] {
                guard let list = raw as? [Any], list.count <= 64 else { throw HandsBuildMailboxError.invalid("waiting") }
                waiting = try list.map { item in
                    guard let id = item as? String, UUID(uuidString: id) != nil else { throw HandsBuildMailboxError.invalid("waiting") }
                    return id.lowercased()
                }
            }
            return try authority.sync(from: sender, report: report, acks: acks, waiting: waiting)
        case "config":
            guard Set(payload.keys).isSubset(of: ["op", "expected_revision", "changes", "expires_at"]) else { throw HandsBuildMailboxError.invalid("unexpected field") }
            // 簽章涵蓋的期限：延遲送達的舊改動不收（預期版本比對之外的第二道）。
            let now = authority.dependencies.now().timeIntervalSince1970
            guard let expires = (payload["expires_at"] as? NSNumber)?.doubleValue, expires > now, expires <= now + HandsRemote.maxAhead else {
                throw HandsBuildMailboxError.expired
            }
            guard let raw = payload["changes"] as? [Any], raw.count <= 32 else { throw HandsBuildMailboxError.invalid("changes") }
            let changes = raw.compactMap(HandsBuildConfigOp.init(wire:))
            guard changes.count == raw.count else { throw HandsBuildMailboxError.invalid("changes") }
            // W183 R8c 審查（GPT-6 中）：預期版本一定要帶、而且是合法的整數（沒帶、布林、小數、負的＝不收）。
            guard let number = payload["expected_revision"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  Double(number.intValue) == number.doubleValue, number.intValue >= 0 else { throw HandsBuildMailboxError.invalid("expected_revision") }
            let config = try authority.updateConfig(from: sender, expectedRevision: number.intValue, ops: changes)
            return ["config": config.wire]
        case "submit":
            guard let raw = payload["intent"] as? [String: Any], Set(payload.keys) == ["op", "intent"] else { throw HandsBuildMailboxError.invalid("intent") }
            let intent = try HandsBuildIntent.submission(raw, owner: sender, now: authority.dependencies.now())
            try authority.submit(intent)
            return ["accepted": true, "operation_id": intent.operationID]
        default:   // result
            guard let raw = payload["result"], Set(payload.keys) == ["op", "result"], let result = HandsBuildResult(wire: raw) else {
                throw HandsBuildMailboxError.invalid("result")
            }
            try authority.post(result, from: sender)
            return ["accepted": true]
        }
    }
}
