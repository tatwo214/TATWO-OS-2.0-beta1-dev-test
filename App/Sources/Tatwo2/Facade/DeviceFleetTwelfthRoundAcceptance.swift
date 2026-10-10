#if DEBUG
import Darwin
import Foundation
import SwiftUI

enum DeviceFleetTwelfthRoundAcceptance {
    static func run(scenario: String, a: DeviceFleetAcceptance.Fake, b: DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R12_FAIL_" + name) }
            print("W187R12 PASS " + name)
        }
        try a.fleet.bootstrapPrimary(host: a.host)
        let managed = !scenario.hasPrefix("r12-dialog") && !scenario.hasPrefix("r12-ui")
        if managed { try a.fleet.setFaction(.init(id: "r12-staff", name: "Synthetic staff", kind: .managed, managerDisplayName: "Synthetic manager")) }
        try pair(a, b, managed ? .managed : .owner, managed ? "r12-staff" : nil, managed)
        b.dispatch.synchronize()
        if scenario.hasPrefix("r12-dialog") {
            let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            Task { @MainActor in
                defer { done.signal() }
                let session = DeviceFlowSession(environment: a.env, pasteboard: NSPasteboard(name: .init(UUID().uuidString)), rpc: { _, _, _ in
                    if scenario.hasSuffix("offline") { throw DeviceFleetGate.CallError.unreachable }
                    if scenario.hasSuffix("rejected") { throw DeviceFleetGate.CallError.rejected("fleet_role") }
                    throw DeviceFleetGate.CallError.appUnavailable
                })
                defer { session.close() }
                do {
                    try session.open(.transfer); await session.refresh()
                    session.transferTarget = b.id; session.signingName = "fixture release"
                    await session.transferFromLocalDialog(.fixture(binding: session.cardBinding))
                    try check("SEQ-01-dialog-Chinese-" + scenario, session.message.contains("新主設備") && !session.message.contains("fleet_"))
                    let raw = scenario.hasSuffix("offline") ? DeviceFleetGate.CallError.unreachable.reason : scenario.hasSuffix("rejected") ? "fleet_role" : DeviceFleetGate.CallError.appUnavailable.reason
                    let audit = try String(contentsOf: a.fleet.logURL, encoding: .utf8)
                    try check("SEQ-01-original-code-written-to-audit", audit.contains(" " + raw + "\n"))
                    let text = try await DeviceFleetEleventhRoundAcceptance.render(DeviceFlowCard(session: session), artifact: scenario)
                    try check("SEQ-01-card-visible-Chinese", text.contains("新主設備") && !text.contains("fleet_"))
                } catch { errors.fail(error) }
            }
            guard done.wait(timeout: .now() + 60) == .success else { throw DeviceDispatch.Failure(reason: "W187R12_TIMEOUT_dialog_render") }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        } else if scenario.hasPrefix("r12-ui") {
            let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            Task { @MainActor in
                defer { done.signal() }
                do {
                    var local = try a.dispatch.identity()
                    var record = PrimaryTransfer.Record(from: a.id, to: b.id, oldEpoch: 1, epoch: 2, participants: [b.id], sourceDeviceID: a.id, sourceRoot: a.dispatch.entry.root.path, hashes: try a.dispatch.snapshot().mapValues(DeviceDispatch.hash), signingName: "")
                    local.transfer = record
                    if scenario.hasSuffix("status") {
                        let text = try await DeviceFleetEleventhRoundAcceptance.render(PrimaryTransferStatusView(record: record), artifact: "r12-unchecked")
                        try check("SEQ-03-unchecked-name-hidden", !text.contains("比對名稱"))
                    }
                    if scenario.hasSuffix("field") {
                        _ = try await DeviceFleetEleventhRoundAcceptance.render(DeviceFlowTransferPanel(preview: local), artifact: "r12-preparing")
                        let host = NSHostingView(rootView: DeviceFlowTransferPanel(preview: local).frame(width: 1000, height: 1100))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
                        window.contentView = host
                        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
                        func editable(_ view: NSView) -> Bool { (view as? NSTextField)?.isEditable == true || view.subviews.contains(where: editable) }
                        try check("SEQ-03-release-field-hidden-until-enabled", !editable(host))
                    }
                    if scenario.hasSuffix("card") {
                        try DeviceIdentityStore.forLocalDevice(entry: a.dispatch.entry, pairedDeviceID: a.id).write(local)
                        let session = DeviceFlowSession(environment: a.env, pasteboard: NSPasteboard(name: .init(UUID().uuidString)))
                        defer { session.close() }
                        try session.open(.transfer); await session.refresh()
                        let text = try await DeviceFleetEleventhRoundAcceptance.render(DeviceFlowCard(session: session), artifact: "r12-coordinator-card")
                        try check("SEQ-03-coordinator-start-hidden", !text.contains("與現任主设备相同") && !text.contains("與現任主設備相同"))
                    }
                    if scenario.hasSuffix("retired") {
                        local.role = .secondary; local.primaryDeviceID = b.id
                        record.committed = true; record.epochACKs = [b.id]; record.constitution = true; record.sourceDeviceID = b.id
                        record.brain = .migrated; record.brainVerified = true; record.releaseChecked = true; record.release = .ready
                        record.constitutionRevision = 1; record.brainRevision = 1; record.releaseRevision = 1
                        record.acknowledgedRevision = record.revision; local.transfer = record
                        let text = try await DeviceFleetEleventhRoundAcceptance.render(DeviceFlowTransferPanel(preview: local, previewCoordinatorRetired: true), artifact: "r12-retired-complete")
                        try check("SEQ-02-retired-complete-needs-no-action", text.contains("這台不需要操作"))
                    }
                } catch { errors.fail(error) }
            }
            guard done.wait(timeout: .now() + 40) == .success else { throw DeviceFleetError.malformed }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        } else if scenario.hasPrefix("r12-entry-") {
            var env = b.env
            let socket = ProcessInfo.processInfo.environment["TATWO2_W187_AGENT_SOCKET"]!
            env["SSH_AUTH_SOCK"] = ProcessInfo.processInfo.environment["TATWO2_W187_POLICY_AGENT"] ?? socket
            setenv("SSH_AUTH_SOCK", env["SSH_AUTH_SOCK"]!, 1)
            defer { unsetenv("SSH_AUTH_SOCK") }
            let policy = ManagedEnginePolicy(thread: UUID(), environment: env)
            let cwd = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            let script = URL(fileURLWithPath: cwd).appendingPathComponent("probe.mjs")
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: [socket]), as: UTF8.self)
            let js = "import net from 'node:net';import fs from 'node:fs';let s=net.createConnection(" + encoded + "[0]);s.on('connect',()=>{fs.writeFileSync('probe.json',JSON.stringify({blocked:false,env:process.env.SSH_AUTH_SOCK??null}));process.exit(0)});s.on('error',e=>{fs.writeFileSync('probe.json',JSON.stringify({blocked:['EPERM','EACCES'].includes(e.code),env:process.env.SSH_AUTH_SOCK??null}));process.exit(0)});"
            try Data(js.utf8).write(to: script)
            let node = ProcessInfo.processInfo.environment["TATWO2_W187_NODE"]!
            if scenario.hasSuffix("background") {
                let manager = BackgroundJobManager(root: b.dispatch.root.appendingPathComponent("r12-jobs"))
                defer { manager.stopAll() }
                let job = try manager.run(command: "'" + node + "' '" + script.path + "'", cwd: cwd, title: "synthetic", threadID: policy.thread, memoryPolicy: policy)
                for _ in 0..<500 where manager.status(jobID: job.jobID)?.state == "running" { usleep(10_000) }
            } else if scenario.hasSuffix("engine") {
                let overrides = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                UserDefaults.standard.setVolatileDomain(overrides.merging(["tatwo2.sidecarPath.codex": script.path]) { _, new in new }, forName: UserDefaults.argumentDomain)
                defer { UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain) }
                let sidecar = ClaudeSidecar(kind: .codex)
                defer { sidecar.terminate() }
                try sidecar.start(cwd: cwd, resume: nil, model: nil, memoryPolicy: policy)
                for _ in 0..<500 where !FileManager.default.fileExists(atPath: cwd + "/probe.json") { usleep(10_000) }
            } else {
                var launch = try DispatchQueue.main.sync {
                    let live = ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("r12-chat")), environment: b.env)
                    let model = ChatPageModel(environment: b.env, botCoreFixture: (live, BotStore(root: b.dispatch.root.appendingPathComponent("r12-bots"))))
                    return try model.launchForCLI(engine: .generic, workdir: cwd, memoryPolicy: policy)
                }
                launch.arguments += ["-c", "'" + node + "' '" + script.path + "'"]
                let child = Process(); child.executableURL = URL(fileURLWithPath: launch.executable); child.arguments = launch.arguments
                child.environment = launch.environment; child.currentDirectoryURL = launch.workingDirectory
                child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                try child.run(); child.waitUntilExit()
            }
            let result = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cwd + "/probe.json"))) as! [String: Any]
            try check("CARDS-N2-actual-entry-blocks-agent-" + scenario, result["blocked"] as? Bool == true && result["env"] is NSNull)
        } else if scenario == "r12-errors" {
            for (error, raw) in [(DeviceDispatch.Failure(reason: "synthetic_unknown_failure") as Error, "synthetic_unknown_failure"),
                                 (DeviceFleetGate.CallError.appUnavailable as Error, "fleet_app_rpc_unavailable"),
                                 (DeviceFleetError.role as Error, "fleet_role")] {
                try check("SEQ-01-all-error-types-share-Chinese", error.localizedDescription.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } && !error.localizedDescription.contains(raw))
                try check("SEQ-01-raw-code-preserved-for-audit", DeviceFleetReason.code(error) == raw)
            }
            for error in [DeviceFleetError.capabilityDenied as Error, DeviceFleetGate.CallError.refused as Error] {
                try check("SEQ-01-memory-wording-only-for-memory", !DeviceFleetReason.plain(error).contains("記憶") && TatwoMemorySyncEngine.short(error).contains("記憶"))
            }
        } else if scenario == "r12-cli-error" {
            try DispatchQueue.main.sync {
                let live = ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("r12-chat")), environment: b.env)
                let model = ChatPageModel(environment: b.env.merging(["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT": "r12"]) { _, new in new }, botCoreFixture: (live, BotStore(root: b.dispatch.root.appendingPathComponent("r12-bots"))))
                let thread = live.newThread(in: nil, title: "synthetic")
                live.markControllerThread(thread, fingerprint: try DeviceRegistry.fingerprint(publicKey: a.clientKey))
                model.selectedThreadID = thread
                try Data("invalid synthetic fleet".utf8).write(to: b.fleet.url)
                try check("CARDS-N4-CLI-admission-refused", model.openCLITab(engine: .generic, callerThreadID: thread) == nil)
                try check("CARDS-N4-CLI-error-Chinese", model.composerHint?.contains("App") == true && model.composerHint?.contains("fleet_") == false)
            }
        } else if scenario == "r12-admission" {
            let checks = DeviceFleetFourthRoundAcceptance.Results()
            DeviceFleetEnvelope.fixtureVerification = { checks.append(1) }
            defer { DeviceFleetEnvelope.fixtureVerification = nil }
            _ = try b.fleet.pendingConsent()
            try check("CARDS-N5-consent-verifies-once", checks.sequences.count == 1)
        } else if scenario == "r12-sandbox" {
            var env = b.env
            env["SSH_AUTH_SOCK"] = b.dispatch.root.deletingLastPathComponent().appendingPathComponent("fake-agent.sock").path
            let policy = ManagedEnginePolicy(thread: UUID(), environment: env)
            let cwd = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            let plan: [String: Any] = ["arguments": policy.sandboxArguments(executable: "/usr/bin/true", arguments: [], writableDirectory: cwd),
                "environment": try policy.prepareEnvironment(ProcessInfo.processInfo.environment.merging(["SSH_AUTH_SOCK": env["SSH_AUTH_SOCK"]!]) { _, new in new }),
                "cwd": cwd, "socket": env["SSH_AUTH_SOCK"]!]
            try JSONSerialization.data(withJSONObject: plan).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!).appendingPathComponent("r12-plan.json"))
        } else if scenario == "r12-git" {
            let work = b.dispatch.root.deletingLastPathComponent().appendingPathComponent("project").path
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let marker = work + "/EXECUTED", helper = work + "/monitor.sh"
            try Data("#!/bin/sh\nprintf executed > '\(marker)'\n".utf8).write(to: URL(fileURLWithPath: helper))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper)
            for args in [["init", work], ["-C", work, "-c", "user.name=fixture", "-c", "user.email=fixture@localhost", "commit", "--allow-empty", "-m", "fixture"], ["-C", work, "config", "core.fsmonitor", helper]] {
                try check("CARDS-N1-fixture-git", DeviceDispatch.run("/usr/bin/git", args).0 == 0)
            }
            let policy = ManagedEnginePolicy(thread: UUID(), environment: b.env)
            let manager = BackgroundJobManager(root: b.dispatch.root.appendingPathComponent("r12-git-jobs"))
            defer { manager.stopAll() }
            let job = try manager.run(command: "/usr/bin/git config core.fsmonitor '" + helper + "'", cwd: work, title: "synthetic git attack", threadID: policy.thread, memoryPolicy: policy)
            for _ in 0..<500 where manager.status(jobID: job.jobID)?.state == "running" { usleep(10_000) }
            try check("CARDS-N1-managed-dispatch-cannot-configure-git", manager.status(jobID: job.jobID)?.exitCode != 0)
            let live = DispatchQueue.main.sync { ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("r12-chat")), environment: b.env) }
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.sync {
                let project = live.newProject(name: "fixture", workdir: work)
                let thread = live.newThread(in: project, title: "managed")
                live.markControllerThread(thread, fingerprint: try! DeviceRegistry.fingerprint(publicKey: a.clientKey))
                live.gitSummary(for: thread) { _ in done.signal() }
            }
            guard done.wait(timeout: .now() + 20) == .success else { throw DeviceFleetError.malformed }
            try check("CARDS-N1-host-summary-does-not-execute-config", !FileManager.default.fileExists(atPath: marker))
            _ = HandsGit.hostRead(["status", "--porcelain"], cwd: work)
            try check("CARDS-N1-artifacts-do-not-execute-config", !FileManager.default.fileExists(atPath: marker))
            _ = try ChatPageModel.prepareRoomWorktree(workdir: work, roomID: UUID().uuidString)
            try check("CARDS-N1-room-git-does-not-execute-config", !FileManager.default.fileExists(atPath: marker))
        } else if scenario == "r12-cwd" {
            let actual = b.dispatch.root.deletingLastPathComponent().appendingPathComponent("linked-live")
            try FileManager.default.createSymbolicLink(at: actual, withDestinationURL: URL(fileURLWithPath: b.env["TATWO2_LIVE_ROOT"]!))
            var env = b.env; env["TATWO2_LIVE_ROOT"] = actual.path
            let policy = ManagedEnginePolicy(thread: UUID(), environment: env)
            let base = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            try check("CARDS-N3-isolation-is-canonical", base == HandsPath.canonical(base))
            let manager = BackgroundJobManager(root: b.dispatch.root.appendingPathComponent("r12-cwd-jobs"))
            let bridge = OSAgentBridge.fleetFixtureBridge()
            let (model, owner) = try DispatchQueue.main.sync { () throws -> (ChatPageModel, UUID) in
                let live = ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("r12-cwd-chat")), environment: env)
                let model = ChatPageModel(environment: env, botCoreFixture: (live, BotStore(root: b.dispatch.root.appendingPathComponent("r12-cwd-bots"))))
                let owner = live.newThread(in: nil, title: "synthetic managed")
                live.markControllerThread(owner, fingerprint: try DeviceRegistry.fingerprint(publicKey: a.clientKey))
                bridge.configureCallerTest(model: model, manager: manager)
                return (model, owner)
            }
            defer { manager.stopAll(); DispatchQueue.main.sync { model.live?.shutdownAll() } }
            bridge.backgroundCommandApprover = { _, _, _ in true }
            let response = try bridge.fixtureHandle(dispatch: b.dispatch, method: "run_background", params: ["cmd": "printf synthetic > result.txt"], caller: .engine(owner))
            guard let job = UUID(uuidString: (response["result"] as? [String: Any])?["jobID"] as? String ?? "") else { throw DeviceDispatch.Failure(reason: "W187R12_FAIL_CARDS-N3-linked-root-background-refused: " + String(describing: response)) }
            for _ in 0..<500 where manager.status(jobID: job)?.state == "running" { usleep(10_000) }
            try check("CARDS-N3-linked-root-background-works", manager.status(jobID: job)?.exitCode == 0)

        }
        print("W187R12 SUMMARY failures=0")
    }
}
#endif
