#if DEBUG
import AppKit
import Combine
import SwiftUI

/// `TATWO2_SELFTEST=w184chat` 的 W184 G3c 那一段（使用者 09-30 02:4x 實測 .031：ChatGPT 私訊框和訊息上緣）：
/// - 「chatgpt的展開鈕是多餘的」「左側展開槓也是多餘的」：頂列沒有 ≡、左緣不畫槓（判斷區照舊；VoiceOver 按那一格）。
/// - 「左側展開時會把對話筐推去右邊修正對話筐為不動」：抽屜蓋上、主畫面不動（GlobalDMChatGPTNavigationAcceptance 的 overlayProbe 那一條）。
/// - 「右上隱私對話鈕無效 ui也跟原版不同」：右上＝ChatGPT 的臨時聊天（虛線對話泡泡，Space 同一個圖示）；按了真的開——送出帶臨時旗標
///   （TAP 在網頁自己的送出請求裡帶 history_and_training_disabled，同 ChatGPT Space）、接著問也帶、不叫清單重讀；再按一下關掉回一般的新對話；
///   語音模式在臨時聊天裡不開（它開的是一般對話）。
/// - 「chatgpt duo輸入筐造型r角很醜跟功能鍵也不全」：輸入框跟其他對象同一個玻璃膠囊（同心 40）；模型膠囊回到輸入框；沒有聽寫。
/// - 「文字頂部漸淡應頂天 不是空一節」：訊息列表在頂列底下捲到框的上緣、漸淡在框的上緣；頂列的鈕照舊在上面；捲到最上面時第一則在頂列下面。
/// 用真的 GlobalDMPhoneBox 畫（對話是記憶體裡的假 Pod；抽屜與建議的清單是 ChatGPT Space 那一份，自測環境沒連 ChatGPT＝空的）；
/// 不開網頁、不連外、不叫出主視窗。
extension GlobalDMChatAcceptance {
    @MainActor static func chatGPTG3cChecks(root: URL, model: ChatPageModel, artifacts: URL?, axWorks: Bool) async -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        func check(_ condition: Bool, _ label: String) { results.append((condition, label)) }
        func checkIDs(_ found: Set<String>, has required: Set<String>, lacks forbidden: Set<String> = [], _ label: String) {
            guard axWorks else { return }
            let missing = required.subtracting(found).sorted()
            let extra = forbidden.intersection(found).sorted()
            check(missing.isEmpty && extra.isEmpty,
                  label + (missing.isEmpty ? "" : " — missing \(missing)") + (extra.isEmpty ? "" : " — should not be there \(extra)"))
        }
        func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(25)) }
        }
        // W184 H4 修正第四輪（主導授權改這一段）：下面 (drawn) 那幾條的像素門檻是照 fable5（紙底）調的——先明確選 fable5，
        // 結束（含中途 return）還原；不吃共用存檔裡剛好是什麼（以前別的自測切到一半的 aurora 會讓「開／關」的圖示深色像素差太少）。
        let themeScope = TatwoThemeSelfTestScope()
        themeScope.use(.fable5)
        defer { themeScope.restore() }

        let suite = "ai.tatwo.selftest.w184g3c.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "G3c fixture: defaults suite"); return results }
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ChatGPTModelCatalog(models: [
            TapModel(id: "version:fixture", title: "Latest", detail: "",
                     efforts: [TapEffort(id: "fixture|instant", title: "Instant"), TapEffort(id: "fixture|high", title: "Thinking", level: "High"),
                               TapEffort(id: "fixture|pro", title: "Pro", version: "6", level: "Pro", isMax: true, showsVersion: true)]),
        ], defaultModelID: "version:fixture", defaultEffortID: "fixture|pro", tools: [TapTool(id: "search", title: "網路搜尋", detail: "", rank: 1)])
        let pod = GlobalDMChatGPTComposerPod()
        let tap = ChatGPTTap(transport: pod, connection: .ready)
        let session = ChatGPTConversationSession(tap: tap)
        let store = GlobalDMStore(defaults: defaults, chatGPT: { session }, chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false, recentApps: defaults)
        store.attach(model)
        store.select(.chatGPT)
        store.openFloating()
        let portrait = GlobalDMForm.outerPortrait.size
        func phone(_ form: GlobalDMForm = .outerPortrait, secondary: GlobalDMStore? = nil) -> AnyView {
            AnyView(GlobalDMPhoneBox(store: store, model: model, surface: .floating, form: form, secondary: secondary)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        func sends() -> [[String: Any]] { pod.commands.filter { $0["cmd"] as? String == "send" } }
        // 頂列右上那一顆（上 14、44 見方、右邊留 16）。
        let temporaryRect = CGRect(x: portrait.width - DMPhone.margin - DMPhone.touch, y: DMPhone.headerTop,
                                   width: DMPhone.touch, height: DMPhone.touch)
        // 列表中間那一段（頁面圓鈕右邊、右上那顆左邊），量頂列底下有沒有字。
        let barBand = (x: CGFloat(140), width: portrait.width - 280)

        // MARK: 1、2：頂列沒有 ≡；左緣不畫槓（判斷區照舊；VoiceOver 按那一格）
        var hamburgerInk = 1, edgeGap = 1.0, emptyUnderBar = 1.0, emptyEdge = 1.0
        if let shot = renderSync(phone(), size: portrait) {
            let settled = await settle(shot)
            save(settled, "chatgpt-g3c-main.png", to: artifacts)
            // 以前 ≡ 在頁面圓鈕右邊（x 68–112）：那一塊現在沒有深色的像素。
            hamburgerInk = darkPixels(settled, in: CGRect(x: 70, y: 20, width: 60, height: 32))
            // 以前左緣畫一條 5×44 的淡直把手（x 8.5–13.5、上下置中，黑 20%）：那一條跟旁邊（x 40）一樣亮（平均差不到 0.03；紙紋互相抵掉）。
            let edge = (0..<30).map { luma(settled, x: 11, y: portrait.height / 2 - 30 + CGFloat($0 * 2)) }
            let beside = (0..<30).map { luma(settled, x: 40, y: portrait.height / 2 - 30 + CGFloat($0 * 2)) }
            edgeGap = abs(edge.reduce(0, +) - beside.reduce(0, +)) / Double(edge.count)
            // 基準（沒有訊息）：頂列底下那一條、框的上緣那一條（後面量訊息列表頂天時跟它比）。
            emptyUnderBar = bandDarkness(settled, y: 30, to: 58, x: barBand.x, width: barBand.width)
            emptyEdge = bandDarkness(settled, y: 0, to: 3, x: barBand.x, width: barBand.width)
            checkIDs(identifiers(in: settled), has: ["tatwo.dm.chatgpt.temporary", "tatwo.dm.chatgpt.drawer", "tatwo.dm.model", "tatwo.dm.input"],
                     lacks: ["tatwo.dm.chatgpt.newChat", "tatwo.dm.dictate"],
                     "G3c drawn phone: 臨時聊天 top right; the invisible left edge keeps 「對話清單」 for VoiceOver; the model capsule is in the composer")
            settled.close()
        }
        check(hamburgerInk == 0 && edgeGap < 0.03,
              "G3c (drawn) no ≡ on the top bar and no handle drawn on the left edge (hovering the edge still opens the drawer) "
              + "[≡ dark pixels \(hamburgerInk); edge vs beside \(fmt(edgeGap))] (反例：.031 有 ≡ 和一條灰槓)")
        check(GlobalDMChatGPTDrawerLayout.handleStrip == 22 && !store.isChatGPTDrawerOpen,
              "G3c the left edge (22pt, below the top bar) is still the drawer's hover zone")

        // MARK: 4：右上＝ChatGPT 的臨時聊天（真的開、接著問也帶、再按一下關）
        let updateBefore = tap.conversationUpdate
        let voiceBefore = session.canStartVoice
        store.toggleChatGPTTemporary()
        let onForNew = session.temporary && session.isTemporary && session.conversationID == nil
        let voiceDuring = session.canStartVoice || store.startChatGPTVoice() || session.voice.voiceActive
        var onInk = 0, offInk = 0, onMiddle = 0.0, offMiddle = 0.0
        let middleRect = CGRect(x: 40, y: 150, width: portrait.width - 80, height: portrait.height - 380)
        if let shot = renderSync(phone(), size: portrait) {
            let settled = await settle(shot)
            save(settled, "chatgpt-temporary-on.png", to: artifacts)
            onInk = darkPixels(settled, in: temporaryRect)
            onMiddle = share(settled, in: middleRect) { $0 < 0.6 }
            checkIDs(identifiers(in: settled), has: ["tatwo.dm.chatgpt.temporary", "tatwo.dm.chatgpt.temporaryNote"],
                     lacks: ["tatwo.dm.chatgpt.suggestions"],
                     "G3c drawn 臨時聊天 on: ChatGPT's note (same words as ChatGPT Space) instead of suggestions")
            settled.close()
        }
        store.setDraft("臨時聊天的問題", for: .chatGPT)
        let sentFirst = store.send()
        let first = sends().last ?? [:]
        pod.answer("臨時的回答", conversationID: "c-temp")
        await waitUntil { !session.isSending }
        let rememberedTemp = session.conversationID == "c-temp" && session.temporaryConversationID == "c-temp" && session.isTemporary
        store.setDraft("接著問", for: .chatGPT)
        let sentSecond = store.send()
        let second = sends().last ?? [:]
        pod.answer("接著的回答", conversationID: "c-temp")
        await waitUntil { !session.isSending }
        let quiet = tap.conversationUpdate == updateBefore
        let firstFlagged: Bool = (first["temporary"] as? Bool) == true && first["conversationID"] == nil
        let secondFlagged: Bool = (second["temporary"] as? Bool) == true && (second["conversationID"] as? String) == "c-temp"
        check(onForNew && sentFirst && firstFlagged && rememberedTemp && sentSecond && secondFlagged && quiet,
              "G3c 臨時聊天 really starts ChatGPT's temporary chat: the first send and the follow-up both carry the temporary flag "
              + "(TAP → history_and_training_disabled, the same path as ChatGPT Space's 臨時聊天); it is never announced to the conversation list")
        check(voiceBefore && !voiceDuring,
              "G3c 臨時聊天: voice mode stays off inside it (voice would open a normal, saved conversation); it was available before")
        // 回答中不換（說一句），臨時聊天照舊。
        store.setDraft("回答中按臨時聊天", for: .chatGPT)
        _ = store.send()
        store.toggleChatGPTTemporary()
        let refusedWhileAnswering = session.isTemporary && session.conversationID == "c-temp"
            && store.notice == "ChatGPT 正在回答；等它結束再換對話"
        pod.answer("回答", conversationID: "c-temp")
        await waitUntil { !session.isSending }
        check(refusedWhileAnswering, "G3c while ChatGPT answers, 臨時聊天 does not switch (one sentence why)")
        // 再按一下＝關掉：離開臨時聊天、回到一般的新對話；下一句不帶臨時旗標、會通知清單。
        store.toggleChatGPTTemporary()
        let offToNew = session.conversationID == nil && !session.temporary && !session.isTemporary && session.messages.isEmpty
        if let shot = renderSync(phone(), size: portrait) {
            let settled = await settle(shot)
            save(settled, "chatgpt-temporary-off.png", to: artifacts)
            offInk = darkPixels(settled, in: temporaryRect)
            offMiddle = share(settled, in: middleRect) { $0 < 0.6 }
            checkIDs(identifiers(in: settled), has: ["tatwo.dm.chatgpt.temporary"], lacks: ["tatwo.dm.chatgpt.temporaryNote"],
                     "G3c drawn 臨時聊天 off: no note")
            settled.close()
        }
        store.setDraft("一般的問題", for: .chatGPT)
        _ = store.send()
        let normal = sends().last ?? [:]
        pod.answer("一般的回答", conversationID: "c-normal")
        await waitUntil { !session.isSending }
        let announced = tap.conversationUpdate?.conversationID == "c-normal"
        check(offToNew && normal["temporary"] == nil && announced,
              "G3c 臨時聊天 off: pressing it again leaves the temporary chat for a normal new chat; the next send has no temporary flag and is announced to the list")
        check(offInk > 0 && Double(onInk) > Double(offInk) * 1.15 && onMiddle > offMiddle + 0.002,
              "G3c (drawn) the icon shows the state (solid bubble on a selected circle when on, dashed when off) and the note shows only when on "
              + "[icon dark pixels on \(onInk) off \(offInk); note \(fmt(onMiddle)) vs \(fmt(offMiddle))]")
        // 在一般對話裡按＝開一則新的臨時聊天（原本那則的草稿跟著那一則收著）；新對話時就只是開關。
        store.setDraft("一般那則的草稿", for: .chatGPT)
        store.toggleChatGPTTemporary()
        let fromNormal = session.conversationID == nil && session.isTemporary && store.draft(for: .chatGPT).isEmpty
            && store.chatGPTShelf["c-normal"]?.text == "一般那則的草稿"
        store.toggleChatGPTTemporary()
        let justSwitch = session.conversationID == nil && !session.temporary
        check(fromNormal && justSwitch,
              "G3c 臨時聊天 in a normal conversation opens a new temporary chat (that conversation keeps its draft); on a new chat it is just a switch")

        // MARK: GPT-6 審查 #1：臨時聊天沒確認帶了旗標就回答＝失敗、停下，不當成臨時聊天
        // 假 Pod 模擬網頁走了不加旗標的路（沒有先發「確認」就回答）。反例：以前照本機開關把那一則記成臨時聊天。
        _ = store.newChatGPTConversation()
        store.toggleChatGPTTemporary()
        pod.confirmsTemporary = false
        store.setDraft("沒確認旗標的臨時聊天", for: .chatGPT)
        let unconfirmedSent = store.send()
        let stopsBefore = pod.commands.filter { $0["cmd"] as? String == "stop" }.count
        pod.answer("不該被當成臨時聊天的回答", conversationID: "c-unconfirmed")
        await waitUntil { !session.isSending }
        let failedLoudly: Bool = {
            if case .failed(let reason) = session.state { return reason == ChatGPTTap.temporaryUnconfirmedReason }
            return false
        }()
        let notTemporary = session.temporaryConversationID != "c-unconfirmed" && session.conversationID != "c-unconfirmed"
        let stoppedPage = pod.commands.filter { $0["cmd"] as? String == "stop" }.count > stopsBefore
        pod.confirmsTemporary = true
        check(unconfirmedSent && failedLoudly && notTemporary && stoppedPage,
              "G3c 臨時聊天 unconfirmed: when the page never confirms the flag on the request it actually sent, the DM shows the failure, "
              + "stops the page and never records that conversation as temporary (反例：以前照本機開關當成臨時聊天)")
        _ = store.newChatGPTConversation()
        store.setDraft("", for: .chatGPT)

        // MARK: GPT-6 審查 #2、#3：鍵盤入口（⌘⇧S 抽屜、⌘⇧O 新聊天）；抽屜蓋住輸入框時輸入框不收字、不送出
        let directory = GlobalDMChatGPTFakeDirectory(
            conversations: [TapConversation(id: "c-k1", title: "鍵盤第一則", updatedAt: Date()),
                            TapConversation(id: "c-k2", title: "鍵盤第二則", updatedAt: Date().addingTimeInterval(-60)),
                            TapConversation(id: "c-k3", title: "鍵盤第三則", updatedAt: Date().addingTimeInterval(-120))],
            projects: [], pinned: [], suggestions: [])
        /// 抽屜那一層包著頂列＋ChatGPT 那一欄（同 GlobalDMPhoneBox 的疊法；清單用假的）。
        func drawerPhone() -> AnyView {
            AnyView(GlobalDMChatGPTDrawerHost(store: store, enabled: true, directory: directory) {
                VStack(spacing: 0) {
                    GlobalDMTopBar(store: store, form: .outerPortrait)
                        .environment(\.globalDMChatGPTTopWidth, portrait.width)
                    GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory)
                        .zIndex(-1)
                        .environment(\.globalDMListBleed, DMPhone.headerHeight)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            })
        }
        func key(_ keyCode: UInt16, _ scalar: UInt32, _ flags: NSEvent.ModifierFlags, _ window: NSWindow) -> NSEvent? {
            keyEvent(keyCode, scalar, flags: flags, in: window)
        }
        let keyRig = TatwoComposerModeAcceptance.ClickRig(drawerPhone(), size: portrait)
        await keyRig.settle()
        let window = keyRig.window
        func route(_ event: NSEvent?) -> Bool {
            guard let event else { return false }
            return GlobalDMPanelController.routeChatGPTKeys(event, window: window, store: store, form: .outerPortrait, duo: nil,
                                                             browserHasTabs: false) == nil
        }
        // 只有 ⌘⇧S／⌘⇧O 收；⌘S、⌥⌘S 照原本的路（不撞直達鍵 ⌥⌘＋鍵）。
        let plainS = route(key(1, 0x73, [.command], window)), optionS = route(key(1, 0x73, [.command, .option], window))
        let opened = route(key(1, 0x53, [.command, .shift], window))
        let openedState = store.isChatGPTDrawerOpen && store.chatGPTDrawerPinned && store.chatGPTDrawerKeyboard
        let closed = route(key(1, 0x53, [.command, .shift], window)) && !store.isChatGPTDrawerOpen && !store.chatGPTDrawerKeyboard
        check(!plainS && !optionS && opened && openedState && closed,
              "G3c keyboard: ⌘⇧S opens the ChatGPT conversation list pinned (keyboard focus goes in) and ⌘⇧S again closes it; ⌘S and ⌥⌘S are left alone "
              + "[⌘S \(plainS) ⌥⌘S \(optionS) opened \(opened)/\(openedState) closed \(closed)]")
        // 焦點：輸入框有焦點時按 ⌘⇧S → 焦點進抽屜的搜尋欄；↓↓ Return＝打開第二則、抽屜收起、焦點回輸入框。
        var composerText: NSTextView?
        await waitUntil { composerText = firstTextView(in: keyRig.host); return composerText != nil }
        var focusedIn = false, focusedBack = false, openedSecond = false, escBack = false
        if let composerText {
            _ = window.makeFirstResponder(composerText)
            await keyRig.settle()
            _ = route(key(1, 0x53, [.command, .shift], window))
            focusedIn = await keyRig.wait {
                guard let editor = window.firstResponder as? NSTextView else { return false }
                return editor !== composerText && editor.isFieldEditor
            }
            for code: (UInt16, UInt32) in [(125, 0xF701), (125, 0xF701), (36, 0x0D)] {
                if let event = key(code.0, code.1, [], window) { window.sendEvent(event) }
                await keyRig.settle(2)
            }
            openedSecond = await keyRig.wait { session.conversationID == "c-k2" && !store.isChatGPTDrawerOpen }
            focusedBack = await keyRig.wait { window.firstResponder === composerText }
            // Esc 收起（私訊框的 Esc 路由）也把焦點還給輸入框。
            _ = route(key(1, 0x53, [.command, .shift], window))
            _ = await keyRig.wait { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
            if let esc = key(53, 0x1B, [], window) {
                _ = GlobalDMPanelController.routeEscape(esc, window: window, floating: window, store: store, form: .outerPortrait)
            }
            escBack = await keyRig.wait { !store.isChatGPTDrawerOpen && window.firstResponder === composerText }
        }
        check(focusedIn && openedSecond && focusedBack && escBack,
              "G3c keyboard: with the input focused, ⌘⇧S moves focus into the list's search field; ↓↓ Return opens the second conversation "
              + "and focus returns to the input; Esc closes it and returns focus too [in \(focusedIn) second \(openedSecond) back \(focusedBack) esc \(escBack)]")
        // ⌘⇧O＝新聊天（在一則對話裡）；對象不是 ChatGPT、輸入法組字中都不收。
        let newChat = route(key(31, 0x4F, [.command, .shift], window)) && session.conversationID == nil
        var composingLeftAlone = false
        if let composerText {
            _ = window.makeFirstResponder(composerText)
            composerText.setMarkedText("ㄋ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            composingLeftAlone = !route(key(1, 0x53, [.command, .shift], window)) && !store.isChatGPTDrawerOpen && composerText.hasMarkedText()
            composerText.unmarkText()
            store.setDraft("", for: .chatGPT)
        }
        store.select(.assistant)
        let otherTargetLeftAlone = !route(key(1, 0x53, [.command, .shift], window)) && !store.isChatGPTDrawerOpen
        store.select(.chatGPT)
        await keyRig.settle()
        check(newChat && composingLeftAlone && otherTargetLeftAlone,
              "G3c keyboard: ⌘⇧O starts a new chat; while the input method is composing, or the target is not ChatGPT, ⌘⇧S is left alone "
              + "[new \(newChat) composing \(composingLeftAlone) other target \(otherTargetLeftAlone)]")

        // 抽屜蓋住輸入框（滑鼠指到左緣打開）：Return 不送、打字不進去；組字中不搶焦點（候選字不丟），選完字才撤；收起時焦點與草稿都回來。
        await waitUntil { composerText = firstTextView(in: keyRig.host); return composerText != nil }
        var returnRefused = false, typingRefused = false, blurred = false, restored = false, keptComposing = false, blurredAfterCommit = false
        if let composerText {
            store.setDraft("蓋住的草稿", for: .chatGPT)
            _ = window.makeFirstResponder(composerText)
            await keyRig.settle()
            let sendsBefore = sends().count
            store.openChatGPTDrawer(pinned: false)
            // 抽屜剛打開、焦點還沒撤的那一下按 Return：送出入口擋下（反例：以前照樣送出）。
            if let enter = key(36, 0x0D, [], window) { window.sendEvent(enter) }
            await keyRig.settle(2)
            returnRefused = sends().count == sendsBefore && store.draft(for: .chatGPT) == "蓋住的草稿"
            blurred = await keyRig.wait { window.firstResponder !== composerText }
            let nativeScroll = composerText.enclosingScrollView
            check(composerText.isAccessibilityHidden() && !composerText.isAccessibilityElement()
                  && nativeScroll?.isAccessibilityHidden() == true && nativeScroll?.contentView.isAccessibilityHidden() == true,
                  "W193 drawer: the native text area, scroll container and clip view are hidden from accessibility")
            if let shot = keyRig.capture() {
                print("W193 AX drawer open identifiers: \(identifiers(in: shot).sorted())")
                // VoiceOver：抽屜開著時底下被蓋住的（輸入框）不在無障礙樹裡（這個環境建不出無障礙樹就略過，node 釘原始碼）。
                checkIDs(identifiers(in: shot), has: ["tatwo.dm.chatgpt.drawer.panel"], lacks: ["tatwo.dm.input", "tatwo.dm.send"],
                         "G3c drawer over the input: VoiceOver sees the drawer, not the covered input")
                // 反例：同一個抽屜仍開著，只撤掉原生 hidden，舊的漏出來的輸入框必須抓得到。
                composerText.setAccessibilityHidden(false)
                nativeScroll?.setAccessibilityHidden(false)
                nativeScroll?.contentView.setAccessibilityHidden(false)
                check(identifiers(in: shot).contains("tatwo.dm.input"),
                      "W193 counterexample: without native hiding the covered input is still exposed")
                composerText.setAccessibilityHidden(true)
                nativeScroll?.setAccessibilityHidden(true)
                nativeScroll?.contentView.setAccessibilityHidden(true)
            }
            if let letter = key(0, 0x61, [], window) { window.sendEvent(letter) }
            await keyRig.settle(2)
            typingRefused = store.draft(for: .chatGPT) == "蓋住的草稿"
            store.closeChatGPTDrawer()
            restored = await keyRig.wait { window.firstResponder === composerText } && store.draft(for: .chatGPT) == "蓋住的草稿"
            check(!composerText.isAccessibilityHidden() && composerText.isAccessibilityElement()
                  && nativeScroll?.isAccessibilityHidden() == false && nativeScroll?.contentView.isAccessibilityHidden() == false,
                  "W193 drawer closed: the native input and its containers return to accessibility")
            if let shot = keyRig.capture() {
                checkIDs(identifiers(in: shot), has: ["tatwo.dm.input", "tatwo.dm.send"],
                         "W193 drawer closed: VoiceOver can read the input and send control again")
            }
            // 組字中打開抽屜：焦點不撤、候選字還在；字選完（確定）才撤。
            composerText.setMarkedText("ㄋ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            store.openChatGPTDrawer(pinned: false)
            try? await Task.sleep(for: .milliseconds(300))
            await keyRig.settle(2)
            keptComposing = window.firstResponder === composerText && composerText.hasMarkedText()
            composerText.unmarkText()
            blurredAfterCommit = await keyRig.wait { window.firstResponder !== composerText }
            store.closeChatGPTDrawer()
            _ = await keyRig.wait { window.firstResponder === composerText }
            store.setDraft("", for: .chatGPT)
        }
        check(returnRefused && typingRefused && blurred && restored,
              "G3c drawer over the input: Return in the covered input sends nothing and typing goes nowhere (the input lets go of the keyboard); "
              + "closing it gives focus and the draft back [return \(returnRefused) typing \(typingRefused) blurred \(blurred) restored \(restored)] (反例：以前照樣送出)")
        check(keptComposing && blurredAfterCommit,
              "G3c drawer while composing: the input keeps focus and its candidate until the text is committed, then lets go "
              + "[kept \(keptComposing) after commit \(blurredAfterCommit)]")
        keyRig.close()

        // MARK: 5：輸入框＝其他對象的玻璃膠囊（同心 40）；功能鍵照 ChatGPT Space（模型膠囊回來、沒有聽寫）
        let composerSize = CGSize(width: portrait.width, height: 170)
        let assistantSuite = "ai.tatwo.selftest.w184g3c.assistant.\(UUID().uuidString)"
        if let assistantDefaults = UserDefaults(suiteName: assistantSuite) {
            let assistant = GlobalDMStore(defaults: assistantDefaults, chatGPTAllowed: { true }, directKeys: false, recentApps: assistantDefaults)
            assistant.attach(model)
            assistant.select(.assistant)
            func composer(_ target: GlobalDMStore, placeholder: String) -> AnyView {
                AnyView(GlobalDMComposer(store: target, placeholder: placeholder, isRunning: false, canSend: true,
                                         chatGPTSession: target === store ? session : nil)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .background(Color(nsColor: .windowBackgroundColor)))
            }
            var chatGPTShot: Rendered?, assistantShot: Rendered?
            if let shot = renderSync(composer(store, placeholder: "問問 ChatGPT"), size: composerSize) {
                chatGPTShot = await settle(shot)
            }
            if let shot = renderSync(composer(assistant, placeholder: "問助理任何事…"), size: composerSize) {
                assistantShot = await settle(shot)
            }
            if let chatGPTShot, let assistantShot {
                save(chatGPTShot, "chatgpt-composer-g3c.png", to: artifacts)
                save(assistantShot, "assistant-composer-g3c.png", to: artifacts)
                // 左下角那一小塊（＋ 下面、貼著框邊的圓角）：兩個對象的輸入框畫出來一樣（同一個玻璃膠囊、同一個圓角）。
                var total = 0.0, samples = 0
                for y in stride(from: composerSize.height - 20, to: composerSize.height - 12, by: 1) {
                    for x in stride(from: CGFloat(12), to: 30, by: 1) {
                        total += abs(luma(chatGPTShot, x: x, y: y) - luma(assistantShot, x: x, y: y))
                        samples += 1
                    }
                }
                let cornerDiff = total / Double(max(1, samples))
                // 膠囊在輸入框下排、語音模式鈕左邊（右緣＝框寬 − 12 − 12 − 36 − 8；「6 Pro ⌄」的字，量到放大鏡右邊為止）。
                let capsuleInk = darkPixels(chatGPTShot, in: CGRect(x: composerSize.width - 150, y: composerSize.height - 54, width: 80, height: 28))
                check(cornerDiff < 0.02 && capsuleInk > 6 && GlobalDMChatLayout.composerRadius == DMPhone.screenRadius - DMPhone.edgeInset,
                      "G3c (drawn) the ChatGPT composer is the same glass capsule as the other targets (corner 52 − 12 = 40, concentric) "
                      + "with the model capsule back in its bottom row [corner diff \(fmt(cornerDiff)); capsule dark pixels \(capsuleInk)] (反例：.031 是實心灰底)")
                checkIDs(identifiers(in: chatGPTShot), has: ["tatwo.dm.attach", "tatwo.dm.webSearch", "tatwo.dm.model", "tatwo.dm.voice", "tatwo.dm.input"],
                         lacks: ["tatwo.dm.dictate"],
                         "G3c drawn ChatGPT composer keys like ChatGPT Space's: ＋, search, model capsule, voice mode (no dictation)")
                check(inputPointSizes(in: chatGPTShot.host) == [ChatGPTComposerMetrics.space.inputText],
                      "G3c the composer text stays ChatGPT Space's 15 [\(inputPointSizes(in: chatGPTShot.host))]")
            } else {
                check(false, "G3c fixture: the two composers render")
            }
            chatGPTShot?.close()
            assistantShot?.close()
            assistant.close()
            assistantDefaults.removePersistentDomain(forName: assistantSuite)
        } else {
            check(false, "G3c fixture: assistant defaults suite")
        }

        // MARK: 6：訊息列表頂天（所有對象同一個列表；在頂列底下捲到框的上緣、漸淡在框的上緣）
        // 每一張都跟「同一個畫面、沒有訊息」比（基準），量多出來的深色：頂列底下那一條（y 30–58）要多、框的上緣（y 0–3）只多一點點（淡掉了）。
        // 自己的訊息（深色泡泡，量得出頂列底下有沒有字）＋最後一則回答。
        let long = (0..<14).map { index -> [String: Any] in
            ["id": "m\(index)", "role": "user", "text": String(repeating: "很長的一段自己的訊息。", count: 5 + index % 3) + "#\(index)"]
        } + [["id": "m14", "role": "assistant", "text": "好的，照這個順序做。"]]
        pod.getOverrides["c-long"] = long
        let landscape = GlobalDMForm.innerLandscape.size
        let leftWidth = GlobalDMPhoneLook(form: .innerLandscape, slide: nil, size: landscape).chatWidth(in: landscape.width)
        let leftBand = (x: CGFloat(100), width: leftWidth - 140)
        let rightBand = (x: leftWidth + 60, width: landscape.width - leftWidth - 160)
        let rightSuite = "ai.tatwo.selftest.w184g3c.right.\(UUID().uuidString)"
        let rightDefaults = UserDefaults(suiteName: rightSuite)
        let rightSession = ChatGPTConversationSession(tap: tap)
        var right: GlobalDMStore?
        if let rightDefaults {
            let made = GlobalDMStore(defaults: rightDefaults, chatGPT: { rightSession }, chatGPTAllowed: { true },
                                     chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false, recentApps: rightDefaults)
            made.attach(model)
            made.select(.chatGPT)
            made.openFloating()
            right = made
        }
        // 內橫的基準：兩欄都是新對話（沒有訊息）。
        // 數深色像素（泡泡是深色的）：頂列底下那一條（y 26–62）、框的上緣那一條（y 0–4）。
        func duoCounts(_ rendered: Rendered) -> (left: Int, right: Int, rightEdge: Int) {
            (darkPixels(rendered, in: CGRect(x: leftBand.x, y: 26, width: leftBand.width, height: 36)),
             darkPixels(rendered, in: CGRect(x: rightBand.x, y: 26, width: rightBand.width, height: 36)),
             darkPixels(rendered, in: CGRect(x: rightBand.x, y: 0, width: rightBand.width, height: 4)))
        }
        var duoBase: (left: Int, right: Int, rightEdge: Int)?
        if let right, let shot = renderSync(phone(.innerLandscape, secondary: right), size: landscape) {
            let settled = await settle(shot)
            duoBase = duoCounts(settled)
            settled.close()
        }
        _ = store.openChatGPTConversation("c-long")
        await waitUntil { session.loadState == .loaded && session.messages.count == long.count }
        GlobalDMMessageList.rowTopsForSelfTest = [:]
        if let shot = renderSync(phone(), size: portrait) {
            let settled = await settle(shot)
            save(settled, "chatgpt-top-fade.png", to: artifacts)
            let under = bandDarkness(settled, y: 30, to: 58, x: barBand.x, width: barBand.width) - emptyUnderBar
            let edge = bandDarkness(settled, y: 0, to: 3, x: barBand.x, width: barBand.width) - emptyEdge
            let middle = bandDarkness(settled, y: portrait.height / 2 - 60, to: portrait.height / 2 + 60, x: barBand.x, width: barBand.width)
            check(abs(under) < 0.02 && abs(edge) < 0.02 && middle > 0.08,
                  "W194 (drawn) messages reserve the floating top bar while the conversation body stays visible "
                  + "[more ink under the bar \(fmt(under)); at the top edge \(fmt(edge)); middle \(fmt(middle))] "
                  + "(反例：文字進入浮動頭像區域)")
            // 頂列在上面一層：頂列空白處點到的是頂列的拖曳區（不是底下捲過去的列表）；右上臨時聊天那一顆點到的不是列表。
            let barHit = hitView(settled, x: portrait.width / 2 + 70, y: 40)
            let buttonHit = hitView(settled, x: temporaryRect.midX, y: temporaryRect.midY)
            let listHit = hitView(settled, x: portrait.width / 2, y: portrait.height / 2)
            let host = settled.host
            // GPT-6 審查 #5：點到的是 nil 不算過（以前 involves(nil) 回 false，被當成「不是列表」）。
            check(barHit != nil && buttonHit != nil && listHit != nil
                  && involves(barHit, GlobalDMBoxGripView.self, root: host) && !involves(barHit, NSScrollView.self, root: host)
                  && !involves(buttonHit, NSScrollView.self, root: host) && !involves(listHit, GlobalDMBoxGripView.self, root: host),
                  "G3c the top bar stays on top: its empty part is still the drag area and 臨時聊天 is not under the list "
                  + "[bar \(name(barHit)); button \(name(buttonHit)); list \(name(listHit))]")
            // 捲到最上面：第一則在頂列下面（上面留了頂列那一段＋上 10），不被頂列蓋住、也不淡。
            // 捲上去時 ChatGPT 那幾則才量出真的高度（列表會照最底對齊重排一次）：捲到最上面、等畫面穩定，最多試 5 次。
            if let scroll = scrollView(in: settled.host) {
                let expected = GlobalDMChatLayout.listTop + DMPhone.headerHeight
                var top = settled
                var firstTop: CGFloat?
                let inset = max(scroll.contentInsets.top, scroll.contentView.contentInsets.top)
                for _ in 0..<5 {
                    let clip = scroll.contentView
                    let flipped = scroll.documentView?.isFlipped ?? true
                    let height = scroll.documentView?.bounds.height ?? 0
                    clip.scroll(to: NSPoint(x: 0, y: flipped ? -inset : max(0, height - clip.bounds.height)))
                    scroll.reflectScrolledClipView(clip)
                    top = await settle(settled)
                    firstTop = GlobalDMMessageList.rowTopsForSelfTest["m0"]
                    if let value = firstTop, abs(value - GlobalDMChatLayout.listTop) <= 2 { break }
                }
                save(top, "chatgpt-top-scrolled.png", to: artifacts)
                let strength = GlobalDMMessageList.fadeStrength(rowMinY: GlobalDMChatLayout.listTop, rowMaxY: GlobalDMChatLayout.listTop + 40, viewport: 600, isFirst: true, isLast: false)
                let clearUnder = bandDarkness(top, y: 30, to: 58, x: barBand.x, width: barBand.width) - emptyUnderBar
                let scrollRect = scroll.convert(scroll.bounds, to: top.host)
                let viewportTop = top.host.isFlipped ? scrollRect.minY : portrait.height - scrollRect.maxY
                let physicalFirstTop = firstTop.map { viewportTop + $0 }
                let firstBelowBar = physicalFirstTop.map { abs($0 - expected) <= 2 } ?? false
                check(firstBelowBar && strength.top == 0 && abs(clearUnder) < 0.02,
                      "G3c scrolled to the top: the first message starts below the top bar (at \(physicalFirstTop.map { Int($0) } ?? -1) from the box's top, expected \(Int(expected))), "
                      + "not covered and not faded [ink under the bar \(fmt(clearUnder)); scroll view top inset \(Int(inset))]")
            } else {
                check(false, "G3c fixture: the message list's scroll view")
            }
            settled.close()
        }
        // W194：四種形態都用真實 viewport 的位置量第一行，不把文件座標當螢幕座標。
        for form in GlobalDMForm.allCases {
            guard let shot = renderSync(phone(form), size: form.size) else { check(false, "W194 \(form.rawValue) renders"); continue }
            let settled = await settle(shot)
            defer { settled.close() }
            if form == .tent {
                check(scrollView(in: settled.host) == nil, "W194 tent has no conversation text beneath the portrait")
                save(settled, "w194-header-tent.png", to: artifacts)
                continue
            }
            guard let scroll = scrollView(in: settled.host) else { check(false, "W194 \(form.rawValue) viewport exists"); continue }
            let rect = scroll.convert(scroll.bounds, to: settled.host)
            let top = settled.host.isFlipped ? rect.minY : form.size.height - rect.maxY
            check(top >= DMPhone.headerHeight - 2, "W194 \(form.rawValue) viewport avoids the floating portrait [top \(Int(top))]")
            save(settled, "w194-header-\(form.rawValue).png", to: artifacts)
        }
        // GPT-6 審查 #5：頂列的臨時聊天真的點得到——真的滑鼠事件（按下、放開，排進 App 的事件佇列）點右上那一顆，臨時的狀態真的變了、
        // 再點一下變回來；反例：頂列上蓋一層透明遮罩，同樣的點擊不會改變狀態（這一條測試真的抓得到點不到的鈕）。內橫右欄在下面內橫那一段驗。
        /// 點那一顆（框的座標，左上原點），回（變了沒、再點一下變回來了沒）。
        func pressTemporary(_ view: AnyView, size: CGSize, at point: CGPoint, of target: ChatGPTConversationSession) async -> (toggled: Bool, back: Bool) {
            let rig = TatwoComposerModeAcceptance.ClickRig(view, size: size)
            defer { rig.close() }
            await rig.settle()
            let before = target.isTemporary
            let spot = NSPoint(x: point.x, y: size.height - point.y)
            await rig.click(spot)
            let toggled = await rig.wait { target.isTemporary != before }
            guard toggled else { return (false, false) }
            let asksWithoutConsent = rig.has(TatwoComposerModeClickAwayView.self) && !target.temporaryPersonalized
            if let shot = rig.capture() {
                save(shot, size == portrait ? "g3c-choice-portrait.png" : "g3c-choice-right.png", to: artifacts)
            }
            await rig.click(spot)
            let back = await rig.wait { target.isTemporary == before }
            return (asksWithoutConsent, back && !target.temporaryPersonalized && !rig.has(TatwoComposerModeClickAwayView.self))
        }
        _ = store.newChatGPTConversation()
        let buttonCenter = CGPoint(x: temporaryRect.midX, y: temporaryRect.midY)
        let leftPress = await pressTemporary(phone(), size: portrait, at: buttonCenter, of: session)
        let masked = AnyView(phone().overlay {
            Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture {}   // 看不見、會吃掉點擊的一層
        })
        let maskedPress = await pressTemporary(masked, size: portrait, at: buttonCenter, of: session)
        check(leftPress.toggled && leftPress.back && !maskedPress.toggled,
              "G3c (clicked) the top bar's 臨時聊天 really takes a mouse click: it turns on and a second click turns it off; "
              + "with a transparent mask over it the same click changes nothing, so this test does catch an unclickable button "
              + "[on \(leftPress.toggled) off \(leftPress.back); masked \(maskedPress.toggled)]")

        // 選擇卡也真的可點；同意只屬於這一則，關掉再開絕不沿用。
        let choiceRig = TatwoComposerModeAcceptance.ClickRig(phone().environment(\.dmFrameProbes, true), size: portrait)
        await choiceRig.settle()
        let choiceSpot = NSPoint(x: buttonCenter.x, y: portrait.height - buttonCenter.y)
        await choiceRig.click(choiceSpot)
        let defaultPrivate = session.isTemporary && !session.temporaryPersonalized
        if let allow = DMBrowserPhoneAcceptance.probeFrame("temporary.allow", in: choiceRig.host) {
            await choiceRig.click(NSPoint(x: allow.midX, y: allow.midY))
        }
        let allowed = session.isTemporary && session.temporaryPersonalized && !choiceRig.has(TatwoComposerModeClickAwayView.self)
        await choiceRig.click(choiceSpot)
        let cleared = !session.isTemporary && !session.temporaryPersonalized
        await choiceRig.click(choiceSpot)
        let asksAgain = session.isTemporary && !session.temporaryPersonalized && choiceRig.has(TatwoComposerModeClickAwayView.self)
        if let keep = DMBrowserPhoneAcceptance.probeFrame("temporary.keep", in: choiceRig.host) {
            await choiceRig.click(NSPoint(x: keep.midX, y: keep.midY))
        }
        let kept = session.isTemporary && !session.temporaryPersonalized && !choiceRig.has(TatwoComposerModeClickAwayView.self)
        check(defaultPrivate && allowed && cleared && asksAgain && kept,
              "G3c (clicked) personalization requires the explicit choice for each new temporary chat; keeping unpersonalized never grants consent "
              + "[default \(defaultPrivate) allow \(allowed) cleared \(cleared) asksAgain \(asksAgain) keep \(kept)]")
        await choiceRig.click(choiceSpot)
        choiceRig.close()

        // 短的訊息（一行的泡泡約 41 高＋間距 18）：整則捲到頂列底下的也要畫（不是只畫壓在頂列下緣的那一則）——
        // 捲動區座標（框的上緣＝0）裡 −41～27 這一段一定有一則的開頭（每 59 一則），它要有量到位置，頂列底下看得到字（泡泡靠右）。
        let short = (0..<40).map { index -> [String: Any] in ["id": "s\(index)", "role": "user", "text": "短訊息 \(index)"] }
        pod.getOverrides["c-short"] = short
        _ = store.openChatGPTConversation("c-short")
        await waitUntil { session.loadState == .loaded && session.messages.count == short.count }
        GlobalDMMessageList.rowTopsForSelfTest = [:]
        if let shot = renderSync(phone(), size: portrait) {
            let settled = await settle(shot)
            save(settled, "chatgpt-top-short.png", to: artifacts)
            let bubble = GlobalDMChatLayout.userLineHeight + GlobalDMChatLayout.userBubbleVerticalPadding * 2
            let whollyAbove = GlobalDMMessageList.rowTopsForSelfTest.values.filter { $0 > -bubble && $0 <= DMPhone.headerHeight - bubble }
            let underDark = darkPixels(settled, in: CGRect(x: portrait.width - 136, y: 12, width: 70, height: 54))
            let visibleShort = darkPixels(settled, in: CGRect(x: portrait.width - 136, y: 100, width: 70, height: 150))
            check(!whollyAbove.isEmpty && underDark == 0 && visibleShort > 0,
                  "W194 (drawn) short rows scrolling out of the viewport never paint over the floating avatar "
                  + "[rows wholly above: \(whollyAbove.map { Int($0) }); dark pixels under the bar \(underDark)]")
            settled.close()
        }
        // 內橫：左欄、右欄（另一個 ChatGPT）的列表都延伸到框的上緣（一條頂列跨兩欄）；右欄自己那一排臨時聊天蓋在它的列表上。
        if let right {
            _ = right.openChatGPTConversation("c-long")
            await waitUntil { rightSession.loadState == .loaded && rightSession.messages.count == long.count }
            if let duoBase, let shot = renderSync(phone(.innerLandscape, secondary: right), size: landscape) {
                let settled = await settle(shot)
                save(settled, "chatgpt-duo-top-fade.png", to: artifacts)
                let counts = duoCounts(settled)
                let leftUnder = counts.left - duoBase.left, rightUnder = counts.right - duoBase.right
                let rightEdge = counts.rightEdge - duoBase.rightEdge
                let leftBody = darkPixels(settled, in: CGRect(x: leftBand.x, y: 180, width: leftBand.width, height: 100))
                let rightBody = darkPixels(settled, in: CGRect(x: rightBand.x, y: 180, width: rightBand.width, height: 100))
                check(abs(leftUnder) < 5 && abs(rightUnder) < 5 && abs(rightEdge) < 5 && leftBody > 50 && rightBody > 50,
                      "W194 (drawn) 內橫: both columns reserve the shared floating top bar and retain visible conversation bodies "
                      + "[more dark pixels under the bar: left +\(leftUnder), right +\(rightUnder); right top edge +\(rightEdge)]")
                checkIDs(identifiers(in: settled), has: ["tatwo.dm.chatgpt.trailingBar", "tatwo.dm.chatgpt.temporary"],
                         "G3c drawn 內橫 right column: its own 臨時聊天 over its list")
                settled.close()
            } else {
                check(false, "G3c fixture: the 內橫 phone renders")
            }
            // GPT-6 審查 #5：內橫右欄自己那一顆也真的點（右欄那一排：上 10、44 見方、右邊留 20，在頂列 68 下面）：變的是右欄那一則，左欄不動。
            _ = right.newChatGPTConversation()
            let leftBefore = session.isTemporary
            let rightButton = CGPoint(x: landscape.width - DMPhone.wideMargin - DMPhone.touch / 2,
                                      y: DMPhone.headerHeight + DMPhone.headerBottom + DMPhone.touch / 2)
            let rightPress = await pressTemporary(phone(.innerLandscape, secondary: right), size: landscape, at: rightButton, of: rightSession)
            check(rightPress.toggled && rightPress.back && session.isTemporary == leftBefore,
                  "G3c (clicked) 內橫 right column: its own 臨時聊天 takes a real click and changes the right column's chat only "
                  + "[on \(rightPress.toggled) off \(rightPress.back); left unchanged \(session.isTemporary == leftBefore)]")
            right.close()
        } else {
            check(false, "G3c fixture: right column defaults suite")
        }
        rightDefaults?.removePersistentDomain(forName: rightSuite)
        // 助理、session 的對話同一個列表：手機框給它頂列的高度，一樣延伸到框的上緣（這裡只畫頂列＋對話窗格，疊法同 GlobalDMPhoneBox；
        // 手機框給每一欄這個值在上面那張真的 GlobalDMPhoneBox 已經量過）。
        let threadSuite = "ai.tatwo.selftest.w184g3c.thread.\(UUID().uuidString)"
        if let threadDefaults = UserDefaults(suiteName: threadSuite) {
            let thread = GlobalDMStore(defaults: threadDefaults, chatGPTAllowed: { true }, directKeys: false, recentApps: threadDefaults)
            thread.attach(model)
            thread.select(.assistant)
            let bubbles = GlobalDMBubble.rows((0..<14).map { index in
                ChatMessage(id: "t\(index)", role: .user, text: String(repeating: "問助理的一段話。", count: 6 + index % 3))
            } + [ChatMessage(id: "t14", role: .assistant, text: "收到，我來排。")])
            func threadPhone(_ rows: [GlobalDMBubble]) -> AnyView {
                AnyView(VStack(spacing: 0) {
                    GlobalDMTopBar(store: thread, form: .outerPortrait)
                    GlobalDMThreadPane(store: thread, bubbles: rows, emptyText: "", placeholder: "問助理任何事…")
                        .zIndex(-1)
                        .environment(\.globalDMListBleed, DMPhone.headerHeight)
                }
                .background(Color(nsColor: .windowBackgroundColor)))
            }
            // 助理、session 的泡泡是淺色底＋深色字：數頂列底下那一條的深色字像素（沒有訊息時是 0）、框的上緣那一條（淡掉＝幾乎沒有）。
            var base: (under: Int, edge: Int)?
            if let shot = renderSync(threadPhone([]), size: portrait) {
                let settled = await settle(shot)
                base = (darkPixels(settled, in: CGRect(x: barBand.x, y: 26, width: barBand.width, height: 36)),
                        darkPixels(settled, in: CGRect(x: barBand.x, y: 0, width: barBand.width, height: 4)))
                settled.close()
            }
            if let base, let shot = renderSync(threadPhone(bubbles), size: portrait) {
                let settled = await settle(shot)
                save(settled, "assistant-top-fade.png", to: artifacts)
                let under = darkPixels(settled, in: CGRect(x: barBand.x, y: 26, width: barBand.width, height: 36)) - base.under
                let edge = darkPixels(settled, in: CGRect(x: barBand.x, y: 0, width: barBand.width, height: 4)) - base.edge
                let bodyInk = darkPixels(settled, in: CGRect(x: barBand.x, y: 180, width: barBand.width, height: 100))
                check(abs(under) < 5 && abs(edge) < 5 && bodyInk > 20,
                      "W194 (drawn) assistant／session conversations also reserve the floating header with visible text below "
                      + "[dark text pixels under the bar +\(under); at the top edge +\(edge)]")
                settled.close()
            } else {
                check(false, "G3c fixture: the assistant conversation renders")
            }
            thread.close()
            threadDefaults.removePersistentDomain(forName: threadSuite)
        } else {
            check(false, "G3c fixture: thread defaults suite")
        }

        _ = store.newChatGPTConversation()
        store.close()
        return results
    }

    /// 一塊橫條（y 從 from 到 to、x 從 x 起 width 寬）平均多暗（0＝白、1＝黑），每 2 點取一個。
    @MainActor static func bandDarkness(_ rendered: Rendered, y from: CGFloat, to: CGFloat, x: CGFloat, width: CGFloat) -> Double {
        var total = 0.0, count = 0
        for y in stride(from: from, to: to, by: 2) {
            for dx in stride(from: CGFloat(0), to: width, by: 2) {
                total += 1 - luma(rendered, x: x + dx, y: y)
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    /// 一塊區域（單位點）裡逐一看每個像素（照螢幕倍率），比門檻暗的有幾個（細的線、小字也數得到）。
    @MainActor static func darkPixels(_ rendered: Rendered, in rect: CGRect, below threshold: Double = 0.45) -> Int {
        let rep = rendered.bitmap
        let scale = CGFloat(rep.pixelsWide) / rendered.size.width
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(rep.pixelsHigh, Int(rect.maxY * scale))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if Double(color.redComponent + color.greenComponent + color.blueComponent) / 3 < threshold { count += 1 }
            }
        }
        return count
    }

    /// 畫面裡有東西（不是白底：黑字、灰字、紫字都算）的範圍有多寬（點）。
    @MainActor static func inkWidth(_ rendered: Rendered, below threshold: Double = 0.85) -> CGFloat {
        let rep = rendered.bitmap
        var minX = Int.max, maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      Double(color.redComponent + color.greenComponent + color.blueComponent) / 3 < threshold else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= 0 else { return 0 }
        return CGFloat(maxX - minX + 1) / (CGFloat(rep.pixelsWide) / rendered.size.width)
    }

    /// 畫面上某一點（左上原點、單位點）點下去是哪一個 view（同 AppKit 送滑鼠事件前的 hitTest）。
    @MainActor static func hitView(_ rendered: Rendered, x: CGFloat, y: CGFloat) -> NSView? {
        let host = rendered.host
        let local = NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y)
        return host.hitTest(host.superview.map { host.convert(local, to: $0) } ?? local)
    }

    /// 點到的那個 view、它往上的每一層、或（不是整個畫面本身時）它底下兩層裡有沒有這一類（SwiftUI 會把 AppKit 的 view 包一層）。
    @MainActor static func involves(_ view: NSView?, _ type: AnyClass, root: NSView) -> Bool {
        guard let view else { return false }
        var current: NSView? = view
        while let candidate = current {
            if candidate.isKind(of: type) { return true }
            current = candidate.superview
        }
        guard view !== root else { return false }
        return view.subviews.contains { child in child.isKind(of: type) || child.subviews.contains { grandchild in grandchild.isKind(of: type) } }
    }

    @MainActor static func name(_ view: NSView?) -> String { view.map { String(describing: type(of: $0)) } ?? "nil" }

    /// 畫面裡內容最長、放不下要捲的那個捲動區（訊息列表）。
    @MainActor static func scrollView(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ node: NSView) {
            if let scroll = node as? NSScrollView { found.append(scroll) }
            node.subviews.forEach(walk)
        }
        walk(view)
        return found.filter { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
    }
}
#endif
