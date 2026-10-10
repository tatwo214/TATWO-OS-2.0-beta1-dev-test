#if DEBUG
import Foundation

enum DeviceFleetFourthRoundAcceptance {
    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var sequences: [UInt64] = []
        var failures: [String] = []
        func append(_ sequence: UInt64) { lock.withLock { sequences.append(sequence) } }
        func fail(_ error: Error) { lock.withLock { failures.append(DeviceFleetReason.code(error) ?? error.localizedDescription) } }
    }
    static func run(scenario: String, make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R4_FAIL_" + name) }
            print("W187R4 PASS " + name)
        }
        func rejects(_ name: String, expected: DeviceFleetError? = nil, _ action: () throws -> Void) throws {
            do { try action() } catch { if let expected, error as? DeviceFleetError != expected { throw error }; print("W187R4 PASS " + name); return }
            throw DeviceDispatch.Failure(reason: "W187R4_UNEXPECTED_ACCEPT_" + name)
        }
        let a = try make(60, true), b = try make(61, false)
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b, .owner, nil, false)
        func instance(_ fake: DeviceFleetAcceptance.Fake) -> DeviceDispatch {
            DeviceDispatch(entry: fake.dispatch.entry, registry: fake.registry, environment: fake.env)
        }
        switch scenario {
        case "roster":
            let c = try make(62, false)
            let member = DeviceFleetMember(id: c.id, name: "unconfirmed device", factionID: "owner", role: .secondary,
                clientKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: c.clientKey),
                hostKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: c.hostKey),
                clientPublicKey: try c.clientKey, hostPublicKey: try c.hostKey,
                endpoints: [.init(kind: .lan, host: c.host)], user: "fixture")
            for direction in [DeviceFleetEdge.Direction.none, .oneway, .mutual] {
                var roster = try a.fleet.current()!.roster!
                roster.edges.removeAll { ($0.from == .device(a.id) && $0.to == .device(b.id)) || ($0.from == .device(b.id) && $0.to == .device(a.id)) }
                roster.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: direction, capabilities: direction == .none ? [] : DeviceFleetCapabilities.all))
                try a.fleet.publish(&roster); a.dispatch.pushFleetNow(); b.dispatch.synchronize()
                let bridge = OSAgentBridge.fleetFixtureBridge()
                let fetch = try b.dispatch.signed(method: "dispatch_fetch", payload: [:], recipient: a.id)
                let reply = try bridge.fixtureHandle(dispatch: a.dispatch, method: "dispatch_fetch", params: fetch)
                try check("ROSTER-01-fetch-allowed-\(direction)", reply["ok"] as? Bool == true)
                let bundle = try DeviceDispatch.decode(DeviceDispatch.Bundle.self, reply["result"] as! [String: Any])
                let revision = try a.fleet.current()!.revision
                let receipt = DeviceDispatch.Receipt(seq: bundle.seq, phase: "converged", hashes: bundle.hashes, updated: Date(), fleetMembers: [member])
                let ack = try b.dispatch.signed(method: "dispatch_ack", payload: DeviceDispatch.object(receipt), recipient: a.id)
                let denied = try bridge.fixtureHandle(dispatch: a.dispatch, method: "dispatch_ack", params: ack)
                try check("ROSTER-01-pending-member-through-handle-refused-\(direction)", denied["ok"] as? Bool == false)
                try check("ROSTER-01-no-roster-or-key-change-\(direction)", a.fleet.current()?.revision == revision && !a.registry.fleetHasAuthorizedFingerprint(member.clientKeyFingerprint!))
            }
        case "initial-window":
            let receiver = instance(b)
            let delayed = try instance(a).signedHandshake(method: "device_status", params: [:], recipient: b.id)
            let bundle = try instance(a).offer(to: b.id)
            let primaryPeer = b.registry.list().first { $0.id == a.id }!
            let receipt = try receiver.apply(bundle, authenticatedPrimary: primaryPeer)
            try check("SEQ-bundle-applied-before-first-inbound-proof", receipt.phase == "converged")
            var legacyBody = try JSONSerialization.jsonObject(with: Data(base64Encoded: delayed["body"] as! String)!) as! [String: Any]
            legacyBody.removeValue(forKey: "issuedAt"); legacyBody["payload"] = [String: Any]()
            let legacyBytes = try JSONSerialization.data(withJSONObject: legacyBody, options: [.sortedKeys])
            let legacySignature = try DeviceSignature.sign(legacyBytes, namespace: "tatwo2-rpc", environment: a.env)
            let legacy: [String: Any] = ["body": legacyBytes.base64EncodedString(), "signature": legacySignature.0.base64EncodedString(), "publicKey": legacySignature.1]
            do {
                _ = try instance(b).authenticate(method: "device_status", proof: legacy)
                throw DeviceDispatch.Failure(reason: "W187R4_UNEXPECTED_ACCEPT_legacy_without_time")
            } catch let failure as DeviceDispatch.Failure {
                try check("SEQ-legacy-without-time-refused-before-window-migration", failure.reason == "rpc_proof_expired")
            }
            let bridge = OSAgentBridge.fleetFixtureBridge()
            try check("SEQ-first-handshake-after-newer-bundle-accepted", bridge.fixtureHandle(dispatch: instance(b), method: "device_status", params: [:], handshake: delayed)["ok"] as? Bool == true)
            try rejects("SEQ-first-handshake-replay-after-bundle-refused") {
                _ = try instance(b).authenticate(method: "device_status", proof: delayed)
            }
        case "replay":
            let receiver = instance(a)
            let fetch = try instance(b).signed(method: "dispatch_fetch", payload: [:], recipient: a.id)
            let memory = try instance(b).signed(method: "memory_sync_target", payload: [:], recipient: a.id)
            let handshake = try instance(b).signed(method: "device_status", payload: [:], recipient: a.id)
            let bridge = OSAgentBridge.fleetFixtureBridge()
            try check("SEQ-handshake-arrives-first", bridge.fixtureHandle(dispatch: receiver, method: "device_status", params: [:], handshake: handshake)["ok"] as? Bool == true)
            try check("SEQ-fetch-signed-first-arrives-last", bridge.fixtureHandle(dispatch: instance(a), method: "dispatch_fetch", params: fetch)["ok"] as? Bool == true)
            _ = try instance(a).authenticate(method: "memory_sync_target", proof: memory)
            try check("SEQ-memory-interleaved", true)
            try rejects("SEQ-duplicate-refused-across-instance") { _ = try instance(a).authenticate(method: "dispatch_fetch", proof: fetch) }
            let old = try instance(b).signed(method: "dispatch_fetch", payload: [:], recipient: a.id)
            // A real signer can have sequence gaps after failed sends; advance its durable counter.
            let file = b.dispatch.root.appendingPathComponent("state.json")
            var state = try JSONDecoder().decode(DeviceDispatch.State.self, from: Data(contentsOf: file))
            state.next += 2048
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            let latest = try instance(b).signed(method: "dispatch_fetch", payload: [:], recipient: a.id)
            _ = try instance(a).authenticate(method: "dispatch_fetch", proof: latest)
            try rejects("SEQ-too-old-refused") { _ = try instance(a).authenticate(method: "dispatch_fetch", proof: old) }
            let timed = try instance(b).signed(method: "dispatch_fetch", payload: [:], recipient: a.id)
            var timedBody = try JSONSerialization.jsonObject(with: Data(base64Encoded: timed["body"] as! String)!) as! [String: Any]
            timedBody["issuedAt"] = Date().timeIntervalSince1970 - 121
            let expired = try JSONSerialization.data(withJSONObject: timedBody, options: [.sortedKeys])
            let signature = try DeviceSignature.sign(expired, namespace: "tatwo2-rpc", environment: b.env)
            let expiredProof: [String: Any] = ["body": expired.base64EncodedString(), "signature": signature.0.base64EncodedString(), "publicKey": signature.1]
            try rejects("SEQ-time-window-expired-proof-refused") { _ = try instance(a).authenticate(method: "dispatch_fetch", proof: expiredProof) }
        case "concurrent":
            let results = Results(), group = DispatchGroup(), ready = DispatchSemaphore(value: 0)
            let methods = ["device_status", "dispatch_fetch", "memory_sync_target"]
            // Separate instances and truly simultaneous sign + authenticate, no test serial queue.
            for index in 0..<18 {
                let signer = instance(b), receiver = instance(a), method = methods[index % methods.count]
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    ready.wait()
                    do {
                        let proof = try signer.signed(method: method, payload: [:], recipient: a.id)
                        let raw = Data(base64Encoded: proof["body"] as! String)!
                        let body = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
                        results.append(body["seq"] as! UInt64)
                        _ = try receiver.authenticate(method: method, proof: proof)
                    } catch { results.fail(error) }
                }
            }
            for _ in 0..<18 { ready.signal() }
            try check("SEQ-concurrent-completes", group.wait(timeout: .now() + 60) == .success)
            try check("SEQ-concurrent-all-authenticated", results.failures.isEmpty)
            try check("SEQ-cross-instance-unique-counter", Set(results.sequences).count == 18)
            let proof = try instance(b).signed(method: "dispatch_fetch", payload: [:], recipient: a.id)
            let duplicates = Results(), duplicateGroup = DispatchGroup()
            for _ in 0..<8 {
                let receiver = instance(a)
                duplicateGroup.enter()
                DispatchQueue.global().async {
                    defer { duplicateGroup.leave() }
                    do { _ = try receiver.authenticate(method: "dispatch_fetch", proof: proof); duplicates.append(1) }
                    catch { duplicates.fail(error) }
                }
            }
            try check("SEQ-concurrent-duplicate-completes", duplicateGroup.wait(timeout: .now() + 60) == .success)
            try check("SEQ-concurrent-duplicate-exactly-one-accept", duplicates.sequences.count == 1 && duplicates.failures.count == 7)
        case "delivery-warning":
            let c = try make(62, false)
            let main = try a.fleet.current()!.roster!.groups.first { $0.type == .main }!.id
            try pair(a, c, .sandbox, main, true)
            let rejecting = DeviceDispatch(entry: a.dispatch.entry, registry: a.registry, environment: a.env,
                rpc: { _, _, _ in throw DeviceFleetGate.CallError.refused })
            rejecting.synchronize()
            let state = try DeviceDispatch.object(a.fleet.read())
            try check("DM-04-rejected-projection-names-pending-recipient", (state["deliveryProblems"] as? [String: String])?[c.id] != nil)
            let lines = DeviceFleetStore.deliveryWarnings(roster: try a.fleet.current()?.roster,
                problems: state["deliveryProblems"] as? [String: String] ?? [:]).values.sorted()
            try check("DM-04-warning-names-device-reason-and-update", lines.contains { $0.contains("fixture 62") && $0.contains("這台的 App 需要更新才能收新版權限") })
            let snapshot = DeviceFleetUISnapshot(payload: try a.fleet.current(), localID: a.id,
                deliveryProblems: state["deliveryProblems"] as? [String: String] ?? [:])
            try check("DM-04-settings-projects-pending-warning", snapshot.pendingDeliveryLines.isEmpty && snapshot.deliveryWarnings[c.id] == lines.first)
            a.dispatch.synchronize()
            let delivered = try DeviceDispatch.object(a.fleet.read())
            try check("DM-04-successful-delivery-clears-warning", (delivered["deliveryProblems"] as? [String: String])?[c.id] == nil)
            let bridge = OSAgentBridge.fleetFixtureBridge()
            let fetchFailure = DeviceDispatch(entry: a.dispatch.entry, registry: a.registry, environment: a.env,
                rpc: { peer, method, params in
                    guard peer.id == c.id, method == "dispatch_ack" else { throw DeviceFleetGate.CallError.appUnavailable }
                    let reply = try bridge.fixtureHandle(dispatch: c.dispatch, method: method, params: params)
                    guard reply["ok"] as? Bool == true, let result = reply["result"] as? [String: Any] else { throw DeviceFleetError.malformed }
                    return result
                })
            fetchFailure.synchronize()
            try check("DM-04-accepted-projection-followup-failure-is-not-pending", a.fleet.read().deliveryProblems?[c.id] == nil)
        case "sweep":
            var sweeps = 0
            DeviceFleetRevocation.testHooks = .init(sessions: { sweeps += 1; return [] }, terminate: { _ in false })
            defer { DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false }) }
            try a.fleet.revoke(b.id)
            for _ in 0..<5 {
                var roster = try a.fleet.current()!.roster!; try a.fleet.publish(&roster)
            }
            try check("CUT-02-revocation-sweep-budget-survives-unrelated-revisions", sweeps <= 3)
        case "broad-scope":
            let c = try make(62, false); try pair(a, c, .owner, nil, false)
            var roster = try a.fleet.current()!.roster!
            roster.edges.removeAll { ($0.from == .device(b.id) && $0.to == .device(c.id)) || ($0.from == .device(c.id) && $0.to == .device(b.id)) }
            roster.edges.append(.init(from: .device(b.id), to: .device(c.id), direction: .none, capabilities: []))
            try a.fleet.publish(&roster)
            let store = a.fleet
            let proposal = try store.propose([.revoke(id: b.id)], actor: a.id)
            _ = try store.confirm(proposal.id, userConfirmed: true, disconnectAllSelected: true)
            try check("TR-02-all-disconnect-excludes-unaffected-and-revoked-MAIN", Set(a.fleet.current()!.roster!.disconnectAll!.targets) == [a.id])
        case "broad":
            let sessions: [DeviceFleetRevocation.Session] = [
                .init(pid: 8001, start: 1, fingerprint: nil, address: "example.local", tatwoRelated: false),
                .init(pid: 8002, start: 1, fingerprint: nil, address: "192.0.2.199", tatwoRelated: false)]
            var killed: [Int32] = []
            DeviceFleetRevocation.testHooks = .init(sessions: { sessions }, terminate: { killed.append($0.pid); return true })
            defer { DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false }) }
            var roster = try a.fleet.current()!.roster!; roster.version += 1
            var payload = try DeviceDispatch.object(DeviceFleetPayload(roster: roster))
            var graph = payload["roster"] as! [String: Any]
            graph["disconnectAll"] = ["id": UUID().uuidString, "revision": roster.version, "targets": [b.id]]
            payload["roster"] = graph
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let signed = try DeviceSignature.sign(body, namespace: DeviceFleetEnvelope.namespace, environment: a.env)
            let envelope = DeviceFleetEnvelope(body: body, signature: signed.0, publicKey: signed.1)
            try b.fleet.synchronizeEnvelope(envelope)
            try check("TR-02-physical-all-disconnect-reaches-other-MAIN", killed == [8001,8002])
            try b.fleet.synchronizeEnvelope(envelope)
            try check("TR-02-all-disconnect-event-consumed-once", killed == [8001,8002])
        case "gate-status":
            var roster = try a.fleet.current()!.roster!
            roster.edges.removeAll { $0.from == .device(a.id) && $0.to == .device(b.id) }
            roster.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: .oneway, capabilities: ["files"]))
            try a.fleet.publish(&roster); try b.fleet.synchronizeEnvelope(a.fleet.envelope()!)
            let peer = a.registry.list().first { $0.id == b.id }!
            let link = RemoteHostLink(environment: a.env)
            link.fixtureGate = { _, _, _ in throw DeviceFleetGate.CallError.appUnavailable }
            try check("R3-GATE-02-restricted-SSH-ready-App-unavailable", link.queryDeviceStatus(device: peer).connection == .appUnavailable)
            DeviceFleetGate.fixtureExchange = { root, destination, frame in
                guard root == a.registry.root.path, destination.id == b.id, frame["method"] as? String == "device_status" else { throw DeviceFleetError.malformed }
                return (0, "Authenticated to synthetic peer\n", Data("{\"ok\":false,\"error\":\"app_unavailable\"}\n".utf8))
            }
            defer { DeviceFleetGate.fixtureExchange = nil }
            try check("R3-GATE-02-status-through-real-Gate-call", RemoteHostLink(environment: a.env).queryDeviceStatus(device: peer).connection == .appUnavailable)
            DeviceFleetGate.fixtureExchange = { _, _, _ in
                (0, "Authenticated to synthetic peer\n", Data("{\"ok\":false,\"error\":\"fixture_projection_refused\"}\n".utf8))
            }
            do {
                _ = try DeviceFleetGate.call(peer: peer, method: "dispatch_ack", params: [:], registry: a.registry)
                throw DeviceDispatch.Failure(reason: "DM-04-refused-projection-accepted")
            } catch {
                try check("DM-04-Gate-preserves-projection-refusal-reason", DeviceFleetReason.code(error) == "fixture_projection_refused")
            }
        case "frame":
            let params: [String: Any] = ["synthetic": String(repeating: "x", count: 10 * 1024 * 1024)]
            let frame = try RemoteHostLink(environment: b.env).fixtureFrame(method: "device_status", params: params, recipient: a.id)
            let data = try JSONSerialization.data(withJSONObject: frame)
            try check("GATE-03-ten-MB-params-fit-original-sixteen-MB-frame", data.count < 16 * 1024 * 1024)
            let proof = frame["deviceHandshake"] as! [String: Any]
            let bridge = OSAgentBridge.fleetFixtureBridge()
            try check("GATE-03-parameter-tamper-refused", bridge.fixtureHandle(dispatch: a.dispatch, method: "device_status", params: ["synthetic": "changed"], handshake: proof)["ok"] as? Bool == false)
            let next = try RemoteHostLink(environment: b.env).fixtureFrame(method: "device_status", params: params, recipient: a.id)
            let verified = try a.dispatch.authenticate(method: "device_status", proof: next["deviceHandshake"] as! [String: Any]).1
            try check("GATE-03-large-real-handshake-accepted", verified["paramsSHA256"] as? String == DeviceDispatch.hash(try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])))
        case "memory":
            var roster = try a.fleet.current()!.roster!
            roster.edges.removeAll { ($0.from == .device(a.id) && $0.to == .device(b.id)) || ($0.from == .device(b.id) && $0.to == .device(a.id)) }
            roster.edges.append(.init(from: .device(b.id), to: .device(a.id), direction: .oneway, capabilities: ["memory"]))
            try a.fleet.publish(&roster); try b.fleet.synchronizeEnvelope(a.fleet.envelope()!)
            let p = EngineMemoryPaths(home: a.dispatch.root.appendingPathComponent("home").path, entryRoot: a.dispatch.entry.root)
            let q = EngineMemoryPaths(home: b.dispatch.root.appendingPathComponent("home").path, entryRoot: b.dispatch.entry.root)
            for paths in [p,q] { try EngineMemoryLinks.createMemoryFolder(paths.memory) }
            try TatwoMemorySyncAcceptance.note(p.memory, "primary.md", title: "Synthetic primary", body: "Synthetic fixture memory.")
            try TatwoMemorySyncAcceptance.note(q.memory, "secondary.md", title: "Synthetic secondary", body: "Synthetic fixture memory.")
            _ = EngineMemoryLinks.commit(p.memory, message: "fixture"); _ = EngineMemoryLinks.commit(q.memory, message: "fixture")
            let engine = TatwoMemorySyncEngine(paths: { p }, dispatch: a.dispatch)
            let bridge = OSAgentBridge.fleetFixtureBridge(); bridge.fixtureMemory(engine)
            let proof = try b.dispatch.signed(method: "memory_sync_export", payload: [:], recipient: a.id)
            let exported = try bridge.fixtureHandle(dispatch: a.dispatch, method: "memory_sync_export", params: proof)
            if let error = exported["error"] { print("W187R4 memory export diagnostic " + String(describing: error)) }
            try check("R3-GATE-02-restricted-memory-export-through-real-handle", exported["ok"] as? Bool == true)
            let channel = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, retireBackup: { _ in }, rpc: { _, method, signed in
                let reply = try bridge.fixtureHandle(dispatch: a.dispatch, method: method, params: signed)
                guard reply["ok"] as? Bool == true, let result = reply["result"] as? [String: Any] else {
                    throw RemoteHostLinkError.remoteError(reply["error"] as? String ?? "fixture rejected")
                }
                return result
            })
            let secondary = TatwoMemorySyncEngine(paths: { q }, dispatch: channel)
            try check("R3-GATE-02-memory-sync-without-unrestricted-shell", secondary.runOnce(.manual).state == .synced
                && FileManager.default.fileExists(atPath: p.memory.appendingPathComponent("secondary.md").path)
                && FileManager.default.fileExists(atPath: q.memory.appendingPathComponent("primary.md").path))
            let invalid = try b.dispatch.signed(method: "memory_sync_import", payload: ["bundle": Data("invalid fixture".utf8).base64EncodedString(), "commit": String(repeating: "a", count: 40), "ref": TatwoMemorySyncEngine.inboxRef(b.id)], recipient: a.id)
            try check("R3-GATE-02-invalid-git-bundle-refused", bridge.fixtureHandle(dispatch: a.dispatch, method: "memory_sync_import", params: invalid)["ok"] as? Bool == false)
            roster.edges[roster.edges.count - 1].capabilities = ["files"]; try a.fleet.publish(&roster)
            let denied = try b.dispatch.signed(method: "memory_sync_export", payload: [:], recipient: a.id)
            try check("R3-GATE-02-no-memory-grant-no-export", bridge.fixtureHandle(dispatch: a.dispatch, method: "memory_sync_export", params: denied)["ok"] as? Bool == false)
        case "read-only":
            try a.fleet.setFaction(.init(id: "read-staff", name: "fixture", kind: .managed, managerDisplayName: "fixture"))
            let p = try make(62, false); try pair(a, p, .managed, "read-staff", true)
            var roster = try a.fleet.current()!.roster!
            let staffIndex = roster.devices.firstIndex { $0.id == p.id }!
            roster.devices[staffIndex].name = roster.devices.first { $0.id == a.id }!.name
            var state = try a.fleet.read()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(DeviceFleetPayload(roster: roster))
            let signed = try DeviceSignature.sign(body, namespace: DeviceFleetEnvelope.namespace, environment: a.env)
            state.envelope = .init(body: body, signature: signed.0, publicKey: signed.1)
            try a.fleet.save(state)
            let before = try Data(contentsOf: a.fleet.url)
            _ = try a.fleet.readGraph()
            try check("DM-03-reading-roster-does-not-rename-or-sign", Data(contentsOf: a.fleet.url) == before)
            let proposal = try a.fleet.propose([.renameGroup(id: roster.groups.first { $0.type == .main }!.id, name: "preview MAIN")], actor: a.id)
            let lines = DeviceFlowPreview.lines(before: roster, proposal: proposal)
            let renamed = proposal.preview.devices.first { $0.id == p.id }!
            try check("DM-03-normalized-name-visible-in-confirmation-preview", renamed.name != roster.devices[staffIndex].name
                && lines.contains { $0.contains("設備名稱") && $0.contains(roster.devices[staffIndex].name) && $0.contains(renamed.name) })
            try rejects("DM-03-no-local-confirmation-no-signature", expected: .confirmationRequired) { _ = try a.fleet.confirm(proposal.id, userConfirmed: false) }
            try check("DM-03-preview-and-refusal-never-sign", Data(contentsOf: a.fleet.url) == before)
        case "projection-cache":
            try a.fleet.setFaction(.init(id: "r4-staff", name: "fixture staff", kind: .managed, managerDisplayName: "fixture manager"))
            let p = try make(62, false), q = try make(63, false)
            try pair(a, p, .managed, "r4-staff", true); try pair(a, q, .managed, "r4-staff", true)
            let roster = try a.fleet.current()!.roster!
            var stale = try roster.slice(for: p.id)
            stale.devices = roster.devices.filter { $0.groupID == "r4-staff" }
            var state = try a.fleet.read()
            state.deliveries = [p.id: try DeviceFleetEnvelope.issue(.init(slice: stale), environment: a.env)]
            try a.fleet.save(state)
            _ = try a.fleet.migrateStaffInterconnections(a.fleet.current()!, trust: a.fleet.trust()!)
            let deliveries = try a.fleet.managedDeliveries()
            let projection = try deliveries[p.id]!.verified(trust: p.fleet.trust()!).slice!
            try check("DM-02-old-cached-projection-discarded", projection.devices.filter { $0.id != p.id }.allSatisfy { $0.displayOnly && $0.user.isEmpty && $0.endpoints.isEmpty && $0.clientPublicKey == nil })
        case "secondary":
            let c = try make(62, false)
            try pair(a, c, .owner, nil, false)
            try a.fleet.revoke(c.id); a.dispatch.pushFleetNow(); b.dispatch.synchronize()
            var secondaryEnv = b.env; secondaryEnv["TATWO2_PAIRING_HOST"] = "127.0.0.1"
            let secondaryHost = DevicePairingHost(registry: b.registry, environment: secondaryEnv)
            defer { secondaryHost.cancelPairingWindow() }
            try rejects("REV-05-secondary-restoration-refused-before-mint", expected: .primaryRequired) {
                _ = try secondaryHost.startPairingWindow(restoringDeviceID: c.id)
            }
            try rejects("ROSTER-01-secondary-managed-invitation-refused-before-trust", expected: .primaryRequired) {
                _ = try secondaryHost.startPairingWindow(kind: .managed, factionID: "managed")
            }
        case "pairing":
            let c = try make(62, false)
            try a.fleet.revoke(b.id)
            let server = DevicePairingHost(registry: a.registry, environment: a.env, peerHostResolver: { _ in c.host })
            defer { server.cancelPairingWindow() }
            var loopback = a.env; loopback["TATWO2_PAIRING_HOST"] = "127.0.0.1"
            let boundServer = DevicePairingHost(registry: a.registry, environment: loopback, peerHostResolver: { _ in c.host })
            defer { boundServer.cancelPairingWindow() }
            let window = try boundServer.startPairingWindow(restoringDeviceID: b.id)
            let hostKey = try a.hostKey
            let joiner = DevicePairingClient(registry: c.registry, environment: c.env, sshVerifier: { _, _, _ in true }, hostKeyResolver: { _ in hostKey }, peerEndpoints: { _, row in row.endpoints })
            let revision = try a.fleet.current()!.revision
            try rejects("PAIR-02-restore-code-rejects-other-device") {
                _ = try joiner.pair(host: "127.0.0.1", port: Int(window.listenAddress.split(separator: ":").last!)!, code: window.code, name: "wrong restore target")
            }
            try check("PAIR-02-wrong-device-not-admitted", a.fleet.current()?.revision == revision && a.fleet.current()?.roster?.devices.contains { $0.id == c.id } == false)
            try rejects("REV-05-secondary-cannot-open-restore-window") {
                _ = try DevicePairingHost(registry: b.registry, environment: b.env).startPairingWindow(restoringDeviceID: b.id)
            }
        case "feedback":
            let closed = DispatchSemaphore(value: 0)
            var loopback = a.env; loopback["TATWO2_PAIRING_HOST"] = "127.0.0.1"
            let server = DevicePairingHost(registry: a.registry, environment: loopback, peerHostResolver: { _ in b.host })
            server.onClose = { closed.signal() }
            let window = try server.startPairingWindow()
            defer { server.cancelPairingWindow() }
            let hostKey = try a.hostKey
            let client = DevicePairingClient(registry: b.registry, environment: b.env, sshVerifier: { _, _, _ in true }, hostKeyResolver: { _ in hostKey })
            try rejects("PAIR-N4-owner-preview-refused") {
                _ = try client.pair(host: "127.0.0.1", port: Int(window.listenAddress.split(separator: ":").last!)!, code: window.code, name: "fixture", previewOnly: true)
            }
            try check("PAIR-N4-consumed-preview-closes-host-window", closed.wait(timeout: .now() + 2) == .success)
            try check("PAIR-N4-preview-feedback-is-not-network-error", DevicePairingFeedback.failure("配對失敗：fleet_previewNotAllowed")?.message.contains("受管") == true)
        case "diagnostics":
            for message in ["ssh: Could not resolve hostname example.local: nodename nor servname provided, or not known", "ssh: connect to host 192.0.2.1 port 22: Host is down", "ssh: connect to host 192.0.2.1 port 22: Operation timed out"] {
                try check("XFER-02-unreachable-" + message, DeviceFleetGate.isSSHUnreachable(status: 255, diagnostics: message))
                try check("XFER-02-authenticated-message-still-online", !DeviceFleetGate.isSSHUnreachable(status: 255, diagnostics: "Authenticated to peer\n" + message))
            }
        case "cut":
            let link = RemoteHostLink(environment: a.env)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["120"]
            defer { if process.isRunning { process.terminate() }; link.disconnect() }
            try link.attachFixture(device: a.registry.list().first { $0.id == b.id }!, process: process)
            var roster = try a.fleet.current()!.roster!
            roster.edges.removeAll { ($0.from == .device(a.id) && $0.to == .device(b.id)) || ($0.from == .device(b.id) && $0.to == .device(a.id)) }
            roster.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: .oneway, capabilities: DeviceFleetCapabilities.all))
            try a.fleet.publish(&roster)
            for round in 0..<3 {
                a.dispatch.pushFleetNow(); b.dispatch.synchronize()
                try a.fleet.synchronizeEnvelope(a.fleet.envelope()!)
                try check("CUT-01-outbound-retained-after-sync-\(round)", !link.fixtureRevoked && process.isRunning)
            }
            try check("CUT-01-no-false-possible-connections", a.fleet.read().possiblyConnected?.isEmpty != false)
        default: throw DeviceFleetError.malformed
        }
        print("W187R4 SUMMARY failures=0")
    }
}
#endif
