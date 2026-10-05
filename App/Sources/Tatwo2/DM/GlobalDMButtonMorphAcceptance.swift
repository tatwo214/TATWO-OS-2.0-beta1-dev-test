#if DEBUG
import AppKit
import Carbon
import QuartzCore
import SwiftUI

/// `TATWO2_SELFTEST=w184button`：W184 F45——
/// F4 換形態的鍵讓使用者自己設（直達鍵頁「換形態」那一列、預設 ⌥⌘Tab、存檔讀回、壞值退回、跟直達鍵兩個方向互擋、系統保留鍵選不到、
/// 右鍵選單照目前的鍵寫、回到預設、同一套等鍵）；
/// F5 縮成桌面圓鈕時框開著圓鈕不出現：圓鈕長成框、框縮回圓鈕（取樣 0.05／0.12／0.25／0.44／0.6 秒、外殼一直在真的框後面、
/// 轉向不跳而且接著原本的速度、減少動態效果＝淡入淡出、外殼沒有框的內容、換形態與恢復主視窗直接到位、長縮途中換螢幕直接到位、
/// 長縮途中按外殼或圓鈕的位置＝點圓鈕、沒縮成圓鈕照舊直接開關）；另外一段用真的時鐘（計時器自己收尾、t＝0 在外殼建好之後）。
/// W184 F45 查核（#1、#2、#4–#8、#10）的反例都在這裡：退步就會失敗。
/// 只在完整隔離的 staging 跑：熱鍵是假的（記憶體裡的註冊）、設定是暫時的 suite、引擎資料夾必須未登入（不送引擎）；
/// 圓鈕與框是真的面板，動畫的時鐘由自測推（M15 除外）；畫面證據（PNG）寫到 TATWO2_SELFTEST_ARTIFACTS。
enum GlobalDMButtonMorphAcceptance {
    @MainActor final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: @autoclosure () -> String = "") {
            if condition { passed += 1 } else { failed += 1 }
            let detail = condition ? "" : evidence()
            print("W184BUTTON \(condition ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — " + String(detail.prefix(500)))")
        }
        func skip(_ label: String) {
            skipped += 1
            print("W184BUTTON SKIP \(label)")
        }
        func note(_ text: String) { print("W184BUTTON NOTE \(text)") }
    }

    @MainActor final class Clock {
        var now: CFTimeInterval = 100
    }

    /// SelfTest.swift 的一行註冊叫這裡：跑完就結束程式（同 w184forms 的做法）。
    @MainActor static func launch() {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            do { exit(try await run() ? 0 : 1) }
            catch { print("W184BUTTON FAIL \(error)"); print("W184BUTTON SUMMARY failures=1"); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"], let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w184button needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }
        let check = Checker()
        var suites: [String] = []
        func freshDefaults(_ name: String) -> UserDefaults {
            let suite = "ai.tatwo.selftest.w184button.\(name).\(UUID().uuidString)"
            suites.append(suite)
            return UserDefaults(suiteName: suite) ?? .standard
        }
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
        let artifacts = environment["TATWO2_SELFTEST_ARTIFACTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

        formKeyChecks(check, freshDefaults)
        await keyPageChecks(check, freshDefaults, artifacts: artifacts)
        morphModelChecks(check)
        let fixture = try await GlobalDMFormsAcceptance.Fixture.make(root: root, environment: environment)
        defer { fixture.engine.shutdownAll() }
        await morphChecks(check, freshDefaults, model: fixture.model, artifacts: artifacts)
        await dockedMorphChecks(check, freshDefaults, model: fixture.model)   // W184 AB（使用者 09-30）：停靠的圓鈕 ↔ 停靠框

        print("W184BUTTON SUMMARY failures=\(check.failed) passed=\(check.passed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    // MARK: - F4 換形態的鍵（純邏輯＋假的 Carbon 註冊）

    @MainActor static func key(_ name: String) -> GlobalDMDirectKey {
        guard let key = GlobalDMDirectKey(rawValue: name) else { preconditionFailure("unknown key \(name)") }
        return key
    }

    @MainActor static func formKeyChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) {
        let book = freshDefaults("book")
        check(GlobalDMFormKeyBook.load(from: book) == .tab && GlobalDMFormKeyBook.storageKey == "tatwo2.globalDM.formKey",
              "K1 nothing stored: the form key is ⌥⌘Tab (people who never changed it get exactly the old key)")
        book.set("S", forKey: GlobalDMFormKeyBook.storageKey)
        let readS = GlobalDMFormKeyBook.load(from: book)
        var fallbacks: [String] = []
        for bad in ["??", "", "D", "H", "M", "W", "I", "B", "Esc", "Space", "Down", "Up", "Tab", "s"] {
            book.set(bad, forKey: GlobalDMFormKeyBook.storageKey)
            if GlobalDMFormKeyBook.load(from: book) != .tab { fallbacks.append(bad) }
        }
        book.set(42, forKey: GlobalDMFormKeyBook.storageKey)   // 型別不對（不是字串）
        if GlobalDMFormKeyBook.load(from: book) != .tab { fallbacks.append("42") }
        check(readS == key("S") && fallbacks.isEmpty,
              "K1 a stored key reads back (S); broken values and system or TATWO keys (D, H, M, W, I, B, Esc, Space, ↓, ↑) fall back to Tab",
              "S=\(readS.rawValue) notFallingBack=\(fallbacks)")
        GlobalDMFormKeyBook.save(key("S"), to: book)
        let savedS = book.string(forKey: GlobalDMFormKeyBook.storageKey)
        GlobalDMFormKeyBook.save(.tab, to: book)
        check(savedS == "S" && book.object(forKey: GlobalDMFormKeyBook.storageKey) == nil,
              "K1 only the key name is stored; going back to Tab removes the entry (same as never changed)")

        // 假的 Carbon：框看得到才註冊換形態的鍵；改鍵、存檔、讀回、重新註冊。
        let fake = GlobalDMDeskFakeHotKeyBackend()
        let formDefaults = freshDefaults("formKey")
        let hotkeys = GlobalDMHotKeys(backend: fake, formDefaults: formDefaults)
        let store = GlobalDMStore(defaults: freshDefaults("store"), chatGPTAllowed: { true })
        var actions: [GlobalDMHotKeys.Action] = []
        hotkeys.onAction = { actions.append($0) }
        hotkeys.install(store: store)
        defer { hotkeys.uninstall() }
        let tab = UInt32(kVK_Tab)
        check(hotkeys.formKey == .tab && !fake.live.values.contains(tab), "K2 default ⌥⌘Tab, not registered while the box is folded")
        hotkeys.isBoxShowing = true
        fake.press(keyCode: tab)
        check(hotkeys.registeredKeys.contains(.tab) && actions == [.cycleForm], "K2 box showing: ⌥⌘Tab is registered and cycles the form")
        actions = []
        let setS = hotkeys.assignFormKey(keyCode: UInt16(kVK_ANSI_S), store: store)
        let sCode = UInt32(kVK_ANSI_S)
        fake.press(keyCode: tab)
        let tabIgnored = actions.isEmpty
        fake.press(keyCode: sCode)
        check(setS == .ok && hotkeys.formKey == key("S") && hotkeys.registeredKeys.contains(key("S")) && !hotkeys.registeredKeys.contains(.tab)
              && fake.live.values.contains(sCode) && !fake.live.values.contains(tab) && tabIgnored && actions == [.cycleForm]
              && formDefaults.string(forKey: GlobalDMFormKeyBook.storageKey) == "S",
              "K3 changed to ⌥⌘S: registered right away, ⌥⌘Tab no longer changes the form, ⌥⌘S does; saved as \"S\"",
              "verdict=\(setS) key=\(hotkeys.formKey.rawValue) registered=\(hotkeys.registeredKeys.map(\.rawValue)) actions=\(actions)")
        let relaunched = GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend(), formDefaults: formDefaults)
        check(relaunched.formKey == key("S"), "K3 the chosen key survives a relaunch")
        hotkeys.isBoxShowing = false
        check(!fake.live.values.contains(sCode) && !hotkeys.registeredKeys.contains(key("S")),
              "K4 folding the box releases the custom key too (only registered while the box shows)")
        hotkeys.isBoxShowing = true

        // 兩個方向都擋：換形態的鍵不能是直達鍵；直達鍵不能是換形態的鍵。
        let taken = hotkeys.assignFormKey(keyCode: UInt16(kVK_ANSI_G), store: store)
        let titles: (GlobalDMTarget) -> String = { store.title(for: $0) }
        check(taken == .taken(key("G"), by: .chatGPT) && hotkeys.formKey == key("S")
              && taken.message(title: titles)?.contains("⌥⌘G 已經給") == true,
              "K5 the form key cannot take a direct key (⌥⌘G = ChatGPT): refused, names the owner, nothing changes",
              "\(taken) \(taken.message(title: titles) ?? "")")
        let blockedDirect = hotkeys.assign(keyCode: UInt16(kVK_ANSI_S), to: .assistant, store: store)
        let blockedMessage = blockedDirect.message(title: titles) ?? ""
        check(blockedDirect == .blocked(key("S"), reason: "⌥⌘S 已經用來「換私訊框的形態」") && store.directKeys[.assistant] == nil
              && blockedMessage == "⌥⌘S 已經用來「換私訊框的形態」，不能用。",
              "K5 a direct key cannot take the form key: \(blockedMessage)", "\(blockedDirect)")
        check(GlobalDMDirectKeyRules.verdict(.tab, for: .assistant, in: [:], formKey: key("S")) == .unsupported
              && GlobalDMDirectKeyRules.verdict(.tab, for: .assistant, in: [:], formKey: .tab)
                == .blocked(.tab, reason: "⌥⌘Tab 已經用來「換私訊框的形態」"),
              "K5 the blocked list follows the current form key (Tab is only blocked while it is the form key)")

        // 系統保留鍵、不是英文字母或數字：選不到。
        var reserved: [String] = []
        for (name, code) in [("D", kVK_ANSI_D), ("H", kVK_ANSI_H), ("M", kVK_ANSI_M), ("W", kVK_ANSI_W), ("I", kVK_ANSI_I), ("B", kVK_ANSI_B),
                             ("Esc", kVK_Escape), ("Space", kVK_Space), ("Down", kVK_DownArrow), ("Up", kVK_UpArrow)] {
            if case .blocked = hotkeys.assignFormKey(keyCode: UInt16(code), store: store) { continue }
            reserved.append(name)
        }
        let equals = hotkeys.assignFormKey(keyCode: UInt16(kVK_ANSI_Equal), store: store)
        check(reserved.isEmpty && equals == .unsupported && hotkeys.formKey == key("S"),
              "K6 system and TATWO keys (⌥⌘D/H/M/W/I/B/Esc/Space/↓/↑) are refused with their reason; = is not a choice; the key stays ⌥⌘S",
              "accepted=\(reserved) equals=\(equals)")
        fake.refused = [UInt32(kVK_ANSI_K)]
        let busy = hotkeys.assignFormKey(keyCode: UInt16(kVK_ANSI_K), store: store)
        fake.refused = []
        check(busy == .occupied(key("K")) && hotkeys.formKey == key("S") && formDefaults.string(forKey: GlobalDMFormKeyBook.storageKey) == "S"
              && fake.live[GlobalDMHotKeys.probeID] == nil,
              "K7 a key another app holds is refused and not saved (the probe does not linger)")
        fake.refused = [sCode]
        hotkeys.isSuspended = true
        hotkeys.isSuspended = false
        check(hotkeys.failed.contains(key("S")), "K7 the custom key held by another app later is reported as failed (the menu says so)")
        fake.refused = []
        hotkeys.isSuspended = true
        hotkeys.isSuspended = false

        // 右鍵選單照目前的鍵寫。
        let menuS = GlobalDMMoreMenu.make(GlobalDMMoreMenuState(form: .outerPortrait, tabKeyFailed: true, formKey: hotkeys.formKey),
                                          actions: noopActions())
        let menuTab = GlobalDMMoreMenu.make(GlobalDMMoreMenuState(form: .outerPortrait, tabKeyFailed: true), actions: noopActions())
        let headingS = menuS.items.first { $0.identifier?.rawValue == "tatwo.dm.size" }?.title
        let busyS = menuS.items.first { $0.identifier?.rawValue == "tatwo.dm.form.keyBusy" }?.title
        let headingTab = menuTab.items.first { $0.identifier?.rawValue == "tatwo.dm.size" }?.title
        check(headingS == "形態（⌥⌘S 依序換）" && busyS == "⌥⌘S 被別的 App 佔用了，用這裡換形態" && headingTab == "形態（⌥⌘Tab 依序換）",
              "K8 the page circle's menu shows the current key (⌥⌘S after the change, ⌥⌘Tab by default) in the heading and the busy note",
              "\(headingS ?? "-") | \(busyS ?? "-") | \(headingTab ?? "-")")

        // 回到預設；按 Tab 也是回到預設。
        hotkeys.resetFormKey()
        let afterReset = hotkeys.formKey == .tab && formDefaults.object(forKey: GlobalDMFormKeyBook.storageKey) == nil
            && fake.live.values.contains(tab) && !fake.live.values.contains(sCode)
        let freed = hotkeys.assign(keyCode: UInt16(kVK_ANSI_S), to: .assistant, store: store)
        check(afterReset && freed == .ok && store.directKeys[.assistant] == key("S"),
              "K9 回到預設 brings ⌥⌘Tab back (entry removed, Tab registered) and ⌥⌘S is free for a direct key again", "\(freed)")
        store.setDirectKey(nil, for: .assistant)
        _ = hotkeys.assignFormKey(keyCode: UInt16(kVK_ANSI_J), store: store)
        let jSet = hotkeys.formKey == key("J")
        let back = hotkeys.assignFormKey(keyCode: UInt16(kVK_Tab), store: store)
        check(jSet && back == .ok && hotkeys.formKey == .tab && formDefaults.object(forKey: GlobalDMFormKeyBook.storageKey) == nil,
              "K9 pressing Tab in the recorder also goes back to the default")
    }

    @MainActor static func noopActions() -> GlobalDMMoreMenu.Actions {
        GlobalDMMoreMenu.Actions(setForm: { _ in }, openDirectKeys: {}, openAccessibility: {}, collapse: {}, restore: {}, close: {})
    }

    // MARK: - F4 直達鍵頁的「換形態」那一列（真的畫出來＋同一套等鍵）

    @MainActor static func keyPageChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, artifacts: URL?) async {
        let fake = GlobalDMDeskFakeHotKeyBackend()
        let hotkeys = GlobalDMHotKeys(backend: fake, formDefaults: freshDefaults("pageForm"))
        let store = GlobalDMStore(defaults: freshDefaults("pageStore"), chatGPTAllowed: { true })
        hotkeys.install(store: store)
        defer { hotkeys.uninstall() }
        hotkeys.isBoxShowing = true
        let size = CGSize(width: GlobalDMForm.outerPortrait.size.width, height: 360)
        guard let first = GlobalDMChatAcceptance.renderSync(GlobalDMDirectKeyPage(store: store, hotkeys: hotkeys), size: size) else {
            return check.skip("K10 直達鍵頁畫不出來（沒有畫面環境）")
        }
        let ids = GlobalDMChatAcceptance.identifiers(in: first)
        let labels = accessibilityLabels(in: first.window)
        save(first.bitmap, "keys-page-default.png", to: artifacts, check)
        first.close()
        if ids.isEmpty {
            check.skip("K10 無障礙樹拿不到識別碼（這個環境的 SwiftUI 沒建樹）；這一列改看畫出來的（K10 drawn）")
        } else {
            check(ids.isSuperset(of: ["tatwo.dm.keys", "tatwo.dm.keys.form", "tatwo.dm.keys.form.key", "tatwo.dm.keys.form.set",
                                      "tatwo.dm.keys.chatgpt"]) && !ids.contains("tatwo.dm.keys.form.reset")
                  && labels["tatwo.dm.keys.form.key"] == "⌥⌘Tab",
                  "K10 the direct-key page has a 換形態 row showing ⌥⌘Tab with 更改 (no 回到預設 while it is the default)",
                  "ids=\(ids.filter { $0.hasPrefix("tatwo.dm.keys") }.sorted()) key=\(labels["tatwo.dm.keys.form.key"] ?? "-")")
        }
        _ = hotkeys.assignFormKey(keyCode: UInt16(kVK_ANSI_S), store: store)
        if let changed = GlobalDMChatAcceptance.renderSync(GlobalDMDirectKeyPage(store: store, hotkeys: hotkeys), size: size) {
            let changedIDs = GlobalDMChatAcceptance.identifiers(in: changed)
            let changedLabels = accessibilityLabels(in: changed.window)
            save(changed.bitmap, "keys-page-form-key.png", to: artifacts, check)
            changed.close()
            if changedIDs.isEmpty {
                // 查核 #4：沒有樹也要算進 SUMMARY（不是默默沒驗）。
                check.skip("K10（改鍵後）無障礙樹拿不到識別碼（這個環境的 SwiftUI 沒建樹）；這一列改看畫出來的（K10 drawn）")
            } else {
                check(changedIDs.contains("tatwo.dm.keys.form.reset") && changedLabels["tatwo.dm.keys.form.key"] == "⌥⌘S",
                      "K10 after the change the row shows ⌥⌘S and offers 回到預設 (tatwo.dm.keys.form.reset)",
                      "key=\(changedLabels["tatwo.dm.keys.form.key"] ?? "-") ids=\(changedIDs.filter { $0.hasPrefix("tatwo.dm.keys.form") }.sorted())")
            }
            // 查核 #4、#6：不靠無障礙樹、比畫出來的鍵帽：預設 vs 改成 ⌥⌘S vs 回到預設，三張頁面。
            hotkeys.resetFormKey()
            let back = GlobalDMChatAcceptance.renderSync(GlobalDMDirectKeyPage(store: store, hotkeys: hotkeys), size: size)
            back?.close()
            let drawn = formRowDrawn(standard: first.bitmap, changed: changed.bitmap, reset: back?.bitmap)
            check(drawn.ok,
                  "K10 drawn (no accessibility tree needed): only the 換形態 row changes when the key does — its key cap (⌥⌘Tab → ⌥⌘S) and a 回到預設 icon in its slot only after the change; after 回到預設 the right side of the page is drawn exactly as before",
                  drawn.detail)
        } else {
            check.skip("K10（改鍵後）直達鍵頁畫不出來（沒有畫面環境）")
        }
        hotkeys.resetFormKey()

        // 同一套等鍵（GlobalDMKeyCapture）：只收這個面板、熱鍵暫停，按 ⌥⌘J 存成換形態的鍵；直達鍵被擋時一句話、繼續等；Esc 不設了。
        let capture = GlobalDMKeyCapture()
        let panel = GlobalDMPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 240, height: 80), styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        defer {
            capture.end()
            panel.orderOut(nil)
        }
        func post(_ code: Int, _ flags: NSEvent.ModifierFlags, _ text: String) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, characters: text,
                                               charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code)) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        capture.hostWindow = panel
        capture.beginForm(store: store, hotkeys: hotkeys)
        let started = capture.slot == .form && capture.target == nil && hotkeys.isSuspended && fake.live.isEmpty
        post(kVK_ANSI_J, [.command, .option], "j")
        _ = await DMBrowserAcceptance.waitUntil(1) { hotkeys.formKey == key("J") || capture.message != nil || capture.slot == nil }
        if hotkeys.formKey != key("J"), capture.slot == .form, capture.message == nil {
            return check.skip("K11 合成的按鍵沒送到面板（這個環境沒有鍵盤事件）；started=\(started)")
        }
        check(started && hotkeys.formKey == key("J") && capture.slot == nil && !hotkeys.isSuspended
              && hotkeys.registeredKeys.contains(key("J")),
              "K11 the 換形態 row uses the same recorder: hotkeys pause while it waits, ⌥⌘J pressed in the panel becomes the form key, hotkeys come back",
              "started=\(started) key=\(hotkeys.formKey.rawValue) slot=\(String(describing: capture.slot)) suspended=\(hotkeys.isSuspended) message=\(capture.message ?? "-")")
        capture.beginForm(store: store, hotkeys: hotkeys)
        post(kVK_ANSI_G, [.command, .option], "g")
        _ = await DMBrowserAcceptance.waitUntil(1) { capture.message != nil || capture.slot == nil }
        let refusedMessage = capture.message ?? ""
        let stillWaiting = capture.slot == .form && hotkeys.isSuspended
        post(kVK_Escape, [], "\u{1b}")
        _ = await DMBrowserAcceptance.waitUntil(1) { capture.slot == nil }
        check(refusedMessage.contains("⌥⌘G 已經給") && stillWaiting && hotkeys.formKey == key("J") && capture.slot == nil && !hotkeys.isSuspended,
              "K11 in the recorder a direct key is refused with one sentence and it keeps waiting; Esc leaves without changing anything",
              "message=\(refusedMessage) waiting=\(stillWaiting) key=\(hotkeys.formKey.rawValue) slot=\(String(describing: capture.slot))")
        hotkeys.resetFormKey()
    }

    /// 無障礙樹裡「識別碼 → 標籤」（找 GlobalDMKey 上寫的鍵）。同 GlobalDMChatAcceptance.identifiers 的走法：新式 API 空的再問舊式的。
    @MainActor static func accessibilityLabels(in window: NSWindow) -> [String: String] {
        func attribute(_ object: NSObject, _ name: String, legacy: String) -> Any? {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() {
                if let array = value as? [Any] {
                    if !array.isEmpty { return array }
                } else if let text = value as? String {
                    if !text.isEmpty { return text }
                } else {
                    return value
                }
            }
            let old = NSSelectorFromString("accessibilityAttributeValue:")
            guard object.responds(to: old) else { return nil }
            return object.perform(old, with: legacy)?.takeUnretainedValue()
        }
        var result: [String: String] = [:]
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 80, seen.count < 6000, let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let id = attribute(object, "accessibilityIdentifier", legacy: "AXIdentifier") as? String, !id.isEmpty {
                let label = attribute(object, "accessibilityLabel", legacy: "AXDescription") as? String
                let value = attribute(object, "accessibilityValue", legacy: "AXValue") as? String
                let title = attribute(object, "accessibilityTitle", legacy: "AXTitle") as? String
                result[id] = [label, value, title].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            }
            for child in attribute(object, "accessibilityChildren", legacy: "AXChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for sub in view.subviews { visit(sub, depth: depth + 1) } }
        }
        for _ in 0..<10 {
            visit(window, depth: 0)
            if result["tatwo.dm.keys.form.key"] != nil { break }
            seen = []
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return result
    }

    /// 查核 #4、#6：直達鍵頁「換形態」那一列畫出來的對不對（不靠無障礙樹）。只比頁面右側（右緣往左 8–200pt：鍵帽、更改、回到預設那一欄；
    /// 左邊的頭像不比）。預設 vs 改成 ⌥⌘S：不一樣的地方只有一列高（≤44pt）；鍵帽那一段（右緣往左 100–200pt）有變；
    /// 回到預設的位置（右緣往左 16–44pt、那一列）改鍵後才有圖示；回到預設之後右側跟預設那張一樣。白底（renderSync）。
    static func formRowDrawn(standard a: NSBitmapImageRep, changed b: NSBitmapImageRep, reset c: NSBitmapImageRep?) -> (ok: Bool, detail: String) {
        func usable(_ rep: NSBitmapImageRep) -> Bool {
            rep.bitsPerSample == 8 && !rep.isPlanar && rep.samplesPerPixel >= 3 && rep.bitmapData != nil && rep.pixelsWide == a.pixelsWide
                && rep.pixelsHigh == a.pixelsHigh && rep.size.width > 0
        }
        guard usable(a), usable(b) else { return (false, "pages are not comparable bitmaps (\(a.pixelsWide)×\(a.pixelsHigh) vs \(b.pixelsWide)×\(b.pixelsHigh))") }
        let scale = CGFloat(a.pixelsWide) / a.size.width, width = a.size.width
        func px(_ points: CGFloat) -> Int { min(a.pixelsWide, max(0, Int((points * scale).rounded()))) }
        func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Int, Int, Int) {
            guard let data = rep.bitmapData else { return (0, 0, 0) }
            let p = data + y * rep.bytesPerRow + x * rep.samplesPerPixel + (rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0)
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        func differs(_ p: (Int, Int, Int), _ q: (Int, Int, Int)) -> Bool { max(abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2)) > 24 }
        let right = px(width - 200)..<px(width - 8), keyColumns = px(width - 200)..<px(width - 100)
        var rows: [Int] = [], keyDiff = 0
        for y in 0..<a.pixelsHigh {
            var changedRow = false
            for x in right where differs(rgb(a, x, y), rgb(b, x, y)) {
                changedRow = true
                if keyColumns.contains(x) { keyDiff += 1 }
            }
            if changedRow { rows.append(y) }
        }
        guard let top = rows.first, let bottom = rows.last else {
            return (false, "the page looks the same after the key changed (the row does not show the current key)")
        }
        let bandHeight = CGFloat(bottom - top + 1) / scale
        let resetColumns = px(width - 44)..<px(width - 16)
        func ink(_ rep: NSBitmapImageRep) -> Int {
            var count = 0
            for y in top...bottom {
                for x in resetColumns {
                    let p = rgb(rep, x, y)
                    if 255 - min(p.0, p.1, p.2) > 24 { count += 1 }
                }
            }
            return count
        }
        let resetBefore = ink(a), resetAfter = ink(b)
        var backDiff = -1
        if let c, usable(c) {
            backDiff = 0
            for y in 0..<a.pixelsHigh { for x in right where differs(rgb(a, x, y), rgb(c, x, y)) { backDiff += 1 } }
        }
        let ok = bandHeight <= 44 && keyDiff > 10 && resetBefore <= 2 && resetAfter >= 20 && backDiff >= 0 && backDiff <= 4
        return (ok, "changed rows \(top)–\(bottom) (\(Int(bandHeight))pt) keyCapDiff=\(keyDiff) resetIcon before/after=\(resetBefore)/\(resetAfter) backToDefaultDiff=\(backDiff)")
    }

    // MARK: - F5 模型（純計算）

    /// 圓鈕（預設右下、內縮 24）與圓鈕上方的外直框（照 boxBeside）。
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    static var bubbleRect: CGRect {
        CGRect(origin: GlobalDMDeskLayout.defaultBubbleOrigin(visible: screen), size: CGSize(width: 44, height: 44))
    }
    static var boxRect: CGRect {
        GlobalDMDeskLayout.boxBeside(bubble: bubbleRect, wanted: GlobalDMForm.outerPortrait.size, visible: screen)
    }
    static let samples: [Double] = [0.05, 0.12, 0.25, 0.6]
    /// 量「有沒有內容」時四邊內縮多少：大於框的圓角 52（圓角外的底色、1pt 的邊、陰影都不算進來），只比框的中間。
    static let inkInset: CGFloat = 60

    /// 一串矩形是不是每一邊都一路朝 goal 走（不回頭、不衝過頭）。
    static func approaches(_ rects: [CGRect], _ goal: CGRect, slack: CGFloat = 0.5) -> Bool {
        func distances(_ r: CGRect) -> [CGFloat] { [abs(r.minX - goal.minX), abs(r.minY - goal.minY), abs(r.maxX - goal.maxX), abs(r.maxY - goal.maxY)] }
        for (a, b) in zip(rects, rects.dropFirst()) {
            for (da, db) in zip(distances(a), distances(b)) where db > da + slack { return false }
        }
        return true
    }

    static func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    static func describe(_ rects: [CGRect]) -> String {
        rects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" }.joined(separator: " | ")
    }

    @MainActor static func morphModelChecks(_ check: Checker) {
        check(GlobalDMMorphTiming.radius(for: CGSize(width: 44, height: 44)) == 22
              && GlobalDMMorphTiming.radius(for: GlobalDMForm.outerPortrait.size) == 52
              && GlobalDMMorphTiming.radius(for: CGSize(width: 80, height: 300)) == 40 && DMPhone.screenRadius == 52,
              "M1 the shell corner: the bubble is a circle (radius 22), the box is 52 (52 whenever the short side allows it)")
        let one = [screen], two = [screen, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let otherBox = CGRect(x: 1700, y: 200, width: 466, height: 678)
        typealias T = GlobalDMMorphTiming
        check(T.style(bubble: bubbleRect, box: boxRect, screens: one, reduceMotion: false) == .morph
              && T.style(bubble: bubbleRect, box: boxRect, screens: one, reduceMotion: true) == .fade
              && T.style(bubble: bubbleRect, box: otherBox, screens: two, reduceMotion: false) == .fade
              && T.style(bubble: bubbleRect, box: boxRect.offsetBy(dx: 9_000, dy: 0), screens: one, reduceMotion: false) == .fade,
              "M1 grow and shrink on one screen; reduce motion, or the bubble and the box on different screens, fade instead")
        let grow = GlobalDMMorphPlan(from: bubbleRect, to: boxRect, direction: .grow)
        let rects = [grow.rect(at: 0)] + samples.map { grow.rect(at: $0) }
        let radii = [0.0, 0.01, 0.02].map { grow.radius(at: $0) } + samples.map { grow.radius(at: $0) }
        let content = samples.map { grow.content(at: $0) }
        check(near(rects[0], bubbleRect, 0.01) && approaches(rects, boxRect) && near(grow.rect(at: 0.6), boxRect, 1)
              && zip(radii, radii.dropFirst()).allSatisfy { $1 >= $0 - 0.01 } && radii.first == 22 && radii.last == 52,
              "M2 grow (model): starts as the bubble, every edge moves one way toward the box, at 0.6 s it is the box (≤1pt); the corner goes 22 → 52",
              "rects=\(describe(rects)) radii=\(radii.map { Int($0) })")
        check(content[0] == 0 && content[1] == 0 && content[2] == 0 && content[3] > 0.999 && grow.content(at: 0.44) > 0.05
              && grow.content(at: 0.44) < 0.95,
              "M2 the real box's content stays transparent early (0.05 / 0.12 / 0.25 s = 0) and fades in late (0.36–0.52 s; 1 at 0.6 s)",
              "\(content) mid=\(grow.content(at: 0.44))")
        let shrink = GlobalDMMorphPlan(from: boxRect, to: bubbleRect, direction: .shrink)
        let back = [shrink.rect(at: 0)] + samples.map { shrink.rect(at: $0) }
        let backRadii = [shrink.radius(at: 0)] + samples.map { shrink.radius(at: $0) } + [shrink.radius(at: 1)]
        check(near(back[0], boxRect, 0.01) && approaches(back, bubbleRect) && near(shrink.rect(at: 0.6), bubbleRect, 1)
              && zip(backRadii, backRadii.dropFirst()).allSatisfy { $1 <= $0 + 0.01 } && backRadii.first == 52 && abs((backRadii.last ?? 0) - 22) < 0.5
              && samples.allSatisfy { shrink.content(at: $0) == 0 },
              "M2 shrink (model): starts as the box, every edge moves one way to the bubble, ≤1pt at 0.6 s; corner 52 → 22; no content",
              "rects=\(describe(back)) radii=\(backRadii.map { Int($0) })")
        var turned = grow
        let before = turned.rect(at: 0.12), speed = turned.speed(at: 0.12)
        turned.retarget(at: 0.12, direction: .shrink, to: bubbleRect)
        let after = turned.rect(at: 0.12), speedAfter = turned.speed(at: 0.12)
        check(near(before, after, 0.01) && abs(speed.height - speedAfter.height) < 0.01 && abs(speed.maxX - speedAfter.maxX) < 0.01
              && near(turned.rect(at: 0.72), bubbleRect, 1) && turned.direction == .shrink && turned.content(at: 0.5) == 0,
              "M3 turning mid-grow keeps the position and the speed (no jump) and ends on the bubble")
    }

    // MARK: - F5 真的面板（圓鈕、浮動框、外殼；時鐘由自測推）

    /// 讓圖層與 SwiftUI 的改動送出去（讀 presentation 之前）。
    @MainActor static func settleUI() {
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// W184 AB：收框＝框的內容先淡出 0.10 秒（外殼墊在框下面），淡完才收框、縮——時鐘推過那一段，回傳縮的那一段的 t＝0（時鐘）。
    /// 淡出本身的取樣在 M18 另外看。
    @MainActor static func closeBox(_ store: GlobalDMStore, _ morph: GlobalDMButtonMorph, _ clock: Clock, at time: Double) -> Double {
        clock.now = time
        store.isFloatingOpen = false
        guard morph.phase == .clearing else { return time }
        clock.now = time + GlobalDMMorphTiming.clearOut + 0.001
        morph.tick()
        return clock.now
    }

    @MainActor static func morphChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel,
                                       artifacts: URL?) async {
        let store = GlobalDMStore(defaults: freshDefaults("morphStore"), chatGPTAllowed: { true })
        store.isEnabled = true
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("morphDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        let browser = DMBrowser(store: store, openBox: {}, pageHost: DMBrowserAcceptance.FakeWebHost(), podPage: { nil })
        let hotkeys = GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend(), formDefaults: freshDefaults("morphKeys"))
        let desk = GlobalDMDeskController(store: store, settings: settings, hotkeys: hotkeys, panels: panels,
                                          duo: GlobalDMDuo(defaults: nil), browser: browser)
        panels.install()
        desk.install()
        let morph = panels.buttonMorph
        let clock = Clock()
        morph.manualTime = true
        morph.clock = { clock.now }
        morph.reduceMotion = { false }   // 固定：不看這台的系統設定（減少動態效果那一段 M12 自己打開）
        defer {
            morph.cancel()
            store.close()
            desk.uninstall()
            panels.uninstall()
            browser.closeAll()
        }
        let margin = GlobalDMLayout.margin

        // M0：沒縮成圓鈕＝照舊直接開關（沒有外殼、內容一開始就看得到）。
        clock.now = 10
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true }
        guard let floating = panels.floatingPanelForTesting, floating.isVisible, let canvas = floating.contentView as? GlobalDMPanelCanvas else {
            return check.skip("M0 這個環境開不出浮動框（沒有畫面環境）")
        }
        settleUI()
        check(morph.bubble?() == nil && morph.phase == .idle && morph.shell == nil && morph.presentedContent > 0.99,
              "M0 not collapsed: the floating box opens directly as before (no shell, content visible at once)",
              "phase=\(morph.phase) content=\(morph.presentedContent)")

        // M13：框開著時縮成圓鈕＝圓鈕不出現（框移到圓鈕旁）；收框＝框縮回圓鈕，到位才出現。
        desk.collapse()
        guard desk.isCollapsed, let bubble = morph.bubble?() else {
            return check.skip("M13 這個環境縮不成桌面圓鈕（沒有畫面環境）")
        }
        func circle() -> CGRect { bubble.frame.insetBy(dx: margin, dy: margin) }
        settleUI()
        let besideBox = floating.frame.insetBy(dx: margin, dy: margin)
        check(!bubble.isVisible && floating.isVisible && store.isFloatingOpen && !besideBox.intersects(circle()),
              "M13 collapsing while the box is open: the desktop bubble does not show; the box sits beside where the bubble is",
              "bubble=\(bubble.isVisible) box=\(besideBox) circle=\(circle())")
        let shrink13 = closeBox(store, morph, clock, at: 20)
        let collapsedShrink = morph.phase == .shrinking && morph.plan.map { near($0.target, circle(), 0.5) } == true
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        let hiddenWhileShrinking = !bubble.isVisible
        clock.now = shrink13 + 0.61
        morph.tick()
        check(collapsedShrink && hiddenWhileShrinking && bubble.isVisible && morph.phase == .idle && morph.shell == nil,
              "M13 closing it: the box shrinks into the bubble, which only shows when the shell arrives",
              "shrink=\(collapsedShrink) hidden=\(hiddenWhileShrinking) bubble=\(bubble.isVisible) phase=\(morph.phase)")
        check(bubble.isVisible && !store.isFloatingOpen && panels.dockedPanelForTesting?.isVisible != true,
              "M4 collapsed with the box folded: the desktop bubble shows (and there is no docked box beside it)")

        // M5：開框＝圓鈕長成框。
        clock.now = 100
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        let target = floating.frame.insetBy(dx: margin, dy: margin)
        let startCircle = circle()
        guard morph.phase == .growing, let shell = morph.shell, let plan = morph.plan else {
            return check(false, "M5 opening the box from the collapsed bubble starts the grow", "phase=\(morph.phase)")
        }
        var openRects: [CGRect] = [], openRadii: [CGFloat] = [], openContent: [Double: Float] = [:], issues: [String] = []
        var openFrameIssues: [String] = [], openOrder: [String] = [], orderUnknown = false
        var bubbleSeen = false
        var openFrames: [NSBitmapImageRep] = []
        var midFrame: NSBitmapImageRep?
        let region = startCircle.union(target).insetBy(dx: -40, dy: -40)
        // 查核 #7：多取 0.44 秒（內容淡入到一半、外殼還在）；每一格都看外殼是不是在真的框後面（視窗伺服器的前後順序）。
        for t in [0.0, 0.05, 0.12, 0.25, 0.44, 0.6] {
            clock.now = 100 + t
            morph.show(at: t)
            let rect = shell.presentedRect
            openRects.append(rect)
            openRadii.append(shell.presentedRadius)
            openContent[t] = morph.presentedContent
            if !near(rect, plan.rect(at: t), 1) { issues.append("t=\(t) presented \(rect) model \(plan.rect(at: t))") }
            if bubble.isVisible { bubbleSeen = true }
            let behind = isBehind(shell.panel, floating)
            if behind == nil { orderUnknown = true } else if behind == false { openOrder.append("t=\(t) shell in front of the box") }
            // 畫面證據照真實的視窗順序疊（外殼在後面＝先畫外殼、框疊上去）。
            let boxAbove = behind ?? true
            if [0.05, 0.12, 0.25].contains(t), let frame = renderFrame(region: region, shell: shell, box: canvas, panel: floating,
                                                                         boxAlpha: CGFloat(morph.presentedContent), boxAbove: boxAbove) {
                openFrames.append(frame)
                if !frameShowsShell(frame, shell: rect, region: region) { openFrameIssues.append("t=\(t) shell=\(rect)") }
            }
            if t == 0.44 {
                midFrame = renderFrame(region: region, shell: shell, box: canvas, panel: floating, boxAlpha: CGFloat(morph.presentedContent),
                                       boxAbove: boxAbove)
            }
            if t == 0.12 {
                // 長到一半有別的整理（重擺、換前景）：不重來、圓鈕照樣不出現。
                panels.reconcile()
                if morph.phase != .growing || morph.shell !== shell { issues.append("a reconcile mid-grow restarted or stopped it (phase=\(morph.phase))") }
                if bubble.isVisible { bubbleSeen = true }
            }
        }
        check(shell.panel.isVisible && near(openRects[0], startCircle, 1) && abs(openRadii[0] - 22) < 0.5 && issues.isEmpty,
              "M5 open: the bubble hides and the shell starts on the bubble (its frame and circle, radius 22) — the layers run the model",
              "start=\(openRects[0]) circle=\(startCircle) r=\(openRadii[0]) \(issues.prefix(3))")
        check(approaches(openRects, target) && near(openRects.last ?? .zero, target, 1)
              && zip(openRadii, openRadii.dropFirst()).allSatisfy { $1 >= $0 - 0.5 } && abs((openRadii.last ?? 0) - 52) < 0.5,
              "M5 open sampled at 0.05 / 0.12 / 0.25 / 0.44 / 0.6 s: the shell's rect moves one way to the box (≤1pt at 0.6 s), corner 22 → 52",
              "rects=\(describe(openRects)) radii=\(openRadii.map { Int($0) })")
        let early = [0.05, 0.12, 0.25].map { openContent[$0] ?? 1 }, half = openContent[0.44] ?? 0, full = openContent[0.6] ?? 0
        check(early.allSatisfy { $0 < 0.01 } && half > 0.05 && half < 0.95 && full > 0.99,
              "M5 open: the real box's content is transparent at 0.05 / 0.12 / 0.25 s, half in at 0.44 s and fully in at 0.6 s (it only comes up late)",
              "early=\(early) 0.44=\(half) 0.6=\(full)")
        if orderUnknown {
            check.skip("M5 order：這個環境查不到視窗的前後順序（NSWindow.windowNumbers／CGWindowList 都沒有這兩個面板）")
        } else {
            check(openOrder.isEmpty,
                  "M5 order: at every sample (0 → 0.6 s) the shell is behind the real box, so the content fades in over it (0.44 s: half in, the shell still under it)",
                  "\(openOrder)")
        }
        check(!bubbleSeen && !bubble.isVisible, "M6 while the box is open the desktop bubble is never on screen (every sample, a reconcile mid-grow)")
        check(openFrames.count == 3 && openFrameIssues.isEmpty,
              "M5 evidence frames (0.05 / 0.12 / 0.25 s) draw the shell where its layers are (its center on the surface, the far corner empty desktop)",
              "frames=\(openFrames.count) \(openFrameIssues)")
        clock.now = 100.61
        morph.tick()
        settleUI()
        check(morph.phase == .idle && morph.shell == nil && !shell.panel.isVisible && morph.presentedContent > 0.99 && floating.isVisible
              && !bubble.isVisible && near(floating.frame.insetBy(dx: margin, dy: margin), target, 0.5),
              "M5 once it is in place the shell is taken down; the real box stays exactly where it grew to, fully visible; still no bubble",
              "phase=\(morph.phase) content=\(morph.presentedContent) bubble=\(bubble.isVisible)")
        // 框開著時的整理、換螢幕（圓鈕照新螢幕重擺）：圓鈕照樣不出現。
        panels.reconcile()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        settleUI()
        check(!bubble.isVisible && floating.isVisible && store.isFloatingOpen && morph.phase == .idle && morph.shell == nil,
              "M6 with the box open, a reconcile or a screen change does not bring the bubble back")
        saveFrames(openFrames, prefix: "morph-open", to: artifacts, check)
        save(midFrame, "morph-open-0.44.png", to: artifacts, check)   // 查核 #7：內容淡入到一半、疊在外殼上面（照真實的視窗順序畫）

        // M7：外殼沒有框的內容：圖層只有底色、紙紋、邊框、陰影；畫出來的外殼中間沒有字（真的框的中間有）。
        let shrink7 = closeBox(store, morph, clock, at: 150)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        clock.now = shrink7 + 0.61
        morph.tick()
        clock.now = 160
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        if let probe = morph.shell {
            morph.show(at: 0.25)
            let layers = probe.allLayers
            let paper = probe.surface.paper
            let foreign = layers.filter { layer in
                guard let contents = layer.contents else { return false }
                return paper.map { (contents as AnyObject) !== $0 } ?? true
            }
            let shellRect = probe.presentedRect
            let shellInk = inkFraction(renderShell(probe, rect: shellRect), inset: inkInset)
            check(probe.view.subviews.isEmpty && foreign.isEmpty && layers.count <= 5,
                  "M7 the shell holds no picture of the box: no subviews, its layers' contents are only the paper tile (\(layers.count) layers)",
                  "foreign=\(foreign.count) subviews=\(probe.view.subviews.count)")
            clock.now = 160.61
            morph.tick()
            settleUI()
            canvas.layoutSubtreeIfNeeded()
            let boxInk = inkFraction(renderPanel(canvas, rect: floating.frame.insetBy(dx: margin, dy: margin), panel: floating), inset: inkInset)
            check(shellInk < 0.002 && boxInk > shellInk + 0.004,
                  "M7 drawn: the middle of the shell mid-grow is plain paper (no text, pairing code or page pixels) while the real box's middle has its content",
                  "shellInk=\(shellInk) boxInk=\(boxInk) shell=\(shellRect)")
        } else {
            check(false, "M7 a grow started for the content check", "phase=\(morph.phase)")
        }

        // M18（W184 AB 補 F45 查核 #3）：收框＝框的內容先淡出 0.10 秒——框還開著、內容還在（GlobalDMFloatingRoot 照樣留著）、透明度
        // 0.03／0.08 秒介於 0 和 1 之間而且在變小；外殼停在框的位置、墊在框下面；這段時間的整理不收框；淡完才收框、同一個外殼開始縮。
        let openBox = floating.frame.insetBy(dx: margin, dy: margin)
        clock.now = 200
        store.isFloatingOpen = false
        guard morph.phase == .clearing, let back = morph.shell else {
            return check(false, "M18 closing from bubble mode starts with the content fade (the shell under the box)", "phase=\(morph.phase) shell=\(morph.shell != nil)")
        }
        var fadeContent: [Double: Float] = [:], fadeIssues: [String] = [], fadeOrderUnknown = false
        for t in [0.0, 0.03, 0.08] {
            clock.now = 200 + t
            morph.show(at: t)
            fadeContent[t] = morph.presentedContent
            if t == 0.03 {
                panels.reconcile()   // 淡出途中有整理：不收框
                settleUI()
            }
            if !floating.isVisible { fadeIssues.append("t=\(t) the box is already put away") }
            if morph.phase != .clearing { fadeIssues.append("t=\(t) phase=\(morph.phase)") }
            if !near(back.presentedRect, openBox, 1) { fadeIssues.append("t=\(t) the shell moved: \(back.presentedRect)") }
            if bubble.isVisible { fadeIssues.append("t=\(t) the bubble shows") }
            if DMBrowserPhoneAcceptance.views(NSTextView.self, in: canvas.host).isEmpty { fadeIssues.append("t=\(t) the content is gone (no composer)") }
            switch isBehind(back.panel, floating) {
            case nil: fadeOrderUnknown = true
            case false?: fadeIssues.append("t=\(t) the shell is in front of the box")
            default: break
            }
        }
        let fadeEarly = fadeContent[0.03] ?? -1, fadeLate = fadeContent[0.08] ?? -1
        clock.now = 200 + GlobalDMMorphTiming.clearOut + 0.001
        morph.tick()
        let shrinkAt = clock.now
        let shrinkAfter = morph.phase == .shrinking && morph.shell === back && !floating.isVisible && !bubble.isVisible
        check((fadeContent[0] ?? 0) > 0.99 && fadeEarly > 0.01 && fadeEarly < 0.99 && fadeLate > 0.01 && fadeLate < fadeEarly && fadeIssues.isEmpty && shrinkAfter,
              "M18 (W184 AB, F45 #3) closing from bubble mode: the content fades out first — the box stays up with its content (0.03 / 0.08 s: opacity between 0 and 1, falling), the shell sits still on the box and behind it, a reconcile meanwhile does not put the box away — and only after 0.10 s is the box put away and the same shell starts shrinking",
              "0=\(fadeContent[0] ?? -1) 0.03=\(fadeEarly) 0.08=\(fadeLate) shrinkAfter=\(shrinkAfter) phase=\(morph.phase) \(fadeIssues.prefix(4))")
        if fadeOrderUnknown { check.skip("M18 order：這個環境查不到視窗的前後順序") }
        guard morph.phase == .shrinking, let backPlan = morph.plan else {
            return check(false, "M8 after the content fade the shrink starts", "phase=\(morph.phase)")
        }
        var closeRects: [CGRect] = [], closeRadii: [CGFloat] = [], closeFrames: [NSBitmapImageRep] = [], closeIssues: [String] = []
        var closeFrameIssues: [String] = []
        var bubbleEarly = false
        for t in [0.0] + samples {
            clock.now = shrinkAt + t
            morph.show(at: t)
            closeRects.append(back.presentedRect)
            closeRadii.append(back.presentedRadius)
            if !near(back.presentedRect, backPlan.rect(at: t), 1) { closeIssues.append("t=\(t)") }
            if bubble.isVisible { bubbleEarly = true }
            if [0.05, 0.12, 0.25].contains(t), let frame = renderFrame(region: region, shell: back, box: nil, panel: nil, boxAlpha: 0) {
                closeFrames.append(frame)
                if !frameShowsShell(frame, shell: back.presentedRect, region: region) { closeFrameIssues.append("t=\(t) shell=\(back.presentedRect)") }
            }
            if t == 0 { _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible } }
        }
        check(near(closeRects[0], openBox, 1) && abs(closeRadii[0] - 52) < 0.5 && approaches(closeRects, circle())
              && near(closeRects.last ?? .zero, circle(), 1) && zip(closeRadii, closeRadii.dropFirst()).allSatisfy { $1 <= $0 + 0.5 }
              && closeIssues.isEmpty && !floating.isVisible,
              "M8 close: the shell starts on the box (corner 52), moves one way back to the bubble (≤1pt at 0.6 s), corner shrinks; the real box is gone",
              "rects=\(describe(closeRects)) radii=\(closeRadii.map { Int($0) }) \(closeIssues)")
        check(!bubbleEarly, "M8 close: the bubble stays hidden until the shell arrives")
        check(closeFrames.count == 3 && closeFrameIssues.isEmpty,
              "M8 evidence frames (0.05 / 0.12 / 0.25 s) draw the shell where its layers are (its center on the surface, the far corner empty desktop)",
              "frames=\(closeFrames.count) \(closeFrameIssues)")
        clock.now = shrinkAt + 0.61
        morph.tick()
        check(bubble.isVisible && morph.phase == .idle && !back.panel.isVisible && morph.shell == nil,
              "M8 close: when the shell arrives the bubble shows and the shell is taken down")
        settleUI()
        check(morph.presentedContent > 0.99 || floating.contentView?.alphaValue == 1,
              "M18 once the box is put away its content's opacity is back to 1 (the next open starts clean)",
              "alpha=\(floating.contentView?.alphaValue ?? -1)")

        // M18（W184 AB）淡出途中又打開：點圓鈕本來的位置（看不見的點擊區）、按 ⌥⌘——內容從當下的透明度淡回來、外殼拆掉、框照舊開著、
        // 圓鈕照樣藏著；淡回來之後內容全看得到。
        for (way, reopen) in [("the bubble's spot", { () -> Void in
                                    if let catcher = morph.catcherPanel { press(catcher, at: CGPoint(x: catcher.frame.midX, y: catcher.frame.midY)) }
                                }), ("⌥⌘", { () -> Void in panels.handleToggle() })] {
            if !store.isFloatingOpen {
                clock.now = 230
                store.openFloating()
                _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
                clock.now = 230.61
                morph.tick()
                settleUI()
            }
            clock.now = 240
            store.isFloatingOpen = false
            let fading = morph.phase == .clearing
            let catcherUp = morph.catcherPanel?.isVisible == true
            clock.now = 240.05
            morph.show(at: 0.05)
            let before = morph.presentedContent
            reopen()
            _ = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .fadingIn && store.isFloatingOpen }
            morph.show(at: 0.05)
            let turned = morph.phase == .fadingIn && morph.shell == nil && floating.isVisible && store.isFloatingOpen && !bubble.isVisible
            let resumed = abs(morph.presentedContent - before) < 0.1
            clock.now = 240.2
            morph.tick()
            settleUI()
            let back = morph.phase == .idle && morph.presentedContent > 0.99 && floating.isVisible && !bubble.isVisible && morph.catcherPanel?.isVisible != true
            check(fading && catcherUp && turned && resumed && back,
                  "M18 (W184 AB) reopening mid-fade via \(way): the content fades back in from where it was (no jump), the shell comes down, the box stays open and the bubble stays hidden; then the content is fully visible",
                  "fading=\(fading) catcher=\(catcherUp) before=\(before) turned=\(turned) resumed=\(resumed) back=\(back) phase=\(morph.phase)")
        }
        _ = closeBox(store, morph, clock, at: 250)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        clock.now = 250.1 + 0.61
        morph.tick()
        settleUI()
        saveFrames(closeFrames, prefix: "morph-close", to: artifacts, check)

        // M9：轉向：長到一半收起＝從當下縮回；縮到一半又打開＝從當下長回去。
        clock.now = 300
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        if let turning = morph.shell {
            clock.now = 300.12
            morph.show(at: 0.12)
            let before = turning.presentedRect
            store.isFloatingOpen = false
            morph.show(at: 0.12)
            let after = turning.presentedRect
            // 查核 #8：轉向之後圖層照新的一段走（0.16／0.3 秒跟模型 ≤1pt），而且接著原本的速度：正在變大，收起後先再大一點才回頭
            // （速度被歸零的話 0.04 秒後反而已經變小：同一刻的位置一樣也分得出來）。
            morph.show(at: 0.16)
            let next = turning.presentedRect
            let model16 = morph.plan?.rect(at: 0.16)
            morph.show(at: 0.3)
            let later = turning.presentedRect
            let model30 = morph.plan?.rect(at: 0.3)
            let sameShell = morph.shell === turning && morph.phase == .shrinking
            _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
            clock.now = 300.12 + 0.61
            morph.tick()
            let onNew16 = model16.map { near(next, $0, 1) } ?? false, onNew30 = model30.map { near(later, $0, 1) } ?? false
            check(sameShell && near(before, after, 1) && next.height > after.height && onNew16 && onNew30 && bubble.isVisible,
                  "M9 closing mid-grow turns the same shell around from where it is (no jump), carrying its speed (still growing a moment, then back; the layers run the new segment ≤1pt at 0.16 / 0.3 s) and ends on the bubble",
                  "before=\(before) after=\(after) next=\(next) model16=\(String(describing: model16)) later=\(later) model30=\(String(describing: model30)) same=\(sameShell)")
        } else {
            check(false, "M9 a grow started for the turn")
        }
        clock.now = 400
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        clock.now = 400.61
        morph.tick()
        let shrink9 = closeBox(store, morph, clock, at: 500)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        if let turning = morph.shell, morph.phase == .shrinking {
            clock.now = shrink9 + 0.12
            morph.show(at: 0.12)
            let before = turning.presentedRect
            store.openFloating()
            _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
            var turnOrder: [String] = [], turnOrderUnknown = false
            func noteOrder(_ t: Double) {
                let behind = isBehind(turning.panel, floating)
                if behind == nil { turnOrderUnknown = true } else if behind == false { turnOrder.append("t=\(t) shell in front of the box") }
            }
            morph.show(at: 0.12)
            let after = turning.presentedRect
            noteOrder(0.12)
            let regrow = morph.phase == .growing && morph.shell === turning
            let hidden = !bubble.isVisible
            // 查核 #8：接著原本的速度（正在變小：打開後先再小一點才長回去），圖層照新的一段走（≤1pt）。
            morph.show(at: 0.16)
            let next = turning.presentedRect
            let model16 = morph.plan?.rect(at: 0.16)
            noteOrder(0.16)
            morph.show(at: 0.3)
            let later = turning.presentedRect
            let model30 = morph.plan?.rect(at: 0.3)
            noteOrder(0.3)
            morph.show(at: 0.12 + 0.25)
            let contentEarly = morph.presentedContent
            noteOrder(0.37)
            clock.now = shrink9 + 0.12 + 0.61
            morph.tick()
            settleUI()
            let onNew16 = model16.map { near(next, $0, 1) } ?? false, onNew30 = model30.map { near(later, $0, 1) } ?? false
            let settled = floating.isVisible && morph.phase == .idle && morph.presentedContent > 0.99 && !bubble.isVisible
            check(regrow && near(before, after, 1) && next.height < after.height && onNew16 && onNew30 && hidden && contentEarly < 0.01 && settled,
                  "M9 opening mid-shrink grows back from where the shell is (no jump), carrying its speed (still shrinking a moment, then growing; ≤1pt of the new segment at 0.16 / 0.3 s); the bubble never shows; the content fades in late again",
                  "before=\(before) after=\(after) next=\(next) model16=\(String(describing: model16)) later=\(later) model30=\(String(describing: model30)) regrow=\(regrow) contentEarly=\(contentEarly)")
            // 查核 #7：長回去時外殼也在真的框後面（框的內容淡入要蓋在外殼上）。
            if turnOrderUnknown {
                check.skip("M9 order：這個環境查不到視窗的前後順序")
            } else {
                check(turnOrder.isEmpty, "M9 order: growing back, the shell goes behind the real box again (0.12 / 0.16 / 0.3 / 0.37 s)", "\(turnOrder)")
            }
        } else {
            check(false, "M9 a shrink started for the turn", "phase=\(morph.phase)")
        }

        // M17（查核 #1）：長、縮途中按畫出來的外殼、或圓鈕本來的位置＝點圓鈕（開↔收，走同一個轉向）；外殼以外透明的地方不接。
        await pressChecks(check, store: store, morph: morph, floating: floating, bubble: bubble, clock: clock)

        // M16（查核 #10）：長、縮到一半換螢幕（插拔螢幕、改解析度）＝直接到位：長的那一段＝外殼拆掉、內容全看得到、圓鈕照樣藏著；
        // 縮的那一段＝圓鈕出現（之後照新螢幕擺圓鈕）。
        clock.now = 590
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        if let moving = morph.shell {
            clock.now = 590.12
            morph.show(at: 0.12)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            settleUI()
            let spotGone = morph.catcherPanel?.isVisible != true
            let boxShown = floating.isVisible && store.isFloatingOpen && morph.presentedContent > 0.99
            check(morph.phase == .idle && morph.shell == nil && !moving.panel.isVisible && boxShown && !bubble.isVisible && spotGone,
                  "M16 a screen change mid-grow puts it straight at its end: the shell is down, the box fully visible, the bubble still hidden",
                  "phase=\(morph.phase) content=\(morph.presentedContent) bubble=\(bubble.isVisible)")
        } else {
            check(false, "M16 a grow started for the screen change", "phase=\(morph.phase)")
        }
        let shrink16 = closeBox(store, morph, clock, at: 595)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        if let moving = morph.shell, morph.phase == .shrinking {
            clock.now = shrink16 + 0.12
            morph.show(at: 0.12)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            settleUI()
            let spotGone = morph.catcherPanel?.isVisible != true
            check(morph.phase == .idle && morph.shell == nil && !moving.panel.isVisible && bubble.isVisible && !store.isFloatingOpen && spotGone,
                  "M16 a screen change mid-shrink puts it straight at its end: the shell is down and the bubble shows",
                  "phase=\(morph.phase) bubble=\(bubble.isVisible)")
        } else {
            check(false, "M16 a shrink started for the screen change", "phase=\(morph.phase)")
        }

        // M10：長到一半換形態＝先到位（框的內容照常），再照 F3 換。
        let shrink10 = closeBox(store, morph, clock, at: 600)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        clock.now = shrink10 + 0.61
        morph.tick()
        clock.now = 610
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        let growingShell = morph.shell
        _ = desk.setForm(.innerLandscape, animated: false)
        settleUI()
        check(morph.phase == .idle && morph.shell == nil && growingShell?.panel.isVisible == false && morph.presentedContent > 0.99
              && !bubble.isVisible && settings.form == .innerLandscape,
              "M10 a form change mid-grow puts the grow straight at its end first (shell down, content visible, bubble still hidden)",
              "phase=\(morph.phase) content=\(morph.presentedContent)")
        _ = desk.setForm(.outerPortrait, animated: false)
        _ = await DMBrowserAcceptance.waitUntil(1) { floating.isVisible }

        // M11：圓鈕被拖到別的地方：從圓鈕「現在」的位置長出、縮回（動畫開始那一刻讀 frame，不另存）。
        let shrink11 = closeBox(store, morph, clock, at: 700)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        clock.now = shrink11 + 0.61
        morph.tick()
        let moved = bubble.frame.origin
        bubble.setFrameOrigin(NSPoint(x: moved.x - 300, y: moved.y + 120))
        let movedCircle = circle()
        clock.now = 710
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        let movedStart = morph.shell.map { shell -> CGRect in
            morph.show(at: 0)
            return shell.presentedRect
        }
        clock.now = 710.61
        morph.tick()
        check(movedStart.map { near($0, movedCircle, 1) } == true && !bubble.isVisible,
              "M11 a bubble moved elsewhere: the box grows from where the bubble is now (frame read when the animation starts)",
              "start=\(String(describing: movedStart)) circle=\(movedCircle)")
        let shrink11b = closeBox(store, morph, clock, at: 720)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        let endsAt = morph.plan?.target
        clock.now = shrink11b + 0.61
        morph.tick()
        check(endsAt.map { near($0, movedCircle, 0.5) } == true && bubble.isVisible && near(circle(), movedCircle, 0.5),
              "M11 and shrinks back to that same place, where the bubble shows again",
              "endsAt=\(String(describing: endsAt)) circle=\(movedCircle)")
        bubble.setFrameOrigin(moved)

        // M12：減少動態效果：不長不縮，淡入淡出。
        morph.reduceMotion = { true }
        clock.now = 800
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .fadingIn }
        var fadeIn: [Float] = []
        for t in [0.0, 0.075, 0.15] {
            clock.now = 800 + t
            morph.show(at: t)
            fadeIn.append(morph.presentedContent)
        }
        let noShell = morph.shell == nil, bubbleGone = !bubble.isVisible
        clock.now = 800.16
        morph.tick()
        check(morph.phase == .idle && noShell && bubbleGone && fadeIn[0] < 0.01 && fadeIn[1] > 0.1 && fadeIn[1] < 0.9 && fadeIn[2] > 0.99,
              "M12 reduce motion, open: no shell (nothing grows), the bubble hides and the box fades in over 0.15 s", "\(fadeIn)")
        let closedBox = floating.frame.insetBy(dx: margin, dy: margin)
        clock.now = 900
        store.isFloatingOpen = false
        // W184 AB：減少動態效果＝框本身（內容連同框）淡掉 0.12 秒、沒有外殼；淡完才收框，圓鈕 0.15 秒淡入；什麼都不動。
        if morph.phase == .clearing, morph.shell == nil {
            var boxFade: [Float] = [], stayed = true, bubbleEarly = false
            for t in [0.0, 0.06] {
                clock.now = 900 + t
                morph.show(at: t)
                boxFade.append(morph.presentedContent)
                stayed = stayed && floating.isVisible && near(floating.frame.insetBy(dx: margin, dy: margin), closedBox, 0.5)
                bubbleEarly = bubbleEarly || bubble.isVisible
            }
            clock.now = 900.12
            morph.tick()
            let bubbleAt012 = bubble.isVisible && !floating.isVisible && morph.phase == .fadingOut
            clock.now = 900.2
            morph.show(at: 0.2)
            let bubbleMid = morph.presentedBubble(bubble)
            clock.now = 900.28
            morph.tick()
            settleUI()
            check(stayed && !bubbleEarly && boxFade[0] > 0.99 && boxFade[1] > 0.05 && boxFade[1] < 0.95 && bubbleAt012
                  && bubbleMid > 0.05 && bubbleMid < 0.95 && morph.phase == .idle && morph.presentedBubble(bubble) > 0.99 && bubble.isVisible,
                  "M12 reduce motion, close: no shell; the box itself (content and frame) fades out in place (0.12 s), then it is put away and the bubble fades in (0.15 s); nothing moves",
                  "fade=\(boxFade) stayed=\(stayed) early=\(bubbleEarly) bubble012=\(bubbleAt012) mid=\(bubbleMid)")
        } else {
            check(false, "M12 reduce motion, close fades the box itself", "phase=\(morph.phase) shell=\(morph.shell != nil)")
        }
        morph.reduceMotion = { false }
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }

        // M15（查核 #5、#2）：真的時鐘（正式的路）：計時器自己收尾；t＝0 在外殼建好之後。
        await realClockChecks(check, store: store, morph: morph, floating: floating, bubble: bubble, clock: clock)

        // M14：長到一半恢復主視窗＝外殼馬上拆掉、圓鈕不回來（框跟著收）。
        clock.now = 1_000
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        let restoring = morph.shell
        clock.now = 1_000.2
        morph.show(at: 0.2)
        desk.restore()
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        settleUI()
        check(restoring != nil && !desk.isCollapsed && morph.phase == .idle && morph.shell == nil && restoring?.panel.isVisible == false
              && !bubble.isVisible && !store.isFloatingOpen && !floating.isVisible && morph.presentedContent > 0.99,
              "M14 restoring the main window mid-grow takes the shell down at once; the bubble does not come back and the box closes with it",
              "phase=\(morph.phase) collapsed=\(desk.isCollapsed) bubble=\(bubble.isVisible) floating=\(floating.isVisible)")
    }

    // MARK: - F5 長、縮途中按一下（查核 #1）

    /// M17：框開著、停著進來；出去時框收著、圓鈕在（時鐘由自測推）。
    /// 1. 縮到一半按外殼＝長回去（同一個外殼）；外殼面板透明的角不接。2. 長到一半按外殼（真的框蓋不到的那一段）＝縮回去。
    /// 3. 連點圓鈕：第二下（0.2 秒：外殼 0.1 秒就長離圓鈕了）落在圓鈕本來的位置＝點圓鈕（F45 之前第二下點到還在的圓鈕＝收框），
    ///    不會穿到後面的 App 把框的鍵盤焦點搶走。
    @MainActor static func pressChecks(_ check: Checker, store: GlobalDMStore, morph: GlobalDMButtonMorph, floating: NSWindow, bubble: NSWindow,
                                       clock: Clock) async {
        let margin = GlobalDMLayout.margin
        func circle() -> CGRect { bubble.frame.insetBy(dx: margin, dy: margin) }
        let shrink17 = closeBox(store, morph, clock, at: 540)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        if let shrinking = morph.shell, morph.phase == .shrinking {
            clock.now = shrink17 + 0.12
            morph.show(at: 0.12)
            let rect = shrinking.presentedRect
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let corner = CGPoint(x: shrinking.panel.frame.minX + 3, y: shrinking.panel.frame.maxY - 3)
            let takesShell = hitView(shrinking.panel, at: center) === shrinking.view
            let passesCorner = hitView(shrinking.panel, at: corner) == nil && !rect.contains(corner)
            let notIgnoring = !shrinking.panel.ignoresMouseEvents
            let catcherUp = morph.catcherPanel.map { $0.isVisible && near($0.frame, circle(), 0.5) } ?? false
            press(shrinking.panel, at: center)
            _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
            let regrew = morph.phase == .growing && morph.shell === shrinking && store.isFloatingOpen && !bubble.isVisible
            check(takesShell && passesCorner && notIgnoring && catcherUp && regrew,
                  "M17 pressing the shrinking shell is pressing the bubble: it grows back from where it is (same shell); the see-through corner of the shell's panel does not take the click; while it moves the bubble's own spot is a click target",
                  "shell=\(takesShell) corner=\(passesCorner) ignoresMouseEvents=\(!notIgnoring) catcher=\(catcherUp) regrew=\(regrew) phase=\(morph.phase)")
            clock.now = shrink17 + 0.12 + 0.61
            morph.tick()
            settleUI()
        } else {
            check(false, "M17 closing started a shrink for the press", "phase=\(morph.phase)")
        }
        let shrink17b = closeBox(store, morph, clock, at: 550)
        _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
        clock.now = shrink17b + 0.61
        morph.tick()
        clock.now = 555
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        if let growing = morph.shell {
            clock.now = 555.05
            morph.show(at: 0.05)
            let rect = growing.presentedRect
            let uncovered = rect.minY + 2 < floating.frame.minY
            let point = uncovered ? CGPoint(x: rect.midX, y: (rect.minY + min(rect.maxY, floating.frame.minY)) / 2) : CGPoint(x: rect.midX, y: rect.midY)
            let takes = hitView(growing.panel, at: point) === growing.view
            press(growing.panel, at: point)
            let turned = morph.phase == .shrinking && morph.shell === growing && !store.isFloatingOpen
            _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
            clock.now = 555.05 + 0.61
            morph.tick()
            let spotGone = morph.catcherPanel?.isVisible != true
            check(takes && turned && bubble.isVisible && morph.phase == .idle && spotGone,
                  "M17 pressing the growing shell (where the real box does not cover it) shrinks it back into the bubble (same shell); the click spot goes away with the shell",
                  "takes=\(takes) turned=\(turned) uncovered=\(uncovered) bubble=\(bubble.isVisible) phase=\(morph.phase)")
        } else {
            check(false, "M17 a grow started for the press", "phase=\(morph.phase)")
        }
        clock.now = 565
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        if let growing = morph.shell, let catcher = morph.catcherPanel {
            clock.now = 565.2
            morph.show(at: 0.2)
            let spot = CGPoint(x: circle().midX, y: circle().midY)
            let shellLeft = hitView(growing.panel, at: spot) == nil
            let catcherTakes = hitView(catcher, at: spot) != nil
            let roundOnly = hitView(catcher, at: CGPoint(x: circle().minX + 1, y: circle().minY + 1)) == nil
            let level = catcher.level == bubble.level && catcher.isVisible
            press(catcher, at: spot)
            let turned = morph.phase == .shrinking && morph.shell === growing && !store.isFloatingOpen
            _ = await DMBrowserAcceptance.waitUntil(2) { !floating.isVisible }
            clock.now = 565.2 + 0.61
            morph.tick()
            check(shellLeft && catcherTakes && roundOnly && level && turned && bubble.isVisible && !catcher.isVisible,
                  "M17 a double-click on the bubble: the second click (0.2 s, the shell has already left that spot) lands on the bubble's spot and turns it back like the bubble used to — it does not fall through to the app behind; the spot is gone once the bubble is back",
                  "shellLeft=\(shellLeft) catcher=\(catcherTakes) roundOnly=\(roundOnly) level=\(level) turned=\(turned) bubble=\(bubble.isVisible)")
        } else {
            check(false, "M17 a grow started for the double-click", "phase=\(morph.phase) catcher=\(morph.catcherPanel != nil)")
        }
    }

    // MARK: - F5 真的時鐘（查核 #5、#2）

    /// M15：正式只有計時器會收尾（外殼拆掉、圓鈕回來），這一段自測不推時鐘、也不叫 tick()；t＝0 在外殼建好之後；
    /// 中途圖層照真的時間原點跑（跟模型比）。框收著、圓鈕在進來，出去一樣；出去時換回自測推時鐘。
    @MainActor static func realClockChecks(_ check: Checker, store: GlobalDMStore, morph: GlobalDMButtonMorph, floating: NSWindow,
                                           bubble: NSWindow, clock: Clock) async {
        // 從停著開始（前一段留下的縮、淡出還在跑的話，這一段量的就不是真的時鐘開的那一次）。
        let startsIdle = morph.phase == .idle && morph.shell == nil && !store.isFloatingOpen
        morph.manualTime = false
        morph.clock = { CACurrentMediaTime() }
        defer {
            morph.reduceMotion = { false }
            morph.manualTime = true
            morph.clock = { clock.now }
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .growing }
        guard let grow = morph.shell, let plan = morph.plan else {
            return check(false, "M15 real clock, open: a grow started", "phase=\(morph.phase)")
        }
        let growBuiltFirst = morph.startedAt >= grow.builtAt
        _ = await DMBrowserAcceptance.waitUntil(0.4) { morph.elapsed >= 0.1 }
        var onModel: Bool?
        var sample = "not sampled (the main thread was late)"
        if morph.phase == .growing {
            let t0 = morph.elapsed, rect = grow.presentedRect, t1 = morph.elapsed
            onModel = between(rect, plan.rect(at: t0), plan.rect(at: t1), slack: 2)
            sample = "t=\(String(format: "%.3f", t0))…\(String(format: "%.3f", t1)) shown=\(describe([rect])) model=\(describe([plan.rect(at: t0)]))"
        }
        if onModel == nil { check.note("M15 mid-way sample skipped: \(sample)") }
        let opened = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .idle }
        settleUI()
        let modelOK = onModel ?? true, spotGone = morph.catcherPanel?.isVisible != true
        let boxShown = floating.isVisible && morph.presentedContent > 0.99 && !bubble.isVisible
        check(startsIdle && growBuiltFirst && modelOK && opened && morph.shell == nil && !grow.panel.isVisible && boxShown && spotGone,
              "M15 real clock, open: t = 0 is taken after the shell is built; mid-way the layers are where the model says (real time origin); the timer alone ends it (shell down, content in, still no bubble)",
              "startsIdle=\(startsIdle) builtFirst=\(growBuiltFirst) \(sample) idle=\(opened) content=\(morph.presentedContent) bubble=\(bubble.isVisible)")
        store.isFloatingOpen = false
        // W184 AB：先是內容淡出（外殼墊在框下面），計時器 0.10 秒後才收框、開始縮。
        let clearingFirst = morph.phase == .clearing && floating.isVisible
        _ = await DMBrowserAcceptance.waitUntil(1) { morph.phase == .shrinking }
        guard clearingFirst, let shrink = morph.shell, morph.phase == .shrinking else {
            return check(false, "M15 real clock, close: the content fade, then (timer) a shrink", "clearingFirst=\(clearingFirst) phase=\(morph.phase)")
        }
        let shrinkBuiltFirst = morph.startedAt >= shrink.builtAt && !floating.isVisible
        let closed = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .idle && bubble.isVisible }
        settleUI()
        let closeSpotGone = morph.catcherPanel?.isVisible != true
        check(shrinkBuiltFirst && closed && morph.shell == nil && !shrink.panel.isVisible && bubble.isVisible && !floating.isVisible && closeSpotGone,
              "M15 real clock, close: t = 0 after the shell is built; the timer alone brings the bubble back when the shell arrives and takes the shell down",
              "builtFirst=\(shrinkBuiltFirst) idle=\(closed) bubble=\(bubble.isVisible) phase=\(morph.phase)")
        morph.reduceMotion = { true }
        store.openFloating()
        let fadedIn = await DMBrowserAcceptance.waitUntil(2) { floating.isVisible && morph.phase == .idle && morph.presentedContent > 0.99 }
        store.isFloatingOpen = false
        let fading = morph.phase == .clearing && morph.shell == nil && floating.isVisible
        let fadedOut = await DMBrowserAcceptance.waitUntil(2) { morph.phase == .idle && bubble.isVisible }
        settleUI()
        let bubbleIn = bubble.isVisible && morph.presentedBubble(bubble) > 0.99 && !floating.isVisible
        check(fadedIn && fading && fadedOut && morph.shell == nil && bubbleIn,
              "M15 real clock, reduce motion: the timers alone fade the box in, then on close fade the box itself out (no shell), put it away and bring the bubble back",
              "in=\(fadedIn) fading=\(fading) out=\(fadedOut) bubble=\(morph.presentedBubble(bubble))")
    }

    // MARK: - 畫面證據

    /// 一格：先鋪桌面的灰，再照真實的視窗順序疊外殼（presentation）與真的框（照它現在的透明度）：boxAbove＝框在外殼前面（查核 #7）。
    @MainActor static func renderFrame(region: CGRect, shell: GlobalDMMorphShell, box: NSView?, panel: NSWindow?, boxAlpha: CGFloat,
                                       boxAbove: Bool = true) -> NSBitmapImageRep? {
        guard let rep = bitmap(region.size, scale: 2) else { return nil }
        fill(rep, desktopGrey.cgColor)
        if boxAbove { shell.render(into: rep, region: region) }
        if let box, let panel, boxAlpha > 0.001, let cached = box.bitmapImageRepForCachingDisplay(in: box.bounds),
           let context = NSGraphicsContext(bitmapImageRep: rep) {
            box.cacheDisplay(in: box.bounds, to: cached)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context   // 這個 context 已經照 rep.size（點）對到像素：用點畫，不再自己放大
            cached.draw(in: NSRect(x: panel.frame.minX - region.minX, y: panel.frame.minY - region.minY, width: box.bounds.width,
                                   height: box.bounds.height),
                        from: .zero, operation: .sourceOver, fraction: boxAlpha, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if !boxAbove { shell.render(into: rep, region: region) }
        return rep
    }

    /// 查核 #7：視窗伺服器上的前後順序（前 → 後）：back 在 front 後面嗎；nil＝這個環境查不到這兩個視窗。
    @MainActor static func isBehind(_ back: NSWindow, _ front: NSWindow) -> Bool? {
        func order(_ numbers: [Int]) -> Bool? {
            guard let b = numbers.firstIndex(of: back.windowNumber), let f = numbers.firstIndex(of: front.windowNumber) else { return nil }
            return b > f
        }
        if let result = order(NSWindow.windowNumbers(options: [])?.map(\.intValue) ?? []) { return result }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return order(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
    }

    /// 查核 #1：一個面板在螢幕上某一點打到哪個 view（AppKit 送滑鼠事件前的 hitTest；nil＝這個面板在那裡不接）。
    @MainActor static func hitView(_ window: NSWindow, at screen: CGPoint) -> NSView? {
        guard let content = window.contentView else { return nil }
        let point = window.convertPoint(fromScreen: screen)
        return content.hitTest(content.superview.map { $0.convert(point, from: nil) } ?? point)
    }

    /// 查核 #1：在面板上的一點按一下（按下、放開；視窗照 hitTest 交給那個 view——同真的點擊進了這個視窗之後的路）。
    @MainActor static func press(_ window: NSWindow, at screen: CGPoint) {
        let point = window.convertPoint(fromScreen: screen)
        let now = ProcessInfo.processInfo.systemUptime
        for (type, pressure, time) in [(NSEvent.EventType.leftMouseDown, Float(1), now), (NSEvent.EventType.leftMouseUp, Float(0), now + 0.05)] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) else { continue }
            window.sendEvent(event)
        }
    }

    /// r 的每一邊都在 a、b 兩個矩形的那一邊之間（多 slack 點）：真的時鐘在兩次讀時間之間取的樣。
    static func between(_ r: CGRect, _ a: CGRect, _ b: CGRect, slack: CGFloat) -> Bool {
        func within(_ v: CGFloat, _ x: CGFloat, _ y: CGFloat) -> Bool { v >= min(x, y) - slack && v <= max(x, y) + slack }
        return within(r.minX, a.minX, b.minX) && within(r.minY, a.minY, b.minY) && within(r.width, a.width, b.width)
            && within(r.height, a.height, b.height)
    }

    /// 只畫外殼（白底：玻璃主題的半透明底色也比得出來）：rect＝外殼現在的矩形。
    @MainActor static func renderShell(_ shell: GlobalDMMorphShell, rect: CGRect) -> NSBitmapImageRep? {
        guard let rep = bitmap(rect.size, scale: 2) else { return nil }
        fill(rep, NSColor.white.cgColor)
        shell.render(into: rep, region: rect)
        return rep
    }

    /// 真的框（停下之後）：面板內容裡框的那一塊，疊在白底上（同外殼那一張的比法）。
    @MainActor static func renderPanel(_ canvas: NSView, rect: CGRect, panel: NSWindow) -> NSBitmapImageRep? {
        let local = NSRect(x: rect.minX - panel.frame.minX, y: rect.minY - panel.frame.minY, width: rect.width, height: rect.height)
        guard let raw = canvas.bitmapImageRepForCachingDisplay(in: local), let rep = bitmap(rect.size, scale: 2),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        canvas.cacheDisplay(in: local, to: raw)
        fill(rep, NSColor.white.cgColor)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context   // 用點畫（context 已經照 rep.size 對到像素）
        raw.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// 裡面（四邊內縮 inset 點）跟中位色差很多的點占多少（字、配對碼、網頁畫面都會拉高它；紙紋很淡）。
    @MainActor static func inkFraction(_ rep: NSBitmapImageRep?, inset: CGFloat) -> Double {
        guard let rep, rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let data = rep.bitmapData else { return 1 }
        let scale = CGFloat(rep.pixelsWide) / max(1, rep.size.width)
        let edge = Int((inset * scale).rounded(.up))
        let spp = rep.samplesPerPixel, row = rep.bytesPerRow
        var pixels: [(Int, Int, Int)] = []
        for y in stride(from: edge, to: rep.pixelsHigh - edge, by: 3) {
            for x in stride(from: edge, to: rep.pixelsWide - edge, by: 3) {
                let p = data + y * row + x * spp
                pixels.append((Int(p[0]), Int(p[1]), Int(p[2])))
            }
        }
        guard !pixels.isEmpty else { return 1 }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        let mr = median(pixels.map(\.0)), mg = median(pixels.map(\.1)), mb = median(pixels.map(\.2))
        let far = pixels.filter { max(abs($0.0 - mr), abs($0.1 - mg), abs($0.2 - mb)) > 64 }.count
        return Double(far) / Double(pixels.count)
    }

    static func bitmap(_ size: CGSize, scale: CGFloat) -> NSBitmapImageRep? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                                bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        return rep
    }

    static func fill(_ rep: NSBitmapImageRep, _ color: CGColor) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        context.cgContext.setFillColor(color)
        context.cgContext.fill(CGRect(origin: .zero, size: rep.size))   // 點（context 已經照 rep.size 對到像素）
        context.flushGraphics()
    }

    /// 一張畫面在某一點（螢幕座標；region＝這張畫的範圍）的顏色（0–255 RGB）。bitmapData 的第 0 列在最上面。
    static func pixel(_ rep: NSBitmapImageRep, at point: CGPoint, region: CGRect) -> (Int, Int, Int)? {
        guard rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let data = rep.bitmapData, rep.size.width > 0 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let x = Int(((point.x - region.minX) * scale).rounded(.down))
        let up = Int(((point.y - region.minY) * scale).rounded(.down))
        let y = rep.pixelsHigh - 1 - up
        guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh else { return nil }
        let p = data + y * rep.bytesPerRow + x * rep.samplesPerPixel
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    /// 畫面證據那一格真的畫對了（沒畫歪、沒放大）：外殼的中心是外殼的底色，範圍左上角（外殼走不到的地方）是鋪好的桌面灰。
    /// 桌面灰的像素值用一張同樣鋪法的小圖量（色彩轉換後不一定剛好是 219）。
    static func frameShowsShell(_ rep: NSBitmapImageRep, shell rect: CGRect, region: CGRect) -> Bool {
        let probe = CGRect(x: 0, y: 0, width: 4, height: 4)
        guard let blank = bitmap(probe.size, scale: 2) else { return false }
        fill(blank, desktopGrey.cgColor)
        guard let grey = pixel(blank, at: CGPoint(x: 2, y: 2), region: probe),
              let center = pixel(rep, at: CGPoint(x: rect.midX, y: rect.midY), region: region),
              let corner = pixel(rep, at: CGPoint(x: region.minX + 6, y: region.maxY - 6), region: region) else { return false }
        func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }
        return distance(corner, grey) <= 3 && distance(center, grey) > 8
    }

    /// 畫面證據底下鋪的桌面灰。
    static var desktopGrey: NSColor { NSColor(calibratedWhite: 0.86, alpha: 1) }

    /// 幾格排成一排（中間留 24 點）。
    @MainActor static func strip(_ reps: [NSBitmapImageRep]) -> NSBitmapImageRep? {
        guard let first = reps.first else { return nil }
        let gap: CGFloat = 24
        let size = CGSize(width: first.size.width * CGFloat(reps.count) + gap * CGFloat(max(0, reps.count - 1)), height: first.size.height)
        guard let canvas = bitmap(size, scale: 2), let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context   // 用點畫（context 已經照 rep.size 對到像素）
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, rep) in reps.enumerated() {
            rep.draw(in: NSRect(x: CGFloat(index) * (first.size.width + gap), y: 0, width: first.size.width, height: first.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas
    }

    /// 中途三格（0.05／0.12／0.25 秒）各一張，再加排成一排的一張。
    @MainActor static func saveFrames(_ reps: [NSBitmapImageRep], prefix: String, to folder: URL?, _ check: Checker) {
        guard reps.count == 3 else { return check.note("\(prefix): \(reps.count) frames drawn (expected 3)") }
        for (rep, time) in zip(reps, ["0.05", "0.12", "0.25"]) { save(rep, "\(prefix)-\(time).png", to: folder, check) }
        save(strip(reps), "\(prefix)-0.05-0.12-0.25.png", to: folder, check)
    }

    @MainActor static func save(_ rep: NSBitmapImageRep?, _ name: String, to folder: URL?, _ check: Checker) {
        guard let folder else { return check.skip("\(name)：沒有 TATWO2_SELFTEST_ARTIFACTS（不是 lead-verify 跑的）") }
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else { return check.note("\(name) not drawn") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try png.write(to: url)
            check.note("evidence \(url.path)")
        } catch {
            check.note("\(name) not written: \(error.localizedDescription)")
        }
    }
}
#endif
