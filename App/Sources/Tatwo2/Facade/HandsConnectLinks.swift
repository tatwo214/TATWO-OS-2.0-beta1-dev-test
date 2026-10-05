import Foundation

// W183 R6b：擁有者（按［連線］那台）怎麼跟主機說話。這台就是主機＝直接呼叫 HandsConnectHost（在背景執行緒，主機要讀專案名稱會回主執行緒）；
// 副設備（主機是主設備）＝設備簽章 RPC（remote_hands_action 的 connect_*，帶簽章涵蓋的 expires_at；擁有者＝主機驗章得到的這台）。
// 送出結果未知（網路斷、逾時）回 .unknown：呼叫端先查狀態，不直接重送。

enum HandsConnectLinkError: Error, Equatable, CustomStringConvertible {
    /// 主機明確拒絕（機器代碼）。
    case refused(HandsConnectRefusal)
    /// 送出去了但不知道結果（網路、逾時）：先查，不重送。
    case unknown(String)
    /// 其他明確的失敗（白話）。
    case failed(String)

    var description: String {
        switch self {
        case .refused(let refusal): refusal.rawValue
        case .unknown(let text): "unknown: \(text)"
        case .failed(let text): text
        }
    }

    var plain: String {
        switch self {
        case .refused(let refusal): refusal.plain
        case .unknown: "連不到主機，結果不確定"
        case .failed(let text): text
        }
    }
}

protocol HandsConnectLink: Sendable {
    var isRemote: Bool { get }
    func offer() async throws -> HandsConnectOffer
    func begin(_ request: HandsConnectRequest) async throws -> HandsConnectStatus
    func status(attemptID: String, evidence: String?) async throws -> HandsConnectStatus
    func cancel(attemptID: String, reason: String) async throws -> HandsConnectStatus
    /// W183 R6b 審查：擁有者核對過 Pod 帳號之後確認（只有這一下會變成已連線）。
    func confirm(attemptID: String) async throws -> HandsConnectStatus
}

enum HandsConnectOffMain {
    /// 在背景執行緒做（主機的判斷可能要回主執行緒讀專案名稱；簽章 RPC 會等網路）。
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// 這台就是主機。
struct HandsConnectLocalLink: HandsConnectLink {
    let host: HandsConnectHost
    let ownerID: String
    var isRemote: Bool { false }

    private func mapped<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        do { return try await HandsConnectOffMain.run(body) }
        catch let refusal as HandsConnectRefusal { throw HandsConnectLinkError.refused(refusal) }
    }

    func offer() async throws -> HandsConnectOffer { try await mapped { [host] in try host.offer(includeChoices: true) } }   // W183 R7a：帶可以選的專案
    func begin(_ request: HandsConnectRequest) async throws -> HandsConnectStatus {
        try await mapped { [host, ownerID] in try host.begin(request, sender: ownerID) }
    }
    func status(attemptID: String, evidence: String?) async throws -> HandsConnectStatus {
        try await mapped { [host, ownerID] in try host.status(attemptID: attemptID, sender: ownerID, evidence: evidence) }
    }
    func cancel(attemptID: String, reason: String) async throws -> HandsConnectStatus {
        try await mapped { [host, ownerID] in try host.cancel(attemptID: attemptID, sender: ownerID, reason: reason) }
    }
    func confirm(attemptID: String) async throws -> HandsConnectStatus {
        try await mapped { [host, ownerID] in try host.confirm(attemptID: attemptID, sender: ownerID) }
    }
}

/// 副設備：問主設備（設備簽章 RPC）。
struct HandsConnectRemoteLink: HandsConnectLink, @unchecked Sendable {
    let dispatch: DeviceDispatch
    var isRemote: Bool { true }
    /// 請求有效多久（簽章涵蓋；主機收 now < expires_at ≤ now＋300）。
    static let lifetime: TimeInterval = 90

    private func call(_ op: String, _ fields: [String: Any]) async throws -> [String: Any] {
        var payload = fields
        payload["op"] = op
        payload["expires_at"] = Int(Date().timeIntervalSince1970 + Self.lifetime)
        let sendable = HandsConnectPayload(payload)
        do {
            return try await HandsConnectOffMain.run { [dispatch] in
                HandsConnectPayload(try dispatch.callPrimary(method: "remote_hands_action", payload: sendable.value))
            }.value
        } catch {
            throw Self.classify(error)
        }
    }

    /// 主機回的拒絕（hands_remote_invalid: <代碼>）＝明確拒絕；其他（連不上、逾時、驗章通道斷）＝結果未知。
    static func classify(_ error: Error) -> HandsConnectLinkError {
        let text = String(describing: error)
        if let refusal = HandsConnectRefusal.allCases.first(where: { text.contains($0.rawValue) }) { return .refused(refusal) }
        if text.contains(HandsRemote.expiredReason) { return .failed("這個動作送到主機時已經過期（或兩台的時間差太多）；再按一次") }
        if text.contains("hands_remote_invalid: op") || text.contains("hands_remote_invalid: unexpected field") {
            return .failed("主設備的 TATWO OS 版本太舊（不認得「連線」）；主設備更新後再試")
        }
        if text.contains("hands_remote_invalid") { return .failed("主設備沒有照做") }
        return .unknown(HandsRemoteClient.plain(error))
    }

    func offer() async throws -> HandsConnectOffer {
        let response = try await call("connect_offer", [:])
        guard let offer = HandsConnectOffer(wire: response) else { throw HandsConnectLinkError.failed("主設備回的連線資料看不懂") }
        return offer
    }

    func begin(_ request: HandsConnectRequest) async throws -> HandsConnectStatus {
        var fields: [String: Any] = ["attempt_id": request.attemptID, "setup_epoch": request.setupEpoch,
                                     "owner_device_id": request.ownerDeviceID, "scope_digest": request.scopeDigest, "mcp_url": request.mcpURL]
        // W183 R7a：卡上選的範圍（主機收這兩個欄位才帶：舊版主機會拒絕不認得的欄位）。
        if let choice = request.choice { fields.merge(choice.wireFields) { _, new in new } }
        let response = try await call("begin_connect", fields)
        return try decode(response, attemptID: request.attemptID)
    }

    func status(attemptID: String, evidence: String?) async throws -> HandsConnectStatus {
        var fields: [String: Any] = ["attempt_id": attemptID]
        if let evidence { fields["evidence"] = evidence }
        return try decode(try await call("connect_status", fields), attemptID: attemptID)
    }

    func cancel(attemptID: String, reason: String) async throws -> HandsConnectStatus {
        try decode(try await call("cancel_connect", ["attempt_id": attemptID, "reason": HandsConnectHost.cleanReason(reason)]), attemptID: attemptID)
    }

    func confirm(attemptID: String) async throws -> HandsConnectStatus {
        try decode(try await call("connect_confirm", ["attempt_id": attemptID]), attemptID: attemptID)
    }

    private func decode(_ response: [String: Any], attemptID: String) throws -> HandsConnectStatus {
        guard let status = HandsConnectStatus(wire: response), status.attemptID == attemptID else {
            throw HandsConnectLinkError.failed("主設備回的連線狀態看不懂")
        }
        return status
    }
}

/// 跨執行緒搬 [String: Any]（JSON 形狀的值，只在一個呼叫裡用）。
struct HandsConnectPayload: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// W183 R8c（在哪台都能做；GPT-6 必改 3、5）：主機是**別台副設備**（或這台是主設備、主機是某台副設備）：每一步都變成一件交給那台的事，
/// 經主設備的信箱（HandsBuildMailbox）：那台自己驗、自己做（跟設備簽章 RPC 同一套主機規則：擁有者＝主設備驗章得到的這台），
/// 結果（含配對碼）**只回到這台**。等不到結果＝結果未知（.unknown：流程先查、不重送）。
struct HandsConnectMailboxLink: HandsConnectLink, @unchecked Sendable {
    let target: String
    let sync: HandsBuildSync
    /// 每一步最多等多久（那台要先來取件：沒事時 10 秒問一次）。
    var timeout: TimeInterval = 45
    var isRemote: Bool { true }

    private func call(_ op: String, _ fields: [String: Any]) async throws -> [String: Any] {
        var payload = fields
        payload["remote_op"] = op
        payload["expires_at"] = Int(Date().timeIntervalSince1970 + HandsConnectRemoteLink.lifetime)
        let result: [String: Any]
        do {
            result = try await sync.request(target: target, action: "connect", payload: payload, timeout: timeout)
        } catch HandsBuildSyncError.timeout {
            throw HandsConnectLinkError.unknown("mailbox_timeout")
        } catch {
            throw HandsConnectLinkError.unknown(String(describing: error))
        }
        if result["state"] as? String == "done", let response = result["response"] as? [String: Any] { return response }
        let reason = result["reason"] as? String ?? ""
        if let refusal = HandsConnectRefusal(rawValue: reason) { throw HandsConnectLinkError.refused(refusal) }
        if reason == HandsRemote.expiredReason || reason == "expired" {
            throw HandsConnectLinkError.failed("這個動作送到那台時已經過期（或兩台的時間差太多）；再按一次")
        }
        if reason == "not_target" || reason == "duplicate" { throw HandsConnectLinkError.unknown(reason) }
        throw HandsConnectLinkError.failed("那台沒有照做（\(reason.isEmpty ? "看不懂的回覆" : reason)）")
    }

    func offer() async throws -> HandsConnectOffer {
        let response = try await call("connect_offer", [:])
        guard let offer = HandsConnectOffer(wire: response), HandsHostAuthority.same(offer.hostDeviceID, target) else {
            throw HandsConnectLinkError.failed("那台回的連線資料看不懂（或不是那台的）")
        }
        return offer
    }

    func begin(_ request: HandsConnectRequest) async throws -> HandsConnectStatus {
        var fields: [String: Any] = ["attempt_id": request.attemptID, "setup_epoch": request.setupEpoch,
                                     "owner_device_id": request.ownerDeviceID, "scope_digest": request.scopeDigest, "mcp_url": request.mcpURL]
        if let choice = request.choice { fields.merge(choice.wireFields) { _, new in new } }
        return try decode(try await call("begin_connect", fields), attemptID: request.attemptID)
    }

    func status(attemptID: String, evidence: String?) async throws -> HandsConnectStatus {
        var fields: [String: Any] = ["attempt_id": attemptID]
        if let evidence { fields["evidence"] = evidence }
        return try decode(try await call("connect_status", fields), attemptID: attemptID)
    }

    func cancel(attemptID: String, reason: String) async throws -> HandsConnectStatus {
        try decode(try await call("cancel_connect", ["attempt_id": attemptID, "reason": HandsConnectHost.cleanReason(reason)]), attemptID: attemptID)
    }

    func confirm(attemptID: String) async throws -> HandsConnectStatus {
        try decode(try await call("connect_confirm", ["attempt_id": attemptID]), attemptID: attemptID)
    }

    private func decode(_ response: [String: Any], attemptID: String) throws -> HandsConnectStatus {
        guard let status = HandsConnectStatus(wire: response), status.attemptID == attemptID else {
            throw HandsConnectLinkError.failed("那台回的連線狀態看不懂")
        }
        return status
    }
}

enum HandsConnectLinkResolver {
    /// W183 R8c：連指定的那台——這台＝本機（要有啟用許可）；主設備＝設備簽章 RPC；別台副設備（或這台是主設備）＝經主設備的信箱。
    static func live(target: String) -> (link: (any HandsConnectLink)?, problem: String?) {
        let identity = try? DeviceIdentityStore.readLocal()
        guard let local = identity?.deviceID, !local.isEmpty else { return (nil, "這台還沒有設備身分；先到「設定 › 設備」完成設定") }
        if HandsHostAuthority.same(target, local) {
            let service = HandsService.shared
            let settings = service.settings.load()
            guard settings.enabled, service.deviceAllowed(settings), HandsBuildPermit.permits(local) else {
                return (nil, "這台的 ChatGPT build 還沒準備好（沒勾這台、或還沒套用網址）")
            }
            return (HandsConnectLocalLink(host: .shared, ownerID: local), nil)
        }
        if identity?.role == .secondary, HandsHostAuthority.same(identity?.primaryDeviceID, target) {
            return (HandsConnectRemoteLink(dispatch: .shared), nil)
        }
        return (HandsConnectMailboxLink(target: target.lowercased(), sync: .shared), nil)
    }

    /// 這台該怎麼跟主機說話：這台是主機＝本機；副設備＝問主設備；主設備但主機是別台＝不行（請在那台按）。
    static func live() -> (link: (any HandsConnectLink)?, problem: String?) {
        let identity = try? DeviceIdentityStore.readLocal()
        guard let local = identity?.deviceID, !local.isEmpty else { return (nil, "這台還沒有設備身分；先到「設定 › 設備」完成設定") }
        let service = HandsService.shared
        let settings = service.settings.load()
        if settings.enabled, service.deviceAllowed(settings), HandsHostAuthority.same(settings.hostDeviceID ?? local, local) {
            return (HandsConnectLocalLink(host: .shared, ownerID: local), nil)
        }
        if identity?.role == .secondary { return (HandsConnectRemoteLink(dispatch: .shared), nil) }
        return (nil, "ChatGPT 手腳的主機是另一台：請在那台的私訊框按「連線」")
    }
}
