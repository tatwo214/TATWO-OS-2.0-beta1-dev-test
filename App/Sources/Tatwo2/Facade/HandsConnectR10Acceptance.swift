#if DEBUG
import AppKit
import Combine
import Foundation

// W183 R10 自測（w183connect；只在完整隔離的 staging，不開通道、不啟動關口、不上網）：［連線］按一下就好。
// 使用者 09-29：「連線根本連不上 而且也根本不自動」「這邊要勾選也太怪 就要給他用了還要多一個勾選」；裁決：「I understand」與 8 碼由 TATWO 代做，
// 只限 TATWO 自己開的那一頁，按［連線］那一下就算同意。
// - 代勾：Pod 回 tickable＝App 點那一格（假 Pod 記下位置）、等一下、帶同一張表單的記號再按 Create；只點一次。點不下去、點了沒勾到＝交給使用者
//   （卡片一句話）；代勾的時候（Create 還沒按）出現配對頁＝當場終止、那一筆作廢、不填。
// - 代填：主機核對過綁住的那一頁才給碼；Pod 在那一頁填好送出，碼不上卡片（presenter 從沒顯示碼）；填不成、送了沒被收下（剩幾次變少、太久）＝退回顯示碼；
//   手動模式不代填；沒綁上（攻擊者先占交易）＝不填。
// - 配對表單的辨識（畫面快照→欄位）與節點綁定：純資料的規則在這裡驗；真的 CEF（原生點擊、節點綁定 typeText）由 W328 在隔離的 loopback Pod 驗。

extension HandsConnectAcceptance {
    @MainActor static func r10Checks(_ check: Checker, _ base: URL) async throws {
        try await r10OnePress(check, base)
        try await r10TickFallbacks(check, base)
        try await r10BeforeCreate(check, base)
        try await r10FillFallbacks(check, base)
        try await r10NoFillWhenUnbound(check, base)
        try await r10Provenance(check, base)
        try await r10Round3(check, base)
        try await r10Round4(check, base)
        await r10ArmedLate(check)
        r10PairingForm(check)
        r10TickControl(check)
    }

    static let tickTarget = HandsTickTarget(x: 20, y: 400, width: 18, height: 18, viewportWidth: 466, viewportHeight: 678)

    /// 假 ChatGPT 的配對頁參數（Pod 看到的那一組）的原始證據（綁住那一頁用的；不是第二版）。
    static func rawEvidence(_ chatgpt: FakeChatGPT) -> String {
        HandsAuth.evidenceHash(clientID: chatgpt.clientID, redirectURI: chatgpt.redirect, state: chatgpt.state, challenge: chatgpt.challenge)
    }

    /// 卡片出現過哪幾種（看使用者有沒有被叫去勾、碼有沒有上卡片）。
    @MainActor final class CardLog {
        private(set) var turns: [String] = []
        private(set) var codes = 0
        private var watch: AnyCancellable?
        init(_ flow: HandsConnectFlow) {
            watch = flow.$card.sink { [weak self] card in
                MainActor.assumeIsolated {
                    if case .waitingUser(let text, _)? = card { self?.turns.append(text) }
                    if case .pairing(let view)? = card, view.pairingCode != nil { self?.codes += 1 }
                }
            }
        }
    }

    // MARK: 按一下就好：代勾＋代填，使用者什麼都不用做

    @MainActor static func r10OnePress(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r10-one-press")
        let service = world.service
        let seen = HandsConnectorAck(form: "fr10tick001", warning: "0123abcd-99")
        world.pod.createQueue = [.tickable(seen, tickTarget)]   // 第一次：表單上只剩「I understand」那一格（之後照 createResult＝按了 Create）
        world.pod.tickResult = true
        let chatgpt = FakeChatGPT(service: service)
        // ChatGPT 只在 Create 真的按下去之後才開始 OAuth（代勾的那一下之後才接上）。
        var windowAtTick: Bool?
        world.pod.onTick = {
            windowAtTick = world.pod.window()
            world.chatgptStarts(chatgpt)
        }
        var authCode: String?
        var filledOn: (frame: HandsPodFrame, evidence: String)?
        world.pod.fillBehavior = { code, frame, evidence in
            // 「網頁」收到填好的 8 碼送出（關口轉進 authorize_submit）。
            filledOn = (frame, evidence)
            authCode = try? chatgpt.submit(code)
            return .filled
        }
        let log = CardLog(world.flow)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let authorized = await waitUntil(8) { authCode?.isEmpty == false }
        let access = try chatgpt.token(authCode ?? "")
        try chatgpt.tools(access)
        let connected = await waitUntil(5) { world.flow.phase == .connected }
        check(authorized && connected && world.pod.ticks == [tickTarget] && world.pod.acks.count == 2 && world.pod.acks[0] == nil && world.pod.acks[1] == seen
              && world.pod.calls.filter({ $0 == "tick" }).count == 1 && windowAtTick == true,
              "W183 R10 代勾：Pod 說只剩「I understand」那一格＝TATWO 點那一格（只點一次；窗口開著、不回頭交給使用者），再帶同一張表單的記號按 Create",
              "\(world.pod.calls) acks=\(world.pod.acks)")
        check(connected && log.turns.isEmpty && log.codes == 0 && !world.presenter.codeEverVisible
              && filledOn?.evidence == rawEvidence(chatgpt) && filledOn?.frame.surface == -1 && world.pod.fills.count == 1
              && !world.flow.debugLog.joined().contains(chatgpt.state),
              "W183 R10 代填：主機核對過綁住的那一頁才給碼，Pod 在那一頁（同一個畫面、同一組參數）填好送出；卡片從沒叫你勾、從沒顯示碼；紀錄裡沒有碼與參數",
              "turns=\(log.turns) codes=\(log.codes) \(world.flow.debugLog.suffix(6))")
        world.flow.cancel(reason: "test_done")
    }

    // MARK: 代勾的退路：點不下去、點了沒勾到＝交給使用者（一句話）

    @MainActor static func r10TickFallbacks(_ check: Checker, _ base: URL) async throws {
        let seen = HandsConnectorAck(form: "fr10tick002", warning: "0123abcd-98")
        // 1. 點不下去（Pod 不在畫面上、畫面大小對不上）。
        let blocked = try World(base, "r10-tick-blocked")
        blocked.pod.createQueue = [.tickable(seen, tickTarget)]
        blocked.pod.tickResult = false
        blocked.flow.offer()
        _ = await waitUntil(5) { isConfirm(blocked.flow.card) }
        blocked.flow.connect()
        let waiting = await waitUntil(5) {
            if case .waitingUser(let text, continuable: true)? = blocked.flow.card { return text == HandsConnectFlow.tickMissedCardText }
            return false
        }
        let closed = await waitUntil(3) { blocked.service.auth.windowExpiresAt == nil }
        check(waiting && closed && blocked.pod.calls.filter({ $0 == "tick" }).count == 1 && !blocked.pod.calls.contains("create-resume"),
              "W183 R10 代勾點不下去：交給你勾（卡片一句話：TATWO 沒勾到、自己勾再按［繼續］），等的時候窗口關著，不再點第二次",
              "\(blocked.pod.calls) \(String(describing: blocked.flow.card))")
        blocked.flow.cancel(reason: "test_done")

        // 2. 點了、網頁沒認（證據不算：還是要勾）＝不再點，交給使用者；使用者勾完按［繼續］＝照 R9 帶回同一張表單按 Create。
        let missed = try World(base, "r10-tick-missed")
        let again = HandsConnectorAck(form: "fr10tick003", warning: "0123abcd-98")
        missed.pod.createQueue = [.tickable(seen, tickTarget), .needsUser(HandsConnectFlow.riskAckReason, again)]
        missed.pod.tickResult = true
        let chatgpt = FakeChatGPT(service: missed.service)
        missed.flow.offer()
        _ = await waitUntil(5) { isConfirm(missed.flow.card) }
        missed.flow.connect()
        let handed = await waitUntil(5) {
            if case .waitingUser(let text, continuable: true)? = missed.flow.card { return text == HandsConnectFlow.tickMissedCardText }
            return false
        }
        missed.chatgptStarts(chatgpt)
        missed.flow.continueAfterUser()
        let paired = await waitUntil(8) { missed.pairing?.pairingCode != nil }
        check(handed && paired && missed.pod.calls.filter({ $0 == "tick" }).count == 1 && missed.pod.acks.last == again
              && missed.pairing?.autoFillFailed == true,
              "W183 R10 點了沒勾到：不再點第二次、交給你勾；你勾完按［繼續］＝帶回同一張表單按 Create（R9 的真人證據鏈照舊）；這個假 Pod 填不了碼＝退回顯示碼",
              "\(missed.pod.calls) \(String(describing: missed.flow.card))")
        missed.flow.cancel(reason: "test_done")

        // 3. 警語大改、沒見過的勾選框：Pod 不給位置（needs_user 帶原因）＝卡片講原因、交給你，TATWO 不點。
        for (name, reason, text) in [("r10-changed", HandsConnectFlow.warningChangedReason, HandsConnectFlow.warningChangedCardText),
                                     ("r10-box", HandsConnectFlow.checkboxUnknownReason, HandsConnectFlow.checkboxUnknownCardText)] {
            let world = try World(base, name)
            world.pod.createQueue = [.needsUser(reason, seen)]
            world.pod.tickResult = true
            world.flow.offer()
            _ = await waitUntil(5) { isConfirm(world.flow.card) }
            world.flow.connect()
            let shown = await waitUntil(5) {
                if case .waitingUser(let card, continuable: true)? = world.flow.card { return card == text }
                return false
            }
            check(shown && !world.pod.calls.contains("tick"),
                  "W183 R10 \(reason)：TATWO 不代勾，卡片一句話說原因、交給你勾再按［繼續］", "\(world.pod.calls)")
            world.flow.cancel(reason: "test_done")
        }
    }

    // MARK: 代勾的時候（Create 還沒按）就出現配對頁＝當場終止、那一筆作廢、不填

    @MainActor static func r10BeforeCreate(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r10-before-create")
        let seen = HandsConnectorAck(form: "fr10tick004", warning: "0123abcd-97")
        world.pod.createQueue = [.tickable(seen, tickTarget)]
        world.pod.tickResult = true
        let early = FakeChatGPT(service: world.service)
        world.pod.onTick = {
            _ = try? early.register()
            _ = early.begin()
            world.pod.emit(early.authorizeURL)   // 代勾的那一下，Create 還沒按就開出配對頁
        }
        world.pod.fillBehavior = { _, _, _ in .filled }
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let refused = await waitUntil(5) { world.flow.phase == .refused }
        let closed = await waitUntil(3) { world.service.auth.windowExpiresAt == nil && world.service.auth.attemptTransaction(world.attemptID ?? "") == nil }
        var dead = false
        do { _ = try early.submit("22222222") } catch let error as HandsWireError { dead = error.code == "pairing_window_closed" || error.code == "pairing_expired" }
        check(refused && closed && dead && world.flow.card == .refused(HandsConnectFlow.beforeCreateText) && world.pod.fills.isEmpty
              && !world.pod.calls.contains("create-resume") && !world.presenter.codeEverVisible && world.service.auth.activeGrantIDs.isEmpty,
              "W183 R10 Create 之前出現的配對頁：當場終止、不填、不給碼、那一筆作廢（也不按 Create）",
              "\(world.pod.calls) \(world.flow.debugLog.suffix(4))")
    }

    // MARK: 代填的退路：填不成、送了沒被收下＝退回顯示碼；手動模式不代填

    @MainActor static func r10FillFallbacks(_ check: Checker, _ base: URL) async throws {
        // 1. 找不到欄位、頁面改版：退回顯示碼（卡片說一句為什麼）；使用者照打＝連上。
        let failed = try World(base, "r10-fill-failed")
        failed.pod.fillBehavior = { _, _, _ in .failed("form") }
        let chatgpt = FakeChatGPT(service: failed.service)
        failed.chatgptStarts(chatgpt)
        failed.flow.offer()
        _ = await waitUntil(5) { isConfirm(failed.flow.card) }
        failed.flow.connect()
        let shown = await waitUntil(8) { failed.pairing?.pairingCode != nil }
        let view = failed.pairing
        let access = try chatgpt.token(try chatgpt.submit(view?.pairingCode ?? ""))
        try chatgpt.tools(access)
        let connected = await waitUntil(5) { failed.flow.phase == .connected }
        check(shown && view?.autoFillFailed == true && failed.pod.fills.count == 1 && failed.presenter.codeEverVisible && connected,
              "W183 R10 代填找不到欄位（頁面改版）：退回顯示碼（卡片寫 TATWO 沒填成、照這 8 碼自己打），你照打就連上",
              "\(failed.pod.calls)")
        failed.flow.cancel(reason: "test_done")

        // 2. 填了、打錯（網頁收到的不是這 8 碼）：主機說剩的次數變少＝不再等，退回顯示碼。
        let wrong = try World(base, "r10-fill-wrong")
        let wrongChat = FakeChatGPT(service: wrong.service)
        wrong.chatgptStarts(wrongChat)
        wrong.pod.fillBehavior = { _, _, _ in _ = try? wrongChat.submit("23456789"); return .filled }
        wrong.flow.offer()
        _ = await waitUntil(5) { isConfirm(wrong.flow.card) }
        wrong.flow.connect()
        let fallback = await waitUntil(8) { wrong.pairing?.pairingCode != nil }
        check(fallback && wrong.pairing?.autoFillFailed == true && wrong.pairing?.attemptsLeft == 4 && wrong.pod.fills.count == 1,
              "W183 R10 代填送了沒被收下（剩的次數變少）：馬上退回顯示碼（只填一次）", "\(String(describing: wrong.pairing))")
        wrong.flow.cancel(reason: "test_done")

        // 3. 填了、送出去沒有下文：過了等待時間退回顯示碼。
        let silent = try World(base, "r10-fill-silent")
        let silentChat = FakeChatGPT(service: silent.service)
        silent.chatgptStarts(silentChat)
        silent.pod.fillBehavior = { _, _, _ in .filled }
        silent.flow.offer()
        _ = await waitUntil(5) { isConfirm(silent.flow.card) }
        silent.flow.connect()
        let late = await waitUntil(8) { silent.pairing?.pairingCode != nil }
        check(late && silent.pairing?.autoFillFailed == true && silent.pod.fills.count == 1,
              "W183 R10 代填送出去沒被收下（等太久）：退回顯示碼，不再填第二次", "\(silent.pod.calls)")
        silent.flow.cancel(reason: "test_done")

        // 4. 手動模式（Create 是你自己按的）：不代填，照舊顯示碼。
        let manual = try World(base, "r10-manual")
        manual.pod.createResult = .notFound("mcp_item")
        manual.pod.fillBehavior = { _, _, _ in .filled }
        manual.flow.offer()
        _ = await waitUntil(5) { isConfirm(manual.flow.card) }
        manual.flow.connect()
        _ = await waitUntil(5) { manual.flow.phase == .needsManual }
        let manualChat = FakeChatGPT(service: manual.service)
        manual.chatgptStarts(manualChat)
        manual.flow.retry(manual: true)
        let manualCode = await waitUntil(8) { manual.pairing?.pairingCode != nil }
        check(manualCode && manual.pairing?.manual == true && manual.pod.fills.isEmpty,
              "W183 R10 手動模式（建立是你自己按的、來源確認不了）：不代填，照舊顯示碼", "\(manual.pod.calls)")
        manual.flow.cancel(reason: "test_done")
    }

    // MARK: 沒綁上＝不填（攻擊者先占交易）

    @MainActor static func r10NoFillWhenUnbound(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r10-unbound")
        let attacker = FakeChatGPT(service: world.service)
        let chatgpt = FakeChatGPT(service: world.service)
        world.pod.fillBehavior = { _, _, _ in .filled }
        world.chatgptStarts(chatgpt, before: {
            _ = try? attacker.register()
            _ = attacker.begin()   // 攻擊者的 ChatGPT 搶在前面開了這個窗口的交易
        })
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let refused = await waitUntil(8) { world.flow.phase == .refused }
        check(refused && world.pod.fills.isEmpty && !world.presenter.codeEverVisible && world.service.auth.activeGrantIDs.isEmpty,
              "W183 R10 沒綁上（占著窗口的交易不是 Pod 看到的那一頁）：主機不給碼＝不填、不顯示、那一筆作廢", "\(world.pod.calls)")
    }

    // MARK: W183 R10 第二輪（GPT-6 1）：來源證據——Create 真的送出（錨點）之前的配對頁一律拒絕；回覆沒回來不代填；popup、離開 chatgpt.com

    @MainActor static func r10Provenance(_ check: Checker, _ base: URL) async throws {
        // 1. 建立指令的準備期間（表單還在填、還沒按 Create）就冒出 TATWO 的配對頁（參數對）＝當場終止、作廢、不填、不給碼。
        let prep = try World(base, "r10-prep")
        let early = FakeChatGPT(service: prep.service)
        prep.pod.createResult = .pressed
        prep.pod.onCreateStart = {
            _ = try? early.register()
            _ = early.begin()
            prep.pod.emit(early.authorizeURL)   // 同源的網頁程式搶在 Create 之前把 Pod 導到這一組授權參數
        }
        prep.pod.fillBehavior = { _, _, _ in .filled }
        prep.flow.offer()
        _ = await waitUntil(5) { isConfirm(prep.flow.card) }
        prep.flow.connect()
        let refused = await waitUntil(5) { prep.flow.phase == .refused }
        let closed = await waitUntil(3) { prep.service.auth.windowExpiresAt == nil && prep.service.auth.attemptTransaction(prep.attemptID ?? "") == nil }
        check(refused && closed && prep.flow.card == .refused(HandsConnectFlow.beforeCreateText) && prep.pod.fills.isEmpty
              && !prep.presenter.codeEverVisible && prep.service.auth.activeGrantIDs.isEmpty && prep.flow.debugLog.contains("authorize before create"),
              "W183 R10 第二輪 準備期間（Create 還沒送出、不只代勾那一段）冒出的配對頁：當場終止、那一筆作廢、不填、不給碼",
              "\(prep.pod.calls) \(prep.flow.debugLog.suffix(4))")

        // 2. 送了「按」、回覆沒回來（unknown）：配對頁照樣可以綁（主機核對），但不代填——只顯示碼讓你自己打，卡片說明原因。
        let lost = try World(base, "r10-unknown")
        let chatgpt = FakeChatGPT(service: lost.service)
        lost.pod.createResult = .unknown
        // 回覆沒回來之後讀清單：連接器在（真的按下去了）＝接著等配對頁；清單裡沒有＝改手動（前面「按了建立、結果未知」那一條）。
        let listedConnector = HandsConnectorScan.Match(id: "c-r10-unknown", name: HandsBuildConfig.connectorName("Primary One"), auth: "oauth")
        lost.pod.rescanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true, matches: [listedConnector])
        lost.pod.fillBehavior = { _, _, _ in .filled }
        lost.chatgptStarts(chatgpt)
        lost.flow.offer()
        _ = await waitUntil(5) { isConfirm(lost.flow.card) }
        lost.flow.connect()
        let shown = await waitUntil(8) { lost.pairing?.pairingCode != nil }
        check(shown && lost.pod.fills.isEmpty && lost.pairing?.autoFillUnproven == true && lost.presenter.codeEverVisible
              && lost.pod.anchors.count == 1,
              "W183 R10 第二輪 送了 Create、回覆沒回來（unknown）：不把「看到配對頁」反推成按下去了來代填——只顯示碼、卡片說確認不了來源",
              "\(lost.pod.calls) \(String(describing: lost.pairing))")
        lost.flow.cancel(reason: "test_done")

        // 3. 配對頁出現在錨點之前就開著的 popup 裡（網頁先開好視窗，Create 之後才導過去）＝不算：終止、不給碼。
        let popup = try World(base, "r10-popup-before")
        let viaPopup = FakeChatGPT(service: popup.service)
        popup.pod.onCreateStart = { popup.pod.emit(URL(string: "https://chatgpt.com/plugins")!, popup: 55) }
        popup.chatgptStarts(viaPopup, popup: 55)
        popup.flow.offer()
        _ = await waitUntil(5) { isConfirm(popup.flow.card) }
        popup.flow.connect()
        let popupRefused = await waitUntil(8) { popup.flow.phase == .refused }
        check(popupRefused && !popup.presenter.codeEverVisible && popup.pod.fills.isEmpty
              && popup.flow.debugLog.contains { $0.contains("popup_before_press") },
              "W183 R10 第二輪 錨點那一刻已經開著的 popup 裡出現的配對頁：不算、終止、不給碼", "\(popup.flow.debugLog.suffix(4))")

        // 4. 錨點之後主框架先去了別的網站、再回 chatgpt.com、才出現配對頁＝不是一路從這個流程導過來的：終止。
        let detour = try World(base, "r10-detour")
        let viaDetour = FakeChatGPT(service: detour.service)
        detour.pod.onAction = { [weak detour] in
            _ = try? viaDetour.register()
            _ = viaDetour.begin()
            let url = viaDetour.authorizeURL
            Task { @MainActor in
                detour?.pod.emit(URL(string: "https://evil.example.net/landing")!)
                detour?.pod.emit(URL(string: "https://chatgpt.com/plugins")!)
                detour?.pod.emit(url)
            }
        }
        detour.flow.offer()
        _ = await waitUntil(5) { isConfirm(detour.flow.card) }
        detour.flow.connect()
        let detourRefused = await waitUntil(8) { detour.flow.phase == .refused }
        check(detourRefused && !detour.presenter.codeEverVisible && detour.flow.debugLog.contains { $0.contains("left_chatgpt_after_press") },
              "W183 R10 第二輪 錨點之後主框架離開過 chatgpt.com 再回來才出現的配對頁：不算、終止、不給碼", "\(detour.flow.debugLog.suffix(4))")

        // 5. 對照組：錨點記在 ChatGPT 開始 OAuth 之前（正常的一次：前面代填那一條），配對頁的世代比錨點新。
        let normal = try World(base, "r10-anchor-order")
        let ok = FakeChatGPT(service: normal.service)
        normal.chatgptStarts(ok)
        normal.flow.offer()
        _ = await waitUntil(5) { isConfirm(normal.flow.card) }
        normal.flow.connect()
        let bound = await waitUntil(8) { normal.flow.debugLog.contains { $0.contains("authorize observed") } }
        check(bound && normal.pod.anchors.count == 1 && normal.flow.debugLog.firstIndex(of: "press dispatched").map { index in
                  normal.flow.debugLog.firstIndex { $0.contains("authorize observed") }.map { $0 > index } ?? false } == true,
              "W183 R10 第二輪 對照組：錨點（press dispatched）在前、配對頁（authorize observed）在後，照常綁住", "\(normal.flow.debugLog.suffix(6))")
        normal.flow.cancel(reason: "test_done")
    }

    // MARK: W183 R10 第三輪（GPT-6 發現 1、3、7）：錨點之後只准一條路、派送前核同意內容、舊操作的錨點不收

    @MainActor static func r10Round3(_ check: Checker, _ base: URL) async throws {
        // 1. 錨點之後、配對頁之前多開了一個不相干的 popup，配對頁出現在另一個新 popup：照樣綁住（主機核對），但不代填、只顯示碼。
        let crowded = try World(base, "r10-crowded")
        let crowdedChat = FakeChatGPT(service: crowded.service)
        crowded.pod.fillBehavior = { _, _, _ in .filled }
        crowded.chatgptStarts(crowdedChat, popup: 62, before: { crowded.pod.emit(URL(string: "https://chatgpt.com/plugins")!, popup: 61) })
        crowded.flow.offer()
        _ = await waitUntil(5) { isConfirm(crowded.flow.card) }
        crowded.flow.connect()
        let crowdedShown = await waitUntil(8) { crowded.pairing?.pairingCode != nil }
        check(crowdedShown && crowded.pod.fills.isEmpty && crowded.pairing?.autoFillUnproven == true
              && crowded.flow.debugLog.contains { $0.contains("authorize observed") && $0.contains("crowded") },
              "W183 R10 第三輪 錨點之後多開了別的 popup（不只一條路）：配對頁照樣綁住，但不代填、只顯示碼（卡片說確認不了來源）",
              "\(crowded.pod.calls) \(crowded.flow.debugLog.suffix(4))")
        crowded.flow.cancel(reason: "test_done")

        // 2. 配對頁在 popup，但那個 popup 不是 Pod 主框架開的：不代填、只顯示碼。
        let opener = try World(base, "r10-opener")
        let openerChat = FakeChatGPT(service: opener.service)
        opener.pod.fillBehavior = { _, _, _ in .filled }
        opener.pod.onAction = { [weak opener] in
            guard let opener else { return }
            _ = try? openerChat.register()
            let (_, status) = openerChat.begin()
            let url = openerChat.authorizeURL
            Task { @MainActor in opener.pod.emit(url, status: status, popup: 63, openerIsMain: false) }
        }
        opener.flow.offer()
        _ = await waitUntil(5) { isConfirm(opener.flow.card) }
        opener.flow.connect()
        let openerShown = await waitUntil(8) { opener.pairing?.pairingCode != nil }
        check(openerShown && opener.pod.fills.isEmpty && opener.pairing?.autoFillUnproven == true,
              "W183 R10 第三輪 配對頁所在的 popup 不是 Pod 主框架開的：不代填、只顯示碼", "\(opener.flow.debugLog.suffix(4))")
        opener.flow.cancel(reason: "test_done")

        // 3. 對照組：錨點之後剛好一個新 popup、配對頁就在它裡面＝照常代填。
        let single = try World(base, "r10-single-popup")
        let singleChat = FakeChatGPT(service: single.service)
        var singleCode: String?
        single.pod.fillBehavior = { code, _, _ in singleCode = try? singleChat.submit(code); return .filled }
        single.chatgptStarts(singleChat, popup: 64)
        single.flow.offer()
        _ = await waitUntil(5) { isConfirm(single.flow.card) }
        single.flow.connect()
        let singleFilled = await waitUntil(8) { singleCode?.isEmpty == false }
        check(singleFilled && single.pod.fills.count == 1 && !single.presenter.codeEverVisible,
              "W183 R10 第三輪 對照組：錨點之後剛好一個新 popup、配對頁就在裡面＝照常代填（碼沒上卡片）", "\(single.pod.calls)")
        single.flow.cancel(reason: "test_done")

        // 4. 派送代勾之前網頁腳本核到同意內容變了（例如連結換了網址）：不點、交給使用者（卡片說跟 TATWO 認得的不一樣），不按 Create。
        let changed = try World(base, "r10-consent-changed")
        let seen = HandsConnectorAck(form: "fr10cons001", warning: "0123abcd-96")
        changed.pod.createQueue = [.tickable(seen, tickTarget)]
        changed.pod.tickOutcome = .consentChanged
        changed.flow.offer()
        _ = await waitUntil(5) { isConfirm(changed.flow.card) }
        changed.flow.connect()
        let handedBack = await waitUntil(5) {
            if case .waitingUser(let text, continuable: true)? = changed.flow.card { return text == HandsConnectFlow.warningChangedCardText }
            return false
        }
        check(handedBack && changed.pod.calls.filter({ $0 == "tick" }).count == 1 && !changed.pod.calls.contains("create-resume")
              && changed.pod.anchors.isEmpty,
              "W183 R10 第三輪 派送代勾前核到同意內容變了：不點、交給你（卡片說跟 TATWO 認得的不一樣），不按 Create、沒有錨點",
              "\(changed.pod.calls) \(String(describing: changed.flow.card))")
        changed.flow.cancel(reason: "test_done")

        // 5. 取消→重連→舊操作的錨點晚到（流程層）：沒有進行中的按、或編號是舊的＝不收，也不改掉新的一次（新的一次照常綁住配對頁）。
        let stale = try World(base, "r10-stale-anchor")
        stale.flow.offer()
        _ = await waitUntil(5) { isConfirm(stale.flow.card) }
        stale.flow.connect()
        let firstAnchored = await waitUntil(5) { stale.pod.anchors.count == 1 }
        let oldAnchor = stale.pod.anchors.first
        stale.flow.cancel(reason: "test_cancel")
        _ = await waitUntil(3) { stale.flow.phase == .idle }
        if let oldAnchor { stale.pod.onPressDispatch?(oldAnchor) }   // 取消之後、重連之前晚到
        let staleChat = FakeChatGPT(service: stale.service)
        stale.chatgptStarts(staleChat)
        // 第一次按過建立：清單裡要看得到它，重連才會走「重新連線」（看不到＝為了不重複建立改手動，那是另一條路）。
        stale.pod.scanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true,
                                                  matches: [.init(id: "c-r10-stale", name: HandsBuildConfig.connectorName("Primary One"), auth: "oauth")])
        stale.flow.offer()
        _ = await waitUntil(5) { isConfirm(stale.flow.card) }
        stale.flow.connect()
        let secondAnchored = await waitUntil(5) { stale.pod.anchors.count == 2 }
        if let oldAnchor { stale.pod.onPressDispatch?(oldAnchor) }   // 重連之後晚到
        let staleBound = await waitUntil(8) { stale.flow.debugLog.contains { $0.contains("authorize observed") } }
        let rejected = stale.flow.debugLog.filter { $0 == "stale press anchor" }.count
        check(firstAnchored && secondAnchored && staleBound && rejected >= 2 && oldAnchor?.operation != stale.pod.anchors.last?.operation
              && oldAnchor?.operation.isEmpty == false,
              "W183 R10 第三輪 取消→重連→舊操作的錨點晚到：不收（取消之後、重連之後都一樣），新的一次照常綁住配對頁",
              "rejected=\(rejected) \(stale.flow.debugLog.suffix(6))")
        stale.flow.cancel(reason: "test_done")
    }

    // MARK: W183 R10 第四輪（GPT-6 發現 1）：popup 在原生開窗那一刻就算（不等載入完成、關掉也不少算）；不是主框架開的＝不代填

    @MainActor static func r10Round4(_ check: Checker, _ base: URL) async throws {
        // 1. 錨點之後先開了 popup A、它一直在載入（沒有網址），配對頁出現在 popup B：照樣綁住，但不代填、只顯示碼。
        let loading = try World(base, "r10-popup-loading")
        let loadingChat = FakeChatGPT(service: loading.service)
        loading.pod.fillBehavior = { _, _, _ in .filled }
        loading.chatgptStarts(loadingChat, popup: 72, before: {
            loading.pod.openPopup(71)
            loading.pod.emitLoading(popup: 71)
        })
        loading.flow.offer()
        _ = await waitUntil(5) { isConfirm(loading.flow.card) }
        loading.flow.connect()
        let loadingShown = await waitUntil(8) { loading.pairing?.pairingCode != nil }
        check(loadingShown && loading.pod.fills.isEmpty && loading.pairing?.autoFillUnproven == true,
              "W183 R10 第四輪 錨點之後先開的 popup 一直在載入（沒有網址）：一開窗就算，配對頁在另一個 popup＝不代填、只顯示碼",
              "\(loading.flow.debugLog.suffix(5))")
        loading.flow.cancel(reason: "test_done")

        // 2. 錨點之後開的 popup A 還沒載入完就關了，配對頁出現在 popup B：一樣不代填（關掉不會少算）。
        let closed = try World(base, "r10-popup-closed")
        let closedChat = FakeChatGPT(service: closed.service)
        closed.pod.fillBehavior = { _, _, _ in .filled }
        closed.chatgptStarts(closedChat, popup: 74, before: {
            closed.pod.openPopup(73)
            closed.pod.emitClosed(popup: 73)
        })
        closed.flow.offer()
        _ = await waitUntil(5) { isConfirm(closed.flow.card) }
        closed.flow.connect()
        let closedShown = await waitUntil(8) { closed.pairing?.pairingCode != nil }
        check(closedShown && closed.pod.fills.isEmpty && closed.pairing?.autoFillUnproven == true,
              "W183 R10 第四輪 錨點之後開的 popup 沒載入完就關了：照樣算它開過，配對頁在另一個 popup＝不代填、只顯示碼",
              "\(closed.flow.debugLog.suffix(5))")
        closed.flow.cancel(reason: "test_done")

        // 3. 真的 Pod 驅動（同一條登記路）：錨點之後原生開了一個 popup（主框架開的）、一直在載入——Pod 驅動一開窗就通知、畫面帶著
        //    開窗者；流程算到它，配對頁在另一個 popup＝不代填。
        let real = try World(base, "r10-real-popup")
        let realChat = FakeChatGPT(service: real.service)
        real.pod.fillBehavior = { _, _, _ in .filled }
        let driver = ChatGPTConnectorPod(tap: ChatGPTTap(transport: ArmTransport(), connection: .ready), surface: { LeaseSurface() })
        var opened: [(Int, Bool)] = []
        var driverFrames: [HandsPodFrame] = []
        driver.onPopupOpened = { [weak real] key, at, openerIsMain in
            opened.append((key, openerIsMain))
            real?.flow.popupOpened(key: key, at: at, openerIsMain: openerIsMain)
        }
        driver.onFrame = { [weak real] frame in
            driverFrames.append(frame)
            real?.flow.frameChanged(frame)
        }
        real.chatgptStarts(realChat, popup: 82, before: {
            driver.simulateNativePopup(key: 81, openerIsMain: true)
            driver.simulatePopupState(key: 81, url: nil, generation: 1, loading: true)
        })
        real.flow.offer()
        _ = await waitUntil(5) { isConfirm(real.flow.card) }
        real.flow.connect()
        let realShown = await waitUntil(8) { real.pairing?.pairingCode != nil }
        check(realShown && real.pod.fills.isEmpty && real.pairing?.autoFillUnproven == true && opened.count == 1 && opened.first?.0 == 81
              && driverFrames.first.map { $0.popupKey == 81 && $0.loading && $0.openerIsMain } == true,
              "W183 R10 第四輪 真的 Pod 驅動：原生一開窗就通知流程（還在載入也算、畫面帶著開窗者），配對頁在另一個 popup＝不代填",
              "opened=\(opened.map { "\($0.0):\($0.1)" }) \(real.flow.debugLog.suffix(5))")
        real.flow.cancel(reason: "test_done")

        // 4. 真的 Pod 驅動：錨點之後有一個 popup 是子框架開的（CEF 的 frame->IsMain() 是 false）、開了馬上關；配對頁在主框架＝不代填。
        let sub = try World(base, "r10-subframe-popup")
        let subChat = FakeChatGPT(service: sub.service)
        sub.pod.fillBehavior = { _, _, _ in .filled }
        let subDriver = ChatGPTConnectorPod(tap: ChatGPTTap(transport: ArmTransport(), connection: .ready), surface: { LeaseSurface() })
        var subClosed: HandsPodFrame?
        subDriver.onPopupOpened = { [weak sub] key, at, openerIsMain in sub?.flow.popupOpened(key: key, at: at, openerIsMain: openerIsMain) }
        subDriver.onFrame = { [weak sub] frame in
            if frame.closed { subClosed = frame }
            sub?.flow.frameChanged(frame)
        }
        sub.chatgptStarts(subChat, before: {
            subDriver.simulateNativePopup(key: 83, openerIsMain: false)
            subDriver.simulatePopupClosed(key: 83)
        })
        sub.flow.offer()
        _ = await waitUntil(5) { isConfirm(sub.flow.card) }
        sub.flow.connect()
        let subShown = await waitUntil(8) { sub.pairing?.pairingCode != nil }
        check(subShown && sub.pod.fills.isEmpty && sub.pairing?.autoFillUnproven == true && subClosed?.openerIsMain == false
              && sub.flow.debugLog.contains { $0.contains("not the main frame") },
              "W183 R10 第四輪 真的 Pod 驅動：錨點之後有 popup 是子框架開的（開了就關）＝配對頁在主框架也不代填、只顯示碼",
              "\(sub.flow.debugLog.suffix(5))")
        sub.flow.cancel(reason: "test_done")
    }

    /// W183 R10 第三輪：記憶體裡的 Pod 傳輸：connectorCreate 的回覆（armed）壓著，自測決定什麼時候送（模擬晚到）；connectorPress 回按了；其他照回。
    @MainActor final class ArmTransport: ChatGPTPodTransport {
        var onEvent: ((String) -> Void)?
        var isRunning = true
        var isHosted = false
        private(set) var commands: [String] = []
        private var heldCreate: String?
        func start() throws { isRunning = true }
        func stop() { isRunning = false }
        func run(_ script: String) {
            guard let open = script.range(of: ".command("), script.hasSuffix(")"),
                  let data = String(script[open.upperBound..<script.index(before: script.endIndex)]).data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = payload["cmd"] as? String, let id = payload["id"] as? String else { return }
            commands.append(cmd)
            if cmd == "connectorCreate" { heldCreate = id; return }
            reply(id, cmd == "connectorPress" ? ["status": "pressed"] : ["ok": true])
        }
        func releaseArmed() {
            guard let id = heldCreate else { return }
            heldCreate = nil
            reply(id, ["status": "armed", "form": "farm12345678"])
        }
        private func reply(_ id: String, _ data: [String: Any]) {
            guard let body = try? JSONSerialization.data(withJSONObject: ["type": "result", "id": id, "ok": true, "data": data]) else { return }
            let json = String(decoding: body, as: UTF8.self)
            Task { @MainActor [weak self] in self?.onEvent?(json) }
        }
    }

    /// W183 R10 第三輪（GPT-6 發現 7）：真的 Pod 驅動（記憶體傳輸）：拿著第一次獨占送出建立 → 取消（放掉獨占）→ 重連（第二次獨占）→
    /// 第一次的 armed 這時候才到＝不記錨點、不送「按」（不會拿第二次的獨占去按）。
    @MainActor static func r10ArmedLate(_ check: Checker) async {
        let transport = ArmTransport()
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let surface = LeaseSurface()
        let pod = ChatGPTConnectorPod(tap: tap, surface: { surface })
        pod.restoreTimeout = 3
        pod.attach()
        surface.onPluginsLoaded = { transport.onEvent?(#"{"type":"hello","loggedIn":true}"#) }
        surface.commit("https://chatgpt.com/plugins")
        var anchors: [HandsPressAnchor] = []
        pod.onPressDispatch = { anchors.append($0) }
        let first = await pod.acquireExclusive(timeout: 1)
        pod.pressOperation = "op-first"
        let late = Task { @MainActor in await pod.create(url: "https://\(publicHost)/mcp", name: "Fixture", acknowledged: nil) }
        let sent = await waitUntil(3) { transport.commands.contains("connectorCreate") }
        pod.releaseExclusive()
        let released = await waitUntil(6) { tap.connectorHold == nil }
        let second = await pod.acquireExclusive(timeout: 3)
        pod.pressOperation = "op-second"
        transport.releaseArmed()
        let result = await late.value
        check(first && sent && released && second && anchors.isEmpty && !transport.commands.contains("connectorPress") && result != .pressed,
              "W183 R10 第三輪 取消→重連→舊的 armed 晚到（真的 Pod 驅動）：舊操作不記錨點、不送「按」（不會用到新的獨占）",
              "commands=\(transport.commands) result=\(result) anchors=\(anchors.count)")
        pod.releaseExclusive()
        _ = await waitUntil(6) { tap.connectorHold == nil }
    }

    // MARK: W183 R10 第二輪（GPT-6 2）：代勾點哪一個節點——快照裡同一個位置剛好一個控制項（純資料的規則；真的 CEF 點擊主導實機驗）

    @MainActor static func r10TickControl(_ check: Checker) {
        let viewport = NSSize(width: 466, height: 678)
        let target = HandsTickTarget(x: 20, y: 400, width: 18, height: 18, viewportWidth: 466, viewportHeight: 678, generation: 9)
        func control(_ id: String, _ x: Double, _ y: Double, kind: String = "button", disabled: Bool = false) -> [String: Any] {
            ["elementID": id, "kind": kind, "label": "", "disabled": disabled, "rect": ["x": x, "y": y, "width": 18.0, "height": 18.0]]
        }
        func snapshot(_ controls: [[String: Any]], origin: String = "https://chatgpt.com", generation: UInt64 = 9, width: Double = 466) -> [String: Any] {
            ["schema": "TatwoCEFVisibleSnapshotV1", "origin": origin, "navigationGeneration": generation,
             "viewport": ["width": width, "height": 678, "scrollX": 0, "scrollY": 0], "controls": controls, "forms": []]
        }
        let good = ChatGPTConnectorPod.tickControl(snapshot([control("cef-12", 20, 400), control("cef-13", 20, 460)]), target: target, generation: 9, viewport: viewport)
        let refusals: [(String, [String: Any])] = [
            ("換了位置（量完之後網頁把它移走）", snapshot([control("cef-12", 20, 430)])),
            ("同一個位置兩個控制項", snapshot([control("cef-12", 20, 400), control("cef-14", 20.5, 400)])),
            ("別份文件（導頁過了）", snapshot([control("cef-12", 20, 400)], generation: 10)),
            ("不是 chatgpt.com", snapshot([control("cef-12", 20, 400)], origin: "https://evil.example.net")),
            ("畫面大小變了", snapshot([control("cef-12", 20, 400)], width: 500)),
            ("停用的", snapshot([control("cef-12", 20, 400, disabled: true)])),
            ("連結（不是按鈕、勾選框）", snapshot([control("cef-12", 20, 400, kind: "draggable")])),
            ("沒有", snapshot([])),
        ]
        let leaked = refusals.filter { ChatGPTConnectorPod.tickControl($0.1, target: target, generation: 9, viewport: viewport) != nil }.map { $0.0 }
        check(good?.elementID == "cef-12" && good?.rect == NSRect(x: 20, y: 400, width: 18, height: 18) && leaked.isEmpty,
              "W183 R10 第二輪 代勾只點「同一份文件、同一個位置剛好一個」的那個節點（走 CEF 的節點驗證點擊，不走裸座標）；換位、多個、導頁、別的網站、停用一律不點",
              "good=\(String(describing: good?.elementID)) leaked=\(leaked)")
    }

    // MARK: 配對表單的辨識（畫面快照→欄位）與節點綁定

    @MainActor static func r10PairingForm(_ check: Checker) {
        let host = publicHost
        let viewport = NSSize(width: 466, height: 678)
        func field(_ type: String, _ y: Double, disabled: Bool = false) -> [String: Any] {
            ["elementID": "cef-\(Int(y))", "type": type, "label": "", "sensitive": type == "text", "disabled": disabled, "readOnly": false,
             "rect": ["x": 40, "y": y, "width": 380, "height": 44]]
        }
        func form(_ fields: [[String: Any]], action: String = "https://" + host, method: String = "POST") -> [String: Any] {
            ["elementID": "cef-1", "sourceOrigin": "https://" + host, "actionOrigin": action, "method": method, "fields": fields,
             "rect": ["x": 30, "y": 200, "width": 400, "height": 200]]
        }
        func snapshot(_ forms: [[String: Any]], origin: String = "https://" + host, generation: UInt64 = 7, width: Double = 466) -> [String: Any] {
            ["schema": "TatwoCEFVisibleSnapshotV1", "origin": origin, "navigationGeneration": generation,
             "viewport": ["width": width, "height": 678, "scrollX": 0, "scrollY": 0], "forms": forms, "controls": []]
        }
        let good = snapshot([form([field("text", 300), field("submit", 360)])])
        let found = ChatGPTConnectorPod.pairingForm(good, publicHost: host, generation: 7, viewport: viewport)
        let refusals: [(String, [String: Any], UInt64)] = [
            ("別的網站", snapshot([form([field("text", 300), field("submit", 360)])], origin: "https://chatgpt.com"), 7),
            ("別份文件", good, 8),
            ("畫面大小對不上", snapshot([form([field("text", 300), field("submit", 360)])], width: 500), 7),
            ("送到別處", snapshot([form([field("text", 300), field("submit", 360)], action: "https://chatgpt.com")]), 7),
            ("GET 表單", snapshot([form([field("text", 300), field("submit", 360)], method: "GET")]), 7),
            ("兩張表單", snapshot([form([field("text", 300), field("submit", 360)]), form([field("text", 400), field("submit", 460)])]), 7),
            ("兩格文字欄", snapshot([form([field("text", 300), field("text", 250), field("submit", 360)])]), 7),
            ("沒有送出", snapshot([form([field("text", 300)])]), 7),
            ("欄位出了畫面", snapshot([form([field("text", 660), field("submit", 360)])]), 7),
            ("欄位停用", snapshot([form([field("text", 300, disabled: true), field("submit", 360)])]), 7),
        ]
        let leaked = refusals.filter { ChatGPTConnectorPod.pairingForm($0.1, publicHost: host, generation: $0.2, viewport: viewport) != nil }.map { $0.0 }
        check(found?.field == NSRect(x: 40, y: 300, width: 380, height: 44) && found?.submit == NSRect(x: 40, y: 360, width: 380, height: 44) && leaked.isEmpty,
              "W183 R10 代填只認這一頁的這一張表單：這台主機、同一份文件、畫面大小對得上、送到這台主機的 POST、剛好一格文字欄＋一顆送出、都在畫面裡；其他一律不填",
              "found=\(String(describing: found)) leaked=\(leaked)")
        var missingNode = good
        missingNode["forms"] = [form([["type": "text", "rect": ["x": 40, "y": 300, "width": 380, "height": 44]], field("submit", 360)])]
        check(found?.elementID == "cef-300" && ChatGPTConnectorPod.pairingForm(missingNode, publicHost: host, generation: 7, viewport: viewport) == nil,
              "W330 代填綁定快照中同一格的 elementID；缺少節點 ID 時拒絕")
    }
}
#endif
