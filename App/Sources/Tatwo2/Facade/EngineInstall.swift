import Foundation
import CryptoKit
import Darwin

@MainActor struct EngineInstall {
    static let manualGrok = "請手動更新（官方只提供安裝腳本）"
    static let teams = ["codex": "2DC432GLL2", "claude": "Q6L2SF6YDW", "grok": "5Y6N3AJ54S"]
    let paths: EnginePaths
    var fetch: (URL) async throws -> Data = { url in
        guard !NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment) else { throw CocoaError(.fileReadNoPermission) }
        return try await Self.download(url)
    }
    nonisolated static let byteLimit = 256 * 1024 * 1024
    nonisolated static func download(_ url: URL, limit: Int = byteLimit, seconds: TimeInterval = 60, session: URLSession? = nil) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = seconds; config.timeoutIntervalForRequest = seconds
        let client = session ?? URLSession(configuration: config); defer { if session == nil { client.invalidateAndCancel() } }
        let end = ProcessInfo.processInfo.systemUptime + seconds
        let (bytes, response) = try await client.bytes(for: URLRequest(url: url, timeoutInterval: seconds))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.url?.host == "registry.npmjs.org", response.expectedContentLength <= limit else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit, ProcessInfo.processInfo.systemUptime < end else { throw CocoaError(.fileReadTooLarge) }
            data.append(byte)
        }
        return data
    }
    var signature: (URL, String) async -> Bool = { url, team in
        return (try? await DispatchGit.background {
            let s = EngineRuntimeSelection.signingIdentity(url, expectedTeam: team)
            return s.verified && s.developerID && s.teamID == team
        }) ?? false
    }
    var run: (URL, [String], URL) async -> String? = EngineAIUpdate.command
    var models: (URL) async -> EngineModelCatalog.Catalog? = { await EngineModelCatalogProbe.shared.read(.claude, executable: $0) }
    func folder(_ kind: ClaudeSidecar.Kind) -> URL { paths.enginesRoot.appendingPathComponent(kind.rawValue) }
    func previous(_ kind: ClaudeSidecar.Kind) -> URL? {
        let p = folder(kind).appendingPathComponent("previous")
        return FileManager.default.isExecutableFile(atPath: p.path) && p.resolvingSymlinksInPath() != folder(kind).appendingPathComponent("current").resolvingSymlinksInPath() ? p.resolvingSymlinksInPath() : nil
    }
    func validate(_ executable: URL, kind: ClaudeSidecar.Kind, version: String) async throws {
        guard await signature(executable, Self.teams[kind.rawValue]!) else { throw failure("官方簽章或 Team 驗證失敗") }
        guard let text = await run(executable, ["--version"], folder(kind)), EngineAIUpdate.version(text) == version, !text.contains(version + "-") else { throw failure("新版 --version 執行失敗或版本不符") }
        if kind == .claude {
            guard let catalog = await models(executable), !catalog.models.isEmpty else { throw failure("Claude SDK supportedModels() 驗證失敗") }
        }
    }
    func failure(_ text: String) -> NSError { NSError(domain: "EngineInstall", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func package(_ version: String) async throws -> [String: Any] {
        guard let url = URL(string: "https://registry.npmjs.org/@openai/codex/" + version),
              let object = try JSONSerialization.jsonObject(with: await fetch(url)) as? [String: Any],
              object["name"] as? String == "@openai/codex", object["version"] as? String == version else { throw failure("registry 套件不符") }
        return object
    }
    func tarball(_ metadata: [String: Any]) async throws -> Data {
        guard let dist = metadata["dist"] as? [String: Any], let address = dist["tarball"] as? String,
              let url = URL(string: address), url.scheme == "https", url.host == "registry.npmjs.org",
              url.user == nil, url.password == nil, let integrity = dist["integrity"] as? String else { throw failure("缺少官方 SHA-512 校驗值") }
        let data = try await fetch(url)
        guard data.count <= Self.byteLimit, integrity == "sha512-" + (try await EngineAIUpdate.background { Data(SHA512.hash(data: data)).base64EncodedString() }) else { throw failure("SHA-512 校驗失敗") }
        return data
    }
    func codex(_ version: String, stage: URL) async throws -> URL {
        let main = try await package(version)
        guard (main["optionalDependencies"] as? [String: String])?["@openai/codex-darwin-arm64"] == "npm:@openai/codex@\(version)-darwin-arm64" else { throw failure("原生套件 alias 不符") }
        let data = try await tarball(package(version + "-darwin-arm64"))
        return try await EngineAIUpdate.background {
            let archive = stage.appendingPathComponent("native.tgz"), binary = stage.appendingPathComponent("codex")
            try data.write(to: archive)
            FileManager.default.createFile(atPath: binary.path, contents: nil)
            let output = try FileHandle(forWritingTo: binary); defer { try? output.close() }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xOf", archive.path, "package/vendor/aarch64-apple-darwin/bin/codex"]
            p.standardOutput = output; p.standardError = FileHandle.nullDevice
            try p.run(); try EngineAIUpdate.wait(p, output: binary, limit: Self.byteLimit, seconds: 60)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            return binary
        }
    }
    func snapshot(_ source: URL, to target: URL) async throws -> URL {
        try await DispatchGit.background {
            let source = source.resolvingSymlinksInPath()
            guard (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            return target
        }
    }
    func publish(_ snapshot: URL, kind: ClaudeSidecar.Kind, version: String) async throws -> URL {
        let fm = FileManager.default, target = folder(kind).appendingPathComponent(version + "/" + kind.rawValue)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard target.deletingLastPathComponent().resolvingSymlinksInPath() == target.deletingLastPathComponent() else { throw failure("版本目錄不可為連結") }
        if fm.fileExists(atPath: target.path) {
            let existing = try await self.snapshot(target, to: snapshot.deletingLastPathComponent().appendingPathComponent(UUID().uuidString))
            try await validate(existing, kind: kind, version: version)
            return target
        }
        try await validate(snapshot, kind: kind, version: version)
        guard renamex_np(snapshot.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw failure("發布版本失敗") }
        return target
    }
    nonisolated static func recover(_ steps: [(String, () throws -> Void)]) -> [String] {
        var failures: [String] = []
        for (name, step) in steps { do { try step() } catch { failures.append(name + ": " + error.localizedDescription) } }
        return failures
    }
    nonisolated static func pointers(_ changes: [(String, URL?)], in root: URL, replace: @escaping (String, String) -> Int32 = { rename($0, $1) }) throws {
        let fm = FileManager.default; let prior = try changes.map { name, _ -> (String, String?) in
            let path = root.appendingPathComponent(name).path
            if let destination = try? fm.destinationOfSymbolicLink(atPath: path) { return (name, destination) }
            guard !fm.fileExists(atPath: path) else { throw CocoaError(.fileWriteFileExists) }
            return (name, nil)
        }
        func set(_ name: String, _ destination: String?) throws {
            let temp = root.appendingPathComponent(".link-" + UUID().uuidString), path = root.appendingPathComponent(name)
            defer { try? fm.removeItem(at: temp) }
            if let destination {
                try fm.createSymbolicLink(atPath: temp.path, withDestinationPath: destination)
                guard replace(temp.path, path.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            } else if (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil { try fm.removeItem(at: path) }
        }
        do { for (name, target) in changes { try set(name, target?.path) } }
        catch {
            let original = error, failures = recover(prior.map { name, target in (name, { try set(name, target) }) })
            if !failures.isEmpty { throw NSError(domain: "EngineInstall", code: 3, userInfo: [NSLocalizedDescriptionKey: original.localizedDescription + "；還原失敗：" + failures.joined(separator: "；")]) }
            throw original
        }
    }
    func install(_ kind: ClaudeSidecar.Kind, current: EngineRuntimeSelection.Choice, newest: String) async throws -> String {
        if kind == .grok { return Self.manualGrok }
        return try await EngineRuntimeSelection.withGate(kind) { try await installLocked(kind, current: current, newest: newest) }
    }
    private func installLocked(_ kind: ClaudeSidecar.Kind, current: EngineRuntimeSelection.Choice, newest: String) async throws -> String {
        guard let old = current.version, newest.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil,
              EngineRuntimeSelection.isNewer(newest, than: old) else { throw failure("版本未較新") }
        let fm = FileManager.default, root = folder(kind), stage = root.appendingPathComponent(".stage-" + UUID().uuidString)
        if (try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("current").path)) != nil, EngineRuntimeSelection.isNewer(root.appendingPathComponent("current").resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent, than: old) { throw failure("目前版本已變更，請重新檢查") }
        if kind == .claude, (try? fm.destinationOfSymbolicLink(atPath: paths.userHome.appendingPathComponent(".local/bin/claude").path)) == nil { return "請手動更新（找不到 Claude launcher）" }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.resolvingSymlinksInPath() == root else { throw failure("引擎目錄不可為連結") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keepRecovery = false; defer { if !keepRecovery { try? fm.removeItem(at: stage) } }
        let saved = try await snapshot(current.executable, to: stage.appendingPathComponent("old"))
        guard await signature(saved, Self.teams[kind.rawValue]!) else { throw failure("舊版簽章驗證失敗") }
        let launcher = paths.userHome.appendingPathComponent(".local/bin/claude"), vendor = paths.userHome.appendingPathComponent(".local/share/claude")
        let vendorBackup = stage.appendingPathComponent("vendor-old")
        var launcherTarget: String?, updatingClaude = false
        do {
            let executable: URL
            var actual = newest
            if kind == .codex { executable = try await codex(newest, stage: stage) }
            else {
                launcherTarget = try fm.destinationOfSymbolicLink(atPath: launcher.path)
                guard vendor.resolvingSymlinksInPath() == vendor,
                      launcher.resolvingSymlinksInPath().path.hasPrefix(vendor.appendingPathComponent("versions").path + "/") else { throw failure("無法完整備份，請手動更新 Claude CLI") }
                try await DispatchGit.background { try FileManager.default.copyItem(at: vendor, to: vendorBackup) }
                try Data(launcherTarget!.utf8).write(to: stage.appendingPathComponent("launcher-target.txt"))
                updatingClaude = true
                guard await run(saved, ["update"], paths.userHome) != nil else { throw failure("claude update 失敗") }
                executable = try await snapshot(launcher, to: stage.appendingPathComponent("new"))
                guard await signature(executable, Self.teams[kind.rawValue]!) else { throw failure("官方簽章或 Team 驗證失敗") }
                guard let text = await run(executable, ["--version"], root), let version = EngineAIUpdate.version(text),
                      EngineRuntimeSelection.isNewer(version, than: old), !EngineRuntimeSelection.isNewer(newest, than: version) else { throw failure("新版 --version 執行失敗或版本不符") }
                actual = version
            }
            let backup = try await publish(saved, kind: kind, version: old)
            let installed = try await publish(executable, kind: kind, version: actual)
            try Self.pointers([("previous", backup), ("current", installed), ("rollback-pin", nil)], in: root)
            return "\(old) → \(actual) 已更新"
        } catch {
            let original = error
            if updatingClaude {
                let failures = Self.recover([
                    ("封存版本目錄", {
                        let failed = stage.appendingPathComponent("vendor-failed")
                        if fm.fileExists(atPath: vendor.path), rename(vendor.path, failed.path) != 0 { throw failure("無法封存失敗安裝") }
                    }),
                    ("還原版本目錄", { guard rename(vendorBackup.path, vendor.path) == 0 else { throw failure("無法還原 Claude 版本目錄") } }),
                    ("還原 launcher", {
                        let temp = launcher.deletingLastPathComponent().appendingPathComponent(".restore-" + UUID().uuidString)
                        defer { try? fm.removeItem(at: temp) }
                        try fm.createSymbolicLink(atPath: temp.path, withDestinationPath: launcherTarget!)
                        guard rename(temp.path, launcher.path) == 0 else { throw failure("無法還原 Claude launcher") }
                    })])
                if !failures.isEmpty { keepRecovery = true; throw failure(original.localizedDescription + "；還原失敗，請手動修復；備份：\(stage.path)；" + failures.joined(separator: "；")) }
            }
            try Data(original.localizedDescription.utf8).write(to: root.appendingPathComponent("failure.txt"), options: .atomic)
            throw original
        }
    }
    func rollback(_ kind: ClaudeSidecar.Kind) async throws -> String {
        let version = try await EngineRuntimeSelection.withGate(kind) { () async throws -> String in
            guard let old = previous(kind) else { throw failure("沒有可退回的版本") }
            let version = old.deletingLastPathComponent().lastPathComponent
            let stage = folder(kind).appendingPathComponent(".rollback-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: stage) }
            let saved = try await snapshot(old, to: stage.appendingPathComponent(kind.rawValue))
            try await validate(saved, kind: kind, version: version)
            let installed = try await publish(saved, kind: kind, version: version)
            let launcher = paths.userHome.appendingPathComponent(".local/bin/claude")
            let target = kind == .claude ? try? FileManager.default.destinationOfSymbolicLink(atPath: launcher.path) : nil
            if target != nil { try Self.pointers([("claude", installed)], in: launcher.deletingLastPathComponent()) }
            do { try Self.pointers([("current", installed), ("previous", nil), ("rollback-pin", installed)], in: folder(kind)) }
            catch { if let target { let prior = URL(fileURLWithPath: target, relativeTo: launcher.deletingLastPathComponent()); try Self.pointers([("claude", prior)], in: launcher.deletingLastPathComponent()) }; throw error }
            return version
        }
        if let catalog = await EngineModelCatalogProbe.shared.read(kind) { EngineModelCatalog.replace(EngineModelCatalog.catalogs().filter { $0.engine != kind.rawValue } + [catalog]) }
        return "已退回 \(version)"
    }
}
