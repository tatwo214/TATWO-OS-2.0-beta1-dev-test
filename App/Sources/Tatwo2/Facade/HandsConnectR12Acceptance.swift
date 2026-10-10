#if DEBUG
import Combine
import Foundation

// W183 R12 第一批自測（w183connect；.032 實機驗收後，主導 1、3、5）：
// - 3：ChatGPT 的說明改了、腳本讀得到全文＝卡片顯示全文＋［同意並繼續］；按了＝記下這一版（只記雜湊）、帶著它再走一次（TATWO 代勾）；
//   下次同一版＝不出卡片、自動帶著它；帶著同意再走一次還是對不上＝回到卡片（不一直重來）。
// - 5：按過建立、清單裡找不到＝重開 App 也記得；只有當輪確認不存在後重試才重建一次，不清持久紀錄。
// - 1：收起私訊框（連線的網頁不在畫面上）＝等的時間不倒數、流程不取消；打開之後照常倒數。
// W183 R12 第二批（主導 4：拿掉等級選擇，使用者 09-30 裁決）：
// - 中央設定所有設備一律 L2：還沒照過的一份照一次（低於 L2 的都記成待升，L0 也算；不直接升）；升不升照 R11 同一道 raiseCheck。
// - 畫面寫能力、不寫 L0／L1／L2：面板那一行、確認卡那一行（同一句）、狀態「已連線・Codex、記憶」。
// W183 R12 第二批（主導 2：要真人點的那一步指給他看）：
// - 按了建立、等配對頁：Pod 指出那一顆（亮框＋箭頭）＝卡片「點一下亮起來的「連接」」（兩頁時「右邊亮起來的」）；配對頁出來＝拿掉亮框。
// - 指不出來＝照舊那一句（「在上面的頁面點一下」）；手動模式不指；TATWO 不按（Pod 只有指的方法）。

extension HandsConnectAcceptance {
    @MainActor static func r12Checks(_ check: Checker, _ base: URL) async throws {
        try await r12Consent(check, base)
        try await r12PendingCreates(check, base)
        try await r12MissingNameRecovery(check, base)
        try await r12HiddenWait(check, base)
        r12Levels(check)   // W183 R12 第二批（主導 4）
        try await r12Gesture(check, base)   // W183 R12 第二批（主導 2）
        try await r12ConnectLog(check, base)   // W183 R12（.033 實機）：正式版的連線紀錄
        try await w304bInstalled(check, base)
        r12DomTick(check)   // W183 R12（.034 實機）：代勾改走 DOM 驗證
        try await r12PopupWait(check, base)   // W183 R12（.035 實機）：ChatGPT 的對話框停在等它的授權視窗
        try await r12UserPress(check, base)   // W183 R12（.036 實機）：量不到 Create＝請使用者自己按；ChatGPT 沒建成＝講清楚
        try await r12Continue(check, base)   // W183 R12（.037 實機）：Continue to …、用記下的名字接著連
    }

    @MainActor static func r12Continue(_ check: Checker, _ base: URL) async throws {
        // 建成之後 ChatGPT 開「Connect <名字>」對話框：TATWO 自己真的點擊按「Continue to <名字>」，卡片說它按了、等配對頁。
        let clicked = try World(base, "r12-continue")
        clicked.pod.gestureClickedLabel = "Continue to TATWO（Primary One）"
        guard await r12Start(clicked) else { return check(false, "W183 R12 Continue：確認卡沒出來") }
        let said = await waitUntil(3) {
            if case .working(let text)? = clicked.flow.card { return text == HandsConnectFlow.continueClickedText("Continue to TATWO（Primary One）") }
            return false
        }
        clicked.flow.cancel(reason: "r12-continue")
        // 點不中（亮起來）＝卡片寫那一顆的字。
        let lit = try World(base, "r12-continue-lit")
        lit.pod.gestureResult = true
        lit.pod.gestureLabel = "Continue to TATWO（Primary One）"
        guard await r12Start(lit) else { return check(false, "W183 R12 Continue（亮起來）：確認卡沒出來") }
        let pointed = await waitUntil(3) {
            if case .working(let text)? = lit.flow.card { return text == "點一下亮起來的「Continue to TATWO（Primary One）」" }
            return false
        }
        let sided = HandsConnectCardContext.live(lit.flow, revealsCode: false, webOnRight: true).sided(lit.flow.progressHint ?? "")
        lit.flow.cancel(reason: "r12-continue-lit")
        check(said && pointed && sided.hasPrefix("點一下右邊亮起來的「Continue to TATWO（Primary One）」"),
              "W183 R12（.037 實機）建成之後的「Connect <名字>」對話框：TATWO 自己真的點擊按「Continue to <名字>」（卡片說它按了、等配對頁）；點不中＝亮起來、卡片寫「點一下右邊亮起來的「Continue to …」」",
              "said=\(said) pointed=\(pointed) sided=\(sided)")
        // A collision tries the original name once and can never create a numbered sibling.
        let first = try World(base, "r12-byname-a")
        first.pod.gestureRejected = "An app with this name already exists. Choose another name"
        first.pod.byNameResult = .pressed
        guard await r12Start(first) else { return check(false, "W208 collision confirmation") }
        let reused = await waitUntil(5) { first.pod.byNameCalls.count == 1 }
        check(reused && first.pod.createdNames == ["TATWO（Primary One）"]
              && first.pod.byNameCalls == ["TATWO（Primary One）"],
              "W208 collision reconnects the exact original name without a second Create")
        first.flow.cancel(reason: "r12-byname-a")
    }

    @MainActor static func r12UserPress(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r12-user-press")
        world.pod.userPressDelay = 800_000_000
        guard await r12Start(world) else { return check(false, "W183 R12 自己按 Create：確認卡沒出來") }
        let asked = await waitUntil(4) {
            if case .working(let text)? = world.flow.card { return text == HandsConnectFlow.createByUserText }
            return false
        }
        let sided = HandsConnectCardContext.live(world.flow, revealsCode: false, webOnRight: true).sided(world.flow.progressHint ?? "")
        let moved = await waitUntil(4) { world.flow.progressStep == 2 }
        check(asked && sided.hasPrefix("點一下右邊亮起來的「Create」") && moved && world.pod.calls.filter { $0.hasPrefix("create") }.count == 1,
              "W183 R12（.036 實機）TATWO 量不到、點不中 Create：不退回程式按（程式按沒有真人手勢、ChatGPT 的授權視窗出不來）——卡片「點一下右邊亮起來的「Create」」，使用者按了照常接手（到第 3 步）",
              "asked=\(asked) sided=\(sided) step=\(world.flow.progressStep)")
        world.flow.cancel(reason: "r12-user-press")
        let taken = try World(base, "r12-name-taken")
        taken.pod.gestureRejected = "An app with this name already exists. Choose another name"
        guard await r12Start(taken) else { return check(false, "W208 collision confirmation") }
        let stoppedCollision = await waitUntil(5) { taken.flow.phase == .needsManual }
        check(stoppedCollision && taken.pod.createdNames == ["TATWO（Primary One）"]
              && taken.pod.byNameCalls == ["TATWO（Primary One）"],
              "W208 missing namesake stops at manual card and never renames/recreates")
        taken.flow.cancel(reason: "r12-name-taken")
        let rejected = try World(base, "r12-rejected")
        rejected.pod.gestureRejected = "Something went wrong while creating the app. Try again"
        guard await r12Start(rejected) else { return check(false, "W183 R12 沒建成：確認卡沒出來") }
        let stopped = await waitUntil(4) { rejected.flow.phase == .needsManual }
        let text: String = { if case .needsManual(let text)? = rejected.flow.card { return text }; return "" }()
        check(stopped && text.contains("沒建成") && text.contains("Something went wrong") && text.contains("再連一次")
              && rejected.pod.gestureClears >= 1,
              "W183 R12（.036 實機）ChatGPT 在對話框裡說沒建成（不是撞名的錯）：馬上停下、白話講為什麼與要做什麼（不換名、不替你刪 ChatGPT 裡的東西），不再空等 10 分鐘",
              "text=\(text)")
    }

    @MainActor static func r12PopupWait(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r12-popup-wait")
        world.pod.gestureWaiting = true
        guard await r12Start(world) else { return check(false, "W183 R12 等授權視窗：確認卡沒出來") }
        let noticed = await waitUntil(4) {
            if case .working(let text)? = world.flow.card { return text == HandsConnectFlow.popupWaitText }
            return false
        }
        let hint = world.flow.progressHint ?? ""
        let snapshots = world.pod.gesturePoints
        world.pod.gestureWaiting = false
        let back = await waitUntil(3) {
            if case .working(let text)? = world.flow.card { return text == HandsConnectFlow.gestureWaitText }
            return false
        }
        check(noticed && hint.hasPrefix(HandsConnectFlow.popupWaitShort + "・剩 ") && snapshots >= 2 && back && world.flow.phase != .needsManual,
              "W183 R12（.035 實機）按了 Create 之後 ChatGPT 的對話框停在等待：一陣子之後卡片說「ChatGPT 在等它的授權視窗…」＋還剩多久（不判找不到、不放棄）；對話框不等了＝回到「點一下頁面上的「Connect」」",
              "noticed=\(noticed) hint=\(hint) back=\(back) card=\(String(describing: world.flow.card))")
        world.flow.cancel(reason: "r12-popup-wait")
    }

    // MARK: 代勾走 DOM 驗證（.034 實機：CEF 的畫面快照整頁只有 1 個控制項）

    @MainActor static func r12DomTick(_ check: Checker) {
        typealias P = ChatGPTConnectorPod
        let target = HandsTickTarget(x: 57, y: 529, width: 16, height: 16, viewportWidth: 524, viewportHeight: 617, generation: 1)
        // .034 的樣子：CEF 快照整頁只有 1 個控制項（不在那一格）＝認不到——這不再是「找不到」：改走 DOM 驗證。
        let sparse: [String: Any] = ["origin": "https://chatgpt.com", "navigationGeneration": NSNumber(value: 1), "viewport": ["width": 524, "height": 617],
                                     "controls": [["kind": "button", "elementID": "cef-9", "rect": ["x": 400, "y": 20, "width": 30, "height": 30]] as [String: Any]]]
        let empty: [String: Any] = ["origin": "https://chatgpt.com", "navigationGeneration": NSNumber(value: 1), "viewport": ["width": 524, "height": 617], "controls": [[String: Any]]()]
        let noCEF = P.tickControl(sparse, target: target, generation: 1, viewport: NSSize(width: 524, height: 617)) == nil
            && P.tickControl(empty, target: target, generation: 1, viewport: NSSize(width: 524, height: 617)) == nil
        let size = NSSize(width: 524, height: 617)
        let ok: [String: Any] = ["status": "ok", "tick": ["x": 57, "y": 529, "w": 16, "h": 16, "vw": 524, "vh": 617]]
        let point = P.domClickPoint(ok, generation: 1, viewSize: size, zoomLevel: 0)
        let refused = [P.domClickPoint(["status": "changed", "why": "consent"], generation: 1, viewSize: size, zoomLevel: 0),
                       P.domClickPoint(ok, generation: 1, viewSize: NSSize(width: 500, height: 617), zoomLevel: 0),
                       P.domClickPoint(ok, generation: 1, viewSize: size, zoomLevel: 1),
                       P.domClickPoint(["status": "ok", "tick": ["x": 520, "y": 529, "w": 16, "h": 16, "vw": 524, "vh": 617]], generation: 1, viewSize: size, zoomLevel: 0),
                       P.domClickPoint(nil, generation: 1, viewSize: size, zoomLevel: 0)]
        check(noCEF && point == NSPoint(x: 65, y: 537) && refused.allSatisfy { $0 == nil },
              "W183 R12（.034 實機）代勾：CEF 快照認不到（整頁只有 1 個控制項、或空的）不再當成找不到——腳本在同一份文件再驗一次、量位置，點那一格的中心（57,529 16×16 → 65,537）；狀態不是 ok、畫面大小對不上、有縮放（zoomLevel 0＝100%）、位置出界＝不點",
              "point=\(String(describing: point))")
        let strip: [String: Any] = ["status": "ok", "tick": ["x": 40, "y": 613, "w": 320, "h": 4, "vw": 524, "vh": 617]]
        check(P.domClickPoint(strip, generation: 1, viewSize: size, zoomLevel: 0, minimumHeight: 4) == NSPoint(x: 200, y: 615)
              && P.domClickPoint(strip, generation: 1, viewSize: size, zoomLevel: 0) == nil
              && P.domClickPoint(strip, generation: 1, viewSize: size, zoomLevel: 1, minimumHeight: 4) == nil,
              "W304b Create accepts the measured 4px strip at 100% zoom; checkbox and zoom guards stay strict")
        check(P.tickTook(["status": "ok", "checked": true, "create": true]) && !P.tickTook(["status": "ok", "checked": true, "create": false])
              && !P.tickTook(["status": "ok", "checked": false, "create": true]) && !P.tickTook(["status": "gone"]) && !P.tickTook(nil),
              "W183 R12 代勾點完用 DOM 確認：勾上了而且 Create 能按才算；不然交回使用者（不點第二次）")
    }

    // MARK: 正式版的連線紀錄（.033 實機：失敗了查不到任何紀錄）

    @MainActor static func r12ConnectLog(_ check: Checker, _ base: URL) async throws {
        // 檔案：0600、一行一步、遮掉信箱／token／查詢字串／碼；結構快照一行（換行寫成 ⏎）；超過上限只留最後一段。
        let url = base.appendingPathComponent("r12-connect-log/connect-log.txt")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        let log = HandsConnectLog(url: url, maxBytes: 4096, keepBytes: 2048)
        log.begin(attempt: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000000"))
        let fakeMail = "someone" + "@" + "example.com"   // 假的（拼起來：原始碼裡不留信箱樣子的字）
        log.write("flow", "account \(fakeMail) token Bearer abc.def-ghi code ABCD-2345 page https://chatgpt.com/x?code=SECRET#frag long 0123456789abcdef0123456789abcdef01")
        log.structure("pod", "connectorCreate needs_user outline", "div role=dialog\n button \"Create\"\n input type=checkbox name=ack checked=0")
        let lines = log.tail(10)
        let text = lines.joined(separator: "\n")
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        check(lines.count == 2 && text.contains("\t0a1b2c3d\tflow\t") && text.contains("<email>") && text.contains("Bearer <token>") && text.contains("<code>")
              && text.contains("https://chatgpt.com/x?<…>") && text.contains("<token>") && !text.contains("someone@") && !text.contains("SECRET")
              && !text.contains("ABCD-2345") && !text.contains("abc.def") && text.contains("⟦div role=dialog⏎ button \"Create\"⏎ input type=checkbox name=ack checked=0⟧")
              && mode == 0o600,
              "W183 R12（.033 實機）正式版的連線紀錄：一行一步（時間、這次嘗試的代號、步驟、內容）、結構快照整段一行；信箱、token、配對碼、網址查詢字串一律遮掉；檔案 0600",
              "mode=\(String(describing: mode)) \(text.prefix(600))")
        let accountName = "Custom Display Persona", accountMail = "custom-persona" + "@" + "example.invalid"
        let accountTree = "div role=dialog\n section aria=\"\(accountName)\"\n  h3 \"Accounts\"\n  p aria=\"\(accountName)\" title=\"\(accountName)\" \"\(accountName)\"\n  img alt=\"\(accountName)\"\n  p \"\(accountMail)\"\n section\n  h3 \"About\""
        log.structure("pod", "account privacy", accountTree)
        log.write("pod", "account_name=\(accountName) email=\(accountMail)")
        let accountLog = log.tail(2).joined(separator: "\n")
        check(accountLog.contains("(account)") && !accountLog.contains(accountName) && !accountLog.contains(accountMail) && accountLog.contains("About"),
              "W294b second log mask removes custom account names, email and aria/title/alt subtree")
        for index in 0..<120 { log.write("flow", "filler line \(index) " + String(repeating: "x", count: 40)) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let rotated = log.tail(500)
        check(size <= 4096 && rotated.last?.contains("filler line 119") == true && !(rotated.first?.contains("filler line 0 ") ?? true)
              && rotated.allSatisfy { $0.split(separator: "\t").count >= 4 },
              "W183 R12 連線紀錄超過上限：只留最後一段（整行為單位）；最新的在",
              "size=\(size) first=\(rotated.first?.prefix(80) ?? "")")
        // 流程：跑一次到配對卡——每一步都有一行（嘗試第幾次、卡片、進度、Pod 的結果），配對碼不進紀錄。
        let flowURL = base.appendingPathComponent("r12-connect-log/flow-log.txt")
        let flowLog = HandsConnectLog(url: flowURL)
        let world = try World(base, "r12-connect-log", connectLog: flowLog)
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt, popup: 3)
        guard await r12Start(world) else { return check(false, "W183 R12 連線紀錄：確認卡沒出來") }
        let paired = await waitUntil(5) { world.pairing?.pairingCode != nil }
        let code = world.pairing?.pairingCode ?? "no-code"
        let flowText = flowLog.tail(200).joined(separator: "\n")
        let spaced = code.count == 8 ? String(code.prefix(4)) + " " + String(code.suffix(4)) : code
        check(paired && flowText.contains("attempt #1 manual=false") && flowText.contains("card working: ") && flowText.contains("step 3/4")
              && flowText.contains("action pressed") && flowText.contains("card pairing code_shown=true")
              && !flowText.contains(code) && !flowText.contains(spaced),
              "W183 R12 流程的每一步都進紀錄（第幾次嘗試、卡片、進度、按了建立），配對碼不進紀錄",
              "paired=\(paired) \(flowText.prefix(1200))")
        world.flow.cancel(reason: "r12-connect-log")
    }

    // MARK: 要真人點的那一步指給他看（主導 2）

    @MainActor static func r12Gesture(_ check: Checker, _ base: URL) async throws {
        // 指出來了：卡片那一句＋進度點下面那一句都是「點一下亮起來的「連接」」；兩頁時說「右邊亮起來的」；配對頁出來＝拿掉亮框。
        let world = try World(base, "r12-gesture")
        world.pod.gestureResult = true
        guard await r12Start(world) else { return check(false, "W183 R12 指路：確認卡沒出來") }
        let pointed = await waitUntil(3) {
            if case .working(let text)? = world.flow.card { return text == HandsConnectFlow.gesturePointText }
            return false
        }
        let hint = world.flow.progressHint
        let context = HandsConnectCardContext.live(world.flow, revealsCode: false, webOnRight: true)
        let sidedHint = hint.map(context.sided)
        let points = world.pod.gesturePoints
        // 等了一陣子也不換成「在上面的頁面點一下」（指著的時候照舊指著：每幾秒看一次它還在不在）。
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        let kept: Bool = { if case .working(let text)? = world.flow.card { return text == HandsConnectFlow.gesturePointText }; return false }()
        // 使用者按了亮起來的那一顆＝ChatGPT 開始 OAuth、另開視窗打開 TATWO 的配對頁。
        let chatgpt = FakeChatGPT(service: world.service)
        _ = try? chatgpt.register()
        let (_, status) = chatgpt.begin()
        world.pod.emit(chatgpt.authorizeURL, status: status, popup: 7)
        let cleared = await waitUntil(3) { world.pod.gestureClears >= 1 }
        // W183 R12（.034 實機）：進度點下面那一句後面帶倒數（「・剩 9:58」）；那一顆寫 Connect（真的 ChatGPT 是英文介面）。
        check(pointed && hint?.hasPrefix(HandsConnectFlow.gesturePointText + "・剩 ") == true
              && sidedHint?.hasPrefix("點一下右邊亮起來的「Connect」・剩 ") == true && points >= 1 && kept && cleared
              && !world.pod.calls.contains(where: { $0.hasPrefix("press") }),
              "W183 R12（主導 2）要真人點的那一步：Pod 指出那一顆（亮框＋箭頭）＝卡片「點一下亮起來的「Connect」」（兩頁時「點一下右邊亮起來的「Connect」」、後面帶倒數）；指著的時候不換成舊的那一句；配對頁出來＝拿掉亮框；TATWO 不按",
              "pointed=\(pointed) hint=\(String(describing: hint)) sided=\(String(describing: sidedHint)) points=\(points) kept=\(kept) cleared=\(world.pod.gestureClears)")
        world.flow.cancel(reason: "r12-gesture")
        // 指不出來（找不到那一顆、CEF 核不過）：照舊那一句。
        let missing = try World(base, "r12-gesture-missing")
        missing.pod.gestureResult = false
        guard await r12Start(missing) else { return check(false, "W183 R12 指路（找不到）：確認卡沒出來") }
        let fellBack = await waitUntil(3) {
            if case .working(let text)? = missing.flow.card { return text == HandsConnectFlow.gestureWaitText }
            return false
        }
        let hintNow = missing.flow.progressHint ?? ""
        let sidedNow = HandsConnectCardContext.live(missing.flow, revealsCode: false, webOnRight: true).sided(hintNow)
        check(fellBack && hintNow.hasPrefix(HandsConnectFlow.gestureHintShort + "・剩 ") && sidedNow.hasPrefix("點一下右邊的頁面上的「Connect」")
              && missing.flow.phase != .needsManual && missing.pod.gesturePoints >= 1,
              "W183 R12（.034 實機）找不到那一顆：卡片講清楚「點一下上面的頁面上的「Connect」」（兩頁時「右邊的頁面」）＋還剩多久；不會一分鐘就放棄",
              "card=\(String(describing: missing.flow.card)) points=\(missing.pod.gesturePoints)")
        missing.flow.cancel(reason: "r12-gesture-missing")
    }

    /// 改版後的一份同意內容（假的；純文字＋連結的字與網域）。
    static let r12Offer = HandsConsentOffer(
        text: "New Plugin Name Connection Server URL Authentication OAuth Custom MCP servers introduce risk. I understand and want to continue "
            + "Only connect to MCP servers you trust (reworded 2026-09-30). Cancel Create",
        links: [HandsConsentOffer.Link(text: "Learn more", origin: "https://help.openai.com")],
        print: "user\nNew Plugin Name Connection Server URL Authentication OAuth Custom MCP servers introduce risk. I understand and want to continue "
            + "Only connect to MCP servers you trust (reworded 2026-09-30). Cancel Create\nLearn more -> https://help.openai.com")

    @MainActor static func r12Start(_ world: World) async -> Bool {
        world.flow.offer()
        guard await waitUntil(5, { isConfirm(world.flow.card) }) else { return false }
        world.flow.connect()
        return true
    }

    @MainActor static func r12Consent(_ check: Checker, _ base: URL) async throws {
        let bookURL = base.appendingPathComponent("r12-consent-approvals.json")
        try? FileManager.default.removeItem(at: bookURL)
        let book = HandsConnectDigestBook(url: bookURL, maxEntries: 16)
        let world = try World(base, "r12-consent", consentApprovals: book)
        let ack = HandsConnectorAck(form: "fr12a1b2c3", warning: "0badf00d-10", consent: r12Offer)
        // 帶著同意再走一次之後就停在「找不到」（不按建立：不留「按過建立」的紀錄，下一輪照樣走到表單）。
        world.pod.createResult = .notFound("r12_stop")
        world.pod.createQueue = [.needsUser(HandsConnectFlow.warningChangedReason, ack)]
        var cards: [HandsConnectCard?] = []
        let watch = world.flow.$card.sink { cards.append($0) }
        defer { watch.cancel() }
        let started = await r12Start(world)
        let shown = await waitUntil(5) { if case .consent(let offer)? = world.flow.card { return offer == r12Offer }; return false }
        let face = world.flow.card.map { HandsConnectCardFace.make($0, phase: world.flow.phase) }
        check(started && shown && face?.kind == .consent && face?.actions == [.approveConsent] && face?.title == HandsConnectCardFace.consentTitle
              && world.flow.phase == .waitingUser && !book.contains(r12Offer.digest),
              "W183 R12（主導 3）ChatGPT 的說明改了、讀得到全文：卡片顯示那一段全文＋［同意並繼續］（不叫你去小網頁找勾選框）；還沒按＝什麼都沒記",
              "card=\(String(describing: world.flow.card)) calls=\(world.pod.calls)")
        world.flow.approveConsent()
        let resumed = await waitUntil(5) { world.pod.acks.count >= 2 }
        let carried = world.pod.acks.last.flatMap { $0 }
        check(resumed && book.contains(r12Offer.digest) && carried?.approved == r12Offer.print && carried?.form == ack.form
              && book.entries.count == 1 && book.entries.first?.digest.count == 64,
              "W183 R12（主導 3）按［同意並繼續］＝記下這一版（本機只記 SHA-256）、帶著它再走一次（網頁腳本整份一字不差才代勾）",
              "acks=\(world.pod.acks.count) approved=\(carried?.approved != nil) book=\(book.entries.count)")
        world.flow.cancel(reason: "test_done")

        // 下次同一版：不出卡片，直接帶著同意過的那一份。
        cards.removeAll()
        let before = world.pod.acks.count
        world.pod.createQueue = [.needsUser(HandsConnectFlow.warningChangedReason, ack)]
        let again = await r12Start(world)
        let auto = await waitUntil(5) { world.pod.acks.count >= before + 2 }
        let autoAck = world.pod.acks.last.flatMap { $0 }
        let sawCard = cards.contains { if case .consent? = $0 { return true }; return false }
        check(again && auto && autoAck?.approved == r12Offer.print && !sawCard,
              "W183 R12（主導 3）同一版以前同意過：不出卡片、TATWO 自動帶著它代勾（恢復一鍵完成）",
              "auto=\(auto) sawCard=\(sawCard) acks=\(world.pod.acks.count - before)")
        world.flow.cancel(reason: "test_done")

        // 帶著同意再走一次，網頁還是說對不上（同一份）＝回到卡片，不一直自動重來。
        cards.removeAll()
        world.pod.createQueue = [.needsUser(HandsConnectFlow.warningChangedReason, ack),
                                 .needsUser(HandsConnectFlow.warningChangedReason, ack.approving(r12Offer.print))]
        let third = await r12Start(world)
        let backToCard = await waitUntil(6) { if case .consent? = world.flow.card { return true }; return false }
        let resumes = world.pod.calls.filter { $0 == "create-resume" }.count
        check(third && backToCard,
              "W183 R12（主導 3）帶著同意過的那一份再走一次還是對不上：回到［同意並繼續］的卡（不會一直自動重來）",
              "card=\(String(describing: world.flow.card)) resumes=\(resumes)")
        world.flow.cancel(reason: "test_done")

        // 讀不到全文（腳本沒給那一份）：照舊請使用者自己勾（原本的退路卡）。
        world.pod.createQueue = [.needsUser(HandsConnectFlow.warningChangedReason, HandsConnectorAck(form: "fr12nooffer", warning: "0badf00d-10"))]
        let fourth = await r12Start(world)
        let fallback = await waitUntil(5) {
            if case .waitingUser(let text, _)? = world.flow.card { return text == HandsConnectFlow.warningChangedCardText }
            return false
        }
        check(fourth && fallback, "W183 R12（主導 3）讀不到全文（沒有那一份）：照舊是「看完自己勾，再按繼續」的卡",
              "card=\(String(describing: world.flow.card))")
        world.flow.cancel(reason: "test_done")
        // 外來的字只顯示：控制字元拿掉、只收 user 開頭的那一份、連結只收 https 網域。
        let cleaned = HandsConsentOffer(wire: ["text": "Line one\u{0007}\nLine two", "links": [["text": "Learn", "origin": "https://help.openai.com"]],
                                              "print": "user\nLine one"])
        let badPrint = HandsConsentOffer(wire: ["text": "x", "links": [], "print": "en-2026-09-29\nx"])
        let badLink = HandsConsentOffer(wire: ["text": "x", "links": [["text": "Learn", "origin": "javascript:alert(1)"]], "print": "user\nx"])
        check(cleaned?.text == "Line one\nLine two" && badPrint == nil && badLink == nil,
              "W183 R12（主導 3）外來的說明只當文字顯示：控制字元拿掉、只收 TATWO 那一份的樣子、連結只收 https")
        try? FileManager.default.removeItem(at: bookURL)
    }

    @MainActor static func r12PendingCreates(_ check: Checker, _ base: URL) async throws {
        let bookURL = base.appendingPathComponent("r12-pending-creates.json")
        try? FileManager.default.removeItem(at: bookURL)
        func book() -> HandsConnectDigestBook { HandsConnectDigestBook(url: bookURL, maxEntries: 16, lifetime: 7 * 24 * 3600) }
        // 第一次：按了建立、ChatGPT 沒開出配對頁（逾時）＝記下「按過建立」（檔裡；只有雜湊）。
        let first = try World(base, "r12-pending-a", pendingCreateBook: book())
        let started = await r12Start(first)
        let timedOut = await waitUntil(12) { first.flow.phase == .needsManual }
        let raw = (try? String(contentsOf: bookURL, encoding: .utf8)) ?? ""
        check(started && timedOut && first.pod.calls.contains("create") && book().entries.count == 1
              && !raw.contains(HandsConnectAcceptance.identity) && !raw.contains(HandsConnectAcceptance.publicHost),
              "W183 R12（主導 5）按過建立、還沒出現在清單：記進這台的檔（只有雜湊，沒有帳號、網址）",
              "calls=\(first.pod.calls) entries=\(book().entries.count)")
        first.flow.cancel(reason: "test_done")
        // 重開 App（新的流程）：清單裡還是找不到＝停下來講清楚；保留 pending，不能靠重開 App 繞過。
        let second = try World(base, "r12-pending-b", pendingCreateBook: book())
        let restarted = await r12Start(second)
        let stopped = await waitUntil(8) { second.flow.phase == .needsManual }
        check(restarted && stopped && !second.pod.calls.contains(where: { $0.hasPrefix("create") })
              && second.flow.problem?.contains("找不到不等於不存在") == true && book().entries.count == 1 && second.flow.retryWillRebuild,
              "W183 R12（主導 5）重開 App 之後再按［連線］：記得上次按過建立、清單裡找不到＝不再建第二個（講清楚到 ChatGPT 看一下）",
              "calls=\(second.pod.calls) problem=\(String(describing: second.flow.problem))")
        // 使用者看過、真的沒有：再連一次＝重建。
        second.flow.retry()
        let rebuilt = await waitUntil(8) { second.pod.calls.contains(where: { $0.hasPrefix("create") }) }
        check(rebuilt, "W183 R12（主導 5）本輪明確確認不存在後重試才重建（不會卡死，也不清掉持久紀錄）", "\(second.pod.calls)")
        second.flow.cancel(reason: "test_done")
        // 清單裡找得到（同一個網址、OAuth、認得編號）＝沿用：重新連線，不建新的。
        let third = try World(base, "r12-pending-c", pendingCreateBook: book())
        third.pod.scanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true,
                                                  matches: [HandsConnectorScan.Match(id: "conn_r12", name: "TATWO（Primary One）", auth: "oauth")])
        let reused = await r12Start(third)
        let reconnected = await waitUntil(8) { third.pod.calls.contains("reconnect:conn_r12") }
        check(reused && reconnected && !third.pod.calls.contains(where: { $0.hasPrefix("create") }),
              "W183 R12（主導 5）ChatGPT 裡已經有同一個 TATWO 連接器（同網址、OAuth）：沿用它繼續授權，不建第二個", "\(third.pod.calls)")
        third.flow.cancel(reason: "test_done")
        try? FileManager.default.removeItem(at: bookURL)
    }

    /// 真正的 HandsConnectFlow＋隔離的持久 book；Pod 仍是假回覆，不宣稱是真實 ChatGPT／CEF 驗收。
    @MainActor static func r12MissingNameRecovery(_ check: Checker, _ base: URL) async throws {
        let name = "TATWO（Primary One）"
        let url = "https://\(publicHost)/mcp"
        @MainActor func seed(_ book: HandsConnectDigestBook, identity: String, url: String) {
            let key = identity + "|" + url
            book.insert(HandsPendingCreates.digest(key))
        }
        @MainActor func fixture(_ label: String, step: String = "by_name",
                                loginGeneration: (@MainActor () -> Int)? = nil) throws -> (World, HandsConnectDigestBook) {
            let book = HandsConnectDigestBook(url: base.appendingPathComponent("r12-recovery-\(label).json"),
                                             maxEntries: 16, lifetime: 7 * 24 * 3600)
            seed(book, identity: identity, url: url)
            let world = try World(base, "r12-recovery-\(label)", loginGeneration: loginGeneration, pendingCreateBook: book)
            world.pod.byNameResult = .notFound(step)
            return (world, book)
        }
        @MainActor func stopped(_ world: World) async -> Bool {
            guard await r12Start(world) else { return false }
            return await waitUntil(5) { world.flow.phase == .needsManual }
        }

        // Pending Create survives restart; only open/by_name failures offer a scoped retry.
        for step in ["open", "by_name"] {
            let (world, book) = try fixture(step, step: step)
            let missing = await stopped(world)
            let original = Set(book.entries.map(\.digest))
            check(missing && world.flow.retryWillRebuild && world.pod.byNameCalls == [name]
                  && world.pod.createdNames.isEmpty && original.count == 1
                  && world.flow.problem?.contains("找不到不等於不存在") == true,
                  "W183 recovery \(step)：只提示確認不存在；保留 pending，不自動建立")

            // 另開流程、重新從檔案載入：先前看到提示不代表已授權，不能自動建立。
            let freshBook = HandsConnectDigestBook(url: book.url, maxEntries: 16, lifetime: 7 * 24 * 3600)
            let fresh = try World(base, "r12-recovery-\(step)-fresh", pendingCreateBook: freshBook)
            let initiallyUnapproved = !fresh.flow.retryWillRebuild
            let freshStopped = await stopped(fresh)
            check(initiallyUnapproved && freshStopped && fresh.pod.createdNames.isEmpty && fresh.pod.byNameCalls == [name]
                  && Set(freshBook.entries.map(\.digest)) == original,
                  "W183 recovery \(step)：fresh flow 重讀持久名稱仍先 byName，不沿用上輪重建授權")
            fresh.flow.cancel(reason: "test_done")

            world.flow.retry()   // 使用者在 needsManual 明確確認不存在
            let rebuilt = await waitUntil(5) { world.pod.createdNames == [name] && world.flow.progressStep == 2 }
            check(rebuilt && world.pod.byNameCalls == [name] && !world.flow.retryWillRebuild
                  && Set(book.entries.map(\.digest)) == original,
                  "W183 recovery \(step)：同 flow 明確 retry 只建立一次、仍沿用名稱，不再陷入 byName 迴圈")
            let timedOut = await waitUntil(8) { world.flow.phase == .needsManual }
            world.flow.retry()
            let checkedAgain = await waitUntil(5) { world.pod.byNameCalls.count == 2 && world.flow.phase == .needsManual }
            check(timedOut && checkedAgain && world.pod.createdNames == [name],
                  "W183 recovery \(step)：建立已送出後授權消耗；再次重試先查既有外掛，不再自動建立")
            world.flow.cancel(reason: "test_done")
        }

        // 核驗／Connect 失敗表示流程已找到入口，不能被誤當「不存在」；未知 step 也不放行。
        for step in ["verify", "connect", "id", "unsupported"] {
            let (world, book) = try fixture(step, step: step)
            let missing = await stopped(world)
            let unapproved = !world.flow.retryWillRebuild
            world.flow.retry()
            let retried = await waitUntil(5) { world.pod.byNameCalls.count == 2 && world.flow.phase == .needsManual }
            check(missing && unapproved && retried && !world.flow.retryWillRebuild
                  && world.pod.createdNames.isEmpty && book.entries.count == 1,
                  "W183 recovery \(step)：不授權重建、不清名稱；retry 仍只重連")
            world.flow.cancel(reason: "test_done")
        }

        let (reuse, _) = try fixture("reuse")
        let reuseMissing = await stopped(reuse)
        reuse.pod.scanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true,
            matches: [HandsConnectorScan.Match(id: "recovery-existing", name: name, auth: "oauth")])
        reuse.flow.retry()
        let reused = await waitUntil(5) { reuse.pod.calls.contains("reconnect:recovery-existing") }
        check(reuseMissing && reused && reuse.pod.createdNames.isEmpty && reuse.pod.byNameCalls == [name]
              && !reuse.flow.retryWillRebuild,
              "W183 recovery：明確重建後仍先 scan；同 URL 有 OAuth 外掛必須優先 reuse")
        reuse.flow.cancel(reason: "test_done")

        for known in [false, true] {
            let (world, _) = try fixture(known ? "ambiguous-list" : "unknown-list")
            let missing = await stopped(world)
            let match = HandsConnectorScan.Match(id: "recovery-existing", name: name, auth: "oauth")
            world.pod.scanResult = HandsConnectorScan(loggedIn: true, listKnown: known, devMode: true,
                                                      matches: known ? [match, match] : [])
            world.flow.retry()
            let refused = await waitUntil(5) { world.flow.phase == .needsManual }
            let expired = !world.flow.retryWillRebuild
            world.pod.scanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true, matches: [])
            world.flow.retry()
            let rechecked = await waitUntil(5) { world.pod.byNameCalls.count == 2 && world.flow.phase == .needsManual }
            check(missing && refused && expired && rechecked && world.pod.createdNames.isEmpty,
                  "W183 recovery \(known ? "ambiguous" : "listUnknown")：不能建立；這次授權作廢，恢復空清單也不自動建立")
            world.flow.cancel(reason: "test_done")
        }

        // 同一輪建立尚未送出：一般警語（ack=nil）→ 新同意卡 → 核准，同一次選擇必須一直帶著。
        let (consent, _) = try fixture("consent")
        let consentMissing = await stopped(consent)
        let ack = HandsConnectorAck(form: "frecovery123", warning: "0badf00d-10", consent: r12Offer)
        consent.pod.createQueue = [.needsUser(HandsConnectFlow.riskAckReason, nil),
                                   .needsUser(HandsConnectFlow.warningChangedReason, ack)]
        consent.flow.retry()
        let waiting = await waitUntil(5) { consent.flow.phase == .waitingUser }
        consent.flow.continueAfterUser()
        let cardShown = await waitUntil(5) { if case .consent? = consent.flow.card { return true }; return false }
        consent.flow.approveConsent()
        let continued = await waitUntil(5) { consent.pod.createdNames.count == 3 && consent.flow.progressStep == 2 }
        check(consentMissing && waiting && cardShown && continued && consent.pod.byNameCalls == [name]
              && consent.pod.acks.last.flatMap({ $0 })?.approved == r12Offer.print,
              "W183 recovery：ack=nil 的警語續接與同意卡不丟掉本輪重建選擇、不回 byName；只有最後一次才 pressed")
        consent.flow.cancel(reason: "test_done")

        // 相鄰反例：這次是在重連既有的 …2，不是在重建；警語／同意卡續接絕不能改呼叫 create。
        let (named, _) = try fixture("named-consent")
        let warning = HandsConnectorAck(form: "fnamed123", warning: "0badf00d-10")
        named.pod.byNameQueue = [.needsUser(HandsConnectFlow.riskAckReason, warning),
                                 .needsUser(HandsConnectFlow.warningChangedReason, ack), .pressed]
        named.pod.createResult = .notFound("unexpected_create")   // 舊路徑在第一次 continue 就會命中這個反例
        let namedStarted = await r12Start(named)
        let namedWarning = await waitUntil(5) { named.flow.phase == .waitingUser }
        named.flow.continueAfterUser()
        let namedConsent = await waitUntil(5) { if case .consent? = named.flow.card { return true }; return false }
        named.flow.approveConsent()
        let namedResumed = await waitUntil(5) { named.pod.byNameCalls.count == 3 && named.flow.progressStep == 2 }
        check(namedStarted && namedWarning && namedConsent && namedResumed && named.pod.createdNames.isEmpty
              && named.pod.byNameCalls == [name, name, name]
              && named.pod.byNameAcks == [nil, warning, ack.approving(r12Offer.print)] && !named.flow.retryWillRebuild,
              "W183 recovery named consent：原 byName 重連遇警語／同意卡仍只重連；ack 非 nil 不得改成 create",
              "byName=\(named.pod.byNameCalls.count) creates=\(named.pod.createdNames.count)")
        named.flow.cancel(reason: "test_done")

        let (cancelled, _) = try fixture("cancel")
        let cancelMissing = await stopped(cancelled)
        cancelled.flow.cancel(reason: "user_cancelled")
        let cleared = !cancelled.flow.retryWillRebuild
        let cancelledAgain = await stopped(cancelled)
        check(cancelMissing && cleared && cancelledAgain && cancelled.pod.byNameCalls.count == 2 && cancelled.pod.createdNames.isEmpty,
              "W183 recovery：取消清掉當輪提示／授權，重新連線仍先 byName")
        cancelled.flow.cancel(reason: "test_done")

        // 換帳號／網址時，另一組也有持久名稱：否則建立新的合法外掛會掩蓋誤帶舊授權。
        for changeAccount in [true, false] {
            let (world, book) = try fixture(changeAccount ? "account" : "url")
            let missing = await stopped(world)
            if changeAccount {
                let other = identity + "-other"
                seed(book, identity: other, url: url)
                world.pod.identityValue = other
            } else {
                let otherHost = "recovery-other.trycloudflare.com"
                seed(book, identity: identity, url: "https://\(otherHost)/mcp")
                _ = try world.service.updateSettings { $0.publicHost = otherHost }
            }
            world.flow.retry()
            let reconfirmed = await waitUntil(5) { isConfirm(world.flow.card) }
            let cleared = !world.flow.retryWillRebuild
            world.flow.connect()
            let rechecked = await waitUntil(5) { world.pod.byNameCalls.count == 2 && world.flow.phase == .needsManual }
            check(missing && reconfirmed && cleared && rechecked && world.pod.createdNames.isEmpty,
                  "W183 recovery \(changeAccount ? "account" : "url")：換目標必須重新確認，舊重建授權不能跨帳號／網址")
            world.flow.cancel(reason: "test_done")
        }

        var generation = 1
        let (changedLogin, _) = try fixture("login-generation", loginGeneration: { generation })
        let loginMissing = await stopped(changedLogin)
        generation += 1   // 同帳號登出又登入，也不能沿用
        let expired = !changedLogin.flow.retryWillRebuild
        changedLogin.flow.retry()
        let loginChecked = await waitUntil(5) { changedLogin.pod.byNameCalls.count == 2 && changedLogin.flow.phase == .needsManual }
        check(loginMissing && expired && loginChecked && changedLogin.pod.createdNames.isEmpty,
              "W183 recovery：同帳號登入世代改變，舊重建提示不得轉成授權")
        changedLogin.flow.cancel(reason: "test_done")

        // 已經在重建的同意卡上時也要作廢；不能只清 grant，卻讓舊 ack 直接跳過 byName 建立。
        for event in ["generation", "cancel", "pod_lost"] {
            var currentGeneration = 1
            let (world, _) = try fixture("consent-\(event)", loginGeneration: { currentGeneration })
            let missing = await stopped(world)
            world.pod.createQueue = [.needsUser(HandsConnectFlow.warningChangedReason, ack)]
            world.flow.retry()
            let waiting = await waitUntil(5) { if case .consent? = world.flow.card { return true }; return false }
            switch event {
            case "generation":
                currentGeneration += 1
                world.flow.approveConsent()
            case "cancel":
                world.flow.cancel(reason: "user_cancelled")
                world.flow.offer()
            default:
                world.pod.onLost?("pod_logged_out")
            }
            let reconfirmed = await waitUntil(5) { isConfirm(world.flow.card) }
            world.flow.connect()
            let rechecked = await waitUntil(5) { world.pod.byNameCalls.count == 2 && world.flow.phase == .needsManual }
            check(missing && waiting && reconfirmed && rechecked && world.pod.createdNames == [name],
                  "W183 recovery consent \(event)：舊重建選擇與 ack 不得跨失效事件；重新連線仍 byName")
            world.flow.cancel(reason: "test_done")
        }
    }

    @MainActor static func r12HiddenWait(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r12-hidden")
        world.presenter.webShown = false   // 收起私訊框（連線的網頁不在畫面上）
        let started = await r12Start(world)
        let pressed = await waitUntil(5) { world.pod.calls.contains("create") }
        try? await Task.sleep(nanoseconds: 4_500_000_000)   // 比等配對頁的上限（3 秒）久
        let kept: Bool = { if case .working? = world.flow.card { return world.flow.phase == .creatingConnector }; return false }()
        world.presenter.webShown = true    // 打開：照常倒數
        let timedOut = await waitUntil(8) { world.flow.phase == .needsManual }
        check(started && pressed && kept && timedOut,
              "W183 R12（主導 1）收起私訊框：等 ChatGPT 開配對頁的時間不倒數、流程不取消；打開之後照常倒數",
              "phase=\(world.flow.phase) kept=\(kept)")
        world.flow.cancel(reason: "test_done")
    }

    // MARK: 拿掉等級選擇（主導 4）：所有設備一律 L2，R11 的安全規則照守

    @MainActor static func r12Levels(_ check: Checker) {
        typealias R = HandsBuildConfig
        func entry(_ id: String, level: Int, revision: Int) -> HandsBuildDeviceEntry {
            HandsBuildDeviceEntry(deviceID: id, name: "Primary One", isPrimary: id == hostID, selected: true,
                                  subdomain: id == hostID ? "os-for-chatgpt" : "os-for-chatgpt-\(id.prefix(4))", level: level, projectIDs: [],
                                  deviceRevision: revision, revocationGeneration: 0)
        }
        let third = "33333333-3333-4333-8333-333333333333"
        // .032 實測的樣子：中央設定裡主機是 L0（device_revision 7）；R11 的一份（有 level_default、還沒照過 level_unified）。
        let r11 = R(primaryID: hostID, authorityEpoch: 1, configRevision: 10, enabled: true, accountID: nil, zoneID: nil, domain: nil,
                    devices: [entry(hostID, level: 0, revision: 7), entry(secondaryID, level: 1, revision: 2), entry(third, level: 2, revision: 1)],
                    migratedFromLegacy: nil, levelDefault: 2)
        let empty = R.empty(primaryID: hostID, epoch: 1)
        let unified = R.unifiedLevels(r11)
        check(empty.levelUnified == true && R.unifiedLevels(empty) == nil
              && unified?.levelDefaultPending == [hostID, secondaryID] && unified?.entry(hostID)?.level == 0 && unified?.entry(secondaryID)?.level == 1
              && unified?.entry(third)?.level == 2 && unified?.entry(hostID)?.deviceRevision == 7 && unified?.configRevision == 11
              && unified?.levelUnified == true && unified.flatMap(R.unifiedLevels) == nil,
              "W183 R12 所有設備一律 L2：還沒照過的一份照一次——低於 L2 的每一台（L0 也算）記成待升、不直接升（現有連線不因此放大）；已經 L2 的不列；照過就不再照；新的一份一開始就照過",
              "\(String(describing: unified?.levelDefaultPending)) rev=\(String(describing: unified?.configRevision))")
        let at = Date()
        var guarded = HandsBuildDeviceReport(deviceID: hostID)
        guarded.levelGuard = true
        guarded.receivedAt = at
        guarded.appliedConfigRevision = 11
        var oldIdle = guarded   // 舊版主機、沒有連線
        oldIdle.levelGuard = false
        oldIdle.grants = 0
        var behind = guarded   // 還沒套用到照過的這一版
        behind.appliedConfigRevision = 10
        let raised = unified.flatMap { R.raisingPending($0, device: hostID, report: guarded, now: at) }
        check(raised?.entry(hostID)?.level == 2 && raised?.entry(hostID)?.deviceRevision == 8 && raised?.levelDefaultPending == [secondaryID]
              && raised?.configRevision == 12
              && unified.flatMap { R.raisingPending($0, device: hostID, report: oldIdle, now: at) } == nil
              && unified.flatMap { R.raisingPending($0, device: hostID, report: behind, now: at) } == nil,
              "W183 R12 待升的 L0 那台：會先封頂的主機、回報新、已經套用到這一版＝升到 L2（那台的版本 +1）；舊版主機（沒有連線也一樣）、還沒套用到這一版＝不升",
              "raised=\(String(describing: raised?.entry(hostID)?.level))")
        // 畫面：面板那一行＝確認卡那一行（連上後能做的）；狀態寫能力；主卡片的字沒有 L0／L1／L2。
        check(HandsBuildCopy.capabilities == "連上後：看全部專案・可用 Codex・記憶只讀＋收件匣"
              && HandsConnectAbility.line(level: HandsBuildConfig.defaultLevel) == HandsBuildCopy.capabilities
              && HandsBuildCopy.connected(2) == "已連線・Codex、記憶",
              "W183 R12 拿掉等級選擇：ChatGPT Dev 面板＝「連上後：看全部專案・可用 Codex・記憶只讀＋收件匣」（跟確認卡同一句）；狀態寫「已連線・Codex、記憶」；主卡片的字沒有 L0／L1／L2")
        W224Acceptance.compactBuild { value, label in check(value, label, "native current card") }
    }
}
#endif
