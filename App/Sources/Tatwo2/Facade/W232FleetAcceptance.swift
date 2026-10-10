#if DEBUG
import Darwin
import Foundation

enum W232FleetAcceptance {
    final class Remote: @unchecked Sendable {
        let fd: Int32
        let dispatch: DeviceDispatch
        let path: String
        init(_ dispatch: DeviceDispatch, path: String) throws {
            self.dispatch = dispatch
            self.path = path
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw DeviceFleetError.malformed }
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            path.withCString { source in withUnsafeMutablePointer(to: &address.sun_path.0) { _ = strlcpy($0, source, capacity) } }
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, listen(fd, 8) == 0 else { throw DeviceFleetError.malformed }
            DispatchQueue.global().async { [self] in
                while true {
                    let client = Darwin.accept(fd, nil, nil)
                    guard client >= 0 else { break }
                    let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
                    do {
                        var data = Data()
                        while data.last != 10 { let byte = handle.readData(ofLength: 1); guard !byte.isEmpty else { throw DeviceFleetError.malformed }; data.append(byte) }
                        let frame = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                        let wire = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: dispatch, method: frame["method"] as! String,
                            params: frame["params"] as! [String: Any], handshake: frame["deviceHandshake"] as? [String: Any])
                        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: wire) + Data([10]))
                    } catch { print("W232 REMOTE ERROR \(error)") }
                    try? handle.close()
                }
            }
        }
        func stop() { shutdown(fd, SHUT_RDWR); close(fd); _ = unlink(path) }
    }
    static func run(make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake) throws {
        let mini = try make(80, true), studio = try make(81, false), other = try make(82, false)
        let fm = FileManager.default, root = mini.registry.root.deletingLastPathComponent().deletingLastPathComponent()
        var count = 0
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W232_FAIL_" + name) }; count += 1; print("W232 PASS " + name)
        }
        var identity = try DeviceIdentityStore.forLocalDevice(entry: studio.dispatch.entry).read()
        identity.epoch = 1; identity.primaryDeviceID = mini.id
        try DeviceIdentityStore.forLocalDevice(entry: studio.dispatch.entry).write(identity)
        for (local, peer) in [(mini, studio), (studio, mini)] {
            let host = try DeviceRegistry.fingerprint(publicKey: peer.hostKey)
            _ = try local.registry.add(id: peer.id, name: "fixture paired", host: peer.host, user: "fixture", publicKeyFingerprint: host,
                hostKeyFingerprint: host, clientKeyFingerprint: DeviceRegistry.fingerprint(publicKey: peer.clientKey))
            try DeviceDispatchSafeFile.write(Data(("\(peer.host) \(try DeviceFleetPublicKey.withoutComment(peer.hostKey))\n").utf8), url: local.registry.knownHostsURL)
        }
        _ = try studio.registry.authorize(publicKey: mini.clientKey, deviceID: mini.id)
        _ = try mini.registry.authorize(publicKey: studio.clientKey, deviceID: studio.id)
        try mini.fleet.bootstrapPrimary(host: mini.host)
        let aliasBase = URL(fileURLWithPath: "/tmp/w232-" + String(UUID().uuidString.prefix(8)))
        // Short aliases only for Unix socket limits; every fixture byte stays below the assigned TMPDIR.
        try fm.createSymbolicLink(at: aliasBase, withDestinationURL: root)
        defer { try? fm.removeItem(at: aliasBase) }
        var homes: [String: [String: String]] = [:]
        for device in [mini, studio] {
            let base = device.registry.root.deletingLastPathComponent(), home = aliasBase.appendingPathComponent(base.lastPathComponent)
            let support = base.appendingPathComponent("Library/Application Support/tatwo2")
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: support.appendingPathComponent("live"), withDestinationURL: device.registry.root)
            try fm.createSymbolicLink(at: support.appendingPathComponent("bin"), withDestinationURL: base.appendingPathComponent("bin"))
            homes[device.host] = ["home": home.path, "hostKey": try DeviceFleetPublicKey.withoutComment(device.hostKey)]
        }
        let log = root.appendingPathComponent("ssh-transports.jsonl"), ssh = root.appendingPathComponent("ssh")
        let destinations = String(decoding: try JSONSerialization.data(withJSONObject: homes), as: UTF8.self)
        let script = #"""
        #!/usr/bin/python3
        import json, os, select, socket, subprocess, sys
        peers = json.loads(r'''__PEERS__''')
        args = sys.argv[1:]
        destination = next((key for key in peers if any(value.rsplit('@',1)[-1] == key for value in args)), None)
        assert destination is not None
        peer = peers[destination]
        pin = next(value.split('=',1)[1].strip('"') for value in args if value.startswith('UserKnownHostsFile='))
        assert peer['hostKey'] in open(pin).read()
        assert 'StrictHostKeyChecking=yes' in args and 'ControlPath=none' in args
        channel = 'legacy' if '-N' in args or args[-1] == 'echo $HOME' else 'gate'
        with open(json.loads(r'''__LOG__'''), 'a') as output: output.write(json.dumps({'peer': destination, 'channel': channel, 'command': args[-1]})+'\n')
        remote = os.environ.copy(); remote['HOME'] = peer['home']
        if '-N' not in args:
            sys.exit(subprocess.run(['/bin/sh', '-c', args[-1]], env=remote).returncode)
        local, path = args[args.index('-L')+1].split(':',1)
        listener = socket.socket(socket.AF_UNIX); listener.bind(local); listener.listen(2)
        while True:
            client,_ = listener.accept(); server = socket.socket(socket.AF_UNIX); server.connect(path)
            sockets = [client,server]
            while sockets:
                ready,_,_ = select.select(sockets,[],[],15)
                if not ready: break
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        sockets.remove(source)
                        (server if source is client else client).shutdown(socket.SHUT_WR)
                        continue
                    (server if source is client else client).sendall(data)
            client.close(); server.close()
        """#
        try script.replacingOccurrences(of: "__PEERS__", with: destinations).replacingOccurrences(of: "__LOG__", with: String(decoding: try JSONEncoder().encode(log.path), as: UTF8.self)).write(to: ssh, atomically: true, encoding: .utf8)
        chmod(ssh.path, 0o700)
        RemoteHostLink.fixtureSSH = ssh
        DeviceFleetGate.fixtureSSH = ssh
        defer { RemoteHostLink.fixtureSSH = nil; DeviceFleetGate.fixtureSSH = nil }
        func real(_ device: DeviceFleetAcceptance.Fake, peer: DeviceFleetAcceptance.Fake) -> DeviceDispatch {
            var environment = device.env
            environment["TATWO2_REMOTE_OS_SOCKET"] = homes[peer.host]!["home"]! + "/Library/Application Support/tatwo2/live/os.sock"
            return DeviceDispatch(entry: device.dispatch.entry, registry: device.registry, environment: environment, retireBackup: { _ in })
        }
        let sender = real(mini, peer: studio), receiver = real(studio, peer: mini)
        let remotes = try [Remote(sender, path: homes[mini.host]!["home"]! + "/Library/Application Support/tatwo2/live/os.sock"), Remote(receiver, path: homes[studio.host]!["home"]! + "/Library/Application Support/tatwo2/live/os.sock")]
        defer { remotes.forEach { $0.stop() } }
        func calls() throws -> [[String: Any]] {
            guard fm.fileExists(atPath: log.path) else { return [] }
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        try check("initial-peer-legacy-without-policy", mini.fleet.current()!.roster!.devices.first { $0.id == studio.id }!.legacy && !fm.fileExists(atPath: studio.registry.root.appendingPathComponent("fleet-gate-policy.json").path))
        let known = try Data(contentsOf: mini.registry.knownHostsURL)
        try DeviceDispatchSafeFile.write(Data(("\(studio.host) \(try DeviceFleetPublicKey.withoutComment(other.hostKey))\n").utf8), url: mini.registry.knownHostsURL)
        sender.pushFleetNow()
        try check("bootstrap-host-conflict-refused-before-ssh", studio.fleet.trust() == nil && calls().isEmpty)
        try DeviceDispatchSafeFile.write(known, url: mini.registry.knownHostsURL)
        sender.pushFleetNow()
        try check("first-roster-old-channel-and-policy", studio.fleet.trust() != nil && fm.fileExists(atPath: studio.registry.root.appendingPathComponent("fleet-gate-policy.json").path) && calls().allSatisfy { $0["channel"] as? String == "legacy" })
        let beforeACK = try calls().count
        receiver.synchronize()
        let ackCalls = try calls().dropFirst(beforeACK)
        try check("legacy-ack-over-old-channel", mini.fleet.read().deliveryProblems?[studio.id] == nil
            && mini.fleet.current()!.roster!.devices.first { $0.id == studio.id }!.legacy == false
            && !ackCalls.isEmpty && ackCalls.allSatisfy { $0["peer"] as? String == mini.host && $0["channel"] as? String == "legacy" })
        sender.synchronize(); receiver.synchronize()
        try check("signed-ack-completes-membership", mini.fleet.current()!.roster!.devices.first { $0.id == studio.id }!.legacy == false && studio.fleet.current()!.roster!.devices.first { $0.id == studio.id }!.legacy == false)
        let before = try calls().count
        _ = try receiver.callPrimary(method: "dispatch_fetch", payload: [:])
        try check("enrolled-call-uses-real-gate", calls().dropFirst(before).contains { $0["channel"] as? String == "gate" })
        let countBeforeConflict = try calls().count
        let studioKnown = try Data(contentsOf: studio.registry.knownHostsURL)
        try DeviceDispatchSafeFile.write(Data(("\(mini.host) \(try DeviceFleetPublicKey.withoutComment(other.hostKey))\n").utf8), url: studio.registry.knownHostsURL)
        do { _ = try receiver.callPrimary(method: "dispatch_fetch", payload: [:]); throw DeviceFleetError.malformed }
        catch { try check("gate-host-conflict-refused-before-ssh", error as? DeviceFleetError == .keyConflict && calls().count == countBeforeConflict) }
        try DeviceDispatchSafeFile.write(studioKnown, url: studio.registry.knownHostsURL)
        print("W232 FLEET SUMMARY checks=\(count) failures=0")
    }
}
#endif
