#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W336VMDeviceAcceptance {
    // Executable fixture, never a real limactl. Shared with W335's source metadata check.
    static func fixture(entry: TatwoEntry, root: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let script = #"""
        #!/usr/bin/python3
        import os,sys,json,time,hashlib
        from pathlib import Path
        root=Path(__file__).resolve().parents[2]
        args=sys.argv[1:]
        with (root/'argv.jsonl').open('a') as f:f.write(json.dumps({'argv':args,'home':os.environ.get('LIMA_HOME'),'pid':os.getpid()})+'\n')
        if args[0]=='list':
          print((root/'list.jsonl').read_text(),end='')
        elif args[0] in ['start','stop']:
          time.sleep(float((root/'delay').read_text()) if (root/'delay').exists() else 0)
          if (root/'fail').exists():
            print('fixture power refused',file=sys.stderr);sys.exit(1)
          rows=[json.loads(x) for x in (root/'list.jsonl').read_text().splitlines()]
          for row in rows:
            if row['name']==args[-1]:row['status']='Running' if args[0]=='start' else 'Stopped'
          (root/'list.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in rows))
        elif args[0]=='create':
          name=next(x.split('=',1)[1] for x in args if x.startswith('--name='))
          with (root/'list.jsonl').open('a') as f:f.write(json.dumps({'name':name,'status':'Stopped','config':{'os':'Darwin' if name.startswith('tatwo-macos-') else 'Linux'}})+'\n')
        elif args[0]=='shell' and '-u' in args:
          display=(root/'display').read_text() if (root/'display').exists() else 'ABCD'
          print('交易：'+display+'；回呼識別：fixture',flush=True)
          value=sys.stdin.readline().strip()
          (root/'stdin-sha256').write_text(hashlib.sha256(value.encode()).hexdigest())
          print('installed',flush=True)
        """#
        for version in ["2.9.0", "2.10.0"] {
            let bin = root.appendingPathComponent("lima-\(version)/bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent("limactl")
            try Data(script.utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try setRows(root)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: entry.deviceJSON)) as! [String: Any]
        json["resources"] = ["sandbox": root.path]
        try JSONSerialization.data(withJSONObject: json).write(to: entry.deviceJSON)
        return root
    }
    static func setRows(_ root: URL) throws {
        let rows: [[String: Any]] = [
            ["name": "tatwo-linux-ab12", "status": "Stopped", "config": ["os": "Linux"]],
            ["name": "tatwo-macos-cd34", "status": "Running", "config": ["os": "Darwin"]],
            ["name": "someone-else", "status": "Running", "os": "Linux"],
            ["name": "tatwo-windows", "status": "Stopped", "os": "Windows"]]
        let data = try rows.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
        try data.write(to: root.appendingPathComponent("list.jsonl"))
    }
    static func press(_ id: String, _ shot: GlobalDMChatAcceptance.Rendered, settle: Bool = true) async throws {
        guard let node = W214Acceptance.node(id, shot), let frame = DMBrowserAcceptance.axFrame(node) else { throw DeviceFleetError.malformed }
        let point = shot.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        if settle { await W214Acceptance.click(point, in: shot) }
        else {
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shot.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1), let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shot.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw DeviceFleetError.malformed }
            shot.window.sendEvent(down); shot.window.sendEvent(up)
        }
    }
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), let output = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw DeviceFleetError.malformed }
        let artifacts = URL(fileURLWithPath: output), entry = TatwoEntry()
        let fm = FileManager.default
        try fm.createDirectory(at: entry.root, withIntermediateDirectories: true)
        let identity = DeviceIdentity(deviceID: UUID().uuidString, name: "fixture Studio", hardwareModel: "fixture", role: .secondary, epoch: 1, primaryDeviceID: "11111111-1111-4111-8111-111111111111", updatedAt: Date())
        try identity.encoded().write(to: entry.deviceJSON)
        var passed = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { print("W336VMDEVICE FAIL \(name)"); throw DeviceFleetError.malformed }
            passed += 1; print("W336VMDEVICE PASS \(name)")
        }
        let noTool = try await Task.detached { try SandboxVMTool.find() }.value
        try check(noTool == nil, "missing-resource-no-fallback-no-download")
        let graph = DeviceFleetUISnapshot(payload: nil, localID: identity.deviceID)
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }
        func render(_ dark: Bool) async throws -> GlobalDMChatAcceptance.Rendered {
            guard let shot = GlobalDMChatAcceptance.renderSync(VStack(alignment: .leading, spacing: 20) {
                Text("沙盒 › Linux › 虛擬設備").font(.title2)
                SandboxVirtualDevices(platform: "Linux", snapshot: graph, canPair: false)
                Text("沙盒 › macOS › 虛擬設備").font(.title2)
                SandboxVirtualDevices(platform: "macOS", snapshot: graph, canPair: false)
            }.padding(24), size: CGSize(width: 1000, height: 1000), scheme: dark ? .dark : .light) else { throw DeviceFleetError.malformed }
            await W214Acceptance.settle(shot); try await Task.sleep(for: .milliseconds(400)); return shot
        }
        for dark in [false, true] {
            theme.use(dark ? .aurora : .fable5)
            let shot = try await render(dark)
            try check(W214Acceptance.text(shot).contains("這台沒有內建虛擬機"), "empty-\(dark)")
            try W214Acceptance.save(shot, "empty-" + (dark ? "aurora" : "fable5"), artifacts); shot.close()
        }
        let root = try fixture(entry: entry, root: artifacts.appendingPathComponent("fake-vm"))
        guard let tool = try await Task.detached(operation: { try SandboxVMTool.find() }).value else { throw DeviceFleetError.malformed }
        try check(tool.executable.path.contains("lima-2.10.0") && tool.home == root.appendingPathComponent("lima-home").path, "highest-version-and-scoped-home")
        for version in ["2.10.0", "2.9.0"] {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("lima-\(version)/bin/limactl").path)
        }
        try check(try await Task.detached { try SandboxVMTool.find() }.value == nil, "configured-resource-missing-executable")
        for version in ["2.10.0", "2.9.0"] { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("lima-\(version)/bin/limactl").path) }
        let rows = try await tool.list()
        try check(rows.count == 2 && rows.map(\.platform) == ["Linux", "macOS"], "tatwo-only-platform-split")
        let nestedMac = try JSONDecoder().decode(SandboxVM.self, from: Data(#"{"name":"fixture","status":"Stopped","config":{"os":"Darwin","mounts":[]}}"#.utf8))
        let defaultLinux = try JSONDecoder().decode(SandboxVM.self, from: Data(#"{"name":"fixture","status":"Stopped","config":{}}"#.utf8))
        let flatMac = try JSONDecoder().decode(SandboxVM.self, from: Data(#"{"name":"fixture","status":"Stopped","os":"Darwin"}"#.utf8))
        try check(nestedMac.platform == "macOS" && defaultLinux.platform == "Linux" && flatMac.platform == "macOS", "native-config-os-and-linux-default")
        for action in ["start", "stop"] {
            _ = try await tool.run([action, "--tty=false", rows[0].name])
            let current = try await tool.list()
            try check(current[0].running == (action == "start"), "\(action)-args-background-and-refresh")
        }
        try Data().write(to: root.appendingPathComponent("fail"))
        var reason = ""
        do { _ = try await tool.run(["start", "--tty=false", rows[0].name]) } catch { reason = String(describing: error) }
        try check(reason == "fixture power refused", "power-failure-retains-one-reason")
        try fm.removeItem(at: root.appendingPathComponent("fail"))
        for platform in ["Linux", "macOS"] { try await tool.create(platform) }
        try check(try await tool.list().count == 4, "create-both-platforms-template-args")
        try setRows(root)
        _ = try await tool.run(["start", "--tty=false", rows[0].name])
        let running = try await tool.list()[0]
        let secret = "SYNTHETIC-STDIN-ONLY"
        try await tool.install(running, gateway: "https://hands.example.com") { display in
            guard display == "ABCD" else { throw DeviceFleetError.malformed }; return secret
        }
        try check(try String(contentsOf: root.appendingPathComponent("stdin-sha256"), encoding: .utf8) == HandsAuth.sha256Hex(Data(secret.utf8)), "installation-work-account-pairing-code-stdin-only")
        let log = try String(contentsOf: root.appendingPathComponent("argv.jsonl"), encoding: .utf8)
        try check(!log.contains(secret) && log.contains("\"-u\", \"work\"") && log.contains("\"copy\""), "no-code-in-argv-or-records-no-host-job-dispatch")
        var denied = false
        do { _ = try await DeviceFleetStore.registerSandbox(name: "fixture", info: .init(platform: "Linux", virtual: true, source: "fixture Studio")) } catch { denied = true }
        do { try HandsState.shared.service.sandboxLane.pair("fixture"); denied = false } catch { }
        try check(denied && HandsState.shared.service.auth.pendingCard == nil, "non-primary-cannot-create-pairing")
        try Data("5".utf8).write(to: root.appendingPathComponent("delay"))
        let start = Date()
        var timedOut = false
        do { _ = try await tool.run(["start", "--tty=false", rows[0].name], timeout: 0.2) } catch { timedOut = true }
        try check(timedOut && Date().timeIntervalSince(start) < 1, "bounded-background-process")
        try Data("1".utf8).write(to: root.appendingPathComponent("delay"))
        try setRows(root)
        // A previously installed VM may have been rebuilt or its host grant revoked.
        let defaults = UserDefaults.standard, previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(previous.merging(["tatwo2.sandbox.vmPaired": rows[1].name]) { _, new in new }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        for dark in [false, true] {
            theme.use(dark ? .aurora : .fable5)
            let suffix = dark ? "aurora" : "fable5", shot = try await render(dark)
            try W214Acceptance.dump(shot, "two-rows-" + suffix, artifacts)
            let text = W214Acceptance.text(shot)
            try check(text.contains(rows[0].name) && text.contains(rows[1].name) && !text.contains("someone-else") && W214Acceptance.node("vm.gateway", shot) == nil && W214Acceptance.node("vm.code", shot) == nil, "two-rows-no-setup-fields-until-install-\(suffix)")
            try W214Acceptance.save(shot, "two-rows-" + suffix, artifacts)
            try check(W214Acceptance.text(shot).contains("曾完成安裝；配對以主設備為準"), "W352-cached-install-is-only-hint-\(suffix)")
            try await press("vm.install." + rows[1].name, shot)
            try check(W214Acceptance.text(shot).contains("先到主設備按「加一台沙盒」登錄這台") && W214Acceptance.node("vm.gateway", shot) != nil && W214Acceptance.node("vm.start", shot) != nil && W214Acceptance.node("vm.code", shot) == nil, "install-setup-panel-non-primary-\(suffix)")
            try check(W214Acceptance.node("vm.start", shot) != nil, "W352-rebuilt-or-revoked-vm-can-pair-again-\(suffix)")
            try W214Acceptance.save(shot, "setup-" + suffix, artifacts)
            try await press("vm.cancel", shot)
            let clicked = Date()
            try await press("vm.power." + rows[0].name, shot, settle: false)
            for _ in 0..<10 { if W214Acceptance.text(shot).contains("開機中…") { break }; try await Task.sleep(for: .milliseconds(10)) }
            try check(W214Acceptance.text(shot).contains("開機中…") && Date().timeIntervalSince(clicked) < 0.3, "immediate-starting-state-\(suffix)")
            try W214Acceptance.save(shot, "starting-" + suffix, artifacts)
            for _ in 0..<100 { if W214Acceptance.text(shot).contains(rows[0].name + " · 已開機") { break }; try await Task.sleep(for: .milliseconds(50)) }
            await W214Acceptance.settle(shot)
            try await press("vm.create", shot)
            try check(W214Acceptance.node("vm.platform", shot) != nil && W214Acceptance.node("vm.confirm", shot) != nil, "create-platform-form-\(suffix)")
            shot.close(); try setRows(root)
        }
        print("W336VMDEVICE SUMMARY failures=0 passed=\(passed)")
        return true
    }
}
#endif
