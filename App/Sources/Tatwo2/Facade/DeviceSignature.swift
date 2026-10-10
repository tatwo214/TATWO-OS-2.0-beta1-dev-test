import Darwin
import Foundation

/// 設備既有 SSH 身分的簽章實作；不同用途必須用不同 namespace，沒有另一套金鑰。
enum DeviceSignature {
    static func run(_ arguments: [String], input: Data) throws -> (Int32, Data) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.environment?["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment?["SSH_ASKPASS"] = "/usr/bin/false"
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // 沿用 DeviceDispatch.run 的有界、非互動行為；大的名單不會卡在 stdin pipe。
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("device-sign-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = scratch.appendingPathComponent("input")
        try input.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: scratch) }
        process.standardInput = handle
        try process.run()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + 10)
        deadline.setEventHandler { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        deadline.resume()
        defer { deadline.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    static func sign(_ body: Data, namespace: String, environment: [String: String]) throws -> (Data, String) {
        let key = environment["TATWO2_SSH_KEY_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
        let publicKey = try String(contentsOfFile: key + ".pub", encoding: .utf8)
        var result: (Int32, Data) = (1, Data())
        if environment["SSH_AUTH_SOCK"]?.isEmpty == false {
            result = try run(["-Y", "sign", "-f", key + ".pub", "-n", namespace], input: body)
        }
        if result.0 != 0 {
            try HandsFiles.ensureDirectory(URL(fileURLWithPath: key).deletingLastPathComponent())
            try HandsFiles.restrictOwnedFile(URL(fileURLWithPath: key))
            result = try run(["-Y", "sign", "-f", key, "-P", "", "-n", namespace], input: body)
        }
        guard result.0 == 0, !result.1.isEmpty else {
            throw NSError(domain: "device_signing_unavailable", code: 1)
        }
        return (result.1, publicKey)
    }

    static func verify(body: Data, signature: Data, publicKey: String, namespace: String) -> Bool {
        let fields = publicKey.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, !publicKey.contains("\r"), publicKey.split(separator: "\n").count <= 1,
              fields[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "@" || $0 == ".") }),
              fields[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }) else { return false }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("device-sign-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let allowed = scratch.appendingPathComponent("allowed"), file = scratch.appendingPathComponent("signature")
        guard (try? Data("primary \(fields[0]) \(fields[1])\n".utf8).write(to: allowed)) != nil,
              (try? signature.write(to: file)) != nil,
              let result = try? run(["-Y", "verify", "-f", allowed.path, "-I", "primary",
                                    "-n", namespace, "-s", file.path], input: body) else { return false }
        return result.0 == 0
    }
}
