#if DEBUG
import AppKit
import Foundation

/// `TATWO2_SELFTEST=w183build` 的第三部分：W183 R8 整合（主導把 R8a 的畫面、R8b 的私訊框 Browser 接到 R8c 的多設備後端）。
/// 用真的控制器（HandsBuildController）、信箱、執行者與 R8b 的 Browser（自測的私訊框：隔離的 store、假頁面宿主），驗接起來之後的那一段：
/// - 人在 A 替 B 登入：授權頁開在 A 私訊框的 Browser 分頁（在最前面、敏感頁、不進瀏覽紀錄）；完成＝分頁標「完成」（頁面關掉、不再算敏感、
///   分頁留著）；還沒完成就關掉分頁＝請 B 取消這一輪（信箱 login_cancel；B 的 cloudflared login 收掉）。
/// - 「套用」帶子網域草稿（R8a 的「帶看到的那一份」）：照看到的版本先存（CAS）——存不成＝停、看到的版本舊了＝不存；存好之後等 B 拿到那一版
///   才送套用（B 用自己已接受的那一份拍快照，照新子網域建）。
/// - 每台回報確認過的連線數：暫時的（還沒確認）不算已連線；舊版沒回報＝不當已連線。
extension HandsBuildAcceptance {
    @MainActor static func integrationChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        try await statusTruthChecks(check, base, keys)
        let fleet = try Fleet(base.appendingPathComponent("integration"), keys: keys)
        let canary = "W183BUILDINTEG" + String(UUID().uuidString.prefix(8)).lowercased().filter { $0.isLetter || $0.isNumber }
        let a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B", loginCanary: canary)
        _ = try fleet.update([.select(device: bID, selected: true), .setEnabled(true)])
        fleet.syncAll()
        let dm = HandsUIAcceptance.DMHarness("w183build-integration")
        defer { dm.finish() }
        let ctlA = HandsBuildController(dependencies: .init(
            sync: a.sync, flow: HandsConnectFlow(), localID: { aID }, pairedDevices: { HandsBuildAcceptance.known },
            loginHere: {}, unlockHere: { _, _, _ in nil },
            revocation: .standard(service: a.service, callPrimary: HandsBuildAcceptance.fleetPrimaryCall(fleet, sender: aID)),   // W183 R11 第二輪
            // 正式同一條：HandsSetup.openLoginPage（只收 Cloudflare 授權網址）→ 私訊框的 Browser 分頁；只把私訊框換成自測的。
            openLogin: { url, cancel in _ = dm.open(url, onCancel: cancel) },
            closeLogin: { url in HandsSetup.postCloseLoginPages(only: url) },
            background: { work in work() }, now: { fleet.clock.now() }))
        fleet.syncAll([bID]); fleet.syncAll([aID])
        _ = await waitUntil(5) { ctlA.view.report(bID)?.setupEpoch != nil }

        func pump(_ until: () -> Bool) async -> Bool {
            for _ in 0..<200 {
                fleet.syncAll([bID]); b.executor.drain(); b.sync.syncNow(); fleet.syncAll([aID])
                try? await Task.sleep(nanoseconds: 30_000_000)
                if until() { return true }
            }
            return until()
        }

        // 1. 替 B 登入：授權頁開在 A 私訊框的 Browser 分頁。
        b.runner.cert.set(certPEM(zone: zoneID, token: "W183BUILDAPITOKENI"))
        ctlA.loginCloudflare(for: bID)
        let shown = await pump { dm.loginTab != nil && dm.loginPageReady }
        let tab = dm.loginTab
        let start = tab?.startURL
        check(shown && tab?.purpose == .cloudflareLogin && start?.absoluteString.contains(String(canary.prefix(14))) == true
              && dm.store.isBrowsing && dm.browser.activeID == tab?.id && dm.host.pages.count == 1 && dm.browser.isSensitive
              && start.map(BrowserHistoryStore.isExcluded) == true && ctlA.loginWork[bID] == .running("在私訊框按 Authorize（授權存到那台）"),
              "W183 R8 整合 替別台登入：授權頁開在這台私訊框的 Browser 分頁（在最前面、敏感頁、不進瀏覽紀錄；登入網址經信箱只到按的那台）",
              "shown=\(shown) tab=\(tab?.displayHost ?? "nil") browsing=\(dm.store.isBrowsing) work=\(String(describing: ctlA.loginWork[bID]))")
        // W183 R8 整合審查（GPT-6 高「替別台登入的網址仍暴露在目標設備的本機 UI」）：B 那台只知道「授權頁開著」這個進度——B 的畫面
        // （設定頁「在這台打開授權頁」、ChatGPT build 的登入鈕、「…」、環境登入）拿不到、開不了這個網址。
        _ = await waitUntil(1) { false }   // 讓 B 那邊排在主執行緒的發布先跑完
        var bInput = HandsBuildInput()
        bInput.localDeviceID = bID
        bInput.loginOpenHere = b.setup.loginURL
        bInput.busyHere = b.setup.isBusy
        let bPlan = HandsBuildModel.plan(.loginCloudflare(nil), bInput)
        check(start != nil && b.setup.pendingLoginURL != nil && b.setup.loginURL == nil && start.map { !b.setup.isLocalLoginPage($0) } == true
              && bPlan == [.notice(HandsBuildCopy.busy)],
              "W183 R8 整合審查 替別台登入：那台（B）的畫面拿不到、開不了這個授權網址（不發布到 B 的 loginURL；B 的「在這台打開授權頁」核對這一輪不是 B 自己的就不開）",
              "loginURL=\(b.setup.loginURL?.host ?? "nil") plan=\(bPlan)")

        // 2. B 那邊授權完成：A 的分頁標「完成」（頁面關掉、不再算敏感；分頁留著、使用者自己關）；關掉完成的分頁不取消任何東西。
        b.runner.authorize.set(true)
        let finished = await pump { ctlA.loginWork[bID] == .done("已登入") }
        let marked = await waitUntil(5) { dm.loginTab?.done == true }
        let page = dm.host.pages.first
        let keptDone = marked && dm.loginTab?.pageClosed == true && page?.closes == 1 && !dm.browser.isSensitive && dm.store.isBrowsing
        dm.closeLoginTab()
        let closedQuietly = dm.loginTab == nil && ctlA.loginWork[bID] == .done("已登入")
        check(finished && keptDone && closedQuietly,
              "W183 R8 整合 替別台登入完成：這台的授權分頁標「完成」（頁面關掉、不再算敏感；分頁留著、使用者自己關，關掉不取消任何東西）",
              "finished=\(finished) kept=\(keptDone) closed=\(closedQuietly) \(String(describing: ctlA.loginWork[bID]))")

        // 3. 再替 B 登入一次、還沒完成就關掉分頁＝請 B 取消這一輪（信箱 login_cancel）：B 的 cloudflared login 收掉、A 不再等。
        b.runner.authorize.set(false)
        let loginsBefore = b.runner.logins
        ctlA.loginCloudflare(for: bID)
        let reopened = await pump { dm.loginTab != nil && dm.loginPageReady && b.runner.logins > loginsBefore }
        dm.closeLoginTab()
        let cancelled = await pump { ctlA.loginWork[bID] == .idle && !b.setup.isBusy }
        check(reopened && cancelled && dm.loginTab == nil && dm.host.pages.last?.closes == 1,
              "W183 R8 整合 替別台登入時還沒完成就關掉授權分頁＝請那台取消這一輪（信箱 login_cancel；那台的 cloudflared login 收掉、這台不再等）",
              "reopened=\(reopened) cancelled=\(cancelled) \(String(describing: ctlA.loginWork[bID])) busy=\(b.setup.isBusy)")

        // 4. 「套用」帶子網域草稿：照看到的版本先存（CAS）。
        _ = try fleet.update([.zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        let seen = await pump { ctlA.config?.zoneID == zoneID && ctlA.authorized(bID) }
        let revision = fleet.store.load()?.configRevision ?? 0
        let commandsBefore = b.runner.nonLogin.count
        // 4a. 主設備存不成（真的存檔失敗）：停在那裡——設定沒變、B 沒有收到套用、一句話留在面板。
        fleet.store.failSavesForTesting = true
        ctlA.applyURLs(saving: [.subdomain(device: bID, label: "os-for-chatgpt-renamed")], expected: revision)
        let refused = await waitUntil(5) { ctlA.actionProblem != nil }
        _ = await pump { ctlA.applyWork[bID] != .running("存網址…") }
        fleet.store.failSavesForTesting = false
        let notSaved = refused && ctlA.actionProblem == HandsBuildConfigError.notSaved.plain && fleet.store.load()?.configRevision == revision
            && b.runner.nonLogin.count == commandsBefore && ctlA.applyWork[bID] != .running("等那台拿到新網址…")
        check(seen && notSaved,
              "W183 R8 整合 套用帶子網域草稿：主設備存不成（真的存檔失敗）＝停在那裡（設定沒變、那台沒收到套用、不建通道、不改 DNS；一句話留在面板）",
              "seen=\(seen) problem=\(ctlA.actionProblem ?? "nil") revision=\(fleet.store.load()?.configRevision ?? -1) commands=\(b.runner.nonLogin.count - commandsBefore)")
        // 4b. 看到的版本舊了（別處改過）：不存、不套用。
        ctlA.applyURLs(saving: [.subdomain(device: bID, label: "os-for-chatgpt-renamed")], expected: revision - 1)
        let stale = await waitUntil(5) { ctlA.actionProblem?.contains("設定剛被改過") == true }
        check(stale && fleet.store.load()?.configRevision == revision && fleet.store.load()?.entry(bID)?.subdomain != "os-for-chatgpt-renamed"
              && b.runner.nonLogin.count == commandsBefore,
              "W183 R8 整合 套用帶子網域草稿：看到的版本舊了（別處剛改過）＝不存、不套用（CAS，請你再看一次）", ctlA.actionProblem ?? "nil")
        // 4c. 照看到的版本存好之後，等 B 拿到新的那一版才送套用：B 照新子網域建（B 用自己已接受的那一份拍快照）。
        ctlA.applyURLs(saving: [.subdomain(device: bID, label: "os-for-chatgpt-renamed")], expected: revision)
        let applied = await pump { b.runner.nonLogin.count > commandsBefore && !b.setup.isBusy }
        let saved = fleet.store.load()?.entry(bID)?.subdomain == "os-for-chatgpt-renamed" && (fleet.store.load()?.configRevision ?? 0) > revision
        let usedNew = b.service.settings.load().subdomainLabel == "os-for-chatgpt-renamed"
        let notStale = ctlA.applyWork[bID] != .failed(HandsBuildController.refusalText("config_changed"))
        check(applied && saved && usedNew && notStale,
              "W183 R8 整合 套用帶子網域草稿：照看到的版本存好、等那台拿到新的那一版才送「套用」（那台照新子網域建，不是舊的那一份）",
              "applied=\(applied) saved=\(saved) label=\(b.service.settings.load().subdomainLabel ?? "nil") work=\(String(describing: ctlA.applyWork[bID]))")

        // 5. 每台回報確認過的連線數：暫時的（還沒確認）不算；舊版沒回報這個欄位＝不當已連線；不超過全部。
        var report = HandsBuildDeviceReport(deviceID: bID)
        report.grants = 2
        report.confirmedGrants = 1
        let round = HandsBuildDeviceReport(wire: try Fleet.wire(report.wire))
        let old = HandsBuildDeviceReport(wire: ["device_id": bID, "grants": 2])
        let clamped = HandsBuildDeviceReport(wire: ["device_id": bID, "grants": 2, "confirmed_grants": 9])
        _ = try b.service.updateSettings { $0.publicHost = "os-for-chatgpt-renamed.example.com"; $0.hostDeviceID = bID; $0.enabled = true }
        b.phase.set(.running(url: "https://os-for-chatgpt-renamed.example.com/mcp"))
        var paired = false
        do { _ = try pair(b.service, host: "os-for-chatgpt-renamed.example.com"); paired = true }
        catch { check(false, "W183 R8 整合 自測：B 配對一筆連線", String(describing: error)) }
        var connected = false
        if paired { connected = await pump { ctlA.devices.first { $0.id == bID }?.connection == .done } }
        check(round?.confirmedGrants == 1 && old?.confirmedGrants == nil && clamped?.confirmedGrants == 2 && connected && ctlA.confirmedGrants(bID) == 1,
              "W183 R8 整合 每台回報確認過的連線數：確認過的才算已連線（暫時的不算；舊版沒回報＝不當已連線；不超過全部）",
              "round=\(String(describing: round?.confirmedGrants)) old=\(String(describing: old?.confirmedGrants)) connected=\(connected)")
    }
}
#endif
