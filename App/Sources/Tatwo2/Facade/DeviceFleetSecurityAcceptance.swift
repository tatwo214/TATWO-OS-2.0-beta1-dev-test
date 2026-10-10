#if DEBUG
import CryptoKit
import Darwin
import Foundation
import Network

enum DeviceFleetSecurityAcceptance {
    static func run(host: DeviceFleetAcceptance.Fake, client: DeviceFleetAcceptance.Fake,
                    managed: DeviceFleetAcceptance.Fake) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw NSError(domain: "W187SEC_FAIL_" + name, code: 1) }
            print("W187SEC PASS \(name)")
        }
        func rejects(_ name: String, reason: String? = nil, _ action: () throws -> Void) throws {
            do { try action() } catch {
                if let reason {
                    guard case DevicePairingClient.ClientError.pairingRejected(let actual) = error, actual == reason else { throw error }
                }
                print("W187SEC PASS \(name)"); return
            }
            throw NSError(domain: "W187SEC_UNEXPECTED_ACCEPT_" + name, code: 1)
        }
        let first = DevicePairingDiscovery.sessionTag("ABC123"), second = DevicePairingDiscovery.sessionTag("ABC123")
        try check("PAIR-01-independent-advertisements", first != second && first.count == 64 && second.count == 64)
        let digest = SHA256.hash(data: Data("ABC123".utf8)).map { String(format: "%02x", $0) }.joined()
        try check("PAIR-01-no-code-derived-bytes", !first.contains(String(digest.prefix(16))) && !second.contains(String(digest.prefix(16))))
        let nonce = DevicePairingAuth.makeNonce(), key = DevicePairingAuth.key(code: "ABC123", nonce: DevicePairingAuth.makeNonce())!
        let plaintext = try JSONSerialization.data(withJSONObject: ["names": ["Synthetic manager", "Synthetic member"],
            "addresses": ["192.0.2.80", "member.example.invalid"], "user": "fixture",
            "publicKey": client.clientKey, "group": "Synthetic group"])
        let ciphertext = try DevicePairingAuth.sealResponse(plaintext, key: key)
        let raw = String(decoding: ciphertext, as: UTF8.self)
        for secret in ["Synthetic manager", "Synthetic member", "192.0.2.80", "member.example.invalid", "fixture", "Synthetic group", try client.clientKey] {
            try check("PAIR-07-wire-hides-member-field", !raw.contains(secret))
        }
        try check("PAIR-07-authenticated-roundtrip", DevicePairingAuth.openResponse(ciphertext, key: key) == plaintext)
        try check("PAIR-07-fresh-GCM-nonce", DevicePairingAuth.sealResponse(plaintext, key: key) != ciphertext)
        try rejects("PAIR-07-wrong-key-refused") { _ = try DevicePairingAuth.openResponse(ciphertext, key: SymmetricKey(size: .bits256)) }
        let falseProof = DevicePairingAuth.mac(key: SymmetricKey(size: .bits256), label: "host-proof", fields: [nonce])
        try check("PAIR-01-unknown-code-proof-refused", !DevicePairingAuth.verify(mac: falseProof, key: key, label: "host-proof", fields: [nonce]))

        var env = host.env; env["TATWO2_PAIRING_HOST"] = "127.0.0.1"
        let server = DevicePairingHost(registry: host.registry, environment: env, peerHostResolver: { _ in client.host })
        defer { server.cancelPairingWindow() }
        let joiner = DevicePairingClient(registry: client.registry, environment: client.env,
            sshVerifier: { _, _, _ in true }, hostKeyResolver: { _ in try? host.hostKey })
        func pair(_ kind: DeviceFactionKind = .owner, faction: String? = nil) throws {
            let window = try server.startPairingWindow(kind: kind, factionID: faction)
            _ = try joiner.pair(host: "127.0.0.1", port: Int(window.listenAddress.split(separator: ":").last!)!,
                code: window.code, name: "Synthetic fresh member", kind: kind, consentToManagement: kind != .owner)
        }
        let before = try Data(contentsOf: host.registry.authorizedKeysURL)
        let state = try Data(contentsOf: host.fleet.url)
        let known = try Data(contentsOf: host.registry.fleetKnownHostsURL)
        joiner.omitFleetForTest = true
        try rejects("PAIR-06-missing-fleet-refused", reason: DeviceFleetError.consentRequired.reason) { try pair() }
        try check("PAIR-06-missing-fleet-no-authorization", Data(contentsOf: host.registry.authorizedKeysURL) == before)
        joiner.omitFleetForTest = false
        server.afterConsume = { server.cancelPairingWindow() }
        try rejects("PAIR-04-closed-managed-window-refused", reason: "pairing_window_closed") { try pair(.managed, faction: "staff") }
        try rejects("PAIR-04-closed-sandbox-window-refused", reason: "pairing_window_closed") { try pair(.sandbox, faction: "sandbox") }
        try check("PAIR-04-no-owner-fallback", Data(contentsOf: host.registry.authorizedKeysURL) == before)
        server.afterConsume = nil
        server.enrollmentCheck = { throw DeviceFleetError.confirmationRequired }
        try rejects("PAIR-06-approval-failure-refused", reason: DeviceFleetError.confirmationRequired.reason) { try pair() }
        try check("PAIR-06-rollback-authorized-keys", Data(contentsOf: host.registry.authorizedKeysURL) == before)
        try check("PAIR-06-rollback-roster-and-pending", Data(contentsOf: host.fleet.url) == state)
        try check("PAIR-06-rollback-host-pins", Data(contentsOf: host.registry.fleetKnownHostsURL) == known)

        server.enrollmentCheck = nil
        var captured = Data(), capturedKey: SymmetricKey?
        server.captureWire = { bytes, key in captured = bytes; capturedKey = key }
        try pair()
        try check("PAIR-07-real-TCP-response-captured", !captured.isEmpty && capturedKey != nil)
        let clear = try DevicePairingAuth.openResponse(captured, key: capturedKey!)
        let response = try JSONSerialization.jsonObject(with: clear) as! [String: Any]
        let offer = try JSONDecoder().decode(DeviceFleetPairOffer.self, from: Data(base64Encoded: response["fleet"] as! String)!)
        let members = try JSONDecoder().decode(DeviceFleetPayload.self, from: offer.envelope!.body).roster!.devices
        let rawResponse = String(decoding: captured, as: UTF8.self)
        for member in members {
            for field in [member.name, member.user, member.clientPublicKey ?? "", member.hostPublicKey ?? ""] + member.endpoints.map(\.host) where !field.isEmpty {
                try check("PAIR-07-real-wire-hides-roster-field", !rawResponse.contains(field))
            }
        }
        let text = try String(contentsOf: managed.registry.authorizedKeysURL, encoding: .utf8)
        try check("REG-03-restricted-arrows", text.split(separator: "\n").filter { $0.contains("tatwo2-device:") }.allSatisfy { $0.hasPrefix("restrict,command=") })
        let ownerText = try String(contentsOf: host.registry.authorizedKeysURL, encoding: .utf8)
        try check("REG-03-MAIN-owner-unrestricted", ownerText.split(separator: "\n").allSatisfy { !$0.hasPrefix("restrict,") })
        let gate = DeviceFleetGate.path(registry: managed.registry)
        try check("REG-03-stable-gate-content", Data(contentsOf: gate) == DeviceFleetGate.bytes(registry: managed.registry))
        // Model d1's old restricted entry using only this fixture's authorized file.
        let oldCommand = "/usr/bin/" + "python3 '" + gate.path + ".py' --device "
        let legacy = text.split(separator: "\n").map { line -> String in
            guard let end = line.range(of: "\" ssh-ed25519") else { return String(line) }
            let deviceID = String(line.split(separator: " ").last!.dropFirst("tatwo2-device:".count))
            return "restrict,command=\"" + oldCommand + deviceID + String(line[end.lowerBound...])
        }
        try DeviceDispatchSafeFile.write(Data((legacy.joined(separator: "\n") + "\n").utf8), url: managed.registry.authorizedKeysURL)
        let pendingIDs = Set(legacy.compactMap { $0.split(separator: " ").last }.map { String($0.dropFirst("tatwo2-device:".count)) })
        try managed.registry.fleetReconcileKeys([], preserveLegacy: [], pending: pendingIDs)
        let pendingMigrated = try String(contentsOf: managed.registry.authorizedKeysURL, encoding: .utf8)
        try check("REG-03-pending-native-migration-keeps-restrictions", pendingMigrated.split(separator: "\n").allSatisfy {
            $0.hasPrefix("restrict,command=") && $0.contains(gate.path) && !$0.contains("python3") && !$0.contains(".py'")
        })
        try managed.fleet.reconcile(managed.fleet.current()!)
        let migrated = try String(contentsOf: managed.registry.authorizedKeysURL, encoding: .utf8)
        try check("REG-03-native-migration-keeps-restrictions", migrated.split(separator: "\n").allSatisfy {
            $0.hasPrefix("restrict,command=") && $0.contains(gate.path) && !$0.contains("python3") && !$0.contains(".py'")
        })
        let duplicateKey = try host.clientKey
        let restrictedBefore = try Data(contentsOf: managed.registry.authorizedKeysURL)
        try DeviceDispatchSafeFile.write(restrictedBefore + Data((duplicateKey + " manually-imported\n").utf8), url: managed.registry.authorizedKeysURL)
        let duplicateFile = try Data(contentsOf: managed.registry.authorizedKeysURL)
        let fingerprint = try DeviceRegistry.fingerprint(publicKey: duplicateKey)
        func markedHostRow(_ line: String) -> Bool {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.last?.hasPrefix("tatwo2-device:") == true,
                  let index = fields.firstIndex(of: "ssh-ed25519"), index + 1 < fields.count else { return false }
            return (try? DeviceRegistry.fingerprint(publicKey: "\(fields[index]) \(fields[index + 1])")) == fingerprint
        }
        let protectedRows = String(decoding: restrictedBefore, as: UTF8.self).components(separatedBy: "\n").filter(markedHostRow)
        try managed.fleet.reconcile(managed.fleet.current()!)
        let conflictResult = try managed.registry.fleetReconcileKeys([(host.id, duplicateKey)], preserveLegacy: [], pending: [])
        try check("REG-03-unmarked-duplicate-refuses-restricted-update", conflictResult == [host.id: "authorized_keys_user_line_conflict"])
        let reconciledFile = try Data(contentsOf: managed.registry.authorizedKeysURL)
        let hostRows = String(decoding: reconciledFile, as: UTF8.self).components(separatedBy: "\n").filter(markedHostRow)
        let manualRow = Data((duplicateKey + " manually-imported\n").utf8)
        try check("REG-03-unmarked-duplicate-cannot-bypass-gate", !protectedRows.isEmpty && hostRows == protectedRows
            && hostRows.allSatisfy { $0.hasPrefix("restrict,") }
            && duplicateFile.range(of: manualRow) != nil && reconciledFile.range(of: manualRow) != nil)
        let independent = client
        let results = try managed.registry.fleetReconcileKeys([(host.id, duplicateKey), (independent.id, independent.clientKey)], preserveLegacy: [], pending: [])
        try check("REG-03-other-device-still-synchronizes", results == conflictResult && managed.registry.fleetPublicKey(deviceID: independent.id) != nil)
        let beforeRevoke = try Data(contentsOf: managed.registry.authorizedKeysURL)
        try managed.registry.revokeAuthorizedKey(deviceID: host.id, fingerprint: fingerprint)
        try check("REG-03-revoke-removes-manual-and-managed", !managed.registry.fleetHasAuthorizedFingerprint(fingerprint))
        let backup = try FileManager.default.contentsOfDirectory(at: managed.registry.root.appendingPathComponent("backups/authorized_keys"), includingPropertiesForKeys: nil).first { $0.pathExtension == "bak" }!
        try check("REG-03-backup-restores-exact-file", Data(contentsOf: backup) == beforeRevoke)
        try DeviceDispatchSafeFile.write(Data(contentsOf: backup), url: managed.registry.authorizedKeysURL)
        try check("REG-03-restore-is-usable", Data(contentsOf: managed.registry.authorizedKeysURL) == beforeRevoke)
        // Restore only this synthetic attack fixture so the existing gate probes can continue.
        try DeviceDispatchSafeFile.write(restrictedBefore, url: managed.registry.authorizedKeysURL)
        let policy = try JSONSerialization.jsonObject(with: Data(contentsOf: managed.registry.root.appendingPathComponent("fleet-gate-policy.json"))) as! [String: Any]
        let id = (policy["controllers"] as! [String: Any]).keys.sorted().first!
        func runGate(command: String, request: String = "") throws -> (Int32, String) {
            let process = Process(), output = Pipe(), input = Pipe()
            process.executableURL = gate
            process.arguments = ["--device", id, "--policy", managed.registry.root.appendingPathComponent("fleet-gate-policy.json").path]
            process.environment = ["SSH_ORIGINAL_COMMAND": command]
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            do { try process.run() } catch { return (126, "") }
            input.fileHandleForWriting.write(Data(request.utf8)); try input.fileHandleForWriting.close()
            let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
        }
        try check("REG-03-shell-refused", runGate(command: "sh").0 == 126)
        try check("REG-03-forward-command-refused", runGate(command: "ssh -L 9999:localhost:22").0 == 126)
        let unlisted = try runGate(command: "tatwo-fleet-rpc", request: "{\"id\":1,\"method\":\"unlisted_method\"}\n")
        if !unlisted.1.contains("fleet_gate_denied") { print("W187SEC gate fixture status=\(unlisted.0) response=\(unlisted.1)") }
        try check("DM-05-unlisted-method-refused", unlisted.1.contains("fleet_gate_denied"))
        try check("REG-03-local-native-process-is-not-SSH", DeviceFleetGate.identity(pid: getpid(), registry: managed.registry) == nil)
        let localGate = Process(), localInput = Pipe()
        localGate.executableURL = gate
        localGate.arguments = ["--device", id, "--policy", managed.registry.root.appendingPathComponent("fleet-gate-policy.json").path]
        localGate.environment = ["SSH_ORIGINAL_COMMAND": "tatwo-fleet-rpc"]
        localGate.standardInput = localInput; localGate.standardOutput = FileHandle.nullDevice; localGate.standardError = FileHandle.nullDevice
        try localGate.run()
        defer { if localGate.isRunning { localGate.terminate() } }
        let record = managed.registry.root.appendingPathComponent("gate-sessions/\(localGate.processIdentifier).json")
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: record.path) { usleep(1000) }
        try check("REG-03-native-registration-before-request", FileManager.default.fileExists(atPath: record.path))
        try check("REG-03-native-without-system-sshd-refused", DeviceFleetGate.identity(pid: localGate.processIdentifier, registry: managed.registry) == nil)
        DeviceFleetGate.terminateRegistered(id, registry: managed.registry)
        usleep(50_000)
        try check("TR-02-forged-registration-cannot-kill-local-native-process", localGate.isRunning)
        try localInput.fileHandleForWriting.close(); localGate.waitUntilExit()
        let intact = try Data(contentsOf: gate)
        try DeviceDispatchSafeFile.write(intact + Data([0]), url: gate)
        try rejects("REG-03-tampered-native-gate-refused") {
            try DeviceFleetGate.install(registry: managed.registry)
        }
        let policyURL = managed.registry.root.appendingPathComponent("fleet-gate-policy.json")
        let policyBytes = try Data(contentsOf: policyURL)
        var previousVersionPolicy = try JSONSerialization.jsonObject(with: policyBytes) as! [String: Any]
        let previousVersion = intact + Data([0])
        previousVersionPolicy["gateHash"] = SHA256.hash(data: previousVersion).map { String(format: "%02x", $0) }.joined()
        try DeviceDispatchSafeFile.write(JSONSerialization.data(withJSONObject: previousVersionPolicy), url: policyURL)
        try DeviceFleetGate.install(registry: managed.registry)
        try check("REG-03-intact-previous-native-version-upgrades", Data(contentsOf: gate) == intact)
        try DeviceDispatchSafeFile.write(policyBytes, url: policyURL)
        try DeviceDispatchSafeFile.write(intact, url: gate); _ = chmod(gate.path, 0o700)
        let bytes = try Data(contentsOf: gate); try FileManager.default.removeItem(at: gate)
        defer { try? DeviceDispatchSafeFile.write(bytes, url: gate); _ = chmod(gate.path, 0o700) }
        try check("REG-03-missing-gate-refused", runGate(command: "tatwo-fleet-rpc").0 != 0)
        try rejects("REG-03-published-missing-native-gate-not-reinstalled") {
            try DeviceFleetGate.install(registry: managed.registry)
        }
        print("W187SEC SUMMARY failures=0")
    }
}
#endif
