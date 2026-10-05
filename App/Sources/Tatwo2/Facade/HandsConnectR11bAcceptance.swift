#if DEBUG
import Foundation

// W183 R11 第二輪自測（w183connect；完整隔離的 staging，不開通道、不上網）：GPT-6 R11 審查的反例——每一條都寫成「退步時會失敗」的樣子。
// 1（高）遷移不能讓收窄過的舊 L2 grant 恢復：主機在中央等級生效之前先封頂（HandsService.levelGuard）。R10 的樣子（grant L2、本機設定 L1、
//   沒有封頂檔）→ 遷移成 L2：舊 token 照舊 L1；reconcile 先寫本機設定也一樣；重開 App 也一樣；新的連線才 L2；封頂存不進去＝全部撤銷。
// 2（高）確認卡顯示帳號 A、中途登出：按原卡＝回到確認卡（不自動接著連 B）；本來就沒登入按的，登入之後才自動接著、進度卡看得到登入的帳號。
// 3、4、5（中）每台的判定（HandsConnectVerdict）：目前帳號的那一條在不在；剛連上的樂觀只到期限或新的回報；撤銷、停了優先；舊版主機＝能力未確認。
// 6（中）［斷線］逐台：斷了的馬上不算連著、沒斷的留著（卡片照實說），再按只重試沒斷的。
// 正式 controller 的三條撤銷路（本機、主設備 RPC、信箱）與入口對著真的回報：w183build 的 HandsBuildR11Acceptance（GPT-6 R11 審查 7）。

extension HandsConnectAcceptance {
    @MainActor static func r11bChecks(_ check: Checker, _ base: URL) async throws {
        try r11bLevelGuard(check, base)
        r11bVerdicts(check)
        try await r11bLoginAccount(check, base)
        try await r11bFlowOutcomes(check, base)
        try await r11bUnconfirmedCard(check, base)   // W183 R11 第二輪（GPT-6 R11b 審查 4）
        try await r11cCardRecovery(check, base)      // W183 R11 最後一輪（GPT-6 R11c 審查 4）
    }

    /// 讀 `{"level": N}` 那種小檔（封頂檔、待完成的上限）；沒有＝nil。
    static func r11bLevelFile(_ url: URL) -> Int? {
        guard let data = HandsFiles.readSecure(url, limit: 4096),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["level"] as? NSNumber)?.intValue
    }

    // MARK: 1. 遷移不讓收窄過的舊 L2 grant 恢復

    @MainActor static func r11bLevelGuard(_ check: Checker, _ base: URL) throws {
        func pairHere(_ service: HandsService) throws -> String {
            let chatgpt = FakeChatGPT(service: service)
            try chatgpt.register()
            try service.startPairing()
            _ = chatgpt.begin()
            return try chatgpt.token(try chatgpt.submit(service.auth.pendingCard?.pairingCode ?? ""))
        }
        func tools(_ service: HandsService, _ access: String) -> (level: Int?, names: Set<String>) {
            let result = try? service.handle(method: "hands_tools", params: ["access_token": access])
            return (result?["level"] as? Int, Set((result?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }))
        }
        func grantLevel(_ service: HandsService, _ access: String) -> Int? {
            service.auth.grant(forAccess: access).flatMap { service.auth.grantRecord($0.grantID) }?.level
        }
        /// R10 的樣子：中央 L2 的時候連上一筆 L2，之後中央收窄成 L1——R10 的 reconcile 把本機設定寫成 1、只停工作鎖工作區，grant 紀錄還是 L2；
        /// 沒有封頂檔（R10 沒有這個檔）。這裡用沒接中央的世界做出這個樣子（scopeCap nil＝不封頂）。
        func r10State(_ name: String) throws -> (ScopeFixture, HandsService, String) {
            let fx = try scopeFixture(base, name)
            let (service, _) = try scopeHost(base, name, fx)
            _ = try service.updateSettings { $0.level = 2 }
            let access = try pairHere(service)
            _ = try service.updateSettings { $0.level = 1 }
            return (fx, service, access)
        }

        // 1a. 更新成 R11、中央遷移成 L2（信封一到就生效），第一個用到的是 ChatGPT 的呼叫。
        let (fx, service, access) = try r10State("r11b-guard")
        let seeded = grantLevel(service, access)
        let noFile = !FileManager.default.fileExists(atPath: service.levelWatermarkURL.path)
        service.scopeCap = { (level: 2, projects: []) }
        let first = tools(service, access)
        check(seeded == 2 && noFile && first.level == 1 && !first.names.contains("open_workspace") && !first.names.contains("run_command")
              && first.names.contains("memory_inbox_save") && grantLevel(service, access) == 1,
              "W183 R11 第二輪（GPT-6 R11 審查 1 反例）L2 grant → 中央 L1 → 遷移成 L2：舊的 token 照舊只有 L1（工具清單沒有 Codex 的、grant 紀錄封頂成 L1）",
              "seeded=\(String(describing: seeded)) level=\(String(describing: first.level)) names=\(first.names.count)")
        // 1b. 新的連線（按［連線］看過確認卡）才拿到 L2。
        let fresh = try pairHere(service)
        let second = tools(service, fresh)
        check(second.level == 2 && second.names.contains("open_workspace") && tools(service, access).level == 1,
              "W183 R11 第二輪 遷移之後新的連線（看過確認卡）＝L2（Codex、記憶）；舊的那一條照舊 L1", "fresh=\(String(describing: second.level))")
        // 1c. 重開 App（新的 HandsService、同一份檔案）：封頂是寫進授權檔的。
        // W183 R11 最後一輪：正式的 reconcile 會在遷移之後把中央的 L2 寫進本機設定（1d 就是這一步）；這裡照做再重開——
        // 重開 App 時本機設定比封頂檔低＝先照較低的封頂（GPT-6 R11c 審查 2 的補救，見 1h），不寫這一步新的 L2 會被當成要補救。
        _ = try service.updateSettings { $0.level = 2 }
        let reopened = HandsService(paths: service.paths)
        reopened.deviceIDOverride = hostID
        fx.configure(reopened)
        reopened.scopeCap = { (level: 2, projects: []) }
        check(tools(reopened, access).level == 1 && tools(reopened, fresh).level == 2,
              "W183 R11 第二輪 重開 App 之後：舊的照舊 L1、新的照舊 L2（封頂寫進授權檔）")

        // 1d. reconcile 先把新的中央等級寫進本機設定（任何呼叫都還沒用到新等級）：寫之前就照改之前的本機等級封頂。
        let (_, raced, racedAccess) = try r10State("r11b-guard-race")
        raced.scopeCap = { (level: 2, projects: []) }
        _ = try raced.updateSettings { $0.level = 2 }   // reconcile 那一步
        check(raced.settings.load().level == 2 && tools(raced, racedAccess).level == 1 && grantLevel(raced, racedAccess) == 1,
              "W183 R11 第二輪 reconcile 先寫本機設定（遷移的 L2）：寫之前就封頂——舊的 token 照舊 L1（退步＝寫完才看本機，會變 L2）")

        // 1e. R11 之後（中央管的）：收窄＝grant 跟著降；之後再調高（面板、遷移）也回不去。
        let fx2 = try scopeFixture(base, "r11b-guard-central")
        let (central, _) = try scopeHost(base, "r11b-guard-central", fx2)
        central.scopeCap = { (level: 2, projects: []) }
        let wide = try pairHere(central)
        let before = tools(central, wide).level
        central.scopeCap = { (level: 1, projects: []) }
        let lowered = tools(central, wide).level
        central.scopeCap = { (level: 2, projects: []) }
        let raisedAgain = tools(central, wide).level
        check(before == 2 && lowered == 1 && raisedAgain == 1 && grantLevel(central, wide) == 1,
              "W183 R11 第二輪 中央收窄＝grant 也降（寫進授權檔）；之後再調高也回不去（要按［連線］重新同意）",
              "before=\(String(describing: before)) lowered=\(String(describing: lowered)) raised=\(String(describing: raisedAgain))")

        // 1f. 封頂存不進去＝跟撤銷一樣 fail closed（全部撤銷、刪授權檔）：不會多拿。
        let (_, failing, failingAccess) = try r10State("r11b-guard-fail")
        failing.auth.failSavesForTesting = true
        failing.scopeCap = { (level: 2, projects: []) }
        let refused = tools(failing, failingAccess).level == nil
        failing.auth.failSavesForTesting = false
        check(refused && failing.auth.activeGrantIDs.isEmpty && failing.auth.revocationProblem != nil,
              "W183 R11 第二輪 封頂存不進去：全部撤銷、刪授權檔（舊的 token 被拒，不會用新的等級）")

        // 1g.（GPT-6 R11b 審查 2 反例）封頂存不進去、授權檔也刪不掉（例如被鎖住：自測只模擬刪不掉，不設不可變旗標）：磁碟上還是舊的 L2。
        // 不記下新的等級、留下跨重啟的待完成上限、本機等級不往上改、這段期間一律不收；重開 App（磁碟還壞）照樣不收；磁碟好了＝先封頂才收。
        let (fxStuck, stuck, stuckAccess) = try r10State("r11b-guard-stuck")
        stuck.auth.failSavesForTesting = true
        stuck.auth.failRemovesForTesting = true
        stuck.scopeCap = { (level: 2, projects: []) }
        let stuckRefused = tools(stuck, stuckAccess).level == nil
        let advanced = r11bLevelFile(stuck.levelWatermarkURL) == 2
        let marked = r11bLevelFile(stuck.levelCapPendingURL) == 1
        var raiseRefused = false
        do { _ = try stuck.updateSettings { $0.level = 2 } } catch { raiseRefused = true }   // reconcile 那一步
        check(stuckRefused && !advanced && marked && raiseRefused && stuck.settings.load().level == 1,
              "W183 R11 第二輪（GPT-6 R11b 審查 2 反例）封頂存不進去、授權檔也刪不掉：一律不收、不記下新的等級（封頂檔不是 L2）、留下待完成的上限 L1、本機等級不往上改",
              "refused=\(stuckRefused) advanced=\(advanced) marked=\(marked) raiseRefused=\(raiseRefused)")
        func reopen(broken: Bool) -> HandsService {
            let service = HandsService(paths: stuck.paths)
            service.deviceIDOverride = hostID
            fxStuck.configure(service)
            service.auth.failSavesForTesting = broken
            service.auth.failRemovesForTesting = broken
            service.scopeCap = { (level: 2, projects: []) }
            return service
        }
        let brokenAgain = reopen(broken: true)
        let stillRefused = tools(brokenAgain, stuckAccess).level == nil
        brokenAgain.scopeCap = nil
        let healed = reopen(broken: false)
        let healedLevel = tools(healed, stuckAccess).level
        check(stillRefused && healedLevel == 1 && r11bLevelFile(healed.levelCapPendingURL) == nil && r11bLevelFile(healed.levelWatermarkURL) == 2,
              "W183 R11 第二輪（GPT-6 R11b 審查 2 反例）重開 App：磁碟還壞＝照樣先封頂、還是存不進去＝一律不收（舊的 L2 不會回來）；磁碟好了＝先照待完成的上限封頂、存好了才收——舊的 token 照舊 L1、標記清掉",
              "stillRefused=\(stillRefused) healed=\(String(describing: healedLevel))")
        // 1h.（GPT-6 R11c 審查 2 反例：標記寫入失敗＋既有封頂檔＋中央等級來回＋重開）已經有封頂檔 L2、一筆 L2 的連線；中央收窄成 L1 的時候
        // 封頂存不進去、授權檔刪不掉、待完成的標記也寫不進去（三重失敗）＝這段期間一律不收、磁碟上的封頂檔不清；reconcile 把本機設定寫成 L1；
        // 中央又調回 L2＝本機等級不往上改。重開 App（磁碟好了、中央 L2）：封頂檔（L2）比本機設定（L1）高＝先照較低的 L1 封頂——舊的 token 照舊 L1。
        let fx3 = try scopeFixture(base, "r11c-guard-triple")
        let (triple, _) = try scopeHost(base, "r11c-guard-triple", fx3)
        triple.scopeCap = { (level: 2, projects: []) }
        _ = try triple.updateSettings { $0.level = 2 }   // reconcile 寫進本機（中央 L2）
        let tripleAccess = try pairHere(triple)
        let tripleWide = tools(triple, tripleAccess).level == 2 && r11bLevelFile(triple.levelWatermarkURL) == 2
        triple.auth.failSavesForTesting = true
        triple.auth.failRemovesForTesting = true
        triple.failCapMarkerWritesForTesting = true
        triple.scopeCap = { (level: 1, projects: []) }   // 中央收窄
        let tripleRefused = tools(triple, tripleAccess).level == nil
        let noMarker = r11bLevelFile(triple.levelCapPendingURL) == nil
        let keptWatermark = r11bLevelFile(triple.levelWatermarkURL) == 2
        let markerProblem = triple.capMarkerProblem != nil
        _ = try? triple.updateSettings { $0.level = 1 }   // reconcile 寫本機（設定檔本身寫得進去）
        triple.scopeCap = { (level: 2, projects: []) }   // 中央又調回 L2
        var tripleRaiseRefused = false
        do { _ = try triple.updateSettings { $0.level = 2 } } catch { tripleRaiseRefused = true }   // reconcile 那一步
        let tripleStillRefused = tools(triple, tripleAccess).level == nil
        check(tripleWide && tripleRefused && noMarker && keptWatermark && markerProblem && tripleRaiseRefused && tripleStillRefused
              && triple.settings.load().level == 1,
              "W183 R11 最後一輪（GPT-6 R11c 審查 2 反例）封頂、刪授權檔、寫待完成標記都失敗：這段期間一律不收、磁碟上的封頂檔（L2）不清；中央調回 L2＝本機等級不往上改",
              "wide=\(tripleWide) refused=\(tripleRefused) noMarker=\(noMarker) kept=\(keptWatermark) problem=\(markerProblem) raise=\(tripleRaiseRefused)")
        triple.scopeCap = nil
        let restarted = HandsService(paths: triple.paths)
        restarted.deviceIDOverride = hostID
        fx3.configure(restarted)
        restarted.scopeCap = { (level: 2, projects: []) }
        let restartedLevel = tools(restarted, tripleAccess).level
        check(restartedLevel == 1 && grantLevel(restarted, tripleAccess) == 1 && restarted.effectiveSettings().level == 2,
              "W183 R11 最後一輪（GPT-6 R11c 審查 2 反例）重開 App（沒有待完成標記、封頂檔 L2、中央 L2）：本機設定是 L1＝先照較低的 L1 封頂——舊的 token 照舊 L1，不會回到 L2",
              "level=\(String(describing: restartedLevel))")
        restarted.scopeCap = nil

        // 1i.（GPT-6 R11c 審查 2 反例：enabled 與 level 一起改）封頂還沒做完的時候，同一次改動又關掉又調高等級＝照調高的規則擋
        //（整次不收：本機等級不會連帶存成較高的）；單純關掉照樣可以。
        let (_, combo, comboAccess) = try r10State("r11c-guard-combo")
        combo.auth.failSavesForTesting = true
        combo.auth.failRemovesForTesting = true
        combo.scopeCap = { (level: 2, projects: []) }
        let comboRefused = tools(combo, comboAccess).level == nil   // 封頂存不進去：待完成 L1
        var comboBlocked = false
        do { _ = try combo.updateSettings { $0.enabled = false; $0.level = 2 } } catch { comboBlocked = true }
        let comboKept = combo.settings.load().level == 1 && combo.settings.load().enabled
        _ = try? combo.updateSettings { $0.enabled = false }   // 單純關掉（撤銷存不進去會另外報錯；設定照樣關）
        let offOnly = !combo.settings.load().enabled && combo.settings.load().level == 1
        check(comboRefused && comboBlocked && comboKept && offOnly && combo.levelCapPending == 1,
              "W183 R11 最後一輪（GPT-6 R11c 審查 2 反例）封頂還沒做完：又關掉又調高＝整次不收（本機還是 L1、還開著）；單純關掉照樣關得掉（等級不動）",
              "blocked=\(comboBlocked) kept=\(comboKept) off=\(offOnly)")
        combo.scopeCap = nil

        healed.scopeCap = nil
        stuck.scopeCap = nil
        central.scopeCap = nil
        service.scopeCap = nil
        reopened.scopeCap = nil
        raced.scopeCap = nil
        failing.scopeCap = nil
    }

    // MARK: 3、4、5. 每台的判定（純資料）

    static func r11bVerdicts(_ check: Checker) {
        typealias V = HandsConnectVerdict
        let now = Date()
        let up: TimeInterval = 50_000   // 這台的單調時鐘（任意的起點）
        let tagA = HandsConnectAccounts.identityTag("u=user-a|w=|e=mail-a")
        let tagB = HandsConnectAccounts.identityTag("u=user-b|w=|e=mail-b")
        let grant = HandsBuildDeviceReport.grantTag("grant-a")
        // W183 R11 最後一輪（GPT-6 R11c 審查 4）：紀錄帶連上那一刻的單調時鐘與主機確認的授權狀態版本；回報帶取樣時的版本。
        let settled = HandsConnectAccountRecord(host: hostID, identityTag: tagA, grantTag: grant, level: 2, at: now.addingTimeInterval(-600),
                                                uptime: up - 600, grantVersion: 3)
        var serving = HandsConnectHostEvidence(fresh: true, serving: true, confirmedGrants: 1, grantLevels: [grant: 2], receivedAt: now, actualLevel: 2)
        serving.grantsVersion = 5
        func of(_ evidence: HandsConnectHostEvidence?, _ tag: String?, _ records: [HandsConnectAccountRecord], at: Date = now,
                uptime: TimeInterval = up) -> V {
            V.of(host: hostID, evidence: evidence, identityTag: tag, records: records, now: at, uptime: uptime)
        }
        var narrowed = serving
        narrowed.actualLevel = 1
        check(of(serving, tagA, [settled]) == .connected(level: 2) && of(serving, tagB, [settled]) == .open && of(serving, nil, [settled]) == .open
              && of(serving, tagA, []) == .open && of(narrowed, tagA, [settled]) == .connected(level: 1),
              "W183 R11 第二輪（GPT-6 R11 審查 4 反例）主機上是帳號 A 的連線：目前是 A＝已連線；目前是 B、帳號讀不到、這台沒記過＝給［連線］（不拿別的帳號的連線說目前帳號已連上）；中央收窄＝等級跟著")
        var revoked = serving
        revoked.grantLevels = [:]
        revoked.confirmedGrants = 0
        revoked.grantsVersion = 6   // 取樣比連線確認（3）新、卻沒有這一條
        var stopped = serving
        stopped.serving = false
        var stale = serving
        stale.fresh = false
        stale.serving = false
        check(of(revoked, tagA, [settled]) == .ended(.revoked) && of(stopped, tagA, [settled]) == .ended(.stopped) && of(stale, tagA, [settled]) == .open
              && of(nil, tagA, [settled]) == .open,
              "W183 R11 第二輪（GPT-6 R11 審查 3）新的回報優先：那一條在別處撤銷了＝不在了；那台停了、暫停、安全鎖＝不在了；回報太舊、沒有回報＝核對不了（不說斷、也不說連著）")
        // 剛連上（連線確認的版本 7）：
        let young = HandsConnectAccountRecord(host: hostID, identityTag: tagA, grantTag: HandsBuildDeviceReport.grantTag("grant-new"), level: 2, at: now,
                                              uptime: up, grantVersion: 7)
        var earlier = revoked
        earlier.grantsVersion = 6            // 連上之前取樣的回報（還沒有這一條）
        var later = revoked
        later.grantsVersion = 8              // 連上之後取樣的回報（沒有這一條）
        var stoppedLater = stopped
        stoppedLater.grantsVersion = 7       // 連上之後（沒有別的授權變動）取樣：那台停了
        check(of(earlier, tagA, [young], at: now.addingTimeInterval(10), uptime: up + 10) == .connected(level: 2)
              && of(earlier, tagA, [young], at: now.addingTimeInterval(V.optimism + 1), uptime: up + V.optimism + 1) == .open
              && of(later, tagA, [young], at: now.addingTimeInterval(1), uptime: up + 1) == .ended(.revoked)
              && of(stoppedLater, tagA, [young], at: now.addingTimeInterval(1), uptime: up + 1) == .ended(.stopped),
              "W183 R11 第二輪（GPT-6 R11 審查 3 反例）剛連上只樂觀到期限：回報還沒跟上＝期限內算連著、過了期限＝不再算；連上之後取樣的回報沒有它＝不在了（不用等）；那台停了＝馬上不算（不等期限）")
        // W183 R11 最後一輪（GPT-6 R11c 審查 4 反例：延遲快照）：連上之前取樣的回報（沒有這一條、或說停了）晚了 20 秒才送到——
        // 收件時間在連線之後很久，照樣不算撤銷、不算停了（看取樣的版本，不看收件的牆上時間）。
        var delayed = earlier
        delayed.receivedAt = now.addingTimeInterval(20)
        var delayedStopped = stopped
        delayedStopped.grantsVersion = 6
        delayedStopped.receivedAt = now.addingTimeInterval(20)
        check(of(delayed, tagA, [young], at: now.addingTimeInterval(25), uptime: up + 25) == .connected(level: 2)
              && of(delayedStopped, tagA, [young], at: now.addingTimeInterval(25), uptime: up + 25) == .connected(level: 2)
              && of(delayed, tagA, [young], at: now.addingTimeInterval(V.optimism + 5), uptime: up + V.optimism + 5) == .open,
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）延遲快照：連上之前取樣、連上之後 20 秒才送到的回報（沒有這一條／說停了）＝不算撤銷、不算停了（期限內算連著，之後「未確認」）")
        // 雙邊各自跳鐘（GPT-6 R11c 審查 4 反例）：
        // - 這台的牆上時鐘倒退：連線紀錄 1000、現在 900（單調時鐘只走了 30 秒）＝不再算「剛連上」；沒有這一條的新回報照版本判撤銷（不會因為倒退算成連線之前）。
        let back = now.addingTimeInterval(-100)
        var unversioned = earlier
        unversioned.grantsVersion = nil      // 比不了先後的回報（沒有這一條）
        check(of(later, tagA, [young], at: back, uptime: up + 30) == .ended(.revoked) && of(unversioned, tagA, [young], at: back, uptime: up + 30) == .open
              && !V.young(young, now: back, uptime: up + 30),
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）這台的鐘倒退（連線紀錄在「未來」）：不再算剛連上；新的回報沒有這一條＝照版本判撤銷；比不了先後＝未確認（都不會變成已連線）")
        // - 這台的牆上時鐘往前大跳（單調時鐘只走 30 秒、牆上走了一小時）＝不算剛連上；比不了先後＝未確認。
        let ahead = now.addingTimeInterval(3600)
        check(of(unversioned, tagA, [young], at: ahead, uptime: up + 30) == .open && of(earlier, tagA, [young], at: ahead, uptime: up + 30) == .open,
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）這台的鐘往前大跳：不算剛連上（沒有證據的就「未確認」，不當成已連線）")
        // - 時鐘剛跳過（這台拿到全貌之後、或主設備）＝這份回報一律「未確認」：有這一條也不說已連線，沒有也不說撤銷、停了。
        var suspectHas = serving
        suspectHas.clockSuspect = true
        var suspectGone = later
        suspectGone.clockSuspect = true
        var suspectStopped = stoppedLater
        suspectStopped.clockSuspect = true
        check(of(suspectHas, tagA, [settled]) == .open && of(suspectGone, tagA, [young], at: now.addingTimeInterval(1), uptime: up + 1) == .open
              && of(suspectStopped, tagA, [young], at: now.addingTimeInterval(1), uptime: up + 1) == .open
              && !V.proves(host: hostID, evidence: suspectHas, identityTag: tagA, records: [settled])
              && V.proves(host: hostID, evidence: serving, identityTag: tagA, records: [settled]),
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）時鐘剛跳過：這份回報不說已連線、也不說撤銷或停了（一律「未確認」）；也不拿它證明卡片可以恢復")
        // 重開機（單調時鐘歸零、比連線那一刻小）＝不算剛連上。
        check(of(earlier, tagA, [young], at: now.addingTimeInterval(5), uptime: 10) == .open,
              "W183 R11 最後一輪 單調時鐘比連線那一刻小（重開機過）＝不算剛連上（未確認）")
        var legacy = serving
        legacy.grantLevels = nil
        legacy.grantsVersion = nil
        var legacyEmpty = legacy
        legacyEmpty.confirmedGrants = 0
        legacyEmpty.receivedAt = now.addingTimeInterval(20)
        // W183 R11 最後一輪（GPT-6 R11c 審查 4）：舊版主機的回報沒有可以比的版本＝不推定撤銷（原本「連上之後一條都沒有＝不在了」改成這樣）。
        check(of(legacy, tagA, [young], at: now.addingTimeInterval(5), uptime: up + 5) == .connected(level: nil) && of(legacy, tagA, [settled]) == .open
              && of(legacyEmpty, tagA, [young], at: now.addingTimeInterval(25), uptime: up + 25) == .connected(level: nil)
              && of(legacyEmpty, tagA, [young], at: now.addingTimeInterval(V.optimism + 5), uptime: up + V.optimism + 5) == .open,
              "W183 R11 第二輪（GPT-6 R11 審查 5 反例）舊版主機（回報沒有逐筆等級）：剛連上＝已連線・能力未確認（不推定 L2）；過了期限核對不了＝給［連線］；W183 R11 最後一輪：沒有可以比的版本＝不推定撤銷（期限內算連著、之後「未確認」）")
    }

    // MARK: 2. 確認卡上是帳號 A、中途登出：不自動接著連 B

    @MainActor static func r11bLoginAccount(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r11b-login-switch")
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        let shownA: Bool = { if case .confirm(_, let account)? = world.flow.card { return account == Self.account }; return false }()
        // 還沒按：Pod 登出（session 失效）。使用者按的是原本那張寫著 A 的卡。
        world.pod.readiness = .needsLogin
        world.flow.connect()
        let backToCard = await waitUntil(5) {
            if case .confirm(_, let account)? = world.flow.card { return account == nil && world.flow.problem == HandsConnectFlow.loggedOutNote }
            return false
        }
        // 在框裡登入的是 B：不會自己接著連（沒有獨占 Pod、沒有建立連接器、主機的配對窗口沒開）。
        world.pod.readiness = .ready(account: "Other Account")
        world.pod.identityValue = "u=user-other|w=|e=mail-other"
        try? await Task.sleep(nanoseconds: 2_600_000_000)
        let stayed = isConfirm(world.flow.card)
        let untouched = !world.pod.calls.contains("exclusive") && !world.pod.calls.contains("create") && world.service.auth.windowExpiresAt == nil
        check(shownA && backToCard && stayed && untouched,
              "W183 R11 第二輪（GPT-6 R11 審查 2 反例）確認卡是帳號 A、按之前 Pod 登出：按原卡＝回到確認卡（沒登入的樣子）；之後登入 B 也不會自己接著建連接器、開窗口",
              "calls=\(world.pod.calls) card=\(String(describing: world.flow.card))")
        // 換帳號（沒登出、直接換成 B）：按原卡＝回到確認卡、寫著 B（照舊）。
        world.flow.cancel(reason: "test_done")
        world.pod.readiness = .ready(account: Self.account)
        world.pod.identityValue = Self.identity
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.pod.readiness = .ready(account: "Other Account")
        world.flow.connect()
        let showsB = await waitUntil(5) {
            if case .confirm(_, let account)? = world.flow.card { return account == "Other Account" }
            return false
        }
        check(showsB && !world.pod.calls.contains("create"), "W183 R11 第二輪 確認卡是 A、按之前換成 B：回到確認卡、寫著 B（再按一次才連）")
        world.flow.cancel(reason: "test_done")

        // 本來就沒登入：按下去＝登入之後自動接著連，進度卡上看得到登入的是哪個帳號（不回到確認卡）。
        let fresh = try World(base, "r11b-login-fresh")
        fresh.pod.readiness = .needsLogin
        let freshGPT = FakeChatGPT(service: fresh.service)
        fresh.chatgptStarts(freshGPT)
        fresh.flow.offer()
        _ = await waitUntil(5) { isConfirm(fresh.flow.card) }
        fresh.flow.connect()
        _ = await waitUntil(5) { if case .waitingUser? = fresh.flow.card { return true }; return false }
        fresh.pod.readiness = .ready(account: "Other Account")
        fresh.pod.identityValue = "u=user-other|w=|e=mail-other"
        let continued = await waitUntil(8) { fresh.pod.calls.contains("exclusive") }
        let context = HandsConnectCardContext.live(fresh.flow, revealsCode: false)
        check(continued && fresh.flow.attemptAccount == "Other Account" && context.account == "Other Account",
              "W183 R11 第二輪（GPT-6 R11 審查 2）本來就沒登入按的：登入之後自動接著連；進度卡上寫著登入的那個帳號",
              "account=\(String(describing: fresh.flow.attemptAccount)) calls=\(fresh.pod.calls)")
        fresh.flow.cancel(reason: "test_done")
    }

    // MARK: 4（R11b）. 核對不了的已連線卡＝「連線狀態未確認」

    @MainActor static func r11bUnconfirmedCard(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r11b-unconfirmed")   // 這個世界沒接撤銷（［斷線］＝沒做成）
        world.flow.showConnected(hosts: [hostID], level: 2)
        world.flow.connectionChanged(ended: [], ending: nil, level: 2, unconfirmed: [hostID])
        let unsure: Bool = { if case .unconfirmed(let text)? = world.flow.card { return text == HandsConnectFlow.unconfirmedStatusText }; return false }()
        let face = world.flow.card.map { HandsConnectCardFace.make($0, phase: world.flow.phase) }
        let noClaims = face.map { !$0.line.contains("Codex") && !$0.line.contains("記憶") && !$0.title.contains("已連線") && $0.actions == [.disconnect] } ?? false
        world.flow.disconnect()   // 沒斷成：放回「狀態未確認」，不會因為沒斷成就又說已連線
        let kept = await waitUntil(3) {
            guard !world.flow.disconnecting else { return false }
            if case .unconfirmed? = world.flow.card { return true }
            return false
        }
        world.flow.connectionChanged(ended: [], ending: nil, level: 2, unconfirmed: [])   // 新的回報核對得到
        let back: Bool = { if case .connected(let text)? = world.flow.card { return text == HandsConnectFlow.connectedText(level: 2) }; return false }()
        check(unsure && noClaims && kept && back && !HandsConnectPresenter.inProcess(.unconfirmed("x")),
              "W183 R11 第二輪（GPT-6 R11b 審查 4）已連線卡上的那台核對不了：卡片改成「連線狀態未確認」、不寫 Codex／記憶、［斷線］留著；沒斷成照舊是「未確認」；核對得到＝回到「已連線：Codex、記憶」",
              "card=\(String(describing: world.flow.card)) face=\(String(describing: face))")
        world.flow.dismiss()
    }

    // MARK: 4（R11c）. 推斷斷了之後，新的回報證明還連著＝卡片恢復

    @MainActor static func r11cCardRecovery(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r11c-recover")
        world.flow.showConnected(hosts: [hostID], level: 2)
        world.flow.connectionChanged(ended: [hostID], ending: .revoked, level: 2)   // 入口推斷：在別處撤銷了
        let ended: Bool = { if case .disconnected(let text)? = world.flow.card { return text == HandsConnectFlow.endedElsewhereText }; return false }()
        let watched = world.flow.watchedHostIDs == [hostID]
        world.flow.connectionChanged(ended: [], ending: nil, level: 2, unconfirmed: [hostID])   // 核對不了（不是證明）：不恢復
        let stillEnded: Bool = { if case .disconnected? = world.flow.card { return true }; return false }()
        world.flow.connectionChanged(ended: [], ending: nil, level: 2, connected: [hostID])     // 新的回報證明還連著
        let back: Bool = { if case .connected(let text)? = world.flow.card { return text == HandsConnectFlow.connectedText(level: 2) }; return false }()
        let phaseBack = world.flow.phase == .connected && world.flow.connectedHostIDs == [hostID]
        check(ended && watched && stillEnded && back && phaseBack,
              "W183 R11 最後一輪（GPT-6 R11c 審查 4 反例）誤判「已斷線」之後：核對不了＝不動；新的回報證明卡上那台還連著＝卡片回到「已連線：Codex、記憶」（［斷線］照樣在）",
              "card=\(String(describing: world.flow.card)) phase=\(world.flow.phase)")
        // 使用者收起來的「已斷線」卡：之後的回報不再把它叫回來。
        world.flow.connectionChanged(ended: [hostID], ending: .stopped, level: 2)
        let stoppedCard: Bool = { if case .disconnected(let text)? = world.flow.card { return text == HandsConnectFlow.hostStoppedText }; return false }()
        world.flow.dismiss()
        world.flow.connectionChanged(ended: [], ending: nil, level: 2, connected: [hostID])
        check(stoppedCard && world.flow.card == nil && world.flow.watchedHostIDs.isEmpty,
              "W183 R11 最後一輪 收起來的「已斷線」卡：之後的回報不再把它叫回來（只看還開著的那一張）",
              "card=\(String(describing: world.flow.card))")
    }

    // MARK: 6. ［斷線］逐台：斷了的馬上不算、沒斷的留著、再按只重試沒斷的

    @MainActor static func r11bFlowOutcomes(_ check: Checker, _ base: URL) async throws {
        let other = "0B0B0B0B-0000-4000-8000-00000000000B".lowercased()
        let third = "0C0C0C0C-0000-4000-8000-00000000000C".lowercased()
        let calls = HandsLocked<[[String]]>([])
        let script = HandsLocked<[[String: HandsDisconnectOutcome]]>([
            [hostID.lowercased(): .revoked, other: .failed("Studio B：送不到主設備（ssh_tunnel_unavailable）"),
             third: .unknown("Laptop C：那台沒回覆（沒開？），不知道斷了沒有；再按一次斷線")],
            [other: .revoked, third: .revokedUnsaved("Laptop C：斷了，但那台的授權檔沒存成；之後要重新配對")],
        ])
        let accountsURL = base.appendingPathComponent("r11b-outcomes-accounts.json")
        let accounts = HandsConnectAccounts(url: accountsURL)
        let tag = HandsConnectAccounts.identityTag(Self.identity)
        for host in [hostID, other, third] {
            accounts.remember(HandsConnectAccountRecord(host: host, identityTag: tag, grantTag: nil, level: 2, at: Date()))
        }
        let world = try World(base, "r11b-outcomes", disconnect: { _, hosts in
            calls.update { $0.append(hosts) }
            var next: [String: HandsDisconnectOutcome] = [:]
            script.update { queue in if !queue.isEmpty { next = queue.removeFirst() } }
            return next
        }, accounts: accounts)
        world.flow.showConnected(hosts: [hostID, other, third], level: 2)
        world.flow.disconnect()
        let partial = await waitUntil(5) { !world.flow.disconnecting && world.flow.connectedHostIDs.count == 2 }
        let text: String? = { if case .connected(let value)? = world.flow.card { return value }; return nil }()
        let problem = world.flow.problem ?? ""
        let forgotten = accounts.records().map(\.host)
        check(partial && text == HandsConnectFlow.partialDisconnectText(cut: 1, left: 2) && world.flow.connectedHostIDs == [other, third]
              && problem.contains("Studio B：送不到主設備") && problem.contains("不知道斷了沒有") && forgotten.sorted() == [other, third].sorted()
              && world.flow.phase == .connected,
              "W183 R11 第二輪（GPT-6 R11 審查 6 反例）三台斷一台成：斷了的那台馬上不算連著（紀錄拿掉）；送不到的、不知道結果的分開照實說、留在卡上",
              "text=\(String(describing: text)) problem=\(problem) left=\(world.flow.connectedHostIDs)")
        world.flow.disconnect()   // 再按：只重試沒斷的兩台
        let done = await waitUntil(5) { if case .disconnected? = world.flow.card { return true }; return false }
        let retried = calls.get().last ?? []
        check(done && retried.sorted() == [other, third].sorted() && (world.flow.problem ?? "").contains("授權檔沒存成")
              && accounts.records().isEmpty && world.flow.phase == .idle,
              "W183 R11 第二輪 再按［斷線］只重試還沒斷的兩台；撤銷了但沒存成＝算斷了、照實說要重新配對；全部斷了＝「已斷線」卡",
              "retried=\(retried) problem=\(String(describing: world.flow.problem))")
        world.flow.dismiss()
        try? FileManager.default.removeItem(at: accountsURL)
    }
}
#endif
