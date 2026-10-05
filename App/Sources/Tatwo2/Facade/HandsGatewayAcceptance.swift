import Foundation
import Darwin

/// W183 R2／R2b 自測（`TATWO2_SELFTEST=w183gateway`，無頭、在 lead-verify 的 staging 隔離裡跑）：
/// 自測／staging 不啟動、IP 清單解析與四種失效、子行程環境沒有多餘變數、token 不進 argv 也不進環境、token 檔 0600／不跟隨捷徑／連上就刪；
/// 並用真的 sandbox-exec＋Node 起關口（gateway.mjs，沒有 supervisor），假的 cloudflared 用「非系統程式」的 Node 扮演
/// （系統程式的環境從外面讀不到，非系統程式讀得到——真的 cloudflared 就是後者，所以要用 KERN_PROCARGS2 實讀），驗：
/// 接口約定 v2 §1／v3 V8 的兄弟行程拓樸與啟動、退出順序；登記的是關口 pid；cloudflared 替身不是外部 AI；App 的 fd（canary）關口與
/// cloudflared 都拿不到；HTTP 端點矩陣（授權頁不看 OpenAI 清單）；清單過期全拒；任一個停掉整組收掉再重開；開關關掉就停；
/// App 當掉（stdin 關閉）兩組都收；App 結束途中不重開；cloudflared 不在時清楚回報。鑰匙圈用記憶體假資料，不碰真的。
/// W183 R2b 審查：驗不到的項目一律印 `W183GATEWAY SKIP blocked-until-R1 <名稱>` 並算進 SUMMARY 的 skipped（lead-verify 只看 FAIL 會漏看，
/// 所以 SKIP 行帶 blocked 字樣、SUMMARY 寫明未驗證）；`HandsContract.registryImplemented` 為 true 之後，登記沒生效就是 FAIL。
/// 另驗：回呼在開行程時就裝好（馬上輸出、馬上結束的子行程也收得到）、socket 被換掉時整組停下且不自動重開。
/// W183 R4：原本唯一的 SKIP（真實 os.sock 整合）換成真的整合測試（HandsGatewayIntegration.swift）：真的橋、HandsService、關口，
/// 配對 → token → MCP → request_id 重送 → refresh 輪替與重用 → 跨 grant → App 撤銷與開關 → 身分，十步各一條 PASS。
enum HandsGatewayAcceptance {
    struct MemoryToken: HandsTunnelTokenStore {
        let value: String?
        func read() throws -> String? { value }
    }
    struct LockedToken: HandsTunnelTokenStore {
        func read() throws -> String? { throw HandsTunnelKeychain.Failure.locked }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(pid_t, UInt64)] = []
        private var removed: [pid_t] = []
        func add(_ pid: pid_t, _ start: UInt64) { lock.lock(); items.append((pid, start)); lock.unlock() }
        func remove(_ pid: pid_t) { lock.lock(); removed.append(pid); lock.unlock() }
        var all: [(pid_t, UInt64)] { lock.lock(); defer { lock.unlock() }; return items }
        var unregistered: [pid_t] { lock.lock(); defer { lock.unlock() }; return removed }
    }

    static func run() -> Int32 {
        #if DEBUG
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0
        var skipped: [String] = []
        func check(_ ok: Bool, _ name: String) {
            print("W183GATEWAY \(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        // 驗不到＝SKIP（算數、印出來，SKIP 行帶 blocked 讓 lead-verify 印得出來）。
        func pending(_ name: String) {
            print("W183GATEWAY SKIP blocked-until-R1 \(name)")
            skipped.append(name)
        }
        // 靠外部 AI 登記才驗得到的：登記已實作（R1 合併後）卻沒生效＝FAIL，不再略過。
        func skip(_ name: String) {
            if HandsContract.registryImplemented { check(false, "\(name)（外部 AI 登記已實作卻沒生效）"); return }
            pending(name)
        }
        guardChecks(check)
        retryChecks(check)
        rangeChecks(check)
        launchChecks(check)
        spawnCallbackChecks(check)
        descendantChecks(check, skip)
        // W183 R4：真的 os.sock 整合（真的橋、HandsService／HandsAuth／HandsTools、ChatGPTHandsService 起的關口）；
        // 要在 endToEnd 之前（它最後會模擬 App 結束，之後就不能再開子行程）。
        MainActor.assumeIsolated { HandsGatewayIntegration.run(check) }   // 自測從 main() 直接呼叫：就在主執行緒上
        endToEnd(check, skip)
        print("W183GATEWAY SUMMARY failures=\(failures) skipped=\(skipped.count)\(skipped.isEmpty ? "" : "（未驗證，兩房合併後重跑才算數）")")
        return failures == 0 ? 0 : 1
        #else
        print("W183GATEWAY FAIL debug build required")
        return 1
        #endif
    }

    #if DEBUG
    static func tempRoot(_ prefix: String) -> URL {
        // unix socket 路徑上限 104 位元組：放 /tmp，用真實路徑。
        var template = Array("/tmp/\(prefix)-XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
        let path = made.map { String(cString: $0) } ?? NSTemporaryDirectory() + prefix + UUID().uuidString
        return URL(fileURLWithPath: HandsGatewayLaunch.realPath(path) ?? path, isDirectory: true)
    }

    private static func writeSettings(_ root: URL, enabled: Bool, device: String = "device-test-1") throws {
        let paths = HandsGatewayLaunch.Paths(root: root)
        try HandsGatewayLaunch.ensurePrivateDirectory(paths.appDir)
        let object: [String: Any] = ["enabled": enabled, "level": 1, "public_host": "hands.example.com", "host_device_id": device,
                                     "allowed_project_ids": [String](), "lent_folders": [String]()]
        try HandsGatewayLaunch.writePrivate(try JSONSerialization.data(withJSONObject: object), to: paths.settingsFile)
    }

    static func seedRanges(_ root: URL, fetched: Date = Date(), ranges: [String] = ["203.0.113.0/24"]) throws {
        let paths = HandsGatewayLaunch.Paths(root: root)
        try HandsGatewayLaunch.ensurePrivateDirectory(paths.gatewayDir)
        try HandsGatewayLaunch.writeGatewayDocument(.init(socketPath: paths.socket.path, publicHost: "hands.example.com", allowedIPRanges: ranges,
                                                          rangesFetchedAt: HandsGatewayLaunch.timestamp(fetched)), to: paths.gatewayConfig)
    }

    /// 等的時候轉主執行緒的 run loop（自測本身跑在主執行緒上；服務的結果經 main.async 發佈）。
    static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            if Thread.isMainThread { _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false) } else { usleep(100_000) }
        }
        return condition()
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // MARK: 1. 自測／staging 不啟動
    private static func guardChecks(_ check: (Bool, String) -> Void) {
        let current = ProcessInfo.processInfo.environment
        check(!ChatGPTHandsService.allowedToRun(environment: current), "自測行程本身（TATWO2_SELFTEST／staging）不允許開關口")
        check(!ChatGPTHandsService.allowedToRun(environment: ["HOME": "/tmp/x", "TATWO_STAGING_SCRATCH_HOME": "/tmp/x"]), "staging 不開")
        check(!ChatGPTHandsService.allowedToRun(environment: ["HOME": "/tmp/x", "TATWO2_SOURCETEST": "1"]), "source test 不開")
        check(!ChatGPTHandsService.allowedToRun(environment: ["HOME": "/tmp/x", "TATWO2_SELFTEST": "other"]), "其他自測不開")
        check(ChatGPTHandsService.allowedToRun(environment: ["HOME": "/tmp/x"]), "一般使用可以開")
        check(HandsGatewayLaunch.Paths.defaultRoot().lastPathComponent == "TATWO OS Hands"
              && HandsGatewayLaunch.Paths.defaultRoot().deletingLastPathComponent().lastPathComponent == "Application Support",
              "預設資料夾是 <App Support>/TATWO OS Hands（接口約定 v2 §10）")

        let root = tempRoot("w183g")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let hands = root.appendingPathComponent("hands", isDirectory: true)
            try writeSettings(hands, enabled: true)
            var spawned = false
            var deps = ChatGPTHandsService.Dependencies()
            deps.environment = current          // 正是 staging／自測環境
            deps.handsRoot = hands
            deps.hostConfirmed = { _ in true }   // W183 R8c：每台啟用許可另在 w183build 驗；這裡只驗關口本身
            deps.cloudflared = { spawned = true; return URL(fileURLWithPath: "/bin/bash") }
            deps.localDeviceID = { "device-test-1" }
            deps.tunnelToken = MemoryToken(value: "tunnel-token-" + String(repeating: "x", count: 32))
            deps.fetchRanges = { _ in spawned = true }
            deps.register = { _, _ in spawned = true }
            let service = ChatGPTHandsService(dependencies: deps)
            service.startIfEnabled()
            service.settingsDidChange()
            service.debugEvaluate()
            let processes = service.debugProcesses
            let paths = HandsGatewayLaunch.Paths(root: hands)
            check(service.debugPhase == .stopped && processes.gateway == nil && processes.tunnel == nil && !spawned
                  && !FileManager.default.fileExists(atPath: paths.gatewayConfig.path)
                  && !FileManager.default.fileExists(atPath: paths.cloudflaredConfig.path)
                  && !FileManager.default.fileExists(atPath: paths.socketDir.path),
                  "staging 裡開關開著也不起關口、不開通道、不抓清單、不登記、不寫設定")
        } catch { check(false, "staging 檢查準備失敗 \(error)") }
    }

    // MARK: 2. IP 清單（接口約定 v2 §2 的清單政策）
    private static func retryChecks(_ check: (Bool, String) -> Void) {
        let root = tempRoot("w185retry")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try writeSettings(root, enabled: true)
            let clock = HandsLocked(Date())
            let permit = HandsLocked(true)
            let attempts = HandsLocked(0)
            var deps = ChatGPTHandsService.Dependencies()
            deps.allowUnderTest = true
            deps.handsRoot = root
            deps.localDeviceID = { "device-test-1" }
            deps.hostConfirmed = { _ in permit.get() }
            deps.now = { clock.get() }
            deps.prepareWorkspace = { attempts.update { $0 += 1 }; return "工作區暫時讀不到 W185_PRIVATE_CANARY" }
            deps.fetchRanges = { _ in }
            let service = ChatGPTHandsService(dependencies: deps)
            service.debugEvaluate()
            check(attempts.get() == 1 && service.debugRetryAt == clock.get().addingTimeInterval(30)
                  && ChatGPTHandsService.statusText(service.debugPhase).contains("自動重試"),
                  "W185 暫時性 prepare 失敗：原因與下次重試時間可見，30 秒退避")
            service.debugEvaluate()
            check(attempts.get() == 1, "W185 退避未到：不熱重試")
            for delay in [60.0, 120.0, 240.0, 300.0, 300.0] {
                clock.set(service.debugRetryAt!)
                service.debugEvaluate()
                check(service.debugRetryAt == clock.get().addingTimeInterval(delay), "W185 退避 \(Int(delay)) 秒（上限 5 分鐘）")
            }
            permit.set(false)
            service.debugEvaluate()
            check(service.debugPhase == .stopped, "W185 paused 許可：停下、不撤銷連線")
            let before = attempts.get()
            permit.set(true)
            service.debugEvaluate()
            check(attempts.get() == before + 1 && service.debugRetryAt == clock.get().addingTimeInterval(30)
                  && service.debugCrashCount == 0,
                  "W185 paused → active：同設定、未按重試、未到退避時間，下一次 evaluate 重新 begin")
            let log = (try? String(contentsOf: service.paths.logFile, encoding: .utf8)) ?? ""
            check(log.contains("reason=permit_restored result=begin") && log.contains("result=temporary_failure")
                  && !log.contains("W185_PRIVATE_CANARY"), "W185 重啟 log：時間、原因、結果；不記錯誤原文與秘密")

            // Same production path, but a configuration failure must not loop.
            let permanent = root.appendingPathComponent("configuration")
            try writeSettings(permanent, enabled: true, device: "another-device")
            deps.handsRoot = permanent
            let locked = ChatGPTHandsService(dependencies: deps)
            locked.debugEvaluate()
            clock.set(clock.get().addingTimeInterval(600))
            locked.debugEvaluate()
            let lockedLog = (try? String(contentsOf: locked.paths.logFile, encoding: .utf8)) ?? ""
            check(locked.debugPhase == .failed("通道設在另一台設備；這台不開") && locked.debugRetryAt == nil
                  && lockedLog.components(separatedBy: "result=begin").count == 2,
                  "W185 設定錯誤：同設定仍鎖住，不自動重試")
            try writeSettings(permanent, enabled: true)
            locked.debugEvaluate()
            check(locked.debugRetryAt != nil, "W185 設定改正：解除設定指紋鎖，重新 prepare")
            locked.debugSafetyStop()
            permit.set(false); locked.debugEvaluate()
            permit.set(true); locked.debugEvaluate()
            check(locked.debugPhase == .failed(ChatGPTHandsService.tamperedText)
                  && ChatGPTHandsService.safetyStopped(locked.paths),
                  "W185 許可恢復：絕不解除記憶體或磁碟安全停機鎖")
            deps.prepareWorkspace = { nil }
            deps.programDirectory = repoProgramDirectory()
            deps.node = URL(fileURLWithPath: "/bin/sh")
            deps.cloudflared = { URL(fileURLWithPath: "/bin/sh") }
            deps.tunnelToken = LockedToken()
            let keychainRoot = root.appendingPathComponent("keychain")
            try writeSettings(keychainRoot, enabled: true)
            deps.handsRoot = keychainRoot
            let keychain = ChatGPTHandsService(dependencies: deps)
            keychain.debugEvaluate()
            check(keychain.debugRetryAt != nil && ChatGPTHandsService.statusText(keychain.debugPhase).contains("鑰匙圈"),
                  "W185 鑰匙圈讀取拋錯：走真 prepare 分類為可退避重試")
            let fileRoot = root.appendingPathComponent("files")
            try writeSettings(fileRoot, enabled: true)
            deps.handsRoot = fileRoot
            deps.cloudflared = { nil }
            let files = ChatGPTHandsService(dependencies: deps)
            files.debugEvaluate()
            check(files.debugRetryAt != nil && ChatGPTHandsService.statusText(files.debugPhase).contains("雜湊"),
                  "W185 cloudflared 讀檔或雜湊驗證失敗：不啟動未驗程式，但不永久鎖")
        } catch { check(false, "W185 重試自測準備失敗 \(error)") }
    }

    private static func rangeChecks(_ check: (Bool, String) -> Void) {
        let valid = Data(#"{"creationTime":"2026-09-22T18:18:05.915327","prefixes":[{"ipv4Prefix":"203.0.113.0/24"},{"ipv4Prefix":"198.51.100.8/29"},{"ipv6Prefix":"2001:db8:10::/48"},{"ipv4Prefix":"203.0.113.0/24"}]}"#.utf8)
        let parsed = try? HandsGatewayLaunch.parseConnectorRanges(valid)
        check(parsed == ["203.0.113.0/24", "198.51.100.8/29", "2001:db8:10::/48"], "OpenAI 清單格式解析（含 IPv6、去重）")
        func rejects(_ json: String, _ expected: HandsGatewayLaunch.Failure) -> Bool {
            do { _ = try HandsGatewayLaunch.parseConnectorRanges(Data(json.utf8)); return false }
            catch let failure as HandsGatewayLaunch.Failure { return failure == expected }
            catch { return false }
        }
        check(rejects("not json", .invalidList), "不是 JSON 不收")
        check(rejects(#"{"prefixes":[]}"#, .invalidList), "空清單不收")
        check(rejects(#"{"prefixes":[{"ipv4Prefix":"203.0.113.0/24"},{"ipv4Prefix":"0.0.0.0/0"}]}"#, .tooBroad), "0.0.0.0/0 整份不收")
        check(rejects(#"{"prefixes":[{"ipv4Prefix":"11.0.0.0/4"}]}"#, .tooBroad), "太寬的 IPv4 網段整份不收")
        check(rejects(#"{"prefixes":[{"ipv6Prefix":"2001:db8::/8"}]}"#, .tooBroad), "太寬的 IPv6 網段整份不收")
        check(rejects(#"{"prefixes":[{"ipv4Prefix":"203.0.113.300/24"}]}"#, .invalidList), "位址不合法不收")
        check(rejects(#"{"prefixes":[{"ipv4Prefix":"203.0.113.0/33"}]}"#, .invalidList), "前綴超過範圍不收")
        check(rejects(#"{"prefixes":[{"other":"x"}]}"#, .invalidList), "欄位不對不收")
        let many = "{\"prefixes\":[" + (0..<5001).map { _ in #"{"ipv4Prefix":"203.0.113.0/24"}"# }.joined(separator: ",") + "]}"
        check(rejects(many, .tooMany), "超過 5000 筆不收")

        let now = Date()
        check(HandsGatewayLaunch.isStale(nil, now: now), "失效 1：沒有可信清單（沒抓過）＝過期，關口全拒")
        check(!HandsGatewayLaunch.isStale(now.addingTimeInterval(-6 * 86400), now: now), "6 天內還能用")
        check(HandsGatewayLaunch.isStale(now.addingTimeInterval(-8 * 86400), now: now), "失效 4：超過 7 天＝過期")
        check(HandsGatewayLaunch.isStale(now.addingTimeInterval(2 * 3600), now: now), "時間在未來＝不可信")

        let root = tempRoot("w183r")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let hands = root.appendingPathComponent("hands", isDirectory: true)
            try writeSettings(hands, enabled: true)
            let old = now.addingTimeInterval(-2 * 86400)
            try seedRanges(hands, fetched: old, ranges: ["192.0.2.0/24"])
            var deps = ChatGPTHandsService.Dependencies()
            deps.handsRoot = hands
            deps.hostConfirmed = { _ in true }   // W183 R8c：每台啟用許可另在 w183build 驗；這裡只驗關口本身
            let service = ChatGPTHandsService(dependencies: deps)
            let paths = HandsGatewayLaunch.Paths(root: hands)
            service.debugApplyRanges(.failure(HandsGatewayLaunch.Failure.invalidList))
            var document = HandsGatewayLaunch.readGatewayDocument(paths.gatewayConfig)
            check(document?.allowedIPRanges == ["192.0.2.0/24"] && document?.rangesFetchedAt == HandsGatewayLaunch.timestamp(old)
                  && document?.lastError == "fetch_failed" && document?.lastAttemptAt != nil,
                  "失效 2：更新失敗保留舊清單，而且**不更新**抓到的時間（只記最後一次嘗試）")
            service.debugApplyRanges(.success(Data(#"{"prefixes":[{"ipv4Prefix":"0.0.0.0/0"}]}"#.utf8)))
            document = HandsGatewayLaunch.readGatewayDocument(paths.gatewayConfig)
            check(document?.allowedIPRanges == ["192.0.2.0/24"] && document?.rangesFetchedAt == HandsGatewayLaunch.timestamp(old)
                  && document?.lastError == "invalid_list", "失效 3：格式錯誤保留舊清單與舊時間")
            service.debugApplyRanges(.success(valid))
            document = HandsGatewayLaunch.readGatewayDocument(paths.gatewayConfig)
            check(document?.allowedIPRanges.count == 3 && document?.lastError == nil
                  && (document?.fetchedDate.map { abs($0.timeIntervalSince(now)) < 60 } ?? false), "新清單驗過才換上、才更新時間")
            var info = stat()
            let fileMode = stat(paths.gatewayConfig.path, &info) == 0 ? info.st_mode & 0o777 : 0
            let dirMode = stat(paths.gatewayDir.path, &info) == 0 ? info.st_mode & 0o777 : 0
            check(fileMode == 0o600 && dirMode == 0o700, "config.json 0600、gateway 資料夾 0700")
        } catch { check(false, "清單檢查準備失敗 \(error)") }
    }

    // MARK: 3. 啟動參數與環境
    private static func launchChecks(_ check: (Bool, String) -> Void) {
        let paths = HandsGatewayLaunch.Paths(root: URL(fileURLWithPath: "/private/tmp/w183x/TATWO OS Hands", isDirectory: true))
        let token = "tunnel-CANARY-" + String(repeating: "t", count: 40)
        check(paths.settingsFile.path.hasSuffix("TATWO OS Hands/app/settings.json") && paths.gatewayConfig.path.hasSuffix("TATWO OS Hands/gateway/config.json")
              && paths.socket.path.hasSuffix("TATWO OS Hands/gateway/sock/gw.sock") && paths.cloudflaredHome.path.hasSuffix("TATWO OS Hands/cf-home"),
              "版面照接口約定 v2 §10：app/settings.json、gateway/config.json、gateway/sock/、cf-home/")
        check(HandsGatewayLaunch.gatewayEnvironment(paths: paths, osSocket: "/private/tmp/w183x/o.sock").keys.sorted() == ["HOME", "LANG", "PATH", "TATWO2_OS_SOCKET"],
              "關口的環境只有 PATH／HOME／LANG／os.sock（沒有 TUNNEL_TOKEN、沒有憑證）")
        check(HandsGatewayLaunch.cloudflaredEnvironment(paths: paths).keys.sorted() == ["HOME", "PATH"],
              "cloudflared 的環境只有 HOME／PATH（token 不放環境變數：非系統程式的環境同一個使用者讀得到）")
        check(HandsGatewayLaunch.cloudflaredEnvironment(paths: paths)["HOME"] == paths.cloudflaredHome.path, "cloudflared 用獨立 HOME（T13）")
        let tokenFile = paths.newTunnelTokenFile()
        let guardScript = "echo guard"
        if let launch = try? HandsGatewayLaunch.cloudflaredLaunch(profile: "(version 1)", guardScript: guardScript, cloudflared: "/opt/homebrew/bin/cloudflared",
                                                                  paths: paths, tokenFile: tokenFile, userHome: "/Users/example") {
            check(!launch.arguments.contains(where: { $0.contains(token) }) && launch.executable == "/bin/sh"
                  && Array(launch.arguments.prefix(5)) == ["-c", guardScript, "chatgpt-hands/tunnel-guard", tokenFile.path, "/usr/bin/sandbox-exec"]
                  && Array(launch.arguments.suffix(7)) == ["tunnel", "--no-autoupdate", "--config", paths.cloudflaredConfig.path, "run", "--token-file", tokenFile.path]
                  && launch.arguments.contains("USER_HOME=/Users/example") && launch.arguments.contains("HANDS_ROOT=" + paths.root.path)
                  && !launch.arguments.contains("--token"),
                  "cloudflared：看門程式（sh -c 全文）包著 sandbox-exec、--no-autoupdate＋明確 --config＋--token-file、讀不到手腳資料夾、token 不在 argv")
        } else { check(false, "cloudflared 參數") }
        check((try? HandsGatewayLaunch.cloudflaredLaunch(profile: "(version 1)", guardScript: guardScript, cloudflared: "/opt/homebrew/bin/cloudflared", paths: paths,
                                                         tokenFile: URL(fileURLWithPath: "/private/tmp/w183x/elsewhere/.tunnel-token-x"), userHome: "/Users/example")) == nil,
              "token 檔只能放在 cf-home 裡")
        tokenFileChecks(check, token: token)
        let deep = "/private/tmp/" + (0..<30).map { "d\($0)" }.joined(separator: "/")
        check((try? HandsGatewayLaunch.gatewayLaunch(profile: "(version 1)", node: deep + "/node", programDir: "/private/tmp/p", paths: paths, osSocket: "/private/tmp/o.sock")) == nil,
              "上層資料夾超過 24 格就不起（不放寬規則）")
        let longRoot = HandsGatewayLaunch.Paths(root: URL(fileURLWithPath: "/private/tmp/" + String(repeating: "L", count: 100)))
        check((try? HandsGatewayLaunch.gatewayLaunch(profile: "(version 1)", node: "/private/tmp/node", programDir: "/private/tmp/p", paths: longRoot, osSocket: "/private/tmp/o.sock")) == nil,
              "socket 路徑超過 104 位元組就不起")
        if let launch = try? HandsGatewayLaunch.gatewayLaunch(profile: "(version 1)", node: "/private/tmp/n/node", programDir: "/private/tmp/p", paths: paths, osSocket: "/private/tmp/o.sock") {
            let params = launch.arguments.enumerated().filter { $0.offset > 0 && launch.arguments[$0.offset - 1] == "-D" }.map(\.element)
            check(launch.executable == "/usr/bin/sandbox-exec" && params.filter { $0.hasPrefix("ANC_") }.count == 24 && params.contains("SOCKET=" + paths.socket.path)
                  && params.contains("CONFIG=" + paths.gatewayConfig.path) && !params.contains(where: { $0.hasPrefix("STATE_DIR=") })
                  && Array(launch.arguments.suffix(3)) == ["/private/tmp/n/node", "/private/tmp/p/gateway.mjs", paths.gatewayConfig.path],
                  "關口：sandbox-exec 直接開 node gateway.mjs <config.json>（沒有 supervisor）、路徑都用 -D 傳、沒有可寫的狀態資料夾")
        } else { check(false, "關口參數") }
        check((try? HandsGatewayLaunch.cloudflaredConfig(publicHost: "evil.example.com\n  - service: http://127.0.0.1:22", socket: paths.socket.path)) == nil
              && (try? HandsGatewayLaunch.cloudflaredConfig(publicHost: "hands.example.com", socket: "/tmp/a\"b")) == nil,
              "cf.yml 不接受換行或引號注入")
        let yaml = (try? HandsGatewayLaunch.cloudflaredConfig(publicHost: "hands.example.com", socket: paths.socket.path)) ?? ""
        check(yaml.contains("hostname: \"hands.example.com\"") && yaml.contains("service: \"unix:\(paths.socket.path)\"")
              && yaml.contains("service: http_status:404") && !yaml.contains("credentials"), "cf.yml 只轉到關口的 socket，其他 404")
        check(HandsGatewayLaunch.validToken(token) && !HandsGatewayLaunch.validToken("short") && !HandsGatewayLaunch.validToken(token + "\n"), "通道 token 格式檢查")
        let line = HandsGatewayLaunch.logLine(["ev": "req", "m": "POST", "r": "mcp", "s": 200, "ms": 7, "rpc": "tools/call", "token": token], at: Date(timeIntervalSince1970: 0)) ?? ""
        let hostile = HandsGatewayLaunch.logLine(["ev": "req", "m": "GET " + token, "r": "/x?code=" + token, "s": "x", "ms": -1, "rpc": token], at: Date()) ?? ""
        check(line == "1970-01-01T00:00:00Z POST mcp 200 7ms tools/call\n" && !hostile.contains(token) && HandsGatewayLaunch.logLine(["ev": "ready"], at: Date()) == nil,
              "關口日誌：App 逐欄檢查才寫，奇怪的值寫不進去（T10）")
    }

    /// token 檔：0600、只建新檔、不跟隨捷徑、留下的會被清掉（T10）。
    private static func tokenFileChecks(_ check: (Bool, String) -> Void, token: String) {
        let root = tempRoot("w183t")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HandsGatewayLaunch.Paths(root: root.appendingPathComponent("hands", isDirectory: true))
        do {
            try HandsGatewayLaunch.ensurePrivateDirectory(paths.root)
            try HandsGatewayLaunch.ensurePrivateDirectory(paths.cloudflaredHome)
            let file = paths.newTunnelTokenFile()
            try HandsGatewayLaunch.writeTokenFile(token, to: file)
            var info = stat()
            let mode = lstat(file.path, &info) == 0 ? info.st_mode & 0o777 : 0
            check(mode == 0o600 && (try? String(contentsOf: file, encoding: .utf8)) == token, "token 檔 0600、內容完整")
            check((try? HandsGatewayLaunch.writeTokenFile("other-" + token, to: file)) == nil
                  && (try? String(contentsOf: file, encoding: .utf8)) == token, "token 檔已存在就不覆寫（O_EXCL）")
            let decoy = root.appendingPathComponent("decoy.txt")
            try Data("DECOY".utf8).write(to: decoy)
            let link = paths.newTunnelTokenFile()
            _ = symlink(decoy.path, link.path)
            check((try? HandsGatewayLaunch.writeTokenFile(token, to: link)) == nil
                  && (try? String(contentsOf: decoy, encoding: .utf8)) == "DECOY", "token 檔的位置是捷徑就不寫（O_NOFOLLOW）")
            HandsGatewayLaunch.removeStaleTokenFiles(in: paths.cloudflaredHome)
            check(HandsGatewayLaunch.tokenFiles(in: paths.cloudflaredHome).isEmpty && FileManager.default.fileExists(atPath: decoy.path),
                  "留下的 token 檔會被清掉（捷徑只刪捷徑本身）")
        } catch { check(false, "token 檔檢查準備失敗 \(error)") }
    }

    // MARK: 3b. 回呼在開行程時就裝好（W183 R2b 審查）
    /// 很快輸出、馬上結束的子行程：輸出與結束通知一次都不能掉（開好再設回呼的舊寫法，最早的輸出與結束會掉，服務就卡在「啟動中」）。
    /// 另驗結束碼記得到、結束後 isRunning 是 false，以及 App 定時確認 socket 聽的人用的 socketPeer。
    private static func spawnCallbackChecks(_ check: (Bool, String) -> Void) {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String: Int] = [:]
            func add(_ key: String) { lock.lock(); values[key, default: 0] += 1; lock.unlock() }
            func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key] ?? 0 }
        }
        let counter = Counter()
        let rounds = 20
        var processes: [SidecarGroupedProcess] = []
        for index in 0..<rounds {
            // 一半馬上結束（沒有輸出），一半先印一行再等一下才結束。
            let script = index % 2 == 0 ? "exit 7" : "echo ready; /bin/sleep 0.3; exit 7"
            guard let process = try? SidecarGroupedProcess.spawn(
                executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: "/",
                closeInheritedDescriptors: true,
                onStdout: { data in if String(decoding: data, as: UTF8.self).contains("ready") { counter.add("out") } },
                onExit: { counter.add("exit") }) else { check(false, "回呼測試的子行程開不起來"); return }
            processes.append(process)
        }
        let done = waitUntil(10) { counter.count("exit") == rounds && counter.count("out") == rounds / 2 }
        check(done, "回呼在開行程時就裝好：\(rounds) 個子行程的結束通知與最早的輸出一個都沒掉（實際 結束 \(counter.count("exit"))／輸出 \(counter.count("out"))）")
        check(processes.allSatisfy { $0.exitCode == 7 && !$0.isRunning }, "結束碼記得到（服務靠它分辨關口自己發現被冒充）、結束後 isRunning 是 false")

        let root = tempRoot("w183c")
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("peer.sock").path
        if let fd = listenUnix(socketPath) {
            check(HandsGatewayLaunch.socketPeer(socketPath: socketPath) == getpid(), "socketPeer 認得出聽 socket 的是誰（App 定時確認關口 socket 沒被換掉）")
            close(fd)
        } else { check(false, "socketPeer 測試的 socket 開不起來") }
    }

    /// 在 path 開一個 unix socket 並 listen（扮演冒充關口的程式）；呼叫端負責關。
    private static func listenUnix(_ path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { source in withUnsafeMutablePointer(to: &address.sun_path.0) { strlcpy($0, source, capacity) } }
        guard copied < capacity else { close(fd); return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return nil }
        return fd
    }

    // MARK: 4. 身分不沿用（R1 的 registerExternalAI 合併後才驗得到分類；現在是空殼就記 SKIP）
    /// 關口本身在 Seatbelt 裡開不出子行程（node 測試實跑）；這裡另外證明：就算登記的外部 AI 開得出子行程，子行程也是 `.other`。
    /// 用一個 App 直接開的替身（/bin/sh 開一個 sleep）登記成外部 AI，分類替身本人與它的子行程。
    private static func descendantChecks(_ check: (Bool, String) -> Void, _ skip: (String) -> Void) {
        guard let parent = try? SidecarGroupedProcess.spawn(executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30 & wait"],
                                                            environment: ["PATH": "/usr/bin:/bin"], currentDirectory: "/", closeInheritedDescriptors: true),
              let start = parent.startTime else { check(false, "身分替身開不起來"); return }
        defer { OSSocketCaller.unregisterExternalAI(pid: parent.pid); parent.terminateGroup() }
        OSSocketCaller.registerExternalAI(pid: parent.pid, startTime: start, thread: HandsGatewayLaunch.unboundThread)
        guard OSSocketCaller.currentRoots()[parent.pid] != nil else {
            skip("身分替身：登記的 pid 本人是外部 AI")
            skip("身分替身：外部 AI 開的子行程一律 .other")
            skip("身分替身：解除登記後就是 .other")
            return
        }
        var child: pid_t?
        _ = waitUntil(3) {
            child = childPIDs(of: parent.pid).first
            return child != nil
        }
        let roots = OSSocketCaller.currentRoots()
        check(OSSocketCaller.classify(pid: parent.pid, roots: roots).label.hasPrefix("externalAI"), "登記的 pid 本人是外部 AI")
        check(child.map { OSSocketCaller.classify(pid: $0, roots: roots).label.hasPrefix("other") } ?? false, "外部 AI 開的子行程一律 .other（不沿用身分）")
        OSSocketCaller.unregisterExternalAI(pid: parent.pid)
        check(OSSocketCaller.classify(pid: parent.pid, roots: OSSocketCaller.currentRoots()).label.hasPrefix("other"), "解除登記後就是 .other")
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).filter { $0.kp_eproc.e_ppid == pid }.map { $0.kp_proc.p_pid }
    }

    // MARK: 5. 真的起關口（Seatbelt）＋假 cloudflared
    /// 扮演 cloudflared 的 Node：要是「非系統程式」（環境從外面讀得到，跟真的 cloudflared 一樣），
    /// 而且不在家目錄或外接卷裡（cloudflared.sb 擋這兩處）。用 Homebrew 的。
    static func fakeCloudflaredNode() -> URL? {
        let home = HandsGatewayLaunch.realPath(HandsGatewayLaunch.accountHome()) ?? HandsGatewayLaunch.accountHome()
        // Studio 可用 TATWO 自己的 runtime；仍須在帳戶家目錄、外接碟與系統程式以外。
        let runtimeNode = EnginePaths().runtimeBinDirectory.appendingPathComponent("node").path
        for candidate in [runtimeNode, "/opt/homebrew/bin/node", "/usr/local/bin/node"] where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let real = HandsGatewayLaunch.realPath(candidate), !real.hasPrefix(home + "/"), !real.hasPrefix("/Volumes/"),
                  !real.hasPrefix("/System/"), !real.hasPrefix("/usr/bin/") else { continue }
            return URL(fileURLWithPath: real)
        }
        return nil
    }

    /// 假 cloudflared（在 cloudflared.sb 裡跑）：讀 --token-file、把自己的 pid、環境變數「名稱」、有沒有拿到 canary fd 寫進自己的 HOME，
    /// 印「已連上」、一直等。
    static func fakeCloudflaredScript(canaryFD: Int32) -> String {
        """
        const fs = require('fs');
        const argv = process.argv;
        const at = argv.indexOf('--token-file');
        let token = 'missing';
        if (at > 0) { try { token = fs.readFileSync(argv[at + 1], 'utf8').length > 0 ? 'read' : 'empty'; } catch (e) { token = String(e.code); } }
        let fd = 'closed';
        try { fs.fstatSync(\(canaryFD)); fd = 'OPEN'; } catch (e) { fd = String(e.code); }
        fs.writeFileSync(process.env.HOME + '/probe.json', JSON.stringify({ pid: process.pid, token: token, fd: fd, env: Object.keys(process.env).sort() }));
        process.stderr.write('INF Registered tunnel connection connIndex=0\\n');
        setInterval(function () {}, 1 << 30);
        """
    }

    private struct Probe: Decodable {
        let pid: Int32
        let token: String
        let fd: String
        let env: [String]
    }

    private static func readProbe(_ home: URL) -> Probe? {
        (try? Data(contentsOf: home.appendingPathComponent("probe.json"))).flatMap { try? JSONDecoder().decode(Probe.self, from: $0) }
    }

    static func findNode() -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates = [EnginePaths().runtimeBinDirectory.appendingPathComponent("node").path, "/opt/homebrew/bin/node", "/usr/local/bin/node"]
        if let bin = env["TATWO2_RUNTIME_BIN"], !bin.isEmpty { candidates.insert(bin + "/node", at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// 這份原始碼所在的 repo（自測只在 debug 建置跑，程式在 Engines/chatgpt-hands）。
    static func repoProgramDirectory() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Engines/chatgpt-hands", isDirectory: true)
    }

    private static func httpStatus(socketPath: String, _ request: String) -> Int? {
        guard let fd = HandsGatewayLaunch.connectUnix(socketPath, timeout: 5) else { return nil }
        defer { close(fd) }
        let bytes = Array(request.utf8)
        guard bytes.withUnsafeBufferPointer({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else { return nil }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            response.append(contentsOf: chunk.prefix(count))
            if response.count > 65_536 { break }
        }
        let head = String(decoding: response.prefix(32), as: UTF8.self)
        let parts = head.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    /// KERN_PROCARGS2：行程真正拿到的 argv 與環境變數（驗「沒有多餘變數」「token 不在 argv」）。
    private static func argumentsAndEnvironment(_ pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        var start = index
        while index < size {
            if buffer[index] == 0 {
                strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        let arguments = Array(strings.prefix(argc))
        var environment: [String] = []
        for item in strings.dropFirst(argc) {
            if item.isEmpty { break }
            environment.append(item)
        }
        return (arguments, environment)
    }

    /// proc_pidinfo：行程開著的每一個 fd，vnode 的連同路徑（驗 App 的 canary fd 沒被繼承，v3 V8）。
    private static func openDescriptors(_ pid: pid_t) -> [(fd: Int32, path: String)]? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return nil }
        var out: [(fd: Int32, path: String)] = []
        for item in fds.prefix(Int(used) / stride) {
            var entry: (fd: Int32, path: String) = (item.proc_fd, "")
            if item.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let got = proc_pidfdinfo(pid, item.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                if got == Int32(MemoryLayout<vnode_fdinfowithpath>.size) {
                    entry.path = withUnsafeBytes(of: info.pvip.vip_path) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
                }
            }
            out.append(entry)
        }
        return out
    }

    private static func endToEnd(_ check: (Bool, String) -> Void, _ skip: (String) -> Void) {
        guard let node = findNode() else { check(false, "找不到 Node（內附 runtime 或 Homebrew），關口實跑沒有驗"); return }
        guard let fakeCloudflared = fakeCloudflaredNode() else {
            check(false, "找不到家目錄外的 Homebrew Node 來扮演 cloudflared（要非系統程式才驗得到環境），通道實跑沒有驗"); return
        }
        let program = repoProgramDirectory()
        guard FileManager.default.fileExists(atPath: program.appendingPathComponent("gateway.mjs").path) else {
            check(false, "找不到 Engines/chatgpt-hands，關口實跑沒有驗"); return
        }
        let root = tempRoot("w183e")
        let hands = root.appendingPathComponent("hands", isDirectory: true)
        let recorder = Recorder()
        let permit = HandsLocked(true)
        let workspaceProblem = HandsLocked<String?>(nil)
        let token = "tunnel-CANARY-" + String(repeating: "k", count: 40)
        setenv("W183_APP_CANARY", "app-env-CANARY", 1)
        // App 的 fd canary（v3 V8）：一個沒設 CLOEXEC 的檔案放在 200 號。關口與 cloudflared 都不該拿到。
        let canaryFile = root.appendingPathComponent("fd-canary.txt")
        let canaryFD: Int32 = 200
        FileManager.default.createFile(atPath: canaryFile.path, contents: Data("FD-CANARY".utf8))
        let rawCanary = open(canaryFile.path, O_RDONLY)
        _ = dup2(rawCanary, canaryFD)
        if rawCanary >= 0 && rawCanary != canaryFD { close(rawCanary) }
        _ = fcntl(canaryFD, F_SETFD, 0)
        var service: ChatGPTHandsService?
        defer {
            if let service { service.stop(); _ = service.debugPhase }
            close(canaryFD)
            unsetenv("W183_APP_CANARY")
            try? FileManager.default.removeItem(at: root)
        }
        let osSocket = root.appendingPathComponent("o.sock").path
        let script = fakeCloudflaredScript(canaryFD: canaryFD)
        do {
            try writeSettings(hands, enabled: true)
            try seedRanges(hands)
            var deps = ChatGPTHandsService.Dependencies()
            deps.environment = ProcessInfo.processInfo.environment
            deps.allowUnderTest = true
            deps.handsRoot = hands
            deps.hostConfirmed = { _ in permit.get() }
            deps.prepareWorkspace = { workspaceProblem.get() }
            deps.programDirectory = program
            deps.node = node
            deps.osSocket = osSocket
            deps.cloudflared = { fakeCloudflared }
            deps.tunnelProgramPrefix = ["-e", script]
            deps.localDeviceID = { "device-test-1" }
            deps.tunnelToken = MemoryToken(value: token)
            deps.fetchRanges = { $0(.failure(HandsGatewayLaunch.Failure.invalidList)) }   // 不上網
            // 真的登記（R1 合併後就是真的身分）＋記下來給自測看。
            deps.register = { pid, start in
                recorder.add(pid, start)
                OSSocketCaller.registerExternalAI(pid: pid, startTime: start, thread: HandsGatewayLaunch.unboundThread)
            }
            deps.unregister = { pid in recorder.remove(pid); OSSocketCaller.unregisterExternalAI(pid: pid) }
            deps.restartDelay = 0.5
            deps.monitorInterval = 1
            service = ChatGPTHandsService(dependencies: deps)
        } catch { check(false, "實跑準備失敗 \(error)"); return }
        guard let service else { return }
        let url = "https://hands.example.com/mcp"
        service.startIfEnabled()
        let running = waitUntil(25) { service.debugPhase == .running(url: url) }
        check(running, "關口在 Seatbelt 裡起來、健康、通道回報已連上 → 運作中＋網址（實際 \(service.debugPhase)）")
        guard running, let gateway = service.debugProcesses.gateway, let tunnel = service.debugProcesses.tunnel else { return }
        let paths = HandsGatewayLaunch.Paths(root: URL(fileURLWithPath: HandsGatewayLaunch.realPath(hands.path) ?? hands.path, isDirectory: true))

        // v3 V8 啟動順序。
        let log = service.debugLaunchLog
        let expected = ["dirs", "gateway_spawned:\(gateway.pid)", "registered:\(gateway.pid)", "gateway_healthy:403", "tunnel_spawned:\(tunnel.pid)"]
        check(Array(log.prefix(5)) == expected, "啟動順序：預建資料夾 → 開關口 → 登記關口 pid → 關口健康 → 最後才開 cloudflared（實際 \(log)）")
        var info = stat()
        check(stat(paths.socketDir.path, &info) == 0 && (info.st_mode & 0o777) == 0o700 && lstat(paths.socket.path, &info) == 0
              && (info.st_mode & S_IFMT) == S_IFSOCK && (info.st_mode & 0o777) == 0o600, "socket 資料夾由 App 預建 0700；socket 0600")

        // v2 §1 拓樸：兩個兄弟、登記的是關口 pid、cloudflared 不是外部 AI。
        let registered = recorder.all.last
        check(recorder.all.count == 1 && registered?.0 == gateway.pid && registered?.1 == OSSocketCaller.processStartTime(gateway.pid)
              && OSSocketCaller.parentPID(of: gateway.pid) == getpid() && OSSocketCaller.executablePath(gateway.pid)?.hasSuffix("/node") == true,
              "登記的是關口 pid：App 直接開、sandbox-exec 已換成 node（pid 不變）、啟動時間對得上")
        _ = waitUntil(3) { readProbe(paths.cloudflaredHome) != nil }
        let probe = readProbe(paths.cloudflaredHome)
        check(gateway.pgid != tunnel.pgid && OSSocketCaller.parentPID(of: tunnel.pid) == getpid()
              && probe.map { OSSocketCaller.parentPID(of: $0.pid) == tunnel.pid } == true,
              "cloudflared（連同看門程式）是關口的兄弟：另一組、上一層是 App，不是關口的子行程")
        if let probe {
            let roots = OSSocketCaller.currentRoots()
            check(!recorder.all.contains(where: { $0.0 == probe.pid || $0.0 == tunnel.pid }), "cloudflared 替身與看門程式沒有登記")
            if roots[gateway.pid] != nil {
                // 登記真的生效時，「cloudflared 是 .other」才不是空驗（空殼時根本沒有任何行程是外部 AI，一定成立）。
                check(OSSocketCaller.classify(pid: gateway.pid, roots: roots).label.hasPrefix("externalAI"), "關口 pid 被認成外部 AI")
                check(OSSocketCaller.classify(pid: probe.pid, roots: roots).label.hasPrefix("other")
                      && OSSocketCaller.classify(pid: tunnel.pid, roots: roots).label.hasPrefix("other"),
                      "cloudflared 替身與看門程式 os.sock 認成 .other（不是外部 AI）")
            } else {
                skip("關口 pid 被認成外部 AI")
                skip("cloudflared 替身與看門程式 os.sock 認成 .other（空殼時一定成立＝空驗）")
            }
        } else { check(false, "假 cloudflared 沒回報") }

        // v3 V8：App 的 fd 一個都不給（POSIX_SPAWN_CLOEXEC_DEFAULT）。先證明偵測本身有效：App 自己看得到 canary。
        let mine = openDescriptors(getpid()) ?? []
        check(mine.contains { $0.fd == canaryFD && $0.path.hasSuffix("fd-canary.txt") }, "fd canary 偵測有效：App 自己開著 200 號 canary")
        var fdTargets: [(String, pid_t)] = [("關口", gateway.pid), ("看門程式", tunnel.pid)]
        if let probe { fdTargets.append(("cloudflared 替身", probe.pid)) }
        for (label, pid) in fdTargets {
            if let fds = openDescriptors(pid) {
                check(!fds.contains { $0.fd == canaryFD || $0.path.hasSuffix("fd-canary.txt") } && !fds.isEmpty,
                      "\(label)拿不到 App 的 canary fd（它開著 \(fds.count) 個 fd，沒有 200 號、沒有 canary 檔）")
            } else { check(false, "讀不到\(label)的 fd 清單") }
        }
        check(probe?.fd == "EBADF", "cloudflared 替身自己試 fstat(200) 也是 EBADF（實際 \(probe?.fd ?? "沒回報")）")
        check(gateway.debugAppSideDescriptorsCloseOnExec && tunnel.debugAppSideDescriptorsCloseOnExec,
              "App 這一端的 pipe 都設了 FD_CLOEXEC（之後開的其他子行程拿不到，App 當掉時兩組才收得到 EOF）")

        // v2 §2 端點矩陣（打真的關口）。同一個使用者的程式能直接連 socket、偽造來源 IP——但沒有 token 拿不到工具（殘餘風險 V16）。
        let base = "Host: hands.example.com\r\nConnection: close\r\n"
        let socket = paths.socket.path
        check(httpStatus(socketPath: socket, "GET /.well-known/oauth-protected-resource HTTP/1.1\r\n\(base)CF-Connecting-IP: 203.0.113.9\r\n\r\n") == 200,
              "OpenAI 的 IP＋對的 Host：拿得到 metadata（殘餘：同一個使用者也偽造得了這個標頭）")
        check(httpStatus(socketPath: socket, "GET /.well-known/oauth-protected-resource HTTP/1.1\r\n\(base)CF-Connecting-IP: 198.51.100.7\r\n\r\n") == 403,
              "其他 IP：403")
        let query = "response_type=code&client_id=hc_1&redirect_uri=https%3A%2F%2Fchat.example.com%2Fcb&code_challenge=\(String(repeating: "a", count: 43))&code_challenge_method=S256&state=s"
        let page = httpStatus(socketPath: socket, "GET /authorize?\(query) HTTP/1.1\r\n\(base)CF-Connecting-IP: 198.51.100.7\r\n\r\n")
        check(page != nil && page != 403 && httpStatus(socketPath: socket, "POST /token HTTP/1.1\r\n\(base)CF-Connecting-IP: 198.51.100.7\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 0\r\n\r\n") == 403,
              "使用者瀏覽器的 IP：授權頁進得去（這裡沒有 App 的 os.sock，回 \(page.map { "\($0)" } ?? "無")），/token 仍然 403")
        check(httpStatus(socketPath: socket, "POST /mcp HTTP/1.1\r\n\(base)CF-Connecting-IP: 203.0.113.9\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}") == 401,
              "偽造來源 IP 的同使用者程式：沒有 token 就 401（拿不到工具）")
        // 清單過期 7 天：關口全拒（不用重開）；換回來就恢復。
        if var document = HandsGatewayLaunch.readGatewayDocument(paths.gatewayConfig) {
            let fresh = document.rangesFetchedAt
            document.rangesFetchedAt = HandsGatewayLaunch.timestamp(Date().addingTimeInterval(-8 * 86400))
            try? HandsGatewayLaunch.writeGatewayDocument(document, to: paths.gatewayConfig)
            usleep(2_300_000)
            let stale = httpStatus(socketPath: socket, "GET /.well-known/oauth-protected-resource HTTP/1.1\r\n\(base)CF-Connecting-IP: 203.0.113.9\r\n\r\n")
            let staleAuthorize = httpStatus(socketPath: socket, "GET /authorize?\(query) HTTP/1.1\r\n\(base)CF-Connecting-IP: 198.51.100.7\r\n\r\n")
            document.rangesFetchedAt = fresh
            try? HandsGatewayLaunch.writeGatewayDocument(document, to: paths.gatewayConfig)
            usleep(2_300_000)
            let back = httpStatus(socketPath: socket, "GET /.well-known/oauth-protected-resource HTTP/1.1\r\n\(base)CF-Connecting-IP: 203.0.113.9\r\n\r\n")
            check(stale == 403 && staleAuthorize == 403 && back == 200, "清單過期 7 天：metadata 與授權頁都 403；換回新清單就恢復（實際 \(String(describing: stale))/\(String(describing: staleAuthorize))/\(String(describing: back))）")
        } else { check(false, "讀不到 config.json") }

        // 環境與秘密。
        if let gatewayProcess = argumentsAndEnvironment(gateway.pid) {
            let gatewayKeys = Set(gatewayProcess.environment.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
            check(gatewayKeys == ["PATH", "HOME", "LANG", "TATWO2_OS_SOCKET"], "關口行程的環境沒有多餘變數（實際 \(gatewayKeys.sorted())）")
            let everything = (gatewayProcess.arguments + gatewayProcess.environment).joined(separator: "\n")
            check(!everything.contains(token) && !everything.contains("app-env-CANARY") && !everything.contains("TUNNEL_TOKEN"),
                  "關口的 argv／環境沒有通道 token、App 的其他環境變數沒有流過去")
        } else { check(false, "讀不到關口行程的 argv／環境") }
        check(probe?.token == "read", "cloudflared 讀得到 --token-file（實際 \(probe?.token ?? "沒回報")）")
        if let probe, let cloudflaredProcess = argumentsAndEnvironment(probe.pid), !cloudflaredProcess.environment.isEmpty {
            let keys = Set(cloudflaredProcess.environment.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
                .subtracting(["PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"])   // 看門的 /bin/sh 與系統自己會加這幾個（都不是秘密）
            let everything = (cloudflaredProcess.arguments + cloudflaredProcess.environment).joined(separator: "\n")
            check(keys == ["HOME", "PATH"] && !everything.contains(token) && !everything.contains("TUNNEL_TOKEN") && !everything.contains("app-env-CANARY"),
                  "cloudflared 行程（KERN_PROCARGS2 實讀）：環境只有 HOME／PATH，argv 與環境都沒有 token（實際 \(keys.sorted())）")
            check(getpgid(probe.pid) == tunnel.pgid, "cloudflared 和看門程式同一個行程群組")
        } else { check(false, "讀不到 cloudflared 行程的 argv／環境（KERN_PROCARGS2）") }
        check(waitUntil(3) { HandsGatewayLaunch.tokenFiles(in: paths.cloudflaredHome).isEmpty }, "連上之後 token 檔立刻刪掉")
        _ = waitUntil(2) { (try? String(contentsOf: paths.logFile, encoding: .utf8))?.contains(" GET prm 200 ") == true }
        let logText = (try? String(contentsOf: paths.logFile, encoding: .utf8)) ?? ""
        check(logText.contains(" GET prm 200 ") && logText.split(separator: "\n").allSatisfy {
            $0.range(of: #"^\d{4}-\d\d-\d\dT[\d:]+Z [A-Z]+ [a-z_]+ \d{3} \d+ms( [a-z/]+)?$"#, options: .regularExpression) != nil
                || $0.range(of: #"^\d{4}-\d\d-\d\dT[\d:]+Z restart reason=(enabled|permit_restored|transient_retry|user_retry|retry_keeping_safety|settings_changed|gateway_exit|tunnel_exit) result=(begin|running|temporary_failure|latched_failure|stopped|process_exit)$"#, options: .regularExpression) != nil
        }, "關口日誌由 App 寫進 logs/gateway.log：請求固定欄位；W185 重啟只有時間、白名單原因與結果")
        let files = [paths.gatewayConfig, paths.cloudflaredConfig, paths.logFile, paths.cloudflaredHome.appendingPathComponent("probe.json")]
        let leaked = files.contains { (try? String(contentsOf: $0, encoding: .utf8))?.contains(token) == true }
        check(!leaked, "token 沒有落在 config.json／cf.yml／日誌")
        check(((try? FileManager.default.contentsOfDirectory(atPath: paths.socketDir.path)) ?? []) == ["gw.sock"]
              && Set((try? FileManager.default.contentsOfDirectory(atPath: paths.gatewayDir.path)) ?? []) == ["config.json", "sock"],
              "關口沒有寫任何檔案（socket 資料夾只有 socket，設定資料夾只有 App 寫的 config.json）")

        // 任一個停掉：兩個一起收（先 cloudflared、解除登記、再關口），然後自動重開。殺的是真正的（假）cloudflared。
        if let probe { kill(probe.pid, SIGKILL) } else { kill(tunnel.pid, SIGKILL) }
        check(waitUntil(8) { !alive(gateway.pid) && !SidecarGroupedProcess.groupIsAlive(tunnel.pgid) }, "cloudflared 被殺 → 看門程式與關口也一起收掉")
        let stopLog = service.debugLaunchLog.dropFirst(5)
        let stopExpected = ["tunnel_stopped:\(tunnel.pid)", "unregistered:\(gateway.pid)", "gateway_stopped:\(gateway.pid)"]
        check(Array(stopLog.prefix(3)) == stopExpected && recorder.unregistered.first == gateway.pid,
              "退出順序：先停 cloudflared → 解除登記 → 再停關口（實際 \(Array(stopLog.prefix(3)))）")
        let restarted = waitUntil(25) {
            if let next = service.debugProcesses.gateway { return next.pid != gateway.pid && service.debugPhase == .running(url: url) }
            return false
        }
        check(restarted && recorder.all.count == 2, "整組自動重開一次（重新登記新的關口 pid）")

        let beforePause = service.debugProcesses.gateway?.pid
        permit.set(false); service.debugEvaluate()
        workspaceProblem.set("暫時讀不到工作區")
        permit.set(true); service.debugEvaluate()
        let temporaryRecorded = service.debugRetryAt != nil
        permit.set(false); service.debugEvaluate()
        workspaceProblem.set(nil)
        permit.set(true); service.debugEvaluate()
        check(temporaryRecorded && waitUntil(25) { service.debugPhase == .running(url: url) }
              && service.debugProcesses.gateway?.pid != beforePause && service.debugCrashCount == 0,
              "W185 真行程：許可恢復後 prepare 暫時失敗，再次 paused → active 無改設定立即重開關口與通道")
        let lifecycle = (try? String(contentsOf: paths.logFile, encoding: .utf8)) ?? ""
        check(lifecycle.contains("reason=permit_restored result=running") && !lifecycle.contains(token),
              "W185 真行程：許可恢復重啟成功記錄原因與結果、不含 token")

        // W183 R2b：同一個使用者的程式把關口的 socket 換成自己的 listener（殘餘風險 V16 的攻擊手法）：關口自己（每 0.5 秒）或
        // App（每次定時檢查）發現後整組停下、寫明原因、不自動重開；使用者按重試才再開。
        if restarted, let swappedGateway = service.debugProcesses.gateway, let swappedTunnel = service.debugProcesses.tunnel {
            let moved = paths.socket.path + ".moved"
            let renamed = rename(paths.socket.path, moved) == 0
            let fake = renamed ? listenUnix(paths.socket.path) : nil
            let stoppedBySwap = waitUntil(10) {
                service.debugPhase == .failed(ChatGPTHandsService.tamperedText) && !alive(swappedGateway.pid)
                    && !SidecarGroupedProcess.groupIsAlive(swappedTunnel.pgid)
            }
            _ = waitUntil(2.5) { false }   // 給自動重開足夠時間（restartDelay 0.5 秒、monitor 1 秒）——它不該發生
            check(renamed && fake != nil && stoppedBySwap && service.debugProcesses.gateway == nil
                  && service.debugPhase == .failed(ChatGPTHandsService.tamperedText),
                  "關口的 socket 被換成別的程式的 listener → 關口與 cloudflared 都停、狀態寫明、不自動重開（實際 \(service.debugPhase)）")
            if let fake { close(fake) }
            unlink(paths.socket.path); unlink(moved)
            service.retry()
            check(waitUntil(25) { service.debugPhase == .running(url: url) }, "清掉冒充的 socket、按重試 → 又起來")
        } else { check(false, "socket 冒充測試：前一步沒有重開成功，無法測") }

        // 開關關掉：定時檢查看到就停，socket 也清掉。
        let before = service.debugProcesses
        do { try writeSettings(hands, enabled: false) } catch { check(false, "寫設定失敗"); return }
        let stopped = waitUntil(10) {
            service.debugPhase == .stopped && service.debugProcesses.gateway == nil
                && !(before.gateway.map { alive($0.pid) } ?? false) && !(before.tunnel.map { SidecarGroupedProcess.groupIsAlive($0.pgid) } ?? false)
        }
        check(stopped, "開關關掉 → 關口與 cloudflared 都停")
        check(before.gateway.map { recorder.unregistered.contains($0.pid) } ?? false, "開關關掉也解除登記")
        check(waitUntil(3) { !FileManager.default.fileExists(atPath: paths.socket.path) }, "關口收掉時清掉自己的 socket")
        check(HandsGatewayLaunch.tokenFiles(in: paths.cloudflaredHome).isEmpty, "停下來後沒有留下 token 檔")

        appCrashChecks(check, paths: paths, program: program, node: node, fakeCloudflared: fakeCloudflared, osSocket: osSocket, script: script)

        // cloudflared 不在：清楚回報「還沒安裝」，不起任何東西。
        do {
            try writeSettings(hands, enabled: true)
            var deps = service.dependencies
            deps.cloudflared = { nil }
            deps.monitorInterval = 3600
            let missing = ChatGPTHandsService(dependencies: deps)
            missing.debugEvaluate()
            check(ChatGPTHandsService.statusText(missing.debugPhase).contains("可能還沒安裝")
                  && missing.debugRetryAt != nil && missing.debugProcesses.gateway == nil,
                  "cloudflared 不在或讀不到：回報檔案與雜湊檢查失敗、退避、不起關口")
        } catch { check(false, "缺 cloudflared 檢查準備失敗 \(error)") }

        // App 結束（最後做：之後這個行程不能再開任何 sidecar）：terminateAll 收掉兩組後，服務不能把它當成當機又重開。
        let back = waitUntil(25) { service.debugPhase == .running(url: url) }
        check(back, "開關打開 → 又起來（準備驗 App 結束）")
        let last = service.debugProcesses
        SidecarGroupedProcess.terminateAll()
        let gone = waitUntil(6) {
            !(last.gateway.map { alive($0.pid) } ?? false) && !(last.tunnel.map { SidecarGroupedProcess.groupIsAlive($0.pgid) } ?? false)
        }
        _ = waitUntil(3) { false }   // 給「重開」足夠時間（restartDelay 0.5 秒、monitor 1 秒）——它不該發生
        let after = service.debugProcesses
        let respawned = [after.gateway, after.tunnel].compactMap { $0 }.contains { process in
            process.pid != last.gateway?.pid && process.pid != last.tunnel?.pid && alive(process.pid)
        }
        check(gone && !respawned && service.debugPhase != .running(url: url), "App 結束途中：兩組都收掉，服務不重開")
        check(SidecarGroupedProcess.isTerminating
              && (try? SidecarGroupedProcess.spawn(executable: "/usr/bin/true", arguments: [], environment: [:], currentDirectory: "/")) == nil,
              "App 結束途中不再開新的子行程")
        do { try writeSettings(hands, enabled: false) } catch {}
    }

    /// 模擬 App 當掉：App 這一端的 stdin 一關（真的當掉時核心會關掉 App 所有的 fd），關口與看門程式＋cloudflared 兩組都要自己收，
    /// 看門程式也要刪掉 token 檔。直接用服務同一套開法（spawnGateway／spawnTunnel），不經服務（服務看到結束會自己收，就分不出是誰收的）。
    private static func appCrashChecks(_ check: (Bool, String) -> Void, paths: HandsGatewayLaunch.Paths, program: URL, node: URL,
                                       fakeCloudflared: URL, osSocket: String, script: String) {
        guard let programReal = HandsGatewayLaunch.realPath(program.path), let nodeReal = HandsGatewayLaunch.realPath(node.path),
              let socketReal = HandsGatewayLaunch.realPath(osSocket),
              let gatewayProfile = try? String(contentsOf: program.appendingPathComponent("gateway.sb"), encoding: .utf8),
              let tunnelProfile = try? String(contentsOf: program.appendingPathComponent("cloudflared.sb"), encoding: .utf8),
              let guardScript = try? String(contentsOf: program.appendingPathComponent("tunnel-guard.sh"), encoding: .utf8) else {
            check(false, "App 當掉模擬：準備失敗"); return
        }
        var gateway: SidecarGroupedProcess?
        var tunnel: SidecarGroupedProcess?
        defer { gateway?.terminateGroup(); tunnel?.terminateGroup() }
        let tokenFile = paths.newTunnelTokenFile()
        do {
            try? FileManager.default.removeItem(at: paths.cloudflaredHome.appendingPathComponent("probe.json"))
            let gatewayLaunch = try HandsGatewayLaunch.gatewayLaunch(profile: gatewayProfile, node: nodeReal, programDir: programReal, paths: paths, osSocket: socketReal)
            gateway = try HandsGatewayLaunch.spawnGateway(gatewayLaunch, paths: paths, osSocket: socketReal)
            try HandsGatewayLaunch.writeTokenFile("tunnel-CANARY-" + String(repeating: "c", count: 40), to: tokenFile)
            let userHome = HandsGatewayLaunch.realPath(HandsGatewayLaunch.accountHome()) ?? HandsGatewayLaunch.accountHome()
            let tunnelLaunch = try HandsGatewayLaunch.cloudflaredLaunch(profile: tunnelProfile, guardScript: guardScript, cloudflared: fakeCloudflared.path,
                                                                        paths: paths, tokenFile: tokenFile, userHome: userHome,
                                                                        programPrefix: ["-e", script])
            tunnel = try HandsGatewayLaunch.spawnTunnel(tunnelLaunch, paths: paths)
        } catch { check(false, "App 當掉模擬：開不起來 \(error)"); return }
        guard let gatewayProcess = gateway, let tunnelProcess = tunnel else { return }
        let up = waitUntil(15) { FileManager.default.fileExists(atPath: paths.socket.path) && readProbe(paths.cloudflaredHome) != nil }
        check(up, "App 當掉模擬：關口與假 cloudflared 都起來了")
        gatewayProcess.debugCloseStdin()
        tunnelProcess.debugCloseStdin()
        let ended = waitUntil(8) { !SidecarGroupedProcess.groupIsAlive(gatewayProcess.pgid) && !SidecarGroupedProcess.groupIsAlive(tunnelProcess.pgid) }
        check(ended, "App 當掉（stdin 關閉）→ 關口、看門程式、cloudflared 兩組都自己結束，不留孤兒")
        check(!FileManager.default.fileExists(atPath: tokenFile.path), "App 當掉時看門程式也刪掉 token 檔")
    }

    #endif
}
