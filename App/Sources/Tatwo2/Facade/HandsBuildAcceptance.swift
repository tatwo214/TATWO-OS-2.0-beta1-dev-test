#if DEBUG
import AppKit
import Darwin
import Foundation

/// `TATWO2_SELFTEST=w183build`：ChatGPT build 多設備後端（W183 R8c；GPT-6 設計審查六條必改）。只在完整隔離的 staging 跑；
/// 不開通道、不啟動關口、不碰網路、真的鑰匙圈與使用者資料。
/// - 主設備 P＋副設備 A、B、C（每台自己的手腳資料夾、HandsService、授權檔、已接受的信封、套用紀錄、執行者）；主設備的信封用測試產生的
///   ed25519 金鑰真的簽、副設備真的驗（ssh-keygen）；有一條走真的設備簽章 RPC（DeviceDispatch.authenticate）。
/// - 兩台同時服務；關 B 不動 A；舊世代晚到；偽造／回滾／同版異內容；斷線到期安全暫停；A 替 B 登入（網址只到 A、C 拿不到）；
///   A 替 B 連線（碼只到 A）；交換兩台的碼卡／token／attempt 全拒；環境登入加帳號零 DNS 副作用；輪詢不清安全鎖；離線 B 的通道不被清；
///   AI 工具改不了設定（反例）；舊的單主機遷移；同一個主機名不能分給兩台；公共狀態沒有登入網址與配對碼。
enum HandsBuildAcceptance {
    final class Checker {
        var passed = 0, failed = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: String = "") {
            if condition { passed += 1 } else { failed += 1 }
            print("W183BUILD \(condition ? "PASS" : "FAIL") \(label)\(condition || evidence.isEmpty ? "" : " — " + String(evidence.prefix(700)))")
        }
    }

    static let pID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let aID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    /// B 用連線自測世界的主機 id（那個世界的 HandsConnectHost 就是 B）。
    static let bID = HandsConnectAcceptance.hostID
    static let cID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    static let accountID = String(repeating: "a1", count: 16)
    static let zoneID = String(repeating: "c3", count: 16)
    static let otherZoneID = String(repeating: "d4", count: 16)
    static let domain = "example.com"
    /// 自測用的安全停機事故編號（Fleet 的執行者只認這一個）。
    static let fixtureIncident = "w183buildincident1"

    static let known: [HandsSetupDevice] = [
        HandsSetupDevice(id: pID, name: "Primary One", isPrimary: true, isThisDevice: true),
        HandsSetupDevice(id: aID, name: "Laptop A", isPrimary: false, isThisDevice: false),
        HandsSetupDevice(id: bID, name: "Studio B", isPrimary: false, isThisDevice: false),
        HandsSetupDevice(id: cID, name: "Desk C", isPrimary: false, isThisDevice: false),
    ]

    // MARK: - 測試用的時鐘、金鑰、假 cloudflared

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        /// 真的過了多久（advance：牆上時間與單調時鐘一起走）。
        private var offset: TimeInterval = 0
        /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：某一台的牆上時鐘被調過（jumpWall：只動那台的牆上時間，單調時鐘照走）。
        private var skews: [String: TimeInterval] = [:]
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
        func now(for device: String) -> Date {
            lock.lock(); defer { lock.unlock() }
            return Date().addingTimeInterval(offset + (skews[device.lowercased()] ?? 0))
        }
        /// 單調時鐘（真的過的時間＋advance；調牆上的鐘不動它）。
        func uptime() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return HandsMonotonic.now() + offset }
        func advance(_ seconds: TimeInterval) { lock.lock(); offset += seconds; lock.unlock() }
        func jumpWall(_ seconds: TimeInterval, device: String) { lock.lock(); skews[device.lowercased(), default: 0] += seconds; lock.unlock() }
        func reset() { lock.lock(); offset = 0; skews = [:]; lock.unlock() }
    }

    struct Keys {
        let primary: String
        let forger: String
        let fingerprint: String
    }

    static func makeKeys(_ root: URL) throws -> Keys? {
        let primary = root.appendingPathComponent("primary-key").path, forger = root.appendingPathComponent("forger-key").path
        for path in [primary, forger] {
            let (status, _) = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path])
            guard status == 0 else { return nil }
        }
        let publicKey = try String(contentsOfFile: primary + ".pub", encoding: .utf8)
        return Keys(primary: primary, forger: forger, fingerprint: try DeviceRegistry.fingerprint(publicKey: publicKey))
    }

    static func certPEM(zone: String, account: String = accountID, token: String) -> String {
        let json = "{\"zoneID\":\"\(zone)\",\"accountID\":\"\(account)\",\"apiToken\":\"\(token)\"}"
        return "-----BEGIN ARGO TUNNEL TOKEN-----\n" + Data(json.utf8).base64EncodedString(options: [.lineLength64Characters])
            + "\n-----END ARGO TUNNEL TOKEN-----\n"
    }

    static func loginURL(_ canary: String) -> String {
        let key = String((canary + String(repeating: "A", count: 43)).prefix(43))
        return "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F" + key + "%3D"
    }

    final class FakeCommand: HandsRunningCommand, @unchecked Sendable {
        let cancelled = HandsLocked(false)
        let exited = HandsLocked(false)
        var processGroup: pid_t { 0 }
        var hasExited: Bool { exited.get() }
        func cancel() { cancelled.set(true) }
        func waitForExit(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if exited.get() { return true }; Thread.sleep(forTimeInterval: 0.02) }
            return exited.get()
        }
    }

    /// 假 cloudflared：login 印授權網址、等「授權」再寫 cert.pem；list 回設定好的通道清單；其他指令一律記下來並失敗（登入不能碰 DNS）。
    final class FakeRunner: HandsCloudflaredRunning, @unchecked Sendable {
        let commands = HandsLocked<[[String]]>([])
        let authorize = HandsLocked(false)
        let cert = HandsLocked("")
        let url: String
        let listed = HandsLocked("[]")
        /// W183 R8c 審查：擋住其他指令（模擬「套用」建通道到一半），直到放開或被取消。
        let hold = HandsLocked(false)
        let cancelledCommands = HandsLocked(0)
        init(url: String) { self.url = url }

        var nonLogin: [[String]] { commands.get().filter { $0.last != "login" } }
        var logins: Int { commands.get().filter { $0.last == "login" }.count }

        func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL,
                   onLine: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand {
            commands.update { $0.append(arguments) }
            let command = FakeCommand()
            let url = self.url, authorize = self.authorize, cert = self.cert, listed = self.listed
            if arguments.last == "login" {
                DispatchQueue.global().async {
                    onLine("Please open the following URL and log in with your Cloudflare account:")
                    onLine(url)
                    while !command.cancelled.get() {
                        if authorize.get() {
                            let file = home.appendingPathComponent(".cloudflared", isDirectory: true).appendingPathComponent("cert.pem")
                            try? HandsFiles.writeAtomically(Data(cert.get().utf8), to: file)
                            command.exited.set(true)
                            onExit(0)
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    command.exited.set(true)
                    onExit(nil)
                }
            } else if arguments.contains("list") {
                DispatchQueue.global().async {
                    onLine(listed.get())
                    command.exited.set(true)
                    onExit(0)
                }
            } else {
                let hold = self.hold, cancelledCommands = self.cancelledCommands
                DispatchQueue.global().async {
                    while hold.get() && !command.cancelled.get() { Thread.sleep(forTimeInterval: 0.02) }
                    let cancelled = command.cancelled.get()
                    if cancelled { cancelledCommands.update { $0 += 1 } }
                    command.exited.set(true)
                    onExit(cancelled ? nil : 9)
                }
            }
            return command
        }
    }

    // MARK: - 一台設備

    final class Device {
        let id: String
        let name: String
        let root: URL
        let paths: HandsPaths
        let service: HandsService
        let accounts: CloudflareAccountsStore
        let secrets: CloudflareMemorySecrets
        let accepted: HandsBuildAcceptedStore
        let applied: HandsBuildAppliedStore
        let permit: HandsBuildPermit
        let runner: FakeRunner
        let phase = HandsLocked<ChatGPTHandsService.Phase>(.stopped)
        let resumes = HandsLocked(0)
        let serviceChanges = HandsLocked(0)
        let connectCancels = HandsLocked<[String]>([])
        let opened = HandsLocked<[URL]>([])
        let starts = HandsLocked(0)
        let suspends = HandsLocked(0)
        /// 自測：reconcile 的 resume 叫真的 HandsSetup.resumeIfEnabled（記下有沒有開始）。
        var realResume = false
        let resumeStarted = HandsLocked<[Bool]>([])
        var setup: HandsSetup!
        var executor: HandsBuildExecutor!
        var sync: HandsBuildSync!
        let role: HandsBuildRole
        let trust: HandsBuildTrust?

        init(_ base: URL, id: String, name: String, role: HandsBuildRole, keys: Keys, clock: Clock, config: @escaping () -> HandsBuildConfig?,
             loginCanary: String, service existing: HandsService? = nil, lookup: [String: String] = [:]) throws {
            self.id = id
            self.name = name
            self.role = role
            root = base.appendingPathComponent(String(id.prefix(8)), isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let real = URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path, isDirectory: true)
            let paths = existing?.paths ?? HandsPaths(root: real.appendingPathComponent("hands", isDirectory: true))
            try HandsFiles.ensureDirectory(paths.root)
            try HandsFiles.ensureDirectory(paths.appDir)
            self.paths = paths
            let service = existing ?? HandsService(paths: paths)
            service.deviceIDOverride = id
            service.projectsOverride = { [] }
            self.service = service
            secrets = CloudflareMemorySecrets()
            accounts = CloudflareAccountsStore(fileURL: real.appendingPathComponent("cloudflare/accounts.json"), secrets: secrets)
            accepted = HandsBuildAcceptedStore(url: paths.appDir.appendingPathComponent("build-accepted.json"))
            applied = HandsBuildAppliedStore(url: paths.appDir.appendingPathComponent("build-applied.json"))
            if case .member(let local, let primary, let epoch) = role {
                trust = HandsBuildTrust(localID: local, primaryID: primary, epoch: epoch, pinnedPrimaryKey: keys.fingerprint)
            } else {
                trust = nil
            }
            let acceptedStore = accepted, trustValue = trust
            permit = HandsBuildPermit(dependencies: .init(role: { role }, config: config,
                                                          accepted: { acceptedStore.current(trust: trustValue) }, now: { clock.now() }))
            runner = FakeRunner(url: HandsBuildAcceptance.loginURL(loginCanary))
            let accounts = self.accounts, phase = self.phase, opened = self.opened, starts = self.starts
            let resumes = self.resumes, serviceChanges = self.serviceChanges
            var deps = HandsSetup.Dependencies(
                paths: paths, accounts: accounts, runner: runner,
                localDeviceID: { id },
                devices: { HandsBuildAcceptance.known.map { HandsSetupDevice(id: $0.id, name: $0.name, isPrimary: $0.isPrimary, isThisDevice: $0.id == id) } },
                transferHost: { _ in nil },
                locateCloudflared: { HandsCloudflared.Location(url: URL(fileURLWithPath: "/usr/bin/true"), source: .downloaded) },
                installCloudflared: { done in done(.failure(.download)) },
                lookupZone: { zone, _, done in done(lookup[zone] ?? HandsBuildAcceptance.domain, "Fixture Account") },
                openURL: { url in opened.update { $0.append(url) } },
                loadSettings: { service.settings.load() },
                updateSettings: { change in _ = try service.updateSettings(change) },
                startService: { starts.update { $0 += 1 } },
                servicePhase: { phase.get() },
                hasActiveGrant: { !service.auth.activeGrantIDs.isEmpty },
                askApproval: { _, _, done in done(false) })
            deps.resumeService = { resumes.update { $0 += 1 } }
            deps.retryService = { starts.update { $0 += 1 } }
            deps.serviceChanged = { serviceChanges.update { $0 += 1 } }
            deps.closeLoginPages = { _ in }   // W183 R8 整合：R8b 之後帶這一輪的網址（這裡不碰私訊框）
            deps.loginPagesDone = { _ in }
            deps.loginPagesWithdrawn = { _ in }
            deps.pollInterval = 0.02
            deps.lookupTimeout = 3
            deps.loginTimeout = 30
            deps.commandTimeout = 10
            deps.exitWait = 3
            deps.retireRetryDelays = []
            deps.buildPermit = { [permit] local in permit.state(local) }
            deps.buildSelectDefault = { _ in false }
            setup = HandsSetup(dependencies: deps)
            service.attachBuild(permit: permit)
        }

        func reconciler() -> HandsBuildReconciler {
            let resumes = self.resumes, serviceChanges = self.serviceChanges, cancels = connectCancels, suspends = self.suspends
            let setup = self.setup!, service = self.service, real = realResume, started = resumeStarted
            return HandsBuildReconciler(service: service, applied: applied,
                                        resume: {
                                            resumes.update { $0 += 1 }
                                            if real { let ok = setup.resumeIfEnabled(); started.update { $0.append(ok) } }
                                        },
                                        serviceChanged: { serviceChanges.update { $0 += 1 } },
                                        cancelConnect: { reason in cancels.update { $0.append(reason) } },
                                        cancelSetup: { setup.cancel() },
                                        suspend: { suspends.update { $0 += 1 }; service.suspendForPermit() })
        }

        /// 這台的 HandsSetup 自測世界（先寫好狀態檔再開：已經建好的網址、選好的帳號與網域）。
        func preloadSetupState(_ state: HandsSetupState) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try HandsFiles.writeAtomically(try encoder.encode(state), to: paths.appDir.appendingPathComponent("setup.json"))
        }
    }

    /// 主設備 P 的正本與信箱（用測試金鑰簽）＋每台的同步（副設備的 RPC＝經 JSON 來回、sender 當作已驗章）。
    final class Fleet {
        let base: URL
        let keys: Keys
        let clock = Clock()
        let store: HandsBuildConfigStore
        let authority: HandsBuildAuthority
        var devices: [String: Device] = [:]
        let lifetime: HandsLocked<TimeInterval>
        /// 模擬斷線的設備（它的 RPC 一律失敗）。
        let offline = HandsLocked<Set<String>>([])

        init(_ base: URL, keys: Keys, legacy: (settings: HandsSettings, setup: HandsSetupState)? = nil, lifetime: TimeInterval = HandsBuildEnvelopes.lifetime) throws {
            self.base = base
            self.keys = keys
            let lifetimeBox = HandsLocked(lifetime)
            self.lifetime = lifetimeBox
            let pRoot = base.appendingPathComponent("p-store", isDirectory: true)
            try FileManager.default.createDirectory(at: pRoot, withIntermediateDirectories: true)
            let paths = HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(pRoot.path) ?? pRoot.path).appendingPathComponent("hands", isDirectory: true))
            try HandsFiles.ensureDirectory(paths.appDir)
            let clock = self.clock
            // W183 R11 最後一輪：主設備（正本、信箱）用 P 那台的牆上時鐘（自測可以只調主設備的鐘）。
            store = HandsBuildConfigStore(paths: paths, dependencies: .init(
                role: { .authority(local: HandsBuildAcceptance.pID, epoch: 1) },
                devices: { HandsBuildAcceptance.known }, legacy: { legacy }, now: { clock.now(for: HandsBuildAcceptance.pID) }))
            authority = HandsBuildAuthority(dependencies: .init(
                store: store, signer: .ssh(environment: ["TATWO2_SSH_KEY_PATH": keys.primary]),
                knownDevices: { HandsBuildAcceptance.known }, localID: { HandsBuildAcceptance.pID }, now: { clock.now(for: HandsBuildAcceptance.pID) },
                envelopeLifetime: lifetime))
        }

        static func wire(_ object: [String: Any]) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: object)) as? [String: Any] ?? [:]
        }

        @discardableResult
        /// safety（W183 R8 整合審查）：這台現在的安全停機事故編號（nil＝沒鎖）；給了＝公共狀態照它回報，解除只認現在這一個（清掉）。
        func add(_ id: String, name: String, service: HandsService? = nil, loginCanary: String = "W183BUILDLOGIN",
                 lookup: [String: String] = [:], realResume: Bool = false, safety: HandsLocked<String?>? = nil,
                 callPrimary custom: (([String: Any]) throws -> [String: Any])? = nil,
                 trust customTrust: (() -> HandsBuildTrust?)? = nil,
                 primaryHostPin: ((String) -> String?)? = nil,
                 learnPrimaryKey: ((HandsBuildEnvelope, HandsBuildTrust, String) -> Void)? = nil) throws -> Device {
            let role: HandsBuildRole = id == HandsBuildAcceptance.pID ? .authority(local: id, epoch: 1) : .member(local: id, primary: HandsBuildAcceptance.pID, epoch: 1)
            let store = self.store
            let device = try Device(base, id: id, name: name, role: role, keys: keys, clock: clock,
                                    config: { role.isAuthority ? store.load() : nil }, loginCanary: loginCanary, service: service, lookup: lookup)
            let authority = self.authority, offline = self.offline, clock = self.clock
            let call: ([String: Any]) throws -> [String: Any] = custom ?? { payload in
                if offline.get().contains(id) { throw RemoteHostLinkError.tunnelUnavailable }
                return try Fleet.wire(try HandsBuildRemote.handle(payload: try Fleet.wire(payload), sender: id, authority: authority))
            }
            let permit = device.permit, accepted = device.accepted, trust = device.trust, setup = device.setup!
            let executor = HandsBuildExecutor(dependencies: .init(
                localID: { id }, setup: { setup }, service: { device.service },
                remoteHost: { HandsRemote.Host(service: device.service, phase: { .running(url: "https://os-for-chatgpt.example.com/mcp") },
                                               setup: { nil }, localDeviceID: { id }) },
                unlockSafety: { incident in
                    guard let safety else { return incident == HandsBuildAcceptance.fixtureIncident }
                    guard let current = safety.get(), current == incident else { return false }   // 跟現在鎖著的是同一次才清
                    safety.set(nil)
                    return true
                },
                current: {
                    if role.isAuthority {
                        guard let config = store.load() else { return nil }
                        return (config.slice(for: id), config.configRevision)
                    }
                    guard let body = accepted.current(trust: trust), clock.now() < body.expiresDate else { return nil }
                    return (body.content, body.configRevision)
                },
                accounts: { device.accounts }, now: { clock.now() }), ledgerURL: device.paths.appDir.appendingPathComponent("build-ops.json"))
            device.executor = executor
            device.realResume = realResume
            let reconciler = device.reconciler()
            let applied = device.applied, service = device.service, accounts = device.accounts
            device.sync = HandsBuildSync(dependencies: .init(
                role: { role }, authority: role.isAuthority ? authority : nil, callPrimary: call, trust: customTrust ?? { trust }, accepted: accepted,
                permit: permit, reconciler: reconciler, executor: executor,
                report: { local in HandsBuildReports.build(local: local, service: service, setup: setup, accounts: accounts, permit: permit,
                                                           applied: applied, phase: { device.phase.get() }, safetyLocked: { safety?.get() != nil },
                                                           safetyIncident: { safety?.get() }) },
                now: { clock.now(for: id) }, uptime: { clock.uptime() },   // W183 R11 最後一輪：這台的牆上時鐘與單調時鐘
                primaryHostPin: primaryHostPin, learnPrimaryKey: learnPrimaryKey))
            devices[id] = device
            return device
        }

        func device(_ id: String) -> Device { devices[id]! }

        /// 每台同步一輪（依序）。
        func syncAll(_ ids: [String]? = nil) {
            for id in ids ?? Array(devices.keys).sorted() { devices[id]?.sync.syncNow() }
        }

        func update(_ ops: [HandsBuildConfigOp], from sender: String = HandsBuildAcceptance.pID, expected: Int? = nil) throws -> HandsBuildConfig {
            try authority.updateConfig(from: sender, expectedRevision: expected ?? store.load()?.configRevision ?? 0, ops: ops)
        }
    }

    @MainActor static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    static func text(_ value: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self) }

    // MARK: - 進入點

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let stagingPath = environment["TATWO_STAGING_ROOT"], let staging = HandsPath.realpath(stagingPath) else {
            throw BotLibraryError.invalid("w183build needs a fully isolated staging environment")
        }
        let base = URL(fileURLWithPath: staging).appendingPathComponent("w183build-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let check = Checker()
        check(!ChatGPTHandsService.allowedToRun(environment: environment), "自測／staging：真的關口、通道、背景同步都不跑")
        guard let keys = try makeKeys(base) else {
            check(false, "產生測試金鑰（ssh-keygen）")
            print("W183BUILD SUMMARY failures=\(check.failed) passed=\(check.passed)")
            return false
        }
        try migrationChecks(check, base, keys)
        try configChecks(check, base, keys)
        try await twoDevicesAndDisable(check, base, keys)
        try envelopeChecks(check, base, keys)
        try await expiryPause(check, base, keys)
        try await loginForOther(check, base, keys)
        try await mailboxEdgeCases(check, base, keys)
        try await connectForOther(check, base, keys)
        try await swapRefusals(check, base, keys)
        try await environmentLoginNoDNS(check, base, keys)
        try await safetyLockChecks(check, base, keys)
        try await offlineTunnelKept(check, base, keys)
        try signedRPC(check, base, keys)
        try joinSideLearnsPrimaryKey(check, base, keys)
        aiCannotChangeConfig(check)
        publicStatusChecks(check)
        // W183 R8c 審查（GPT-6 跨引擎＋Claude）：行為驗收（HandsBuildReviewAcceptance.swift）。
        try await resumeNoDNS(check, base, keys)
        try await disableCancelsApply(check, base, keys)
        try await applyPlanChecks(check, base, keys)
        try await mailboxAckChecks(check, base, keys)
        try await busyLoginChecks(check, base, keys)
        try await controllerChecks(check, base, keys)
        try await switchAndScopeChecks(check, base, keys)
        pollingChecks(check)
        // W183 R8 整合：畫面接到多設備後端之後的那一段（授權頁在 Browser 分頁、套用帶草稿的 CAS、確認過的連線才算）。
        try await integrationChecks(check, base, keys)
        // W183 R8 整合審查（GPT-6 跨引擎＋Claude）：送出前換版、沒回執不送、這台的解除安全鎖、沒有回報不寫已關、收窄存不進去、舊的遠端設定 RPC、［連線］這一輪。
        try await integrationReviewChecks(check, base, keys)
        // W183 R11 第二輪（GPT-6 R11 審查 1、3–7）：正式 controller 的三條撤銷路、遷移不放大既有連線、入口對著真的回報（HandsBuildR11Acceptance.swift）。
        try await r11bChecks(check, base, keys)
        // W183 R12 第二批（主導 4：拿掉等級選擇）：所有設備一律 L2；既有連線不放大、舊版主機不調高（HandsBuildR12Acceptance.swift）。
        try await r12LevelChecks(check, base, keys)
        try await localApplyChecks(check, base, keys)
        try? FileManager.default.removeItem(at: base)
        print("W183BUILD SUMMARY failures=\(check.failed) passed=\(check.passed)")
        return check.failed == 0
    }

    // MARK: - 1. 舊的單主機遷移（必改 8）

    static func migrationChecks(_ check: Checker, _ base: URL, _ keys: Keys) throws {
        var settings = HandsSettings()
        settings.enabled = true
        settings.hostDeviceID = pID
        settings.publicHost = "os-for-chatgpt.example.com"
        settings.level = 1
        var setup = HandsSetupState()
        setup.accountID = accountID; setup.zoneID = zoneID; setup.domain = domain
        setup.tunnelID = "0f0e0d0c-0b0a-4908-8706-050403020100"; setup.publicHost = "os-for-chatgpt.example.com"
        setup.steps[HandsSetupStep.authorize.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date())
        let fleet = try Fleet(base.appendingPathComponent("migration"), keys: keys, legacy: (settings, setup))
        let config = fleet.store.load()
        let ownership = fleet.store.ownership()
        check(config?.migratedFromLegacy == true && config?.enabled == true && config?.selectedIDs == [pID]
              && config?.entry(pID)?.subdomain == "os-for-chatgpt" && config?.domain == domain && config?.zoneID == zoneID
              && config?.entry(aID) == nil && config?.entry(bID) == nil && config?.configRevision == 1,
              "遷移：舊的單主機（主設備、固定子網域、網域）＝一份「只勾主設備」的設定；別台沒勾", "\(String(describing: config))")
        check(ownership.owner(of: "os-for-chatgpt.example.com") == pID
              && ownership.records.first?.tunnelID == "0f0e0d0c-0b0a-4908-8706-050403020100" && ownership.records.first?.evidence == "legacy_host",
              "遷移：舊網址與通道記成主設備的所有權（別台的清理不碰）")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: fleet.store.url.deletingLastPathComponent().path)) ?? []
        check(!files.contains("auth.json") && !text(config?.wire ?? [:]).contains("token"),
              "遷移：不複製任何 OAuth 狀態（沒有 auth.json、設定裡沒有 token）", files.joined(separator: ","))
        let reloaded = HandsBuildConfigStore(paths: HandsPaths(root: fleet.store.url.deletingLastPathComponent().deletingLastPathComponent()),
                                             dependencies: fleet.store.dependencies).load()
        check(reloaded == config, "遷移只做一次（第二次讀的是存下來的那一份）")
    }

    // MARK: - 2. 設定：CAS、每台版本、同一個主機名不能給兩台、所有權

    static func configChecks(_ check: Checker, _ base: URL, _ keys: Keys) throws {
        let fleet = try Fleet(base.appendingPathComponent("config"), keys: keys)
        let first = try fleet.update([.setEnabled(true)])
        check(first.selectedIDs == [pID] && first.enabled, "打開時一台都沒勾＝勾主設備（沒有副設備的人一律主設備）")
        let second = try fleet.update([.select(device: aID, selected: true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        check(second.entry(aID)?.subdomain == "os-for-chatgpt-laptopa" && second.entry(pID)?.subdomain == "os-for-chatgpt"
              && second.hostname(aID) == "os-for-chatgpt-laptopa.example.com",
              "每台預設子網域：主設備 os-for-chatgpt、其他 os-for-chatgpt-<簡稱>", "\(second.devices.map(\.subdomain))")
        var stale = false
        do { _ = try fleet.update([.select(device: bID, selected: true)], expected: first.configRevision) }
        catch HandsBuildConfigError.revisionConflict(let current) { stale = current == second.configRevision }
        check(stale && fleet.store.load()?.entry(bID) == nil, "延遲送達的舊改動（預期版本舊了）不收：CAS")
        var taken = false
        do { _ = try fleet.update([.subdomain(device: aID, label: "os-for-chatgpt")]) } catch HandsBuildConfigError.hostnameTaken { taken = true }
        check(taken, "同一個主機名不能分給兩台")
        let beforeA = fleet.store.load()?.entry(aID)
        // W183 R11：新加的設備預設就是 L2——改成 L1 才是「內容變了」（守的一樣：只改主設備＝主設備 +1、A 不動）。
        check(fleet.store.load()?.entry(pID)?.level == HandsBuildConfig.defaultLevel && beforeA?.level == HandsBuildConfig.defaultLevel,
              "W183 R11 新加進來的設備預設 L2（Codex、記憶）")
        let third = try fleet.update([.level(device: pID, level: 1)])
        check(third.entry(pID)?.deviceRevision == (second.entry(pID)?.deviceRevision ?? 0) + 1 && third.entry(aID) == beforeA,
              "只改主設備：主設備的 deviceRevision +1，A 的內容與版本不動")
        _ = fleet.store.recordResources(device: bID, [.init(hostname: "os-for-chatgpt-studiob.example.com", deviceID: bID, tunnelID: nil, zoneID: zoneID,
                                                             evidence: "created", recordedAt: Date())])
        var owned = false
        do { _ = try fleet.update([.subdomain(device: aID, label: "os-for-chatgpt-studiob")]) } catch HandsBuildConfigError.hostnameOwned { owned = true }
        check(owned, "別台有建立證據的主機名不分給這台（沒有自動接管）")
        let conflicts = fleet.store.recordResources(device: aID, [.init(hostname: "os-for-chatgpt-studiob.example.com", deviceID: aID, tunnelID: nil,
                                                                         zoneID: zoneID, evidence: "created", recordedAt: Date())])
        check(conflicts == ["os-for-chatgpt-studiob.example.com"] && fleet.store.ownership().owner(of: "os-for-chatgpt-studiob.example.com") == bID,
              "別台回報別人的主機名：不改所有權（衝突照實回）")
        var unknown = false
        do { _ = try fleet.update([.select(device: "99999999-9999-4999-8999-999999999999", selected: true)]) } catch HandsBuildConfigError.unknownDevice { unknown = true }
        check(unknown, "沒配對的設備不能勾（名稱與主／副以主設備自己的登記為準）")
        let wire = text(fleet.store.load()?.wire ?? [:])
        check(!wire.contains("token") && !wire.contains("cert") && !wire.contains("BEGIN"), "設定正本沒有任何金鑰、token、憑證")

        // W183 R8c 審查（GPT-6 中）：CAS 一定要帶——經簽章 RPC 沒帶預期版本、帶布林、帶小數＝不收。
        let revisionBefore = fleet.store.load()?.configRevision
        func rpcRefused(_ extra: [String: Any]) -> Bool {
            var payload: [String: Any] = ["op": "config", "changes": [HandsBuildConfigOp.level(device: aID, level: 0).wire],
                                          "expires_at": Int(fleet.clock.now().timeIntervalSince1970 + 60)]
            payload.merge(extra) { $1 }
            do { _ = try HandsBuildRemote.handle(payload: try Fleet.wire(payload), sender: aID, authority: fleet.authority); return false }
            catch { return String(describing: error).contains("expected_revision") }
        }
        check(rpcRefused([:]) && rpcRefused(["expected_revision": true]) && rpcRefused(["expected_revision": 1.5])
              && rpcRefused(["expected_revision": -1]) && fleet.store.load()?.configRevision == revisionBefore,
              "改設定一定要帶預期版本（沒帶、布林、小數、負的都不收；沒有「nil＝跳過比對」）")

        // W183 R8c 審查（Claude 中）：內容一樣的回報不重寫所有權表（也不改時間）。
        let ownershipFile = fleet.store.ownershipURL
        let beforeBytes = try? Data(contentsOf: ownershipFile)
        let beforeInode = (try? FileManager.default.attributesOfItem(atPath: ownershipFile.path)[.systemFileNumber] as? Int) ?? -1
        for _ in 0..<3 {
            fleet.clock.advance(1.7)
            _ = fleet.store.recordResources(device: bID, [.init(hostname: "os-for-chatgpt-studiob.example.com", deviceID: bID, tunnelID: nil,
                                                                 zoneID: zoneID, evidence: "created", recordedAt: fleet.clock.now())])
        }
        let afterInode = (try? FileManager.default.attributesOfItem(atPath: ownershipFile.path)[.systemFileNumber] as? Int) ?? -2
        check(beforeBytes == (try? Data(contentsOf: ownershipFile)) && beforeInode == afterInode,
              "所有權：同樣的回報（只有時間不同）不重寫檔案（每 2 秒一次的同步不會一直寫磁碟）")
        // W183 R8c 審查（GPT-6 中）：沒回報不等於釋放——B 換了網址、只回報新的：舊的照樣是 B 的；B 帶了釋放證據才拿掉。
        _ = fleet.store.recordResources(device: bID, [.init(hostname: "os-for-chatgpt-studio2.example.com", deviceID: bID, tunnelID: nil,
                                                             zoneID: zoneID, evidence: "created", recordedAt: Date())])
        let keptOld = fleet.store.ownership().owner(of: "os-for-chatgpt-studiob.example.com") == bID
            && fleet.store.ownership().owner(of: "os-for-chatgpt-studio2.example.com") == bID
        _ = fleet.store.recordResources(device: bID, [.init(hostname: "os-for-chatgpt-studio2.example.com", deviceID: bID, tunnelID: nil,
                                                             zoneID: zoneID, evidence: "created", recordedAt: Date())],
                                        released: ["os-for-chatgpt-studiob.example.com"])
        check(keptOld && fleet.store.ownership().owner(of: "os-for-chatgpt-studiob.example.com") == nil
              && fleet.store.ownership().owner(of: "os-for-chatgpt-studio2.example.com") == bID,
              "所有權：沒回報的舊網址照樣是那台的（沒有連線不等於沒有主人）；有釋放證據（刪掉了、確定不在）才拿掉")
        // 所有權表壞了（讀不到）＝不知道：不分配網址、不覆蓋；關掉照樣可以。
        try HandsFiles.writeAtomically(Data("{not json".utf8), to: ownershipFile)
        var unknownRefused = false
        do { _ = try fleet.update([.select(device: cID, selected: true)]) } catch HandsBuildConfigError.ownershipUnknown { unknownRefused = true }
        let offStillWorks = (try? fleet.update([.select(device: aID, selected: false)])) != nil
        _ = fleet.store.recordResources(device: bID, [])
        check(fleet.store.ownership().unknown && unknownRefused && offStillWorks && (try? Data(contentsOf: ownershipFile)) == Data("{not json".utf8),
              "所有權表讀不到＝不知道（不是空表）：不分配新網址、不覆蓋那個檔案；取消勾選照樣可以")
    }

    // MARK: - 3. 兩台同時服務、關 B 不動 A、未收到回執不顯示已關

    /// 手動配對一筆（開窗口、註冊、交易、碼、token）。回 access token。
    static func pair(_ service: HandsService, host: String) throws -> String {
        try service.startPairing()
        let chatgpt = HandsConnectAcceptance.FakeChatGPT(service: service)
        try chatgpt.register()
        _ = try service.handle(method: "hands_auth", params: [
            "op": "authorize_begin", "client_id": chatgpt.clientID, "redirect_uri": chatgpt.redirect, "code_challenge": chatgpt.challenge,
            "code_challenge_method": "S256", "state": chatgpt.state, "resource": "https://\(host)/mcp", "scope": "tatwo.hands"])
        let code = service.auth.pendingCard?.pairingCode ?? ""
        let transaction = service.auth.pendingCard?.id ?? ""
        chatgpt.transaction = transaction
        return try chatgpt.token(try chatgpt.submit(code))
    }

    static func tools(_ service: HandsService, _ access: String) -> Bool {
        (try? service.handle(method: "hands_tools", params: ["access_token": access])) != nil
    }

    @MainActor static func twoDevicesAndDisable(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("two"), keys: keys)
        let a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B")
        _ = try fleet.update([.setEnabled(true), .select(device: aID, selected: true), .select(device: bID, selected: true),
                              .select(device: pID, selected: false), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        // 兩台都已經套用過網址（有網址）：收到勾選後自己打開。
        for (device, host) in [(a, "os-for-chatgpt-laptopa.example.com"), (b, "os-for-chatgpt-studiob.example.com")] {
            _ = try device.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = device.id }
        }
        fleet.syncAll()
        let aSettings = a.service.settings.load(), bSettings = b.service.settings.load()
        check(a.permit.permits(aID) && b.permit.permits(bID) && aSettings.enabled && bSettings.enabled
              && aSettings.subdomainLabel == "os-for-chatgpt-laptopa" && bSettings.subdomainLabel == "os-for-chatgpt-studiob",
              "兩台同時勾：各自收到主設備簽的那一份、各自打開（每台自己當自己的主機）",
              "\(a.permit.state(aID)) \(b.permit.state(bID))")
        let accessA = try pair(a.service, host: "os-for-chatgpt-laptopa.example.com")
        let accessB = try pair(b.service, host: "os-for-chatgpt-studiob.example.com")
        let grantA = a.service.auth.grant(forAccess: accessA), grantB = b.service.auth.grant(forAccess: accessB)
        check(tools(a.service, accessA) && tools(b.service, accessB)
              && a.service.auth.grantRecord(grantA?.grantID ?? "")?.hostDeviceID == aID
              && b.service.auth.grantRecord(grantB?.grantID ?? "")?.resource == "https://os-for-chatgpt-studiob.example.com/mcp",
              "兩台同時服務：各自一筆 grant（蓋上自己的設備、網址、撤銷世代），各自的工具都能用")
        let aRevision = fleet.store.load()?.entry(aID)?.deviceRevision
        let disabled = try fleet.update([.select(device: bID, selected: false)])
        // 未收到回執：主設備看到的 B 還沒套用這一版。
        let reportBefore = fleet.authority.reportsSnapshot().first { $0.deviceID == bID }
        check((reportBefore?.appliedConfigRevision ?? 0) < disabled.configRevision,
              "關 B 之後、B 還沒同步：主設備看到的 B 套用版本還是舊的（畫面不會寫已關）")
        fleet.syncAll([aID, bID])
        fleet.syncAll([bID])
        let reportAfter = fleet.authority.reportsSnapshot().first { $0.deviceID == bID }
        check(!b.service.settings.load().enabled && !tools(b.service, accessB) && b.service.auth.grantRecord(grantB?.grantID ?? "")?.revokedAt != nil
              && b.connectCancels.get().contains("build_disabled"),
              "關 B：B 撤銷自己全部的連線、關開關、進行中的連線作廢")
        check(a.service.settings.load().enabled && tools(a.service, accessA) && a.permit.permits(aID)
              && fleet.store.load()?.entry(aID)?.deviceRevision == aRevision,
              "關 B 不動 A：A 的內容與版本不變、A 的連線照用")
        check((reportAfter?.appliedConfigRevision ?? 0) >= disabled.configRevision && reportAfter?.permit == "inactive"
              && reportAfter?.enabled == false && reportAfter?.grants == 0,
              "B 同步後回報已套用這一版、許可 inactive、開關關、沒有連線（有回執才算）", "\(String(describing: reportAfter?.wire))")
        // 舊的啟用晚到：用關之前的版本再勾 B → 版本對不上，不收。
        var lateEnable = false
        do { _ = try fleet.update([.select(device: bID, selected: true)], expected: disabled.configRevision - 1) }
        catch HandsBuildConfigError.revisionConflict { lateEnable = true }
        check(lateEnable && !(fleet.store.load()?.isActive(bID) ?? true), "舊的啟用晚到（預期版本是關之前的）：不收，B 維持關著")
        // 重新勾 B：新的一輪，舊的 grant 不會復活（撤銷世代變了）。
        _ = try fleet.update([.select(device: bID, selected: true)])
        fleet.syncAll([bID])
        check(!tools(b.service, accessB) && b.permit.permits(bID), "重新勾 B：新的一輪；B 舊的 token 不會復活（撤銷世代變了、grant 已撤銷）")
    }

    // MARK: - 4. 信封：偽造、竄改、回滾、同版異內容、給錯台、沒 pin

    static func envelopeChecks(_ check: Checker, _ base: URL, _ keys: Keys) throws {
        let fleet = try Fleet(base.appendingPathComponent("envelope"), keys: keys)
        let b = try fleet.add(bID, name: "Studio B")
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true)])
        let config1 = fleet.store.load()!
        let signer = HandsBuildSigner.ssh(environment: ["TATWO2_SSH_KEY_PATH": keys.primary])
        let now = fleet.clock.now()
        let e1 = try HandsBuildEnvelopes.issue(config: config1, target: bID, signer: signer, now: now)
        let trust = b.trust!
        let accepted1 = try? b.accepted.accept(e1, trust: trust, now: now)
        check(accepted1?.body.configRevision == config1.configRevision, "B 收主設備簽的信封（驗章、給這台、雜湊對）")
        let forger = HandsBuildSigner.ssh(environment: ["TATWO2_SSH_KEY_PATH": keys.forger])
        var forged: HandsBuildEnvelopeError?
        do { try b.accepted.accept(try HandsBuildEnvelopes.issue(config: config1, target: bID, signer: forger, now: now), trust: trust, now: now) }
        catch { forged = error as? HandsBuildEnvelopeError }
        check(forged == .untrustedSigner, "偽造（別的金鑰簽的）：不收", "\(String(describing: forged))")
        var body = try JSONDecoder().decode(HandsBuildEnvelopeBody.self, from: e1.body)
        body.content.level = 0   // W183 R11：預設已經是 L2，竄改成別的值（守的一樣：內容改了＝簽章對不上）
        let tampered = HandsBuildEnvelope(body: HandsBuildCanonical.encode(body), signature: e1.signature, publicKey: e1.publicKey)
        var tamperError: HandsBuildEnvelopeError?
        do { try b.accepted.accept(tampered, trust: trust, now: now) } catch { tamperError = error as? HandsBuildEnvelopeError }
        check(tamperError == .badSignature, "竄改內容（簽章對不上）：不收", "\(String(describing: tamperError))")
        _ = try fleet.update([.level(device: bID, level: 1)])   // W183 R11：預設 L2，改成 L1 才是新的一版
        let config2 = fleet.store.load()!
        let e2 = try HandsBuildEnvelopes.issue(config: config2, target: bID, signer: signer, now: now)
        _ = try b.accepted.accept(e2, trust: trust, now: now)
        var rollback: HandsBuildEnvelopeError?
        do { try b.accepted.accept(e1, trust: trust, now: now) } catch { rollback = error as? HandsBuildEnvelopeError }
        check(rollback == .rollback && b.accepted.current(trust: trust)?.configRevision == config2.configRevision,
              "回滾（舊版本晚到）：不收，留著較新的", "\(String(describing: rollback))")
        // 同一版、不同內容（主設備自己的金鑰簽的也一樣不收）。
        var same = try JSONDecoder().decode(HandsBuildEnvelopeBody.self, from: e2.body)
        same.content.subdomain = "os-for-chatgpt-other"
        same.contentHash = same.content.contentHash
        var conflict: HandsBuildEnvelopeError?
        do { try b.accepted.accept(try HandsBuildEnvelopes.sign(same, signer: signer), trust: trust, now: now) } catch { conflict = error as? HandsBuildEnvelopeError }
        check(conflict == .conflict, "同一版不同內容（就算是主設備的金鑰簽的）：不收", "\(String(describing: conflict))")
        let again = try? b.accepted.accept(try HandsBuildEnvelopes.issue(config: config2, target: bID, signer: signer, now: now.addingTimeInterval(60)),
                                           trust: trust, now: now.addingTimeInterval(60))
        check(again == .refreshed(again?.body ?? same), "同一版同內容：冪等（只把期限延長）")
        // W183 R8c 審查（GPT-6 中）：整份的版本變大、這台自己的版本或撤銷世代卻倒退；同一個 deviceRevision 換了內容＝不收。
        var lower = try JSONDecoder().decode(HandsBuildEnvelopeBody.self, from: e2.body)
        lower.configRevision += 5
        lower.content.deviceRevision -= 1
        lower.deviceRevision = lower.content.deviceRevision
        lower.contentHash = lower.content.contentHash
        var perDevice: HandsBuildEnvelopeError?
        do { try b.accepted.accept(try HandsBuildEnvelopes.sign(lower, signer: signer), trust: trust, now: now) } catch { perDevice = error as? HandsBuildEnvelopeError }
        var sameRevision = try JSONDecoder().decode(HandsBuildEnvelopeBody.self, from: e2.body)
        sameRevision.configRevision += 5
        sameRevision.content.level = 0
        sameRevision.contentHash = sameRevision.content.contentHash
        var sameRevisionError: HandsBuildEnvelopeError?
        do { try b.accepted.accept(try HandsBuildEnvelopes.sign(sameRevision, signer: signer), trust: trust, now: now) }
        catch { sameRevisionError = error as? HandsBuildEnvelopeError }
        check(perDevice == .rollback && sameRevisionError == .conflict && b.accepted.current(trust: trust)?.configRevision == config2.configRevision,
              "整份版本變大但這台自己的版本倒退＝回滾；同一個 deviceRevision 換了內容＝不收（每台各自單調）",
              "\(String(describing: perDevice)) \(String(describing: sameRevisionError))")
        // W183 R8c 審查（Claude 高）：跟已接受的一模一樣的信封＝不再叫 ssh-keygen 驗章。
        let current2 = try HandsBuildEnvelopes.issue(config: config2, target: bID, signer: signer, now: now.addingTimeInterval(120))
        _ = try b.accepted.accept(current2, trust: trust, now: now.addingTimeInterval(120))
        let verifies = HandsBuildEnvelopes.debugVerifyCount
        let again2 = try b.accepted.accept(current2, trust: trust, now: now.addingTimeInterval(130))
        check(HandsBuildEnvelopes.debugVerifyCount == verifies && again2 == .unchanged(again2.body),
              "同一份信封（逐位元一樣）不重驗章：每一輪同步不用再開 ssh-keygen")
        var wrongTarget: HandsBuildEnvelopeError?
        do { try b.accepted.accept(try HandsBuildEnvelopes.issue(config: config2, target: aID, signer: signer, now: now), trust: trust, now: now) }
        catch { wrongTarget = error as? HandsBuildEnvelopeError }
        check(wrongTarget == .wrongTarget, "給別台的信封：不收")
        var unpinned: HandsBuildEnvelopeError?
        let noPin = HandsBuildTrust(localID: bID, primaryID: pID, epoch: 1, pinnedPrimaryKey: nil)
        do { try b.accepted.accept(e2, trust: noPin, now: now) } catch { unpinned = error as? HandsBuildEnvelopeError }
        check(unpinned == .unpinned, "沒有 pin 住主設備的簽章識別：一律不收（不從回覆學新公鑰）")
        var wrongEpoch: HandsBuildEnvelopeError?
        do { try b.accepted.accept(e2, trust: HandsBuildTrust(localID: bID, primaryID: pID, epoch: 2, pinnedPrimaryKey: keys.fingerprint), now: now) }
        catch { wrongEpoch = error as? HandsBuildEnvelopeError }
        check(wrongEpoch == .wrongEpoch, "主權換過（epoch 不對）：不收")
        // 讀回來重驗：同一個使用者的程式改了檔案＝不認。
        let file = b.accepted.url
        var stored = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) ?? [:]
        stored["body"] = HandsBuildCanonical.encode(body).base64EncodedString()
        try HandsFiles.writeAtomically(try JSONSerialization.data(withJSONObject: stored), to: file)
        let reread = HandsBuildAcceptedStore(url: file).current(trust: trust)
        check(reread == nil, "已接受的檔案被改過：重開讀回來重驗不過＝沒有許可（fail closed）")
    }

    // MARK: - 5. 斷線到期：安全暫停（不撤銷），連得上再恢復

    @MainActor static func expiryPause(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("expiry"), keys: keys, lifetime: 120)
        let b = try fleet.add(bID, name: "Studio B")
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        _ = try b.service.updateSettings { $0.publicHost = "os-for-chatgpt-studiob.example.com"; $0.hostDeviceID = bID }
        fleet.syncAll()
        let access = try pair(b.service, host: "os-for-chatgpt-studiob.example.com")
        check(tools(b.service, access), "準備：B 有一筆連線、工具能用")
        try b.service.startPairing()   // 暫停前開著一個配對窗口
        let suspendsBefore = b.suspends.get()
        fleet.offline.set([bID])
        fleet.clock.advance(300)
        fleet.syncAll([bID])
        let state = b.permit.state(bID)
        let grantID = b.service.auth.grants().first?.id ?? ""
        check(state == .paused("expired") && !tools(b.service, access) && b.service.auth.grantRecord(grantID)?.revokedAt == nil
              && b.service.settings.load().enabled,
              "連不到主設備、信封過期：安全暫停（工具不收），grant 沒撤銷、開關沒動", "\(state)")
        // W183 R8c 審查（GPT-6 高）：暫停不只停關口——跑著的工作收掉、配對窗口關掉（grant 留著）；長的工作跑的時候也看許可（HandsJobs）。
        check(b.suspends.get() == suspendsBefore + 1 && b.service.auth.windowExpiresAt == nil && b.service.permitCheck?() == false,
              "許可到期的那一下：安全暫停的收尾（收掉工作、關配對窗口；只在轉成暫停時做一次）", "suspends=\(b.suspends.get())")
        var paused = false
        do { _ = try b.service.handle(method: "hands_auth", params: ["op": "register_client", "redirect_uris": [HandsSettings.defaultCallbacks[0]]]) }
        catch let error as HandsWireError { paused = error == .disabled }
        check(paused, "暫停時也不開配對（hands_auth 回關著）")
        fleet.offline.set([])
        fleet.syncAll([bID])
        check(b.permit.permits(bID) && tools(b.service, access), "連得上主設備、拿到新的信封：自己恢復（同一筆連線照用，不用重新配對）")
    }

    // MARK: - 6. A 替 B 登入：網址只到 A、C 拿不到；登入只是登入（零 DNS）

    @MainActor static func loginForOther(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("login"), keys: keys)
        let canary = "W183BUILDLOGINB" + String(UUID().uuidString.prefix(8)).lowercased().filter { $0.isLetter || $0.isNumber }
        let a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B", loginCanary: canary)
        let c = try fleet.add(cID, name: "Desk C")
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true)])
        fleet.syncAll()
        b.runner.cert.set(certPEM(zone: zoneID, token: "W183BUILDAPITOKEN" + canary))
        let results = HandsLocked<[HandsBuildResult]>([])
        let epoch = b.setup.setupEpoch
        let id = try a.sync.submit(action: "login", target: bID, attempt: UUID().uuidString.lowercased(), setupEpoch: epoch) { result in
            results.update { $0.append(result) }
        }
        var gotURL = false
        for _ in 0..<150 {
            fleet.syncAll([bID])
            b.executor.drain()
            fleet.syncAll([aID, cID])
            if results.get().contains(where: { $0.state == "login_url" }) { gotURL = true; break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let urlResult = results.get().first { $0.state == "login_url" }
        let url = urlResult?.object["url"] as? String ?? ""
        check(gotURL && url.contains(String(canary.prefix(20))) && HandsCloudflared.loginURL(in: url) != nil,
              "A 替 B 登入：B 跑自己的 cloudflared login，授權網址經主設備只回到 A（A 自己的私訊框開）", "\(results.get().map(\.state))")
        let publicView = text(fleet.authority.view())
        let bStatus = text(HandsRemote.status(HandsRemote.Host(service: b.service, phase: { .stopped }, setup: { b.setup.snapshot },
                                                               localDeviceID: { bID }, flow: b.setup)))
        check(!publicView.contains(String(canary.prefix(20))) && !bStatus.contains(String(canary.prefix(20))) && !bStatus.contains("login_url")
              && b.setup.statusPayload()["url"] as? String == "" && !text(b.setup.statusPayload()).contains(String(canary.prefix(20))),
              "登入網址不在公共狀態（主設備的全貌、remote_hands_status、給 AI 的 hands_setup_status）")
        let cView = try fleet.authority.sync(from: cID, report: nil)
        check((cView["results"] as? [Any] ?? []).isEmpty && !text(cView).contains(String(canary.prefix(20))),
              "C 拿不到（只給擁有者 A）")
        var cPost = false
        do { try fleet.authority.post(HandsBuildResult(operationID: id, seq: 9, final: true, object: ["state": "authorized"]), from: cID) }
        catch HandsBuildMailboxError.notTarget { cPost = true }
        check(cPost, "C 冒充 B 交結果：不收（只有這件事的目標那台能交）")
        b.runner.authorize.set(true)
        var finished = false
        for _ in 0..<150 {
            fleet.syncAll([aID])
            if results.get().contains(where: \.final) { finished = true; break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let final = results.get().first(where: \.final)
        let state = b.setup.snapshot
        let account = b.accounts.account(accountID)
        check(finished && final?.state == "authorized" && final?.object["account"] as? String == "Fixture Account"
              && b.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + zoneID)
              && !a.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + zoneID),
              "授權存在 B（B 的鑰匙圈），A 沒有；結束的結果（帳號名稱）回到 A", "\(String(describing: final?.object))")
        check(b.runner.nonLogin.isEmpty && state.tunnelID == nil && state.publicHost == nil && state.accountID == nil && state.zoneID == nil
              && account?.selectedDomain == nil && b.service.settings.load().publicHost == nil
              && state.step(.authorize).message == HandsSetup.chooseDomainMessage,
              "登入只是登入：沒有建通道、沒有 DNS、沒有採用帳號與網域（等使用者選、按套用）", "\(b.runner.nonLogin)")
        let beforeAck = fleet.authority.mailbox.debugState(id)
        fleet.syncAll([aID])   // A 下一輪帶 ack
        let leftovers = fleet.authority.mailbox.debugState(id)
        check(beforeAck.exists && !leftovers.exists,
              "擁有者 ack 了最後一則＝主設備上這件整個清掉（完成即清；沒 ack 之前留著，回應掉了拿得回來）")
        let allFiles = (FileManager.default.enumerator(atPath: fleet.base.path)?.allObjects as? [String] ?? [])
            .map { fleet.base.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        check(!allFiles.contains(String(canary.prefix(20))) && !allFiles.contains("W183BUILDAPITOKEN"),
              "登入網址與授權的 token 沒有落在任何檔案（狀態檔、信箱、紀錄）")
    }

    // MARK: - 7. 信箱的邊界：重播、取消先到、逾時、P 重開

    @MainActor static func mailboxEdgeCases(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("mailbox"), keys: keys)
        let a = try fleet.add(aID, name: "Laptop A"), b = try fleet.add(bID, name: "Studio B")
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true)])
        fleet.syncAll()
        let now = fleet.clock.now()
        func intent(_ action: String, id: String = UUID().uuidString.lowercased(), payload: [String: Any] = [:], expires: TimeInterval = 60,
                    epoch: String? = nil) throws -> HandsBuildIntent {
            try HandsBuildIntent.submission(HandsBuildIntent.submissionWire(operationID: id, action: action, target: bID, attempt: nil,
                                                                            configRevision: fleet.store.load()?.configRevision ?? 0, setupEpoch: epoch,
                                                                            expiresAt: now.addingTimeInterval(expires), payload: payload),
                                            owner: aID, now: now)
        }
        let posted = HandsLocked<[HandsBuildResult]>([])
        b.executor.post = { result in posted.update { $0.append(result) } }
        // 取消先到：墓碑，晚到的登入不做、不開窗口。
        let loginID = UUID().uuidString.lowercased()
        b.executor.executeNow(try intent("login_cancel", payload: ["operation_id": loginID]))
        b.executor.executeNow(try intent("login", id: loginID))
        b.executor.drain()
        check(posted.get().last?.state == "cancelled" && b.runner.logins == 0, "取消比登入先到：墓碑，晚到的那件不做（沒有開授權頁）")
        // 重播同一件：不重做。（W183 R8c 審查：解除安全鎖要帶 setupEpoch、事故編號、撤銷世代。）
        let generation = fleet.store.load()?.entry(bID)?.revocationGeneration ?? 0
        let unlock = try intent("unlock_safety", payload: ["incident": fixtureIncident, "revocation_generation": generation], epoch: b.setup.setupEpoch)
        b.executor.executeNow(unlock)
        b.executor.executeNow(unlock)
        let replay = posted.get().suffix(2).map(\.state)
        check(replay == ["done", "duplicate"], "同一件再送一次（P 重播、A 重送）：B 不重做（冪等紀錄在 B）", "\(replay)")
        let reopened = HandsBuildExecutor(dependencies: b.executor.dependencies, ledgerURL: b.executor.ledgerURL)
        reopened.post = { result in posted.update { $0.append(result) } }
        reopened.executeNow(unlock)
        check(posted.get().last?.state == "duplicate", "B 重開之後重播：一樣不重做（紀錄在磁碟）")
        // 逾時：取件期限過了＝不做；世代不對＝不做。
        let late = try intent("unlock_safety", expires: 1)
        fleet.clock.advance(5)
        b.executor.executeNow(late)
        check(posted.get().last?.object["reason"] as? String == "expired", "過期的意圖：B 不做")
        fleet.clock.reset()
        b.executor.executeNow(try intent("login", epoch: "stale-epoch"))
        check(posted.get().last?.object["reason"] as? String == "epoch_stale" && b.runner.logins == 0, "B 的 setupEpoch 對不上（B 重開過、取消過）：不做")
        // P 重開：信箱全部作廢；B 交結果＝不認得，不會重開任何東西。
        let results = HandsLocked<[HandsBuildResult]>([])
        let id = try a.sync.submit(action: "unlock_safety", target: bID) { result in results.update { $0.append(result) } }
        fleet.authority.mailbox.reset()
        var unknown = false
        do { try fleet.authority.post(HandsBuildResult(operationID: id, seq: 0, final: true, object: ["state": "done"]), from: bID) }
        catch HandsBuildMailboxError.unknownOperation { unknown = true }
        fleet.syncAll([bID])
        let quiet = results.get().isEmpty
        fleet.syncAll([aID])   // A 帶「還在等哪幾件」：P 不認得＝gone
        check(unknown && quiet && results.get().count == 1 && results.get().first?.final == true && results.get().first?.state == "unknown",
              "P 重開：信箱作廢，B 拿不到那件、交結果也不收；A 收成「結果未知」（不重做、也不會永遠等）", "\(results.get().map(\.state))")
        // 擁有者不能冒名：送給主設備的意圖，owner 一律是驗章得到的那台。
        var conflict = false
        let dup = HandsBuildIntent.submissionWire(operationID: id, action: "revoke_all", target: bID, attempt: nil, configRevision: 0, setupEpoch: nil,
                                                  expiresAt: now.addingTimeInterval(60), payload: [:])
        do {
            try fleet.authority.submit(try HandsBuildIntent.submission(dup, owner: aID, now: now))
            try fleet.authority.submit(try HandsBuildIntent.submission(dup.merging(["action": "unlock_safety"]) { $1 }, owner: aID, now: now))
        } catch HandsBuildMailboxError.conflict { conflict = true }
        check(conflict, "同一個 operationID 送不同內容：不收")
        var badHash = false
        var forged = dup
        forged["operation_id"] = UUID().uuidString.lowercased()
        forged["payload"] = ["x": 1]
        do { _ = try HandsBuildIntent.submission(forged, owner: aID, now: now) } catch HandsBuildMailboxError.invalid("payload_hash") { badHash = true }
        check(badHash, "payload 跟雜湊對不上：主設備不收（P 自己重算）")
    }

    // MARK: - 8. A 替 B 連線：碼只到 A（經主設備的信箱）

    @MainActor static func connectForOther(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("connect"), keys: keys)
        let a = try fleet.add(aID, name: "Laptop A")
        let c = try fleet.add(cID, name: "Desk C")
        let aSync = a.sync!
        let world = try HandsConnectAcceptance.World(base.appendingPathComponent("connect-world"), "b-host", owner: aID,
                                                     link: { _ in HandsConnectMailboxLink(target: HandsBuildAcceptance.bID, sync: aSync, timeout: 20) })
        let b = try fleet.add(bID, name: "Studio B", service: world.service)
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        fleet.syncAll()
        // 泵：每 40 毫秒三台各同步一輪（B 取件、交結果；A 取結果）。
        let pumping = HandsLocked(true)
        let pump = Thread {
            while pumping.get() {
                fleet.syncAll([bID, aID, cID])
                Thread.sleep(forTimeInterval: 0.04)
            }
        }
        pump.start()
        defer { pumping.set(false) }
        let chatgpt = HandsConnectAcceptance.FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        let confirmed = await waitUntil(20) { HandsConnectAcceptance.isConfirm(world.flow.card) }
        check(confirmed && world.flow.offerShown?.hostDeviceID == bID, "A 看得到 B 的［連線］卡（卡片內容經信箱從 B 拿）",
              "\(String(describing: world.flow.card))")
        world.flow.connect()
        let paired = await waitUntil(40) { world.pairing?.pairingCode != nil }
        let attempt = world.attemptID ?? ""
        let tx = world.service.auth.attemptTransaction(attempt)
        check(paired && world.pairing?.pairingCode == tx?.pairingCode && !attempt.isEmpty,
              "A 替 B 連線：B 開窗口、核對 A 的 Pod 看到的配對頁（第二版證據）後，8 碼只回到 A", "\(String(describing: world.flow.card))")
        // C 冒充：拿 A 的 attempt 問 B 的狀態＝不是擁有者，不給碼。
        let cResult = try? await c.sync.request(target: bID, action: "connect",
                                                payload: ["remote_op": "connect_status", "attempt_id": attempt, "expires_at": Int(Date().timeIntervalSince1970 + 60)],
                                                timeout: 15)
        check(cResult?["reason"] as? String == HandsConnectRefusal.notOwner.rawValue && !text(cResult ?? [:]).contains(tx?.pairingCode ?? "NOPE"),
              "C 拿 A 的 attempt 去問：B 拒絕（不是擁有者），沒有碼", "\(String(describing: cResult))")
        check(!text(fleet.authority.view()).contains(tx?.pairingCode ?? "NOPE"), "主設備的公共狀態（全貌）沒有配對碼")
        let code = try chatgpt.submit(tx?.pairingCode ?? "")
        let access = try chatgpt.token(code)
        try chatgpt.tools(access)
        let connected = await waitUntil(40) { world.flow.phase == .connected }
        check(connected && b.service.auth.grant(forAccess: access)?.provisional == false,
              "B 的 grant 第一次 /mcp、A 核對 Pod 帳號確認：已連線（全部經主設備的信箱）")
        check(world.pod.calls.filter { $0.hasPrefix("create") }.count == 1, "同一個 Pod 這一輪只建一個連接器")
        pumping.set(false)
    }

    // MARK: - 9. 交換兩台的碼卡／token／attempt／refresh：全拒

    @MainActor static func swapRefusals(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let root = base.appendingPathComponent("swap", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func host(_ name: String, id: String, publicHost: String) throws -> (HandsService, HandsConnectHost) {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let service = HandsService(paths: HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(dir.path) ?? dir.path).appendingPathComponent("hands")))
            service.deviceIDOverride = id
            service.projectsOverride = { [] }
            _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = id; $0.publicHost = publicHost }
            service.auth.binding = { HandsGrantBinding(hostDeviceID: id, issuer: "https://" + publicHost, resource: "https://\(publicHost)/mcp", generation: 0) }
            let connect = HandsConnectHost(service: service, epoch: { "e-" + name }, localDeviceID: { id }, hostName: { name }, serviceRunning: { true })
            connect.attach()
            return (service, connect)
        }
        let (aService, aHost) = try host("a", id: aID, publicHost: "os-for-chatgpt-laptopa.example.com")
        let (bService, bHost) = try host("b", id: bID, publicHost: "os-for-chatgpt-studiob.example.com")
        let (results, attempts) = try await HandsConnectOffMain.run { () -> ([String: Bool], [String]) in
            var out: [String: Bool] = [:]
            let a = try swapBegin(aService, aHost), b = try swapBegin(bService, bHost)
            let evidence = swapEvidence
            // B 的配對頁證據（綁 B）拿去 A：對不上＝終止、不給碼。
            let swapped = try aHost.status(attemptID: a.attempt, sender: pID, evidence: evidence(b, bID))
            out["evidence"] = swapped.state == .refused && swapped.transaction?.pairingCode == nil
            // 目標寫成 A、其他都是 B 的：一樣對不上（target 在證據裡）。
            let retarget = try? bHost.status(attemptID: b.attempt, sender: pID, evidence: evidence(b, aID))
            out["target"] = retarget?.state == .refused
            // A 的 attempt 拿去問 B：B 不認得。
            var unknown = false
            do { _ = try bHost.status(attemptID: a.attempt, sender: pID, evidence: nil) } catch HandsConnectRefusal.unknownAttempt { unknown = true }
            out["attempt"] = unknown
            return (out, [a.attempt, b.attempt])
        }
        check(results["evidence"] == true, "交換碼卡：B 的配對頁證據拿到 A 用＝終止、不給碼", "\(results)")
        check(results["target"] == true, "證據綁 target：同一組參數寫成別台＝終止")
        check(results["attempt"] == true && attempts.count == 2, "交換 attempt：A 的 attempt 拿去 B＝不認得")
        // token 與 refresh：B 的拿到 A 用一律不認；整個 auth.json 搬到 A 也不認（grant 綁著 B）。
        let bToken = try pair(bService, host: "os-for-chatgpt-studiob.example.com")
        check(!tools(aService, bToken), "交換 token：B 的 access token 在 A 不認")
        let copied = root.appendingPathComponent("copied-auth.json")
        try FileManager.default.copyItem(at: bService.auth.url, to: copied)
        let foreign = HandsAuth(url: copied)
        foreign.binding = { HandsGrantBinding(hostDeviceID: aID, issuer: "https://os-for-chatgpt-laptopa.example.com",
                                              resource: "https://os-for-chatgpt-laptopa.example.com/mcp", generation: 0) }
        check(foreign.grant(forAccess: bToken) == nil && HandsAuth(url: copied).grant(forAccess: bToken) != nil,
              "B 的授權檔整個搬到 A：grant 綁著 B（設備、網址）＝不認（同一份檔案不核綁定才認得）")
        var refreshRefused = false
        do {
            _ = try aService.handle(method: "hands_auth", params: ["op": "token", "grant_type": "refresh_token", "refresh_token": "tatwoh_rt_" + String(repeating: "x", count: 43),
                                                                  "client_id": "hc_" + String(repeating: "0", count: 24)])
        } catch { refreshRefused = true }
        check(refreshRefused, "交換 refresh token：A 不認 B 的（client 與 refresh 都不在 A）")
        // W183 R8c 審查（GPT-6 中）：有效的 grant 逐欄篡改（issuer、resource、主機、世代；拿掉或換掉）＝一律不認。
        func tampered(_ change: (inout [String: Any]) -> Void) throws -> Bool {
            let url = root.appendingPathComponent("tamper-\(UUID().uuidString.prefix(6)).json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: bService.auth.url)) as? [String: Any] ?? [:]
            var grants = object["grants"] as? [[String: Any]] ?? []
            guard !grants.isEmpty else { return false }
            for index in grants.indices { change(&grants[index]) }
            object["grants"] = grants
            try HandsFiles.writeAtomically(try JSONSerialization.data(withJSONObject: object), to: url)
            let copy = HandsAuth(url: url)
            copy.binding = { HandsGrantBinding(hostDeviceID: bID, issuer: "https://os-for-chatgpt-studiob.example.com",
                                               resource: "https://os-for-chatgpt-studiob.example.com/mcp", generation: 0) }
            return copy.grant(forAccess: bToken) == nil
        }
        let control = try tampered { _ in }
        let fieldResults = [
            try tampered { $0["issuer"] = "https://os-for-chatgpt-laptopa.example.com" }, try tampered { $0["issuer"] = nil },
            try tampered { $0["resource"] = nil }, try tampered { $0["resource"] = "https://os-for-chatgpt-laptopa.example.com/mcp" },
            try tampered { $0["hostDeviceID"] = nil }, try tampered { $0["hostDeviceID"] = aID },
            try tampered { $0["generation"] = nil }, try tampered { $0["generation"] = 7 }]
        check(!control && fieldResults.allSatisfy { $0 },
              "grant 的綁定逐欄核對：issuer、resource、主機、撤銷世代任何一欄拿掉或換掉都不認（沒改的那份照樣認得）", "\(control) \(fieldResults)")
        // 升級前的舊 grant（四欄都沒有）：這台有網址＝明確遷移一次（蓋上這台的綁定、之後照用）；沒網址＝撤銷（原因明確）。
        func legacyCopy() throws -> HandsAuth {
            let url = root.appendingPathComponent("legacy-\(UUID().uuidString.prefix(6)).json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: bService.auth.url)) as? [String: Any] ?? [:]
            object["grants"] = (object["grants"] as? [[String: Any]] ?? []).map { grant in
                var copy = grant
                for key in ["hostDeviceID", "issuer", "resource", "generation"] { copy[key] = nil }
                return copy
            }
            object["bindingUpgradedAt"] = nil
            try HandsFiles.writeAtomically(try JSONSerialization.data(withJSONObject: object), to: url)
            return HandsAuth(url: url)
        }
        let binding = HandsGrantBinding(hostDeviceID: bID, issuer: "https://os-for-chatgpt-studiob.example.com",
                                        resource: "https://os-for-chatgpt-studiob.example.com/mcp", generation: 0)
        let upgraded = try legacyCopy()
        upgraded.binding = { binding }
        let refusedBefore = upgraded.grant(forAccess: bToken) == nil
        let stamped = upgraded.upgradeLegacyBindings(binding)
        let usableAfter = upgraded.grant(forAccess: bToken) != nil && upgraded.activeGrantIDs.count == 1
        let secondTime = upgraded.upgradeLegacyBindings(binding)
        let noHost = try legacyCopy()
        let dropped = noHost.upgradeLegacyBindings(HandsGrantBinding(hostDeviceID: bID, issuer: nil, resource: nil, generation: 0))
        check(refusedBefore && stamped.stamped == 1 && stamped.revoked == 0 && usableAfter && secondTime.stamped == 0 && secondTime.revoked == 0
              && dropped.stamped == 0 && dropped.revoked == 1 && noHost.activeGrantIDs.isEmpty
              && noHost.grants().first?.revokeReason == "binding_upgrade",
              "升級前的舊 grant：先不認；這台有網址＝明確遷移一次（計數與能不能用一致）；沒網址＝用 binding_upgrade 撤銷",
              "\(stamped) \(secondTime) \(dropped)")
        let generationMoved = HandsAuth(url: copied)
        generationMoved.binding = { HandsGrantBinding(hostDeviceID: bID, issuer: "https://os-for-chatgpt-studiob.example.com",
                                                      resource: "https://os-for-chatgpt-studiob.example.com/mcp", generation: 1) }
        check(generationMoved.grant(forAccess: bToken) == nil, "撤銷世代變了（B 被關過又打開）：舊 grant 不認")
        var resourceRefused = false
        do {
            let chatgpt = HandsConnectAcceptance.FakeChatGPT(service: aService)
            try aService.startPairing()
            try chatgpt.register()
            _ = try aService.handle(method: "hands_auth", params: [
                "op": "authorize_begin", "client_id": chatgpt.clientID, "redirect_uri": chatgpt.redirect, "code_challenge": chatgpt.challenge,
                "code_challenge_method": "S256", "state": chatgpt.state, "resource": "https://os-for-chatgpt-studiob.example.com/mcp", "scope": "tatwo.hands"])
        } catch let error as HandsWireError { resourceRefused = error.code == "invalid_request" }
        check(resourceRefused, "App 端精確核 resource：別台的網址（B 的 /mcp）在 A 開不了交易")
    }

    struct SwapSide {
        let attempt: String
        let chatgpt: HandsConnectAcceptance.FakeChatGPT
        let offer: HandsConnectOffer
    }

    /// 在一台主機上開一個 attempt 與它的交易（擁有者＝主設備）。在背景叫（主機核對範圍可能要回主執行緒）。
    static func swapBegin(_ service: HandsService, _ connect: HandsConnectHost) throws -> SwapSide {
        let offer = try connect.offer()
        let attempt = UUID().uuidString
        _ = try connect.begin(HandsConnectRequest(attemptID: attempt, setupEpoch: offer.setupEpoch, ownerDeviceID: pID, scopeDigest: offer.digest,
                                                  mcpURL: offer.mcpURL), sender: pID)
        let chatgpt = HandsConnectAcceptance.FakeChatGPT(service: service)
        try chatgpt.register()
        _ = try service.handle(method: "hands_auth", params: [
            "op": "authorize_begin", "client_id": chatgpt.clientID, "redirect_uri": chatgpt.redirect, "code_challenge": chatgpt.challenge,
            "code_challenge_method": "S256", "state": chatgpt.state, "resource": offer.mcpURL, "scope": "tatwo.hands"])
        return SwapSide(attempt: attempt, chatgpt: chatgpt, offer: offer)
    }

    /// 擁有者那端會算的第二版證據（綁 target）。
    static func swapEvidence(_ side: SwapSide, _ target: String) -> String {
        let v1 = HandsAuth.evidenceHash(clientID: side.chatgpt.clientID, redirectURI: side.chatgpt.redirect, state: side.chatgpt.state,
                                        challenge: side.chatgpt.challenge)
        return HandsAuth.boundEvidence(v1, target: target, issuer: "https://" + side.offer.publicHost, resource: side.offer.mcpURL,
                                       attempt: side.attempt, setupEpoch: side.offer.setupEpoch)
    }

    // MARK: - 10. 環境登入加帳號：build 開著也零 DNS 副作用

    @MainActor static func environmentLoginNoDNS(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("envlogin"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One", lookup: [otherZoneID: "example.org"])
        _ = try fleet.update([.setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        var state = HandsSetupState()
        state.accountID = accountID; state.zoneID = zoneID; state.domain = domain
        state.tunnelID = "0f0e0d0c-0b0a-4908-8706-050403020100"; state.tokenTunnelID = state.tunnelID; state.publicHost = "os-for-chatgpt.example.com"
        state.steps[HandsSetupStep.authorize.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date())
        state.steps[HandsSetupStep.tunnel.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date())
        try p.preloadSetupState(state)
        let fresh = try fleet.add(pID, name: "Primary One", service: p.service, lookup: [otherZoneID: "example.org"])   // 重開：讀預先寫好的狀態
        try fresh.accounts.upsert(accountID: accountID, name: "Fixture Account", domain: CloudflareDomain(name: domain, zoneID: zoneID),
                                  cert: certPEM(zone: zoneID, token: "x"))
        try fresh.accounts.select(accountID: accountID, zoneID: zoneID)
        _ = try fresh.service.updateSettings { $0.enabled = true; $0.hostDeviceID = pID; $0.publicHost = "os-for-chatgpt.example.com" }
        fresh.phase.set(.running(url: "https://os-for-chatgpt.example.com/mcp"))
        fresh.runner.cert.set(certPEM(zone: otherZoneID, account: String(repeating: "e5", count: 16), token: "W183BUILDENVTOKEN"))
        fresh.runner.authorize.set(true)
        fresh.setup.login(trigger: .user)
        let done = await waitUntil(20) { !fresh.setup.isBusy && fresh.accounts.account(String(repeating: "e5", count: 16)) != nil }
        let after = fresh.setup.snapshot
        let settings = fresh.service.settings.load()
        check(done && fresh.runner.nonLogin.isEmpty && after.accountID == accountID && after.zoneID == zoneID
              && after.publicHost == "os-for-chatgpt.example.com" && after.tunnelID == state.tunnelID
              && settings.enabled && settings.publicHost == "os-for-chatgpt.example.com" && fresh.starts.get() == 0
              && fresh.accounts.account(String(repeating: "e5", count: 16))?.selectedDomain == nil
              && fresh.accounts.account(accountID)?.selectedDomain == zoneID,
              "環境登入加一個新帳號（build 開著、網址在用）：只多一個帳號——不採用、不換網域、不動通道與網址、零 DNS、不叫關口",
              "\(fresh.runner.nonLogin) \(String(describing: after.zoneID)) starts=\(fresh.starts.get())")
    }

    // MARK: - 11. 安全停機鎖：輪詢、重新勾選、重開、設定同步都不清；只有明確解除（綁事故編號、setupEpoch、撤銷世代）

    @MainActor static func safetyLockChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("safety"), keys: keys)
        let b = try fleet.add(bID, name: "Studio B")
        let host = "os-for-chatgpt-studiob.example.com", tunnel = "6b6b6b6b-6b6b-46b6-86b6-6b6b6b6b6b6b"
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        try b.accounts.upsert(accountID: accountID, name: "Fixture Account", domain: CloudflareDomain(name: domain, zoneID: zoneID),
                              cert: certPEM(zone: zoneID, token: "x"))
        try b.accounts.select(accountID: accountID, zoneID: zoneID)
        try b.accounts.setTunnel(accountID: accountID, tunnelID: tunnel)
        try b.accounts.saveTunnelToken("w183build-fixture-tunnel-token")
        _ = try b.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = bID }
        fleet.syncAll([bID])
        // 真的關口（W183 R8c 審查 Claude：之前的反例在自測環境空轉）：allowUnderTest、沒有 cloudflared（萬一鎖沒擋住也起不來）。
        var deps = ChatGPTHandsService.Dependencies()
        deps.handsRoot = b.paths.root
        deps.allowUnderTest = true
        deps.monitorInterval = 3600
        deps.cloudflared = { nil }
        deps.fetchRanges = { done in done(.failure(HandsWireError.disabled)) }
        deps.localDeviceID = { bID }
        deps.hostConfirmed = { [permit = b.permit] in permit.permits($0) }
        deps.prepareWorkspace = { nil }
        let gateway = ChatGPTHandsService(dependencies: deps)
        check(ChatGPTHandsService.armSafety(gateway.paths), "準備：起關口前預寫（帶事故編號）")
        ChatGPTHandsService.recordSafetyStop(gateway.paths)
        let incident = ChatGPTHandsService.safetyIncident(gateway.paths)
        check(ChatGPTHandsService.safetyState(gateway.paths) == .locked && incident != nil, "準備：安全停機鎖在磁碟上、有事故編號")
        // B 的設定流程接上這個關口：開始＝保留安全鎖的那個（retryKeepingSafetyLock）；關口狀態就是它的。
        var state = HandsSetupState()
        state.accountID = accountID; state.zoneID = zoneID; state.domain = domain; state.hostDeviceID = bID
        state.tunnelID = tunnel; state.tokenTunnelID = tunnel; state.publicHost = host
        state.steps[HandsSetupStep.authorize.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date())
        state.steps[HandsSetupStep.tunnel.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date())
        try b.preloadSetupState(state)
        var setupDeps = b.setup.dependencies
        setupDeps.startService = { gateway.retryKeepingSafetyLock() }
        setupDeps.retryService = { gateway.retryKeepingSafetyLock() }
        setupDeps.resumeService = { gateway.settingsDidChange() }
        setupDeps.servicePhase = { gateway.debugPhase }
        setupDeps.serviceTimeout = 6
        let setup = HandsSetup(dependencies: setupDeps)
        let reconciler = HandsBuildReconciler(service: b.service, applied: HandsBuildAppliedStore(url: b.paths.appDir.appendingPathComponent("safety-applied.json")),
                                              resume: { _ = setup.resumeIfEnabled() },
                                              serviceChanged: { gateway.settingsDidChange() }, cancelConnect: { _ in }, cancelSetup: { setup.cancel() })
        for _ in 0..<3 {
            _ = try fleet.update([.select(device: bID, selected: false)])
            fleet.syncAll([bID])
            reconciler.apply(b.permit.state(bID), configRevision: fleet.store.load()?.configRevision, local: bID, primary: pID)
            _ = try fleet.update([.select(device: bID, selected: true)])
            fleet.syncAll([bID])
            reconciler.apply(b.permit.state(bID), configRevision: fleet.store.load()?.configRevision, local: bID, primary: pID)
            _ = await waitUntil(10) { !setup.isBusy }
            gateway.debugEvaluate()
        }
        _ = try b.service.updateSettings { $0.enabled = true; $0.publicHost = host; $0.hostDeviceID = bID }
        let ran = setup.runAll(trigger: .user, allowLogin: false)   // 使用者在這台重新打開（跑整條）：stepStart 叫的是保留安全鎖的那個
        _ = await waitUntil(15) { !setup.isBusy }
        let reachedStart = setup.snapshot.step(.start).status == .failed && setup.snapshot.step(.start).message == ChatGPTHandsService.tamperedText
        let restarted = ChatGPTHandsService(dependencies: deps)   // App 重開
        restarted.debugEvaluate()
        gateway.debugEvaluate()
        check(ran && reachedStart && ChatGPTHandsService.safetyState(gateway.paths) == .locked
              && gateway.debugPhase == .failed(ChatGPTHandsService.tamperedText) && restarted.debugPhase == .failed(ChatGPTHandsService.tamperedText),
              "輪詢套用、重新勾選三次、使用者重新打開（真的走到 stepStart、叫真的關口）、App 重開：安全停機鎖都還在（沒有冒充人工重試）",
              "\(setup.snapshot.step(.start).message) \(gateway.debugPhase)")
        let posted = HandsLocked<[HandsBuildResult]>([])
        let executorB = HandsBuildExecutor(dependencies: .init(
            localID: { bID }, setup: { setup }, service: { b.service },
            remoteHost: { HandsRemote.Host(service: b.service, phase: { .stopped }, setup: { nil }, localDeviceID: { bID }) },
            unlockSafety: { gateway.unlockSafety(incident: $0) },
            current: { [store = fleet.store] in
                guard let config = store.load() else { return nil }
                return (config.slice(for: bID), config.configRevision)
            },
            accounts: { b.accounts }, now: { fleet.clock.now() }),
                                           ledgerURL: b.paths.appDir.appendingPathComponent("safety-ops.json"))
        executorB.post = { result in posted.update { $0.append(result) } }
        let generation = fleet.store.load()?.entry(bID)?.revocationGeneration ?? -1
        func unlockIntent(incident: String?, epoch: String?, generation gen: Int) throws -> HandsBuildIntent {
            var payload: [String: Any] = ["revocation_generation": gen]
            if let incident { payload["incident"] = incident }
            return try HandsBuildIntent.submission(HandsBuildIntent.submissionWire(
                operationID: UUID().uuidString.lowercased(), action: "unlock_safety", target: bID, attempt: nil, configRevision: 0, setupEpoch: epoch,
                expiresAt: fleet.clock.now().addingTimeInterval(60), payload: payload), owner: aID, now: fleet.clock.now())
        }
        executorB.executeNow(try unlockIntent(incident: incident, epoch: nil, generation: generation))
        let noEpoch = posted.get().last?.object["reason"] as? String
        executorB.executeNow(try unlockIntent(incident: incident, epoch: "stale-epoch", generation: generation))
        let staleEpoch = posted.get().last?.object["reason"] as? String
        executorB.executeNow(try unlockIntent(incident: "w183oldincident", epoch: setup.setupEpoch, generation: generation))
        let oldIncident = posted.get().last?.object["reason"] as? String
        executorB.executeNow(try unlockIntent(incident: incident, epoch: setup.setupEpoch, generation: generation + 1))
        let oldGeneration = posted.get().last?.object["reason"] as? String
        gateway.debugEvaluate()
        check(noEpoch == "epoch_missing" && staleEpoch == "epoch_stale" && oldIncident == "incident_changed" && oldGeneration == "generation_changed"
              && ChatGPTHandsService.safetyState(gateway.paths) == .locked,
              "晚到的舊解除（沒帶 setupEpoch、setupEpoch 舊了、事故編號是上一次的、撤銷世代對不上）：一律不解除",
              "\(String(describing: noEpoch)) \(String(describing: staleEpoch)) \(String(describing: oldIncident)) \(String(describing: oldGeneration))")
        executorB.executeNow(try unlockIntent(incident: incident, epoch: setup.setupEpoch, generation: generation))
        gateway.debugEvaluate()
        check(ChatGPTHandsService.safetyState(gateway.paths) == .clear && posted.get().last?.state == "done",
              "使用者對這台明確按「解除安全鎖」（這一次的事故編號、setupEpoch、撤銷世代都對）：才解除")
    }

    // MARK: - 12. 離線 B 的通道不被清；DNS 查不到禁止刪；只列自己有建立證據的

    @MainActor static func offlineTunnelKept(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("tunnels"), keys: keys)
        let a = try fleet.add(aID, name: "Laptop A")
        let tunnelB = "1b1b1b1b-1b1b-41b1-81b1-1b1b1b1b1b1b", oldA = "2a2a2a2a-2a2a-42a2-82a2-2a2a2a2a2a2a", currentA = "3a3a3a3a-3a3a-43a3-83a3-3a3a3a3a3a3a"
        let noEvidence = "4c4c4c4c-4c4c-44c4-84c4-4c4c4c4c4c4c"
        _ = fleet.store.recordResources(device: bID, [.init(hostname: "os-for-chatgpt-studiob.example.com", deviceID: bID, tunnelID: tunnelB,
                                                             zoneID: zoneID, evidence: "created", recordedAt: Date())])
        _ = try fleet.update([.setEnabled(true), .select(device: aID, selected: true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        var state = HandsSetupState()
        state.accountID = accountID; state.zoneID = zoneID; state.domain = domain
        state.tunnelID = currentA; state.tokenTunnelID = currentA
        state.createdTunnels = [oldA, currentA, tunnelB]   // 就算這台（被竄改的狀態檔）宣稱建過 B 的，主設備的所有權表照樣擋
        state.steps[HandsSetupStep.authorize.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date())
        try a.preloadSetupState(state)
        let fresh = try fleet.add(aID, name: "Laptop A", service: a.service)
        try fresh.accounts.upsert(accountID: accountID, name: "Fixture Account", domain: CloudflareDomain(name: domain, zoneID: zoneID),
                                  cert: certPEM(zone: zoneID, token: "x"))
        let row = { (id: String) in "{\"id\":\"\(id)\",\"name\":\"tatwo-hands-\(id.prefix(8))\",\"created_at\":\"2026-09-28T00:00:00Z\",\"deleted_at\":\"0001-01-01T00:00:00Z\",\"connections\":[]}" }
        fresh.runner.listed.set("[" + [tunnelB, oldA, noEvidence].map(row).joined(separator: ",") + "]")
        fleet.offline.set([bID])   // B 離線（沒有連線、也沒在回報）
        let targets = HandsLocked<Set<String>?>([])
        let sync = fresh.sync!
        var deps = fresh.setup.dependencies
        deps.foreignTunnels = { sync.foreignTunnelIDs() }
        deps.dnsTunnelTargets = { _, _, done in done(targets.get()) }
        let setup = HandsSetup(dependencies: deps)
        fleet.syncAll([aID])   // A 從主設備拿到所有權表
        check(sync.foreignTunnelIDs()?.contains(tunnelB) == true, "A 從主設備拿到所有權表：B 的通道是 B 的（B 離線照樣）")
        setup.checkUnusedTunnels()
        let listed = await waitUntil(15) { setup.unusedTunnels != nil && !setup.checkingTunnels }
        let ids = setup.unusedTunnels?.map(\.id) ?? []
        check(listed && ids == [oldA], "沒用到的通道只列 A 自己有建立證據的：離線 B 的不列（沒有連線不等於沒有主人）、沒證據的不列",
              "\(ids)")
        targets.set(nil)
        _ = await waitUntil(5) { !setup.checkingTunnels }
        setup.checkUnusedTunnels()
        _ = await waitUntil(15) { !setup.checkingTunnels }
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(setup.unusedTunnels == nil, "DNS 查不到：整份不列（禁止刪）")
        let blank = HandsBuildSync(dependencies: {
            var d = fresh.sync.dependencies
            d.callPrimary = { _ in throw RemoteHostLinkError.tunnelUnavailable }
            return d
        }())
        check(blank.foreignTunnelIDs() == nil, "還沒從主設備拿到所有權表＝不知道＝不列任何通道")
        _ = blank
    }

    // MARK: - 13. 真的設備簽章 RPC（hands_build 走 DeviceDispatch.authenticate）

    static func signedRPC(_ check: Checker, _ base: URL, _ keys: Keys) throws {
        let root = base.appendingPathComponent("signed", isDirectory: true)
        let fm = FileManager.default
        let pRoot = root.appendingPathComponent("primary"), sRoot = root.appendingPathComponent("secondary")
        for dir in [pRoot.appendingPathComponent("entry"), sRoot.appendingPathComponent("entry"), pRoot.appendingPathComponent("live"),
                    sRoot.appendingPathComponent("live")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let pEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": pRoot.appendingPathComponent("entry").path], preference: nil)
        let sEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": sRoot.appendingPathComponent("entry").path], preference: nil)
        try DeviceIdentity(deviceID: pID, name: "Primary One", hardwareModel: "Fixture", role: .primary, epoch: 1,
                           primaryDeviceID: pID, updatedAt: Date()).encoded().write(to: pEntry.deviceJSON)
        try DeviceIdentity(deviceID: bID, name: "Studio B", hardwareModel: "Fixture", role: .secondary, epoch: 1,
                           primaryDeviceID: pID, updatedAt: Date()).encoded().write(to: sEntry.deviceJSON)
        let key = root.appendingPathComponent("paired-key"), hostKey = root.appendingPathComponent("host-key")
        for path in [key, hostKey] {
            let (status, _) = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path.path])
            guard status == 0 else { return check(false, "產生設備金鑰") }
        }
        let publicKey = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
        let pRegistry = DeviceRegistry(root: pRoot.appendingPathComponent("live"), authorizedKeysURL: pRoot.appendingPathComponent("authorized_keys"))
        let sRegistry = DeviceRegistry(root: sRoot.appendingPathComponent("live"), authorizedKeysURL: sRoot.appendingPathComponent("authorized_keys"))
        let fingerprint = try pRegistry.authorize(publicKey: publicKey, deviceID: bID)
        _ = try pRegistry.add(DeviceRecord(id: bID, name: "Studio B", host: "127.0.0.1", user: "fixture", sshPort: 1, publicKeyFingerprint: fingerprint,
                                           addedAt: Date(), lastSeenAt: Date(), workdirMap: [:], role: .secondary, epoch: 1))
        // 副設備記的主設備：主機金鑰＋配對時 pin 住的簽章識別（主設備簽信封的那一把）。
        let hostPublic = try String(contentsOf: URL(fileURLWithPath: hostKey.path + ".pub"), encoding: .utf8)
        _ = try sRegistry.add(DeviceRecord(id: pID, name: "Primary One", host: "127.0.0.1", user: "fixture", sshPort: 1,
                                           publicKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: hostPublic), addedAt: Date(), lastSeenAt: Date(),
                                           workdirMap: [:], role: .primary, epoch: 1,
                                           hostKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: hostPublic), clientKeyFingerprint: keys.fingerprint))
        let fleet = try Fleet(root.appendingPathComponent("fleet"), keys: keys)
        _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true)])
        let primary = DeviceDispatch(entry: pEntry, registry: pRegistry, retireBackup: { _ in })
        let calls = HandsLocked(0)
        let secondary = DeviceDispatch(entry: sEntry, registry: sRegistry, environment: ["TATWO2_SSH_KEY_PATH": key.path], retireBackup: { _ in },
                                       rpc: { _, method, proof in
            do {
                let (sender, payload) = try primary.authenticate(method: method, proof: proof)
                guard method == HandsBuildRemote.method else { throw HandsBuildMailboxError.invalid("method") }
                calls.update { $0 += 1 }
                return try HandsBuildRemote.handle(payload: payload, sender: sender, authority: fleet.authority)
            } catch { throw RemoteHostLinkError.remoteError(String(describing: error)) }
        })
        let b = try fleet.add(bID, name: "Studio B", callPrimary: { payload in try secondary.callPrimary(method: HandsBuildRemote.method, payload: payload) })
        let trust = HandsBuildTrust.live(entry: sEntry, registry: sRegistry)
        check(trust?.pinnedPrimaryKey == keys.fingerprint && trust?.primaryID == pID, "副設備信的主設備公鑰＝配對時 pin 住的簽章識別")
        b.sync.syncNow()
        check(calls.get() == 1 && b.permit.permits(bID) && b.accepted.current(trust: b.trust)?.configRevision == fleet.store.load()?.configRevision,
              "hands_build 走真的設備簽章（authenticate 驗章、序號）：B 收到主設備簽的信封、有許可")
        var forged = false
        do { _ = try primary.authenticate(method: HandsBuildRemote.method, proof: ["body": Data("{}".utf8).base64EncodedString(), "signature": "", "publicKey": publicKey]) }
        catch { forged = true }
        check(forged, "沒有簽章的 hands_build：驗章不過")
    }

    // MARK: - 13b. 加入端補記主設備簽章那把（W183 R8 實機，v2.0.21.026 副設備；契約 §11.10）
    // 真的配對後，加入端（副設備）的紀錄只有主設備的主機金鑰、沒有客戶端金鑰（w91b-legacy-host-key-classified）；
    // 上面 signedRPC 的夾具直接放了 clientKeyFingerprint，所以沒抓到「副設備一律 unpinned、整台不收」。這裡照真的紀錄形狀做。
    // GPT-6 審查：先驗再落地（壞簽章零落地）、綁這次呼叫的主機金鑰（中途換配對＝不補）、完全沒 pin 的紀錄不補。
    static func joinSideLearnsPrimaryKey(_ check: Checker, _ base: URL, _ keys: Keys) throws {
        let root = base.appendingPathComponent("join-pin", isDirectory: true)
        let hostKey = root.appendingPathComponent("host-key"), otherHost = root.appendingPathComponent("other-host-key")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in [hostKey, otherHost] {
            guard try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path.path]).0 == 0 else {
                return check(false, "產生主機金鑰")
            }
        }
        let hostFingerprint = try DeviceRegistry.fingerprint(publicKey: String(contentsOfFile: hostKey.path + ".pub", encoding: .utf8))
        let otherHostFingerprint = try DeviceRegistry.fingerprint(publicKey: String(contentsOfFile: otherHost.path + ".pub", encoding: .utf8))
        let forgerFingerprint = try DeviceRegistry.fingerprint(publicKey: String(contentsOfFile: keys.forger + ".pub", encoding: .utf8))
        func registry(_ name: String, host: String?, client: String?, legacy: String = "") throws -> DeviceRegistry {
            let live = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
            let registry = DeviceRegistry(root: live, authorizedKeysURL: live.appendingPathComponent("authorized_keys"),
                                          knownHostsURL: live.appendingPathComponent("known_hosts"))
            _ = try registry.add(DeviceRecord(id: pID, name: "Primary One", host: "127.0.0.1", user: "fixture", sshPort: 1,
                                              publicKeyFingerprint: host ?? client ?? legacy, addedAt: Date(), lastSeenAt: Date(),
                                              workdirMap: [:], role: .primary, epoch: 1, hostKeyFingerprint: host, clientKeyFingerprint: client,
                                              hostKeyFingerprintSource: host.map { _ in DeviceFingerprintProvenance(source: "known_hosts", recordedAt: Date()) }))
            return registry
        }
        func record(_ registry: DeviceRegistry) -> DeviceRecord? { registry.list().first { HandsHostAuthority.same($0.id, pID) } }
        func trust(_ registry: DeviceRegistry) -> () -> HandsBuildTrust? {
            { HandsBuildTrust(localID: bID, primaryID: pID, epoch: 1, pinnedPrimaryKey: record(registry)?.pinnedClientKeyFingerprint) }
        }
        let clock = Clock()
        func learner(_ registry: DeviceRegistry) -> (hostPin: (String) -> String?, learn: (HandsBuildEnvelope, HandsBuildTrust, String) -> Void) {
            ({ primary in HandsBuildTrust.hostPin(primary: primary, registry: registry) },
             { envelope, trust, host in HandsBuildTrust.learnPrimaryKey(envelope: envelope, trust: trust, expectedHost: host, now: clock.now(), registry: registry) })
        }
        func fleet(_ name: String) throws -> Fleet {
            let fleet = try Fleet(root.appendingPathComponent(name), keys: keys)
            _ = try fleet.update([.setEnabled(true), .select(device: bID, selected: true)])
            return fleet
        }

        // 1. 原本的實機：加入端只有主機金鑰、不補記＝一律不收。
        let stuck = try registry("stuck", host: hostFingerprint, client: nil)
        let b0 = try fleet("fleet-before").add(bID, name: "Studio B", trust: trust(stuck))
        b0.sync.syncNow()
        check(trust(stuck)()?.pinnedPrimaryKey == nil && b0.accepted.current(trust: b0.trust) == nil,
              "加入端（只有主機金鑰）不補記：信封一律 unpinned、不收（v2.0.21.026 副設備的實況）")

        // 2. 補記：經 pin 住主機金鑰的通道拿到、驗得過的信封，補上主設備簽章那把；同一輪就收得下。
        let join = try registry("join", host: hostFingerprint, client: nil)
        let joinFleet = try fleet("fleet-join")
        let l2 = learner(join)
        let b = try joinFleet.add(bID, name: "Studio B", trust: trust(join), primaryHostPin: l2.hostPin, learnPrimaryKey: l2.learn)
        b.sync.syncNow()
        let learned = record(join)
        check(learned?.clientKeyFingerprint == keys.fingerprint && learned?.clientKeyFingerprintSource?.source == "hands_build_pinned_channel"
              && learned?.hostKeyFingerprint == hostFingerprint,
              "加入端補記主設備簽章那把（來源 hands_build_pinned_channel；主機金鑰不動）")
        check(b.accepted.current(trust: trust(join)())?.configRevision == joinFleet.store.load()?.configRevision && b.permit.permits(bID),
              "補記後同一輪就收下主設備簽的信封、有許可")

        // 3. 已經 pin 了別把：不補、不覆蓋、照樣不收。
        let pinned = try registry("pinned", host: hostFingerprint, client: forgerFingerprint)
        check(HandsBuildTrust.hostPin(primary: pID, registry: pinned) == nil, "已經 pin 住另一把簽章識別：呼叫前就不記主機金鑰（不補）")
        let l3 = learner(pinned)
        let c = try fleet("fleet-pinned").add(bID, name: "Studio B", trust: trust(pinned), primaryHostPin: l3.hostPin, learnPrimaryKey: l3.learn)
        c.sync.syncNow()
        check(c.accepted.current(trust: trust(pinned)()) == nil && record(pinned)?.clientKeyFingerprint == forgerFingerprint,
              "簽章那把對不上已 pin 的：照樣不收、不覆蓋（補記不放寬比對）")

        // 4. 壞簽章（通道回的信封驗不過）：什麼都不留（先驗再落地）。
        let bad = try registry("bad-signature", host: hostFingerprint, client: nil)
        let badFleet = try fleet("fleet-bad")
        let l4 = learner(bad), badAuthority = badFleet.authority
        let d = try badFleet.add(bID, name: "Studio B", callPrimary: { payload in
            var response = try Fleet.wire(try HandsBuildRemote.handle(payload: try Fleet.wire(payload), sender: bID, authority: badAuthority))
            if var envelope = response["envelope"] as? [String: Any], let body = (envelope["body"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                envelope["body"] = (body + Data(" ".utf8)).base64EncodedString()   // 內容多一個位元組＝簽章對不上
                response["envelope"] = envelope
            }
            return response
        }, trust: trust(bad), primaryHostPin: l4.hostPin, learnPrimaryKey: l4.learn)
        d.sync.syncNow()
        check(record(bad)?.clientKeyFingerprint == nil && d.accepted.current(trust: d.trust) == nil,
              "通道回的信封簽章驗不過：不補記（零落地）、不收")

        // 5. 呼叫途中重新配對（主機金鑰換了）：這次拿到的不補。
        let moved = try registry("re-paired", host: hostFingerprint, client: nil)
        let movedFleet = try fleet("fleet-moved")
        let l5 = learner(moved), movedAuthority = movedFleet.authority
        let e = try movedFleet.add(bID, name: "Studio B", callPrimary: { payload in
            let response = try Fleet.wire(try HandsBuildRemote.handle(payload: try Fleet.wire(payload), sender: bID, authority: movedAuthority))
            if var current = record(moved) {   // 回覆送達前，紀錄被移除再以同一個 id、另一把主機金鑰配對
                current.hostKeyFingerprint = otherHostFingerprint
                current.publicKeyFingerprint = otherHostFingerprint
                _ = try moved.add(current)
            }
            return response
        }, trust: trust(moved), primaryHostPin: l5.hostPin, learnPrimaryKey: l5.learn)
        e.sync.syncNow()
        check(record(moved)?.clientKeyFingerprint == nil && record(moved)?.hostKeyFingerprint == otherHostFingerprint
              && e.accepted.current(trust: e.trust) == nil,
              "呼叫途中主機金鑰換了（重新配對）：這次拿到的不補、不收")

        // 6. 完全沒 pin（主機、客戶端都沒有）、沒分流過的舊紀錄、不認得的主設備、待修指紋：不補。
        let none = try registry("no-pin", host: nil, client: nil)
        let l6 = learner(none)
        let f = try fleet("fleet-none").add(bID, name: "Studio B", trust: trust(none), primaryHostPin: l6.hostPin, learnPrimaryKey: l6.learn)
        f.sync.syncNow()
        check(record(none)?.pinnedHostKeyFingerprint == nil && HandsBuildTrust.hostPin(primary: pID, registry: none) == nil
              && record(none)?.clientKeyFingerprint == nil && f.accepted.current(trust: f.trust) == nil,
              "完全沒 pin 的紀錄（通道沒被證明是主設備）：不補、不收")
        let legacy = try registry("legacy", host: nil, client: nil, legacy: hostFingerprint)
        check(record(legacy)?.pinnedClientKeyFingerprint != nil && HandsBuildTrust.hostPin(primary: pID, registry: legacy) == nil,
              "沒分流過的舊紀錄（指紋沿用舊欄）：不補、不動")
        check(HandsBuildTrust.hostPin(primary: bID, registry: join) == nil, "不在設備名單裡的主設備 id：不補")
        let repair = try registry("repair", host: hostFingerprint, client: nil)
        if var current = record(repair) { current.needsFingerprintRepair = true; _ = try repair.add(current) }
        check(HandsBuildTrust.hostPin(primary: pID, registry: repair) == nil
              && (try? repair.recordClientFingerprint(id: pID, expectedHost: hostFingerprint, fingerprint: keys.fingerprint, source: "x")) == false,
              "紀錄標著待修指紋：不補（needsFingerprintRepair 不當作覆蓋授權）")
    }

    // MARK: - 14. AI 工具改不了設定（反例）

    static func aiCannotChangeConfig(_ check: Checker) {
        let method = HandsBuildRemote.method
        let callers: [(OSSocketCaller, Bool)] = [(.app, false), (.engine(UUID()), false), (.job(UUID()), false), (.helper, false),
                                                 (.externalAI, false), (.other(pid: nil), false), (.ssh, true)]
        let wrong = callers.filter { OSAgentBridge.allows(caller: $0.0, method: method, params: [:], staging: false) != $0.1 }
        check(wrong.isEmpty, "hands_build 只給 SSH 轉進來的已配對設備（還要設備簽章）；這台的 AI 引擎、背景工作、外部 AI、其他程式一律不能叫",
              "\(wrong.map { "\($0.0)" })")
        var refused = false
        do { _ = try HandsSetupTool.handle(method: "hands_setup_step", params: ["step": "all", "subdomain": "evil", "devices": ["x"]]) }
        catch { refused = String(describing: error).contains("unexpected field") }
        check(refused, "助理的 hands_setup_step 沒有改設備、網址、等級、專案的參數（多帶就拒）")
        check(!HandsContract.externalAIMethods.contains(method) && HandsTools.catalog(level: HandsSettings.maxLevel).allSatisfy { tool in
            let name = tool.descriptor["name"] as? String ?? ""
            return !name.contains("build") && !name.contains("device") && !name.contains("config")
        }, "外部 AI（ChatGPT）的工具清單沒有任何改設定、設備、派工的工具（T12 改寫：多台連得上不代表能管別台）")
    }

    // MARK: - 15. 公共狀態：沒有登入網址、確認 token、配對碼

    static func publicStatusChecks(_ check: Checker) {
        var report = HandsBuildDeviceReport(deviceID: bID)
        report.phaseText = "運作中"
        let keys = Set(report.wire.keys)
        check(!keys.contains("login_url") && !keys.contains("pairing_code") && !keys.contains("confirm_token") && !keys.contains("card"),
              "每台回報的公共狀態欄位：沒有登入網址、配對碼、確認 token", keys.sorted().joined(separator: ","))
    }
}
#endif
