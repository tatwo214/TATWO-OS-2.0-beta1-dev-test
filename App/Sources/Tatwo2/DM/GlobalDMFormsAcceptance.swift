#if DEBUG
import AppKit
import Combine
import QuartzCore
import SwiftUI

/// `TATWO2_SELFTEST=w184forms`：W184 AB 私訊框 iPhone Duo 的外殼——四種形態（尺寸、順序、等比縮、舊值對應）、⌘⌥Tab（只在框看得到時註冊、
/// 收起就放掉、動畫走完才接下一次）、四段轉換動畫對照表（含減少動態效果＝直接換、動畫期間原生網頁藏起來不重建）、頂列（展開收回、只剩左上圓鈕、圓鈕右鍵選單的內容與右鍵／control＋點；W184 F）、
/// 內橫一條頂列兩欄（reveal 開到右欄、左欄照常送出）。只在完整隔離的 staging 跑：熱鍵是假的、頁面是假的、引擎資料夾必須未登入（不送引擎）。
/// 畫面證據（PNG）寫到 TATWO2_SELFTEST_ARTIFACTS：四種形態各一張（頂列收起）、外直頂列展開一張、內橫兩欄（右欄 Browser）一張。
enum GlobalDMFormsAcceptance {
    @MainActor final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: @autoclosure () -> String = "") {
            if condition { passed += 1 } else { failed += 1 }
            let detail = condition ? "" : evidence()
            print("W184FORMS \(condition ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — " + String(detail.prefix(400)))")
        }
        func skip(_ label: String) {
            skipped += 1
            print("W184FORMS SKIP \(label)")
        }
    }

    /// 右鍵選單按下去記下來。
    @MainActor final class Recorder {
        var forms: [GlobalDMForm] = []
        var calls: [String] = []
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"], let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w184forms needs a fully isolated staging environment")
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
            let suite = "ai.tatwo.selftest.w184forms.\(name).\(UUID().uuidString)"
            suites.append(suite)
            return UserDefaults(suiteName: suite) ?? .standard
        }
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
        // 隔離的引擎與 model（完整的私訊框：助理那條塞 48 則訊息——每一種形態都捲得動、欄寬量得到；GPT-6 審查 #5、#6，查證 #13）。
        let fixture = try await Fixture.make(root: root, environment: environment)
        defer { fixture.engine.shutdownAll() }

        formChecks(check, freshDefaults)
        await hotkeyChecks(check, freshDefaults)
        motionChecks(check)
        await nativePageChecks(check)
        topBarChecks(check, freshDefaults)
        await pageMenuChecks(check, freshDefaults, model: fixture.model)
        await duoChecks(check, freshDefaults)
        await tentIntentChecks(check, freshDefaults)
        await canvasChecks(check, freshDefaults, model: fixture.model, engine: fixture.engine)
        cornerChecks(check, freshDefaults, model: fixture.model)
        await dockedRigChecks(check, freshDefaults, model: fixture.model)
        gripPureChecks(check, freshDefaults)   // W184 G1b：範圍、兩個角、記住、圓鈕讓開
        gripEventChecks(check)   // W184 G1b：抓取區的滑鼠、回到預設
        await gripRigChecks(check, freshDefaults, model: fixture.model)   // W184 G1b：原生拖曳、角的縮放、圓鈕模式
        await bubbleEventChecks(check, freshDefaults, model: fixture.model)   // W184 G1b 第二輪：真的桌面圓鈕的點、拖、長按
        gripMarkChecks(check, freshDefaults, model: fixture.model)   // W184 G1b：抓取區、角標、游標（W184 AB：沒有小把手）
        await edgeLineChecks(check, freshDefaults, model: fixture.model)   // W184 AB（使用者 09-30）：動畫中途只有一條外框、沒有多出來的邊線
        await abortIdleChecks(check, freshDefaults)
        await tentTurnChecks(check, freshDefaults, model: fixture.model)
        await tentNoVideoChecks(check, freshDefaults, model: fixture.model)
        composerChipChecks(check, freshDefaults, model: fixture.model)
        await darkModeChecks(check, freshDefaults, model: fixture.model)   // W184 AB（.031 真機）：深色系統下 fable5 的字要夠深
        await regressionChecks(check, freshDefaults, model: fixture.model)   // W184 F3T：GPT-6 審查 F3 #4、#5 的回歸（GlobalDMFormsRegressionAcceptance.swift）
        await securityChecks(check, freshDefaults, model: fixture.model)
        await taskChecks(check, freshDefaults, model: fixture.model)   // W183 R12：任務版面（連線用雙頁：左頁授權卡、右頁網頁；結束還原）
        try await evidence(check, fixture: fixture, freshDefaults)

        print("W184FORMS SUMMARY failures=\(check.failed) passed=\(check.passed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    /// 隔離的引擎（staging 裡的資料夾）、助理那條（48 則訊息：每一種形態都捲得動）、另一個對象的那條、私訊框的 model。
    @MainActor final class Fixture {
        let engine: ChatLiveEngine
        let model: ChatPageModel
        let thread: UUID

        init(engine: ChatLiveEngine, model: ChatPageModel, thread: UUID) {
            self.engine = engine
            self.model = model
            self.thread = thread
        }

        static func make(root: URL, environment: [String: String]) async throws -> Fixture {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
            let project = engine.newProject(name: "W184 形態", workdir: root.path)
            let thread = engine.newThread(in: project, title: "另一個對象")
            if let assistant = engine.doc.assistantThreadID {
                let rows = (0..<48).map { index in
                    ChatMessage(id: "w184f-\(index)", role: index % 2 == 0 ? .user : .assistant,
                                text: index % 2 == 0 ? "第 \(index / 2 + 1) 個問題：換形態的時候這一則還在原來的位置嗎？"
                                    : "第 \(index / 2 + 1) 個回答：在。換形態只換框的大小，捲動位置、草稿、輸入焦點都不動；欄寬變了文字會重新換行。")
                }
                engine.appendOfflineRows(threadID: assistant, rows: rows)
            }
            let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
            await library.ready()
            let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
            return Fixture(engine: engine, model: model, thread: thread)
        }
    }

    // MARK: - A 形態：尺寸、順序、等比縮、舊值對應

    @MainActor static func formChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) {
        check(GlobalDMForm.allCases.map(\.size) == [CGSize(width: 466, height: 678), CGSize(width: 890, height: 626),
                                                    CGSize(width: 626, height: 890), CGSize(width: 678, height: 466)],
              "A1 four forms: outer portrait 466×678, inner landscape 890×626, inner portrait 626×890, tent 678×466")
        var walk: [GlobalDMForm] = [.outerPortrait]
        for _ in 0..<4 { walk.append(walk[walk.count - 1].next) }
        check(walk == [.outerPortrait, .innerLandscape, .innerPortrait, .tent, .outerPortrait],
              "A1 ⌘⌥Tab order: outer portrait → inner landscape → inner portrait → tent → outer portrait", "\(walk)")
        check(GlobalDMForm.allCases.filter(\.isDuo) == [.innerLandscape]
              && GlobalDMForm.allCases.map { DMPhone.sideMargin(for: $0) } == [16, 20, 16, 16],
              "A1 only inner landscape has two columns (20pt sides like the chat columns; the others 16)")

        let small = CGRect(x: 0, y: 25, width: 1024, height: 640)
        let fits = GlobalDMForm.allCases.allSatisfy { form in
            let size = GlobalDMDeskLayout.fitted(form.size, in: small)
            return size.width <= small.width - 48 && size.height <= small.height - 48
                && abs(size.width / size.height - form.size.width / form.size.height) < 0.01
        }
        check(fits, "A2 every form shrinks proportionally when the screen is too small (floating box)")
        let content = CGRect(x: 100, y: 50, width: 820, height: 900)
        let composer = CGRect(x: 180, y: 76, width: 600, height: 118)
        if let box = GlobalDMDockLayout.place(content: content, composer: composer, mode: .chat, boxOpen: true,
                                              boxSize: GlobalDMForm.innerLandscape.size).box {
            check(box.width < 890 && box.width <= content.width - 24 && abs(box.width / box.height - 890.0 / 626.0) < 0.01
                  && box.minY >= composer.maxY + 12,
                  "A2 docked inner landscape in a narrow window keeps its proportions (\(Int(box.width))×\(Int(box.height)))")
        } else {
            check(false, "A2 docked inner landscape box exists")
        }
        let tall = CGRect(x: 100, y: 50, width: 1400, height: 1000)
        if let box = GlobalDMDockLayout.place(content: tall, composer: composer, mode: .chat, boxOpen: true,
                                              boxSize: GlobalDMForm.tent.size).box {
            check(box.size == GlobalDMForm.tent.size, "A2 a docked form that fits keeps its exact size (tent 678×466)")
        } else {
            check(false, "A2 docked tent box exists")
        }
        // W184 F3（使用者 09-29 17:10：「r角現在會變 導致輸入筐根外ｒ角不齊」）：框的圓角任何形態、任何大小都固定 52，輸入框固定 40（同心：內距 12）。
        let scales: [CGFloat] = [0.7, 1, 1.3]
        let fixedCorner = GlobalDMForm.allCases.allSatisfy { form in
            scales.allSatisfy { scale in
                let size = CGSize(width: form.size.width * scale, height: form.size.height * scale)
                return GlobalDMPhoneLook(form: form, slide: nil, size: size).radius == 52
            }
        }
        check(fixedCorner && DMPhone.screenRadius == 52 && GlobalDMChatLayout.composerRadius == 40 && GlobalDMChatLayout.composerInset == 12
              && DMPhone.screenRadius - GlobalDMChatLayout.composerInset == GlobalDMChatLayout.composerRadius,
              "A2 the box corner stays 52 in every form at 0.7 / 1 / 1.3 scale and the composer stays 40 (concentric: 52 − 12)",
              "composer=\(GlobalDMChatLayout.composerRadius) inset=\(GlobalDMChatLayout.composerInset)")

        let legacy: [(String?, GlobalDMForm)] = [("iPhoneOpen", .innerLandscape), ("dm", .outerPortrait),
                                                  ("chatGPTQuick", .outerPortrait), ("iPhoneClosed", .outerPortrait),
                                                  (nil, .outerPortrait), ("W184FORMS-unknown", .outerPortrait)]
        check(legacy.allSatisfy { GlobalDMForm.stored($0.0) == $0.1 }
              && GlobalDMForm.allCases.allSatisfy { GlobalDMForm.stored($0.rawValue) == $0 },
              "A3 old expand sizes map: iPhone Duo open → inner landscape, every other old value → outer portrait; new values round-trip")
        let old = freshDefaults("legacy")
        old.set("iPhoneOpen", forKey: GlobalDMDeskSettings.formKey)
        let upgraded = GlobalDMDeskSettings(defaults: old)
        check(upgraded.form == .innerLandscape && old.string(forKey: GlobalDMDeskSettings.formKey) == "iPhoneOpen",
              "A3 an old 'iPhone Duo open' setting opens as inner landscape (nothing rewritten until the form changes)")
        upgraded.form = .tent
        check(GlobalDMDeskSettings(defaults: old).form == .tent && old.string(forKey: GlobalDMDeskSettings.formKey) == "tent",
              "A3 the chosen form is remembered")
    }

    // MARK: - B ⌘⌥Tab

    @MainActor static func hotkeyChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) async {
        let fake = GlobalDMDeskFakeHotKeyBackend()
        let hotkeys = GlobalDMHotKeys(backend: fake)
        let store = GlobalDMStore(defaults: freshDefaults("hot"), chatGPTAllowed: { true })
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("hotDesk"))
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: false)
        let browser = DMBrowser(store: store, openBox: {}, pageHost: DMBrowserAcceptance.FakeWebHost(), podPage: { nil })
        let desk = GlobalDMDeskController(store: store, settings: settings, hotkeys: hotkeys, panels: panels,
                                          duo: GlobalDMDuo(defaults: nil), browser: browser)   // 右欄的第二個 store 不建（不叫醒 ChatGPT）
        desk.install()
        defer { desk.uninstall() }
        let tab = UInt32(GlobalDMDirectKey.tab.keyCode)
        check(!fake.live.values.contains(tab) && !hotkeys.registeredKeys.contains(.tab),
              "B1 ⌘⌥Tab is not registered while the box is folded (other apps keep the key)")
        store.openFloating()
        check(fake.live.values.contains(tab) && hotkeys.registeredKeys.contains(.tab),
              "B1 opening the box registers ⌘⌥Tab")
        var seen: [GlobalDMForm] = []
        for _ in 0..<4 {
            fake.press(keyCode: tab)
            seen.append(settings.form)
        }
        check(seen == [.innerLandscape, .innerPortrait, .tent, .outerPortrait],
              "B2 each ⌘⌥Tab moves to the next form and wraps around", "\(seen)")
        store.isFloatingOpen = false
        check(!fake.live.values.contains(tab) && !hotkeys.registeredKeys.contains(.tab),
              "B1 folding the box releases ⌘⌥Tab right away")
        store.openDocked()
        store.isDockedVisible = true
        check(hotkeys.registeredKeys.contains(.tab), "B1 the docked box showing in the main window also registers ⌘⌥Tab")
        store.isDockedVisible = false
        check(!hotkeys.registeredKeys.contains(.tab), "B1 the main window going away releases it again")
        store.isDockedVisible = true

        // W184 F2：轉換中再按 ⌘⌥Tab（或 setForm）＝直接轉向下一個（不排隊、不等）；房 E 等別的畫面看得到「轉換進行中」。
        let before = settings.form
        panels.formMotion.begin(duration: 0.25)
        let transitioning = desk.isFormTransitioning && panels.formMotion.isAnimating
        fake.press(keyCode: tab)
        let turned = settings.form == before.next
        fake.press(keyCode: tab)
        let turnedAgain = settings.form == before.next.next && desk.setForm(before.next.next.next) && settings.form == before.next.next.next
        let stillTransitioning = desk.isFormTransitioning
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating }
        check(transitioning && turned && turnedAgain && stillTransitioning && !desk.isFormTransitioning,
              "B3 during a transition ⌘⌥Tab and setForm turn straight to the new form each time (no queue, no wait)",
              "turned=\(turned) again=\(turnedAgain) form=\(settings.form)")
        check(desk.setForm(.outerPortrait, animated: false) && settings.form == .outerPortrait && desk.form == .outerPortrait,
              "B4 setForm(_:animated:) switches the form by code (the tent card's 打開私訊框 uses it)")
        fake.refused = [tab]
        store.isDockedVisible = false
        store.isDockedVisible = true
        check(hotkeys.failed.contains(.tab), "B5 ⌘⌥Tab held by another app is reported")
        let busyMenu = GlobalDMMoreMenu.make(GlobalDMMoreMenuState(form: .outerPortrait, tabKeyFailed: hotkeys.failed.contains(.tab)),
                                             actions: noopActions())
        // 守：換形態的鍵被佔用時選單照實說（W184 F45：寫目前設的鍵；沒改過＝⌥⌘Tab）。
        check(busyMenu.items.contains { $0.identifier?.rawValue == "tatwo.dm.form.keyBusy" && !$0.isEnabled
            && $0.title.contains("\(GlobalDMDirectKey.tab.display) 被別的 App 佔用") },
              "B5 the page circle's menu says ⌘⌥Tab is taken and that the menu still switches forms")
        fake.refused = []
        store.close()
    }

    // MARK: - C 換形態＝滑（W184 F2：樣子是時間的純函式，在指定秒數取樣）

    /// 施工單的取樣秒數。
    static let sampleTimes: [Double] = [0.03, 0.08, 0.14, 0.24, 0.6]

    /// 右下角固定（App 現在的擺法：浮動框、停靠框都是右緣與下緣對齊）時某個形態的框（螢幕座標，y 往上）。
    static func pinnedBox(_ form: GlobalDMForm, right: CGFloat = 1420, bottom: CGFloat = 24) -> CGRect {
        CGRect(x: right - form.size.width, y: bottom, width: form.size.width, height: form.size.height)
    }

    static func slidePlan(_ from: GlobalDMForm, _ to: GlobalDMForm,
                          style: GlobalDMFormTransition.Style = .slide) -> GlobalDMFormPlan {
        GlobalDMFormPlan(from: .rest(from, box: pinnedBox(from)), to: to, target: pinnedBox(to), style: style)
    }

    /// 一串值是不是一路朝 goal 走（不回頭、不衝過頭）。
    static func oneWay(_ values: [CGFloat], toward goal: CGFloat) -> Bool {
        guard let first = values.first else { return true }
        let up = goal >= first
        return zip(values, values.dropFirst()).allSatisfy { up ? $1 >= $0 - 0.000_1 : $1 <= $0 + 0.000_1 }
            && values.allSatisfy { up ? $0 <= goal + 0.000_1 : $0 >= goal - 0.000_1 }
    }

    @MainActor static func motionChecks(_ check: Checker) {
        typealias T = GlobalDMFormTransition
        check(T.between(.outerPortrait, .innerLandscape).style == .slide && T.between(.innerPortrait, .tent).style == .slide
              && T.between(.outerPortrait, .tent).style == .slide
              && T.between(.outerPortrait, .innerLandscape, reduceMotion: true).style == .fade
              && T.between(.outerPortrait, .innerLandscape, animated: false).style == .instant && T.between(.tent, .tent).style == .instant,
              "C1 every change slides (menu jumps too); reduce motion fades out and in; animated: false or the same form switches straight away")
        check(DMPhone.Slide.response == 0.42 && abs(GlobalDMSpring.omega - 2 * Double.pi / 0.42) < 1e-9 && DMPhone.Slide.settle == 0.6
              && DMPhone.Slide.fadeOut == 0.10 && DMPhone.Slide.fadeIn == 0.22 && DMPhone.Slide.reduceOut == 0.12 && DMPhone.Slide.reduceIn == 0.15,
              "C2 a critically damped spring, response 0.42 (.smooth(duration: 0.42)), settled at 0.6 s; content swaps 0.10 out / 0.22 in; reduce motion 0.12 / 0.15")

        // (1) 取樣 0.03／0.08／0.14／0.24／0.6 秒：固定的角（右下）不動、會動的兩條邊（左、上）單向移動、0.6 秒時等於新框（≤1pt）。
        let steps: [(GlobalDMForm, GlobalDMForm)] = [(.outerPortrait, .innerLandscape), (.innerLandscape, .innerPortrait),
                                                     (.innerPortrait, .tent), (.tent, .outerPortrait), (.outerPortrait, .tent)]
        for (from, to) in steps {
            let plan = slidePlan(from, to)
            let boxes = sampleTimes.map { plan.frame(at: $0).box }
            let old = pinnedBox(from), new = pinnedBox(to)
            let pinned = boxes.allSatisfy { abs($0.maxX - old.maxX) < 0.001 && abs($0.minY - old.minY) < 0.001 }
            let edges = oneWay([old.minX] + boxes.map(\.minX), toward: new.minX) && oneWay([old.maxY] + boxes.map(\.maxY), toward: new.maxY)
            let settled = boxes.last.map { abs($0.minX - new.minX) <= 1 && abs($0.maxY - new.maxY) <= 1
                && abs($0.width - new.width) <= 1 && abs($0.height - new.height) <= 1 } ?? false
            check(pinned && edges && settled,
                  "C3 \(from.rawValue) → \(to.rawValue): the bottom-right corner stays, the left and top edges move one way, at 0.6 s it is the new box (≤1pt)",
                  boxes.map { "(\(Int($0.minX)),\(Int($0.maxY)))" }.joined(separator: " "))
        }

        // 框裡：進內橫＝對話欄從整個框寬連續變成左欄寬、右欄（寬度用最後的寬度）從它底下露出來，分隔線在後 70% 淡入；出內橫反過來、前 60% 淡出。
        let open = slidePlan(.outerPortrait, .innerLandscape), close = slidePlan(.innerLandscape, .innerPortrait)
        func look(_ frame: GlobalDMSlideFrame) -> GlobalDMPhoneLook { GlobalDMPhoneLook(form: frame.form, slide: frame, size: frame.box.size) }
        let opening = ([0] + sampleTimes).map { open.frame(at: $0) }
        let openChat = opening.map { look($0).chatWidth(in: $0.box.width) }
        let openShown = opening.map { $0.box.width - look($0).chatWidth(in: $0.box.width) }
        let openRight = Set(opening.map { look($0).rightWidth })
        let dividerLate = stride(from: 0.0, through: 0.6, by: 0.01).allSatisfy { t in
            let frame = open.frame(at: t)
            return frame.duo > DMPhone.Slide.dividerIn || frame.divider == 0
        }
        check(openChat.first == 466 && oneWay(openChat, toward: 400) && abs((openChat.last ?? 0) - 400) <= 1
              && oneWay(openShown, toward: 490) && openRight.count == 1 && abs((openRight.first ?? 0) - 489.5) < 0.01
              && dividerLate && (opening.last?.divider ?? 0) > 0.99,
              "C4 into inner landscape: the chat column narrows from the whole box to the left column, the right column (at its final width) comes out from under it; the divider fades in over the last 70%",
              "chat=\(openChat) right=\(openRight)")
        let closing = ([0] + sampleTimes).map { close.frame(at: $0) }
        let closeChat = closing.map { look($0).chatWidth(in: $0.box.width) }
        let dividerEarly = stride(from: 0.0, through: 0.6, by: 0.01).allSatisfy { t in
            let frame = close.frame(at: t)
            return frame.duo > 1 - DMPhone.Slide.dividerOut || frame.divider == 0
        }
        check(closeChat.first == 400 && oneWay(closeChat, toward: 626) && abs((closeChat.last ?? 0) - 626) <= 1
              && Set(closing.dropLast().map { look($0).rightWidth }).count == 1 && dividerEarly,
              "C4 out of inner landscape: the chat column widens to the whole box and covers the right column again; the divider fades out over the first 60%",
              "chat=\(closeChat)")

        // (4) 換內容（任何形態↔倒放）：t＝0.10 秒兩層都 ≤0.05、t＝0.32 秒新的 ≥0.95；兩層不會同時半透明；同一串對話一直是 1。
        let down = slidePlan(.innerPortrait, .tent), up = slidePlan(.tent, .outerPortrait)
        let d10 = down.frame(at: 0.10), d32 = down.frame(at: 0.32), u10 = up.frame(at: 0.10), u32 = up.frame(at: 0.32)
        check(d10.chat <= 0.05 && d10.tent <= 0.05 && d32.tent >= 0.95 && u10.chat <= 0.05 && u10.tent <= 0.05 && u32.chat >= 0.95,
              "C5 swapping content (a form ↔ the tent): at 0.10 s both layers are ≤ 0.05, at 0.32 s the new one is ≥ 0.95",
              "down: \(d10.chat)/\(d10.tent) → \(d32.tent); up: \(u10.tent)/\(u10.chat) → \(u32.chat)")
        let neverBoth = [down, up].allSatisfy { plan in
            stride(from: 0.0, through: 0.6, by: 0.005).allSatisfy { t in
                let frame = plan.frame(at: t)
                return !(frame.chat > 0.02 && frame.chat < 0.98 && frame.tent > 0.02 && frame.tent < 0.98)
            }
        }
        let sameChat = [open, close, slidePlan(.innerPortrait, .outerPortrait), slidePlan(.outerPortrait, .innerPortrait)].allSatisfy { plan in
            stride(from: 0.0, through: 0.6, by: 0.01).allSatisfy { plan.frame(at: $0).chat == 1 && plan.frame(at: $0).tent == 0 }
        }
        check(neverBoth && sameChat,
              "C5 the two layers are never half-transparent together; between chats (outer ↔ inner landscape ↔ inner portrait) the chat stays at 1 all along")

        // (6) 轉向：轉換中換目標＝從那一刻的位置與速度接著走（不跳、速度連續），0.6 秒後是新框；整段只有一條時間軸。
        var turn = slidePlan(.outerPortrait, .innerLandscape)
        let at = 0.14
        let beforeTurn = turn.frame(at: at), speedBefore = turn.segment(at: at).speed(at: at)
        turn.retarget(at: at, to: .innerPortrait, target: pinnedBox(.innerPortrait))
        let afterTurn = turn.frame(at: at), speedAfter = turn.segment(at: at).speed(at: 0)
        let late = turn.frame(at: at + 0.6).box, goal = pinnedBox(.innerPortrait)
        let continuous = abs(beforeTurn.box.minX - afterTurn.box.minX) < 0.001 && abs(beforeTurn.box.maxY - afterTurn.box.maxY) < 0.001
            && abs(beforeTurn.duo - afterTurn.duo) < 0.000_1 && abs(speedBefore.x - speedAfter.x) < 0.001
            && abs(speedBefore.width - speedAfter.width) < 0.001 && abs(speedBefore.height - speedAfter.height) < 0.001
        check(continuous && abs(late.minX - goal.minX) <= 1 && abs(late.maxY - goal.maxY) <= 1 && turn.end == at + DMPhone.Slide.settle
              && turn.form == .innerPortrait,
              "C6 turning mid-way keeps the position and speed (no jump), then settles on the new box 0.6 s later",
              "before=\(beforeTurn.box) after=\(afterTurn.box) v=\(speedBefore.x)/\(speedAfter.x)")

        // (8) 減少動態效果：整個框 0.12 秒淡出 → 換成新框 → 0.15 秒淡入，不滑（中間沒有別的矩形）。
        let fade = slidePlan(.outerPortrait, .innerLandscape, style: .fade)
        let old = pinnedBox(.outerPortrait), new = pinnedBox(.innerLandscape)
        let rects = stride(from: 0.0, through: 0.3, by: 0.005).map { fade.frame(at: $0).box }
        let noSlide = rects.allSatisfy { $0 == old || $0 == new } && rects.contains(old) && rects.contains(new)
        let f06 = fade.frame(at: 0.06), f13 = fade.frame(at: 0.13), f27 = fade.frame(at: 0.27)
        check(noSlide && f06.box == old && f06.opacity > 0 && f06.opacity < 1 && fade.frame(at: 0.119).opacity < 0.05
              && f13.box == new && f13.opacity < 0.2 && f27.opacity == 1 && abs(fade.end - 0.27) < 0.000_1,
              "C7 reduce motion: the whole box fades out (0.12 s), switches to the new box, fades in (0.15 s) — no sliding in between",
              "opacity 0.06=\(f06.opacity) 0.13=\(f13.opacity)")
    }

    // MARK: - C 轉換期間原生網頁的遮蔽狀態（不重建、不重新載入；GPT-6 審查 #3、#6 的反例）

    @MainActor static func nativePageChecks(_ check: Checker) async {
        let mask = GlobalDMNativePageMask()
        func container() -> DMBrowserPageContainer { DMBrowserPageContainer(frame: NSRect(x: 0, y: 0, width: 500, height: 600)) }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 662, height: 926))
        let first = container(), second = container()
        root.addSubview(first)
        let page = NSView(frame: first.bounds)
        first.addSubview(page)

        // C8 一般情況：藏起來、同一個畫面、同一個容器；放手就顯示回來，底色還原。
        var token = mask.begin()
        mask.cover(in: root)
        let hidden = page.isHidden && page.superview === first && first.layer?.backgroundColor != nil && mask.isMasking
        mask.end(token)
        check(hidden && !page.isHidden && page.superview === first && first.layer?.backgroundColor == nil && !mask.isMasking,
              "C8 a native page is only hidden while the transition holds the mask (same view, same container), then shown")

        // C8 反例：轉換中頁面被搬到另一個容器（停靠框換成浮動框，Pod 那一格搬家）——結束時照樣顯示回來，不看它現在在哪。
        token = mask.begin()
        mask.cover(in: root)
        page.removeFromSuperview()
        second.addSubview(page)   // 搬家的那一方不認得遮蔽（舊的 Pod 路徑）：頁面帶著「藏著」過去
        let movedHidden = page.isHidden
        mask.end(token)
        check(movedHidden && !page.isHidden && page.superview === second,
              "C8 counterexample: a page moved to another container during the transition is still shown again when it ends")

        // C8 反例：轉換中才掛上的頁面（DMBrowser 的 attach）照遮蔽狀態藏；結束時顯示回來、那個容器的佔位底色還原。
        let web = DMBrowserWebPage(DMBrowserAcceptance.FakeWebPage())
        let late = container()
        token = GlobalDMNativePageMask.shared.begin()
        web.attach(to: late)
        let lateHidden = web.view.isHidden && web.view.superview === late && late.layer?.backgroundColor != nil
            && GlobalDMNativePageMask.shared.hiddenPages.contains { $0 === web.view }
        web.attach(to: first)   // 轉換中又換一次容器（attach 到新的框）
        let rehomedHidden = web.view.isHidden && web.view.superview === first
        GlobalDMNativePageMask.shared.end(token)
        check(lateHidden && rehomedHidden && !web.view.isHidden && web.view.superview === first && late.layer?.backgroundColor == nil,
              "C8 counterexample: a page attached (or re-attached elsewhere) during the transition stays hidden, then is shown when it ends")
        web.view.isHidden = true   // 舊版殘留：被藏著的頁面（例如以前搬走後沒還原的 Pod 那一格）
        web.detach()
        web.attach(to: second)
        check(!web.view.isHidden && web.view.superview === second && !GlobalDMNativePageMask.shared.isMasking,
              "C8 outside a transition attach always shows the page (a page left hidden before comes back)")

        // C8 倒放的影片容器有卡蓋著：遮蔽結束不把影片翻出來蓋在卡上。
        let tent = DMTentVideoContainer(frame: NSRect(x: 0, y: 0, width: 678, height: 466))
        let video = NSView(frame: tent.bounds)
        tent.addSubview(video)
        let tentRoot = NSView(frame: tent.bounds)
        tentRoot.addSubview(tent)
        token = mask.begin()
        mask.cover(in: tentRoot)
        tent.covered = true
        mask.end(token)
        check(video.isHidden && tent.keepsPagesHidden, "C8 a card covering the tent video keeps it hidden after the mask ends")
        tent.covered = false

        // C8 真的滑一段（W184 F2）：畫布裡的原生頁整段藏著（中途轉向也藏）、中途換視窗掛上的也藏；Browser 容器佔位＝頁面底色、
        // 倒放影片容器佔位＝黑色；停下全部顯示回來（同一個畫面、沒重新載入）、底色還原。
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 926, height: 926), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 926, height: 926))
        window.contentView = content
        let panelBox = container()
        content.addSubview(panelBox)
        let shown = DMBrowserWebPage(DMBrowserAcceptance.FakeWebPage())
        shown.attach(to: panelBox)
        let tentBox = DMTentVideoContainer(frame: NSRect(x: 0, y: 0, width: 678, height: 466))
        let tentVideo = NSView(frame: tentBox.bounds)
        tentBox.addSubview(tentVideo)
        content.addSubview(tentBox)
        let other = NSWindow(contentRect: NSRect(x: -21_000, y: -20_000, width: 526, height: 700), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let otherBox = container()
        other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 526, height: 700))
        other.contentView?.addSubview(otherBox)
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            other.orderOut(nil)
        }
        func isBlack(_ color: CGColor?) -> Bool {
            guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return false }
            return rgb.redComponent < 0.01 && rgb.greenComponent < 0.01 && rgb.blueComponent < 0.01 && rgb.alphaComponent > 0.99
        }
        let motion = GlobalDMFormMotion()
        let idles = HandsLocked(0)
        motion.onIdle = { idles.update { $0 += 1 } }
        motion.slide(from: .rest(.innerPortrait, box: pinnedBox(.innerPortrait)), to: .tent,
                     target: pinnedBox(.tent), style: .slide, host: content)
        let playing = motion.isAnimating && shown.view.isHidden && tentVideo.isHidden && GlobalDMNativePageMask.shared.isMasking
        let fills = panelBox.layer?.backgroundColor != nil && !isBlack(panelBox.layer?.backgroundColor) && isBlack(tentBox.layer?.backgroundColor)
        shown.attach(to: otherBox)   // 滑到一半框換手（停靠框 → 浮動框）
        let movedDuring = shown.view.isHidden && shown.view.superview === otherBox
        _ = await DMBrowserAcceptance.waitUntil(1) { motion.elapsed > 0.2 }
        motion.slide(from: .rest(.tent, box: pinnedBox(.tent)), to: .outerPortrait,
                     target: pinnedBox(.outerPortrait), style: .slide, host: content)
        let turnedMasked = motion.isAnimating && shown.view.isHidden && tentVideo.isHidden && GlobalDMNativePageMask.shared.isMasking && idles.get() == 0
        _ = await DMBrowserAcceptance.waitUntil(3) { !motion.isAnimating }
        check(playing && fills && movedDuring && turnedMasked && !motion.isAnimating && idles.get() == 1 && !shown.view.isHidden
              && shown.view.superview === otherBox && !tentVideo.isHidden && tentBox.layer?.backgroundColor == nil
              && !GlobalDMNativePageMask.shared.isMasking && motion.current == nil && motion.plan == nil,
              "C8 a slide keeps native pages hidden the whole way (a turn too; the tent video's stand-in is black, the Browser's the page colour) and shows the same pages again once it settles",
              "playing=\(playing) fills=\(fills) moved=\(movedDuring) turned=\(turnedMasked) idles=\(idles.get())")
    }

    // MARK: - D 頂列

    @MainActor static func topBarChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) {
        check(DMPhone.Strip.width(count: 3, open: false) == 52 && DMPhone.Strip.width(count: 3, open: true) == 156
              && DMPhone.Strip.width(count: 1, open: true) == 52 && DMPhone.Strip.spacing == 8 && DMPhone.Strip.inset == 4
              && DMPhone.Strip.currentRing == 2 && DMPhone.Strip.otherRing == 1 && DMPhone.Strip.duration == 0.26,
              "D1 strip: 52×52 clip (−4 margin, 4 padding), 44pt circles 8 apart, opens to 156 in 260ms; rings 2 and 1")
        let store = GlobalDMStore(defaults: freshDefaults("bar"), chatGPTAllowed: { true })
        store.select(.chatGPT)
        let items = GlobalDMTopBarLayout.order(store.pageItems(besideBrowser: false), current: store.currentPageID(besideBrowser: false))
        check(items.map(\.id) == ["chatgpt", "assistant", "browser"],
              "D2 open strip: the current page first, then the fixed order without it", "\(items.map(\.id))")
        store.showBrowser()
        check(store.currentPageID(besideBrowser: false) == "browser" && store.currentPageID(besideBrowser: true) == "chatgpt"
              && GlobalDMTopBarLayout.order(store.pageItems(besideBrowser: false), current: "browser").map(\.id) == ["browser", "assistant", "chatgpt"],
              "D2 one column: Browser open = the globe is the current page; inner landscape keeps the left column's target")
        let session = UUID()
        store.select(.thread(session))
        let withSession = store.pageItems(besideBrowser: false)
        check(withSession.first?.id == "thread:" + session.uuidString && withSession.count == 4,
              "D2 a session opened by its direct key gets its own circle in front")
        store.select(.assistant)
        var hover = GlobalDMStripHover()
        hover.hovering(true)
        let opened = hover.isOpen
        hover.picked()
        let folded = !hover.isOpen
        hover.hovering(true)
        let stays = !hover.isOpen
        hover.hovering(false)
        check(opened && folded && stays && !hover.isOpen, "D3 hover opens the strip; picking a circle folds it; moving away folds it")
        // W184 F：右上的 ⋯、⌄ 拿掉；頂列照舊 68 高（上 14、44 的圓鈕、下 10），左上圓鈕列的位置不變。
        check(DMPhone.headerHeight == 68
              && GlobalDMTopBarLayout.stripFrame(open: false, count: 3, form: .outerPortrait) == CGRect(x: 12, y: 10, width: 52, height: 52)
              && GlobalDMTopBarLayout.stripFrame(open: false, count: 3, form: .innerLandscape).minX == 16
              && GlobalDMTopBarLayout.stripFrame(open: true, count: 3, form: .outerPortrait).maxX <= 466 - DMPhone.margin,
              "D4 the bar is still 68 high in chat and Browser alike and the strip keeps its place top-left (16 in, 20 in inner landscape); nothing is reserved top-right")

        let recorder = Recorder()
        let actions = GlobalDMMoreMenu.Actions(
            setForm: { form in recorder.forms.append(form) },
            openDirectKeys: { recorder.calls.append("keys") },
            openAccessibility: { recorder.calls.append("accessibility") },
            collapse: { recorder.calls.append("collapse") },
            restore: { recorder.calls.append("restore") },
            close: { recorder.calls.append("close") })
        let menu = GlobalDMMoreMenu.make(GlobalDMMoreMenuState(form: .innerLandscape, systemWide: false), actions: actions)
        let formItems = menu.items.filter { $0.identifier?.rawValue.hasPrefix("tatwo.dm.form.") == true && $0.isEnabled }
        check(formItems.map(\.title) == GlobalDMForm.allCases.map(\.menuTitle)
              && formItems.filter { $0.state == .on }.map(\.title) == [GlobalDMForm.innerLandscape.menuTitle]
              && menu.items.first?.identifier?.rawValue == "tatwo.dm.size"
              && menu.items.first?.title.contains(GlobalDMDirectKey.tab.display) == true,   // 守：標題寫換形態的鍵（W184 F45：目前設的，預設 ⌥⌘Tab）
              "D5 page circle's menu: the four forms (current ticked) under a heading that explains ⌘⌥Tab", "\(menu.items.map(\.title))")
        let accessibility = menu.items.first { $0.identifier?.rawValue == "tatwo.dm.accessibility" }
        check(menu.items.contains { $0.title == "直達鍵…" } && accessibility?.isEnabled == true
              && menu.items.contains { $0.title == "要在其他 App 用 ⌥⌘，要開裝置控制和資料取用（舊稱輔助使用）權限" && !$0.isEnabled }
              && menu.items.contains { $0.title == "縮成桌面圓鈕　⌥⌘↓" },
              "D5 page circle's menu: direct keys, the ⌥⌘ note with 打開裝置控制和資料取用（舊稱輔助使用）設定… (tatwo.dm.accessibility), and 縮成桌面圓鈕 ⌥⌘↓")
        for item in [formItems.last, accessibility, menu.items.first { $0.title == "直達鍵…" }].compactMap({ $0 }) {
            if let action = item.action, let target = item.target as? NSObject { _ = target.perform(action, with: item) }
        }
        check(recorder.forms == [.tent] && recorder.calls == ["accessibility", "keys"],
              "D5 page circle's menu items do what they say (form, accessibility settings, direct-key page)")
        let collapsedMenu = GlobalDMMoreMenu.make(GlobalDMMoreMenuState(form: .outerPortrait, isCollapsed: true, systemWide: true),
                                                  actions: actions)
        check(collapsedMenu.items.contains { $0.title == "恢復主視窗　⌥⌘↑" } && !collapsedMenu.items.contains { $0.title.hasPrefix("縮成桌面圓鈕") }
              && collapsedMenu.items.contains { $0.title == "⌥⌘ 開關私訊框：在任何 App 都有效" && !$0.isEnabled }
              && !collapsedMenu.items.contains { $0.identifier?.rawValue == "tatwo.dm.accessibility" },
              "D5 page circle's menu when collapsed offers 恢復主視窗 ⌥⌘↑; with the permission there is no settings item")
        check(!menu.items.contains { $0.title.contains("私訊框  ") || $0.title.contains("ChatGPT 快捷視窗") || $0.title.contains("iPhone Duo") },
              "D5 the old expand sizes are gone from the menu")
    }

    // MARK: - D 左上頁面圓鈕的右鍵選單（W184 F：右上 ⋯、⌄ 拿掉）

    /// 右鍵選單跳出來的記下來（正式會停在選單追蹤裡）。
    @MainActor final class MenuLog {
        var menus: [NSMenu] = []
        var events: [NSEvent?] = []
    }

    @MainActor static func pageMenuChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        let store = GlobalDMStore(defaults: freshDefaults("pageMenu"), chatGPTAllowed: { true })
        store.select(.assistant)

        // 版面：有頂列的三個形態都只有左上一顆（位置照舊：左 16／內橫 20、上 14、44），右上什麼都沒畫（⋯、⌄ 不在了）。
        var placed: [String] = [], emptyRight: [String] = [], handles: [String] = [], notes: [String] = []
        for form in GlobalDMForm.allCases where form != .tent {
            guard let bar = renderTopBar(store, form: form) else {
                return check.skip("D6 真的畫出來：這個環境畫不出來（沒有畫面環境）")
            }
            defer { bar.close() }
            let catchers = DMBrowserPhoneAcceptance.views(GlobalDMPageMenuCatcherView.self, in: bar.host)
            let frame = catchers.first.map { frameFromTop($0, in: bar.host) } ?? .null
            if catchers.count == 1, near(frame.minX, DMPhone.sideMargin(for: form)), near(frame.minY, DMPhone.headerTop),
               near(frame.width, DMPhone.touch), near(frame.height, DMPhone.touch) {
                placed.append(form.rawValue)
            }
            let rightStart = DMPhone.sideMargin(for: form) + DMPhone.Strip.collapsed + 12
            // W184 AB（使用者 09-30：「上方不要拖拽槓 不好看」）：原本頂列正中間那條拖曳小把手（36×5 膠囊、離上緣 6）拿掉了——
            // 那一塊（含左右、上下各多幾點）一個記號都不准有；右上照舊什麼都沒畫。
            let handle = CGRect(x: (form.size.width - 36) / 2 - 4, y: 2, width: 44, height: 13)
            let region = CGRect(x: rightStart, y: 0, width: form.size.width - rightStart, height: DMPhone.headerHeight)
            let grab = marks(in: bar, rect: handle)
            let drawn = marks(in: bar, rect: region)
            if drawn == 0 { emptyRight.append(form.rawValue) }
            if grab == 0 { handles.append(form.rawValue) }
            notes.append("\(form.rawValue): circles=\(catchers.count) frame=\(frame) right=\(drawn) handle=\(grab)")
        }
        let barForms = GlobalDMForm.allCases.filter { $0 != .tent }.map(\.rawValue)
        check(placed == barForms,
              "D6 the page circle keeps its place top-left (16 in, 20 in inner landscape; 14 from the top; 44) and is the only circle with the menu",
              notes.joined(separator: "; "))
        check(emptyRight == barForms,
              "D6 nothing is drawn top-right in any form with a top bar: ⋯ and ⌄ are gone", notes.joined(separator: "; "))
        check(handles == barForms,
              "D6 (W184 AB, user 09-30 \"上方不要拖拽槓\") no top bar draws the grab handle any more: the middle of the bar (where the 36×5 capsule was) is blank paper",
              notes.joined(separator: "; "))
        if let folded = renderTopBar(store, form: .outerPortrait), let opened = renderTopBar(store, form: .outerPortrait, open: true) {
            let heights = (NSHostingView(rootView: GlobalDMTopBar(store: store, form: .outerPortrait).frame(width: 466)).fittingSize.height,
                           NSHostingView(rootView: GlobalDMTopBar(store: store, form: .outerPortrait).frame(width: 466)
                            .environment(\.globalDMStripPinnedOpen, true)).fittingSize.height)
            check(near(heights.0, DMPhone.headerHeight) && near(heights.1, DMPhone.headerHeight)
                  && marks(in: folded, rect: CGRect(x: 0, y: 0, width: 466, height: DMPhone.headerHeight)) > 0
                  && marks(in: opened, rect: CGRect(x: 100, y: 0, width: 80, height: DMPhone.headerHeight)) > 0,
                  "D6 the bar is 68 high whether the strip is folded or open (the content below never moves)", "\(heights)")
            folded.close()
            opened.close()
        }

        // 右鍵、control＋點：跳出原本「⋯ 更多」那一份（識別碼 tatwo.dm.more）；左鍵照常給圓鈕（不接）。
        guard let bar = renderTopBar(store, form: .outerPortrait),
              let catcher = DMBrowserPhoneAcceptance.views(GlobalDMPageMenuCatcherView.self, in: bar.host).first else {
            return check.skip("D7 右鍵選單：這個環境畫不出來（沒有畫面環境）")
        }
        defer { bar.close() }
        bar.window.ignoresMouseEvents = false   // 自測自己把點擊交給視窗（sendEvent），不經過真的滑鼠
        let saved = (GlobalDMPageMenuCatcherView.currentEvent, GlobalDMPageMenuCatcherView.makeMenu, GlobalDMPageMenuCatcherView.present)
        defer {
            GlobalDMPageMenuCatcherView.currentEvent = saved.0
            GlobalDMPageMenuCatcherView.makeMenu = saved.1
            GlobalDMPageMenuCatcherView.present = saved.2
        }
        let log = MenuLog()
        GlobalDMPageMenuCatcherView.makeMenu = { store, surface in
            var actions = noopActions()
            actions.close = { GlobalDMMoreMenu.close(store, surface: surface) }
            return GlobalDMMoreMenu.make(GlobalDMMoreMenuState(form: .outerPortrait, systemWide: false), actions: actions)
        }
        GlobalDMPageMenuCatcherView.present = { menu, event, _ in
            log.menus.append(menu)
            log.events.append(event)
        }
        let center = catcher.convert(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY), to: nil)
        func click(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, send: Bool) -> (hit: Bool, opened: Bool) {
            guard let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: flags,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: bar.window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return (false, false) }
            GlobalDMPageMenuCatcherView.currentEvent = { event }
            let before = log.menus.count
            let hit = bar.window.contentView?.hitTest(center) === catcher
            if hit, send { bar.window.sendEvent(event) }
            return (hit, log.menus.count == before + 1 && log.events.last.map { $0 === event } == true)
        }
        let right = click(.rightMouseDown, [], send: true)
        let control = click(.leftMouseDown, .control, send: true)
        let plain = click(.leftMouseDown, [], send: false)
        check(right.hit && right.opened, "D7 right-click on the page circle opens the menu (the window hands the click to it)",
              "hit=\(right.hit) opened=\(right.opened)")
        check(control.hit && control.opened, "D7 control-click on the page circle opens the same menu",
              "hit=\(control.hit) opened=\(control.opened)")
        check(!plain.hit && !plain.opened && log.menus.count == 2,
              "D7 a plain click is not taken: it goes to the circle underneath (switch page, hover opens the strip)")
        // GPT-6 審查 #6：左鍵真的點下去（按下、放開排進 App 的事件佇列，照正式的路徑送進正式的面板）：圓鈕自己的動作真的跑了、沒開選單。
        GlobalDMPageMenuCatcherView.currentEvent = saved.0   // 正式的 NSApp.currentEvent（上面自測直接 sendEvent 才換掉）
        let left = await realLeftClick(store: store, log: log)
        check(left.ran && !left.menu,
              "D7 counterexample (GPT-6 #6): a real left click on the page circle (down + up through the app's event queue into a real panel) runs the circle's own action (the open target list folds) and opens no menu",
              left.detail)
        // VoiceOver 走的路：輔助使用樹裡那顆圓鈕的「顯示選單」動作，開到同一份選單。
        if let ax = axShowMenu(bar, id: "tatwo.dm.icon." + store.currentPageID(besideBrowser: false), log: log) {
            check(ax.opened, "D7 VoiceOver's show-menu (the circle's AX action found in the accessibility tree) opens the same menu", ax.detail)
        } else {
            check.skip("D7 VoiceOver 的 AX 動作：這個環境建不出 SwiftUI 的輔助使用樹（ssh 無頭）；圓鈕的 accessibilityAction(.showMenu) 由 node 測試釘原始碼，主導實機驗")
        }
        let wanted = ["tatwo.dm.size", "tatwo.dm.form.outerPortrait", "tatwo.dm.form.innerLandscape", "tatwo.dm.form.innerPortrait",
                      "tatwo.dm.form.tent", "tatwo.dm.more.keys", "tatwo.dm.more.chord", "tatwo.dm.accessibility", "tatwo.dm.more.collapse",
                      "tatwo.dm.close"]
        let menu = log.menus.first
        let ids = menu?.items.compactMap { $0.identifier?.rawValue } ?? []
        print("W184FORMS NOTE page menu: " + (menu?.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓" : "") + $0.title } ?? []).joined(separator: " | "))
        check(menu?.identifier?.rawValue == "tatwo.dm.more" && wanted.allSatisfy(ids.contains)
              && menu?.items.first { $0.identifier?.rawValue == "tatwo.dm.form.outerPortrait" }?.state == .on
              && menu?.items.contains { $0.title == "縮成桌面圓鈕　⌥⌘↓" } == true && menu?.items.contains { $0.title == "直達鍵…" } == true,
              "D7 the right-click menu has every item the ⋯ menu had: four forms (current ticked), 直達鍵…, the ⌥⌘ note, 打開裝置控制和資料取用（舊稱輔助使用）設定…, 縮成桌面圓鈕 ⌥⌘↓ (menu id tatwo.dm.more)",
              "\(ids)")

        // W184 F2：最下面「收起私訊框」（tatwo.dm.close）收的是選單所在的那個框：浮動框收浮動、停靠框收停靠。
        // 查證 #15：從完整的 GlobalDMPhoneBox(surface:) 找那顆圓鈕與兩個抓取區（surface 是整支手機給的環境值，不是自測自己塞的）；
        // GPT-6 審查 #7：兩個抓取區在完整私訊框的輔助使用樹裡找得到識別碼。
        store.attach(model)
        func closeFromPhone(_ surface: GlobalDMSurface) -> (surfaces: Bool, last: Bool, closed: Bool, ids: Set<String>) {
            if surface == .floating { store.openFloating() } else { store.openDocked() }
            guard let rendered = GlobalDMChatAcceptance.renderSync(GlobalDMPhoneBox(store: store, model: model, surface: surface, form: .outerPortrait),
                                                                   size: GlobalDMForm.outerPortrait.size) else { return (false, false, false, []) }
            defer { rendered.close() }
            let circles = DMBrowserPhoneAcceptance.views(GlobalDMPageMenuCatcherView.self, in: rendered.host)
            let grips = DMBrowserPhoneAcceptance.views(GlobalDMBoxGripView.self, in: rendered.host)
            let surfaces = circles.count == 1 && circles.allSatisfy { $0.surface == surface } && grips.count == 3
                && grips.allSatisfy { $0.surface == surface } && grips.contains { $0.kind == .move }
                && grips.contains { $0.kind == .resize(.topRight) } && grips.contains { $0.kind == .resize(.bottomLeft) }
            let ids = GlobalDMChatAcceptance.identifiers(in: rendered)
            guard let circle = circles.first,
                  let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: rendered.window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { return (surfaces, false, false, ids) }
            circle.rightMouseDown(with: event)
            guard let item = log.menus.last?.items.last, item.identifier?.rawValue == "tatwo.dm.close", item.title == "收起私訊框" else {
                return (surfaces, false, false, ids)
            }
            if let action = item.action, let target = item.target as? NSObject { _ = target.perform(action, with: item) }
            return (surfaces, true, surface == .floating ? !store.isFloatingOpen : !store.isOpen, ids)
        }
        let floatingClose = closeFromPhone(.floating)
        let dockedClose = closeFromPhone(.docked)
        check(floatingClose.surfaces && floatingClose.last && floatingClose.closed && dockedClose.surfaces && dockedClose.last && dockedClose.closed,
              "D7 收起私訊框 (tatwo.dm.close) is the last item and closes the box the menu sits on: floating → floating, docked → docked (found in the full GlobalDMPhoneBox(surface:), whose page circle and both grips carry that surface)",
              "floating=\(floatingClose.surfaces),\(floatingClose.last),\(floatingClose.closed) docked=\(dockedClose.surfaces),\(dockedClose.last),\(dockedClose.closed)")
        let gripIDs: Set<String> = ["tatwo.dm.grip.move", "tatwo.dm.grip.resize", "tatwo.dm.grip.resize.bottomLeft"]
        check(gripIDs.isSubset(of: floatingClose.ids) && gripIDs.isSubset(of: dockedClose.ids),
              "D15 counterexample (GPT-6 #7): the move and both resize grips have identifiers (tatwo.dm.grip.move, tatwo.dm.grip.resize, tatwo.dm.grip.resize.bottomLeft) and are found in the full DM box's accessibility walk",
              "floating=\(floatingClose.ids.filter { $0.hasPrefix("tatwo.dm.grip") }.sorted()) docked=\(dockedClose.ids.filter { $0.hasPrefix("tatwo.dm.grip") }.sorted())")
        store.close()
    }

    /// 左鍵真的點在頁面圓鈕上：頂列放進正式的面板（GlobalDMPanel＋GlobalDMHostingView：不是 key 也接第一下），按下、放開排進 App 的事件佇列，
    /// 照正式的路徑送進視窗（右鍵選單的攔截層照 NSApp.currentEvent 判斷）。圓鈕的動作＝切到目前那頁（對象清單收起）。
    @MainActor static func realLeftClick(store: GlobalDMStore, log: MenuLog) async -> (ran: Bool, menu: Bool, detail: String) {
        guard let screen = NSScreen.main else { return (false, false, "no screen") }
        let size = CGSize(width: GlobalDMForm.outerPortrait.size.width, height: DMPhone.headerHeight)
        let panel = GlobalDMPanel(contentRect: NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40,
                                                      width: size.width, height: size.height),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        let host = GlobalDMHostingView.make(GlobalDMTopBar(store: store, form: .outerPortrait).frame(width: size.width, height: size.height))
        panel.contentView = host
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        guard let catcher = DMBrowserPhoneAcceptance.views(GlobalDMPageMenuCatcherView.self, in: host).first else { return (false, false, "no circle") }
        let point = catcher.convert(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY), to: nil)
        store.isPickerOpen = true
        let before = log.menus.count
        let now = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: now,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: now + 0.05,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else {
            return (false, false, "no events")
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        _ = await DMBrowserAcceptance.waitUntil(1) { !store.isPickerOpen }
        return (!store.isPickerOpen, log.menus.count != before, "pickerStillOpen=\(store.isPickerOpen) menus=\(log.menus.count - before) at=\(point)")
    }

    /// VoiceOver 走的路：在輔助使用樹裡找識別碼 id 的元件（頁面圓鈕），叫它的「顯示選單」動作；選單有沒有開、是不是同一份（tatwo.dm.more）。
    /// 這個環境建不出 SwiftUI 的輔助使用樹＝nil。
    @MainActor static func axShowMenu(_ rendered: GlobalDMChatAcceptance.Rendered, id: String, log: MenuLog) -> (opened: Bool, detail: String)? {
        var found: NSObject?
        func attribute(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        for _ in 0..<10 where found == nil {
            var seen = Set<ObjectIdentifier>()
            func visit(_ element: Any, depth: Int) {
                guard found == nil, depth < 60, let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
                if !(object is NSView), attribute(object, "accessibilityIdentifier") as? String == id {
                    found = object
                    return
                }
                for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
                if let view = object as? NSView { for sub in view.subviews { visit(sub, depth: depth + 1) } }
            }
            visit(rendered.window, depth: 0)
            rendered.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let element = found else { return nil }
        let before = log.menus.count
        let modern = NSSelectorFromString("accessibilityPerformShowMenu"), legacy = NSSelectorFromString("accessibilityPerformAction:")
        if element.responds(to: modern) {
            _ = element.perform(modern)   // 回傳的 BOOL 不看（只看選單有沒有開）
        } else if element.responds(to: legacy) {
            _ = element.perform(legacy, with: NSAccessibility.Action.showMenu.rawValue)
        } else {
            return (false, "the element has no show-menu action")
        }
        let opened = log.menus.count == before + 1 && log.menus.last?.identifier?.rawValue == "tatwo.dm.more"
        return (opened, "menus=\(log.menus.count - before) id=\(log.menus.last?.identifier?.rawValue ?? "-")")
    }

    /// 只畫頂列（白底、淺色；照形態的寬、68 高；surface＝這支手機是停靠框還是浮動框）。
    @MainActor static func renderTopBar(_ store: GlobalDMStore, form: GlobalDMForm, open: Bool = false,
                                        surface: GlobalDMSurface = .floating) -> GlobalDMChatAcceptance.Rendered? {
        GlobalDMChatAcceptance.renderSync(GlobalDMTopBar(store: store, form: form).environment(\.globalDMStripPinnedOpen, open)
                                            .environment(\.globalDMSurface, surface),
                                          size: CGSize(width: form.size.width, height: DMPhone.headerHeight))
    }

    /// 一個 view 在畫面裡的位置（點、y 從上往下）。
    @MainActor static func frameFromTop(_ view: NSView, in host: NSView) -> CGRect {
        let frame = host.convert(view.bounds, from: view)
        return host.isFlipped ? frame : CGRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// 白底上畫了東西的像素有幾個（rect 用點、y 從上往下；任何一個色版比 245 暗就算）。
    @MainActor static func marks(in rendered: GlobalDMChatAcceptance.Rendered, rect: CGRect) -> Int {
        let rep = rendered.bitmap
        guard rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let data = rep.bitmapData else { return -1 }
        let sx = CGFloat(rep.pixelsWide) / rendered.size.width, sy = CGFloat(rep.pixelsHigh) / rendered.size.height
        let x0 = max(0, Int(rect.minX * sx)), x1 = min(rep.pixelsWide, Int(rect.maxX * sx))
        let y0 = max(0, Int(rect.minY * sy)), y1 = min(rep.pixelsHigh, Int(rect.maxY * sy))
        let samples = rep.samplesPerPixel, row = rep.bytesPerRow, colors = min(3, samples)
        var count = 0
        for y in y0..<max(y0, y1) {
            let line = data + y * row
            for x in x0..<max(x0, x1) {
                let pixel = line + x * samples
                var dark = false
                for s in 0..<colors where pixel[s] < 245 { dark = true }
                if dark { count += 1 }
            }
        }
        return count
    }

    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }

    // MARK: - E 內橫：一條頂列、兩欄、reveal 開到右欄、左欄照常送

    @MainActor static func duoChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) async {
        typealias L = GlobalDMDuoLayout
        check(L.panes(form: .innerLandscape, browsing: false, hasTabs: false) == [.conversation, .otherConversation]
              && L.panes(form: .innerLandscape, browsing: false, hasTabs: true) == [.conversation, .browser]
              && L.panes(form: .innerLandscape, browsing: true, hasTabs: false) == [.conversation, .browser]
              && L.panes(form: .outerPortrait, browsing: true, hasTabs: true) == [.browser]
              && L.panes(form: .innerPortrait, browsing: false, hasTabs: true) == [.conversation],
              "E1 inner landscape: left = this target's chat, right = Browser (tabs or the Browser circle) or the other target's chat")
        check(GlobalDMForm.allCases.map { L.topBarCount(form: $0) } == [1, 1, 1, 0] && DMPhone.duoLeadingFraction * 890 == 400
              && DMPhone.hairline == 0.5,
              "E1 one top bar across both columns (none on the tent); left column 400 of 890; 0.5pt divider")

        let h = DMBrowserAcceptance.Harness("w184forms")
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("duoDesk"))
        let panels = GlobalDMPanelController(store: h.store, desk: settings, hostsWindows: false)
        let desk = GlobalDMDeskController(store: h.store, settings: settings, hotkeys: GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend()),
                                          panels: panels, duo: GlobalDMDuo(defaults: nil), browser: h.browser)
        desk.install()
        defer {
            desk.uninstall()
            h.browser.closeAll()
        }
        h.store.select(.assistant)
        h.store.showNotice("W184FORMS 左欄的提示")
        _ = desk.setForm(.innerLandscape, animated: false)
        let opened = h.browser.open(url: DMBrowserAcceptance.loginURL("W184FORMSDUO"), purpose: .cloudflareLogin)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.browser.hasTabs }
        check(opened && h.store.browsesBeside && h.store.isBrowsingBeside && !h.store.isBrowsing && h.store.target == .assistant
              && h.store.notice == "W184FORMS 左欄的提示"
              && L.panes(form: settings.form, browsing: h.store.isBrowsingBeside, hasTabs: h.browser.hasTabs) == [.conversation, .browser],
              "E2 in inner landscape DMBrowser.reveal opens the page in the right column; the left column (chat, notice) stays")
        h.store.select(.thread(UUID()))
        h.store.setDraft("/plan W184FORMS", for: h.store.target)
        let sent = h.store.send()
        check(!sent && h.store.notice?.hasPrefix("/plan 要在 Coder 的輸入框用") == true && h.browser.hasTabs
              && L.panes(form: settings.form, browsing: h.store.isBrowsingBeside, hasTabs: h.browser.hasTabs) == [.conversation, .browser],
              "E3 with the Browser in the right column the left column still sends (it reaches the normal send checks)")
        _ = desk.setForm(.innerPortrait, animated: false)
        h.store.showBrowser()
        h.store.setDraft("/plan W184FORMS", for: h.store.target)
        let blocked = !h.store.send() && h.store.notice == nil && h.store.isBrowsing
        check(blocked && !h.store.isBrowsingBeside, "E3 one column with the Browser open still refuses to send (Enter belongs to the page)")
        _ = desk.setForm(.tent, animated: false)
        _ = desk.setForm(.outerPortrait, animated: false)
        _ = desk.setForm(.innerLandscape, animated: false)
        await Task.yield()
        let moved = !h.store.isBrowsing && h.store.isBrowsingBeside
        h.browser.closeAll()
        _ = await DMBrowserAcceptance.waitUntil(2) { !h.browser.hasTabs }
        desk.syncDuo()
        check(moved && !h.store.isBrowsingBeside,
              "E4 entering inner landscape moves an open Browser to the right column; closing every tab brings the other chat back")
    }

    // MARK: - G 倒放時「要看到某個畫面」的入口（GPT-6 審查 #4、#6 的反例）

    @MainActor static func tentIntentChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) async {
        let store = GlobalDMStore(defaults: freshDefaults("tentStore"), chatGPTAllowed: { true })
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("tentDesk"))
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: false)
        let browser = DMBrowser(store: store, openRequest: { panels.open($0) }, pageHost: DMBrowserAcceptance.FakeWebHost(), podPage: { nil })
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 466, height: 600))
        browser.claim(surface)
        let desk = GlobalDMDeskController(store: store, settings: settings, hotkeys: GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend()),
                                          panels: panels, duo: GlobalDMDuo(defaults: nil), browser: browser)
        desk.install()
        defer {
            desk.uninstall()
            browser.closeAll()
        }

        // 直達鍵（框收著、倒放）：立起到外直、切到那個對象、打開——不再被倒放吞掉。
        let session = UUID()   // 不用 ChatGPT 當對象：框一開就會叫醒真的 ChatGPT 對話
        settings.form = .tent
        desk.openDirect(.thread(session))
        check(settings.form == .outerPortrait && store.target == .thread(session) && store.isFloatingOpen,
              "G1 tent + a direct key: the phone stands up to outer portrait and opens on that target (not swallowed)")
        store.close()
        settings.form = .tent
        store.openFloating()
        desk.openDirect(.assistant)
        check(settings.form == .outerPortrait && store.target == .assistant && store.isFloatingOpen,
              "G1 tent on screen + a direct key: stands up to outer portrait on that target")

        // 轉換中（例如剛倒下去）按「到私訊框設定」：排隊，動畫走完才立起並打開直達鍵頁（不丟掉）。
        store.close()
        settings.form = .tent
        panels.formMotion.begin(duration: 0.25)
        desk.openDirectKeySettings()
        let queued = desk.pendingContentCount == 1 && settings.form == .tent && !store.isPresented
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating && store.isPresented }
        check(queued && settings.form == .outerPortrait && store.isFloatingOpen && store.isEditingDirectKeys && desk.pendingContentCount == 0,
              "G2 during a transition 到私訊框設定 is queued; when it ends the phone stands up and shows the direct-key page",
              "queued=\(queued) form=\(settings.form) open=\(store.isFloatingOpen) keys=\(store.isEditingDirectKeys)")

        // 流程開授權頁（DMBrowser.reveal）：倒放時立起到外直，Browser 開在那一欄；轉換中就排隊、走完再開。
        store.close()
        settings.form = .tent
        let opened = browser.open(url: DMBrowserAcceptance.loginURL("W184FORMSTENT"), purpose: .cloudflareLogin)
        check(opened && settings.form == .outerPortrait && store.isBrowsing && store.isFloatingOpen,
              "G3 tent + a flow opening its page (DMBrowser.reveal): stands up and shows the Browser tab")
        store.close()
        settings.form = .tent
        panels.formMotion.begin(duration: 0.25)
        let again = browser.open(url: DMBrowserAcceptance.loginURL("W184FORMSTENT"), purpose: .cloudflareLogin)
        let waiting = again && desk.pendingContentCount == 1 && settings.form == .tent && !store.isPresented
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating && store.isPresented }
        check(waiting && settings.form == .outerPortrait && store.isFloatingOpen && store.isBrowsing,
              "G3 a reveal during a transition is queued, then shown in the Browser when it ends (not dropped)",
              "waiting=\(waiting) form=\(settings.form) open=\(store.isFloatingOpen)")

        // 不是倒放、沒有轉換：照舊馬上打開、形態不變。
        store.close()
        settings.form = .innerPortrait
        desk.openDirect(.assistant)
        check(settings.form == .innerPortrait && store.isFloatingOpen && desk.pendingContentCount == 0,
              "G4 outside the tent a direct key opens right away and keeps the form")
        store.close()
        await queuedEntryChecks(check, store: store, settings: settings, panels: panels, browser: browser, desk: desk)
    }

    /// W184 AB（GPT-6 複核 新發現 1–3）：排隊的是整個入口操作（開框＋選頁／選對象／設定旗標）、可以撤銷、出列前再驗證、完成回呼記最終樣子。
    @MainActor static func queuedEntryChecks(_ check: Checker, store: GlobalDMStore, settings: GlobalDMDeskSettings,
                                             panels: GlobalDMPanelController, browser: DMBrowser, desk: GlobalDMDeskController) async {
        browser.closeAll()
        store.close()
        settings.form = .outerPortrait
        let presenter = HandsConnectPresenter(store: store, openRequest: { panels.open($0) }, browser: browser, hookPod: { _ in },
                                              podURL: { nil }, cancelFlow: {}, card: { .loading("讀取中") })

        // 新發現 1：已有停靠框 → 轉換中排隊 → 出列時主視窗看不到＝改開浮動框：直達鍵頁照樣打開、直達鍵的對象照樣切過去。
        // 反例：以前旗標在排隊前就設了，換手時兩個框都關著的那一下被清掉——框開了、設定頁沒開。
        store.openDocked()
        panels.formMotion.begin(duration: 0.25)
        desk.openDirectKeySettings()
        let keysWaiting = desk.pendingContentCount == 1 && store.isOpen && !store.isFloatingOpen && !store.isEditingDirectKeys
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating && store.isFloatingOpen }
        check(keysWaiting && store.isFloatingOpen && !store.isOpen && store.isEditingDirectKeys && desk.pendingContentCount == 0,
              "G5 counterexample (new finding 1): docked box open → 到私訊框設定 queued → dequeued as a floating box — the direct-key page still opens (set after the box really opened)",
              "waiting=\(keysWaiting) floating=\(store.isFloatingOpen) docked=\(store.isOpen) keys=\(store.isEditingDirectKeys)")
        store.close()
        let session = UUID()
        store.openDocked()
        panels.formMotion.begin(duration: 0.25)
        desk.openDirect(.thread(session))
        let targetWaiting = desk.pendingContentCount == 1 && store.target != .thread(session)
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating && store.isFloatingOpen }
        check(targetWaiting && store.isFloatingOpen && !store.isOpen && store.target == .thread(session),
              "G5 a direct key queued over a docked box: the whole entry waits (target not switched yet) and switches once the floating box is open")
        store.close()

        // 新發現 2：先取消、後出列——轉換中流程開了授權頁（整個請求排隊），動畫結束前分頁就關了：撤銷，出列時不立起、不開框；再關一次也不動。
        settings.form = .tent
        panels.formMotion.begin(duration: 0.25)
        _ = browser.open(url: DMBrowserAcceptance.loginURL("W184FORMSCANCEL"), purpose: .cloudflareLogin)
        let pageQueued = desk.pendingContentCount == 1 && !store.isPresented && !store.isBrowsing
        browser.close(purpose: .cloudflareLogin)
        let pageCancelled = desk.pendingContentCount == 0 && browser.tabs.isEmpty
        browser.close(purpose: .cloudflareLogin)
        browser.closeAll()
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating }
        check(pageQueued && pageCancelled && !panels.formMotion.isAnimating && settings.form == .tent && !store.isPresented && !store.isBrowsing,
              "G6 counterexample (new finding 2): cancel first, dequeue later — a flow's page queued during a transition and its tab closed before the end: nothing stands up or opens (closing again changes nothing)",
              "queued=\(pageQueued) cancelled=\(pageCancelled) form=\(settings.form) open=\(store.isPresented)")
        panels.formMotion.begin(duration: 0.25)
        presenter.show()
        let cardQueued = desk.pendingContentCount == 1 && !store.isPresented && presenter.isShown
        presenter.hide()
        presenter.hide()
        let cardCancelled = desk.pendingContentCount == 0
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating }
        check(cardQueued && cardCancelled && !panels.formMotion.isAnimating && settings.form == .tent && !store.isPresented,
              "G6 counterexample (new finding 2): the ［連線］ card shown during a transition and dismissed (twice) before it ends — cancelled: nothing stands up or opens")
        let targetAlive = HandsLocked(true)
        let goneOutcomes = HandsLocked<[GlobalDMOpenOutcome]>([])
        let gone = GlobalDMOpenRequest(valid: { targetAlive.get() })
        gone.whenFinished { outcome in goneOutcomes.update { $0.append(outcome) } }
        panels.formMotion.begin(duration: 0.25)
        panels.open(gone)
        let goneQueued = desk.pendingContentCount == 1 && goneOutcomes.get().isEmpty
        targetAlive.set(false)
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating && !goneOutcomes.get().isEmpty }
        check(goneQueued && goneOutcomes.get() == [.dropped] && settings.form == .tent && !store.isPresented,
              "G6 re-checked before dequeue: a target gone while queued (not cancelled) is dropped — no stand-up, no box")
        let twiceOutcomes = HandsLocked<[GlobalDMOpenOutcome]>([])
        let twice = GlobalDMOpenRequest()
        twice.whenFinished { outcome in twiceOutcomes.update { $0.append(outcome) } }
        twice.cancel()
        twice.cancel()
        panels.open(twice)
        check(twiceOutcomes.get() == [.cancelled] && settings.form == .tent && !store.isPresented,
              "G6 cancelling twice reports once; a cancelled request handed to the gate opens nothing")
        settings.form = .outerPortrait
        panels.formMotion.begin(duration: 0.25)
        _ = browser.open(url: DMBrowserAcceptance.loginURL("W184FORMSKEEP"), purpose: .cloudflareLogin)
        _ = browser.open(url: DMBrowserAcceptance.loginURL("W184FORMSDROP"), purpose: .cloudflareLogin)
        let keepID = browser.tabs.first?.id
        let twoQueued = browser.tabs.count == 2 && desk.pendingContentCount == 2
        if let dropID = browser.tabs.last?.id { browser.userClose(dropID) }
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating && store.isFloatingOpen }
        check(twoQueued && store.isFloatingOpen && store.isBrowsing && browser.tabs.count == 1 && browser.activeID == keepID,
              "G6 two pages queued in one transition, the later tab closed before dequeue: only its request is cancelled — the earlier page still opens in front")
        browser.closeAll()
        store.close()

        // 新發現 3：已有框換手——原本停靠框開著；轉換中流程開頁（排隊），出列時開浮動框；流程結束：記的是這一次開框之後的樣子（浮動框），
        // 所以改回原本的停靠框。反例：以前排隊前就把停靠框記成「打開後的樣子」，收尾比對不上，浮動框留著。
        store.openDocked()
        panels.formMotion.begin(duration: 0.25)
        _ = browser.open(url: DMBrowserAcceptance.loginURL("W184FORMSHANDOFF"), purpose: .cloudflareLogin)
        let handoffQueued = desk.pendingContentCount == 1 && store.isOpen && !store.isFloatingOpen && !store.isBrowsing
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating && store.isFloatingOpen }
        let handedOff = store.isFloatingOpen && !store.isOpen && store.isBrowsing
        browser.close(purpose: .cloudflareLogin)
        check(handoffQueued && handedOff && store.isOpen && !store.isFloatingOpen && !store.isBrowsing,
              "G7 counterexample (new finding 3): docked box open → a flow's page queued → dequeued as a floating box → the flow ends: back to the docked box (the state recorded is the one this open produced)",
              "queued=\(handoffQueued) handedOff=\(handedOff) docked=\(store.isOpen) floating=\(store.isFloatingOpen)")
        store.close()
        store.openDocked()
        panels.formMotion.begin(duration: 0.25)
        presenter.show()
        _ = await DMBrowserAcceptance.waitUntil(2) { !panels.formMotion.isAnimating && store.isFloatingOpen }
        let cardHandedOff = store.isFloatingOpen && !store.isOpen
        presenter.hide()
        check(cardHandedOff && store.isOpen && !store.isFloatingOpen,
              "G7 counterexample (new finding 3): the ［連線］ card the same way — docked → queued → floating → card dismissed: back to the docked box")
        store.close()
        store.openDocked()
        _ = browser.open(url: DMBrowserAcceptance.loginURL("W184FORMSUSER"), purpose: .cloudflareLogin)
        let flowOpened = store.isFloatingOpen && !store.isOpen
        store.isFloatingOpen = false
        browser.close(purpose: .cloudflareLogin)
        check(flowOpened && !store.isPresented,
              "G7 a change the user made after the open is kept: they closed the box, so the flow ending does not bring the docked box back")
        store.close()

        // 房 E 倒放卡上的「打開私訊框」（showContent 的閉包那一條）：框本來就開著——立起、回到對話，不照 ⌥⌘ 規則重開（停靠框留在停靠框）。
        store.openDocked()
        store.showBrowser()
        settings.form = .tent
        desk.showContent { store.isBrowsing = false }
        check(settings.form == .outerPortrait && store.isOpen && !store.isFloatingOpen && !store.isBrowsing,
              "G8 the tent card's 打開私訊框 stands up and switches to the chat without reopening the box (a docked box stays docked)")
        store.close()
    }

    // MARK: - F 畫面證據（PNG）

    @MainActor static func evidence(_ check: Checker, fixture: Fixture, _ freshDefaults: (String) -> UserDefaults) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"], !folder.isEmpty else {
            check.skip("F 畫面證據：沒有 TATWO2_SELFTEST_ARTIFACTS（不是 lead-verify 跑的）")
            return
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = fixture.model, thread = fixture.thread
        let store = GlobalDMStore(defaults: freshDefaults("shot"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let secondary = GlobalDMStore(defaults: freshDefaults("shotRight"), chatGPTAllowed: { true }, directKeys: false)
        secondary.attach(model)
        secondary.select(.thread(thread))

        func shoot(_ name: String, form: GlobalDMForm, open: Bool = false, dark: Bool = false) -> Bool {
            let margin = GlobalDMLayout.margin
            let size = CGSize(width: form.size.width + margin * 2, height: form.size.height + margin * 2)
            let view = GlobalDMPhoneBox(store: store, model: model, surface: .floating, form: form,
                                        secondary: form.isDuo ? secondary : nil)
                .environment(\.globalDMStripPinnedOpen, open)
                .frame(width: form.size.width, height: form.size.height)
                .padding(margin)
                // cacheDisplay 只畫 hosting view；視窗的深色底不會進 PNG，需把同一個顏色 token 放進截圖根視圖。
                .background(dark ? LiquidGlassTokens.browserOmniboxDarkTint : Color.clear)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            let url = out.appendingPathComponent(name)
            do { try png.write(to: url) } catch { return false }
            print("W184FORMS NOTE evidence \(url.path)")
            if dark && !TatwoThemeSelfTestScope.hasReadableDarkPixels(bitmap) { return false }
            return bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height)
        }
        var written: [String] = []
        for form in GlobalDMForm.allCases {
            if shoot("form-\(form.rawValue).png", form: form) { written.append(form.rawValue) }
            check(TatwoThemeSelfTestScope.withDarkAppearance {
                shoot("form-\(form.rawValue)-dark.png", form: form, dark: true)
            }, "I3 \(form.rawValue) darkAqua evidence")
        }
        check(written == GlobalDMForm.allCases.map(\.rawValue), "F1 each of the four forms rendered to PNG (top bar folded)", "\(written)")
        check(shoot("topbar-open-outerPortrait.png", form: .outerPortrait, open: true), "F2 outer portrait with the strip open rendered to PNG")
        store.browsesBeside = true
        store.showBrowser()
        let duo = shoot("innerLandscape-two-columns-browser.png", form: .innerLandscape)
        store.isBrowsingBeside = false
        store.browsesBeside = false
        check(duo, "F3 inner landscape, one top bar over two columns (chat | Browser), rendered to PNG")
        await slideRenderChecks(check, freshDefaults, store: store, out: out)
        placementEvidence(check, store: store, model: model, out: out)
    }

    // MARK: - D 拖、縮放（W184 G1b 的自測在 GlobalDMFormsGripAcceptance.swift）

    /// 某個螢幕 visibleFrame 裡浮動框預設的位置（右下角，內縮 24；跟面板控制器同一條算法）。
    static func floatingStandard(_ form: GlobalDMForm, in visible: CGRect) -> CGRect {
        let size = GlobalDMDeskLayout.fitted(form.size, in: visible)
        return CGRect(x: visible.maxX - GlobalDMLayout.floatingInset - size.width, y: visible.minY + GlobalDMLayout.floatingInset,
                      width: size.width, height: size.height)
    }

    @MainActor static func placementEvidence(_ check: Checker, store: GlobalDMStore, model: ChatPageModel, out: URL) {
        let area = CGRect(x: 0, y: 0, width: 1_440, height: 1_000)
        let base = floatingStandard(.outerPortrait, in: area)
        var small = GlobalDMBoxPlacement.standard
        small.scale = 0.7
        var large = GlobalDMBoxPlacement.standard
        large.scale = 1.3
        var corner = GlobalDMBoxPlacement.standard
        let topLeft = CGRect(x: area.minX, y: area.maxY - base.height, width: base.width, height: base.height)
        corner.offset = GlobalDMBoxPlacement.offset(of: topLeft, reference: area)
        var written: [String] = []
        for (name, placement) in [("placement-scale-0.7.png", small), ("placement-scale-1.3.png", large), ("placement-dragged-top-left.png", corner)] {
            let box = placement.box(standard: base, reference: area, bounds: area)
            let view = ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.primary.opacity(0.06))
                GlobalDMPhoneBox(store: store, model: model, surface: .floating, form: .outerPortrait)
                    .frame(width: box.width, height: box.height)
                    .padding(.leading, box.minX - area.minX)
                    .padding(.top, area.maxY - box.maxY)
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            guard let rendered = GlobalDMChatAcceptance.renderSync(view, size: area.size),
                  let png = rendered.bitmap.representation(using: .png, properties: [:]) else { continue }
            rendered.close()
            do {
                try png.write(to: out.appendingPathComponent(name))
                print("W184FORMS NOTE evidence \(out.appendingPathComponent(name).path)")
                written.append(name)
            } catch {}
        }
        // W184 F 小修正：內橫縮到 0.8 倍的樣子（左欄輸入列：記憶膠囊先縮、模型名不截）。
        let shrunk = GlobalDMBoxPlacement.sized(GlobalDMForm.innerLandscape.size, factor: 0.8)
        let landscape = GlobalDMPhoneBox(store: store, model: model, surface: .floating, form: .innerLandscape)
            .frame(width: shrunk.width, height: shrunk.height)
            .padding(GlobalDMLayout.margin)
        if let rendered = GlobalDMChatAcceptance.renderSync(landscape, size: CGSize(width: shrunk.width + GlobalDMLayout.margin * 2,
                                                                                   height: shrunk.height + GlobalDMLayout.margin * 2)),
           let png = rendered.bitmap.representation(using: .png, properties: [:]) {
            rendered.close()
            if (try? png.write(to: out.appendingPathComponent("innerLandscape-scale-0.8.png"))) != nil {
                print("W184FORMS NOTE evidence \(out.appendingPathComponent("innerLandscape-scale-0.8.png").path)")
                written.append("innerLandscape-scale-0.8.png")
            }
        }
        check(written.count == 4, "D11 PNGs: scaled to 0.7, scaled to 1.3, dragged to the top-left corner, inner landscape at 0.8", "\(written)")
    }

    // MARK: - H 滑的樣子真的畫出來（W184 F3：真的面板控制器、圖層台；時鐘由自測推）

    /// 外直→內橫、內橫→內直、內直→倒放、倒放→外直：真的面板上的圖層台在 t＝0.03／0.08／0.14／0.24／0.6 秒各畫一張、排成一排的 PNG；
    /// 動畫中台上的圖層只有位置、大小、透明度的動畫（沒有 transform／3D／縮放／旋轉、沒有遮罩），底下真的框沒有動畫。
    @MainActor static func slideRenderChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, store: GlobalDMStore,
                                             out: URL) async {
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("slideShots"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        panels.install()
        defer {
            store.isFloatingOpen = false
            panels.uninstall()
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true }
        guard let panel = panels.floatingPanelForTesting, panel.isVisible, let canvas = panel.contentView as? GlobalDMPanelCanvas else {
            return check.skip("H3 畫面證據：這個環境開不出浮動框（沒有畫面環境）")
        }
        panel.alphaValue = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        panel.makeFirstResponder(nil)
        let clock = TestClock()
        panels.formMotion.clock = { clock.now }
        panels.formMotion.manualTime = true
        defer {
            panels.formMotion.manualTime = false
            panels.formMotion.clock = { CACurrentMediaTime() }
        }
        let margin = GlobalDMLayout.margin
        var strips: [String] = [], issues: [String] = []
        for (from, to) in [(GlobalDMForm.outerPortrait, GlobalDMForm.innerLandscape), (.innerLandscape, .innerPortrait),
                           (.innerPortrait, .tent), (.tent, .outerPortrait)] {
            let before = panel.frame
            panels.prepareForm()
            settings.form = to
            panels.applyForm(.between(from, to))
            // W184 AB：新的樣子在動畫開始之後才拍（run loop 的下一輪）；時鐘停著＝在 t＝0 交進來（跟當場拍一樣）。
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            guard let stage = canvas.stage, let placed = panels.placedPanelFrameForTesting() else { continue }
            let region = before.union(placed).insetBy(dx: -margin, dy: -margin)
            let local = NSRect(x: region.minX - panel.frame.minX, y: region.minY - panel.frame.minY, width: region.width, height: region.height)
            var reps: [NSBitmapImageRep] = []
            for t in sampleTimes {
                stage.show(at: t)
                if [0.08, 0.14, 0.24].contains(t) {
                    issues += stageIssues(stage).map { "\(to.rawValue)@\(t): \($0)" }
                    issues += layerIssues(canvas.host.layer, skip: isCaret).map { "host \(to.rawValue)@\(t): \($0)" }
                }
                guard let rep = canvas.bitmapImageRepForCachingDisplay(in: local) else { continue }
                stage.render(into: rep, region: local, underlay: NSColor.windowBackgroundColor.cgColor)
                reps.append(rep)
            }
            clock.now += 1
            panels.formMotion.tick()   // 停下
            let name = "slide-\(from.rawValue)-to-\(to.rawValue).png"
            if reps.count == sampleTimes.count, let png = strip(reps, size: local.size) {
                do {
                    try png.write(to: out.appendingPathComponent(name))
                    print("W184FORMS NOTE evidence \(out.appendingPathComponent(name).path)")
                    strips.append(name)
                } catch {}
            }
        }
        check(issues.isEmpty,
              "H2 while sliding the stage layers only animate position, size and opacity (no transform, 3D, scale, rotation or mask) and the real box underneath does not animate",
              issues.prefix(8).joined(separator: "; "))
        check(strips.count == 4, "H3 each slide drawn from the real panel's layer stage at 0.03 / 0.08 / 0.14 / 0.24 / 0.6 s into a PNG strip", "\(strips)")
        settings.form = .outerPortrait
        panels.applyForm(.between(.outerPortrait, .outerPortrait, animated: false))
    }

    /// 幾張畫面並排成一張（中間留 24 的空白）。
    @MainActor static func strip(_ reps: [NSBitmapImageRep], size: CGSize) -> Data? {
        let gap: CGFloat = 24
        let width = Int(ceil(size.width * CGFloat(reps.count) + gap * CGFloat(max(0, reps.count - 1))))
        let height = Int(ceil(size.height))
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, rep) in reps.enumerated() {
            let x = CGFloat(index) * (size.width + gap)
            rep.draw(in: NSRect(x: x, y: 0, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }

    /// 圖層樹裡動畫中不准有的東西：不是單位矩陣的 transform／sublayerTransform、畫布與框那兩層的遮罩、任何進行中的動畫。
    /// skip＝整塊跳過的圖層（只給系統自己的文字插入點：輸入框游標的閃爍不是換形態的動畫）；每一條寫出它屬於哪個 view。
    @MainActor static func layerIssues(_ root: CALayer?, skip: (CALayer) -> Bool = { _ in false }) -> [String] {
        var issues: [String] = []
        var stack: [(CALayer, Int, String)] = root.map { [($0, 0, "")] } ?? []
        var visited = 0
        while let item = stack.popLast(), visited < 20_000 {
            visited += 1
            let (layer, depth, owner) = item
            if skip(layer) { continue }
            let here = layer.delegate.map { String(describing: type(of: $0 as AnyObject)) } ?? owner
            let name = "\(type(of: layer))\(layer.name.map { "(\($0))" } ?? "")" + (here.isEmpty ? "" : " in \(here)")
            if !CATransform3DIsIdentity(layer.transform) { issues.append("transform \(name)") }
            if !CATransform3DIsIdentity(layer.sublayerTransform) { issues.append("sublayerTransform \(name)") }
            if depth < 2, layer.mask != nil { issues.append("mask \(name)") }
            for key in layer.animationKeys() ?? [] { issues.append("animation \(key) on \(name)") }
            stack.append(contentsOf: (layer.sublayers ?? []).map { ($0, depth + 1, here) })
        }
        return issues
    }

    /// 系統的文字插入點（輸入框的游標，NSTextInsertionIndicator）：它自己閃爍的不透明度動畫不是換形態的動畫。
    @MainActor static func isCaret(_ layer: CALayer) -> Bool {
        guard let delegate = layer.delegate else { return false }
        return String(describing: type(of: delegate as AnyObject)).contains("InsertionIndicator")
    }

    /// W184 F3：圖層台上只准位置、大小、透明度的動畫（keyPath 白名單）；transform／sublayerTransform 一律單位矩陣（沒有 3D、旋轉、縮放）；沒有遮罩。
    @MainActor static func stageIssues(_ stage: GlobalDMFormStage) -> [String] {
        let allowed: Set<String> = ["position.x", "position.y", "bounds.size.width", "bounds.size.height", "opacity"]
        var issues: [String] = []
        for layer in stage.allLayers {
            if !CATransform3DIsIdentity(layer.transform) { issues.append("transform on a stage layer") }
            if !CATransform3DIsIdentity(layer.sublayerTransform) { issues.append("sublayerTransform on a stage layer") }
            if layer.mask != nil { issues.append("mask on a stage layer") }
            for key in layer.animationKeys() ?? [] {
                let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath ?? "?"
                if !allowed.contains(path) { issues.append("animation \(key) (\(path)) on a stage layer") }
            }
        }
        return issues
    }

    /// 台停下前最後一格畫一張（box＝螢幕座標；先鋪台的底色）。
    @MainActor static func renderStage(_ stage: GlobalDMFormStage, box: CGRect, panel: NSWindow, canvas: GlobalDMPanelCanvas) -> NSBitmapImageRep? {
        let local = NSRect(x: box.minX - panel.frame.minX, y: box.minY - panel.frame.minY, width: box.width, height: box.height)
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: local) else { return nil }
        stage.render(into: rep, region: local, underlay: stage.surface.fill)
        return rep
    }

    /// 真的框（停下之後）同一塊畫一張，疊在同一個底色上（玻璃主題拍不進系統玻璃：兩邊都鋪台的底色才比得到內容）。
    @MainActor static func renderHost(canvas: GlobalDMPanelCanvas, box: CGRect, panel: NSWindow, underlay: CGColor) -> NSBitmapImageRep? {
        let local = NSRect(x: box.minX - panel.frame.minX, y: box.minY - panel.frame.minY, width: box.width, height: box.height)
        guard let raw = canvas.bitmapImageRepForCachingDisplay(in: local), let result = canvas.bitmapImageRepForCachingDisplay(in: local),
              let context = NSGraphicsContext(bitmapImageRep: result) else { return nil }
        canvas.cacheDisplay(in: local, to: raw)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let whole = CGRect(x: 0, y: 0, width: result.pixelsWide, height: result.pixelsHigh)
        context.cgContext.clear(whole)
        context.cgContext.setFillColor(underlay)
        context.cgContext.fill(whole)
        raw.draw(in: NSRect(origin: .zero, size: local.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return result
    }

    /// 兩張同樣大小、同樣格式的圖比像素：每 3 像素取一點，在另一張 ±2 像素（1pt）內找最像的，色版差超過 40 的算一個不一樣。
    @MainActor static func pixelDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (bad: Int, total: Int, worst: Int)? {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bitsPerSample == 8, b.bitsPerSample == 8, !a.isPlanar, !b.isPlanar,
              a.samplesPerPixel == b.samplesPerPixel, a.samplesPerPixel >= 3, a.bitmapFormat == b.bitmapFormat,
              let da = a.bitmapData, let db = b.bitmapData else { return nil }
        let spp = a.samplesPerPixel, ra = a.bytesPerRow, rb = b.bytesPerRow
        let offset = a.hasAlpha && a.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        let reach = 2, threshold = 40
        var bad = 0, total = 0, worst = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: a.pixelsWide, by: 3) {
                total += 1
                let pa = da + y * ra + x * spp + offset
                var best = Int.max
                search: for dy in -reach...reach {
                    let yy = y + dy
                    guard yy >= 0, yy < b.pixelsHigh else { continue }
                    for dx in -reach...reach {
                        let xx = x + dx
                        guard xx >= 0, xx < b.pixelsWide else { continue }
                        let pb = db + yy * rb + xx * spp + offset
                        var diff = 0
                        for c in 0..<3 { diff = max(diff, abs(Int(pa[c]) - Int(pb[c]))) }
                        if diff < best { best = diff }
                        if best <= threshold { break search }
                    }
                }
                if best > threshold {
                    bad += 1
                    worst = max(worst, best)
                }
            }
        }
        return (bad, total, worst)
    }

    // MARK: - H 真的面板（W184 F3：圖層台；修正單 GPT-6 審查 #6、查證 #10–#14）

    /// 真的面板上的一段轉換（時鐘由自測推：同一時刻比圖層台與模型）記下來的東西。
    struct CanvasRun {
        var old = NSRect.zero, startBox = NSRect.zero, startCanvas = NSRect.zero
        var frames: [NSRect] = []
        var worst: CGFloat = 0, sampleWorst: CGFloat = 0, turnWorst: CGFloat = 0
        var steps = 0
        var contained = true, pinned = true, wired = true, hidden = true, masking = true, exact = true, corner = true
        var opacities: [Double] = []
        var duos: [Double] = []
        var layers: [String] = []
        var columns: [String] = []
        var samples: [String] = []
        var turnJump: CGFloat = 99
        var grewAtTurn = false
        var turnHidden = false
        /// 真的框排版幾次：形態改之前拍舊的樣子、開始、動畫期間、轉向、停下。
        var capture = 0, start = 0, during = 0, turn = 0, stop = 0, afterStop = 0
        var pixels = "-"
        var pixelOK = false
        var settled = false
        var startTrace: [String] = []
        var stopTrace = ""
        var layouts: String { "capture=\(capture) start=\(start) during=\(during) turn=\(turn) stop=\(stop) afterStop=\(afterStop)" }
    }

    @MainActor static func canvasChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel,
                                        engine: ChatLiveEngine? = nil) async {
        let store = GlobalDMStore(defaults: freshDefaults("canvas"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("canvasDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        panels.install()
        defer {
            store.close()
            panels.uninstall()
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.boxPanelForTesting?.isVisible == true }
        guard let panel = panels.boxPanelForTesting, let canvas = panel.contentView as? GlobalDMPanelCanvas else {
            return check.skip("H4 真的面板：這個環境開不出浮動框（沒有畫面環境）")
        }
        panel.alphaValue = 0   // 自測不在螢幕上閃
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        panel.makeFirstResponder(nil)   // 輸入框不拿游標（閃爍的插入點是系統自己的動畫，不是轉換）
        let clock = TestClock()
        panels.formMotion.clock = { clock.now }
        panels.formMotion.manualTime = true
        defer {
            panels.formMotion.manualTime = false
            panels.formMotion.clock = { CACurrentMediaTime() }
        }
        let margin = GlobalDMLayout.margin
        let mask = GlobalDMNativePageMask.shared
        // 查證 #10：真的面板的畫布裡放一個 Browser 頁面容器（一頁假網頁）與一個倒放影片容器（一塊色塊）：applyForm 遮蔽藏的 host
        // 真的是這個畫布——轉換一開始就藏、轉向時照樣藏、停下才回來。
        let page = DMBrowserPageContainer(frame: NSRect(x: 40, y: 40, width: 160, height: 160))
        let pageView = NSView(frame: page.bounds)
        page.addSubview(pageView)
        let tent = DMTentVideoContainer(frame: NSRect(x: 220, y: 40, width: 160, height: 90))
        let video = NSView(frame: tent.bounds)
        tent.addSubview(video)
        canvas.addSubview(page)
        canvas.addSubview(tent)
        defer {
            page.removeFromSuperview()
            tent.removeFromSuperview()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))   // 加進畫布的兩個容器先排好（不算進第一段的排版次數）
        /// 自測的畫面證據（有 TATWO2_SELFTEST_ARTIFACTS 才寫；假的對話內容）。
        let artifacts = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        func dump(_ rep: NSBitmapImageRep?, _ name: String) {
            guard let artifacts, let rep, let png = rep.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try? png.write(to: artifacts.appendingPathComponent(name))
        }

        /// 一段轉換：形態一改（willSet）先拍舊的樣子、applyForm 換畫布並排一次版；(b) 取樣 0.03／0.08／0.14／0.24／0.6 秒圖層的 presentation；
        /// 之後每 1/60 秒一格：台上的框＝模型那一刻的框（<1pt）、畫布包住框、右下角不動、圓角 52、真的框透明度 0 而且不排版、原生頁藏著；
        /// 最後一格台停在終點畫一張，停下（換回真的框）再畫一張比（c）。
        func run(_ transition: GlobalDMFormTransition, turnAt: Int? = nil, turnTo: GlobalDMForm = .innerPortrait,
                 layersAt: Set<Int> = [], columnsAt: Set<Int> = [], label: String? = nil) -> CanvasRun {
            var result = CanvasRun()
            let host = canvas.host
            result.old = panel.frame.insetBy(dx: margin, dy: margin)
            result.frames = [panel.frame]
            var count = host.layoutCount
            panels.prepareForm()   // 跟 GlobalDMDeskController.setForm 一樣：形態改之前先拍舊的樣子（不排版）
            settings.form = transition.to
            result.capture = host.layoutCount - count
            count = host.layoutCount
            panels.applyForm(transition)
            result.start = host.layoutCount - count
            result.startTrace = panels.lastStartTrace
            if result.frames.last != panel.frame { result.frames.append(panel.frame) }
            guard let stage = canvas.stage, let plan = panels.formMotion.plan else {
                result.wired = false
                return result
            }
            result.startBox = stage.presentedBox
            result.startCanvas = panel.frame
            result.hidden = pageView.isHidden && video.isHidden   // 查證 #10：applyForm 一回來（同一格）就藏好了
            result.masking = mask.isMasking
            result.wired = host.alphaValue == 0 && panels.formMotion.surface == .floating
            // (b) 圖層的 presentation 位置＝模型那一刻的框（<1pt）。
            for t in sampleTimes {
                stage.show(at: t)
                let shown = stage.presentedBox, want = plan.frame(at: t).box
                result.sampleWorst = max(result.sampleWorst, deviation(shown, want))
                result.samples.append(String(format: "%.2f:%.2f", t, Double(deviation(shown, want))))
            }
            stage.show(at: panels.formMotion.elapsed)
            count = host.layoutCount
            var landing = transition.to
            while panels.formMotion.isAnimating, result.steps < 120 {
                if let turnAt, result.steps == turnAt, let current = canvas.stage {
                    // 轉向那一刻（時鐘不動）：台上的框、前一段在那一刻的框、新一段的起點三個一樣（<1pt）；之後照新的一段走（速度接得上）。
                    let before = current.presentedBox, canvasBefore = panel.frame
                    result.during += host.layoutCount - count
                    let turnCount = host.layoutCount
                    settings.form = turnTo
                    panels.applyForm(.between(landing, turnTo))
                    result.turn = host.layoutCount - turnCount
                    count = host.layoutCount
                    landing = turnTo
                    let after = current.presentedBox
                    if let plan = panels.formMotion.plan, plan.segments.count >= 2, let now = panels.formMotion.current {
                        let new = plan.segments[plan.segments.count - 1], previous = plan.segments[plan.segments.count - 2]
                        let end = previous.frame(at: new.start - previous.start).box, begin = new.frame(at: 0).box
                        result.turnJump = max(deviation(before, after), deviation(after, begin), deviation(end, begin), deviation(after, now.box))
                        for dt in [0.03, 0.08, 0.14, 0.24] {
                            current.show(at: new.start + dt)
                            result.turnWorst = max(result.turnWorst, deviation(current.presentedBox, plan.frame(at: new.start + dt).box))
                        }
                        current.show(at: panels.formMotion.elapsed)
                    }
                    result.grewAtTurn = panel.frame != canvasBefore
                    result.turnHidden = pageView.isHidden && video.isHidden && mask.isMasking && panels.formMotion.isAnimating
                    if result.frames.last != panel.frame { result.frames.append(panel.frame) }
                }
                if let plan = panels.formMotion.plan, plan.isSettled(at: panels.formMotion.elapsed + 1.0 / 60), let current = canvas.stage {
                    // 最後一格：台停在終點畫一張；停下（同一個呼叫裡換回真的框、排回新框高）再畫真的框（c）。
                    result.during += host.layoutCount - count
                    let box = plan.target.insetBy(dx: 3, dy: 3)
                    current.show(at: plan.end)
                    let staged = renderStage(current, box: box, panel: panel, canvas: canvas)
                    let underlay = current.surface.fill
                    let stopCount = host.layoutCount
                    clock.now += 1.0 / 60
                    panels.formMotion.tick()
                    result.stop = panels.lastStopLayouts   // 停下那一次本身（之後轉換結束的整理、配對碼恢復顯示另算）
                    result.afterStop = host.layoutCount - stopCount - panels.lastStopLayouts
                    result.stopTrace = panels.lastStopTrace
                    if result.frames.last != panel.frame { result.frames.append(panel.frame) }
                    let real = renderHost(canvas: canvas, box: box, panel: panel, underlay: underlay)
                    if let label {
                        dump(staged, "stop-\(label)-stage.png")
                        dump(real, "stop-\(label)-real.png")
                    }
                    if let staged, let real, let diff = pixelDifference(staged, real) {
                        result.pixelOK = diff.total > 100 && Double(diff.bad) <= Double(diff.total) * 0.005
                        result.pixels = "outliers \(diff.bad)/\(diff.total) worst \(diff.worst)"
                    } else {
                        result.pixels = "render failed staged=\(staged != nil) real=\(real != nil)"
                    }
                    break
                }
                step(clock, panels.formMotion)
                result.steps += 1
                if result.frames.last != panel.frame { result.frames.append(panel.frame) }
                guard panels.formMotion.isAnimating, let model = panels.formMotion.current, let current = canvas.stage else { break }
                let now = current.presentedBox
                result.worst = max(result.worst, deviation(now, model.box))
                result.contained = result.contained && panel.frame.insetBy(dx: -0.5, dy: -0.5).contains(now.insetBy(dx: -margin, dy: -margin))
                result.pinned = result.pinned && abs(now.maxX - result.old.maxX) <= 0.5 && abs(now.minY - result.old.minY) <= 0.5
                result.corner = result.corner && abs(current.presentedRadius - 52) < 0.01
                result.wired = result.wired && host.alphaValue == 0 && panels.formMotion.surface == .floating
                result.hidden = result.hidden && pageView.isHidden && video.isHidden
                result.masking = result.masking && mask.isMasking
                result.exact = result.exact && (same(now, result.old) || same(now, panels.placedPanelFrameForTesting()?.insetBy(dx: margin, dy: margin) ?? .zero))
                result.opacities.append(Double(current.presentedOpacity.whole))
                result.duos.append(model.duo)
                if layersAt.contains(result.steps) {
                    result.layers += stageIssues(current).map { "step \(result.steps): \($0)" }
                    result.layers += layerIssues(host.layer, skip: isCaret).map { "step \(result.steps) host: \($0)" }
                }
                if columnsAt.contains(result.steps) {
                    let want = GlobalDMPhoneLook(form: model.form, slide: model, size: model.box.size).chatWidth(in: model.box.width)
                    let got = current.presentedColumn
                    result.columns.append("step \(result.steps) duo \(String(format: "%.2f", model.duo)): want \(Int(want)) got \(Int(got))"
                                          + (abs(got - want) <= 1 ? "" : " ✗"))
                }
            }
            result.settled = !panels.formMotion.isAnimating && canvas.stage == nil && host.alphaValue == 1 && host.frame == canvas.bounds
            return result
        }

        // T1 外直 → 內橫（滑；框變矮：對話本體排成 max(舊高, 新高)、停下排回新框高）。
        let first = run(.between(.outerPortrait, .innerLandscape), layersAt: [4, 9, 15], columnsAt: [6, 12], label: "outer-to-land")
        let placedFirst = panels.placedPanelFrameForTesting()
        let restFirst = canvas.host.frame == canvas.bounds && canvas.stage == nil && canvas.host.alphaValue == 1
            && !pageView.isHidden && !video.isHidden && !mask.isMasking
        print("W184FORMS NOTE H4 samples \(first.samples.joined(separator: " ")) layouts \(first.layouts) pixels \(first.pixels) start \(String(format: "%.1f", panels.lastStartCost * 1000))ms stop \(String(format: "%.1f", panels.lastStopCost * 1000))ms")
        print("W184FORMS NOTE H10 start trace \(first.startTrace) stop trace \(first.stopTrace)")
        check(same(first.startBox, first.old)
              && same(first.startCanvas, first.old.union(placedFirst?.insetBy(dx: margin, dy: margin) ?? .zero).insetBy(dx: -margin, dy: -margin), 1)
              && first.frames.count == 3,
              "H4 the canvas is swapped in once (old box ∪ new box + shadow margin) with the box on screen exactly where it was; the panel changes size exactly twice per transition (start, stop), never in between",
              "start=\(first.startBox) old=\(first.old) canvas=\(first.startCanvas) frames=\(first.frames.count)")
        check(first.steps > 20 && first.worst < 1 && first.sampleWorst < 1 && first.contained && first.pinned && first.wired && first.corner,
              "H4 (b) the layer stage runs the model: at 0.03 / 0.08 / 0.14 / 0.24 / 0.6 s and at every 1/60 s step the stage's presentation box is the model's box (<1pt), the bottom-right corner stays, the corner stays 52, and the real box sits underneath at opacity 0",
              "steps=\(first.steps) worst=\(first.worst) samples=\(first.samples) contained=\(first.contained) pinned=\(first.pinned) wired=\(first.wired) corner=\(first.corner)")
        // 開始：新形態、剛好是新框的大小排一次（原本在最底的列表捲回最底時懶載入的列要再排一次）；都在換畫布的那一次畫面更新裡、動畫開始之前。
        // 停下：大小不變＝不用再排。動畫期間一次都不准。
        check(first.capture == 0 && first.start >= 1 && first.start <= 3 && first.during == 0 && first.stop <= 1,
              "H10 (a) the real SwiftUI box lays out only when the slide starts (the new form at exactly the new size, once more when a list is kept at its bottom) — never during the slide, and the stop needs no new layout (same size; capturing the old look before the form changes lays out nothing)",
              "\(first.layouts) start \(first.startTrace) stop \(first.stopTrace)")
        check(first.pixelOK && first.settled,
              "H11 (c) the stop frame: the stage's last frame and the real box shown in its place match inside the box (1pt tolerance, colour within 40/255, ≤0.5% outliers)",
              "\(first.pixels) settled=\(first.settled)")
        // 拍下來的圖：圓角外那四小塊是透明的（拍到的是框的陰影：台上的框比圖寬、高時角落會多一圈弧線——v6 出內橫 0.24 秒的畫面看得到），框裡不透明。
        if let shot = canvas.recentCaptures.last {
            let rep = NSBitmapImageRep(cgImage: shot)
            let w = rep.pixelsWide, h = rep.pixelsHigh
            let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)].map { rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1 }
            let inside = [(w / 2, 4), (4, h / 2), (w - 5, h / 2), (w / 2, h - 5)].map { rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0 }
            check(corners.allSatisfy { $0 < 0.02 } && inside.allSatisfy { $0 > 0.98 },
                  "H11 the pictures have nothing outside the 52 corner (transparent: no shadow arc when the stage's box is bigger than a picture) and are opaque inside",
                  "corners=\(corners.map { String(format: "%.2f", $0) }) inside=\(inside.map { String(format: "%.2f", $0) }) \(w)×\(h)")
        } else {
            check(false, "H11 the pictures have nothing outside the 52 corner (transparent: no shadow arc when the stage's box is bigger than a picture) and are opaque inside",
                  "no capture")
        }
        check(first.duos.contains { $0 > 0.05 && $0 < 0.95 } && first.columns.count == 2 && !first.columns.contains { $0.hasSuffix("✗") },
              "H7 the chat column on the stage follows the model: mid-way it is as wide as that moment's frame says (the column narrows from the whole box to the left column, ≤1pt), not the destination drawn at once",
              first.columns.joined(separator: "; "))
        check(first.layers.isEmpty && first.hidden && first.masking && restFirst,
              "H2 on the real panel the stage only animates position, size and opacity (no transform, 3D, scale, rotation or mask) and the real box does not animate; H9 the Browser page and the tent video in the panel's canvas stay hidden the whole slide and are shown again when it stops",
              "layers=\(first.layers.prefix(6)) hidden=\(first.hidden) masking=\(first.masking) rest=\(restFirst)")

        // 量測（W184 F3 開始的成本）：停著的真的框，用 cacheDisplay（AppKit 重畫一次）與 CALayer.render（只合成現有的圖層內容）各拍一次，
        // 比時間與像素；紙紋底圖第一次畫要多久。只記下來（NOTE），選哪一種看這裡的數字。
        do {
            let margin = GlobalDMLayout.margin
            let box = NSRect(x: margin, y: margin, width: canvas.bounds.width - margin * 2, height: canvas.bounds.height - margin * 2)
            var t0 = CACurrentMediaTime()
            let cached = canvas.host.bitmapImageRepForCachingDisplay(in: box)
            if let cached { canvas.host.cacheDisplay(in: box, to: cached) }
            let cacheMs = (CACurrentMediaTime() - t0) * 1000
            t0 = CACurrentMediaTime()
            var rendered: NSBitmapImageRep?
            if let rep = canvas.host.bitmapImageRepForCachingDisplay(in: box), let context = NSGraphicsContext(bitmapImageRep: rep),
               let layer = canvas.host.layer {
                let cg = context.cgContext
                let scale = CGFloat(rep.pixelsWide) / box.width
                cg.clear(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                cg.scaleBy(x: scale, y: scale)
                // host 的圖層是 geometryFlipped（左上原點）：先翻過來再畫；框在 host 裡上下都留 margin，所以同一塊。
                cg.translateBy(x: 0, y: box.height)
                cg.scaleBy(x: 1, y: -1)
                cg.translateBy(x: -box.minX, y: -box.minY)
                layer.render(in: cg)
                context.flushGraphics()
                rendered = rep
            }
            let renderMs = (CACurrentMediaTime() - t0) * 1000
            let diff = (cached != nil && rendered != nil) ? pixelDifference(cached!, rendered!) : nil
            dump(cached, "capture-cacheDisplay.png")
            dump(rendered, "capture-layerRender.png")
            t0 = CACurrentMediaTime()
            _ = GlobalDMFormStage.paperImage(size: CGSize(width: 1900, height: 1900), fill: NSColor.white.cgColor, grain: 0.085)
            let paperMs = (CACurrentMediaTime() - t0) * 1000
            // 哪一塊貴：只有框的表面（底色、邊、紙紋、陰影）的一個 view、真的框裡中間 100×100、頂列那一條。
            func timed(_ view: NSView, _ rect: NSRect) -> Double {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return -1 }
                let start = CACurrentMediaTime()
                view.cacheDisplay(in: rect, to: rep)
                return (CACurrentMediaTime() - start) * 1000
            }
            let chromeHost = NSHostingView(rootView: Color.clear.frame(width: box.width, height: box.height)
                .modifier(GlobalDMBoxChrome(cornerRadius: DMPhone.screenRadius)).padding(GlobalDMLayout.margin))
            chromeHost.frame = NSRect(x: 0, y: 0, width: box.width + margin * 2, height: box.height + margin * 2)
            let chromeWindow = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: chromeHost.frame.width, height: chromeHost.frame.height),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
            chromeWindow.isReleasedWhenClosed = false
            chromeWindow.contentView = chromeHost
            chromeWindow.orderFrontRegardless()
            chromeHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let chromeMs = timed(chromeHost, box)
            chromeWindow.orderOut(nil)
            // Retina（2x）要多久：同一塊用 2 倍像素的圖拍（MacBook Air 是 2x）。
            var retinaMs = -1.0
            if let retina = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width * 2), pixelsHigh: Int(box.height * 2), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                retina.size = box.size
                let start = CACurrentMediaTime()
                canvas.host.cacheDisplay(in: box, to: retina)
                retinaMs = (CACurrentMediaTime() - start) * 1000
            }
            print("W184FORMS NOTE F3 capture at 2x (Retina): \(String(format: "%.1f", retinaMs))ms")
            // 2x（Retina）：這台是 1x 螢幕，拍 2x 的圖是「比例不一樣」的路（連 1×1 都要五百多毫秒＝固定成本），不代表 Retina 上真的成本；只記下來。
            if let retina = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width * 2), pixelsHigh: Int(box.height * 2), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                retina.size = box.size
                let start = CACurrentMediaTime()
                canvas.host.cacheDisplay(in: NSRect(x: box.midX, y: box.midY, width: 1, height: 1), to: retina)
                print("W184FORMS NOTE F3 capture 2x on a 1x screen: 1×1 \(String(format: "%.1f", (CACurrentMediaTime() - start) * 1000))ms (scale-mismatch path, not what a Retina screen costs)")
            }
            // 1x 貴在哪：每次拍的固定成本（1×1）、只有對話列表、只有輸入框；再跟 /usr/bin/sample 同步（等它開始取樣）連拍 3.5 秒，
            // 取樣（只有函式名稱與次數，沒有內容）寫進 artifacts。
            let tinyMs = timed(canvas.host, NSRect(x: box.midX, y: box.midY, width: 1, height: 1))
            let list = canvas.scrollLists().max { $0.frame.height < $1.frame.height }
            let listMs = list.map { timed($0, $0.bounds) } ?? -1
            let composer = DMBrowserPhoneAcceptance.views(NSTextView.self, in: canvas.host).max { $0.frame.width < $1.frame.width }
            let composerMs = composer.map { timed($0, $0.visibleRect) } ?? -1
            print("W184FORMS NOTE F3 capture 1x parts: 1×1 \(String(format: "%.1f", tinyMs))ms, chat list only \(String(format: "%.1f", listMs))ms (\(list.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "-")), composer text view only \(String(format: "%.1f", composerMs))ms")
            // 取樣（v8、sample）：一張 1x 的時間大半在 CALayer.render 替有陰影的圖層做高斯模糊。列出真的框裡有陰影的圖層（大小、半徑、顏色的
            // 透明度），比「照原樣拍」與 capture() 的做法（陰影全關）：時間、像素差（輸入框小元件、頁面圓鈕的淡陰影在圖裡少了：最大差多少）。
            var shadowed: [String] = [], shadowCount = 0, shadowArea: CGFloat = 0
            var layerStack: [(CALayer, Int)] = canvas.host.layer.map { [($0, 0)] } ?? []
            while let entry = layerStack.popLast() {
                let (layer, depth) = entry
                if layer.shadowOpacity > 0 {
                    shadowCount += 1
                    let pad = layer.shadowRadius * 3
                    shadowArea += (layer.bounds.width + pad * 2) * (layer.bounds.height + pad * 2)
                    if shadowed.count < 8 {
                        shadowed.append("\(String(describing: type(of: layer)))@\(depth) \(Int(layer.bounds.width))×\(Int(layer.bounds.height)) r\(String(format: "%.0f", layer.shadowRadius)) a\(String(format: "%.2f", layer.shadowColor?.alpha ?? 0))")
                    }
                }
                layerStack.append(contentsOf: (layer.sublayers ?? []).map { ($0, depth + 1) })
            }
            print("W184FORMS NOTE F3 shadowed layers in the real box: \(shadowCount) (blur area with padding ≈ \(Int(shadowArea / 1000))k pt²), e.g. \(shadowed.joined(separator: "; "))")
            if let raw = canvas.host.bitmapImageRepForCachingDisplay(in: box), let quiet = canvas.host.bitmapImageRepForCachingDisplay(in: box) {
                let t1 = CACurrentMediaTime()
                canvas.host.cacheDisplay(in: box, to: raw)
                let rawMs = (CACurrentMediaTime() - t1) * 1000
                let t2 = CACurrentMediaTime()
                canvas.withShadowsMutedForTesting { canvas.host.cacheDisplay(in: box, to: quiet) }
                let quietMs = (CACurrentMediaTime() - t2) * 1000
                let muted = canvas.lastMutedShadows
                let differs = pixelDifference(raw, quiet)
                var loose = 0, largest = 0
                if let a = raw.bitmapData, let b = quiet.bitmapData, raw.bytesPerRow == quiet.bytesPerRow, raw.pixelsHigh == quiet.pixelsHigh {
                    for index in stride(from: 0, to: raw.bytesPerRow * raw.pixelsHigh, by: raw.samplesPerPixel) {
                        var d = 0
                        for c in 0..<3 { d = Swift.max(d, abs(Int(a[index + c]) - Int(b[index + c]))) }
                        if d > 8 { loose += 1 }
                        largest = Swift.max(largest, d)
                    }
                }
                let restored = canvas.host.layer.map { root -> Int in
                    var count = 0, stack = [root]
                    while let layer = stack.popLast() {
                        if layer.shadowOpacity > 0 { count += 1 }
                        stack.append(contentsOf: layer.sublayers ?? [])
                    }
                    return count
                } ?? -1
                let detail = "\(String(format: "%.1f", quietMs))ms vs \(String(format: "%.1f", rawMs))ms as is, \(muted) layer(s) muted and \(restored) back, outliers(>40) \(differs.map { "\($0.bad)/\($0.total)" } ?? "n/a"), pixels differing by more than 8/255: \(loose) of \(raw.pixelsWide * raw.pixelsHigh), largest difference \(largest)/255"
                print("W184FORMS NOTE F3 capture with every shadow muted: \(detail)")
                check(muted >= 1 && restored == shadowCount && differs.map { $0.total > 100 && $0.bad == 0 } == true && largest <= 40,
                      "F3 capture: every shadow is muted while capturing (CPU blur is most of a capture) and put back right after; the picture differs from the as-is one only in those faint shadows (no pixel over 40/255)",
                      detail)
            }
            let middleMs = timed(canvas.host, NSRect(x: box.midX - 50, y: box.midY - 50, width: 100, height: 100))
            let headerMs = timed(canvas.host, NSRect(x: box.minX, y: box.minY, width: box.width, height: DMPhone.headerHeight))
            print("W184FORMS NOTE F3 capture parts: chrome only \(String(format: "%.1f", chromeMs))ms, middle 100² \(String(format: "%.1f", middleMs))ms, header strip \(String(format: "%.1f", headerMs))ms")
            print("W184FORMS NOTE F3 capture cacheDisplay \(String(format: "%.1f", cacheMs))ms, layer.render \(String(format: "%.1f", renderMs))ms, differ \(diff.map { "\($0.bad)/\($0.total) worst \($0.worst)" } ?? "n/a"), paper 1900² \(String(format: "%.1f", paperMs))ms, glass=\(TatwoActivePalette.current.usesGlass)")
        }

        // T2 內橫 → 外直，減少動態效果（查證 #14：真的面板上跑 .fade）。
        let fade = run(.between(.innerLandscape, .outerPortrait, reduceMotion: true))
        let placedFade = panels.placedPanelFrameForTesting()
        let dipped = (fade.opacities.min() ?? 1) < 0.5 && (fade.opacities.first ?? 0) > 0.9 && (fade.opacities.last ?? 0) > 0.8
        check(fade.steps > 10 && fade.exact && dipped && fade.frames.count == 3 && fade.hidden && fade.settled && fade.pixelOK
              && fade.during == 0 && placedFade.map { same(panel.frame, $0) } == true && !mask.isMasking,
              "H8 reduce motion on the real panel: every frame the stage's box is exactly the old box or the new box (no slide), the whole box fades out and back in, the panel changes size only at start and stop, the real box never lays out in between and the stop frame matches it",
              "steps=\(fade.steps) exact=\(fade.exact) min=\(fade.opacities.min() ?? -1) frames=\(fade.frames.count) \(fade.layouts) \(fade.pixels)")

        // T3 外直 → 內橫，滑到一半轉向內直（框變高：對話本體排成新框高）。
        GlobalDMHostingView.traceLayouts = true
        let turned = run(.between(.outerPortrait, .innerLandscape), turnAt: 9, label: "turn-to-inner")
        GlobalDMHostingView.traceLayouts = false
        let placedTurn = panels.placedPanelFrameForTesting()
        print("W184FORMS NOTE H4 turn jump=\(turned.turnJump) after=\(turned.turnWorst) layouts \(turned.layouts) pixels \(turned.pixels)")
        if turned.during > 0 {
            for line in canvas.host.layoutStacks { print("W184FORMS NOTE H4 turn layout \(line.prefix(1800))") }
        }
        check(turned.turnJump < 1 && turned.turnWorst < 1 && turned.pinned && turned.contained && turned.worst < 1 && turned.turnHidden && turned.hidden
              && turned.frames.count == (turned.grewAtTurn ? 4 : 3) && turned.during == 0 && turned.turn >= 1 && turned.turn <= 3
              && turned.stop <= 1 && turned.corner,
              "H4 (d) turning mid-way (outer portrait → inner landscape → inner portrait): at the turn the stage, the previous segment and the new one agree (<1pt, same moment) and afterwards the stage follows the new segment (<1pt: the springs carry the speed over); the real box lays out once more at the turn and never in between; native pages stay hidden",
              "turnJump=\(turned.turnJump) after=\(turned.turnWorst) pinned=\(turned.pinned) worst=\(turned.worst) grew=\(turned.grewAtTurn) frames=\(turned.frames.count) \(turned.layouts)")
        check(!panels.formMotion.isAnimating && placedTurn.map { same(panel.frame, $0) } == true && turned.settled && turned.pixelOK
              && placedTurn.map { same(canvas.host.frame, NSRect(origin: .zero, size: $0.size)) } == true
              && !mask.isMasking && !pageView.isHidden && !video.isHidden,
              "H5 once it settles the panel is exactly the new box + margin, the real box fills it again (the stage is gone and its last frame matched it) and the native pages are back",
              "panel=\(panel.frame) placed=\(String(describing: placedTurn)) \(turned.pixels)")

        // H1（GPT-6 審查 #6）：捲上去看舊的訊息（離最上面 200pt），滑一整圈（外直→內橫→內直→外直）：一直是同一個輸入框（草稿還在）、
        // 同一個捲動區、沒有被捲回最底；回到外直時離最上面跟開始一樣（≤20pt：列表是 LazyVStack，沒畫到的列高度是估計的）。
        settings.form = .outerPortrait
        panels.applyForm(.between(.innerPortrait, .outerPortrait, animated: false))
        store.setDraft("W184F3 草稿還在", for: .assistant)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        if let composer = DMBrowserPhoneAcceptance.views(NSTextView.self, in: canvas.host).first(where: { $0.string == "W184F3 草稿還在" }) {
            let list = DMBrowserPhoneAcceptance.views(NSScrollView.self, in: canvas.host)
                .filter { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 40 }
                .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
            func fromBottom(_ scroll: NSScrollView) -> CGFloat {
                let visible = scroll.contentView.bounds, height = scroll.documentView?.frame.height ?? 0
                return scroll.documentView?.isFlipped == true ? height - visible.maxY : visible.minY
            }
            func fromTop(_ scroll: NSScrollView) -> CGFloat {
                let visible = scroll.contentView.bounds, height = scroll.documentView?.frame.height ?? 0
                return scroll.documentView?.isFlipped == true ? visible.minY : height - visible.maxY
            }
            if let list, let document = list.documentView {
                // 先量好最前面幾列的實際高度，再設 200pt 起點；LazyVStack 的初估高度不是可見閱讀位置。
                list.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? 0 : max(0, document.frame.height - list.contentView.bounds.height)))
                list.reflectScrolledClipView(list.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let visible = list.contentView.bounds
                let y = document.isFlipped ? 200 : document.frame.height - visible.height - 200
                list.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
                list.reflectScrolledClipView(list.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let startTop = list.map(fromTop) ?? -1
            let readingStart = list.flatMap { GlobalDMListRows.of($0)?.reading }
            var kept = 0, sameList = list != nil, neverBottom = true, tops: [Int] = []
            for (from, to) in [(GlobalDMForm.outerPortrait, GlobalDMForm.innerLandscape), (.innerLandscape, .innerPortrait), (.innerPortrait, .outerPortrait)] {
                _ = run(.between(from, to))
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if DMBrowserPhoneAcceptance.views(NSTextView.self, in: canvas.host).contains(where: { $0 === composer }), composer.string == "W184F3 草稿還在" {
                    kept += 1
                }
                if let list {
                    sameList = sameList && list.window === panel && DMBrowserPhoneAcceptance.views(NSScrollView.self, in: canvas.host).contains { $0 === list }
                    neverBottom = neverBottom && fromBottom(list) > 20
                    tops.append(Int(fromTop(list)))
                }
            }
            let endTop = list.map(fromTop) ?? -1
            let readingEnd = list.flatMap { GlobalDMListRows.of($0)?.current[readingStart?.id ?? ""] }
            let readingHeld = readingStart.flatMap { start in readingEnd.map { $0.fresh && abs($0.top - start.top) <= 20 } } ?? false
            check(kept == 3 && abs(startTop - 200) <= 2 && sameList && neverBottom && readingHeld,
                  "H1 outer portrait → inner landscape → inner portrait → outer portrait on the real panel: the chat is the same GlobalDMBox all along (same composer view, draft still there), the same scroll view keeps its visible message within 20pt (starts scrolled up 200pt, never snapped to the bottom; raw offsets can change as lazy row heights settle)",
                  "kept=\(kept) top \(startTop)→\(endTop) tops=\(tops) same=\(sameList) neverBottom=\(neverBottom) reading=\(readingStart?.top ?? -1)→\(readingEnd?.top ?? -1)")
        } else {
            check.skip("H1 真的面板：找不到輸入框（這個環境畫不出來）")
        }
        store.setDraft("", for: .assistant)

        // H13（A4：GPT-6 審查 F3 #4）：原本在最底的仍在最底；輸入框在組字（輸入法的 marked text）也不動——每一段（變矮、變高、中途轉向）
        // 結束時看：離最底 ≤2pt、first responder 還是那個輸入框、marked range／組字的字／選取範圍都一樣。
        settings.form = .outerPortrait
        panels.applyForm(.between(.innerPortrait, .outerPortrait, animated: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let lists = canvas.scrollLists()
        let chatList = lists.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        if let chatList, let document = chatList.documentView {
            let visible = chatList.contentView.bounds
            chatList.contentView.scroll(to: NSPoint(x: visible.minX, y: document.isFlipped ? max(0, document.frame.height - visible.height) : 0))
            chatList.reflectScrolledClipView(chatList.contentView)
        }
        store.setDraft("組字", for: .assistant)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let composing = DMBrowserPhoneAcceptance.views(NSTextView.self, in: canvas.host).first { $0.string == "組字" }
        if let composing, let chatList {
            panel.makeFirstResponder(composing)
            composing.setSelectedRange(NSRange(location: 2, length: 0))
            composing.setMarkedText("ㄋㄧˇ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let marked = composing.markedRange(), selected = composing.selectedRange(), text = composing.string
            var notes: [String] = [], held = true
            func look(_ label: String) {
                let bottom = GlobalDMPanelCanvas.distanceFromBottom(chatList)
                let same = panel.firstResponder === composing && composing.hasMarkedText() && composing.markedRange() == marked
                    && composing.selectedRange() == selected && composing.string == text
                held = held && same && bottom <= 2 && chatList.window === panel
                notes.append("\(label): bottom=\(Int(bottom)) same=\(same)")
            }
            _ = run(.between(.outerPortrait, .innerLandscape))
            look("shorter")
            _ = run(.between(.innerLandscape, .innerPortrait))
            look("taller")
            _ = run(.between(.innerPortrait, .outerPortrait), turnAt: 8, turnTo: .innerLandscape)
            look("turned")
            _ = run(.between(.innerLandscape, .outerPortrait))
            look("back")
            check(held,
                  "H13 (A4) a list at its bottom stays at its bottom and a composer mid-IME stays composing through shorter, taller and turned slides: same first responder, same marked range and text, same selection, bottom ≤2pt at the end of every segment",
                  notes.joined(separator: "; "))
            composing.unmarkText()
            panel.makeFirstResponder(nil)
        } else {
            check(false, "H13 (A4) a list at its bottom stays at its bottom and a composer mid-IME stays composing through shorter, taller and turned slides: same first responder, same marked range and text, same selection, bottom ≤2pt at the end of every segment",
                  "composer=\(composing != nil) list=\(chatList != nil)")
        }
        store.setDraft("", for: .assistant)

        // H14（A2：GPT-6 審查 F3 #2）：連續轉向（每 3 格轉一次、40 次）：台上的圖層、拍下來的圖有上限（轉向不累積），停下之後全部放掉。
        settings.form = .outerPortrait
        panels.applyForm(.between(.innerPortrait, .outerPortrait, animated: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        panels.prepareForm()
        settings.form = .innerLandscape
        panels.applyForm(.between(.outerPortrait, .innerLandscape))
        var most = 0, layersMost = 0
        let cycle: [GlobalDMForm] = [.innerPortrait, .outerPortrait, .innerLandscape, .tent]
        for index in 0..<40 {
            for _ in 0..<3 { step(clock, panels.formMotion) }
            guard let stage = canvas.stage else { break }
            most = max(most, stage.pieces.count)
            layersMost = max(layersMost, stage.allLayers.count)
            let from = settings.form, to = cycle[index % cycle.count]
            settings.form = to
            panels.applyForm(.between(from, to))
        }
        weak var lastStage = canvas.stage
        while panels.formMotion.isAnimating { step(clock, panels.formMotion, 0.05) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        print("W184FORMS NOTE H14 40 turns: most pieces \(most), most layers \(layersMost)")
        check(most > 0 && most <= 16 && layersMost <= 40 && canvas.stage == nil && lastStage == nil && canvas.host.alphaValue == 1,
              "H14 (A2) forty quick turns in a row: the stage keeps at most 16 pictures (faded ones are dropped and a fade already running is not restarted; an under-layer only stays while no newer one covers it) and at most 40 layers; once it stops the stage and all its pictures are released",
              "pieces=\(most) layers=\(layersMost) stage=\(canvas.stage != nil) released=\(lastStage == nil)")
        settings.form = .outerPortrait
        panels.applyForm(.between(.innerLandscape, .outerPortrait, animated: false))

        // H12（F3 的 60 格、A3：GPT-6 審查 F3 #3）：真的時鐘、真的螢幕更新（display link）。從「使用者按下去之前」開始量：第一張看得到的畫面
        // 多久出來；動畫期間主執行緒每一格的間隔、真的框排版次數（與時間點）；結束之後一定：不在轉換、圖層台拆掉、真的框透明度 1、遮蔽放掉。
        // 另外一種：動畫中對話一直在長（串流回覆：排版是內容造成的，不是動畫幾何）。
        panels.formMotion.manualTime = false
        panels.formMotion.clock = { CACurrentMediaTime() }
        struct RealRun {
            var firstFrame: Double = -1, fps: Double = 0, longest: Double = 0, frames = 0, during = 0
            var ended = false, start = 0.0, stop = 0.0, updates = 0
            /// 動畫期間那幾次排版在按下去之後幾毫秒（開始時 SwiftUI 晚一拍的更新，還是逐格）。
            var at: [Int] = []
            /// 按下去到開始動的時間拆開：拍舊的樣子（prepareForm）、改形態（desk.form 的連動）、applyForm（排版＋拍新的＋台）。
            var prepare = 0.0, formSet = 0.0, apply = 0.0
            /// W184 AB：第二長的間隔（最長那一個是動畫開始後拍新樣子的那一下：主執行緒忙、畫面伺服器照樣在跑）；拍新樣子花多久；
            /// 新的樣子在動畫開始後多久換上（-1＝這一段沒上台）、用的像素比例。
            var second = 0.0, fresh = 0.0, freshAt = -1.0, freshScale: CGFloat = 0
            /// W184 AB（GPT-6 第三輪 #7）：這一段新的樣子每一次的紀錄（嘗試、拍成、上台、降級分開）；
            /// 框真的動了的第一格（display link 那一格讀圖層台的 presentation：離起點 ≥0.5pt）在按下去之後幾毫秒、那一格的時間。
            var freshLog: [GlobalDMPanelController.FreshRecord] = []
            var firstMove = -1.0, firstMoveStamp: CFTimeInterval = 0, returnedAt: CFTimeInterval = 0
            /// W184 AB（H12 串流真的進畫面）：串流的每一次更新進到列表（列表拿到那一則）、排出位置（遮罩量到它）各花了多久（毫秒；nil＝沒有）。
            var arrivals: [(listed: Double?, laidOut: Double?)] = []
            var reached: Int { arrivals.filter { $0.listed != nil }.count }
            var laidOut: Int { arrivals.filter { $0.laidOut != nil }.count }
            var arrivalText: String {
                guard !arrivals.isEmpty else { return "no content update was sent" }
                func ms(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "never" }
                let each = arrivals.enumerated().map { "#\($0.offset + 1) \(ms($0.element.listed))/\(ms($0.element.laidOut))" }
                return "\(arrivals.count) content updates: reached the list \(reached)/\(arrivals.count), laid out \(laidOut)/\(arrivals.count) "
                    + "(ms after each update, list/laid out: \(each.joined(separator: " ")))"
            }
            /// 逐段斷言：每一段都有一次拍成而且真的上台（延後拍的那一次），沒有降級；框動的第一格在延後拍攝開始之前。
            var freshOK: Bool {
                let deferred = freshLog.filter(\.deferred)
                guard !deferred.isEmpty, deferred.allSatisfy({ $0.outcome == .staged }), freshAt >= 0, firstMove >= 0 else { return false }
                let segments = Set(deferred.map(\.segment))
                return segments.count == deferred.count && firstMoveStamp < (deferred.first?.startedAt ?? 0)
            }
            var freshText: String {
                let records = freshLog.map { "seg \($0.segment) \($0.deferred ? "deferred" : "sync") \($0.outcome) \(Int($0.scale))x" }
                return "[\(records.joined(separator: ", "))] first move \(String(format: "%.0f", firstMove))ms, capture started \(freshLog.first(where: \.deferred).map { String(format: "%.0f", ($0.startedAt - returnedAt) * 1000) } ?? "-")ms after applyForm"
            }
        }
        func realRun(_ from: GlobalDMForm, _ to: GlobalDMForm, stream: Bool = false) -> RealRun {
            var result = RealRun()
            let recorder = GlobalDMFrameRecorder()
            recorder.attach(to: canvas)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            recorder.reset()
            let pressed = CACurrentMediaTime()   // 使用者按下去（setForm 之前）
            panels.prepareForm()
            let prepared = CACurrentMediaTime()
            settings.form = to
            let formed = CACurrentMediaTime()
            panels.applyForm(.between(from, to))
            let returned = CACurrentMediaTime()
            result.returnedAt = returned
            // 框真的動了沒：每一格 display link 讀圖層台 presentation 的框，跟起點比。
            let startBox = canvas.stage?.presentedBox
            recorder.probe = { [weak canvas] in canvas?.stage?.presentedBox }
            result.prepare = (prepared - pressed) * 1000
            result.formSet = (formed - prepared) * 1000
            result.apply = (returned - formed) * 1000
            result.start = (returned - pressed) * 1000
            var streamer: Timer?
            let updates = HandsLocked(0)
            let sent = HandsLocked<[(id: String, at: CFTimeInterval)]>([])
            if stream, let engine, let thread = engine.doc.assistantThreadID {
                let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        updates.update { $0 += 1 }
                        let count = updates.get()
                        let id = "w184f3-stream-\(UUID().uuidString)"
                        // W184 AB（R2 查證）：串流的每一段帶讀得到的「第 1xx 個回答」——後面的 R2 讀畫面時這幾列還留在這條最後面。
                        engine.appendOfflineRows(threadID: thread, rows: [ChatMessage(id: id, role: .assistant,
                                                                                      text: "第 \(100 + count) 個回答（串流中的回覆第 \(count) 段）：動畫期間內容還在長。")])
                        // W184 AB（H12）：照正式的 onChange 通知畫面（自測的模型是 fixture，ChatPageModel 的 botCoreFixture 不接引擎的
                        // onChange；正式的會 objectWillChange.send()）。沒通知＝這 20 次一次都進不了畫面（j-int 074819：
                        // real-box layouts during 0 for 20 content updates），A3 等於沒量到串流。
                        model.objectWillChange.send()
                        sent.update { $0.append((id, CACurrentMediaTime())) }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                streamer = timer
            }
            while panels.formMotion.isAnimating, CACurrentMediaTime() - pressed < 3 {
                let before = canvas.host.layoutCount
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                if panels.formMotion.isAnimating {
                    let added = canvas.host.layoutCount - before
                    result.during += added
                    if added > 0 { result.at += canvas.host.layoutTimes.suffix(added).map { Int(($0 - pressed) * 1000) } }
                }
            }
            streamer?.invalidate()
            result.updates = updates.get()
            let ended = CACurrentMediaTime()
            if stream {
                // 最後一次更新可能剛好在停下那一格前後：再給 0.1 秒讓它進畫面，再看每一次更新有沒有進到列表、排出位置。
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                result.arrivals = sent.get().map { update -> (listed: Double?, laidOut: Double?) in
                    (GlobalDMListRows.listedForSelfTest[update.id].map { ($0 - update.at) * 1000 },
                     GlobalDMListRows.laidOutForSelfTest[update.id].map { ($0 - update.at) * 1000 })
                }
            }
            let stamps = recorder.stamps.filter { $0 >= returned && $0 <= ended }
            recorder.detach()
            result.firstFrame = (stamps.first.map { $0 - pressed } ?? -1) * 1000
            let gaps = zip(stamps, stamps.dropFirst()).map { $1 - $0 }
            result.frames = stamps.count
            result.fps = stamps.count > 1 ? Double(stamps.count - 1) / max(0.001, (stamps.last ?? 0) - (stamps.first ?? 0)) : 0
            result.longest = (gaps.max() ?? 0) * 1000
            result.second = (gaps.sorted(by: >).dropFirst().first ?? 0) * 1000
            result.fresh = panels.lastFreshCost * 1000
            result.freshLog = panels.freshLog
            if let staged = result.freshLog.first(where: { $0.deferred && $0.outcome == .staged }) {
                result.freshAt = (staged.endedAt - returned) * 1000
                result.freshScale = staged.scale
            }
            if let startBox, let move = recorder.samples.first(where: { $0.time >= returned && $0.box.map { deviation($0, startBox) >= 0.5 } == true }) {
                result.firstMove = (move.time - pressed) * 1000
                result.firstMoveStamp = move.time
            }
            result.stop = panels.lastStopCost * 1000
            result.ended = !panels.formMotion.isAnimating && canvas.stage == nil && canvas.host.alphaValue == 1 && !mask.isMasking
                && panels.boxPanelForTesting.map { same($0.frame, panels.placedPanelFrameForTesting() ?? .zero) } == true
            return result
        }
        // A5（按下去到第一格的時間、主執行緒卡住時停下的計時器）歸 F3T 房（GlobalDMFormsRegressionAcceptance）；這裡只量 F3 自己的：
        // 真的時鐘下每一格主執行緒都跟得上、動畫幾何不逐格排版（A3）。第一格的時間照樣記下來（NOTE）。
        GlobalDMHostingView.traceLayouts = true
        let plain = realRun(.outerPortrait, .innerLandscape)
        GlobalDMHostingView.traceLayouts = false
        if plain.during > 0 {
            for line in canvas.host.layoutStacks.suffix(4) { print("W184FORMS NOTE H12 plain layout \(line.prefix(1800))") }
        }
        // W184 AB（H12）：串流時使用者在看最新的回覆：先把對話捲到最底（新的列接在看得到的地方）。
        if let chat = DMBrowserPhoneAcceptance.views(NSScrollView.self, in: canvas.host)
            .filter({ !$0.isHiddenOrHasHiddenAncestor && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 40 })
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }), let document = chat.documentView {
            for _ in 0..<3 {
                let visible = chat.contentView.bounds
                chat.contentView.scroll(to: NSPoint(x: visible.minX, y: document.isFlipped ? max(0, document.frame.height - visible.height) : 0))
                chat.reflectScrolledClipView(chat.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            }
        }
        let streaming = realRun(.innerLandscape, .outerPortrait, stream: true)
        func line(_ name: String, _ r: RealRun) -> String {
            "\(name): first visible frame \(String(format: "%.0f", r.firstFrame))ms after the press (start \(String(format: "%.0f", r.start))ms = old picture \(String(format: "%.0f", r.prepare)) + form change \(String(format: "%.0f", r.formSet)) + applyForm \(String(format: "%.0f", r.apply))), \(r.frames) frames \(String(format: "%.1f", r.fps)) fps, longest gap \(String(format: "%.1f", r.longest))ms (the new look captured \(String(format: "%.1f", r.fresh))ms), next \(String(format: "%.1f", r.second))ms, real-box layouts during \(r.during)\(r.at.isEmpty ? "" : " at \(r.at.map { "+\($0)ms" }.joined(separator: ","))")\(r.updates > 0 ? " for \(r.updates) content updates" : ""), stop \(String(format: "%.1f", r.stop))ms, ended cleanly \(r.ended)"
        }
        print("W184FORMS NOTE H12 start trace \(panels.lastStartTrace) stop \(panels.lastStopTrace)")
        print("W184FORMS NOTE H12 \(line("plain", plain))")
        print("W184FORMS NOTE H12 \(line("streaming reply", streaming))")
        print("W184FORMS NOTE H12 streaming updates: \(streaming.arrivalText)")
        check(plain.ended && streaming.ended,
              "H12 every real-clock slide ends cleanly — not animating, stage gone, real box at opacity 1, mask released, the panel at the placed frame — also while a reply keeps streaming in",
              "plain=\(plain.ended) streaming=\(streaming.ended)")
        // W184 AB（H12；j-int 074819：20 次串流更新一次都沒進畫面，A3 照樣過）：串流那一段真的在串流——動畫中送出的每一次更新都進到
        // 列表（照正式的 onChange 通知模型），而且排出位置。一次都沒進＝不過（寫明原因），不能當成「排版 0 次」過關。
        let streamedIn = streaming.updates > 0 && streaming.reached == streaming.updates && streaming.laidOut == streaming.updates
        check(streamedIn,
              "H12 (A3, W184 AB) the streaming case really streams: every content update sent during the slide reaches the chat list (the model is notified as the engine's onChange does) and is laid out — none reaching it is a fail, not a pass",
              (streaming.reached == 0 ? "NO CONTENT UPDATE REACHED THE LIST — the streaming case measured nothing; " : "") + streaming.arrivalText)
        if plain.frames < 5 {
            check.skip("H12 量格數：這個環境的 display link 沒有在跑（\(plain.frames) 格）")
        } else {
            // 動畫期間真的框最多排一次（開始那一刻 SwiftUI 晚一拍套用「轉換中」的狀態），不是每一格；主執行緒每一格都跟得上——W184 AB：
            // 只有拍新樣子的那一下（動畫開始之後、畫面伺服器照樣在跑動畫）可以比 50ms 長，而且不比拍的時間多 25ms 以上。
            check(plain.freshOK,
                  "H12 (W184 AB, GPT-6 third review #7) the deferred new look of this slide was attempted, captured and actually taken by the stage (logged apart from a degraded fallback), and the box had already moved on screen (the stage's presentation ≥0.5pt off its start at a display-link frame) before that capture began",
                  plain.freshText)
            check(plain.during <= 1 && plain.fps >= 50 && plain.second < 50 && plain.longest < max(50, plain.fresh + 25),
                  "H12 (F3) with the real clock and display link the main thread keeps every frame (≥50 fps; no gap over 50ms except the one while the new look is captured after the slide started) and the slide's geometry lays out nothing per frame (at most one real-box layout, right at the start)",
                  line("plain", plain))
            // A3：動畫幾何不逐格觸發排版——對話在長時的排版次數跟內容更新的次數同一個量級，不是每一格一次。
            check(streamedIn && streaming.during <= streaming.updates * 3 + 2 && streaming.during < streaming.frames,
                  "H12 (A3) while a reply streams in, the slide's own geometry adds no per-frame layout: layouts during the slide follow the content updates, not the frames (only judged when the updates really reached the list)",
                  (streamedIn ? "" : "UPDATES DID NOT ALL REACH THE LIST — nothing to judge; ") + line("streaming reply", streaming))
        }
        // W184 AB（.031 真機：Retina 的 MacBook 上內直→倒放按下去到開始動約 251ms；目標每個方向 ≤150ms）：這台是 1x 螢幕，照 Retina 的
        // 像素比例拍新樣子（nativeScaleOverride＝2：同一棵圖層樹照兩倍像素重畫；舊樣子照產品用 1x、新樣子等畫面動了才拍），
        // 每個方向三次取中位數（按下去之前先空 0.4 秒：上一段停下之後的整理做完）。這台比 MacBook 快，真機再量。
        GlobalDMPanelCanvas.nativeScaleOverride = 2
        var retina: [String: [Double]] = [:], retinaNotes: [String] = [], freshAts: [String: [Double]] = [:], freshProblems: [String] = []
        for _ in 0..<3 {
            for (from, to) in [(GlobalDMForm.outerPortrait, GlobalDMForm.innerLandscape), (.innerLandscape, .innerPortrait), (.innerPortrait, .tent),
                               (.tent, .outerPortrait)] {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let run = realRun(from, to)
                let label = "\(from.rawValue)→\(to.rawValue)"
                retina[label, default: []].append(run.firstFrame)
                freshAts[label, default: []].append(run.freshAt)
                if !run.freshOK { freshProblems.append("\(label): \(run.freshText)") }
                retinaNotes.append("\(label) \(String(format: "%.0f", run.firstFrame))ms (old \(String(format: "%.0f", run.prepare)) + apply \(String(format: "%.0f", run.apply)); new look at \(Int(run.freshScale))x in \(String(format: "%.0f", run.fresh))ms, on the stage \(String(format: "%.0f", run.freshAt))ms after the start)")
            }
        }
        GlobalDMPanelCanvas.nativeScaleOverride = nil
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let retinaText = retina.keys.sorted().map { "\($0) median \(String(format: "%.0f", median(retina[$0] ?? [-1])))ms" }.joined(separator: "; ")
        print("W184FORMS NOTE AB Retina-like start (2x new look, 1x old look): \(retinaText) — \(retinaNotes.joined(separator: "; "))")
        if plain.frames < 5 {
            check.skip("AB Retina 模擬：這個環境的 display link 沒有在跑")
        } else {
            check(retina.count == 4 && retina.values.allSatisfy { $0.count == 3 && median($0) >= 0 && median($0) <= 150 },
                  "AB (.031 on a Retina MacBook: 251ms) press to first moving frame with Retina-sized captures (the new look at 2x, captured after the slide started; the old look at 1x), every direction, median of three ≤150ms on this machine",
                  retinaText)
            let freshText = freshAts.keys.sorted().map { "\($0) median \(String(format: "%.0f", median(freshAts[$0] ?? [-1])))ms" }.joined(separator: "; ")
            print("W184FORMS NOTE AB Retina-like new look on the stage after the start: \(freshText)")
            check(freshProblems.isEmpty,
                  "AB (GPT-6 third review #7) every Retina-sized run: the deferred new look was captured and actually taken by the stage (no degraded fallback counted as success) and the box had moved on screen before that capture began",
                  freshProblems.prefix(4).joined(separator: "; "))
            check(freshAts.count == 4 && freshAts.values.allSatisfy { $0.count == 3 && median($0) >= 0 && median($0) <= 150 },
                  "AB with Retina-sized captures the new look is on the stage ≤150ms after the slide started in every direction (median of three; a big box — inner portrait, inner landscape — is captured at 1x so the old look does not linger cut through most of the slide)",
                  freshText)
        }
        panels.formMotion.manualTime = true
        panels.formMotion.clock = { clock.now }
        // W184 AB（.031 真機：Retina 上按下去到開始動 251ms）：每個形態拍一張要多久——產品的拍法第一次（停了 0.2 秒之後：跟按下去那一刻
        // 一樣是「冷」的）與馬上再拍一次（熱的）、重畫一次之後再拍、CALayer.render 1x／2x（2x＝接近 Retina：同一棵圖層樹照兩倍像素重畫；
        // 陰影照產品關掉）；內橫、外直再列出最貴的幾層（自己那一層的成本＝整棵 − 子層整棵）。內橫、內直另外量「冷的」那一下花在哪：
        // 換走再換回來（冷）之後藏起混合模式的圖層拍、0.75x／0.5x 拍、每一層第一次畫比第二次多花多少。
        // 量完才做（放在這一段的最後）：2x 重畫整棵圖層樹之後 SwiftUI 會晚一點再排一次版，不能讓它落在上面那幾段「動畫期間不排版」的量測裡。
        panels.formMotion.manualTime = false
        panels.formMotion.clock = { CACurrentMediaTime() }
        do {
            var lines: [String] = [], hogLines: [String] = [], coldLines: [String] = []
            var previous = settings.form
            func show(_ form: GlobalDMForm) {
                settings.form = form
                panels.applyForm(.between(previous, form, animated: false))
                previous = form
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            for form in [GlobalDMForm.outerPortrait, .innerLandscape, .innerPortrait, .tent] {
                show(form)
                let box = NSRect(x: margin, y: margin, width: canvas.bounds.width - margin * 2, height: canvas.bounds.height - margin * 2)
                let fill = GlobalDMFormStage.surface(appearance: panel.effectiveAppearance, size: .zero).fill
                func product(_ scale: CGFloat = 1) -> Double {
                    let t0 = CACurrentMediaTime()
                    _ = canvas.capture(form, box: box, fill: fill, label: "measure \(form.rawValue)", scale: scale)
                    return (CACurrentMediaTime() - t0) * 1000
                }
                func render(_ scale: CGFloat, hideBlends: Bool = false) -> Double {
                    guard let layer = canvas.host.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let ctx = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: 0, y: box.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.translateBy(x: -box.minX, y: -box.minY)
                    var hidden: [CALayer] = []
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if hideBlends {
                        var stack: [CALayer] = [layer]
                        while let next = stack.popLast() {
                            if next.compositingFilter != nil, next.opacity > 0 { next.opacity = 0; hidden.append(next) }
                            stack.append(contentsOf: next.sublayers ?? [])
                        }
                    }
                    let t0 = CACurrentMediaTime()
                    canvas.withShadowsMutedForTesting { layer.render(in: ctx) }
                    let ms = (CACurrentMediaTime() - t0) * 1000
                    for item in hidden { item.opacity = 1 }
                    CATransaction.commit()
                    return ms
                }
                let cold = product()
                let warm = product()
                // 整個框重畫一次（像內容剛更新過）、送出去、等 0.1 秒，再拍。
                canvas.host.setNeedsDisplay(canvas.host.bounds)
                canvas.host.displayIfNeeded()
                CATransaction.flush()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let redrawn = product()
                _ = render(1)
                let render1 = render(1), render2 = render(2)
                // 整張畫（tile＝nil）或分塊畫（每一塊先裁到那一塊再畫整棵樹）。W184 AB 量過：分塊沒有比較快（mini：內橫 1x 整張 51ms、
                // 橫條 256pt 50ms、128pt 方塊 67ms），產品照整張畫。
                func tiled(_ scale: CGFloat, tile: CGSize?) -> (ms: Double, image: CGImage?) {
                    guard let layer = canvas.host.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let ctx = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (-1, nil) }
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: 0, y: box.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.translateBy(x: -box.minX, y: -box.minY)
                    var rects: [CGRect] = []
                    let step = tile ?? box.size
                    var y: CGFloat = 0
                    while y < box.height {
                        var x: CGFloat = 0
                        while x < box.width {
                            rects.append(CGRect(x: box.minX + x, y: box.minY + y, width: min(step.width, box.width - x), height: min(step.height, box.height - y)))
                            x += step.width
                        }
                        y += step.height
                    }
                    let t0 = CACurrentMediaTime()
                    canvas.withShadowsMutedForTesting {
                        for rect in rects {
                            ctx.saveGState()
                            ctx.clip(to: rect)
                            layer.render(in: ctx)
                            ctx.restoreGState()
                        }
                    }
                    return ((CACurrentMediaTime() - t0) * 1000, ctx.makeImage())
                }
                lines.append("\(form.rawValue) \(Int(box.width))×\(Int(box.height)): product 1x cold \(String(format: "%.1f", cold))ms, warm \(String(format: "%.1f", warm))ms, after a redraw \(String(format: "%.1f", redrawn))ms; render 1x \(String(format: "%.1f", render1))ms, 2x \(String(format: "%.1f", render2))ms")
                if form == .innerLandscape || form == .outerPortrait, let layer = canvas.host.layer {
                    for scale in [CGFloat(1), 2] {
                        var hogs: [String] = []
                        canvas.withShadowsMutedForTesting { hogs = renderHogs(layer, scale: scale, size: canvas.host.bounds.size) }
                        hogLines.append("\(form.rawValue) \(Int(scale))x: \(hogs.joined(separator: " | "))")
                    }
                }
                if form == .innerLandscape || form == .innerPortrait {
                    // 冷的那一下：每次先換走再換回來（重新排版＝冷的）。
                    func recold() {
                        let back = form
                        show(form == .innerLandscape ? .innerPortrait : .innerLandscape)
                        show(back)
                    }
                    recold()
                    let coldAgain = product()
                    recold()
                    let coldNoBlend = render(1, hideBlends: true)
                    recold()
                    let cold075 = product(0.75)
                    recold()
                    let cold05 = product(0.5)
                    recold()
                    let coldWhole2x = tiled(2, tile: nil).ms
                    recold()
                    var penalties: [String] = []
                    if let layer = canvas.host.layer {
                        canvas.withShadowsMutedForTesting { penalties = coldHogs(layer, size: canvas.host.bounds.size) }
                    }
                    coldLines.append("\(form.rawValue): cold again \(String(format: "%.1f", coldAgain))ms, cold without blend layers \(String(format: "%.1f", coldNoBlend))ms, cold at 0.75x \(String(format: "%.1f", cold075))ms, at 0.5x \(String(format: "%.1f", cold05))ms, cold 2x \(String(format: "%.1f", coldWhole2x))ms; first-render penalty by layer: \(penalties.joined(separator: " | "))")
                }
            }
            print("W184FORMS NOTE AB capture per form: \(lines.joined(separator: "; "))")
            for line in hogLines { print("W184FORMS NOTE AB render hogs \(line)") }
            for line in coldLines { print("W184FORMS NOTE AB cold capture \(line)") }
        }
        panels.formMotion.manualTime = true
        panels.formMotion.clock = { clock.now }
        settings.form = .outerPortrait
        panels.applyForm(.between(settings.form, .outerPortrait, animated: false))
    }

    // MARK: - DK 深色系統下的牛皮紙主題（W184 AB，.031 真機：字跟著系統變白、紙底照樣淺米色，對比約 1.2 倍）

    /// 一塊畫面裡「深色的字」有幾個像素（亮度 < 110；紙底約 215–240）、最深的亮度。
    static func inkStats(_ rep: NSBitmapImageRep, in rect: NSRect? = nil) -> (dark: Int, darkest: Int) {
        let area = rect ?? NSRect(x: 0, y: 0, width: rep.size.width, height: rep.size.height)
        let sx = CGFloat(rep.pixelsWide) / rep.size.width, sy = CGFloat(rep.pixelsHigh) / rep.size.height
        var dark = 0, darkest = 255
        for y in stride(from: Int(area.minY * sy), to: min(rep.pixelsHigh, Int(area.maxY * sy)), by: 1) {
            for x in stride(from: Int(area.minX * sx), to: min(rep.pixelsWide, Int(area.maxX * sx)), by: 1) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                let luma = Int((0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent) * 255)
                if luma < 110 { dark += 1 }
                darkest = min(darkest, luma)
            }
        }
        return (dark, darkest)
    }

    @MainActor static func darkModeChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        // W184 H4 修正第四輪：換主題只換這個程序畫的樣子，共用的存檔（tatwo.activeThemeID）全程不動——別的房間同時開的自測
        // 讀不到這裡切到一半的主題（TatwoThemeSelfTestScope）；結束照舊還原成原本的主題與外觀。
        let themes = TatwoThemeSelfTestScope()
        let theme0 = TatwoThemeStore.shared.activeThemeID, appearance0 = NSApp.appearance
        defer {
            themes.use(theme0 == .aurora ? .fable5 : .aurora)
            themes.restore()
            NSApp.appearance = appearance0
        }
        // 系統深色的樣子：先切到跟系統走的主題（還原成 nil），再把 App 的外觀設成深色（沒有指定外觀的視窗照它）；然後切到 fable5。
        themes.use(.aurora)
        let followsSystem = NSApp.appearance == nil
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let darkBefore = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        themes.use(.fable5)
        let forced = NSApp.appearance?.name == .aqua
        // 私訊框（真的浮動框，視窗沒有自己指定外觀）：對話那一塊的字是深的。
        let store = GlobalDMStore(defaults: freshDefaults("darkBox"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("darkBoxDesk"))
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        panels.install()
        defer {
            store.close()
            panels.uninstall()
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.floatingPanelForTesting?.isVisible == true }
        var box = (dark: -1, darkest: -1), boxDark = false, bug = (dark: -1, darkest: -1)
        if let panel = panels.floatingPanelForTesting, let canvas = panel.contentView as? GlobalDMPanelCanvas {
            panel.alphaValue = 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            canvas.host.layoutSubtreeIfNeeded()
            boxDark = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let margin = GlobalDMLayout.margin
            let area = NSRect(x: margin + 12, y: margin + DMPhone.headerHeight + 8, width: canvas.host.bounds.width - margin * 2 - 24,
                              height: canvas.host.bounds.height - margin * 2 - DMPhone.headerHeight - 140)
            if let rep = canvas.host.bitmapImageRepForCachingDisplay(in: canvas.host.bounds) {
                canvas.host.cacheDisplay(in: canvas.host.bounds, to: rep)
                box = inkStats(rep, in: area)
            }
            // 反例（.031 的樣子）：fable5 底下 App 照系統變深色＝字變白、紙底照樣淺——同一個量法量得出來（深色的字幾乎沒有）。
            NSApp.appearance = NSAppearance(named: .darkAqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            canvas.host.layoutSubtreeIfNeeded()
            if let rep = canvas.host.bitmapImageRepForCachingDisplay(in: canvas.host.bounds) {
                canvas.host.cacheDisplay(in: canvas.host.bounds, to: rep)
                bug = inkStats(rep, in: area)
            }
            NSApp.appearance = NSAppearance(named: .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        // DK2（GPT-6 第三輪 #6：DK1 原本那個另建的單行字視窗不算數）：真的主視窗（TatwoWorkOSWindow，照 AppShell 開主視窗那一套：
        // configureTatwoChrome、applyTatwoWindowSurface）裡放真的 Browser 網址列（EmbeddedBrowserToolbar，展開成玻璃面板、裡面有網址）：
        // 深色系統＋fable5 下網址的字是深的、玻璃面板是淺的；反例（.031 那樣 App 跟系統變深色）同一個量法量得出字變淺、玻璃變深。
        let real = realMainWindowOmnibox()
        themes.use(.fable5)   // 量完反例之後照 fable5 還原（量的函式裡暫時換過 App 的外觀）
        // DK3：Island 本來就跟著系統的明暗：fable5 把 App 固定淺色時，它照舊跟系統（系統深色＝深色的玻璃與字）。
        let savedDark = TatwoSystemAppearance.isDark
        TatwoSystemAppearance.isDark = { true }
        let island = TatwoIslandShellPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 120),
                                           viewController: NSHostingController(rootView: TatwoIslandShellView(state: TatwoIslandShellState())))
        island.alphaValue = 0
        let plain = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let islandDark = island.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let plainLight = plain.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        TatwoSystemAppearance.isDark = { false }
        TatwoSystemAppearance.refresh()
        let islandFollows = island.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        TatwoSystemAppearance.isDark = savedDark
        TatwoSystemAppearance.refresh()
        island.orderOut(nil)
        // 換回極光＝還原成跟系統。
        themes.use(.aurora)
        let released = NSApp.appearance == nil
        print("W184FORMS NOTE DK1 dark system + fable5: DM box messages \(box.dark) dark-ink pixels (darkest luminance \(box.darkest)/255); counterexample (.031: the app following the system dark on paper) \(bug.dark) (darkest \(bug.darkest))")
        print("W184FORMS NOTE DK2 real main window + Browser omnibox, dark system + fable5: \(real.note)")
        check(bug.dark >= 0 && bug.dark < box.dark / 4,
              "DK1 counterexample: forcing the dark appearance on the paper theme (what .031 did) leaves almost no dark ink in the same area — the measure tells the two apart",
              "fixed=\(box) bug=\(bug)")
        check(followsSystem && darkBefore && forced && !boxDark && box.dark > 150 && box.darkest < 90 && released,
              "DK1 (W184 AB, .031 on the real device) with the system dark, the paper theme (fable5) keeps the whole app light (NSApp.appearance = aqua): the DM box's messages are dark ink on the paper (not white on beige); back to aurora the app follows the system again",
              "followsSystem=\(followsSystem) darkBefore=\(darkBefore) forced=\(forced) boxDark=\(boxDark) box=\(box) released=\(released)")
        check(real.ok,
              "DK2 (W184 AB, GPT-6 third review #6) the real main window (TatwoWorkOSWindow with the app's chrome and paper surface) with the real Browser omnibox open, system dark + fable5: the address text is dark ink and the glass panel is light (accepted: fable5 makes the whole app one light paper theme); counterexample — the app following the dark system — gives light text on dark glass by the same measure",
              real.note)
        check(islandDark && plainLight && islandFollows,
              "DK3 (W184 AB, GPT-6 third review #6) the Island keeps following the system's light/dark while fable5 pins the app light: with the system dark the Island panel is dark (a plain panel of the app is light); back to a light system the Island is light again",
              "islandDark=\(islandDark) plainLight=\(plainLight) followsLight=\(islandFollows)")
    }

    /// DK2：真的主視窗＋真的 Browser 網址列（展開、玻璃面板裡有網址），在目前的 App 外觀（fable5＝aqua）量一次、再把 App 暫時換成深色
    ///（反例）量一次。回傳：通過沒有、數字。
    @MainActor static func realMainWindowOmnibox() -> (ok: Bool, note: String) {
        struct Harness: View {
            @State var address = ""
            @State var expand = true
            @FocusState var focused: Bool
            var body: some View {
                EmbeddedBrowserToolbar(addressText: $address, addressFieldFocused: $focused,
                                       state: EmbeddedBrowserNavigationState(urlString: "https://tatwo.ai/dark-mode-check", canGoBack: true,
                                                                             canGoForward: false, visibleError: nil),
                                       enabled: true, onSubmit: {}, onCommand: { _ in }, expansionRequest: $expand)
                    .frame(width: 560)
                    .padding(.top, 40)
                    .frame(width: 640, height: 300, alignment: .top)
            }
        }
        let size = NSSize(width: 640, height: 300)
        let window = TatwoWorkOSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Harness())
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.configureTatwoChrome()
        window.applyTatwoWindowSurface()
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let canvas = NSColor(TatwoActivePalette.current.canvasBase).usingColorSpace(.deviceRGB) ?? .white
        /// 面板那一塊（網址列底下 4pt 起、約 70pt 高）：深色字的像素、最深的亮度、鋪在主視窗紙底上的中位數亮度（玻璃）。
        func measure() -> (dark: Int, darkest: Int, glass: Int, isDark: Bool) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (-1, -1, -1, false) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let top = 40 + BrowserOmniboxMetrics.collapsedHeight + BrowserOmniboxMetrics.panelGap
            let area = NSRect(x: 52, y: top + 4, width: 520, height: 60)
            let ink = inkStats(rep, in: area)
            let sx = CGFloat(rep.pixelsWide) / rep.size.width, sy = CGFloat(rep.pixelsHigh) / rep.size.height
            var lumas: [Int] = []
            for y in stride(from: Int(area.minY * sy), to: Int(area.maxY * sy), by: 2) {
                for x in stride(from: Int(area.minX * sx), to: Int(area.maxX * sx), by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let a = c.alphaComponent
                    let r = c.redComponent * a + canvas.redComponent * (1 - a), g = c.greenComponent * a + canvas.greenComponent * (1 - a)
                    let b = c.blueComponent * a + canvas.blueComponent * (1 - a)
                    lumas.append(Int((0.299 * r + 0.587 * g + 0.114 * b) * 255))
                }
            }
            let glass = lumas.isEmpty ? -1 : lumas.sorted()[lumas.count / 2]
            return (ink.dark, ink.darkest, glass, host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
        let fixed = measure()
        let saved = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let bug = measure()
        NSApp.appearance = saved
        let ok = !fixed.isDark && fixed.dark > 30 && fixed.darkest < 110 && fixed.glass >= 170
            && bug.isDark && (bug.dark * 4 < fixed.dark || bug.glass + 15 < fixed.glass)
        let note = "fixed: \(fixed.dark) dark text pixels (darkest \(fixed.darkest)/255), glass median \(fixed.glass)/255, window dark=\(fixed.isDark); counterexample (app dark): \(bug.dark) (darkest \(bug.darkest)), glass \(bug.glass), dark=\(bug.isDark)"
        return (ok, note)
    }

    @MainActor static func noopActions() -> GlobalDMMoreMenu.Actions {
        GlobalDMMoreMenu.Actions(setForm: { _ in }, openDirectKeys: {}, openAccessibility: {}, collapse: {}, restore: {}, close: {})
    }
}
/// W184 F3 自測：主執行緒的 display link 每一格記一個時間（動畫期間主執行緒被卡住，間隔就會拉長）。
@MainActor final class GlobalDMFrameRecorder: NSObject {
    private(set) var stamps: [CFTimeInterval] = []
    /// W184 AB（第三輪 #7）：每一格同時讀一次 probe（例如圖層台 presentation 的框）：看得到框是哪一格真的開始動。
    var probe: (() -> CGRect?)?
    private(set) var samples: [(time: CFTimeInterval, box: CGRect?)] = []
    private var link: CADisplayLink?

    func attach(to view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        stamps.append(now)
        if let probe { samples.append((now, probe())) }
    }

    func reset() {
        stamps = []
        samples = []
    }

    func detach() {
        link?.invalidate()
        link = nil
    }
}
#endif
