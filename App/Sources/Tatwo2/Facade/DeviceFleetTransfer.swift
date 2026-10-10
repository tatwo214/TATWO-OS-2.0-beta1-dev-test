import CryptoKit
import Foundation

/// Never decoded from RPC. Created only by DeviceDispatch's existing local UI entry.
struct DeviceFleetLocalTransferConfirmation {
    let target: String
    let primary: String
    let epoch: Int
    fileprivate init(target: String, primary: String, epoch: Int) {
        self.target = target; self.primary = primary; self.epoch = epoch
    }
    static func forLocalUI(target: String, local: DeviceIdentity) throws -> Self {
        guard local.role == .primary, local.primaryDeviceID == local.deviceID, let epoch = local.epoch else {
            throw DeviceFleetError.primaryRequired
        }
        return .init(target: target, primary: local.deviceID, epoch: epoch)
    }
}

/// Immutable old-primary authorization. The new signature also binds this body's digest.
struct DeviceFleetHandoff: Codable, Equatable, Sendable {
    struct Claim: Codable, Equatable, Sendable {
        var id: String
        var from: String
        var to: String
        var oldEpoch: Int
        var epoch: Int
        var version: UInt64
        var oldKey: String
        var newKey: String
        var nextRosterHash: String
        var participants: [String]
        var sourcePages: Int? = nil
    }
    var body: Data
    var signature: Data
    var publicKey: String
    var claim: Claim { get throws { try JSONDecoder().decode(Claim.self, from: body) } }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var digest: String { Self.hash(body) }
    static let namespace = "tatwo2-fleet-handoff"
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    func verified(_ trust: DeviceFleetTrust, revision: UInt64) throws -> Claim {
        guard body.count <= 65536, signature.count < 8192, publicKey.utf8.count <= 2048 else {
            throw DeviceFleetError.malformed
        }
        let c = try claim
        guard UUID(uuidString: c.id) != nil, UUID(uuidString: c.from) != nil,
              c.oldEpoch >= 0, c.oldEpoch == trust.epoch, c.oldEpoch < Int.max, c.epoch == c.oldEpoch + 1,
              c.from == trust.primaryID, c.from != c.to, UUID(uuidString: c.to) != nil,
              c.oldKey == trust.pinnedPrimaryKey, c.version > 0, c.version >= revision, c.version < UInt64.max,
              c.participants.count <= 128, Set(c.participants).count == c.participants.count,
              c.participants.contains(c.to), !c.participants.contains(c.from),
              c.participants.allSatisfy({ UUID(uuidString: $0) != nil }),
              c.nextRosterHash.count == 64, c.nextRosterHash.allSatisfy(\.isHexDigit),
              try DeviceRegistry.fingerprint(publicKey: publicKey) == trust.pinnedPrimaryKey,
              DeviceSignature.verify(body: body, signature: signature, publicKey: publicKey, namespace: Self.namespace) else {
            throw DeviceFleetError.signature
        }
        return c
    }
}

/// Only the incumbent can issue this after ACK. Each certificate binds one exact projection.
struct DeviceFleetRotationCommit: Codable, Equatable, Sendable {
    struct Claim: Codable { var handoffDigest: String; var projectionHash: String; var targetID: String; var committed: Bool }
    var body: Data
    var signature: Data
    static let namespace = "tatwo2-fleet-rotation-commit"
}

struct DeviceFleetRotation: Codable, Sendable {
    var handoff: DeviceFleetHandoff
    var nextRoster: DeviceFleetRoster? // Never sent to SUB / sandbox.
    var baseEnvelope: DeviceFleetEnvelope? = nil
    var envelope: DeviceFleetEnvelope?
    var deliveries: [String: DeviceFleetEnvelope]?
    var identityCommit: PrimaryTransferState.Record?
    var deliveredProjections: [String]? = nil
    var preparedAt: Date? = nil
    var previousIdentityTransfer: PrimaryTransferState.Record? = nil
}

extension DeviceFleetStore {
    /// Serialize the confirmed proposal before W83 preparation; authority changes cancel it before commit.
    func prepareTransfer(_ record: PrimaryTransferState.Record,
                         confirmation: DeviceFleetLocalTransferConfirmation?) throws {
        try Self.lock.withLock {
            guard let trust = try trust() else { return }
            do {
                guard let confirmation, confirmation.target == record.to, confirmation.primary == trust.primaryID,
                      confirmation.epoch == trust.epoch, trust.localID == trust.primaryID else {
                    throw DeviceFleetError.confirmationRequired
                }
                try checkTransfer(from: record.from, to: record.to)
                guard var roster = try current()?.roster,
                      let target = roster.devices.first(where: { $0.id == record.to }), !target.legacy,
                      target.role == .secondary, target.clientPublicKey != nil, target.hostPublicKey != nil,
                      let key = target.clientKeyFingerprint,
                      record.participants.sorted() == roster.devices.filter({
                          roster.kind(of: $0.id) == .owner && $0.id != record.from
                      }).map(\.id).sorted(), roster.version < UInt64.max else { throw DeviceFleetError.role }
                roster.removeStaffInterconnections(); roster.normalizeNames()
                let version = roster.version
                roster.version += 1; roster.epoch = record.epoch; roster.primaryID = record.to
                let main = roster.groups.firstIndex { $0.type == .main }!
                roster.groups[main].primaryDeviceID = record.to
                for index in roster.devices.indices where [record.from, record.to].contains(roster.devices[index].id) {
                    roster.devices[index].role = roster.devices[index].id == record.to ? .primary : .secondary
                }
                try roster.validate()
                let claim = DeviceFleetHandoff.Claim(id: record.id, from: record.from, to: record.to,
                    oldEpoch: record.oldEpoch, epoch: record.epoch, version: version, oldKey: trust.pinnedPrimaryKey,
                    newKey: key, nextRosterHash: DeviceFleetHandoff.hash(try DeviceFleetHandoff.bytes(roster)),
                    participants: record.participants, sourcePages: record.sourcePages)
                let body = try DeviceFleetHandoff.bytes(claim)
                let signed = try DeviceSignature.sign(body, namespace: DeviceFleetHandoff.namespace, environment: environment)
                let handoff = DeviceFleetHandoff(body: body, signature: signed.0, publicKey: signed.1)
                _ = try handoff.verified(trust, revision: version)
                var state = try read()
                state.rotation = .init(handoff: handoff, nextRoster: roster, baseEnvelope: state.envelope, preparedAt: Date(),
                    previousIdentityTransfer: try DeviceIdentityStore.readLocal(entry: entry)?.transfer)
                try save(state)
            } catch { audit(error, fallback: "fleet_prepare_refused"); throw error }
        }
    }
    func rotation() throws -> DeviceFleetRotation? { try Self.lock.withLock { try read().rotation } }

    func validateCommitEnvelope(_ record: PrimaryTransferState.Record, handoff: DeviceFleetHandoff?,
                                envelope: DeviceFleetEnvelope?) throws {
        guard record.committed, let trust = try trust(), trust.epoch == record.oldEpoch else { return }
        guard let handoff, let envelope, envelope.handoff == handoff, let current = try current() else {
            throw DeviceFleetError.signature
        }
        let claim = try handoff.verified(trust, revision: current.revision)
        try verifyRotationCommit(envelope, handoff: handoff, targetID: "MAIN")
        guard claim.id == record.id, claim.to == record.to, claim.participants == record.participants else {
            throw DeviceFleetError.signature
        }
        var next = trust; next.primaryID = claim.to; next.epoch = claim.epoch; next.pinnedPrimaryKey = claim.newKey
        let payload = try envelope.verified(trust: next)
        guard payload.rotationDigest == handoff.digest, payload.revision == claim.version + 1,
              let roster = payload.roster,
              DeviceFleetHandoff.hash(try DeviceFleetHandoff.bytes(roster)) == claim.nextRosterHash else {
            throw DeviceFleetError.signature
        }
    }

    /// A peer may have missed ordinary graph revisions, but not an authority change.
    /// Only the frozen, old-primary-signed base can fill that gap; SUB never receives it.
    func stageTransferBase(_ record: PrimaryTransferState.Record, handoff: DeviceFleetHandoff?,
                           envelope: DeviceFleetEnvelope?) throws {
        try Self.lock.withLock {
            guard let trust = try trust(), trust.epoch == record.oldEpoch else { return }
            guard let handoff, let envelope, let current = try current(), let previous = current.roster else {
                throw DeviceFleetError.signature
            }
            let claim = try handoff.verified(trust, revision: current.revision)
            let base = try envelope.verified(trust: trust)
            guard claim.id == record.id, base.revision == claim.version, let roster = base.roster,
                  roster.kind(of: record.to) == .owner,
                  roster.devices.first(where: { $0.id == record.to })?.legacy == false else {
                throw DeviceFleetError.role
            }
            try roster.validateTransition(from: previous)
            if base.revision > current.revision { try accept(envelope) }
            else if base != current { throw DeviceFleetError.replay }
        }
    }

    /// Receiver validates the old signature, exact frozen graph and W83 participant set before ACK.
    func stageTransfer(_ record: PrimaryTransferState.Record, handoff: DeviceFleetHandoff?,
                       roster: DeviceFleetRoster?) throws {
        try Self.lock.withLock {
            guard let trust = try trust() else { return }
            guard let handoff else { audit("fleet_missing_handoff"); throw DeviceFleetError.signature }
            let bound = try handoff.claim
            guard bound.id == record.id, bound.from == record.from, bound.to == record.to,
                  bound.oldEpoch == record.oldEpoch, bound.epoch == record.epoch,
                  bound.participants == record.participants, (bound.sourcePages == nil || bound.sourcePages == record.sourcePages) else { throw DeviceFleetError.signature }
            if let rotation = try read().rotation, rotation.handoff == handoff,
               trust.epoch == record.epoch || trust.epoch == record.oldEpoch { return }
            guard let previous = try current()?.roster, let roster else { throw DeviceFleetError.signature }
            let claim = try handoff.verified(trust, revision: previous.version)
            try checkTransfer(from: record.from, to: record.to)
            guard claim.id == record.id, claim.from == record.from, claim.to == record.to,
                  claim.oldEpoch == record.oldEpoch, claim.epoch == record.epoch,
                  claim.participants == record.participants, (claim.sourcePages == nil || claim.sourcePages == record.sourcePages),
                  roster.version == claim.version + 1, roster.primaryID == claim.to, roster.epoch == claim.epoch,
                  roster.devices.first(where: { $0.id == claim.to })?.clientKeyFingerprint == claim.newKey,
                  DeviceFleetHandoff.hash(try DeviceFleetHandoff.bytes(roster)) == claim.nextRosterHash else {
                throw DeviceFleetError.signature
            }
            // No hidden membership/key/capability edits may piggyback on a handoff.
            var expected = previous
            expected.removeStaffInterconnections(); expected.normalizeNames()
            expected.version += 1; expected.primaryID = claim.to; expected.epoch = claim.epoch
            expected.groups[expected.groups.firstIndex { $0.type == .main }!].primaryDeviceID = claim.to
            for index in expected.devices.indices where [claim.from, claim.to].contains(expected.devices[index].id) {
                expected.devices[index].role = expected.devices[index].id == claim.to ? .primary : .secondary
            }
            guard expected == roster else { throw DeviceFleetError.signature }
            try roster.validate(); try roster.validateTransition(from: previous)
            var state = try read()
            state.rotation = .init(handoff: handoff, nextRoster: roster)
            try save(state)
        }
    }
    func signPreparedTransfer(_ record: PrimaryTransferState.Record) throws -> DeviceFleetEnvelope? {
        try Self.lock.withLock {
            guard let trust = try trust() else { return nil }
            guard var rotation = try read().rotation, let roster = rotation.nextRoster,
                  try rotation.handoff.claim.to == trust.localID, try rotation.handoff.claim.id == record.id else {
                throw DeviceFleetError.signature
            }
            if let signed = rotation.envelope { return signed }
            func issue(_ payload: DeviceFleetPayload) throws -> DeviceFleetEnvelope {
                var payload = payload; payload.rotationDigest = rotation.handoff.digest
                var result = try DeviceFleetEnvelope.issue(payload, environment: environment)
                result.handoff = rotation.handoff
                return result
            }
            let envelope = try issue(.init(roster: roster))
            var deliveries: [String: DeviceFleetEnvelope] = [:]
            for row in roster.devices where !roster.revoked.contains(row.id) && (row.role == .sandbox || roster.groups.first(where: { $0.id == row.groupID })?.type == .sub) {
                deliveries[row.id] = try issue(.init(slice: roster.slice(for: row.id)))
            }
            rotation.envelope = envelope; rotation.deliveries = deliveries
            var state = try read(); state.rotation = rotation; try save(state)
            return envelope
        }
    }
    func commitTransfer(_ record: PrimaryTransferState.Record, envelope incoming: DeviceFleetEnvelope?,
                        deliveries incomingDeliveries: [String: DeviceFleetEnvelope]? = nil) throws {
        var deliveries = incomingDeliveries
        try Self.lock.withLock {
            guard try trust() != nil else { return }
            guard record.committed, let initial = incoming, let rotation = try read().rotation,
                  initial.handoff == rotation.handoff,
                  try rotation.handoff.claim.id == record.id else {
                audit("fleet_new_primary_signature_missing"); throw DeviceFleetError.signature
            }
            var envelope = initial
            if try trust()?.epoch == record.oldEpoch {
                if try trust()?.localID == record.from {
                    guard let current = try current()?.roster, !current.revoked.contains(record.to),
                          let rotation = try read().rotation, let nextRoster = rotation.nextRoster else { throw DeviceFleetError.role }
                    // Revalidate every new-primary-signed body before certifying its digest.
                    var next = try trust()!; next.primaryID = record.to; next.epoch = record.epoch
                    next.pinnedPrimaryKey = try rotation.handoff.claim.newKey
                    guard try envelope.verified(trust: next).roster == nextRoster else { throw DeviceFleetError.signature }
                    for (id, delivery) in deliveries ?? [:] {
                        var slicedTrust = next; slicedTrust.localID = id
                        slicedTrust.kind = nextRoster.kind(of: id) ?? .sandbox
                        guard try delivery.verified(trust: slicedTrust).slice == nextRoster.slice(for: id) else { throw DeviceFleetError.signature }
                    }
                    envelope = try certifyRotation(envelope, targetID: "MAIN")
                    if let supplied = deliveries {
                        deliveries = try supplied.mapValues { delivery in
                            let target = try JSONDecoder().decode(DeviceFleetPayload.self, from: delivery.body).slice!.targetID
                            return try certifyRotation(delivery, targetID: target)
                        }
                    }
                }
                try acceptRotation(envelope, record: record, deliveries: deliveries)
            } else {
                guard try read().rotation?.handoff == envelope.handoff,
                      try trust()?.primaryID == record.to, try trust()?.epoch == record.epoch else { throw DeviceFleetError.epoch }
                // Do not rewind a valid B-signed roster while W83 metadata continues.
                var state = try read(); state.rotation?.identityCommit = record; try save(state)
                try recoverAuthority()
            }
        }
    }
    func acceptRotation(_ envelope: DeviceFleetEnvelope, record: PrimaryTransferState.Record? = nil,
                        deliveries: [String: DeviceFleetEnvelope]? = nil) throws {
        var state = try read()
        guard let old = state.trust, let handoff = envelope.handoff, let current = try current() else {
            throw DeviceFleetError.signature
        }
        let claim = try handoff.verified(old, revision: current.revision)
        try verifyRotationCommit(envelope, handoff: handoff, targetID: old.kind == .owner ? "MAIN" : old.localID)
        var trust = old; trust.primaryID = claim.to; trust.epoch = claim.epoch; trust.pinnedPrimaryKey = claim.newKey
        let payload = try envelope.verified(trust: trust)
        guard payload.rotationDigest == handoff.digest, payload.revision == claim.version + 1 else {
            throw DeviceFleetError.signature
        }
        if let roster = payload.roster {
            guard DeviceFleetHandoff.hash(try DeviceFleetHandoff.bytes(roster)) == claim.nextRosterHash,
                  let previous = current.roster, previous.kind(of: claim.to) == .owner,
                  previous.devices.first(where: { $0.id == claim.to })?.legacy == false else { throw DeviceFleetError.role }
            try roster.validateTransition(from: previous)
            if record != nil {
                let required = Set(roster.devices.filter { row in
                    !roster.revoked.contains(row.id) && (row.role == .sandbox || roster.groups.first(where: { $0.id == row.groupID })?.type == .sub)
                }.map(\.id))
                guard Set((deliveries ?? [:]).keys) == required else { throw DeviceFleetError.signature }
            }
        }
        var rotation = state.rotation.flatMap { $0.handoff == handoff ? $0 : nil } ?? .init(handoff: handoff)
        rotation.envelope = envelope; rotation.deliveries = deliveries
        rotation.identityCommit = record
        if let deliveries {
            for (id, delivery) in deliveries {
                guard let roster = payload.roster, let row = roster.devices.first(where: { $0.id == id }),
                      roster.kind(of: id) != .owner, delivery.handoff == handoff else { throw DeviceFleetError.role }
                let sliced = try delivery.verified(trust: .init(localID: id, primaryID: claim.to,
                    epoch: claim.epoch, pinnedPrimaryKey: claim.newKey, kind: row.role == .sandbox ? .sandbox : .managed))
                guard sliced.rotationDigest == handoff.digest, sliced.slice == (try roster.slice(for: id)) else {
                    throw DeviceFleetError.signature
                }
            }
        }
        state.rotation = rotation; state.trust = trust; state.envelope = envelope
        state.deliveries = deliveries; state.confirmations = []
        // The signed roster + new pin are the atomic authority journal. Identity is its replayable projection.
        try save(state); try recoverAuthority(); try reconcile(payload)
    }
    func recoverAuthority() throws {
        try Self.lock.withLock {
            let state = try read()
            guard let trust = state.trust, let rotation = state.rotation, let signed = state.envelope,
                  let claim = try? rotation.handoff.claim, trust.epoch == claim.epoch,
                  trust.primaryID == claim.to else { return }
            _ = try signed.verified(trust: trust)
            guard var local = try DeviceIdentityStore.readLocal(entry: entry), local.deviceID == trust.localID,
                  local.epoch == claim.oldEpoch || local.epoch == claim.epoch else { throw DeviceFleetError.epoch }
            if local.epoch != trust.epoch || local.primaryDeviceID != trust.primaryID ||
                (rotation.identityCommit != nil && local.transfer != rotation.identityCommit) {
                local.epoch = trust.epoch; local.primaryDeviceID = trust.primaryID
                local.role = trust.localID == trust.primaryID ? .primary : .secondary
                if let record = rotation.identityCommit { local.transfer = record }
                local.updatedAt = Date()
                try DeviceIdentityStore.forLocalDevice(entry: entry, pairedDeviceID: local.deviceID).write(local)
            }
            if rotation.identityCommit != nil {
                var cleared = state; cleared.rotation?.identityCommit = nil; try save(cleared)
            }
        }
    }
    func allowsRotationTransport(content: [String: Any], fingerprint: String, epoch: Int) throws -> Bool {
        guard let value = content["fleet"] as? [String: Any], let trust = try trust(),
              let current = try current() else { return false }
        let envelope = try JSONDecoder().decode(DeviceFleetEnvelope.self, from: JSONSerialization.data(withJSONObject: value))
        let prefix: [DeviceFleetEnvelope]
        if let raw = content["fleetChain"] {
            guard let list = raw as? [[String: Any]], list.count <= 16 else { return false }
            prefix = try list.map { try JSONDecoder().decode(DeviceFleetEnvelope.self, from: JSONSerialization.data(withJSONObject: $0)) }
        } else { prefix = [] }
        var pin = trust, revision = current.revision
        for proof in prefix + [envelope] {
            let proposedEpoch = try JSONDecoder().decode(DeviceFleetPayload.self, from: proof.body).epoch
            if proposedEpoch < pin.epoch { continue } // Discard already-applied historical metadata; never apply it.
            if proposedEpoch == pin.epoch {
                let payload = try proof.verified(trust: pin)
                guard payload.revision >= revision else { continue }
                revision = payload.revision; continue
            }
            guard let handoff = proof.handoff else { return false }
            let claim = try handoff.verified(pin, revision: revision)
            try verifyRotationCommit(proof, handoff: handoff, targetID: trust.kind == .owner ? "MAIN" : trust.localID)
            var next = pin; next.primaryID = claim.to; next.epoch = claim.epoch; next.pinnedPrimaryKey = claim.newKey
            let payload = try proof.verified(trust: next)
            guard payload.rotationDigest == handoff.digest, payload.revision == claim.version + 1 else { return false }
            pin = next; revision = payload.revision
        }
        let forwarding = try registry.fleetHasAuthorizedFingerprint(fingerprint)
            && methodAllowed(fingerprint: fingerprint, method: "dispatch_ack")
        return pin.epoch > trust.epoch && epoch == pin.epoch && (fingerprint == pin.pinnedPrimaryKey || forwarding)
    }

    func pendingRotationDeliveries(for id: String) throws -> [DeviceFleetEnvelope] {
        let state = try read()
        let delivered = Set(state.deliveredHistory?[id] ?? [])
        var entries = (try current()?.roster?.rotationHistory?[id] ?? []).filter {
            !delivered.contains(DeviceFleetHandoff.hash($0.body))
        }
        if let rotation = state.rotation, !(rotation.deliveredProjections ?? []).contains(id),
           try state.trust?.epoch == rotation.handoff.claim.epoch, let envelope = rotation.deliveries?[id],
           !entries.contains(envelope) { entries.append(envelope) }
        return entries
    }
    func pendingRotationDelivery(for id: String) throws -> DeviceFleetEnvelope? {
        try pendingRotationDeliveries(for: id).first
    }
    func recordRotationHistoryDelivered(_ id: String) throws {
        try Self.lock.withLock {
            var state = try read()
            var rows = state.deliveredHistory ?? [:]
            rows[id] = (try current()?.roster?.rotationHistory?[id] ?? []).map { DeviceFleetHandoff.hash($0.body) }
            state.deliveredHistory = rows
            state.pendingRepin?.removeAll { $0 == id }
            try save(state); try recordRotationDelivery(id)
        }
    }
    func recordRotationDelivery(_ id: String) throws {
        try Self.lock.withLock {
            var state = try read()
            guard state.rotation?.deliveries?[id] != nil else { return }
            var delivered = state.rotation?.deliveredProjections ?? []
            if !delivered.contains(id) { delivered.append(id) }
            state.rotation?.deliveredProjections = delivered; try save(state)
        }
    }
    func markPendingRepin(_ id: String) throws {
        try Self.lock.withLock {
            var state = try read(); state.pendingRepin = Array(Set((state.pendingRepin ?? []) + [id])); try save(state)
        }
    }
    func requirePreviousRotationDelivered() throws {
        try Self.lock.withLock {
            guard let rotation = try rotation(), let trust = try trust(),
                  try trust.localID == rotation.handoff.claim.to, try trust.epoch == rotation.handoff.claim.epoch,
                  var roster = try current()?.roster else { return }
            var history = roster.rotationHistory ?? [:]
            var changed = false
            for (id, proof) in rotation.deliveries ?? [:] where !(rotation.deliveredProjections ?? []).contains(id)
                && !roster.revoked.contains(id) {
                try markPendingRepin(id)
                var entries = history[id] ?? []
                if !entries.contains(proof) { entries.append(proof); changed = true }
                // Bounded retention must never stop another handoff. A longer absence requires fresh pairing.
                history[id] = Array(entries.suffix(16))
            }
            // MAIN observers skipped while offline need the same immutable authority history.
            if let proof = rotation.envelope, let transfer = try DeviceIdentityStore.readLocal(entry: entry)?.transfer,
               try transfer.id == rotation.handoff.claim.id {
                for id in transfer.skippedParticipants ?? [] where roster.kind(of: id) == .owner && !roster.revoked.contains(id) {
                    var entries = history[id] ?? []
                    if !entries.contains(proof) { entries.append(proof); changed = true }
                    history[id] = Array(entries.suffix(16))
                }
            }
            history = history.filter { id, _ in !roster.revoked.contains(id) }
            while (try JSONEncoder().encode(history)).count > 512 * 1024 {
                guard let id = history.keys.sorted().first else { break }
                history.removeValue(forKey: id); changed = true; try markPendingRepin(id)
            }
            if changed { roster.rotationHistory = history; try publish(&roster) }
        }
    }
    func cancelUncommittedRotationForRosterChange() throws {
        guard let rotation = try read().rotation, let trust = try trust(),
              try trust.epoch == rotation.handoff.claim.oldEpoch else { return }
        var state = try read(); state.rotation = nil; try save(state)
        if var local = try DeviceIdentityStore.readLocal(entry: entry), local.transfer?.committed == false {
            local.transfer = rotation.previousIdentityTransfer; local.updatedAt = Date()
            try DeviceIdentityStore.forLocalDevice(entry: entry, pairedDeviceID: local.deviceID).write(local)
        }
        audit("fleet_transfer_cancelled_for_authority_change")
    }
    func expirePreparedTransfer(now: Date = Date()) throws {
        try Self.lock.withLock {
            guard let rotation = try read().rotation, let prepared = rotation.preparedAt,
                  now.timeIntervalSince(prepared) >= 120 else { return }
            try cancelUncommittedRotationForRosterChange()
        }
    }
    private func certifyRotation(_ incoming: DeviceFleetEnvelope, targetID: String) throws -> DeviceFleetEnvelope {
        guard let handoff = incoming.handoff, try trust()?.localID == handoff.claim.from else { throw DeviceFleetError.primaryRequired }
        // projectionHashes are certified separately so SUB never sees the other targets.
        let projectionHashes = DeviceFleetHandoff.hash(incoming.body)
        let claim = DeviceFleetRotationCommit.Claim(handoffDigest: handoff.digest, projectionHash: projectionHashes,
            targetID: targetID, committed: true)
        let body = try DeviceFleetHandoff.bytes(claim)
        let signed = try DeviceSignature.sign(body, namespace: DeviceFleetRotationCommit.namespace, environment: environment)
        var result = incoming; result.rotationCommit = .init(body: body, signature: signed.0); return result
    }
    func verifyRotationCommit(_ envelope: DeviceFleetEnvelope, handoff: DeviceFleetHandoff, targetID: String) throws {
        guard let proof = envelope.rotationCommit, proof.body.count <= 4096, proof.signature.count < 8192,
              DeviceSignature.verify(body: proof.body, signature: proof.signature, publicKey: handoff.publicKey,
                  namespace: DeviceFleetRotationCommit.namespace) else { throw DeviceFleetError.signature }
        let claim = try JSONDecoder().decode(DeviceFleetRotationCommit.Claim.self, from: proof.body)
        guard claim.committed, claim.handoffDigest == handoff.digest, claim.targetID == targetID,
              claim.projectionHash == DeviceFleetHandoff.hash(envelope.body) else { throw DeviceFleetError.signature }
    }
    func cancelRotation(_ record: PrimaryTransferState.Record) throws {
        try Self.lock.withLock {
            guard try trust() != nil else { return }
            guard try trust()?.epoch == record.oldEpoch else { throw DeviceFleetError.epoch }
            var state = try read(); state.rotation = nil; try save(state)
        }
    }
}
