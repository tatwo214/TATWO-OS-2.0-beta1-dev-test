import CryptoKit
import Darwin
import Foundation
import Network

final class DevicePairingHost: @unchecked Sendable {
    private struct PairRequest: Codable {
        // W178 v2：加入端不送配對碼，改送 nonce＋HMAC；舊版加入端才會帶 code（明文）。
        var v: Int?
        var code: String?
        var nonce: String?
        var mac: String?
        let publicKey: String
        let name: String
        var user: String?
        var deviceID: String?
        // 加入端自報的兩把公鑰指紋（舊版加入端沒有這兩欄，照樣相容）。
        var clientKeyFingerprint: String?
        var hostKeyFingerprint: String?
        var fleet: String?
    }

    private struct PairResponse: Codable {
        let ok: Bool
        var deviceID: String?
        var hostName: String?
        var hostUser: String?
        var reason: String?
        var hostDeviceID: String?
        // 本機自報的兩把公鑰指紋，讓加入端把主機／客戶端金鑰分開存。
        var hostKeyFingerprint: String?
        var clientKeyFingerprint: String?
        var fleet: String?
        var previewOnly: Bool?
        var mac: String?
    }

    /// 這次配對請求導出的金鑰；回覆用它簽，加入端才分得出是不是主機本人回的。
    private struct ReplyAuth {
        let key: SymmetricKey
        let nonce: String
    }

    private final class StartProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private(set) var ready = false
        private(set) var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)

        func resolveReady() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            ready = true
            lock.unlock()
            semaphore.signal()
        }

        func resolveFailure(_ error: Error) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            failure = error
            lock.unlock()
            semaphore.signal()
        }
    }

    enum HostError: Error, LocalizedError {
        case windowClosed
        case noLocalAddress
        case noPortAvailable
        case listenerStartTimedOut
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .windowClosed: "pairing_window_closed"
            case .noLocalAddress: "pairing_no_local_address"
            case .noPortAvailable: "pairing_no_port_available"
            case .listenerStartTimedOut: "pairing_listener_start_timed_out"
            case let .listenerFailed(reason): "pairing_listener_failed:\(reason)"
            }
        }
    }

    private let registry: DeviceRegistry
    private let environment: [String: String]
    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.device-pairing-host")
    private let stateLock = NSLock()
    private let peerHostResolver: (NWEndpoint) -> String
    private var listener: NWListener?
    private var activeCode: TatwoDevicePairingCodeRecordV1?
    private var activeToken: UUID?
    private var failedAttempts = 0
    private var fleetOffer: DeviceFleetPairOffer?
    private var restoringDeviceID: String?
    private(set) var port: Int?
    var onClose: (() -> Void)?
    #if DEBUG
    var afterConsume: (() -> Void)?
    var enrollmentCheck: (() throws -> Void)?
    var captureWire: ((Data, SymmetricKey) -> Void)?
    #endif

    init(
        registry: DeviceRegistry? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        peerHostResolver: ((NWEndpoint) -> String)? = nil
    ) {
        self.environment = environment
        self.registry = registry ?? DeviceRegistry(environment: environment)
        self.peerHostResolver = peerHostResolver ?? Self.remoteHost
    }

    func startPairingWindow(kind: DeviceFactionKind = .owner, factionID: String? = nil, restoringDeviceID: String? = nil) throws -> (code: String, expiresAt: Date, listenAddress: String) {
        let fleet = DeviceFleetStore(registry: registry, environment: environment)
        try fleet.requireOwner()
        cancelPairingWindow()
        if let id = restoringDeviceID {
            guard try DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: environment))?.role == .primary else { throw DeviceFleetError.primaryRequired }
            guard let roster = try fleet.current()?.roster, roster.revoked.contains(id), let member = roster.devices.first(where: { $0.id == id }),
                  roster.kindForRestoration(member) == kind,
                  (kind != .managed || factionID == member.groupID) else { throw DeviceFleetError.role }
        }
        if let roster = try fleet.current()?.roster, let id = restoringDeviceID,
           !roster.canRestore(id) { throw DeviceFleetError.keyConflict }
        self.restoringDeviceID = restoringDeviceID
        let identity = try DeviceIdentityStore.forLocalDevice(
            entry: TatwoEntry(environment: environment)).read()
        if kind == .owner, identity.role != .primary, identity.primaryDeviceID != nil { throw DeviceFleetError.primaryRequired }
        if kind == .sandbox, identity.role != .primary { throw DeviceFleetError.primaryRequired }
        if kind == .managed, identity.role != .primary { throw DeviceFleetError.primaryRequired }
        let authority = identity.primaryDeviceID ?? identity.deviceID
        let code = try TatwoDevicePairingCodeEngineV1.mint(
            createdBy: identity.deviceID,
            authorityPrimary: authority,
            // Unassigned bootstrap pairing is epoch 0; it does not grant primary role.
            authorityEpoch: UInt64(identity.epoch ?? 0),
            ttlSeconds: 300)
        guard let bindAddress = Self.bindAddress(environment: environment) else {
            throw HostError.noLocalAddress
        }
        let offer = try fleet.makeOffer(kind: kind, factionID: factionID, host: bindAddress)
        if kind != .owner, offer == nil { throw DeviceFleetError.primaryRequired }

        var lastFailure: Error?
        for candidatePort in Array(18800...18899).shuffled() {
            let nwPort = NWEndpoint.Port(rawValue: UInt16(candidatePort))!
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: nwPort)
            do {
                let candidate = try NWListener(using: parameters)
                let token = UUID()
                let probe = StartProbe()
                candidate.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection, token: token)
                }
                candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                    switch state {
                    case .ready:
                        probe.resolveReady()
                    case let .failed(error):
                        probe.resolveFailure(error)
                        if probe.ready, let candidate {
                            self?.finishWindow(listener: candidate, token: token)
                        }
                    case .cancelled:
                        if probe.ready, let candidate {
                            self?.finishWindow(listener: candidate, token: token)
                        }
                    default:
                        break
                    }
                }

                stateLock.lock()
                listener = candidate
                activeCode = code
                activeToken = token
                failedAttempts = 0
                fleetOffer = offer
                port = candidatePort
                stateLock.unlock()
                candidate.start(queue: queue)

                guard probe.semaphore.wait(timeout: .now() + 2) == .success else {
                    candidate.cancel()
                    clearIfMatching(listener: candidate, token: token, notify: false)
                    lastFailure = HostError.listenerStartTimedOut
                    continue
                }
                guard probe.ready else {
                    candidate.cancel()
                    clearIfMatching(listener: candidate, token: token, notify: false)
                    lastFailure = probe.failure
                    continue
                }

                queue.asyncAfter(deadline: .now() + 300) { [weak self, weak candidate] in
                    guard let candidate else { return }
                    self?.finishWindow(listener: candidate, token: token)
                }
                return (code.seed, code.expiresAt, "\(bindAddress):\(candidatePort)")
            } catch {
                lastFailure = error
            }
        }
        if let lastFailure {
            throw HostError.listenerFailed(lastFailure.localizedDescription)
        }
        throw HostError.noPortAvailable
    }

    func cancelPairingWindow() {
        stateLock.lock()
        let current = listener
        let token = activeToken
        stateLock.unlock()
        guard let current, let token else { return }
        finishWindow(listener: current, token: token)
    }

    private func accept(_ connection: NWConnection, token: UUID) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receiveLine(from: connection, token: token, buffer: Data())
    }

    private func receiveLine(from connection: NWConnection, token: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var joined = buffer
            if let data { joined.append(data) }
            if joined.count > 65_536 {
                self.reject(connection, token: token, reason: "request_too_large")
                return
            }
            if let newline = joined.firstIndex(of: 0x0A) {
                self.handle(Data(joined[..<newline]), from: connection, token: token)
            } else if complete || error != nil {
                self.handle(joined, from: connection, token: token)
            } else {
                self.receiveLine(from: connection, token: token, buffer: joined)
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection, token: UUID) {
        // This proof reveals no member information and never consumes the invitation.
        if let hello = try? JSONDecoder().decode([String: String].self, from: data),
           let nonce = hello["hello"], DevicePairingAuth.isValidNonce(nonce) {
            let record = stateLock.withLock { activeToken == token ? activeCode : nil }
            guard let record, record.expiresAt > Date(), record.consumedAt == nil,
                  let key = DevicePairingAuth.key(code: record.seed, nonce: nonce),
                  stateLock.withLock({ activeToken == token && activeCode == record && record.expiresAt > Date() }) else {
                connection.cancel(); return
            }
            let proof = DevicePairingAuth.mac(key: key, label: "host-proof", fields: [nonce])
            var reply = try! JSONEncoder().encode(["proof": proof]); reply.append(0x0A)
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        guard let request = try? JSONDecoder().decode(PairRequest.self, from: data),
              !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            reject(connection, token: token, reason: "bad_request")
            return
        }
        if let legacyCode = request.code {
            // 舊版加入端把配對碼明文送上網路。拒絕；碼若是對的就視同外洩，直接關窗，兩台更新後重開。
            stateLock.lock()
            let exposed = activeToken == token && activeCode.map { Self.constantTimeEqual($0.seed, legacyCode.uppercased()) } == true
            stateLock.unlock()
            reject(connection, token: token, reason: "pairing_protocol_outdated", closeWindow: exposed)
            return
        }
        guard request.v == DevicePairingAuth.protocolVersion,
              let nonce = request.nonce, DevicePairingAuth.isValidNonce(nonce), request.mac != nil,
              request.user.map(DevicePairingAuth.isSafeSSHUser) ?? true
        else {
            reject(connection, token: token, reason: "bad_request")
            return
        }

        stateLock.lock()
        guard activeToken == token, let record = activeCode else {
            stateLock.unlock()
            send(PairResponse(ok: false, reason: "pairing_window_closed"), to: connection)
            return
        }
        stateLock.unlock()
        // PBKDF2 在鎖外算（約 0.1 秒），算完再確認配對窗還是同一個。
        guard let key = DevicePairingAuth.key(code: record.seed, nonce: nonce),
              DevicePairingAuth.verify(mac: request.mac, key: key, label: "request", fields: DevicePairingAuth.requestFields(
                  nonce: nonce, publicKey: request.publicKey, name: request.name, user: request.user,
                  deviceID: request.deviceID, clientKeyFingerprint: request.clientKeyFingerprint,
                  hostKeyFingerprint: request.hostKeyFingerprint, fleet: request.fleet))
        else {
            reject(connection, token: token, reason: "pairing_code_mismatch")
            return
        }
        let auth = ReplyAuth(key: key, nonce: nonce)

        stateLock.lock()
        guard activeToken == token, activeCode == record else {
            stateLock.unlock()
            send(PairResponse(ok: false, reason: "pairing_window_closed"), to: connection, auth: auth)
            return
        }
        let fleetRequestPreview = request.fleet.flatMap { Data(base64Encoded: $0) }.flatMap { try? JSONDecoder().decode(DeviceFleetPairRequest.self, from: $0) }
        let previewOnly = fleetRequestPreview?.previewOnly == true
        let local: DeviceIdentity
        let capturedRestoreID = restoringDeviceID
        let capturedOffer = fleetOffer
        do {
            guard let identity = try DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: environment))
            else { throw DeviceIdentityError.identityConflict }
            local = identity
            let previewAllowed = previewOnly && identity.role == .primary
                && capturedOffer?.trust.localID == capturedOffer?.trust.primaryID
                && capturedOffer.map { $0.faction.kind != .owner } == true
            try TatwoDevicePairingCodeEngineV1.validate(seed: record.seed, against: record,
                expectedPrimary: identity.primaryDeviceID ?? identity.deviceID,
                expectedEpoch: UInt64(identity.epoch ?? 0), expectedCreator: capturedOffer?.member.id)
            if !previewAllowed { activeCode = try TatwoDevicePairingCodeEngineV1.consume(
                seed: record.seed,
                record: record,
                expectedPrimary: identity.primaryDeviceID ?? identity.deviceID,
                expectedEpoch: UInt64(identity.epoch ?? 0),
                expectedCreator: fleetOffer?.member.id) }
            if previewOnly && !previewAllowed { throw DeviceFleetError.previewNotAllowed }
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            reject(connection, token: token, reason: DeviceFleetReason.code(error) ?? error.localizedDescription, closeWindow: (error as? DeviceFleetError) == .previewNotAllowed, auth: auth)
            return
        }

        #if DEBUG
        afterConsume?()
        #endif
        do {
            let fleet = DeviceFleetStore(registry: registry, environment: environment)
            try fleet.requireOwner()
            try fleet.requireOwnerMember(local.deviceID)
            if let restoreID = capturedRestoreID {
                guard let roster = try fleet.current()?.roster,
                      let target = roster.devices.first(where: { $0.id == restoreID }),
                      roster.revoked.contains(restoreID), request.deviceID?.lowercased() == restoreID.lowercased(),
                      try DeviceRegistry.fingerprint(publicKey: request.publicKey) == target.clientKeyFingerprint else {
                    throw DeviceFleetError.keyConflict
                }
            }
            var deviceID = try registry.pairingDeviceID(
                publicKey: request.publicKey, requestedID: request.deviceID,
                localDeviceID: local.deviceID)
            if let roster = try fleet.current()?.roster, roster.revoked.contains(deviceID), capturedRestoreID != deviceID {
                // Generic invitations create a fresh identity and default arrows, never revive the old row.
                let fingerprint = try DeviceRegistry.fingerprint(publicKey: request.publicKey)
                let lifecycle = "new-enrollment-" + deviceID + "-" + String(roster.version)
                deviceID = DevicePairingClient.legacyHostID(host: fingerprint, name: lifecycle)
            }
            let previous = registry.list().first { $0.id.lowercased() == deviceID }
            // 加入端自報的客戶端金鑰指紋必須跟它送來的公鑰一致，不一致就不授權、不配對。
            if let declared = request.clientKeyFingerprint {
                guard try DeviceRegistry.fingerprint(publicKey: request.publicKey) == declared else {
                    throw DeviceRegistry.RegistryError.fingerprintConflict
                }
            }
            // 加入端的主機金鑰指紋只在格式正確時收下；收不到就留空，之後往它的隧道照樣擋。
            let peerHostKey = request.hostKeyFingerprint.flatMap { $0.hasPrefix("SHA256:") ? $0 : nil }
            let paired = DeviceFingerprintProvenance(source: "pairing", recordedAt: Date())
            var offer = capturedOffer
            let fleetRequest: DeviceFleetPairRequest?
            if let raw = request.fleet {
                guard let data = Data(base64Encoded: raw),
                      let decoded = try? JSONDecoder().decode(DeviceFleetPairRequest.self, from: data) else {
                    throw DeviceFleetError.malformed
                }
                fleetRequest = decoded
            } else { fleetRequest = nil }
            let enrolled = try fleet.trust() != nil
            if (offer != nil || enrolled), fleetRequest == nil {
                throw DeviceFleetError.consentRequired
            }
            if let offer, offer.faction.kind != .owner {
                guard fleetRequest?.kind == offer.faction.kind, fleetRequest?.consent == true else {
                    throw DeviceFleetError.consentRequired
                }
            }
            let fingerprint = try DeviceRegistry.fingerprint(publicKey: request.publicKey)
            var member: DeviceFleetMember?
            if let currentOffer = offer, let fleetRequest {
                guard fleetRequest.kind == currentOffer.faction.kind,
                      try DeviceRegistry.fingerprint(publicKey: fleetRequest.hostPublicKey) == peerHostKey else {
                    throw DeviceFleetError.keyConflict
                }
                let kind = currentOffer.faction.kind
                let row = DeviceFleetMember(id: deviceID, name: DeviceFleetName.clean(request.name), factionID: currentOffer.faction.id,
                    role: kind == .owner ? .secondary : (kind == .managed ? .managed : .sandbox),
                    clientKeyFingerprint: fingerprint, hostKeyFingerprint: peerHostKey,
                    clientPublicKey: request.publicKey, hostPublicKey: fleetRequest.hostPublicKey,
                    endpoints: [.init(kind: .lan, host: peerHostResolver(connection.endpoint))],
                    user: request.user ?? NSUserName())
                try row.validate()
                if let roster = try fleet.current()?.roster {
                    guard !roster.devices.contains(where: { previous in
                        previous.id == row.id && (previous.role == .sandbox ? .sandbox
                            : roster.factions.first { $0.id == previous.factionID }?.kind) != kind
                    }) else {
                        throw DeviceFleetError.reverseEnrollment
                    }
                    guard !roster.devices.contains(where: { $0.id != row.id && !roster.revoked.contains($0.id) &&
                        ($0.clientKeyFingerprint == row.clientKeyFingerprint || $0.hostKeyFingerprint == row.hostKeyFingerprint)
                    }) else { throw DeviceFleetError.keyConflict }
                }
                member = row

            }
            // Closing or replacing the window is serialized with all persistent side effects.
            stateLock.lock()
            defer { stateLock.unlock() }
            guard activeToken == token, activeCode?.seed == record.seed, record.expiresAt > Date() else {
                throw HostError.windowClosed
            }
            try fleet.pairingTransaction {
                if let member, var currentOffer = offer {
                    if currentOffer.trust.localID == currentOffer.trust.primaryID {
                        let restore = capturedRestoreID == member.id
                        if previewOnly {
                            guard member.role != .secondary || currentOffer.faction.kind != .owner else { throw DeviceFleetError.role }
                            currentOffer.envelope = try fleet.previewAdmission(member, sender: local.deviceID, allowRePair: restore)
                        } else {
                            if let expected = fleetRequest?.previewDigest {
                                let preview = try fleet.previewAdmission(member, sender: local.deviceID, allowRePair: restore)
                                let slice = try JSONDecoder().decode(DeviceFleetPayload.self, from: preview.body).slice!
                                guard try DeviceFleetStore.consentDigest(slice) == expected else { throw DeviceFleetError.staleProposal }
                            } else if currentOffer.faction.kind != .owner {
                                // Protocol callers may explicitly consent; the UI always binds its exact preview.
                                guard fleetRequest?.consent == true else { throw DeviceFleetError.consentRequired }
                            }
                            try fleet.approve([member], sender: local.deviceID, allowRePair: restore)
                            currentOffer.envelope = try fleet.delivery(for: member.id)
                        }
                    } else {
                        // Pending membership has no SSH authority before MAIN signs it.
                        guard !previewOnly else { throw DeviceFleetError.primaryRequired }
                        try fleet.queue(member)
                    }
                    offer = currentOffer
                    #if DEBUG
                    try enrollmentCheck?()
                    #endif
                } else {
                    guard !previewOnly, try fleet.trust() == nil else { throw DeviceFleetError.consentRequired }
                    _ = try registry.authorize(publicKey: request.publicKey, deviceID: deviceID)
                    _ = try registry.add(id: deviceID, name: DeviceFleetName.clean(request.name),
                        host: peerHostResolver(connection.endpoint), user: request.user ?? NSUserName(),
                        sshPort: 22, publicKeyFingerprint: fingerprint, workdirMap: previous?.workdirMap ?? [:],
                        hostKeyFingerprint: peerHostKey, clientKeyFingerprint: fingerprint,
                        hostKeyFingerprintSource: peerHostKey.map { _ in paired }, clientKeyFingerprintSource: paired)
                }
                guard record.expiresAt > Date() else { throw TatwoDevicePairingErrorV1.codeExpired }
            }
            let response = PairResponse(
                ok: true,
                deviceID: deviceID,
                hostName: offer?.faction.kind != nil && offer?.faction.kind != .owner
                    ? offer?.faction.managerDisplayName : Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                hostUser: offer?.faction.kind != nil && offer?.faction.kind != .owner ? "manager" : NSUserName(),
                hostDeviceID: local.deviceID,
                hostKeyFingerprint: DeviceRegistry.localHostKeyFingerprint(environment: environment),
                clientKeyFingerprint: DeviceRegistry.localClientKeyFingerprint(environment: environment),
                fleet: try offer.map { try JSONEncoder().encode($0).base64EncodedString() }, previewOnly: previewOnly)
            send(response, to: connection, auth: auth) { [weak self] in
                if !previewOnly { self?.finishCurrentWindow(token: token) }
            }
        } catch {
            send(PairResponse(ok: false, reason: DeviceFleetReason.code(error) ?? error.localizedDescription), to: connection, auth: auth) { [weak self] in
                self?.finishCurrentWindow(token: token)
            }
        }
    }

    private func reject(
        _ connection: NWConnection, token: UUID, reason: String,
        closeWindow: Bool = false, auth: ReplyAuth? = nil
    ) {
        stateLock.lock()
        guard activeToken == token else {
            stateLock.unlock()
            send(PairResponse(ok: false, reason: "pairing_window_closed"), to: connection, auth: auth)
            return
        }
        failedAttempts += 1
        let shouldClose = closeWindow || failedAttempts >= 5
        stateLock.unlock()
        send(PairResponse(ok: false, reason: reason), to: connection, auth: auth) { [weak self] in
            if shouldClose { self?.finishCurrentWindow(token: token) }
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func send(
        _ response: PairResponse, to connection: NWConnection, auth: ReplyAuth? = nil,
        completion: (() -> Void)? = nil
    ) {
        var response = response
        // Refusals contain only the protocol reason, never any member fields.
        if !response.ok { response = PairResponse(ok: false, reason: response.reason) }
        if let auth {
            response.mac = DevicePairingAuth.mac(key: auth.key, label: "response", fields: DevicePairingAuth.responseFields(
                nonce: auth.nonce, ok: response.ok, deviceID: response.deviceID, hostName: response.hostName,
                hostUser: response.hostUser, hostDeviceID: response.hostDeviceID,
                hostKeyFingerprint: response.hostKeyFingerprint,
                clientKeyFingerprint: response.clientKeyFingerprint, reason: response.reason, fleet: response.fleet, previewOnly: response.previewOnly))
        }
        guard var data = try? JSONEncoder().encode(response) else {
            connection.cancel()
            completion?()
            return
        }
        if let auth, response.ok {
            guard let sealed = try? DevicePairingAuth.sealResponse(data, key: auth.key) else { connection.cancel(); completion?(); return }
            data = sealed
        }
        #if DEBUG
        if let auth { captureWire?(data, auth.key) }
        #endif
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    private func finishCurrentWindow(token: UUID) {
        stateLock.lock()
        let current = activeToken == token ? listener : nil
        stateLock.unlock()
        guard let current else { return }
        finishWindow(listener: current, token: token)
    }

    private func finishWindow(listener target: NWListener, token: UUID) {
        let didClear = clearIfMatching(listener: target, token: token, notify: true)
        if didClear { target.cancel() }
    }

    @discardableResult
    private func clearIfMatching(listener target: NWListener, token: UUID, notify: Bool) -> Bool {
        stateLock.lock()
        guard listener === target, activeToken == token else {
            stateLock.unlock()
            return false
        }
        listener = nil
        activeCode = nil
        activeToken = nil
        failedAttempts = 0
        fleetOffer = nil
        port = nil
        let callback = notify ? onClose : nil
        stateLock.unlock()
        callback?()
        return true
    }

    private static func remoteHost(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return String(describing: endpoint) }
        return String(describing: host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func bindAddress(environment: [String: String]) -> String? {
        if let override = environment["TATWO2_PAIRING_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return "127.0.0.1" }
        defer { freeifaddrs(interfaces) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            defer { current = pointer.pointee.ifa_next }
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (pointer.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  (pointer.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let value = String(cString: host)
            if value.hasPrefix("10.") || value.hasPrefix(["192", "168", ""].joined(separator: ".")) || Self.isPrivate172(value) {
                return value
            }
        }
        return "127.0.0.1"
    }

    private static func isPrivate172(_ address: String) -> Bool {
        let fields = address.split(separator: ".")
        guard fields.count == 4, fields[0] == "172", let second = Int(fields[1]) else { return false }
        return (16...31).contains(second)
    }
}
