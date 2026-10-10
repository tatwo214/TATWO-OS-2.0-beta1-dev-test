#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W250PickerAcceptance {
    final class State: ObservableObject {
        @Published var selected: ChatRunMode = .tatwo
        var presses: [ChatRunMode] = []
    }
    struct Fixture: View {
        @ObservedObject var state: State
        let modes: [ChatRunMode]
        var body: some View {
            WorkspaceSidebarModePicker(modes: modes, selection: state.selected) {
                state.presses.append($0)
                state.selected = $0
            }
        }
    }
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let out = URL(fileURLWithPath: path), scope = TatwoThemeSelfTestScope()
        defer { scope.restore() }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failed += 1 }
            print("W250PICKER \(ok ? "PASS" : "FAIL") \(label)")
        }
        func capture(_ shot: GlobalDMChatAcceptance.Rendered) -> GlobalDMChatAcceptance.Rendered? {
            TatwoComposerModeAcceptance.settle(shot)
            // WindowServer supplies the glass layers omitted by cacheDisplay.
            return GlobalDMChatAcceptance.captureOwnWindow(shot)
        }
        for theme in [TatwoThemeID.fable5, .aurora] {
            scope.use(theme)
            for scheme in [ColorScheme.light, .dark] {
                for count in [4, 5] {
                    let name = "\(theme.rawValue)-\(scheme == .dark ? "dark" : "light")-\(count)"
                    let modes = Array([ChatRunMode.tatwo, .chat, .chatgpt, .browser, .bot].prefix(count))
                    let state = State()
                    guard let shot = GlobalDMChatAcceptance.renderSync(Fixture(state: state, modes: modes),
                                                                       size: CGSize(width: 214, height: 80), scheme: scheme) else {
                        check(false, name + " renders"); continue
                    }
                    defer { shot.close() }
                    let nodes = GlobalDMChatAcceptance.tree(shot)
                    check(nodes.keys.filter { $0.hasPrefix("workspace.mode.") }.count == count, name + " button count")
                    check(!nodes.keys.contains { $0.lowercased().contains("enamel") }, name + " no removed surface")
                    check((nodes["workspace.mode.Bot"] != nil) == (count == 5), name + " pet button presence")
                    check(ChatRunMode.bot.displayName == "寵物", name + " pet label")
                    check(state.selected == .tatwo && state.presses.isEmpty, name + " initial selection")
                    guard let before = capture(shot) else { check(false, name + " initial capture"); continue }
                    GlobalDMChatAcceptance.save(before, "w250-\(name)-initial.png", to: out)
                    var previous = before.bitmap.tiffRepresentation
                    for mode in modes.dropFirst() + modes.prefix(1) {
                        let id = "workspace.mode.\(mode.rawValue)", calls = state.presses.count
                        guard let node = GlobalDMChatAcceptance.tree(shot)[id] else { check(false, name + " " + id); continue }
                        check((node as AnyObject).accessibilityPerformPress?() == true, name + " native press " + mode.rawValue)
                        try await Task.sleep(for: .milliseconds(150))
                        check(state.selected == mode && state.presses.count == calls + 1 && state.presses.last == mode,
                              name + " selected state " + mode.rawValue)
                        guard let after = capture(shot) else { check(false, name + " selected capture " + mode.rawValue); continue }
                        let pixels = after.bitmap.tiffRepresentation
                        check(pixels != nil && pixels != previous, name + " selected appearance changes " + mode.rawValue)
                        previous = pixels
                    }
                    // Leave exactly one selected button; include selected Pets evidence in the five-button row.
                    let target = modes.last!
                    let pressed = GlobalDMChatAcceptance.tree(shot)["workspace.mode.\(target.rawValue)"]
                        .map { ($0 as AnyObject).accessibilityPerformPress?() == true } ?? false
                    try await Task.sleep(for: .milliseconds(150))
                    check(pressed && state.selected == target, name + " final single selection " + target.rawValue)
                    if let selected = capture(shot) {
                        GlobalDMChatAcceptance.save(selected, "w250-\(name)-selected.png", to: out)
                        check(scheme != .dark || theme == .fable5 || TatwoThemeSelfTestScope.hasReadableDarkPixels(selected.bitmap),
                              name + " readable theme capture")
                    } else { check(false, name + " final capture") }
                    let finalNodes = GlobalDMChatAcceptance.tree(shot)
                    check(!finalNodes.keys.contains { $0.lowercased().contains("enamel") }, name + " no removed surface after press")
                    check(FileManager.default.fileExists(atPath: out.appendingPathComponent("w250-\(name)-selected.png").path),
                          name + " saved selected screenshot")
                }
            }
        }
        print("W250PICKER SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }
}
#endif
