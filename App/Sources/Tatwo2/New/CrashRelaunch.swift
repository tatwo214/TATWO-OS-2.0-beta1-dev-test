import AppKit
@MainActor enum CrashRelaunch {
    nonisolated static let label = "ai.tatwo.tatwo2.keepalive"
    static var hasLaunchTargets = false
    nonisolated static func canHandoff(_ arguments: [String], openEvent: Bool) -> Bool {
        !openEvent && !arguments.dropFirst().contains { !$0.hasPrefix("-") }
    }
    static var requested: Bool?
    static var enabled: Bool { !UserDefaults.standard.bool(forKey: "crashRelaunchDisabled") }
    static var available: Bool {
        let env = ProcessInfo.processInfo.environment
        return Bundle.main.bundleIdentifier == "ai.tatwo.tatwo2" &&
            env["TATWO2_LIVE_ROOT"] == nil && env["TATWO_STAGING_ROOT"] == nil && env["TATWO2_SELFTEST"] == nil
    }
    nonisolated static func attempts(_ prior: [Double], now: Double) -> [Double] {
        prior.filter { now - $0 >= 0 && now - $0 < 120 } + [now]
    }
    static func launch() -> Bool {
        guard available, enabled, canHandoff(CommandLine.arguments, openEvent: hasLaunchTargets) else { return false }
        let defaults = UserDefaults.standard, key = "crashRelaunchAttempts"
        if ProcessInfo.processInfo.environment["TATWO2_KEEPALIVE"] == "1" {
            let recent = attempts(defaults.array(forKey: key) as? [Double] ?? [], now: Date().timeIntervalSince1970)
            defaults.set(recent, forKey: key)
            if recent.count >= 3 {
                defaults.set(true, forKey: "crashRelaunchDisabled")
                do { try configure(enabled: false) } catch { show(error) }
                let alert = NSAlert(); alert.messageText = "已關閉當機自動重開"
                alert.informativeText = "App 在 2 分鐘內已自動開啟 3 次。請檢查問題後再啟用。"; alert.runModal()
                willTerminate()
            }
            return false
        }
        defaults.removeObject(forKey: key)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        if FileManager.default.fileExists(atPath: plist.appendingPathExtension("pending-removal").path), !FileManager.default.fileExists(atPath: plist.path) { return false }
        if TatwoSingleInstanceGuard.forwardToExistingInstanceAndExitIfNeeded() { return true }
        do { try configure(enabled: true); return true }
        catch { show(error); return false }
    }
    static func change(_ value: Bool) {
        if value { requested = true; NSApp.terminate(nil); return }
        do { try configure(enabled: false); UserDefaults.standard.set(true, forKey: "crashRelaunchDisabled") }
        catch { show(error) }
    }
    static func willTerminate(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              domain: String = "gui/\(getuid())", job: String = label) {
        do {
            if requested == true { try configure(enabled: true); UserDefaults.standard.set(false, forKey: "crashRelaunchDisabled") }
            let plist = home.appendingPathComponent("Library/LaunchAgents/\(job).plist"), pending = plist.appendingPathExtension("pending-removal")
            guard FileManager.default.fileExists(atPath: pending.path), !FileManager.default.fileExists(atPath: plist.path) else { return }
            var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
            posix_spawnattr_setpgroup(&attr, 0); posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
            let args = ["/bin/launchctl", "bootout", "\(domain)/\(job)"].map { $0.withCString { strdup($0) } } + [nil]
            defer { args.forEach { free($0) } }; var pid: pid_t = 0
            try FileManager.default.removeItem(at: pending) // bootout may terminate us before spawn returns.
            let code = args.withUnsafeBufferPointer { posix_spawn(&pid, "/bin/launchctl", nil, &attr, $0.baseAddress!, environ) }
            if code != 0 { try Data().write(to: pending); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        } catch { show(error) }
        requested = nil
    }
    static func configure(enabled: Bool, executable: URL = Bundle.main.executableURL!,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          domain: String = "gui/\(getuid())", job: String = label,
                          waitPID: Int32 = getpid(), environment: [String: String] = [:]) throws {
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(job).plist"), pending = plist.appendingPathExtension("pending-removal")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !enabled {
            try Data().write(to: pending, options: .atomic)
            if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": job, "Program": executable.path, "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10, "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua", "AbandonProcessGroup": true,
            "EnvironmentVariables": environment.merging(["TATWO2_KEEPALIVE": "1", "HOME": home.path]) { _, value in value }
        ], format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        if FileManager.default.fileExists(atPath: pending.path) { try FileManager.default.removeItem(at: pending) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /bin/launchctl print \"$2/$3\" 2>/dev/null | /usr/bin/grep -q 'pid = ' && exit 0; /bin/launchctl bootout \"$2/$3\" 2>/dev/null; /bin/launchctl bootstrap \"$2\" \"$4\" && /bin/launchctl kickstart \"$2/$3\"", "relaunch", String(waitPID), domain, job, plist.path]
        try process.run()
    }
    static func show(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "無法設定當機自動重開"; alert.informativeText = error.localizedDescription; alert.runModal()
    }
}
