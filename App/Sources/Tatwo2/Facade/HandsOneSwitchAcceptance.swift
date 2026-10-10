#if DEBUG
import AppKit
import Foundation

/// W183 R6a（一個開關；docs/specs/183-chatgpt-hands/one-switch.md）的自測，掛在 `TATWO2_SELFTEST=w183ui` 底下（HandsUIAcceptance.run 叫）。
/// 只用假 cloudflared（Node，走真的看門程式＋sandbox-exec）、記憶體假鑰匙圈、假 Cloudflare API（跟假 cloudflared 同一份 dns.json）、
/// 假關口狀態；不開通道、不上網、不碰真的鑰匙圈。連線那一段（HandsConnectFlow）是 R6b 的：這裡只驗「什麼時候叫 offer／cancel」。
/// - 一列＋詳細收起、狀態只有規格那幾種字、「出錯」都有一顆鈕；
/// - 主設備開關直接走授權（私訊框開授權頁，不導去環境登入）；走到配對叫 offer、不開配對窗口；關開關叫 cancel；
/// - 主機 App 重開、開關開著：自動續跑只到通道、關口、既有 grant（不開授權頁、不 offer、不叫「重試」；安全停機的鎖不解除，重開 App 也一樣）；
/// - 固定子網域：新建、撞名停下（在 HandsUIAcceptance.errorFlowChecks）、隨機→固定遷移只刪自己那一筆（而且是指向這條通道的 CNAME）；
/// - 交回主機（開關關著也可以）、換主機要確認（而且會取消連線）、模式變了會開始同步、設定頁看得到時退避最多 10 秒、
///   副設備按的開關走到連線那一步會在這台 offer；沒用到的通道只列符合條件的、刪之前再查一次、只刪勾的。
/// W183 R6a 審查（GPT-6／Claude 十七條）：每一條都有對應的自測（標籤「W183 R6a 審查 …」）。
extension HandsUIAcceptance {
    // MARK: - 狀態字（純判斷）

    @MainActor static func oneSwitchStatusChecks(_ check: Checker) {
        let allowed: (String) -> Bool = { text in
            [HandsOneSwitchStatus.offText, HandsOneSwitchStatus.preparingText, HandsOneSwitchStatus.waitingText,
             HandsOneSwitchStatus.waitingHereText, HandsOneSwitchStatus.connectingText].contains(text)
                || text.hasPrefix("已連線・L") || text.hasPrefix("出錯：")
        }
        func steps(_ done: [HandsSetupStep], _ extra: [HandsSetupStep: HandsSetupStepState] = [:]) -> HandsSetupState {
            var state = HandsSetupState()
            for step in done { state.steps[step.rawValue] = HandsSetupStepState(status: .done) }
            for (step, entry) in extra { state.steps[step.rawValue] = entry }
            return state
        }
        let ready: [HandsSetupStep] = [.host, .cloudflared, .authorize, .tunnel, .start, .url, .remember]
        func local(enabled: Bool = true, busy: Bool = false, setup: HandsSetupState, login: Bool = false, blocked: String? = nil,
                   phase: ChatGPTHandsService.Phase = .running(url: "https://os-for-chatgpt.example.com/mcp"), grants: Int = 0,
                   connect: HandsConnectionPhase = .idle, problem: String? = nil, handback: String? = nil) -> HandsOneSwitchStatus {
            HandsOneSwitchStatus.forLocal(.init(enabled: enabled, level: 1, busy: busy, setup: setup, loginOpen: login, blocked: blocked, phase: phase,
                                             activeGrants: grants, connect: connect, connectProblem: problem, handback: handback))
        }
        var unconfirmed = steps([.host, .cloudflared], [.authorize: .init(status: .waitingUser, message: HandsSetup.confirmWaitingMessage)])
        unconfirmed.zoneID = "z"
        unconfirmed.unconfirmedZoneIDs = ["z"]
        let cases: [(HandsOneSwitchStatus, HandsOneSwitchStatus, String)] = [
            (local(enabled: false, setup: HandsSetupState()), .off, "關著"),
            (local(busy: true, setup: steps([.host])), .preparing, "跑到一半（不顯示第 N 步）"),
            (local(busy: true, setup: steps([.host, .cloudflared], [.authorize: .init(status: .waitingUser)]), login: true), .waiting(.login), "授權頁開在私訊框"),
            (local(setup: unconfirmed), .waiting(.confirm), "授權後確認帳號與網域"),
            (local(setup: steps([.host, .cloudflared], [.authorize: .init(status: .waitingUser, message: HandsSetup.resumeNeedsLoginMessage)])),
             .failed(HandsOneSwitchStatus.needsLoginText, .reauthorize), "自動續跑遇到沒授權＝重新授權"),
            (local(setup: steps([.host, .cloudflared, .authorize], [.tunnel: .init(status: .failed, message: HandsSetup.fixedHostTakenMessage("os-for-chatgpt.example.com"))])),
             .failed("os-for-chatgpt.example.com 已經有別的 DNS 紀錄", .retry), "出錯：一句話＋重試"),
            (local(setup: steps([.host, .cloudflared], [.authorize: .init(status: .failed, message: "等 Cloudflare 授權太久（10 分鐘）；按「重試」")])),
             .failed("等 Cloudflare 授權太久（10 分鐘）", .reauthorize), "授權失敗＝重新授權"),
            (local(setup: steps([.host], [.cloudflared: .init(status: .pending, message: HandsSetup.interruptedMessage)])), .preparing, "上次中斷＝準備中（會自動接著做）"),
            (local(setup: steps([.host], [.cloudflared: .init(status: .pending, message: "已取消；按「重試」再做")])), .failed(HandsOneSwitchStatus.cancelledText, .retry), "取消了"),
            (local(setup: steps(ready), phase: .failed(ChatGPTHandsService.tamperedText)), .failed(ChatGPTHandsService.tamperedText, .retry), "安全停機"),
            (local(setup: steps(ready), phase: .starting), .preparing, "關口啟動中"),
            (local(setup: steps(ready)), .waiting(.connect), "等你在私訊框按［連線］"),
            (local(setup: steps(ready), connect: .creatingConnector), .connecting, "建連接器中"),
            (local(setup: steps(ready), connect: .needsManual, problem: "找不到外掛頁的「＋」；網址已複製"), .failed("找不到外掛頁的「＋」", .reconnect), "自動做不到＝再連一次"),
            (local(setup: steps(ready), grants: 1), .connected(level: 1), "已連線・L1（既有 grant）"),
            (local(setup: steps(ready), grants: 1, connect: .verifying), .connecting, "授權完成、等第一次 /mcp"),
            (local(enabled: false, setup: HandsSetupState(), handback: "連不到主設備"), .failed("連不到主設備", .handBack), "交回主設備（開關關著）"),
            (local(setup: steps(ready), blocked: HandsSetup.leftoverMessage), .failed(HandsSetup.leftoverMessage, .retry), "被擋住"),
        ]
        let wrong = cases.filter { $0.0 != $0.1 }.map { "\($0.2)：\($0.0.text)" }
        check(wrong.isEmpty, "W183 R6a 狀態字：已關閉／準備中…／等你在私訊框按一下／連線中…／已連線・L1／出錯：一句話＋一顆鈕，不再寫「第 N 步」", "\(wrong)")
        check(cases.allSatisfy { allowed($0.0.text) && !$0.0.text.contains("第 ") && ($0.0.action != nil) == $0.0.text.hasPrefix("出錯：") },
              "W183 R6a 狀態字只有規格那幾種；「出錯」一定有一顆鈕（重試／重新授權／再連一次／交回主設備）")
        check(HandsOneSwitchStatus.Action.allCases.map(\.title) == ["重試", "重新授權", "再連一次", "交回主設備"]
              && HandsOneSwitchStatus.connected(level: 1).text == "已連線・L1" && HandsOneSwitchStatus.waiting(.connect).text == "等你在私訊框按一下",
              "W183 R6a 按鈕與字：重試／重新授權／再連一次／交回主設備；已連線・L1")
        check(HandsBuildPanel.resolve(chosen: nil, attention: nil) == .dev,
              "W183 R8a 舊的一列＋「詳細」拿掉：工程細節收進節點面板右上「…」，預設開節點面板")
        check(HandsOneSwitchStatus.shouldOffer(.waiting(.connect), connect: .idle) && !HandsOneSwitchStatus.shouldOffer(.waiting(.connect), connect: .waitingTap)
              && !HandsOneSwitchStatus.shouldOffer(.waiting(.login), connect: .idle) && !HandsOneSwitchStatus.shouldOffer(.connected(level: 1), connect: .idle),
              "W183 R6a 那一列只在「等［連線］、這一段還沒開始」時自動叫［連線］卡")

        // 副設備（看主機）：還沒拿到狀態＝準備中（不再卡「讀取主機狀態…」）、問不到＝出錯＋重試；其餘跟主機同一套字。
        func remote(_ object: [String: Any]?, pending: Bool? = nil, stale: Bool = false, problem: String? = nil,
                    connect: HandsConnectionPhase = .idle) -> HandsOneSwitchStatus {
            HandsOneSwitchStatus.forRemote(.init(status: object.flatMap { HandsRemoteStatus($0) }, pendingEnabled: pending, stale: stale, problem: problem,
                                              connect: connect, connectProblem: nil))
        }
        let allDone = HandsSetupStep.allCases.map { ["step": $0.rawValue, "status": $0 == .pairing ? "waiting_user" : "done"] }
        let running: [String: Any] = ["enabled": true, "phase": ["state": "running", "text": "運作中"], "setup": allDone, "level": 1]
        let remoteCases: [(HandsOneSwitchStatus, HandsOneSwitchStatus, String)] = [
            (remote(nil), .preparing, "還沒拿到主機狀態"),
            (remote(nil, problem: "連不到主設備（網路或主設備沒開）"), .failed(HandsOneSwitchStatus.unreachableText, .retry), "問不到"),
            (remote(["enabled": false, "phase": ["state": "stopped", "text": "已停止"]]), .off, "主機關著"),
            (remote(["enabled": false, "phase": ["state": "stopped", "text": "已停止"]], pending: true), .preparing, "按了、主機還沒回"),
            (remote(running), .waiting(.connect), "主機等［連線］"),
            (remote(running.merging(["grants": [["id": "g_1", "level": 1]]]) { $1 }), .connected(level: 1), "主機已連線"),
            (remote(running, stale: true), .failed(HandsOneSwitchStatus.unreachableText, .retry), "斷線"),
            (remote(["enabled": true, "phase": ["state": "stopped", "text": "x"], "setup_busy": true,
                     "login_url": loginLine("W183R6ASTATUS")]), .waiting(.login), "主機在等授權（授權頁在這台的私訊框）"),
            (remote(["enabled": true, "phase": ["state": "stopped", "text": "x"],
                     "setup": [["step": "host", "status": "done"], ["step": "cloudflared", "status": "done"],
                               ["step": "authorize", "status": "waiting_user", "code": "authorize.needs_login"]]]),
             .failed(HandsOneSwitchStatus.needsLoginText, .reauthorize), "主機沒授權＝重新授權"),
        ]
        let remoteWrong = remoteCases.filter { $0.0 != $0.1 }.map { "\($0.2)：\($0.0.text)" }
        check(remoteWrong.isEmpty && remoteCases.allSatisfy { allowed($0.0.text) },
              "W183 R6a 副設備同一套字（還沒拿到＝準備中、問不到＝出錯＋重試、主機等［連線］＝等你在私訊框按一下）", "\(remoteWrong)")
    }

    // MARK: - 開關的流程（主設備：直接授權、走到配對 offer、關掉 cancel）

    @MainActor static func oneSwitchFlowChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "one-switch", zoneName: "example.com")
        let jumps = JumpCounter()
        defer { jumps.stop() }
        // 1. 打開（沒有 Cloudflare 帳號）：直接在這台開授權頁（私訊框；自測記在 opened），不停在「先登入」、不導去環境登入。
        HandsOneSwitch.turnOn(setEnabled: { on in _ = try? world.service.updateSettings { $0.enabled = on } }, setup: world.setup)
        let opened = await waitUntil(25) { world.status(.authorize).status == .waitingUser && !world.opened.get().isEmpty }
        check(opened && world.opened.get().first?.host == "dash.cloudflare.com" && !world.status(.authorize).message.contains("環境登入")
              && jumps.count.get() == 0 && world.service.settings.load().enabled,
              "W183 R6a 主設備開關＝runAll(allowLogin: true)：沒登入 Cloudflare 就直接開授權頁（不導去環境登入、設定頁不換頁）", world.status(.authorize).message)
        world.flag("authorized", true)
        _ = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        // W183 R8c：登入只是登入——停在「選網域、按套用」＝那一列「等你在這裡按一下」；按「套用」才建網址。
        let confirming = HandsOneSwitchStatus.forLocal(localInput(world))
        _ = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .user)
        let reached = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
        let status = HandsOneSwitchStatus.forLocal(localInput(world))
        check(confirming == .waiting(.confirm) && reached && world.offers.get() == 1 && world.service.auth.windowExpiresAt == nil
              && world.service.auth.pendingCard == nil && status == .waiting(.connect)
              && world.setup.snapshot.publicHost == "os-for-chatgpt.example.com",
              "W183 R6a 走到配對：叫 HandsConnectFlow.offer 一次（私訊框的［連線］卡），不開配對窗口；那一列＝等你在私訊框按一下",
              "offers=\(world.offers.get()) window=\(String(describing: world.service.auth.windowExpiresAt)) \(status.text)")

        // 2. 主機 App 重開、開關開著：自動續跑只到通道、關口、既有 grant——不開授權頁、不 offer、不叫「重試」、不開配對窗口。
        world.phase.set(.stopped)
        let openedBefore = world.opened.get().count, startsBefore = world.starts.get(), offersBefore = world.offers.get()
        let reopened = HandsSetup(dependencies: world.setup.dependencies)
        let interrupted = reopened.snapshot.step(.pairing)
        let resumed = reopened.resumeIfEnabled()
        _ = await waitUntil(20) { !reopened.isBusy && reopened.snapshot.step(.pairing).status == .waitingUser }
        let runningAgain: Bool = { if case .running = world.phase.get() { return true }; return false }()
        check(interrupted.status == .pending && interrupted.message == HandsSetup.interruptedMessage && resumed && runningAgain
              && world.resumes.get() >= 1 && world.starts.get() == startsBefore && world.offers.get() == offersBefore
              && world.opened.get().count == openedBefore && world.service.auth.windowExpiresAt == nil
              && reopened.snapshot.step(.start).status == .done && reopened.snapshot.step(.tunnel).status == .done,
              "W183 R6a 重開續跑：開關開著就自動接著做（關口照設定起來），不開授權頁、不 offer、不叫「重試」、不開配對窗口",
              "resumes=\(world.resumes.get()) starts=\(world.starts.get())/\(startsBefore) offers=\(world.offers.get())/\(offersBefore)")

        // 3. 安全停機（socket 被動過）：自動續跑不解除（只叫關口照設定判斷）；使用者按「重試」才解除。
        world.phase.set(.failed(ChatGPTHandsService.tamperedText))
        let afterCrash = HandsSetup(dependencies: world.setup.dependencies)
        let startsBeforeTamper = world.starts.get()
        afterCrash.resumeIfEnabled()
        _ = await waitUntil(15) { !afterCrash.isBusy && afterCrash.snapshot.step(.start).status == .failed }
        let tamperStatus = HandsOneSwitchStatus.forLocal(localInput(world, setup: afterCrash))
        let stillFailed: Bool = { if case .failed = world.phase.get() { return true }; return false }()
        check(stillFailed && world.starts.get() == startsBeforeTamper && afterCrash.snapshot.step(.start).message == ChatGPTHandsService.tamperedText
              && tamperStatus.action == .retry && world.offers.get() == offersBefore,
              "W183 R6a 安全停機：重開後的自動續跑不解除（不叫「重試」、停在出錯＋重試）", tamperStatus.text)
        // 助理（AI）叫的也不解除（人工重試鎖）：照實回報，請使用者按「重試」。
        world.approve.set(true)
        let aiRetriesBefore = world.assistantRetries.get()
        afterCrash.run(.start, trigger: .assistant)
        _ = await waitUntil(15) { !afterCrash.isBusy }
        let stillLocked: Bool = { if case .failed = world.phase.get() { return true }; return false }()
        let aiRefused = afterCrash.snapshot.step(.start).status == .failed && world.starts.get() == startsBeforeTamper && stillLocked
            && world.assistantRetries.get() == aiRetriesBefore + 1
        check(aiRefused, "W183 R6a 安全停機：助理（AI）的 hands_setup_step 也不解除（叫的是保留安全鎖的重試），要使用者按", afterCrash.snapshot.step(.start).message)
        HandsOneSwitch.retry(setup: afterCrash)
        let retried = await waitUntil(20) { !afterCrash.isBusy && afterCrash.snapshot.step(.start).status == .done }
        check(retried && world.starts.get() == startsBeforeTamper + 1, "W183 R6a 安全停機：使用者按「重試」才解除（叫一次重試）")
        // W183 R6a 審查（Claude）：一般的關口失敗（例如一直停止）助理救得回來（保留安全鎖的重試），不用等使用者。
        world.phase.set(.failed("關口一直停止；請到設定按重試"))
        afterCrash.run(.start, trigger: .assistant)
        let aiRecovered = await waitUntil(15) { !afterCrash.isBusy && afterCrash.snapshot.step(.start).status == .done }
        check(aiRecovered && world.starts.get() == startsBeforeTamper + 1 && world.assistantRetries.get() == aiRetriesBefore + 2,
              "W183 R6a 審查 助理的重試：一般的關口失敗救得回來（不是安全停機）；安全停機的鎖照樣只有使用者的「重試」解除",
              afterCrash.snapshot.step(.start).message)

        // 4. 關開關：取消這次連線（HandsConnectFlow.cancel(reason: switched_off)）、撤銷全部、關口停。
        let cancelsBefore = world.connectCancels.get().count
        HandsOneSwitch.turnOff(setEnabled: { on in _ = try? world.service.updateSettings { $0.enabled = on } }, setup: afterCrash,
                               serviceChanged: { world.phase.set(.stopped) })
        _ = await waitUntil(5) { !afterCrash.isBusy }
        check(world.connectCancels.get().dropFirst(cancelsBefore).contains("switched_off") && !world.service.settings.load().enabled,
              "W183 R6a 關開關：叫 HandsConnectFlow.cancel(reason:)（這次連線作廢）、開關關掉", "\(world.connectCancels.get())")
        check(!afterCrash.resumeIfEnabled(), "W183 R6a 開關關著：不自動續跑")

        // 5. 自動續跑遇到沒有可用的 Cloudflare 授權：不自己開授權頁，停在「重新授權」。
        let empty = try World(fixture, folder: "one-switch-nologin", zoneName: "example.com")
        _ = try empty.service.updateSettings { $0.enabled = true; $0.hostDeviceID = fixture.primaryID }
        let started = empty.setup.resumeIfEnabled()
        _ = await waitUntil(15) { !empty.setup.isBusy && empty.status(.authorize).status == .waitingUser }
        let noLogin = HandsOneSwitchStatus.forLocal(localInput(empty))
        check(started && empty.opened.get().isEmpty && empty.status(.authorize).message == HandsSetup.resumeNeedsLoginMessage && empty.log("argv.log").isEmpty
              && noLogin == .failed(HandsOneSwitchStatus.needsLoginText, .reauthorize),
              "W183 R6a 重開續跑沒有授權：不開授權頁、不跑 cloudflared login；那一列＝出錯＋重新授權", noLogin.text)
        HandsOneSwitch.reauthorize(setup: empty.setup)
        let loginOpened = await waitUntil(25) { !empty.opened.get().isEmpty }
        empty.setup.cancel()
        _ = await waitUntil(15) { !empty.setup.isBusy }
        check(loginOpened, "W183 R6a 按「重新授權」：這下才開授權頁（私訊框）")

        // 6. W183 R6a 審查（GPT-6「換主機確認只擋 UI」）：後端只記下請求（不換）；使用者在卡片內按「確定」才換。請求一次性、綁世代與原主機；
        //    助理（hands_setup_step 帶 hostDeviceID）只能提出——工具回「要使用者按」、主機不動、連線不作廢。
        _ = await waitUntil(10) { !afterCrash.isBusy }
        let hostBefore = world.service.settings.load().hostDeviceID
        let cancelsBeforeHost = world.connectCancels.get().count
        var aiNeedsUser = false
        do { _ = try HandsSetupTool.handle(method: "hands_setup_step", params: ["step": "host", "hostDeviceID": fixture.secondaryID], setup: afterCrash) }
        catch { aiNeedsUser = String(describing: error).contains("hands_setup_needs_user") }
        _ = await waitUntil(5) { afterCrash.hostChangeRequest != nil }
        let aiRequest = afterCrash.hostChangeRequest
        let aiUnchanged = world.service.settings.load().hostDeviceID == hostBefore && world.connectCancels.get().count == cancelsBeforeHost
        let wrongToken = !afterCrash.confirmHostChange(token: "wrong-token")
        afterCrash.cancel()   // 取消（或關掉、App 重開）＝世代換掉：請求作廢
        _ = await waitUntil(5) { afterCrash.hostChangeRequest == nil }
        let staleRefused = !afterCrash.confirmHostChange(token: aiRequest?.token ?? "")
        check(aiNeedsUser && aiRequest?.byAssistant == true && aiRequest?.to == fixture.secondaryID && aiUnchanged && wrongToken && staleRefused
              && world.service.settings.load().hostDeviceID == hostBefore,
              "W183 R6a 換主機要確認：助理只能提出（工具回要使用者按、主機不動、連線不作廢）；確認碼不對、取消之後都不換",
              "needsUser=\(aiNeedsUser) request=\(String(describing: aiRequest)) unchanged=\(aiUnchanged)")
        // 使用者按的：一樣先記下，按「確定」才處理；W183 R8c：換成別台＝不換（每台自己跑自己的；要用那台＝在 ChatGPT build 勾那台），
        // 這次連線不作廢；同一張請求只能用一次；選這台（跟現在一樣）照常確認一次、不作廢。
        let choice = afterCrash.chooseHost(fixture.secondaryID, trigger: .user)
        _ = await waitUntil(5) { afterCrash.hostChangeRequest != nil }
        let userRequest = afterCrash.hostChangeRequest
        let pendingOnly = choice == .needsConfirmation && world.service.settings.load().hostDeviceID == hostBefore
        let confirmed = afterCrash.confirmHostChange(token: userRequest?.token ?? "")
        _ = await waitUntil(10) { !afterCrash.isBusy }
        let unchanged = world.service.settings.load().hostDeviceID == hostBefore
            && afterCrash.snapshot.step(.host).message == HandsSetup.otherDeviceRunsItselfMessage
        let once = !afterCrash.confirmHostChange(token: userRequest?.token ?? "")
        let same = afterCrash.chooseHost(fixture.primaryID, trigger: .user)
        _ = await waitUntil(10) { !afterCrash.isBusy }
        check(pendingOnly && confirmed && unchanged && once && same == .started && world.connectCancels.get().count == cancelsBeforeHost,
              "W183 R6a 換主機（換成別台）：第一下只記下來，按「確定」才處理——W183 R8c 不換（每台自己跑自己的）、這次連線不作廢；請求只能用一次；選同一台照常確認、不作廢",
              "\(world.connectCancels.get()) \(afterCrash.snapshot.step(.host).message)")
        // 請求提出之後主機被別的路換了（原主機不是提出時那一台）：按「確定」也不處理。
        _ = afterCrash.chooseHost(fixture.secondaryID, trigger: .user)
        _ = await waitUntil(5) { afterCrash.hostChangeRequest != nil }
        let movedRequest = afterCrash.hostChangeRequest
        _ = try world.service.updateSettings { $0.hostDeviceID = "33333333-3333-4333-8333-333333333333" }
        let movedRefused = !afterCrash.confirmHostChange(token: movedRequest?.token ?? "")
        _ = await waitUntil(5) { !afterCrash.isBusy }
        check(movedRefused && world.service.settings.load().hostDeviceID == "33333333-3333-4333-8333-333333333333",
              "W183 R6a 審查 換主機的請求綁原主機：提出之後主機被換過＝按「確定」也不換")
        _ = try world.service.updateSettings { $0.hostDeviceID = fixture.primaryID }
    }

    @MainActor static func localInput(_ world: World, setup: HandsSetup? = nil) -> HandsOneSwitchStatus.LocalInput {
        let flow = setup ?? world.setup
        let settings = world.service.settings.load()
        return .init(enabled: settings.enabled, level: settings.level, busy: flow.isBusy, setup: flow.snapshot, loginOpen: flow.pendingLoginURL != nil,
                     blocked: nil, phase: world.phase.get(), activeGrants: world.grant.get() ? 1 : 0, connect: .idle, connectProblem: nil, handback: nil)
    }

    // MARK: - W183 R6a 審查：自動續跑不換帳號與網域（GPT-6）、副設備重開後先問主設備（GPT-6 雙主機）

    @MainActor static func resumeBoundaryChecks(_ check: Checker, _ fixture: Fixture) async throws {
        // 原本確認過的帳號＋網域的授權不見了、環境登入還有另一個帳號：自動續跑停下（不換）；W183 R8c：使用者按的也不換（登入不等於選網址）。
        let world = try World(fixture, folder: "resume-account", zoneName: "example.com")
        _ = try world.service.updateSettings { $0.enabled = true }
        world.flag("authorized", true)
        world.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        try world.setup.chooseDomain(accountID: fixture.accountID, zoneID: fixture.zoneID)   // W183 R8c：使用者選網域
        world.setup.runAll(trigger: .user, allowLogin: false)   // 按「套用」
        _ = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
        let otherAccount = String(repeating: "b", count: 32), otherZone = String(repeating: "c", count: 32)
        let otherPEM = "-----BEGIN ARGO TUNNEL TOKEN-----\n" + Data("{\"zoneID\":\"\(otherZone)\",\"accountID\":\"\(otherAccount)\",\"apiToken\":\"\(fixture.canaryAPIToken)\"}".utf8)
            .base64EncodedString(options: [.lineLength64Characters]) + "\n-----END ARGO TUNNEL TOKEN-----\n"
        let otherDomain = "example.org"
        try world.accounts.upsert(accountID: otherAccount, name: "Other One", domain: CloudflareDomain(name: otherDomain, zoneID: otherZone), cert: otherPEM)
        try world.secrets.remove(service: CloudflareKeychain.certService, account: CloudflareAccountsStore.certAccount(fixture.zoneID))
        world.phase.set(.stopped)
        let reopened = HandsSetup(dependencies: world.setup.dependencies)
        reopened.resumeIfEnabled()
        _ = await waitUntil(20) { !reopened.isBusy && reopened.snapshot.step(.authorize).status != .done }
        _ = await waitUntil(20) { !reopened.isBusy }
        let resumed = reopened.snapshot
        check(resumed.accountID == fixture.accountID && resumed.zoneID == fixture.zoneID
              && resumed.step(.authorize).status == .waitingUser && resumed.step(.authorize).message == HandsSetup.resumeNeedsLoginMessage
              && world.opened.get().count == 1,
              "W183 R6a 審查 自動續跑只接受原本確認過的帳號與網域：授權不見了就停下（不換成環境登入裡的另一個、不開授權頁）",
              resumed.step(.authorize).message)
        reopened.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(20) { !reopened.isBusy }
        let substituted = reopened.snapshot
        check(substituted.zoneID == fixture.zoneID && !substituted.awaitingConfirmation && substituted.step(.authorize).status == .waitingUser
              && substituted.step(.authorize).message == HandsSetup.chooseDomainMessage && substituted.step(.tunnel).status != .running
              && world.opened.get().count == 1,
              "W183 R8c 使用者按的也一樣：不自己換用另一個帳號與網域（登入不等於選網址），停在「選網域、按套用」；不開授權頁、不建通道",
              substituted.step(.authorize).message)

        // W183 R8c：每台啟用許可（取代單主機租約）——許可暫停（太久連不到主設備）＝不起；沒勾這台＝不起（不自己關開關：明確關掉由 reconcile 撤銷）。
        let permit = HandsLocked<HandsBuildPermit.State>(.paused("expired"))
        let leaseWorld = try World(fixture, folder: "resume-lease", zoneName: "example.com", configure: { deps in
            deps.buildPermit = { _ in permit.get() }
            deps.buildSelectDefault = { _ in false }
        })
        _ = try leaseWorld.service.updateSettings { $0.enabled = true; $0.hostDeviceID = fixture.primaryID; $0.publicHost = "os-for-chatgpt.example.com" }
        let startsBefore = leaseWorld.starts.get(), resumesBefore = leaseWorld.resumes.get()
        leaseWorld.setup.resumeIfEnabled()
        _ = await waitUntil(15) { !leaseWorld.setup.isBusy && leaseWorld.status(.host).status == .failed }
        let unreachable = leaseWorld.status(.host).message == HandsSetup.leaseUnreachableMessage && leaseWorld.service.settings.load().enabled
            && leaseWorld.starts.get() == startsBefore && leaseWorld.resumes.get() == resumesBefore
        permit.set(.inactive(nil))
        leaseWorld.setup.resumeIfEnabled()
        _ = await waitUntil(15) { !leaseWorld.setup.isBusy && leaseWorld.status(.host).message == HandsSetup.notSelectedMessage }
        check(unreachable && leaseWorld.status(.host).message == HandsSetup.notSelectedMessage && leaseWorld.resumes.get() == resumesBefore,
              "W183 R8c 每台許可：暫停（太久連不到主設備）＝不起關口；沒勾這台＝不起（grant 由明確關掉那一刻撤銷）",
              leaseWorld.status(.host).message)
        let slice = HandsBuildDeviceSlice(deviceID: "22222222-2222-4222-8222-222222222222", name: "Fixture", active: true, subdomain: "os-for-chatgpt-fixture",
                                          hostname: nil, accountID: nil, zoneID: nil, domain: nil, level: 1, projectIDs: [], deviceRevision: 1,
                                          revocationGeneration: 0, connectorName: "TATWO（Fixture）")
        let body = HandsBuildEnvelopeBody(primaryID: fixture.primaryID, authorityEpoch: 1, targetDeviceID: slice.deviceID, configRevision: 3,
                                          deviceRevision: 1, revocationGeneration: 0, contentHash: slice.contentHash,
                                          issuedAt: Int(Date().timeIntervalSince1970), expiresAt: Int(Date().timeIntervalSince1970 + 60), content: slice)
        let clock = HandsLocked(Date())
        let accepted = HandsLocked<HandsBuildEnvelopeBody?>(nil)
        let member = HandsBuildPermit(dependencies: .init(role: { .member(local: slice.deviceID, primary: fixture.primaryID, epoch: 1) },
                                                          config: { nil }, accepted: { accepted.get() }, now: { clock.get() }))
        let none = !member.permits(slice.deviceID)
        accepted.set(body)
        let active = member.permits(slice.deviceID) && !member.permits("33333333-3333-4333-8333-333333333333")
        clock.set(Date().addingTimeInterval(120))
        let paused = member.state(slice.deviceID) == .paused("expired")
        check(none && active && paused,
              "W183 R8c 每台啟用許可：副設備沒收到主設備簽的信封＝不起；給這台、勾了、沒過期＝起；過期＝安全暫停")
    }

    // MARK: - 安全停機的鎖在磁碟上（ChatGPTHandsService：重開 App 也不解除，只有「重試」解除）

    static func safetyLockChecks(_ check: Checker, _ base: URL) throws {
        let root = base.appendingPathComponent("safety-lock", isDirectory: true)
        let paths = HandsGatewayLaunch.Paths(root: root)
        try HandsFiles.ensureDirectory(root)
        try HandsFiles.ensureDirectory(paths.appDir)
        try HandsFiles.writeAtomically(Data(#"{"enabled":true,"public_host":"os-for-chatgpt.example.com"}"#.utf8), to: paths.settingsFile)
        var deps = ChatGPTHandsService.Dependencies()
        deps.handsRoot = root
        deps.allowUnderTest = true
        deps.monitorInterval = 3600
        deps.cloudflared = { nil }   // 萬一鎖沒擋住也起不來（不開任何行程）
        deps.fetchRanges = { done in done(.failure(HandsWireError.disabled)) }
        ChatGPTHandsService.recordSafetyStop(paths)
        let first = ChatGPTHandsService(dependencies: deps)
        first.debugEvaluate()
        let afterRestart = ChatGPTHandsService(dependencies: deps)   // App 重開
        afterRestart.debugEvaluate()
        let locked = first.debugPhase == .failed(ChatGPTHandsService.tamperedText) && afterRestart.debugPhase == .failed(ChatGPTHandsService.tamperedText)
            && afterRestart.debugProcesses.gateway == nil
        afterRestart.settingsDidChange()   // 自動續跑叫的就是這個
        afterRestart.debugEvaluate()
        let stillLocked = ChatGPTHandsService.safetyStopped(paths) && afterRestart.debugPhase == .failed(ChatGPTHandsService.tamperedText)
        afterRestart.retry()
        afterRestart.debugEvaluate()
        let marker = (try? String(contentsOf: ChatGPTHandsService.safetyStopURL(paths), encoding: .utf8)) ?? ""
        check(locked && stillLocked && !ChatGPTHandsService.safetyStopped(paths) && marker.isEmpty,
              "W183 R6a 安全停機的人工重試鎖寫在磁碟（app/）：重開 App、自動續跑（settingsDidChange）都不解除，按「重試」才解除",
              "locked=\(locked) still=\(stillLocked) phase=\(afterRestart.debugPhase)")

        // W183 R6a 審查（GPT-6「人工重試鎖可能沒有保存」）：
        // ① 先鎖再停：預寫的那份改名成鎖（不用新空間）；助理的重試（retryKeepingSafetyLock）不解除。
        let armedURL = ChatGPTHandsService.safetyArmedURL(paths), stopURL = ChatGPTHandsService.safetyStopURL(paths)
        let armed = ChatGPTHandsService.armSafety(paths)
        let tamper = ChatGPTHandsService(dependencies: deps)
        tamper.debugSafetyStop()
        let renamed = armed && !FileManager.default.fileExists(atPath: armedURL.path) && FileManager.default.fileExists(atPath: stopURL.path)
        tamper.retryKeepingSafetyLock()
        tamper.debugEvaluate()
        let aiKept = ChatGPTHandsService.safetyStopped(paths) && tamper.debugPhase == .failed(ChatGPTHandsService.tamperedText)
        tamper.retry()
        tamper.debugEvaluate()
        check(renamed && aiKept && !ChatGPTHandsService.safetyStopped(paths),
              "W183 R6a 審查 安全停機先鎖再停：預寫的那份改名成鎖（磁碟滿也改得了名）；助理的重試不解除，使用者的「重試」才解除",
              "renamed=\(renamed) aiKept=\(aiKept)")
        // ② 用隔離目錄占住落點，確定改名與寫檔都失敗；原子寫入會重設父目錄權限，不能只靠 chmod。
        // 移除占位後才驗磁碟鎖，避免占位本身被當成鎖。
        _ = ChatGPTHandsService.armSafety(paths)
        try FileManager.default.createDirectory(at: stopURL, withIntermediateDirectories: false)
        let full = ChatGPTHandsService(dependencies: deps)
        full.debugSafetyStop()
        let fallbackReadOnly = (try FileManager.default.attributesOfItem(atPath: armedURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400
        try FileManager.default.removeItem(at: stopURL)
        full.debugEvaluate()
        let memoryLocked = full.debugPhase == .failed(ChatGPTHandsService.tamperedText)
        chmod(paths.appDir.path, 0o700)
        let restarted = ChatGPTHandsService(dependencies: deps)
        restarted.debugEvaluate()
        let diskLocked = ChatGPTHandsService.safetyStopped(paths) && restarted.debugPhase == .failed(ChatGPTHandsService.tamperedText)
            && !FileManager.default.fileExists(atPath: stopURL.path)
        restarted.retry()
        restarted.debugEvaluate()
        check(fallbackReadOnly && memoryLocked && diskLocked && !ChatGPTHandsService.safetyStopped(paths),
              "W183 R6a 審查 鎖寫不進去（資料夾不能寫、磁碟滿）：預寫的那份改成唯讀，重開 App 照樣鎖著；「重試」才解除",
              "memory=\(memoryLocked) disk=\(diskLocked) readOnly=\(fallbackReadOnly)")
        // ③ 讀標記出錯（權限）＝當成鎖著（fail closed），不當成沒鎖。④ App 當掉留下的預寫檔（可寫）不算鎖（當掉後照樣自動續跑）。
        chmod(paths.appDir.path, 0o000)
        let unreadable = ChatGPTHandsService.safetyState(paths)
        chmod(paths.appDir.path, 0o700)
        _ = ChatGPTHandsService.armSafety(paths)
        let crashLeftover = ChatGPTHandsService.safetyState(paths)
        ChatGPTHandsService.disarmSafety(paths)
        check(unreadable == .unreadable && crashLeftover == .clear && !FileManager.default.fileExists(atPath: armedURL.path),
              "W183 R6a 審查 讀標記出錯＝當成鎖著（fail closed）；App 當掉留下的預寫檔不算鎖、正常停下就拿掉", "\(unreadable) \(crashLeftover)")
        // ⑤ 副設備沒有主設備確認過的租約＝不起（不鎖：確認到了下一次定時檢查就起）。（預寫不進去＝不起：在 start() 起關口之前，
        //    自測環境沒有真的關口程式走不到那裡——node 契約測試核對順序。）
        var leased = deps
        leased.localDeviceID = { "22222222-2222-4222-8222-222222222222" }
        try HandsFiles.writeAtomically(Data(#"{"enabled":true,"public_host":"os-for-chatgpt.example.com","host_device_id":"22222222-2222-4222-8222-222222222222"}"#.utf8),
                                       to: paths.settingsFile)
        leased.hostConfirmed = { _ in false }
        let waiting = ChatGPTHandsService(dependencies: leased)
        waiting.debugEvaluate()
        let blocked = waiting.debugPhase == .stopped && waiting.debugProcesses.gateway == nil
        leased.hostConfirmed = { _ in true }
        let allowed = ChatGPTHandsService(dependencies: leased)
        allowed.debugEvaluate()
        let passedLease: Bool = { if case .failed = allowed.debugPhase { return true }; return false }()   // 過了租約，停在後面的檢查（沒有 cloudflared）
        check(blocked && passedLease, "W183 R6a 審查 副設備沒有主設備確認過的租約：關口不起（只看自己存的設備 id 不夠）", "\(waiting.debugPhase) \(allowed.debugPhase)")
    }

    // MARK: - 固定子網域：隨機→固定遷移只刪自己那一筆

    @MainActor static func fixedSubdomainChecks(_ check: Checker, _ fixture: Fixture) async throws {
        /// 以前的做法（隨機子網域 h＋19 字）跑到等配對：用設定的標籤扮演舊的名字（同一條 route dns 路），再把標籤改回預設＝固定的名字。
        func legacyWorld(_ folder: String) async throws -> (World, String) {
            let world = try World(fixture, folder: folder, zoneName: "example.com")
            let oldLabel = "h" + HandsSetup.randomLabel(19)
            _ = try world.service.updateSettings { $0.enabled = true; $0.subdomainLabel = oldLabel }
            world.flag("authorized", true)
            world.setup.runAll(trigger: .user, allowLogin: true)
            _ = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
            world.flag("authorized", false)
            _ = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .user)   // W183 R8c：登入只是登入；選網域、按「套用」
            _ = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
            _ = try world.service.updateSettings { $0.subdomainLabel = nil }
            return (world, oldLabel + ".example.com")
        }
        let tunnel = "0f0e0d0c-0b0a-4908-8706-050403020100"
        let (world, old) = try await legacyWorld("fixed-migrate")
        check(world.setup.snapshot.publicHost == old && world.service.settings.load().publicHost == old && world.dnsNames() == [old],
              "遷移前：主機用的是以前的隨機子網域（\(old.prefix(4))…）", "\(String(describing: world.setup.snapshot.publicHost))")
        // 別人的紀錄、另一筆也指向這條通道的隨機名字（不是狀態裡記的那筆）：都不能動。
        let stranger = "h" + HandsSetup.randomLabel(19) + ".example.com"
        world.putRecord("www.example.com", content: "example.org")
        world.putRecord(stranger, content: HandsCloudflared.tunnelTarget(tunnel))
        world.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !world.setup.isBusy && world.setup.snapshot.retiredHost == nil && world.setup.nextStep == .pairing }
        let state = world.setup.snapshot
        let names = world.dnsNames()
        let dnsCalls = world.log("argv.log").split(separator: "\n").filter { $0.contains(" dns ") }
        check(state.publicHost == "os-for-chatgpt.example.com" && world.service.settings.load().publicHost == "os-for-chatgpt.example.com"
              && world.phase.get() == .running(url: "https://os-for-chatgpt.example.com/mcp") && state.retiredHost == nil
              && names == ["os-for-chatgpt.example.com", stranger, "www.example.com"].sorted() && world.dnsDeletes.get().count == 1
              && dnsCalls.last?.hasSuffix(" os-for-chatgpt.example.com") == true,
              "W183 R6a 隨機→固定：先加新紀錄、確認是指向這條通道的 CNAME、改設定與網址（關口照新網址起來）、才刪狀態裡記的那一筆舊紀錄；別的紀錄一律不動",
              "\(names) deletes=\(world.dnsDeletes.get())")
        let log = (try? String(contentsOf: world.paths.root.appendingPathComponent("logs/setup-errors.log"), encoding: .utf8)) ?? ""
        check(world.dnsTokens.get().allSatisfy { $0 == fixture.canaryAPIToken } && !world.dnsTokens.get().isEmpty
              && !world.stateFiles().contains(fixture.canaryAPIToken) && !world.allFilesText().contains(fixture.canaryAPIToken)
              && !world.log("argv.log").contains(fixture.canaryAPIToken) && !log.contains(fixture.canaryAPIToken),
              "W183 R6a 刪紀錄用授權裡的 API token（只在記憶體）：不在狀態檔、日誌、argv、任何檔案")

        // 舊紀錄已經被改成指向別的地方（不是這條通道的 CNAME）：不刪、也不再試；新的照用。
        let (changedWorld, changedOld) = try await legacyWorld("fixed-notours")
        changedWorld.putRecord(changedOld, content: "somewhere-else.example.org")
        changedWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !changedWorld.setup.isBusy && changedWorld.setup.nextStep == .pairing }
        let changedLog = (try? String(contentsOf: changedWorld.paths.root.appendingPathComponent("logs/setup-errors.log"), encoding: .utf8)) ?? ""
        check(changedWorld.setup.snapshot.publicHost == "os-for-chatgpt.example.com" && changedWorld.dnsDeletes.get().isEmpty
              && changedWorld.dnsNames().contains(changedOld) && changedWorld.setup.snapshot.retiredHost == nil
              && changedLog.contains("dns.retire category=not_ours") && !changedLog.contains("somewhere"),
              "W183 R6a 舊紀錄不是指向這條通道的 CNAME（被改過）：不刪、不再試（錯誤只記分類）", changedLog)

        // 新紀錄確認不到（Cloudflare API 沒回）：不換過去、舊網址照用、舊紀錄不刪；之後重試才換、才刪。
        let (apiWorld, apiOld) = try await legacyWorld("fixed-api-down")
        apiWorld.dnsFailure.set("network")
        apiWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !apiWorld.setup.isBusy }
        let stayed = apiWorld.setup.snapshot.publicHost == apiOld && apiWorld.service.settings.load().publicHost == apiOld
            && apiWorld.status(.tunnel).status == .failed && apiWorld.status(.tunnel).message == HandsSetup.fixedHostUnconfirmedMessage
            && apiWorld.dnsNames().contains(apiOld) && apiWorld.dnsDeletes.get().isEmpty && apiWorld.setup.snapshot.retiredHost == nil
        apiWorld.dnsFailure.set(nil)
        apiWorld.dnsDeleteFailure.set("auth")   // 刪舊的沒權限：不擋流程，留著下次再試
        apiWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !apiWorld.setup.isBusy && apiWorld.setup.nextStep == .pairing }
        let kept = apiWorld.setup.snapshot.publicHost == "os-for-chatgpt.example.com" && apiWorld.setup.snapshot.retiredHost?.host == apiOld
            && apiWorld.dnsNames().contains(apiOld) && apiWorld.status(.url).status == .done
        apiWorld.dnsDeleteFailure.set(nil)
        apiWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !apiWorld.setup.isBusy && apiWorld.setup.snapshot.retiredHost == nil }
        check(stayed && kept && !apiWorld.dnsNames().contains(apiOld) && apiWorld.dnsDeletes.get().count == 1,
              "W183 R6a 遷移的退路：新紀錄確認不到＝不換、舊的不刪；刪舊的沒權限＝不擋流程、記著下次再試；再試就刪掉",
              "stayed=\(stayed) kept=\(kept) \(apiWorld.dnsNames())")

        // 這個授權不能讀 DNS 紀錄（Cloudflare 回 403）：以 cloudflared 的回覆為準換到固定網址；舊的那一筆確認不了就不刪（記著、錯誤只記分類）。
        let (authWorld, authOld) = try await legacyWorld("fixed-api-auth")
        authWorld.dnsFailure.set("auth")
        authWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !authWorld.setup.isBusy && authWorld.setup.nextStep == .pairing }
        let authLog = (try? String(contentsOf: authWorld.paths.root.appendingPathComponent("logs/setup-errors.log"), encoding: .utf8)) ?? ""
        check(authWorld.setup.snapshot.publicHost == "os-for-chatgpt.example.com" && authWorld.service.settings.load().publicHost == "os-for-chatgpt.example.com"
              && authWorld.dnsNames().contains(authOld) && authWorld.dnsDeletes.get().isEmpty && authWorld.setup.snapshot.retiredHost?.host == authOld
              && authLog.contains("dns.confirm category=auth_cloudflared_confirmed") && authLog.contains("dns.list category=auth"),
              "W183 R6a 授權不能讀 DNS（403）：以 cloudflared 的回覆為準換到固定網址；舊的確認不了就不刪（記著下次再試）", authLog)
        try await migrationReviewChecks(check, fixture, legacyWorld: legacyWorld)
        check(HandsSetup.isTatwoRandomHost("h" + String(repeating: "a", count: 19) + ".example.com", domain: "example.com")
              && !HandsSetup.isTatwoRandomHost("www.example.com", domain: "example.com")
              && !HandsSetup.isTatwoRandomHost("h" + String(repeating: "a", count: 19) + ".example.org", domain: "example.com")
              && !HandsSetup.isTatwoRandomHost("os-for-chatgpt.example.com", domain: "example.com")
              && HandsSettings().effectiveSubdomainLabel == "os-for-chatgpt" && HandsSettings.validLabel("-bad") == nil
              && HandsSettings.validLabel("Os-For-ChatGPT") == "os-for-chatgpt",
              "W183 R6a 只認 TATWO 自己的隨機格式（h＋19 字＋這個網域）；標籤預設 os-for-chatgpt、不合格的不收")
    }

    // MARK: - W183 R6a 審查：遷移的界線與刪舊紀錄的核對（Claude 高；GPT-6 高×3、中×2）

    @MainActor static func migrationReviewChecks(_ check: Checker, _ fixture: Fixture,
                                                legacyWorld: @MainActor (String) async throws -> (World, String)) async throws {
        let fixed = "os-for-chatgpt.example.com"
        // ① 自動續跑不遷移：以前的隨機網址照用（不加新紀錄、不刪舊的、不作廢連線），已連線照舊；已經連上時助理叫的也不遷移。
        let (world, old) = try await legacyWorld("review-resume")
        world.grant.set(true)
        world.phase.set(.stopped)
        let reopened = HandsSetup(dependencies: world.setup.dependencies)
        reopened.resumeIfEnabled()
        _ = await waitUntil(20) { !reopened.isBusy && reopened.snapshot.step(.start).status == .done }
        _ = await waitUntil(10) { !reopened.isBusy }
        let resumedStatus = HandsOneSwitchStatus.forLocal(localInput(world, setup: reopened))
        let resumeKept = reopened.snapshot.publicHost == old && world.service.settings.load().publicHost == old && world.dnsNames() == [old]
            && world.revokes.get().isEmpty && world.phase.get() == .running(url: "https://\(old)/mcp") && resumedStatus == .connected(level: 1)
        reopened.runAll(trigger: .assistant, allowLogin: true)
        _ = await waitUntil(20) { !reopened.isBusy }
        check(resumeKept && reopened.snapshot.publicHost == old && world.dnsNames() == [old] && world.revokes.get().isEmpty,
              "W183 R6a 審查 自動續跑（與已連上時助理叫的）不遷移：以前的隨機網址照用、不作廢連線，已連線照舊", resumedStatus.text)

        // ② 使用者按的遷移、已經連上：舊的連線作廢（連接器還指著舊網址）、那一列回到「等你在私訊框按一下」、叫一次［連線］卡；舊紀錄核對後才刪。
        let offersBefore = world.offers.get()
        reopened.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !reopened.isBusy && reopened.snapshot.retiredHost == nil && reopened.nextStep == .pairing }
        let migratedStatus = HandsOneSwitchStatus.forLocal(localInput(world, setup: reopened))
        check(reopened.snapshot.publicHost == fixed && world.revokes.get() == ["url_migrated"] && !world.grant.get()
              && reopened.snapshot.step(.tunnel).message == HandsSetup.migratedMessage(fixed) && world.offers.get() == offersBefore + 1
              && migratedStatus == .waiting(.connect) && !world.dnsNames().contains(old) && world.dnsNames().contains(fixed),
              "W183 R6a 審查 已經連上時遷移：舊的連線作廢、那一列回到等你在私訊框按一下（叫一次［連線］卡，不自動重連）；舊紀錄核對後才刪",
              "\(migratedStatus.text) \(world.revokes.get())")

        // ③ 新網址從外面確認不了（不是 TATWO 的關口、連不上）：舊紀錄不刪、記著；確認得了才刪。
        let (probeWorld, probeOld) = try await legacyWorld("review-probe")
        probeWorld.probeFailure.set("not_gateway")
        probeWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !probeWorld.setup.isBusy && probeWorld.setup.nextStep == .pairing }
        let probeLog = (try? String(contentsOf: probeWorld.paths.root.appendingPathComponent("logs/setup-errors.log"), encoding: .utf8)) ?? ""
        let probeKept = probeWorld.setup.snapshot.publicHost == fixed && probeWorld.dnsNames().contains(probeOld)
            && probeWorld.setup.snapshot.retiredHost?.host == probeOld && probeLog.contains("dns.probe category=not_gateway")
        probeWorld.probeFailure.set(nil)
        probeWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !probeWorld.setup.isBusy && probeWorld.setup.snapshot.retiredHost == nil }
        check(probeKept && !probeWorld.dnsNames().contains(probeOld),
              "W183 R6a 審查 刪舊紀錄之前從外面確認新網址（TLS、回的是 TATWO 的關口）：確認不了＝舊的留著、記著下次再試", probeLog)
        check(HandsCloudflared.gatewayVerdict(HTTPURLResponse(url: URL(string: "https://\(fixed)/x")!, statusCode: 403, httpVersion: nil,
                                                              headerFields: ["Content-Type": "text/plain; charset=utf-8"]), data: Data("forbidden".utf8), host: fixed) == nil
              && HandsCloudflared.gatewayVerdict(HTTPURLResponse(url: URL(string: "https://\(fixed)/x")!, statusCode: 403, httpVersion: nil,
                                                                 headerFields: ["Content-Type": "text/html"]), data: Data("<html>cloudflare</html>".utf8), host: fixed) == "not_gateway"
              && HandsCloudflared.gatewayVerdict(HTTPURLResponse(url: URL(string: "https://\(fixed)/x")!, statusCode: 530, httpVersion: nil,
                                                                 headerFields: ["Content-Type": "text/plain"]), data: Data("forbidden".utf8), host: fixed) == "not_gateway"
              && HandsCloudflared.gatewayVerdict(nil, data: nil, host: fixed) == "network",
              "W183 R6a 審查 新網址的外部確認只認 TATWO 關口的回應（403 純文字 forbidden）；Cloudflare 的錯誤頁、5xx、連不上都不算")

        // ④ 查驗之後、刪之前那一筆被改了（同一個 id、指向別處）：這一次不刪（刪之前再查一次）。
        let (raceWorld, raceOld) = try await legacyWorld("review-race")
        let raceLookups = HandsLocked(0)
        raceWorld.dnsHook.set { name in
            guard name == raceOld else { return }
            raceLookups.update { $0 += 1 }
            if raceLookups.get() == 2 { raceWorld.putRecord(raceOld, content: "elsewhere.example.org") }
        }
        raceWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !raceWorld.setup.isBusy && raceWorld.setup.nextStep == .pairing }
        raceWorld.dnsHook.set(nil)
        let raceLog = (try? String(contentsOf: raceWorld.paths.root.appendingPathComponent("logs/setup-errors.log"), encoding: .utf8)) ?? ""
        check(raceWorld.dnsDeletes.get().isEmpty && raceWorld.dnsNames().contains(raceOld) && raceLog.contains("dns.retire category=changed"),
              "W183 R6a 審查 刪之前再查一次：查驗之後那一筆被改了就不刪（Cloudflare 的刪除不能帶條件，只能縮短空窗）", raceLog)

        // ⑤ setup.json 被改（同一個使用者的程式）：記下的那一筆指向別的服務的通道——不是現在這條通道、或 Cloudflare 上不是 TATWO 建的＝不刪。
        let (tamperWorld, _) = try await legacyWorld("review-tamper")
        tamperWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !tamperWorld.setup.isBusy && tamperWorld.setup.snapshot.retiredHost == nil && tamperWorld.setup.nextStep == .pairing }
        let foreignTunnel = "abababab-abab-4bab-8bab-abababababab"
        let victim = "h" + HandsSetup.randomLabel(19) + ".example.com"
        tamperWorld.putRecord(victim, content: HandsCloudflared.tunnelTarget(foreignTunnel))
        func tamper(_ change: (inout [String: Any]) -> Void) throws -> HandsSetup {
            let url = tamperWorld.paths.appDir.appendingPathComponent("setup.json")
            var object = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
            change(&object)
            try HandsFiles.writeAtomically(try JSONSerialization.data(withJSONObject: object), to: url)
            return HandsSetup(dependencies: tamperWorld.setup.dependencies)
        }
        let zone = tamperWorld.setup.snapshot.zoneID ?? ""
        let notCurrent = try tamper { $0["retired_host"] = ["host": victim, "zone_id": zone, "tunnel_id": foreignTunnel] }
        notCurrent.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(30) { !notCurrent.isBusy && notCurrent.snapshot.retiredHost == nil }
        let keptA = tamperWorld.dnsNames().contains(victim) && tamperWorld.dnsDeletes.get().count == 1
        let foreignOwned = try tamper {
            $0["retired_host"] = ["host": victim, "zone_id": zone, "tunnel_id": foreignTunnel]
            $0["tunnel_id"] = foreignTunnel; $0["token_tunnel_id"] = foreignTunnel
        }
        foreignOwned.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(30) { !foreignOwned.isBusy && foreignOwned.snapshot.retiredHost == nil }
        let tamperLog = (try? String(contentsOf: tamperWorld.paths.root.appendingPathComponent("logs/setup-errors.log"), encoding: .utf8)) ?? ""
        check(keptA && tamperWorld.dnsNames().contains(victim) && tamperWorld.dnsDeletes.get().count == 1
              && tamperLog.contains("dns.retire category=not_current") && tamperLog.contains("dns.retire category=not_tatwo_tunnel"),
              "W183 R6a 審查 setup.json 被改成指向別的服務：不是現在這條通道、或 Cloudflare 上那條通道不是 TATWO 建的（名字）＝不刪", tamperLog)

        // ⑥ 新紀錄不是經過 Cloudflare 代理的（proxied false）：不換過去（外面連不到通道）。
        let (proxyWorld, proxyOld) = try await legacyWorld("review-proxied")
        proxyWorld.putRecord(fixed, content: HandsCloudflared.tunnelTarget("0f0e0d0c-0b0a-4908-8706-050403020100"), proxied: false)
        proxyWorld.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !proxyWorld.setup.isBusy }
        check(proxyWorld.setup.snapshot.publicHost == proxyOld && proxyWorld.status(.tunnel).message == HandsSetup.fixedHostUnconfirmedMessage
              && proxyWorld.dnsDeletes.get().isEmpty,
              "W183 R6a 審查 新紀錄要是經過 Cloudflare 代理的 CNAME：不是就不換過去（舊網址照用）", proxyWorld.status(.tunnel).message)

        // ⑦ 固定的名字指向這個帳號裡另一條 TATWO 通道（換主機時另一台建的）：照實說「指向另一條 TATWO 通道」（不覆蓋、不換名字）。
        let other = try World(fixture, folder: "review-other-device", zoneName: "example.com")
        let otherTunnel = "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd"
        other.putRecord(fixed, content: HandsCloudflared.tunnelTarget(otherTunnel))
        let otherName = HandsCloudflared.tatwoTunnelPrefix + "otherdevice"
        let otherRows: [[String: Any]] = [["id": otherTunnel, "name": otherName, "created_at": "2026-09-28T04:35:00Z", "connections": [Any]()]]
        try Data(text(otherRows).utf8).write(to: other.ctrl.appendingPathComponent("tunnels.json"))
        _ = try other.service.updateSettings { $0.enabled = true }
        other.flag("authorized", true)
        other.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !other.setup.isBusy && other.status(.authorize).message == HandsSetup.chooseDomainMessage }
        other.flag("authorized", false)
        _ = other.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .user)   // W183 R8c：登入只是登入；選網域、按「套用」
        _ = await waitUntil(40) { !other.setup.isBusy && other.status(.tunnel).status == .failed }
        check(other.status(.tunnel).message == HandsSetup.fixedHostOtherDeviceMessage(fixed) && other.setup.snapshot.publicHost == nil
              && other.dnsNames() == [fixed] && World.records(other.ctrl.appendingPathComponent("dns.json")).first?.content == HandsCloudflared.tunnelTarget(otherTunnel),
              "W183 R6a 審查 換主機撞到固定的名字（指向另一台的 TATWO 通道）：照實說是另一條 TATWO 通道，不覆蓋、不換名字",
              other.status(.tunnel).message)
    }

    // MARK: - 交回主設備（副設備當了主機；開關關著也可以）

    @MainActor static func handbackChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let release = HandsLocked<String?>("連不到主設備（網路或主設備沒開）")
        let calls = HandsLocked(0)
        let world = try World(fixture, folder: "handback", zoneName: "example.com", configure: { deps in
            deps.hostNeedsRelease = { true }   // 這台（副設備）登記是主機
            deps.releaseHost = { calls.update { $0 += 1 }; return release.get() }
            deps.serviceChanged = {}   // 關口停不停由自測自己設（驗「關口還沒停＝不交回」）
        })
        _ = try world.service.updateSettings { $0.enabled = true; $0.hostDeviceID = fixture.primaryID }
        HandsOneSwitch.turnOff(setEnabled: { on in _ = try? world.service.updateSettings { $0.enabled = on } }, setup: world.setup, serviceChanged: {})
        let failed = await waitUntil(10) { world.setup.handbackProblem != nil }
        let back = HandsOneSwitch.handback(problem: world.setup.handbackProblem, isSecondary: true, local: fixture.secondaryID,
                                                settings: world.service.settings.load(), hostStep: world.status(.host), busy: false)
        let status = HandsOneSwitchStatus.forLocal(.init(enabled: false, level: 1, busy: false, setup: world.setup.snapshot, loginOpen: false, blocked: nil,
                                                      phase: .stopped, activeGrants: 0, connect: .idle, connectProblem: nil, handback: back))
        check(failed && calls.get() == 1 && status.action == .handBack && world.status(.host).status == .failed,
              "W183 R6a 關開關＝交回主設備；交回不成功：那一列一句話＋「交回主設備」", status.text)
        release.set(nil)
        world.setup.handBack()   // 開關關著也可以按
        let cleared = await waitUntil(10) { world.setup.handbackProblem == nil && calls.get() == 2 }
        check(cleared, "W183 R6a 「交回主設備」：開關關著也能按；主設備收到就清掉")
        // 開關開著時按：先照關掉的順序停下這台（關開關、取消連線），再交回。
        _ = try world.service.updateSettings { $0.enabled = true }
        let cancelsBefore = world.connectCancels.get().count
        world.setup.handBack()
        let handed = await waitUntil(10) { calls.get() == 3 }
        check(handed && !world.service.settings.load().enabled && world.connectCancels.get().dropFirst(cancelsBefore).contains("host_changed"),
              "W183 R6a 開關開著按「交回主設備」：先關掉這台（連線作廢），再交回")

        // W183 R6a 審查（GPT-6「交回主機接受只在記憶體關閉」）：「關」存不進磁碟（只在記憶體強制關閉）＝不交回（重開會以為自己還是主機）；
        // 關口還沒停＝不交回。存得進去、停了才交回。
        _ = try world.service.updateSettings { $0.enabled = true }
        world.service.settings.failSavesForTesting = true
        world.setup.handBack()
        let notSaved = await waitUntil(10) { world.setup.handbackProblem == HandsSetup.handbackNotSavedMessage }
        let notReleased = calls.get() == 3 && world.service.settings.forcedOff && world.status(.host).status == .failed
        world.service.settings.failSavesForTesting = false
        world.phase.set(.running(url: "https://os-for-chatgpt.example.com/mcp"))
        world.setup.handBack()
        let stillRunning = await waitUntil(10) { world.setup.handbackProblem == HandsSetup.handbackStillRunningMessage }
        let notReleasedRunning = calls.get() == 3 && !world.service.settings.forcedOff
        world.phase.set(.stopped)
        world.setup.handBack()
        let finally = await waitUntil(10) { calls.get() == 4 && world.setup.handbackProblem == nil }
        check(notSaved && notReleased && stillRunning && notReleasedRunning && finally,
              "W183 R6a 審查 交回之前「關」要存進磁碟、關口要停：只在記憶體關掉、關口還在跑都不交回；存進去、停了才交回",
              "notSaved=\(notSaved) \(notReleased) running=\(stillRunning) \(notReleasedRunning) finally=\(finally)")

        // W183 R6a 審查（Claude）：只有交回真的沒成功（第 1 步記著失敗；重開後也看得到）才給鈕——剛認領、開關關著＝已關閉。
        var stuck = HandsSettings(); stuck.hostDeviceID = fixture.secondaryID
        var on = stuck; on.enabled = true
        let hostFailed = HandsSetupStepState(status: .failed, message: "這台已經關了；但主設備沒收到「這台不當主機了」（網路或主設備沒開）：連得到主設備時按「交回主設備」")
        let claimed = HandsSetupStepState(status: .done, message: "主機：這台（Fixture）")
        let justClaimed = HandsOneSwitch.handback(problem: nil, isSecondary: true, local: fixture.secondaryID, settings: stuck, hostStep: claimed, busy: false)
        let offStatus = HandsOneSwitchStatus.forLocal(.init(enabled: false, level: 1, busy: false, setup: HandsSetupState(), loginOpen: false, blocked: nil,
                                                         phase: .stopped, activeGrants: 0, connect: .idle, connectProblem: nil, handback: justClaimed))
        check(HandsOneSwitch.handback(problem: nil, isSecondary: true, local: fixture.secondaryID, settings: stuck, hostStep: hostFailed, busy: false) != nil
              && HandsOneSwitch.handback(problem: nil, isSecondary: false, local: fixture.secondaryID, settings: stuck, hostStep: hostFailed, busy: false) == nil
              && HandsOneSwitch.handback(problem: nil, isSecondary: true, local: fixture.secondaryID, settings: on, hostStep: hostFailed, busy: false) == nil
              && justClaimed == nil && offStatus == .off,
              "W183 R6a 審查 「交回主設備」只在交回真的沒成功時出現（重開後也看得到）；剛認領、開關關著＝已關閉，不叫你交回")
    }

    // MARK: - 副設備：模式變了會開始同步、看得到時退避最多 10 秒、按的開關走到連線那一步在這台 offer

    @MainActor static func remoteSyncChecks(_ check: Checker, _ base: URL) async throws {
        // W183 R8 整合：ChatGPT build 的卡片接到多設備後端（每台自己當主機、設定在主設備）——不再有「畫面模式／跟主機同步的鍵」；
        // 畫面打開＝後端一陣子內同步快一點（HandsBuildController.viewDidAppear → HandsBuildSync.heatUp）。原本守的「設定一變馬上重問、
        // 看得到時最多 10 秒」在多設備改成：改設定一律帶版本（CAS）、別處改過＝不送，畫面開著時熱問（w183build「多久問一次」）。
        // 下面照舊驗 HandsRemoteClient 的退避（［連線］到主設備、ChatGPT Space 的狀態小鈕還在用它）。

        let dir = base.appendingPathComponent("client-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("entry"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("live"), withIntermediateDirectories: true)
        let dispatch = DeviceDispatch(entry: TatwoEntry(environment: ["TATWO_OS_ROOT": dir.appendingPathComponent("entry").path], preference: nil),
                                      registry: DeviceRegistry(root: dir.appendingPathComponent("live"), authorizedKeysURL: dir.appendingPathComponent("authorized_keys")),
                                      retireBackup: { _ in })
        let client = HandsRemoteClient(dispatch: dispatch)
        client.pollsWhileWaiting = false   // 不起定時器：自測自己叫
        client.watch(visible: true)
        client.refreshNow()
        _ = await waitUntil(10) { client.debugBackoff.failures >= 1 && !client.debugBackoff.inFlight }
        client.refreshNow()
        _ = await waitUntil(10) { client.debugBackoff.failures >= 2 && !client.debugBackoff.inFlight }
        let now = Date()
        let visibleCap = client.debugBackoff.nextAllowed <= now.addingTimeInterval(10)
        _ = await waitUntil(2) { client.problem != nil }
        let unreachable = HandsOneSwitchStatus.forRemote(.init(status: client.status, pendingEnabled: nil, stale: client.stale, problem: client.problem,
                                                            connect: .idle, connectProblem: nil))
        client.unwatch(visible: true)
        client.refreshNow()
        _ = await waitUntil(10) { client.debugBackoff.failures >= 3 && !client.debugBackoff.inFlight }
        let hidden = client.debugBackoff.nextAllowed >= Date().addingTimeInterval(50)
        check(visibleCap && hidden && unreachable == .failed(HandsOneSwitchStatus.unreachableText, .retry),
              "W183 R6a 設定頁看得到時連不上最多 10 秒再問（看不到照舊退避到 60 秒）；還沒拿到狀態＝強制問、問不到＝出錯＋重試",
              "visible=\(visibleCap) hidden=\(hidden) \(unreachable.text)")

        // W183 R6a 審查（GPT-6「9 秒退避加 10 秒定時器，實際可超過 10 秒」）：查詢本身慢（模擬 0.6 秒）也從「開始問」起算，到期自己排下一次，
        // 不等下一輪定時器（自測把 10 秒縮成 1.5 秒；定時器沒起：只靠到期自己排的那一次）。
        let timed = HandsRemoteClient(dispatch: dispatch)
        timed.pollsWhileWaiting = false
        timed.visibleMaxGap = 1.5
        timed.debugCall = { _, _ in Thread.sleep(forTimeInterval: 0.6); throw HandsWireError.disabled }
        timed.watch(visible: true)
        timed.refreshNow()
        _ = await waitUntil(6) { timed.debugStartTimes.count >= 3 }
        let starts = timed.debugStartTimes
        timed.unwatch(visible: true)
        let gaps = zip(starts.dropFirst(), starts).map { $0.timeIntervalSince($1) }
        check(starts.count >= 3 && gaps.allSatisfy { $0 >= 1.4 && $0 <= 1.5 + 0.5 },
              "W183 R6a 審查 設定頁看得到時：連不上的下一次從「上一次開始問」起算、最多 visibleMaxGap 就問（含查詢花的時間；到期自己排，不等定時器）",
              "\(gaps)")

        // 這台按的開關（start_setup 成功）：主機走到「等你按［連線］」＝這台 offer 一次；沒到之前、連不上都照等；關掉了、已經連上＝不等了。
        let offered = HandsLocked(0)
        client.offerConnect = { offered.update { $0 += 1 } }
        func status(_ pairing: String, busy: Bool = false, enabled: Bool = true, phase: String = "running", grants: Int = 0) -> HandsRemoteStatus? {
            HandsRemoteStatus(["enabled": enabled, "phase": ["state": phase, "text": "x"], "setup_busy": busy,
                               "setup": [["step": "pairing", "status": pairing]],
                               "grants": (0..<grants).map { ["id": "g_\($0)", "level": 1] }])
        }
        client.debugArmOffer()
        client.debugReceive(status("pending", busy: true))
        client.debugReceive(nil)
        let waited = client.offerArmed && offered.get() == 0
        client.debugReceive(status("waiting_user"))
        let fired = offered.get() == 1 && !client.offerArmed
        client.debugReceive(status("waiting_user"))
        let once = offered.get() == 1
        client.debugArmOffer()
        client.debugReceive(status("waiting_user", grants: 1))
        let connectedStops = !client.offerArmed && offered.get() == 1
        client.debugArmOffer()
        client.debugReceive(status("waiting_user", enabled: false))
        let offStops = !client.offerArmed && offered.get() == 1
        check(waited && fired && once && connectedStops && offStops
              && HandsRemoteClient.offerOps == ["start_setup", "continue_setup", "confirm_authorization", "reauthorize"],
              "W183 R6a 副設備按的開關：主機走到連線那一步＝這台的私訊框出［連線］卡（一次）；沒到、連不上照等；已連上、關掉了就不等",
              "waited=\(waited) fired=\(fired) once=\(once) connected=\(connectedStops) off=\(offStops)")
    }

    // MARK: - 沒用到的 TATWO 通道：只列符合條件的、刪之前再查一次、只刪勾的

    @MainActor static func unusedTunnelChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let current = "0f0e0d0c-0b0a-4908-8706-050403020100"
        let unused = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", busy = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let other = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", gone = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let later = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        func row(_ id: String, _ name: String, connections: Int = 0, deleted: String? = nil) -> [String: Any] {
            var object: [String: Any] = ["id": id, "name": name, "created_at": "2026-09-28T04:35:00Z",
                                         "connections": (0..<connections).map { ["id": "conn-\($0)", "colo_name": "tpe01"] }]
            if let deleted { object["deleted_at"] = deleted }
            return object
        }
        let rows: [[String: Any]] = [row(current, "tatwo-hands-current", connections: 2), row(unused, "tatwo-hands-extra1235"),
                                     row(busy, "tatwo-hands-busy", connections: 1), row(other, "prod-tunnel"),
                                     row(gone, "tatwo-hands-gone", deleted: "2026-09-28T05:00:00Z"), row(later, "tatwo-hands-later")]
        let stdout = [text(rows)]
        let parsed = HandsCloudflared.unusedTatwoTunnels(stdout: stdout, excludingIDs: [current.uppercased()], excludingNames: ["tatwo-hands-later"])
        let malformed = HandsCloudflared.unusedTatwoTunnels(stdout: ["[{\"id\":\"\(unused)\",\"name\":\"tatwo-hands-x\"}]"], excludingIDs: [], excludingNames: [])
        check(parsed?.map(\.id) == [unused] && malformed == nil && HandsCloudflared.unusedTatwoTunnels(stdout: ["WRN x", "[]"], excludingIDs: [], excludingNames: []) == nil,
              "W183 R6a 沒用到的通道只列：tatwo-hands- 開頭、沒有連線、還沒刪、不是現在用的（也不是建到一半記下的）；看不懂整份不列",
              "\(String(describing: parsed?.map(\.name)))")

        let world = try World(fixture, folder: "unused-tunnels", zoneName: "example.com")
        _ = try world.service.updateSettings { $0.enabled = true }
        world.flag("authorized", true)
        world.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        _ = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .user)   // W183 R8c：登入只是登入；選網域、按「套用」
        _ = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
        // W183 R8c（GPT-6 必改 6）：只列這台有建立證據的——扮演「這台以前建過」unused、busy、later、otherDevice、other
        // （寫進 setup.json 的 created_tunnels，重開一個 HandsSetup 讀進來）；stranger 是別台建的（沒有證據）。
        let stranger = "f0f0f0f0-f0f0-4f0f-8f0f-f0f0f0f0f0f0"
        let otherDevice = "abababab-abab-4bab-8bab-abababababab"
        let setupURL = world.paths.appDir.appendingPathComponent("setup.json")
        var stored = (try JSONSerialization.jsonObject(with: Data(contentsOf: setupURL)) as? [String: Any]) ?? [:]
        stored["created_tunnels"] = ((stored["created_tunnels"] as? [String]) ?? []) + [unused, busy, later, otherDevice, other]
        try HandsFiles.writeAtomically(try JSONSerialization.data(withJSONObject: stored), to: setupURL)
        let setup = HandsSetup(dependencies: world.setup.dependencies)
        let fleet: [[String: Any]] = [row(current, setup.snapshot.tunnelName ?? "tatwo-hands-current", connections: 2),
                                      row(unused, "tatwo-hands-extra1235"), row(busy, "tatwo-hands-busy", connections: 1), row(other, "prod-tunnel"),
                                      row(stranger, "tatwo-hands-stranger")]
        try Data(text(fleet).utf8).write(to: world.ctrl.appendingPathComponent("tunnels.json"))
        let started = setup.checkUnusedTunnels()
        let notBusy = !setup.isBusy
        _ = await waitUntil(20) { setup.unusedTunnels != nil && !setup.checkingTunnels }
        check(started && notBusy && setup.unusedTunnels?.map(\.id) == [unused]
              && world.log("argv.log").split(separator: "\n").last?.contains("--origincert") == true
              && world.log("argv.log").split(separator: "\n").last?.hasSuffix(" list --output json") == true,
              "W183 R6a 詳細裡列出沒用到的 TATWO 通道（走同一套沙盒與看門程式；不算設定流程的忙碌）；W183 R8c 只列這台有建立證據的（別台建的不列）",
              "\(String(describing: setup.unusedTunnels?.map(\.name)))")
        // 勾了不該刪的（現在用的、有連線的、別的名字、別台建的）：一律不刪，只刪還符合條件的那條。
        let result = HandsLocked<(Int, Int)?>(nil)
        setup.deleteUnusedTunnels([unused, current, busy, other, stranger]) { result.set(($0, $1)) }
        _ = await waitUntil(20) { result.get() != nil }
        let deletes = world.log("deletes.log").split(separator: "\n").map(String.init)
        let remaining = (try? JSONSerialization.jsonObject(with: Data(contentsOf: world.ctrl.appendingPathComponent("tunnels.json")))) as? [[String: Any]]
        check(result.get().map { $0.0 == 1 && $0.1 == 0 } == true && deletes == [unused]
              && Set(remaining?.compactMap { $0["id"] as? String } ?? []) == [current, busy, other, stranger] && setup.unusedTunnels?.isEmpty == true
              && !world.log("argv.log").contains(" -f") && !world.log("argv.log").contains("--force"),
              "W183 R6a 清掉：刪之前再查一次，只刪勾了而且還符合條件的（現在用的、有連線的、別的名字、別台建的一律不刪；不加 -f）", "\(deletes)")
        // W183 R6a 審查（Claude）＋W183 R8c：被這個網域的 DNS 紀錄指到的 TATWO 通道（另一台設備在用的）不列；查不到 DNS＝整份不列（禁止刪）。
        let cleaned = fleet.filter { ($0["id"] as? String) != unused }
        try Data(text(cleaned + [row(otherDevice, "tatwo-hands-otherdevice")]).utf8).write(to: world.ctrl.appendingPathComponent("tunnels.json"))
        world.putRecord("h" + HandsSetup.randomLabel(19) + ".example.com", content: HandsCloudflared.tunnelTarget(otherDevice))
        _ = await waitUntil(5) { !setup.checkingTunnels }
        let rechecked = setup.checkUnusedTunnels()
        _ = await waitUntil(2) { setup.checkingTunnels }
        _ = await waitUntil(20) { !setup.checkingTunnels }
        let dnsExcluded = rechecked && setup.unusedTunnels?.isEmpty == true && !setup.unusedTunnelsUnverified
        world.dnsFailure.set("auth")
        setup.checkUnusedTunnels()
        _ = await waitUntil(20) { setup.unusedTunnelsUnverified && !setup.checkingTunnels }
        let unverified = setup.unusedTunnels == nil && setup.unusedTunnelsUnverified
        let dnsLog = (try? String(contentsOf: world.paths.root.appendingPathComponent("logs/setup-errors.log"), encoding: .utf8)) ?? ""
        world.dnsFailure.set(nil)
        try Data(text(cleaned).utf8).write(to: world.ctrl.appendingPathComponent("tunnels.json"))
        check(dnsExcluded && unverified && dnsLog.contains("tunnel.list category=dns_unknown"),
              "W183 R6a 審查 沒用到的通道：被這個網域 DNS 指到的（另一台設備的）不列；W183 R8c 查不到 DNS＝整份不列（禁止刪）",
              "\(String(describing: setup.unusedTunnels?.map(\.name)))")
        // W183 R8c：主設備的所有權表記的別台的通道不列；所有權表拿不到＝整份不列。
        var ownedDeps = world.setup.dependencies
        let foreign = HandsLocked<Set<String>?>([later])
        ownedDeps.foreignTunnels = { foreign.get() }
        let owned = HandsSetup(dependencies: ownedDeps)
        try Data(text(cleaned + [row(later, "tatwo-hands-later")]).utf8).write(to: world.ctrl.appendingPathComponent("tunnels.json"))
        owned.checkUnusedTunnels()
        _ = await waitUntil(2) { owned.checkingTunnels }
        _ = await waitUntil(20) { owned.unusedTunnels != nil && !owned.checkingTunnels }
        let foreignExcluded = owned.unusedTunnels?.isEmpty == true
        foreign.set(nil)
        owned.checkUnusedTunnels()
        _ = await waitUntil(2) { owned.checkingTunnels }
        _ = await waitUntil(20) { !owned.checkingTunnels }
        check(foreignExcluded && owned.unusedTunnels == nil,
              "W183 R8c 沒用到的通道：主設備所有權表記的別台的通道不列（離線那台的照樣是它的）；所有權表拿不到＝整份不列",
              "\(String(describing: owned.unusedTunnels?.map(\.name)))")

        // 查完之後才有連線的（例如別台剛接上）：刪之前再查一次就不刪。
        setup.checkUnusedTunnels()
        let listedLater = await waitUntil(20) { setup.unusedTunnels?.map(\.id) == [later] && !setup.checkingTunnels }
        try Data(text(cleaned + [row(later, "tatwo-hands-later", connections: 1)]).utf8).write(to: world.ctrl.appendingPathComponent("tunnels.json"))
        let second = HandsLocked<(Int, Int)?>(nil)
        setup.deleteUnusedTunnels([later]) { second.set(($0, $1)) }
        _ = await waitUntil(20) { second.get() != nil }
        check(listedLater && second.get().map { $0.0 == 0 } == true && world.log("deletes.log").split(separator: "\n").map(String.init) == [unused],
              "W183 R6a 查完之後才接上連線的：刪之前再查一次，不刪")
        check(!world.log("argv.log").contains(fixture.canaryAPIToken) && !world.allFilesText().contains(fixture.canaryAPIToken),
              "W183 R6a 查、刪通道：授權只以 0600 暫存檔交給 cloudflared（argv、檔案都沒有 token）")
    }
}
#endif
