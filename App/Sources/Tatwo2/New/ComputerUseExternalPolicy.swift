import AppKit
import ApplicationServices
import os

/// Extra restrictions for external AI, never a replacement for the native window/input protections.
enum ComputerUseExternalPolicy {
    // Apple LSApplicationCategoryType: https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype
    static let allowedCategories = [
        "public.app-category.productivity": "生產力",
        "public.app-category.graphics-design": "繪圖與設計",
        "public.app-category.photography": "攝影",
        "public.app-category.video": "影片",
        "public.app-category.music": "音樂",
        "public.app-category.education": "教育",
        "public.app-category.reference": "參考資料",
        "public.app-category.lifestyle": "生活風格"
    ]
    struct Application {
        let name: String
        let category: String?
        var categoryLabel: String { category.flatMap { allowedCategories[$0] } ?? "未分類" }
        var consentTitle: String { "ChatGPT · \(categoryLabel) · \(reasonLine(name))" }
        static func read(_ url: URL) throws -> Self {
            guard let bundle = Bundle(url: url) else { throw ComputerUseFailure("computer_external_app_category_denied") }
            return Self(name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? url.deletingPathExtension().lastPathComponent,
                        category: bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String)
        }
    }
    static let deniedIdentifiers: Set<String> = ComputerUseTarget.deniedIdentifiers.union([
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
        "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92",
        "com.apple.scripteditor2", "com.apple.automator", "com.apple.shortcuts", "com.apple.dt.xcode",
        "com.sublimetext.4", "dev.zed.zed", "com.apple.finder", "com.github.wez.wezterm",
        "com.okx.desktop", "com.ftx.desktop", "com.bybit.desktop",
        "com.binance.desktop", "com.ibkr.tws", "com.tradingview.tradingview",
        "com.coinbase.desktop", "com.chase.mobile", "com.bankofamerica.bofa",
        "com.surfshark.vpnclient.macos", "com.nordvpn.osx", "com.expressvpn.expressvpn",
        "io.tailscale.ipn.macos", "com.cloudflare.1dot1dot1dot1.macos",
        "at.obdev.littlesnitch", "com.objective-see.lulu"
    ])
    static let deniedNameFragments = [
        "terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "終端", "finder",
        "jetbrains", "intellij", "pycharm", "webstorm", "phpstorm", "rubymine", "clion", "goland",
        "datagrip", "dataspell", "rider", "rustrover", "fleet", "vscode", "visual studio code", "cursor",
        "editor", "編輯器", "textedit", "文字編輯", "textmate", "textwrangler", "bbedit", "nova", "neovim", "vim",
        "eclipse", "netbeans", "androidstudio", "android studio", "visual studio", "notepad", "ultraedit",
        "atom", "brackets", "lapce", "helix", "lite-xl",
        "keychain", "鑰匙圈", "password", "密碼", "securityagent", "system settings", "系統設定",
        "bank", "銀行", "trade", "trading", "交易", "binance", "coinbase", "ibkr", "broker",
        "wallet", "錢包", "robinhood", "fidelity", "schwab", "chase", "finance", "金融", "okx", "bybit",
        "券商", "證券", "期貨", "securities", "futures", "元大", "富邦", "凱基", "永豐", "群益",
        "國泰", "兆豐", "統一證", "玉山", "新光", "華南", "第一金", "台新", "合庫",
        "yuanta", "fubon", "kgi", "sinopac", "capital.com", "cathay", "megabank",
        "scripteditor", "automator", "shortcuts", "xcode", "emacs", "sublime", "zed", "powershell",
        "safari", "chrome", "firefox", "browser", "brave", "opera", "orion",
        "surfshark", "nordvpn", "expressvpn", "tailscale", "cloudflare warp", "little snitch", "littlesnitch", "lulu", "vpn"
    ]
    // External browsers require a separately verifiable page-security boundary. Desktop AX cannot
    // guarantee that an opaque/canvas login or banking page is safe, so fail closed for now.
    static let deniedBrowserIdentifiers: Set<String> = [
        "com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.browser", "com.brave.browser", "com.operasoftware.opera"
    ]
    static let sensitiveFragments = [
        "pairing", "配對", "授權", "authorization", "oauth", "login", "log in", "sign in", "登入",
        "password", "密碼", "privacy", "隱私", "security", "安全性", "bank", "銀行",
        "api key", "secret", "token", "private key", "鑰匙圈", "keychain", "允許", "核准"
    ]

    static func target(_ id: String, name: String = "") throws -> ComputerUseTarget {
        let requested = try ComputerUseTarget.requested(id, allowSelf: false)
        let resolved = try requested.resolve()
        let application = try Application.read(resolved.url)
        return try validateApplication(id, name: application.name + " " + name, category: application.category)
    }

    static func validateApplication(_ id: String, name: String, category: String?) throws -> ComputerUseTarget {
        let target = try ComputerUseTarget.requested(id, allowSelf: false)
        let normalized = id.lowercased()
        guard !deniedIdentifiers.contains(normalized), !deniedBrowserIdentifiers.contains(normalized),
              !deniedNameFragments.contains(where: (id + " " + reasonLine(name)).lowercased().contains) else {
            throw ComputerUseFailure("computer_external_app_denied")
        }
        guard let category, allowedCategories[category] != nil else {
            throw ComputerUseFailure("computer_external_app_category_denied")
        }
        return target
    }

    static func safe(role: String, text: String) -> Bool {
        role != "AXWebArea" && !ComputerUseNative.isSecure(role: role, subrole: nil)
            && !sensitiveFragments.contains(where: text.lowercased().contains)
            && !HandsSecretFiles.isSecret(path: text)
            && !TatwoMemoryStore.containsSecret(text)
            && HandsSecretLines.maskText(text) == text
    }

    static let protectedWindowTitleFragments = [
        "memory", "user.md", "os.md", ".ssh", "id_ed25519", "id_rsa", "id_ecdsa", "id_dsa", "auth.json",
        "金鑰", "私鑰", "密鑰", "private key", "private_key", "ssh key", "api key", "api_key", "credentials", ".pem", ".p12", ".pfx"
    ]

    static func windowTitleAllowed(_ title: String) -> Bool {
        let normalized = reasonLine(title).lowercased()
        return !protectedWindowTitleFragments.contains(where: normalized.contains)
    }

    static func documentAllowed(_ value: String?, runtime: HandsRuntime = .current()) -> Bool {
        guard let value else { return true }
        let decoded: String
        if value.hasPrefix("/") { decoded = value }
        else if value.hasPrefix("~/") { decoded = runtime.home + String(value.dropFirst()) }
        else {
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return false }
            decoded = url.path
        }
        guard decoded.hasPrefix("/"), !decoded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        guard let path = canonicalDocumentPath(decoded) else { return false }
        let engines = EnginePaths(environment: runtime.environment)
        var roots = runtime.deniedDirectories + [runtime.paths.root.path, engines.enginesRoot.path]
        roots += [".codex", ".claude", ".gemini", ".grok", ".config/opencode", ".config/aider"].map { runtime.home + "/" + $0 }
        roots += [runtime.entryRoot, runtime.workspaceEntry].compactMap { $0 }
        for key in ["CODEX_HOME", "TATWO2_CODEX_SOURCE_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
                    "GEMINI_CLI_HOME", "GROK_HOME", "XDG_CONFIG_HOME", "TATWO2_OS_ROOT", "TATWO2_ENGINES_ROOT"] {
            if let root = runtime.environment[key], root.hasPrefix("/") { roots.append(root) }
        }
        return !HandsSecretFiles.isSecret(path: decoded) && !HandsSecretFiles.isSecret(path: path)
            && !(roots + runtime.deniedFiles).contains { root in
                guard let protected = canonicalDocumentPath(root) else { return true }
                return path == protected || path.hasPrefix(protected + "/")
            }
    }

    private static func canonicalDocumentPath(_ value: String, depth: Int = 0) -> String? {
        guard depth < 32 else { return nil }
        var ancestor = value, tail: [String] = []
        while true {
            if let real = HandsPath.realpath(ancestor) {
                // Never re-standardize realpath output: macOS drops a leading /private only when the path exists,
                // so an existing protected root and a not-yet-existing document under it would stop matching.
                var parts = real.split(separator: "/").map(String.init)
                for component in tail.reversed() where !component.isEmpty && component != "." {
                    if component == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(component) }
                }
                return ("/" + parts.joined(separator: "/")).lowercased()
            }
            // realpath requires the final file to exist. Resolve existing parents and even broken
            // links explicitly, so an absent document under a protected root cannot use an alias.
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor) {
                let target = link.hasPrefix("/") ? link : (ancestor as NSString).deletingLastPathComponent + "/" + link
                let rewritten = tail.reversed().reduce(URL(fileURLWithPath: target)) { $0.appendingPathComponent($1) }.path
                return canonicalDocumentPath(rewritten, depth: depth + 1)
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != ancestor else { return nil }
            tail.append((ancestor as NSString).lastPathComponent)
            ancestor = parent
        }
    }

    static func reasonLine(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return ![0x034F, 0x180B, 0x180C, 0x180D].contains($0.value)
                && !(0xFE00...0xFE0F).contains($0.value) && !(0xE0100...0xE01EF).contains($0.value)
            }
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pasteCommand(_ label: String, commandCharacter: String? = nil,
                             commandModifiers: Int? = nil, commandVirtualKey: Int? = nil) -> Bool {
        let normalized = reasonLine(label).lowercased()
        return normalized.contains("paste") || normalized.contains("貼上") || normalized.contains("粘贴")
            || normalized.contains("黏貼") || normalized.contains("粘貼")
            || ((commandCharacter?.lowercased() == "v" || commandVirtualKey == 9)
                && commandModifiers.map { $0 & 8 == 0 } == true)
    }

    static func validateRequest(_ request: ComputerUseNative.Request) throws {
        if case .pressKey(let key) = request, key.code == 9, key.flags.contains(.maskCommand) {
            throw ComputerUseFailure("computer_external_paste_denied")
        }
    }

    static func requireNoPasteCommand(_ label: String, commandCharacter: String? = nil,
                                     commandModifiers: Int? = nil, commandVirtualKey: Int? = nil) throws {
        guard !pasteCommand(label, commandCharacter: commandCharacter, commandModifiers: commandModifiers,
                            commandVirtualKey: commandVirtualKey) else {
            throw ComputerUseFailure("computer_external_paste_denied")
        }
    }

    static func requireBackgroundPointer(_ available: Bool) throws {
        guard available else { throw ComputerUseFailure("computer_external_hid_fallback_denied") }
    }

    static func requireNoPendingApproval(_ pending: Bool) throws {
        guard !pending else { throw ComputerUseFailure("computer_external_pending_approval_denied") }
    }

    /// Preserve grapheme boundaries and CGEvent's UTF-16 budget; shared with the fake sender.
    static func textChunks(_ text: String, maxUTF16: Int) -> [String] {
        var chunks: [String] = [], chunk = "", units = 0
        for character in text {
            let size = String(character).utf16.count
            if units + size > maxUTF16, !chunk.isEmpty { chunks.append(chunk); chunk = ""; units = 0 }
            chunk.append(character); units += size
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    @MainActor static var approvalPending: Bool {
        !IslandNotice.shared.pendingRequestIDs.isEmpty
            || (IslandNotice.shared.current.map { $0.kind != .info } ?? false)
            || NSApp?.modalWindow != nil
            || (NSApp?.windows.contains { $0.isVisible && $0.attachedSheet != nil } ?? false)
    }

    /// A fresh bounded MainActor query for every dispatch. No session lock is held while waiting;
    /// an unavailable UI thread refuses input, and Stop can always revoke the native epoch.
    static func checkPendingApproval() throws {
        if Thread.isMainThread {
            try MainActor.assumeIsolated { try requireNoPendingApproval(approvalPending) }
            return
        }
        let answer = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            answer.withLock { $0 = approvalPending }
            ready.signal()
        }
        guard ready.wait(timeout: .now() + 0.25) == .success, let pending = answer.withLock({ $0 }) else {
            throw ComputerUseFailure("computer_external_approval_unverifiable")
        }
        try requireNoPendingApproval(pending)
    }

    static func validateDestination(_ node: AXUIElement, deadline: TimeInterval) throws {
        var current: AXUIElement? = node
        for _ in 0..<8 {
            guard let element = current else { return }
            let title = try ComputerUseNative.attribute(element, kAXTitleAttribute, deadline: deadline) as? String ?? ""
            let description = try ComputerUseNative.attribute(element, kAXDescriptionAttribute, deadline: deadline) as? String ?? ""
            let identifier = try ComputerUseNative.attribute(element, kAXIdentifierAttribute, deadline: deadline) as? String ?? ""
            try requireNoPasteCommand(title + " " + description + " " + identifier,
                commandCharacter: try ComputerUseNative.attribute(element, "AXMenuItemCmdChar", deadline: deadline) as? String,
                commandModifiers: try ComputerUseNative.attribute(element, "AXMenuItemCmdModifiers", deadline: deadline) as? Int,
                commandVirtualKey: try ComputerUseNative.attribute(element, "AXMenuItemCmdVirtualKey", deadline: deadline) as? Int)
            current = ComputerUseNative.element(try ComputerUseNative.attribute(element, kAXParentAttribute, deadline: deadline))
        }
    }

    static func focusOwnerAllowed(owner: Int32, target: Int32) -> Bool {
        owner == target && target > 1 && target != ProcessInfo.processInfo.processIdentifier
    }

    static func validate(_ state: ComputerUseNative.State, runtime: HandsRuntime = .current()) throws {
        try requireNoPendingApproval(state.pendingDialog || state.nodes.contains { $0.role == kAXSheetRole })
        // Return/Space can activate a selected menu command without clicking it. Refuse an open
        // menu containing Paste before any keyboard navigation or activation can dispatch.
        for node in state.nodes where node.inOpenMenu {
            try requireNoPasteCommand(node.title + " " + (node.value ?? "") + " " + node.actions.joined(separator: " "))
        }
        guard !state.busy, !state.truncated, state.window != nil, !state.nodes.isEmpty,
              safe(role: "", text: state.title), windowTitleAllowed(state.title),
              documentAllowed(state.documentURL, runtime: runtime),
              documentAllowed(state.representedURL, runtime: runtime),
              state.windows.allSatisfy({ safe(role: "", text: $0.title) && windowTitleAllowed($0.title)
                  && documentAllowed($0.documentURL, runtime: runtime) && documentAllowed($0.representedURL, runtime: runtime) }),
              state.nodes.allSatisfy({ safe(role: $0.role, text: $0.title + " " + ($0.value ?? "")) }) else {
            throw ComputerUseFailure("computer_external_sensitive_or_unverifiable_page")
        }
        guard let bundle = state.bundleIdentifier else { throw ComputerUseFailure("computer_target_denied") }
        _ = try validateApplication(bundle, name: state.appName, category: state.applicationCategory)
    }

    /// System security agents or an out-of-process focused element are never an input destination.
    static func preflight(pid: Int32, deadline: TimeInterval) throws {
        try checkPendingApproval()
        let app = AXUIElementCreateApplication(pid)
        if let focus = ComputerUseNative.element(try ComputerUseNative.attribute(app, kAXFocusedUIElementAttribute, deadline: deadline)) {
            var owner: pid_t = 0
            guard AXUIElementGetPid(focus, &owner) == .success, focusOwnerAllowed(owner: owner, target: pid) else {
                throw ComputerUseFailure("computer_external_system_dialog_denied")
            }
            try ComputerUseNative.requireNonSecure(
                role: ComputerUseNative.attribute(focus, kAXRoleAttribute, deadline: deadline) as? String,
                subrole: ComputerUseNative.attribute(focus, kAXSubroleAttribute, deadline: deadline) as? String)
            try validateDestination(focus, deadline: deadline)
        }
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
              let id = running.bundleIdentifier else { throw ComputerUseFailure("computer_target_closed") }
        let target = try target(id, name: running.localizedName ?? "")
        try validate(ComputerUseNative.read(pid: pid, expectedTarget: target, deadline: deadline, externalAI: true))
    }
}
