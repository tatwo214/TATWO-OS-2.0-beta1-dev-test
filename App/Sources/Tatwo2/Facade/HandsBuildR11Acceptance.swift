#if DEBUG
import Combine
import Foundation

// W183 R11 第二輪自測（w183build；Fleet＝真的設定正本、信封、信箱、每台的 reconcile 與回報；用測試金鑰簽，不上網）：GPT-6 R11 審查的反例。
// - 7（中）正式的 HandsBuildController.disconnect 三條路（這台本機、副設備→主設備 RPC、別台經信箱）都真的撤銷：指定那台的舊 access、refresh
//   被拒，撤銷的收尾有跑（它的工作區鎖成 grant_revoked：同一個收尾也收掉它的工作與沙盒行程）。
// - 6（中）一台失敗不擋後面的；逐台結果（已撤銷／撤銷了但沒存成／沒做成）；流程接正式 controller：再按只重試沒斷的。
// - 1（高）R10 的樣子（收窄過的 L2 grant、本機 L1、沒有封頂檔）→ 主設備遷移：會先封頂的主機才升、舊 token 照舊 L1；舊版主機（沒有 level_guard）
//   有連線＝先不升；它更新之後才升。
// - 5（中）舊版回報沒有連線等級＝能力未確認（controller.connectedLevel＝nil、判定＝已連線・能力未確認）。
// - 3、4（中）入口對著真的回報：帳號 A 的連線＋Pod 換成 B＝給［連線］（主機有授權照實另外報）、按下去照樣排那台；在別處撤銷、那台停了＝
//   已連線卡跟著改；剛連上的樂觀只到期限。

extension HandsBuildAcceptance {
    @MainActor static func r11bChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        try await r11bDisconnectTransports(check, base, keys)
        try await r11bMigrationFleet(check, base, keys)
        try await r11bPanelRaise(check, base, keys)   // W183 R11 第二輪（GPT-6 R11b 審查 1）
        try await r11bEntryFleet(check, base, keys)
        try await r11cClockJumps(check, base, keys)      // W183 R11 最後一輪（GPT-6 R11c 審查 4）
        try await r11cDelayedSnapshot(check, base, keys)  // W183 R11 最後一輪（GPT-6 R11c 審查 4）
    }

    /// 配對一筆（跟 pair 一樣走完整的授權），回 access、refresh、client 與 grant id（撤銷之後拿 refresh 再換一次＝要被拒）。
    struct R11Paired {
        let access: String
        let refresh: String
        let client: String
        let grant: String
    }

    static func r11Pair(_ service: HandsService, host: String) throws -> R11Paired {
        try service.startPairing()
        let chatgpt = HandsConnectAcceptance.FakeChatGPT(service: service)
        try chatgpt.register()
        _ = try service.handle(method: "hands_auth", params: [
            "op": "authorize_begin", "client_id": chatgpt.clientID, "redirect_uri": chatgpt.redirect, "code_challenge": chatgpt.challenge,
            "code_challenge_method": "S256", "state": chatgpt.state, "resource": "https://\(host)/mcp", "scope": "tatwo.hands"])
        let code = service.auth.pendingCard?.pairingCode ?? ""
        chatgpt.transaction = service.auth.pendingCard?.id ?? ""
        let authorization = try chatgpt.submit(code)
        let result = try service.handle(method: "hands_auth", params: [
            "op": "token", "grant_type": "authorization_code", "code": authorization, "code_verifier": chatgpt.verifier,
            "client_id": chatgpt.clientID, "redirect_uri": chatgpt.redirect])
        let access = result["access_token"] as? String ?? ""
        return R11Paired(access: access, refresh: result["refresh_token"] as? String ?? "", client: chatgpt.clientID,
                         grant: service.auth.grant(forAccess: access)?.grantID ?? "")
    }

    static func r11ToolLevel(_ service: HandsService, _ access: String) -> Int? {
        (try? service.handle(method: "hands_tools", params: ["access_token": access]))?["level"] as? Int
    }

    static func r11ToolNames(_ service: HandsService, _ access: String) -> Set<String> {
        let result = try? service.handle(method: "hands_tools", params: ["access_token": access])
        return Set((result?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
    }

    /// 舊的 refresh token 再換一次：被拒＝true。
    static func r11RefreshRefused(_ service: HandsService, _ paired: R11Paired) -> Bool {
        guard paired.refresh.hasPrefix("tatwoh_rt_") else { return false }   // 沒拿到 refresh＝這一項不算過（不讓空字串假裝被拒）
        do {
            _ = try service.handle(method: "hands_auth", params: ["op": "token", "grant_type": "refresh_token", "refresh_token": paired.refresh,
                                                                  "client_id": paired.client])
            return false
        } catch {
            return true
        }
    }

    /// 那一筆連線的工作區紀錄（撤銷的收尾會把它鎖成 grant_revoked：同一個收尾也收掉它的工作與沙盒行程）。
    static func r11Workspace(_ service: HandsService, grant: String) throws -> UUID {
        let id = UUID()
        try service.workspaceStore.insert(HandsWorkspaceRecord(
            id: id, grantID: grant, projectID: UUID(), projectName: "Fixture", title: "r11b", baseSHA: "", workspaceBase: "",
            workspaceHead: nil, candidateSHA: nil, submittedBaseSHA: nil, status: "open", lockReason: nil, dependencies: [], baselineBytes: 0,
            createdAt: Date(), updatedAt: Date()))
        return id
    }

    /// 自測的主設備傳輸：設備簽章 RPC 那一段換成直接叫主設備（Fleet 裡的 P）那端真的 HandsRemote.handle（簽章當作已驗）。
    static func fleetPrimaryCall(_ fleet: Fleet, sender: String) -> @Sendable (String, [String: Any]) throws -> [String: Any] {
        { method, payload in
            guard let primary = fleet.devices[HandsBuildAcceptance.pID]?.service else { throw RemoteHostLinkError.tunnelUnavailable }
            let host = HandsRemote.Host(service: primary, phase: { .running(url: "https://os-for-chatgpt.example.com/mcp") }, setup: { nil },
                                        localDeviceID: { HandsBuildAcceptance.pID })
            return try HandsRemote.handle(method: method, payload: payload, sender: sender, host: host)
        }
    }

    /// 這台（A）的正式 controller。W183 R11 第二輪（GPT-6 R11b 審查 5）：撤銷用正式的建構器（HandsRevocationWiring.standard）——
    /// 自測只換底下的 service（A 自己的 HandsService）與傳輸（主設備那端真的 remote_hands_action），撤銷本身不另寫；信箱＝Fleet。
    @MainActor static func r11Controller(_ fleet: Fleet, _ device: Device, flow: HandsConnectFlow, primary: HandsService,
                                         primaryDown: HandsLocked<Bool>, primaryCalls: HandsLocked<Int>) -> HandsBuildController {
        let id = device.id, role = device.role
        let host = HandsRemote.Host(service: primary, phase: { .running(url: "https://os-for-chatgpt.example.com/mcp") }, setup: { nil },
                                    localDeviceID: { HandsBuildAcceptance.pID })
        let executor: HandsBuildExecutor = device.executor
        let transport: @Sendable (String, [String: Any]) throws -> [String: Any] = { method, payload in
            primaryCalls.update { $0 += 1 }
            if primaryDown.get() { throw RemoteHostLinkError.tunnelUnavailable }
            return try HandsRemote.handle(method: method, payload: payload, sender: id, host: host)
        }
        return HandsBuildController(dependencies: .init(
            sync: device.sync, flow: flow, localID: { id }, pairedDevices: { HandsBuildAcceptance.known }, loginHere: {},
            unlockHere: { incident, epoch, generation in executor.unlockHere(incident: incident, setupEpoch: epoch, revocationGeneration: generation) },
            revocation: .standard(service: device.service, callPrimary: transport),
            role: { role },
            openLogin: { _, _ in }, closeLogin: { _ in }, markLoginDone: { _ in },
            background: { work in work() }, now: { fleet.clock.now(for: id) }, uptime: { fleet.clock.uptime() }))   // W183 R11 最後一輪
    }

    /// 畫面看的全貌（HandsBuildSync.view）是在主執行緒非同步換的：同步一輪之後，等那幾台的回報（連線摘要、關口在不在跑）真的出現在這一份裡。
    @MainActor static func r11CaughtUp(_ controller: HandsBuildController, _ devices: [Device]) async -> Bool {
        await waitUntil(5) {
            devices.allSatisfy { device in
                guard let report = controller.view.report(device.id) else { return false }
                let running: Bool = { if case .running = device.phase.get() { return true }; return false }()
                return report.grantsDigest == HandsBuildDeviceReport.digest(grants: device.service.auth.activeGrantIDs)
                    && (report.phase == "running") == running
            }
        }
    }

    @MainActor static func r11InertFlow(owner: String) -> HandsConnectFlow {
        HandsConnectFlow(dependencies: .init(link: { (nil, "r11b") }, pod: { HandsConnectAcceptance.FakePod(window: { false }) },
                                             presenter: { HandsConnectAcceptance.FakePresenter() }, localDeviceID: { owner }, copy: { _ in }))
    }

    /// 等正式的 controller 斷線做完（信箱那條要 B 同步、執行、A 同步才回來：一邊等一邊幫它們同步）。
    @MainActor static func r11Disconnect(_ fleet: Fleet, _ controller: HandsBuildController, _ ids: [String],
                                         pump: [Device]) async -> [String: HandsDisconnectOutcome]? {
        let finished = HandsLocked<[String: HandsDisconnectOutcome]?>(nil)
        Task { @MainActor in finished.set(await controller.disconnect(deviceIDs: ids)) }
        for _ in 0..<300 {
            if finished.get() != nil { break }
            for device in pump { device.sync.syncNow(); device.executor.drain() }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return finished.get()
    }

    // MARK: 7、6. 正式 controller 的三條撤銷路；一台失敗不擋後面的

    @MainActor static func r11bDisconnectTransports(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("r11b-disconnect"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One"), a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B")
        _ = try fleet.update([.select(device: pID, selected: true), .select(device: aID, selected: true), .select(device: bID, selected: true),
                              .setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        let hosts: [(Device, String)] = [(p, "os-for-chatgpt.example.com"), (a, "os-for-chatgpt-laptopa.example.com"),
                                         (b, "os-for-chatgpt-studiob.example.com")]
        for (device, host) in hosts {
            _ = try device.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = device.id }
            device.phase.set(.running(url: "https://\(host)/mcp"))
        }
        fleet.syncAll(); fleet.syncAll()
        let pp = try r11Pair(p.service, host: hosts[0].1), ap = try r11Pair(a.service, host: hosts[1].1), bp = try r11Pair(b.service, host: hosts[2].1)
        let pw = try r11Workspace(p.service, grant: pp.grant), aw = try r11Workspace(a.service, grant: ap.grant), bw = try r11Workspace(b.service, grant: bp.grant)
        fleet.syncAll()
        let flow = r11InertFlow(owner: aID)
        let primaryDown = HandsLocked(false), primaryCalls = HandsLocked(0)
        let controller = r11Controller(fleet, a, flow: flow, primary: p.service, primaryDown: primaryDown, primaryCalls: primaryCalls)
        let caught = await r11CaughtUp(controller, [p, a, b])
        let ready = caught && tools(p.service, pp.access) && tools(a.service, ap.access) && tools(b.service, bp.access)
            && controller.view.report(bID)?.setupEpoch != nil
        let outcomes = await r11Disconnect(fleet, controller, [aID, pID, bID], pump: [b, a])
        func locked(_ service: HandsService, _ id: UUID) -> Bool { service.workspaceStore.record(id)?.lockReason == "grant_revoked:user_revoked_all" }
        check(ready && outcomes?[aID] == .revoked && outcomes?[pID] == .revoked && outcomes?[bID] == .revoked && primaryCalls.get() == 1,
              "W183 R11 第二輪（GPT-6 R11 審查 7 反例）正式的 controller［斷線］三條路都回「已撤銷」：這台本機、副設備→主設備 RPC、別台經信箱",
              "\(String(describing: outcomes))")
        check(!tools(a.service, ap.access) && !tools(p.service, pp.access) && !tools(b.service, bp.access)
              && r11RefreshRefused(a.service, ap) && r11RefreshRefused(p.service, pp) && r11RefreshRefused(b.service, bp)
              && a.service.auth.activeGrantIDs.isEmpty && p.service.auth.activeGrantIDs.isEmpty && b.service.auth.activeGrantIDs.isEmpty,
              "W183 R11 第二輪 三條路都真的撤銷了指定那台：舊的 access token 被拒、舊的 refresh token 換不到新的、那台沒有有效連線（controller 沒真的叫撤銷＝這裡會失敗）")
        check(locked(a.service, aw) && locked(p.service, pw) && locked(b.service, bw),
              "W183 R11 第二輪 三條路都跑了撤銷的收尾：那筆連線的工作區鎖成 grant_revoked（同一個收尾收掉它的工作與沙盒行程）")

        // 6. 一台失敗不擋後面的：主設備那條送不到，信箱那台照樣撤銷；逐台結果照實回。
        let pp2 = try r11Pair(p.service, host: hosts[0].1), bp2 = try r11Pair(b.service, host: hosts[2].1)
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])   // 信箱那條綁按的時候看到的那一組連線：先等畫面看到新的那一組
        primaryDown.set(true)
        let partial = await r11Disconnect(fleet, controller, [pID, bID], pump: [b, a])
        let pFailed: Bool = { if case .failed(let text)? = partial?[pID] { return text.contains("送不到主設備") }; return false }()
        check(pFailed && partial?[bID] == .revoked && tools(p.service, pp2.access) && !tools(b.service, bp2.access),
              "W183 R11 第二輪（GPT-6 R11 審查 6 反例）主設備那條送不到：照實回「沒做成」、主設備的連線照舊能用；後面那台（信箱）照樣試、真的撤銷了",
              "\(String(describing: partial))")
        // 撤銷了但沒存成（本機、信箱）＝算斷了、另外說；送出去回覆壞了＝不知道。
        let ap3 = try r11Pair(a.service, host: hosts[1].1), bp3 = try r11Pair(b.service, host: hosts[2].1)
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        a.service.auth.failSavesForTesting = true
        b.service.auth.failSavesForTesting = true
        let unsaved = await r11Disconnect(fleet, controller, [aID, bID], pump: [b, a])
        a.service.auth.failSavesForTesting = false
        b.service.auth.failSavesForTesting = false
        func isUnsaved(_ value: HandsDisconnectOutcome?) -> Bool { if case .revokedUnsaved? = value { return true }; return false }
        check(isUnsaved(unsaved?[aID]) && isUnsaved(unsaved?[bID]) && unsaved?[aID]?.cut == true && !tools(a.service, ap3.access) && !tools(b.service, bp3.access)
              && HandsBuildController.rpcFailure(RemoteHostLinkError.invalidResponse).hasPrefix(HandsBuildController.unknownMark)
              && HandsBuildController.rpcFailure(RemoteHostLinkError.remoteError("invalid: 撤銷沒能存檔（x）")).hasPrefix(HandsBuildController.unsavedMark)
              && !HandsBuildController.rpcFailure(RemoteHostLinkError.tunnelUnavailable).hasPrefix(HandsBuildController.unknownMark),
              "W183 R11 第二輪 撤銷了但沒存成（本機、信箱）＝算斷了、另外說要重新配對；回覆壞了＝不知道；連不上＝沒做成（三種分開）",
              "\(String(describing: unsaved))")

        // 流程接正式的 controller：兩台斷一台 → 卡片照實說、再按［斷線］只重試沒斷的那台。
        let pp4 = try r11Pair(p.service, host: hosts[0].1), bp4 = try r11Pair(b.service, host: hosts[2].1)
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        let requested = HandsLocked<[[String]]>([])
        let cardFlow = HandsConnectFlow(dependencies: {
            var deps = HandsConnectFlow.Dependencies(link: { (nil, "r11b") }, pod: { HandsConnectAcceptance.FakePod(window: { false }) },
                                                     presenter: { HandsConnectAcceptance.FakePresenter() }, localDeviceID: { aID }, copy: { _ in })
            deps.disconnect = { ids in
                requested.update { $0.append(ids) }
                return await HandsBuildAcceptance.r11PumpedDisconnect(fleet, controller, ids, pump: [b, a])
            }
            return deps
        }())
        primaryDown.set(true)
        cardFlow.showConnected(hosts: [pID, bID], level: 2)
        cardFlow.disconnect()
        let half = await waitUntil(20) { !cardFlow.disconnecting && cardFlow.connectedHostIDs == [pID] }
        primaryDown.set(false)
        cardFlow.disconnect()
        let whole = await waitUntil(20) { if case .disconnected? = cardFlow.card { return true }; return false }
        check(half && whole && requested.get().count == 2 && requested.get().last == [pID] && !tools(p.service, pp4.access) && !tools(b.service, bp4.access),
              "W183 R11 第二輪 私訊框的［斷線］接正式的 controller：主設備送不到＝卡片留著主設備那台、信箱那台已斷；再按只重試主設備那台，全部斷了＝「已斷線」",
              "requested=\(requested.get()) left=\(cardFlow.connectedHostIDs)")
    }

    /// 流程等 controller 的時候照樣幫信箱同步（信箱那條要 B 執行、A 收結果）。
    @MainActor static func r11PumpedDisconnect(_ fleet: Fleet, _ controller: HandsBuildController, _ ids: [String],
                                               pump: [Device]) async -> [String: HandsDisconnectOutcome] {
        await r11Disconnect(fleet, controller, ids, pump: pump) ?? [:]
    }

    // MARK: 1、5. 遷移：會先封頂的主機才升；舊版主機有連線先不升；舊版回報＝能力未確認

    @MainActor static func r11bMigrationFleet(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("r11b-migrate"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One")
        let authority = fleet.authority
        let legacy = HandsLocked(true)   // true＝C 的回報像 R10 的主機（沒有 level_guard、沒有連線等級）
        func legacyCall(_ id: String) -> ([String: Any]) throws -> [String: Any] {
            { payload in
                var sent = try Fleet.wire(payload)
                if legacy.get(), var report = sent["report"] as? [String: Any] {
                    report["grant_levels"] = nil
                    report["grant_level"] = nil
                    report["level_guard"] = nil
                    sent["report"] = report
                }
                return try Fleet.wire(try HandsBuildRemote.handle(payload: sent, sender: id, authority: authority))
            }
        }
        var b = try fleet.add(bID, name: "Studio B")
        var c = try fleet.add(cID, name: "Desk C", callPrimary: legacyCall(cID))
        let bHost = "os-for-chatgpt-studiob.example.com", cHost = "os-for-chatgpt-deskc.example.com"
        _ = try fleet.update([.select(device: bID, selected: true), .select(device: cID, selected: true), .setEnabled(true),
                              .zone(accountID: accountID, zoneID: zoneID, domain: domain), .level(device: bID, level: 2), .level(device: cID, level: 2)])
        for (device, host) in [(b, bHost), (c, cHost)] {
            _ = try device.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = device.id }
            device.phase.set(.running(url: "https://\(host)/mcp"))
        }
        fleet.syncAll(); fleet.syncAll()
        let bOld = try r11Pair(b.service, host: bHost), cOld = try r11Pair(c.service, host: cHost)
        let widened = r11ToolLevel(b.service, bOld.access) == 2 && r11ToolLevel(c.service, cOld.access) == 2
        // R10 的收窄：中央 B、C 降成 L1——R10 的主機只把本機設定寫成 1，grant 紀錄還是 L2（這裡關掉這兩台的中央上限＝不封頂，做出 R10 的樣子）。
        let bCap = b.service.scopeCap, cCap = c.service.scopeCap
        b.service.scopeCap = nil
        c.service.scopeCap = nil
        _ = try fleet.update([.level(device: bID, level: 1), .level(device: cID, level: 1)])
        fleet.syncAll([bID, cID])
        func recorded(_ service: HandsService, _ paired: R11Paired) -> Int? { service.auth.grantRecord(paired.grant)?.level }
        let r10 = recorded(b.service, bOld) == 2 && recorded(c.service, cOld) == 2 && b.service.settings.load().level == 1
            && c.service.settings.load().level == 1
        b.service.scopeCap = bCap
        c.service.scopeCap = cCap
        // 更新成 R11：重開 App（新的 HandsService、同一份檔案；R10 沒有封頂檔）。
        for device in [b, c] { try? FileManager.default.removeItem(at: device.service.levelWatermarkURL) }
        let freshB = HandsService(paths: b.paths), freshC = HandsService(paths: c.paths)
        b = try fleet.add(bID, name: "Studio B", service: freshB)
        c = try fleet.add(cID, name: "Desk C", service: freshC, callPrimary: legacyCall(cID))
        b.phase.set(.running(url: "https://\(bHost)/mcp"))
        c.phase.set(.running(url: "https://\(cHost)/mcp"))
        // 主設備也更新成 R11：這一份（沒有 level_default）第一次讀＝照一次遷移（還是 L1 的記成待升）。
        guard var old = fleet.store.load() else { return check(false, "W183 R11 第二輪 遷移：主設備讀不到設定") }
        old.levelDefault = nil
        old.levelDefaultPending = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try HandsFiles.writeAtomically(try encoder.encode(old), to: fleet.store.url)
        fleet.store.reloadForTesting()
        let migrated = fleet.store.load()
        let pendingBoth = Set(migrated?.levelDefaultPending ?? []) == [bID, cID] && migrated?.entry(bID)?.level == 1 && migrated?.entry(cID)?.level == 1
        fleet.syncAll(); fleet.syncAll(); fleet.syncAll()
        let config = fleet.store.load()
        let bTools = r11ToolNames(b.service, bOld.access)
        check(widened && r10 && pendingBoth && config?.entry(bID)?.level == 2 && config?.levelDefaultPending == [cID]
              && r11ToolLevel(b.service, bOld.access) == 1 && !bTools.contains("open_workspace") && recorded(b.service, bOld) == 1
              && b.service.settings.load().level == 2,
              "W183 R11 第二輪（GPT-6 R11 審查 1 反例）L2 grant → 中央 L1 → 主設備遷移：會先封頂的主機（B）升到 L2，但 B 舊的 token 照舊 L1（沒按［連線］、沒看確認卡就不會拿回 Codex）",
              "widened=\(widened) r10=\(r10) pending=\(String(describing: migrated?.levelDefaultPending)) b=\(String(describing: config?.entry(bID)?.level)) old=\(String(describing: r11ToolLevel(b.service, bOld.access)))")
        let bNew = try r11Pair(b.service, host: bHost)
        check(r11ToolLevel(b.service, bNew.access) == 2 && r11ToolNames(b.service, bNew.access).contains("open_workspace"),
              "W183 R11 第二輪 遷移之後在 B 新的連線（看過確認卡）＝L2：預設只給下一次明確核准的")
        fleet.syncAll()   // B 的回報跟上新的那一條
        // 舊版主機（C 的回報沒有 level_guard、有連線）：先不升——它收到 L2 會讓收窄過的舊 L2 grant 恢復。
        let controller = reviewController(fleet, p)
        _ = await waitUntil(5) { controller.view.report(cID) != nil && controller.view.report(bID)?.grantLevel == 2 }
        check(config?.entry(cID)?.level == 1 && r11ToolLevel(c.service, cOld.access) == 1 && controller.view.report(cID)?.levelGuard == false,
              "W183 R11 第二輪 舊版主機（回報沒有 level_guard）有連線：主設備先不升（還是 L1、留在待升清單），等它更新")
        // 5. 舊版回報沒有連線等級：controller 的「ChatGPT 實際拿到的」＝不知道（不拿中央上限推定）；判定＝已連線・能力未確認。
        let evidence = controller.connectEvidence(cID)
        let tag = HandsConnectAccounts.identityTag(HandsConnectAcceptance.identity)
        let young = HandsConnectAccountRecord(host: cID, identityTag: tag, grantTag: nil, level: 2, at: fleet.clock.now(for: pID),
                                              uptime: fleet.clock.uptime())
        check(controller.connectedLevel(cID) == nil && controller.actualLevel(cID) == 1 && evidence?.grantLevels == nil
              && HandsConnectVerdict.of(host: cID, evidence: evidence, identityTag: tag, records: [young], now: fleet.clock.now(for: pID),
                                        uptime: fleet.clock.uptime()) == .connected(level: nil)
              && controller.connectedLevel(bID) == 2,
              "W183 R11 第二輪（GPT-6 R11 審查 5 反例）混合版本：舊版主機的回報沒有連線等級＝能力未確認（connectedLevel nil、入口寫「已連線・能力未確認」），不推定 Codex",
              "level=\(String(describing: controller.connectedLevel(cID))) actual=\(String(describing: controller.actualLevel(cID)))")
        // C 更新成 R11（回報有 level_guard）：這時才升；C 舊的 token 照舊 L1（它的主機先封頂）。
        legacy.set(false)
        fleet.syncAll(); fleet.syncAll(); fleet.syncAll()
        let after = fleet.store.load()
        check(after?.entry(cID)?.level == 2 && after?.levelDefaultPending == nil && r11ToolLevel(c.service, cOld.access) == 1
              && c.service.auth.grantRecord(cOld.grant)?.level == 1,
              "W183 R11 第二輪 舊版主機更新之後（回報會先封頂）：主設備才升到 L2；它舊的 token 照舊 L1",
              "c=\(String(describing: after?.entry(cID)?.level)) old=\(String(describing: r11ToolLevel(c.service, cOld.access)))")
    }

    // MARK: 1（R11b）. 面板調高跟預設升級同一道檢查

    @MainActor static func r11bPanelRaise(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("r11b-panel"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One")
        let authority = fleet.authority
        let legacy = HandsLocked(true)   // C 的回報像舊版主機（沒有 level_guard、沒有連線等級）
        let c = try fleet.add(cID, name: "Desk C", callPrimary: { payload in
            var sent = try Fleet.wire(payload)
            if legacy.get(), var report = sent["report"] as? [String: Any] {
                report["grant_levels"] = nil
                report["grant_level"] = nil
                report["level_guard"] = nil
                sent["report"] = report
            }
            return try Fleet.wire(try HandsBuildRemote.handle(payload: sent, sender: HandsBuildAcceptance.cID, authority: authority))
        })
        let b = try fleet.add(bID, name: "Studio B")
        let cHost = "os-for-chatgpt-deskc.example.com", bHost = "os-for-chatgpt-studiob.example.com"
        _ = try fleet.update([.select(device: bID, selected: true), .select(device: cID, selected: true), .setEnabled(true),
                              .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        for (device, host) in [(b, bHost), (c, cHost)] {
            _ = try device.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = device.id }
            device.phase.set(.running(url: "https://\(host)/mcp"))
        }
        fleet.syncAll(); fleet.syncAll()
        let cOld = try r11Pair(c.service, host: cHost), bOld = try r11Pair(b.service, host: bHost)
        _ = try fleet.update([.level(device: cID, level: 1), .level(device: bID, level: 1)])   // 中央收窄成 L1
        fleet.syncAll(); fleet.syncAll()
        // 舊版主機（C）有連線：面板直接把 C 調回 L2＝不發布（它收到 L2，收窄過的舊 grant 就恢復了）。
        var refused: HandsBuildConfigError?
        do { _ = try fleet.update([.level(device: cID, level: 2)]) } catch { refused = HandsBuildConfigError.from(error) }
        check(refused == .raiseNeedsUpdate("Desk C") && fleet.store.load()?.entry(cID)?.level == 1 && r11ToolLevel(c.service, cOld.access) == 1,
              "W183 R11 第二輪（GPT-6 R11b 審查 1 反例）L2 grant → 中央 L1 → 面板調回 L2：舊版主機（回報沒有 level_guard）有連線＝主設備不發布較高的等級（照舊 L1）",
              "refused=\(String(describing: refused)) c=\(String(describing: fleet.store.load()?.entry(cID)?.level))")
        // 面板那一條（ChatGPT build 的等級，勾的每台一起）：同一道檢查、畫面一句短話；整次不收（B 也沒變）。
        let panel = reviewController(fleet, p)
        _ = await waitUntil(5) { panel.config?.configRevision == fleet.store.load()?.configRevision }
        panel.setLevel(2)
        let said = await waitUntil(5) { panel.actionProblem == HandsBuildConfigError.raiseNeedsUpdate("Desk C").plain }
        check(said && fleet.store.load()?.entry(cID)?.level == 1 && fleet.store.load()?.entry(bID)?.level == 1,
              "W183 R11 第二輪 面板上調高：一句「Desk C：先更新 TATWO OS 才能調高」（W183 R11 最後一輪：舊版斷線再連也不行了，不寫那條路），這次改動整個不收",
              "problem=\(String(describing: panel.actionProblem))")
        // R11 起的主機（B，回報說會先封頂）：面板調高照發布——但舊的連線照舊 L1（面板調高不是對既有連線的重新同意），新的連線才 L2。
        _ = try fleet.update([.level(device: bID, level: 2)])
        fleet.syncAll(); fleet.syncAll()
        let bNew = try r11Pair(b.service, host: bHost)
        check(fleet.store.load()?.entry(bID)?.level == 2 && r11ToolLevel(b.service, bOld.access) == 1 && r11ToolLevel(b.service, bNew.access) == 2,
              "W183 R11 第二輪 會先封頂的主機（B）：面板調高照發布，但舊的 token 照舊 L1（不是重新同意）；新的連線才 L2",
              "old=\(String(describing: r11ToolLevel(b.service, bOld.access))) new=\(String(describing: r11ToolLevel(b.service, bNew.access)))")
        // W183 R11 最後一輪（GPT-6 R11c 審查 1 反例：過舊的「零 grant」回報放行舊主機調高）：舊版主機（C）的「沒有連線」也不放行——
        // C 先斷線（撤銷全部）、回報跟上＝零連線：面板調回 L2＝照樣不發布（原本這裡會放行）；之後 C 又連上一筆、不再回報，
        // 那份零連線的回報也舊了：照樣不發布（原本整次放行，C 收到 L2＝新的那一筆、之後的連線都拿 L2，舊主機不會先封頂）。
        _ = c.service.revokeEverything()
        fleet.syncAll()
        let zeroReported = fleet.authority.report(for: cID)?.grants == 0 && fleet.authority.report(for: cID)?.levelGuard == false
        var afterCut: HandsBuildConfigError?
        do { _ = try fleet.update([.level(device: cID, level: 2)]) } catch { afterCut = HandsBuildConfigError.from(error) }
        let cAgain = try r11Pair(c.service, host: cHost)   // C 又連上一筆（L1），之後不再回報
        fleet.clock.advance(HandsBuildConfig.raiseReportWindow + 30)
        var staleZero: HandsBuildConfigError?
        do { _ = try fleet.update([.level(device: cID, level: 2)]) } catch { staleZero = HandsBuildConfigError.from(error) }
        check(zeroReported && afterCut == .raiseNeedsUpdate("Desk C") && staleZero == .raiseNeedsUpdate("Desk C")
              && fleet.store.load()?.entry(cID)?.level == 1 && r11ToolLevel(c.service, cAgain.access) == 1,
              "W183 R11 最後一輪（GPT-6 R11c 審查 1 反例）舊版主機回報「沒有連線」（剛收到的、之後又連上一筆而變舊的）：面板調回 L2＝照樣不發布、請它先更新",
              "zero=\(zeroReported) afterCut=\(String(describing: afterCut)) stale=\(String(describing: staleZero))")
        // 還沒回報的那台（A：設定裡有、從沒同步過）：調高＝等它回報。
        _ = try fleet.update([.level(device: aID, level: 1)])
        var unknown: HandsBuildConfigError?
        do { _ = try fleet.update([.level(device: aID, level: 2)]) } catch { unknown = HandsBuildConfigError.from(error) }
        check(unknown == .raiseUnknown("Laptop A") && fleet.store.load()?.entry(aID)?.level == 1,
              "W183 R11 第二輪 還沒回報的那台（A）＝先不調高（等它回報）", "unknown=\(String(describing: unknown))")
        // W183 R11 最後一輪（GPT-6 R11c 審查 1）：會先封頂的主機（B）也要回報夠新、已經套用到現在這一版才調高——
        // 剛收窄、B 還沒同步（還沒套用、沒封頂）＝先等；B 套用了、回報跟上＝可以；回報又舊了（B 停了）＝先等；新的回報＝可以。
        fleet.syncAll([bID])
        _ = try fleet.update([.level(device: bID, level: 1)])
        var behind: HandsBuildConfigError?
        do { _ = try fleet.update([.level(device: bID, level: 2)]) } catch { behind = HandsBuildConfigError.from(error) }
        fleet.syncAll([bID]); fleet.syncAll([bID])
        fleet.clock.advance(HandsBuildConfig.raiseReportWindow + 5)
        var staleGuarded: HandsBuildConfigError?
        do { _ = try fleet.update([.level(device: bID, level: 2)]) } catch { staleGuarded = HandsBuildConfigError.from(error) }
        fleet.syncAll([bID])
        var freshGuarded: HandsBuildConfigError?
        do { _ = try fleet.update([.level(device: bID, level: 2)]) } catch { freshGuarded = HandsBuildConfigError.from(error) }
        check(behind == .raiseUnknown("Studio B") && staleGuarded == .raiseUnknown("Studio B") && freshGuarded == nil
              && fleet.store.load()?.entry(bID)?.level == 2,
              "W183 R11 最後一輪（GPT-6 R11c 審查 1）會先封頂的主機：還沒套用剛收窄的這一版、或回報太舊＝先不調高（等它回報）；套用了、回報新＝照發布",
              "behind=\(String(describing: behind)) stale=\(String(describing: staleGuarded)) fresh=\(String(describing: freshGuarded))")
        fleet.clock.reset()
    }

    // MARK: 3、4. 入口對著真的回報

    @MainActor static func r11bEntryFleet(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("r11b-entry"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One"), b = try fleet.add(bID, name: "Studio B")
        let host = "os-for-chatgpt-studiob.example.com"
        try fixtureAccount(b)   // B 有那個網域的 Cloudflare 授權（網址那一段做好了：入口是「連線」不是「到設定」）
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        _ = try b.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = bID }
        b.phase.set(.running(url: "https://\(host)/mcp"))
        fleet.syncAll(); fleet.syncAll()
        let first = try r11Pair(b.service, host: host)   // 帳號 A 的那一條
        let firstVersion = b.service.auth.stateVersion   // W183 R11 最後一輪：主機確認這一條那一刻的授權狀態版本（正式的從連線結果拿）
        fleet.syncAll()
        let flow = r11InertFlow(owner: pID)
        let controller = reviewController(fleet, p, flow: flow)
        _ = await r11CaughtUp(controller, [b])
        let accountsURL = base.appendingPathComponent("r11b-entry-accounts.json")
        let accounts = HandsConnectAccounts(url: accountsURL)
        let identityA = "u=user-a|w=|e=mail-a", identityB = "u=user-b|w=|e=mail-b"
        let tagA = HandsConnectAccounts.identityTag(identityA), tagB = HandsConnectAccounts.identityTag(identityB)
        let identity = HandsLocked<String?>(identityA)
        let hold = HandsLocked(false)   // true＝身分查詢卡在路上（查的是發出那一刻的帳號，晚一點才回）
        let pod = CurrentValueSubject<TapConnection, Never>(.ready)
        let login = HandsPodLogin(state: pod.eraseToAnyPublisher())   // W183 R11 最後一輪：入口與連線流程共用的登入世代
        accounts.remember(HandsConnectAccountRecord(host: bID, identityTag: tagA, grantTag: HandsBuildDeviceReport.grantTag(first.grant), level: 2,
                                                    at: fleet.clock.now(for: pID).addingTimeInterval(-300), uptime: fleet.clock.uptime() - 300,
                                                    grantVersion: firstVersion))
        let entry = HandsConnectEntry(build: { controller }, flow: flow, now: { fleet.clock.now(for: pID) }, uptime: { fleet.clock.uptime() },
                                      openSetup: {}, accounts: accounts,
                                      probeIdentity: {
                                          let asked = identity.get()
                                          while hold.get() { try? await Task.sleep(nanoseconds: 20_000_000) }
                                          return asked
                                      },
                                      login: login)
        let probed = await waitUntil(5) { entry.identityTag == tagA }
        entry.refresh()
        check(probed && entry.state == .connected(hosts: [bID], level: 2) && HandsConnectEntry.published.get().capability == "confirmed",
              "W183 R11 第二輪 入口：Pod 是帳號 A、B 的回報裡有 A 的那一條＝「已連線・Codex、記憶」（核對過的）", "\(entry.state)")

        // 4. Pod 換成帳號 B（登出再登入）：主機上只有 A 的連線＝給［連線］；「主機有授權」另外照實報；給 AI 的沒有帳號、沒有代號。
        pod.send(.needsLogin)
        let cleared = await waitUntil(3) { entry.identityTag == nil }
        identity.set(identityB)
        pod.send(.ready)
        let switched = await waitUntil(5) { entry.identityTag == tagB }
        entry.refresh()
        let status = HandsConnectEntry.aiStatus()
        let statusText = text(status)
        check(cleared && switched && entry.state == .connect && status["state"] as? String == "not_connected" && status["host_authorized"] as? Bool == true
              && !statusText.contains("user-a") && !statusText.contains("user-b") && !statusText.contains("mail-") && !statusText.contains("g_"),
              "W183 R11 第二輪（GPT-6 R11 審查 4 反例）主機上是帳號 A 的連線、Pod 換成 B：入口＝「連線」（不說 B 已連線）；hands_setup_status 分開報「主機有授權」，沒有帳號、沒有連線代號",
              "\(entry.state) \(statusText)")
        // 按下去：照樣排那台（那台有 A 的連線也照連；舊的「勾的每台逐台排」會把它當已連線跳過）。
        entry.tap()
        let queued = await waitUntil(5) { controller.failedConnect == bID || controller.connecting == bID }
        check(queued, "W183 R11 第二輪 帳號 B 按「連線」：那台照樣排進［連線］（這個自測的流程沒接主機，所以停在出錯：看得到它排的是 B 那台）",
              "failed=\(String(describing: controller.failedConnect)) connecting=\(String(describing: controller.connecting))")
        flow.cancel(reason: "test_done")

        // 3. 回到帳號 A、已連線卡開著；那一條在別處撤銷了（新的回報沒有它）：入口回到「連線」、已連線卡跟著改成「已斷線」。
        pod.send(.needsLogin)
        identity.set(identityA)
        pod.send(.ready)
        _ = await waitUntil(5) { entry.identityTag == tagA }
        entry.refresh()
        flow.showConnected(hosts: [bID], level: 2)
        _ = b.service.revokeEverything()
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        entry.refresh()
        let endedCard: Bool = { if case .disconnected(let text)? = flow.card { return text == HandsConnectFlow.endedElsewhereText }; return false }()
        check(entry.state == .connect && endedCard && !HandsConnectEntry.published.get().hostAuthorized,
              "W183 R11 第二輪（GPT-6 R11 審查 3 反例）在別處撤銷：新的回報沒有這一條＝入口回到「連線」、已連線卡跟著改成「已斷線：這條連線在別處撤銷了」",
              "\(entry.state) card=\(String(describing: flow.card))")
        flow.dismiss()

        // 3. 剛連上（回報還沒跟上）＝樂觀算連著；過了期限沒有新的回報＝不再算；新的回報有它＝核對過的連著。
        let second = try r11Pair(b.service, host: host)
        accounts.remember(HandsConnectAccountRecord(host: bID, identityTag: tagA, grantTag: HandsBuildDeviceReport.grantTag(second.grant), level: 2,
                                                    at: fleet.clock.now(for: pID), uptime: fleet.clock.uptime(),
                                                    grantVersion: b.service.auth.stateVersion))
        entry.refresh()
        let optimistic = entry.state == .connected(hosts: [bID], level: 2)
        flow.showConnected(hosts: [bID], level: 2)   // 連上那一刻的已連線卡
        fleet.clock.advance(HandsConnectVerdict.optimism + 10)
        entry.refresh()
        let expired: Bool = { if case .connected = entry.state { return false }; return true }()   // 回報也舊了：入口可能是「到設定」，重點是不再算連著
        // W183 R11 第二輪（GPT-6 R11b 審查 4 反例）：膠囊、卡片、給 AI 的狀態三個一起看——都不再宣稱已連線、不寫能力。
        let unsureCard: Bool = { if case .unconfirmed(let text)? = flow.card { return text == HandsConnectFlow.unconfirmedStatusText }; return false }()
        let expiredStatus = HandsConnectEntry.aiStatus()
        let aiQuiet = expiredStatus["state"] as? String != "connected" && (expiredStatus["abilities"] as? [String] ?? ["?"]).isEmpty
            && expiredStatus["capability"] == nil && expiredStatus["level"] == nil
        check(optimistic && expired && unsureCard && aiQuiet,
              "W183 R11 第二輪（GPT-6 R11b 審查 4 反例）剛連上的期限過了、沒有新的回報：膠囊不算連著、已連線卡改成「連線狀態未確認」（不寫 Codex、記憶）、hands_setup_status 也不說已連線、不給能力",
              "state=\(entry.state) card=\(String(describing: flow.card)) ai=\(text(expiredStatus))")
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        entry.refresh()
        let verified = entry.state == .connected(hosts: [bID], level: 2)
        let backCard: Bool = { if case .connected(let text)? = flow.card { return text == HandsConnectFlow.connectedText(level: 2) }; return false }()
        check(optimistic && expired && verified && backCard,
              "W183 R11 第二輪（GPT-6 R11 審查 3）剛連上只樂觀到期限：回報還沒跟上＝算連著；過了期限、沒有新的回報＝不算；新的回報有這一條＝連著（卡片也回到已連線）",
              "optimistic=\(optimistic) expired=\(expired) verified=\(verified) card=\(String(describing: flow.card))")

        // 3. 那台停了（新的回報：關口沒在跑）＝優先：入口「連線」、已連線卡改成「連不上」。
        flow.showConnected(hosts: [bID], level: 2)
        b.phase.set(.stopped)
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        entry.refresh()
        let stoppedCard: Bool = { if case .disconnected(let text)? = flow.card { return text == HandsConnectFlow.hostStoppedText }; return false }()
        check(entry.state == .connect && stoppedCard,
              "W183 R11 第二輪 那台停了（回報新、關口沒在跑）：馬上不算連著（不等期限），已連線卡改成「連不上：那台主機停了或暫停」",
              "\(entry.state) card=\(String(describing: flow.card))")
        // W183 R11 最後一輪（GPT-6 R11c 審查 4 反例：誤判後卡片恢復）：那台又跑起來、新的回報裡還有這一條＝「連不上」卡回到已連線、入口也是。
        b.phase.set(.running(url: "https://\(host)/mcp"))
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        entry.refresh()
        let recovered: Bool = { if case .connected(let text)? = flow.card { return text == HandsConnectFlow.connectedText(level: 2) }; return false }()
        check(recovered && entry.state == .connected(hosts: [bID], level: 2) && flow.connectedHostIDs == [bID],
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）「連不上／已斷線」是推斷的：之後新的回報證明還連著＝卡片回到「已連線：Codex、記憶」、入口也回到已連線",
              "\(entry.state) card=\(String(describing: flow.card))")
        flow.dismiss()

        // GPT-6 R11b 審查 3 反例：身分查詢綁 Pod 這一次登入——查詢還在路上時登出，晚到的 A 不採用；之後 B 登入的查詢不被舊的擋住。
        hold.set(true)
        pod.send(.needsLogin)
        identity.set(identityA)
        pod.send(.ready)                                   // A 的查詢發出去了（卡在路上）
        try? await Task.sleep(nanoseconds: 150_000_000)
        pod.send(.needsLogin)                              // 查詢還在路上時登出
        hold.set(false)                                    // A 的查詢這時才回來
        try? await Task.sleep(nanoseconds: 300_000_000)
        let lateIgnored = entry.identityTag == nil
        hold.set(true)
        pod.send(.ready)                                   // 又登入（還是 A）：新的一代、新的查詢（卡著）
        try? await Task.sleep(nanoseconds: 150_000_000)
        pod.send(.needsLogin)                              // 又登出
        identity.set(identityB)
        pod.send(.ready)                                   // B 登入：B 的查詢不被 A 那個還在路上的擋住
        try? await Task.sleep(nanoseconds: 150_000_000)
        hold.set(false)                                    // 兩個都回來（A 的晚到）
        let tookB = await waitUntil(3) { entry.identityTag == tagB }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(lateIgnored && tookB && entry.identityTag == tagB,
              "W183 R11 第二輪（GPT-6 R11b 審查 3 反例）登出之後晚到的查詢（A）不採用（還是核對不了）；B 登入之後的查詢照常、不被 A 那個擋住，也不被晚到的 A 蓋掉",
              "late=\(lateIgnored) tookB=\(tookB) tag=\(String(describing: entry.identityTag))")

        // W183 R11 最後一輪（GPT-6 R11c 審查 3 反例）：連線流程的 loadOffer 在等 A 的帳號身分（晚到）→ 登出 → B 登入、入口查到 B → A 才回來。
        // 流程發布的帳號帶著讀之前的登入世代：入口不收別一代的（只當成「請重新查一次」），目前帳號還是 B。
        pod.send(.needsLogin)
        identity.set(identityA)
        pod.send(.ready)
        _ = await waitUntil(5) { entry.identityTag == tagA }
        let world = try HandsConnectAcceptance.World(base, "r11c-late-flow", loginGeneration: { login.generation })
        world.pod.identityValue = identityA
        world.pod.identityDelay = 700_000_000
        world.pod.identityAtCall = true                    // 回的是發出那一刻的帳號（晚到的舊結果）
        let lateEntry = HandsConnectEntry(build: { controller }, flow: world.flow, now: { fleet.clock.now(for: pID) }, uptime: { fleet.clock.uptime() },
                                          openSetup: {}, accounts: accounts, probeIdentity: { identity.get() }, login: login)
        _ = await waitUntil(5) { lateEntry.identityTag == tagA }
        let generationA = login.generation
        world.flow.offer()                                 // loadOffer：讀 A 的帳號身分（卡在路上）
        let asked = await waitUntil(5) { world.pod.identityReads > 0 }
        pod.send(.needsLogin)                              // A 登出
        identity.set(identityB)
        world.pod.identityValue = identityB
        pod.send(.ready)                                   // B 登入：入口查到 B
        let sawB = await waitUntil(5) { lateEntry.identityTag == tagB }
        let lateArrived = await waitUntil(5) { world.flow.podIdentity?.tag == tagA && world.flow.podIdentity?.generation == generationA }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(asked && sawB && lateArrived && login.generation != generationA && lateEntry.identityTag == tagB && entry.identityTag == tagB,
              "W183 R11 最後一輪（GPT-6 R11c 審查 3 反例）流程的 loadOffer 晚到的 A（讀的時候是上一次登入）不蓋掉 B：入口只收現在這一代的，別一代的只觸發重新查",
              "asked=\(asked) sawB=\(sawB) late=\(lateArrived) tag=\(String(describing: lateEntry.identityTag))")
        world.flow.cancel(reason: "test_done")
        fleet.clock.reset()
        try? FileManager.default.removeItem(at: accountsURL)
    }

    // MARK: 4（R11c）. 時間因果：雙邊各自跳鐘（真的回報、真的全貌）

    /// 等 A 這台的全貌換成新的一份（時間那一對變了）。
    @MainActor static func r11cNextView(_ controller: HandsBuildController, after previous: Date?) async -> Bool {
        await waitUntil(5) { controller.view.localTime != nil && controller.view.localTime != previous }
    }

    @MainActor static func r11cClockJumps(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("r11c-clock"), keys: keys)
        _ = try fleet.add(pID, name: "Primary One")
        let a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B")
        let host = "os-for-chatgpt-studiob.example.com"
        try fixtureAccount(b)
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        _ = try b.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = bID }
        b.phase.set(.running(url: "https://\(host)/mcp"))
        fleet.syncAll(); fleet.syncAll()
        let controller = reviewController(fleet, a)   // 按［連線］的是 A（副設備：全貌從主設備來）
        let tag = HandsConnectAccounts.identityTag("u=user-a|w=|e=mail-a")
        func record(_ paired: R11Paired) -> HandsConnectAccountRecord {
            HandsConnectAccountRecord(host: bID, identityTag: tag, grantTag: HandsBuildDeviceReport.grantTag(paired.grant), level: 2,
                                      at: fleet.clock.now(for: aID), uptime: fleet.clock.uptime(), grantVersion: b.service.auth.stateVersion)
        }
        func verdict(_ records: [HandsConnectAccountRecord]) -> HandsConnectVerdict {
            HandsConnectVerdict.of(host: bID, evidence: controller.connectEvidence(bID), identityTag: tag, records: records,
                                   now: fleet.clock.now(for: aID), uptime: fleet.clock.uptime())
        }
        let first = try r11Pair(b.service, host: host)
        let r1 = record(first)
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        let baseline = verdict([r1]) == .connected(level: 2) && controller.connectEvidence(bID)?.clockSuspect == false
        // 在別處撤銷（B 的新回報沒有這一條、版本比連線確認新）＝撤銷了。
        _ = b.service.revokeEverything()
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        let revokedSeen = verdict([r1]) == .ended(.revoked)
        // A 的牆上時鐘倒退 120 秒（拿到這份全貌之後）：這一份新不新鮮算不準＝「未確認」（不說連著、也不說撤銷）。
        fleet.clock.jumpWall(-120, device: aID)
        let suspectLocal = controller.connectEvidence(bID)?.clockSuspect == true && verdict([r1]) == .open
        // A 再同步（換成跳之後的一對時間）：連線紀錄在 A 的「未來」，照樣照版本判撤銷（原本會把這份回報算成連線之前、又把負的時間差當剛連上＝已連線）。
        let beforeLocal = controller.view.localTime
        fleet.syncAll([aID])
        let republished = await r11cNextView(controller, after: beforeLocal)
        let afterLocal = verdict([r1])
        check(baseline && revokedSeen && suspectLocal && republished && afterLocal == .ended(.revoked)
              && controller.connectEvidence(bID)?.clockSuspect == false,
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）按［連線］那台的鐘倒退：拿到全貌之後跳＝「未確認」；換成跳之後的全貌＝照主機的授權狀態版本判撤銷（不會變成已連線）",
              "baseline=\(baseline) revoked=\(revokedSeen) suspect=\(suspectLocal) republished=\(republished) after=\(afterLocal)")

        // 主設備的鐘倒退 600 秒：跳的那一份（主設備時間走的跟 A 的單調時鐘差太多）＝「未確認」，連這一條還在也不說已連線；下一份正常＝回到已連線。
        let second = try r11Pair(b.service, host: host)
        let r2 = record(second)
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        let secondSeen = verdict([r2]) == .connected(level: 2)
        fleet.clock.jumpWall(-600, device: pID)
        fleet.syncAll()
        let flagged = await waitUntil(5) { controller.view.serverClockJumped }
        let suspectServer = verdict([r2]) == .open && controller.connectEvidence(bID)?.clockSuspect == true
        fleet.syncAll()
        let cleared = await waitUntil(5) { !controller.view.serverClockJumped }
        let backAgain = verdict([r2]) == .connected(level: 2)
        check(secondSeen && flagged && suspectServer && cleared && backAgain,
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）主設備的鐘倒退：跳的那一份＝「未確認」（這一條還在也不說已連線、也不說斷了）；下一份正常＝回到已連線",
              "second=\(secondSeen) flagged=\(flagged) suspect=\(suspectServer) cleared=\(cleared) back=\(backAgain)")

        // 主設備的鐘又倒退、B 這段期間沒有再回報：B 那份的收件時間比主設備現在還晚（負的年齡）＝新不新鮮算不準＝「未確認」（原本當成新的）。
        fleet.clock.jumpWall(-600, device: pID)
        fleet.syncAll([pID, aID])
        _ = await waitUntil(5) { controller.view.serverClockJumped }
        fleet.syncAll([pID, aID])
        let settled = await waitUntil(5) { !controller.view.serverClockJumped }
        let negative = controller.connectEvidence(bID)?.clockSuspect == true && verdict([r2]) == .open
        check(settled && negative,
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）主設備的鐘倒退、那台沒再回報：那份回報的收件時間在主設備的「未來」＝「未確認」（不把負的年齡當成新的）",
              "settled=\(settled) evidence=\(String(describing: controller.connectEvidence(bID)))")
        fleet.clock.reset()
    }

    // MARK: 4（R11c）. 延遲快照：連上之前取樣、連上之後才送到的回報

    @MainActor static func r11cDelayedSnapshot(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("r11c-delayed"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One")
        let authority = fleet.authority
        let holding = HandsLocked(false)
        let stash = HandsLocked<[String: Any]?>(nil)
        let b = try fleet.add(bID, name: "Studio B", callPrimary: { payload in
            // true＝這一次同步的請求送出去了、還在路上（先攔下來，晚一點才送到主設備）。
            if holding.get() { stash.set(try Fleet.wire(payload)); throw RemoteHostLinkError.tunnelUnavailable }
            return try Fleet.wire(try HandsBuildRemote.handle(payload: try Fleet.wire(payload), sender: HandsBuildAcceptance.bID, authority: authority))
        })
        let host = "os-for-chatgpt-studiob.example.com"
        try fixtureAccount(b)
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        _ = try b.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = bID }
        b.phase.set(.running(url: "https://\(host)/mcp"))
        fleet.syncAll(); fleet.syncAll()
        let controller = reviewController(fleet, p)
        _ = await r11CaughtUp(controller, [b])
        let tag = HandsConnectAccounts.identityTag("u=user-a|w=|e=mail-a")
        holding.set(true)
        b.sync.syncNow()                                   // B 取樣（還沒有新的連線）：這份回報卡在路上
        holding.set(false)
        let sampled = b.service.auth.stateVersion
        let paired = try r11Pair(b.service, host: host)    // 使用者這時連上
        let confirmed = b.service.auth.stateVersion
        let record = HandsConnectAccountRecord(host: bID, identityTag: tag, grantTag: HandsBuildDeviceReport.grantTag(paired.grant), level: 2,
                                               at: fleet.clock.now(for: pID), uptime: fleet.clock.uptime(), grantVersion: confirmed)
        func verdict() -> HandsConnectVerdict {
            HandsConnectVerdict.of(host: bID, evidence: controller.connectEvidence(bID), identityTag: tag, records: [record],
                                   now: fleet.clock.now(for: pID), uptime: fleet.clock.uptime())
        }
        fleet.clock.advance(25)                            // 25 秒之後，卡在路上的舊快照才送到主設備（簽章、序號都對）
        let deliveredAt = fleet.clock.now(for: pID)
        guard let late = stash.get() else { return check(false, "W183 R11 最後一輪 延遲快照：沒攔到那一次同步") }
        _ = try HandsBuildRemote.handle(payload: late, sender: bID, authority: authority)
        fleet.syncAll([pID])
        let arrived = await waitUntil(5) {
            guard let report = controller.view.report(bID), let at = report.receivedAt else { return false }
            return at >= deliveredAt.addingTimeInterval(-2) && report.grantsVersion == sampled
        }
        let lateVerdict = verdict()
        check(arrived && sampled < confirmed && lateVerdict == .connected(level: 2),
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）延遲快照：連上之前取樣（沒有這一條）、連上 25 秒之後才送到的回報＝不算撤銷（看取樣的版本，不看收件時間；剛連上的那一段照樣算連著）",
              "arrived=\(arrived) sampled=\(sampled) confirmed=\(confirmed) verdict=\(lateVerdict)")
        fleet.syncAll()
        _ = await r11CaughtUp(controller, [b])
        check(verdict() == .connected(level: 2), "W183 R11 最後一輪 之後照常的回報（有這一條）＝核對過的已連線")
        fleet.clock.reset()
    }
}
#endif
