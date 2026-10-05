import Foundation
import Combine
import AppKit
import Darwin

/// W183 R2／R2b：App 端看管 ChatGPT 手腳的對外關口與 cloudflared（接口約定 v2 §1、§10，v3 V8；威脅模型 T1、T8、T10–T13）。
/// 沒有 Node supervisor：這裡直接開兩個**兄弟**行程（都是 App 的子行程、各自一個行程群組、都不繼承 App 的 fd）。
/// 啟動順序（v3 V8）：預建 socket 資料夾（0700）→ 以 `POSIX_SPAWN_CLOEXEC_DEFAULT` 開關口（`sandbox-exec -p gateway.sb … node gateway.mjs`）
///   → 登記關口 pid（`OSSocketCaller.registerExternalAI`；sandbox-exec 以 exec 換成 Node，pid 不變）→ 關口健康（App 自己探 socket，
///   並確認聽 socket 的就是登記的 pid）→ 最後才開 cloudflared（外面包看門程式 tunnel-guard.sh、cloudflared.sb、獨立 HOME、明確 --config、
///   --no-autoupdate；token 只寫進 cf-home 裡的 0600 檔，連上就刪，不進 argv、不進環境、關口拿不到）。
/// 退出順序：先停 cloudflared（等它整組結束）→ 解除登記 → 再停關口；任一個停掉就整組收並回報。
///   App 結束時由 SidecarGroupedProcess.terminateAll 一起收（App 自己也要結束，os.sock 跟著消失）。
/// 十分鐘內最多自動重開三次（照 SpotifyConnect）；開關關掉就停；自測、staging、source test 不啟動（照 GBrainService）。
/// W183 R2b：定時確認兩個行程真的活著、關口的 socket 還是登記的 pid 在聽；socket 被換掉（關口自己發現＝結束碼 3，或 App 看到聽的人不對）
///   ＝可能有同一個使用者的其他程式冒充關口：整組停下、不自動重開，等使用者按重試（殘餘風險 V16：兩次檢查之間的請求仍可能被接走）。
/// 每天抓一次 OpenAI 的外掛 IP 清單寫進關口的 config.json：更新失敗保留舊清單且不更新時間，格式錯誤保留舊的，過期 7 天由關口全拒（T1）。
final class ChatGPTHandsService: ObservableObject {
    static let shared = ChatGPTHandsService()

    enum Phase: Equatable {
        case stopped
        case starting
        case running(url: String)
        case failed(String)
    }

    /// 給 R3 畫面：停／啟動中／運作中＋網址／失敗原因（白話中文，不含路徑或金鑰）。
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var rangesFetchedAt: Date?
    @Published private(set) var rangesProblem: String?

    struct Dependencies {
        var environment: [String: String] = ProcessInfo.processInfo.environment
        /// `<App Support>/TATWO OS Hands`；自測指到暫存資料夾。
        var handsRoot: URL?
        /// 預設 App 內的 Resources/chatgpt-hands 與 Resources/runtime/bin/node（不借 ClaudeSidecar.scriptPath 的覆寫）。
        var programDirectory: URL?
        var node: URL?
        var osSocket: String?
        // W183 R3（審查修正）：只用標準設定流程下載、驗過雜湊的那份（<App Support>/TATWO OS Hands/bin/cloudflared；每次用前再驗雜湊）。
        // Homebrew 的路徑同一個使用者的程式都改得到，只看路徑就把通道 token 交給它＝繞過固定版本，所以不再用。
        var cloudflared: () -> URL? = { HandsCloudflared.verifiedInstalled(root: HandsGatewayLaunch.Paths.defaultRoot()) }
        /// 只給自測：在 cloudflared 的參數前面插一段（例如用 Node 扮演 cloudflared）；Seatbelt 規則、參數與環境照舊。
        var tunnelProgramPrefix: [String]?
        /// token 檔最多留多久（cloudflared 啟動當下就讀；連上會更早刪）。
        var tokenFileLifetime: TimeInterval = 30
        var localDeviceID: () -> String? = { try? DeviceIdentityStore.readLocal()?.deviceID }
        var tunnelToken: HandsTunnelTokenStore = HandsTunnelKeychain()
        var fetchRanges: (@escaping (Result<Data, Error>) -> Void) -> Void = ChatGPTHandsService.fetchConnectorList
        /// 接口約定 v2 §1：登記的是關口 pid；關口身分不綁對話（thread 給固定值，App 端忽略）。
        var register: (pid_t, UInt64) -> Void = { OSSocketCaller.registerExternalAI(pid: $0, startTime: $1, thread: HandsGatewayLaunch.unboundThread) }
        var unregister: (pid_t) -> Void = { OSSocketCaller.unregisterExternalAI(pid: $0) }
        /// 只給 w183gateway 自測：略過「自測／staging 不啟動」。
        var allowUnderTest = false
        var now: () -> Date = Date.init
        var restartDelay: TimeInterval = 2
        var readyTimeout: TimeInterval = 20
        var monitorInterval: TimeInterval = 5
        /// 停 cloudflared（或關口）後最多等它整組結束多久（terminateGroup 2 秒後就 SIGKILL）。
        var tunnelStopWait: TimeInterval = 3
        /// W183 R6a 審查（GPT-6）：這台可以當主機起關口嗎。W183 R8c：每台啟用許可（HandsBuildPermit：正本這台看自己的設定、
        /// 副設備看主設備簽的信封——給這台、勾了這台、沒過期）。自測換掉。
        var hostConfirmed: (_ local: String) -> Bool = { HandsBuildPermit.permits($0) }
        /// W183 R6c：起關口前備好入口的 chatgpt/ 工作區（主機重開、開關開著自動續跑也照這個檢查）。成功回 nil、失敗回一句話。
        var prepareWorkspace: () -> String? = { HandsWorkspaceRoot.prepare() }
    }

    let dependencies: Dependencies
    let paths: HandsGatewayLaunch.Paths
    private let queue = DispatchQueue(label: "tatwo.chatgpt-hands.service")
    private var phaseOnQueue: Phase = .stopped
    private var gateway: SidecarGroupedProcess?
    private var tunnel: SidecarGroupedProcess?
    private var registeredPID: pid_t?
    private var generation = 0
    private var crashes: [Date] = []
    private var latchedFailure: String?
    private var lastHostConfirmed: Bool?
    private var retryAt: Date?
    private var retryFingerprint: String?
    private var transientFailures = 0
    private var restartReason = "enabled"
    private var attemptOpen = false
    /// W183 R6a 審查（GPT-6）：這個行程記得的安全停機（磁碟上的鎖寫不進去時也擋；只有使用者按的「重試」解除）。只在佇列上讀寫。
    private var safetyLatched = false
    /// W183 R8c 審查：這個行程記得的那一次安全停機的事故編號（磁碟上的鎖沒有編號時用）。只在佇列上讀寫。
    private var latchedIncident: String?
    private var restartPending = false
    /// App 結束：觀察者直接設（不經佇列，避免和佇列互等）；佇列上用 isStopping 讀。
    private let stopLock = NSLock()
    private var stoppingFlag = false
    private var monitor: DispatchSourceTimer?
    private var fetching = false
    private var lastRangesAttempt: Date?
    private var gatewayBuffer = Data()
    private var tunnelBuffer = Data()
    private var tunnelAuthFailed = false
    private var tunnelTooOld = false
    private var tokenFileOnDisk: URL?
    private var lastGatewayError: String?
    private var currentFingerprint: String?
    private var currentHost: String?
    private var pendingTunnel: PendingTunnel?
    /// 關口的 socket（真實路徑）；定時確認聽它的還是登記的 pid（W183 R2b）。
    private var gatewaySocketPath: String?
    private var peerCheckInFlight = false
    private var terminationObserver: NSObjectProtocol?
    #if DEBUG
    /// 自測看啟動與退出順序（v3 V8）：只記步驟名稱與 pid，不記任何秘密。
    private var launchLog: [String] = []
    #endif

    private struct PendingTunnel {
        let cloudflared: URL
        let token: String
        let paths: HandsGatewayLaunch.Paths
        let profile: String
        let guardScript: String
    }

    /// 起關口前在佇列上就能做完的檢查與材料。
    private struct Prepared {
        let settings: HandsGatewayLaunch.Settings
        let host: String
        let programReal: String
        let nodeReal: String
        let gatewayProfile: String
        let tunnelProfile: String
        let guardScript: String
        let cloudflared: URL
        let token: String
    }

    private enum Part { case gateway, tunnel }

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        paths = HandsGatewayLaunch.Paths(root: dependencies.handsRoot ?? HandsGatewayLaunch.Paths.defaultRoot())
        // App 結束時 SidecarGroupedProcess.terminateAll 會收掉兩組；這裡只標記不要自動重開。直接設旗標，不經佇列
        // （佇列可能正在做事；主執行緒在這裡等佇列＝可能互等）。terminateAll 一開頭也會設 isTerminating，兩道都擋。
        let appPaths = paths
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.markStopping()
            Self.disarmSafety(appPaths)   // W183 R6a 審查：正常結束＝預寫的那份拿掉（安全停機改成唯讀的那份不動）
        }
    }

    private func markStopping() { stopLock.lock(); stoppingFlag = true; stopLock.unlock() }

    /// App 正在結束：不開、不重開。
    private var isStopping: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stoppingFlag || SidecarGroupedProcess.isTerminating
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        monitor?.cancel()
        tunnel?.terminateGroup()
        if let registeredPID { dependencies.unregister(registeredPID) }
        gateway?.terminateGroup()
        if let tokenFileOnDisk { HandsGatewayLaunch.removeTokenFile(tokenFileOnDisk) }
    }

    /// 自測、staging、source test 一律不開通道、不起關口（T12）。
    static func allowedToRun(environment: [String: String]) -> Bool {
        environment["TATWO2_SOURCETEST"] != "1" && environment["TATWO2_SELFTEST"] == nil
            && !NativeStagingIsolation.isEnabled(environment)
    }

    private var allowed: Bool { dependencies.allowUnderTest || Self.allowedToRun(environment: dependencies.environment) }

    // MARK: 給 App／R3 呼叫
    /// App 啟動後呼叫：開關開著才起；之後定時看設定（關掉就停、網域或主機設備換了就重開）與 IP 清單新鮮度。
    func startIfEnabled() {
        queue.async { [weak self] in
            guard let self, allowed else { return }
            installMonitor()
            evaluate()
            refreshRangesIfDue()
        }
    }

    /// 設定改了（開關、網域、主機設備）就呼叫；不呼叫也會在下一次定時檢查時被看到。
    func settingsDidChange() { queue.async { [weak self] in self?.evaluate(); self?.refreshRangesIfDue() } }

    /// 失敗後按「重試」。
    func retry() {
        queue.async { [weak self] in
            guard let self else { return }
            Self.clearSafetyStop(paths)   // W183 R6a：安全停機的人工重試鎖只有這一下（使用者按的「重試」）解除
            safetyLatched = false
            latchedIncident = nil
            resetFailures()
            restartReason = "user_retry"
            evaluate()
        }
    }

    /// W183 R6a 審查（Claude）：助理（AI）叫的「重試」——一般的關口失敗（一直停止、版本太舊、憑證錯）照樣救得回來，
    /// 但安全停機的人工重試鎖不解除（evaluate 在看上次的失敗之前先看安全鎖）。
    func retryKeepingSafetyLock() {
        queue.async { [weak self] in
            guard let self else { return }
            resetFailures()
            restartReason = "retry_keeping_safety"
            evaluate()
        }
    }

    /// 先停下來，直到設定改了或按「重試」才會再開（開關本身由設定決定）。
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            latchedFailure = HandsGatewayLaunch.readSettings(paths.settingsFile)?.fingerprint ?? currentFingerprint ?? ""
            shutdown(then: .stopped)
        }
    }

    /// 立刻抓一次 OpenAI 的 IP 清單（標準流程用）。
    func refreshRanges() { queue.async { [weak self] in self?.refreshRangesIfDue(force: true) } }

    /// socket 被動過時的狀態文字（不自動重開，等使用者確認後按重試）。
    static let tamperedText = "關口的連線點被別的程式動過；為了安全已經停下，確認沒有可疑程式後請到設定按重試"

    // W183 R6a（one-switch「自動續跑的界線」：安全停機保留人工重試鎖，重開 App 不會解除）：鎖寫進 App 自己的資料夾（app/，關口讀寫不到），
    // App 重開、自動續跑（只叫 settingsDidChange）、助理的重試都不解除；只有使用者按的「重試」（retry）解除。只有標記，沒有任何秘密。
    // W183 R6a 審查（GPT-6「人工重試鎖可能沒有保存」）：
    // - 起關口之前先預寫 safety-armed.json（fsync；寫不進去＝不起）。真的安全停機時**先**鎖、再停行程：把預寫的那份改名成 safety-stop.json
    //   （改名不用新的資料空間，磁碟滿也改得了）→ 改不了才寫新的一份 → 再不行把預寫的那份改成唯讀（chmod 不用新空間）→ 這個行程也記著（safetyLatched）。
    // - 讀標記出錯（權限、I/O；不是「沒有這個檔」）＝當成鎖著（fail closed）。
    // - 正常停下、App 正常結束＝拿掉預寫的那份；App 當掉留下的預寫檔（可寫的）不算鎖（當掉後照樣自動續跑）。
    /// 標記放在 app/ 的真實路徑（app/ 可以是捷徑：整合自測把關口的 app/ 指到 HandsService 的 app/；正式就是同一個資料夾）。
    static func safetyDir(_ paths: HandsGatewayLaunch.Paths) -> URL {
        URL(fileURLWithPath: HandsGatewayLaunch.realPath(paths.appDir.path) ?? paths.appDir.path, isDirectory: true)
    }
    static func safetyStopURL(_ paths: HandsGatewayLaunch.Paths) -> URL { safetyDir(paths).appendingPathComponent("safety-stop.json") }
    static func safetyArmedURL(_ paths: HandsGatewayLaunch.Paths) -> URL { safetyDir(paths).appendingPathComponent("safety-armed.json") }

    enum SafetyState: Equatable { case clear, locked, unreadable }

    static func safetyState(_ paths: HandsGatewayLaunch.Paths) -> SafetyState {
        var info = stat()
        if lstat(safetyStopURL(paths).path, &info) == 0 { return .locked }
        guard errno == ENOENT else { return .unreadable }
        if lstat(safetyArmedURL(paths).path, &info) == 0 { return (info.st_mode & 0o200) == 0 ? .locked : .clear }
        return errno == ENOENT ? .clear : .unreadable
    }

    static func safetyStopped(_ paths: HandsGatewayLaunch.Paths) -> Bool { safetyState(paths) != .clear }

    /// 起關口前預寫（確定進了磁碟才回 true）。W183 R8c 審查（GPT-6 高）：帶一個亂數的事故編號（不是秘密）——真的安全停機時
    /// 改名成鎖，編號跟著走；別台送來的「解除安全鎖」要帶這個編號，對上才解除（晚到的舊解除清不掉新事故的鎖）。
    static func armSafety(_ paths: HandsGatewayLaunch.Paths) -> Bool {
        do {
            try HandsFiles.ensureDirectory(safetyDir(paths))
            let incident = HandsSetup.randomLabel(20)
            try HandsFiles.writeAtomically(Data("{\"armed\":true,\"incident\":\"\(incident)\",\"note\":\"renamed to safety-stop.json on a safety stop\"}\n".utf8),
                                           to: safetyArmedURL(paths))
            return true
        } catch { return false }
    }

    /// 安全停機：鎖落在磁碟上回 true（改名 → 寫新的 → 預寫的改唯讀；都不行＝false，只剩這個行程記得）。
    @discardableResult
    static func recordSafetyStop(_ paths: HandsGatewayLaunch.Paths) -> Bool {
        if Darwin.rename(safetyArmedURL(paths).path, safetyStopURL(paths).path) == 0 { return true }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let incident = HandsSetup.randomLabel(20)
        if (try? HandsFiles.writeAtomically(Data("{\"reason\":\"socket_tampered\",\"incident\":\"\(incident)\",\"at\":\"\(stamp)\"}\n".utf8),
                                            to: safetyStopURL(paths))) != nil {
            return true
        }
        return chmod(safetyArmedURL(paths).path, 0o400) == 0
    }

    /// W183 R8c 審查（GPT-6 高）：現在這一次安全停機的事故編號（鎖檔、或改成唯讀的預寫檔裡的；讀不到、舊版沒有編號＝nil）。
    static func safetyIncident(_ paths: HandsGatewayLaunch.Paths) -> String? {
        func read(_ url: URL) -> String? {
            guard let data = HandsGatewayLaunch.readPrivate(url, limit: 4096),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let incident = object["incident"] as? String, (1...64).contains(incident.utf8.count),
                  incident.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return incident
        }
        switch safetyState(paths) {
        case .clear, .unreadable: return nil
        case .locked:
            var info = stat()
            if lstat(safetyStopURL(paths).path, &info) == 0 { return read(safetyStopURL(paths)) }
            return read(safetyArmedURL(paths))
        }
    }

    /// W183 R8c 審查（GPT-6 高「遠端解除安全鎖未綁事故與世代」）：別台送來的「解除安全鎖」——在關口的佇列上原子地核對事故編號
    /// （跟現在鎖著的是同一次）才解除；這個行程記著、磁碟上沒有編號的鎖（寫不進去）也只接受這個行程記的編號。回 true＝解除了。
    func unlockSafety(incident: String) -> Bool {
        queue.sync {
            let current = safetyLatched ? (latchedIncident ?? Self.safetyIncident(paths)) : Self.safetyIncident(paths)
            guard let current, HandsAuth.constantTimeEqual(current, incident) else { return false }
            Self.clearSafetyStop(paths)
            safetyLatched = false
            latchedIncident = nil
            latchedFailure = nil; crashes = []
            evaluate()
            return true
        }
    }

    /// 這台現在的事故編號（公共狀態用：只是亂數編號，不是秘密）。
    func currentSafetyIncident() -> String? {
        queue.sync { safetyLatched ? (latchedIncident ?? Self.safetyIncident(paths)) : Self.safetyIncident(paths) }
    }

    /// 正常停下：拿掉預寫的那份（已經改成唯讀＝安全停機的最後一道，不動）。
    static func disarmSafety(_ paths: HandsGatewayLaunch.Paths) {
        var info = stat()
        guard lstat(safetyArmedURL(paths).path, &info) == 0, (info.st_mode & 0o200) != 0 else { return }
        unlink(safetyArmedURL(paths).path)
    }

    static func clearSafetyStop(_ paths: HandsGatewayLaunch.Paths) {
        unlink(safetyStopURL(paths).path)
        unlink(safetyArmedURL(paths).path)
    }

    /// 讀不到安全停機的標記（fail closed）。
    static let safetyUnreadableText = "讀不到安全停機的標記（App 資料夾的權限？）；為了安全先不開，修好後請到設定按重試"
    /// 預寫不進去（起關口前）。
    static let safetyArmFailedText = "安全停機的標記寫不進去（磁碟滿？）；為了安全先不開，空出空間後請到設定按重試"

    static func statusText(_ phase: Phase) -> String {
        switch phase {
        case .stopped: "已停止"
        case .starting: "啟動中…"
        case let .running(url): "運作中：\(url)"
        case let .failed(reason): reason
        }
    }

    // MARK: 判斷要不要跑
    private func installMonitor() {
        guard monitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + dependencies.monitorInterval, repeating: dependencies.monitorInterval)
        timer.setEventHandler { [weak self] in self?.evaluate(); self?.refreshRangesIfDue() }
        timer.resume()
        monitor = timer
    }

    private func evaluate() {
        guard allowed, !isStopping else {
            if gateway != nil || tunnel != nil { shutdown(then: .stopped) }
            return
        }
        guard let settings = HandsGatewayLaunch.readSettings(paths.settingsFile), settings.enabled else {
            // 開關關掉（或設定不見）：立刻整組收掉。
            if gateway != nil || tunnel != nil || restartPending || phaseOnQueue != .stopped { shutdown(then: .stopped) }
            latchedFailure = nil
            resetTransientRetry()
            lastHostConfirmed = false
            return
        }
        // Observe permission before the fingerprint latch, including while no process exists.
        let confirmed = dependencies.localDeviceID().map { dependencies.hostConfirmed($0) } ?? false
        if lastHostConfirmed == false, confirmed {
            resetFailures()
            restartReason = "permit_restored"
        }
        lastHostConfirmed = confirmed
        // W183 R6a：安全停機（socket 被動過）的鎖在磁碟上：不管設定怎麼變、App 重開幾次都不開，等使用者按「重試」。
        // W183 R6a 審查：這個行程記得的也算；讀標記出錯＝當成鎖著。
        if gateway == nil, !restartPending {
            let state: SafetyState = safetyLatched ? .locked : Self.safetyState(paths)
            if state != .clear {
                let text = state == .unreadable ? Self.safetyUnreadableText : Self.tamperedText
                if phaseOnQueue != .failed(text) { publish(.failed(text)) }
                return
            }
        }
        guard confirmed else {
            if gateway != nil || tunnel != nil || restartPending || phaseOnQueue != .stopped {
                shutdown(then: .stopped)
            }
            restartReason = "permit_restored"
            return
        }
        if gateway != nil {
            // W183 R8c（GPT-6 必改 2）：跑著的時候許可沒了（信封過期＝太久連不到主設備、或設定不再勾這台）＝安全暫停：關口與通道停下，
            // **不撤銷** grant（明確關掉才撤銷，由 HandsBuildReconciler 做）；許可回來（下一次同步）就照設定再起來。
            if let local = dependencies.localDeviceID(), !dependencies.hostConfirmed(local) {
                currentFingerprint = nil
                shutdown(then: .stopped)
                return
            }
            if settings.fingerprint != currentFingerprint { shutdown(then: .starting); begin(settings); return }
            checkAlive()
            return
        }
        if restartPending { return }
        if let latched = latchedFailure, latched == settings.fingerprint { return }
        if retryFingerprint != settings.fingerprint { resetTransientRetry() }
        if let retryAt, dependencies.now() < retryAt { return }
        begin(settings)
    }

    private func publish(_ phase: Phase) {
        if case .running = phase {
            if attemptOpen { lifecycle(result: "running"); attemptOpen = false }
            resetTransientRetry()
        }
        phaseOnQueue = phase
        DispatchQueue.main.async { [weak self] in self?.phase = phase }
    }

    private func fail(_ text: String, fingerprint: String?, retryable: Bool = false) {
        if attemptOpen {
            lifecycle(result: retryable ? "temporary_failure" : "latched_failure")
            attemptOpen = false
        }
        if retryable {
            latchedFailure = nil
            transientFailures += 1
            let delay = min(300.0, 30.0 * pow(2, Double(min(transientFailures - 1, 4))))
            let next = dependencies.now().addingTimeInterval(delay)
            retryAt = next
            retryFingerprint = fingerprint ?? currentFingerprint
            restartReason = "transient_retry"
            publish(.failed("\(text)；\(Self.clockText(next)) 自動重試"))
        } else {
            resetTransientRetry()
            latchedFailure = fingerprint ?? currentFingerprint ?? ""
            publish(.failed(text))
        }
    }

    static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func resetTransientRetry() {
        retryAt = nil; retryFingerprint = nil; transientFailures = 0
    }

    private func resetFailures() {
        latchedFailure = nil; crashes = []
        resetTransientRetry()
        // Deliberately does not touch safetyLatched or the on-disk safety lock.
    }

    private func lifecycle(result: String) {
        // Only fixed internal codes: never settings, workspace errors, credentials or child output.
        guard (try? HandsGatewayLaunch.ensurePrivateDirectory(paths.root)) != nil,
              (try? HandsGatewayLaunch.ensurePrivateDirectory(paths.logDir)) != nil else { return }
        HandsGatewayLaunch.appendLog("\(HandsGatewayLaunch.timestamp(dependencies.now())) restart reason=\(restartReason) result=\(result)\n",
                                     to: paths.logFile)
    }

    private func note(_ step: String) {
        #if DEBUG
        launchLog.append(step)
        #endif
    }

    // MARK: 啟動
    private func bundledProgramDirectory() -> URL? {
        dependencies.programDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("chatgpt-hands", isDirectory: true)
    }

    private func bundledNode() -> URL? {
        dependencies.node ?? EnginePaths(environment: dependencies.environment).runtimeBinDirectory.appendingPathComponent("node")
    }

    /// 建好自己的資料夾（都 0700、不是捷徑、屬於自己）、解析真實路徑（Seatbelt 比對真實路徑）。socket 資料夾在這裡預建（v3 V8）。
    private func resolvedPaths() throws -> HandsGatewayLaunch.Paths {
        try HandsGatewayLaunch.ensurePrivateDirectory(paths.root)
        guard let real = HandsGatewayLaunch.realPath(paths.root.path) else { throw HandsGatewayLaunch.Failure.unsafeDirectory }
        let resolved = HandsGatewayLaunch.Paths(root: URL(fileURLWithPath: real, isDirectory: true))
        for directory in [resolved.gatewayDir, resolved.socketDir, resolved.cloudflaredHome, resolved.logDir] {
            try HandsGatewayLaunch.ensurePrivateDirectory(directory)
        }
        return resolved
    }

    /// 設備、網域、內建程式、cloudflared、通道憑證都先檢查；過了才開。
    private func begin(_ settings: HandsGatewayLaunch.Settings) {
        if let currentFingerprint, currentFingerprint != settings.fingerprint { restartReason = "settings_changed" }
        attemptOpen = true
        lifecycle(result: "begin")
        guard let prepared = prepare(settings) else { return }
        publish(.starting)
        start(prepared)
    }

    private func prepare(_ settings: HandsGatewayLaunch.Settings) -> Prepared? {
        let fingerprint = settings.fingerprint
        currentFingerprint = fingerprint
        guard let local = dependencies.localDeviceID(), let owner = settings.hostDeviceID,
              owner.caseInsensitiveCompare(local) == .orderedSame else {
            fail("通道設在另一台設備；這台不開", fingerprint: fingerprint); return nil
        }
        // W183 R6a 審查（GPT-6「交回主機接受只在記憶體關閉，可能重開後雙主機」）：副設備只看自己存的設備 id 不夠——
        // 這個行程要先有主設備確認過的租約（認領成功、或重開後問過主設備）。不鎖：確認到了下一次定時檢查就起。
        guard dependencies.hostConfirmed(local) else {
            currentFingerprint = nil
            if phaseOnQueue != .stopped { publish(.stopped) }
            return nil
        }
        guard let host = HandsGatewayLaunch.validHost(settings.publicHost) else { fail("還沒選網域", fingerprint: fingerprint); return nil }
        if let problem = dependencies.prepareWorkspace() { fail(problem, fingerprint: fingerprint, retryable: true); return nil }   // W183 R6c
        let fileManager = FileManager.default
        guard let program = bundledProgramDirectory(), let node = bundledNode(),
              fileManager.isExecutableFile(atPath: node.path),
              ["gateway.mjs", "gateway.sb", "cloudflared.sb", "tunnel-guard.sh"].allSatisfy({ fileManager.fileExists(atPath: program.appendingPathComponent($0).path) })
        else { fail("內建的關口程式或 Node 不完整；請重新安裝 TATWO OS", fingerprint: fingerprint); return nil }
        guard let programReal = HandsGatewayLaunch.realPath(program.path), let nodeReal = HandsGatewayLaunch.realPath(node.path),
              let guardScript = HandsGatewayLaunch.readPrivate(program.appendingPathComponent("tunnel-guard.sh"), limit: 64 * 1024).flatMap({ String(data: $0, encoding: .utf8) }),
              let gatewayProfile = HandsGatewayLaunch.readPrivate(program.appendingPathComponent("gateway.sb"), limit: 64 * 1024).flatMap({ String(data: $0, encoding: .utf8) }),
              let tunnelProfile = HandsGatewayLaunch.readPrivate(program.appendingPathComponent("cloudflared.sb"), limit: 64 * 1024).flatMap({ String(data: $0, encoding: .utf8) })
        else { fail("讀不到內建關口檔案", fingerprint: fingerprint, retryable: true); return nil }
        guard let cloudflared = dependencies.cloudflared() else {
            fail("cloudflared 尚未通過檔案與雜湊檢查（可能還沒安裝）", fingerprint: fingerprint, retryable: true); return nil
        }
        let token: String
        do {
            guard let value = try dependencies.tunnelToken.read() else { fail("還沒設定 Cloudflare 通道", fingerprint: fingerprint); return nil }
            guard HandsGatewayLaunch.validToken(value) else {
                fail("通道憑證格式不對；請到 設定 › 環境登入 › Cloudflare 重新設定", fingerprint: fingerprint); return nil
            }
            token = value
        } catch { fail("讀不到通道憑證（鑰匙圈鎖著？）", fingerprint: fingerprint, retryable: true); return nil }
        return Prepared(settings: settings, host: host, programReal: programReal, nodeReal: nodeReal, gatewayProfile: gatewayProfile,
                        tunnelProfile: tunnelProfile, guardScript: guardScript, cloudflared: cloudflared, token: token)
    }

    /// v3 V8 第 1–3 步：預建資料夾 → 開關口（CLOEXEC_DEFAULT）→ 登記 pid。第 4、5 步（健康、cloudflared）等關口回報 ready。
    private func start(_ prepared: Prepared) {
        guard allowed, !isStopping else { publish(.stopped); return }
        let fingerprint = prepared.settings.fingerprint
        let host = prepared.host
        let resolved: HandsGatewayLaunch.Paths
        let osSocket: String
        do {
            resolved = try resolvedPaths()
            note("dirs")
            HandsGatewayLaunch.removeStaleTokenFiles(in: resolved.cloudflaredHome)
            let rawSocket = dependencies.osSocket ?? OSAgentBridge.resolveSocketPath(environment: dependencies.environment)
            guard let real = HandsGatewayLaunch.realPath(rawSocket) else { throw HandsGatewayLaunch.Failure.invalidPath }
            osSocket = real
            switch HandsGatewayLaunch.socketState(resolved.socket.path) {
            case .absent: break
            case .stale: unlink(resolved.socket.path)
            case .live: return fail("另一個 TATWO OS 的關口還在跑", fingerprint: fingerprint)
            case .occupied: throw HandsGatewayLaunch.Failure.unsafeDirectory
            }
            var document = HandsGatewayLaunch.readGatewayDocument(resolved.gatewayConfig)
                ?? .init(socketPath: resolved.socket.path, publicHost: host, allowedIPRanges: [])
            document.socketPath = resolved.socket.path
            document.publicHost = host
            try HandsGatewayLaunch.writeGatewayDocument(document, to: resolved.gatewayConfig)
            let config = try HandsGatewayLaunch.cloudflaredConfig(publicHost: host, socket: resolved.socket.path)
            try HandsGatewayLaunch.writePrivate(Data(config.utf8), to: resolved.cloudflaredConfig)
        } catch { return fail("無法準備關口的資料夾或設定", fingerprint: fingerprint, retryable: true) }
        // W183 R6a 審查（GPT-6）：起關口之前先把安全停機的預寫檔確定寫進磁碟；寫不進去就不起（fail closed）。
        guard Self.armSafety(paths) else { return fail(Self.safetyArmFailedText, fingerprint: fingerprint) }
        // 回呼在開行程時就裝好（W183 R2b）：馬上輸出或馬上失敗的關口，最早的 ready／結束通知也收得到。都回到佇列上處理，
        // 這時 start() 已經把 gateway 設好了。
        generation += 1
        let current = generation
        let handlers = HandsGatewayLaunch.Handlers(
            stdout: { [weak self] data in self?.queue.async { self?.gatewayOutput(data, generation: current) } },
            stderr: { _ in },   // 關口不寫秘密到 stderr；這裡也不收不記
            exit: { [weak self] in self?.queue.async { self?.exited(.gateway, generation: current) } })
        let process: SidecarGroupedProcess
        do {
            let launch = try HandsGatewayLaunch.gatewayLaunch(profile: prepared.gatewayProfile, node: prepared.nodeReal, programDir: prepared.programReal,
                                                              paths: resolved, osSocket: osSocket)
            process = try HandsGatewayLaunch.spawnGateway(launch, paths: resolved, osSocket: osSocket, handlers: handlers)
        } catch HandsGatewayLaunch.Failure.socketPathTooLong {
            return fail("資料夾路徑太長，關口開不起來", fingerprint: fingerprint)
        } catch HandsGatewayLaunch.Failure.pathTooDeep {
            return fail("資料夾層數太多，關口開不起來", fingerprint: fingerprint)
        } catch { return fail("關口啟動失敗", fingerprint: fingerprint) }
        note("gateway_spawned:\(process.pid)")
        guard let startTime = process.startTime else {
            generation += 1   // 這一組的回呼不再作用
            process.terminateGroup()
            return fail("關口啟動失敗", fingerprint: fingerprint)
        }
        // 開好立刻登記：只有這個 pid 本人是外部 AI；它開不出子行程（Seatbelt 不准 fork），就算開得出來也一律 .other（R1）。
        dependencies.register(process.pid, startTime)
        registeredPID = process.pid
        note("registered:\(process.pid)")
        gateway = process
        gatewaySocketPath = resolved.socket.path
        currentHost = host
        gatewayBuffer = Data(); tunnelBuffer = Data(); tunnelAuthFailed = false; tunnelTooOld = false; lastGatewayError = nil
        pendingTunnel = PendingTunnel(cloudflared: prepared.cloudflared, token: prepared.token, paths: resolved,
                                      profile: prepared.tunnelProfile, guardScript: prepared.guardScript)
        queue.asyncAfter(deadline: .now() + dependencies.readyTimeout) { [weak self] in
            guard let self, current == generation, tunnel == nil, gateway != nil else { return }
            lastGatewayError = "ready_timeout"
            exited(.gateway, generation: current)
        }
    }

    private func gatewayOutput(_ data: Data, generation current: Int) {
        guard current == generation else { return }
        gatewayBuffer.append(data)
        if gatewayBuffer.count > 65_536 { gatewayBuffer.removeAll(); return }
        while let end = gatewayBuffer.firstIndex(of: 0x0A) {
            let line = gatewayBuffer[gatewayBuffer.startIndex..<end]
            gatewayBuffer.removeSubrange(gatewayBuffer.startIndex...end)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let event = object["ev"] as? String else { continue }
            switch event {
            case "ready":
                checkHealthThenStartTunnel(generation: current)
            case "req":
                if let text = HandsGatewayLaunch.logLine(object, at: dependencies.now()) { HandsGatewayLaunch.appendLog(text, to: paths.logFile) }
            case "error":
                lastGatewayError = (object["code"] as? String).map { String($0.prefix(40)) }
            default:
                break
            }
        }
    }

    /// v3 V8 第 4 步：App 自己探關口的 socket（不經佇列做阻塞 I/O），確認在服務、而且聽 socket 的就是登記的 pid，才開 cloudflared。
    private func checkHealthThenStartTunnel(generation current: Int) {
        guard let process = gateway, let socketPath = pendingTunnel?.paths.socket.path else { return }
        let expected = process.pid
        let expectedStart = process.startTime
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let probe = HandsGatewayLaunch.probeGateway(socketPath: socketPath)
            let peerStart = probe.flatMap { OSSocketCaller.processStartTime($0.peer) }
            self?.queue.async { [weak self] in
                guard let self, current == generation else { return }
                guard let probe, probe.peer == expected, peerStart == expectedStart else {
                    lastGatewayError = "unhealthy"
                    return exited(.gateway, generation: current)
                }
                note("gateway_healthy:\(probe.status)")
                startTunnel(generation: current)
            }
        }
    }

    /// v3 V8 第 5 步：最後才開 cloudflared。
    private func startTunnel(generation current: Int) {
        guard current == generation, tunnel == nil, let pending = pendingTunnel, !isStopping else { return }
        pendingTunnel = nil   // token 只在這一刻寫進 0600 檔給 cloudflared 讀，不留在記憶體裡等下一次
        let tokenFile = pending.paths.newTunnelTokenFile()
        do {
            let userHome = HandsGatewayLaunch.realPath(HandsGatewayLaunch.accountHome()) ?? HandsGatewayLaunch.accountHome()
            let launch = try HandsGatewayLaunch.cloudflaredLaunch(profile: pending.profile, guardScript: pending.guardScript,
                                                                  cloudflared: pending.cloudflared.path, paths: pending.paths, tokenFile: tokenFile,
                                                                  userHome: userHome, programPrefix: dependencies.tunnelProgramPrefix)
            try HandsGatewayLaunch.writeTokenFile(pending.token, to: tokenFile)
            tokenFileOnDisk = tokenFile
            // 回呼在開行程時就裝好（W183 R2b）：cloudflared 馬上失敗（例如憑證錯）時結束通知不會掉，不會卡在「啟動中」。
            let handlers = HandsGatewayLaunch.Handlers(
                stdout: { [weak self] data in self?.queue.async { self?.tunnelOutput(data, generation: current) } },
                stderr: { [weak self] data in self?.queue.async { self?.tunnelOutput(data, generation: current) } },
                exit: { [weak self] in self?.queue.async { self?.exited(.tunnel, generation: current) } })
            let process = try HandsGatewayLaunch.spawnTunnel(launch, paths: pending.paths, handlers: handlers)
            tunnel = process
            note("tunnel_spawned:\(process.pid)")
            // cloudflared 啟動當下就讀 token 檔；連上會更早刪（tunnelOutput），最晚到這裡也刪。
            queue.asyncAfter(deadline: .now() + dependencies.tokenFileLifetime) { [weak self] in
                guard let self, current == generation else { return }
                dropTokenFile()
            }
        } catch {
            HandsGatewayLaunch.removeTokenFile(tokenFile)
            tokenFileOnDisk = nil
            lastGatewayError = "tunnel_spawn_failed"
            exited(.tunnel, generation: current)
        }
    }

    private func dropTokenFile() {
        if let file = tokenFileOnDisk { HandsGatewayLaunch.removeTokenFile(file) }
        tokenFileOnDisk = nil
    }

    /// cloudflared 的輸出只拿來判斷狀態（連上了、憑證無效），一行都不存。
    private func tunnelOutput(_ data: Data, generation current: Int) {
        guard current == generation else { return }
        tunnelBuffer.append(data)
        if tunnelBuffer.count > 65_536 { tunnelBuffer.removeAll(); return }
        while let end = tunnelBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: tunnelBuffer[tunnelBuffer.startIndex..<end], as: UTF8.self)
            tunnelBuffer.removeSubrange(tunnelBuffer.startIndex...end)
            if line.contains("Registered tunnel connection"), let host = currentHost {
                dropTokenFile()   // 連上了＝token 已經讀進去，檔案立刻刪
                if phaseOnQueue != .running(url: "https://\(host)/mcp") { publish(.running(url: "https://\(host)/mcp")) }
            } else if line.contains("flag provided but not defined") && line.contains("token-file") {
                tunnelTooOld = true   // 不退回用環境變數傳 token
            } else if line.contains("Unauthorized") || line.contains("token is not valid") || line.contains("Invalid tunnel secret") {
                tunnelAuthFailed = true
            }
        }
    }

    // MARK: 定時檢查（W183 R2b）
    /// 兩個行程真的還活著（結束通知萬一沒到也收得到）；通道開著時，關口的 socket 還是登記的那個 pid（連同啟動時間）在聽。
    private func checkAlive() {
        let current = generation
        if let gateway, !gateway.isRunning {
            lastGatewayError = lastGatewayError ?? "gateway_gone"
            return exited(.gateway, generation: current)
        }
        if let tunnel, !tunnel.isRunning { return exited(.tunnel, generation: current) }
        verifySocketPeer(generation: current)
    }

    /// 同一個使用者的程式能把關口的 socket 路徑換成自己的 listener，接走 cloudflared 送來的請求（含 Bearer token、配對頁表單）。
    /// 關口自己每 0.5 秒看 socket 與每一層資料夾；App 這裡再每次定時檢查確認聽的人。聽的人不對＝冒充：整組停下、不自動重開。
    /// 連不上不算冒充（關口自己的檢查與結束通知會處理）。
    private func verifySocketPeer(generation current: Int) {
        guard tunnel != nil, !peerCheckInFlight, let socketPath = gatewaySocketPath, let expected = registeredPID,
              let expectedStart = gateway?.startTime else { return }
        peerCheckInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let peer = HandsGatewayLaunch.socketPeer(socketPath: socketPath)
            let peerStart = peer.flatMap { OSSocketCaller.processStartTime($0) }
            self?.queue.async { [weak self] in
                guard let self else { return }
                peerCheckInFlight = false
                guard current == generation, gateway != nil, let peer else { return }
                if peer != expected || peerStart != expectedStart {
                    lastGatewayError = "socket_replaced"
                    exited(.gateway, generation: current)
                }
            }
        }
    }

    // MARK: 停止與重開
    /// v3 V8 退出順序：先停 cloudflared（SIGTERM，看門程式 1 秒後整組 SIGKILL；最多等 tunnelStopWait）→ 解除登記 → 再停關口。
    /// 之後才到的結束通知一律不理（generation 已經換了）。disarm（W183 R6a 審查）：正常停下＝拿掉安全停機的預寫檔（安全停機不拿）。
    private func terminateBoth() { terminateBoth(disarm: true) }

    private func terminateBoth(disarm: Bool) {
        generation += 1
        let tunnelProcess = tunnel, gatewayProcess = gateway
        tunnel = nil; gateway = nil; pendingTunnel = nil; gatewaySocketPath = nil
        gatewayBuffer = Data(); tunnelBuffer = Data()
        if let tunnelProcess {
            tunnelProcess.terminateGroup()
            let deadline = Date().addingTimeInterval(dependencies.tunnelStopWait)
            while SidecarGroupedProcess.groupIsAlive(tunnelProcess.pgid), Date() < deadline { usleep(50_000) }
            note("tunnel_stopped:\(tunnelProcess.pid)")
        }
        if let registeredPID {
            dependencies.unregister(registeredPID)
            note("unregistered:\(registeredPID)")
            self.registeredPID = nil
        }
        if let gatewayProcess {
            // 等它收完（關 socket、刪 socket 檔），接著馬上重開時才不會把還在收的舊關口當成「另一個關口還在跑」。
            gatewayProcess.terminateGroup()
            let deadline = Date().addingTimeInterval(dependencies.tunnelStopWait)
            while SidecarGroupedProcess.groupIsAlive(gatewayProcess.pgid), Date() < deadline { usleep(50_000) }
            note("gateway_stopped:\(gatewayProcess.pid)")
        }
        dropTokenFile()   // 看門程式結束時也會刪；這裡再刪一次
        if disarm, !safetyLatched { Self.disarmSafety(paths) }
    }

    private func shutdown(then phase: Phase) {
        if attemptOpen { lifecycle(result: "stopped"); attemptOpen = false }
        terminateBoth()
        restartPending = false
        publish(phase)
    }

    private func exited(_ part: Part, generation current: Int) {
        guard current == generation, !isStopping else { return }   // App 結束途中：terminateAll 在收，不重開
        let authProblem = tunnelAuthFailed
        let tooOld = tunnelTooOld
        // 關口的 socket 被換掉或刪掉（關口自己發現＝結束碼 3；App 看到聽的人不對＝socket_replaced）：可能有程式冒充關口。
        let tampered = lastGatewayError == "socket_replaced" || lastGatewayError == "socket_missing"
            || gateway?.exitCode == HandsGatewayLaunch.tamperExitCode
        // W183 R6a：重開 App 也不解除。W183 R6a 審查（GPT-6）：**先**把鎖落在磁碟上（停行程要幾秒，停到一半當掉也還鎖著），再停。
        if tampered { safetyStop() }
        terminateBoth(disarm: !tampered)   // 任一個停掉：整組結束（先 cloudflared、解除登記、再關口）
        if attemptOpen { lifecycle(result: "process_exit"); attemptOpen = false }
        restartReason = part == .gateway ? "gateway_exit" : "tunnel_exit"
        if tampered { return fail(Self.tamperedText, fingerprint: nil) }
        if tooOld { return fail("cloudflared 版本太舊（不支援 --token-file）；請更新 cloudflared", fingerprint: nil) }
        if authProblem { return fail("通道憑證無效；請到 設定 › 環境登入 › Cloudflare 重新設定", fingerprint: nil) }
        let now = dependencies.now()
        crashes = crashes.filter { now.timeIntervalSince($0) < 600 } + [now]
        if crashes.count <= 3 {
            restartPending = true
            publish(.starting)
            queue.asyncAfter(deadline: .now() + dependencies.restartDelay) { [weak self] in
                guard let self, restartPending, !isStopping else { return }
                restartPending = false
                evaluate()
            }
        } else {
            fail(part == .gateway ? "關口一直停止；請到設定按重試" : "cloudflared 一直停止；請到設定按重試", fingerprint: nil)
        }
    }

    /// 安全停機的鎖（佇列上）：這個行程記著，磁碟上也落一份（落不下＝只記一筆步驟名，不擋停機）。
    private func safetyStop() {
        safetyLatched = true
        if !Self.recordSafetyStop(paths) { note("safety_lock_memory_only") }
        latchedIncident = Self.safetyIncident(paths) ?? HandsSetup.randomLabel(20)
    }

    // MARK: OpenAI IP 清單（T1；接口約定 v2 §2 的清單政策）
    private func refreshRangesIfDue(force: Bool = false) {
        guard allowed, !fetching, HandsGatewayLaunch.readSettings(paths.settingsFile)?.enabled == true else { return }
        let now = dependencies.now()
        let fetched = HandsGatewayLaunch.readGatewayDocument(paths.gatewayConfig)?.fetchedDate
        let due = force || fetched.map { now.timeIntervalSince($0) >= HandsGatewayLaunch.refreshEvery || $0.timeIntervalSince(now) > 3600 } ?? true
        guard due else { return }
        // 抓不到時一小時後再試，不連續打。
        if !force, let last = lastRangesAttempt, now.timeIntervalSince(last) < 3600 { return }
        fetching = true
        lastRangesAttempt = now
        dependencies.fetchRanges { [weak self] result in self?.queue.async { self?.applyRanges(result) } }
    }

    /// 驗過格式才換清單；抓不到或格式不對就保留舊的、**不更新**「抓到的時間」，只記「最後一次嘗試」與原因代碼。
    private func applyRanges(_ result: Result<Data, Error>) {
        fetching = false
        let now = dependencies.now()
        guard let resolved = try? resolvedPaths() else { return }
        let settings = HandsGatewayLaunch.readSettings(resolved.settingsFile)
        var document = HandsGatewayLaunch.readGatewayDocument(resolved.gatewayConfig)
            ?? .init(socketPath: resolved.socket.path, publicHost: HandsGatewayLaunch.validHost(settings?.publicHost) ?? "", allowedIPRanges: [])
        switch result {
        case .success(let data):
            do {
                document.allowedIPRanges = try HandsGatewayLaunch.parseConnectorRanges(data)
                document.rangesFetchedAt = HandsGatewayLaunch.timestamp(now)
                document.lastError = nil
            } catch { document.lastError = "invalid_list" }
        case .failure:
            document.lastError = "fetch_failed"
        }
        document.lastAttemptAt = HandsGatewayLaunch.timestamp(now)
        try? HandsGatewayLaunch.writeGatewayDocument(document, to: resolved.gatewayConfig)
        let fetched = document.fetchedDate
        let problem: String? = HandsGatewayLaunch.isStale(fetched, now: now) ? "OpenAI 的 IP 清單過期或還沒抓到：關口目前全部拒絕"
            : document.lastError == nil ? nil : "這次沒抓到新的 IP 清單，先用上次的"
        DispatchQueue.main.async { [weak self] in self?.rangesFetchedAt = fetched; self?.rangesProblem = problem }
    }

    /// 只抓 https://openai.com/chatgpt-connectors.json：不帶 cookie、不跟隨轉址、最多 1 MiB。
    static func fetchConnectorList(_ completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: HandsGatewayLaunch.connectorsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: HandsRangesFetchDelegate(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == HandsGatewayLaunch.connectorsURL.host, let data, data.count <= 1 << 20 else {
                completion(.failure(HandsGatewayLaunch.Failure.invalidList))
                return
            }
            completion(.success(data))
        }.resume()
    }

    #if DEBUG
    /// 自測用：等佇列上的事做完，讀目前狀態（不經主執行緒）。
    var debugPhase: Phase { queue.sync { phaseOnQueue } }
    var debugProcesses: (gateway: SidecarGroupedProcess?, tunnel: SidecarGroupedProcess?) { queue.sync { (gateway, tunnel) } }
    var debugLaunchLog: [String] { queue.sync { launchLog } }
    var debugRetryAt: Date? { queue.sync { retryAt } }
    var debugCrashCount: Int { queue.sync { crashes.count } }
    func debugApplyRanges(_ result: Result<Data, Error>) { queue.sync { applyRanges(result) } }
    func debugEvaluate() { queue.sync { evaluate() } }
    /// W183 R6a 審查自測：走一次真的安全停機那條路（先鎖、再停），不需要真的關口。
    func debugSafetyStop() { queue.sync { safetyStop(); terminateBoth(disarm: false); fail(Self.tamperedText, fingerprint: nil) } }
    #endif
}

/// IP 清單不跟隨轉址（只信 openai.com 本身給的內容）。
private final class HandsRangesFetchDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
