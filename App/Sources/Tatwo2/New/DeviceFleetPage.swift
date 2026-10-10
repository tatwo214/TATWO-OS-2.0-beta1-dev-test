import SwiftUI

struct DeviceFleetPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let snapshot: DeviceFleetUISnapshot
    var openAssistant: () -> Void = {}
    var initialList = false
    var initiallyExpanded: Int? = nil
    @State private var list = false
    @State private var chosen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TatwoSettingsPageHeader(title: "設備", subtitle: "群組、箭頭與權限一覽；點箭頭展開看詳細權限。") {
                if !snapshot.isStaff {
                    HStack(spacing: 4) {
                        tab("關係圖", isList: false)
                        tab("清單", isList: true)
                    }.padding(4).chatGlassChip()
                }
            }
            if let problem = snapshot.problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            ForEach(snapshot.pendingDeliveryLines + ((chosen ? list : initialList) ? [] : snapshot.devices.compactMap { snapshot.deliveryWarnings[$0.id] }), id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(DeviceFleetStyle.terra)
            }
            if snapshot.devices.isEmpty {
                Text("尚未取得設備群名單。加入設備後，群組與權限會顯示在這裡。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            } else if snapshot.isStaff {
                DeviceFleetStaffView(snapshot: snapshot)
            } else if chosen ? list : initialList {
                DeviceFleetListView(snapshot: snapshot)
            } else {
                DeviceFleetGraphView(snapshot: snapshot, initiallyExpanded: initiallyExpanded)
            }
            SandboxDevicesSection(snapshot: snapshot)
            Divider()
            HStack(spacing: 12) {
                Text("要加入設備、調整群組或權限，在私訊框跟 TATWO 助理說。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                OSChipButton(title: "打開私訊框", action: openAssistant)
            }
        }
    }
    private func tab(_ label: String, isList: Bool) -> some View {
        Button { list = isList; chosen = true } label: {
            Text(label).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).frame(height: 28)
                .chatGlassChip(isSelected: (chosen ? list : initialList) == isList)
        }.buttonStyle(.plain).accessibilityIdentifier(isList ? "fleet-tab-list" : "fleet-tab-graph")
    }
}

struct DeviceFleetToolbarContainer: View {
    @StateObject private var fleet = DeviceFleetUIModel()
    var body: some View {
        DeviceFleetToolbarView(snapshot: fleet.snapshot, refreshing: fleet.refreshing,
                               refresh: { Task { await fleet.refresh() } })
            .task { await fleet.observe() }
    }
}

struct DeviceFleetToolbarView: View {
    let snapshot: DeviceFleetUISnapshot
    var refreshing = false
    var refresh: () -> Void = {}
    var initiallyExpanded: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("設備").font(.system(size: 17, weight: .bold))
                Spacer()
                OSChipButton(title: refreshing ? "檢查中…" : "重新檢查", action: refresh).disabled(refreshing)
            }
            if let manager = snapshot.manager { Text("由「\(manager)」管理").font(.caption) }
            if let primary = snapshot.visibleMain {
                DeviceFleetPrimaryDisplayCard(primary: primary).frame(height: 76)
            }
            if let problem = snapshot.problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            ForEach(snapshot.pendingDeliveryLines, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(DeviceFleetStyle.terra)
            }
            if snapshot.devices.isEmpty { Text("尚未取得設備群名單").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                DeviceFleetListView(snapshot: snapshot, toolbar: true, initiallyExpanded: initiallyExpanded)
            }
            Text("點一列查看版本、連線路徑與簽章狀態。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
