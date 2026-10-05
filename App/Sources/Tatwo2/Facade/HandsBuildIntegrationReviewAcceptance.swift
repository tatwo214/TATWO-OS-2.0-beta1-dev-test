#if DEBUG
import Foundation

/// `TATWO2_SELFTEST=w183build` 的第四部分：W183 R8 整合審查（GPT-6 跨引擎＋Claude）指出的邊界——每一項都是行為驗收
/// （真的控制器、信箱、執行者、HandsSetup、HandsService、HandsConnectFlow；假的 cloudflared 記下每一個指令），不是原始碼形狀。
/// - 「套用」：按下去之後、背景送出之前設定換了版本＝不送（不自己換版本）；存好子網域、那台一直沒回報拿到那一版＝到期不送、出錯；
///   取消勾那台＝那台的出錯收掉。
/// - 解除安全鎖（這台）：綁按的時候看到的事故編號、setupEpoch——晚到的清不掉新事故、世代換了不解除；對上了才解除。
/// - 關掉的那台沒有回報（主設備剛重開）＝不寫「已關閉」；關掉之前的舊回報不算回執。
/// - 中央收窄、這台的設定存不進去：工具清單、授權檢查照中央上限；跑著的工作收掉、不 resume；下一輪存得進去才真的收窄設定。
/// - 舊的遠端設定 RPC（continue_setup：trigger .remote、沒有套用快照）：不 route dns、不新建通道、不換網址。
/// - ［連線］：卡片上取消＝這一輪結束（不再佔著、可以再按）；流程沒真的開始＝不佔著；offer() 回到預設的主機。
extension HandsBuildAcceptance {
    @MainActor static func integrationReviewChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        try await applySnapshotChecks(check, base, keys)
        try await localUnlockChecks(check, base, keys)
        try await noReportOffChecks(check, base, keys)
        try await narrowingNotSavedChecks(check, base, keys)
        try await legacyRemoteNoDNS(check, base, keys)
        try await connectRoundChecks(check, base, keys)
    }

    @MainActor static func reviewController(_ fleet: Fleet, _ device: Device, flow: HandsConnectFlow? = nil,
                                            background: @escaping (@escaping @Sendable () -> Void) -> Void = { work in work() }) -> HandsBuildController {
        let executor: HandsBuildExecutor = device.executor, id = device.id
        return HandsBuildController(dependencies: .init(
            sync: device.sync, flow: flow ?? HandsConnectFlow(), localID: { id }, pairedDevices: { HandsBuildAcceptance.known },
            loginHere: {},
            unlockHere: { incident, epoch, generation in executor.unlockHere(incident: incident, setupEpoch: epoch, revocationGeneration: generation) },
            revocation: .standard(service: device.service, callPrimary: HandsBuildAcceptance.fleetPrimaryCall(fleet, sender: id)),   // W183 R11 第二輪
            openLogin: { _, _ in }, closeLogin: { _ in }, markLoginDone: { _ in },
            background: background, now: { fleet.clock.now(for: id) }, uptime: { fleet.clock.uptime() }))   // W183 R11 最後一輪：這台的兩個鐘
    }

    // MARK: - 1. 「套用」帶按的時候看到的那一份（GPT-6 高）

    @MainActor static func applySnapshotChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("review-apply"), keys: keys)
        let a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B")
        try fixtureAccount(b)   // B 有那個網域的 Cloudflare 授權（只問有沒有；不碰真的鑰匙圈）
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        func pump(_ rounds: Int = 3) { for _ in 0..<rounds { fleet.syncAll([bID]); b.executor.drain(); fleet.syncAll([aID]) } }
        pump()
        // 1a. 按「套用」之後、背景真的送出之前，別處（另一台）改了 B 的子網域（設定版本 +1、B 的 setupEpoch 不變）：不送。
        let injected = HandsLocked(false)
        let raced = reviewController(fleet, a, background: { work in
            if !injected.get() {
                injected.set(true)
                _ = try? fleet.update([.subdomain(device: bID, label: "os-for-chatgpt-raced")])
                fleet.syncAll([bID]); fleet.syncAll([aID])   // B 拿到新的一版；A 這台知道的設定也是新的了
            }
            work()
        })
        let ready = await waitUntil(5) { raced.authorized(bID) && raced.view.report(bID)?.setupEpoch != nil && raced.config?.zoneID == zoneID }
        let before = b.runner.nonLogin.count, epochBefore = b.setup.setupEpoch, seenRevision = raced.config?.configRevision ?? -1
        raced.applyURLs()
        let refused = await waitUntil(5) { if case .failed? = raced.applyWork[bID] { return true }; return false }
        pump()
        b.executor.drain()
        check(ready && injected.get() && refused && raced.applyWork[bID] == .failed(HandsBuildConfigError.revisionConflict(0).plain)
              && b.runner.nonLogin.count == before && b.setup.setupEpoch == epochBefore && (fleet.store.load()?.configRevision ?? 0) == seenRevision + 1
              && b.setup.snapshot.publicHost == nil,
              "W183 R8 整合審查 套用：按下去之後、背景送出之前設定換了一版（只改子網域、那台的 setupEpoch 沒變）＝不送（不自己換成新的版本；那台零指令），請你再看一次",
              "ready=\(ready) refused=\(refused) work=\(String(describing: raced.applyWork[bID])) commands=\(b.runner.nonLogin.count - before)")
        // 送出時一定帶按的時候看到的那一份：「套用」沒帶＝不送（HandsBuildSync.submit）。
        var unpinned = false
        do { _ = try a.sync.submit(action: "apply_urls", target: bID, setupEpoch: b.setup.setupEpoch) { _ in } }
        catch { unpinned = (error as? HandsBuildSyncError) == .unavailable("expected_revision") }
        check(unpinned, "W183 R8 整合審查 套用一定帶按的時候看到的那一份（主權＋設定版本）：沒帶＝不送（送出那一刻不自己讀版本）")

        // 1b. 存好子網域、B 一直沒回報拿到那一版（B 連不到主設備）：到期不送、出錯（沒收到那一版的回執就不送）；取消勾 B＝那台的出錯收掉。
        let ctl = reviewController(fleet, a)
        pump()
        _ = await waitUntil(5) { ctl.config?.configRevision == fleet.store.load()?.configRevision && ctl.view.report(bID)?.setupEpoch != nil }
        let revision = ctl.config?.configRevision ?? -1
        fleet.offline.set([bID])
        let commandsBefore = b.runner.nonLogin.count
        ctl.applyURLs(saving: [.subdomain(device: bID, label: "os-for-chatgpt-late")], expected: revision)
        let waiting = await waitUntil(5) { ctl.applyWork[bID] == .running("等那台拿到新網址…") }
        fleet.clock.advance(HandsBuildController.pickupWait + 5)
        var late = false
        for _ in 0..<60 {
            fleet.syncAll([bID]); fleet.syncAll([aID])
            try? await Task.sleep(nanoseconds: 30_000_000)
            if case .failed? = ctl.applyWork[bID] { late = true; break }
        }
        b.executor.drain()
        let failedText = ctl.applyWork[bID]
        check(waiting && late && b.runner.nonLogin.count == commandsBefore && ctl.problemInfo?.kind == .apply
              && failedText == .failed("那台還沒拿到新的設定（沒開、連不到主設備？）；等它連上再按「套用」"),
              "W183 R8 整合審查 套用帶草稿：存好之後那台一直沒回報拿到那一版＝到期不送（沒收到那一版的回執就不送；那台零指令），那台出錯",
              "waiting=\(waiting) late=\(late) work=\(String(describing: failedText)) commands=\(b.runner.nonLogin.count - commandsBefore)")
        ctl.setDevice(bID, selected: false)
        check(ctl.applyWork[bID] == nil && ctl.problemInfo?.kind != .apply,
              "W183 R8 整合審查 取消勾那台＝那台的套用出錯收掉（狀態不會一直卡在「出錯：那台：…」）", "\(String(describing: ctl.problemInfo))")
        fleet.offline.set([])
        fleet.clock.reset()
    }

    // MARK: - 2. 這台的「解除安全鎖」綁事故編號與世代（GPT-6 中）

    @MainActor static func localUnlockChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("review-unlock"), keys: keys)
        let safety = HandsLocked<String?>("w183unlockone")
        let a = try fleet.add(aID, name: "Laptop A", safety: safety)
        _ = try fleet.update([.select(device: aID, selected: true), .setEnabled(true)])
        let ctl = reviewController(fleet, a)
        func round() { fleet.syncAll([aID]); fleet.syncAll([aID]) }
        round()
        let shownOne = await waitUntil(5) { ctl.view.report(aID)?.safetyIncident == "w183unlockone" }
        // 畫面上是第一次事故；按下去之前又發生了一次（新的事故編號）：晚到的解除清不掉新事故的鎖。
        safety.set("w183unlocktwo")
        ctl.unlockSafety(for: aID)
        let refusedIncident = await waitUntil(5) { ctl.actionProblem == HandsBuildController.refusalText("incident_changed") }
        check(shownOne && refusedIncident && safety.get() == "w183unlocktwo",
              "W183 R8 整合審查 這台按「解除安全鎖」也綁按的時候看到的事故編號：之後又發生一次＝不解除新的那一次（不叫不帶事故編號的 retry()）",
              ctl.actionProblem ?? "nil")
        // 畫面看到第二次事故，但這台的設定流程剛取消過（setupEpoch 換了）：不解除。
        round()
        _ = await waitUntil(5) { ctl.view.report(aID)?.safetyIncident == "w183unlocktwo" }
        a.setup.cancel()
        ctl.unlockSafety(for: aID)
        let refusedEpoch = await waitUntil(5) { ctl.actionProblem == HandsBuildController.refusalText("epoch_stale") }
        check(refusedEpoch && safety.get() == "w183unlocktwo",
              "W183 R8 整合審查 這台按「解除安全鎖」綁 setupEpoch：畫面之後流程重開或取消過＝不解除（再看一次再按）", ctl.actionProblem ?? "nil")
        // 看到的就是現在這一次、世代也對：解除。
        round()
        _ = await waitUntil(5) { ctl.view.report(aID)?.setupEpoch == a.setup.setupEpoch }
        ctl.unlockSafety(for: aID)
        let unlocked = await waitUntil(5) { safety.get() == nil && ctl.actionProblem == nil }
        check(unlocked && ctl.actionProblem == nil,
              "W183 R8 整合審查 這台按「解除安全鎖」：看到的就是現在這一次（事故編號、setupEpoch、撤銷世代都對）才解除——跟信箱那條同一套核對",
              ctl.actionProblem ?? "nil")
    }

    // MARK: - 3. 關掉的那台沒有回報＝不寫「已關閉」（GPT-6 中）

    @MainActor static func noReportOffChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("review-off"), keys: keys)
        let a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B")
        // C 看到的全貌沒有任何回報（主設備剛重開、記憶體裡的回報還沒回來）。
        let c = try fleet.add(cID, name: "Desk C", callPrimary: { payload in
            var response = try Fleet.wire(try HandsBuildRemote.handle(payload: try Fleet.wire(payload), sender: cID, authority: fleet.authority))
            response["reports"] = [Any]()
            return response
        })
        _ = b
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true)])
        fleet.syncAll([bID])   // B 第一輪：回報是拿到許可「之前」的（還沒開），之後才開
        _ = try fleet.update([.select(device: bID, selected: false)])   // 關掉 B（撤銷世代 +1）；B 還沒套用這次關掉
        let ctlA = reviewController(fleet, a), ctlC = reviewController(fleet, c)
        fleet.syncAll([aID, cID])
        _ = await waitUntil(5) { ctlA.config?.entry(bID)?.selected == false && ctlC.config?.entry(bID)?.selected == false }
        let staleReport = ctlA.devices.first { $0.id == bID }?.state
        let noReport = ctlC.devices.first { $0.id == bID }?.state
        let neverRan = ctlC.devices.first { $0.id == pID }?.state
        check(staleReport == .working && ctlA.statusText == "關閉中…（等那台回報）"
              && noReport == .waiting && ctlC.statusText == "關閉中…（等那台回報）" && neverRan == .off,
              "W183 R8 整合審查 關掉的那台：沒有回報（主設備剛重開）＝待套用、不寫已關閉；關掉之前的舊回報（看起來停了）也不算回執；從沒跑過的那台照樣是關",
              "stale=\(String(describing: staleReport)) none=\(String(describing: noReport)) never=\(String(describing: neverRan)) \(ctlA.statusText) / \(ctlC.statusText)")
        // B 套用了這次關掉（回報撤銷世代的回執）＝關。
        fleet.syncAll([bID]); fleet.syncAll([bID]); fleet.syncAll([aID])
        let off = await waitUntil(5) { ctlA.devices.first { $0.id == bID }?.state == .off }
        check(off && (fleet.authority.reportsSnapshot().first { $0.deviceID == bID }?.appliedGeneration ?? 0) >= 1,
              "W183 R8 整合審查 那台回報已經套用這次關掉（撤銷世代的回執）、真的停了＝才寫關")
    }

    // MARK: - 4. 中央收窄、這台的設定存不進去（GPT-6 高）

    @MainActor static func narrowingNotSavedChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("review-narrow"), keys: keys)
        let host = "os-for-chatgpt-studiob.example.com"
        let b = try fleet.add(bID, name: "Studio B")
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain),
                              .level(device: bID, level: 2)])
        _ = try b.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = bID; $0.level = 2 }
        fleet.syncAll([bID])
        let access = try pair(b.service, host: host)
        let grantID = b.service.auth.grant(forAccess: access)?.grantID ?? ""
        func toolLevel() -> Int? { (try? b.service.handle(method: "hands_tools", params: ["access_token": access]))?["level"] as? Int }
        let levelBefore = toolLevel()
        let suspendsBefore = b.suspends.get(), resumesBefore = b.resumes.get()
        b.service.settings.failSavesForTesting = true
        _ = try fleet.update([.level(device: bID, level: 0)])
        fleet.syncAll([bID])
        let levelAfter = toolLevel()
        let kept = b.service.settings.load().level
        let admission = b.service.admissionProblem(grantID: grantID, level: 2, projectID: nil, workspaceID: nil, forWrite: false)
        check(levelBefore == 2 && kept == 2 && levelAfter == 0 && admission == "level_lowered"
              && b.service.capProblem(level: 2, projectID: nil) == "level_lowered"
              && b.suspends.get() > suspendsBefore && b.resumes.get() == resumesBefore,
              "W183 R8 整合審查 中央把這台降到 L0、這台的設定存不進去：舊 grant 的工具清單、啟動與發布的授權照中央上限（L0）；跑著的工作收掉、不 resume",
              "before=\(String(describing: levelBefore)) after=\(String(describing: levelAfter)) kept=\(kept) admission=\(admission ?? "nil") suspends=\(b.suspends.get() - suspendsBefore) resumes=\(b.resumes.get() - resumesBefore)")
        b.service.settings.failSavesForTesting = false
        fleet.syncAll([bID])
        check(b.service.settings.load().level == 0 && toolLevel() == 0, "W183 R8 整合審查 下一輪存得進去：這台的設定也收窄（上限照樣生效）")
    }

    // MARK: - 5. 舊的遠端設定 RPC（continue_setup）不是「套用」（GPT-6 高）

    @MainActor static func legacyRemoteNoDNS(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("review-legacy"), keys: keys)
        let host = "os-for-chatgpt-studiob.example.com", tunnel = "6c6c6c6c-6c6c-46c6-86c6-6c6c6c6c6c6c"
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        let first = try fleet.add(bID, name: "Studio B")
        try preloadApplied(first, host: host, tunnel: tunnel)
        let b = try fleet.add(bID, name: "Studio B", service: first.service)
        try fixtureAccount(b, tunnel: tunnel)
        _ = try b.service.updateSettings { $0.enabled = true; $0.hostDeviceID = bID; $0.publicHost = host; $0.subdomainLabel = "os-for-chatgpt-studiob" }
        b.phase.set(.running(url: "https://\(host)/mcp"))
        fleet.syncAll([bID])
        _ = await waitUntil(15) { !b.setup.isBusy }
        // 中央改了 B 的子網域（期望的網址變了），還沒按新版的「套用」；已配對的舊客戶端送來有效的 continue_setup（HandsRemote.setupAction 叫的就是這個）。
        _ = try fleet.update([.subdomain(device: bID, label: "os-for-chatgpt-renamed")])
        fleet.syncAll([bID])
        _ = await waitUntil(15) { !b.setup.isBusy }
        let before = b.runner.commands.get().count
        let started = b.setup.runAll(trigger: .remote, allowLogin: true, hostOverride: bID, requester: aID)
        _ = await waitUntil(20) { !b.setup.isBusy }
        let commands = Array(b.runner.commands.get().dropFirst(before))
        let state = b.setup.snapshot
        check(started && !commands.contains { $0.contains("route") || $0.contains("create") } && state.publicHost == host && state.retiredHost == nil
              && b.service.settings.load().publicHost == host,
              "W183 R8 整合審查 舊的遠端設定 RPC（continue_setup：trigger .remote、沒有套用的快照）不是套用授權：不 route dns、不新建通道、不換網址（換網址只有經執行者帶快照的「套用」）",
              "\(commands.map { $0.suffix(3).joined(separator: " ") }) host=\(state.publicHost ?? "nil")")
    }

    // MARK: - 6. ［連線］的這一輪（GPT-6 中、Claude 高／中）

    @MainActor static func connectRoundChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("review-connect"), keys: keys)
        let a = try fleet.add(aID, name: "Laptop A")
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true)])
        fleet.syncAll([aID])
        let root = base.appendingPathComponent("review-connect-world", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let world = try HandsConnectAcceptance.World(root, "cancel")
        let ctl = reviewController(fleet, a, flow: world.flow)
        _ = await waitUntil(5) { ctl.config?.entry(bID)?.selected == true }
        // 按［連線］→ 卡片出來 → 卡片上按「取消」：這一輪結束（不再佔著「連線中」）；可以再按。
        ctl.connect(deviceID: bID)
        let shown = await waitUntil(5) { HandsConnectAcceptance.isConfirm(world.flow.card) && ctl.connecting == bID }
        world.flow.dismiss()
        let released = await waitUntil(5) { ctl.connecting == nil && ctl.connectQueue.isEmpty && world.flow.card == nil }
        let phaseAfter = world.flow.phase
        ctl.connect(deviceID: bID)
        let again = await waitUntil(5) { HandsConnectAcceptance.isConfirm(world.flow.card) && ctl.connecting == bID }
        check(shown && released && phaseAfter == .waitingTap && again,
              "W183 R8 整合審查［連線］：卡片上按「取消」（卡片收起、流程回到等你按，不是 idle）＝這一輪結束，不再佔著「連線中」；［連線］可以再按",
              "shown=\(shown) released=\(released) phase=\(phaseAfter) again=\(again)")
        world.flow.dismiss()
        _ = await waitUntil(5) { ctl.connecting == nil }
        // ChatGPT build 連過 B 之後，設定流程或助理叫的 offer()＝回到預設的主機（不沿用 B、不沿用面板上選的範圍）。
        world.flow.offer()
        let reset = await waitUntil(5) { HandsConnectAcceptance.isConfirm(world.flow.card) }
        check(reset && world.flow.targetDeviceID == nil,
              "W183 R8 整合審查 offer()（設定流程、助理）＝連這台或主設備：清掉 ChatGPT build 上一輪指定的那台與範圍", String(describing: world.flow.targetDeviceID))
        // 別的連線真的在跑（配對頁出來了）：ChatGPT build 的［連線］沒開始＝不佔著、說一句話。
        let chatgpt = HandsConnectAcceptance.FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        world.flow.connect()
        let pairing = await waitUntil(8) { world.pairing?.pairingCode != nil }
        ctl.connect(deviceID: bID)
        check(pairing && ctl.connecting == nil && ctl.connectQueue.isEmpty && ctl.actionProblem != nil && world.flow.phase == .waitingPairing,
              "W183 R8 整合審查［連線］：別的連線還在跑（流程沒真的開始）＝不佔著「連線中」、不算在這台，說一句話",
              "pairing=\(pairing) connecting=\(ctl.connecting ?? "nil") problem=\(ctl.actionProblem ?? "nil")")
        world.flow.cancel(reason: "test_done")
        _ = await waitUntil(3) { world.service.auth.windowExpiresAt == nil }
    }
}
#endif
