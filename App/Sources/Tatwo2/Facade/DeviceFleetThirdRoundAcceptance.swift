#if DEBUG
import Foundation

enum DeviceFleetThirdRoundAcceptance {
    static func run(scenario: String, make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw NSError(domain: "W187R3_FAIL_" + name, code: 1) }
            print("W187R3 PASS \(name)")
        }
        let a = try make(40, true), b = try make(41, false)
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b, .owner, nil, false)
        switch scenario {
        case "gate":
            let bridge = OSAgentBridge.fleetFixtureBridge()
            let proof = try b.dispatch.signed(method: "dispatch_fetch", payload: [:])
            let reply = try bridge.fixtureHandle(dispatch: a.dispatch, method: "dispatch_fetch", params: proof)
            try check("GATE-01-nil-fingerprint-fetch-through-handle", reply["ok"] as? Bool == true)
            let bundle = try DeviceDispatch.decode(DeviceDispatch.Bundle.self, reply["result"] as! [String: Any])
            let receipt = try b.dispatch.apply(bundle, authenticatedPrimary: b.registry.list().first { $0.id == a.id }!)
            let ack = try b.dispatch.signed(method: "dispatch_ack", payload: DeviceDispatch.object(receipt), recipient: a.id)
            try check("GATE-01-nil-fingerprint-ack-through-handle", bridge.fixtureHandle(dispatch: a.dispatch, method: "dispatch_ack", params: ack)["ok"] as? Bool == true)
            let unsigned = try bridge.fixtureHandle(dispatch: a.dispatch, method: "device_status", params: [:])
            try check("GATE-01-unsigned-remote-method-refused", unsigned["ok"] as? Bool == false)
            let reported = try bridge.fixtureHandle(dispatch: a.dispatch, method: "device_status", params: [:], fingerprint: DeviceRegistry.fingerprint(publicKey: b.clientKey))
            try check("GATE-05-reported-identity-cannot-replace-proof", reported["ok"] as? Bool == false)
            let handshake = try b.dispatch.signed(method: "device_status", payload: [:], recipient: a.id)
            try check("GATE-01-signed-remote-method-through-handle", bridge.fixtureHandle(dispatch: a.dispatch, method: "device_status", params: [:], handshake: handshake)["ok"] as? Bool == true)
            try check("GATE-01-replayed-handshake-refused", bridge.fixtureHandle(dispatch: a.dispatch, method: "device_status", params: [:], handshake: handshake)["ok"] as? Bool == false)
            let c = try make(44, false)
            try pair(a, c, .owner, nil, false)
            a.dispatch.pushFleetNow(); b.dispatch.synchronize()
            let key = try DeviceRegistry.fingerprint(publicKey: c.clientKey)
            try check("GATE-01-third-owner-key-present", b.registry.fleetHasAuthorizedFingerprint(key))
            let cleanupPeer = a.registry.list().first { $0.id == c.id }!
            try a.fleet.revoke(c.id); a.dispatch.pushFleetNow(); b.dispatch.synchronize()
            try check("GATE-03-revoked-unrestricted-owner-cleanup-route", !RemoteHostLink(environment: a.env, revocationCleanup: true).requiresFleetGate(cleanupPeer))
            try check("GATE-01-revocation-one-round-through-handle", !b.registry.fleetHasAuthorizedFingerprint(key))
            let revokedProof = try c.dispatch.signed(method: "device_status", payload: [:], recipient: a.id)
            try check("GATE-01-revoked-key-handshake-refused", bridge.fixtureHandle(dispatch: a.dispatch, method: "device_status", params: [:], handshake: revokedProof)["ok"] as? Bool == false)
            try check("GATE-03-revoked-owner-notice-through-handle", c.fleet.current()?.revocationNotice?.targetID == c.id && c.registry.list().allSatisfy { !c.registry.fleetHasAuthorizedFingerprint($0.publicKeyFingerprint) })
        case "narrow":
            let c = try make(44, false), d = try make(45, false)
            try pair(a, c, .owner, nil, false); try pair(a, d, .owner, nil, false)
            let bridge = OSAgentBridge.fleetFixtureBridge()
            for (step, caps) in [["files"], []].enumerated() {
                var roster = try a.fleet.current()!.roster!
                roster.edges.removeAll { ($0.from == .device(a.id) && $0.to == .device(b.id)) || ($0.from == .device(b.id) && $0.to == .device(a.id)) }
                roster.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: caps.isEmpty ? .none : .mutual, capabilities: caps))
                try a.fleet.publish(&roster); a.dispatch.pushFleetNow(); b.dispatch.synchronize()
                let peer = b.registry.list().first { $0.id == a.id }!
                let link = RemoteHostLink(environment: b.env)
                try check("ROSTER-02-restricted-route-selected-\(step)", link.requiresFleetGate(peer))
                try check("ROSTER-02-transport-without-user-arrow-\(step)", b.fleet.methodAllowed(fingerprint: DeviceRegistry.fingerprint(publicKey: a.clientKey), method: "dispatch_ack"))
                if step == 0 {
                    let proof = try b.dispatch.signed(method: "document_inspect", payload: ["id": "os"], recipient: a.id)
                    let reply = try bridge.fixtureHandle(dispatch: a.dispatch, method: "document_inspect", params: proof)
                    try check("GATE-02-narrowed-files-through-handle", reply["ok"] as? Bool == true && (reply["result"] as? [String: Any])?["text"] as? String == "synthetic constitution\n")
                } else {
                    let proof = try b.dispatch.signed(method: "document_inspect", payload: ["id": "os"], recipient: a.id)
                    try check("GATE-02-disconnected-files-refused", bridge.fixtureHandle(dispatch: a.dispatch, method: "document_inspect", params: proof)["ok"] as? Bool == false)
                }
                let victim = step == 0 ? c : d
                try a.fleet.revoke(victim.id); a.dispatch.pushFleetNow(); b.dispatch.synchronize()
                try check("ROSTER-02-revocation-one-round-after-narrow-\(step)", !b.registry.fleetHasAuthorizedFingerprint(DeviceRegistry.fingerprint(publicKey: victim.clientKey)))
            }
        case "roster":
            try a.fleet.setFaction(.init(id: "staff-r3", name: "Synthetic staff", kind: .managed, managerDisplayName: "Synthetic manager"))
            let p = try make(42, false)
            try pair(a, p, .managed, "staff-r3", true)
            let q = try make(43, false); try pair(a, q, .managed, "staff-r3", true)
            var roster = try a.fleet.current()!.roster!
            let main = roster.groups.first { $0.type == .main }!.id
            roster.edges.removeAll { $0.from == .group(main) && $0.to == .group("staff-r3") }
            roster.edges.append(.init(from: .group(main), to: .group("staff-r3"), direction: .oneway, capabilities: []))
            try a.fleet.publish(&roster)
            let deliveries = try a.fleet.managedDeliveries()
            try check("ROSTER-01-empty-controller-managedDeliveries", deliveries[p.id] != nil)
            let failingStore = a.fleet; failingStore.fixtureDeliveryFailures = [p.id]
            let isolated = try failingStore.managedDeliveries()
            try check("ROSTER-01-one-projection-failure-does-not-break-others", isolated[p.id] == nil && isolated[q.id] != nil)
            try check("ROSTER-01-skipped-projection-audited", String(contentsOf: failingStore.logURL, encoding: .utf8).contains("fleet_delivery_skipped_" + p.id))
            a.dispatch.pushFleetNow(); b.dispatch.synchronize()
            try check("ROSTER-01-main-converges-with-empty-controller", b.fleet.current()?.revision == a.fleet.current()?.revision)
            try check("ROSTER-01-staff-receives-empty-permission-projection", p.fleet.current()?.slice?.controllers.allSatisfy { $0.capabilities.isEmpty } == true)
            roster = try a.fleet.current()!.roster!
            let edge = roster.edges.firstIndex { $0.from == .group(main) && $0.to == .group("staff-r3") }!
            roster.edges[edge].direction = .none
            try a.fleet.publish(&roster); a.dispatch.pushFleetNow()
            try check("R2-GATE-01-disconnected-staff-keeps-only-roster-controller", p.fleet.current()?.slice?.controllers.contains { $0.clientKeyFingerprint == (try? DeviceRegistry.fingerprint(publicKey: a.clientKey)) && $0.capabilities.isEmpty } == true)
            let c = try make(44, false); try pair(a, c, .owner, nil, false)
            a.dispatch.pushFleetNow()
            let key = try DeviceRegistry.fingerprint(publicKey: c.clientKey)
            try a.fleet.revoke(c.id); a.dispatch.pushFleetNow(); b.dispatch.synchronize()
            try check("ROSTER-01-revocation-still-delivered", !b.registry.fleetHasAuthorizedFingerprint(key) && p.fleet.current()?.revision == a.fleet.current()?.revision)
        case "assistant":
            try a.fleet.setFaction(.init(id: "staff-r3", name: "Synthetic staff", kind: .managed, managerDisplayName: "Synthetic manager"))
            let p = try make(42, false), q = try make(43, false)
            try pair(a, p, .managed, "staff-r3", true)
            try pair(a, q, .managed, "staff-r3", true)
            let store = a.fleet
            let proposal = try store.propose([.setSubPrimary(groupID: "staff-r3", deviceID: p.id)], actor: a.id)
            _ = try store.confirm(proposal.id, userConfirmed: true)
            a.dispatch.pushFleetNow()
            try check("DM-01-designated-colleague-resolver-remains-local", AssistantPrimaryResolver.primaryDeviceID(environment: q.env) == nil)
            try check("DM-01-colleague-not-remembered-as-primary", !q.registry.list().contains { $0.id == p.id })
            try check("DM-02-no-colleague-SSH-eligible", !q.fleet.allowsPeerConnection(p.id))
            let slice = try q.fleet.current()!.slice!
            let peer = slice.devices.first { $0.id == p.id }!
            try check("DM-02-colleague-display-has-no-address-account-or-keys", peer.endpoints.isEmpty && peer.user.isEmpty && peer.clientPublicKey == nil && peer.hostPublicKey == nil)
            let wire = try DeviceDispatch.object(peer)
            try check("DM-02-display-wire-omits-sensitive-fields", ["endpoints", "user", "clientPublicKey", "hostPublicKey"].allSatisfy { wire[$0] == nil })
        case "warnings":
            let target = a.registry.list().first { $0.id == b.id }!
            let otherFingerprint = try DeviceRegistry.fingerprint(publicKey: a.clientKey)
            let oldHooks = DeviceFleetRevocation.testHooks
            defer { DeviceFleetRevocation.testHooks = oldHooks }
            DeviceFleetRevocation.testHooks = .init(sessions: {
                [.init(pid: 987654, start: 1, fingerprint: otherFingerprint, address: "192.0.2.88", tatwoRelated: false)]
            }, terminate: { _ in false })
            DeviceFleetRevocation.cutOff(target, registry: a.registry, revokeIdentity: false)
            try check("REV-01-other-key-session-does-not-warn-target", a.fleet.read().possiblyConnected?.contains(b.id) != true)
            DeviceFleetRevocation.testHooks = .init(sessions: {
                [.init(pid: 987654, start: 1, fingerprint: nil, address: nil, tatwoRelated: false)]
            }, terminate: { _ in false })
            DeviceFleetRevocation.cutOff(target, registry: a.registry, revokeIdentity: false)
            try check("REV-01-unknown-session-honestly-warns-target", a.fleet.read().possiblyConnected?.contains(b.id) == true)
            DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false })
            DeviceFleetRevocation.cutOff(target, registry: a.registry, revokeIdentity: false)
            try check("REV-01-no-sessions-clears-stale-warning", a.fleet.read().possiblyConnected?.contains(b.id) != true)
        case "repair":
            let bridge = OSAgentBridge.fleetFixtureBridge()
            let params: [String: Any] = [:]
            let oldProof = try b.dispatch.signed(method: "device_status", payload: params, recipient: a.id)
            try a.fleet.revoke(b.id)
            a.dispatch.pushFleetNow()
            try pair(a, b, .owner, nil, false)
            let newID = try b.dispatch.identity().deviceID
            try check("REV-05-generic-repair-keeps-old-identity-revoked", newID != b.id && a.fleet.current()!.roster!.revoked.contains(b.id))
            let policy = try JSONSerialization.jsonObject(with: Data(contentsOf: a.registry.root.appendingPathComponent("fleet-gate-policy.json"))) as! [String: Any]
            try check("REV-05-repaired-key-policy-bound-to-active-ID", (policy["controllers"] as? [String: Any])?[newID] != nil && (policy["controllers"] as? [String: Any])?[b.id] == nil)
            let freshProof = try b.dispatch.signed(method: "device_status", payload: params, recipient: a.id)
            let repairedReply = try bridge.fixtureHandle(dispatch: a.dispatch, method: "device_status", params: params, handshake: freshProof)
            if repairedReply["ok"] as? Bool != true { print("W187R3 repaired handshake error: \(repairedReply)") }
            try check("REV-05-repaired-owner-handshake-through-handle", repairedReply["ok"] as? Bool == true)
            try check("REV-05-old-revoked-ID-still-refused", bridge.fixtureHandle(dispatch: a.dispatch, method: "device_status", params: params, handshake: oldProof)["ok"] as? Bool == false)
            let oldHooks = DeviceFleetRevocation.testHooks
            defer { DeviceFleetRevocation.testHooks = oldHooks }
            var terminated = 0
            let reusedKey = try DeviceRegistry.fingerprint(publicKey: b.clientKey)
            DeviceFleetRevocation.testHooks = .init(sessions: {
                [.init(pid: 987654, start: 1, fingerprint: reusedKey, address: nil, tatwoRelated: true)]
            }, terminate: { _ in terminated += 1; return true })
            try a.fleet.reconcile(a.fleet.current()!)
            try check("REV-05-repaired-key-not-cut-by-old-tombstone", terminated == 0)
        case "gatefailure":
            let fresh = try make(48, false)
            try DeviceFleetGate.install(registry: fresh.registry)
            let freshGate = DeviceFleetGate.path(registry: fresh.registry)
            try FileManager.default.removeItem(at: freshGate)
            try DeviceFleetGate.install(registry: fresh.registry)
            try check("GATE-05-journaled-unreferenced-gate-reinstalled", FileManager.default.fileExists(atPath: freshGate.path))
            let gate = DeviceFleetGate.path(registry: a.registry)
            let intact = try Data(contentsOf: gate)
            try DeviceDispatchSafeFile.write(intact + Data([255]), url: gate)
            var roster = try a.fleet.current()!.roster!
            let edge = roster.edges.firstIndex { ($0.from == .device(a.id) && $0.to == .device(b.id)) || ($0.from == .device(b.id) && $0.to == .device(a.id)) }!
            roster.edges[edge].capabilities = ["files"]
            var refused = false
            do { try a.fleet.publish(&roster) } catch { refused = true }
            let fingerprint = try DeviceRegistry.fingerprint(publicKey: b.clientKey)
            try check("GATE-05-tampered-gate-publish-refused", refused)
            try check("GATE-05-narrowed-key-converges-despite-gate-failure", !a.registry.fleetHasUnrestrictedFingerprint(fingerprint) && !a.registry.fleetHasAuthorizedFingerprint(fingerprint))
            try DeviceDispatchSafeFile.write(intact, url: gate)
            try a.fleet.reconcile(a.fleet.current()!)
            let repairProof = try b.dispatch.signed(method: "document_inspect", payload: ["id": "os"], recipient: a.id)
            try check("GATE-05-intact-repair-restores-narrowed-files", OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: a.dispatch, method: "document_inspect", params: repairProof)["ok"] as? Bool == true)
            // Make cleanup fail after signed state is stored; registered transport must close first.
            final class CloseFlag: @unchecked Sendable { var closed = false }
            let flag = CloseFlag()
            let token = DeviceFleetConnections.register(b.id, scope: a.registry.root.path) { flag.closed = true }
            defer { DeviceFleetConnections.unregister(b.id, scope: a.registry.root.path, token: token) }
            let authorization = a.registry.authorizedKeysURL
            let oldKeys = try Data(contentsOf: authorization)
            try FileManager.default.removeItem(at: authorization)
            try FileManager.default.createDirectory(at: authorization, withIntermediateDirectories: false)
            refused = false
            do { try a.fleet.revoke(b.id) } catch { refused = true }
            try check("R2-GATE-06-transport-closed-before-failed-key-write", refused && flag.closed)
            try FileManager.default.removeItem(at: authorization)
            try DeviceDispatchSafeFile.write(oldKeys, url: authorization)
            try a.fleet.reconcile(a.fleet.current()!)
            try check("R2-GATE-06-retry-cleans-revoked-key", !a.registry.fleetHasAuthorizedFingerprint(fingerprint))
        case "pairing":
            let legacy = try make(46, false), joining = try make(47, false)
            var hostEnv = legacy.env; hostEnv["TATWO2_PAIRING_HOST"] = "127.0.0.1"
            let server = DevicePairingHost(registry: legacy.registry, environment: hostEnv, peerHostResolver: { _ in joining.host })
            defer { server.cancelPairingWindow() }
            let window = try server.startPairingWindow()
            let hostKey = try legacy.hostKey
            let client = DevicePairingClient(registry: joining.registry, environment: joining.env, sshVerifier: { _, _, _ in true }, hostKeyResolver: { _ in hostKey }, peerEndpoints: { _, row in row.endpoints })
            var rejected = false
            do { _ = try client.pair(host: "127.0.0.1", port: Int(window.listenAddress.split(separator: ":").last!)!, code: window.code, name: "Synthetic device", previewOnly: true) }
            catch { rejected = true }
            try check("PAIR-01-legacy-preview-refused", rejected)
            try check("PAIR-01-legacy-preview-never-authorizes-key", !legacy.registry.fleetHasAuthorizedFingerprint(DeviceRegistry.fingerprint(publicKey: joining.clientKey)))
            rejected = false
            do { _ = try client.pair(host: "127.0.0.1", port: Int(window.listenAddress.split(separator: ":").last!)!, code: window.code, name: "Synthetic device") }
            catch { rejected = true }
            try check("PAIR-01-refused-preview-code-consumed", rejected)
            let secondaryHost = DevicePairingHost(registry: b.registry, environment: b.env)
            rejected = false
            do { _ = try secondaryHost.startPairingWindow(kind: .sandbox) } catch { rejected = true }
            try check("PAIR-06-secondary-sandbox-never-opens-window", rejected)
            try check("PAIR-07-plaintext-success-never-accepted", !client.fixtureReplyAccepted(Data("{\"ok\":true}".utf8), code: "ABC123", nonce: DevicePairingAuth.makeNonce()))
            try check("PAIR-07-invalid-encrypted-success-never-accepted", !client.fixtureReplyAccepted(Data("{\"ciphertext\":\"broken\",\"ok\":true}".utf8), code: "ABC123", nonce: DevicePairingAuth.makeNonce()))
            let budget = a.fleet
            for _ in 0..<3 { try check("CUT-01-narrow-sweep-budget", budget.claimRevocationSweep(b.id, revokeIdentity: false)) }
            try check("CUT-01-revoke-has-independent-budget", budget.claimRevocationSweep(b.id, revokeIdentity: true))
            let peer = b.registry.list().first { $0.id == a.id }!
            let extra = try DeviceFleetPublicKey.withoutComment(joining.hostKey)
            try DeviceDispatchSafeFile.write(Data(("@cert-authority " + a.host + " " + extra + "\n@revoked " + a.host + " " + extra + "\n").utf8), url: b.registry.knownHostsURL)
            try check("PIN-01-marker-key-not-literal-host-conflict", !DeviceFleetSSHPins.lines(for: peer, registry: b.registry).isEmpty)
        default: throw DeviceFleetError.malformed
        }
        print("W187R3 SUMMARY failures=0")
    }
}
#endif
