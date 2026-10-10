#if DEBUG
import Foundation
import SwiftUI
import AppKit

@MainActor enum W236SigilsAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else { throw CocoaError(.fileReadNoPermission) }
        let registry = OSMCPRegistry(environment: env), root = registry.root.appendingPathComponent("w236-fixture")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ label: String) { print("W236SIGILS \(ok ? "PASS" : "FAIL") \(label)"); if ok { passed += 1 } else { failed += 1 } }
        func write(_ text: String, _ file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let config = registry.paths.codexHome.appendingPathComponent("config.toml")
        try write("[mcp_servers.engineOnly]\ncommand = '/missing/engine-only'\nargs = []\n[mcp_servers.imported]\ncommand = '/missing/imported'\nargs = []\n", config)
        try write("---\nname: tatwo-ultrawork\ndescription: 分工、施工單、驗收\n---\nFixture skill.\n", registry.paths.codexHome.appendingPathComponent("skills/tatwo-ultrawork/SKILL.md"))
        let script = root.appendingPathComponent("coder.mjs"), log = root.appendingPathComponent("sends.jsonl")
        try write(#"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args=process.argv.slice(2), cwd=args[args.indexOf('--cwd')+1];
        const emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line);
          if(c.op==='send') {
            fs.appendFileSync(cwd+'/sends.jsonl',JSON.stringify(c)+'\n');
            emit({type:'system',subtype:'init',session_id:'w236-'+process.pid,model:'gpt-6.1-sol'});
            emit({type:'system',subtype:'turn_accepted',client_turn_id:c.uuid});
            emit({type:'stream_event',client_turn_id:c.uuid,event:{type:'content_block_delta',delta:{type:'text_delta',text:'我看過這串的方向。'}}});
            emit({type:'result',client_turn_id:c.uuid,subtype:'success',is_error:false,result:'我看過這串的方向。'});
          } else if(c.op==='close') process.exit(0);
        }).on('close',()=>process.exit(0));
        """#, script)
        let defaults = UserDefaults.standard, previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous
        overrides["tatwo2.sidecarPath.codex"] = script.path; overrides["tatwo2.sidecarPath.claude"] = script.path
        overrides[GroupCoderBridge.flag] = false
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let tap = W185FakeConversationTap(), catalog = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(try await tap.models().items)
        defer { ChatGPTTapModelCatalog.replace(catalog) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "W236 Fixture", workdir: root.path)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.engineLoginTestDouble = [.codex, .claude]
        await model.reloadPluginRegistry()?.value
        let id = engine.newThread(in: project); model.document = engine.document; model.selectedThreadID = id
        engine.onChange = { [weak model, weak engine] in
            guard let model, let engine else { return }; model.document = engine.document
            model.isRunning = engine.isRunning(model.selectedThreadID); model.objectWillChange.send()
        }
        engine.groupBridge.taps.append(GroupTapAdapter(id: "Future", unavailable: { "未連線" }, invoke: { _, _, _ in }, stop: { _ in }))
        let issue = TatwoIssueListEntryV1(id: "w236-issue", title: "#212 登入頁更新卡找不到", body: "fixture", sourceReference: "212", threadReference: id.uuidString)
        try engine.addIssueChecked(threadID: id, entry: issue)
        model.issueListEntries = [issue]
        for (symbol, title, first) in [("@", "MCP 工具", "TATWO OS"), ("$", "Skillet 技能", "ultrawork"), ("!", "Issue List", issue.title), ("@@", "TAP（拉進這串一起討論）", "ChatGPT")] {
            model.prompt = symbol
            check(model.composerSigil?.title == title && model.composerSigilItems.first?.name == first, "\(symbol) title and first item")
        }
        model.prompt = "@"
        check(model.issueAtMentionMatches.isEmpty && !model.composerSigilItems.contains { $0.name == issue.title }, "@ no longer opens Issue")
        model.prompt = "!212"
        check(model.handleComposerSuggestionKey(.commit) && model.focusedIssueEntryID == issue.id && model.requestOpenInfoCard && model.prompt.isEmpty, "! Enter pins original Issue")
        var duplicate = TatwoIssueListEntryV1(id: "w236-second", title: issue.title, body: "second", sourceReference: issue.sourceReference, threadReference: id.uuidString)
        duplicate.status = issue.status
        model.issueListEntries = [issue, duplicate]; model.prompt = "!"
        _ = model.handleComposerSuggestionKey(.next); _ = model.handleComposerSuggestionKey(.commit)
        check(model.focusedIssueEntryID == duplicate.id, "same source and title still selects the requested Issue")
        model.issueListEntries = [issue]
        model.prompt = "!not-an-issue"
        check(!model.handleComposerSuggestionKey(.commit), "unmatched Issue preserves ordinary Enter behavior")
        for query in ["@tatwo", "@os"] {
            model.prompt = query
            check(model.composerSigilItems.first?.name == "TATWO OS", "\(query) finds TATWO OS")
            check(model.handleComposerSuggestionKey(.commit) && model.prompt == "@TATWO OS " && model.composerMarkers == ["@TATWO OS"], "\(query) canonical marker")
        }
        model.prompt = "@"
        check(!model.composerSigilItems.contains { $0.name == "engineOnly" || $0.name == "imported" }, "engine-only MCPs excluded")
        try registry.bringIn(registry.scan().items.filter { $0.sourceName == "imported" })
        check(model.composerSigilItems.contains { $0.name == "imported" } && !model.composerSigilItems.contains { $0.name == "engineOnly" }, "OS import appears without importing other engine MCP")
        check(model.handleComposerSuggestionKey(.next) && model.issueMentionSelectedIndex == 1, "shared Down advances default first selection")
        check(model.handleComposerSuggestionKey(.prev) && model.issueMentionSelectedIndex == 0, "shared Up returns to first selection")
        model.dismissComposerSigil()
        check(model.composerSigil == nil && model.prompt == "@", "Esc dismiss preserves draft")
        model.prompt = "$ultrawork"
        check(model.handleComposerSuggestionKey(.commit) && model.prompt == "$ultrawork " && model.composerMarkers == ["$ultrawork"], "$ultrawork marker")
        model.prompt = "@@"
        check(model.composerSigilItems.map(\.name) == ["ChatGPT", "Future"] && model.composerSigilItems[0].enabled && !model.composerSigilItems[1].enabled && model.composerSigilItems[1].detail == "現在不能用", "TAP table readiness and future disabled")
        model.pickComposerSigil(model.composerSigilItems[1])
        check(model.prompt == "@@", "disabled TAP cannot be picked")
        tap.connection = .off
        check(model.composerSigilItems.first?.enabled == false, "disconnected TAP disabled")
        tap.connection = .ready
        func until(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw NSError(domain: "W236", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
        func sends() -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        let ordinary = engine.newThread(in: project)
        model.document = engine.document; model.selectedThreadID = ordinary; model.selectedModel = "gpt-6.1-sol"
        for original in ["花了 $2", "花了 $5.5", "@2026", "!3", "@@2026"] {
            model.prompt = original
            check(!model.handleComposerSuggestionKey(.commit), "U2 \(original) Enter uses ordinary send")
            let before = sends().count; model.send()
            try await until("ordinary sigil send") { sends().count > before && !engine.isRunning(ordinary) }
            check(engine.transcript(for: ordinary).last { $0.role == .user }?.text == original && (sends().last?["text"] as? String)?.contains(original) == true, "U2 \(original) sends original text to engine and transcript")
        }
        for (kind, route) in [(ClaudeSidecar.Kind.codex, "gpt-6.1-sol"), (.claude, "sonnet5")] {
            let thread = engine.newThread(in: project); model.document = engine.document; model.selectedThreadID = thread; model.selectedModel = route
            model.prompt = "@TATWO OS $ultrawork 檢查這一回合"
            let original = model.prompt
            let before = sends().count, enabled = engine.threadRecord(thread)?.enabledMCP
            model.send()
            try await until("\(kind) fixture receives send") { sends().count > before && !engine.isRunning(thread) }
            let text = sends().last?["text"] as? String ?? ""
            check(engine.transcript(for: thread).first { $0.role == .user }?.text == original, "U5 \(kind) user bubble and stored row contain only original text and markers")
            check(engine.doc.threads.first { $0.id == thread }?.messages.first { $0.role == "user" }?.text == original, "U5 \(kind) persisted row has no hidden instruction")
            check(text.contains("使用者指定這回合用 MCP：TATWO OS"), "\(kind) actual turn receives MCP context")
            check(kind == .codex ? text.contains("$tatwo-ultrawork") : text.contains("使用者指定這回合用技能：ultrawork"), "\(kind) actual turn receives native skill context")
            check(engine.threadRecord(thread)?.enabledMCP == enabled && model.prompt.isEmpty && model.composerMarkers.isEmpty, "\(kind) keeps MCP switches and consumes markers")
            model.prompt = "下一回合沒有指定工具或技能"
            let next = sends().count; model.send()
            try await until("\(kind) next turn") { sends().count > next && !engine.isRunning(thread) }
            let nextText = sends().last?["text"] as? String ?? ""
            check(!nextText.contains("使用者指定這回合用") && !nextText.contains("$tatwo-ultrawork"), "\(kind) marker context does not leak into next turn")
        }
        overrides[GroupCoderBridge.flag] = true; defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        model.selectedThreadID = id; model.selectedModel = "gpt-6.1-sol"; model.prompt = "@@"
        model.pickComposerSigil(model.composerSigilItems[0])
        check(model.prompt == "@@ChatGPT ", "connected TAP insertion")
        model.prompt += "請一起看這串"
        model.send()
        try await until("group TAP receives human") { !tap.sent.isEmpty }
        tap.emit(.conversation(id: "w236-chat")); tap.emit(.text(messageID: "w236-tap", full: "方向對，可以再簡化。")); tap.finish()
        try await until("group auto relay") { tap.sent.count >= 2 }
        tap.emit(.text(messageID: "w236-relay", full: "我已讀這串，等下一步。")); tap.finish()
        try await until("group idle") { !engine.isRunning(id) }
        guard let realGroup = engine.groupBridge.sessions[id] else { throw CocoaError(.fileReadUnknown) }
        check(realGroup.state("ChatGPT") == .collaborating && realGroup.cursors["ChatGPT", default: 0] > 0, "existing group joins and advances read cursor")
        check(!realGroup.canContinueRound, "no eligible AI reply hides continuation")
        let scope = TatwoThemeSelfTestScope(); defer { scope.restore() }; scope.use(.aurora)
        let artifacts = URL(fileURLWithPath: env["TATWO2_SELFTEST_ARTIFACTS"]!)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        func screenshot<V: View>(_ view: V, _ name: String, _ scheme: ColorScheme, size: CGSize) throws -> GlobalDMChatAcceptance.Rendered {
            guard let shot = GlobalDMChatAcceptance.renderSync(view, size: size, scheme: scheme), let data = shot.bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: artifacts.appendingPathComponent("w236-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            check(scheme != .dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(shot.bitmap), "\(name) \(scheme) readable screenshot")
            return shot
        }
        for scheme in [ColorScheme.light, .dark] {
            for (symbol, name) in [("@", "mcp"), ("$", "skillet"), ("!", "issue"), ("@@", "tap")] {
                model.prompt = symbol; model.issueListEntries = [issue]
                let shot = try screenshot(ComposerFixture(model: model).padding(24), name, scheme, size: CGSize(width: 820, height: 650))
                let tree = GlobalDMChatAcceptance.tree(shot)
                check(tree["composer-sigil-title"] != nil && model.composerSigilItems.first.map { tree["composer-sigil-item-" + $0.value] != nil } == true, "\(name) \(scheme) menu title and first item rendered")
                if symbol == "@", scheme == .light {
                    func editor(_ view: NSView) -> NSTextView? {
                        if let text = view as? NSTextView { return text }
                        return view.subviews.compactMap(editor).first
                    }
                    shot.window.styleMask.insert(.titled); shot.window.makeKey()
                    if let editor = editor(shot.host) {
                        shot.window.makeFirstResponder(editor)
                        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                        for (code, char, expected) in [(125, "\u{f701}", 1), (126, "\u{f700}", 0)] {
                            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: shot.window.windowNumber, context: nil, characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: UInt16(code))!
                            NSApp.postEvent(event, atStart: true)
                            try await until("native arrow \(code)") { model.issueMentionSelectedIndex == expected }
                            check(model.issueMentionSelectedIndex == expected, "native composer arrow \(code) drives shared menu")
                        }
                    } else { check(false, "native composer editor rendered") }
                    print("W236SIGILS EVIDENCE keyWindow=\(NSApp.keyWindow?.windowNumber ?? -1) target=\(shot.window.windowNumber)")
                    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: shot.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                    NSApp.postEvent(escape, atStart: true)
                    try await until("native Escape dismisses menu") { model.composerSigil == nil }
                    check(model.prompt == "@", "native Escape keeps draft")
                    try await until("native Escape removes popup") { GlobalDMChatAcceptance.tree(shot)["composer-sigil-title"] == nil }
                    model.prompt = "$ultrawork"
                    try await until("skill popup reopens") { GlobalDMChatAcceptance.tree(shot)["composer-sigil-title"] != nil }
                    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: shot.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                    NSApp.postEvent(enter, atStart: true)
                    try await until("native Enter inserts default selection") { model.prompt == "$ultrawork " }
                    check(model.composerMarkers == ["$ultrawork"], "native Enter inserts skill marker")
                }
                shot.close()
            }
            model.prompt = ""
            let shot = try screenshot(ChatPage(model: model).messageArea(contentMaxWidth: 760).padding(20), "group", scheme, size: CGSize(width: 820, height: 720))
            check(GlobalDMChatAcceptance.tree(shot)["group-leave-ChatGPT"] != nil, "participant leave button rendered")
            shot.close()
        }
        var calls = 0
        let group = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [
            GroupParticipant(id: "Codex", invoke: { _, done in calls += 1; done(.success("@@ChatGPT 請回覆")) }, stop: {}),
            GroupParticipant(id: "ChatGPT", join: true, invoke: { _, done in calls += 1; done(.success("@Codex 請看")) }, stop: {})])
        _ = group.human("@@ChatGPT 一起看")
        check(group.canContinueRound, "pending AI exchange exposes continuation")
        guard let shot = GlobalDMChatAcceptance.renderSync(ChatGroupParticipants(group: group), size: CGSize(width: 820, height: 100)) else { throw CocoaError(.fileWriteUnknown) }
        defer { shot.close() }
        let tree = GlobalDMChatAcceptance.tree(shot), before = calls
        check(tree["group-continue"].map { ($0 as AnyObject).accessibilityPerformPress?() == true } == true && calls > before, "continuation button invokes existing engine")
        check(tree["group-leave-ChatGPT"].map { ($0 as AnyObject).accessibilityPerformPress?() == true } == true && group.state("ChatGPT") == .left, "leave button invokes existing command parser")
        print("W236SIGILS SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }

    private struct ComposerFixture: View {
        @ObservedObject var model: ChatPageModel
        var body: some View { ChatPage(model: model).composer(contentMaxWidth: 760) }
    }
}
#endif
