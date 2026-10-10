#if DEBUG
import AppKit
import SwiftUI

/// Synthetic keyDown events traverse NSWindow.sendEvent and the production NSTextView.
/// No text assignment, engine send, network, account, or microphone is used.
@MainActor enum W288Acceptance {
    static func run() throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_LIVE_ROOT"] else { throw CocoaError(.fileWriteNoPermission) }
        let root = URL(fileURLWithPath: path)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.selectedThreadID = engine.doc.selectedThreadID
        var checks = 0, failures = 0, sends = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1; if !ok { failures += 1 }
            print("W288 \(ok ? "PASS" : "FAIL") \(name)")
        }
        let editor = ChatComposerTextView(text: Binding(get: { model.prompt }, set: { model.prompt = $0 }),
            contentHeight: .constant(60), isFocused: true, placeholder: "測試", isMonospaced: false,
            minimumHeight: 60, maximumHeight: 120, onSubmit: { sends += 1 }, onFocusChange: { _ in },
            onSuggestionKey: { model.handleComposerSuggestionKey($0) })
        guard let shot = GlobalDMChatAcceptance.renderSync(editor, size: CGSize(width: 760, height: 140)) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { shot.window.close() }
        func textView(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(textView).first
        }
        guard let text = textView(shot.host) else { throw CocoaError(.fileReadUnknown) }
        shot.window.makeFirstResponder(text)
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shot.window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            shot.window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        func clear() { for _ in 0..<model.prompt.utf16.count { key("\u{7f}", 51) } }
        for (chars, code) in [("/", UInt16(44)), ("g", 5), ("o", 31)] { key(chars, code) }
        check(model.prompt == "/go" && model.matchingSlashCommands.map(\.cmd) == ["/goal", "/goal list"], "1 typed /go by keyDown")
        key("\r", 36)
        check(model.prompt == "/goal " && sends == 0, "1 first Return completes first suggestion without send")
        clear()
        for (chars, code) in [("/", UInt16(44)), ("g", 5), ("o", 31)] { key(chars, code) }
        key("\u{f701}", 125); key("\u{f701}", 125); key("\r", 36)
        check(model.goalCardExpanded && model.prompt.isEmpty && sends == 0, "1 arrows select goal list before Return prompt=\(model.prompt) sends=\(sends)")
        let thread = model.selectedThreadID!
        engine.onChange = { model.document = engine.document; model.isRunning = engine.isRunning(thread) }
        model.engineLoginTestDouble = [.codex, .claude]
        model.catalogRefreshTestDouble = {}
        model.chatGPTTapConnectionTestDouble = { .ready }
        model.chatGPTTapWakeTestDouble = {}
        model.goalCardExpanded = false
        let defaults = UserDefaults.standard, prior = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let sidecar = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../tests/fixtures/w288-sidecar.mjs").standardizedFileURL.path
        var overrides = prior
        overrides["tatwo2.sidecarPath.codex"] = sidecar; overrides["tatwo2.sidecarPath.claude"] = sidecar
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { engine.shutdownAll(); defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let pod = W217VoiceAcceptance.Pod("success")
        let tap = ChatGPTTap(transport: pod, connection: .ready)
        tap.voiceMicrophonePermission = { true }
        let voice = ChatGPTVoiceMode(tap: tap, holderNotice: "Coder 測試")
        voice.startTimeout = .milliseconds(100)
        voice.stopTimeout = .milliseconds(50); voice.stateTimeout = .milliseconds(50)
        voice.stopPause = .milliseconds(10)
        let artifacts = env["TATWO2_SELFTEST_ARTIFACTS"].map { URL(fileURLWithPath: $0) }
        func settle() { for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) } }
        func tree(_ shot: GlobalDMChatAcceptance.Rendered) -> [String: NSObject] { GlobalDMChatAcceptance.tree(shot) }
        func frame(_ object: NSObject?) -> CGRect? { object.flatMap { DMBrowserAcceptance.axFrame($0) } }
        func click(_ shot: GlobalDMChatAcceptance.Rendered, _ identifier: String) -> Bool {
            guard let rect = frame(tree(shot)[identifier]) else { return false }
            let point = shot.window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shot.window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApp.postEvent(event, atStart: false)
            }
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            settle(); return true
        }
        func save(_ shot: GlobalDMChatAcceptance.Rendered, _ name: String) {
            guard let captured = GlobalDMChatAcceptance.captureOwnWindow(shot) else { check(false, "UI capture \(name)"); return }
            GlobalDMChatAcceptance.save(captured, name, to: artifacts)
            check(GlobalDMChatAcceptance.ink(captured) != nil, "UI drawn \(name)")
        }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            for route in ["gpt-6.1-sol", "opus-5.5"] {
                model.selectedModel = route; model.prompt = "保留這份草稿"
                check(engine.send(threadID: thread, text: "work", model: route, engine: route == "opus-5.5" ? .claude : .codex), "2 \(route) starts isolated native turn")
                settle()
                guard let ui = GlobalDMChatAcceptance.renderSync(ChatPage(model: model, coderVoice: voice), size: CGSize(width: 840, height: 720), scheme: scheme) else { throw CocoaError(.fileReadUnknown) }
                let nodes = tree(ui), before = frame(nodes["chat-composer-stop"])
                check(nodes["chat-composer-send"] != nil && before != nil, "2 \(route) draft shows send and Stop")
                save(ui, "2-\(route)-draft-\(suffix).png")
                model.prompt = ""; settle()
                check(frame(tree(ui)["chat-composer-stop"]) == before, "2 \(route) Stop position stays fixed")
                model.prompt = "保留這份草稿"; settle()
                check(click(ui, "chat-composer-stop") && model.prompt == "保留這份草稿", "2 \(route) real Stop click preserves draft")
                check(!model.isRunning, "2 \(route) Stop confirms turn ended")
                ui.close()
            }
            model.prompt = ""; model.selectedModel = "chatgpt-tap:fixture"
            ChatGPTTapModelCatalog.replace([TapModel(id: "fixture", title: "ChatGPT 測試模型", detail: "")])
            guard let ui = GlobalDMChatAcceptance.renderSync(ChatPage(model: model, coderVoice: voice), size: CGSize(width: 840, height: 720), scheme: scheme) else { throw CocoaError(.fileReadUnknown) }
            check(tree(ui)["tatwo.coder.voice"] != nil, "3 TAP voice entry exists")
            save(ui, "3-tap-voice-\(suffix).png")
            check(click(ui, "tatwo.coder.voice") && voice.voiceLive && tree(ui)["tatwo.coder.voiceMode.stop"] != nil, "3 real voice click uses shared mode and Stop")
            check(click(ui, "tatwo.coder.voiceMode.stop") && !voice.voiceActive && !pod.live, "3 real voice Stop ends fake microphone")
            model.selectedModel = "gpt-6.1-sol"; settle()
            check(tree(ui)["tatwo.coder.voice"] == nil, "3 other models hide voice")
            check(click(ui, "w288-issue-list") && tree(ui)["w288-thread-card"] != nil, "4 Issue List opens real Thread card")
            check(click(ui, "chat-composer-model") && tree(ui)[TatwoComposerMode.cardIdentifier] != nil && tree(ui)["w288-thread-card"] == nil, "4 model click closes Thread card")
            save(ui, "4-model-panel-\(suffix).png")
            check(click(ui, "w288-issue-list") && tree(ui)[TatwoComposerMode.cardIdentifier] == nil, "4 opening Thread closes model panel")
            ui.close()
            let plan = TatwoPlanArtifactV1(threadID: thread, objective: "封存測試畫布")
            try engine.savePlanArtifact(plan); model.exitActiveCanvasMode()
            guard let archived = GlobalDMChatAcceptance.renderSync(ChatPage(model: model, coderVoice: voice), size: CGSize(width: 840, height: 720), scheme: scheme) else { throw CocoaError(.fileReadUnknown) }
            check(tree(archived)["composer-archived-canvases"] != nil, "6 archived glass chip appears")
            save(archived, "6-archived-chip-\(suffix).png")
            archived.close()
        }
        tap.sleep()
        print("W288 SUMMARY checks=\(checks) failures=\(failures)")
        return failures == 0
    }
}

extension ChatPage {
    /// Hosts the production composer and Thread overlay with installed @State.
    /// The normal workspace body starts browser lifecycle tasks, so this isolated
    /// fixture supplies only its surrounding space. All controls are production views.
    var w288ComposerFixture: some View {
        VStack {
            Button("Issue List") { infoCardFloatingOpen.toggle() }
                .accessibilityIdentifier("w288-issue-list")
            Spacer()
            composer(contentMaxWidth: 804)
        }
        .padding(18)
        .overlay {
            if infoCardFloatingOpen { chatFloatingInfoCardOverlay.accessibilityIdentifier("w288-thread-card") }
        }
    }
}
#endif
