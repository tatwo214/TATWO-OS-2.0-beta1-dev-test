#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W284Acceptance {
    final class Probe { var frames: [String: CGRect] = [:] }
    private static func press(_ id: String, _ shot: GlobalDMChatAcceptance.Rendered, _ probe: Probe) async -> Bool {
        guard let frame = probe.frames[id] else { return false }
        await W214Acceptance.click(shot.host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil), in: shot)
        return true
    }
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let output = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let artifacts = URL(fileURLWithPath: output), entry = TatwoEntry()
        let fm = FileManager.default, theme = TatwoThemeSelfTestScope()
        defer { theme.restore() }
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try fm.createDirectory(at: WorkPath.defaultURL(entry), withIntermediateDirectories: true)
        let chosen = entry.root.appendingPathComponent("custom work"), refused = entry.root.appendingPathComponent("readonly")
        for folder in [chosen, refused] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: refused.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: refused.path) }
        let identity = DeviceIdentity(deviceID: UUID().uuidString, name: "fixture", hardwareModel: "fixture",
                                      role: .secondary, epoch: nil, primaryDeviceID: nil, updatedAt: Date())
        try identity.encoded().write(to: entry.deviceJSON)
        try Data("# OS\n共用入口規則。".utf8).write(to: entry.constitution)
        var modelEnv = env; modelEnv["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "settings"
        let model = ChatPageModel(environment: modelEnv)
        model.engineLogins = [.init(kind: .codex, isLoggedIn: false, account: nil, detail: "fixture")]
        var failures = 0, passed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures += 1 }
            print("W284 \(value ? "PASS" : "FAIL") \(name)")
        }
        let queue = JobQueue(entry: entry, environment: [:])
        _ = try WorkPath.set(chosen, entry: entry)
        check(DeviceStatusReader.stagingRoot(entry: entry, environment: [:]).path == chosen.path && queue.staging.path == chosen.path,
              "W352-status-and-queue-use-current-workpath")
        let override = entry.root.appendingPathComponent("override")
        check(DeviceStatusReader.stagingRoot(entry: entry, environment: ["TATWO_STAGING": override.path]).path == override.path && JobQueue(entry: entry, environment: ["TATWO_STAGING": override.path]).staging.path == override.path,
              "W352-explicit-staging-environment-wins")
        check(DeviceStatusReader.stagingRoot(entry: entry, environment: ["TATWO_STAGING": "relative"]).path == chosen.path,
              "W352-invalid-staging-environment-uses-workpath")
        _ = try WorkPath.set(nil, entry: entry)
        check(queue.staging == WorkPath.defaultURL(entry), "W352-workpath-reset-updates-existing-queue")
        for dark in [false, true] {
            theme.use(dark ? .aurora : .fable5)
            let suffix = dark ? "dark" : "light", scheme: ColorScheme = dark ? .dark : .light
            let docs = GlobalDMChatAcceptance.renderSync(OSDocumentsCard(model: model, onBack: {}), size: CGSize(width: 1000, height: 720), scheme: scheme)!
            await W214Acceptance.settle(docs)
            check(W214Acceptance.node("workpath.row", docs) != nil && W214Acceptance.text(docs).contains("預設"), "documents.default.\(suffix)")
            check(W214Acceptance.node("workpath.reset", docs) == nil, "documents.default-hides-reset.\(suffix)")
            try W214Acceptance.save(docs, "documents-" + suffix, artifacts); docs.close()
            let beforeGuide = try Data(contentsOf: entry.deviceJSON)
            let guide = GlobalDMChatAcceptance.renderSync(SetupGuidePage(model: model, open: { _ in }), size: CGSize(width: 1000, height: 920), scheme: scheme)!
            await W214Acceptance.settle(guide)
            try W214Acceptance.dump(guide, "guide-" + suffix, artifacts)
            let order = ["setup-title-model", "setup-title-rules", "setup-title-memory", "setup-title-device", "workpath.row", "setup-title-media"]
                .compactMap { W214Acceptance.node($0, guide).flatMap(DMBrowserAcceptance.axFrame)?.midY }
            check(order.count == 6 && zip(order, order.dropFirst()).allSatisfy { $0.0 > $0.1 }, "guide.model-first-workpath-after-device.\(suffix)")
            check(W214Acceptance.node("workpath.state.default", guide) != nil && W214Acceptance.node("workpath.reset", guide) == nil
                  && W214Acceptance.node("workpath.skip", guide) == nil && W214Acceptance.node("workpath.choose", guide).map(DMBrowserAcceptance.axText)?.contains("更改 ›") == true
                  && W214Acceptance.node("setup-assistant-login", guide) != nil, "guide.default-one-change-other-steps.\(suffix)")
            check(try Data(contentsOf: entry.deviceJSON) == beforeGuide, "guide.default-does-not-write.\(suffix)")
            try W214Acceptance.save(guide, "getting-started-" + suffix, artifacts); guide.close()
            let probe = Probe()
            let row = GlobalDMChatAcceptance.renderSync(WorkPathRow(entry: entry, testFolder: chosen, testProbe: probe).padding(24), size: CGSize(width: 1000, height: 220), scheme: scheme)!
            await W214Acceptance.settle(row)
            try W214Acceptance.dump(row, "row-" + suffix, artifacts)
            check(await press("workpath.choose", row, probe), "choose.action.\(suffix)")
            await W214Acceptance.settle(row)
            check(try WorkPath.current(entry).path == chosen.path && W214Acceptance.text(row).contains("custom work"), "choose.persist-and-display.\(suffix)")
            check(W214Acceptance.node("workpath.reset", row) != nil, "documents.custom-shows-reset.\(suffix)")
            check(await press("workpath.reset", row, probe), "reset.action.\(suffix)")
            await W214Acceptance.settle(row)
            check(try WorkPath.current(entry).path == WorkPath.defaultURL(entry).path && W214Acceptance.node("workpath.reset", row) == nil, "reset.default-hides-reset.\(suffix)"); row.close()
            let setupProbe = Probe()
            let setup = GlobalDMChatAcceptance.renderSync(WorkPathRow(entry: entry, isSetup: true, testFolder: chosen, testProbe: setupProbe).padding(24), size: CGSize(width: 1000, height: 220), scheme: scheme)!
            await W214Acceptance.settle(setup)
            check(await press("workpath.choose", setup, setupProbe), "guide.choose.action.\(suffix)")
            await W214Acceptance.settle(setup)
            check(try WorkPath.current(entry).path == chosen.path && W214Acceptance.node("workpath.state.done", setup) != nil
                  && W214Acceptance.node("workpath.reset", setup) == nil && W214Acceptance.node("workpath.skip", setup) == nil, "guide.custom-complete-one-change.\(suffix)")
            try W214Acceptance.dump(setup, "setup-custom-" + suffix, artifacts); setup.close()
            _ = try WorkPath.set(nil, entry: entry)
            let errorProbe = Probe()
            let error = GlobalDMChatAcceptance.renderSync(WorkPathRow(entry: entry, testFolder: refused, testProbe: errorProbe).padding(24), size: CGSize(width: 1000, height: 220), scheme: scheme)!
            await W214Acceptance.settle(error)
            _ = await press("workpath.choose", error, errorProbe)
            await W214Acceptance.settle(error)
            check(try W214Acceptance.text(error).contains("不可寫") && WorkPath.current(entry) == WorkPath.defaultURL(entry), "unwritable.reason.\(suffix)")
            try W214Acceptance.save(error, "unwritable-" + suffix, artifacts); error.close()
            let low = GlobalDMChatAcceptance.renderSync(WorkPathRow(entry: entry, testNotice: WorkPath.warning(bytes: 49_999_999_999)).padding(24), size: CGSize(width: 1000, height: 220), scheme: scheme)!
            await W214Acceptance.settle(low)
            check(W214Acceptance.text(low).contains("空間偏少"), "capacity.warning.\(suffix)")
            try W214Acceptance.save(low, "low-space-" + suffix, artifacts); low.close()
        }
        print("W284 SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
}
#endif
