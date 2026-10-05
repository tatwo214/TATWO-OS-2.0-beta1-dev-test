#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum CoderScrollAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              env["CFFIXED_USER_HOME"] == env["HOME"],
              let rootPath = env["TATWO2_LIVE_ROOT"], let artifactsPath = env["TATWO2_SELFTEST_ARTIFACTS"] else {
            throw BotLibraryError.invalid("w213scroll requires isolated app preferences and artifacts")
        }
        // This is the isolated application's domain, never NSGlobalDomain.
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "AppleShowScrollBars")
        defaults.set("Always", forKey: "AppleShowScrollBars")
        defaults.synchronize()
        defer {
            if let original { defaults.set(original, forKey: "AppleShowScrollBars") }
            else { defaults.removeObject(forKey: "AppleShowScrollBars") }
        }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        var failures = 0, passed = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failures += 1 }
            print("W213SCROLL \(ok ? "PASS" : "FAIL") \(label)")
        }
        check(NSScroller.preferredScrollerStyle == .legacy, "Always preference really selects legacy mouse-only scrollbars")
        let root = URL(fileURLWithPath: rootPath)
        let artifacts = URL(fileURLWithPath: artifactsPath)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "W213 Coder", workdir: rootPath)
        let code = (0..<90).map { "let row\($0) = \"" + String(repeating: "horizontal ", count: 30) + "\"" }.joined(separator: "\n")
        let rows = (0..<60).map {
            ChatMessage(id: "w213-\($0)", role: $0.isMultiple(of: 2) ? .user : .assistant,
                        text: "W213 message \($0)\n" + String(repeating: "Reading position and wheel scrolling remain available. ", count: 4))
        } + [ChatMessage(id: "w213-code", role: .assistant, text: "```swift\n\(code)\n```")]
        let thread = engine.insertOfflineCopy(projectID: project, title: "Long transcript", rows: rows)
        for i in 0..<30 { _ = engine.newThread(in: project, title: "Sidebar thread \(i)") }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.mode = .chat
        model.selectLocalThread(thread)
        model.prompt = String(repeating: "Composer line\n", count: 20)
        let page = ChatPage(model: model)
        let plan = TatwoPlanArtifactV1(threadID: thread, objective: "W213 plan",
                                     sections: [.init(title: "Steps", body: String(repeating: "Plan step\n", count: 100))])
        let inspector = PlanTranscriptInspectorView(
            artifact: plan, isPresented: .constant(true), selection: nil, localActionPresentation: .idle,
            editableText: nil, onSelectionChange: { _ in }, onSaveEditedText: { _ in false },
            ultraworkPanel: AnyView(EmptyView()), ultraworkPrimaryModelID: model.routeChoice.id,
            ultraworkSecondaryModelID: nil, ultraworkAuxiliaryCount: 0, onDismissUltrawork: {}, onExecute: {})
        let searchIndex = TatwoChatSearchIndex(documents: (0..<60).map {
            .init(id: "search-\($0)", sourceKind: .message, threadID: thread,
                  title: "W213 result \($0)", searchableText: "W213 " + String(repeating: "result ", count: 20))
        })
        setenv("TATWO_ULTRAWORK_CHAT_SEARCH_QUERY", "W213", 1)
        defer { unsetenv("TATWO_ULTRAWORK_CHAT_SEARCH_QUERY") }
        let search = TatwoChatSearchOverlay(indexProvider: { searchIndex }, onJump: { _ in }, onClose: {})
        let mode = TatwoComposerModeCard(mode: page.coderComposerMode(), metrics: .main, fitsAbove: false)
        var prPlan = plan
        prPlan.kind = "pr"
        prPlan.prReview = PRPlanReview(directory: root, repository: "example/fixture", account: "fixture",
                                      snapshot: .init(head: "fixture", status: "", diff:
                                        "diff --git a/fixture.swift b/fixture.swift\n@@ -1 +1 @@\n+" + String(repeating: "diff ", count: 250),
                                                      stat: "", origin: "https://example.invalid/fixture"))
        var pr = PRPlanActions(artifact: prPlan, isDisabled: false, onConfirm: {}, onSubmit: {}, onReturnToDiscussion: {})
        pr.testLoggedIn = true
        let cases: [(String, AnyView, CGSize)] = [
            ("coder", AnyView(page), CGSize(width: 1100, height: 700)),
            ("sidebar", AnyView(page.chatSidebar), CGSize(width: 260, height: 320)),
            ("plan", AnyView(inspector), CGSize(width: 480, height: 420)),
            ("search", AnyView(search), CGSize(width: 760, height: 650)),
            ("pr", AnyView(pr), CGSize(width: 480, height: 300)),
            ("mode", AnyView(mode), CGSize(width: 420, height: 280)),
            ("mode-scroll", AnyView(TatwoComposerModeFitScroll(limit: 100) { mode }), CGSize(width: 420, height: 120))
        ]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            TatwoThemeSelfTestScope().use(scheme == .dark ? .aurora : .fable5)
            for (name, view, size) in cases {
                guard let shot = GlobalDMChatAcceptance.renderSync(view, size: size, scheme: scheme) else {
                    check(false, "\(name) \(suffix) renders"); continue
                }
                defer { shot.close() }
                if name == "pr" {
                    check(expandDisclosure(in: shot.host), "PR diff disclosure expands through accessibility")
                    TatwoComposerModeAcceptance.settle(shot)
                }
                let scrolls = descendants(shot.host)
                if name != "mode" { check(!scrolls.isEmpty, "\(name) \(suffix) has real NSScrollViews") }
                for (i, scroll) in scrolls.enumerated() {
                    verify(scroll, label: "\(name) \(suffix) #\(i)", check: check)
                    let origin = scroll.contentView.bounds.origin
                    let viewport = scroll.contentView.bounds.size
                    NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
                    shot.host.layoutSubtreeIfNeeded()
                    verify(scroll, label: "\(name) \(suffix) #\(i) after preference notification", check: check)
                    check(scroll.contentView.bounds.origin == origin && scroll.contentView.bounds.size == viewport,
                          "\(name) \(suffix) #\(i) notification preserves reading position and viewport")
                }
                if name == "coder" {
                    guard let png = shot.bitmap.representation(using: .png, properties: [:]) else {
                        check(false, "\(suffix) screenshot encodes"); continue
                    }
                    try png.write(to: artifacts.appendingPathComponent("w213-coder-\(suffix).png"))
                    check(true, "\(suffix) screenshot saved")
                }
            }
        }
        // AppKit's horizontal code viewer is a separate panel, not a SwiftUI descendant.
        let codeScroll = ChatCodeBlockHorizontalViewer.makeScrollView(code: code)
        codeScroll.documentView?.setFrameSize(NSSize(width: 4000, height: 3000))
        verify(codeScroll, label: "code viewer", check: check)
        let originalOrigin = codeScroll.contentView.bounds.origin
        codeScroll.contentView.scroll(to: NSPoint(x: 180, y: 200))
        codeScroll.reflectScrolledClipView(codeScroll.contentView)
        check(codeScroll.contentView.bounds.origin != originalOrigin, "code viewer still scrolls both axes")
        let reading = codeScroll.contentView.bounds.origin
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        verify(codeScroll, label: "code viewer after preference notification", check: check)
        check(codeScroll.contentView.bounds.origin == reading, "code viewer notification preserves reading position")
        print("W213SCROLL SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }

    static func descendants(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(descendants)
    }

    static func verify(_ scroll: NSScrollView, label: String, check: (Bool, String) -> Void) {
        for (axis, scroller) in [("vertical", scroll.verticalScroller), ("horizontal", scroll.horizontalScroller)] {
            check(scroll.scrollerStyle == .overlay || scroller == nil || scroller!.isHidden,
                  "\(label) \(axis) never permanently visible (style=\(scroll.scrollerStyle.rawValue))")
        }
    }

    static func expandDisclosure(in host: NSView) -> Bool {
        var seen = Set<ObjectIdentifier>()
        func visit(_ node: NSObject) -> Bool {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return false }
            let role = NSSelectorFromString("accessibilityRole")
            if node.responds(to: role),
               let value = node.perform(role)?.takeUnretainedValue() as? String,
               value == NSAccessibility.Role.disclosureTriangle.rawValue,
               (node as AnyObject).accessibilityPerformPress?() == true { return true }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children),
               let nodes = node.perform(children)?.takeUnretainedValue() as? [NSObject],
               nodes.contains(where: visit) { return true }
            return (node as? NSView)?.subviews.contains(where: visit) ?? false
        }
        return visit(host)
    }
}
#endif
