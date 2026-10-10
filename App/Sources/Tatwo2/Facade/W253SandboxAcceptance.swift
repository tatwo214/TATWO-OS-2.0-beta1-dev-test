#if DEBUG
import Foundation

/// Synthetic identities and keys only. No listener, SSH transport, Keychain or account access.
enum W253SandboxAcceptance {
    static func run() async throws -> Bool {
        try await Task.detached { try checks(); return true }.value
    }
    private static func checks() throws {
        let fm = FileManager.default, outer = ProcessInfo.processInfo.environment
        guard let staging = outer["TATWO_STAGING_ROOT"], let live = outer["TATWO2_LIVE_ROOT"],
              DeviceIdentityStore.canonical(URL(fileURLWithPath: live)).path.hasPrefix(
                DeviceIdentityStore.canonical(URL(fileURLWithPath: staging)).path + "/") else {
            throw DeviceFleetError.malformed
        }
        let root = URL(fileURLWithPath: live).appendingPathComponent("w253-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = 0
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else {
                print("W253SANDBOX FAIL \(name) — stop; reproduce with TATWO2_SELFTEST=w253sandbox")
                throw NSError(domain: "W253SANDBOX_" + name, code: 1)
            }
            passed += 1; print("W253SANDBOX PASS \(name)")
        }
        func make(_ index: Int, primary: Bool = false, primaryID: String? = nil) throws -> DeviceFleetAcceptance.Fake {
            let base = root.appendingPathComponent("device-\(index)")
            let entry = TatwoEntry(environment: ["TATWO_OS_ROOT": base.appendingPathComponent("entry").path], preference: nil)
            try fm.createDirectory(at: entry.root, withIntermediateDirectories: true)
            try Data("synthetic constitution\n".utf8).write(to: entry.constitution)
            let id = String(format: "%08x-1111-4111-8111-111111111111", index + 1)
            try DeviceIdentity(deviceID: id, name: "fixture \(index)", hardwareModel: "fixture",
                role: primary ? .primary : .secondary, epoch: 1, primaryDeviceID: primaryID ?? id,
                updatedAt: Date()).encoded().write(to: entry.deviceJSON)
            let key = base.appendingPathComponent("client-key").path, host = base.appendingPathComponent("host-key").path
            for path in [key, host] {
                guard try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", path]).0 == 0 else {
                    throw DeviceFleetError.missingKey
                }
            }
            let env = ["TATWO_OS_ROOT": entry.root.path, "TATWO2_LIVE_ROOT": base.appendingPathComponent("live").path,
                "TATWO2_AUTHORIZED_KEYS": base.appendingPathComponent("authorized_keys").path,
                "TATWO2_SSH_KNOWN_HOSTS": base.appendingPathComponent("known_hosts").path,
                "TATWO2_SSH_KEY_PATH": key, "TATWO2_SSH_HOST_KEY_PUB": host + ".pub",
                "TATWO2_PAIRING_HOST": "192.0.2.\(index + 11)"]
            let registry = DeviceRegistry(environment: env)
            let dispatch = DeviceDispatch(entry: entry, registry: registry, environment: env, retireBackup: { _ in },
                rpc: { _, _, _ in throw DeviceDispatch.Failure(reason: "w253_network_forbidden") })
            return .init(id: id, env: env, registry: registry, dispatch: dispatch)
        }
        DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false })
        defer { DeviceFleetRevocation.testHooks = nil }
        let host = try make(0, primary: true), owner = try make(1, primaryID: host.id), sandbox = try make(2, primaryID: host.id)
        try host.fleet.bootstrapPrimary(host: host.host)
        var roster = try host.fleet.current()!.roster!
        let faction = roster.factions.first!
        var ownerRow = try owner.fleet.localMember(faction: faction, host: owner.host)
        ownerRow.user = "fixture"
        var sandboxRow = try sandbox.fleet.localMember(faction: faction, host: sandbox.host)
        sandboxRow.role = .sandbox; sandboxRow.user = "fixture"
        roster.devices += [ownerRow, sandboxRow]
        roster.edges = DeviceFleetRoster.defaults(groups: roster.groups, devices: roster.devices)
        try host.fleet.publish(&roster)
        let sandboxFP = try DeviceRegistry.fingerprint(publicKey: sandbox.clientKey)
        let ownerFP = try DeviceRegistry.fingerprint(publicKey: owner.clientKey)
        try check("oneway-owner-can-control-sandbox", Set(try roster.capabilities(from: host.id, to: sandbox.id)) == Set(DeviceFleetCapabilities.sandbox))
        try check("sandbox-no-return-arrow", roster.capabilities(from: sandbox.id, to: host.id).isEmpty)
        try check("sandbox-key-not-authorized", !host.registry.fleetHasAuthorizedFingerprint(sandboxFP))
        try check("owner-key-authorized", host.registry.fleetHasAuthorizedFingerprint(ownerFP))
        // Model a historical/manual unrestricted authorization. App checks must still refuse it.
        let cleanKeys = try Data(contentsOf: host.registry.authorizedKeysURL)
        try DeviceDispatchSafeFile.write(cleanKeys + Data((DeviceFleetPublicKey.withoutComment(try sandbox.clientKey) + " fixture-old-key\n").utf8), url: host.registry.authorizedKeysURL)
        try check("old-key-present-for-attack", host.registry.fleetHasAuthorizedFingerprint(sandboxFP))
        let bridge = OSAgentBridge.fleetFixtureBridge()
        for method in ["memory_search", "memory_sync_export", "dispatch_fetch", "dispatch_rooms", "run_background", "job_submit", "job_status"] {
            try check("normal-owner-\(method)-gate-allowed", OSSocketCaller.sshMethodAllowed(fingerprint: ownerFP, method: method, registry: host.registry))
        }
        let fileProof = try owner.dispatch.signed(method: "document_inspect", payload: ["id": "os"], recipient: host.id)
        let fileReply = try bridge.fixtureHandle(dispatch: host.dispatch, method: "document_inspect", params: fileProof)
        try check("normal-owner-document-inspect", fileReply["ok"] as? Bool == true && (fileReply["result"] as? [String: Any])?["text"] as? String == "synthetic constitution\n")
        let groups: [(String, [String])] = [
            ("memory", ["memory_search", "memory_get", "memory_save", "memory_propose", "memory_list", "memory_decide", "memory_sync_export", "memory_sync_import", "user_remember"]),
            ("gbrain", ["gbrain_allai", "gbrain_search", "gbrain_write"]),
            ("dispatch", ["dispatch_fetch", "dispatch_ack", "dispatch_wake", "dispatch_rooms", "chatgpt_dispatch", "hands_build"]),
            ("background", ["run_background", "background_status", "background_list", "stop_background"]),
            ("job-queue", ["job_submit", "job_status"])]
        let params: [String: Any] = ["query": "fixture", "command": "false", "project_id": "fixture"]
        for (family, methods) in groups {
            for method in methods {
                let proof = try sandbox.dispatch.signedHandshake(method: method, params: params, recipient: host.id)
                let reply = try bridge.fixtureHandle(dispatch: host.dispatch, method: method, params: params, handshake: proof, fingerprint: sandboxFP)
                try check("\(family)-\(method)-denied", reply["ok"] as? Bool == false && reply["error"] as? String == "fleet_capabilityDenied")
                try check("\(family)-\(method)-SSH-gate-denied", !OSSocketCaller.sshMethodAllowed(fingerprint: sandboxFP, method: method, registry: host.registry))
            }
        }
        for method in ["memory_future", "command_memory", "MEMORY_GET", "memory_get ", "sandbox_fetch_job", "fleet_propose"] {
            let proof = try sandbox.dispatch.signedHandshake(method: method, params: params, recipient: host.id)
            let reply = try bridge.fixtureHandle(dispatch: host.dispatch, method: method, params: params, handshake: proof)
            try check("renamed-\(method)-denied", reply["error"] as? String == "fleet_capabilityDenied")
        }
        let normal = try owner.dispatch.signedHandshake(method: "device_status", params: [:], recipient: host.id)
        try check("normal-owner-device-status", bridge.fixtureHandle(dispatch: host.dispatch, method: "device_status", params: [:], handshake: normal)["ok"] as? Bool == true)
        try check("replay-consumed-owner-proof-denied", bridge.fixtureHandle(dispatch: host.dispatch, method: "device_status", params: [:], handshake: normal)["error"] as? String == "fleet_capabilityDenied")
        let wrongMethod = try owner.dispatch.signedHandshake(method: "device_status", params: [:], recipient: host.id)
        try check("method-substitution-denied", bridge.fixtureHandle(dispatch: host.dispatch, method: "run_background", params: [:], handshake: wrongMethod)["error"] as? String == "fleet_capabilityDenied")
        func expired(_ device: DeviceFleetAcceptance.Fake) throws -> [String: Any] {
            var proof = try device.dispatch.signedHandshake(method: "device_status", params: [:], recipient: host.id)
            var body = try JSONSerialization.jsonObject(with: Data(base64Encoded: proof["body"] as! String)!) as! [String: Any]
            body["issuedAt"] = Date().addingTimeInterval(-600).timeIntervalSince1970
            let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let signed = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", device.env["TATWO2_SSH_KEY_PATH"]!, "-P", "", "-n", "tatwo2-rpc"], input: bytes)
            guard signed.0 == 0 else { throw DeviceFleetError.signature }
            proof["body"] = bytes.base64EncodedString(); proof["signature"] = signed.1.base64EncodedString()
            return proof
        }
        try check("expired-valid-owner-envelope-denied", bridge.fixtureHandle(dispatch: host.dispatch, method: "device_status", params: [:], handshake: expired(owner))["error"] as? String == "rpc_proof_expired")
        try check("expired-sandbox-envelope-denied", bridge.fixtureHandle(dispatch: host.dispatch, method: "device_status", params: [:], handshake: expired(sandbox))["error"] as? String == "fleet_capabilityDenied")
        let pending = try owner.dispatch.signedHandshake(method: "device_status", params: [:], recipient: host.id)
        roster = try host.fleet.current()!.roster!
        roster.devices[roster.devices.firstIndex { $0.id == owner.id }!].role = .sandbox
        roster.edges = DeviceFleetRoster.defaults(groups: roster.groups, devices: roster.devices)
        try host.fleet.publish(&roster)
        try check("old-owner-credential-after-sandbox-conversion-denied", bridge.fixtureHandle(dispatch: host.dispatch, method: "device_status", params: [:], handshake: pending)["error"] as? String == "fleet_capabilityDenied")
        let reload = DeviceDispatch(entry: TatwoEntry(environment: host.env, preference: nil), registry: host.registry,
            environment: host.env, retireBackup: { _ in }, rpc: { _, _, _ in throw DeviceFleetError.malformed })
        let old = try sandbox.dispatch.signedHandshake(method: "memory_get", params: params, recipient: host.id)
        try check("restart-reloads-sandbox-denial", bridge.fixtureHandle(dispatch: reload, method: "memory_get", params: params, handshake: old)["error"] as? String == "fleet_capabilityDenied")
        try host.fleet.revoke(sandbox.id)
        try check("revoked-old-key-removed", !host.registry.fleetHasAuthorizedFingerprint(sandboxFP))
        try check("revoked-old-proof-denied", bridge.fixtureHandle(dispatch: reload, method: "memory_get", params: params, handshake: old)["error"] as? String == "fleet_capabilityDenied")
        print("W253SANDBOX SUMMARY failures=0 passed=\(passed)")
    }
}
#endif
