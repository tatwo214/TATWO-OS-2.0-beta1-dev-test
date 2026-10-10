import Foundation
import Darwin
import Security

enum EngineRuntimeSelection {
    static let gates = Dictionary(uniqueKeysWithValues: ["codex", "claude", "grok"].map { ($0, DispatchSemaphore(value: 1)) })
    @TaskLocal static var heldGates: Set<String> = []
    static let busy = NSError(domain: "EngineInstall", code: 2, userInfo: [NSLocalizedDescriptionKey: "另一個更新正在進行"])
    private static func wait(_ gate: DispatchSemaphore, cancellation: Cancellation?) -> Bool {
        let end = Date().addingTimeInterval(3)
        while cancellation?.isCancelled != true && Date() < end {
            if gate.wait(timeout: .now() + 0.05) == .success { return true }
        }
        return false
    }
    static func acquire(_ gate: DispatchSemaphore) async throws {
        let cancellation = Cancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Thread {
                    let acquired = wait(gate, cancellation: cancellation)
                    if cancellation.isCancelled { if acquired { gate.signal() }; continuation.resume(throwing: CancellationError()) }
                    else if acquired { continuation.resume() }
                    else { continuation.resume(throwing: busy) }
                }.start()
            }
        } onCancel: { cancellation.cancel() }
    }
    @MainActor static func withGate<T>(_ kind: ClaudeSidecar.Kind, _ body: () async throws -> T) async throws -> T {
        guard !heldGates.contains(kind.rawValue) else { throw busy }
        let gate = gates[kind.rawValue]!
        try await acquire(gate); defer { gate.signal() }
        try Task.checkCancellation()
        return try await $heldGates.withValue(heldGates.union([kind.rawValue])) { try await body() }
    }
    struct Candidate: Equatable, Sendable {
        var path: URL
        var version: String?
        var verified: Bool
        var developerID: Bool
        var teamID: String?
    }
    struct Choice: Equatable, Sendable {
        var executable: URL
        var version: String?
        var source: String
        var reason: String?
        var identity: String { executable.path + "|" + (version ?? "unknown") }
        var summary: String { "\(source) · \(version ?? "版本未取得")\n\(executable.path)" + (reason.map { "\n" + $0 } ?? "") }
    }
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Choice] = [:]
        var current: [String: Choice] = [:]
    }
    private static let cache = Cache()
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }
    static func isNewer(_ local: String, than bundled: String) -> Bool {
        func parts(_ value: String) -> [Int]? {
            guard value.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil else { return nil }
            let numbers = value.split(separator: ".").compactMap { Int($0) }
            return numbers.count == 3 ? numbers : nil
        }
        guard let lhs = parts(local), let rhs = parts(bundled) else { return false }
        return rhs.lexicographicallyPrecedes(lhs)
    }
    static func choose(bundled: Candidate, local: Candidate?, pinned: Bool = false) -> Choice {
        var result = Choice(executable: bundled.path, version: bundled.version, source: "App 內附", reason: nil)
        guard let local else { return result }
        if let reason = trustFailure(bundled: bundled, local: local) {
            result.reason = reason; return result
        }
        guard let version = local.version, EngineAIUpdate.version(version) == version, let baseline = bundled.version,
              (pinned || isNewer(version, than: baseline)) else {
            result.reason = "本機 CLI 版本未較新，或無法確認版本；仍使用 App 內附引擎。"; return result
        }
        return Choice(executable: local.path, version: version, source: "本機", reason: nil)
    }
    static func shouldRollback(bundled: Candidate, local: Candidate) -> Bool {
        bundled.verified && bundled.developerID && bundled.teamID?.isEmpty == false
            && (!local.verified || !local.developerID || local.teamID != bundled.teamID)
    }
    private static func trustFailure(bundled: Candidate, local: Candidate) -> String? {
        guard bundled.verified, bundled.developerID, bundled.teamID?.isEmpty == false else {
            return "內附引擎沒有可驗證的 Developer ID，未採用本機 CLI。"
        }
        guard local.verified else { return "本機 CLI 簽章驗證失敗，仍使用 App 內附引擎。" }
        guard local.developerID, local.teamID == bundled.teamID else {
            return "本機 CLI 的 Developer ID Team ID 與內附引擎不同，未採用。"
        }
        return nil
    }
    private static func baseline(kind: ClaudeSidecar.Kind, bundled: URL) -> URL {
        let native = bundled.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("codex-vendor/aarch64-apple-darwin/bin/codex")
        return (kind == .codex && FileManager.default.isExecutableFile(atPath: native.path) ? native : bundled).resolvingSymlinksInPath()
    }
    private static func scope(_ baseline: URL, _ userHome: URL, _ engineHome: URL, _ environment: [String: String]) -> String {
        [baseline.path, userHome.path, engineHome.path, environment["PATH"] ?? "", String(NativeStagingIsolation.isEnabled(environment))].joined(separator: "|")
    }
    static func cached(kind: ClaudeSidecar.Kind, bundled: URL, userHome: URL, engineHome: URL,
                       environment: [String: String]) -> Choice {
        let base = baseline(kind: kind, bundled: bundled)
        cache.lock.lock(); defer { cache.lock.unlock() }
        return cache.current[scope(base, userHome, engineHome, environment)]
            ?? Choice(executable: base, version: nil, source: "App 內附", reason: nil)
    }
    static func resolveAsync(kind: ClaudeSidecar.Kind, bundled: URL, userHome: URL, engineHome: URL,
                             environment: [String: String], forceVerification: Bool = false) async throws -> Choice {
        guard !heldGates.contains(kind.rawValue) else { throw busy }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let choice = await withCheckedContinuation { continuation in
                // 版本子程序的同步等待只占自己的 Thread，不占 Swift 或 GCD 的共用池。
                let worker = Thread {
                    continuation.resume(returning: resolve(kind: kind, bundled: bundled, userHome: userHome,
                        engineHome: engineHome, environment: environment, forceVerification: forceVerification,
                        cancellation: cancellation))
                }
                worker.name = "ai.tatwo.engine-runtime-probe"
                worker.qualityOfService = .utility
                worker.start()
            }
            try Task.checkCancellation()
            return choice
        } onCancel: { cancellation.cancel() }
    }
    static func resolve(kind: ClaudeSidecar.Kind, bundled: URL, userHome: URL, engineHome: URL,
                        environment: [String: String], forceVerification: Bool = false) -> Choice {
        resolve(kind: kind, bundled: bundled, userHome: userHome, engineHome: engineHome, environment: environment,
                forceVerification: forceVerification, cancellation: nil)
    }
    private static func resolve(kind: ClaudeSidecar.Kind, bundled: URL, userHome: URL, engineHome: URL,
                                environment: [String: String], forceVerification: Bool, cancellation: Cancellation?) -> Choice {
        // Main-thread readers keep the last completed choice; they never wait for a process.
        guard !Thread.isMainThread else {
            return cached(kind: kind, bundled: bundled, userHome: userHome, engineHome: engineHome, environment: environment)
        }
        let gate = gates[kind.rawValue]!
        guard !heldGates.contains(kind.rawValue), wait(gate, cancellation: cancellation) else {
            var choice = cached(kind: kind, bundled: bundled, userHome: userHome, engineHome: engineHome, environment: environment)
            choice.reason = busy.localizedDescription; return choice
        }
        defer { gate.signal() }
        let fm = FileManager.default, baseline = baseline(kind: kind, bundled: bundled)
        let scopeKey = scope(baseline, userHome, engineHome, environment)
        var paths = [engineHome.appendingPathComponent("current"), userHome.appendingPathComponent(".local/bin/\(kind.rawValue)")]
        if kind == .grok { paths.append(userHome.appendingPathComponent(".grok/bin/grok")) }
        paths += (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(kind.rawValue) }
        var seen = Set<String>()
        let candidates = NativeStagingIsolation.isEnabled(environment) ? [] : paths.map { $0.resolvingSymlinksInPath() }.filter {
            $0 != baseline && seen.insert($0.path).inserted && fm.isExecutableFile(atPath: $0.path)
        }
        let cacheKey = ([baseline] + candidates).map { url in
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return url.path + ":" + String(describing: (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970) + ":" + String(describing: attrs?[.size])
        }.joined(separator: "|") + "|" + scopeKey + "|" + ((try? fm.destinationOfSymbolicLink(atPath: engineHome.appendingPathComponent("rollback-pin").path)) ?? "")
        if !forceVerification {
            cache.lock.lock()
            let prior = cache.values[cacheKey]
            if let prior, !Task.isCancelled && cancellation?.isCancelled != true { cache.current[scopeKey] = prior }
            cache.lock.unlock()
            if let prior { return prior }
        }
        // An allowlist prevents API keys, provider tokens and loader overrides from entering probes.
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": engineHome.path,
                   "CODEX_HOME": engineHome.path, "CLAUDE_CONFIG_DIR": engineHome.path,
                   "CLAUDE_SECURESTORAGE_CONFIG_DIR": engineHome.path,
                   "TATWO2_GROK_HOME": engineHome.path, "LANG": "C", "LC_ALL": "C", "DISABLE_AUTOUPDATER": "1"]
        let base = inspect(baseline, environment: env, bundled: nil, cancellation: cancellation)
        var selected = choose(bundled: base, local: nil)
        for path in candidates {
            guard !Task.isCancelled && cancellation?.isCancelled != true else { return cached(kind: kind, bundled: bundled, userHome: userHome, engineHome: engineHome, environment: environment) }
            let candidate = inspect(path, environment: env, bundled: base, cancellation: cancellation)
            let choice = choose(bundled: base, local: candidate)
            if path == engineHome.appendingPathComponent("current").resolvingSymlinksInPath() {
                let pinned = (try? fm.destinationOfSymbolicLink(atPath: engineHome.appendingPathComponent("rollback-pin").path)) == path.path
                let managed = choose(bundled: base, local: candidate, pinned: pinned)
                if managed.source == "本機" { selected = managed; break }
                if !shouldRollback(bundled: base, local: candidate) {
                    if candidate.version == nil || base.version == nil { return cached(kind: kind, bundled: bundled, userHome: userHome, engineHome: engineHome, environment: environment) }
                    continue
                }
                let prior = engineHome.appendingPathComponent("previous").resolvingSymlinksInPath()
                let fallback = inspect(prior, environment: env, bundled: base, cancellation: cancellation)
                let restored = choose(bundled: base, local: fallback)
                if restored.source == "本機", (try? EngineInstall.pointers([("current", prior), ("previous", nil), ("rollback-pin", nil)], in: engineHome)) != nil { selected = restored; selected.reason = "新版驗證失敗，已退回"; break }
            }
            if choice.source == "本機", selected.source != "本機" || isNewer(choice.version ?? "", than: selected.version ?? "") { selected = choice }
            else if selected.source != "本機", selected.reason == nil { selected.reason = choice.reason }
        }
        guard !Task.isCancelled && cancellation?.isCancelled != true else { return cached(kind: kind, bundled: bundled, userHome: userHome, engineHome: engineHome, environment: environment) }
        cache.lock.lock(); cache.values[cacheKey] = selected; cache.current[scopeKey] = selected; cache.lock.unlock()
        return selected
    }
    /// Security.framework checks the signed code and certificate requirement directly. Displayed codesign text is never evidence.
    static func signingIdentity(_ path: URL, expectedTeam: String?) -> (verified: Bool, developerID: Bool, teamID: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code else { return (false, false, nil) }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let verified = SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        var information: CFDictionary?
        guard verified, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as NSDictionary?)?[kSecCodeInfoTeamIdentifier] as? String,
              team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { return (verified, false, nil) }
        let expected = expectedTeam ?? team
        guard expected == team else { return (verified, false, team) }
        let requirementText = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(expected)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return (verified, false, team)
        }
        return (verified, SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess, team)
    }
    private static func inspect(_ path: URL, environment: [String: String], bundled: Candidate?, cancellation: Cancellation?) -> Candidate {
        let deadline = Date().addingTimeInterval(3)
        let signature = signingIdentity(path, expectedTeam: bundled?.teamID)
        var candidate = Candidate(path: path, version: nil, verified: signature.verified,
                                  developerID: signature.developerID, teamID: signature.teamID)
        guard bundled.map({ trustFailure(bundled: $0, local: candidate) == nil }) ?? true else { return candidate }
        let versionText = output(path, ["--version"], environment: environment, deadline: deadline, cancellation: cancellation).flatMap { $0.code == 0 ? $0.text : nil }
        candidate.version = versionText.flatMap { EngineAIUpdate.version($0) }
        return candidate
    }
    private static func output(_ executable: URL, _ arguments: [String], environment: [String: String], deadline: Date, cancellation: Cancellation?) -> (code: Int32, text: String)? {
        guard !Task.isCancelled && cancellation?.isCancelled != true, Date() < deadline, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let process = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        while done.wait(timeout: .now() + 0.05) != .success {
            if Task.isCancelled || cancellation?.isCancelled == true || Date() >= deadline {
                process.terminate()
                if done.wait(timeout: .now() + 0.2) != .success { kill(process.processIdentifier, SIGKILL) }
                return nil
            }
        }
        guard !Task.isCancelled && cancellation?.isCancelled != true else { return nil }
        return (process.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
