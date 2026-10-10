// Pairing UI adapted after cp from New/DevicesCard.swift; the settings card is untouched.
import SwiftUI
import CoreImage.CIFilterBuiltins

/// One-shot local authority: it cannot be decoded or created by a tool response.
@MainActor
final class DeviceFlowUserAction {
    private let binding: String
    private let issuedAt: TimeInterval
    private var consumed = false
    fileprivate init(binding: String, issuedAt: TimeInterval) { self.binding = binding; self.issuedAt = issuedAt }
    func consume(binding expected: String) -> Bool {
        guard !consumed, binding == expected,
              abs(ProcessInfo.processInfo.systemUptime - issuedAt) < 0.5 else { return false }
        consumed = true
        return true
    }
    func consume(for session: DeviceFlowSession) -> Bool { consume(binding: session.cardBinding) }
    // Compatibility for older negative self-tests; there is no ambient event authority.
    static func current() -> DeviceFlowUserAction? { nil }
    #if DEBUG
    static func fixture(binding: String = "invalid-fixture") -> DeviceFlowUserAction {
        .init(binding: binding, issuedAt: ProcessInfo.processInfo.systemUptime)
    }
    #endif
}

/// Native mouseDown/mouseUp own the events. AXPress and programmatic target/action cannot mint authority.
struct DeviceFlowPhysicalButton: NSViewRepresentable {
    let title: String
    var binding: String
    var enabled = true
    var primary = false
    var run: (DeviceFlowUserAction) -> Void
    final class Native: NSButton {
        var binding = ""
        var changedAt = ProcessInfo.processInfo.systemUptime
        var armed: (String, TimeInterval)?
        var invoke: ((DeviceFlowUserAction) -> Void)?
        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor(TatwoThemeTokensV1.fromLiquidGlassTokens().surface).setFill(); shape.fill()
            NSColor(TatwoActivePalette.current.surfaceBorder.opacity(isHighlighted ? 0.9 : 0.55)).setStroke(); shape.stroke()
            let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
                .foregroundColor: (contentTintColor ?? .labelColor).withAlphaComponent(isEnabled ? 1 : 0.45)])
            let size = text.size()
            text.draw(at: NSPoint(x: max(6, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2))
        }
        override func accessibilityPerformPress() -> Bool { false }
        private func physical(_ event: NSEvent, type: NSEvent.EventType) -> Bool {
            guard isEnabled, event.type == type, let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let cg = event.cgEvent,
                  cg.getIntegerValueField(.eventSourceUnixProcessID) == 0,
                  cg.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.privateState.rawValue),
                  abs(event.timestamp - ProcessInfo.processInfo.systemUptime) < 0.5,
                  event.timestamp - changedAt >= 1 else { return false }
            return true
        }
        override func mouseDown(with event: NSEvent) {
            armed = physical(event, type: .leftMouseDown) ? (binding, event.timestamp) : nil
            highlight(armed != nil)
        }
        override func mouseUp(with event: NSEvent) {
            defer { armed = nil; highlight(false) }
            guard let down = armed, down.0 == binding, event.timestamp >= down.1,
                  physical(event, type: .leftMouseUp) else { return }
            invoke?(.init(binding: binding, issuedAt: event.timestamp))
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); armed = nil; changedAt = ProcessInfo.processInfo.systemUptime
        }
    }
    func makeNSView(context: Context) -> Native {
        let button = Native()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 14, weight: .medium)
        button.setAccessibilityRole(.button)
        return button
    }
    func updateNSView(_ button: Native, context: Context) {
        let effectiveEnabled = enabled && context.environment.isEnabled
        if button.binding != binding || button.title != title || button.isEnabled != effectiveEnabled {
            button.changedAt = ProcessInfo.processInfo.systemUptime; button.armed = nil
        }
        button.title = title; button.binding = binding; button.isEnabled = effectiveEnabled; button.invoke = run
        button.bezelColor = NSColor(TatwoThemeTokensV1.fromLiquidGlassTokens().surface)
        button.contentTintColor = primary ? NSColor(DeviceFleetStyle.terra) : .labelColor
        button.setAccessibilityLabel(title)
    }
}

struct DeviceFlowChip: View {
    @ObservedObject var session: DeviceFlowSession
    var body: some View {
        Button {
            if session.active != nil { session.reveal(); return }
            do { try session.open(.menu) } catch { session.report("請先完成或取消目前的設備流程。") }
        } label: { GlobalDMChipLabel(title: "設備") }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tatwo.dm.fleet.chip")
    }
}

struct DeviceFlowCard: View {
    @ObservedObject var session: DeviceFlowSession
    @ObservedObject private var theme = TatwoThemeStore.shared
    @State private var confirmingTransfer = false
    @State private var from = ""
    @State private var to = ""
    @State private var direction = DeviceFleetEdge.Direction.oneway
    @State private var capabilities = Set(DeviceFleetCapabilities.managed)
    @State private var rename = ""
    @State private var renamingGroup = ""
    @FocusState private var codeFocus: Int?
    private var kind: DeviceFlowKind { session.active ?? .menu }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(kind.title, systemImage: "desktopcomputer")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("收起") { session.close() }.buttonStyle(.plain).disabled(session.busy)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if let consent = session.consentRequest {
                Text(session.awaitingInitialConsent ? "確認這台允許誰操作" : "管理者想多開這些權限").font(.headline)
                ForEach(Array(session.consentLines.enumerated()), id: \.offset) { _, line in Text(line) }
                Text("只能做這些事、不能直接登入。這台不能連回管理者的設備。")
                if consent.faction.kind == .managed { Text(DeviceFleetDefaults.staffRoleExplanation).font(.caption) }
                action(session.awaitingInitialConsent ? (consent.faction.kind == .sandbox ? "同意作為沙盒並加入" : "同意被管理") : "同意新增權限", primary: true) { await session.approveConsentFromCard($0, revision: consent.revision) }
                OSChipButton(title: "先不開放") { session.close() }
            } else { content }
            if !session.possiblyConnected.isEmpty {
                Text("可能還有連線：「" + session.possiblyConnectedLabels.joined(separator: "」、「") + "」的 SSH 連線尚未確認中斷。").foregroundStyle(.orange)
                Text("請確認這些連線已中斷，再按下方確認。")
                action("已確認連線中斷") { await session.confirmConnectionsClosed($0) }
            }
            ForEach(Array(session.pendingDeliveryLines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13)).foregroundStyle(.orange)
            }
            if session.busy { ProgressView().controlSize(.small) }
            if !session.message.isEmpty { Text(session.message).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .font(.system(size: 15))
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(TatwoThemeTokensV1.fromLiquidGlassTokens().surface))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(TatwoActivePalette.current.surfaceBorder.opacity(0.55), lineWidth: 1))
        .background(DeviceFlowWindowShield())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.fleet.card.\(kind.rawValue)")
        .sheet(isPresented: $confirmingTransfer) {
            VStack(alignment: .leading, spacing: 16) {
                Text("移交主權給所選設備？").font(.headline)
                if let target = session.transferCandidates.first(where: { $0.id == session.transferTarget }) {
                    Text(DeviceFleetName.label(target, groups: session.graph?.groups ?? []))
                }
                Text("現任主設備必須配合。完成後仍須分別驗收正本、GBrain 與發行能力。")
                action("確認移交（主權版本將遞增）", primary: true, enabled: !session.signingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { authority in
                    await session.transferFromLocalDialog(authority); confirmingTransfer = false
                }
                OSChipButton(title: "取消") { confirmingTransfer = false }
            }.padding(24).frame(width: 460)
                .background(TatwoThemeTokensV1.fromLiquidGlassTokens().surface)
                .background(DeviceFlowWindowShield())
        }
    }
    @ViewBuilder private var content: some View {
        switch kind {
        case .menu: menu
        case .invite: invite
        case .join, .joinManaged, .joinSandbox: join
        case .progress: progress
        case .managed: managed
        case .sandbox: sandbox
        case .permissions: permissions
        case .transfer: transfer
        }
    }
    private func navigate(_ kind: DeviceFlowKind) {
        do { try session.open(kind) } catch { session.report("請先完成或取消目前的設備流程。") }
    }
    private func action(_ title: String, primary: Bool = false, enabled: Bool = true,
                        run: @escaping (DeviceFlowUserAction) async -> Void) -> some View {
        DeviceFlowPhysicalButton(title: title, binding: session.cardBinding,
                                 enabled: enabled && !session.busy, primary: primary) { authority in
            Task { await run(authority) }
        }.frame(height: 34)
    }
    private var menu: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.managedLocally {
                Text("退出管理：先撤回操作權限，再由主設備核准離開。")
                action("申請離開／退出管理") { await session.requestLeaveFromCard($0) }
            }
            ForEach(session.leaveRequests, id: \.self) { id in
                Text("離開申請：" + (session.graph?.devices.first { $0.id == id }.map { DeviceFleetName.label($0, groups: session.graph?.groups ?? []) } ?? "受管設備"))
                OSChipButton(title: "核准離開（預覽撤銷）") { session.proposeLeaveApproval(id) }
            }
            Text("加入我的設備").font(.system(size: 15, weight: .semibold))
            if session.canInviteSandbox { OSChipButton(title: "讓別台加入") { navigate(.invite) } }
            else { Text("請在主設備上加入") }
            OSChipButton(title: "我要加入別台") { navigate(.join) }
            OSChipButton(title: "新增受管設備") { navigate(.managed) }
            if session.canInviteSandbox {
                OSChipButton(title: "新增沙盒設備") { navigate(.sandbox) }
            }
            OSChipButton(title: "調整群組與權限") { navigate(.permissions) }
            OSChipButton(title: "移交主設備") { navigate(.transfer) }
            Divider()
            Text("在另一台加入受管或沙盒：")
            OSChipButton(title: "加入成受管設備") { navigate(.joinManaged) }
            OSChipButton(title: "加入成沙盒設備") { navigate(.joinSandbox) }
        }
    }
    private var invite: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在另一台的「加入我的設備」打這組碼就好")
            pairingOutput
            Text("不用抄 IP：同一個網路裡，那台打碼就會自己找到這台")
            Text(session.discovery.advertised ? "附近的 TATWO 已經看得到這台正在等配對。加入後，你所有的開發設備都會自動認得它。"
                 : "配對開啟後會公告給附近的 TATWO；若網路擋住搜尋，可展開進階用位址連。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            OSChipButton(title: "取消") { session.close() }.disabled(session.busy)
        }
    }
    @ViewBuilder private var pairingOutput: some View {
        if session.window == nil, !session.revokedCandidates.isEmpty || !session.restoringDeviceID.isEmpty {
            Picker("恢復被撤銷設備的原身分（須確認後才產生專用碼）", selection: $session.restoringDeviceID) {
                Text("新增設備，不恢復舊身分").tag("")
                ForEach(session.revokedCandidates, id: \.id) { member in
                    Text(DeviceFleetName.label(member, groups: session.graph?.groups ?? [])).tag(member.id)
                }
            }
        }
        if !session.restoringDeviceID.isEmpty {
            Text("確認恢復原身分與原箭頭").font(.headline)
            invitationDetails
            Text("只有按下方實體確認後，才會產生這台設備專用的恢復碼。")
                .fixedSize(horizontal: false, vertical: true)
        }
        if let window = session.window, window.expiresAt > session.now {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { codeOutput(window); qr(window) }
                VStack(alignment: .leading, spacing: 12) { codeOutput(window); qr(window) }
            }
            DisclosureGroup("進階：在不同網段，用位址連") {
                DMSecretCode(text: window.address).frame(height: 44)
                Text("在那台的進階欄貼入位址；連線仍會核對配對碼與金鑰。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if kind != .invite { OSChipButton(title: "取消") { session.close() }.disabled(session.busy) }
        } else {
            action(session.restorationConfirmation != nil ? "確認恢復並產生專用碼" : kind == .managed ? "確認設定並產生配對碼" : "產生配對碼", primary: true) { await session.generateFromCard($0) }
            Text("6 碼、5 分鐘內有效、只能用一次。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
    private var invitationDetails: some View {
        ForEach(Array(session.invitationConsentLines.enumerated()), id: \.offset) { _, line in
            Text(line).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func codeOutput(_ window: DeviceFlowSession.Window) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DMSecretCode(text: window.code).frame(height: 48)
            Text("只能用一次 · \(session.remaining / 60) 分 \(session.remaining % 60) 秒後失效")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            action("複製碼") { session.copyCode($0) }
        }
    }
    private func qr(_ window: DeviceFlowSession.Window) -> some View {
        VStack(spacing: 6) {
            DeviceFlowQRCode(text: DevicePairingInput.copyLine(address: window.address, code: window.code))
                .frame(width: 100, height: 100)
            Text("或用相機、iPhone 掃").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var join: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("打那台畫面上的 6 碼")
            HStack(spacing: 5) {
                ForEach(0..<6) { index in
                    TextField("", text: Binding(get: { session.codeCells[index] }, set: { text in
                        session.setCell(index, text: text)
                        if !text.isEmpty { codeFocus = min(5, index + DevicePairingInput.normalizedCode(text).count) }
                    }))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center).textFieldStyle(.plain)
                    .frame(maxWidth: 46).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .focused($codeFocus, equals: index)
                    .accessibilityLabel("配對碼第 \(index + 1) 格")
                }
            }
            Text("打小寫也會變大寫；只收英文字母與數字").font(.system(size: 13)).foregroundStyle(.secondary)
            DeviceFlowNearby(session: session)
            TextField("這台的名字", text: $session.deviceName).textFieldStyle(.roundedBorder)
            DisclosureGroup("進階：在不同網段，用位址連") {
                TextField("192.0.2.10:18815", text: $session.address).textFieldStyle(.roundedBorder)
                    .onChange(of: session.address) { _, value in
                        if let parsed = DevicePairingInput.parseAddress(value), let code = parsed.code {
                            session.setCell(0, text: code)
                            session.address = "\(parsed.host.contains(":") ? "[\(parsed.host)]" : parsed.host):\(parsed.port)"
                        }
                    }
            }
            if kind == .joinManaged {
                Text("先讀取已驗章的權限預覽，尚未入群；逐台列出誰能操作與每一項權限。只有你在這台按「同意被管理」才會開放控制；讀取後會列出實際權限，讓你實體確認。只能做你同意的事、不能直接登入。")
                action("讀取管理權限", primary: true, enabled: session.code.count == 6) { await session.joinFromCard($0) }
            } else if kind == .joinSandbox {
                Text("先讀取已驗章的權限預覽，尚未入群；列出每台管理設備與逐項權限；在這台實體同意後才開放。只能做這些事、不能直接登入；這台不能連回管理者。")
                action("讀取沙盒權限", primary: true, enabled: session.code.count == 6) { await session.joinFromCard($0) }
            } else {
                Text("這台加入後，你所有的開發設備都會自動認得它")
                action("加入", primary: true, enabled: session.code.count == 6) { await session.joinFromCard($0) }
            }
            OSChipButton(title: "取消") { session.close() }.disabled(session.busy)
        }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.joinedDeviceLabel.isEmpty { Text("加入設備：" + session.joinedDeviceLabel) }
            if !session.pairingHistoryNotice.isEmpty { Text(session.pairingHistoryNotice) }
            step("互換鑰匙", done: session.exchanged)
            step("主設備簽新名單\(session.signedVersion.map { " v\($0)" } ?? "")", done: session.signedVersion != nil)
            step("其他設備自動連上", done: session.connected)
            step("完成", done: session.connected)
            if session.exchanged && session.signedVersion == nil {
                Text("尚未加入名單，請在主設備本機重新配對並確認。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else if !session.connected {
                Text("名單與連線狀態會即時更新；離線設備上線後自動連上。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            OSChipButton(title: "回到設備") { session.close() }
        }
    }
    private func step(_ text: String, done: Bool) -> some View {
        Label(text, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Color.green : Color.secondary)
    }
    private var managed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("受管設備是別人在用的電腦：你的開發設備可以看、可以操作、可以派工；它連不回你的任何一台。")
            Picker("加進哪個派系", selection: $session.selectedGroup) {
                ForEach(session.graph?.groups.filter { $0.type == .sub } ?? [], id: \.id) { Text(DeviceFleetName.label($0)).tag($0.id) }
                Text("＋ 新派系…").tag("new")
            }
            .disabled(session.window != nil || session.restorationConfirmation != nil)
            .onChange(of: session.selectedGroup) { _, id in
                if let group = session.graph?.groups.first(where: { $0.id == id }) {
                    session.managerName = group.managerDisplayName; session.showMainPrimary = group.showMainPrimary
                } else { session.showMainPrimary = false }
            }
            if session.selectedGroup == "new" { TextField("新派系名稱", text: $session.newGroupName).textFieldStyle(.roundedBorder).disabled(session.window != nil) }
            Toggle("在職員電腦上顯示主設備", isOn: $session.showMainPrimary).disabled(session.window != nil)
            Text("只顯示名稱與角色，不顯示位址、帳號或金鑰。預設關。").font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("職員看到的管理者名稱", text: $session.managerName).textFieldStyle(.roundedBorder).disabled(session.window != nil)
            Text("在職員那台做").font(.system(size: 15, weight: .semibold))
            Text("1　裝 TATWO OS，打開助理私訊框的「設備」\n2　選「加入成受管設備」，打這組碼（或掃 QR）\n3　職員按「同意被管理」")
            if session.restoringDeviceID.isEmpty { invitationDetails }
            Text("只能做這些事、不能直接登入；職員在那台看過實際名單再實體同意。")
            pairingOutput
            Text("職員電腦做不到的事（一律擋）").font(.system(size: 15, weight: .semibold))
            Text("· 連回你的任何一台、讀你的專案、記憶或對話\n· 要求主權\n· 把你的設備加成它的副設備\n· 自己出碼收別台，或把自己升級成副設備")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }.disabled(session.window != nil && session.busy)
    }
    private var sandbox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("另一台裝了 TATWO OS 的電腦當沙盒")
            Text("你的設備可以派工給它；對話全文與終端機紀錄各有存取限制：用對話功能讀全文，目前只開放給 MAIN 的我的設備，App 終端機須另開記憶權限。請在工作檔案中交付成果，你看過後再合併回來；它不能讀、不能寫、不能操控你的設備。")
            Text("在那台的助理私訊框點「設備」→「加入成沙盒設備」，輸入這組碼。")
            pairingOutput
            if session.restoringDeviceID.isEmpty { invitationDetails }
            Text("只能做這些事、不能直接登入。沙盒連不回你的設備；成果要你看過才合併。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var permissions: some View {
        if session.pending != nil {
            Text("請確認以下變更，按確認才由主設備簽發：")
            ForEach(Array(session.previewLines.enumerated()), id: \.offset) { _, line in
                Text(line).fixedSize(horizontal: false, vertical: true)
                    .fontWeight(line.hasPrefix("⚠") ? .semibold : .regular)
                    .foregroundStyle(line.hasPrefix("⚠") ? DeviceFleetStyle.terra : Color.primary)
            }
            if session.hasConnectionCut {
                Text("這台目前可能還有連線：無法辨識或共用位址的舊連線可能繼續。")
                Toggle("中斷主設備及受影響的「我的設備」上所有遠端連線（其他設備會自動重連）", isOn: $session.disconnectAllOnRevoke)
                Text("會中斷：" + session.disconnectAllTargets.joined(separator: "、")).font(.caption)
                Text("目前離線的設備，要在下一次名單變更前連上才會中斷。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                action("確認", primary: true) { await session.confirmFromCard($0) }
                OSChipButton(title: "取消") { session.cancelProposal() }.disabled(session.busy)
            }
        } else if let graph = session.graph {
            Text("選箭頭與權限後先看預覽，確認才變更名單。反方向鎖住的權限不能開放。")
            Picker("起點", selection: $from) { endpointOptions(graph) }
            Picker("終點", selection: $to) { endpointOptions(graph) }
            Picker("方向", selection: $direction) {
                Text("互通").tag(DeviceFleetEdge.Direction.mutual)
                Text("單向：起點控制終點").tag(DeviceFleetEdge.Direction.oneway)
                Text("不連").tag(DeviceFleetEdge.Direction.none)
            }
            ForEach(DeviceFleetCapabilities.all, id: \.self) { key in
                Toggle(DeviceFlowPreview.capability(key), isOn: Binding(get: { capabilities.contains(key) }, set: {
                    if $0 { capabilities.insert(key) } else { capabilities.remove(key) }
                }))
            }
            OSChipButton(title: "預覽箭頭變更") {
                guard let from = endpoint(from), let to = endpoint(to) else { session.report("請先選起點與終點。"); return }
                do { _ = try session.propose([.setEdge(.init(from: from, to: to, direction: direction, capabilities: capabilities.sorted()))]) }
                catch { session.report("這條箭頭受系統鎖定或不允許，未更動名單。") }
            }
            DisclosureGroup("群組改名與移動設備") {
                Picker("群組", selection: $renamingGroup) {
                    Text("請選擇").tag("")
                    ForEach(graph.groups, id: \.id) { Text(DeviceFleetName.label($0)).tag($0.id) }
                }
                TextField("新名稱", text: $rename).textFieldStyle(.roundedBorder)
                OSChipButton(title: "預覽改名") {
                    do { _ = try session.propose([.renameGroup(id: renamingGroup, name: rename)]) }
                    catch { session.report("請選群組並填新名稱。") }
                }
                Text("把上方起點選為設備、終點選為群組，可預覽移動。")
                OSChipButton(title: "預覽移動設備") {
                    guard let source = endpoint(from), source.kind == .device,
                          let target = endpoint(to), target.kind == .group else { return }
                    do { _ = try session.propose([.moveDevice(id: source.id, groupID: target.id)]) }
                    catch { session.report("這台設備不能移入所選群組。") }
                }
            }
        } else { Text("尚未有已驗章的設備群；先加入我的設備，再調整群組與權限。") }
    }
    @ViewBuilder private func endpointOptions(_ graph: DeviceFleetRoster) -> some View {
        Text("請選擇").tag("")
        ForEach(graph.groups, id: \.id) { Text("群組：\($0.name)").tag("group:\($0.id)") }
        ForEach(graph.devices.filter { !graph.revoked.contains($0.id) }, id: \.id) { Text("設備：\(DeviceFleetName.label($0, groups: graph.groups))").tag("device:\($0.id)") }
    }
    private func endpoint(_ value: String) -> DeviceFleetEndpoint? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = DeviceFleetEndpoint.Kind(rawValue: parts[0]) else { return nil }
        return .init(kind: kind, id: parts[1])
    }
    private var transfer: some View {
        let local = try? DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: session.environment))
        return VStack(alignment: .leading, spacing: 12) {
            Text("移交後，所選設備成為 MAIN 的主設備，原主設備降為副設備，主權版本 epoch 遞增。新主設備會重簽名單，其他設備驗過雙簽才接受。")
            Text("憲法正本、GBrain 與發行能力仍須分項驗收；不自動搬資料或匯出憑證。")
            if session.canTransfer && local.map(PrimaryTransfer.canBegin) == true {
                Picker("新主設備", selection: $session.transferTarget) {
                    Text("請選擇").tag("")
                    ForEach(session.transferCandidates, id: \.id) { Text(DeviceFleetName.label($0, groups: session.graph?.groups ?? [])).tag($0.id) }
                }
                TextField("與現任主設備相同的簽章身分名稱", text: $session.signingName).textFieldStyle(.roundedBorder)
                action("移交主設備…", primary: true, enabled: !session.transferTarget.isEmpty && !session.signingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { _ in confirmingTransfer = true }
            } else if session.canTransfer { Text("先完成①所有設備的讀回，才能再移交。") }
            else if !session.canTransfer && local?.transfer?.from != local?.deviceID { Text("請在現任 MAIN 主設備上開啟這張卡片；主設備須在線才能移交。") }
            if local?.transfer != nil {
                DeviceFlowTransferPanel(dispatch: session.dispatch, onReturn: session.transferCandidates.contains { $0.id == local?.transfer?.from } ? { target, name in
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    session.transferTarget = target; session.signingName = name; confirmingTransfer = true
                } : nil)
            }
        }
    }
}

private struct DeviceFlowNearby: View {
    @ObservedObject var session: DeviceFlowSession
    @ObservedObject var discovery: DevicePairingDiscovery
    init(session: DeviceFlowSession) { self.session = session; discovery = session.discovery }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.matchingPeers.isEmpty { Text("附近的 TATWO：等你填滿 6 碼後自動尋找").foregroundStyle(.secondary) }
            ForEach(session.matchingPeers) { peer in
                OSChipButton(title: "在附近找到「\(peer.name)」\(session.selectedPeer == peer.id ? " ✓" : "")") { session.selectedPeer = peer.id }
            }
        }.font(.system(size: 13))
    }
}

/// Sharing protection also makes the existing Computer Use observer refuse this window.
struct DeviceFlowWindowShield: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); WindowCaptureShield.shared.hold(self, window: window) }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { WindowCaptureShield.shared.hold(view, window: view.window) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { WindowCaptureShield.shared.release(view) }
}

/// QR uses the same native secret view as the pairing code, including transition/capture suppression.
private struct DeviceFlowQRCode: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> DMSecretCodeView { DMSecretCodeView() }
    func updateNSView(_ view: DMSecretCodeView, context: Context) {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        if let image = filter.outputImage, let cg = CIContext().createCGImage(image, from: image.extent) {
            view.qrImage = NSImage(cgImage: cg, size: NSSize(width: 100, height: 100))
        }
        view.isHidden = DMSecretCodeView.isSuppressed
        view.setAccessibilityLabel("配對 QR")
        view.setAccessibilityIdentifier("tatwo.dm.fleet.qr")
    }
}
