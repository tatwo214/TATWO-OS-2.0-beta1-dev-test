#if DEBUG
import AppKit
import Darwin
import Foundation
import SwiftUI

enum DeviceFleetThirteenthRoundAcceptance {
    static func run(scenario: String, a: DeviceFleetAcceptance.Fake, b: DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R13_FAIL_" + name) }
            print("W187R13 PASS " + name)
        }
        if scenario == "r13-reclaim" {
            let repo = a.dispatch.root.appendingPathComponent("large-repo").path
            try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
            _ = try HandsGit.checked(["init", "-q"], cwd: repo)
            _ = try HandsGit.checked(["commit", "--allow-empty", "-m", "fixture"], cwd: repo, extraEnvironment: HandsGit.identity)
            let id = UUID(), path = try ChatPageModel.prepareRoomWorktree(workdir: repo, roomID: id.uuidString)
            for index in 0..<5000 {
                try Data("synthetic".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent(String(index) + String(repeating: "x", count: 235)))
            }
            let status = try HandsGit.run(["status", "--porcelain", "--untracked-files=all"], cwd: path, cap: 2 * 1024 * 1024)
            try check("CARDS-05-fixture-status-exceeds-one-MB", status.out.utf8.count > 1024 * 1024)
            let (model, room) = try DispatchQueue.main.sync { () throws -> (ChatPageModel, UUID) in
                let live = ChatLiveEngine(store: ChatLiveStore(root: a.dispatch.root.appendingPathComponent("reclaim-chat")), environment: a.env)
                let model = ChatPageModel(environment: a.env, botCoreFixture: (live, BotStore(root: a.dispatch.root.appendingPathComponent("reclaim-bots"))))
                guard let project = model.acceptanceNewProject(name: "fixture", workdir: repo) else { throw DeviceFleetError.malformed }
                let parent = live.newThread(in: project, title: "fixture parent"), room = live.newThread(in: project, title: "fixture room")
                live.configureRoom(threadID: room, parentThreadID: parent, roomBrief: "synthetic", engine: "codex", cwdOverride: path, deviceID: nil)
                return (model, room)
            }
            let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            let tick = HandsLocked(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { tick.set(true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 40) { if done.wait(timeout: .now()) != .success { print("W187R13 FAIL CARDS-05-reclaim-timeout"); exit(1) } }
            Task { @MainActor in
                defer { model.live?.shutdownAll(); done.signal() }
                do {
                    let start = Date()
                    do { _ = try await model.reclaimRoom(room); throw DeviceFleetError.signature }
                    catch {
                        try check("CARDS-05-bounded-output-refusal", String(describing: error).contains("limit"))
                    }
                    try check("CARDS-05-main-remains-responsive", tick.get())
                    try check("CARDS-05-reports-within-timeout-and-preserves-files", Date().timeIntervalSince(start) < 35 && FileManager.default.fileExists(atPath: path + "/0" + String(repeating: "x", count: 235)))
                } catch { errors.fail(error) }
            }
            guard done.wait(timeout: .now() + 39) == .success else { throw DeviceDispatch.Failure(reason: "W187R13_FAIL_CARDS-05-reclaim-timeout") }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        } else if scenario == "r13-button" {
            var local = try a.dispatch.identity()
            var record = PrimaryTransfer.Record(from: a.id, to: b.id, oldEpoch: 1, epoch: 2, participants: [b.id], sourceDeviceID: a.id, sourceRoot: a.dispatch.entry.root.path, hashes: [:], signingName: "fixture release")
            record.committed = true; record.epochACKs = [b.id]
            local.role = .secondary; local.epoch = 2; local.primaryDeviceID = b.id; local.transfer = record
            let preview = local, done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            Task { @MainActor in
                defer { done.signal() }
                do {
                    let host = NSHostingView(rootView: DeviceFlowTransferPanel(preview: preview).frame(width: 1000, height: 1100))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
                    func titles(_ view: NSView) -> [String] { (view as? DeviceFlowPhysicalButton.Native).map { [$0.title] } ?? view.subviews.flatMap(titles) }
                    try check("SEQ-04-button-names-frozen-originals", titles(host).contains("② 比對凍結的正本並切換正本派發來源"))
                } catch { errors.fail(error) }
            }
            guard done.wait(timeout: .now() + 30) == .success else { throw DeviceFleetError.malformed }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        } else if scenario == "r13-blank-name" {
            try a.fleet.bootstrapPrimary(host: a.host)
            try pair(a, b, .owner, nil, false)
            let calls = DeviceFleetFourthRoundAcceptance.Results()
            let broken = DeviceDispatch(entry: a.dispatch.entry, registry: a.registry, environment: a.env, retireBackup: { _ in }, rpc: { _, _, _ in
                calls.append(1); throw DeviceFleetGate.CallError.appUnavailable
            })
            do { try broken.beginTransfer(to: b.id, signingName: " \n "); throw DeviceFleetError.signature }
            catch { try check("ROSTER-03-begin-rejects-blank-before-probing", error.localizedDescription.contains("簽章身分名稱") && calls.sequences.isEmpty) }
            let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            Task { @MainActor in
                defer { done.signal() }
                let session = DeviceFlowSession(environment: a.env, pasteboard: NSPasteboard(name: .init(UUID().uuidString)), rpc: { _, _, _ in calls.append(1); throw DeviceFleetGate.CallError.appUnavailable })
                defer { session.close() }
                do {
                    try session.open(.transfer); await session.refresh()
                    session.transferTarget = b.id; session.signingName = " "
                    await session.transferFromLocalDialog(.fixture(binding: session.cardBinding))
                    try check("ROSTER-03-dialog-rejects-blank-before-probing", session.message.contains("簽章身分名稱") && calls.sequences.isEmpty)
                } catch { errors.fail(error) }
            }
            guard done.wait(timeout: .now() + 20) == .success else { throw DeviceFleetError.malformed }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        } else if scenario == "r13-shell" {
            let policy = ManagedEnginePolicy(thread: UUID(), environment: b.env)
            let cwd = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            var launch = try DispatchQueue.main.sync {
                let live = ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("shell-chat")), environment: b.env)
                let model = ChatPageModel(environment: b.env, botCoreFixture: (live, BotStore(root: b.dispatch.root.appendingPathComponent("shell-bots"))))
                return try model.launchForCLI(engine: .generic, workdir: cwd, memoryPolicy: policy)
            }
            launch.arguments += ["-c", "printf '%s' \"${SSH_AUTH_SOCK-unset}:${TMUX-unset}:${TMUX_PANE-unset}\" > env.txt"]
            let runtime = CLITmuxRuntime(root: a.dispatch.root.appendingPathComponent("synthetic-tmux"), executable: ProcessInfo.processInfo.environment["TATWO2_RUNTIME_BIN"]! + "/tmux")
            let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            Task {
                do {
                    try await runtime.create(id: UUID(), launch: launch)
                    for _ in 0..<100 where !FileManager.default.fileExists(atPath: cwd + "/env.txt") { try await Task.sleep(for: .milliseconds(50)) }
                    let text = try String(contentsOfFile: cwd + "/env.txt", encoding: .utf8)
                    try check("CARDS-01-real-tmux-removes-agent-and-relay-variables", text == "unset:unset:unset")
                } catch { errors.fail(error) }
                _ = try? await runtime.run(["kill-server"])
                done.signal()
            }
            guard done.wait(timeout: .now() + 30) == .success else { throw DeviceFleetError.malformed }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        } else if scenario == "r13-external-dispatch" {
            let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            Task { @MainActor in
                defer { done.signal() }
                let live = ChatLiveEngine(store: ChatLiveStore(root: a.dispatch.root.appendingPathComponent("external-chat")), environment: a.env)
                defer { live.shutdownAll(); ExternalWorkspacePolicy.extraEntriesForTesting.set([]); ClaudeSidecar.fixtureLaunch = nil }
                do {
                    ExternalWorkspacePolicy.extraEntriesForTesting.set([a.dispatch.entry.root.path])
                    let cwd = a.dispatch.entry.root.appendingPathComponent("chatgpt/project").path
                    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
                    let model = ChatPageModel(environment: a.env, botCoreFixture: (live, BotStore(root: a.dispatch.root.appendingPathComponent("external-bots"))))
                    guard let project = model.acceptanceNewProject(name: "fixture", workdir: cwd) else { throw DeviceFleetError.malformed }
                    let parent = live.newThread(in: project, title: "fixture")
                    var launched = false; ClaudeSidecar.fixtureLaunch = { _, _, _, _ in launched = true }
                    do { _ = try await model.dispatchChecked(rooms: [.init(title: "fixture", engine: "codex", model: nil, brief: "synthetic")], parent: parent); throw DeviceFleetError.signature }
                    catch { try check("W183-external-workspace-dispatch-refused-before-worktree", String(describing: error).contains(ExternalWorkspacePolicy.engineRefusal) && !launched && !FileManager.default.fileExists(atPath: cwd + "/.tatwo2")) }
                } catch { errors.fail(error) }
            }
            guard done.wait(timeout: .now() + 20) == .success else { throw DeviceFleetError.malformed }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        } else if scenario == "r13-validate-files" {
            let data = Data("synthetic".utf8)
            for path in ["os.md", "skillet.md", "note/nested/fixture.md"] + DeviceDispatch.optionalFiles { try DeviceDispatch.validateFiles([path: data]) }
            for path in ["chatgpt/private.txt", "memory/private.txt", ".git/config", "../os.md", "note/../../os.md"] {
                do { try DeviceDispatch.validateFiles([path: data]); throw DeviceFleetError.signature }
                catch { try check("W183-dispatch-path-refused-" + path.replacingOccurrences(of: "/", with: "_"), (error as? DeviceFleetError) != .signature) }
            }
        } else if scenario == "r13-audit" {
            try a.fleet.bootstrapPrimary(host: a.host)
            try pair(a, b, .owner, nil, false)
            let broken = DeviceDispatch(entry: a.dispatch.entry, registry: a.registry, environment: a.env, retireBackup: { _ in }, rpc: { _, _, _ in
                throw DeviceDispatch.Failure(reason: "無法讀取 /private/synthetic-secret-path/fixture")
            })
            do { try broken.beginTransfer(to: b.id, signingName: "fixture release"); throw DeviceFleetError.signature } catch {}
            let log = try String(contentsOf: a.fleet.logURL, encoding: .utf8)
            try check("SEQ-03-audit-fixed-code-no-local-path", log.contains("fleet_transfer_begin_refused") && !log.contains("synthetic-secret-path"))
        } else if scenario == "r13-managed-git" {
            let policy = ManagedEnginePolicy(thread: UUID(), environment: b.env)
            let cwd = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            let result = try DeviceDispatch.run("/usr/bin/sandbox-exec", policy.sandboxArguments(executable: "/usr/bin/git", arguments: ["init", "nested"], writableDirectory: cwd), directory: URL(fileURLWithPath: cwd))
            try check("CARDS-02-git-init-refused", result.0 != 0 && !FileManager.default.fileExists(atPath: cwd + "/nested/.git"))
            try check("CARDS-02-permission-explains-enforcement", DeviceFleetCapabilities.methodDescriptions["run_background"]?.contains("受管工作不能 commit、clone 或建立 git 版本庫") == true)
        } else if scenario == "r13-summary" {
            let repo = a.dispatch.root.appendingPathComponent("summary-repo").path
            try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
            _ = try HandsGit.checked(["init", "-q"], cwd: repo)
            _ = try HandsGit.checked(["commit", "--allow-empty", "-m", "fixture"], cwd: repo, extraEnvironment: HandsGit.identity)
            let home = ProcessInfo.processInfo.environment["HOME"]!
            try Data("global-ignored.txt\n".utf8).write(to: URL(fileURLWithPath: home + "/synthetic-ignore"))
            try Data(("[core]\n excludesFile = " + home + "/synthetic-ignore\n").utf8).write(to: URL(fileURLWithPath: home + "/.gitconfig"))
            try Data("fixture".utf8).write(to: URL(fileURLWithPath: repo + "/global-ignored.txt"))
            let unreadable = URL(fileURLWithPath: repo + "/unreadable")
            try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: unreadable.appendingPathComponent("hidden.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
            let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            DispatchQueue.main.async {
                let live = ChatLiveEngine(store: ChatLiveStore(root: a.dispatch.root.appendingPathComponent("summary-chat")), environment: a.env)
                let id = live.newThread(in: nil, title: "synthetic")
                live.configureRoom(threadID: id, parentThreadID: UUID(), roomBrief: "synthetic", engine: "codex", cwdOverride: repo, deviceID: nil)
                live.gitSummary(for: id) { summary in
                    defer { live.shutdownAll(); done.signal() }
                    do {
                        try check("CARDS-03-normal-summary-respects-global-ignore", !summary.files.joined(separator: "\n").contains("global-ignored.txt"))
                        try check("CARDS-03-stderr-is-not-a-file", !summary.files.contains { $0.contains("warning") || $0.contains("could not open") })
                    } catch { errors.fail(error) }
                }
            }
            guard done.wait(timeout: .now() + 30) == .success else { throw DeviceFleetError.malformed }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        } else if scenario == "r13-refusal" {
            try a.fleet.bootstrapPrimary(host: a.host)
            try a.fleet.setFaction(.init(id: "r13-staff", name: "fixture", kind: .managed, managerDisplayName: "fixture"))
            try pair(a, b, .managed, "r13-staff", true)
            try DispatchQueue.main.sync {
                let live = ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("refusal-chat")), environment: b.env)
                let model = ChatPageModel(environment: b.env.merging(["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT": "r13"]) { _, new in new }, botCoreFixture: (live, BotStore(root: b.dispatch.root.appendingPathComponent("refusal-bots"))))
                defer { live.shutdownAll() }
                let id = live.newThread(in: nil, title: "synthetic")
                live.markControllerThread(id, fingerprint: try DeviceRegistry.fingerprint(publicKey: a.clientKey))
                model.selectedThreadID = id
                try Data("invalid synthetic fleet".utf8).write(to: b.fleet.url)
                try check("CARDS-04-cli-refuses", model.openCLITab(engine: .generic, callerThreadID: id) == nil)
                let cli = model.composerHint ?? ""
                _ = live.send(threadID: id, text: "synthetic", model: nil, engine: .codex)
                try check("CARDS-04-two-entry-same-local-error", live.transcript(for: id).last?.text == cli && cli.contains("設備頁"))
            }
        }
        print("W187R13 SUMMARY failures=0")
    }
}
#endif
