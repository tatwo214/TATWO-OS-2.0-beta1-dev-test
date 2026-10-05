#if DEBUG
import AppKit
import Foundation

/// `TATWO2_SELFTEST=w179desk`：純邏輯驗收桌面圓鈕、展開尺寸、直達鍵。不建視窗、不註冊真的 Carbon 熱鍵
/// （換成記憶體裡的假註冊），UserDefaults 只用自己的暫時 suite，結束時刪掉。
enum GlobalDMDeskAcceptance {
    @MainActor static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W179DESK \(condition ? "PASS" : "FAIL") \(label)")
        }
        var suites: [String] = []
        func freshDefaults() -> UserDefaults? {
            let name = "ai.tatwo.selftest.w179desk.\(UUID().uuidString)"
            suites.append(name)
            return UserDefaults(suiteName: name)
        }
        defer { for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) } }
        guard let deskDefaults = freshDefaults(), let keyDefaults = freshDefaults(), let hotDefaults = freshDefaults(),
              let duoDefaults = freshDefaults(), let openDefaults = freshDefaults() else {
            print("W179DESK FAIL defaults suites")
            print("W179DESK SUMMARY failures=1 passed=0")
            return false
        }
        func key(_ name: String) -> GlobalDMDirectKey {
            guard let key = GlobalDMDirectKey(rawValue: name) else { preconditionFailure("unknown key \(name)") }
            return key
        }

        // 1. 四種形態（W184 AB：外直、內橫、內直、倒放）；比螢幕可用範圍大時等比縮小。
        check(GlobalDMForm.allCases.map(\.size) == [CGSize(width: 466, height: 678), CGSize(width: 890, height: 626),
                                                    CGSize(width: 626, height: 890), CGSize(width: 678, height: 466)],
              "four forms: outer portrait 466×678, inner landscape 890×626, inner portrait 626×890, tent 678×466")
        check(GlobalDMForm.allCases.filter(\.isDuo) == [.innerLandscape], "only inner landscape shows two columns")
        let roomy = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        check(GlobalDMForm.allCases.allSatisfy { GlobalDMDeskLayout.fitted($0.size, in: roomy) == $0.size },
              "every form fits unchanged on a roomy screen")
        let small = CGRect(x: 0, y: 25, width: 1024, height: 640)
        let duo = GlobalDMDeskLayout.fitted(GlobalDMForm.innerLandscape.size, in: small)
        check(duo.width < 890 && duo.height < 626 && duo.width <= small.width - 48 && duo.height <= small.height - 48
              && abs(duo.width / duo.height - 890.0 / 626.0) < 0.01,
              "890×626 scales down proportionally on a small screen (\(Int(duo.width))×\(Int(duo.height)))")
        let closed = GlobalDMDeskLayout.fitted(GlobalDMForm.outerPortrait.size, in: small)
        check(closed.height <= small.height - 48 && abs(closed.width / closed.height - 466.0 / 678.0) < 0.01,
              "466×678 (outer portrait) scales down proportionally on a small screen")
        let tallSmall = GlobalDMDeskLayout.fitted(GlobalDMForm.innerPortrait.size, in: small)
        check(tallSmall.height <= small.height - 48 && abs(tallSmall.width / tallSmall.height - 626.0 / 890.0) < 0.01,
              "626×890 (inner portrait) scales down proportionally on a small screen")
        check(GlobalDMDeskLayout.fitted(GlobalDMForm.tent.size, in: small) == CGSize(width: 678, height: 466),
              "sizes that fit stay exact on the small screen (tent 678×466)")
        let narrow = CGRect(x: 0, y: 0, width: 600, height: 1400)
        let narrowDuo = GlobalDMDeskLayout.fitted(GlobalDMForm.innerLandscape.size, in: narrow)
        check(narrowDuo.width <= 552 && abs(narrowDuo.width / narrowDuo.height - 890.0 / 626.0) < 0.01,
              "a narrow screen shrinks the wide duo by width")

        // 2. 圓鈕與圓鈕旁的框。
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let bubbleOrigin = GlobalDMDeskLayout.defaultBubbleOrigin(visible: screen)
        check(bubbleOrigin == CGPoint(x: 1440 - 24 - 44, y: 24), "default bubble: main screen bottom-right, inset 24")
        check(GlobalDMDeskLayout.placeBubble(saved: nil, visibleFrames: [screen], main: screen) == bubbleOrigin,
              "a bubble never dragged sits at the default spot")
        check(GlobalDMDeskLayout.placeBubble(saved: CGPoint(x: 300, y: 400), visibleFrames: [screen], main: screen)
              == CGPoint(x: 300, y: 400), "a dragged bubble stays where it was dropped")
        check(GlobalDMDeskLayout.placeBubble(saved: CGPoint(x: 1430, y: 870), visibleFrames: [screen], main: screen)
              == CGPoint(x: 1440 - 44, y: 875 - 44), "a bubble dropped past the edge is pulled fully on screen")
        check(GlobalDMDeskLayout.placeBubble(saved: CGPoint(x: 4000, y: 300), visibleFrames: [screen], main: screen)
              == bubbleOrigin, "a bubble left on an unplugged display returns to the main screen")
        let bubble = CGRect(origin: bubbleOrigin, size: CGSize(width: 44, height: 44))
        let dmBox = GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: GlobalDMForm.outerPortrait.size, visible: screen)
        check(dmBox.minY >= bubble.maxY && abs(dmBox.maxX - bubble.maxX) < 0.5 && screen.contains(dmBox),
              "the outer portrait form opens right above the bubble")
        // 擺位規則：上方放不下的高框改放圓鈕旁邊（量尺用 390×844；iPhone Duo 兩種尺寸都不高，另外驗開在上方）。
        let tall = GlobalDMDeskLayout.fitted(CGSize(width: 390, height: 844), in: screen)
        let tallBox = GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: tall, visible: screen)
        check(screen.contains(tallBox) && !tallBox.intersects(bubble) && tallBox.maxX <= bubble.minX,
              "a tall box goes beside the bubble, fully on screen")
        for form in [GlobalDMForm.outerPortrait, .innerLandscape, .tent] {
            let wanted = GlobalDMDeskLayout.fitted(form.size, in: screen)
            let box = GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: wanted, visible: screen)
            check(screen.contains(box) && !box.intersects(bubble) && box.minY >= bubble.maxY,
                  "\(form.title) opens above the bubble, fully on screen")
        }
        let tallForm = GlobalDMDeskLayout.fitted(GlobalDMForm.innerPortrait.size, in: screen)
        let tallFormBox = GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: tallForm, visible: screen)
        check(screen.contains(tallFormBox) && !tallFormBox.intersects(bubble)
              && abs(tallFormBox.width / tallFormBox.height - 626.0 / 890.0) < 0.01,
              "inner portrait (too tall above the bubble) opens beside it, fully on screen, same proportions")
        let corner = CGRect(origin: CGPoint(x: 30, y: 800), size: CGSize(width: 44, height: 44))
        let cornerBox = GlobalDMDeskLayout.boxBeside(bubble: corner, wanted: GlobalDMForm.tent.size, visible: screen)
        check(screen.contains(cornerBox) && !cornerBox.intersects(corner), "a bubble in the top-left corner still opens on screen")

        // 3. 記住形態與圓鈕位置；單按 ⌥⌘ 的設定。
        let desk = GlobalDMDeskSettings(defaults: deskDefaults)
        check(desk.form == .outerPortrait && desk.bubbleOrigin == nil
              && deskDefaults.object(forKey: GlobalDMDeskSettings.formKey) == nil,
              "defaults: the outer portrait form, bubble not moved, nothing written yet")
        desk.form = .innerLandscape
        desk.saveBubbleOrigin(CGPoint(x: 120, y: 260))
        let reread = GlobalDMDeskSettings(defaults: deskDefaults)
        check(reread.form == .innerLandscape && reread.bubbleOrigin == CGPoint(x: 120, y: 260)
              && deskDefaults.string(forKey: GlobalDMDeskSettings.formKey) == "innerLandscape",
              "last form and the dragged bubble position survive a relaunch")
        check(GlobalDMDeskSettings.chordToggleEnabled(deskDefaults), "single ⌥⌘ toggle is on by default")
        deskDefaults.set(false, forKey: GlobalDMDeskSettings.chordToggleKey)
        check(!GlobalDMDeskSettings.chordToggleEnabled(deskDefaults), "single ⌥⌘ toggle can be switched off")

        // 4. 擋鍵清單與衝突。
        let blocked: [(String, String)] = [("Esc", "⌥⌘Esc"), ("D", "⌥⌘D"), ("H", "⌥⌘H"), ("M", "⌥⌘M"), ("W", "⌥⌘W"),
                                           ("Space", "⌥⌘Space"), ("I", "⌥⌘I"), ("Down", "⌥⌘↓"), ("Up", "⌥⌘↑"),
                                           ("B", "⌥⌘B"), ("Tab", "⌥⌘Tab"), ("T", "⌥⌘T")]   // W184 G2c 第二輪：⌥⌘T＝私訊框 Browser 的新分頁
        let titles: (GlobalDMTarget) -> String = { target in
            switch target {
            case .assistant: "TATWO 助理"
            case .chatGPT: "ChatGPT"
            case .thread: "Coder 對話"
            }
        }
        for (name, combo) in blocked {
            let verdict = GlobalDMDirectKeyRules.verdict(key(name), for: .assistant, in: [:])
            let message = verdict.message(title: titles) ?? ""
            let isBlocked: Bool
            if case .blocked = verdict { isBlocked = true } else { isBlocked = false }
            check(isBlocked && message.hasPrefix(combo) && message.hasSuffix("不能用。"), "\(combo) is blocked: \(message)")
        }
        check(GlobalDMDirectKey(keyCode: 5) == key("G") && GlobalDMDirectKey(keyCode: 0x12) == key("1")
              && GlobalDMDirectKey(keyCode: 0x31) == .space && GlobalDMDirectKey(keyCode: 0x18) == nil,
              "keys are read by physical key position (G, 1, Space; = is not a choice)")
        check(key("G").display == "⌥⌘G" && GlobalDMDirectKey.down.display == "⌥⌘↓", "keys read as ⌥⌘G / ⌥⌘↓")
        let taken = GlobalDMDirectKeyRules.verdict(key("G"), for: .assistant, in: [.chatGPT: key("G")])
        check(taken == .taken(key("G"), by: .chatGPT) && taken.message(title: titles)?.contains("ChatGPT") == true,
              "a key another target uses is refused and names that target")
        check(GlobalDMDirectKeyRules.verdict(key("G"), for: .chatGPT, in: [.chatGPT: key("G")]) == .ok,
              "re-setting the same key on the same target is fine")
        check(GlobalDMDirectKeyVerdict.occupied(key("K")).message(title: titles) == "⌥⌘K 被別的 App 佔用了，換一個鍵試試。",
              "registration failure has a plain sentence")

        // 5. 直達鍵存取（GlobalDMStore）。
        let keyStore = GlobalDMStore(defaults: keyDefaults, chatGPTAllowed: { true })
        check(keyStore.directKeys == [.chatGPT: key("G")]
              && keyDefaults.object(forKey: GlobalDMDirectKeyBook.storageKey) == nil,
              "default direct key: only ⌥⌘G = ChatGPT, nothing written until changed")
        if case .blocked = keyStore.setDirectKey(key("D"), for: .assistant) {
            check(keyStore.directKeys[.assistant] == nil, "store refuses ⌥⌘D and keeps nothing")
        } else {
            check(false, "store refuses ⌥⌘D and keeps nothing")
        }
        check(keyStore.setDirectKey(key("G"), for: .assistant) == .taken(key("G"), by: .chatGPT)
              && keyStore.directKeys[.assistant] == nil, "store refuses a key ChatGPT already uses")
        let session = UUID()
        check(keyStore.setDirectKey(key("K"), for: .assistant) == .ok
              && keyStore.setDirectKey(key("1"), for: .thread(session)) == .ok,
              "assistant and a session get their own keys")
        let relaunched = GlobalDMStore(defaults: keyDefaults, chatGPTAllowed: { true })
        check(relaunched.directKeys == [.chatGPT: key("G"), .assistant: key("K"), .thread(session): key("1")],
              "direct keys survive a relaunch")
        keyStore.setDirectKey(nil, for: .chatGPT)
        check(GlobalDMStore(defaults: keyDefaults, chatGPTAllowed: { true }).directKeys[.chatGPT] == nil,
              "clearing ⌥⌘G stays cleared after a relaunch")
        let stored = keyDefaults.dictionary(forKey: GlobalDMDirectKeyBook.storageKey) as? [String: String] ?? [:]
        check(stored == ["assistant": "K", "thread:" + session.uuidString: "1"], "only target ids and key names are stored")
        if let legacy = freshDefaults() {
            legacy.set(["assistant": "B", "chatgpt": "G"], forKey: GlobalDMDirectKeyBook.storageKey)
            check(GlobalDMDirectKeyBook.load(from: legacy) == [.chatGPT: key("G")],
                  "a stored ⌥⌘B (TATWO's own browser key) is dropped on load")
        }
        let rightSide = GlobalDMStore(defaults: duoDefaults, chatGPTAllowed: { true }, directKeys: false)
        check(rightSide.directKeys.isEmpty && rightSide.setDirectKey(key("J"), for: .assistant) == .unsupported
              && duoDefaults.object(forKey: GlobalDMDirectKeyBook.storageKey) == nil,
              "the iPhone-open right side does not own direct keys")

        // 6. Carbon 熱鍵：註冊與移除成對、跟著開關與對照、被佔用時照實說。
        let fake = GlobalDMDeskFakeHotKeyBackend()
        let hotkeys = GlobalDMHotKeys(backend: fake)
        let hotStore = GlobalDMStore(defaults: hotDefaults, chatGPTAllowed: { true })
        var actions: [GlobalDMHotKeys.Action] = []
        hotkeys.onAction = { actions.append($0) }
        hotkeys.install(store: hotStore)
        let appWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        func appArrow(_ key: GlobalDMDirectKey, active: Bool = true) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .command],
                                        timestamp: 10, windowNumber: appWindow.windowNumber, context: nil,
                                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key.keyCode)!
            _ = hotkeys.handleAppKey(event, appActive: active)
        }
        check(fake.isActive && Set(fake.live.values) == [UInt32(0x05)]
              && hotkeys.registeredKeys == [key("G")],
              "install registers only direct G globally; both arrows stay free for other apps")
        fake.press(keyCode: 0x7D)
        fake.press(keyCode: 0x7E)
        fake.press(keyCode: 0x05)
        check(actions == [.direct(.chatGPT)], "global arrows do nothing; direct G opens ChatGPT")
        actions = []
        appArrow(.down, active: false)
        appArrow(.up)
        check(actions.isEmpty, "inactive TATWO arrows do nothing; ⌥⌘↑ does nothing before collapsing")
        appArrow(.down)
        check(actions == [.collapse], "foreground ⌥⌘↓ collapses")
        // W184 AB：⌘⌥Tab 只在私訊框看得到時註冊（收起就放掉，不搶別的 App 的鍵）；被佔用時照實說。
        check(!hotkeys.registeredKeys.contains(.tab) && !fake.live.values.contains(UInt32(0x30)),
              "⌘⌥Tab is not registered while the box is folded")
        hotkeys.isBoxShowing = true
        actions = []
        fake.press(keyCode: 0x30)
        check(hotkeys.registeredKeys.contains(.tab) && actions == [.cycleForm],
              "⌘⌥Tab is registered while the box shows and cycles the form")
        hotkeys.isBoxShowing = false
        check(!hotkeys.registeredKeys.contains(.tab) && !fake.live.values.contains(UInt32(0x30))
              && hotkeys.registeredKeys == [key("G")],
              "folding the box releases ⌘⌥Tab right away")
        fake.refused = [UInt32(0x30)]
        hotkeys.isBoxShowing = true
        check(hotkeys.failed.contains(.tab) && !hotkeys.registeredKeys.contains(.tab),
              "⌘⌥Tab held by another app is reported (the page circle's menu says so)")
        hotkeys.isBoxShowing = false
        fake.refused = []
        hotkeys.isSuspended = true
        hotkeys.isSuspended = false
        actions = []
        hotkeys.isCollapsed = true
        check(hotkeys.registeredKeys == [key("G")] && !fake.live.values.contains(0x7D),
              "while collapsed neither arrow is registered globally")
        actions = []
        fake.press(keyCode: 0x7D)
        fake.press(keyCode: 0x7E)
        check(actions.isEmpty, "collapsed: other-app arrows do nothing")
        appArrow(.down)
        appArrow(.up)
        check(actions == [.restore], "collapsed: foreground ⌥⌘↑ restores, ⌥⌘↓ does nothing")
        hotkeys.isCollapsed = false
        check(hotkeys.registeredKeys == [key("G")] && !fake.live.values.contains(0x7E),
              "back to the main window: ⌥⌘↑ is released again")
        hotStore.setDirectKey(key("K"), for: .assistant)
        check(hotkeys.registeredKeys == [key("G"), key("K")], "a new direct key is registered right away")
        hotStore.setDirectKey(nil, for: .chatGPT)
        check(hotkeys.registeredKeys == [key("K")] && !fake.live.values.contains(0x05),
              "a cleared direct key is unregistered")
        hotStore.isEnabled = false
        check(fake.live.isEmpty && hotkeys.registeredKeys.isEmpty, "master switch off removes every hotkey")
        hotStore.isEnabled = true
        check(hotkeys.registeredKeys == [key("K")], "master switch on registers them again")
        hotkeys.isSuspended = true
        check(fake.live.isEmpty, "hotkeys pause while the box waits for a new key")
        hotkeys.isSuspended = false
        check(hotkeys.registeredKeys == [key("K")], "hotkeys come back after picking a key")
        fake.refused = [UInt32(0x7E)]
        hotkeys.isSuspended = true
        hotkeys.isSuspended = false
        check(hotkeys.failed.isEmpty && !fake.live.values.contains(0x7E) && fake.live[GlobalDMHotKeys.probeID] == nil,
              "app arrows are never probed as Carbon hotkeys")
        fake.refused = []
        fake.refused = [UInt32(key("J").keyCode)]
        let occupied = hotkeys.assign(keyCode: key("J").keyCode, to: .thread(session), store: hotStore)
        check(occupied == .occupied(key("J")) && hotStore.directKeys[.thread(session)] == nil,
              "a key held by another app is refused and not saved")
        check(hotkeys.assign(keyCode: key("D").keyCode, to: .thread(session), store: hotStore)
              == .blocked(key("D"), reason: GlobalDMDirectKeyRules.blocked["D"] ?? ""),
              "setting ⌥⌘D in the box is blocked")
        check(hotkeys.assign(keyCode: key("L").keyCode, to: .thread(session), store: hotStore) == .ok
              && hotkeys.registeredKeys.contains(key("L")) && fake.live[GlobalDMHotKeys.probeID] == nil,
              "a free key is probed, saved and registered (the probe does not linger)")
        fake.refused = [UInt32(key("K").keyCode)]
        hotkeys.isSuspended = true
        hotkeys.isSuspended = false
        check(hotkeys.failed == [key("K")] && !hotkeys.registeredKeys.contains(key("K")),
              "a key taken by another app after the fact is reported as failed")
        fake.refused = []
        hotkeys.uninstall()
        check(fake.live.isEmpty && !fake.isActive && fake.registerCount == fake.unregisterCount,
              "uninstall removes every hotkey; register and unregister are paired (\(fake.registerCount))")
        actions = []
        fake.press(keyCode: 0x7D)
        check(actions.isEmpty, "after uninstall a key press does nothing")

        // 7. 縮起／恢復的狀態機（不記進檔案：重開 App 一定是一般主視窗）。
        let original = CGRect(x: 180, y: 90, width: 1180, height: 760)
        var machine = GlobalDMDeskMachine()
        check(!machine.isCollapsed, "launch starts with the normal main window")
        check(!machine.collapse(enabled: false, frame: original) && !machine.isCollapsed, "DM switched off: cannot collapse")
        check(machine.collapse(enabled: true, frame: original) && machine.isCollapsed, "⌥⌘↓ collapses and keeps the frame")
        check(!machine.collapse(enabled: true, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
              "a second ⌥⌘↓ changes nothing")
        check(machine.restore() == .frame(original) && !machine.isCollapsed, "⌥⌘↑ restores the original position and size")
        check(machine.restore() == .notCollapsed, "⌥⌘↑ when not collapsed leaves the frame alone")
        check(machine.collapse(enabled: true, frame: nil) && machine.restore() == .reopen,
              "collapsing with no visible main window reopens it on restore")
        let desktop = CGRect(x: 0, y: 0, width: 1440, height: 875)
        check(GlobalDMDeskLayout.restorableFrame(saved: original, visibleFrames: [desktop], main: desktop) == original,
              "a saved frame still on screen is restored exactly")
        let onExternal = CGRect(x: 1700, y: 120, width: 1200, height: 800)
        let pulledBack = GlobalDMDeskLayout.restorableFrame(saved: onExternal, visibleFrames: [desktop], main: desktop)
        check(desktop.contains(pulledBack) && pulledBack.size == onExternal.size,
              "saved frame on an unplugged display is restored onto the main screen")
        let tooBig = CGRect(x: 100, y: 200, width: 1800, height: 1100)
        check(GlobalDMDeskLayout.restorableFrame(saved: tooBig, visibleFrames: [desktop], main: desktop) == desktop,
              "a window larger than the now smaller screen is shrunk to fit it")
        let pastEdge = CGRect(x: 1200, y: 100, width: 800, height: 600)
        check(GlobalDMDeskLayout.restorableFrame(saved: pastEdge, visibleFrames: [desktop], main: desktop) == pastEdge,
              "a window hanging past the edge with its title bar still reachable stays put")
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let lowered = CGRect(x: 1500, y: 700, width: 1200, height: 800)
        let keptOnExternal = GlobalDMDeskLayout.restorableFrame(saved: lowered, visibleFrames: [desktop, external],
                                                                main: desktop)
        check(external.contains(keptOnExternal) && keptOnExternal.size == lowered.size,
              "a title bar above a still-plugged display is pulled down onto that display")
        check(GlobalDMDeskMachine() == GlobalDMDeskMachine() && !GlobalDMDeskMachine().isCollapsed,
              "a relaunch never starts collapsed")

        // 8. 直達鍵＝打開（不是開關），照 B 房規則選停靠框或浮動框。
        typealias Open = GlobalDMOpenAction
        check(Open.resolve(enabled: true, floatingOpen: false, dockedShowing: false, appActive: true, mainWindowVisible: true) == .openDocked
              && Open.resolve(enabled: true, floatingOpen: false, dockedShowing: false, appActive: false, mainWindowVisible: true) == .openFloating
              && Open.resolve(enabled: true, floatingOpen: false, dockedShowing: false, appActive: true, mainWindowVisible: false) == .openFloating
              && Open.resolve(enabled: true, floatingOpen: true, dockedShowing: false, appActive: false, mainWindowVisible: false) == .focusFloating
              && Open.resolve(enabled: true, floatingOpen: false, dockedShowing: true, appActive: true, mainWindowVisible: true) == .focusDocked
              && Open.resolve(enabled: false, floatingOpen: false, dockedShowing: false, appActive: true, mainWindowVisible: true) == .ignore,
              "direct key: visible main window → docked box, otherwise floating (next to the bubble when collapsed)")
        let openStore = GlobalDMStore(defaults: openDefaults, chatGPTAllowed: { true })
        let panels = GlobalDMPanelController(store: openStore, desk: GlobalDMDeskSettings(defaults: openDefaults),
                                             hostsWindows: false)
        let thread = UUID()
        openStore.select(.thread(thread))
        panels.open()
        check(openStore.isFloatingOpen && openStore.target == .thread(thread), "direct key opens the box on that target")
        panels.open()
        check(openStore.isFloatingOpen, "pressing the direct key again keeps the box open")
        openStore.isEditingDirectKeys = true
        openStore.select(.assistant)
        check(!openStore.isEditingDirectKeys && openStore.target == .assistant, "switching target leaves the key page")
        openStore.isEditingDirectKeys = true
        openStore.close()
        check(!openStore.isEditingDirectKeys, "closing the box leaves the key page")

        // 9. 內橫（W184 AB；以前叫 iPhone 打開）：右欄的對話預設上次的 session，不跟左欄重複。
        let a = UUID(), b = UUID()
        check(GlobalDMDuo.defaultSecondary(primary: .assistant, sessions: [a, b], chatGPTAvailable: true) == .thread(a),
              "inner landscape: right column defaults to the latest session")
        check(GlobalDMDuo.defaultSecondary(primary: .thread(a), sessions: [a, b], chatGPTAvailable: true) == .thread(b),
              "the right side never repeats the left target")
        check(GlobalDMDuo.defaultSecondary(primary: .assistant, sessions: [], chatGPTAvailable: true) == .chatGPT
              && GlobalDMDuo.defaultSecondary(primary: .chatGPT, sessions: [], chatGPTAvailable: true) == .assistant,
              "without sessions the right side takes ChatGPT or the assistant")
        let duoHolder = GlobalDMDuo(defaults: duoDefaults)
        let right = duoHolder.secondary
        right?.select(.chatGPT)
        check(right?.hasDirectKeys == false && duoDefaults.string(forKey: GlobalDMStore.lastTargetKey) == "chatgpt"
              && openDefaults.string(forKey: GlobalDMStore.lastTargetKey) != "chatgpt",
              "the right side remembers its own target without touching the left side")
        check(GlobalDMDuo(defaults: nil).secondary == nil, "without its own settings suite the box stays one column")

        print("W179DESK SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }
}

/// 記憶體裡的假 Carbon：記錄註冊、移除與按鍵；`refused` 模擬被別的 App 佔用。
@MainActor final class GlobalDMDeskFakeHotKeyBackend: GlobalDMHotKeyBackend {
    private(set) var isActive = false
    private(set) var live: [UInt32: UInt32] = [:]
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    var refused: Set<UInt32> = []
    private var onPress: (@MainActor (UInt32) -> Void)?

    func activate(onPress: @escaping @MainActor (UInt32) -> Void) {
        isActive = true
        self.onPress = onPress
    }

    func deactivate() {
        isActive = false
        onPress = nil
    }

    func register(id: UInt32, keyCode: UInt32) -> Bool {
        guard !refused.contains(keyCode), !live.values.contains(keyCode) else { return false }
        live[id] = keyCode
        registerCount += 1
        return true
    }

    func unregister(id: UInt32) {
        if live.removeValue(forKey: id) != nil { unregisterCount += 1 }
    }

    func press(keyCode: UInt32) {
        for (id, code) in live where code == keyCode { onPress?(id) }
    }
}
#endif
