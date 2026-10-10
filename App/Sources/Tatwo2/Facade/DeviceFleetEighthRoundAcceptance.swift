#if DEBUG
import Darwin
import Foundation
import SwiftUI
import Vision

enum DeviceFleetEighthRoundAcceptance {
    static func withMainRunLoop(_ body: @escaping @MainActor () async throws -> Void) throws {
        let done = DispatchSemaphore(value: 0), result = HandsLocked<Result<Void, Error>?>(nil)
        Task { @MainActor in
            defer { done.signal() }
            do { try await body(); result.set(.success(())) }
            catch { result.set(.failure(error)) }
        }
        guard done.wait(timeout: .now() + 30) == .success, let outcome = result.get() else {
            throw DeviceDispatch.Failure(reason: "W221_main_fixture_timeout")
        }
        try outcome.get()
    }

    @MainActor static func waitForLaunch(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !ready() {
            guard Date() < deadline else { throw DeviceDispatch.Failure(reason: "W221_sidecar_launch_timeout") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func run(scenario: String, make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R8_FAIL_" + name) }
            print("W187R8 PASS " + name)
        }
        let a = try make(100, true), b = try make(101, false)
        if scenario.hasPrefix("r14-") {
            try DeviceFleetFourteenthRoundAcceptance.run(scenario: scenario, a: a, b: b, pair: pair)
            return
        }
        if scenario.hasPrefix("r13-") {
            try DeviceFleetThirteenthRoundAcceptance.run(scenario: scenario, a: a, b: b, pair: pair)
            return
        }
        if scenario.hasPrefix("r12-") {
            try DeviceFleetTwelfthRoundAcceptance.run(scenario: scenario, a: a, b: b, pair: pair)
            return
        }
        if scenario.hasPrefix("ui-") {
            try DispatchQueue.main.sync {
                var preview: DeviceIdentity?
                if scenario != "ui-initial" {
                    let local = DeviceIdentity(deviceID: b.id, name: "fixture observer", hardwareModel: "fixture", role: ["ui-primary", "ui-recovery-invalid"].contains(scenario) ? .primary : .secondary, epoch: 2, primaryDeviceID: a.id, updatedAt: Date())
                    var record = PrimaryTransfer.Record(from: ["ui-complete", "ui-app-unavailable", "ui-stale", "ui-card-coordinator", "ui-signing", "ui-progress", "ui-retired"].contains(scenario) ? local.deviceID : a.id,
                        to: a.id, oldEpoch: 1, epoch: 2, participants: [a.id], sourceDeviceID: a.id,
                        sourceRoot: a.dispatch.entry.root.path, hashes: [:], sourcePages: 42, signingName: "fixture release")
                    record.committed = true; record.epochACKs = [a.id]
                    if scenario == "ui-signing" { record.releaseChecked = true; record.release = .missingCertificate }
                    if scenario == "ui-progress" { record.constitution = true; record.constitutionRevision = 1; record.acknowledgedRevision = record.revision }
                    if scenario == "ui-complete" {
                        record.constitution = true; record.constitutionRevision = 1; record.brain = .migrated
                        record.brainVerified = true; record.brainRevision = 1; record.release = .ready
                        record.releaseChecked = true; record.releaseRevision = 1; record.acknowledgedRevision = record.revision
                    }
                    preview = local
                    if scenario == "ui-recovery-invalid" { record.to = local.deviceID; record.localVerification = true; record.committed = false; preview!.primaryDeviceID = local.deviceID }
                    preview!.transfer = record
                }
                let view: AnyView
                var cardSession: DeviceFlowSession?
                defer { cardSession?.close() }
                if scenario == "ui-card-coordinator" {
                    preview!.transfer!.sourceDeviceID = b.id
                    preview!.transfer!.hashes = try b.dispatch.snapshot().mapValues(DeviceDispatch.hash)
                    try DeviceIdentityStore.forLocalDevice(entry: b.dispatch.entry, pairedDeviceID: b.id).write(preview!)
                    let session = DeviceFlowSession(environment: b.env, pasteboard: NSPasteboard(name: .init(UUID().uuidString)))
                    try session.open(.transfer)
                    cardSession = session
                    view = AnyView(DeviceFlowCard(session: session))
                } else {
                    view = AnyView(DeviceFlowTransferPanel(preview: preview, previewCoordinatorRetired: scenario == "ui-retired", previewContactError: ["ui-app-unavailable", "ui-progress"].contains(scenario) ? DeviceFleetGate.CallError.appUnavailable : scenario == "ui-stale" ? DeviceDispatch.Failure(reason: "transfer_identity_stale") : nil))
                }
                let host = NSHostingView(rootView: view.padding(24).frame(width: 900, height: 1100).background(Color.white).environment(\.colorScheme, .light).foregroundStyle(.black))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let artifact = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!).appendingPathComponent(scenario + ".png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: artifact)
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hant", "en-US"]
                try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                print("R9 rendered transfer: " + text)
                try check("UI-01-no-premature-or-observer-offline-warning", !text.contains("現任主設備須在線"))
                if scenario == "ui-signing" {
                    func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
                    try check("R12-SEQ-03-disconnected-signing-field-hidden", !fields(host).contains { $0.isEditable })
                    try check("R11-SEQ-01-status-shows-compared-name", text.contains("缺憑證") && text.contains("比對名稱"))
                }
                if scenario == "ui-recovery-invalid" { try check("R11-ROSTER-04-invalid-recovery-has-no-checkpoint-controls", !text.contains("手動操作")) }
                if scenario == "ui-progress" { try check("R11-SEQ-02-continue-later-steps", text.contains("再繼續③④") && !text.contains("再按②")) }
                if scenario == "ui-retired" { try check("R11-SEQ-04-retired-coordinator-guidance", text.contains("這台不需要操作")) }
                if scenario == "ui-complete" { try check("R10-UI-02-complete-no-signature-or-retry", !text.contains("簽章身分名稱") && !text.contains("重試同步")) }
                if scenario == "ui-card-coordinator" { try check("R10-UI-02-coordinator-card-no-contradiction", !text.replacingOccurrences(of: " ", with: "").contains("請在現任MAIN")) }
                if scenario == "ui-primary" { try check("R10-LIGHT-01-no-duplicate-start-controls", !text.components(separatedBy: "\n").contains("新主設備") && !text.contains("移交 epoch")) }
                if scenario == "ui-app-unavailable" { try check("R10-UI-01-app-unavailable-action", text.replacingOccurrences(of: " ", with: "").contains("App沒開") && text.contains("再按②")) }
                if scenario == "ui-stale" { try check("R10-UI-01-stale-status-action", text.contains("狀態已過期")) }
                if scenario == "ui-observer" { try check("R7-ROSTER-03-observer-has-no-stale-transfer-status", !text.contains("移交未完成")) }
                if scenario == "ui-complete" { try check("ROSTER-03-completed-checkpoint-controls-collapse", text.contains("移交完成") && !text.contains("手動操作") && !text.contains("打包依賴")) }
            }
            print("W187R8 SUMMARY failures=0"); return
        }
        if scenario.hasPrefix("r11-") {
            try DeviceFleetEleventhRoundAcceptance.run(scenario: scenario, a: a, b: b, pair: pair)
            print("W187R11 SUMMARY failures=0"); return
        }
        if scenario == "sandbox-plan" {
            var env = a.env
            let base = a.registry.root.deletingLastPathComponent()
            let scratch = base.deletingLastPathComponent()
            env["TATWO2_OS_SOCKET"] = scratch.appendingPathComponent("net-os/o.sock").path
            env["TATWO2_BROWSER_SOCKET"] = scratch.appendingPathComponent("net-browser/b.sock").path
            env["TMUX"] = scratch.appendingPathComponent("net-tmux/server,1,0").path
            env["TMUX_TMPDIR"] = scratch.appendingPathComponent("net-tmp").path
            env["HOME"] = base.deletingLastPathComponent().appendingPathComponent("synthetic-home").path
            let policy = ManagedEnginePolicy(thread: UUID(), environment: env)
            let cwd = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            let paths = [".zsh_history", ".zsh_sessions/private", ".bash_history", ".bash_sessions/private",
                         "Library/Caches/tatwo2/Cache/private", "Library/Application Support/TATWO OS/Browser/private"]
                .map { URL(fileURLWithPath: env["HOME"]!).appendingPathComponent($0) }
            for path in paths {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("synthetic private history\n".utf8).write(to: path)
            }
            let launch: [String: Any] = ["arguments": policy.sandboxArguments(executable: "/usr/bin/env", arguments: [], writableDirectory: cwd),
                "defaultArguments": policy.sandboxArguments(executable: "/usr/bin/env", arguments: []),
                "environment": try policy.prepareEnvironment(["PATH": ProcessInfo.processInfo.environment["PATH"]!, "TMUX": base.appendingPathComponent("tmux/server,1,0").path]),
                "cwd": cwd, "privatePaths": paths.map(\.path), "home": env["HOME"]!,
                "sockets": [env["TATWO2_OS_SOCKET"]!, env["TATWO2_BROWSER_SOCKET"]!, scratch.appendingPathComponent("net-tmux/fixture.sock").path, scratch.appendingPathComponent("net-tmp/tmux-\(getuid())/fixture.sock").path]]
            try JSONSerialization.data(withJSONObject: launch).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!).appendingPathComponent("sandbox-plan.json"))
            print("W187R8 SUMMARY failures=0"); return
        }
        if scenario.hasPrefix("entry-") {
            var env = a.env
            let base = a.registry.root.deletingLastPathComponent()
            env["HOME"] = base.deletingLastPathComponent().appendingPathComponent("synthetic-home").path
            let policy = ManagedEnginePolicy(thread: UUID(), environment: env)
            let cwd = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            let targets = [env["HOME"]! + "/.zshrc", env["HOME"]! + "/Library/LaunchAgents/x.plist"]
            try FileManager.default.createDirectory(atPath: env["HOME"]! + "/Library/LaunchAgents", withIntermediateDirectories: true)
            let script = URL(fileURLWithPath: cwd).appendingPathComponent("fixture.mjs")
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: targets), as: UTF8.self)
            let js = "import fs from 'node:fs';const failures=" + encoded + ".map(p=>{try{fs.writeFileSync(p,'synthetic');return false}catch{return true}});fs.writeFileSync('result.json',JSON.stringify(failures));"
            try Data(js.utf8).write(to: script)
            let entry = scenario == "entry-openai" ? "codex" : String(scenario.dropFirst(6))
            if entry == "cli" {
                var launch = try DispatchQueue.main.sync {
                    let processEnv = ProcessInfo.processInfo.environment
                    let live = ChatLiveEngine(store: ChatLiveStore(root: base.appendingPathComponent("cli-chat")), environment: processEnv)
                    let model = ChatPageModel(environment: processEnv, botCoreFixture: (live, BotStore(root: base.appendingPathComponent("cli-bots"))))
                    return try model.launchForCLI(engine: .generic, workdir: cwd, memoryPolicy: policy)
                }
                launch.arguments += ["-c", "'" + ProcessInfo.processInfo.environment["TATWO2_W187_NODE"]! + "' '" + script.path + "'"]
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launch.executable); process.arguments = launch.arguments
                process.environment = launch.environment; process.currentDirectoryURL = launch.workingDirectory
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                let result = try JSONDecoder().decode([Bool].self, from: Data(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent("result.json")))
                try check("R7-CARDS-04-actual-no-memory-CLI-denies-writes", process.terminationStatus == 0 && result == [true, true])
            } else if let kind = ClaudeSidecar.Kind(rawValue: entry) {
                let defaultsKey = "tatwo2.sidecarPath." + entry
                let overrides = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                UserDefaults.standard.setVolatileDomain(overrides.merging([defaultsKey: script.path]) { _, new in new }, forName: UserDefaults.argumentDomain)
                defer { UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain) }
                let sidecar = ClaudeSidecar(kind: kind)
                try sidecar.start(cwd: cwd, resume: nil, model: nil, memoryPolicy: policy)
                defer { sidecar.terminate() }
                let output = URL(fileURLWithPath: cwd).appendingPathComponent("result.json")
                for _ in 0..<500 where !FileManager.default.fileExists(atPath: output.path) { usleep(10_000) }
                let result = try JSONDecoder().decode([Bool].self, from: Data(contentsOf: output))
                try check("R7-CARDS-04-actual-" + entry + "-denies-zshrc-and-launchagents", result == [true, true])
            } else {
                let manager = BackgroundJobManager(root: base.appendingPathComponent("background"))
                let command = "node '" + script.path + "'"
                let job = try manager.run(command: command, cwd: cwd, title: "synthetic", threadID: policy.thread, memoryPolicy: policy)
                defer { manager.stopAll() }
                for _ in 0..<500 where manager.status(jobID: job.jobID)?.state == "running" { usleep(10_000) }
                let result = try JSONDecoder().decode([Bool].self, from: Data(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent("result.json")))
                try check("R7-CARDS-04-actual-background-denies-zshrc-and-launchagents", result == [true, true])
            }
            try check("R7-CARDS-04-workspace-writable-" + entry, FileManager.default.fileExists(atPath: cwd + "/result.json"))
            print("W187R8 SUMMARY failures=0"); return
        }
        if scenario == "cli-history" {
            let env = ProcessInfo.processInfo.environment
            let home = env["HOME"]!
            try Data("HISTFILE=\"$HOME/.zsh_history\"\n".utf8).write(to: URL(fileURLWithPath: home + "/.zshrc"))
            let launch = try DispatchQueue.main.sync {
                let live = ChatLiveEngine(store: ChatLiveStore(root: a.dispatch.root.appendingPathComponent("chat")), environment: env)
                let model = ChatPageModel(environment: env, botCoreFixture: (live, BotStore(root: a.dispatch.root.appendingPathComponent("bots"))))
                return try model.launchForCLI(engine: .generic, workdir: home)
            }
            try check("N4-generic-terminal-keeps-native-environment", launch.environment["ZDOTDIR"] == nil && launch.environment["HISTFILE"] == nil)
            try check("N4-no-CliHome-forwarders", [".zshenv", ".zprofile", ".zshrc", ".zlogin"].allSatisfy { !FileManager.default.fileExists(atPath: home + "/Library/Application Support/tatwo2/CliHome/" + $0) })
            let process = Process(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: launch.executable); process.arguments = launch.arguments
            process.environment = launch.environment; process.currentDirectoryURL = launch.workingDirectory
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("print synthetic-history-command\nexit\n".utf8)); try input.fileHandleForWriting.close()
            process.waitUntilExit()
            try check("N4-native-zsh-history", FileManager.default.fileExists(atPath: home + "/.zsh_history"))
            print("W187R8 SUMMARY failures=0"); return
        }
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b, .owner, nil, false)
        b.dispatch.synchronize()
        switch scenario {
        case "background-default":
            var graph = try a.fleet.current()!.roster!; graph.edges.removeAll()
            graph.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: .oneway, capabilities: ["dispatch", "files"]))
            try a.fleet.publish(&graph); b.dispatch.synchronize()
            let manager = BackgroundJobManager(root: b.dispatch.root.appendingPathComponent("jobs"))
            let bridge = OSAgentBridge.fleetFixtureBridge()
            let model = try DispatchQueue.main.sync { () throws -> ChatPageModel in
                let live = ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("chat")), environment: b.env)
                let model = ChatPageModel(environment: b.env, botCoreFixture: (live, BotStore(root: b.dispatch.root.appendingPathComponent("bots"))))
                bridge.configureCallerTest(model: model, manager: manager)
                return model
            }
            defer { manager.stopAll(); DispatchQueue.main.sync { model.live?.shutdownAll() } }
            let owner = try DispatchQueue.main.sync { () throws -> UUID in
                let owner = model.live!.newThread(in: nil, title: "synthetic")
                model.localLiveForBridge!.markControllerThread(owner, fingerprint: try DeviceRegistry.fingerprint(publicKey: a.clientKey))
                return owner
            }
            let home = ProcessInfo.processInfo.environment["HOME"]!
            try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
            let approval = b.dispatch.root.appendingPathComponent("approval.txt")
            bridge.backgroundCommandApprover = { _, detail, _ in try? Data(detail.utf8).write(to: approval); return true }
            for path in [".zprofile", ".zshenv", ".zlogin", ".ssh/authorized_keys"] {
                let target = home + "/" + path
                try Data("synthetic original".utf8).write(to: URL(fileURLWithPath: target))
                let params: [String: Any] = ["callerThreadID": owner.uuidString, "cmd": "print changed > '" + target + "'"]
                let reply = try bridge.fixtureHandle(dispatch: b.dispatch, method: "run_background", params: params, caller: .engine(owner))
                guard let result = reply["result"] as? [String: Any], let raw = result["jobID"] as? String, let id = UUID(uuidString: raw) else { throw DeviceDispatch.Failure(reason: String(describing: reply)) }
                for _ in 0..<500 where manager.status(jobID: id)?.state == "running" { usleep(10_000) }
                let job = manager.status(jobID: id)!
                try check("R10-F1-no-cwd-denies-" + path, job.exitCode != 0 && String(decoding: Data(contentsOf: URL(fileURLWithPath: target)), as: UTF8.self) == "synthetic original")
                try check("R10-F1-approval-shows-normalized-cwd", job.cwd != home && String(contentsOf: approval, encoding: .utf8).contains(job.cwd))
            }
        case "admission-once", "session-switch":
            var graph = try a.fleet.current()!.roster!; graph.edges.removeAll()
            graph.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: .oneway, capabilities: ["dispatch", "files"]))
            try a.fleet.publish(&graph); b.dispatch.synchronize()
            let store = ChatLiveStore(root: b.dispatch.root.appendingPathComponent("chat"))
            let live = DispatchQueue.main.sync { ChatLiveEngine(store: store, environment: b.env) }
            let owner = try DispatchQueue.main.sync { () throws -> UUID in
                let owner = live.newThread(in: nil, title: "synthetic")
                live.markControllerThread(owner, fingerprint: try DeviceRegistry.fingerprint(publicKey: a.clientKey))
                let reads = DeviceFleetFourthRoundAcceptance.Results()
                if scenario == "admission-once" { DeviceFleetStore.fixtureStateRead = { reads.append(1) } }
                defer { DeviceFleetStore.fixtureStateRead = nil }
                try check("R10-F2-real-isolated-engine-launch", live.fixtureStartSidecar(owner, engine: .codex))
                if scenario == "admission-once" { try check("R10-F4-one-fleet-read-for-admission-and-policy", reads.sequences.count == 1) }
                return owner
            }
            if scenario == "admission-once" { DispatchQueue.main.sync { live.shutdownAll() }; print("W187R8 SUMMARY failures=0"); return }
            func session(_ engine: ChatLiveEngine) -> String? { DispatchQueue.main.sync { engine.threadRecord(owner)?.sessionIDs["codex"] } }
            for _ in 0..<1000 where session(live) == nil { usleep(10_000) }
            guard let isolatedID = session(live) else { throw DeviceDispatch.Failure(reason: "real isolated Codex did not initialize") }
            DispatchQueue.main.sync { live.shutdownAll() }
            graph.edges[0].capabilities.append("memory"); try a.fleet.publish(&graph); b.dispatch.synchronize()
            let reopened = DispatchQueue.main.sync { ChatLiveEngine(store: store, environment: b.env) }
            defer { DispatchQueue.main.sync { reopened.shutdownAll(); ClaudeSidecar.fixtureLaunch = nil } }
            try withMainRunLoop {
                var arguments: [String] = []
                ClaudeSidecar.fixtureLaunch = { _, args, _, _ in arguments = args }
                try check("R10-F2-granted-home-launch-starts", reopened.fixtureStartSidecar(owner, engine: .codex))
                try await waitForLaunch { !arguments.isEmpty }
                try check("R10-F2-granted-home-never-resumes-isolated-ID", !arguments.contains("--resume") && !arguments.contains(isolatedID))
            }
            for _ in 0..<1000 where session(reopened) == isolatedID { usleep(10_000) }
            try check("R10-F2-real-engine-initializes-after-memory-grant", session(reopened) != nil && session(reopened) != isolatedID)
        case "terminal-plan":
            var cliEnvironment = ProcessInfo.processInfo.environment.merging(b.env) { _, new in new }
            cliEnvironment["TATWO2_RESOURCES_ROOT"] = "/Applications/TATWO OS.app/Contents/Resources"
            let policy = ManagedEnginePolicy(thread: UUID(), environment: b.env)
            let cwd = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            let launch = try DispatchQueue.main.sync {
                let live = ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("chat")), environment: b.env)
                let model = ChatPageModel(environment: cliEnvironment, botCoreFixture: (live, BotStore(root: b.dispatch.root.appendingPathComponent("bots"))))
                model.permissionPreset = .askFirst
                do {
                    _ = try model.launchForCLI(engine: .codex, workdir: cwd, memoryPolicy: policy)
                    throw DeviceFleetError.malformed
                } catch let failure as DeviceDispatch.Failure {
                    try check("R11-CARDS-02-engine-CLI-refused-with-reason", failure.localizedDescription.contains("一般終端"))
                }
                return try model.launchForCLI(engine: .generic, workdir: cwd, memoryPolicy: policy)
            }
            try JSONSerialization.data(withJSONObject: ["executable": launch.executable, "arguments": launch.arguments, "environment": launch.environment, "cwd": cwd]).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!).appendingPathComponent("terminal-plan.json"))
            try check("R11-CARDS-02-generic-shell-keeps-outer-policy", launch.executable == "/usr/bin/sandbox-exec")
        case "reconcile-cache":
            a.dispatch.synchronize()
            let file = a.registry.root.appendingPathComponent("fleet-gate-policy.json")
            let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber
            a.dispatch.fixtureRecoveryNow = Date().addingTimeInterval(120)
            a.dispatch.synchronize()
            try check("R10-ROSTER-03-unchanged-files-not-rewritten-after-60s", FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber == inode)
            let keys = try Data(contentsOf: a.registry.authorizedKeysURL)
            try Data().write(to: a.registry.authorizedKeysURL); a.dispatch.synchronize()
            try check("R10-ROSTER-03-fingerprint-repairs-changed-keys", Data(contentsOf: a.registry.authorizedKeysURL) == keys)
        case "memory-launch":
            var graph = try a.fleet.current()!.roster!
            graph.edges.removeAll()
            graph.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: .oneway, capabilities: ["dispatch", "files", "memory"]))
            try a.fleet.publish(&graph); b.dispatch.synchronize()
            try withMainRunLoop {
                let store = ChatLiveStore(root: b.dispatch.root.appendingPathComponent("chat"))
                let live = ChatLiveEngine(store: store, environment: b.env)
                let thread = live.newThread(in: nil, title: "synthetic managed")
                live.markControllerThread(thread, fingerprint: try DeviceRegistry.fingerprint(publicKey: a.clientKey))
                var document = live.doc
                document.threads[document.threads.firstIndex { $0.id == thread }!].sessionIDs["codex"] = "synthetic-saved-session"
                document.threads[document.threads.firstIndex { $0.id == thread }!].sessionIsolated["codex"] = false
                live.shutdownAll(); store.save(document)
                let reopened = ChatLiveEngine(store: store, environment: b.env)
                defer { reopened.shutdownAll(); ClaudeSidecar.fixtureLaunch = nil }
                var launched: (String, [String], [String: String], String)?
                ClaudeSidecar.fixtureLaunch = { launched = ($0, $1, $2, $3) }
                let started = reopened.fixtureStartSidecar(thread, engine: .codex)
                if !started { print("R9 launch diagnostic " + String(describing: reopened.transcript(for: thread))) }
                try check("N1-real-managed-sidecar-starts", started)
                try await waitForLaunch { launched != nil }
                guard let launched else { throw DeviceFleetError.malformed }
                try JSONSerialization.data(withJSONObject: ["executable": launched.0, "arguments": launched.1,
                    "environment": launched.2, "cwd": launched.3]).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!).appendingPathComponent("memory-launch.json"))
                try check("N1-memory-grant-has-no-outer-sandbox", launched.0 != "/usr/bin/sandbox-exec")
                try check("N2-memory-grant-keeps-engine-home", launched.2["HOME"] == ProcessInfo.processInfo.environment["HOME"] && launched.2["CODEX_HOME"] == ProcessInfo.processInfo.environment["CODEX_HOME"] && launched.2["CLAUDE_CONFIG_DIR"] == ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] && launched.2["TATWO2_MANAGED_NO_MEMORY"] == nil)
                try check("N2-memory-grant-resumes", launched.1.contains("--resume") && launched.1.contains("synthetic-saved-session"))
            }
        case "revocation-resweep":
            let c = try make(103, false); try pair(a, c, .owner, nil, false)
            var attempts = 0
            let started = Date()
            DeviceFleetRevocation.testHooks = .init(sessions: { [.init(pid: 12345, start: 1, fingerprint: try! DeviceRegistry.fingerprint(publicKey: b.clientKey), address: b.host, tatwoRelated: true)] }, terminate: { _ in attempts += 1; return attempts > 2 })
            defer { DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false }) }
            try a.fleet.revoke(b.id)
            a.dispatch.synchronize()
            try check("ROSTER-02-first-termination-failure-reswept-within-budget", attempts >= 3 && Date().timeIntervalSince(started) < 60)
            let authorized = try Data(contentsOf: a.registry.authorizedKeysURL)
            try Data().write(to: a.registry.authorizedKeysURL)
            a.dispatch.synchronize()
            try check("ROSTER-02-primary-reconciles-keys-without-restart", Data(contentsOf: a.registry.authorizedKeysURL) == authorized)
        case "memory-restricted-fetch":
            var graph = try a.fleet.current()!.roster!; graph.edges.removeAll()
            graph.edges.append(.init(from: .device(a.id), to: .device(b.id), direction: .mutual, capabilities: ["memory"]))
            try a.fleet.publish(&graph); b.dispatch.synchronize()
            let p = EngineMemoryPaths(home: a.dispatch.root.appendingPathComponent("home").path, entryRoot: a.dispatch.entry.root)
            let q = EngineMemoryPaths(home: b.dispatch.root.appendingPathComponent("home").path, entryRoot: b.dispatch.entry.root)
            for paths in [p, q] {
                try EngineMemoryLinks.createMemoryFolder(paths.memory)
                try TatwoMemorySyncAcceptance.note(paths.memory, "synthetic.md", title: "Synthetic", body: "Synthetic memory.")
                _ = EngineMemoryLinks.commit(paths.memory, message: "synthetic")
            }
            let primary = TatwoMemorySyncEngine(paths: { p }, dispatch: a.dispatch)
            let bridge = OSAgentBridge.fleetFixtureBridge(); bridge.fixtureMemory(primary)
            var exports = 0
            let channel = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, rpc: { _, method, params in
                let reply = try bridge.fixtureHandle(dispatch: a.dispatch, method: method, params: params)
                guard reply["ok"] as? Bool == true else { throw DeviceFleetGate.CallError.rejected(reply["error"] as? String ?? "unknown") }
                var result = reply["result"] as! [String: Any]
                if method == "memory_sync_export" { exports += 1; result["bundle"] = "not-a-bundle" }
                return result
            })
            let status = TatwoMemorySyncEngine(paths: { q }, dispatch: channel).runOnce(.manual)
            print("R9 restricted export calls=\(exports) status=" + status.line)
            try check("MEM-01-real-secondaryRound-fetch-direction", exports > 0 && status.line == "同步沒成功：這次從主設備拉來的記憶驗不過，這輪不合併・下一輪再試")
        case "projection-enum", "projection-schema", "projection-storage":
            let staff = try make(102, false)
            let main = try a.fleet.current()!.roster!.groups.first { $0.type == .main }!.id
            try pair(a, staff, .sandbox, main, true)
            var roster = try a.fleet.current()!.roster!
            roster.devices[0].name += " revision"
            try a.fleet.publish(&roster)
            var envelope = try a.fleet.delivery(for: staff.id)!
            if scenario != "projection-storage" {
                var object = try JSONSerialization.jsonObject(with: envelope.body) as! [String: Any]
                if scenario == "projection-schema" { object["schema"] = "tatwo.device-fleet.v999" }
                else {
                    var slice = object["slice"] as! [String: Any], devices = slice["devices"] as! [[String: Any]]
                    devices[0]["role"] = "future_role"; slice["devices"] = devices; object["slice"] = slice
                }
                envelope.body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                let signature = try DeviceSignature.sign(envelope.body, namespace: DeviceFleetEnvelope.namespace, environment: a.env)
                envelope.signature = signature.0; envelope.publicKey = signature.1
            } else {
                // Only this synthetic journal is made immutable to force an atomic rename failure.
                try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: staff.fleet.url.path)
            }
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: staff.fleet.url.path) }
            let receipt = DeviceDispatch.Receipt(seq: 0, phase: "fleet", hashes: [:], updated: Date(), fleet: envelope)
            let proof = try a.dispatch.signed(method: "dispatch_ack", payload: DeviceDispatch.object(receipt), recipient: staff.id)
            let response = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: staff.dispatch, method: "dispatch_ack", params: proof)
            let reason = response["error"] as? String ?? "missing_error"
            try check("CARDS-03-actual-synchronize-" + scenario, reason == (scenario == "projection-storage" ? "local_storage_failed" : "projection_unsupported"))
            try a.fleet.recordDeliveryProblem(staff.id, error: RemoteHostLinkError.remoteError(reason))
            let warnings = try DeviceFleetStore.deliveryWarnings(roster: a.fleet.current()?.roster, problems: a.fleet.read().deliveryProblems ?? [:]).values.sorted()
            try check("CARDS-03-only-compatibility-needs-update", warnings.contains { $0.contains("更新") } == (scenario != "projection-storage"))
        case "row-warnings":
            let snapshot = try DeviceFleetUISnapshot(payload: a.fleet.current(), localID: a.id, deliveryProblems: [b.id: "projection_refused"])
            try check("UI-01-warning-only-at-corresponding-row", snapshot.deliveryWarnings[b.id] != nil && snapshot.pendingDeliveryLines.isEmpty)
        case "memory-full-fetch":
            let p = EngineMemoryPaths(home: a.dispatch.root.appendingPathComponent("home").path, entryRoot: a.dispatch.entry.root)
            let q = EngineMemoryPaths(home: b.dispatch.root.appendingPathComponent("home").path, entryRoot: b.dispatch.entry.root)
            for paths in [p, q] {
                try EngineMemoryLinks.createMemoryFolder(paths.memory)
                try TatwoMemorySyncAcceptance.note(paths.memory, "synthetic.md", title: "Synthetic", body: "Synthetic memory.")
                _ = EngineMemoryLinks.commit(paths.memory, message: "synthetic")
            }
            let primary = TatwoMemorySyncEngine(paths: { p }, dispatch: a.dispatch)
            let bridge = OSAgentBridge.fleetFixtureBridge(); bridge.fixtureMemory(primary)
            let channel = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, rpc: { _, method, params in
                let reply = try bridge.fixtureHandle(dispatch: a.dispatch, method: method, params: params)
                guard reply["ok"] as? Bool == true else { throw DeviceFleetError.malformed }
                return reply["result"] as! [String: Any]
            })
            let secondary = TatwoMemorySyncEngine(paths: { q }, dispatch: channel)
            var fetches = 0
            secondary.fixtureFetchGit = { arguments, environment in
                fetches += 1
                guard arguments.contains("fetch"), environment["GIT_SSH_COMMAND"]?.contains("StrictHostKeyChecking=yes") == true else { return (-1, "invalid fixture pin") }
                return (128, "ssh: connect to host 192.0.2.111 port 22: Connection refused\n")
            }
            try check("R7-MEM-02-real-full-channel-fetch-sleep-is-offline", secondary.runOnce(.manual).state == .offline && fetches > 0)
            secondary.fixtureFetchGit = { _, _ in (128, "Permission denied (publickey).\n") }
            try check("R7-MEM-02-auth-denial-is-not-offline", secondary.runOnce(.manual).state == .failed)
        case "memory-push":
            let paths = EngineMemoryPaths(home: a.dispatch.root.appendingPathComponent("home").path, entryRoot: a.dispatch.entry.root)
            try EngineMemoryLinks.createMemoryFolder(paths.memory)
            try TatwoMemorySyncAcceptance.note(paths.memory, "primary.md", title: "Synthetic", body: "Synthetic memory.")
            _ = EngineMemoryLinks.commit(paths.memory, message: "synthetic")
            let engine = TatwoMemorySyncEngine(paths: { paths }, dispatch: a.dispatch)
            do {
                _ = try engine.handle(method: "memory_sync_import", payload: ["bundle": "not-a-bundle", "commit": String(repeating: "a", count: 40), "ref": TatwoMemorySyncEngine.inboxRef(b.id)], sender: b.id)
                throw DeviceFleetError.signature
            } catch {
                try check("MEM-01-primary-import-preserves-original-code", TatwoMemorySyncEngine.raw(error) == "invalid_memory_bundle")
                let line = TatwoMemorySyncStatus(state: .failed, error: TatwoMemorySyncEngine.short(error, pushing: true)).line
                try check("MEM-01-real-import-refusal-push-direction", line == "同步沒成功：主設備拒收：這台送來的記憶驗不過，這輪先不送・下一輪再試")
            }
        case "memory-errors":
            let status = TatwoMemorySyncStatus(state: .failed, error: TatwoMemorySyncEngine.short(DeviceFleetGate.CallError.rejected("fixture_unknown")))
            try check("MEM-02-no-duplicate-prefix", status.line == "同步沒成功：原因不明・下一輪再試")
            try check("MEM-02-gate-method-refusal-update-action", TatwoMemorySyncEngine.short(DeviceFleetGate.CallError.refused).contains("還沒更新"))
            try check("R10-MEM-01-untrusted-sender-requires-repairing", TatwoMemorySyncEngine.short(DeviceDispatch.Failure(reason: "untrusted_rpc_sender")).contains("重新配對"))
            try check("MEM-02-capability-denial-action", TatwoMemorySyncEngine.short(DeviceFleetError.capabilityDenied).contains("記憶權限"))
        case "stop-tracking":
            try a.fleet.revoke(b.id)
            _ = try a.fleet.claimRevocationDelivery(b.id)
            try a.fleet.recordDeliveryProblem(b.id, error: DeviceFleetGate.CallError.unreachable)
            try DispatchQueue.main.sync {
                let session = DeviceFlowSession(environment: a.env)
                let thread = UUID()
                let version = try a.fleet.current()!.revision
                let reply = try AssistantFleetTools.perform("fleet_propose", params: ["baseVersion": version, "changes": [["op": "stop_tracking", "target": "d2"]]], caller: .engine(thread), assistantThread: thread, session: session)
                try check("R7-CARDS-05-stop-tracking-requires-confirmation", reply["confirmed"] as? Bool == false && a.fleet.read().deliveryProblems?[b.id] == "revocation_pending")
                _ = try session.store.confirm(session.pending!.id, userConfirmed: true)
            }
            try check("R7-CARDS-05-stop-tracking-keeps-tombstone", a.fleet.current()!.roster!.revoked.contains(b.id) && !a.fleet.claimRevocationDelivery(b.id, now: Date().addingTimeInterval(99_999)))
            try check("R7-CARDS-05-stop-tracking-hides-warning", a.fleet.read().deliveryProblems?[b.id] == nil)
        case "revocation-pending":
            try a.fleet.revoke(b.id)
            try check("R7-CARDS-05-claim-does-not-warn-before-send", a.fleet.claimRevocationDelivery(b.id) && a.fleet.read().deliveryProblems?[b.id] != "revocation_pending")
            try a.fleet.recordDeliveryProblem(b.id, error: DeviceFleetGate.CallError.unreachable)
            try check("R7-CARDS-05-failed-send-actionable", DeviceFleetStore.deliveryWarnings(roster: a.fleet.current()?.roster, problems: a.fleet.read().deliveryProblems ?? [:]).values.sorted().contains { $0.contains("不再追蹤這台") })
        default: throw DeviceFleetError.malformed
        }
        print("W187R8 SUMMARY failures=0")
    }
}
#endif
