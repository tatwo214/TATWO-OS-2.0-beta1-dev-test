import SwiftUI

struct DeviceFleetListView: View {
    let snapshot: DeviceFleetUISnapshot
    var toolbar = false
    var initiallyExpanded: String? = nil
    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(snapshot.groups, id: \.id) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(collapsed.contains(group.id) ? "▸" : "▾") \(group.name)")
                                .font(.system(size: 14, weight: .bold))
                            DeviceFleetBadge(title: snapshot.relationship(group), color: group.type == .main ? DeviceFleetStyle.green : DeviceFleetStyle.terra)
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(group.name)；展開或收合")
                    if group.type == .sub { Text(DeviceFleetDefaults.staffRoleExplanation).font(.caption).foregroundStyle(.secondary) }
                    if !collapsed.contains(group.id) {
                        ForEach(snapshot.devices.filter { $0.groupID == group.id && $0.role != .sandbox }, id: \.id) { device in
                            row(device)
                        }
                    }
                }
            }
            if toolbar { SandboxDevicesSection(snapshot: snapshot) }
        }
    }

    private func row(_ device: DeviceFleetMember) -> some View {
        let isExpanded = expanded.contains(device.id) || initiallyExpanded == device.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded.contains(device.id) { expanded.remove(device.id) } else { expanded.insert(device.id) }
            } label: {
                HStack(spacing: 10) {
                    if toolbar { Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9)) }
                    Circle().fill(snapshot.online(device) ? DeviceFleetStyle.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    if device.id == snapshot.localID { Text("（這台）").font(.caption2) }
                    Spacer(minLength: 4)
                    DeviceFleetBadge(title: snapshot.role(device), color: device.role == .primary ? DeviceFleetStyle.terra : .secondary)
                    Text(snapshot.version(device) ?? snapshot.connectionLabel(device))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("fleet-row-\(device.id)").accessibilityHint("展開版本、連線路徑與簽章狀態")
            if snapshot.pinConflicts.contains(device.id) {
                Text("這台的身分跟你電腦記得的不一樣，暫不自動信任").font(.caption).foregroundStyle(DeviceFleetStyle.terra)
            }
            if let warning = snapshot.deliveryWarnings[device.id] {
                Text(warning).font(.caption).foregroundStyle(DeviceFleetStyle.terra)
                    .accessibilityIdentifier("fleet-delivery-warning-\(device.id)")
            }
            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("版本：\(snapshot.version(device) ?? "尚未取得")")
                    Text("連線：\(snapshot.connectionLabel(device))")
                    if !snapshot.isStaff {
                        Text("連線路徑：\(device.endpoints.isEmpty ? "尚未取得" : device.endpoints.map(\.label).joined(separator: "、"))")
                    }
                    Text("簽章狀態：\(snapshot.signature)")
                    Text("設備簽章識別：\(device.clientKeyFingerprint ?? "尚未取得")")
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(DeviceFleetStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2)))
    }
}
