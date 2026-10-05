#if DEBUG
import AppKit
import Darwin
import Foundation

/// `TATWO2_SELFTEST=w183ui`：ChatGPT 手腳的畫面與標準設定流程（W183 R3）。只在完整隔離的 staging 環境跑；不開通道、不啟動關口、不碰網路。
/// - 標準流程每一步的狀態機：用假 cloudflared（Node 扮演，走真的看門程式＋sandbox-exec＋spawn 路徑）與記憶體假鑰匙圈；
///   沒登入就停在授權、登入完自動接上、取消後接著做、出錯白話、重跑、撞名換名、助理打開要先問、不是 Cloudflare 的網址不開。
/// - 秘密（授權憑證、通道 token）與 Cloudflare 帳號資料用 canary 證明：不在 argv、狀態檔、帳號清單、工具回傳；暫存憑證 0600、
///   cloudflared 自己寫的授權檔與通道憑證也是 0600（看門程式的 umask）、用完刪；不碰假 HOME 的 ~/.cloudflared。
/// - W183 R3 審查修正：設定指令的沙盒（寫不到沙盒外、開不了別的程式）、App 當掉（看門程式收 EOF 就收掉並清檔、重開時收掉上次那一組）、
///   舊指令沒結束不准重跑、關掉後再登入不會自己打開、忙碌時不准換網域／主機、移除正在用的帳號會先停、staging 一律拒絕、
///   給 AI 的狀態沒有帳號資料、副設備的配對碼到期或斷線就拿掉、查詢去重與退避、主機交接（一次只有一台）、畫面模式依主機。
/// - cloudflared 下載：固定雜湊（壓縮檔＋執行檔）、捷徑成員、被改過的執行檔、只用下載的那份（不用 Homebrew）。
/// - OS 工具 hands_setup_*：外部 AI、SSH、背景指令、其他程式一律拒；配對不能由工具開。
/// - 副設備 RPC（remote_hands_*）：真的設備簽章（ssh-keygen）、驗章、竄改與重放被拒、只回白名單欄位、配對碼只在確認卡。
/// - 設定分頁改名（rawValue 不動）、施工卡的手腳房間沒有「待確認」。
/// - W183 R3b 審查：授權後先確認帳號與網域（確認前不建通道）、晚到的取消不收憑證、多網域重新授權刪這一輪的 token、清到一半失敗可重按、
///   關掉時設定存不進去照樣停（記憶體強制關閉）、關掉與啟動的競態、簽章涵蓋的期限與流程世代、交接時流程在跑就拒、
///   授權頁走真的瀏覽器佇列與分頁登記（敏感分頁不落檔、不進瀏覽紀錄）、給 AI 的狀態沒有網域。
enum HandsUIAcceptance {
    final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: String = "") {
            if condition { passed += 1 } else { failed += 1 }
            print("W183UI \(condition ? "PASS" : "FAIL") \(label)\(condition || evidence.isEmpty ? "" : " — " + String(evidence.prefix(700)))")
        }
        /// W183 R5b：這裡驗不到的（不是通過）：印 SKIP、在 SUMMARY 另計，主導要看。
        func skip(_ label: String) {
            skipped += 1
            print("W183UI SKIP \(label)")
        }
    }

    struct Fixture {
        let base: URL
        let fakeHome: URL
        let node: URL
        let canaryToken: String
        let canaryAPIToken: String
        let accountName: String
        let accountID: String
        let zoneID: String
        let primaryID: String
        let secondaryID: String
        /// W183 R3b：假 cloudflared 印的授權網址裡的 canary（證明授權網址只經設備簽章通道、不進 AI 可見的輸出）。
        var loginCanary: String = "W183UILOGIN"
        var certPEM: String {
            let json = "{\"zoneID\":\"\(zoneID)\",\"accountID\":\"\(accountID)\",\"apiToken\":\"\(canaryAPIToken)\"}"
            return "-----BEGIN ARGO TUNNEL TOKEN-----\n" + Data(json.utf8).base64EncodedString(options: [.lineLength64Characters]) + "\n-----END ARGO TUNNEL TOKEN-----\n"
        }
        var secrets: [String] { [canaryToken, canaryAPIToken] }
    }

    /// 取消之後一直不結束的指令（驗「舊指令沒結束不准重跑」）。release 之後才算結束。
    final class StuckCommand: HandsRunningCommand, @unchecked Sendable {
        let released = HandsLocked(false)
        var processGroup: pid_t { 0 }
        var hasExited: Bool { released.get() }
        func cancel() {}
        func waitForExit(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if released.get() { return true }; Thread.sleep(forTimeInterval: 0.02) }
            return released.get()
        }
    }

    /// W183 R5b 審查：一停就結束的指令＋輸出由自測自己送（模擬讀輸出的執行緒延遲：網址在收尾之後才送到）。
    final class LateCommand: HandsRunningCommand, @unchecked Sendable {
        let exited = HandsLocked(false)
        var processGroup: pid_t { 0 }
        var hasExited: Bool { exited.get() }
        func cancel() { exited.set(true) }
        func waitForExit(timeout: TimeInterval) -> Bool { exited.get() }
    }

    final class LateRunner: HandsCloudflaredRunning, @unchecked Sendable {
        let command = LateCommand()
        let deliver = HandsLocked<((String) -> Void)?>(nil)
        func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL,
                   onLine: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand {
            deliver.set(onLine)
            return command
        }
    }

    final class StuckRunner: HandsCloudflaredRunning {
        let command = StuckCommand()
        func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL,
                   onLine: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand { command }
    }

    /// 一個流程世界：自己的手腳資料夾、帳號清單、假鑰匙圈、假 cloudflared（Node）、假關口。
    final class World {
        let root: URL
        let paths: HandsPaths
        let service: HandsService
        let accounts: CloudflareAccountsStore
        let secrets: CloudflareMemorySecrets
        let setup: HandsSetup
        let ctrl: URL
        let opened: HandsLocked<[URL]>
        let phase: HandsLocked<ChatGPTHandsService.Phase>
        let grant: HandsLocked<Bool>
        let approve: HandsLocked<Bool>
        let asked: HandsLocked<Int>
        let lookedUp: HandsLocked<[String]>
        let serviceChanges: HandsLocked<Int>
        /// W183 R3b 審查：Cloudflare 回的網域名稱（nil＝問不到；自測可以中途改）、查詢時插一手、固定點插一手、授權頁關了幾次。
        let names: HandsLocked<String?>
        let lookupHook: HandsLocked<(() -> Void)?>
        let checkpointHook: HandsLocked<((String) -> Void)?>
        let closedLogin: HandsLocked<Int>
        /// W183 R6a：［連線］卡叫了幾次（offerConnect）、取消連線的原因、自動續跑叫關口幾次（resumeService）、「重試」叫關口幾次（startService）、
        /// 假 Cloudflare API（讀寫假 cloudflared 同一份 dns.json）用過的 token、刪了哪些紀錄、要它失敗的分類。
        let offers: HandsLocked<Int>
        let connectCancels: HandsLocked<[String]>
        let resumes: HandsLocked<Int>
        let starts: HandsLocked<Int>
        let dnsTokens: HandsLocked<[String]>
        let dnsDeletes: HandsLocked<[String]>
        let dnsFailure: HandsLocked<String?>
        let dnsDeleteFailure: HandsLocked<String?>
        /// W183 R6a 審查：助理的重試（retryService）叫了幾次、遷移時作廢連線的原因、新網址外部確認要回的分類（nil＝確認了）、
        /// 每一次查 DNS 紀錄前插一手（名字）。
        let assistantRetries: HandsLocked<Int>
        let revokes: HandsLocked<[String]>
        let probeFailure: HandsLocked<String?>
        let dnsHook: HandsLocked<((String) -> Void)?>

        /// W183 R5b：openURL＝主機本機的「在這台打開授權頁」（nil＝只記下來）；postsClose＝流程結束也發正式的收回通知（私訊框的頁面聽它）。
        init(_ fixture: Fixture, folder: String, zoneName: String?, runner custom: HandsCloudflaredRunning? = nil, exitWait: TimeInterval = 8,
             openURL: ((URL) -> Void)? = nil, postsClose: Bool = false, loginTimeout: TimeInterval = 40,
             configure: ((inout HandsSetup.Dependencies) -> Void)? = nil) throws {
            let fm = FileManager.default
            let root = fixture.base.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let handsRoot = URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands", isDirectory: true)
            try HandsFiles.ensureDirectory(handsRoot)
            let paths = HandsPaths(root: handsRoot)
            try HandsFiles.ensureDirectory(paths.appDir)
            let service = HandsService(paths: paths)
            service.deviceIDOverride = fixture.primaryID
            let secrets = CloudflareMemorySecrets()
            let accounts = CloudflareAccountsStore(fileURL: root.appendingPathComponent("cloudflare/accounts.json"), secrets: secrets)
            // 假 cloudflared 的控制檔放在設定流程的家目錄裡（沙盒只開那裡）。
            let setupHome = handsRoot.appendingPathComponent("cf-setup", isDirectory: true)
            try HandsFiles.ensureDirectory(setupHome)
            let ctrl = setupHome.appendingPathComponent("fake-ctrl", isDirectory: true)
            try HandsFiles.ensureDirectory(ctrl)
            try Data(fixture.certPEM.utf8).write(to: ctrl.appendingPathComponent("cert.pem"))
            try Data((fixture.canaryToken + "\n").utf8).write(to: ctrl.appendingPathComponent("token"))
            let script = HandsUIAcceptance.fakeScript(ctrl: ctrl.path, tunnelID: "0f0e0d0c-0b0a-4908-8706-050403020100", appDir: paths.appDir.path,
                                                      loginToken: fixture.loginCanary)
            let opened = HandsLocked<[URL]>([]), phase = HandsLocked<ChatGPTHandsService.Phase>(.stopped)
            let grant = HandsLocked(false), approve = HandsLocked(false), asked = HandsLocked(0), lookedUp = HandsLocked<[String]>([])
            let serviceChanges = HandsLocked(0)
            let names = HandsLocked<String?>(zoneName), lookupHook = HandsLocked<(() -> Void)?>(nil)
            let checkpointHook = HandsLocked<((String) -> Void)?>(nil), closedLogin = HandsLocked(0)
            let offers = HandsLocked(0), connectCancels = HandsLocked<[String]>([]), resumes = HandsLocked(0), starts = HandsLocked(0)
            let dnsTokens = HandsLocked<[String]>([]), dnsDeletes = HandsLocked<[String]>([])
            let dnsFailure = HandsLocked<String?>(nil), dnsDeleteFailure = HandsLocked<String?>(nil)
            let assistantRetries = HandsLocked(0), revokes = HandsLocked<[String]>([]), probeFailure = HandsLocked<String?>(nil)
            let dnsHook = HandsLocked<((String) -> Void)?>(nil)
            let primary = fixture.primaryID, secondary = fixture.secondaryID
            let devices = [HandsSetupDevice(id: primary, name: "Primary One", isPrimary: true, isThisDevice: true),
                           HandsSetupDevice(id: secondary, name: "Fixture", isPrimary: false, isThisDevice: false)]
            let node = fixture.node
            let accountName = fixture.accountName
            // staging 在外接卷：放棄責任行程的子行程讀不到那裡的檔（TCC），自測只關掉這一項，其餘（看門程式、Seatbelt、環境、fd）照正式。
            let runner = custom ?? HandsCloudflaredRunner(disclaimResponsibilityForTesting: false, programPrefix: ["-e", script])
            var deps = HandsSetup.Dependencies(
                paths: paths, accounts: accounts, runner: runner,
                localDeviceID: { primary },
                devices: { devices },
                transferHost: { target in
                    HandsHostAuthority.localTransfer(to: target, localID: primary, service: service,
                                                     devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) }), serviceChanged: {})
                },
                locateCloudflared: { HandsCloudflared.Location(url: node, source: .downloaded) },
                installCloudflared: { done in done(.failure(.download)) },
                lookupZone: { _, token, done in
                    lookedUp.update { $0.append(token) }
                    lookupHook.get()?()
                    let name = names.get()
                    done(name, name == nil ? nil : accountName)
                },
                openURL: { url in opened.update { $0.append(url) }; openURL?(url) },
                loadSettings: { service.settings.load() },
                updateSettings: { change in _ = try service.updateSettings(change) },
                startService: {
                    starts.update { $0 += 1 }
                    let settings = service.settings.load()
                    if settings.enabled, let host = settings.publicHost { phase.set(.running(url: "https://\(host)/mcp")) }
                },
                serviceChanged: {
                    serviceChanges.update { $0 += 1 }
                    if !service.settings.load().enabled { phase.set(.stopped) }
                },
                servicePhase: { phase.get() },
                hasActiveGrant: { grant.get() },
                askApproval: { _, _, done in asked.update { $0 += 1 }; done(approve.get()) })
            deps.closeLoginPages = { url in closedLogin.update { $0 += 1 }; if postsClose { HandsSetup.postCloseLoginPages(only: url) } }
            // W183 R8b：授權完成＝Browser 的授權分頁標「完成」（頁面關掉、分頁留著）；這裡一樣算一次收尾（closedLogin＝收回、撤下或標完成）。
            deps.loginPagesDone = { url in closedLogin.update { $0 += 1 }; if postsClose { HandsSetup.postLoginPagesDone(only: url) } }
            // W183 R8b 審查：cloudflared 結束、還在驗授權檔＝授權頁先撤下（分頁寫「確認中」）。
            deps.loginPagesWithdrawn = { url in closedLogin.update { $0 += 1 }; if postsClose { HandsSetup.postLoginPagesWithdrawn(only: url) } }
            // W183 R6a：連線那一段（R6b）只記下來；自動續跑只叫關口照設定判斷（安全停機＝失敗狀態留著，不解除）。
            deps.offerConnect = { offers.update { $0 += 1 } }
            deps.cancelConnect = { reason in connectCancels.update { $0.append(reason) } }
            deps.resumeService = {
                resumes.update { $0 += 1 }
                if case .failed = phase.get() { return }
                let settings = service.settings.load()
                if settings.enabled, let host = settings.publicHost { phase.set(.running(url: "https://\(host)/mcp")) }
            }
            let dnsFile = ctrl.appendingPathComponent("dns.json")
            deps.dnsRecords = { _, name, token, done in
                dnsTokens.update { $0.append(token) }
                dnsHook.get()?(name)
                if let failure = dnsFailure.get() { return done(.failure(failure)) }
                done(.records(World.records(dnsFile).filter { $0.name == name }))
            }
            // W183 R6a 審查：助理的重試（安全停機＝失敗留著；其他失敗救得回來）、遷移時作廢連線、新網址的外部確認、DNS 指到的通道、「關」有沒有存進磁碟。
            deps.retryService = {
                assistantRetries.update { $0 += 1 }
                if phase.get() == .failed(ChatGPTHandsService.tamperedText) { return }
                let settings = service.settings.load()
                if settings.enabled, let host = settings.publicHost { phase.set(.running(url: "https://\(host)/mcp")) }
            }
            deps.revokeGrants = { reason in revokes.update { $0.append(reason) }; grant.set(false); return nil }
            deps.probeHost = { _, done in done(probeFailure.get()) }
            deps.dnsTunnelTargets = { _, token, done in
                dnsTokens.update { $0.append(token) }
                if dnsFailure.get() != nil { return done(nil) }
                done(Set(World.records(dnsFile).filter { $0.type == "CNAME" && $0.content.hasSuffix(HandsCloudflared.tunnelSuffix) }
                    .map { String($0.content.dropLast(HandsCloudflared.tunnelSuffix.count)) }))
            }
            deps.offPersisted = { !service.settings.forcedOff }
            deps.stopWait = 1
            deps.deleteDNSRecord = { _, id, token, done in
                dnsTokens.update { $0.append(token) }
                if let failure = dnsDeleteFailure.get() { return done(failure) }
                World.removeRecord(dnsFile, id: id)
                dnsDeletes.update { $0.append(id) }
                done(nil)
            }
            deps.retireRetryDelays = []   // W183 R7a：舊紀錄的自動重試預設不跑（不跟別的檢查搶）；要驗的在 configure 或自己的世界打開
            configure?(&deps)
            deps.checkpoint = { point in checkpointHook.get()?(point) }
            deps.lookupTimeout = 5
            deps.pollInterval = 0.05
            deps.loginTimeout = loginTimeout
            deps.commandTimeout = 20
            deps.serviceTimeout = 5
            deps.approvalTimeout = 5
            deps.exitWait = exitWait
            self.root = root
            self.paths = paths
            self.service = service
            self.accounts = accounts
            self.secrets = secrets
            self.ctrl = ctrl
            self.opened = opened
            self.phase = phase
            self.grant = grant
            self.approve = approve
            self.asked = asked
            self.lookedUp = lookedUp
            self.serviceChanges = serviceChanges
            self.names = names
            self.lookupHook = lookupHook
            self.checkpointHook = checkpointHook
            self.closedLogin = closedLogin
            self.offers = offers
            self.connectCancels = connectCancels
            self.resumes = resumes
            self.starts = starts
            self.dnsTokens = dnsTokens
            self.dnsDeletes = dnsDeletes
            self.dnsFailure = dnsFailure
            self.dnsDeleteFailure = dnsDeleteFailure
            self.assistantRetries = assistantRetries
            self.revokes = revokes
            self.probeFailure = probeFailure
            self.dnsHook = dnsHook
            self.setup = HandsSetup(dependencies: deps)
        }

        /// W183 R6a：假 Cloudflare 上的 DNS 紀錄（假 cloudflared 的 route dns 也寫同一份 dns.json）。
        static func records(_ file: URL) -> [HandsCloudflared.DNSRecord] {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return [] }
            return object.compactMap { name, row in
                guard let id = row["id"], let type = row["type"], let content = row["content"] else { return nil }
                return HandsCloudflared.DNSRecord(id: id, type: type.uppercased(), name: name.lowercased(), content: content.lowercased(),
                                                  proxied: row["proxied"] == "true")
            }.sorted { $0.name < $1.name }
        }

        static func removeRecord(_ file: URL, id: String) {
            guard let data = try? Data(contentsOf: file),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return }
            object = object.filter { $0.value["id"] != id }
            if let out = try? JSONSerialization.data(withJSONObject: object) { try? out.write(to: file) }
        }

        /// 在假 Cloudflare 上放一筆紀錄（別人的、或以前 TATWO 建的隨機子網域）。
        func putRecord(_ host: String, type: String = "CNAME", content: String, proxied: Bool = true) {
            let file = ctrl.appendingPathComponent("dns.json")
            var object = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: String]] }) ?? [:]
            object[host] = ["id": Data(host.utf8).map { String(format: "%02x", $0) }.joined().padding(toLength: 32, withPad: "0", startingAt: 0),
                            "type": type, "content": content, "proxied": proxied ? "true" : "false"]
            if let out = try? JSONSerialization.data(withJSONObject: object) { try? out.write(to: file) }
        }

        func dnsNames() -> [String] { World.records(ctrl.appendingPathComponent("dns.json")).map(\.name) }

        /// W183 R3b 審查：使用者在畫面按「是這個，繼續」（用畫面上看到的確認碼與網域）。回 true＝確認了。
        @discardableResult
        func confirm(token: String? = nil, domain: String? = nil) throws -> Bool {
            let summary = setup.authorizedSummary()
            return try setup.confirmAuthorization(token: token ?? summary?.confirmToken ?? "", domain: domain ?? summary?.domain ?? "")
        }

        /// 這個世界寫下的所有檔案（找秘密、授權網址）：手腳資料夾、帳號清單、瀏覽器，全部（假 cloudflared 自己的控制檔除外：那裡本來就放假憑證）。
        func allFilesText() -> String {
            var out = ""
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let url = enumerator?.nextObject() as? URL {
                if url.path.contains("/fake-ctrl") { continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) <= 4 * 1024 * 1024 else { continue }
                if let data = try? Data(contentsOf: url) { out += String(decoding: data, as: UTF8.self) + "\n" }
            }
            return out
        }

        func flag(_ name: String, _ on: Bool) {
            let url = ctrl.appendingPathComponent(name)
            if on { FileManager.default.createFile(atPath: url.path, contents: Data("1".utf8)) } else { unlink(url.path) }
        }

        func log(_ name: String) -> String {
            (try? String(contentsOf: ctrl.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }

        var setupHome: URL { paths.root.appendingPathComponent("cf-setup", isDirectory: true) }
        func status(_ step: HandsSetupStep) -> HandsSetupStepState { setup.snapshot.step(step) }

        /// 所有 App 寫的狀態檔（找秘密）。
        func stateFiles() -> String {
            [paths.appDir.appendingPathComponent("setup.json"), paths.settingsFile, accounts.fileURL]
                .map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }.joined(separator: "\n")
        }

        func leftovers() -> [String] {
            let top = ((try? FileManager.default.contentsOfDirectory(atPath: setupHome.path)) ?? []).filter { $0.hasPrefix("oc-") || $0.hasPrefix("cred-") }
            let dot = (try? FileManager.default.contentsOfDirectory(atPath: setupHome.appendingPathComponent(".cloudflared").path)) ?? []
            return top + dot
        }
    }

    /// 扮演 cloudflared 的 Node：要在家目錄與外接卷外面（沙盒擋那兩處）。隔離自測可指定私有暫存目錄內的 Node 副本。
    static func findNode() -> URL? {
        let home = HandsGatewayLaunch.realPath(HandsGatewayLaunch.accountHome()) ?? HandsGatewayLaunch.accountHome()
        // Studio has a standalone Node. A copied temporary fixture keeps the same real sandbox,
        // without installing Homebrew or allowing the user's home into the profile.
        let environment = ProcessInfo.processInfo.environment
        // w183ui（扮演 cloudflared）與 w185tools（W196 的工具實際連線）兩組隔離自測共用這個入口。
        if ["w183ui", "w185tools"].contains(environment["TATWO2_SELFTEST"] ?? ""), NativeStagingIsolation.isEnabled(environment),
           NativeStagingIsolation.validationError(environment) == nil,
           let candidate = environment["TATWO2_SELFTEST_NODE"], let real = HandsGatewayLaunch.realPath(candidate),
           real.hasPrefix("/private/tmp/") || real.hasPrefix("/private/var/folders/"),
           !real.hasPrefix(home + "/"), FileManager.default.isExecutableFile(atPath: real) {
            var info = stat()
            if lstat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               info.st_uid == getuid(), info.st_nlink == 1 {
                return URL(fileURLWithPath: real)
            }
        }
        // Studio 的隔離自測可帶暫存 runtime；仍照原本 realpath 的家目錄與外接卷禁讀檢查。
        // .056 閘門：runtime 的 node 放最後——mini 上它在沙盒裡讀不到自己的 libnode，有系統 Node 就先用系統的。
        let runtimeNode = EnginePaths().runtimeBinDirectory.appendingPathComponent("node").path
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", runtimeNode] where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let real = HandsGatewayLaunch.realPath(candidate), !real.hasPrefix(home + "/"), !real.hasPrefix("/Volumes/") else { continue }
            return URL(fileURLWithPath: real)
        }
        return nil
    }

    /// W183 R5b 審查：固定版本 cloudflared 印的那種授權網址（公鑰那一段放 canary，補滿 43 字＋「=」）。
    static func loginLine(_ key: String) -> String {
        let safe = String(key.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        return "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F"
            + String((safe + String(repeating: "A", count: 43)).prefix(43)) + "%3D"
    }

    static func json(_ text: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8), as: UTF8.self)
            .dropFirst().dropLast().description
    }

    /// 假 cloudflared（`node -e <這段> tunnel …`）：記下參數、HOME、pid；login 先試沙盒（寫沙盒外、開別的程式、寫 /tmp），印授權網址、
    /// 等控制檔、寫 cert.pem；create／route dns／token 照控制檔成功或失敗；記下它自己寫的檔的權限（umask）。輸出一律同步寫（pipe 不掉字）。
    static func fakeScript(ctrl: String, tunnelID: String, appDir: String, loginToken: String = "x") -> String {
        """
        const fs = require('fs');
        const CTRL = \(json(ctrl)), TUNNEL = \(json(tunnelID)), APPDIR = \(json(appDir)), LOGIN = \(json(loginToken));
        const args = process.argv.slice(1);
        const home = process.env.HOME;
        const out = text => fs.writeSync(1, text + '\\n');
        const log = (name, text) => fs.appendFileSync(CTRL + '/' + name, text + '\\n');
        const has = name => fs.existsSync(CTRL + '/' + name);
        const mode = file => (fs.statSync(file).mode & 0o777).toString(8);
        const value = flag => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : ''; };
        log('argv.log', args.join(' '));
        log('home.log', home);
        log('pid.log', String(process.pid));
        const origincert = value('--origincert'), cred = value('--credentials-file');
        const cmd = args.includes('login') ? 'login' : args.includes('create') ? 'create' : args.includes('dns') ? 'dns' : args.includes('token') ? 'token' : args.includes('list') ? 'list' : args.includes('delete') ? 'delete' : '';
        // W183 R6a：Cloudflare 上的 DNS 紀錄（dns.json：名稱 → {id, type, content}；App 的假 Cloudflare API 讀寫同一份）與通道清單（tunnels.json）。
        const readJSON = (name, fallback) => { try { return JSON.parse(fs.readFileSync(CTRL + '/' + name, 'utf8')); } catch (e) { return fallback; } };
        const writeJSON = (name, value) => fs.writeFileSync(CTRL + '/' + name, JSON.stringify(value));
        const err = text => fs.writeSync(2, text + '\\n');
        const last = args[args.length - 1], before = args[args.length - 2];
        if (cmd === 'login') {
          const probe = {};
          try { fs.writeFileSync(APPDIR + '/evil.txt', 'x'); probe.appWrite = 'WROTE'; } catch (e) { probe.appWrite = e.code; }
          try { fs.writeFileSync('/private/tmp/w183ui-sandbox-' + process.pid, 'x'); probe.tmpWrite = 'WROTE'; } catch (e) { probe.tmpWrite = e.code; }
          const spawned = require('child_process').spawnSync('/bin/sh', ['-c', 'true']);
          probe.exec = spawned.error ? spawned.error.code : 'RAN';
          fs.writeFileSync(CTRL + '/probe.json', JSON.stringify(probe));
          if (has('bad-url')) { out('Please open https://evil.example.org/login to continue'); process.exit(1); }
          out('Please open the following URL and log in with your Cloudflare account:');
          out('');
          // W183 R5b 審查：跟固定版本 cloudflared 印的一樣（callback＝login.cloudflareaccess.org/<32 位元組公鑰的 base64url>）；
          // 每一輪的公鑰不一樣（真的 cloudflared 每次登入都新產生一把）：canary 後面接這個行程的編號。
          out('https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F'
              + (LOGIN + process.pid.toString(36) + 'A'.repeat(43)).slice(0, 43) + '%3D');
          let i = 0;
          const timer = setInterval(() => {
            if (has('deny') || ++i > 600) { clearInterval(timer); process.exit(1); }
            if (!has('authorized')) return;
            clearInterval(timer);
            fs.mkdirSync(home + '/.cloudflared', { recursive: true });
            fs.writeFileSync(home + '/.cloudflared/cert.pem', fs.readFileSync(CTRL + '/cert.pem'));
            log('perm.log', 'cert ' + mode(home + '/.cloudflared/cert.pem'));
            out('You have successfully logged in.');
            process.exit(0);
          }, 100);
        } else if (cmd === 'create') {
          log('creates.log', 'x');
          if (has('fail-create')) { out('ERR failed to create tunnel: Authentication error (10000)'); process.exit(1); }
          if (has('create-exists-once')) { fs.rmSync(CTRL + '/create-exists-once'); err('ERR failed to create tunnel: Create Tunnel API call failed: tunnel with name already exists'); process.exit(1); }
          if (!origincert || !fs.existsSync(origincert)) { out('no origin cert'); process.exit(2); }
          log('perm.log', 'origincert ' + mode(origincert));
          if (cred) { fs.writeFileSync(cred, '{"AccountTag":"fixture"}'); log('perm.log', 'cred ' + mode(cred)); }
          log('created.log', last);
          // W183 R5（實機）：真的 cloudflared 是 stderr 的 log＋stdout 縮排多行 JSON（含 token），兩條混在同一串。
          err('2026-09-28T00:00:00Z WRN Your version 2026.9.1 is outdated. We recommend upgrading it to 2026.9.2');
          if (has('create-noid-once')) { fs.rmSync(CTRL + '/create-noid-once'); err('2026-09-28T00:00:00Z INF done'); process.exit(0); }
          out(JSON.stringify({ id: TUNNEL, name: last, created_at: new Date().toISOString(), deleted_at: '0001-01-01T00:00:00Z', connections: [], token: 'fixture-token' }, null, 2));
          err('2026-09-28T00:00:01Z INF Tunnel created');
          process.exit(0);
        } else if (cmd === 'list') {
          const want = value('--name');
          const names = fs.existsSync(CTRL + '/created.log') ? fs.readFileSync(CTRL + '/created.log', 'utf8').split('\\n').filter(Boolean) : [];
          const mine = n => ({ id: TUNNEL, name: n, created_at: new Date().toISOString(), deleted_at: '0001-01-01T00:00:00Z', connections: [] });
          // W183 R6a：整個帳號的通道（沒用到的通道那一段；W183 R6a 審查：沒寫 tunnels.json＝這個帳號裡只有這台建過的那幾條）。
          const rows = want ? names.filter(n => n === want).map(mine)
                            : (fs.existsSync(CTRL + '/tunnels.json') ? readJSON('tunnels.json', []) : names.map(mine));
          log('lists.log', want || '*');
          err('2026-09-28T00:00:00Z WRN Your version 2026.9.1 is outdated.');
          out(JSON.stringify(rows, null, 2));
          process.exit(0);
        } else if (cmd === 'delete') {
          log('deletes.log', last);
          const rows = readJSON('tunnels.json', []);
          const row = rows.find(r => r.id === last);
          if (!row) { err('ERR tunnel not found'); process.exit(1); }
          if ((row.connections || []).length > 0) { err('ERR Cannot delete tunnel ' + last + ' because it has active connections'); process.exit(1); }
          writeJSON('tunnels.json', rows.filter(r => r.id !== last));
          err('2026-09-28T00:00:00Z INF Deleted tunnel');
          process.exit(0);
        } else if (cmd === 'dns') {
          if (has('dns-collide-once')) {
            fs.rmSync(CTRL + '/dns-collide-once');
            out('ERR API error: An A, AAAA, or CNAME record with that host already exists.');
            process.exit(1);
          }
          const h = last.includes('.') ? last : last + '.example.com';
          // W183 R6a：跟 Cloudflare 一樣——同名的紀錄指向這條通道＝已經設好；指向別的（或不是 CNAME）＝撞名（不加 --overwrite-dns）。
          const records = readJSON('dns.json', {});
          const target = before + '.cfargotunnel.com';
          if (records[h]) {
            if (records[h].type === 'CNAME' && records[h].content === target) { out(h + ' is already configured to route to your tunnel tunnelID=' + before); process.exit(0); }
            out('ERR API error: An A, AAAA, or CNAME record with that host already exists.');
            process.exit(1);
          }
          records[h] = { id: Buffer.from(h).toString('hex').padEnd(32, '0').slice(0, 32), type: 'CNAME', content: target, proxied: 'true' };
          writeJSON('dns.json', records);
          out('2026-09-28T00:00:00Z INF Added CNAME ' + h + ' which will route to this tunnel tunnelID=' + before);
          process.exit(0);
        } else if (cmd === 'token') {
          out(fs.readFileSync(CTRL + '/token', 'utf8').trim());
          process.exit(0);
        } else {
          out('unexpected command');
          process.exit(9);
        }
        """
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let stagingPath = environment["TATWO_STAGING_ROOT"], let staging = HandsPath.realpath(stagingPath) else {
            throw BotLibraryError.invalid("w183ui needs a fully isolated staging environment")
        }
        let check = Checker()
        let base = URL(fileURLWithPath: staging).appendingPathComponent("w183ui-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fakeHome = URL(fileURLWithPath: environment["HOME"] ?? base.appendingPathComponent("home").path)
        let hex = { (n: Int) in String((0..<n).map { _ in "0123456789abcdef".randomElement()! }) }
        check(!ChatGPTHandsService.allowedToRun(environment: environment), "自測／staging：真的關口與通道不啟動（T12）")
        staticChecks(check)
        isolationChecks(check)
        guard let node = findNode() else {
            check(false, "找不到家目錄與外接卷外的 Homebrew Node 來扮演 cloudflared；流程與沙盒實跑沒有驗")
            print("W183UI SUMMARY passed=\(check.passed) failures=\(check.failed)")
            return false
        }
        let fixture = Fixture(base: base, fakeHome: fakeHome, node: node,
                              canaryToken: "W183UITOKEN" + hex(40), canaryAPIToken: "W183UIAPITOKEN" + hex(32),
                              accountName: "W183UIACCT" + hex(8), accountID: hex(32), zoneID: hex(32),
                              primaryID: "11111111-1111-4111-8111-111111111111", secondaryID: "22222222-2222-4222-8222-222222222222",
                              loginCanary: "W183UILOGIN" + hex(24))
        parsingChecks(check, fixture)
        try installerChecks(check, base)
        toolGateChecks(check)
        try await flowChecks(check, fixture)
        try await errorFlowChecks(check, fixture)
        try await badURLChecks(check, fixture)
        try await resumeIntentChecks(check, fixture)
        try await lingeringChecks(check, fixture)
        try await lateOutputChecks(check, fixture)
        try await crashChecks(check, fixture)
        try toolHandlerChecks(check, fixture)
        try remoteChecks(check, fixture)
        try await remoteSetupChecks(check, fixture)
        try await lateCancelChecks(check, fixture)
        try await multiDomainChecks(check, fixture)
        try await cleanupRetryChecks(check, fixture)
        try await settingsFailureChecks(check, fixture)
        try await raceChecks(check, fixture)
        try await browserPathChecks(check, fixture)
        try await dmSheetChecks(check, fixture)
        await dmHostingChecks(check)
        await cefPageChecks(check)
        try await remoteClientChecks(check, base)
        try await remoteClientBindingChecks(check, base)
        // W183 R6a：一個開關（HandsOneSwitchAcceptance.swift）。
        try await oneSwitchFlowChecks(check, fixture)
        try safetyLockChecks(check, base)
        try await fixedSubdomainChecks(check, fixture)
        try await handbackChecks(check, fixture)
        try await remoteSyncChecks(check, base)
        try await unusedTunnelChecks(check, fixture)
        try await resumeBoundaryChecks(check, fixture)   // W183 R6a 審查
        try await r7aChecks(check, fixture)   // W183 R7a（HandsScopeAcceptance.swift）
        buildUIChecks(check)   // W183 R8a：ChatGPT build 的節點流程與面板（HandsBuildUIAcceptance.swift）
        try? FileManager.default.removeItem(at: base)
        print("W183UI SUMMARY passed=\(check.passed) failures=\(check.failed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    // MARK: - 設定分頁、施工卡、畫面模式

    @MainActor static func staticChecks(_ check: Checker) {
        check(TatwoSettingsPage.Section.github.rawValue == "github" && TatwoSettingsPage.Section.github.title == "環境登入",
              "設定：「GitHub」改名「環境登入」，rawValue github 不動（側欄更新鈕、開始使用照舊）")
        check(EnvironmentLoginTab.storageKey == "tatwo.settings.envLogin.tab" && EnvironmentLoginTab.allCases.map(\.title) == ["GitHub", "Cloudflare"],
              "環境登入：GitHub｜Cloudflare 兩個子分頁，記住上次（@AppStorage）")
        let received = HandsLocked<String?>(nil)
        let observer = NotificationCenter.default.addObserver(forName: .tatwoOpenSettingsSection, object: nil, queue: nil) { note in
            received.set(note.object as? String)
        }
        let before = UserDefaults.standard.string(forKey: EnvironmentLoginTab.storageKey)
        EnvironmentLoginTab.open(.cloudflare)
        check(received.get() == "github" && UserDefaults.standard.string(forKey: EnvironmentLoginTab.storageKey) == "cloudflare",
              "導去環境登入：先把子分頁寫成 cloudflare，再開設定的環境登入頁", "\(String(describing: received.get()))")
        // 授權結束帶回 TAP › ChatGPT（授權頁開在 OS 瀏覽器時設定浮層先關掉了）。
        let tabBefore = UserDefaults.standard.string(forKey: "tatwo.plugins.selectedTab")
        received.set(nil)
        HandsSetup.open(.tap)
        check(received.get() == TatwoSettingsPage.Section.plugin.rawValue && UserDefaults.standard.string(forKey: "tatwo.plugins.selectedTab") == "tap",
              "授權結束：帶回設定 › Plugin › TAP（ChatGPT 手腳那一頁）", "\(String(describing: received.get()))")
        NotificationCenter.default.removeObserver(observer)
        if let before { UserDefaults.standard.set(before, forKey: EnvironmentLoginTab.storageKey) } else { UserDefaults.standard.removeObject(forKey: EnvironmentLoginTab.storageKey) }
        if let tabBefore { UserDefaults.standard.set(tabBefore, forKey: "tatwo.plugins.selectedTab") } else { UserDefaults.standard.removeObject(forKey: "tatwo.plugins.selectedTab") }
        let waiting = DispatchRoom(id: UUID(), title: "ChatGPT 工作區", engineLabel: ChatLiveEngine.handsEngine, liveness: .idle,
                                   lastOutputAt: Date().addingTimeInterval(-3600), reportAvailable: false, isRunning: false, isHands: true)
        check(!waiting.needsAttention && waiting.statusLabel == "等 ChatGPT", "施工卡：手腳房間等 ChatGPT 不是「狀態待確認」、不算待查看", waiting.statusLabel)
        let summary = HandsReviewSummary(candidate: "aaaa", base: "bbbb", mainHead: "cccc", flagged: ["Package.swift"], files: 1, refused: nil)
        check(summary.mainAdvanced && !HandsReviewSummary(candidate: "a", base: "b", mainHead: "b", flagged: [], files: 0, refused: nil).mainAdvanced,
              "審查卡：主線在交件後前進才提示")
        check(HandsSetupStep.allCases.count == 8 && HandsSetupStep.allCases.filter(\.needsUser) == [.authorize, .pairing],
              "標準流程：八步，使用者親自按的只有授權與配對")
        // W183 R3b：步驟狀態在兩台畫面都是中文；副設備收到不認得的代碼寫「未知」，不把英文代碼放上畫面。
        let labels = HandsSetupStatus.allCases.map(\.label)
        let remoteLabels = ["pending", "running", "waiting_user", "done", "failed", "brand_new"]
            .map { HandsRemoteStatus.Step(step: "host", status: $0, message: "").statusLabel }
        check(labels == ["等待中", "進行中", "等你按", "完成", "失敗"] && remoteLabels == labels + ["未知"],
              "中文狀態：等待中／進行中／等你按／完成／失敗，兩台一樣（不認得的寫「未知」）", "\(labels) \(remoteLabels)")
        check(HandsSetup.authorizedText(account: "Primary One", domain: "example.com") == "已授權：Cloudflare 帳號〈Primary One〉、網域〈example.com〉"
              && HandsSetup.authorizedText(account: "Primary One", domain: nil).contains("名稱建通道時補上"),
              "授權後：兩台同一句「已授權：Cloudflare 帳號〈名稱〉、網域〈網域〉」")
        // 打開後還沒做到關口：不顯示關口的失敗原因（W183 R6a：字改成「準備中…」，不再寫「第 N 步」；見 oneSwitchStatusChecks）。
        var partial = HandsSetupState()
        partial.steps[HandsSetupStep.host.rawValue] = HandsSetupStepState(status: .done)
        var ready = HandsSetupState()
        for step in [HandsSetupStep.host, .cloudflared, .authorize, .tunnel, .start, .url] { ready.steps[step.rawValue] = HandsSetupStepState(status: .done) }
        check(HandsSetup.settingUpStep(partial) == .cloudflared && HandsSetup.settingUpStep(ready) == nil,
              "狀態：設定還沒做到關口時算「還在設定」，做完才看關口狀態")
        modeChecks(check)
        oneSwitchStatusChecks(check)
    }

    @MainActor static func modeChecks(_ check: Checker) {
        // W183 R8 整合：R8c 之後沒有「一次一台主機」（claim／release 退役），每台被勾的設備自己當自己的主機——畫面也沒有「主機是別台」
        // 這種模式了。原本守的「不顯示錯的服務」改成：每台那一格只看那台自己的回報（網址、連線；HandsBuildController 只在那台回報夠新、
        // 在跑時才給網址），這台的格子不會拿到別台的網址或連線。
        let p = "11111111-1111-4111-8111-111111111111", s = "22222222-2222-4222-8222-222222222222"
        var i = HandsBuildInput()
        i.configKnown = true; i.configRevision = 3; i.enabled = true; i.localDeviceID = s
        i.devices = [HandsBuildDevice(id: p, name: "Primary One", isPrimary: true, isThisDevice: false, selected: true, state: .done,
                                      subdomain: "os-for-chatgpt", url: "https://os-for-chatgpt.example.com/mcp", connection: .done),
                     HandsBuildDevice(id: s, name: "Fixture", isPrimary: false, isThisDevice: true, selected: false, state: .off,
                                      subdomain: "os-for-chatgpt-fixture", url: nil, connection: .off)]
        let snap = HandsBuildSnapshot.derive(i)
        let mine = snap.devices.first { $0.id == s }, primary = snap.devices.first { $0.id == p }
        check(mine?.url == nil && mine?.connection == .off && mine?.selected == false
              && primary?.url == "https://os-for-chatgpt.example.com/mcp" && primary?.connection == .done,
              "W183 R8 整合 每台自己當主機：每台那一格只看那台自己的回報（這台沒勾＝沒網址、沒連線；別台的網址不會算到這台）",
              "\(snap.devices)")
    }

    // MARK: - staging／自測：設定的副作用一律拒絕

    @MainActor static func isolationChecks(_ check: Checker) {
        let isolatedEnv = ["TATWO2_SELFTEST": "w183ui"]
        let live = HandsSetup.Dependencies.live(environment: isolatedEnv)
        let install = HandsLocked<HandsCloudflared.Failure?>(nil)
        live.installCloudflared { result in if case .failure(let failure) = result { install.set(failure) } }
        var settingsRefused = false
        do { try live.updateSettings { _ in } } catch { settingsRefused = true }
        let started = (try? live.runner.start(cloudflared: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], home: URL(fileURLWithPath: "/"),
                                              handsRoot: URL(fileURLWithPath: "/"), onLine: { _ in }, onExit: { _ in })) != nil
        check(live.runner is HandsRefusingRunner && !started && live.locateCloudflared() == nil && install.get() == .isolated && settingsRefused
              && live.transferHost("x") == HandsSetup.isolatedMessage,
              "staging／自測：設定流程的 live 依賴一律拒絕（不開 cloudflared、不下載、不改設定、不換主機）")
        check(CloudflareAccountsStore.defaultSecrets(environment: isolatedEnv) is CloudflareRefusingSecrets
              && CloudflareAccountsStore.defaultSecrets(environment: ["TATWO2_SOURCETEST": "1"]) is CloudflareRefusingSecrets,
              "staging／自測：Cloudflare 的秘密庫不碰正式鑰匙圈（沒明確要記憶體假資料就拒絕）")
        check(CloudflareAccountsStore.defaultSecrets(environment: isolatedEnv.merging(["TATWO2_CLOUDFLARE_CREDENTIAL_FIXTURE": "memory"]) { $1 }) is CloudflareMemorySecrets
              && CloudflareAccountsStore.defaultSecrets(environment: [:]) is CloudflareKeychain,
              "秘密庫：正式＝鑰匙圈；DEBUG 明確要 memory 才用記憶體假資料")
        let refusing = CloudflareRefusingSecrets()
        var saveRefused = false
        do { try refusing.save("x", service: "s", account: "a") } catch { saveRefused = true }
        check(saveRefused && !refusing.contains(service: "s", account: "a") && (try? refusing.read(service: "s", account: "a")) == nil,
              "拒絕的秘密庫：不存、不讀、當作沒有")
    }

    // MARK: - 解析 cloudflared 的輸出與授權檔

    static func parsingChecks(_ check: Checker, _ fixture: Fixture) {
        let cert = HandsCloudflared.parseOriginCert(fixture.certPEM)
        check(cert?.accountID == fixture.accountID && cert?.zoneID == fixture.zoneID && cert?.apiToken == fixture.canaryAPIToken,
              "授權檔：從 ARGO TUNNEL TOKEN 讀出帳號、網域 id")
        check(HandsCloudflared.parseOriginCert("-----BEGIN ARGO TUNNEL TOKEN-----\nbm90IGpzb24=\n-----END ARGO TUNNEL TOKEN-----") == nil
              && HandsCloudflared.parseOriginCert("garbage") == nil, "授權檔：格式不對就不收")
        let good = loginLine("W183UIPARSE")
        check(HandsCloudflared.loginURL(in: "  " + good + " ")?.absoluteString == good
              && HandsCloudflared.loginURL(in: "https://dash.cloudflare.com/argotunnel?callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F"
                                            + String(repeating: "B", count: 43) + "%3D&aud=") != nil,
              "授權網址：固定版本 cloudflared 印的那一種才開（dash.cloudflare.com/argotunnel、aud 空的、callback 是 login.cloudflareaccess.org/<公鑰>）")
        // W183 R5b 審查（GPT-6）：起點與 callback 都精確比對；惡意的輸入一律不開。
        let key = String(repeating: "C", count: 43)
        let cb = { (value: String) in "https://dash.cloudflare.com/argotunnel?aud=&callback=" + value }
        let refused = ["https://evil.example.org/argotunnel", "http://dash.cloudflare.com/argotunnel", "https://dash.cloudflare.com.evil.example/x",
                       "https://developers.cloudflare.com/cloudflare-one/", "https://dash.cloudflare.com/profile",
                       "https://x" + "@" + "dash.cloudflare.com/x", "https://dash.cloudflare.com:8443/x",
                       "https://dash.cloudflare.com/argotunnel?aud=&callback=x",
                       "https://dash.cloudflare.com/argotunnel-other?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%3D",
                       "https://dash.cloudflare.com/argotunnel/?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%3D",
                       "https://sub.dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%3D",
                       cb("https%3A%2F%2Fevil.example.org%2F\(key)%3D"),                         // callback 換成外部站點
                       cb("https%3A%2F%2Flogin.cloudflareaccess.org.evil.example%2F\(key)%3D"),
                       cb("http%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%3D"),                // callback 用 http
                       cb("https%3A%2F%2Fx%40login.cloudflareaccess.org%2F\(key)%3D"),           // callback 帶帳號
                       cb("https%3A%2F%2Flogin.cloudflareaccess.org%3A444%2F\(key)%3D"),         // callback 帶埠
                       cb("https%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%3D%3Fnext%3Dhttps%3A%2F%2Fevil.example.org"),   // callback 帶參數
                       cb("https%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%3D%23frag"),         // callback 帶 fragment
                       cb("https%3A%2F%2Flogin.cloudflareaccess.org%2Fshort%3D"),                 // 公鑰長度不對
                       cb("https%3A%2F%2Flogin.cloudflareaccess.org%2Fx%2F\(key)%3D"),            // 多一層路徑
                       cb("https%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%3D%2F"),             // 結尾多一個「/」
                       cb("https%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%253D"),              // 「=」編碼兩次
                       good + "#frag",                                                              // fragment
                       good + "&redirect_url=https%3A%2F%2Fevil.example.org",                       // 不認得的跳轉參數
                       good + "&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F\(key)%3D",    // callback 重複
                       good + "&aud=",                                                              // aud 重複
                       good.replacingOccurrences(of: "aud=&", with: "aud=x&")]                       // aud 不是空的
            .filter { HandsCloudflared.loginURL(in: $0) != nil }
        check(refused.isEmpty, "授權網址：別的網域、http、帶帳號或埠、路徑只是前綴、callback 指到別處、帶 fragment、重複或不認得的參數一律不開", "\(refused)")
        // W183 R5（實機＋GPT-6 審查）：只解析 stdout 的整段 JSON（log 在 stderr）；名字要對；用名字找要有「這一輪建的」證據。
        let id = "0f0e0d0c-0b0a-4908-8706-050403020100"
        let since = Date()
        let tx = "tatwo-hands-x", ty = "tatwo-hands-y"
        let now = ISO8601DateFormatter().string(from: since.addingTimeInterval(5))
        let pretty = ["{", "  \"id\": \"0F0E0D0C-0B0A-4908-8706-050403020100\",", "  \"name\": \"tatwo-hands-x\",", "  \"connections\": [],",
                      "  \"token\": \"fixture-token\"", "}"]
        let row = { (name: String, created: String) in "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"created_at\":\"\(created)\",\"deleted_at\":\"0001-01-01T00:00:00Z\"}" }
        check(HandsCloudflared.createdTunnelID(stdout: pretty, name: tx) == id
              && HandsCloudflared.createdTunnelID(stdout: pretty, name: ty) == nil
              && HandsCloudflared.createdTunnelID(stdout: ["WRN log line"] + pretty, name: tx) == nil
              && HandsCloudflared.createdTunnelID(stdout: ["{\"connections\":[{\"id\":\"\(id)\"}]}"], name: tx) == nil,
              "W183 R5：建通道的 id 只從 stdout 整段 JSON 讀、名字要是這次建的（夾 log、內層物件、別的名字一律不認）")
        check(HandsCloudflared.lookupTunnel(stdout: ["[" + row(tx, now) + "]"], name: tx, since: since) == .found(id)
              && HandsCloudflared.lookupTunnel(stdout: ["[]"], name: tx, since: since) == .absent
              && HandsCloudflared.lookupTunnel(stdout: ["[" + row(ty, now) + "]"], name: tx, since: since) == .absent
              && HandsCloudflared.lookupTunnel(stdout: ["[" + row(tx, "2020-01-01T00:00:00Z") + "]"], name: tx, since: since) == .foreign
              && HandsCloudflared.lookupTunnel(stdout: ["[" + row(tx, now) + "," + row(tx, now) + "]"], name: tx, since: since) == .ambiguous
              && HandsCloudflared.lookupTunnel(stdout: ["WRN x", "[]"], name: tx, since: since) == .malformed
              && HandsCloudflared.lookupTunnel(stdout: ["[1]"], name: tx, since: since) == .malformed
              && HandsCloudflared.lookupTunnel(stdout: [], name: tx, since: since) == .malformed
              && HandsCloudflared.lookupTunnel(stdout: ["[{}]"], name: tx, since: since) == .malformed
              && HandsCloudflared.lookupTunnel(stdout: ["[" + row(tx, now).replacingOccurrences(of: "0001-01-01T00:00:00Z", with: "garbage") + "]"], name: tx, since: since) == .malformed
              && HandsCloudflared.lookupTunnel(stdout: ["[" + row(tx, ISO8601DateFormatter().string(from: since.addingTimeInterval(3600))) + "]"], name: tx, since: since) == .foreign
              && HandsCloudflared.lookupTunnel(stdout: ["[" + row(tx, now) + "]", "\u{0}"], name: tx, since: since) == .malformed,
              "W183 R5：用名字找通道——確定沒有才算沒有；看不懂、不只一條、早就存在的（別人的）一律不當成這一輪建的")
        check(HandsCloudflared.errorCategory(["ERR failed to create tunnel: Authentication error (10000)"]) == "auth"
              && HandsCloudflared.errorCategory(["ERR tunnel with name already exists"]) == "exists"
              // 守：不認得的錯誤一律歸 unknown、不留原文。canary 只取字母——亂數十六進位裡剛好出現 403／404／429 會被當成 HTTP 錯誤（偶發失敗，約 1／30）。
              && HandsCloudflared.errorCategory(["something else " + fixture.canaryToken.filter { !$0.isNumber }]) == "unknown",
              "W183 R5：錯誤只記白名單分類，不留原文")
        check(HandsRemoteStatus.Step(step: "host", status: "done", message: "主機：這台（Mac mini）").displayMessage == "主機：Mac mini"
              && HandsRemoteStatus.Step(step: "cloudflared", status: "done", message: "主機：這台（x）").displayMessage == "主機：這台（x）",
              "W183 R5：副設備看到的第 1 步寫主機的名字，不寫「這台」")
        check(HandsCloudflared.routedHost(in: ["x INF Added CNAME habc.example.com which will route to this tunnel tunnelID=y"]) == "habc.example.com"
              && HandsCloudflared.routedHost(in: ["habc.example.com is already configured to route to your tunnel tunnelID=y"]) == "habc.example.com",
              "DNS：從輸出讀出實際的網址")
        check(HandsCloudflared.token(in: ["2026 INF something", fixture.canaryToken, ""]) == fixture.canaryToken
              && HandsCloudflared.token(in: ["ERR no token here", "short"]) == nil, "token：只拿像 token 的那一行")
    }

    // MARK: - 下載的 cloudflared：固定雜湊、只用下載的那份

    static func tarball(_ directory: URL, member: String, into archive: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", directory.path, member]
        process.environment = ["PATH": "/usr/bin:/bin", "COPYFILE_DISABLE": "1"]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func installerChecks(_ check: Checker, _ base: URL) throws {
        let fm = FileManager.default
        let work = base.appendingPathComponent("installer", isDirectory: true)
        let source = work.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho fake cloudflared\n".utf8).write(to: source.appendingPathComponent("cloudflared"))
        let archive = work.appendingPathComponent("cf.tgz")
        guard tarball(source, member: "cloudflared", into: archive), let archiveHash = HandsCloudflared.sha256(ofFile: archive),
              let binaryHash = HandsCloudflared.sha256(ofFile: source.appendingPathComponent("cloudflared")),
              let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int) else {
            return check(false, "下載：準備假壓縮檔")
        }
        let pin = HandsCloudflared.Pin(arch: "test", url: URL(string: "https://github.com/cloudflare/cloudflared/releases/download/0/x.tgz")!,
                                       archiveSHA256: archiveHash, archiveBytes: size, binarySHA256: binaryHash)
        let goodRoot = work.appendingPathComponent("good", isDirectory: true)
        let installed = try? HandsCloudflared.install(archive: archive, root: goodRoot, pin: pin)
        var info = stat()
        let mode = installed.flatMap { lstat($0.path, &info) == 0 ? info.st_mode & 0o777 : nil }
        check(installed != nil && mode == 0o755 && HandsCloudflared.verifiedInstalled(root: goodRoot, pin: pin) != nil,
              "下載：壓縮檔讀進記憶體驗雜湊、同一份位元組經 stdin 解開；執行檔雜湊也對才裝，0755")
        func refused(_ pin: HandsCloudflared.Pin, _ root: String, archive: URL) -> HandsCloudflared.Failure? {
            let target = work.appendingPathComponent(root, isDirectory: true)
            do { _ = try HandsCloudflared.install(archive: archive, root: target, pin: pin); return nil }
            catch let failure as HandsCloudflared.Failure {
                return fm.fileExists(atPath: HandsCloudflared.installedBinary(root: target).path) ? nil : failure
            } catch { return nil }
        }
        let wrongArchive = HandsCloudflared.Pin(arch: "test", url: pin.url, archiveSHA256: String(repeating: "0", count: 64), archiveBytes: size, binarySHA256: binaryHash)
        let wrongBinary = HandsCloudflared.Pin(arch: "test", url: pin.url, archiveSHA256: archiveHash, archiveBytes: size, binarySHA256: String(repeating: "0", count: 64))
        let wrongSize = HandsCloudflared.Pin(arch: "test", url: pin.url, archiveSHA256: archiveHash, archiveBytes: size + 1, binarySHA256: binaryHash)
        check(refused(wrongArchive, "a", archive: archive) == .hash && refused(wrongBinary, "b", archive: archive) == .binaryHash
              && refused(wrongSize, "c", archive: archive) == .size,
              "下載：雜湊或大小對不上一律不用，也不留下檔案")
        // 壓縮檔裡的 cloudflared 是捷徑（指到 /bin/sh）：解開後不是一般檔，不收。
        let linkSource = work.appendingPathComponent("link", isDirectory: true)
        try fm.createDirectory(at: linkSource, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linkSource.appendingPathComponent("cloudflared").path, withDestinationPath: "/bin/sh")
        let linkArchive = work.appendingPathComponent("link.tgz")
        if tarball(linkSource, member: "cloudflared", into: linkArchive), let linkHash = HandsCloudflared.sha256(ofFile: linkArchive),
           let linkSize = try? fm.attributesOfItem(atPath: linkArchive.path)[.size] as? Int {
            let linkPin = HandsCloudflared.Pin(arch: "test", url: pin.url, archiveSHA256: linkHash, archiveBytes: linkSize, binarySHA256: binaryHash)
            check(refused(linkPin, "d", archive: linkArchive) == .extract, "下載：壓縮檔裡是捷徑就不收")
        } else {
            check(false, "下載：準備捷徑壓縮檔")
        }
        if let installed, let handle = try? FileHandle(forWritingTo: installed) {
            handle.seekToEndOfFile(); handle.write(Data("#".utf8)); try? handle.close()
        }
        check(HandsCloudflared.verifiedInstalled(root: goodRoot, pin: pin) == nil, "下載：裝好後被改過的 cloudflared 不再使用（每次用前驗雜湊）")
        let pins = HandsCloudflared.pins.values
        check(pins.count == 2 && pins.allSatisfy { $0.archiveSHA256.count == 64 && $0.binarySHA256.count == 64
                  && $0.url.absoluteString.hasPrefix("https://github.com/cloudflare/cloudflared/releases/download/\(HandsCloudflared.pinnedVersion)/") },
              "下載：固定版本 \(HandsCloudflared.pinnedVersion)、兩種處理器各有壓縮檔與執行檔雜湊")
        let empty = work.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        check(HandsCloudflared.locate(root: empty) == nil,
              "只用下載、驗過雜湊的那份：沒下載就是沒有（Homebrew 的 cloudflared 不再被當成可信）")
    }

    // MARK: - OS 工具的界線

    static func toolGateChecks(_ check: Checker) {
        let thread = UUID()
        for staging in [false, true] {
            let allowed = HandsSetupTool.methods.allSatisfy { method in
                [OSSocketCaller.app, .engine(thread), .helper].allSatisfy { OSAgentBridge.allows(caller: $0, method: method, params: [:], staging: staging) }
            }
            let refused = HandsSetupTool.methods.allSatisfy { method in
                [OSSocketCaller.externalAI, .ssh, .job(thread), .other(pid: nil)].allSatisfy { !OSAgentBridge.allows(caller: $0, method: method, params: [:], staging: staging) }
            }
            check(allowed && refused, "OS 工具：hands_setup_* 只給 App 與這台的引擎；外部 AI、SSH、背景指令、其他程式都拒（staging=\(staging)）")
        }
        let lists = OSAgentBridge.untrustedCallerMethods.union(OSAgentBridge.stagingReadOnlyMethods).union(OSAgentBridge.sshForwardMethods)
        check(HandsSetupTool.methods.isDisjoint(with: lists), "OS 工具：不在任何「外部程式／staging／SSH」清單")
        check(HandsRemote.methods.isSubset(of: OSAgentBridge.untrustedCallerMethods)
              && HandsRemote.methods.isDisjoint(with: OSAgentBridge.sshForwardMethods.union(OSAgentBridge.stagingReadOnlyMethods))
              && HandsRemote.methods.allSatisfy { !OSAgentBridge.allows(caller: .externalAI, method: $0, params: [:], staging: false) },
              "副設備 RPC：跟 memory_propose 同一組（要設備簽章），外部 AI 不能用")
    }

    // MARK: - 標準流程（第一個世界：從頭到尾）

    @MainActor static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @MainActor static func flowChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "flow", zoneName: "example.com")
        let sentinel = fixture.fakeHome.appendingPathComponent(".cloudflared/sentinel")
        try? FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: sentinel)
        try await firstRun(check, world)
        try await loginAndResume(check, world, fixture, sentinel: sentinel)
        try await cancelAndResume(check, world, fixture)
        try await removalChecks(check, world, fixture)
    }

    @MainActor static func firstRun(_ check: Checker, _ world: World) async throws {
        world.setup.runAll(trigger: .user, allowLogin: false)
        _ = await waitUntil(15) { !world.setup.isBusy && world.status(.authorize).status != .pending }
        check(world.status(.host).status == .done && world.service.settings.load().hostDeviceID == "11111111-1111-4111-8111-111111111111",
              "第 1 步：預設主設備當主機，寫進手腳設定（主設備記著現在哪一台是主機）", world.status(.host).message)
        check(world.status(.cloudflared).status == .done, "第 2 步：找到 cloudflared", world.status(.cloudflared).message)
        check(world.status(.authorize).status == .waitingUser && world.status(.authorize).message.contains("環境登入 › Cloudflare")
              && world.log("argv.log").isEmpty && world.opened.get().isEmpty,
              "第 3 步（allowLogin false、沒登入；W183 R6a 起 TAP 的開關不走這條）：停在「先登入 Cloudflare」、不自己開授權頁", world.status(.authorize).message)
        check(world.status(.tunnel).status == .pending && !world.service.settings.load().enabled, "沒授權就不往下做、不打開開關")
    }

    @MainActor static func loginAndResume(_ check: Checker, _ world: World, _ fixture: Fixture, sentinel: URL) async throws {
        _ = try? world.service.updateSettings { $0.enabled = true }   // TAP 的開關打開（開關開著，登入完才會接著做）
        world.setup.login(trigger: .user)
        let waiting = await waitUntil(20) { world.status(.authorize).status == .waitingUser && !world.opened.get().isEmpty }
        check(waiting && world.opened.get().first?.host == "dash.cloudflare.com" && world.setup.isBusy,
              "授權：在 OS 瀏覽器打開 Cloudflare 授權頁、等使用者按", world.status(.authorize).message)
        world.setup.refreshDerived()
        var chooseRefused = false
        do { try world.setup.chooseDomain(accountID: fixture.accountID, zoneID: fixture.zoneID) } catch { chooseRefused = (error as? HandsSetupError) == .busy }
        let hostRefused = world.setup.chooseHost(fixture.secondaryID, trigger: .user) == .busy
        check(chooseRefused && hostRefused, "設定進行中：不准換網域、不准換主機（回報忙碌，不會默默改掉一半）")
        let probe = (try? JSONSerialization.jsonObject(with: Data(contentsOf: world.ctrl.appendingPathComponent("probe.json")))) as? [String: String]
        check(probe?["appWrite"] == "EPERM" && probe?["tmpWrite"] == "EPERM" && probe?["exec"] == "EPERM"
              && !FileManager.default.fileExists(atPath: world.paths.appDir.appendingPathComponent("evil.txt").path),
              "設定指令的沙盒（真的看門程式＋sandbox-exec）：寫不到 App 資料與 /tmp、開不了別的程式", "\(String(describing: probe))")
        world.flag("authorized", true)
        // W183 R8c（GPT-6 必改 4）：登入只是登入——授權存好、帳號清單更新就停在「選網域、按套用」（不採用、不建網址）。
        let authorized = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        try await confirmGateChecks(check, world, fixture, authorized: authorized)
        // 使用者在 ChatGPT build 的 Cloudflare 節點選網域、按「套用」＝這時才建網址。
        let applied = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .user)
        let finished = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
        let state = world.setup.snapshot
        check(applied && finished && world.status(.authorize).status == .done && world.setup.authorizedSummary()?.needsConfirm == false,
              "W183 R8c 套用：使用者選網域、按「套用」才用這個帳號與網域（第 3 步完成、接著建網址）", world.status(.authorize).message)
        check(world.accounts.snapshot.count == 1 && world.accounts.snapshot.first?.selected?.name == "example.com"
              && world.accounts.snapshot.first?.name == fixture.accountName && world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + fixture.zoneID),
              "授權：環境登入 › Cloudflare 記住帳號與網域；憑證在鑰匙圈（假）", "\(world.accounts.snapshot)")
        check(world.lookedUp.get() == [fixture.canaryAPIToken], "授權：只用授權裡的 token 問一次網域名稱")
        check(world.status(.tunnel).status == .done && state.tunnelID == "0f0e0d0c-0b0a-4908-8706-050403020100"
              && state.publicHost == "os-for-chatgpt.example.com" && world.dnsNames() == ["os-for-chatgpt.example.com"]
              && state.tunnelName?.hasPrefix("tatwo-hands-") == true && state.retiredHost == nil && world.dnsTokens.get().isEmpty,
              "第 4 步：新通道（隨機名字）＋W183 R6a 固定網址 os-for-chatgpt.<網域>（新建不用查 API、沒有要刪的）", "\(String(describing: state.publicHost))")
        check((try? world.secrets.read(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)) == fixture.canaryToken
              && state.tokenTunnelID == state.tunnelID, "第 4 步：通道 token 收進鑰匙圈（R2 讀的位置）")
        let settings = world.service.settings.load()
        check(world.status(.start).status == .done && settings.enabled && settings.publicHost == state.publicHost && world.asked.get() == 0,
              "第 5 步：寫 public_host、打開、關口運作中（使用者從 TAP 打開：不另外問）", world.status(.start).message)
        check(world.status(.url).status == .done && world.status(.url).message.contains("https://\(state.publicHost ?? "-")/mcp"),
              "第 6 步：網址給 ChatGPT", world.status(.url).message)
        check(world.status(.remember).status == .done && world.accounts.snapshot.first?.tunnelID == state.tunnelID,
              "第 8 步：記住帳號、網域與通道（不用等配對）")
        check(world.status(.pairing).status == .waitingUser && world.status(.pairing).message == HandsSetup.pairingWaitingMessage
              && world.offers.get() == 1 && world.service.auth.windowExpiresAt == nil,
              "第 7 步（W183 R6a）：走到配對＝叫 HandsConnectFlow.offer（私訊框的［連線］卡），不開配對窗口、沒有「開始配對」", world.status(.pairing).message)
        world.grant.set(true)
        world.setup.refreshDerived()
        check(world.status(.pairing).status == .done && world.setup.nextStep == nil, "第 7 步：有一筆有效授權就算配對完成")
        secretChecks(check, world, fixture, sentinel: sentinel)
    }

    /// W183 R8c（GPT-6 必改 4；取代 R3b 的「確認帳號與網域」關卡）：登入只是登入——授權拿到了、使用者還沒在 ChatGPT build 選網域按「套用」：
    /// 不採用帳號、不自動選網域、不建通道、不改 DNS、不打開；AI 不能跳過、不能替他選；舊的確認碼一律不收。
    @MainActor static func confirmGateChecks(_ check: Checker, _ world: World, _ fixture: Fixture, authorized: Bool) async throws {
        let state = world.setup.snapshot
        let account = world.accounts.account(fixture.accountID)
        check(authorized && world.status(.authorize).status == .waitingUser && state.accountID == nil && state.zoneID == nil
              && account != nil && account?.selectedDomain == nil && account?.selected == nil
              && world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + fixture.zoneID)
              && world.log("creates.log").isEmpty && world.dnsNames().isEmpty && world.status(.tunnel).status == .pending
              && world.service.settings.load().publicHost == nil && world.setup.authorizedSummary() == nil,
              "W183 R8c 登入只是登入：授權存進鑰匙圈、帳號清單更新就停（不採用、不選網域、不建通道、不改 DNS、不打開）", world.status(.authorize).message)
        let ai = try HandsSetupTool.handle(method: "hands_setup_status", params: [:], setup: world.setup)
        let aiAll = try HandsSetupTool.handle(method: "hands_setup_step", params: ["step": "all"], setup: world.setup)
        _ = await waitUntil(10) { !world.setup.isBusy }
        let afterAll = world.status(.authorize).message
        let aiTunnel = try HandsSetupTool.handle(method: "hands_setup_step", params: ["step": "tunnel"], setup: world.setup)
        _ = await waitUntil(10) { !world.setup.isBusy }
        let aiText = text(ai) + text(aiAll) + text(aiTunnel)
        check(afterAll == HandsSetup.chooseDomainMessage && world.status(.tunnel).message == HandsSetup.applyFirstMessage
              && world.log("creates.log").isEmpty && world.dnsNames().isEmpty && world.setup.snapshot.zoneID == nil
              && world.accounts.account(fixture.accountID)?.selectedDomain == nil
              && !aiText.contains(fixture.accountName) && !aiText.contains("example.com"),
              "W183 R8c AI 跳不過「套用」：hands_setup_step all 停在選網域、tunnel 停在「先按套用」；AI 看不到帳號與網域、不會替他選", afterAll)
        var staleRefused = false
        do { try world.confirm(token: "stale-token-000000000000", domain: "example.com") } catch { staleRefused = (error as? HandsConfirmRefusal) == .stale }
        check(staleRefused && world.log("creates.log").isEmpty && world.setup.snapshot.zoneID == nil,
              "W183 R8c 舊的「是這個，繼續」（確認碼）一律不收：確認不會採用帳號、不會接著建網址")
    }

    static func text(_ value: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self) }

    static func secretChecks(_ check: Checker, _ world: World, _ fixture: Fixture, sentinel: URL) {
        let argv = world.log("argv.log")
        let files = world.stateFiles() + world.allFilesText()
        let payload = String(decoding: (try? JSONSerialization.data(withJSONObject: world.setup.statusPayload())) ?? Data(), as: UTF8.self)
        let leaks = fixture.secrets.filter { argv.contains($0) || files.contains($0) || payload.contains($0) }
        check(leaks.isEmpty && !files.contains("ARGO TUNNEL TOKEN") && !payload.contains("ARGO TUNNEL TOKEN"),
              "秘密：憑證與通道 token 不在 argv、狀態檔、帳號清單、工具回傳（canary）")
        check(world.opened.get().contains { $0.absoluteString.contains(fixture.loginCanary) } && !files.contains(fixture.loginCanary)
              && !payload.contains(fixture.loginCanary),
              "授權網址（canary）：只拿來開 OS 瀏覽器；不在狀態檔、帳號清單、hands_setup_status")
        let accountLeaks = [fixture.accountName, fixture.accountID, String(fixture.accountID.prefix(6)), fixture.zoneID].filter { payload.contains($0) }
        check(accountLeaks.isEmpty && payload.contains("\"code\""),
              "給 AI 的狀態（hands_setup_status）：沒有 Cloudflare 帳號名稱與 id（canary）；每步有固定代碼", "\(accountLeaks)")
        // W183 R3b 審查：網域與對外主機名只在畫面；給 AI 的只有關口起來後的 MCP 連線網址（url 欄與第 6 步，助理代填 ChatGPT 用）。
        var stripped = world.setup.statusPayload()
        stripped["url"] = nil
        stripped["steps"] = (stripped["steps"] as? [[String: Any]])?.filter { $0["step"] as? String != HandsSetupStep.url.rawValue }
        if (stripped["user_action"] as? String)?.contains("/mcp") == true { stripped["user_action"] = nil }
        let hostText = text(stripped)
        check(stripped["domain"] == nil && stripped["public_host"] == nil && !hostText.contains("example.com")
              && (world.setup.statusPayload()["url"] as? String)?.hasSuffix("/mcp") == true,
              "給 AI 的狀態：沒有網域與對外主機名（只有 MCP 連線網址那一欄與第 6 步）", String(hostText.prefix(300)))
        let homes = Set(world.log("home.log").split(separator: "\n").map(String.init))
        let expected = HandsPath.realpath(world.setupHome.path) ?? world.setupHome.path
        check(homes == [expected], "cloudflared 用獨立 HOME（不是使用者的家目錄）", "\(homes)")
        check((try? String(contentsOf: sentinel, encoding: .utf8)) == "untouched"
              && (try? FileManager.default.contentsOfDirectory(atPath: sentinel.deletingLastPathComponent().path)) == ["sentinel"],
              "不碰 ~/.cloudflared（假 HOME 裡的原樣）")
        check(world.leftovers().isEmpty, "暫存憑證、授權檔、通道憑證檔用完就刪", "\(world.leftovers())")
        let perms = world.log("perm.log").split(separator: "\n").map(String.init)
        check(!perms.isEmpty && perms.allSatisfy { $0.hasSuffix(" 600") } && perms.contains { $0.hasPrefix("cert ") } && perms.contains { $0.hasPrefix("cred ") }
              && perms.contains { $0.hasPrefix("origincert ") },
              "暫存憑證 0600；cloudflared 自己寫的授權檔（cert.pem）與通道憑證 json 也是 0600（看門程式 umask 077）", perms.joined(separator: ","))
        var info = stat()
        let mode = lstat(world.paths.appDir.appendingPathComponent("setup.json").path, &info) == 0 ? info.st_mode & 0o777 : 0
        let accountsMode = lstat(world.accounts.fileURL.path, &info) == 0 ? info.st_mode & 0o777 : 0
        check(mode == 0o600 && accountsMode == 0o600, "setup.json、accounts.json 都是 0600")
        let accountKeys = (try? JSONSerialization.jsonObject(with: Data(contentsOf: world.accounts.fileURL)) as? [String: Any])?["accounts"] as? [[String: Any]]
        check(accountKeys?.allSatisfy { Set($0.keys).isSubset(of: ["id", "name", "domains", "selected_domain", "tunnel_id"]) } == true,
              "帳號清單只放 id／名稱／網域／選用網域／通道 id")
    }

    @MainActor static func cancelAndResume(_ check: Checker, _ world: World, _ fixture: Fixture) async throws {
        let logins = { world.log("argv.log").split(separator: "\n").filter { $0.hasSuffix(" login") }.count }
        let before = logins()
        world.setup.run(.authorize, trigger: .user)
        let waiting = await waitUntil(20) { world.status(.authorize).status == .waitingUser }
        world.setup.cancel()
        let stopped = await waitUntil(15) { !world.setup.isBusy }
        check(waiting && stopped && world.status(.authorize).status == .pending && world.status(.authorize).message.contains("取消")
              && world.leftovers().isEmpty,
              "中斷：取消等授權（等舊指令真的結束才收尾），步驟回到「還沒做」、可以接著做", world.status(.authorize).message)
        world.flag("authorized", true)
        world.setup.run(.authorize, trigger: .user)
        let resumed = await waitUntil(20) { !world.setup.isBusy && world.status(.authorize).status == .done }
        world.flag("authorized", false)
        // W183 R8c：重新登入選好的那個網域＝授權更新（不換帳號、不換網域、不重建）；登入只是登入。
        let creates = world.log("creates.log")
        check(resumed && world.accounts.snapshot.count == 1 && logins() == before + 2 && world.leftovers().isEmpty
              && world.setup.snapshot.zoneID == fixture.zoneID && world.accounts.snapshot.first?.selected?.zoneID == fixture.zoneID,
              "續跑：再授權一次＝同一個帳號（不重複）、選好的網域照舊、沒有殘留檔",
              "resumed=\(resumed) accounts=\(world.accounts.snapshot.count) logins=\(logins())/\(before + 2) leftovers=\(world.leftovers()) \(world.status(.authorize).message)")
        // 已完成的步驟不重做：一次跑完只剩配對（已經有授權）。
        world.setup.runAll(trigger: .user, allowLogin: false)
        _ = await waitUntil(10) { !world.setup.isBusy }
        check(world.log("creates.log") == creates && world.setup.nextStep == nil, "續跑：已完成的步驟不重做（不會再建一條通道）")
    }

    /// 移除正在用的帳號：先選了另一個帳號 B（還沒續跑），再移除 A——A 的通道 token 還在鑰匙圈，手腳要停、token 要刪。
    @MainActor static func removalChecks(_ check: Checker, _ world: World, _ fixture: Fixture) async throws {
        let otherAccount = String(repeating: "b", count: 32), otherZone = String(repeating: "c", count: 32)
        let otherHost = "example" + ".net"
        try world.accounts.upsert(accountID: otherAccount, name: "Other One", domain: CloudflareDomain(name: otherHost, zoneID: otherZone), cert: fixture.certPEM)
        try world.setup.chooseDomain(accountID: otherAccount, zoneID: otherZone)
        let tokenOwner = world.setup.snapshot.tokenTunnelID
        let changesBefore = world.serviceChanges.get()
        let result = HandsLocked<String??>(nil)
        world.setup.removeAccount(fixture.accountID) { problem in result.set(.some(problem)) }
        let done = await waitUntil(15) { result.get() != nil }
        check(tokenOwner == "0f0e0d0c-0b0a-4908-8706-050403020100", "換帳號不會忘記鑰匙圈裡的 token 是哪一條通道的")
        check(done && result.get() == .some(nil) && !world.service.settings.load().enabled && world.serviceChanges.get() > changesBefore
              && !world.secrets.contains(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)
              && world.accounts.account(fixture.accountID) == nil
              && !world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + fixture.zoneID)
              && world.setup.snapshot.tokenTunnelID == nil,
              "移除正在用的帳號（先選了別的帳號也一樣）：先關開關、關口停下，再刪通道 token、授權與清單",
              "\(String(describing: result.get())) enabled=\(world.service.settings.load().enabled)")
    }

    // MARK: - 第二個世界：網域名稱問不到、建通道失敗、DNS 撞名、助理打開要先問

    @MainActor static func errorFlowChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "errors", zoneName: nil)
        world.flag("fail-create", true)
        world.flag("authorized", true)
        world.setup.runAll(trigger: .assistant, allowLogin: true)
        _ = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        // W183 R8c（GPT-6 必改 4）：助理叫的登入也只是登入——網域名稱問不到＝先記帳號（名稱空的），停在「選網域、按套用」；不建通道。
        check(world.accounts.snapshot.count == 1 && world.accounts.snapshot.first?.domains.first?.name == ""
              && world.status(.authorize).status == .waitingUser && world.setup.snapshot.zoneID == nil
              && world.log("creates.log").isEmpty && world.lookedUp.get().count == 1,
              "W183 R8c 助理叫的登入也只是登入：網域名稱問不到＝先記帳號、停在選網域；不建通道", world.status(.authorize).message)
        world.setup.run(.tunnel, trigger: .assistant)
        _ = await waitUntil(10) { !world.setup.isBusy }
        check(world.status(.tunnel).message == HandsSetup.applyFirstMessage && world.log("creates.log").isEmpty && world.setup.snapshot.zoneID == nil,
              "W183 R8c 助理不能替使用者選網域、按「套用」：建網址停在「先按套用」", world.status(.tunnel).message)
        // 再登入一次問到網域名稱（登入只是登入：只補帳號清單的名稱）；使用者選網域。
        world.names.set("example.com")
        world.flag("authorized", true)
        world.setup.login(trigger: .user)
        _ = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).status != .running }
        world.flag("authorized", false)
        let named = world.accounts.snapshot.first?.domains.first?.name == "example.com" && world.setup.snapshot.zoneID == nil
            && world.status(.authorize).message == HandsSetup.chooseDomainMessage && world.log("creates.log").isEmpty
        try world.setup.chooseDomain(accountID: fixture.accountID, zoneID: fixture.zoneID)
        world.setup.run(.tunnel, trigger: .assistant)
        _ = await waitUntil(10) { !world.setup.isBusy }
        check(named && world.setup.snapshot.domain == "example.com" && world.status(.tunnel).message == HandsSetup.applyFirstMessage
              && world.log("creates.log").isEmpty && !world.service.settings.load().enabled,
              "W183 R8c 再登入補上網域名稱；選了網域也只是選——助理照樣不能新建網址（要使用者按）", world.status(.tunnel).message)
        world.setup.run(.tunnel, trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy }
        check(world.status(.tunnel).status == .failed && world.status(.tunnel).message.contains("Cloudflare 拒絕")
              && world.setup.snapshot.tunnelID == nil && !world.status(.tunnel).message.contains("/"),
              "建通道失敗：白話錯誤（不回原文、沒有路徑），不記半套通道", world.status(.tunnel).message)
        let failedPending = world.setup.snapshot.pendingTunnels?.values.first?.name
        let errorLog = (try? String(contentsOf: world.setup.dependencies.paths.root.appendingPathComponent("logs/setup-errors.log"), encoding: .utf8)) ?? ""
        check(failedPending?.hasPrefix("tatwo-hands-") == true && errorLog.contains("tunnel.create exit=1") && errorLog.contains("category=auth")
              && !errorLog.contains("Authentication") && !errorLog.contains("/") && !errorLog.contains(fixture.canaryToken),
              "W183 R5：建之前先記通道名字（寫進磁碟）；失敗只記分類進 logs（沒有原文、路徑、token）", errorLog)
        world.flag("fail-create", false)
        world.flag("create-exists-once", true)
        world.setup.run(.tunnel, trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy }
        check(world.status(.tunnel).status == .failed && world.status(.tunnel).message.contains("撞到")
              && (world.setup.snapshot.pendingTunnels?.isEmpty ?? true) && world.setup.snapshot.tunnelID == nil,
              "W183 R5：上次沒建成（名字查不到）就換新名字建；名字撞到既有的通道＝不認領、名字作廢", world.status(.tunnel).message)
        world.flag("create-noid-once", true)
        world.flag("dns-collide-once", true)
        world.setup.run(.tunnel, trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy }
        let argv = world.log("argv.log").split(separator: "\n")
        let listCalls = argv.filter { $0.contains(" list ") }
        check(world.setup.snapshot.tunnelID == "0f0e0d0c-0b0a-4908-8706-050403020100"
              && (world.setup.snapshot.pendingTunnels?.isEmpty ?? true) && listCalls.count == 2 && listCalls.first?.contains(failedPending ?? "?") == true
              && world.log("created.log").split(separator: "\n").count == 1,
              "W183 R5：建成了卻讀不到 id＝用名字找回來（有「這一輪建的」證據才認；不多建一條）", "\(listCalls.count)")
        // W183 R6a：固定的名字已經有別的紀錄＝停下說明：不覆蓋、不換名字（不再換一個隨機名字重試）。
        let collided = world.status(.tunnel)
        let firstDNS = world.log("argv.log").split(separator: "\n").filter { $0.contains(" dns ") }
        check(collided.status == .failed && collided.message.contains("不覆蓋、也不換名字") && collided.message.contains("os-for-chatgpt.example.com")
              && world.setup.snapshot.publicHost == nil && firstDNS.count == 1 && firstDNS.allSatisfy { $0.hasSuffix(" os-for-chatgpt.example.com") }
              && HandsOneSwitchStatus.short(collided.message).contains("已經有別的 DNS 紀錄"),
              "W183 R6a 固定子網域撞名：停下並一句話說明（不覆蓋、不換名字；只試過那一個名字）", collided.message)
        world.setup.run(.tunnel, trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy }
        let host = world.setup.snapshot.publicHost ?? ""
        let dnsCalls = world.log("argv.log").split(separator: "\n").filter { $0.contains(" dns ") }
        check(world.status(.tunnel).status == .done && host == "os-for-chatgpt.example.com" && world.setup.snapshot.domain == "example.com"
              && world.accounts.snapshot.first?.selected?.name == "example.com" && dnsCalls.count == 2
              && dnsCalls.allSatisfy { $0.hasSuffix(" os-for-chatgpt.example.com") } && !dnsCalls.contains { $0.contains("overwrite") },
              "W183 R6a 撞名的紀錄清掉後按「重試」：用同一個固定名字設好（不覆蓋、不加 --overwrite-dns）", "\(host) \(dnsCalls.count)")
        world.approve.set(false)
        world.setup.run(.start, trigger: .assistant)
        _ = await waitUntil(15) { !world.setup.isBusy }
        check(world.asked.get() == 1 && world.status(.start).status == .failed && !world.service.settings.load().enabled,
              "助理要打開、開關原本關著：先在 Island 問；使用者沒允許就不打開", world.status(.start).message)
        world.approve.set(true)
        world.setup.run(.start, trigger: .assistant)
        _ = await waitUntil(15) { !world.setup.isBusy }
        check(world.asked.get() == 2 && world.status(.start).status == .done && world.service.settings.load().enabled,
              "使用者允許後才打開、關口運作中", world.status(.start).message)
    }

    @MainActor static func badURLChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "badurl", zoneName: "example.com")
        world.flag("bad-url", true)
        world.setup.login(trigger: .user)
        _ = await waitUntil(20) { !world.setup.isBusy && world.status(.authorize).status == .failed }
        check(world.status(.authorize).status == .failed && world.opened.get().isEmpty && world.accounts.snapshot.isEmpty
              && world.status(.authorize).message.contains("不是 Cloudflare"),
              "授權網址不是 Cloudflare 的：不開、不收", world.status(.authorize).message)
    }

    // MARK: - 關掉之後再登入：不會自己打開（W183 R3 審查）

    @MainActor static func resumeIntentChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "resume", zoneName: "example.com")
        _ = try? world.service.updateSettings { $0.enabled = true }
        world.setup.runAll(trigger: .user, allowLogin: false)
        _ = await waitUntil(15) { !world.setup.isBusy && world.status(.authorize).status == .waitingUser }
        // 使用者在 TAP 把開關關掉（跟畫面一樣：先關開關、再 turnedOff）。
        _ = try? world.service.updateSettings { $0.enabled = false }
        world.setup.turnedOff()
        _ = await waitUntil(5) { !world.setup.isBusy }
        // 稍後只到環境登入加 Cloudflare 帳號。
        world.flag("authorized", true)
        world.setup.login(trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        _ = await waitUntil(2) { false }   // 登入完不會有「接著做」的工作排進來
        check(!world.setup.isBusy && world.status(.authorize).status == .waitingUser && world.status(.authorize).message == HandsSetup.chooseDomainMessage
              && world.setup.snapshot.zoneID == nil && world.log("creates.log").isEmpty && world.status(.tunnel).status == .pending
              && !world.service.settings.load().enabled && world.asked.get() == 0 && world.accounts.snapshot.count == 1,
              "關掉之後再登入（環境登入）：登入只是登入——只記帳號，不會自己接著建通道、打開手腳（W183 R8c：沒有「登入完接著做」）", world.status(.tunnel).message)
    }

    // MARK: - 舊指令取消後一直沒結束：結束前不准重跑

    @MainActor static func lingeringChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let stuck = StuckRunner()
        let world = try World(fixture, folder: "stuck", zoneName: "example.com", runner: stuck, exitWait: 0.5)
        world.setup.login(trigger: .user)
        _ = await waitUntil(10) { world.status(.authorize).status == .running }
        world.setup.cancel()
        _ = await waitUntil(10) { !world.setup.isBusy }
        check(world.status(.authorize).status == .failed && world.status(.authorize).message == HandsSetup.lingeringMessage,
              "取消後舊指令沒在時限內結束：不清檔、不假裝好了，明講還沒結束", world.status(.authorize).message)
        world.setup.run(.authorize, trigger: .user)
        _ = await waitUntil(10) { !world.setup.isBusy }
        check(world.status(.authorize).status == .failed && world.status(.authorize).message == HandsSetup.lingeringMessage,
              "舊指令還沒結束：擋住重跑", world.status(.authorize).message)
        stuck.command.released.set(true)
        world.setup.run(.authorize, trigger: .user)
        let proceeded = await waitUntil(10) { world.status(.authorize).status == .running }
        world.setup.cancel()
        _ = await waitUntil(10) { !world.setup.isBusy }
        check(proceeded && world.status(.authorize).status == .pending, "舊指令結束之後：可以重跑", world.status(.authorize).message)
    }

    // MARK: - App 當掉：看門程式收掉 cloudflared 並清檔；重開時收掉上次那一組

    @MainActor static func crashChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "crash", zoneName: "example.com")
        let home = HandsPath.realpath(world.setupHome.path) ?? world.setupHome.path
        let dotDir = world.setupHome.appendingPathComponent(".cloudflared", isDirectory: true)
        try HandsFiles.ensureDirectory(dotDir)
        let config = world.setupHome.appendingPathComponent("config.yml")
        try HandsFiles.writeAtomically(Data("no-autoupdate: true\n".utf8), to: config)
        let script = fakeScript(ctrl: world.ctrl.path, tunnelID: "0f0e0d0c-0b0a-4908-8706-050403020100", appDir: world.paths.appDir.path)
        let runner = HandsCloudflaredRunner(disclaimResponsibilityForTesting: false, programPrefix: ["-e", script])
        let sawURL = HandsLocked(false), exit = HandsLocked<Int32??>(nil)
        let command = try runner.start(cloudflared: fixture.node, arguments: ["tunnel", "--no-autoupdate", "--config", config.path, "login"],
                                       home: world.setupHome, handsRoot: world.paths.root,
                                       onLine: { if HandsCloudflared.loginURL(in: $0) != nil { sawURL.set(true) } },
                                       onExit: { exit.set(.some($0)) })
        _ = await waitUntil(15) { sawURL.get() }
        let pid = pid_t(world.log("pid.log").split(separator: "\n").last.flatMap { Int32($0) } ?? 0)
        // 假裝 cloudflared 已經寫了明文：暫存憑證、通道憑證、授權檔。
        for file in [world.setupHome.appendingPathComponent("oc-crash.pem"), world.setupHome.appendingPathComponent("cred-crash.json"),
                     dotDir.appendingPathComponent("cert.pem")] {
            try Data("W183UI-CRASH".utf8).write(to: file)
        }
        (command as? HandsCloudflaredRunner.Command)?.debugCloseStdin()   // App 當掉＝stdin EOF（不送任何訊號）
        let exited = command.waitForExit(timeout: 10)
        let gone = pid > 1 ? HandsSetup.waitGone(pid, seconds: 3) : false
        check(sawURL.get() && exited && gone && world.leftovers().isEmpty,
              "App 當掉（stdin EOF）：看門程式收掉 cloudflared、等它結束、刪暫存憑證與授權檔", "exited=\(exited) gone=\(gone) pid=\(pid) \(world.leftovers())")
        // 上次沒收掉的那一組（紀錄在 app/setup-runner.json）＋留下的明文：重開 App（新的 HandsSetup）先收掉、清乾淨。
        let leftover = try HandsCloudflaredRunner.spawn(executable: HandsGatewayLaunch.shell,
                                                         arguments: ["-c", HandsCloudflaredRunner.guardScript, HandsCloudflaredRunner.guardName, home, "/bin/sleep", "30"],
                                                         environment: ["PATH": "/usr/bin:/bin"], currentDirectory: home, disclaim: false,
                                                         onLine: { _ in }, onExit: { _ in })
        try HandsFiles.writeAtomically(try JSONSerialization.data(withJSONObject: ["pgid": Int(leftover.pid)]), to: world.setup.runnerRecordURL)
        try Data("W183UI-CRASH".utf8).write(to: world.setupHome.appendingPathComponent("oc-left.pem"))
        try Data("W183UI-CRASH".utf8).write(to: dotDir.appendingPathComponent("cert.pem"))
        let ours = HandsCloudflaredRunner.isOurGuard(pid: leftover.pid, setupHome: home)
        let reopened = HandsSetup(dependencies: world.setup.dependencies)
        let recovered = await waitUntil(12) {
            leftover.hasExited && world.leftovers().isEmpty && !FileManager.default.fileExists(atPath: reopened.runnerRecordURL.path)
        }
        check(ours && recovered && reopened.snapshot.steps.values.allSatisfy { $0.status != .running },
              "App 重開：認出上次的看門程式（argv）、收掉那一組、清掉留下的明文與紀錄", "ours=\(ours) recovered=\(recovered) \(world.leftovers())")
        check(!HandsCloudflaredRunner.isOurGuard(pid: getpid(), setupHome: home), "不是我們的看門程式就不動（pid 可能被別的程式重用）")
    }

    // MARK: - OS 工具的回傳

    static func toolHandlerChecks(_ check: Checker, _ fixture: Fixture) throws {
        let world = try World(fixture, folder: "tool", zoneName: "example.com")
        let status = try HandsSetupTool.handle(method: "hands_setup_status", params: ["callerThreadID": UUID().uuidString], setup: world.setup)
        let steps = status["steps"] as? [[String: Any]] ?? []
        check(steps.count == 8 && status["next_step"] as? String == "host" && (status["rule"] as? String)?.contains("配對") == true,
              "hands_setup_status：八步、下一步、規則（兩步要使用者按）")
        var rejected: [String] = []
        for params: [String: Any] in [["step": "pairing"], ["step": "bogus"], ["step": "all", "extra": 1], ["step": "all", "action": "delete"],
                                       ["step": "host", "hostDeviceID": "not-a-uuid"]] {
            do { _ = try HandsSetupTool.handle(method: "hands_setup_step", params: params, setup: world.setup) } catch { rejected.append("\(error)") }
        }
        check(rejected.count == 5 && rejected[0].contains("needs_user"), "hands_setup_step：配對不能由工具開；錯的參數一律拒", "\(rejected)")
        do { _ = try HandsSetupTool.handle(method: "hands_setup_status", params: ["x": 1], setup: world.setup); check(false, "hands_setup_status 不收參數") }
        catch { check(true, "hands_setup_status 不收參數") }
    }

    // MARK: - 副設備 RPC（真的設備簽章）

    /// remote_hands_status／action 回傳的欄位白名單（W183 R3b 加 setup_busy、login_url、authorized、can_reauthorize、started）。
    static let remoteStatusKeys: Set<String> = ["host_device_id", "host_name", "this_device_is_host", "enabled", "level", "public_host", "phase",
                                                "allowed_projects", "grants", "window_expires_at", "card", "setup", "done",
                                                "setup_busy", "login_url", "authorized", "can_reauthorize", "started", "setup_epoch",
                                                "setup_run", "setup_run_mine",   // W183 R5b 審查：這一輪的編號、是不是問的那台按的
                                                "host_epoch",   // W183 R6a 審查：主機任期
                                                "project_choices",   // W183 R7a：卡片要的專案清單（id、名稱、資料夾最後一段）
                                                "safety_incident"]   // W183 R8c 審查：安全停機的事故編號（亂數；解除安全鎖要帶）

    /// 兩台設備（主設備＋副設備）的簽章 RPC：真的 ssh-keygen 金鑰、真的驗章；主設備那端交給 host（可以換）。
    struct RemoteHarness {
        let primaryDispatch: DeviceDispatch
        let secondaryDispatch: DeviceDispatch
        let proofs: HandsLocked<[[String: Any]]>
        let host: HandsLocked<HandsRemote.Host?>
    }

    static func remoteHarness(_ root: URL, _ fixture: Fixture) throws -> RemoteHarness? {
        let fm = FileManager.default
        let pRoot = root.appendingPathComponent("primary"), sRoot = root.appendingPathComponent("secondary")
        for dir in [pRoot.appendingPathComponent("entry"), sRoot.appendingPathComponent("entry"), pRoot.appendingPathComponent("live"), sRoot.appendingPathComponent("live")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let pEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": pRoot.appendingPathComponent("entry").path], preference: nil)
        let sEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": sRoot.appendingPathComponent("entry").path], preference: nil)
        let pID = fixture.primaryID, sID = fixture.secondaryID
        try DeviceIdentity(deviceID: pID, name: "Primary One", hardwareModel: "Fixture", role: .primary, epoch: 1,
                           primaryDeviceID: pID, updatedAt: Date()).encoded().write(to: pEntry.deviceJSON)
        try DeviceIdentity(deviceID: sID, name: "Fixture", hardwareModel: "Fixture", role: .secondary, epoch: 1,
                           primaryDeviceID: pID, updatedAt: Date()).encoded().write(to: sEntry.deviceJSON)
        let key = root.appendingPathComponent("paired-key"), hostKey = root.appendingPathComponent("host-key")
        for path in [key, hostKey] {
            let (status, _) = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path.path])
            guard status == 0 else { return nil }
        }
        let publicKey = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
        let publicHost = try String(contentsOf: URL(fileURLWithPath: hostKey.path + ".pub"), encoding: .utf8)
        let pRegistry = DeviceRegistry(root: pRoot.appendingPathComponent("live"), authorizedKeysURL: pRoot.appendingPathComponent("authorized_keys"))
        let sRegistry = DeviceRegistry(root: sRoot.appendingPathComponent("live"), authorizedKeysURL: sRoot.appendingPathComponent("authorized_keys"))
        let fingerprint = try pRegistry.authorize(publicKey: publicKey, deviceID: sID)
        _ = try pRegistry.add(DeviceRecord(id: sID, name: "Fixture", host: "127.0.0.1", user: "fixture", sshPort: 1, publicKeyFingerprint: fingerprint,
                                           addedAt: Date(), lastSeenAt: Date(), workdirMap: [:], role: .secondary, epoch: 1))
        _ = try sRegistry.add(DeviceRecord(id: pID, name: "Primary One", host: "127.0.0.1", user: "fixture", sshPort: 1,
                                           publicKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: publicHost),
                                           addedAt: Date(), lastSeenAt: Date(), workdirMap: [:], role: .primary, epoch: 1))
        let primaryDispatch = DeviceDispatch(entry: pEntry, registry: pRegistry, retireBackup: { _ in })
        let proofs = HandsLocked<[[String: Any]]>([])
        let hostBox = HandsLocked<HandsRemote.Host?>(nil)
        let secondaryDispatch = DeviceDispatch(entry: sEntry, registry: sRegistry, environment: ["TATWO2_SSH_KEY_PATH": key.path],
                                               retireBackup: { _ in }, rpc: { _, method, proof in
            proofs.update { $0.append(proof) }
            do {
                let (sender, payload) = try primaryDispatch.authenticate(method: method, proof: proof)
                guard HandsRemote.methods.contains(method), let host = hostBox.get() else { throw HandsRemote.Failure.invalid("method") }
                return try HandsRemote.handle(method: method, payload: payload, sender: sender, host: host)
            } catch { throw RemoteHostLinkError.remoteError(String(describing: error)) }
        })
        return RemoteHarness(primaryDispatch: primaryDispatch, secondaryDispatch: secondaryDispatch, proofs: proofs, host: hostBox)
    }

    static func remoteChecks(_ check: Checker, _ fixture: Fixture) throws {
        let root = fixture.base.appendingPathComponent("remote", isDirectory: true)
        guard let harness = try remoteHarness(root, fixture) else { return check(false, "副設備 RPC：產生測試金鑰") }
        let pID = fixture.primaryID, sID = fixture.secondaryID
        // 主機（主設備）的手腳：開著、主機是自己。關口狀態跟著設定走（交出主機＝停下）。
        let handsRoot = URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands", isDirectory: true)
        let service = HandsService(paths: HandsPaths(root: handsRoot))
        service.deviceIDOverride = pID
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = pID; $0.publicHost = "hands-fixture.example.com" }
        let host = HandsRemote.Host(service: service, phase: {
            let settings = service.settings.load()
            return settings.enabled && HandsHostAuthority.same(settings.hostDeviceID, pID) ? .running(url: "https://hands-fixture.example.com/mcp") : .stopped
        }, setup: { nil }, localDeviceID: { pID }, devices: { [pID: "Primary One", sID: "Fixture"] })
        harness.host.set(host)
        try remoteScenario(check, secondaryDispatch: harness.secondaryDispatch, primaryDispatch: harness.primaryDispatch, service: service,
                           proofs: harness.proofs, handsRoot: handsRoot)
        try hostHandoffScenario(check, secondaryDispatch: harness.secondaryDispatch, service: service, host: host, primaryID: pID, secondaryID: sID)
    }

    static func remoteScenario(_ check: Checker, secondaryDispatch: DeviceDispatch, primaryDispatch: DeviceDispatch, service: HandsService,
                               proofs: HandsLocked<[[String: Any]]>, handsRoot: URL) throws {
        let first = try secondaryDispatch.callPrimary(method: "remote_hands_status", payload: [:])
        let decoded = HandsRemoteStatus(first)
        check(decoded?.phaseState == "running" && decoded?.url == "https://hands-fixture.example.com/mcp" && decoded?.card == nil
              && decoded?.windowExpiresAt == nil && decoded?.primaryIsHost == true && decoded?.hostName == "Primary One",
              "副設備 RPC：驗過設備簽章才回主機的狀態與網址（主機是誰）；沒開配對就沒有配對碼")
        let allowed = remoteStatusKeys
        check(Set(first.keys).isSubset(of: allowed), "副設備 RPC：只回畫面要的欄位", "\(first.keys.sorted())")
        // W183 R6b：副設備的裸「開始配對」停用（碼會跑到所有設備都輪詢得到的狀態）；改用 begin_connect（碼只給按的那台，w183connect 驗）。
        var retired = false
        do { _ = try secondaryDispatch.callPrimary(method: "remote_hands_action", payload: ["op": "start_pairing"]) }
        catch { retired = String(describing: error).contains(HandsConnectRemote.startPairingRetired) }
        check(retired && service.auth.windowExpiresAt == nil, "副設備 RPC：裸的「開始配對」停用，主機不開窗口（W183 R6b）")
        try service.startPairing()   // 主機本機的手動配對（「詳細」裡）
        // ChatGPT 那邊開始授權（主機的關口會轉進來的同一個呼叫）：確認卡只在主機本機，副設備的狀態裡沒有配對碼。
        let redirect = HandsSettings.defaultCallbacks[0]
        let registered = try service.handle(method: "hands_auth", params: ["op": "register_client", "redirect_uris": [redirect], "client_name": "ChatGPT"])
        let client = registered["client_id"] as? String ?? ""
        _ = try service.handle(method: "hands_auth", params: [
            "op": "authorize_begin", "client_id": client, "redirect_uri": redirect,
            "code_challenge": HandsAuth.challenge(for: HandsAuth.random(bytes: 32)), "code_challenge_method": "S256",
            "state": "s", "resource": "https://hands-fixture.example.com/mcp", "scope": "tatwo.hands"])
        let withCard = try secondaryDispatch.callPrimary(method: "remote_hands_status", payload: [:])
        let pendingCode = service.auth.pendingCard?.pairingCode ?? "NOPE"
        let polledJSON = String(decoding: try JSONSerialization.data(withJSONObject: withCard), as: UTF8.self)
        check(withCard["card"] == nil && !polledJSON.contains(pendingCode) && withCard["window_expires_at"] != nil,
              "副設備 RPC：所有設備輪詢的狀態裡沒有配對碼（W183 R6b；窗口時間照給）")
        // 副設備畫面的舊解碼（到期、太久沒更新就拿掉）照樣驗：用一份合成的舊格式狀態。
        var legacy = withCard
        if let pending = service.auth.pendingCard {
            legacy["card"] = ["transaction": pending.displayCode, "pairing_code": pending.pairingCode, "callback_host": pending.callbackHost,
                              "level": pending.scope.level, "projects": [String](), "memory": pending.scope.memory,
                              "expires_at": ISO8601DateFormatter().string(from: pending.expiresAt), "attempts_left": pending.attemptsLeft]
        }
        let status = HandsRemoteStatus(legacy)
        let card = status?.card
        // 副設備畫面：到期或太久沒從主設備更新（斷線）就不顯示配對碼與窗口。
        if let status, let expires = card?.expiresAt {
            let now = Date()
            check(status.live(at: now).card != nil && status.live(at: expires.addingTimeInterval(1)).card == nil
                  && status.live(at: now.addingTimeInterval(HandsRemoteStatus.freshFor + 1)).card == nil
                  && status.live(at: now.addingTimeInterval(HandsRemoteStatus.freshFor + 1)).windowExpiresAt == nil
                  && status.withoutPairing().card == nil && status.withoutPairing().windowExpiresAt == nil,
                  "副設備畫面：配對碼到期、太久沒更新或連不上就拿掉，不再宣稱窗口開著")
        } else {
            check(false, "副設備畫面：確認卡要帶到期時間")
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: withCard), as: UTF8.self)
        check(!json.contains("tatwoh_") && !json.contains("hash") && !json.contains(handsRoot.path) && !json.contains("code_challenge"),
              "副設備 RPC：沒有 token、雜湊、路徑")
        // 竄改與重放：同一份證明再送一次、改了內容、沒有簽章，都被拒。
        guard let proof = proofs.get().last else { return check(false, "副設備 RPC：拿到證明") }
        var replayRefused = false, tamperRefused = false, unsignedRefused = false
        do { _ = try primaryDispatch.authenticate(method: "remote_hands_status", proof: proof) } catch { replayRefused = true }
        if let body = proof["body"] as? String, var raw = Data(base64Encoded: body) {
            raw.append(contentsOf: Array(" ".utf8))
            var forged = proof; forged["body"] = raw.base64EncodedString()
            do { _ = try primaryDispatch.authenticate(method: "remote_hands_status", proof: forged) } catch { tamperRefused = true }
        }
        do { _ = try primaryDispatch.authenticate(method: "remote_hands_status", proof: [:]) } catch { unsignedRefused = true }
        check(replayRefused && tamperRefused && unsignedRefused, "副設備 RPC：重放、竄改、沒簽章一律拒")
        var badOp = false, badGrant = false
        do { _ = try secondaryDispatch.callPrimary(method: "remote_hands_action", payload: ["op": "enable"]) } catch { badOp = true }
        do { _ = try secondaryDispatch.callPrimary(method: "remote_hands_action", payload: ["op": "revoke_grant", "grant_id": "nope"]) } catch { badGrant = true }
        check(badOp && badGrant, "副設備 RPC：只收白名單動作，撤銷要真的有那筆")
        _ = try secondaryDispatch.callPrimary(method: "remote_hands_action", payload: ["op": "stop_pairing"])
        check(service.auth.windowExpiresAt == nil && service.auth.pendingCard == nil, "副設備 RPC：遠端收掉配對＝窗口與確認卡一起作廢")
        let all = try secondaryDispatch.callPrimary(method: "remote_hands_action", payload: ["op": "revoke_all"])
        check(all["done"] as? String == "revoke_all" && service.auth.activeGrantIDs.isEmpty, "副設備 RPC：遠端全部撤銷")
    }

    /// W183 R8c（GPT-6 必改 1）：沒有「一次只有一台主機」了——每台被勾選的設備自己當自己的主機（設定在主設備的 ChatGPT build）。
    /// 副設備的 claim_host／release_host 一律退役（host_claim_retired）：主設備的開關、主機、配對窗口都不動。
    static func hostHandoffScenario(_ check: Checker, secondaryDispatch: DeviceDispatch, service: HandsService, host: HandsRemote.Host,
                                    primaryID: String, secondaryID: String) throws {
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = primaryID }
        service.auth.openWindow()
        func hostOp(_ op: String, _ extra: [String: Any], expires: TimeInterval = Date().timeIntervalSince1970 + 60, id: String = HandsSetup.randomLabel(16)) -> [String: Any] {
            extra.merging(["op": op, "expires_at": Int(expires), "request_id": id]) { $1 }
        }
        func refused(_ payload: [String: Any], _ reason: String) -> Bool {
            do { _ = try secondaryDispatch.callPrimary(method: "remote_hands_action", payload: payload); return false }
            catch { return String(describing: error).contains(reason) }
        }
        let epochBefore = service.settings.load().hostEpoch ?? 0
        let claim = refused(hostOp("claim_host", ["expected_host": primaryID]), HandsRemote.hostClaimRetired)
        let lateClaim = refused(hostOp("claim_host", ["expected_host": ""]), HandsRemote.hostClaimRetired)
        let bare = refused(["op": "claim_host"], HandsRemote.hostClaimRetired)
        let settings = service.settings.load()
        check(claim && lateClaim && bare && settings.enabled && HandsHostAuthority.same(settings.hostDeviceID, primaryID)
              && service.auth.windowExpiresAt != nil && (settings.hostEpoch ?? 0) == epochBefore,
              "W183 R6a 審查 交接請求（W183 R8c 退役）：副設備的 claim_host 一律不收（host_claim_retired）；主設備照舊開著、配對窗口不關、任期不變")
        let release = refused(hostOp("release_host", ["host_epoch": epochBefore]), HandsRemote.hostClaimRetired)
        let noEpoch = refused(hostOp("release_host", [:]), HandsRemote.hostClaimRetired)
        check(release && noEpoch && HandsHostAuthority.same(service.settings.load().hostDeviceID, primaryID) && service.settings.load().enabled,
              "W183 R6a 審查 交回：不是這一任的（W183 R8c 退役）：release_host 一律不收，主機照舊")
        let status = HandsRemoteStatus(try secondaryDispatch.callPrimary(method: "remote_hands_status", payload: [:]))
        check(status?.primaryIsHost == true && HandsHostAuthority.same(status?.hostDeviceID, primaryID) && status?.card == nil,
              "W183 R8c 每台自己的：副設備看到主設備照舊是它自己的主機（別台要用＝在 ChatGPT build 勾那台）")
        service.auth.closeWindow()
    }

    // MARK: - W183 R3b：副設備的開關與設定（真的設備簽章；主機跑真的標準流程＋假 cloudflared）

    @MainActor static func remoteSetupChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "remote-setup", zoneName: "example.com")
        guard let harness = try remoteHarness(world.root.appendingPathComponent("rpc", isDirectory: true), fixture) else {
            return check(false, "副設備開關：產生測試金鑰")
        }
        let pID = fixture.primaryID, sID = fixture.secondaryID
        let refreshed = HandsLocked(0), unlocks = HandsLocked(0)
        harness.host.set(HandsRemote.Host(service: world.service, phase: { world.phase.get() }, setup: { world.setup.snapshot },
                                          localDeviceID: { pID }, devices: { [pID: "Primary One", sID: "Fixture"] },
                                          serviceChanged: { if !world.service.settings.load().enabled { world.phase.set(.stopped) } },
                                          flow: world.setup, refreshUI: { refreshed.update { $0 += 1 } },
                                          unlockSafety: { incident in
                                              guard incident == "w183uiincident1" else { return false }
                                              unlocks.update { $0 += 1 }
                                              return true
                                          }, safetyIncident: { "w183uiincident1" }))
        let secondary = harness.secondaryDispatch
        // 簽章呼叫一律在背景跑、主執行緒用 await 等：主設備那端讀專案清單會回主執行緒（main.sync），
        // 副設備客戶端的背景查詢也在同一把 RPC 鎖上——主執行緒卡著等鎖就會互等。
        func status() async throws -> [String: Any] { try await offMain { try secondary.callPrimary(method: "remote_hands_status", payload: [:]) } }
        /// W183 R3b 審查：設定動作帶簽章涵蓋的 expires_at；開始、繼續、重新授權、確認帶主機給的 setup_epoch（沒給就先問一次）。
        func act(_ op: String, extra: [String: Any] = [:], epoch: String? = nil, expires: Double? = nil) async throws -> [String: Any] {
            var payload: [String: Any] = ["op": op]
            if HandsRemote.setupOps.contains(op) {
                payload["expires_at"] = expires ?? (Date().timeIntervalSince1970 + 60).rounded()
                if HandsRemote.epochOps.contains(op) {
                    let current = try await status()["setup_epoch"] as? String
                    payload["setup_epoch"] = epoch ?? current ?? ""
                }
            }
            for (key, value) in extra { payload[key] = value }
            let body = payload
            return try await offMain { try secondary.callPrimary(method: "remote_hands_action", payload: body) }
        }
        func refused(_ op: String, _ code: String, extra: [String: Any] = [:], epoch: String? = nil, expires: Double? = nil) async -> Bool {
            do { _ = try await act(op, extra: extra, epoch: epoch, expires: expires); return false } catch { return String(describing: error).contains(code) }
        }
        func stopped() -> Bool { if case .stopped = world.phase.get() { return true }; return false }

        // 1. 主機是別台（第三台）：主設備不開始（那台自己跑）。還沒開：狀態是關的、沒有授權網址。
        _ = try world.service.updateSettings { $0.hostDeviceID = "33333333-3333-4333-8333-333333333333" }
        let elsewhereRefused = await refused("start_setup", HandsHostAuthority.busyReason)
        _ = try world.service.updateSettings { $0.hostDeviceID = nil }
        let before = HandsRemoteStatus(try await status())
        check(elsewhereRefused && before?.enabled == false && before?.loginURL == nil && !world.setup.isBusy && before?.setupEpoch == world.setup.setupEpoch,
              "副設備開關：主機是別台時主設備不開始；還沒開時狀態是關的、沒有授權網址；狀態帶流程世代")

        // 1b. W183 R3b 審查：簽章涵蓋的有效期限與流程世代——過期、沒帶期限、舊的世代一律不收（延遲送達的舊請求不會把主機打開）。
        let expired = await refused("start_setup", HandsRemote.expiredReason, expires: Date().timeIntervalSince1970 - 5)
        let tooFar = await refused("start_setup", HandsRemote.expiredReason, expires: Date().timeIntervalSince1970 + 3600)
        var missing = false
        do { _ = try await offMain { try secondary.callPrimary(method: "remote_hands_action", payload: ["op": "start_setup"]) } }
        catch { missing = String(describing: error).contains(HandsRemote.expiredReason) }
        let oldEpoch = world.setup.setupEpoch
        world.setup.cancel()   // 主機那邊按了取消（或關掉）：世代換掉
        let staleEpoch = await refused("start_setup", HandsRemote.staleEpochReason, epoch: oldEpoch)
        let extraRefused = await refused("start_pairing", "unexpected field", extra: ["expires_at": 1])
        check(expired && tooFar && missing && staleEpoch && extraRefused && !world.service.settings.load().enabled && !world.setup.isBusy,
              "設定動作：過期、期限太遠、沒帶期限、舊的流程世代一律不收（主機維持關著）；非設定動作不收多的欄位")

        // 1c. W183 R3b 審查＋W183 R8c：主機在本機打開開關（沒登入就停在「先登入」）——副設備照代碼顯示「在 ChatGPT build 替那台登入」，
        //     不照抄主機畫面的「到環境登入」，也不叫你按「重新授權」（W183 R8c：遠端的開始、繼續、重新授權不在主機開授權頁）。
        _ = try world.service.updateSettings { $0.enabled = true }
        world.setup.runAll(trigger: .user, allowLogin: false)
        _ = await waitUntil(15) { !world.setup.isBusy && world.status(.authorize).status == .waitingUser }
        let needsLogin = HandsRemoteStatus(try await status())?.setup.first { $0.step == HandsSetupStep.authorize.rawValue }
        check(needsLogin?.code == "authorize.needs_login" && needsLogin?.message == HandsSetup.needsLoginMessage
              && needsLogin?.displayMessage.contains("ChatGPT build") == true && needsLogin?.displayMessage.contains("「重新授權」") == false,
              "副設備：主機停在「先登入」時顯示「在 ChatGPT build 替那台登入 Cloudflare」（不叫你在這台的環境登入另外登入、不叫你按重新授權）",
              needsLogin?.displayMessage ?? "nil")
        _ = try world.service.updateSettings { $0.enabled = false }

        // 2. 副設備按開關（畫面同一個客戶端送 start_setup）：主機的開關跟著開、主機＝主設備、照原本的流程跑到「先登入」就停。
        //    W183 R8c（GPT-6 必改 3）：登入網址不再放進所有設備都輪詢的狀態——遠端的開始不開 cloudflared login、主機不開授權頁、副設備不自動開頁；
        //    替那台登入改走 ChatGPT build（信箱：網址只給按的那台，見 w183build）。
        let client = HandsRemoteClient(dispatch: secondary)
        // W183 R8c 審查：這個客戶端按了開始＝會等主機走到連線那一步出［連線］卡；自測換掉（不碰正式的 HandsConnectFlow.shared／私訊框卡片，
        // 免得後面的敏感頁閘門檢查被這張卡片卡住）。
        let clientOffers = HandsLocked(0)
        client.offerConnect = { clientOffers.update { $0 += 1 } }
        let dm = DMHarness("remote")
        let jumps = JumpCounter()
        defer { jumps.stop() }
        let returned = HandsLocked(0)
        client.returnToSettings = { returned.update { $0 += 1 } }
        client.closeLoginPages = { url in HandsSetup.postCloseLoginPages(only: url) }
        client.openLoginPage = { [weak client] url in
            let owner = client
            return dm.open(url, onCancel: { owner?.cancelFromPage() })   // 跟正式同一條（頁面的「取消」）
        }
        let logins = { world.log("argv.log").split(separator: "\n").filter { $0.hasSuffix(" login") }.count }
        let loginsBefore = logins()
        _ = await waitUntil(10) { client.fetch(force: true); return client.status?.setupEpoch != nil }
        client.act("start_setup")
        let stoppedAtLogin = await waitUntil(25) {
            world.service.settings.load().enabled && !world.setup.isBusy && world.status(.host).status == .done
                && world.status(.authorize).status == .waitingUser
        }
        _ = await waitUntil(10) { client.fetch(force: true); return !client.autoOpenArmed && client.status?.setupBusy == false }
        let startedRaw = try await status()
        let started = world.service.settings.load()
        check(stoppedAtLogin && started.enabled && HandsHostAuthority.same(started.hostDeviceID, pID) && refreshed.get() > 0
              && world.status(.authorize).message == HandsSetup.needsLoginMessage && world.setup.pendingLoginURL == nil && logins() == loginsBefore
              && world.opened.get().isEmpty && startedRaw["login_url"] == nil && dm.loginTab == nil && dm.host.pages.isEmpty
              && !client.awaitingAuthorize && !client.autoOpenArmed && jumps.count.get() == 0 && dm.fallbacks.get().isEmpty && returned.get() == 0,
              "W183 R5b 遠端觸發（W183 R8c 改走信箱）：副設備按開關＝主機開關跟著開、照流程跑到「先登入」就停；不開 cloudflared login、主機不開授權頁、公共狀態沒有授權網址、副設備不自動開頁",
              world.status(.authorize).message)
        // 遠端的「繼續」也一樣停在先登入（取消之後馬上按也不會開授權頁）。
        _ = try await act("cancel_setup")
        _ = try await act("continue_setup")
        _ = await waitUntil(15) { !world.setup.isBusy }
        check(world.status(.authorize).message == HandsSetup.needsLoginMessage && logins() == loginsBefore && world.opened.get().isEmpty
              && dm.host.pages.isEmpty && world.setup.pendingLoginURL == nil,
              "W183 R5b 審查 取消後馬上按「繼續」（W183 R8c）：遠端的繼續照樣停在「先登入」，不開授權頁", world.status(.authorize).message)

        // 3. 替那台登入（信箱那條：HandsBuildExecutor 叫 loginForRemote）：授權網址只交給按的那台（onURL），主機不開；
        //    公共狀態、給 AI 的、步驟訊息、檔案都沒有（canary）。
        let delivered = HandsLocked<[URL]>([]), outcome = HandsLocked<HandsLoginOutcome?>(nil)
        let remoteStarted = world.setup.loginForRemote(requester: sID, onURL: { url in delivered.update { $0.append(url) } },
                                                       onEnd: { result in outcome.set(result) })
        let gotURL = await waitUntil(25) { !delivered.get().isEmpty && world.setup.pendingLoginURL != nil }
        let raw = try await status()
        let aiStatus = try HandsSetupTool.handle(method: "hands_setup_status", params: [:], setup: world.setup)
        let aiStep = try HandsSetupTool.handle(method: "hands_setup_step", params: ["step": "all"], setup: world.setup)   // 忙碌中：只回狀態
        let aiAuthorize = (aiStatus["steps"] as? [[String: Any]])?.first(where: { $0["step"] as? String == "authorize" })?["message"] as? String
        let messages = world.setup.snapshot.steps.values.map(\.message).joined(separator: "\n")
        let loginURL = delivered.get().first
        check(remoteStarted && gotURL && delivered.get().count == 1 && loginURL?.host == "dash.cloudflare.com"
              && (loginURL?.absoluteString.contains(fixture.loginCanary) ?? false) && world.opened.get().isEmpty
              && world.status(.authorize).message == HandsSetup.authorizeWaitingRemoteMessage,
              "W183 R8c 替那台登入：授權網址只交給按的那台（信箱），主機不在自己的畫面開", "\(delivered.get().count)")
        let loginCode = HandsRemoteStatus(raw)?.setup.first { $0.step == "authorize" }?.code
        check(!text(raw).contains(fixture.loginCanary) && raw["login_url"] == nil && Set(raw.keys).isSubset(of: remoteStatusKeys)
              && !text(aiStatus).contains(fixture.loginCanary) && !text(aiStep).contains(fixture.loginCanary) && !text(aiStatus).contains("argotunnel")
              && !messages.contains(fixture.loginCanary) && !world.stateFiles().contains(fixture.loginCanary) && !world.allFilesText().contains(fixture.loginCanary)
              && aiAuthorize == HandsSetup.aiAuthorizeWaiting && aiStatus["user_action"] as? String == HandsSetup.aiAuthorizeWaiting
              && loginCode == "authorize.login_open",
              "授權網址（canary）不在 hands_setup_status／step、步驟訊息、這個世界的任何檔案；W183 R8c 也不在所有設備輪詢的 remote_hands_status；給 AI 的只說「等使用者在瀏覽器按授權」",
              aiAuthorize ?? "nil")
        // 副設備畫面的舊解碼（舊版主機還會給 login_url）：太舊、斷線就拿掉；不是 Cloudflare 授權頁的網址不收。
        if let loginURL, let decoded = HandsRemoteStatus(raw.merging(["login_url": loginURL.absoluteString]) { $1 }) {
            check(decoded.loginURL == loginURL && decoded.live(at: Date().addingTimeInterval(HandsRemoteStatus.freshFor + 1)).loginURL == nil
                  && decoded.withoutPairing().loginURL == nil
                  && HandsRemoteStatus(raw.merging(["login_url": "https://evil.example.org/argotunnel?x=1"]) { $1 })?.loginURL == nil,
                  "副設備（舊版主機相容）：授權網址太舊或斷線就拿掉；不是 Cloudflare 授權頁的網址不收")
        } else {
            check(false, "副設備：解得出主機的狀態")
        }
        // W183 R8c：claim_host 退役（沒有單一主機）；設定流程在跑時也一樣不收。
        var claimRefused = false
        let claimPayload: [String: Any] = ["op": "claim_host", "expires_at": Int(Date().timeIntervalSince1970 + 60), "request_id": HandsSetup.randomLabel(16),
                                           "expected_host": pID]
        do { _ = try await offMain { try secondary.callPrimary(method: "remote_hands_action", payload: claimPayload) } }
        catch { claimRefused = String(describing: error).contains(HandsRemote.hostClaimRetired) }
        check(claimRefused && HandsHostAuthority.same(world.service.settings.load().hostDeviceID, pID) && world.setup.isBusy,
              "W183 R8c claim_host 退役：副設備「改用這台當主機」一律不收（host_claim_retired），主機與進行中的登入照舊")
        world.flag("authorized", true)
        let ended = await waitUntil(40) { outcome.get() != nil && !world.setup.isBusy }
        world.flag("authorized", false)
        let expectedOutcome = HandsLoginOutcome.authorized(account: fixture.accountName, zones: ["example.com"])
        check(ended && outcome.get() == expectedOutcome && world.setup.snapshot.zoneID == nil && world.setup.snapshot.loginZoneID == fixture.zoneID
              && world.status(.authorize).message == HandsSetup.chooseDomainMessage && world.log("creates.log").isEmpty
              && world.setup.pendingLoginURL == nil && world.accounts.account(fixture.accountID)?.selectedDomain == nil,
              "W183 R8c 替那台登入完成：結果（帳號名稱、網域清單）只回按的那台；登入只是登入（沒選網域、沒建通道）",
              "\(String(describing: outcome.get()))")

        // 4. 選網域、按「套用」（別台按的＝.remote，requester＝驗章得到的那台）：這一輪是哪台按的。
        let gate = DispatchSemaphore(value: 0), parked = HandsLocked(false)
        world.checkpointHook.set({ point in
            guard point == "start.beforeWrite" else { return }
            parked.set(true)
            _ = gate.wait(timeout: .now() + 20)
        })
        let applied = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .remote, requester: sID)
        let atStart = await waitUntil(40) { parked.get() }
        let runStatus = HandsRemoteStatus(try await status())
        let otherView = HandsRemote.status(harness.host.get()!, sender: "33333333-3333-4333-8333-333333333333")
        let spoofRefused = await refused("continue_setup", "op", extra: ["requester": sID])
        check(applied && atStart && runStatus?.setupRun != nil && runStatus?.setupRunMine == true && world.setup.runInfo?.requester == sID
              && otherView["setup_run"] as? String == runStatus?.setupRun && otherView["setup_run_mine"] as? Bool == false && spoofRefused,
              "W183 R5b 審查 這一輪是哪台按的：主機用驗章得到的設備記、狀態帶這一輪的編號；別台看到的不是它的；payload 不能指定")
        world.checkpointHook.set(nil)
        gate.signal()
        let finished = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
        check(finished && world.service.settings.load().enabled && world.status(.tunnel).status == .done
              && world.dnsNames() == ["os-for-chatgpt.example.com"] && world.opened.get().isEmpty,
              "W183 R8c 套用（別台按的）：主機用選好的帳號與網域建通道與 DNS、啟動關口，到等配對", world.status(.tunnel).message)

        // 5. 授權後兩台都看得到帳號與網域（同一句）；給 AI 的沒有帳號名稱；授權網址、確認碼不給。
        let authorizedRaw = try await status()
        let authorized = HandsRemoteStatus(authorizedRaw)
        let local = world.setup.authorizedSummary()
        let aiAfter = text(try HandsSetupTool.handle(method: "hands_setup_status", params: [:], setup: world.setup))
        check(authorized?.authorizedAccount == fixture.accountName && authorized?.authorizedDomain == "example.com" && authorized?.canReauthorize == true
              && authorized?.authorizedNeedsConfirm == false && authorized?.confirmToken == nil
              && local?.account == fixture.accountName && local?.domain == "example.com" && authorized?.loginURL == nil
              && !text(authorizedRaw).contains(fixture.loginCanary) && !aiAfter.contains(fixture.accountName),
              "授權後：主機與副設備都顯示「已授權：Cloudflare 帳號〈名稱〉、網域〈網域〉」；給 AI 的狀態沒有帳號名稱")

        // 6. 已經配對：不給「取消並重新授權」（要先撤銷）；副設備看到白話原因。
        world.grant.set(true)
        let pairedRefused = await refused("reauthorize", HandsReauthorizeRefusal.paired.rawValue)
        let pairedStatus = HandsRemoteStatus(try await status())
        world.grant.set(false)
        let plain = HandsHostAuthority.plain(RemoteHostLinkError.remoteError("hands_remote_invalid: " + HandsReauthorizeRefusal.paired.rawValue))
        check(pairedRefused && pairedStatus?.canReauthorize == false && plain == HandsReauthorizeRefusal.paired.description,
              "已經配對：不能在這裡重新授權（副設備看到白話原因）", plain)

        // 7. 副設備按「取消並重新授權」：主機先停下手腳，清掉這次登入拿到的憑證（帳號只有這個網域＝整個移除，含通道 token），
        //    回到第 3 步；W183 R8c：不在主機開授權頁（重新登入走 ChatGPT build 的信箱）；不叫 cloudflared 刪任何通道或 DNS。
        let tunnelsBefore = world.log("creates.log").split(separator: "\n").count
        let argvBefore = world.log("argv.log").count
        _ = try await act("reauthorize")
        let cleared = await waitUntil(25) { !world.setup.isBusy && world.status(.authorize).status == .waitingUser }
        let midStatus = HandsRemoteStatus(try await status())
        let newCommands = String(world.log("argv.log").dropFirst(argvBefore))
        check(cleared && stopped() && world.accounts.snapshot.isEmpty
              && !world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + fixture.zoneID)
              && !world.secrets.contains(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)
              && world.setup.snapshot.tunnelID == nil && world.setup.snapshot.accountID == nil && world.setup.snapshot.discard == nil
              && world.status(.authorize).message == HandsSetup.needsLoginMessage && world.setup.pendingLoginURL == nil
              && midStatus?.loginURL == nil && midStatus?.authorizedAccount == nil && world.opened.get().isEmpty
              && !newCommands.contains(" delete") && !newCommands.contains("cleanup") && !newCommands.contains(" login"),
              "取消並重新授權：先停下關口、清掉這次拿到的憑證與通道 token、回到第 3 步（不在主機開授權頁）；Cloudflare 上的東西不刪", newCommands)
        world.flag("authorized", true)
        let relogged = HandsLocked<HandsLoginOutcome?>(nil)
        _ = world.setup.loginForRemote(requester: sID, onURL: { _ in }, onEnd: { relogged.set($0) })
        let reloggedDone = await waitUntil(40) { relogged.get() != nil && !world.setup.isBusy }
        world.flag("authorized", false)
        let reapplied = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .remote, requester: sID)
        let redone = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
        check(reloggedDone && reapplied && redone && world.service.settings.load().enabled
              && world.log("creates.log").split(separator: "\n").count == tunnelsBefore + 1 && world.accounts.snapshot.count == 1
              && world.secrets.contains(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount),
              "重新授權完成：再登入（信箱）、再按「套用」才照常接續（新通道、開關再打開）", world.status(.start).message)

        // 8. W183 R8c（GPT-6 必改 4）：安全停機鎖只能由使用者對這台明確解除（簽章＋期限）；開始、繼續、輪詢都不解除。
        let unlocksBefore = unlocks.get()
        _ = try await status()
        _ = try await act("continue_setup")
        _ = await waitUntil(15) { !world.setup.isBusy }
        let notUnlocked = unlocks.get() == unlocksBefore
        let expiredUnlock = await refused("unlock_safety", HandsRemote.expiredReason, extra: ["safety_incident": "w183uiincident1"],
                                          expires: Date().timeIntervalSince1970 - 5)
        // W183 R8c 審查（GPT-6 高）：事故編號對不上（晚到的舊解除）、setup_epoch 對不上、沒帶編號＝一律不解除。
        let staleIncident = await refused("unlock_safety", HandsRemote.incidentChangedReason, extra: ["safety_incident": "w183uiincident0"])
        let staleUnlockEpoch = await refused("unlock_safety", HandsRemote.staleEpochReason, extra: ["safety_incident": "w183uiincident1"], epoch: "stale-epoch")
        let noIncident = await refused("unlock_safety", HandsRemote.incidentChangedReason)
        let incidentInStatus = (try await status())["safety_incident"] as? String == "w183uiincident1"
        _ = try await act("unlock_safety", extra: ["safety_incident": "w183uiincident1"])
        check(notUnlocked && expiredUnlock && staleIncident && staleUnlockEpoch && noIncident && incidentInStatus && unlocks.get() == unlocksBefore + 1,
              "W183 R8c 安全鎖：輪詢、繼續都不解除；副設備明確按「解除安全鎖」（簽章＋期限＋setup_epoch＋事故編號）才解除這台；舊編號、舊世代、沒帶都不解除",
              "expired=\(expiredUnlock) incident=\(staleIncident) epoch=\(staleUnlockEpoch) none=\(noIncident) status=\(incidentInStatus)")

        // 9. 副設備關掉開關：主機的開關關掉（撤銷全部 grant）、關口停下；開關關著時「繼續」不會偷偷打開。
        _ = try await act("turn_off")
        let off = HandsRemoteStatus(try await status())
        let continueRefused = await refused("continue_setup", HandsRemote.notEnabledReason)
        check(!world.service.settings.load().enabled && off?.enabled == false && stopped() && continueRefused && !world.setup.isBusy
              && !world.service.settings.load().enabled,
              "副設備關掉開關：主機的開關關掉、關口停下；關著時「繼續」被拒")
    }

    // MARK: - W183 R3b 審查：晚到的取消、多網域的清除、清到一半失敗、磁碟滿、關掉與啟動的競態、真的瀏覽器路徑

    /// 取消發生在查帳號名稱時（cloudflared 已經交回憑證）：不收進鑰匙圈；收進去之後才取消＝這一輪新增的網域與帳號回滾。
    @MainActor static func lateCancelChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "late-cancel", zoneName: "example.com")
        world.lookupHook.set { world.setup.cancel() }
        world.flag("authorized", true)
        world.setup.login(trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy && world.lookedUp.get().count == 1 }
        let first = world.accounts.snapshot.isEmpty && !world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + fixture.zoneID)
            && world.status(.authorize).status == .pending && !world.setup.snapshot.awaitingConfirmation && world.setup.snapshot.loginZoneID == nil
        world.lookupHook.set(nil)
        world.checkpointHook.set { point in if point == "authorize.afterUpsert" { world.setup.cancel() } }
        world.setup.login(trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy && world.lookedUp.get().count == 2 }
        world.checkpointHook.set(nil)
        world.flag("authorized", false)
        let second = world.accounts.snapshot.isEmpty && !world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + fixture.zoneID)
            && world.status(.authorize).status == .pending && world.setup.snapshot.accountID == nil
        check(first && second && world.closedLogin.get() >= 2 && world.leftovers().isEmpty,
              "取消晚到（查帳號名稱時、收進鑰匙圈之後）：不收憑證／回滾這一輪新增的；授權頁關掉、沒有殘留檔",
              "first=\(first) second=\(second) \(world.status(.authorize).message)")
    }

    /// 同一個帳號已有別的網域：這一輪授權另一個網域、建了通道與 token，再「取消並重新授權」＝這一輪的網域授權與 token 刪掉，別的網域留著。
    @MainActor static func multiDomainChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "multi-domain", zoneName: "example.com")
        let otherZone = String(repeating: "d", count: 32)
        try world.accounts.upsert(accountID: fixture.accountID, name: fixture.accountName,
                                  domain: CloudflareDomain(name: "example" + ".net", zoneID: otherZone), cert: fixture.certPEM)
        _ = try world.service.updateSettings { $0.enabled = true }
        world.flag("authorized", true)
        world.setup.login(trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        _ = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .user)   // W183 R8c：選網域、按「套用」
        let ready = await waitUntil(40) { !world.setup.isBusy && world.setup.nextStep == .pairing }
        let tokenOwner = world.setup.snapshot.tokenTunnelID
        let hadToken = world.secrets.contains(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)
        let refusal = world.setup.reauthorize(trigger: .user)
        _ = await waitUntil(25) { world.status(.authorize).status == .waitingUser && world.setup.pendingLoginURL != nil }
        world.setup.cancel()
        _ = await waitUntil(15) { !world.setup.isBusy }
        let account = world.accounts.account(fixture.accountID)
        check(ready && hadToken && tokenOwner != nil && refusal == nil && account?.domains.map(\.zoneID) == [otherZone]
              && !world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + fixture.zoneID)
              && world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + otherZone)
              && !world.secrets.contains(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)
              && world.setup.snapshot.tokenTunnelID == nil && !world.service.settings.load().enabled,
              "多網域帳號重新授權：這一輪的網域授權與通道 token 刪掉、token 對應清掉；同帳號別的網域授權留著；手腳先停",
              "ready=\(ready) token=\(hadToken) domains=\(account?.domains.map(\.zoneID) ?? [])")
    }

    /// 「取消並重新授權」清到一半失敗（鑰匙圈鎖著）：一般的「繼續」不重新採用那個授權、不建通道；可以重按（冪等），清完才重開授權頁。
    @MainActor static func cleanupRetryChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "cleanup-retry", zoneName: "example.com")
        world.flag("authorized", true)
        world.setup.login(trigger: .user)
        _ = await waitUntil(30) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        // W183 R8c：選了這個網域（第 3 步完成；助理叫的不新建網址，所以還沒有通道）。
        try world.setup.chooseDomain(accountID: fixture.accountID, zoneID: fixture.zoneID)
        world.setup.runAll(trigger: .assistant, allowLogin: false)
        _ = await waitUntil(15) { !world.setup.isBusy && world.status(.authorize).status == .done }
        world.secrets.failRemovesForTesting = true
        let firstRefusal = world.setup.reauthorize(trigger: .user)
        _ = await waitUntil(15) { !world.setup.isBusy }
        let failedOnce = world.status(.authorize).status == .failed && world.setup.snapshot.discard != nil
            && world.setup.authorizedSummary()?.cleanupPending == true
        _ = try? world.service.updateSettings { $0.enabled = true }
        world.setup.runAll(trigger: .user, allowLogin: false)
        _ = await waitUntil(15) { !world.setup.isBusy }
        let blocked = world.status(.authorize).status == .failed && world.status(.authorize).message == HandsSetup.cleanupPendingMessage
            && world.log("creates.log").isEmpty && world.status(.tunnel).status != .done
        let retryRefusal = world.setup.reauthorize(trigger: .user)
        _ = await waitUntil(15) { !world.setup.isBusy }
        let stillPending = world.setup.snapshot.discard != nil
        world.secrets.failRemovesForTesting = false
        let finalRefusal = world.setup.reauthorize(trigger: .user)
        let reopened = await waitUntil(25) { world.status(.authorize).status == .waitingUser && world.setup.pendingLoginURL != nil }
        world.setup.cancel()
        _ = await waitUntil(15) { !world.setup.isBusy }
        check(firstRefusal == nil && failedOnce && blocked && retryRefusal == nil && stillPending && finalRefusal == nil && reopened
              && world.setup.snapshot.discard == nil && world.accounts.snapshot.isEmpty
              && !world.secrets.contains(service: CloudflareKeychain.certService, account: "cert:" + fixture.zoneID),
              "清到一半失敗：畫面給「再清一次」、「繼續」不重新採用也不建通道；重按冪等，清完才重開授權頁",
              "failed=\(failedOnce) blocked=\(blocked) pending=\(stillPending) reopened=\(reopened) \(world.status(.authorize).message)")
    }

    /// 真的配對一次（開窗口→ChatGPT 送出→輸入配對碼→換 token）：回 grant id。
    static func pair(_ service: HandsService, resource: String) throws -> String? {
        let redirect = HandsSettings.defaultCallbacks[0]
        let client = try service.handle(method: "hands_auth", params: ["op": "register_client", "redirect_uris": [redirect], "client_name": "ChatGPT"])["client_id"] as? String ?? ""
        try service.startPairing()
        let verifier = HandsAuth.random(bytes: 32)
        let begun = try service.handle(method: "hands_auth", params: [
            "op": "authorize_begin", "client_id": client, "redirect_uri": redirect, "code_challenge": HandsAuth.challenge(for: verifier),
            "code_challenge_method": "S256", "state": "s", "resource": resource, "scope": "tatwo.hands"])
        guard let tx = begun["transaction_id"] as? String, let code = service.auth.pendingCard?.pairingCode else { return nil }
        let submitted = try service.handle(method: "hands_auth", params: ["op": "authorize_submit", "transaction_id": tx, "pairing_code": code,
                                                                         "browser_binding_hash": "sha256:" + String(HandsAuth.hash("w183ui").prefix(32))])
        let tokens = try service.handle(method: "hands_auth", params: ["op": "token", "grant_type": "authorization_code",
                                                                      "code": submitted["authorization_code"] as? String ?? "", "code_verifier": verifier,
                                                                      "client_id": client, "redirect_uri": redirect])
        let access = tokens["access_token"] as? String ?? ""
        return try service.handle(method: "hands_auth", params: ["op": "check", "access_token": access])["grant_id"] as? String
    }

    /// 副設備按關掉、主機的設定檔存不進去（磁碟滿）：主機照樣撤銷全部 grant、關口停下、記憶體強制關閉；回報照實說；之後存得進去才解除。
    @MainActor static func settingsFailureChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "disk-full", zoneName: "example.com")
        let pID = fixture.primaryID
        let publicHost = "hands-fixture.example.com"
        _ = try world.service.updateSettings { $0.enabled = true; $0.hostDeviceID = pID; $0.publicHost = publicHost }
        world.phase.set(.running(url: "https://\(publicHost)/mcp"))
        let host = HandsRemote.Host(service: world.service, phase: { world.phase.get() }, setup: { world.setup.snapshot },
                                    localDeviceID: { pID }, devices: { [pID: "Primary One"] },
                                    serviceChanged: { if !world.service.settings.load().enabled { world.phase.set(.stopped) } },
                                    flow: world.setup)
        let grant = try await offMain { try pair(world.service, resource: "https://\(publicHost)/mcp") }
        let active = grant.map { world.service.auth.activeGrantIDs.contains($0) } ?? false
        world.service.settings.failSavesForTesting = true
        var code = ""
        do { _ = try await offMain { try HandsRemote.setupAction("turn_off", payload: ["expires_at": Date().timeIntervalSince1970 + 60], host: host) } }
        catch { code = String(describing: error) }
        let onDisk = (try? JSONSerialization.jsonObject(with: Data(contentsOf: world.paths.settingsFile)) as? [String: Any])?["enabled"] as? Bool
        let gateway = HandsGatewayLaunch.readSettings(world.paths.settingsFile)?.enabled
        let plain = HandsHostAuthority.plain(RemoteHostLinkError.remoteError(code))
        let stoppedNow: Bool = { if case .stopped = world.phase.get() { return true }; return false }()
        check(active && code.contains(HandsRemote.offNotSavedReason) && onDisk == true && !world.service.settings.load().enabled && gateway == false
              && world.service.auth.activeGrantIDs.isEmpty && stoppedNow && world.service.settings.forcedOff
              && plain.contains("設定存不進去") && !plain.contains("主機已經關了，但撤銷紀錄"),
              "關掉時設定存不進去：有效的 grant 照樣撤銷、關口停下、記憶體強制關閉（關口讀到也是關）；回報照實說",
              "code=\(code) disk=\(String(describing: onDisk)) gateway=\(String(describing: gateway)) \(plain)")
        world.service.settings.failSavesForTesting = false
        _ = try world.service.updateSettings { $0.level = 1 }
        let persisted = (try? JSONSerialization.jsonObject(with: Data(contentsOf: world.paths.settingsFile)) as? [String: Any])?["enabled"] as? Bool
        check(persisted == false && !world.service.settings.forcedOff && !world.service.settings.load().enabled,
              "之後存得進去：檔案寫成關的，才解除記憶體強制關閉")
    }

    /// 關掉與啟動的競態：舊流程已經過了取消檢查、正要寫「打開」時，副設備送來關掉——最後一定是關的；主機剛換成別台也不寫。
    @MainActor static func raceChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let world = try World(fixture, folder: "race", zoneName: "example.com")
        let pID = fixture.primaryID, sID = fixture.secondaryID
        let host = HandsRemote.Host(service: world.service, phase: { world.phase.get() }, setup: { world.setup.snapshot },
                                    localDeviceID: { pID }, devices: { [pID: "Primary One", sID: "Fixture"] },
                                    serviceChanged: { if !world.service.settings.load().enabled { world.phase.set(.stopped) } },
                                    flow: world.setup)
        _ = try world.service.updateSettings { $0.enabled = true }
        world.flag("authorized", true)
        world.setup.runAll(trigger: .user, allowLogin: true)
        _ = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        let fired = HandsLocked(0)
        let turnOffError = HandsLocked<String?>(nil)
        world.checkpointHook.set { point in
            guard point == "start.beforeWrite", fired.get() == 0 else { return }
            fired.update { $0 += 1 }
            do { _ = try HandsRemote.setupAction("turn_off", payload: ["expires_at": Date().timeIntervalSince1970 + 60], host: host) }
            catch { turnOffError.set(String(describing: error)) }
        }
        _ = world.setup.applyURLs(accountID: fixture.accountID, zoneID: fixture.zoneID, trigger: .user)   // W183 R8c：按「套用」
        _ = await waitUntil(40) { !world.setup.isBusy && fired.get() == 1 }
        _ = await waitUntil(5) { !world.setup.isBusy }
        let settled: Bool = { if case .stopped = world.phase.get() { return true }; return false }()
        check(fired.get() == 1 && turnOffError.get() == nil && !world.service.settings.load().enabled && world.status(.start).status != .done && settled,
              "競態：舊流程正要寫「打開」時送來關掉（先取消、再關）——舊流程在鎖裡看到已取消就不寫，最後是關的",
              "\(world.status(.start).status) \(world.status(.start).message)")
        // 主機剛被別台接走（交接跟第 5 步擦身而過）：第 5 步不把主機寫回自己、不打開。
        world.checkpointHook.set { point in
            if point == "start.beforeWrite" { _ = try? world.service.updateSettings { $0.hostDeviceID = sID } }
        }
        world.setup.run(.start, trigger: .user)
        _ = await waitUntil(15) { !world.setup.isBusy }
        world.checkpointHook.set(nil)
        let settings = world.service.settings.load()
        check(world.status(.start).status == .failed && world.status(.start).message.contains("主機剛換成別台") && !settings.enabled
              && HandsHostAuthority.same(settings.hostDeviceID, sID),
              "第 5 步寫設定前再核主機：主機剛換成別台就不寫、不打開（一次只有一台主機）", world.status(.start).message)
    }

    /// 真的瀏覽器路徑（隔離的佇列、分頁登記、分頁還原檔、瀏覽紀錄）：授權網址開成敏感分頁——tabs.json、最近關閉、空間封存、
    /// 瀏覽紀錄都沒有它；授權頁轉址後（網址被編碼）也一樣；流程結束的通知把它關掉。一般網址照舊保存（對照）。
    @MainActor static func browserPathChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let dir = fixture.base.appendingPathComponent("browser", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registryURL = dir.appendingPathComponent("tabs.json"), settingsURL = dir.appendingPathComponent("settings.json")
        let registry = BrowserTabRegistry(storageURL: registryURL)
        let store = BrowserWorkSpaceStore(registry: registry)
        let queue = BrowserExternalURLQueue(notifications: NotificationCenter())
        let lifecycle = BrowserWorkSpaceLifecycle(store: store, registry: registry, queue: queue, settingsURL: settingsURL)
        let history = BrowserHistoryStore(storageURL: dir.appendingPathComponent("history.json"))
        let canary = "W183UIBROWSER" + String(fixture.loginCanary.suffix(16))
        guard let login = HandsCloudflared.loginURL(in: loginLine(canary)),
              let normal = URL(string: "https://example.com/normal-page") else { return check(false, "瀏覽器路徑：授權網址") }
        let second = registry.addSpace(name: "第二")
        HandsSetup.openInOSBrowser(login, queue: queue, present: false)
        _ = queue.enqueue([normal])
        try lifecycle.consumePendingURLs()
        guard let sensitive = registry.tabs.first(where: { $0.url == login }) else { return check(false, "瀏覽器路徑：授權頁開成分頁") }
        // 登入頁轉址：網址裡的 callback 被編碼一層。
        let redirected = URL(string: "https://dash.cloudflare.com/login?redirect_uri=" + (login.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!
        registry.update(sensitive.id, url: redirected, title: "Cloudflare", favicon: nil)
        registry.move(sensitive.id, to: .workSpace(spaceID: second.id))
        try registry.flush()
        try await history.recordVisit(url: redirected, title: "Cloudflare")
        try await history.recordVisit(url: normal, title: "Normal")
        let visits = try await history.entries().map(\.url)
        func onDisk() -> String {
            var out = ""
            let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL { if let data = try? Data(contentsOf: url) { out += String(decoding: data, as: UTF8.self) } }
            return out
        }
        let afterOpen = onDisk()
        check(registry.isSensitive(sensitive.id) && !afterOpen.contains(canary) && afterOpen.contains("normal-page")
              && visits == [normal] && BrowserHistoryStore.isExcluded(redirected),
              "授權頁（真的佇列→分頁登記→存檔）：敏感分頁只在記憶體，轉址後也不進 tabs.json 與瀏覽紀錄；一般網址照舊保存（對照）")
        let archived = registry.archiveAndRemoveSpace(second.id)   // 授權頁那一頁就在這個空間
        let archiveText = archived.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        HandsSetup.openInOSBrowser(login, queue: queue, present: false)
        try lifecycle.consumePendingURLs()
        if let again = registry.tabs.first(where: { $0.url == login }) { registry.close(again.id) }
        let reopenedTab = registry.reopenClosedTab()
        check(archived != nil && !archiveText.contains(canary) && registry.recentlyClosed.allSatisfy { !($0.url?.absoluteString.contains(canary) ?? false) }
              && !(reopenedTab?.url?.absoluteString.contains(canary) ?? false),
              "空間封存、最近關閉（重新打開關掉的分頁）都沒有授權頁")
        // 流程結束：關掉敏感分頁（通知；主執行緒上處理）。
        HandsSetup.openInOSBrowser(login, queue: queue, present: false)
        try lifecycle.consumePendingURLs()
        let openAgain = registry.tabs.contains { $0.url == login }
        HandsSetup.postCloseLoginPages()
        let closed = await waitUntil(5) { !registry.tabs.contains { $0.url == login } }
        try registry.flush()
        check(openAgain && closed && registry.recentlyClosed.allSatisfy { $0.url != login } && !onDisk().contains(canary),
              "流程結束：授權頁（敏感分頁）關掉、不記進最近關閉；磁碟上從頭到尾沒有授權網址")
    }

    // MARK: - W183 R5b／R8b：授權頁在私訊框裡開（R8b：第三顆圓鈕 Browser 的分頁；手機式瀏覽器）

    /// 假頁面（正式＝CEF 的 human 頁面）：記下起點網址、收回次數、上一頁／下一頁次數；頁面本身接得了鍵盤（像 CEF 的原生子元件）。
    @MainActor final class FakePage: GlobalDMWebPage {
        final class KeyView: NSView { override var acceptsFirstResponder: Bool { true } }
        let view: NSView = KeyView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let url: URL
        var closes = 0
        var backs = 0
        var forwards = 0
        /// W184 G2d：原生重新載入的次數（重新載入不關頁、不重開）。
        var reloads = 0
        /// 頁面回報狀態（載入、實際載入的網址、疊了幾層、上一頁／下一頁）。
        var report: (@MainActor (GlobalDMWebPageState) -> Void)?
        init(url: URL) { self.url = url }
        var isHumanActor: Bool { true }
        func back() { backs += 1 }
        func goBack() { backs += 1 }
        func goForward() { forwards += 1 }
        func reload() { reloads += 1 }
        func close() { closes += 1; view.removeFromSuperview() }
    }

    /// 假頁面宿主（CEF 在自測裡起不來；頁面宿主是可替換的介面）。failure＝頁面打不開。
    @MainActor final class FakePageHost: GlobalDMWebPageHosting {
        var pages: [FakePage] = []
        var failure: Error?
        func openPage(url: URL, onState: @escaping @MainActor (GlobalDMWebPageState) -> Void) async throws -> any GlobalDMWebPage {
            if let failure { throw failure }
            let page = FakePage(url: url)
            page.report = onState
            pages.append(page)
            onState(GlobalDMWebPageState(loading: false, error: nil, committedURL: url, stacked: 0))
            return page
        }
    }

    /// 一個私訊框（隔離的 store、無頭的面板控制器：主視窗看不到＝開浮動框）＋假頁面宿主＋它自己的 Browser；退回舊路只記下來。
    /// surface＝框裡放頁面的那個容器（正式由 SwiftUI 的 DMBrowserPageSurface 叫 claim；無頭自測自己叫）。
    @MainActor final class DMHarness {
        let store: GlobalDMStore
        let panels: GlobalDMPanelController
        let host: FakePageHost
        let browser: DMBrowser
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 466, height: 678))
        let fallbacks = HandsLocked<[URL]>([])

        init(_ name: String) {
            let defaults = UserDefaults(suiteName: "w183ui.dm.\(name).\(UUID().uuidString)") ?? .standard
            let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false }, directKeys: false)
            let panels = GlobalDMPanelController(store: store, hostsWindows: false)
            let host = FakePageHost()
            self.store = store
            self.panels = panels
            self.host = host
            browser = DMBrowser(store: store, openBox: { panels.open() }, pageHost: host, podPage: { nil })
            browser.claim(surface)
        }

        /// Browser 的 Cloudflare 授權分頁。
        var loginTab: DMBrowserTabInfo? { browser.tab(for: .cloudflareLogin) }
        /// 授權分頁的頁面開好了。
        var loginPageReady: Bool { loginTab.map { browser.page(for: $0.id) != nil } ?? false }

        /// 跟正式同一條（HandsSetup.openLoginPage），只把私訊框的 Browser 與退路換成這裡的。
        @discardableResult
        func open(_ url: URL, onCancel: @escaping @MainActor () -> Void) -> Bool {
            let fallbacks = self.fallbacks
            return HandsSetup.openLoginPage(url, onCancel: onCancel, browser: browser, fallback: { url, _ in fallbacks.update { $0.append(url) } })
        }

        /// 使用者在分頁清單按 ×（還沒完成＝一起取消這一輪；完成的只關）。
        func closeLoginTab() {
            if let tab = loginTab { browser.userClose(tab.id) }
        }

        /// 收尾：這個私訊框的分頁全關、框收起來（後面的 Computer Use 檢查不受這裡影響）。
        func finish() {
            browser.closeAll()
            store.close()
        }
    }

    /// 數「關設定浮層」「切到 Work OS 視窗（Browser）」「設定換頁」的通知：私訊框的路一次都不該有。
    /// W183 R5b 審查（Claude）：加上換頁（.tatwoOpenSettingsSection：HandsSetup.open、EnvironmentLoginTab.open 都發這個）。
    final class JumpCounter {
        let count = HandsLocked(0)
        private var observers: [NSObjectProtocol] = []
        init() {
            for name in [Notification.Name.tatwoCloseSettingsPage, .tatwoOpenWorkOSWindow, .tatwoOpenSettingsSection] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [count] _ in count.update { $0 += 1 } })
            }
        }
        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
    }

    /// 主機本機觸發（環境登入 › 用瀏覽器登入）：私訊框自動打開、切到 Browser、授權分頁在最前面（起點是 Cloudflare 授權網址）、
    /// 不切 OS 的 Browser 工作區、不關設定；授權完成＝分頁標「完成」、不自己消失（使用者自己關）；還沒完成時關掉＝取消這一輪；
    /// 逾時＝流程結束時關掉；頁面打不開＝寫原因、給退路；只收驗過的網址；私訊鈕關掉才退回舊路；磁碟上沒有授權網址。
    @MainActor static func dmSheetChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let dm = DMHarness("local")
        let jumps = JumpCounter()
        defer { jumps.stop() }
        let cancels = HandsLocked(0)
        let flow = HandsLocked<HandsSetup?>(nil)
        // W183 R5b 審查：流程在主執行緒上核對「這一輪還有效」之後才叫 openURL（同一個主執行緒回合裡開）。
        let world = try World(fixture, folder: "dm-sheet", zoneName: "example.com", openURL: { url in
            let open = { MainActor.assumeIsolated { _ = dm.open(url, onCancel: { cancels.update { $0 += 1 }; flow.get()?.cancel() }) } }
            if Thread.isMainThread { open() } else { DispatchQueue.main.async(execute: open) }
        }, postsClose: true)
        flow.set(world.setup)

        // A. 主機本機觸發：拿到網址就在這台私訊框的 Browser 開（分頁在最前面）。
        // W183 R5b 審查（Claude）：跟正式的「用瀏覽器登入」一樣先記「授權完帶回環境登入」——開在私訊框就清掉、不換頁。
        let closedAtStart = !dm.store.isPresented && dm.loginTab == nil && !dm.store.isBrowsing
        HandsSetup.returnAfterAuthorize = .environmentLogin
        world.setup.login(trigger: .user)
        let shown = await waitUntil(25) { dm.loginTab != nil && dm.loginPageReady }
        let returnCleared = HandsSetup.returnAfterAuthorize == nil
        let login = world.setup.pendingLoginURL
        let tab = dm.loginTab
        check(closedAtStart && shown && login != nil && tab?.startURL == login && login.map { HandsCloudflared.loginURL(in: $0.absoluteString) == $0 } == true
              && tab?.title == "Cloudflare" && tab?.displayHost == "dash.cloudflare.com" && tab?.kind == .web && tab?.hostMismatch == false
              && dm.store.isFloatingOpen && dm.store.isBrowsing && dm.browser.activeID == tab?.id
              && dm.host.pages.map(\.url) == [login].compactMap { $0 } && dm.host.pages.first?.view.superview === dm.surface
              && world.status(.authorize).message == HandsSetup.authorizeWaitingMessage,
              "W183 R8b 主機本機觸發：拿到網址就在這台的私訊框自動打開（原本關著）、切到 Browser、授權分頁在最前面；起點是 Cloudflare 授權網址，網址 pill 是 dash.cloudflare.com",
              "tab=\(tab?.displayHost ?? "nil") floating=\(dm.store.isFloatingOpen) browsing=\(dm.store.isBrowsing)")
        check(jumps.count.get() == 0 && dm.fallbacks.get().isEmpty && !BrowserExternalURLQueue.shared.hasPendingURLs
              && login.map(BrowserHistoryStore.isExcluded) == true && returnCleared,
              "私訊框的路：不關設定浮層、不切 OS 的 Browser 工作區、不換設定頁（「授權完帶回哪一頁」清掉）、不開 OS 瀏覽器分頁；授權網址不進瀏覽紀錄",
              "jumps=\(jumps.count.get()) returnCleared=\(returnCleared)")
        let page = dm.host.pages.first

        // B. 授權完成（W183 R8c：登入只是登入，停在「選網域、按套用」）：分頁標「完成」、不自己消失（分頁與私訊框留著）；設定頁不關、不換頁。
        //    W183 R8b 審查（GPT-6、Claude）：cloudflared 一結束頁面先撤下（分頁寫「確認中」）；授權檔驗過、存進鑰匙圈才標「完成」；
        //    完成＝頁面關掉（不留可以操作的登入頁、不再算敏感）。
        world.flag("authorized", true)
        let confirming = await waitUntil(40) { !world.setup.isBusy && world.status(.authorize).message == HandsSetup.chooseDomainMessage }
        world.flag("authorized", false)
        let markedDone = await waitUntil(5) { dm.loginTab?.done == true }
        try? await Task.sleep(nanoseconds: 300_000_000)   // 步驟結束的收尾（帶回哪一頁）在主執行緒上跑完
        check(confirming && markedDone && dm.loginTab != nil && dm.loginTab?.pageClosed == true && page?.closes == 1 && page?.view.superview == nil
              && dm.store.isPresented && dm.store.isBrowsing && cancels.get() == 0 && !dm.browser.isSensitive
              && jumps.count.get() == 0 && HandsSetup.returnAfterAuthorize == nil && world.closedLogin.get() >= 2,
              "W183 R8b 授權完成：Browser 的授權分頁標「完成」、不自己消失（分頁留著、私訊框還開著；頁面關掉、不再算敏感）；設定頁不關、不換頁（停在原處看得到「選網域、按套用」）",
              "done=\(markedDone) closes=\(page?.closes ?? -1) jumps=\(jumps.count.get()) \(world.status(.authorize).message)")
        // B2. 使用者自己關掉完成的分頁：不取消任何東西；分頁全沒了＝私訊框回原狀（原本關著、回到對話）。
        dm.closeLoginTab()
        check(dm.loginTab == nil && page?.closes == 1 && cancels.get() == 0 && !dm.store.isPresented && !dm.store.isBrowsing
              && world.status(.authorize).message == HandsSetup.chooseDomainMessage,
              "W183 R8b 使用者關掉完成的分頁：頁面銷毀、不取消這一輪（W183 R8c：照樣停在「選網域、按套用」）；分頁全沒了＝私訊框回原狀")

        // C. 還沒完成時關掉分頁＝取消這一輪：頁面馬上銷毀；私訊框回原本的樣子（原本開著停靠框＝回停靠框、回對話）。
        dm.store.isOpen = true
        world.setup.login(trigger: .user)
        let shownAgain = await waitUntil(25) { dm.loginTab != nil && dm.host.pages.count == 2 && dm.loginPageReady }
        let floatedWhileShown = dm.store.isFloatingOpen && !dm.store.isOpen && dm.store.isBrowsing   // 主視窗看不到（無頭）＝浮動框
        dm.closeLoginTab()
        let immediate = dm.loginTab == nil && dm.host.pages.last?.closes == 1 && dm.store.isOpen && !dm.store.isFloatingOpen && !dm.store.isBrowsing
        let cancelledFlow = await waitUntil(20) { !world.setup.isBusy && world.status(.authorize).status != .waitingUser }
        check(shownAgain && floatedWhileShown && immediate && cancelledFlow && cancels.get() == 1 && world.setup.pendingLoginURL == nil,
              "W183 R8b 還沒完成時關掉授權分頁＝取消這一輪：頁面馬上銷毀；私訊框回原本的樣子（原本開著停靠框＝回停靠框、回對話）",
              world.status(.authorize).message)
        dm.store.isOpen = false

        // D. 逾時：授權等太久，流程結束時由流程關掉授權分頁（頁面銷毀、私訊框收回）。
        let quickDM = DMHarness("timeout")
        let quick = try World(fixture, folder: "dm-sheet-timeout", zoneName: "example.com", openURL: { url in
            let open = { MainActor.assumeIsolated { _ = quickDM.open(url, onCancel: {}) } }
            if Thread.isMainThread { open() } else { DispatchQueue.main.async(execute: open) }
        }, postsClose: true, loginTimeout: 2)
        quick.setup.login(trigger: .user)
        let up = await waitUntil(20) { quickDM.loginTab != nil }
        let timedOut = await waitUntil(30) { !quick.setup.isBusy && quick.status(.authorize).status == .failed }
        let gone = await waitUntil(5) { quickDM.loginTab == nil }
        check(up && timedOut && gone && !quickDM.store.isPresented && quickDM.host.pages.first?.closes == 1 && quick.status(.authorize).message.contains("太久"),
              "W183 R8b 逾時：流程結束時由流程關掉授權分頁（頁面銷毀、私訊框收回）", quick.status(.authorize).message)
        quickDM.finish()

        // E. 頁面打不開：分頁上寫原因、給「改在 OS 瀏覽器開」（使用者按了才走舊路）。
        let failLogin = URL(string: loginLine("W183UIFAILPAGE0000"))!
        dm.host.failure = BrowserSensitivePageError.unavailable
        dm.open(failLogin, onCancel: {})
        let failed = await waitUntil(5) { dm.loginTab?.problem != nil }
        let problem = dm.loginTab?.problem ?? ""
        dm.browser.openElsewhere()
        check(failed && problem.contains(BrowserSensitivePageError.unavailable.description) && dm.loginTab == nil
              && dm.fallbacks.get() == [failLogin] && !dm.store.isPresented,
              "頁面打不開：分頁上寫白話原因、按「改在 OS 瀏覽器開」才走舊路（分頁先關）", problem)
        dm.host.failure = nil

        // F. 只收驗過的 Cloudflare 授權網址；Pod、配對頁不能用網址開；私訊鈕總開關關著才退回舊路。
        let evil = URL(string: "https://evil.example.org/argotunnel?x=1")!
        let refusedEvil = !dm.open(evil, onCancel: {}) && dm.loginTab == nil && dm.fallbacks.get().count == 1
            && GlobalDMWebSheet.cloudflareAuthorization(evil) == nil
            && GlobalDMWebSheet.cloudflareAuthorization(URL(string: "https://dash.cloudflare.com:8443/argotunnel")!) == nil
            && GlobalDMWebSheet.cloudflareAuthorization(URL(string: "http://dash.cloudflare.com/argotunnel")!) == nil
            && !dm.browser.open(url: evil, purpose: .cloudflareLogin)
            && !dm.browser.open(url: failLogin, purpose: .chatgptDeveloper) && !dm.browser.open(url: failLogin, purpose: .chatgptPairing)
            && dm.browser.tabs.isEmpty
        dm.store.isEnabled = false
        let usedFallback = !dm.open(failLogin, onCancel: {}) && dm.loginTab == nil && dm.fallbacks.get().count == 2
        dm.store.isEnabled = true
        check(refusedEvil && usedFallback && dm.host.pages.count == 2,
              "只收 HandsCloudflared.loginURL 驗過的 Cloudflare 授權網址當起點；Pod、配對頁不能用網址開；私訊鈕總開關關著才退回舊路（OS 瀏覽器分頁）")

        // G. 敏感：授權網址（canary）不在任何檔案（這個世界、staging 的 HOME：瀏覽紀錄、tabs.json、偏好設定都在那裡）。
        var home = ""
        let enumerator = FileManager.default.enumerator(at: fixture.fakeHome, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) <= 4 * 1024 * 1024 else { continue }
            if let data = try? Data(contentsOf: url) { home += String(decoding: data, as: UTF8.self) }
        }
        check(!home.contains(fixture.loginCanary) && !world.allFilesText().contains(fixture.loginCanary) && !quick.allFilesText().contains(fixture.loginCanary),
              "敏感：授權網址不進瀏覽紀錄、tabs.json、偏好設定或任何檔案（磁碟上從頭到尾沒有）")
        dm.finish()
    }

    /// W183 R8b：分頁不會自己消失（取代 R5b 的「沒有看得到的框接手＝銷毀」）、鍵盤給頁面、網址 pill 顯示實際的網域、
    /// Computer Use 碰不到、授權時不給擷取、設定浮層開著時私訊框用浮動框（浮在上面）。
    @MainActor static func dmHostingChecks(_ check: Checker) async {
        let dm = DMHarness("hosting")
        func open(_ key: String) async -> FakePage? {
            guard let url = URL(string: loginLine(key)) else { return nil }
            dm.browser.open(url: url, purpose: .cloudflareLogin)
            _ = await waitUntil(5) { dm.loginPageReady && dm.loginTab?.startURL == url }
            return dm.host.pages.last
        }

        // 1. 框換了（停靠↔浮動）頁面跟著搬；框全收起來＝頁面從畫面拿下來（不掛在任何視窗），分頁留著、不銷毀、沒有時限；框回來就放回去。
        let page = await open("W183UIHOSTING")
        let docked = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400)), floating = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        dm.browser.claim(docked)
        dm.browser.claim(floating)
        let inLatest = page?.view.superview === floating
        dm.browser.release(floating)
        let backToDocked = page?.view.superview === docked
        dm.browser.release(docked)
        dm.browser.release(dm.surface)
        let detached = page?.view.superview == nil && page?.closes == 0 && dm.loginTab != nil
        try? await Task.sleep(nanoseconds: 1_800_000_000)   // 比 R5b 的交接時限（1.5 秒）還久
        let stillThere = page?.closes == 0 && dm.loginTab != nil
        dm.browser.claim(floating)
        let tookOver = page?.view.superview === floating
        check(page != nil && inLatest && backToDocked && detached && stillThere && tookOver,
              "W183 R8b 分頁不會自己消失：框換了頁面跟著搬；框全收起來＝頁面拿下來（不掛在任何視窗）但分頁留著、不銷毀；框回來就放回去",
              "latest=\(inLatest) docked=\(backToDocked) detached=\(detached) still=\(stillThere) back=\(tookOver)")
        dm.browser.release(floating)
        dm.browser.claim(dm.surface)

        // 2. 明確關框、主視窗收起來、切到對話對象：分頁都留著；私訊鈕總開關關掉＝全部馬上關（沿用 R5b）。
        dm.store.close()
        let keptAfterClose = dm.loginTab != nil && page?.closes == 0
        dm.store.isOpen = true
        dm.store.isDockedVisible = false
        let keptHidden = dm.loginTab != nil && page?.closes == 0
        dm.store.isOpen = false
        dm.store.select(.assistant)
        let keptOther = dm.loginTab != nil && !dm.store.isBrowsing && page?.closes == 0
        dm.store.isEnabled = false
        let disabledNow = await waitUntil(0.5) { dm.browser.tabs.isEmpty }
        dm.store.isEnabled = true
        check(keptAfterClose && keptHidden && keptOther && disabledNow && page?.closes == 1,
              "W183 R8b 關框、主視窗收起來、切到對話：分頁都留著；私訊鈕總開關關掉＝全部馬上關",
              "close=\(keptAfterClose) hidden=\(keptHidden) other=\(keptOther) disabled=\(disabledNow)")

        // 3. 鍵盤：分頁出現時鍵盤在頁面（不是別的輸入列）；錄鍵頁、對象清單收起；Browser 開著時 Enter 不會把草稿送出。
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 466, height: 678), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 466, height: 678))
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 466, height: 40))
        let box = NSView(frame: NSRect(x: 0, y: 40, width: 466, height: 600))
        content.addSubview(composer)
        content.addSubview(box)
        window.contentView = content
        window.makeFirstResponder(composer)
        let composerHadKeys = window.firstResponder === composer
        dm.store.isPickerOpen = true
        dm.store.isEditingDirectKeys = true
        dm.browser.claim(box)
        let fifth = await open("W183UIKEYS")
        let pageHasKeys = fifth.map { window.firstResponder === $0.view } ?? false
        dm.store.setDraft("W183UIDRAFT", for: dm.store.target)
        let refusedSend = !dm.store.send() && dm.store.draft(for: dm.store.target) == "W183UIDRAFT"
        check(composerHadKeys && pageHasKeys && !dm.store.isPickerOpen && !dm.store.isEditingDirectKeys && dm.store.isBrowsing && refusedSend,
              "W183 R8b 鍵盤：分頁出現時鍵盤在頁面（不是別的輸入列）；錄鍵頁、對象清單收起；Browser 開著時 Enter 不會把草稿送出",
              "page=\(pageHasKeys) picker=\(dm.store.isPickerOpen) keys=\(dm.store.isEditingDirectKeys) send=\(refusedSend)")
        dm.store.setDraft("", for: dm.store.target)

        // 4. 網址 pill：網域照實際載入的網址；導到別的網域＝標「不是 cloudflare.com」；不是 https＝標出來；上一頁（疊了新視窗＝收那一層）、下一頁。
        fifth?.report?(GlobalDMWebPageState(loading: false, error: nil, committedURL: URL(string: "https://accounts.example.org/signin"), stacked: 1))
        let pill = dm.loginTab
        dm.browser.goBack()
        let backed = fifth?.backs == 1
        fifth?.report?(GlobalDMWebPageState(loading: false, error: nil, committedURL: URL(string: "http://dash.cloudflare.com/x"), stacked: 0,
                                            canGoBack: false, canGoForward: true))
        let insecure = dm.loginTab?.isInsecure == true && dm.loginTab?.hostMismatch == false && dm.loginTab?.canGoForward == true
            && dm.loginTab?.canGoBack == false
        dm.browser.goForward()
        // W183 R8b 審查（GPT-6）：頁面回報沒有實際網址（空白頁、還沒提交）＝尚未確認來源（不拿起點或 cloudflare.com 頂替、不給鎖頭）。
        fifth?.report?(GlobalDMWebPageState(loading: true, error: nil, committedURL: nil, stacked: 0))
        let unknown = dm.loginTab?.sourceKnown == false && dm.loginTab?.displayHost == "" && dm.loginTab?.sourceText == "尚未確認來源"
            && dm.loginTab?.hostMismatch == false && dm.loginTab.map { DMBrowserAddressPill.symbol($0, warn: false) } == "questionmark.circle"
        check(unknown, "W183 R8b 審查 網址 pill：頁面還沒有實際網址＝「尚未確認來源」，不拿起點或該在的網域頂替、不給鎖頭")
        check(pill?.displayHost == "accounts.example.org" && pill?.hostMismatch == true && pill?.expectedHost == "cloudflare.com" && pill?.canGoBack == true
              && pill?.stacked == 1 && backed && insecure && fifth?.forwards == 1
              && DMBrowserAddressPill.label(host: "accounts.example.org", mismatch: "cloudflare.com", insecure: false).contains("不是 cloudflare.com")
              && GlobalDMWebSheet.isSecure(URL(string: "https://dash.cloudflare.com/")!) && !GlobalDMWebSheet.isSecure(URL(string: "http://dash.cloudflare.com/")!)
              && GlobalDMWebPageState.committed("about:blank") == nil && GlobalDMWebPageState.committed("https://x.example.org:8443/a").map(GlobalDMWebSheet.displayHost) == "x.example.org:8443",
              "W183 R8b 網址 pill：網域照看得到的那一頁實際載入的網址；導到別的網域標「不是 cloudflare.com」、不是 https 標出來；上一頁（疊了新視窗＝收掉那一層）、下一頁",
              pill?.displayHost ?? "nil")

        // 5. Computer Use：Browser 有分頁＝以 TATWO 自己為目標的操作一律拒絕（截圖、讀 AX、輸入前都看）；全部關掉就恢復。
        let own = ProcessInfo.processInfo.processIdentifier
        let blockedSelf = BrowserSensitivePageGate.isActive
            && ComputerUseController.refusesSelf(pid: own, lane: .externalApplication, sensitivePageOpen: BrowserSensitivePageGate.isActive)
            && !ComputerUseController.refusesSelf(pid: own &+ 1, lane: .externalApplication, sensitivePageOpen: true)
            && !ComputerUseController.refusesSelf(pid: own, lane: .builtInBrowser, sensitivePageOpen: true)
            && ComputerUseController.isSelf(ComputerUseTarget(bundleIdentifier: "ai.tatwo.tatwo2"))
            && ComputerUseController.preDispatchCodes.contains(ComputerUseController.sensitivePageCode)
        dm.browser.markDone(purpose: .cloudflareLogin)
        // W183 R8b 審查（GPT-6、Claude）：完成＝頁面關掉，不再有登入中的網頁，Computer Use 不再被這個分頁擋（分頁留著）。
        let releasedWhenDone = !BrowserSensitivePageGate.isActive && dm.loginTab?.done == true
        let gateDetail = "gate=\(BrowserSensitivePageGate.isActive) mine=\(dm.browser.isSensitive) tabs=\(dm.browser.tabs.map { "\($0.purpose.rawValue):\($0.done):\($0.pageClosed)" })"
            + " card=\(HandsConnectPresenter.anySensitive) os=\(!BrowserTabRegistry.withSensitiveTabs.isEmpty)"
        dm.finish()
        let released = !BrowserSensitivePageGate.isActive
        check(blockedSelf && releasedWhenDone && released,
              "W183 R8b Computer Use：Browser 有還開著的授權頁時不准以 TATWO 自己為目標（內建瀏覽器那條、別的 App 不受影響）；完成（頁面關掉）或全部關掉就恢復",
              "blocked=\(blockedSelf) done=\(releasedWhenDone) released=\(released) \(gateDetail)")
        dm.browser.release(box)
        window.contentView = nil

        // 6. 授權時不給擷取：還沒完成的授權分頁在畫面上＝框所在的視窗 sharingType .none；標完成或關掉就還原。
        let captureWindow = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 466, height: 678), styleMask: [.borderless], backing: .buffered, defer: false)
        captureWindow.isReleasedWhenClosed = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 466, height: 678))
        captureWindow.contentView = holder
        let observable = DMBrowserAcceptance.windowSharingIsObservable()
        let before = captureWindow.sharingType
        dm.browser.claim(holder)
        let seventh = await open("W183UICAPTURE")
        let protected = dm.browser.captureProtectedWindow === captureWindow
        let sharingWhileOpen = captureWindow.sharingType
        dm.browser.markDone(purpose: .cloudflareLogin)
        let restored = dm.browser.captureProtectedWindow == nil && dm.loginTab?.done == true
        let sharingAfterDone = captureWindow.sharingType
        dm.finish()
        dm.browser.release(holder)
        captureWindow.contentView = nil
        check(protected && restored && seventh?.closes == 1,
              "W183 R8b 授權時不給擷取：還沒完成的授權分頁在畫面上＝框所在的視窗不給擷取；標完成就還原（分頁留著）",
              "protected=\(protected) restored=\(restored)")
        if observable {
            check(sharingWhileOpen == .none && sharingAfterDone == before,
                  "W183 R8b 授權時不給擷取：視窗真的是 sharingType .none、標完成還原成原本的設定",
                  "\(sharingWhileOpen.rawValue)/\(sharingAfterDone.rawValue)/\(before.rawValue)")
        } else {
            check.skip("W183 R8b 視窗真的不給擷取：這個環境沒有能讀回的視窗伺服器狀態（ssh 無頭），由主導實機驗")
        }

        // 7. 設定浮層開著（主視窗被蓋住）：私訊框開的是浮動框（浮在設定浮層上面），設定頁不關、不換頁。
        let covered = GlobalDMMainCover(overlays: ["chat"]).isCovered
        let action = GlobalDMOpenAction.resolve(enabled: true, floatingOpen: false, dockedShowing: false, appActive: true, mainWindowVisible: !covered)
        check(covered && action == .openFloating,
              "W183 R5b 審查 設定浮層開著（主視窗算被蓋住）：私訊框開浮動框，不開被蓋住的停靠框")
        check.skip("設定浮層開著時浮動框（level .floating）真的疊在設定浮層上面、看得到也點得到：無頭自測看不到畫面，主導實機截圖驗")
    }

    /// 真的 CEF 起不起得來（human 設定檔、AI 的瀏覽器工具找不到、收回就關）：這個建置沒有 Chromium（lead-verify 的 swift build 不開
    /// TATWO_ENABLE_CEF、也不是打包的 App）就記 SKIP——不當通過；真 CEF 由主導實機截圖驗。
    @MainActor static func cefPageChecks(_ check: Checker) async {
        guard TatwoCEFRuntime.compiled, EmbeddedBrowserEnginePolicy.current == .chromiumCEF,
              EmbeddedBrowserEnginePolicy.helperExecutableURL(in: .main) != nil else {
            check.skip("私訊框的真 CEF 頁面（human 設定檔、共用 context、AI 看不到、收回就關）：這個建置沒有 Chromium（compiled=\(TatwoCEFRuntime.compiled)），流程已用假頁面宿主驗；真 CEF 要主導實機驗")
            return
        }
        let host = GlobalDMCEFWebPageHost()
        do {
            let page = try await host.openPage(url: URL(string: "about:blank")!) { _ in }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 520))
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = container
            page.view.frame = container.bounds
            container.addSubview(page.view)
            let hidden = BrowserAgentBridge.findBrowserView(container, profileID: BrowserWorkSpaceRuntime.profile.dataStoreIdentifier) == nil
            let cef = page as? GlobalDMCEFWebPage
            check(page.isHumanActor && cef?.browser.sensitivePage == true && cef?.browser.onPopupCreated == nil && hidden,
                  "真 CEF：私訊框的頁面是 human、用 OS 瀏覽器的設定檔、是敏感頁（只准 https、新視窗疊在同一張頁面）；AI 的瀏覽器工具找不到它")
            page.close()
            let closed = await waitUntil(15) { cef?.closeCompleted == true }
            check(page.view.superview == nil && closed, "真 CEF：收回就從畫面拿掉、CEF 真的關完（不留在停泊視窗）")
            window.contentView = nil
        } catch {
            check(false, "真 CEF：私訊框的頁面開不起來", String(describing: error))
        }
    }

    /// 在背景跑一個會阻塞的呼叫、主執行緒只 await（不佔住主執行緒）。
    static func offMain<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - W183 R5b 審查：逾時收尾之後才讀到的授權網址

    /// 輸出延遲：網址在逾時收尾之後才送到——不會再開頁、不會再發布網址、步驟不會改回「等你按」；
    /// 收尾一定發關頁通知（先前還沒有網址也發）。
    @MainActor static func lateOutputChecks(_ check: Checker, _ fixture: Fixture) async throws {
        let runner = LateRunner()
        let world = try World(fixture, folder: "late-output", zoneName: "example.com", runner: runner, loginTimeout: 1)
        world.setup.login(trigger: .user)
        let timedOut = await waitUntil(20) { !world.setup.isBusy && world.status(.authorize).status == .failed }
        let closedWithoutURL = world.closedLogin.get() >= 1
        let deliver = runner.deliver.get()
        let late = loginLine("W183UILATE")
        try await offMain { deliver?(late) }   // 跟正式一樣在讀輸出的執行緒上送
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(timedOut && closedWithoutURL && deliver != nil && world.opened.get().isEmpty && world.setup.pendingLoginURL == nil
              && world.setup.loginURL == nil && world.status(.authorize).status == .failed && world.status(.authorize).message.contains("太久"),
              "W183 R5b 審查 逾時收尾之後才讀到的授權網址：不開頁、不發布網址、步驟不改回「等你按」；收尾一定收頁（先前沒有網址也收）",
              "opened=\(world.opened.get().count) closed=\(world.closedLogin.get()) \(world.status(.authorize).status.rawValue)")
    }

    // MARK: - W183 R5b 審查：副設備的自動開頁綁這一輪與按的那台；已開的頁綁這一輪有效的網址

    @MainActor static func remoteClientBindingChecks(_ check: Checker, _ base: URL) async throws {
        let dir = base.appendingPathComponent("client-binding", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("entry"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("live"), withIntermediateDirectories: true)
        let dispatch = DeviceDispatch(entry: TatwoEntry(environment: ["TATWO_OS_ROOT": dir.appendingPathComponent("entry").path], preference: nil),
                                      registry: DeviceRegistry(root: dir.appendingPathComponent("live"), authorizedKeysURL: dir.appendingPathComponent("authorized_keys")),
                                      retireBackup: { _ in })
        let probe = HandsRemoteClient(dispatch: dispatch)
        probe.pollsWhileWaiting = false   // 自測自己餵狀態
        let opened = HandsLocked<[URL]>([]), closed = HandsLocked<[URL?]>([])
        probe.openLoginPage = { url in opened.update { $0.append(url) }; return true }
        probe.closeLoginPages = { url in closed.update { $0.append(url) } }
        probe.returnToSettings = {}
        guard let a = URL(string: loginLine("W183UIRUNA")), let b = URL(string: loginLine("W183UIRUNB")) else { return check(false, "副設備自動開頁：網址") }
        func status(run: String?, mine: Bool, url: URL?, step: String = "waitingUser", at: Date = Date()) -> HandsRemoteStatus? {
            var object: [String: Any] = ["enabled": true, "phase": ["state": "stopped", "text": "x"], "setup_busy": true,
                                         "setup": [["step": "authorize", "status": step]]]
            if let run { object["setup_run"] = run; object["setup_run_mine"] = mine }
            if let url { object["login_url"] = url.absoluteString }
            return HandsRemoteStatus(object, fetchedAt: at)
        }
        // 1. 換了一輪（例如別台取消後重開）、同一輪但不是這台按的、連不上：都不開、不等了。對上了才開。
        probe.debugArm(run: "runA")
        probe.debugReceive(status(run: "runB", mine: true, url: b))
        let otherRun = opened.get().isEmpty && !probe.autoOpenArmed
        probe.debugArm(run: "runA")
        probe.debugReceive(status(run: "runA", mine: false, url: a))
        let notMine = opened.get().isEmpty && !probe.autoOpenArmed
        probe.debugArm(run: "runA")
        probe.debugReceive(nil)
        let unreachable = opened.get().isEmpty && !probe.autoOpenArmed
        probe.debugArm(run: "runA")
        probe.debugReceive(status(run: "runA", mine: true, url: a))
        let matched = opened.get() == [a] && !probe.autoOpenArmed && probe.awaitingAuthorize && probe.openedLoginURL == a
        check(otherRun && notMine && unreachable && matched,
              "W183 R5b 審查 副設備自動開頁：只在這一輪（編號）而且是這台按的時候開；換輪、不是這台按的、連不上＝不開、不等了",
              "otherRun=\(otherRun) notMine=\(notMine) unreachable=\(unreachable) matched=\(matched)")

        // 2. 已開的頁綁這一輪有效的網址：網址撤回（步驟還在跑）＝頁面馬上關（W183 R8b 審查：分頁留著寫「確認中」）、照樣等；
        //    網址換了＝收；連不上＝收頁、不等了。
        let withdrawnURLs = HandsLocked<[URL]>([])
        probe.loginPageWithdrawn = { url in withdrawnURLs.update { $0.append(url) } }
        let closedBeforeWithdraw = closed.get().count
        probe.debugReceive(status(run: "runA", mine: true, url: nil, step: "running"))
        let withdrawn = withdrawnURLs.get() == [a] && closed.get().count == closedBeforeWithdraw && probe.openedLoginURL == a && probe.awaitingAuthorize
        probe.openLoginHere(a)
        probe.debugReceive(status(run: "runB", mine: false, url: b))
        let changed = closed.get().last == a && probe.openedLoginURL == nil && probe.awaitingAuthorize
        probe.openLoginHere(b)
        let closedBefore = closed.get().count
        probe.debugReceive(nil)
        let dropped = closed.get().count == closedBefore + 1 && closed.get().last == b && !probe.awaitingAuthorize
        check(withdrawn && changed && dropped,
              "W183 R5b 審查 副設備已開的授權頁：網址撤回、換了、連不上主機就馬上收（不等期限、不等步驟寫完）",
              "withdrawn=\(withdrawn) changed=\(changed) dropped=\(dropped)")

        // 3. 狀態太久沒更新（查詢卡住）＝收頁；期限有自己的計時器（沒有任何網路回覆也收）。
        probe.openLoginHere(a)
        probe.debugReceive(status(run: "runA", mine: false, url: a))
        let keptWhileFresh = probe.openedLoginURL == a
        probe.debugCheckFreshness(now: Date().addingTimeInterval(HandsRemoteStatus.freshFor + 5))
        let staleClosed = closed.get().last == a && probe.openedLoginURL == nil
        probe.awaitLimit = 0.4
        probe.openLoginHere(b)
        let expired = await waitUntil(3) { !probe.awaitingAuthorize }
        check(keptWhileFresh && staleClosed && expired && closed.get().last == b && probe.openedLoginURL == nil,
              "W183 R5b 審查 副設備已開的授權頁：狀態太久沒更新就收；期限到了自己收（不靠網路回覆）")

        // 4. W183 R8b：網址拿掉是因為授權完成（主機第 3 步完成、或在等你確認帳號與網域）＝這台的授權分頁標「完成」、不收；
        //    網址拿掉但步驟失敗或取消＝照舊收。
        let doneURLs = HandsLocked<[URL]>([])
        probe.loginPageDone = { url in doneURLs.update { $0.append(url) } }
        probe.awaitLimit = HandsRemoteClient.defaultAwaitLimit
        probe.openLoginHere(a)
        let closedBeforeDone = closed.get().count
        probe.debugReceive(status(run: "runA", mine: true, url: nil, step: HandsSetupStatus.done.rawValue))
        let markedDone = doneURLs.get() == [a] && closed.get().count == closedBeforeDone && probe.openedLoginURL == nil && !probe.awaitingAuthorize
        probe.openLoginHere(b)
        probe.debugReceive(status(run: "runA", mine: true, url: nil, step: HandsSetupStatus.failed.rawValue))
        let failedClosed = doneURLs.get() == [a] && closed.get().last == b && !probe.awaitingAuthorize
        var confirmObject: [String: Any] = ["enabled": true, "phase": ["state": "stopped", "text": "x"], "setup_busy": false,
                                            "setup": [["step": "authorize", "status": "waitingUser"]],
                                            "authorized": ["account_name": "W183UIACCOUNT", "domain": "example.com", "needs_confirm": true]]
        let confirming = HandsRemoteStatus(confirmObject).map(HandsRemoteClient.authorizationFinished) == true
        confirmObject["login_url"] = a.absoluteString
        let stillOpen = HandsRemoteStatus(confirmObject).map(HandsRemoteClient.authorizationFinished) == false
        check(markedDone && failedClosed && confirming && stillOpen,
              "W183 R8b 副設備：授權完成（或在等你確認）＝授權分頁標「完成」、不收；失敗、取消照舊收",
              "done=\(markedDone) failed=\(failedClosed) confirm=\(confirming) open=\(stillOpen)")

        // 5. W183 R8b 審查（Claude）：cloudflared 剛結束、主機還在查網域與寫鑰匙圈（網址拿掉、第 3 步還在等、還沒要你確認）＝分頁不關
        //    （頁面先撤下、寫「確認中」）；主機一到「請確認」＝標「完成」。
        probe.openLoginHere(a)
        let closedBeforeGap = closed.get().count, withdrawnBeforeGap = withdrawnURLs.get().count
        var gap: [String: Any] = ["enabled": true, "phase": ["state": "stopped", "text": "x"], "setup_busy": true, "setup_run": "runA",
                                  "setup_run_mine": true, "setup": [["step": "authorize", "status": HandsSetupStatus.waitingUser.rawValue]]]
        let gapStatus = HandsRemoteStatus(gap)
        let openedAtGap = probe.openedLoginURL == a && probe.awaitingAuthorize
        probe.debugReceive(gapStatus)
        let keptInGap = closed.get().count == closedBeforeGap && withdrawnURLs.get().count == withdrawnBeforeGap + 1
            && withdrawnURLs.get().last == a && probe.openedLoginURL == a && probe.awaitingAuthorize
        let gapDetail = "parsed=\(gapStatus != nil) run=\(gapStatus?.setupRun ?? "nil") opened=\(openedAtGap) closed+\(closed.get().count - closedBeforeGap)"
            + " withdrawn+\(withdrawnURLs.get().count - withdrawnBeforeGap) url=\(probe.openedLoginURL == a) awaiting=\(probe.awaitingAuthorize)"
        gap["setup_busy"] = false
        gap["setup_run"] = nil   // 主機這一輪跑完（停在「請確認」）會清掉編號
        gap["authorized"] = ["account_name": "W183UIACCOUNT", "domain": "example.com", "needs_confirm": true]
        probe.debugReceive(HandsRemoteStatus(gap))
        let doneAfterGap = doneURLs.get().last == a && doneURLs.get().count == 2 && closed.get().count == closedBeforeGap && !probe.awaitingAuthorize
        check(keptInGap && doneAfterGap,
              "W183 R8b 審查 副設備：主機還在查網域、寫鑰匙圈（網址拿掉、還沒要你確認）＝分頁不關（頁面撤下、寫「確認中」）；到「請確認」才標「完成」",
              "gap=\(keptInGap) done=\(doneAfterGap) \(gapDetail) doneURLs=\(doneURLs.get().count)")

        // 6. W183 R8b 審查（GPT-6）：主機跑的已經是別的一輪（編號不同）＝不是這一頁的結果：收掉、不標「完成」。
        probe.debugReceive(status(run: "runA", mine: true, url: b))   // 這台看到的是 runA 的網址（還沒在等）
        probe.openLoginHere(b)
        let doneBeforeOther = doneURLs.get().count
        probe.debugReceive(status(run: "runB", mine: false, url: nil, step: HandsSetupStatus.done.rawValue))
        let otherRunClosed = closed.get().last == b && doneURLs.get().count == doneBeforeOther && !probe.awaitingAuthorize
        check(otherRunClosed, "W183 R8b 審查 副設備：主機已經換了一輪（別人的流程）才做完＝這台的分頁收掉，不標「完成」")
    }

    // MARK: - 副設備查詢：同一時間只有一個、連不上就退避

    @MainActor static func remoteClientChecks(_ check: Checker, _ base: URL) async throws {
        let dir = base.appendingPathComponent("client", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("entry"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("live"), withIntermediateDirectories: true)
        let dispatch = DeviceDispatch(entry: TatwoEntry(environment: ["TATWO_OS_ROOT": dir.appendingPathComponent("entry").path], preference: nil),
                                      registry: DeviceRegistry(root: dir.appendingPathComponent("live"), authorizedKeysURL: dir.appendingPathComponent("authorized_keys")),
                                      retireBackup: { _ in })
        let client = HandsRemoteClient(dispatch: dispatch)
        let start = Date()
        client.fetch(); client.fetch(); client.fetch()   // 上一個還在路上：後兩個跳過
        _ = await waitUntil(10) { client.debugBackoff.failures >= 1 && !client.debugBackoff.inFlight }
        _ = await waitUntil(2) { client.stale }
        let first = client.debugBackoff
        client.fetch()   // 還在退避：跳過
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(first.failures == 1 && client.debugBackoff.failures == 1 && first.nextAllowed >= start.addingTimeInterval(9)
              && client.stale && client.status == nil && client.problem != nil,
              "副設備查詢：同一時間只有一個；連不上就退避（10 秒起），不會越排越多", "\(first)")
        client.fetch(force: true)
        _ = await waitUntil(10) { client.debugBackoff.failures >= 2 && !client.debugBackoff.inFlight }
        check(client.debugBackoff.nextAllowed >= Date().addingTimeInterval(20), "副設備查詢：連續失敗拉長間隔（30 秒）")
    }
}
#endif
