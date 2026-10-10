import Foundation
import CoreFoundation

/// Cloud-safe projection. Arbitrary names, keys, endpoints and pairing state never cross this boundary.
@MainActor
enum AssistantFleetTools {
    nonisolated static let methods: Set<String> = ["fleet_overview", "fleet_open_card", "fleet_propose"]
    static let openCards = DeviceFlowKind.allCases.filter { $0 != .progress }.map(\.rawValue)
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    nonisolated static func allows(_ caller: OSSocketCaller) -> Bool {
        if case .engine = caller { return true }
        return false
    }
    static func perform(_ method: String, params: [String: Any], caller: OSSocketCaller,
                        assistantThread: UUID?, session: DeviceFlowSession = .shared,
                        present: (() -> Void)? = nil) throws -> [String: Any] {
        guard allows(caller), let thread = caller.boundThread, thread == assistantThread else {
            throw Failure(reason: "fleet_assistant_required")
        }
        if let supplied = params["callerThreadID"] {
            guard let raw = supplied as? String, UUID(uuidString: raw) == thread else {
                throw Failure(reason: "fleet_assistant_required")
            }
        }
        guard methods.contains(method) else { throw Failure(reason: "fleet_unknown_tool") }
        let parameters = params.filter { $0.key != "callerThreadID" }
        do {
            switch method {
            case "fleet_overview":
                guard parameters.isEmpty else { throw Failure(reason: "fleet_invalid_input") }
                return try overview(session.store.readGraph())
            case "fleet_open_card":
                guard Set(parameters.keys) == ["card"], let raw = parameters["card"] as? String,
                      openCards.contains(raw), let kind = DeviceFlowKind(rawValue: raw) else {
                    throw Failure(reason: "fleet_invalid_input")
                }
                try session.open(kind); present?()
                return ["card": kind.rawValue, "opened": true, "requiresUserAction": true]
            case "fleet_propose":
                guard Set(parameters.keys) == ["baseVersion", "changes"],
                      let version = parameters["baseVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
                      let rows = parameters["changes"] as? [[String: Any]], !rows.isEmpty, rows.count <= 64,
                      let graph = try session.store.readGraph()?.roster,
                      version.stringValue == String(graph.version) else { throw Failure(reason: "fleet_invalid_input") }
                let changes = try rows.map { try parse($0, graph: graph) }
                let pending = try session.propose(changes); present?()
                // The local card has the full human preview; no arbitrary strings are echoed to the model.
                return ["proposalID": pending.id.uuidString, "baseVersion": pending.baseVersion,
                        "changeCount": changes.count, "card": "permissions", "status": "awaiting_user_confirmation",
                        "confirmed": false]
            default: throw Failure(reason: "fleet_unknown_tool")
            }
        } catch let error as Failure { throw error }
        catch DeviceFleetError.staffPeersUnavailable { throw Failure(reason: DeviceFleetDefaults.staffInterconnectionMessage) }
        catch { throw Failure(reason: "fleet_request_refused") }
    }
    static func overview(_ payload: DeviceFleetPayload?) throws -> [String: Any] {
        guard let payload else { return ["state": "not_enrolled", "groups": [], "devices": [], "edges": []] }
        guard let graph = payload.roster else {
            // Projection does not reveal the MAIN ID, version, manager name or controller fingerprints.
            return ["state": "managed", "groups": [["id": "g1", "type": "SUB"]],
                    "deviceCount": payload.slice?.devices.count ?? 0, "writable": false]
        }
        let groups = graph.groups.enumerated().map { index, group -> [String: Any] in
            ["id": "g\(index + 1)", "type": group.type.rawValue,
             "deviceCount": graph.devices.filter { $0.groupID == group.id && !graph.revoked.contains($0.id) }.count,
             "showMainPrimary": group.showMainPrimary,
             "primaryDevice": group.primaryDeviceID.isEmpty ? NSNull() : reference(.device(group.primaryDeviceID), graph: graph)]
        }
        let devices = graph.devices.enumerated().compactMap { index, member -> [String: Any]? in
            guard !graph.revoked.contains(member.id) else { return nil }
            return ["id": "d\(index + 1)", "group": reference(.group(member.groupID), graph: graph),
                    "role": graph.kind(of: member.id) == .managed ? "managed" : member.role.rawValue]
        }
        let edges = graph.edges.map { edge -> [String: Any] in
            ["from": reference(edge.from, graph: graph), "to": reference(edge.to, graph: graph),
             "direction": edge.direction.rawValue, "capabilities": edge.capabilities, "locked": edge.locked]
        }
        return ["state": "enrolled", "baseVersion": graph.version, "groups": groups, "devices": devices,
                "edges": edges, "revokedDevices": graph.devices.enumerated().filter { graph.revoked.contains($0.element.id) }.map { ["id": "d\($0.offset + 1)"] }, "confirmation": "local_card_only"]
    }
    private static func reference(_ endpoint: DeviceFleetEndpoint, graph: DeviceFleetRoster) -> String {
        if endpoint.kind == .group, let index = graph.groups.firstIndex(where: { $0.id == endpoint.id }) { return "g\(index + 1)" }
        if endpoint.kind == .device, let index = graph.devices.firstIndex(where: { $0.id == endpoint.id }) { return "d\(index + 1)" }
        return "unknown"
    }
    private static func endpoint(_ raw: Any?, graph: DeviceFleetRoster, allowRevoked: Bool = false) throws -> DeviceFleetEndpoint {
        guard let raw = raw as? String, raw.count >= 2, let index = Int(raw.dropFirst()), index > 0,
              String(index) == raw.dropFirst() else { throw Failure(reason: "fleet_invalid_reference") }
        if raw.first == "g", graph.groups.indices.contains(index - 1) { return .group(graph.groups[index - 1].id) }
        if raw.first == "d", graph.devices.indices.contains(index - 1), (allowRevoked || !graph.revoked.contains(graph.devices[index - 1].id)) {
            return .device(graph.devices[index - 1].id)
        }
        throw Failure(reason: "fleet_invalid_reference")
    }
    private static func parse(_ row: [String: Any], graph: DeviceFleetRoster) throws -> DeviceFleetChange {
        guard let op = row["op"] as? String else { throw Failure(reason: "fleet_invalid_input") }
        func keys(_ expected: Set<String>) throws {
            guard Set(row.keys) == expected.union(["op"]) else { throw Failure(reason: "fleet_invalid_input") }
        }
        func name() throws -> String {
            guard let value = row["name"] as? String, !DeviceFleetName.clean(value).isEmpty,
                  value.utf8.count <= 4096 else { throw Failure(reason: "fleet_invalid_input") }
            return DeviceFleetName.clean(value)
        }
        switch op {
        case "stop_tracking":
            try keys(["target"])
            let target = try endpoint(row["target"], graph: graph, allowRevoked: true)
            guard target.kind == .device, graph.revoked.contains(target.id) else { throw Failure(reason: "fleet_invalid_reference") }
            return .stopTracking(id: target.id)
        case "revoke_device":
            try keys(["target"])
            let target = try endpoint(row["target"], graph: graph)
            guard target.kind == .device, target.id != graph.primaryID else { throw Failure(reason: "fleet_invalid_reference") }
            return .revoke(id: target.id)
        case "rename_group", "rename_device", "set_manager_name":
            try keys(["target", "name"])
            let target = try endpoint(row["target"], graph: graph), value = try name()
            if op == "rename_device", target.kind == .device { return .renameDevice(id: target.id, name: value) }
            guard target.kind == .group else { throw Failure(reason: "fleet_invalid_reference") }
            return op == "set_manager_name" ? .setManagerDisplayName(groupID: target.id, name: value) : .renameGroup(id: target.id, name: value)
        case "move_device":
            try keys(["target", "group"])
            let target = try endpoint(row["target"], graph: graph), group = try endpoint(row["group"], graph: graph)
            guard target.kind == .device, group.kind == .group else { throw Failure(reason: "fleet_invalid_reference") }
            return .moveDevice(id: target.id, groupID: group.id)
        case "set_visibility":
            try keys(["target", "showMainPrimary"])
            let target = try endpoint(row["target"], graph: graph)
            guard target.kind == .group, let flag = row["showMainPrimary"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw Failure(reason: "fleet_invalid_input") }
            return .setVisibility(groupID: target.id, showMainPrimary: flag.boolValue)
        case "set_sub_primary":
            try keys(["target", "device"])
            let target = try endpoint(row["target"], graph: graph)
            guard target.kind == .group else { throw Failure(reason: "fleet_invalid_reference") }
            if row["device"] is NSNull { return .setSubPrimary(groupID: target.id, deviceID: nil) }
            let device = try endpoint(row["device"], graph: graph)
            guard device.kind == .device else { throw Failure(reason: "fleet_invalid_reference") }
            return .setSubPrimary(groupID: target.id, deviceID: device.id)
        case "set_edge":
            try keys(["from", "to", "direction", "capabilities"])
            guard let raw = row["direction"] as? String, let direction = DeviceFleetEdge.Direction(rawValue: raw),
                  let capabilities = row["capabilities"] as? [String], DeviceFleetCapabilities.valid(capabilities),
                  Set(capabilities).count == capabilities.count else { throw Failure(reason: "fleet_invalid_input") }
            return .setEdge(.init(from: try endpoint(row["from"], graph: graph), to: try endpoint(row["to"], graph: graph),
                                 direction: direction, capabilities: capabilities))
        default: throw Failure(reason: "fleet_invalid_input")
        }
    }
}
