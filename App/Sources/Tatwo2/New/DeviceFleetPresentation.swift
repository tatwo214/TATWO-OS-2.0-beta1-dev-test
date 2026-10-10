import SwiftUI

/// A presentation copy of the verified graph. Registry entries only supply status/routes,
/// never membership or names. A filtered slice never falls back to the full registry.
struct DeviceFleetUISnapshot {
    var groups: [DeviceFleetGroup] = []
    var devices: [DeviceFleetMember] = []
    var edges: [DeviceFleetEdge] = []
    var localID = ""
    var manager: String?
    var visibleMain: DeviceFleetPrimaryDisplay?
    var isStaff = false
    var controllerPermissionLines: [String] = []
    var pendingDeliveryLines: [String] = []
    var deliveryWarnings: [String: String] = [:]
    var signature = "尚未取得已驗章名單"
    var problem: String?
    var pinConflicts: Set<String> = []
    var status: [String: DeviceStatusProbe] = [:]
    var sandboxStatus: [String: String] = [:]

    init(payload: DeviceFleetPayload? = nil, localID: String = "", consentCeiling: [String: [String]] = [:], deliveryProblems: [String: String] = [:]) {
        self.localID = localID
        guard let payload else { return }
        signature = "名單簽章已驗證"
        if let slice = payload.slice {
            isStaff = true
            manager = slice.group?.managerDisplayName ?? slice.faction.managerDisplayName
            var effective = slice
            effective.controllers = slice.controllers.map { row in
                var row = row; row.capabilities = row.capabilities.filter { consentCeiling[row.clientKeyFingerprint]?.contains($0) == true }; return row
            }
            controllerPermissionLines = DeviceFleetStore.consentLines(effective)
            guard !slice.revoked else { problem = "這台已移出設備群"; return }
            groups = slice.group.map { [$0] } ?? []
            devices = slice.devices.filter { $0.groupID == slice.faction.id }
            edges = slice.edges ?? []
            if slice.group?.showMainPrimary ?? slice.faction.showPrimaryToMembers {
                visibleMain = slice.primary
            }
        } else if let roster = payload.roster {
            let local = roster.devices.first { $0.id == localID }
            let own = roster.groups.first { $0.id == local?.groupID }
            isStaff = own?.type == .sub || local?.role == .managed || local?.role == .sandbox
            if isStaff {
                manager = own?.managerDisplayName
                groups = local?.role == .sandbox ? [] : own.map { [$0] } ?? []
                devices = roster.devices.filter {
                    !roster.revoked.contains($0.id) && (local?.role == .sandbox ? $0.id == localID
                        : $0.groupID == own?.id && $0.role != .sandbox)
                }
                if local?.role != .sandbox && own?.showMainPrimary == true {
                    visibleMain = roster.devices.first { $0.id == roster.primaryID }.map(DeviceFleetPrimaryDisplay.init)
                }
            } else {
                groups = roster.groups.sorted { $0.type == .main && $1.type != .main }
                devices = roster.devices.filter { !roster.revoked.contains($0.id) }
                if localID == roster.primaryID {
                    let warnings = DeviceFleetStore.deliveryWarnings(roster: roster, problems: deliveryProblems)
                    let visible = Set(devices.map(\.id))
                    deliveryWarnings = warnings.filter { visible.contains($0.key) }
                    pendingDeliveryLines = roster.devices.filter { !visible.contains($0.id) }.compactMap { warnings[$0.id] }
                }
            }
            edges = roster.edges
        }
        let endpoints = Set(devices.map { DeviceFleetEndpoint.device($0.id) }
            + groups.map { DeviceFleetEndpoint.group($0.id) })
        edges = edges.filter { endpoints.contains($0.from) && endpoints.contains($0.to) }
    }

    func name(_ endpoint: DeviceFleetEndpoint) -> String {
        endpoint.kind == .group ? groups.first { $0.id == endpoint.id }?.name ?? "群組"
            : devices.first { $0.id == endpoint.id }.map { DeviceFleetName.label($0, groups: groups) } ?? "設備"
    }
    func role(_ device: DeviceFleetMember) -> String {
        let group = groups.first { $0.id == device.groupID }
        let role = group?.type == .sub ? (device.role == .primary ? "SUB 主設備（指定）" : "職員電腦")
            : device.role == .sandbox ? "沙盒（只能領工、交件）" : device.role == .primary ? "主設備" : "副設備"
        return role + " · " + (group?.name ?? device.groupID) + " · " + (group?.type.rawValue ?? "群組")
    }
    func isMAIN(_ endpoint: DeviceFleetEndpoint) -> Bool {
        let groupID = endpoint.kind == .group ? endpoint.id : devices.first { $0.id == endpoint.id }?.groupID
        return groups.contains { $0.id == groupID && $0.type == .main }
    }
    func online(_ device: DeviceFleetMember) -> Bool {
        guard let probe = status[device.id], DeviceStatusPolicy.fresh(probe.acquiredAt, now: Date()) else { return false }
        return probe.connection.online
    }
    func connectionLabel(_ device: DeviceFleetMember) -> String {
        if device.role == .sandbox { return "只能領工、交件；不開反向存取" }
        guard let probe = status[device.id], DeviceStatusPolicy.fresh(probe.acquiredAt, now: Date()) else { return "尚未確認" }
        if probe.reason == "rpc_proof_expired" { return "兩台時間不一致" }
        return probe.connection.online ? "在線" : "離線"
    }
    func version(_ device: DeviceFleetMember) -> String? {
        guard let probe = status[device.id], DeviceStatusPolicy.fresh(probe.acquiredAt, now: Date()),
              let field = probe.snapshot?.appVersion,
              DeviceStatusPolicy.fresh(field.acquiredAt, now: Date()) else { return nil }
        return field.value
    }
    func relationship(_ group: DeviceFleetGroup) -> String {
        if isStaff && group.type == .sub { return "→ 受管理" }
        let incoming = edges.filter { $0.to == .group(group.id) && $0.direction != .none }
        if incoming.contains(where: { $0.direction == .oneway }) { return "→ 單向管理" }
        if edges.contains(where: { edge in edge.direction == .mutual &&
            devices.contains(where: { $0.groupID == group.id && DeviceFleetEndpoint.device($0.id) == edge.from }) }) { return "↔ 互通" }
        return "依箭頭授權"
    }
}

@MainActor final class DeviceFleetUIModel: ObservableObject {
    @Published private(set) var snapshot = DeviceFleetUISnapshot()
    @Published private(set) var refreshing = false
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let result = await Task.detached(priority: .utility) { () -> Result<DeviceFleetUISnapshot, Error> in
            Result {
                let environment = ProcessInfo.processInfo.environment
                let fleet = DeviceFleetStore(registry: DeviceRegistry(), environment: environment)
                let payload = try fleet.readGraph()
                let id = try DeviceIdentityStore.readLocal()?.deviceID ?? ""
                let state = try fleet.read()
                var graph = DeviceFleetUISnapshot(payload: payload, localID: id, consentCeiling: state.consentCeiling ?? [:],
                                                  deliveryProblems: state.deliveryProblems ?? [:])
                graph.pendingDeliveryLines += try fleet.keyRemovalWarnings()
                graph.pinConflicts = Set((try? DeviceFleetStore(registry: DeviceRegistry(), environment: environment).read().pinConflicts) ?? [])
                if let roster = payload?.roster {
                    for device in graph.devices where device.id != id && (try? roster.usesUnrestrictedKey(from: device.id, to: id)) != true {
                        if let fp = fleet.registry.fleetClientFingerprint(device), let lines = try? fleet.registry.authorizedUserLines(fingerprint: fp), !lines.isEmpty {
                            graph.deliveryWarnings[device.id] = "第 \(lines.map(String.init).joined(separator: "、")) 行是你手動加的，這台仍有完整登入權限"
                        }
                    }
                }
                return graph
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .failure: snapshot = DeviceFleetUISnapshot(); snapshot.problem = "設備名單暫時無法讀取"
        case .success(let graph): snapshot = graph
        }
        for device in snapshot.devices where device.role == .sandbox { snapshot.sandboxStatus[device.id] = HandsService.shared.sandboxLane.status(device.id) }
        let records = await Task.detached { DeviceStatusReader.registry() }.value
        // Query only members visible in this projection, including MAIN solely when opted in.
        for member in snapshot.devices where !snapshot.pinConflicts.contains(member.id) {
            guard !Task.isCancelled else { return }
            let probe: DeviceStatusProbe
            if member.id == snapshot.localID {
                probe = await Task.detached {
                    .init(connection: .local, snapshot: DeviceStatusReader.read(), acquiredAt: Date(), reason: nil)
                }.value
            } else if DeviceFleetStore(registry: DeviceRegistry(), environment: ProcessInfo.processInfo.environment).allowsPeerConnection(member.id), let record = records.first(where: {
                $0.id == member.id || (member.clientKeyFingerprint != nil && $0.clientKeyFingerprint == member.clientKeyFingerprint)
            }) {
                probe = await Task.detached { RemoteHostLink().queryDeviceStatus(device: record) }.value
            } else { continue }
            guard !Task.isCancelled else { return }
            snapshot.status[member.id] = probe
        }
    }
    func observe() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }
}

/// Warm paper themes use their palette; glass themes use tinted surfaces in both appearances.
enum DeviceFleetStyle {
    static let green = Color(red: 0.24, green: 0.48, blue: 0.28)
    static let terra = Color(red: 0.73, green: 0.40, blue: 0.31)
    static func surface(_ scheme: ColorScheme) -> Color {
        if !TatwoActivePalette.current.usesGlass { return TatwoActivePalette.current.surfaceFill }
        return scheme == .dark ? Color(red: 0.19, green: 0.18, blue: 0.23)
            : Color(red: 0.93, green: 0.92, blue: 0.96)
    }
    static func canvas(_ scheme: ColorScheme) -> Color {
        if !TatwoActivePalette.current.usesGlass { return TatwoActivePalette.current.canvasBase }
        return scheme == .dark ? Color(red: 0.11, green: 0.10, blue: 0.14) : TatwoActivePalette.current.canvasBase
    }
}

struct DeviceFleetBadge: View {
    let title: String
    var color: Color = .secondary
    var body: some View {
        Text(title).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}

struct DeviceFleetDeviceCard: View {
    let device: DeviceFleetMember
    let snapshot: DeviceFleetUISnapshot
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(snapshot.online(device) ? DeviceFleetStyle.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if device.id == snapshot.localID { Text("（這台）").font(.caption2) }
            }
            if snapshot.pinConflicts.contains(device.id) {
                Text("這台的身分跟你電腦記得的不一樣，暫不自動信任").font(.caption2).foregroundStyle(DeviceFleetStyle.terra)
            }
            HStack {
                DeviceFleetBadge(title: snapshot.role(device), color: device.role == .primary ? DeviceFleetStyle.terra : .secondary)
                Spacer(minLength: 0)
                Text(snapshot.version(device) ?? snapshot.connectionLabel(device))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(DeviceFleetStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(device.role == .primary ? DeviceFleetStyle.terra.opacity(0.65) : Color.secondary.opacity(0.25)))
    }
}

struct SandboxDeviceStatusView: View {
    let deviceID: String
    let status: String
    var canPair: Bool
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading) {
            Text(status).font(.caption)
            OSChipButton(title: "建立沙盒專用配對") {
                do { try HandsService.shared.sandboxLane.pair(deviceID); problem = nil }
                catch { problem = "只有已啟用關口的主設備能替已登錄沙盒建立專用配對。" }
            }.disabled(!canPair)
            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
