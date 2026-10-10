import CryptoKit
import Darwin
import Foundation

/// Stable forced command; no shell, forwarding, executable selection or remote socket selection.
enum DeviceFleetGate {
    enum CallError: Error, Equatable, LocalizedError {
        case unreachable, appUnavailable, refused, contentTooLarge, clockMismatch, primaryTransferred, rejected(String)
        var errorDescription: String? { DeviceFleetReason.plain(self) }
        var reason: String {
            switch self {
            case .unreachable: "fleet_ssh_endpoint_unreachable"
            case .appUnavailable: "fleet_app_rpc_unavailable"
            case .refused: "fleet_app_rpc_refused"
            case .contentTooLarge: "rpc_parameters_too_large"
            case .clockMismatch: "rpc_proof_expired"
            case .primaryTransferred: "primary_transferred"
            case .rejected(let reason): reason
            }
        }
    }
    #if DEBUG
    nonisolated(unsafe) static var fixtureExchange: ((String, DeviceRecord, [String: Any]) throws -> (Int32, String, Data))?
    nonisolated(unsafe) static var fixtureSSH: URL?
    #endif
    static func path(registry: DeviceRegistry) -> URL {
        registry.root.deletingLastPathComponent().appendingPathComponent("bin/fleet-gate")
    }
    /// The signed App supplies the helper; development builds use its SwiftPM sibling.
    /// No environment variable or request can select the executable.
    private static func bundledHelper() throws -> URL {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return bundle.appendingPathComponent("Contents/Helpers/TatwoFleetGate")
        }
        #if DEBUG
        guard let executable = executablePath(getpid()) else { throw DeviceFleetError.malformed }
        return URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("TatwoFleetGate")
        #else
        throw DeviceFleetError.malformed
        #endif
    }
    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
    static func bytes(registry: DeviceRegistry) throws -> Data {
        let data = try DeviceDispatchSafeFile.read(bundledHelper(), limit: 16 * 1024 * 1024)
        guard !data.isEmpty else { throw DeviceFleetError.malformed }
        return data
    }
    private static func matches(_ file: URL, expected: Data) -> Bool {
        guard let actual = try? DeviceDispatchSafeFile.read(file, limit: 16 * 1024 * 1024), !actual.isEmpty else { return false }
        return SHA256.hash(data: actual) == SHA256.hash(data: expected)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func install(registry: DeviceRegistry) throws {
        let file = path(registry: registry), expected = try bytes(registry: registry)
        let policyURL = registry.root.appendingPathComponent("fleet-gate-policy.json")
        let installedURL = registry.root.appendingPathComponent("fleet-gate-install.json")
        func savedHash(_ url: URL) -> String? {
            (try? DeviceDispatchSafeFile.read(url, limit: 1024 * 1024))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["gateHash"] as? String
        }
        let recognized = Set([savedHash(installedURL), savedHash(policyURL)].compactMap { $0 })
        let authorization = (try? DeviceDispatchSafeFile.read(registry.authorizedKeysURL, limit: 4 * 1024 * 1024)) ?? Data()
        let referenced = String(decoding: authorization, as: UTF8.self).split(separator: "\n").contains {
            $0.contains("'\(file.path)' --device ") || $0.contains("\(file.path) --device ")
        }
        var info = stat()
        if lstat(file.path, &info) == 0 {
            if !matches(file, expected: expected) {
                // Upgrade an intact journaled helper, including pre-enrollment installs.
                // Legacy unjournaled bytes may migrate only without authorized gate references.
                let actual = try DeviceDispatchSafeFile.read(file, limit: 16 * 1024 * 1024)
                guard recognized.contains(digest(actual)) || (recognized.isEmpty && !referenced) else { throw DeviceFleetError.malformed }
                try DeviceDispatchSafeFile.write(expected, url: file)
            }
        } else {
            // Re-provision only when no authorization references the missing helper.
            // A referenced missing gate remains closed regardless of the journal.
            guard errno == ENOENT, !referenced else { throw DeviceFleetError.malformed }
            try DeviceDispatchSafeFile.write(expected, url: file)
        }
        guard chmod(file.path, 0o700) == 0, matches(file, expected: expected) else { throw DeviceFleetError.malformed }
        try DeviceDispatchSafeFile.write(JSONSerialization.data(withJSONObject: ["gateHash": digest(expected)]), url: installedURL)
    }
    static func publish(registry: DeviceRegistry, controllers: [String: DeviceFleetController]) throws {
        try install(registry: registry)
        let policy: [String: Any] = ["socket": registry.root.appendingPathComponent("os.sock").path,
            "gateHash": digest(try bytes(registry: registry)),
            "controllers": controllers.mapValues { ["fingerprint": $0.clientKeyFingerprint, "capabilities": $0.capabilities] as [String: Any] },
            "methods": DeviceFleetCapabilities.methodTable]
        try DeviceDispatchSafeFile.write(JSONSerialization.data(withJSONObject: policy),
            url: registry.root.appendingPathComponent("fleet-gate-policy.json"))
    }
    static func ownerFallbackSafe(registry: DeviceRegistry, fingerprint: String? = nil) -> Bool {
        guard let fingerprint else { return false }
        let fleet = DeviceFleetStore(registry: registry, environment: registry.fleetEnvironment)
        do {
            guard let trust = try fleet.trust(), let roster = try fleet.current()?.roster,
                  roster.kind(of: trust.localID) == .owner,
                  let peer = roster.activeMember(clientFingerprint: fingerprint),
                  roster.kind(of: peer.id) == .owner, !roster.revoked.contains(peer.id),
                  registry.fleetHasAuthorizedFingerprint(fingerprint) else { return false }
            return Set(try roster.capabilities(from: peer.id, to: trust.localID)) == Set(DeviceFleetCapabilities.all)
        } catch { return false }
    }
    /// Identity is bound to kernel PID/argv and system sshd ancestry, never request params.
    static func identity(pid: pid_t, registry: DeviceRegistry, requireAuthorized: Bool = true) -> (id: String, fingerprint: String)? {
        let file = path(registry: registry)
        guard let expected = try? bytes(registry: registry), matches(file, expected: expected),
              executablePath(pid) == file.path,
              let args = DeviceFleetRevocation.processArguments(pid)?.args,
              args.count == 5, args[0] == file.path, args[1] == "--device",
              args[3] == "--policy", args[4] == registry.root.appendingPathComponent("fleet-gate-policy.json").path,
              DeviceFleetRevocation.isSystemSSHDescendant(pid) else { return nil }
        let id = args[2]
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        if !requireAuthorized { return (id, "") }
        guard let data = try? DeviceDispatchSafeFile.read(registry.root.appendingPathComponent("fleet-gate-policy.json"), limit: 1024 * 1024),
              let policy = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = policy["controllers"] as? [String: [String: Any]],
              let fingerprint = controllers[id]?["fingerprint"] as? String,
              registry.fleetHasAuthorizedFingerprint(fingerprint),
              (try? DeviceFleetStore(registry: registry, environment: registry.fleetEnvironment).capabilities(for: fingerprint)) != nil else { return nil }
        return (id, fingerprint)
    }
    static func terminateRegistered(_ id: String, registry: DeviceRegistry) {
        let folder = registry.root.appendingPathComponent("gate-sessions")
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent), pid > 1,
                  identity(pid: pid, registry: registry, requireAuthorized: false)?.id == id else { continue }
            _ = kill(pid, SIGTERM)
        }
    }
    /// The forced row ignores this command; an unrestricted row executes the same fixed native helper.
    /// The native helper accepts this exact form, and every App request still needs its device proof.
    static func ownerCompatibleCommand(deviceID: String) -> String {
        "env SSH_ORIGINAL_COMMAND=tatwo-fleet-rpc \"$HOME/Library/Application Support/tatwo2/bin/fleet-gate\" --device \(deviceID) --policy \"$HOME/Library/Application Support/tatwo2/live/fleet-gate-policy.json\""
    }
    static func isSSHUnreachable(status: Int32, diagnostics: String) -> Bool {
        guard status == 255, !diagnostics.contains("Authenticated to ") else { return false }
        return diagnostics.split(separator: "\n").contains { line in
            if line.hasPrefix("ssh: Could not resolve hostname ") { return true }
            guard line.hasPrefix("ssh: connect to host ") else { return false }
            return ["Connection refused", "Operation timed out", "Connection timed out", "No route to host", "Network is unreachable", "Host is down"].contains { line.hasSuffix(": " + $0) }
        }
    }
    /// A reachable/ambiguous endpoint wins over a later network failure; never mark a live participant absent.
    static func rpcFailure(_ failures: [Error]) -> Error {
        failures.first { ($0 as? CallError) != .unreachable }
            ?? failures.first ?? DeviceFleetError.unknownMember
    }
    private final class SSHDiagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data(), tail = Data()
        private var authenticated = false
        func append(_ data: Data) {
            lock.withLock {
                let combined = tail + data
                authenticated = authenticated || String(decoding: combined, as: UTF8.self).contains("Authenticated to ")
                tail = Data(combined.suffix(64))
                bytes.append(data.prefix(max(0, 64 * 1024 - bytes.count)))
            }
        }
        var text: String { lock.withLock { (authenticated ? "Authenticated to peer\n" : "") + String(decoding: bytes, as: UTF8.self) } }
    }
    private static func decodeResponse(status: Int32, diagnostics: String, data: Data) throws -> [String: Any] {
        if status == 255, !diagnostics.contains("Authenticated to "), ["Connection reset", "Connection closed"].contains(where: diagnostics.contains) { throw CallError.rejected("ssh_remote_login_unresponsive") }
        if isSSHUnreachable(status: status, diagnostics: diagnostics) { throw CallError.unreachable }
        if status == 0, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           reply["ok"] as? Bool == false {
            if reply["error"] as? String == "app_unavailable" { throw CallError.appUnavailable }
            if reply["error"] as? String == "rpc_proof_expired" { throw CallError.clockMismatch }
            if ["rpc_parameters_too_large", "memory_bundle_too_large"].contains(reply["error"] as? String ?? "") { throw CallError.contentTooLarge }
            let reason = reply["error"] as? String ?? "fleet_app_rpc_refused"
            if ["primary_transferred", "not_primary"].contains(reason) { throw CallError.primaryTransferred }
            if (DeviceFleetReason.unsupportedMethods + DeviceFleetReason.projectionRefusals).contains(reason) { throw CallError.refused }
            // Keep reason codes for routing and diagnostics; generic refusal is not evidence of an old App.
            throw CallError.rejected(reason)
        }
        guard status == 0, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["ok"] as? Bool == true, let result = reply["result"] as? [String: Any] else {
            if status == 0 || diagnostics.contains("Authenticated to ") { throw CallError.appUnavailable }
            throw DeviceFleetError.signature
        }
        return result
    }
    /// Fleet delivery uses stdio over an exec channel; restrict forbids the older -L tunnel.
    static func call(peer: DeviceRecord, method: String, params: [String: Any], registry: DeviceRegistry,
                     revocationKey: String? = nil, handshake: [String: Any]? = nil) throws -> [String: Any] {
        _ = try DeviceFleetSSHPins.lines(for: peer, registry: registry)
        guard let fingerprint = peer.pinnedHostKeyFingerprint,
              let key = revocationKey ?? registry.fleetHostPublicKey(fingerprint: fingerprint),
              try DeviceRegistry.fingerprint(publicKey: key) == fingerprint else { throw DeviceFleetError.keyConflict }
        let pin = registry.root.appendingPathComponent("fleet-rpc-pin-" + UUID().uuidString)
        try DeviceDispatchSafeFile.write(Data(("tatwo-paired-host " + DeviceFleetPublicKey.withoutComment(key) + "\n").utf8), url: pin)
        defer { try? FileManager.default.removeItem(at: pin) }
        let quoted = pin.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var frame: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        if let handshake { frame["deviceHandshake"] = handshake }
        let request = try JSONSerialization.data(withJSONObject: frame) + Data([0x0A])
        guard request.count <= 1024 * 1024 else { throw CallError.contentTooLarge }
        #if DEBUG
        if let fixtureExchange {
            let (status, diagnostics, data) = try fixtureExchange(registry.root.path, peer, frame)
            return try decodeResponse(status: status, diagnostics: diagnostics, data: data)
        }
        #endif
        var failures: [Error] = []
        for endpoint in peer.orderedEndpoints {
            let destination = endpoint.kind == .alias ? endpoint.alias! : endpoint.host
            var args = ["-v", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\"\(quoted)\"", "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "HostKeyAlias=tatwo-paired-host", "-o", "CheckHostIP=no", "-o", "HostKeyAlgorithms=ssh-ed25519",
                "-o", "KnownHostsCommand=none", "-o", "VerifyHostKeyDNS=no", "-o", "UpdateHostKeys=no",
                "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ForwardAgent=no",
                "-o", "ClearAllForwardings=yes", "-o", "RequestTTY=no", "-o", "ConnectTimeout=3"]
            if let key = registry.fleetEnvironment["TATWO2_SSH_KEY_PATH"] { args += ["-i", key, "-o", "IdentitiesOnly=yes"] }
            if endpoint.kind != .alias { args += ["-p", String(endpoint.port)] }
            guard let local = try DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: registry.fleetEnvironment)),
                  !local.deviceID.isEmpty, local.deviceID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw DeviceFleetError.role }
            args += ["-l", peer.user, "--", destination, ownerCompatibleCommand(deviceID: local.deviceID)]
            do {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = args
                #if DEBUG
                if let executable = fixtureSSH { process.executableURL = executable }
                #endif
                let errors = Pipe(), diagnostics = SSHDiagnostics(), diagnosticsEnded = DispatchSemaphore(value: 0)
                process.standardInput = input; process.standardOutput = output; process.standardError = errors
                errors.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil; diagnosticsEnded.signal() }
                    else { diagnostics.append(data) }
                }
                defer { errors.fileHandleForReading.readabilityHandler = nil }
                try process.run()
                defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
                let deadline = DispatchSource.makeTimerSource(queue: .global())
                deadline.schedule(deadline: .now() + 12)
                deadline.setEventHandler { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
                deadline.resume(); defer { deadline.cancel() }
                try input.fileHandleForWriting.write(contentsOf: request); try input.fileHandleForWriting.close()
                var data = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > 4 * 1024 * 1024 { process.terminate(); throw DeviceFleetError.malformed }
                }
                process.waitUntilExit()
                _ = diagnosticsEnded.wait(timeout: .now() + 1)
                return try decodeResponse(status: process.terminationStatus, diagnostics: diagnostics.text, data: data)
            } catch { failures.append(error) }
        }
        throw rpcFailure(failures)
    }
}
