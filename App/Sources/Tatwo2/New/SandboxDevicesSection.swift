import SwiftUI

extension DeviceFleetStore {
    static func registerSandbox(name: String, info: SandboxDeviceInfo) async throws -> DeviceFleetMember {
        try await Task.detached(priority: .utility) {
            let fleet = DeviceFleetStore(registry: DeviceRegistry(), environment: ProcessInfo.processInfo.environment)
            let id = try fleet.addSandbox(name: name, info: info)
            guard let member = try fleet.readGraph()?.roster?.devices.first(where: { $0.id == id }) else { throw DeviceFleetError.primaryRequired }
            return member
        }.value
    }
    func addSandbox(name: String, info: SandboxDeviceInfo) throws -> String {
        try Self.lock.withLock {
            guard let local = try DeviceIdentityStore.readLocal(entry: entry), local.role == .primary,
                  let roster = try readGraph()?.roster, roster.primaryID == local.deviceID,
                  let group = roster.groups.first(where: { $0.type == .main }), info.valid,
                  !DeviceFleetName.clean(name).isEmpty else { throw DeviceFleetError.primaryRequired }
            var member = DeviceFleetMember(id: UUID().uuidString, name: DeviceFleetName.clean(name), factionID: group.id, role: .sandbox,
                clientKeyFingerprint: nil, hostKeyFingerprint: nil, clientPublicKey: nil, hostPublicKey: nil, endpoints: [], user: "user")
            member.sandboxInfo = info
            try approve([member], sender: local.deviceID)
            return member.id
        }
    }
}

struct SandboxDevicesSection: View {
    let snapshot: DeviceFleetUISnapshot
    var initiallyExpanded = false
    @ObservedObject private var hands = HandsState.shared
    @AppStorage("tatwo2.sandbox.Linux.virtual") private var linuxVirtual = false
    @AppStorage("tatwo2.sandbox.macOS.virtual") private var macVirtual = false
    @State private var expanded = false
    @State private var platforms: Set<String> = []
    @State private var added: [DeviceFleetMember] = []
    @State private var adding: String?
    @State private var name = ""
    @State private var source = ""
    @State private var busy = false
    @State private var problem: String?
    var canAdd: Bool { !snapshot.isStaff && snapshot.devices.contains { $0.id == snapshot.localID && $0.role == .primary } }
    private var devices: [DeviceFleetMember] { snapshot.devices + added.filter { row in !snapshot.devices.contains { $0.id == row.id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fold("沙盒", id: "sandbox.expand", open: expanded || initiallyExpanded) { expanded.toggle() }
            if expanded || initiallyExpanded {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("權限不對稱").fontWeight(.semibold); Text("兩種來源共用") }
                    GridRow { Text("使用者這邊 → 沙盒"); Text("派工、送指定檔案、撤銷") }
                    GridRow { Text("沙盒 → 這邊"); Text("讀檔、跑指令、派工、記憶、提案全部拒絕") }
                    GridRow { Text("沙盒交件"); Text("只能交被派工作的結果，等使用者審查") }
                }.font(.caption).padding(12).chatLiquidSection(cornerRadius: 12)
                ForEach(["Linux", "macOS"], id: \.self) { platform in
                    VStack(alignment: .leading, spacing: 12) {
                        fold(platform, id: "sandbox.\(platform).expand", open: platforms.contains(platform)) {
                            if platforms.contains(platform) { platforms.remove(platform) } else { platforms.insert(platform) }
                        }
                        if platforms.contains(platform) {
                            let selection = platform == "Linux" ? $linuxVirtual : $macVirtual
                            HStack(spacing: 6) {
                                OSChipButton(title: "自己的設備", isPrimary: !selection.wrappedValue) { selection.wrappedValue = false }
                                    .accessibilityIdentifier("sandbox.\(platform).physical")
                                OSChipButton(title: "虛擬設備", isPrimary: selection.wrappedValue) { selection.wrappedValue = true }
                                    .accessibilityIdentifier("sandbox.\(platform).virtual")
                            }
                            if selection.wrappedValue { SandboxVirtualDevices(platform: platform, snapshot: snapshot, canPair: canAdd) } else {
                                let rows = devices.filter { $0.role == .sandbox && $0.sandboxInfo?.platform == platform && $0.sandboxInfo?.virtual == false }
                                if rows.isEmpty { Text("尚未配對沙盒設備").font(.caption).foregroundStyle(.secondary) }
                                ForEach(rows, id: \.id) { device in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("\(device.name) · \(platform)").font(.callout.weight(.semibold))
                                        Text(device.sandboxInfo?.label ?? "來源未登錄").font(.caption).foregroundStyle(.secondary)
                                        SandboxDeviceStatusView(deviceID: device.id, status: snapshot.sandboxStatus[device.id] ?? hands.service.sandboxLane.status(device.id), canPair: canAdd)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).chatLiquidSection(cornerRadius: 12).accessibilityElement(children: .contain).accessibilityIdentifier("sandbox.row.\(device.id)")
                                }
                                OSChipButton(title: "加一台沙盒") { adding = platform; name = ""; source = "" }
                                    .disabled(!canAdd || busy).accessibilityIdentifier("sandbox.\(platform).add")
                                if !canAdd { Text("只有主設備能登錄與建立配對。").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.padding(.leading, 16)
                }
                let legacy = devices.filter { $0.role == .sandbox && $0.sandboxInfo == nil }
                ForEach(legacy, id: \.id) { device in
                    Text("\(device.name) · 平台／來源未登錄").font(.caption)
                    SandboxDeviceStatusView(deviceID: device.id, status: snapshot.sandboxStatus[device.id] ?? hands.service.sandboxLane.status(device.id), canPair: canAdd)
                }
                if let adding {
                    Text("加一台 \(adding) 沙盒").font(.callout.weight(.semibold))
                    TextField("名稱", text: $name).accessibilityIdentifier("sandbox.name")
                    TextField("來源（Dots／Grok／測試機）", text: $source).accessibilityIdentifier("sandbox.source")
                    HStack {
                        OSChipButton(title: busy ? "登錄中…" : "登錄並建立配對", action: add).disabled(busy || !canAdd || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("sandbox.confirm")
                        OSChipButton(title: "取消") { self.adding = nil }.disabled(busy)
                    }
                }
                if let card = hands.pendingPairing, card.scope.sandboxDeviceID != nil {
                    ChatGPTHandsPairingCard(transaction: card.displayCode, pairingCode: card.spacedPairingCode, callbackHost: card.callbackHost,
                        level: card.scope.level, projects: card.scope.projects.map(\.name), memory: card.scope.memory, attemptsLeft: card.attemptsLeft,
                        onMismatch: { hands.service.auth.closeWindow() }, sandbox: true)
                } else if hands.pairingWindowExpiresAt != nil { Text("沙盒版先執行 pair；此處會顯示交易編號與配對碼。").font(.caption) }
                if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("sandbox.section")
    }
    private func fold(_ title: String, id: String, open: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Text("\(open ? "▾" : "▸") \(title)").font(.system(size: 14, weight: .bold)); Spacer() }.contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityIdentifier(id)
    }
    private func add() {
        guard canAdd, let platform = adding, !busy else { return }
        busy = true; problem = nil
        let chosenName = name, info = SandboxDeviceInfo(platform: platform, virtual: false, source: DeviceFleetName.clean(source))
        Task {
            defer { busy = false }
            do {
                let member = try await DeviceFleetStore.registerSandbox(name: chosenName, info: info)
                added.append(member); adding = nil
                try hands.service.sandboxLane.pair(member.id)
            } catch { problem = "登錄或配對未完成；請確認主設備與沙盒關口已啟用。" }
        }
    }
}
