import Darwin
import Foundation

/// The App supplies an inherited Seatbelt boundary for native reads and child tools.
/// External services need their own boundary: block Unix relays and LaunchServices,
/// and require memory permission for App-owned terminal execution.
struct ManagedEnginePolicy {
    static let removedEnvironment = ["TMUX", "TMUX_PANE", "SSH_AUTH_SOCK"]
    let thread: UUID
    let environment: [String: String]
    static func forThread(_ thread: UUID, creator: String?, fleet: DeviceFleetStore) throws -> Self? {
        guard let creator else { return nil }
        guard let capabilities = try fleet.capabilities(for: creator),
              DeviceFleetCapabilities.allowsNativeExecution(capabilities) else {
            throw DeviceDispatch.Failure(reason: "管理者尚未取得派工與檔案權限，不能啟動工作引擎。")
        }
        return capabilities.contains("memory") ? nil : Self(thread: thread, environment: fleet.environment)
    }
    static func refusal(_ error: Error, fleet: DeviceFleetStore) -> String {
        fleet.audit(error, fallback: "fleet_managed_execution_refused")
        return (error as? DeviceDispatch.Failure)?.localizedDescription ?? "這台的設備群資料需要重新同步，請到 App 的設備頁處理。"
    }
    private struct BoundaryError: Error, LocalizedError {
        var errorDescription: String? { "受管對話的工作資料夾已改變，請移除捷徑或重新建立對話。" }
    }
    var root: URL {
        URL(fileURLWithPath: HandsPath.canonical(DeviceRegistry(environment: environment).root.deletingLastPathComponent().path))
            .appendingPathComponent("managed-engines").appendingPathComponent(thread.uuidString)
    }
    private var applicationDataRoots: [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let paths = [DeviceRegistry(environment: environment).root.deletingLastPathComponent().path,
                     home + "/Library/Application Support/tatwo2"]
        return Array(Set(paths.flatMap { [$0, HandsPath.canonical($0)] })).sorted()
    }
    var protectedPaths: [String] {
        let entry = TatwoEntry(environment: environment)
        let home = environment["HOME"] ?? NSHomeDirectory()
        let shared = ClaudeSidecar.engineHomeRoot(environment: environment).path
        // Protect complete stores, including future files, logs and generated backups.
        // Only this thread's isolated directory is exempt from the App data root.
        let paths = applicationDataRoots + [entry.root.path,
                     (OSUpstream.runtimePath(environment: environment) as NSString).deletingLastPathComponent,
                     home + "/.claude", home + "/.codex", home + "/.grok", shared,
                     home + "/Library/Application Support/tatwo2/CliHome", home + "/Library/Application Support/TATWO OS/Browser",
                     home + "/.zsh_history", home + "/.zsh_sessions", home + "/.bash_history", home + "/.bash_sessions",
                     home + "/Library/Caches/tatwo2", home + "/Library/Caches/TATWO OS/Browser",
                     home + "/.zshrc", home + "/.zprofile", home + "/.zshenv", home + "/.zlogin", home + "/.ssh", home + "/Library/LaunchAgents"]
        // Include both lexical and resolved paths: engine-memory links must not bypass the boundary.
        return Array(Set(paths.flatMap { [$0, HandsPath.canonical($0)] })).sorted()
    }
    private func isProtected(_ path: String) -> Bool {
        let canonical = HandsPath.canonical(path), isolated = HandsPath.canonical(root.path)
        return protectedPaths.contains { privatePath in
            if applicationDataRoots.contains(privatePath), canonical == isolated || canonical.hasPrefix(isolated + "/") { return false }
            return HandsPath.overlaps(canonical, privatePath)
        }
    }
    private func workDirectory(_ requested: String?) throws -> String {
        if let requested {
            let path = HandsPath.canonical(requested)
            if !isProtected(path) { return path }
        }
        let directory = root.appendingPathComponent("work")
        try withDirectory("work") { _ in }
        return HandsPath.canonical(directory.path)
    }
    /// The owning conversation chooses the boundary; a command may only narrow it.
    func workDirectory(for thread: LiveThreadRecord, project: LiveProjectRecord?, requested: String? = nil) throws -> String {
        let base = try workDirectory(thread.cwdOverride ?? project?.workdir)
        guard let requested else { return base }
        guard requested.hasPrefix("/") else { throw DeviceDispatch.Failure(reason: "工作位置須是這條對話工作資料夾內的完整路徑，請改用對話的工作資料夾。") }
        let path = HandsPath.canonical(URL(fileURLWithPath: requested).standardizedFileURL.path)
        guard HandsPath.isWithin(path, base), !isProtected(path) else {
            throw DeviceDispatch.Failure(reason: "指定的工作位置不在這條對話的工作資料夾內，請改用對話的工作資料夾或其中的子資料夾。")
        }
        return path
    }
    /// Native children can rename their private directories. App writes must keep the
    /// directory descriptor and refuse links at every component, including existing parents.
    private func withDirectory<T>(_ relative: String, _ body: (Int32) throws -> T) throws -> T {
        let base = HandsPath.canonical(DeviceRegistry(environment: environment).root.deletingLastPathComponent().path)
        let prefix = "managed-engines/" + thread.uuidString + "/" + relative
        guard !isProtected(base + "/" + prefix) else { throw BoundaryError() }
        guard let filesystem = try? HandsQuarantine.openDirectory("/") else { throw BoundaryError() }
        defer { close(filesystem) }
        guard let (parent, _) = try? HandsQuarantine.openParent(filesystem, base + "/.managed-directory") else { throw BoundaryError() }
        defer { close(parent) }
        guard let (directory, _) = try? HandsQuarantine.makeParents(parent, prefix + "/.managed-directory") else { throw BoundaryError() }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), fchmod(directory, 0o700) == 0 else { throw BoundaryError() }
        return try body(directory)
    }
    private func writeCredential(_ bytes: Data, directory: Int32, name: String) throws {
        var info = stat()
        let existing = fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW)
        guard (existing == 0 && (info.st_mode & S_IFMT) == S_IFREG) || (existing != 0 && errno == ENOENT) else { throw BoundaryError() }
        let temporary = ".auth-" + UUID().uuidString
        defer { _ = unlinkat(directory, temporary, 0) }
        try HandsQuarantine.writeNew(directory, temporary, bytes)
        guard renameat(directory, temporary, directory, name) == 0 else { throw BoundaryError() }
    }
    func sandboxArguments(executable: String, arguments: [String], writableDirectory: String? = nil) -> [String] {
        // Paths are -D parameters, never interpolated into profile syntax.
        let isolated = Array(Set([root.path, HandsPath.canonical(root.path)])).sorted()
        var definitions = protectedPaths.enumerated().flatMap { ["-D", "PRIVATE\($0.offset)=\($0.element)"] }
        definitions += isolated.enumerated().flatMap { ["-D", "ISOLATED\($0.offset)=\($0.element)"] }
        // realpath/stat must traverse the isolated home's parents. Exempt only
        // those directory metadata lookups; directory listings and contents stay denied.
        var parents = Set<String>()
        for path in isolated {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            while parent.path != "/" {
                parents.insert(parent.path); parent.deleteLastPathComponent()
            }
        }
        let metadataParents = parents.sorted()
        definitions += metadataParents.enumerated().flatMap { ["-D", "PARENT\($0.offset)=\($0.element)"] }
        let exemptions = isolated.indices.map { "(require-not (subpath (param \"ISOLATED\($0)\")))" }.joined(separator: " ")
        let filters = protectedPaths.enumerated().map { index, path in
            let filter = "(subpath (param \"PRIVATE\(index)\"))"
            return applicationDataRoots.contains(path) ? "(require-all " + filter + " " + exemptions + ")" : filter
        }.joined(separator: " ")
        let metadataExemptions = metadataParents.indices.map { "(require-not (literal (param \"PARENT\($0)\")))" }.joined(separator: " ")
        let metadataFilters = protectedPaths.enumerated().map { index, path in
            let filter = "(subpath (param \"PRIVATE\(index)\"))"
            return applicationDataRoots.contains(path) ? "(require-all " + filter + " " + exemptions + " " + metadataExemptions + ")" : filter
        }.joined(separator: " ")
        var socketRoots = ["/private/tmp/tatwo2-cli-\(getuid())", "/private/tmp/tmux-\(getuid())",
            (OSAgentBridge.resolveSocketPath(environment: environment) as NSString).deletingLastPathComponent,
            (BrowserAgentBridge.resolveSocketPath(environment: environment) as NSString).deletingLastPathComponent]
        if let agent = environment["SSH_AUTH_SOCK"], !agent.isEmpty { socketRoots.append(agent) }
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !agent.isEmpty { socketRoots.append(agent) }
        if let tmux = environment["TMUX"]?.split(separator: ",").first { socketRoots.append((String(tmux) as NSString).deletingLastPathComponent) }
        if let temporary = environment["TMUX_TMPDIR"] { socketRoots.append(temporary + "/tmux-\(getuid())") }
        socketRoots = Array(Set(socketRoots.flatMap { [$0, HandsPath.canonical($0)] })).sorted()
        definitions += socketRoots.enumerated().flatMap { ["-D", "SOCKET\($0.offset)=^" + NSRegularExpression.escapedPattern(for: $0.element) + "(/|$)"] }
        definitions += ["-D", "SSH_AGENT=^/(private/)?(tmp|var/run)/com[.]apple[.]launchd[.][^/]+/Listeners$"]
        let sockets = "(remote unix-socket (path-regex (param \"SSH_AGENT\"))) " + socketRoots.indices.map { "(remote unix-socket (path-regex (param \"SOCKET\($0)\")))" }.joined(separator: " ")
        var profile = "(version 1)(allow default)(deny file-write* " + filters + ")"
        profile += "(deny appleevent-send)"
        // Match existing and future Git metadata, including nested repos and directory renames.
        profile += "(deny file-write* (regex \"/[.][gG][iI][tT](/|$)\"))"
        profile += "(deny file-read-data file-read-xattr " + filters + ")(deny file-read-metadata " + metadataFilters + ")"
                + "(deny network-outbound " + sockets + ")"
                + "(deny mach-lookup (global-name-regex \"^com[.]apple[.](lsd|LaunchServices)\") (global-name \"com.apple.coreservices.launchservicesd\"))"
                + "(deny process-exec (literal \"/usr/bin/osascript\") (literal \"/usr/bin/automator\") (literal \"/bin/launchctl\") (literal \"/usr/bin/launchctl\") (literal \"/usr/bin/open\"))"
        let writableDirectory = writableDirectory ?? root.appendingPathComponent("work").path
        let writable = Array(Set([writableDirectory, HandsPath.canonical(writableDirectory)] + isolated)).sorted()
        definitions += writable.enumerated().flatMap { ["-D", "WRITE\($0.offset)=\($0.element)"] }
        let outside = writable.indices.map { "(require-not (subpath (param \"WRITE\($0)\")))" }.joined(separator: " ")
        profile += "(deny file-write* (require-all (subpath \"/\") " + outside
                + " (require-not (literal \"/dev/null\")) (require-not (literal \"/dev/tty\"))"
                + " (require-not (literal \"/dev/stdout\")) (require-not (literal \"/dev/stderr\")) (require-not (subpath \"/dev/fd\"))"
                + " (require-not (literal \"/dev/ptmx\")) (require-not (regex \"^/dev/ttys[0-9]+\"))))"
        return definitions + ["-p", profile, executable] + arguments
    }
    func prepareEnvironment(_ input: [String: String]) throws -> [String: String] {
        var env = input
        let fm = FileManager.default
        let shared = ClaudeSidecar.engineHomeRoot(environment: environment)
        let isolated = root.appendingPathComponent("engines")
        // Only login credentials cross into this thread's engine home; no memory, rules, sessions or MCP settings.
        for (kind, relative) in [("codex", "auth.json"), ("claude", ".credentials.json"), ("grok", ".grok/auth.json")] {
            let source = shared.appendingPathComponent(kind).appendingPathComponent(relative)
            try withDirectory("engines/" + kind + "/" + (relative as NSString).deletingLastPathComponent) { descriptor in
                if fm.fileExists(atPath: source.path) {
                    let bytes = try DeviceDispatchSafeFile.read(source, limit: 1024 * 1024)
                    try writeCredential(bytes, directory: descriptor, name: (relative as NSString).lastPathComponent)
                }
            }
        }
        let home = root.appendingPathComponent("home")
        try withDirectory("home") { _ in }
        try withDirectory("tmp") { _ in }
        env["HOME"] = home.path; env["CFFIXED_USER_HOME"] = home.path
        env["TATWO2_ENGINES_ROOT"] = isolated.path
        env["CODEX_HOME"] = isolated.appendingPathComponent("codex").path
        env["TATWO2_CODEX_SOURCE_HOME"] = env["CODEX_HOME"]
        env["CLAUDE_CONFIG_DIR"] = isolated.appendingPathComponent("claude").path
        env["TATWO2_GROK_HOME"] = isolated.appendingPathComponent("grok").path
        env["TATWO2_MANAGED_NO_MEMORY"] = "1"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path
        env["CLANG_MODULE_CACHE_PATH"] = root.appendingPathComponent("tmp/clang").path
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = root.appendingPathComponent("tmp/swift-modules").path
        env["SWIFTPM_CACHE_PATH"] = root.appendingPathComponent("tmp/swiftpm").path
        env["XDG_CACHE_HOME"] = root.appendingPathComponent("tmp/cache").path
        env["ZDOTDIR"] = home.path; env["HISTFILE"] = home.appendingPathComponent(".zsh_history").path
        for key in Self.removedEnvironment { env[key] = nil }
        return env
    }
}
