import AppKit
import Combine

enum DeviceFlowKind: String, CaseIterable {
    case menu, invite, join, joinManaged, joinSandbox, progress, managed, sandbox, permissions, transfer
    var title: String {
        switch self {
        case .menu: "設備"
        case .invite: "讓別台加入"
        case .join: "我要加入別台"
        case .joinManaged: "加入成受管設備"
        case .joinSandbox: "加入成沙盒設備"
        case .progress: "正在加入你的設備群"
        case .managed: "新增受管設備"
        case .sandbox: "新增沙盒設備"
        case .permissions: "調整群組與權限"
        case .transfer: "移交主設備"
        }
    }
}

/// Card state is local, ephemeral, and deliberately absent from assistant transcripts.
@MainActor
final class DeviceFlowSession: ObservableObject {
    static let shared = DeviceFlowSession()
    struct Window {
        let code: String
        let expiresAt: Date
        let address: String
    }
    @Published private(set) var active: DeviceFlowKind?
    @Published private(set) var revision = 0
    @Published private(set) var window: Window?
    @Published private(set) var now = Date()
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var graph: DeviceFleetRoster?
    @Published private(set) var pending: DeviceFleetPendingChange?
    @Published private(set) var previewLines: [String] = []
    @Published private(set) var exchanged = false
    @Published private(set) var signedVersion: UInt64?
    @Published private(set) var connected = false
    @Published var codeCells = Array(repeating: "", count: 6) { didSet { if oldValue != codeCells { revision += 1 } } }
    @Published var address = "" { didSet { if oldValue != address { revision += 1 } } }
    @Published var deviceName = "這台" { didSet { if oldValue != deviceName { revision += 1 } } }
    @Published var selectedGroup = "" { didSet { if oldValue != selectedGroup { revision += 1 } } }
    @Published var newGroupName = "" { didSet { if oldValue != newGroupName { revision += 1 } } }
    @Published var managerName = "" { didSet { if oldValue != managerName { revision += 1 } } }
    @Published var showMainPrimary = false { didSet { if oldValue != showMainPrimary { revision += 1 } } }
    @Published var restoringDeviceID = "" {
        didSet {
            guard oldValue != restoringDeviceID else { return }
            restorationConfirmation = revokedCandidates.first { $0.id == restoringDeviceID }
            if active == .managed, let member = restorationConfirmation {
                selectedGroup = member.groupID
                if let group = graph?.groups.first(where: { $0.id == member.groupID }) { managerName = group.managerDisplayName }
            }
            if restoringDeviceID.isEmpty { resetSelectedGroup() }
            revision += 1
        }
    }
    @Published private(set) var restorationConfirmation: DeviceFleetMember?
    @Published private(set) var joinedDeviceLabel = ""
    @Published private(set) var pairingHistoryNotice = ""
    private var baselineRevoked = Set<String>()
    private var baselineRePairVersions: [String: UInt64] = [:]
    @Published private(set) var leaveRequests: [String] = []
    private var previewBeforeJoining = false
    var managedLocally: Bool { (try? store.trust())?.kind != nil && (try? store.trust())?.kind != .owner }
    var revokedCandidates: [DeviceFleetMember] {
        guard canInviteSandbox else { return [] }
        return graph?.devices.filter { row in
            guard graph?.canRestore(row.id) == true else { return false }
            if active == .sandbox { return row.role == .sandbox }
            if active == .managed { return row.role != .sandbox && graph?.groups.first { $0.id == row.groupID }?.type == .sub }
            return row.role != .sandbox && graph?.groups.first { $0.id == row.groupID }?.type == .main
        } ?? []
    }
    @Published var selectedPeer = "" { didSet { if oldValue != selectedPeer { revision += 1 } } }
    @Published var transferTarget = "" { didSet { if oldValue != transferTarget { revision += 1 } } }
    @Published var signingName = "" { didSet { if oldValue != signingName { revision += 1 } } }
    var disconnectAllTargets: [String] {
        guard let graph, let pending,
              let targets = try? DeviceFleetStore.disconnectAllTargets(before: graph, after: pending.preview) else { return [] }
        return graph.devices.filter { targets.contains($0.id) }.map { DeviceFleetName.label($0, groups: graph.groups) }
    }
    @Published var disconnectAllOnRevoke = false { didSet { if oldValue != disconnectAllOnRevoke { revision += 1 } } }
    @Published private(set) var consentRequest: DeviceFleetSlice?
    @Published private(set) var consentLines: [String] = []
    @Published private(set) var awaitingInitialConsent = false
    @Published private(set) var possiblyConnected: [String] = []
    private var connectionWarningGenerations: [String: UInt64] = [:]
    @Published private(set) var pendingDeliveryLines: [String] = []
    private var projectionMembers: [DeviceFleetMember] = []
    private var projectionGroups: [DeviceFleetGroup] = []
    private var consentObserver: AnyCancellable?
    var hasRevocation: Bool { pending?.changes.contains { if case .revoke = $0 { return true }; return false } == true }
    var hasConnectionCut: Bool {
        guard let pending, let graph else { return false }
        if hasRevocation { return true }
        return graph.devices.contains { peer in
            graph.devices.contains { target in
                guard (try? graph.usesUnrestrictedKey(from: peer.id, to: target.id)) == true else { return false }
                return (try? pending.preview.usesUnrestrictedKey(from: peer.id, to: target.id)) != true
            }
        }
    }
    var possiblyConnectedLabels: [String] {
        possiblyConnected.map(deviceStatusLabel)
    }
    private func deviceStatusLabel(_ id: String) -> String {
        (graph?.devices ?? projectionMembers).first { $0.id == id }.map {
            DeviceFleetName.label($0, groups: graph?.groups ?? projectionGroups)
        } ?? dispatch.registry.list().first { $0.id == id }.map(DeviceFleetName.label) ?? String(id.prefix(8))
    }
    // Bind authority to this local session, the complete rendered input, card revision and proposal id.
    var cardBinding: String {
        String(describing: ObjectIdentifier(self)) + ":" + [String(revision), active?.rawValue ?? "", pending?.id.uuidString ?? "",
            String(graph?.version ?? 0), transferTarget, signingName, code, address, deviceName,
            selectedGroup, selectedPeer, newGroupName, managerName, String(showMainPrimary), restoringDeviceID, String(disconnectAllOnRevoke),
            String(consentRequest?.revision ?? 0), consentLines.joined(separator: "|"),
            possiblyConnected.sorted().map { $0 + ":" + String(connectionWarningGenerations[$0] ?? 0) }.joined(separator: "|")].joined(separator: "\u{1F}")
    }
    var invitationConsentLines: [String] {
        guard var roster = graph, let main = roster.groups.first(where: { $0.type == .main }) else {
            return ["取得實際名單後，會逐台列出控制者與權限；未確認前不開放控制。"]
        }
        if let member = roster.devices.first(where: { $0.id == restoringDeviceID }) {
            roster.revoked.removeAll { $0 == member.id }
            let heading = ["恢復：" + DeviceFleetName.label(member, groups: roster.groups),
                "群組：" + (roster.groups.first { $0.id == member.groupID }?.name ?? member.groupID),
                "將恢復的角色：" + DeviceFleetName.label(member, groups: roster.groups)]
            if roster.kind(of: member.id) == .owner {
                let lines = roster.devices.filter { $0.id != member.id && !roster.revoked.contains($0.id) }.map { other in
                    let incoming = (try? roster.capabilities(from: other.id, to: member.id)) ?? []
                    let outgoing = (try? roster.capabilities(from: member.id, to: other.id)) ?? []
                    return DeviceFleetName.label(other, groups: roster.groups) + " → 此設備：" + incoming.map { DeviceFleetCapabilities.labels[$0] ?? $0 }.joined(separator: "、")
                        + "；此設備 → 對方：" + outgoing.map { DeviceFleetCapabilities.labels[$0] ?? $0 }.joined(separator: "、")
                }
                return heading + lines + [DeviceFleetCapabilities.unrestrictedOwnerExplanation]
            }
            guard let slice = try? roster.slice(for: member.id) else { return heading + ["無法取得原箭頭，不能產生恢復碼。"] }
            let labels = controllerLabels(roster)

            return heading + DeviceFleetStore.consentLines(slice, labels: labels)
        }
        let sandbox = active == .sandbox
        let targetID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let groupID = sandbox ? main.id : selectedGroup
        let role: DeviceFleetRole = sandbox ? .sandbox : .secondary
        if !sandbox, !roster.groups.contains(where: { $0.id == groupID }) {
            roster.groups.append(.init(id: groupID, name: DeviceFleetName.clean(newGroupName).isEmpty ? "新群組" : DeviceFleetName.clean(newGroupName), type: .sub,
                primaryDeviceID: "", parentGroupID: main.id, managerDisplayName: DeviceFleetName.clean(managerName)))
        }
        let target = DeviceFleetMember(id: targetID, name: "新設備", factionID: groupID, role: role,
            clientKeyFingerprint: nil, hostKeyFingerprint: nil, clientPublicKey: nil, hostPublicKey: nil,
            endpoints: [], user: "fixture", legacy: true)
        roster.removeStaffInterconnections()
        roster.devices.append(target)
        // Mirror admission: retain customized arrows and add only missing new-member defaults.
        for edge in DeviceFleetRoster.defaults(groups: roster.groups, devices: roster.devices)
            where edge.from == .device(targetID) || edge.to == .device(targetID)
                || edge.from == .group(groupID) || edge.to == .group(groupID) {
            if !roster.edges.contains(where: { $0.from == edge.from && $0.to == edge.to }) { roster.edges.append(edge) }
        }
        guard let slice = try? roster.slice(for: targetID) else { return ["取得實際名單後再逐台確認權限；未確認前不開放控制。"] }
        let labels = controllerLabels(roster)
        return DeviceFleetStore.consentLines(slice, labels: labels)
            + (!sandbox ? [DeviceFleetDefaults.staffRoleExplanation] : [])
    }
    private func controllerLabels(_ roster: DeviceFleetRoster) -> [String: String] {
        Dictionary(roster.devices.compactMap { row -> (String, String)? in
            guard let fp = row.clientKeyFingerprint,
                  let active = graph?.activeMember(clientFingerprint: fp) ?? roster.activeMember(clientFingerprint: fp) else { return nil }
            return (fp, DeviceFleetName.label(active, groups: roster.groups))
        }, uniquingKeysWith: { first, _ in first })
    }
    private func resetSelectedGroup() {
        selectedGroup = graph?.groups.first { $0.type == .sub }?.id ?? "new"
    }
    let discovery = DevicePairingDiscovery()
    let clipboard: DevicePairingClipboard
    let store: DeviceFleetStore
    let environment: [String: String]
    private let host: DevicePairingHost
    let dispatch: DeviceDispatch
    private var timer: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var baselineMembers: Set<String> = []
    private var baselineVersion: UInt64 = 0
    private var joinedID: String?
    private var joiningKind: DeviceFactionKind = .owner
    private var inviting = false
    private var windowGeneration: UUID?
    var onPaired: (() -> Void)?

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         pasteboard: NSPasteboard = .general,
         rpc: ((DeviceRecord, String, [String: Any]) throws -> [String: Any])? = nil) {
        self.environment = environment
        let registry = DeviceRegistry(environment: environment)
        store = DeviceFleetStore(registry: registry, environment: environment)
        host = DevicePairingHost(registry: registry, environment: environment)
        dispatch = DeviceDispatch(entry: TatwoEntry(environment: environment), registry: registry, environment: environment, rpc: rpc)
        clipboard = DevicePairingClipboard(pasteboard: pasteboard)
        consentObserver = NotificationCenter.default.publisher(for: Notification.Name("tatwo.fleet.consent.changed"))
            .receive(on: DispatchQueue.main).sink { [weak self] note in
                guard let self, note.object as? String == self.store.url.path else { return }
                Task { @MainActor in
                    await self.refresh()
                    // Pending consent stays visible in the device page; repeated rosters never steal focus.
                    if self.active == .permissions { self.revision += 1 }
                }
            }

    }
    var code: String { codeCells.joined() }
    var remaining: Int { max(0, Int(ceil((window?.expiresAt ?? now).timeIntervalSince(now)))) }
    var transferCandidates: [DeviceFleetMember] {
        guard let graph else { return [] }
        return graph.devices.filter { graph.kind(of: $0.id) == .owner && $0.id != graph.primaryID && !graph.revoked.contains($0.id) }
    }
    var localID: String? {
        try? DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: environment))?.deviceID
    }
    var canTransfer: Bool { localID == graph?.primaryID && graph != nil }
    var canInviteSandbox: Bool {
        do {
            guard let identity = try DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: environment)),
                  identity.role == .primary else { return false }
            guard let trust = try store.read().trust else { return true }
            return trust.kind == .owner && trust.localID == trust.primaryID && trust.localID == identity.deviceID
        } catch { return false }
    }
    var primaryName: String { graph?.devices.first { $0.id == graph?.primaryID }?.name ?? "主設備" }
    var matchingPeers: [DevicePairingDiscovery.Peer] { discovery.matches(code: code) }

    func setCell(_ index: Int, text: String) {
        guard codeCells.indices.contains(index) else { return }
        let normalized = DevicePairingInput.normalizedCode(text)
        if normalized.isEmpty { codeCells[index] = ""; return }
        if normalized.count > 1 {
            for (offset, letter) in normalized.enumerated() where index + offset < 6 { codeCells[index + offset] = String(letter) }
        } else { codeCells[index] = normalized }
        selectedPeer = ""
    }
    func open(_ kind: DeviceFlowKind) throws {
        guard !busy, pending == nil, window == nil else { throw DeviceFleetError.staleProposal }
        restoringDeviceID = ""; restorationConfirmation = nil
        active = kind; resetSelectedGroup(); message = ""; revision += 1
        if kind == .join || kind == .joinManaged || kind == .joinSandbox { discovery.browse() }
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.tick()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
        if refreshTask == nil {
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
        }
    }
    func tick(at date: Date = Date()) {
        now = date
        if let window, window.expiresAt <= date {
            inviting = false; windowGeneration = nil; restoringDeviceID = ""; restorationConfirmation = nil
            host.cancelPairingWindow(); self.window = nil
            discovery.stopAdvertising(); clipboard.clear(); message = "配對碼已過期，請重新產生。"
        }
    }
    func close() {
        restoringDeviceID = ""; restorationConfirmation = nil; resetSelectedGroup()
        guard !busy else { return }
        inviting = false; windowGeneration = nil; host.cancelPairingWindow(); window = nil; clipboard.clear(); discovery.stop()
        if let pending { store.discardProposal(pending.id) }
        previewBeforeJoining = false
        restoringDeviceID = ""; restorationConfirmation = nil
        pending = nil; previewLines = []; active = nil; consentRequest = nil; consentLines = []; disconnectAllOnRevoke = false; revision += 1
        message = ""
        timer?.cancel(); timer = nil
        refreshTask?.cancel(); refreshTask = nil
    }
    func report(_ text: String) { message = text }
    func confirmConnectionsClosed(_ authority: DeviceFlowUserAction) async {
        guard authority.consume(for: self), !busy, !possiblyConnected.isEmpty else { return }
        let ids = possiblyConnected, generations = connectionWarningGenerations, store = store
        busy = true; defer { busy = false }
        do {
            try await Task.detached(priority: .utility) { try store.confirmConnectionsClosed(ids: ids, generations: generations) }.value
            await refresh(); revision += 1
        } catch { message = "這次確認未儲存，請再試一次。" }
    }
    func reveal() { revision += 1 }
    func copyCode(_ authority: DeviceFlowUserAction) {
        guard authority.consume(for: self) else { return }
        copyCodeForLocalAction()
    }
    private func copyCodeForLocalAction() {
        guard let window, window.expiresAt > now else { return }
        clipboard.copy(.code, address: window.address, code: window.code, expiresAt: window.expiresAt)
    }
    func refresh() async {
        let store = store, dispatch = dispatch
        let snapshot = await Task.detached(priority: .utility) {
            (try? store.readGraph(), try? store.pending(), dispatch.registry.list(), try? store.pendingConsent(), try? store.read(), (try? store.pendingManagedRemoval()) ?? [], (try? store.keyRemovalWarnings()) ?? [])
        }.value
        graph = snapshot.0?.roster
        projectionMembers = snapshot.0?.slice?.devices ?? []
        projectionGroups = snapshot.0?.slice?.group.map { [$0] } ?? []
        pendingDeliveryLines = snapshot.4?.trust?.localID == snapshot.4?.trust?.primaryID
            ? DeviceFleetStore.deliveryWarnings(roster: snapshot.0?.roster, problems: snapshot.4?.deliveryProblems ?? [:], includeRevocations: false).values.sorted() : []
        pendingDeliveryLines += snapshot.6
        if !previewBeforeJoining {
            if consentRequest != snapshot.3 { revision += 1 }
            consentRequest = snapshot.3
            consentLines = snapshot.3.map { DeviceFleetStore.consentLines($0, ceiling: snapshot.4?.consentCeiling ?? [:]) } ?? []
        }
        leaveRequests = snapshot.4?.trust?.kind == .owner && snapshot.4?.trust?.localID == graph?.primaryID
            ? (snapshot.4?.leaveRequests ?? []).filter { graph?.revoked.contains($0) != true } : []
        awaitingInitialConsent = snapshot.4?.consentCeiling?.isEmpty != false
        possiblyConnected = snapshot.4?.possiblyConnected ?? []
        connectionWarningGenerations = snapshot.4?.possiblyConnectedDevices ?? [:]
        if selectedGroup.isEmpty { selectedGroup = graph?.groups.first { $0.type == .sub }?.id ?? "new" }
        if deviceName == "這台", let id = localID,
           let name = graph?.devices.first(where: { $0.id == id })?.name { deviceName = name }
        let newMembers = Set((graph?.devices.map(\.id) ?? []) + (snapshot.1?.map(\.id) ?? [])).subtracting(baselineMembers)
        let restoredMembers = baselineRevoked.subtracting(graph?.revoked ?? []).filter { id in graph?.devices.contains { $0.id == id } == true }
        if inviting, !newMembers.isEmpty || !restoredMembers.isEmpty {
            inviting = false
            joinedID = restoredMembers.first ?? newMembers.first; exchanged = true; active = .progress
            if let member = graph?.devices.first(where: { $0.id == joinedID }) ?? snapshot.1?.first(where: { $0.id == joinedID }) {
                joinedDeviceLabel = DeviceFleetName.label(member, groups: graph?.groups ?? [])
                if graph?.devices.contains(where: { $0.id == member.id }) != true {
                    let wasRevoked = member.clientKeyFingerprint.map { fingerprint in
                        graph?.devices.contains { $0.clientKeyFingerprint == fingerprint && graph?.revoked.contains($0.id) == true } == true
                    } ?? false
                    pairingHistoryNotice = (wasRevoked ? "這把金鑰曾被撤銷；尚未加入名單或解除舊金鑰墓碑。" : "尚未加入名單。")
                        + "請到主設備本機重新配對並實體確認。"
                } else if restoredMembers.contains(member.id) { pairingHistoryNotice = "已恢復「" + joinedDeviceLabel + "」的原身分與原箭頭。" }
                else if let fp = member.clientKeyFingerprint, let revision = graph?.rePairVersions?[fp], revision > (baselineRePairVersions[fp] ?? 0) {
                    pairingHistoryNotice = "這把金鑰曾被撤銷；一般配對已用新身分加入並解除舊金鑰墓碑。"
                }
            }
            restoringDeviceID = ""; restorationConfirmation = nil
            host.cancelPairingWindow(); window = nil; clipboard.clear(); discovery.stopAdvertising(); revision += 1
            onPaired?()
        }
        if !inviting, !restoringDeviceID.isEmpty, graph?.revoked.contains(restoringDeviceID) != true {
            restoringDeviceID = ""; restorationConfirmation = nil; message = "這台已恢復"
        }
        if active == .progress, exchanged {
            let included = joinedID.map { id in graph?.devices.contains { $0.id == id } == true } ?? false
            signedVersion = included && (graph?.version ?? 0) > baselineVersion ? graph?.version : nil
            if joiningKind != .owner, let slice = snapshot.0?.slice, !slice.revoked {
                signedVersion = slice.revision; connected = true
            } else if let version = signedVersion, !connected {
                let roster = graph
                connected = await Task.detached(priority: .utility) {
                    guard let roster, roster.version == version else { return false }
                    return dispatch.flowOwnerConnectionsReady(roster)
                }.value
            }
        }
    }
    func generateFromCard(_ authority: DeviceFlowUserAction) async {
        guard authority.consume(for: self), !busy, let active, [.invite, .managed, .sandbox].contains(active) else { return }
        if !restoringDeviceID.isEmpty {
            guard let roster = try? store.current()?.roster, roster.revoked.contains(restoringDeviceID),
                  canInviteSandbox, restorationConfirmation?.id == restoringDeviceID,
                  (active != .managed || selectedGroup == restorationConfirmation?.groupID) else {
                restoringDeviceID = ""; restorationConfirmation = nil; message = "這台已恢復"; return
            }
        }
        busy = true; message = ""
        host.cancelPairingWindow()
        let generation = UUID()
        windowGeneration = generation
        host.onClose = { [weak self] in
            Task { @MainActor in
                guard let self, self.windowGeneration == generation else { return }
                await self.refresh()
                guard self.windowGeneration == generation else { return }
                self.discovery.stopAdvertising(); self.window = nil; self.clipboard.clear()
                self.inviting = false; self.windowGeneration = nil
                self.restoringDeviceID = ""; self.restorationConfirmation = nil
            }
        }
        let kind: DeviceFactionKind = active == .managed ? .managed : active == .sandbox ? .sandbox : .owner
        let store = store, host = host
        let groupID = selectedGroup, newName = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let manager = managerName.trimmingCharacters(in: .whitespacesAndNewlines), show = showMainPrimary
        let current = graph, restoreID = restoringDeviceID.isEmpty ? nil : restoringDeviceID
        do {
            if kind == .managed, manager.isEmpty || (groupID == "new" && newName.isEmpty) {
                throw DeviceFleetError.malformed
            }
            let result = try await Task.detached {
                var chosen = kind == .sandbox ? current?.groups.first { $0.type == .main }?.id : nil
                if kind == .managed, restoreID == nil {
                    let id = groupID == "new" ? UUID().uuidString : groupID
                    let name = groupID == "new" ? newName : current?.groups.first { $0.id == id }?.name ?? newName
                    try store.setFaction(.init(id: id, name: name, kind: .managed,
                                              managerDisplayName: manager, showPrimaryToMembers: show))
                    chosen = id
                }
                if kind == .managed, restoreID != nil { chosen = groupID }
                let window = try host.startPairingWindow(kind: kind, factionID: chosen, restoringDeviceID: restoreID)
                return (window, try store.readGraph()?.roster)
            }.value
            graph = result.1
            baselineMembers = Set((graph?.devices.map(\.id) ?? []) + (try store.pending().map(\.id))); baselineVersion = graph?.version ?? 0
            baselineRevoked = Set(graph?.revoked ?? []); baselineRePairVersions = graph?.rePairVersions ?? [:]
            joinedDeviceLabel = ""; pairingHistoryNotice = ""
            joiningKind = kind; exchanged = false; signedVersion = nil; connected = false; joinedID = nil
            window = .init(code: result.0.code, expiresAt: result.0.expiresAt, address: result.0.listenAddress)
            inviting = true
            if let endpoint = DevicePairingInput.parseAddress(result.0.listenAddress), let port = Int(endpoint.port) {
                let advertisedName = kind == .owner ? deviceName : manager.isEmpty ? "TATWO 管理者" : manager
                discovery.advertise(code: result.0.code, port: port, name: advertisedName)
            }
            revision += 1
        } catch {
            if windowGeneration == generation { windowGeneration = nil; host.cancelPairingWindow() }
            message = DevicePairingFeedback.invitationFailure(error)
        }
        busy = false
    }
    func joinFromCard(_ authority: DeviceFlowUserAction) async {
        guard authority.consume(for: self) else { return }
        await joinFromLocalAction(preview: active != .join)
    }
    private func joinFromLocalAction(preview: Bool) async {
        guard !busy, let active, [.join, .joinManaged, .joinSandbox].contains(active), code.count == 6 else { return }
        let kind: DeviceFactionKind = active == .joinManaged ? .managed : active == .joinSandbox ? .sandbox : .owner
        let candidates = matchingPeers
        let peer = candidates.first { $0.id == selectedPeer } ?? candidates.first
        let endpoint = DevicePairingInput.parseAddress(address)
        guard let host = endpoint?.host ?? peer?.host, let port = endpoint.flatMap({ Int($0.port) }) ?? peer?.port else {
            message = "還沒找到那台；確認兩台在同一個網路，或展開進階填位址。"; return
        }
        let endpoints = endpoint != nil || !selectedPeer.isEmpty ? [(host, port)] : candidates.map { ($0.host, $0.port) }
        let code = code, name = DeviceFleetName.clean(deviceName), environment = environment
        guard !name.isEmpty else { message = "請填這台的名字。"; return }
        let expected = preview ? nil : consentRequest.flatMap { try? DeviceFleetStore.consentDigest($0) }
        busy = true; message = ""; exchanged = false; signedVersion = nil; connected = false
        baselineVersion = graph?.version ?? 0
        do {
            let result = try await Task.detached {
                var failure: Error = DevicePairingClient.ClientError.responseUnauthenticated
                for (host, port) in endpoints {
                    do {
                        let client = DevicePairingClient(environment: environment)
                        let record = try client.pair(host: host, port: port, code: code, name: name, kind: kind,
                            consentToManagement: kind != .owner, previewOnly: preview, previewDigest: expected)
                        return (record, client.managementPreview)
                    }
                    catch DevicePairingClient.ClientError.responseUnauthenticated { failure = DevicePairingClient.ClientError.responseUnauthenticated }
                    catch { throw error }
                }
                throw failure
            }.value
            if preview, let slice = result.1 {
                previewBeforeJoining = true; consentRequest = slice
                consentLines = DeviceFleetStore.consentLines(slice); awaitingInitialConsent = true
                revision += 1; busy = false; return
            }
            previewBeforeJoining = false
            if kind != .owner, try !approveJoinedConsent(expected: expected) { return }
            consentRequest = nil; consentLines = []
            let record = result.0
            joinedID = localID; joiningKind = kind; exchanged = true; self.active = .progress
            codeCells = Array(repeating: "", count: 6); address = ""; discovery.stop(); revision += 1
            message = "已與「\(record.name)」互換鑰匙。"
            if kind == .owner, (try? store.current()?.roster?.devices.contains { $0.id == localID }) != true {
                pairingHistoryNotice = "尚未加入名單。請到主設備本機重新配對並實體確認。"
            }
            onPaired?()
            await refresh()
        } catch {
            message = DevicePairingFeedback.failure("配對失敗：\(error.localizedDescription)")?.message ?? "配對沒有完成。"
        }
        busy = false
    }
    func approveJoinedConsent(expected: String?) throws -> Bool {
        guard let slice = try store.pendingConsent() else { return true }
        guard let expected, try DeviceFleetStore.consentDigest(slice) == expected else {
            consentRequest = slice; consentLines = DeviceFleetStore.consentLines(slice)
            awaitingInitialConsent = true; message = "權限已改變，請重新確認這份同意卡。"
            revision += 1; busy = false; return false
        }
        try store.approveConsent(revision: slice.revision, controllers: slice.controllers)
        return true
    }
    func propose(_ changes: [DeviceFleetChange]) throws -> DeviceFleetPendingChange {
        guard !busy, pending == nil, window == nil, let actor = localID,
              let roster = try store.readGraph()?.roster else { throw DeviceFleetError.primaryRequired }
        let proposal = try store.propose(changes, actor: actor)
        message = ""
        pending = proposal; graph = roster; disconnectAllOnRevoke = false
        previewLines = DeviceFlowPreview.lines(before: roster, proposal: proposal, registry: dispatch.registry)
        active = .permissions; revision += 1
        return proposal
    }
    func confirmFromCard(_ authority: DeviceFlowUserAction) async {
        guard authority.consume(for: self), !busy, let pending else { return }
        busy = true
        do {
            let store = store, dispatch = dispatch, token = pending.id
            let disconnect = hasConnectionCut && disconnectAllOnRevoke
            _ = try await Task.detached {
                let envelope = try disconnect ? store.confirm(token, userConfirmed: true, disconnectAllSelected: true)
                    : store.confirm(token, userConfirmed: true)
                dispatch.pushFleetNow()
                return envelope
            }.value
            disconnectAllOnRevoke = false
            self.pending = nil; previewLines = []; message = "已確認並簽發新名單。"; revision += 1
            for change in pending.changes {
                if case .revoke(let id) = change {
                    do { try await Self.archiveOfflineCopy(id, environment: environment) }
                    catch { message += "\n離線副本移到垃圾桶未完成，副本還留在這台電腦上。" }
                }
            }
            await refresh()
            message += pendingDeliveryLines.filter { $0.contains("備份失敗") }.map { "\n" + $0 }.joined()
        } catch { message = "這份預覽現在無法簽發；請取消後重新提案，並在主設備確認。" }
        busy = false
    }
    static func archiveOfflineCopy(_ id: String, environment: [String: String]) async throws {
        let cache = RemoteOfflineCache(root: RemoteOfflineCache.defaultRoot(environment: environment))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cache.run({ cache in Result { _ = try cache.clear(deviceID: id) } }) { continuation.resume(with: $0) }
        }
    }
    func approveConsentFromCard(_ authority: DeviceFlowUserAction, revision: UInt64) async {
        guard authority.consume(for: self), !busy, let request = consentRequest, request.revision == revision else { return }
        if previewBeforeJoining { await joinFromLocalAction(preview: false); return }
        busy = true
        do {
            let store = store
            try await Task.detached { try store.approveConsent(revision: request.revision, controllers: request.controllers) }.value
            message = "已在這台同意列出的權限。"; consentRequest = nil; consentLines = []; self.revision += 1
        } catch { message = "名單已變動，請重新看過權限再確認。" }
        busy = false; await refresh()
    }
    func requestLeaveFromCard(_ authority: DeviceFlowUserAction) async {
        guard authority.consume(for: self), !busy, managedLocally else { return }
        busy = true
        do {
            let store = store
            try await Task.detached { try store.requestLeave() }.value
            message = "已撤回操作權限並申請離開，等待主設備核准。"; revision += 1
        } catch { message = "離開申請未完成，請重試。" }
        busy = false; await refresh()
    }
    func proposeLeaveApproval(_ id: String) {
        guard canInviteSandbox else { message = "請在主設備的私訊框核准離開。"; return }
        guard leaveRequests.contains(id) else { return }
        do { _ = try propose([.revoke(id: id)]) }
        catch { message = "請先完成目前的確認，再核准離開。" }
    }
    func cancelProposal() {
        guard !busy else { return }
        if let pending { store.discardProposal(pending.id) }
        pending = nil; previewLines = []; message = "已取消，名單未更動。"; revision += 1
    }
    func transferFromLocalDialog(_ authority: DeviceFlowUserAction) async {
        guard authority.consume(for: self), !busy, canTransfer, transferCandidates.contains(where: { $0.id == transferTarget }) else {
            message = "移交條件或確認已改變，請重新選擇可移交的副設備，再按確認移交。"
            return
        }
        guard !signingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "請填寫與現任主設備相同的簽章身分名稱，再確認移交。"; return
        }
        busy = true
        let dispatch = dispatch, target = transferTarget, name = signingName
        let error = await Task.detached {
            do { try dispatch.beginTransfer(to: target, signingName: name); return "" }
            catch { return DeviceFleetReason.plain(error, context: .transfer(nil)) }
        }.value
        message = error.isEmpty ? "已開始移交；接著逐項驗收正本、GBrain 與發行能力。" : error
        busy = false; await refresh()
    }
    #if DEBUG
    func copyCode() { copyCodeForLocalAction() }
    func fixtureCard(_ kind: DeviceFlowKind, window: Window? = nil) {
        active = kind; self.window = window; message = ""; revision += 1
    }
    func fixtureProgress(exchanged: Bool, version: UInt64?, connected: Bool) {
        self.exchanged = exchanged; signedVersion = version; self.connected = connected
    }
    func fixtureAwaitingMember() {
        baselineMembers = Set(graph?.devices.map(\.id) ?? [])
        baselineRevoked = Set(graph?.revoked ?? [])
        baselineRePairVersions = graph?.rePairVersions ?? [:]
        inviting = true
    }
    #endif
}

enum DeviceFlowPreview {
    static func direction(_ value: DeviceFleetEdge.Direction?, from: String, to: String) -> String {
        switch value { case .mutual: "互通"; case .oneway: "單向：\(from) 控制 \(to)"; default: "不連" }
    }
    static func capability(_ key: String) -> String {
        DeviceFleetCapabilities.labels[key] ?? "未知權限"
    }
    static func lines(before: DeviceFleetRoster, proposal: DeviceFleetPendingChange, registry: DeviceRegistry? = nil) -> [String] {
        let after = proposal.preview
        func label(_ endpoint: DeviceFleetEndpoint) -> String {
            endpoint.kind == .group ? (before.groups + after.groups).first { $0.id == endpoint.id }?.name ?? "新群組"
                : (before.devices + after.devices).first { $0.id == endpoint.id }.map { DeviceFleetName.label($0, groups: before.groups + after.groups) } ?? "新設備"
        }
        var result: [String] = []
        for id in after.revoked where !before.revoked.contains(id) {
            let name = before.devices.first { $0.id == id }.map { DeviceFleetName.label($0, groups: before.groups + after.groups) } ?? "設備"
            result.append("撤銷設備：「\(name)」；移除金鑰並中斷可辨識的連線。這台目前可能還有連線；無法辨識或共用位址的舊連線可能繼續。")
            result.append("「\(name)」存在這台的離線副本一起移到垃圾桶（可以放回）")
            if let member = before.devices.first(where: { $0.id == id }), let fp = registry?.fleetClientFingerprint(member),
               !after.devices.contains(where: { !after.revoked.contains($0.id) && registry?.fleetClientFingerprint($0) == fp }) {
                result.append("其他沒被撤銷的電腦也會移除「\(name)」的鑰匙；你自己加的那行，每台先備份成功才移除。")
                if let lines = try? registry?.authorizedUserLines(fingerprint: fp), !lines.isEmpty {
                    result.append("你在這台電腦上手動加的同一把鑰匙也會一起移除（移除前會先備份）。")
                }
            }
        }
        func changed(_ title: String, _ old: String, _ new: String) {
            if old != new { result.append("\(title)：原本：\(old) → 改成：\(new)") }
        }
        // Compare the final preview so repeated edits and reverted edits do not show unchanged rows.
        for group in after.groups {
            guard let old = before.groups.first(where: { $0.id == group.id }) else {
                changed("群組", "無", "新增「\(group.name)」"); continue
            }
            changed("群組名稱", old.name, group.name)
            changed("「\(old.name)」管理者名稱", old.managerDisplayName, group.managerDisplayName)
            if group.type == .sub && old.primaryDeviceID != group.primaryDeviceID {
                changed("「\(group.name)」的 SUB 主設備",
                        old.primaryDeviceID.isEmpty ? "未指定" : label(.device(old.primaryDeviceID)),
                        group.primaryDeviceID.isEmpty ? "未指定" : label(.device(group.primaryDeviceID)))
                result.append(DeviceFleetDefaults.staffRoleExplanation)
            }
            changed("「\(old.name)」的職員電腦顯示主設備", old.showMainPrimary ? "開" : "關", group.showMainPrimary ? "開" : "關")
        }
        for device in after.devices {
            guard let old = before.devices.first(where: { $0.id == device.id }) else {
                changed(device.role == .sandbox ? "沙盒" : "設備", "無", "新增「\(DeviceFleetName.label(device, groups: before.groups + after.groups))」"); continue
            }
            // Role designation is already shown at group level; it does not rename the device.
            if old.name != device.name {
                changed("設備名稱", DeviceFleetName.label(old, groups: before.groups + after.groups), DeviceFleetName.label(device, groups: before.groups + after.groups))
            }
            changed("「\(DeviceFleetName.label(old, groups: before.groups + after.groups))」所在群組", label(.group(old.groupID)), label(.group(device.groupID)))
        }
        for target in after.devices where !after.revoked.contains(target.id) {
            if let old = before.devices.first(where: { $0.id == target.id }), before.kind(of: old.id) != after.kind(of: target.id) {
                let consequence = after.kind(of: target.id) == .owner
                    ? "成為我的設備：可讀完整名單、控制職員與沙盒、再收設備；必須以我的設備配對碼重新配對，兩邊實體確認。"
                    : "成為受管或沙盒：不再能讀我的設備名單或連回我的設備；新的控制者將能依下列權限操作這台。"
                result.append("⚠ 身分變更：\(DeviceFleetName.label(target, groups: before.groups + after.groups))；\(consequence)")
            }
            for source in after.devices where source.id != target.id && !after.revoked.contains(source.id) {
                let old = Set((try? before.capabilities(from: source.id, to: target.id)) ?? [])
                let new = Set((try? after.capabilities(from: source.id, to: target.id)) ?? [])
                let gains = new.subtracting(old).sorted()
                if !gains.isEmpty {
                    result.append("新增控制權：\(DeviceFleetName.label(source, groups: before.groups + after.groups)) 可對 \(DeviceFleetName.label(target, groups: before.groups + after.groups))：\(gains.map(capability).joined(separator: "、"))。")
                }
            }
        }
        let edges = before.edges + after.edges.filter { edge in
            !before.edges.contains { $0.from == edge.from && $0.to == edge.to }
        }
        let removedPeers = before.edges.filter { before.isStaffInterconnection($0) }
        if !removedPeers.isEmpty {
            result.append("依裁決移除職員電腦之間的箭頭與控制權。" + DeviceFleetDefaults.staffRoleExplanation)
        }
        for edge in edges where !before.isStaffInterconnection(edge) {
            let old = before.edges.first { $0.from == edge.from && $0.to == edge.to }
            let new = after.edges.first { $0.from == edge.from && $0.to == edge.to }
            let from = label(edge.from), to = label(edge.to), title = "「\(from)」與「\(to)」"
            let mainID = after.groups.first { $0.type == .main }?.id
            let ownerPair = (edge.from.kind == .group ? edge.from.id == mainID : after.kind(of: edge.from.id) == .owner)
                && (edge.to.kind == .group ? edge.to.id == mainID : after.kind(of: edge.to.id) == .owner)
            if ownerPair, old != new, old?.direction != DeviceFleetEdge.Direction.none, Set(old?.capabilities ?? []) == Set(DeviceFleetCapabilities.all),
               new?.direction == .none || Set(new?.capabilities ?? []) != Set(DeviceFleetCapabilities.all) {
                result.append("⚠ " + title + "收窄後，無法辨識的既有 SSH 連線可能繼續；可選擇中斷主設備及受影響的「我的設備」上所有遠端連線。")
            }
            if old?.direction == .none || Set(old?.capabilities ?? []) != Set(DeviceFleetCapabilities.all), new?.direction != DeviceFleetEdge.Direction.none, Set(new?.capabilities ?? []) == Set(DeviceFleetCapabilities.all) {
                let main = after.groups.first { $0.type == .main }?.id
                let fromMain = edge.from.kind == .group ? edge.from.id == main : after.kind(of: edge.from.id) == .owner
                let toMain = edge.to.kind == .group ? edge.to.id == main : after.kind(of: edge.to.id) == .owner
                if fromMain && toMain { result.append(DeviceFleetCapabilities.unrestrictedOwnerExplanation) }
            }
            if old != new, new?.direction == .none, !ownerPair { result.append("不連會清掉使用者權限；仍保留已驗章的名單與撤銷通道。") }
            changed(title, direction(old?.direction, from: from, to: to), direction(new?.direction, from: from, to: to))
            for key in DeviceFleetCapabilities.all {
                let wasAllowed = old.map { $0.direction != .none && $0.capabilities.contains(key) } ?? false
                let isAllowed = new.map { $0.direction != .none && $0.capabilities.contains(key) } ?? false
                changed("\(title)・\(capability(key))", wasAllowed ? "允許" : "不允許", isAllowed ? "允許" : "不允許")
            }
        }
        for case let .stopTracking(id) in proposal.changes {
            result.append("不再追蹤「" + label(.device(id)) + "」的撤銷送達；仍保留撤銷與連線限制。")
        }
        for case let .transfer(to) in proposal.changes where to != before.primaryID {
            changed("移交主設備（仍須本機確認對話框）", label(.device(before.primaryID)), label(.device(to)))
        }
        return result
    }
}
