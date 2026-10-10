#if DEBUG
import Darwin
import Foundation

/// 假設備用真實 SSH 簽章、真實 NW 配對與正式同步狀態機；SSH daemon 由測試 transport 取代。
enum DeviceFleetAcceptance {
    final class Network {
        var endpoints: [String: DeviceDispatch] = [:]
        var offline = Set<String>()
        var bridgeRequests = false
        var calls: [(String, String)] = []
        var revocationPackets: [[String: Any]] = []
        func call(_ peer: DeviceRecord, _ method: String, _ proof: [String: Any]) throws -> [String: Any] {
            guard !offline.contains(peer.id), let target = endpoints[peer.id] else {
                throw DeviceDispatch.Failure(reason: "fixture_offline")
            }
            calls.append((peer.id, method))
            if proof["revocation"] != nil { revocationPackets.append(proof) }
            if bridgeRequests {
                let response = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: target, method: method, params: proof)
                guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] else {
                    throw DeviceDispatch.Failure(reason: "fixture_bridge_rejected")
                }
                return result
            }
            let (sender, payload) = try target.authenticate(method: method, proof: proof)
            switch method {
            case "dispatch_fetch":
                if payload["identityOnly"] as? Bool == true { return try DeviceDispatch.object(target.localFleetPresence()) }
                return try DeviceDispatch.object(target.offer(to: sender))
            case "dispatch_ack":
                try target.recordACK(DeviceDispatch.decode(DeviceDispatch.Receipt.self, payload), sender: sender)
                return ["recorded": true]
            default: throw DeviceDispatch.Failure(reason: "unexpected_fixture_method")
            }
        }
    }
    struct Fake {
        var id: String
        var env: [String: String]
        var registry: DeviceRegistry
        var dispatch: DeviceDispatch
        var fleet: DeviceFleetStore { DeviceFleetStore(registry: registry, environment: env) }
        var host: String { env["TATWO2_PAIRING_HOST"]! }
        var clientKey: String { get throws { try String(contentsOfFile: env["TATWO2_SSH_KEY_PATH"]! + ".pub", encoding: .utf8) } }
        var hostKey: String { get throws { try String(contentsOfFile: env["TATWO2_SSH_HOST_KEY_PUB"]!, encoding: .utf8) } }
    }
    static func isolatedRoot() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let root = env["TATWO2_W187_TEST_ROOT"] { return URL(fileURLWithPath: root) }
        guard let live = env["TATWO2_LIVE_ROOT"] else { throw DeviceFleetError.malformed }
        let root = URL(fileURLWithPath: live).appendingPathComponent("w187-isolated-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("synthetic only\n".utf8).write(to: root.appendingPathComponent("owned-fixture"))
        return root
    }
    static func run(root: URL) throws {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default
        guard let live = env["TATWO2_LIVE_ROOT"],
              fm.fileExists(atPath: root.appendingPathComponent("owned-fixture").path) else { throw DeviceFleetError.malformed }
        let r = DeviceIdentityStore.canonical(root).path
        let l = DeviceIdentityStore.canonical(URL(fileURLWithPath: live)).path
        guard l.hasPrefix(r + "/") || r.hasPrefix(l + "/w187-isolated-") else { throw DeviceFleetError.malformed }
        if env["TATWO2_W187_GRAPH"] == "1" {
            try DeviceFleetGraphAcceptance.run(root: root)
            return
        }
        DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false })
        defer { DeviceFleetRevocation.testHooks = nil }
        if env["TATWO2_W187_TRANSFER"] == "1" {
            if env["TATWO2_W187_R13_TRANSFER"] == "ui" {
                DispatchQueue.global().async {
                    do { try DeviceFleetTransferAcceptance.run(root: root); exit(0) }
                    catch { print("W187R13 FAIL \(error)"); exit(1) }
                }
                RunLoop.main.run()
            }
            try DeviceFleetTransferAcceptance.run(root: root); return
        }
        var checks = 0
        func check(_ label: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw NSError(domain: "W187FLEET_FAIL_" + label, code: 1) }
            checks += 1; print("W187FLEET PASS \(label)")
        }
        func rejects(_ label: String, expected: DeviceFleetError? = nil, _ action: () throws -> Void) throws {
            do { try action() } catch {
                if let expected, (error as? DeviceFleetError) != expected { throw error }
                checks += 1; print("W187FLEET PASS \(label)"); return
            }
            throw NSError(domain: "W187FLEET_UNEXPECTED_ACCEPT_" + label, code: 1)
        }
        let network = Network()
        func make(_ index: Int, primary: Bool = false) throws -> Fake {
            let base = root.appendingPathComponent("device-\(index)")
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            let id = String(format: "%08x-1111-4111-8111-111111111111", index + 1)
            let entry = TatwoEntry(environment: ["TATWO_OS_ROOT": base.appendingPathComponent("entry").path], preference: nil)
            try fm.createDirectory(at: entry.root, withIntermediateDirectories: true)
            try Data("synthetic constitution\n".utf8).write(to: entry.constitution)
            try Data("synthetic skills\n".utf8).write(to: entry.skillet)
            try DeviceIdentity(deviceID: id, name: "fixture \(index)", hardwareModel: "fixture",
                               role: primary ? .primary : .secondary, epoch: primary ? 1 : nil,
                               primaryDeviceID: primary ? id : nil, updatedAt: Date()).encoded().write(to: entry.deviceJSON)
            let key = base.appendingPathComponent("client-key").path, hostKey = base.appendingPathComponent("host-key").path
            for path in [key, hostKey] {
                guard try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", path]).0 == 0 else {
                    throw DeviceFleetError.missingKey
                }
            }
            let env = ["TATWO_OS_ROOT": entry.root.path, "TATWO2_LIVE_ROOT": base.appendingPathComponent("live").path,
                       "TATWO2_AUTHORIZED_KEYS": base.appendingPathComponent("authorized_keys").path,
                       "TATWO2_SSH_KNOWN_HOSTS": base.appendingPathComponent("known_hosts").path,
                       "TATWO2_SSH_KEY_PATH": key, "TATWO2_SSH_HOST_KEY_PUB": hostKey + ".pub",
                       "TATWO2_PAIRING_HOST": "192.0.2.\(index + 11)"]
            let registry = DeviceRegistry(environment: env)
            let dispatch = DeviceDispatch(entry: entry, registry: registry, environment: env, retireBackup: { _ in },
                                          rpc: { try network.call($0, $1, $2) })
            network.endpoints[id] = dispatch
            return Fake(id: id, env: env, registry: registry, dispatch: dispatch)
        }
        func pair(_ host: Fake, _ client: Fake, kind: DeviceFactionKind = .owner, faction: String? = nil,
                  consent: Bool = false, enrollmentFault: Bool = false, name: String? = nil, restoring: Bool = false) throws {
            var loopback = host.env; loopback["TATWO2_PAIRING_HOST"] = "127.0.0.1"
            let server = DevicePairingHost(registry: host.registry, environment: loopback,
                                           peerHostResolver: { _ in client.host })
            if enrollmentFault { server.enrollmentCheck = { throw DeviceFleetError.role } }
            defer { server.cancelPairingWindow() }
            let window = try server.startPairingWindow(kind: kind, factionID: faction, restoringDeviceID: restoring ? client.id : nil)
            let hostKey = try host.hostKey
            let joiner = DevicePairingClient(registry: client.registry, environment: client.env,
                sshVerifier: { _, _, _ in true }, hostKeyResolver: { _ in hostKey }, peerEndpoints: { _, row in row.endpoints })
            _ = try joiner.pair(host: "127.0.0.1", port: Int(window.listenAddress.split(separator: ":").last!)!,
                               code: window.code, name: name ?? "fixture \(Int(client.host.split(separator: ".").last!)! - 11)",
                               kind: kind, consentToManagement: consent)
            if kind != .owner, consent, let slice = try client.fleet.pendingConsent() {
                try check("initial-managed-controls-closed-before-local-review", try client.fleet.effectiveControllers(slice.controllers).isEmpty)
                try client.fleet.approveConsent(revision: slice.revision, controllers: slice.controllers)
            }
        }
        func authorized(_ device: Fake, _ key: String) throws -> Bool {
            let fingerprint = try DeviceRegistry.fingerprint(publicKey: key)
            let text = (try? String(contentsOf: device.registry.authorizedKeysURL, encoding: .utf8)) ?? ""
            return text.split(whereSeparator: \.isNewline).contains { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard let index = fields.firstIndex(of: "ssh-ed25519"), index + 1 < fields.count else { return false }
                return (try? DeviceRegistry.fingerprint(publicKey: "\(fields[index]) \(fields[index + 1])")) == fingerprint
            }
        }
        if env["TATWO2_SELFTEST"] == "w232" { try W232FleetAcceptance.run(make: { try make($0, primary: $1) }); return }
        if let scenario = env["TATWO2_W221C"] {
            try W221cAcceptance.run(scenario: scenario, make: { try make($0, primary: $1) },
                pair: { try pair($0, $1) })
            return
        }
        if let scenario = env["TATWO2_W187_R8"] {
            DispatchQueue.global().async {
                do {
                    try DeviceFleetEighthRoundAcceptance.run(scenario: scenario, make: { try make($0, primary: $1) },
                        pair: { try pair($0, $1, kind: $2, faction: $3, consent: $4) })
                    exit(0)
                } catch { print("W187R8 FAIL \(error)"); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        if let scenario = env["TATWO2_W187_R7"] {
            try SelfTest.offMain {
                try DeviceFleetSeventhRoundAcceptance.run(scenario: scenario, make: { try make($0, primary: $1) },
                    pair: { try pair($0, $1, kind: $2, faction: $3, consent: $4) })
            }
            return
        }
        if let scenario = env["TATWO2_W187_R6"] {
            try SelfTest.offMain {
                try DeviceFleetSixthRoundAcceptance.run(scenario: scenario, make: { try make($0, primary: $1) },
                    pair: { try pair($0, $1, kind: $2, faction: $3, consent: $4) })
            }
            return
        }
        if let scenario = env["TATWO2_W187_R5"] {
            try SelfTest.offMain {
                try DeviceFleetFifthRoundAcceptance.run(scenario: scenario, make: { try make($0, primary: $1) },
                    pair: { try pair($0, $1, kind: $2, faction: $3, consent: $4) })
            }
            return
        }
        if let scenario = env["TATWO2_W187_R4"] {
            try SelfTest.offMain {
                try DeviceFleetFourthRoundAcceptance.run(scenario: scenario, make: { try make($0, primary: $1) },
                    pair: { try pair($0, $1, kind: $2, faction: $3, consent: $4) })
            }
            return
        }
        if let scenario = env["TATWO2_W187_R3"] {
            if ["gate", "narrow"].contains(scenario) { network.bridgeRequests = true }
            try DeviceFleetThirdRoundAcceptance.run(scenario: scenario, make: { try make($0, primary: $1) },
                pair: { try pair($0, $1, kind: $2, faction: $3, consent: $4) })
            return
        }
        if env["TATWO2_W187_R2"] == "1" {
            try DeviceFleetRoundTwoAcceptance.run(make: { try make($0, primary: $1) },
                pair: { try pair($0, $1, kind: $2, faction: $3, consent: $4, restoring: $5) })
            return
        }
        let a = try make(0, primary: true), b = try make(1), c = try make(2), m = try make(3), s = try make(4)
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b)
        try check("two-device-once-bidirectional-keys", authorized(a, b.clientKey) && authorized(b, a.clientKey))
        try check("two-device-both-host-pins", a.registry.fleetHostPublicKey(fingerprint: DeviceRegistry.fingerprint(publicKey: b.hostKey)) != nil
                    && b.registry.fleetHostPublicKey(fingerprint: DeviceRegistry.fingerprint(publicKey: a.hostKey)) != nil)
        let beforeC = try a.fleet.current()!.roster!.version
        network.offline.insert(a.id)
        try rejects("secondary-general-invitation-refused", expected: .primaryRequired) { try pair(b, c) }
        // A pre-upgrade secondary pending row never had admission authority.
        let legacyPending = try c.fleet.localMember(faction: a.fleet.current()!.roster!.factions.first { $0.kind == .owner }!, host: c.host)
        try b.fleet.queue(legacyPending)
        try check("offline-only-paired-devices", !authorized(b, c.clientKey) && !authorized(c, b.clientKey)
                  && !authorized(a, c.clientKey) && !authorized(c, a.clientKey))
        try check("offline-pending-primary", b.fleet.statusText == "待主設備簽名單")
        b.dispatch.synchronize()
        try check("secondary-historical-pending-retired-without-admission", b.fleet.pending().isEmpty)
        network.offline.remove(a.id)
        b.dispatch.synchronize(); b.dispatch.synchronize()
        try check("online-roster-channel-never-auto-admits-pending", !authorized(a, c.clientKey))
        try pair(a, c) // Admission must be a new pairing at the local primary.
        b.dispatch.synchronize(); c.dispatch.synchronize()
        try check("third-member-version-increases", a.fleet.current()!.roster!.version > beforeC)
        for (left, right) in [(a,b),(a,c),(b,a),(b,c),(c,a),(c,b)] {
            try check("three-device-key-\(left.id.prefix(8))-\(right.id.prefix(8))", authorized(left, right.clientKey))
        }
        try check("online-pending-drained", b.fleet.pending().isEmpty)
        let staff = DeviceFaction(id: "staff", name: "職員", kind: .managed, managerDisplayName: "測試公司")
        try a.fleet.setFaction(staff)
        try rejects("management-requires-local-consent", expected: .consentRequired) { try pair(a, m, kind: .managed, faction: "staff") }
        try pair(a, m, kind: .managed, faction: "staff", consent: true)
        let sandbox = DeviceFaction(id: "sandbox", name: "沙盒", kind: .sandbox, managerDisplayName: "測試公司")
        try a.fleet.setFaction(sandbox)
        try pair(a, s, kind: .sandbox, faction: "sandbox", consent: true)
        a.dispatch.synchronize()
        b.dispatch.synchronize(); c.dispatch.synchronize()
        for owner in [a,b,c] {
            try check("managed-has-owner-key-\(owner.id.prefix(8))", authorized(m, owner.clientKey))
            try check("managed-key-not-in-owner-\(owner.id.prefix(8))", !authorized(owner, m.clientKey))
            try check("sandbox-key-not-in-owner-\(owner.id.prefix(8))", !authorized(owner, s.clientKey))
            try check("owner-has-managed-host-pin-\(owner.id.prefix(8))",
                      owner.registry.fleetHostPublicKey(fingerprint: DeviceRegistry.fingerprint(publicKey: m.hostKey)) != nil)
        }
        let hidden = try m.fleet.current()!.slice!
        try check("managed-bridge-projection-has-no-return-route", !m.registry.list().isEmpty
                  && m.registry.list().allSatisfy { $0.host.isEmpty && $0.endpoints.isEmpty
                      && $0.role == nil && $0.pinnedHostKeyFingerprint == nil
                      && $0.name == "測試公司" })
        try check("managed-filter-only-own-faction", hidden.devices.allSatisfy { $0.factionID == "staff" }
                  && hidden.primary == nil && hidden.faction.managerDisplayName == "測試公司")
        let hiddenJSON = String(decoding: try m.fleet.envelope()!.body, as: UTF8.self)
        try check("managed-filter-no-primary-metadata", !hiddenJSON.contains("fixture 0") && !hiddenJSON.contains(a.host)
                  && !hiddenJSON.contains("\"primaryID\"") && !hiddenJSON.contains("\"version\"") && !hiddenJSON.contains(a.id))
        var visible = staff; visible.showPrimaryToMembers = true
        try a.fleet.setFaction(visible); a.dispatch.synchronize()
        try check("managed-primary-only-with-opt-in", m.fleet.current()!.slice!.primary?.name == a.fleet.current()!.roster!.devices.first { $0.id == a.id }!.name)
        try a.fleet.setFaction(staff); a.dispatch.synchronize()
        try rejects("managed-transfer-refused", expected: .managedLocked) { try m.dispatch.beginTransfer(to: a.id, signingName: "") }
        try rejects("sandbox-transfer-refused", expected: .managedLocked) { try s.dispatch.beginTransfer(to: a.id, signingName: "") }
        try rejects("managed-cannot-mint-code", expected: .managedLocked) { _ = try DevicePairingHost(registry: m.registry, environment: m.env).startPairingWindow() }
        try rejects("managed-cannot-join-code", expected: .managedLocked) {
            _ = try DevicePairingClient(registry: m.registry, environment: m.env).pair(host: a.host, port: 18800, code: "ABC123", name: "fixture")
        }
        try rejects("managed-cannot-edit-roster", expected: .managedLocked) { try m.fleet.setFaction(staff) }
        try rejects("owner-cannot-join-managed-host-key", expected: .reverseEnrollment) {
            try a.fleet.checkJoining(hostFingerprint: DeviceRegistry.fingerprint(publicKey: m.hostKey), offer: nil)
        }
        try rejects("sandbox-cannot-reverse-enroll", expected: .reverseEnrollment) {
            try a.fleet.checkJoining(hostFingerprint: DeviceRegistry.fingerprint(publicKey: s.hostKey), offer: nil)
        }
        b.dispatch.synchronize(); c.dispatch.synchronize()
        let n = try make(9)
        try rejects("secondary-managed-invitation-requires-local-primary", expected: .primaryRequired) {
            try pair(b, n, kind: .managed, faction: "staff", consent: true)
        }
        b.dispatch.synchronize(); b.dispatch.synchronize()
        try check("secondary-managed-proposal-never-auto-admitted", !authorized(n, a.clientKey))
        try pair(a, n, kind: .managed, faction: "staff", consent: true)
        b.dispatch.synchronize()
        if let slice = try n.fleet.pendingConsent() {
            try check("secondary-managed-join-awaits-local-review", try n.fleet.effectiveControllers(slice.controllers).isEmpty)
            try n.fleet.approveConsent(revision: slice.revision, controllers: slice.controllers)
        }
        try check("managed-joins-secondary-full-owner-grants", authorized(n, a.clientKey)
                  && authorized(n, b.clientKey) && authorized(n, c.clientKey))
        // Fifth ruling: neither SUB primary nor colleague may control another staff device.
        try check("sub-peers-neither-direction", !authorized(m, n.clientKey) && !authorized(n, m.clientKey))
        a.dispatch.synchronize(); b.dispatch.synchronize(); c.dispatch.synchronize()
        let old = try a.fleet.envelope()!
        var forgedRoster = try a.fleet.current()!.roster!
        forgedRoster.version += 1
        forgedRoster.primaryID = m.id
        for index in forgedRoster.devices.indices {
            if forgedRoster.devices[index].id == m.id {
                forgedRoster.devices[index].factionID = "owner"; forgedRoster.devices[index].role = .primary
            } else if forgedRoster.devices[index].id == a.id {
                forgedRoster.devices[index].role = .secondary
            }
        }
        // Preserve the old self-signed attack with a structurally valid v2 graph.
        for index in forgedRoster.groups.indices {
            if forgedRoster.groups[index].type == .main { forgedRoster.groups[index].primaryDeviceID = m.id }
            else if forgedRoster.groups[index].id == "staff" { forgedRoster.groups[index].primaryDeviceID = n.id }
        }
        for index in forgedRoster.devices.indices where forgedRoster.devices[index].id == n.id {
            forgedRoster.devices[index].role = .primary
        }
        forgedRoster.edges = DeviceFleetRoster.defaults(groups: forgedRoster.groups, devices: forgedRoster.devices)
        let forged = try DeviceFleetEnvelope.issue(.init(roster: forgedRoster), environment: m.env)
        try rejects("managed-self-signed-roster-refused", expected: .signer) { try a.fleet.accept(forged) }
        let x = try make(5, primary: true)
        try x.fleet.bootstrapPrimary(host: x.host)
        let xOffer = try x.fleet.makeOffer(kind: .owner, factionID: nil, host: x.host)!
        var deceptiveOffer = xOffer
        deceptiveOffer.trust.primaryID = a.id
        deceptiveOffer.trust.pinnedPrimaryKey = try DeviceRegistry.fingerprint(publicKey: a.clientKey)
        deceptiveOffer.envelope = forged
        try rejects("invalid-pair-proof-before-authorization", expected: .signer) {
            try a.fleet.completePair(peer: xOffer.member, offer: deceptiveOffer, consent: false)
        }
        try check("invalid-pair-leaves-no-authorization", !authorized(a, x.clientKey))
        var changedPin = deceptiveOffer
        changedPin.trust.pinnedPrimaryKey = try DeviceRegistry.fingerprint(publicKey: m.clientKey)
        try rejects("pairing-cannot-substitute-primary-pin", expected: .signer) {
            try a.fleet.checkJoining(hostFingerprint: DeviceRegistry.fingerprint(publicKey: x.hostKey), offer: changedPin)
        }
        try rejects("owner-in-other-fleet-refused", expected: .foreignFleet) {
            try a.fleet.checkJoining(hostFingerprint: DeviceRegistry.fingerprint(publicKey: x.hostKey), offer: xOffer)
        }
        try rejects("old-roster-replay-refused", expected: .replay) { try b.fleet.accept(old) }
        try rejects("restart-keeps-replay-highwater", expected: .replay) {
            try DeviceFleetStore(registry: b.registry, environment: b.env).accept(old)
        }
        var wrongEpoch = try a.fleet.current()!.roster!; wrongEpoch.epoch += 1; wrongEpoch.version += 1
        let wrong = try DeviceFleetEnvelope.issue(.init(roster: wrongEpoch), environment: a.env)
        try rejects("wrong-epoch-refused", expected: .epoch) { try b.fleet.accept(wrong) }
        var badSignature = old; badSignature.body.append(0)
        try rejects("bad-signature-refused", expected: .signature) { try c.fleet.accept(badSignature) }
        try rejects("owner-fleet-downgrade-refused", expected: .foreignFleet) {
            try a.fleet.checkJoining(hostFingerprint: DeviceRegistry.fingerprint(publicKey: x.hostKey), offer: nil)
        }
        try rejects("owner-transfer-requires-confirmation", expected: .confirmationRequired) {
            try b.fleet.checkTransfer(from: a.id, to: b.id, confirmation: "fixture-confirmation")
        }
        try b.fleet.confirmTransfer("fixture-confirmation")
        try b.fleet.checkTransfer(from: a.id, to: b.id, confirmation: "fixture-confirmation")
        try check("owner-transfer-explicitly-confirmed", true)
        try rejects("fleet-transfer-stops-before-partial-epoch", expected: .confirmationRequired) {
            try PrimaryTransfer.begin(a.dispatch, to: b.id, signingName: "")
        }
        try check("blocked-transfer-keeps-authority", a.dispatch.identity().epoch == 1
                  && a.dispatch.identity().primaryDeviceID == a.id
                  && a.dispatch.identity().transfer == nil)
        let transfer = PrimaryTransferState.Record(from: a.id, to: b.id, oldEpoch: 1, epoch: 2,
            participants: [a.id, b.id, c.id], previousTransferID: nil,
            sourceDeviceID: a.id, sourceRoot: a.dispatch.entry.root.path, hashes: [:],
            sourcePages: nil, signingName: "")
        try rejects("fleet-resumed-transfer-cannot-commit-epoch", expected: .transferNotReady) {
            try PrimaryTransfer.save(transfer, dispatch: b.dispatch, commit: true)
        }
        try check("blocked-resume-keeps-secondary-authority", b.dispatch.identity().epoch == 1
                  && b.dispatch.identity().primaryDeviceID == a.id
                  && b.dispatch.identity().transfer == nil)
        try rejects("owner-transfer-needs-primary-signature", expected: .signature) {
            try b.fleet.requireTransferSignature(transfer, proof: nil)
        }
        let managedTransferProof = try DeviceFleetTransferProof.issue(transfer, environment: m.env)
        try rejects("managed-cannot-sign-owner-transfer", expected: .signature) {
            try b.fleet.requireTransferSignature(transfer, proof: managedTransferProof)
        }
        let primaryTransferProof = try DeviceFleetTransferProof.issue(transfer, environment: a.env)
        try b.fleet.requireTransferSignature(transfer, proof: primaryTransferProof)
        try check("owner-transfer-primary-signature-verified", true)
        try check("ssh-managed-key-refused", !OSSocketCaller.sshFingerprintAllowed(DeviceRegistry.fingerprint(publicKey: m.clientKey), registry: a.registry))
        try check("ssh-sandbox-key-refused", !OSSocketCaller.sshFingerprintAllowed(DeviceRegistry.fingerprint(publicKey: s.clientKey), registry: a.registry))
        try check("ssh-owner-key-allowed", OSSocketCaller.sshFingerprintAllowed(DeviceRegistry.fingerprint(publicKey: c.clientKey), registry: a.registry))
        let callsBefore = network.calls.count
        m.dispatch.synchronize(); s.dispatch.synchronize()
        try check("managed-never-connects-back", network.calls.count == callsBefore)
        try m.fleet.requestLeave(); a.dispatch.synchronize()
        try check("leave-request-owner-polled", a.fleet.leaveRequests().contains(m.id))
        let fresh = try make(10)
        try DeviceFleetSecurityAcceptance.run(host: a, client: fresh, managed: m)
        // 本測試登記的真實關閉 callback；既有 UI 持續連線還須 W187b 接此介面。
        final class Closed: @unchecked Sendable { var value = false }
        let closed = Closed()
        DeviceFleetConnections.register(b.id) { closed.value = true }
        let oldKnown = (try? Data(contentsOf: c.registry.knownHostsURL)) ?? Data()
        // Conflict belongs to an unrelated member; it must not freeze revocation.
        let conflict = "\(m.host) \(try DeviceFleetPublicKey.withoutComment(s.hostKey)) conflict-fixture\n"
        let pins = try Data(contentsOf: c.registry.fleetKnownHostsURL)
        try DeviceDispatchSafeFile.write(pins + Data(conflict.utf8), url: c.registry.fleetKnownHostsURL)
        let revocationStore = a.fleet
        let revocation = try revocationStore.propose([.revoke(id: b.id)], actor: a.id)
        _ = try revocationStore.confirm(revocation.id, userConfirmed: true)
        a.dispatch.pushFleetNow()
        try check("ROSTER-02-immediate-push-no-poll", !authorized(c, b.clientKey) && !authorized(m, b.clientKey) && !authorized(s, b.clientKey))
        try check("REG-05-conflict-does-not-block-revocation", c.fleet.read().pinConflicts?.contains(m.id) == true && !authorized(c, b.clientKey))
        try check("REG-05-user-known-hosts-untouched", ((try? Data(contentsOf: c.registry.knownHostsURL)) ?? Data()) == oldKnown)
        let notice = try a.fleet.delivery(for: b.id)!
        let body = try JSONDecoder().decode(DeviceFleetPayload.self, from: notice.body)
        try check("ROSTER-09-notice-has-no-other-members", body.roster == nil && body.slice == nil && body.revocationNotice?.targetID == b.id && notice.publicKey.isEmpty)
        for secret in [a.id, c.id, m.id, s.id, try a.clientKey, try c.clientKey, a.host, c.host, m.host, s.host] {
            try check("TR-06-notice-excludes-peer-data", !String(decoding: notice.body, as: UTF8.self).contains(secret))
        }
        try check("TR-06-successful-notification-is-one-shot", !a.fleet.claimRevocationDelivery(b.id))
        let retries = "fixture-bounded-retry", firstAttempt = Date()
        try check("TR-06-first-revocation-attempt", a.fleet.claimRevocationDelivery(retries, now: firstAttempt))
        try check("TR-06-immediate-retry-backs-off", !a.fleet.claimRevocationDelivery(retries, now: firstAttempt))
        try check("TR-06-retry-survives-original-minute", a.fleet.claimRevocationDelivery(retries, now: firstAttempt.addingTimeInterval(61)))
        try check("TR-06-repeated-retry-does-not-storm", !a.fleet.claimRevocationDelivery(retries, now: firstAttempt.addingTimeInterval(61)))
        try check("TR-06-time-budget-started", a.fleet.claimRevocationDelivery("fixture-time-budget", now: firstAttempt))
        try check("TR-06-absent-peer-remains-retryable", a.fleet.claimRevocationDelivery("fixture-time-budget", now: firstAttempt.addingTimeInterval(3600)))
        try check("TR-06-wire-notice-has-no-RPC-member-metadata", !network.revocationPackets.isEmpty && network.revocationPackets.allSatisfy { Set($0.keys) == ["revocation"] })
        for fake in [a,c,m,s] {
            let current = try fake.fleet.envelope()!
            let keyText = (try? Data(contentsOf: fake.registry.authorizedKeysURL)) ?? Data()
            try DeviceDispatchSafeFile.write(keyText + Data((try DeviceFleetPublicKey.withoutComment(b.clientKey) + " tatwo2-device:resurrection-fixture\n").utf8), url: fake.registry.authorizedKeysURL)
            try fake.fleet.synchronizeEnvelope(current)
            try check("ROSTER-02-same-version-never-resurrects", !authorized(fake, b.clientKey))
            let restarted = DeviceFleetStore(registry: fake.registry, environment: fake.env)
            try restarted.reconcile(restarted.current()!)
            try check("ROSTER-10-restart-reconcile-keeps-tombstone", !authorized(fake, b.clientKey))
        }
        a.dispatch.synchronize(); c.dispatch.synchronize()
        try check("revoke-B-removes-A-and-C-keys", !authorized(a, b.clientKey) && !authorized(c, b.clientKey))
        try check("revoke-B-closes-registered-link", closed.value)
        try check("revoke-B-removes-host-pin", a.registry.fleetHostPublicKey(fingerprint: DeviceRegistry.fingerprint(publicKey: b.hostKey)) == nil
                  && c.registry.fleetHostPublicKey(fingerprint: DeviceRegistry.fingerprint(publicKey: b.hostKey)) == nil)
        try check("revoked-owner-cleans-own-authorizations", !authorized(b, a.clientKey) && !authorized(b, c.clientKey))
        try b.fleet.checkJoining(hostFingerprint: DeviceRegistry.fingerprint(publicKey: x.hostKey), offer: xOffer)
        try check("revoked-owner-may-leave-for-another-fleet", true)
        try a.fleet.revoke(m.id)
        network.offline.insert(m.id); a.dispatch.synchronize()
        try check("offline-managed-revocation-pending", a.fleet.pendingManagedRemoval().contains(m.id) && authorized(m, a.clientKey))
        network.offline.remove(m.id); a.dispatch.fixtureRecoveryNow = Date().addingTimeInterval(601); a.dispatch.synchronize()
        try check("revoke-M-clears-owner-keys", !authorized(m, a.clientKey) && !authorized(m, c.clientKey))
        try check("revoke-M-ack-clears-pending", !a.fleet.pendingManagedRemoval().contains(m.id))
        try rejects("ROSTER-02-repair-cannot-promote-revoked-managed-to-MAIN", expected: .managedLocked) {
            _ = try DevicePairingClient(registry: m.registry, environment: m.env).pair(host: a.host, port: 18800,
                code: "ABC123", name: "fixture", kind: .owner)
        }
        do {
            try pair(a, b, enrollmentFault: true, restoring: true)
            throw DeviceFleetError.malformed
        } catch DevicePairingClient.ClientError.pairingRejected { }
        try check("PAIR-06-repair-failure-restores-connection-tombstone",
                  DeviceFleetConnections.isRevoked(b.id, scope: a.registry.root.path)
                    && !authorized(a, b.clientKey) && a.fleet.current()!.roster!.revoked.contains(b.id))
        try pair(a, b, restoring: true)
        a.dispatch.pushFleetNow()
        try check("ROSTER-02-only-fresh-pair-restores-original-owner-identity", authorized(a, b.clientKey)
                  && authorized(b, a.clientKey) && authorized(c, b.clientKey) && authorized(s, b.clientKey))
        let repairedPayload = try a.fleet.current()!
        try a.fleet.revoke(b.id)
        try rejects("ROSTER-02-old-repair-reconcile-refused", expected: .replay) { try a.fleet.reconcile(repairedPayload) }
        try check("ROSTER-02-old-repair-proof-cannot-undo-new-revocation", !authorized(a, b.clientKey))
        try pair(a, b, restoring: true)
        try pair(a, m, kind: .managed, faction: "staff", consent: true, restoring: true)
        a.dispatch.pushFleetNow()
        try check("ROSTER-02-only-fresh-pair-restores-original-managed-identity", authorized(m, a.clientKey)
                  && authorized(m, b.clientKey) && !authorized(a, m.clientKey))
        // 從實際旧紀錄形狀遷移：正本有客戶端 pin，加入端只有主機 pin。
        let mini = try make(6, primary: true), book = try make(7)
        let key = try book.clientKey, miniHost = try mini.hostKey
        var bookIdentity = try book.dispatch.identityForFleetFixture()
        bookIdentity.epoch = 1; bookIdentity.primaryDeviceID = mini.id
        try DeviceIdentityStore.forLocalDevice(entry: book.dispatch.entry).write(bookIdentity)
        _ = try mini.registry.authorize(publicKey: key, deviceID: book.id)
        _ = try mini.registry.add(id: book.id, name: "fixture 7", host: book.host, user: NSUserName(),
                                  publicKeyFingerprint: DeviceRegistry.fingerprint(publicKey: key))
        try Data("\(mini.host) \(DevicePairingClient.normalizedHostKey(miniHost)!)\n".utf8).write(to: book.registry.knownHostsURL)
        _ = try book.registry.add(id: mini.id, name: "fixture 6", host: mini.host, user: NSUserName(),
                                  publicKeyFingerprint: DeviceRegistry.fingerprint(publicKey: miniHost))
        try mini.fleet.bootstrapPrimary(host: mini.host)
        book.dispatch.synchronize(); book.dispatch.synchronize()
        try check("legacy-mini-book-no-repairing", mini.fleet.current()!.roster!.devices.count == 2
                  && mini.fleet.current()!.roster!.primaryID == mini.id && book.fleet.trust()?.primaryID == mini.id)
        try check("legacy-upgraded-auto-bidirectional", authorized(mini, book.clientKey) && authorized(book, mini.clientKey))
        // 仍無名單協定的舊 peer 保留單向，不能把缺的 key 當成另一種 key。
        let legacy = try make(8)
        let legacyKey = try legacy.clientKey
        _ = try mini.registry.add(id: legacy.id, name: "fixture", host: legacy.host, user: NSUserName(),
                                  publicKeyFingerprint: DeviceRegistry.fingerprint(publicKey: legacyKey))
        _ = try mini.registry.authorize(publicKey: legacyKey, deviceID: legacy.id)
        try check("legacy-no-roster-status", legacy.fleet.statusText == "舊版，更新後自動互通")
        let defaultFaction = try JSONDecoder().decode(DeviceFaction.self, from:
            Data(#"{"id":"default","name":"fixture","kind":"managed","managerDisplayName":"Company"}"#.utf8))
        try check("primary-display-defaults-false", !defaultFaction.showPrimaryToMembers)
        try check("audit-rejections-recorded", String(contentsOf: a.fleet.logURL, encoding: .utf8).contains("fleet_signer"))
        let nameHost = try make(12, primary: true), nameClient = try make(13)
        try nameHost.fleet.bootstrapPrimary(host: nameHost.host)
        try pair(nameHost, nameClient, name: "fixture\u{202E}\u{200B} visible")
        try check("pairing-authenticates-original-name-before-canonical-storage",
                  nameHost.fleet.current()?.roster?.devices.first(where: { $0.id == nameClient.id })?.name == "fixture visible")
        print("W187FLEET SUMMARY checks=\(checks) failures=0")
    }
}

extension DeviceDispatch {
    fileprivate func identityForFleetFixture() throws -> DeviceIdentity {
        try DeviceIdentityStore.forLocalDevice(entry: entry).read()
    }
}
#endif
