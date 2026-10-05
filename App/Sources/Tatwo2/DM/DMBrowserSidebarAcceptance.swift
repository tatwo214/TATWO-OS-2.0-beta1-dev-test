#if DEBUG
import AppKit
import Combine
import SwiftUI

/// W184 G2c 第二輪（GPT-6 審查 w184g2c：第 1–6 項；主導加的第 6、7 項）：`TATWO2_SELFTEST=w184browser` 的第二輪段。
/// W184 G2d（使用者 09-30：側欄、頂列、搜尋框改用主視窗 Browser space 的元件）：同一組反例留在新樣子上——
/// - N1b 打的字（草稿）綁在開始打字的那一個空白分頁：真的點進置中的搜尋框打字、中間點側欄換頁或關頁、再按 Return——草稿不填進別的空白頁；
///   送出時 DMBrowser 也再驗一次（直接叫 openBrowse 帶別的分頁＝不填目前的空白頁）。
/// - N4b ⌘⌥T 走正式的 GlobalDMPanelController（install／uninstall）＋正式的 ⌥⌘ 手勢偵測：內橫、有分頁、兩個旗標都 false 照樣收；
///   組字（不是 NSTextView 的文字輸入）⌘⌥T、Esc 都放行；放開 ⌥⌘ 不開關私訊框；單欄看對話、倒放、在設直達鍵、⌘T 放行。
/// - N5 ⌥⌘T 不能設成直達鍵（存過的也丟掉）。
/// - S4–S6 小框（外直、內橫右欄都縮到 0.7）＋最高的卡片：頂天的側欄停在卡片上面；每一格都捲得到、看得到、不碰卡片；真的滑鼠逐格按。
/// - S7 十一個空間：每一顆圓點（主視窗那一排）都在側欄裡、在停留帶裡（指過去不收欄）、按得到。
/// （G2c 第二輪的 S8 上下緣漸出拿掉了：主視窗 Browser space 的側欄沒有漸出，使用者 09-30 要的是跟它一樣。）
/// 隔離：面板控制器、桌面控制器、Browser、卡片都是自測自己建的（假頁面、假熱鍵、只在記憶體的設定）；⌥⌘ 手勢偵測只有一份
/// （GlobalHotkeyMonitor.shared；自測程序沒有裝正式那一份）：N4b 裝上、量完拿掉。
extension DMBrowserPhoneAcceptance {
    /// 不是 NSTextView 的文字輸入（網頁輸入框那一類：NSTextInputClient）；setMarkedText＝輸入法正在組字。收到的按鍵自己吃掉（不叫）。
    final class ComposingClient: NSView, NSTextInputClient {
        private(set) var marked: String?
        private(set) var committed = ""

        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}

        private static func string(_ value: Any) -> String {
            (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
        }

        func insertText(_ string: Any, replacementRange: NSRange) {
            committed += Self.string(string)
            marked = nil
        }

        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            marked = Self.string(string)
        }

        func unmarkText() { marked = nil }

        func selectedRange() -> NSRange { NSRange(location: (committed as NSString).length, length: 0) }

        func markedRange() -> NSRange {
            guard let marked else { return NSRange(location: NSNotFound, length: 0) }
            return NSRange(location: (committed as NSString).length, length: (marked as NSString).length)
        }

        func hasMarkedText() -> Bool { marked != nil }

        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

        func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }

        func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    }

    @MainActor final class Tally { var count = 0 }

    // MARK: - N1b 打的字綁在開始打字的那一個空白分頁（GPT-6 #3；W184 G2d：置中的搜尋框）

    @MainActor static func draftChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        let phone = Phone("draft")
        let web = openedID(phone.browser.openBrowse(url: URL(string: "https://example.com/web")!, title: "web", origin: .typed))
        let screen = Clickable(phone.pane(.sidebar, probes: true), size: size, keyable: true)
        await screen.settle()
        /// 側欄的「新分頁」（真的滑鼠）→ 空白分頁的 id；收起輸入。
        func plus() async -> UUID? {
            guard let point = screen.center("side.newTab") else { return nil }
            await screen.click(point)
            _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState == .search }
            let id = phone.browser.activeTab?.isBlank == true ? phone.browser.activeID : nil
            _ = DMBrowserPanelEscape.closePanel(in: screen.window)
            await screen.settle(3)
            return id
        }
        /// 點側欄那一列（真的滑鼠）。
        func row(_ id: UUID?) async {
            guard let id, let point = screen.center("side.tab.\(id.uuidString)") else { return }
            await screen.click(point)
        }
        /// 點置中的搜尋框（開始打字）再真的打字。側欄這時展開著（蓋在網頁左半邊上，同主視窗），點搜尋框露在側欄右邊的那一段。
        func typeSearch(_ text: String) async -> Bool {
            guard let field = searchField(screen) else { return false }
            let frame = field.convert(field.bounds, to: nil)
            let point = NSPoint(x: frame.maxX - 16, y: frame.midY)
            if let column = screen.frame("side.panel"), column.contains(point) { return false }
            await screen.click(point)
            return await screen.type(text)
        }
        func returnKey() async {
            await pressKey(36, characters: "\r", flags: [], in: screen.window)
            await screen.settle(3)
        }
        func blank(_ id: UUID?) -> Bool { id.flatMap { id in phone.browser.tabs.first { $0.id == id } }?.isBlank == true }
        func opened(_ address: String) -> Bool { phone.browser.tabs.contains { $0.startURL?.absoluteString == address } }

        let a = await plus()
        await row(web)
        let b = await plus()
        // 1. 在 A 打字（沒送出）→ 點側欄切到 B（也是空白）→ 按 Return：輸入已經收起、B 的搜尋框是空的、B 還是空白、草稿沒開到任何一頁。
        await row(a)
        let typedA = await typeSearch("example.com/draft-a")
        await row(b)
        let endedOnSwitch = screen.panelState == nil
        let emptyOnB = searchField(screen)?.stringValue.isEmpty == true
        await returnKey()
        let switched: Bool = typedA && endedOnSwitch && emptyOnB && phone.browser.activeID == b && blank(a) && blank(b)
            && !opened("https://example.com/draft-a")
        // 2. 在 B 打字 → 點側欄 × 關掉 B（A 接手成為目前那一頁）→ 按 Return：輸入收起、A 還是空白、草稿沒開。
        let typedB = await typeSearch("example.com/draft-b")
        if let b, let close = screen.center("side.close.\(b.uuidString)") { await screen.click(close) }
        let endedOnClose = screen.panelState == nil
        await returnKey()
        let closed: Bool = typedB && endedOnClose && !phone.browser.tabs.contains { $0.id == b } && blank(a)
            && !opened("https://example.com/draft-b")
        // 3. 對照：在 A 打字 → 按 Return＝開在 A 自己上面（同一個分頁、不多開），輸入收起。
        if let a, phone.browser.activeID != a { await row(a) }
        let count = phone.browser.tabs.count
        let typedOK = await typeSearch("example.com/ok")
        await returnKey()
        _ = await DMBrowserAcceptance.waitUntil(2) { !blank(a) }
        let filled: Bool = typedOK && phone.browser.activeID == a && phone.browser.tabs.count == count && screen.panelState == nil
            && phone.browser.tabs.first { $0.id == a }?.startURL?.absoluteString == "https://example.com/ok"
        check(a != nil && b != nil && switched && closed && filled,
              "N1b (W184 G2c second round, GPT-6 #3; G2d) the typed text belongs to the blank tab where typing began: typed in blank A's centered search box (not sent), switching to blank B in the sidebar or closing B's tab ends typing and drops the draft — B's box is empty, Return then opens nothing and the tabs stay blank; typed on A and sent = A itself is filled (same tab)",
              "switch=\(switched)(typed=\(typedA) ended=\(endedOnSwitch) empty=\(emptyOnB)) close=\(closed)(typed=\(typedB) ended=\(endedOnClose)) fill=\(filled) tabs=\(phone.browser.tabs.map { $0.startURL?.path ?? "blank" })")
        // 4. 送出時 DMBrowser 再驗一次：目前是空白分頁 C，送出的是「在別頁開始打的字」＝不填 C（開自己的新分頁）；
        //    沒記開始的那一頁＝一樣不填；只有開始打字的就是 C 才填 C。書籤、珍藏＝按下去當下在看的空白分頁照樣填。
        let c = await plus()
        let other = phone.browser.openBrowse(url: URL(string: "https://example.com/other")!, title: "other", origin: .typed, typedInto: web)
        let otherKept: Bool = openedID(other) != nil && openedID(other) != c && blank(c)
        if let id = openedID(other) { phone.browser.userClose(id) }
        if let c { phone.browser.select(c) }
        let none = phone.browser.openBrowse(url: URL(string: "https://example.com/none")!, title: "none", origin: .typed, typedInto: nil)
        let noneKept: Bool = openedID(none) != nil && openedID(none) != c && blank(c)
        if let id = openedID(none) { phone.browser.userClose(id) }
        if let c { phone.browser.select(c) }
        let own = phone.browser.openBrowse(url: URL(string: "https://example.com/own")!, title: "own", origin: .typed, typedInto: c)
        let ownFilled: Bool = c != nil && own == .opened(c!) && !blank(c)
        let d = await plus()
        let bookmark = DMBrowserShelf.open(bookmark: BrowserWorkSpaceStore.Bookmark(id: UUID(), title: "書籤", url: "https://example.net/mark"),
                                           in: phone.browser)
        let bookmarkFilled: Bool = d != nil && bookmark == .opened(d!) && !blank(d)
        let pure: Bool = DMBrowser.blankToFill(origin: .typed, typedInto: nil, active: phone.browser.tabs.first { $0.id == web }) == nil
        check(otherKept && noneKept && ownFilled && bookmarkFilled && pure,
              "N1c (W184 G2c second round, GPT-6 #3) DMBrowser re-checks on submit: a typed address from another tab (or with no recorded tab) never fills the blank tab in front — it opens its own; only the tab where typing began is filled; a bookmark still fills the blank tab in front",
              "other=\(other) none=\(none) own=\(own) bookmark=\(bookmark)")
        screen.close()
        phone.browser.closeAll()
    }

    // MARK: - N4b ⌘⌥T 走正式的 GlobalDMPanelController（GPT-6 #1、#2；測試缺口）

    /// 真的按一組鍵（排進 App 的事件佇列，同真的鍵盤）：⌥ 按下 → ⌘ 按下 →（有 keyCode 的話）那一顆按下、放開 → ⌘ 放開 → ⌥ 放開。
    @MainActor static func pressChord(_ keyCode: UInt16?, characters: String = "", flags: NSEvent.ModifierFlags = [.command, .option],
                                      in window: NSWindow) async {
        func post(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags, code: UInt16, text: String = "") {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                                            isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        post(.flagsChanged, [.option], code: 58)
        post(.flagsChanged, [.option, .command], code: 55)
        if let keyCode {
            post(.keyDown, flags, code: keyCode, text: characters)
            post(.keyUp, flags, code: keyCode, text: characters)
        }
        post(.flagsChanged, [.option], code: 55)
        post(.flagsChanged, [], code: 58)
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    @MainActor static func newTabControllerChecks(_ check: Checker) async {
        guard let defaults = UserDefaults(suiteName: "w184browser.n4b.\(UUID().uuidString)"),
              let deskDefaults = UserDefaults(suiteName: "w184browser.n4bdesk.\(UUID().uuidString)") else {
            return check.skip("N4b ⌘⌥T 走正式的面板控制器：拿不到自測自己的設定")
        }
        let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { true }, directKeys: true)
        let settings = GlobalDMDeskSettings(defaults: deskDefaults)
        settings.form = .innerLandscape
        let browser = DMBrowser(store: store, openBox: {}, pageHost: EvidenceWebHost(), podPage: { EvidencePage("ChatGPT（假頁面）") },
                                windowShown: { $0.isVisible }, transitions: { Just(false).eraseToAnyPublisher() })
        let box = CardBox()
        let presenter = HandsConnectPresenter(store: store, openBox: {}, browser: browser, hookPod: { _ in }, podURL: { nil },
                                              cancelFlow: {}, card: { box.card })
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true,
                                             browserServices: GlobalDMBrowserServices(browser: browser, flow: inertFlow(), connect: presenter))
        let desk = GlobalDMDeskController(store: store, settings: settings, hotkeys: GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend()),
                                          panels: panels, duo: GlobalDMDuo(defaults: nil), browser: browser)
        let chord = GlobalHotkeyMonitor.shared
        chord.install()   // 同 App 啟動的順序：⌥⌘ 手勢偵測先裝、再裝私訊框的面板與桌面控制器
        panels.install()
        desk.install()
        let toggles = Tally()
        let watch = NotificationCenter.default.addObserver(forName: .tatwoToggleGlobalDM, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { toggles.count += 1 }
        }
        let composer = ComposingClient(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        defer {
            NotificationCenter.default.removeObserver(watch)
            composer.removeFromSuperview()
            browser.closeAll()
            store.close()
            desk.uninstall()
            panels.uninstall()
            chord.uninstall()
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true }
        guard let floating = panels.floatingPanelForTesting, floating.isVisible else {
            return check.skip("N4b ⌘⌥T 走正式的面板控制器：這個環境開不出浮動框（沒有畫面環境）")
        }
        floating.alphaValue = 0   // 量按鍵，不在螢幕上閃
        floating.makeKey()
        let isKey = await DMBrowserAcceptance.waitUntil(1) { floating.isKeyWindow }
        // 1. 內橫：開一個一般分頁（右欄是 Browser），再從頂列選左欄的對話對象（兩個旗標都清掉）——右欄因為還有分頁照樣是 Browser。
        _ = browser.openBrowse(url: URL(string: "https://example.com/k")!, title: "k", origin: .bookmark(UUID()))
        store.select(.assistant)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let state: Bool = settings.form == .innerLandscape && !store.isBrowsing && !store.isBrowsingBeside && browser.hasTabs
        let shown = GlobalDMDuoLayout.showsBrowser(form: settings.form, browsing: store.isBrowsing, browsingBeside: store.isBrowsingBeside,
                                                   hasTabs: browser.hasTabs, hasSecondary: GlobalDMDuo.shared.hasSecondary)
        var serial = browser.newTabAsk?.serial ?? 0
        let before = browser.tabs.count
        await pressChord(DMBrowserNewTabKey.keyCode, characters: "t", in: floating)
        let took: Bool = browser.newTabAsk?.serial == serial + 1 && browser.tabs.count == before + 1 && browser.activeTab?.isBlank == true
        let noToggle: Bool = toggles.count == 0 && store.isFloatingOpen
        check(isKey && state && shown && took && noToggle,
              "N4b (W184 G2c second round, GPT-6 #1) ⌘⌥T through the real GlobalDMPanelController (install / uninstall) and the real ⌥⌘ gesture monitor: inner landscape, a tab open, then a left-column target picked (both Browser flags cleared) — the right column still shows the Browser, so ⌘⌥T opens a blank tab; releasing ⌥⌘ afterwards does not open or close the box",
              "key=\(isKey) state=\(state) shown=\(shown) took=\(took) toggles=\(toggles.count) open=\(store.isFloatingOpen)")
        // 2. 組字（不是 NSTextView 的文字輸入）：⌘⌥T、Esc 都交給輸入法（不開新分頁、不收框）；字選完再按 ⌘⌥T＝照樣收。
        floating.contentView?.addSubview(composer)
        let focused = floating.makeFirstResponder(composer)
        composer.setMarkedText("ㄊ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        serial = browser.newTabAsk?.serial ?? 0
        await pressChord(DMBrowserNewTabKey.keyCode, characters: "t", in: floating)
        let passedT: Bool = browser.newTabAsk?.serial == serial && composer.hasMarkedText()
        await pressEscape(in: floating)
        let passedEsc: Bool = store.isFloatingOpen && composer.hasMarkedText()
        composer.unmarkText()
        await pressChord(DMBrowserNewTabKey.keyCode, characters: "t", in: floating)
        let takenAfter: Bool = browser.newTabAsk?.serial == serial + 1
        check(focused && passedT && passedEsc && takenAfter && toggles.count == 0,
              "N4b-IME (W184 G2c second round, GPT-6 #2) while a text input that is not an NSTextView (NSTextInputClient, like a web page's field) is composing, ⌘⌥T and Esc go to the input method — no new tab, the box stays open; once composing ends ⌘⌥T is taken again",
              "focused=\(focused) t=\(passedT) esc=\(passedEsc) after=\(takenAfter) toggles=\(toggles.count)")
        // 3. 看不到 Browser＝放行：單欄看對話（還有分頁也一樣）；單欄的 Browser 那一頁＝收；倒放；在設直達鍵；⌘T（沒有 ⌥）。
        settings.form = .outerPortrait
        try? await Task.sleep(nanoseconds: 150_000_000)
        store.select(.assistant)   // 單欄看對話（Browser 那一頁收起；分頁還在）
        serial = browser.newTabAsk?.serial ?? 0
        await pressChord(DMBrowserNewTabKey.keyCode, characters: "t", in: floating)
        let conversation: Bool = browser.newTabAsk?.serial == serial && browser.hasTabs
        store.showBrowser()
        await pressChord(DMBrowserNewTabKey.keyCode, characters: "t", in: floating)
        let single: Bool = browser.newTabAsk?.serial == serial + 1
        serial = browser.newTabAsk?.serial ?? 0
        store.isEditingDirectKeys = true
        await pressChord(DMBrowserNewTabKey.keyCode, characters: "t", in: floating)
        let editingKeys: Bool = browser.newTabAsk?.serial == serial
        store.isEditingDirectKeys = false
        await pressKey(DMBrowserNewTabKey.keyCode, characters: "t", flags: [.command], in: floating)
        let commandT: Bool = browser.newTabAsk?.serial == serial
        settings.form = .tent
        try? await Task.sleep(nanoseconds: 150_000_000)
        await pressChord(DMBrowserNewTabKey.keyCode, characters: "t", in: floating)
        let tent: Bool = browser.newTabAsk?.serial == serial
        settings.form = .outerPortrait
        try? await Task.sleep(nanoseconds: 150_000_000)
        check(conversation && single && editingKeys && commandT && tent && toggles.count == 0,
              "N4b-pass (W184 G2c second round) the same real route passes ⌘⌥T on whenever the Browser is not on screen — single column showing the conversation (tabs still open), setting a direct key, the tent — and ⌘T without ⌥; the single-column Browser page takes it",
              "chat=\(conversation) single=\(single) keys=\(editingKeys) cmdT=\(commandT) tent=\(tent) toggles=\(toggles.count)")
        // 4. 對照：只按 ⌥⌘ 放開＝開關私訊框（這個手勢在自測裡是活的，上面「放開 ⌥⌘ 沒開關」才算數）。
        await pressChord(nil, in: floating)
        let control: Bool = toggles.count == 1 && !store.isFloatingOpen
        check(control, "N4b-control a bare ⌥⌘ press and release does toggle the box (the gesture monitor is live in this test, so “releasing ⌥⌘ after ⌘⌥T toggles nothing” above is meaningful)",
              "toggles=\(toggles.count) open=\(store.isFloatingOpen)")
    }

    // MARK: - N5 ⌥⌘T 不能設成直達鍵（主導 #6）

    @MainActor static func directKeyChecks(_ check: Checker) {
        guard let t = GlobalDMDirectKey(keyCode: DMBrowserNewTabKey.keyCode), t.rawValue == "T" else {
            return check(false, "N5 ⌥⌘T is the physical T key (kVK_ANSI_T = 17)")
        }
        let reason = "⌥⌘T 是私訊框 Browser 的「新分頁」"
        let verdict = GlobalDMDirectKeyRules.verdict(t, for: .assistant, in: [:])
        let blocked: Bool = verdict == .blocked(t, reason: reason) && verdict.message(title: { _ in "" }) == reason + "，不能用。"
        var dropped = false, refused = false
        if let stored = UserDefaults(suiteName: "w184browser.n5.\(UUID().uuidString)") {
            stored.set(["assistant": "T", "chatgpt": "G"], forKey: GlobalDMDirectKeyBook.storageKey)
            dropped = GlobalDMDirectKeyBook.load(from: stored)[.assistant] == nil
            let store = GlobalDMStore(defaults: stored, chatGPTAllowed: { true }, directKeys: true)
            let backend = GlobalDMDeskFakeHotKeyBackend()
            let hotkeys = GlobalDMHotKeys(backend: backend)
            refused = hotkeys.assign(keyCode: DMBrowserNewTabKey.keyCode, to: .assistant, store: store) == .blocked(t, reason: reason)
                && store.directKeys[.assistant] == nil && !backend.live.values.contains(UInt32(DMBrowserNewTabKey.keyCode))
        }
        check(blocked && dropped && refused,
              "N5 (W184 G2c second round, lead #6) ⌥⌘T cannot be set as a direct key (「⌥⌘T 是私訊框 Browser 的「新分頁」，不能用。」): assigning it is refused and never registered as a global hotkey, and a stored ⌥⌘T is dropped on load",
              "verdict=\(verdict) dropped=\(dropped) refused=\(refused)")
    }

    // MARK: - S4–S6 小框＋最高的卡片（GPT-6 #4；W184 G2d：頂天的側欄）

    /// 側欄每一格的量尺（珍藏那一排、每一個資料夾、展開的資料夾裡每一條書籤、新分頁、每一個分頁與它的 ×、空間圓點）。
    @MainActor static func sidebarControls(_ phone: Phone, in screen: Clickable) -> [String] {
        var keys = ["side.favorites"]
        for folder in phone.shelf.store.folders {
            keys.append("side.folder.\(folder.id.uuidString)")
            keys += folder.bookmarks.map { "side.bookmark.\($0.id.uuidString)" }.filter { screen.probeView($0) != nil }
        }
        keys.append("side.newTab")
        for tab in phone.browser.tabs where tab.origin == nil || tab.origin == .typed {   // 書籤、珍藏開的分頁住在各自那一列／那一格
            keys += ["side.tab.\(tab.id.uuidString)", "side.close.\(tab.id.uuidString)"]
        }
        for space in phone.shelf.store.spaces {
            let id: String = space.registryID?.uuidString ?? String(space.id)
            keys.append("side.space." + id)
        }
        return keys
    }

    /// 最小的兩種框（Browser 區）：外直 ×0.7（326×(475−68)）、內橫右欄 ×0.7（(623−280)×(438−68)）。
    /// 這裡故意保留單欄退路的浮卡壓力測試；R12 真正的內橫任務卡在左頁，另由 taskChecks 驗。
    static let smallBoxes: [(name: String, size: CGSize)] = [("outer×0.7", CGSize(width: 326, height: 407)),
                                                               ("innerRight×0.7", CGSize(width: 342, height: 370))]

    /// 最高的幾張卡：手動連線（步驟最長）、手動模式的配對碼卡（多一段說明）、輪到你（取消｜繼續）。
    @MainActor static func tallCards(surface: Int) -> [(name: String, card: HandsConnectCard, buttons: [String])] {
        let url = "https://example.com/mcp"
        return [("manual", .manual(url: url, steps: HandsConnectFlow.manualSteps(url)), ["card.dismiss"]),
                ("pairing", .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(272), attemptsLeft: 5,
                                                             callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true, manual: true,
                                                             surface: surface)), ["card.dismiss"]),
                ("turn", .waitingUser(HandsConnectFlow.riskAckCardText, continuable: true), ["card.turnCancel", "card.continue"])]
    }

    @MainActor static func smallBoxChecks(_ check: Checker) async {
        var stops: [String] = [], reach: [String] = []
        var pairingReach: [String] = []
        for box in smallBoxes {
            for card in tallCards(surface: 98) {
                let phone = Phone("small-\(box.name)-\(card.name)")
                phone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）"), key: 98, purpose: .chatgptPairing, expectedHost: nil)
                let pairingID = phone.browser.activeID
                _ = phone.browser.openBrowse(url: URL(string: "https://example.com/other")!, title: "其他", origin: .typed)
                if let pairingID { phone.browser.select(pairingID) }
                phone.box.card = card.card
                phone.presenter.show()
                var copies = 0
                let screen = Clickable(phone.pane(.sidebar, probes: true)
                    .environment(\.dmConnectCardActions, HandsConnectCardActions(copyPairingCode: { _ in copies += 1; return true })), size: box.size)
                await screen.settle()
                if let folder = phone.shelf.store.folders.first, let row = await screen.scrollIntoView("side.folder.\(folder.id.uuidString)") {
                    await screen.click(NSPoint(x: row.midX, y: row.midY))   // 展開第一個資料夾：書籤也要量得到
                }
                let column = screen.frame("side.panel") ?? .zero
                let cardArea = screen.frame("card.frame") ?? .zero
                let buttons = card.buttons.compactMap { screen.frame($0) }
                let above = !cardArea.isEmpty && column.minY >= cardArea.maxY + DMBrowserPhone.sidebarGap - 1 && near(column.maxY, box.size.height)
                let clear = buttons.count == card.buttons.count && buttons.allSatisfy { !$0.intersects(column) }
                let tall = !["manual", "pairing"].contains(card.name) || column.height >= DMBrowserPhone.sidebarMinHeight - 1
                stops.append("\(box.name)/\(card.name)=\(above && clear && tall)(h=\(Int(column.height)))")
                var missing: [String] = []
                let keys = sidebarControls(phone, in: screen)
                for key in keys {
                    guard let part = await screen.scrollIntoView(key), let whole = screen.frame(key) else { missing.append(key); continue }
                    let inColumn = column.insetBy(dx: -1, dy: -1).contains(part)
                    let offCard = !part.intersects(cardArea)
                    let enough = part.height >= min(whole.height, 20) - 0.5
                    if !(inColumn && offCard && enough) { missing.append(key) }
                }
                let bookmarks = keys.filter { $0.hasPrefix("side.bookmark.") }.count
                reach.append("\(box.name)/\(card.name)=\(missing.isEmpty && bookmarks > 0 ? "all" : "missing:" + missing.joined(separator: ",") + " bookmarks=\(bookmarks)")")
                if card.name == "pairing" {
                    if let part = await screen.scrollIntoView("card.copyCode") {
                        await screen.click(NSPoint(x: part.midX, y: part.midY))
                    }
                    let warning = await screen.scrollIntoView("card.pairingWarning")
                    let clear = warning.map { cardArea.contains($0) && !$0.intersects(column) && $0.height >= 20 } == true
                    pairingReach.append("\(box.name)=\(copies == 1 && clear)")
                }
                screen.close()
                phone.presenter.hide()
                phone.browser.closeAll()
            }
        }
        print("W184BROWSER NOTE S4 sidebar per box/card: \(stops.joined(separator: " "))")
        check(stops.count == 6 && stops.allSatisfy { $0.contains("=true") },
              "S4 (W184 G2c second round, GPT-6 #4; G2d) the smallest boxes (outer portrait ×0.7, inner-landscape right column ×0.7) with the tallest cards (manual steps, the manual-mode pairing card, 「輪到你」): the full-height sidebar starts at the top and stops 8 above the card, none of the card's buttons is under it, and next to the manual card it keeps at least 3 rows (the card's scrolling steps give way)",
              stops.joined(separator: " "))
        check(reach.count == 6 && reach.allSatisfy { $0.hasSuffix("=all") },
              "S5 (W184 G2c second round, GPT-6 #4; G2d) in those small boxes every part of the sidebar — the favorites strip, each folder and each bookmark in the opened folder, 新分頁, each tab and its ×, each space dot — scrolls into view inside the sidebar (drawn only in the sidebar, never on the card)",
              reach.joined(separator: " "))
        check(pairingReach.count == 2 && pairingReach.allSatisfy { $0.hasSuffix("=true") },
              "W184 R pairing card: keeping the sidebar usable also keeps the copy button mouse-clickable and the full manual warning scrollable inside the card",
              pairingReach.joined(separator: " "))

        // S6：最矮的那一個（內橫右欄 ×0.7＋手動模式的配對卡）：真的滑鼠逐格按（先捲到看得到），每一格真的做它的事；按下去時卡片在、那一格不在卡片上。
        guard let smallest = smallBoxes.last, let pairingCard = tallCards(surface: 99).first(where: { $0.name == "pairing" }) else { return }
        let phone = Phone("small-press")
        let page = EvidencePage("連上 TATWO（假配對頁）")
        phone.browser.adoptPopup(page, key: 99, purpose: .chatgptPairing, expectedHost: nil)
        let pairingID = phone.browser.activeID
        let otherID = openedID(phone.browser.openBrowse(url: URL(string: "https://example.com/other")!, title: "其他", origin: .typed))
        if let pairingID { phone.browser.select(pairingID) }
        phone.box.card = pairingCard.card
        phone.presenter.show()
        let screen = Clickable(phone.pane(.sidebar, probes: true), size: smallest.size, keyable: true)
        await screen.settle()
        var did: [String] = []
        var onCard: [String] = []
        /// 捲到看得到、確認卡片還在，按它看得到那一段的正中間（珍藏＝那一排第一格，也要在看得到的那一段裡）；
        /// 回傳（按了沒、按的時候那一段是不是在卡片上）。
        var hits: [String] = []
        func press(_ key: String, tile: Bool = false) async -> (done: Bool, covered: Bool) {
            let name = key.split(separator: ".").prefix(2).joined(separator: ".")
            guard let part = await screen.scrollIntoView(key), let area = screen.frame("card.frame") else { hits.append(name + ":notVisible"); return (false, false) }
            let first = tile ? favoriteTile(screen, index: 0).map { NSPoint(x: $0.x, y: part.midY) } : NSPoint(x: part.midX, y: part.midY)
            guard var point = first, part.insetBy(dx: -0.5, dy: -0.5).contains(point) else { hits.append(name + ":outside"); return (false, false) }
            // 剛捲過、清單剛變長短，直捲軸會浮出來停一下（蓋在每一列最右邊，分頁的 × 就在那裡；使用者看到的也是這樣）：
            // 等它自己收掉再按；等不到就按那一段最左邊（還在捲軸上＝不算按了）。
            if screen.scroller(at: point) != nil {
                let waitFrom = point
                let gone = await DMBrowserAcceptance.waitUntil(3) { screen.scroller(at: waitFrom) == nil }
                if !gone { point = NSPoint(x: part.minX + 2, y: point.y) }
                hits.append(name + ":scroller(\(gone ? "hid" : "stayed"))")
            }
            hits.append(name + ":" + screen.hitName(at: point))
            guard screen.scroller(at: point) == nil else { return (false, false) }
            let covered = area.contains(point)
            await screen.click(point)
            return (true, covered)
        }
        func restore() async {
            _ = DMBrowserPanelEscape.closePanel(in: screen.window)
            phone.browser.isShowingTabList = false
            if let pairingID, phone.browser.activeID != pairingID { phone.browser.select(pairingID) }
            await screen.settle(3)
        }
        var step = await press("side.favorites", tile: true)
        if step.covered { onCard.append("favorite") }
        if step.done { did.append("favorite=\(phone.browser.activeTab?.origin == .favorite(phone.shelf.favorite.id) ? "new" : "none")") }
        await restore()
        if let folder = phone.shelf.store.folders.first {
            step = await press("side.folder.\(folder.id.uuidString)")
            if step.covered { onCard.append("folder") }
            if step.done { did.append("folder=\(screen.probeView("side.bookmark.\(phone.shelf.docs.id.uuidString)") != nil)") }
        }
        step = await press("side.bookmark.\(phone.shelf.docs.id.uuidString)")
        if step.covered { onCard.append("bookmark") }
        if step.done { did.append("bookmark=\(phone.browser.activeTab?.origin == .bookmark(phone.shelf.docs.id) ? "new" : "none")") }
        await restore()
        if let otherID {
            step = await press("side.tab.\(otherID.uuidString)")
            if step.covered { onCard.append("row") }
            if step.done { did.append("row=\(phone.browser.activeID == otherID)") }
        }
        await restore()
        // ×：珍藏、書籤開的分頁住在各自那一格／那一列（同主視窗，不列在分頁裡），所以關的是打網址開的那一頁。
        if let otherID {
            step = await press("side.close.\(otherID.uuidString)")
            if step.covered { onCard.append("close") }
            if step.done { did.append("close=\(!phone.browser.tabs.contains { $0.id == otherID })") }
        }
        await restore()
        step = await press("side.newTab")
        if step.covered { onCard.append("newTab") }
        if step.done {
            _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState == .search }
            let blank = phone.browser.activeTab?.isBlank == true ? phone.browser.activeID : nil
            did.append("newTab=\(blank != nil ? "blank" : "none")/\(screen.panelState?.rawValue ?? "nil")")
            _ = DMBrowserPanelEscape.closePanel(in: screen.window)
            if let blank { phone.browser.userClose(blank) }
        }
        await restore()
        step = await press("side.space.\(phone.shelf.work.uuidString)")
        if step.covered { onCard.append("space") }
        if step.done { did.append("space=\(phone.shelf.store.selectedSpace.registryID == phone.shelf.work)") }
        let flowsKept = page.closes == 0 && phone.browser.tabs.contains { $0.id == pairingID }
        check(did == ["favorite=new", "folder=true", "bookmark=new", "row=true", "close=true", "newTab=blank/search", "space=true"] && onCard.isEmpty && flowsKept,
              "S6 (W184 G2c second round, GPT-6 #4; G2d) the lowest sidebar (inner-landscape right column ×0.7 under the manual-mode pairing card): each part scrolled into view and pressed with a real mouse event does its job — a favorite, a folder (opens), a bookmark (new tabs), a tab row, its ×, 新分頁 (caret in the centered search box), a space dot — with the card still up and never under the pointer",
              "\(did.joined(separator: " ")) onCard=\(onCard) flowsKept=\(flowsKept) hits=\(hits)")
        screen.close()
        phone.presenter.hide()
        phone.browser.closeAll()
    }

    // MARK: - S7 很多空間（GPT-6 #5；W184 G2d：主視窗那一排圓點）

    @MainActor static func manySpacesChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        let phone = Phone("spaces")
        for (n, color) in ["graphite", "blue", "yellow", "pink", "red", "orange", "green", "purple"].enumerated() {
            let id = phone.shelf.registry.addSpace(name: "空間 \(n + 3)").id
            phone.shelf.registry.setSpaceColor(id, color)
        }
        let all = phone.shelf.store.spaces
        _ = phone.browser.openPod(purpose: .chatgptDeveloper)
        let screen = Clickable(phone.pane(probes: true), size: size)
        await screen.settle()
        guard let reveal = screen.reveal else { return check(false, "S7 the Browser's reveal anchor is drawn") }
        reveal.evaluate(windowPoint: NSPoint(x: 10, y: 305))   // 從左緣叫出側欄
        await screen.settle(3)
        var outside: [String] = [], collapsed: [String] = [], missed: [String] = []
        func dotKey(_ space: BrowserWorkSpaceStore.Space) -> String {
            let id: String = space.registryID?.uuidString ?? String(space.id)
            return "side.space." + id
        }
        let width = DMBrowserPhone.sidebarWidth(for: size.width)
        for space in all {
            let key = dotKey(space)
            guard let part = await screen.scrollIntoView(key), let column = screen.frame("side.panel") else { missed.append(space.name); continue }
            if !column.insetBy(dx: -1, dy: -1).contains(part) || part.maxX > width + DMBrowserPhone.exitZone { outside.append(space.name) }
            let point = NSPoint(x: part.midX, y: part.midY)
            reveal.evaluate(windowPoint: point)   // 指標移到那一顆上：側欄還在（在側欄裡）
            await screen.settle(2)
            if !reveal.isRevealed || !screen.sidebarActive { collapsed.append(space.name) }
            await screen.click(point)
            if phone.shelf.store.selectedSpace.registryID != space.registryID { missed.append(space.name) }
        }
        check(all.count >= 10 && outside.isEmpty && collapsed.isEmpty && missed.isEmpty,
              "S7 (W184 G2c second round, GPT-6 #5; G2d) ten-plus spaces: the dots (the main window's WorkspaceSpaceControls row) are all inside the sidebar and its stay band — pointing at any of them keeps the sidebar out — and pressing each really switches to that space",
              "spaces=\(all.count) outside=\(outside) collapsed=\(collapsed) missed=\(missed)")
        screen.close()
        phone.browser.closeAll()
    }

    // MARK: - 畫面證據用

    /// 一支縮小的手機（外直 ×0.7：326×475）：頂列＋Browser（同 GlobalDMPhoneBox：欄在頂列底下一層、側欄頂天），外面留陰影邊。
    @MainActor static func smallShot(_ store: GlobalDMStore, _ content: some View) -> some View {
        PhoneColumns(store: store, form: .outerPortrait) { content }
        .frame(width: 326, height: 475)
        .modifier(GlobalDMBoxChrome())
        .padding(GlobalDMLayout.margin)
    }

}

extension DMBrowserPhoneAcceptance.Clickable {
    /// 量尺那一格（NSView）。
    func probeView(_ key: String) -> DMFrameProbeView? {
        DMBrowserPhoneAcceptance.views(DMFrameProbeView.self, in: host).first { $0.key == key }
    }

    /// 把這一格捲進看得到的範圍（左列的捲動區自己捲，同使用者捲到那裡）；回傳它看得到的那一段（視窗座標；看不到＝nil）。
    /// 不在捲動區裡（固定在上下的那兩塊）＝它自己的位置。
    /// 一層一層捲（空間圓點那一排自己是橫的捲動區，緊湊側欄裡它又在直的捲動區裡）；回傳每一層都看得到的那一段。
    func scrollIntoView(_ key: String) async -> CGRect? {
        guard let probe = probeView(key) else { return nil }
        var scrolls: [NSScrollView] = []
        var next = probe.enclosingScrollView
        while let scroll = next {
            scrolls.append(scroll)
            next = scroll.superview?.enclosingScrollView
        }
        guard !scrolls.isEmpty else {
            let frame = probe.convert(probe.bounds, to: nil)
            return frame.isEmpty ? nil : frame
        }
        probe.scrollToVisible(probe.bounds)
        for scroll in scrolls.dropLast() { scroll.scrollToVisible(scroll.bounds) }
        // 捲完等畫面跟上：那一格的位置連兩次一樣才量、才按（mini 忙的時候 SwiftUI 的排版會晚一拍，按到還在移動的格子＝點擊沒落在它上面）。
        var last = probe.convert(probe.bounds, to: nil)
        for _ in 0..<12 {
            await settle(2)
            let now = probe.convert(probe.bounds, to: nil)
            if now == last { break }
            last = now
        }
        await settle(2)
        var part = scrolls.reduce(probe.convert(probe.bounds, to: nil)) { part, scroll in
            part.intersection(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        }
        // 直的捲軸（剛捲過會浮出來）蓋在每一列最右邊：看得到、按得到的那一段不含捲軸（使用者也會按捲軸左邊那一段）。
        // 捲軸不一定掛在 verticalScroller 上（SwiftUI 的捲動區），所以找捲動區裡所有直的 NSScroller。
        for scroll in scrolls where !part.isNull {
            for scroller in DMBrowserPhoneAcceptance.views(NSScroller.self, in: scroll)
            where !scroller.isHidden && scroller.frame.height > scroller.frame.width {
                let bar = scroller.convert(scroller.bounds, to: nil)
                if bar.intersects(part), bar.minX > part.minX { part.size.width = min(part.width, bar.minX - part.minX) }
            }
        }
        return part.isNull || part.isEmpty ? nil : part
    }

    /// 這一點按下去會落在捲軸上嗎（落在上面＝回傳那一條捲軸）。
    func scroller(at point: NSPoint) -> NSScroller? {
        guard let root = window.contentView else { return nil }
        var view = root.hitTest(root.superview.map { $0.convert(point, from: nil) } ?? point)
        while let current = view {
            if let scroller = current as? NSScroller { return scroller }
            view = current.superview
        }
        return nil
    }

    /// 這一點按下去會落在哪一種畫面元件上（自測失敗時印出來查）。
    func hitName(at point: NSPoint) -> String {
        guard let root = window.contentView,
              let hit = root.hitTest(root.superview.map { $0.convert(point, from: nil) } ?? point) else { return "nil" }
        return String(describing: Swift.type(of: hit))   // 這個類別自己有 type(_:)（打字）
    }

    /// 真的打字：等網址欄拿到游標（欄位編輯器），把字交給它（同輸入法把選好的字送上來的路）。回傳欄位裡是不是就是這些字。
    func type(_ text: String) async -> Bool {
        _ = await DMBrowserAcceptance.waitUntil(2) { self.window.firstResponder is NSTextView }
        guard let editor = window.firstResponder as? NSTextView else { return false }
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(2)
        return editor.string == text
    }
}
#endif
