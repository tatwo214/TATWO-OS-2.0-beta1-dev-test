#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W335SandboxUIAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), let output = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw DeviceFleetError.malformed }
        let artifacts = URL(fileURLWithPath: output), entry = TatwoEntry()
        try FileManager.default.createDirectory(at: entry.root, withIntermediateDirectories: true)
        let id = HandsConnectAcceptance.hostID
        try DeviceIdentity(deviceID: id, name: "fixture primary", hardwareModel: "fixture", role: .primary, epoch: 1, primaryDeviceID: id, updatedAt: Date()).encoded().write(to: entry.deviceJSON)
        let key = artifacts.appendingPathComponent("fixture-key").path
        setenv("TATWO2_SSH_KEY_PATH", key, 1); setenv("TATWO2_SSH_HOST_KEY_PUB", key + ".pub", 1)
        _ = try await Task.detached { try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", key]) }.value
        let fleet = DeviceFleetStore(registry: DeviceRegistry(), environment: ProcessInfo.processInfo.environment)
        try await Task.detached { try fleet.bootstrapPrimary() }.value
        let hands = HandsState.shared, service = hands.service
        service.deviceIDOverride = id; service.permitCheck = { true }
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = id; $0.publicHost = "hands.example.com" }
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }
        var passed = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { print("W335SANDBOXUI FAIL \(name)"); throw DeviceFleetError.malformed }
            passed += 1; print("W335SANDBOXUI PASS \(name)")
        }
        func snapshot() throws -> DeviceFleetUISnapshot { DeviceFleetUISnapshot(payload: try fleet.readGraph(), localID: id) }
        func render(_ snapshot: DeviceFleetUISnapshot, dark: Bool = false, list: Bool = true) async throws -> GlobalDMChatAcceptance.Rendered {
            guard let shot = GlobalDMChatAcceptance.renderSync(DeviceFleetPage(snapshot: snapshot, initialList: list).padding(24), size: CGSize(width: 1000, height: 1060), scheme: dark ? .dark : .light) else { throw DeviceFleetError.malformed }
            await W214Acceptance.settle(shot); return shot
        }
        func press(_ name: String, _ shot: GlobalDMChatAcceptance.Rendered) async throws {
            guard let node = W214Acceptance.node(name, shot), let frame = DMBrowserAcceptance.axFrame(node) else { throw DeviceFleetError.malformed }
            shot.window.setFrameOrigin(NSPoint(x: -20_000, y: -19_000))
            guard let updated = DMBrowserAcceptance.axFrame(node) else { throw DeviceFleetError.malformed }
            let point = shot.window.convertPoint(fromScreen: NSPoint(x: updated.midX, y: updated.midY))
            _ = frame
            await W214Acceptance.click(point, in: shot)
        }
        theme.use(.fable5)
        for platform in ["Linux", "macOS"] { UserDefaults.standard.set(false, forKey: "tatwo2.sandbox.\(platform).virtual") }
        let empty = try await render(snapshot())
        try W214Acceptance.dump(empty, "empty-before", artifacts)
        try await press("sandbox.expand", empty); try await press("sandbox.Linux.expand", empty)
        try check(W214Acceptance.text(empty).contains("尚未配對沙盒設備"), "empty-state")
        try await press("sandbox.Linux.add", empty)
        try check(W214Acceptance.node("sandbox.confirm", empty) != nil && W214Acceptance.node("sandbox.source", empty) != nil, "add-name-platform-source-form")
        let fields = W214Acceptance.nodes(empty).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        guard fields.count == 2 else { throw DeviceFleetError.malformed }
        for (field, value) in zip(fields, ["Dots fixture", "Dots"]) {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        await W214Acceptance.settle(empty)
        try await press("sandbox.confirm", empty)
        for _ in 0..<50 {
            if (try fleet.readGraph()?.roster?.devices.count ?? 0) > 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await W214Acceptance.settle(empty)
        let registered = try fleet.readGraph()!.roster!.devices.first { $0.role == .sandbox }!
        try check(registered.sandboxInfo == SandboxDeviceInfo(platform: "Linux", virtual: false, source: "Dots") && service.auth.windowExpiresAt != nil, "add-registers-sandbox-and-opens-existing-pairing")
        let client = HandsConnectAcceptance.FakeChatGPT(service: service); try client.register()
        _ = try service.handle(method: "hands_auth", params: ["op": "authorize_begin", "client_id": client.clientID, "redirect_uri": client.redirect,
            "code_challenge": client.challenge, "code_challenge_method": "S256", "state": client.state, "scope": "sandbox"])
        await W214Acceptance.settle(empty)
        try check(W214Acceptance.node("tap.chatgpt.hands.pairingCode", empty) != nil && service.auth.pendingCard?.scope.sandboxDeviceID == registered.id, "existing-pairing-code-inline")
        service.auth.closeWindow(); empty.close()
        _ = try await Task.detached { try fleet.addSandbox(name: "Grok fixture", info: .init(platform: "macOS", virtual: false, source: "Grok")) }.value
        _ = try await Task.detached { try fleet.addSandbox(name: "tatwo-linux-ab12", info: .init(platform: "Linux", virtual: true, source: "fixture primary")) }.value
        _ = try await Task.detached { try fleet.addSandbox(name: "tatwo-macos-cd34", info: .init(platform: "macOS", virtual: true, source: "fixture primary")) }.value
        _ = try W336VMDeviceAcceptance.fixture(entry: entry, root: artifacts.appendingPathComponent("fake-vm"))
        let graph = try snapshot()
        let encoded = try JSONEncoder().encode(graph.devices), decoded = try JSONDecoder().decode([DeviceFleetMember].self, from: encoded)
        try check(decoded == graph.devices, "source-metadata-roundtrip")
        let diagram = try await render(graph, list: false)
        try check(!W214Acceptance.text(diagram).contains("建立沙盒專用配對"), "graph-has-no-duplicate-pairing-entry"); diagram.close()
        for dark in [false, true] {
            theme.use(dark ? .aurora : .fable5)
            let shot = try await render(graph, dark: dark), suffix = dark ? "aurora" : "fable5"
            try W214Acceptance.save(shot, suffix + "-collapsed", artifacts)
            try await press("sandbox.expand", shot)
            for platform in ["Linux", "macOS"] { try await press("sandbox.\(platform).expand", shot) }
            let text = W214Acceptance.text(shot)
            try check(text.contains("Dots fixture") && text.contains("Grok fixture") && text.contains("權限不對稱") && text.contains("最後心跳") && text.contains("目前工作"), "platform-rows-status-\(suffix)")
            try W214Acceptance.save(shot, suffix + "-expanded", artifacts)
            try await press("sandbox.Linux.virtual", shot)
            for _ in 0..<100 { if W214Acceptance.text(shot).contains("tatwo-linux-ab12") { break }; try await Task.sleep(for: .milliseconds(50)) }
            try check(W214Acceptance.text(shot).contains("tatwo-linux-ab12") && !W214Acceptance.text(shot).contains("Dots fixture") && W214Acceptance.text(shot).contains("內建虛擬機（fixture primary）"), "virtual-source-row-\(suffix)")
            try check(UserDefaults.standard.bool(forKey: "tatwo2.sandbox.Linux.virtual") && !UserDefaults.standard.bool(forKey: "tatwo2.sandbox.macOS.virtual"), "per-platform-selection-persisted-\(suffix)")
            try W214Acceptance.dump(shot, "virtual-" + suffix, artifacts)
            try check(W214Acceptance.node("vm.power.tatwo-linux-ab12", shot) != nil, "lima-backed-vm-control-\(suffix)")
            try await press("sandbox.Linux.physical", shot)
            try check(!W214Acceptance.nodes(shot).contains { ["AXCheckBox", "AXSwitch"].contains(W214Acceptance.attr($0, "accessibilityRole", "AXRole") as? String ?? "") }, "no-fake-vm-switch-\(suffix)")
            shot.close()
        }
        var secondary = graph; secondary.localID = UUID().uuidString
        let denied = try await render(secondary)
        try await press("sandbox.expand", denied); try await press("sandbox.Linux.expand", denied)
        try check(!SandboxDevicesSection(snapshot: secondary).canAdd && W214Acceptance.text(denied).contains("只有主設備"), "non-primary-cannot-add")
        try await press("sandbox.Linux.add", denied)
        try check(W214Acceptance.node("sandbox.confirm", denied) == nil, "disabled-add-does-not-open-form"); denied.close()
        let identity = DeviceIdentity(deviceID: UUID().uuidString, name: "fixture secondary", hardwareModel: "fixture", role: .secondary, epoch: 1, primaryDeviceID: id, updatedAt: Date())
        try identity.encoded().write(to: entry.deviceJSON)
        var refused = false
        do { _ = try await Task.detached { try fleet.addSandbox(name: "fixture", info: .init(platform: "Linux", virtual: false, source: "fixture")) }.value } catch { refused = true }
        try check(refused, "backend-rechecks-primary-authority")
        print("W335SANDBOXUI SUMMARY failures=0 passed=\(passed)")
        return true
    }
}
#endif
