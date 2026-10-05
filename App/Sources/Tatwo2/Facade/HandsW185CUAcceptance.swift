#if DEBUG
import AppKit
import ApplicationServices

/// CU-only fixtures: production policy/parser/epoch gates, no native AX queries or GUI events.
enum HandsW185CUAcceptance {
    @MainActor final class Backend: HandsComputerBackend {
        let session = ComputerUseSession()
        let prompt = IslandNotice(fallback: { _, _, _ in nil }, holdOpen: { _ in }, log: { _ in })
        let runtime: HandsRuntime
        let bundleURL: URL
        var pendingApproval = false
        var backgroundAvailable = true
        var commandLabel = "Example button"
        var commandCharacter: String?
        var commandModifiers: Int?
        var windowTitle = "Example document"
        var otherWindowTitle: String?
        var document: String?
        var represented: String?
        var dialog = false
        var fieldRole = "AXTextField"
        var text = ""
        var chunks: [String] = []
        var dispatched = 0
        var afterChunk: (() -> Void)?
        init(runtime: HandsRuntime, bundleURL: URL) {
            self.runtime = runtime; self.bundleURL = bundleURL; prompt.hostAvailable = true
        }
        func application(_ id: String) throws -> ComputerUseExternalPolicy.Application {
            try .read(bundleURL)
        }
        func state() -> ComputerUseNative.State {
            let element = AXUIElementCreateApplication(12345) // opaque handle only; never queried
            return .init(pid: 12345, appName: "Example", bundleIdentifier: "com.example.productivity", launchDate: nil,
                window: element, frame: .init(x: 0, y: 0, width: 100, height: 100), title: windowTitle,
                windows: otherWindowTitle.map { [.init(element: element, title: $0, frame: .init(x: 0, y: 0, width: 100, height: 100), isFocused: false)] } ?? [], elements: [element], nodes: [.init(depth: 0, role: fieldRole, title: "Example field",
                    value: text, frame: nil, actions: ["AXPress"], focused: true, disabled: false)],
                truncated: text.count > 4096, documentURL: document, representedURL: represented,
                applicationCategory: "public.app-category.productivity", pendingDialog: dialog)
        }
        func start(owner: UUID, scope: String, app: String, consent: ComputerUseController.ExternalConsent,
                   valid: @escaping @MainActor () -> Bool) async throws -> ComputerUseSession.Grant {
            let metadata = try application(app)
            let epoch = session.currentEpoch
            let decision = await prompt.ask(title: metadata.consentTitle, detail: metadata.categoryLabel + " · " + consent.reason,
                allowLabel: "允許", timeout: 2, requestID: consent.requestID)
            guard decision == .allow, valid() else { throw ComputerUseFailure("computer_external_denied") }
            return try session.authorize(owner: owner, scope: scope, pid: 12345, expectedEpoch: epoch,
                expiresAt: ProcessInfo.processInfo.systemUptime + 60)
        }
        func perform(_ method: String, params: [String: Any], grant: ComputerUseSession.Grant,
                     valid: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
            func check() throws {
                guard valid() else { throw ComputerUseFailure("expired") }
                try session.validate(grant)
                try ComputerUseExternalPolicy.requireNoPendingApproval(pendingApproval || !prompt.pendingRequestIDs.isEmpty)
                try ComputerUseExternalPolicy.validate(state(), runtime: runtime)
            }
            try check()
            if method == "computer_observe" {
                let observed = try session.publish(fingerprint: "", for: grant, elements: state().elements, state: state())
                return ["observationID": observed.id.uuidString]
            }
            let request = try ComputerUseNative.request(action: params["action"] as? String ?? "", params: params)
            try ComputerUseExternalPolicy.validateRequest(request)
            let observed = try session.beginAction(observationID: params["observationID"] as? String ?? "", fingerprint: "", for: grant)
            defer { session.endAction(observationID: observed.id, for: grant) }
            try ComputerUseExternalPolicy.requireNoPasteCommand(commandLabel, commandCharacter: commandCharacter,
                commandModifiers: commandModifiers)
            if case .pointer = request { try ComputerUseExternalPolicy.requireBackgroundPointer(backgroundAvailable) }
            if case .typeText(let value) = request {
                var sent = 0
                for chunk in ComputerUseExternalPolicy.textChunks(value, maxUTF16: 300) {
                    try check()
                    try session.dispatch(observationID: observed.id, for: grant) {
                        chunks.append(chunk); text += chunk; sent += chunk.count; dispatched += 1
                    }
                    afterChunk?()
                }
                return ["dispatched": true, "sent_characters": sent]
            }
            try check()
            try session.dispatch(observationID: observed.id, for: grant) { dispatched += 1 }
            return ["dispatched": true]
        }
        func stop(owner: UUID) {
            if let current = prompt.current { prompt.resolve(.cancel, id: current.id) }
            session.stop(owner: owner)
        }
    }

    @MainActor static func run(service: HandsService, grant: String, landing: HandsProjectLanding,
                               base: URL) async throws -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W185CU \(condition ? "PASS" : "FAIL") \(name)")
        }
        func refuses(_ code: String? = nil, _ work: () throws -> Void) -> Bool {
            do { try work(); return false } catch {
                return code == nil || (error as? ComputerUseFailure)?.code == code
            }
        }
        let safeCategory = "public.app-category.productivity"
        for category in [nil, "public.app-category.utilities", "public.app-category.finance", "public.app-category.developer-tools", "public.app-category.sample"] as [String?] {
            check(refuses("computer_external_app_category_denied") {
                _ = try ComputerUseExternalPolicy.validateApplication("com.example.app", name: "Example", category: category)
            }, category == nil ? "category_missing" : "category_unlisted_\(category!)")
        }
        for (id, name) in [("com.example.wezterm", "Example"), ("com.example.jetbrains.sample", "Example"),
                           ("com.example.app", "PyCharm"), ("com.example.finder", "Example"),
                           ("com.example.okx", "Example"), ("com.example.app", "台灣券商"),
                           ("com.example.app", "元大證券"), ("com.example.editor", "Example"),
                           ("com.example.browser", "Example")] {
            check(refuses("computer_external_app_denied") {
                _ = try ComputerUseExternalPolicy.validateApplication(id, name: name, category: safeCategory)
            }, "explicit_app_denial_\(id)_\(name)")
        }
        for name in ["Surfshark", "NordVPN", "ExpressVPN", "Tailscale", "Cloudflare WARP", "Little Snitch", "LuLu"] {
            check(refuses("computer_external_app_denied") {
                _ = try ComputerUseExternalPolicy.validateApplication("com.example.productivity", name: name, category: safeCategory)
            }, "M4 network tool refused \(name)")
        }
        for category in ComputerUseExternalPolicy.allowedCategories.keys {
            check(!refuses { _ = try ComputerUseExternalPolicy.validateApplication("com.example.sample", name: "Example", category: category) },
                  "category_allow_\(category)")
        }
        let bundleURL = base.appendingPathComponent("Example.app")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        func metadata(_ category: String?) throws {
            var plist: [String: Any] = ["CFBundleIdentifier": "com.example.productivity", "CFBundleName": "Example", "CFBundlePackageType": "APPL"]
            plist["LSApplicationCategoryType"] = category
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        try metadata(safeCategory)
        let readApplication = try ComputerUseExternalPolicy.Application.read(bundleURL)
        check(readApplication.name == "Example" && readApplication.category == safeCategory, "bundle_category_read_from_plist")
        let backend = Backend(runtime: service.runtime, bundleURL: bundleURL)
        for title in ["memory", "USER.MD", "os.md", ".ssh", "id_ed25519", "auth.json", "金鑰", "私鑰", "密鑰", "user.\u{200B}md"] {
            backend.windowTitle = "Example · " + title
            check(refuses("computer_external_sensitive_or_unverifiable_page") {
                try ComputerUseExternalPolicy.validate(backend.state(), runtime: service.runtime)
            }, "M4 protected window title without AXDocument refused \(title)")
            backend.windowTitle = "Example document"
            backend.otherWindowTitle = "Example · " + title
            check(refuses("computer_external_sensitive_or_unverifiable_page") {
                try ComputerUseExternalPolicy.validate(backend.state(), runtime: service.runtime)
            }, "M4 other protected window without AXDocument refused \(title)")
            backend.otherWindowTitle = nil
        }
        check(!refuses { try ComputerUseExternalPolicy.validate(backend.state(), runtime: service.runtime) }, "M4 ordinary fixture window stays allowed")
        let manager = HandsComputerUse(backend: backend)
        defer { manager.stop() }
        func wait(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<100 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
            return false
        }
        let unsafeReason = "Example\u{2028}\u{2029}\u{202A}\u{202E}\u{2066}\u{2069}\u{200B}\u{200D}\u{FEFF}\n\t\u{0000} reason"
        check(ComputerUseExternalPolicy.reasonLine(unsafeReason) == "Example reason", "reason_invisible_controls_removed")
        check(ComputerUseExternalPolicy.reasonLine("\u{2028}\u{202E}\u{200B}").isEmpty, "reason_empty_after_filter")
        _ = try manager.request(app: "com.example.productivity", reason: unsafeReason, minutes: 1, landing: landing, grant: grant, service: service)
        _ = await wait { backend.prompt.current != nil }
        check(backend.prompt.current?.detail == "生產力 · Example reason" && backend.prompt.current?.title == "ChatGPT · 生產力 · Example", "consent_name_category_sanitized_reason")
        backend.prompt.resolve(.allow, id: backend.prompt.current?.id ?? UUID())
        check(await wait { manager.current?.state == .allowed }, "safe_category_host_allow")
        func observe() async throws -> [String: Any] { try await manager.perform("computer_observe", arguments: [:], grant: grant, service: service) }
        func action(_ arguments: [String: Any]) async throws -> [String: Any] {
            var arguments = arguments
            arguments["observationID"] = try await observe()["observationID"]
            return try await manager.perform("computer_action", arguments: arguments, grant: grant, service: service)
        }
        let initial = backend.dispatched
        _ = try await action(["action": "click", "element": 0])
        check(backend.dispatched == initial + 1, "safe_observe_click")
        let longText = String(repeating: "x", count: 500)
        let typed = try await action(["action": "type", "text": longText])
        check(backend.text == longText && backend.chunks.map(\.count) == [300, 200]
              && typed["sent_characters"] as? Int == 500, "type_500_chunked_complete_count")
        check(!refuses { try ComputerUseExternalPolicy.validate(backend.state(), runtime: service.runtime) }, "post_type_500_observation_allowed")
        check(ComputerUseNative.observedValue(role: "AXTextField", subrole: nil, limit: 4096, read: { longText as CFString }) == longText,
              "external_value_4096_budget")
        check(ComputerUseNative.observedValue(role: "AXTextField", subrole: nil, read: { longText as CFString })?.count == 300,
              "native_value_300_unchanged")
        for size in [4096, 4097] {
            check(refuses { _ = try ComputerUseNative.request(action: "type_text", params: ["text": String(repeating: "x", count: size)]) } == (size > 4096),
                  "type_utf16_limit_\(size)")
        }
        let unicode = String(repeating: "測試👩🏽‍💻", count: 90)
        let chunks = ComputerUseExternalPolicy.textChunks(unicode, maxUTF16: 20)
        check(chunks.joined() == unicode && chunks.allSatisfy { $0.utf16.count <= 20 }, "unicode_grapheme_chunks")
        func actionRefused(_ name: String, arguments: [String: Any], code: String) async throws {
            let observation = try await observe()
            let before = backend.dispatched
            var arguments = arguments; arguments["observationID"] = observation["observationID"]
            do { _ = try await manager.perform("computer_action", arguments: arguments, grant: grant, service: service); check(false, name) }
            catch { check((error as? ComputerUseFailure)?.code == code && backend.dispatched == before, name) }
        }
        for keys in ["cmd+v", "shift+cmd+v", "option+shift+cmd+v"] {
            try await actionRefused("paste_key_\(keys)", arguments: ["action": "key", "keys": keys], code: "computer_external_paste_denied")
        }
        for label in ["Paste", "Paste and Match Style", "貼上", "貼上並符合樣式", "Pa\u{200B}ste"] {
            backend.commandLabel = label
            for arguments: [String: Any] in [["action": "click", "element": 0], ["action": "perform_ax_action", "element": 0, "name": kAXPressAction]] {
                try await actionRefused("paste_menu_ax_\(label)_\(arguments["action"]!)", arguments: arguments, code: "computer_external_paste_denied")
            }
        }
        backend.commandLabel = "Example"; backend.commandCharacter = "v"; backend.commandModifiers = 3
        try await actionRefused("paste_unnamed_ax_shortcut", arguments: ["action": "click", "element": 0], code: "computer_external_paste_denied")
        backend.commandCharacter = nil; backend.commandModifiers = nil
        let menuElement = AXUIElementCreateApplication(12345)
        let menuState = ComputerUseNative.State(pid: 12345, appName: "Example", bundleIdentifier: "com.example.productivity",
            launchDate: nil, window: menuElement, frame: .zero, title: "Example", windows: [], elements: [menuElement],
            nodes: [.init(depth: 0, role: "AXMenuItem", title: "Paste", value: nil, frame: nil, actions: ["AXPress"],
                focused: true, disabled: false, inOpenMenu: true)], truncated: false, applicationCategory: safeCategory)
        check(refuses("computer_external_paste_denied") { try ComputerUseExternalPolicy.validate(menuState, runtime: service.runtime) },
              "paste_open_menu_keyboard_activation_refused")
        backend.backgroundAvailable = false
        try await actionRefused("hid_only_pointer_refused", arguments: ["action": "click", "x": 10, "y": 10], code: "computer_external_hid_fallback_denied")
        backend.backgroundAvailable = true
        let pendingObservation = try await observe(), beforePending = backend.dispatched
        backend.pendingApproval = true
        do {
            _ = try await manager.perform("computer_action", arguments: ["action": "click", "element": 0, "observationID": pendingObservation["observationID"] ?? ""], grant: grant, service: service)
            check(false, "pending_approval_dispatch_refused")
        } catch { check((error as? ComputerUseFailure)?.code == "computer_external_pending_approval_denied" && backend.dispatched == beforePending, "pending_approval_dispatch_refused") }
        backend.pendingApproval = false
        backend.dialog = true
        do { _ = try await observe(); check(false, "pending_target_dialog_refused") }
        catch { check(true, "pending_target_dialog_refused") }
        backend.dialog = false
        let entry = service.runtime.entryRoot!
        let deniedDocuments = [entry + "/memory/example.md", entry + "/user.md", entry + "/os.md",
            service.runtime.paths.root.path + "/state/example.json", service.runtime.home + "/.ssh/config",
            service.runtime.home + "/.codex/config.toml", service.runtime.home + "/.claude/settings.json",
            service.runtime.home + "/.gemini/settings.json", service.runtime.environment["CODEX_HOME"]! + "/config.toml"]
        let documentObservation = try await observe(), beforeDocument = backend.dispatched
        backend.document = URL(fileURLWithPath: entry + "/memory/example.md").absoluteString
        do {
            _ = try await manager.perform("computer_action", arguments: ["action": "click", "element": 0,
                "observationID": documentObservation["observationID"] ?? ""], grant: grant, service: service)
            check(false, "protected_document_action_refused")
        } catch { check(backend.dispatched == beforeDocument, "protected_document_action_refused") }
        for (index, document) in deniedDocuments.enumerated() {
            backend.document = URL(fileURLWithPath: document).absoluteString
            do { _ = try await observe(); check(false, "protected_document_observe_\(index)") }
            catch { check(true, "protected_document_observe_\(index)") }
            check(!ComputerUseExternalPolicy.documentAllowed(backend.document, runtime: service.runtime), "protected_document_path_\(index)")
        }
        backend.document = nil; backend.represented = URL(fileURLWithPath: entry + "/user.md").absoluteString
        do { _ = try await observe(); check(false, "represented_file_observe_refused") }
        catch { check(true, "represented_file_observe_refused") }
        backend.represented = nil
        check(!ComputerUseExternalPolicy.documentAllowed(ComputerUseNative.documentReference(URL(fileURLWithPath: entry + "/user.md") as CFURL),
                runtime: service.runtime), "represented_cfurl_refused")
        check(!ComputerUseExternalPolicy.documentAllowed(ComputerUseNative.documentReference(NSNumber(value: 1)), runtime: service.runtime),
              "unverifiable_document_type_refused")
        let link = base.appendingPathComponent("example-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: entry))
        check(!ComputerUseExternalPolicy.documentAllowed(link.appendingPathComponent("user.md").absoluteString, runtime: service.runtime), "protected_document_symlink_refused")
        let brokenLink = base.appendingPathComponent("sample-link")
        try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: URL(fileURLWithPath: entry + "/missing-folder"))
        check(!ComputerUseExternalPolicy.documentAllowed(brokenLink.appendingPathComponent("sample.txt").absoluteString, runtime: service.runtime),
              "protected_broken_symlink_refused")
        // A protected root under /private (temp folders) must still cover documents that do not exist yet.
        let privateRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("w185cu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        var privateRuntime = service.runtime
        privateRuntime.entryRoot = privateRoot.path
        check(!ComputerUseExternalPolicy.documentAllowed(privateRoot.appendingPathComponent("missing.md").absoluteString, runtime: privateRuntime),
              "protected_private_root_missing_document_refused")
        check(!ComputerUseExternalPolicy.documentAllowed("/tmp/\(privateRoot.lastPathComponent)/missing.md", runtime: privateRuntime),
              "protected_tmp_alias_missing_document_refused")
        try? FileManager.default.removeItem(at: privateRoot)
        check(!ComputerUseExternalPolicy.documentAllowed("https://example.invalid/sample", runtime: service.runtime), "nonlocal_document_refused")
        check(ComputerUseExternalPolicy.documentAllowed(base.appendingPathComponent("sample.txt").absoluteString, runtime: service.runtime), "ordinary_document_allowed")
        backend.fieldRole = "AXSecureTextField"
        do { _ = try await observe(); check(false, "secure_field_observe_refused") }
        catch { check(true, "secure_field_observe_refused") }
        backend.fieldRole = "AXTextField"
        // Inject a pending approval between chunks; only the first chunk may be sent.
        backend.text = ""; backend.chunks = []
        backend.afterChunk = { backend.pendingApproval = true }
        do { _ = try await action(["action": "type", "text": longText]); check(false, "pending_between_chunks_refused") }
        catch { check(backend.chunks.map(\.count) == [300], "pending_between_chunks_refused") }
        backend.pendingApproval = false; backend.afterChunk = nil
        backend.text = ""; backend.chunks = []
        backend.afterChunk = { manager.stop() }
        do { _ = try await action(["action": "type", "text": longText]); check(false, "stop_between_chunks_fences_input") }
        catch { check(backend.chunks.map(\.count) == [300] && manager.current?.state == .expired, "stop_between_chunks_fences_input") }
        print("W185CU SUMMARY passed=\(passed) failures=\(failed)")
        return (passed, failed)
    }
}
#endif
