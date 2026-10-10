#if DEBUG
import AppKit
import Foundation

// W183 R7a 自測（只在完整隔離的 staging；不開通道、不啟動關口、不上網、不碰真的鑰匙圈）。
// W183 R10 改寫（使用者 09-29「這邊要勾選也太怪 就要給他用了還要多一個勾選」）：卡上選範圍拿掉——守的東西換成新規矩：
// - w183connect（HandsConnectAcceptance.scopeCard）：範圍＝中央設定的等級＋這台全部專案（新專案自動包含，本機的 allowed_project_ids 不再當閘門）；
//   卡片只顯示（offer 不給卡上選、flow 沒有選擇）；主機一律不收卡上選的範圍（本機 begin、設備簽章的 begin_connect 帶了 level／project_ids
//   ＝connect_scope_invalid、設定不動、不開窗口）；交易實盤類專案標只能看、L1／L2 的寫入與執行工具被拒（主機自己判斷）；
//   已連線的 grant 等級照舊用自己的快照；AI 工具（外部 AI、os.sock 沒簽章）改不了等級與專案。
// - w183ui（HandsUIAcceptance.r7aChecks）：步驟訊息與畫面的按鈕名稱一致、不露內部代號；公開 DNS 的外部確認（純解析）；
//   舊 DNS 紀錄確認不了就不刪、之後自己再試（不用按）；助理（hands_setup_step）改不了等級與專案。
// W183 R7a 審查留下來、照樣守的反例：取消比 begin 先到（墓碑）、同 ID 異內容、暫時不見的專案的工作區不會因為按［連線］被鎖、70 個專案不截斷、
//   真的走 os.sock 的處理路徑（OSAgentBridge、引擎身分）送 remote_hands_action：沒簽章、沒配對的金鑰、別的方法的簽章、重放舊序號一律拒
//   （對照組：有效簽章、不帶範圍的才開得了窗口）；外部 AI 的每一個真實工具帶等級、專案參數都被拒。

extension HandsConnectAcceptance {
    /// 主機上的專案：兩個正常的、入口本身、入口的 chatgpt/ 裡面、資料夾不見的（後三個都不在「這台全部專案」裡），
    /// 加兩個交易實盤類（W183 R10 底線 B：名字含「實盤」、資料夾名含 hermes）。
    struct ScopeFixture {
        let alpha: UUID, beta: UUID, entry: UUID, chatgpt: UUID, missing: UUID, trading: UUID, hermes: UUID
        let records: [(UUID, String, String)]
        let root: String
        let entryPath: String
        let homePath: String

        func configure(_ service: HandsService) {
            let records = records
            service.projectsOverride = { records }
            service.runtime.entryRoot = entryPath
            service.runtime.home = homePath
            // lead-verify 的 staging：TATWO2_LIVE_ROOT＝<staging>/live，App 資料夾（沙盒一律拒、專案不能在裡面）就是 staging 根——
            // 自測的專案資料夾也在那底下，換成這個世界自己的位置（正式照舊：~/Library/Application Support/tatwo2）。
            service.runtime.appSupport = root + "/app-support"
        }

        /// 「這台全部專案」（能當專案的）＝這幾個，照名字排。
        var visible: [UUID] { [alpha, beta, hermes, trading] }
    }

    static func scopeFixture(_ base: URL, _ name: String) throws -> ScopeFixture {
        let fm = FileManager.default
        let root = base.appendingPathComponent(name + "-projects", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let entry = root.appendingPathComponent("entry", isDirectory: true)
        let inside = entry.appendingPathComponent("chatgpt/workspaces/w1", isDirectory: true)
        let alpha = root.appendingPathComponent("work/alpha", isDirectory: true)
        let beta = root.appendingPathComponent("work/beta", isDirectory: true)
        let desk = root.appendingPathComponent("work/live-desk", isDirectory: true)
        let bot = root.appendingPathComponent("work/Hermes-bot", isDirectory: true)
        for dir in [home, entry, inside, alpha, beta, desk, bot] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func real(_ url: URL) -> String { HandsPath.realpath(url.path) ?? url.path }
        let ids = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
        let records: [(UUID, String, String)] = [
            (ids.0, "Alpha", real(alpha)), (ids.1, "Beta", real(beta)), (ids.2, "Entry itself", real(entry)),
            (ids.3, "Inside chatgpt", real(inside)), (ids.4, "Gone", real(root) + "/work/gone"),
            (ids.5, "BTC 實盤", real(desk)), (ids.6, "Desk tools", real(bot)),
        ]
        return ScopeFixture(alpha: ids.0, beta: ids.1, entry: ids.2, chatgpt: ids.3, missing: ids.4, trading: ids.5, hermes: ids.6,
                            records: records, root: real(root), entryPath: real(entry), homePath: real(home))
    }

    @MainActor static func scopeCard(_ check: Checker, _ base: URL) async throws {
        try await scopeAllVisible(check, base)
        try scopeHostRules(check, base)
        try await scopeRemote(check, base)
        scopeWire(check)
        try scopeCentral(check, base)
        try scopeOldGrant(check, base)   // W183 R10 第二輪（GPT-6 8）：恢復「中央放大、舊 grant 不跟著變大」的實際工具授權測試
        // W183 R7a 審查留下來的
        try scopeConcurrency(check, base)
        try scopeGoneKept(check, base)
        try scopeLongList(check, base)
        try await scopeBridge(check, base)
    }

    /// 只有主機的世界（HandsService＋HandsConnectHost；設定開著、這台是主機、L1、本機的 allowed_project_ids 是空的——就像實機的 mini）。
    static func scopeHost(_ base: URL, _ name: String, _ fx: ScopeFixture) throws -> (HandsService, HandsConnectHost) {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = HandsService(paths: HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands")))
        service.deviceIDOverride = hostID
        fx.configure(service)
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = hostID; $0.publicHost = publicHost; $0.level = 1 }
        let host = HandsConnectHost(service: service, epoch: { "e1" }, localDeviceID: { hostID }, hostName: { "Primary One" }, serviceRunning: { true })
        host.attach()
        return (service, host)
    }

    /// 擁有者照卡片按［連線］的請求（不帶範圍：W183 R10 的樣子）。
    static func scopeRequest(_ host: HandsConnectHost, id: String = UUID().uuidString, choice: HandsScopeChoice? = nil) throws -> HandsConnectRequest {
        let offer = try host.offer()
        return HandsConnectRequest(attemptID: id, setupEpoch: offer.setupEpoch, ownerDeviceID: hostID, scopeDigest: offer.digest, mcpURL: offer.mcpURL,
                                   choice: choice)
    }

    static func settingsText(_ service: HandsService) -> String {
        let settings = service.settings.load()
        return "L\(settings.level):" + settings.allowedProjectIDs.sorted().joined(separator: ",")
    }

    // MARK: 全部可見：卡片只顯示、快照＝全部專案、新專案自動包含、交易類只能看

    @MainActor static func scopeAllVisible(_ check: Checker, _ base: URL) async throws {
        let fx = try scopeFixture(base, "scope-all")
        let world = try World(base, "scope-all", configure: fx.configure)
        let service = world.service
        // 實機的樣子：本機的 allowed_project_ids 是空的（R8 之後沒有地方核准）。W183 R10：它不再當閘門。L2（才驗得到寫入與工作區被拒）。
        _ = try service.updateSettings { $0.level = 2; $0.allowedProjectIDs = [] }
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        guard case .confirm(let offer, _)? = world.flow.card else { return check(false, "W183 R10 ［連線］卡出現", "\(String(describing: world.flow.card))") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: offer.wire), as: UTF8.self)
        let names = offer.scope.projects.map(\.name)
        check(offer.scope.allProjects && !offer.supportsChoice && offer.projectChoices.isEmpty && world.flow.choice == nil
              && Set(offer.scope.projects.map(\.id)) == Set(fx.visible.map(\.uuidString)) && offer.scope.level == 2
              && Set(offer.scope.readOnlyProjectIDs) == [fx.trading.uuidString, fx.hermes.uuidString]
              && json.contains("\"all_projects\":true") && !json.contains("project_choices") && !json.contains("unchecked_in_build")
              && !json.contains(fx.root) && !json.contains(fx.entryPath),
              "W183 R10 卡片：範圍＝這台全部專案（入口本身、入口的 chatgpt/、資料夾不見的不在裡面）＋設定的等級；本機 allowed_project_ids 是空的也一樣；卡上不選（沒有 project_choices、flow 沒有選擇）；交易類另外列出（只能看）；不帶完整路徑",
              "\(names) readOnly=\(offer.scope.readOnlyProjectIDs.count) \(json.prefix(300))")

        let chatgpt = FakeChatGPT(service: service)
        world.chatgptStarts(chatgpt)
        world.flow.connect()
        let paired = await waitUntil(8) { world.pairing?.pairingCode != nil }
        let tx = service.auth.attemptTransaction(world.attemptID ?? "")
        check(paired && tx?.scope.allProjects == true && tx?.scope.level == 2 && service.settings.load().allowedProjectIDs.isEmpty,
              "W183 R10 按［連線］：範圍快照＝全部專案（allProjects）＋L2；本機設定一個字都不寫", "\(String(describing: tx?.scope))")
        let access = try chatgpt.token(try chatgpt.submit(tx?.pairingCode ?? ""))
        try chatgpt.tools(access)
        let connected = await waitUntil(5) { world.flow.phase == .connected }
        let grant = service.auth.grant(forAccess: access)
        let record = grant.flatMap { service.auth.grantRecord($0.grantID) }
        check(connected && grant?.allProjects == true && record?.allProjects == true && record?.level == 2,
              "W183 R10 這次連上的 grant：核准的是「這台全部專案」（新專案自動包含）＋L2")

        // 新專案（連上之後才在 Coder 加的）自動包含；交易類標 read_only。
        let fresh = URL(fileURLWithPath: fx.root).appendingPathComponent("work/fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let freshID = UUID()
        let more = fx.records + [(freshID, "Fresh", HandsPath.realpath(fresh.path) ?? fresh.path)]
        service.projectsOverride = { more }
        func call(_ name: String, _ arguments: [String: Any]) -> (text: String, isError: Bool) {
            do {
                let result = try service.handle(method: "hands_call", params: ["access_token": access, "name": name, "arguments": arguments])
                let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                return (text, (result["isError"] as? Bool) == true)
            } catch { return ("\(error)", true) }
        }
        let listed = call("list_projects", [:])
        let rows = ((try? JSONSerialization.jsonObject(with: Data(listed.text.utf8))) as? [String: Any])?["projects"] as? [[String: Any]] ?? []
        let ids = Set(rows.compactMap { $0["id"] as? String })
        let readOnly = Set(rows.filter { $0["read_only"] as? Bool == true }.compactMap { $0["id"] as? String })
        check(!listed.isError && ids.contains(freshID.uuidString) && ids.isSuperset(of: fx.visible.map(\.uuidString))
              && !ids.contains(fx.entry.uuidString) && !ids.contains(fx.chatgpt.uuidString)
              && readOnly == [fx.trading.uuidString, fx.hermes.uuidString],
              "W183 R10 新專案自動包含：連上之後才加的專案 list_projects 就看得到；交易實盤類（名字含實盤、資料夾含 hermes）標 read_only",
              "\(listed.text.prefix(400))")
        // 底線 B：交易類——開工作區（L2）被拒；讀（L0）照樣可以。
        let open = call("open_workspace", ["project_id": fx.trading.uuidString, "title": "try"])
        let openHermes = call("open_workspace", ["project_id": fx.hermes.uuidString, "title": "try"])
        // L0 的讀會跑 git（主機不准在主執行緒跑 git）：照正式的處理線放到背景叫（關口的呼叫本來就不在主執行緒）。
        let tradingID = fx.trading.uuidString, readTool = "list_dir"
        let read: (text: String, isError: Bool) = await Task.detached {
            do {
                let result = try service.handle(method: "hands_call", params: ["access_token": access, "name": readTool,
                                                                               "arguments": ["project_id": tradingID]])
                let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                return (text, (result["isError"] as? Bool) == true)
            } catch { return ("\(error)", true) }
        }.value
        check(open.isError && open.text.contains("project_read_only") && openHermes.isError && openHermes.text.contains("project_read_only")
              && !read.text.contains("project_read_only"),
              "W183 R10 底線 B：交易實盤類專案（名字或資料夾名）開工作區一律被拒（主機自己查 Coder 的名字與資料夾）；讀的工具不擋（只能看）",
              "open=\(open.text.prefix(160)) hermes=\(openHermes.text.prefix(120)) read=\(read.text.prefix(120))")

        // AI 工具改不了等級與專案：外部 AI 的工具清單裡沒有這種工具；每一個真實工具帶等級、專案參數呼叫一次，都被拒、設定照舊。
        let catalog = HandsTools.catalog(level: HandsSettings.maxLevel)
        let toolNames = catalog.map(\.name)
        var accepted: [String] = []
        for tool in catalog where !call(tool.name, ["level": 0, "project_ids": [fx.beta.uuidString], "allowed_project_ids": [fx.beta.uuidString]]).isError {
            accepted.append(tool.name)
        }
        let after = service.settings.load()
        check(!catalog.isEmpty && accepted.isEmpty && after.level == 2 && after.allowedProjectIDs.isEmpty
              && !toolNames.contains(where: { $0.contains("level") || $0.contains("setting") || $0.contains("scope") || $0.hasPrefix("set_") }),
              "W183 R10 反例：外部 AI（ChatGPT）沒有、也叫不動改等級或專案的工具（\(catalog.count) 個真實工具帶等級、專案參數都被拒）；設定照舊",
              "accepted=\(accepted) \(toolNames)")
        world.flow.dismiss()
    }

    // MARK: 主機的規則：卡上選的範圍一律不收；不帶範圍的才開窗口；外部 AI 在授權請求裡塞範圍＝不收

    @MainActor static func scopeHostRules(_ check: Checker, _ base: URL) throws {
        let fx = try scopeFixture(base, "scope-rules")
        let (service, host) = try scopeHost(base, "scope-rules", fx)
        let changed = HandsLocked(0)
        host.onSettingsChanged = { changed.update { $0 += 1 } }
        func begin(_ request: HandsConnectRequest) -> (HandsConnectStatus?, HandsConnectRefusal?) {
            do { return (try host.begin(request, sender: hostID), nil) }
            catch let refusal as HandsConnectRefusal { return (nil, refusal) }
            catch { return (nil, .invalid) }
        }
        let choices = [HandsScopeChoice(level: 2, projectIDs: [fx.alpha.uuidString]), HandsScopeChoice(level: 1, projectIDs: []),
                       HandsScopeChoice(level: 2, projectIDs: [fx.entry.uuidString]), HandsScopeChoice(level: 3, projectIDs: [])]
        let refusals = try choices.map { begin(try scopeRequest(host, choice: $0)).1 }
        let before = service.settings.load()
        check(refusals.allSatisfy { $0 == .scopeInvalid } && before.level == 1 && before.allowedProjectIDs.isEmpty
              && service.auth.windowExpiresAt == nil && changed.get() == 0 && host.currentAttemptID == nil,
              "W183 R10 主機一律不收卡上選的範圍（等級、專案，連跟現在一樣的也不收）：connect_scope_invalid、設定不動、不開窗口（範圍只照 ChatGPT build 的中央設定）",
              "\(refusals)")
        let id = UUID().uuidString
        let (opened, refused) = begin(try scopeRequest(host, id: id))
        check(opened?.state == .open && refused == nil && settingsText(service) == "L1:" && changed.get() == 0,
              "W183 R10 不帶範圍的 begin（新版擁有者）：核對世代與 digest 之後開窗口，設定一個字都不寫", "\(String(describing: refused))")
        // 外部 AI（關口轉進來的 authorize_begin）多塞等級、專案：整個請求不收；正常的那一筆照舊用按［連線］時的快照。
        let chatgpt = FakeChatGPT(service: service)
        try chatgpt.register()
        var extraRefused = false
        do {
            _ = try service.handle(method: "hands_auth", params: [
                "op": "authorize_begin", "client_id": chatgpt.clientID, "redirect_uri": chatgpt.redirect, "code_challenge": chatgpt.challenge,
                "code_challenge_method": "S256", "state": chatgpt.state, "scope": "tatwo.hands", "level": 0, "project_ids": [fx.alpha.uuidString]])
        } catch { extraRefused = true }
        let noTransaction = service.auth.attemptTransaction(id) == nil
        let (began, _) = chatgpt.begin()
        let tx = service.auth.attemptTransaction(id)
        check(extraRefused && noTransaction && began != nil && tx?.scope.level == 1 && tx?.scope.allProjects == true && settingsText(service) == "L1:",
              "W183 R10 反例：外部 AI 在授權請求裡塞等級、專案：整個請求不收；交易照舊用快照（L1＋全部專案），設定不動", "\(String(describing: tx?.scope))")
        _ = try host.cancel(attemptID: id, sender: hostID, reason: "test_done")
    }

    // MARK: 副設備：begin_connect 不帶範圍（真的設備簽章）；帶了＝不收

    @MainActor static func scopeRemote(_ check: Checker, _ base: URL) async throws {
        let fx = try scopeFixture(base, "scope-remote")
        let root = base.appendingPathComponent("scope-remote-keys", isDirectory: true)
        guard let harness = try remoteHarness(root) else { return check(false, "W183 R10 副設備：產生測試金鑰") }
        let secondary = harness.secondary
        let world = try World(base, "scope-remote", owner: secondaryID, link: { _ in HandsConnectRemoteLink(dispatch: secondary) },
                              configure: fx.configure)
        let service = world.service
        harness.host.set(HandsRemote.Host(service: service, phase: { .running(url: "https://\(publicHost)/mcp") }, setup: { nil },
                                          localDeviceID: { hostID }, devices: { [hostID: "Primary One", secondaryID: "Fixture"] }))
        // remote_hands_status：主機的專案清單（id、名稱、資料夾最後一段；沒有完整路徑；W183 R10：不照中央清單收窄＝這台全部專案）。
        let polled = try await HandsConnectOffMain.run { HandsConnectPayload(try secondary.callPrimary(method: "remote_hands_status", payload: [:])) }.value
        let polledJSON = String(decoding: try JSONSerialization.data(withJSONObject: polled), as: UTF8.self)
        let rows = polled["project_choices"] as? [[String: Any]] ?? []
        check(Set(rows.map { $0["id"] as? String ?? "" }) == Set(fx.visible.map(\.uuidString)) && rows.allSatisfy { Set($0.keys) == ["id", "name", "folder"] }
              && !polledJSON.contains(fx.root),
              "W183 R10 remote_hands_status：主機的專案清單＝這台全部能當專案的（id、名稱、資料夾最後一段，不帶完整路徑）", "\(polledJSON.prefix(300))")

        let chatgpt = FakeChatGPT(service: service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        _ = await waitUntil(8) { isConfirm(world.flow.card) }
        let shown = world.flow.offerShown
        world.flow.connect()
        let paired = await waitUntil(10) { world.pairing?.pairingCode != nil }
        let begin = harness.actions.get().last { $0["op"] as? String == "begin_connect" }
        let tx = service.auth.attemptTransaction(world.attemptID ?? "")
        check(shown?.scope.allProjects == true && shown?.supportsChoice == false && paired && begin != nil
              && begin?["level"] == nil && begin?["project_ids"] == nil && tx?.scope.allProjects == true && tx?.scope.level == 1,
              "W183 R10 副設備：卡片經簽章 RPC 拿到「全部專案」的卡片（沒有可以選的清單）；begin_connect 不帶等級、專案；快照＝設定的等級＋全部專案",
              "\(String(describing: begin))")
        world.flow.cancel(reason: "test_done")
        _ = await waitUntil(3) { service.auth.windowExpiresAt == nil }
    }

    // MARK: 接口：全部可見的 digest 只記「*」；舊格式照舊；begin_connect 的等級只收整數

    static let alphaName = "Alpha"

    @MainActor static func scopeWire(_ check: Checker) {
        let one = HandsProjectRef(id: UUID().uuidString, name: Self.alphaName), two = HandsProjectRef(id: UUID().uuidString, name: "BTC 實盤")
        func offer(_ projects: [HandsProjectRef], all: Bool, readOnly: [String] = []) -> HandsConnectOffer {
            HandsConnectOffer(hostDeviceID: hostID, hostName: "Primary One", publicHost: publicHost,
                              scope: HandsGrantScope(level: 1, projects: projects, memory: HandsGrantScope.memoryText(level: 1),
                                                     allProjects: all, readOnlyProjectIDs: readOnly),
                              callbackHosts: ["chatgpt.com"], setupEpoch: "e1")
        }
        let all = offer([one, two], all: true, readOnly: [two.id])
        let round = HandsConnectOffer(wire: all.wire)
        let grown = offer([one, two, HandsProjectRef(id: UUID().uuidString, name: "Fresh project")], all: true, readOnly: [two.id])
        let listed = offer([one, two], all: false)
        var forged = all.wire
        forged["all_projects"] = "true"   // 不是布林＝不算全部可見：digest 對不上＝整份不收
        check(round == all && round?.scope.readOnlyProjectIDs == [two.id] && grown.digest == all.digest && listed.digest != all.digest
              && HandsConnectOffer(wire: forged) == nil && HandsConnectOffer(wire: listed.wire)?.scope.allProjects == false,
              "W183 R10 接口：全部可見的卡片來回一樣（含只能看的清單）；digest 的專案那一段是「*」（多一個專案不會讓進行中的連線作廢）；舊格式（照清單）照舊；all_projects 不是布林＝不收")
        func parse(_ payload: [String: Any]) -> String {
            do { return (try HandsScopeChoice.fromWire(payload)).map { "L\($0.level):\($0.projectIDs.count)" } ?? "none" }
            catch { return "refused" }
        }
        check(parse([:]) == "none" && parse(["level": 2, "project_ids": ["a"]]) == "L2:1" && parse(["level": true, "project_ids": []]) == "refused"
              && parse(["level": 1.5, "project_ids": []]) == "refused" && parse(["level": 1]) == "refused" && parse(["level": 1, "project_ids": [3]]) == "refused",
              "W183 R7a begin_connect 的範圍欄位照舊嚴格解析（等級只收整數、專案 id 只收字串；只帶一半＝拒）；W183 R10 解析得出來的也一律不收（scopeHostRules）")
    }

    // MARK: W183 R10：中央設定即生效（不再 ∩ 本機）；專案全部可見；等級只看中央設定

    @MainActor static func scopeCentral(_ check: Checker, _ base: URL) throws {
        let fx = try scopeFixture(base, "scope-central")
        let (service, host) = try scopeHost(base, "scope-central", fx)
        // 本機：L0、沒有允許的專案（舊的閘門）。中央：L2。
        _ = try service.updateSettings { $0.level = 0; $0.allowedProjectIDs = [] }
        service.scopeCap = { (level: 2, projects: []) }
        let effective = service.effectiveSettings()
        let offer = try host.offer()
        check(effective.level == 2 && effective.allProjects && offer.scope.level == 2 && Set(offer.scope.projects.map(\.id)) == Set(fx.visible.map(\.uuidString)),
              "W183 R10 中央設定即生效：本機是 L0、allowed_project_ids 空的，中央給 L2＝有效範圍 L2＋這台全部專案（不再取小、不再 ∩ 本機）",
              "effective=L\(effective.level) all=\(effective.allProjects) offer=L\(offer.scope.level) \(offer.scope.projects.map(\.name))")
        // 中央收窄＝立刻收窄（撤銷照舊立即生效）：等級降到 L0、跑著的工作（HandsJobs 每 2 秒看）超出＝level_lowered。
        service.scopeCap = { (level: 0, projects: []) }
        let lowered = service.effectiveSettings()
        check(lowered.level == 0 && service.capProblem(level: 2, projectID: nil) == "level_lowered" && service.capProblem(level: 0, projectID: nil) == nil
              && (try? host.offer())?.scope.level == 0,
              "W183 R10 中央收窄照舊立刻生效：有效等級跟著降、跑著的工作超出就收掉、卡片跟著改")
        // 底線 B：交易類專案的寫入與執行（L1 以上）在最後一道（鎖裡、不碰主執行緒）也擋；讀（L0）不擋。
        service.scopeCap = { (level: 2, projects: []) }
        _ = service.allProjectRecords()   // 讀一次專案清單＝記下交易類（最後一道看這一份）
        check(service.capProblem(level: 2, projectID: fx.trading) == "project_read_only" && service.capProblem(level: 1, projectID: fx.hermes) == "project_read_only"
              && service.capProblem(level: 0, projectID: fx.trading) == nil && service.capProblem(level: 2, projectID: fx.alpha) == nil
              && service.isTradingProject(fx.trading) && service.isTradingProject(fx.hermes) && !service.isTradingProject(fx.beta),
              "W183 R10 底線 B：交易實盤類（名字含實盤、資料夾名含 hermes）L1、L2 的工作在最後一道也被擋；L0 與一般專案不受影響")
        service.scopeCap = nil
    }

    // MARK: W183 R10 第二輪（GPT-6 8）：中央設定 L1 → L2 之後，已經連上的 L1 grant 照舊只有 L1（實際叫工具驗，不是看設定）

    @MainActor static func scopeOldGrant(_ check: Checker, _ base: URL) throws {
        let fx = try scopeFixture(base, "scope-old-grant")
        let (service, _) = try scopeHost(base, "scope-old-grant", fx)
        // 中央設定 L1 的時候連上一筆（全部專案）。
        service.scopeCap = { (level: 1, projects: []) }
        let old = FakeChatGPT(service: service)
        try old.register()
        try service.startPairing()
        _ = old.begin()
        let access = try old.token(try old.submit(service.auth.pendingCard?.pairingCode ?? ""))
        let before = service.auth.grant(forAccess: access).flatMap { service.auth.grantRecord($0.grantID) }
        // 之後在任何一台把面板改成 L2（這台收到就生效）。
        service.scopeCap = { (level: 2, projects: []) }
        let widened = service.effectiveSettings().level
        let tools = try service.handle(method: "hands_tools", params: ["access_token": access])
        let names = (tools["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        var l2Refused = false
        let widerTool = "open_workspace"
        do {
            let result = try service.handle(method: "hands_call", params: ["access_token": access, "name": widerTool,
                                                                         "arguments": ["project_id": fx.alpha.uuidString, "title": "wider"]])
            l2Refused = (result["isError"] as? Bool) == true
        } catch { l2Refused = true }
        let after = service.auth.grant(forAccess: access).flatMap { service.auth.grantRecord($0.grantID) }
        check(!access.isEmpty && before?.level == 1 && widened == 2 && after?.level == 1 && tools["level"] as? Int == 1
              && !names.contains("open_workspace") && !names.contains("run_command") && names.contains("memory_inbox_save") && l2Refused
              && service.workspaceStore.all().isEmpty,
              "W183 R10 第二輪 中央設定 L1 → L2：已經連上的 L1 grant 照舊只有 L1（工具清單沒有 L2 的、叫 open_workspace 被拒、一個工作區都沒開）；新的連線才拿得到 L2",
              "level=\(String(describing: tools["level"])) names=\(names.count) refused=\(l2Refused)")
        service.scopeCap = nil
    }
}

extension HandsConnectAcceptance {
    // MARK: W183 R7a 審查留下來的：墓碑、同 ID 異內容

    @MainActor static func scopeConcurrency(_ check: Checker, _ base: URL) throws {
        let fx = try scopeFixture(base, "scope-race")
        let (service, host) = try scopeHost(base, "scope-race", fx)
        // 取消比 begin 先到（墓碑）：晚到的 begin 不開窗口。
        let early = try scopeRequest(host)
        let tomb = try host.cancel(attemptID: early.attemptID, sender: hostID, reason: "early")
        let late = try host.begin(early, sender: hostID)
        check(tomb.state == .cancelled && late.state == .cancelled && service.auth.windowExpiresAt == nil && settingsText(service) == "L1:",
              "W183 R7a 審查 取消比 begin 先到（墓碑）：晚到的 begin 不開窗口、設定不動", settingsText(service))
        // 同一個 attempt id、不同的內容：在任何副作用之前被拒（窗口是第一個的）。
        let id = UUID().uuidString
        let first = try scopeRequest(host, id: id)
        let opened = try host.begin(first, sender: hostID)
        let other = HandsConnectRequest(attemptID: id, setupEpoch: first.setupEpoch, ownerDeviceID: hostID, scopeDigest: "sha256:" + String(repeating: "0", count: 64),
                                        mcpURL: first.mcpURL)
        var refusal: HandsConnectRefusal?
        do { _ = try host.begin(other, sender: hostID) } catch let error as HandsConnectRefusal { refusal = error }
        check(opened.state == .open && refusal == .invalid && host.currentAttemptID == id && settingsText(service) == "L1:",
              "W183 R7a 審查 同一個 attempt id、不同的內容：在任何副作用之前被拒（窗口是第一個的）", "\(String(describing: refusal))")
        _ = try host.cancel(attemptID: id, sender: hostID, reason: "test_done")
    }

    // MARK: W183 R7a 審查（Claude）：資料夾暫時不見的專案——它的工作區不會因為按［連線］被鎖

    @MainActor static func scopeGoneKept(_ check: Checker, _ base: URL) throws {
        let fx = try scopeFixture(base, "scope-gone")
        let (service, host) = try scopeHost(base, "scope-gone", fx)
        let workspaceID = UUID()
        try service.workspaceStore.insert(HandsWorkspaceRecord(
            id: workspaceID, grantID: "grant-fixture", projectID: fx.missing, projectName: "Gone", title: "fixture", baseSHA: "", workspaceBase: "",
            workspaceHead: nil, candidateSHA: nil, submittedBaseSHA: nil, status: "open", lockReason: nil, dependencies: [], baselineBytes: 0,
            createdAt: Date(), updatedAt: Date()))
        let offer = try host.offer()
        let request = try scopeRequest(host)
        let status = try host.begin(request, sender: hostID)
        let record = service.workspaceStore.record(workspaceID)
        check(!offer.scope.projects.contains { $0.id == fx.missing.uuidString } && status.state == .open && record?.isLocked == false
              && settingsText(service) == "L1:",
              "W183 R10 資料夾暫時不見的專案：不在「這台全部專案」裡（外接碟沒掛上）；按［連線］不寫設定，它的工作區沒有被鎖",
              "locked=\(String(describing: record?.isLocked)) \(offer.scope.projects.map(\.name))")
        _ = try host.cancel(attemptID: request.attemptID, sender: hostID, reason: "test_done")
    }

    // MARK: W183 R7a 審查（GPT-6）：70 個專案不截斷

    @MainActor static func scopeLongList(_ check: Checker, _ base: URL) throws {
        let fx = try scopeFixture(base, "scope-long")
        var records: [(UUID, String, String)] = []
        for index in 0..<70 {
            let dir = URL(fileURLWithPath: fx.root).appendingPathComponent("many/p\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            records.append((UUID(), String(format: "P%02d", index), HandsPath.realpath(dir.path) ?? dir.path))
        }
        let (service, host) = try scopeHost(base, "scope-long", fx)
        let all = records
        service.projectsOverride = { all }
        let offer = try host.offer()
        let round = HandsConnectOffer(wire: offer.wire)
        let request = try scopeRequest(host)
        let status = try host.begin(request, sender: hostID)
        // 交易要等 ChatGPT 開始 OAuth 才有（範圍＝按［連線］時窗口拍下的快照）。
        let chatgpt = FakeChatGPT(service: service)
        try chatgpt.register()
        _ = chatgpt.begin()
        let tx = service.auth.attemptTransaction(request.attemptID)
        check(offer.scope.projects.count == 70 && round?.scope.projects.count == 70 && round?.digest == offer.digest && status.state == .open
              && tx?.scope.allProjects == true && tx?.scope.projects.count == 70,
              "W183 R10 主機有 70 個專案：卡片拿到完整的清單（不截在 64 個）；快照＝全部專案",
              "offer=\(offer.scope.projects.count) round=\(String(describing: round?.scope.projects.count)) state=\(status.state) tx=\(String(describing: tx?.scope.projects.count))")
        _ = try host.cancel(attemptID: request.attemptID, sender: hostID, reason: "test_done")
    }

    // MARK: W183 R7a 審查（Claude）：真的走 os.sock 的處理路徑（OSAgentBridge、引擎身分）送 remote_hands_action

    @MainActor static func scopeBridge(_ check: Checker, _ base: URL) async throws {
        let fx = try scopeFixture(base, "scope-bridge")
        let root = base.appendingPathComponent("scope-bridge-keys", isDirectory: true)
        guard let harness = try remoteHarness(root), let primary = harness.primary else { return check(false, "W183 R7a 審查 os.sock 反例：產生測試金鑰") }
        let secondary = harness.secondary
        let world = try World(base, "scope-bridge", owner: secondaryID, link: { _ in HandsConnectRemoteLink(dispatch: secondary) }, configure: fx.configure)
        let service = world.service
        let remoteHost = HandsRemote.Host(service: service, phase: { .running(url: "https://\(publicHost)/mcp") }, setup: { nil },
                                          localDeviceID: { hostID }, devices: { [hostID: "Primary One", secondaryID: "Fixture"] })
        harness.host.set(remoteHost)
        let bridge = OSAgentBridge.handsRemoteTestBridge(dispatch: primary, host: remoteHost)
        let offer = try world.host.offer(includeChoices: true)
        func expires() -> Int { Int(Date().timeIntervalSince1970 + 60) }
        /// scope＝帶卡上選的範圍（W183 R10 一律不收）；不帶＝新版擁有者的樣子。
        func beginPayload(_ id: String = UUID().uuidString, scope: Bool = false) -> [String: Any] {
            var out: [String: Any] = ["op": "begin_connect", "expires_at": expires(), "attempt_id": id, "setup_epoch": offer.setupEpoch,
                                      "owner_device_id": secondaryID, "scope_digest": offer.digest, "mcp_url": offer.mcpURL]
            if scope { out["level"] = 2; out["project_ids"] = [fx.alpha.uuidString] }
            return out
        }
        func send(_ caller: OSSocketCaller, _ method: String, _ params: [String: Any]) async -> String {
            let data = (try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])) ?? Data()
            let response = (try? await HandsConnectOffMain.run { bridge.respondForSelfTest(caller: caller, request: data) }) ?? Data()
            return String(decoding: response, as: UTF8.self)
        }
        let engine = OSSocketCaller.engine(UUID())
        let before = settingsText(service)
        // 沒有設備簽章（引擎直接連 os.sock 送 begin_connect）。
        let unsigned = await send(engine, "remote_hands_action", ["payload": beginPayload()])
        // 沒配對的金鑰簽的（形狀完全正確）。
        let stranger = root.appendingPathComponent("stranger-key")
        let (made, _) = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", stranger.path])
        let body = try JSONSerialization.data(withJSONObject: ["method": "remote_hands_action", "sender": secondaryID, "recipient": hostID, "epoch": 1,
                                                               "seq": 9_000_000, "payload": beginPayload()], options: [.sortedKeys])
        let (signedOK, signature) = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", stranger.path, "-P", "", "-n", "tatwo2-rpc"], input: body)
        let strangerKey = (try? String(contentsOfFile: stranger.path + ".pub", encoding: .utf8)) ?? ""
        let foreign = await send(engine, "remote_hands_action", ["body": body.base64EncodedString(), "signature": signature.base64EncodedString(),
                                                                 "publicKey": strangerKey])
        // 配對過的金鑰、但簽的是別的方法（remote_hands_status）：拿來當 remote_hands_action 用。
        let otherMethod = await send(engine, "remote_hands_action", try secondary.signed(method: "remote_hands_status", payload: beginPayload()))
        // 重放已處理的簽章；第一次因範圍不合法而拒絕，仍必須消耗序號。
        let stale = try secondary.signed(method: "remote_hands_action", payload: beginPayload(scope: true))
        let firstUse = await send(engine, "remote_hands_action", stale)
        let newer = await send(engine, "remote_hands_action", try secondary.signed(method: "remote_hands_action",
                                                                                    payload: ["op": "connect_offer", "expires_at": expires()]))
        let replayed = await send(engine, "remote_hands_action", stale)
        let untouched = settingsText(service) == before && service.auth.windowExpiresAt == nil && world.host.currentAttemptID == nil
        check(made == 0 && signedOK == 0 && unsigned.contains("untrusted_rpc_sender") && foreign.contains("untrusted_rpc_sender")
              && otherMethod.contains("untrusted_rpc_sender") && firstUse.contains("connect_scope_invalid") && newer.contains("\"ok\":true") && replayed.contains("stale_epoch_or_replayed_sequence") && untouched,
              "W183 R7a 反例：沒有設備簽章的 begin_connect（引擎身分真的走 os.sock 的處理路徑）、沒配對的金鑰、別的方法的簽章、重放舊序號一律拒；設定、窗口都沒動",
              "unsigned=\(unsigned.prefix(120)) foreign=\(foreign.prefix(120)) other=\(otherMethod.prefix(120)) newer=\(newer.prefix(80)) replayed=\(replayed.prefix(120)) \(settingsText(service))")
        // 外部 AI（關口）的身分：連 remote_hands_action、hands_setup_step 都叫不到（真的走處理路徑）。
        let externalAction = await send(.externalAI, "remote_hands_action", try secondary.signed(method: "remote_hands_action", payload: beginPayload()))
        let externalSetup = await send(.externalAI, "hands_setup_step", ["step": "all"])
        check(externalAction.contains("caller_not_trusted") && externalSetup.contains("caller_not_trusted") && settingsText(service) == before,
              "W183 R7a 反例：外部 AI 的身分叫不到 remote_hands_action（begin_connect）與 hands_setup_step（真的走 os.sock 的處理路徑）",
              "\(externalAction.prefix(120)) \(externalSetup.prefix(120))")
        // W183 R10：有效的設備簽章、但帶了卡上選的範圍＝一律不收（範圍只照中央設定）。
        let scoped = await send(engine, "remote_hands_action", try secondary.signed(method: "remote_hands_action", payload: beginPayload(scope: true)))
        check(scoped.contains("connect_scope_invalid") && settingsText(service) == before && world.host.currentAttemptID == nil,
              "W183 R10 有效簽章的 begin_connect 帶了等級、專案＝connect_scope_invalid：設定不動、不開窗口", "\(scoped.prefix(160))")
        // 對照組：同一條路徑、有效的設備簽章、不帶範圍（副設備卡片的［連線］）才開得了窗口——上面的拒絕不是空驗。
        // （殘餘：持有這台配對金鑰的同使用者程式也簽得出來，見 threat-model T17。）
        let id = UUID().uuidString
        let accepted = await send(engine, "remote_hands_action", try secondary.signed(method: "remote_hands_action", payload: beginPayload(id)))
        let opened = world.host.currentAttemptID == id
        _ = await send(engine, "remote_hands_action", try secondary.signed(method: "remote_hands_action",
                                                                            payload: ["op": "cancel_connect", "expires_at": expires(), "attempt_id": id, "reason": "test_done"]))
        check(accepted.contains("\"ok\":true") && opened && settingsText(service) == before && world.host.currentAttemptID == nil,
              "W183 R10 對照組：同一條 os.sock 路徑、有效的設備簽章、不帶範圍才開得了窗口（上面的拒絕不是空驗）；設定照舊不寫", "\(accepted.prefix(160))")
    }
}

extension HandsUIAcceptance {
    @MainActor static func r7aChecks(_ check: Checker, _ fixture: Fixture) async throws {
        r7aMessageChecks(check)
        r7aProbeParsingChecks(check)
        try await r7aRetireRetryChecks(check, fixture)
        try r7aAssistantChecks(check, fixture)
    }

    /// 訊息裡用「」點名的字。
    static func quotedNames(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "「([^」]+)」") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    // MARK: 步驟訊息與畫面一致（按鈕名稱、第 N 步、不露內部代號）

    @MainActor static func r7aMessageChecks(_ check: Checker) {
        let url = HandsSetup.urlMessage("https://os-for-chatgpt.example.com/mcp")
        check(!url.contains("W183") && !url.contains("R6a") && url.contains("［連線］"), "W183 R7a 第 6 步（網址給 ChatGPT）的訊息不露內部代號", url)
        // 訊息裡點名的按鈕都是畫面上真的有的：那一列的鈕、步驟清單的鈕、授權後那一列、Island、Cloudflare 授權頁、環境登入。
        let onScreen = Set(HandsOneSwitchStatus.Action.allCases.map(\.title)).union([
            "取消", "是這個，繼續", "取消並重新授權", "再查一次網域名稱", "在這台打開授權頁", "換主機", "允許", "Authorize",
            "用瀏覽器登入 Cloudflare", "設定 › 環境登入 › Cloudflare"])
        let messages = [HandsSetup.lingeringMessage, HandsSetup.leftoverMessage, HandsSetup.resumeNeedsLoginMessage,
                        HandsSetup.fixedHostTakenMessage("os-for-chatgpt.example.com"), HandsSetup.fixedHostUnconfirmedMessage,
                        HandsSetup.fixedHostOtherDeviceMessage("os-for-chatgpt.example.com"), HandsSetup.hostChangeNeedsConfirmMessage,
                        HandsSetup.handbackNotSavedMessage, HandsSetup.handbackStillRunningMessage, HandsSetup.leaseUnreachableMessage,
                        HandsSetup.cloudflaredMissing, HandsSetup.authorizeWaitingMessage, HandsSetup.authorizeWaitingRemoteMessage,
                        HandsSetup.confirmWaitingMessage, HandsSetup.cleanupPendingMessage, HandsSetup.namesUnknownMessage,
                        HandsSetup.confirmFirstMessage, HandsSetup.lookupFailedMessage, HandsSetup.lookupUnclearMessage,
                        HandsSetup.cancelledMessage(HandsSetupStep.authorize.rawValue), HandsSetup.cancelledMessage(HandsSetupStep.tunnel.rawValue)]
        let named = messages.flatMap(quotedNames)
        let unknown = named.filter { !onScreen.contains($0) }
        check(!named.isEmpty && unknown.isEmpty, "W183 R7a 步驟訊息裡點名的按鈕都是畫面上真的有的（不再有「重跑這一步」這種對不上的名字）", "\(unknown)")
        // 授權那一步：訊息、那一列的鈕、步驟清單的鈕都叫「重新授權」；其他步驟都叫「重試」。
        var failedAuth = HandsSetupState()
        for step in [HandsSetupStep.host, .cloudflared] { failedAuth.steps[step.rawValue] = HandsSetupStepState(status: .done) }
        failedAuth.steps[HandsSetupStep.authorize.rawValue] = HandsSetupStepState(status: .failed,
            message: "Cloudflare 授權沒有完成（取消、逾時或網路不通）；按「重新授權」再試一次")
        var cancelledAuth = failedAuth
        cancelledAuth.steps[HandsSetupStep.authorize.rawValue] = HandsSetupStepState(status: .pending,
            message: HandsSetup.cancelledMessage(HandsSetupStep.authorize.rawValue))
        func line(_ state: HandsSetupState) -> HandsOneSwitchStatus {
            HandsOneSwitchStatus.forLocal(.init(enabled: true, level: 1, busy: false, setup: state, loginOpen: false, blocked: nil, phase: .stopped,
                                             activeGrants: 0, connect: .idle, connectProblem: nil, handback: nil))
        }
        check(line(failedAuth).action == .reauthorize && line(cancelledAuth).action == .reauthorize
              && ChatGPTHandsStepRow.rerunLabel(for: .authorize) == "重新授權" && ChatGPTHandsStepRow.rerunLabel(for: .tunnel) == "重試"
              && ChatGPTHandsStepRow.rerunLabel(for: .cloudflared) == "重試"
              && HandsSetup.cancelledMessage(HandsSetupStep.authorize.rawValue).contains("「重新授權」")
              && HandsSetup.cancelledMessage(HandsSetupStep.start.rawValue).contains("「重試」"),
              "W183 R7a 授權那一步出錯或取消：訊息、那一列的鈕、步驟清單的鈕都叫「重新授權」；其他步驟都叫「重試」")
        // 那一行沒有步驟編號；步驟清單的編號跟訊息裡的「第 N 步」一致。
        check(HandsOneSwitchStatus.short("先完成第 3 步（Cloudflare 授權）") == "先完成「Cloudflare 授權」"
              && !HandsOneSwitchStatus.short("先完成第 4 步（通道與網址）").contains("第")
              && !HandsOneSwitchStatus.short(HandsSetup.confirmFirstMessage).contains("第")
              && HandsSetupStep.cloudflared.number == 2 && HandsSetupStep.authorize.number == 3 && HandsSetupStep.tunnel.number == 4
              && HandsSetupStep.start.number == 5 && HandsSetupStep.url.number == 6,
              "W183 R7a 那一行不寫「第 N 步」（只留步驟名）；步驟清單的編號跟訊息裡的「第 N 步」一致（2 cloudflared、3 授權、4 通道、5 關口、6 網址）")
    }

    // MARK: 公開 DNS＋直連的外部確認（純解析；自測不上網）

    static func r7aProbeParsingChecks(_ check: Checker) {
        typealias DoH = HandsCloudflared.DoHAnswer
        let host = "os-for-chatgpt.example.com"
        func doh(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
        func parse(_ object: [String: Any], _ type: String = "A") -> DoH { HandsCloudflared.parseDNSJSON(doh(object), host: host, type: type) }
        let question: [[String: Any]] = [["name": host + ".", "type": 1]]
        let edge = "104.16.0.1", edge2 = "104.16.0.2", edge6 = "2606:4700::6810:1"
        let lan = "\(10).0.0.5"
        let tunnel = "x.cfargotunnel.com.", other = "other.example.net"
        let chained = parse(["Status": 0, "Question": question, "Answer": [
            ["name": host + ".", "type": 5, "data": tunnel], ["name": tunnel, "type": 1, "data": edge]]])
        let flat = parse(["Status": 0, "Question": [["name": host, "type": 1]], "Answer": [["name": host, "type": 1, "data": edge]]])
        let nx = parse(["Status": 3, "Question": question])
        let privateMixed = parse(["Status": 0, "Question": question, "Answer": [["name": host, "type": 1, "data": edge], ["name": host, "type": 1, "data": lan]]])
        let junk = HandsCloudflared.parseDNSJSON(Data("<html>".utf8), host: host, type: "A")
        let otherQuestion = parse(["Status": 0, "Question": [["name": other, "type": 1]], "Answer": [["name": other, "type": 1, "data": edge]]])
        let wrongType = parse(["Status": 0, "Question": [["name": host, "type": 28]], "Answer": [["name": host, "type": 1, "data": edge]]])
        let unlinked = parse(["Status": 0, "Question": question, "Answer": [["name": other + ".", "type": 1, "data": edge]]])
        let truncated = parse(["Status": 0, "TC": true, "Question": question, "Answer": [["name": host, "type": 1, "data": edge]]])
        let emptyA = parse(["Status": 0, "Question": question])
        let v6 = parse(["Status": 0, "Question": [["name": host, "type": 28]], "Answer": [["name": host, "type": 28, "data": edge6]]], "AAAA")
        check(chained == .addresses([edge]) && flat == .addresses([edge]) && nx == .failure("nxdomain") && privateMixed == .failure("private")
              && junk == .failure("malformed") && otherQuestion == .failure("question") && wrongType == .failure("question") && unlinked == .failure("unlinked")
              && truncated == .failure("truncated") && emptyA == .addresses([]) && v6 == .addresses([edge6]),
              "W183 R7a 公開 DNS（DoH JSON，用 IP 連、不經系統解析）：問題要對得上、答案沿 CNAME 接得上這個名字、只收公開位址；NXDOMAIN、私人位址（混一個也不行）、截斷、接不上、看不懂的一律不算",
              "\(chained) \(flat) \(nx) \(privateMixed) \(junk) \(otherQuestion) \(unlinked) \(truncated) \(emptyA) \(v6)")
        // W183 R7a 審查（GPT-6）：刪除判定——每個解析器都乾淨、答案一致才拿去直連；部分失敗、不一致＝不確認；A 失敗不改問 AAAA。
        let ok: DoH = .addresses([edge])
        let combined = HandsCloudflared.combineDoH([ok, ok])
        func decide(_ a: [DoH], _ aaaa: [DoH]) -> (verdict: String, askedAAAA: Bool, probed: String?) {
            var verdict = "never", asked = false
            var probed: String?
            HandsCloudflared.probeViaPublicDNS(host: host, query: { _, type, done in
                if type == "AAAA" { asked = true; done(aaaa) } else { done(a) }
            }, probe: { address, _, done in probed = address; done(nil) }, completion: { verdict = $0 ?? "confirmed" })
            return (verdict, asked, probed)
        }
        let clean = decide([ok, ok], [])
        let secondOnly = decide([.failure("failed"), ok], [])
        let firstOnly = decide([ok, .failure("malformed")], [])
        let disagree = decide([ok, .addresses([edge2])], [])
        let badA = decide([.failure("malformed"), .failure("malformed")], [.addresses([edge6]), .addresses([edge6])])
        let noA = decide([.addresses([]), .addresses([])], [.addresses([edge6]), .addresses([edge6])])
        let noAPartial = decide([.addresses([]), .addresses([])], [.addresses([edge6]), .failure("failed")])
        let allNX = decide([.failure("nxdomain"), .failure("nxdomain")], [])
        check(combined.addresses == [edge] && combined.failure == nil
              && clean.verdict == "confirmed" && clean.probed == edge && !clean.askedAAAA
              && secondOnly.verdict == "doh_partial" && secondOnly.probed == nil && firstOnly.verdict == "doh_partial" && firstOnly.probed == nil
              && disagree.verdict == "doh_inconsistent" && disagree.probed == nil
              && badA.verdict == "doh_malformed" && !badA.askedAAAA && badA.probed == nil
              && noA.verdict == "confirmed" && noA.askedAAAA && noA.probed == edge6
              && noAPartial.verdict == "doh_partial" && noAPartial.probed == nil && allNX.verdict == "doh_nxdomain",
              "W183 R7a 審查 刪除判定：每個公開解析器都乾淨、答案一致才拿去直連確認；備援成功但另一個失敗、格式不對、答案不一致＝不確認（舊紀錄照留、之後再試）；A 失敗不改問 AAAA，乾淨地沒有 A 才問",
              "\(clean) \(secondOnly) \(firstOnly) \(disagree) \(badA) \(noA) \(noAPartial) \(allNX)")
        // 位址：照位元組判斷（各種寫法的本機、私人、對應的 IPv4 都不算）。
        let blocked = ["::1", "0:0:0:0:0:0:0:1", "0000:0000:0000:0000:0000:0000:0000:0001", "::", "::ffff:a00:5", "0:0:0:0:0:ffff:a00:5",
                       "::ffff:127.0.0.1", "::a00:5", "64:ff9b::a00:5", "fe80::1", "FE80::1", "fc00::1", "fd12:3456::1", "ff02::1", "2001:db8::1",
                       "2002:a00:5::1", "2001:0:4136:e378::1", "3fff::1", "fe80::1%en0",
                       "127.0.0.1", lan, "\(172).16.0.1", "\(192).168.1.1", "100.64.0.1", "169.254.1.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
                       "198.18.0.1", "192.0.2.1", "203.0.113.9", "010.0.0.5", "1.1.1", "not-an-ip"]
        let allowed = ["2606:4700::1", "2606:4700:0000:0000:0000:0000:0000:0001", edge, "1.1.1.1"]
        let leaked = blocked.filter(HandsCloudflared.isPublicAddress)
        let refused = allowed.filter { !HandsCloudflared.isPublicAddress($0) }
        check(leaked.isEmpty && refused.isEmpty,
              "W183 R7a 審查 公開位址照 inet_pton 的位元組判斷：展開寫法的 ::1、IPv4 對應（含十六進位寫法）、NAT64、6to4、Teredo、文件用、鏈結本地、私人、CGNAT 一律不算",
              "leaked=\(leaked) refused=\(refused)")
        // 直連的回應：嚴格照框。
        func verdict(_ text: String, closed: Bool = true, failed: Bool = false) -> String? {
            switch HandsCloudflared.receiveVerdict(Data(text.utf8), closed: closed, failed: failed, host: host) {
            case .none: return "wait"
            case .some(let inner): return inner ?? "confirmed"
            }
        }
        let head = "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\n"
        let plain = head + "Content-Length: 9\r\n\r\nforbidden"
        let chunked = head + "Transfer-Encoding: chunked\r\n\r\n4\r\nforb\r\n5\r\nidden\r\n0\r\n\r\n"
        let trailers = head + "Transfer-Encoding: chunked\r\n\r\n9\r\nforbidden\r\n0\r\nX-Trace: 1\r\n\r\n"
        let chunkNoEnd = head + "Transfer-Encoding: chunked\r\n\r\n9\r\nforbidden\r\n0\r\n"
        let chunkNoCRLF = head + "Transfer-Encoding: chunked\r\n\r\n9\r\nforbiddenXX0\r\n\r\n"
        let chunkBadSize = head + "Transfer-Encoding: chunked\r\n\r\n+9\r\nforbidden\r\n0\r\n\r\n"
        let both = head + "Content-Length: 9\r\nTransfer-Encoding: chunked\r\n\r\n9\r\nforbidden\r\n0\r\n\r\n"
        let twoLengths = head + "Content-Length: 9\r\nContent-Length: 9\r\n\r\nforbidden"
        let extra = plain + "X"
        let folded = head + " X-Fold: a\r\nContent-Length: 9\r\n\r\nforbidden"
        let gzip = head + "Transfer-Encoding: gzip, chunked\r\n\r\n9\r\nforbidden\r\n0\r\n\r\n"
        let noLength = head + "\r\nforbidden"
        let cfPage = "HTTP/1.1 530 \r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\n<html"
        let interim = "HTTP/1.1 100 Continue\r\n\r\n"
        let results = [
            verdict(plain), verdict(chunked), verdict(trailers), verdict(noLength),                                  // 0-3 確認
            verdict(plain, failed: true), verdict(noLength, failed: true), verdict(chunked, closed: false, failed: true), // 4-6 接收出錯＝network
            verdict(chunkNoEnd, closed: false), verdict(noLength, closed: false), verdict(head + "Content-Length: 9\r\n\r\nforb", closed: false), // 7-9 還沒收完
            verdict(chunkNoEnd), verdict(head + "Content-Length: 9\r\n\r\nforb"),                                     // 10-11 收不完就關線
            verdict(chunkNoCRLF), verdict(chunkBadSize), verdict(both), verdict(twoLengths), verdict(extra), verdict(folded),
            verdict(gzip), verdict(cfPage), verdict(interim), verdict("garbage\r\n\r\n"),                             // 12-21 格式不對、不是關口
        ]
        let expected: [String] = ["confirmed", "confirmed", "confirmed", "confirmed", "network", "network", "network", "wait", "wait", "wait"]
            + Array(repeating: "not_gateway", count: 12)
        check(results.compactMap { $0 } == expected,
              "W183 R7a 直連的回應照同一個判斷（W183 R7a 審查：嚴格照框）：TATWO 關口的 403 forbidden（含 chunked、trailers）才算；接收出錯一律連不上；"
              + "沒收完不判、收不完就關線不算；chunk 沒有 CRLF、長度不是十六進位、長度標頭衝突或重複、多出來的位元組、折行、非 chunked 的傳輸編碼、1xx、Cloudflare 的錯誤頁都不算",
              "\(results)")
    }

    // MARK: 舊 DNS 紀錄：確認不了就不刪，之後自己再試（不用按）

    @MainActor static func r7aRetireRetryChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "r7a-retire-retry", zoneName: "example.com")
        let oldLabel = "h" + HandsSetup.randomLabel(19)
        _ = try world.service.updateSettings { $0.enabled = true; $0.subdomainLabel = oldLabel }
        world.flag("authorized", true)
        world.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        _ = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .user)   // W183 R8c：登入只是登入；選網域、按「套用」
        _ = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
        _ = try world.service.updateSettings { $0.subdomainLabel = nil }
        let old = oldLabel + ".example.com", fixed = "os-for-chatgpt.example.com"
        var deps = world.setup.dependencies
        deps.retireRetryDelays = [0.4]
        let setup = HandsSetup(dependencies: deps)
        let logURL = world.paths.root.appendingPathComponent("logs/setup-errors.log")
        func probeFailures() -> Int {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0.contains("dns.probe category=network") }.count
        }
        world.probeFailure.set("network")
        setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !setup.isBusy && setup.nextStep == .pairing }
        let first = probeFailures()
        let kept = setup.snapshot.publicHost == fixed && setup.snapshot.retiredHost?.host == old && world.dnsNames().contains(old) && first >= 1
        let retried = await waitUntil(10) { probeFailures() >= first + 2 }
        let stillKept = setup.snapshot.retiredHost?.host == old && world.dnsNames().contains(old) && world.dnsDeletes.get().isEmpty && !setup.isBusy
        world.probeFailure.set(nil)
        let cleared = await waitUntil(10) { setup.snapshot.retiredHost == nil && !world.dnsNames().contains(old) }
        check(kept && retried && stillKept && cleared && world.dnsNames().contains(fixed) && world.dnsDeletes.get().count == 1,
              "W183 R7a 舊紀錄：新網址從外面確認不了（network）＝不刪、記著；之後不用按，自己隔一段時間再試（確認不了照樣不刪、不算設定流程的忙碌）；確認得了才刪",
              "kept=\(kept) retried=\(retried) stillKept=\(stillKept) cleared=\(cleared) \(world.dnsNames())")
    }

    // MARK: 助理（hands_setup_step）改不了等級與專案

    static func r7aAssistantChecks(_ check: Checker, _ fixture: Fixture) throws {
        let world = try World(fixture, folder: "r7a-assistant", zoneName: "example.com")
        _ = try world.service.updateSettings { $0.enabled = true; $0.level = 1 }
        var refused = 0
        for extra: [String: Any] in [["level": 2], ["allowed_project_ids": [UUID().uuidString]], ["project_ids": [UUID().uuidString]], ["scope": "L2"]] {
            var params: [String: Any] = ["step": "all"]
            params.merge(extra) { _, new in new }
            do { _ = try HandsSetupTool.handle(method: "hands_setup_step", params: params, setup: world.setup) }
            catch { if String(describing: error).contains("unexpected field") { refused += 1 } }
        }
        let settings = world.service.settings.load()
        check(refused == 4 && settings.level == 1 && settings.allowedProjectIDs.isEmpty && !world.setup.isBusy,
              "W183 R7a 反例：助理的 hands_setup_step 帶等級、專案一律拒（unexpected field），設定不動", "\(refused)")
    }
}
#endif
