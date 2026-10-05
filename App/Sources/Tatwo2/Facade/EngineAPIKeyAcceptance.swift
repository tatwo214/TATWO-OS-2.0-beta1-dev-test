#if DEBUG
import AppKit
import Combine
import Foundation

/// W181 R3 自測（`TATWO2_SELFTEST=w181apikey`，只在 lead-verify 的完整隔離 staging 跑）：
/// 「不用 API 金鑰」只擋按量計費的 API 金鑰，訂閱登入照常能跑。
/// 用假的引擎根目錄與登入檔、假的 `claude auth status`、假的引擎程式；不碰真的登入、不啟動真的模型。
/// 使用者的 `tatwo2.disabledEngines` 只用暫時覆寫（argument domain），前後不變。
@MainActor
enum EngineAPIKeyAcceptance {
    private final class Tally {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W181APIKEY \(condition ? "PASS" : "FAIL") \(label)")
        }
    }

    private struct Fixture {
        let root: URL
        let engines: URL
        let paths: EnginePaths
        let environment: [String: String]
        let claudeStatus: URL
        let claudeLog: URL
        /// 有這個檔，假 claude 先睡檔裡寫的秒數（驗主執行緒不等、逾時）。
        let claudeDelay: URL
    }

    static let disableKey = "tatwo2.disabledEngines"
    static let subscriptionCodex = #"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"access_token":"fixture-access","refresh_token":"fixture-refresh","account_id":"fixture"}}"#
    static let apiKeyCodex = #"{"auth_mode":"apikey","OPENAI_API_KEY":"fixture-not-a-real-key"}"#
    static let subscriptionClaude = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
    static let apiKeyClaude = #"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"ANTHROPIC_API_KEY"}"#
    static let subscriptionGrok = #"{"https://auth.example::fixture":{"auth_mode":"oidc","principal_type":"User","refresh_token":"fixture-refresh"}}"#
    static let apiKeyGrok = #"{"https://auth.example::fixture":{"auth_mode":"api_key","key":"fixture-not-a-real-key"}}"#

    static func run() async throws -> Bool {
        let t = Tally()
        defer { print("W181APIKEY SUMMARY failures=\(t.failed) passed=\(t.passed)") }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let stagingPath = env["TATWO_STAGING_ROOT"], let livePath = env["TATWO2_LIVE_ROOT"] else {
            t.check(false, "needs the isolated staging environment (lead-verify)")
            return false
        }
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.path + "/"
        guard URL(fileURLWithPath: livePath).standardizedFileURL.path.hasPrefix(staging) else {
            t.check(false, "live root must be inside the staging root")
            return false
        }
        let defaults = UserDefaults.standard
        let disableBefore = defaults.stringArray(forKey: disableKey)
        let savedArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let envKeys = ["OPENAI_API_KEY", "CODEX_API_KEY", "W181_SIDECAR_LOG", "W181_CASE"]
        let savedEnv = envKeys.map { ($0, env[$0]) }
        let fixture = try prepare(live: URL(fileURLWithPath: livePath), env: env)
        EngineAPIKeyPolicy.shared.useForTesting(paths: fixture.paths, environment: fixture.environment, statusTimeout: 2)
        defer {
            EngineAPIKeyPolicy.shared.useForTesting(paths: nil, environment: nil)
            defaults.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
            for (key, value) in savedEnv { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
        }

        try await policyChecks(t, fixture)
        environmentChecks(t)
        try await sendChecks(t, fixture)
        try await modelChecks(t, fixture)

        defaults.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        t.check(defaults.stringArray(forKey: disableKey) == disableBefore,
                "tatwo2.disabledEngines is unchanged (only a volatile override was used)")
        return t.failed == 0
    }

    // MARK: - 假的引擎根目錄、假 claude

    private static func prepare(live: URL, env: [String: String]) throws -> Fixture {
        let fm = FileManager.default
        let root = live.appendingPathComponent("w181-apikey-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let engines = root.appendingPathComponent("engines", isDirectory: true)
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        for dir in [engines.appendingPathComponent("codex"), engines.appendingPathComponent("claude"),
                    engines.appendingPathComponent("grok/.grok")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var fakeEnv = env
        fakeEnv["TATWO2_ENGINES_ROOT"] = engines.path
        fakeEnv["CODEX_HOME"] = engines.path + "/codex"
        fakeEnv["TATWO2_CODEX_SOURCE_HOME"] = engines.path + "/codex"
        fakeEnv["CLAUDE_CONFIG_DIR"] = engines.path + "/claude"
        fakeEnv["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = engines.path + "/claude"
        // 這台環境裡有 Claude 的金鑰變數：查登入方式時一定要先拿掉（假 claude 會記下有沒有看到）。
        fakeEnv["ANTHROPIC_API_KEY"] = "fixture-not-a-real-key"
        let status = root.appendingPathComponent("claude-status.json")
        let log = root.appendingPathComponent("claude-probe.log")
        let delay = root.appendingPathComponent("claude-delay")
        fakeEnv["W181_CLAUDE_STATUS"] = status.path
        fakeEnv["W181_CLAUDE_LOG"] = log.path
        fakeEnv["W181_CLAUDE_DELAY"] = delay.path
        let paths = EnginePaths(environment: fakeEnv, resourceRoot: resources)
        try fm.createDirectory(at: paths.claudeExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        [ -f "$W181_CLAUDE_DELAY" ] && sleep "$(cat "$W181_CLAUDE_DELAY")"
        [ -n "$ANTHROPIC_API_KEY" ] && echo "saw ANTHROPIC_API_KEY" >> "$W181_CLAUDE_LOG"
        echo "probe $1 $2 $CLAUDE_CONFIG_DIR" >> "$W181_CLAUDE_LOG"
        cat "$W181_CLAUDE_STATUS"
        """.write(to: paths.claudeExecutable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.claudeExecutable.path)
        return Fixture(root: root, engines: engines, paths: paths, environment: fakeEnv, claudeStatus: status, claudeLog: log,
                       claudeDelay: delay)
    }

    /// 在背景執行緒跑（Claude 的登入查詢只在背景起子程序；主執行緒的行為另外驗）。
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached { work() }.value
    }

    private static func write(_ text: String?, _ url: URL) {
        if let text { try? Data(text.utf8).write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - (1) 判斷：訂閱／API 金鑰／判斷不出來；沒勾不查

    private static func policyChecks(_ t: Tally, _ f: Fixture) async throws {
        let policy = EngineAPIKeyPolicy.shared
        let codexAuth = f.paths.codexAuth, codexConfig = f.paths.codexHome.appendingPathComponent("config.toml")
        let opted: Set<String> = ["claude", "codex", "grok"]

        write(subscriptionCodex, codexAuth)
        t.check(policy.method(.codex) == .subscription && EngineDisableStore.sendBlockReason(.codex, optedOut: opted) == nil,
                "(1) Codex subscription (auth_mode chatgpt) + opted out → can send")
        write(apiKeyCodex, codexAuth)
        let apiReason = EngineDisableStore.sendBlockReason(.codex, optedOut: opted)
        t.check(policy.method(.codex) == .apiKey && apiReason == EngineAPIKeyPolicy.blockMessage(.codex, .apiKey)
                && apiReason == "OpenAI 在這台只有 API 金鑰登入，你設定了不用 API 金鑰（按量計費），這句沒有送出。要用請在 設定 › 登入 用訂閱帳號登入，或取消這個設定。",
                "(1) Codex API key only + opted out → blocked with the plain explanation")
        write(nil, codexAuth)
        let unknownReason = EngineDisableStore.sendBlockReason(.codex, optedOut: opted)
        t.check(policy.method(.codex) == .unknown && unknownReason == EngineAPIKeyPolicy.blockMessage(.codex, .unknown)
                && unknownReason?.contains("當成 API 金鑰") == true,
                "(1) no login file → unknown → treated as an API key and blocked, with an explanation")
        write("not json", codexAuth)
        t.check(policy.method(.codex) == .unknown, "(1) unreadable login file → unknown")
        write(#"{"auth_mode":"chatgpt","tokens":{}}"#, codexAuth)
        t.check(policy.method(.codex) == .unknown, "(1) chatgpt mode without tokens → unknown")
        write(subscriptionCodex, codexAuth)
        write("model_provider = \"gateway\"\n", codexConfig)
        t.check(policy.method(.codex) == .unknown, "(1) Codex config switches to another provider → unknown")
        write("forced_login_method = \"api\"\n", codexConfig)
        t.check(policy.method(.codex) == .apiKey, "(1) Codex config forces API login → API key")
        write("model = \"x\"\n[profiles.other]\nmodel_provider = \"other\"\n", codexConfig)
        t.check(policy.method(.codex) == .subscription, "(1) provider inside a [section] does not count")
        write(nil, codexConfig)
        var neverBlocks = true
        for state in [subscriptionCodex, apiKeyCodex, nil] {
            write(state, codexAuth)
            neverBlocks = neverBlocks && EngineDisableStore.sendBlockReason(.codex, optedOut: []) == nil
                && EngineDisableStore.sendBlockReason(.codex, optedOut: ["claude", "grok"]) == nil
        }
        t.check(neverBlocks, "(1) not opted out never blocks, whatever the login (old behavior)")

        write(subscriptionGrok, f.paths.grokAuth)
        t.check(policy.method(.grok) == .subscription, "(1) Grok oidc login → subscription")
        write(apiKeyGrok, f.paths.grokAuth)
        t.check(policy.method(.grok) == .apiKey && EngineDisableStore.blocksSend(.grok, optedOut: opted),
                "(1) Grok API key → blocked")
        write("{}", f.paths.grokAuth)
        t.check(policy.method(.grok) == .unknown, "(1) Grok empty login file → unknown")

        // Claude：`claude auth status`（假的）＋設定檔。查詢在背景執行緒跑（主執行緒不起子程序，下面另外驗）。
        write(subscriptionClaude, f.claudeStatus)
        policy.invalidate()
        write(nil, f.claudeLog)
        let subMethod = await offMain { policy.method(.claude) }
        let subReason = await offMain { EngineDisableStore.sendBlockReason(.claude, optedOut: opted) }
        t.check(subMethod == .subscription && subReason == nil,
                "(1) Claude subscription (authMethod claude.ai, firstParty, plan) → can send")
        let probeLog = (try? String(contentsOf: f.claudeLog, encoding: .utf8)) ?? ""
        t.check(probeLog.contains("probe auth status \(f.engines.path)/claude") && !probeLog.contains("saw ANTHROPIC_API_KEY"),
                "(1) the login check runs in the App's own Claude folder without the API key variable")
        write(apiKeyClaude, f.claudeStatus)
        let cached = await offMain { policy.method(.claude) }
        t.check(cached == .subscription, "(1) Claude result is cached for a short while")
        policy.invalidate()
        let apiMethod = await offMain { policy.method(.claude) }
        let apiReason2 = await offMain { EngineDisableStore.sendBlockReason(.claude, optedOut: opted) }
        t.check(apiMethod == .apiKey && apiReason2 == EngineAPIKeyPolicy.blockMessage(.claude, .apiKey),
                "(1) Claude API key → blocked")
        func claudeAfterInvalidate(_ status: String) async -> EngineLoginMethod {
            write(status, f.claudeStatus)
            policy.invalidate()
            return await offMain { policy.method(.claude) }
        }
        let managed = await claudeAfterInvalidate(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","apiKeySource":"/login managed key"}"#)
        t.check(managed == .apiKey, "(1) Claude console-managed key → API key")
        let loggedOut = await claudeAfterInvalidate(#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#)
        t.check(loggedOut == .unknown, "(1) Claude not logged in → unknown")
        let garbage = await claudeAfterInvalidate("garbage")
        t.check(garbage == .unknown, "(1) Claude status unreadable → unknown")
        _ = await claudeAfterInvalidate(subscriptionClaude)
        let userSettings = f.paths.claudeConfigDirectory.appendingPathComponent("settings.json")
        write(#"{"apiKeyHelper":"/bin/echo"}"#, userSettings)
        t.check(policy.method(.claude) == .apiKey,
                "(1) Claude settings with apiKeyHelper → API key at once (read every time, even on the main thread), even when logged in by subscription")
        write(nil, userSettings)
        t.check(EngineAPIKeyPolicy.claudeMethod(status: Data(#"{"loggedIn":true,"authMethod":"third_party"}"#.utf8), settings: []) == .apiKey,
                "(1) Claude through a cloud provider → API key")

        // 主執行緒不等 `claude auth status`（03:41／03:52 兩次「當機」那一類）：先回「還在確認」、背景查，查完通知畫面重畫。
        write("1", f.claudeDelay)
        policy.invalidate()
        var redraws = 0
        let watch = policy.changes.sink { redraws += 1 }
        let started = Date()
        let first = policy.method(.claude)
        let firstReason = EngineDisableStore.sendBlockReason(.claude, optedOut: opted)
        let firstBlocks = EngineDisableStore.blocksSend(.claude, optedOut: opted, allowStale: true)
        let elapsed = Date().timeIntervalSince(started)
        t.check(first == .checking && firstBlocks && firstReason == EngineAPIKeyPolicy.blockMessage(.claude, .checking) && elapsed < 0.5,
                "(1) the main thread never waits for `claude auth status` (\(Int(elapsed * 1000)) ms): first answer is 'still checking'")
        let landed = try await waitUntil(8) { policy.method(.claude) == .subscription }
        t.check(landed && redraws > 0, "(1) the background check lands and tells the screen to redraw")
        watch.cancel()

        // 逾時（上限跟 EngineLogin 一樣 8 秒；這裡測試設 2 秒）：之前沒查到過 → 「暫時查不到」，不說成沒登入；之前查到過 → 沿用。
        write("5", f.claudeDelay)
        policy.invalidate()
        let timedOut = await offMain { policy.refreshClaude() }
        let failedText = EngineAPIKeyPolicy.blockMessage(.claude, .checkFailed)
        t.check(timedOut == .checkFailed && failedText.contains("暫時查不到") && !failedText.contains("沒登入"),
                "(1) Claude check times out with nothing known → 'cannot check right now', not 'not logged in'")
        write(nil, f.claudeDelay)
        policy.invalidate()
        _ = await offMain { policy.refreshClaude() }
        write("5", f.claudeDelay)
        let kept = await offMain { policy.refreshClaude() }
        t.check(kept == .subscription, "(1) a later timeout keeps the last good answer instead of blocking")
        write(nil, f.claudeDelay)
        t.check(EngineAPIKeyPolicy.claudeStatusTimeout == 8, "(1) the real timeout matches EngineLogin (8 s)")

        // 剛勾下時的提示：跟擋送出同一套說法（判斷不出來不說成「只有 API 金鑰」）。
        t.check(EngineAPIKeyPolicy.optOutHint(.grok, .unknown).contains("看不出") && !EngineAPIKeyPolicy.optOutHint(.grok, .unknown).contains("只有 API 金鑰登入")
                && EngineAPIKeyPolicy.optOutHint(.codex, .apiKey).contains("只有 API 金鑰登入")
                && EngineAPIKeyPolicy.optOutHint(.codex, .subscription).contains("訂閱登入照常能用"),
                "(1) the opt-out hint matches the real login (API key / cannot tell / subscription)")
        write(subscriptionCodex, codexAuth)   // 這台的 Codex 是訂閱登入，別台的串照樣擋
        t.check(EngineDisableStore.sendBlockReason(.codex, optedOut: opted, otherDevice: "Primary One")
                == EngineAPIKeyPolicy.otherDeviceMessage(.codex, device: "Primary One")
                && EngineDisableStore.sendBlockReason(.codex, optedOut: [], otherDevice: "Primary One") == nil,
                "(1) a thread on another device is not judged by this device's login: opted out → blocked (names the device); not opted out → as before")
        let project = f.root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        write(#"{"env":{"ANTHROPIC_API_KEY":"fixture-not-a-real-key"}}"#, project.appendingPathComponent(".claude/settings.json"))
        t.check(EngineDisableStore.sendBlockReason(.claude, optedOut: opted, cwd: project.path) == EngineAPIKeyPolicy.claudeProjectMessage
                && EngineDisableStore.sendBlockReason(.claude, optedOut: [], cwd: project.path) == nil
                && EngineDisableStore.sendBlockReason(.claude, optedOut: opted, cwd: f.root.path) == nil,
                "(1) a folder's .claude settings that switch to an API key block only that folder")
    }

    // MARK: - (2) 啟動環境拿掉金鑰；GBrain 不帶被勾那家的金鑰

    private static func environmentChecks(_ t: Tally) {
        let base = ["PATH": "/usr/bin", "OPENAI_API_KEY": "a", "CODEX_API_KEY": "b", "ANTHROPIC_API_KEY": "c", "XAI_API_KEY": "d"]
        var codex = base
        let removed = EngineAPIKeyPolicy.removeAPIKeys(from: &codex, for: .codex, optedOut: ["codex"])
        t.check(Set(removed) == ["OPENAI_API_KEY", "CODEX_API_KEY"] && codex == ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "c", "XAI_API_KEY": "d"],
                "(2) opted-out Codex starts without its API key variables (others untouched)")
        var claude = base
        EngineAPIKeyPolicy.removeAPIKeys(from: &claude, for: .claude, optedOut: ["claude"])
        var grok = base
        EngineAPIKeyPolicy.removeAPIKeys(from: &grok, for: .grok, optedOut: ["grok"])
        t.check(claude["ANTHROPIC_API_KEY"] == nil && grok["XAI_API_KEY"] == nil && claude["OPENAI_API_KEY"] == "a",
                "(2) Claude and Grok drop their own key variables")
        var untouched = base
        let none = EngineAPIKeyPolicy.removeAPIKeys(from: &untouched, for: .codex, optedOut: ["claude", "grok"])
        t.check(none.isEmpty && untouched == base, "(2) not opted out: the environment is exactly the same")

        var reads: [String] = []
        let reader: (String) -> String? = { name in reads.append(name); return "fixture-\(name)" }
        let all = EngineAPIKeyPolicy.gbrainProviderEnvironment(optedOut: [], read: reader)
        t.check(all == ["OPENAI_API_KEY": "fixture-openai", "ANTHROPIC_API_KEY": "fixture-anthropic"],
                "(2) GBrain: nothing opted out → both keys as before")
        reads = []
        let noOpenAI = EngineAPIKeyPolicy.gbrainProviderEnvironment(optedOut: ["codex"], read: reader)
        t.check(noOpenAI == ["ANTHROPIC_API_KEY": "fixture-anthropic"] && reads == ["anthropic"],
                "(2) GBrain: OpenAI opted out → its key is not even read")
        reads = []
        let neither = EngineAPIKeyPolicy.gbrainProviderEnvironment(optedOut: ["codex", "claude"], read: reader)
        t.check(neither.isEmpty && reads.isEmpty, "(2) GBrain: both opted out → no key")
    }

    // MARK: - (3) 真的送出（假的 Codex 引擎程式記下啟動環境與收到的句子）

    private static func sentLines(_ log: URL) -> [[String: Any]] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private static func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func sendChecks(_ t: Tally, _ f: Fixture) async throws {
        let script = f.root.appendingPathComponent("codex-fixture.mjs")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.env.W181_SIDECAR_LOG;
        const keys = ['OPENAI_API_KEY', 'CODEX_API_KEY', 'AZURE_OPENAI_API_KEY'];
        fs.appendFileSync(log, JSON.stringify({ start: process.env.W181_CASE, keys: keys.filter(k => process.env[k] !== undefined) }) + '\n');
        const sdk = msg => console.log(JSON.stringify({ ev: 'sdk', msg }));
        sdk({ type: 'system', subtype: 'init', session_id: 'w181-fixture', model: 'fixture' });
        readline.createInterface({ input: process.stdin }).on('line', line => {
          const c = JSON.parse(line);
          if (c.op === 'send') {
            fs.appendFileSync(log, JSON.stringify({ text: c.text }) + '\n');
            sdk({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: '好的。' } } });
            setTimeout(() => sdk({ type: 'result', subtype: 'success', is_error: false, result: '好的。' }), 30);
          } else if (c.op === 'close') process.exit(0);
        }).on('close', () => process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let log = f.root.appendingPathComponent("codex-sidecar.jsonl")
        setenv("W181_SIDECAR_LOG", log.path, 1)
        // 這台環境裡有 OpenAI 的金鑰變數（假的）：勾了之後啟動的引擎一定看不到。
        setenv("OPENAI_API_KEY", "fixture-not-a-real-key", 1)
        setenv("CODEX_API_KEY", "fixture-not-a-real-key", 1)
        let defaults = UserDefaults.standard
        func override(_ key: String, _ value: Any?) {
            var args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            args[key] = value
            defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        }
        override("tatwo2.sidecarPath.codex", script.path)
        override(disableKey, ["claude", "codex", "grok"])   // 暫時覆寫：使用者的設定檔不寫

        let engine = ChatLiveEngine(store: ChatLiveStore(root: f.root.appendingPathComponent("live")), environment: ProcessInfo.processInfo.environment)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "w181 fixture", workdir: f.root.path)
        func start(_ label: String, _ text: String) -> (UUID, Bool) {
            setenv("W181_CASE", label, 1)
            let id = engine.newThread(in: project, title: label)
            return (id, engine.send(threadID: id, text: text, model: nil, engine: .codex))
        }

        write(subscriptionCodex, f.paths.codexAuth)
        let (subThread, subSent) = start("subscription", "訂閱送得出去")
        let reached = try await waitUntil { sentLines(log).contains { $0["text"] as? String == "訂閱送得出去" } }
        let subStart = sentLines(log).first { $0["start"] as? String == "subscription" }
        t.check(subSent && reached, "(3) opted out + subscription login → the sentence reaches the engine")
        t.check((subStart?["keys"] as? [String])?.isEmpty == true,
                "(3) …and the engine started with no API key variable (OPENAI_API_KEY / CODEX_API_KEY removed)")
        _ = try await waitUntil { !engine.isRunning(subThread) }

        write(apiKeyCodex, f.paths.codexAuth)
        let (apiThread, apiSent) = start("apikey", "只有金鑰不該送")
        try await Task.sleep(for: .milliseconds(300))
        let apiRow = engine.transcript(for: apiThread).last
        t.check(!apiSent && apiRow?.status == "error|不用 API 金鑰" && apiRow?.text == EngineAPIKeyPolicy.blockMessage(.codex, .apiKey)
                && !sentLines(log).contains { $0["text"] as? String == "只有金鑰不該送" || $0["start"] as? String == "apikey" },
                "(3) opted out + API key only → not sent, no engine started, plain explanation in the thread")

        write(nil, f.paths.codexAuth)
        let (unknownThread, unknownSent) = start("unknown", "看不出來不該送")
        let unknownRow = engine.transcript(for: unknownThread).last
        t.check(!unknownSent && unknownRow?.text == EngineAPIKeyPolicy.blockMessage(.codex, .unknown),
                "(3) opted out + login cannot be told → treated as an API key, blocked with an explanation")

        override(disableKey, [String]())
        write(apiKeyCodex, f.paths.codexAuth)
        let (oldThread, oldSent) = start("not-opted", "沒勾照舊")
        let oldReached = try await waitUntil { sentLines(log).contains { $0["text"] as? String == "沒勾照舊" } }
        let oldStart = sentLines(log).first { $0["start"] as? String == "not-opted" }
        t.check(oldSent && oldReached && Set(oldStart?["keys"] as? [String] ?? []) == ["OPENAI_API_KEY", "CODEX_API_KEY"],
                "(3) not opted out → sends exactly as before (key variables left as they were)")
        _ = try await waitUntil { !engine.isRunning(oldThread) }

        // 先沒勾就啟動（帶著金鑰變數）→ 再勾 → 同一條的下一句：舊的引擎不沿用，重開後沒有金鑰變數。
        override(disableKey, ["claude", "codex", "grok"])
        write(subscriptionCodex, f.paths.codexAuth)
        setenv("W181_CASE", "re-opted", 1)
        let reSent = engine.send(threadID: oldThread, text: "勾了之後同一條", model: nil, engine: .codex)
        let reReached = try await waitUntil { sentLines(log).contains { $0["text"] as? String == "勾了之後同一條" } }
        let reStart = sentLines(log).first { $0["start"] as? String == "re-opted" }
        t.check(reSent && reReached && (reStart?["keys"] as? [String])?.isEmpty == true,
                "(3) started before opting out, then opted out → the next sentence restarts the engine without API key variables")
        _ = try await waitUntil { !engine.isRunning(oldThread) }
        setenv("W181_CASE", "reuse", 1)
        let againSent = engine.send(threadID: oldThread, text: "設定沒變再一句", model: nil, engine: .codex)
        let againReached = try await waitUntil { sentLines(log).contains { $0["text"] as? String == "設定沒變再一句" } }
        t.check(againSent && againReached && !sentLines(log).contains { $0["start"] as? String == "reuse" },
                "(3) setting unchanged → the running engine is reused as before (no restart)")
        _ = try await waitUntil { !engine.isRunning(oldThread) }

        // 派到別台的串（sidecar 經 ssh 在那台跑）：這台的 Codex 是訂閱登入，也不拿來判斷那台；勾了就擋、說是別台，不起任何引擎。
        let remoteThread = engine.newThread(in: project, title: "remote")
        engine.configureRoom(threadID: remoteThread, parentThreadID: oldThread, roomBrief: "fixture", engine: "codex",
                             cwdOverride: f.root.path, deviceID: "primary-one")
        setenv("W181_CASE", "remote", 1)
        let remoteSent = engine.send(threadID: remoteThread, text: "別台不該送", model: nil, engine: .codex)
        let remoteRow = engine.transcript(for: remoteThread).last
        t.check(!remoteSent && remoteRow?.text == EngineAPIKeyPolicy.otherDeviceMessage(.codex, device: nil)
                && !sentLines(log).contains { $0["start"] as? String == "remote" || $0["text"] as? String == "別台不該送" },
                "(3) a thread running on another device is not judged by this device's login: opted out → blocked, says so")
    }

    // MARK: - (4) 助理、私訊框、匯入「只能看」都用同一個判斷；副設備的助理仍住主設備

    private static func modelChecks(_ t: Tally, _ f: Fixture) async throws {
        let root = f.root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: ProcessInfo.processInfo.environment)
        defer { engine.shutdownAll() }
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: ProcessInfo.processInfo.environment, botCoreFixture: (engine, BotStore(library: library)))
        let saved = model.disabledEngines
        defer { model.disabledEngines = saved; model.assistantPrimaryTestDouble = nil }

        write(subscriptionCodex, f.paths.codexAuth)
        write(apiKeyGrok, f.paths.grokAuth)
        write(apiKeyClaude, f.claudeStatus)
        let policy = EngineAPIKeyPolicy.shared
        policy.invalidate()
        _ = await offMain { policy.refreshClaude() }   // 跟 App 一開時一樣，先在背景查好
        model.disabledEngines = ["claude", "codex", "grok"]   // 只改這個 model 的記憶體
        t.check(model.isAPIKeyOptedOut(.codex) && !model.isEngineDisabled(.codex)
                && model.isEngineDisabled(.grok) && model.isEngineDisabled(.claude),
                "(4) opted out ≠ blocked: Codex (subscription) runs, Grok and Claude (API key) do not")
        let codexRoute = ChatRouteChoice.all.first { AssistantModelRouting.engineKind(for: $0) == .codex }
        let claudeRoute = ChatRouteChoice.all.first { AssistantModelRouting.engineKind(for: $0) == .claude }
        let options = model.assistantModelOptions
        t.check(codexRoute.map { r in options.contains { $0.route.id == r.id && !$0.isDisabled } } == true
                && claudeRoute.map { r in options.contains { $0.route.id == r.id && $0.isDisabled } } == true,
                "(4) assistant menu: the subscription engine is selectable, the API-key-only one is marked")
        let primary = AssistantPrimaryDevice(id: "primary-one", displayName: "Primary One")
        model.assistantPrimaryTestDouble = (device: primary, engine: { nil }, connecting: { false })
        t.check(!model.coderImportViewOnly, "(4) import: a secondary that can run a model here is not view-only")
        t.check(EngineDisableStore.optOutLabel(.codex, optedOut: model.disabledEngines)?.text == "不用 API 金鑰（訂閱照用）"
                && EngineDisableStore.optOutLabel(.claude, optedOut: model.disabledEngines).map { $0.blocked && $0.text == "不用 API 金鑰（沒訂閱登入，送不出）" } == true
                && EngineDisableStore.optOutLabel(.codex, optedOut: []) == nil,
                "(4) settings / overview line: subscription says 'still used', API-key-only says it cannot send")
        // W181 主導裁決（使用者：mini 關掉也要能用）：三家都勾著「不用 API 金鑰」、主設備連不上，
        // 這台的 Codex 是訂閱登入送得出去 → 助理退回這台、用 Codex 回。
        if case .local = model.assistantPlacement {
            t.check(AssistantModelRouting.engineKind(for: model.assistantRouteChoice) == .codex,
                    "(4) primary unreachable, all three opted out but Codex runs on subscription: the assistant falls back here")
        } else {
            t.check(false, "(4) primary unreachable, all three opted out but Codex runs on subscription: the assistant falls back here")
        }
        model.disabledEngines = ["claude", "grok"]
        if case .local = model.assistantPlacement {
            t.check(AssistantModelRouting.engineKind(for: model.assistantRouteChoice) == .codex,
                    "(4) primary unreachable, one engine not opted out: falls back here as before (W179 F)")
        } else {
            t.check(false, "(4) primary unreachable, one engine not opted out: falls back here as before (W179 F)")
        }
        model.disabledEngines = ["claude", "codex", "grok"]
        var remoteDoc = LiveDocumentRecord()
        _ = remoteDoc.ensureAssistantThread()
        let reachable = AssistantRemoteAcceptanceDouble(doc: remoteDoc)
        model.assistantPrimaryTestDouble = (device: primary, engine: { () -> (any AssistantRemoteEngine)? in reachable },
                                            connecting: { false })
        t.check(model.assistantPlacement.isPrimary, "(4) primary reachable: the assistant still lives on the primary (W179 F unchanged)")
        model.assistantPrimaryTestDouble = (device: primary, engine: { nil }, connecting: { false })

        write(apiKeyCodex, f.paths.codexAuth)
        t.check(model.coderImportViewOnly && CoderImport.viewOnlyHint
                == "這台現在沒有能用的模型（只有 API 金鑰、而你設定不用）：可以看；要接著做，登入訂閱帳號，或右鍵「移到其他設備…」。",
                "(4) import: every engine API-key-only → view-only with the new plain hint")
        if case .unreachable = model.assistantPlacement {
            t.check(true, "(4) nothing can run here and the primary is unreachable → the pane says so, nothing is sent")
        } else {
            t.check(false, "(4) nothing can run here and the primary is unreachable → the pane says so, nothing is sent")
        }
        model.disabledEngines = []
        t.check(ClaudeSidecar.Kind.allCases.allSatisfy { !model.isEngineDisabled($0) && !model.isAPIKeyOptedOut($0) }
                && !model.coderImportViewOnly,
                "(4) nothing opted out → nothing blocked (old behavior)")
        // W180 E3 起匯入的串，串頂存的是改字前的舊句子：送出或移到別台時一樣拿掉。
        let legacy = "這台的引擎已停用：可以看；要接著做，右鍵「併回設備…」送到主設備"
        let rest = "從 Codex 匯入：放了最近 3 則（共 3 則）"
        t.check(CoderImport.legacyViewOnlyHints.contains(legacy) && CoderImport.withoutViewOnlyHint(legacy + "\n" + rest) == rest
                && !CoderImport.transferredBanner(legacy + "\n" + rest, createdProject: nil).contains("併回設備"),
                "(4) import: the old view-only line saved before W181 is dropped too")
    }
}
#endif
