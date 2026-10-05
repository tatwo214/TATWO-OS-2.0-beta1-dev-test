#if DEBUG
import Foundation

/// `TATWO2_SELFTEST=w183build` 的第二部分：W183 R8c 審查（GPT-6 跨引擎＋Claude）指出的邊界——每一項都是行為驗收（真的跑 HandsSetup、
/// 信箱、執行者、關口、畫面控制器，記下假的 cloudflared 收到的每一個指令），不是原始碼形狀。
extension HandsBuildAcceptance {
    static func intent(_ fleet: Fleet, _ action: String, target: String, owner: String, id: String = UUID().uuidString.lowercased(),
                       payload: [String: Any] = [:], epoch: String? = nil, expires: TimeInterval = 60, revision: Int? = nil) throws -> HandsBuildIntent {
        let now = fleet.clock.now()
        return try HandsBuildIntent.submission(HandsBuildIntent.submissionWire(
            operationID: id, action: action, target: target, attempt: nil, configRevision: revision ?? fleet.store.load()?.configRevision ?? 0,
            setupEpoch: epoch, expiresAt: now.addingTimeInterval(expires), payload: payload), owner: owner, now: now)
    }

    static func preloadApplied(_ device: Device, host: String, tunnel: String) throws {
        var state = HandsSetupState()
        state.accountID = accountID; state.zoneID = zoneID; state.domain = domain; state.hostDeviceID = device.id
        state.tunnelID = tunnel; state.tokenTunnelID = tunnel; state.publicHost = host
        state.createdTunnels = [tunnel]
        state.steps[HandsSetupStep.authorize.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date())
        state.steps[HandsSetupStep.tunnel.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date())
        try device.preloadSetupState(state)
    }

    static func fixtureAccount(_ device: Device, tunnel: String? = nil) throws {
        try device.accounts.upsert(accountID: accountID, name: "Fixture Account", domain: CloudflareDomain(name: domain, zoneID: zoneID),
                                   cert: certPEM(zone: zoneID, token: "x"))
        if let tunnel {
            try device.accounts.select(accountID: accountID, zoneID: zoneID)
            try device.accounts.setTunnel(accountID: accountID, tunnelID: tunnel)
            try device.accounts.saveTunnelToken("w183build-fixture-tunnel-token")
        }
    }

    // MARK: - 16. 設定同步改子網域：自動續跑只恢復已套用的網址（GPT-6／Claude 高）

    @MainActor static func resumeNoDNS(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("resume-dns"), keys: keys)
        let host = "os-for-chatgpt-studiob.example.com", tunnel = "7b7b7b7b-7b7b-47b7-87b7-7b7b7b7b7b7b"
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        let first = try fleet.add(bID, name: "Studio B")
        try preloadApplied(first, host: host, tunnel: tunnel)
        let b = try fleet.add(bID, name: "Studio B", service: first.service, realResume: true)   // 重開：讀預先寫好的狀態；reconcile 叫真的 resume
        try fixtureAccount(b, tunnel: tunnel)
        _ = try b.service.updateSettings { $0.enabled = true; $0.hostDeviceID = bID; $0.publicHost = host; $0.subdomainLabel = "os-for-chatgpt-studiob" }
        b.phase.set(.running(url: "https://\(host)/mcp"))
        fleet.syncAll([bID])
        _ = await waitUntil(15) { !b.setup.isBusy }
        let access = try pair(b.service, host: host)
        let grant = b.service.auth.grant(forAccess: access)?.grantID ?? ""
        let startedBefore = b.resumeStarted.get().count
        _ = try fleet.update([.subdomain(device: bID, label: "os-for-chatgpt-renamed")])
        fleet.syncAll([bID])
        _ = await waitUntil(15) { !b.setup.isBusy }
        let started = b.resumeStarted.get()
        let commands = b.runner.nonLogin
        let state = b.setup.snapshot
        let settings = b.service.settings.load()
        check(started.count > startedBefore && started.last == true && commands.isEmpty
              && state.publicHost == host && settings.publicHost == host && state.retiredHost == nil
              && b.service.auth.grantRecord(grant)?.revokedAt == nil && tools(b.service, access) && settings.subdomainLabel == "os-for-chatgpt-renamed",
              "設定同步改了子網域（期望的網址變了）：背景同步照樣自動續跑，但只恢復已經套用的網址——零 cloudflared 指令（沒有 route dns）、不換網址、不撤銷連線；換網址要使用者按「套用」",
              "\(commands) started=\(started) host=\(state.publicHost ?? "nil")")
        fleet.syncAll([bID])
        let report = fleet.authority.reportsSnapshot().first { $0.deviceID == bID }
        check(report?.publicHost == host && fleet.store.load()?.hostname(bID) == "os-for-chatgpt-renamed.example.com",
              "期望（設定：新子網域）與已套用（那台回報的網址：舊的）分開：畫面照這個寫「等你按套用」")
    }

    // MARK: - 17. 關掉 B 時 B 的「套用」正在跑：先作廢那個工作（GPT-6 高）

    @MainActor static func disableCancelsApply(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("disable-apply"), keys: keys)
        let b = try fleet.add(bID, name: "Studio B")
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        try fixtureAccount(b)
        fleet.syncAll([bID])
        b.runner.hold.set(true)
        let posted = HandsLocked<[HandsBuildResult]>([])
        b.executor.post = { result in posted.update { $0.append(result) } }
        let epochBefore = b.setup.setupEpoch
        b.executor.executeNow(try intent(fleet, "apply_urls", target: bID, owner: aID, epoch: epochBefore))
        let holding = await waitUntil(15) { b.runner.commands.get().contains { $0.contains("create") } }
        _ = try fleet.update([.select(device: bID, selected: false)])
        fleet.syncAll([bID])
        let stopped = await waitUntil(15) { !b.setup.isBusy }
        b.runner.hold.set(false)
        b.executor.drain()
        // 放開之後被取消的指令才回來、最後結果才送出（非同步）：等最後結果到（最多 5 秒）再比對，條件一條都不放（偶發失敗的原因）。
        _ = await waitUntil(5) { posted.get().last?.final == true && !b.setup.isBusy }
        let final = posted.get().last
        check(holding && stopped && b.runner.cancelledCommands.get() >= 1 && !b.service.settings.load().enabled && b.starts.get() == 0
              && !b.runner.commands.get().contains { $0.contains("route") } && b.setup.setupEpoch != epochBefore
              && final?.final == true && final?.state == "failed" && b.setup.snapshot.publicHost == nil,
              "關掉 B 時 B 的「套用」正在建通道：先作廢那個設定工作（換世代、收掉 cloudflared）；舊工作不會接著改 DNS、不會寫回「打開」",
              "holding=\(holding) stopped=\(stopped) cancelled=\(b.runner.cancelledCommands.get()) \(b.runner.commands.get().map { $0.suffix(3).joined(separator: " ") })")
    }

    // MARK: - 18. 「套用」拍下不變的那一份；主設備當目標、主設備當擁有者（GPT-6 中、Claude 中）

    @MainActor static func applyPlanChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("apply-plan"), keys: keys)
        let canary = "W183BUILDLOGINP" + String(UUID().uuidString.prefix(8)).lowercased().filter { $0.isLetter || $0.isNumber }
        let p = try fleet.add(pID, name: "Primary One")
        let a = try fleet.add(aID, name: "Laptop A")
        let b = try fleet.add(bID, name: "Studio B", loginCanary: canary)
        _ = try fleet.update([.setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])   // 一台都沒勾＝勾主設備
        try fixtureAccount(p)
        fleet.syncAll()
        // 拍下的那一份跟 build 給這台的不一樣（按的時候看到的是舊的子網域）：這一輪不建、不寫子網域。
        let stale = HandsApplyPlan(accountID: accountID, zoneID: zoneID, subdomain: "os-for-chatgpt-other",
                                   hostname: "os-for-chatgpt-other.example.com", revocationGeneration: 0)
        let started = p.setup.applyURLs(plan: stale, trigger: .user)
        _ = await waitUntil(10) { !p.setup.isBusy }
        check(started && p.runner.nonLogin.isEmpty && p.setup.snapshot.step(.tunnel).message == HandsSetup.planChangedMessage
              && p.service.settings.load().subdomainLabel != "os-for-chatgpt-other",
              "「套用」拍下的那一份跟 build 給這台的不一樣（設定改過）：這一輪不建通道、不改 DNS、不寫子網域", p.setup.snapshot.step(.tunnel).message)
        // A 替主設備按「套用」：經信箱交給主設備，主設備的執行者用同一套核對自己做；結果只回到 A。
        let aResults = HandsLocked<[HandsBuildResult]>([])
        // W183 R8 整合審查（GPT-6 高）：「套用」一定帶按的時候看到的那一份（主權＋設定版本）；送出時不自己換版本。
        _ = try a.sync.submit(action: "apply_urls", target: pID, setupEpoch: p.setup.setupEpoch, expected: a.sync.knownConfig().map(HandsBuildExpected.of)) { result in
            aResults.update { $0.append(result) }
        }
        for _ in 0..<150 {
            p.executor.drain()
            fleet.syncAll([pID, aID])
            if aResults.get().contains(where: \.final) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        _ = await waitUntil(10) { !p.setup.isBusy }
        let aFinal = aResults.get().first(where: \.final)
        check(aFinal?.state == "failed" && p.runner.nonLogin.contains { $0.contains("create") } && a.runner.nonLogin.isEmpty
              && p.service.settings.load().effectiveSubdomainLabel == "os-for-chatgpt",
              "A 替主設備按「套用」：主設備是目標（本機那一段）也走信箱與執行者，照 build 給它的子網域建；結果回到 A",
              "\(String(describing: aFinal?.object))")
        // 主設備當擁有者：人在主設備替 B 登入——網址經信箱交回主設備自己（本機交、交完就清），A 拿不到。
        let pResults = HandsLocked<[HandsBuildResult]>([])
        b.runner.cert.set(certPEM(zone: zoneID, token: "W183BUILDAPITOKENP"))
        let id = try p.sync.submit(action: "login", target: bID, setupEpoch: b.setup.setupEpoch) { result in pResults.update { $0.append(result) } }
        var gotURL = false
        for _ in 0..<150 {
            fleet.syncAll([bID])
            b.executor.drain()
            b.sync.syncNow()
            fleet.syncAll([pID, aID])
            if pResults.get().contains(where: { $0.state == "login_url" }) { gotURL = true; break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let url = pResults.get().first { $0.state == "login_url" }?.object["url"] as? String ?? ""
        let aSees = fleet.authority.mailbox.takeResults(owner: aID, now: fleet.clock.now())
        check(gotURL && url.contains(String(canary.prefix(20))) && aSees.allSatisfy { $0.operationID != id },
              "人在主設備替 B 登入：B 產生的授權網址經信箱只回到主設備（本機交給等待者），A 拿不到")
        b.runner.authorize.set(true)
        for _ in 0..<150 {
            b.sync.syncNow()
            fleet.syncAll([pID])
            if pResults.get().contains(where: \.final) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        check(pResults.get().first(where: \.final)?.state == "authorized" && !fleet.authority.mailbox.debugState(id).exists,
              "主設備當擁有者：最後結果本機交完就 ack，信箱上這件清掉")
    }

    // MARK: - 19. 信箱：結果掉包拿得回來、B 交不出去的下一輪再送、沒人取＝結果未知（GPT-6 中、Claude 高）

    @MainActor static func mailboxAckChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("ack"), keys: keys)
        let drop = HandsLocked(false)
        let authority = fleet.authority
        let a = try fleet.add(aID, name: "Laptop A", callPrimary: { payload in
            let response = try Fleet.wire(try HandsBuildRemote.handle(payload: try Fleet.wire(payload), sender: HandsBuildAcceptance.aID, authority: authority))
            if drop.get(), payload["op"] as? String == "sync" { drop.set(false); throw RemoteHostLinkError.tunnelUnavailable }   // 回應在路上掉了
            return response
        })
        let b = try fleet.add(bID, name: "Studio B")
        let p = try fleet.add(pID, name: "Primary One")
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true)])
        fleet.syncAll()
        let results = HandsLocked<[HandsBuildResult]>([])
        let id = try a.sync.submit(action: "revoke_all", target: bID, setupEpoch: b.setup.setupEpoch, payload: ["grants_digest": ""]) { result in
            results.update { $0.append(result) }
        }
        fleet.syncAll([bID]); b.executor.drain(); b.sync.syncNow()
        drop.set(true)
        a.sync.syncNow()
        let lost = results.get().isEmpty && fleet.authority.mailbox.debugState(id).results == 1
        a.sync.syncNow(); a.sync.syncNow(); a.sync.syncNow()
        check(lost && results.get().count == 1 && results.get().first?.final == true && results.get().first?.state == "done"
              && !fleet.authority.mailbox.debugState(id).exists,
              "回應在路上掉了：主設備沒收到 ack 前留著、下一輪再給；擁有者照序號去重（只交一次）；ack 之後才清", "lost=\(lost) \(results.get().map(\.state))")
        // B 交結果時連不到主設備：記在 B 的 outbox（只在記憶體），連上後下一輪先送；主設備照 B 的序號去重。
        let second = HandsLocked<[HandsBuildResult]>([])
        let id2 = try a.sync.submit(action: "revoke_all", target: bID, setupEpoch: b.setup.setupEpoch, payload: ["grants_digest": ""]) { result in
            second.update { $0.append(result) }
        }
        fleet.syncAll([bID])
        fleet.offline.set([bID])
        b.executor.drain(); b.sync.syncNow()
        let stuck = fleet.authority.mailbox.debugState(id2).results == 0
        fleet.offline.set([])
        b.sync.syncNow(); b.sync.syncNow()
        a.sync.syncNow(); a.sync.syncNow()
        check(stuck && second.get().filter(\.final).count == 1 && second.get().first?.state == "done",
              "B 交結果時連不到主設備：outbox 下一輪再送，擁有者收到一次", "\(second.get().map(\.state))")
        // 沒人取（目標那台沒開、取件期限過了）：主設備清掉，擁有者帶「還在等」問到 gone＝結果未知（不會永遠轉圈）。
        let third = HandsLocked<[HandsBuildResult]>([])
        _ = try a.sync.submit(action: "revoke_all", target: cID, setupEpoch: "x", payload: ["grants_digest": ""], lifetime: 5) { result in
            third.update { $0.append(result) }
        }
        let pWaits = HandsLocked<[HandsBuildResult]>([])
        _ = try p.sync.submit(action: "revoke_all", target: cID, setupEpoch: "x", payload: ["grants_digest": ""], lifetime: 5) { result in
            pWaits.update { $0.append(result) }
        }
        let hotBefore = a.sync.debugHot()
        fleet.clock.advance(10)
        a.sync.syncNow()
        p.sync.syncNow()
        check(third.get().count == 1 && third.get().first?.state == "unknown" && third.get().first?.object["reason"] as? String == "result_unknown"
              && pWaits.get().first?.state == "unknown" && hotBefore,
              "沒人取（期限過了）：副設備擁有者問到 gone、主設備擁有者看到信箱沒有這件＝都收成「結果未知」",
              "\(third.get().map(\.state)) \(pWaits.get().map(\.state))")
        // 快速輪詢只算還在 hotWindow 內的等待者（等不到的舊事不會讓副設備永遠每 1.5 秒問一次）。
        _ = try a.sync.submit(action: "revoke_all", target: cID, setupEpoch: "x", payload: ["grants_digest": ""], lifetime: 180) { _ in }
        let hotNow = a.sync.debugHot()
        fleet.clock.advance(200)
        check(hotNow && !a.sync.debugHot(), "快速輪詢只算 3 分鐘內送出的事：之後就算還在等，也回到平常的間隔")
        fleet.clock.reset()
    }

    // MARK: - 20. 第二件登入忙碌：不蓋掉第一件的取消；取消認擁有者、真的取消才回成功（GPT-6 中）

    @MainActor static func busyLoginChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("busy-login"), keys: keys)
        let b = try fleet.add(bID, name: "Studio B")
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true)])
        fleet.syncAll()
        let posted = HandsLocked<[HandsBuildResult]>([])
        b.executor.post = { result in posted.update { $0.append(result) } }
        let first = try intent(fleet, "login", target: bID, owner: aID, epoch: b.setup.setupEpoch)
        b.executor.executeNow(first)
        let waiting = await waitUntil(15) { b.setup.isBusy && b.runner.logins == 1 }
        let second = try intent(fleet, "login", target: bID, owner: aID, epoch: b.setup.setupEpoch)
        b.executor.executeNow(second)
        let secondRefused = posted.get().last { $0.operationID == second.operationID }?.object["reason"] as? String == "busy"
        b.executor.executeNow(try intent(fleet, "login_cancel", target: bID, owner: cID, payload: ["operation_id": first.operationID]))
        let notOwner = posted.get().last?.object["reason"] as? String == "not_owner" && b.setup.isBusy
        b.executor.executeNow(try intent(fleet, "login_cancel", target: bID, owner: aID, payload: ["operation_id": second.operationID]))
        let finishedRefused = posted.get().last?.object["reason"] as? String == "already_finished"
        b.executor.executeNow(try intent(fleet, "login_cancel", target: bID, owner: aID, payload: ["operation_id": first.operationID]))
        let cancelReply = posted.get().last
        let stopped = await waitUntil(15) { !b.setup.isBusy }
        b.executor.drain()
        // W183 R8 整合：那一輪的結果是在「忙碌」放掉之後才交出（HandsSetup 的 finished 在設定工作的佇列上），等它到（不放寬：還是要「cancelled」）。
        _ = await waitUntil(5) { posted.get().contains { $0.operationID == first.operationID && $0.final } }
        let firstFinal = posted.get().last { $0.operationID == first.operationID && $0.final }
        check(waiting && secondRefused && notOwner && finishedRefused && cancelReply?.state == "done"
              && cancelReply?.object["was_running"] as? Bool == true && stopped && firstFinal?.state == "cancelled",
              "第二件登入（忙碌）不蓋掉第一件；別台（不是擁有者）取消不了；取消已經結束的＝照實說；擁有者取消第一件＝真的收掉那一輪",
              "waiting=\(waiting) second=\(secondRefused) notOwner=\(notOwner) finished=\(finishedRefused) \(String(describing: cancelReply?.object)) stopped=\(stopped) final=\(firstFinal?.state ?? "nil")")
        // 墓碑存不進去＝不假裝取消了。
        let unwritable = b.paths.appDir.appendingPathComponent("build-ops.json")
        let blocker = HandsBuildExecutor(dependencies: b.executor.dependencies, ledgerURL: unwritable.appendingPathComponent("nope/ops.json"))
        let blockedPosts = HandsLocked<[HandsBuildResult]>([])
        blocker.post = { result in blockedPosts.update { $0.append(result) } }
        blocker.executeNow(try intent(fleet, "login_cancel", target: bID, owner: aID, payload: ["operation_id": UUID().uuidString.lowercased()]))
        check(blockedPosts.get().last?.state == "refused", "紀錄存不進去：取消回失敗（不把沒取消的回成成功）")
    }

    // MARK: - 21. 畫面控制器：別台的登入網址只開在這台；沒收到回執不寫已關閉；沒拿到設定不能改（GPT-6 中、Claude 中）

    @MainActor static func controllerChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("controller"), keys: keys)
        let canary = "W183BUILDLOGINC" + String(UUID().uuidString.prefix(8)).lowercased().filter { $0.isLetter || $0.isNumber }
        let a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B", loginCanary: canary), c = try fleet.add(cID, name: "Desk C")
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true)])   // 先勾 B 再開：只勾 B（不自動勾主設備）
        fleet.syncAll()
        let known = HandsBuildAcceptance.known
        // W183 R8 整合（R8b）：授權完成＝那個授權分頁標「完成」（markLoginDone；頁面關掉、分頁留著），其他結果才收掉（closeLogin）。
        let doneA = HandsLocked<[URL]>([])
        func controller(_ device: Device, sync: HandsBuildSync? = nil, opened: HandsLocked<[URL]>, closed: HandsLocked<[URL]>) -> HandsBuildController {
            HandsBuildController(dependencies: .init(
                sync: sync ?? device.sync, flow: HandsConnectFlow(), localID: { device.id }, pairedDevices: { known },
                loginHere: {}, unlockHere: { _, _, _ in "not_used" },
                revocation: .standard(service: device.service, callPrimary: HandsBuildAcceptance.fleetPrimaryCall(fleet, sender: device.id)),   // W183 R11 第二輪
                openLogin: { url, _ in opened.update { $0.append(url) } }, closeLogin: { url in closed.update { $0.append(url) } },
                markLoginDone: { url in doneA.update { $0.append(url) } },
                background: { work in work() }, now: { fleet.clock.now() }))
        }
        let openedA = HandsLocked<[URL]>([]), closedA = HandsLocked<[URL]>([]), openedC = HandsLocked<[URL]>([]), closedC = HandsLocked<[URL]>([])
        let ctlA = controller(a, opened: openedA, closed: closedA)
        let ctlC = controller(c, opened: openedC, closed: closedC)
        fleet.syncAll([bID]); fleet.syncAll([aID, cID])
        _ = await waitUntil(5) { ctlA.view.report(bID)?.setupEpoch != nil }   // 全貌發到主執行緒（畫面拿到 B 的回報）
        b.runner.cert.set(certPEM(zone: zoneID, token: "W183BUILDAPITOKENC"))
        ctlA.loginCloudflare(for: bID)
        var opened = false
        for _ in 0..<150 {
            fleet.syncAll([bID]); b.executor.drain(); b.sync.syncNow(); fleet.syncAll([aID, cID])
            try? await Task.sleep(nanoseconds: 30_000_000)
            if !openedA.get().isEmpty { opened = true; break }
        }
        check(opened && openedA.get().first?.absoluteString.contains(String(canary.prefix(20))) == true && openedC.get().isEmpty
              && ctlA.loginWork[bID] == .running("在私訊框按 Authorize（授權存到那台）"),
              "畫面：人在 A 替 B 登入——授權頁只開在 A 的私訊框（C 的畫面什麼都沒開）")
        b.runner.authorize.set(true)
        var done = false
        for _ in 0..<150 {
            b.sync.syncNow(); fleet.syncAll([aID])
            try? await Task.sleep(nanoseconds: 30_000_000)
            if ctlA.loginWork[bID] == .done("已登入") { done = true; break }
        }
        // W183 R8 整合：原本守的「敏感頁面不留著」照舊——完成＝頁面關掉（R8b：分頁留著寫「完成」、不再算敏感），不是留著可以操作的登入頁。
        check(done && doneA.get() == openedA.get() && closedA.get().isEmpty,
              "登入完成：那張授權頁收起來（敏感頁面不留著；W183 R8 整合：分頁標「完成」、頁面關掉）", "\(String(describing: ctlA.loginWork[bID]))")
        _ = ctlC
        // 關掉 B：B 還沒回報＝「關閉中」，不寫已關閉；B 回報已套用、真的停了才算關。
        _ = try fleet.update([.select(device: bID, selected: false)])
        fleet.syncAll([aID])
        try? await Task.sleep(nanoseconds: 50_000_000)
        let pendingState = ctlA.devices.first { $0.id == bID }?.state
        let pendingText = ctlA.statusText
        fleet.syncAll([bID]); fleet.syncAll([bID]); fleet.syncAll([aID])
        try? await Task.sleep(nanoseconds: 50_000_000)
        let offState = ctlA.devices.first { $0.id == bID }?.state
        check(pendingState == .working && pendingText == "關閉中…（等那台回報）" && offState == .off && ctlA.statusText == "等你選設備",
              "沒收到 B 的回執：B 那一格是「進行中」、狀態寫「關閉中」；B 回報已套用、真的停了才寫關", "\(String(describing: pendingState)) \(pendingText) \(String(describing: offState))")
        // B 離線：關掉之後 B 一直沒回報（回報太舊、上次看到還開著）＝「離線、待套用」，不是已關。
        _ = try fleet.update([.select(device: bID, selected: true)])
        fleet.syncAll([bID]); fleet.syncAll([bID]); fleet.syncAll([aID])
        _ = try fleet.update([.select(device: bID, selected: false)])
        fleet.clock.advance(100)
        fleet.syncAll([aID])
        try? await Task.sleep(nanoseconds: 50_000_000)
        let offlineState = ctlA.devices.first { $0.id == bID }?.state
        check(offlineState == .waiting && ctlA.problem?.contains("關閉還沒套用") == true,
              "B 離線（回報太舊、上次看到還開著）：寫「連不到，關閉還沒套用」，不寫已關", "\(String(describing: offlineState)) \(ctlA.problem ?? "")")
        // 這台自己失聯：快取的回報不算新（這台的鐘也看）。
        fleet.syncAll([bID]); fleet.syncAll([bID]); fleet.syncAll([aID])
        fleet.clock.advance(100)
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(ctlA.devices.first { $0.id == bID }?.state == .off, "這台自己很久沒同步：已經確定關掉的照樣是關（回報上次看到已停）")
        fleet.clock.reset()
        // 還沒拿到設定（全貌是空的）：不能改（沒有「不比對版本」）。
        let blankSync = HandsBuildSync(dependencies: c.sync.dependencies)
        let blank = controller(c, sync: blankSync, opened: openedC, closed: closedC)
        let revision = fleet.store.load()?.configRevision
        blank.setEnabled(false)
        check(blank.actionProblem != nil && fleet.store.load()?.configRevision == revision && fleet.store.load()?.enabled == true,
              "畫面還沒從主設備拿到設定：改設定不送（沒有預期版本就不能改）")
    }

    // MARK: - 22. 這台的開關與等級、專案跟中央設定兩個方向都對得上（Claude 中）

    @MainActor static func switchAndScopeChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("switch"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One")
        _ = try fleet.update([.setEnabled(true)])
        _ = try p.service.updateSettings { $0.publicHost = "os-for-chatgpt.example.com"; $0.hostDeviceID = pID }
        fleet.syncAll([pID])
        let enabledBySelect = p.service.settings.load().enabled
        _ = try p.service.updateSettings { $0.enabled = false }   // 使用者在這台關掉（舊的開關；寫穿還沒到）
        _ = try fleet.update([.level(device: pID, level: 0)])      // 中央改了別的內容
        fleet.syncAll([pID])
        check(enabledBySelect && !p.service.settings.load().enabled,
              "只有「從沒勾變成勾了」才打開這台：使用者在這台關掉之後，中央改了別的內容也不會被偷偷打開")
        p.sync.localSwitchedOff(local: pID)
        let deselected = await waitUntil(5) { fleet.store.load()?.entry(pID)?.selected == false }
        check(deselected, "在這台關掉開關＝中央設定也取消勾這台（寫穿）")
        let permitted = p.sync.selectHere(local: pID)
        check(permitted && fleet.store.load()?.isActive(pID) == true, "在這台打開、中央沒勾這台（總開關開著）＝勾這台")
        _ = try fleet.update([.setEnabled(false)])
        let reenabled = p.sync.selectHere(local: pID)
        check(reenabled && fleet.store.load()?.enabled == true && fleet.store.load()?.isActive(pID) == true,
              "只勾了這台、總開關關著：在這台打開＝打開總開關（舊資料遷移成「勾了但關著」也打得開）")
        _ = try fleet.update([.select(device: aID, selected: true), .setEnabled(false)])
        let revision = fleet.store.load()?.configRevision
        let refused = !p.sync.selectHere(local: pID)
        check(refused && fleet.store.load()?.configRevision == revision && fleet.store.load()?.enabled == false,
              "總開關關著、還勾了別台：在這台打開不改中央（打開會連別台一起開：請在 ChatGPT build 打開）")
        // 等級與專案：同一版不收窄（舊畫面剛調高的不會被改回去）；舊畫面改的寫穿到中央；中央調低（版本變大）照樣收窄。
        // W183 R11 最後一輪（GPT-6 R11c 審查 1）：把這台從 L0 調回 L1 也是調高——要這台的回報夠新、已經套用到改之前的這一版：
        // 原本一次改完（取消勾 A、打開總開關、這台 L1）拆成先改開關、這台同步兩輪（回報跟上），再調高；守的照舊。
        _ = try fleet.update([.select(device: aID, selected: false), .setEnabled(true)])
        fleet.syncAll([pID]); fleet.syncAll([pID])
        _ = try fleet.update([.level(device: pID, level: 1)])
        fleet.syncAll([pID])
        _ = try p.service.updateSettings { $0.level = 2 }
        fleet.syncAll([pID]); fleet.syncAll([pID])
        let kept = p.service.settings.load().level == 2
        p.sync.localScopeChanged(level: 2, projects: [])
        let wrote = await waitUntil(5) { fleet.store.load()?.entry(pID)?.level == 2 }
        _ = try fleet.update([.level(device: pID, level: 0)])
        fleet.syncAll([pID])
        check(kept && wrote && p.service.settings.load().level == 0,
              "等級：同一版不收窄（每輪不會把這台剛調高的改回去）；舊畫面改的寫穿到中央；中央調低（版本變大）照樣收窄",
              "kept=\(kept) wrote=\(wrote) level=\(p.service.settings.load().level)")
    }

    // MARK: - 23. 多久問一次（Claude 高／中）

    static func pollingChecks(_ check: Checker) {
        let intervals = HandsBuildSync.Intervals()
        let member = HandsBuildRole.member(local: aID, primary: pID, epoch: 1), authority = HandsBuildRole.authority(local: pID, epoch: 1)
        func at(_ role: HandsBuildRole, hot: Bool = false, active: Bool = false, known: Bool = true, failures: Int = 0, membersHot: Bool = false) -> TimeInterval {
            HandsBuildSync.interval(role: role, hot: hot, permitActive: active, permitKnown: known, failures: failures, membersHot: membersHot,
                                    intervals: intervals)
        }
        check(at(member) == 60 && at(member, known: false) == 120 && at(member, active: true) == 15 && at(member, hot: true) == 1.5
              && at(member, hot: true, failures: 1) == 10 && at(member, failures: 2) == 20 && at(member, failures: 5) == 160 && at(member, failures: 9) == 300
              && at(authority) == 30 && at(authority, hot: true) == 2 && at(authority, membersHot: true) == 2,
              "多久問一次：副設備沒事 60 秒（沒設定 120、被勾 15、有事 1.5）；連不到主設備 10 秒起加倍到 5 分鐘；主設備自己沒事 30 秒、有人熱問 2 秒")
    }
}
#endif
