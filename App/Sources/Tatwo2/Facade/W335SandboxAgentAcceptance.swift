#if DEBUG
import Darwin
import Foundation

enum W335SandboxAgentAcceptance {
    final class SocketHost: @unchecked Sendable {
        let listener: Int32
        let service: HandsService
        init(root: URL, service: HandsService) throws {
            self.service = service
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                for (i, value) in root.appendingPathComponent("o.sock").path.utf8.enumerated() { bytes[i] = value }
            }
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard listener >= 0, bound == 0, listen(listener, 8) == 0 else { throw DeviceFleetError.malformed }
        }
        func start() {
            DispatchQueue.global().async { [self] in
                while true {
                    var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    guard poll(&item, 1, 1000) >= 0 else { return }
                    if item.revents == 0 { continue }
                    let fd = accept(listener, nil, nil)
                    guard fd >= 0 else { return }
                    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    do {
                        guard let input = OSAgentBridge.readRequest(fd) else { throw DeviceFleetError.malformed }
                        let request = try JSONSerialization.jsonObject(with: input) as! [String: Any]
                        let reply = OSAgentBridge.handsResponse(method: request["method"] as! String, params: request["params"] as! [String: Any], service: service)
                        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: reply) + Data([10]))
                    } catch { }
                    try? handle.close()
                }
            }
        }
        func stop() { shutdown(listener, SHUT_RDWR); close(listener) }
    }
    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), let artifacts = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw DeviceFleetError.malformed }
        let root = URL(fileURLWithPath: "/tmp/w335-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        func dir(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        let cwd = try dir("project"), paths = HandsPaths(root: try dir("hands"))
        var runtime = HandsRuntime.current(paths: paths, environment: env)
        runtime.home = try dir("home").path; runtime.entryRoot = try dir("entry").path; runtime.appSupport = try dir("support").path
        let live = ChatLiveEngine(store: ChatLiveStore(root: try dir("live")), environment: env, tap: W185FakeConversationTap())
        defer { live.shutdownAll() }
        let bots = BotLibrary(root: root, skillsRoot: try dir("skills")); await bots.ready()
        let model = ChatPageModel(environment: env, botCoreFixture: (live, BotStore(library: bots)))
        let service = HandsService(paths: paths, runtime: runtime); service.attach(model: model)
        service.deviceIDOverride = HandsConnectAcceptance.hostID
        _ = try service.updateSettings { $0.enabled = true; $0.level = 2; $0.allProjects = true; $0.hostDeviceID = HandsConnectAcceptance.hostID; $0.publicHost = "hands.example.com" }
        let defaults = UserDefaults.standard, previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(previous.merging([GroupCoderBridge.flag: true]) { _, new in new }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let project = live.newProject(name: "Fixture", workdir: cwd.path), thread = live.newThread(in: project)
        _ = live.groupBridge.route(threadID: thread, text: "@@ChatGPT", model: nil, engine: .codex, systemPrompt: nil, attachments: [], effort: nil, tier: nil, ultrawork: nil, delivery: nil, source: .init(origin: "composer", actor: "使用者", surface: nil))
        try Data("before\n".utf8).write(to: cwd.appendingPathComponent("main.txt"))
        try Data("原文\n".utf8).write(to: cwd.appendingPathComponent("文件.txt"))
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "seed"]] {
            let result = try await Task.detached { try HandsGit.run(args, cwd: cwd.path) }.value
            guard result.status == 0 else { throw DeviceFleetError.malformed }
        }
        let device = "dots-synthetic"
        service.sandboxLane.deviceCheck = { $0 == device }
        for params: [String: Any] in [
            ["op": "register_client", "scope": "sandbox", "redirect_uris": [HandsSettings.defaultCallbacks[0]]],
            ["op": "register_client", "scope": "sandbox", "redirect_uris": ["https://other.example.com/sandbox/callback"]],
            ["op": "register_client", "redirect_uris": ["https://hands.example.com/sandbox/callback"]]
        ] {
            var refused = false
            do { _ = try service.handle(method: "hands_auth", params: params) } catch { refused = true }
            guard refused else { throw DeviceFleetError.malformed }
        }
        print("W335SANDBOXAGENT PASS sandbox-register-window-and-callback-boundary")
        try service.sandboxLane.pair(device)
        let socket = try SocketHost(root: root, service: service); socket.start(); defer { socket.stop() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "tests/helpers/w335-client.mjs", root.path]
        process.environment = env
        let log = root.appendingPathComponent("node.log"); FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(100)
        var queued = false, submitted = false
        while process.isRunning && Date() < deadline {
            if let code = service.auth.pendingCard?.pairingCode { try Data(code.utf8).write(to: root.appendingPathComponent("pairing-code"), options: .atomic) }
            if !queued && FileManager.default.fileExists(atPath: root.appendingPathComponent("paired").path) {
                let lane = service.sandboxLane
                _ = try await Task.detached { try lane.queue(device, thread: thread, instruction: "printf 'after\\n' > main.txt\nprintf '修改\\n' > 文件.txt\ngit add .\ngit -c user.name=fixture -c user.email=fixture@localhost commit -qm runner\nprintf '工作樹\\n' >> 文件.txt\nprintf 'local output\\n' > output.txt\nprintf '中文產物\\n' > 產物.txt", files: ["main.txt", "文件.txt"], artifacts: ["output.txt", "產物.txt"]) }.value
                queued = true; try Data().write(to: root.appendingPathComponent("queued"))
            }
            if !submitted && FileManager.default.fileExists(atPath: root.appendingPathComponent("submitted").path) {
                let event = live.groupBridge.sessions[thread]!.events.last!
                let proposal = live.groupBridge.proposals.proposal(thread, event.sequence)
                guard proposal?.title == "沙盒交件（外部資料）", proposal?.files.map(\.path).sorted() == ["main.txt", "output.txt", "文件.txt", "產物.txt"],
                      try String(contentsOf: cwd.appendingPathComponent("main.txt"), encoding: .utf8) == "before\n" else { throw DeviceFleetError.malformed }
                print("W335SANDBOXAGENT PASS real-python-result-in-host-proposal-project-unchanged")
                guard event.text.contains("文件.txt"), event.text.contains("產物.txt"),
                      try live.groupBridge.proposals.patch(thread, event.sequence).contains("+工作樹") else { throw DeviceFleetError.malformed }
                print("W335SANDBOXAGENT PASS chinese-files-and-artifacts-in-host-card")
                print("W335SANDBOXAGENT PASS runner-commit-and-worktree-in-host-patch")
                submitted = true; service.sandboxLane.remove(device)
                try Data().write(to: root.appendingPathComponent("revoked"))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !process.isRunning, process.terminationStatus == 0, submitted else {
            print(try String(contentsOf: log, encoding: .utf8)); throw DeviceFleetError.malformed
        }
        let evidence = URL(fileURLWithPath: artifacts).appendingPathComponent("client-evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for file in ["node.log", "python-pair-pair.log", "python-run-once.log"] { try FileManager.default.copyItem(at: root.appendingPathComponent(file), to: evidence.appendingPathComponent(file)) }
        print("W335SANDBOXAGENT SUMMARY failures=0 passed=5")
        return true
    }
}
#endif
