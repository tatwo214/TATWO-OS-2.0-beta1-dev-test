import Foundation

/// A resumable handoff over W78's pinned pull + signed ACK channel.
/// Each endpoint writes only its own identity. No database or private key is moved.
enum PrimaryTransfer {
    typealias Brain = PrimaryTransferState.Brain
    typealias Release = PrimaryTransferState.Release
    typealias Evidence = PrimaryTransferState.Evidence
    typealias Record = PrimaryTransferState.Record
    typealias ACK = PrimaryTransferState.ACK

    static let coordinatorStillOnline = "舊主設備又上線了；等它同步到接管證明後再重試。舊主若是舊版 App，請先更新。"
    static let coordinatorAbsenceUnproven = "找不到舊主設備的連線紀錄，無法確認它已離線；請在私訊框請 TATWO 助理檢查連線。"
    static let migrationSteps = [
        "1. 在舊主設備停止資料寫入，依目前資料庫後端匯出並保留備份；不要將含密碼連線字串放進移交記錄。",
        "2. 在新主設備依同一後端的匯入流程操作；本精靈不執行匯出、匯入或搬動正式資料。",
        "3. 啟動新服務，檢查健康與兩端頁數一致，再選「已遷移」並驗證；頁數一致不等同逐頁內容驗證。",
        "保留舊服務時，須先手動確認新主設備仍能連到舊服務；不會自動建立第二個資料庫。"
    ]

    static func fail(_ reason: String) -> DeviceDispatch.Failure { .init(reason: reason) }

    static func sameCheckpoint(_ before: (DeviceIdentity, DeviceRecord?), _ after: (DeviceIdentity, DeviceRecord?)) -> Bool {
        before.0.deviceID == after.0.deviceID && before.0.role == after.0.role
            && before.0.primaryDeviceID == after.0.primaryDeviceID && before.0.epoch == after.0.epoch
            && sameTransferCheckpoint(before.0.transfer, after.0.transfer)
            && before.1?.id == after.1?.id && before.1?.user == after.1?.user
            && before.1?.pinnedClientKeyFingerprint == after.1?.pinnedClientKeyFingerprint
            && before.1?.pinnedHostKeyFingerprint == after.1?.pinnedHostKeyFingerprint
    }

    /// ACK evidence freshness, revision and readback progress are rechecked under the lock,
    /// but do not change the meaning of the action the user confirmed.
    static func sameTransferCheckpoint(_ a: Record?, _ b: Record?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.id == b.id && a.from == b.from && a.to == b.to
            && a.oldEpoch == b.oldEpoch && a.epoch == b.epoch && a.participants == b.participants
            && a.previousTransferID == b.previousTransferID && a.committed == b.committed
            && a.epochComplete == b.epochComplete && a.constitution == b.constitution
            && a.localVerification == b.localVerification && a.constitutionRevision == b.constitutionRevision && a.sourceDeviceID == b.sourceDeviceID
            && a.sourceRoot == b.sourceRoot && a.hashes == b.hashes && a.sourcePages == b.sourcePages && a.targetRoot == b.targetRoot
            && a.brain == b.brain && a.brainVerified == b.brainVerified && a.brainRevision == b.brainRevision
            && a.release == b.release && a.releaseChecked == b.releaseChecked && a.releaseRevision == b.releaseRevision
            && a.signingName == b.signingName && a.missingDependencies == b.missingDependencies
    }
    static func retryCheckpoint(_ action: () throws -> Void) throws {
        do { try action() }
        catch let error as DeviceDispatch.Failure where error.reason == "transfer_checkpoint_changed_retry" {
            do { try action() }
            catch let retry as DeviceDispatch.Failure where retry.reason == "transfer_checkpoint_changed_retry" {
                throw fail("移交階段在檢查期間變更了；已重新檢查一次，請重新按這個步驟。")
            }
        }
    }
    static func canResolveParticipants(_ dispatch: DeviceDispatch, _ local: DeviceIdentity, _ record: Record) -> Bool {
        guard (try? dispatch.coordinatorRetired(record)) == false else { return false }
        return record.from == local.deviceID || (record.to == local.deviceID && local.role == .primary
            && local.primaryDeviceID == local.deviceID && local.epoch == record.epoch
            && (try? dispatch.hasRecoveredDispatchSource()) == true)
    }

    static func save(_ record: Record, dispatch: DeviceDispatch, commit: Bool = false) throws {
        try dispatch.fleet.requireTransferReady()
        var local = try dispatch.identity()
        if commit {
            if try dispatch.fleet.trust() != nil {
                let rotation = try dispatch.fleet.rotation()
                try dispatch.fleet.commitTransfer(record, envelope: rotation?.envelope, deliveries: rotation?.deliveries)
                local = try dispatch.identity()
            }
            guard local.epoch == record.oldEpoch || local.epoch == record.epoch else {
                throw fail("transfer_stale_epoch")
            }
            local.epoch = record.epoch
            local.primaryDeviceID = record.to
            local.role = local.deviceID == record.to ? .primary : .secondary
        }
        local.transfer = record; local.updatedAt = Date()
        let store = try DeviceIdentityStore.forLocalDevice(entry: dispatch.entry,
                                                          pairedDeviceID: local.deviceID)
        try store.write(local)
        if commit {
            // Keep the existing registry's role projection in sync; never replace
            // keys, endpoints, local resources, or pairing identities.
            let roster = try dispatch.fleet.current()?.roster
            for var peer in dispatch.registry.list() {
                if let roster, roster.kind(of: peer.id) != .owner { continue }
                peer.role = peer.id == record.to ? .primary : .secondary
                peer.epoch = record.epoch
                _ = try dispatch.registry.add(peer)
            }
        }
    }

    static func canBegin(_ local: DeviceIdentity) -> Bool {
        guard let record = local.transfer, !record.complete else { return true }
        return record.from != local.deviceID && (record.to != local.deviceID || record.epochComplete)
    }

    /// Must run on the current primary. An offline peer cannot manufacture a handoff.
    static func begin(_ dispatch: DeviceDispatch, to target: String, signingName: String,
                      confirmation: DeviceFleetLocalTransferConfirmation? = nil) throws {
        func checkpoint() throws -> (DeviceIdentity, DeviceRecord) {
            let local = try dispatch.identity()
            try dispatch.fleet.requireOwner()
            try dispatch.fleet.checkTransfer(from: local.deviceID, to: target)
            try dispatch.fleet.requirePreviousRotationDelivered()
            if try dispatch.fleet.trust() != nil, confirmation == nil {
                dispatch.fleet.audit("fleet_transfer_confirmation_required")
                throw DeviceFleetError.confirmationRequired
            }
            guard local.role == .primary, local.primaryDeviceID == local.deviceID else {
                throw fail("現任主設備須在線才能移交")
            }
            guard !signingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("請填寫與現任主設備相同的簽章身分名稱，再確認移交。") }
            guard canBegin(local) else {
                throw fail(local.transfer?.to == local.deviceID ? "先完成①所有設備的讀回，才能再移交。" : "transfer_in_progress_retry_existing")
            }
            guard let peer = dispatch.registry.list().first(where: { $0.id == target }), target != local.deviceID,
                  let epoch = local.epoch, epoch < Int.max else { throw fail("invalid_transfer_target") }
            return (local, peer)
        }
        let captured = try dispatch.withStateLock { try checkpoint() }
        let peer = captured.1, epoch = captured.0.epoch!
        let remote = try dispatch.transferPresence(peer)
        guard remote.deviceID == target, remote.role == .secondary,
              remote.epoch == epoch, remote.primaryDeviceID == captured.0.deviceID else {
            throw fail("target_authority_mismatch")
        }
        let source = dispatch.transferEvidence()
        guard source.brainHealthy else { throw fail("舊主設備的 GBrain 不健康，請恢復服務後再開始移交。") }
        guard let pages = source.pages, pages >= 0 else { throw fail("讀不到舊主設備的 GBrain 頁數，請確認服務正常回報頁數後再開始移交。") }
        try dispatch.withStateLock {
            let current = try checkpoint()
            guard sameCheckpoint(captured, current) else { throw fail("transfer_checkpoint_changed_retry") }
            let local = current.0
            let record = Record(from: local.deviceID, to: target, oldEpoch: epoch, epoch: epoch + 1,
                                participants: try dispatch.fleet.current()?.roster.map { roster in
                                    roster.devices.filter { roster.kind(of: $0.id) == .owner && $0.id != local.deviceID }.map(\.id).sorted()
                                } ?? dispatch.registry.list().map(\.id).sorted(),
                                previousTransferID: local.transfer?.id,
                                sourceDeviceID: local.deviceID, sourceRoot: dispatch.entry.root.path,
                                hashes: try dispatch.transferHashes(),
                                sourcePages: pages,
                                signingName: signingName.trimmingCharacters(in: .whitespacesAndNewlines))
            try dispatch.fleet.prepareTransfer(record, confirmation: confirmation)
            do { try save(record, dispatch: dispatch) }
            catch {
                try dispatch.fleet.cancelRotation(record)
                throw error
            }
        }
        dispatch.align()
    }

    /// Only the active coordinator can confirm skipping proven missing readbacks.
    /// Participants remain immutable in the dual-signed handoff; skipped IDs are explicit checkpoint metadata.
    /// Probe only through pinned, authenticated status RPC. A remote denial proves reachability; it is not absence.
    static func failedContact(_ error: Error) -> Bool {
        if (error as? DeviceFleetGate.CallError) == .unreachable { return true }
        #if DEBUG
        if (error as? DeviceDispatch.Failure)?.reason == "fixture_offline" { return true }
        #endif
        return false
    }
    static func probePendingParticipants(_ dispatch: DeviceDispatch, now: Date = Date()) throws {
        let local = try dispatch.identity()
        guard var record = local.transfer, record.committed, !record.epochComplete,
              canResolveParticipants(dispatch, local, record) else { return }
        // Old checkpoints start their grace period when first read, never at distantPast.
        if record.committedAt == nil { record.committedAt = now; try save(record, dispatch: dispatch) }
        for id in record.participants where id != record.to && !record.epochACKs.contains(id) {
            guard let peer = dispatch.registry.list().first(where: { $0.id == id }) else { continue }
            do {
                _ = try dispatch.transferPresence(peer)
                try dispatch.fleet.noteTransferContact(transfer: record.id, peer: id, reached: true, now: now)
            } catch {
                if failedContact(error) { try dispatch.fleet.noteTransferContact(transfer: record.id, peer: id, reached: false, now: now) }
                else { try dispatch.fleet.noteTransferContact(transfer: record.id, peer: id, reached: true, now: now) }
            }
        }
    }
    static func absentParticipants(_ dispatch: DeviceDispatch, now: Date = Date()) throws -> [String] {
        let local = try dispatch.identity()
        guard let record = local.transfer, record.committed, !record.epochComplete, canResolveParticipants(dispatch, local, record),
              let committedAt = record.committedAt else { return [] }
        let contacts = try dispatch.fleet.read().transferContacts ?? [:]
        let revoked = Set(try dispatch.fleet.current()?.roster?.revoked ?? [])
        return record.participants.filter { id in
            guard id != record.to, !record.epochACKs.contains(id) else { return false }
            if revoked.contains(id) { return true }
            guard now.timeIntervalSince(committedAt) >= 120, let contact = contacts[record.id + ":" + id], contact.failures >= 2,
                  let first = contact.firstFailure, let last = contact.lastFailure,
                  first >= committedAt, last.timeIntervalSince(first) >= 120,
                  now.timeIntervalSince(last) >= 0, now.timeIntervalSince(last) <= 30,
                  contact.lastSuccess.map({ $0 < first }) ?? true else { return false }
            return true
        }
    }
    static func skipAbsentParticipants(_ dispatch: DeviceDispatch, now: Date = Date(), includeOffline: Bool = false) throws {
        try dispatch.fleet.requireOwner()
        let local = try dispatch.identity()
        guard var record = local.transfer, record.committed, canResolveParticipants(dispatch, local, record) else { throw fail("這台尚不能處理移交參與者，請到目前負責協調的主設備操作。") }
        guard includeOffline else { return }
        if record.to == local.deviceID {
            // Recovery is physically authorized, but renewed contact with the old
            // coordinator must not permit two writers for the same checkpoint.
            let revoked = try dispatch.fleet.current()?.roster?.revoked.contains(record.from) == true
            if !revoked {
                guard let former = dispatch.registry.list().first(where: { $0.id == record.from }) else { throw fail(PrimaryTransfer.coordinatorAbsenceUnproven) }
                do {
                    let live = try dispatch.transferPresence(former)
                    // An online former primary is safe only after it has durably
                    // accepted the signed recovery proof and retired as coordinator.
                    guard live.deviceID == record.from, live.role == .secondary,
                          live.epoch == record.epoch, live.primaryDeviceID == record.to,
                          live.transferID == record.id, live.coordinatorRetired == true else {
                        throw fail(PrimaryTransfer.coordinatorStillOnline)
                    }
                }
                catch { guard failedContact(error) else { if let failure = error as? DeviceDispatch.Failure, !failure.reason.allSatisfy(\.isASCII) { throw failure }; throw DeviceFleetReason.ProbedError(error: error, record: record, probed: .source) } }
            }
        } else {
            guard let target = dispatch.registry.list().first(where: { $0.id == record.to }) else { throw fail("找不到新主設備的連線紀錄，請先在設備卡檢查連線。") }
            let live = try dispatch.transferPresence(target)
            guard live.deviceID == record.to, live.role == .primary, live.epoch == record.epoch,
                  live.transferID == record.id else { throw fail("找不到新主設備的連線紀錄，請先在設備卡檢查連線。") }
            guard live.sourceRecovered != true else { throw fail("新主設備已接管協調工作；請到新主設備繼續驗收。") }
        }
        try probePendingParticipants(dispatch, now: now)
        try dispatch.withStateLock {
            try dispatch.fleet.requireOwner()
            let current = try dispatch.identity()
            guard current.deviceID == local.deviceID, current.epoch == local.epoch,
                  current.primaryDeviceID == local.primaryDeviceID,
                  let latest = current.transfer, latest.id == record.id,
                  latest.from == record.from, latest.to == record.to, latest.epoch == record.epoch,
                  latest.participants == record.participants, latest.committed,
                  canResolveParticipants(dispatch, current, latest) else { throw fail("移交對象或設備名單已改變，請重新確認略過步驟。") }
            record = latest
            let revoked = Set(try dispatch.fleet.current()?.roster?.revoked ?? [])
            guard let committedAt = record.committedAt,
                  now.timeIntervalSince(committedAt) >= 120 || record.participants.contains(where: { $0 != record.to && revoked.contains($0) }) else {
                throw fail("transfer_participant_timeout_pending")
            }
            let skip = try absentParticipants(dispatch, now: now)
            guard !skip.isEmpty else { return }
            record.skippedParticipants = Array(Set((record.skippedParticipants ?? []) + skip)).sorted()
            record.revision += 1
            try save(record, dispatch: dispatch)
            dispatch.fleet.audit("fleet_transfer_absent_participants_skipped")
        }
    }

    /// The former primary only retains authority to finish this exact recorded
    /// handoff. It cannot issue another epoch, alter the destination, or take over.
    static func update(_ dispatch: DeviceDispatch, constitution: Bool = false,
                       brain: Brain? = nil, release: Bool = false, signingName: String? = nil,
                       expectedTransfer: Record? = nil) throws {
        if constitution, brain == nil, !release, signingName == nil, try dispatch.identity().transfer?.constitution == true { return }
        func checkpoint() throws -> (DeviceIdentity, DeviceRecord?) {
            try dispatch.fleet.requireOwner()
            let local = try dispatch.identity()
            guard let record = local.transfer, record.epochComplete,
                  try !dispatch.coordinatorRetired(record),
                  try (record.from == local.deviceID || dispatch.hasRecoveredDispatchSource()) else {
                throw fail("請先完成①主權版本的設備讀回，再繼續③④驗收。")
            }
            if let expectedTransfer {
                guard record.id == expectedTransfer.id, record.from == expectedTransfer.from,
                      record.to == expectedTransfer.to, record.epoch == expectedTransfer.epoch,
                      record.oldEpoch == expectedTransfer.oldEpoch, record.participants == expectedTransfer.participants else {
                    throw fail("移交對象或設備名單已改變，請重新確認這個步驟。")
                }
            }
            let peer = record.from == local.deviceID ? dispatch.registry.list().first(where: { $0.id == record.to }) : nil
            if record.from == local.deviceID && peer == nil { throw fail("找不到新主設備的連線紀錄，請先在設備卡檢查連線。") }
            return (local, peer)
        }
        let captured = try dispatch.withStateLock { try checkpoint() }
        if let peer = captured.1 {
            let probedRecord = captured.0.transfer!
            let remote = try dispatch.transferPresence(peer)
            guard remote.deviceID == peer.id, remote.role == .primary, remote.epoch == probedRecord.epoch,
                  remote.transferID == probedRecord.id else { throw fail("現任主設備須在線才能移交") }
        }
        if constitution {
            try dispatch.withStateLock { try checkFrozen(dispatch, record: captured.0.transfer!) }
            if let peer = captured.1 { try dispatch.refreshTransferWork(peer) }
        }
        let source = dispatch.transferEvidence()
        try dispatch.withStateLock {
            let current = try checkpoint()
            guard sameCheckpoint(captured, current) else { throw fail("transfer_checkpoint_changed_retry") }
            var record = current.0.transfer!
            guard let evidence = current.1 == nil ? source : record.targetEvidence, Date().timeIntervalSince(evidence.acquiredAt) <= 60,
                  Date().timeIntervalSince(evidence.acquiredAt) >= -5 else { throw fail("新主設備的讀回已過期；請先重新同步，再重試這個步驟。") }
            if constitution {
                if let peer = current.1, try !dispatch.transferWorkMatches(peer) { throw fail("transfer_checkpoint_changed_retry") }
                try checkFrozen(dispatch, record: record)
                guard let root = record.targetRoot else { throw fail("還沒讀回新主設備的入口位置，請開著新主設備的 App 後再按②。") }
                record.constitution = true; record.sourceDeviceID = record.to; record.sourceRoot = root
                record.constitutionRevision = record.revision + 1
            }
            if let brain {
                record.brain = brain; record.brainVerified = false
                record.brainRevision = record.revision + 1
                record.targetPages = evidence.pages
                if brain != .migrating {
                    let selected = brain == .retained ? "保留舊服務" : "已遷移"
                    let frozen = try dispatch.fleet.trust() == nil ? record.sourcePages : dispatch.fleet.rotation()?.handoff.claim.sourcePages
                    guard let pages = frozen, pages >= 0 else { throw fail("移交時沒有可用的舊主設備凍結頁數，不能確認 GBrain" + selected + "。") }
                    guard record.sourcePages == pages else { throw fail("移交紀錄的 GBrain 凍結頁數不符，請重新同步設備名單後再驗證。") }
                    guard evidence.brainHealthy else { throw fail("新主設備的 GBrain 不健康，請恢復服務後再驗證。") }
                    guard let targetPages = evidence.pages, targetPages > 0 else { throw fail("新主設備沒有可用的 GBrain 頁數，請確認資料已匯入且服務正常後再驗證。") }
                    guard targetPages >= pages else { throw fail("新主設備的 GBrain 頁數少於移交時的凍結值，請補齊資料後再驗證。") }
                    if current.1 != nil && source.brainHealthy {
                        guard let currentPages = source.pages, currentPages >= 0 else { throw fail("讀不到舊主設備目前的 GBrain 頁數，請確認服務正常回報頁數後再驗證。") }
                        guard targetPages >= currentPages else { throw fail("新主設備的 GBrain 頁數少於舊主設備目前的頁數，請同步最新資料後再驗證。") }
                    }
                    if brain == .retained {
                        if let limitation = source.limitation ?? evidence.limitation { throw fail(limitation) }
                        guard source.brainHealthy else { throw fail("舊主設備的 GBrain 不健康，不能確認保留舊服務。") }
                        guard ["ssh-stdio", "ssh-http"].contains(evidence.brainMode),
                              evidence.brainHostID == record.from else { throw fail("新主設備尚未驗證連到舊主設備的 GBrain 服務。") }
                    } else {
                        guard ["pglite", "legacy"].contains(evidence.brainMode) else {
                            throw fail("新主設備使用的 GBrain 不是本機資料庫，不能確認已遷移。")
                        }
                    }
                    record.brainVerified = true
                }
            }
            if release {
                if let signingName { record.signingName = signingName.trimmingCharacters(in: .whitespacesAndNewlines) }
                let hasName = !record.signingName.isEmpty && source.signingNames.contains(record.signingName)
                    && evidence.signingNames.contains(record.signingName)
                record.missingDependencies = evidence.missingDependencies
                record.releaseChecked = true
                record.releaseRevision = record.revision + 1
                record.release = !hasName ? .missingCertificate
                    : evidence.missingDependencies.isEmpty ? .ready : .missingDependencies
            }
            record.revision += 1
            try save(record, dispatch: dispatch)
        }
    }

    private static func checkFrozen(_ dispatch: DeviceDispatch, record: Record) throws {
        let current = try dispatch.transferHashes(), frozen = DeviceDispatch.frozen(record.hashes)
        let changed = Set(current.keys).union(frozen.keys).filter { current[$0] != frozen[$0] }.sorted()
        guard changed.isEmpty else { throw fail("①之後，" + changed.joined(separator: "、") + " 的內容有改動，和移交時凍結的內容不同，②不能比對。") }
    }

    static func cancelPrepared(_ dispatch: DeviceDispatch) throws {
        try dispatch.fleet.requireOwner()
        var local = try dispatch.identity()
        guard local.role == .primary, let record = local.transfer,
              record.from == local.deviceID, !record.committed, record.previousTransferID == nil,
              local.epoch == record.oldEpoch else {
            throw fail("不可清除既有移交檢查點；請重試或由現任主設備正式移交回來")
        }
        try dispatch.fleet.cancelRotation(record)
        local.transfer = nil; local.updatedAt = Date()
        try DeviceIdentityStore.forLocalDevice(entry: dispatch.entry, pairedDeviceID: local.deviceID).write(local)
    }

    static func accept(_ record: Record, bundle: DeviceDispatch.Bundle,
                       peer: DeviceRecord, dispatch: DeviceDispatch) throws -> DeviceDispatch.Receipt {
        let local = try dispatch.identity()
        try dispatch.fleet.requireOwnerMember(record.from)
        try dispatch.fleet.requireOwnerMember(record.to)
        try dispatch.fleet.requireTransferSignature(record, proof: bundle.transferProof)
        try record.validate()
        guard record.localVerification != true else { throw fail("transfer_local_checkpoint_not_remote_authority") }
        try dispatch.fleet.validateCommitEnvelope(record, handoff: bundle.fleetHandoff, envelope: bundle.fleet)
        try dispatch.fleet.stageTransferBase(record, handoff: bundle.fleetHandoff, envelope: bundle.fleetBase)
        let previous = local.transfer
        let rotation = try dispatch.fleet.rotation()
        let rotatedAlready = try rotation?.handoff.claim.id == record.id
            && local.primaryDeviceID == record.to && local.epoch == record.epoch
        guard peer.id == record.from, bundle.sender == record.from,
              bundle.recipient == local.deviceID, record.from != record.to,
              bundle.epoch == (record.committed ? record.epoch : record.oldEpoch),
              record.participants.contains(local.deviceID), record.epoch > 0,
              record.oldEpoch == record.epoch - 1,
              dispatch.registry.list().contains(where: { $0.id == peer.id && $0.publicKeyFingerprint == peer.publicKeyFingerprint }),
              dispatch.registry.list().contains(where: { $0.id == record.to }) || local.deviceID == record.to
        else { throw fail("transfer_trust_or_hash_mismatch") }
        let frozenHashes = DeviceDispatch.frozen(record.hashes)
        if record.constitution {
            guard bundle.files.isEmpty, bundle.hashes.isEmpty else { throw fail("transfer_metadata_only_after_source_switch") }
        } else {
            guard frozenHashes == DeviceDispatch.frozen(bundle.files).mapValues(DeviceDispatch.hash) else { throw fail("transfer_manifest_mismatch") }
            try DeviceDispatch.validateFiles(bundle.files)
        }
        // Freeze only until the source switch. Later GBrain/release checkpoints
        // must not overwrite or prohibit legitimate edits on the new primary.
        if previous?.id != record.id || previous?.constitution != true {
            guard frozenHashes == (try dispatch.transferHashes()) else {
                throw fail("transfer_target_hash_mismatch")
            }
        }
        if record.constitution, local.deviceID == record.to, record.sourceRoot != dispatch.entry.root.path {
            throw fail("transfer_source_root_mismatch")
        }
        if let checkpoint = previous, checkpoint.id == record.id {
            guard record.revision >= checkpoint.revision, checkpoint.from == record.from, checkpoint.to == record.to,
                  checkpoint.epoch == record.epoch, checkpoint.hashes == record.hashes,
                  checkpoint.participants == record.participants,
                  !checkpoint.committed || record.committed,
                  !checkpoint.constitution || record.constitution,
                  Set(record.epochACKs).isSuperset(of: checkpoint.epochACKs),
                  Set(record.skippedParticipants ?? []).isSuperset(of: checkpoint.skippedParticipants ?? []) else { throw fail("transfer_replay") }
        } else {
            guard local.role == .secondary,
                  (local.primaryDeviceID == record.from && local.epoch == record.oldEpoch) || rotatedAlready else {
                throw fail("transfer_not_current_primary")
            }
        }
        guard local.epoch == record.oldEpoch || ((previous?.id == record.id || rotatedAlready) && local.epoch == record.epoch) else {
            throw fail("transfer_stale_epoch")
        }
        // A new primary must already trust every participant; pairing is never copied.
        if local.deviceID == record.to {
            let trusted = Set(dispatch.registry.list().map(\.id) + [local.deviceID])
            guard trusted.isSuperset(of: record.participants + [record.from]) else {
                throw fail("new_primary_missing_pairings")
            }
        }
        if !record.constitution {
            // Frozen sources were compared above; update only the latest working files.
            _ = try dispatch.applyFiles(bundle.files, hashes: bundle.hashes, seq: bundle.seq, readOnly: false, excluding: Set(DeviceDispatch.frozen(bundle.files).keys))
        }
        try dispatch.fleet.stageTransfer(record, handoff: bundle.fleetHandoff, roster: bundle.fleetNextRoster)
        if record.committed, try dispatch.fleet.trust() != nil {
            try dispatch.fleet.commitTransfer(record, envelope: bundle.fleet, deliveries: bundle.fleetDeliveries)
        }
        try save(record, dispatch: dispatch, commit: record.committed)
        let signed = !record.committed && local.deviceID == record.to
            ? try dispatch.fleet.signPreparedTransfer(record) : nil
        return .init(seq: bundle.seq, phase: "converged", hashes: bundle.hashes, updated: Date(),
                     transfer: ACK(id: record.id, revision: record.revision, committed: record.committed,
                                   root: dispatch.entry.root.path, evidence: dispatch.transferEvidence()),
                     fleet: signed, fleetDeliveries: signed == nil ? nil : try dispatch.fleet.rotation()?.deliveries)
    }

    static func acknowledge(_ ack: ACK, sender: String, dispatch: DeviceDispatch,
                            envelope: DeviceFleetEnvelope? = nil, deliveries: [String: DeviceFleetEnvelope]? = nil) throws {
        try dispatch.fleet.requireOwnerMember(sender)
        let local = try dispatch.identity()
        guard var record = local.transfer, record.from == local.deviceID, record.id == ack.id,
              record.revision == ack.revision, record.participants.contains(sender),
              record.committed == ack.committed else { throw fail("transfer_ack_mismatch") }
        if sender == record.to {
            record.targetRoot = ack.root; record.targetEvidence = ack.evidence
            record.acknowledgedRevision = ack.revision
        }
        if !record.committed && sender == record.to {
            record.committed = true; record.committedAt = Date(); record.revision += 1
            try dispatch.fleet.commitTransfer(record, envelope: envelope, deliveries: deliveries)
            try save(record, dispatch: dispatch, commit: true)
            return
        }
        if record.committed && !record.epochACKs.contains(sender) {
            record.epochACKs.append(sender)
            record.revision += 1
        }
        try save(record, dispatch: dispatch)
    }

    static func evidence(entry: TatwoEntry) -> Evidence {
        var result = Evidence()
        guard !NativeStagingIsolation.isW276Bundle else { return result }
        // Read names only. No export, unlock, import, or key material access.
        if let (_, data) = try? DeviceDispatch.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]) {
            result.signingNames = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                let parts = $0.components(separatedBy: "\""); return parts.count >= 3 ? parts[1] : nil
            }
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin",
               FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tatwo-build-deps/tmux/3.6b/bin").path]
        for tool in ["swift", "node", "npm", "git", "codesign", "xcrun", "hdiutil",
                     "python3", "curl", "tar", "ditto", "otool", "install_name_tool", "tmux"] {
            if !paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/" + tool) }) {
                result.missingDependencies.append(tool)
            }
        }
        if let tmux = paths.map({ $0 + "/tmux" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
           let (code, data) = try? DeviceDispatch.run(tmux, ["-V"]),
           code != 0 || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "tmux 3.6b" {
            result.missingDependencies.append("tmux 3.6b")
        }
        if (try? DeviceDispatch.run("/usr/bin/xcrun", ["--find", "swift"]).0) != 0 {
            result.missingDependencies.append("Swift toolchain")
        }
        for input in ["Package.swift", "scripts/build-app.sh", "scripts/bundle-gbrain.py",
                      "scripts/runtime-sign.py", "scripts/bundle-cli-runtime.sh",
                      "Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json"] {
            if !FileManager.default.fileExists(atPath: entry.repoRoot.appendingPathComponent(input).path) {
                result.missingDependencies.append(input)
            }
        }
        let health = GBrainHealth.read(entry: entry)
        result.brainHealthy = health.reason == nil
        if let data = try? DeviceDispatch.readFile("gbrain/state.json", root: entry.root),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.brainMode = state["mode"] as? String ?? "unconfigured"
            result.pages = state["pageCount"] as? Int
        }
        if let data = try? DeviceDispatch.readFile("gbrain/connection.json", root: entry.root),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.brainHostID = config["primaryID"] as? String
        }
        if let identity = try? DeviceIdentityStore.readLocal(entry: entry),
           (identity.role == .primary && ["ssh-stdio", "ssh-http"].contains(result.brainMode))
            || (identity.role == .secondary && ["pglite", "legacy"].contains(result.brainMode)) {
            result.limitation = "GBrain adapter 尚不支援主權與資料庫位置分離；須先完成相容性整合"
        }
        return result
    }
}
