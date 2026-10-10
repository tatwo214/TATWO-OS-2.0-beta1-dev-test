import Darwin
import Foundation

// An SSH exec channel, not a general command runner. The receiving App authenticates
// our kernel executable/argv, hash, UID/sshd ancestry and current key authorization.
// --policy is pinned in authorized_keys and checked verbatim by that receiver.
enum GateError: Error { case denied }

func readPolicy(_ path: String) throws -> [String: Any] {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw GateError.denied }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
          info.st_size > 0, info.st_size <= 1024 * 1024 else { throw GateError.denied }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    guard let data = try handle.readToEnd(), data.count <= 1024 * 1024,
          let policy = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GateError.denied }
    return policy
}

struct Lines {
    let fd: Int32
    let limit: Int
    var pending = Data()
    mutating func next(deadline: UInt64? = nil) throws -> Data? {
        while true {
            if let end = pending.firstIndex(of: 10) {
                let count = pending.distance(from: pending.startIndex, to: end) + 1
                guard count <= limit else { throw GateError.denied }
                let line = Data(pending.prefix(count)); pending.removeFirst(count)
                return line
            }
            guard pending.count < limit else { throw GateError.denied }
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw GateError.denied }
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&item, 1, Int32(min((deadline - now) / 1_000_000 + 1, 10_000)))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw GateError.denied }
            }
            var buffer = [UInt8](repeating: 0, count: min(8192, limit - pending.count))
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw GateError.denied }
            if count == 0 {
                guard pending.isEmpty else { throw GateError.denied }
                return nil
            }
            pending.append(contentsOf: buffer.prefix(count))
        }
    }
}

func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GateError.denied }
            sent += count
        }
    }
}

func relay(_ line: Data, socketPath: String) throws -> Data {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = Array(socketPath.utf8) + [UInt8(0)]
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw GateError.denied }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw GateError.denied }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
          setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw GateError.denied }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw GateError.denied }
    try writeAll(line, fd: fd)
    var replies = Lines(fd: fd, limit: 4 * 1024 * 1024)
    guard let reply = try replies.next(deadline: DispatchTime.now().uptimeNanoseconds + 10_000_000_000) else { throw GateError.denied }
    return reply
}

func ownerCompatibleCommand(deviceID: String) -> String {
    "env SSH_ORIGINAL_COMMAND=tatwo-fleet-rpc \"$HOME/Library/Application Support/tatwo2/bin/fleet-gate\" --device \(deviceID) --policy \"$HOME/Library/Application Support/tatwo2/live/fleet-gate-policy.json\""
}

/// Validate only command grammar. A forced row's anonymous ID remains the identity used by policy;
/// the App additionally verifies the device proof and its key, never this caller-supplied token.
func isOwnerCompatibleCommand(_ command: String) -> Bool {
    guard command.utf8.count <= 1024 else { return false }
    let parts = command.components(separatedBy: " --device ")
    guard parts.count == 2, let token = parts[1].components(separatedBy: " --policy ").first,
          !token.isEmpty, token.utf8.count <= 128,
          token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return false }
    return command == ownerCompatibleCommand(deviceID: token)
}

func run() throws {
    let args = CommandLine.arguments
    guard args.count == 5, args[1] == "--device", args[3] == "--policy",
          (ProcessInfo.processInfo.environment["SSH_ORIGINAL_COMMAND"] == "tatwo-fleet-rpc"
            || isOwnerCompatibleCommand(ProcessInfo.processInfo.environment["SSH_ORIGINAL_COMMAND"] ?? "")),
          !args[2].isEmpty, args[2].utf8.count <= 128,
          args[2].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
          args[4].hasPrefix("/") else { throw GateError.denied }
    let device = args[2], policyPath = args[4]
    let root = URL(fileURLWithPath: policyPath).deletingLastPathComponent()
    // The policy cannot redirect us to an executable, network endpoint or another socket.
    let socketPath = root.appendingPathComponent("os.sock").path
    let initial = try readPolicy(policyPath)
    guard (initial["controllers"] as? [String: [String: Any]])?[device] != nil else { throw GateError.denied }
    let folder = root.appendingPathComponent("gate-sessions")
    if mkdir(folder.path, 0o700) != 0 && errno != EEXIST { throw GateError.denied }
    var info = stat()
    guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw GateError.denied }
    let record = folder.appendingPathComponent(String(getpid()) + ".json")
    let fd = open(record.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw GateError.denied }
    defer { close(fd); _ = unlink(record.path) }
    try writeAll(JSONSerialization.data(withJSONObject: ["device": device, "pid": getpid()]), fd: fd)
    var input = Lines(fd: STDIN_FILENO, limit: 1024 * 1024)
    while let line = try input.next() {
        guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw GateError.denied }
        // Reopen on every request, including requests on already established SSH channels.
        let policy = try readPolicy(policyPath)
        let controller = (policy["controllers"] as? [String: [String: Any]])?[device]
        let method = request["method"] as? String ?? ""
        var required = (policy["methods"] as? [String: String])?[method]
        if method.hasPrefix("memory_") { required = "memory" }
        if method.hasPrefix("computer_") || method.hasPrefix("ipad_") { required = "screen" }
        if method.hasPrefix("cli_") || method.hasPrefix("command_") { required = "dispatch" }
        let fleetTransport = ["dispatch_fetch", "dispatch_ack"].contains(method)
        guard controller != nil, let required, let capabilities = controller?["capabilities"] as? [String],
              (fleetTransport || capabilities.contains(required)) else {
            let reply: [String: Any] = ["id": request["id"] ?? NSNull(), "ok": false, "error": "fleet_gate_denied"]
            try writeAll(JSONSerialization.data(withJSONObject: reply) + Data([10]), fd: STDOUT_FILENO)
            continue
        }
        try writeAll(relay(line, socketPath: socketPath), fd: STDOUT_FILENO)
    }
}

signal(SIGPIPE, SIG_IGN)
do { try run() } catch { exit(126) }
