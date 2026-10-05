#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum CoderTurnAcceptance {
    static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                children.forEach(visit)
            }
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(root)
        return result
    }
    static func string(_ node: NSObject, _ name: String) -> String {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return "" }
        return node.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func frame(_ node: NSObject) -> CGRect { (node as AnyObject).accessibilityFrame?() ?? .zero }
    static func find(_ host: NSView, _ id: String) -> NSObject? {
        nodes(host).first { string($0, "accessibilityIdentifier") == id }
    }
    static func save(_ shot: GlobalDMChatAcceptance.Rendered, _ name: String, _ artifacts: URL) throws {
        shot.host.layoutSubtreeIfNeeded()
        guard let rep = shot.host.bitmapImageRepForCachingDisplay(in: shot.host.bounds) else { throw BotLibraryError.invalid("no bitmap") }
        shot.host.cacheDisplay(in: shot.host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent(name + ".png"))
        let tree = nodes(shot.host).map { node in
            ["id": string(node, "accessibilityIdentifier"), "label": string(node, "accessibilityLabel"),
             "value": string(node, "accessibilityValue"), "role": string(node, "accessibilityRole"), "frame": NSStringFromRect(frame(node))]
        }
        try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]).write(to: artifacts.appendingPathComponent(name + ".json"))
    }
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let rootPath = env["TATWO2_LIVE_ROOT"], let path = env["TATWO2_SELFTEST_ARTIFACTS"] else {
            throw BotLibraryError.invalid("w215 requires isolated staging and artifacts")
        }
        let artifacts = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: rootPath)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "fixture", workdir: rootPath)
        let memory = TatwoMemoryUsageNote(items: [.init(id: "fixture-memory", title: "W215 記憶標題")], query: "fixture")
        let rows = [
            ChatMessage(id: "u1", role: .user, text: "整理這回合的成果", turnID: "t1"),
            ChatMessage(id: "work1", role: .assistant, text: "hidden reasoning must never appear", status: "done|testing", eventKind: .thinking, turnID: "t1"),
            ChatMessage(id: "memory1", role: .system, text: memory.encoded(), status: TatwoMemoryUsageNote.status, turnID: "t1"),
            ChatMessage(id: "approved1", role: .system, text: "允許測試工具", status: "done|權限", turnID: "t1"),
            ChatMessage(id: "denied1", role: .system, text: "拒絕測試工具", status: "done|權限", turnID: "t1"),
            ChatMessage(id: "pending1", role: .system, text: "待核准 fixture.swift 寫入", status: "tool approval required", turnID: "t1"),
            ChatMessage(id: "a1", role: .assistant, text: "W215 reply\n已完成修改。", status: "done", turnID: "t1")
        ]
        let thread = engine.insertOfflineCopy(projectID: project, title: "Coder turn", rows: rows)
        try Data("// W215 fixture\n".utf8).write(to: root.appendingPathComponent("fixture.swift"))
        _ = try await engine.turnArtifacts.collect(threadID: thread, turnID: "t1", messageID: "a1", endedAt: Date(),
                                                   cwd: rootPath, claimed: ["fixture.swift"], gitFiles: [])
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.mode = .chat
        model.selectLocalThread(thread)
        try? await Task.sleep(for: .milliseconds(250))
        let stage = Int(env["W215_CHECK"] ?? "5") ?? 5
        var failures = 0, passed = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failures += 1 }
            print("W215 \(ok ? "PASS" : "FAIL") \(label)")
        }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            TatwoThemeSelfTestScope().use(scheme == .light ? .fable5 : .aurora)
            guard let shot = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).transcript(contentMaxWidth: 560), size: CGSize(width: 700, height: 650), scheme: scheme) else {
                check(false, "render \(suffix)"); continue
            }
            defer { shot.close() }
            let tree = nodes(shot.host)
            let logo = find(shot.host, "coder-turn-logo-a1") ?? tree.first { string($0, "accessibilityLabel").hasSuffix(" logo") }
            let textViews = TatwoComposerModeAcceptance.views(NSTextView.self, in: shot.host)
            let reply = textViews.first { $0.string.contains("W215 reply") }
            let textFrame = reply.map { shot.window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? .zero
            let logoFrame = logo.map { CGRect(x: frame($0).midX - 12, y: frame($0).midY - 12, width: 24, height: 24) } ?? .zero
            check(logo != nil && reply != nil, "N1 real logo and reply exist \(suffix)")
            check(textFrame.minX - logoFrame.maxX >= 12 && textFrame.minX - logoFrame.maxX <= 14.5,
                  "N1 logo gap 12–14pt \(suffix) gap=\(textFrame.minX - logoFrame.maxX)")
            // The first line's actual text layout provides the vertical center, independently of the avatar's layout.
            if let reply, let manager = reply.layoutManager, let container = reply.textContainer {
                let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                let first = shot.window.convertToScreen(reply.convert(line.offsetBy(dx: reply.textContainerInset.width, dy: reply.textContainerInset.height), to: nil))
                check(abs(first.midY - logoFrame.midY) <= 2, "N1 logo centers on first line \(suffix) delta=\(abs(first.midY - logoFrame.midY))")
                _ = container
            }
            if stage == 1 {
                check(find(shot.host, "chat-artifacts-disclosure") == nil && find(shot.host, "chat-artifacts-view") == nil, "N1 artifact card starts collapsed \(suffix)")
                check(TatwoComposerModeAcceptance.press("coder-turn-logo-a1", in: shot), "N1 logo press expands artifacts \(suffix)")
                TatwoComposerModeAcceptance.settle(shot)
                check(find(shot.host, "chat-artifacts-disclosure") != nil && find(shot.host, "chat-artifacts-view") != nil, "N1 real artifact card exists after logo press \(suffix)")
            }
            for node in nodes(shot.host) where string(node, "accessibilityLabel").contains("權限 允許") || string(node, "accessibilityIdentifier") == "chat-artifacts-disclosure" {
                check(frame(node).minX >= textFrame.minX - 0.5, "N1 auxiliary row stays in text column \(suffix) \(string(node, "accessibilityLabel"))")
            }
            if stage == 1 {
                check(TatwoComposerModeAcceptance.press("coder-turn-logo-a1", in: shot), "N1 logo press collapses artifacts \(suffix)")
                TatwoComposerModeAcceptance.settle(shot)
                check(find(shot.host, "chat-artifacts-disclosure") == nil && find(shot.host, "chat-artifacts-view") == nil, "N1 artifact card disappears after collapse \(suffix)")
            }
            if stage >= 3 {
                check(!tree.contains { string($0, "accessibilityLabel").hasPrefix("權限 ") }, "N3 approved and denied permissions absent while collapsed \(suffix)")
                check(textViews.contains { $0.string.contains("待核准 fixture.swift") }, "N3 pending approval stays visible \(suffix)")
            }
            if stage >= 2 {
                check(find(shot.host, "chat-inline-work-timeline-summary") == nil && find(shot.host, "tatwo-memory-usage") == nil && find(shot.host, "chat-artifacts-disclosure") == nil,
                      "N2 completed steps memory artifacts absent from collapsed tree \(suffix)")
                let buttonID = "coder-turn-logo-a1"
                check(find(shot.host, buttonID).map { string($0, "accessibilityLabel") == "顯示這回合的步驟" && string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue } == true,
                      "N2 logo is accessible button \(suffix)")
                check(TatwoComposerModeAcceptance.press(buttonID, in: shot), "N2 logo press expands \(suffix)")
                TatwoComposerModeAcceptance.settle(shot)
                check(find(shot.host, "chat-inline-work-detail") != nil, "N2 steps visible after logo press \(suffix)")
                check(nodes(shot.host).contains { string($0, "accessibilityValue") == "W215 記憶標題" || string($0, "accessibilityLabel").contains("W215 記憶標題") },
                      "N2 memory titles visible after logo press \(suffix)")
                check(find(shot.host, "chat-artifacts-view") != nil, "N2 artifact view action survives \(suffix)")
                check(!nodes(shot.host).contains { string($0, "accessibilityValue").contains("hidden reasoning") || string($0, "accessibilityLabel").contains("hidden reasoning") },
                      "N2 private reasoning stays absent \(suffix)")
                let ids = ["chat-inline-work-detail", "coder-turn-memory", "chat-artifacts-view"]
                let frames = ids.compactMap { find(shot.host, $0).map(frame) }
                check(frames.count == 3 && frames.allSatisfy { $0.minX >= textFrame.minX - 0.5 } && frames[0].midY > frames[1].midY && frames[1].midY > frames[2].midY,
                      "N2 steps memory artifacts ordered inside text column \(suffix)")
                if stage >= 3 {
                    let permissions = nodes(shot.host).filter { string($0, "accessibilityLabel").hasPrefix("權限 ") }
                    check(permissions.count == 2 && permissions.allSatisfy { frame($0).minX >= textFrame.minX && frame($0).midY < textFrame.midY },
                          "N3 approved and denied permissions expand below reply in text column \(suffix)")
                    check(TatwoComposerModeAcceptance.views(NSTextView.self, in: shot.host).contains { $0.string.contains("待核准 fixture.swift") },
                          "N3 opening details never hides pending approval \(suffix)")
                    try save(shot, "w215-n3-expanded-\(suffix)", artifacts)
                }
                try save(shot, "w215-n2-expanded-\(suffix)", artifacts)
                check(TatwoComposerModeAcceptance.press(buttonID, in: shot), "N2 second logo press collapses \(suffix)")
                TatwoComposerModeAcceptance.settle(shot)
                check(find(shot.host, "chat-inline-work-detail") == nil && find(shot.host, "chat-artifacts-view") == nil,
                      "N2 second press removes details from tree \(suffix)")
                if let node = find(shot.host, buttonID) {
                    (node as AnyObject).setAccessibilityFocused?(true)
                    if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: shot.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
                        shot.window.sendEvent(key)
                    }
                    TatwoComposerModeAcceptance.settle(shot)
                    check(find(shot.host, "chat-inline-work-detail") != nil, "N2 focused logo opens with Space key \(suffix)")
                    try save(shot, "w215-n2-keyboard-\(suffix)", artifacts)
                    _ = TatwoComposerModeAcceptance.press(buttonID, in: shot)
                    (node as AnyObject).setAccessibilityFocused?(false)
                    shot.window.makeFirstResponder(nil)
                    TatwoComposerModeAcceptance.settle(shot)
                }

            }
            try save(shot, "w215-n\(stage)-\(suffix)", artifacts)
        }
        if stage >= 2 {
            TatwoThemeSelfTestScope().use(.fable5)
            let empty = engine.insertOfflineCopy(projectID: project, title: "No turn metadata", rows: [
                ChatMessage(id: "empty", role: .assistant, text: "沒有步驟、記憶或產出", turnID: "empty-turn")])
            model.selectLocalThread(empty)
            try? await Task.sleep(for: .milliseconds(250))
            if let shot = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).transcript(contentMaxWidth: 560), size: CGSize(width: 700, height: 650)) {
                check(!nodes(shot.host).contains { string($0, "accessibilityLabel") == "顯示這回合的步驟" }, "N2 empty turn logo has no button")
                try save(shot, "w215-n2-empty", artifacts)
                shot.close()
            } else { check(false, "N2 empty turn renders") }
            let history = engine.insertOfflineCopy(projectID: project, title: "Two turns", rows: rows + [
                ChatMessage(id: "u2", role: .user, text: "第二回合", turnID: "t2"),
                ChatMessage(id: "work2", role: .assistant, text: "", status: "done|第二回合工具", eventKind: .toolUse, turnID: "t2"),
                ChatMessage(id: "a2", role: .assistant, text: "第二回合回覆", status: "done", turnID: "t2")])
            _ = try await engine.turnArtifacts.collect(threadID: history, turnID: "t1", messageID: "a1", endedAt: Date(), cwd: rootPath, claimed: ["fixture.swift"], gitFiles: [])
            model.selectLocalThread(history)
            try? await Task.sleep(for: .milliseconds(250))
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                TatwoThemeSelfTestScope().use(scheme == .light ? .fable5 : .aurora)
            if let shot = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).environment(\.tatwoSurfaceKind, .window), size: CGSize(width: 1100, height: 700), scheme: scheme) {
                if stage >= 4 {
                    let rail = TatwoComposerModeAcceptance.views(NSScrollView.self, in: shot.host).first { $0.frame.width < 50 }
                    let bounds = rail.map { $0.convert($0.bounds, to: shot.host) } ?? .zero
                    check(rail != nil && abs(bounds.height - 40) <= 0.5, "N4 history uses visible row count \(suffix)")
                    var ancestor: NSView? = TatwoComposerModeAcceptance.views(NSTextView.self, in: shot.host).first { $0.string.contains("第二回合回覆") }
                    while ancestor != nil && !(ancestor is NSScrollView) { ancestor = ancestor?.superview }
                    let viewport = ancestor.map { $0.convert($0.bounds, to: shot.host) } ?? .zero
                    check(ancestor != nil && abs(bounds.midY - viewport.midY) <= 0.5,
                          "N4 real Coder history centered \(suffix) delta=\(bounds.midY - viewport.midY)")
                    try save(shot, "w215-n4-history-\(suffix)", artifacts)
                }
                check(TatwoComposerModeAcceptance.press("coder-turn-logo-a2", in: shot), "N2 newer turn logo opens")
                TatwoComposerModeAcceptance.settle(shot)
                check(find(shot.host, "chat-inline-work-detail") != nil && find(shot.host, "coder-turn-memory") == nil && find(shot.host, "chat-artifacts-view") == nil,
                      "N2 newer turn never inherits older memory or artifacts")
                _ = TatwoComposerModeAcceptance.press("coder-turn-logo-a2", in: shot)
                TatwoComposerModeAcceptance.settle(shot)
                check(TatwoComposerModeAcceptance.press("coder-turn-logo-a1", in: shot), "N2 older turn logo opens")
                TatwoComposerModeAcceptance.settle(shot)
                check(find(shot.host, "coder-turn-memory") != nil && find(shot.host, "chat-artifacts-view") != nil, "N2 older turn keeps its own memory and artifact index")
                try save(shot, "w215-n2-history-\(suffix)", artifacts)
                shot.close()
            } else { check(false, "N2 historical turns render") }
            }
            TatwoThemeSelfTestScope().use(.fable5)
            if let presentation = ChatSystemNotePresentation.resolve(rows[2]), let shared = GlobalDMChatAcceptance.renderSync(ChatSystemNoteRow(presentation: presentation, rowWidth: 560), size: CGSize(width: 600, height: 150)) {
                check(find(shared.host, "tatwo-memory-usage") != nil && find(shared.host, "coder-turn-memory") == nil, "N2 shared assistant and DM memory row keeps original disclosure")
                shared.close()
            } else { check(false, "N2 shared memory row renders") }
        }
        if stage >= 4 {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                TatwoThemeSelfTestScope().use(scheme == .light ? .fable5 : .aurora)
                for count in [4, 12, 80] {
                    let items = (0..<count).map { ChatTranscriptDisplayItem.message(ChatMessage(id: "tick-\($0)", role: $0.isMultiple(of: 2) ? .user : .assistant, text: "History \($0)")) }
                    for height in [80.0, 300.0, 650.0] {
                        guard let shot = GlobalDMChatAcceptance.renderSync(ChatHistoryMinimap(items: items, onJump: { _ in }), size: CGSize(width: 40, height: height), scheme: scheme) else {
                            check(false, "N4 history renders"); continue
                        }
                        defer { shot.close() }
                        let scroll = TatwoComposerModeAcceptance.views(NSScrollView.self, in: shot.host).first
                        let bounds = scroll.map { $0.convert($0.bounds, to: shot.host) } ?? .zero
                        check(scroll != nil && abs(bounds.midY - height / 2) <= 0.5,
                              "N4 history centered count=\(count) height=\(height) \(suffix) delta=\(bounds.midY - height / 2)")
                        check(bounds.height <= min(360, CGFloat(count) * 8) + 0.5 && bounds.minY >= -0.5 && bounds.maxY <= height + 0.5,
                              "N4 history fits available viewport count=\(count) height=\(height) \(suffix)")
                        check((scroll?.documentView?.frame.height ?? 0) >= CGFloat(count) * 8 - 0.5,
                              "N4 ticks keep spacing and overflow scrolls count=\(count) height=\(height) \(suffix)")
                        try save(shot, "w215-n4-\(count)-\(Int(height))-\(suffix)", artifacts)
                    }
                }
            }
        }
        if stage >= 5 {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                TatwoThemeSelfTestScope().use(scheme == .light ? .fable5 : .aurora)
                for status in ["queued", "calling-tool|檢查檔案", "reconnecting|續接", "done|工具完成"] {
                    let name = String(status.split(separator: "|")[0])
                    let liveRows = rows + [
                        ChatMessage(id: "live-u", role: .user, text: "繼續施工", turnID: "live-turn"),
                        ChatMessage(id: "live-work", role: .assistant, text: "", status: status, eventKind: .toolUse, turnID: "live-turn"),
                        ChatMessage(id: "live-a", role: .assistant, text: "進行中的回覆", status: "streaming", turnID: "live-turn")]
                    let live = engine.insertOfflineCopy(projectID: project, title: "Running \(name)", rows: liveRows)
                    _ = try await engine.turnArtifacts.collect(threadID: live, turnID: "t1", messageID: "a1", endedAt: Date(), cwd: rootPath, claimed: ["fixture.swift"], gitFiles: [])
                    model.selectLocalThread(live)
                    try? await Task.sleep(for: .milliseconds(250))
                    model.isRunning = true
                    guard let shot = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).transcript(contentMaxWidth: 560), size: CGSize(width: 700, height: 650), scheme: scheme) else {
                        check(false, "N5 running transcript renders"); continue
                    }
                    defer { shot.close() }
                    let progress = nodes(shot.host).filter { string($0, "accessibilityIdentifier") == "chat-inline-work-timeline-summary" }
                    let reply = TatwoComposerModeAcceptance.views(NSTextView.self, in: shot.host).first { $0.string.contains("進行中的回覆") }
                    let replyFrame = reply.map { shot.window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? .zero
                    check(progress.count == 1, "N5 current progress stays visible until reply ends \(name) \(suffix)")
                    check(reply != nil && progress.allSatisfy { frame($0).minX >= replyFrame.minX - 0.5 },
                          "N5 live progress stays outside logo column \(name) \(suffix)")
                    check(TatwoComposerModeAcceptance.press("coder-turn-logo-a1", in: shot), "N5 older logo still opens during reply \(name) \(suffix)")
                    TatwoComposerModeAcceptance.settle(shot)
                    check(find(shot.host, "chat-artifacts-view") != nil, "N5 older artifacts stay available during newer reply \(name) \(suffix)")
                    _ = TatwoComposerModeAcceptance.press("coder-turn-logo-a1", in: shot)
                    TatwoComposerModeAcceptance.settle(shot)
                    try save(shot, "w215-n5-running-\(name)-\(suffix)", artifacts)
                }
                let ended = engine.insertOfflineCopy(projectID: project, title: "Completed reply", rows: rows + [
                    ChatMessage(id: "live-u", role: .user, text: "繼續施工", turnID: "live-turn"),
                    ChatMessage(id: "live-work", role: .assistant, text: "", status: "done|工具完成", eventKind: .toolUse, turnID: "live-turn"),
                    ChatMessage(id: "live-a", role: .assistant, text: "回覆已完成", status: "done", turnID: "live-turn")])
                model.selectLocalThread(ended)
                try? await Task.sleep(for: .milliseconds(250))
                model.isRunning = false
                if let shot = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).transcript(contentMaxWidth: 560), size: CGSize(width: 700, height: 650), scheme: scheme) {
                    check(find(shot.host, "chat-inline-work-timeline-summary") == nil, "N5 ended progress folds into logo \(suffix)")
                    check(TatwoComposerModeAcceptance.press("coder-turn-logo-live-a", in: shot), "N5 ended reply logo opens steps \(suffix)")
                    TatwoComposerModeAcceptance.settle(shot)
                    check(find(shot.host, "chat-inline-work-detail") != nil, "N5 ended steps remain accessible \(suffix)")
                    try save(shot, "w215-n5-ended-\(suffix)", artifacts)
                    shot.close()
                } else { check(false, "N5 completed transcript renders") }
            }
        }
        if stage >= 2 {
            TatwoThemeSelfTestScope().use(.fable5)
            var viewed = 0, opened: [String] = []
            if let index = try await engine.turnArtifacts.list(threadID: thread, turnID: "t1"),
               let shot = GlobalDMChatAcceptance.renderSync(ChatArtifactsCard(index: index, onView: { viewed += 1 }, onOpen: { opened.append($0) }, initiallyExpanded: true), size: CGSize(width: 560, height: 200)) {
                check(TatwoComposerModeAcceptance.press("chat-artifacts-view", in: shot), "N2 artifact View receives real accessibility press")
                check(viewed == 1, "N2 artifact View invokes original callback")
                let file = nodes(shot.host).first { string($0, "accessibilityLabel") == "fixture.swift，檔在" }
                check(file.map { ($0 as AnyObject).accessibilityPerformPress?() == true } == true, "N2 artifact file receives real accessibility press")
                check(opened == ["fixture.swift"], "N2 artifact file invokes original Open callback with its path")
                shot.close()
            } else { check(false, "N2 artifact action fixture renders") }
        }
        if stage >= 2, let foreign = try await engine.turnArtifacts.list(threadID: thread, turnID: "t1") {
            let copy = engine.insertOfflineCopy(projectID: project, title: "Identical message IDs", rows: rows)
            model.selectLocalThread(copy)
            try? await Task.sleep(for: .milliseconds(250))
            model.latestTurnArtifacts = foreign
            if let shot = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).transcript(contentMaxWidth: 560), size: CGSize(width: 700, height: 650)) {
                check(TatwoComposerModeAcceptance.press("coder-turn-logo-a1", in: shot), "N2 copied thread logo opens")
                TatwoComposerModeAcceptance.settle(shot)
                check(find(shot.host, "chat-artifacts-view") == nil, "N2 identical message ids never expose another thread artifact index")
                shot.close()
            } else { check(false, "N2 copied thread renders") }
        }
        if stage >= 4 {
            TatwoThemeSelfTestScope().use(.fable5)
            let expected = ["message:u1", "message:pending1", "message:a1", "message:u2", "message:a2"]
            let jumpRows = rows + [ChatMessage(id: "u2", role: .user, text: "第二回合", turnID: "t2"), ChatMessage(id: "a2", role: .assistant, text: "第二回合回覆", turnID: "t2")]
            let projection = CoderTurnProjection(ChatTranscriptDisplayBuilder.build(jumpRows), messages: jumpRows)
            var jumped: String?
            let rig = TatwoComposerModeAcceptance.ClickRig(ChatHistoryMinimap(items: projection.items, onJump: { jumped = $0 }), size: CGSize(width: 40, height: 300))
            defer { rig.close() }
            await rig.settle()
            if let scroll = TatwoComposerModeAcceptance.views(NSScrollView.self, in: rig.host).first {
                let rect = scroll.convert(scroll.bounds, to: nil)
                for (index, id) in expected.enumerated() {
                    jumped = nil
                    await rig.click(NSPoint(x: rect.minX + 10, y: rect.maxY - CGFloat(index) * 8 - 4))
                    check(jumped == id, "N4 history jump uses rendered row id \(id) got=\(jumped ?? "nil")")
                }
            } else { check(false, "N4 jump surface renders") }
        }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            TatwoThemeSelfTestScope().use(scheme == .light ? .fable5 : .aurora)
            model.selectLocalThread(thread)
            try? await Task.sleep(for: .milliseconds(250))
            model.activePlanArtifact = TatwoPlanArtifactV1(threadID: thread, objective: "W215 計畫", sections: [.init(title: "步驟", body: "[計畫文件](https://example.invalid/plan)")])
            if let shot = GlobalDMChatAcceptance.renderSync(ChatPage(model: model).transcript(contentMaxWidth: 560), size: CGSize(width: 700, height: 650), scheme: scheme) {
                let cardNodes = nodes(shot.host).filter { string($0, "accessibilityIdentifier") == "plan-transcript-summary" }
                let icon = cardNodes.first { string($0, "accessibilityRole") == NSAccessibility.Role.image.rawValue }
                let reply = TatwoComposerModeAcceptance.views(NSTextView.self, in: shot.host).first { $0.string.contains("W215 reply") }
                let textFrame = reply.map { shot.window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? .zero
                check(find(shot.host, "plan-transcript-summary") != nil && icon != nil && reply != nil, "N1 real plan card and its icon exist \(suffix)")
                check(icon != nil && cardNodes.allSatisfy { frame($0).minX >= textFrame.minX - 0.5 }, "N1 plan card links and controls stay outside logo column \(suffix) left=\(icon.map { frame($0).minX } ?? 0) text=\(textFrame.minX)")
                try save(shot, "w215-n1-plan-\(suffix)", artifacts)
                shot.close()
            } else { check(false, "N1 plan card renders") }
            model.activePlanArtifact = nil
        }
        print("W215 SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
}
#endif
