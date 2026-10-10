// MAIN-only handoff actions with physical confirmation.
import SwiftUI

struct DeviceFlowTransferPanel: View {
    private let dispatch: DeviceDispatch
    private let previewOnly: Bool
    @State private var identity: DeviceIdentity?
    @State private var peers: [DeviceRecord] = []
    private let onReturn: ((String, String) -> Void)?
    @State private var signingName = ""
    @State private var brain = PrimaryTransfer.Brain.migrating
    @State private var message = ""
    @State private var busy = false
    private enum Contact: Equatable { case waiting, online, offline(String) }
    @State private var contact = Contact.waiting
    @State private var coordinatorRetired = false
    @State private var absent: [String] = []

    init(dispatch: DeviceDispatch = .shared, preview: DeviceIdentity? = nil, previewCoordinatorRetired: Bool = false, previewContactError: Error? = nil, onReturn: ((String, String) -> Void)? = nil) {
        self.dispatch = dispatch
        self.onReturn = onReturn
        previewOnly = preview != nil
        _identity = State(initialValue: preview)
        _signingName = State(initialValue: preview?.transfer?.signingName ?? "")
        _coordinatorRetired = State(initialValue: preview != nil && previewCoordinatorRetired)
        _contact = State(initialValue: previewContactError.map { Self.contactProblem($0, record: preview?.transfer) } ?? (preview?.role == .primary ? .online : .waiting))
    }

    private var binding: String { [String(describing: identity), brain.rawValue, signingName].joined(separator: "|") }
    private func physical(_ title: String, disabled: Bool = false, run action: @escaping () -> Void) -> some View {
        DeviceFlowPhysicalButton(title: title, binding: binding, enabled: !busy && !disabled) { authority in
            guard authority.consume(binding: binding) else { return }
            action()
        }.frame(height: 34)
    }
    private var coordinator: Bool {
        !coordinatorRetired && identity?.transfer?.from == identity?.deviceID && identity?.transfer != nil
    }
    var body: some View {
        VStack(alignment: .leading) {
            if let identity, let record = identity.transfer, identity.role == .primary || coordinator {
                let sourceRecovered = DeviceDispatch.hasRecoveredDispatchSource(identity)
                GroupBox("移交主權") {
                    VStack(alignment: .leading, spacing: 12) {
                        if record.complete { Text(record.summary).foregroundStyle(.green) }
                        else {
                            Text("四項分開驗收；不自動搬 GBrain，不匯出任何憑證。").font(.caption)
                            if !coordinatorRetired { PrimaryTransferStatusView(record: record) }
                            if case .offline(let message) = contact { Text(message).foregroundStyle(.orange) }
                        }
                        if identity.role == .primary, record.to == identity.deviceID {
                            if record.committed && !record.constitution && !sourceRecovered {
                                Text("舊協調者失聯或被撤銷時，可在本機確認以凍結時的正本恢復派發；GBrain 與發行驗收仍待完成。")
                                physical("確認凍結雜湊並恢復正本派發") {
                                    run { try dispatch.updateTransfer(constitution: true) }
                                }
                            }
                            if let onReturn {
                                physical("移交回原主設備…") { onReturn(record.from, record.signingName) }.disabled(!record.epochComplete || record.signingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        if !record.complete {
                            if coordinator || sourceRecovered {
                                if !record.committed {
                                    physical("取消尚未遞增的移交（恢復一般派發）") {
                                        run { try dispatch.cancelPreparedTransfer() }
                                    }
                                }
                                if record.committed && !record.epochComplete {
                                    Text(sourceRecovered ? "先完成其他設備的主權版本讀回；撤銷者可略過，其餘設備須有提交後持續 120 秒失聯紀錄。" : "撤銷者可直接略過；其他設備須有提交後持續 120 秒失聯紀錄。新主設備須在線並回覆。")
                                    ForEach(absent, id: \.self) { id in Text("將略過：" + (peers.first { $0.id == id }?.name ?? String(id.prefix(8)))) }
                                    physical("略過逾時或已撤銷的參與者") {
                                        run { try PrimaryTransfer.skipAbsentParticipants(dispatch, includeOffline: true) }
                                    }.disabled(absent.isEmpty)
                                }
                                if coordinator {
                                    physical("② 比對凍結的正本並切換正本派發來源") {
                                        run { try dispatch.updateTransfer(constitution: true) }
                                    }.disabled(contact != .online || !record.epochComplete || record.constitution)
                                }
                                Picker("③ GBrain", selection: $brain) {
                                    ForEach(PrimaryTransfer.Brain.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                DisclosureGroup("匯出／匯入步驟（手動操作）") {
                                    ForEach(PrimaryTransfer.migrationSteps, id: \.self) { Text($0).font(.caption) }
                                }
                                if contact == .online && record.constitutionComplete && record.epochComplete {
                                    TextField("④ 要比對的簽章身分名稱", text: $signingName).textFieldStyle(.roundedBorder)
                                }
                                Group {
                                    physical("驗證 GBrain 健康與頁數") {
                                        let selected = brain
                                        run { try dispatch.updateTransfer(brain: selected) }
                                    }
                                    physical("④ 檢查同名簽章身分與打包依賴") {
                                        let name = signingName
                                        run { try dispatch.updateTransfer(release: true, signingName: name) }
                                    }
                                }.disabled(contact != .online || !record.constitutionComplete || !record.epochComplete)
                            }
                            HStack {
                                physical("重新檢查／重試同步") { run { dispatch.synchronize() } }
                                if busy { ProgressView().controlSize(.small) }
                            }
                            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
                        }
                    }.padding(8)
                }
                .background(TatwoThemeTokensV1.fromLiquidGlassTokens().surface)
                .background(DeviceFlowWindowShield())
            } else if coordinatorRetired {
                Text("這台已交出移交協調；後續驗收由新主設備處理，這台不需要操作。")
            }
        }
        .task {
            guard !previewOnly else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    private static func contactProblem(_ error: Error, record: PrimaryTransfer.Record?) -> Contact {
        guard ["fleet_app_rpc_unavailable", "fleet_ssh_endpoint_unreachable", "transfer_identity_stale", "fleet_app_rpc_refused", "fleet_gate_denied", "fleet_capabilityDenied", "rpc_proof_expired", "paired_host_key_not_found"].contains(DeviceFleetReason.code(error) ?? "") else { return .waiting }
        return .offline(DeviceFleetReason.plain(error, context: .transfer(record)))
    }

    private func refresh() async {
        let dispatch = dispatch
        let result = await Task.detached(priority: .utility) {
            let identity = try? dispatch.identity()
            let peers = dispatch.registry.list()
            let retired = identity?.transfer.flatMap { try? dispatch.coordinatorRetired($0) } ?? false
            var contact: Contact = identity?.role == .primary ? .online : .waiting
            if let primary = peers.first(where: { $0.id == identity?.primaryDeviceID }),
               !retired, identity?.transfer?.complete != true, identity?.transfer?.from == identity?.deviceID {
                do {
                    let remote = try dispatch.transferIdentity(primary)
                    contact = remote.role == .primary && remote.epoch == identity?.epoch ? .online : .waiting
                } catch { contact = Self.contactProblem(error, record: identity?.transfer) }
            }
            return (identity, peers, contact, retired, (try? PrimaryTransfer.absentParticipants(dispatch)) ?? [])
        }.value
        if identity?.transfer?.id != result.0?.transfer?.id { signingName = result.0?.transfer?.signingName ?? "" }
        identity = result.0; peers = result.1; contact = result.2
        coordinatorRetired = result.3; absent = result.4
    }
    private func run(_ action: @escaping @Sendable () throws -> Void) {
        guard !previewOnly else { return }
        busy = true; message = ""
        let record = identity?.transfer
        Task {
            message = await Task.detached(priority: .utility) {
                do { try action(); return "" } catch { dispatch.fleet.audit(error, fallback: "fleet_transfer_step_refused"); return DeviceFleetReason.plain(error, context: .transfer(record)) }
            }.value
            await refresh(); busy = false
        }
    }
}
