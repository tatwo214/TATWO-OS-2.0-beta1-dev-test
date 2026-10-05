#if DEBUG
import AppKit
import Combine
import Foundation
import SwiftUI
import TatwoCEFBridge
import UniformTypeIdentifiers

// W183 R9 自測（w183browser；記憶體替身，不開網頁、不碰真的 Pod）：原生 ChatGPT Space「外掛」頁的「新增 ▾」。
// - 三項各自：Pod 的畫面開成私訊框 Browser 的「ChatGPT Dev」分頁、送出 pluginNewMenu（那一項＋一次性操作序號＋Pod 的鑰匙），
//   指令只帶這幾樣（沒有網址、名稱、勾選）＝只把網頁的對話框打開，不填、不勾、不按 Create（網頁那一端在 tests/w183-connect.test.mjs
//   用假頁面跑真的 Pod 腳本）。
// - Pod 找不到那一項、私訊框正在連 TATWO、正在回答、語音中、私訊鈕關著、還沒登入：原生頁一句話（不是代號），不送或不做。
// W183 R9 審查（GPT-6 #3、#8、#9、#10、#11；Claude #4、#7、#8、#9）：
// - Pod 的操作租約：對話框交給使用者之後照樣拿著；聊天送出先排隊、語音與連線流程拿不到（雙向）；分頁關掉、私訊框收起來、網頁的對話框關了、
//   網頁換了一份、Pod 關了、逾時＝放掉（先送撤銷）。回覆比取消晚到＝不理。
// - 每一個指令都帶這個 Pod 的鑰匙；keyedPodScript 換不掉佔位字＝不開。
// - 只給人用的檔案選擇器：只在受保護的呈現、看得到、人在用時開；一次一個；取消／世代；結果只交一次。
// W183 R9 審查（GPT-6 N7、N8）：
// - 從拿到租約起就看：等 Pod 回覆（網頁選單延遲掛載）的時候收起私訊框、網頁換了一份＝回覆之前就撤銷、放掉 Pod；晚到的回覆不理。
//   選檔視窗開著的時候網頁換了一份＝照樣放掉（世代不被「選檔中」跳過）。
// - CEF 的 onWebFeaturesInvalidated 真的接到 Pod 的檔案選擇器（假的宿主走 TapWebPod.wireWebFeatures）：sheet 取消、回覆結清剛好一次、
//   晚到的選檔結果不交、「新增」那一次結束（撤銷、放掉租約）；拆掉之後兩條回呼都是 nil。
// - 畫面：照 BotUIAcceptance 的方式畫出外掛頁標題列與「新增」選單（PNG 存到 TATWO2_SELFTEST_ARTIFACTS），
//   驗右上是玻璃 chip、沒有藍色、三項＋一行提示；用 accessibilityIdentifier「chatgpt.plugins.new.<item>」真的按三項。

extension DMBrowserAcceptance {
    /// 記憶體裡的 Pod 傳輸：記下送出的指令，照設定的結果回（send／regenerate 不回＝正在回答）。
    @MainActor final class MenuTransport: ChatGPTPodTransport {
        var onEvent: ((String) -> Void)?
        var isRunning = true
        var isHosted = false
        /// pluginNewMenu 的回覆、晚多久回（秒）。
        var reply: [String: Any] = ["status": "opened"]
        var replyDelay: Double = 0
        /// pluginNewMenuWatch：網頁的對話框還開著嗎、網頁還認得這一次嗎（false＝換了一份）。
        var dialogOpen = true
        var pageKnows = true
        /// 其他指令的回覆（例如 voice）。
        var answers: [String: [String: Any]] = [:]
        /// W183 R9c（GPT-6 C7）：像真的網頁——選單 menuAppearsAfter 秒後才出來；那時這一次還沒被撤銷＝按下那一項（itemClicks）、回 opened；
        /// 撤銷了＝不按、回 aborted。
        var menuAppearsAfter: Double?
        private(set) var itemClicks = 0
        private var abortedOps: Set<String> = []
        private(set) var payloads: [[String: Any]] = []
        var commands: [String] { payloads.compactMap { $0["cmd"] as? String } }
        func start() throws { isRunning = true }
        func stop() { isRunning = false }
        func run(_ script: String) {
            guard let open = script.range(of: ".command("), script.hasSuffix(")"),
                  let data = String(script[open.upperBound..<script.index(before: script.endIndex)]).data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = payload["id"] as? String, let cmd = payload["cmd"] as? String else { return }
            payloads.append(payload)
            var delay = 0.0
            let answer: [String: Any]
            switch cmd {
            case "send", "regenerate": return
            case "stop": answer = ["stopped": true]
            case "pluginNewMenu":
                if let appear = menuAppearsAfter {
                    let op = payload["op"] as? String ?? ""
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(appear * 1_000_000_000))
                        guard let self else { return }
                        let aborted = self.abortedOps.contains(op)
                        if !aborted { self.itemClicks += 1 }
                        guard let body = try? JSONSerialization.data(withJSONObject: ["type": "result", "id": id, "ok": true,
                                                                                      "data": ["status": aborted ? "aborted" : "opened"]]) else { return }
                        self.onEvent?(String(decoding: body, as: UTF8.self))
                    }
                    return
                }
                answer = reply; delay = replyDelay
            case "pluginNewMenuAbort":
                abortedOps.insert(payload["op"] as? String ?? "")
                answer = ["ok": true]
            case "pluginNewMenuWatch": answer = ["known": pageKnows, "open": dialogOpen]
            default: answer = answers[cmd] ?? ["ok": true]
            }
            guard let body = try? JSONSerialization.data(withJSONObject: ["type": "result", "id": id, "ok": true, "data": answer]) else { return }
            let json = String(decoding: body, as: UTF8.self)
            let wait = delay
            Task { @MainActor [weak self] in
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                self?.onEvent?(json)
            }
        }
    }

    /// 自測調得動的外界：私訊框收起來了、Pod 還在、時鐘。
    @MainActor final class MenuKnobs {
        var boxClosed = false
        var podAlive = true
        var pickerOpen = false
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        /// 原生頁面世代（網頁換了一份就加一）。
        var generation = 0
    }

    /// 照正式的接法，只把 Pod、私訊框換成記憶體替身（租約、指令、撤銷都走真的 ChatGPTTap）。
    @MainActor static func menuDeps(_ tap: ChatGPTTap, _ h: Harness, _ knobs: MenuKnobs, holdLimit: TimeInterval = 600,
                                    prepare: @escaping @MainActor () async -> (problem: String?, needsLogin: Bool) = { (nil, false) },
                                    openTab: (@MainActor (@escaping @MainActor () -> Void) -> Bool)? = nil) -> ChatGPTPluginNewMenu.Dependencies {
        let browserTab: @MainActor (@escaping @MainActor () -> Void) -> Bool = { onCancel in
            h.browser.openPod(purpose: .chatgptDeveloper, onCancel: onCancel)
        }
        var deps = ChatGPTPluginNewMenu.Dependencies(
            prepare: prepare,
            beginHold: { if let hold = tap.beginMenuHold() { return (hold, nil) }; return (nil, tap.menuHoldBlocker) },
            endHold: { tap.endMenuHold($0) },
            openTab: openTab ?? browserTab,
            tabOpen: { h.browser.tab(for: .chatgptDeveloper).map { !$0.pageClosed } ?? false },
            send: { item, op, hold in try await tap.pluginNewMenu(item, op: op, hold: hold) },
            watch: { op, hold in await tap.pluginNewMenuOpen(op: op, hold: hold) },
            abort: { tap.abortPluginNewMenu(op: $0) },
            boxClosed: { knobs.boxClosed },
            podAlive: { knobs.podAlive })
        deps.now = { knobs.clock }
        deps.pickerOpen = { knobs.pickerOpen }
        deps.pageGeneration = { knobs.generation }
        deps.pause = { _ in _ = try? await Task.sleep(nanoseconds: 15_000_000) }
        deps.watchEvery = 0.015
        deps.holdLimit = holdLimit
        return deps
    }

    @MainActor static func pluginNewMenuChecks(_ check: Checker) async {
        check(ChatGPTPluginNewItem.allCases.map(\.title) == ["建立外掛程式", "上傳外掛程式封存檔", "建立 MCP 應用程式"]
              && ChatGPTPluginNewItem.mcpHint.contains("ChatGPT build") && ChatGPTPluginNewItem.mcpHint.contains("［連線］")
              && ChatGPTTap.pageCommands.contains("pluginNewMenu") && ChatGPTTap.pluginNewMenuItems == ["plugin", "archive", "mcp"],
              "W183 R9 原生外掛頁「新增 ▾」：三項照網頁版（建立外掛程式／上傳外掛程式封存檔／建立 MCP 應用程式），MCP 那一項下面提示用 ChatGPT build 的［連線］；pluginNewMenu 算會換頁的指令")
        keyChecks(check)
        await itemChecks(check)
        await textChecks(check)
        await busyChecks(check)
        await exclusiveChecks(check)
        await menuCancelChecks(check)
        await lateReplyChecks(check)
        await sendPhaseChecks(check)
        await visibilityChecks(check)
        await filePickerChecks(check)
        await webFeatureChecks(check)
        await pluginNewMenuRenderChecks(check)
    }

    // MARK: 鑰匙（GPT-6 #3）

    @MainActor static func keyChecks(_ check: Checker) {
        let key = ChatGPTTap.makePodKey()
        let keyed = try? ChatGPTTap.keyedPodScript(key)
        let placeholder = ChatGPTTap.podKeyPlaceholder
        let occurrences = ChatGPTTap.podScript.components(separatedBy: placeholder).count - 1
        check(key.utf8.count == 64 && key.allSatisfy { $0.isHexDigit } && ChatGPTTap.makePodKey() != key && occurrences == 1
              && keyed?.contains(key) == true && keyed?.contains(placeholder) == false
              && (try? ChatGPTTap.keyedPodScript("0123")) == nil && (try? ChatGPTTap.keyedPodScript(key.uppercased())) == nil
              && (try? ChatGPTTap.keyedPodScript(key, script: "no placeholder here")) == nil
              && (try? ChatGPTTap.keyedPodScript(key, script: placeholder + placeholder)) == nil,
              "W183 R9 審查（GPT-6 #3）：Pod 腳本的鑰匙每次換一把（64 個十六進位字）；佔位字剛好一個、換完不剩；鑰匙不對、佔位字不是一個＝不開（scriptRejected）",
              "occurrences=\(occurrences)")
        let transport = MenuTransport()
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let stream = tap.send(requestID: UUID().uuidString, text: "fixture", conversationID: nil)
        withExtendedLifetime(stream) { tap.stop() }
        let keys = transport.payloads.map { $0["key"] as? String }
        check(transport.payloads.count >= 2 && keys.allSatisfy { $0 == tap.podKeyForSelfTest } && Set(transport.commands) == ["send", "stop"],
              "W183 R9 審查（GPT-6 #3）：App 送的每一個指令都帶這個 Pod 的鑰匙（送出、停止都一樣）",
              "\(transport.commands)")
    }

    // MARK: 三項各自（只開對話框；租約交給使用者、對話框關了才放）

    @MainActor static func itemChecks(_ check: Checker) async {
        for item in ChatGPTPluginNewItem.allCases {
            let h = Harness("r9-menu-\(item.rawValue)")
            let transport = MenuTransport()
            transport.reply = item == .archive ? ["status": "menu_open"] : ["status": "opened"]
            let tap = ChatGPTTap(transport: transport, connection: .ready)
            let knobs = MenuKnobs()
            let menu = ChatGPTPluginNewMenu(dependencies: menuDeps(tap, h, knobs))
            await menu.run(item)
            let sent = transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenu" }
            let keys = Set(sent.first?.keys.map { $0 } ?? [])
            let op = sent.first?["op"] as? String ?? ""
            let tab = h.browser.activeTab
            let held = menu.holding == item && tap.menuHold != nil && menu.message?.contains("「\(item.title)」") == true
                && menu.message?.contains("ChatGPT Dev") == true && menu.working == nil
            check(sent.count == 1 && sent.first?["item"] as? String == item.rawValue && keys == ["cmd", "id", "item", "key", "op"]
                  && ChatGPTTap.validMenuOp(op) && sent.first?["key"] as? String == tap.podKeyForSelfTest
                  && tab?.kind == .pod && tab?.purpose == .chatgptDeveloper && tab?.title == "ChatGPT Dev" && h.store.isBrowsing && held,
                  "W183 R9 原生外掛頁「新增 ▾」→「\(item.title)」：Pod 的畫面開成私訊框 Browser 的 ChatGPT Dev 分頁、送 pluginNewMenu(\(item.rawValue))；指令只帶這一項、一次性操作序號與 Pod 的鑰匙（不填、不勾、不按 Create）；交給使用者後還拿著 Pod",
                  "\(sent) \(menu.message ?? "nil") holding=\(String(describing: menu.holding))")
            // 「上傳外掛程式封存檔」：使用者自己叫出來的選檔視窗開著（網頁的選單已經關了）＝照樣拿著 Pod。
            var heldWhilePicking = true
            if item == .archive {
                knobs.pickerOpen = true
                transport.dialogOpen = false
                try? await Task.sleep(nanoseconds: 200_000_000)
                heldWhilePicking = menu.holding == .archive && tap.menuHold != nil
                knobs.pickerOpen = false
            }
            // 網頁的對話框（或選單）關了：放掉租約、原生頁一句話；撤銷只拿掉標出的框（帶這一次的序號）。
            transport.dialogOpen = false
            let released = await waitUntil(3) { menu.holding == nil && tap.menuHold == nil }
            let aborts = transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenuAbort" }
            check(released && heldWhilePicking && menu.message == ChatGPTPluginNewMenu.closedText && aborts.count == 1 && aborts.first?["op"] as? String == op
                  && transport.commands.contains("pluginNewMenuWatch")
                  && transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenuWatch" }.allSatisfy { $0["op"] as? String == op },
                  "W183 R9 審查（GPT-6 #9、#10）：「\(item.title)」的對話框（或選單）在網頁上關了＝放掉 Pod 的操作租約（腳本回報、只問這一次的操作）；選檔視窗開著的時候照樣拿著",
                  "\(transport.commands) \(menu.message ?? "nil")")
            h.browser.closeAll()
        }
        // archive＝只打開選單、標出那一項（使用者自己點選檔）；不再回假的「按了」。
        let archive = ChatGPTPluginNewMenu.resultText(["status": "menu_open"], item: .archive)
        check(archive.contains("標出「上傳外掛程式封存檔」") && archive.contains("自己點它選檔") && archive.contains("不代選")
              && ChatGPTPluginNewMenu.resultText(["status": "pressed"], item: .archive).contains("跟預期的不一樣"),
              "W183 R9 審查（GPT-6 #10）：「上傳外掛程式封存檔」＝打開「新增」選單、標出那一項，原生頁說在 Browser 分頁自己點它選檔；舊的「pressed」不再當成打開了",
              archive)
    }

    // MARK: 找不到、不只一個：一句話（Claude #7：看是哪一步）

    @MainActor static func textChecks(_ check: Checker) async {
        let h = Harness("r9-menu-missing")
        let transport = MenuTransport()
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let menu = ChatGPTPluginNewMenu(dependencies: menuDeps(tap, h, MenuKnobs()))
        var texts: [String] = []
        let replies: [([String: Any], ChatGPTPluginNewItem)] = [(["status": "not_found", "step": "menu_item"], .mcp),
                                                               (["status": "not_found", "step": "new_button"], .plugin),
                                                               (["status": "ambiguous", "step": "menu_item"], .archive),
                                                               (["status": "ambiguous", "step": "new_button"], .mcp),
                                                               (["status": "busy", "step": "dialog_open"], .plugin),
                                                               (["status": "not_found", "step": "dialog"], .plugin)]
        for (reply, item) in replies {
            transport.reply = reply
            await menu.run(item)
            texts.append(menu.message ?? "")
        }
        let codes = ["menu_item", "new_button", "dialog_open", "not_found", "ambiguous", "busy"]
        check(texts[0].contains("找不到「建立 MCP 應用程式」") && texts[1].contains("找不到「新增」選單") && texts[1].contains("開發者模式")
              && texts[2].contains("「上傳外掛程式封存檔」不只一個") && texts[3].contains("「新增」鈕不只一顆") && !texts[3].contains("建立 MCP")
              && texts[4].contains("已經開著一個對話框") && texts[5].contains("對話框沒有出來")
              && !texts.contains { text in codes.contains { text.contains($0) } }
              && h.browser.tab(for: .chatgptDeveloper) != nil && tap.menuHold == nil && menu.holding == nil,
              "W183 R9 原生外掛頁：找不到那一項、找不到「新增」、不只一個（看是哪一步：新增鈕／選單項）、已經開著對話框＝一句話（不是代號）；沒打開＝馬上放掉 Pod",
              texts.joined(separator: " | "))
        h.browser.closeAll()
    }

    // MARK: 私訊框正在連 TATWO、正在回答、語音中、私訊鈕關著、還沒登入（Claude #9）

    @MainActor static func busyChecks(_ check: Checker) async {
        // 私訊框正在連 TATWO（連接器獨占）：不送、一句話。
        let busy = Harness("r9-menu-busy")
        let busyTransport = MenuTransport()
        let busyTap = ChatGPTTap(transport: busyTransport, connection: .ready)
        let hold = busyTap.beginConnectorHold()
        let busyMenu = ChatGPTPluginNewMenu(dependencies: menuDeps(busyTap, busy, MenuKnobs()))
        await busyMenu.run(.mcp)
        var unknownRefused = false
        do { _ = try await busyTap.pluginNewMenu("upload", op: UUID().uuidString, hold: UUID()) } catch { unknownRefused = true }
        check(hold != nil && !busyTransport.commands.contains("pluginNewMenu") && busyMenu.message?.contains("正在連接 TATWO") == true && unknownRefused,
              "W183 R9 原生外掛頁：私訊框正在連 TATWO（連接器獨占）＝不送、不換頁；不是那三項的字一律不送",
              "\(busyTransport.commands) \(busyMenu.message ?? "nil")")
        if let hold { busyTap.endConnectorHold(hold) }
        busy.browser.closeAll()

        // 正在回答（有一則送出還沒完成）：不送、一句話。
        let answering = Harness("r9-menu-answering")
        let answeringTransport = MenuTransport()
        let answeringTap = ChatGPTTap(transport: answeringTransport, connection: .ready)
        let answeringStream = answeringTap.send(requestID: UUID().uuidString, text: "fixture", conversationID: nil)
        let answeringMenu = ChatGPTPluginNewMenu(dependencies: menuDeps(answeringTap, answering, MenuKnobs()))
        await answeringMenu.run(.plugin)
        check(answeringTransport.commands == ["send"] && answeringMenu.message?.contains("正在回答") == true && answeringTap.menuHold == nil,
              "W183 R9 審查（Claude #9）：ChatGPT 正在回答＝「新增」不送指令、不換頁；原生頁寫「ChatGPT 正在回答（或在語音模式）」",
              "\(answeringTransport.commands) \(answeringMenu.message ?? "nil")")
        withExtendedLifetime(answeringStream) { answeringTap.stop() }
        answering.browser.closeAll()

        // 語音中：不送、一句話；語音結束後就可以。
        let voice = Harness("r9-menu-voice")
        let voiceTransport = MenuTransport()
        voiceTransport.answers["voice"] = ["live": true]
        let voiceTap = ChatGPTTap(transport: voiceTransport, connection: .ready)
        let live = (try? await voiceTap.voice(start: nil))?.live == true
        let voiceMenu = ChatGPTPluginNewMenu(dependencies: menuDeps(voiceTap, voice, MenuKnobs()))
        await voiceMenu.run(.mcp)
        let blocked = !voiceTransport.commands.contains("pluginNewMenu") && voiceMenu.message?.contains("語音") == true
        _ = try? await voiceTap.voiceStop()
        voiceTransport.dialogOpen = false
        await voiceMenu.run(.mcp)
        check(live && blocked && voiceTransport.commands.contains("pluginNewMenu"),
              "W183 R9 審查（Claude #9）：語音模式中＝「新增」不送指令（原生頁一句話）；語音結束之後才送",
              "\(voiceTransport.commands) \(voiceMenu.message ?? "nil")")
        _ = await waitUntil(2) { voiceMenu.holding == nil }
        voice.browser.closeAll()

        // 私訊鈕關著＝沒有地方開：不送、放掉租約；還沒登入＝分頁打開讓你登入、不送。
        let off = Harness("r9-menu-off")
        let offTransport = MenuTransport()
        let offTap = ChatGPTTap(transport: offTransport, connection: .ready)
        let offMenu = ChatGPTPluginNewMenu(dependencies: menuDeps(offTap, off, MenuKnobs(), openTab: { _ in false }))
        await offMenu.run(.plugin)
        let opened = HandsLocked(0)
        let loginMenu = ChatGPTPluginNewMenu(dependencies: menuDeps(offTap, off, MenuKnobs(),
            prepare: { ("ChatGPT 還沒登入：在私訊框 Browser 的「ChatGPT Dev」分頁登入後再按一次", true) },
            openTab: { _ in opened.update { $0 += 1 }; return true }))
        await loginMenu.run(.mcp)
        // W184 G2 第三輪（查證 #3）：還沒登入、但 ChatGPT Dev 分頁開不出來＝照實說沒有地方開，不叫你去不存在的分頁登入。
        let loginNoTab = ChatGPTPluginNewMenu(dependencies: menuDeps(offTap, off, MenuKnobs(),
            prepare: { ("ChatGPT 還沒登入：在私訊框 Browser 的「ChatGPT Dev」分頁登入後再按一次", true) },
            openTab: { _ in false }))
        await loginNoTab.run(.mcp)
        let noTabSaid: Bool = loginNoTab.message == ChatGPTPluginNewMenu.noPlaceText && loginNoTab.message?.contains("分頁登入") == false
        check(offTransport.payloads.isEmpty && offMenu.message?.contains("私訊鈕關著") == true && offTap.menuHold == nil
              && opened.get() == 1 && loginMenu.message?.contains("登入") == true && noTabSaid,
              "W183 R9 原生外掛頁：私訊鈕關著＝不送（一句話、租約放掉）；ChatGPT 還沒登入＝分頁打開讓你登入、不送；分頁開不出來＝照實說（W184 G2 第三輪）",
              "\(offTransport.payloads) \(offMenu.message ?? "nil") \(loginMenu.message ?? "nil") \(loginNoTab.message ?? "nil")")
        off.browser.closeAll()
    }

    // MARK: 雙向互斥（GPT-6 #9）：拿著的時候聊天排隊、語音與連線流程拿不到；放掉才送排隊的

    @MainActor static func exclusiveChecks(_ check: Checker) async {
        let h = Harness("r9-menu-exclusive")
        let transport = MenuTransport()
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let menu = ChatGPTPluginNewMenu(dependencies: menuDeps(tap, h, MenuKnobs()))
        await menu.run(.plugin)
        let holding = menu.holding == .plugin && tap.menuHold != nil
        let stream = tap.send(requestID: "fixture-queued", text: "fixture", conversationID: nil)
        let events = HandsLocked<[String]>([])
        let reader = Task { @MainActor in
            for await event in stream {
                switch event {
                case .queued: events.update { $0.append("queued") }
                case .accepted: events.update { $0.append("accepted") }
                default: break
                }
            }
        }
        _ = await waitUntil(1) { events.get().contains("queued") }
        let queued = !transport.commands.contains("send")
        let connectorRefused = tap.beginConnectorHold() == nil
        var voiceRefused = false
        do { _ = try await tap.voice(start: nil) } catch { voiceRefused = true }
        let secondBlocked = tap.beginMenuHold() == nil && tap.menuHoldBlocker?.contains("上一個「新增」") == true
        check(holding && events.get().contains("queued") && queued && connectorRefused && voiceRefused && !transport.commands.contains("voice") && secondBlocked,
              "W183 R9 審查（GPT-6 #9）：「新增」的對話框交給使用者之後照樣拿著 Pod——聊天送出先排隊、連線流程拿不到獨占、語音不開、再按一次「新增」也不做",
              "\(transport.commands) events=\(events.get())")
        transport.dialogOpen = false
        let dispatched = await waitUntil(3) { tap.menuHold == nil && transport.commands.contains("send") && events.get().contains("accepted") }
        check(dispatched,
              "W183 R9 審查（GPT-6 #9）：對話框關了、放掉 Pod 之後，排隊的聊天才送出（drainQueue 也看租約）",
              "\(transport.commands) events=\(events.get())")
        tap.stop(requestID: "fixture-queued")
        reader.cancel()
        h.browser.closeAll()
    }

    // MARK: 撤銷（GPT-6 #8）：分頁關掉、私訊框收起來、逾時、網頁換了一份、Pod 關了

    @MainActor static func menuCancelChecks(_ check: Checker) async {
        struct Case { let kind: String; let note: String; let aborts: Bool }
        let cases = [Case(kind: "tab", note: ChatGPTPluginNewMenu.tabClosedText, aborts: true),
                     Case(kind: "box", note: ChatGPTPluginNewMenu.boxClosedText, aborts: true),
                     Case(kind: "timeout", note: ChatGPTPluginNewMenu.timeoutText, aborts: true),
                     Case(kind: "page", note: ChatGPTPluginNewMenu.pageChangedText, aborts: true),
                     Case(kind: "pod", note: ChatGPTPluginNewMenu.podGoneText, aborts: false)]
        var results: [String] = []
        for c in cases {
            let h = Harness("r9-menu-cancel-\(c.kind)")
            let transport = MenuTransport()
            let tap = ChatGPTTap(transport: transport, connection: .ready)
            let knobs = MenuKnobs()
            let menu = ChatGPTPluginNewMenu(dependencies: menuDeps(tap, h, knobs, holdLimit: 60))
            await menu.run(.mcp)
            let op = menu.operationForSelfTest ?? ""
            switch c.kind {
            case "tab": if let id = h.browser.tab(for: .chatgptDeveloper)?.id { h.browser.userClose(id) }
            case "box": knobs.boxClosed = true
            case "timeout": knobs.clock = knobs.clock.addingTimeInterval(61)
            case "page": transport.pageKnows = false
            default: knobs.podAlive = false
            }
            let released = await waitUntil(3) { tap.menuHold == nil && menu.holding == nil }
            let aborts = transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenuAbort" }
            let ok = released && !op.isEmpty && menu.message == c.note
                && (c.aborts ? aborts.count == 1 && aborts.first?["op"] as? String == op : aborts.isEmpty)
            results.append("\(c.kind)=\(ok)")
            h.browser.closeAll()
        }
        check(!results.contains { $0.hasSuffix("=false") },
              "W183 R9 審查（GPT-6 #8）：「新增」交給使用者之後：關掉 ChatGPT Dev 分頁、收起私訊框、10 分鐘、網頁換了一份＝撤銷這一次（送 pluginNewMenuAbort 帶這一次的序號）、放掉 Pod；Pod 關了＝直接放掉；每一種都有一句話",
              results.joined(separator: " "))
    }

    /// 回覆比取消晚到（等網頁選單時就關了分頁）：撤銷先送、租約放掉，晚到的「打開了」不理（不再拿著 Pod）。
    @MainActor static func lateReplyChecks(_ check: Checker) async {
        let h = Harness("r9-menu-late")
        let transport = MenuTransport()
        transport.replyDelay = 0.3
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let menu = ChatGPTPluginNewMenu(dependencies: menuDeps(tap, h, MenuKnobs()))
        let running = Task { @MainActor in await menu.run(.plugin) }
        _ = await waitUntil(2) { transport.commands.contains("pluginNewMenu") }
        if let id = h.browser.tab(for: .chatgptDeveloper)?.id { h.browser.userClose(id) }
        let abortedEarly = transport.commands.last == "pluginNewMenuAbort" && tap.menuHold == nil
        await running.value
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(abortedEarly && menu.holding == nil && tap.menuHold == nil && menu.message == ChatGPTPluginNewMenu.tabClosedText,
              "W183 R9 審查（GPT-6 #8）：等網頁選單的時候就關了分頁＝馬上撤銷（撤銷先送、再放掉 Pod）；晚到的「打開了」不理，不再拿著 Pod",
              "\(transport.commands) \(menu.message ?? "nil")")
        h.browser.closeAll()
    }

    // MARK: 等回覆的時候就看（GPT-6 N7）

    /// 按了「新增」、網頁的選單延遲掛載（Pod 還沒回）：這時收起私訊框、網頁換了一份＝回覆之前就撤銷（腳本在下一個按之前停手）、放掉 Pod；
    /// 晚到的「打開了」不理。選檔視窗開著的時候網頁換了一份＝照樣放掉。
    @MainActor static func sendPhaseChecks(_ check: Checker) async {
        var results: [String] = []
        for kind in ["box", "page"] {
            let h = Harness("r9-menu-send-\(kind)")
            let transport = MenuTransport()
            transport.replyDelay = 0.6
            let tap = ChatGPTTap(transport: transport, connection: .ready)
            let knobs = MenuKnobs()
            let menu = ChatGPTPluginNewMenu(dependencies: menuDeps(tap, h, knobs))
            let running = Task { @MainActor in await menu.run(.mcp) }
            _ = await waitUntil(2) { transport.commands.contains("pluginNewMenu") }
            if kind == "box" { knobs.boxClosed = true } else { knobs.generation += 1 }
            // 回覆 0.6 秒後才到：在那之前就要撤銷、放掉。
            let early = await waitUntil(0.4) { tap.menuHold == nil && transport.commands.contains("pluginNewMenuAbort") }
            let aborts = transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenuAbort" }
            let op = transport.payloads.first(where: { $0["cmd"] as? String == "pluginNewMenu" })?["op"] as? String
            await running.value
            try? await Task.sleep(nanoseconds: 100_000_000)
            let note = kind == "box" ? ChatGPTPluginNewMenu.boxClosedText : ChatGPTPluginNewMenu.pageChangedText
            let ok = early && aborts.count == 1 && aborts.first?["op"] as? String == op && op != nil
                && menu.holding == nil && tap.menuHold == nil && menu.message == note && !transport.commands.contains("pluginNewMenuWatch")
            results.append("\(kind)=\(ok)")
            h.browser.closeAll()
        }
        // 「上傳外掛程式封存檔」交給使用者、選檔視窗開著：網頁換了一份＝照樣放掉（不因為選檔中跳過）。
        let h = Harness("r9-menu-picker-generation")
        let transport = MenuTransport()
        transport.reply = ["status": "menu_open"]
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let knobs = MenuKnobs()
        let menu = ChatGPTPluginNewMenu(dependencies: menuDeps(tap, h, knobs))
        await menu.run(.archive)
        knobs.pickerOpen = true
        transport.dialogOpen = false
        try? await Task.sleep(nanoseconds: 100_000_000)
        let heldWhilePicking = menu.holding == .archive && tap.menuHold != nil
        knobs.generation += 1
        let released = await waitUntil(2) { tap.menuHold == nil && menu.holding == nil }
        results.append("picker=\(heldWhilePicking && released && menu.message == ChatGPTPluginNewMenu.pageChangedText)")
        h.browser.closeAll()
        check(!results.contains { $0.hasSuffix("=false") },
              "W183 R9 審查（GPT-6 N7）：從拿到 Pod 的操作租約起就看——等網頁選單（Pod 還沒回）時收起私訊框、網頁換了一份＝回覆之前就撤銷、放掉 Pod，晚到的回覆不理；選檔視窗開著時網頁換了一份也照樣放掉",
              results.joined(separator: " "))
    }

    // MARK: 收起私訊框＝事件一來就撤銷（GPT-6 C7）

    /// 正式的時序（輪詢 250 毫秒一次、真的等）：按了「新增」、網頁的選單 120 毫秒後才出來；送出之後 20 毫秒使用者收起私訊框。
    /// 有訂閱私訊框的變化＝一收起就撤銷，選單出來時已經撤銷＝項目一次都沒被按；沒有訂閱（只靠輪詢）＝選單出來時還沒撤銷、會按到（對照）。
    @MainActor static func visibilityChecks(_ check: Checker) async {
        var clicks: [Bool: Int] = [:]
        var released: [Bool: Bool] = [:]
        var notes: [Bool: String] = [:]
        for subscribed in [true, false] {
            let h = Harness("r9-menu-visibility-\(subscribed)")
            let transport = MenuTransport()
            transport.menuAppearsAfter = 0.12
            let tap = ChatGPTTap(transport: transport, connection: .ready)
            let knobs = MenuKnobs()
            var deps = menuDeps(tap, h, knobs)
            deps.pause = { seconds in _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            deps.sendWatchEvery = 0.25
            deps.watchEvery = 1.5
            let subject = PassthroughSubject<Void, Never>()
            if subscribed { deps.visibilityChanges = { changed in subject.sink { _ in MainActor.assumeIsolated { changed() } } } }
            let menu = ChatGPTPluginNewMenu(dependencies: deps)
            let running = Task { @MainActor in await menu.run(.mcp) }
            _ = await waitUntil(2) { transport.commands.contains("pluginNewMenu") }
            try? await Task.sleep(nanoseconds: 20_000_000)
            knobs.boxClosed = true
            subject.send(())
            await running.value
            _ = await waitUntil(2) { tap.menuHold == nil }
            try? await Task.sleep(nanoseconds: 300_000_000)
            clicks[subscribed] = transport.itemClicks
            released[subscribed] = tap.menuHold == nil && menu.holding == nil
            notes[subscribed] = menu.message ?? "nil"
            h.browser.closeAll()
        }
        check(clicks[true] == 0 && released[true] == true && notes[true] == ChatGPTPluginNewMenu.boxClosedText && clicks[false] == 1 && released[false] == true,
              "W183 R9c（GPT-6 C7）：正式時序下收起私訊框＝事件一來就撤銷（不等 250 毫秒的輪詢）：之後才出來的選單項一次都沒被按、Pod 放掉；只靠輪詢的對照會按到一次",
              "subscribed clicks=\(clicks[true] ?? -1) released=\(released[true] ?? false) \(notes[true] ?? "") | polling clicks=\(clicks[false] ?? -1)")
    }

    // MARK: 只給人用的檔案選擇器（GPT-6 #10）

    @MainActor final class FakePanels {
        var opened = 0
        var cancels = 0
        var refused = 0
        var respond: (@MainActor ([URL]?) -> Void)?
        var lastRequest: TapPodFilePicker.Request?
        var context = TapPodFilePicker.Context.closed
        var answers: [[String]?] = []
        func answer(_ paths: [String]?) { answers.append(paths) }
    }

    @MainActor static func filePickerChecks(_ check: Checker) async {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panels = FakePanels()
        let human = TapPodFilePicker.Context(guarded: true, visible: true, human: true, window: window)
        panels.context = human
        let picker = TapPodFilePicker(context: { panels.context }, present: { _, request, done in
            panels.opened += 1
            panels.lastRequest = request
            panels.respond = done
            return { panels.cancels += 1; done(nil) }
        })
        picker.onRefused = { panels.refused += 1 }
        // 不是人在看的時候（Pod 墊在畫面外、被 AI 操作、沒有受保護的呈現）、資料夾、另存新檔：不開。
        for (title, blocked) in [("hidden", TapPodFilePicker.Context(guarded: true, visible: false, human: true, window: window)),
                                 ("agent", TapPodFilePicker.Context(guarded: true, visible: true, human: false, window: window)),
                                 ("unguarded", TapPodFilePicker.Context(guarded: false, visible: true, human: true, window: window))] {
            panels.context = blocked
            picker.request(mode: 0, title: title, defaultPath: "", filters: [], multiple: false) { panels.answer($0) }
        }
        panels.context = human
        picker.request(mode: 2, title: "folder", defaultPath: "", filters: [], multiple: false) { panels.answer($0) }
        picker.request(mode: 3, title: "save", defaultPath: "/tmp/fixture.zip", filters: [], multiple: false) { panels.answer($0) }
        let refusedAll = panels.answers.count == 5 && panels.answers.allSatisfy { $0 == nil } && panels.opened == 0 && panels.refused == 5
        // 人在看：開一個（不預選檔：預設路徑只當起始資料夾）；開著的時候再要一個＝不開；使用者選了＝交回路徑（剛好一次）。
        panels.answers = []
        picker.request(mode: 0, title: "Upload plugin archive", defaultPath: "/tmp/fixture/archive.zip", filters: [".zip"], multiple: true) { panels.answer($0) }
        picker.request(mode: 0, title: "again", defaultPath: "", filters: [], multiple: false) { panels.answer($0) }
        let zip = UTType(filenameExtension: "zip")
        let oneAtATime = panels.opened == 1 && panels.answers == [nil] && picker.isOpen && panels.lastRequest?.multiple == false
            && panels.lastRequest?.directory?.path == "/tmp/fixture" && panels.lastRequest?.types == (zip.map { [$0] } ?? [])
        panels.respond?([URL(fileURLWithPath: "/tmp/fixture/archive.zip")])
        panels.respond?([URL(fileURLWithPath: "/tmp/fixture/other.zip")])
        let picked = panels.answers.count == 2 && panels.answers[1] == ["/tmp/fixture/archive.zip"] && !picker.isOpen
        // 開著的時候 Pod 從分頁拿下來（世代換了）＝取消、網頁拿到「取消」；晚到的結果不交。
        panels.answers = []
        picker.request(mode: 0, title: "x", defaultPath: "", filters: [], multiple: false) { panels.answer($0) }
        let late = panels.respond
        picker.invalidate()
        late?([URL(fileURLWithPath: "/tmp/fixture/late.zip")])
        let cancelled = panels.cancels == 1 && panels.answers == [nil] && !picker.isOpen
        // 開著的時候不再看得到（視窗收起來）：使用者按了「好」也不交給網頁。
        panels.answers = []
        picker.request(mode: 0, title: "y", defaultPath: "", filters: [], multiple: false) { panels.answer($0) }
        panels.context = TapPodFilePicker.Context(guarded: true, visible: false, human: true, window: window)
        panels.respond?([URL(fileURLWithPath: "/tmp/fixture/hidden.zip")])
        let hiddenDropped = panels.answers == [nil]
        check(refusedAll && oneAtATime && picked && cancelled && hiddenDropped,
              "W183 R9 審查（GPT-6 #10）：Pod 的檔案選擇器只給人用——只在私訊框 Browser 的分頁、看得到、人在用時開；只開檔（不開資料夾、另存新檔）；一次一個；不預選檔；取消／世代：還開著就取消、晚到的結果不交；結果只交一次",
              "refused=\(refusedAll) one=\(oneAtATime) picked=\(picked) cancelled=\(cancelled) hidden=\(hiddenDropped)")
        window.close()
    }

    // MARK: CEF 作廢網頁功能 → 選檔視窗、「新增」（GPT-6 N8）

    /// 假的 Pod 瀏覽器：只有兩條回呼（選檔、作廢）。TapWebPod.wireWebFeatures 接上的就是正式瀏覽器上的同一組。
    @MainActor final class FakePodFeatureHost: TapPodWebFeatureHost {
        var onFileDialog: TatwoCEFFileDialogHandler?
        var onWebFeaturesInvalidated: (() -> Void)?
    }

    @MainActor static func webFeatureChecks(_ check: Checker) async {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panels = FakePanels()
        panels.context = TapPodFilePicker.Context(guarded: true, visible: true, human: true, window: window)
        let picker = TapPodFilePicker(context: { panels.context }, present: { _, request, done in
            panels.opened += 1
            panels.lastRequest = request
            panels.respond = done
            return { panels.cancels += 1; done(nil) }
        })
        let host = FakePodFeatureHost()
        TapWebPod.wireWebFeatures(host, picker: picker)
        let wired = host.onFileDialog != nil && host.onWebFeaturesInvalidated != nil
        // 「上傳外掛程式封存檔」交給使用者（選單開著、拿著 Pod）。
        let h = Harness("r9-menu-invalidated")
        let transport = MenuTransport()
        transport.reply = ["status": "menu_open"]
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let knobs = MenuKnobs()
        var deps = menuDeps(tap, h, knobs)
        deps.pickerOpen = { picker.isOpen }
        deps.armPicker = { hook in picker.onBrowserInvalidated = hook }
        let menu = ChatGPTPluginNewMenu(dependencies: deps)
        await menu.run(.archive)
        let op = menu.operationForSelfTest ?? ""
        // 使用者點那一項：網頁要選檔 → CEF 的選檔回呼 → 人用的選擇器開了；網頁的選單關了，照樣拿著 Pod。
        host.onFileDialog?(0, "Upload plugin archive", "", [".zip"], false) { panels.answer($0) }
        transport.dialogOpen = false
        try? await Task.sleep(nanoseconds: 100_000_000)
        let picking = panels.opened == 1 && picker.isOpen && menu.holding == .archive && tap.menuHold != nil
        // 網頁導頁（CEF W57dInvalidate → onWebFeaturesInvalidated）：sheet 取消、網頁拿到「取消」一次、「新增」那一次結束（撤銷、放掉 Pod）。
        let late = panels.respond
        host.onWebFeaturesInvalidated?()
        let settled = panels.cancels == 1 && panels.answers == [nil] && !picker.isOpen
        let finished = tap.menuHold == nil && menu.holding == nil && menu.message == ChatGPTPluginNewMenu.pageChangedText
            && transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenuAbort" }.map { $0["op"] as? String } == [op]
        late?([URL(fileURLWithPath: "/tmp/fixture/late.zip")])
        let lateDropped = panels.answers == [nil]
        // 沒有進行中的「新增」時作廢：只取消選檔（不出錯、不多送）。
        host.onWebFeaturesInvalidated?()
        let idle = panels.answers == [nil] && transport.commands.filter { $0 == "pluginNewMenuAbort" }.count == 1
        TapWebPod.unwireWebFeatures(host, picker: picker)
        let unwired = host.onFileDialog == nil && host.onWebFeaturesInvalidated == nil
        check(wired && picking && settled && finished && lateDropped && idle && unwired && !op.isEmpty,
              "W183 R9 審查（GPT-6 N8）：CEF 的 onWebFeaturesInvalidated 接到 Pod 的檔案選擇器——導頁時 sheet 取消、網頁拿到「取消」剛好一次、晚到的選檔結果不交，「新增」那一次跟著結束（撤銷、放掉 Pod，不因為選檔中跳過）；stop 拆掉兩條回呼",
              "wired=\(wired) picking=\(picking) settled=\(settled) finished=\(finished) late=\(lateDropped) idle=\(idle) unwired=\(unwired) \(transport.commands)")
        h.browser.closeAll()
        window.close()
    }

    // MARK: 畫面（Claude #4、#8）：畫出外掛頁標題列與「新增」選單；用 accessibilityIdentifier 真的按三項

    /// ImageRenderer 畫出來的點（上到下、RGBA8）。
    struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        func rgba(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
    }

    @MainActor static func render<V: View>(_ view: V, scale: CGFloat = 2) -> (CGImage, Pixels)? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (image, Pixels(width: width, height: height, bytes: bytes)) : nil
    }

    /// 存 PNG 到 verify 目錄（lead-verify 給的 TATWO2_SELFTEST_ARTIFACTS；沒有就放隔離的 staging 根目錄）。回存的路徑。
    @MainActor static func savePNG(_ image: CGImage, _ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["TATWO2_SELFTEST_ARTIFACTS"] ?? environment["TATWO_STAGING_ROOT"] else { return nil }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return nil }
        return url.path
    }

    /// 同一個行程裡讀 SwiftUI 的輔助使用樹（照 BotUIAcceptance：新式 selector 讀不到就用舊式 attribute）。
    @MainActor static func axObject(_ element: NSObject, _ selector: String, legacy: String) -> Any? {
        let modern = NSSelectorFromString(selector)
        if element.responds(to: modern), let value = element.perform(modern)?.takeUnretainedValue() {
            if let list = value as? [Any], list.isEmpty {} else { return value }
        }
        let old = NSSelectorFromString("accessibilityAttributeValue:")
        guard element.responds(to: old) else { return nil }
        return element.perform(old, with: legacy)?.takeUnretainedValue()
    }

    @MainActor static func axCollect(_ root: NSObject, _ wanted: Set<String>) -> [String: NSObject] {
        var found: [String: NSObject] = [:]
        var queue: [(NSObject, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if let id = axObject(element, "accessibilityIdentifier", legacy: "AXIdentifier") as? String, wanted.contains(id), found[id] == nil {
                found[id] = element
            }
            guard depth < 60 else { continue }
            for child in (axObject(element, "accessibilityChildren", legacy: "AXChildren") as? [Any]) ?? [] {
                if let object = child as? NSObject { queue.append((object, depth + 1)) }
            }
        }
        return found
    }

    @MainActor static func axFrame(_ element: NSObject) -> NSRect? {
        if let accessible = element as? NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard element.responds(to: selector), let imp = element.method(for: selector) else { return nil }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(imp, to: Frame.self)(element, selector)
    }

    @MainActor static func axPress(_ element: NSObject) -> Bool {
        if let accessible = element as? NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
        let press = NSSelectorFromString("accessibilityPerformPress")
        if element.responds(to: press), let imp = element.method(for: press) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(imp, to: Press.self)(element, press)
        }
        let action = NSSelectorFromString("accessibilityPerformAction:")
        guard element.responds(to: action) else { return false }
        _ = element.perform(action, with: "AXPress")
        return true
    }

    @MainActor static func axText(_ element: NSObject?) -> String {
        guard let element else { return "" }
        let label = axObject(element, "accessibilityLabel", legacy: "AXDescription") as? String ?? ""
        let value = axObject(element, "accessibilityValue", legacy: "AXValue") as? String ?? ""
        return label + "|" + value
    }

    @MainActor static func pluginNewMenuRenderChecks(_ check: Checker) async {
        let transport = MenuTransport()
        transport.dialogOpen = false   // 每按一項：對話框一打開就當作關了（租約很快放掉，下一項才按得動）
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let h = Harness("r9-render")
        let menu = ChatGPTPluginNewMenu(dependencies: menuDeps(tap, h, MenuKnobs()))
        let width: CGFloat = 720
        let canvas = Color(red: 0.96, green: 0.96, blue: 0.96)
        let header = ChatGPTPageHeader(title: ChatGPTPluginsView.title, subtitle: ChatGPTPluginsView.subtitle,
                                       trailing: ChatGPTPluginsView.newMenuTrailing(menu))

        // 1. 畫出來（ImageRenderer）：標題列、選單各一張 PNG。
        let pad: CGFloat = 16
        let headerShot = render(header.frame(width: width).padding(pad).background(canvas).environment(\.colorScheme, .light))
        let listShot = render(ChatGPTPluginNewMenuList(menu: menu).padding(8).background(canvas).environment(\.colorScheme, .light))
        let headerPath = headerShot.flatMap { savePNG($0.0, "w183-r9-plugins-header.png") }
        let listPath = listShot.flatMap { savePNG($0.0, "w183-r9-plugins-new-menu.png") }
        print("W183BROWSER NOTE png header=\(headerPath ?? "not saved") menu=\(listPath ?? "not saved")")
        if let pixels = headerShot?.1 {
            let scale = CGFloat(pixels.width) / (width + pad * 2)
            // 跟底色不一樣的點：右邊 40% 裡的（chip）框出來；整張找藍色（系統的藍按鈕、藍框）。
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, blue = 0
            let left = Int((pad + width * 0.6) * scale)
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let (r, g, b, a) = pixels.rgba(x, y)
                    if a > 128, b > 128, b - r > 50, b - g > 25 { blue += 1 }
                    guard x >= left else { continue }
                    let base = 245
                    if abs(r - base) + abs(g - base) + abs(b - base) > 60 {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            let rightEdge = CGFloat(pixels.width) - pad * scale
            let chipRight = CGFloat(maxX) / scale, chipTop = CGFloat(minY) / scale
            let found = maxX >= 0
            check(found && blue == 0 && rightEdge / scale - chipRight <= 18 && chipTop - pad <= 18 && CGFloat(maxX - minX) / scale >= 20,
                  "W183 R9 審查（Claude #4）：外掛頁標題列畫出來——右上角是「新增 ⌄」玻璃 chip（貼右邊、在最上面那一列），整張沒有藍色系統鈕、藍框",
                  "found=\(found) blue=\(blue) right=\(rightEdge / scale - chipRight) top=\(chipTop - pad) png=\(headerPath ?? "-")")
        } else {
            check(false, "W183 R9 審查（Claude #4）：外掛頁標題列畫不出來（ImageRenderer）")
        }
        if let pixels = listShot?.1 {
            var blue = 0
            for y in 0..<pixels.height { for x in 0..<pixels.width {
                let (r, g, b, a) = pixels.rgba(x, y)
                if a > 128, b > 128, b - r > 50, b - g > 25 { blue += 1 }
            } }
            check(blue == 0 && pixels.height > pixels.width / 4, "W183 R9 審查（Claude #4）：「新增」選單畫出來（三項＋一行提示），沒有藍色",
                  "blue=\(blue) size=\(pixels.width)x\(pixels.height) png=\(listPath ?? "-")")
        } else {
            check(false, "W183 R9 審查（Claude #4）：「新增」選單畫不出來（ImageRenderer）")
        }

        // 2. 放進視窗、讀輔助使用樹：chip 在標題列右上、三項＋提示都認得出來（accessibilityIdentifier）。
        //    09-29 在 mini 實測：ssh 無頭的環境 SwiftUI 不建輔助使用樹（整棵只有 1 個節點、沒有任何 identifier）——這時記 SKIP（主導實機驗），
        //    三項改用下面 3. 真的滑鼠事件按；有輔助使用樹（一般桌面）就照 identifier 讀、照 identifier 按。
        let root = VStack(alignment: .leading, spacing: 12) {
            header.frame(width: width).accessibilityElement(children: .contain).accessibilityIdentifier("w183.r9.header")
            ChatGPTPluginNewMenuList(menu: menu)
        }
        .padding(pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(canvas)
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width + pad * 2, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let items = ChatGPTPluginNewItem.allCases.map { "chatgpt.plugins.new.\($0.rawValue)" }
        let wanted: Set<String> = Set(items + ["chatgpt.plugins.new", "chatgpt.plugins.new.hint", "w183.r9.header"])
        var found: [String: NSObject] = [:]
        for _ in 0..<40 {
            found = axCollect(host, wanted)
            if found.count == wanted.count { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let image = bitmap.cgImage, let path = savePNG(image, "w183-r9-plugins-window.png") { print("W183BROWSER NOTE png window=\(path)") }
        }
        var axPressed: [String] = []
        if found.isEmpty {
            check.skip("W183 R9 審查（Claude #4、#8）：這個環境沒有輔助使用樹（ssh 無頭：SwiftUI 不建，實測整棵 1 個節點）——chip／三項／提示的 accessibilityIdentifier 與 chip 的位置由主導實機驗；三項改用真的滑鼠事件按（下一條）")
        } else {
            let missing = wanted.subtracting(found.keys).sorted()
            check(missing.isEmpty && axText(found["chatgpt.plugins.new.hint"]).contains(ChatGPTPluginNewItem.mcpHint),
                  "W183 R9 審查（Claude #4、#8）：輔助使用樹裡認得出「新增」chip、三項（chatgpt.plugins.new.plugin／archive／mcp）與 MCP 那一項下面的一行提示",
                  "missing=\(missing) hint=\(axText(found["chatgpt.plugins.new.hint"]))")
            if let chipNode = found["chatgpt.plugins.new"], let barNode = found["w183.r9.header"], let chip = axFrame(chipNode), let bar = axFrame(barNode) {
                check(abs(bar.maxX - chip.maxX) <= 2 && bar.maxY - chip.maxY >= -2 && bar.maxY - chip.maxY <= 12 && chip.width >= 40 && chip.height >= 20,
                      "W183 R9 審查（Claude #4）：「新增」chip 在外掛頁標題列的右上角（跟標題同一列）",
                      "chip=\(chip) header=\(bar)")
            } else {
                check(false, "W183 R9 審查（Claude #4）：讀不到「新增」chip 或標題列的位置（輔助使用樹）")
            }
            for item in ChatGPTPluginNewItem.allCases {
                let id = "chatgpt.plugins.new.\(item.rawValue)"
                _ = await waitUntil(3) { menu.working == nil && menu.holding == nil }
                guard let element = axCollect(host, [id])[id] else { axPressed.append("\(item.rawValue)=missing"); continue }
                let before = transport.payloads.count
                let ok = axPress(element)
                let sent = await waitUntil(3) { transport.payloads.dropFirst(before).contains { $0["cmd"] as? String == "pluginNewMenu" } }
                let payload = transport.payloads.dropFirst(before).first { $0["cmd"] as? String == "pluginNewMenu" }
                axPressed.append("\(item.rawValue)=\(ok && sent && payload?["item"] as? String == item.rawValue)")
            }
            _ = await waitUntil(3) { menu.working == nil && menu.holding == nil }
            check(axPressed == ChatGPTPluginNewItem.allCases.map { "\($0.rawValue)=true" },
                  "W183 R9 審查（Claude #8）：照 accessibilityIdentifier（chatgpt.plugins.new.<item>）按選單上的三項：各自送出那一項的 pluginNewMenu",
                  axPressed.joined(separator: " "))
        }

        // 3. 真的滑鼠事件（window.sendEvent：跟使用者點的同一條路）按「新增」選單上的三項——選單就是外掛頁 popover 裡的那一張
        //    （ChatGPTPluginNewMenuList：上下留 6、一列 30、列距 2，第 i 列的中心在上面數下來 6＋15＋32i）。各自送出那一項的 pluginNewMenu、一項一個指令。
        _ = await waitUntil(3) { menu.working == nil && menu.holding == nil }
        let listHost = NSHostingView(rootView: ChatGPTPluginNewMenuList(menu: menu).environment(\.colorScheme, .light))
        let listSize = listHost.fittingSize
        let listWindow = NSWindow(contentRect: NSRect(x: -20_000, y: -19_000, width: listSize.width, height: listSize.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        listWindow.isReleasedWhenClosed = false
        listWindow.contentView = listHost
        listWindow.orderFrontRegardless()
        defer { listWindow.orderOut(nil); listWindow.close() }
        listHost.layoutSubtreeIfNeeded()
        listWindow.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let beforeClicks = transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenu" }.count
        var clicked: [String] = []
        for (index, item) in ChatGPTPluginNewItem.allCases.enumerated() {
            _ = await waitUntil(3) { menu.working == nil && menu.holding == nil }
            let before = transport.payloads.count
            let point = NSPoint(x: 60, y: listHost.bounds.height - CGFloat(6 + 15 + index * 32))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: listWindow.windowNumber, context: nil, eventNumber: index, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    listWindow.sendEvent(event)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let sent = await waitUntil(3) { transport.payloads.dropFirst(before).contains { $0["cmd"] as? String == "pluginNewMenu" } }
            let payload = transport.payloads.dropFirst(before).first { $0["cmd"] as? String == "pluginNewMenu" }
            clicked.append("\(item.rawValue)=\(sent && payload?["item"] as? String == item.rawValue)")
        }
        _ = await waitUntil(3) { menu.working == nil && menu.holding == nil }
        let afterClicks = transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenu" }.count
        check(clicked == ChatGPTPluginNewItem.allCases.map { "\($0.rawValue)=true" } && afterClicks - beforeClicks == 3 && tap.menuHold == nil,
              "W183 R9 審查（Claude #8）：用真的滑鼠事件按「新增」選單（外掛頁 popover 裡同一張 ChatGPTPluginNewMenuList）上的三項：各自送出那一項的 pluginNewMenu，一項一個指令",
              "\(clicked.joined(separator: " ")) sent=\(afterClicks - beforeClicks)")
        // open() 的防重複：同一輪按兩下只送一次。
        _ = await waitUntil(3) { menu.working == nil && menu.holding == nil }
        let beforeDouble = transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenu" }.count
        menu.open(.mcp)
        menu.open(.mcp)
        menu.open(.plugin)
        _ = await waitUntil(3) { transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenu" }.count > beforeDouble }
        _ = await waitUntil(3) { menu.working == nil && menu.holding == nil }
        let doubleSent = transport.payloads.filter { $0["cmd"] as? String == "pluginNewMenu" }.count - beforeDouble
        check(doubleSent == 1, "W183 R9 審查（Claude #8）：「新增」選單還在開那一項的時候再按（同一項或別項）＝不重複送", "sent=\(doubleSent)")
        h.browser.closeAll()
    }
}
#endif
