#if DEBUG
import AppKit
import Combine
import SwiftUI

/// `TATWO2_SELFTEST=w184mode`：W184 H4——自研輸入框的「模式選擇」chip＋模式卡（ULTRAWORK 卡擴充）。
/// T  拉條：填充式（第一檔＝一格、最後一檔＝整條，不是方塊按鈕）、放開停在哪一檔（中點遲滯＋方向）、兩檔與一檔；
///    T4 真的畫出來量像素：沒填到的格子也看得到玻璃軌道底、填色從左邊到目前那一檔（查核 #14）。
/// K  點卡外面收起的規則；私訊框的卡與 chip 只用手機字級 token（17／15／13／11）、可按至少 44、同心圓角。
/// C  Coder：四樣各自改了之後 ChatPageModel 的值真的變了（ultrawork 檔位與角色、模型、速度、推理強度、記憶），送出時讀的參數對；
///    chip 摘要跟著變；換模型時速度照新模型允許的檔位列或不列；ultrawork 開著也換得到這一輪的模型（查核 #8）；CLI、Bot 串沒有記憶；
///    Plan 畫布那張只有協作、關著時沒有模型列（查核 #10）。
/// D  私訊框：助理與 Coder session 的模型、記憶照原本的路徑改；速度、推理強度寫回那一條、ultrawork 就是送出時帶的那一個（查核 #1）；
///    停用的引擎真的變淡（查核 #17）；接主設備時變淡寫原因、回覆中模型列停用（查核 #1、#15）；ChatGPT 對象沒有模式卡；Bot 串沒有記憶。
/// A  TATWO 助理頁（W184 H4b）：助理頁的卡跟私訊框助理那張逐項一樣（同一條助理、同一條送出路徑）；模型、速度、推理強度、記憶各自改了之後
///    助理那一條的值真的變了、Coder 的不動；接主設備時變淡寫原因、回覆中模型列停用、停用的引擎逐列一致。
/// S  Space 搭建：預覽的選擇、正式搭建時不能選的照舊。B  Bot Studio：展示、不能改、沒有記憶；派工方式不是一格的拉條（查核 #7）。
/// R  每個套用的輸入框畫卡片開與關的 PNG（fable5、極光）：卡的下緣真的在輸入框上方 8（查核 #13）；Space（R6）與 TATWO 助理頁（R10，畫真的
///    AssistantSpacePane）也是以整個輸入框的上緣為準（H4b：Space 的卡原本掛在工具列上，蓋住打字區 59pt）；
///    R7 真的滑鼠點 chip 開、再點關、點外面收（事件走 App 的事件佇列，跟使用者點的同一條路；查核 #12），助理頁與 Space 也有；
///    R11／R12 卡開著時真的滑鼠點在卡上改值：助理頁點速度、記憶的檔位、點模型那一列進清單再點另一個模型，Space 點 S～XXL 的 XL、量卡的位置
///    （拉條的事件監看用事件的螢幕座標，所以點拉條前把視窗搬進螢幕、全透明；沒有顯示器的環境改叫它接的同一組回呼，NOTE 會寫走了哪一條）；
///    R8／R9 視窗矮、卡很高時 S～XXL 照樣在畫面裡、中間那一段捲（查核 #3、#11）。另畫參考卡同狀態（S＋Opus 5.5、L）的卡給並排比對。
/// W184 H4 修正（GPT-6 H4 審查 10 條；TatwoComposerModeAcceptanceFix.swift）：
/// P  真的送出的參數：引擎程式換成只記下收到什麼的替身腳本（sidecarPath 覆寫；不啟動真的引擎、不燒額度），走真的 Coder send()、
///    私訊框 sendFromDM、ChatLiveEngine、ClaudeSidecar——第一輪與重用的第二輪（同一家換模型要重開、Codex 每一輪帶模型與推理強度）、
///    ultrawork 每一輪照卡上的值接在那一句後面（換檔、改角色、關掉的那一輪說「關了」）；遠端：RemoteLiveEngine 真的要送出的那一包
///    （send／deliver）、主設備的 send_message 收下後真的帶進那一輪、認不得的欄位照常送。
/// I  不同 session 隔離、同一條才同步、存在那條（重開還在）、開關 ultrawork 不換模型。
/// F  卡的總高度硬上限（純計算＋私訊框外直 0.7 倍＋多行＋附件畫出來量）。
/// H  捲動後點固定區，被捲走的設定不會變（真的滑鼠事件；沒有螢幕＝未驗證，不叫回呼充數）。
/// KB 鍵盤矩陣：Esc 收卡、焦點回輸入框、Tab／方向鍵／Return 選檔位、卡開著時輸入框 Return 不送出、組字中先給輸入法（真的按鍵事件）。
/// R13 主視窗 Coder：卡掛在整個輸入框上（量真的上緣），卡開著點送出＝收卡並照常送出（不吞那一下）。
/// 只在完整隔離的 staging 跑（引擎資料夾必須未登入：不送出任何一句給真的引擎）；PNG 寫到 TATWO2_SELFTEST_ARTIFACTS。
enum TatwoComposerModeAcceptance {
    @MainActor final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: @autoclosure () -> String = "") {
            if condition { passed += 1 } else { failed += 1 }
            let detail = condition ? "" : evidence()
            print("W184MODE \(condition ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — " + String(detail.prefix(500)))")
        }
        func skip(_ label: String) {
            skipped += 1
            print("W184MODE SKIP \(label)")
        }
        func note(_ text: String) { print("W184MODE NOTE \(text)") }
    }

    /// 自測裡代替 ChatPage 的角色設定（同 collaborationRoleModelID／selectCollaborationRoleModel 的寫法：寫進這張表＋ChatPageModel 的主導、副審）。
    @MainActor final class RoleBook {
        var configuration = UltraworkRoleConfiguration.defaultValue
        var picks: [String] = []
    }

    /// 畫面上量到的位置（最上層畫面的座標，由上往下，單位是點）：輸入框、工具列、卡。
    final class FrameProbe {
        var composer: CGRect?
        var toolbar: CGRect?
        var card: CGRect?
    }

    /// SelfTest.swift 的一行註冊叫這裡：跑完就結束程式（同 w184button 的做法）。
    @MainActor static func launch() {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            do { exit(try await run() ? 0 : 1) }
            catch { print("W184MODE FAIL \(error)"); print("W184MODE SUMMARY failures=1"); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"], let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w184mode needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w184mode requires a fresh live root")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }
        let artifacts = environment["TATWO2_SELFTEST_ARTIFACTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let check = Checker()

        // 隔離的引擎：一條 Coder 串、一條 Bot 串；助理那條引擎自己建。
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "W184 模式選擇", workdir: root.path)
        let thread = engine.newThread(in: project, title: "Coder 串")
        let bot = BotLibraryRecord(id: "w184-mode-bot", name: "Fixture Bot", emoji: "B", role: "fixture", engine: "claude",
                                   model: nil, workdir: root.path, parentBotID: nil)
        let botThread = try engine.prepareBotThread(existing: nil, bot: bot, registeredMCP: [], selectThread: false)
        let library = BotLibrary(root: root.appendingPathComponent("bots"), skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        model.mode = .chat
        model.selectedThreadID = thread
        let suite = "ai.tatwo.selftest.w184mode.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw BotLibraryError.invalid("defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let chatSession = ChatGPTConversationSession(tap: ChatGPTTap(transport: GlobalDMChatAcceptancePod(), connection: .ready))
        let catalog = ChatGPTModelCatalog(models: [
            TapModel(id: "version:fixture", title: "Latest", detail: "",
                     efforts: [TapEffort(id: "fixture|instant", title: "Instant")]),
        ], defaultModelID: "version:fixture", defaultEffortID: "fixture|instant")
        let store = GlobalDMStore(defaults: defaults, chatGPT: { chatSession }, chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, recentApps: defaults)
        store.attach(model)
        store.select(.assistant)
        let roles = RoleBook()
        // 同 ChatPage 的接法（coderComposerMode → collaborationRoleModelID／selectCollaborationRoleModel）：角色讀、寫的都是
        // Coder 開著的那一條（W184 H4 修正：審查 #3、#5）；這裡不寫 app-wide 的預設（自測不改使用者的設定）。
        func coderMode(ultraworkOnly: Bool = false) -> TatwoComposerMode {
            TatwoComposerMode.coder(
                model: model,
                roleModelID: { model.ultraworkRoleModelID($0, for: model.selectedThreadID) },
                chooseRole: { choice, slot in
                    roles.picks.append("\(slot.label)=\(choice.canonicalModelSlug)")
                    model.setUltraworkRole(choice.canonicalModelSlug, slot: slot, for: model.selectedThreadID)
                },
                chooseModel: { TatwoComposerMode.applyCoderRoute($0, to: model) },
                ultraworkOnly: ultraworkOnly)
        }

        trackChecks(check)
        layoutRuleChecks(check)
        fitRuleChecks(check)   // W184 H4 修正（審查 #8）
        acceptingChecks(check)   // W184 H4 修正第二輪（GPT-6 H4b 審查 #3）
        coderChecks(check, model: model, engine: engine, thread: thread, botThread: botThread, roles: roles, mode: coderMode)
        dmChecks(check, model: model, store: store, engine: engine, thread: thread, botThread: botThread)
        assistantPageChecks(check, model: model, store: store, engine: engine, thread: thread)
        spaceChecks(check)
        botStudioChecks(check)
        // W184 H4 修正（審查 #1、#2、#3、#10）：真的送出的參數（替身腳本記下 sidecar 收到的）、session 隔離、遠端那一包與主設備收下。
        await payloadChecks(check, model: model, store: store, engine: engine, thread: thread, root: root, mode: coderMode)
        if renderChecks(check, model: model, store: store, engine: engine, thread: thread, mode: coderMode, artifacts: artifacts) {
            do {   // 審查 #8：私訊框外直 0.7 倍＋多行＋附件；第四輪：迴圈前記下主題，結束（含中途離開）還原，共用存檔不動
                let themeScope = TatwoThemeSelfTestScope()
                defer { themeScope.restore() }
                for theme in [TatwoThemeID.fable5, .aurora] {
                    smallDMChecks(check, model: model, store: store, engine: engine, thread: thread, root: root, artifacts: artifacts,
                                  theme: theme)
                }
            }
            await clickChecks(check, model: model, store: store, engine: engine, mode: coderMode, artifacts: artifacts)
            await hitAfterScrollChecks(check, model: model, mode: coderMode, artifacts: artifacts)   // 審查 #4
            await keyboardChecks(check, model: model, store: store, engine: engine, mode: coderMode, artifacts: artifacts)   // 審查 #6
            await keyboardScrollChecks(check, model: model, mode: coderMode)   // W184 H4 修正第二輪（GPT-6 H4b 審查 #5、#6）
        }
        await escapeChecks(check, store: store)   // W184 AB（H4 查核 #9）：模式卡開著按 Esc＝只收卡

        check(TatwoThemeSelfTestScope.saveDarkEvidence("mode-coder-dark.png", size: CGSize(width: 360, height: 720), to: artifacts) {
            TatwoComposerModeCard(mode: coderMode(), metrics: .main, fitsAbove: false).padding(16)
        }, "I3 Coder mode card darkAqua evidence")
        store.select(.assistant)
        check(TatwoThemeSelfTestScope.saveDarkEvidence("mode-dm-dark.png", size: CGSize(width: 360, height: 620), to: artifacts) {
            if let dm = TatwoComposerMode.dm(store: store) {
                TatwoComposerModeCard(mode: dm, metrics: .main, fitsAbove: false).padding(16)
            }
        }, "I3 DM mode card darkAqua evidence")
        check(TatwoThemeSelfTestScope.saveDarkEvidence("mode-assistant-dark.png", size: CGSize(width: 360, height: 620), to: artifacts) {
            TatwoComposerModeCard(mode: TatwoComposerMode.assistantSpace(model: model), metrics: .main, fitsAbove: false).padding(16)
        }, "I3 assistant mode card darkAqua evidence")
        check(TatwoThemeSelfTestScope.saveDarkEvidence("mode-space-dark.png", size: CGSize(width: 360, height: 620), to: artifacts) {
            let domain = SpaceSetupPreviewState.Domain(id: "w192-dark-space", name: "測試工作室", bots: [])
            TatwoComposerModeCard(mode: TatwoComposerMode.spaceSetup(domain: domain), metrics: .main, fitsAbove: false).padding(16)
        }, "I3 preview mode card darkAqua evidence")

        print("W184MODE SUMMARY failures=\(check.failed) passed=\(check.passed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    // MARK: - T 拉條

    @MainActor static func trackChecks(_ check: Checker) {
        let five = TatwoComposerFilledTrackGeometry(count: 5, width: 260)
        check(five.fillWidth(ratio: five.ratio(of: 0)) == 52 && five.fillWidth(ratio: five.ratio(of: 2)) == 156
              && five.fillWidth(ratio: five.ratio(of: 4)) == 260,
              "T1 filled glass track: S fills one fifth, L fills S–L (three fifths), XXL fills the whole bar — a bar growing from the left, not one square button",
              "S=\(five.fillWidth(ratio: 0)) L=\(five.fillWidth(ratio: 0.5)) XXL=\(five.fillWidth(ratio: 1))")
        check(five.index(nearest: 0) == 0 && five.index(nearest: 0.5) == 2 && five.index(nearest: 1) == 4
              && five.laneRatio(forLocalX: 0) == 0 && five.laneRatio(forLocalX: 260) == 1 && five.laneRatio(forLocalX: 130) == 0.5,
              "T1 the lane runs from the middle of S to the middle of XXL; the middle of the bar is L")
        let hysteresis = min(CGFloat(0.04), 5 / five.laneWidth)
        check(five.target(forRelease: 0.125 - hysteresis - 0.005, dragDelta: 0, direction: 0) == 0
              && five.target(forRelease: 0.125 + hysteresis + 0.005, dragDelta: 0, direction: 0) == 1,
              "T2 release outside the midpoint band: position wins (just before the S/M midpoint → S, just after → M)")
        check(five.target(forRelease: 0.125, dragDelta: 0.05, direction: 0.01) == 1
              && five.target(forRelease: 0.125, dragDelta: -0.05, direction: -0.01) == 0
              && five.target(forRelease: 0.125, dragDelta: 0.001, direction: 0) == five.index(nearest: 0.125),
              "T2 inside the midpoint band the drag direction decides; a one-pixel wobble falls back to the nearest stop")
        check(five.target(forRelease: 1.4, dragDelta: 0, direction: 0) == 4 && five.target(forRelease: -0.3, dragDelta: 0, direction: 0) == 0,
              "T2 releasing past either end stops at XXL / S")
        let two = TatwoComposerFilledTrackGeometry(count: 2, width: 260)
        check(two.fillWidth(ratio: two.ratio(of: 0)) == 130 && two.fillWidth(ratio: two.ratio(of: 1)) == 260
              && two.target(forRelease: 0.3, dragDelta: 0, direction: 0) == 0 && two.target(forRelease: 0.7, dragDelta: 0, direction: 0) == 1,
              "T3 two stops (speed fast/標準): half and whole bar; release picks the nearer one")
        let one = TatwoComposerFilledTrackGeometry(count: 1, width: 200)
        check(one.fillWidth(ratio: one.ratio(of: 0)) == 200 && one.target(forRelease: 0.9, dragDelta: 0.5, direction: 0.2) == 0,
              "T3 a single stop fills the bar and never leaves index 0")
    }

    // MARK: - K 版面規則（點外面收起、私訊框手機 token）

    @MainActor static func layoutRuleChecks(_ check: Checker) {
        let card = NSRect(x: 100, y: 100, width: 300, height: 400)
        let chip = NSRect(x: 320, y: 40, width: 120, height: 24)
        let otherChip = NSRect(x: 20, y: 40, width: 80, height: 24)
        check(TatwoComposerModeClickAwayView.shouldClose(click: nil, card: card, chips: [chip])
              && !TatwoComposerModeClickAwayView.shouldClose(click: NSPoint(x: 150, y: 300), card: card, chips: [chip])
              && !TatwoComposerModeClickAwayView.shouldClose(click: NSPoint(x: 330, y: 50), card: card, chips: [chip])
              && !TatwoComposerModeClickAwayView.shouldClose(click: NSPoint(x: 30, y: 50), card: card, chips: [chip, otherChip])
              && TatwoComposerModeClickAwayView.shouldClose(click: NSPoint(x: 20, y: 20), card: card, chips: [chip])
              && TatwoComposerModeClickAwayView.shouldClose(click: NSPoint(x: 330, y: 50), card: card, chips: []),
              "K1 click-away: a click on the card or on any mode chip in that window keeps the card (the chip toggles itself); anywhere else or another window closes it")
        let dm = TatwoComposerModeMetrics.dmPhone
        let tokens: Set<CGFloat> = [DMPhone.TextSize.body, DMPhone.TextSize.secondary, DMPhone.TextSize.footnote, DMPhone.TextSize.caption]
        check(dm.textSizes.allSatisfy(tokens.contains) && GlobalDMChatLayout.footnoteSize == 13 && GlobalDMChatLayout.captionSize == 11,
              "K2 the DM card and chip only use the phone font tokens (17/15/13/11)", "\(dm.textSizes)")
        check(dm.trackHeight >= DMPhone.touch && dm.rowHeight >= DMPhone.touch && dm.powerSize >= DMPhone.touch
              && dm.listRowHeight >= DMPhone.touch && GlobalDMChatLayout.chipHeight == 32,
              "K2 DM: every track, row, the power and back buttons are at least 44 high; the chip is 32 (same as the old chips)")
        check(dm.cornerRadius == DMPhone.cardRadius && dm.trackRadius == DMPhone.concentric(DMPhone.cardRadius, inset: dm.padding)
              && dm.rowRadius == dm.trackRadius && dm.padding == DMPhone.edgeInset && dm.flexibleWidth,
              "K2 DM card corner 28 (content card), inner tracks and rows concentric 28 − 12 = 16; narrow boxes narrow the card")
        let main = TatwoComposerModeMetrics.main
        check(main.width == 300 && !main.flexibleWidth && main.trackHeight == 34 && main.rowHeight == 38
              && main.trackRadius == LiquidGlassTokens.radiusChip && main.cornerRadius == LiquidGlassTokens.radiusCard,
              "K3 main window keeps the ULTRAWORK card sizes (track 34, rows 38, theme radii)")
        check(main.topClearance == WindowChromeMetrics.bandHeight + 8 && dm.topClearance == GlobalDMLayout.margin + DMPhone.headerHeight,
              "K4 the card grows up from the composer and stops below the window's top band (main) / the DM's top bar (DM)",
              "main=\(main.topClearance) dm=\(dm.topClearance)")
    }

    // MARK: - C Coder

    @MainActor static func coderChecks(_ check: Checker, model: ChatPageModel, engine: ChatLiveEngine, thread: UUID,
                                       botThread: UUID, roles: RoleBook,
                                       mode coderMode: (Bool) -> TatwoComposerMode) {
        guard let speedRoute = ChatRouteChoice.all.first(where: { $0.supportsNativeSpeedControl && $0.allowedSpeedTiers.count > 1 }),
              let plainRoute = ChatRouteChoice.all.first(where: { !$0.supportsNativeSpeedControl && $0.supportsNativeReasoningControl
                                                                && AssistantModelRouting.engineKind(for: $0) == .claude }) else {
            check(false, "C0 fixture: a route with speed tiers and a Claude route without")
            return
        }
        var mode = coderMode(false)
        check(mode.eyebrow == "ULTRAWORK" && mode.collaboration?.level == .off && mode.title == "單模型模式"
              && mode.badge?.text == "確認後 · 可執行" && mode.models.count == 1 && mode.models[0].role == "模型"
              && mode.footnote?.text == "執行權限綁定 Goal、角色與受控輸出根。",
              "C1 the card is the ULTRAWORK card: ULTRAWORK / 單模型模式 / 確認後 · 可執行, one model row, the permission line")
        check(mode.segments.map(\.identifier) == ["chat-composer-model", "tatwo-memory-strength", "chat-composer-ultrawork"]
              && mode.segments.last?.text == "ultrawork" && mode.segments.last?.dimmed == true,
              "C1 the chip reads model · 記憶 · ultrawork (off = dim); each part keeps an identifier",
              mode.segments.map { "\($0.identifier)=\($0.text)" }.joined(separator: " "))
        check(mode.segments.last?.short == "" && mode.segments.last?.icon == "target"
              && mode.segments.first(where: { $0.id == "memory" }).map { $0.short.hasPrefix("記") } == true,
              "C1 narrow chip (查核 #6): ultrawork off keeps its dim icon, memory reads 記淺 / 記憶關 (not a bare 淺)",
              mode.segments.map { "\($0.id)=\($0.short)" }.joined(separator: " "))

        // 模型：換到有速度檔的模型、再換到沒有速度檔的 Claude。
        mode.models[0].choose(speedRoute.id)
        mode = coderMode(false)
        check(model.selectedModel == speedRoute.id && model.pendingModelID == nil
              && mode.speed?.options.map(\.id) == speedRoute.allowedSpeedTiers.map(\.rawValue)
              && mode.effort?.options.map(\.id) == speedRoute.allowedEfforts.map(\.rawValue),
              "C2 model row → \(speedRoute.title): ChatPageModel.selectedModel changed; 速度 lists exactly its tiers, 推理強度 its efforts",
              "selected=\(model.selectedModel) speed=\(mode.speed?.options.map(\.id) ?? [])")
        mode.speed?.choose(TatwoModelSpeedTier.standard.rawValue)
        mode = coderMode(false)
        check(model.selectedSpeedTier == .standard && engine.threadRecord(thread)?.requestedSpeedTier == "standard"
              && mode.speed?.selectedTitle == "標準"
              && mode.segments.first?.text == "\(TatwoComposerMode.shortModelName(speedRoute)) 標準",
              "C3 速度 → 標準: selectedSpeedTier and the thread's saved speed changed; the chip reads「\(TatwoComposerMode.shortModelName(speedRoute)) 標準」",
              "tier=\(model.selectedSpeedTier) saved=\(engine.threadRecord(thread)?.requestedSpeedTier ?? "nil") chip=\(mode.segments.first?.text ?? "")")
        mode.effort?.choose(TatwoCodexReasoningEffort.low.rawValue)
        mode = coderMode(false)
        check(model.selectedEffort == .low && engine.threadRecord(thread)?.requestedEffort == "low" && mode.effort?.selectedTitle == "低",
              "C4 推理強度 → 低: selectedEffort and the thread's saved effort changed")
        mode.models[0].choose(plainRoute.id)
        mode = coderMode(false)
        // 守（W184 H4 修正：審查 #1）：Claude 的 sidecar 不收推理強度——卡上照樣列出、變淡、寫原因，chip 不寫送不出去的推理強度
        // （以前這裡亮著、chip 寫「高」，送出卻只有 Codex 帶 effort）。
        check(model.selectedModel == plainRoute.id && mode.speed == nil
              && mode.effort?.isEnabled == false && mode.effort?.selectedID == nil
              && mode.effort?.note == TatwoComposerMode.effortNotForwarded
              && mode.segments.first?.text == TatwoComposerMode.shortModelName(plainRoute),
              "C5 (審查 #1) switching to \(plainRoute.title) (no speed tiers; its engine takes no effort): 速度 is not listed, 推理強度 is listed dimmed with the reason, the chip shows no effort",
              "speed=\(String(describing: mode.speed?.options.map(\.id))) effort=\(String(describing: mode.effort?.isEnabled))/\(mode.effort?.note ?? "nil") chip=\(mode.segments.first?.text ?? "")")
        mode.models[0].choose(speedRoute.id)
        mode = coderMode(false)
        check(model.selectedModel == speedRoute.id && speedRoute.allowedSpeedTiers.contains(model.selectedSpeedTier)
              && mode.speed?.selectedID == model.selectedSpeedTier.rawValue,
              "C5 back to \(speedRoute.title): 速度 comes back inside its allowed tiers (allowedSpeedTiers)")
        // C3、C4 的值照卡上改回來（換模型時不在新模型允許的檔位就換預設），後面 C8 量送出時讀的參數。
        mode.speed?.choose(TatwoModelSpeedTier.standard.rawValue)
        mode.effort?.choose(TatwoCodexReasoningEffort.low.rawValue)
        mode = coderMode(false)

        // 記憶：只改這一條。
        mode.memory?.choose(TatwoMemoryStrength.deep.rawValue)
        mode = coderMode(false)
        check(engine.threadRecord(thread)?.memoryStrength == "deep" && engine.threadRecord(botThread)?.memoryStrength == nil
              && mode.memory?.selectedTitle == "深" && mode.segments.map(\.text).contains("記憶深"),
              "C6 記憶 → 深: only this thread's memory strength changed; the chip reads 記憶深")

        // ultrawork：S～XXL、角色、電源。W184 H4 修正（查核 #8）：開著時「模型」那一列照樣在、排在角色前面。
        let modelBeforeOn = model.selectedModel, requestedBeforeOn = engine.threadRecord(thread)?.requestedModel
        mode.collaboration?.setLevel(.l)
        mode = coderMode(false)
        // 守（審查 #3）：檔位記在這一條（thread 的偏好），Coder 的 collaborationLevel 跟著這一條；開 ultrawork 不換這條的模型。
        check(model.collaborationLevel == .l && engine.threadRecord(thread)?.ultrawork?.level == ChatCollaborationLevel.l.rawValue
              && mode.title == "L 協作編制"
              && mode.models.map(\.role) == ["模型", "主導", "副審", "sub"]
              && mode.models.map(\.identifier) == ["tatwo.composer.mode.model", "ultrawork-role-primary", "ultrawork-role-輔1", "ultrawork-role-輔2"]
              && mode.segments.last?.text == "ultrawork L" && mode.segments.last?.emphasized == true
              && model.selectedModel == modelBeforeOn && engine.threadRecord(thread)?.requestedModel == requestedBeforeOn,
              "C7 (審查 #3) S～XXL → L: stored in this thread's preferences; the card lists 模型 first, then 主導, 副審, sub; the chip reads ultrawork L; turning it on does not swap the thread's model",
              "level=\(model.collaborationLevel.title) stored=\(String(describing: engine.threadRecord(thread)?.ultrawork)) roles=\(mode.models.map(\.role))")
        let lead = ChatRouteChoice.all.first { $0.canonicalModelSlug != model.ultraworkRoleModelID(.primary, for: thread) } ?? speedRoute
        let selectedBeforeRole = model.selectedModel
        mode.models[1].choose(lead.id)
        mode = coderMode(false)
        check(roles.picks.last == "主=\(lead.canonicalModelSlug)" && model.ultraworkPrimaryModelID == lead.canonicalModelSlug
              && engine.threadRecord(thread)?.ultrawork?.primaryModelID == lead.canonicalModelSlug
              && mode.models[1].detail == lead.canonicalModelSlug && model.selectedModel == selectedBeforeRole,
              "C7 the 主導 row picks a model through the same role path (setUltraworkRole on this thread, as ChatPage.selectCollaborationRoleModel); this thread's model stays")
        // C7c（審查 #5）：sub（第二個副手）也換得到、也記在這一條——以前只有 index 0 會寫進去，其他的只存成全域預設。
        let subBefore = model.ultraworkRoleModelID(.auxiliary(1), for: thread)
        if let sub = mode.models[3].options.first(where: { ChatRouteChoice.resolve($0.id).canonicalModelSlug != subBefore && !$0.isDisabled }) {
            mode.models[3].choose(sub.id)
            mode = coderMode(false)
            let stored = engine.threadRecord(thread)?.ultrawork?.auxiliaryModelIDs ?? []
            check(stored.count == UltraworkTurnSettings.maxAuxiliaries && stored.indices.contains(1)
                  && stored[1] == ChatRouteChoice.resolve(sub.id).canonicalModelSlug
                  && mode.models[3].detail == ChatRouteChoice.resolve(sub.id).canonicalModelSlug,
                  "C7c (審查 #5) the sub row (second helper) is written into this thread's role list too (the whole list, not only index 0)",
                  "stored=\(stored)")
        } else {
            check(false, "C7c (審查 #5) fixture: another model for the sub row")
        }
        // C7b（查核 #8 反例）：ultrawork 開著時換「模型」那一列＝換這一輪真的用的模型（selectedModel、送出的模型參數），主導不動。
        let primaryBefore = model.ultraworkPrimaryModelID
        if let other = ChatRouteChoice.all.first(where: { $0.id != speedRoute.id && AssistantModelRouting.engineKind(for: $0) != nil
                                                          && ($0.modelArgument ?? $0.canonicalModelSlug) != (speedRoute.modelArgument ?? speedRoute.canonicalModelSlug) }) {
            mode.models[0].choose(other.id)
            mode = coderMode(false)
            let argument = model.routeChoice.modelArgument ?? model.routeChoice.canonicalModelSlug
            check(model.selectedModel == other.id && model.ultraworkPrimaryModelID == primaryBefore && model.collaborationLevel == .l
                  && argument == (other.modelArgument ?? other.canonicalModelSlug)
                  && mode.models[0].title == TatwoComposerMode.cardModelName(other)
                  && mode.segments.first.map { $0.text.hasPrefix(TatwoComposerMode.shortModelName(other)) } == true,
                  "C7b (查核 #8) with ultrawork L the 模型 row changes the model this turn is sent with (selectedModel → \(argument)); 主導 stays",
                  "selected=\(model.selectedModel) primary=\(model.ultraworkPrimaryModelID ?? "nil") argument=\(argument)")
            mode.models[0].choose(speedRoute.id)
            mode = coderMode(false)
            mode.speed?.choose(TatwoModelSpeedTier.standard.rawValue)
            mode.effort?.choose(TatwoCodexReasoningEffort.low.rawValue)
            mode = coderMode(false)
        } else {
            check(false, "C7b (查核 #8) fixture: a second route with a different model argument")
        }
        // C8：卡改完之後這一條記著的值（W184 H4 修正：審查 #10——這裡只看狀態；真的送到引擎的是哪些，由 P 段的替身腳本看 sidecar 收到的）。
        let settings = model.ultraworkSettings(for: thread)
        let briefing = settings.briefing ?? ""
        let kind = AssistantModelRouting.engineKind(for: model.routeChoice)
        check(kind == .codex && model.selectedEffort.codexRawValue == "low" && model.selectedSpeedTier.appServerValue == "default"
              && settings.level == ChatCollaborationLevel.l.rawValue && settings.primaryModelID == lead.canonicalModelSlug
              && settings.auxiliaryModelIDs.count == UltraworkTurnSettings.maxAuxiliaries
              && briefing.contains("檔位：L") && briefing.contains("主導：\(lead.canonicalModelSlug)") && briefing.contains("副審：")
              && briefing.contains("sub 1：") && engine.doc.memoryStrength(for: thread) == .deep,
              "C8 (state, not the send path) this thread after the card: effort low, speed 標準, ultrawork L with 主導 and every helper (副審, sub 1), memory deep",
              "kind=\(String(describing: kind)) effort=\(model.selectedEffort.codexRawValue) tier=\(model.selectedSpeedTier.appServerValue) settings=\(settings)")
        let planOn = coderMode(true)
        check(planOn.models.map(\.role) == ["主導", "副審", "sub"] && planOn.models.allSatisfy { $0.id.hasPrefix("role-") },
              "C10 (查核 #10) the Plan canvas card at L lists only the roles (no 模型 row that would change the execution model)",
              "\(planOn.models.map(\.role))")
        let modelBeforeOff = model.selectedModel, requestedBeforeOff = engine.threadRecord(thread)?.requestedModel
        mode.collaboration?.setLevel(.off)
        mode = coderMode(false)
        // 守（審查 #3）：關掉不換這條的模型（開的時候也沒換，所以沒有要還原的）；角色留著，再開照舊。
        check(model.collaborationLevel == .off && model.ultraworkTurnBriefing == nil && mode.models.count == 1
              && mode.segments.last?.text == "ultrawork" && engine.threadRecord(thread)?.ultrawork?.level == 0
              && engine.threadRecord(thread)?.ultrawork?.primaryModelID == lead.canonicalModelSlug
              && model.selectedModel == modelBeforeOff && engine.threadRecord(thread)?.requestedModel == requestedBeforeOff,
              "C9 (審查 #3) the power button (level off) goes back to one model: stored off in this thread, roles kept, the thread's model unchanged")
        let plan = coderMode(true)
        check(plan.collaboration != nil && plan.speed == nil && plan.effort == nil && plan.memory == nil && plan.models.isEmpty,
              "C10 the Plan canvas card only carries the collaboration part (ULTRAWORK + roles), like before; off = no model row at all",
              "models=\(plan.models.map(\.role))")

        model.mode = .cli
        let cli = coderMode(false)
        model.mode = .chat
        model.selectedThreadID = botThread
        let botCoder = coderMode(false)
        model.selectedThreadID = thread
        check(cli.memory == nil && !cli.segments.contains { $0.identifier == "tatwo-memory-strength" }
              && botCoder.memory == nil && !botCoder.segments.contains { $0.id == "memory" }
              && coderMode(false).memory != nil,
              "C11 記憶 only in Coder chats: none in CLI, none on a Bot thread")

        // C12（審查 #9）：這一輪在這台跑：這台送不出的那家在模型清單與每一個角色清單都變淡、標「已停用」；Coder 走別台（selectedRemote，
        // 例 MacBook 走主設備）時不拿這台的停用擋——那台自己會擋——並寫一句在哪台跑。
        let current = AssistantModelRouting.engineKind(for: model.routeChoice)
        if let blocked = ClaudeSidecar.Kind.allCases.first(where: { $0 != current }) {
            model.disabledEngines = [blocked.rawValue]
            model.setCollaborationLevel(.m)
            let local = coderMode(false)
            func blockedRows(_ row: TatwoComposerMode.ModelRow) -> [TatwoComposerMode.ModelOption] {
                row.options.filter { AssistantModelRouting.engineKind(for: ChatRouteChoice.resolve($0.id)) == blocked }
            }
            let localMarked = local.models.allSatisfy { row in
                let rows = blockedRows(row)
                return !rows.isEmpty && rows.allSatisfy { $0.isDisabled && $0.title.contains("已停用") }
            } && local.models.allSatisfy { row in row.options.filter { !blockedRows(row).map(\.id).contains($0.id) }.allSatisfy { !$0.isDisabled } }
            model.selectedRemote = ("w184-mode-remote", thread)
            let remote = coderMode(false)
            let remoteClear = remote.models.allSatisfy { $0.options.allSatisfy { !$0.isDisabled } }
                && remote.modelNote?.contains("上跑") == true
            model.selectedRemote = nil
            model.disabledEngines = []
            model.setCollaborationLevel(.off)
            check(localMarked && remoteClear && local.models.count == 3,
                  "C12 (審查 #9) runs here: the engine this Mac cannot send is dimmed and marked 已停用 in the model list and every role list; runs on another device: nothing is blocked by this Mac, the card says where it runs",
                  "localMarked=\(localMarked) remoteClear=\(remoteClear) note=\(remote.modelNote ?? "nil") rows=\(local.models.map(\.role))")
        } else {
            check(false, "C12 (審查 #9) fixture: an engine other than the current one")
        }
    }

    // MARK: - D 私訊框

    /// 主設備的最小替身（不連 SSH、不送出）：只有助理那一條；running＝那條回覆中。
    @MainActor final class ModePrimaryDouble: AssistantRemoteEngine {
        var doc: LiveDocumentRecord
        var running = false

        init() {
            var document = LiveDocumentRecord()
            _ = document.ensureAssistantThread()
            doc = document
        }

        func transcript(for threadID: UUID?) -> [ChatMessage] { [] }
        func isTranscriptLoading(_ threadID: UUID?) -> Bool { false }
        func isRunning(_ threadID: UUID?) -> Bool { running }
        func threadRecord(_ threadID: UUID?) -> LiveThreadRecord? { doc.threads.first { $0.id == threadID } }
        func deliver(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind?, assistantRoute: String?,
                     completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            completion(.failure(RemoteHostLinkError.remoteError("w184mode double never sends")))
        }
        func stop(threadID: UUID) {}
    }

    @MainActor static func dmChecks(_ check: Checker, model: ChatPageModel, store: GlobalDMStore, engine: ChatLiveEngine,
                                    thread: UUID, botThread: UUID) {
        guard let speedRoute = ChatRouteChoice.all.first(where: { $0.supportsNativeSpeedControl && $0.allowedSpeedTiers.count > 1
                                                                 && AssistantModelRouting.engineKind(for: $0) == .codex }) else {
            check(false, "D0 fixture: a Codex route with speed tiers")
            return
        }
        store.select(.assistant)
        guard var mode = TatwoComposerMode.dm(store: store) else {
            check(false, "D1 the assistant has a mode card")
            return
        }
        check(mode.eyebrow == "ULTRAWORK" && mode.collaboration?.isEnabled == false
              && mode.collaboration?.note?.contains("助理不使用 ultrawork") == true && mode.memory != nil
              && mode.models.count == 1
              && mode.segments.map(\.identifier) == ["tatwo.dm.model", "tatwo-memory-strength"],
              "D1 DM assistant (查核 #1): S～XXL is on the card but off and says the assistant's send carries no ultrawork; 模型 and 記憶; old identifiers on the chip parts",
              mode.segments.map(\.identifier).joined(separator: " "))
        let options = mode.models[0].options
        check(options.map(\.id) == TatwoComposerMode.assistantOptions(model.assistantModelOptions).map(\.id)
              && options.filter(\.isSelected).count == 1,
              "D1 the model list is the assistant's own menu (same routes, one checked)")
        // D1b（查核 #17 反例）：停用一家引擎：卡上那家的每一列都變淡、標「已停用」，跟 store 的選單逐列一致。
        let current = AssistantModelRouting.engineKind(for: model.assistantRouteChoice)
        if let blocked = store.modelOptions(for: .assistant).compactMap({ AssistantModelRouting.engineKind(for: $0.route) })
            .first(where: { $0 != current }) {
            model.disabledEngines = [blocked.rawValue]
            let rows = TatwoComposerMode.dm(store: store)?.models.first?.options ?? []
            let menu = Dictionary(store.modelOptions(for: .assistant).map { ($0.route.id, $0.isDisabled) }, uniquingKeysWith: { first, _ in first })
            let marked = rows.filter { AssistantModelRouting.engineKind(for: ChatRouteChoice.resolve($0.id)) == blocked }
            check(!marked.isEmpty && marked.allSatisfy { $0.isDisabled && $0.title.contains("已停用") }
                  && rows.count == menu.count && rows.allSatisfy { menu[$0.id] == $0.isDisabled },
                  "D1b (查核 #17) a disabled engine's rows are dimmed and marked 已停用 on the card, row by row the same as the store's menu",
                  "marked=\(marked.map { "\($0.title)/\($0.isDisabled)" })")
            model.disabledEngines = []
        } else {
            check(false, "D1b (查核 #17) fixture: a second engine to disable")
        }
        if let other = options.first(where: { !$0.isSelected && !$0.isDisabled }) {
            mode.models[0].choose(other.id)
            mode = TatwoComposerMode.dm(store: store) ?? mode
            let route = ChatRouteChoice.resolve(other.id)
            check(store.modelChipTitle == AssistantModelRouting.chipName(route) && mode.segments.first?.text.hasPrefix(store.modelChipTitle) == true
                  && model.assistantRouteChoice.id == route.id,
                  "D2 picking a model changes the assistant's model (setAssistantModel) and the chip summary",
                  "chip=\(store.modelChipTitle) route=\(model.assistantRouteChoice.id)")
        } else {
            check.skip("D2 no second enabled model for the assistant in this environment")
        }
        mode.memory?.choose(TatwoMemoryStrength.light.rawValue)
        mode = TatwoComposerMode.dm(store: store) ?? mode
        check(model.memoryChipState(.assistant)?.strength == .light && mode.memory?.selectedTitle == "淺"
              && mode.segments.map(\.text).contains("記憶淺") && engine.doc.memoryStrength(for: thread) == .deep,
              "D3 記憶 → 淺 changes only the assistant (the Coder thread keeps 深)")

        // D-speed（查核 #1）：助理在這台跑、模型是 Codex 系：速度、推理強度寫回助理那一條（sendToLocalAssistant 讀的那兩個欄位）。
        let coderModelBefore = model.selectedModel
        store.chooseModel(speedRoute.id, for: .assistant)
        if let assistant = model.assistantThreadID, var tuned = TatwoComposerMode.dm(store: store),
           tuned.speed != nil, tuned.effort != nil {
            let targetTier: TatwoModelSpeedTier = engine.threadRecord(assistant)?.requestedSpeedTier == TatwoModelSpeedTier.standard.rawValue
                ? .fast : .standard
            tuned.speed?.choose(targetTier.rawValue)
            tuned.effort?.choose(TatwoCodexReasoningEffort.low.rawValue)
            tuned = TatwoComposerMode.dm(store: store) ?? tuned
            let record = engine.threadRecord(assistant)
            check(record?.requestedSpeedTier == targetTier.rawValue && record?.requestedEffort == "low"
                  && record?.requestedModel == speedRoute.id && tuned.speed?.selectedID == targetTier.rawValue
                  && tuned.segments.first?.text == "\(store.modelChipTitle) \(TatwoComposerMode.speedTitle(targetTier))"
                  && engine.threadRecord(thread)?.requestedEffort == "low" && model.selectedModel == coderModelBefore,
                  "D-speed (查核 #1) DM assistant: 速度 and 推理強度 write the assistant thread's own preferences (what its send reads); the chip shows the speed",
                  "tier=\(record?.requestedSpeedTier ?? "nil") effort=\(record?.requestedEffort ?? "nil") chip=\(tuned.segments.first?.text ?? "")")
        } else {
            check(false, "D-speed (查核 #1) DM assistant on a Codex model lists 速度 and 推理強度")
        }

        store.select(.thread(thread))
        if let session = TatwoComposerMode.dm(store: store), let pick = session.models[0].options.first(where: { !$0.isSelected && !$0.isDisabled }) {
            session.models[0].choose(pick.id)
            check(engine.threadRecord(thread)?.requestedModel == pick.id
                  && session.title == TatwoComposerMode.collaborationTitle(model.ultraworkSettings(for: thread).collaborationLevel)
                  && session.memory != nil,
                  "D4 a Coder session in the DM: its model changes only that thread (setDMSessionModel); memory is there",
                  "requested=\(engine.threadRecord(thread)?.requestedModel ?? "nil") pick=\(pick.id)")
        } else {
            check(false, "D4 a Coder session in the DM has a mode card with another model to pick")
        }
        // D-ultrawork（GPT-6 審查 #3、#5）：卡上改的是這一條 session 自己的 ultrawork（sendFromDM 帶的就是它）。這條剛好也是主視窗 Coder
        // 開著的那條：兩邊一起變（Coder 的 collaborationLevel 跟著）。以前改的是共用的 collaborationLevel——另一條 session 也會被改到
        // （不同條的隔離在 P 段 I1：真的送出去看）。開著時角色（主導、副審）也列、也改那一條。
        if let session = TatwoComposerMode.dm(store: store), session.collaboration?.isEnabled == true {
            session.collaboration?.setLevel(.m)
            let after = TatwoComposerMode.dm(store: store)
            check(model.ultraworkSettings(for: thread).level == ChatCollaborationLevel.m.rawValue
                  && engine.threadRecord(thread)?.ultrawork?.level == ChatCollaborationLevel.m.rawValue && model.collaborationLevel == .m
                  && session.collaboration?.note?.contains("兩邊一起變") == true
                  && after?.segments.last?.identifier == "tatwo.dm.ultrawork" && after?.segments.last?.text == "ultrawork M"
                  && after?.title == "M 協作編制" && after?.models.map(\.role) == ["模型", "主導", "副審"],
                  "D-ultrawork (審查 #3、#5) DM session = the thread open in Coder: S～XXL writes that thread's own ultrawork and Coder follows; 主導 and 副審 are listed",
                  "stored=\(String(describing: engine.threadRecord(thread)?.ultrawork)) coder=\(model.collaborationLevel.title) roles=\(after?.models.map(\.role) ?? [])")
            if let reviewer = after?.models.last,
               let pick = reviewer.options.first(where: { !$0.isSelected && !$0.isDisabled }) {
                reviewer.choose(pick.id)
                check(engine.threadRecord(thread)?.ultrawork?.auxiliaryModelIDs.first == ChatRouteChoice.resolve(pick.id).canonicalModelSlug
                      && model.ultraworkSecondaryModelID == ChatRouteChoice.resolve(pick.id).canonicalModelSlug,
                      "D-roles (審查 #5) the DM card's 副審 row writes that thread's 副審 (Coder shows the same)",
                      "stored=\(String(describing: engine.threadRecord(thread)?.ultrawork))")
            } else {
                check(false, "D-roles (審查 #5) fixture: another model for 副審")
            }
            model.setCollaborationLevel(.off)
        } else {
            check(false, "D-ultrawork (審查 #3) a local Coder session in the DM lists S～XXL")
        }
        // D-session speed：這條也是 Coder 開著的那條：寫回那一條，Coder 的輸入框跟著重讀（同 setDMSessionModel）。
        store.chooseModel(speedRoute.id, for: .thread(thread))
        if let session = TatwoComposerMode.dm(store: store), session.speed != nil {
            let next: TatwoModelSpeedTier = model.selectedSpeedTier == .fast ? .standard : .fast
            session.speed?.choose(next.rawValue)
            check(engine.threadRecord(thread)?.requestedSpeedTier == next.rawValue && model.selectedSpeedTier == next
                  && engine.threadRecord(thread)?.requestedModel == speedRoute.id,
                  "D-speed (查核 #1) DM session: 速度 writes that thread (what sendFromDM reads); Coder's composer re-reads it (same thread open in Coder)",
                  "saved=\(engine.threadRecord(thread)?.requestedSpeedTier ?? "nil") coder=\(model.selectedSpeedTier)")
        } else {
            check(false, "D-speed (查核 #1) a local Coder session on a Codex model lists 速度")
        }
        store.select(.thread(botThread))
        let botSession = TatwoComposerMode.dm(store: store)
        check(botSession != nil && botSession?.memory == nil && botSession?.segments.contains { $0.id == "memory" } == false,
              "D5 a Bot thread shows no memory (Bot 不顯示)")
        store.select(.chatGPT)
        check(TatwoComposerMode.dm(store: store) == nil, "D6 the ChatGPT target has no mode card (its composer follows ChatGPT)")

        // D7／D8：副設備接主設備（主設備替身）：這一台送出只帶模型——速度、推理強度、ultrawork 照那邊的設定（變淡、寫原因）；回覆中模型列停用。
        let primary = ModePrimaryDouble()
        model.assistantPrimaryTestDouble = (device: AssistantPrimaryDevice(id: "w184-mode-primary", displayName: "Primary One"),
                                            engine: { primary }, connecting: { false })
        defer { model.assistantPrimaryTestDouble = nil }
        store.select(.assistant)
        store.chooseModel(speedRoute.id, for: .assistant)
        let remote = TatwoComposerMode.dm(store: store)
        let remoteNote = remote?.effort?.note ?? remote?.speed?.note ?? ""
        check(model.assistantPlacement.isPrimary && remote?.speed?.isEnabled == false && remote?.speed?.selectedID == nil
              && remoteNote.contains("主設備「Primary One」") && remote?.collaboration?.isEnabled == false
              && remote?.models.first?.isEnabled == true && remote?.segments.first?.text == store.modelChipTitle,
              "D7 (查核 #1) assistant on the primary: 速度 and 推理強度 are listed but dimmed — the primary decides — and the card says so; the model row still works",
              "note=\(remoteNote) speed=\(String(describing: remote?.speed?.isEnabled))")
        primary.running = true
        let busy = TatwoComposerMode.dm(store: store)
        check(!store.canChooseModel && busy?.models.first?.isEnabled == false && busy?.segments.first?.dimmed == true
              && busy?.modelNote == store.modelChipHelp && store.modelChipHelp == "回覆中不換模型",
              "D8 (查核 #15) while it answers: the card's model row is off (no list opens), the chip's model part is dim, the card says 回覆中不換模型",
              "enabled=\(String(describing: busy?.models.first?.isEnabled)) note=\(busy?.modelNote ?? "nil")")
        primary.running = false
        model.assistantPrimaryTestDouble = nil
        store.select(.assistant)
    }

    // MARK: - A TATWO 助理頁（W184 H4b）

    /// 一張卡逐項的文字描述（助理頁與私訊框助理的卡比對用）：標題、模型列（含清單、能不能選）、說明、ultrawork 那排、速度、推理強度、記憶、chip 各段。
    @MainActor static func cardLines(_ mode: TatwoComposerMode) -> [String] {
        func steps(_ name: String, _ value: TatwoComposerMode.Steps?) -> String {
            guard let value else { return "\(name): -" }
            let options = value.options.map { "\($0.id)=\($0.title)" }.joined(separator: ",")
            return "\(name): \(value.title) [\(options)] selected=\(value.selectedID ?? "nil") enabled=\(value.isEnabled) "
                + "detail=\(value.detail ?? "-") note=\(value.note ?? "-")"
        }
        var lines = ["title: \(mode.eyebrow) / \(mode.title) / \(mode.modelHeading) / note=\(mode.modelNote ?? "-")"]
        for row in mode.models {
            let options = row.options.map { "\($0.id)=\($0.title)/\($0.brand.rawValue)/sel=\($0.isSelected)/off=\($0.isDisabled)" }
                .joined(separator: ",")
            lines.append("row: \(row.role) \(row.title) detail=\(row.detail ?? "-") enabled=\(row.isEnabled) [\(options)]")
        }
        lines.append(mode.collaboration.map { "ultrawork: level=\($0.level.title) enabled=\($0.isEnabled) note=\($0.note ?? "-")" } ?? "ultrawork: -")
        lines.append(steps("speed", mode.speed))
        lines.append(steps("effort", mode.effort))
        lines.append(steps("memory", mode.memory))
        lines.append("chip: " + mode.segments.map { "\($0.text)/\($0.short)/\($0.icon ?? "-")/emph=\($0.emphasized)/dim=\($0.dimmed)" }
            .joined(separator: " | "))
        return lines
    }

    /// 助理頁那張卡跟私訊框助理那張卡逐項一樣嗎（同一條助理、同一條送出路徑；識別碼與滑過的說明字不同，不比）；nil＝一樣，否則寫第一個不一樣的地方。
    @MainActor static func assistantCardDifference(model: ChatPageModel, store: GlobalDMStore) -> String? {
        store.select(.assistant)
        guard let dm = TatwoComposerMode.dm(store: store) else { return "the DM has no card for the assistant" }
        let page = cardLines(TatwoComposerMode.assistantSpace(model: model)), other = cardLines(dm)
        for (index, pair) in zip(page, other).enumerated() where pair.0 != pair.1 {
            return "line \(index): page=\(pair.0) | dm=\(pair.1)"
        }
        return page.count == other.count ? nil : "line count: page \(page.count) vs dm \(other.count)"
    }

    /// 助理頁的模式卡：整張卡跟私訊框助理那張逐項一樣；模型、速度、推理強度、記憶各自改了之後，助理那一條的值真的變了、Coder 的不動；
    /// 接主設備時、回覆中、引擎停用時照原本的規則（列出、變淡、寫原因）。
    @MainActor static func assistantPageChecks(_ check: Checker, model: ChatPageModel, store: GlobalDMStore, engine: ChatLiveEngine,
                                               thread: UUID) {
        guard let speedRoute = ChatRouteChoice.all.first(where: { $0.supportsNativeSpeedControl && $0.allowedSpeedTiers.count > 1
                                                                 && AssistantModelRouting.engineKind(for: $0) == .codex }),
              let assistant = model.assistantThreadID else {
            check(false, "A0 fixture: a Codex route with speed tiers and the assistant's own thread")
            return
        }
        store.select(.assistant)
        var mode = TatwoComposerMode.assistantSpace(model: model)
        let cardShape = mode.eyebrow == "ULTRAWORK" && mode.title == "TATWO 助理" && mode.models.count == 1 && mode.models[0].role == "模型"
        let ultraworkOff = mode.collaboration?.isEnabled == false && mode.collaboration?.note?.contains("助理不使用 ultrawork") == true
        let chipNames = mode.segments.map(\.identifier) == ["tatwo-assistant-model", "tatwo-memory-strength"]
            && mode.segments.first?.accessibilityLabel.hasPrefix("助理的模型：") == true
        check(cardShape && ultraworkOff && chipNames && mode.memory != nil && mode.help == "助理的模型，不更動 Coder",
              "A1 TATWO assistant page: the ULTRAWORK card titled TATWO 助理 with one model row, S～XXL on it but off with the reason, 記憶; the chip parts keep tatwo-assistant-model / tatwo-memory-strength and the name「助理的模型：…」",
              "\(mode.title) ids=\(mode.segments.map(\.identifier)) label=\(mode.segments.first?.accessibilityLabel ?? "nil")")
        var difference = assistantCardDifference(model: model, store: store)
        check(difference == nil, "A2 the page's card equals the DM assistant's card line by line (title, model list, 速度, 推理強度, 記憶, ultrawork, chip) — same assistant, same send path",
              difference ?? "")

        // 模型：換到另一家的模型（沒有速度、推理強度），助理那一條的模型真的變了、Coder 的不動；再換回有速度檔的。
        let coderModel = model.selectedModel
        if let other = mode.models[0].options.first(where: { !$0.isSelected && !$0.isDisabled
                                                            && AssistantModelRouting.engineKind(for: ChatRouteChoice.resolve($0.id)) == .claude }) {
            mode.models[0].choose(other.id)
            mode = TatwoComposerMode.assistantSpace(model: model)
            let route = ChatRouteChoice.resolve(other.id)
            let changed = model.assistantRouteChoice.id == route.id && model.selectedModel == coderModel
            let chipReads = mode.segments.first?.text == AssistantModelRouting.chipName(route)
                && mode.segments.first?.text == model.assistantModelChipTitle
            // 守（審查 #1）：這一家的引擎不收推理強度：照樣列出、變淡、寫原因（以前不列；Coder、私訊框、助理頁同一套）。
            check(changed && chipReads && mode.speed == nil && mode.effort?.isEnabled == false
                  && mode.effort?.note == TatwoComposerMode.effortNotForwarded,
                  "A3 the 模型 row → \(route.title): the assistant's model changed through setAssistantModel and the chip reads it; Coder's model stays; no 速度, 推理強度 dimmed with the reason (審查 #1)",
                  "route=\(model.assistantRouteChoice.id) chip=\(mode.segments.first?.text ?? "nil") coder=\(model.selectedModel)")
            difference = assistantCardDifference(model: model, store: store)
            check(difference == nil, "A2 [Claude model] the page's card equals the DM assistant's card", difference ?? "")
        } else {
            check(false, "A3 fixture: an enabled model from another engine in the assistant's list")
        }
        mode.models[0].choose(speedRoute.id)
        mode = TatwoComposerMode.assistantSpace(model: model)

        // 速度、推理強度：寫回助理那一條（送出時 sendToLocalAssistant 讀的那兩個欄位）。
        let coderTier = model.selectedSpeedTier, coderEffort = model.selectedEffort
        let coderSaved = engine.threadRecord(thread)?.requestedEffort
        if mode.speed != nil, mode.effort != nil {
            let tier: TatwoModelSpeedTier = mode.speed?.selectedID == TatwoModelSpeedTier.standard.rawValue ? .fast : .standard
            let effort: TatwoCodexReasoningEffort = mode.effort?.selectedID == TatwoCodexReasoningEffort.low.rawValue ? .medium : .low
            mode.speed?.choose(tier.rawValue)
            mode.effort?.choose(effort.rawValue)
            mode = TatwoComposerMode.assistantSpace(model: model)
            let record = engine.threadRecord(assistant)
            let saved = record?.requestedSpeedTier == tier.rawValue && record?.requestedEffort == effort.codexRawValue
                && record?.requestedModel == speedRoute.id
            let cardReads = mode.speed?.selectedID == tier.rawValue && mode.effort?.selectedID == effort.rawValue
            let chipText = "\(model.assistantModelChipTitle) \(TatwoComposerMode.speedTitle(tier))"
            let coderKept = model.selectedSpeedTier == coderTier && model.selectedEffort == coderEffort
                && engine.threadRecord(thread)?.requestedEffort == coderSaved
            check(saved && cardReads && mode.segments.first?.text == chipText && coderKept,
                  "A4 速度 and 推理強度 write the assistant thread's own preferences (what its send reads); the chip reads the speed; Coder's speed, effort and thread stay",
                  "tier=\(record?.requestedSpeedTier ?? "nil") effort=\(record?.requestedEffort ?? "nil") chip=\(mode.segments.first?.text ?? "nil")")
            difference = assistantCardDifference(model: model, store: store)
            check(difference == nil, "A2 [Codex model, tuned] the page's card equals the DM assistant's card", difference ?? "")
        } else {
            check(false, "A4 fixture: the assistant on \(speedRoute.title) lists 速度 and 推理強度")
        }

        // 記憶：只改助理那一條（Coder 那條的記憶不動）。
        let coderMemory = engine.doc.memoryStrength(for: thread)
        for strength in [TatwoMemoryStrength.off, .medium] {
            mode.memory?.choose(strength.rawValue)
            mode = TatwoComposerMode.assistantSpace(model: model)
            let written = engine.doc.memoryStrength(for: assistant) == strength && engine.doc.memoryStrength(for: thread) == coderMemory
            let shown = mode.memory?.selectedID == strength.rawValue && mode.segments.map(\.text).contains("記憶\(strength.title)")
            check(written && shown,
                  "A5 記憶 → \(strength.title): only the assistant's thread changed (Coder stays \(coderMemory.title)); the chip reads 記憶\(strength.title)",
                  "assistant=\(engine.doc.memoryStrength(for: assistant).title) coder=\(engine.doc.memoryStrength(for: thread).title)")
        }

        // 引擎停用：停用那一家的每一列變淡、標「已停用」，跟助理原本的選單（assistantModelOptions）逐列一致。
        let current = AssistantModelRouting.engineKind(for: model.assistantRouteChoice)
        if let blocked = model.assistantModelOptions.compactMap({ AssistantModelRouting.engineKind(for: $0.route) }).first(where: { $0 != current }) {
            model.disabledEngines = [blocked.rawValue]
            let rows = TatwoComposerMode.assistantSpace(model: model).models.first?.options ?? []
            let menu = Dictionary(model.assistantModelOptions.map { ($0.route.id, $0.isDisabled) }, uniquingKeysWith: { first, _ in first })
            let marked = rows.filter { AssistantModelRouting.engineKind(for: ChatRouteChoice.resolve($0.id)) == blocked }
            let dimmed = !marked.isEmpty && marked.allSatisfy { $0.isDisabled && $0.title.contains("已停用") }
            let sameAsMenu = rows.count == menu.count && rows.allSatisfy { menu[$0.id] == $0.isDisabled }
            check(dimmed && sameAsMenu,
                  "A7 a disabled engine's rows are dimmed and marked 已停用 on the page's card, row by row the same as the assistant's own menu",
                  "marked=\(marked.map { "\($0.title)/\($0.isDisabled)" })")
            difference = assistantCardDifference(model: model, store: store)
            check(difference == nil, "A2 [engine disabled] the page's card equals the DM assistant's card", difference ?? "")
            model.disabledEngines = []
        } else {
            check(false, "A7 fixture: a second engine to disable")
        }

        // 接主設備（副設備的樣子）：這一台送出只帶模型——速度、推理強度、ultrawork 照那台的設定（變淡、寫原因）；回覆中模型列停用。
        let primary = ModePrimaryDouble()
        model.assistantPrimaryTestDouble = (device: AssistantPrimaryDevice(id: "w184-mode-page-primary", displayName: "Primary One"),
                                            engine: { primary }, connecting: { false })
        model.setAssistantModel(speedRoute.id)
        let remote = TatwoComposerMode.assistantSpace(model: model)
        let remoteNote = remote.effort?.note ?? remote.speed?.note ?? ""
        let tuningDimmed = model.assistantPlacement.isPrimary && remote.speed?.isEnabled == false && remote.speed?.selectedID == nil
            && remoteNote.contains("主設備「Primary One」") && remote.collaboration?.isEnabled == false
        let modelAndMemory = remote.models.first?.isEnabled == true && remote.segments.first?.text == model.assistantModelChipTitle
            && remote.memory?.note?.contains("主設備「Primary One」") == true
            && remote.modelNote?.contains("主設備「Primary One」") == true
        check(tuningDimmed && modelAndMemory,
              "A6 assistant on the primary: 速度 and 推理強度 are listed but dimmed — the primary decides — and the card says so; the model row still works; 記憶 says it rides with the next sentence",
              "note=\(remoteNote) speed=\(String(describing: remote.speed?.isEnabled)) modelNote=\(remote.modelNote ?? "nil")")
        difference = assistantCardDifference(model: model, store: store)
        check(difference == nil, "A2 [on the primary] the page's card equals the DM assistant's card", difference ?? "")
        primary.running = true
        let busy = TatwoComposerMode.assistantSpace(model: model)
        let rowOff = busy.models.first?.isEnabled == false && busy.segments.first?.dimmed == true
        check(model.assistantIsRunning && rowOff && busy.modelNote == "回覆中不換模型" && busy.help == "回覆中不換模型",
              "A6 while it answers: the model row is off (no list opens), the chip's model part is dim, the card and the hover text say 回覆中不換模型",
              "enabled=\(String(describing: busy.models.first?.isEnabled)) note=\(busy.modelNote ?? "nil")")
        difference = assistantCardDifference(model: model, store: store)
        check(difference == nil, "A2 [while it answers] the page's card equals the DM assistant's card", difference ?? "")
        primary.running = false
        model.assistantPrimaryTestDouble = nil
        store.select(.assistant)
    }

    // MARK: - S Space 搭建

    @MainActor static func spaceChecks(_ check: Checker) {
        guard let speedRoute = ChatRouteChoice.all.first(where: { $0.supportsNativeSpeedControl }),
              let plainRoute = ChatRouteChoice.all.first(where: { !$0.supportsNativeSpeedControl && $0.supportsNativeReasoningControl }) else {
            check(false, "S0 fixture routes")
            return
        }
        let domain = SpaceSetupPreviewState.Domain(id: "w184-mode-space", name: "測試工作室", bots: [])
        var mode = TatwoComposerMode.spaceSetup(domain: domain)
        check(mode.badge?.text == "UI 預覽" && mode.collaboration?.isEnabled == true && mode.memory == nil
              && mode.segments.map(\.identifier) == ["space-composer-model", "space-composer-ultrawork"],
              "S1 Space preview: UI 預覽 badge, collaboration selectable, no memory")
        mode.collaboration?.setLevel(.xl)
        mode.models[0].choose(plainRoute.id)
        mode = TatwoComposerMode.spaceSetup(domain: domain)
        check(domain.composerCollaboration == .xl && domain.composerRoute.id == plainRoute.id && mode.speed == nil
              && mode.title == "XL 協作編制",
              "S2 preview picks write the same fields as the old menus (composerCollaboration, selectComposerRoute); no speed for \(plainRoute.title)")
        mode.models[0].choose(speedRoute.id)
        mode = TatwoComposerMode.spaceSetup(domain: domain)
        mode.speed?.choose(TatwoModelSpeedTier.standard.rawValue)
        mode.effort?.choose(TatwoCodexReasoningEffort.medium.rawValue)
        check(domain.composerRoute.id == speedRoute.id && domain.composerSpeed == .standard && domain.composerEffort == .medium,
              "S3 preview speed and effort write composerSpeed / composerEffort")
        domain.isProduction = true
        domain.bots = [SpaceSetupPreviewState.Bot(id: "w184-mode-bot", name: "搭建 Bot")]
        domain.chosenBotID = "w184-mode-bot"
        let production = TatwoComposerMode.spaceSetup(domain: domain)
        // 守（審查 #1、#2）：正式搭建的送出不帶協作：拉條照「關」畫、變淡、寫一句原因（預覽選的 XL 不會亮著卻不送）。
        check(production.collaboration?.isEnabled == false && production.collaboration?.level == .off
              && production.collaboration?.note == "搭建需求不帶 ultrawork" && production.segments.last?.text == "ultrawork"
              && production.models[0].isEnabled == false
              && production.speed == nil && production.effort == nil && production.segments.first?.text == "Bot 設定",
              "S4 real build: collaboration can't be chosen and is drawn off with the reason, the model follows the chosen Bot, no speed/effort")
        // S5（審查 #9）：正式搭建在這台跑：這台送不出的那家在模型清單變淡、標「已停用」；預覽不連模型，不標。
        domain.chosenBotID = ""
        let blockedKind: ClaudeSidecar.Kind = .grok
        let build = TatwoComposerMode.spaceSetup(domain: domain, blocked: [blockedKind])
        domain.isProduction = false
        let preview = TatwoComposerMode.spaceSetup(domain: domain, blocked: [blockedKind])
        let marked = build.models[0].options.filter { AssistantModelRouting.engineKind(for: ChatRouteChoice.resolve($0.id)) == blockedKind }
        check(!marked.isEmpty && marked.allSatisfy(\.isDisabled) && build.models[0].isEnabled
              && build.models[0].options.filter { !marked.map(\.id).contains($0.id) }.allSatisfy { !$0.isDisabled }
              && preview.models[0].options.allSatisfy { !$0.isDisabled },
              "S5 (審查 #9) real build runs here: the engine this Mac cannot send is dimmed in the model list; the UI preview marks nothing",
              "marked=\(marked.map(\.title))")
    }

    // MARK: - B Bot Studio

    @MainActor static func botStudioChecks(_ check: Checker) {
        let mode = TatwoComposerMode.botStudio(modelLabel: "Claude Opus 5", modelTier: "fast", scopeLabel: "自己做")
        check(mode.memory == nil && mode.collaboration == nil && mode.models.count == 2
              && mode.models.allSatisfy { !$0.isEnabled && $0.options.isEmpty } && mode.badge?.text == "展示"
              && mode.segments.map(\.identifier) == ["bot-composer-model", "bot-composer-scope"],
              "B1 Bot Studio (demo): model and 派工方式 are shown, nothing can change, no memory")
        check(mode.speed == nil && mode.effort == nil && mode.models[1].identifier == "tatwo.composer.mode.scope"
              && mode.models[1].title == "自己做",
              "B2 (查核 #7) 派工方式 is a disabled row like 模型, not a one-stop track filled edge to edge (a square button)")
    }

    // MARK: - R 畫面：卡浮在哪裡、每個輸入框卡片開與關、識別碼、PNG、視窗矮時

    /// 回 false＝這個環境畫不出來（後面的真滑鼠點也不跑）。
    @MainActor static func renderChecks(_ check: Checker, model: ChatPageModel, store: GlobalDMStore, engine: ChatLiveEngine,
                                        thread: UUID, mode coderMode: (Bool) -> TatwoComposerMode, artifacts: URL?) -> Bool {
        let render = GlobalDMChatAcceptance.self
        guard let probeShot = render.renderSync(Text("測試 Test").font(.system(size: 17)).foregroundStyle(Color.black),
                                                size: CGSize(width: 200, height: 60)) else {
            check.skip("R rendering: this environment cannot draw offscreen")
            return false
        }
        let canDraw = render.ink(probeShot) != nil
        probeShot.close()
        guard canDraw else {
            check.skip("R rendering: no window server to draw text offscreen (rules above still ran)")
            return false
        }

        // R0 卡浮在哪裡：探針卡（純紅 120×80）掛在 300×100 的輸入框上，要在輸入框上緣上方 8、右緣對齊（私訊框、Bot Studio、Space 搭建同一個 modifier）。
        let anchorProbe = VStack(spacing: 0) {
            Spacer(minLength: 0)
            Color.white.frame(width: 300, height: 100)
                .tatwoComposerModeCard(isPresented: .constant(true), anchor: AssistantModelMenuAnchor()) {
                    Color(red: 1, green: 0, blue: 0).frame(width: 120, height: 80)
                }
        }
        if let shot = render.renderSync(anchorProbe, size: CGSize(width: 400, height: 400)) {
            let red = redBounds(shot)
            let expected = CGRect(x: 230, y: 212, width: 120, height: 80)
            check(red.map { abs($0.minX - expected.minX) <= 1.5 && abs($0.maxX - expected.maxX) <= 1.5
                            && abs($0.minY - expected.minY) <= 1.5 && abs($0.maxY - expected.maxY) <= 1.5 } ?? false,
                  "R0 the card floats above the composer: its bottom 8 above the composer's top, right edges aligned (drawn and measured)",
                  "red=\(red.map { "\($0)" } ?? "none") expected=\(expected)")
            render.save(shot, "popover-probe.png", to: artifacts)
            shot.close()
        }

        let opus = ChatRouteChoice.all.first { $0.canonicalModelSlug == "opus-5.5" }
        if let opus { model.setPrimaryModel(opus.canonicalModelSlug) }

        // 無障礙樹在這個環境畫在螢幕外時可能是空的（同 w184chat 的 SKIP）：識別碼那幾條記成 SKIP，不當成通過；
        // 開關、位置、拉條另有量像素與真的滑鼠點的檢查（R7、T4），那些畫不出來或點不到一律記 FAIL。
        var axWorks: Bool?
        func identifierCheck(_ shot: GlobalDMChatAcceptance.Rendered, _ label: String, _ condition: (Set<String>) -> Bool) {
            let ids = render.identifiers(in: shot)
            if axWorks == nil { axWorks = !ids.isEmpty }
            guard axWorks == true else {
                check.skip(label + " — identifiers: accessibility tree is empty offscreen here (source contract in tests/w184-mode.test.mjs)")
                return
            }
            check(condition(ids), label, "found \(ids.sorted().prefix(40))")
        }
        /// 同一個輸入框畫關、開兩張（PNG 兩張都存）：開的那張在輸入框上緣以上多出一張卡；
        /// 查核 #13：卡的下緣用畫出來的算——卡左邊 1/4 那幾欄、整個高度找開關兩張不一樣的最底列（不含 chip 自己變色的那一塊），
        /// 要在上緣上方至少 8（以前只掃上緣以上那一段，卡掉進輸入框也照樣過）。
        func openClose<V: View>(_ name: String, size: CGSize, _ label: String, reference: String, probe: FrameProbe,
                                edge: (FrameProbe) -> CGFloat?, closedIDs: Set<String>, openIDs: Set<String>,
                                lacks: Set<String> = [], _ make: (Bool) -> V) {
            guard let closed = render.renderSync(make(false), size: size) else {
                check(false, label + ": draw the closed composer")
                return
            }
            defer { closed.close() }
            render.save(closed, "\(name)-closed.png", to: artifacts)
            // 先驗關卡；同一個 store 的第二張 composer 開卡後，第一張會同步開卡，不能再拿它當關卡的 AX 樹。
            identifierCheck(closed, label + " closed: the chip parts keep their identifiers") {
                closedIDs.isSubset(of: $0) && !$0.contains(TatwoComposerMode.cardIdentifier) && lacks.isDisjoint(with: $0)
            }
            let top = edge(probe)
            guard let opened = render.renderSync(make(true), size: size) else {
                check(false, label + ": draw the open composer")
                return
            }
            defer { opened.close() }
            render.save(opened, "\(name)-open.png", to: artifacts)
            guard let top else {
                check(false, label + ": measure where \(reference) is")
                return
            }
            let above = diffBounds(closed, opened, above: top)
            let card = views(TatwoComposerModeClickAwayView.self, in: opened.host).first.map { imageRect($0, in: opened) } ?? probe.card
            let chips = views(TatwoComposerModeChipAnchorView.self, in: opened.host).map { imageRect($0, in: opened).insetBy(dx: -4, dy: -4) }
            let drawn = card.flatMap { rect in
                diffRows(closed, opened, columns: (rect.minX + 6)...(rect.minX + max(12, rect.width / 4)), excluding: chips)
            }
            check(above.map { $0.width >= 200 && $0.height >= 100 } ?? false,
                  label + ": closed shows no card; open adds the card above \(reference)",
                  "difference above y=\(Int(top)): \(above.map { "\($0)" } ?? "none")")
            check(drawn.map { $0.maxY <= top - 8 + 1.5 } ?? false,
                  label + ": the card's drawn bottom edge is at least 8 above \(reference)",
                  "card=\(card.map { "\($0)" } ?? "none") drawnBottom=\(drawn.map { "\($0.maxY)" } ?? "none") \(reference) top=\(top)")
            if let drawn { check.note("\(label): the card's drawn bottom edge is \(Int((top - drawn.maxY).rounded()))pt above \(reference)") }
            identifierCheck(opened, label + " open: the card and its sections") {
                openIDs.union([TatwoComposerMode.cardIdentifier]).isSubset(of: $0) && lacks.isDisjoint(with: $0)
            }
        }

        // 第四輪（主導：主題迴圈沒還原害到之後的自測）：迴圈開始前記下原本的主題（與共用存檔）；結束（含中途 continue、失敗、return）
        // 就還原，存檔那一格全程不變——別的程序（例如同時開的 w184chat）讀不到切到一半的主題。
        let themeScope = TatwoThemeSelfTestScope()
        defer { themeScope.restore() }
        for theme in [TatwoThemeID.fable5, .aurora] {
            themeScope.use(theme)
            let suffix = theme.rawValue

            // 參考卡同狀態：S＋主導 Opus 5.5（29 那張）、L（31 那張的拉條）。T4（查核 #14）：真的畫出來的 S～XXL 那一排量像素。
            let variants: [(ChatCollaborationLevel, Int, CGFloat)] = [(.s, 0, 560), (.l, 2, 680)]
            for (level, index, height) in variants {
                model.setCollaborationLevel(level)
                guard let shot = render.renderSync(TatwoComposerModeCard(mode: coderMode(false), metrics: .main, fitsAbove: false).padding(16),
                                                   size: CGSize(width: 340, height: height)) else {
                    check(false, "T4 [\(suffix)] draw the card at \(level.title)")
                    continue
                }
                render.save(shot, "card-\(level.title)-\(suffix).png", to: artifacts)
                if let cells = trackCells(shot) {
                    let filled = Array(cells[...index]), unfilled = Array(cells[(index + 1)...])
                    check(unfilled.allSatisfy { $0 >= 8 } && (filled.min() ?? 0) >= 1.6 * (unfilled.max() ?? 1),
                          "T4 [\(suffix)] (查核 #14) the drawn S～XXL at \(level.title): every stop past \(level.title) still shows the glass base bar, the gradient fill runs from the left edge to \(level.title) (not one square)",
                          "difference from the card per stop=\(cells.map { Int($0) })")
                } else {
                    check(false, "T4 [\(suffix)] (查核 #14) find the drawn S～XXL track on the card at \(level.title)")
                }
                if level == .s {
                    identifierCheck(shot, "R1 [\(suffix)] the card at S: S/M/L/XL/XXL stops, 主導 row, 速度, 推理強度, 記憶, power") {
                        Set([TatwoComposerMode.cardIdentifier, "tatwo.composer.mode.ultrawork", "ultrawork-mode-s", "ultrawork-mode-m",
                             "ultrawork-mode-l", "ultrawork-mode-xl", "ultrawork-mode-xxl", "ultrawork-role-primary",
                             "tatwo.composer.mode.speed", "tatwo.composer.mode.effort", "tatwo.composer.mode.memory",
                             "tatwo.composer.mode.off"]).isSubset(of: $0)
                    }
                }
                shot.close()
            }
            model.setCollaborationLevel(.off)

            // 主視窗 Coder：輸入框＋模式卡照 ChatPage+Composer 的掛法（CoderOverlayFrame；整頁 ChatPage 不在自測裡畫，見那個型別的說明）。
            // W184 H4 修正（審查 #7）：卡掛在整個輸入框（玻璃卡）上——量的是輸入框真的上緣（不再是離整頁底 104 的固定點）。
            let mainProbe = FrameProbe()
            let mainSize = CGSize(width: 760, height: 700)
            openClose("main-\(suffix)", size: mainSize, "R2 [\(suffix)] main window Coder",
                      reference: "the composer's top edge (the whole input box, as ChatPage+Composer)",
                      probe: mainProbe, edge: { $0.composer?.minY },
                      closedIDs: [TatwoComposerMode.identifier, "chat-composer-model", "tatwo-memory-strength", "chat-composer-ultrawork"],
                      openIDs: ["tatwo.composer.mode.ultrawork", "ultrawork-mode-s", "tatwo.composer.mode.memory"]) { open in
                CoderOverlayFrame(mode: coderMode(false), open: open, probe: mainProbe)
            }
            // R2b（審查 #7 反例）：輸入框多行＋附件（長高了）：卡照樣在它真的上緣上方 8，不蓋到打字區（以前固定離底 104 會重疊）。
            let tallProbe = FrameProbe()
            openClose("main-multiline-attachments-\(suffix)", size: mainSize,
                      "R2b [\(suffix)] (審查 #7) main window Coder with 4 lines and 2 attachments",
                      reference: "the taller composer's top edge", probe: tallProbe, edge: { $0.composer?.minY },
                      closedIDs: [TatwoComposerMode.identifier], openIDs: ["tatwo.composer.mode.ultrawork"]) { open in
                CoderOverlayFrame(mode: coderMode(false), open: open, probe: tallProbe, lines: 4, attachments: ["設計稿.png", "規格.md"])
            }
            if let composer = tallProbe.composer, let card = tallProbe.card {
                check(card.maxY <= composer.minY - 8 + 1.5 && composer.height > 150,
                      "R2b [\(suffix)] (審查 #7) the grown composer (\(Int(composer.height))pt) keeps the card fully above it",
                      "card=\(card) composer=\(composer)")
            } else {
                check(false, "R2b [\(suffix)] (審查 #7) measure the grown composer and the card")
            }

            // 私訊框外直：真的 GlobalDMComposer；先畫有兩則訊息的（PNG），再畫空的（量開關差異）。
            store.select(.assistant)
            let bubbles = GlobalDMBubble.rows([
                ChatMessage(id: "u1", role: .user, text: "幫我把模型換成快一點的"),
                ChatMessage(id: "a1", role: .assistant, text: "好，點輸入框右下的「模式選擇」就能換模型、速度、推理強度和記憶。"),
            ])
            for open in [false, true] {
                let pane = GlobalDMChatAcceptanceFrame {
                    VStack(spacing: 0) {
                        GlobalDMMessageList(bubbles: bubbles, emptyText: "")
                        GlobalDMComposer(store: store, placeholder: "問助理任何事…", isRunning: false, canSend: true,
                                         initiallyFocused: false, modeCardOpen: open)
                    }
                }
                if let shot = render.renderSync(pane, size: GlobalDMLayout.box) {
                    render.save(shot, "dm-chat-\(open ? "open" : "closed")-\(suffix).png", to: artifacts)
                    if !open, axWorks != false, press("tatwo.dm.model", in: shot) {
                        settle(shot)
                        identifierCheck(shot, "R4 [\(suffix)] DM: pressing the chip opens the card") {
                            $0.contains(TatwoComposerMode.cardIdentifier)
                        }
                        if let again = recapture(shot) { render.save(again, "dm-pressed-\(suffix).png", to: artifacts) }
                        if press("tatwo.dm.model", in: shot) {
                            settle(shot)
                            identifierCheck(shot, "R4 [\(suffix)] DM: pressing the chip again closes the card") {
                                !$0.contains(TatwoComposerMode.cardIdentifier)
                            }
                        }
                    } else if !open {
                        check.skip("R4 [\(suffix)] DM: accessibility press is not available offscreen (R7 clicks it with the mouse instead)")
                    }
                    shot.close()
                }
            }
            let dmProbe = FrameProbe()
            openClose("dm-\(suffix)", size: GlobalDMLayout.box, "R3 [\(suffix)] DM (phone size; 模型, 速度, 推理強度, 記憶, S～XXL off for the assistant)",
                      reference: "the composer", probe: dmProbe, edge: { $0.composer?.minY },
                      closedIDs: [TatwoComposerMode.identifier, "tatwo.dm.model", "tatwo-memory-strength", "tatwo.dm.input",
                                  "tatwo.dm.send", "tatwo.dm.attach"],
                      openIDs: ["tatwo.composer.mode.model", "tatwo.composer.mode.memory", "tatwo.composer.mode.ultrawork"]) { open in
                GlobalDMChatAcceptanceFrame {
                    VStack(spacing: 0) {
                        GlobalDMMessageList(bubbles: [], emptyText: "")
                        GlobalDMComposer(store: store, placeholder: "問助理任何事…", isRunning: false, canSend: true,
                                         initiallyFocused: false, modeCardOpen: open)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dmProbe.composer = $0 }
                    }
                }
            }

            // Bot Studio（展示）。
            let botProbe = FrameProbe()
            openClose("bot-studio-\(suffix)", size: CGSize(width: 760, height: 520), "R5 [\(suffix)] Bot Studio (demo; no memory)",
                      reference: "the composer", probe: botProbe, edge: { $0.composer?.minY },
                      closedIDs: [TatwoComposerMode.identifier, "bot-composer-model", "bot-composer-scope"],
                      openIDs: ["tatwo.composer.mode.model", "tatwo.composer.mode.scope"],
                      lacks: ["tatwo-memory-strength", "tatwo.composer.mode.memory"]) { open in
                VStack {
                    Spacer()
                    BotStudioComposer(text: .constant(""), placeholder: "跟「研究員」講話…", modelLabel: "Claude Opus 5",
                                      scopeLabel: "自己做", modeCardOpen: open, onSubmit: {})
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { botProbe.composer = $0 }
                }
                .padding(24)
            }


            // Space 搭建（預覽）：W184 H4b：卡掛在整個輸入框（SpaceSetupPreviewView 的玻璃卡）上方 8、右緣對齊，不再蓋住打字區
            // （原本掛在工具列上：卡的下緣在工具列上方 8＝在輸入框裡面 59pt）；以輸入框的上緣為準，不是工具列。
            let domain = SpaceSetupPreviewState.Domain(id: "w184-mode-render", name: "測試工作室", bots: [])
            let spaceProbe = FrameProbe()
            openClose("space-\(suffix)", size: CGSize(width: 760, height: 620), "R6 [\(suffix)] Space setup preview (card hangs on the whole composer)",
                      reference: "the composer's top edge (the whole input box, not the toolbar)", probe: spaceProbe, edge: { $0.composer?.minY },
                      closedIDs: [TatwoComposerMode.identifier, "space-composer-model", "space-composer-ultrawork"],
                      openIDs: ["ultrawork-mode-s", "tatwo.composer.mode.speed"], lacks: ["tatwo.composer.mode.memory"]) { open in
                SpaceComposerFrame(domain: domain, open: open, probe: spaceProbe)
            }
            if let composerTop = spaceProbe.composer?.minY, let toolbarTop = spaceProbe.toolbar?.minY {
                check.note("R6 [\(suffix)] Space: the toolbar's top is \(Int(toolbarTop - composerTop))pt inside the composer; the card no longer hangs there (before H4b it sat 8 above the toolbar = \(Int(toolbarTop - 8 - composerTop))pt inside the text area)")
            }

            // TATWO 助理頁（W184 H4b，畫真的 AssistantSpacePane、視窗模式）：卡掛在整個輸入框上方 8；輸入框的位置由頁面自己回報（globalDMComposerFrame）。
            // 助理放在有速度檔的 Codex 模型上，卡上四樣都在（S～XXL 變淡、寫原因）。
            if let codex = ChatRouteChoice.all.first(where: { $0.supportsNativeSpeedControl && $0.allowedSpeedTiers.count > 1
                                                             && AssistantModelRouting.engineKind(for: $0) == .codex }) {
                model.setAssistantModel(codex.id)
            }
            openClose("assistant-\(suffix)", size: CGSize(width: 760, height: 720),
                      "R10 [\(suffix)] TATWO assistant page (real AssistantSpacePane, window mode; 模型, 速度, 推理強度, 記憶, S～XXL off)",
                      reference: "the composer's top edge", probe: FrameProbe(),
                      edge: { _ in GlobalDMComposerFrames.shared.frames[.tatwo]?.minY },
                      closedIDs: [TatwoComposerMode.identifier, "tatwo-assistant-model", "tatwo-memory-strength", "tatwo-assistant-input",
                                  "tatwo-assistant-send"],
                      openIDs: ["tatwo.composer.mode.model", "tatwo.composer.mode.speed", "tatwo.composer.mode.effort",
                                "tatwo.composer.mode.memory", "tatwo.composer.mode.ultrawork"]) { open in
                AssistantPaneFrame(model: model, open: open)
            }

            // R8（查核 #3、#11）：主視窗最矮 600、ultrawork XXL、模型有速度與推理強度：卡的上緣在頂列下面、S～XXL 整排在畫面裡，中間那一段捲。
            if let gpt = ChatRouteChoice.all.first(where: { $0.supportsNativeSpeedControl && $0.supportsNativeReasoningControl }) {
                TatwoComposerMode.applyCoderRoute(gpt, to: model)
                model.setCollaborationLevel(.xxl)
                let tall = coderMode(false)
                let natural = NSHostingView(rootView: TatwoComposerModeCard(mode: tall, metrics: .main, fitsAbove: false)).fittingSize.height
                let fitProbe = FrameProbe()
                let size = CGSize(width: 760, height: TatwoAppSurfaceMetrics.windowMinSize.height)
                if let shot = render.renderSync(CoderOverlayFrame(mode: tall, open: true, probe: fitProbe), size: size) {
                    render.save(shot, "main-600-xxl-\(suffix).png", to: artifacts)
                    let track = views(ChatSliderPointerCaptureView.self, in: shot.host).map { imageRect($0, in: shot) }
                        .filter { $0.width > 100 }.min { $0.minY < $1.minY }
                    let scrolls = !views(NSScrollView.self, in: shot.host).isEmpty
                    let clearance = TatwoComposerModeMetrics.main.topClearance
                    let composerTop = fitProbe.composer?.minY ?? size.height
                    check(natural > composerTop - 8 - clearance
                          && (fitProbe.card.map { $0.minY >= clearance - 1 && $0.maxY <= composerTop - 8 + 1.5 && $0.height < natural - 20 } ?? false)
                          && (track.map { $0.minY >= clearance && $0.maxY <= (fitProbe.card?.maxY ?? 0) } ?? false),
                          "R8 [\(suffix)] (查核 #3、#11) main window at its minimum height 600, XXL: the card (\(Int(natural))pt tall on its own) is cut down to stay below the top band, S～XXL is on screen, the middle scrolls",
                          "natural=\(natural) card=\(fitProbe.card.map { "\($0)" } ?? "none") track=\(track.map { "\($0)" } ?? "none")")
                    check.note("R8 [\(suffix)] scroll view in the card: \(scrolls)")
                    shot.close()
                } else {
                    check(false, "R8 [\(suffix)] draw the main window at 600 high")
                }
                model.setCollaborationLevel(.off)
            } else {
                check(false, "R8 fixture: a route with speed and reasoning")
            }

            // R9（查核 #3）：私訊框外直、Coder session（本機、Codex 系、ultrawork L）：手機尺寸的卡很高——S～XXL 照樣在框裡、中間那一段捲。
            store.select(.thread(thread))
            model.setCollaborationLevel(.l)
            let dmFit = FrameProbe()
            let dmPane = GlobalDMChatAcceptanceFrame {
                VStack(spacing: 0) {
                    GlobalDMMessageList(bubbles: [], emptyText: "")
                    GlobalDMComposer(store: store, placeholder: "傳給這條 session…", isRunning: false, canSend: true,
                                     initiallyFocused: false, modeCardOpen: true)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dmFit.composer = $0 }
                }
            }
            if let shot = render.renderSync(dmPane, size: GlobalDMLayout.box) {
                render.save(shot, "dm-session-l-\(suffix).png", to: artifacts)
                let card = views(TatwoComposerModeClickAwayView.self, in: shot.host).first.map { imageRect($0, in: shot) }
                let track = views(ChatSliderPointerCaptureView.self, in: shot.host).map { imageRect($0, in: shot) }
                    .filter { $0.width > 100 }.min { $0.minY < $1.minY }
                let clearance = TatwoComposerModeMetrics.dmPhone.topClearance
                check((card.map { $0.minY >= DMPhone.headerHeight - 1 && $0.minY >= clearance - GlobalDMLayout.margin - 1 } ?? false)
                      && (track.map { $0.minY >= (card?.minY ?? .infinity) && $0.maxY <= (dmFit.composer?.minY ?? 0) } ?? false),
                      "R9 [\(suffix)] (查核 #3) DM session at L on a Codex model: the phone-size card stays inside the box under the top bar and S～XXL is on screen",
                      "card=\(card.map { "\($0)" } ?? "none") track=\(track.map { "\($0)" } ?? "none") composer=\(dmFit.composer.map { "\($0)" } ?? "none")")
                shot.close()
            } else {
                check(false, "R9 [\(suffix)] draw the DM session card")
            }
            model.setCollaborationLevel(.off)
            store.select(.assistant)
        }
        model.setCollaborationLevel(.off)
        return true
    }

    // MARK: - R7 真的滑鼠點（查核 #12）

    /// 每個套用的輸入框：畫卡片關著的真輸入框，對 chip 送真的滑鼠（按下、放開；排進 App 的事件佇列＝先過本機事件監看、再派給視窗做
    /// hit test，跟使用者點的同一條路）：點模型那一段＝開、點 ⌄＝關、再開、點卡以外的地方＝收。開不開看卡在不在（彈出的卡墊著
    /// 點外面收起的那一層；主視窗看浮層裡那張卡的記號）。點不到、開不了都記 FAIL。
    @MainActor static func clickChecks(_ check: Checker, model: ChatPageModel, store: GlobalDMStore, engine: ChatLiveEngine,
                                       mode coderMode: (Bool) -> TatwoComposerMode, artifacts: URL?) async {
        store.select(.assistant)
        let dm = ClickRig(GlobalDMChatAcceptanceFrame {
            VStack(spacing: 0) {
                GlobalDMMessageList(bubbles: [], emptyText: "")
                GlobalDMComposer(store: store, placeholder: "問助理任何事…", isRunning: false, canSend: true,
                                 initiallyFocused: false, modeCardOpen: false)
            }
        }, size: GlobalDMLayout.box)
        await clickCycle(check, "DM", rig: dm, artifacts: artifacts) { dm.has(TatwoComposerModeClickAwayView.self) }
        dm.close()

        let bot = ClickRig(VStack {
            Spacer()
            BotStudioComposer(text: .constant(""), placeholder: "跟「研究員」講話…", modelLabel: "Claude Opus 5",
                              scopeLabel: "自己做", onSubmit: {})
        }
        .padding(24), size: CGSize(width: 760, height: 520))
        await clickCycle(check, "Bot Studio", rig: bot, artifacts: artifacts) { bot.has(TatwoComposerModeClickAwayView.self) }
        bot.close()

        let domain = SpaceSetupPreviewState.Domain(id: "w184-mode-click", name: "測試工作室", bots: [])
        let space = ClickRig(SpaceComposerFrame(domain: domain, open: false, probe: FrameProbe()), size: CGSize(width: 760, height: 620))
        await clickCycle(check, "Space setup", rig: space, artifacts: artifacts) { space.has(TatwoComposerModeClickAwayView.self) }
        space.close()

        // W184 H4b：TATWO 助理頁（真的 AssistantSpacePane）與 Space 搭建（卡掛在整個輸入框上）：卡開著時真的點在卡上。
        await assistantClickChecks(check, model: model, engine: engine, artifacts: artifacts)
        await spaceClickChecks(check, artifacts: artifacts)

        let main = ClickRig(CoderOverlayFrame(mode: coderMode(false), open: false, probe: FrameProbe()), size: CGSize(width: 760, height: 700))
        await clickCycle(check, "main window Coder", rig: main, artifacts: artifacts) { main.has(CardMarkerView.self) }
        main.close()

        // R13（審查 #7）：卡開著時真的點送出：卡收起、送出照常——點卡外收卡是本機事件監看，不吞那一下（以前整頁的透明底吃掉這一下，
        // 只收卡、沒送出）。卡的下緣在輸入框真的上緣上方 8。
        final class Sends { var count = 0 }
        let sends = Sends()
        let probe = FrameProbe()
        let rig = ClickRig(CoderOverlayFrame(mode: coderMode(false), open: false, probe: probe, onSend: { sends.count += 1 }),
                           size: CGSize(width: 760, height: 700))
        defer { rig.close() }
        await rig.settle(8)
        guard let chip = rig.chipFrame(),
              let send = views(SendMarkerView.self, in: rig.host).first.map({ $0.convert($0.bounds, to: nil) }) else {
            check(false, "R13 (審查 #7) the main window Coder's chip and send button are on screen to click")
            return
        }
        await rig.click(NSPoint(x: chip.minX + min(20, chip.width * 0.2), y: chip.midY))
        let opened = await rig.wait { rig.has(CardMarkerView.self) }
        if let card = rig.cardFrame(), let composer = probe.composer {
            let composerTop = rig.size.height - composer.minY
            check(abs(card.minY - (composerTop + 8)) <= 1.5 && abs(card.maxX - composer.maxX) <= 1.5,
                  "R13 (審查 #7) main window Coder: the real card's bottom edge sits 8 above the composer's real top edge, right edges aligned",
                  "card=\(card) composer=\(composer)")
        } else {
            check(false, "R13 (審查 #7) open the Coder card by a real click and measure it")
        }
        await rig.click(NSPoint(x: send.midX, y: send.midY))
        let closed = await rig.wait { !rig.has(CardMarkerView.self) }
        check(opened && closed && sends.count == 1,
              "R13 (審查 #7) with the card open, a real click on 送出 closes the card and still sends (the click is not swallowed)",
              "opened=\(opened) closed=\(closed) sends=\(sends.count)")
    }

    // MARK: - E 私訊框的 Esc（W184 AB，H4 查核 #9）

    /// 模式卡開著按 Esc 會把整個私訊框收掉（routeEscape 看不到卡）：store 記著卡開著沒有（跟輸入框的 modeOpen 兩邊同步），
    /// Esc 先收卡、框照舊開著；再按一次才照原本的順序（收框）。真的浮動框（面板控制器）、真的點 chip、真的 Esc 事件
    /// （NSApp.postEvent：走 App 的事件佇列 → 面板控制器的本機監看 → routeEscape）。換對象、開 session 清單也收卡。
    @MainActor static func escapeChecks(_ check: Checker, store: GlobalDMStore) async {
        // E0：store 那一層——換對象、開 session 清單、收框都收卡。
        store.select(.assistant)
        store.isModeCardOpen = true
        store.select(.assistant)
        let clearedBySelect = !store.isModeCardOpen
        store.isModeCardOpen = true
        store.isPickerOpen = true
        let clearedByPicker = !store.isModeCardOpen
        store.isPickerOpen = false
        check(clearedBySelect && clearedByPicker,
              "E0 (W184 AB, H4 review #9) the store knows the mode card is open, and picking a target or opening the session list closes it",
              "select=\(clearedBySelect) picker=\(clearedByPicker)")

        let suite = "ai.tatwo.selftest.w184mode.esc.\(UUID().uuidString)"
        guard let deskDefaults = UserDefaults(suiteName: suite) else { return check(false, "E1 fixture: desk defaults") }
        defer { deskDefaults.removePersistentDomain(forName: suite) }
        let settings = GlobalDMDeskSettings(defaults: deskDefaults)
        settings.form = .outerPortrait
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true)
        store.isEnabled = true
        panels.install()
        defer {
            store.close()
            panels.uninstall()
        }
        store.openFloating()
        func wait(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<60 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            return condition()
        }
        _ = await wait { panels.floatingPanelForTesting?.isVisible == true }
        guard let panel = panels.floatingPanelForTesting, panel.isVisible, let root = panel.contentView else {
            return check.skip("E1 私訊框 Esc：這個環境開不出浮動框（沒有畫面環境）")
        }
        panel.alphaValue = 0   // 自測不在螢幕上閃；事件照視窗編號送
        func cardShown() -> Bool { !views(TatwoComposerModeClickAwayView.self, in: root).isEmpty }
        _ = await wait { TatwoComposerModeChipAnchorView.frames(in: panel).contains { $0.width > 20 && $0.height > 10 } }
        guard let chip = TatwoComposerModeChipAnchorView.frames(in: panel).first(where: { $0.width > 20 && $0.height > 10 }) else {
            return check(false, "E1 fixture: the mode chip on the floating DM box")
        }
        func post(_ event: NSEvent?) { if let event { NSApp.postEvent(event, atStart: false) } }
        func click(_ point: NSPoint) {
            let now = ProcessInfo.processInfo.systemUptime
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                post(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now + Double(index) * 0.05,
                                        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseDown ? 1 : 0))
            }
        }
        func escape() {
            post(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                  isARepeat: false, keyCode: 53))
        }
        let startsClosed = !cardShown() && !store.isModeCardOpen
        click(NSPoint(x: chip.minX + min(20, chip.width * 0.2), y: chip.midY))   // 點 chip 的模型那一段＝打開卡
        let opened = await wait { cardShown() && store.isModeCardOpen }
        escape()
        let cardClosed = await wait { !cardShown() && !store.isModeCardOpen }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let boxKept = store.isFloatingOpen && panel.isVisible
        escape()
        let boxClosed = await wait { !store.isFloatingOpen }
        check(startsClosed && opened && cardClosed && boxKept && boxClosed,
              "E1 (W184 AB, H4 review #9) a real Esc on the floating DM box with the mode card open (opened by a real click on the chip) closes only the card — the box stays open; the next Esc takes the usual order and closes the box",
              "startsClosed=\(startsClosed) opened=\(opened) cardClosed=\(cardClosed) boxKept=\(boxKept) boxClosed=\(boxClosed) chip=\(chip)")
    }

    @MainActor static func clickCycle(_ check: Checker, _ name: String, rig: ClickRig, artifacts: URL?,
                                      isOpen: @escaping @MainActor () -> Bool) async {
        await rig.settle(8)
        guard let chip = rig.chipFrame() else {
            check(false, "R7 [\(name)] (查核 #12) the mode chip is on screen to click")
            return
        }
        let segment = NSPoint(x: chip.minX + min(20, chip.width * 0.2), y: chip.midY)
        let chevron = NSPoint(x: chip.maxX - 13, y: chip.midY)
        let outside = NSPoint(x: 30, y: rig.size.height - 40)
        let startsClosed = !isOpen()
        await rig.click(segment)
        let opened = await rig.wait(isOpen)
        if let shot = rig.capture() { GlobalDMChatAcceptance.save(shot, "click-\(name.replacingOccurrences(of: " ", with: "-"))-open.png", to: artifacts) }
        await rig.click(chevron)
        let closed = await rig.wait { !isOpen() }
        await rig.click(segment)
        let reopened = await rig.wait(isOpen)
        await rig.click(outside)
        let away = await rig.wait { !isOpen() }
        check(startsClosed && opened, "R7 [\(name)] (查核 #12) a real click on the chip's model part opens the card (one toggle, not open-then-closed)",
              "startsClosed=\(startsClosed) opened=\(opened) chip=\(chip)")
        check(closed, "R7 [\(name)] (查核 #12) a real click on the chip's ⌄ closes it again", "chip=\(chip)")
        check(reopened && away, "R7 [\(name)] (查核 #12) reopened, a real click outside the card closes it (click-away)",
              "reopened=\(reopened) away=\(away)")
    }

    // MARK: - R11／R12 卡開著時真的點在卡上（W184 H4b）

    /// TATWO 助理頁（真的 AssistantSpacePane）：先跟其他輸入框一樣真的點 chip 開、關、點外面收（R7）；再開著卡，真的點——
    /// 速度的另一檔、記憶的另一檔（拉條的滑鼠走本機事件監看）、模型那一列（SwiftUI 的按鈕：進卡裡的模型清單）再點清單裡的另一個模型——
    /// 助理那一條的值真的變了。卡在輸入框外面（往上長），所以這也證明浮在輸入框上方的那一張點得到（不是只有 chip 點得到）。
    @MainActor static func assistantClickChecks(_ check: Checker, model: ChatPageModel, engine: ChatLiveEngine, artifacts: URL?) async {
        guard let assistant = model.assistantThreadID,
              let codex = ChatRouteChoice.all.first(where: { $0.supportsNativeSpeedControl && $0.allowedSpeedTiers.count > 1
                                                            && AssistantModelRouting.engineKind(for: $0) == .codex }) else {
            check(false, "R11 fixture: the assistant's own thread and a Codex route with speed tiers")
            return
        }
        model.setAssistantModel(codex.id)
        let rig = ClickRig(AssistantPaneFrame(model: model, open: false), size: CGSize(width: 760, height: 720))
        defer { rig.close() }
        await clickCycle(check, "TATWO assistant page", rig: rig, artifacts: artifacts) { rig.has(TatwoComposerModeClickAwayView.self) }

        // 卡開著：位置（真的 view 的框）＋拉條。
        guard let chip = rig.chipFrame() else {
            check(false, "R11 [TATWO assistant page] the mode chip is on screen to click")
            return
        }
        await rig.click(NSPoint(x: chip.minX + min(20, chip.width * 0.2), y: chip.midY))
        guard await rig.wait({ rig.has(TatwoComposerModeClickAwayView.self) }), let card = rig.cardFrame() else {
            check(false, "R11 [TATWO assistant page] open the card by a real click before clicking on it")
            return
        }
        if let composer = GlobalDMComposerFrames.shared.frames[.tatwo] {
            let composerTop = rig.size.height - composer.minY
            check(abs(card.minY - (composerTop + 8)) <= 1.5 && abs(card.maxX - composer.maxX) <= 1.5,
                  "R11 [TATWO assistant page] the real card's bottom edge sits 8 above the composer's top edge and the right edges line up",
                  "card=\(card) composer=\(composer) windowHeight=\(rig.size.height)")
        } else {
            check(false, "R11 [TATWO assistant page] the page reports where its composer is")
        }
        let before = TatwoComposerMode.assistantSpace(model: model)
        let tracks = rig.trackFrames()
        // S～XXL 在助理頁是變淡的（不接滑鼠），所以點得到的拉條由上往下是：速度、推理強度、記憶。
        guard tracks.count == 3, let speed = before.speed, before.effort != nil, before.memory != nil else {
            check(false, "R11 [TATWO assistant page] the card shows three clickable tracks (速度, 推理強度, 記憶; S～XXL is off)",
                  "tracks=\(tracks.count) speed=\(before.speed != nil) effort=\(before.effort != nil) memory=\(before.memory != nil)")
            return
        }
        // 拉條的滑鼠：視窗搬進螢幕（全透明）走真的事件；沒有螢幕就叫它接的回呼（見 ClickRig.clickStep）。
        let realPointer = rig.moveOnScreen()
        await rig.settle(4)
        check.note("R11 [TATWO assistant page] slider clicks go through \(realPointer ? "real mouse events (window moved on screen, transparent)" : "nothing: no display big enough here, those checks are SKIP (unverified)"); screens=\(NSScreen.screens.count)")
        if let index = speed.options.firstIndex(where: { $0.id != speed.selectedID }) {
            let target = speed.options[index].id
            let pressed = await rig.pressStep(tracks[0], index: index, of: speed.options.count) {
                engine.threadRecord(assistant)?.requestedSpeedTier == target
            }
            let label = "R11 [TATWO assistant page] a real click on the other 速度 step writes the assistant thread's speed (\(target))"
            if pressed.verified {
                check(pressed.ok, label + " — \(pressed.path)",
                      "saved=\(engine.threadRecord(assistant)?.requestedSpeedTier ?? "nil") path=\(pressed.path)")
            } else {
                check.skip(label + " — " + pressed.path)
            }
        }
        let strengths = TatwoMemoryStrength.allCases
        let targetStrength: TatwoMemoryStrength = engine.doc.memoryStrength(for: assistant) == .deep ? .off : .deep
        if let index = strengths.firstIndex(of: targetStrength) {
            let pressed = await rig.pressStep(tracks[2], index: index, of: strengths.count) {
                engine.doc.memoryStrength(for: assistant) == targetStrength
            }
            let chipTexts = TatwoComposerMode.assistantSpace(model: model).segments.map(\.text)
            let label = "R11 [TATWO assistant page] a real click on the 記憶 step (\(targetStrength.title)) writes the assistant thread's memory and the chip reads it"
            if pressed.verified {
                check(pressed.ok && chipTexts.contains("記憶\(targetStrength.title)"), label + " — \(pressed.path)",
                      "memory=\(engine.doc.memoryStrength(for: assistant).title) chip=\(chipTexts) path=\(pressed.path)")
            } else {
                check.skip(label + " — " + pressed.path)
            }
        }

        // 模型：先放在清單最後一個能選的模型上，這樣清單第一個能選的列一定不是現在這個。
        let choices = before.models[0].options.filter { !$0.isDisabled }
        guard let first = choices.first, let last = choices.last, first.id != last.id else {
            check(false, "R11 [TATWO assistant page] fixture: two enabled models in the assistant's list")
            return
        }
        model.setAssistantModel(last.id)
        await rig.settle(6)
        let opened = await openModelList(rig)
        if let shot = rig.capture() { GlobalDMChatAcceptance.save(shot, "click-TATWO-assistant-page-model-list.png", to: artifacts) }
        check(opened, "R11 [TATWO assistant page] a real click on the 模型 row opens the model list inside the card (the tracks are gone)")
        var picked = false
        if opened { picked = await pickFirstModel(rig, model: model) }
        if let shot = rig.capture() { GlobalDMChatAcceptance.save(shot, "click-TATWO-assistant-page-after.png", to: artifacts) }
        let now = model.assistantRouteChoice.id
        check(picked && now != last.id && choices.contains { $0.id == now },
              "R11 [TATWO assistant page] a real click on a row of the model list changes the assistant's model (\(last.id) → \(now)) and the list closes",
              "picked=\(picked) now=\(now) was=\(last.id) tracksBack=\(!rig.trackFrames().isEmpty)")
    }

    /// 卡的主頁上點模型那一列：由上往下一點一點點（避開拉條），點到卡換成模型清單為止。換頁的當下卡的高度就變了（清單頁比主頁高），
    /// 但舊那頁淡出時它的拉條 view 還留著一下，所以「高度變了」才算點中，再等拉條 view 都走了（＝清單頁）。
    @MainActor static func openModelList(_ rig: ClickRig) async -> Bool {
        guard let card = rig.cardFrame() else { return false }
        let mainHeight = card.height
        let tracks = rig.trackFrames()
        var y = card.maxY - 22
        while y > card.minY + 10 {
            if !tracks.contains(where: { y > $0.minY - 5 && y < $0.maxY + 5 }) {
                await rig.click(NSPoint(x: card.minX + 80, y: y))
                if let now = rig.cardFrame(), abs(now.height - mainHeight) > 12 {
                    return await rig.wait { rig.trackFrames().isEmpty }
                }
            }
            y -= 8
        }
        return false
    }

    /// 模型清單頁上點第一個能選的列：由上往下一點一點點，點到助理的模型變了為止（清單收回去了、值沒變＝點到現在這個，回 false）。
    @MainActor static func pickFirstModel(_ rig: ClickRig, model: ChatPageModel) async -> Bool {
        guard let list = rig.cardFrame() else { return false }
        let was = model.assistantRouteChoice.id
        var y = list.maxY - 22
        while y > list.minY + 10 {
            await rig.click(NSPoint(x: list.minX + 80, y: y))
            if model.assistantRouteChoice.id != was { return true }
            if !rig.trackFrames().isEmpty { return false }
            y -= 8
        }
        return false
    }

    /// Space 搭建（W184 H4b：卡掛在整個輸入框上）：真的點 chip 開卡，量真的 view 的框——卡的下緣在輸入框上緣上方 8（不是工具列上方 8）、
    /// 右緣對齊、不蓋到打字區；再在卡上真的點 S～XXL 的 XL，Space 的協作檔位真的變了。
    @MainActor static func spaceClickChecks(_ check: Checker, artifacts: URL?) async {
        let domain = SpaceSetupPreviewState.Domain(id: "w184-mode-click-values", name: "測試工作室", bots: [])
        let probe = FrameProbe()
        let rig = ClickRig(SpaceComposerFrame(domain: domain, open: false, probe: probe), size: CGSize(width: 760, height: 620))
        defer { rig.close() }
        await rig.settle(8)
        guard let chip = rig.chipFrame() else {
            check(false, "R12 [Space setup] the mode chip is on screen to click")
            return
        }
        await rig.click(NSPoint(x: chip.minX + min(20, chip.width * 0.2), y: chip.midY))
        guard await rig.wait({ rig.has(TatwoComposerModeClickAwayView.self) }), let card = rig.cardFrame(),
              let composer = probe.composer, let toolbar = probe.toolbar else {
            check(false, "R12 [Space setup] open the card by a real click and read the composer's and toolbar's frames")
            return
        }
        let composerTop = rig.size.height - composer.minY
        let toolbarTop = rig.size.height - toolbar.minY
        check(abs(card.minY - (composerTop + 8)) <= 1.5 && abs(card.maxX - composer.maxX) <= 1.5,
              "R12 [Space setup] the real card's bottom edge sits 8 above the whole composer's top edge (not the toolbar's) and the right edges line up",
              "card=\(card) composer=\(composer) windowHeight=\(rig.size.height)")
        check(card.minY >= composerTop,
              "R12 [Space setup] the card no longer covers the composer's text area: its whole frame is above the composer (the toolbar's top is \(Int(composerTop - toolbarTop))pt inside it)",
              "cardBottom=\(card.minY) composerTop=\(composerTop) toolbarTop=\(toolbarTop)")
        if let shot = rig.capture() { GlobalDMChatAcceptance.save(shot, "click-Space-setup-card-above-composer.png", to: artifacts) }
        guard let track = rig.trackFrames().first else {
            check(false, "R12 [Space setup] the card shows a clickable S～XXL track")
            return
        }
        let realPointer = rig.moveOnScreen()
        await rig.settle(4)
        check.note("R12 [Space setup] slider clicks go through \(realPointer ? "real mouse events (window moved on screen, transparent)" : "nothing: no display big enough here, those checks are SKIP (unverified)"); screens=\(NSScreen.screens.count)")
        let levels = ChatCollaborationLevel.allCases.filter { $0 != .off }
        if let index = levels.firstIndex(of: .xl) {
            let pressed = await rig.pressStep(track, index: index, of: levels.count) { domain.composerCollaboration == .xl }
            let chipText = TatwoComposerMode.spaceSetup(domain: domain).segments.last?.text ?? "nil"
            let label = "R12 [Space setup] a real click on the XL stop of the card's S～XXL sets composerCollaboration and the chip reads ultrawork XL"
            if pressed.verified {
                check(pressed.ok && chipText == "ultrawork XL", label + " — \(pressed.path)",
                      "level=\(domain.composerCollaboration.title) chip=\(chipText) path=\(pressed.path)")
            } else {
                check.skip(label + " — " + pressed.path)
            }
        }
        if let shot = rig.capture() { GlobalDMChatAcceptance.save(shot, "click-Space-setup-after-xl.png", to: artifacts) }
    }

    /// 按得到的畫面：無邊框視窗放在螢幕外、排在畫面上（不透明、接滑鼠）；點＝排進 App 的事件佇列（NSApp.postEvent）。
    @MainActor final class ClickRig {
        let window: NSWindow
        let host: NSView
        let size: CGSize

        init<V: View>(_ view: V, size: CGSize) {
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
                .background(Color.white).environment(\.colorScheme, .light)))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -19_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.hasShadow = false
            window.contentView = host
            window.orderFrontRegardless()
            self.window = window
            self.host = host
            self.size = size
        }

        func settle(_ rounds: Int = 6) async {
            for _ in 0..<rounds {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }

        /// 視窗座標的一點：按下、放開。
        func click(_ point: NSPoint) async {
            let now = ProcessInfo.processInfo.systemUptime
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now + Double(index) * 0.05,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await settle(4)
        }

        /// 等到條件成立（開關有動畫：收起的那一下卡要等動畫跑完才拿掉），最多約 2 秒。
        func wait(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<40 {
                if condition() { return true }
                await settle(1)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return condition()
        }

        func has<T: NSView>(_ type: T.Type) -> Bool { !TatwoComposerModeAcceptance.views(type, in: host).isEmpty }

        /// 卡的位置（視窗座標；卡底下墊著點外面收起的那一層 TatwoComposerModeClickAwayView）；沒開＝nil。
        func cardFrame() -> NSRect? {
            TatwoComposerModeAcceptance.views(TatwoComposerModeClickAwayView.self, in: host).first
                .map { $0.convert($0.bounds, to: nil) }
        }

        /// 每條點得到的拉條（接滑鼠的那一層 ChatSliderPointerCaptureView；變淡的拉條沒有）的位置，由上往下（視窗座標 y 大的在上）。
        func trackFrames() -> [NSRect] {
            TatwoComposerModeAcceptance.views(ChatSliderPointerCaptureView.self, in: host)
                .map { $0.convert($0.bounds, to: nil) }
                .filter { $0.width > 100 && $0.height > 10 }
                .sorted { $0.midY > $1.midY }
        }

        /// 視窗現在在螢幕上嗎（見 moveOnScreen）。
        private(set) var onScreen = false

        /// 拉條的本機事件監看把事件的 cgEvent（螢幕座標）對回視窗：視窗放在螢幕外（預設，不打擾畫面）時對不回來，拉條就收不到事件
        /// （R7 的 chip 與點外面收起用 locationInWindow，不受影響）。點拉條前把視窗搬進螢幕——全透明、不接真的滑鼠，排進 App 事件佇列的事件照樣進得來；
        /// 沒有夠大的螢幕（沒有顯示器的環境）回 false。
        @discardableResult
        func moveOnScreen() -> Bool {
            guard let screen = NSScreen.screens.first(where: { $0.frame.width >= size.width + 40 && $0.frame.height >= size.height + 40 }) else {
                return false
            }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 20))
            onScreen = true
            return true
        }

        /// 點某條拉條（一共 count 檔）第 index 檔的正中間：放開的位置剛好在那一檔上，所以停在那一檔。
        /// 視窗在螢幕上（moveOnScreen）就送真的滑鼠事件（拉條的本機事件監看）。callbacks＝true 只給失敗後的診斷用：改叫拉條接的同一組
        /// onBegan／onChanged／onEnded 回呼（分得出「事件送不進來」與「接線壞了」；那一次一律記失敗，不算通過）。
        func clickStep(_ track: NSRect, index: Int, of count: Int, callbacks: Bool = false) async {
            let localX = track.width * (CGFloat(index) + 0.5) / CGFloat(max(count, 1))
            if onScreen && !callbacks {
                await click(NSPoint(x: track.minX + localX, y: track.midY))
                return
            }
            let captures = TatwoComposerModeAcceptance.views(ChatSliderPointerCaptureView.self, in: host)
            guard let capture = captures.first(where: {
                let frame = $0.convert($0.bounds, to: nil)
                return abs(frame.minX - track.minX) < 0.5 && abs(frame.midY - track.midY) < 0.5
            }) else { return }
            capture.onBegan?(localX)
            capture.onChanged?(localX)
            capture.onEnded?(localX)
            await settle(4)
        }

        struct Pressed {
            let ok: Bool
            /// false＝未驗證：這個環境送不了真的滑鼠事件（沒有夠大的螢幕），呼叫端記 SKIP 並寫原因——不叫回呼然後記 PASS。
            let verified: Bool
            let path: String
        }

        /// 點一檔並等值變（changed 為真）。W184 H4 修正（審查 #10）：只有真的滑鼠事件（視窗在螢幕上）才算數；沒有螢幕＝未驗證
        /// （以前改叫回呼、記 PASS，證明不了滑鼠路徑）。真的事件沒讓值變時，再用回呼試一次只為了分得出「事件送不進來」與「接線壞了」
        /// （ok 仍是 false）。
        func pressStep(_ track: NSRect, index: Int, of count: Int, until changed: @MainActor () -> Bool) async -> Pressed {
            guard onScreen else {
                return Pressed(ok: false, verified: false,
                               path: "未驗證：這個環境沒有夠大的螢幕，拉條的事件監看收不到送進來的滑鼠事件（不叫回呼充數）")
            }
            await clickStep(track, index: index, of: count)
            if await wait(changed) { return Pressed(ok: true, verified: true, path: "real mouse events") }
            await clickStep(track, index: index, of: count, callbacks: true)
            let viaCallbacks = await wait(changed)
            return Pressed(ok: false, verified: true,
                           path: "real mouse events did not change it; the pointer callbacks \(viaCallbacks ? "did (the wiring is fine, the event path is not)" : "did not either")")
        }

        /// 模式選擇 chip 的位置（視窗座標；chip 自己墊的定位點 TatwoComposerModeChipAnchorView）。
        func chipFrame() -> NSRect? {
            TatwoComposerModeAcceptance.views(TatwoComposerModeChipAnchorView.self, in: host).first
                .map { $0.convert($0.bounds, to: nil) }
                .flatMap { $0.width > 20 && $0.height > 10 ? $0 : nil }
        }

        func capture() -> GlobalDMChatAcceptance.Rendered? {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return GlobalDMChatAcceptance.Rendered(host: host, window: window, bitmap: bitmap, size: size)
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    /// 主視窗 Coder：輸入框（同 ChatPage+Composer：真的 ChatComposerTextView、附件、＋、全權、模式選擇 chip、送出，玻璃卡）＋模式卡。
    /// W184 H4 修正（審查 #7）：卡照 ChatPage+Composer 的掛法——掛在整個輸入框（玻璃卡）上（tatwoComposerModeCard：量真的上緣、
    /// 點卡外收卡不吞那一下、Esc 與鍵盤同一套）；不再照 ChatPage+Panels 的浮層離整頁底 104。整頁 ChatPage 不在自測裡畫
    /// （它一建起來就開 chat 的 Browser runtime）；這個掛法由 tests/w184-mode.test.mjs 守著跟 ChatPage+Composer 一樣。
    struct CoderOverlayFrame: View {
        let mode: TatwoComposerMode
        @State var open: Bool
        let probe: FrameProbe
        let lines: Int
        let attachments: [String]
        let onSend: () -> Void
        @State private var draft: String
        @State private var textHeight: CGFloat = 44

        init(mode: TatwoComposerMode, open: Bool, probe: FrameProbe, lines: Int = 1, attachments: [String] = [],
             onSend: @escaping () -> Void = {}) {
            self.mode = mode
            _open = State(initialValue: open)
            self.probe = probe
            self.lines = lines
            self.attachments = attachments
            self.onSend = onSend
            _draft = State(initialValue: lines > 1 ? (1...lines).map { "第 \($0) 行：幫我把登入流程拆成三步" }.joined(separator: "\n") : "")
        }

        var body: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // 同 ChatPage+Composer：玻璃卡＋下面塞進去 13 的狀態抽屜（間距 8），整塊離底 18；模式卡掛在玻璃卡上。
                VStack(alignment: .leading, spacing: 8) {
                    composer
                        .tatwoComposerModeCard(isPresented: $open) {
                            TatwoComposerModeCard(mode: mode, metrics: .main)
                                .background(CardMarker())
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.card = $0 }
                        }
                    ChatComposerStatusDrawer(text: nil, tone: .quiet)
                        .zIndex(-1)
                        .padding(.top, -13)
                }
                .frame(maxWidth: ChatUILayout.chatColumnMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 24)
            .background(TatwoActivePalette.current.canvasBase)
        }

        private var composer: some View {
            VStack(alignment: .leading, spacing: 0) {
                ChatComposerTextView(text: $draft, contentHeight: $textHeight, isFocused: false, placeholder: "要求後續跟進變更",
                                     isMonospaced: false, minimumHeight: 44, maximumHeight: 160,
                                     onSubmit: { onSend() }, onFocusChange: { _ in })
                    .frame(height: min(160, max(44, lines > 1 ? max(textHeight, CGFloat(lines) * 20) : textHeight)))
                    .padding(.horizontal, 20)
                    .padding(.top, 15)
                    .padding(.bottom, 8)
                if !attachments.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(attachments, id: \.self) { name in
                            Label(name, systemImage: "doc")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .chatGlassChip(isSelected: false)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 6)
                }
                ChatComposerToolbarRow(compact: false) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.secondary)
                    ChatComposerPermissionLabel(symbol: "exclamationmark.shield", title: "全權", tint: Color.red.opacity(0.88))
                    Spacer(minLength: 14)
                    // 同 ChatPage 的 composerModeChip：按了切換卡（toggleComposerModeCard）。
                    ChatComposerModeChip(segments: mode.segments, selected: open, help: mode.help) {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { open.toggle() }
                    }
                    .layoutPriority(1)
                    ChatComposerSendButton(enabled: true) { onSend() }
                        .background(SendMarker())
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 8)
            }
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.composer = $0 }
        }
    }

    /// 送出鈕的記號（自測找它在哪、真的去點；不畫東西、不接點擊）。
    private struct SendMarker: NSViewRepresentable {
        func makeNSView(context: Context) -> SendMarkerView { SendMarkerView() }
        func updateNSView(_ view: SendMarkerView, context: Context) {}
    }

    final class SendMarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// 主視窗浮層裡那張卡的記號（自測看卡在不在；不畫東西、不接點擊）。
    private struct CardMarker: NSViewRepresentable {
        func makeNSView(context: Context) -> CardMarkerView { CardMarkerView() }
        func updateNSView(_ view: CardMarkerView, context: Context) {}
    }

    final class CardMarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Space 搭建輸入框的樣子（同 SpaceSetupPreviewView 的 SpaceSetupBuilderView.composer：文字＋SpaceSetupComposerToolbar，玻璃卡，
    /// W184 H4b：模式卡掛在整張玻璃卡上、開關是玻璃卡這一層的 open，用 Binding 傳給工具列——tests/w184-mode.test.mjs 守著正式那邊是同一個掛法）。
    struct SpaceComposerFrame: View {
        @ObservedObject var domain: SpaceSetupPreviewState.Domain
        @State private var open: Bool
        let probe: FrameProbe

        init(domain: SpaceSetupPreviewState.Domain, open: Bool, probe: FrameProbe) {
            _domain = ObservedObject(wrappedValue: domain)
            _open = State(initialValue: open)
            self.probe = probe
        }

        var body: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    Text("描述你希望如何搭建這個自訂 work space")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                        .padding(.horizontal, 20)
                        .padding(.top, 15)
                        .padding(.bottom, 8)
                    SpaceSetupComposerToolbar(domain: domain, compact: false, modeOpen: $open)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.toolbar = $0 }
                        .padding(.horizontal, 11)
                        .padding(.bottom, 8)
                }
                .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.composer = $0 }
                .tatwoComposerModeCard(isPresented: $open) {
                    TatwoComposerModeCard(mode: TatwoComposerMode.spaceSetup(domain: domain), metrics: .main)
                }
            }
            .padding(24)
            .background(TatwoActivePalette.current.canvasBase)
        }
    }

    /// TATWO 助理頁（真的 AssistantSpacePane，視窗模式：輸入框的位置由頁面自己回報給 GlobalDMComposerFrames）。
    struct AssistantPaneFrame: View {
        @ObservedObject var model: ChatPageModel
        let open: Bool

        var body: some View {
            AssistantSpacePane(model: model, modeCardOpen: open)
                .environment(\.tatwoSurfaceKind, .window)
                .background(TatwoActivePalette.current.canvasBase)
        }
    }

    // MARK: - 無障礙：按一下、重畫

    /// 在無障礙樹裡找到這個識別碼的元素，對它做「按一下」（AXPress）；找不到或不支援回 false。
    @MainActor static func press(_ identifier: String, in rendered: GlobalDMChatAcceptance.Rendered) -> Bool {
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
        var seen = Set<ObjectIdentifier>()
        var found: NSObject?
        func visit(_ element: Any, depth: Int) {
            guard found == nil, depth < 80, seen.count < 6000, let object = element as? NSObject,
                  seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let id = attribute(object, "accessibilityIdentifier", legacy: "AXIdentifier") as? String, id == identifier {
                found = object
                return
            }
            for child in attribute(object, "accessibilityChildren", legacy: "AXChildren") as? [Any] ?? [] {
                visit(child, depth: depth + 1)
            }
            if let view = object as? NSView { for sub in view.subviews { visit(sub, depth: depth + 1) } }
        }
        visit(rendered.window, depth: 0)
        visit(rendered.host, depth: 0)
        guard let target = found else { return false }
        // 動態呼叫（不是每一種節點都有 accessibilityPerformPress；沒有就是 nil，再試舊式的 AXPress 動作）。
        if let pressed = (target as AnyObject).accessibilityPerformPress?() {
            return pressed
        }
        let legacy = NSSelectorFromString("accessibilityPerformAction:")
        guard target.responds(to: legacy) else { return false }
        _ = target.perform(legacy, with: NSAccessibility.Action.press.rawValue)
        return true
    }

    /// 按了之後讓 SwiftUI 跑幾輪（改狀態、重排、重建無障礙樹）。
    @MainActor static func settle(_ rendered: GlobalDMChatAcceptance.Rendered) {
        for _ in 0..<8 {
            rendered.host.layoutSubtreeIfNeeded()
            rendered.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
    }

    /// 同一個視窗重拍一張（按了之後的樣子）。
    @MainActor static func recapture(_ rendered: GlobalDMChatAcceptance.Rendered) -> GlobalDMChatAcceptance.Rendered? {
        rendered.host.layoutSubtreeIfNeeded()
        guard let bitmap = rendered.host.bitmapImageRepForCachingDisplay(in: rendered.host.bounds) else { return nil }
        rendered.host.cacheDisplay(in: rendered.host.bounds, to: bitmap)
        return GlobalDMChatAcceptance.Rendered(host: rendered.host, window: rendered.window, bitmap: bitmap, size: rendered.size)
    }

    // MARK: - 找 view、量像素（不管位元組順序）

    @MainActor static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        func visit(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return found
    }

    /// 一個 view 在畫出來的圖上的位置（點、y 由上往下；畫的時候 host 就是整個視窗內容）。
    @MainActor static func imageRect(_ view: NSView, in rendered: GlobalDMChatAcceptance.Rendered) -> CGRect {
        let rect = view.convert(view.bounds, to: nil)
        return CGRect(x: rect.minX, y: rendered.size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 純紅（探針卡）占的範圍，單位是點、y 從上往下：一個像素裡剛好兩個值很暗、其他都很亮＝紅（白底上只有它是這樣）。
    @MainActor static func redBounds(_ rendered: GlobalDMChatAcceptance.Rendered) -> CGRect? {
        let rep = rendered.bitmap
        guard rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let data = rep.bitmapData else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh, samples = rep.samplesPerPixel, row = rep.bytesPerRow
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let pixel = data + y * row + x * samples
                var low = 0, high = 0
                for s in 0..<samples {
                    if pixel[s] < 60 { low += 1 } else if pixel[s] > 200 { high += 1 }
                }
                guard low == 2, high == samples - 2 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let sx = CGFloat(width) / rendered.size.width, sy = CGFloat(height) / rendered.size.height
        return CGRect(x: CGFloat(minX) / sx, y: CGFloat(minY) / sy,
                      width: CGFloat(maxX - minX + 1) / sx, height: CGFloat(maxY - minY + 1) / sy)
    }

    /// 兩張同大小的圖在 y < limit（點）這一段不一樣的地方的範圍（每個值差超過 24 才算；紙紋、玻璃每次畫都一樣）。
    @MainActor static func diffBounds(_ a: GlobalDMChatAcceptance.Rendered, _ b: GlobalDMChatAcceptance.Rendered,
                                      above limit: CGFloat) -> CGRect? {
        let ra = a.bitmap, rb = b.bitmap
        guard ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh, ra.samplesPerPixel == rb.samplesPerPixel,
              ra.bitsPerSample == 8, rb.bitsPerSample == 8, !ra.isPlanar, !rb.isPlanar,
              let da = ra.bitmapData, let db = rb.bitmapData else { return nil }
        let samples = ra.samplesPerPixel
        let sx = CGFloat(ra.pixelsWide) / a.size.width, sy = CGFloat(ra.pixelsHigh) / a.size.height
        let rows = min(ra.pixelsHigh, Int(limit * sy))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<max(rows, 0) {
            for x in 0..<ra.pixelsWide {
                let pa = da + y * ra.bytesPerRow + x * samples
                let pb = db + y * rb.bytesPerRow + x * samples
                var differs = false
                for s in 0..<samples where abs(Int(pa[s]) - Int(pb[s])) > 24 {
                    differs = true
                    break
                }
                guard differs else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / sx, y: CGFloat(minY) / sy,
                      width: CGFloat(maxX - minX + 1) / sx, height: CGFloat(maxY - minY + 1) / sy)
    }

    /// 查核 #13：只看某幾欄（點）、整個高度：兩張圖不一樣的最上一列與最下一列（點，y 由上往下）；excluding 裡的範圍不算（chip 自己變色）。
    @MainActor static func diffRows(_ a: GlobalDMChatAcceptance.Rendered, _ b: GlobalDMChatAcceptance.Rendered,
                                    columns: ClosedRange<CGFloat>, excluding: [CGRect] = []) -> (minY: CGFloat, maxY: CGFloat)? {
        let ra = a.bitmap, rb = b.bitmap
        guard ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh, ra.samplesPerPixel == rb.samplesPerPixel,
              ra.bitsPerSample == 8, rb.bitsPerSample == 8, !ra.isPlanar, !rb.isPlanar,
              let da = ra.bitmapData, let db = rb.bitmapData else { return nil }
        let samples = ra.samplesPerPixel
        let sx = CGFloat(ra.pixelsWide) / a.size.width, sy = CGFloat(ra.pixelsHigh) / a.size.height
        let x0 = max(0, Int(columns.lowerBound * sx)), x1 = min(ra.pixelsWide - 1, Int(columns.upperBound * sx))
        guard x0 <= x1 else { return nil }
        var minY = Int.max, maxY = -1
        for y in 0..<ra.pixelsHigh {
            for x in x0...x1 {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / sx, y: (CGFloat(y) + 0.5) / sy)
                if excluding.contains(where: { $0.contains(point) }) { continue }
                let pa = da + y * ra.bytesPerRow + x * samples
                let pb = db + y * rb.bytesPerRow + x * samples
                var differs = false
                for s in 0..<samples where abs(Int(pa[s]) - Int(pb[s])) > 24 {
                    differs = true
                    break
                }
                guard differs else { continue }
                minY = min(minY, y); maxY = max(maxY, y)
                break
            }
        }
        guard maxY >= 0 else { return nil }
        return (CGFloat(minY) / sy, CGFloat(maxY + 1) / sy)
    }

    /// 查核 #14：畫出來的 S～XXL 那一排（卡上最上面那條拉條；每一條拉條都有接滑鼠的那一層 ChatSliderPointerCaptureView，照它找位置），
    /// 五格各取左右兩點（避開中間的字），跟拉條上方 5 點的卡底色比，差多少（0～255）。
    @MainActor static func trackCells(_ rendered: GlobalDMChatAcceptance.Rendered) -> [CGFloat]? {
        guard let track = views(ChatSliderPointerCaptureView.self, in: rendered.host).map({ imageRect($0, in: rendered) })
                .filter({ $0.width > 100 }).min(by: { $0.minY < $1.minY }) else { return nil }
        let rep = rendered.bitmap
        guard rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let data = rep.bitmapData else { return nil }
        let samples = rep.samplesPerPixel
        let sx = CGFloat(rep.pixelsWide) / rendered.size.width, sy = CGFloat(rep.pixelsHigh) / rendered.size.height
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let px = min(max(Int(x * sx), 0), rep.pixelsWide - 1), py = min(max(Int(y * sy), 0), rep.pixelsHigh - 1)
            let start = data + py * rep.bytesPerRow + px * samples
            return (0..<samples).map { Int(start[$0]) }
        }
        let row = track.midY, base = track.minY - 5
        let cell = track.width / 5
        return (0..<5).map { index -> CGFloat in
            let differences = [CGFloat(0.15), CGFloat(0.85)].map { fraction -> Int in
                let x = track.minX + cell * (CGFloat(index) + fraction)
                let a = pixel(x, row), b = pixel(x, base)
                return zip(a, b).map { abs($0 - $1) }.max() ?? 0
            }
            return CGFloat(differences.reduce(0, +)) / CGFloat(differences.count)
        }
    }
}
#endif
