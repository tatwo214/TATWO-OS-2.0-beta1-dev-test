#if DEBUG
import Foundation

enum W221cACKAcceptance {
    static func run(make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake) throws {
        var checks = 0
        func check(_ label: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W221D_ACK_FAIL_" + label) }
            checks += 1; print("W221D ACK PASS " + label)
        }
        func rejects(_ label: String, reason: String, _ action: () throws -> Void) throws {
            do { try action() } catch {
                try check(label, DeviceFleetReason.code(error) == reason); return
            }
            throw DeviceDispatch.Failure(reason: "W221D_ACK_ACCEPTED_" + label)
        }
        let primary = try make(80, true), legacy = try make(81, false), stranger = try make(82, true)
        var local = try DeviceIdentityStore.forLocalDevice(entry: legacy.dispatch.entry).read()
        local.epoch = 1; local.primaryDeviceID = primary.id
        let hashes = ["os.md": String(repeating: "a", count: 64), "skillet.md": String(repeating: "b", count: 64)]
        local.transfer = .init(from: legacy.id, to: primary.id, oldEpoch: 0, epoch: 1,
            participants: [primary.id], previousTransferID: nil, committed: true, epochACKs: [primary.id],
            sourceDeviceID: legacy.id, sourceRoot: legacy.dispatch.entry.root.path, hashes: hashes,
            signingName: "fixture")
        try DeviceIdentityStore.forLocalDevice(entry: legacy.dispatch.entry).write(local)
        let pin = try DeviceRegistry.fingerprint(publicKey: primary.clientKey)
        _ = try legacy.registry.add(id: primary.id, name: "old unsplit pin", host: primary.host, user: "fixture", publicKeyFingerprint: pin)
        _ = try legacy.registry.authorize(publicKey: primary.clientKey, deviceID: primary.id)
        let receipt = DeviceDispatch.Receipt(seq: 1, phase: "converged", hashes: hashes, updated: Date())
        let payload = try DeviceDispatch.object(receipt)
        func proof(_ signer: DeviceFleetAcceptance.Fake? = nil) throws -> [String: Any] {
            try (signer ?? primary).dispatch.signed(method: "dispatch_ack", payload: payload, recipient: legacy.id)
        }
        // The stored row has no explicit client pin; the registry classifies the old unsplit pin from the marked authorized_keys line.
        let classified = legacy.registry.list().first { $0.id == primary.id }
        try check("legacy-no-fleet-no-explicit-client-pin", legacy.fleet.trust() == nil
            && classified?.clientKeyFingerprint == pin && classified?.clientKeyFingerprintSource?.source == "legacy_authorized_keys")
        let valid = try proof()
        let (sender, verified) = try legacy.dispatch.authenticate(method: "dispatch_ack", proof: valid)
        let decoded = try DeviceDispatch.decode(DeviceDispatch.Receipt.self, verified)
        try check("non-fleet-old-handoff-authenticates", sender == primary.id && decoded.phase == receipt.phase)
        // Authentication does not invent the outstanding offer required by W83's ACK ledger.
        try rejects("old-ack-ledger-still-required", reason: "invalid_or_late_ack") {
            try legacy.dispatch.recordACK(decoded, sender: sender)
        }
        try rejects("non-fleet-replay", reason: "stale_epoch_or_replayed_sequence") {
            _ = try legacy.dispatch.authenticate(method: "dispatch_ack", proof: valid)
        }
        var forged = try proof(); forged["signature"] = Data("forged".utf8).base64EncodedString()
        try rejects("non-fleet-signature", reason: "invalid_ssh_proof") {
            _ = try legacy.dispatch.authenticate(method: "dispatch_ack", proof: forged)
        }
        try rejects("non-fleet-unpinned-sender", reason: "untrusted_rpc_sender") {
            _ = try legacy.dispatch.authenticate(method: "dispatch_ack", proof: proof(stranger))
        }
        var future = try primary.dispatch.identity(); future.epoch = 2
        try DeviceIdentityStore.forLocalDevice(entry: primary.dispatch.entry).write(future)
        try rejects("non-fleet-epoch", reason: "stale_epoch_or_replayed_sequence") {
            _ = try legacy.dispatch.authenticate(method: "dispatch_ack", proof: proof())
        }
        future.epoch = 1
        try DeviceIdentityStore.forLocalDevice(entry: primary.dispatch.entry).write(future)
        let authorized = try Data(contentsOf: legacy.registry.authorizedKeysURL)
        try Data().write(to: legacy.registry.authorizedKeysURL)
        try rejects("non-fleet-revoked-key", reason: "revoked_rpc_key") {
            _ = try legacy.dispatch.authenticate(method: "dispatch_ack", proof: proof())
        }
        try authorized.write(to: legacy.registry.authorizedKeysURL)
        for (claimed, verified) in [("fleet", "converged"), ("converged", "fleet"), ("missing", "converged")] {
            var phaseReceipt = receipt; phaseReceipt.phase = verified
            var changed = try primary.dispatch.signed(method: "dispatch_ack", payload: DeviceDispatch.object(phaseReceipt), recipient: legacy.id)
            var body = try JSONSerialization.jsonObject(with: Data(base64Encoded: changed["body"] as! String)!) as! [String: Any]
            var payload = body["payload"] as! [String: Any]
            payload["phase"] = claimed == "missing" ? nil : claimed
            body["payload"] = payload
            changed["body"] = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).base64EncodedString()
            try rejects(claimed == "missing" ? "missing-claimed-phase" : "phase-mismatch-" + claimed, reason: "invalid_ssh_proof") {
                _ = try legacy.dispatch.authenticate(method: "dispatch_ack", proof: changed)
            }
        }
        try check("rejections-never-adopt-fleet", legacy.fleet.trust() == nil)
        print("W221D ACK SUMMARY checks=\(checks) failures=0")
    }
}
#endif
