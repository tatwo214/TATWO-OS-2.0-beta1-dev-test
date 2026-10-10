import SwiftUI
import SystemConfiguration

struct SandboxVM: Decodable {
    let name: String; let status: String; let os: String?; let config: OS?
    struct OS: Decodable { let os: String? }
    var platform: String { switch (os ?? config?.os ?? "Linux").lowercased() { case "linux": "Linux"; case "macos", "darwin": "macOS"; default: "" } }
    var running: Bool { status.lowercased() == "running" }
    var label: String { running ? "已開機" : status.lowercased() == "stopped" ? "已關機" : status.lowercased() == "starting" ? "開機中" : "狀態不明" }
}
struct SandboxVMTool {
    let executable: URL; let home: String; let source: String
    static func find(entry: TatwoEntry = TatwoEntry()) throws -> Self? {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: entry.deviceJSON)) as? [String: Any]
        guard let path = (json?["resources"] as? [String: Any])?["sandbox"] as? String, path.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: path), fm = FileManager.default
        let candidates = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.range(of: "^lima-[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil && fm.isExecutableFile(atPath: $0.appendingPathComponent("bin/limactl").path)
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        return candidates.first.map { Self(executable: $0.appendingPathComponent("bin/limactl"), home: root.appendingPathComponent("lima-home").path, source: json?["name"] as? String ?? "這台設備") }
    }
    static var assets: URL? { TatwoResources.url(forResource: "sandbox-agent", withExtension: nil) }
    static var desktop: Bool { var uid: uid_t = 0; return SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil && uid == getuid() && uid != 0 }
    func run(_ args: [String], timeout: TimeInterval = 30, code: (@Sendable (String) async throws -> String)? = nil) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let p = Process(), output = Pipe(), input = Pipe(), bytes = HandsLocked(Data()), errors = Pipe(), reason = HandsLocked(Data())
            p.executableURL = executable; p.arguments = args; p.environment = ["LIMA_HOME": home, "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            p.standardOutput = output; p.standardError = errors; p.standardInput = code == nil ? FileHandle.nullDevice : input
            for (pipe, buffer) in [(output, bytes), (errors, reason)] { pipe.fileHandleForReading.readabilityHandler = { handle in let data = handle.availableData; buffer.update { $0.append(data.prefix(max(0, 1048576 - $0.count))) } } }
            defer { output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil; try? input.fileHandleForWriting.close() }
            try p.run()
            let deadline = Date().addingTimeInterval(timeout); var sent = false
            defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            while p.isRunning {
                guard Date() < deadline, !Task.isCancelled else { throw HandsToolError.invalid("操作逾時；請再試一次。") }
                if let code, !sent, let text = String(data: bytes.get(), encoding: .utf8), let range = text.range(of: "交易：[A-Z2-9]{4}；", options: .regularExpression) {
                    let display = String(text[range].dropFirst(3).prefix(4))
                    let value = try await code(display)
                    try input.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8)); try input.fileHandleForWriting.close(); sent = true
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            p.waitUntilExit(); try await Task.sleep(for: .milliseconds(50))
            guard p.terminationStatus == 0 else { throw HandsToolError.invalid(code == nil && !reason.get().isEmpty ? String(String(decoding: reason.get(), as: UTF8.self).split(separator: "\n").first?.prefix(160) ?? "Lima 未完成操作。") : "Lima 未完成操作；請確認虛擬機與沙盒關口可用。") }
            return code == nil ? bytes.get() : Data()
        }.value
    }
    func list() async throws -> [SandboxVM] {
        let data = try await run(["list", "--json"])
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map { try JSONDecoder().decode(SandboxVM.self, from: Data($0.utf8)) }
        return rows.filter { $0.name.hasPrefix("tatwo-") && ["Linux", "macOS"].contains($0.platform) }
    }
    func create(_ platform: String) async throws {
        guard let assets = Self.assets, ["Linux", "macOS"].contains(platform) else { throw DeviceFleetError.malformed }
        let name = "tatwo-\(platform.lowercased())-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await run(["create", "--tty=false", "--name=" + name, assets.appendingPathComponent("vm/\(platform.lowercased()).yaml").path], timeout: 1800)
    }
    func install(_ vm: SandboxVM, gateway: String, code: @escaping @Sendable (String) async throws -> String) async throws {
        guard vm.running, let assets = Self.assets, let url = URL(string: gateway), url.scheme == "https", url.host != nil else { throw HandsToolError.invalid("請填主設備的 HTTPS 沙盒關口。") }
        let staging = "/tmp/tatwo-sandbox-install-" + UUID().uuidString, askpass = staging + ".askpass"
        // macOS 客體的 Lima 帳號 sudo 要密碼（虛擬機自己的 ~/password）；askpass 只在虛擬機裡讀它。Linux 免密碼，不受影響。
        _ = try await run(["shell", "--workdir=/", vm.name, "sh", "-c", #"umask 077; mkdir "$1"; printf '#!/bin/sh\ncat "$HOME/password" 2>/dev/null\n' > "$2"; chmod 700 "$2""#, "_", staging, askpass])
        let sudo = ["shell", "--workdir=/", vm.name, "env", "SUDO_ASKPASS=" + askpass, "sudo", "-A"]
        do {
            for file in ["install.sh", "sandbox-agent.py", "vm/install.sh"] {
                let target = file == "vm/install.sh" ? "vm-install.sh" : file
                _ = try await run(["copy", assets.appendingPathComponent(file).path, vm.name + ":" + staging + "/" + target])
            }
            _ = try await run(sudo + ["chown", "-R", "work", staging])
            _ = try await run(sudo + ["-H", "-u", "work", "sh", staging + "/vm-install.sh", gateway, vm.name], timeout: 600, code: code)
        } catch { _ = try? await run(["shell", "--workdir=/", vm.name, "rm", "-f", askpass]); throw error }
        _ = try? await run(["shell", "--workdir=/", vm.name, "rm", "-f", askpass])
    }
}

struct SandboxVirtualDevices: View {
    let platform: String; let snapshot: DeviceFleetUISnapshot; let canPair: Bool
    @State private var tool: SandboxVMTool?
    @State private var rows: [SandboxVM] = []
    @State private var busy: String?; @State private var problem: String?; @State private var failedID: String?
    @State private var creating = false; @State private var choice = "Linux"
    @State private var gateway = ""; @State private var pairingCode = ""; @State private var transaction = ""
    @State private var setup: String?; @State private var submitted: String?
    @AppStorage("tatwo2.sandbox.vmPaired") private var paired = ""
    @State private var registered: [DeviceFleetMember] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tool {
                ForEach(rows.filter { $0.platform == platform }, id: \.name) { vm in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("\(vm.name) · \(busy == vm.name ? transaction : vm.label)", isOn: Binding(get: { vm.running }, set: { on in perform(vm.name, on ? "開機中…" : "關機中…") { if on && vm.platform == "macOS" && !SandboxVMTool.desktop { throw HandsToolError.invalid("要在這台的桌面開一次") }; _ = try await tool.run([on ? "start" : "stop", "--tty=false", vm.name], timeout: 1800) } })).toggleStyle(.switch).tint(LiquidGlassTokens.brandAccent).disabled(busy != nil).accessibilityIdentifier("vm.power.\(vm.name)")
                        let member = (snapshot.devices + registered).first { $0.role == .sandbox && $0.name == vm.name && $0.sandboxInfo?.platform == platform && $0.sandboxInfo?.source == tool.source }
                        let isPaired = canPair && (member.map { device in HandsState.shared.service.auth.grants().contains { grant in grant.revokedAt == nil && HandsState.shared.service.auth.grantRecord(grant.id)?.sandboxDeviceID == device.id } } ?? false)
                        Text("內建虛擬機（\(tool.source)） · \(isPaired ? "沙盒版已配對" : paired.split(separator: ",").contains(Substring(vm.name)) ? "曾完成安裝；配對以主設備為準" : "沙盒版尚未配對")").font(.caption)
                        OSChipButton(title: "裝沙盒版") { if canPair && !gateway.isEmpty { install(vm, tool: tool, member: member) } else { setup = vm.name } }
                            .disabled(!vm.running || busy != nil || isPaired).accessibilityIdentifier("vm.install.\(vm.name)")
                        // 關口與配對碼只在要裝的時候出現；碼要按「送出」才交出去（打字到一半不送）。
                        if setup == vm.name, busy == nil {
                            if !canPair { Text("先到主設備按「加一台沙盒」登錄這台，再按開始安裝").font(.caption) }
                            TextField("主設備的 HTTPS 沙盒關口", text: $gateway).textFieldStyle(.roundedBorder).accessibilityIdentifier("vm.gateway")
                            HStack(spacing: 6) {
                                OSChipButton(title: "開始安裝") { setup = nil; install(vm, tool: tool, member: member) }.disabled(gateway.isEmpty).accessibilityIdentifier("vm.start")
                                OSChipButton(title: "取消") { setup = nil }.accessibilityIdentifier("vm.cancel")
                            }
                        }
                        if busy == vm.name, !canPair, transaction.hasPrefix("交易：") {
                            Text("到主設備核對交易編號，把那裡的配對碼貼到這裡").font(.caption)
                            HStack(spacing: 6) {
                                SecureField("配對碼（只走標準輸入）", text: $pairingCode).textFieldStyle(.roundedBorder).onSubmit(submitCode).accessibilityIdentifier("vm.code")
                                OSChipButton(title: "送出", action: submitCode).disabled(pairingCode.isEmpty).accessibilityIdentifier("vm.submit")
                            }
                        }
                        if failedID == vm.name, let problem { Text(problem).font(.caption) }
                    }.padding(12).chatLiquidSection(cornerRadius: 12)
                }
                OSChipButton(title: "建一台虛擬設備") { creating = true; choice = platform }.disabled(busy != nil).accessibilityIdentifier("vm.create")
                if creating {
                    Picker("平台", selection: $choice) { Text("Linux").tag("Linux"); Text("macOS").tag("macOS") }.accessibilityIdentifier("vm.platform")
                    OSChipButton(title: "建立") { perform("create", "建立中…") { try await tool.create(choice); creating = false } }.disabled(busy != nil).accessibilityIdentifier("vm.confirm")
                }
            } else { Text("這台沒有內建虛擬機"); Text("請在設備入口設定沙盒資源與 Lima；這裡不會自動下載或安裝工具。").font(.caption) }
            if let problem, failedID == nil || failedID == "create" { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("vm.section").task { await refresh(); gateway = HandsState.shared.service.effectiveSettings().publicHost.map { "https://" + $0 } ?? "" }
    }
    private func submitCode() {
        guard !pairingCode.isEmpty else { return }
        submitted = pairingCode.filter { !$0.isWhitespace }; pairingCode = ""
    }
    private func refresh() async {
        do { tool = try await Task.detached { try SandboxVMTool.find() }.value; rows = try await tool?.list() ?? [] } catch { problem = "虛擬機清單讀取失敗。" }
    }
    private func perform(_ id: String, _ label: String, action: @escaping () async throws -> Void) {
        busy = id; transaction = label; problem = nil; failedID = nil
        Task { do { try await action() } catch { failedID = id; problem = (error as? HandsToolError).map { $0.description } ?? "操作未完成；請確認主設備與虛擬機可用。" }; await refresh(); busy = nil }
    }
    private func install(_ vm: SandboxVM, tool: SandboxVMTool, member: DeviceFleetMember?) {
        submitted = nil; pairingCode = ""   // W344：上一次取消或失敗留下的配對碼不帶到這一次
        perform(vm.name, "安裝中…") {
            var device = member
            if canPair {
                if device == nil { device = try await DeviceFleetStore.registerSandbox(name: vm.name, info: .init(platform: platform, virtual: true, source: tool.source)); if let device { registered.append(device) } }
                guard let device else { throw DeviceFleetError.primaryRequired }; try HandsState.shared.service.sandboxLane.pair(device.id)
            }
            let deviceID = device?.id
            try await tool.install(vm, gateway: gateway) { display in
                await MainActor.run { transaction = "交易：\(display)；等配對碼…" }
                for _ in 0..<600 {
                    if let code = await MainActor.run(body: { () -> String? in
                        if canPair, let deviceID, let card = HandsState.shared.service.auth.pendingCard, card.scope.sandboxDeviceID == deviceID, card.displayCode == display, HandsState.shared.service.sandboxLane.allowed(deviceID) { return card.pairingCode }
                        if !canPair, let value = submitted { submitted = nil; return value }; return nil
                    }) { return code }
                    try await Task.sleep(for: .milliseconds(200))
                }
                throw HandsToolError.invalid("配對碼已逾時；請重新建立沙盒配對。")
            }
            paired = (paired.split(separator: ",").map(String.init).filter { $0 != vm.name } + [vm.name]).joined(separator: ",")
        }
    }
}
