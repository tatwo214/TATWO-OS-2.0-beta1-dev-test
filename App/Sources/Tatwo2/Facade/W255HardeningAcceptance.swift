#if DEBUG
import Darwin
import Foundation

enum W255HardeningAcceptance {
    static func run() async throws -> Bool {
        try await Task.detached { try checks(); return true }.value
    }
    private static func checks() throws {
        let env = ProcessInfo.processInfo.environment
        guard let live = env["TATWO2_LIVE_ROOT"], let staging = env["TATWO_STAGING_ROOT"],
              DeviceIdentityStore.canonical(URL(fileURLWithPath: live)).path.hasPrefix(
                DeviceIdentityStore.canonical(URL(fileURLWithPath: staging)).path + "/") else {
            throw HandsFileError.unsafe("w255_isolation")
        }
        let fm = FileManager.default, root = URL(fileURLWithPath: live).appendingPathComponent("w255-fixture")
        var passed = 0
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else { print("W255 FAIL \(name)"); throw HandsFileError.unsafe(name) }
            passed += 1; print("W255 PASS \(name)")
        }
        func mode(_ url: URL) throws -> Int {
            (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try HandsFiles.ensureDirectory(root)
        try check("existing-directory-0700", mode(root) == 0o700)
        for file in ["settings.json", "auth.json", "build-config.json", "build-ownership.json", "state.json", "devices.json"] {
            let url = root.appendingPathComponent(file)
            try HandsFiles.writeAtomically(Data("{}".utf8), to: url)
            try check("\(file)-0600", mode(url) == 0o600)
            try check("\(file)-readable", HandsFiles.readSecure(url) == Data("{}".utf8))
        }
        let key = root.appendingPathComponent("synthetic-key")
        try Data("synthetic-private-key".utf8).write(to: key)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        try check("wide-file-still-refused", HandsFiles.readSecure(key) == nil)
        try HandsFiles.restrictOwnedFile(key)
        try check("key-0600-content-preserved", mode(key) == 0o600 && Data(contentsOf: key) == Data("synthetic-private-key".utf8))
        let alias = root.appendingPathComponent("key-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: key)
        var refused = false
        do { try HandsFiles.restrictOwnedFile(alias) } catch { refused = true }
        try check("symlink-refused", refused)
        let hardlink = root.appendingPathComponent("key-hardlink")
        try fm.linkItem(at: key, to: hardlink)
        refused = false
        do { try HandsFiles.restrictOwnedFile(key) } catch { refused = true }
        try check("hardlink-refused", refused)
        try check("caller-cannot-claim-apple-sshd", !OSSocketCaller.systemSSHSignature(pid: getpid(), path: "/usr/sbin/sshd"))
        try check("unlisted-signature-path-refused", !OSSocketCaller.systemSSHSignature(pid: getpid(), path: "/usr/bin/sleep"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["3"]
        try process.run()
        let caller = OSSocketCaller.classify(pid: process.processIdentifier, roots: [:])
        try check("unregistered-same-uid-refused", !caller.isTrusted)
        process.waitUntilExit()
        print("W255 SUMMARY failures=0 passed=\(passed)")
    }
}
#endif
