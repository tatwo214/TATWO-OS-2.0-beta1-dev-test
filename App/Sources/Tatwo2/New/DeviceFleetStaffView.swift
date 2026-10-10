import SwiftUI

/// MAIN metadata can only enter this view through the opt-in projection field.
struct DeviceFleetStaffView: View {
    let snapshot: DeviceFleetUISnapshot
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("由「\(snapshot.manager ?? "管理者")」管理").font(.headline)
            if let primary = snapshot.visibleMain {
                VStack(alignment: .leading, spacing: 6) {
                    DeviceFleetPrimaryDisplayCard(primary: primary)
                }
            }
            Text(DeviceFleetDefaults.staffRoleExplanation).font(.caption).foregroundStyle(.secondary)
            Text("管理者可以對這台做的事").font(.subheadline.weight(.semibold))
            ForEach(Array(snapshot.controllerPermissionLines.enumerated()), id: \.offset) { _, line in Text(line).font(.caption) }
            Button("申請離開／退出管理") {
                try? DeviceFlowSession.shared.open(.menu)
                GlobalDMStore.shared.select(.assistant); GlobalDMStore.shared.openDocked()
            }
            Text("自己群組的設備樹").font(.caption).foregroundStyle(.secondary)
            DeviceFleetGraphView(snapshot: snapshot)
        }.padding(16)
            .background(DeviceFleetStyle.surface(scheme).opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DeviceFleetPrimaryDisplayCard: View {
    let primary: DeviceFleetPrimaryDisplay
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack {
            Text(primary.name).font(.system(size: 13, weight: .semibold))
            DeviceFleetBadge(title: "管理者的主設備 · MAIN", color: DeviceFleetStyle.terra)
        }.padding(12)
            .background(DeviceFleetStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
    }
}
