#if DEBUG
import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// `TATWO2_SELFTEST=w184cu`（W184 CU：09-30 mini .032 兩個實測失敗——以 TATWO 自己為目標時 AXShowMenu 開了選單就卡死整個 App、
/// 開著好幾個自家視窗時 computer_observe 三次都回 computer_window_not_uniquely_identified）。
///
/// A 排程（不需要系統權限）：選單在「GCD 主佇列區塊」裡開＝bridge 式的 main.sync 排不進去（反例：.032 的卡死）；
///   在 run loop 的區塊回呼裡開（正式的 ComputerUseNative.performOnMainRunLoop）＝main.sync、MainActor、ComputerUseNative.run 照常。
/// B 真的 AX（要輔助使用權限；mini 的 ssh 有）：以自己為目標、走正式的 backgroundInput／input／readState——
///   AXShowMenu 直接叫同一個元件的 NSAccessibility 動作（不經 AX 呼叫；AppKit 圓鈕與 SwiftUI 圓鈕各一次）、
///   選單開著時 bridge 照常、觀察回得來而且讀得到選單項目、點項目收起並執行、Esc 收起；
///   背景事件不能用時的退路（AX 呼叫本身開選單）：bridge 照常、觀察回「忙」不卡、Esc（不碰 AX）收起；
///   反例：舊做法（GCD 主佇列裡叫 AX）開同一份選單＝main.sync 排不進去。
/// C 挑視窗：規則（純資料）＋真的自家視窗（同位置大小：一般、alpha 0、收起來的、不接滑鼠的浮層、擋擷取的）＋錯誤附候選清單＋windowID；
///   ScreenCaptureKit 那段要螢幕錄製權限（ssh 沒有）＝SKIP，主導實機驗。
/// W184 CU 第二輪（GPT-6 審查 1–6 的反例）：B10 選單開著時停止、撤權、斷線、失焦、敏感頁＝排進去的動作作廢；B11 事件照觀察時
///   確定的視窗（兩套座標）；C 的「可以用」是每一條分支的前置條件（指定的、知道編號的都拒絕不可以用的，錯誤裡受保護的不給標題）、
///   沒有視窗編號時指定＝拒絕、同角色同位置疊著的元件對不到唯一一個＝退回 AX；E 真的 ChatPageModel 權限 setter 降級＝當場撤銷。
/// W184 CU 第三輪（GPT-6 複核）：C0 擋擷取三態（讀不到＝受保護）與 WindowCaptureShield 強制否決；C1 沒有視窗編號＝一律拒絕；
///   C3 受保護的 fixture 是自己建的，判成可以用＝FAIL（不再依結果 SKIP）；C6 選單的座標換算；C7 控制器的 observe 整段——
///   成功回應裡受保護／讀不到的視窗沒有標題、私有 API 失效時截圖與不截圖同樣拒絕；B13 選單項目的合成事件送到選單自己的視窗、
///   跨視窗拖曳拒絕、按鍵的 believer 照編號。
/// 每一段都有看門狗：卡住（主執行緒卡死）＝FAIL 並退出，不讓驗證一直排隊等。
enum ComputerUseSelfTargetAcceptance {
    @MainActor final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: @autoclosure () -> String = "") {
            if condition { passed += 1 } else { failed += 1 }
            let detail = evidence()
            print("W184CU \(condition ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — " + String(detail.prefix(700)))")
        }
        func skip(_ label: String) {
            skipped += 1
            print("W184CU SKIP \(label)")
        }
        func note(_ text: String) { print("W184CU NOTE \(text)") }
    }

    /// 看門狗：哪一段超時（多半是主執行緒卡死）就印 FAIL、SUMMARY 並退出。
    final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var phase = "start"
        private var deadline = Date().addingTimeInterval(30)
        func enter(_ name: String, seconds: Double) {
            lock.lock(); phase = name; deadline = Date().addingTimeInterval(seconds); lock.unlock()
        }
        func finish() { lock.lock(); phase = "done"; lock.unlock() }
        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    Thread.sleep(forTimeInterval: 0.25)
                    lock.lock(); let (current, until) = (phase, deadline); lock.unlock()
                    if current == "done" { return }
                    if Date() > until {
                        print("W184CU FAIL watchdog: \(current) did not finish in time (main thread stuck?)")
                        print("W184CU SUMMARY failures=1 watchdog")
                        exit(1)
                    }
                }
            }
        }
    }

    /// 選單開關的次數：主執行緒記、背景量的時候讀（上鎖）。
    final class MenuFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = 0, closed = 0
        func open() { lock.lock(); opened += 1; lock.unlock() }
        func close() { lock.lock(); closed += 1; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened > closed }
        var openings: Int { lock.lock(); defer { lock.unlock() }; return opened }
        var counts: String { lock.lock(); defer { lock.unlock() }; return "opened=\(opened) closed=\(closed)" }
    }

    /// 選單的委派與項目的動作：記開關、記按了哪一個。
    final class MenuLog: NSObject, NSMenuDelegate, @unchecked Sendable {
        let flag = MenuFlag()
        private let lock = NSLock()
        private var titles: [String] = []
        var picked: [String] { lock.lock(); defer { lock.unlock() }; return titles }
        func menuWillOpen(_ menu: NSMenu) { flag.open() }
        func menuDidClose(_ menu: NSMenu) { flag.close() }
        @objc func pick(_ sender: NSMenuItem) { lock.lock(); titles.append(sender.title); lock.unlock() }
    }

    /// 真的執行前重驗的那五件事（自測撥開關：撤權、斷線、失焦、敏感頁）。
    final class Flags: @unchecked Sendable {
        var connected = true, context = true, permitted = true, sensitive = false
        func reset() { connected = true; context = true; permitted = true; sensitive = false }
    }
    static func authority(_ grant: ComputerUseSession.Grant, _ gate: ComputerUseSession, _ flags: Flags) -> ComputerUseSelfAuthority {
        ComputerUseSelfAuthority(grant: grant, gate: gate, requestIsConnected: { flags.connected },
                                 contextIsCurrent: { flags.context }, selfTargetPermitted: { flags.permitted },
                                 sensitivePageOpen: { flags.sensitive })
    }

    /// 自測的圓鈕：跟私訊框左上的頁面圓鈕一樣——AX 的「顯示選單」從圓鈕下方跳出（popUp），右鍵跳出系統右鍵選單（popUpContextMenu）。
    final class MenuCircle: NSView {
        var popupMenu: NSMenu?
        var showMenuCalls = 0
        var rightDowns = 0
        static let label = "W184 CU 圓鈕"
        var labelText = MenuCircle.label
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { labelText }
        override func accessibilityTitle() -> String? { labelText }
        override func accessibilityPerformShowMenu() -> Bool {
            showMenuCalls += 1
            guard let popupMenu else { return false }
            popupMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
            return true
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func rightMouseDown(with event: NSEvent) {
            rightDowns += 1
            if let popupMenu { NSMenu.popUpContextMenu(popupMenu, with: event, for: self) }
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemGray.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }

    /// 跟私訊框頁面圓鈕同一種寫法的 SwiftUI 圓鈕：`.accessibilityAction(.showMenu)` 從疊在上面的 NSView 下方跳出選單
    ///（GlobalDMPageMenu 的做法，AX 樹裡是 SwiftUI 的 AccessibilityNode）。
    @MainActor final class SwiftUIAnchor {
        weak var view: NSView?
        var showMenuCalls = 0
        func showMenu(_ menu: NSMenu) {
            showMenuCalls += 1
            guard let view else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
        }
    }
    struct SwiftUIAnchorView: NSViewRepresentable {
        let anchor: SwiftUIAnchor
        func makeNSView(context: Context) -> NSView { let view = NSView(); anchor.view = view; return view }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
    struct SwiftUICircle: View {
        static let label = "W184 CU SwiftUI 圓鈕"
        let anchor: SwiftUIAnchor
        let menu: NSMenu
        var body: some View {
            Button(action: {}) { Circle().fill(Color.gray).frame(width: 44, height: 44) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Self.label))
                .overlay { SwiftUIAnchorView(anchor: anchor) }
                .accessibilityAction(.showMenu) { anchor.showMenu(menu) }
                .frame(width: 200, height: 120)
        }
    }

    @MainActor final class Fixture {
        let window: NSWindow
        let circle = MenuCircle(frame: NSRect(x: 24, y: 120, width: 44, height: 44))
        let menu = NSMenu(title: "W184 CU")
        let log = MenuLog()
        init(screen: NSScreen) {
            let visible = screen.visibleFrame
            window = NSWindow(contentRect: NSRect(x: visible.minX + 80, y: visible.maxY - 260, width: 280, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "W184 CU 自測"
            window.isReleasedWhenClosed = false
            menu.autoenablesItems = false
            menu.delegate = log
            for title in ["甲", "乙", "丙"] {
                let item = NSMenuItem(title: title, action: #selector(MenuLog.pick(_:)), keyEquivalent: "")
                item.target = log
                menu.addItem(item)
            }
            circle.popupMenu = menu
            window.contentView?.addSubview(circle)
            window.orderFrontRegardless()
        }
        func close() {
            menu.cancelTracking()
            window.orderOut(nil)
        }
    }

    struct Probe: Sendable, CustomStringConvertible {
        var menuOpened = false, mainSync = false, mainActor = false, nativeRun = false, stillOpenAfter = false
        var description: String {
            "menuOpened=\(menuOpened) mainSync=\(mainSync) mainActor=\(mainActor) nativeRun=\(nativeRun) stillOpenAfter=\(stillOpenAfter)"
        }
        var allRan: Bool { menuOpened && mainSync && mainActor && nativeRun && stillOpenAfter }
    }

    /// 背景執行緒：等選單開起來（最多 2 秒），量三種要回主執行緒的工作，各等最多 timeout 秒：
    /// bridge 式的 DispatchQueue.main.sync（OSAgentBridge.onMain 的做法）、MainActor 的工作、ComputerUseNative.run（觀察、輸入回主執行緒那一跳）。
    static func probeWhileOpen(_ flag: MenuFlag, timeout: Double) async -> Probe {
        await withCheckedContinuation { (continuation: CheckedContinuation<Probe, Never>) in
            Thread.detachNewThread {
                var probe = Probe()
                let until = Date().addingTimeInterval(2)
                while !flag.isOpen && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
                probe.menuOpened = flag.isOpen
                Thread.sleep(forTimeInterval: 0.15)
                let synced = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async { DispatchQueue.main.sync {}; synced.signal() }
                probe.mainSync = synced.wait(timeout: .now() + timeout) == .success
                let hopped = DispatchSemaphore(value: 0)
                Task { @MainActor in hopped.signal() }
                probe.mainActor = hopped.wait(timeout: .now() + timeout) == .success
                let ran = DispatchSemaphore(value: 0)
                Task.detached { _ = try? await ComputerUseNative.run(pid: getpid()) { Thread.isMainThread }; ran.signal() }
                probe.nativeRun = ran.wait(timeout: .now() + timeout) == .success
                probe.stillOpenAfter = flag.isOpen
                continuation.resume(returning: probe)
            }
        }
    }

    @MainActor static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }

    /// 保險：common 模式的計時器（在選單的追蹤迴圈、甚至卡在 GCD 主佇列區塊裡都輪得到）到時收掉選單；回傳它有沒有出手。
    @MainActor final class Safety {
        private(set) var fired = false
        private var timer: Timer?
        init(_ menu: NSMenu, after seconds: Double) {
            let timer = Timer(timeInterval: seconds, repeats: false) { [weak self, weak menu] _ in
                MainActor.assumeIsolated {
                    self?.fired = true
                    menu?.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        func cancel() { timer?.invalidate() }
    }

    @MainActor static func run() async -> Bool {
        let check = Checker()
        let watchdog = Watchdog()
        watchdog.start()
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            check.skip("整段：這個環境沒有螢幕（選單、視窗都開不起來）；規則在 tests/w184-cu.test.mjs，主導實機驗")
            windowPickRuleChecks(check)
            parameterChecks(check)
            watchdog.finish()
            print("W184CU SUMMARY failures=\(check.failed) passed=\(check.passed) skipped=\(check.skipped)")
            return check.failed == 0
        }
        check.note("environment: accessibility trusted=\(AXIsProcessTrusted()) screen recording=\(CGPreflightScreenCaptureAccess()) background events=\(ComputerUseBackgroundEvents.available) screens=\(NSScreen.screens.count) main=\(screen.frame)")
        let fixture = Fixture(screen: screen)
        defer { fixture.close() }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }

        await schedulerChecks(check, fixture, watchdog)
        if AXIsProcessTrusted() {
            await axMenuChecks(check, fixture, watchdog)
        } else {
            check.skip("B 真的 AX 那段：這個執行檔沒有輔助使用權限（AXIsProcessTrusted＝false）；A 段已驗排程本身，主導實機驗 AX 路徑")
        }
        watchdog.enter("C window picking", seconds: 90)
        windowPickRuleChecks(check)
        await realWindowChecks(check, screen: screen)
        parameterChecks(check)
        await permissionSetterChecks(check, watchdog)
        watchdog.finish()
        print("W184CU SUMMARY failures=\(check.failed) passed=\(check.passed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    // MARK: - A 排程（不需要系統權限）

    @MainActor static func schedulerChecks(_ check: Checker, _ fixture: Fixture, _ watchdog: Watchdog) async {
        let flag = fixture.log.flag
        // A1 反例（.032 出貨的做法）：在 GCD 主佇列區塊裡開選單。
        // 這台的桌面可能有人在用：選單被外面的點擊收掉（開了、沒到保險就關）＝重做一次，最多三次。
        watchdog.enter("A1 GCD counterexample", seconds: 40)
        var old = Probe(), closed1 = false, safety1 = Safety(fixture.menu, after: 3)
        for attempt in 1...3 {
            safety1 = Safety(fixture.menu, after: 3)
            DispatchQueue.main.async { _ = fixture.circle.accessibilityPerformShowMenu() }
            old = await probeWhileOpen(flag, timeout: 0.6)
            closed1 = await waitUntil(6) { !flag.isOpen }
            safety1.cancel()
            if old.menuOpened && (old.stillOpenAfter || safety1.fired) { break }
            check.note("A1 attempt \(attempt): the menu was dismissed from outside (\(old)); retrying")
        }
        check(old.menuOpened && !old.mainSync && !old.mainActor && closed1,
              "A1 counterexample (.032 as shipped): a menu opened inside a GCD main-queue block (DispatchQueue.main.async) keeps bridge-style main.sync and MainActor work out until the menu is closed by hand — this is the hang, and it shows this test can fail",
              "\(old) closed=\(closed1) safetyFired=\(safety1.fired) \(flag.counts)")

        // A2 正式的排程：run loop 的區塊回呼（主執行緒、不在主佇列區塊裡）。
        watchdog.enter("A2 run-loop scheduler", seconds: 20)
        let safety2 = Safety(fixture.menu, after: 8)
        ComputerUseNative.performOnMainRunLoop { _ = fixture.circle.accessibilityPerformShowMenu() }
        let fixed = await probeWhileOpen(flag, timeout: 1.0)
        let openDuring = flag.isOpen
        // 選單開著時再排一個 run loop 區塊（跟點選單項目的 AXPress 同一條路）：收起來。
        ComputerUseNative.performOnMainRunLoop { fixture.menu.cancelTracking() }
        let closed2 = await waitUntil(3) { !flag.isOpen }
        safety2.cancel()
        check(fixed.allRan && openDuring && closed2 && !safety2.fired,
              "A2 production scheduler (ComputerUseNative.performOnMainRunLoop: CFRunLoopPerformBlock, common modes): the same menu open on the main thread, and bridge-style main.sync, MainActor work and ComputerUseNative.run's hop all run while it is open; a block scheduled the same way closes it",
              "\(fixed) openDuring=\(openDuring) closed=\(closed2) safetyFired=\(safety2.fired)")
    }

    // MARK: - B 真的 AX（以自己為目標，走正式的函式）

    @MainActor static func axMenuChecks(_ check: Checker, _ fixture: Fixture, _ watchdog: Watchdog) async {
        let flag = fixture.log.flag
        let gate = ComputerUseSession()
        let grant: ComputerUseSession.Grant
        do {
            grant = try gate.authorize(owner: UUID(), scope: "w184cu", pid: getpid(), expectedEpoch: gate.currentEpoch)
        } catch {
            return check(false, "B0 a self-target grant for this process", "\(error)")
        }
        let running = NSRunningApplication.current
        let windowID = CGWindowID(fixture.window.windowNumber)
        let flags = Flags()
        let auth = authority(grant, gate, flags)
        func observe(_ wanted: CGWindowID? = nil) async throws -> ComputerUseNative.State {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            let preferred = wanted ?? windowID
            return try await ComputerUseNative.run(pid: getpid()) {
                try ComputerUseNative.readState(running, deadline: deadline, includeTree: true, preferredWindowID: preferred)
            }
        }
        /// 跟 ComputerUseController.perform 一樣的順序：先試背景（AX），不適用才走 input。
        func act(_ request: ComputerUseNative.Request, on state: ComputerUseNative.State) async throws -> ComputerUseNative.BackgroundOutcome {
            let published = try gate.publish(fingerprint: "", for: grant, elements: state.elements, state: state)
            let observation = try gate.beginAction(observationID: published.id.uuidString, fingerprint: "", for: grant)
            defer { gate.endAction(observationID: observation.id, for: grant) }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            let outcome = try await ComputerUseNative.run(pid: getpid()) {
                try ComputerUseNative.backgroundInput(request, observation: observation, authority: auth, deadline: deadline)
            }
            if case .done = outcome { return outcome }
            try await ComputerUseNative.run(pid: getpid()) {
                try ComputerUseNative.input(request, observation: observation, authority: auth, deadline: deadline)
            }
            return outcome
        }
        func circleIndex(_ state: ComputerUseNative.State?) -> Int? {
            state?.nodes.firstIndex { $0.title == MenuCircle.label && $0.actions.contains("AXShowMenu") }
        }
        func menuItems(_ state: ComputerUseNative.State?) -> [(index: Int, title: String)] {
            (state?.nodes ?? []).enumerated().filter { $0.element.inOpenMenu && $0.element.role == "AXMenuItem" }
                .map { ($0.offset, $0.element.title) }
        }
        /// 讀不到選單項目時的證據：自己的選單視窗（層級、位置）、在那裡的 hit test、這次觀察裡的每一個節點。
        func menuEvidence(_ state: ComputerUseNative.State?) -> String {
            let app = AXUIElementCreateApplication(getpid())
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let windows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }.map { info -> String in
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                var hit: AXUIElement?
                var chain: [String] = []
                if AXUIElementCopyElementAtPosition(app, Float(bounds.midX), Float(bounds.minY + min(12, bounds.height / 2)), &hit) == .success,
                   var node = hit {
                    for _ in 0..<5 {
                        var role: CFTypeRef?; AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
                        chain.append(role as? String ?? "?")
                        var parent: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                              let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                        node = parent as! AXUIElement
                    }
                }
                return "layer=\(info[kCGWindowLayer as String] as? Int ?? -1) \(bounds) hit=\(chain.joined(separator: "<"))"
            }
            let nodes = (state?.nodes ?? []).map { "\($0.role) \($0.title)\($0.inOpenMenu ? " [menu]" : "")" }
            return "windows=\(windows) nodes=\(nodes)"
        }
        let escape: ComputerUseNative.Key
        do { escape = try ComputerUseNative.parseKey("escape") } catch { return check(false, "B0 escape key", "\(error)") }

        // B1 觀察這個自測視窗：視窗伺服器編號對得上、找得到圓鈕。
        watchdog.enter("B1 observe", seconds: 20)
        let first = try? await observe()
        let circle = circleIndex(first)
        check(first?.windowID == windowID && circle != nil && first?.busy == false
              && first?.windowPayload(disclosing: ComputerUseWindowPick.facts(pid: getpid())).contains { ($0["windowID"] as? Int) == Int(windowID) } == true,
              "B1 observing TATWO itself reads the fixture window, knows its window-server number (_AXUIElementGetWindow; also in windows[].windowID) and finds the circle with AXShowMenu",
              "windowID=\(String(describing: first?.windowID)) expected=\(windowID) circle=\(String(describing: circle)) nodes=\(first?.nodes.count ?? -1)")
        guard let first, let circle else { return }

        // B2 AXShowMenu（正式的 input）：直接叫同一個元件的 NSAccessibility「顯示選單」，不是同行程的 AX 呼叫、也不是合成右鍵。
        watchdog.enter("B2 AXShowMenu", seconds: 20)
        let safety = Safety(fixture.menu, after: 15)
        let rightBefore = fixture.circle.rightDowns, axBefore = fixture.circle.showMenuCalls
        var failure = ""
        do { _ = try await act(.axAction(circle, "AXShowMenu"), on: first) } catch { failure = "\(error)" }
        let opened = await waitUntil(2) { flag.isOpen }
        check(opened && failure.isEmpty && fixture.circle.showMenuCalls == axBefore + 1
              && fixture.circle.rightDowns == rightBefore && !ComputerUseNative.SelfAction.inFlight,
              "B2 perform_ax_action AXShowMenu on TATWO itself (production input) opens the menu by calling that same element's NSAccessibility show-menu action from a main run-loop block (found in-process by role and frame) — not an in-process AX call, not a synthesized click; nothing is left in flight",
              "opened=\(opened) error=\(failure) showMenu=\(fixture.circle.showMenuCalls - axBefore) rightDowns=\(fixture.circle.rightDowns - rightBefore) inFlight=\(ComputerUseNative.SelfAction.inFlight) \(flag.counts)")

        // B3 選單開著：bridge 照常、觀察回得來、讀得到選單項目。
        watchdog.enter("B3 observe while open", seconds: 20)
        let probe = await probeWhileOpen(flag, timeout: 1.0)
        check(probe.allRan,
              "B3 while that menu is open, bridge-style main.sync (OSAgentBridge.onMain), MainActor work and ComputerUseNative.run's hop all run (no os_bridge_timeout)",
              "\(probe)")
        let started = Date()
        let during = try? await observe()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let items = menuItems(during)
        let text = during?.render(width: 0, height: 0).text ?? ""
        check(during != nil && during?.busy == false && elapsed < 3000 && flag.isOpen
              && ["甲", "乙", "丙"].allSatisfy { title in items.contains { $0.title == title } } && text.contains("(open menu)"),
              "B3 observing TATWO itself while the menu is open comes back (production readState, not busy) and lists the open menu's items 甲 乙 丙 as open-menu elements (text says (open menu), not (offscreen))",
              "elapsed=\(elapsed)ms busy=\(String(describing: during?.busy)) items=\(items.map(\.title)) open=\(flag.isOpen) \(items.isEmpty ? menuEvidence(during) : "")")

        // B4 點「乙」（正式的 backgroundInput：AXPress 排到 run loop）：選單收起、乙 執行了。
        watchdog.enter("B4 click item", seconds: 20)
        let pickedBefore = fixture.log.picked.count
        var clicked = false
        failure = ""
        if let during, let item = items.first(where: { $0.title == "乙" }) {
            do {
                if case .done = try await act(.pointer(.init(kind: .click, from: .element(item.index), to: nil, dx: 0, dy: 0)), on: during) {
                    clicked = true
                }
            } catch { failure = "\(error)" }
        }
        let closedByItem = await waitUntil(3) { !flag.isOpen }
        let ran = await waitUntil(2) { fixture.log.picked.count > pickedBefore }
        check(clicked && closedByItem && ran && fixture.log.picked.last == "乙" && !safety.fired,
              "B4 clicking menu item 乙 by element (production backgroundInput: AXPress on the item, scheduled on the main run loop) closes the menu and runs 乙",
              "clicked=\(clicked) error=\(failure) closed=\(closedByItem) picked=\(fixture.log.picked) safetyFired=\(safety.fired)")

        // B5 右鍵（正式的指標路徑）再開、press_key escape（正式的 input）收起，什麼都沒選。
        watchdog.enter("B5 right_click + escape", seconds: 25)
        let fresh = try? await observe()
        var opened2 = false, closedByEscape = false
        failure = ""
        if let fresh, let index = circleIndex(fresh) {
            let picked = fixture.log.picked.count
            let rights = fixture.circle.rightDowns, shows = fixture.circle.showMenuCalls
            do {
                _ = try await act(.pointer(.init(kind: .rightClick, from: .element(index), to: nil, dx: 0, dy: 0)), on: fresh)
                opened2 = await waitUntil(2) { flag.isOpen }
                let open = try await observe()
                _ = try await act(.pressKey(escape), on: open)
                closedByEscape = await waitUntil(3) { !flag.isOpen }
            } catch { failure = "\(error)" }
            check(opened2 && closedByEscape && fixture.log.picked.count == picked && !safety.fired
                  && fixture.circle.showMenuCalls == shows + 1 && fixture.circle.rightDowns == rights,
                  "B5 right_click on the circle (production backgroundInput: an element with AXShowMenu = its show-menu action, called directly) opens the menu; press_key escape (production input) closes it and picks nothing",
                  "opened=\(opened2) closed=\(closedByEscape) error=\(failure) picked=\(fixture.log.picked) showMenu=\(fixture.circle.showMenuCalls - shows) rightDowns=\(fixture.circle.rightDowns - rights) safetyFired=\(safety.fired)")
        } else {
            check(false, "B5 the circle is still observable after the menu closed", "state=\(fresh != nil)")
        }
        safety.cancel()

        // B6 退路（背景事件不能用時）：AX 呼叫本身開選單，追蹤迴圈卡在這個 AX 呼叫裡。
        watchdog.enter("B6 nested AX fallback", seconds: 25)
        let safety6 = Safety(fixture.menu, after: 15)
        let third = try? await observe()
        if let third, let index = circleIndex(third) {
            let axBefore6 = fixture.circle.showMenuCalls
            let picked6 = fixture.log.picked.count
            _ = ComputerUseNative.performAction(third.elements[index], "AXShowMenu", authority: auth)
            let opened6 = await waitUntil(2) { flag.isOpen }
            let inFlight = ComputerUseNative.SelfAction.inFlight
            let probe6 = await probeWhileOpen(flag, timeout: 1.0)
            check(opened6 && fixture.circle.showMenuCalls == axBefore6 + 1 && inFlight && probe6.allRan,
                  "B6 fallback (no background events): performAction runs AXShowMenu itself, scheduled on the main run loop — the menu's loop sits inside that AX call, and bridge-style main.sync, MainActor work and ComputerUseNative.run still run (the .032 fix)",
                  "opened=\(opened6) axShowMenu=\(fixture.circle.showMenuCalls - axBefore6) inFlight=\(inFlight) \(probe6)")
            let busyStart = Date()
            let busy = try? await observe()
            let busyMS = Int(Date().timeIntervalSince(busyStart) * 1000)
            check(busy?.busy == true && busy?.elements.isEmpty == true && busyMS < 1500 && flag.isOpen,
                  "B6 observing while that AX call is still inside the menu returns busy at once (no nested in-process AX read — that one froze the main thread in the 09-30 probe)",
                  "busy=\(String(describing: busy?.busy)) elapsed=\(busyMS)ms open=\(flag.isOpen)")
            var refused = ""
            if let busy {
                do { _ = try await act(.typeText("x"), on: busy) } catch { refused = (error as? ComputerUseFailure)?.code ?? "\(error)" }
            }
            check(refused == ComputerUseNative.selfBusyCode,
                  "B6 while busy, input other than keys is refused without touching AX (\(ComputerUseNative.selfBusyCode))", "got=\(refused)")
            failure = ""
            if let busy { do { _ = try await act(.pressKey(escape), on: busy) } catch { failure = "\(error)" } }
            let closed6 = await waitUntil(3) { !flag.isOpen }
            let settled = await waitUntil(3) { !ComputerUseNative.SelfAction.inFlight }
            let after = try? await observe()
            check(failure.isEmpty && closed6 && settled && after?.busy == false && circleIndex(after) != nil
                  && fixture.log.picked.count == picked6 && !safety6.fired,
                  "B6 press_key escape on the busy observation (production input: the key goes to this process without AX) closes the menu; the AX call returns and observing works normally again",
                  "error=\(failure) closed=\(closed6) settled=\(settled) afterBusy=\(String(describing: after?.busy)) safetyFired=\(safety6.fired)")
        } else {
            check(false, "B6 the circle is observable before the fallback", "state=\(third != nil)")
        }
        safety6.cancel()

        // B7 反例：舊做法（GCD 主佇列裡直接叫 AX，.032 出貨的樣子）開同一份選單。
        watchdog.enter("B7 AX in GCD counterexample", seconds: 20)
        if let fourth = try? await observe(), let index = circleIndex(fourth) {
            let node = fourth.elements[index]
            var old = Probe(), closed7 = false, safety7 = Safety(fixture.menu, after: 3)
            for attempt in 1...3 {
                safety7 = Safety(fixture.menu, after: 3)
                DispatchQueue.main.async { _ = AXUIElementPerformAction(node, "AXShowMenu" as CFString) }
                old = await probeWhileOpen(flag, timeout: 0.6)
                closed7 = await waitUntil(6) { !flag.isOpen }
                safety7.cancel()
                if old.menuOpened && (old.stillOpenAfter || safety7.fired) { break }
                check.note("B7 attempt \(attempt): the menu was dismissed from outside (\(old)); retrying")   // 桌面有人在用
            }
            check(old.menuOpened && !old.mainSync && closed7 && safety7.fired,
                  "B7 counterexample (.032 as shipped): the same AXShowMenu performed inside DispatchQueue.main.async keeps bridge-style main.sync out while the menu is open (only the safety timer frees it)",
                  "\(old) closed=\(closed7) safetyFired=\(safety7.fired)")
        } else {
            check(false, "B7 the circle is observable before the counterexample")
        }
        await swiftUIMenuChecks(check, fixture, watchdog, observe: observe, act: act, escape: escape)
        gate.stop()   // B1–B9 的 grant 到此為止；B10–B12 各自拿新的
        await revocationChecks(check, fixture, watchdog, gate: gate, flags: flags, observe: observe, escape: escape)
        await eventGeometryChecks(check, fixture, watchdog, observe: observe, gate: gate, flags: flags)
        await elementIdentityChecks(check, fixture, watchdog, gate: gate, flags: flags)
        await menuEventTargetChecks(check, fixture, watchdog, observe: observe, gate: gate)
        check(!ComputerUseNative.SelfAction.inFlight && !flag.isOpen, "B8 nothing left open or in flight at the end", "\(flag.counts)")
    }

    /// B10（GPT-6 審查 #2 的反例）：選單還卡在 AX 呼叫裡（modal 開著）時——停止（撤銷）、權限降級、斷線、失焦、敏感頁——
    /// 排進 run loop 還沒跑的自我動作一律作廢（token 沒了或重驗不過）；條件都好時同一個動作照跑。撤銷不會自動關掉 modal
    /// （只有按鍵能收；下一個 grant 觀察回忙）——這是設計，自測寫明。
    @MainActor static func revocationChecks(_ check: Checker, _ fixture: Fixture, _ watchdog: Watchdog,
                                            gate: ComputerUseSession, flags: Flags,
                                            observe: (CGWindowID?) async throws -> ComputerUseNative.State,
                                            escape: ComputerUseNative.Key) async {
        watchdog.enter("B10 revocation while a modal is open", seconds: 60)
        let flag = fixture.log.flag
        typealias S = ComputerUseNative.SelfSchedule
        // 先在沒有 modal 時找好圓鈕的直接動作（modal 開著時不能再讀 AX：會卡死，正式路徑也不會）。
        guard let state = try? await observe(nil),
              let index = state.nodes.firstIndex(where: { $0.title == MenuCircle.label && $0.actions.contains("AXShowMenu") }),
              let direct = ComputerUseNative.selfDirectAction(state.elements[index], "AXShowMenu", pid: getpid(),
                                                              deadline: ProcessInfo.processInfo.systemUptime + 8) else {
            return check(false, "B10 the circle's direct action is resolvable before the modal opens")
        }
        func pump() async { for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); await Task.yield() } }
        /// 排一個、把條件弄壞、跑一輪：一定沒開選單、佇列空了。
        func voided(_ label: String, _ grant: ComputerUseSession.Grant, _ spoil: () -> Void) async -> Bool {
            flags.reset()
            let before = fixture.circle.showMenuCalls
            let token = direct.schedule(authority: authority(grant, gate, flags))
            spoil()
            await pump()
            let ok = fixture.circle.showMenuCalls == before && !S.isPending(token) && S.pendingCount == 0
            check(ok, label, "showMenu=\(fixture.circle.showMenuCalls - before) pending=\(S.isPending(token)) queue=\(S.pendingCount) open=\(flag.isOpen)")
            flags.reset()
            return ok
        }
        // 開 modal：AX 呼叫本身開選單（退路），追蹤迴圈卡在那個 AX 呼叫裡。
        let grant1: ComputerUseSession.Grant
        do { grant1 = try gate.authorize(owner: UUID(), scope: "w184cu-b10", pid: getpid(), expectedEpoch: gate.currentEpoch) }
        catch { return check(false, "B10 grant", "\(error)") }
        let safety = Safety(fixture.menu, after: 40)
        defer { safety.cancel() }
        _ = ComputerUseNative.performAction(state.elements[index], "AXShowMenu", authority: authority(grant1, gate, flags))
        let opened = await waitUntil(2) { flag.isOpen }
        check(opened && ComputerUseNative.SelfAction.inFlight, "B10 the modal is open inside the AX call (in flight)",
              "opened=\(opened) inFlight=\(ComputerUseNative.SelfAction.inFlight)")
        _ = await voided("B10 counterexample: permission downgraded (no longer full access) after scheduling = the queued self action never runs", grant1) { flags.permitted = false }
        _ = await voided("B10 counterexample: the request disconnected after scheduling = never runs", grant1) { flags.connected = false }
        _ = await voided("B10 counterexample: the context changed (not the selected local chat any more) after scheduling = never runs", grant1) { flags.context = false }
        _ = await voided("B10 counterexample: a sensitive page appeared after scheduling = never runs", grant1) { flags.sensitive = true }
        _ = await voided("B10 counterexample: the grant was stopped (epoch moved) after scheduling = never runs", grant1) { gate.stop(ifCurrent: grant1) }
        // 控制器的停止：排進去的一律作廢（token 拿掉），連重驗都不用。
        let grant2: ComputerUseSession.Grant
        do { grant2 = try gate.authorize(owner: UUID(), scope: "w184cu-b10", pid: getpid(), expectedEpoch: gate.currentEpoch) }
        catch { return check(false, "B10 second grant", "\(error)") }
        flags.reset()
        let before = fixture.circle.showMenuCalls
        let token = direct.schedule(authority: authority(grant2, gate, flags))
        let pendingBefore = S.pendingCount
        #if DEBUG
        let revocations = ComputerUseController.revocations
        #endif
        ComputerUseController.shared.stop()
        let cancelled = !S.isPending(token) && S.pendingCount == 0
        await pump()
        #if DEBUG
        let revoked = ComputerUseController.revocations == revocations + 1
        #else
        let revoked = true
        #endif
        check(pendingBefore == 1 && cancelled && revoked && fixture.circle.showMenuCalls == before && flag.isOpen && ComputerUseNative.SelfAction.inFlight,
              "B10 Stop while the modal is open: the controller voids every queued self action at once (token gone before the run loop turns) and revokes; the modal itself stays open (by design: only a key closes it, the next observe says busy)",
              "pendingBefore=\(pendingBefore) cancelled=\(cancelled) revoked=\(revoked) showMenu=\(fixture.circle.showMenuCalls - before) open=\(flag.isOpen) inFlight=\(ComputerUseNative.SelfAction.inFlight)")
        // 停止之後（自測的 gate 跟控制器的 session 是兩份：這裡把 gate 也停掉，跟控制器停止後的樣子一樣）：
        // 新的 grant 觀察＝忙；按 Esc 收掉；AX 呼叫回來、不忙。
        gate.stop()
        let grant3: ComputerUseSession.Grant
        do { grant3 = try gate.authorize(owner: UUID(), scope: "w184cu-b10", pid: getpid(), expectedEpoch: gate.currentEpoch) }
        catch { return check(false, "B10 third grant", "\(error)") }
        let busy = try? await observe(nil)
        var failure = ""
        if let busy {
            do {
                let published = try gate.publish(fingerprint: "", for: grant3, elements: [], state: busy)
                let observation = try gate.beginAction(observationID: published.id.uuidString, fingerprint: "", for: grant3)
                defer { gate.endAction(observationID: observation.id, for: grant3) }
                try ComputerUseNative.postKeyToSelf(escape, observation: observation, grant: grant3, gate: gate)
            } catch { failure = "\(error)" }
        }
        let closed = await waitUntil(3) { !flag.isOpen }
        let settled = await waitUntil(3) { !ComputerUseNative.SelfAction.inFlight }
        check(busy?.busy == true && failure.isEmpty && closed && settled && !safety.fired,
              "B10 after Stop a new grant observes busy; press_key escape closes the modal; the AX call returns",
              "busy=\(String(describing: busy?.busy)) error=\(failure) closed=\(closed) settled=\(settled) safetyFired=\(safety.fired)")
        // 條件都好：同一個動作照跑（證明上面作廢的是條件，不是 modal）。
        flags.reset()
        let ran = fixture.circle.showMenuCalls
        _ = direct.schedule(authority: authority(grant3, gate, flags))
        let openedAgain = await waitUntil(2) { flag.isOpen }
        check(openedAgain && fixture.circle.showMenuCalls == ran + 1 && S.pendingCount == 0,
              "B10 with every condition intact the same queued action runs (the menu opens through the element's own action)",
              "opened=\(openedAgain) showMenu=\(fixture.circle.showMenuCalls - ran)")
        if openedAgain, let open = try? await observe(nil) {
            let published = try? gate.publish(fingerprint: "", for: grant3, elements: open.elements, state: open)
            if let published, let observation = try? gate.beginAction(observationID: published.id.uuidString, fingerprint: "", for: grant3) {
                try? ComputerUseNative.postKeyToSelf(escape, observation: observation, grant: grant3, gate: gate)
                gate.endAction(observationID: observation.id, for: grant3)
            }
        }
        _ = await waitUntil(3) { !flag.isOpen }
        gate.stop()
    }

    /// B11（GPT-6 審查 #4）：合成事件照觀察時確定的視窗（編號＋視窗伺服器的位置大小）、用視窗伺服器座標；AX 查詢用 AX 座標。
    /// 真的送一次：用圖片座標對圓鈕右鍵（走 ComputerUsePointer.input 的事件路徑）→ 圓鈕的 rightMouseDown 收到、選單開；Esc 收。
    @MainActor static func eventGeometryChecks(_ check: Checker, _ fixture: Fixture, _ watchdog: Watchdog,
                                               observe: (CGWindowID?) async throws -> ComputerUseNative.State,
                                               gate: ComputerUseSession, flags: Flags) async {
        watchdog.enter("B11 event geometry", seconds: 30)
        let flag = fixture.log.flag
        guard let state = try? await observe(nil), let window = state.window,
              let circle = state.nodes.first(where: { $0.title == MenuCircle.label })?.frame else {
            return check(false, "B11 observable")
        }
        guard let geometry = try? state.eventGeometry() else { return check(false, "B11 the observation has an event geometry") }
        check(state.windowID == CGWindowID(fixture.window.windowNumber) && geometry.windowID == state.windowID
              && ComputerUseWindowPick.sameSize(geometry.serverFrame, state.frame),
              "B11 the observation carries the AX frame, the window server frame and the definite windowID (same size, both coordinate spaces)",
              "ax=\(state.frame) server=\(String(describing: state.serverFrame)) id=\(String(describing: state.windowID))")
        guard ComputerUseBackgroundEvents.available else {
            return check.skip("B11 真的送合成事件：這個環境沒有 SkyLight 的事件通道；純函式的座標對應在 C5 驗，主導實機驗")
        }
        let grant: ComputerUseSession.Grant
        do { grant = try gate.authorize(owner: UUID(), scope: "w184cu-b11", pid: getpid(), expectedEpoch: gate.currentEpoch) }
        catch { return check(false, "B11 grant", "\(error)") }
        defer { gate.stop() }
        // 圖片座標＝視窗內的點（imageWidth＝視窗寬：1 像素＝1 點）。
        let x = circle.midX - state.frame.minX, y = circle.midY - state.frame.minY
        let request = ComputerUsePointer.Request(kind: .rightClick, from: .point(x, y), to: nil, dx: 0, dy: 0)
        let rights = fixture.circle.rightDowns, openings = flag.openings
        let safety = Safety(fixture.menu, after: 15)
        defer { safety.cancel() }
        var failure = ""
        do {
            let published = try gate.publish(fingerprint: "", for: grant, imageWidth: Int(state.frame.width), imageHeight: Int(state.frame.height),
                                             elements: state.elements, state: state)
            let observation = try gate.beginAction(observationID: published.id.uuidString, fingerprint: "", for: grant)
            defer { gate.endAction(observationID: observation.id, for: grant) }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            try ComputerUsePointer.input(request, observation: observation, grant: grant, gate: gate, geometry: geometry,
                                         check: {}, element: { try observation.element(at: $0) },
                                         elementGeometry: { try ComputerUseNative.eventGeometry(for: $0, state: state, deadline: deadline) },
                                         deadline: deadline)
        } catch { failure = "\(error)" }
        _ = window
        // 合成右鍵開的選單有時很快自己關（第一輪探針的時序問題）：算「開過」，不等它一直開著。
        let opened = await waitUntil(2) { flag.openings > openings }
        check(failure.isEmpty && fixture.circle.rightDowns == rights + 1 && opened,
              "B11 a synthesized right-click by image coordinates goes to the observed window itself (geometry.target: windowID + server frame, no search) and reaches the circle: rightMouseDown received, the context menu opened",
              "error=\(failure) rightDowns=\(fixture.circle.rightDowns - rights) opened=\(opened)")
        if flag.isOpen {
            fixture.menu.cancelTracking()
            _ = await waitUntil(3) { !flag.isOpen }
        }
    }

    /// B12（GPT-6 審查 #3）：同一視窗兩個重疊、同角色同位置大小、動作不同的元件；還有別的視窗蓋在同一點上的同角色元件。
    /// 觀察拿到的是 B 的節點：直接叫的一定是 B（身分對得上、唯一）；A、B 身分完全一樣（對到兩個）＝退回 AX 路徑，
    /// AX 節點本來就是 B 的，還是 B；蓋在上面那個視窗的元件不算（只在原節點的視窗裡找）。
    @MainActor static func elementIdentityChecks(_ check: Checker, _ fixture: Fixture, _ watchdog: Watchdog,
                                                 gate: ComputerUseSession, flags: Flags) async {
        watchdog.enter("B12 element identity", seconds: 40)
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let rect = NSRect(x: visible.minX + 700, y: visible.maxY - 300, width: 240, height: 160)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "W184 CU 疊著的元件"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let logA = MenuLog(), logB = MenuLog()
        func menu(_ log: MenuLog, _ title: String) -> NSMenu {
            let menu = NSMenu(title: title); menu.delegate = log
            let item = NSMenuItem(title: title, action: #selector(MenuLog.pick(_:)), keyEquivalent: ""); item.target = log
            menu.addItem(item); return menu
        }
        let same = NSRect(x: 40, y: 60, width: 44, height: 44)
        let a = MenuCircle(frame: same), b = MenuCircle(frame: same)
        a.labelText = "元件 甲"; b.labelText = "元件 乙"
        a.popupMenu = menu(logA, "甲的選單"); b.popupMenu = menu(logB, "乙的選單")
        window.contentView?.addSubview(a)
        window.contentView?.addSubview(b)   // 乙在上面
        // 另一個視窗蓋在同一點上，裡面同角色同位置大小的元件（身分也跟乙一樣）。
        let cover = NSPanel(contentRect: rect, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        cover.title = "W184 CU 蓋著的視窗"
        cover.isReleasedWhenClosed = false
        cover.hidesOnDeactivate = false
        let logC = MenuLog()
        let c = MenuCircle(frame: same); c.labelText = "元件 乙"; c.popupMenu = menu(logC, "蓋著的選單")
        cover.contentView?.addSubview(c)
        cover.orderFrontRegardless()
        defer { cover.orderOut(nil) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        let running = NSRunningApplication.current
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        guard let state = try? ComputerUseNative.readState(running, deadline: deadline, includeTree: true,
                                                            preferredWindowID: CGWindowID(window.windowNumber)) else {
            return check(false, "B12 the window with two overlapping circles is observable")
        }
        let indexB = state.nodes.firstIndex { $0.title == "元件 乙" && $0.actions.contains("AXShowMenu") }
        let indexA = state.nodes.firstIndex { $0.title == "元件 甲" && $0.actions.contains("AXShowMenu") }
        guard let indexB, let indexA else {
            return check(false, "B12 both overlapping circles are in the tree", "\(state.nodes.map { "\($0.role) \($0.title)" })")
        }
        let grant: ComputerUseSession.Grant
        do { grant = try gate.authorize(owner: UUID(), scope: "w184cu-b12", pid: getpid(), expectedEpoch: gate.currentEpoch) }
        catch { return check(false, "B12 grant", "\(error)") }
        defer { gate.stop() }
        flags.reset()
        let auth = authority(grant, gate, flags)
        // 1. 對乙的節點：直接動作找到的是乙（不是甲、不是蓋著的視窗裡那個）。
        let directB = ComputerUseNative.selfDirectAction(state.elements[indexB], "AXShowMenu", pid: getpid(), deadline: deadline)
        let directA = ComputerUseNative.selfDirectAction(state.elements[indexA], "AXShowMenu", pid: getpid(), deadline: deadline)
        check(directB?.target === b && directB?.windowNumber == window.windowNumber && directA?.target === a,
              "B12 two overlapping same-role same-frame circles in one window (乙 on top of 甲) and a covering window with a look-alike: the direct action for 乙's AX node is 乙's own object, for 甲's node 甲's — never the other one, never the covering window's",
              "B→\(directB.map { $0.target === b ? "b" : $0.target === a ? "a" : $0.target === c ? "cover" : "?" } ?? "nil") A→\(directA.map { $0.target === a ? "a" : "?" } ?? "nil")")
        let safety = Safety(b.popupMenu!, after: 15)
        defer { safety.cancel() }
        if let directB {
            let showsB = b.showMenuCalls, showsA = a.showMenuCalls, showsC = c.showMenuCalls
            directB.schedule(authority: auth)
            let opened = await waitUntil(2) { logB.flag.isOpen }
            check(opened && b.showMenuCalls == showsB + 1 && a.showMenuCalls == showsA && c.showMenuCalls == showsC,
                  "B12 running it opens 乙's menu (甲's and the covering window's handlers untouched)",
                  "opened=\(opened) b=\(b.showMenuCalls - showsB) a=\(a.showMenuCalls - showsA) cover=\(c.showMenuCalls - showsC)")
            b.popupMenu?.cancelTracking()
            _ = await waitUntil(3) { !logB.flag.isOpen }
        }
        // 2. 甲、乙身分完全一樣（同標題）：對到兩個＝nil（退回 AX 路徑，節點本來就是乙的）。
        a.labelText = "元件 乙"
        guard let twinState = try? ComputerUseNative.readState(running, deadline: ProcessInfo.processInfo.systemUptime + 8, includeTree: true,
                                                                preferredWindowID: CGWindowID(window.windowNumber)) else {
            return check(false, "B12 twins observable")
        }
        let twins = twinState.nodes.enumerated().filter { $0.element.title == "元件 乙" && $0.element.actions.contains("AXShowMenu") }.map(\.offset)
        let ambiguous = twins.map { ComputerUseNative.selfDirectAction(twinState.elements[$0], "AXShowMenu", pid: getpid(), deadline: ProcessInfo.processInfo.systemUptime + 8) }
        check(twins.count == 2 && ambiguous.allSatisfy { $0 == nil },
              "B12 counterexample: when 甲 and 乙 are indistinguishable (same role, frame, title, identifier) the direct route resolves to nothing — no guess; the AX path (which holds 乙's own node) is used instead",
              "twins=\(twins.count) resolved=\(ambiguous.map { $0 != nil })")
        // 3. 執行前元件不見了（從視窗拿掉）＝作廢。
        a.labelText = "元件 甲"
        if let directB {
            let shows = b.showMenuCalls
            b.removeFromSuperview()
            directB.schedule(authority: auth)
            for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); await Task.yield() }
            check(b.showMenuCalls == shows && !logB.flag.isOpen && ComputerUseNative.SelfSchedule.pendingCount == 0,
                  "B12 counterexample: the element left the window before the queued action ran = voided (re-resolved at run time, must be the same object)",
                  "shows=\(b.showMenuCalls - shows) open=\(logB.flag.isOpen)")
        }
    }

    /// B9 跟私訊框頁面圓鈕同一種的 SwiftUI 圓鈕（.accessibilityAction(.showMenu)）：正式的 input 找到 SwiftUI 的 AccessibilityNode、
    /// 直接叫它的顯示選單；選單開著時觀察回得來、讀得到項目；Esc 收起。
    @MainActor static func swiftUIMenuChecks(_ check: Checker, _ fixture: Fixture, _ watchdog: Watchdog,
                                             observe: (CGWindowID?) async throws -> ComputerUseNative.State,
                                             act: (ComputerUseNative.Request, ComputerUseNative.State) async throws -> ComputerUseNative.BackgroundOutcome,
                                             escape: ComputerUseNative.Key) async {
        watchdog.enter("B9 SwiftUI circle", seconds: 30)
        let flag = fixture.log.flag
        let anchor = SwiftUIAnchor()
        let panel = NSPanel(contentRect: NSRect(x: fixture.window.frame.maxX + 40, y: fixture.window.frame.minY, width: 200, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: SwiftUICircle(anchor: anchor, menu: fixture.menu))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        let panelID = CGWindowID(panel.windowNumber)
        let safety = Safety(fixture.menu, after: 20)
        defer { safety.cancel() }
        let state = try? await observe(panelID)
        let index = state?.nodes.firstIndex { $0.title == SwiftUICircle.label && $0.actions.contains("AXShowMenu") }
        guard let state, let index, state.windowID == panelID else {
            return check(false, "B9 the SwiftUI circle (like the DM page circle) is observable with AXShowMenu",
                         "windowID=\(String(describing: state?.windowID)) expected=\(panelID) nodes=\(state?.nodes.map { "\($0.role) \($0.title)" } ?? [])")
        }
        var failure = ""
        do { _ = try await act(.axAction(index, "AXShowMenu"), state) } catch { failure = "\(error)" }
        let opened = await waitUntil(2) { flag.isOpen }
        let inFlight = ComputerUseNative.SelfAction.inFlight
        let probe = await probeWhileOpen(flag, timeout: 1.0)
        let during = try? await observe(panelID)
        let items = (during?.nodes ?? []).filter { $0.inOpenMenu && $0.role == "AXMenuItem" }.map(\.title)
        check(opened && failure.isEmpty && anchor.showMenuCalls == 1 && !inFlight && probe.allRan && during?.busy == false
              && ["甲", "乙", "丙"].allSatisfy { items.contains($0) },
              "B9 SwiftUI circle with .accessibilityAction(.showMenu), the DM page circle's shape: perform_ax_action AXShowMenu finds its AccessibilityNode in-process and calls it directly; while the menu is open bridge-style work runs and observing lists 甲 乙 丙",
              "opened=\(opened) error=\(failure) handler=\(anchor.showMenuCalls) inFlight=\(inFlight) \(probe) busy=\(String(describing: during?.busy)) items=\(items)")
        failure = ""
        if let during { do { _ = try await act(.pressKey(escape), during) } catch { failure = "\(error)" } }
        let closed = await waitUntil(3) { !flag.isOpen }
        check(closed && failure.isEmpty && !safety.fired,
              "B9 press_key escape closes the SwiftUI circle's menu", "closed=\(closed) error=\(failure) safetyFired=\(safety.fired)")
    }

    /// B13（GPT-6 複核 #4）：主視窗＋獨立的選單視窗。選單項目用元素編號、走合成事件時，事件送到選單自己的視窗（不是觀察的視窗）、
    /// 座標是選單視窗內的；_AXUIElementGetWindow 對選單項目回的是叫出它的視窗（所以不能拿它當事件目標）。拖曳跨視窗＝拒絕、
    /// 一個事件都不送。按鍵的 believer（Controller 按鍵那一處）：照視窗自己的編號；私有 API 失效＝拒絕（不退回用點找）。
    @MainActor static func menuEventTargetChecks(_ check: Checker, _ fixture: Fixture, _ watchdog: Watchdog,
                                                 observe: (CGWindowID?) async throws -> ComputerUseNative.State,
                                                 gate: ComputerUseSession) async {
        watchdog.enter("B13 menu event target", seconds: 40)
        let flag = fixture.log.flag
        guard ComputerUseBackgroundEvents.available else {
            return check.skip("B13 選單的合成事件：這個環境沒有 SkyLight 的事件通道；純函式的選單對應在 C6 驗，主導實機驗")
        }
        let fixtureID = CGWindowID(fixture.window.windowNumber)
        if let plain = try? await observe(nil), let window = plain.window {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            let believer = try? ComputerUseNative.eventTarget(forWindow: window, pid: getpid(), deadline: deadline)
            ComputerUseSelfTestHooks.windowIDUnavailable = true
            var refused = ""
            do { _ = try ComputerUseNative.eventTarget(forWindow: window, pid: getpid(), deadline: deadline); refused = "resolved" }
            catch let failure as ComputerUseFailure { refused = failure.code } catch { refused = "\(error)" }
            ComputerUseSelfTestHooks.windowIDUnavailable = false
            check(believer?.windowID == fixtureID && believer?.windowBounds == plain.serverFrame && refused == ComputerUseNative.eventTargetUnresolved,
                  "B13 counterexample (GPT-6 re-check #4, the key path): the believer window is resolved by its own window number and window-server frame; with the window-ID API failing it is refused (computer_event_target_unresolved), no point search",
                  "believer=\(String(describing: believer?.windowID)) expected=\(fixtureID) refused=\(refused)")
        } else {
            check(false, "B13 the fixture window is observable")
        }
        // 開一個獨立的選單視窗（跟 A2 同一條：run loop 區塊裡 popUp）。
        let safety = Safety(fixture.menu, after: 25)
        defer { safety.cancel() }
        let pickedBefore = fixture.log.picked.count
        ComputerUseNative.performOnMainRunLoop { _ = fixture.circle.accessibilityPerformShowMenu() }
        let opened = await waitUntil(2) { flag.isOpen }
        var observed: ComputerUseNative.State?
        if opened { observed = try? await observe(nil) }
        guard let state = observed,
              let index = state.nodes.indices.first(where: { state.nodes[$0].inOpenMenu && state.nodes[$0].role == "AXMenuItem" && state.nodes[$0].title == "乙" }),
              let itemFrame = state.nodes[index].frame else {
            if flag.isOpen { fixture.menu.cancelTracking() }
            return check(false, "B13 the open menu's item 乙 is observable", "open=\(flag.isOpen)")
        }
        let item = state.elements[index]
        let menus = ComputerUseWindowPick.popUpMenuWindows(pid: getpid())
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let resolved = try? ComputerUseNative.eventGeometry(for: item, state: state, deadline: deadline)
        let naive = ComputerUseNative.windowID(of: item)
        let observedTarget = try? state.eventGeometry()
        check(menus.count == 1 && resolved?.windowID == menus.first?.0 && resolved?.serverFrame == menus.first?.1
              && resolved?.windowID != fixtureID && observedTarget?.windowID == fixtureID && naive == fixtureID,
              "B13 counterexample (GPT-6 re-check #4): a menu item's event window is the menu's own pop-up window (frame equal to the AXMenu), not the observed window the second round sent it to, and not what _AXUIElementGetWindow says for the item (the window that opened the menu)",
              "resolved=\(String(describing: resolved?.windowID)) menus=\(menus.map(\.0)) observed=\(String(describing: observedTarget?.windowID)) naive=\(String(describing: naive)) fixture=\(fixtureID)")
        guard let grant = try? gate.authorize(owner: UUID(), scope: "w184cu-b13", pid: getpid(), expectedEpoch: gate.currentEpoch) else {
            fixture.menu.cancelTracking()
            return check(false, "B13 grant")
        }
        defer { gate.stop() }
        /// 正式的 ComputerUsePointer.input（合成事件那條），記下每一筆事件送去哪個視窗、視窗內哪一點。
        func send(_ request: ComputerUsePointer.Request) -> (records: [ComputerUseSelfTestHooks.EventRecord], failure: String) {
            var failure = ""
            ComputerUseSelfTestHooks.startRecording()
            do {
                let published = try gate.publish(fingerprint: "", for: grant, imageWidth: Int(state.frame.width), imageHeight: Int(state.frame.height),
                                                 elements: state.elements, state: state)
                let observation = try gate.beginAction(observationID: published.id.uuidString, fingerprint: "", for: grant)
                defer { gate.endAction(observationID: observation.id, for: grant) }
                try ComputerUsePointer.input(request, observation: observation, grant: grant, gate: gate, geometry: try state.eventGeometry(),
                                             check: {}, element: { try observation.element(at: $0) },
                                             elementGeometry: { try ComputerUseNative.eventGeometry(for: $0, state: state, deadline: deadline) },
                                             deadline: deadline)
            } catch let error as ComputerUseFailure { failure = error.code } catch { failure = "\(error)" }
            return (ComputerUseSelfTestHooks.stopRecording(), failure)
        }
        // 跨視窗拖曳（選單項目 → 觀察視窗裡的點）：拒絕，一個事件都沒送。
        let drag = send(.init(kind: .drag, from: .element(index), to: .point(20, 20), dx: 0, dy: 0))
        check(drag.failure == ComputerUseNative.eventTargetUnresolved && drag.records.isEmpty,
              "B13 counterexample: a drag from the menu item into the observed window spans two windows = refused before any event (computer_event_target_unresolved)",
              "failure=\(drag.failure) records=\(drag.records.count)")
        let click = send(.init(kind: .click, from: .element(index), to: nil, dx: 0, dy: 0))
        let mice = click.records.filter { $0.type == 1 || $0.type == 2 }
        let menuSize = menus.first?.1.size ?? .zero
        let expected = CGPoint(x: itemFrame.midX - (resolved?.axFrame.minX ?? 0), y: itemFrame.midY - (resolved?.axFrame.minY ?? 0))
        let landed = mice.map(\.local).allSatisfy { point in
            guard let local = point else { return false }
            return abs(local.x - expected.x) < 1 && abs(local.y - expected.y) < 1 && CGRect(origin: .zero, size: menuSize).contains(local)
        }
        check(click.failure.isEmpty && mice.count == 2 && !click.records.isEmpty && click.records.allSatisfy { $0.windowID == menus.first?.0 } && landed,
              "B13 the production pointer path sends the click on menu item 乙 (by element) to the menu's own window, at the item's point inside that window (window-local = server point − menu window origin) — no record goes to the observed window",
              "failure=\(click.failure) records=\(click.records.map { "\($0.windowID)/\($0.type)" }) localPoints=\(click.records.map(\.local)) menu=\(String(describing: menus.first?.0)) expected=\(expected)")
        let closedByClick = await waitUntil(1.5) { !flag.isOpen }
        let picked = Array(fixture.log.picked.dropFirst(pickedBefore))
        check(closedByClick && picked == ["乙"],
              "B13 the receiver is the menu: that synthesized click (sent to the menu's own window) picks 乙 and closes the menu",
              "closed=\(closedByClick) picked=\(picked)")
        if flag.isOpen {
            fixture.menu.cancelTracking()
            _ = await waitUntil(3) { !flag.isOpen }
        }
    }

    // MARK: - C 挑視窗

    /// 純資料的規則：「可以用」是每一條分支的前置條件；擋擷取三態（讀不到＝受保護）、自家的 WindowCaptureShield 強制否決；
    /// 沒有 AX 視窗編號＝一律拒絕（第三輪：不再用位置大小、標題、前後順序猜）；輸出過濾（受保護、讀不到的只有 windowID＋protected）。
    @MainActor static func windowPickRuleChecks(_ check: Checker) {
        typealias P = ComputerUseWindowPick
        let frame = CGRect(x: 650, y: 380, width: 926, height: 662)
        /// protected＝視窗伺服器說擋擷取；server／shield 可以直接給三態。
        func candidate(_ id: CGWindowID, _ title: String, _ rect: CGRect = frame, onScreen: Bool = true, alpha: Double = 1,
                       visible: Bool? = nil, ignores: Bool? = nil, protected: Bool = false, layer: Int = 0,
                       server: P.Protection? = nil, shield: P.Protection? = nil) -> P.Candidate {
            P.Candidate(windowID: id, title: title, frame: rect,
                        facts: P.Facts(onScreen: onScreen, alpha: alpha, layer: layer, server: server ?? (protected ? .protected : .shareable),
                                       shield: shield, appKitVisible: visible, appKitAlpha: nil, ignoresMouse: ignores))
        }
        func reason(_ outcome: P.Outcome) -> String {
            if case .unresolved(let reason, _) = outcome { return reason }
            return "\(outcome)"
        }
        func payload(_ code: String) -> [String: Any] {
            code.split(separator: ":", maxSplits: 1).last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        }
        // 三態（GPT-6 複核 #1）：kCGWindowSharingState 缺、不是整數、不認得＝unknown；unknown 跟 protected 一樣不可以用、不給標題。
        let states: [(Any?, P.Protection)] = [(0, .protected), (1, .shareable), (2, .shareable), (NSNumber(value: 0), .protected),
                                              (nil, .unknown), (NSNull(), .unknown), ("0", .unknown), (true, .unknown), (7, .unknown), (0.5, .unknown)]
        let mapped = states.map { P.protection(sharingState: $0.0) }
        check(mapped == states.map(\.1),
              "C0 counterexample (GPT-6 re-check #1): the window server's sharing state is three-valued — 0 protected, 1/2 shareable, missing / NSNull / a string / a bool / an unknown number = unknown (never read as shareable)",
              "\(mapped)")
        let unknownFacts = P.Facts(onScreen: true, alpha: 1, layer: 0, server: .unknown)
        let defaultFacts = P.Facts(onScreen: true, alpha: 1, layer: 0)
        let shieldHeld = P.Facts(onScreen: true, alpha: 1, layer: 0, server: .shareable, shield: .protected)
        let shieldUnknown = P.Facts(onScreen: true, alpha: 1, layer: 0, server: .shareable, shield: .unknown)
        let open = P.Facts(onScreen: true, alpha: 1, layer: 0, server: .shareable, shield: .shareable)
        check(!unknownFacts.usable && unknownFacts.captureProtected && !unknownFacts.disclosable
              && !defaultFacts.usable && defaultFacts.server == .unknown
              && !shieldHeld.usable && !shieldHeld.disclosable && !shieldUnknown.usable && !shieldUnknown.disclosable
              && open.usable && open.disclosable,
              "C0 counterexample: unknown protection is refused and masked (a Facts built without a server state defaults to unknown); our own window held by WindowCaptureShield (held or lingering) is vetoed even when the window server says shareable, and so is one whose shield state could not be asked (off the main thread)",
              "unknown=\(unknownFacts.usable) default=\(defaultFacts.server) shield=\(shieldHeld.usable) shieldUnknown=\(shieldUnknown.usable) open=\(open.usable)")
        // 09-30 mini 的樣子：主視窗、停靠的私訊框（同位置還有收起來的外殼、alpha 0 的輔助視窗）、Island、擋擷取的授權頁視窗。
        let main = candidate(10, "TATWO OS", CGRect(x: 350, y: 110, width: 1220, height: 970))
        let box = candidate(11, "私訊")
        let shell = candidate(12, "私訊", onScreen: false)
        let clear = candidate(13, "私訊", alpha: 0)
        let pointer = candidate(14, "私訊", ignores: true, layer: 25)
        let island = candidate(15, "", CGRect(x: 614, y: 0, width: 692, height: 172), layer: 27)
        let shielded = candidate(17, "配對碼 TATWO-1234", protected: true)
        let unknown = candidate(18, "未知狀態 U-5M", server: .unknown)
        let held = candidate(19, "持有中 H-3K", shield: .protected)
        let all = [main, shell, clear, pointer, box, island, shielded, unknown, held]
        check(P.choose(all, focusedID: 11, focusedFrame: frame) == .window(11, rule: "same_window"),
              "C1 when the AX window's own number is known and that window is usable it is exactly that window (identity, never geometry)")
        // 知道編號不是例外——編號指到的視窗看不見、不接滑鼠、擋擷取、讀不到狀態、被 shield 擋＝拒絕，不改拿別的。
        let notUsable: [(CGWindowID, String)] = [(12, "ordered out"), (13, "alpha 0"), (14, "mouse-transparent overlay"), (17, "capture-protected"),
                                                 (18, "protection unknown"), (19, "held by WindowCaptureShield")]
        let observedRefused = notUsable.map { reason(P.choose(all, focusedID: $0.0, focusedFrame: frame)) }
        let requestedRefused = notUsable.map { reason(P.choose(all, focusedID: $0.0, focusedFrame: frame, requested: $0.0)) }
        check(observedRefused.allSatisfy { $0 == "observed_window_not_usable" } && requestedRefused.allSatisfy { $0 == "requested_window_not_usable" },
              "C1 counterexample (GPT-6 #1): a known windowID or an agent-requested windowID that is ordered out / alpha 0 / mouse-transparent / capture-protected / of unknown protection / held by WindowCaptureShield is refused on every branch — usable is the common precondition, knowing the ID is no exception",
              "observed=\(observedRefused) requested=\(requestedRefused) for \(notUsable.map(\.1))")
        // GPT-6 審查 #5／複核 #3 的反例：沒有 AX 視窗編號（私有 API 拿不到）時，什麼都不挑——同位置只有一個可以用的、標題一樣的、
        // 最前面的都不算；指定的也拒絕。
        let noIDObserved = reason(P.choose(all, focusedID: nil, focusedFrame: frame))
        let noIDOnlyOne = reason(P.choose([box], focusedID: nil, focusedFrame: frame))
        let noIDRequested = reason(P.choose(all, focusedID: nil, focusedFrame: frame, requested: 11))
        check(noIDObserved == "observed_window_unverifiable_without_ax_window_id" && noIDOnlyOne == "observed_window_unverifiable_without_ax_window_id"
              && noIDRequested == "requested_window_unverifiable_without_ax_window_id",
              "C1 counterexample (GPT-6 #5, re-check #3): with no AX window number nothing is picked — not the only usable window on that frame, not a title match, not the frontmost; an agent-requested windowID is refused too — geometry equality is never identity",
              "observed=\(noIDObserved) onlyOne=\(noIDOnlyOne) requested=\(noIDRequested)")
        check(P.choose(all, focusedID: 11, focusedFrame: frame, requested: 11) == .window(11, rule: "requested"),
              "C1 the agent's windowID picks that window when it is the observed one and usable")
        check(reason(P.choose(all, focusedID: 11, focusedFrame: frame, requested: 10)) == "requested_window_is_not_the_observed_window",
              "C1 a windowID that is not the observed window is refused (the screenshot must match the AX tree)")
        check(reason(P.choose([main, box], focusedID: 99, focusedFrame: frame)) == "observed_window_not_capturable",
              "C1 the AX window's number is known but ScreenCaptureKit does not list it: say so, never capture another window with the same frame")
        // 錯誤附候選（統一的輸出過濾）：受保護、讀不到狀態、shield 擋著的只有 windowID 與 protected（沒有標題、位置、大小）。
        let stuck = P.choose(all, focusedID: 12, focusedFrame: frame)
        var listed: [P.Candidate] = []
        if case .unresolved(_, let list) = stuck { listed = list }
        let code = P.failureCode(reason: reason(stuck), candidates: listed, focusedTitle: "私訊", focusedFrame: frame, focusedID: 12,
                                 focusedFacts: shell.facts)
        let rows = payload(code)["candidates"] as? [[String: Any]] ?? []
        let masked = [17, 18, 19].map { id in rows.first { ($0["windowID"] as? Int) == id }.map { Set($0.keys) } }
        let boxRow = rows.first { ($0["windowID"] as? Int) == 11 }
        check(code.hasPrefix("computer_window_not_uniquely_identified:") && Set(listed.map(\.windowID)).isSuperset(of: [11, 12, 13, 14, 17, 18, 19])
              && masked.allSatisfy { $0 == ["windowID", "protected"] }
              && !code.contains("配對碼") && !code.contains("U-5M") && !code.contains("H-3K")
              && boxRow?["title"] as? String == "私訊" && boxRow?["size"] as? String == "926x662"
              && (payload(code)["next"] as? String)?.contains("windowID") == true,
              "C1 the candidate list names windowID, title, size, position and visibility for shareable windows; capture-protected, unknown-state and shield-held candidates get only windowID + protected (their titles never leave the process)",
              code)
        let observedCodes = [(shielded, "配對碼"), (unknown, "U-5M"), (held, "H-3K")].map { item, secret in
            (P.failureCode(reason: "observed_window_not_usable", candidates: [item], focusedTitle: item.title, focusedFrame: frame,
                           focusedID: item.windowID, focusedFacts: item.facts), secret)
        }
        let noID = P.failureCode(reason: "observed_window_unverifiable_without_ax_window_id", candidates: [], focusedTitle: "無編號 N-2P",
                                 focusedFrame: frame, focusedID: nil, focusedFacts: box.facts)
        check(observedCodes.allSatisfy { code, secret in
                  let observed = payload(code)["observedWindow"] as? [String: Any] ?? [:]
                  return observed["title"] == nil && observed["x"] == nil && (observed["protected"] as? Bool) == true && !code.contains(secret)
              } && (payload(noID)["observedWindow"] as? [String: Any])?["title"] == nil && !noID.contains("N-2P"),
              "C1 when the observed window itself is protected / of unknown state / shield-held — or has no window number at all — the error carries no title or position for it either",
              observedCodes.map(\.0).joined(separator: " | ") + " | " + noID)
        let resized = candidate(11, "私訊", CGRect(x: frame.minX, y: frame.minY, width: frame.width + 30, height: frame.height))
        check(P.choose([resized], focusedID: 11, focusedFrame: frame) == .moving,
              "C1 same window but a different size (resizing right now) = window changed during capture (retried), not a wrong capture")
        // 09-30 mini 實機重播（唯讀讀到的：AX 與視窗伺服器的位置差 1020，大小一樣；12 個 TATWO 視窗照原樣）。
        let mini: [P.Candidate] = [
            candidate(59636, "", CGRect(x: 1514, y: 966, width: 44, height: 44), onScreen: false),
            candidate(59634, "私訊", CGRect(x: 650, y: 1247, width: 926, height: 662)),
            candidate(59633, "", CGRect(x: -30000, y: 30280, width: 1100, height: 800), onScreen: false),
            candidate(59625, "", CGRect(x: 1496, y: 948, width: 80, height: 80), onScreen: false),
            candidate(59624, "Tatwo Ultrawork OS", CGRect(x: 350, y: 1068, width: 1220, height: 970)),
            candidate(59623, "", CGRect(x: 614, y: 0, width: 692, height: 172), layer: 27),
            candidate(59622, "", CGRect(x: 0, y: 0, width: 1920, height: 30), onScreen: false),
            candidate(59620, "", CGRect(x: 0, y: 0, width: 1920, height: 30), onScreen: false),
            candidate(59619, "", CGRect(x: 0, y: 0, width: 1920, height: 30), onScreen: false),
            candidate(59627, "", CGRect(x: 131, y: 583, width: 280, height: 84), onScreen: false, layer: 25),
            candidate(59621, "", CGRect(x: 0, y: 0, width: 1920, height: 30), onScreen: false),
            candidate(59626, "", CGRect(x: 0, y: 580, width: 500, height: 500), onScreen: false)]
        let miniOrder: [CGWindowID] = [59623, 59634, 59624]
        let axBox = CGRect(x: 650, y: 227, width: 926, height: 662), axMain = CGRect(x: 350, y: 48, width: 1220, height: 970)
        /// 舊規則（.032）：同位置大小 → 標題 → 螢幕上的前後順序；nil＝computer_window_not_uniquely_identified。
        func oldRule(_ all: [P.Candidate], _ frame: CGRect, _ title: String) -> CGWindowID? {
            let matches = all.filter { ComputerUseNative.sameFrame($0.frame, frame) }
            let titled = matches.filter { $0.title == title }
            let pool = titled.isEmpty ? matches : titled
            let frontmost = miniOrder.lazy.compactMap { id in pool.first { $0.windowID == id } }.first
            return matches.count == 1 ? matches.first?.windowID : (titled.count == 1 ? titled.first?.windowID : frontmost?.windowID)
        }
        check(oldRule(mini, axBox, "私訊") == nil && oldRule(mini, axMain, "Tatwo Ultrawork OS") == nil,
              "C1 counterexample, 09-30 mini replay: the old rule (same position and size, then title, then front-to-back) finds nothing for either TATWO window — AX and the window server place them 1020 apart — so every observe said computer_window_not_uniquely_identified")
        check(P.choose(mini, focusedID: 59634, focusedFrame: axBox) == .window(59634, rule: "same_window")
              && P.choose(mini, focusedID: 59624, focusedFrame: axMain) == .window(59624, rule: "same_window")
              && reason(P.choose(mini, focusedID: nil, focusedFrame: axBox)) == "observed_window_unverifiable_without_ax_window_id",
              "C1 09-30 mini replay: the new rule picks the DM box and the main window by their own window number (size only — the position may be in another coordinate space); without the number it refuses (no size-only guess any more)",
              "\(P.choose(mini, focusedID: nil, focusedFrame: axBox))")
        // C2 AX 這邊讀哪一個（代理沒指定時）：焦點 → 主視窗 → 其他，第一個可以用的；碰到確認不了的（沒有編號）＝拒絕，不跳過它。
        let status: [String: P.AXStatus] = ["box": .usable, "main": .usable, "helper": .unusable, "shell": .unusable, "x": .unusable,
                                            "unmapped": .unverifiable]
        func pick(_ focused: String?, _ main: String?, _ all: [String]) -> String {
            switch P.axWindow(focused: focused, main: main, all: all, status: { status[$0] ?? .unverifiable }) {
            case .window(let name): return name
            case .none: return "none"
            case .unverifiable: return "unverifiable"
            }
        }
        let picks = [pick("box", "main", ["x", "box", "main"]), pick("x", "main", ["x", "main"]), pick(nil, nil, ["helper", "box", "main"]),
                     pick(nil, nil, ["helper", "shell"]), pick("unmapped", "main", ["main"]), pick("helper", "unmapped", ["box"]),
                     pick(nil, nil, ["helper", "unmapped", "box"])]
        check(picks == ["box", "main", "box", "none", "unverifiable", "unverifiable", "unverifiable"],
              "C2 the AX side reads the focused / main window if usable → the first usable one → none; a window with no window number on the way is refused (unverifiable), never skipped over or treated as usable (counterexample: an invisible helper is never read just because it is first or focused)",
              "\(picks)")
        // C5（GPT-6 審查 #4）：兩套座標。AX 查詢用 AX 座標，事件用視窗伺服器座標；事件的視窗照確定的編號。
        let geometry = ComputerUseNative.EventGeometry(pid: getpid(), axFrame: axBox, serverFrame: CGRect(x: 650, y: 1247, width: 926, height: 662), windowID: 59634)
        let axClick = try? ComputerUsePointer.screenPoint(x: 100, y: 50, imageWidth: 926, imageHeight: 662, frame: axBox)
        let serverClick = axClick.map(geometry.serverPoint)
        let axDragEnd = try? ComputerUsePointer.screenPoint(x: 100, y: 500, imageWidth: 926, imageHeight: 662, frame: axBox)
        let serverDragEnd = axDragEnd.map(geometry.serverPoint)
        check(axClick == CGPoint(x: 750, y: 277) && serverClick == CGPoint(x: 750, y: 1297)
              && axDragEnd == CGPoint(x: 750, y: 727) && serverDragEnd == CGPoint(x: 750, y: 1747),
              "C5 09-30 mini replay (1020 apart): an image point maps to the AX point for AX queries and to the window-server point for events (pure translation, same size)",
              "click ax=\(String(describing: axClick)) server=\(String(describing: serverClick)) drag ax=\(String(describing: axDragEnd)) server=\(String(describing: serverDragEnd))")
        // 反例：舊做法拿 AX 座標的點去視窗伺服器清單裡找視窗（第二輪以前的 windowContaining，這裡照抄當反例）——私訊框的點
        // 什麼都找不到；主視窗裡往下拖到 AX (450,700) 就落進不在螢幕上的 500×500 輔助視窗（59626）。新做法：編號直接指定。
        func oldSearch(_ point: CGPoint) -> Int? {
            mini.first { $0.frame.contains(point) }.map { Int($0.windowID) }
        }
        let oldClick = oldSearch(axClick ?? .zero)
        let oldDragEnd = oldSearch(CGPoint(x: 450, y: 700))
        let direct = ComputerUseBackgroundEvents.available ? try? geometry.target() : nil
        let directOK = !ComputerUseBackgroundEvents.available || (direct?.windowID == 59634 && direct?.windowBounds == geometry.serverFrame)
        check(oldClick != 59634 && oldDragEnd == 59626 && directOK,
              "C5 counterexample: searching the window list with the AX point finds no window for the click and sends a drag end (AX 450,700 inside the main window) into the off-screen 500×500 helper window 59626; the event target is windowID 59634 with the server frame, no search",
              "oldClick=\(String(describing: oldClick)) oldDragEnd=\(String(describing: oldDragEnd)) direct=\(String(describing: direct?.windowID))")
        // 沒有編號（或視窗伺服器的位置大小）就沒有事件目標：拒絕，不退回用點找。
        var noWindow = ComputerUseNative.State(pid: getpid(), appName: "", bundleIdentifier: nil, launchDate: nil, window: nil, frame: axBox,
                                               title: "", windows: [], elements: [], nodes: [], truncated: false)
        var refusals: [String] = []
        for (id, server) in [(nil, nil), (59634, nil), (nil, CGRect(x: 650, y: 1247, width: 926, height: 662))] as [(CGWindowID?, CGRect?)] {
            noWindow.windowID = id
            noWindow.serverFrame = server
            do { _ = try noWindow.eventGeometry(); refusals.append("resolved") }
            catch let failure as ComputerUseFailure { refusals.append(failure.code) }
            catch { refusals.append("\(error)") }
        }
        check(refusals.allSatisfy { $0 == ComputerUseNative.eventTargetUnresolved },
              "C5 counterexample (GPT-6 re-check #4): an observation without its window number or window-server frame has no event target at all (computer_event_target_unresolved) — the old point search is gone",
              "\(refusals)")
        // C6（GPT-6 複核 #4，:1494）：開著的選單。選單視窗的位置是視窗伺服器座標；hit test 要 AX 座標；AXMenu 平移回去要跟選單視窗
        // 一模一樣才算；_AXUIElementGetWindow 對選單回的是叫出它的視窗，所以選單的事件目標用「選單層級的視窗＋位置大小」確認（剛好一個）。
        let offset = CGVector(dx: 0, dy: 1020)
        let axMenu = CGRect(x: 124, y: 659, width: 45, height: 82)
        let menuServer = CGRect(x: 124, y: 1679, width: 45, height: 82)
        let probes = ComputerUseNative.menuProbePoints(serverBounds: menuServer, offset: offset)
        let oldProbe = CGPoint(x: menuServer.midX, y: menuServer.minY + 12)   // 第二輪以前：直接拿視窗伺服器座標去 hit test
        let decoy = CGRect(x: 124, y: 659, width: 45, height: 82)   // 別的選單視窗剛好在 AX 那個位置（沒平移）
        let resolvedMenu = P.menuWindow(axMenuFrame: axMenu, offset: offset, windows: [(701, decoy), (700, menuServer)])
        let twins = P.menuWindow(axMenuFrame: axMenu, offset: offset, windows: [(700, menuServer), (702, menuServer)])
        let wrongSize = P.menuWindow(axMenuFrame: axMenu, offset: offset, windows: [(700, CGRect(x: 124, y: 1679, width: 45, height: 90))])
        check(probes.allSatisfy { axMenu.contains($0) } && !axMenu.contains(oldProbe)
              && resolvedMenu?.0 == 700 && twins == nil && wrongSize == nil,
              "C6 counterexample (GPT-6 re-check #4, 1020 apart): the open-menu probe points are converted to AX coordinates (inside the AXMenu; the old server-coordinate probe misses it); the menu's event window is the one pop-up window whose frame equals the AXMenu shifted by the offset — a same-size decoy at the untranslated place does not count, two matches or a size mismatch = none",
              "probes=\(probes) old=\(oldProbe) resolved=\(String(describing: resolvedMenu?.0)) twins=\(String(describing: twins?.0)) wrongSize=\(String(describing: wrongSize?.0))")
    }

    /// 真的自家視窗：同位置大小的一般視窗、alpha 0、收起來的、不接滑鼠的浮層、擋擷取的、WindowCaptureShield 持有的；
    /// 指定到不可以用的、不在樹裡的＝readState 拒絕附候選；控制器的 observe 整段（成功回應的輸出過濾、讀不到狀態、私有 API 失效）。
    @MainActor static func realWindowChecks(_ check: Checker, screen: NSScreen) async {
        typealias P = ComputerUseWindowPick
        let visible = screen.visibleFrame
        let rect = NSRect(x: visible.minX + 420, y: visible.maxY - 320, width: 240, height: 160)
        func make(_ title: String, _ alpha: CGFloat, ordered: Bool, ignores: Bool = false, protected: Bool = false) -> NSWindow {
            // 同一種樣式（有標題列的小面板）：六個視窗的位置大小一模一樣。
            let window = NSPanel(contentRect: rect, styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false   // 面板預設 App 不在前景就收起來：自測這個 App 不在前景
            window.alphaValue = alpha
            window.ignoresMouseEvents = ignores
            window.backgroundColor = .windowBackgroundColor
            if protected { window.sharingType = .none }
            if ordered { window.orderFrontRegardless() }
            return window
        }
        // 標題各不一樣：受保護、shield 持有的標題是「秘密」，完整回應裡一個字都不能出現。
        let normalTitle = "W184 CU 一般 A-1R", clearTitle = "W184 CU alpha0 U-5M"
        let protectedSecret = "W184 CU 受保護 B-7Q", heldSecret = "W184 CU 持有 H-3K"
        let normal = make(normalTitle, 1, ordered: true)
        let clear = make(clearTitle, 0, ordered: true)
        let hidden = make("W184 CU 收起", 1, ordered: false)
        let overlay = make("W184 CU 浮層", 1, ordered: true, ignores: true)
        let protected = make(protectedSecret, 1, ordered: true, protected: true)
        let heldWindow = make(heldSecret, 1, ordered: true)
        let holder = NSObject()
        WindowCaptureShield.shared.hold(holder, window: heldWindow)
        // 有人把 sharingType 改回來（視窗伺服器說可以分享）：WindowCaptureShield 還持有＝照樣受保護（強制否決）。
        heldWindow.sharingType = .readOnly
        defer {
            WindowCaptureShield.shared.release(holder)
            for window in [normal, clear, hidden, overlay, protected, heldWindow] { window.orderOut(nil) }
        }
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        let windows = [normal, clear, hidden, overlay, protected, heldWindow]
        let ids = windows.map { CGWindowID($0.windowNumber) }
        let facts = P.facts(pid: getpid())
        let f = ids.map { facts[$0] }
        check(f[0]?.usable == true && f[0]?.server == .shareable && f[0]?.shield == .shareable
              && f[1]?.visible == false && f[2]?.onScreen == false && f[2]?.visible == false
              && f[3]?.visible == true && f[3]?.usable == false && f[3]?.ignoresMouse == true,
              "C3 real windows: the window server and AppKit facts — normal usable (window server shareable, no shield); alpha 0 not visible; ordered out not on screen; the mouse-transparent overlay visible but not operable",
              ids.enumerated().map { "\($0.element): \(String(describing: f[$0.offset]))" }.joined(separator: " | "))
        // 環境能力跟待測結果分開：受保護的 fixture 是這裡自己建的（sharingType .none）——被判成可以用就是 FAIL，不 SKIP。
        check(f[4]?.server == .protected && f[4]?.captureProtected == true && f[4]?.usable == false,
              "C3 counterexample: a window this test made capture-protected (sharingType none: pairing code, authorization page) is protected by the window server's own state and not usable — a regression here fails, it is never skipped",
              String(describing: f[4]))
        check(f[5]?.server == .shareable && f[5]?.shield == .protected && f[5]?.captureProtected == true && f[5]?.usable == false,
              "C3 counterexample (GPT-6 re-check #1): WindowCaptureShield still holds a window whose sharingType someone reset (the window server says shareable) — the shield vetoes it: protected, not usable",
              String(describing: f[5]))
        let candidates = P.candidates(pid: getpid()).filter { ids.contains($0.windowID) }
        let frame = candidates.first { $0.windowID == ids[0] }?.frame ?? .zero
        func reason(_ outcome: P.Outcome) -> String { if case .unresolved(let r, _) = outcome { return r }; return "\(outcome)" }
        // 每一條分支對真的不可以用的視窗：拒絕。
        let refusedKnown = [ids[1], ids[2], ids[3], ids[4], ids[5]]
        let byID = refusedKnown.map { reason(P.choose(candidates, focusedID: $0, focusedFrame: frame)) }
        let byRequest = refusedKnown.map { reason(P.choose(candidates, focusedID: $0, focusedFrame: frame, requested: $0)) }
        check(candidates.count == 6 && byID.allSatisfy { $0 == "observed_window_not_usable" } && byRequest.allSatisfy { $0 == "requested_window_not_usable" },
              "C3 counterexample (GPT-6 #1) on real windows: the alpha-0, ordered-out, mouse-transparent, capture-protected and shield-held windows are refused both as the observed window (by ID) and as the requested windowID",
              "candidates=\(candidates.count) byID=\(byID) byRequest=\(byRequest)")
        let listedCode = P.failure(reason: "observed_window_not_usable", pid: getpid(), focusedTitle: protectedSecret, focusedFrame: frame, focusedID: ids[4]).code
        let size = "\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
        check(listedCode.contains("\"title\":\"\(normalTitle)\"") && listedCode.contains("\"size\":\"\(size)\"")
              && listedCode.contains("{\"protected\":true,\"windowID\":\(ids[4])}") && listedCode.contains("{\"protected\":true,\"windowID\":\(ids[5])}")
              && !listedCode.contains("B-7Q") && !listedCode.contains("H-3K"),
              "C3 the real candidate list (production failure()) names the shareable windows with titles and sizes; the capture-protected and shield-held ones — and the observed window itself when it is protected — only as windowID + protected", listedCode)
        guard AXIsProcessTrusted() else {
            return check.skip("C3 AX 視窗編號、readState、控制器的 observe：這個執行檔沒有輔助使用權限；純資料規則已驗，主導實機驗")
        }
        // AX：自己的視窗編號、readState 讀代理指定的那一個；指定到不可以用的、不在樹裡的＝拒絕附候選。
        let running = NSRunningApplication.current
        let wanted = ids[0]
        let state = try? await ComputerUseNative.run(pid: getpid()) {
            try ComputerUseNative.readState(running, deadline: ProcessInfo.processInfo.systemUptime + 8,
                                            includeTree: false, preferredWindowID: wanted)
        }
        let exact = state.map { P.choose(candidates, focusedID: $0.windowID, focusedFrame: $0.frame) }
        check(state?.windowID == wanted && exact == .window(wanted, rule: "same_window")
              && state?.serverFrame.map { ComputerUseWindowPick.sameSize($0, state!.frame) } == true,
              "C3 AX reads the window the agent asked for (windowID) and knows its number and its window-server frame: the capture is exactly that window even with five others on the same frame",
              "state.windowID=\(String(describing: state?.windowID)) wanted=\(wanted) pick=\(String(describing: exact)) server=\(String(describing: state?.serverFrame))")
        func refusal(_ id: CGWindowID?) async -> String {
            do {
                _ = try await ComputerUseNative.run(pid: getpid()) {
                    try ComputerUseNative.readState(running, deadline: ProcessInfo.processInfo.systemUptime + 8, includeTree: false, preferredWindowID: id)
                }
                return "read"
            } catch let failure as ComputerUseFailure { return P.reason(of: failure) ?? failure.code }
            catch { return "\(error)" }
        }
        let alpha0 = await refusal(ids[1]), overlayR = await refusal(ids[3]), bogus = await refusal(4_000_000_000)
        let protectedR = await refusal(ids[4]), heldR = await refusal(ids[5])
        check(alpha0 == "requested_window_not_usable" && overlayR == "requested_window_not_usable" && protectedR == "requested_window_not_usable"
              && heldR == "requested_window_not_usable" && bogus == "requested_window_not_in_accessibility_tree",
              "C3 counterexample: readState refuses a requested windowID that is alpha 0 / mouse-transparent / capture-protected / shield-held, and one that is not in the AX tree at all — the tree of another window is never returned for it",
              "alpha0=\(alpha0) overlay=\(overlayR) protected=\(protectedR) held=\(heldR) bogus=\(bogus)")
        // WindowCaptureShield 放手後的尾段（0.45 秒）：還是受保護＝拒絕；過了才可以。
        let lingerHolder = NSObject()
        WindowCaptureShield.shared.hold(lingerHolder, window: normal)
        let held = await refusal(ids[0])
        WindowCaptureShield.shared.release(lingerHolder)
        let lingering = await refusal(ids[0])
        let lingerFacts = P.facts(pid: getpid())[ids[0]]
        let shieldingDuringLinger = WindowCaptureShield.shared.isShielding(normal)
        // 放手後的還原計時器在 run loop 上：同 DMBrowserAcceptance.settleShield，把 run loop 跑過那一小段。
        RunLoop.main.run(until: Date().addingTimeInterval(WindowCaptureShield.linger + 0.15))
        _ = await waitUntil(1.0) { !WindowCaptureShield.shared.isShielding(normal) && P.facts(pid: getpid())[ids[0]]?.server == .shareable }
        let restoredFacts = P.facts(pid: getpid())[ids[0]]
        let restored = await refusal(ids[0])
        check(held == "requested_window_not_usable" && lingering == "requested_window_not_usable" && lingerFacts?.captureProtected == true
              && lingerFacts?.shield == .protected && shieldingDuringLinger && restoredFacts?.server == .shareable && restoredFacts?.shield == .shareable
              && restored == "read",
              "C3 counterexample (GPT-6 #1, the linger): while WindowCaptureShield holds the normal window and for the 0.45 s after release it is refused as the requested window (shield veto, whatever the window server says); once the shield lets go it reads again",
              "held=\(held) lingering=\(lingering) lingerFacts=\(String(describing: lingerFacts)) shieldingDuringLinger=\(shieldingDuringLinger) restored=\(restored) restoredFacts=\(String(describing: restoredFacts))")
        await controllerObserveChecks(check, ids: ids, titles: (normalTitle, clearTitle, protectedSecret, heldSecret))
        // ScreenCaptureKit 本身（正式的候選來源）與真的截圖要螢幕錄製權限。
        if CGPreflightScreenCaptureAccess() {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let mine = content.windows.filter { $0.owningApplication?.processID == getpid() && ids.contains($0.windowID) }
                let fresh = P.facts(pid: getpid())
                let sc = mine.map { P.Candidate(windowID: $0.windowID, title: $0.title ?? "", frame: $0.frame,
                                                facts: fresh[$0.windowID] ?? .init(onScreen: $0.isOnScreen, alpha: 1, layer: $0.windowLayer, server: .unknown)) }
                let chosen = P.choose(sc, focusedID: ids[0], focusedFrame: frame)
                let refused = P.choose(sc, focusedID: ids[4], focusedFrame: frame)
                check(chosen == .window(ids[0], rule: "same_window") && reason(refused) == "observed_window_not_usable",
                      "C4 the same pick from ScreenCaptureKit's own window list (production source)", "sc=\(sc.map(\.windowID)) chosen=\(chosen)")
                let gate = ComputerUseController.shared.session
                if let grant = try? gate.authorize(owner: UUID(), scope: "w184cu-c4", pid: getpid(), expectedEpoch: gate.currentEpoch) {
                    let result = try? await ComputerUseController.shared.observeForSelfTest(grant, includeImage: true, requestedWindowID: ids[0])
                    check(result?["windowID"] as? CGWindowID == ids[0] && (result?["imageBase64"] as? String)?.isEmpty == false,
                          "C4 the controller's observe with a real capture returns the requested window's screenshot", "\(result?.keys.sorted() ?? [])")
                    ComputerUseController.shared.stop()
                }
            } catch {
                check.skip("C4 ScreenCaptureKit：\(error.localizedDescription)；這一條沒完成，主導實機驗")
            }
        } else {
            check.skip("C4 ScreenCaptureKit 的視窗清單與真的截圖：這個執行檔沒有螢幕錄製權限（ssh 無頭）；挑視窗規則已用視窗伺服器清單驗、控制器的 observe 已用 image:false 驗。這一條沒完成，主導實機驗")
        }
    }

    /// C7（GPT-6 複核 #2、#1、#3）：控制器的 observe 整段（ComputerUseController.observeForSelfTest：正式的 observe，讀樹走同一個
    /// readState）。A 可讀、B 受保護、H 被 shield 持有：成功回應的 windows 裡 B、H 只有 index／windowID／protected，秘密標題一個字都沒有；
    /// 讀不到擋擷取狀態＝跟受保護一樣（成功回應遮、指定它＝拒絕）；私有 API 失效＝截圖與不截圖一樣在讀樹前拒絕。
    @MainActor static func controllerObserveChecks(_ check: Checker, ids: [CGWindowID],
                                                   titles: (normal: String, clear: String, protected: String, held: String)) async {
        typealias P = ComputerUseWindowPick
        typealias H = ComputerUseSelfTestHooks
        let controller = ComputerUseController.shared
        let gate = controller.session
        guard let grant = try? gate.authorize(owner: UUID(), scope: "w184cu-c7", pid: getpid(), expectedEpoch: gate.currentEpoch) else {
            return check(false, "C7 a self-target grant on the controller's own session")
        }
        defer {
            H.setSharingUnknown([])
            H.windowIDUnavailable = false
            controller.stop()
        }
        func text(_ value: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
                ?? String(describing: value)
        }
        func observe(image: Bool = false, requested: CGWindowID? = nil) async -> (result: [String: Any]?, failure: String) {
            do { return (try await controller.observeForSelfTest(grant, includeImage: image, requestedWindowID: requested), "") }
            catch let failure as ComputerUseFailure { return (nil, failure.code) }
            catch { return (nil, "\(error)") }
        }
        func rows(_ result: [String: Any]?) -> [[String: Any]] { result?["windows"] as? [[String: Any]] ?? [] }
        func row(_ result: [String: Any]?, _ id: CGWindowID) -> [String: Any]? { rows(result).first { ($0["windowID"] as? Int) == Int(id) } }
        // A 可讀、B 受保護、H shield 持有：完整回應。正向對照：alpha 0 的那個（沒受保護）標題照給——證明這條檢查會失敗。
        let (first, firstFailure) = await observe(requested: ids[0])
        let whole = first.map(text) ?? firstFailure
        let protectedRow = row(first, ids[4]).map { Set($0.keys) }, heldRow = row(first, ids[5]).map { Set($0.keys) }
        check(first?["windowState"] as? String == "present" && first?["windowID"] == nil
              && (row(first, ids[0])?["title"] as? String) == titles.normal && (row(first, ids[1])?["title"] as? String) == titles.clear
              && protectedRow == ["index", "windowID", "protected"] && heldRow == ["index", "windowID", "protected"]
              && !whole.contains("B-7Q") && !whole.contains("H-3K"),
              "C7 counterexample (GPT-6 re-check #2): the controller's full observe response (production observe, image:false) with A readable, B capture-protected and H held by WindowCaptureShield lists B and H only as index + windowID + protected — their titles appear nowhere in the whole response; A and the unprotected alpha-0 window keep their titles (positive control)",
              "failure=\(firstFailure) rows=\(rows(first).map { text($0) })")
        // 讀不到擋擷取狀態（視窗伺服器沒給）：alpha 0 那個跟受保護一樣遮掉；指定 A 而 A 讀不到＝拒絕，錯誤裡也不給 A 的標題。
        H.setSharingUnknown([ids[1]])
        let (masked, maskedFailure) = await observe(requested: ids[0])
        let maskedWhole = masked.map(text) ?? maskedFailure
        H.setSharingUnknown([ids[0]])
        let (_, refusedA) = await observe(requested: ids[0])
        let refusedObserved = (refusedA.split(separator: ":", maxSplits: 1).last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })?["observedWindow"] as? [String: Any]
        H.setSharingUnknown([])
        check(row(masked, ids[1]).map { Set($0.keys) } == ["index", "windowID", "protected"] && !maskedWhole.contains("U-5M")
              && refusedA.hasPrefix(P.failurePrefix) && P.reason(of: ComputerUseFailure(refusedA)) == "requested_window_not_usable"
              && refusedObserved?["title"] == nil && (refusedObserved?["protected"] as? Bool) == true && !refusedA.contains("A-1R"),
              "C7 counterexample (GPT-6 re-check #1): a window whose sharing state the window server does not give is treated as protected — masked in the success response (title gone) and refused when requested (no title in the error either)",
              "masked=\(row(masked, ids[1]).map { text($0) } ?? maskedFailure) refused=\(refusedA)")
        // 私有 API 失效（_AXUIElementGetWindow 拿不到）：截圖與不截圖、指定與不指定，都在讀樹前拒絕，理由一樣。
        H.windowIDUnavailable = true
        let noIDText = await observe(image: false), noIDImage = await observe(image: true)
        let noIDTextRequested = await observe(image: false, requested: ids[0]), noIDImageRequested = await observe(image: true, requested: ids[0])
        H.windowIDUnavailable = false
        let reasons = [noIDText, noIDImage, noIDTextRequested, noIDImageRequested].map { $0.result == nil ? (P.reason(of: ComputerUseFailure($0.failure)) ?? $0.failure) : "returned" }
        check(reasons == ["observed_window_unverifiable_without_ax_window_id", "observed_window_unverifiable_without_ax_window_id",
                          "requested_window_unverifiable_without_ax_window_id", "requested_window_unverifiable_without_ax_window_id"],
              "C7 counterexample (GPT-6 re-check #3): with the private window-ID API failing, the controller's observe refuses before reading the tree or capturing — the same reason with image:true and image:false, requested or not (no geometry fallback, no silent pass)",
              "\(reasons)")
        // 恢復之後照常（證明上面拒絕的是條件，不是這個環境）。
        let (again, againFailure) = await observe(requested: ids[0])
        check((row(again, ids[0])?["title"] as? String) == titles.normal,
              "C7 with the window server state and the window-ID API back, the same observe returns the window again", againFailure)
    }

    // MARK: - E 真的 ChatPageModel：權限 setter 從全權降級＝當場撤銷（要隔離的 staging 環境）

    @MainActor static func permissionSetterChecks(_ check: Checker, _ watchdog: Watchdog) async {
        watchdog.enter("E permission setter", seconds: 60)
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"], let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            return check.skip("E 真的 ChatPageModel 權限 setter：要完整隔離的 staging 環境（lead-verify 有）；這裡沒有。setter 的原始碼由 tests/w184-cu.test.mjs 釘住")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else { return check.skip("E TATWO2_LIVE_ROOT 不在 TATWO_STAGING_ROOT 裡") }
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            return check.skip("E 隔離的引擎資料夾有登入：不建 ChatPageModel（不送引擎）")
        }
        let engineRoot = root.appendingPathComponent("w184cu")
        try? FileManager.default.createDirectory(at: engineRoot, withIntermediateDirectories: true)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: engineRoot), environment: environment)
        defer { engine.shutdownAll() }
        let library = BotLibrary(root: engineRoot, skillsRoot: engineRoot.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        let saved = UserDefaults.standard.string(forKey: "tatwo2.permissionPreset")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "tatwo2.permissionPreset") }
            else { UserDefaults.standard.removeObject(forKey: "tatwo2.permissionPreset") }
        }
        typealias S = ComputerUseNative.SelfSchedule
        let gate = ComputerUseSession()
        guard let grant = try? gate.authorize(owner: UUID(), scope: "w184cu-e", pid: getpid(), expectedEpoch: gate.currentEpoch) else {
            return check(false, "E grant")
        }
        let flags = Flags()
        model.permissionPreset = .fullAccess
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); await Task.yield() }   // 建 model 的尾巴先跑完
        #if DEBUG
        let before = ComputerUseController.revocations
        #endif
        // 排一個自我動作（真的執行只是記一下），把權限降下來：控制器當場撤銷，排進去的作廢（token 沒了）。
        var ran = 0
        let token = S.schedule(authority(grant, gate, flags)) { ran += 1 }
        model.permissionPreset = .approveForMe
        let voidedAtOnce = !S.isPending(token) && S.pendingCount == 0
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); await Task.yield() }
        #if DEBUG
        let revoked = ComputerUseController.revocations == before + 1
        #else
        let revoked = true
        #endif
        check(voidedAtOnce && ran == 0 && revoked,
              "E counterexample (GPT-6 #2): setting the real ChatPageModel.permissionPreset from 全權 to 代我核准 revokes Computer Use synchronously in the setter (queued self action voided before the run loop turns)",
              "voidedAtOnce=\(voidedAtOnce) ran=\(ran) revoked=\(revoked)")
        // 反向：從代我核准到要求核准（不是從全權降）不撤；全權到全權不撤；升級不撤。
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); await Task.yield() }
        #if DEBUG
        let stable = ComputerUseController.revocations
        #endif
        model.permissionPreset = .askFirst
        model.permissionPreset = .fullAccess
        model.permissionPreset = .fullAccess
        #if DEBUG
        let untouched = ComputerUseController.revocations == stable
        #else
        let untouched = true
        #endif
        let token2 = S.schedule(authority(grant, gate, flags)) { ran += 1 }
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); await Task.yield() }
        check(untouched && ran == 1 && !S.isPending(token2),
              "E changes that do not leave 全權 (代我核准→要求核准, upgrade to 全權, 全權→全權) revoke nothing, and a queued action then runs",
              "untouched=\(untouched) ran=\(ran)")
        gate.stop()
    }

    /// computer_observe 的 windowID：MCP 閘門之外，App 這邊也驗（正整數視窗編號，其他一律擋）。
    @MainActor static func parameterChecks(_ check: Checker) {
        let caller = UUID()
        func accepts(_ extra: [String: Any]) -> Bool {
            var params: [String: Any] = ["callerThreadID": caller.uuidString, "sessionID": UUID().uuidString]
            params.merge(extra) { _, new in new }
            return (try? ChatPageModel.validateComputerToolParameters("computer_observe", params: params, caller: caller)) != nil
        }
        let refused: [Any] = [0, -1, 1.5, "59634", true, NSNull(), 4_294_967_296.0]
        let absent: Bool
        do { absent = try ComputerUseNative.windowIDParameter(nil) == nil } catch { absent = false }
        check(accepts([:]) && accepts(["windowID": 59634]) && accepts(["windowID": 4_294_967_295.0])
              && refused.allSatisfy { !accepts(["windowID": $0]) } && absent,
              "D computer_observe accepts an optional windowID (a positive window number) and refuses anything else before any native work")
    }
}
#endif
