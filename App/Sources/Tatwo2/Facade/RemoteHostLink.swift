import Darwin
import Foundation

enum RemoteHostLinkError: Error, LocalizedError {
    case sshHomeLookupFailed(String)
    case tunnelStartFailed(String)
    case tunnelUnavailable
    case socketPathTooLong
    case connectFailed(Int32)
    case invalidResponse
    case responseTimedOut
    case remoteError(String)

    var errorDescription: String? {
        switch self {
        case .sshHomeLookupFailed(let detail): "ssh_home_lookup_failed: \(detail)"
        case .tunnelStartFailed(let detail): "ssh_tunnel_start_failed: \(detail)"
        case .tunnelUnavailable: "ssh_tunnel_unavailable"
        case .socketPathTooLong: "unix_socket_path_too_long"
        case .connectFailed(let code): "unix_socket_connect_failed: errno=\(code)"
        case .invalidResponse: "invalid_json_rpc_response"
        case .responseTimedOut: "rpc_response_timed_out"
        case .remoteError(let detail): "remote_error: \(detail)"
        }
    }
}

/// R2 的 App-to-App SSH socket 轉發。這層只管連線、重連與 JSON-RPC，不碰 SSH 設定。
final class RemoteHostLink: @unchecked Sendable {
    private static let ownershipLock = NSLock()
    nonisolated(unsafe) private static var owned: [Int32: (Process, String)] = [:]
    nonisolated(unsafe) private static var ending = false
    static func terminateOwned() {
        ownershipLock.withLock {
            ending = true
            for (_, (process, socket)) in owned { stop(process, socket: socket) }
            owned = [:]
        }
    }
    private static func stop(_ process: Process?, socket: String) {
        process?.terminationHandler = nil
        if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        _ = unlink(socket)
    }
    /// Same-user, launchd-owned legacy forwards only; recheck the complete row before signalling.
    static func reapOrphans(list: (Int32?) -> String? = { processRows(pid: $0) }, socketDirectory: String = "/tmp") {
        guard let rows = list(nil) else { return }
        let pattern = #"^([0-9]+)\s+1\s+/usr/bin/ssh (?=(?:.* )?-N(?: |$))(?:.* )?-L (/tmp/t2-r-[0-9a-f]{8}-[0-9a-f]{3}\.sock):/.*live/os\.sock .*"#
        let pin = #" -o UserKnownHostsFile="?/[^"\n]*\/w91-host-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"?(?: |$)"#
        for row in rows.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard row.range(of: pin, options: .regularExpression) != nil,
                  let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: row, range: NSRange(row.startIndex..., in: row)),
                  let pidRange = Range(match.range(at: 1), in: row), let pid = Int32(row[pidRange]), pid > 1,
                  let socketRange = Range(match.range(at: 2), in: row),
                  list(pid)?.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == row }) == true else { continue }
            if kill(pid, SIGKILL) == 0 { _ = unlink(String(row[socketRange])) }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: socketDirectory)) ?? [] {
            let path = socketDirectory + "/" + name; var info = stat()
            if name.range(of: #"^t2-r-[0-9a-f]{8}-[0-9a-f]{3}\.sock$"#, options: .regularExpression) != nil,
               !rows.contains(path), lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { _ = unlink(path) }
        }
    }
    private static func processRows(pid: Int32?) -> String? {
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww"] + (pid.map { ["-p", String($0)] } ?? ["-U", String(getuid())]) + ["-o", "pid=,ppid=,command="]; process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
    private let environment: [String: String]
    private let lock = NSLock()
    // Revocation must not wait for a network RPC holding the transport lock.
    private let revocationLock = NSLock()
    private var revoked = false
    private var revocationToken: UUID?
    private var revocationID: String?
    private var revocationProcesses: [Process] = []
    private var activeFD: Int32?
    private let revocationCleanup: Bool
    #if DEBUG
    nonisolated(unsafe) static var fixtureSSH: URL?
    private var fixtureLaunches = 0
    /// Test-only executable replacing SSH; all pin/permission checks and git push still run.
    var fixturePushSSH: URL?
    #endif
    private let reconnectQueue = DispatchQueue(label: "ai.tatwo.tatwo2.remote-reconnect", qos: .utility)
    private var device: DeviceRecord?
    private var tunnel: Process?
    private var remoteSocketPath: String?
    private var reconnectDelay: TimeInterval = 1
    private var reconnectScheduled = false
    private var wantsConnection = false
    private var statusProbeOnly = false
    private var pinnedHostsFile: URL?
    private var pinnedHostAlgorithm: String?
    /// 這次 pin 中的主機金鑰指紋，隧道成功後用來補記來源。
    private var pinnedHostFingerprint: String?
    private var activeEndpoint: DeviceEndpoint?
    private var endpointDeadline: Date?

    let localSocketPath: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment, revocationCleanup: Bool = false) {
        self.environment = environment
        self.revocationCleanup = revocationCleanup
        self.localSocketPath = "/tmp/t2-r-\(UUID().uuidString.lowercased().prefix(12)).sock"
    }

    deinit {
        if let id = revocationID, let token = revocationToken {
            DeviceFleetConnections.unregister(id, scope: DeviceRegistry(environment: environment).root.path, token: token)
        }
        disconnect()
        if let pinnedHostsFile { try? FileManager.default.removeItem(at: pinnedHostsFile) }
    }

    /// A dedicated RPC link authenticated against the pairing record's SSH HOST key.
    /// Do not use this with a record representing an inbound client key. No TOFU here.
    func callPinned(device: DeviceRecord, method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard tunnel == nil, !wantsConnection else { throw RemoteHostLinkError.invalidResponse }
        statusProbeOnly = true
        wantsConnection = true
        self.device = device
        defer {
            wantsConnection = false
            stopTunnelLocked()
        }
        try establishLocked(device)
        return try callLocked(method: method, params: params)
    }

    /// Reuse the exact host-key pin established by callPinned; push only a captured
    /// commit into an inbox ref, never the primary's checked-out branch.
    func pushPinned(device: DeviceRecord, repository: String, localRepository: URL,
                    commit: String, ref: String) throws {
        lock.lock(); defer { lock.unlock() }
        try bindRevocation(device)
        try requireNotRevoked(device)
        guard try !requiresFleetGate(device) else { throw DeviceFleetError.role }
        _ = try DeviceFleetSSHPins.lines(for: device, registry: DeviceRegistry(environment: environment))
        // A fresh link can push after callPrimary used a separate RPC link. Establish
        // its own exact paired host pin before any git/SSH process is launched.
        try prepareHostPin(device)
        self.device = device
        guard pinnedHostsFile != nil, self.device?.id == device.id,
              !device.user.hasPrefix("-"), !device.host.hasPrefix("-"),
              device.user.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              device.host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              repository.hasPrefix("/"), !repository.contains("\n"), !repository.contains("\0"),
              [40, 64].contains(commit.count), commit.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              ref.hasPrefix("refs/heads/inbox/") else { throw RemoteHostLinkError.invalidResponse }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var sshProgram = "/usr/bin/ssh"
        #if DEBUG
        sshProgram = fixturePushSSH?.path ?? sshProgram
        #endif
        let endpoints = device.orderedEndpoints
        let ordered = activeEndpoint.map { active in [active] + endpoints.filter { $0 != active } } ?? endpoints
        guard !ordered.isEmpty else { throw RemoteHostLinkError.remoteError("no_active_endpoints") }
        for endpoint in ordered {
            try requireNotRevoked(device)
            activeEndpoint = endpoint
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = localRepository
            var env = sshEnvironment.filter { !$0.key.hasPrefix("GIT_") }
            env["GIT_SSH_COMMAND"] = ([sshProgram, "-v"] + (try sshBaseArguments(device))).map(quote).joined(separator: " ")
            env["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = env
            process.arguments = ["-c", "core.hooksPath=/dev/null", "push", "--",
                "\(sshDestination(device)):\(repository)", "\(commit):\(ref)"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let diagnosticsURL = pinnedHostsFile!.deletingLastPathComponent().appendingPathComponent("push-diagnostics-" + UUID().uuidString)
            try DeviceDispatchSafeFile.write(Data(), url: diagnosticsURL)
            let diagnostics = try FileHandle(forWritingTo: diagnosticsURL)
            defer { try? diagnostics.close(); try? FileManager.default.removeItem(at: diagnosticsURL) }
            process.standardError = diagnostics
            try launchUnlessRevoked(process)
            let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            deadline.schedule(deadline: .now() + 90)
            deadline.setEventHandler { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
            deadline.resume()
            process.waitUntilExit(); deadline.cancel()
            try requireNotRevoked(device)
            if process.terminationStatus == 0 { return }
            let text = String(decoding: (try? Data(contentsOf: diagnosticsURL)) ?? Data(), as: UTF8.self)
            // Before authentication no Git data could reach the peer. This includes
            // a different host at a stale LAN address or an unready tunnel backend.
            // An authenticated failure stays on this endpoint to avoid an ambiguous resend.
            guard !text.contains("Authenticated to ") else {
                throw RemoteHostLinkError.remoteError("branch_push_failed")
            }
        }
        activeEndpoint = nil
        throw DeviceFleetGate.CallError.unreachable
    }

    /// A wake-up has no content or authority. Receiver must fetch independently
    /// from its own pinned primary; a spoofed notification cannot apply anything.
    func notifyDispatch(device: DeviceRecord) throws {
        lock.lock(); defer { lock.unlock() }
        statusProbeOnly = true; wantsConnection = true; self.device = device
        defer {
            wantsConnection = false; stopTunnelLocked()
        }
        try establishLocked(device)
        _ = try callLocked(method: "dispatch_wake", params: [:])
    }

    /// Use a dedicated short-lived link. Never connect(), call(), or schedule get_document.
    func queryDeviceStatus(device: DeviceRecord, primaryCommit: String? = nil) -> DeviceStatusProbe {
        guard DeviceFleetStore(registry: DeviceRegistry(environment: environment), environment: environment).allowsPeerConnection(device.id) else {
            return .init(connection: .sshUnavailable, snapshot: nil, acquiredAt: Date(), reason: "fleet_staff_local")
        }
        lock.lock()
        defer {
            wantsConnection = false
            stopTunnelLocked()
            lock.unlock()
        }
        statusProbeOnly = true
        var sshReachable = false
        do {
            self.device = device
            wantsConnection = true
            try establishLocked(device) { sshReachable = true }
            // Cancel the legacy reconnect handler before issuing any request.
            tunnel?.terminationHandler = nil
            let params: [String: Any] = primaryCommit.map { ["primary_commit": $0] } ?? [:]
            let result = try callLocked(method: "device_status", params: params)
            return .init(connection: .reachable, snapshot: try DeviceStatusSnapshot.decode(result),
                         acquiredAt: Date(), reason: nil)
        } catch {
            if let failure = error as? DeviceFleetGate.CallError, failure != .unreachable { sshReachable = true }
            var clockMismatch = (error as? DeviceFleetGate.CallError) == .clockMismatch
            if case .remoteError("rpc_proof_expired") = error as? RemoteHostLinkError { clockMismatch = true }
            if clockMismatch { sshReachable = true }
            return .init(connection: sshReachable ? .appUnavailable : .sshUnavailable,
                         snapshot: nil, acquiredAt: Date(),
                         reason: clockMismatch ? "rpc_proof_expired" : sshReachable ? "app_rpc_unavailable" : "ssh_unavailable")
        }
    }

    func connect(device: DeviceRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        wantsConnection = true
        self.device = device
        try establishLocked(device)
        _ = try callLocked(method: "get_document", params: [:])
        reconnectDelay = 1
    }

    func disconnect() {
        lock.lock()
        wantsConnection = false
        reconnectScheduled = false
        stopTunnelLocked()
        lock.unlock()
    }

    func call(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        // W100 設計約束（DEBUG／RELEASE 都留）：這條路會等 SSH，主執行緒一律不准走。
        // 畫面要的資料請走 RemoteLiveEngine 的快取＋背景刷新。
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock()
        defer { lock.unlock() }
        do {
            return try callLocked(method: method, params: params)
        } catch {
            scheduleReconnectLocked()
            throw error
        }
    }

    /// Only transport establishment retries. Never replay a mutating RPC on another endpoint.
    private func establishLocked(_ device: DeviceRecord, sshReady: () -> Void = {}) throws {
        try bindRevocation(device)
        try requireNotRevoked(device)
        // W100：建隧道會起 ssh 子行程並等它，主執行緒一律不准走。
        dispatchPrecondition(condition: .notOnQueue(.main))
        // No route (including LAN) may turn a paired record back into TOFU.
        try prepareHostPin(device)
        if try requiresFleetGate(device) { return }
        // Sessions may predate an endpoint edit. Reload routes, never silently replace
        // the caller's paired identity/key with a differently paired registry record.
        let current = DeviceStatusReader.registry(environment: environment).first { $0.id == device.id }
        if let current, current.publicKeyFingerprint != device.publicKeyFingerprint || current.user != device.user {
            throw RemoteHostLinkError.remoteError("pairing_identity_changed")
        }
        let routes = current ?? device
        var lastError: Error = RemoteHostLinkError.remoteError("no_active_endpoints")
        for endpoint in routes.orderedEndpoints {
            stopTunnelLocked()
            activeEndpoint = endpoint
            endpointDeadline = Date().addingTimeInterval(8)
            defer { endpointDeadline = nil }
            do {
                let home = try sshHome(device)
                sshReady()
                remoteSocketPath = environment["TATWO2_REMOTE_OS_SOCKET"]
                    ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/tatwo2/live/os.sock").path
                try startTunnelLocked(device: device)
                let registry = DeviceRegistry(environment: environment)
                _ = try? registry.touch(id: device.id, endpoint: endpoint)
                // 隧道走通了，把這次實際比中的 known_hosts 指紋補記成 host 那一把（含來源與時間）。
                // recordFingerprint 只補空的或補來源，值不同會拒絕，不會覆蓋已 pin 的指紋。
                if let pinned = pinnedHostFingerprint {
                    _ = try? registry.recordFingerprint(
                        id: device.id, role: .host, fingerprint: pinned, source: "known_hosts")
                }
                return
            } catch {
                lastError = error
                stopTunnelLocked()
            }
        }
        throw lastError
    }

    func requiresFleetGate(_ peer: DeviceRecord) throws -> Bool {
        let registry = DeviceRegistry(environment: environment)
        let fleet = DeviceFleetStore(registry: registry, environment: environment)
        guard let trust = try fleet.trust() else { return false }
        guard let roster = try fleet.readGraph()?.roster else { return true }
        return try !roster.usesUnrestrictedKey(from: trust.localID, to: peer.id, forRevocation: revocationCleanup)
    }
    private func callFleetGate(_ peer: DeviceRecord, method: String, params: [String: Any]) throws -> [String: Any] {
        let registry = DeviceRegistry(environment: environment)
        _ = try DeviceFleetSSHPins.lines(for: peer, registry: registry)
        let fleet = DeviceFleetStore(registry: registry, environment: environment)
        if let trust = try fleet.trust(), let roster = try fleet.readGraph()?.roster {
            let capabilities = try roster.capabilities(from: trust.localID, to: peer.id)
            guard (DeviceFleetCapabilities.isFleetTransport(method) && roster.hasMAINTransport(from: trust.localID, to: peer.id))
                || DeviceFleetCapabilities.allows(method: method, capabilities: capabilities) else { throw DeviceFleetError.role }
        } else if DeviceFleetCapabilities.required(for: method) == nil { throw DeviceFleetError.role }
        #if DEBUG
        if let fixtureGate { return try fixtureGate(peer, method, params) }
        #endif
        let wireParams = try signedHandlerParams(method: method, params: params, recipient: peer.id)
        let handshake = OSAgentBridge.signedDeviceMethods.contains(method) ? nil : try DeviceDispatch(entry: TatwoEntry(environment: environment), registry: registry, environment: environment).signedHandshake(method: method, params: params, recipient: peer.id)
        let result = try DeviceFleetGate.call(peer: peer, method: method, params: wireParams, registry: registry, handshake: handshake)
        _ = try? registry.touch(id: peer.id)
        return result
    }
    #if DEBUG
    var fixtureGate: ((DeviceRecord, String, [String: Any]) throws -> [String: Any])?
    func fixturePrepareHostPin(_ peer: DeviceRecord) throws { try prepareHostPin(peer) }
    func fixtureFrame(method: String, params: [String: Any], recipient: String) throws -> [String: Any] {
        try requestFrame(method: method, params: params, recipient: recipient)
    }
    #endif
    private func stopTunnelLocked() {
        Self.ownershipLock.withLock { if let tunnel { Self.owned[tunnel.processIdentifier] = nil }; Self.stop(tunnel, socket: localSocketPath) }
        tunnel = nil
    }

    private func prepareHostPin(_ device: DeviceRecord) throws {
        // 隧道只認對方的主機金鑰。分流過的紀錄若沒有 host 指紋（例如自己是產生配對碼端，
        // 手上只有對方的客戶端金鑰）就直接擋掉，不會退回用另一把或 TOFU。
        pinnedHostFingerprint = nil
        guard let pinned = device.pinnedHostKeyFingerprint, pinned.hasPrefix("SHA256:") else {
            throw RemoteHostLinkError.remoteError("paired_host_key_not_found")
        }
        if let pinnedHostsFile { try? FileManager.default.removeItem(at: pinnedHostsFile) }
        pinnedHostsFile = nil; pinnedHostAlgorithm = nil
        let registry = DeviceRegistry(environment: environment)
        // Every general channel reads both caller-side pin sources before selecting the paired key.
        let lines = try DeviceFleetSSHPins.lines(for: device, registry: registry)
        var match: (String, String)?
        for line in lines where !line.hasPrefix("#") && !line.hasPrefix("@") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }
            let key = "\(parts[1]) \(parts[2])"
            if (try? DeviceRegistry.fingerprint(publicKey: key)) == pinned {
                match = (key, String(parts[1])); break
            }
        }
        guard let match else { throw RemoteHostLinkError.remoteError("paired_host_key_not_found") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("w91-host-" + UUID().uuidString)
        try Data(("tatwo-paired-host " + match.0 + "\n").utf8).write(to: file, options: .atomic)
        _ = chmod(file.path, 0o600)
        pinnedHostsFile = file
        pinnedHostAlgorithm = match.1 == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256" : match.1
        pinnedHostFingerprint = pinned
    }

    /// GUI launches do not inherit a terminal's Homebrew PATH. Keep the caller's
    /// precedence, but let an existing ProxyCommand find its installed helper.
    private var sshEnvironment: [String: String] {
        var result = environment
        var paths = (result["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for path in ["/opt/homebrew/bin", "/usr/local/bin"] where !paths.contains(path) { paths.append(path) }
        result["PATH"] = paths.joined(separator: ":")
        return result
    }

    private func sshDestination(_ device: DeviceRecord) -> String {
        if activeEndpoint?.kind == .alias { return activeEndpoint?.alias ?? "" }
        return "\(device.user)@\(activeEndpoint?.host ?? device.host)"
    }

    private func sshHome(_ device: DeviceRecord) throws -> String {
        // W100：這裡最久可以等 8 秒（endpointDeadline），主執行緒一律不准走。
        dispatchPrecondition(condition: .notOnQueue(.main))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try sshBaseArguments(device) + [sshDestination(device), "echo $HOME"]
        #if DEBUG
        if let executable = Self.fixtureSSH { process.executableURL = executable }
        #endif
        process.environment = sshEnvironment
        // A file avoids pipe backpressure from a noisy ProxyCommand. Never read private keys.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("w91-ssh-" + UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        do {
            try launchUnlessRevoked(process)
            let deadline = endpointDeadline ?? Date().addingTimeInterval(8)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning {
                process.terminate()
                _ = kill(process.processIdentifier, SIGKILL)
                throw RemoteHostLinkError.sshHomeLookupFailed("endpoint_timeout")
            }
            process.waitUntilExit()
        } catch {
            throw RemoteHostLinkError.sshHomeLookupFailed(error.localizedDescription)
        }
        let text = String(decoding: (try? Data(contentsOf: output)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            throw RemoteHostLinkError.sshHomeLookupFailed(
                "exit=\(process.terminationStatus) \(String(text.prefix(240)))")
        }
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
    }

    private func startTunnelLocked(device: DeviceRecord) throws {
        if let tunnel, tunnel.isRunning, FileManager.default.fileExists(atPath: localSocketPath) {
            return
        }
        stopTunnelLocked()
        guard let remoteSocketPath else { throw RemoteHostLinkError.tunnelUnavailable }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try sshBaseArguments(device) + [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localSocketPath):\(remoteSocketPath)",
            sshDestination(device),
        ]
        #if DEBUG
        if let executable = Self.fixtureSSH { process.executableURL = executable }
        #endif
        process.environment = sshEnvironment
        process.standardOutput = FileHandle.nullDevice
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("w91-forward-" + UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output); process.standardError = handle
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        do {
            try launchUnlessRevoked(process)
        } catch {
            throw RemoteHostLinkError.tunnelStartFailed(error.localizedDescription)
        }
        tunnel = process

        let deadline = endpointDeadline ?? Date().addingTimeInterval(8)
        while Date() < deadline {
            if !process.isRunning {
                throw RemoteHostLinkError.tunnelStartFailed(String(decoding: (try? Data(contentsOf: output)) ?? Data(), as: UTF8.self).prefix(240).description)
            }
            if FileManager.default.fileExists(atPath: localSocketPath) {
                if !statusProbeOnly {
                    process.terminationHandler = { [weak self] ended in
                        guard let self else { return }
                        self.lock.lock(); defer { self.lock.unlock() }
                        guard self.tunnel === ended else { return }
                        self.stopTunnelLocked()
                        self.scheduleReconnectLocked()
                    }
                }
                return
            }
            usleep(50_000)
        }
        stopTunnelLocked()
        throw RemoteHostLinkError.tunnelUnavailable
    }

    private func sshBaseArguments(_ device: DeviceRecord) throws -> [String] {
        guard let pinnedHostsFile, let pinnedHostAlgorithm else {
            throw RemoteHostLinkError.remoteError("paired_host_key_not_found")
        }
        let port = activeEndpoint?.kind == .alias ? [] : ["-p", String(activeEndpoint?.port ?? device.sshPort)]
        // -o is parsed using ssh_config syntax even though Process uses argv.
        // Quote the value as well, since the approved staging volume has spaces.
        let knownHosts = pinnedHostsFile.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var arguments = [
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"\(knownHosts)\"", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlgorithms=\(pinnedHostAlgorithm)", "-o", "UpdateHostKeys=no",
            "-o", "KnownHostsCommand=none", "-o", "VerifyHostKeyDNS=no",
            "-o", "HostKeyAlias=tatwo-paired-host", "-o", "CheckHostIP=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
        ] + port
        if let key = environment["TATWO2_SSH_KEY_PATH"] { arguments += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        return arguments
    }

    private func signedHandlerParams(method: String, params: [String: Any], recipient: String) throws -> [String: Any] {
        guard OSAgentBridge.signedDeviceMethods.contains(method), params["body"] == nil, params["revocation"] == nil else { return params }
        let registry = DeviceRegistry(environment: environment)
        return try DeviceDispatch(entry: TatwoEntry(environment: environment), registry: registry, environment: environment)
            .signed(method: method, payload: params, recipient: recipient)
    }
    private func requestFrame(method: String, params: [String: Any], recipient: String) throws -> [String: Any] {
        var request: [String: Any] = ["id": UUID().uuidString.lowercased(), "method": method,
            "params": try signedHandlerParams(method: method, params: params, recipient: recipient)]
        if !OSAgentBridge.signedDeviceMethods.contains(method) {
            let registry = DeviceRegistry(environment: environment)
            request["deviceHandshake"] = try DeviceDispatch(entry: TatwoEntry(environment: environment), registry: registry, environment: environment)
                .signedHandshake(method: method, params: params, recipient: recipient)
        }
        return request
    }
    private func callLocked(method: String, params: [String: Any]) throws -> [String: Any] {
        guard wantsConnection, let device else { throw RemoteHostLinkError.tunnelUnavailable }
        try requireNotRevoked(device)
        if try requiresFleetGate(device) { return try callFleetGate(device, method: method, params: params) }
        if tunnel?.isRunning != true { try establishLocked(device) }
        let request = try requestFrame(method: method, params: params, recipient: device.id)
        guard JSONSerialization.isValidJSONObject(request) else {
            throw RemoteHostLinkError.invalidResponse
        }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        let responseData = try transact(data)
        guard
            let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let ok = response["ok"] as? Bool
        else {
            throw RemoteHostLinkError.invalidResponse
        }
        guard ok else {
            throw RemoteHostLinkError.remoteError(response["error"] as? String ?? "unknown")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw RemoteHostLinkError.invalidResponse
        }
        reconnectDelay = 1
        return result
    }

    private func transact(_ data: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteHostLinkError.connectFailed(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try revocationLock.withLock {
            guard !revoked else { throw RemoteHostLinkError.remoteError("fleet_revoked") }
            activeFD = fd
        }
        defer { revocationLock.withLock { activeFD = nil }; try? handle.close() }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = localSocketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strlcpy(destination, source, capacity)
            }
        }
        guard copied < capacity else { throw RemoteHostLinkError.socketPathTooLong }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw RemoteHostLinkError.connectFailed(errno) }
        // 對端慢或睡著時不能無限等（03:41／03:52 兩次主執行緒卡死就是這裡）：收發各 10 秒
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try handle.write(contentsOf: data)
        _ = Darwin.shutdown(fd, SHUT_WR)
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65536) }
            if n > 0 {
                out.append(contentsOf: chunk[0..<n])
                guard out.count <= 16 * 1024 * 1024 else { throw RemoteHostLinkError.invalidResponse }
                if out.last == 0x0A { break }; continue
            }
            if n == 0 { break }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw RemoteHostLinkError.responseTimedOut }   // 逾時
            if errno == EINTR { continue }
            throw RemoteHostLinkError.connectFailed(errno)
        }
        return out
    }

    private func bindRevocation(_ device: DeviceRecord) throws {
        guard !revocationCleanup else { return } // Only DeviceDispatch's one-shot, signed cleanup delivery.
        if let id = revocationID, id != device.id { throw RemoteHostLinkError.invalidResponse }
        guard revocationToken == nil else { return }
        revocationID = device.id
        let scope = DeviceRegistry(environment: environment).root.path
        revocationToken = DeviceFleetConnections.register(device.id, scope: scope) { [weak self] in
            self?.cutOffImmediately()
        }
    }
    private func requireNotRevoked(_ device: DeviceRecord) throws {
        guard !revocationLock.withLock({ revoked }) else { throw RemoteHostLinkError.remoteError("fleet_revoked") }
        if revocationCleanup { return }
        let registry = DeviceRegistry(environment: environment)
        let fleet = DeviceFleetStore(registry: registry, environment: environment)
        let payload = try fleet.current()
        if DeviceFleetConnections.isRevoked(device.id, scope: registry.root.path) ||
            payload?.roster?.revoked.contains(device.id) == true || payload?.slice?.revoked == true {
            cutOffImmediately(); throw RemoteHostLinkError.remoteError("fleet_revoked")
        }
    }
    private func launchUnlessRevoked(_ process: Process) throws {
        try revocationLock.withLock {
            guard !revoked else { throw RemoteHostLinkError.remoteError("fleet_revoked") }
            revocationProcesses.removeAll { !$0.isRunning }
            try Self.ownershipLock.withLock {
                guard !Self.ending else { throw RemoteHostLinkError.tunnelUnavailable }
                Self.owned = Self.owned.filter { $0.value.0.isRunning }
                try process.run()
                if process.arguments?.contains("-N") == true { Self.owned[process.processIdentifier] = (process, localSocketPath) }
            }
            revocationProcesses.append(process)
            #if DEBUG
            fixtureLaunches += 1
            #endif
        }
    }
    private func cutOffImmediately() {
        revocationLock.withLock {
            revoked = true
            if let fd = activeFD { _ = Darwin.shutdown(fd, SHUT_RDWR) }
            for process in revocationProcesses where process.isRunning {
                process.terminationHandler = nil
                process.terminate()
                _ = kill(process.processIdentifier, SIGKILL)
            }
            revocationProcesses = []
        }
        _ = unlink(localSocketPath)
        // A reconnect already queued will see revoked before starting a new process.
    }
    #if DEBUG
    /// Fake owned child only; no SSH daemon or real endpoint is launched by the fixture.
    func attachFixture(device: DeviceRecord, process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        self.device = device; wantsConnection = true
        try bindRevocation(device); try requireNotRevoked(device)
        try launchUnlessRevoked(process); tunnel = process
    }
    var fixtureRevoked: Bool { revocationLock.withLock { revoked } }
    var fixtureLaunchCount: Int { revocationLock.withLock { fixtureLaunches } }
    var fixtureReconnectPending: Bool { lock.withLock { reconnectScheduled } }
    func queueFixtureReconnect() { lock.withLock { scheduleReconnectLocked() } }
    #endif

    private func scheduleReconnectLocked() {
        guard !statusProbeOnly else { return }
        guard !revocationLock.withLock({ revoked }) else { return }
        guard wantsConnection, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        reconnectQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.reconnectScheduled = false
            guard self.wantsConnection, !self.revocationLock.withLock({ self.revoked }), let device = self.device else {
                self.lock.unlock()
                return
            }
            do {
                try self.establishLocked(device)
                _ = try self.callLocked(method: "get_document", params: [:])
                self.reconnectDelay = 1
            } catch {
                self.scheduleReconnectLocked()
            }
            self.lock.unlock()
        }
    }
}
