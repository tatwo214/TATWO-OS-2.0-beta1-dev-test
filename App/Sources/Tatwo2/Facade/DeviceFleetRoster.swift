import CryptoKit
import Darwin
import Foundation

enum DeviceFleetReason {
    static let unsupportedMethods = ["unsupported_method", "unknown_method", "method_not_found"]
    static let projectionRefusals = ["projection_unsupported", "malformed"]
    enum Probed { case source, target }
    enum Context { case operation(device: String = "對方設備"), transfer(PrimaryTransferState.Record?, probed: Probed = .target), memory(pushing: Bool, offline: Bool) }
    struct ProbedError: LocalizedError, CustomStringConvertible {
        let error: Error
        let record: PrimaryTransferState.Record
        let probed: Probed
        var errorDescription: String? { plain(error, context: .transfer(record, probed: probed)) }
        var description: String { plain(error, context: .transfer(record, probed: probed)) }
    }
    /// Codes belong to protocol decisions and audit, never to visible error text.
    static func code(_ error: Error) -> String? {
        if let located = error as? ProbedError { return code(located.error) }
        let raw: String?
        if let failure = error as? DeviceDispatch.Failure { raw = failure.reason }
        else if let call = error as? DeviceFleetGate.CallError { raw = call.reason }
        else if let fleet = error as? DeviceFleetError { raw = fleet.reason }
        else { raw = (error as? LocalizedError)?.errorDescription }
        guard let raw else { return nil }
        return raw.hasPrefix("remote_error: ") ? String(raw.dropFirst(14)) : raw
    }
    static func plain(_ error: Error, context: Context = .operation()) -> String {
        let text = (code(error) ?? String(describing: error)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let located = error as? ProbedError { return plain(located.error, context: .transfer(located.record, probed: located.probed)) }
        var next = "再試一次。", device = "對方設備"
        switch context {
        case .operation(let name): device = name
        case .transfer(let record, let probed):
            device = probed == .source ? "舊主設備" : "新主設備"
            if let record { next = !record.epochComplete ? "回移交卡重試同步。" : record.constitutionComplete ? "再繼續③④。" : "再按②。" }
        case .memory: break
        }
        if case .memory(let pushing, let offline) = context {
            device = "主設備"
            if offline { return "連不上主設備" }
            if pushing, ["invalid_memory_bundle", "invalid_memory_bundle_tree", "memory_bundle_unavailable"].contains(text) {
                return "主設備拒收：這台送來的記憶驗不過，這輪先不送"
            }
        }
        switch text {
        case "fleet_app_rpc_unavailable": return device + "的 App 沒開，請打開後" + next
        case "fleet_ssh_endpoint_unreachable": return device + "目前離線，請恢復連線後" + next
        case "transfer_work_readback_pending": return "新主設備還沒收到這台最新的工作檔，請確認新主設備的 App 開著，稍後再按②。"
        case "transfer_identity_stale": return device + "的狀態已過期，請打開 App 後" + next
        case "target_authority_mismatch": return "新主設備的角色或主權版本尚未同步，請同步設備名單後再開始移交。"
        case "transfer_in_progress_retry_existing": return "已有未完成的移交，請回移交卡重試同步，再繼續可操作的步驟。"
        case "invalid_transfer_target": return "移交對象不可用，請從設備卡重新選擇可移交的副設備。"
        case "transfer_stale_epoch": return "移交的主權版本已過期，請同步設備名單後重新確認移交卡。"
        case "fleet_transferNotReady": return "缺少已確認的交接記錄或新主設備簽章，不能改主權。"
        case "rpc_parameters_too_large", "memory_bundle_too_large":
            if case .memory = context { return "記憶內容太大，超過受限通道容量；請在權限卡允許雙向完整連線後重試，或請管理者協助同步" }
            return "這次傳送的內容太大，請縮小內容後再試。"
        case "rpc_proof_expired": return "兩台時間不一致，請開啟自動設定日期與時間"
        case "fleet_app_rpc_refused", "caller_not_trusted", "unsupported_method", "unknown_method", "method_not_found", "unknown_memory_sync_method":
            if case .memory = context { return "主設備的 App 還沒更新，不認得記憶同步" }
            return "對方的 App 尚未接受這項操作，請確認權限與版本後再試一次。"
        case "invalid_memory_sync_receipt": return "主設備看不懂這次送的記憶（兩台的 App 版本可能不同）"
        case "invalid_memory_sync_target": return "主設備看不懂這次的請求（兩台的 App 版本可能不同）"
        case "branch_not_received": return "主設備沒收到這次送的記憶，下一輪重送"
        case "not_primary", "primary_transferred": return "對方已經不是主設備，會自動找新主"
        case "memory_bundle_unavailable", "invalid_memory_bundle", "invalid_memory_bundle_tree": return "這次從主設備拉來的記憶驗不過，這輪不合併"
        case "fleet_gate_denied", "fleet_capabilityDenied":
            if case .memory = context { return "主設備沒開這台的記憶權限" }
            return "管理者尚未允許這項操作，請確認權限後再試一次。"
        case "untrusted_rpc_sender": return "對方未接受這台的簽章，要重新配對"
        case "revoked_rpc_key": return "這台的配對金鑰在主設備被撤銷了"
        case "invalid_ssh_proof": return "主設備驗不過這台的簽章"
        case "stale_epoch_or_replayed_sequence": return "這次請求已收過，或主設備身分已變更；請重新同步"
        case "paired_ssh_signing_unavailable": return "這台的配對金鑰簽不了名"
        case "authority_unknown": return "這台還不知道誰是主設備"
        case "primary_not_paired": return "還沒跟主設備配對"
        case "paired_host_key_not_found", "fleet_legacy_repair_required": return "找不到配對時記下的主設備金鑰，需要重新配對"
        case "pairing_identity_changed": return "主設備的配對資料變了，要重新配對"
        case "primary_memory_moved": return "主設備的記憶資料夾換了位置，下一輪重來"
        case "branch_push_failed": return "送到主設備沒成功"
        case "fetch_failed": return "拉不到主設備的記憶"
        default: break
        }
        if text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            if case .memory = context, text.count > 60 { return String(text.prefix(60)) + "…" }
            return text
        }
        switch context {
        case .transfer(let record, _): return record == nil ? "移交沒有開始，請重新檢查" + device + "後再試。" : "這一步沒有完成，請按重新檢查後再試。"
        case .memory: return "原因不明"
        case .operation: return "沒有完成，請按重新檢查再試；一直失敗，請在私訊框請 TATWO 助理檢查。"
        }
    }
}

/// One visible, single-line rule for pairing, signed membership and assistant input.
enum DeviceFleetName {
    static let maximumBytes = 160
    static func clean(_ value: String) -> String {
        let scalars = value.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: return false
            default: return !$0.properties.isDefaultIgnorableCodePoint
            }
        }
        let visible = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = ""
        for character in visible {
            guard result.utf8.count + String(character).utf8.count <= maximumBytes else { break }
            result.append(character)
        }
        return result
    }
    static func unique(_ value: String, used: [String]) -> String {
        let base = clean(value)
        guard !base.isEmpty else { return "" }
        let names = Set(used.map { $0.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) })
        func occupied(_ text: String) -> Bool { names.contains(text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))) }
        if !occupied(base) { return base }
        for index in 2...514 {
            let suffix = " (\(index))"
            var prefix = base
            while prefix.utf8.count + suffix.utf8.count > maximumBytes { prefix.removeLast() }
            if !occupied(prefix + suffix) { return prefix + suffix }
        }
        return ""
    }
    static func shortFingerprint(_ value: String?) -> String {
        guard let value else { return "未確認" }
        return String((value.hasPrefix("SHA256:") ? String(value.dropFirst(7)) : value).prefix(8))
    }
    static func label(_ group: DeviceFleetGroup) -> String { group.name }
    static func label(_ record: DeviceRecord) -> String {
        let role = record.role?.rawValue == "primary" ? "主設備" : "副設備"
        return "\(clean(record.name))〔\(role) · \(shortFingerprint(record.clientKeyFingerprint ?? record.hostKeyFingerprint))〕"
    }
    static func label(_ member: DeviceFleetMember, groups: [DeviceFleetGroup]) -> String {
        let group = groups.first { $0.id == member.groupID }
        let role = group?.type == .sub ? (member.role == .primary ? "SUB 主設備（指定）" : "職員電腦")
            : member.role == .sandbox ? "沙盒設備" : member.role == .primary ? "我的主設備" : "我的副設備"
        return "\(member.name)〔\(group?.name ?? member.groupID) · \(group?.type.rawValue ?? "群組") · \(role) · \(shortFingerprint(member.clientKeyFingerprint))〕"
    }
    static func label(_ member: DeviceFleetMember) -> String {
        let role: String = switch member.role {
        case .primary: "主設備"
        case .secondary: "副設備"
        case .managed: "受管設備"
        case .sandbox: "沙盒設備"
        }
        return "\(member.name)〔\(role) · \(shortFingerprint(member.clientKeyFingerprint))〕"
    }
}

enum DeviceFleetDefaults {
    static let firstManagedDeviceIsPrimary = false
    static let staffPeerCapabilities: [String] = []
    static let staffRoleExplanation = "SUB 主設備由你的主設備指定，只是角色標記；未指定前沒有 SUB 主設備。職員電腦只接受管理者的設備控制，彼此暫不互聯。"
    static let staffInterconnectionMessage = "職員電腦之間的互聯暫不開放"
}

/// Opt-in MAIN display has no routing or cryptographic fields, even in its encoded form.
struct DeviceFleetPrimaryDisplay: Codable, Equatable, Sendable {
    var name: String
    var role: DeviceFleetRole = .primary
    init(_ member: DeviceFleetMember) { name = member.name }
}

enum DeviceFactionKind: String, Codable, Sendable { case owner, managed, sandbox }
enum DeviceFleetRole: String, Codable, Sendable { case primary, secondary, managed, sandbox }

struct DeviceFaction: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: DeviceFactionKind
    var managerDisplayName: String
    var showPrimaryToMembers: Bool = false
    enum CodingKeys: String, CodingKey { case id, name, kind, managerDisplayName, showPrimaryToMembers }
    init(id: String, name: String, kind: DeviceFactionKind, managerDisplayName: String,
         showPrimaryToMembers: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.managerDisplayName = managerDisplayName
        self.showPrimaryToMembers = showPrimaryToMembers
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  kind: try c.decode(DeviceFactionKind.self, forKey: .kind),
                  managerDisplayName: try c.decode(String.self, forKey: .managerDisplayName),
                  showPrimaryToMembers: try c.decodeIfPresent(Bool.self, forKey: .showPrimaryToMembers) ?? false)
    }
}

struct SandboxDeviceInfo: Codable, Equatable, Sendable {
    var platform: String
    var virtual: Bool
    var source: String
    var label: String { virtual ? "內建虛擬機（\(source)）" : "別人的設備（\(source)）" }
    var valid: Bool { ["Linux", "macOS"].contains(platform) && !source.isEmpty && source == DeviceFleetName.clean(source) && source.utf8.count <= DeviceFleetName.maximumBytes }
}
struct DeviceFleetMember: Codable, Equatable, Sendable {
    var sandboxInfo: SandboxDeviceInfo? = nil
    var id: String
    var name: String
    var factionID: String
    var role: DeviceFleetRole
    var clientKeyFingerprint: String?
    var hostKeyFingerprint: String?
    var clientPublicKey: String?
    var hostPublicKey: String?
    var endpoints: [DeviceEndpoint]
    var user: String
    /// 沒有名單協定的既有配對只保留原授權，不推測缺失的另一把金鑰。
    var legacy: Bool = false
    /// SUB colleague display metadata carries no account, endpoints or public keys.
    var displayOnly: Bool = false
    var groupID: String {
        get { factionID }
        set { factionID = newValue }
    }
    enum CodingKeys: String, CodingKey {
        case id, name, groupID, factionID, role, clientKeyFingerprint, hostKeyFingerprint
        case clientPublicKey, hostPublicKey, endpoints, user, legacy, displayOnly, sandboxInfo
    }
    init(id: String, name: String, factionID: String, role: DeviceFleetRole,
         clientKeyFingerprint: String?, hostKeyFingerprint: String?,
         clientPublicKey: String?, hostPublicKey: String?, endpoints: [DeviceEndpoint],
         user: String, legacy: Bool = false) {
        self.id = id; self.name = name; self.factionID = factionID; self.role = role
        self.clientKeyFingerprint = clientKeyFingerprint; self.hostKeyFingerprint = hostKeyFingerprint
        self.clientPublicKey = clientPublicKey.map(DeviceFleetPublicKey.withoutComment)
        self.hostPublicKey = hostPublicKey.map(DeviceFleetPublicKey.withoutComment)
        self.endpoints = endpoints; self.user = user; self.legacy = legacy
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  factionID: try c.decodeIfPresent(String.self, forKey: .groupID) ?? c.decode(String.self, forKey: .factionID),
                  role: try c.decode(DeviceFleetRole.self, forKey: .role),
                  clientKeyFingerprint: try c.decodeIfPresent(String.self, forKey: .clientKeyFingerprint),
                  hostKeyFingerprint: try c.decodeIfPresent(String.self, forKey: .hostKeyFingerprint),
                  clientPublicKey: try c.decodeIfPresent(String.self, forKey: .clientPublicKey),
                  hostPublicKey: try c.decodeIfPresent(String.self, forKey: .hostPublicKey),
                  endpoints: try c.decodeIfPresent([DeviceEndpoint].self, forKey: .endpoints) ?? [],
                  user: try c.decodeIfPresent(String.self, forKey: .user) ?? "",
                  legacy: try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? false)
        displayOnly = try c.decodeIfPresent(Bool.self, forKey: .displayOnly) ?? false
        sandboxInfo = try c.decodeIfPresent(SandboxDeviceInfo.self, forKey: .sandboxInfo)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(groupID, forKey: .groupID)
        try c.encode(role == .managed ? .secondary : role, forKey: .role)
        try c.encodeIfPresent(sandboxInfo, forKey: .sandboxInfo)
        try c.encodeIfPresent(clientKeyFingerprint, forKey: .clientKeyFingerprint)
        try c.encodeIfPresent(hostKeyFingerprint, forKey: .hostKeyFingerprint)
        if displayOnly { try c.encode(true, forKey: .displayOnly); return }
        try c.encodeIfPresent(clientPublicKey, forKey: .clientPublicKey)
        try c.encodeIfPresent(hostPublicKey, forKey: .hostPublicKey)
        try c.encode(endpoints, forKey: .endpoints); try c.encode(user, forKey: .user); try c.encode(legacy, forKey: .legacy)
    }

    func validate() throws {
        if displayOnly {
            guard UUID(uuidString: id) != nil, !name.isEmpty, !factionID.isEmpty,
                  name == DeviceFleetName.clean(name), name.utf8.count <= DeviceFleetName.maximumBytes,
                  endpoints.isEmpty, user.isEmpty, clientPublicKey == nil, hostPublicKey == nil else { throw DeviceFleetError.malformed }
            return
        }
        guard UUID(uuidString: id) != nil, !name.isEmpty, !factionID.isEmpty,
              DevicePairingAuth.isSafeSSHUser(user), endpoints.allSatisfy(\.isValid),
              endpoints.count <= 16, name == DeviceFleetName.clean(name), name.utf8.count <= DeviceFleetName.maximumBytes else { throw DeviceFleetError.malformed }
        if let sandboxInfo {
            guard role == .sandbox, sandboxInfo.valid, endpoints.isEmpty, clientPublicKey == nil, hostPublicKey == nil,
                  clientKeyFingerprint == nil, hostKeyFingerprint == nil, !legacy else { throw DeviceFleetError.malformed }
            return // B 種只連出，沒有 SSH 金鑰或反向設備入口。
        }
        for (key, fingerprint) in [(clientPublicKey, clientKeyFingerprint), (hostPublicKey, hostKeyFingerprint)] {
            if let key {
                guard key.utf8.count <= 2048, try DeviceRegistry.fingerprint(publicKey: key) == fingerprint else {
                    throw DeviceFleetError.keyConflict
                }
            } else if !legacy { throw DeviceFleetError.missingKey }
        }
    }
}

struct DeviceFleetDisconnectAll: Codable, Equatable, Sendable {
    var id: String
    var revision: UInt64
    var targets: [String]
}
struct DeviceFleetRoster: Codable, Equatable, Sendable {
    var version: UInt64
    var primaryID: String
    var epoch: Int
    var groups: [DeviceFleetGroup]
    var edges: [DeviceFleetEdge]
    var factions: [DeviceFaction] { groups.map(\.faction) }
    var devices: [DeviceFleetMember]
    var revoked: [String]
    var rePairVersions: [String: UInt64]? = nil
    var rotationHistory: [String: [DeviceFleetEnvelope]]? = nil
    var disconnectAll: DeviceFleetDisconnectAll? = nil
    enum CodingKeys: String, CodingKey { case version, primaryID, epoch, groups, edges, factions, devices, revoked, rePairVersions, rotationHistory, disconnectAll }
    init(version: UInt64, primaryID: String, epoch: Int, factions: [DeviceFaction],
         devices: [DeviceFleetMember], revoked: [String]) {
        self.version = version; self.primaryID = primaryID; self.epoch = epoch
        var migrated = devices
        let graph = Self.migrate(factions: factions, devices: &migrated, primaryID: primaryID)
        groups = graph.groups; edges = graph.edges; self.devices = migrated; self.revoked = revoked
    }
    init(version: UInt64, primaryID: String, epoch: Int, groups: [DeviceFleetGroup],
         devices: [DeviceFleetMember], edges: [DeviceFleetEdge], revoked: [String] = []) {
        self.version = version; self.primaryID = primaryID; self.epoch = epoch
        self.groups = groups; self.devices = devices; self.edges = edges; self.revoked = revoked
    }
    init(from decoder: Decoder) throws {
        groups = []; edges = []
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(UInt64.self, forKey: .version); primaryID = try c.decode(String.self, forKey: .primaryID)
        epoch = try c.decode(Int.self, forKey: .epoch); devices = try c.decode([DeviceFleetMember].self, forKey: .devices)
        revoked = try c.decode([String].self, forKey: .revoked)
        rePairVersions = try c.decodeIfPresent([String: UInt64].self, forKey: .rePairVersions)
        rotationHistory = try c.decodeIfPresent([String: [DeviceFleetEnvelope]].self, forKey: .rotationHistory)
        disconnectAll = try c.decodeIfPresent(DeviceFleetDisconnectAll.self, forKey: .disconnectAll)
        if c.contains(.groups) {
            groups = try c.decode([DeviceFleetGroup].self, forKey: .groups)
            edges = try c.decode([DeviceFleetEdge].self, forKey: .edges)
        } else {
            let factions = try c.decode([DeviceFaction].self, forKey: .factions)
            // Validate the legacy authority before migration; do not "repair" a malicious v1 role.
            guard factions.count <= 64, Set(factions.map(\.id)).count == factions.count,
                  factions.filter({ $0.kind == .owner }).count == 1,
                  devices.filter({ $0.role == .primary && !revoked.contains($0.id) }).map(\.id) == [primaryID],
                  devices.allSatisfy({ row in
                      guard let faction = factions.first(where: { $0.id == row.factionID }) else { return false }
                      return faction.kind == .owner ? [.primary, .secondary].contains(row.role)
                          : (row.role == (faction.kind == .managed ? .managed : .sandbox))
                  }) else { throw DeviceFleetError.role }
            let graph = Self.migrate(factions: factions, devices: &devices, primaryID: primaryID)
            groups = graph.groups; edges = graph.edges
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(primaryID, forKey: .primaryID); try c.encode(epoch, forKey: .epoch)
        try c.encode(groups, forKey: .groups); try c.encode(edges, forKey: .edges)
        try c.encode(devices, forKey: .devices); try c.encode(revoked, forKey: .revoked)
        try c.encodeIfPresent(rePairVersions, forKey: .rePairVersions)
        try c.encodeIfPresent(rotationHistory, forKey: .rotationHistory)
        try c.encodeIfPresent(disconnectAll, forKey: .disconnectAll)
    }

    func kind(of id: String) -> DeviceFactionKind? {
        guard !revoked.contains(id), let member = devices.first(where: { $0.id == id }) else { return nil }
        if member.role == .sandbox { return .sandbox }
        return factions.first { $0.id == member.factionID }?.kind
    }

    func validate() throws {
        guard version > 0, epoch >= 0, devices.count <= 512, factions.count <= 64,
              Set(devices.map(\.id)).count == devices.count,
              Set(factions.map(\.id)).count == factions.count,
              Set(revoked).count == revoked.count, revoked.allSatisfy({ UUID(uuidString: $0) != nil }),
              factions.filter({ $0.kind == .owner }).count == 1,
              kind(of: primaryID) == .owner else { throw DeviceFleetError.malformed }
        guard (rePairVersions ?? [:]).count <= 512,
              (rePairVersions ?? [:]).allSatisfy({ fp, revision in
                  revision > 0 && revision <= version && devices.contains { $0.clientKeyFingerprint == fp }
              }), (rotationHistory ?? [:]).count <= 512,
              (rotationHistory ?? [:]).allSatisfy({ id, entries in
                  devices.contains { $0.id == id && $0.id != primaryID } && entries.count <= 16
              }) else { throw DeviceFleetError.malformed }
        if let event = disconnectAll {
            guard UUID(uuidString: event.id) != nil, event.revision > 0, event.revision <= version,
                  event.targets.count <= 128, Set(event.targets).count == event.targets.count,
                  event.targets.allSatisfy({ id in devices.contains { row in
                      row.id == id && groups.first(where: { $0.id == row.groupID })?.type == .main && row.role != .sandbox
                  } }) else { throw DeviceFleetError.malformed }
        }
        for group in groups {
            guard !group.name.isEmpty, group.name == DeviceFleetName.clean(group.name),
                  group.managerDisplayName == DeviceFleetName.clean(group.managerDisplayName) else { throw DeviceFleetError.malformed }
            let names = devices.filter { $0.groupID == group.id }.map { $0.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
            guard Set(names).count == names.count else { throw DeviceFleetError.malformed }
        }
        try validateGraph()
        var clientKeys = Set<String>(), hostKeys = Set<String>()
        for member in devices {
            try member.validate()
            guard !member.displayOnly else { throw DeviceFleetError.malformed }
            guard let faction = factions.first(where: { $0.id == member.factionID }),
                  ([.owner, .managed].contains(faction.kind) && [.primary, .secondary, .sandbox].contains(member.role)) else {
                throw DeviceFleetError.role
            }
            if let key = member.clientKeyFingerprint, !revoked.contains(member.id), !clientKeys.insert(key).inserted { throw DeviceFleetError.keyConflict }
            if let key = member.hostKeyFingerprint, !revoked.contains(member.id), !hostKeys.insert(key).inserted { throw DeviceFleetError.keyConflict }
        }
    }

    /// Cached signatures from earlier releases retain their original per-group rule.
    /// Every newly issued/accepted roster must use fleet-wide unique display names.
    func validateUniqueNames() throws {
        for names in [devices.map(\.name), groups.map(\.name)] {
            let folded = names.map { $0.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
            guard Set(folded).count == names.count else { throw DeviceFleetError.malformed }
        }
    }
    func kindForRestoration(_ member: DeviceFleetMember) -> DeviceFactionKind {
        if member.role == .sandbox { return .sandbox }
        return groups.first { $0.id == member.groupID }?.type == .main ? .owner : .managed
    }
    mutating func normalizeNames() {
        var names: [String] = []
        for index in groups.indices {
            groups[index].name = DeviceFleetName.unique(groups[index].name, used: names)
            names.append(groups[index].name)
        }
        names = []
        for index in devices.indices {
            devices[index].name = DeviceFleetName.unique(devices[index].name, used: names)
            names.append(devices[index].name)
        }
    }

    func slice(for id: String) throws -> DeviceFleetSlice {
        guard let member = devices.first(where: { $0.id == id }),
              let group = groups.first(where: { $0.id == member.groupID }), kind(of: id) != .owner else {
            throw DeviceFleetError.role
        }
        var faction = group.faction
        if member.role == .sandbox { faction.kind = .sandbox; faction.showPrimaryToMembers = false }
        let removed = revoked.contains(id)
        // 控制者只有公開客戶端金鑰與指紋，沒有設備 ID、主機金鑰、地址、名字或角色。
        let controllers = removed ? [] : try incoming(to: id)
        let visible = devices.filter {
            !revoked.contains($0.id) && (member.role == .sandbox ? $0.id == id : $0.groupID == member.groupID && $0.role != .sandbox)
        }.map { row -> DeviceFleetMember in
            guard row.id != id else { return row }
            var display = row
            display.displayOnly = true; display.endpoints = []; display.user = ""
            display.clientPublicKey = nil; display.hostPublicKey = nil
            return display
        }
        let visibleIDs = Set(visible.map(\.id))
        var localEdges = edges.filter {
            $0.from.kind == .device && $0.to.kind == .device
                && visibleIDs.contains($0.from.id) && visibleIDs.contains($0.to.id) && !isStaffInterconnection($0)
        }
        for controller in controllers where !visible.contains(where: { $0.clientKeyFingerprint == controller.clientKeyFingerprint }) {
            let source = DeviceFleetEndpoint.device(DeviceFleetStore.controllerID(controller.clientKeyFingerprint))
            localEdges.append(.init(from: source, to: .device(id), direction: .oneway,
                                    capabilities: controller.capabilities))
            localEdges.append(.init(from: .device(id), to: source, direction: .none, capabilities: [], locked: true))
        }
        return .init(revision: version, epoch: epoch, targetID: id, faction: faction,
                     devices: visible,
                     controllers: controllers, revoked: removed,
                     primary: faction.showPrimaryToMembers ? devices.first { $0.id == primaryID }.map(DeviceFleetPrimaryDisplay.init) : nil,
                     group: member.role == .sandbox ? nil : group, edges: localEdges,
                     revokedKeys: devices.filter { row in revoked.contains(row.id) && !devices.contains(where: {
                        !revoked.contains($0.id) && $0.clientKeyFingerprint == row.clientKeyFingerprint
                     }) }.compactMap(\.clientKeyFingerprint),
                     rePairVersions: rePairVersions?.filter { fp, _ in
                         fp == member.clientKeyFingerprint || controllers.contains { $0.clientKeyFingerprint == fp }
                     })
    }
}

struct DeviceFleetController: Codable, Equatable, Sendable {
    var clientKeyFingerprint: String
    var clientPublicKey: String
    var capabilities: [String] = DeviceFleetCapabilities.all
    enum CodingKeys: String, CodingKey { case clientKeyFingerprint, clientPublicKey, capabilities }
    init(clientKeyFingerprint: String, clientPublicKey: String, capabilities: [String] = DeviceFleetCapabilities.all) {
        self.clientKeyFingerprint = clientKeyFingerprint
        self.clientPublicKey = DeviceFleetPublicKey.withoutComment(clientPublicKey); self.capabilities = capabilities
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(clientKeyFingerprint: try c.decode(String.self, forKey: .clientKeyFingerprint),
                  clientPublicKey: try c.decode(String.self, forKey: .clientPublicKey),
                  capabilities: try c.decodeIfPresent([String].self, forKey: .capabilities) ?? DeviceFleetCapabilities.all)
    }
}

/// revision 是這份投影的防重放序號；沒有正本 version／primaryID 或主設備 App 版本。
struct DeviceFleetSlice: Codable, Equatable, Sendable {
    var revision: UInt64
    var epoch: Int
    var targetID: String
    var faction: DeviceFaction
    var devices: [DeviceFleetMember]
    var controllers: [DeviceFleetController]
    var revoked: Bool
    var primary: DeviceFleetPrimaryDisplay?
    var group: DeviceFleetGroup? = nil
    var edges: [DeviceFleetEdge]? = nil
    var revokedKeys: [String]? = nil
    var rePairVersions: [String: UInt64]? = nil

    func upgraded(legacy: Bool = false) throws -> Self {
        var result = self
        if legacy || (group == nil && faction.kind == .managed) {
            let allowed = faction.kind == .sandbox ? DeviceFleetCapabilities.sandbox : DeviceFleetCapabilities.managed
            for index in result.controllers.indices {
                result.controllers[index].capabilities = result.controllers[index].capabilities.filter(allowed.contains)
            }
        }
        if group == nil && faction.kind == .managed {
            result.group = .init(id: faction.id, name: faction.name, type: .sub, primaryDeviceID: "",
                showMainPrimary: faction.showPrimaryToMembers, managerDisplayName: faction.managerDisplayName)
            for index in result.devices.indices {
                result.devices[index].role = .secondary
            }
            result.edges = []
        }
        try result.validate()
        return result
    }

    func validate() throws {
        guard revision > 0, faction.kind != .owner, devices.count <= 512, controllers.count <= 512,
              Set(devices.map(\.id)).count == devices.count,
              devices.allSatisfy({ $0.factionID == faction.id
                  && (faction.kind == .sandbox ? $0.role == .sandbox : [.primary, .secondary, .managed].contains($0.role)) }),
              revoked || devices.contains(where: { $0.id == targetID }),
              !revoked || controllers.isEmpty,
              faction.showPrimaryToMembers || primary == nil else { throw DeviceFleetError.role }
        guard (rePairVersions ?? [:]).count <= 512,
              (rePairVersions ?? [:]).allSatisfy({ fp, generation in
                  generation > 0 && generation <= revision && (devices.contains { $0.clientKeyFingerprint == fp }
                      || controllers.contains { $0.clientKeyFingerprint == fp })
              }) else { throw DeviceFleetError.malformed }
        for row in devices {
            try row.validate()
            guard row.id != targetID || !row.displayOnly else { throw DeviceFleetError.malformed }
        }
        if let primary { guard primary.role == .primary, !primary.name.isEmpty, primary.name == DeviceFleetName.clean(primary.name) else { throw DeviceFleetError.role } }
        guard Set(controllers.map(\.clientKeyFingerprint)).count == controllers.count else { throw DeviceFleetError.keyConflict }
        for controller in controllers {
            guard try DeviceRegistry.fingerprint(publicKey: controller.clientPublicKey) == controller.clientKeyFingerprint,
                  DeviceFleetCapabilities.valid(controller.capabilities),
                  !devices.contains(where: { $0.id == targetID && $0.clientKeyFingerprint == controller.clientKeyFingerprint }) else {
                throw DeviceFleetError.keyConflict
            }
        }
        if let group {
            guard faction.kind == .managed, group.type == .sub, group.id == faction.id,
                  group.showMainPrimary == faction.showPrimaryToMembers,
                  !devices.contains(where: { $0.id == group.primaryDeviceID && $0.role != .primary }) else {
                throw DeviceFleetError.role
            }
        }
        for edge in edges ?? [] {
            let anonymous = Set(controllers.map { DeviceFleetStore.controllerID($0.clientKeyFingerprint) })
            let visible = Set(devices.map(\.id)).union(anonymous)
            guard edge.from.kind == .device, edge.to.kind == .device,
                  visible.contains(edge.from.id), visible.contains(edge.to.id), edge.from != edge.to,
                  DeviceFleetCapabilities.valid(edge.capabilities),
                  edge.direction != .none || edge.capabilities.isEmpty,
                  !anonymous.contains(edge.to.id) || edge.direction == .none,
                  !anonymous.contains(edge.from.id) || edge.direction == .oneway else { throw DeviceFleetError.role }
        }
    }
}

struct DeviceFleetRevocationNotice: Codable, Equatable, Sendable {
    var targetID: String
    var revision: UInt64
    var epoch: Int
}

struct DeviceFleetPayload: Codable, Equatable, Sendable {
    var schema: String = "tatwo.device-fleet.v2"
    var roster: DeviceFleetRoster?
    var slice: DeviceFleetSlice?
    var revocationNotice: DeviceFleetRevocationNotice? = nil
    var revision: UInt64 { roster?.version ?? slice?.revision ?? revocationNotice?.revision ?? 0 }
    var epoch: Int { roster?.epoch ?? slice?.epoch ?? revocationNotice?.epoch ?? -1 }
    var rotationDigest: String? = nil
}

struct DeviceFleetEnvelope: Codable, Equatable, Sendable {
    var body: Data
    var signature: Data
    var publicKey: String
    var handoff: DeviceFleetHandoff? = nil
    var rotationCommit: DeviceFleetRotationCommit? = nil
    static let namespace = "tatwo2-device-fleet"
    private static let signatureLock = NSLock()
    nonisolated(unsafe) private static var verifiedSignatures: [DeviceFleetEnvelope] = []

    static func issue(_ payload: DeviceFleetPayload, environment: [String: String]) throws -> Self {
        var payload = payload
        if var roster = payload.roster {
            roster.removeStaffInterconnections()
            payload.roster = roster
        }
        if var slice = payload.slice, slice.faction.kind == .managed {
            let peers = Set(slice.devices.compactMap(\.clientKeyFingerprint))
            slice.controllers.removeAll { peers.contains($0.clientKeyFingerprint) }
            let peerIDs = Set(slice.devices.map(\.id))
            slice.edges?.removeAll { peerIDs.contains($0.from.id) && peerIDs.contains($0.to.id) }
            payload.slice = slice
        }
        if let roster = payload.roster { try roster.validate(); try roster.validateUniqueNames() }
        if let slice = payload.slice { try slice.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var v2 = payload; v2.schema = "tatwo.device-fleet.v2"
        v2.slice = try payload.slice?.upgraded(legacy: payload.schema == "tatwo.device-fleet.v1")
        let body = try encoder.encode(v2)
        let (signature, publicKey) = try DeviceSignature.sign(body, namespace: namespace, environment: environment)
        if let roster = payload.roster,
           try DeviceRegistry.fingerprint(publicKey: publicKey) != roster.devices.first(where: { $0.id == roster.primaryID })?.clientKeyFingerprint {
            throw DeviceFleetError.signer
        }
        return .init(body: body, signature: signature, publicKey: DeviceFleetPublicKey.withoutComment(publicKey))
    }

    #if DEBUG
    static var fixtureVerification: (() -> Void)?
    #endif
    func verified(trust: DeviceFleetTrust) throws -> DeviceFleetPayload {
        #if DEBUG
        Self.fixtureVerification?()
        #endif
        guard body.count <= 2 * 1024 * 1024, signature.count < 8192, publicKey.utf8.count <= 2048,
              try DeviceRegistry.fingerprint(publicKey: publicKey) == trust.pinnedPrimaryKey else {
            throw DeviceFleetError.signer
        }
        if !Self.signatureLock.withLock({ Self.verifiedSignatures.contains(self) }) {
            guard DeviceSignature.verify(body: body, signature: signature, publicKey: publicKey, namespace: Self.namespace) else {
                throw DeviceFleetError.signature
            }
            Self.signatureLock.withLock {
                Self.verifiedSignatures.append(self)
                if Self.verifiedSignatures.count > 8 { Self.verifiedSignatures.removeFirst() }
            }
        }
        let payload: DeviceFleetPayload
        do { payload = try JSONDecoder().decode(DeviceFleetPayload.self, from: body) }
        catch is DecodingError { throw DeviceFleetError.projectionUnsupported }
        guard ["tatwo.device-fleet.v1", "tatwo.device-fleet.v2"].contains(payload.schema) else { throw DeviceFleetError.projectionUnsupported }
        guard [payload.roster != nil, payload.slice != nil, payload.revocationNotice != nil].filter { $0 }.count == 1 else {
            throw DeviceFleetError.malformed
        }
        if payload.schema == "tatwo.device-fleet.v2" {
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw DeviceFleetError.malformed
            }
            if let roster = object["roster"] as? [String: Any] {
                guard roster["groups"] is [[String: Any]], roster["edges"] is [[String: Any]],
                      let devices = roster["devices"] as? [[String: Any]],
                      devices.allSatisfy({ $0["groupID"] is String && ["primary", "secondary", "sandbox"].contains($0["role"] as? String ?? "") }) else {
                    throw DeviceFleetError.malformed
                }
            }
            if let slice = object["slice"] as? [String: Any] {
                guard let controllers = slice["controllers"] as? [[String: Any]],
                      controllers.allSatisfy({ $0["capabilities"] is [String] }),
                      let devices = slice["devices"] as? [[String: Any]],
                      devices.allSatisfy({ $0["groupID"] is String && ["primary", "secondary", "sandbox"].contains($0["role"] as? String ?? "") }),
                      payload.slice?.faction.kind != .managed || (slice["group"] is [String: Any] && slice["edges"] is [[String: Any]]) else {
                    throw DeviceFleetError.malformed
                }
            }
        }
        if let notice = payload.revocationNotice {
            guard notice.targetID == trust.localID, notice.revision > 0 else { throw DeviceFleetError.role }
        }
        guard payload.epoch == trust.epoch else { throw DeviceFleetError.epoch }
        if let roster = payload.roster {
            try roster.validate()
            guard trust.kind == .owner, roster.primaryID == trust.primaryID else { throw DeviceFleetError.foreignFleet }
            guard roster.devices.first(where: { $0.id == trust.primaryID })?.clientKeyFingerprint == trust.pinnedPrimaryKey else {
                throw DeviceFleetError.signer
            }
            guard roster.kind(of: trust.localID) == .owner || roster.revoked.contains(trust.localID) else {
                throw DeviceFleetError.role
            }
            if trust.localID == trust.primaryID {
                guard roster.devices.first(where: { $0.id == trust.localID })?.role == .primary else { throw DeviceFleetError.role }
            } else if let member = roster.devices.first(where: { $0.id == trust.localID }) {
                guard member.role == .secondary else { throw DeviceFleetError.role }
            }
        } else if let slice = payload.slice {
            try slice.validate()
            guard slice.targetID == trust.localID, slice.faction.kind == trust.kind else { throw DeviceFleetError.role }
        }
        var normalized = payload; normalized.schema = "tatwo.device-fleet.v2"
        normalized.slice = try payload.slice?.upgraded(legacy: payload.schema == "tatwo.device-fleet.v1")
        return normalized
    }
}

struct DeviceFleetTrust: Codable, Equatable, Sendable {
    var localID: String
    var primaryID: String
    var epoch: Int
    var pinnedPrimaryKey: String
    var kind: DeviceFactionKind
}

enum DeviceFleetError: String, Error, LocalizedError {
    case malformed, missingKey, keyConflict, signer, signature, epoch, replay, role, foreignFleet
    case managedLocked, consentRequired, primaryRequired, unknownMember, reverseEnrollment, confirmationRequired
    case projectionUnsupported = "projection_unsupported", localStorageFailed = "local_storage_failed"
    case transferNotReady, staffPeersUnavailable, previewNotAllowed
    case reverseEdge, subAuthority, lockedEdge, staleProposal, capabilityDenied
    var errorDescription: String? { DeviceFleetReason.plain(self) }
    var reason: String {
        if self == .projectionUnsupported || self == .localStorageFailed { return rawValue }
        if self == .staffPeersUnavailable { return DeviceFleetDefaults.staffInterconnectionMessage }
        if self == .transferNotReady {
            return "fleet_transferNotReady"
        }
        return "fleet_\(rawValue)"
    }
}

/// 只由呼叫端傳入已經過 HMAC 的配對資料；不提供未驗證網路內容的 TOFU 入口。
struct DeviceFleetPairOffer: Codable, Equatable, Sendable {
    var member: DeviceFleetMember
    var trust: DeviceFleetTrust
    var envelope: DeviceFleetEnvelope?
    var faction: DeviceFaction
}

struct DeviceFleetPairRequest: Codable, Sendable {
    var hostPublicKey: String
    var kind: DeviceFactionKind
    var consent: Bool
    var previewOnly: Bool? = nil
    var previewDigest: String? = nil
}

/// W83 的簽章守門，不改其檢查點或移交狀態機。
struct DeviceFleetTransferProof: Codable, Sendable {
    var body: Data
    var signature: Data
    var publicKey: String
    static let namespace = "tatwo2-primary-transfer"
    static func bytes(_ record: PrimaryTransferState.Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }
    static func issue(_ record: PrimaryTransferState.Record, environment: [String: String]) throws -> Self {
        let body = try bytes(record)
        let (signature, publicKey) = try DeviceSignature.sign(body, namespace: namespace, environment: environment)
        return .init(body: body, signature: signature, publicKey: publicKey)
    }
}

/// 檔案都在既有 live root；公鑰不是秘密。簽過的信封才是名單真值。
final class DeviceFleetStore: @unchecked Sendable {
    #if DEBUG
    var fixtureDeliveryFailures = Set<String>()
    #endif
    struct State: Codable {
        var trust: DeviceFleetTrust?
        var envelope: DeviceFleetEnvelope?
        var pending: [DeviceFleetMember] = []
        var confirmations: [String] = []
        var leaving: Bool = false
        var managedRemoved: [String] = []
        var leaveRequests: [String] = []
        var controllerHistory: [String] = []
        var deliveries: [String: DeviceFleetEnvelope]? = nil
        var draftFactions: [DeviceFaction]? = nil
        var rotation: DeviceFleetRotation? = nil
        var revokedKeys: [String]? = nil
        var revokedAt: [String: UInt64]? = nil
        var deliveredHistory: [String: [String]]? = nil
        var pinConflicts: [String]? = nil
        var possiblyConnected: [String]? = nil
        var possiblyConnectedDevices: [String: UInt64]? = nil
        var revocationDeliveries: [String: RevocationAttempt]? = nil
        var pendingRepin: [String]? = nil
        var revocationSweeps: [String: RevocationAttempt]? = nil
        var revocationSweepGenerations: [String: UInt64]? = nil
        // Local only: never copied into a signed roster or received from another device.
        var consentCeiling: [String: [String]]? = nil
        var transferContacts: [String: TransferContact]? = nil
        var consumedDisconnectAll: [String]? = nil
        var deliveryProblems: [String: String]? = nil
        var pendingKeyRemoval: [String: KeyRemoval]? = nil
    }
    struct KeyRemoval: Codable { var deviceID: String; var lines: [Int] }
    struct TransferContact: Codable {
        var firstFailure: Date?
        var lastFailure: Date?
        var lastSuccess: Date?
        var failures = 0
    }
    func noteTransferContact(transfer: String, peer: String, reached: Bool, now: Date = Date()) throws {
        try Self.lock.withLock {
            var state = try read(), contacts = state.transferContacts ?? [:]
            let key = transfer + ":" + peer
            var contact = contacts[key] ?? .init()
            if reached { contact.lastSuccess = now; contact.firstFailure = nil; contact.failures = 0 }
            else { contact.firstFailure = contact.firstFailure ?? now; contact.lastFailure = now; contact.failures += 1 }
            contacts[key] = contact; state.transferContacts = contacts; try save(state)
        }
    }
    struct RevocationAttempt: Codable { var attempts: Int; var first: Date; var delivered: Bool; var nextAttempt: Date? = nil; var stopped: Bool? = nil }
    func claimRevocationDelivery(_ id: String, now: Date = Date()) throws -> Bool {
        try Self.lock.withLock {
            if let roster = try current()?.roster, roster.revoked.contains(id), !roster.canRestore(id) { return false }
            var state = try read()
            var rows = state.revocationDeliveries ?? [:]
            var row = rows[id] ?? .init(attempts: 0, first: now, delivered: false)
            guard !row.delivered, row.stopped != true, now >= (row.nextAttempt ?? .distantPast) else { return false }
            row.attempts = min(row.attempts, 30) + 1
            row.nextAttempt = now.addingTimeInterval(min(600, 10 * pow(2, Double(min(row.attempts, 6)))))
            rows[id] = row; state.revocationDeliveries = rows
            try save(state); return true
        }
    }
    func claimRevocationSweep(_ id: String, now: Date = Date(), revokeIdentity: Bool = true) throws -> Bool {
        try Self.lock.withLock {
            let sweepRevision = try current()?.revision ?? 0
            var state = try read(), rows = state.revocationSweeps ?? [:]
            let generation: UInt64
            if revokeIdentity {
                var generations = state.revocationSweepGenerations ?? [:]
                generation = generations[id] ?? sweepRevision; generations[id] = generation
                state.revocationSweepGenerations = generations
            } else { generation = sweepRevision }
            let sweepKey = id + ":" + String(generation) + (revokeIdentity ? ":revoke" : ":narrow")
            var row = rows[sweepKey] ?? .init(attempts: 0, first: now, delivered: false)
            guard row.attempts < 3, now.timeIntervalSince(row.first) < 60 else { return false }
            row.attempts += 1; rows[sweepKey] = row
            let expired = rows.filter { $0.key.hasSuffix(":narrow") }.sorted { $0.value.first < $1.value.first }
            for stale in expired.prefix(max(0, expired.count - 2048)) { rows[stale.key] = nil }
            state.revocationSweeps = rows; try save(state); return true
        }
    }
    func finishRevocationDelivery(_ id: String) throws {
        try Self.lock.withLock {
            var state = try read(); state.revocationDeliveries?[id]?.delivered = true; state.deliveryProblems?[id] = nil; try save(state)
        }
    }
    func rememberRevokedKeys(_ keys: [String], removeManual: Bool = false) throws {
        var state = try read(); let fresh = Set(keys).subtracting(state.revokedKeys ?? [])
        state.revokedKeys = Array(Set((state.revokedKeys ?? []) + keys))
        if !removeManual { state.pendingKeyRemoval = [:] }
        var fence = state.revokedAt ?? [:]
        let revision = try current()?.revision ?? UInt64.max
        for fp in keys { fence[fp] = max(fence[fp] ?? 0, revision) }
        var pending = state.pendingKeyRemoval ?? [:]
        for fp in fresh where removeManual {
            let id = registry.list().first { $0.pinnedClientKeyFingerprint == fp }?.id ?? Self.controllerID(fp)
            let lines = try registry.authorizedUserLines(fingerprint: fp)
            if !lines.isEmpty { pending[fp] = .init(deviceID: id, lines: lines) }
        }
        state.pendingKeyRemoval = pending
        state.revokedAt = fence; try save(state)
        for fp in fresh where removeManual {
            let id = registry.list().first { $0.pinnedClientKeyFingerprint == fp }?.id ?? Self.controllerID(fp)
            try registry.revokeAuthorizedKey(deviceID: id, fingerprint: fp)
        }
        try registry.fleetPruneRevokedKeys()
    }
    func pendingKeyRemoval(_ fingerprint: String, deviceID: String?, lines: [Int] = []) throws {
        var state = try read(), pending = state.pendingKeyRemoval ?? [:]
        pending[fingerprint] = deviceID.map { KeyRemoval(deviceID: $0, lines: lines) }; state.pendingKeyRemoval = pending; try save(state)
    }
    func keyRemovalWarnings() throws -> [String] {
        try (read().pendingKeyRemoval ?? [:]).sorted { $0.key < $1.key }.compactMap { fp, row in
            let lines = try registry.authorizedUserLines(fingerprint: fp)
            return lines.isEmpty ? nil : "設備「\(registry.list().first { $0.id == row.deviceID }?.name ?? row.deviceID)」：備份失敗，第 \(lines.map(String.init).joined(separator: "、")) 行仍可登入；會再試一次"
        }
    }
    /// Only a newer signed, code-authenticated enrollment generation removes a tombstone.
    private func applyRePairVersions(_ versions: [String: UInt64], locallyRepaired: Bool = false) throws {
        var state = try read()
        let restored = Set(versions.filter { fp, version in
            guard let fence = state.revokedAt?[fp] else { return false }
            return version > fence
        }.map(\.key))
        let keys = locallyRepaired ? Set(state.revokedKeys ?? []) : restored
        state.revokedKeys = (state.revokedKeys ?? []).filter { !keys.contains($0) }
        for fp in keys { state.pendingKeyRemoval?[fp] = nil }
        try save(state)
        let revokedIDs = Set(try current()?.roster?.revoked ?? [])
        for row in registry.list() where keys.contains(row.pinnedClientKeyFingerprint ?? "") && !revokedIDs.contains(row.id) {
            DeviceFleetConnections.restore(row.id, scope: registry.root.path)
        }
        if let roster = try current()?.roster {
            for row in roster.devices where restored.contains(row.clientKeyFingerprint ?? "") && !roster.revoked.contains(row.id) {
                DeviceFleetConnections.restore(row.id, scope: registry.root.path)
                var updated = try read(); updated.revocationDeliveries?[row.id] = nil
                updated.revocationSweeps = updated.revocationSweeps?.filter { !$0.key.hasPrefix(row.id + ":") }
                updated.revocationSweepGenerations?[row.id] = nil
                updated.deliveryProblems?[row.id] = nil; try save(updated)
            }
        }
    }
    private func pinOrMark(_ peer: DeviceFleetMember) throws {
        // Routing identity must survive a host pin failure, including for a later revocation.
        try registry.fleetRemember(peer)
        do {
            if peer.hostPublicKey != nil { try registry.fleetPinHost(peer) }
            if let record = registry.list().first(where: { $0.id == peer.id }) { _ = try DeviceFleetSSHPins.lines(for: record, registry: registry) }
            var state = try read(); state.pinConflicts?.removeAll { $0 == peer.id }; try save(state)
        } catch {
            var state = try read(); state.pinConflicts = Array(Set((state.pinConflicts ?? []) + [peer.id])); try save(state)
            audit("fleet_member_pin_conflict")
        }
    }
    static let lock = NSRecursiveLock()
    let registry: DeviceRegistry
    let environment: [String: String]
    let entry: TatwoEntry
    private var proposals: [UUID: DeviceFleetPendingChange] = [:]
    private var reconciled: (DeviceFleetEnvelope, [String])?
    var url: URL { registry.root.appendingPathComponent("fleet-state.json") }
    var logURL: URL { registry.root.appendingPathComponent("fleet-audit.log") }

    init(registry: DeviceRegistry, environment: [String: String]) {
        self.registry = registry; self.environment = environment; entry = TatwoEntry(environment: environment)
    }

    func pairingTransaction<T>(_ action: () throws -> T) throws -> T {
        try Self.lock.withLock {
            let blocked = [registry.root.path: DeviceFleetConnections.revokedIDs(scope: registry.root.path),
                           "": DeviceFleetConnections.revokedIDs(scope: "")]
            let files = [url, entry.deviceJSON, registry.url, registry.authorizedKeysURL, registry.fleetKnownHostsURL,
                         registry.root.appendingPathComponent("fleet-gate-policy.json")]
            let snapshots = try files.map { file -> Data? in
                FileManager.default.fileExists(atPath: file.path) ? try DeviceDispatchSafeFile.read(file, limit: 4 * 1024 * 1024) : nil
            }
            do { return try action() }
            catch {
                let failure = error
                for (file, bytes) in zip(files, snapshots) {
                    if let bytes { try DeviceDispatchSafeFile.write(bytes, url: file) }
                    else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
                // A failed fresh enrollment must also restore the in-memory reconnect barrier.
                for (scope, ids) in blocked { for id in ids { DeviceFleetConnections.revoke(id, scope: scope) } }
                throw failure
            }
        }
    }

    #if DEBUG
    static var fixtureStateRead: (() -> Void)?
    #endif
    /// Local eligibility only; network reachability and cross-device time remain unmeasured.
    static func upgradeCheck(environment: [String: String], now: Date = Date()) -> String {
        var report: [String: Any] = ["role": "unknown", "automatic": false, "reason": "identity_unavailable", "clock": "check_automatic_time", "unmarked_device_key_lines": 0]
        func output() -> String { String(data: (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}" }
        do {
            let registry = DeviceRegistry(environment: environment), fleet = DeviceFleetStore(registry: registry, environment: environment)
            let state = try fleet.read()
            let members = state.envelope.flatMap { try? JSONDecoder().decode(DeviceFleetPayload.self, from: $0.body) }?.roster?.devices ?? []
            let pins = Set(registry.list().flatMap { [$0.pinnedClientKeyFingerprint, $0.pinnedHostKeyFingerprint, $0.publicKeyFingerprint].compactMap { $0 } }
                + members.flatMap { [$0.clientKeyFingerprint, $0.hostKeyFingerprint].compactMap { $0 } })
            report["unmarked_device_key_lines"] = try pins.reduce(0) { try $0 + registry.authorizedUserLines(fingerprint: $1).count }
            guard let local = try DeviceIdentityStore.readLocal(entry: fleet.entry) else { return output() }
            report["role"] = local.role.rawValue
            if local.updatedAt.timeIntervalSince(now) > 120 { report["clock"] = "adjust" }
            guard local.epoch != nil, let primaryID = local.primaryDeviceID else { report["reason"] = "authority_unknown"; return output() }
            let client = environment["TATWO2_SSH_KEY_PATH"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
            let hasClient = FileManager.default.fileExists(atPath: client + ".pub")
            if let trust = state.trust {
                report["automatic"] = trust.kind == .owner && trust.localID == local.deviceID && trust.primaryID == primaryID && trust.epoch == local.epoch
                report["reason"] = report["automatic"] as? Bool == true ? "none" : "fleet_identity_mismatch"
            } else if local.role == .primary {
                let host = environment["TATWO2_SSH_HOST_KEY_PUB"] ?? "/etc/ssh/ssh_host_ed25519_key.pub"
                report["automatic"] = hasClient && FileManager.default.fileExists(atPath: host)
                report["reason"] = report["automatic"] as? Bool == true ? "none" : "local_public_key_missing"
            } else if let primary = registry.list().first(where: { $0.id == primaryID }), !primary.needsFingerprintRepair {
                let push = primary.clientKeyFingerprint.map { !(state.revokedKeys ?? []).contains($0) && registry.fleetHasAuthorizedFingerprint($0) } ?? false
                let pull = hasClient && primary.hostKeyFingerprint.map { registry.fleetHostPublicKey(fingerprint: $0) != nil } == true
                report["automatic"] = push || pull
                report["reason"] = push || pull ? "none" : "fleet_legacy_repair_required"
            } else { report["reason"] = "fleet_legacy_repair_required" }
        } catch { report["automatic"] = false; report["reason"] = "check_unavailable" }
        return output()
    }
    func read() throws -> State {
        #if DEBUG
        Self.fixtureStateRead?()
        #endif
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        let data = try DeviceDispatchSafeFile.read(url, limit: 4 * 1024 * 1024)
        return try JSONDecoder().decode(State.self, from: data)
    }
    func save(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        // Never commit a journal that this store's bounded reader cannot recover.
        guard data.count <= 4 * 1024 * 1024 else { throw DeviceFleetError.malformed }
        try DeviceDispatchSafeFile.write(data, url: url)
    }
    func audit(_ error: Error, fallback: String) {
        let code = DeviceFleetReason.code(error) ?? ""
        audit(!code.isEmpty && code.utf8.count <= 160 && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) } ? code : fallback)
    }
    func audit(_ reason: String, details: [String: Any]? = nil) {
        // 不記姓名、端點、碼或公鑰；一個事件一行，不讓遠端文字注入多行。
        let safe = reason.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }
        Self.lock.withLock {
            let old = (try? DeviceDispatchSafeFile.read(logURL, limit: 1024 * 1024)) ?? Data()
            let event = details.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) } ?? safe
            try? DeviceDispatchSafeFile.write(old.suffix(512 * 1024) + Data("\(Int(Date().timeIntervalSince1970)) \(event)\n".utf8), url: logURL)
        }
    }
    func trust() throws -> DeviceFleetTrust? { try Self.lock.withLock { try read().trust } }
    private var migratingStaff = false
    func migrateStaffInterconnections(_ payload: DeviceFleetPayload, trust: DeviceFleetTrust) throws -> DeviceFleetPayload {
        try Self.lock.withLock {
        // A timer's earlier snapshot cannot overwrite a physical confirmation or pairing.
        let payload = try current() ?? payload
        guard try self.trust() == trust else { throw DeviceFleetError.epoch }
        guard !migratingStaff else { return payload }
        if var roster = payload.roster, trust.localID == trust.primaryID, trust.kind == .owner {
            var migrated = roster
            migrated.removeStaffInterconnections()
            let staleProjection = try read().deliveries?.contains { id, envelope in
                guard let expected = try? migrated.slice(for: id),
                      let cached = try? envelope.verified(trust: .init(localID: id, primaryID: trust.primaryID,
                        epoch: trust.epoch, pinnedPrimaryKey: trust.pinnedPrimaryKey, kind: expected.faction.kind)) else { return false }
                return cached.slice != expected
            } == true
            if migrated != roster || staleProjection {
                migratingStaff = true; defer { migratingStaff = false }
                roster = migrated
                try publish(&roster, normalizeNames: false)
                audit("fleet_staff_interconnections_migrated")
                return try read().envelope!.verified(trust: trust)
            }
        }
        return payload
        }
    }
    func current() throws -> DeviceFleetPayload? {
        try Self.lock.withLock {
            let state = try read()
            guard let trust = state.trust, let envelope = state.envelope else { return nil }
            return try envelope.verified(trust: trust)
        }
    }
    func envelope() throws -> DeviceFleetEnvelope? { try Self.lock.withLock { try read().envelope } }
    /// Read-only graph source; a SUB caller receives only its verified, filtered projection.
    func readGraph() throws -> DeviceFleetPayload? {
        guard var payload = try current() else { return nil }
        if var roster = payload.roster { roster.removeStaffInterconnections(); payload.roster = roster }
        if var slice = payload.slice {
            let colleagues = Set(slice.devices.filter { $0.id != slice.targetID }.compactMap(\.clientKeyFingerprint))
            slice.controllers.removeAll { colleagues.contains($0.clientKeyFingerprint) }
            slice.devices = slice.devices.map { row in
                guard row.id != slice.targetID else { return row }
                var display = row; display.displayOnly = true; display.endpoints = []; display.user = ""
                display.clientPublicKey = nil; display.hostPublicKey = nil; return display
            }
            let anonymous = Set(slice.controllers.map { Self.controllerID($0.clientKeyFingerprint) })
            slice.edges?.removeAll { !anonymous.contains($0.from.id) && !anonymous.contains($0.to.id) }
            payload.slice = slice
        }
        return payload
    }
    /// Signed offers remain intact; authorization always intersects the local consent ceiling.
    func effectiveControllers(_ controllers: [DeviceFleetController]) throws -> [DeviceFleetController] {
        let ceiling = try read().consentCeiling ?? [:]
        return controllers.compactMap { row in
            var allowed = row
            allowed.capabilities = row.capabilities.filter { ceiling[row.clientKeyFingerprint]?.contains($0) == true }
            return allowed.capabilities.isEmpty ? nil : allowed
        }
    }
    /// Keep the signed incoming controller present for roster transport even before user consent.
    func transportControllers(_ controllers: [DeviceFleetController], state: State, payload: DeviceFleetPayload) -> [DeviceFleetController] {
        let colleagues = Set((payload.slice?.devices ?? []).filter { $0.id != payload.slice?.targetID }.compactMap(\.clientKeyFingerprint))
        let ceiling = state.consentCeiling ?? [:]
        return controllers.filter { !colleagues.contains($0.clientKeyFingerprint) }.map { row in
            var controller = row
            controller.capabilities = row.capabilities.filter { ceiling[row.clientKeyFingerprint]?.contains($0) == true }
            return controller
        }
    }
    func pendingConsent() throws -> DeviceFleetSlice? {
        try Self.lock.withLock {
            let state = try read()
            guard let trust = state.trust, let payload = try state.envelope?.verified(trust: trust),
                  let slice = payload.slice, !slice.revoked, !state.leaving else { return nil }
            let effective = transportControllers(slice.controllers, state: state, payload: payload)
            return effective == slice.controllers ? nil : slice
        }
    }
    /// The caller is the local physical card. Revision + exact controller list prevent stale consent.
    func approveConsent(revision: UInt64, controllers: [DeviceFleetController]) throws {
        try Self.lock.withLock {
            guard let payload = try current(), let slice = payload.slice, !slice.revoked,
                  slice.revision == revision, slice.controllers == controllers else { throw DeviceFleetError.staleProposal }
            var state = try read()
            state.consentCeiling = Dictionary(uniqueKeysWithValues: controllers.map { ($0.clientKeyFingerprint, $0.capabilities) })
            try save(state)
            try reconcile(payload)
        }
    }
    static func consentLines(_ slice: DeviceFleetSlice, ceiling: [String: [String]]? = nil, labels: [String: String] = [:]) -> [String] {
        slice.controllers.compactMap { controller in
            let permissions = controller.capabilities.filter { ceiling == nil || ceiling?[controller.clientKeyFingerprint]?.contains($0) != true }
            guard !permissions.isEmpty else { return nil }
            let peer = slice.devices.first { $0.clientKeyFingerprint == controller.clientKeyFingerprint }
            let name = labels[controller.clientKeyFingerprint] ?? peer.map { DeviceFleetName.label($0, groups: slice.group.map { [$0] } ?? []) } ?? "管理者的設備〔管理設備 · \(DeviceFleetName.shortFingerprint(controller.clientKeyFingerprint))〕"
            let words = permissions.map { DeviceFleetCapabilities.labels[$0] ?? "未知權限（不開放）" }
            return "\(name)：\(words.joined(separator: "、"))。"
        }
    }
    /// Engine selection/status fields; transport data stays in DeviceRecord and App-to-App RPC.
    static func engineDeviceProjection(_ records: [DeviceRecord], payload: DeviceFleetPayload? = nil, now: Date = Date()) -> [[String: Any]] {
        let members = payload?.roster?.devices ?? payload?.slice?.devices ?? []
        let groups = payload?.roster?.groups ?? payload?.slice?.group.map { [$0] } ?? []
        return records.filter { row in
            guard let payload else { return true }
            return members.contains { $0.id == row.id } && payload.roster?.revoked.contains(row.id) != true && payload.slice?.revoked != true
        }.map { record in
            let member = members.first { $0.id == record.id }
            return ["id": record.id, "name": DeviceFleetName.clean(member?.name ?? record.name),
                    "role": member?.role.rawValue ?? record.role?.rawValue ?? "secondary",
                    "group": groups.first { $0.id == member?.groupID }?.name ?? "",
                    "online": now.timeIntervalSince(record.lastSeenAt) >= 0 && now.timeIntervalSince(record.lastSeenAt) < 60]
        }
    }
    func propose(_ changes: [DeviceFleetChange], actor: String) throws -> DeviceFleetPendingChange {
        try Self.lock.withLock {
            do {
                try requireOwnerMember(actor)
                guard let roster = try current()?.roster else { throw DeviceFleetError.primaryRequired }
                var naming = roster
                let normalized = changes.map { change -> DeviceFleetChange in
                    switch change {
                    case let .renameDevice(id, name):
                        guard let index = naming.devices.firstIndex(where: { $0.id == id }) else { return change }
                        let value = DeviceFleetName.unique(name, used: naming.devices.filter { $0.id != id }.map(\.name))
                        naming.devices[index].name = value
                        return .renameDevice(id: id, name: value)
                    case let .renameGroup(id, name):
                        let value = DeviceFleetName.unique(name, used: naming.groups.filter { $0.id != id }.map(\.name))
                        if let i = naming.groups.firstIndex(where: { $0.id == id }) { naming.groups[i].name = value }
                        return .renameGroup(id: id, name: value)
                    case let .setManagerDisplayName(id, name): return .setManagerDisplayName(groupID: id, name: DeviceFleetName.clean(name))
                    default: return change
                    }
                }
                let proposal = try DeviceFleetGraphService.propose(roster: roster, actor: actor, changes: normalized)
                proposals[proposal.id] = proposal
                return proposal
            } catch { audit(error, fallback: "fleet_proposal_refused"); throw error }
        }
    }
    /// Local card cancellation consumes only this store instance's unconfirmed token.
    func discardProposal(_ id: UUID) { Self.lock.withLock { proposals[id] = nil } }
    /// The next room must call this only after one explicit user confirmation.
    /// The token is bound to this service instance and current revision; the caller cannot supply a preview to sign.
    static func disconnectAllTargets(before: DeviceFleetRoster, after: DeviceFleetRoster) throws -> Set<String> {
        var affected: Set<String> = [before.primaryID]
        for receiver in before.devices where before.kind(of: receiver.id) == .owner && !after.revoked.contains(receiver.id) {
            for sender in before.devices where sender.id != receiver.id && before.kind(of: sender.id) == .owner {
                let old = Set(try before.capabilities(from: sender.id, to: receiver.id))
                let new = Set(try after.capabilities(from: sender.id, to: receiver.id))
                if !old.isSubset(of: new)
                    || (after.revoked.contains(sender.id) && before.hasMAINTransport(from: sender.id, to: receiver.id)) {
                    affected.insert(receiver.id)
                }
            }
        }
        return affected
    }
    func confirm(_ id: UUID, userConfirmed: Bool, disconnectAllSelected: Bool = false) throws -> DeviceFleetEnvelope {
        try Self.lock.withLock {
            do {
                guard userConfirmed else { throw DeviceFleetError.confirmationRequired }
                try requireOwner()
                guard let trust = try trust(), trust.localID == trust.primaryID,
                      let proposal = proposals[id], let current = try current()?.roster else {
                    throw DeviceFleetError.primaryRequired
                }
                guard proposal.baseVersion == current.version else { throw DeviceFleetError.staleProposal }
                if proposal.changes.contains(where: { if case .transfer = $0 { return true }; return false }) {
                    // A Boolean from an assistant/RPC is never local UI authority.
                    throw DeviceFleetError.confirmationRequired
                }
                let verified = try DeviceFleetGraphService.propose(roster: current, actor: proposal.actor, changes: proposal.changes)
                var next = verified.preview
                if disconnectAllSelected {
                    let affected = try Self.disconnectAllTargets(before: current, after: next)
                    if !affected.isEmpty {
                        next.disconnectAll = .init(id: UUID().uuidString, revision: current.version + 1, targets: affected.sorted())
                    }
                }
                try publish(&next)
                var state = try read()
                for case let .stopTracking(id) in proposal.changes {
                    var row = state.revocationDeliveries?[id] ?? .init(attempts: 0, first: Date(), delivered: false)
                    row.stopped = true
                    state.revocationDeliveries = (state.revocationDeliveries ?? [:]).merging([id: row]) { _, new in new }
                    state.deliveryProblems?[id] = nil
                }
                try save(state)
                proposals[id] = nil
                return try envelope()!
            } catch { audit(error, fallback: "fleet_confirmation_refused"); throw error }
        }
    }
    func incomingControllers(_ roster: DeviceFleetRoster, trust: DeviceFleetTrust, state: State? = nil) throws -> [DeviceFleetController] {
        var controllers = try roster.incoming(to: trust.localID)
        if let local = try DeviceIdentityStore.readLocal(entry: entry), let transfer = local.transfer,
           transfer.committed, !transfer.epochComplete, transfer.from == trust.localID,
           transfer.epoch == trust.epoch,
           let rotation = try (state ?? read()).rotation, try rotation.handoff.claim.id == transfer.id {
            for id in transfer.participants where !(transfer.skippedParticipants ?? []).contains(id) {
                guard roster.kind(of: id) == .owner, let peer = roster.devices.first(where: { $0.id == id }),
                      let fp = peer.clientKeyFingerprint, let key = peer.clientPublicKey,
                      !controllers.contains(where: { $0.clientKeyFingerprint == fp }) else { continue }
                controllers.append(.init(clientKeyFingerprint: fp, clientPublicKey: key, capabilities: []))
            }
        }
        return controllers
    }
    /// nil = key not authorized by an incoming arrow; never use a fingerprint supplied in RPC params.
    func capabilities(for fingerprint: String) throws -> [String]? {
        let state = try Self.lock.withLock { try read() }
        guard let trust = state.trust else { return nil }
        guard let payload = try state.envelope?.verified(trust: trust) else {
            // Pairing has authenticated this one controller, but the first signed projection
            // has not arrived yet. Bootstrap only the two roster transport methods below.
            if trust.kind != .owner, state.controllerHistory.contains(fingerprint),
               registry.fleetPublicKey(deviceID: Self.controllerID(fingerprint)) != nil { return ["dispatch"] }
            return nil
        }
        let controllers = try payload.roster.map { try incomingControllers($0, trust: trust, state: state) } ?? transportControllers(payload.slice?.controllers ?? [], state: state, payload: payload)
        return controllers.first { $0.clientKeyFingerprint == fingerprint }?.capabilities
    }
    func allowsNativeExecution(fingerprint: String) throws -> Bool {
        guard let capabilities = try capabilities(for: fingerprint) else { return false }
        return DeviceFleetCapabilities.allowsNativeExecution(capabilities)
    }
    func methodAllowed(fingerprint: String, method: String) throws -> Bool {
        guard let capabilities = try capabilities(for: fingerprint) else { return false }
        if DeviceFleetCapabilities.isFleetTransport(method) { return true }
        if try current() == nil { return false }
        if let roster = try current()?.roster, let trust = try trust(), roster.kind(of: trust.localID) == .owner,
           let peer = roster.activeMember(clientFingerprint: fingerprint), roster.kind(of: peer.id) == .owner,
           Set(capabilities) == Set(DeviceFleetCapabilities.all) {
            return DeviceFleetCapabilities.required(for: method) != nil || DeviceFleetCapabilities.ownerOnlyMethods.contains(method)
        }
        return DeviceFleetCapabilities.allows(method: method, capabilities: capabilities)
    }
    func pending() throws -> [DeviceFleetMember] { try Self.lock.withLock { try read().pending } }
    var statusText: String {
        if (try? pending().isEmpty) == false { return "待主設備簽名單" }
        return (try? current()) == nil ? "舊版，更新後自動互通" : "名單已驗章"
    }
    func allowsPeerConnection(_ id: String) -> Bool {
        do { if let trust = try trust(), trust.kind != .owner { return false }; return true }
        catch { return false }
    }
    func requireOwner() throws {
        do {
            if let trust = try trust(), trust.kind != .owner { throw DeviceFleetError.managedLocked }
        } catch { audit("fleet_managed_operation_refused"); throw error }
    }
    /// Read-only displays use only the signed projection; controller identities are not display membership.
    func visibleRegistryRecords() -> [DeviceRecord] {
        do {
            guard let payload = try readGraph() else { return try trust() == nil ? registry.list() : [] }
            let visible: [DeviceFleetMember]
            if let roster = payload.roster {
                visible = roster.devices.filter { !roster.revoked.contains($0.id) }
            } else if let slice = payload.slice, !slice.revoked {
                visible = slice.devices
            } else { return [] }
            return registry.list().filter { row in visible.contains {
                $0.id == row.id || ($0.clientKeyFingerprint != nil && $0.clientKeyFingerprint == row.clientKeyFingerprint)
            } }
        } catch { return [] }
    }
    func requireOwnerMember(_ id: String) throws {
        try requireOwner()
        if let roster = try current()?.roster, roster.kind(of: id) != .owner || roster.revoked.contains(id) {
            audit("fleet_nonowner_authority_refused"); throw DeviceFleetError.role
        }
    }

    func localMember(faction: DeviceFaction, host: String) throws -> DeviceFleetMember {
        let local = try DeviceIdentityStore.forLocalDevice(entry: entry).read()
        let clientPath = (environment["TATWO2_SSH_KEY_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path) + ".pub"
        let client = try String(contentsOfFile: clientPath, encoding: .utf8)
        let hostKey = try String(contentsOfFile: environment["TATWO2_SSH_HOST_KEY_PUB"]
                                ?? "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8)
        let role: DeviceFleetRole = faction.kind == .owner
            ? (local.role == .primary ? .primary : .secondary) : (faction.kind == .managed ? .managed : .sandbox)
        let row = DeviceFleetMember(id: local.deviceID, name: DeviceFleetName.clean(local.name), factionID: faction.id, role: role,
                                   clientKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: client),
                                   hostKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: hostKey),
                                   clientPublicKey: client, hostPublicKey: hostKey,
                                   endpoints: [.init(kind: .lan, host: host)], user: NSUserName())
        try row.validate()
        return row
    }

    /// primary migration: 既有已配對記錄成 owner；缺的公鑰只能經下次已 pin 的同步補齊。
    func bootstrapPrimary(host: String = "127.0.0.1") throws {
        try Self.lock.withLock {
            try requireOwner()
            guard try read().trust == nil else { return }
            let local = try DeviceIdentityStore.forLocalDevice(entry: entry).read()
            guard local.role == .primary, local.primaryDeviceID == local.deviceID, let epoch = local.epoch else { return }
            let faction = DeviceFaction(id: "owner", name: "我的開發設備", kind: .owner, managerDisplayName: "管理者")
            let me = try localMember(faction: faction, host: host)
            var devices = [me]
            for record in registry.list() {
                let client = registry.fleetPublicKey(deviceID: record.id)
                let hostKey = registry.fleetHostPublicKey(fingerprint: record.hostKeyFingerprint)
                devices.append(.init(id: record.id, name: DeviceFleetName.unique(record.name, used: devices.map(\.name)), factionID: faction.id, role: .secondary,
                    clientKeyFingerprint: record.clientKeyFingerprint, hostKeyFingerprint: record.hostKeyFingerprint,
                    clientPublicKey: client, hostPublicKey: hostKey, endpoints: record.endpoints, user: record.user, legacy: true))
            }
            let trust = DeviceFleetTrust(localID: me.id, primaryID: me.id, epoch: epoch,
                                         pinnedPrimaryKey: me.clientKeyFingerprint!, kind: .owner)
            let roster = DeviceFleetRoster(version: 1, primaryID: me.id, epoch: epoch,
                                           factions: [faction], devices: devices, revoked: [])
            let envelope = try DeviceFleetEnvelope.issue(.init(roster: roster), environment: environment)
            _ = try envelope.verified(trust: trust)
            try save(State(trust: trust, envelope: envelope))
            try reconcile(.init(roster: roster))
        }
    }

    func makeOffer(kind: DeviceFactionKind, factionID: String?, host: String) throws -> DeviceFleetPairOffer? {
        try requireOwner()
        try bootstrapPrimary(host: host)
        guard let trust = try trust(), let roster = try current()?.roster else { return nil }
        guard roster.kind(of: trust.localID) == .owner else { throw DeviceFleetError.role }
        guard let identity = try DeviceIdentityStore.readLocal(entry: entry),
              identity.primaryDeviceID == roster.primaryID, identity.epoch == roster.epoch else { throw DeviceFleetError.epoch }
        let faction: DeviceFaction
        if kind == .owner {
            faction = roster.factions.first { $0.kind == .owner }!
        } else if kind == .sandbox, let id = factionID, let group = roster.groups.first(where: { $0.id == id }) {
            var sandbox = group.faction; sandbox.kind = .sandbox; sandbox.showPrimaryToMembers = false
            faction = sandbox
        } else {
            let available = roster.factions + (try read().draftFactions ?? [])
            guard let id = factionID, let found = available.first(where: { $0.id == id && $0.kind == kind }) else {
                throw DeviceFleetError.unknownMember
            }
            faction = found
        }
        // 配對的 owner 身分不能改成它出碼所邀的 managed 身分。
        let ownerFaction = roster.factions.first { $0.kind == .owner }!
        let registeredHost = roster.devices.first { $0.id == trust.localID }?.endpoints.first?.host ?? host
        var member = try localMember(faction: ownerFaction, host: registeredHost)
        if kind != .owner {
            member.name = faction.managerDisplayName
            member.endpoints = []
            member.role = .secondary
            member.user = "manager"
        }
        return try .init(member: member, trust: trust,
                         envelope: kind == .owner ? envelope() : nil, faction: faction)
    }

    func locallyRevoked() throws -> Bool {
        guard let trust = try trust(), let payload = try current() else { return false }
        return payload.revocationNotice?.targetID == trust.localID || payload.slice?.revoked == true
            || payload.roster?.revoked.contains(trust.localID) == true
    }
    func checkJoining(hostFingerprint: String, offer: DeviceFleetPairOffer?) throws {
        if try !locallyRevoked() { try requireOwner() }
        if let currentTrust = try trust(), let offer {
            if currentTrust.kind != .owner && offer.faction.kind == .owner { throw DeviceFleetError.managedLocked }
            if currentTrust.kind == .sandbox && offer.faction.kind != .sandbox { throw DeviceFleetError.reverseEnrollment }
        }
        if let roster = try current()?.roster,
           roster.devices.contains(where: { $0.hostKeyFingerprint == hostFingerprint
               && roster.kind(of: $0.id) != .owner && !roster.revoked.contains($0.id) }) {
            audit("fleet_reverse_enrollment_refused"); throw DeviceFleetError.reverseEnrollment
        }
        if let roster = try current()?.roster, let peer = offer?.member,
           roster.devices.contains(where: { $0.id == peer.id && roster.kind(of: $0.id) != .owner }) {
            audit("fleet_peer_role_or_revocation_refused"); throw DeviceFleetError.reverseEnrollment
        }
        if let current = try trust(), let offer, current.primaryID == offer.trust.primaryID {
            guard current.pinnedPrimaryKey == offer.trust.pinnedPrimaryKey else {
                audit("fleet_primary_pin_substitution_refused"); throw DeviceFleetError.signer
            }
            guard current.epoch == offer.trust.epoch else { throw DeviceFleetError.epoch }
        }
        if let roster = try current()?.roster, offer == nil,
           !roster.devices.contains(where: { $0.hostKeyFingerprint == hostFingerprint && roster.kind(of: $0.id) == .owner }) {
            audit("fleet_unknown_legacy_join_refused"); throw DeviceFleetError.foreignFleet
        }
        if let trust = try trust(), let offer, trust.kind == .owner, offer.faction.kind != .owner,
           try !locallyRevoked() {
            audit("fleet_owner_cannot_be_managed"); throw DeviceFleetError.foreignFleet
        }
        if let stateTrust = try trust(), let offer, offer.trust.primaryID != stateTrust.primaryID {
            let left = try locallyRevoked()
            guard left else {
                audit("fleet_foreign_join_refused"); throw DeviceFleetError.foreignFleet
            }
        } else if let local = try DeviceIdentityStore.readLocal(entry: entry),
                  let primary = local.primaryDeviceID, let offer, primary != offer.trust.primaryID,
                  try trust() == nil {
            // 未遷移的既有 owner 身分也不能被另一群帶走。
            audit("fleet_legacy_foreign_join_refused"); throw DeviceFleetError.foreignFleet
        }
    }

    /// owner 兩台先互通；加入其他群或反收前必須先跑 checkJoining。
    func completePair(peer: DeviceFleetMember, offer: DeviceFleetPairOffer, consent: Bool) throws {
        try pairingTransaction {
            try peer.validate()
            guard let hostFingerprint = peer.hostKeyFingerprint else { throw DeviceFleetError.missingKey }
            try checkJoining(hostFingerprint: hostFingerprint, offer: offer)
            var state = try read()
            let local = try DeviceIdentityStore.forLocalDevice(entry: entry).read()
            if offer.faction.kind != .owner, !consent { throw DeviceFleetError.consentRequired }
            var trust = offer.trust
            trust.localID = local.deviceID; trust.kind = offer.faction.kind
            var primaryMember: DeviceFleetMember?
            if offer.faction.kind == .owner {
                guard let envelope = offer.envelope else { throw DeviceFleetError.signature }
                let candidate = try envelope.verified(trust: .init(localID: peer.id, primaryID: trust.primaryID,
                    epoch: trust.epoch, pinnedPrimaryKey: trust.pinnedPrimaryKey, kind: .owner))
                guard let roster = candidate.roster, roster.kind(of: peer.id) == .owner,
                      let declared = roster.devices.first(where: { $0.id == peer.id }),
                      declared.clientKeyFingerprint == peer.clientKeyFingerprint,
                      declared.hostKeyFingerprint == peer.hostKeyFingerprint else { throw DeviceFleetError.role }
                primaryMember = roster.devices.first { $0.id == trust.primaryID }
                // 所有簽章與釘選檢查必須在 authorized_keys 寫入之前完成。
                try registry.fleetValidatePins([peer] + (primaryMember.map { [$0] } ?? []))
            }
            let freshLifecycle = state.trust?.localID != local.deviceID && state.trust?.kind == .owner
            if try locallyRevoked() || freshLifecycle, state.trust?.primaryID == trust.primaryID {
                guard let envelope = offer.envelope else { throw DeviceFleetError.signature }
                let proof = try envelope.verified(trust: trust)
                let versions = proof.roster?.rePairVersions ?? proof.slice?.rePairVersions ?? [:]
                let localKey = try localMember(faction: offer.faction, host: "127.0.0.1").clientKeyFingerprint!
                guard let generation = versions[localKey], generation > (try current()?.revision ?? UInt64.max),
                      proof.roster?.revoked.contains(local.deviceID) != true, proof.slice?.revoked != true else {
                    throw DeviceFleetError.replay
                }
                try applyRePairVersions(versions, locallyRepaired: true)
                state = try read()
            }
            // A verified new invitation starts a new local consent lifecycle.
            // Ordinary roster refreshes never withdraw a pending leave request.
            state.leaving = false
            // owner 正本內不收新成員前，新成員只能釘配對 peer，不能套用全群。
            if state.trust == nil || state.trust?.primaryID != trust.primaryID || state.trust?.localID != trust.localID {
                state.trust = trust; state.envelope = nil
            }
            if offer.faction.kind == .owner {
                guard let client = peer.clientPublicKey else { throw DeviceFleetError.missingKey }
                if let candidate = try offer.envelope?.verified(trust: .init(localID: peer.id, primaryID: trust.primaryID,
                    epoch: trust.epoch, pinnedPrimaryKey: trust.pinnedPrimaryKey, kind: .owner)),
                   candidate.roster?.devices.contains(where: { $0.id == local.deviceID }) == true {
                    _ = try registry.authorize(publicKey: client, deviceID: peer.id)
                    try registry.fleetPinHost(peer)
                }
            } else {
                // 單向加入：只給本機 owner 的公開 client key；受管 client key 永不回 owner。
                guard let client = peer.clientPublicKey else { throw DeviceFleetError.missingKey }
                state.consentCeiling = [:]
                // Prior to the first signed slice, only signed roster transport is allowed
                // by methodAllowed; user capabilities remain closed until local consent.
                let id = Self.controllerID(peer.clientKeyFingerprint!)
                let controller = DeviceFleetController(clientKeyFingerprint: peer.clientKeyFingerprint!, clientPublicKey: client, capabilities: ["dispatch"])
                try DeviceFleetGate.publish(registry: registry, controllers: [id: controller])
                try registry.fleetReconcileKeys([(id, client)], preserveLegacy: [], pending: [])
                state.controllerHistory.append(peer.clientKeyFingerprint!)
            }
            try save(state)
            // 只讀 bootstrap 公鑰與主設備 pin；把自己列進來前不施加全群授權。
            if let primary = primaryMember {
                try registry.fleetPinHost(primary)
                try registry.fleetRemember(primary)
            }
        }
    }

    func queue(_ member: DeviceFleetMember) throws {
        try Self.lock.withLock {
            try requireOwner(); try member.validate()
            var state = try read()
            state.pending.removeAll { $0.id == member.id }; state.pending.append(member)
            try save(state); audit("fleet_waiting_primary_signature")
        }
    }

    /// Old secondary invitations had no admission authority. Retire their local pending rows.
    func discardSecondaryPending() throws {
        try Self.lock.withLock {
            var state = try read()
            guard let trust = state.trust, trust.kind == .owner, trust.localID != trust.primaryID else { return }
            guard !state.pending.isEmpty || state.deliveryProblems?.isEmpty == false else { return }
            state.pending = []; state.deliveryProblems = [:]
            try save(state); audit("fleet_secondary_pending_retired")
        }
    }

    /// ACK may complete only the authenticated sender's existing legacy row. It cannot
    /// add a member, change a group/role/route, restore a revoked ID, or replace a pin.
    func upgradeLegacySelf(_ member: DeviceFleetMember, sender: String) throws {
        try Self.lock.withLock {
            guard let trust = try trust(), trust.kind == .owner, trust.localID == trust.primaryID,
                  member.id == sender, !member.legacy, !member.displayOnly,
                  var roster = try current()?.roster, !roster.revoked.contains(sender),
                  roster.kind(of: sender) == .owner,
                  let index = roster.devices.firstIndex(where: { $0.id == sender }), roster.devices[index].legacy,
                  let paired = registry.list().first(where: { $0.id == sender }),
                  member.clientKeyFingerprint == paired.pinnedClientKeyFingerprint else { throw DeviceFleetError.role }
            try member.validate()
            var row = roster.devices[index]
            guard row.groupID == member.groupID, row.role == member.role,
                  row.clientKeyFingerprint == nil || row.clientKeyFingerprint == member.clientKeyFingerprint,
                  row.hostKeyFingerprint == nil || row.hostKeyFingerprint == member.hostKeyFingerprint,
                  paired.pinnedHostKeyFingerprint == nil || paired.pinnedHostKeyFingerprint == member.hostKeyFingerprint else { throw DeviceFleetError.keyConflict }
            row.clientKeyFingerprint = member.clientKeyFingerprint; row.clientPublicKey = member.clientPublicKey
            row.hostKeyFingerprint = member.hostKeyFingerprint; row.hostPublicKey = member.hostPublicKey; row.legacy = false
            // A legacy key fill cannot invalidate the user's pending handoff confirmation.
            if let rotation = try rotation(), trust.epoch == (try rotation.handoff.claim).oldEpoch {
                audit("fleet_legacy_self_upgrade_deferred_for_transfer"); return
            }
            try row.validate(); roster.devices[index] = row; try publish(&roster, normalizeNames: false)
            audit("fleet_legacy_self_upgraded")
        }
    }

    /// 只有 dispatch 的已 pin 主機金鑰回覆能呼叫；沿用 HandsBuildTrust 的先驗後補 pin 規則。
    func adoptLegacy(_ envelope: DeviceFleetEnvelope, primary: DeviceRecord, expectedHost: String) throws {
        try Self.lock.withLock {
            guard try read().trust == nil,
                  let local = try DeviceIdentityStore.readLocal(entry: entry),
                  local.role == .secondary, local.primaryDeviceID == primary.id,
                  primary.hostKeyFingerprint == expectedHost, !primary.needsFingerprintRepair,
                  let epoch = local.epoch else { throw DeviceFleetError.signer }
            let fingerprint = try DeviceRegistry.fingerprint(publicKey: envelope.publicKey)
            if let pin = primary.clientKeyFingerprint, pin != fingerprint { throw DeviceFleetError.signer }
            let trust = DeviceFleetTrust(localID: local.deviceID, primaryID: primary.id, epoch: epoch,
                                         pinnedPrimaryKey: fingerprint, kind: .owner)
            _ = try envelope.verified(trust: trust)
            if primary.clientKeyFingerprint == nil {
                guard try registry.recordClientFingerprint(id: primary.id, expectedHost: expectedHost,
                    fingerprint: fingerprint, source: "fleet_pinned_channel") else { throw DeviceFleetError.keyConflict }
            }
            var state = try read(); state.trust = trust; try save(state)
            try accept(envelope)
        }
    }

    /// Inbound bootstrap cannot infer a signing identity from a host pin or the received key.
    func legacyPushTrust(_ envelope: DeviceFleetEnvelope, sender: String) throws -> DeviceFleetTrust {
        let state = try read()
        guard state.trust == nil, let local = try DeviceIdentityStore.readLocal(entry: entry),
              local.role == .secondary, local.primaryDeviceID == sender, let epoch = local.epoch,
              let primary = registry.list().first(where: { $0.id == sender }),
              !primary.needsFingerprintRepair,
              let pin = primary.clientKeyFingerprint else { throw DeviceDispatch.Failure(reason: "fleet_legacy_repair_required") }
        guard try DeviceRegistry.fingerprint(publicKey: envelope.publicKey) == pin,
              !(state.revokedKeys ?? []).contains(pin), registry.fleetHasAuthorizedFingerprint(pin) else { throw DeviceFleetError.signer }
        let trust = DeviceFleetTrust(localID: local.deviceID, primaryID: sender, epoch: epoch, pinnedPrimaryKey: pin, kind: .owner)
        let payload = try envelope.verified(trust: trust)
        guard let roster = payload.roster, !roster.revoked.contains(sender), !roster.revoked.contains(local.deviceID) else { throw DeviceFleetError.role }
        try registry.fleetValidatePins(roster.devices)
        return trust
    }
    func adoptLegacyPush(_ envelope: DeviceFleetEnvelope, sender: String) throws {
        try pairingTransaction {
            let trust = try legacyPushTrust(envelope, sender: sender)
            var state = try read(); state.trust = trust; try save(state)
            try accept(envelope)
        }
    }

    func syncMember() throws -> DeviceFleetMember? {
        guard let trust = try trust(), trust.kind == .owner else { return nil }
        let roster = try current()?.roster
        let faction = roster?.factions.first { $0.kind == .owner }
            ?? DeviceFaction(id: "owner", name: "我的開發設備", kind: .owner, managerDisplayName: "管理者")
        let host = roster?.devices.first { $0.id == trust.localID }?.endpoints.first?.host
            ?? environment["TATWO2_PAIRING_HOST"] ?? ProcessInfo.processInfo.hostName
        return try localMember(faction: faction, host: host)
    }

    /// 只接受經現有 RPC 驗章的 owner 之提案；副设备能提案，不能自己簽正本。
    private func admissionRoster(_ members: [DeviceFleetMember], sender: String, allowRePair: Bool = false) throws -> DeviceFleetRoster {
        try Self.lock.withLock {
            try requireOwnerMember(sender)
            guard let trust = try read().trust, trust.localID == trust.primaryID,
                  var roster = try current()?.roster else { throw DeviceFleetError.primaryRequired }
            for var member in members {
                member.name = DeviceFleetName.unique(member.name, used: roster.devices.filter { $0.id != member.id }.map(\.name))
                try member.validate()
                let repairing = roster.revoked.contains(member.id)
                guard (!repairing || allowRePair),
                      let faction = (roster.factions + (try read().draftFactions ?? [])).first(where: { $0.id == member.factionID })
                        ?? (member.role == .sandbox ? roster.factions.first { $0.kind == .owner } : nil) else {
                    throw DeviceFleetError.role
                }
                if member.role == .sandbox && !roster.groups.contains(where: { $0.id == member.groupID }) {
                    member.groupID = roster.groups.first { $0.type == .main }!.id
                }
                if let previous = roster.devices.first(where: { $0.id == member.id }) {
                    // migration 只補缺的鍵，不能靜默替換任何已 pin 的鍵或更改派系。
                    guard previous.factionID == member.factionID,
                          previous.clientKeyFingerprint == nil || previous.clientKeyFingerprint == member.clientKeyFingerprint,
                          previous.hostKeyFingerprint == nil || previous.hostKeyFingerprint == member.hostKeyFingerprint else {
                        throw DeviceFleetError.keyConflict
                    }
                    member.role = previous.role
                    if repairing {
                        guard previous.clientKeyFingerprint == member.clientKeyFingerprint,
                              previous.hostKeyFingerprint == member.hostKeyFingerprint,
                              let fingerprint = member.clientKeyFingerprint else { throw DeviceFleetError.keyConflict }
                        roster.revoked.removeAll { $0 == member.id }
                        var generations = roster.rePairVersions ?? [:]
                        generations[fingerprint] = roster.version + 1; roster.rePairVersions = generations
                    }
                    if previous == member && !repairing { continue }
                } else {
                    if let fingerprint = member.clientKeyFingerprint, roster.devices.contains(where: {
                        roster.revoked.contains($0.id) && $0.clientKeyFingerprint == fingerprint
                    }) {
                        var generations = roster.rePairVersions ?? [:]
                        generations[fingerprint] = roster.version + 1; roster.rePairVersions = generations
                    }
                    guard member.role != .primary else { throw DeviceFleetError.role }
                    if faction.kind == .sandbox || member.role == .sandbox {
                        member.role = .sandbox
                    } else if faction.kind == .managed && !roster.groups.contains(where: { $0.id == faction.id }) {
                        member.role = DeviceFleetDefaults.firstManagedDeviceIsPrimary ? .primary : .secondary
                        roster.groups.append(.init(id: faction.id, name: faction.name, type: .sub,
                            primaryDeviceID: DeviceFleetDefaults.firstManagedDeviceIsPrimary ? member.id : "", parentGroupID: roster.groups.first { $0.type == .main }!.id,
                            showMainPrimary: faction.showPrimaryToMembers, managerDisplayName: faction.managerDisplayName))
                    } else { member.role = .secondary }
                }
                let new = !roster.devices.contains { $0.id == member.id }
                roster.devices.removeAll { $0.id == member.id }; roster.devices.append(member)
                if new {
                    // Add only new-device/group defaults; never overwrite customized arrows of existing members.
                    let defaults = DeviceFleetRoster.defaults(groups: roster.groups, devices: roster.devices)
                    for edge in defaults where edge.from == .device(member.id) || edge.to == .device(member.id)
                        || edge.from == .group(member.groupID) || edge.to == .group(member.groupID) {
                        if !roster.edges.contains(where: { $0.from == edge.from && $0.to == edge.to }) { roster.edges.append(edge) }
                    }
                }
            }
            roster.normalizeNames()
            return roster
        }
    }
    func approve(_ members: [DeviceFleetMember], sender: String, allowRePair: Bool = false) throws {
        try Self.lock.withLock {
            var roster = try admissionRoster(members, sender: sender, allowRePair: allowRePair)
            if roster != (try current()?.roster) { try publish(&roster) }
        }
    }
    func previewAdmission(_ member: DeviceFleetMember, sender: String, allowRePair: Bool = false) throws -> DeviceFleetEnvelope {
        try Self.lock.withLock {
            var roster = try admissionRoster([member], sender: sender, allowRePair: allowRePair)
            roster.version += 1
            var slice = try roster.slice(for: member.id)
            slice.devices.removeAll { $0.id != member.id }
            slice.edges?.removeAll { edge in edge.from.id != member.id && edge.to.id != member.id }
            return try DeviceFleetEnvelope.issue(.init(slice: slice), environment: environment)
        }
    }
    static func consentDigest(_ slice: DeviceFleetSlice) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(slice.controllers) + encoder.encode(slice.faction) + Data(slice.targetID.utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func publish(_ roster: inout DeviceFleetRoster, normalizeNames: Bool = true) throws {
        try Self.lock.withLock {
        try cancelUncommittedRotationForRosterChange()
        var state = try read()
        guard let trust = state.trust, trust.kind == .owner, trust.localID == trust.primaryID,
              roster.primaryID == trust.primaryID, roster.version < UInt64.max else { throw DeviceFleetError.primaryRequired }
        guard let local = try DeviceIdentityStore.readLocal(entry: entry), local.role == .primary,
              local.primaryDeviceID == trust.primaryID, local.epoch == trust.epoch else { throw DeviceFleetError.epoch }
        if let previous = try current()?.roster {
            guard roster.version == previous.version else { throw DeviceFleetError.staleProposal }
            try roster.validateTransition(from: previous)
        }
        if let event = roster.disconnectAll, event.revision <= roster.version { roster.disconnectAll = nil }
        roster.removeStaffInterconnections()
        if normalizeNames { roster.normalizeNames() }
        roster.version += 1
        let envelope = try DeviceFleetEnvelope.issue(.init(roster: roster), environment: environment)
        _ = try envelope.verified(trust: trust)
        state.envelope = envelope
        state.deliveries = nil
        state.leaveRequests.removeAll { roster.revoked.contains($0) }
        state.pending.removeAll { row in roster.devices.contains {
            $0.id == row.id && $0.clientKeyFingerprint == row.clientKeyFingerprint && $0.hostKeyFingerprint == row.hostKeyFingerprint
        } }
        try save(state); try reconcile(.init(roster: roster))
        }
    }

    func setFaction(_ faction: DeviceFaction) throws {
        try Self.lock.withLock {
            try requireOwner()
            guard let trust = try trust(), trust.localID == trust.primaryID else { throw DeviceFleetError.primaryRequired }
            guard var roster = try current()?.roster, !faction.id.isEmpty, !faction.name.isEmpty else {
                throw DeviceFleetError.primaryRequired
            }
            if let old = roster.factions.first(where: { $0.id == faction.id }), old.kind != faction.kind {
                throw DeviceFleetError.role
            }
            if let index = roster.groups.firstIndex(where: { $0.id == faction.id }) {
                roster.groups[index].name = faction.name
                roster.groups[index].managerDisplayName = faction.managerDisplayName
                roster.groups[index].showMainPrimary = faction.showPrimaryToMembers
                try publish(&roster)
            } else {
                guard faction.kind != .owner else { throw DeviceFleetError.role }
                // An empty group cannot have a valid primary. Keep compatibility pairing setup unsigned
                // until an authenticated member is enrolled, then create the complete v2 group.
                var state = try read()
                var drafts = state.draftFactions ?? []
                drafts.removeAll { $0.id == faction.id }; drafts.append(faction)
                state.draftFactions = drafts; try save(state)
            }
        }
    }
    func revoke(_ id: String) throws {
        try Self.lock.withLock {
            try requireOwner()
            guard var roster = try current()?.roster, id != roster.primaryID,
                  roster.devices.contains(where: { $0.id == id }) else { throw DeviceFleetError.unknownMember }
            if !roster.revoked.contains(id) { roster.revoked.append(id); try publish(&roster) }
        }
    }
    func delivery(for id: String) throws -> DeviceFleetEnvelope? {
        guard let roster = try current()?.roster else { return nil }
        guard let local = try DeviceIdentityStore.readLocal(entry: entry),
              local.primaryDeviceID == roster.primaryID, local.epoch == roster.epoch else { throw DeviceFleetError.epoch }
        let row = roster.devices.first { $0.id == id }
        if roster.revoked.contains(id) {
            var notice = try DeviceFleetEnvelope.issue(.init(revocationNotice: .init(targetID: id, revision: roster.version, epoch: roster.epoch)), environment: environment)
            notice.publicKey = "" // Recipient already pins the signer; no other member's key travels here.
            return notice
        }
        if row?.role != .sandbox && roster.groups.first(where: { $0.id == row?.groupID })?.type == .main {
            return try envelope()
        }
        if let cached = try read().deliveries?[id], let trust = try trust(),
           let payload = try? cached.verified(trust: DeviceFleetTrust(localID: id, primaryID: trust.primaryID,
               epoch: trust.epoch, pinnedPrimaryKey: trust.pinnedPrimaryKey,
               kind: row?.role == .sandbox ? .sandbox : .managed)),
           payload.revision == roster.version, payload.slice == (try roster.slice(for: id)) { return cached }
        guard (try trust())?.localID == roster.primaryID else { throw DeviceFleetError.primaryRequired }
        let fresh = try DeviceFleetEnvelope.issue(.init(slice: roster.slice(for: id)), environment: environment)
        try Self.lock.withLock {
            var state = try read(); var deliveries = state.deliveries ?? [:]
            deliveries[id] = fresh; state.deliveries = deliveries; try save(state)
        }
        return fresh
    }
    func managedDeliveries() throws -> [String: DeviceFleetEnvelope] {
        guard let roster = try current()?.roster else { return [:] }
        var deliveries: [String: DeviceFleetEnvelope] = [:]
        for row in roster.devices where !roster.revoked.contains(row.id) && (row.role == .sandbox || roster.groups.first(where: { $0.id == row.groupID })?.type == .sub) {
            do {
                #if DEBUG
                if fixtureDeliveryFailures.contains(row.id) { throw DeviceFleetError.malformed }
                #endif
                if let envelope = try delivery(for: row.id) { deliveries[row.id] = envelope }
            } catch { audit("fleet_delivery_skipped_" + row.id) }
        }
        return deliveries
    }
    func cacheDeliveries(_ deliveries: [String: DeviceFleetEnvelope]) throws {
        try Self.lock.withLock {
            guard let roster = try current()?.roster, let trust = try trust(), trust.kind == .owner else {
                throw DeviceFleetError.role
            }
            var accepted: [String: DeviceFleetEnvelope] = [:]
            for (id, envelope) in deliveries {
                do {
                    guard let row = roster.devices.first(where: { $0.id == id }), !roster.revoked.contains(id),
                          let faction = roster.factions.first(where: { $0.id == row.factionID }),
                          faction.kind != .owner || row.role == .sandbox else { throw DeviceFleetError.role }
                    let payload = try envelope.verified(trust: .init(localID: id, primaryID: trust.primaryID,
                        epoch: trust.epoch, pinnedPrimaryKey: trust.pinnedPrimaryKey,
                        kind: row.role == .sandbox ? .sandbox : faction.kind))
                    guard payload.revision == roster.version else { throw DeviceFleetError.replay }
                    accepted[id] = envelope
                } catch { audit("fleet_projection_cache_rejected") }
            }
            var state = try read(); state.deliveries = accepted; try save(state)
        }
    }
    func accept(_ incoming: DeviceFleetEnvelope) throws {
        var envelope = incoming
        try Self.lock.withLock {
            do {
                var state = try read()
                guard var trust = state.trust else { throw DeviceFleetError.signer }
                if envelope.publicKey.isEmpty {
                    guard envelope.handoff == nil,
                          let notice = try JSONDecoder().decode(DeviceFleetPayload.self, from: envelope.body).revocationNotice,
                          notice.targetID == trust.localID else { throw DeviceFleetError.signature }
                    guard let key = state.envelope?.publicKey ?? registry.fleetPublicKey(deviceID: Self.controllerID(trust.pinnedPrimaryKey)) else { throw DeviceFleetError.signer }
                    envelope.publicKey = key
                }
                if envelope.handoff != nil,
                   (try DeviceRegistry.fingerprint(publicKey: envelope.publicKey)) != trust.pinnedPrimaryKey {
                    try acceptRotation(envelope)
                    return
                }
                try recoverAuthority()
                guard let local = try DeviceIdentityStore.readLocal(entry: entry),
                      local.deviceID == trust.localID, local.primaryDeviceID == trust.primaryID,
                      local.epoch == trust.epoch else { throw DeviceFleetError.epoch }
                let payload: DeviceFleetPayload
                do { payload = try envelope.verified(trust: trust) }
                catch let error as DeviceFleetError where [.role, .foreignFleet].contains(error) {
                    // Only a MAIN-signed v2 delivery can reclassify an already enrolled device.
                    // Epoch and primary pin never change; a sandbox never becomes a MAIN member.
                    let candidate = try JSONDecoder().decode(DeviceFleetPayload.self, from: envelope.body)
                    guard candidate.schema == "tatwo.device-fleet.v2", trust.kind != .sandbox else { throw error }
                    if let slice = candidate.slice {
                        guard slice.targetID == trust.localID, slice.faction.kind == .managed else { throw error }
                        trust.kind = .managed
                    } else if let roster = candidate.roster {
                        guard roster.kind(of: trust.localID) == .owner else { throw error }
                        trust.kind = .owner
                    } else { throw error }
                    payload = try envelope.verified(trust: trust)
                }
                if let old = state.envelope {
                    let previous = try old.verified(trust: state.trust!)
                    guard payload.revision > previous.revision else { throw DeviceFleetError.replay }
                    if let before = previous.roster, let after = payload.roster { try after.validateTransition(from: before) }
                }
                try payload.roster?.validateUniqueNames()
                if state.trust?.kind == .owner, trust.kind != .owner {
                    DeviceFleetConnections.closeAll(scope: registry.root.path)
                    state.possiblyConnected = Array(Set((state.possiblyConnected ?? []) + [trust.localID]))
                }
                state.trust = trust
                state.envelope = envelope
                if let roster = payload.roster {
                    state.pending.removeAll { row in roster.devices.contains {
                        $0.id == row.id && $0.clientKeyFingerprint == row.clientKeyFingerprint && $0.hostKeyFingerprint == row.hostKeyFingerprint
                    } }
                }
                if let slice = payload.slice {
                    state.controllerHistory = Array(Set(state.controllerHistory + slice.controllers.map(\.clientKeyFingerprint)))
                }
                try save(state); try reconcile(payload)
                if try pendingConsent() != nil { NotificationCenter.default.post(name: Notification.Name("tatwo.fleet.consent.changed"), object: url.path) }
            } catch { audit(error, fallback: "fleet_rejected"); throw error }
        }
    }
    private func reconciliationFingerprint() -> [String]? {
        let gate = DeviceFleetGate.path(registry: registry)
        var fingerprints: [String] = []
        for file in [url, entry.deviceJSON, registry.url, registry.authorizedKeysURL, registry.knownHostsURL,
                     registry.fleetKnownHostsURL, gate, gate.deletingLastPathComponent(), registry.root.appendingPathComponent("fleet-gate-policy.json")] {
            var info = stat()
            if lstat(file.path, &info) != 0 {
                guard errno == ENOENT else { return nil }
                fingerprints.append("missing"); continue
            }
            let metadata = "\(info.st_mode):\(info.st_uid):\(info.st_gid):" + file.resolvingSymlinksInPath().path
            if file == gate.deletingLastPathComponent(), info.st_mode & S_IFMT == S_IFDIR { fingerprints.append(metadata); continue }
            guard var data = try? DeviceDispatchSafeFile.read(file, limit: 16 * 1024 * 1024) else { return nil }
            if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                // Presence timestamps do not change SSH grants.
                if file == url { object["transferContacts"] = nil }
                data = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? data
            }
            fingerprints.append(metadata + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return fingerprints
    }
    /// sync 可重試完全相同的已接受信封，但外部 accept 始終拒絕舊版／同版。
    func synchronizeEnvelope(_ envelope: DeviceFleetEnvelope) throws {
        try Self.lock.withLock {
        if let reconciled, reconciled.0 == envelope, reconciled.1 == reconciliationFingerprint(), try read().pendingKeyRemoval?.isEmpty != false {
            if let payload = try current(), let trust = try trust() { try closeBeforeCleanup(payload, trust: trust, state: try read()) }
            return
        }
        if try self.envelope() == envelope {
            guard let payload = try current() else { throw DeviceFleetError.signer }
            try reconcile(payload)
        } else { try accept(envelope) }
        }
    }

    /// A local physical acknowledgement clears diagnostics only. Tombstones, permissions,
    /// connection revocation and exhausted cleanup budgets remain in force.
    func confirmConnectionsClosed(ids: [String], generations: [String: UInt64]) throws {
        try Self.lock.withLock {
            var state = try read()
            let acknowledged = Set(ids.filter { state.possiblyConnectedDevices?[$0] == generations[$0] })
            state.possiblyConnected?.removeAll { acknowledged.contains($0) }
            for id in acknowledged { state.possiblyConnectedDevices?[id] = nil }
            try save(state)
            audit("fleet_physical_connection_closure_acknowledged")
        }
    }
    /// Signatures/current-state checks precede this step; transport closure precedes fallible cleanup.
    private func closeBeforeCleanup(_ payload: DeviceFleetPayload, trust: DeviceFleetTrust, state: State) throws {
        if let event = payload.roster?.disconnectAll, event.targets.contains(trust.localID) {
            var state = try read()
            if !(state.consumedDisconnectAll ?? []).contains(event.id) {
                state.consumedDisconnectAll = Array(((state.consumedDisconnectAll ?? []) + [event.id]).suffix(128))
                try save(state)
                if DeviceFleetRevocation.disconnectAllRemoteSessions(userSelected: true) {
                    state = try read(); state.possiblyConnected = []; state.possiblyConnectedDevices = [:]; try save(state)
                    audit("fleet_physical_all_disconnect_applied")
                } else { audit("fleet_physical_all_disconnect_incomplete") }
            }
        }
        if payload.revocationNotice != nil {
            for row in registry.list() { DeviceFleetRevocation.cutOff(row, registry: registry) }
        } else if let roster = payload.roster {
            let localRevoked = roster.revoked.contains(trust.localID)
            let allowed = Set(try incomingControllers(roster, trust: trust).map(\.clientKeyFingerprint))
            for peer in roster.devices where peer.id != trust.localID {
                let revoke = localRevoked || roster.revoked.contains(peer.id)
                let fp = peer.clientKeyFingerprint ?? ""
                if !localRevoked, roster.revoked.contains(peer.id),
                   let active = roster.activeMember(clientFingerprint: fp), active.id != peer.id {
                    // A physically re-paired key belongs to the new active ID. Close only the old ID's registered routes.
                    DeviceFleetConnections.revoke(peer.id, scope: registry.root.path)
                    DeviceFleetConnections.revoke(peer.id)
                    DeviceFleetGate.terminateRegistered(peer.id, registry: registry)
                    continue
                }
                let removed = registry.fleetHasAuthorizedFingerprint(fp) && !allowed.contains(fp)
                let remainsUnrestricted = try roster.usesUnrestrictedKey(from: peer.id, to: trust.localID)
                let narrowed = registry.fleetHasUnrestrictedFingerprint(fp) && !remainsUnrestricted
                if revoke || removed || narrowed {
                    DeviceFleetRevocation.cutOff(peer, registry: registry, revokeIdentity: revoke)
                }
            }
        } else if let slice = payload.slice {
            let keep = Set(transportControllers(slice.controllers, state: state, payload: payload).map { Self.controllerID($0.clientKeyFingerprint) })
            for row in registry.list() where slice.revoked || !keep.contains(row.id) {
                DeviceFleetConnections.close(row.id, scope: registry.root.path)
                DeviceFleetRevocation.cutOff(row, registry: registry,
                    revokeIdentity: slice.revoked || (slice.revokedKeys ?? []).contains(row.pinnedClientKeyFingerprint ?? ""))
            }
        }
    }
    func reconcile(_ payload: DeviceFleetPayload) throws {
        try Self.lock.withLock {
        reconciled = nil
        var finished = false
        defer {
            if finished, let envelope = try? self.envelope(), let fingerprint = reconciliationFingerprint() { reconciled = (envelope, fingerprint) }
        }
        let state = try read()
        guard let trust = state.trust else { throw DeviceFleetError.signer }
        // The supplied payload must be the signed current state, even for restart reconciliation.
        guard try state.envelope?.verified(trust: trust) == payload else { throw DeviceFleetError.replay }
        try closeBeforeCleanup(payload, trust: trust, state: state)
        // W232c (lead): retry pending manual-key removal only after transports are closed; a failed retry never blocks this round.
        if payload.revocationNotice == nil, payload.slice?.revoked != true, payload.roster?.revoked.contains(trust.localID) != true {
            let pending = try read()
            for (fp, row) in pending.pendingKeyRemoval ?? [:] where (pending.revokedKeys ?? []).contains(fp) {
                do { try registry.revokeAuthorizedKey(deviceID: row.deviceID, fingerprint: fp, retry: true) }
                catch { audit("authorized_keys_pending_retry_failed") }
            }
        }
        try applyRePairVersions(payload.roster?.rePairVersions ?? payload.slice?.rePairVersions ?? [:])
        if let notice = payload.revocationNotice {
            guard notice.targetID == trust.localID else { throw DeviceFleetError.role }
            try rememberRevokedKeys(registry.list().compactMap(\.pinnedClientKeyFingerprint) + (try read().controllerHistory))
            var gateFailure: Error?
            do { try DeviceFleetGate.publish(registry: registry, controllers: [:]) } catch { gateFailure = error }
            try registry.fleetReconcileKeys([], preserveLegacy: [], pending: [])
            if let gateFailure { throw gateFailure }
            finished = true; return
        }
        if let roster = payload.roster {
            let localRevoked = roster.revoked.contains(trust.localID)
            let reenrolled = Set(roster.devices.filter { !roster.revoked.contains($0.id) }.compactMap { registry.fleetClientFingerprint($0) })
            try rememberRevokedKeys(roster.devices.filter { localRevoked || (roster.revoked.contains($0.id) && !reenrolled.contains(registry.fleetClientFingerprint($0) ?? "")) }.compactMap { registry.fleetClientFingerprint($0) }, removeManual: !localRevoked)
            let controllers = try incomingControllers(roster, trust: trust)
            let allowed = Set(controllers.map(\.clientKeyFingerprint))
            let policy = Dictionary(uniqueKeysWithValues: controllers.map { controller in
                (roster.activeMember(clientFingerprint: controller.clientKeyFingerprint)!.id, controller)
            })
            var gateFailure: Error?
            do { try DeviceFleetGate.publish(registry: registry, controllers: policy) } catch { gateFailure = error; audit("fleet_gate_publish_failed") }
            let pending = try read().pending
            let mainGroupID = roster.groups.first { $0.type == .main }!.id
            var keys: [(String, String)] = []
            for peer in roster.devices where peer.id != trust.localID {
                if roster.revoked.contains(peer.id) || localRevoked {
                    try registry.removeAuthorizedKey(deviceID: peer.id)
                    try? registry.fleetUnpinHost(peer)
                    continue
                }
                if let fp = peer.clientKeyFingerprint, allowed.contains(fp), let key = peer.clientPublicKey {
                    // An untrusted helper must never remain the executable behind a restricted row.
                    // Preserve only already unrestricted, still-full MAIN owner grants until repair.
                    let remainsUnrestricted = try roster.usesUnrestrictedKey(from: peer.id, to: trust.localID)
                    if gateFailure == nil || (remainsUnrestricted && registry.fleetHasUnrestrictedFingerprint(fp)) {
                        keys.append((peer.id, key))
                    }
                } else {
                    try registry.removeAuthorizedKey(deviceID: peer.id)
                }
                try pinOrMark(peer)
            }
            try registry.fleetReconcileKeys(keys, preserveLegacy: Set(try roster.devices.filter { row in
                guard row.legacy, !roster.revoked.contains(row.id), !localRevoked,
                      roster.kind(of: trust.localID) == .owner, roster.kind(of: row.id) == .owner else { return false }
                return try !roster.capabilities(from: row.id, to: trust.localID).isEmpty
            }.map(\.id)), pending: [], denied: Set(roster.devices.filter {
                !allowed.contains($0.clientKeyFingerprint ?? "") || localRevoked
            }.compactMap(\.clientKeyFingerprint)).union(pending.filter {
                $0.groupID != mainGroupID || $0.role == .sandbox
            }.compactMap(\.clientKeyFingerprint)), unrestricted: Set(roster.devices.filter {
                roster.kind(of: trust.localID) == .owner && roster.kind(of: $0.id) == .owner
                    && Set((try? roster.capabilities(from: $0.id, to: trust.localID)) ?? []) == Set(DeviceFleetCapabilities.all)
            }.map(\.id)))
            try closeBeforeCleanup(payload, trust: trust, state: state)
            if let gateFailure { throw gateFailure }
        } else if var slice = payload.slice {
            slice.controllers = transportControllers(slice.controllers, state: state, payload: payload)
            // Historical signed projections may contain colleague controllers; fifth ruling removes them locally immediately.
            let colleagueKeys = Set(slice.devices.filter { $0.id != trust.localID }.compactMap(\.clientKeyFingerprint))
            slice.controllers.removeAll { colleagueKeys.contains($0.clientKeyFingerprint) }
            try rememberRevokedKeys(slice.revokedKeys ?? [], removeManual: !slice.revoked)
            var keys = slice.controllers.map { controller in
                (Self.controllerID(controller.clientKeyFingerprint), controller.clientPublicKey)
            }
            var gateFailure: Error?
            do { try DeviceFleetGate.publish(registry: registry, controllers: Dictionary(uniqueKeysWithValues: zip(keys.map(\.0), slice.controllers))) }
            catch { gateFailure = error; audit("fleet_gate_publish_failed"); keys.removeAll() }
            let removedControllers = Set(try read().controllerHistory).subtracting(slice.controllers.map(\.clientKeyFingerprint))
            let denied = removedControllers
                .union(slice.devices.compactMap(\.clientKeyFingerprint).filter { fp in
                    !slice.controllers.contains { $0.clientKeyFingerprint == fp }
                })
            try registry.fleetReconcileKeys(keys, preserveLegacy: [], pending: [], denied: denied)
            for row in registry.list() where removedControllers.contains(row.pinnedClientKeyFingerprint ?? "") || (slice.revokedKeys ?? []).contains(row.pinnedClientKeyFingerprint ?? "") {
                DeviceFleetRevocation.cutOff(row, registry: registry, revokeIdentity: (slice.revokedKeys ?? []).contains(row.pinnedClientKeyFingerprint ?? ""))
            }
            let keep = Set(keys.map(\.0))
            for row in registry.list() where !keep.contains(row.id) {
                DeviceFleetConnections.close(row.id, scope: registry.root.path)
                DeviceFleetRevocation.cutOff(row, registry: registry, revokeIdentity: false)
                // Remove obsolete peer endpoints as well as anonymous controller records.
                if let fp = row.hostKeyFingerprint { try registry.fleetUnpinHost(.init(id: row.id,
                    name: row.name, factionID: slice.faction.id, role: .secondary,
                    clientKeyFingerprint: row.clientKeyFingerprint, hostKeyFingerprint: fp,
                    clientPublicKey: nil, hostPublicKey: registry.fleetHostPublicKey(fingerprint: fp),
                    endpoints: row.endpoints, user: row.user, legacy: true)) }
                try registry.remove(id: row.id)
            }
            for controller in slice.controllers {
                let id = Self.controllerID(controller.clientKeyFingerprint)
                _ = try registry.add(DeviceRecord(id: id, name: slice.faction.managerDisplayName, host: "",
                    user: "user", sshPort: 22, publicKeyFingerprint: controller.clientKeyFingerprint,
                    addedAt: Date(), lastSeenAt: Date(), workdirMap: [:], endpoints: [],
                    clientKeyFingerprint: controller.clientKeyFingerprint))
            }
            if slice.revoked { DeviceFleetConnections.revokeAll(scope: registry.root.path) }
            if let gateFailure { throw gateFailure }
        }
        var cleanup = try read()
        for fp in cleanup.pendingKeyRemoval?.keys ?? Dictionary<String, KeyRemoval>().keys { cleanup.pendingKeyRemoval?[fp]?.lines = try registry.authorizedUserLines(fingerprint: fp) }
        if cleanup.pendingKeyRemoval?.isEmpty == false { try save(cleanup) }
        finished = true
    }
    }
    static func controllerID(_ fingerprint: String) -> String {
        "controller-" + String(fingerprint.dropFirst(7)).replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
    func requestLeave() throws {
        try Self.lock.withLock {
            var state = try read()
            guard let kind = state.trust?.kind, kind != .owner else { throw DeviceFleetError.role }
            state.leaving = true; state.consentCeiling = [:]; try save(state)
            if let payload = try current() { try reconcile(payload) }
            audit("fleet_leave_requested")
        }
    }
    func leaveRequested() throws -> Bool { try Self.lock.withLock { try read().leaving } }
    /// Local delivery diagnostics contain fixed reason codes, never peer-controlled text.
    func recordDeliveryProblem(_ id: String, error: Error?, revision: UInt64? = nil) throws {
        try Self.lock.withLock {
            // A result from an older in-flight projection cannot describe the current one.
            if let revision, try current()?.revision != revision { return }
            var state = try read(), rows = state.deliveryProblems ?? [:]
            if let error {
                let reason: String
                if (error as? DeviceFleetGate.CallError) == .unreachable { reason = "unreachable" }
                else if (error as? DeviceFleetGate.CallError) == .appUnavailable { reason = "app_unavailable" }
                else if (error as? DeviceFleetGate.CallError) == .clockMismatch { reason = "clock_mismatch" }
                else if (error as? DeviceFleetGate.CallError) == .refused { reason = "projection_refused" }
                else if Self.isProjectionRefusal(error) || DeviceFleetReason.unsupportedMethods.contains(DeviceFleetReason.code(error) ?? "") { reason = "projection_refused" }
                else { reason = "delivery_failed" }
                if state.revocationDeliveries?[id]?.stopped == true { rows[id] = nil }
                else if try current()?.roster?.revoked.contains(id) == true, state.revocationDeliveries?[id]?.delivered != true {
                    rows[id] = "revocation_pending"
                } else if error is DeviceFleetError {
                    rows[id] = nil
                } else { rows[id] = reason }
            } else { rows[id] = nil }
            let members = Set(try current()?.roster?.devices.map(\.id) ?? [])
            state.deliveryProblems = rows.filter { members.contains($0.key) }
            try save(state)
        }
    }
    private static func isProjectionRefusal(_ error: Error) -> Bool {
        return DeviceFleetReason.projectionRefusals.contains(DeviceFleetReason.code(error) ?? "")
    }
    static func deliveryWarnings(roster: DeviceFleetRoster?, problems: [String: String], includeRevocations: Bool = true) -> [String: String] {
        guard let roster else { return [:] }
        return Dictionary(uniqueKeysWithValues: roster.devices.compactMap { row -> (String, String)? in
            let label = "「" + DeviceFleetName.label(row, groups: roster.groups) + "」"
            let line: String?
            switch problems[row.id] {
            case "revocation_pending": line = includeRevocations && roster.canRestore(row.id)
                ? label + "還沒收到撤銷；若仍持有這台，請打開它的 App。若已遺失這台，請在私訊框請 TATWO 助理「不再追蹤這台」。" : nil
            case "clock_mismatch": line = label + "兩台時間不一致，請開啟自動設定日期與時間"
            case "projection_refused": line = label + "尚未收到新版權限：這台的 App 需要更新才能收新版權限。"
            default: line = nil
            }
            return line.map { (row.id, $0) }
        })
    }
    func recordManagedDelivery(_ id: String, removed: Bool, revision: UInt64? = nil) throws {
        try Self.lock.withLock {
            if let revision, try current()?.revision != revision { return }
            var state = try read()
            if removed, !state.managedRemoved.contains(id) { state.managedRemoved.append(id) }
            state.deliveryProblems?[id] = nil
            try save(state)
        }
    }
    func pendingManagedRemoval() throws -> [String] {
        let removed = try Self.lock.withLock { try read().managedRemoved }
        guard let roster = try current()?.roster else { return [] }
        return roster.devices.filter { row in
            (roster.groups.first(where: { $0.id == row.groupID })?.type == .sub || row.role == .sandbox)
                && roster.revoked.contains(row.id) && !removed.contains(row.id)
        }.map(\.id)
    }
    func recordLeaveRequest(_ id: String) throws {
        try Self.lock.withLock {
            var state = try read()
            if !state.leaveRequests.contains(id) { state.leaveRequests.append(id) }
            try save(state); audit("fleet_leave_awaiting_owner_approval")
        }
    }
    func leaveRequests() throws -> [String] { try Self.lock.withLock { try read().leaveRequests } }
    func managedRemovalReceipts() throws -> [String] { try Self.lock.withLock { try read().managedRemoved } }
    func confirmTransfer(_ id: String) throws {
        try Self.lock.withLock {
            try requireOwner(); var state = try read()
            if !state.confirmations.contains(id) { state.confirmations.append(id) }; try save(state)
        }
    }
    func checkTransfer(from: String, to: String, confirmation: String? = nil) throws {
        try requireOwnerMember(from); try requireOwnerMember(to)
        guard let trust = try trust() else { return } // W83 升級前原檢查全部照舊。
        let claim = try read().rotation?.handoff.claim
        guard from == trust.primaryID || (claim?.from == from && claim?.to == to) else { audit("fleet_transfer_not_primary"); throw DeviceFleetError.signer }
        if trust.localID == to, let confirmation, !(try read().confirmations.contains(confirmation)) {
            audit("fleet_transfer_confirmation_required"); throw DeviceFleetError.confirmationRequired
        }
    }
    /// A prepared journal (and, for commit, a new-primary signature) is mandatory.
    func requireTransferReady() throws {
        if try trust() != nil, try read().rotation == nil {
            audit("fleet_transfer_confirmation_required")
            throw DeviceFleetError.transferNotReady
        }
    }
    func requireTransferSignature(_ record: PrimaryTransferState.Record, proof: DeviceFleetTransferProof?) throws {
        guard let trust = try trust() else { return }
        let rotation = try read().rotation
        let claim = try rotation?.handoff.claim
        let resuming = claim?.id == record.id
        let oldPin = resuming ? claim!.oldKey : trust.pinnedPrimaryKey
        let oldPrimary = resuming ? claim!.from : trust.primaryID
        guard resuming || (record.from == trust.primaryID && record.oldEpoch == trust.epoch),
              let proof, proof.body.count <= 2 * 1024 * 1024, proof.signature.count < 8192,
              proof.body == (try DeviceFleetTransferProof.bytes(record)),
              try DeviceRegistry.fingerprint(publicKey: proof.publicKey) == oldPin,
              record.from == oldPrimary,
              DeviceSignature.verify(body: proof.body, signature: proof.signature, publicKey: proof.publicKey,
                                     namespace: DeviceFleetTransferProof.namespace) else {
            audit("fleet_transfer_signature_refused"); throw DeviceFleetError.signature
        }
    }
}

/// 窄的公鑰／名單儲存器：不跟隨 symlink；限大小、0600、原子替換。
enum DeviceDispatchSafeFile {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DeviceFleetError.malformed }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            throw DeviceFleetError.malformed
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }
    static func write(_ data: Data, url: URL) throws {
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw DeviceFleetError.localStorageFailed }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { throw DeviceFleetError.malformed }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".fleet-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DeviceFleetError.localStorageFailed
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard rename(temp.path, url.path) == 0 else { throw DeviceFleetError.localStorageFailed }
    }
}
