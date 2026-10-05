#if DEBUG
import Foundation

/// W185：原生本機 apply 的行為測試，不是另一家引擎審查。
/// 重用 Fleet 的隔離 store、已驗章 slice、記憶體 secrets；所有 RPC 都是行程內 fake。
extension HandsBuildAcceptance {
    /// Fleet 原 runner 刻意讓 create 失敗；成功案例只換這個注入點，不更改產品行為。
    final class LocalApplyRunner: HandsCloudflaredRunning, @unchecked Sendable {
        let commands = HandsLocked<[[String]]>([])
        let hold = HandsLocked(false)
        static let tunnel = "18518518-5185-4185-8185-185185185185"

        func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL,
                   onLine: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand {
            commands.update { $0.append(arguments) }
            let command = FakeCommand(), hold = self.hold
            DispatchQueue.global().async {
                while hold.get() && !command.cancelled.get() { Thread.sleep(forTimeInterval: 0.01) }
                guard !command.cancelled.get() else { command.exited.set(true); onExit(nil); return }
                var code: Int32 = 0
                if arguments.contains("create"), let name = arguments.last {
                    onLine("{\"id\":\"\(Self.tunnel)\",\"name\":\"\(name)\"}")
                } else if arguments.contains("route"), let host = arguments.last {
                    onLine("Added CNAME \(host) which will route to this tunnel")
                } else if arguments.contains("token") {
                    onLine(String(repeating: "W185FixtureOnly", count: 4))
                } else if arguments.contains("list") {
                    onLine("[]")
                } else {
                    code = 9   // 不默許 fixture 沒有實作的指令，尤其 login。
                }
                command.exited.set(true)
                onExit(code)
            }
            return command
        }
    }

    @MainActor final class LocalApplyWorld {
        let fleet: Fleet
        let local: Device
        let other: Device
        let runner = LocalApplyRunner()
        let rpc: HandsLocked<[String]>
        let disconnected: HandsLocked<Bool>
        let role: HandsLocked<HandsBuildRole>

        init(_ base: URL, _ keys: Keys, accepted: Bool = true, selected: Bool = true, cert: Bool = true) throws {
            let fleet = try Fleet(base, keys: keys)
            self.fleet = fleet
            let rpc = HandsLocked<[String]>([]), disconnected = HandsLocked(false)
            let role = HandsLocked<HandsBuildRole>(.member(local: bID, primary: pID, epoch: 1))
            self.rpc = rpc
            self.disconnected = disconnected
            self.role = role
            _ = try fleet.update([.setEnabled(true), .select(device: aID, selected: true),
                                  .select(device: bID, selected: selected),
                                  .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
            local = try fleet.add(bID, name: "Local MacBook Fixture", callPrimary: { payload in
                rpc.update { $0.append(payload["op"] as? String ?? "?") }
                if disconnected.get() { throw RemoteHostLinkError.tunnelUnavailable }
                var response = try Fleet.wire(try HandsBuildRemote.handle(payload: try Fleet.wire(payload),
                                                                         sender: bID, authority: fleet.authority))
                if !accepted { response.removeValue(forKey: "envelope") }
                return response
            })
            other = try fleet.add(aID, name: "Other Selected Fixture")
            try fixtureAccount(local)
            if !cert {
                // 只移除 fixture 的 memory secret；帳號／網域紀錄仍在，確實測缺 cert。
                try local.secrets.remove(service: CloudflareKeychain.certService, account: CloudflareAccountsStore.certAccount(zoneID))
            }
            try fixtureAccount(other)
            let device = local, runner = self.runner
            var setupDeps = device.setup.dependencies
            setupDeps.runner = runner
            setupDeps.serviceTimeout = 2
            setupDeps.startService = {
                device.starts.update { $0 += 1 }
                let host = device.service.settings.load().publicHost ?? ""
                device.phase.set(.running(url: "https://\(host)/mcp"))
            }
            let setup = HandsSetup(dependencies: setupDeps)
            device.setup = setup
            var executorDeps = device.executor.dependencies
            executorDeps.setup = { setup }
            let executor = HandsBuildExecutor(dependencies: executorDeps, ledgerURL: device.executor.ledgerURL)
            device.executor = executor
            var syncDeps = device.sync.dependencies
            syncDeps.role = { role.get() }
            syncDeps.executor = executor
            syncDeps.reconciler = device.reconciler()
            syncDeps.report = { id in
                HandsBuildReports.build(local: id, service: device.service, setup: setup, accounts: device.accounts,
                                        permit: device.permit, applied: device.applied, phase: { device.phase.get() },
                                        safetyLocked: { false })
            }
            device.sync = HandsBuildSync(dependencies: syncDeps)
            fleet.syncAll([bID, aID])
            // 從此 apply 期間任何 RPC 都記錄並拒絕（絕不碰真正 Mini）。
            disconnected.set(true)
            rpc.set([])
        }

        var expected: HandsBuildExpected { HandsBuildExpected.of(fleet.store.load()!) }
        func current() throws -> (slice: HandsBuildDeviceSlice, configRevision: Int) {
            guard let body = local.accepted.current(trust: local.trust) else {
                throw HandsBuildSyncError.unavailable("no_config")
            }
            guard fleet.clock.now() < body.expiresDate else { throw HandsBuildSyncError.unavailable("expired") }
            return (body.content, body.configRevision)
        }
    }

    /// 只反射這個 fixture 的 private outbox；沒有產品 debug API 就不能把「看不到」當作空。
    static func localApplyOutboxCount(_ sync: HandsBuildSync) -> Int? {
        Mirror(reflecting: sync).children.first { $0.label == "outbox" }
            .flatMap { $0.value as? [HandsBuildResult] }?.count
    }

    @MainActor static func localApplyChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        localApplyUIChecks(check)
        try await localApplySuccess(check, base, keys)
        try await localApplyRefusals(check, base, keys)
        try await localApplyQueueChecks(check, base, keys)
        try await localApplyCompletionChecks(check, base, keys)
    }

    @MainActor private static func localApplyUIChecks(_ check: Checker) {
        var input = HandsBuildInput()
        input.configKnown = true
        input.configRevision = 3
        input.authority = pID + "#1"
        input.localDeviceID = bID
        input.enabled = true
        input.selectedZoneID = zoneID
        input.epochHere = "w185-ui-epoch"
        input.devices = [HandsBuildDevice(id: bID, name: "fixture", isPrimary: false, isThisDevice: true,
                                         selected: true, state: .off, subdomain: "os-for-chatgpt-fixture",
                                         url: nil, connection: .off)]
        let shown = HandsBuildSeen.of(input)
        check(HandsBuildModel.localApplyRefusal(shown: shown, current: input, drafts: []) == nil,
              "W185 local UI：已勾本機、同一 seen、沒有草稿可套用")
        let drafts = [HandsBuildDraft(label: "unsaved-local", device: bID),
                      HandsBuildDraft(label: "unsaved-other", device: aID)]
        let before = drafts
        check(HandsBuildModel.localApplyRefusal(shown: shown, current: input, drafts: drafts) != nil && drafts == before,
              "W185 local UI：本機或別台未存草稿都拒絕，原文／device 不變（純函式層）")
        var changed = input
        changed.configRevision = 4
        check(HandsBuildModel.localApplyRefusal(shown: shown, current: changed, drafts: []) == HandsBuildCopy.changed,
              "W185 local UI：舊 seen 不送")
        var unselected = input
        unselected.devices = []
        check(HandsBuildModel.localApplyRefusal(shown: .of(unselected), current: unselected, drafts: []) != nil,
              "W185 local UI：未勾本機拒絕")
        var busy = input
        busy.busyHere = true
        check(HandsBuildModel.localApplyRefusal(shown: .of(busy), current: busy, drafts: []) != nil,
              "W185 local UI：本機 setup 忙碌拒絕")
        busy.busyHere = false
        busy.applyBusy = [aID]
        check(HandsBuildModel.localApplyRefusal(shown: .of(busy), current: busy, drafts: []) != nil,
              "W185 local UI：已有 apply 進行中拒絕")
    }

    @MainActor private static func localApplySuccess(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let w = try LocalApplyWorld(base.appendingPathComponent("w185-local-success"), keys)
        let configBefore = w.fleet.store.load()
        let results = HandsLocked<[HandsBuildResult]>([])
        let id = try w.local.sync.applyHere(expected: w.expected, setupEpoch: w.local.setup.setupEpoch) {
            result in results.update { $0.append(result) }
        }
        let finished = await waitUntil(10) { results.get().contains(where: \.final) && !w.local.setup.isBusy }
        w.local.executor.drain()
        let callsBeforeProbe = w.rpc.get()
        // 同步 queue barrier＋故障傳輸探針：若 completion 偷進 outbox，這裡會嘗試 result RPC。
        w.local.sync.syncNow()
        let commands = w.runner.commands.get()
        check(finished && results.get().count == 1 && results.get().first?.operationID == id
              && results.get().first?.state == "applied"
              && w.local.setup.snapshot.publicHost == configBefore?.hostname(bID)
              && commands.contains { $0.contains("create") } && commands.contains { $0.contains("route") }
              && commands.contains { $0.contains("token") } && w.other.runner.nonLogin.isEmpty,
              "W185 local accepted slice：多勾仍只有本機 runner 建網址，真 setup 回 applied",
              "finished=\(finished) result=\(String(describing: results.get().first?.object)) commands=\(commands.count)")
        check(callsBeforeProbe.isEmpty && !w.rpc.get().contains("result")
              && localApplyOutboxCount(w.local.sync) == 0 && w.local.sync.inFlight.isEmpty,
              "W185 local apply：Mini callPrimary 零次、無 outbox／remote waiter；額外 barrier 僅允許測試 sync",
              "before=\(callsBeforeProbe) probe=\(w.rpc.get()) outbox=\(String(describing: localApplyOutboxCount(w.local.sync)))")
        check(w.fleet.store.load() == configBefore,
              "W185 local apply：中央 config、revision、多設備勾選完全不變")

        // 重播同一 operation：走同一持久化 ledger，不重做，也不回遠端 post。
        let duplicate = HandsLocked<[HandsBuildResult]>([]), posted = HandsLocked<[HandsBuildResult]>([])
        w.local.executor.post = { result in posted.update { $0.append(result) } }
        let replay = try intent(w.fleet, "apply_urls", target: bID, owner: bID, id: id, epoch: w.local.setup.setupEpoch)
        let current = try w.current()
        w.local.executor.applyHere(replay, current: { current }, completion: { result in duplicate.update { $0.append(result) } })
        let replayed = await waitUntil(3) { !duplicate.get().isEmpty }
        check(replayed && duplicate.get().count == 1 && duplicate.get().first?.state == "duplicate"
              && w.runner.commands.get().count == commands.count && posted.get().isEmpty,
              "W185 local duplicate：ledger 拒絕重跑、completion 不落 remote post")
    }

    @MainActor private static func localApplyRefusals(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        for scenario in ["missing", "expired", "unselected", "stale-epoch", "missing-epoch", "no-cert", "revision", "authority"] {
            let w = try LocalApplyWorld(base.appendingPathComponent("w185-local-" + scenario), keys,
                                        accepted: scenario != "missing", selected: scenario != "unselected", cert: scenario != "no-cert")
            let results = HandsLocked<[HandsBuildResult]>([])
            var expected = w.expected
            var epoch: String? = w.local.setup.setupEpoch
            if scenario == "expired" { w.fleet.clock.advance(HandsBuildEnvelopes.lifetime + 5) }
            if scenario == "stale-epoch" { epoch = "w185-stale-epoch" }
            if scenario == "missing-epoch" { epoch = nil }
            if scenario == "revision" { expected = .init(authority: expected.authority, revision: expected.revision + 1) }
            if scenario == "authority" { w.role.set(.member(local: bID, primary: pID, epoch: 2)) }
            let expectedReason: String
            switch scenario {
            case "missing": expectedReason = "no_config"
            case "expired": expectedReason = "expired"
            case "unselected": expectedReason = "not_selected"
            case "stale-epoch": expectedReason = "epoch_stale"
            case "missing-epoch": expectedReason = "epoch_missing"
            case "no-cert": expectedReason = "not_authorized_here"
            default: expectedReason = "config_changed"
            }
            var thrown: String?
            do {
                _ = try w.local.sync.applyHere(expected: expected, setupEpoch: epoch) { result in results.update { $0.append(result) } }
            } catch { thrown = HandsBuildExecutor.localApplyReason(error) }
            if thrown == nil { _ = await waitUntil(3) { results.get().contains(where: \.final) } }
            w.local.executor.drain()
            let reason = thrown ?? (results.get().first?.object["reason"] as? String)
            check(reason == expectedReason && results.get().count <= 1 && w.runner.commands.get().isEmpty
                  && w.other.runner.commands.get().isEmpty && w.local.starts.get() == 0 && w.rpc.get().isEmpty,
                  "W185 local guard \(scenario)：\(expectedReason)、零指令／零 Mini",
                  "reason=\(reason ?? "nil") results=\(results.get().count) rpc=\(w.rpc.get())")
        }
    }

    @MainActor private static func localApplyQueueChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let w = try LocalApplyWorld(base.appendingPathComponent("w185-local-queue"), keys)
        let entered = HandsLocked(false), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocker = try intent(w.fleet, "apply_urls", target: bID, owner: bID, epoch: w.local.setup.setupEpoch)
        let blockerResults = HandsLocked<[HandsBuildResult]>([])
        w.local.executor.applyHere(blocker, current: {
            entered.set(true)
            _ = release.wait(timeout: .now() + 5)
            throw HandsBuildSyncError.unavailable("fixture_blocker")
        }, completion: { result in blockerResults.update { $0.append(result) } })
        let blocked = await waitUntil(3) { entered.get() }
        let results = HandsLocked<[HandsBuildResult]>([])
        let seen = w.expected
        _ = try w.local.sync.applyHere(expected: seen, setupEpoch: w.local.setup.setupEpoch) {
            result in results.update { $0.append(result) }
        }
        // revision 不動，只換 authority；真正從 executor queue 取出時必須重核。
        w.role.set(.member(local: bID, primary: pID, epoch: 2))
        release.signal()
        let refused = await waitUntil(3) { !results.get().isEmpty && !blockerResults.get().isEmpty }
        check(blocked && refused && results.get().count == 1
              && results.get().first?.object["reason"] as? String == "config_changed"
              && w.fleet.store.load()?.configRevision == seen.revision
              && w.runner.commands.get().isEmpty && w.rpc.get().isEmpty,
              "W185 queued local apply：排隊後 authority 換任、same revision 仍拒絕")

        // 第一次 queue guard 通過，apply 取 snapshot 前才換任：第二次 current 必須執行。
        let current = try w.current(), reads = HandsLocked(0), second = HandsLocked<[HandsBuildResult]>([])
        let snapshotIntent = try intent(w.fleet, "apply_urls", target: bID, owner: bID, epoch: w.local.setup.setupEpoch)
        w.local.executor.applyHere(snapshotIntent, current: {
            reads.update { $0 += 1 }
            if reads.get() > 1 { throw HandsBuildSyncError.configChanged }
            return current
        }, completion: { result in second.update { $0.append(result) } })
        let secondRefused = await waitUntil(3) { !second.get().isEmpty }
        check(secondRefused && reads.get() == 2 && second.get().count == 1
              && second.get().first?.object["reason"] as? String == "config_changed" && w.runner.commands.get().isEmpty,
              "W185 local snapshot：queue guard 之後、apply 取 snapshot 再核 current")

        // 不用 chmod／真磁碟耗盡：ledger 目標本身是隔離目錄，原子檔案寫入必須失敗。
        let ledgerDirectory = w.fleet.base.appendingPathComponent("ledger-is-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
        let executor = HandsBuildExecutor(dependencies: w.local.executor.dependencies, ledgerURL: ledgerDirectory)
        let ledgerResults = HandsLocked<[HandsBuildResult]>([]), remote = HandsLocked<[HandsBuildResult]>([])
        executor.post = { result in remote.update { $0.append(result) } }
        let ledgerIntent = try intent(w.fleet, "apply_urls", target: bID, owner: bID, epoch: w.local.setup.setupEpoch)
        executor.applyHere(ledgerIntent, current: { current }, completion: { result in ledgerResults.update { $0.append(result) } })
        let ledgerRefused = await waitUntil(3) { !ledgerResults.get().isEmpty }
        check(ledgerRefused && ledgerResults.get().count == 1
              && ledgerResults.get().first?.object["reason"] as? String == "ledger_not_saved"
              && w.runner.commands.get().isEmpty && remote.get().isEmpty,
              "W185 local ledger：寫不進去拒絕，不執行／不走 post")
    }

    @MainActor private static func localApplyCompletionChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let w = try LocalApplyWorld(base.appendingPathComponent("w185-local-timeout"), keys)
        let current = try w.current()
        let localResults = HandsLocked<[HandsBuildResult]>([]), remoteResults = HandsLocked<[HandsBuildResult]>([])
        w.local.executor.post = { result in remoteResults.update { $0.append(result) } }
        w.runner.hold.set(true)
        defer { w.runner.hold.set(false) }
        let localIntent = try intent(w.fleet, "apply_urls", target: bID, owner: bID, epoch: w.local.setup.setupEpoch)
        w.local.executor.applyHere(localIntent, current: { current }, timeout: 0.5,
                                   completion: { result in localResults.update { $0.append(result) } })
        let running = await waitUntil(3) { w.runner.commands.get().contains { $0.contains("create") } }
        // local 的非同步 setup 還在跑，remote refusal 應只進原 post，不污染 local completion。
        let remoteIntent = try intent(w.fleet, "apply_urls", target: aID, owner: aID, epoch: w.local.setup.setupEpoch)
        w.local.executor.executeNow(remoteIntent)
        let timedOut = await waitUntil(3) { localResults.get().contains(where: \.final) }
        check(running && timedOut && localResults.get().count == 1
              && localResults.get().first?.operationID == localIntent.operationID
              && localResults.get().first?.state == "unknown"
              && localResults.get().first?.object["reason"] as? String == "result_unknown"
              && remoteResults.get().count == 1 && remoteResults.get().first?.operationID == remoteIntent.operationID
              && remoteResults.get().first?.object["reason"] as? String == "not_target",
              "W185 local timeout／remote post：unknown 只回本機一次，並行 remote 仍回原 post")
        w.runner.hold.set(false)
        let settled = await waitUntil(10) { !w.local.setup.isBusy && w.local.setup.snapshot.step(.tunnel).status == .done }
        w.local.executor.drain()
        try? await Task.sleep(nanoseconds: 150_000_000)
        check(settled && localResults.get().count == 1 && remoteResults.get().count == 1
              && w.runner.commands.get().filter { $0.contains("create") }.count == 1 && w.rpc.get().isEmpty,
              "W185 local timeout 晚到：真 setup 完成不重回、不走 post、不重送")
    }
}
#endif
