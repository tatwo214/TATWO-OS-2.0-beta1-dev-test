import CryptoKit
import Darwin
import Foundation

/// W78 uses the existing SSH/RPC channel only. A bundle is accepted only as a
/// response fetched from the host key pinned to device.json's current primary.
/// There deliberately is no RPC that accepts an arbitrary inbound bundle.
final class DeviceDispatch: @unchecked Sendable {
    static let shared = DeviceDispatch()
    /// 憲法 v4.1：這些入口檔跟 os.md 一樣由主設備派發；沒有就不帶。
    static let optionalFiles = ["agents.md", "user.md", "todo.md", "issue.md"]
    private static let transferFiles = ["os.md", "skillet.md", "user.md"]
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { DeviceFleetReason.plain(self) }
    }

    struct Bundle: Codable {
        var sender: String
        var recipient: String
        var epoch: Int
        var seq: UInt64
        var files: [String: Data]
        var hashes: [String: String]
        var transfer: PrimaryTransfer.Record? = nil
        var fleet: DeviceFleetEnvelope? = nil
        var leaveRequested: Bool? = nil
        var fleetDeliveries: [String: DeviceFleetEnvelope]? = nil
        var transferProof: DeviceFleetTransferProof? = nil
        var fleetHandoff: DeviceFleetHandoff? = nil
        var fleetNextRoster: DeviceFleetRoster? = nil
        var fleetBase: DeviceFleetEnvelope? = nil
        var fleetChain: [DeviceFleetEnvelope]? = nil
        var fleetOnly: Bool? = nil
        var sourceRecoveryProof: CoordinatorRecovery? = nil
    }
    /// The current primary signs only its exact physically authorized source recovery.
    /// This retires background coordination without fabricating any W83 readbacks.
    struct CoordinatorRecovery: Codable {
        struct Claim: Codable { var transferID: String; var primaryID: String; var epoch: Int }
        var body: Data
        var signature: Data
        var publicKey: String
        static let namespace = "tatwo2-transfer-source-recovery"
        static func issue(_ record: PrimaryTransfer.Record, environment: [String: String]) throws -> Self {
            let body = try DeviceFleetHandoff.bytes(Claim(transferID: record.id, primaryID: record.to, epoch: record.epoch))
            let signed = try DeviceSignature.sign(body, namespace: namespace, environment: environment)
            return .init(body: body, signature: signed.0, publicKey: signed.1)
        }
        func retires(_ record: PrimaryTransfer.Record, trust: DeviceFleetTrust) throws -> Bool {
            guard body.count <= 512, signature.count < 8192, publicKey.utf8.count <= 2048 else { return false }
            let claim = try JSONDecoder().decode(Claim.self, from: body)
            let fingerprint = try DeviceRegistry.fingerprint(publicKey: publicKey)
            return record.committed && record.from == trust.localID && claim.transferID == record.id
                && claim.primaryID == record.to && claim.primaryID == trust.primaryID
                && claim.epoch == record.epoch && claim.epoch == trust.epoch
                && fingerprint == trust.pinnedPrimaryKey
                && DeviceSignature.verify(body: body, signature: signature, publicKey: publicKey, namespace: Self.namespace)
        }
    }
    struct Receipt: Codable {
        var seq: UInt64
        var phase: String
        var hashes: [String: String]
        var updated: Date
        var detail: String?
        var attemptAt: Date?
        var transfer: PrimaryTransfer.ACK? = nil
        var fleet: DeviceFleetEnvelope? = nil
        var fleetMembers: [DeviceFleetMember]? = nil
        var fleetRemoved: [String]? = nil
        var fleetDeliveries: [String: DeviceFleetEnvelope]? = nil
        var fleetChain: [DeviceFleetEnvelope]? = nil
        var fleetRevision: UInt64? = nil
    }
    /// A bounded sequence window per authenticated key + authority epoch. Gaps are allowed;
    /// identical proofs and counters outside the window remain unusable after a restart.
    struct ReplayWindow: Codable {
        var highest: UInt64 = 0
        var floor: UInt64 = 0
        var seen: [UInt64] = []
        mutating func consume(_ sequence: UInt64) throws {
            guard sequence > floor, !seen.contains(sequence),
                  sequence > highest || highest - sequence < 1024 else {
                throw Failure(reason: "stale_epoch_or_replayed_sequence")
            }
            highest = max(highest, sequence)
            seen.append(sequence)
            seen.removeAll { highest - $0 >= 1024 }
        }
    }
    struct State: Codable {
        var retiredCoordinatorTransfer: String? = nil
        var next: UInt64 = 0
        var received: [String: UInt64] = [:]
        var rpcWindows: [String: ReplayWindow]? = nil
        var epoch: Int = 0
        var receipts: [String: Receipt] = [:]
        /// Handoff metadata and ordinary document pulls can run in opposite
        /// directions after the source switch; never overwrite an outstanding ACK.
        var transferOffers: [String: Receipt]? = nil
        var transferWorkACKs: [String: [String: String]]? = nil
    }
    let entry: TatwoEntry
    let registry: DeviceRegistry
    let root: URL
    let environment: [String: String]
    let retireBackup: ((URL) -> Void)?
    /// In-process test transport only; no environment or RPC can enable it.
    private let rpc: ((DeviceRecord, String, [String: Any]) throws -> [String: Any])?
    private let push: ((URL, String, String, String) throws -> Void)?
    private let evidence: (() -> PrimaryTransfer.Evidence)?
    lazy var inbox = DeviceInbox(dispatch: self)
    private static let lockRegistry = NSLock()
    private final class StateLock {
        private let mutex = NSRecursiveLock()
        private let threadKey = "tatwo.dispatch.lock." + UUID().uuidString
        var heldByCurrentThread: Bool { (Thread.current.threadDictionary[threadKey] as? Int ?? 0) > 0 }
        func lock() { mutex.lock(); acquired() }
        func unlock() {
            let depth = Thread.current.threadDictionary[threadKey] as? Int ?? 0
            assert(depth > 0)
            if depth == 1 { Thread.current.threadDictionary.removeObject(forKey: threadKey) }
            else { Thread.current.threadDictionary[threadKey] = depth - 1 }
            mutex.unlock()
        }
        func `try`() -> Bool { guard mutex.try() else { return false }; acquired(); return true }
        private func acquired() { Thread.current.threadDictionary[threadKey] = (Thread.current.threadDictionary[threadKey] as? Int ?? 0) + 1 }
        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock(); defer { unlock() }; return try body()
        }
    }
    nonisolated(unsafe) private static var stateLocks: [String: StateLock] = [:]
    private let lock: StateLock
    private static func stateLock(for root: URL) -> StateLock {
        lockRegistry.withLock {
            let key = root.standardizedFileURL.resolvingSymlinksInPath().path
            if let existing = stateLocks[key] { return existing }
            let created = StateLock(); stateLocks[key] = created; return created
        }
    }
    /// Keep related primary RPC work ordered within this instance. All instances share the
    /// durable state lock; receivers accept bounded out-of-order proofs via the replay window.
    private let rpcLock = NSRecursiveLock()
    private var recoveryScanFailures = 0
    private var recoveryScanAfter = Date.distantPast
    private var formerRecoveryAttempts: [String: (count: Int, after: Date)] = [:]
    #if DEBUG
    var fixtureRecoveryNow: Date?
    var fixtureAlign: (() -> Void)?
    #endif
    private var recoveryNow: Date {
        #if DEBUG
        if let fixtureRecoveryNow { return fixtureRecoveryNow }
        #endif
        return Date()
    }
    private let worker = DispatchQueue(label: "ai.tatwo.tatwo2.dispatch")
    private var timer: DispatchSourceTimer?
    let fleet: DeviceFleetStore

    init(entry: TatwoEntry = TatwoEntry(), registry: DeviceRegistry = DeviceRegistry(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         retireBackup: ((URL) -> Void)? = nil,
         rpc: ((DeviceRecord, String, [String: Any]) throws -> [String: Any])? = nil,
         push: ((URL, String, String, String) throws -> Void)? = nil,
         evidence: (() -> PrimaryTransfer.Evidence)? = nil) {
        self.entry = entry; self.registry = registry; self.environment = environment
        fleet = DeviceFleetStore(registry: registry, environment: environment)
        self.retireBackup = retireBackup
        self.rpc = rpc
        self.push = push
        self.evidence = evidence
        root = registry.root.appendingPathComponent("dispatch", isDirectory: true)
        lock = Self.stateLock(for: root)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// Descriptor-relative, no-follow read. Never traverse a note/ symlink.
    static func readFile(_ path: String, root: URL, readOnly: Bool = false) throws -> Data? {
        let parts = try RemoteThreadTransfer.validatedRelativePath(path).split(separator: "/").map(String.init)
        var fd = Darwin.open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(reason: "entry_unreadable") }
        defer { Darwin.close(fd) }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return nil }
                throw Failure(reason: "unsafe_file_parent")
            }
            Darwin.close(fd); fd = next
        }
        let file = openat(fd, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure(reason: "unsafe_file")
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 4 * 1024 * 1024 else { throw Failure(reason: "not_a_bounded_regular_file") }
        let data = try handle.readToEnd() ?? Data()
        if readOnly, fchmod(file, 0o444) != 0 { throw Failure(reason: "readonly_mode_failed") }
        return data
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    func identity() throws -> DeviceIdentity {
        try fleet.recoverAuthority()
        guard let local = try DeviceIdentityStore.readLocal(entry: entry),
              local.epoch != nil, local.primaryDeviceID != nil else { throw Failure(reason: "authority_unknown") }
        return local
    }
    func primary() throws -> DeviceRecord {
        let local = try identity()
        guard local.role == .secondary,
              let peer = registry.list().first(where: { $0.id.lowercased() == local.primaryDeviceID?.lowercased() })
        else { throw Failure(reason: "primary_not_paired") }
        return peer
    }
    #if DEBUG
    func fixtureStateLockAvailable(timeout: TimeInterval = 0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if lock.try() { lock.unlock(); return true }
            if timeout == 0 { return false }
            usleep(1_000)
        } while Date() < deadline
        return false
    }
    #endif
    private func state() throws -> State {
        let file = root.appendingPathComponent("state.json")
        if !FileManager.default.fileExists(atPath: file.path) { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
    }
    private func save(_ value: State) throws {
        try HandsFiles.writeAtomically(JSONEncoder().encode(value), to: root.appendingPathComponent("state.json"))
    }
    func receipts(now: Date = Date()) -> [String: Receipt] {
        lock.lock(); defer { lock.unlock() }
        guard let state = try? state() else { return [:] }
        return state.receipts.mapValues { receipt in
            var row = receipt
            if row.phase != "converged", now.timeIntervalSince(row.updated) > 60 {
                row.phase = "timeout"
            }
            return row
        }
    }
    private func notePaths() throws -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: entry.noteDir.path) {
            guard (try? fm.destinationOfSymbolicLink(atPath: entry.noteDir.path)) == nil else {
                throw Failure(reason: "note_symlink")
            }
            var enumerationError: Error?
            guard let enumerator = fm.enumerator(at: entry.noteDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw Failure(reason: "notes_unreadable")
            }
            // The enumerator yields resolved paths; the entrance may be reached through
            // a symlink (mini: ~/AI/TATWO OS → /Volumes/…), so strip the resolved prefix.
            let notePrefix = entry.noteDir.resolvingSymlinksInPath().path
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                guard visited <= 2048 else { throw Failure(reason: "dispatch_too_many_paths") }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                    throw Failure(reason: "note_symlink_or_special_file")
                }
                if values.isRegularFile == true {
                    let resolved = url.resolvingSymlinksInPath().path
                    guard resolved.hasPrefix(notePrefix + "/") else { throw Failure(reason: "note_outside_entry") }
                    paths.append("note/" + String(resolved.dropFirst(notePrefix.count + 1)))
                }
            }
            if let enumerationError { throw enumerationError }
        }
        return paths
    }
    /// Working files travel at their latest version; only rule sources and preferences freeze at ①.
    static func frozen<T>(_ files: [String: T]) -> [String: T] {
        files.filter { transferFiles.contains($0.key) }
    }
    func transferHashes() throws -> [String: String] {
        var files: [String: Data] = [:]
        for path in Self.transferFiles {
            do { files[path] = try Self.readFile(path, root: entry.root) }
            catch { throw Failure(reason: "讀不到凍結範圍的 " + path + "，請確認入口檔案仍存在且可讀。") }
            guard path == "user.md" || files[path] != nil else { throw Failure(reason: "凍結範圍的 " + path + " 已不存在，不能比對。") }
        }
        return files.mapValues(Self.hash)
    }
    func snapshot() throws -> [String: Data] {
        // W160：agents.md／user.md／todo.md／issue.md 跟著派發；主設備還沒有這些檔時不擋（選配）。
        let optional = Self.optionalFiles.filter { (try? Self.readFile($0, root: entry.root)) != nil }
        let paths = try ["os.md", "skillet.md"] + optional + notePaths()
        guard paths.count <= 512 else { throw Failure(reason: "dispatch_too_many_files") }
        var result: [String: Data] = [:], bytes = 0
        for path in paths {
            guard let data = try Self.readFile(path, root: entry.root) else {
                throw Failure(reason: "dispatch_missing_file")
            }
            bytes += data.count
            guard bytes <= 4 * 1024 * 1024 else { throw Failure(reason: "dispatch_too_large") }
            result[path] = data
        }
        return result
    }
    static func validateFiles(_ files: [String: Data]) throws {
        guard files.count <= 512, files.values.reduce(0, { $0 + $1.count }) <= 4 * 1024 * 1024 else { throw Failure(reason: "dispatch_too_large") }
        for path in files.keys {
            _ = try RemoteThreadTransfer.validatedRelativePath(path)
            guard path == "os.md" || path == "skillet.md" || optionalFiles.contains(path) || path.hasPrefix("note/") else {
                throw Failure(reason: "dispatch_path_outside_allowlist")
            }
        }
    }
    func writeFiles(_ files: [String: Data], hashes: [String: String]) throws {
        let baselines = try RemoteThreadTransfer.baselines(paths: Array(files.keys), in: entry.root.path)
        let changed = files.filter { baselines[$0.key] != hashes[$0.key] }.map { RemoteThreadTransferFile(relativePath: $0.key,
            base64: $0.value.base64EncodedString(), baseSHA256: baselines[$0.key]) }
        try RemoteThreadTransfer.write(changed, to: entry.root.path, retire: retireBackup)
    }
    /// Shared write, archive and readback transaction; transfer excludes only frozen sources.
    func applyFiles(_ files: [String: Data], hashes: [String: String], seq: UInt64, readOnly: Bool, excluding: Set<String> = [], onWritten: () throws -> Void = {}) throws -> [String: String] {
        let selected = files.filter { !excluding.contains($0.key) }
        let expected = hashes.filter { !excluding.contains($0.key) }
        let removed = Set(try notePaths()).subtracting(files.keys).sorted()
        try writeFiles(selected, hashes: expected)
        try onWritten()
        try archiveRemovedNotes(removed, seq: seq)
        for path in selected.keys {
            guard try Self.readFile(path, root: entry.root, readOnly: readOnly) != nil else { throw Failure(reason: "readback_missing") }
        }
        let readback = try snapshot().filter { !excluding.contains($0.key) && (files[$0.key] != nil || !Self.optionalFiles.contains($0.key)) }.mapValues(Self.hash)
        guard readback == expected else { throw Failure(reason: "readback_mismatch") }
        return readback
    }
    /// Wake the pinned destination and wait off-main for its genuine working-file ACK.
    func refreshTransferWork(_ peer: DeviceRecord) throws {
        if try lock.withLock({ try transferWorkMatches(peer) }) { return }
        _ = try send(peer, method: "dispatch_wake", params: [:])
        let deadline = Date().addingTimeInterval(30)
        while try !lock.withLock({ try transferWorkMatches(peer) }) {
            guard Date() < deadline else { throw Failure(reason: "transfer_work_readback_pending") }
            usleep(100_000)
        }
    }
    func transferWorkMatches(_ peer: DeviceRecord) throws -> Bool {
        let state = try state(), last = state.receipts[peer.id]
        let hashes = state.transferWorkACKs?[peer.id] ?? (last?.phase == "converged" ? last?.hashes : nil)
        return try hashes == snapshot().mapValues(Self.hash)
    }
    /// Removed replica notes are archived, never deleted. Descriptor-relative
    /// renames cannot follow a replaced note parent or an archive symlink.
    /// Ordinary dispatch saves its applied receipt before archiving; a fresh sequence finishes the
    /// remaining moves and must read back the entire manifest before converging.
    private func archiveRemovedNotes(_ paths: [String], seq: UInt64) throws {
        guard !paths.isEmpty else { return }
        let rootFD = Darwin.open(entry.root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure(reason: "entry_unreadable") }
        defer { Darwin.close(rootFD) }
        guard mkdirat(rootFD, "archive", 0o700) == 0 || errno == EEXIST else {
            throw Failure(reason: "archive_unavailable")
        }
        let archiveFD = openat(rootFD, "archive", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard archiveFD >= 0 else { throw Failure(reason: "unsafe_archive") }
        defer { Darwin.close(archiveFD) }
        let name = "w78-notes-\(seq)-" + UUID().uuidString
        guard mkdirat(archiveFD, name, 0o700) == 0 else { throw Failure(reason: "archive_unavailable") }
        let destination = openat(archiveFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else { throw Failure(reason: "archive_unavailable") }
        defer { Darwin.close(destination) }
        let manifest = "# Archived replica notes\nRestore each numbered file to its relative path under the entrance.\n"
            + paths.enumerated().map { "\($0.offset).note → \($0.element)" }.joined(separator: "\n") + "\n"
        let manifestFD = openat(destination, "MANIFEST.md", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard manifestFD >= 0 else { throw Failure(reason: "archive_manifest_unavailable") }
        let handle = FileHandle(fileDescriptor: manifestFD, closeOnDealloc: true)
        try handle.write(contentsOf: Data(manifest.utf8)); try handle.close()
        for (index, path) in paths.enumerated() {
            let parts = try RemoteThreadTransfer.validatedRelativePath(path).split(separator: "/").map(String.init)
            guard parts.first == "note", let leaf = parts.last,
                  try Self.readFile(path, root: entry.root) != nil else { throw Failure(reason: "unsafe_removed_note") }
            var parent = dup(rootFD)
            guard parent >= 0 else { throw Failure(reason: "archive_unavailable") }
            defer { Darwin.close(parent) }
            for part in parts.dropLast() {
                let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure(reason: "unsafe_removed_note") }
                Darwin.close(parent); parent = next
            }
            guard renameat(parent, leaf, destination, "\(index).note") == 0 else {
                throw Failure(reason: "note_archive_interrupted")
            }
        }
    }
    /// Read-only payload creation except for the durable sequence / receipt ledger.
    func offer(to recipient: String) throws -> Bundle {
        lock.lock(); defer { lock.unlock() }
        let local = try identity()
        if let trust = try fleet.trust(), trust.kind != .owner {
            // owner 主動詢問：受管設備只回離開申請，沒有任何主人資料與檔案。
            return Bundle(sender: local.deviceID, recipient: recipient, epoch: local.epoch!,
                          seq: 0, files: [:], hashes: [:], leaveRequested: try fleet.leaveRequested())
        }
        let handoff = local.transfer.flatMap { $0.from == local.deviceID ? $0 : nil }
        guard (local.role == .primary || handoff?.participants.contains(recipient) == true),
              registry.list().contains(where: { $0.id == recipient }) else {
            throw Failure(reason: "not_primary_or_unknown_recipient")
        }
        let roster = try fleet.current()?.roster
        let historicalReturn = roster?.kind(of: recipient) == .owner && roster?.revoked.contains(recipient) == false
            && (local.transfer?.skippedParticipants?.contains(recipient) == true || roster?.rotationHistory?[recipient]?.isEmpty == false)
        var fleetOnly = false
        if let transfer = local.transfer, transfer.to == local.deviceID, !transfer.constitution, try !hasRecoveredDispatchSource() {
            guard historicalReturn else { throw Failure(reason: "constitution_source_not_transferred") }
            fleetOnly = true // Authority recovery cannot imply that document/source checkpoints completed.
        }
        if local.role == .primary && !fleetOnly { _ = try? AgentsFile.refresh(entry: entry, role: local.role) }
        let files: [String: Data] = fleetOnly || handoff?.constitution == true ? [:] : try snapshot()
        let hashes = files.mapValues(Self.hash)
        var state = try state()
        guard local.epoch! >= state.epoch else { throw Failure(reason: "stale_local_authority") }
        guard state.next < UInt64.max else { throw Failure(reason: "sequence_exhausted") }
        state.epoch = local.epoch!
        state.next += 1
        let previous = state.receipts[recipient]
        let started = previous?.phase != "converged" && previous?.hashes == hashes ? previous!.updated : Date()
        state.receipts[recipient] = Receipt(seq: state.next, phase: "delivered", hashes: hashes,
                                          updated: started, attemptAt: Date())
        if handoff != nil {
            var offers = state.transferOffers ?? [:]
            offers[recipient] = state.receipts[recipient]
            state.transferOffers = offers
        }
        var sourceRecoveryProof: CoordinatorRecovery?
        if local.role == .primary, let record = local.transfer, record.to == local.deviceID,
           record.localVerification == true {
            sourceRecoveryProof = try CoordinatorRecovery.issue(record, environment: environment)
        }
        try save(state)
        let transferProof: DeviceFleetTransferProof?
        if let handoff, try fleet.trust() != nil {
            transferProof = try DeviceFleetTransferProof.issue(handoff, environment: environment)
        } else { transferProof = nil }
        let rotation = try fleet.rotation()
        let rosterEnvelope = handoff == nil ? try fleet.delivery(for: recipient)
            : (handoff?.committed == true ? rotation?.envelope : nil)
        let fleetRevision = try rosterEnvelope.map { try JSONDecoder().decode(DeviceFleetPayload.self, from: $0.body).revision }
        state.receipts[recipient]?.fleetRevision = fleetRevision
        if handoff != nil { state.transferOffers?[recipient]?.fleetRevision = fleetRevision }
        try save(state)
        let managedDeliveries = handoff == nil ? (rosterEnvelope == nil ? nil : try fleet.managedDeliveries())
            : (handoff?.committed == true ? rotation?.deliveries : nil)
        var ownerChain = roster?.kind(of: recipient) == .owner ? (roster?.rotationHistory?[recipient] ?? []) : []
        if roster?.kind(of: recipient) == .owner, let commit = rotation?.envelope,
           !ownerChain.contains(commit) { ownerChain.append(commit) }
        // Retention limits require old observers to pair locally, but cannot block a peer already on the current pin.
        ownerChain = Array(ownerChain.suffix(16))
        return Bundle(sender: local.deviceID, recipient: recipient, epoch: local.epoch!,
                      seq: state.next, files: files, hashes: hashes, transfer: handoff,
                      fleet: rosterEnvelope, fleetDeliveries: managedDeliveries,
                      transferProof: transferProof, fleetHandoff: handoff == nil ? nil : rotation?.handoff,
                      fleetNextRoster: handoff == nil ? nil : rotation?.nextRoster,
                      fleetBase: handoff == nil ? nil : rotation?.baseEnvelope,
                      fleetChain: ownerChain.isEmpty ? nil : ownerChain, fleetOnly: fleetOnly ? true : nil,
                      sourceRecoveryProof: sourceRecoveryProof)
    }
    /// Internal transport-bound entry, never exposed through OSAgentBridge.perform.
    func apply(_ bundle: Bundle, authenticatedPrimary: DeviceRecord) throws -> Receipt {
        lock.lock(); defer { lock.unlock() }
        var local = try identity()
        try fleet.requireOwner()
        if let transfer = bundle.transfer {
            var state = try state()
            guard bundle.epoch >= max(local.epoch!, state.epoch),
                  bundle.seq > (state.received[bundle.sender] ?? 0),
                  bundle.files.mapValues(Self.hash) == bundle.hashes else {
                fleet.audit("fleet_transfer_replay_or_epoch_refused")
                throw Failure(reason: "stale_epoch_or_replayed_transfer")
            }
            let receipt: Receipt
            do { receipt = try PrimaryTransfer.accept(transfer, bundle: bundle, peer: authenticatedPrimary, dispatch: self) }
            catch { fleet.audit(error, fallback: "fleet_transfer_accept_refused"); throw error }
            state.epoch = bundle.epoch
            state.received[bundle.sender] = bundle.seq
            state.receipts[bundle.sender] = receipt
            try save(state)
            return receipt
        }
        // Validate the entire chain and final roster before moving any authority pin.
        let advances = bundle.epoch > (local.epoch ?? 0)
        if advances || bundle.fleetOnly == true {
            guard let trust = try fleet.trust(), trust.kind == .owner else { throw DeviceFleetError.role }
            let commits = try verifiedOwnerRecovery(bundle, trust: trust)
            let ledger = try state()
            guard local.role == .secondary, bundle.epoch >= ledger.epoch,
                  bundle.seq > (ledger.received[bundle.sender] ?? 0),
                  registry.list().contains(where: { $0.id == authenticatedPrimary.id && $0.publicKeyFingerprint == authenticatedPrimary.publicKeyFingerprint }),
                  bundle.sender == authenticatedPrimary.id, bundle.recipient == local.deviceID else { throw DeviceFleetError.signature }
            if bundle.fleetOnly == true {
                guard bundle.files.isEmpty, bundle.hashes.isEmpty else { throw Failure(reason: "fleet_recovery_contains_documents") }
            } else {
                guard bundle.files["os.md"] != nil, bundle.files["skillet.md"] != nil,
                      bundle.files.mapValues(Self.hash) == bundle.hashes else { throw DeviceFleetError.signature }
                try Self.validateFiles(bundle.files)
            }
            for commit in commits { try fleet.synchronizeEnvelope(commit) }
            try fleet.synchronizeEnvelope(bundle.fleet!)
            local = try identity()
            if bundle.fleetOnly == true {
                var state = try state(); state.epoch = bundle.epoch; state.received[bundle.sender] = bundle.seq
                state.receipts[bundle.sender] = Receipt(seq: bundle.seq, phase: "delivered", hashes: [:], updated: Date(), detail: "fleet_recovery_only")
                try save(state)
                return Receipt(seq: bundle.seq, phase: "converged", hashes: [:], updated: Date(), detail: "fleet_recovery_only", fleetRevision: try fleet.current()?.revision)
            }
        }
        guard local.role == .secondary,
              authenticatedPrimary.id.lowercased() == local.primaryDeviceID?.lowercased(),
              registry.list().contains(where: { $0.id == authenticatedPrimary.id
                  && $0.publicKeyFingerprint == authenticatedPrimary.publicKeyFingerprint }),
              bundle.sender.lowercased() == authenticatedPrimary.id.lowercased(),
              bundle.recipient.lowercased() == local.deviceID.lowercased()
        else { throw Failure(reason: "not_current_primary") }
        var state = try state()
        guard bundle.epoch >= max(local.epoch!, state.epoch) else { throw Failure(reason: "stale_epoch") }
        guard bundle.seq > (state.received[bundle.sender] ?? 0) else { throw Failure(reason: "replayed_sequence") }
        guard bundle.files["os.md"] != nil, bundle.files["skillet.md"] != nil,
              bundle.files.mapValues(Self.hash) == bundle.hashes else { throw Failure(reason: "content_hash_mismatch") }
        try Self.validateFiles(bundle.files)
        if let envelope = bundle.fleet {
            if try fleet.trust() == nil, let host = authenticatedPrimary.hostKeyFingerprint {
                try fleet.adoptLegacy(envelope, primary: authenticatedPrimary, expectedHost: host)
            } else { try fleet.synchronizeEnvelope(envelope) }
        }
        if let deliveries = bundle.fleetDeliveries {
            do { try fleet.cacheDeliveries(deliveries) }
            catch { fleet.audit("fleet_projection_cache_rejected") }
        }
        if let proof = bundle.sourceRecoveryProof, let record = local.transfer,
           bundle.epoch == record.epoch, let trust = try fleet.trust(),
           (try? proof.retires(record, trust: trust)) == true {
            state.retiredCoordinatorTransfer = record.id
        }
        // Consume before writing. A crash/retry must obtain a fresh sequence, never
        // reuse a cached converged ACK. File transaction recovery is W72's writer.
        state.epoch = bundle.epoch
        state.received[bundle.sender] = bundle.seq
        state.receipts[bundle.sender] = Receipt(seq: bundle.seq, phase: "delivered", hashes: [:], updated: Date())
        try save(state)
        var receipt = Receipt(seq: bundle.seq, phase: "applied", hashes: [:], updated: Date())
        receipt.hashes = try applyFiles(bundle.files, hashes: bundle.hashes, seq: bundle.seq, readOnly: true) {
            state.receipts[bundle.sender] = receipt; try save(state)
        }
        receipt.phase = "converged"; receipt.updated = Date()
        receipt.fleetRevision = try fleet.current()?.revision
        state.receipts.removeValue(forKey: "local")
        state.receipts[bundle.sender] = receipt; try save(state)
        if let transfer = local.transfer, !transfer.committed, transfer.from == bundle.sender,
           local.epoch == transfer.oldEpoch {
            // The still-current primary cancelled before committing the epoch.
            // An ordinary pinned bundle restores W78 alignment, not a takeover.
            try fleet.cancelRotation(transfer)
            var restored = local; restored.transfer = nil; restored.updatedAt = Date()
            try DeviceIdentityStore.forLocalDevice(entry: entry, pairedDeviceID: local.deviceID).write(restored)
        }
        // This proof can only fill the sender's existing legacy key slots.
        let selfRow = try fleet.current()?.roster?.devices.first { $0.id == local.deviceID }
        if selfRow?.legacy == true {
            do { receipt.fleetMembers = try fleet.syncMember().map { [$0] } }
            catch { fleet.audit("fleet_legacy_self_upgrade_pending") }
        }
        receipt.fleetRemoved = try fleet.managedRemovalReceipts()
        return receipt
    }
    func recordACK(_ receipt: Receipt, sender: String) throws {
        lock.lock()
        var forwardProjection = false
        defer {
            lock.unlock()
            if forwardProjection {
                worker.async {
                    do { try self.synchronizeManaged() }
                    catch { self.fleet.audit("fleet_handoff_projection_forward_pending") }
                }
            }
        }
        if let members = receipt.fleetMembers, !members.isEmpty,
           (members.count != 1 || members[0].id != sender) {
            fleet.audit("fleet_roster_channel_admission_refused")
            throw Failure(reason: "fleet_local_pairing_required")
        }
        let pushTrust = try fleet.trust(), pushIdentity = try identity()
        if receipt.phase == "fleet", (pushTrust?.kind == .owner || pushTrust == nil),
           pushIdentity.role == .secondary {
            guard sender == (pushTrust?.primaryID ?? pushIdentity.primaryDeviceID), let envelope = receipt.fleet, receipt.fleetMembers == nil,
                  receipt.transfer == nil else { throw Failure(reason: "untrusted_fleet_push") }
            if try fleet.trust() == nil {
                guard receipt.fleetChain == nil else { throw Failure(reason: "untrusted_fleet_push") }
                try fleet.adoptLegacyPush(envelope, sender: sender)
            } else { try fleet.synchronizeEnvelope(envelope) }
            return
        }
        if let trust = try fleet.trust(), trust.kind != .owner {
            if let chain = receipt.fleetChain, !chain.isEmpty {
                guard chain.count <= 16, receipt.phase == "fleet", receipt.transfer == nil,
                      let final = receipt.fleet else { throw Failure(reason: "invalid_rotation_chain") }
                let packet = try Self.object(receipt)
                let finalEpoch = try JSONDecoder().decode(DeviceFleetPayload.self, from: final.body).epoch
                if finalEpoch > trust.epoch {
                    let fingerprint = try DeviceRegistry.fingerprint(publicKey: final.publicKey)
                    guard try fleet.allowsRotationTransport(content: packet, fingerprint: fingerprint, epoch: finalEpoch) else {
                        throw Failure(reason: "invalid_rotation_chain")
                    }
                }
                for commit in chain {
                    let epoch = try JSONDecoder().decode(DeviceFleetPayload.self, from: commit.body).epoch
                    if epoch > (try fleet.trust()!.epoch) { try fleet.synchronizeEnvelope(commit) }
                }
            }
            guard let envelope = receipt.fleet, receipt.phase == "fleet", receipt.fleetMembers == nil,
                  receipt.transfer == nil else { throw Failure(reason: "managed_only_accepts_signed_fleet") }
            try fleet.synchronizeEnvelope(envelope)
            return
        }
        var state = try state()
        let offered = receipt.transfer == nil ? state.receipts[sender] : state.transferOffers?[sender]
        guard let sent = offered, sent.seq == receipt.seq,
              receipt.phase == "converged", sent.hashes == receipt.hashes,
              Date().timeIntervalSince(sent.attemptAt ?? sent.updated) <= 60 else { throw Failure(reason: "invalid_or_late_ack") }
        if let revision = sent.fleetRevision, receipt.fleetRevision == revision {
            try fleet.recordDeliveryProblem(sender, error: nil, revision: revision)
        }
        if let members = receipt.fleetMembers, !members.isEmpty {
            do { try fleet.upgradeLegacySelf(members[0], sender: sender) }
            catch { fleet.audit("fleet_legacy_self_upgrade_pending") }
        }
        if let transfer = receipt.transfer {
            do { try PrimaryTransfer.acknowledge(transfer, sender: sender, dispatch: self,
                                                envelope: receipt.fleet, deliveries: receipt.fleetDeliveries) }
            catch { fleet.audit(error, fallback: "fleet_transfer_ack_refused"); throw error }
        }
        if receipt.transfer == nil, try hasRecoveredDispatchSource(),
           var record = try identity().transfer, record.committed, record.to == (try identity()).deviceID,
           record.participants.contains(sender), !record.epochACKs.contains(sender) {
            // The recovered primary finishes epoch readbacks through genuine, current-epoch
            // document ACKs. Constitution/GBrain/release evidence is never synthesized.
            record.epochACKs = Array(Set(record.epochACKs + [record.to, sender])).sorted()
            record.revision += 1; try PrimaryTransfer.save(record, dispatch: self)
        }
        state.receipts[sender] = Receipt(seq: sent.seq, phase: "converged", hashes: receipt.hashes, updated: Date(), fleetRevision: receipt.fleetRevision)
        if receipt.transfer != nil && !receipt.hashes.isEmpty {
            var acks = state.transferWorkACKs ?? [:]; acks[sender] = receipt.hashes; state.transferWorkACKs = acks
        }
        try save(state)
        if receipt.transfer != nil, let envelope = try fleet.envelope() {
            // Completion removes the former coordinator's temporary roster-only grants.
            try fleet.synchronizeEnvelope(envelope)
            if let transfer = try identity().transfer, transfer.committed, !transfer.epochComplete,
               transfer.from == (try identity()).deviceID {
                // The destination may have no authorized SSH row on a roster-only staff device yet.
                // Forward its self-authenticating commit using the still-authorized incumbent key.
                forwardProjection = true
            }
        }
        if let removed = receipt.fleetRemoved {
            let roster = try fleet.current()?.roster
            for id in removed where roster?.revoked.contains(id) == true {
                try fleet.recordManagedDelivery(id, removed: true)
            }
        }
    }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        do { try DeviceFleetGate.install(registry: registry) } catch { fleet.audit("fleet_gate_install_failed") }
        worker.async { // Recover authority/key projections and unfinished revocation after a process crash.
            do {
                try self.fleet.recoverAuthority()
                if let envelope = try self.fleet.envelope() { try self.fleet.synchronizeEnvelope(envelope) }
            } catch { self.fleet.audit("fleet_launch_reconcile_pending") }
        }
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: 10)
        timer.setEventHandler { [weak self] in self?.synchronize() }
        self.timer = timer; timer.resume()
    }
    func align(targetDeviceID: String? = nil, regenerateRules: Bool = false) {
        #if DEBUG
        if let fixtureAlign { fixtureAlign(); return }
        #endif
        lock.withLock {
            recoveryScanFailures = 0; recoveryScanAfter = .distantPast
            formerRecoveryAttempts = [:]
        }
        // Injected test transports are driven synchronously; never race test roots.
        guard rpc == nil else { return }
        worker.async {
            let local = try? self.identity()
            if let local, local.role == .primary, let transfer = local.transfer, transfer.to == local.deviceID, !transfer.constitution {
                if let former = self.registry.list().first(where: { $0.id == transfer.from }) { try? self.pullTransfer(from: former) }
                return
            }
            if local?.role == .primary {
                for peer in self.registry.list() where targetDeviceID == nil || peer.id == targetDeviceID {
                    try? RemoteHostLink(environment: self.environment).notifyDispatch(device: peer)
                }
            } else {
                self.synchronize()
                if regenerateRules, let primary = try? self.primary(),
                   self.receipts()[primary.id]?.phase == "converged" {
                    // W68 ownership checks preserve customized output. Translating
                    // constitution+identity into new rule content remains W79.
                    _ = OSUpstreamRefresh.applyOnLaunch()
                }
            }
        }
    }
    func synchronize() {
        do {
            try fleet.discardSecondaryPending()
            try fleet.expirePreparedTransfer()
            try PrimaryTransfer.probePendingParticipants(self)
            let local = try identity()
            if let trust = try fleet.trust(), trust.kind != .owner { return } // 永不反連 owner。
            if local.role == .primary {
                // W83 未完成的移交仍走原有通道；不要在半途製造另一任名單。
                if local.transfer == nil { try fleet.bootstrapPrimary(host: environment["TATWO2_PAIRING_HOST"] ?? ProcessInfo.processInfo.hostName) }
                if let payload = try fleet.current(), let trust = try fleet.trust() {
                    do { _ = try fleet.migrateStaffInterconnections(payload, trust: trust) }
                    catch { fleet.audit("fleet_migration_needs_local_confirmation") }
                }
                if let envelope = try fleet.envelope() {
                    try fleet.synchronizeEnvelope(envelope)
                }
                try synchronizeManaged()
            }
            // A roster-only recovery precedes the actual W83 metadata/readback ACK.
            // Fetch the still-paired coordinator using the now-current epoch; never synthesize an ACK from presence.
            if local.transfer == nil, let rotation = try fleet.rotation(),
               let claim = try? rotation.handoff.claim, claim.epoch == local.epoch, claim.from != local.deviceID,
               let roster = try fleet.current()?.roster, !roster.revoked.contains(claim.from), roster.kind(of: claim.from) == .owner,
               let former = registry.list().first(where: { $0.id == claim.from }), takeFormerRecoveryAttempt(claim.id) {
                do { try pullTransfer(from: former); return }
                catch { fleet.audit("fleet_returning_observer_metadata_pending") }
            }
            // The destination continues pulling the former primary's checkpoint
            // after promotion. The authority exception is scoped to this handoff.
            if let transfer = local.transfer, transfer.to == local.deviceID, !transfer.complete, try !hasRecoveredDispatchSource(),
               let former = registry.list().first(where: { $0.id == transfer.from }) {
                try pullTransfer(from: former)
                return
            }
            if local.role == .primary {
                lock.lock(); defer { lock.unlock() }
                let hashes = try snapshot().mapValues(Self.hash)
                var state = try state()
                state.receipts.removeValue(forKey: "local")
                for peer in registry.list() where state.receipts[peer.id]?.hashes != hashes {
                    state.receipts[peer.id] = Receipt(seq: 0, phase: "pending", hashes: hashes, updated: Date())
                }
                try save(state)
                return
            }
            let peer = try primary()
            inbox.flush()
            let fetched = try fetchFromPrimaryOrCommittedSuccessor(peer)
            let bundle = fetched.1
            let servingPrimary = fetched.0
            guard !inbox.proposals().contains(where: {
                ($0.document == "os" || $0.document == "skillet") && $0.status != "sent"
            }) else { throw Failure(reason: "pending_document_keeps_local_original") }
            let receipt = try apply(bundle, authenticatedPrimary: servingPrimary)
            // apply may promote this device; ACK must still go to the pinned sender.
            _ = try serializedRPC { // W180 E1b
                try send(servingPrimary, method: "dispatch_ack",
                         params: signed(method: "dispatch_ack", payload: Self.object(receipt), recipient: servingPrimary.id))
            }
            try synchronizeManaged()
        } catch {
            lock.lock(); defer { lock.unlock() }
            if var state = try? state() {
                let id = (try? DeviceIdentityStore.readLocal(entry: entry))?.primaryDeviceID ?? "local"
                if id != "local" { state.receipts.removeValue(forKey: "local") }
                var row = state.receipts[id] ?? Receipt(seq: 0, phase: "delivered", hashes: [:], updated: Date())
                // Preserve first failure time, so repeated outages cannot postpone timeout.
                if row.phase == "converged" { row.phase = "delivered"; row.updated = Date() }
                // W211's consistency panel translates these identity/key failures into actionable Chinese.
                if let reason = DeviceFleetReason.code(error),
                   ["authority_unknown", "device_identity_invalidIdentity", "paired_ssh_key_missing", "paired_ssh_signing_unavailable"].contains(reason) {
                    row.detail = reason
                } else {
                    row.detail = DeviceFleetReason.plain(error, context: .operation(device: registry.list().first { $0.id == id }?.name ?? "主設備"))
                }
                state.receipts[id] = row
                try? save(state)
            }
        }
    }

    /// 同一個已 pin 的 SSH／RPC 通道，但方向是 owner -> managed。
    private func synchronizeManaged() throws {
        guard let roster = try fleet.current()?.roster else { return }
        let local = try identity()
        let isPrimary = local.role == .primary && local.primaryDeviceID == local.deviceID
        let retired = try local.transfer.map { try coordinatorRetired($0) } ?? false
        let coordinating = !retired && local.transfer?.committed == true && local.transfer?.from == local.deviceID && local.transfer?.epochComplete == false
        let ownerRelay = try fleet.trust()?.kind == .owner
        guard isPrimary || coordinating || ownerRelay else { return }
        let needsOwnerRosterPush = (isPrimary || coordinating) && local.transfer?.constitution == false
        for member in roster.devices where member.id != (try fleet.trust()?.localID)
            && (member.role == .sandbox || roster.groups.first(where: { $0.id == member.groupID })?.type == .sub
                || (needsOwnerRosterPush && !roster.revoked.contains(member.id))
                || (isPrimary && local.transfer == nil && member.legacy && member.clientKeyFingerprint == nil && member.role == .secondary && roster.kind(of: member.id) == .owner && !roster.revoked.contains(member.id))) {
            var projectionDelivered = false
            var attemptedRevision = roster.version
            do {
                if roster.revoked.contains(member.id) {
                    guard isPrimary, try fleet.claimRevocationDelivery(member.id, now: recoveryNow) else { continue }
                }
                guard let peer = registry.list().first(where: { $0.id == member.id }),
                      let envelope = try fleet.delivery(for: member.id) else { continue }
                attemptedRevision = try JSONDecoder().decode(DeviceFleetPayload.self, from: envelope.body).revision
                let chain = roster.revoked.contains(member.id) ? [] : try fleet.pendingRotationDeliveries(for: member.id)
                let receipt = Receipt(seq: 0, phase: "fleet", hashes: [:], updated: Date(), fleet: envelope,
                                      fleetChain: chain.isEmpty ? nil : chain)
                _ = try serializedRPC {
                    try send(peer, method: "dispatch_ack", params: signed(method: "dispatch_ack",
                        payload: Self.object(receipt), recipient: peer.id),
                        revocationHostKey: roster.revoked.contains(member.id) ? member.hostPublicKey : nil)
                }
                if !roster.revoked.contains(peer.id) { try fleet.recordRotationHistoryDelivered(peer.id) }
                if isPrimary { try fleet.recordManagedDelivery(peer.id, removed: roster.revoked.contains(peer.id), revision: attemptedRevision) }
                projectionDelivered = true
                if roster.revoked.contains(peer.id) { try fleet.finishRevocationDelivery(peer.id) }
                if isPrimary, !roster.revoked.contains(peer.id) {
                    if member.legacy, member.clientKeyFingerprint == nil, roster.kind(of: member.id) == .owner {
                        let response = try serializedRPC { try send(peer, method: "dispatch_fetch", params: signed(method: "dispatch_fetch", payload: ["identityOnly": true], recipient: peer.id)) }
                        let presence = try Self.decode(FleetPresence.self, response)
                        guard presence.deviceID == peer.id, presence.primaryDeviceID == local.deviceID, presence.epoch == local.epoch,
                              presence.role == .secondary, let learned = presence.legacyMember, let fp = learned.clientKeyFingerprint,
                              let host = peer.hostKeyFingerprint else { throw DeviceFleetError.signer }
                        try fleet.pairingTransaction {
                            guard try registry.recordClientFingerprint(id: peer.id, expectedHost: host, fingerprint: fp, source: "fleet_pinned_channel") else { throw DeviceFleetError.keyConflict }
                            try fleet.upgradeLegacySelf(learned, sender: peer.id)
                        }
                        continue
                    }
                    let response = try serializedRPC {
                        try send(peer, method: "dispatch_fetch", params: signed(method: "dispatch_fetch", payload: [:], recipient: peer.id))
                    }
                    let bundle = try Self.decode(Bundle.self, response)
                    if bundle.leaveRequested == true { try fleet.recordLeaveRequest(peer.id) }
                }
            } catch {
                if !projectionDelivered, isPrimary { try? fleet.recordDeliveryProblem(member.id, error: error, revision: attemptedRevision) }
                fleet.audit(projectionDelivered ? "fleet_managed_followup_pending" : "fleet_managed_delivery_pending")
            }
        }
        if (try identity()).role == .primary {
            for row in roster.devices where row.role == .secondary && roster.revoked.contains(row.id)
                && roster.groups.first(where: { $0.id == row.groupID })?.type == .main {
                guard try fleet.claimRevocationDelivery(row.id, now: recoveryNow),
                      let peer = registry.list().first(where: { $0.id == row.id }),
                      let envelope = try fleet.delivery(for: row.id) else { continue }
                let attemptedRevision = try JSONDecoder().decode(DeviceFleetPayload.self, from: envelope.body).revision
                do {
                    let receipt = Receipt(seq: 0, phase: "fleet", hashes: [:], updated: Date(), fleet: envelope)
                    _ = try serializedRPC {
                        try send(peer, method: "dispatch_ack", params: signed(method: "dispatch_ack",
                            payload: Self.object(receipt), recipient: peer.id), revocationHostKey: row.hostPublicKey)
                    }
                    try fleet.finishRevocationDelivery(row.id)
                    try fleet.recordDeliveryProblem(row.id, error: nil, revision: attemptedRevision)
                } catch {
                    try? fleet.recordDeliveryProblem(row.id, error: error, revision: attemptedRevision)
                    fleet.audit("fleet_owner_revocation_delivery_pending")
                }
            }
        }
    }

    /// Explicit confirmation pushes the newly signed roster immediately to reachable members.
    func pushFleetNow() {
        guard let roster = try? fleet.current()?.roster, (try? identity().role) == .primary else { return }
        for member in roster.devices where member.id != roster.primaryID {
            var attemptedRevision = roster.version
            do {
                if roster.revoked.contains(member.id), !(try fleet.claimRevocationDelivery(member.id, now: recoveryNow)) { continue }
                guard let peer = registry.list().first(where: { $0.id == member.id }),
                      let envelope = try fleet.delivery(for: member.id) else { continue }
                attemptedRevision = try JSONDecoder().decode(DeviceFleetPayload.self, from: envelope.body).revision
                let receipt = Receipt(seq: 0, phase: "fleet", hashes: [:], updated: Date(), fleet: envelope)
                _ = try serializedRPC {
                    try send(peer, method: "dispatch_ack", params: signed(method: "dispatch_ack",
                        payload: Self.object(receipt), recipient: peer.id),
                        revocationHostKey: roster.revoked.contains(member.id) ? member.hostPublicKey : nil)
                }
                if roster.revoked.contains(member.id) { try fleet.finishRevocationDelivery(member.id) }
                try fleet.recordDeliveryProblem(member.id, error: nil, revision: attemptedRevision)
            } catch {
                try? fleet.recordDeliveryProblem(member.id, error: error, revision: attemptedRevision)
                fleet.audit("fleet_immediate_delivery_pending")
            }
        }
    }

    // Client proof uses the SAME paired SSH key. Never read/export private key bytes.
    // Forwarded UNIX sockets do not carry SSH client identity; self-reported UUIDs
    // are not authentication. Keychain / the legacy Ed25519 signer are not used.
    func callPrimary(method: String, payload: [String: Any]) throws -> [String: Any] {
        let peer = try primary()
        return try serializedRPC { // W180 E1b：簽章到收到回覆不被別的簽章呼叫插隊
            let proof = try signed(method: method, payload: payload)
            return try send(peer, method: method, params: proof)
        }
    }
    /// W180 E1b：自己簽章、自己送（例如記憶同步推送前用同一條 pin 住的連線問位置）的呼叫也要包在這裡。
    func serializedRPC<T>(_ body: () throws -> T) rethrows -> T {
        assert(!lock.heldByCurrentThread, "Network RPC must never run while holding the dispatch state lock")
        rpcLock.lock(); defer { rpcLock.unlock() }
        return try body()
    }
    func withStateLock<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }
    private func send(_ peer: DeviceRecord, method: String, params: [String: Any],
                      revocationHostKey: String? = nil) throws -> [String: Any] {
        var params = params
        if method == "dispatch_ack", let raw = params["body"] as? String, let data = Data(base64Encoded: raw),
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = body["payload"] as? [String: Any], let wire = payload["fleet"] as? [String: Any],
           let envelope = try? Self.decode(DeviceFleetEnvelope.self, wire),
           let notice = try? JSONDecoder().decode(DeviceFleetPayload.self, from: envelope.body).revocationNotice,
           notice.targetID == peer.id {
            // This signed notice is already self-authenticating against the recipient's cached pin.
            // No outer RPC public key, sender ID, member list or peer endpoint travels to the revoked device.
            params = ["revocation": wire]
        }
        // W221g (lead): keep this pre-check; injected RPC paths skip DeviceFleetGate.call, so it is the only host-pin check there.
        if method == "dispatch_ack", revocationHostKey == nil, let row = try fleet.current()?.roster?.devices.first(where: { $0.id == peer.id }), row.legacy, row.clientKeyFingerprint == nil {
            _ = try DeviceFleetSSHPins.lines(for: peer, registry: registry)
            guard let pin = peer.hostKeyFingerprint, registry.fleetHostPublicKey(fingerprint: pin) != nil else { throw DeviceFleetError.keyConflict }
        }
        if let rpc { return try rpc(peer, method, params) }
        let localFleetID = try fleet.trust()?.localID
        let bootstrap = try DeviceFleetCapabilities.isFleetTransport(method) && revocationHostKey == nil
            && fleet.current()?.roster.map { roster in
                !roster.revoked.contains(peer.id) && roster.devices.contains { $0.legacy && ($0.id == peer.id || $0.id == localFleetID) }
            } == true
        if bootstrap { _ = try DeviceFleetSSHPins.lines(for: peer, registry: registry) }
        if DeviceFleetCapabilities.isFleetTransport(method), !bootstrap, revocationHostKey == nil, try fleet.trust() != nil {
            return try DeviceFleetGate.call(peer: peer, method: method, params: params, registry: registry)
        }
        if method == "device_status", revocationHostKey == nil, try fleet.trust() != nil {
            let handshake = try signedHandshake(method: method, params: params, recipient: peer.id)
            return try DeviceFleetGate.call(peer: peer, method: method, params: params, registry: registry, handshake: handshake)
        }
        if let roster = try fleet.current()?.roster, let localID = try fleet.trust()?.localID,
           try !roster.usesUnrestrictedKey(from: localID, to: peer.id, forRevocation: revocationHostKey != nil) {
            let handshake = OSAgentBridge.signedDeviceMethods.contains(method) ? nil
                : try signedHandshake(method: method, params: params, recipient: peer.id)
            return try DeviceFleetGate.call(peer: peer, method: method, params: params, registry: registry,
                                           revocationKey: revocationHostKey, handshake: handshake)
        }
        var transportEnvironment = environment
        var temporary: URL?
        if let key = revocationHostKey {
            // 撤銷已把本機 known_hosts 移除，但仍可沿這份已簽名單中的原 pin 向被撤銷者送清理。
            // 只建立此呼叫的 0600 暫存檔，不把撤銷鍵加回使用者的 known_hosts。
            guard try DeviceRegistry.fingerprint(publicKey: key) == peer.pinnedHostKeyFingerprint,
                  let normalized = DevicePairingClient.normalizedHostKey(key) else { throw DeviceFleetError.keyConflict }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-revoke-" + UUID().uuidString)
            try DeviceDispatchSafeFile.write(Data("revoked-peer \(normalized)\n".utf8), url: url)
            temporary = url; transportEnvironment["TATWO2_SSH_KNOWN_HOSTS"] = url.path
        }
        if temporary == nil, let key = registry.fleetHostPublicKey(fingerprint: peer.pinnedHostKeyFingerprint) {
            let pin = registry.root.appendingPathComponent("fleet-owner-pin-" + UUID().uuidString)
            try DeviceDispatchSafeFile.write(Data(("tatwo-paired-host " + key + "\n").utf8), url: pin)
            temporary = pin; transportEnvironment["TATWO2_SSH_KNOWN_HOSTS"] = pin.path
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let link = RemoteHostLink(environment: transportEnvironment, revocationCleanup: revocationHostKey != nil)
        return try link.callPinned(device: peer, method: method, params: params)
    }
    func pushSubmission(repository: URL, commit: String, ref: String) throws {
        let peer = try primary()
        let link = RemoteHostLink(environment: environment)
        let target = try serializedRPC { () throws -> [String: Any] in // W180 E1b
            let params = try signed(method: "inbox_target", payload: [:])
            return try rpc?(peer, "inbox_target", params)
                ?? link.callPinned(device: peer, method: "inbox_target", params: params)
        }
        guard let path = target["repository"] as? String, path.hasPrefix("/"), !path.contains("\n") else {
            throw Failure(reason: "invalid_primary_repository")
        }
        if rpc != nil {
            guard let push else { throw Failure(reason: "test_push_not_injected") }
            try push(repository, path, commit, ref)
        } else {
            try link.pushPinned(device: peer, repository: path, localRepository: repository, commit: commit, ref: ref)
        }
    }
    func signedHandshake(method: String, params: [String: Any], recipient: String) throws -> [String: Any] {
        let bytes = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        guard bytes.count <= 16 * 1024 * 1024 else { throw Failure(reason: "rpc_parameters_too_large") }
        return try signed(method: method, payload: ["handshakeVersion": 2, "paramsSHA256": Self.hash(bytes)], recipient: recipient)
    }
    func signed(method: String, payload: [String: Any], recipient: String? = nil) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let local = try identity()
        var state = try state()
        guard state.next < UInt64.max else { throw Failure(reason: "sequence_exhausted") }
        state.next += 1; try save(state)
        var payload = payload
        var detachedBundle: String?
        if method == "memory_sync_import", let encoded = payload["bundle"] as? String {
            guard encoded.utf8.count <= 3 * 1024 * 1024, let bytes = Data(base64Encoded: encoded),
                  bytes.count <= 2 * 1024 * 1024 else { throw Failure(reason: "rpc_parameters_too_large") }
            detachedBundle = encoded
            payload.removeValue(forKey: "bundle"); payload["bundleSHA256"] = Self.hash(bytes)
        }
        let body: [String: Any] = ["method": method, "sender": local.deviceID,
            "recipient": recipient ?? local.primaryDeviceID ?? local.deviceID, "epoch": local.epoch ?? 0, "seq": state.next, "issuedAt": Date().timeIntervalSince1970, "payload": payload]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let key = environment["TATWO2_SSH_KEY_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
        guard FileManager.default.fileExists(atPath: key + ".pub") else { throw Failure(reason: "paired_ssh_key_missing") }
        let publicKey = try String(contentsOfFile: key + ".pub", encoding: .utf8)
        // Prefer the already-unlocked SSH agent using only the public-key path.
        // A noninteractive file-key fallback still uses the same paired key;
        // encrypted/unavailable keys fail closed, never trigger Keychain prompts.
        var result: (Int32, Data) = (1, Data())
        if environment["SSH_AUTH_SOCK"]?.isEmpty == false {
            result = try Self.run("/usr/bin/ssh-keygen",
                ["-Y", "sign", "-f", key + ".pub", "-n", "tatwo2-rpc"], input: data)
        }
        if result.0 != 0 {
            try HandsFiles.ensureDirectory(URL(fileURLWithPath: key).deletingLastPathComponent())
            try HandsFiles.restrictOwnedFile(URL(fileURLWithPath: key))
            result = try Self.run("/usr/bin/ssh-keygen",
                ["-Y", "sign", "-f", key, "-P", "", "-n", "tatwo2-rpc"], input: data)
        }
        guard result.0 == 0 else { throw Failure(reason: "paired_ssh_signing_unavailable") }
        var proof: [String: Any] = ["body": data.base64EncodedString(), "signature": result.1.base64EncodedString(), "publicKey": publicKey]
        if let detachedBundle { proof["bundle"] = detachedBundle }
        return proof
    }
    /// The one base64 bundle is outside the base64 signature body, but its digest, method,
    /// recipient, epoch and sequence remain authenticated. Older inline proofs still verify.
    private func authenticatedPayload(method: String, payload: [String: Any], proof: [String: Any]) throws -> [String: Any] {
        guard method == "memory_sync_import", payload["bundleSHA256"] != nil else {
            guard proof["bundle"] == nil else { throw Failure(reason: "invalid_memory_bundle") }
            return payload
        }
        guard Set(payload.keys) == ["bundleSHA256", "commit", "ref"],
              let expected = payload["bundleSHA256"] as? String,
              let encoded = proof["bundle"] as? String, encoded.utf8.count <= 3 * 1024 * 1024,
              let bytes = Data(base64Encoded: encoded), bytes.count <= 2 * 1024 * 1024,
              Self.hash(bytes) == expected else { throw Failure(reason: "invalid_memory_bundle") }
        var restored = payload; restored.removeValue(forKey: "bundleSHA256"); restored["bundle"] = encoded
        return restored
    }
    private func consumeRPC(_ state: inout State, key: String, epoch: Int, sequence: UInt64,
                            issuedAt: Double?, authorityEpoch: Int, now: Date = Date()) throws {
        guard let issuedAt, issuedAt.isFinite,
              abs(now.timeIntervalSince1970 - issuedAt) <= 120 else {
            throw Failure(reason: "rpc_proof_expired")
        }
        let id = key + ":" + String(epoch)
        var windows = state.rpcWindows ?? [:]
        // Pre-window RPC proofs have no issuedAt and are refused above. The received bundle ledger
        // belongs to a different inbound stream; seeding from it rejects the first reordered handshake.
        var window = windows[id] ?? ReplayWindow()
        try window.consume(sequence)
        windows[id] = window
        // Retain replay evidence for the bounded historical recovery chain as well.
        // An authenticated rotation can be in flight before recordACK advances the fleet journal.
        // A concurrent old-epoch call must not forget its consumed proof; keep the live authority window too.
        let currentEpoch = windows.keys.reduce(max(state.epoch, epoch)) { highest, key in
            max(highest, key.split(separator: ":").last.flatMap { Int($0) } ?? 0)
        }
        windows = windows.filter { item in
            guard let value = item.key.split(separator: ":").last.flatMap({ Int($0) }) else { return false }
            return value == authorityEpoch || (value >= max(0, currentEpoch - 16) && value <= currentEpoch)
        }
        state.rpcWindows = windows
    }
    func authenticate(method: String, proof: [String: Any]) throws -> (String, [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        if method == "dispatch_ack", Set(proof.keys) == ["revocation"],
           let wire = proof["revocation"] as? [String: Any], let trust = try fleet.trust() {
            var notice = try Self.decode(DeviceFleetEnvelope.self, wire)
            guard notice.publicKey.isEmpty, notice.handoff == nil, notice.rotationCommit == nil,
                  let cachedKey = try fleet.read().envelope?.publicKey,
                  try DeviceRegistry.fingerprint(publicKey: cachedKey) == trust.pinnedPrimaryKey,
                  registry.fleetHasAuthorizedFingerprint(trust.pinnedPrimaryKey) else { throw Failure(reason: "untrusted_revocation_notice") }
            notice.publicKey = cachedKey
            let payload = try notice.verified(trust: trust)
            guard let target = payload.revocationNotice, target.targetID == trust.localID,
                  target.revision > (try fleet.current()?.revision ?? 0) else { throw DeviceFleetError.replay }
            let receipt = Receipt(seq: 0, phase: "fleet", hashes: [:], updated: Date(), fleet: try Self.decode(DeviceFleetEnvelope.self, wire))
            return (trust.kind == .owner ? trust.primaryID : DeviceFleetStore.controllerID(trust.pinnedPrimaryKey), try Self.object(receipt))
        }
        if let trust = try fleet.trust(), trust.kind != .owner {
            return try authenticateController(method: method, proof: proof, trust: trust)
        }
        let local = try identity()
        let handoff = local.transfer.flatMap { $0.from == local.deviceID ? $0 : nil }
        let handoffMethod = method == "dispatch_fetch" || method == "dispatch_ack"
        let transferredMemory = method.hasPrefix("memory_sync_") && local.role == .secondary
            && handoff?.committed == true && handoff?.to == local.primaryDeviceID
        let handshakeTrust = try fleet.trust()
        let legacyPhase: String? = {
            guard method == "dispatch_ack", let raw = proof["body"] as? String, let data = Data(base64Encoded: raw), data.count <= 16 * 1024 * 1024,
                  let claim = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return (claim["payload"] as? [String: Any])?["phase"] as? String
        }()
        let legacyFleetPush = local.role == .secondary && method == "dispatch_ack" && handshakeTrust == nil && legacyPhase == "fleet"
        if legacyFleetPush, registry.list().first(where: { $0.id == local.primaryDeviceID })?.clientKeyFingerprint == nil {
            throw Failure(reason: "fleet_legacy_repair_required")
        }
        let ownerFleetPush: Bool
        if local.role == .secondary, method == "dispatch_ack", (handshakeTrust?.kind == .owner || legacyFleetPush) {
            ownerFleetPush = true
        } else { ownerFleetPush = false }
        let ownerHandshake = (handshakeTrust?.kind == .owner || handshakeTrust == nil) && !OSAgentBridge.signedDeviceMethods.contains(method)
        let ownerPresence: Bool
        if method == "dispatch_fetch", let raw = proof["body"] as? String,
           let bytes = Data(base64Encoded: raw), bytes.count <= 16 * 1024 * 1024,
           let claimed = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let payload = claimed["payload"] as? [String: Any] {
            ownerPresence = Set(payload.keys) == ["identityOnly"] && payload["identityOnly"] as? Bool == true
        } else { ownerPresence = false }
        guard (local.role == .primary || (handoff != nil && handoffMethod) || transferredMemory || ownerFleetPush || ownerHandshake || ownerPresence),
              let raw = proof["body"] as? String, let data = Data(base64Encoded: raw), data.count <= 16 * 1024 * 1024,
              let sig = proof["signature"] as? String, let signature = Data(base64Encoded: sig), signature.count < 8192,
              let publicKey = proof["publicKey"] as? String,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["method"] as? String == method, body["recipient"] as? String == local.deviceID,
              let sender = body["sender"] as? String,
              let peer = registry.list().first(where: { $0.id == sender }),
              // RPC 簽章只認對方的客戶端金鑰。分流過的紀錄若缺這把（例如自己是加入端，
              // 手上只有對方的主機金鑰）就當作沒配對，直接拒絕，不退回用另一把。
              let pinnedClientKey = peer.pinnedClientKeyFingerprint,
              try DeviceRegistry.fingerprint(publicKey: publicKey) == pinnedClientKey,
              let epoch = body["epoch"] as? Int, let seq = body["seq"] as? UInt64,
              let payload = body["payload"] as? [String: Any]
        else { throw Failure(reason: "untrusted_rpc_sender") }
        if ownerFleetPush && !(handoffMethod && handoff?.participants.contains(sender) == true) {
            guard sender == local.primaryDeviceID, payload["phase"] as? String == "fleet" else {
                throw Failure(reason: "untrusted_fleet_push")
            }
        }
        try fleet.requireOwnerMember(sender)
        let authorized = try String(contentsOf: registry.authorizedKeysURL, encoding: .utf8)
        let components = publicKey.split(whereSeparator: \.isWhitespace)
        guard components.count >= 2, !publicKey.contains("\r"),
              authorized.components(separatedBy: "\n").contains(where: { line in
                  let fields = line.split(whereSeparator: \.isWhitespace)
                  guard let index = fields.firstIndex(of: components[0]), index + 1 < fields.count else { return false }
                  return fields[index + 1] == components[1]
              }) else { throw Failure(reason: "revoked_rpc_key") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("w78-proof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let allowed = scratch.appendingPathComponent("allowed"), signatureFile = scratch.appendingPathComponent("signature")
        try Data("paired \(components[0]) \(components[1])\n".utf8).write(to: allowed)
        try signature.write(to: signatureFile)
        let result = try Self.run("/usr/bin/ssh-keygen", ["-Y", "verify", "-f", allowed.path,
            "-I", "paired", "-n", "tatwo2-rpc", "-s", signatureFile.path], input: data)
        guard result.0 == 0 else { throw Failure(reason: "invalid_ssh_proof") }
        if transferredMemory { throw Failure(reason: "primary_transferred") }
        if try fleet.trust() != nil,
           try !fleet.methodAllowed(fingerprint: pinnedClientKey, method: method) {
            fleet.audit("fleet_rpc_capability_refused")
            throw Failure(reason: "fleet_capabilityDenied")
        }
        var state = try state()
        let transfer = local.transfer
        let pendingHandoff = handoffMethod && transfer?.participants.contains(sender) == true
            && epoch == transfer?.oldEpoch && transfer?.committed == true && transfer?.epochComplete == false
            && (transfer?.from == local.deviceID || transfer?.to == local.deviceID)
        let roster = try fleet.current()?.roster
        let historicalReturn = roster?.kind(of: sender) == .owner && roster?.revoked.contains(sender) == false
            && (transfer?.skippedParticipants?.contains(sender) == true || roster?.rotationHistory?[sender]?.isEmpty == false)
        let observedNewerEpoch = (state.rpcWindows ?? [:]).keys.contains { key in
            key.hasPrefix(pinnedClientKey + ":") && (key.split(separator: ":").last.flatMap { Int($0) } ?? 0) > epoch
        }
        let returningFetch = method == "dispatch_fetch" && payload.isEmpty && historicalReturn
            && local.role == .primary && transfer?.committed == true && transfer?.to == local.deviceID
            && epoch > 0 && epoch < (local.epoch ?? 0) && epoch >= max(1, (local.epoch ?? 0) - 16)
            && !observedNewerEpoch
        guard ((epoch == (local.epoch ?? 0) && epoch >= state.epoch) || pendingHandoff || returningFetch),
              seq > 0 else {
            if method == "dispatch_fetch", payload.isEmpty, local.role == .secondary,
               let handoff, handoff.committed, handoff.to == local.primaryDeviceID,
               epoch > 0, epoch < (local.epoch ?? 0) {
                throw Failure(reason: "primary_transferred")
            }
            throw Failure(reason: "stale_epoch_or_replayed_sequence")
        }
        let authenticated = try authenticatedPayload(method: method, payload: payload, proof: proof)
        if legacyFleetPush {
            let receipt = try Self.decode(Receipt.self, authenticated)
            guard let envelope = receipt.fleet, receipt.fleetMembers == nil, receipt.transfer == nil, receipt.fleetChain == nil else { throw Failure(reason: "untrusted_fleet_push") }
            _ = try fleet.legacyPushTrust(envelope, sender: sender)
        }
        try consumeRPC(&state, key: pinnedClientKey, epoch: epoch, sequence: seq,
                       issuedAt: body["issuedAt"] as? Double, authorityEpoch: local.epoch ?? 0)
        state.epoch = max(state.epoch, local.epoch ?? 0); try save(state)
        // 簽章驗過（且金鑰仍在 authorized_keys）之後才補記這把客戶端金鑰的來源與時間。
        // 補記不影響上面的判斷；值不同 recordFingerprint 會拒絕，不會覆蓋已 pin 的指紋。
        if let verified = try? DeviceRegistry.fingerprint(publicKey: publicKey) {
            _ = try? registry.recordFingerprint(
                id: sender, role: .client, fingerprint: verified, source: "rpc_proof")
        }
        if let transfer = local.transfer, transfer.committed, transfer.from == local.deviceID,
           transfer.participants.contains(sender) {
            try fleet.noteTransferContact(transfer: transfer.id, peer: sender, reached: true)
        }
        return (sender, authenticated)
    }

    private func authenticateController(method: String, proof: [String: Any], trust: DeviceFleetTrust) throws -> (String, [String: Any]) {
        guard DeviceFleetCapabilities.required(for: method) != nil,
              let raw = proof["body"] as? String, let data = Data(base64Encoded: raw), data.count <= 16 * 1024 * 1024,
              let sig = proof["signature"] as? String, let signature = Data(base64Encoded: sig), signature.count < 8192,
              let publicKey = proof["publicKey"] as? String,
              let fingerprint = try? DeviceRegistry.fingerprint(publicKey: publicKey),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["method"] as? String == method, payload["recipient"] as? String == trust.localID,
              let epoch = payload["epoch"] as? Int, let sender = payload["sender"] as? String,
              let seq = payload["seq"] as? UInt64, let content = payload["payload"] as? [String: Any],
              DeviceSignature.verify(body: data, signature: signature, publicKey: publicKey, namespace: "tatwo2-rpc") else {
            fleet.audit("fleet_untrusted_controller"); throw Failure(reason: "untrusted_rpc_controller")
        }
        let rotationPush = try epoch != trust.epoch && method == "dispatch_ack" && content["phase"] as? String == "fleet"
            && (fleet.allowsRotationTransport(content: content, fingerprint: fingerprint, epoch: epoch))
        let ordinary = try registry.fleetHasAuthorizedFingerprint(fingerprint)
            && fleet.methodAllowed(fingerprint: fingerprint, method: method)
        guard ordinary || rotationPush else { throw Failure(reason: "untrusted_rpc_controller") }
        guard epoch == trust.epoch || rotationPush else { throw Failure(reason: "stale_controller_epoch") }
        let authenticated = try authenticatedPayload(method: method, payload: content, proof: proof)
        var state = try state()
        // 用簽章指紋當防重放身份，不能換個自報 UUID 重用序號。
        try consumeRPC(&state, key: fingerprint, epoch: epoch, sequence: seq,
                       issuedAt: payload["issuedAt"] as? Double, authorityEpoch: trust.epoch)
        try save(state)
        if let peer = try fleet.current()?.slice?.devices.first(where: { $0.clientKeyFingerprint == fingerprint }) {
            guard peer.id == sender else { throw Failure(reason: "controller_identity_mismatch") }
            return (peer.id, authenticated)
        }
        // External MAIN controllers are deliberately anonymous in a SUB's registry.
        return (DeviceFleetStore.controllerID(fingerprint), authenticated)
    }
    /// W162：設定 › OS 的跨設備總表——向已配對設備要 device_status（走已 pin 的 SSH），拿不到回 nil。
    func peerStatus(_ peer: DeviceRecord) -> DeviceStatusSnapshot? {
        (try? send(peer, method: "device_status", params: [:])).flatMap { try? DeviceStatusSnapshot.decode($0) }
    }
    func transferEvidence() -> PrimaryTransfer.Evidence {
        evidence?() ?? PrimaryTransfer.evidence(entry: entry)
    }
    struct FleetPresence: Codable {
        var deviceID: String
        var role: DeviceRole
        var epoch: Int?
        var primaryDeviceID: String?
        var transferID: String?
        var sourceRecovered: Bool? = nil
        var coordinatorRetired: Bool? = nil
        var legacyMember: DeviceFleetMember? = nil
    }
    func localFleetPresence() throws -> FleetPresence {
        let local = try identity()
        try fleet.requireOwner()
        return .init(deviceID: local.deviceID, role: local.role, epoch: local.epoch,
                     primaryDeviceID: local.primaryDeviceID, transferID: local.transfer?.id,
                     sourceRecovered: try hasRecoveredDispatchSource(),
                     coordinatorRetired: try local.transfer.map { try coordinatorRetired($0) },
                     legacyMember: try fleet.current()?.roster?.devices.first(where: { $0.id == local.deviceID })?.legacy == true ? fleet.syncMember() : nil)
    }
    func transferPresence(_ peer: DeviceRecord) throws -> FleetPresence {
        if try fleet.trust() == nil {
            let remote = try transferIdentity(peer)
            return .init(deviceID: remote.deviceID, role: remote.role, epoch: remote.epoch,
                         primaryDeviceID: remote.primaryDeviceID, transferID: remote.transfer?.id)
        }
        return try serializedRPC {
            let proof = try signed(method: "dispatch_fetch", payload: ["identityOnly": true], recipient: peer.id)
            return try Self.decode(FleetPresence.self, send(peer, method: "dispatch_fetch", params: proof))
        }
    }
    func transferIdentity(_ peer: DeviceRecord) throws -> DeviceIdentity {
        let snapshot = try DeviceStatusSnapshot.decode(send(peer, method: "device_status", params: [:]))
        guard let identity = snapshot.identity.value,
              DeviceStatusPolicy.fresh(snapshot.identity.acquiredAt, now: Date()) else {
            throw Failure(reason: "transfer_identity_stale")
        }
        return identity
    }
    func beginTransfer(to target: String, signingName: String) throws {
        // This method is the existing DevicesPage confirmationDialog action, not an RPC method.
        // Remote request Booleans and fleet.confirm() never mint this non-Codable authority.
        do {
            let confirmation = try lock.withLock {
                try fleet.requireOwner()
                return try fleet.trust() == nil ? nil
                    : DeviceFleetLocalTransferConfirmation.forLocalUI(target: target, local: identity())
            }
            try PrimaryTransfer.retryCheckpoint {
                try PrimaryTransfer.begin(self, to: target, signingName: signingName, confirmation: confirmation)
            }
        } catch { fleet.audit(error, fallback: "fleet_transfer_begin_refused"); throw error }
    }
    func updateTransfer(constitution: Bool = false, brain: PrimaryTransfer.Brain? = nil,
                        release: Bool = false, signingName: String? = nil) throws {
        if constitution, brain == nil, !release, signingName == nil, try identity().transfer?.constitution == true { return }
        if constitution, brain == nil, !release, signingName == nil,
           let transfer = try identity().transfer, transfer.to == (try identity()).deviceID {
            try recoverDispatchSource(); return
        }
        let intended = try identity().transfer
        try PrimaryTransfer.retryCheckpoint {
            try PrimaryTransfer.update(self, constitution: constitution, brain: brain, release: release, signingName: signingName, expectedTransfer: intended)
        }
    }
    func coordinatorRetired(_ record: PrimaryTransfer.Record) throws -> Bool {
        try lock.withLock { try state().retiredCoordinatorTransfer == record.id }
    }
    func hasRecoveredDispatchSource() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Self.hasRecoveredDispatchSource(try identity())
    }
    static func hasRecoveredDispatchSource(_ local: DeviceIdentity?) -> Bool {
        guard let local, local.role == .primary, local.primaryDeviceID == local.deviceID,
              let transfer = local.transfer, transfer.committed, transfer.to == local.deviceID,
              local.epoch == transfer.epoch else { return false }
        // The frozen snapshot is checked at physical authorization. Subsequent edits belong to this new primary.
        return transfer.localVerification == true
    }
    /// Existing physical transfer card only; no RPC method can authorize recovery.
    private func recoverDispatchSource() throws {
        func checkpoint() throws -> (DeviceIdentity, PrimaryTransfer.Record) {
            let local = try identity()
            try fleet.requireOwner()
            guard local.role == .primary, local.primaryDeviceID == local.deviceID,
                  let record = local.transfer, record.committed, record.to == local.deviceID,
                  local.epoch == record.epoch, let rotation = try fleet.rotation(),
                  try rotation.handoff.claim.id == record.id,
                  try transferHashes() == Self.frozen(record.hashes) else { throw Failure(reason: "凍結時的正本雜湊或移交身分不符，不能恢復正本派發。") }
            return (local, record)
        }
        let captured: (DeviceIdentity, PrimaryTransfer.Record)? = try lock.withLock {
            if try hasRecoveredDispatchSource() { return nil }
            return try checkpoint()
        }
        guard let captured else { return }
        let record = captured.1
        let revoked = try fleet.current()?.roster?.revoked.contains(record.from) == true
        if !revoked {
            guard let old = registry.list().first(where: { $0.id == record.from }) else { throw Failure(reason: PrimaryTransfer.coordinatorAbsenceUnproven) }
            // No state mutex is held across this RPC; the authenticated absence cannot deadlock reciprocal probes.
            do { _ = try transferPresence(old); throw Failure(reason: "舊主設備在線，請到舊主設備繼續②比對雜湊；只有舊主失聯或被撤銷時，才需要在這裡恢復。") }
            catch { guard PrimaryTransfer.failedContact(error) else { if let failure = error as? Failure, !failure.reason.allSatisfy(\.isASCII) { throw failure }; throw DeviceFleetReason.ProbedError(error: error, record: record, probed: .source) } }
        }
        try lock.withLock {
            if try hasRecoveredDispatchSource() { return }
            let current = try checkpoint()
            guard current.0.deviceID == captured.0.deviceID, current.1.id == record.id,
                  current.1.epoch == record.epoch else { throw Failure(reason: "檢查期間主設備身分已變更，請重新確認移交。") }
            var recovered = current.1
            recovered.constitution = true; recovered.sourceDeviceID = recovered.to; recovered.sourceRoot = entry.root.path
            recovered.targetRoot = entry.root.path; recovered.localVerification = true
            recovered.epochACKs = Array(Set(recovered.epochACKs + [recovered.to])).sorted()
            recovered.revision += 1; recovered.constitutionRevision = recovered.revision
            try PrimaryTransfer.save(recovered, dispatch: self)
            fleet.audit("fleet_transfer_local_source_recovered_checkpoints_remain_pending")
        }
    }
    /// Pure verification: no journal/identity/key mutation until every hop and the latest document roster is authenticated.
    private func verifiedOwnerRecovery(_ bundle: Bundle, trust: DeviceFleetTrust) throws -> [DeviceFleetEnvelope] {
        guard trust.kind == .owner, let final = bundle.fleet, let current = try fleet.current(),
              var previous = current.roster else { throw DeviceFleetError.signature }
        let chain = bundle.fleetChain ?? [final]
        guard chain.count <= 16, chain.reduce(final.body.count, { $0 + $1.body.count }) <= 2 * 1024 * 1024 else {
            throw Failure(reason: "rotation_history_requires_local_pairing")
        }
        var pin = trust, revision = current.revision, commits: [DeviceFleetEnvelope] = []
        for proof in chain {
            let proposed = try JSONDecoder().decode(DeviceFleetPayload.self, from: proof.body).epoch
            if proposed <= pin.epoch { continue } // Historical prefix can never roll back the current pin.
            guard let handoff = proof.handoff else { throw DeviceFleetError.signature }
            let claim = try handoff.verified(pin, revision: revision)
            try fleet.verifyRotationCommit(proof, handoff: handoff, targetID: "MAIN")
            var next = pin; next.primaryID = claim.to; next.epoch = claim.epoch; next.pinnedPrimaryKey = claim.newKey
            let payload = try proof.verified(trust: next)
            guard payload.rotationDigest == handoff.digest, payload.revision == claim.version + 1,
                  let roster = payload.roster,
                  DeviceFleetHandoff.hash(try DeviceFleetHandoff.bytes(roster)) == claim.nextRosterHash,
                  previous.kind(of: claim.to) == .owner,
                  previous.devices.first(where: { $0.id == claim.to })?.legacy == false else { throw DeviceFleetError.signature }
            try roster.validateTransition(from: previous)
            pin = next; revision = payload.revision; previous = roster; commits.append(proof)
        }
        let payload = try final.verified(trust: pin)
        guard pin.epoch == bundle.epoch, pin.primaryID == bundle.sender, payload.revision >= revision,
              let roster = payload.roster, roster.kind(of: trust.localID) == .owner,
              !roster.revoked.contains(trust.localID) else { throw DeviceFleetError.signature }
        try roster.validateTransition(from: previous)
        return commits
    }
    private func fetchFromPrimaryOrCommittedSuccessor(_ incumbent: DeviceRecord) throws -> (DeviceRecord, Bundle) {
        func fetch(_ peer: DeviceRecord) throws -> Bundle {
            try Self.decode(Bundle.self, serializedRPC {
                try send(peer, method: "dispatch_fetch", params: signed(method: "dispatch_fetch", payload: [:], recipient: peer.id))
            })
        }
        do {
            let bundle = try fetch(incumbent)
            lock.withLock { recoveryScanFailures = 0; recoveryScanAfter = .distantPast }
            return (incumbent, bundle)
        } catch {
            let failure = error
            let reason = DeviceFleetReason.code(failure) ?? ""
            let transferred = ["primary_transferred", "not_primary"].contains(reason)
            let appClosed = (failure as? DeviceFleetGate.CallError) == .appUnavailable
            // Discovery never adopts authority without the complete dual-signed chain.
            let obsoleteIncumbent = (failure as? DeviceFleetError) == .signature
                || ["untrusted_rpc_sender", "revoked_rpc_key", "stale_epoch_or_replayed_sequence"].contains(reason)
            guard PrimaryTransfer.failedContact(failure) || transferred || appClosed || obsoleteIncumbent, let trust = try fleet.trust(), trust.kind == .owner,
                  let roster = try fleet.current()?.roster else { throw failure }
            let scan = lock.withLock { () -> Bool in
                if appClosed, recoveryScanFailures == 0, recoveryScanAfter == .distantPast {
                    recoveryScanAfter = recoveryNow.addingTimeInterval(20); return false
                }
                guard recoveryNow >= recoveryScanAfter else { return false }
                // Six attempts form a bounded batch, followed by ten minutes of
                // quiet. A sleeping successor can return after any number of batches.
                if recoveryScanFailures >= 6 { recoveryScanFailures = 0 }
                recoveryScanFailures += 1
                recoveryScanAfter = recoveryNow.addingTimeInterval(recoveryScanFailures == 6 ? 600 : 10 * pow(2, Double(recoveryScanFailures)))
                return true
            }
            guard scan else { throw failure }
            for candidate in registry.list() where candidate.id != incumbent.id && roster.kind(of: candidate.id) == .owner
                && !roster.revoked.contains(candidate.id) {
                do {
                    let bundle = try fetch(candidate)
                    guard bundle.epoch > trust.epoch, bundle.sender == candidate.id else { continue }
                    _ = try verifiedOwnerRecovery(bundle, trust: trust)
                    return (candidate, bundle)
                } catch { continue }
            }
            throw failure
        }
    }
    private func takeFormerRecoveryAttempt(_ transfer: String) -> Bool {
        lock.withLock {
            let budget = formerRecoveryAttempts[transfer] ?? (count: 0, after: Date.distantPast)
            guard budget.count < 6, recoveryNow >= budget.after else { return false }
            let count = budget.count + 1
            formerRecoveryAttempts = [transfer: (count, recoveryNow.addingTimeInterval(min(600, 10 * pow(2, Double(count)))))]
            return true
        }
    }
    func cancelPreparedTransfer() throws {
        lock.lock(); defer { lock.unlock() }
        if try fleet.trust() == nil { try PrimaryTransfer.cancelPrepared(self); return }
        try fleet.requireOwner()
        var local = try identity()
        guard local.role == .primary, let record = local.transfer, record.from == local.deviceID,
              !record.committed, local.epoch == record.oldEpoch else { throw DeviceFleetError.epoch }
        let previous = try fleet.rotation()?.previousIdentityTransfer
        try fleet.cancelRotation(record)
        local.transfer = previous; local.updatedAt = Date()
        try DeviceIdentityStore.forLocalDevice(entry: entry, pairedDeviceID: local.deviceID).write(local)
    }
    func pullTransfer(from peer: DeviceRecord) throws {
        let response = try serializedRPC { // W180 E1b
            try send(peer, method: "dispatch_fetch",
                     params: signed(method: "dispatch_fetch", payload: [:], recipient: peer.id))
        }
        let receipt = try apply(Self.decode(Bundle.self, response), authenticatedPrimary: peer)
        _ = try serializedRPC { // W180 E1b
            try send(peer, method: "dispatch_ack",
                     params: signed(method: "dispatch_ack", payload: Self.object(receipt), recipient: peer.id))
        }
    }
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    directory: URL? = nil) throws -> (Int32, Data) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.environment?["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment?["SSH_ASKPASS"] = "/usr/bin/false"
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        var temporary: URL?, handle: FileHandle?
        if let input {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("w78-input-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            temporary = folder
            let url = folder.appendingPathComponent("input")
            try input.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            handle = try FileHandle(forReadingFrom: url); process.standardInput = handle
        } else { process.standardInput = FileHandle.nullDevice }
        defer { try? handle?.close(); if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try process.run()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + 10)
        deadline.setEventHandler { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        deadline.resume()
        defer { deadline.cancel() }
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
