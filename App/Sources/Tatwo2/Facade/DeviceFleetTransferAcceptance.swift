#if DEBUG
import AppKit
import Darwin
import Foundation

/// Real signatures + production W83 transport. Fake sessions; only owned /bin/sleep children are killed.
enum DeviceFleetTransferAcceptance {
    /// Protect fixture routing/failure state while production delivery work runs on its own queue.
    final class FixtureNetwork: @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [String: DeviceDispatch] = [:]
        private var dropNextACK = false
        subscript(id: String) -> DeviceDispatch? {
            get { lock.withLock { peers[id] } }
            set { lock.withLock { peers[id] = newValue } }
        }
        func removeValue(forKey id: String) -> DeviceDispatch? { lock.withLock { peers.removeValue(forKey: id) } }
        func loseACK() { lock.withLock { dropNextACK = true } }
        func consumeLostACK() -> Bool {
            lock.withLock { let value = dropNextACK; dropNextACK = false; return value }
        }
    }
    static func run(root: URL) throws {
        let fm = FileManager.default
        var checks = 0
        func check(_ label: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187TRANSFER_FAIL_" + label) }
            checks += 1; print("W187TRANSFER PASS " + label)
        }
        func rejects(_ label: String, expected: DeviceFleetError? = nil, _ action: () throws -> Void) throws {
            do { try action() } catch {
                if let expected, error as? DeviceFleetError != expected { throw error }
                checks += 1; print("W187TRANSFER PASS " + label); return
            }
            throw DeviceDispatch.Failure(reason: "W187TRANSFER_UNEXPECTED_ACCEPT_" + label)
        }
        try check("XFER-01-authentication-failure-is-not-device-absence", !PrimaryTransfer.failedContact(RemoteHostLinkError.tunnelStartFailed("Permission denied (publickey).")))
        try check("XFER-01-local-socket-failure-is-not-device-absence", !PrimaryTransfer.failedContact(RemoteHostLinkError.connectFailed(ECONNREFUSED)))
        try check("XFER-01-specific-SSH-connect-failure-counts-as-absence", PrimaryTransfer.failedContact(DeviceFleetGate.CallError.unreachable))
        try check("XFER-01-SSH-connect-refused-is-specific-absence", DeviceFleetGate.isSSHUnreachable(status: 255, diagnostics: "ssh: connect to host 192.0.2.9 port 22: Connection refused\n"))
        try check("XFER-01-SSH-authentication-refused-is-online", !DeviceFleetGate.isSSHUnreachable(status: 255, diagnostics: "Permission denied (publickey).\n"))
        try check("XFER-01-authenticated-command-error-is-online", !DeviceFleetGate.isSSHUnreachable(status: 255, diagnostics: "Authenticated to 192.0.2.9\nssh: connect to host 192.0.2.9 port 22: Connection refused\n"))
        try check("XFER-01-remote-error-text-cannot-claim-device-absence", !PrimaryTransfer.failedContact(DeviceDispatch.Failure(reason: "fleet_ssh_endpoint_unreachable")))
        let unreachable = DeviceFleetGate.CallError.unreachable
        try check("XFER-01-reachable-endpoint-wins-over-later-offline-endpoint", !PrimaryTransfer.failedContact(DeviceFleetGate.rpcFailure([unreachable, DeviceFleetError.signature, unreachable])))
        try check("XFER-01-all-endpoints-unreachable-count-as-absence", PrimaryTransfer.failedContact(DeviceFleetGate.rpcFailure([unreachable, unreachable])))
        try check("XFER-01-no-endpoint-attempt-is-not-absence", !PrimaryTransfer.failedContact(DeviceFleetGate.rpcFailure([])))
        let ids = (1...5).map { String(format: "%08x-3333-4333-8333-333333333333", $0) }
        var fixtures: [DeviceFleetGraphAcceptance.Fixture] = []
        for index in 0..<5 {
            let base = root.appendingPathComponent("transfer-fixture-\(index)")
            let entry = TatwoEntry(environment: ["TATWO_OS_ROOT": base.appendingPathComponent("entry").path], preference: nil)
            try fm.createDirectory(at: entry.root, withIntermediateDirectories: true)
            try Data("fixture constitution\n".utf8).write(to: entry.constitution)
            try Data("fixture skills\n".utf8).write(to: entry.skillet)
            let client = base.appendingPathComponent("client").path, host = base.appendingPathComponent("host").path
            for key in [client, host] {
                guard try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", key]).0 == 0 else {
                    throw DeviceFleetError.missingKey
                }
            }
            let environment = ["TATWO_OS_ROOT": entry.root.path, "TATWO2_LIVE_ROOT": base.appendingPathComponent("live").path,
                "TATWO2_AUTHORIZED_KEYS": base.appendingPathComponent("authorized_keys").path,
                "TATWO2_SSH_KNOWN_HOSTS": base.appendingPathComponent("known_hosts").path,
                "TATWO2_SSH_KEY_PATH": client, "TATWO2_SSH_HOST_KEY_PUB": host + ".pub"]
            let clientKey = try String(contentsOfFile: client + ".pub", encoding: .utf8)
            let hostKey = try String(contentsOfFile: host + ".pub", encoding: .utf8)
            let member = DeviceFleetMember(id: ids[index], name: "fixture-\(index)", factionID: index == 3 ? "sub" : "main",
                role: index == 0 || index == 3 ? .primary : index == 4 ? .sandbox : .secondary,
                clientKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: clientKey),
                hostKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: hostKey), clientPublicKey: clientKey,
                hostPublicKey: hostKey, endpoints: [.init(kind: .lan, host: "192.0.2.\(index + 1)")], user: "fixture")
            try DeviceIdentity(deviceID: member.id, name: member.name, hardwareModel: "fixture",
                role: index == 0 ? .primary : .secondary, epoch: 1, primaryDeviceID: ids[0], updatedAt: Date()).encoded().write(to: entry.deviceJSON)
            let registry = DeviceRegistry(environment: environment)
            let fleet = DeviceFleetStore(registry: registry, environment: environment)
            fixtures.append(.init(member: member, registry: registry, environment: environment, fleet: fleet))
        }
        let preserveUserLines = ProcessInfo.processInfo.environment["TATWO2_W221C_TRANSFER"] == "1"
        let unmanaged = try fixtures.map { fixture -> Data in
            guard preserveUserLines else { return Data() }
            let text = fixture.member.clientPublicKey! + " user-owned\r\n\r\n"
            let data = Data(text.utf8)
            try data.write(to: fixture.registry.authorizedKeysURL)
            return data
        }
        let a = fixtures[0], b = fixtures[1], c = fixtures[2], p = fixtures[3], s = fixtures[4]
        let groups = [DeviceFleetGroup(id: "main", name: "example MAIN", type: .main, primaryDeviceID: ids[0], managerDisplayName: "example"),
            DeviceFleetGroup(id: "sub", name: "example SUB", type: .sub, primaryDeviceID: ids[3], parentGroupID: "main", managerDisplayName: "example")]
        let members = fixtures.map(\.member)
        let roster = DeviceFleetRoster(version: 1, primaryID: ids[0], epoch: 1, groups: groups, devices: members,
            edges: DeviceFleetRoster.defaults(groups: groups, devices: members))
        for (index, fixture) in fixtures.enumerated() {
            let trust = DeviceFleetTrust(localID: ids[index], primaryID: ids[0], epoch: 1, pinnedPrimaryKey: a.member.clientKeyFingerprint!,
                kind: index == 3 ? .managed : index == 4 ? .sandbox : .owner)
            let state = try JSONSerialization.data(withJSONObject: ["trust": DeviceDispatch.object(trust), "pending": [], "confirmations": [],
                "leaving": false, "managedRemoved": [], "leaveRequests": [], "controllerHistory": []])
            try DeviceDispatchSafeFile.write(state, url: fixture.fleet.url)
            let payload: DeviceFleetPayload = index < 3 ? .init(roster: roster) : .init(slice: try roster.slice(for: ids[index]))
            try fixture.fleet.accept(DeviceFleetEnvelope.issue(payload, environment: a.environment))
            if let slice = try fixture.fleet.pendingConsent() { try fixture.fleet.approveConsent(revision: slice.revision, controllers: slice.controllers) }
        }
        let oldRosterEnvelope = try a.fleet.envelope()!
        var oversized = try a.fleet.read()
        oversized.controllerHistory = Array(repeating: c.member.clientKeyFingerprint!, count: 100_000)
        try rejects("oversized-journal-refused-before-replacing-authority", expected: .malformed) { try a.fleet.save(oversized) }
        try check("oversized-journal-keeps-valid-signed-roster", a.fleet.envelope() == oldRosterEnvelope)
        let offlineProjectionState = try DeviceDispatchSafeFile.read(p.fleet.url, limit: 4 * 1024 * 1024)
        let offlineProjectionIdentity = try Data(contentsOf: p.fleet.entry.deviceJSON)
        let offlineProjectionAuthorization = try Data(contentsOf: p.registry.authorizedKeysURL)
        let endpoints = FixtureNetwork()
        let recoveryLocks = DeviceFleetFourthRoundAcceptance.Results()
        let r5FormerAttempts = DeviceFleetFourthRoundAcceptance.Results()
        let r9Brain = ProcessInfo.processInfo.environment["TATWO2_W187_R9_BRAIN"] ?? ""
        var r9Pages = 42
        var r10SourcePages: Int? = 42
        var r10SourceHealthy = true
        let r13Mode = ProcessInfo.processInfo.environment["TATWO2_W187_R13_TRANSFER"] ?? ""
        let r13Work = r13Mode == "work"
        var r13SourceClosed = false
        let r12Mode = ProcessInfo.processInfo.environment["TATWO2_W187_R12_TRANSFER"] ?? ""
        let r11Mode = ProcessInfo.processInfo.environment["TATWO2_W187_R11_TRANSFER"] ?? ""
        let r10Mode = ProcessInfo.processInfo.environment["TATWO2_W187_R10_TRANSFER"] ?? ""
        let r8Recovery = ProcessInfo.processInfo.environment["TATWO2_W187_R8_TRANSFER"] == "1"
        let r8OwnerPushes = DeviceFleetFourthRoundAcceptance.Results()
        let r7Mode = ProcessInfo.processInfo.environment["TATWO2_W187_R7_TRANSFER"] ?? ""
        var r7RecoveryFailures = false
        let r6Mode = ProcessInfo.processInfo.environment["TATWO2_W187_R6_TRANSFER"] ?? ""
        let r6CoordinatorCalls = DeviceFleetFourthRoundAcceptance.Results()
        var r6Churn = false
        var r6ReturningOffline = false
        let r5Mode = ProcessInfo.processInfo.environment["TATWO2_W187_R5_TRANSFER"] ?? ""
        let r5Probe = DispatchSemaphore(value: 0), r5Release = DispatchSemaphore(value: 0)
        let r5Guard = NSLock()
        var r5Delay = false

        func make(_ index: Int) -> DeviceDispatch {
            let fixture = fixtures[index]
            return DeviceDispatch(entry: fixture.fleet.entry, registry: fixture.registry, environment: fixture.environment,
                retireBackup: { _ in }, rpc: { peer, method, proof in
                    if r8Recovery, index == 1, method == "dispatch_ack", [ids[0], ids[2]].contains(peer.id) { r8OwnerPushes.append(1) }
                    if r5Mode == "former-retries" || r6Mode == "coordinator-recovered", index == 2, peer.id == ids[0], method == "dispatch_fetch" { r5FormerAttempts.append(1) }
                    if r6Mode == "coordinator-recovered", index == 0, peer.id == ids[2] { r6CoordinatorCalls.append(1) }
                    if r7RecoveryFailures, index == 2, method == "dispatch_fetch" {
                        if peer.id == ids[0] {
                            if r7Mode == "return-exhausted" { throw DeviceFleetGate.CallError.unreachable }
                            if r7Mode == "return-signature" { throw DeviceFleetError.signature }
                            throw DeviceFleetGate.CallError.rejected("untrusted_rpc_sender")
                        }
                        if r7Mode == "return-exhausted" { throw DeviceFleetGate.CallError.unreachable }
                    }
                    if r6ReturningOffline, peer.id == ids[2] { throw DeviceDispatch.Failure(reason: "fixture_offline") }
                    guard let destination = endpoints[peer.id] else { throw DeviceDispatch.Failure(reason: "fixture_offline") }
                    if ["controller-window", "controller-epoch"].contains(ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] ?? ""), peer.id == ids[3] {
                        // Keep this participant offline until the fixture exercises authenticate/recordACK directly.
                        throw DeviceDispatch.Failure(reason: "fixture_offline")
                    }
                    if ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] == "source-lock", index == 1,
                       peer.id == ids[0], method == "dispatch_fetch", let raw = proof["body"] as? String,
                       let bytes = Data(base64Encoded: raw),
                       let body = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                       let payload = body["payload"] as? [String: Any], payload["identityOnly"] as? Bool == true {
                        let checked = DeviceFleetFourthRoundAcceptance.Results(), done = DispatchSemaphore(value: 0)
                        // Unrelated delivery workers may briefly own the mutex. A bounded wait still
                        // detects a mutex held by this RPC's caller, without racing those workers.
                        DispatchQueue.global().async { checked.append(current(1).fixtureStateLockAvailable(timeout: 2) ? 1 : 0); done.signal() }
                        guard done.wait(timeout: .now() + 3) == .success else { throw DeviceDispatch.Failure(reason: "fixture_source_probe_blocked") }
                        recoveryLocks.append(checked.sequences.first ?? 0)
                    }
                    if ["lock-begin", "lock-update"].contains(r5Mode), index == 0, method == "dispatch_fetch",
                       let raw = proof["body"] as? String, let bytes = Data(base64Encoded: raw),
                       let body = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                       (body["payload"] as? [String: Any])?["identityOnly"] as? Bool == true,
                       r5Guard.withLock({ let value = r5Delay; r5Delay = false; return value }) {
                        r5Probe.signal()
                        guard r5Release.wait(timeout: .now() + 5) == .success else { throw DeviceDispatch.Failure(reason: "fixture_delayed_RPC_timeout") }
                    }
                    if r13SourceClosed, index == 1, peer.id == ids[0] { throw DeviceFleetGate.CallError.appUnavailable }
                    if method == "device_status" {
                        if ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] == "target-none" {
                            let handshake = try current(index).signedHandshake(method: method, params: [:], recipient: peer.id)
                            let reply = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: destination, method: method, params: [:], handshake: handshake)
                            guard reply["ok"] as? Bool == true else { throw DeviceFleetError.capabilityDenied }
                        }
                        return try DeviceStatusReader.read(entry: destination.entry).jsonObject()
                    }
                    if ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] == "managed-gate",
                       method == "dispatch_ack", let publicKey = proof["publicKey"] as? String,
                       (try destination.fleet.trust())?.kind != .owner {
                        let key = try DeviceRegistry.fingerprint(publicKey: publicKey)
                        guard destination.registry.fleetHasAuthorizedFingerprint(key) else { throw DeviceDispatch.Failure(reason: "fixture_SSH_key_not_authorized") }
                    }
                    if ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] == "managed-gate",
                       index == 0, method == "dispatch_ack", peer.id == ids[3] {
                        let checked = DeviceFleetFourthRoundAcceptance.Results(), done = DispatchSemaphore(value: 0)
                        DispatchQueue.global().async { checked.append(current(0).fixtureStateLockAvailable() ? 1 : 0); done.signal() }
                        guard done.wait(timeout: .now() + 3) == .success, checked.sequences == [1] else {
                            throw DeviceDispatch.Failure(reason: "fixture_state_lock_held_across_RPC")
                        }
                    }
                    if ["return-online", "return-app-closed"].contains(r6Mode), index == 2, peer.id == ids[0],
                       (try destination.identity()).transfer?.constitution == true {
                        if r6Mode == "return-app-closed" { throw DeviceFleetGate.CallError.appUnavailable }
                        let response = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: destination, method: method, params: proof)
                        guard response["ok"] as? Bool == true else { throw RemoteHostLinkError.remoteError(response["error"] as? String ?? "unknown") }
                        return response["result"] as! [String: Any]
                    }
                    if method == "dispatch_wake" {
                        try destination.pullTransfer(from: destination.registry.list().first { $0.id == ids[index] }!)
                        return ["scheduled": true]
                    }
                    let (sender, content) = try destination.authenticate(method: method, proof: proof)
                    if method == "dispatch_fetch" {
                        if content["identityOnly"] as? Bool == true { return try DeviceDispatch.object(destination.localFleetPresence()) }
                        return try DeviceDispatch.object(destination.offer(to: sender))
                    }
                    if method == "dispatch_ack" {
                        if endpoints.consumeLostACK() { throw DeviceDispatch.Failure(reason: "fixture_lost_ack") }
                        try destination.recordACK(DeviceDispatch.decode(DeviceDispatch.Receipt.self, content), sender: sender)
                        return ["recorded": true]
                    }
                    throw DeviceDispatch.Failure(reason: "fixture_unknown_method")
                }, evidence: {
                    if r6Churn, index == 0 {
                        r6Churn = false
                        try! current(1).pullTransfer(from: peer(0, at: 1))
                    }
                    return .init(signingNames: ["fixture release"], brainMode: index == 1 && !r8Recovery && r12Mode.isEmpty ? "ssh-http" : "pglite",
                        brainHealthy: index != 0 || r10SourceHealthy, brainHostID: index == 1 ? ids[0] : nil, pages: index == 1 ? r9Pages : (r9Brain == "empty" ? 0 : r10SourcePages), acquiredAt: Date())
                })
        }
        for index in fixtures.indices { endpoints[ids[index]] = make(index) }
        func current(_ index: Int) -> DeviceDispatch { endpoints[ids[index]]! }
        func restart(_ index: Int) { endpoints[ids[index]] = make(index) }
        func peer(_ index: Int, at: Int) -> DeviceRecord { fixtures[at].registry.list().first { $0.id == ids[index] }! }
        func pump(_ index: Int, count: Int = 1) throws {
            for _ in 0..<count { try current(index).pullTransfer(from: peer(0, at: index)) }
        }
        func r5Concurrent(_ action: @escaping @Sendable () throws -> Void) throws {
            let endpoint = current(0), group = DispatchGroup(), errors = DeviceFleetFourthRoundAcceptance.Results()
            r5Guard.withLock { r5Delay = true }
            group.enter()
            DispatchQueue.global().async { defer { group.leave() }; do { try action() } catch { errors.fail(error) } }
            guard r5Probe.wait(timeout: .now() + 10) == .success else { throw DeviceDispatch.Failure(reason: "W187R5_FAIL_LOCK-probe-not-started") }
            group.enter()
            DispatchQueue.global().async { defer { group.leave() }; endpoint.synchronize() }
            let available = endpoint.fixtureStateLockAvailable(timeout: 0.5)
            r5Release.signal()
            try check("R5-LOCK-state-available-during-delayed-RPC", available)
            let complete = group.wait(timeout: .now() + 20) == .success
            if !errors.failures.isEmpty { print("W187R5 transfer concurrency errors " + errors.failures.joined(separator: "; ")) }
            try check("R5-LOCK-transfer-and-synchronize-complete", complete && errors.failures.isEmpty)
        }
        let controllerMode = ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] ?? ""
        let oldControllerPoll: [String: Any]?
        if ["controller-window", "controller-epoch"].contains(controllerMode) {
            oldControllerPoll = try current(0).signedHandshake(method: "device_status", params: [:], recipient: ids[3])
        } else { oldControllerPoll = nil }
        try rejects("SUB-target-refused", expected: .role) { try current(0).beginTransfer(to: ids[3], signingName: "fixture release") }
        try rejects("sandbox-target-refused", expected: .role) { try current(0).beginTransfer(to: ids[4], signingName: "fixture release") }
        try rejects("secondary-cannot-initiate", expected: .primaryRequired) { try current(1).beginTransfer(to: ids[2], signingName: "fixture release") }
        try rejects("no-local-UI-confirmation-refused", expected: .confirmationRequired) { try PrimaryTransfer.begin(current(0), to: ids[1], signingName: "fixture release") }
        let proposal = try a.fleet.propose([.transfer(to: ids[1])], actor: ids[0])
        try rejects("remote-Boolean-confirmation-refused", expected: .confirmationRequired) { _ = try a.fleet.confirm(proposal.id, userConfirmed: true) }
        try check("refused-request-keeps-old-authority", current(0).identity().epoch == 1 && a.fleet.current()?.epoch == 1)
        var unverified = try a.fleet.current()!.roster!
        unverified.version += 1
        unverified.devices[1].legacy = true
        try a.fleet.accept(DeviceFleetEnvelope.issue(.init(roster: unverified), environment: a.environment))
        try rejects("unverified-owner-target-refused", expected: .role) {
            try current(0).beginTransfer(to: ids[1], signingName: "fixture release")
        }
        unverified.version += 1; unverified.devices[1].legacy = false
        try a.fleet.accept(DeviceFleetEnvelope.issue(.init(roster: unverified), environment: a.environment))
        try check("target-and-observer-missed-graph-revisions", b.fleet.current()?.revision == 1 && a.fleet.current()?.revision == 3)
        if !r12Mode.isEmpty {
            for path in ["agents.md", "user.md", "todo.md", "issue.md", "note/x.md"] {
                let file = a.fleet.entry.root.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(("synthetic " + path).utf8).write(to: file)
            }
            try pump(1); try pump(2)
            if r12Mode == "save-failure" {
                try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: a.fleet.entry.root.path)
                defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: a.fleet.entry.root.path) }
                try rejects("R12-ROSTER-02-save-fails") { try current(0).beginTransfer(to: ids[1], signingName: "fixture release") }
                try check("R12-ROSTER-02-save-failure-rolls-back-rotation", a.fleet.rotation() == nil && current(0).identity().transfer == nil)
                print("W187R12 SUMMARY failures=0"); return
            }
        }
        if r11Mode == "missing-pages" {
            r10SourcePages = nil
            try rejects("R11-ROSTER-02-begin-requires-frozen-pages") { try current(0).beginTransfer(to: ids[1], signingName: "fixture release") }
            print("W187R11 SUMMARY failures=0"); return
        }
        if r10Mode == "unhealthy" {
            r10SourceHealthy = false
            do { try current(0).beginTransfer(to: ids[1], signingName: "fixture release"); throw DeviceFleetError.signature }
            catch let failure as DeviceDispatch.Failure {
                try check("R10-ROSTER-01-unhealthy-source-refuses-begin-in-Chinese", failure.reason.contains("GBrain 不健康") && current(0).identity().transfer == nil)
            }
            print("W187R8 SUMMARY failures=0"); return
        }
        if r5Mode == "lock-begin" {
            let endpoint = current(0), target = ids[1]
            try r5Concurrent { try endpoint.beginTransfer(to: target, signingName: "fixture release") }
        } else { try current(0).beginTransfer(to: ids[1], signingName: "fixture release") }
        try current(0).cancelPreparedTransfer()
        try check("prepared-transfer-safe-rollback", a.fleet.rotation() == nil && current(0).identity().transfer == nil)
        if let mode = ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"], ["none", "oneway"].contains(mode) {
            var narrowed = try a.fleet.current()!.roster!
            narrowed.edges.removeAll { ($0.from == .device(ids[0]) && $0.to == .device(ids[2])) || ($0.from == .device(ids[2]) && $0.to == .device(ids[0])) }
            narrowed.edges.append(.init(from: .device(ids[0]), to: .device(ids[2]), direction: mode == "none" ? .none : .oneway, capabilities: mode == "none" ? [] : DeviceFleetCapabilities.all))
            try a.fleet.publish(&narrowed)
        }
        if ["managed-none", "managed-gate"].contains(ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] ?? "") {
            var narrowed = try a.fleet.current()!.roster!
            for i in narrowed.edges.indices where narrowed.edges[i].from == .group("main") && narrowed.edges[i].to == .group("sub") {
                narrowed.edges[i].direction = .none; narrowed.edges[i].capabilities = []
            }
            try a.fleet.publish(&narrowed); try p.fleet.synchronizeEnvelope(a.fleet.delivery(for: ids[3])!)
        }
        if ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] == "target-none" {
            var narrowed = try a.fleet.current()!.roster!
            narrowed.edges.removeAll { ($0.from == .device(ids[0]) && $0.to == .device(ids[1])) || ($0.from == .device(ids[1]) && $0.to == .device(ids[0])) }
            narrowed.edges.append(.init(from: .device(ids[0]), to: .device(ids[1]), direction: .none, capabilities: []))
            try a.fleet.publish(&narrowed); try b.fleet.synchronizeEnvelope(a.fleet.envelope()!)
        }
        try current(0).beginTransfer(to: ids[1], signingName: "fixture release")
        if r12Mode == "legacy" {
            var record = try current(0).identity().transfer!
            record.hashes = try current(0).snapshot().mapValues(DeviceDispatch.hash)
            try PrimaryTransfer.save(record, dispatch: current(0))
        } else if !r12Mode.isEmpty {
            try check("R12-ROSTER-02-only-rule-files-freeze", Set(try current(0).identity().transfer!.hashes.keys) == Set(["os.md", "skillet.md", "user.md"]))
        }
        let originalRecordHashes = try current(0).identity().transfer!.hashes
        let prepared = try current(0).offer(to: ids[1])
        var attack = prepared; attack.transferProof = nil
        try rejects("missing-W83-signature-refused", expected: .signature) { _ = try current(1).apply(attack, authenticatedPrimary: peer(0, at: 1)) }
        attack = prepared; attack.fleetHandoff = nil
        try rejects("missing-handoff-signature-refused", expected: .signature) { _ = try current(1).apply(attack, authenticatedPrimary: peer(0, at: 1)) }
        attack = prepared; attack.fleetHandoff!.signature = Data("fixture forged signature".utf8)
        try rejects("forged-handoff-signature-refused", expected: .signature) { _ = try current(1).apply(attack, authenticatedPrimary: peer(0, at: 1)) }
        endpoints.loseACK()
        try rejects("checkpoint-1-prepare-ACK-interrupted") { try pump(1) }
        try check("prepare-does-not-switch-pins", a.fleet.trust()?.epoch == 1 && b.fleet.trust()?.epoch == 1
                  && current(1).identity().role == .secondary)
        restart(0); restart(1)
        let next = try current(0).offer(to: ids[1])
        let receipt = try current(1).apply(next, authenticatedPrimary: peer(0, at: 1))
        var noSignature = receipt; noSignature.fleet = nil
        try rejects("new-primary-unsigned-roster-refused", expected: .signature) { try current(0).recordACK(noSignature, sender: ids[1]) }
        try check("no-partial-demotion-on-missing-new-signature", current(0).identity().epoch == 1 && a.fleet.current()?.epoch == 1)
        var wrongSigner = receipt
        let forged = try DeviceSignature.sign(receipt.fleet!.body, namespace: DeviceFleetEnvelope.namespace, environment: c.environment)
        wrongSigner.fleet!.signature = forged.0; wrongSigner.fleet!.publicKey = forged.1
        try rejects("wrong-new-primary-signature-refused", expected: .signer) { try current(0).recordACK(wrongSigner, sender: ids[1]) }
        var missingProjection = receipt; missingProjection.fleetDeliveries?[ids[3]] = nil
        try rejects("missing-new-primary-projection-refused", expected: .signature) {
            try current(0).recordACK(missingProjection, sender: ids[1])
        }
        try rejects("TR-03-precommit-projection-refused", expected: .signature) {
            try p.fleet.accept(receipt.fleetDeliveries![ids[3]]!)
        }
        try current(0).recordACK(receipt, sender: ids[1])
        if ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] == "managed-gate" {
            let deadline = Date().addingTimeInterval(10)
            while try p.fleet.trust()?.epoch != 2, Date() < deadline { usleep(10_000) }
            try check("R3-ROSTER-02-empty-projection-repins-over-still-authorized-old-channel", p.fleet.trust()?.epoch == 2)
        }
        try check("old-primary-demoted-with-valid-new-roster", current(0).identity().role == .secondary
                  && a.fleet.current()?.roster?.primaryID == ids[1] && a.fleet.current()?.epoch == 2)
        if let mode = ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"], ["none", "oneway"].contains(mode) {
            try check("R4-XFER-01-participant-key-retained-until-epoch-ACK", a.registry.fleetHasAuthorizedFingerprint(c.member.clientKeyFingerprint!))
            let pull = try current(2).signed(method: "dispatch_fetch", payload: [:], recipient: ids[0])
            let reply = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: current(0), method: "dispatch_fetch", params: pull)
            try check("R4-XFER-01-pull-through-real-handle", reply["ok"] as? Bool == true)
            try pump(2); try pump(1, count: 2)
            try check("R4-XFER-01-completes-with-roster-only-observer", current(0).identity().transfer!.epochComplete)
            print("W187R4 SUMMARY failures=0")
            return
        }
        let committed = try current(0).offer(to: ids[1])
        attack = committed; attack.fleet = nil
        try rejects("commit-missing-new-signature-refused", expected: .signature) { _ = try current(1).apply(attack, authenticatedPrimary: peer(0, at: 1)) }
        try pump(1, count: 2)
        try check("new-primary-promoted-and-repinned", current(1).identity().role == .primary && b.fleet.trust()?.pinnedPrimaryKey == b.member.clientKeyFingerprint)
        if ["skip-online", "fork"].contains(r7Mode) {
            let targetBefore = try current(1).identity().transfer!
            if r7Mode == "skip-online" {
                let absent = endpoints.removeValue(forKey: ids[2])!
                let start = targetBefore.committedAt!
                try PrimaryTransfer.probePendingParticipants(current(1), now: start.addingTimeInterval(121))
                do { try PrimaryTransfer.skipAbsentParticipants(current(1), now: start.addingTimeInterval(243), includeOffline: true) } catch {}
                try check("R7-ROSTER-01-online-coordinator-prevents-new-primary-skip", current(1).identity().transfer == targetBefore)
                endpoints[ids[2]] = absent
            } else {
                var fork = targetBefore; fork.skippedParticipants = [ids[2]]; fork.revision += 1
                try PrimaryTransfer.save(fork, dispatch: current(1))
                var forged = try current(0).offer(to: ids[1]); forged.fleetHandoff!.signature = Data("synthetic forged".utf8)
                try rejects("R7-ROSTER-01-fork-repair-still-requires-dual-signatures") {
                    _ = try current(1).apply(forged, authenticatedPrimary: peer(0, at: 1))
                }
                var changed = fork; changed.signingName = "synthetic different checkpoint"
                try PrimaryTransfer.save(changed, dispatch: current(1))
                try rejects("R7-ROSTER-01-semantic-checkpoint-changes-still-reject-replay") {
                    _ = try current(1).apply(current(0).offer(to: ids[1]), authenticatedPrimary: peer(0, at: 1))
                }
                try PrimaryTransfer.save(fork, dispatch: current(1))
                try rejects("R8-ROSTER-05-lower-revision-cannot-repair-fork") {
                    _ = try current(1).apply(current(0).offer(to: ids[1]), authenticatedPrimary: peer(0, at: 1))
                }
                try pump(2)
                try current(0).updateTransfer(constitution: true)
                try rejects("R8-ROSTER-05-advanced-checkpoint-cannot-drop-local-skips") {
                    _ = try current(1).apply(current(0).offer(to: ids[1]), authenticatedPrimary: peer(0, at: 1))
                }
                try check("R8-ROSTER-05-refusal-keeps-local-checkpoint", current(1).identity().transfer == fork)
            }
            print("W187R7 SUMMARY failures=0"); return
        }
        if r6Mode == "new-primary-skip" {
            let former = endpoints.removeValue(forKey: ids[0])!
            try current(1).updateTransfer(constitution: true)
            try b.fleet.revoke(ids[2])
            try PrimaryTransfer.skipAbsentParticipants(current(1), includeOffline: true)
            try check("R5-ROSTER-N2-new-primary-skips-revoked-participant", current(1).identity().transfer!.epochComplete)
            endpoints[ids[0]] = former
            try current(1).beginTransfer(to: ids[0], signingName: "fixture release")
            try check("R5-ROSTER-N2-next-transfer-not-stranded", current(1).identity().transfer!.epoch == 3)
            print("W187R6 SUMMARY failures=0"); return
        }
        if ["controller-window", "controller-epoch"].contains(controllerMode) {
            // Pause at the real authenticate/recordACK boundary with a committed dual-signed projection.
            try DeviceDispatchSafeFile.write(offlineProjectionState, url: p.fleet.url)
            try offlineProjectionIdentity.write(to: p.fleet.entry.deviceJSON)
            try offlineProjectionAuthorization.write(to: p.registry.authorizedKeysURL)
            let delivery = try current(0).fleet.rotation()!.deliveries![ids[3]]!
            let receipt = DeviceDispatch.Receipt(seq: 0, phase: "fleet", hashes: [:], updated: Date(), fleet: delivery)
            let future = try current(0).signed(method: "dispatch_ack", payload: DeviceDispatch.object(receipt), recipient: ids[3])
            if controllerMode == "controller-epoch" {
                var body = try JSONSerialization.jsonObject(with: Data(base64Encoded: future["body"] as! String)!) as! [String: Any]
                body["epoch"] = 3 // Valid signer/commit for epoch 2 cannot claim a different replay namespace.
                let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                let signed = try DeviceSignature.sign(bytes, namespace: "tatwo2-rpc", environment: a.environment)
                var claimed = future; claimed["body"] = bytes.base64EncodedString(); claimed["signature"] = signed.0.base64EncodedString()
                try rejects("SEQ-controller-proof-epoch-must-match-committed-projection") {
                    _ = try current(3).authenticate(method: "dispatch_ack", proof: claimed)
                }
            } else {
                let authenticated = try current(3).authenticate(method: "dispatch_ack", proof: future)
                _ = try current(3).authenticate(method: "device_status", proof: oldControllerPoll!)
                try check("SEQ-old-controller-poll-between-verification-and-apply", p.fleet.trust()?.epoch == 1)
                do {
                    _ = try current(3).authenticate(method: "dispatch_ack", proof: future)
                    throw DeviceDispatch.Failure(reason: "W187TRANSFER_UNEXPECTED_ACCEPT_future_controller_replay")
                } catch let failure as DeviceDispatch.Failure {
                    try check("SEQ-controller-inflight-future-window-not-forgotten", failure.reason == "stale_epoch_or_replayed_sequence")
                }
                try current(3).recordACK(DeviceDispatch.decode(DeviceDispatch.Receipt.self, authenticated.1), sender: authenticated.0)
                try check("SEQ-controller-inflight-valid-delivery-still-applies", p.fleet.trust()?.epoch == 2)
                try rejects("SEQ-controller-applied-delivery-replay-refused") {
                    _ = try current(3).authenticate(method: "dispatch_ack", proof: future)
                }
            }
            print("W187R4 SUMMARY failures=0"); return
        }
        if let mode = ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"], mode == "revoked" {
            var next = try b.fleet.current()!.roster!; next.revoked.append(ids[2]); try b.fleet.publish(&next)
            try a.fleet.synchronizeEnvelope(b.fleet.envelope()!)
            let now = try current(0).identity().transfer!.committedAt!.addingTimeInterval(1)
            try check("R4-XFER-02-revoked-immediately-eligible", PrimaryTransfer.absentParticipants(current(0), now: now) == [ids[2]])
            try PrimaryTransfer.skipAbsentParticipants(current(0), now: now, includeOffline: true)
            try check("R4-XFER-02-revoked-skipped-without-timeout", current(0).identity().transfer!.skippedParticipants == [ids[2]])
            print("W187R4 SUMMARY failures=0"); return
        }
        if !r11Mode.isEmpty || !r12Mode.isEmpty {
            let uiPending = r13Mode == "ui" && ProcessInfo.processInfo.environment["TATWO2_W187_R13_UI_STATE"] == "pending"
            if !uiPending { try pump(2) }
            try pump(1)
            if r13Mode == "ui" {
                let local = try current(1).identity(), record = local.transfer!
                try check("R13-ROSTER-03-fixture-is-promoted-but-brain-release-incomplete",
                          local.role == .primary && record.committed && !record.brainVerified && !record.releaseChecked && !record.complete)
                try check("R13-ROSTER-03-fixture-epoch-readback-" + (uiPending ? "pending" : "done"), record.epochComplete != uiPending)
                let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
                Task { @MainActor in
                    defer { done.signal() }
                    do {
                        let session = DeviceFlowSession(environment: b.environment, pasteboard: NSPasteboard(name: .init(UUID().uuidString)), rpc: { _, _, _ in throw DeviceFleetGate.CallError.appUnavailable })
                        defer { session.close() }
                        try session.open(.transfer); await session.refresh()
                        let text = try await DeviceFleetEleventhRoundAcceptance.render(DeviceFlowCard(session: session), artifact: "r13-epoch-readback-" + (uiPending ? "pending" : "done"))
                        if uiPending {
                            try check("R13-ROSTER-03-epoch-readback-pending-hides-start-fields",
                                      !text.contains("與現任主設備相同") && text.contains("先完成①所有設備的讀回"))
                        } else {
                            try check("R13-ROSTER-03-epoch-readback-done-shows-start-before-brain-release",
                                      text.contains("與現任主設備相同") && !text.contains("先完成①所有設備的讀回"))
                        }
                    } catch { errors.fail(error) }
                }
                guard done.wait(timeout: .now() + 40) == .success else { throw DeviceFleetError.malformed }
                if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
                print("W187R13 SUMMARY failures=0"); return
            }
            if r13Mode == "reason" {
                r13SourceClosed = true
                do { try current(1).updateTransfer(constitution: true); throw DeviceFleetError.signature }
                catch {
                    try check("R13-ROSTER-02-recovery-names-old-primary", error.localizedDescription.contains("舊主設備") && !error.localizedDescription.contains("新主設備的 App"))
                }
                try check("R13-ROSTER-02-secondary-sync-is-not-transfer", !DeviceFleetGate.CallError.unreachable.localizedDescription.contains("新主設備"))
                try check("R13-ROSTER-02-large-operation-is-not-memory", !DeviceFleetGate.CallError.contentTooLarge.localizedDescription.contains("記憶"))
                print("W187R13 SUMMARY failures=0"); return
            }
            if !r12Mode.isEmpty {
                for path in ["os.md", "skillet.md", "user.md"] {
                    let file = a.fleet.entry.root.appendingPathComponent(path), original = try Data(contentsOf: a.fleet.entry.root.appendingPathComponent(path))
                    try Data("changed synthetic rule".utf8).write(to: file)
                    do { try current(0).updateTransfer(constitution: true); throw DeviceFleetError.signature }
                    catch let error as DeviceDispatch.Failure {
                        try check("R12-SEQ-04-names-changed-" + path, error.localizedDescription.contains(path) && !error.localizedDescription.contains("重新同步"))
                    }
                    try original.write(to: file)
                }
                for path in ["agents.md", "todo.md", "issue.md", "note/x.md"] { try Data("latest synthetic work".utf8).write(to: a.fleet.entry.root.appendingPathComponent(path)) }
                try pump(1); try pump(2)
                for path in ["agents.md", "todo.md", "issue.md", "note/x.md"] {
                    try check("R12-ROSTER-02-working-file-arrives-latest-" + path, Data(contentsOf: b.fleet.entry.root.appendingPathComponent(path)) == Data(contentsOf: a.fleet.entry.root.appendingPathComponent(path)))
                }
            }
            if r13Work {
                try fm.removeItem(at: a.fleet.entry.root.appendingPathComponent("note/x.md"))
                usleep(1_000_000)
                try Data("last second synthetic todo".utf8).write(to: a.fleet.entry.root.appendingPathComponent("todo.md"))
            }
            try current(0).updateTransfer(constitution: true); try pump(1); try pump(2)
            if r13Work {
                current(0).synchronize()
                for fixture in [a, b] {
                    try check("R13-ROSTER-01-latest-todo-" + fixture.member.id, Data(contentsOf: fixture.fleet.entry.root.appendingPathComponent("todo.md")) == Data("last second synthetic todo".utf8))
                    try check("R13-ROSTER-01-deleted-note-stays-archived-" + fixture.member.id, !fm.fileExists(atPath: fixture.fleet.entry.root.appendingPathComponent("note/x.md").path))
                }
                print("W187R13 SUMMARY failures=0"); return
            }
            if r11Mode == "source-unhealthy" { r10SourceHealthy = false; r9Pages = 43 }
            if r11Mode == "target-ahead" { r10SourcePages = 43; r9Pages = 44 }
            try pump(1)
            try current(0).updateTransfer(brain: .migrated)
            try check("R11-ROSTER-02-" + r11Mode, current(0).identity().transfer!.brainVerified)
            if !r12Mode.isEmpty {
                try current(0).updateTransfer(release: true); try pump(1); try pump(2); try pump(1)
                try check("R12-ROSTER-02-real-entry-completes-four-checkpoints", current(0).identity().transfer!.complete && current(1).identity().transfer!.complete)
                try check("R12-ROSTER-02-record-hashes-remain-immutable", current(0).identity().transfer!.hashes == originalRecordHashes && current(1).identity().transfer!.hashes == originalRecordHashes)
                print("W187R12 SUMMARY failures=0"); return
            }
            if r11Mode == "signing-repair" {
                try current(0).updateTransfer(release: true, signingName: ""); try pump(1)
                try check("R11-SEQ-01-empty-name-is-missing-certificate", current(0).identity().transfer!.release == .missingCertificate)
                Task { @MainActor in
                    do {
                        try await DeviceFleetEleventhRoundAcceptance.correctSigningName(dispatch: current(0), readback: { try pump(1) })
                        try check("R11-SEQ-01-corrected-name-completes", current(0).identity().transfer!.complete)
                        print("W187R11 SUMMARY failures=0"); exit(0)
                    } catch { print("W187R11 FAIL " + error.localizedDescription); exit(1) }
                }
                RunLoop.main.run(); return
            }
            print("W187R11 SUMMARY failures=0"); return
        }
        if ["grow", "shrink", "memory-transferred"].contains(r10Mode) {
            try pump(2); try pump(1)
            if r10Mode == "memory-transferred" {
                for method in ["memory_sync_target", "memory_sync_receive", "memory_sync_export", "memory_sync_import"] {
                    let proof = try current(2).signed(method: method, payload: [:], recipient: ids[0])
                    do { _ = try current(0).authenticate(method: method, proof: proof); throw DeviceFleetError.signature }
                    catch let failure as DeviceDispatch.Failure { try check("R10-MEM-01-transferred-" + method, failure.reason == "primary_transferred") }
                    var forged = proof; forged["signature"] = Data("synthetic invalid".utf8).base64EncodedString()
                    do { _ = try current(0).authenticate(method: method, proof: forged); throw DeviceFleetError.signature }
                    catch let failure as DeviceDispatch.Failure { try check("R10-MEM-01-never-hides-invalid-signature-" + method, failure.reason != "primary_transferred") }
                }
                let paths = EngineMemoryPaths(home: c.registry.root.appendingPathComponent("memory-home").path, entryRoot: c.fleet.entry.root)
                try EngineMemoryLinks.createMemoryFolder(paths.memory)
                try TatwoMemorySyncAcceptance.note(paths.memory, "synthetic.md", title: "Synthetic", body: "Synthetic.")
                _ = EngineMemoryLinks.commit(paths.memory, message: "synthetic")
                let channel = DeviceDispatch(entry: c.fleet.entry, registry: c.registry, environment: c.environment, rpc: { _, method, params in
                    let body = try JSONSerialization.jsonObject(with: Data(base64Encoded: params["body"] as! String)!) as! [String: Any]
                    let redirected = try current(2).signed(method: method, payload: body["payload"] as! [String: Any], recipient: ids[0])
                    _ = try current(0).authenticate(method: method, proof: redirected)
                    throw DeviceFleetError.signature
                })
                let status = try SelfTest.offMain { TatwoMemorySyncEngine(paths: { paths }, dispatch: channel).runOnce(.manual) }
                try check("R10-MEM-01-returning-member-waits-quietly", status.state == .disabled && status.line.isEmpty && status.error == nil)
            } else {
                try current(0).updateTransfer(constitution: true); try pump(1); try pump(2)
                r9Pages = r10Mode == "grow" ? 43 : 41; r10SourcePages = r9Pages
                try pump(1)
                if r10Mode == "grow" {
                    try current(0).updateTransfer(brain: .migrated)
                    try check("R10-ROSTER-01-grown-matching-pages-pass", current(0).identity().transfer!.brainVerified)
                    r10SourcePages = 44
                    do { try current(0).updateTransfer(brain: .migrated); throw DeviceFleetError.signature }
                    catch let failure as DeviceDispatch.Failure { try check("R10-ROSTER-01-coordinator-rejects-current-page-divergence", failure.reason.contains("GBrain")) }
                } else { try rejects("R10-ROSTER-01-below-frozen-pages-refused") { try current(0).updateTransfer(brain: .migrated) } }
            }
            print("W187R8 SUMMARY failures=0"); return
        }
        if r8Recovery || r7Mode == "retired" || r6Mode == "coordinator-recovered" || ["recovery-convergence", "former-retries"].contains(r5Mode) || ["source-recovery", "source-lock"].contains(ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] ?? "") {
            let mode = ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] ?? ""
            if r9Brain == "online" {
                do { try current(1).updateTransfer(constitution: true); throw DeviceFleetError.signature }
                catch let error as DeviceDispatch.Failure {
                    try check("R9-CKPT-01-recovery-instructs-old-primary-step-two", error.reason.contains("舊主設備在線，請到舊主設備繼續②"))
                }
                print("W187R8 SUMMARY failures=0"); return
            }
            try rejects("R2-XFER-04-recovery-refused-while-old-coordinator-online") { try current(1).updateTransfer(constitution: true) }
            if mode == "source-lock" {
                print("W187TRANSFER SOURCE_LOCK probes=\(recoveryLocks.sequences)")
                try check("R2-XFER-04-recovery-probe-does-not-hold-shared-state-lock", recoveryLocks.sequences.last == 1)
                print("W187R4 SUMMARY failures=0"); return
            }
            let old = endpoints.removeValue(forKey: ids[0])!
            let changed = try current(1).snapshot(); let frozen = changed["os.md"]!
            try Data("changed fixture constitution\n".utf8).write(to: b.fleet.entry.constitution)
            try rejects("R2-XFER-04-recovery-refuses-changed-frozen-manifest") { try current(1).updateTransfer(constitution: true) }
            try frozen.write(to: b.fleet.entry.constitution)
            try current(1).updateTransfer(constitution: true)
            if r8Recovery {
                let recovered = try current(1).identity().transfer!
                try check("R8-ROSTER-01-recovered-source-card-is-local", recovered.constitution && recovered.sourceDeviceID == ids[1] && recovered.sourceRoot == b.fleet.entry.root.path)
                let ledgerFile = current(1).root.appendingPathComponent("state.json")
                var interrupted = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerFile)) as! [String: Any]
                interrupted.removeValue(forKey: "sourceRecoveryProof")
                try JSONSerialization.data(withJSONObject: interrupted).write(to: ledgerFile, options: .atomic)
                if r10Mode == "stale-proof" {
                    var stale = recovered; stale.id = UUID().uuidString
                    let proof = try DeviceDispatch.CoordinatorRecovery.issue(stale, environment: b.environment)
                    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerFile)) as! [String: Any]
                    object["sourceRecoveryProof"] = try DeviceDispatch.object(proof)
                    try JSONSerialization.data(withJSONObject: object).write(to: ledgerFile, options: .atomic)
                    let offer = try current(1).offer(to: ids[0])
                    try check("R10-ROSTER-02-offer-ignores-stale-ledger-proof", offer.sourceRecoveryProof?.retires(recovered, trust: a.fleet.trust()!) == true)
                    endpoints[ids[0]] = old
                    _ = try current(0).apply(offer, authenticatedPrimary: peer(1, at: 0))
                    try check("R10-ROSTER-02-former-primary-retires-with-stale-ledger", current(0).coordinatorRetired(current(0).identity().transfer!))
                    print("W187R8 SUMMARY failures=0"); return
                }
                if r9Brain == "source" {
                    try check("R9-ROSTER-04-recovery-has-one-durable-authority", current(1).hasRecoveredDispatchSource())
                    print("W187R8 SUMMARY failures=0"); return
                }
                let edited = Data("synthetic edits after physical recovery\n".utf8)
                try edited.write(to: b.fleet.entry.constitution)
                current(1).synchronize()
                try check("R9-ROSTER-04-local-checkpoint-survives-missing-proof", current(1).hasRecoveredDispatchSource())
                for index in [1, 2] { try current(index).fleet.reconcile(current(index).fleet.current()!) }
                let files = [b, c].map { $0.registry.root.appendingPathComponent("fleet-gate-policy.json") }
                let inodes = try files.map { try fm.attributesOfItem(atPath: $0.path)[.systemFileNumber] as! NSNumber }
                let pushes = r8OwnerPushes.sequences.count
                for _ in 0..<5 {
                    current(1).synchronize()
                    for index in [1, 2] { try current(index).fleet.synchronizeEnvelope(current(index).fleet.envelope()!) }
                }
                try check("R8-ROSTER-01-five-syncs-zero-owner-push", r8OwnerPushes.sequences.count == pushes)
                try check("R8-ROSTER-01-same-envelope-not-reconciled", try files.enumerated().allSatisfy { try fm.attributesOfItem(atPath: $0.element.path)[.systemFileNumber] as! NSNumber == inodes[$0.offset] })
                let authorized = try Data(contentsOf: b.registry.authorizedKeysURL)
                try Data().write(to: b.registry.authorizedKeysURL)
                try b.fleet.synchronizeEnvelope(b.fleet.envelope()!)
                try check("R8-ROSTER-01-same-envelope-repairs-changed-permissions", Data(contentsOf: b.registry.authorizedKeysURL) == authorized)
                let restarted = DeviceFleetStore(registry: b.registry, environment: b.environment)
                let beforeRestart = try fm.attributesOfItem(atPath: files[0].path)[.systemFileNumber] as! NSNumber
                try restarted.synchronizeEnvelope(restarted.envelope()!)
                try check("R8-ROSTER-01-restart-reconciles-same-envelope", fm.attributesOfItem(atPath: files[0].path)[.systemFileNumber] as! NSNumber != beforeRestart)
                current(2).synchronize(); current(2).synchronize()
                if !r9Brain.isEmpty {
                    if r9Brain == "missing" {
                        var local = try current(1).identity(); local.transfer!.sourcePages = nil
                        try DeviceIdentityStore.forLocalDevice(entry: b.fleet.entry, pairedDeviceID: ids[1]).write(local)
                    } else { r9Pages = r9Brain == "empty" ? 0 : 41 }
                    try rejects("R9-ROSTER-01-frozen-pages-" + r9Brain) { try current(1).updateTransfer(brain: .migrated) }
                    print("W187R8 SUMMARY failures=0"); return
                }
                try current(1).updateTransfer(brain: .migrated)
                try current(1).updateTransfer(release: true, signingName: "fixture release")
                try check("R8-ROSTER-01-local-checkpoints-can-complete", current(1).identity().transfer!.complete)
                endpoints[ids[0]] = old
                current(0).synchronize()
                try check("R8-ROSTER-01-retired-coordinator-no-work-left", current(0).coordinatorRetired(current(0).identity().transfer!))
                print("W187R8 SUMMARY failures=0"); return
            }
            if r7Mode == "retired" {
                endpoints[ids[0]] = old
                try b.fleet.revoke(ids[2])
                _ = try current(0).apply(current(1).offer(to: ids[0]), authenticatedPrimary: peer(1, at: 0))
                let record = try current(0).identity().transfer!
                try check("R7-ROSTER-03-retired-coordinator-has-no-absent-actions", PrimaryTransfer.absentParticipants(current(0)).isEmpty)
                try rejects("R7-ROSTER-03-retired-coordinator-cannot-skip") { try PrimaryTransfer.skipAbsentParticipants(current(0), includeOffline: true) }
                try check("R7-ROSTER-03-retirement-remains-durable", current(0).coordinatorRetired(record))
                try PrimaryTransfer.skipAbsentParticipants(current(1), includeOffline: true)
                try check("R7-ROSTER-03-retired-former-primary-does-not-block-active-coordinator", current(1).identity().transfer!.epochComplete)
                print("W187R7 SUMMARY failures=0"); return
            }
            let offered = try current(1).offer(to: ids[2])
            let applied = try current(2).apply(offered, authenticatedPrimary: peer(1, at: 2))
            try check("R2-XFER-04-new-primary-physical-source-recovery", applied.phase == "converged" && c.fleet.trust()?.epoch == 2)
            try check("R2-XFER-04-never-forges-old-primary-ACK", current(1).identity().transfer!.constitutionComplete && !current(1).identity().transfer!.brainComplete && current(1).identity().transfer!.acknowledgedRevision < current(1).identity().transfer!.revision)
            let edited = Data("synthetic constitution after source recovery\n".utf8)
            try edited.write(to: b.fleet.entry.constitution)
            let revised: DeviceDispatch.Bundle
            do { revised = try current(1).offer(to: ids[2]) }
            catch { throw DeviceDispatch.Failure(reason: "W187TRANSFER_FAIL_R2-XFER-04-recovered-primary-can-publish-edits: " + error.localizedDescription) }
            let revisedReceipt = try current(2).apply(revised, authenticatedPrimary: peer(1, at: 2))
            try check("R2-XFER-04-recovered-primary-can-publish-edits", revisedReceipt.phase == "converged" && Data(contentsOf: c.fleet.entry.constitution) == edited)
            try current(1).updateTransfer(constitution: true)
            try check("R2-XFER-04-source-recovery-idempotent-with-pending-W83-checkpoints", current(1).hasRecoveredDispatchSource() && current(1).identity().transfer!.constitutionComplete)
            if r5Mode == "former-retries" || r6Mode == "coordinator-recovered" {
                var observer = try current(2).identity(); observer.transfer = nil
                try DeviceIdentityStore.forLocalDevice(entry: c.fleet.entry, pairedDeviceID: ids[2]).write(observer)
                let start = Date(), baseline = r5FormerAttempts.sequences.count
                current(2).fixtureRecoveryNow = start
                current(2).synchronize(); current(2).synchronize()
                try check("ROSTER-N5-former-coordinator-retries-back-off", r5FormerAttempts.sequences.count - baseline == 1)
                for i in 1...8 { current(2).fixtureRecoveryNow = start.addingTimeInterval(Double(i) * 1200); current(2).synchronize() }
                try check("ROSTER-N5-former-coordinator-retries-stop", r5FormerAttempts.sequences.count - baseline == 6)
                try check("ROSTER-N5-stopped-metadata-pull-keeps-current-primary-sync", c.fleet.trust()?.epoch == 2 && Data(contentsOf: c.fleet.entry.constitution) == edited)
                endpoints[ids[0]] = old
                if r6Mode == "coordinator-recovered" {
                    var offered = try current(1).offer(to: ids[0])
                    let record = try current(0).identity().transfer!
                    let trust = try current(0).fleet.trust()!
                    try check("R6-ROSTER-05-current-primary-signature-required", offered.sourceRecoveryProof!.retires(record, trust: trust))
                    var unrelated = record; unrelated.id = UUID().uuidString
                    try check("R6-ROSTER-05-proof-cannot-retire-another-transfer", !offered.sourceRecoveryProof!.retires(unrelated, trust: trust))
                    offered.sourceRecoveryProof!.signature = Data("synthetic forged proof".utf8)
                    _ = try current(0).apply(offered, authenticatedPrimary: peer(1, at: 2))
                    try check("R6-ROSTER-05-forged-proof-does-not-retire-coordinator", !current(0).coordinatorRetired(record))
                    current(0).synchronize()
                    let baseline = r6CoordinatorCalls.sequences.count
                    current(0).synchronize(); current(0).synchronize(); restart(0); current(0).synchronize()
                    try check("R6-ROSTER-05-recovered-source-stops-former-coordinator-owner-probes-and-pushes", r6CoordinatorCalls.sequences.count == baseline)
                    try check("R6-ROSTER-05-retirement-does-not-forge-readbacks", !current(0).identity().transfer!.epochComplete)
                    print("W187R6 SUMMARY failures=0"); return
                }
                print("W187R5 SUMMARY failures=0"); return
            }
            endpoints[ids[0]] = old
            if r5Mode == "recovery-convergence" {
                // Observer sends a genuine current-epoch readback to the recovered primary.
                current(2).synchronize(); current(2).synchronize()
                current(1).synchronize(); current(1).synchronize()
                try check("R5-ROSTER-N2-recovered-source-still-converges-epoch", current(1).identity().transfer!.epochComplete)
                try check("R5-ROSTER-N2-metadata-does-not-overwrite-new-source-edits", Data(contentsOf: b.fleet.entry.constitution) == edited)
                try current(1).beginTransfer(to: ids[0], signingName: "fixture release")
                try check("R5-ROSTER-N2-recovered-primary-can-initiate-next-handoff", current(1).identity().transfer!.epoch == 3 && current(1).identity().transfer!.to == ids[0])
                try current(1).cancelPreparedTransfer()
                print("W187R5 SUMMARY failures=0"); return
            }
            print("W187R4 SUMMARY failures=0"); return
        }
        let beforeSkip = try Data(contentsOf: a.fleet.entry.deviceJSON)
        let waiting = try current(0).identity().transfer!
        let commitTime = waiting.committedAt!
        try rejects("XFER-01-long-preparation-does-not-expire-commit") {
            try PrimaryTransfer.skipAbsentParticipants(current(0), now: commitTime.addingTimeInterval(119), includeOffline: true)
        }
        try PrimaryTransfer.skipAbsentParticipants(current(0), now: commitTime.addingTimeInterval(121), includeOffline: true)
        try check("XFER-01-online-unacked-participant-not-skipped", current(0).identity().transfer!.skippedParticipants?.isEmpty != false)
        let absent = endpoints.removeValue(forKey: ids[2])!
        r6ReturningOffline = ["return-online", "return-app-closed"].contains(r6Mode)
        try PrimaryTransfer.probePendingParticipants(current(0), now: commitTime.addingTimeInterval(122))
        try PrimaryTransfer.skipAbsentParticipants(current(0), now: commitTime.addingTimeInterval(241), includeOffline: true)
        try check("XFER-01-short-outage-not-skipped", current(0).identity().transfer!.skippedParticipants?.isEmpty != false)
        if ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] == "target-offline" {
            let targetEndpoint = endpoints.removeValue(forKey: ids[1])!
            try rejects("R4-XFER-02-new-primary-must-be-online-in-skip-round") {
                try PrimaryTransfer.skipAbsentParticipants(current(0), now: commitTime.addingTimeInterval(243), includeOffline: true)
            }
            try check("R4-XFER-02-offline-new-primary-never-skipped", current(0).identity().transfer!.skippedParticipants?.isEmpty != false)
            endpoints[ids[1]] = targetEndpoint
            print("W187R4 SUMMARY failures=0"); return
        }
        try PrimaryTransfer.skipAbsentParticipants(current(0), now: commitTime.addingTimeInterval(243), includeOffline: true)
        let skipped = try current(0).identity().transfer!
        try check("XFER-04-timeout-skips-proven-absent-with-immutable-participants", skipped.epochComplete && skipped.participants == waiting.participants
            && skipped.skippedParticipants == [ids[2]] && !skipped.skippedParticipants!.contains(skipped.to))
        endpoints[ids[2]] = absent
        let returnMode = r7Mode == "return-next" ? "skipped-two" : ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] ?? ""
        if !["skipped-return", "skipped-two", "skipped-pending"].contains(returnMode) {
            try DeviceDispatchSafeFile.write(beforeSkip, url: a.fleet.entry.deviceJSON)
        }
        let oldObserverJournal = try Data(contentsOf: c.fleet.url), oldObserverIdentity = try Data(contentsOf: c.fleet.entry.deviceJSON)
        let cOld = try c.fleet.envelope()!
        var cCommit = try current(0).offer(to: ids[2]); cCommit.fleet!.handoff = nil
        try rejects("observer-requires-both-signatures", expected: .signature) { _ = try current(2).apply(cCommit, authenticatedPrimary: peer(0, at: 2)) }
        try check("observer-no-partial-pin", c.fleet.envelope() == cOld && c.fleet.trust()?.epoch == 1)
        try c.fleet.accept(committed.fleet!)
        try check("observer-can-receive-dual-signatures-before-W83-metadata", current(2).identity().epoch == 2 && current(2).identity().transfer == nil)
        if !["skipped-return", "skipped-two", "skipped-pending"].contains(returnMode) { try pump(2) }
        try pump(1)
        try check("all-owner-epoch-readbacks", current(0).identity().transfer!.epochComplete)
        for fixture in [p,s] {
            let envelope = try b.fleet.delivery(for: fixture.member.id)!
            var missing = envelope; missing.handoff = nil
            try rejects("projection-\(fixture.member.role.rawValue)-missing-handoff") { try fixture.fleet.accept(missing) }
            let destination = endpoints[fixture.member.id]!
            let delivery = DeviceDispatch.Receipt(seq: 0, phase: "fleet", hashes: [:], updated: Date(), fleet: envelope)
            let proof = try current(1).signed(method: "dispatch_ack", payload: DeviceDispatch.object(delivery), recipient: fixture.member.id)
            let (sender, content) = try destination.authenticate(method: "dispatch_ack", proof: proof)
            try destination.recordACK(DeviceDispatch.decode(DeviceDispatch.Receipt.self, content), sender: sender)
            try check("projection-\(fixture.member.role.rawValue)-dual-signature-pin", fixture.fleet.trust()?.pinnedPrimaryKey == b.member.clientKeyFingerprint)
        }
        try rejects("old-epoch-handoff-replay-refused", expected: .replay) { try c.fleet.accept(committed.fleet!) }
        try rejects("old-primary-epoch-roster-refused", expected: .signer) { try c.fleet.accept(oldRosterEnvelope) }
        try rejects("old-epoch-W83-packet-refused") { _ = try current(2).apply(prepared, authenticatedPrimary: peer(0, at: 2)) }
        try rejects("former-primary-cannot-sign-roster", expected: .signer) {
            var next = try b.fleet.current()!.roster!; next.version += 1
            _ = try DeviceFleetEnvelope.issue(.init(roster: next), environment: a.environment)
        }
        // Simulate crash between atomic fleet journal and device.json projection, then replay it.
        var local = try current(2).identity(); local.epoch = 1; local.primaryDeviceID = ids[0]
        try DeviceIdentityStore.forLocalDevice(entry: c.fleet.entry, pairedDeviceID: ids[2]).write(local)
        restart(2)
        try check("authority-journal-recovers-identity-with-valid-roster", current(2).identity().epoch == 2 && c.fleet.current()?.epoch == 2)
        if r7Mode == "stale-evidence" {
            var record = try current(0).identity().transfer!
            record.targetEvidence!.acquiredAt = Date().addingTimeInterval(-61)
            try PrimaryTransfer.save(record, dispatch: current(0))
            do { try current(0).updateTransfer(constitution: true); throw DeviceFleetError.malformed }
            catch {
                try check("R7-CKPT-01-stale-evidence-has-Chinese-retry-action", error.localizedDescription.contains("重新同步") && !error.localizedDescription.contains("target_evidence_stale_retry"))
            }
            print("W187R7 SUMMARY failures=0"); return
        }
        if r6Mode == "ack-churn" { r6Churn = true }
        if r5Mode == "lock-update" {
            let endpoint = current(0)
            try r5Concurrent { try endpoint.updateTransfer(constitution: true) }
        } else { try current(0).updateTransfer(constitution: true) }
        restart(0); restart(1); endpoints.loseACK()
        try rejects("checkpoint-2-source-switch-interrupted") { try pump(1) }
        try pump(1)
        try check("checkpoint-2-resumed", current(0).identity().transfer!.constitutionComplete)
        if ["return-online", "return-app-closed"].contains(r6Mode) {
            try current(0).updateTransfer(brain: .retained); try pump(1)
            try current(0).updateTransfer(release: true, signingName: "fixture release"); try pump(1, count: 2)
            try check("R6-ROSTER-01-real-transfer-complete-before-return", current(0).identity().transfer!.complete)
        }
        if ["skipped-return", "skipped-two", "skipped-pending"].contains(returnMode) {
            var destination = 1, expectedEpoch = 2
            if returnMode != "skipped-return" {
                try current(0).updateTransfer(brain: .retained); try pump(1)
                try current(0).updateTransfer(release: true, signingName: "fixture release"); try pump(1, count: 2)
                let absentAgain = endpoints.removeValue(forKey: ids[2])!
                try current(1).beginTransfer(to: ids[0], signingName: "fixture release")
                for _ in 0..<3 { try current(0).pullTransfer(from: peer(1, at: 0)) }
                let secondCommit = try current(1).identity().transfer!.committedAt!
                if returnMode != "skipped-pending" {
                try PrimaryTransfer.probePendingParticipants(current(1), now: secondCommit.addingTimeInterval(122))
                try PrimaryTransfer.skipAbsentParticipants(current(1), now: secondCommit.addingTimeInterval(243), includeOffline: true)
                try current(1).updateTransfer(constitution: true)
                try current(0).pullTransfer(from: peer(1, at: 0))
                }
                endpoints[ids[2]] = absentAgain
                destination = 0; expectedEpoch = 3
            }
            let destinationFleet = fixtures[destination].fleet
            var latest = try destinationFleet.current()!.roster!
            latest.devices[latest.devices.firstIndex { $0.id == ids[2] }!].name = "fixture returning"
            try destinationFleet.publish(&latest)
            try DeviceDispatchSafeFile.write(oldObserverJournal, url: c.fleet.url)
            try oldObserverIdentity.write(to: c.fleet.entry.deviceJSON); restart(2)
            let oldFetch = try current(2).signed(method: "dispatch_fetch", payload: [:], recipient: ids[destination])
            let oldMutation = try current(2).signed(method: "document_inspect", payload: ["id": "fixture"], recipient: ids[destination])
            try rejects("R3-XFER-01-returning-old-epoch-cannot-use-other-methods") {
                _ = try current(destination).authenticate(method: "document_inspect", proof: oldMutation)
            }
            var forged = try current(destination).offer(to: ids[2]); forged.fleet!.signature = Data("fixture forged signature".utf8)
            try rejects("R3-XFER-01-forged-latest-roster-refused-before-authority-change") {
                _ = try current(2).apply(forged, authenticatedPrimary: peer(destination, at: 2))
            }
            try check("R3-XFER-01-refusal-keeps-old-authority", current(2).identity().epoch == 1)
            let lostIndex = destination == 1 ? 0 : 1
            let old = returnMode == "skipped-pending" || !r6Mode.isEmpty || !r7Mode.isEmpty ? nil : endpoints.removeValue(forKey: ids[lostIndex])!
            r6ReturningOffline = false
            if ["return-denied", "return-signature", "return-exhausted"].contains(r7Mode) { r7RecoveryFailures = true }
            if r7Mode == "return-exhausted" {
                let start = Date()
                for i in 0..<7 { current(2).fixtureRecoveryNow = start.addingTimeInterval(Double(i) * 1200); current(2).synchronize() }
                try check("R7-ROSTER-02-failed-scans-do-not-change-trust", c.fleet.trust()?.epoch == 1)
                r7RecoveryFailures = false
                current(2).fixtureRecoveryNow = start.addingTimeInterval(9 * 1200)
            }
            current(2).synchronize()
            if r6Mode == "return-app-closed" {
                current(2).fixtureRecoveryNow = Date().addingTimeInterval(21)
                current(2).synchronize()
            }
            try check("R3-XFER-01-old-epoch-observer-recovers-from-new-primary-\(expectedEpoch)", c.fleet.trust()?.epoch == expectedEpoch && current(2).identity().primaryDeviceID == ids[destination])
            if returnMode == "skipped-pending" {
                current(2).synchronize()
                try check("R3-XFER-01-online-old-observer-ACKs-pending-second-handoff", current(1).identity().transfer!.epochComplete)
                try current(1).updateTransfer(constitution: true)
                try current(0).pullTransfer(from: peer(1, at: 0))
                current(2).synchronize()
            }
            try check("R3-XFER-01-returning-observer-receives-post-commit-roster", c.fleet.current()?.roster?.devices.first { $0.id == ids[2] }?.name == "fixture returning")
            try rejects("R3-XFER-01-caught-up-observer-old-epoch-fetch-refused") {
                _ = try current(destination).authenticate(method: "dispatch_fetch", proof: oldFetch)
            }
            if returnMode == "skipped-two", r7Mode.isEmpty {
                var bounded = try destinationFleet.current()!.roster!
                var history = bounded.rotationHistory ?? [:]
                history[ids[2]] = Array(repeating: committed.fleet!, count: 16)
                bounded.rotationHistory = history
                try destinationFleet.publish(&bounded)
                current(2).synchronize()
                try check("R3-XFER-01-caught-up-device-not-blocked-by-full-history", c.fleet.current()?.revision == destinationFleet.current()?.revision)
            }
            if let old { endpoints[ids[lostIndex]] = old }
            if !r7Mode.isEmpty {
                print("W187R7 SUMMARY failures=0"); return
            }
            if !r6Mode.isEmpty {
                var revoked = try destinationFleet.current()!.roster!; revoked.revoked.append(ids[2])
                try destinationFleet.publish(&revoked); current(destination).pushFleetNow()
                try check("R6-ROSTER-01-returning-observer-receives-revocation", c.fleet.current()?.revocationNotice?.targetID == ids[2])
                print("W187R6 SUMMARY failures=0")
            } else { print("W187R4 SUMMARY failures=0") }
            return
        }
        if r6Mode == "ack-churn" { r6Churn = true }
        try current(0).updateTransfer(brain: .retained)
        restart(0); restart(1); endpoints.loseACK()
        try rejects("checkpoint-3-brain-interrupted") { try pump(1) }
        try pump(1)
        try check("checkpoint-3-resumed-with-source-preserved", current(0).identity().transfer!.brainComplete && current(0).identity().transfer!.constitutionComplete)
        if r6Mode == "ack-churn" { r6Churn = true }
        try current(0).updateTransfer(release: true, signingName: "fixture release")
        restart(0); restart(1); endpoints.loseACK()
        try rejects("checkpoint-4-release-interrupted") { try pump(1) }
        try pump(1, count: 2)
        try check("four-checkpoints-complete", current(0).identity().transfer!.complete && current(1).identity().transfer!.complete)
        try b.fleet.requirePreviousRotationDelivered()
        try check("offline-projection-does-not-block-handback", Set(b.fleet.read().pendingRepin ?? []) == [ids[3],ids[4]])
        let renamed = try b.fleet.propose([.renameGroup(id: "main", name: "example renamed")], actor: ids[1])
        _ = try b.fleet.confirm(renamed.id, userConfirmed: true)
        // This fixture stood in for an offline SUB: it still has its original pin and projection.
        try DeviceDispatchSafeFile.write(offlineProjectionState, url: p.fleet.url)
        try offlineProjectionIdentity.write(to: p.fleet.entry.deviceJSON)
        try offlineProjectionAuthorization.write(to: p.registry.authorizedKeysURL)
        current(1).synchronize()
        try check("offline-projection-rotates-before-later-roster", p.fleet.trust()?.epoch == 2 && p.fleet.current()?.revision == b.fleet.current()?.revision)
        try check("projection-readbacks-durable", Set(b.fleet.rotation()?.deliveredProjections ?? []) == [ids[3],ids[4]])
        current(1).synchronize()
        try check("repeated-projection-delivery-idempotent", p.fleet.current()?.epoch == 2 && s.fleet.current()?.epoch == 2)
        let calls: [DeviceFleetRevocation.Session] = [
            .init(pid: 1001, start: 1, fingerprint: c.member.clientKeyFingerprint, address: "192.0.2.200", tatwoRelated: false),
            .init(pid: 1002, start: 1, fingerprint: nil, address: "192.0.2.3", tatwoRelated: true),
            .init(pid: 1003, start: 1, fingerprint: a.member.clientKeyFingerprint, address: "192.0.2.3", tatwoRelated: true),
            .init(pid: 1004, start: 1, fingerprint: nil, address: "192.0.2.3", tatwoRelated: false),
            .init(pid: 1005, start: 1, fingerprint: nil, address: "192.0.2.200", tatwoRelated: true)]
        var terminated = Set<pid_t>()
        DeviceFleetRevocation.testHooks = .init(sessions: { calls }, terminate: { terminated.insert($0.pid); return true })
        defer { DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false }) }
        let link = RemoteHostLink(environment: b.environment), other = RemoteHostLink(environment: b.environment)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        let otherChild = Process(); otherChild.executableURL = URL(fileURLWithPath: "/bin/sleep"); otherChild.arguments = ["60"]
        defer { if otherChild.isRunning { otherChild.terminate() }; if child.isRunning { child.terminate() } }
        try link.attachFixture(device: peer(2, at: 1), process: child)
        try other.attachFixture(device: peer(0, at: 1), process: otherChild)
        link.queueFixtureReconnect()
        try check("revoked-key-allowed-before-change", OSSocketCaller.sshMethodAllowed(fingerprint: c.member.clientKeyFingerprint, method: "document_inspect", registry: b.registry))
        try b.fleet.revoke(ids[2])
        child.waitUntilExit()
        try check("persistent-link-immediately-closed", !child.isRunning && link.fixtureRevoked && otherChild.isRunning && !other.fixtureRevoked)
        usleep(1_200_000)
        try check("already-queued-reconnect-never-launches", !link.fixtureReconnectPending && link.fixtureLaunchCount == 1)
        try check("only-key-or-related-endpoint-sessions-terminated", terminated == [1001,1002])
        try check("TR-02-broad-disconnect-requires-explicit-choice", !DeviceFleetRevocation.disconnectAllRemoteSessions(userSelected: false)
                  && terminated == [1001,1002])
        try check("TR-02-explicit-broad-disconnect-uses-visible-sessions", DeviceFleetRevocation.disconnectAllRemoteSessions(userSelected: true)
                  && terminated == Set(calls.map(\.pid)))
        var sharedAddress = peer(0, at: 1)
        sharedAddress.endpoints.append(.init(kind: .lan, host: "192.0.2.3"))
        _ = try b.registry.add(sharedAddress)
        terminated = []
        DeviceFleetRevocation.cutOff(c.member, registry: b.registry)
        try check("TR-02-shared-IP-is-not-guessed", terminated == [1001]
                  && b.fleet.read().possiblyConnected?.contains(c.member.id) == true)
        try rejects("revoked-link-cannot-reconnect") {
            let retry = Process(); retry.executableURL = URL(fileURLWithPath: "/bin/sleep"); retry.arguments = ["60"]
            try link.attachFixture(device: peer(2, at: 1), process: retry)
        }
        let newLink = RemoteHostLink(environment: b.environment)
        try rejects("new-link-to-revoked-peer-refused") {
            let retry = Process(); retry.executableURL = URL(fileURLWithPath: "/bin/sleep"); retry.arguments = ["60"]
            try newLink.attachFixture(device: peer(2, at: 1), process: retry)
        }
        try check("ssh-call-immediately-refused-without-App-restart", !OSSocketCaller.sshMethodAllowed(fingerprint: c.member.clientKeyFingerprint,
            method: "document_inspect", registry: b.registry) && !OSSocketCaller.sshFingerprintAllowed(c.member.clientKeyFingerprint!, registry: b.registry))
        let audit = try String(contentsOf: b.fleet.logURL, encoding: .utf8)
        try check("revocation-key-and-fallback-reasons-recorded", audit.contains("fleet_ssh_session_key_terminated") && audit.contains("fleet_ssh_session_endpoint_best_effort"))
        DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false })
        try a.fleet.accept(b.fleet.envelope()!)
        // Keep this SUB genuinely offline across the next authority change.
        try DeviceDispatchSafeFile.write(offlineProjectionState, url: p.fleet.url)
        try offlineProjectionIdentity.write(to: p.fleet.entry.deviceJSON)
        try offlineProjectionAuthorization.write(to: p.registry.authorizedKeysURL)
        var pendingAgain = try b.fleet.read()
        pendingAgain.rotation?.deliveredProjections?.removeAll { $0 == ids[3] }
        try b.fleet.save(pendingAgain)
        let offlinePeer = endpoints.removeValue(forKey: ids[3])!
        try current(1).beginTransfer(to: ids[0], signingName: "fixture release")
        try current(1).cancelPreparedTransfer()
        try check("TR-04-handback-precommit-checkpoint-cancellable", b.fleet.rotation() == nil && current(1).identity().epoch == 2
                  && current(1).identity().role == .primary)
        try current(1).beginTransfer(to: ids[0], signingName: "fixture release")
        for _ in 0..<3 { try current(0).pullTransfer(from: peer(1, at: 0)) }
        try check("completed-fleet-can-hand-back-with-fresh-dual-signatures", current(0).identity().role == .primary
                  && current(0).identity().epoch == 3 && a.fleet.current()?.epoch == 3 && b.fleet.current()?.roster?.primaryID == ids[0])
        endpoints[ids[3]] = offlinePeer
        current(0).synchronize()
        try check("TR-05-offline-across-two-handoffs-repins-through-old-commits", p.fleet.trust()?.epoch == 3
                  && p.fleet.trust()?.pinnedPrimaryKey == a.member.clientKeyFingerprint)
        try current(0).beginTransfer(to: ids[1], signingName: "fixture release")
        try a.fleet.expirePreparedTransfer(now: Date().addingTimeInterval(121))
        try check("TR-04-missing-ACK-expires-without-authority-change", a.fleet.rotation() == nil && current(0).identity().transfer?.committed == true
                  && a.fleet.trust()?.epoch == 3 && current(0).identity().role == .primary)
        try current(0).beginTransfer(to: ids[1], signingName: "fixture release")
        try a.fleet.revoke(ids[1])
        try check("TR-04-revoking-target-cancels-prepared-handoff", a.fleet.rotation() == nil && current(0).identity().transfer?.committed == true
                  && a.fleet.trust()?.epoch == 3)
        try rejects("TR-04-revoked-target-cannot-start-new-handoff", expected: .role) {
            try current(0).beginTransfer(to: ids[1], signingName: "fixture release")
        }
        if ["managed-none", "managed-gate", "target-none"].contains(ProcessInfo.processInfo.environment["TATWO2_W187_R4_TRANSFER"] ?? "") { print("W187R4 SUMMARY failures=0") }
        if !r5Mode.isEmpty { print("W187R5 SUMMARY failures=0") }
        if !r6Mode.isEmpty { print("W187R6 SUMMARY failures=0") }
        if preserveUserLines {
            for (index, fixture) in fixtures.enumerated() {
                try check("W221c-transfer-preserves-user-lines-\(index)", Data(contentsOf: fixture.registry.authorizedKeysURL).starts(with: unmanaged[index]))
            }
        }
        print("W187TRANSFER SUMMARY checks=\(checks) failures=0")
    }
}
#endif
