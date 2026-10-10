#if DEBUG
import Foundation

// W183 R9 自測（w183connect；只在完整隔離的 staging，不開通道、不啟動關口、不上網）：ChatGPT 改版後的「新增 ▾ → 建立 MCP 應用程式」。
// - 卡片上的字：外掛頁找不到／不只一個＝一句話（不再只有代號「（plus）」）；Connection 不是 Server URL＝拒絕；
//   「I understand and want to continue」＝不代勾、講清楚要勾哪一格、按［繼續］才帶回同一張表單。
// - 手動模式的步驟照新介面（新增 ▾ → 建立 MCP 應用程式 → Name → Server URL → OAuth → 自己勾 → Create）。
// - 專案不一致（實機：卡片說「主機上沒有可以選的專案」，ChatGPT Dev 面板列了那台 8 個、都沒勾）：W183 R10 起不用勾——卡片與面板
//   都是「這台全部專案」（交易類只能看），兩邊的清單一樣。
// - W183 R10：「I understand」由 TATWO 代勾（Pod 回 tickable）；交給使用者勾的卡只剩退路（那一格不在畫面上、沒勾到、警語大改、沒見過的勾選框）。
// 真的 ChatGPT 外掛頁 DOM（新增 ▾、選單、New Plugin 表單）在 tests/w183-connect.test.mjs 用本機假頁面跑真的 Pod 腳本。

extension HandsConnectAcceptance {
    @MainActor static func r9Checks(_ check: Checker, _ base: URL) async throws {
        r9Texts(check)
        try await r9RiskAck(check, base)
        try await r9NewMenuMissing(check, base)
        try await r9WarningUnbounded(check, base)
        await r9NavigationNotice(check)
        try await r9Manual(check, base)
        try r9Projects(check, base)
    }

    // MARK: 卡片上的字

    @MainActor static func r9Texts(_ check: Checker) {
        let codes = ["plus", "new_button", "new_menu", "mcp_item", "form", "form_open", "name", "url", "auth", "connection", "create",
                     "id", "open", "verify", "connect", "aborted", "unexpected"]
        var leaked: [String] = []
        for code in codes {
            for text in [HandsConnectFlow.pageMismatchText(.notFound(code)), HandsConnectFlow.pageMismatchText(.ambiguous(code))]
            where text.contains(code) || !text.hasSuffix("；可以再連一次，或改用手動") {
                leaked.append(code + "→" + text)
            }
        }
        check(leaked.isEmpty, "W183 R9 外掛頁跟預期不一樣：每一種都寫成一句話（不再只有代號，例如「（plus）」），都給「再連一次、改用手動」", leaked.joined(separator: " | "))
        let entry = ["plus", "new_button", "new_menu", "mcp_item"].map { HandsConnectFlow.pageMismatchText(.notFound($0)) }
        let missing = HandsConnectFlow.newMenuMissingText
        check(entry.allSatisfy { $0 == missing } && missing.contains("新增選單裡找不到加 MCP 伺服器的那一項") && missing.contains("ChatGPT 改版")
              && missing.contains("開發者模式") && missing.contains("再連一次") && missing.contains("手動"),
              "W303 新舊建立入口都找不到：卡片寫「外掛頁的新增選單裡找不到加 MCP 伺服器的那一項」（改版或沒開開發者模式）",
              entry.joined(separator: " | "))
        let ack = HandsConnectorAck(form: "fabc123456", warning: "0123abcd-40")
        let decoded = ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "risk_ack", "form": "fabc123456", "warning": "0123abcd-40"])
        let refused = ChatGPTConnectorPod.decodeAction(["status": "refused", "reason": "connection_not_server_url"])
        let refusal = HandsConnectFlow.refusalText("connection_not_server_url")
        check(decoded == .needsUser(HandsConnectFlow.riskAckReason, ack) && refused == .refused("connection_not_server_url")
              && refusal.contains("Server URL") && refusal.contains("Tunnel") && !refusal.contains("connection_not_server_url"),
              "W183 R9 Pod 回 risk_ack（沒帶位置）＝交給你勾（帶回那一張表單）；Connection 不是 Server URL＝拒絕（一句話：TATWO 不用 Tunnel）",
              "\(decoded) \(refused) \(refusal)")
        // W183 R10：risk_ack 帶了那一格的位置＝TATWO 代勾；位置不合理（太小、出了畫面、多的欄位、布林當數字）＝照舊交給你；
        // 警語大改、沒見過的勾選框＝交給你（各一句話的原因）。
        let tick: [String: Any] = ["x": 20, "y": 400, "w": 18, "h": 18, "vw": 466, "vh": 678]
        let tickable = ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "risk_ack", "form": "fabc123459", "warning": "0123abcd-42", "tick": tick])
        let target = HandsTickTarget(x: 20, y: 400, width: 18, height: 18, viewportWidth: 466, viewportHeight: 678)
        let bad: [[String: Any]] = [["x": 20, "y": 400, "w": 4, "h": 4, "vw": 466, "vh": 678], ["x": 460, "y": 400, "w": 18, "h": 18, "vw": 466, "vh": 678],
                                    ["x": 20, "y": 400, "w": 18, "h": 18, "vw": 466, "vh": 678, "click": true], ["x": true, "y": 400, "w": 18, "h": 18, "vw": 466, "vh": 678]]
        let badDecoded = bad.map { ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "risk_ack", "form": "fabc123460", "warning": "w", "tick": $0]) }
        let changed = ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "warning_changed", "form": "fabc123461", "warning": "w", "tick": tick])
        let unknownBox = ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "checkbox", "form": "fabc123462", "warning": "w"])
        // W183 R10 第二輪：同意內容對不上核實過的版本（consent: unknown）＝就算帶了位置也不代勾，卡片說「跟 TATWO 認得的不一樣」。
        let unknownConsent = ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "risk_ack", "form": "fabc123463", "warning": "w",
                                                              "consent": "unknown", "tick": tick])
        // W183 R10 第二輪：記下量的那一份文件（導頁世代）；armed 的記號只收表單記號的樣子。
        let stamped = ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "risk_ack", "form": "fabc123464", "warning": "w", "tick": tick],
                                                       generation: 7)
        check(unknownConsent == .needsUser(HandsConnectFlow.warningChangedReason, HandsConnectorAck(form: "fabc123463", warning: "w"))
              && stamped == .tickable(HandsConnectorAck(form: "fabc123464", warning: "w"),
                                      HandsTickTarget(x: 20, y: 400, width: 18, height: 18, viewportWidth: 466, viewportHeight: 678, generation: 7))
              && ChatGPTConnectorPod.armToken("f12x34567890") == "f12x34567890" && ChatGPTConnectorPod.armToken("f12-x") == nil
              && ChatGPTConnectorPod.armToken(12) == nil,
              "W183 R10 第二輪 Pod 回 consent unknown＝不代勾（卡片說不認得）；代勾的位置記下量的那一份文件；armed 的記號只收該有的樣子",
              "\(unknownConsent) \(stamped)")
        check(tickable == .tickable(HandsConnectorAck(form: "fabc123459", warning: "0123abcd-42"), target) && target.point == (29, 409)
              && badDecoded.allSatisfy { if case .needsUser(HandsConnectFlow.riskAckReason, _) = $0 { return true }; return false }
              && changed == .needsUser(HandsConnectFlow.warningChangedReason, HandsConnectorAck(form: "fabc123461", warning: "w"))
              && unknownBox == .needsUser(HandsConnectFlow.checkboxUnknownReason, HandsConnectorAck(form: "fabc123462", warning: "w"))
              && HandsConnectFlow.warningChangedCardText.contains("TATWO 不替你勾") && HandsConnectFlow.checkboxUnknownCardText.contains("沒見過的勾選框")
              && HandsConnectFlow.consentLine == "按連線＝同意 ChatGPT 開發者模式的風險說明，TATWO 會替你勾選",
              "W183 R10 Pod 回 risk_ack＋那一格的位置＝TATWO 代勾（點格子中間的整數點）；位置不合理＝交給你；警語大改、沒見過的勾選框＝交給你（一句話的原因）；［連線］旁那一行小字",
              "\(tickable) \(badDecoded) \(changed) \(unknownBox)")
        // W183 R9 審查（GPT-6 #2、#6）：勾著、但不是使用者真的按的＝交回給他（講清楚要取消再自己勾）；表單被換掉、Name 被改、確認重放＝拒絕，一句話。
        let untrusted = ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "untrusted_tick", "form": "fabc123457", "warning": "0123abcd-41"])
        let refusals = ["form_replaced", "name_mismatch", "ack_replayed"].map { HandsConnectFlow.refusalText($0) }
        check(untrusted == .needsUser(HandsConnectFlow.untrustedTickReason, HandsConnectorAck(form: "fabc123457", warning: "0123abcd-41"))
              && HandsConnectFlow.untrustedTickCardText.contains("取消、自己再勾一次") && HandsConnectFlow.untrustedTickCardText.contains("［繼續］")
              && refusals.allSatisfy { !$0.contains("_") && $0.contains("已停止") }
              && refusals[0].contains("換掉") && refusals[1].contains("Name") && refusals[2].contains("用過"),
              "W183 R9 審查：勾選框不是你按的＝交回（卡片寫取消再自己勾）；表單被換掉、Name 被改、確認重放＝拒絕（一句話、沒有代號）",
              "\(untrusted) \(refusals)")
        // W183 R9 審查（GPT-6 N3、N9）：一般的警語卡片講清楚「這一次自己再勾一次」；警語太長或看不出範圍＝Pod 回 warning_unbounded（App 改手動）。
        let unbounded = ChatGPTConnectorPod.decodeAction(["status": "needs_user", "reason": "warning_unbounded", "form": "fabc123458", "warning": ""])
        let card = HandsConnectFlow.warningCardText("表單上有警語")
        check(unbounded == .needsUser(HandsConnectFlow.warningUnboundedReason, HandsConnectorAck(form: "fabc123458", warning: ""))
              && card.contains("這一次自己再勾一次") && card.contains("先取消再勾") && card.contains("「繼續」")
              && HandsConnectFlow.untrustedTickCardText.contains("上一次勾的") && HandsConnectFlow.warningUnboundedText.contains("不自動按「Create」")
              && HandsConnectFlow.warningUnboundedText.contains("手動") && !HandsConnectFlow.warningUnboundedText.contains("_"),
              "W183 R9 審查（GPT-6 N3、N9）：每交回一次＝新的一輪（卡片寫這一次自己再勾一次、上一次勾的不算）；警語太長或看不出範圍＝不自動按 Create，一句話請你改手動",
              "\(unbounded) \(card)")
        // W183 R9c（GPT-6 C1）：Pod 的網頁少了安全判斷需要的瀏覽器功能＝拒絕（一句話、沒有代號）。
        let unsafe = HandsConnectFlow.refusalText("unsafe_env")
        let unsafeMenu = ChatGPTPluginNewMenu.resultText(["status": "refused", "reason": "unsafe_env"], item: .mcp)
        check(unsafe.contains("瀏覽器功能") && unsafe.contains("不在上面自動操作") && !unsafe.contains("unsafe_env")
              && unsafeMenu == ChatGPTPluginNewMenu.unsafeEnvText && !unsafeMenu.contains("_"),
              "W183 R9c（GPT-6 C1）：Pod 的網頁少了 TATWO 安全判斷需要的瀏覽器功能＝連接器與「新增」都不自動操作（不退回網頁自己的方法），卡片與原生頁各一句話",
              "\(unsafe) | \(unsafeMenu)")
    }

    // MARK: 原生看到的導頁（GPT-6 C3）

    /// 記憶體裡的 Pod 傳輸：記下每一個指令的內容；holdReplies 裡的指令先不回（還在跑）。
    @MainActor final class NavTransport: ChatGPTPodTransport {
        var onEvent: ((String) -> Void)?
        var isRunning = true
        var isHosted = false
        var holdReplies: Set<String> = []
        private(set) var payloads: [[String: Any]] = []
        private var pending: [(String, String)] = []
        var commands: [String] { payloads.compactMap { $0["cmd"] as? String } }
        var navigatedPaths: [String] { payloads.filter { $0["cmd"] as? String == "connectorNavigated" }.compactMap { $0["path"] as? String } }
        func start() throws { isRunning = true }
        func stop() { isRunning = false }
        func run(_ script: String) {
            guard let open = script.range(of: ".command("), script.hasSuffix(")"),
                  let data = String(script[open.upperBound..<script.index(before: script.endIndex)]).data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = payload["cmd"] as? String, let id = payload["id"] as? String else { return }
            payloads.append(payload)
            if holdReplies.contains(cmd) { pending.append((cmd, id)); return }
            answer(id)
        }
        func release(_ cmd: String) {
            let ready = pending.filter { $0.0 == cmd }
            pending.removeAll { $0.0 == cmd }
            for item in ready { answer(item.1) }
        }
        private func answer(_ id: String) {
            guard let body = try? JSONSerialization.data(withJSONObject: ["type": "result", "id": id, "ok": true, "data": ["ok": true]]) else { return }
            let json = String(decoding: body, as: UTF8.self)
            Task { @MainActor [weak self] in self?.onEvent?(json) }
        }
    }

    /// 連接器拿著 Pod、沒有自己的指令在跑（等使用者看警語、勾選）時，原生看到主框架的路徑換了（含同一份文件裡的 pushState）＝通知網頁腳本
    /// （connectorNavigated 帶那個路徑）；同一個路徑不重送；指令在跑、沒拿著 Pod＝不送。
    @MainActor static func r9NavigationNotice(_ check: Checker) async {
        let transport = NavTransport()
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let surface = LeaseSurface()
        let pod = ChatGPTConnectorPod(tap: tap, surface: { surface })
        pod.restoreTimeout = 2
        pod.attach()
        surface.onPluginsLoaded = { transport.onEvent?(#"{"type":"hello","loggedIn":true}"#) }
        surface.commit("https://chatgpt.com/plugins")
        let acquired = await pod.acquireExclusive(timeout: 1)
        surface.commit("https://chatgpt.com/gpts/mine")
        let notified = await waitUntil(2) { transport.navigatedPaths == ["/gpts/mine"] }
        surface.commit("https://chatgpt.com/gpts/mine?tab=1")
        surface.commit("https://chatgpt.com/plugins")
        let back = await waitUntil(2) { transport.navigatedPaths == ["/gpts/mine", "/plugins"] }
        // 指令在跑（連接器自己換頁、網頁腳本自己看得到）：不另外通知。
        transport.holdReplies = ["connectorScan"]
        let scanning = Task { @MainActor in _ = await pod.scan(url: "https://host.example.com/mcp") }
        _ = await waitUntil(2) { transport.commands.contains("connectorScan") }
        surface.commit("https://chatgpt.com/plugins/installed")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let quietWhileRunning = transport.navigatedPaths == ["/gpts/mine", "/plugins"]
        transport.release("connectorScan")
        await scanning.value
        // 放掉 Pod 之後：不通知。
        pod.releaseExclusive()
        _ = await waitUntil(3) { tap.connectorHold == nil }
        surface.commit("https://chatgpt.com/c/abc")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let quietWithoutHold = transport.navigatedPaths == ["/gpts/mine", "/plugins"]
        let encoded = ChatGPTConnectorPod.observedPath(URL(string: "https://chatgpt.com/a%20b/c?x=1")!) == "/a%20b/c"
            && ChatGPTConnectorPod.observedPath(URL(string: "https://chatgpt.com")!) == "/"
        check(acquired && notified && back && quietWhileRunning && quietWithoutHold && encoded,
              "W183 R9c（GPT-6 C3）：連接器拿著 Pod、沒有自己的指令在跑時，原生看到主框架的路徑換了（含同一份文件裡的導頁）就告訴網頁腳本那個路徑（離開過＝那一張的確認永久作廢）；同一個路徑不重送；指令在跑、放掉 Pod 之後不送",
              "\(transport.navigatedPaths) acquired=\(acquired) notified=\(notified) back=\(back) running=\(quietWhileRunning) released=\(quietWithoutHold) encoded=\(encoded)")
    }

    // MARK: 警語太長或看不出範圍（GPT-6 N9）

    @MainActor static func r9WarningUnbounded(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r9-unbounded")
        world.pod.createResult = .needsUser(HandsConnectFlow.warningUnboundedReason, HandsConnectorAck(form: "fr9long0001", warning: ""))
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let manual = await waitUntil(5) { world.flow.phase == .needsManual }
        let closed = await waitUntil(3) { world.service.auth.windowExpiresAt == nil }
        let resumed = world.pod.calls.contains("create-resume")
        check(manual && closed && !resumed && world.flow.problem == HandsConnectFlow.warningUnboundedText
              && world.flow.card == .needsManual(HandsConnectFlow.warningUnboundedText) && !world.presenter.codeEverVisible,
              "W183 R9 審查（GPT-6 N9）：Pod 說警語太長或看不出範圍＝這次不自動按 Create（窗口關掉、不帶確認再試），卡片一句話請你改手動",
              "\(world.pod.calls) \(String(describing: world.flow.problem))")
        world.flow.cancel(reason: "test_done")
    }

    // MARK: 「I understand and want to continue」

    @MainActor static func r9RiskAck(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r9-risk")
        let seen = HandsConnectorAck(form: "fr9risk0001", warning: "89abcdef-120")
        world.pod.createQueue = [.needsUser(HandsConnectFlow.riskAckReason, seen)]
        let chatgpt = FakeChatGPT(service: world.service)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let waiting = await waitUntil(5) {
            if case .waitingUser(let text, continuable: true)? = world.flow.card { return text == HandsConnectFlow.riskAckCardText }
            return false
        }
        let windowClosed = world.service.auth.windowExpiresAt == nil
        world.chatgptStarts(chatgpt)
        world.flow.continueAfterUser()
        let paired = await waitUntil(8) { world.pairing?.pairingCode != nil }
        let text = HandsConnectFlow.riskAckCardText
        check(waiting && windowClosed && paired && world.pod.acks.count == 2 && world.pod.acks[0] == nil && world.pod.acks[1] == seen
              && world.pod.calls.contains("create") && world.pod.calls.contains("create-resume") && !world.pod.calls.contains("tick")
              && text.hasPrefix("TATWO 這次沒辦法替你勾") && text.contains("自己勾「I understand and want to continue」") && text.contains("再按［繼續］"),
              "W183 R10 退路：Pod 量不到「I understand and want to continue」那一格的位置＝不代勾，卡片寫「TATWO 這次沒辦法替你勾…自己勾…，再按［繼續］」；等的時候窗口關著；按［繼續］才帶回同一張表單再按 Create",
              "\(world.pod.calls) \(String(describing: world.flow.card))")
        world.flow.cancel(reason: "test_done")
    }

    // MARK: 找不到「新增 → 建立 MCP 應用程式」、Connection 不是 Server URL

    @MainActor static func r9NewMenuMissing(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r9-missing")
        world.pod.createResult = .notFound("new_button")
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let manual = await waitUntil(5) { world.flow.phase == .needsManual }
        let closed = await waitUntil(3) { world.service.auth.windowExpiresAt == nil }
        check(manual && closed && world.flow.problem == HandsConnectFlow.newMenuMissingText
              && world.flow.card == .needsManual(HandsConnectFlow.newMenuMissingText) && world.flow.problem?.contains("new_button") == false
              && !world.presenter.codeEverVisible,
              "W183 R9 外掛頁找不到「新增 → 建立 MCP 應用程式」：這次取消（窗口關掉）、卡片寫一句話（改版或沒開開發者模式；再連一次或手動），沒有代號、沒有碼",
              String(describing: world.flow.problem))

        let tunnel = try World(base, "r9-tunnel")
        tunnel.pod.createResult = .refused("connection_not_server_url")
        tunnel.flow.offer()
        _ = await waitUntil(5) { isConfirm(tunnel.flow.card) }
        tunnel.flow.connect()
        let refused = await waitUntil(5) { tunnel.flow.phase == .refused }
        let tunnelClosed = await waitUntil(3) { tunnel.service.auth.windowExpiresAt == nil }
        check(refused && tunnelClosed && tunnel.flow.problem == HandsConnectFlow.refusalText("connection_not_server_url")
              && !tunnel.presenter.codeEverVisible,
              "W183 R9 表單的 Connection 不是 Server URL（Tunnel、讀不出來）：明確不符＝終止、窗口關掉、沒有顯示碼（TATWO 不用 Tunnel）",
              String(describing: tunnel.flow.problem))
    }

    // MARK: 手動模式的步驟

    @MainActor static func r9Manual(_ check: Checker, _ base: URL) async throws {
        for (label, known, matches) in [
            ("unknown", false, [HandsConnectorScan.Match]()),
            ("empty", true, []),
            ("existing", true, [.init(id: "fixture", name: "TATWO（Primary One）", auth: "oauth")])
        ] {
            let world = try World(base, "w321-manual-" + label)
            world.pod.scanResult = HandsConnectorScan(listKnown: known, devMode: true, matches: matches)
            world.pod.createResult = .notFound("mcp_item")
            world.pod.reconnectResult = .notFound("open")
            world.flow.offer()
            _ = await waitUntil(5) { isConfirm(world.flow.card) }
            world.flow.connect()
            _ = await waitUntil(5) { world.flow.phase == .needsManual }
            world.flow.retry(manual: true)
            let shown = await waitUntil(5) { if case .manual? = world.flow.card { return true }; return false }
            var steps: [String] = []
            if case .manual(_, let list)? = world.flow.card { steps = list }
            let all = steps.joined(separator: "\n")
            let reuse = !known || !matches.isEmpty
            let words = reuse
                ? ["Plugins", "Installed", "TATWO（Primary One）", "Manage", "Plugin settings", "URL 完全等於", "https://\(publicHost)/mcp", "Reconnect", "8 碼"]
                : ["Plugins", "Add", "Add custom MCP server", "Name（名稱）填 TATWO（Primary One）", "Server URL", "https://\(publicHost)/mcp", "OAuth", "I understand and want to continue", "Create as a plugin", "8 碼"]
            let order = words.map { all.range(of: $0)?.lowerBound }
            let inOrder = order.allSatisfy { $0 != nil } && zip(order, order.dropFirst()).allSatisfy { ($0.0 ?? all.startIndex) <= ($0.1 ?? all.startIndex) }
            check(shown && inOrder && world.pod.calls.contains("highlight") && world.pod.calls.filter { $0 == "scan" }.count == 2
                  && world.copied == ["https://\(publicHost)/mcp"] && all.contains("只在你自己剛按了")
                  && (!reuse || (all.contains("如果 Installed 裡沒有任何 TATWO 才改走新建") && !all.contains("Create as a plugin"))),
                  "W321 手動卡 \(label)：讀不到先沿用，完整清單確定沒有才新建；新版按鈕、URL 與 8 碼提醒", all)
            world.flow.cancel(reason: "test_done")
        }
    }

    // MARK: 專案：卡片與 ChatGPT Dev 面板說法一致（W183 R10：兩邊都是這台全部專案）

    @MainActor static func r9Projects(_ check: Checker, _ base: URL) throws {
        let fx = try scopeFixture(base, "r9-projects")
        let (service, host) = try scopeHost(base, "r9-projects", fx)
        // 實機的樣子：ChatGPT build 給這台的中央清單一個都沒勾（R10 起不再有勾選）。
        service.scopeCap = { (level: 2, projects: []) }
        let card = try host.offer(includeChoices: true)
        let panel = service.buildProjectChoices()
        let remote = HandsConnectOffer(wire: card.wire)
        check(card.scope.allProjects && Set(card.scope.projects.map(\.id)) == Set(panel.map(\.id)) && panel.count == fx.visible.count
              && !card.supportsChoice && remote?.digest == card.digest && remote?.scope.projects.count == panel.count,
              "W183 R10 專案：卡片（也經設備簽章 RPC 給副設備）與 ChatGPT Dev 面板是同一份——這台全部能當專案的；不再有「先到 ChatGPT Dev 勾」",
              "card=\(card.scope.projects.map(\.name)) panel=\(panel.map(\.name))")
        let marked = Set(panel.filter(\.readOnlyFloor).map(\.id))
        check(marked == [fx.trading.uuidString, fx.hermes.uuidString] && Set(card.scope.readOnlyProjectIDs) == marked
              && HandsConnectConfirmContent.tradingNote(card)?.contains("2 個交易類專案只能看") == true
              && HandsConnectConfirmContent.projectsText(card) == "這台全部（\(panel.count) 個）",
              "W183 R10 底線 B：面板的「只能看」與卡片的交易類清單用同一個判斷（名字、資料夾名）；卡片寫「這台全部（N 個）」＋交易類只能看",
              "\(marked.count) \(String(describing: HandsConnectConfirmContent.tradingNote(card)))")

        // 面板：專案 chip 只顯示（全部在範圍裡、交易類標只能看）；「沒勾」的提示沒了，換成一句「全部可見」；勾專案的動作什麼都不做。
        let deviceA = "FIXTURE-DEVICE-A"
        let project = HandsBuildProject(id: deviceA + "/p1", name: "Project one", selected: true, deviceID: deviceA, active: true, readOnly: false)
        let trading = HandsBuildProject(id: deviceA + "/p2", name: "BTC 實盤", selected: true, deviceID: deviceA, active: true, readOnly: true)
        check(project.selected && trading.readOnly && card.scope.allProjects,
              "W224-5 專案範圍仍是全部、交易類仍只能看；退休畫面文字不作為範圍證據")
        W224Acceptance.compactBuild { value, label in check(value, label, "native current card") }
    }
}
#endif
