#if DEBUG
import CryptoKit
import Darwin
import Foundation

enum DeviceFleetRoundTwoAcceptance {
    static func run(make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw NSError(domain: "W187R2_FAIL_" + name, code: 1) }
            print("W187R2 PASS \(name)")
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch { print("W187R2 PASS \(name)"); return }
            throw NSError(domain: "W187R2_UNEXPECTED_ACCEPT_" + name, code: 1)
        }
        let a = try make(30, true), b = try make(31, false), p = try make(32, false), q = try make(33, false)
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b, .owner, nil, false, false)
        try a.fleet.setFaction(.init(id: "staff-r2", name: "Synthetic staff", kind: .managed, managerDisplayName: "Synthetic manager"))
        try pair(a, p, .managed, "staff-r2", true, false)
        let firstStaffRoster = try a.fleet.current()!.roster!
        try check("g-admission-first-staff-has-no-primary", firstStaffRoster.groups.first { $0.id == "staff-r2" }!.primaryDeviceID.isEmpty
            && firstStaffRoster.devices.first { $0.id == p.id }!.role == .secondary)
        try pair(a, q, .managed, "staff-r2", true, false)
        a.dispatch.pushFleetNow()
        // Preview and decline perform no enrollment or device routing writes on either side.
        let pending = try make(34, false)
        var previewEnv = a.env; previewEnv["TATWO2_PAIRING_HOST"] = "127.0.0.1"
        let previewHost = DevicePairingHost(registry: a.registry, environment: previewEnv, peerHostResolver: { _ in pending.host })
        defer { previewHost.cancelPairingWindow() }
        let previewWindow = try previewHost.startPairingWindow(kind: .managed, factionID: "staff-r2")
        let previewClient = DevicePairingClient(registry: pending.registry, environment: pending.env,
            sshVerifier: { _, _, _ in true }, hostKeyResolver: { _ in try? a.hostKey })
        let beforePreview = try a.fleet.envelope()
        _ = try previewClient.pair(host: "127.0.0.1", port: Int(previewWindow.listenAddress.split(separator: ":").last!)!,
            code: previewWindow.code, name: "Synthetic preview", kind: .managed, consentToManagement: true, previewOnly: true)
        try check("DM-03-preview-and-decline-never-enroll", a.fleet.envelope() == beforePreview && pending.fleet.trust() == nil
            && pending.registry.list().isEmpty && previewClient.managementPreview != nil)
        try rejects("DM-03-changed-preview-consent-is-refused") {
            _ = try previewClient.pair(host: "127.0.0.1", port: Int(previewWindow.listenAddress.split(separator: ":").last!)!,
                code: previewWindow.code, name: "Synthetic preview", kind: .managed, consentToManagement: true, previewDigest: "invalid")
        }
        try check("DM-03-stale-consent-writes-no-membership", a.fleet.envelope() == beforePreview && pending.fleet.trust() == nil)
        previewHost.cancelPairingWindow()
        // Fifth ruling removes incoming colleague grants. Reconciliation still must not
        // close an unrelated outgoing fixture merely because it is not an incoming controller.
        let qAtP = a.registry.list().first { $0.id == q.id }!
        _ = try p.registry.add(qAtP) // Historical stale colleague route, never a real device.
        let link = RemoteHostLink(environment: p.env)
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["60"]
        defer { if sleeper.isRunning { sleeper.terminate() } }
        try link.attachFixture(device: qAtP, process: sleeper)
        try p.fleet.reconcile(p.fleet.current()!)
        try check("DM-02-stale-colleague-route-is-closed-and-removed", link.fixtureRevoked
            && !p.registry.list().contains { $0.id == q.id })
        try check("GATE-02-nil-fingerprint-denied-on-MAIN-and-SUB", !OSSocketCaller.sshMethodAllowed(fingerprint: nil, method: "memory_list", registry: a.registry)
            && !OSSocketCaller.sshMethodAllowed(fingerprint: nil, method: "memory_list", registry: p.registry))
        var roster = try a.fleet.current()!.roster!
        let move = DeviceFleetChange.moveDevice(id: b.id, groupID: "staff-r2")
        try rejects("DM-02-MAIN-downgrade-is-refused") { _ = try a.fleet.propose([move], actor: a.id) }
        let label = DeviceFleetName.label(roster.devices.first { $0.id == p.id }!, groups: roster.groups)
        try check("DM-04-SUB-role-label-includes-group", label.contains("職員電腦") && label.contains("Synthetic staff") && label.contains("SUB"))
        let rename = try a.fleet.propose([.renameDevice(id: q.id, name: roster.devices.first { $0.id == b.id }!.name)], actor: a.id)
        try check("DM-04-name-unique-across-groups", rename.preview.devices.first { $0.id == q.id }!.name != roster.devices.first { $0.id == b.id }!.name)
        a.fleet.discardProposal(rename.id)
        let edge = roster.edges.firstIndex { $0.from == .group("main") && $0.to == .group("staff-r2") }
            ?? roster.edges.firstIndex { $0.to == .group("staff-r2") && $0.from.kind == .group }!
        roster.edges[edge].capabilities = ["files"]
        try a.fleet.publish(&roster); a.dispatch.pushFleetNow()
        let fp = try DeviceRegistry.fingerprint(publicKey: a.clientKey)
        try check("GATE-01-REV-03-fleet-channel-without-dispatch", p.fleet.methodAllowed(fingerprint: fp, method: "dispatch_fetch")
            && p.fleet.methodAllowed(fingerprint: fp, method: "dispatch_ack") && !p.fleet.methodAllowed(fingerprint: fp, method: "send_message"))
        for method in ["get_document", "transcript", "pull_thread", "push_thread", "assistant_append_offline", "project_proposal_decide", "remote_hands_action", "hands_build"] {
            try check("GATE-04-DM-01-managed-denies-" + method, !p.fleet.methodAllowed(fingerprint: fp, method: method))
        }
        try p.fleet.requestLeave(); a.dispatch.synchronize()
        try check("DM-03-TR-01-leave-request-without-dispatch", a.fleet.leaveRequests().contains(p.id)
            && !p.fleet.methodAllowed(fingerprint: fp, method: "document_inspect"))
        // Owner apply must still write its originals after any managed revocation.
        try a.fleet.revoke(p.id)
        let changed = Data("synthetic constitution after managed revocation\n".utf8)
        try DeviceDispatchSafeFile.write(changed, url: a.dispatch.entry.constitution)
        b.dispatch.synchronize()
        try check("REV-01-owner-sync-after-managed-revoke-converges", b.dispatch.receipts()[a.id]?.phase == "converged"
            && Data(contentsOf: b.dispatch.entry.constitution) == changed)
        try check("REV-01-owner-package-excludes-revocations", !a.fleet.managedDeliveries().keys.contains(p.id))
        var bundle = try a.dispatch.offer(to: b.id)
        var bad = try a.fleet.delivery(for: q.id)!; bad.signature = Data([0])
        bundle.fleetDeliveries = [p.id: try a.fleet.delivery(for: p.id)!, q.id: bad]
        let receipt = try b.dispatch.apply(bundle, authenticatedPrimary: b.registry.list().first { $0.id == a.id }!)
        try check("REV-01-invalid-projection-does-not-abort-apply", receipt.phase == "converged" && b.fleet.read().deliveries?.isEmpty == true)
        // A later explicitly confirmed restoration must start a fresh local consent lifecycle.
        a.dispatch.pushFleetNow()
        try pair(a, p, .managed, "staff-r2", true, true)
        try check("DM-03-REV-05-confirmed-rejoin-clears-old-leave-request", !p.fleet.read().leaving
            && p.fleet.methodAllowed(fingerprint: fp, method: "document_inspect")
            && !a.fleet.current()!.roster!.revoked.contains(p.id) && !a.fleet.read().leaveRequests.contains(p.id))
        // Generate all key kinds under the fake registry root, never a user's SSH home.
        let peer = b.registry.list().first { $0.id == a.id }!
        var mixed = "\(a.host) \(try DeviceFleetPublicKey.withoutComment(a.hostKey))\n"
        for algorithm in ["ecdsa", "rsa"] {
            let path = b.registry.root.appendingPathComponent("fixture-" + algorithm).path
            let status = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", algorithm, "-N", "", "-C", "fixture", "-f", path]).0
            try check("PIN-02-generated-" + algorithm, status == 0)
            mixed += a.host + " " + (try String(contentsOfFile: path + ".pub", encoding: .utf8))
        }
        try DeviceDispatchSafeFile.write(Data(mixed.utf8), url: b.registry.knownHostsURL)
        _ = try DeviceFleetSSHPins.lines(for: peer, registry: b.registry)
        try check("PIN-02-Swift-three-algorithms-connectable", true)
        let conflict = mixed + a.host + " " + (try DeviceFleetPublicKey.withoutComment(q.hostKey)) + "\n"
        try DeviceDispatchSafeFile.write(Data(conflict.utf8), url: b.registry.knownHostsURL)
        try rejects("PIN-02-Swift-same-algorithm-different-key-refused") { _ = try DeviceFleetSSHPins.lines(for: peer, registry: b.registry) }
        try check("REG-05-pin-conflict-keeps-routing-record", b.registry.list().contains { $0.id == a.id } && b.fleet.read().pinConflicts?.contains(a.id) == true)
        try DeviceDispatchSafeFile.write(Data(mixed.utf8), url: b.registry.knownHostsURL)
        _ = try DeviceFleetSSHPins.lines(for: peer, registry: b.registry)
        try check("REG-05-conflict-clears-after-repair", b.fleet.read().pinConflicts?.contains(a.id) != true)
        // Only TATWO-related endpoint fallback is eligible, and scanning has a finite lifetime.
        var scans = 0, killed: [pid_t] = []
        DeviceFleetRevocation.testHooks = .init(sessions: {
            scans += 1
            return [.init(pid: 9001, start: 1, fingerprint: nil, address: q.host, tatwoRelated: false),
                    .init(pid: 9002, start: 1, fingerprint: nil, address: q.host, tatwoRelated: true)]
        }, terminate: { killed.append($0.pid); return true })
        defer { DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false }) }
        for _ in 0..<10 { DeviceFleetRevocation.cutOff(b.registry.list().first { $0.id == q.id }!, registry: b.registry) }
        try check("CUT-07-unrelated-SSH-survives-bounded-sweeps", scans == 3 && Set(killed) == [9002])
        // An installed but unpublished previous helper can upgrade twice; tampering still refuses.
        let solo = try make(35, false), gate = DeviceFleetGate.path(registry: solo.registry)
        try DeviceFleetGate.install(registry: solo.registry)
        let intact = try Data(contentsOf: gate)
        for index in 1...2 {
            let previous = intact + Data([UInt8(index)])
            try DeviceDispatchSafeFile.write(previous, url: gate)
            let digest = SHA256.hash(data: previous).map { String(format: "%02x", $0) }.joined()
            try DeviceDispatchSafeFile.write(JSONSerialization.data(withJSONObject: ["gateHash": digest]), url: solo.registry.root.appendingPathComponent("fleet-gate-install.json"))
            try DeviceFleetGate.install(registry: solo.registry)
            try check("GATE-03-unpublished-upgrade-\(index)", Data(contentsOf: gate) == intact)
        }
        try DeviceDispatchSafeFile.write(intact + Data([255]), url: gate)
        try rejects("GATE-03-unpublished-tamper-is-not-repaired") { try DeviceFleetGate.install(registry: solo.registry) }
        let fresh = try make(36, false)
        try pair(a, fresh, .owner, nil, false, false)
        try a.fleet.revoke(fresh.id); a.dispatch.pushFleetNow()
        try pair(a, fresh, .owner, nil, false, false)
        let newID = try fresh.dispatch.identity().deviceID
        let reenrolled = try a.fleet.current()!.roster!
        try check("REV-05-generic-code-creates-new-identity-keeps-old-revoked", newID != fresh.id && reenrolled.revoked.contains(fresh.id)
            && reenrolled.devices.contains { $0.id == newID && !reenrolled.revoked.contains($0.id) })
        let stale = try make(37, false)
        try pair(a, stale, .owner, nil, false, false)
        try a.fleet.revoke(stale.id)
        try check("REV-05-unnotified-owner-retains-stale-cache-before-pair", !stale.fleet.locallyRevoked())
        try pair(a, stale, .owner, nil, false, false)
        try check("REV-05-signed-new-identity-handles-missed-revocation-notice", stale.dispatch.identity().deviceID != stale.id
            && a.fleet.current()!.roster!.revoked.contains(stale.id))
        var legacyNames = try a.fleet.current()!.roster!
        legacyNames.devices[legacyNames.devices.firstIndex { $0.id == q.id }!].name = legacyNames.devices.first { $0.id == b.id }!.name
        let mainName = legacyNames.groups.first { $0.type == .main }!.name
        legacyNames.groups[legacyNames.groups.firstIndex { $0.type == .sub }!].name = mainName
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacyBody = try encoder.encode(DeviceFleetPayload(roster: legacyNames))
        let legacySignature = try DeviceSignature.sign(legacyBody, namespace: DeviceFleetEnvelope.namespace, environment: a.env)
        var cached = try a.fleet.read()
        cached.envelope = .init(body: legacyBody, signature: legacySignature.0, publicKey: legacySignature.1)
        try a.fleet.save(cached)
        try check("DM-04-legacy-cross-group-names-remain-readable", a.fleet.current()?.roster != nil)
        let namingStore = a.fleet
        let repairNames = try namingStore.propose([.renameDevice(id: q.id, name: "fixture")], actor: a.id)
        _ = try namingStore.confirm(repairNames.id, userConfirmed: true)
        let renamedRoster = try a.fleet.current()!.roster!
        try check("DM-04-next-signed-roster-normalizes-all-names", Set(renamedRoster.devices.map(\.name)).count == renamedRoster.devices.count
            && Set(renamedRoster.groups.map(\.name)).count == renamedRoster.groups.count)
        print("W187R2 SUMMARY failures=0")
    }
}
#endif
