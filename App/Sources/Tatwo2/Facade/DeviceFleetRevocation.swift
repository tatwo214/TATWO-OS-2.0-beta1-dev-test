import Darwin
import Foundation

/// Scope isolates concurrent test fleets and independent installations. Tombstones precede callbacks.
enum DeviceFleetConnections {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: [String: [UUID: @Sendable () -> Void]]] = [:]
    nonisolated(unsafe) private static var revoked: [String: Set<String>] = [:]
    nonisolated(unsafe) private static var watchers: [String: [String: [UUID: @Sendable () -> Void]]] = [:]
    @discardableResult static func register(_ id: String, scope: String = "", close: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        let denied = lock.withLock { () -> Bool in
            if revoked[scope, default: []].contains(id) { return true }
            entries[scope, default: [:]][id, default: [:]][token] = close; return false
        }
        if denied { close() }
        return token
    }
    /// Fires only on revoke; close／closeAll leave it registered. Callers check isRevoked for the already-revoked case.
    @discardableResult static func onRevoke(_ id: String, scope: String, _ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.withLock { watchers[scope, default: [:]][id, default: [:]][token] = handler }
        return token
    }
    static func unregister(_ id: String, scope: String = "", token: UUID) {
        lock.withLock { entries[scope]?[id]?[token] = nil; watchers[scope]?[id]?[token] = nil }
    }
    static func revokedIDs(scope: String) -> Set<String> {
        lock.withLock { revoked[scope] ?? [] }
    }
    static func isRevoked(_ id: String, scope: String) -> Bool {
        lock.withLock { revoked[scope, default: []].contains(id) }
    }
    static func revoke(_ id: String, scope: String = "") {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            revoked[scope, default: []].insert(id)
            return Array((entries[scope]?.removeValue(forKey: id) ?? [:]).values) + Array((watchers[scope]?.removeValue(forKey: id) ?? [:]).values)
        }
        callbacks.forEach { $0() }
    }
    static func restore(_ id: String, scope: String) {
        lock.withLock { revoked[scope]?.remove(id); revoked[""]?.remove(id) }
    }
    static func close(_ id: String, scope: String) {
        let callbacks = lock.withLock { entries[scope]?.removeValue(forKey: id) ?? [:] }
        callbacks.values.forEach { $0() }
    }
    static func closeAll(scope: String) {
        let callbacks = lock.withLock { entries.removeValue(forKey: scope) ?? [:] }
        callbacks.values.flatMap { $0.values }.forEach { $0() }
    }
    static func revokeAll(scope: String = "") {
        let ids = lock.withLock { Set((entries[scope] ?? [:]).keys).union((watchers[scope] ?? [:]).keys) }
        ids.forEach { revoke($0, scope: scope) }
    }
}

/// No sshd configuration changes. Exact authenticated-key matches take precedence over endpoint fallback.
enum DeviceFleetRevocation {
    struct Child: Equatable { var pid: pid_t; var start: UInt64 }
    struct Session: Equatable {
        var pid: pid_t
        var start: UInt64
        var fingerprint: String?
        var address: String?
        var tatwoRelated: Bool
        var children: [Child] = []
    }
    struct Hooks {
        var sessions: () -> [Session]
        var terminate: (Session) -> Bool
    }
    #if DEBUG
    // In-process fixture seam only; not an environment flag or an RPC option.
    nonisolated(unsafe) static var testHooks: Hooks?
    #endif
    static func cutOff(_ member: DeviceFleetMember, registry: DeviceRegistry, revokeIdentity: Bool = true) {
        cutOff(id: member.id, fingerprint: member.clientKeyFingerprint,
               endpoints: member.endpoints, registry: registry, revokeIdentity: revokeIdentity)
    }
    static func cutOff(_ member: DeviceRecord, registry: DeviceRegistry, revokeIdentity: Bool = true) {
        cutOff(id: member.id, fingerprint: member.pinnedClientKeyFingerprint,
               endpoints: member.endpoints, registry: registry, revokeIdentity: revokeIdentity)
    }
    private static func cutOff(id: String, fingerprint: String?, endpoints: [DeviceEndpoint], registry: DeviceRegistry, revokeIdentity: Bool) {
        DeviceFleetGate.terminateRegistered(id, registry: registry)
        HandsService.shared.onMain { HandsService.shared.sandboxLane.remove(id) }
        if revokeIdentity {
            DeviceFleetConnections.revoke(id, scope: registry.root.path)
            // Compatibility callbacks registered by W187a.
            DeviceFleetConnections.revoke(id)
        }
        let fleet = DeviceFleetStore(registry: registry, environment: registry.fleetEnvironment)
        guard (try? fleet.claimRevocationSweep(id, revokeIdentity: revokeIdentity)) == true else { return }
        let otherAddresses = Set(registry.list().filter { $0.id != id }.flatMap(\.endpoints).map(\.host))
        let addresses = Set(endpoints.map(\.host).filter { isNumericAddress($0) }).subtracting(otherAddresses)
        func sweep(_ hooks: Hooks) {
            let fleet = DeviceFleetStore(registry: registry, environment: registry.fleetEnvironment)
            var failed = false
            var readableKey = false
            var unidentified = false
            let sessions = hooks.sessions()
            for session in sessions {
                readableKey = readableKey || session.fingerprint != nil
                let byKey = session.fingerprint != nil && session.fingerprint == fingerprint
                let fallback = session.fingerprint == nil && session.tatwoRelated
                    && session.address.map(addresses.contains) == true
                guard byKey || fallback else {
                    if session.fingerprint == nil {
                        let targetAddresses = Set(endpoints.map(\.host))
                        let knownOther = session.address.map { otherAddresses.contains($0) && !targetAddresses.contains($0) } == true
                        unidentified = unidentified || !knownOther
                    }
                    continue
                }
                let closed = hooks.terminate(session)
                failed = failed || !closed
                fleet.audit(closed ? (byKey ? "fleet_ssh_session_key_terminated" : "fleet_ssh_session_endpoint_best_effort")
                                   : "fleet_ssh_session_termination_denied")
            }
            if !readableKey { fleet.audit("fleet_ssh_authinfo_unavailable_best_effort") }
            if failed || unidentified {
                DeviceFleetStore.lock.withLock {
                    if var state = try? fleet.read() {
                        state.possiblyConnected = Array(Set((state.possiblyConnected ?? []) + [id]))
                        var devices = state.possiblyConnectedDevices ?? [:]
                        devices[id] = (try? fleet.current()?.revision) ?? 0
                        state.possiblyConnectedDevices = devices; try? fleet.save(state)
                    }
                }
            } else {
                DeviceFleetStore.lock.withLock {
                    if var state = try? fleet.read() {
                        state.possiblyConnected?.removeAll { $0 == id }
                        state.possiblyConnectedDevices?[id] = nil; try? fleet.save(state)
                    }
                }
            }
        }
        #if DEBUG
        if let hooks = testHooks { sweep(hooks); return }
        #endif
        // Complete the sweep within this synchronization round.
        sweep(.init(sessions: systemSessions, terminate: terminate))
    }

    /// Called only after the user explicitly selects the broader disconnect option.
    static func disconnectAllRemoteSessions(userSelected: Bool) -> Bool {
        guard userSelected else { return false }
        #if DEBUG
        if let hooks = testHooks { return hooks.sessions().map(hooks.terminate).allSatisfy { $0 } }
        #endif
        return systemSessions().map(terminate).allSatisfy { $0 }
    }

    static func isSystemSSHDescendant(_ pid: pid_t) -> Bool {
        var current = pid
        guard processUIDs(pid)?.effective == geteuid() else { return false }
        for _ in 0..<8 {
            if executablePath(current).map(sshExecutables.contains) == true,
               let parent = parentPID(of: current),
               executablePath(parent).map(sshExecutables.contains) == true,
               processUIDs(parent).map({ $0.real == 0 && $0.effective == 0 }) == true { return true }
            guard let parent = parentPID(of: current), parent > 1, parent != current,
                  processUIDs(parent)?.effective == geteuid() else { return false }
            current = parent
        }
        return false
    }
    static func isNumericAddress(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    /// Read only selected public connection metadata. Never log argv/environment or authentication file paths.
    static func processArguments(_ pid: pid_t) -> (args: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1024 * 1024 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var pos = 4
        func field() -> String {
            let start = pos
            while pos < size, data[pos] != 0 { pos += 1 }
            let result = String(decoding: data[start..<min(pos, size)], as: UTF8.self); pos += 1
            return result
        }
        _ = field(); while pos < size, data[pos] == 0 { pos += 1 }
        var args: [String] = [], env: [String: String] = [:]
        for _ in 0..<argc where pos < size { args.append(field()) }
        while pos < size {
            let value = field()
            for key in ["SSH_CONNECTION", "SSH_CLIENT", "SSH_USER_AUTH"] where value.hasPrefix(key + "=") {
                env[key] = String(value.dropFirst(key.count + 1))
            }
        }
        return (args, env)
    }
    private static let sshExecutables: Set<String> = ["/usr/libexec/sshd-session", "/usr/sbin/sshd"]
    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }
    private static func parentPID(of pid: pid_t) -> pid_t? { processInfo(pid)?.kp_eproc.e_ppid }
    private static func processUIDs(_ pid: pid_t) -> (real: uid_t, effective: uid_t)? {
        guard let info = processInfo(pid) else { return nil }
        return (info.kp_eproc.e_pcred.p_ruid, info.kp_eproc.e_ucred.cr_uid)
    }
    private static func processStartTime(_ pid: pid_t) -> UInt64? {
        guard let start = processInfo(pid)?.kp_proc.p_un.__p_starttime, start.tv_sec > 0 else { return nil }
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }
    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
    private static func sshAuthenticatedFingerprint(pid: pid_t) -> String? {
        guard let path = processArguments(pid)?.env["SSH_USER_AUTH"], path.hasPrefix("/"), path.utf8.count <= 4096 else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 8192,
              info.st_uid == geteuid() || info.st_uid == 0, info.st_mode & 0o022 == 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        let keys = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[0] == "publickey" else { return nil }
            return try? DeviceRegistry.fingerprint(publicKey: "\(fields[1]) \(fields[2])")
        }
        return keys.count == 1 ? keys.first : nil
    }
    /// Only a verified system-sshd session's direct, same-user exec children may
    /// supply ExposeAuthInfo. No request parameter can select a PID or auth file.
    static func childAuthenticatedFingerprint(sshPID: pid_t, children: [pid_t]? = nil) -> String? {
        guard processUIDs(sshPID)?.effective == geteuid(),
              executablePath(sshPID).map(sshExecutables.contains) == true,
              let parent = parentPID(of: sshPID), parent > 1,
              executablePath(parent).map(sshExecutables.contains) == true,
              processUIDs(parent).map({ $0.real == 0 && $0.effective == 0 }) == true else { return nil }
        let candidates: [pid_t]
        if let children { candidates = children }
        else {
            var pids = [pid_t](repeating: 0, count: 65536)
            let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            guard count > 0 else { return nil }
            candidates = Array(pids.prefix(min(Int(count), pids.count)))
        }
        let keys = Set(candidates.filter {
            parentPID(of: $0) == sshPID && processUIDs($0)?.effective == geteuid()
        }.compactMap { sshAuthenticatedFingerprint(pid: $0) })
        return keys.count == 1 ? keys.first : nil
    }
    private static func readOnlyCommand(_ executable: String, _ args: [String]) throws -> (Int32, Data) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + 2)
        deadline.setEventHandler { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        deadline.resume(); defer { deadline.cancel() }
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, output)
    }
    static func systemSessions() -> [Session] {
        var pids = [pid_t](repeating: 0, count: 65536)
        let bytes = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        // proc_listallpids returns a PID count, not a byte count.
        let all = Array(pids.prefix(min(Int(bytes), pids.count))).filter { $0 > 1 }
        let parents = Dictionary(uniqueKeysWithValues: all.compactMap { pid -> (pid_t, pid_t)? in
            guard let parent = parentPID(of: pid) else { return nil }; return (pid, parent)
        })
        func descends(_ child: pid_t, from root: pid_t) -> Bool {
            var current = child
            for _ in 0..<64 {
                guard let parent = parents[current], parent > 1, parent != current else { return false }
                if parent == root { return true }; current = parent
            }
            return false
        }
        var result: [Session] = []
        for pid in all {
            guard processUIDs(pid)?.effective == geteuid(),
                  let path = executablePath(pid), sshExecutables.contains(path),
                  let parent = parentPID(of: pid), parent > 1,
                  let parentPath = executablePath(parent), sshExecutables.contains(parentPath),
                  processUIDs(parent).map({ $0.real == 0 && $0.effective == 0 }) == true,
                  let start = processStartTime(pid) else { continue }
            var address = processArguments(pid)?.env["SSH_CONNECTION"]?.split(separator: " ").first.map(String.init)
            var related = false
            let descendants = all.filter { descends($0, from: pid) }
            // ExposeAuthInfo may be exported only to the session's direct exec child,
            // rather than to the forwarding daemon's original environment.
            let authenticatedKey = sshAuthenticatedFingerprint(pid: pid)
                ?? childAuthenticatedFingerprint(sshPID: pid, children: descendants)
            for child in descendants {
                let metadata = processArguments(child)
                if address == nil { address = metadata?.env["SSH_CONNECTION"]?.split(separator: " ").first.map(String.init) }
                let args = metadata?.args ?? []
                if executablePath(child)?.hasSuffix("/Tatwo2") == true || args.contains(where: {
                    $0.contains("/tatwo2/live/os.sock") || $0.contains("/tatwo2/live/browser.sock")
                }) { related = true }
            }
            // A forwarding-only session has no shell environment. Observe open socket peers read-only.
            if address == nil, let output = try? readOnlyCommand("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-Fn"]).1 {
                for line in String(decoding: output, as: UTF8.self).split(separator: "\n") where line.hasPrefix("n") && line.contains("->") {
                    let destination = line.components(separatedBy: "->").last!.components(separatedBy: " ").first!
                    let host = destination.hasPrefix("[") ? String(destination.dropFirst().prefix(while: { $0 != "]" }))
                        : destination.components(separatedBy: ":").dropLast().joined(separator: ":")
                    if isNumericAddress(host) { address = host; break }
                }
                if let sockets = try? readOnlyCommand("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-U", "-Fn"]).1 {
                    related = related || String(decoding: sockets, as: UTF8.self).contains("/tatwo2/live/os.sock")
                }
            }
            result.append(.init(pid: pid, start: start, fingerprint: authenticatedKey,
                                address: address, tatwoRelated: related, children: descendants.compactMap { child in
                                    guard processUIDs(child)?.effective == geteuid(), let start = processStartTime(child) else { return nil }
                                    return Child(pid: child, start: start)
                                }))
        }
        return result
    }
    static func terminate(_ session: Session) -> Bool {
        // Never signal a reused PID, listener, another user's process or arbitrary argv-matched process.
        guard processStartTime(session.pid) == session.start,
              processUIDs(session.pid)?.effective == geteuid(),
              executablePath(session.pid).map(sshExecutables.contains) == true else { return false }
        for child in session.children where processStartTime(child.pid) == child.start && processUIDs(child.pid)?.effective == geteuid() {
            _ = kill(child.pid, SIGTERM)
        }
        guard kill(session.pid, SIGTERM) == 0 else { return false }
        for _ in 0..<10 {
            if processStartTime(session.pid) != session.start { break }
            usleep(50_000)
        }
        let ended = processStartTime(session.pid) != session.start || kill(session.pid, SIGKILL) == 0
        for child in session.children where processStartTime(child.pid) == child.start && processUIDs(child.pid)?.effective == geteuid() {
            _ = kill(child.pid, SIGKILL)
        }
        return ended
    }
}
