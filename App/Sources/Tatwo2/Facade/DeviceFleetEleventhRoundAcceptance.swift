#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Vision

enum DeviceFleetEleventhRoundAcceptance {
    static func run(scenario: String, a: DeviceFleetAcceptance.Fake, b: DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R11_FAIL_" + name) }
            print("W187R11 PASS " + name)
        }
        try a.fleet.bootstrapPrimary(host: a.host)
        let owned = ["r11-dialog", "r11-empty-card", "r11-memory-race", "r11-return"].contains(scenario)
        if !owned { try a.fleet.setFaction(.init(id: "r11-staff", name: "Synthetic staff", kind: .managed, managerDisplayName: "Synthetic manager")) }
        try pair(a, b, owned ? .owner : .managed, owned ? nil : "r11-staff", !owned)
        b.dispatch.synchronize()
        if ["r11-dialog", "r11-invalid-target", "r11-empty-card", "r11-return"].contains(scenario) {
            let done = DispatchSemaphore(value: 0)
            let errors = DeviceFleetFourthRoundAcceptance.Results()
            Task { @MainActor in
                defer { done.signal() }
                let session = DeviceFlowSession(environment: a.env, pasteboard: NSPasteboard(name: .init(UUID().uuidString)), rpc: { _, _, _ in
                    try DeviceDispatch.object(DeviceDispatch.FleetPresence(deviceID: b.id, role: .secondary, epoch: 1, primaryDeviceID: a.id))
                })
                defer { session.close() }
                do {
                    if scenario == "r11-return" {
                        try a.fleet.revoke(b.id)
                        var local = try a.dispatch.identity()
                        var record = PrimaryTransfer.Record(from: b.id, to: a.id, oldEpoch: 0, epoch: 1, participants: [a.id], sourceDeviceID: a.id, sourceRoot: a.dispatch.entry.root.path, hashes: try a.dispatch.snapshot().mapValues(DeviceDispatch.hash), sourcePages: 42, signingName: "fixture release")
                        record.committed = true; record.epochACKs = [a.id]; record.constitution = true; record.constitutionRevision = 1; record.acknowledgedRevision = 1
                        local.transfer = record
                        try DeviceIdentityStore.forLocalDevice(entry: a.dispatch.entry, pairedDeviceID: a.id).write(local)
                    }
                    try session.open(.transfer)
                    await session.refresh()
                    if scenario == "r11-return" {
                        let text = try await render(DeviceFlowCard(session: session), artifact: scenario)
                        try check("SEQ-03-revoked-source-has-no-return-button", text.contains("epoch 成功不代表移交完成") && !text.contains("移交回原主設備"))
                        return
                    }
                    session.transferTarget = scenario == "r11-invalid-target" ? "removed-device" : b.id
                    if scenario == "r11-empty-card" {
                        session.signingName = "  "
                        try check("SEQ-01-empty-name-fixture-can-transfer", session.canTransfer && PrimaryTransfer.canBegin(a.dispatch.identity()) && session.transferCandidates.contains { $0.id == b.id })
                        let host = NSHostingView(rootView: DeviceFlowCard(session: session).frame(width: 1000, height: 1100))
                        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 1100)
                        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.contentView = host; window.orderFrontRegardless()
                        defer { window.close() }
                        for _ in 0..<8 {
                            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                            try await Task.sleep(for: .milliseconds(30))
                        }
                        func buttons(_ view: NSView) -> [DeviceFlowPhysicalButton.Native] { (view as? DeviceFlowPhysicalButton.Native).map { [$0] } ?? view.subviews.flatMap(buttons) }
                        let deadline = Date().addingTimeInterval(3)
                        var start: DeviceFlowPhysicalButton.Native?
                        repeat {
                            host.layoutSubtreeIfNeeded()
                            start = buttons(host).first { $0.title == "移交主設備…" }
                            if start != nil { break }
                            try await Task.sleep(for: .milliseconds(20))
                        } while Date() < deadline
                        try check("SEQ-01-empty-name-start-button-rendered", start != nil)
                        print("W187R11 empty-name native-button enabled=\(start?.isEnabled == true) binding-current=\(start?.binding == session.cardBinding) signing-name-length=\(session.signingName.count)")
                        try check("SEQ-01-empty-name-disables-start", start?.isEnabled == false)
                        return
                    }
                    session.signingName = "fixture release"
                    await session.transferFromLocalDialog(.fixture(binding: session.cardBinding))
                    try check("ROSTER-03-dialog-actual-cause", scenario == "r11-dialog" ? session.message.contains("GBrain 不健康") : !session.message.isEmpty)
                    let text = try await render(DeviceFlowCard(session: session), artifact: scenario)
                    try check("ROSTER-03-visible-card-cause", scenario != "r11-dialog" || text.contains("GBrain 不健康"))
                } catch { errors.fail(error) }
            }
            guard done.wait(timeout: .now() + 30) == .success else { throw DeviceFleetError.malformed }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
            return
        }
        if scenario == "r11-memory-race" {
            let paths = EngineMemoryPaths(home: b.dispatch.root.appendingPathComponent("r11-memory-home").path, entryRoot: b.dispatch.entry.root)
            let primary = EngineMemoryPaths(home: a.dispatch.root.appendingPathComponent("r11-memory-home").path, entryRoot: a.dispatch.entry.root)
            for path in [primary, paths] {
                try EngineMemoryLinks.createMemoryFolder(path.memory)
                try TatwoMemorySyncAcceptance.note(path.memory, "synthetic.md", title: "Synthetic", body: "Synthetic.")
                _ = EngineMemoryLinks.commit(path.memory, message: "synthetic")
            }
            try TatwoMemorySyncAcceptance.note(paths.memory, "secondary.md", title: "Secondary", body: "Synthetic new note.")
            var targets = 0
            let channel = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, rpc: { _, method, _ in
                guard method == "memory_sync_target" else { throw DeviceFleetError.malformed }
                targets += 1
                if targets > 1 { throw DeviceFleetGate.CallError.primaryTransferred }
                return ["repository": primary.memory.path, "available": true]
            })
            let engine = TatwoMemorySyncEngine(paths: { paths }, dispatch: channel, fetch: { _, _ in
                let result = EngineMemoryLinks.run("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "fetch", "--", primary.memory.path, "+HEAD:" + TatwoMemorySyncEngine.primaryRef], in: paths.memory)
                guard result.status == 0 else { throw DeviceFleetError.malformed }
            })
            let status = engine.runOnce(.manual)
            try check("MEM-01-push-race-waits-quietly", targets == 2 && status.state == .disabled && status.line.isEmpty && status.error == nil)
            return
        }
        let manager = BackgroundJobManager(root: b.dispatch.root.appendingPathComponent("r11-jobs"))
        let bridge = OSAgentBridge.fleetFixtureBridge()
        let (model, owner, other, work) = try DispatchQueue.main.sync { () throws -> (ChatPageModel, UUID, UUID, String) in
            let live = ChatLiveEngine(store: ChatLiveStore(root: b.dispatch.root.appendingPathComponent("r11-chat")), environment: b.env)
            let model = ChatPageModel(environment: b.env.merging(["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT": "r11"]) { _, new in new }, botCoreFixture: (live, BotStore(root: b.dispatch.root.appendingPathComponent("r11-bots"))))
            let work = b.dispatch.entry.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("project").path
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let project = live.newProject(name: "fixture", workdir: work)
            let owner = live.newThread(in: project, title: "managed")
            live.markControllerThread(owner, fingerprint: try DeviceRegistry.fingerprint(publicKey: a.clientKey))
            let override = work + "/owner"
            try FileManager.default.createDirectory(atPath: override, withIntermediateDirectories: true)
            live.configureRoom(threadID: owner, parentThreadID: owner, roomBrief: "synthetic", engine: "codex", cwdOverride: override)
            let otherProject = live.newProject(name: "demo", workdir: work + "/other")
            let other = live.newThread(in: otherProject, title: "unrelated selected thread")
            model.selectedThreadID = other
            bridge.configureCallerTest(model: model, manager: manager)
            return (model, owner, other, override)
        }
        defer { manager.stopAll(); DispatchQueue.main.sync { model.live?.shutdownAll() } }
        bridge.backgroundCommandApprover = { _, _, _ in true }
        if scenario == "r11-cwd" {
            let home = ProcessInfo.processInfo.environment["HOME"]!
            let config = home + "/.config/git"
            try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
            let file = URL(fileURLWithPath: config + "/config")
            try Data("synthetic original".utf8).write(to: file)
            let alias = work + "/outside-link"
            try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home + "/.config")
            for cwd in [home + "/.config", "~/.config", home, "/", work + "/../other", alias] {
                let response = try bridge.fixtureHandle(dispatch: b.dispatch, method: "run_background",
                    params: ["cmd": "print changed > '" + file.path + "'", "cwd": cwd], caller: .engine(owner))
                try check("CARDS-01-cwd-outside-owner-refused", response["ok"] as? Bool == false)
            }
            try check("CARDS-01-config-unchanged", String(contentsOf: file, encoding: .utf8) == "synthetic original")
            let response = try bridge.fixtureHandle(dispatch: b.dispatch, method: "run_background",
                params: ["cmd": "print synthetic > output.txt", "cwd": work], caller: .engine(owner))
            guard let id = UUID(uuidString: (response["result"] as? [String: Any])?["jobID"] as? String ?? "") else {
                throw DeviceDispatch.Failure(reason: "W187R11_FAIL_CARDS-01-owner-workspace-refused: " + String(describing: response))
            }
            for _ in 0..<500 where manager.status(jobID: id)?.state == "running" { usleep(10_000) }
            try check("CARDS-01-owner-workspace-remains-writable", manager.status(jobID: id)?.exitCode == 0)
        } else if scenario == "r11-cli" {
            try DispatchQueue.main.sync {
                try check("CARDS-02-engine-tab-refused", model.openCLITab(engine: .codex, callerThreadID: owner) == nil)
                try check("CARDS-02-screen-explains-shell-only", model.composerHint?.contains("一般終端") == true && model.composerHint?.contains("記憶權限") == true)
                try check("CARDS-02-generic-tab-opens", model.openCLITab(engine: .generic, callerThreadID: owner) != nil)
                let tab = model.cliSessionsByThread[owner]!.last!
                try check("CARDS-01-CLI-uses-owner-override", tab.workdir == HandsPath.canonical(work) && model.selectedThreadID == other)
            }
        } else if scenario == "r11-external" {
            try DispatchQueue.main.sync {
                ExternalWorkspacePolicy.extraEntriesForTesting.set([b.dispatch.entry.root.path])
                defer { ExternalWorkspacePolicy.extraEntriesForTesting.set([]); ClaudeSidecar.fixtureLaunch = nil }
                let cwd = b.dispatch.entry.root.appendingPathComponent("chatgpt/project").path
                try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
                let live = model.localLiveForBridge!
                live.configureRoom(threadID: other, parentThreadID: other, roomBrief: "synthetic", engine: "codex", cwdOverride: cwd)
                var launched = false
                ClaudeSidecar.fixtureLaunch = { _, _, _, _ in launched = true }
                try check("W183-external-workspace-refused-before-engine-launch", !live.fixtureStartSidecar(other, engine: .codex) && !launched)
                try check("W183-external-workspace-refusal-visible", live.transcript(for: other).contains { $0.text == ExternalWorkspacePolicy.engineRefusal })
            }
        } else if scenario == "r11-admission" {
            try DeviceFleetEighthRoundAcceptance.withMainRunLoop {
                let marker = "synthetic-private-preference-r11"
                try Data(marker.utf8).write(to: b.dispatch.entry.root.appendingPathComponent("user.md"))
                var arguments: [String] = [], launchedCwd = ""
                let checks = DeviceFleetFourthRoundAcceptance.Results()
                ClaudeSidecar.fixtureLaunch = { _, args, _, cwd in arguments = args; launchedCwd = cwd }
                DeviceFleetEnvelope.fixtureVerification = { checks.append(1) }
                defer { ClaudeSidecar.fixtureLaunch = nil; DeviceFleetEnvelope.fixtureVerification = nil }
                try check("CARDS-04-production-sidecar-starts", model.localLiveForBridge!.fixtureStartSidecar(owner, engine: .codex))
                try check("CARDS-04-admission-verifies-envelope-once", checks.sequences.count == 1)
                try await DeviceFleetEighthRoundAcceptance.waitForLaunch { !arguments.isEmpty }
                try check("CARDS-04-launch-excludes-preferences", !arguments.joined(separator: " ").contains(marker))
                try check("CARDS-01-sidecar-uses-owner-override", launchedCwd == HandsPath.canonical(work))
            }
        } else if scenario == "r11-ssh-copy" {
            try check("CARDS-03-permission-explains-SSH-key-limit", DeviceFleetCapabilities.labels["dispatch"]!.contains("沒有記憶權限時，不能使用這台的 SSH 金鑰（SSH 的 git、ssh、rsync 不可用）"))
        }
    }
    @MainActor
    static func correctSigningName(dispatch: DeviceDispatch, readback: () throws -> Void) async throws {
        let host = NSHostingView(rootView: DeviceFlowTransferPanel(dispatch: dispatch).frame(width: 1000, height: 1100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let field = fields(host).first(where: { $0.isEditable }), field.stringValue.isEmpty else {
            throw DeviceDispatch.Failure(reason: "W187R11_FAIL_SEQ-01-real-panel-has-empty-editable-name")
        }
        field.stringValue = "fixture release"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [DeviceFlowPhysicalButton.Native] { (view as? DeviceFlowPhysicalButton.Native).map { [$0] } ?? view.subviews.flatMap(buttons) }
        guard let button = buttons(host).first(where: { $0.title.hasPrefix("④") }), button.isEnabled else {
            throw DeviceDispatch.Failure(reason: "W187R11_FAIL_SEQ-01-real-panel-release-action-enabled")
        }
        button.invoke?(.fixture(binding: button.binding))
        for _ in 0..<100 {
            if try dispatch.identity().transfer?.release == .ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard try dispatch.identity().transfer?.signingName == "fixture release",
              try dispatch.identity().transfer?.release == .ready else {
            throw DeviceDispatch.Failure(reason: "W187R11_FAIL_SEQ-01-real-panel-submits-edited-name")
        }
        try readback()
        let text = try await render(DeviceFlowTransferPanel(dispatch: dispatch), artifact: "signing-repair")
        guard text.contains("移交完成") else { throw DeviceDispatch.Failure(reason: "W187R11_FAIL_SEQ-01-completion-visible") }
        print("W187R11 PASS SEQ-01-real-panel-submits-edited-name")
    }
    @MainActor
    static func render<V: View>(_ view: V, artifact: String) async throws -> String {
        let host = NSHostingView(rootView: view.padding(24).frame(width: 1000, height: 1100).background(Color.white).foregroundStyle(.black))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!).appendingPathComponent(artifact + ".png"))
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        print("W187R11 rendered " + text)
        return text
    }
}
#endif
