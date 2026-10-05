#if DEBUG
import AppKit
import Combine
import QuartzCore
import SwiftUI
import Vision

// W184 F3T（新房 F3T：只寫測試、不改產品程式）：GPT-6 審查 F3（H/w184f3-gpt6-report.md）第 4、5 條——現有的 H1、H12 抓不到兩類退步：
// - 第 4 條：H1 只驗「捲上去 200pt」這一種、只看回到外直那一刻；沒驗「原本在最底仍在最底」，也沒驗輸入框的焦點與組字（IME 的 marked text）。
// - 第 5 條：H12 從 applyForm 之後才開始計時（開始的卡頓漏掉），也沒要求停下的計時器真的把轉場收掉。
// 這裡補五類（R1–R5），全部在真的面板控制器＋桌面控制器上跑：換形態走 desk.setForm（⌥⌘Tab 與頁面圓鈕右鍵選單用的同一個入口），
// 轉向＝動畫中再 setForm 一次。判斷只看行為：捲動區的位置、first responder 與 NSTextInputClient 的狀態、圖層台在不在、真的框的透明度、
// 原生頁與配對碼有沒有顯示回來——不讀圖層台內部的切片（房 AB 正在改）。
// R1–R3 的時鐘由自測推（同 H1；每格之間讓主執行緒真的空下來：排到下一輪的整理、SwiftUI 的更新照正式那樣跑）；R4、R5 用真的時鐘與
// 真的螢幕更新（display link）。畫面都在 alpha 0 的面板裡（排在畫面上、看不見）。對話內容是 fixture 的假訊息。
// W184 F3T 修正（查核者列的五條「退步時仍會通過」，逐條查證成立才加強；照樣只寫測試、不改產品程式）：
// 1. 收乾淨不只看 canvas.stage＝nil：畫布上不能還留著圖層台的 view（GlobalDMStageView 在整塊畫布上 hitTest 都回傳自己、點了沒反應，
//    舊圖蓋在真的框上），而且從框中央、每一個看得到的輸入框中心打 hitTest，要打到真的框（canvas.host）底下。
// 2. 真的時鐘的轉向：開始後 0.3 秒再按一次，轉向那一刻用 plan.end − elapsed 重算該停的時間，晚 ≤0.1 秒；再一段轉向＋主執行緒卡 0.3 秒
//    橫跨新的停下時間。停下的計時器沒扣掉已經走的時間，轉向在第 t 秒就晚 t 秒（R1–R3 的轉向是自測推時鐘、不排計時器，抓不到）。
// 3. display link 停掉＝面板移到所有螢幕之外（綁在面板 view 上的 link 沒有螢幕可跟）＋自測自己的 link 停掉；產品的三個檔不准有
//    display link（tests/w184-forms.test.mjs 守）：產品自己加一條 link 來收尾，這一段不一定停得到它。
// 4. R4 每個方向各量三次、各自的中位數比門檻（三個方向混在一起取中位數，只有一個方向慢會被蓋掉）；另量真的時鐘轉向的開始成本；
//    內橫右欄的第二個 store 照正式那樣在 setForm 裡同步（自測自己的 suite；右欄的對象是一條 session，不叫醒 ChatGPT）。
// 5. 「離最底多近算在最底」兩邊都釘住（產品的線是 8pt）：離最底 90pt 看訊息，變矮的兩段不被拉到最底；離最底 4pt 算在最底，變矮之後拉回最底。
extension GlobalDMFormsAcceptance {
    /// R1：每一段停下之後離最底最多幾點（施工單：≤1pt）。
    static let regressionBottomTolerance: CGFloat = 1
    /// R2：看舊訊息時停下的位置最多差幾點（同 H1：LazyVStack 沒畫到的列高度是估計的，欄寬一變會重新換行）。
    static let regressionReadingTolerance: CGFloat = 20
    /// R2（W184 G3c，房 C）：捲上去 200pt 那一組，讀的那一則對齊成第一列時它的字離上緣幾點（上緣 24pt 是漸淡；間距 18 讓上面那一列在框外）。
    static let regressionFirstRowTop: CGFloat = 16
    /// R4：從使用者按下去（入口 desk.setForm 之前）到第一個看得到的畫面（圖層台蓋上去之後 display link 的第一格），三段的中位數上限（毫秒）。
    /// 理由：人對「按了有反應」的感覺大約 100ms，超過就覺得頓；再加一格畫面（60Hz 約 17ms）與主執行緒的雜訊，150ms 是寬鬆的上限。
    /// 換形態本身是 0.42 秒的彈簧：開始之前多停 0.2 秒，等於整段多了一半的時間是「按了沒動」（使用者 09-29 驗收 .030 說「切換卡頓卡頓的」）。
    /// mini 上實測（W184 F3T，bb510989，兩次）：中位數 224／226ms，三段 146–260ms，兩次差 ≤3ms（穩定、不是雜訊）；同樣的換形態在
    /// Browser 頁開著（框裡沒有對話列表）時 88–98ms——多出來的時間在拍舊的樣子與排版、拍新的樣子。門檻不照實測放寬：放寬到實測值
    /// 等於把使用者說的卡頓當成合格；這一條在 bb510989 上失敗＝回報給房 AB 的真問題。取三段的中位數，單次偶發的停頓不算。
    static let regressionStartBudget: Double = 150
    /// R4：每一段按下去之前先讓主執行緒空這麼久（秒）：上一段停下之後的整理都做完、像使用者看了一下才按（量到的是按下去本身的成本）。
    static let regressionStartIdle: Double = 0.4
    /// R5：該停下的時間到了（或主執行緒被放開）之後，最多再多久一定收好（秒）。停下的計時器準時是 +2ms，這裡留寬。
    static let regressionSettleSlack: Double = 0.25
    /// R4 每個方向量幾次（取那個方向自己的中位數；轉向也量這麼多次）。
    static let regressionStartRounds = 3
    /// R5 真的時鐘的轉向：第一次按下去（setForm 回來）之後第幾秒再按一次；主執行緒卡住的那一段轉向在第幾秒。
    /// 都在第一段該停下（0.6 秒）之前：真的是動畫中轉向。
    static let regressionTurnAt: Double = 0.3
    static let regressionBlockedTurnAt: Double = 0.35
    /// R5 轉向：轉向之後該停下的時間（轉向那一刻用 plan.end − elapsed 重算）到了之後，最多再多久一定收好（秒）。
    /// 比 regressionSettleSlack 緊：停下的計時器沒扣掉已經走的時間（間隔＝plan.end 而不是 plan.end − elapsed）時，轉向在第 t 秒就晚 t 秒——
    /// 這裡轉向在 ≥0.3 秒，晚 ≥0.3 秒；卡住的那一段在放開之後還晚 ≥0.2 秒（0.35 − 0.15）。準時的收尾在 mini 上是 +5～21ms（F3T 在
    /// bb510989 實測），0.1 秒留了約 5 倍。
    static let regressionTurnSlack: Double = 0.1
    /// R2（查核加強 #5）：看最底上面一點點——大約離最底幾點（剛過產品「算在最底」的 8pt 線；那條線放寬到超過這裡就會被拉到最底）。
    /// 實際的起點：先捲到這裡＋50，再把最上面那一則對齊到頂端（placeNearBottom），落在 20–150pt。
    static let regressionNearBottom: CGFloat = 90
    /// R1（查核加強 #5）：離最底幾點（在 8pt 線以內）＝算在最底，換形態停下要拉回最底（那條線收窄到這裡以下就抓得到）。
    static let regressionPinnedBottom: CGFloat = 4

    /// 開框請求接到面板控制器、轉換狀態接到桌面控制器（Browser、連線卡片要比它們早建）。
    @MainActor final class RegressionRefs {
        var panels: GlobalDMPanelController?
        var desk: GlobalDMDeskController?
    }

    /// 自測推的時鐘（formMotion.clock 換成它；停著不動，一格一格往前推）。
    @MainActor final class RegressionClock {
        var now: CFTimeInterval = 7_000
    }

    /// 每一段停著的樣子沒收好的記錄（R5：每一段都看）。
    @MainActor final class RegressionLog {
        var segments = 0
        var issues: [String] = []
    }

    /// 一段換形態：到哪個形態；turnAt＝動畫中第幾格（1/60 秒一格）再換一次（轉向）到 turnTo。
    struct RegressionSegment {
        let to: GlobalDMForm
        var turnAt: Int? = nil
        var turnTo: GlobalDMForm? = nil
        let label: String
    }

    /// 一段（自測推時鐘）走完的樣子：真的滑了（圖層台蓋上去）、有轉向、走了幾格。
    struct RegressionLanding {
        var animated = false
        var turned = false
        var steps = 0
    }

    /// 真的時鐘跑一段時加的干擾（R5）。
    enum RegressionDisturb {
        /// 不加干擾。
        case quiet
        /// 開始後 at 秒把主執行緒佔住 length 秒（動畫中段；停下的時間之前就放開）。
        case block(at: Double, length: Double)
        /// 該停下的時間之前 length/2 秒開始把主執行緒佔住 length 秒：正式的停下計時器一定晚到（有轉向＝照轉向之後重算的停下時間）。
        case blockAcrossStop(length: Double)
        /// 開始後 at 秒 display link 全停：面板移到所有螢幕之外（綁在面板 view 上的 link 沒有螢幕可跟；移開之後 0.12 秒量自測的 link
        /// 收到幾格），再把自測自己的 link 停掉（之後沒有任何一格回呼）；計時器照走，停下時產品把面板擺回原位。
        case linksStopped(at: Double)
        /// 整段都讓 run loop 停在 event tracking 模式（選單開著、拖曳中的樣子）。
        case eventTracking
    }

    /// 真的時鐘跑一段記下來的東西（時間是 CACurrentMediaTime；毫秒的欄位另外寫）。
    struct RegressionRealRun {
        var label = ""
        var accepted = false, staged = false
        /// 按下去（setForm 之前）到 setForm 回來（圖層台已經蓋上去）、到之後 display link 的第一格；applyForm 本身花多久（毫秒）。
        var toStage = -1.0, toFrame = -1.0, apply = -1.0
        var settleAt = 0.0, finishedAt = 0.0, blockEnd = 0.0, pausedAt = 0.0
        var ticks = 0, ticksAfterPause = -1
        var cleanAtStop = false, cleanLater = false
        var detail = ""
        /// 面板控制器自己記的開始那一段的分段時間（applyForm 裡：藏、換畫布、排版、拍新的、台；只印出來查原因，不拿來判斷）。
        var trace = ""
        /// until 的條件在停下之後多久成立（毫秒；-1＝沒成立或沒給）。
        var untilAfter = -1.0
        /// 第一次按下去之後第一段該停下的時間（plan 的秒數，轉向要在它之前才算動畫中轉向）。
        var firstEnd = -1.0
        /// 轉向（動畫中再按一次）：按下去、setForm 回來的時間；按下去到 setForm 回來、到之後 display link 的第一格、applyForm 本身（毫秒）；
        /// 轉向在這一整段的第幾秒（plan 的時間：新的那一段從哪裡開始）。
        var turnPressed = 0.0, turnReturned = 0.0
        var turnAccepted = false, turnStaged = false
        var turnToStage = -1.0, turnToFrame = -1.0, turnApply = -1.0, turnStart = -1.0
        var turnPlanned = false
        var turned: Bool { turnPressed > 0 }
        /// display link 全停那一段：面板移開的時間、真的在所有螢幕之外、移開之後到自測的 link 停掉之前那一小段 link 收到幾格（-1＝沒量）。
        var movedAt = 0.0, offscreen = false, framesOffscreen = -1
        var screenWhileOff = ""
        var finished: Bool { finishedAt > 0 }
        /// 停下比該停的時間晚多少（毫秒）。
        var late: Double { finished ? (finishedAt - settleAt) * 1000 : -1 }
        /// 停下比「該停的時間」與「主執行緒被放開」兩者較晚的那一個晚多少（秒）。
        var lateAfterRelease: Double { finished ? finishedAt - max(settleAt, blockEnd) : 99 }
    }

    @MainActor static func regressionChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults, model: ChatPageModel) async {
        let store = GlobalDMStore(defaults: freshDefaults("f3tStore"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let settings = GlobalDMDeskSettings(defaults: freshDefaults("f3tDesk"))
        settings.form = .outerPortrait
        let refs = RegressionRefs()
        let never = Just(false).eraseToAnyPublisher()
        // Browser 與［連線］卡片都是自測自己的一份（假頁面、假配對碼），接進真的面板控制器與桌面控制器（同 S 段的接法）。
        let browser = DMBrowser(store: store, openRequest: { request in refs.panels?.open(request) }, pageHost: DMBrowserAcceptance.FakeWebHost(),
                                podPage: { DMBrowserPhoneAcceptance.EvidencePage("ChatGPT（假頁面・F3T）") },
                                windowShown: { $0.isVisible }, transitions: { refs.desk?.$isFormTransitioning.eraseToAnyPublisher() ?? never })
        let card = DMBrowserPhoneAcceptance.CardBox()
        let presenter = HandsConnectPresenter(store: store, openRequest: { request in refs.panels?.open(request) }, browser: browser,
                                              hookPod: { _ in }, podURL: { nil }, cancelFlow: {}, card: { card.card })
        let panels = GlobalDMPanelController(store: store, desk: settings, hostsWindows: true,
                                             browserServices: GlobalDMBrowserServices(browser: browser, flow: DMBrowserPhoneAcceptance.inertFlow(),
                                                                                      connect: presenter))
        // 查核加強 #4：內橫的右欄照正式那樣在 setForm 裡同步（GlobalDMDuo.sync：第一次進內橫建第二個 store、接上 model、驗對象、登記看得到），
        // R4 量開始的成本才把它算進去——用自測自己的 suite，先記一條 session 當右欄的對象（右欄的預設不會挑到 ChatGPT：不叫醒 ChatGPT）；
        // 沒有 session 可記＝照舊不建（第二個 store 的預設在沒有 session 時是 ChatGPT）。框裡右欄的畫面讀的是 GlobalDMDuo.shared
        //（GlobalDMView），不是這一份：量到的是 sync 本身的工作，右欄畫面的排版照舊是 shared 那一份。
        var duoDefaults: UserDefaults?
        if let session = store.recentSessions().first(where: { GlobalDMTarget.thread($0.id) != store.target }) {
            let defaults = freshDefaults("f3tDuo")
            defaults.set(GlobalDMTarget.thread(session.id).storageValue, forKey: GlobalDMStore.lastTargetKey)
            duoDefaults = defaults
        }
        let duo = GlobalDMDuo(defaults: duoDefaults)
        let desk = GlobalDMDeskController(store: store, settings: settings, hotkeys: GlobalDMHotKeys(backend: GlobalDMDeskFakeHotKeyBackend()),
                                          panels: panels, duo: duo, browser: browser)
        refs.panels = panels
        refs.desk = desk
        panels.install()
        desk.install()
        let clock = RegressionClock()
        let frames = GlobalDMRegressionFrameLog()
        let log = RegressionLog()
        defer {
            frames.detach()
            panels.formMotion.manualTime = false
            panels.formMotion.clock = { CACurrentMediaTime() }
            presenter.hide()
            card.card = nil
            browser.closeAll()
            store.setDraft("", for: .assistant)
            store.close()
            duo.sync(primary: store, showing: false)   // 右欄的第二個 store 不再算看得到
            desk.uninstall()
            panels.uninstall()
            DMSecretCodeView.suppress(false)
        }
        store.openFloating()
        _ = await DMBrowserAcceptance.waitUntil(2) { panels.boxPanelForTesting?.isVisible == true }
        guard let panel = panels.boxPanelForTesting, panel.isVisible, let canvas = panel.contentView as? GlobalDMPanelCanvas else {
            return check.skip("R1–R5 換形態的回歸（F3T）：這個環境開不出浮動框（沒有畫面環境）")
        }
        panel.alphaValue = 0   // 自測不在螢幕上閃
        try? await Task.sleep(nanoseconds: 300_000_000)
        print("W184FORMS NOTE R F3T rig: floating panel \(panel.frame), reduce motion \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), "
              + "inner landscape right column synced through "
              + (duoDefaults == nil ? "no second store (no session to pick)" : "a GlobalDMDuo on the self-test's own suite (right column = a session)"))

        // 畫布裡放一個 Browser 頁面容器（一頁假網頁）與一個倒放影片容器（一塊假影片）：轉換期間被遮蔽藏起來、塗佔位色；
        // 每一段停下都要顯示回來、底色還原（R5「遮蔽已釋放」照行為看）。查核加強 #1：放在框右上角的空白（頂列右邊沒有東西）、
        // 跟著畫布的右上角走——不蓋住框中央與輸入框（停著的樣子從那兩個點打 hitTest，看點擊到不到得了真的框）。
        let rigTop = canvas.bounds.maxY - GlobalDMLayout.margin - 12, rigRight = canvas.bounds.maxX - GlobalDMLayout.margin - 16
        let pageHost = DMBrowserPageContainer(frame: NSRect(x: rigRight - 128, y: rigTop - 40, width: 60, height: 40))
        let pageView = NSView(frame: pageHost.bounds)
        pageHost.addSubview(pageView)
        let tentHost = DMTentVideoContainer(frame: NSRect(x: rigRight - 60, y: rigTop - 34, width: 60, height: 34))
        let video = NSView(frame: tentHost.bounds)
        tentHost.addSubview(video)
        pageHost.autoresizingMask = [.minXMargin, .minYMargin]
        tentHost.autoresizingMask = [.minXMargin, .minYMargin]
        canvas.addSubview(pageHost)
        canvas.addSubview(tentHost)
        defer {
            pageHost.removeFromSuperview()
            tentHost.removeFromSuperview()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let pageFill = pageHost.layer?.backgroundColor, tentFill = tentHost.layer?.backgroundColor
        let mask = GlobalDMNativePageMask.shared

        /// R5：停著的樣子——不在轉換、圖層台拆掉、真的框透明度 1 而且填滿面板、面板在照目前形態擺的位置、遮蔽放掉（頁面顯示回來、
        /// 佔位色還原）、配對碼的轉換遮蔽關掉。
        /// 查核加強 #1：「圖層台拆掉」照行為看——畫布上沒有任何圖層台的 view（只把 stage 設成 nil、view 還蓋在框上＝舊圖蓋住真的框、
        /// 點了沒反應也照樣算收好），而且點擊到得了真的框：框中央、每一個看得到的輸入框中心，從畫布打 hitTest 打到的 view 都在 canvas.host 底下。
        func settledState() -> (ok: Bool, detail: String) {
            let animating = panels.formMotion.isAnimating
            let staged = canvas.stage != nil
            let stageViews = canvas.subviews.filter { $0 is GlobalDMStageView }.count
            let alpha = canvas.host.alphaValue
            let hostShown = !canvas.host.isHidden
            let filled = canvas.host.frame == canvas.bounds
            let placed = panels.placedPanelFrameForTesting().map { regressionNear($0, panel.frame, 0.5) } ?? false
            let masking = mask.isMasking
            let hiddenPages = mask.hiddenPages.count
            let pagesShown = !pageView.isHidden && !video.isHidden
            let pageBack = pageHost.layer?.backgroundColor == pageFill
            let tentBack = tentHost.layer?.backgroundColor == tentFill
            let codeSuppressed = DMSecretCodeView.suppressed
            let clicks = regressionClicks(canvas, panel: panel)
            let ok = !animating && !staged && alpha == 1 && filled && placed && !masking && hiddenPages == 0 && pagesShown && pageBack && tentBack
                && !codeSuppressed && stageViews == 0 && clicks.ok && hostShown
            let detail = "animating=\(animating) stage=\(staged) stageViews=\(stageViews) alpha=\(alpha) hostShown=\(hostShown) hostFills=\(filled) "
                + "placed=\(placed) masking=\(masking) hiddenPages=\(hiddenPages) pagesShown=\(pagesShown) fillsBack=\(pageBack && tentBack) "
                + "codeSuppressed=\(codeSuppressed) \(clicks.detail)"
            return (ok, detail)
        }

        // MARK: R1–R3（時鐘由自測推）

        panels.formMotion.clock = { clock.now }
        panels.formMotion.manualTime = true
        /// 一段（或中途轉向的一段）換形態：走 desk.setForm（使用者的入口），時鐘由自測推，每 1/60 秒一格走到停下（每格之間讓主執行緒空 4ms）；
        /// 停下那一格（同一個 tick 裡，還沒讓主執行緒跑別的）叫 atStop 量一次，之後讓主執行緒空 0.15 秒（停下之後的整理、SwiftUI 的更新）。
        /// R5：每一段停下那一刻與 0.15 秒後各看一次停著的樣子（停下那一刻先量 atStop、再看停著的樣子：點擊的 hitTest 不插在量位置之前）。
        func land(_ segment: RegressionSegment, afterStart: () -> Void = {}, atStop: () -> Void) async -> RegressionLanding {
            var landing = RegressionLanding()
            let accepted = desk.setForm(segment.to)
            landing.animated = accepted && panels.formMotion.isAnimating && canvas.stage != nil
            afterStart()   // W184 AB（R2 查證）：setForm 回來＝真的框已經照新形態、新大小排好（動畫的第一格之前）
            var stopState: (ok: Bool, detail: String)?
            while panels.formMotion.isAnimating, landing.steps < 240 {
                if let turnAt = segment.turnAt, let turnTo = segment.turnTo, landing.steps == turnAt {
                    landing.turned = desk.setForm(turnTo) && panels.formMotion.isAnimating && canvas.stage != nil
                }
                clock.now += 1.0 / 60
                panels.formMotion.tick()
                landing.steps += 1
                if !panels.formMotion.isAnimating {
                    atStop()
                    stopState = settledState()
                    break
                }
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let later = settledState()
            log.segments += 1
            if stopState?.ok != true || !later.ok {
                log.issues.append("\(segment.label): at stop \(stopState?.detail ?? "never stopped"); 0.15s later \(later.detail)")
            }
            return landing
        }

        // 一整圈：外直→內橫（變矮）→內直（變高）→外直（變矮）；再來兩段中途轉向（外直→內橫在 0.15 秒轉向內直、內直→外直在 0.13 秒轉向內橫）；
        // 最後內橫→外直回到起點。
        let loop: [RegressionSegment] = [
            RegressionSegment(to: .innerLandscape, label: "outer→land (shorter)"),
            RegressionSegment(to: .innerPortrait, label: "land→innerP (taller)"),
            RegressionSegment(to: .outerPortrait, label: "innerP→outer (shorter)"),
            RegressionSegment(to: .innerLandscape, turnAt: 9, turnTo: .innerPortrait, label: "outer→land turned at 0.15s→innerP"),
            RegressionSegment(to: .outerPortrait, turnAt: 8, turnTo: .innerLandscape, label: "innerP→outer turned at 0.13s→land (shorter)"),
            RegressionSegment(to: .outerPortrait, label: "land→outer (taller)"),
        ]
        func chatList() -> NSScrollView? {
            DMBrowserPhoneAcceptance.views(NSScrollView.self, in: canvas.host)
                .filter { !$0.isHiddenOrHasHiddenAncestor && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 40 }
                .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        }
        /// 還是同一個捲動區（沒有被重建、還在這個面板的真的框裡）。
        func inPanel(_ list: NSScrollView) -> Bool {
            list.window === panel && DMBrowserPhoneAcceptance.views(NSScrollView.self, in: canvas.host).contains { $0 === list }
        }
        /// 真的滑了；要轉向的那一段真的轉了。
        func slid(_ segment: RegressionSegment, _ landing: RegressionLanding) -> Bool {
            landing.animated && (segment.turnAt == nil || landing.turned)
        }
        func slideNote(_ segment: RegressionSegment, _ landing: RegressionLanding) -> String {
            var note = ""
            if !landing.animated { note += " NOT ANIMATED" }
            if segment.turnAt != nil, !landing.turned { note += " NO TURN" }
            return note
        }
        let artifacts = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        /// 停著的真的框畫一張 PNG（量完才畫：畫圖本身不影響量到的數字）。
        func evidence(_ name: String) {
            guard let artifacts, let rep = canvas.host.bitmapImageRepForCachingDisplay(in: canvas.host.bounds) else { return }
            canvas.host.cacheDisplay(in: canvas.host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            let url = artifacts.appendingPathComponent(name)
            if (try? png.write(to: url)) != nil { print("W184FORMS NOTE evidence \(url.path)") }
        }

        // R1（第 4 條）：原本在最底 → 每一段停下都還在最底（≤1pt）：變矮、變高、中途轉向都算；停下那一刻與 0.15 秒後各量一次。
        let bottomTolerance = regressionBottomTolerance
        if let list = chatList() {
            for _ in 0..<6 where abs(regressionFromBottom(list)) > 0.5 {
                regressionScroll(list, fromTop: nil)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            let start = regressionFromBottom(list)
            var held = abs(start) <= bottomTolerance
            var notes = ["start \(regressionFormat(Double(start)))"]
            for segment in loop {
                var atStop: CGFloat?
                let landing = await land(segment) { atStop = regressionFromBottom(list) }
                let later = regressionFromBottom(list)
                let same = inPanel(list)
                let stopOK = atStop.map { abs($0) <= bottomTolerance } ?? false
                let laterOK = abs(later) <= bottomTolerance
                held = held && slid(segment, landing) && same && stopOK && laterOK
                let stopText = atStop.map { regressionFormat(Double($0)) } ?? "-"
                var note = "\(segment.label): stop \(stopText) later \(regressionFormat(Double(later)))"
                if !same { note += " ANOTHER LIST" }
                notes.append(note + slideNote(segment, landing))
            }
            print("W184FORMS NOTE R1 distance from the bottom (pt): \(notes.joined(separator: "; "))")
            evidence("r1-bottom-after-loop.png")
            check(held,
                  "R1 (F3T, GPT-6 F3 #4) bottom anchor on the real panel: a chat scrolled to its bottom is still at its bottom (≤1pt) the moment every segment stops and 0.15s later — outer portrait → inner landscape (shorter) → inner portrait (taller) → outer portrait (shorter), two mid-slide turns (desk.setForm again while sliding) and back",
                  notes.joined(separator: "; "))
        } else {
            check.skip("R1 最底錨點：找不到對話列表（這個環境畫不出來）")
        }

        // R5（查核加強 #1）反例：停著的時候畫布上留一個圖層台的 view（等於 rest() 只把 stage 設成 nil、view 沒拿掉：舊圖蓋在真的框上、
        // 點了沒反應）——停著的樣子一定要抓到（畫布上有圖層台的 view、框中央的點擊打到它，不在真的框底下）；拿掉之後又是收乾淨的。
        // 自測自己放一個 GlobalDMStageView（不動產品程式）：證明這一條檢查真的抓得到那種退步。
        let leftover = GlobalDMStageView(frame: canvas.bounds)
        leftover.autoresizingMask = [.width, .height]
        canvas.addSubview(leftover, positioned: .above, relativeTo: canvas.host)
        let withLeftover = settledState()
        leftover.removeFromSuperview()
        let withoutLeftover = settledState()
        check(!withLeftover.ok && withLeftover.detail.contains("stageViews=1") && withLeftover.detail.contains("centre → GlobalDMStageView")
                && withoutLeftover.ok,
              "R5 (F3T, GPT-6 F3 #5) counterexample: a layer-stage view left on the canvas after a stop (the stage set to nil, its view not removed) is caught by the settled check — the stage view is found and a click at the box centre lands on it — and the check is clean again once it is gone",
              "with the leftover: \(withLeftover.detail) | without: \(withoutLeftover.detail)")

        // R2 規則（W184 AB；GPT-6 審 G3c 第 4 條）：產品認定「在讀的那一則」＝頂列底下看得到的第一則（GlobalDMListRows.reading，純計算）。
        // 頂列蓋住 0..<68：只露一截、開頭那一行在頂列底下的不算；我說的泡泡上緣在頂列底下、字那一行整個露出來的算（第一行離上緣 9）；
        // 回答的開頭那一行在頂列底下就不算；沒有一則從頂列下面開始（一則長的佔滿）＝跨過頂列下緣的那一則。
        // 只看現在畫面上的：捲過以後沒再量的列（捲出去不畫，遮罩不重算）位置是舊的，不算（j-int 073855：一則早就捲走的串流列留著舊位置
        // 80.8，被當成在讀的那一則）。換形態時的差距：它自己這一輪量過就用它；沒量到用這一輪量過、離它最近的那一則估；什麼都沒量到＝不動。
        do {
            typealias Row = GlobalDMListRows.Row
            let bar: CGFloat = 68, viewport: CGFloat = 574
            func row(_ top: CGFloat, _ bottom: CGFloat, lead: CGFloat = 0) -> Row { Row(top: top, bottom: bottom, lead: lead, offset: 0, fresh: true) }
            func pick(_ rows: [String: Row]) -> String { GlobalDMListRows.reading(rows, covered: bar, viewport: viewport)?.id ?? "nil" }
            let halfHidden = pick(["above": row(-60, -6), "under": row(12, 76, lead: 9), "below": row(94, 160)])
            let bubbleShows = pick(["edge": row(57, 121, lead: 9), "next": row(139, 200)])
            let answerCut = pick(["answer": row(60, 130), "next": row(148, 212, lead: 9)])
            let tall = pick(["tall": row(-300, 900), "gone": row(-420, -318, lead: 9)])
            func at(_ y: CGFloat, _ height: CGFloat, scrolled: CGFloat) -> (frame: CGRect, content: CGRect) {
                (CGRect(x: 0, y: y, width: 300, height: height), CGRect(x: 0, y: y + scrolled, width: 300, height: height))
            }
            let rows = GlobalDMListRows()
            for (id, y, lead) in [("old", CGFloat(80), CGFloat(0)), ("a", 100, 0), ("b", 160, 9)] {
                let place = at(y, 40, scrolled: id == "old" ? 900 : 2000)   // old：捲到 900 那時量的，之後捲到 2000 沒再量
                rows.record(id, frame: place.frame, content: place.content, lead: lead, covered: bar, viewport: viewport)
            }
            let staleSkipped = rows.reading?.id == "a" && rows.current["old"] == nil && rows.rows["old"] != nil
            let snapshot = rows.snapshot()
            let nothingYet = snapshot.map { rows.drift(from: $0) == nil } ?? false
            let movedB = at(190, 63, scrolled: 2000)
            rows.record("b", frame: movedB.frame, content: movedB.content, lead: 9, covered: bar, viewport: viewport)
            let estimated = snapshot.flatMap { rows.drift(from: $0) }
            let movedA = at(125, 63, scrolled: 2000)
            rows.record("a", frame: movedA.frame, content: movedA.content, lead: 0, covered: bar, viewport: viewport)
            let own = snapshot.flatMap { rows.drift(from: $0) }
            check(halfHidden == "below" && bubbleShows == "edge" && answerCut == "next" && tall == "tall" && staleSkipped
                    && snapshot?.id == "a" && snapshot?.top == 100 && snapshot?.tops["old"] == nil && nothingYet && estimated == 30 && own == 25,
                  "R2 rule (W184 AB, GPT-6 G3c #4): the message being read is the first one whose start shows below the top bar — not the one half-hidden under it (its first line under the bar), a user bubble whose text line shows counts, an answer whose first line is under the bar does not, one long message filling the view is itself the one, and a row last measured before a scroll (not redrawn since) is not on screen; after a layout its drift is its own when it was measured again, else the nearest re-measured one's, else none",
                  "picks \(halfHidden)/\(bubbleShows)/\(answerCut)/\(tall); stale row skipped \(staleSkipped); snapshot \(snapshot?.id ?? "-")@\(snapshot.map { regressionFormat(Double($0.top)) } ?? "-"); "
                  + "drift before any re-measure \(nothingYet ? "none" : "SOME"), estimated \(estimated.map { regressionFormat(Double($0)) } ?? "-"), own \(own.map { regressionFormat(Double($0)) } ?? "-")")
        }

        // R2（第 4 條；W184 AB 依 GPT-6 審 G3c 第 4 條改判定）：捲上去看舊訊息 → 每一段停下，使用者在讀的那一則位置不變（±20pt，同 H1）、
        // 不被拉到最底；停下那一刻與 0.15 秒後各看一次。
        // 「在讀的那一則」照畫面判斷：列表頂天以後（G3c）捲動區延伸到框的上緣、在頂列底下捲——使用者真正在讀的是頂列底下看得到的第一則，
        // 不是藏在頂列、漸淡底下只露一截的那一則。看得到的那一塊讀出每一則的開頭（「第 N 個問題／回答」，Vision），開頭那一行在頂列下緣
        // （DMPhone.headerHeight）以下的第一個就是它；每一段停下在畫面上找同一則，它離可見區頂端的位置上下差 ≤20pt。讀不到字＝不過（不是 skip）。
        // 不拿捲動位移本身比：外直、內橫左欄、內直的欄寬不同（466／400／626），上面那幾則重新換行，位移本來就會變。
        // 三組：(1) 原案例——固定捲到離最上面 200pt；(2) 另加——房 C 的對齊（由上往下讀到的第一則對齊成第一列、字在上緣 16pt＝頂列底下），
        // 頂列底下露出的是下一則，守的是它（守著頂列底下那一則的錨點，它重新換行就把下一則推走）；(3) 最底上面一點點（離最底 90pt）。
        let readingTolerance = regressionReadingTolerance
        var readingIndex = 0
        /// 讀畫面：捲動區看得到的那一塊（畫成 2 倍解析度、留一張 PNG），Vision 讀出的每一行（y＝離可見區頂端幾點，由上往下）。
        func readLines(_ list: NSScrollView, _ tag: String) -> [(text: String, y: CGFloat)] {
            readingIndex += 1
            let began = CACurrentMediaTime()
            let read = regressionReadLines(canvas.host, rect: canvas.host.convert(list.contentView.bounds, from: list.contentView))
            print("W193 R2 sample \(readingIndex) \(tag): screenshot/OCR \(regressionFormat((CACurrentMediaTime() - began) * 1000))ms, lines=\(read.lines.count)")
            if let artifacts, let png = read.png {
                try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
                try? png.write(to: artifacts.appendingPathComponent("r2-top-\(readingIndex)-\(tag).png"))
            }
            return read.lines
        }
        /// 由上往下第一則訊息的開頭（在不在頂列底下都算；房 C 的對齊用）。
        func readTop(_ list: NSScrollView, _ tag: String) -> (marker: String, y: CGFloat)? {
            regressionFirstMarker(readLines(list, tag))
        }
        /// 看得到的每一則的開頭（由上往下）。
        func readMarkers(_ list: NSScrollView, _ tag: String) -> [(marker: String, y: CGFloat)] {
            regressionMarkers(readLines(list, tag))
        }
        func topText(_ top: (marker: String, y: CGFloat)?) -> String {
            top.map { "\($0.marker)@\(regressionFormat(Double($0.y)))" } ?? "unread"
        }
        func fmt(_ value: CGFloat) -> String { regressionFormat(Double(value)) }
        if let list = chatList() {
            /// 頂列蓋住的那一段（列表延伸到框的上緣，G3c）：開頭那一行在這條線以下＝頂列底下看得到。
            // W194：viewport 已避開頂列，OCR 的 y=0 是頂列下面；不能再扣一次 68pt。
            let viewportRect = list.convert(list.contentView.bounds, from: list.contentView)
            let hostRect = canvas.host.convert(viewportRect, from: list)
            let viewportTop = canvas.host.isFlipped ? hostRect.minY : canvas.host.bounds.height - hostRect.maxY
            let covered = max(0, DMPhone.headerHeight - viewportTop)
            /// 捲動區的樣子（內容高、看得到的高、離最上面、離最底）。
            func metrics(_ tag: String) -> String {
                let doc = list.documentView?.frame.height ?? -1
                return "\(tag) doc \(fmt(doc)) vis \(fmt(list.contentView.bounds.height)) top \(fmt(regressionFromTop(list))) bottom \(fmt(regressionFromBottom(list)))"
            }
            /// 頂列底下看得到的第一則：開頭那一行在頂列下緣以下的第一個。
            func firstBelow(_ markers: [(marker: String, y: CGFloat)]) -> (marker: String, y: CGFloat)? {
                markers.first { $0.y >= covered }
            }
            /// 產品記下的在讀的那一則（GlobalDMListRows；只寫進說明，判定看畫面）：哪一則、它的上緣、它的開頭在畫面上讀到的位置。
            func productReading(_ markers: [(marker: String, y: CGFloat)]) -> String {
                guard let reading = GlobalDMListRows.of(list)?.reading else { return "product reads nothing" }
                guard let engine = model.localLiveForBridge, let assistant = engine.doc.assistantThreadID,
                      let message = engine.transcript(for: assistant).first(where: { $0.id == reading.id }),
                      let marker = regressionFirstMarker([(text: message.text, y: 0)])?.marker else {
                    return "product reads \(reading.id) (row top \(fmt(reading.top)))"
                }
                let seen = markers.first { $0.marker == marker }.map { ", its start read at \(fmt($0.y))" } ?? ", its start not read"
                return "product reads \(marker) (row top \(fmt(reading.top))\(seen))"
            }
            /// 一段：換形態，停下那一刻與 0.15 秒後在畫面上找 anchor 那一則（起點頂列底下看得到的第一則）——同一則、離可見區頂端上下差 ≤20pt，
            /// 而且沒被拉到最底（離最底 >20pt）。回傳（守住、說明：停下／之後讀到的位置、之後頂列底下第一則、setForm 回來那一刻捲動區的樣子、
            /// 產品怎麼守的）。
            func judge(_ segment: RegressionSegment, _ anchor: (marker: String, y: CGFloat)) async -> (held: Bool, note: String, moved: CGFloat?) {
                canvas.readingTrace = []
                let began = CACurrentMediaTime()
                var stoppedAt = began
                var afterStart = ""
                var atStop: (markers: [(marker: String, y: CGFloat)], bottom: CGFloat)?
                let landing = await land(segment, afterStart: { afterStart = metrics("after setForm") }) {
                    stoppedAt = CACurrentMediaTime()
                    atStop = (readMarkers(list, "stop"), regressionFromBottom(list))
                }
                let laterAt = CACurrentMediaTime()
                let later = readMarkers(list, "later")
                let bottom = regressionFromBottom(list)
                let same = inPanel(list)
                func found(_ markers: [(marker: String, y: CGFloat)]) -> CGFloat? { markers.first { $0.marker == anchor.marker }?.y }
                let stopY = atStop.flatMap { found($0.markers) }, laterY = found(later)
                let stopOK = stopY.map { abs($0 - anchor.y) <= readingTolerance } ?? false
                let laterOK = laterY.map { abs($0 - anchor.y) <= readingTolerance } ?? false
                let notPulled = (atStop?.bottom ?? 0) > readingTolerance && bottom > readingTolerance
                let held = slid(segment, landing) && same && stopOK && laterOK && notPulled
                func at(_ y: CGFloat?) -> String { y.map(fmt) ?? "NOT FOUND" }
                var note = "\(segment.label): \(anchor.marker) at \(at(stopY)) at the stop (bottom \(fmt(atStop?.bottom ?? -1))), "
                note += "\(at(laterY)) later (bottom \(fmt(bottom))), first below the bar later \(topText(firstBelow(later))) "
                note += "[\(afterStart); kept: \(canvas.readingTrace.isEmpty ? "-" : canvas.readingTrace.joined(separator: " / "))]"
                note += " [wall to stop \(regressionFormat((stoppedAt - began) * 1000))ms, later sample after \(regressionFormat((laterAt - stoppedAt) * 1000))ms]"
                if !same { note += " ANOTHER LIST" }
                // 跑了多遠（停下、之後較大的那一個；有一次沒找到＝nil）。
                let moved = stopY.flatMap { stop in laterY.map { max(abs(stop - anchor.y), abs($0 - anchor.y)) } }
                return (held, note + slideNote(segment, landing), moved)
            }

            // 首次中文 OCR 會同步佔住主執行緒（W193 實測 12.9s，之後約 0.4–0.6s）。先做一段不計分的閱讀位置轉換，
            // 讓冷初始化與排版走完；首次位置仍印出來供查核，再回外直、重設原案的 200pt 起點。原 R2 的門檻與時機不變。
            _ = await regressionScroll(list, fromTopRetrying: 200)
            let coldMarkers = readMarkers(list, "cold-probe-start")
            if let coldAnchor = firstBelow(coldMarkers) {
                let cold = await judge(RegressionSegment(to: .innerLandscape, label: "W193 unscored cold outer→land"), coldAnchor)
                print("W193 R2 unscored cold probe held=\(cold.held) moved=\(cold.moved.map(fmt) ?? "unread"): \(cold.note)")
            } else {
                _ = await land(RegressionSegment(to: .innerLandscape, label: "W193 unscored cold outer→land")) {}
                print("W193 R2 unscored cold probe: no message read; original scored checks still follow")
            }
            _ = await land(RegressionSegment(to: .outerPortrait, label: "W193 unscored return to outer")) {}

            // (1) 原案例：固定捲到離最上面 200pt（不對齊）。懶載入的列排好、內容高度變了就再捲一次（j-int 063110：捲到 200pt、等 120ms 後
            // 實際在 1086），最多 6 次；離 200pt 超過 2pt＝起點沒放好（不過）。
            let start = await regressionScroll(list, fromTopRetrying: 200)
            let startBottom = regressionFromBottom(list)
            let startMarkers = readMarkers(list, "start")
            var readingHeld = false
            var readingNotes: [String] = []
            if let anchor = firstBelow(startMarkers) {
                readingHeld = abs(start - 200) <= 2 && startBottom >= 400
                readingNotes.append("start: offset \(fmt(start)), \(fmt(startBottom))pt from the bottom; first message below the top bar \(topText(anchor)), "
                                    + "under the bar \(topText(startMarkers.last { $0.y < covered })); \(productReading(startMarkers))")
                for segment in loop {
                    let result = await judge(segment, anchor)
                    readingHeld = readingHeld && result.held
                    readingNotes.append(result.note)
                }
            } else {
                readingNotes.append("start: offset \(fmt(start)), NOTHING READ below the top bar (\(startMarkers.count) message starts read above it)")
            }
            print("W184FORMS NOTE R2 reading position: \(readingNotes.joined(separator: "; "))")
            check(readingHeld,
                  "R2 (F3T, GPT-6 F3 #4) reading old messages: scrolled up 200pt from the top (fixed, the original case), the message the user reads — the first one whose start shows below the top bar (GPT-6 G3c #4; not the one half-hidden under the bar) — is found on screen within ±20pt of where it was (as in H1) when every segment stops and 0.15s later, and the chat is never pulled to the bottom — the loop with the shorter segments and the mid-slide turns; judged from the screen (text read off the visible area; nothing read is a fail), not from the raw scroll offset that re-wrapping legitimately changes",
                  readingNotes.joined(separator: "; "))

            // (2) 另加（房 C 的對齊，W184 G3c）：捲到 200pt 後把由上往下讀到的第一則對齊成第一列（字在上緣 regressionFirstRowTop＝16pt，在頂列
            // 底下），頂列底下露出的是下一則——守的是它。舊的錨點（SwiftUI 留住捲動區最上面那一列）守的是頂列底下那一則：它換欄寬重新換行
            // （問題在內直一行、其他兩行；回答在內橫左欄多一行，一行約 23pt），下一則就被推走。
            /// 房 C 的對齊：捲到 200pt，把由上往下讀到的第一則對齊成第一列；回傳（對齊的那一則、頂列底下看得到的第一則、讀到的開頭）。
            /// 對不齊、那一則不在頂列底下、頂列底下讀不到＝reading 是 nil。
            func placeAligned(_ tag: String) async -> (under: (marker: String, y: CGFloat)?, reading: (marker: String, y: CGFloat)?,
                                                       markers: [(marker: String, y: CGFloat)]) {
                _ = await regressionScroll(list, fromTopRetrying: 200)
                guard let first = readTop(list, "\(tag)-probe"), let rows = GlobalDMListRows.of(list),
                      let engine = model.localLiveForBridge, let assistant = engine.doc.assistantThreadID,
                      let id = engine.transcript(for: assistant).first(where: {
                          regressionFirstMarker([(text: $0.text, y: 0)])?.marker == first.marker
                      })?.id else { return (nil, nil, []) }
                // 留同一則的下半段在 viewport：開頭被裁掉，使用者閱讀下一則。
                // 保留原來的 rewrap 反例與 ±20pt 門檻，但不再把文字放到頭像底下。
                for _ in 0..<3 {
                    guard let row = rows.current[id] else { break }
                    let lineTop = row.top + row.lead
                    if abs(lineTop + regressionFirstRowTop) <= 4 { break }
                    regressionScroll(list, fromTop: regressionFromTop(list) + lineTop + regressionFirstRowTop)
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                let markers = readMarkers(list, tag)
                guard let row = rows.current[id], row.top + row.lead <= -12, row.bottom > covered,
                      let reading = firstBelow(markers), reading.marker != first.marker else { return (first, nil, markers) }
                return ((first.marker, row.top + row.lead), reading, markers)
            }
            func placedText(_ placed: (under: (marker: String, y: CGFloat)?, reading: (marker: String, y: CGFloat)?,
                                       markers: [(marker: String, y: CGFloat)])) -> String {
                guard let under = placed.under, let reading = placed.reading else {
                    return "start: NOT PLACED — first message read \(topText(placed.under)) (want \(fmt(regressionFirstRowTop))±4 under the bar), "
                        + "first below the bar \(topText(firstBelow(placed.markers)))"
                }
                return "start: offset \(fmt(regressionFromTop(list))), \(under.marker) aligned under the top bar at \(fmt(under.y)); "
                    + "first message below the bar \(topText(reading)); \(productReading(placed.markers))"
            }
            let aligned = await placeAligned("aligned-start")
            var alignedHeld = false
            var alignedNotes = [placedText(aligned)]
            if let reading = aligned.reading {
                alignedHeld = regressionFromBottom(list) >= 400
                for segment in loop {
                    let result = await judge(segment, reading)
                    alignedHeld = alignedHeld && result.held
                    alignedNotes.append(result.note)
                }
            }
            print("W184FORMS NOTE R2 reading position (aligned, extra): \(alignedNotes.joined(separator: "; "))")
            check(alignedHeld,
                  "R2 (W184 AB, GPT-6 G3c #4; extra case, kept beside the original) reading old messages with the first row partly clipped above the viewport: the message the user reads is the next one, the first whose start is fully visible — it stays within ±20pt when every segment stops and 0.15s later and the chat is not pulled to the bottom (an anchor that keeps the half-hidden message under the bar lets the one below move with its re-wrapping)",
                  alignedNotes.joined(separator: "; "))
            // 反例（退步時會失敗）：關掉產品守住在讀的那一則（GlobalDMPanelCanvas.keepsReading，自測才有；退回只靠 AppKit／SwiftUI 自己留的
            // 位置——留住的是頂列底下那一則），同一組要抓得到：有一段頂列底下看得到的那一則跑掉超過 20pt（或整個不見）。
            GlobalDMPanelCanvas.keepsReading = false
            let bare = await placeAligned("counter-start")
            var caught = false
            var counterNotes = [placedText(bare)]
            if let reading = bare.reading {
                // 整圈跑完（停在外直：下一組從外直起）；有一段跑掉超過 20pt（或不見）就是抓到。
                for segment in loop {
                    let result = await judge(segment, reading)
                    counterNotes.append(result.note)
                    if let moved = result.moved, moved <= readingTolerance { continue }
                    caught = true
                }
            }
            GlobalDMPanelCanvas.keepsReading = true
            print("W184FORMS NOTE R2 counterexample (reading anchor off): \(counterNotes.joined(separator: "; "))")
            check(caught,
                  "R2 (W184 AB, GPT-6 G3c #4) counterexample: with the product's reading anchor switched off (the old behaviour — only what AppKit/SwiftUI keep, the half-hidden message under the top bar), the extra case catches it: in some segment the first message below the bar moves more than 20pt (or is gone)",
                  counterNotes.joined(separator: "; "))

            // (3) 最底上面一點點（查核加強 #5）：離最底 90pt（過了產品「算在最底」的 8pt 線）——變矮的兩段（外直→內橫、內直→外直）停下那一刻與
            // 0.15 秒後，頂列底下看得到的第一則還在（±20pt）、沒被拉到最底：那條線放寬到超過起點就會被拉到最底（上面離最上面 200pt 那兩組離最底
            // 有上千點，線放多寬都抓不到）。只驗變矮的：變高時捲動區本來就會被夾到最底（中間那段變高的只收尾）。起點不對齊（W184 AB：舊的做法
            // 把讀到的第一則對齊到頂端 2pt——G3c 以後那裡在頂列底下，對齊會捲過最底）；離最底落在 20–150pt 才算放好。
            let nearBottom = regressionNearBottom
            let nearSteps: [(judged: Bool, segment: RegressionSegment)] = [
                (true, RegressionSegment(to: .innerLandscape, label: "outer→land (shorter)")),
                (false, RegressionSegment(to: .innerPortrait, label: "land→innerP (taller, not judged)")),
                (true, RegressionSegment(to: .outerPortrait, label: "innerP→outer (shorter)")),
            ]
            /// 一組「最底上面一點點」（外直起）：變矮的兩段判定、中間變高的只收尾。讀不到字＝不過（不是 skip）。
            func nearBottomGroup(_ name: String) async -> (held: Bool, notes: [String]) {
                var held = true
                var notes: [String] = []
                for step in nearSteps {
                    guard step.judged else {
                        let landing = await land(step.segment) {}
                        held = held && slid(step.segment, landing)
                        notes.append(step.segment.label + slideNote(step.segment, landing))
                        continue
                    }
                    let nearStart = await regressionScroll(list, fromBottom: nearBottom)
                    let startMarkers = readMarkers(list, "near-start")
                    let startMetrics = metrics("start")
                    guard let nearAnchor = firstBelow(startMarkers) else {
                        held = false
                        notes.append("\(step.segment.label): NOTHING READ below the top bar at the start (\(fmt(nearStart))pt from the bottom; "
                                     + "\(startMarkers.count) message starts above it; \(startMetrics))")
                        _ = await land(step.segment) {}
                        continue
                    }
                    let result = await judge(step.segment, nearAnchor)
                    held = held && nearStart >= 20 && nearStart <= nearBottom + 60 && result.held
                    notes.append("start \(fmt(nearStart))pt from the bottom, first message below the top bar \(topText(nearAnchor)), "
                                 + "\(productReading(startMarkers)) [\(startMetrics)] → \(result.note)")
                }
                return (held, notes.map { "\(name): \($0)" })
            }
            // 兩種尾巴：(1) 前面幾項留下來的尾巴（H12 串流回覆那幾列；W184 AB 起它們帶讀得到的「第 1xx 個回答」，已經不在長）；
            // (2) 乾淨的尾巴（在最後接 8 則新的問答「第 25–32 個」：最底那一段是一般的問答）。
            let leftover = await nearBottomGroup("tail left by earlier checks")
            var cleanNotes: [String] = []
            var cleanHeld = false
            if let engine = model.localLiveForBridge, let assistant = engine.doc.assistantThreadID {
                let rows = (0..<16).map { index in
                    ChatMessage(id: "w184f3t-clean-\(index)", role: index % 2 == 0 ? .user : .assistant,
                                text: index % 2 == 0 ? "第 \(25 + index / 2) 個問題：換形態的時候這一則還在原來的位置嗎？"
                                    : "第 \(25 + index / 2) 個回答：在。換形態只換框的大小，捲動位置、草稿、輸入焦點都不動；欄寬變了文字會重新換行。")
                }
                engine.appendOfflineRows(threadID: assistant, rows: rows)
                // 自測的模型是 fixture（ChatPageModel 的 botCoreFixture 不接引擎的 onChange）：照正式的 onChange 通知畫面重畫，新列才進列表
                //（j-int 073855：沒通知，新列等到下一次換形態重畫才進來，列表照「有新訊息」捲到最底——那一段量的是新訊息進來，不是換形態；
                // 074819 等 3 秒也沒進來）。再捲到最底，看最後一則（第 32 個回答）畫出來了沒，最多 3 秒；之後再空 0.3 秒。
                model.objectWillChange.send()
                var arrived = false
                for _ in 0..<30 {
                    regressionScroll(list, fromTop: nil)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if GlobalDMListRows.of(list)?.current["w184f3t-clean-15"] != nil {
                        arrived = true
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if arrived {
                    let clean = await nearBottomGroup("clean tail")
                    cleanHeld = clean.held
                    cleanNotes = clean.notes
                } else {
                    cleanNotes = ["clean tail: the 16 new rows never showed up in the list (3s)"]
                }
            } else {
                cleanNotes = ["clean tail: no local engine to append to"]
            }
            let nearNotes = leftover.notes + cleanNotes
            print("W184FORMS NOTE R2 near the bottom: \(nearNotes.joined(separator: "; "))")
            check(leftover.held && cleanHeld,
                  "R2 (F3T, GPT-6 F3 #4) reading just above the bottom (90pt up, 20–150pt, past the 8pt 'at the bottom' line): on the two shorter segments (outer portrait → inner landscape, inner portrait → outer portrait) the first message whose start shows below the top bar stays within ±20pt when the segment stops and 0.15s later, and the chat is not pulled to the bottom — judged (never skipped; nothing read is a fail) with the tail the earlier checks left (the H12 streaming reply rows, no longer growing) and with a clean tail",
                  nearNotes.joined(separator: "; "))

            // R1（第 4 條；查核加強 #5）：離最底 4pt（在 8pt 線以內）＝算在最底——變矮的一段（外直→內橫）停下那一刻與 0.15 秒後拉回最底
            //（≤1pt），再變高回外直也還在最底：那條線收窄到 4pt 以下，差一點點就在最底的人換形態會看不到最新那幾則。
            // 捲不到離最底 4pt（列表自己貼回最底、懶載入的高度一直變）＝這一條量不到，照實 skip。
            let pinnedStart = await regressionScroll(list, fromBottom: regressionPinnedBottom)
            if pinnedStart > 1, pinnedStart <= 7 {
                var pinnedHeld = true
                var pinnedNotes = ["start \(regressionFormat(Double(pinnedStart)))pt from the bottom"]
                for segment in [RegressionSegment(to: .innerLandscape, label: "outer→land (shorter)"),
                                RegressionSegment(to: .outerPortrait, label: "land→outer (taller)")] {
                    var atStop: CGFloat?
                    let landing = await land(segment) { atStop = regressionFromBottom(list) }
                    let later = regressionFromBottom(list)
                    let same = inPanel(list)
                    let stopOK = atStop.map { abs($0) <= bottomTolerance } ?? false
                    pinnedHeld = pinnedHeld && slid(segment, landing) && same && stopOK && abs(later) <= bottomTolerance
                    let stopText = atStop.map { regressionFormat(Double($0)) } ?? "-"
                    pinnedNotes.append("\(segment.label): stop \(stopText) later \(regressionFormat(Double(later)))"
                                       + (same ? "" : " ANOTHER LIST") + slideNote(segment, landing))
                }
                print("W184FORMS NOTE R1 within 8pt of the bottom: \(pinnedNotes.joined(separator: "; "))")
                check(pinnedHeld,
                      "R1 (F3T, GPT-6 F3 #4) within 8pt of the bottom counts as at the bottom: a chat 4pt above its bottom is at its bottom (≤1pt) when the shorter segment (outer portrait → inner landscape) stops and 0.15s later, and still there after the taller way back",
                      pinnedNotes.joined(separator: "; "))
            } else {
                check.skip("R1 離最底 4pt：捲不到離最底 4pt（實際 \(regressionFormat(Double(pinnedStart)))pt：列表自己貼回最底或懶載入的高度一直變），量不到")
            }
            regressionScroll(list, fromTop: nil)
            try? await Task.sleep(nanoseconds: 80_000_000)
        } else {
            check.skip("R2 看舊訊息、最底上面一點點，R1 離最底 4pt：找不到對話列表（這個環境畫不出來）")
        }

        // R3（第 4 條）：輸入框組字中（setMarkedText 造出注音的組字狀態，選了其中兩個字）、底下是已確定的草稿 → 換形態（含中途轉向）
        // 停下後：first responder 還是同一個輸入框、marked range／marked 文字／已確定文字／選取範圍都沒變（停下那一刻與 0.15 秒後各看一次）。
        let committed = "W184F3T 已確定的草稿"
        let composingText = "ㄓㄨˋㄧㄣ"
        store.setDraft(committed, for: .assistant)
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let composer = DMBrowserPhoneAcceptance.views(NSTextView.self, in: canvas.host).first(where: { $0.string == committed }) {
            panel.makeFirstResponder(composer)
            composer.setSelectedRange(NSRange(location: ("W184F3T 已確定" as NSString).length, length: 0))
            composer.setMarkedText(composingText, selectedRange: NSRange(location: 1, length: 2),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
            let baseline = regressionComposing(composer, in: panel)
            try? await Task.sleep(nanoseconds: 100_000_000)
            let steady = regressionComposing(composer, in: panel)
            if baseline.responder, baseline.marked != nil, baseline.markedText == composingText, baseline.committed == committed {
                var held = steady == baseline
                var notes = ["baseline \(baseline.text)"]
                if steady != baseline { notes.append("CHANGED before any form change: \(steady.text)") }
                for segment in loop {
                    var atStop: RegressionComposing?
                    let landing = await land(segment) { atStop = regressionComposing(composer, in: panel) }
                    let later = regressionComposing(composer, in: panel)
                    let inTree = DMBrowserPhoneAcceptance.views(NSTextView.self, in: canvas.host).contains { $0 === composer }
                    let same = atStop == baseline && later == baseline && inTree
                    held = held && same && slid(segment, landing)
                    var note = "\(segment.label): "
                    if same {
                        note += "same"
                    } else {
                        note += "stop \(atStop?.text ?? "-") later \(later.text)"
                        if !inTree { note += " NOT IN THE BOX" }
                    }
                    notes.append(note + slideNote(segment, landing))
                }
                print("W184FORMS NOTE R3 composing: \(notes.joined(separator: "; "))")
                evidence("r3-composing-after-loop.png")
                check(held,
                      "R3 (F3T, GPT-6 F3 #4) composing: a composer holding IME marked text (setMarkedText, two characters selected) over a committed draft keeps first responder, the marked range and text, the committed text and the selection when every segment stops and 0.15s later, both mid-slide turns included",
                      notes.joined(separator: "; "))
            } else {
                check.skip("R3 組字中的輸入框：這個環境造不出組字狀態（\(baseline.text)）")
            }
            composer.unmarkText()
        } else {
            check.skip("R3 組字中的輸入框：找不到輸入框（這個環境畫不出來）")
        }
        store.setDraft("", for: .assistant)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // MARK: R4、R5（真的時鐘、真的螢幕更新）

        panels.formMotion.manualTime = false
        panels.formMotion.clock = { CACurrentMediaTime() }
        frames.attach(to: canvas)
        try? await Task.sleep(nanoseconds: 120_000_000)
        let linkRuns = frames.stamps.count >= 3
        let slack = regressionSettleSlack, turnSlack = regressionTurnSlack
        /// 真的時鐘跑一段：按下去（setForm 之前）開始量；每 2ms 看一次（主執行緒空下來），照 disturb 加干擾；停下那一刻看一次停著的樣子；
        /// until（有給的話）在停下之後 0.6 秒內等它成立並記下多久；再空 0.15 秒看一次。
        /// turn（查核加強 #2）：第一次 setForm 回來之後 turn.at 秒再按一次（動畫中轉向，走同一個入口）——從再按下去量到 setForm 回來、到之後的
        /// 第一格；轉向那一刻用 plan.end − elapsed 重算該停下的時間（跟產品的停下計時器同一個算法）。有轉向時，干擾等轉向之後才加。
        func realSlide(_ to: GlobalDMForm, _ disturb: RegressionDisturb, label: String, idle: Double = 0.06,
                       turn: (at: Double, to: GlobalDMForm)? = nil, until: (() -> Bool)? = nil) async -> RegressionRealRun {
            var result = RegressionRealRun()
            result.label = label
            result.turnPlanned = turn != nil
            frames.isPaused = false
            try? await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            frames.reset()
            let pressed = CACurrentMediaTime()   // 使用者按下去（入口之前）
            result.accepted = desk.setForm(to)
            let returned = CACurrentMediaTime()
            result.staged = canvas.stage != nil && panels.formMotion.isAnimating
            result.toStage = (returned - pressed) * 1000
            result.apply = panels.lastStartCost * 1000
            result.trace = panels.lastStartTrace.joined(separator: ", ") + String(format: " | old picture %.1fms", panels.lastPrepareCost * 1000)
            result.firstEnd = panels.formMotion.plan?.end ?? -1
            let remaining = (panels.formMotion.plan?.end ?? 0) - panels.formMotion.elapsed
            result.settleAt = returned + max(0, remaining)
            var disturbed = false, pausePending = false
            var home: NSRect?
            // 期限跟著該停下的時間走（轉向之後重算）：過了它 1.5 秒還在轉換＝收不掉。
            while panels.formMotion.isAnimating, CACurrentMediaTime() < result.settleAt + 1.5 {
                let now = CACurrentMediaTime()
                if let turn, !result.turned, now - returned >= turn.at {
                    result.turnPressed = CACurrentMediaTime()   // 使用者再按一次（入口之前）
                    result.turnAccepted = desk.setForm(turn.to)
                    result.turnReturned = CACurrentMediaTime()
                    result.turnStaged = canvas.stage != nil && panels.formMotion.isAnimating
                    result.turnToStage = (result.turnReturned - result.turnPressed) * 1000
                    result.turnApply = panels.lastStartCost * 1000
                    result.turnStart = panels.formMotion.plan?.segments.last?.start ?? -1
                    let end = panels.formMotion.plan?.end ?? 0
                    result.settleAt = result.turnReturned + max(0, end - panels.formMotion.elapsed)
                    continue
                }
                if !disturbed, turn == nil || result.turned {
                    switch disturb {
                    case .block(let at, let length) where now - returned >= at:
                        disturbed = true
                        regressionOccupyMainThread(length)
                        result.blockEnd = CACurrentMediaTime()
                    case .blockAcrossStop(let length) where now >= result.settleAt - length / 2:
                        disturbed = true
                        regressionOccupyMainThread(length)   // 橫跨該停下的時間：計時器一定晚到
                        result.blockEnd = CACurrentMediaTime()
                    case .linksStopped(let at) where now - returned >= at:
                        disturbed = true
                        home = panel.frame
                        panel.setFrameOrigin(regressionOffscreenOrigin())   // 綁在面板 view 上的 display link 沒有螢幕可跟
                        // 真的在所有螢幕之外：面板的框跟每一個螢幕都不相交（panel.screen 只印出來：系統怎麼回報沒螢幕的視窗不拿來判斷）。
                        result.offscreen = !NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
                        result.screenWhileOff = panel.screen == nil ? "nil" : "a screen"
                        result.movedAt = CACurrentMediaTime()
                        pausePending = true
                    default:
                        break
                    }
                }
                if pausePending, CACurrentMediaTime() - result.movedAt >= 0.12 {
                    // 移開 0.12 秒：記下自測的 link 在所有螢幕之外還收到幾格（移開後 40ms 起算；只印出來），再把它停掉（之後沒有任何一格回呼）。
                    pausePending = false
                    let movedAt = result.movedAt
                    result.framesOffscreen = frames.stamps.filter { $0 > movedAt + 0.04 }.count
                    frames.isPaused = true
                    result.pausedAt = CACurrentMediaTime()
                }
                if case .eventTracking = disturb {
                    regressionSpinEventTracking(0.002)
                } else {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            if !panels.formMotion.isAnimating {
                result.finishedAt = CACurrentMediaTime()
                let state = settledState()
                result.cleanAtStop = state.ok
                if !state.ok { result.detail = "at stop \(state.detail)" }
            } else {
                result.detail = "still animating \(regressionFormat((CACurrentMediaTime() - returned) * 1000))ms after the press"
            }
            if let home, !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) {
                // 產品沒把面板擺回來（收不掉）：自測自己放回去，後面的情境照樣跑（這一段照樣算沒收好：停下那一刻 placed＝false）。
                panel.setFrame(home, display: false)
                result.detail += " | the panel was still off every screen after the slide (put back by the self-test)"
            }
            if let until, let after = await regressionWait(0.6, until) { result.untilAfter = after }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let later = settledState()
            result.cleanLater = later.ok
            if !later.ok { result.detail += " | 0.15s later \(later.detail)" }
            let stamps = frames.stamps
            result.ticks = stamps.count
            if let first = stamps.first(where: { $0 >= returned }) { result.toFrame = (first - pressed) * 1000 }
            if result.turned, let first = stamps.first(where: { $0 >= result.turnReturned }) {
                result.turnToFrame = (first - result.turnPressed) * 1000
            }
            if result.pausedAt > 0 {
                let pausedAt = result.pausedAt
                result.ticksAfterPause = stamps.filter { $0 > pausedAt + 0.02 }.count
            }
            frames.isPaused = false
            return result
        }
        func line(_ slide: RegressionRealRun) -> String {
            var parts = ["\(slide.label): first frame \(regressionFormat(slide.toFrame))ms",
                         "stage up \(regressionFormat(slide.toStage))ms (applyForm \(regressionFormat(slide.apply))ms)"]
            if slide.turned {
                parts.append("turned \(regressionFormat(slide.turnStart * 1000))ms into the slide (first segment ends at \(regressionFormat(slide.firstEnd * 1000))ms): "
                             + "turn first frame \(regressionFormat(slide.turnToFrame))ms, stage up \(regressionFormat(slide.turnToStage))ms "
                             + "(applyForm \(regressionFormat(slide.turnApply))ms)")
            } else if slide.turnPlanned {
                parts.append("NO TURN (the slide ended before the second press)")
            }
            parts += ["ended \(regressionFormat(slide.late))ms after its end time", "\(slide.ticks) frames",
                      "clean \(slide.cleanAtStop)/\(slide.cleanLater)"]
            if slide.blockEnd > 0 { parts.append("block released \(regressionFormat((slide.blockEnd - slide.settleAt) * 1000))ms after the end time") }
            if slide.movedAt > 0 {
                parts.append("off every screen \(slide.offscreen) (panel.screen \(slide.screenWhileOff); link frames while off screen before the pause: \(slide.framesOffscreen))")
            }
            if slide.pausedAt > 0 { parts.append("frames after the pause \(slide.ticksAfterPause)") }
            if slide.untilAfter >= 0 { parts.append("code back \(regressionFormat(slide.untilAfter))ms after the stop") }
            var text = parts.joined(separator: ", ")
            if !slide.detail.isEmpty { text += " — \(slide.detail)" }
            return text
        }
        /// 一段平常的真的時鐘：真的滑了、停下準時（該停的時間之後 slack 內）而且兩次都收好。
        func onTime(_ slide: RegressionRealRun) -> Bool {
            slide.accepted && slide.staged && slide.finished && slide.late <= slack * 1000 && slide.cleanAtStop && slide.cleanLater
        }
        /// 真的時鐘的轉向（查核加強 #2）：兩次按都真的滑了、轉向在第一段該停下之前（動畫中）、停下比轉向那一刻重算的時間晚不超過
        /// regressionTurnSlack、兩次都收好。轉向至少在第 3×slack 秒（≥0.3 秒）：停下的計時器沒扣掉已經走的時間就晚這麼多——這一段抓得到它。
        func turnedOnTime(_ slide: RegressionRealRun) -> Bool {
            slide.accepted && slide.staged && slide.turnAccepted && slide.turnStaged && slide.turnStart >= turnSlack * 3 && slide.turnStart < slide.firstEnd
                && slide.finished && slide.late <= turnSlack * 1000 && slide.cleanAtStop && slide.cleanLater
        }

        // R4（第 5 條）：開始的成本——從使用者按下去（desk.setForm 之前）量到第一個看得到的畫面（圖層台蓋上去之後 display link 的第一格；
        // display link 沒在跑就用圖層台蓋上去的那一刻）。門檻的理由見 regressionStartBudget。
        // 查核加強 #4：每個方向（外直→內橫、內橫→內直、內直→外直）各量三次，取「那個方向」自己的中位數逐一比門檻——三個方向混在一起取中位數，
        // 只有一個方向慢（例如只有進內橫時多排一次版、同步建第二個 store）會被另外兩個蓋掉。另量三次真的時鐘的轉向（外直→內橫，開始後
        // 0.3 秒再按一次換內直）：從第二次按下去到之後的第一格，中位數比同一個門檻。
        let startIdle = regressionStartIdle
        let rounds = regressionStartRounds
        var plainRuns: [RegressionRealRun] = []
        for _ in 0..<rounds {
            let intoLandscape = await realSlide(.innerLandscape, .quiet, label: "outer→land", idle: startIdle)
            let intoPortrait = await realSlide(.innerPortrait, .quiet, label: "land→innerP", idle: startIdle)
            let intoOuter = await realSlide(.outerPortrait, .quiet, label: "innerP→outer", idle: startIdle)
            plainRuns += [intoLandscape, intoPortrait, intoOuter]
        }
        var turnRuns: [RegressionRealRun] = [], turnBacks: [RegressionRealRun] = []
        for _ in 0..<rounds {
            let turned = await realSlide(.innerLandscape, .quiet, label: "outer→land turned at 0.3s→innerP", idle: startIdle,
                                         turn: (at: regressionTurnAt, to: .innerPortrait))
            let turnBack = await realSlide(.outerPortrait, .quiet, label: "innerP→outer (back from the turn)")
            turnRuns.append(turned)
            turnBacks.append(turnBack)
        }
        for slide in plainRuns + turnRuns {
            // 查原因（只印）：按下去到 applyForm 開始（形態改之前拍舊的樣子、改形態）＝stage up − applyForm；applyForm 裡面的分段是累計毫秒。
            print("W184FORMS NOTE R4 \(line(slide)); before applyForm (old capture + form change) \(regressionFormat(slide.toStage - slide.apply))ms; applyForm trace [\(slide.trace)]")
        }
        if !linkRuns { print("W184FORMS NOTE R4 這個環境的 display link 沒有在跑（\(frames.stamps.count) 格）：第一個看得到的畫面改用圖層台蓋上去的那一刻") }
        func firstVisible(_ slide: RegressionRealRun) -> Double { linkRuns && slide.toFrame >= 0 ? slide.toFrame : slide.toStage }
        let perDirection = ["outer→land", "land→innerP", "innerP→outer"].map { label -> (label: String, median: Double, values: [Double]) in
            let values = plainRuns.filter { $0.label == label }.map { firstVisible($0) }
            return (label, regressionMedian(values), values)
        }
        let directionText = perDirection.map { "\($0.label) median \(regressionFormat($0.median))ms of \($0.values.map { regressionFormat($0) })" }
            .joined(separator: "; ")
        let allStaged = plainRuns.allSatisfy { $0.accepted && $0.staged }
        print("W184FORMS NOTE R4 start cost per direction (budget \(regressionFormat(regressionStartBudget))ms): \(directionText)")
        check(allStaged && perDirection.allSatisfy { $0.values.count == rounds && $0.median >= 0 && $0.median <= regressionStartBudget },
              "R4 (F3T, GPT-6 F3 #5) start cost measured from before the user's entry (desk.setForm) to the first visible frame (the first display-link frame after the layer stage is up): each direction on its own — outer→land, land→innerP, innerP→outer, three slides each — median ≤150ms",
              directionText + " — " + plainRuns.map { line($0) }.joined(separator: "; "))
        let turnFirsts = turnRuns.map { linkRuns && $0.turnToFrame >= 0 ? $0.turnToFrame : $0.turnToStage }
        let turnMedian = regressionMedian(turnFirsts)
        let turnText = "turn median \(regressionFormat(turnMedian))ms of \(turnFirsts.map { regressionFormat($0) })"
        print("W184FORMS NOTE R4 start cost of a real-clock turn (budget \(regressionFormat(regressionStartBudget))ms): \(turnText)")
        check(turnRuns.count == rounds && turnRuns.allSatisfy { $0.turnAccepted && $0.turnStaged } && turnMedian >= 0
                && turnMedian <= regressionStartBudget,
              "R4 (F3T, GPT-6 F3 #5) start cost of a real-clock turn: outer portrait → inner landscape, setForm again 0.3s in → inner portrait; from before the second setForm to the first display-link frame after it, median of three ≤150ms",
              turnText + " — " + turnRuns.map { line($0) }.joined(separator: "; "))
        for slide in plainRuns + turnRuns + turnBacks where !onTime(slide) { log.issues.append("R4 \(line(slide))") }
        log.segments += plainRuns.count + turnRuns.count + turnBacks.count

        // R5（第 5 條）：一定收得掉。
        // (a) 正式的停下計時器晚到：該停下的時間前 0.15 秒起把主執行緒佔住 0.3 秒——放開之後照樣馬上收好。
        let lateTimer = await realSlide(.innerLandscape, .blockAcrossStop(length: 0.3), label: "outer→land, main thread blocked 0.3s across the end time")
        // (a') 施工單的例子：動畫中段（開始後 0.15 秒）主執行緒被佔住 0.3 秒——照樣準時收好。
        let midBlock = await realSlide(.innerPortrait, .block(at: 0.15, length: 0.3), label: "land→innerP, main thread blocked 0.3s mid-slide")
        // (b) display link 全停（查核加強 #3）：開始後 0.15 秒面板移到所有螢幕之外（綁在面板 view 上的 link 沒有螢幕可跟）、自測自己的 link
        // 停掉，計時器照走——照樣準時收好、面板擺回原位。產品若自己加一條 link 來收尾，node 守護先擋（這一段不一定停得到那一條）。
        let stopped = await realSlide(.outerPortrait, .linksStopped(at: 0.15),
                                      label: "innerP→outer, panel off every screen and the self-test's display link paused at 0.15s")
        // (c) 整段 run loop 停在 event tracking 模式（選單開著、拖曳中）：停下的計時器照樣會響。
        let tracking = await realSlide(.innerLandscape, .eventTracking, label: "outer→land, run loop in event-tracking mode")
        let back = await realSlide(.outerPortrait, .quiet, label: "land→outer")
        // (e) 查核加強 #2：真的時鐘轉向（開始後 0.35 秒再按一次）＋主執行緒卡 0.3 秒、橫跨轉向之後重算的停下時間——放開之後照樣馬上收好。
        let blockedTurn = await realSlide(.innerLandscape, .blockAcrossStop(length: 0.3),
                                          label: "outer→land turned at 0.35s→innerP, main thread blocked 0.3s across the new end time",
                                          turn: (at: regressionBlockedTurnAt, to: .innerPortrait))
        let blockedBack = await realSlide(.outerPortrait, .quiet, label: "innerP→outer (back from the blocked turn)")
        for slide in [lateTimer, midBlock, stopped, tracking, back, blockedTurn, blockedBack] { print("W184FORMS NOTE R5 \(line(slide))") }
        for slide in [back, blockedBack] where !onTime(slide) { log.issues.append("R5 \(line(slide))") }
        log.segments += 2
        let lateCovered = lateTimer.blockEnd > lateTimer.settleAt   // 真的橫跨了該停下的時間
        let lateOK = lateTimer.accepted && lateTimer.staged && lateTimer.cleanAtStop && lateTimer.cleanLater && lateTimer.lateAfterRelease <= slack
        check(lateCovered && lateOK,
              "R5 (F3T, GPT-6 F3 #5) late settle timer: with the main thread blocked 0.3s across the end time, the overdue timer still ends the slide right after the block (≤0.25s) — not animating, stage gone, real box at opacity 1, mask released, pages shown, panel placed",
              line(lateTimer))
        let midOK = midBlock.accepted && midBlock.staged && midBlock.blockEnd > 0 && midBlock.cleanAtStop && midBlock.cleanLater
            && midBlock.lateAfterRelease <= slack
        check(midOK,
              "R5 (F3T, GPT-6 F3 #5) main thread blocked 0.3s mid-slide: the slide still ends on time (≤0.25s after its end) and clean",
              line(midBlock))
        // 移開之後 40ms 起到自測的 link 停掉之前，那條綁在畫布上的 link 一格都沒收到（F3T 在 mini 量到 0）＝綁在面板 view 上的 display link
        // 在所有螢幕之外真的停了：產品若用這種 link 收尾、計時器又壞了，這一段就收不掉（抓得到）。
        check(onTime(stopped) && stopped.offscreen && stopped.framesOffscreen == 0 && stopped.pausedAt > 0 && stopped.ticksAfterPause == 0,
              "R5 (F3T, GPT-6 F3 #5) display link stopped mid-slide: 0.15s in the panel is moved off every screen (a display link tied to its views gets no frame there — measured on the canvas) and the self-test's own link is paused (no frame callback after it) while the settle timer keeps going — the slide still ends on time and clean, the panel back in its place (no display link in the product's form files: tests/w184-forms.test.mjs)",
              line(stopped))
        check(onTime(tracking),
              "R5 (F3T, GPT-6 F3 #5) the run loop held in event-tracking mode (a menu or a drag) for the whole slide: the settle timer still fires, the slide ends on time and clean",
              line(tracking))
        check(turnRuns.count == rounds && turnRuns.allSatisfy { turnedOnTime($0) },
              "R5 (F3T, GPT-6 F3 #5) a real-clock turn mid-slide (setForm again 0.3s in): the stop time recomputed at the turn (plan.end − elapsed) is kept — every turned slide ends ≤0.1s after it and clean, at the stop and 0.15s later (a settle timer that forgets the time already gone is ≥0.3s late)",
              turnRuns.map { line($0) }.joined(separator: "; "))
        let blockedTurnOK = blockedTurn.accepted && blockedTurn.staged && blockedTurn.turnAccepted && blockedTurn.turnStaged
            && blockedTurn.turnStart >= turnSlack * 3 && blockedTurn.turnStart < blockedTurn.firstEnd && blockedTurn.blockEnd > blockedTurn.settleAt
            && blockedTurn.cleanAtStop && blockedTurn.cleanLater && blockedTurn.lateAfterRelease <= turnSlack
        check(blockedTurnOK,
              "R5 (F3T, GPT-6 F3 #5) a real-clock turn (setForm again 0.35s in) with the main thread blocked 0.3s across the new end time: the overdue timer ends the slide right after the block (≤0.1s) and clean",
              line(blockedTurn))

        // (d) 配對碼在畫面上：Browser 開著配對頁（假的）、［連線］卡片畫著配對碼（假碼）。平常的一段、計時器晚到、display link 全停、
        // 真的時鐘轉向（查核加強 #2、#3）：每一段停下之後碼都要畫回綁住的那一頁上（0.6 秒內）、視窗照樣不給擷取、轉換遮蔽關掉、遮蔽放掉、
        // 圖層台拆掉。
        let pairingKey = 97
        let pairing = DMBrowserPhoneAcceptance.EvidencePage("連上 TATWO（假配對頁・F3T）")
        browser.adoptPopup(pairing, key: pairingKey, purpose: .chatgptPairing, expectedHost: nil)
        card.card = .pairing(HandsConnectPairingView(displayCode: "F3T7", expiresAt: Date().addingTimeInterval(600), attemptsLeft: 5,
                                                     callbackHost: "chatgpt.com", pairingCode: "58213946", popup: true, surface: pairingKey))
        presenter.show()
        presenter.setCodeVisible(true)
        func codeBack() -> Bool {
            DMBrowserPhoneAcceptance.codeDrawn(in: panel) && !DMSecretCodeView.suppressed && WindowCaptureShield.shared.isShielding(panel)
                && pairing.view.window === panel && !pairing.view.isHiddenOrHasHiddenAncestor
        }
        let codeWait = await regressionWait(5) { codeBack() }
        if codeWait != nil {
            let codedFirst = await realSlide(.innerPortrait, .quiet, label: "code up: outer→innerP", until: codeBack)
            let codedLate = await realSlide(.outerPortrait, .blockAcrossStop(length: 0.3),
                                            label: "code up: innerP→outer, main thread blocked 0.3s across the end time", until: codeBack)
            let codedStopped = await realSlide(.innerPortrait, .linksStopped(at: 0.15),
                                               label: "code up: outer→innerP, panel off every screen and the self-test's display link paused at 0.15s",
                                               until: codeBack)
            let codedTurn = await realSlide(.outerPortrait, .quiet, label: "code up: innerP→outer turned at 0.3s→innerP",
                                            turn: (at: regressionTurnAt, to: .innerPortrait), until: codeBack)
            let coded = [codedFirst, codedLate, codedStopped, codedTurn]
            for slide in coded { print("W184FORMS NOTE R5 \(line(slide))") }
            let settled = coded.allSatisfy { slide in
                slide.accepted && slide.staged && slide.cleanAtStop && slide.cleanLater && slide.untilAfter >= 0 && slide.lateAfterRelease <= slack
            }
            let stoppedOK = codedStopped.offscreen && codedStopped.framesOffscreen == 0 && codedStopped.pausedAt > 0 && codedStopped.ticksAfterPause == 0
            check(settled && stoppedOK && turnedOnTime(codedTurn) && codeBack(),
                  "R5 (F3T, GPT-6 F3 #5) with a pairing code on screen: after a plain slide, a late settle timer (0.3s block across the end time), the display link stopped (panel off every screen, the self-test's link paused) and a real-clock turn (0.3s in, ≤0.1s after the recomputed end), each slide ends clean and the code is drawn again on its bound page within 0.6s, its window still shielded",
                  coded.map { line($0) }.joined(separator: "; "))
            let codedBack = await realSlide(.outerPortrait, .quiet, label: "code up: innerP→outer")
            print("W184FORMS NOTE R5 \(line(codedBack))")
            if !onTime(codedBack) { log.issues.append("R5 \(line(codedBack))") }
            log.segments += 1
        } else {
            print("W184FORMS NOTE R5 code: browsing=\(store.isBrowsing) tabs=\(browser.tabs.count) shown=\(presenter.isShown) onScreen=\(presenter.codeOnScreen) drawn=\(DMBrowserPhoneAcceptance.codeDrawn(in: panel)) suppressed=\(DMSecretCodeView.suppressed)")
            check.skip("R5 配對碼：這個環境畫不出配對碼（假配對頁與卡片 5 秒內沒出來）")
        }
        presenter.hide()
        card.card = nil
        browser.closeAll()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // R5（第 5 條）：上面每一段（R1–R3 的每一段、R4 的每一段與轉向、回到外直的那幾段）停下那一刻與 0.15 秒後都收好。
        print("W184FORMS NOTE R5 segments checked \(log.segments), not clean \(log.issues.count)")
        check(log.segments >= 4 && log.issues.isEmpty,
              "R5 (F3T, GPT-6 F3 #5) every segment above ends clean, at the stop and 0.15s later: not animating, the layer stage gone (no stage view left on the canvas, clicks at the box centre and on every composer reach the real box), the real box at opacity 1 and filling the panel, the native-page mask released (pages shown, placeholder fills restored), the pairing-code suppression off, the panel at its placed frame",
              "segments=\(log.segments) " + log.issues.prefix(4).joined(separator: " || "))
    }

    // MARK: - 小工具

    /// R3：輸入框的組字狀態（first responder、marked range 與文字、已確定的文字、選取範圍）。
    struct RegressionComposing: Equatable {
        var responder: Bool
        var marked: NSRange?
        var markedText: String
        var committed: String
        var selected: NSRange

        var text: String {
            "responder=\(responder) marked=\(marked.map { NSStringFromRange($0) } ?? "none") '\(markedText)' committed='\(committed)' selected=\(NSStringFromRange(selected))"
        }
    }

    @MainActor static func regressionComposing(_ composer: NSTextView, in window: NSWindow) -> RegressionComposing {
        let text = composer.string as NSString
        let range: NSRange? = composer.hasMarkedText() ? composer.markedRange() : nil
        var markedText = "", committedText = text as String
        if let range, range.location != NSNotFound, NSMaxRange(range) <= text.length {
            markedText = text.substring(with: range)
            committedText = text.replacingCharacters(in: range, with: "")
        }
        return RegressionComposing(responder: window.firstResponder === composer, marked: range, markedText: markedText,
                                   committed: committedText, selected: composer.selectedRange())
    }

    /// R2：把 view 的 rect 那一塊畫成 2 倍解析度的圖，用 Vision 讀出每一行字（y＝離 rect 頂端幾點，由上往下排）；回傳圖（寫 PNG 用）。
    @MainActor static func regressionReadLines(_ view: NSView, rect: NSRect) -> (lines: [(text: String, y: CGFloat)], png: Data?) {
        let scale: CGFloat = 2
        guard rect.width >= 1, rect.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return ([], nil) }
        rep.size = rect.size
        view.cacheDisplay(in: rect, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        guard let image = rep.cgImage else { return ([], png) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (text: String, y: CGFloat)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, (1 - observation.boundingBox.maxY) * rect.height)
        }
        return (lines.sorted { $0.y < $1.y }, png)
    }

    /// R2：由上往下第一則訊息的開頭（fixture 的訊息都以「第 N 個問題」「第 N 個回答」開頭）→（「N 問題／回答」、離頂端幾點）。
    static func regressionFirstMarker(_ lines: [(text: String, y: CGFloat)]) -> (marker: String, y: CGFloat)? {
        guard let pattern = try? NSRegularExpression(pattern: "第\\s*(\\d+)\\s*[個个]\\s*(問題|问题|回答)") else { return nil }
        for line in lines {
            let text = line.text as NSString
            guard let match = pattern.firstMatch(in: line.text, range: NSRange(location: 0, length: text.length)) else { continue }
            let kind = text.substring(with: match.range(at: 2)) == "回答" ? "回答" : "問題"
            return ("第\(text.substring(with: match.range(at: 1)))個\(kind)", line.y)
        }
        return nil
    }

    /// R2（W184 AB）：看得到的每一則訊息的開頭（由上往下；同一則讀到兩次只算第一次）→（「第 N 個問題／回答」、離頂端幾點）。
    static func regressionMarkers(_ lines: [(text: String, y: CGFloat)]) -> [(marker: String, y: CGFloat)] {
        var result: [(marker: String, y: CGFloat)] = []
        for line in lines {
            guard let marker = regressionFirstMarker([line]), !result.contains(where: { $0.marker == marker.marker }) else { continue }
            result.append(marker)
        }
        return result
    }

    /// 離最底多遠（點）：自己量，不用產品的 GlobalDMPanelCanvas.distanceFromBottom（產品那一條錯了，這裡照樣抓得到）。
    @MainActor static func regressionFromBottom(_ scroll: NSScrollView) -> CGFloat {
        let visible = scroll.contentView.bounds, height = scroll.documentView?.frame.height ?? 0
        return scroll.documentView?.isFlipped == true ? height - visible.maxY : visible.minY
    }

    /// 離最上面多遠（點）。
    @MainActor static func regressionFromTop(_ scroll: NSScrollView) -> CGFloat {
        let visible = scroll.contentView.bounds, height = scroll.documentView?.frame.height ?? 0
        return scroll.documentView?.isFlipped == true ? visible.minY : height - visible.maxY
    }

    /// 捲到離最上面 fromTop 點（nil＝捲到最底）。
    @MainActor static func regressionScroll(_ scroll: NSScrollView, fromTop: CGFloat?) {
        guard let document = scroll.documentView else { return }
        let visible = scroll.contentView.bounds, height = document.frame.height
        let y: CGFloat
        if let fromTop {
            y = document.isFlipped ? fromTop : height - visible.height - fromTop
        } else {
            y = document.isFlipped ? height - visible.height : 0
        }
        scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// R2（W184 AB）：捲到離最上面 fromTop 點（懶載入的列排好、高度變了就再對一次，最多 6 次、每次等 80ms）；回傳實際離最上面多遠。
    @MainActor static func regressionScroll(_ scroll: NSScrollView, fromTopRetrying fromTop: CGFloat) async -> CGFloat {
        for _ in 0..<6 {
            regressionScroll(scroll, fromTop: fromTop)
            try? await Task.sleep(nanoseconds: 80_000_000)
            if abs(regressionFromTop(scroll) - fromTop) <= 0.5 { break }
        }
        return regressionFromTop(scroll)
    }

    /// R2／R1（查核加強 #5）：捲到離最底 fromBottom 點（懶載入的列排好、高度變了就再對一次，最多 6 次、每次等 80ms）；回傳實際離最底多遠。
    @MainActor static func regressionScroll(_ scroll: NSScrollView, fromBottom: CGFloat) async -> CGFloat {
        for _ in 0..<6 {
            guard let document = scroll.documentView else { break }
            let visible = scroll.contentView.bounds, height = document.frame.height
            let y = document.isFlipped ? height - visible.height - fromBottom : fromBottom
            scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(nanoseconds: 80_000_000)
            if abs(regressionFromBottom(scroll) - fromBottom) <= 0.5 { break }
        }
        return regressionFromBottom(scroll)
    }

    /// R5 停著的樣子（查核加強 #1）：點擊到不到得了真的框——框中央與每一個看得到的輸入框中心（輸入框的 NSTextView 看得到的那一塊的中心），
    /// 從畫布打 hitTest（點用畫布 superview 的座標，同 AppKit 送滑鼠事件），打到的 view 要在 canvas.host 底下（host 自己也算）。
    /// 圖層台的 view（GlobalDMStageView：在整塊畫布上都回傳自己、mouseDown 是空的）或別的東西還蓋在框上就打不到。回傳（全部到得了、說明）。
    @MainActor static func regressionClicks(_ canvas: GlobalDMPanelCanvas, panel: NSWindow) -> (ok: Bool, detail: String) {
        guard let superview = canvas.superview else { return (false, "clicks: the canvas has no superview") }
        let host = canvas.host
        var points: [(name: String, point: NSPoint)] = [("centre", NSPoint(x: host.frame.midX, y: host.frame.midY))]
        let composers = DMBrowserPhoneAcceptance.views(ChatComposerTextView.ComposerNSTextView.self, in: host)
            .filter { $0.window === panel && !$0.isHiddenOrHasHiddenAncestor }
        for (index, composer) in composers.enumerated() {
            let visible = composer.visibleRect
            guard visible.width >= 1, visible.height >= 1 else { continue }
            points.append(("composer\(index)", canvas.convert(NSPoint(x: visible.midX, y: visible.midY), from: composer)))
        }
        var missed: [String] = []
        for (name, point) in points {
            let hit = canvas.hitTest(canvas.convert(point, to: superview))
            if hit.map({ $0.isDescendant(of: host) }) != true {
                missed.append("\(name) → \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
        }
        let text = "clicks reach the box \(points.count - missed.count)/\(points.count) (composers \(points.count - 1))"
        return (missed.isEmpty, missed.isEmpty ? text : text + ", missed: " + missed.joined(separator: ", "))
    }

    /// R5 display link 全停（查核加強 #3）：所有螢幕之外的一點（所有螢幕合起來的右上角再往外 4000pt）。
    @MainActor static func regressionOffscreenOrigin() -> NSPoint {
        let screens = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        guard !screens.isNull else { return NSPoint(x: 40_000, y: 40_000) }
        return NSPoint(x: screens.maxX + 4_000, y: screens.maxY + 4_000)
    }

    /// 等條件成立（每 5ms 看一次，主執行緒空下來）：成立就回傳花了多久（毫秒），逾時回 nil。
    @MainActor static func regressionWait(_ seconds: Double, _ condition: () -> Bool) async -> Double? {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            if condition() { return (CACurrentMediaTime() - start) * 1000 }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition() ? (CACurrentMediaTime() - start) * 1000 : nil
    }

    /// R5：主執行緒被佔住 seconds 秒（重的工作卡住主執行緒的樣子；這段時間計時器、display link 都輪不到）。
    @MainActor static func regressionOccupyMainThread(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// R5：run loop 在 event tracking 模式跑 seconds 秒（選單開著、拖曳中：只有 common 模式的計時器與來源會動）。
    @MainActor static func regressionSpinEventTracking(_ seconds: Double) {
        _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(seconds))
    }

    static func regressionMedian(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -1 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func regressionFormat(_ value: Double) -> String { String(format: "%.1f", value) }

    static func regressionNear(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// W184 F3T 自測：主執行緒的 display link 每一格記一個時間；可以停掉（R5：display link 停了，停下的計時器照走）。
@MainActor final class GlobalDMRegressionFrameLog: NSObject {
    private(set) var stamps: [CFTimeInterval] = []
    private var link: CADisplayLink?

    func attach(to view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) { stamps.append(CACurrentMediaTime()) }

    func reset() { stamps = [] }

    var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    func detach() {
        link?.invalidate()
        link = nil
    }
}
#endif
