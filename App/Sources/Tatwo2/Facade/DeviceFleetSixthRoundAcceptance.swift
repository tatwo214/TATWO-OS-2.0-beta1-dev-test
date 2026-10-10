#if DEBUG
import Foundation

enum DeviceFleetSixthRoundAcceptance {
    static func run(scenario: String, make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R6_FAIL_" + name) }
            print("W187R6 PASS " + name)
        }
        if scenario == "memory-endpoints" {
            try DeviceFleetFifthRoundAcceptance.run(scenario: scenario, make: make, pair: pair)
            print("W187R6 SUMMARY failures=0"); return
        }
        let a = try make(80, true), b = try make(81, false)
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b, .owner, nil, false)
        b.dispatch.synchronize()
        switch scenario {
        case "revocation-retry":
            var roster = try a.fleet.current()!.roster!; roster.revoked.append(b.id)
            try a.fleet.publish(&roster)
            let start = Date()
            for i in 0..<8 {
                try check("CARDS-N3-pending-revocation-retries-after-minute-\(i)", a.fleet.claimRevocationDelivery(b.id, now: start.addingTimeInterval(Double(i) * 3600)))
            }
            try check("CARDS-N3-pre-send-no-revocation-warning", a.fleet.read().deliveryProblems?[b.id] == nil)
            try a.fleet.recordDeliveryProblem(b.id, error: DeviceFleetGate.CallError.unreachable)
            let lines = DeviceFleetStore.deliveryWarnings(roster: roster, problems: [:]).values.sorted()
            // The real snapshot, with local pending delivery state, must expose the safety status.
            let snapshot = DeviceFleetUISnapshot(payload: try a.fleet.current(), localID: a.id, deliveryProblems: try a.fleet.read().deliveryProblems ?? [:])
            try check("CARDS-N3-undelivered-revocation-visible", (lines + snapshot.pendingDeliveryLines).contains { $0.contains("還沒收到撤銷") })
            try a.fleet.recordDeliveryProblem(b.id, error: DeviceFleetError.keyConflict)
            let localFailure = DeviceFleetUISnapshot(payload: try a.fleet.current(), localID: a.id, deliveryProblems: try a.fleet.read().deliveryProblems ?? [:])
            try check("CARDS-N3-local-pin-failure-cannot-hide-pending-revocation", localFailure.pendingDeliveryLines.contains { $0.contains("還沒收到撤銷") })
            try a.fleet.finishRevocationDelivery(b.id)
            try check("CARDS-N3-delivery-stops-retries", !a.fleet.claimRevocationDelivery(b.id, now: start.addingTimeInterval(99_999)))
            var restored = roster; restored.revoked.removeAll { $0 == b.id }
            try check("CARDS-N3-restored-row-does-not-show-stale-revocation", DeviceFleetStore.deliveryWarnings(roster: restored, problems: [b.id: "revocation_pending"]).values.sorted().isEmpty)
        case "clock-gate":
            let method = "dispatch_fetch"
            let proof = try b.dispatch.signed(method: method, payload: [:], recipient: a.id)
            var body = try JSONSerialization.jsonObject(with: Data(base64Encoded: proof["body"] as! String)!) as! [String: Any]
            body["issuedAt"] = Date().timeIntervalSince1970 - 121
            let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let signature = try DeviceSignature.sign(bytes, namespace: "tatwo2-rpc", environment: b.env)
            let expired: [String: Any] = ["body": bytes.base64EncodedString(), "signature": signature.0.base64EncodedString(), "publicKey": signature.1]
            let reply = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: a.dispatch, method: method, params: expired)
            try check("CLOCK-01-signed-method-preserves-localized-reason", reply["error"] as? String == "rpc_proof_expired")
            DeviceFleetGate.fixtureExchange = { _, _, _ in (0, "Authenticated to synthetic peer\n", try JSONSerialization.data(withJSONObject: reply)) }
            defer { DeviceFleetGate.fixtureExchange = nil }
            do {
                _ = try DeviceFleetGate.call(peer: b.registry.list().first { $0.id == a.id }!, method: method, params: expired, registry: b.registry)
                throw DeviceFleetError.signature
            } catch {
                try check("CLOCK-01-gate-classifies-clock", error as? DeviceFleetGate.CallError == .clockMismatch)
                try a.fleet.recordDeliveryProblem(b.id, error: error)
            }
            try check("ROSTER-03-clock-action-does-not-request-update", DeviceFleetStore.deliveryWarnings(roster: a.fleet.current()?.roster, problems: a.fleet.read().deliveryProblems ?? [:]).values.sorted().contains { $0.contains("自動設定日期與時間") && !$0.contains("更新") })
        case "secondary-forward":
            let staff = try make(82, false)
            let main = try a.fleet.current()!.roster!.groups.first { $0.type == .main }!.id
            try pair(a, staff, .sandbox, main, true)
            b.dispatch.synchronize()
            let before = try staff.fleet.current()!.revision
            var roster = try a.fleet.current()!.roster!
            for index in roster.edges.indices where roster.edges[index].to == .device(staff.id) { roster.edges[index].capabilities = ["files"] }
            try a.fleet.publish(&roster)
            let unreachablePrimary = DeviceDispatch(entry: a.dispatch.entry, registry: a.registry, environment: a.env,
                rpc: { _, _, _ in throw DeviceFleetGate.CallError.unreachable })
            unreachablePrimary.pushFleetNow()
            try check("CARDS-N2-primary-cannot-deliver-staff-projection", staff.fleet.current()!.revision == before)
            b.dispatch.synchronize()
            try check("CARDS-N2-secondary-relays-primary-signed-narrowing", staff.fleet.current()!.revision > before && staff.fleet.current()!.revision == b.fleet.current()!.revision)
        case "memory-errors":
            try check("MEM-02-App-offline-is-transport", TatwoMemorySyncEngine.isTransport(DeviceFleetGate.CallError.appUnavailable))
            try check("MEM-03-size-action-is-possible", TatwoMemorySyncEngine.short(DeviceFleetGate.CallError.contentTooLarge).contains("受限通道") && !TatwoMemorySyncEngine.short(DeviceFleetGate.CallError.contentTooLarge).contains("分批整理"))
        case "disconnect-targets":
            let before = try a.fleet.current()!.roster!; var after = before
            after.revoked.append(b.id)
            try check("R5-ROSTER-N4-revoked-recipient-excluded-from-broad-disconnect", !DeviceFleetStore.disconnectAllTargets(before: before, after: after).contains(b.id))
        case "restore-old-key", "restore-host-key":
            var roster = try a.fleet.current()!.roster!
            roster.revoked.append(b.id)
            var latest = roster.devices.first { $0.id == b.id }!
            latest.id = UUID().uuidString; latest.name = "synthetic latest"
            if scenario == "restore-old-key" { roster.revoked.append(latest.id) }
            else {
                let c = try make(82, false)
                latest.clientPublicKey = DeviceFleetPublicKey.withoutComment(try c.clientKey)
                latest.clientKeyFingerprint = try DeviceRegistry.fingerprint(publicKey: c.clientKey)
            }
            roster.devices.append(latest)
            try a.fleet.publish(&roster)
            var loopback = a.env; loopback["TATWO2_PAIRING_HOST"] = "127.0.0.1"
            let host = DevicePairingHost(registry: a.registry, environment: loopback)
            defer { host.cancelPairingWindow() }
            do {
                _ = try host.startPairingWindow(restoringDeviceID: b.id)
                host.cancelPairingWindow()
                throw DeviceDispatch.Failure(reason: "W187R6_FAIL_R5-CARDS-05-obsolete-key-created-code")
            } catch let error as DeviceFleetError {
                try check("R5-CARDS-05-obsolete-client-or-host-key-refused-before-code", error == .keyConflict && host.port == nil)
            }
            if scenario == "restore-old-key" {
                _ = try host.startPairingWindow(restoringDeviceID: latest.id)
                try check("R5-CARDS-05-latest-revoked-row-remains-restorable", host.port != nil)
            }
        case "legacy-names", "legacy-prepared":
            let c = try make(82, false)
            try pair(a, c, .owner, nil, false)
            var roster = try a.fleet.current()!.roster!
            let index = roster.devices.firstIndex { $0.id == c.id }!
            let candidate = roster.devices[index]
            roster.devices[index].legacy = true
            roster.devices[index].hostPublicKey = nil; roster.devices[index].hostKeyFingerprint = nil
            try a.fleet.publish(&roster, normalizeNames: false)
            let before = try a.fleet.current()!.roster!
            if scenario == "legacy-prepared" {
                let local = try a.dispatch.identity()
                let record = PrimaryTransferState.Record(from: a.id, to: b.id, oldEpoch: local.epoch!, epoch: local.epoch! + 1,
                    participants: [b.id, c.id].sorted(), sourceDeviceID: a.id, sourceRoot: a.fleet.entry.root.path,
                    hashes: [:], signingName: "synthetic")
                try a.fleet.prepareTransfer(record, confirmation: .forLocalUI(target: b.id, local: local))
                let digest = try a.fleet.rotation()!.handoff.digest
                try a.fleet.upgradeLegacySelf(candidate, sender: c.id)
                try check("CARDS-N4-self-upgrade-defers-during-prepared-transfer", a.fleet.rotation()?.handoff.digest == digest && a.fleet.current()?.revision == before.version)
            } else {
                try a.fleet.setFaction(.init(id: "r6-name-staff", name: "synthetic staff", kind: .managed, managerDisplayName: "synthetic manager"))
                let staff = try make(83, false)
                try pair(a, staff, .managed, "r6-name-staff", true)
                let offered = try a.dispatch.offer(to: c.id)
                let receipt = try c.dispatch.apply(offered, authenticatedPrimary: c.registry.list().first { $0.id == a.id }!)
                // Cached historical signatures allow cross-group duplicate names. No new
                // publication may silently normalize these without a confirmation preview.
                var historical = try a.fleet.current()!.roster!
                historical.devices[historical.devices.firstIndex { $0.id == staff.id }!].name = candidate.name
                let body = try DeviceFleetHandoff.bytes(DeviceFleetPayload(roster: historical))
                let signed = try DeviceSignature.sign(body, namespace: DeviceFleetEnvelope.namespace, environment: a.env)
                var state = try a.fleet.read(); state.envelope = .init(body: body, signature: signed.0, publicKey: signed.1)
                try a.fleet.save(state)
                let proof = try c.dispatch.signed(method: "dispatch_ack", payload: DeviceDispatch.object(receipt), recipient: a.id)
                let response = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: a.dispatch, method: "dispatch_ack", params: proof)
                try check("CARDS-N4-historical-name-ACK-still-converges", response["ok"] as? Bool == true)
                try check("CARDS-N4-self-upgrade-preserves-unconfirmed-names", a.fleet.current()!.roster!.devices.map(\.name) == historical.devices.map(\.name))
            }
        case "legacy-ack":
            let pairedHostPin = a.registry.list().first { $0.id == b.id }!.pinnedHostKeyFingerprint
            var legacy = try a.fleet.current()!.roster!
            let index = legacy.devices.firstIndex { $0.id == b.id }!
            legacy.devices[index].legacy = true
            legacy.devices[index].hostPublicKey = nil // Retain the real pairing fingerprint while metadata is legacy.
            try a.fleet.publish(&legacy)
            let beforePin = try a.fleet.current()!.roster!.devices.first { $0.id == b.id }!.hostPublicKey
            let bundle = try a.dispatch.offer(to: b.id)
            var receipt = try b.dispatch.apply(bundle, authenticatedPrimary: b.registry.list().first { $0.id == a.id }!)
            var forged = receipt.fleetMembers!.first!
            forged.hostPublicKey = try a.hostKey; forged.hostKeyFingerprint = try DeviceRegistry.fingerprint(publicKey: a.hostKey)
            receipt.fleetMembers = [forged]
            let proof = try b.dispatch.signed(method: "dispatch_ack", payload: DeviceDispatch.object(receipt), recipient: a.id)
            let reply = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: a.dispatch, method: "dispatch_ack", params: proof)
            try check("LEGACY-01-failed-self-upgrade-does-not-block-real-ACK", reply["ok"] as? Bool == true && a.dispatch.receipts()[b.id]?.phase == "converged")
            try check("LEGACY-01-pin-unchanged", a.fleet.current()!.roster!.devices.first { $0.id == b.id }!.hostPublicKey == beforePin
                && a.registry.list().first { $0.id == b.id }!.pinnedHostKeyFingerprint == pairedHostPin)
            let hostKey = URL(fileURLWithPath: b.env["TATWO2_SSH_HOST_KEY_PUB"]!)
            guard hostKey.path.hasPrefix(b.fleet.entry.root.deletingLastPathComponent().path + "/") else { throw DeviceFleetError.malformed }
            try FileManager.default.removeItem(at: hostKey) // Only this fixture-generated host public key.
            let next = try b.dispatch.apply(a.dispatch.offer(to: b.id), authenticatedPrimary: b.registry.list().first { $0.id == a.id }!)
            try check("LEGACY-01-unavailable-local-host-key-does-not-block-apply", next.phase == "converged" && next.fleetMembers == nil)
            let ack = try b.dispatch.signed(method: "dispatch_ack", payload: DeviceDispatch.object(next), recipient: a.id)
            try check("LEGACY-01-local-upgrade-failure-still-ACKs", OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: a.dispatch, method: "dispatch_ack", params: ack)["ok"] as? Bool == true)
        default: throw DeviceFleetError.malformed
        }
        print("W187R6 SUMMARY failures=0")
    }
}
#endif
