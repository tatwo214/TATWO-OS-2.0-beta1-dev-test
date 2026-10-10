import Foundation

enum DeviceFleetGroupType: String, Codable, Sendable { case main = "MAIN", sub = "SUB" }

struct DeviceFleetGroup: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var type: DeviceFleetGroupType
    /// Empty only for a SUB that MAIN has not designated. MAIN always has one primary.
    var primaryDeviceID: String
    var parentGroupID: String?
    var showMainPrimary: Bool = false
    var managerDisplayName: String

    enum CodingKeys: String, CodingKey {
        case id, name, type, primaryDeviceID, parentGroupID, showMainPrimary, managerDisplayName
    }
    init(id: String, name: String, type: DeviceFleetGroupType, primaryDeviceID: String,
         parentGroupID: String? = nil, showMainPrimary: Bool = false, managerDisplayName: String) {
        self.id = id; self.name = name; self.type = type; self.primaryDeviceID = primaryDeviceID
        self.parentGroupID = parentGroupID; self.showMainPrimary = showMainPrimary
        self.managerDisplayName = managerDisplayName
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  type: try c.decode(DeviceFleetGroupType.self, forKey: .type),
                  primaryDeviceID: try c.decode(String.self, forKey: .primaryDeviceID),
                  parentGroupID: try c.decodeIfPresent(String.self, forKey: .parentGroupID),
                  showMainPrimary: try c.decodeIfPresent(Bool.self, forKey: .showMainPrimary) ?? false,
                  managerDisplayName: try c.decode(String.self, forKey: .managerDisplayName))
    }
    var faction: DeviceFaction {
        .init(id: id, name: name, kind: type == .main ? .owner : .managed,
              managerDisplayName: managerDisplayName, showPrimaryToMembers: showMainPrimary)
    }
}

/// Typed endpoints avoid a device/group ID collision changing an arrow's meaning.
struct DeviceFleetEndpoint: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case device, group }
    var kind: Kind
    var id: String
    static func device(_ id: String) -> Self { .init(kind: .device, id: id) }
    static func group(_ id: String) -> Self { .init(kind: .group, id: id) }
}

struct DeviceFleetEdge: Codable, Equatable, Sendable {
    enum Direction: String, Codable, Sendable { case mutual, oneway, none }
    var from: DeviceFleetEndpoint
    var to: DeviceFleetEndpoint
    var direction: Direction
    var capabilities: [String]
    var locked: Bool = false
}

enum DeviceFleetCapabilities {
    static let all = ["files", "screen", "dispatch", "update", "memory"]
    static let managed = ["files", "screen", "dispatch", "update"]
    static let sandbox = ["dispatch", "files"]

    /// This is an additional restriction, never a replacement for W178's caller whitelist.
    /// Prefixes cover future members of the existing families; unclassified methods fail closed.
    static let methodTable: [String: String] = {
        var table: [String: String] = [:]
        for method in ["document_inspect", "inbox_target", "list_rooms", "artifacts_list",
                       "os_binding_status", "whoami", "device_status", "list_devices", "overview_snapshot"] { table[method] = "files" }
        for method in ["dispatch_wake", "job_submit", "job_status", "new_thread", "send_message", "send_message_with_options",
                       "stop_thread", "stop_room", "stop_all_rooms", "background_list", "background_status",
                       "run_background", "stop_background", "reclaim_room", "dispatch_rooms"] { table[method] = "dispatch" }
        for method in ["dispatch_fetch", "dispatch_ack"] { table[method] = "fleetTransport" }
        for method in ["app_terminate_for_update"] { table[method] = "update" }
        for method in ["memory_sync_target", "memory_sync_receive", "memory_sync_export", "memory_sync_import", "user_remember", "bot_remember", "bot_get", "bot_profile", "bot_state_get",
                       "bot_state_update", "distill_open", "distill_get", "distill_edit",
                       "distill_write", "distill_remote"] { table[method] = "memory" }
        return table
    }()
    static func isFleetTransport(_ method: String) -> Bool { ["dispatch_fetch", "dispatch_ack"].contains(method) }
    /// Permission surfaces derive their descriptions from the enforced method/family table.
    static let methodDescriptions = ["document_inspect": "看檔案與專案（不寫檔、不含 AI 對話全文）；總覽含對話、目標、背景工作、終端機與待核准項目的標題",
        "new_thread": "開啟管理者自己的工作對話", "send_message": "只向自己建立的對話加話並觸發回覆",
        "stop_thread": "只停止自己建立的對話", "run_background": "派工跑指令、用本機模型帳號讀寫職員檔；須開檔案權限。記憶、App 對話紀錄與終端機轉送須另開記憶權限，執行時仍由職員核准。沒有記憶權限時，不能使用這台的 SSH 金鑰（SSH 的 git、ssh、rsync 不可用）。受管工作不能 commit、clone 或建立 git 版本庫。",
        "app_terminate_for_update": "幫這台安裝更新", "memory_sync_receive": "讀寫這台的記憶",
        "computer_*": "操作畫面（每次記錄、對方看得到）"]
    static let descriptionMethods = ["files": ["document_inspect"],
        "dispatch": ["run_background", "new_thread", "send_message", "stop_thread"],
        "update": ["app_terminate_for_update"], "memory": ["memory_sync_receive"], "screen": ["computer_*"]]
    static let labels: [String: String] = Dictionary(uniqueKeysWithValues: all.map { capability in
        let descriptions = (descriptionMethods[capability] ?? []).filter { method in
            (methodTable[method] ?? requiredFamily(for: method)) == capability
        }.compactMap { methodDescriptions[$0] }
        return (capability, descriptions.joined(separator: "；"))
    })
    static let unrestrictedOwnerExplanation = "MAIN 內五項全開：可以完整登入、讀全部 AI 對話、寫檔與操作助理。"
    static func requiredFamily(for method: String) -> String? {
        if method.hasPrefix("memory_") { return "memory" }
        if method.hasPrefix("computer_") || method.hasPrefix("ipad_") { return "screen" }
        if method.hasPrefix("cli_") || method.hasPrefix("command_") { return "dispatch" }
        return nil
    }
    static func required(for method: String) -> String? {
        return methodTable[method] ?? requiredFamily(for: method)
    }
    static let ownerOnlyMethods: Set<String> = ["get_document", "transcript", "pull_thread", "push_thread", "document_propose",
        "inbox_receive", "select_thread", "assistant_append_offline", "project_proposal_decide", "remote_hands_status", "remote_hands_action", "hands_build", "bot_list", "bot_pending_list"]
    /// File-using native execution needs dispatch and files within the local consent ceiling.
    /// Memory RPC and passive memory remain separately controlled.
    static let nativeExecutionMethods: Set<String> = ["send_message", "send_message_with_options", "run_background",
        "dispatch_rooms", "job_submit", "cli_open", "cli_send", "cli_tail", "background_status", "reclaim_room"]
    static func allowsNativeExecution(_ capabilities: [String]) -> Bool {
        Set(["dispatch", "files"]).isSubset(of: Set(capabilities))
    }
    static func allows(method: String, capabilities: [String]) -> Bool {
        guard let required = required(for: method) else { return false }
        // Existing App terminal servers run outside a thread's inherited policy.
        // Never let a no-memory controller use those servers as a native relay.
        if method.hasPrefix("cli_"), !capabilities.contains("memory") { return false }
        if nativeExecutionMethods.contains(method) || method.hasPrefix("command_") {
            return allowsNativeExecution(capabilities)
        }
        return capabilities.contains(required)
    }
    static func valid(_ values: [String]) -> Bool {
        values.count <= 64 && Set(values).count == values.count && values.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 64 && $0.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0))
            }
        }
    }
}

enum DeviceFleetPublicKey {
    /// SSH comments often contain a machine/account name. Fingerprints and verification use
    /// only algorithm + blob. Never repair malformed multiline or oversized input.
    static func withoutComment(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2048, !trimmed.contains("\n"), !trimmed.contains("\r") else { return value }
        let fields = trimmed.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "ssh-ed25519" else { return value }
        return "\(fields[0]) \(fields[1])"
    }
}

extension DeviceFleetRoster {
    /// Fifth ruling: legacy staff stay unassigned and never gain peer control.
    static func migrate(factions: [DeviceFaction], devices: inout [DeviceFleetMember],
                        primaryID: String) -> (groups: [DeviceFleetGroup], edges: [DeviceFleetEdge]) {
        guard let main = factions.first(where: { $0.kind == .owner }) else { return ([], []) }
        var groups = [DeviceFleetGroup(id: main.id, name: main.name, type: .main, primaryDeviceID: primaryID,
                                      managerDisplayName: main.managerDisplayName)]
        for faction in factions where faction.kind == .managed {
            let members = devices.indices.filter { devices[$0].factionID == faction.id }
            guard !members.isEmpty else { continue }
            groups.append(.init(id: faction.id, name: faction.name, type: .sub,
                                primaryDeviceID: "", parentGroupID: main.id,
                                showMainPrimary: faction.showPrimaryToMembers,
                                managerDisplayName: faction.managerDisplayName))
            for index in members { devices[index].role = .secondary }
        }
        for index in devices.indices where devices[index].role == .sandbox { devices[index].groupID = main.id }
        var edges: [DeviceFleetEdge] = []
        let owners = devices.filter { $0.groupID == main.id && $0.role != .sandbox }
        for (index, left) in owners.enumerated() {
            for right in owners.dropFirst(index + 1) {
                edges.append(.init(from: .device(left.id), to: .device(right.id),
                                   direction: .mutual, capabilities: DeviceFleetCapabilities.all))
            }
        }
        for group in groups where group.type == .sub {
            edges.append(.init(from: .group(main.id), to: .group(group.id),
                               direction: .oneway, capabilities: DeviceFleetCapabilities.managed))
        }
        for row in devices where row.role == .sandbox {
            edges.append(.init(from: .group(main.id), to: .device(row.id),
                               direction: .oneway, capabilities: DeviceFleetCapabilities.sandbox))
        }
        edges += reverseLocks(groups: groups, devices: devices)
        return (groups, edges)
    }

    static func reverseLocks(groups: [DeviceFleetGroup], devices: [DeviceFleetMember]) -> [DeviceFleetEdge] {
        guard let main = groups.first(where: { $0.type == .main }) else { return [] }
        return groups.filter { $0.type == .sub }.map {
            .init(from: .group($0.id), to: .group(main.id), direction: .none, capabilities: [], locked: true)
        } + devices.filter { $0.role == .sandbox }.map {
            .init(from: .device($0.id), to: .group(main.id), direction: .none, capabilities: [], locked: true)
        }
    }

    static func defaults(groups: [DeviceFleetGroup], devices: [DeviceFleetMember]) -> [DeviceFleetEdge] {
        guard let main = groups.first(where: { $0.type == .main }) else { return [] }
        var edges: [DeviceFleetEdge] = []
        for group in groups {
            // Fifth ruling: only MAIN peers interconnect; SUB designation adds no arrows.
            if group.type == .main {
                let members = devices.filter { $0.groupID == group.id && $0.role != .sandbox }
                for (index, left) in members.enumerated() {
                    for right in members.dropFirst(index + 1) {
                        edges.append(.init(from: .device(left.id), to: .device(right.id),
                                           direction: .mutual, capabilities: DeviceFleetCapabilities.all))
                    }
                }
            }
            if group.type == .sub {
                edges.append(.init(from: .group(main.id), to: .group(group.id),
                                   direction: .oneway, capabilities: DeviceFleetCapabilities.managed))
            }
        }
        for row in devices where row.role == .sandbox {
            edges.append(.init(from: .group(main.id), to: .device(row.id),
                               direction: .oneway, capabilities: DeviceFleetCapabilities.sandbox))
        }
        return edges + reverseLocks(groups: groups, devices: devices)
    }

    func members(at endpoint: DeviceFleetEndpoint, includeRevoked: Bool = false) throws -> [DeviceFleetMember] {
        let rows: [DeviceFleetMember]
        switch endpoint.kind {
        case .device:
            guard let member = devices.first(where: { $0.id == endpoint.id }) else { throw DeviceFleetError.unknownMember }
            rows = [member]
        case .group:
            guard groups.contains(where: { $0.id == endpoint.id }) else { throw DeviceFleetError.unknownMember }
            // Sandboxes attach to a group, but never inherit the group's outgoing arrows.
            rows = devices.filter { $0.groupID == endpoint.id && $0.role != .sandbox }
        }
        return rows.filter { includeRevoked || !revoked.contains($0.id) }
    }

    func validateGraph() throws {
        guard groups.count <= 64, edges.count <= 8192,
              Set(groups.map(\.id)).count == groups.count,
              groups.filter({ $0.type == .main }).count == 1,
              let main = groups.first(where: { $0.type == .main }),
              main.primaryDeviceID == primaryID else { throw DeviceFleetError.malformed }
        for group in groups {
            guard !group.id.isEmpty, group.id.utf8.count <= 128, !group.name.isEmpty,
                  group.name.utf8.count <= 256, !group.managerDisplayName.isEmpty,
                  group.managerDisplayName.utf8.count <= 256 else { throw DeviceFleetError.role }
            let primaries = devices.filter { $0.groupID == group.id && $0.role == .primary }
            if group.type == .sub && group.primaryDeviceID.isEmpty {
                guard primaries.isEmpty else { throw DeviceFleetError.role }
            } else {
                guard primaries.count == 1, primaries.first?.id == group.primaryDeviceID else {
                    throw DeviceFleetError.role
                }
            }
            if group.type == .main {
                guard group.parentGroupID == nil else { throw DeviceFleetError.malformed }
            } else {
                var seen: Set<String> = [group.id], parent = group.parentGroupID
                while let id = parent {
                    guard seen.insert(id).inserted, let row = groups.first(where: { $0.id == id }) else {
                        throw DeviceFleetError.malformed
                    }
                    parent = row.parentGroupID
                }
                guard seen.contains(main.id) else { throw DeviceFleetError.malformed }
            }
        }
        for row in devices {
            guard groups.contains(where: { $0.id == row.groupID }), row.role != .managed else {
                throw DeviceFleetError.role
            }
        }
        guard Self.reverseLocks(groups: groups, devices: devices).allSatisfy({ edges.contains($0) }) else {
            throw DeviceFleetError.lockedEdge
        }
        var pairs = Set<String>()
        for edge in edges {
            guard edge.from != edge.to, DeviceFleetCapabilities.valid(edge.capabilities),
                  pairs.insert("\(edge.from.kind):\(edge.from.id)>\(edge.to.kind):\(edge.to.id)").inserted else {
                throw DeviceFleetError.malformed
            }
            let from = try members(at: edge.from, includeRevoked: true)
            let to = try members(at: edge.to, includeRevoked: true)
            guard edge.direction != .none || edge.capabilities.isEmpty else { throw DeviceFleetError.malformed }
            if edge.direction == .none { continue }
            func check(_ sources: [DeviceFleetMember], _ targets: [DeviceFleetMember]) throws {
                for source in sources {
                    guard source.role != .sandbox else { throw DeviceFleetError.reverseEdge }
                    for target in targets where target.id != source.id {
                        if source.groupID != main.id && target.groupID == main.id { throw DeviceFleetError.reverseEdge }
                        if source.role == .primary && source.groupID != main.id && source.groupID != target.groupID {
                            throw DeviceFleetError.subAuthority
                        }
                    }
                }
            }
            try check(from, to)
            if edge.direction == .mutual { try check(to, from) }
        }
    }

    func isStaffInterconnection(_ edge: DeviceFleetEdge) -> Bool {
        func isStaff(_ endpoint: DeviceFleetEndpoint) -> Bool {
            switch endpoint.kind {
            case .group: return groups.contains { $0.id == endpoint.id && $0.type == .sub }
            case .device:
                guard let row = devices.first(where: { $0.id == endpoint.id }), row.role != .sandbox else { return false }
                return groups.contains { $0.id == row.groupID && $0.type == .sub }
            }
        }
        return isStaff(edge.from) && isStaff(edge.to)
    }
    /// Read historical signed bytes unchanged; migrate only the next MAIN-signed revision.
    mutating func removeStaffInterconnections() {
        let historical = self
        edges.removeAll { historical.isStaffInterconnection($0) }
    }

    /// Union of explicitly enabled incoming arrows. `none` adds nothing; it is not a deny override.
    func capabilities(from sourceID: String, to targetID: String) throws -> [String] {
        guard sourceID != targetID, !revoked.contains(sourceID), !revoked.contains(targetID) else { return [] }
        var result = Set<String>()
        for edge in edges where edge.direction != .none && !isStaffInterconnection(edge) {
            let from = try members(at: edge.from).map(\.id), to = try members(at: edge.to).map(\.id)
            if (from.contains(sourceID) && to.contains(targetID))
                || (edge.direction == .mutual && to.contains(sourceID) && from.contains(targetID)) {
                result.formUnion(edge.capabilities)
            }
        }
        return result.sorted()
    }

    /// A MAIN primary and every active MAIN member retain the two signed roster methods, independent of arrows.
    func hasMAINTransport(from source: String, to target: String) -> Bool {
        source != target && kind(of: source) == .owner && kind(of: target) == .owner
            && (source == primaryID || target == primaryID)
    }
    /// Management keeps a signed roster/revocation channel even when every user permission is disconnected.
    func hasManagedTransport(from source: String, to target: String) -> Bool {
        source == primaryID && source != target && kind(of: source) == .owner
            && kind(of: target).map { $0 != .owner } == true
    }
    func usesUnrestrictedKey(from source: String, to target: String, forRevocation: Bool = false) throws -> Bool {
        var graph = self
        if forRevocation { graph.revoked.removeAll { $0 == target || $0 == source } }
        let capabilities = try graph.capabilities(from: source, to: target)
        return graph.kind(of: source) == .owner && graph.kind(of: target) == .owner
            && Set(capabilities) == Set(DeviceFleetCapabilities.all)
    }

    /// Admission appends the newest device identity. Retained revoked rows cannot
    /// issue restoration codes for a key now associated with a later identity.
    func canRestore(_ id: String) -> Bool {
        guard revoked.contains(id), let row = devices.first(where: { $0.id == id }) else { return false }
        let related = devices.filter { candidate in
            candidate.id == id
                || (row.clientKeyFingerprint != nil && candidate.clientKeyFingerprint == row.clientKeyFingerprint)
                || (row.hostKeyFingerprint != nil && candidate.hostKeyFingerprint == row.hostKeyFingerprint)
        }
        return related.allSatisfy { revoked.contains($0.id) } && related.last?.id == id
    }

    func activeMember(clientFingerprint: String) -> DeviceFleetMember? {
        devices.first { $0.clientKeyFingerprint == clientFingerprint && !revoked.contains($0.id) }
    }

    func incoming(to id: String) throws -> [DeviceFleetController] {
        guard let target = devices.first(where: { $0.id == id }), !revoked.contains(id) else { return [] }
        var grants: [String: DeviceFleetController] = [:]
        for edge in edges where edge.direction != .none && !isStaffInterconnection(edge) {
            func collect(_ source: DeviceFleetEndpoint, _ destination: DeviceFleetEndpoint) throws {
                guard try members(at: destination).contains(target) else { return }
                for row in try members(at: source) where row.id != id {
                    guard let fp = row.clientKeyFingerprint, let key = row.clientPublicKey else { continue }
                    let capabilities = Set(grants[fp]?.capabilities ?? []).union(edge.capabilities).sorted()
                    grants[fp] = .init(clientKeyFingerprint: fp, clientPublicKey: key, capabilities: capabilities)
                }
            }
            try collect(edge.from, edge.to)
            if edge.direction == .mutual { try collect(edge.to, edge.from) }
        }
        for row in devices where hasMAINTransport(from: row.id, to: id) || hasManagedTransport(from: row.id, to: id) {
            guard let fp = row.clientKeyFingerprint, let key = row.clientPublicKey else { continue }
            if grants[fp] == nil { grants[fp] = .init(clientKeyFingerprint: fp, clientPublicKey: key, capabilities: []) }
        }
        return grants.values.sorted { $0.clientKeyFingerprint < $1.clientKeyFingerprint }
    }

    /// Joining MAIN is an authority operation, not an arrow capability.
    func requireMAINEnrollment(actor: String, device: String) throws {
        guard kind(of: actor) == .owner, let row = devices.first(where: { $0.id == device }),
              row.role != .sandbox, !revoked.contains(device) else { throw DeviceFleetError.reverseEnrollment }
    }

    func validateTransition(from previous: Self) throws {
        for sandbox in previous.devices where sandbox.role == .sandbox {
            if devices.contains(where: {
                ($0.id == sandbox.id || ($0.clientKeyFingerprint != nil && $0.clientKeyFingerprint == sandbox.clientKeyFingerprint))
                    && $0.role != .sandbox
            }) { throw DeviceFleetError.reverseEnrollment }
        }
    }
}

enum DeviceFleetChange: Equatable, Sendable {
    case renameGroup(id: String, name: String)
    case renameDevice(id: String, name: String)
    case addGroup(DeviceFleetGroup, primary: DeviceFleetMember)
    case moveDevice(id: String, groupID: String)
    case setEdge(DeviceFleetEdge)
    case setSubPrimary(groupID: String, deviceID: String?)
    case setVisibility(groupID: String, showMainPrimary: Bool)
    case setManagerDisplayName(groupID: String, name: String)
    case addSandbox(DeviceFleetMember)
    case revoke(id: String)
    case stopTracking(id: String)
    case transfer(to: String)
}

struct DeviceFleetPendingChange: Equatable, Sendable {
    let id: UUID
    let baseVersion: UInt64
    let actor: String
    let changes: [DeviceFleetChange]
    let preview: DeviceFleetRoster
}

enum DeviceFleetGraphService {
    /// Pure proposal: no signing, persistence or authorization side effects.
    static func propose(roster: DeviceFleetRoster, actor: String,
                        changes: [DeviceFleetChange]) throws -> DeviceFleetPendingChange {
        try roster.validate()
        guard roster.kind(of: actor) == .owner, !roster.revoked.contains(actor), !changes.isEmpty, changes.count <= 64 else {
            throw DeviceFleetError.managedLocked
        }
        var next = roster
        next.disconnectAll = nil
        next.removeStaffInterconnections()
        for change in changes {
            switch change {
            case let .renameGroup(id, name):
                guard let index = next.groups.firstIndex(where: { $0.id == id }) else { throw DeviceFleetError.unknownMember }
                next.groups[index].name = name
            case let .renameDevice(id, name):
                guard let index = next.devices.firstIndex(where: { $0.id == id }) else { throw DeviceFleetError.unknownMember }
                next.devices[index].name = name
            case let .addGroup(group, primary):
                guard actor == next.primaryID, group.type == .sub, !next.groups.contains(where: { $0.id == group.id }),
                      !next.devices.contains(where: { $0.id == primary.id }),
                      primary.groupID == group.id,
                      (group.primaryDeviceID.isEmpty && primary.role == .secondary)
                        || (group.primaryDeviceID == primary.id && primary.role == .primary) else { throw DeviceFleetError.role }
                next.groups.append(group); next.devices.append(primary)
                let defaults = DeviceFleetRoster.defaults(groups: next.groups, devices: next.devices)
                next.edges += defaults.filter {
                    $0.from == .group(group.id) || $0.to == .group(group.id)
                }
            case let .moveDevice(id, groupID):
                guard let index = next.devices.firstIndex(where: { $0.id == id }),
                      let group = next.groups.first(where: { $0.id == groupID }),
                      next.devices[index].role != .primary else { throw DeviceFleetError.role }
                if group.type == .sub, next.kind(of: id) == .owner { throw DeviceFleetError.reverseEnrollment }
                if group.type == .main {
                    guard next.kind(of: id) == .owner else { throw DeviceFleetError.reverseEnrollment }
                    try next.requireMAINEnrollment(actor: actor, device: id)
                }
                guard next.devices[index].role != .sandbox else { throw DeviceFleetError.reverseEnrollment }
                next.devices[index].groupID = groupID
                // Remove old device arrows (except system locks); never keep accidental access on a move.
                next.edges.removeAll { !$0.locked && ($0.from == .device(id) || $0.to == .device(id)) }
                next.edges += DeviceFleetRoster.defaults(groups: next.groups, devices: next.devices).filter {
                    !$0.locked && ($0.from == .device(id) || $0.to == .device(id))
                }
            case let .setSubPrimary(groupID, deviceID):
                guard actor == next.primaryID else { throw DeviceFleetError.primaryRequired }
                guard let index = next.groups.firstIndex(where: { $0.id == groupID && $0.type == .sub }) else {
                    throw DeviceFleetError.role
                }
                if let deviceID {
                    guard next.devices.contains(where: { $0.id == deviceID && $0.groupID == groupID
                        && $0.role != .sandbox && !next.revoked.contains($0.id) }) else { throw DeviceFleetError.role }
                }
                next.groups[index].primaryDeviceID = deviceID ?? ""
                for i in next.devices.indices where next.devices[i].groupID == groupID && next.devices[i].role != .sandbox {
                    next.devices[i].role = next.devices[i].id == deviceID ? .primary : .secondary
                }
            case let .setEdge(edge):
                guard !next.isStaffInterconnection(edge) else { throw DeviceFleetError.staffPeersUnavailable }
                if let old = next.edges.first(where: { $0.from == edge.from && $0.to == edge.to }), old.locked {
                    guard old == edge else { throw DeviceFleetError.lockedEdge }
                }
                guard !edge.locked || next.edges.contains(edge) else { throw DeviceFleetError.lockedEdge }
                next.edges.removeAll { $0.from == edge.from && $0.to == edge.to }; next.edges.append(edge)
            case let .setVisibility(groupID, show):
                guard let index = next.groups.firstIndex(where: { $0.id == groupID && $0.type == .sub }) else {
                    throw DeviceFleetError.role
                }
                next.groups[index].showMainPrimary = show
            case let .setManagerDisplayName(groupID, name):
                guard let index = next.groups.firstIndex(where: { $0.id == groupID }) else {
                    throw DeviceFleetError.unknownMember
                }
                next.groups[index].managerDisplayName = name
            case let .addSandbox(member):
                guard member.role == .sandbox, !next.devices.contains(where: { $0.id == member.id }) else {
                    throw DeviceFleetError.role
                }
                next.devices.append(member)
                next.edges += DeviceFleetRoster.defaults(groups: next.groups, devices: next.devices).filter {
                    $0.from == .device(member.id) || $0.to == .device(member.id)
                }
            case let .revoke(id):
                guard actor == next.primaryID, id != next.primaryID,
                      next.devices.contains(where: { $0.id == id }) else { throw DeviceFleetError.role }
                if !next.revoked.contains(id) { next.revoked.append(id) }
            case let .stopTracking(id):
                guard actor == next.primaryID, next.revoked.contains(id) else { throw DeviceFleetError.role }
            case let .transfer(to):
                guard actor == next.primaryID, next.kind(of: to) == .owner else { throw DeviceFleetError.role }
                // A preview may include a transfer request, never a pre-emptive authority mutation.
            }
        }
        next.normalizeNames()
        try next.validate()
        try next.validateUniqueNames()
        return .init(id: UUID(), baseVersion: roster.version, actor: actor, changes: changes, preview: next)
    }
}
