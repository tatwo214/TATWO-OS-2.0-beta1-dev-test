// 2.0 新畫面（不是照搬）：遠端系統 R1／R2 的設定頁「設備」卡。白話：家裡的 mini 是主機，MacBook 是遙控器。
// 新畫面一律放 New/；Facade 禁自畫 View。
import SwiftUI

/// 設定頁「設備」：配對碼（主機端）、加入主機（副機端）、已配對清單、遙控模式開關。
struct DevicesCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var hostField = ""
    @State private var portField = ""
    @State private var codeField = ""
    @State private var nameField = (try? DeviceIdentityStore.readLocal())?.name
        ?? Host.current().localizedName ?? "這台"
    @StateObject private var pairingClipboard = DevicePairingClipboard()
    @FocusState private var hostFieldFocused: Bool
    @State private var updateOffers: [String: [String: PeerUpdateEntry]] = [:]
    /// W98：展開哪幾台（只在這個畫面存活，不持久化）。
    @State private var expandedDevices: Set<String> = []
    // W171 初始設定：第一次打開自動給的名字與身分。
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmSwitch = false
    @State private var setupMessage: String?
    @State private var setupRevision = 0
    @State private var outboxRevision = 0
    #if DEBUG
    var testProbe: PrimaryOutboxViewProbe? = nil
    #endif

    var body: some View {
        let _ = outboxRevision
        ScrollView {
        VStack(alignment: .leading, spacing: TatwoSettingsPageMetrics.sectionSpacing) {
            TatwoSettingsPageHeader(title: "設備")

            setupBanner

            PrimaryTransferPanel()

            // 主機端：出一組碼
            VStack(alignment: .leading, spacing: 8) {
                Text("讓另一台加入這台（這台當主機）")
                    .font(.headline)
                if let window = model.pairingWindow {
                    let listen = model.pairingListenAddress ?? "—"
                    HStack(spacing: 12) {
                        Text(window.code)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(listen)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                OSChipButton(title: pairingClipboard.copied == .address ? "已複製" : "複製") {
                                    pairingClipboard.copy(.address, address: listen, code: window.code,
                                                          expiresAt: window.expiresAt)
                                }
                                .accessibilityLabel("複製這台的配對位址與埠")
                                .disabled(window.expiresAt <= Date() || listen == "—")
                            }
                            Text("5 分鐘內有效、只能用一次；\(Self.remaining(window.expiresAt)) 後失效")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        OSChipButton(title: pairingClipboard.copied == .all ? "已複製" : "全部複製") {
                            pairingClipboard.copy(.all, address: listen, code: window.code,
                                                  expiresAt: window.expiresAt)
                        }
                        .help("複製一行配對資訊，到另一台的「那台的位址」貼上；碼不會自動傳送。")
                        .disabled(window.expiresAt <= Date() || listen == "—")
                        OSChipButton(title: "取消") {
                            pairingClipboard.clear()
                            model.cancelPairingWindow()
                        }
                    }
                    Text("到另一台的「那台的位址」貼上；「全部複製」會連 6 碼一起填好。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("按下去會出一組 6 碼，對方輸入後它的鑰匙就進這台的名單。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        OSChipButton(title: "產生配對碼", isPrimary: true) { model.startPairingWindow() }
                    }
                }
            }

            Divider()

            // 副機端：加入主機
            VStack(alignment: .leading, spacing: 8) {
                Text("把這台加到另一台主機（這台當遙控器）")
                    .font(.headline)
                Text("先在那台按「產生配對碼」，再把「全部複製」的那一行貼進下面的位址欄。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("那台的位址").font(.footnote)
                        TextField("例：192.0.2.10:18815；也可貼全部配對資訊", text: $hostField)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("那台的位址")
                            .focused($hostFieldFocused)
                            .onChange(of: hostField) { previous, value in
                                if DevicePairingInput.isBulkEdit(previous: previous, current: value) {
                                    parseHostField()
                                }
                            }
                            .onSubmit { parseHostField() }
                            .onChange(of: hostFieldFocused) { _, focused in
                                if !focused { parseHostField() }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("那台畫面上冒號後面的數字").font(.footnote)
                        TextField("例：18815", text: $portField)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("那台畫面上冒號後面的數字")
                    }
                    .frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("那台畫面上的 6 碼").font(.footnote)
                        TextField("A–Z、0–9，共 6 碼", text: $codeField)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("那台畫面上的 6 碼")
                            .onChange(of: codeField) { _, value in
                                let normalized = DevicePairingInput.normalizedCode(value)
                                if codeField != normalized { codeField = normalized }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("這台的名字").font(.footnote)
                        TextField("這台的名字", text: $nameField)
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 8) {
                    OSChipButton(title: "加入", isPrimary: true) {
                        guard pairingValidationMessage == nil,
                              let port = DevicePairingInput.portNumber(portField) else { return }
                        model.pairWithHost(host: hostField.trimmingCharacters(in: .whitespacesAndNewlines),
                                           port: port,
                                           code: codeField,
                                           name: nameField.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(pairingValidationMessage != nil)
                    Text(pairingValidationMessage ?? "資訊已填好，可以加入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let pairMessage = model.pairingClientMessage {
                    if let failure = DevicePairingFeedback.failure(pairMessage) {
                        Text(failure.message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Text("工程資訊：\(failure.detail)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text(pairMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // 已配對清單
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("已配對（\(model.devices.count)）")
                        .font(.headline)
                    Spacer()
                    if let remote = model.remoteMode {
                        Text("遙控中：\(remote.name)")
                            .font(.footnote.weight(.semibold))
                        OSChipButton(title: "回到本機") { model.exitRemoteMode() }
                    }
                }
                if model.devices.isEmpty {
                    Text("還沒有配對任何設備。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .padding(TatwoSettingsPageMetrics.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.pairingWindow?.code) { _, _ in pairingClipboard.clear() }
        .onDisappear { pairingClipboard.clear() }
        #if DEBUG
        .onAppear { if testProbe != nil { nameField = "Secondary One" } }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: PrimaryOutbox.didChange)) { note in
            guard let outbox = note.object as? PrimaryOutbox, outbox === model.primaryOutbox else { return }
            outboxRevision += 1
        }
        .task(id: model.devices) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TATWO2_SELFTEST"] != nil { return } // 假設備自測不探訪任何設備。
            #endif
            updateOffers = [:]
            for offer in await PeerUpdateSource.discover(model.devices) {
                updateOffers[offer.device.id] = offer.entries
            }
        }
    }

    private var pairingValidationMessage: String? {
        DevicePairingInput.validationMessage(host: hostField, port: portField, code: codeField, name: nameField)
    }

    private func parseHostField() {
        guard let parsed = DevicePairingInput.parseAddress(hostField) else { return }
        hostField = parsed.host
        portField = parsed.port
        if let code = parsed.code { codeField = code }
    }

    /// W98：一台設備一列，收法照設定 › Computer Use 的列（左 chevron、標題 13 semibold、副標 11.5）。
    /// 收合只露設備名／狀態／`user@host`；指紋、連線路徑、時間與操作都收進展開區。展開狀態不持久化。
    @ViewBuilder
    private func deviceRow(_ device: DeviceRecord) -> some View {
        let isExpanded = expandedDevices.contains(device.id)
        let primary = model.primaryLinkState()
        let isPrimary = primary?.device.id.lowercased() == device.id.lowercased()
        // 主設備列用此刻的連線，不拿最近 10 分鐘的時間冒充在線。
        let isOnline = isPrimary ? primary?.engine != nil : RemoteDevicePresentation.isOnline(device, sections: model.remoteSidebarSections)
        let queued = isPrimary ? model.primaryOfflineDetails : nil
        let update = PeerUpdateSource.summary(updateOffers[device.id] ?? [:])
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(device.name).font(.system(size: 13, weight: .semibold))
                        badge((isOnline ? "在線" : "離線")
                              + (queued?.waiting.isEmpty == false ? "・\(queued!.waiting.count) 件等送出" : "")
                              + (queued?.failed.isEmpty == false ? "・\(queued!.failed.count) 件沒送到" : ""),
                              color: isOnline ? .green : .secondary)
                        // 沒有可提供的更新就不占位（PeerUpdateSource 會回「可提供更新：無」）。
                        if !update.hasSuffix("無") {
                            badge(update, color: .orange)
                        }
                    }
                    Text("\(device.user)@\(device.host):\(device.sshPort)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let problem = model.deviceConnectionProblem(device.id) {
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange)
                            .accessibilityIdentifier("device.connectionProblem." + device.id)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded { expandedDevices.remove(device.id) } else { expandedDevices.insert(device.id) }
                }
            }
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { if isPrimary { testProbe?.deviceFrame = $0 } }
            #endif
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "收起" : "展開指紋、連線路徑與操作")

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if isPrimary, let outbox = model.primaryOutbox {
                        #if DEBUG
                        PrimaryOfflineOutboxList(model: model, outbox: outbox, testProbe: testProbe)
                        #else
                        PrimaryOfflineOutboxList(model: model, outbox: outbox)
                        #endif
                        Divider()
                    }
                    // 隧道識別（建隧道用）與簽章識別（驗 RPC 簽章用）分開顯示，缺哪把看得出來。
                    Text(device.fingerprintSummary)
                        .font(.footnote)
                        .foregroundStyle(
                            device.hostKeyFingerprint == nil || device.clientKeyFingerprint == nil
                                ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    DeviceEndpointsRow(device: device) { updated in
                        if let index = model.devices.firstIndex(where: { $0.id == updated.id }) {
                            model.devices[index] = updated
                        }
                    }
                    Text("加入 \(Self.stamp(device.addedAt))・最近 \(Self.stamp(device.lastSeenAt))")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    RemoteOfflineCacheRow(model: model, device: device)   // W182 R4：這台存的離線副本＋清除（卡片內確認）
                    HStack(spacing: 8) {
                        if model.remoteMode?.id != device.id {
                            // W98d：設備頁只負責帶路——把左列「遠端設備（名稱）」那個區塊展開並捲過去；
                            // 要不要進遠端模式由使用者在那邊點討論串決定，這顆不自己進。
                            OSChipButton(title: "遠端設備專案") {
                                model.requestSidebarDeviceSection(device.id)
                            }
                            .help("到左列的「遠端設備（\(device.name)）」區塊，點裡面的討論串就在那台上工作")
                        }
                        OSChipButton(title: "移除") { model.removeDevice(device.id) }
                            .help("移除這台配對；它存在這台的離線副本一起移到垃圾桶（可以放回）")   // W182 R4
                        Spacer()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.leading, 18)
                .padding(.vertical, 11)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        )
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    /// W171：第一次打開時自動定了這台的名字、當成第一台；在這裡確認、改名，或改成加入已有的那台。
    @ViewBuilder private var setupBanner: some View {
        let _ = setupRevision
        if FirstRunDefaults.record?.appliedAt != nil, let identity = try? DeviceIdentityStore.readLocal() {
            let waiting = FirstRunDefaults.awaitsDeviceConfirmation
            let role = identity.role == .secondary ? "等著跟你的第一台配對（在下面「把這台加到另一台主機」輸入那台給的碼）" : "你的第一台（規則正本放這裡）"
            SetupBanner(done: !waiting, label: waiting ? "初始設定 · 先用了預設" : "初始設定",
                        text: "這台叫「\(identity.name)」，是\(role)。"
                            + (waiting && identity.role == .primary ? "你已經有另一台 TATWO OS 的話，改成跟那台配對。" : "")) {
                if renaming {
                    TextField("這台的名字", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit(saveName)
                    OSChipButton(title: "儲存", isPrimary: true, action: saveName)
                    OSChipButton(title: "取消") { renaming = false }
                } else {
                    OSChipButton(title: "這樣就好", isPrimary: true) { FirstRunDefaults.confirm(); refreshSetup() }
                    OSChipButton(title: "改名字") { renameText = identity.name; renaming = true }
                    if identity.role == .primary {
                        OSChipButton(title: "我已經有一台 · 改成配對") { confirmSwitch = true }
                    }
                }
            }
            .confirmationDialog("改成加入你已經有的那台？", isPresented: $confirmSwitch, titleVisibility: .visible) {
                Button("改成配對") {
                    do { try FirstRunDefaults.switchToExistingPrimary(); setupMessage = "已改好。到下面「把這台加到另一台主機」輸入那台給的碼。" }
                    catch { setupMessage = "沒改成：\(error.localizedDescription)" }
                    refreshSetup()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("第一次打開時自動建立的規則正本會搬到入口的 archive 資料夾（可搬回來）。之後規則由那台送過來。")
            }
            if let setupMessage { Text(setupMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func saveName() {
        do { try FirstRunDefaults.rename(renameText); renaming = false; setupMessage = nil }
        catch { setupMessage = "沒改成：\(error.localizedDescription)" }
        refreshSetup()
    }

    private func refreshSetup() {
        setupRevision += 1
        SetupChecklist.shared.refresh(logins: model.engineLogins)
    }

    private static func remaining(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        return "\(s / 60) 分 \(s % 60) 秒"
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: date)
    }
}

/// W98：設備頁與側欄共用的呈現規則（只看既有欄位，不新增資料、不改信任）。
enum RemoteDevicePresentation {
    /// 在線＝目前有連上的遠端工作階段，或最近 10 分鐘內成功連過（`lastSeenAt` 只在連線成功時更新）。
    static func isOnline(_ device: DeviceRecord, sections: [RemoteSidebarSection], now: Date = Date()) -> Bool {
        if sections.first(where: { $0.deviceID == device.id })?.isOnline == true { return true }
        return now.timeIntervalSince(device.lastSeenAt) < 600
    }

    /// 跟資料夾專案區別：mini 用 macmini，其餘用 desktopcomputer。
    static func icon(_ device: DeviceRecord) -> String {
        device.name.lowercased().contains("mini") ? "macmini" : "desktopcomputer"
    }
}

/// Shared by both device surfaces; editing only changes routes, never pairing trust.
struct DeviceEndpointsRow: View {
    let device: DeviceRecord
    var changed: (DeviceRecord) -> Void = { _ in }
    @State private var current: DeviceRecord?
    @State private var input = ""
    @State private var kind: DeviceEndpoint.Kind = .lan
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        let record = current ?? device
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(record.endpoints, id: \.self) { endpoint in
                    HStack {
                        Text("\(Self.kindLabel(endpoint.kind)) · \(endpoint.label)").textSelection(.enabled)
                        OSChipButton(title: "停用這條路（可還原）") { update(endpoint, retire: true) }.disabled(busy)
                    }
                }
                ForEach(record.retiredEndpoints, id: \.self) { endpoint in
                    Text("已停用 · \(endpoint.label)").foregroundStyle(.secondary)
                }
                HStack {
                    Picker("類型", selection: $kind) {
                        Text("區網 IP").tag(DeviceEndpoint.Kind.lan)
                        Text("隧道").tag(DeviceEndpoint.Kind.tunnel)
                        Text("SSH 別名").tag(DeviceEndpoint.Kind.alias)
                    }.frame(maxWidth: 160)
                    TextField(Self.placeholder(kind), text: $input)
                    OSChipButton(title: "加一條連線路徑") {
                        do { update(try DeviceEndpoint.parse(Self.normalized(input, kind: kind), kind: kind), retire: false) }
                        catch { message = error.localizedDescription }
                    }.disabled(busy || input.isEmpty)
                }
                // 白話說明：三種路各是什麼、照什麼順序試（順序本身沒改，見 DeviceRecord.orderedEndpoints）。
                Text("區網＝同一 Wi-Fi 直連；隧道＝出門在外走 Cloudflare；SSH 別名＝用 ~/.ssh/config 的設定。依區網→隧道→別名順序嘗試。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.isEmpty { Text(message).foregroundStyle(.orange) }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let fresh = (0...60).contains(context.date.timeIntervalSince(record.lastSeenAt))
                Text("連線路徑 \(record.endpoints.count) · " + (record.lastEndpoint.map {
                    fresh ? "最近可用 \($0.label)" : "目前未知（上次 \($0.label)）"
                } ?? "目前未知"))
            }
        }
        .font(.caption)
        .task(id: device.id) {
            while !Task.isCancelled {
                let id = device.id
                current = await Task.detached { DeviceRegistry().list().first { $0.id == id } }.value
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// 只是顯示用的白話名，存進去的還是原本的 `DeviceEndpoint.Kind`。
    private static func kindLabel(_ kind: DeviceEndpoint.Kind) -> String {
        switch kind {
        case .lan: return "區網 IP"
        case .tunnel: return "隧道"
        case .alias: return "SSH 別名"
        }
    }

    private static func placeholder(_ kind: DeviceEndpoint.Kind) -> String {
        kind == .alias ? "~/.ssh/config 裡的名稱" : "host[:port]（例：192.0.2.10:22）"
    }

    /// 選了「SSH 別名」就不用再自己打 `alias:` 前綴；解析規則本身沒動。
    private static func normalized(_ input: String, kind: DeviceEndpoint.Kind) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .alias, !text.hasPrefix("alias:") else { return text }
        return "alias:" + text
    }

    private func update(_ endpoint: DeviceEndpoint, retire: Bool) {
        busy = true
        let id = device.id
        Task {
            let result = await Task.detached { () -> Result<DeviceRecord, Error> in
                Result { try DeviceRegistry().updateEndpoint(id: id, endpoint: endpoint, retire: retire) }
            }.value
            switch result {
            case .success(let record): current = record; changed(record); input = ""; message = ""
            case .failure(let error): message = error.localizedDescription
            }
            busy = false
        }
    }
}
