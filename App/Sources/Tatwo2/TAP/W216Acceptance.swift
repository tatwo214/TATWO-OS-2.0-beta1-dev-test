#if DEBUG
import AppKit
import SwiftUI

@MainActor enum W216Acceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let artifacts = URL(fileURLWithPath: path)
        var failures = 0, passed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures += 1 }
            print("W216 \(value ? "PASS" : "FAIL") \(name)")
        }
        defer { print("W216 SUMMARY failures=\(failures) passed=\(passed)") }
        let theme = TatwoThemeSelfTestScope()
        defer { theme.restore() }
        for dark in [false, true] {
            theme.use(dark ? .aurora : .fable5)
            let pod = Pod(running: true), tap = ChatGPTTap(transport: pod, connection: .ready)
            let model = ChatGPTSpaceModel(testTap: tap)
            let shot = GlobalDMChatAcceptance.renderSync(HStack(spacing: 0) {
                ChatGPTSpaceSidebarList(model: model).frame(width: 240)
                ChatGPTSpaceMainPane(model: model)
            }, size: CGSize(width: 1000, height: 700), scheme: dark ? .dark : .light)!
            defer { shot.close(); tap.sleep() }
            await W214Acceptance.settle(shot)
            let suffix = dark ? "dark" : "light"
            let entry = W214Acceptance.node("chatgpt.project.new", shot)
            check(entry != nil, "N1.missing-new-project-entry.\(suffix)")
            guard entry != nil else { continue }
            let rows = W214Acceptance.nodes(shot).filter {
                ["chatgpt.project.new", "chatgpt.project"].contains(W214Acceptance.attr($0, "accessibilityIdentifier", "AXIdentifier") as? String ?? "")
            }
            check(rows.first === entry && W214Acceptance.text(shot).contains("新增專案"), "N1.first-project-row.\(suffix)")
            check(TatwoComposerModeAcceptance.press("chatgpt.project.new", in: shot), "N2.open-dialog.\(suffix)")
            await W214Acceptance.settle(shot)
            guard var dialog = sheet(shot) else { check(false, "N2.centered-dialog.\(suffix)"); continue }
            check(W214Acceptance.text(dialog).contains("建立專案"), "N2.traditional-title.\(suffix)")
            check(!enabled("chatgpt.project.create", dialog), "N3.empty-name-disabled.\(suffix)")
            try W214Acceptance.save(dialog, "new-project-empty-" + suffix, artifacts)
            check(setName(" \n ", dialog), "N3.type-whitespace.\(suffix)")
            await W214Acceptance.settle(dialog)
            _ = TatwoComposerModeAcceptance.press("chatgpt.project.create", in: dialog)
            check(!enabled("chatgpt.project.create", dialog) && pod.creates.isEmpty, "N3.whitespace-never-submits.\(suffix)")
            check(setName("取消用", dialog), "N4.type-before-cancel.\(suffix)")
            check(TatwoComposerModeAcceptance.press("chatgpt.project.cancel", in: dialog), "N4.close-cancels.\(suffix)")
            await W214Acceptance.settle(shot)
            check(shot.window.attachedSheet == nil && pod.creates.isEmpty, "N4.cancel-does-not-create.\(suffix)")
            _ = TatwoComposerModeAcceptance.press("chatgpt.project.new", in: shot)
            await W214Acceptance.settle(shot)
            guard let reopened = sheet(shot) else { check(false, "N4.reopen"); continue }
            dialog = reopened
            check(!enabled("chatgpt.project.create", dialog), "N4.reopen-clears-name.\(suffix)")
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: dialog.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                dialog.window.sendEvent(event)
            }
            await W214Acceptance.settle(shot)
            check(shot.window.attachedSheet == nil && pod.creates.isEmpty, "N4.escape-cancels.\(suffix)")
            _ = TatwoComposerModeAcceptance.press("chatgpt.project.new", in: shot)
            await W214Acceptance.settle(shot)
            guard let reopened = sheet(shot) else { check(false, "N5.reopen"); continue }
            dialog = reopened
            for error in ["網路連線失敗，請重試", "請先登入 ChatGPT", "名稱被拒絕，請換個名稱"] {
                check(setName("  W216 測試專案  ", dialog), "N5.type-name.\(suffix)")
                await W214Acceptance.settle(dialog)
                check(enabled("chatgpt.project.create", dialog), "N5.valid-name-enables-submit.\(suffix)")
                let count = pod.creates.count
                _ = TatwoComposerModeAcceptance.press("chatgpt.project.create", in: dialog)
                await until { pod.creates.count > count }
                _ = TatwoComposerModeAcceptance.press("chatgpt.project.create", in: dialog)
                await W214Acceptance.settle(dialog)
                check(!enabled("chatgpt.project.create", dialog) && pod.creates.count == count + 1,
                      "N5.inflight-disables-duplicate.\(suffix)")
                pod.finish(error: error)
                await W214Acceptance.settle(dialog)
                try W214Acceptance.dump(dialog, "new-project-error-" + suffix, artifacts)
                check(shot.window.attachedSheet != nil && enabled("chatgpt.project.create", dialog)
                    && W214Acceptance.text(dialog).contains(error), "N6.failure-keeps-dialog-and-retry.\(suffix)")
            }
            try W214Acceptance.save(dialog, "new-project-error-" + suffix, artifacts)
            pod.holdCatalog = true
            model.retryProjects()
            await until { !pod.pendingCatalog.isEmpty }
            _ = TatwoComposerModeAcceptance.press("chatgpt.project.create", in: dialog)
            await until { pod.creates.count == 4 }
            check(pod.creates.last?["name"] as? String == "W216 測試專案"
                && pod.creates.last?["description"] as? String == "", "N7.existing-tap-command-trims-name.\(suffix)")
            pod.finish()
            await W214Acceptance.settle(shot)
            check(shot.window.attachedSheet == nil && model.activeGPT?.id == "g-p-w216"
                && model.selectedID == nil && model.messages.isEmpty && model.page == nil,
                "N7.success-opens-empty-project.\(suffix)")
            check(model.projects.contains { $0.id == "g-p-w216" } && model.expandedProjects.contains("g-p-w216"),
                  "N7.immediate-list-and-selection.\(suffix)")
            pod.flushCatalog()
            await W214Acceptance.settle(shot)
            check(model.projects.contains { $0.id == "g-p-w216" }, "N8.stale-catalog-cannot-remove-created-project.\(suffix)")
            check(model.projects.contains { $0.id == "g-p-existing" && $0.description == "OS fixture existing-id" },
                  "N8.existing-project-mapping-preserved.\(suffix)")
            try W214Acceptance.save(shot, "new-project-created-" + suffix, artifacts)
            try W214Acceptance.dump(shot, "new-project-created-" + suffix, artifacts)
            model.draft = "專案裡的新對話"
            model.send()
            await until { !pod.sends.isEmpty }
            check(pod.sends.last?["gizmoID"] as? String == "g-p-w216", "N9.new-chat-targets-created-project.\(suffix)")
            model.stop()
        }
        return failures == 0
    }
    static func sheet(_ shot: GlobalDMChatAcceptance.Rendered) -> GlobalDMChatAcceptance.Rendered? {
        guard let window = shot.window.attachedSheet, let host = window.contentView,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        return .init(host: host, window: window, bitmap: bitmap, size: host.bounds.size)
    }
    static func enabled(_ id: String, _ shot: GlobalDMChatAcceptance.Rendered) -> Bool {
        guard let node = W214Acceptance.node(id, shot), node.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return false }
        return node.value(forKey: "accessibilityEnabled") as? Bool == true
    }
    static func setName(_ name: String, _ shot: GlobalDMChatAcceptance.Rendered) -> Bool {
        guard let field = W214Acceptance.nodes(shot).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else { return false }
        field.stringValue = name
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        return true
    }
    static func until(_ predicate: () -> Bool) async {
        for _ in 0..<100 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(20)) }
    }
    final class Pod: DispatchTapPod {
        var creates: [[String: Any]] = [], pendingCatalog: [String] = []
        var holdCatalog = false
        override init(running: Bool = false, responder: ((String, [String: Any]) -> [String: Any]?)? = nil) {
            super.init(running: running, responder: responder)
            projects = [["id": "g-p-existing", "title": "TATWO · 一般", "kind": "project", "description": "OS fixture existing-id"]]
        }
        override func respond(_ command: [String: Any], id: String, cmd: String) {
            if cmd == "createProject" { creates.append(command); return }
            if cmd == "projects", holdCatalog { pendingCatalog.append(id); return }
            super.respond(command, id: id, cmd: cmd)
        }
        func finish(error: String? = nil) {
            guard let command = creates.last, let id = command["id"] as? String else { return }
            if let error { emit(["type": "result", "id": id, "ok": false, "message": error]); return }
            let folder: [String: Any] = ["id": "g-p-w216", "title": command["name"]!, "kind": "project"]
            projects.append(folder)
            emit(["type": "result", "id": id, "ok": true, "data": folder])
        }
        func flushCatalog() {
            for id in pendingCatalog { emit(["type": "result", "id": id, "ok": true, "data": ["items": [projects[0]]]]) }
            pendingCatalog = []
        }
    }
}
#endif
