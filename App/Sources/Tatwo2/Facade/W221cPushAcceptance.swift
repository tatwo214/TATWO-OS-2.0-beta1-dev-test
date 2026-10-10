#if DEBUG
import Foundation

enum W221cPushAcceptance {
    static func run(make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake) throws {
        var count = 0
        func check(_ label: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W221C_PUSH_FAIL_" + label) }
            count += 1; print("W221C PUSH PASS " + label)
        }
        func rejects(_ label: String, reason: String? = nil, _ action: () throws -> Void) throws {
            do { try action() } catch {
                if let reason { try check(label + "-reason", DeviceFleetReason.code(error) == reason) }
                count += 1; print("W221C PUSH PASS " + label); return
            }
            throw DeviceDispatch.Failure(reason: "W221C_PUSH_ACCEPTED_" + label)
        }
        let mini = try make(60, true), studio = try make(61, false), noPin = try make(62, false), stranger = try make(63, false)
        let clientPin = try DeviceRegistry.fingerprint(publicKey: mini.clientKey)
        let primaryHost = try DeviceRegistry.fingerprint(publicKey: mini.hostKey)
        for target in [studio, noPin] {
            var identity = try DeviceIdentityStore.forLocalDevice(entry: target.dispatch.entry).read()
            identity.epoch = 1; identity.primaryDeviceID = mini.id
            try DeviceIdentityStore.forLocalDevice(entry: target.dispatch.entry).write(identity)
            _ = try target.registry.add(id: mini.id, name: "fixture primary", host: mini.host, user: "fixture",
                publicKeyFingerprint: primaryHost, hostKeyFingerprint: target.id == studio.id ? nil : primaryHost,
                clientKeyFingerprint: target.id == studio.id ? clientPin : nil)
            _ = try target.registry.authorize(publicKey: mini.clientKey, deviceID: mini.id)
            _ = try mini.registry.add(id: target.id, name: "fixture target " + target.id, host: target.host, user: "fixture",
                publicKeyFingerprint: DeviceRegistry.fingerprint(publicKey: target.hostKey),
                hostKeyFingerprint: DeviceRegistry.fingerprint(publicKey: target.hostKey))
            try Data(("\(target.host) \(try DeviceFleetPublicKey.withoutComment(target.hostKey))\n").utf8)
                .write(to: mini.registry.knownHostsURL, options: .atomic)
            // Preserve both target pins when adding the next target.
            try mini.registry.fleetPinHost(.init(id: target.id, name: "fixture", factionID: "owner", role: .secondary, clientKeyFingerprint: nil,
                hostKeyFingerprint: DeviceRegistry.fingerprint(publicKey: target.hostKey), clientPublicKey: nil, hostPublicKey: target.hostKey,
                endpoints: [.init(kind: .lan, host: target.host)], user: "fixture", legacy: true))
        }
        // The authoritative legacy row knows only the target's host, never its client key.
        try mini.fleet.bootstrapPrimary(host: mini.host)
        try check("primary-has-host-only-target", mini.registry.list().first { $0.id == studio.id }?.clientKeyFingerprint == nil
            && mini.registry.fleetPublicKey(deviceID: studio.id) == nil)
        try check("studio-has-only-primary-client-pin", studio.registry.list().first { $0.id == mini.id }?.hostKeyFingerprint == nil)
        let envelope = try mini.fleet.envelope()!
        func receipt(_ envelope: DeviceFleetEnvelope) -> DeviceDispatch.Receipt {
            .init(seq: 0, phase: "fleet", hashes: [:], updated: Date(), fleet: envelope)
        }
        func deliver(_ target: DeviceFleetAcceptance.Fake, _ envelope: DeviceFleetEnvelope,
                     signer: DeviceFleetAcceptance.Fake? = nil, corruptOuter: Bool = false) throws {
            var proof = try (signer ?? mini).dispatch.signed(method: "dispatch_ack",
                payload: DeviceDispatch.object(receipt(envelope)), recipient: target.id)
            if corruptOuter { proof["signature"] = Data("forged".utf8).base64EncodedString() }
            let (sender, payload) = try target.dispatch.authenticate(method: "dispatch_ack", proof: proof)
            try target.dispatch.recordACK(DeviceDispatch.decode(DeviceDispatch.Receipt.self, payload), sender: sender)
        }
        var forged = envelope; forged.signature = Data("forged".utf8)
        try rejects("forged-roster-signature") { try deliver(studio, forged) }
        try rejects("forged-rpc-signature") { try deliver(studio, envelope, corruptOuter: true) }
        var next = try mini.fleet.current()!.roster!; next.epoch = 2
        let wrongEpoch = try DeviceFleetEnvelope.issue(.init(roster: next), environment: mini.env)
        try rejects("wrong-epoch") { try deliver(studio, wrongEpoch) }
        try rejects("wrong-sender") { try deliver(studio, envelope, signer: stranger) }
        try rejects("direct-wrong-sender") { try studio.dispatch.recordACK(receipt(envelope), sender: stranger.id) }
        try rejects("missing-primary-signing-pin", reason: "fleet_legacy_repair_required") { try deliver(noPin, envelope) }
        try check("all-rejections-leave-no-trust", studio.fleet.trust() == nil && noPin.fleet.trust() == nil)
        let oldKnown = try Data(contentsOf: mini.registry.knownHostsURL)
        try Data(("\(studio.host) \(try DeviceFleetPublicKey.withoutComment(stranger.hostKey))\n").utf8).write(to: mini.registry.knownHostsURL)
        mini.dispatch.pushFleetNow()
        try check("primary-refuses-conflicting-target-host-pin", studio.fleet.trust() == nil)
        try oldKnown.write(to: mini.registry.knownHostsURL)
        // Use the real primary push entry, through the fixture's authentication and ACK transport.
        mini.dispatch.pushFleetNow()
        try check("pinned-studio-auto-adopts", studio.fleet.trust()?.pinnedPrimaryKey == clientPin
            && studio.fleet.current()?.roster?.primaryID == mini.id)
        try check("unpinned-studio-still-needs-pairing", noPin.fleet.trust() == nil)
        mini.dispatch.synchronize()
        studio.dispatch.synchronize()
        try check("studio-self-row-upgrades-without-repairing", mini.fleet.current()?.roster?.devices.first { $0.id == studio.id }?.legacy == false
            && studio.fleet.current()?.roster?.devices.first { $0.id == studio.id }?.legacy == false)
        try check("studio-key-now-authorized-on-primary", mini.registry.fleetPublicKey(deviceID: studio.id) != nil)
        print("W221C PUSH SUMMARY checks=\(count) failures=0")
    }
}
#endif
