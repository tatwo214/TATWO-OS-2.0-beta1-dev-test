import Combine
import Foundation

/// W181 R3：這家在這台是用哪一種登入跑。
enum EngineLoginMethod: String, Sendable, Equatable {
    /// 訂閱／帳號登入（OAuth）：照常能跑，不會按量扣錢。
    case subscription
    /// API 金鑰（按量計費）。
    case apiKey
    /// 判斷不出來（沒登入、登入檔認不得）：當成 API 金鑰，寧可擋也不偷燒錢。
    case unknown
    /// Claude 還在查（主執行緒不等 `claude auth status`，先回這個、背景查，查完畫面會更新）：先不送。
    case checking
    /// Claude 查詢逾時或跑不起來、之前也沒查到過：先不送，說明寫「暫時查不到」，不說成沒登入。
    case checkFailed
}

/// W181 R3：「不用 API 金鑰」（設定 › 登入 往左拖；存在 `tatwo2.disabledEngines`，W181 前叫「禁用 API」）。
/// 使用者的本意（2026-09-27）：只是不想被 API 按量扣錢——訂閱登入照常能跑，這台自己跑模型，主設備關掉也不影響。
/// 這裡只回答兩件事：這家在這台是哪一種登入（看登入檔的「登入方式」欄位與 `claude auth status`，
/// 權杖與金鑰一律不讀出來、不記、不印），以及啟動引擎時要拿掉哪些 API 金鑰變數。
/// 擋不擋送出的唯一判斷在 `EngineDisableStore.sendBlockReason`。
final class EngineAPIKeyPolicy: @unchecked Sendable {
    static let shared = EngineAPIKeyPolicy()

    // MARK: - 金鑰變數

    /// 每家會讓引擎改走 API 計費的環境變數。
    static func apiKeyEnvironmentKeys(_ kind: ClaudeSidecar.Kind) -> [String] {
        switch kind {
        case .codex: ["OPENAI_API_KEY", "CODEX_API_KEY", "AZURE_OPENAI_API_KEY"]
        case .claude: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                       "CLAUDE_CODE_USE_FOUNDRY", "AWS_BEARER_TOKEN_BEDROCK"]
        case .grok: ["XAI_API_KEY", "GROK_API_KEY"]
        }
    }

    /// 啟動 `kind` 的 sidecar 前：勾了這家就把它的 API 金鑰變數拿掉，讓它不可能偷偷改走 API 計費；
    /// 沒勾一個都不動（跟舊版逐字相同）。回拿掉的變數名（不含值）。
    @discardableResult
    static func removeAPIKeys(from environment: inout [String: String], for kind: ClaudeSidecar.Kind,
                              optedOut: Set<String>) -> [String] {
        guard optedOut.contains(kind.rawValue) else { return [] }
        let removed = apiKeyEnvironmentKeys(kind).filter { environment[$0] != nil }
        for key in removed { environment.removeValue(forKey: key) }
        return removed
    }

    /// GBrain 語意搜尋用的金鑰一定是 API 金鑰（按量計費）：勾了那家就不讀、不帶。
    static func gbrainProviderEnvironment(optedOut: Set<String>,
                                          read: (String) throws -> String?) rethrows -> [String: String] {
        var environment: [String: String] = [:]
        if !optedOut.contains(ClaudeSidecar.Kind.codex.rawValue), let key = try read("openai") {
            environment["OPENAI_API_KEY"] = key
        }
        if !optedOut.contains(ClaudeSidecar.Kind.claude.rawValue), let key = try read("anthropic") {
            environment["ANTHROPIC_API_KEY"] = key
        }
        return environment
    }

    // MARK: - 說明文字

    static func blockMessage(_ kind: ClaudeSidecar.Kind, _ method: EngineLoginMethod) -> String {
        let name = EngineDisableStore.displayName(kind)
        let tail = "你設定了不用 API 金鑰（按量計費），這句沒有送出。要用請在 設定 › 登入 用訂閱帳號登入，或取消這個設定。"
        switch method {
        case .apiKey: return "\(name) 在這台只有 API 金鑰登入，\(tail)"
        case .unknown, .subscription:
            return "\(name) 在這台看不出是訂閱登入（沒登入或登入檔認不得，當成 API 金鑰），\(tail)"
        case .checking:
            return "\(name) 在這台是哪種登入還在確認（你設定了不用 API 金鑰），這句先沒有送出；過幾秒再送一次。"
        case .checkFailed:
            return "這台暫時查不到 \(name) 是哪種登入（你設定了不用 API 金鑰），這句先沒有送出；稍後再送一次，或打開 設定 › 登入 重新檢查。"
        }
    }

    /// 派到別台的串（sidecar 經 ssh 在那台跑）：這台的登入檔說明不了那台，勾了就照舊擋，不拿這台的登入去判斷那台。
    static func otherDeviceMessage(_ kind: ClaudeSidecar.Kind, device: String?) -> String {
        let place = device.map { "「\($0)」" } ?? "別台設備"
        return "這條的 \(EngineDisableStore.displayName(kind)) 在\(place)上跑，這台看不出那台是不是用訂閱登入；"
            + "你設定了不用 API 金鑰（按量計費），這句沒有送出。要用請在 設定 › 登入 取消這個設定。"
    }

    /// 剛勾下「不用 API 金鑰」時的提示（登入方式在背景查完才說，說法跟擋送出一致）。
    static func optOutHint(_ kind: ClaudeSidecar.Kind, _ method: EngineLoginMethod) -> String {
        let name = EngineDisableStore.displayName(kind)
        switch method {
        case .subscription: return "\(name) 不用 API 金鑰了：訂閱登入照常能用，不會按量扣錢"
        case .apiKey: return "\(name) 不用 API 金鑰了；這台只有 API 金鑰登入，要用請登入訂閱帳號"
        case .unknown: return "\(name) 不用 API 金鑰了；看不出這台是訂閱登入（可能還沒登入），先不送；要用請在 設定 › 登入 用訂閱帳號登入"
        case .checking, .checkFailed: return "\(name) 不用 API 金鑰了；這台暫時查不到是哪種登入，先不送，稍後會再查"
        }
    }

    static let claudeProjectMessage = "Claude 在這個資料夾的 .claude 設定會改走 API 金鑰（apiKeyHelper 或金鑰變數），"
        + "你設定了不用 API 金鑰（按量計費），這句沒有送出。要用請拿掉那個設定，或在 設定 › 登入 取消這個設定。"

    // MARK: - 這台是哪一種登入

    private struct ClaudeCheck {
        let method: EngineLoginMethod
        /// 這次查詢開始的時間（比要求晚開始的才算得上「要求之後的結果」）。
        let checkedAt: Date
        /// 過了這個時間就在背景重查（查到了 60 秒；查不到 10 秒）。
        let next: Date
    }

    private let lock = NSLock()
    private var pathsOverride: EnginePaths?
    private var environmentOverride: [String: String]?
    private var statusTimeout: TimeInterval
    private var claudeCache: ClaudeCheck?
    private var claudeRefreshing = false
    /// 清掉結果或換測試路徑就加一；查到一半的舊結果不寫回。
    private var generation = 0
    /// `claude auth status` 一次只跑一個（背景）。
    private let probeQueue = DispatchQueue(label: "tatwo2.engine-apikey-policy.claude", qos: .utility)
    /// Claude 的結果在背景查到（或變了）時送一次（主執行緒）：畫面據此重畫。
    let changes = PassthroughSubject<Void, Never>()
    /// Claude 要跑一次 `claude auth status`（約 0.2 秒），結果記這麼久；Codex、Grok 每次看登入檔。
    static let claudeFreshSeconds: TimeInterval = 60
    /// 查不到（逾時、跑不動）時多久再試。
    static let claudeRetrySeconds: TimeInterval = 10
    /// 跟 EngineLogin 查同一個指令的上限一樣（8 秒）。
    static let claudeStatusTimeout: TimeInterval = 8

    init(paths: EnginePaths? = nil, environment: [String: String]? = nil,
         statusTimeout: TimeInterval = EngineAPIKeyPolicy.claudeStatusTimeout) {
        pathsOverride = paths
        environmentOverride = environment
        self.statusTimeout = statusTimeout
    }

    private func snapshot() -> (paths: EnginePaths, environment: [String: String], timeout: TimeInterval) {
        lock.lock()
        let paths = pathsOverride, override = environmentOverride, timeout = statusTimeout
        lock.unlock()
        let environment = override ?? ProcessInfo.processInfo.environment
        return (paths ?? EnginePaths(environment: environment), environment, timeout)
    }

    #if DEBUG
    /// 自測用：換成假的引擎根目錄（假登入檔、假 claude），並清掉上次查的結果；傳 nil 還原。
    func useForTesting(paths: EnginePaths?, environment: [String: String]?,
                       statusTimeout: TimeInterval = EngineAPIKeyPolicy.claudeStatusTimeout) {
        lock.lock()
        pathsOverride = paths
        environmentOverride = environment
        self.statusTimeout = statusTimeout
        claudeCache = nil
        generation += 1
        lock.unlock()
    }
    #endif

    /// 清掉 Claude 上次查的結果（之後第一次問會重查）。
    func invalidate() {
        lock.lock(); claudeCache = nil; generation += 1; lock.unlock()
    }

    /// 在背景執行緒呼叫（登入、登出、重新檢查後）：勾了 Claude 才重查它的登入方式（沒勾不多跑任何東西）。
    func refresh(optedOut: Set<String>) {
        guard optedOut.contains(ClaudeSidecar.Kind.claude.rawValue) else { return }
        refreshClaude()
    }

    /// 哪個執行緒都能呼叫、馬上回：App 一開、剛勾下 Claude 時先在背景查好（勾了 Claude 才查）。
    func refreshInBackground(optedOut: Set<String>) {
        guard optedOut.contains(ClaudeSidecar.Kind.claude.rawValue) else { return }
        refreshClaudeInBackground()
    }

    /// 這家在這台是哪一種登入。Codex、Grok 讀登入檔；Claude 的設定檔每次都讀，`claude auth status` 用記下的結果。
    /// 主執行緒一律不起子程序（ChatPageModel 註解記的 03:41／03:52 兩次「當機」就是卡在這種地方）：
    /// 過期了先回上次的結果、背景重查；還沒查過回 `.checking`。
    /// 背景執行緒：過期了就在這裡查（allowStale＝有上次的結果就先用、背景重查）。
    func method(_ kind: ClaudeSidecar.Kind, allowStale: Bool = false) -> EngineLoginMethod {
        let (paths, _, _) = snapshot()
        switch kind {
        case .codex:
            return Self.codexMethod(
                authJSON: try? Data(contentsOf: paths.codexAuth),
                config: try? String(contentsOf: paths.codexHome.appendingPathComponent("config.toml"), encoding: .utf8))
        case .grok:
            return Self.grokMethod(authJSON: try? Data(contentsOf: paths.grokAuth))
        case .claude:
            // 設定檔加了 apiKeyHelper／金鑰變數馬上算數（讀一個小檔，不等下次查）。
            let settings = paths.claudeConfigDirectory.appendingPathComponent("settings.json")
            if let data = try? Data(contentsOf: settings), Self.claudeSettingsUseAPIKey(data) { return .apiKey }
            return claudeLogin(allowStale: allowStale)
        }
    }

    private func claudeLogin(allowStale: Bool) -> EngineLoginMethod {
        lock.lock()
        let cached = claudeCache
        lock.unlock()
        if let cached, Date() < cached.next { return cached.method }
        if Thread.isMainThread || (allowStale && cached != nil) {
            refreshClaudeInBackground()
            return cached?.method ?? .checking
        }
        return refreshClaude()
    }

    /// 現在就查一次 Claude（背景執行緒；排隊時別人剛查完就直接用那次的結果）。
    /// 在主執行緒被呼叫時不等：改成背景查，先回上次的結果（沒有就 `.checking`）。
    @discardableResult
    func refreshClaude() -> EngineLoginMethod {
        if Thread.isMainThread {
            refreshClaudeInBackground()
            lock.lock(); let cached = claudeCache; lock.unlock()
            return cached?.method ?? .checking
        }
        let requested = Date()
        return probeQueue.sync { probeClaude(unlessCheckedSince: requested) }
    }

    private func refreshClaudeInBackground() {
        lock.lock()
        let busy = claudeRefreshing
        claudeRefreshing = true
        lock.unlock()
        guard !busy else { return }
        let requested = Date()
        probeQueue.async { [self] in
            probeClaude(unlessCheckedSince: requested)
            lock.lock(); claudeRefreshing = false; lock.unlock()
        }
    }

    /// 只在 probeQueue 上跑。查不到（逾時、跑不起來）：上次查到過就沿用（10 秒後再試），沒有才記「暫時查不到」。
    @discardableResult
    private func probeClaude(unlessCheckedSince requested: Date) -> EngineLoginMethod {
        lock.lock()
        let before = claudeCache, startGeneration = generation
        lock.unlock()
        if let before, before.checkedAt >= requested { return before.method }
        let (paths, environment, timeout) = snapshot()
        let startedAt = Date()
        let answer = Self.claudeStatus(paths: paths, environment: environment, timeout: timeout)
        let now = Date()
        let check: ClaudeCheck
        switch answer {
        case .answer(let data):
            check = ClaudeCheck(method: Self.claudeMethod(status: data, settings: []), checkedAt: startedAt,
                                next: now.addingTimeInterval(Self.claudeFreshSeconds))
        case .unavailable:
            check = ClaudeCheck(method: .unknown, checkedAt: startedAt, next: now.addingTimeInterval(Self.claudeFreshSeconds))
        case .failed:
            let known: Set<EngineLoginMethod> = [.subscription, .apiKey, .unknown]
            let previous = before.map(\.method).flatMap { known.contains($0) ? $0 : nil }
            check = ClaudeCheck(method: previous ?? .checkFailed, checkedAt: startedAt,
                                next: now.addingTimeInterval(Self.claudeRetrySeconds))
        }
        lock.lock()
        let current = generation == startGeneration
        if current { claudeCache = check }
        lock.unlock()
        guard current else { return check.method }
        if before?.method != check.method { DispatchQueue.main.async { [self] in changes.send() } }
        return check.method
    }

    // MARK: - Codex：auth.json 的 auth_mode

    static func codexMethod(authJSON: Data?, config: String?) -> EngineLoginMethod {
        if let config, let forced = codexConfigMethod(config) { return forced }
        guard let authJSON, let object = try? JSONSerialization.jsonObject(with: authJSON) as? [String: Any] else {
            return .unknown
        }
        let tokens = object["tokens"] as? [String: Any] ?? [:]
        let hasTokens = nonEmpty(tokens["refresh_token"]) || nonEmpty(tokens["access_token"])
        switch (object["auth_mode"] as? String)?.lowercased() {
        case "chatgpt"?, "chatgptauthtokens"?: return hasTokens ? .subscription : .unknown
        case "apikey"?, "api_key"?, "api"?: return .apiKey
        case nil: return nonEmpty(object["OPENAI_API_KEY"]) ? .apiKey : .unknown
        default: return .unknown
        }
    }

    /// config.toml 最上層（第一個 [區段] 之前）：強制 API 登入或偏好 API 金鑰＝API 金鑰；換成別的供應商＝判斷不出來。
    static func codexConfigMethod(_ text: String) -> EngineLoginMethod? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { value = value[..<hash].trimmingCharacters(in: .whitespaces) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            switch key {
            case "forced_login_method" where value == "api": return .apiKey
            case "preferred_auth_method" where value == "apikey": return .apiKey
            case "model_provider" where value != "openai": return .unknown
            default: continue
            }
        }
        return nil
    }

    // MARK: - Grok：.grok/auth.json 每一筆的 auth_mode

    static func grokMethod(authJSON: Data?) -> EngineLoginMethod {
        guard let authJSON, let object = try? JSONSerialization.jsonObject(with: authJSON) as? [String: Any],
              !object.isEmpty else { return .unknown }
        for value in object.values {
            guard let entry = value as? [String: Any] else { return .unknown }
            let mode = (entry["auth_mode"] as? String)?.lowercased() ?? ""
            let principal = (entry["principal_type"] as? String)?.lowercased() ?? ""
            if mode.contains("api") || principal.contains("api") { return .apiKey }
            guard ["oidc", "oauth", "device", "device_code"].contains(mode), nonEmpty(entry["refresh_token"]) else {
                return .unknown
            }
        }
        return .subscription
    }

    // MARK: - Claude：`claude auth status` 的 authMethod＋設定裡的 apiKeyHelper／金鑰變數

    static func claudeMethod(status: Data?, settings: [Data]) -> EngineLoginMethod {
        if settings.contains(where: claudeSettingsUseAPIKey) { return .apiKey }
        guard let status, let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any] else {
            return .unknown
        }
        let method = object["authMethod"] as? String
        if nonEmpty(object["apiKeySource"]) || ["api_key", "api_key_helper", "third_party"].contains(method ?? "") {
            return .apiKey
        }
        let provider = object["apiProvider"] as? String
        if object["loggedIn"] as? Bool == true, method == "claude.ai", provider == nil || provider == "firstParty",
           nonEmpty(object["subscriptionType"]) {
            return .subscription
        }
        return .unknown
    }

    /// Claude 的設定檔（使用者層或資料夾的 .claude）：有 apiKeyHelper，或 env 區塊帶金鑰變數＝會改走 API 金鑰。
    static func claudeSettingsUseAPIKey(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if nonEmpty(object["apiKeyHelper"]) { return true }
        let env = object["env"] as? [String: Any] ?? [:]
        return apiKeyEnvironmentKeys(.claude).contains { env[$0] != nil }
    }

    /// 送出時用那條的資料夾看一次 Claude 的專案設定（sidecar 會讀 user＋project 兩層）。
    static func claudeProjectUsesAPIKey(cwd: String) -> Bool {
        let folder = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        return ["settings.json", "settings.local.json"].contains { name in
            (try? Data(contentsOf: folder.appendingPathComponent(name))).map(claudeSettingsUseAPIKey) ?? false
        }
    }

    enum ClaudeStatusAnswer {
        /// `claude auth status` 的 JSON 回答。
        case answer(Data)
        /// 沒有 claude 可跑、或 staging 路徑不對：判斷不出來。
        case unavailable
        /// 逾時或起不來：暫時查不到。
        case failed
    }

    /// 跟聊天 sidecar 同一個獨立 CLAUDE_CONFIG_DIR 跑 `claude auth status`，而且先拿掉 Claude 的金鑰變數
    /// （跟勾了之後的 sidecar 一樣）；只收它的 JSON 回答。只在背景執行緒跑（等它結束最多 timeout 秒）。
    static func claudeStatus(paths: EnginePaths, environment: [String: String],
                             timeout: TimeInterval = claudeStatusTimeout) -> ClaudeStatusAnswer {
        assert(!Thread.isMainThread, "claude auth status must not run on the main thread")
        var child = environment
        removeAPIKeys(from: &child, for: .claude, optedOut: [ClaudeSidecar.Kind.claude.rawValue])
        child = NativeStagingIsolation.isolateClaude(child, configDirectory: paths.claudeConfigDirectory.path)
        guard NativeStagingIsolation.validationError(environment) == nil,
              NativeStagingIsolation.validationError(child) == nil,
              FileManager.default.isExecutableFile(atPath: paths.claudeExecutable.path) else { return .unavailable }
        let process = Process()
        process.executableURL = paths.claudeExecutable
        process.arguments = ["auth", "status"]
        process.environment = child
        if NativeStagingIsolation.isEnabled(environment), let home = environment["HOME"] {
            process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return .failed }
        if finished.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); return .failed }
        return .answer(output.fileHandleForReading.readDataToEndOfFile())
    }

    private static func nonEmpty(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
