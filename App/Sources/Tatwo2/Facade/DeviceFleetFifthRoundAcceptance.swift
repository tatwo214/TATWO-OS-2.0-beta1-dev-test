#if DEBUG
import Darwin
import Foundation

enum DeviceFleetFifthRoundAcceptance {
    /// Run the shipped native gate against a synthetic Unix-socket App using production
    /// fixtureHandle authentication. SSH alone is replaced; policy/line limits and RPC run.
    final class GateFixture: @unchecked Sendable {
        let folder: URL, listener: Int32, primary: DeviceDispatch, bridge: OSAgentBridge
        var maxFrame = 0
        init(primary: DeviceDispatch, bridge: OSAgentBridge, controller: String) throws {
            self.primary = primary; self.bridge = bridge
            folder = URL(fileURLWithPath: "/tmp/w187g-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let policy: [String: Any] = ["controllers": [controller: ["capabilities": ["memory"]]], "methods": DeviceFleetCapabilities.methodTable]
            try DeviceDispatchSafeFile.write(JSONSerialization.data(withJSONObject: policy), url: folder.appendingPathComponent("fleet-gate-policy.json"))
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let path = folder.appendingPathComponent("os.sock").path
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in for (i, value) in path.utf8.enumerated() { bytes[i] = value } }
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard listener >= 0, bound == 0, listen(listener, 8) == 0 else { throw DeviceFleetError.malformed }
        }
        deinit { close(listener); try? FileManager.default.removeItem(at: folder) }
        func exchange(_ frame: [String: Any], controller: String) throws -> (Int32, String, Data) {
            let input = try JSONSerialization.data(withJSONObject: frame) + Data([10])
            maxFrame = max(maxFrame, input.count)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { done.signal() }
                var item = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
                guard poll(&item, 1, 10_000) > 0 else { return }
                let fd = accept(self.listener, nil, nil)
                guard fd >= 0 else { return }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                do {
                    var bytes = Data()
                    while !bytes.contains(10), bytes.count <= 1024 * 1024 {
                        let chunk = handle.availableData; if chunk.isEmpty { return }; bytes.append(chunk)
                    }
                    let request = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    let reply = try self.bridge.fixtureHandle(dispatch: self.primary, method: request["method"] as! String, params: request["params"] as! [String: Any])
                    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: reply) + Data([10]))
                } catch { }
            }
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("TatwoFleetGate")
            process.arguments = ["--device", controller, "--policy", folder.appendingPathComponent("fleet-gate-policy.json").path]
            process.environment = ["SSH_ORIGINAL_COMMAND": "tatwo-fleet-rpc", "HOME": folder.path]
            let file = folder.appendingPathComponent("input.json")
            try input.write(to: file); let stdin = try FileHandle(forReadingFrom: file)
            defer { try? stdin.close() }
            process.standardInput = stdin; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            _ = done.wait(timeout: .now() + 12)
            return (process.terminationStatus, "Authenticated to synthetic peer\n", bytes)
        }
    }
    static func run(scenario: String, make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R5_FAIL_" + name) }
            print("W187R5 PASS " + name)
        }
        let a = try make(70, true), b = try make(71, false)
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b, .owner, nil, false)
        switch scenario {
        case "clock":
            let proof = try b.dispatch.signed(method: "device_status", payload: [:], recipient: a.id)
            var body = try JSONSerialization.jsonObject(with: Data(base64Encoded: proof["body"] as! String)!) as! [String: Any]
            body["issuedAt"] = Date().timeIntervalSince1970 - 121
            let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let signature = try DeviceSignature.sign(bytes, namespace: "tatwo2-rpc", environment: b.env)
            let expired: [String: Any] = ["body": bytes.base64EncodedString(), "signature": signature.0.base64EncodedString(), "publicKey": signature.1]
            let response = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: a.dispatch, method: "device_status", params: [:], handshake: expired)
            try check("SEQ-02-clock-error-preserved-through-handshake", response["error"] as? String == "rpc_proof_expired")
            try check("SEQ-02-clock-plain-action", TatwoMemorySyncEngine.short(DeviceDispatch.Failure(reason: "rpc_proof_expired")).contains("兩台時間不一致"))
            var snapshot = DeviceFleetUISnapshot(payload: try a.fleet.current(), localID: a.id)
            snapshot.status[b.id] = .init(connection: .appUnavailable, snapshot: nil, acquiredAt: Date(), reason: "rpc_proof_expired")
            try check("SEQ-02-clock-shown-in-device-status", snapshot.connectionLabel(a.fleet.current()!.roster!.devices.first { $0.id == b.id }!) == "兩台時間不一致")
            var graph = try a.fleet.current()!.roster!
            graph.edges.removeAll { ($0.from == .device(a.id) && $0.to == .device(b.id)) || ($0.from == .device(b.id) && $0.to == .device(a.id)) }
            graph.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: .oneway, capabilities: ["files"]))
            try a.fleet.publish(&graph)
            let link = RemoteHostLink(environment: a.env)
            link.fixtureGate = { _, _, _ in throw RemoteHostLinkError.remoteError("rpc_proof_expired") }
            let probe = link.queryDeviceStatus(device: a.registry.list().first { $0.id == b.id }!)
            try check("SEQ-02-full-link-clock-error-is-not-App-unavailable", probe.reason == "rpc_proof_expired" && probe.connection == .appUnavailable)
        case "retries":
            let c = try make(72, false), staff = try make(73, false)
            try pair(a, c, .owner, nil, false)
            let main = try a.fleet.current()!.roster!.groups.first { $0.type == .main }!.id
            try pair(a, staff, .sandbox, main, true)
            b.dispatch.synchronize()
            var attempts: [String] = []
            let channel = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, rpc: { peer, _, _ in
                attempts.append(peer.id); throw DeviceFleetGate.CallError.refused
            })
            channel.synchronize(); channel.synchronize()
            try check("SEQ-01-refusal-does-not-scan-other-devices", attempts == [a.id, a.id])
            attempts = []
            let offline = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, rpc: { peer, _, _ in
                attempts.append(peer.id); throw DeviceFleetGate.CallError.unreachable
            })
            offline.synchronize(); offline.synchronize()
            try check("ROSTER-N5-offline-successor-scan-backs-off", attempts.filter { $0 != a.id }.count == 1 && !attempts.contains(staff.id))
            let start = Date()
            for i in 1...5 { offline.fixtureRecoveryNow = start.addingTimeInterval(Double(i) * 1200); offline.synchronize() }
            offline.synchronize()
            try check("ROSTER-N5-successor-scan-stops-after-six-attempts-until-cooldown", attempts.filter { $0 != a.id }.count == 6)
            offline.fixtureRecoveryNow = start.addingTimeInterval(6601); offline.synchronize()
            try check("ROSTER-N5-cooldown-restarts-bounded-scan", attempts.filter { $0 != a.id }.count == 7)
            offline.align(); offline.synchronize()
            try check("ROSTER-N5-manual-alignment-restarts-bounded-scan", attempts.filter { $0 != a.id }.count == 8)
        case "migration":
            let stale = try a.fleet.current()!
            var next = stale.roster!; next.groups[0].name = "new synthetic MAIN"
            try a.fleet.publish(&next)
            let latest = try a.fleet.current()!
            let migrated = try a.fleet.migrateStaffInterconnections(stale, trust: a.fleet.trust()!)
            try check("CARDS-06-migration-rereads-locked-current-roster", migrated == latest)
        case "local-error":
            try check("MEM-01-local-precondition-is-not-offline", !TatwoMemorySyncEngine.isTransport(RemoteHostLinkError.invalidResponse))
        case "bundle-auth":
            let encoded = Data("synthetic authenticated bytes".utf8).base64EncodedString()
            let proof = try b.dispatch.signed(method: "memory_sync_import", payload: ["bundle": encoded, "commit": String(repeating: "a", count: 40), "ref": TatwoMemorySyncEngine.inboxRef(b.id)], recipient: a.id)
            var tampered = proof; tampered["bundle"] = Data("tampered synthetic bytes".utf8).base64EncodedString()
            do {
                _ = try a.dispatch.authenticate(method: "memory_sync_import", proof: tampered)
                throw DeviceFleetError.signature
            } catch {
                try check("MEM-02-detached-bundle-digest-required", (error as? DeviceDispatch.Failure)?.reason == "invalid_memory_bundle")
            }
            let restored = try a.dispatch.authenticate(method: "memory_sync_import", proof: proof)
            try check("MEM-02-tampering-never-burns-valid-proof", restored.0 == b.id && restored.1["bundle"] as? String == encoded)
            do {
                _ = try a.dispatch.authenticate(method: "memory_sync_import", proof: proof)
                throw DeviceFleetError.signature
            } catch { try check("MEM-02-valid-detached-proof-still-replay-protected", (error as? DeviceDispatch.Failure)?.reason == "stale_epoch_or_replayed_sequence") }
        case "legacy-pin":
            var roster = try a.fleet.current()!.roster!
            let index = roster.devices.firstIndex { $0.id == b.id }!
            var candidate = roster.devices[index]
            roster.devices[index].legacy = true; roster.devices[index].hostPublicKey = nil; roster.devices[index].hostKeyFingerprint = nil
            try a.fleet.publish(&roster)
            let otherHost = roster.devices.first { $0.id == a.id }!
            candidate.hostPublicKey = otherHost.hostPublicKey; candidate.hostKeyFingerprint = otherHost.hostKeyFingerprint
            let before = try a.fleet.current()
            do {
                try a.fleet.upgradeLegacySelf(candidate, sender: b.id)
                throw DeviceFleetError.signature
            } catch { try check("ROSTER-N1-legacy-self-never-replaces-existing-pin", error as? DeviceFleetError == .keyConflict && (try a.fleet.current()) == before) }
        case "native":
            for method in ["send_message", "run_background", "job_submit", "command_run", "background_status", "artifacts_list"] {
                try check("CARDS-01-default-dispatch-" + method, DeviceFleetCapabilities.allows(method: method, capabilities: DeviceFleetCapabilities.sandbox))
                try check("CARDS-01-no-files-no-file-execution-" + method, !DeviceFleetCapabilities.allows(method: method, capabilities: ["dispatch"]))
            }
            try check("CARDS-01-no-memory-denies-App-owned-terminal-relay", !DeviceFleetCapabilities.allows(method: "cli_send", capabilities: DeviceFleetCapabilities.sandbox))
            try check("CARDS-01-terminal-relay-requires-dispatch-files-and-memory", DeviceFleetCapabilities.allows(method: "cli_send", capabilities: DeviceFleetCapabilities.sandbox + ["memory"]))
            try check("CARDS-01-files-alone-can-list-artifacts", DeviceFleetCapabilities.allows(method: "artifacts_list", capabilities: ["files"]))
        case "secondary-invite":
            var env = b.env; env["TATWO2_PAIRING_HOST"] = "127.0.0.1"
            let host = DevicePairingHost(registry: b.registry, environment: env)
            defer { host.cancelPairingWindow() }
            do { _ = try host.startPairingWindow(); throw DeviceDispatch.Failure(reason: "W187R5_FAIL_CARDS-03-secondary-invite-created") }
            catch let error as DeviceFleetError { try check("CARDS-03-secondary-refused-before-code", error == .primaryRequired && host.port == nil) }
        case "secondary-warning":
            let c = try make(72, false)
            let main = try a.fleet.current()!.roster!.groups.first { $0.type == .main }!.id
            try pair(a, c, .sandbox, main, true)
            b.dispatch.synchronize()
            var stale = try b.fleet.read()
            stale.deliveryProblems = [c.id: "projection_refused"]
            try b.fleet.save(stale)
            b.dispatch.synchronize()
            try check("CARDS-02-secondary-never-records-projection-refusal", b.fleet.read().deliveryProblems?.isEmpty != false)
            try a.fleet.recordDeliveryProblem(c.id, error: DeviceFleetGate.CallError.unreachable)
            try check("ROSTER-N3-transient-outage-needs-no-user-warning", DeviceFleetStore.deliveryWarnings(roster: a.fleet.current()?.roster, problems: a.fleet.read().deliveryProblems ?? [:]).values.sorted().isEmpty)
        case "ack-version":
            let oldBundle = try a.dispatch.offer(to: b.id)
            let oldACK = try b.dispatch.apply(oldBundle, authenticatedPrimary: b.registry.list().first { $0.id == a.id }!)
            var newer = try a.fleet.current()!.roster!; newer.groups[0].name = "Synthetic newer MAIN"
            try a.fleet.publish(&newer)
            try a.fleet.recordDeliveryProblem(b.id, error: DeviceFleetGate.CallError.refused)
            let proof = try b.dispatch.signed(method: "dispatch_ack", payload: DeviceDispatch.object(oldACK), recipient: a.id)
            let response = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: a.dispatch, method: "dispatch_ack", params: proof)
            try check("ROSTER-N3-old-ACK-remains-authenticated", response["ok"] as? Bool == true)
            try check("ROSTER-N3-old-ACK-cannot-clear-newer-projection-refusal", a.fleet.read().deliveryProblems?[b.id] == "projection_refused")
            b.dispatch.synchronize()
            try check("ROSTER-N3-current-version-ACK-clears-warning", a.fleet.read().deliveryProblems?[b.id] == nil && b.fleet.current()?.revision == a.fleet.current()?.revision)
        case "push-version":
            let channel = DeviceDispatch(entry: a.dispatch.entry, registry: a.registry, environment: a.env, rpc: { peer, method, _ in
                guard peer.id == b.id, method == "dispatch_ack" else { throw DeviceFleetError.role }
                var newer = try a.fleet.current()!.roster!; newer.groups[0].name = "Synthetic newer in-flight MAIN"
                try a.fleet.publish(&newer)
                try a.fleet.recordDeliveryProblem(b.id, error: DeviceFleetGate.CallError.refused)
                return ["accepted": true]
            })
            channel.pushFleetNow()
            try check("ROSTER-N3-old-push-result-cannot-clear-newer-refusal", a.fleet.read().deliveryProblems?[b.id] == "projection_refused")
        case "gate-size":
            let peer = b.registry.list().first { $0.id == a.id }!
            var exchanged = false
            DeviceFleetGate.fixtureExchange = { _, _, _ in exchanged = true; return (126, "Authenticated to synthetic peer\n", Data()) }
            defer { DeviceFleetGate.fixtureExchange = nil }
            do {
                _ = try DeviceFleetGate.call(peer: peer, method: "memory_sync_import", params: ["synthetic": String(repeating: "x", count: 1024 * 1024)], registry: b.registry)
                throw DeviceDispatch.Failure(reason: "W187R5_FAIL_MEM-02-oversize-accepted")
            } catch {
                try check("MEM-02-size-refused-before-transport", !exchanged && DeviceFleetReason.code(error)?.contains("too_large") == true)
                try check("CARDS-04-size-is-plain-not-App-unavailable", TatwoMemorySyncEngine.short(error).contains("內容太大"))
            }
            DeviceFleetGate.fixtureExchange = { _, _, _ in
                (0, "Authenticated to synthetic peer\n", try JSONSerialization.data(withJSONObject: ["ok": false, "error": "memory_bundle_too_large"]))
            }
            do {
                _ = try DeviceFleetGate.call(peer: peer, method: "memory_sync_export", params: [:], registry: b.registry)
                throw DeviceFleetError.signature
            } catch { try check("CARDS-04-export-size-error-preserved", (error as? DeviceFleetGate.CallError) == .contentTooLarge) }
        case "legacy-self":
            var roster = try a.fleet.current()!.roster!
            let index = roster.devices.firstIndex { $0.id == b.id }!
            roster.devices[index].legacy = true
            roster.devices[index].hostPublicKey = nil; roster.devices[index].hostKeyFingerprint = nil
            try a.fleet.publish(&roster)
            try a.fleet.recordDeliveryProblem(b.id, error: DeviceFleetGate.CallError.refused)
            b.dispatch.synchronize(); b.dispatch.synchronize()
            let upgraded = try a.fleet.current()!.roster!.devices.first { $0.id == b.id }!
            try check("ROSTER-N1-self-upgrade-adds-host-pin", !upgraded.legacy && upgraded.hostPublicKey != nil)
            try check("ROSTER-N3-genuine-ACK-clears-old-delivery-warning", a.fleet.read().deliveryProblems?[b.id] == nil)
        case "memory-pin", "incremental", "memory-endpoints":
            let p = EngineMemoryPaths(home: a.dispatch.root.appendingPathComponent("home").path, entryRoot: a.dispatch.entry.root)
            let q = EngineMemoryPaths(home: b.dispatch.root.appendingPathComponent("home").path, entryRoot: b.dispatch.entry.root)
            for paths in [p, q] { try EngineMemoryLinks.createMemoryFolder(paths.memory) }
            // Incompressible synthetic history larger than the gate, but shared by both endpoints.
            let seed = (0..<35_000).map { _ in UUID().uuidString }.joined(separator: "\n")
            try TatwoMemorySyncAcceptance.note(p.memory, "history.md", title: "Synthetic history", body: scenario == "incremental" ? seed : "Synthetic fixture.")
            _ = EngineMemoryLinks.commit(p.memory, message: "fixture history")
            let initial = TatwoMemorySyncEngine.runGit(["fetch", "-q", "--", p.memory.path, "+HEAD:refs/tatwo/fixture-base"], in: q.memory)
            try check("MEM-fixture-shared-history", initial.status == 0)
            let head = TatwoMemorySyncEngine.runGit(["rev-parse", "HEAD"], in: p.memory).text
            _ = TatwoMemorySyncEngine.runGit(["read-tree", "--reset", "-u", head], in: q.memory)
            _ = TatwoMemorySyncEngine.runGit(["update-ref", "HEAD", head], in: q.memory)
            try TatwoMemorySyncAcceptance.note(q.memory, "new.md", title: "Synthetic new memory", body: "New secondary memory.")
            _ = EngineMemoryLinks.commit(q.memory, message: "fixture new")
            let primary = TatwoMemorySyncEngine(paths: { p }, dispatch: a.dispatch)
            let bridge = OSAgentBridge.fleetFixtureBridge(); bridge.fixtureMemory(primary)
            var maxFrame = 0
            var channel = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, rpc: { _, method, proof in
                let count = try JSONSerialization.data(withJSONObject: ["method": method, "params": proof]).count
                maxFrame = max(maxFrame, count)
                if scenario == "incremental", count > 1024 * 1024 { throw DeviceFleetGate.CallError.appUnavailable }
                let response = try bridge.fixtureHandle(dispatch: a.dispatch, method: method, params: proof)
                guard response["ok"] as? Bool == true else { throw RemoteHostLinkError.remoteError(response["error"] as? String ?? "fixture_refused") }
                return response["result"] as! [String: Any]
            })
            if scenario == "incremental" {
                var graph = try a.fleet.current()!.roster!
                graph.edges.removeAll { ($0.from == .device(a.id) && $0.to == .device(b.id)) || ($0.from == .device(b.id) && $0.to == .device(a.id)) }
                graph.edges.append(.init(from: .device(b.id), to: .device(a.id), direction: .oneway, capabilities: ["memory"]))
                try a.fleet.publish(&graph); try b.fleet.synchronizeEnvelope(a.fleet.envelope()!)
            }
            let gate = try GateFixture(primary: a.dispatch, bridge: bridge, controller: b.id)
            if scenario == "incremental" {
                channel = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env)
                DeviceFleetGate.fixtureExchange = { root, peer, frame in
                    guard root == b.registry.root.path, peer.id == a.id else { throw DeviceFleetError.malformed }
                    return try gate.exchange(frame, controller: b.id)
                }
            }
            defer { DeviceFleetGate.fixtureExchange = nil }
            let secondary = TatwoMemorySyncEngine(paths: { q }, dispatch: channel, fetch: { paths, repository in
                let result = TatwoMemorySyncEngine.runGit(["fetch", "-q", "--", repository, "+HEAD:" + TatwoMemorySyncEngine.primaryRef], in: paths.memory)
                guard result.status == 0 else { throw DeviceFleetError.malformed }
            })
            if scenario == "memory-endpoints" {
                var peer = b.registry.list().first { $0.id == a.id }!
                peer.endpoints = [.init(kind: .lan, host: "192.0.2.201"), .init(kind: .tunnel, host: "192.0.2.202")]
                _ = try b.registry.add(peer)
            }
            let fakeSSH = b.dispatch.root.appendingPathComponent("synthetic-ssh")
            let script = "#!/bin/sh\ncase \"$*\" in *StrictHostKeyChecking=yes*UserKnownHostsFile=*) ;; *) exit 90;; esac\ncase \"$*\" in *git-receive-pack*) exec /usr/bin/git receive-pack '" + p.memory.path + "';; *) exit 91;; esac\n"
            let endpointScript = scenario == "memory-endpoints" ? script.replacingOccurrences(of: "case \"$*\" in *git-receive-pack*", with: "case \"$*\" in *192.0.2.201*) echo 'ssh: connect to host 192.0.2.201 port 22: Connection refused' >&2; exit 255;; esac\ncase \"$*\" in *192.0.2.202*git-receive-pack*") : script
            try FileManager.default.createDirectory(at: fakeSSH.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(endpointScript.utf8).write(to: fakeSSH); _ = chmod(fakeSSH.path, 0o700)
            secondary.fixturePushLink = { let link = RemoteHostLink(environment: b.env); link.fixturePushSSH = fakeSSH; return link }
            let result = secondary.runOnce(.manual)
            print("W187R5 memory status " + result.line + " detail=" + (result.detail ?? "none"))
            try check(scenario == "memory-pin" ? "MEM-01-real-pushPinned-delivers-without-pushOverride" : "MEM-02-increment-delivered-through-native-gate", result.state == .synced && FileManager.default.fileExists(atPath: p.memory.appendingPathComponent("new.md").path))
            if scenario == "memory-endpoints" {
                if ProcessInfo.processInfo.environment["TATWO2_W187_R7"] == "memory-endpoints" {
                    for diagnostic in ["Host key verification failed.", "kex_exchange_identification: Connection reset by peer", "Connection closed by synthetic peer port 22"] {
                        let retryScript = script.replacingOccurrences(of: "case \"$*\" in *git-receive-pack*", with: "case \"$*\" in *192.0.2.201*) echo '" + diagnostic + "' >&2; exit 255;; esac\ncase \"$*\" in *192.0.2.202*git-receive-pack*")
                        try Data(retryScript.utf8).write(to: fakeSSH)
                        let link = RemoteHostLink(environment: b.env); link.fixturePushSSH = fakeSSH
                        try link.pushPinned(device: b.registry.list().first { $0.id == a.id }!, repository: p.memory.path,
                            localRepository: q.memory, commit: TatwoMemorySyncEngine.runGit(["rev-parse", "HEAD"], in: q.memory).text,
                            ref: TatwoMemorySyncEngine.inboxRef(b.id))
                        try check("R7-MEM-01-preauthentication-failure-falls-through-" + diagnostic, true)
                    }
                }
                let trace = b.dispatch.root.appendingPathComponent("synthetic-push-hosts")
                let rejecting = "#!/bin/sh\ncase \"$*\" in *git-receive-pack*) ;; *) exit 91;; esac\ncase \"$*\" in *192.0.2.201*) echo first >> '" + trace.path + "'; echo 'Authenticated to synthetic peer' >&2; echo 'ssh: connect to host 192.0.2.201 port 22: Connection refused' >&2; exit 255;; *) echo duplicate >> '" + trace.path + "'; exit 0;; esac\n"
                try Data(rejecting.utf8).write(to: fakeSSH)
                let link = RemoteHostLink(environment: b.env); link.fixturePushSSH = fakeSSH
                do {
                    try link.pushPinned(device: b.registry.list().first { $0.id == a.id }!, repository: p.memory.path,
                        localRepository: q.memory, commit: TatwoMemorySyncEngine.runGit(["rev-parse", "HEAD"], in: q.memory).text,
                        ref: TatwoMemorySyncEngine.inboxRef(b.id))
                    throw DeviceFleetError.signature
                } catch {
                    try check("MEM-01-authenticated-Git-rejection-never-retries-another-endpoint", (error as? LocalizedError)?.errorDescription == "remote_error: branch_push_failed"
                        && (try? String(contentsOf: trace, encoding: .utf8)) == "first\n")
                }
            }
            if scenario == "incremental" { try check("MEM-02-large-shared-history-small-increment-through-native-gate", gate.maxFrame < 128 * 1024 && gate.maxFrame > 0) }
        default: throw DeviceFleetError.malformed
        }
        print("W187R5 SUMMARY failures=0")
    }
}
#endif
